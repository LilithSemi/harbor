import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// N-point integer DCT-II basis matrix (orthonormal, scaled by 4096) - matches
/// the media engine's `_dctMatrix`.
List<List<int>> _dctMatrix(int n) => [
  for (var k = 0; k < n; k++)
    [
      for (var i = 0; i < n; i++)
        ((k == 0 ? sqrt(1 / n) : sqrt(2 / n)) *
                cos((2 * i + 1) * k * pi / (2 * n)) *
                4096)
            .round(),
    ],
];

/// Harbor 4x4 2D inverse DCT (the reconstruction residual transform).
///
/// Computes the spatial residual `X = Mᵀ · C · M` from a 4x4 coefficient block
/// `C`, where `M` is the orthonormal integer DCT-II basis (scaled by 4096). It
/// is separable: a 1D inverse over the columns (round >>12), then over the rows
/// (round >>12). `coeffs` and `residual` pack element (r,c) at bits
/// `[(r*4+c)*16 +: 16]`, signed two's complement. Combinational.
///
/// This pairs with the dequantizer (before) and the intra predictor (after,
/// which adds the residual to the prediction) to reconstruct an intra block.
class HarborInverseDct4 extends BridgeModule {
  HarborInverseDct4({String? name})
    : super('HarborInverseDct4', name: name ?? 'inv_dct4') {
    const w = 40; // signed working width
    final m = _dctMatrix(4);

    createPort('coeffs', PortDirection.input, width: 16 * 16);
    addOutput('residual', width: 16 * 16);

    Logic coeff(int r, int c) =>
        input('coeffs').getRange((r * 4 + c) * 16, (r * 4 + c) * 16 + 16);

    // Signed multiply by a constant: low w bits of the (sign-extended) product.
    Logic smul(Logic a, int k) {
      final kc = Const(BigInt.from(k).toUnsigned(w), width: w);
      return (a.signExtend(w) * kc).getRange(0, w);
    }

    // Arithmetic round-shift by 12 (add 2048 first).
    Logic roundShift(Logic x) {
      final r = (x + Const(2048, width: w)).getRange(0, w);
      return [r[w - 1].replicate(12), r.getRange(12, w)].concat();
    }

    // 1D inverse over a length-4 input vector: out[i] = round(sum_k M[k][i]*in[k]).
    List<Logic> inv1d(List<Logic> inp) => [
      for (var i = 0; i < 4; i++)
        roundShift(
          ([
            for (var k = 0; k < 4; k++) smul(inp[k], m[k][i]),
          ]).reduce((a, b) => (a + b).getRange(0, w)),
        ),
    ];

    // Pass 1: inverse over each column.
    final tmp = <List<Logic>>[
      for (var r = 0; r < 4; r++) List.filled(4, coeff(0, 0)),
    ];
    for (var c = 0; c < 4; c++) {
      final col = inv1d([for (var r = 0; r < 4; r++) coeff(r, c)]);
      for (var r = 0; r < 4; r++) {
        tmp[r][c] = col[r];
      }
    }

    // Pass 2: inverse over each row.
    final out = <Logic>[];
    for (var r = 0; r < 4; r++) {
      final row = inv1d([for (var c = 0; c < 4; c++) tmp[r][c]]);
      for (var c = 0; c < 4; c++) {
        out.add(row[c].getRange(0, 16));
      }
    }

    output('residual') <= out.reversed.toList().concat();
  }
}
