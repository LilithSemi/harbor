import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_dir.dart';
import 'intra_pred.dart';

/// Harbor bit-exact AV1 intra predictor with runtime mode routing: combines the
/// non-directional core ([HarborIntraPred]: DC/V/H/SMOOTH/SMOOTH_V/SMOOTH_H/
/// PAETH) and the directional core ([HarborIntraDir]: D45/D135/D113/D157/D203/
/// D67 at angle_delta = 0) and selects the predicted block by the runtime
/// `mode`. Modes 3..8 are directional, the rest non-directional.
///
/// Ports mirror the two cores: `mode` (4b, the decoded y_mode 0..12), `above` /
/// `left` (bs neighbour pixels each, 8b), `above_left` (the corner pixel) ->
/// `pred` (bs*bs predicted pixels, row-major, 8b). Combinational, bd 8.
class HarborIntraModePred extends BridgeModule {
  /// Block size (square): 4, 8 or 16.
  final int bs;

  /// Sample bit depth (8/10/12). bd 8 is byte-identical to the original.
  final int bitDepth;

  HarborIntraModePred({required this.bs, this.bitDepth = 8, String? name})
    : assert(bs == 4 || bs == 8 || bs == 16 || bs == 32, 'bs 4/8/16/32'),
      assert(bitDepth == 8 || bitDepth == 10 || bitDepth == 12, 'bit depth'),
      super(
        'HarborIntraModePred_S${bs}_B$bitDepth',
        name: name ?? 'intra_mode_pred_${bs}_$bitDepth',
      ) {
    final pw = bitDepth;
    createPort('mode', PortDirection.input, width: 4);
    createPort('above', PortDirection.input, width: bs * pw);
    createPort('left', PortDirection.input, width: bs * pw);
    createPort('above_left', PortDirection.input, width: pw);
    addOutput('pred', width: bs * bs * pw);

    final mode = input('mode');
    final above = input('above');
    final left = input('left');
    final aboveLeft = input('above_left');

    final nd = HarborIntraPred(bs: bs, bitDepth: bitDepth, name: 'nd');
    addSubModule(nd);
    final dr = HarborIntraDir(bs: bs, bitDepth: bitDepth, name: 'dr');
    addSubModule(dr);
    for (final m in [nd, dr]) {
      m.input('mode').srcConnection! <= mode;
      m.input('above').srcConnection! <= above;
      m.input('left').srcConnection! <= left;
      m.input('above_left').srcConnection! <= aboveLeft;
    }

    // Directional modes are D45(3)..D67(8). Everything else is non-directional.
    final directional =
        mode.gte(Const(3, width: 4)) & mode.lte(Const(8, width: 4));
    output('pred') <= mux(directional, dr.output('pred'), nd.output('pred'));
  }
}
