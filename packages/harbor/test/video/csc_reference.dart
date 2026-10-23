import 'package:harbor/harbor.dart';

/// Luma weights and range of one standard set.
class CscStandard {
  final String name;
  final double kr;
  final double kb;
  final bool limited;

  const CscStandard(this.name, this.kr, this.kb, {required this.limited});

  /// The 3x3 matrix in double, rows R, G, B and columns Y, Cb, Cr, from
  /// normalized Y in 0..1 and Cb, Cr in -0.5..0.5 to R, G, B in 0..1.
  List<List<double>> get matrix {
    final kg = 1 - kr - kb;
    return [
      [1, 0, 2 - 2 * kr],
      [1, -2 * kb * (1 - kb) / kg, -2 * kr * (1 - kr) / kg],
      [1, 2 - 2 * kb, 0],
    ];
  }

  /// The 10-bit Y code of black.
  int get yOffset => limited ? 64 : 0;
}

const cscStandards = [
  CscStandard('bt601Limited', 0.299, 0.114, limited: true),
  CscStandard('bt601Full', 0.299, 0.114, limited: false),
  CscStandard('bt709Limited', 0.2126, 0.0722, limited: true),
  CscStandard('bt709Full', 0.2126, 0.0722, limited: false),
  CscStandard('bt2020Limited', 0.2627, 0.0593, limited: true),
  CscStandard('bt2020Full', 0.2627, 0.0593, limited: false),
];

int _clamp8(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

/// `clamp(round(M * (YCbCr - offset)))` in double, to full-range 8-bit RGB.
/// A 10-bit code is an 8-bit code times 4.
List<int> cscFloat(CscStandard s, int y, int cb, int cr) {
  final m = s.matrix;
  final yScale = s.limited ? 4.0 * 219 : 4.0 * 255;
  final cScale = s.limited ? 4.0 * 224 : 4.0 * 255;
  final yn = (y - s.yOffset) / yScale;
  final cbn = (cb - 512) / cScale;
  final crn = (cr - 512) / cScale;
  return [
    for (final row in m)
      _clamp8(((row[0] * yn + row[1] * cbn + row[2] * crn) * 255).round()),
  ];
}

/// The bit-exact fixed-point model of [HarborCsc].
List<int> cscFixed(HarborCscCoefficients c, int y, int cb, int cr) {
  final t = [y - c.inOffset[0], cb - c.inOffset[1], cr - c.inOffset[2]];
  return [
    for (var i = 0; i < 3; i++)
      () {
        var sum =
            (c.outOffset[i] << HarborCsc.shift) + (1 << (HarborCsc.shift - 1));
        for (var j = 0; j < 3; j++) {
          sum += c.coeff[3 * i + j] * t[j];
        }
        return _clamp8(sum >> HarborCsc.shift);
      }(),
  ];
}

/// Y, Cb and Cr of 8-bit R, G and B in 0..255, in 10-bit codes.
List<int> cscForward(CscStandard s, int r, int g, int b) {
  final kg = 1 - s.kr - s.kb;
  final rn = r / 255, gn = g / 255, bn = b / 255;
  final yn = s.kr * rn + kg * gn + s.kb * bn;
  final cbn = (bn - yn) / (2 - 2 * s.kb);
  final crn = (rn - yn) / (2 - 2 * s.kr);
  final yScale = s.limited ? 4.0 * 219 : 4.0 * 255;
  final cScale = s.limited ? 4.0 * 224 : 4.0 * 255;
  return [
    (s.yOffset + yn * yScale).round(),
    (512 + cbn * cScale).round().clamp(0, 1023),
    (512 + crn * cScale).round().clamp(0, 1023),
  ];
}
