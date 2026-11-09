import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_predictor.dart';
import 'inverse_dct4.dart';

/// Harbor 4x4 intra block reconstruction: dequant -> inverse DCT -> predict.
///
/// The full reconstruction path for a decoded 4x4 intra block, composing the
/// verified pieces. The coefficient levels are dequantized (`coeff[0]` by the DC
/// quantizer, the rest by the AC quantizer), inverse-transformed
/// ([HarborInverseDct4]) into the spatial residual, and added to the intra
/// prediction from the neighbours ([HarborIntraPredictor], mode-driven), giving
/// the reconstructed pixels.
///
/// `coeffs` packs 16 signed levels (element (r,c) at `[(r*4+c)*16 +: 16]`). The
/// residual is placed into the predictor's stride-8 grid (`r*8+c`). `recon` is
/// the predictor's 64-pixel output, the block occupies the top-left 4x4.
/// Combinational.
class HarborReconstruct4 extends BridgeModule {
  HarborReconstruct4({int bitDepth = 8, String? name})
    : super('HarborReconstruct4', name: name ?? 'reconstruct4') {
    final pw = bitDepth;

    createPort('coeffs', PortDirection.input, width: 16 * 16);
    createPort('dc_q', PortDirection.input, width: 8);
    createPort('ac_q', PortDirection.input, width: 8);
    createPort('mode', PortDirection.input, width: 3);
    createPort('above', PortDirection.input, width: 8 * pw);
    createPort('left', PortDirection.input, width: 8 * pw);
    createPort('above_left', PortDirection.input, width: pw);
    addOutput('recon', width: 64 * pw);

    Logic level(int i) => input('coeffs').getRange(i * 16, i * 16 + 16);
    final dcq = input('dc_q');
    final acq = input('ac_q');

    // Dequantize: deq[i] = level[i] * (i==0 ? dc_q : ac_q), signed.
    Logic deq(int i) {
      final q = (i == 0 ? dcq : acq).zeroExtend(32);
      return (level(i).signExtend(32) * q).getRange(0, 16);
    }

    final deqPacked = [for (var i = 15; i >= 0; i--) deq(i)].concat();

    final idct = HarborInverseDct4(name: 'idct');
    addSubModule(idct);
    idct.input('coeffs').srcConnection! <= deqPacked;
    final residual = idct.output('residual');
    Logic resi(int i) => residual.getRange(i * 16, i * 16 + 16);

    // Place the 4x4 residual into the predictor's stride-8 grid (r*8+c).
    final res64 = <Logic>[for (var i = 0; i < 64; i++) Const(0, width: 16)];
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 4; c++) {
        res64[r * 8 + c] = resi(r * 4 + c);
      }
    }

    final pred = HarborIntraPredictor(bitDepth: bitDepth, name: 'pred');
    addSubModule(pred);
    pred.input('mode').srcConnection! <= input('mode');
    pred.input('size').srcConnection! <= Const(0); // 4x4
    pred.input('above').srcConnection! <= input('above');
    pred.input('left').srcConnection! <= input('left');
    pred.input('above_left').srcConnection! <= input('above_left');
    pred.input('residual').srcConnection! <=
        [for (var i = 63; i >= 0; i--) res64[i]].concat();

    output('recon') <= pred.output('recon');
  }
}
