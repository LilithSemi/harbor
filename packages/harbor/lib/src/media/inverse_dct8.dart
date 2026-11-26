import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

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

/// Harbor 8x8 2D inverse DCT (the 8x8 reconstruction residual transform).
///
/// The 8-point analogue of [HarborInverseDct4]: `X = Mᵀ · C · M` over an 8x8
/// coefficient block, separable (1D inverse over columns, round >>12, then over
/// rows). `coeffs`/`residual` pack element (r,c) at `[(r*8+c)*16 +: 16]`, signed.
/// Combinational. Pairs with the dequantizer and the 8x8 intra predictor.
class HarborInverseDct8 extends BridgeModule {
  HarborInverseDct8({String? name})
    : super('HarborInverseDct8', name: name ?? 'inv_dct8') {
    const w = 44; // signed working width
    final m = _dctMatrix(8);

    createPort('coeffs', PortDirection.input, width: 64 * 16);
    addOutput('residual', width: 64 * 16);

    Logic coeff(int r, int c) =>
        input('coeffs').getRange((r * 8 + c) * 16, (r * 8 + c) * 16 + 16);

    Logic smul(Logic a, int k) {
      final kc = Const(BigInt.from(k).toUnsigned(w), width: w);
      return (a.signExtend(w) * kc).getRange(0, w);
    }

    Logic roundShift(Logic x) {
      final r = (x + Const(2048, width: w)).getRange(0, w);
      return [r[w - 1].replicate(12), r.getRange(12, w)].concat();
    }

    List<Logic> inv1d(List<Logic> inp) => [
      for (var i = 0; i < 8; i++)
        roundShift(
          ([
            for (var k = 0; k < 8; k++) smul(inp[k], m[k][i]),
          ]).reduce((a, b) => (a + b).getRange(0, w)),
        ),
    ];

    final tmp = <List<Logic>>[
      for (var r = 0; r < 8; r++) List.filled(8, coeff(0, 0)),
    ];
    for (var c = 0; c < 8; c++) {
      final col = inv1d([for (var r = 0; r < 8; r++) coeff(r, c)]);
      for (var r = 0; r < 8; r++) {
        tmp[r][c] = col[r];
      }
    }

    final out = <Logic>[];
    for (var r = 0; r < 8; r++) {
      final row = inv1d([for (var c = 0; c < 8; c++) tmp[r][c]]);
      for (var c = 0; c < 8; c++) {
        out.add(row[c].getRange(0, 16));
      }
    }

    output('residual') <= out.reversed.toList().concat();
  }
}
