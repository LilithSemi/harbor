import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'sgr_boxsum.dart';

/// Per-pixel A/B offset output width for a bit depth [bd].
/// bd8 -> 20 (legacy). `b` scales with the original sum box-sum (`~n*(2^bd-1)`):
/// bd12 needs 22, formula gives 24.
int sgrBWidth(int bd) => bd + 12;

/// Harbor bit-exact AV1 SGR per-pixel A/B derivation (libaom `_calcAb`),
/// bit-depth aware.
///
/// From the box sums over a `(2r+1)x(2r+1)` window, `bv` (sum of pixels) and
/// `av` (sum of squared pixels), and the noise parameter `s`, this computes the
/// per-pixel gain `a` and offset `b` that drive the self-guided filter. At high
/// bit depth libaom rounds the box sums down BEFORE the p/z computation (so the
/// gain LUT stays 8-bit-calibrated), while the `b` offset still uses the ORIGINAL
/// sum box-sum:
///   avR = round2u(av, 2*(bd-8))   bvR = round2u(bv, bd-8)   n = (2r+1)^2
///   p = max(0, avR*n - bvR*bvR)
///   z = round2u(p*s, 20)
///   a = av1_x_by_x_plus_1[min(z, 255)]
///   b = round2u((256 - a) * bv * av1_one_by_x[n-1], 12)   // bv = original sum
/// At bd8 both shifts are 0 (identity). `n` and `one_by_x[n-1]` are fixed per
/// radius, so only the `x/(x+1)` LUT is a ROM here. Combinational.
///
/// Ports: `av` (`sgrAsumWidth(bd)`), `bv` (`sgrBsumWidth(bd)`), `s` (12b)
/// -> `a` (9b, 0..256), `b` (`sgrBWidth(bd)`).
class HarborSgrCalcAb extends BridgeModule {
  /// av1_x_by_x_plus_1 (256 entries), the AV1 a = x/(x+1) Q8 table.
  static const xByXPlus1 = <int>[
    1, 128, 171, 192, 205, 213, 219, 224, 228, 230, 233, 235, 236, 238, 239, //
    240, 241, 242, 243, 243, 244, 244, 245, 245, 246, 246, 247, 247, 247, 247,
    248, 248, 248, 248, 249, 249, 249, 249, 249, 250, 250, 250, 250, 250, 250,
    250, 251, 251, 251, 251, 251, 251, 251, 251, 251, 251, 252, 252, 252, 252,
    252, 252, 252, 252, 252, 252, 252, 252, 252, 252, 252, 252, 252, 253, 253,
    253, 253, 253, 253, 253, 253, 253, 253, 253, 253, 253, 253, 253, 253, 253,
    253, 253, 253, 253, 253, 253, 253, 253, 253, 253, 253, 253, 254, 254, 254,
    254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254,
    254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254,
    254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254,
    254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254,
    254, 254, 254, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    256,
  ];

  /// av1_one_by_x (round(4096 / x)), indexed by n-1.
  static const oneByX = <int>[
    4096, 2048, 1365, 1024, 819, 683, 585, 512, 455, 410, 372, 341, 315, //
    293, 273, 256, 241, 228, 216, 205, 195, 186, 178, 171, 164,
  ];

  HarborSgrCalcAb({int radius = 1, int bd = 8, String? name})
    : super('HarborSgrCalcAb_R${radius}_B$bd', name: name ?? 'sgr_calc_ab') {
    const w = 48; // p*s reaches ~1.3e11 (38 bits)
    final n = (2 * radius + 1) * (2 * radius + 1);
    final recip = oneByX[n - 1];
    final avW = sgrAsumWidth(bd);
    final bvW = sgrBsumWidth(bd);
    final bW = sgrBWidth(bd);
    final avShift = 2 * (bd - 8); // round the sum-of-squares box-sum
    final bvShift = bd - 8; // round the sum box-sum

    createPort('av', PortDirection.input, width: avW);
    createPort('bv', PortDirection.input, width: bvW);
    createPort('s', PortDirection.input, width: 12);
    addOutput('a', width: 9);
    addOutput('b', width: bW);

    final s = input('s').zeroExtend(w);
    Logic kc(int v) => Const(BigInt.from(v).toUnsigned(w), width: w);
    Logic mul(Logic a, Logic b) => (a * b).getRange(0, w);
    // round2u(x, sh) = sh==0 ? x : (x + (1<<(sh-1))) >> sh, all in width w.
    Logic round2u(Logic x, int sh) {
      if (sh == 0) return x;
      final r = (x + kc(1 << (sh - 1))).getRange(0, w);
      return r.getRange(sh, w).zeroExtend(w);
    }

    // Rounded box-sums drive the p/z path. The ORIGINAL sum box-sum drives b.
    final avR = round2u(input('av').zeroExtend(w), avShift);
    final bOrig = input('bv').zeroExtend(w);
    final bvR = round2u(bOrig, bvShift);

    // p = max(0, avR*n - bvR*bvR).
    final avn = mul(avR, kc(n));
    final bvsq = mul(bvR, bvR);
    final p = mux(avn.lt(bvsq), kc(0), (avn - bvsq).getRange(0, w));
    // z = round2u(p*s, 20) = (p*s + (1<<19)) >> 20.
    final ps = (mul(p, s) + kc(1 << 19)).getRange(0, w);
    final z = ps.getRange(20, w);
    final zc = mux(
      z.gt(Const(255, width: z.width)),
      Const(255, width: 8),
      z.getRange(0, 8),
    );

    // a = xByXPlus1[zc] via a ROM mux.
    Logic a = Const(xByXPlus1[0], width: 9);
    for (var i = 1; i < xByXPlus1.length; i++) {
      a = mux(zc.eq(i), Const(xByXPlus1[i], width: 9), a);
    }
    output('a') <= a;

    // b = round2u((256 - a) * bOrig * recip, 12).
    final amix = (Const(256, width: w) - a.zeroExtend(w)).getRange(0, w);
    final bb = mul(mul(amix, bOrig), kc(recip));
    final b = (bb + kc(1 << 11)).getRange(0, w).getRange(12, 12 + bW);
    output('b') <= b;
  }
}
