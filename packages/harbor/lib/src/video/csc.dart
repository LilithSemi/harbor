import 'package:rohd/rohd.dart';

import '../blackbox/ecp5/ecp5.dart';
import '../soc/target.dart';

/// The 15 register values of a color conversion: 9 coefficients, 3 input
/// offsets and 3 output offsets.
///
/// A coefficient is a 16-bit signed value with 12 fraction bits. Row i,
/// column j is at index `3 * i + j`. Rows are R, G and B. Columns are Y, Cb
/// and Cr. The coefficients map a 10-bit input to a 10-bit output scale,
/// and the conversion then divides by 4 to get 8 bits.
class HarborCscCoefficients {
  final List<int> coeff;
  final List<int> inOffset;
  final List<int> outOffset;

  HarborCscCoefficients({
    required List<int> coeff,
    required List<int> inOffset,
    required List<int> outOffset,
  }) : coeff = List.unmodifiable(coeff),
       inOffset = List.unmodifiable(inOffset),
       outOffset = List.unmodifiable(outOffset) {
    if (coeff.length != 9 || inOffset.length != 3 || outOffset.length != 3) {
      throw ArgumentError('give 9 coefficients and 3 offsets of each kind');
    }
    if (coeff.any((c) => c < -0x8000 || c > 0x7fff) ||
        inOffset.any((o) => o < 0 || o > 1023) ||
        outOffset.any((o) => o < 0 || o > 255)) {
      throw ArgumentError('a value is out of the range of its register');
    }
  }

  /// The set for the matrix [m] (rows R, G, B, columns Y, Cb, Cr) that maps
  /// `in - inOffset` to 10-bit output units.
  factory HarborCscCoefficients.fromMatrix(
    List<List<double>> m, {
    required List<int> inOffset,
    List<int> outOffset = const [0, 0, 0],
  }) => HarborCscCoefficients(
    coeff: [
      for (final row in m)
        for (final v in row) (v * (1 << HarborCsc.fractionBits)).round(),
    ],
    inOffset: inOffset,
    outOffset: outOffset,
  );

  /// The standard set for luma weights [kr] and [kb], to full-range RGB.
  /// A limited input has Y from 64 to 940 and Cb, Cr from 64 to 960.
  /// A full input has a 10-bit code of 4 times the 8-bit code, so white Y
  /// is 1020 and not the 1023 scale of H.273.
  factory HarborCscCoefficients.standard(
    double kr,
    double kb, {
    required bool limited,
  }) {
    final kg = 1 - kr - kb;
    final ys = limited ? 255 / 219 : 1.0;
    final cs = limited ? 255 / 224 : 1.0;
    return HarborCscCoefficients.fromMatrix(
      [
        [ys, 0, cs * 2 * (1 - kr)],
        [ys, -cs * 2 * kb * (1 - kb) / kg, -cs * 2 * kr * (1 - kr) / kg],
        [ys, cs * 2 * (1 - kb), 0],
      ],
      inOffset: [limited ? 64 : 0, 512, 512],
    );
  }

  static final bt601Limited = HarborCscCoefficients.standard(
    0.299,
    0.114,
    limited: true,
  );
  static final bt601Full = HarborCscCoefficients.standard(
    0.299,
    0.114,
    limited: false,
  );
  static final bt709Limited = HarborCscCoefficients.standard(
    0.2126,
    0.0722,
    limited: true,
  );
  static final bt709Full = HarborCscCoefficients.standard(
    0.2126,
    0.0722,
    limited: false,
  );
  static final bt2020Limited = HarborCscCoefficients.standard(
    0.2627,
    0.0593,
    limited: true,
  );
  static final bt2020Full = HarborCscCoefficients.standard(
    0.2627,
    0.0593,
    limited: false,
  );

  /// The register values in port order: `csc_coeff_0` to `csc_coeff_8` as
  /// 16-bit two's complement, then `csc_in_offset_0` to `_2`, then
  /// `csc_out_offset_0` to `_2`.
  List<int> registers() => [
    for (final c in coeff) c & 0xffff,
    ...inOffset,
    ...outOffset,
  ];
}

/// Converts 10-bit Y, Cb and Cr to 8-bit R, G and B with a 3x3 matrix.
///
/// For each output channel i:
/// `(sum_j coeff[3i + j] * (in_j - inOffset_j) + (outOffset_i << 14)
/// + (1 << 13)) >> 14`, then a clamp to 0..255. See
/// [HarborCscCoefficients] for the formats.
///
/// It takes one pixel each clock and gives the result [latency] clocks
/// later. The input to each multiplier and its product are registers, so
/// a DSP block can hold them. The data registers have no reset. Yosys does
/// not move registers into an ECP5 MULT18X18D, so on an ECP5 [target] the
/// multipliers are MULT18X18D cells with their own registers. Both variants
/// sample the coefficients and offsets in the clock of the pixel input. They
/// must change only in vertical blanking.
class HarborCsc extends Module {
  static const fractionBits = 12;

  /// The total right shift: the fraction bits and 10 to 8 bits.
  static const shift = fractionBits + 2;

  static const _prodW = 27;
  static const _sumW = 29;

  /// Clocks from the inputs to [red], [green] and [blue].
  static const stages = 5;

  /// The same as [stages].
  int get latency => stages;

  Logic get red => output('red');
  Logic get green => output('green');
  Logic get blue => output('blue');

  HarborCsc({
    required Logic clk,
    required Logic y,
    required Logic cb,
    required Logic cr,
    required List<Logic> coeff,
    required List<Logic> inOffset,
    required List<Logic> outOffset,
    HarborDeviceTarget? target,
    String name = 'csc',
  }) : this._(
         clk: clk,
         y: y,
         cb: cb,
         cr: cr,
         coeff: coeff,
         inOffset: inOffset,
         outOffset: outOffset,
         ecp5:
             target is HarborFpgaTarget &&
             target.vendor == HarborFpgaVendor.ecp5,
         name: name,
       );

  HarborCsc._({
    required Logic clk,
    required Logic y,
    required Logic cb,
    required Logic cr,
    required List<Logic> coeff,
    required List<Logic> inOffset,
    required List<Logic> outOffset,
    required bool ecp5,
    required String name,
  }) : super(
         name: name,
         definitionName: ecp5 ? 'HarborCsc_ecp5' : 'HarborCsc',
       ) {
    if (coeff.length != 9 || inOffset.length != 3 || outOffset.length != 3) {
      throw ArgumentError('give 9 coefficients and 3 offsets of each kind');
    }
    clk = addInput('clk', clk);
    final ins = [
      addInput('y', y, width: 10),
      addInput('cb', cb, width: 10),
      addInput('cr', cr, width: 10),
    ];
    coeff = [
      for (var k = 0; k < 9; k++) addInput('coeff_$k', coeff[k], width: 16),
    ];
    inOffset = [
      for (var j = 0; j < 3; j++)
        addInput('in_offset_$j', inOffset[j], width: 10),
    ];
    outOffset = [
      for (var i = 0; i < 3; i++)
        addInput('out_offset_$i', outOffset[i], width: 8),
    ];

    Logic reg(Logic v, String name) => flop(clk, v).named(name);

    // The ECP5 multiplier registers its own coefficient input. The output
    // offset is delayed to the stage of the bias add.
    final c = ecp5
        ? coeff
        : [for (var k = 0; k < 9; k++) reg(coeff[k], 'coeff${k}_s1')];
    final o = [
      for (var i = 0; i < 3; i++)
        reg(reg(outOffset[i], 'out_offset${i}_s1'), 'out_offset${i}_s2'),
    ];

    // Stage 1: the signed difference, 11 bits.
    final d = [
      for (var j = 0; j < 3; j++)
        ins[j].zeroExtend(11) - inOffset[j].zeroExtend(11),
    ];
    final t = ecp5 ? d : [for (var j = 0; j < 3; j++) reg(d[j], 't${j}_s1')];

    // Stage 2: the products. The low 27 bits of the product of the sign
    // extended values are the signed product.
    Logic product(int i, int j) {
      if (ecp5) {
        return Ecp5Mult18x18d(
          clk: clk,
          a: t[j],
          b: c[3 * i + j],
          name: 'mult$i$j',
        ).p.getRange(0, _prodW).named('p$i${j}_s2');
      }
      return reg(
        c[3 * i + j].signExtend(_prodW) * t[j].signExtend(_prodW),
        'p$i${j}_s2',
      );
    }

    final p = [
      for (var i = 0; i < 3; i++) [for (var j = 0; j < 3; j++) product(i, j)],
    ];

    for (final (i, name) in [(0, 'red'), (1, 'green'), (2, 'blue')]) {
      // Stage 3: two sums. The bias adds the output offset and one half.
      final bias = [
        o[i],
        Const(1 << (shift - 1), width: shift),
      ].swizzle().zeroExtend(_sumW);
      final a = reg(
        p[i][0].signExtend(_sumW) + p[i][1].signExtend(_sumW),
        '${name}_a_s3',
      );
      final b = reg(p[i][2].signExtend(_sumW) + bias, '${name}_b_s3');
      // Stage 4: the full sum.
      final s = reg(a + b, '${name}_sum_s4');
      // Stage 5: clamp to 0..255.
      final over = s.getRange(shift + 8, _sumW - 1).or();
      final v = mux(
        s[_sumW - 1],
        Const(0, width: 8),
        mux(over, Const(0xff, width: 8), s.getRange(shift, shift + 8)),
      );
      addOutput(name, width: 8) <= reg(v, '${name}_s5');
    }
  }
}
