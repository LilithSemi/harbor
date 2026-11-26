import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 per-frame MV store (libaom `av1_copy_frame_mvs`).
/// Combinational.
///
/// Reduces the decoded per-mi motion field into the per-8x8 MV grid that FUTURE
/// frames' TMVP projects (see [HarborMotionField]). For each 8x8 output cell it
/// samples the bottom-right mi of the cell (the last-decoded sub-block in
/// z-order, which `av1_copy_frame_mvs` lets win), and keeps the MV of a
/// past-side single reference (skipping intra, future/equal-order refs via
/// `ref_frame_side`, and out-of-range MVs). The second reference (idx 1) wins
/// over the first when both qualify, matching `av1_copy_frame_mvs`' last write.
///
/// This gate feeds the per-mi grids + `ref_frame_side` as inputs (the decoded
/// values). The full in-HW DPB / order-hint side derivation is a later gate.
///
/// Ports (packed, cell index i in row-major over the gridR x gridC 8x8 grid,
/// each per-mi field is sampled at the cell's bottom-right mi):
///   mi_inter [gcells]        : bottom-right mi is_inter
///   mi_ref0  [gcells*4]      : ref frame 0 (two's complement, -1 = intra/none)
///   mi_ref1  [gcells*4]      : ref frame 1
///   mi_mvr0/mvc0/mvr1/mvc1 [gcells*16] : the two references' MVs (signed)
///   side     [7*2]           : ref_frame_side[LAST..ALTREF] (-1/0/+1, signed)
///   ref_grid [gcells*4]      : stored ref frame per cell (-1 = none)
///   mv_row   [gcells*16]     : stored MV row (0 when none)
///   mv_col   [gcells*16]     : stored MV col
class HarborStoreFrameMvs extends BridgeModule {
  /// Current frame mi rows.
  final int miRows;

  /// Current frame mi cols.
  final int miCols;

  /// Output grid rows: `(miRows + 1) >> 1`.
  int get gridR => (miRows + 1) >> 1;

  /// Output grid cols: `(miCols + 1) >> 1`.
  int get gridC => (miCols + 1) >> 1;

  /// `REFMVS_LIMIT = (1 << 12) - 1`.
  static const int _refmvsLimit = (1 << 12) - 1;

  HarborStoreFrameMvs({
    required this.miRows,
    required this.miCols,
    String? name,
  }) : super('HarborStoreFrameMvs', name: name ?? 'store_frame_mvs') {
    final n = gridR * gridC;
    createPort('mi_inter', PortDirection.input, width: n);
    createPort('mi_ref0', PortDirection.input, width: n * 4);
    createPort('mi_ref1', PortDirection.input, width: n * 4);
    createPort('mi_mvr0', PortDirection.input, width: n * 16);
    createPort('mi_mvc0', PortDirection.input, width: n * 16);
    createPort('mi_mvr1', PortDirection.input, width: n * 16);
    createPort('mi_mvc1', PortDirection.input, width: n * 16);
    createPort('side', PortDirection.input, width: 7 * 2);
    addOutput('ref_grid', width: n * 4);
    addOutput('mv_row', width: n * 16);
    addOutput('mv_col', width: n * 16);

    final miInter = input('mi_inter');
    final miRef0 = input('mi_ref0');
    final miRef1 = input('mi_ref1');
    final miMvr0 = input('mi_mvr0');
    final miMvc0 = input('mi_mvc0');
    final miMvr1 = input('mi_mvr1');
    final miMvc1 = input('mi_mvc1');
    final side = input('side');

    // side[rf] != 0 for rf in 1..7 (side packed at index rf-1, 2-bit signed).
    Logic sideNonZero(Logic rf) {
      Logic v = Const(0);
      for (var rf1 = 1; rf1 <= 7; rf1++) {
        final s = side.getRange((rf1 - 1) * 2, (rf1 - 1) * 2 + 2);
        v = mux(rf.eq(Const(rf1, width: 4)), s.or(), v);
      }
      return v;
    }

    Logic absLeLimit(Logic mv) {
      final neg = mv[15];
      final mag = mux(neg, (~mv + Const(1, width: 16)).getRange(0, 16), mv);
      return mag.lte(Const(_refmvsLimit, width: 16));
    }

    Logic rfPos(Logic rf) => ~rf[3] & rf.or(); // signed rf > 0

    final refOut = <Logic>[];
    final rowOut = <Logic>[];
    final colOut = <Logic>[];
    for (var i = 0; i < n; i++) {
      final inter = miInter[i];
      final rf0 = miRef0.getRange(i * 4, i * 4 + 4);
      final rf1 = miRef1.getRange(i * 4, i * 4 + 4);
      final r0 = miMvr0.getRange(i * 16, i * 16 + 16);
      final c0 = miMvc0.getRange(i * 16, i * 16 + 16);
      final r1 = miMvr1.getRange(i * 16, i * 16 + 16);
      final c1 = miMvc1.getRange(i * 16, i * 16 + 16);
      final valid0 =
          inter &
          rfPos(rf0) &
          ~sideNonZero(rf0) &
          absLeLimit(r0) &
          absLeLimit(c0);
      final valid1 =
          inter &
          rfPos(rf1) &
          ~sideNonZero(rf1) &
          absLeLimit(r1) &
          absLeLimit(c1);
      // idx 1 (ref1) wins over idx 0 (last write in av1_copy_frame_mvs).
      refOut.add(
        mux(valid1, rf1, mux(valid0, rf0, Const(-1, width: 4).getRange(0, 4))),
      );
      rowOut.add(mux(valid1, r1, mux(valid0, r0, Const(0, width: 16))));
      colOut.add(mux(valid1, c1, mux(valid0, c0, Const(0, width: 16))));
    }
    Logic pack(List<Logic> g) =>
        [for (var i = g.length - 1; i >= 0; i--) g[i]].concat();
    output('ref_grid') <= pack(refOut);
    output('mv_row') <= pack(rowOut);
    output('mv_col') <= pack(colOut);
  }
}
