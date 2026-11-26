import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 directional intra prediction with RUNTIME angle
/// (angle_delta != 0), bd 8, NO intra edge filter / NO upsample.
///
/// Faithful port of libaom `av1_dr_prediction_z1/z2/z3` (`dr_predictor`) for the
/// eight directional modes V/H/D45/D135/D113/D157/D203/D67 with a runtime
/// `angle_delta` (-3..3). The angle = `mode_to_angle[mode] + angle_delta*3`
/// selects dx/dy from `dr_intra_derivative` and the z1 (angle<90) / z2
/// (90<angle<180) / z3 (180<angle<270) / V (90) / H (180) kernel; every base
/// index and interpolation `shift` is computed at runtime per pixel.
///
/// Inputs are the already-constructed reference arrays (length 2*bs each, with
/// the libaom extension), `above`/`left`, plus the `corner` (above_row[-1]).
/// Ports: `mode` (4b, 1..8), `angle_delta` (4b signed two's complement, -3..3),
/// `above`/`left` (2*bs pixels, 8b), `corner` (8b) -> `pred` (bs*bs, 8b).
/// Combinational.
class HarborIntraDirAngle extends BridgeModule {
  /// Block size (square): 4 or 8 (16 builds slowly, same logic).
  final int bs;

  static const _modeToAngle = [0, 90, 180, 45, 135, 113, 157, 203, 67];
  static const _drDeriv = [
    0, 0, 0, 1023, 0, 0, 547, 0, 0, 372, 0, 0, 0, 0, 273, 0, 0, 215, 0, 0, //
    178, 0, 0, 151, 0, 0, 132, 0, 0, 116, 0, 0, 102, 0, 0, 0, 90, 0, 0, 80, //
    0, 0, 71, 0, 0, 64, 0, 0, 57, 0, 0, 51, 0, 0, 45, 0, 0, 0, 40, 0, 0, 35, //
    0, 0, 31, 0, 0, 27, 0, 0, 23, 0, 0, 19, 0, 0, 15, 0, 0, 0, 0, 11, 0, 0, //
    7, 0, 0, 3, 0, 0,
  ];

  HarborIntraDirAngle({required this.bs, String? name})
    : assert(bs == 4 || bs == 8 || bs == 16, 'bs 4/8/16'),
      super('HarborIntraDirAngle', name: name ?? 'intra_dir_angle_$bs') {
    createPort('mode', PortDirection.input, width: 4);
    createPort('angle_delta', PortDirection.input, width: 4);
    createPort('above', PortDirection.input, width: 2 * bs * 8);
    createPort('left', PortDirection.input, width: 2 * bs * 8);
    createPort('corner', PortDirection.input, width: 8);
    addOutput('pred', width: bs * bs * 8);

    final mode = input('mode');
    final angleDelta = input('angle_delta'); // signed 4-bit
    Logic aRow(int j) => input('above').getRange(j * 8, j * 8 + 8); // 0..2bs-1
    Logic lCol(int j) => input('left').getRange(j * 8, j * 8 + 8);
    final corner = input('corner');

    const w = 20; // signed working width for z2 (handles negative x)
    Logic romSel(List<int> table, Logic idx, int wd) {
      Logic v = Const(table.last, width: wd);
      for (var i = table.length - 2; i >= 0; i--) {
        v = mux(
          idx.eq(Const(i, width: idx.width)),
          Const(table[i], width: wd),
          v,
        );
      }
      return v;
    }

    // angle = mode_to_angle[mode] + angle_delta*3  (range ~36..212).
    final baseAngle = romSel(_modeToAngle, mode, 9); // 9-bit, 0..203
    final deltaS = angleDelta.signExtend(9); // signed
    final delta3 = (deltaS * Const(3, width: 9)).getRange(0, 9); // signed
    final angle = (baseAngle.zeroExtend(10) + delta3.signExtend(10)).getRange(
      0,
      10,
    );
    Logic angEq(int a) => angle.eq(Const(a, width: 10));
    Logic angLt(int a) => angle.lt(Const(a, width: 10));
    Logic angGt(int a) => angle.gt(Const(a, width: 10));
    final isZ1 = angGt(0) & angLt(90);
    final isZ2 = angGt(90) & angLt(180);
    final isZ3 = angGt(180) & angLt(270);
    final isV = angEq(90);

    // dx / dy from dr_intra_derivative.
    final dxIdx = mux(
      isZ1,
      angle.getRange(0, 8),
      (Const(180, width: 9) - angle.getRange(0, 9)).getRange(0, 8),
    ); // 0..89
    final dyIdx = mux(
      isZ2,
      (angle.getRange(0, 9) - Const(90, width: 9)).getRange(0, 8),
      (Const(270, width: 10) - angle).getRange(0, 8),
    );
    final dx = mux(
      isZ1 | isZ2,
      romSel(_drDeriv, dxIdx, 11),
      Const(1, width: 11),
    );
    final dy = mux(
      isZ2 | isZ3,
      romSel(_drDeriv, dyIdx, 11),
      Const(1, width: 11),
    );

    final maxBase = 2 * bs - 1;
    // Unsigned clamped reader for z1/z3 (base >= 0): selList over 0..2bs-1,
    // values >= 2bs-1 saturate to the last (matches libaom edge extension).
    Logic aClamp(Logic base) {
      Logic v = aRow(2 * bs - 1);
      for (var j = 2 * bs - 2; j >= 0; j--) {
        v = mux(base.eq(Const(j, width: base.width)), aRow(j), v);
      }
      return v;
    }

    Logic lClamp(Logic base) {
      Logic v = lCol(2 * bs - 1);
      for (var j = 2 * bs - 2; j >= 0; j--) {
        v = mux(base.eq(Const(j, width: base.width)), lCol(j), v);
      }
      return v;
    }

    // Signed reader for z2 (idx >= -1 for above, idx can be < -1 for left,
    // reading the below-corner default 129). idx is 12-bit two's complement.
    Logic selA(Logic idx) {
      Logic v = aRow(2 * bs - 1);
      for (var j = 2 * bs - 2; j >= 0; j--) {
        v = mux(idx.eq(Const(j, width: 12)), aRow(j), v);
      }
      return mux(idx[11], corner, v); // negative (-1) -> corner
    }

    Logic selL(Logic idx) {
      Logic v = lCol(2 * bs - 1);
      for (var j = 2 * bs - 2; j >= 0; j--) {
        v = mux(idx.eq(Const(j, width: 12)), lCol(j), v);
      }
      final isM1 = idx.eq(Const(0xFFF, width: 12)); // -1
      return mux(
        idx[11],
        mux(isM1, corner, Const(128 + 1, width: 8)),
        v,
      ); // < -1 -> 129
    }

    Logic interp(Logic a0, Logic a1, Logic shift) {
      // a0*(32-shift) + a1*shift, then round_pow2(.,5). Sum <= 255*32 = 8160.
      final s = shift.zeroExtend(6); // 0..31
      final inv = (Const(32, width: 6) - s).getRange(0, 6); // 32 - shift
      final t0 = (a0.zeroExtend(15) * inv.zeroExtend(15)).getRange(0, 15);
      final t1 = (a1.zeroExtend(15) * s.zeroExtend(15)).getRange(0, 15);
      final sum = (t0 + t1).getRange(0, 15);
      return (sum + Const(16, width: 15)).getRange(5, 13); // round >>5, 8-bit
    }

    final out = <Logic>[]; // row-major bs*bs
    for (var r = 0; r < bs; r++) {
      for (var c = 0; c < bs; c++) {
        // z1: x=(r+1)*dx, base=(x>>6)+c, shift=(x&63)>>1.
        final xz1 = (Const((r + 1), width: 18) * dx.zeroExtend(18)).getRange(
          0,
          18,
        );
        final baseZ1 = (xz1.getRange(6, 18) + Const(c, width: 12)).getRange(
          0,
          12,
        );
        final shZ1 = xz1.getRange(1, 6); // (x&63)>>1 == bits[1..5]
        final z1v = mux(
          baseZ1.lt(Const(maxBase, width: 12)),
          interp(
            aClamp(baseZ1),
            aClamp((baseZ1 + Const(1, width: 12)).getRange(0, 12)),
            shZ1,
          ),
          aRow(maxBase),
        );

        // z3: y=(c+1)*dy, base=(y>>6)+r, shift=(y&63)>>1.
        final yz3 = (Const((c + 1), width: 18) * dy.zeroExtend(18)).getRange(
          0,
          18,
        );
        final baseZ3 = (yz3.getRange(6, 18) + Const(r, width: 12)).getRange(
          0,
          12,
        );
        final shZ3 = yz3.getRange(1, 6);
        final z3v = mux(
          baseZ3.lt(Const(maxBase, width: 12)),
          interp(
            lClamp(baseZ3),
            lClamp((baseZ3 + Const(1, width: 12)).getRange(0, 12)),
            shZ3,
          ),
          lCol(maxBase),
        );

        // z2: x=(c<<6)-(r+1)*dx (signed). baseX=x>>6, if baseX>=-1 use above
        // else use left with y=(r<<6)-(c+1)*dy.
        final xz2 =
            (Const(c << 6, width: w) -
                    (Const((r + 1), width: w) * dx.zeroExtend(w)).getRange(
                      0,
                      w,
                    ))
                .getRange(0, w);
        final baseX = [
          xz2[w - 1].replicate(6),
          xz2.getRange(6, w),
        ].concat().getRange(0, w); // arithmetic >>6
        final shX = xz2.getRange(1, 6);
        // baseX >= -1  <=>  (baseX + 1) sign bit == 0
        final baseXp1 = (baseX + Const(1, width: w)).getRange(0, w);
        final useAbove = ~baseXp1[w - 1];
        final yz2 =
            (Const(r << 6, width: w) -
                    (Const((c + 1), width: w) * dy.zeroExtend(w)).getRange(
                      0,
                      w,
                    ))
                .getRange(0, w);
        final baseY = [
          yz2[w - 1].replicate(6),
          yz2.getRange(6, w),
        ].concat().getRange(0, w);
        final shY = yz2.getRange(1, 6);
        // signed small index for aAt/lAt: use a 12-bit two's complement slice.
        final bX = baseX.getRange(0, 12);
        final bY = baseY.getRange(0, 12);
        final z2above = interp(
          selA(bX),
          selA((bX + Const(1, width: 12)).getRange(0, 12)),
          shX,
        );
        final z2left = interp(
          selL(bY),
          selL((bY + Const(1, width: 12)).getRange(0, 12)),
          shY,
        );
        final z2v = mux(useAbove, z2above, z2left);

        final vV = aRow(c); // V predictor
        final hV = lCol(r); // H predictor
        final px = mux(
          isZ1,
          z1v,
          mux(isZ2, z2v, mux(isZ3, z3v, mux(isV, vV, hV))),
        );
        out.add(px.getRange(0, 8));
      }
    }
    output('pred') <= [for (var i = bs * bs - 1; i >= 0; i--) out[i]].concat();
  }
}
