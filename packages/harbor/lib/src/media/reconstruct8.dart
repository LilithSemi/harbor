import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_predictor.dart';
import 'inverse_dct8.dart';

/// Harbor 8x8 intra block reconstruction: dequant -> inverse DCT8 -> predict.
///
/// The 8x8 analogue of [HarborReconstruct4]: dequantize the 64 coefficient
/// levels (DC by `dc_q`, the rest by `ac_q`), inverse-transform with
/// [HarborInverseDct8], and add the residual to the 8x8 intra prediction
/// ([HarborIntraPredictor] with size = 1). The 8x8 residual maps directly onto
/// the predictor's stride-8 grid. `coeffs` packs 64 signed levels (element (r,c)
/// at `[(r*8+c)*16 +: 16]`), `recon` is the 64-pixel reconstructed block.
/// Combinational.
class HarborReconstruct8 extends BridgeModule {
  HarborReconstruct8({int bitDepth = 8, String? name})
    : super('HarborReconstruct8', name: name ?? 'reconstruct8') {
    final pw = bitDepth;

    createPort('coeffs', PortDirection.input, width: 64 * 16);
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

    Logic deq(int i) {
      final q = (i == 0 ? dcq : acq).zeroExtend(32);
      return (level(i).signExtend(32) * q).getRange(0, 16);
    }

    final deqPacked = [for (var i = 63; i >= 0; i--) deq(i)].concat();

    final idct = HarborInverseDct8(name: 'idct8');
    addSubModule(idct);
    idct.input('coeffs').srcConnection! <= deqPacked;

    final pred = HarborIntraPredictor(bitDepth: bitDepth, name: 'pred');
    addSubModule(pred);
    pred.input('mode').srcConnection! <= input('mode');
    pred.input('size').srcConnection! <= Const(1); // 8x8
    pred.input('above').srcConnection! <= input('above');
    pred.input('left').srcConnection! <= input('left');
    pred.input('above_left').srcConnection! <= input('above_left');
    pred.input('residual').srcConnection! <= idct.output('residual');

    output('recon') <= pred.output('recon');
  }
}
