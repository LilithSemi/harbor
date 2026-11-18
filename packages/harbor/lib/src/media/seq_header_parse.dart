import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'bit_reader.dart';

/// Harbor AV1 `sequence_header_obu` parser, a faithful port of the libaom/spec
/// `parseSequenceHeader` logic.
///
/// Unlike [HarborBitReader]-cascade [HarborSeqHeaderParser] (which only covers
/// the flat `reduced_still_picture_header == 1` prefix), the sequence header has
/// DATA-DEPENDENT loops (the operating-points list, the `uvlc` num-ticks read)
/// and many runtime branches, so it must be a SEQUENTIAL cursor FSM, not a
/// combinational cascade. This module owns ONE [HarborBitReader] wired to a bit
/// cursor register `pos`. Each state reads exactly one `f(n)` field
/// (combinationally available the same cycle), latches it, advances `pos` by the
/// field width, and transitions, branching on just-read bits. It reproduces the
/// whole `sequence_header_obu` syntax through `color_config` + `film_grain`.
///
/// The one unsupported path (a per-operating-point decoder model,
/// `decoder_model_present_for_this_op == 1`) raises `unsupported` (and asserts
/// `done`), so a caller can detect it.
///
/// Pulse `start` for one cycle with `bytes` (a window holding the OBU payload,
/// byte 0 at bit 0). `done` asserts when the parse completes (or hits the
/// unsupported branch). All field outputs are then stable. `bits_consumed` is
/// the final bit cursor (the offset just past `film_grain_params_present`),
/// which a frame-header parser chains from.
class HarborSeqHeaderParse extends BridgeModule {
  /// Maximum coded bytes the input window holds.
  final int maxBytes;

  HarborSeqHeaderParse({this.maxBytes = 32, String? name})
    : assert(maxBytes > 0, 'maxBytes must be positive'),
      super('HarborSeqHeaderParse', name: name ?? 'seq_header_parse') {
    final totalBits = maxBytes * 8;
    final offW = totalBits.bitLength;

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: totalBits);

    addOutput('done');
    addOutput('unsupported');
    addOutput('bits_consumed', width: offW);
    // Parsed fields (mirroring SequenceHeader).
    addOutput('seq_profile', width: 3);
    addOutput('still_picture');
    addOutput('reduced_still_picture');
    addOutput('timing_info_present');
    addOutput('decoder_model_info_present');
    addOutput('operating_point_idc0', width: 12);
    addOutput('frame_width_bits_minus1', width: 4);
    addOutput('frame_height_bits_minus1', width: 4);
    addOutput('max_frame_width_minus1', width: 32);
    addOutput('max_frame_height_minus1', width: 32);
    addOutput('frame_id_numbers_present');
    addOutput('delta_frame_id_length_minus2', width: 4);
    addOutput('additional_frame_id_length_minus1', width: 3);
    addOutput('use_128x128_superblock');
    addOutput('enable_filter_intra');
    addOutput('enable_intra_edge_filter');
    addOutput('enable_interintra_compound');
    addOutput('enable_masked_compound');
    addOutput('enable_warped_motion');
    addOutput('enable_dual_filter');
    addOutput('enable_order_hint');
    addOutput('enable_jnt_comp');
    addOutput('enable_ref_frame_mvs');
    addOutput('seq_force_screen_content_tools', width: 2);
    addOutput('seq_force_integer_mv', width: 2);
    addOutput('order_hint_bits', width: 4);
    addOutput('enable_superres');
    addOutput('enable_cdef');
    addOutput('enable_restoration');
    addOutput('film_grain_params_present');
    addOutput('bit_depth', width: 5);
    addOutput('mono_chrome');
    addOutput('num_planes', width: 2);
    addOutput('color_primaries', width: 8);
    addOutput('transfer_characteristics', width: 8);
    addOutput('matrix_coefficients', width: 8);
    addOutput('color_range');
    addOutput('subsampling_x');
    addOutput('subsampling_y');
    addOutput('chroma_sample_position', width: 2);
    addOutput('separate_uv_delta_q');

    final clk = input('clk');
    final reset = input('reset');
    final start = input('start');

    // The shared f(n) bit reader, wired to the cursor + a combinational width.
    final reader = HarborBitReader(maxBytes: maxBytes, name: 'fn');
    addSubModule(reader);

    // state encoding
    const sIdle = 0;
    const sProfile = 1;
    const sStill = 2;
    const sReduced = 3;
    const sRedLevel = 4;
    const sTimingPresent = 5;
    const sTiming0 = 6;
    const sTiming1 = 7;
    const sTimingEqual = 8;
    const sUvlcLz = 9;
    const sUvlcVal = 10;
    const sDecModelPresent = 11;
    const sDecModel0 = 12;
    const sDecModel1 = 13;
    const sDecModel2 = 14;
    const sDecModel3 = 15;
    const sInitDispPresent = 16;
    const sOpCnt = 17;
    const sOpIdc = 18;
    const sOpLevel = 19;
    const sOpTier = 20;
    const sOpDecModel = 21; // branch-only
    const sOpDecModelBit = 22;
    const sOpInitDisp = 23; // branch-only
    const sOpInitDispBit = 24;
    const sOpInitDispVal = 25;
    const sOpNext = 26; // branch-only
    const sFrameWBits = 27;
    const sFrameHBits = 28;
    const sMaxW = 29;
    const sMaxH = 30;
    const sFrameIdPresent = 31;
    const sDeltaFrameId = 32;
    const sAddFrameId = 33;
    const sSuperblock = 34;
    const sFilterIntra = 35;
    const sIntraEdge = 36;
    const sInterintra = 37;
    const sMasked = 38;
    const sWarped = 39;
    const sDualFilter = 40;
    const sOrderHint = 41;
    const sJntComp = 42;
    const sRefFrameMvs = 43;
    const sChooseScreen = 44;
    const sForceScreenVal = 45;
    const sForceIntCheck = 46; // branch-only
    const sChooseIntMv = 47;
    const sForceIntMvVal = 48;
    const sOrderHintBitsCheck = 49; // branch-only
    const sOrderHintBits = 50;
    const sEnableSuperres = 51;
    const sEnableCdef = 52;
    const sEnableRestoration = 53;
    const sColorHighBd = 54;
    const sColorTwelve = 55;
    const sColorMono = 56;
    const sColorDescPresent = 57;
    const sColorPrim = 58;
    const sColorTransfer = 59;
    const sColorMatrix = 60;
    const sColorAfterDesc = 61; // branch-only
    const sColorMonoRange = 62;
    const sColorRange = 63;
    const sSubX = 64;
    const sSubY = 65;
    const sChromaPosCheck = 66; // branch-only
    const sChromaPos = 67;
    const sSeparateUv = 68;
    const sFilmGrain = 69;
    const sDone = 70;
    const sUnsupported = 71;
    const stW = 7;

    Logic sc(int v) => Const(v, width: stW);

    // registers
    final st = Logic(name: 'st', width: stW);
    final pos = Logic(name: 'pos', width: offW);
    final opCntM1 = Logic(name: 'op_cnt_m1', width: 5);
    final opI = Logic(name: 'op_i', width: 5);
    final lz = Logic(name: 'uvlc_lz', width: 6);

    // field registers
    final rSeqProfile = Logic(name: 'r_seq_profile', width: 3);
    final rStill = Logic(name: 'r_still');
    final rReduced = Logic(name: 'r_reduced');
    final rTimingPresent = Logic(name: 'r_timing_present');
    final rDecModelPresent = Logic(name: 'r_dec_model_present');
    final rOpIdc0 = Logic(name: 'r_op_idc0', width: 12);
    final rInitDispPresent = Logic(name: 'r_init_disp_present');
    final rWBits = Logic(name: 'r_w_bits', width: 4);
    final rHBits = Logic(name: 'r_h_bits', width: 4);
    final rMaxW = Logic(name: 'r_max_w', width: 32);
    final rMaxH = Logic(name: 'r_max_h', width: 32);
    final rFrameIdPresent = Logic(name: 'r_frame_id_present');
    final rDeltaFrameId = Logic(name: 'r_delta_frame_id', width: 4);
    final rAddFrameId = Logic(name: 'r_add_frame_id', width: 3);
    final rUse128 = Logic(name: 'r_use128');
    final rFilterIntra = Logic(name: 'r_filter_intra');
    final rIntraEdge = Logic(name: 'r_intra_edge');
    final rInterintra = Logic(name: 'r_interintra');
    final rMasked = Logic(name: 'r_masked');
    final rWarped = Logic(name: 'r_warped');
    final rDualFilter = Logic(name: 'r_dual_filter');
    final rOrderHint = Logic(name: 'r_order_hint');
    final rJntComp = Logic(name: 'r_jnt_comp');
    final rRefFrameMvs = Logic(name: 'r_ref_frame_mvs');
    final rForceScreen = Logic(name: 'r_force_screen', width: 2);
    final rForceIntMv = Logic(name: 'r_force_int_mv', width: 2);
    final rOrderHintBits = Logic(name: 'r_order_hint_bits', width: 4);
    final rSuperres = Logic(name: 'r_superres');
    final rCdef = Logic(name: 'r_cdef');
    final rRestoration = Logic(name: 'r_restoration');
    final rFilmGrain = Logic(name: 'r_film_grain');
    final rBitDepth = Logic(name: 'r_bit_depth', width: 5);
    final rMono = Logic(name: 'r_mono');
    final rColorPrim = Logic(name: 'r_color_prim', width: 8);
    final rTransfer = Logic(name: 'r_transfer', width: 8);
    final rMatrix = Logic(name: 'r_matrix', width: 8);
    final rColorRange = Logic(name: 'r_color_range');
    final rSubX = Logic(name: 'r_sub_x');
    final rSubY = Logic(name: 'r_sub_y');
    final rChromaPos = Logic(name: 'r_chroma_pos', width: 2);
    final rSepUv = Logic(name: 'r_sep_uv');

    // combinational field width `n` per state
    final nSel = Logic(name: 'n_sel', width: 6);
    // runtime widths
    final wMaxW = (rWBits.zeroExtend(6) + Const(1, width: 6)).getRange(0, 6);
    final wMaxH = (rHBits.zeroExtend(6) + Const(1, width: 6)).getRange(0, 6);
    final wUvlc = lz.getRange(0, 6);

    Combinational([
      nSel < Const(0, width: 6),
      Case(st, [
        CaseItem(sc(sProfile), [nSel < Const(3, width: 6)]),
        CaseItem(sc(sStill), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sReduced), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sRedLevel), [nSel < Const(5, width: 6)]),
        CaseItem(sc(sTimingPresent), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sTiming0), [nSel < Const(32, width: 6)]),
        CaseItem(sc(sTiming1), [nSel < Const(32, width: 6)]),
        CaseItem(sc(sTimingEqual), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sUvlcLz), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sUvlcVal), [nSel < wUvlc]),
        CaseItem(sc(sDecModelPresent), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sDecModel0), [nSel < Const(5, width: 6)]),
        CaseItem(sc(sDecModel1), [nSel < Const(32, width: 6)]),
        CaseItem(sc(sDecModel2), [nSel < Const(5, width: 6)]),
        CaseItem(sc(sDecModel3), [nSel < Const(5, width: 6)]),
        CaseItem(sc(sInitDispPresent), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sOpCnt), [nSel < Const(5, width: 6)]),
        CaseItem(sc(sOpIdc), [nSel < Const(12, width: 6)]),
        CaseItem(sc(sOpLevel), [nSel < Const(5, width: 6)]),
        CaseItem(sc(sOpTier), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sOpDecModelBit), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sOpInitDispBit), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sOpInitDispVal), [nSel < Const(4, width: 6)]),
        CaseItem(sc(sFrameWBits), [nSel < Const(4, width: 6)]),
        CaseItem(sc(sFrameHBits), [nSel < Const(4, width: 6)]),
        CaseItem(sc(sMaxW), [nSel < wMaxW]),
        CaseItem(sc(sMaxH), [nSel < wMaxH]),
        CaseItem(sc(sFrameIdPresent), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sDeltaFrameId), [nSel < Const(4, width: 6)]),
        CaseItem(sc(sAddFrameId), [nSel < Const(3, width: 6)]),
        CaseItem(sc(sSuperblock), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sFilterIntra), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sIntraEdge), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sInterintra), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sMasked), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sWarped), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sDualFilter), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sOrderHint), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sJntComp), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sRefFrameMvs), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sChooseScreen), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sForceScreenVal), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sChooseIntMv), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sForceIntMvVal), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sOrderHintBits), [nSel < Const(3, width: 6)]),
        CaseItem(sc(sEnableSuperres), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sEnableCdef), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sEnableRestoration), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sColorHighBd), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sColorTwelve), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sColorMono), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sColorDescPresent), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sColorPrim), [nSel < Const(8, width: 6)]),
        CaseItem(sc(sColorTransfer), [nSel < Const(8, width: 6)]),
        CaseItem(sc(sColorMatrix), [nSel < Const(8, width: 6)]),
        CaseItem(sc(sColorMonoRange), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sColorRange), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sSubX), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sSubY), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sChromaPos), [nSel < Const(2, width: 6)]),
        CaseItem(sc(sSeparateUv), [nSel < Const(1, width: 6)]),
        CaseItem(sc(sFilmGrain), [nSel < Const(1, width: 6)]),
      ]),
    ]);

    reader.input('bytes').srcConnection! <= input('bytes');
    reader.input('bit_offset').srcConnection! <= pos;
    reader.input('n').srcConnection! <= nSel;
    final rv = reader.output('value'); // 32-bit field value, right-aligned
    final bit0 = rv.getRange(0, 1); // the f(1) flag for branch states
    final nextPos = reader.output('next_offset');

    // constants
    const selectScreenContentTools = 2;
    const selectIntegerMv = 2;

    output('done') <= st.eq(sc(sDone)) | st.eq(sc(sUnsupported));
    output('unsupported') <= st.eq(sc(sUnsupported));
    output('bits_consumed') <= pos;
    output('seq_profile') <= rSeqProfile;
    output('still_picture') <= rStill;
    output('reduced_still_picture') <= rReduced;
    output('timing_info_present') <= rTimingPresent;
    output('decoder_model_info_present') <= rDecModelPresent;
    output('operating_point_idc0') <= rOpIdc0;
    output('frame_width_bits_minus1') <= rWBits;
    output('frame_height_bits_minus1') <= rHBits;
    output('max_frame_width_minus1') <= rMaxW;
    output('max_frame_height_minus1') <= rMaxH;
    output('frame_id_numbers_present') <= rFrameIdPresent;
    output('delta_frame_id_length_minus2') <= rDeltaFrameId;
    output('additional_frame_id_length_minus1') <= rAddFrameId;
    output('use_128x128_superblock') <= rUse128;
    output('enable_filter_intra') <= rFilterIntra;
    output('enable_intra_edge_filter') <= rIntraEdge;
    output('enable_interintra_compound') <= rInterintra;
    output('enable_masked_compound') <= rMasked;
    output('enable_warped_motion') <= rWarped;
    output('enable_dual_filter') <= rDualFilter;
    output('enable_order_hint') <= rOrderHint;
    output('enable_jnt_comp') <= rJntComp;
    output('enable_ref_frame_mvs') <= rRefFrameMvs;
    output('seq_force_screen_content_tools') <= rForceScreen;
    output('seq_force_integer_mv') <= rForceIntMv;
    output('order_hint_bits') <= rOrderHintBits;
    output('enable_superres') <= rSuperres;
    output('enable_cdef') <= rCdef;
    output('enable_restoration') <= rRestoration;
    output('film_grain_params_present') <= rFilmGrain;
    output('bit_depth') <= rBitDepth;
    output('mono_chrome') <= rMono;
    output('num_planes') <=
        mux<Logic>(rMono, Const(1, width: 2), Const(3, width: 2));
    output('color_primaries') <= rColorPrim;
    output('transfer_characteristics') <= rTransfer;
    output('matrix_coefficients') <= rMatrix;
    output('color_range') <= rColorRange;
    output('subsampling_x') <= rSubX;
    output('subsampling_y') <= rSubY;
    output('chroma_sample_position') <= rChromaPos;
    output('separate_uv_delta_q') <= rSepUv;

    // helper to slice rv into a reg of given width
    Logic v(int w) => rv.getRange(0, w);

    // advance the cursor by the field width and go to `to`.
    List<Conditional> step(Logic to) => [pos < nextPos, st < to];

    Sequential(clk, [
      If(
        reset,
        then: [
          st < sc(sIdle),
          pos < Const(0, width: offW),
          opCntM1 < Const(0, width: 5),
          opI < Const(0, width: 5),
          lz < Const(0, width: 6),
          rSeqProfile < Const(0, width: 3),
          rStill < Const(0),
          rReduced < Const(0),
          rTimingPresent < Const(0),
          rDecModelPresent < Const(0),
          rOpIdc0 < Const(0, width: 12),
          rInitDispPresent < Const(0),
          rWBits < Const(0, width: 4),
          rHBits < Const(0, width: 4),
          rMaxW < Const(0, width: 32),
          rMaxH < Const(0, width: 32),
          rFrameIdPresent < Const(0),
          rDeltaFrameId < Const(0, width: 4),
          rAddFrameId < Const(0, width: 3),
          rUse128 < Const(0),
          rFilterIntra < Const(0),
          rIntraEdge < Const(0),
          rInterintra < Const(0),
          rMasked < Const(0),
          rWarped < Const(0),
          rDualFilter < Const(0),
          rOrderHint < Const(0),
          rJntComp < Const(0),
          rRefFrameMvs < Const(0),
          rForceScreen < Const(0, width: 2),
          rForceIntMv < Const(0, width: 2),
          rOrderHintBits < Const(0, width: 4),
          rSuperres < Const(0),
          rCdef < Const(0),
          rRestoration < Const(0),
          rFilmGrain < Const(0),
          rBitDepth < Const(8, width: 5),
          rMono < Const(0),
          rColorPrim < Const(2, width: 8),
          rTransfer < Const(2, width: 8),
          rMatrix < Const(2, width: 8),
          rColorRange < Const(0),
          rSubX < Const(1),
          rSubY < Const(1),
          rChromaPos < Const(0, width: 2),
          rSepUv < Const(0),
        ],
        orElse: [
          Case(st, [
            CaseItem(sc(sIdle), [
              If(
                start,
                then: [
                  pos < Const(0, width: offW),
                  st < sc(sProfile),
                ],
              ),
            ]),
            CaseItem(sc(sProfile), [rSeqProfile < v(3), ...step(sc(sStill))]),
            CaseItem(sc(sStill), [rStill < bit0, ...step(sc(sReduced))]),
            CaseItem(sc(sReduced), [
              rReduced < bit0,
              pos < nextPos,
              If(
                bit0,
                then: [
                  rTimingPresent < Const(0),
                  rDecModelPresent < Const(0),
                  st < sc(sRedLevel),
                ],
                orElse: [st < sc(sTimingPresent)],
              ),
            ]),
            // reduced path: seq_level_idx[0] f(5), then jump to frame size.
            CaseItem(sc(sRedLevel), [...step(sc(sFrameWBits))]),
            // non-reduced: timing / decoder model / operating points
            CaseItem(sc(sTimingPresent), [
              rTimingPresent < bit0,
              pos < nextPos,
              If(
                bit0,
                then: [st < sc(sTiming0)],
                orElse: [
                  rDecModelPresent < Const(0),
                  st < sc(sInitDispPresent),
                ],
              ),
            ]),
            CaseItem(sc(sTiming0), [...step(sc(sTiming1))]),
            CaseItem(sc(sTiming1), [...step(sc(sTimingEqual))]),
            CaseItem(sc(sTimingEqual), [
              pos < nextPos,
              If(
                bit0,
                then: [lz < Const(0, width: 6), st < sc(sUvlcLz)],
                orElse: [st < sc(sDecModelPresent)],
              ),
            ]),
            CaseItem(sc(sUvlcLz), [
              pos < nextPos,
              If(
                bit0,
                then: [
                  // a 1 bit terminates the leading-zero run.
                  If(
                    lz.eq(Const(0, width: 6)),
                    then: [st < sc(sDecModelPresent)],
                    orElse: [st < sc(sUvlcVal)],
                  ),
                ],
                orElse: [lz < (lz + Const(1, width: 6)).getRange(0, 6)],
              ),
            ]),
            CaseItem(sc(sUvlcVal), [...step(sc(sDecModelPresent))]),
            CaseItem(sc(sDecModelPresent), [
              rDecModelPresent < bit0,
              pos < nextPos,
              If(
                bit0,
                then: [st < sc(sDecModel0)],
                orElse: [st < sc(sInitDispPresent)],
              ),
            ]),
            CaseItem(sc(sDecModel0), [...step(sc(sDecModel1))]),
            CaseItem(sc(sDecModel1), [...step(sc(sDecModel2))]),
            CaseItem(sc(sDecModel2), [...step(sc(sDecModel3))]),
            CaseItem(sc(sDecModel3), [...step(sc(sInitDispPresent))]),
            CaseItem(sc(sInitDispPresent), [
              rInitDispPresent < bit0,
              ...step(sc(sOpCnt)),
            ]),
            CaseItem(sc(sOpCnt), [
              opCntM1 < v(5),
              opI < Const(0, width: 5),
              ...step(sc(sOpIdc)),
            ]),
            CaseItem(sc(sOpIdc), [
              If(opI.eq(Const(0, width: 5)), then: [rOpIdc0 < v(12)]),
              ...step(sc(sOpLevel)),
            ]),
            CaseItem(sc(sOpLevel), [
              pos < nextPos,
              // seq_level_idx > 7 -> read seq_tier.
              If(
                v(5).gt(Const(7, width: 5)),
                then: [st < sc(sOpTier)],
                orElse: [st < sc(sOpDecModel)],
              ),
            ]),
            CaseItem(sc(sOpTier), [...step(sc(sOpDecModel))]),
            CaseItem(sc(sOpDecModel), [
              // branch-only (no read)
              If(
                rDecModelPresent,
                then: [st < sc(sOpDecModelBit)],
                orElse: [st < sc(sOpInitDisp)],
              ),
            ]),
            CaseItem(sc(sOpDecModelBit), [
              pos < nextPos,
              // decoder_model_present_for_this_op: unsupported if set.
              If(
                bit0,
                then: [st < sc(sUnsupported)],
                orElse: [st < sc(sOpInitDisp)],
              ),
            ]),
            CaseItem(sc(sOpInitDisp), [
              If(
                rInitDispPresent,
                then: [st < sc(sOpInitDispBit)],
                orElse: [st < sc(sOpNext)],
              ),
            ]),
            CaseItem(sc(sOpInitDispBit), [
              pos < nextPos,
              If(
                bit0,
                then: [st < sc(sOpInitDispVal)],
                orElse: [st < sc(sOpNext)],
              ),
            ]),
            CaseItem(sc(sOpInitDispVal), [...step(sc(sOpNext))]),
            CaseItem(sc(sOpNext), [
              // branch-only: loop while i < op_cnt_minus_1.
              If(
                opI.lt(opCntM1),
                then: [
                  opI < (opI + Const(1, width: 5)).getRange(0, 5),
                  st < sc(sOpIdc),
                ],
                orElse: [st < sc(sFrameWBits)],
              ),
            ]),
            CaseItem(sc(sFrameWBits), [
              rWBits < v(4),
              ...step(sc(sFrameHBits)),
            ]),
            CaseItem(sc(sFrameHBits), [rHBits < v(4), ...step(sc(sMaxW))]),
            CaseItem(sc(sMaxW), [rMaxW < v(32), ...step(sc(sMaxH))]),
            CaseItem(sc(sMaxH), [rMaxH < v(32), ...step(sc(sFrameIdPresent))]),
            CaseItem(sc(sFrameIdPresent), [
              If(
                rReduced,
                then: [rFrameIdPresent < Const(0), st < sc(sSuperblock)],
                orElse: [
                  rFrameIdPresent < bit0,
                  pos < nextPos,
                  If(
                    bit0,
                    then: [st < sc(sDeltaFrameId)],
                    orElse: [st < sc(sSuperblock)],
                  ),
                ],
              ),
            ]),
            CaseItem(sc(sDeltaFrameId), [
              rDeltaFrameId < v(4),
              ...step(sc(sAddFrameId)),
            ]),
            CaseItem(sc(sAddFrameId), [
              rAddFrameId < v(3),
              ...step(sc(sSuperblock)),
            ]),
            CaseItem(sc(sSuperblock), [
              rUse128 < bit0,
              ...step(sc(sFilterIntra)),
            ]),
            CaseItem(sc(sFilterIntra), [
              rFilterIntra < bit0,
              ...step(sc(sIntraEdge)),
            ]),
            CaseItem(sc(sIntraEdge), [
              rIntraEdge < bit0,
              pos < nextPos,
              If(
                rReduced,
                then: [
                  rInterintra < Const(0),
                  rMasked < Const(0),
                  rWarped < Const(0),
                  rDualFilter < Const(0),
                  rOrderHint < Const(0),
                  rJntComp < Const(0),
                  rRefFrameMvs < Const(0),
                  rForceScreen < Const(selectScreenContentTools, width: 2),
                  rForceIntMv < Const(selectIntegerMv, width: 2),
                  rOrderHintBits < Const(0, width: 4),
                  st < sc(sEnableSuperres),
                ],
                orElse: [st < sc(sInterintra)],
              ),
            ]),
            CaseItem(sc(sInterintra), [
              rInterintra < bit0,
              ...step(sc(sMasked)),
            ]),
            CaseItem(sc(sMasked), [rMasked < bit0, ...step(sc(sWarped))]),
            CaseItem(sc(sWarped), [rWarped < bit0, ...step(sc(sDualFilter))]),
            CaseItem(sc(sDualFilter), [
              rDualFilter < bit0,
              ...step(sc(sOrderHint)),
            ]),
            CaseItem(sc(sOrderHint), [
              rOrderHint < bit0,
              pos < nextPos,
              If(
                bit0,
                then: [st < sc(sJntComp)],
                orElse: [st < sc(sChooseScreen)],
              ),
            ]),
            CaseItem(sc(sJntComp), [
              rJntComp < bit0,
              ...step(sc(sRefFrameMvs)),
            ]),
            CaseItem(sc(sRefFrameMvs), [
              rRefFrameMvs < bit0,
              ...step(sc(sChooseScreen)),
            ]),
            CaseItem(sc(sChooseScreen), [
              pos < nextPos,
              If(
                bit0,
                then: [
                  rForceScreen < Const(selectScreenContentTools, width: 2),
                  st < sc(sForceIntCheck),
                ],
                orElse: [st < sc(sForceScreenVal)],
              ),
            ]),
            CaseItem(sc(sForceScreenVal), [
              rForceScreen < bit0.zeroExtend(2),
              ...step(sc(sForceIntCheck)),
            ]),
            CaseItem(sc(sForceIntCheck), [
              // branch-only
              If(
                rForceScreen.gt(Const(0, width: 2)),
                then: [st < sc(sChooseIntMv)],
                orElse: [
                  rForceIntMv < Const(selectIntegerMv, width: 2),
                  st < sc(sOrderHintBitsCheck),
                ],
              ),
            ]),
            CaseItem(sc(sChooseIntMv), [
              pos < nextPos,
              If(
                bit0,
                then: [
                  rForceIntMv < Const(selectIntegerMv, width: 2),
                  st < sc(sOrderHintBitsCheck),
                ],
                orElse: [st < sc(sForceIntMvVal)],
              ),
            ]),
            CaseItem(sc(sForceIntMvVal), [
              rForceIntMv < bit0.zeroExtend(2),
              ...step(sc(sOrderHintBitsCheck)),
            ]),
            CaseItem(sc(sOrderHintBitsCheck), [
              // branch-only
              If(
                rOrderHint,
                then: [st < sc(sOrderHintBits)],
                orElse: [
                  rOrderHintBits < Const(0, width: 4),
                  st < sc(sEnableSuperres),
                ],
              ),
            ]),
            CaseItem(sc(sOrderHintBits), [
              rOrderHintBits <
                  (v(3).zeroExtend(4) + Const(1, width: 4)).getRange(0, 4),
              ...step(sc(sEnableSuperres)),
            ]),
            CaseItem(sc(sEnableSuperres), [
              rSuperres < bit0,
              ...step(sc(sEnableCdef)),
            ]),
            CaseItem(sc(sEnableCdef), [
              rCdef < bit0,
              ...step(sc(sEnableRestoration)),
            ]),
            CaseItem(sc(sEnableRestoration), [
              rRestoration < bit0,
              ...step(sc(sColorHighBd)),
            ]),
            // color_config
            CaseItem(sc(sColorHighBd), [
              pos < nextPos,
              If(
                rSeqProfile.eq(Const(2, width: 3)) & bit0,
                then: [st < sc(sColorTwelve)],
                orElse: [
                  rBitDepth <
                      mux<Logic>(bit0, Const(10, width: 5), Const(8, width: 5)),
                  st < sc(sColorMono),
                ],
              ),
            ]),
            CaseItem(sc(sColorTwelve), [
              rBitDepth <
                  mux<Logic>(bit0, Const(12, width: 5), Const(10, width: 5)),
              ...step(sc(sColorMono)),
            ]),
            CaseItem(sc(sColorMono), [
              If(
                rSeqProfile.eq(Const(1, width: 3)),
                then: [rMono < Const(0), st < sc(sColorDescPresent)],
                orElse: [
                  rMono < bit0,
                  pos < nextPos,
                  st < sc(sColorDescPresent),
                ],
              ),
            ]),
            CaseItem(sc(sColorDescPresent), [
              pos < nextPos,
              If(
                bit0,
                then: [st < sc(sColorPrim)],
                orElse: [
                  rColorPrim < Const(2, width: 8),
                  rTransfer < Const(2, width: 8),
                  rMatrix < Const(2, width: 8),
                  st < sc(sColorAfterDesc),
                ],
              ),
            ]),
            CaseItem(sc(sColorPrim), [
              rColorPrim < v(8),
              ...step(sc(sColorTransfer)),
            ]),
            CaseItem(sc(sColorTransfer), [
              rTransfer < v(8),
              ...step(sc(sColorMatrix)),
            ]),
            CaseItem(sc(sColorMatrix), [
              rMatrix < v(8),
              ...step(sc(sColorAfterDesc)),
            ]),
            CaseItem(sc(sColorAfterDesc), [
              // branch-only
              If(
                rMono,
                then: [st < sc(sColorMonoRange)],
                orElse: [
                  If(
                    rColorPrim.eq(Const(1, width: 8)) &
                        rTransfer.eq(Const(13, width: 8)) &
                        rMatrix.eq(Const(0, width: 8)),
                    then: [
                      rColorRange < Const(1),
                      rSubX < Const(0),
                      rSubY < Const(0),
                      st < sc(sSeparateUv),
                    ],
                    orElse: [st < sc(sColorRange)],
                  ),
                ],
              ),
            ]),
            CaseItem(sc(sColorMonoRange), [
              rColorRange < bit0,
              rSubX < Const(1),
              rSubY < Const(1),
              rChromaPos < Const(0, width: 2),
              rSepUv < Const(0),
              ...step(sc(sFilmGrain)),
            ]),
            CaseItem(sc(sColorRange), [
              rColorRange < bit0,
              pos < nextPos,
              If(
                rSeqProfile.eq(Const(0, width: 3)),
                then: [
                  rSubX < Const(1),
                  rSubY < Const(1),
                  st < sc(sChromaPosCheck),
                ],
                orElse: [
                  If(
                    rSeqProfile.eq(Const(1, width: 3)),
                    then: [
                      rSubX < Const(0),
                      rSubY < Const(0),
                      st < sc(sChromaPosCheck),
                    ],
                    orElse: [
                      // profile 2
                      If(
                        rBitDepth.eq(Const(12, width: 5)),
                        then: [st < sc(sSubX)],
                        orElse: [
                          rSubX < Const(1),
                          rSubY < Const(0),
                          st < sc(sChromaPosCheck),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(sc(sSubX), [
              rSubX < bit0,
              pos < nextPos,
              If(
                bit0,
                then: [st < sc(sSubY)],
                orElse: [rSubY < Const(0), st < sc(sChromaPosCheck)],
              ),
            ]),
            CaseItem(sc(sSubY), [rSubY < bit0, ...step(sc(sChromaPosCheck))]),
            CaseItem(sc(sChromaPosCheck), [
              // branch-only
              If(
                rSubX & rSubY,
                then: [st < sc(sChromaPos)],
                orElse: [st < sc(sSeparateUv)],
              ),
            ]),
            CaseItem(sc(sChromaPos), [
              rChromaPos < v(2),
              ...step(sc(sSeparateUv)),
            ]),
            CaseItem(sc(sSeparateUv), [rSepUv < bit0, ...step(sc(sFilmGrain))]),
            CaseItem(sc(sFilmGrain), [rFilmGrain < bit0, ...step(sc(sDone))]),
            CaseItem(sc(sDone), [
              If(~start, then: [st < sc(sIdle)]),
            ]),
            CaseItem(sc(sUnsupported), [
              If(~start, then: [st < sc(sIdle)]),
            ]),
          ]),
        ],
      ),
    ]);
  }
}
