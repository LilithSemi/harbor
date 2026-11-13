import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'mv_projection.dart';

/// Harbor bit-exact AV1 temporal-motion-field setup (libaom
/// `av1_setup_motion_field` + `motion_field_projection` + `get_block_position`).
///
/// Projects the reference frames' stored per-8x8 motion vectors onto the current
/// frame's 8x8 grid to build the temporal MV field (`tpl_mvs`) sampled by
/// find_mv_refs. Reuses [HarborMvProjection] (the scalar `get_mv_projection`) as
/// the projection kernel.
///
/// The current gate feeds the reference frames' stored MV grids + order hints as
/// precomputed test inputs. The full in-HW DPB is a later gate.
///
/// AV1 runs up to 5 projection passes in a fixed order (LAST, BWDREF, ALTREF2,
/// ALTREF, LAST2), gated by order-hint distances and a running MFMV stamp
/// counter. Later passes overwrite earlier ones at colliding grid positions.
/// This module walks the passes and the (mvsRows x mvsCols) source grid one cell
/// per cycle, so the write order is last-write-wins exactly as the AV1 loops.
///
/// Ports (packed buses, slot index s in 0..6 == AV1 ref LAST..ALTREF):
///   clk, reset, start            : control
///   cur_order   [ohBits]         : current frame order hint
///   ref_order   [7*ohBits]       : per-slot order hint (0 if absent)
///   ref_saved   [7*7*ohBits]     : per-slot savedOrderHints[0..6]
///   ref_usable  [7]              : slot projectable (present & inter & mvs &
///                                  matching mi dims) == projection would run
///   ref_present [7]              : slot buffer present (for LAST overlay/stamp)
///   ref_mvs     [5*cells*36]     : per-pass source grid, pass p in 0..4 maps to
///                                  slot passSlot[p], each cell = {col[16], row[16],
///                                  rf[4]} (rf two's-complement, <=0 skipped)
///   done                         : pulses/holds when the field is built
///   tpl_valid   [gridR*gridC]    : per-8x8 validity
///   tpl_mvrow   [gridR*gridC*16] : stored fwd MV row (source MV, signed)
///   tpl_mvcol   [gridR*gridC*16] : stored fwd MV col
///   tpl_refoff  [gridR*gridC*6]  : frame distance to the source MV's reference
class HarborMotionField extends BridgeModule {
  /// Current frame mi rows (== reference frames' mi rows for a usable ref).
  final int miRows;

  /// Current frame mi cols.
  final int miCols;

  /// `seq.orderHintBits` (get_relative_dist modulus width).
  final int orderHintBits;

  /// Source motion grid rows: `(miRows + 1) >> 1`.
  int get mvsRows => (miRows + 1) >> 1;

  /// Source motion grid cols: `(miCols + 1) >> 1`.
  int get mvsCols => (miCols + 1) >> 1;

  /// Output field rows: `miRows >> 1`.
  int get gridR => miRows >> 1;

  /// Output field cols: `miCols >> 1`.
  int get gridC => miCols >> 1;

  /// `MAX_FRAME_DISTANCE`.
  static const int _maxFrameDistance = 31;

  /// Pass order -> AV1 ref slot (0-based: LAST=0..ALTREF=6).
  /// LAST, BWDREF, ALTREF2, ALTREF, LAST2.
  static const List<int> passSlot = [0, 4, 5, 6, 1];

  /// Pass order -> projection direction (2 = backward/negate, 0 = forward).
  static const List<int> passDir = [2, 0, 0, 0, 2];

  HarborMotionField({
    required this.miRows,
    required this.miCols,
    required this.orderHintBits,
    String? name,
  }) : super('HarborMotionField', name: name ?? 'motion_field') {
    final oh = orderHintBits;
    final cells = mvsRows * mvsCols;
    final gcells = gridR * gridC;

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('cur_order', PortDirection.input, width: oh);
    createPort('ref_order', PortDirection.input, width: 7 * oh);
    createPort('ref_saved', PortDirection.input, width: 7 * 7 * oh);
    createPort('ref_usable', PortDirection.input, width: 7);
    createPort('ref_present', PortDirection.input, width: 7);
    createPort('ref_mvs', PortDirection.input, width: 5 * cells * 36);
    addOutput('done');
    addOutput('tpl_valid', width: gcells);
    addOutput('tpl_mvrow', width: gcells * 16);
    addOutput('tpl_mvcol', width: gcells * 16);
    addOutput('tpl_refoff', width: gcells * 6);

    final clk = input('clk');
    final reset = input('reset');

    // get_relative_dist(a, c): signed, modulo 2^ohBits.
    final rw = oh + 4; // signed working width
    Logic relDist(Logic a, Logic c) {
      final diff = (a.zeroExtend(rw) - c.zeroExtend(rw)).getRange(0, rw);
      final lo = diff & Const((1 << (oh - 1)) - 1, width: rw);
      final hi = diff & Const(1 << (oh - 1), width: rw);
      return (lo - hi).getRange(0, rw); // signed, |.| < 2^(oh-1)
    }

    Logic sgtz(Logic v) => ~v[rw - 1] & v.or(); // signed > 0

    // packed-bus readers
    final refOrder = input('ref_order');
    final refSaved = input('ref_saved');
    final refUsable = input('ref_usable');
    final refPresent = input('ref_present');
    final refMvs = input('ref_mvs');
    final curOrder = input('cur_order');

    Logic ordOf(int slot) => refOrder.getRange(slot * oh, slot * oh + oh);
    Logic savedOf(int slot, int j) {
      final base = (slot * 7 + j) * oh;
      return refSaved.getRange(base, base + oh);
    }

    // fsm registers
    const stW = 3;
    const sIdle = 0, sSetup = 1, sScan = 2, sPassEnd = 3, sDone = 4;
    final st = Logic(name: 'st', width: stW);
    final rcw = 5; // counter width (mvsRows/Cols <= 16 for a 64x64 SB path)
    final pass = Logic(name: 'pass', width: 3);
    final br = Logic(name: 'br', width: rcw);
    final bc = Logic(name: 'bc', width: rcw);
    final refStamp = Logic(name: 'ref_stamp', width: 4); // signed small

    // Output field registers.
    final gValid = [for (var i = 0; i < gcells; i++) Logic(name: 'gv_$i')];
    final gRow = [
      for (var i = 0; i < gcells; i++) Logic(name: 'gr_$i', width: 16),
    ];
    final gCol = [
      for (var i = 0; i < gcells; i++) Logic(name: 'gc_$i', width: 16),
    ];
    final gOff = [
      for (var i = 0; i < gcells; i++) Logic(name: 'go_$i', width: 6),
    ];

    // per-pass constants selected by the `pass` register
    Logic passIs(int p) => pass.eq(Const(p, width: 3));
    Logic slotOrder = ordOf(passSlot[0]);
    Logic usableSel = refUsable[passSlot[0]];
    for (var p = 1; p < 5; p++) {
      slotOrder = mux(passIs(p), ordOf(passSlot[p]), slotOrder);
      usableSel = mux(passIs(p), refUsable[passSlot[p]], usableSel);
    }
    // startToCur = relDist(startOrder, cur), dir==2 -> negate.
    final stcRaw = relDist(slotOrder, curOrder);
    final dirNeg = passIs(0) | passIs(4); // passDir==2
    final startToCur = mux(
      dirNeg,
      (~stcRaw + Const(1, width: rw)).getRange(0, rw),
      stcRaw,
    );
    final signBias = dirNeg; // dir >> 1

    // refOffset[rf] = relDist(startOrder, savedOrderHints[rf-1]) for rf in 1..7.
    // savedOf selects by slot. Select slot's saved table by pass.
    Logic savedSel(int j) {
      Logic v = savedOf(passSlot[0], j);
      for (var p = 1; p < 5; p++) {
        v = mux(passIs(p), savedOf(passSlot[p], j), v);
      }
      return v;
    }

    final refOffset = [
      for (var j = 0; j < 7; j++) relDist(slotOrder, savedSel(j)),
    ];

    // current source cell (pass, br, bc) -> {rf, fwdRow, fwdCol}
    // Linear cell index within the pass grid, and the flat bus offset.
    final cellIdx =
        (br.zeroExtend(12) * Const(mvsCols, width: 12)).getRange(0, 12) +
        bc.zeroExtend(12);
    // Full index across passes: pass*cells + cellIdx.
    final fullIdx =
        (pass.zeroExtend(12) * Const(cells, width: 12)).getRange(0, 12) +
        cellIdx;
    Logic cellField(int lo, int hi) {
      // mux over all 5*cells entries.
      Logic v = refMvs.getRange(lo, hi);
      for (var i = 1; i < 5 * cells; i++) {
        v = mux(
          fullIdx.eq(Const(i, width: 12)),
          refMvs.getRange(i * 36 + lo, i * 36 + hi),
          v,
        );
      }
      return v;
    }

    final cellRf = cellField(0, 4); // 4-bit two's complement
    final cellRow = cellField(4, 20); // 16-bit signed
    final cellCol = cellField(20, 36);

    // rf as unsigned index 0..7 (rf<=0 skipped anyway).
    final rfIdx = cellRf.getRange(0, 3);
    final rfSkip = cellRf[3] | cellRf.eq(Const(0, width: 4)); // rf <= refIntra
    // frameOff = refOffset[rf] (rf in 1..7 -> refOffset[rf-1]).
    Logic frameOff = refOffset[0];
    for (var rf = 2; rf <= 7; rf++) {
      frameOff = mux(
        rfIdx.eq(Const(rf, width: 3)),
        refOffset[rf - 1],
        frameOff,
      );
    }
    // Guards: |frameOff|<=31 && frameOff>0 && |startToCur|<=31.
    Logic absLe31(Logic v) {
      final neg = v[rw - 1];
      final mag = mux(neg, (~v + Const(1, width: rw)).getRange(0, rw), v);
      return mag.lte(Const(_maxFrameDistance, width: rw));
    }

    final offOk = sgtz(frameOff) & absLe31(frameOff) & absLe31(startToCur);

    // projection kernel (shared)
    final proj = HarborMvProjection(name: 'mf_proj');
    proj.input('mv_row').srcConnection! <= cellRow;
    proj.input('mv_col').srcConnection! <= cellCol;
    proj.input('num').srcConnection! <= startToCur.getRange(0, 8);
    proj.input('den').srcConnection! <= frameOff.getRange(0, 6);
    final projRow = proj.output('proj_row'); // signed 16
    final projCol = proj.output('proj_col');

    // get_block_position
    const pw = 12; // signed position width
    Logic offToward(Logic mv) {
      final neg = mv[15];
      final mag = mux(neg, (~mv + Const(1, width: 16)).getRange(0, 16), mv);
      // |mv| <= 16383 so (mag >> 6) < 256 fits in pw bits (unsigned).
      final sh = (mag >>> 6).getRange(0, pw);
      return mux(neg, (~sh + Const(1, width: pw)).getRange(0, pw), sh);
    }

    final rowOff = offToward(projRow);
    final colOff = offToward(projCol);
    final brS = br.zeroExtend(pw);
    final bcS = bc.zeroExtend(pw);
    final posRow = mux(
      signBias,
      (brS - rowOff).getRange(0, pw),
      (brS + rowOff).getRange(0, pw),
    );
    final posCol = mux(
      signBias,
      (bcS - colOff).getRange(0, pw),
      (bcS + colOff).getRange(0, pw),
    );
    // base = (blk & ~7)
    final baseRow = (brS & Const(-8, width: pw)).getRange(0, pw);
    final baseCol = (bcS & Const(-8, width: pw)).getRange(0, pw);
    // Signed compares at position width (sign bit at index pw of the diff).
    Logic sdiff(Logic a, Logic b) =>
        (a.signExtend(pw + 1) - b.signExtend(pw + 1)).getRange(0, pw + 1);
    Logic sge(Logic a, Logic b) => ~sdiff(a, b)[pw]; // a >= b
    Logic slt(Logic a, Logic b) => sdiff(a, b)[pw]; // a < b
    final inFrame =
        sge(posRow, Const(0, width: pw)) &
        slt(posRow, Const(gridR, width: pw)) &
        sge(posCol, Const(0, width: pw)) &
        slt(posCol, Const(gridC, width: pw));
    final inWindow =
        sge(posRow, baseRow) &
        slt(posRow, (baseRow + Const(8, width: pw)).getRange(0, pw)) &
        sge(posCol, (baseCol - Const(8, width: pw)).getRange(0, pw)) &
        slt(posCol, (baseCol + Const(16, width: pw)).getRange(0, pw));
    final writeCell =
        st.eq(Const(sScan, width: stW)) & ~rfSkip & offOk & inFrame & inWindow;

    // pass-level control (shouldScan / stampDec)
    // p0 LAST: overlay = savedOf(LAST,6) == order(GOLDEN=slot3).
    final isOverlay = savedOf(0, 6).eq(ordOf(3));
    final present0 = refPresent[0];
    final usable0 = refUsable[0];
    final guardBwd = sgtz(relDist(ordOf(4), curOrder)); // BWDREF slot4
    final guardAlt2 = sgtz(relDist(ordOf(5), curOrder)); // ALTREF2 slot5
    final guardAlt = sgtz(relDist(ordOf(6), curOrder)); // ALTREF slot6
    // refStamp >= 0 (signed): the top bit of its sign-extension.
    final stampNonNeg = ~refStamp.signExtend(rw)[rw - 1];

    // shouldScan / stampDec per pass, using the *current* refStamp reg.
    final shouldScan = mux(
      passIs(0),
      present0 & ~isOverlay & usable0,
      mux(
        passIs(1),
        guardBwd & refUsable[4],
        mux(
          passIs(2),
          guardAlt2 & refUsable[5],
          mux(
            passIs(3),
            guardAlt & stampNonNeg & refUsable[6],
            /* p4 */ stampNonNeg & refUsable[1],
          ),
        ),
      ),
    );
    final stampDec = mux(
      passIs(0),
      present0,
      mux(
        passIs(1),
        guardBwd & refUsable[4],
        mux(
          passIs(2),
          guardAlt2 & refUsable[5],
          mux(passIs(3), guardAlt & stampNonNeg & refUsable[6], Const(0)),
        ),
      ),
    );

    // outputs
    output('done') <= st.eq(Const(sDone, width: stW));
    Logic pack(List<Logic> g) =>
        [for (var i = g.length - 1; i >= 0; i--) g[i]].concat();
    output('tpl_valid') <= pack(gValid);
    output('tpl_mvrow') <= pack(gRow);
    output('tpl_mvcol') <= pack(gCol);
    output('tpl_refoff') <= pack(gOff);

    // last cell of a pass grid?
    final lastCell =
        br.eq(Const(mvsRows - 1, width: rcw)) &
        bc.eq(Const(mvsCols - 1, width: rcw));
    final lastCol = bc.eq(Const(mvsCols - 1, width: rcw));

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: stW),
          pass < Const(0, width: 3),
          br < Const(0, width: rcw),
          bc < Const(0, width: rcw),
          refStamp < Const(0, width: 4),
          for (var i = 0; i < gcells; i++) ...[
            gValid[i] < Const(0),
            gRow[i] < Const(0, width: 16),
            gCol[i] < Const(0, width: 16),
            gOff[i] < Const(0, width: 6),
          ],
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(sIdle, width: stW), [
              If(
                input('start'),
                then: [
                  for (var i = 0; i < gcells; i++) ...[
                    gValid[i] < Const(0),
                    gRow[i] < Const(0, width: 16),
                    gCol[i] < Const(0, width: 16),
                    gOff[i] < Const(0, width: 6),
                  ],
                  refStamp < Const(2, width: 4), // MFMV_STACK_SIZE - 1
                  pass < Const(0, width: 3),
                  br < Const(0, width: rcw),
                  bc < Const(0, width: rcw),
                  st < Const(sSetup, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(sSetup, width: stW), [
              br < Const(0, width: rcw),
              bc < Const(0, width: rcw),
              If(
                shouldScan,
                then: [st < Const(sScan, width: stW)],
                orElse: [st < Const(sPassEnd, width: stW)],
              ),
            ]),
            CaseItem(Const(sScan, width: stW), [
              // write current cell if projection lands.
              for (var i = 0; i < gcells; i++)
                If(
                  writeCell &
                      posRow.eq(Const(i ~/ gridC, width: pw)) &
                      posCol.eq(Const(i % gridC, width: pw)),
                  then: [
                    gValid[i] < Const(1),
                    gRow[i] < cellRow,
                    gCol[i] < cellCol,
                    gOff[i] < frameOff.getRange(0, 6),
                  ],
                ),
              // advance cell.
              If(
                lastCell,
                then: [st < Const(sPassEnd, width: stW)],
                orElse: [
                  If(
                    lastCol,
                    then: [
                      bc < Const(0, width: rcw),
                      br < (br + Const(1, width: rcw)).getRange(0, rcw),
                    ],
                    orElse: [bc < (bc + Const(1, width: rcw)).getRange(0, rcw)],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sPassEnd, width: stW), [
              If(
                stampDec,
                then: [
                  refStamp < (refStamp - Const(1, width: 4)).getRange(0, 4),
                ],
              ),
              If(
                pass.eq(Const(4, width: 3)),
                then: [st < Const(sDone, width: stW)],
                orElse: [
                  pass < (pass + Const(1, width: 3)).getRange(0, 3),
                  st < Const(sSetup, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(sDone, width: stW), [st < Const(sDone, width: stW)]),
          ]),
        ],
      ),
    ]);
  }
}
