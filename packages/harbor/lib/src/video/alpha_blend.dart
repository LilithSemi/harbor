import 'package:rohd/rohd.dart';

import '../blackbox/ecp5/ecp5.dart';
import '../soc/target.dart';

/// Blends an overlay pixel over a primary pixel with one alpha.
///
/// For each channel: `div255(ov * alpha + pri * (255 - alpha))`, where
/// `div255(v) = (v + 128 + ((v + 128) >> 8)) >> 8` is `round(v / 255)` for
/// every v from 0 to 65025. Alpha 255 gives the overlay and alpha 0 gives
/// the primary.
///
/// The sum is `alpha * (ov - pri) + 255 * pri`, so each channel has one
/// multiplier. It takes one pixel each clock. The outputs come [latency]
/// clocks after the inputs, from logic after the last registers. On an
/// ECP5 [target] the multipliers are MULT18X18D cells with their own
/// registers.
class HarborAlphaBlend extends Module {
  /// Clocks from the inputs to [red], [green] and [blue].
  static const latency = 3;

  Logic get red => output('red');
  Logic get green => output('green');
  Logic get blue => output('blue');

  HarborAlphaBlend({
    required Logic clk,
    required List<Logic> overlay,
    required List<Logic> primary,
    required Logic alpha,
    HarborDeviceTarget? target,
    String name = 'alpha_blend',
  }) : this._(
         clk: clk,
         overlay: overlay,
         primary: primary,
         alpha: alpha,
         ecp5:
             target is HarborFpgaTarget &&
             target.vendor == HarborFpgaVendor.ecp5,
         name: name,
       );

  HarborAlphaBlend._({
    required Logic clk,
    required List<Logic> overlay,
    required List<Logic> primary,
    required Logic alpha,
    required bool ecp5,
    required String name,
  }) : super(
         name: name,
         definitionName: ecp5 ? 'HarborAlphaBlend_ecp5' : 'HarborAlphaBlend',
       ) {
    if (overlay.length != 3 || primary.length != 3) {
      throw ArgumentError('give R, G and B of the overlay and the primary');
    }
    clk = addInput('clk', clk);
    alpha = addInput('alpha', alpha, width: 8);
    const names = ['red', 'green', 'blue'];
    Logic reg(Logic v, String name) => flop(clk, v).named(name);
    final a1 = ecp5 ? alpha : reg(alpha, 'alpha_s1');

    for (var i = 0; i < 3; i++) {
      final n = names[i];
      final ov = addInput('overlay_$n', overlay[i], width: 8);
      final pri = addInput('primary_$n', primary[i], width: 8);
      // Stage 1: the signed difference, 9 bits.
      final d = ov.zeroExtend(9) - pri.zeroExtend(9);
      // Stage 2: the product, 18 bits signed.
      final Logic p;
      if (ecp5) {
        p = Ecp5Mult18x18d(
          clk: clk,
          a: d,
          b: alpha,
          signedB: false,
          name: 'mult_$n',
        ).p.getRange(0, 18).named('${n}_p_s2');
      } else {
        final d1 = reg(d, '${n}_d_s1');
        p = reg(d1.signExtend(18) * a1.zeroExtend(18), '${n}_p_s2');
      }
      final pri2 = reg(reg(pri, '${n}_pri_s1'), '${n}_pri_s2');
      // Stage 3: the sum plus one half. It is from 128 to 65153.
      final pri255 =
          [pri2, Const(0, width: 8)].swizzle().zeroExtend(18) -
          pri2.zeroExtend(18);
      final s = reg(
        (p + pri255 + Const(128, width: 18)).getRange(0, 17),
        '${n}_sum_s3',
      );
      addOutput(n, width: 8) <=
          (s + s.getRange(8).zeroExtend(17)).getRange(8, 16);
    }
  }
}
