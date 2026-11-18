import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'dequant.dart';
import 'od_ec_decoder.dart';

/// Harbor AV1 INTER mode-info entropy decoder. Decodes one inter block's
/// mode-info off the shared `od_ec` range coder for the minimal single-ref
/// target: a whole-frame BLOCK_64X64 with no decoded neighbours (the spatial
/// find_mv_refs scan finds no candidates, so the ref-mv stack is empty, the
/// predictor is the zero/global MV and `mode_context` is 0).
///
/// It reads, in AV1 spec order over a single od_ec window starting at the
/// tile data: partition (must resolve to PARTITION_NONE for this gate), skip,
/// is_inter, the single_ref reference tree, inter_mode (new/zero/ref-mv tree),
/// and, for NEWMV, `read_mv` (mv_joint then per-component sign / class /
/// class0-or-bits / fp / hp). segment_id, skip_mode, cdef, delta_q, DRL,
/// interp_filter and motion_mode are all INFERRED (no coded symbol) for this
/// header configuration, matching SW.
///
/// The starting per-context ICDFs (which for an inter frame with
/// primary_ref_frame set are the reference frame's ADAPTED CDFs) are supplied
/// on the `cdf_in` / `nsyms_in` ports and loaded into the od_ec contexts in the
/// preload phase, like the frame CDF state load. Adaptation during decode
/// follows the od_ec `update_cdf`.
///
/// Scope: single-ref NEWMV SIMPLE inter block mode/ref/mv decode. It does NOT
/// decode the residual coefficients (the next gate). Verification surface: the
/// decoded is_inter / ref0 / inter_mode / motion_mode / mv, the symbol count,
/// and the od_ec `rng` at mode-info end (the sync check).
class HarborInterModeWalk extends BridgeModule {
  final int maxBytes;

  /// When set, continue past mode-info to decode the block's RESIDUAL
  /// coefficients on the SAME od_ec window (txb_skip per plane, then for a
  /// non-skipped chroma txb the eob_pt / coeff_base_eob / coeff_br / dc_sign /
  /// golomb path + dequant). Scoped to the minimal INTER target: a
  /// BLOCK_64X64 with a single-coefficient (eob == 1, DC-only) chroma-U
  /// residual and all-zero luma-Y / chroma-V, at txMode LARGEST (no var-tx),
  /// forced chroma tx_type = DCT_DCT. Adds coeff od_ec contexts (49..) whose
  /// starting ICDFs come from `cdf_in` like the mode contexts. The eob>1
  /// (multi-coeff, neighbour-context coeff_base) path is the next gate.
  final bool decodeResidual;

  // od_ec context allocation (index into cdf_in / nsyms_in).
  static const cPartition = 0; // 10-sym
  static const cSkip = 1;
  static const cIsInter = 2;
  static const cSingleRef0 = 3; // single_ref[ctx][0..5] -> cSingleRef0 + i
  static const cNewMv = 9;
  static const cZeroMv = 10;
  static const cRefMv = 11;
  static const cJoint = 12; // 4-sym
  static const cSign0 = 13, cSign1 = 14;
  static const cClasses0 = 15, cClasses1 = 16; // 11-sym
  static const cClass00 = 17, cClass01 = 18;
  static const cClass0Fp0 = 19; // [comp][d]: cClass0Fp0 + comp*2 + d  (4-sym)
  static const cFp0 = 23, cFp1 = 24; // 4-sym
  static const cClass0Hp0 = 25, cClass0Hp1 = 26;
  static const cHp0 = 27, cHp1 = 28;
  static const cBits0 = 29; // nmv_bits[comp][i]: cBits0 + comp*10 + i
  // Mode-info context count (also the numCtx of the default, mode-only build).
  static const numCtx = 49;
  // residual coeff contexts (decodeResidual only), appended after mode.
  static const cRcYSkip = 49; // Y txb_skip (txsCtx 4, luma, ctx 0)
  static const cRcCSkip = 50; // chroma txb_skip (txsCtx 3, ctx 7) - U and V
  static const cRcEobPt = 51; // chroma eob_pt (1024, planeType 1, 2D) 11-sym
  static const cRcEobExtra = 52; // chroma eob_extra hi-bit
  static const cRcBaseEob = 53; // chroma coeff_base_eob (txsCtx 3, pt1, ctx 0)
  static const cRcBr = 54; // chroma coeff_br
  static const cRcDcSign = 55; // chroma dc_sign (planeType 1, ctx 0)
  static const cRcBypass = 56; // bypass (golomb / eob-extra bits)
  static const numResidualCtx = 57;
  static const maxSyms = 11;

  HarborInterModeWalk({
    this.maxBytes = 16,
    this.decodeResidual = false,
    String? name,
  }) : super('HarborInterModeWalk', name: name ?? 'inter_mode_walk') {
    final numCtx = decodeResidual ? numResidualCtx : HarborInterModeWalk.numCtx;
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    // Frame MV-precision flags (av1_read_mv precision): use_subpel = !force_int,
    // use_hp = !force_int && allow_hp.
    createPort('allow_hp', PortDirection.input);
    createPort('force_integer_mv', PortDirection.input);
    // Starting per-context ICDFs and alphabet sizes (ctx c at [c*maxSyms*16 ..],
    // entry s at [.. + s*16], nsyms_in ctx c at [c*5 ..]).
    createPort('cdf_in', PortDirection.input, width: numCtx * maxSyms * 16);
    createPort('nsyms_in', PortDirection.input, width: numCtx * 5);

    addOutput('done');
    addOutput('is_inter');
    addOutput('ref0', width: 3);
    addOutput('inter_mode', width: 5); // SW enum (NEWMV=16)
    addOutput('motion_mode', width: 2); // 0 = SIMPLE (inferred)
    addOutput('partition', width: 4);
    addOutput('mv_row', width: 16); // two's-complement 1/8-pel delta+pred
    addOutput('mv_col', width: 16);
    addOutput('sym_count', width: 8);
    addOutput('rng', width: 16);

    // Residual-decode data ports (decodeResidual). dc/ac quant steps are frame
    // data driven in. The decoded chroma-U DC dequantized coefficient and the
    // per-plane all_zero flags + U eob are outputs.
    if (decodeResidual) {
      createPort('dc_q', PortDirection.input, width: 16);
      createPort('ac_q', PortDirection.input, width: 16);
      addOutput('y_all_zero');
      addOutput('u_all_zero');
      addOutput('v_all_zero');
      addOutput('u_eob', width: 11);
      addOutput('u_dc_level', width: 20); // pre-dequant magnitude
      addOutput('u_dc_sign');
      addOutput('u_dc_coeff', width: 16); // dequantized, signed
    }

    final clk = input('clk');
    final reset = input('reset');

    final ec = HarborOdEcDecoder(maxSyms: maxSyms, numCtx: numCtx, name: 'ec');
    addSubModule(ec);
    final cw = ec.ctxWidth;

    // byte window + cursor feeding the od_ec (identical to mode-walk).
    final buf = [
      for (var i = 0; i < maxBytes; i++) Logic(name: 'b_$i', width: 8),
    ];
    final cursor = Logic(name: 'cursor', width: (maxBytes + 4).bitLength);
    Logic byteAt(Logic ix) {
      Logic v = buf.last;
      for (var i = maxBytes - 2; i >= 0; i--) {
        v = mux(ix.eq(Const(i, width: cursor.width)), buf[i], v);
      }
      return mux(
        ix.gte(Const(maxBytes, width: cursor.width)),
        Const(0, width: 8),
        v,
      );
    }

    final ecInit = Logic(name: 'ec_init');
    final ecLoad = Logic(name: 'ec_load');
    final ecDecode = Logic(name: 'ec_decode');
    final ecCtx = Logic(name: 'ec_ctx', width: cw);
    final ecCdf = Logic(name: 'ec_cdf', width: maxSyms * 16);
    final ecNsyms = Logic(name: 'ec_nsyms', width: 5);
    ec.input('clk').srcConnection! <= clk;
    ec.input('reset').srcConnection! <= reset;
    ec.input('init').srcConnection! <= ecInit;
    ec.input('load').srcConnection! <= ecLoad;
    ec.input('decode').srcConnection! <= ecDecode;
    ec.input('ctx').srcConnection! <= ecCtx;
    ec.input('cdf').srcConnection! <= ecCdf;
    ec.input('num_syms').srcConnection! <= ecNsyms;
    ec.input('bytes_in').srcConnection! <=
        [
          byteAt(cursor),
          byteAt((cursor + Const(1, width: cursor.width))),
          byteAt((cursor + Const(2, width: cursor.width))),
        ].concat();
    final sym = ec.output('symbol');
    final bytePop = ec.output('byte_pop');

    // Slice the packed CDF / nsyms inputs for a context index.
    final cdfInBits = input('cdf_in');
    final nsymsInBits = input('nsyms_in');
    Logic cdfForCtx(Logic ctx) {
      Logic v = cdfInBits.getRange(
        (numCtx - 1) * maxSyms * 16,
        numCtx * maxSyms * 16,
      );
      for (var c = numCtx - 2; c >= 0; c--) {
        v = mux(
          ctx.eq(Const(c, width: ctx.width)),
          cdfInBits.getRange(c * maxSyms * 16, (c + 1) * maxSyms * 16),
          v,
        );
      }
      return v;
    }

    Logic nsymsForCtx(Logic ctx) {
      Logic v = nsymsInBits.getRange((numCtx - 1) * 5, numCtx * 5);
      for (var c = numCtx - 2; c >= 0; c--) {
        v = mux(
          ctx.eq(Const(c, width: ctx.width)),
          nsymsInBits.getRange(c * 5, c * 5 + 5),
          v,
        );
      }
      return v;
    }

    // FSM states.
    const sIdle = 0, sPreload = 1, sInit = 2, sPartDec = 3, sPartCap = 4, sSkipDec = 5, sSkipCap = 6, sIsInterDec = 7, sIsInterCap = 8, sSrDec = 9, // single_ref: ctx = cSingleRef0 + srIdx
    sSrCap = 10, sNewMvDec = 11, sNewMvCap = 12, sZeroMvDec = 13, sZeroMvCap = 14, sRefMvDec = 15, sRefMvCap = 16, sJointDec = 17, sJointCap = 18, sSignDec = 19, sSignCap = 20, sClassDec = 21, sClassCap = 22, sClass0Dec = 23, sClass0Cap = 24, sBitsDec = 25, sBitsCap = 26, sFpDec = 27, sFpCap = 28, sHpDec = 29, sHpCap = 30, sCompAsm = 31, sDone = 32,
    // residual coeff decode (decodeResidual)
    sRcYSkipDec = 33, sRcYSkipCap = 34, sRcUSkipDec = 35, sRcUSkipCap = 36, sRcEobPtDec = 37, sRcEobPtCap = 38, sRcBaseEobDec = 41, sRcBaseEobCap = 42, sRcBrDec = 43, sRcBrCap = 44, sRcDcSignDec = 45, sRcDcSignCap = 46, sRcVSkipDec = 51, sRcVSkipCap = 52;
    const stW = 6;
    // Mode-info terminal state: continue into the residual when decodeResidual.
    final modeEnd = decodeResidual ? sRcYSkipDec : sDone;

    final st = Logic(name: 'st', width: stW);
    final pli = Logic(name: 'pli', width: cw);

    // Decode result registers.
    final isInterReg = Logic(name: 'is_inter_r');
    final ref0Reg = Logic(name: 'ref0_r', width: 3);
    final modeReg = Logic(name: 'mode_r', width: 5);
    final partReg = Logic(name: 'part_r', width: 4);
    final symCnt = Logic(name: 'sym_cnt', width: 8);

    // single_ref tree walk.
    final srIdx = Logic(name: 'sr_idx', width: cw); // 0..5

    // read_mv state.
    final jointReg = Logic(name: 'joint_r', width: 2);
    final needRow = Logic(name: 'need_row');
    final needCol = Logic(name: 'need_col');
    final compReg = Logic(name: 'comp_r'); // 0 = row, 1 = col
    final signReg = Logic(name: 'sign_r');
    final mvClassReg = Logic(name: 'mvclass_r', width: 4);
    final dAcc = Logic(name: 'd_acc', width: 11);
    final bitI = Logic(name: 'bit_i', width: 4);
    final frReg = Logic(name: 'fr_r', width: 2);
    final hpReg = Logic(name: 'hp_r');
    final mvRowReg = Logic(name: 'mv_row_r', width: 16);
    final mvColReg = Logic(name: 'mv_col_r', width: 16);

    // residual coeff registers (decodeResidual)
    final yAllZeroReg = Logic(name: 'y_all_zero_r');
    final uAllZeroReg = Logic(name: 'u_all_zero_r');
    final vAllZeroReg = Logic(name: 'v_all_zero_r');
    final eobPtReg = Logic(name: 'eob_pt_r', width: 4);
    final eobReg = Logic(name: 'eob_r', width: 11);
    final uLevelReg = Logic(name: 'u_level_r', width: 20);
    final uSignReg = Logic(name: 'u_sign_r');
    final brIdxReg = Logic(name: 'br_idx_r', width: 3);

    // eob group-start ROM (libaom av1_eob_group_start), indexed by eob_pt (1..).
    // Only the offset-bit-free groups (eob_pt <= 2) are in scope here.
    const eobGroupStart = [0, 1, 2, 3, 5, 9, 17, 33, 65, 129, 257, 513];
    Logic romSel(List<int> tbl, Logic idx, int w) {
      Logic v = Const(tbl.last, width: w);
      for (var i = tbl.length - 2; i >= 0; i--) {
        v = mux(idx.eq(Const(i, width: idx.width)), Const(tbl[i], width: w), v);
      }
      return v;
    }

    final useSubpel = ~input('force_integer_mv');
    final useHp = ~input('force_integer_mv') & input('allow_hp');
    final isClass0 = mvClassReg.eq(Const(0, width: 4));

    // Context for the current component's fp / hp reads.
    final fpBaseComp = mux<Logic>(
      compReg,
      Const(cFp1, width: cw),
      Const(cFp0, width: cw),
    );
    final class0FpCtx =
        (Const(cClass0Fp0, width: cw) +
                (compReg.zeroExtend(cw) << 1) +
                dAcc.getRange(0, 1).zeroExtend(cw))
            .getRange(0, cw);
    final fpCtx = mux(isClass0, class0FpCtx, fpBaseComp);
    final hpCtx = mux(
      isClass0,
      mux<Logic>(
        compReg,
        Const(cClass0Hp1, width: cw),
        Const(cClass0Hp0, width: cw),
      ),
      mux<Logic>(compReg, Const(cHp1, width: cw), Const(cHp0, width: cw)),
    );
    final signCtx = mux<Logic>(
      compReg,
      Const(cSign1, width: cw),
      Const(cSign0, width: cw),
    );
    final classCtx = mux<Logic>(
      compReg,
      Const(cClasses1, width: cw),
      Const(cClasses0, width: cw),
    );
    final class0Ctx = mux<Logic>(
      compReg,
      Const(cClass01, width: cw),
      Const(cClass00, width: cw),
    );
    final bitsCtx =
        (Const(cBits0, width: cw) +
                (compReg.zeroExtend(cw) * Const(10, width: cw)) +
                bitI.zeroExtend(cw))
            .getRange(0, cw);

    // combinational od_ec control.
    Combinational([
      ecInit < Const(0),
      ecLoad < Const(0),
      ecDecode < Const(0),
      ecCtx < Const(0, width: cw),
      ecCdf < Const(0, width: maxSyms * 16),
      ecNsyms < Const(0, width: 5),
      Case(st, [
        CaseItem(Const(sPreload, width: stW), [
          ecLoad < Const(1),
          ecCtx < pli,
          ecCdf < cdfForCtx(pli),
          ecNsyms < nsymsForCtx(pli),
        ]),
        CaseItem(Const(sInit, width: stW), [ecInit < Const(1)]),
        CaseItem(Const(sPartDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < Const(cPartition, width: cw),
        ]),
        CaseItem(Const(sSkipDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < Const(cSkip, width: cw),
        ]),
        CaseItem(Const(sIsInterDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < Const(cIsInter, width: cw),
        ]),
        CaseItem(Const(sSrDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < (Const(cSingleRef0, width: cw) + srIdx).getRange(0, cw),
        ]),
        CaseItem(Const(sNewMvDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < Const(cNewMv, width: cw),
        ]),
        CaseItem(Const(sZeroMvDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < Const(cZeroMv, width: cw),
        ]),
        CaseItem(Const(sRefMvDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < Const(cRefMv, width: cw),
        ]),
        CaseItem(Const(sJointDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < Const(cJoint, width: cw),
        ]),
        CaseItem(Const(sSignDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < signCtx,
        ]),
        CaseItem(Const(sClassDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < classCtx,
        ]),
        CaseItem(Const(sClass0Dec, width: stW), [
          ecDecode < Const(1),
          ecCtx < class0Ctx,
        ]),
        CaseItem(Const(sBitsDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < bitsCtx,
        ]),
        CaseItem(Const(sFpDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < fpCtx,
        ]),
        CaseItem(Const(sHpDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < hpCtx,
        ]),
        if (decodeResidual) ...[
          CaseItem(Const(sRcYSkipDec, width: stW), [
            ecDecode < Const(1),
            ecCtx < Const(cRcYSkip, width: cw),
          ]),
          CaseItem(Const(sRcUSkipDec, width: stW), [
            ecDecode < Const(1),
            ecCtx < Const(cRcCSkip, width: cw),
          ]),
          CaseItem(Const(sRcVSkipDec, width: stW), [
            ecDecode < Const(1),
            ecCtx < Const(cRcCSkip, width: cw),
          ]),
          CaseItem(Const(sRcEobPtDec, width: stW), [
            ecDecode < Const(1),
            ecCtx < Const(cRcEobPt, width: cw),
          ]),
          CaseItem(Const(sRcBaseEobDec, width: stW), [
            ecDecode < Const(1),
            ecCtx < Const(cRcBaseEob, width: cw),
          ]),
          CaseItem(Const(sRcBrDec, width: stW), [
            ecDecode < Const(1),
            ecCtx < Const(cRcBr, width: cw),
          ]),
          CaseItem(Const(sRcDcSignDec, width: stW), [
            ecDecode < Const(1),
            ecCtx < Const(cRcDcSign, width: cw),
          ]),
        ],
      ]),
    ]);

    // component value assembly (av1_read_mv_component).
    // mag_base = class0 ? 0 : (CLASS0_SIZE(2) << (mvClass+2))
    // mag = mag_base + ((d<<3) | (fr<<1) | hp) + 1. Value = sign ? -mag : mag.
    final magBase = mux(
      isClass0,
      Const(0, width: 17),
      (Const(2, width: 17) << (mvClassReg + Const(2, width: 4)).getRange(0, 4))
          .getRange(0, 17),
    );
    final tail =
        ((dAcc.zeroExtend(17) << 3) |
            (frReg.zeroExtend(17) << 1) |
            hpReg.zeroExtend(17)) +
        Const(1, width: 17);
    final magFull = (magBase + tail).getRange(0, 16);
    final compVal = mux(signReg, (~magFull + Const(1, width: 16)), magFull);

    output('done') <= st.eq(Const(sDone, width: stW));
    output('is_inter') <= isInterReg;
    output('ref0') <= ref0Reg;
    output('inter_mode') <= modeReg;
    output('motion_mode') <= Const(0, width: 2);
    output('partition') <= partReg;
    output('mv_row') <= mvRowReg;
    output('mv_col') <= mvColReg;
    output('sym_count') <= symCnt;
    output('rng') <= ec.output('rng');

    if (decodeResidual) {
      // Dequant the chroma-U DC (is_dc = 1, TX_32X32 shift = 1). Combinational
      // from the decoded level / sign registers.
      final deq = HarborDequant(bitDepth: 8, name: 'deq');
      addSubModule(deq);
      deq.input('level').srcConnection! <= uLevelReg;
      deq.input('dc_q').srcConnection! <= input('dc_q');
      deq.input('ac_q').srcConnection! <= input('ac_q');
      deq.input('is_dc').srcConnection! <= Const(1);
      deq.input('sign').srcConnection! <= uSignReg;
      deq.input('shift').srcConnection! <= Const(1, width: 2);
      output('y_all_zero') <= yAllZeroReg;
      output('u_all_zero') <= uAllZeroReg;
      output('v_all_zero') <= vAllZeroReg;
      output('u_eob') <= eobReg;
      output('u_dc_level') <= uLevelReg;
      output('u_dc_sign') <= uSignReg;
      output('u_dc_coeff') <= deq.output('dq_coeff').getRange(0, 16);
    }

    // Single-ref tree next-step decode (single_ref, referenceMode == SINGLE).
    // Reads: [0]. Forward([0]==0): [2] then ([2]!=0 -> [4] else [3]).
    // Backward([0]!=0): [1] then ([1]==0 -> [5] else ALTREF).
    List<Conditional> srNext() {
      // srIdx holds the sub-cdf index just decoded, `sym` is its symbol.
      return [
        Case(srIdx, [
          CaseItem(Const(0, width: cw), [
            // p1
            If(
              sym.eq(Const(0, width: ec.symWidth)),
              then: [
                srIdx < Const(2, width: cw),
                st < Const(sSrDec, width: stW),
              ],
              orElse: [
                srIdx < Const(1, width: cw),
                st < Const(sSrDec, width: stW),
              ],
            ),
          ]),
          CaseItem(Const(2, width: cw), [
            // p3
            If(
              sym.eq(Const(0, width: ec.symWidth)),
              then: [
                srIdx < Const(3, width: cw),
                st < Const(sSrDec, width: stW),
              ],
              orElse: [
                srIdx < Const(4, width: cw),
                st < Const(sSrDec, width: stW),
              ],
            ),
          ]),
          CaseItem(Const(3, width: cw), [
            // p4 -> LAST2(2) : LAST(1)
            ref0Reg <
                mux<Logic>(
                  sym.eq(Const(0, width: ec.symWidth)),
                  Const(1, width: 3),
                  Const(2, width: 3),
                ),
            st < Const(sNewMvDec, width: stW),
          ]),
          CaseItem(Const(4, width: cw), [
            // p5 -> GOLDEN(4) : LAST3(3)
            ref0Reg <
                mux<Logic>(
                  sym.eq(Const(0, width: ec.symWidth)),
                  Const(3, width: 3),
                  Const(4, width: 3),
                ),
            st < Const(sNewMvDec, width: stW),
          ]),
          CaseItem(Const(1, width: cw), [
            // p2
            If(
              sym.eq(Const(0, width: ec.symWidth)),
              then: [
                srIdx < Const(5, width: cw),
                st < Const(sSrDec, width: stW),
              ],
              orElse: [
                ref0Reg < Const(7, width: 3), // ALTREF
                st < Const(sNewMvDec, width: stW),
              ],
            ),
          ]),
          CaseItem(Const(5, width: cw), [
            // p6 -> ALTREF2(6) : BWDREF(5)
            ref0Reg <
                mux<Logic>(
                  sym.eq(Const(0, width: ec.symWidth)),
                  Const(5, width: 3),
                  Const(6, width: 3),
                ),
            st < Const(sNewMvDec, width: stW),
          ]),
        ]),
      ];
    }

    // Start decoding component `compReg` (sign first).
    // After a component finishes (sCompAsm) go to the next component or done.

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: stW),
          cursor < Const(0, width: cursor.width),
          pli < Const(0, width: cw),
          isInterReg < Const(0),
          ref0Reg < Const(0, width: 3),
          modeReg < Const(0, width: 5),
          partReg < Const(0, width: 4),
          symCnt < Const(0, width: 8),
          srIdx < Const(0, width: cw),
          jointReg < Const(0, width: 2),
          needRow < Const(0),
          needCol < Const(0),
          compReg < Const(0),
          signReg < Const(0),
          mvClassReg < Const(0, width: 4),
          dAcc < Const(0, width: 11),
          bitI < Const(0, width: 4),
          frReg < Const(0, width: 2),
          hpReg < Const(0),
          mvRowReg < Const(0, width: 16),
          mvColReg < Const(0, width: 16),
          yAllZeroReg < Const(0),
          uAllZeroReg < Const(0),
          vAllZeroReg < Const(0),
          eobPtReg < Const(0, width: 4),
          eobReg < Const(0, width: 11),
          uLevelReg < Const(0, width: 20),
          uSignReg < Const(0),
          brIdxReg < Const(0, width: 3),
          for (var i = 0; i < maxBytes; i++) buf[i] < Const(0, width: 8),
        ],
        orElse: [
          cursor <
              (cursor + bytePop.zeroExtend(cursor.width)).getRange(
                0,
                cursor.width,
              ),
          Case(st, [
            CaseItem(Const(sIdle, width: stW), [
              If(
                input('start'),
                then: [
                  for (var i = 0; i < maxBytes; i++)
                    buf[i] < input('bytes').getRange(i * 8, i * 8 + 8),
                  cursor < Const(0, width: cursor.width),
                  pli < Const(0, width: cw),
                  symCnt < Const(0, width: 8),
                  st < Const(sPreload, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(sPreload, width: stW), [
              If(
                pli.eq(Const(numCtx - 1, width: cw)),
                then: [st < Const(sInit, width: stW)],
                orElse: [pli < (pli + Const(1, width: cw)).getRange(0, cw)],
              ),
            ]),
            CaseItem(Const(sInit, width: stW), [
              st < Const(sPartDec, width: stW),
            ]),

            // partition (must be NONE for this gate).
            CaseItem(Const(sPartDec, width: stW), [
              st < Const(sPartCap, width: stW),
            ]),
            CaseItem(Const(sPartCap, width: stW), [
              partReg < sym.getRange(0, 4),
              symCnt < (symCnt + Const(1, width: 8)),
              st < Const(sSkipDec, width: stW),
            ]),

            // skip
            CaseItem(Const(sSkipDec, width: stW), [
              st < Const(sSkipCap, width: stW),
            ]),
            CaseItem(Const(sSkipCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 8)),
              st < Const(sIsInterDec, width: stW),
            ]),

            // is_inter
            CaseItem(Const(sIsInterDec, width: stW), [
              st < Const(sIsInterCap, width: stW),
            ]),
            CaseItem(Const(sIsInterCap, width: stW), [
              isInterReg < sym.getRange(0, 1),
              symCnt < (symCnt + Const(1, width: 8)),
              // single-ref frame: start the single_ref tree at sub-cdf 0.
              srIdx < Const(0, width: cw),
              st < Const(sSrDec, width: stW),
            ]),

            // single_ref tree
            CaseItem(Const(sSrDec, width: stW), [
              st < Const(sSrCap, width: stW),
            ]),
            CaseItem(Const(sSrCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 8)),
              ...srNext(),
            ]),

            // inter_mode (new/zero/ref-mv tree, mode_context 0)
            CaseItem(Const(sNewMvDec, width: stW), [
              st < Const(sNewMvCap, width: stW),
            ]),
            CaseItem(Const(sNewMvCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 8)),
              If(
                sym.eq(Const(0, width: ec.symWidth)),
                then: [
                  modeReg < Const(16, width: 5), // NEWMV
                  // read_mv: predictor is the zero MV (empty stack, no global
                  // motion), decode the joint then components.
                  st < Const(sJointDec, width: stW),
                ],
                orElse: [st < Const(sZeroMvDec, width: stW)],
              ),
            ]),
            CaseItem(Const(sZeroMvDec, width: stW), [
              st < Const(sZeroMvCap, width: stW),
            ]),
            CaseItem(Const(sZeroMvCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 8)),
              If(
                sym.eq(Const(0, width: ec.symWidth)),
                then: [
                  modeReg < Const(15, width: 5), // GLOBALMV -> mv = 0
                  st < Const(modeEnd, width: stW),
                ],
                orElse: [st < Const(sRefMvDec, width: stW)],
              ),
            ]),
            CaseItem(Const(sRefMvDec, width: stW), [
              st < Const(sRefMvCap, width: stW),
            ]),
            CaseItem(Const(sRefMvCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 8)),
              // NEARESTMV(13) : NEARMV(14). Both take the (empty-stack) zero MV.
              modeReg <
                  mux<Logic>(
                    sym.eq(Const(0, width: ec.symWidth)),
                    Const(13, width: 5),
                    Const(14, width: 5),
                  ),
              st < Const(modeEnd, width: stW),
            ]),

            // read_mv: joint
            CaseItem(Const(sJointDec, width: stW), [
              st < Const(sJointCap, width: stW),
            ]),
            CaseItem(Const(sJointCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 8)),
              jointReg < sym.getRange(0, 2),
              // MV_JOINT: 0 ZERO, 1 HNZVZ(col), 2 HZVNZ(row), 3 HNZVNZ(both).
              needRow <
                  (sym.getRange(0, 2).eq(Const(2, width: 2)) |
                      sym.getRange(0, 2).eq(Const(3, width: 2))),
              needCol <
                  (sym.getRange(0, 2).eq(Const(1, width: 2)) |
                      sym.getRange(0, 2).eq(Const(3, width: 2))),
              // row first.
              If(
                sym.getRange(0, 2).eq(Const(2, width: 2)) |
                    sym.getRange(0, 2).eq(Const(3, width: 2)),
                then: [
                  compReg < Const(0),
                  st < Const(sSignDec, width: stW),
                ],
                orElse: [
                  If(
                    sym.getRange(0, 2).eq(Const(1, width: 2)),
                    then: [
                      compReg < Const(1),
                      st < Const(sSignDec, width: stW),
                    ],
                    orElse: [st < Const(modeEnd, width: stW)],
                  ),
                ],
              ),
            ]),

            // read_mv_component
            CaseItem(Const(sSignDec, width: stW), [
              st < Const(sSignCap, width: stW),
            ]),
            CaseItem(Const(sSignCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 8)),
              signReg < sym.getRange(0, 1),
              st < Const(sClassDec, width: stW),
            ]),
            CaseItem(Const(sClassDec, width: stW), [
              st < Const(sClassCap, width: stW),
            ]),
            CaseItem(Const(sClassCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 8)),
              mvClassReg < sym.getRange(0, 4),
              dAcc < Const(0, width: 11),
              bitI < Const(0, width: 4),
              If(
                sym.getRange(0, 4).eq(Const(0, width: 4)),
                then: [
                  st < Const(sClass0Dec, width: stW), // class0
                ],
                orElse: [
                  st < Const(sBitsDec, width: stW), // classN bits
                ],
              ),
            ]),
            CaseItem(Const(sClass0Dec, width: stW), [
              st < Const(sClass0Cap, width: stW),
            ]),
            CaseItem(Const(sClass0Cap, width: stW), [
              symCnt < (symCnt + Const(1, width: 8)),
              dAcc < sym.getRange(0, 1).zeroExtend(11),
              If(
                useSubpel,
                then: [st < Const(sFpDec, width: stW)],
                orElse: [
                  frReg < Const(3, width: 2),
                  hpReg < Const(1),
                  st < Const(sCompAsm, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(sBitsDec, width: stW), [
              st < Const(sBitsCap, width: stW),
            ]),
            CaseItem(Const(sBitsCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 8)),
              // d |= bit << bitI
              dAcc <
                  (dAcc |
                          (sym.getRange(0, 1).zeroExtend(11) <<
                              bitI.getRange(0, 4)))
                      .getRange(0, 11),
              If(
                (bitI + Const(1, width: 4)).getRange(0, 4).lt(mvClassReg),
                then: [
                  bitI < (bitI + Const(1, width: 4)).getRange(0, 4),
                  st < Const(sBitsDec, width: stW),
                ],
                orElse: [
                  If(
                    useSubpel,
                    then: [st < Const(sFpDec, width: stW)],
                    orElse: [
                      frReg < Const(3, width: 2),
                      hpReg < Const(1),
                      st < Const(sCompAsm, width: stW),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sFpDec, width: stW), [
              st < Const(sFpCap, width: stW),
            ]),
            CaseItem(Const(sFpCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 8)),
              frReg < sym.getRange(0, 2),
              If(
                useHp,
                then: [st < Const(sHpDec, width: stW)],
                orElse: [
                  hpReg < Const(1),
                  st < Const(sCompAsm, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(sHpDec, width: stW), [
              st < Const(sHpCap, width: stW),
            ]),
            CaseItem(Const(sHpCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 8)),
              hpReg < sym.getRange(0, 1),
              st < Const(sCompAsm, width: stW),
            ]),
            CaseItem(Const(sCompAsm, width: stW), [
              If(
                compReg.eq(Const(0)),
                then: [
                  mvRowReg < compVal,
                  If(
                    needCol,
                    then: [
                      compReg < Const(1),
                      st < Const(sSignDec, width: stW),
                    ],
                    orElse: [st < Const(modeEnd, width: stW)],
                  ),
                ],
                orElse: [
                  mvColReg < compVal,
                  st < Const(modeEnd, width: stW),
                ],
              ),
            ]),

            if (decodeResidual) ...[
              // Y txb_skip (TX_64X64 luma). all_zero here (no luma coeffs).
              CaseItem(Const(sRcYSkipDec, width: stW), [
                st < Const(sRcYSkipCap, width: stW),
              ]),
              CaseItem(Const(sRcYSkipCap, width: stW), [
                symCnt < (symCnt + Const(1, width: 8)),
                yAllZeroReg < sym.getRange(0, 1),
                st < Const(sRcUSkipDec, width: stW),
              ]),
              // U txb_skip (TX_32X32 chroma).
              CaseItem(Const(sRcUSkipDec, width: stW), [
                st < Const(sRcUSkipCap, width: stW),
              ]),
              CaseItem(Const(sRcUSkipCap, width: stW), [
                symCnt < (symCnt + Const(1, width: 8)),
                uAllZeroReg < sym.getRange(0, 1),
                If(
                  sym.getRange(0, 1),
                  then: [st < Const(sRcVSkipDec, width: stW)],
                  orElse: [st < Const(sRcEobPtDec, width: stW)],
                ),
              ]),
              // U eob_pt (chroma 1024, 2D). eob = eobGroupStart[eob_pt].
              // This DC-only gate only covers eob_pt <= 2 (no offset bits).
              CaseItem(Const(sRcEobPtDec, width: stW), [
                st < Const(sRcEobPtCap, width: stW),
              ]),
              CaseItem(Const(sRcEobPtCap, width: stW), [
                symCnt < (symCnt + Const(1, width: 8)),
                eobPtReg <
                    (sym.getRange(0, 4) + Const(1, width: 4)).getRange(0, 4),
                eobReg <
                    romSel(
                      eobGroupStart,
                      (sym.getRange(0, 4) + Const(1, width: 4)).getRange(0, 4),
                      11,
                    ),
                st < Const(sRcBaseEobDec, width: stW),
              ]),
              // U coeff_base_eob (eob-1 coeff = DC). level = sym + 1.
              CaseItem(Const(sRcBaseEobDec, width: stW), [
                st < Const(sRcBaseEobCap, width: stW),
              ]),
              CaseItem(Const(sRcBaseEobCap, width: stW), [
                symCnt < (symCnt + Const(1, width: 8)),
                uLevelReg <
                    (sym.getRange(0, 2).zeroExtend(20) + Const(1, width: 20)),
                brIdxReg < Const(0, width: 3),
                If(
                  sym.getRange(0, 2).eq(Const(2, width: 2)),
                  then: [st < Const(sRcBrDec, width: stW)], // level 3 -> range
                  orElse: [st < Const(sRcDcSignDec, width: stW)],
                ),
              ]),
              // U coeff_br range-extension (up to 4 reads of 4 syms).
              CaseItem(Const(sRcBrDec, width: stW), [
                st < Const(sRcBrCap, width: stW),
              ]),
              CaseItem(Const(sRcBrCap, width: stW), [
                symCnt < (symCnt + Const(1, width: 8)),
                uLevelReg <
                    (uLevelReg + sym.getRange(0, 2).zeroExtend(20)).getRange(
                      0,
                      20,
                    ),
                If(
                  sym.getRange(0, 2).lt(Const(3, width: 2)) |
                      brIdxReg.eq(Const(3, width: 3)),
                  then: [st < Const(sRcDcSignDec, width: stW)],
                  orElse: [
                    brIdxReg < (brIdxReg + Const(1, width: 3)),
                    st < Const(sRcBrDec, width: stW),
                  ],
                ),
              ]),
              // U dc_sign. (golomb for level >= 15 is out of scope here.)
              CaseItem(Const(sRcDcSignDec, width: stW), [
                st < Const(sRcDcSignCap, width: stW),
              ]),
              CaseItem(Const(sRcDcSignCap, width: stW), [
                symCnt < (symCnt + Const(1, width: 8)),
                uSignReg < sym.getRange(0, 1),
                st < Const(sRcVSkipDec, width: stW),
              ]),
              // V txb_skip (TX_32X32 chroma). all_zero here.
              CaseItem(Const(sRcVSkipDec, width: stW), [
                st < Const(sRcVSkipCap, width: stW),
              ]),
              CaseItem(Const(sRcVSkipCap, width: stW), [
                symCnt < (symCnt + Const(1, width: 8)),
                vAllZeroReg < sym.getRange(0, 1),
                st < Const(sDone, width: stW),
              ]),
            ],
            CaseItem(Const(sDone, width: stW), [
              If(~input('start'), then: [st < Const(sIdle, width: stW)]),
            ]),
          ]),
        ],
      ),
    ]);
  }
}
