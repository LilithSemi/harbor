import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_dir_angle.dart';
import 'intra_pred_avail.dart';

/// Harbor AV1 intra predictor combining neighbour AVAILABILITY and runtime
/// angle_delta (bd 8, no edge filter / no upsample, above-right/below-left as
/// repeat). The complete intra predictor for real streams short of the edge
/// filter and exotic modes.
///
/// Routes the 13 modes: non-directional (DC / SMOOTH / SMOOTH_V / SMOOTH_H /
/// PAETH) go to [HarborIntraPredAvail] (availability defaults + DC variant),
/// directional (V/H/D45/D135/D113/D157/D203/D67, modes 1..8) go to
/// [HarborIntraDirAngle] over the availability-resolved reference arrays (length
/// 2*bs, with the libaom cross-fill / default / repeat construction) so they
/// honour angle_delta AND missing neighbours.
///
/// Ports: `mode` (4b), `angle_delta` (4b signed, -3..3), `have_above` /
/// `have_left` (1b), `above` / `left` (bs pixels, 8b), `corner` (8b) -> `pred`
/// (bs*bs, 8b). Combinational.
class HarborIntraPredFull extends BridgeModule {
  /// Block size (square): 4 or 8 (16 builds slowly, same logic).
  final int bs;

  HarborIntraPredFull({required this.bs, String? name})
    : assert(bs == 4 || bs == 8 || bs == 16, 'bs 4/8/16'),
      super('HarborIntraPredFull', name: name ?? 'intra_pred_full_$bs') {
    createPort('mode', PortDirection.input, width: 4);
    createPort('angle_delta', PortDirection.input, width: 4);
    createPort('have_above', PortDirection.input);
    createPort('have_left', PortDirection.input);
    createPort('above', PortDirection.input, width: bs * 8);
    createPort('left', PortDirection.input, width: bs * 8);
    createPort('corner', PortDirection.input, width: 8);
    addOutput('pred', width: bs * bs * 8);

    final mode = input('mode');
    final haveA = input('have_above');
    final haveL = input('have_left');
    final corner = input('corner');
    Logic aPix(int i) => input('above').getRange(i * 8, i * 8 + 8);
    Logic lPix(int i) => input('left').getRange(i * 8, i * 8 + 8);
    const base = 128;
    final defAbove = Const(base - 1, width: 8); // 127
    final defLeft = Const(base + 1, width: 8); // 129

    // non-directional path (availability + DC variant) over raw neighbours.
    final nd = HarborIntraPredAvail(bs: bs, name: 'nd');
    addSubModule(nd);
    nd.input('mode').srcConnection! <= mode;
    nd.input('have_above').srcConnection! <= haveA;
    nd.input('have_left').srcConnection! <= haveL;
    nd.input('above').srcConnection! <= input('above');
    nd.input('left').srcConnection! <= input('left');
    nd.input('above_left').srcConnection! <= corner;

    // availability-resolved references extended to 2*bs (cross-fill / repeat /
    // default), fed to the directional-angle predictor.
    final aboveC = [
      for (var i = 0; i < 2 * bs; i++)
        mux(haveA, aPix(i < bs ? i : bs - 1), mux(haveL, lPix(0), defAbove)),
    ];
    final leftC = [
      for (var i = 0; i < 2 * bs; i++)
        mux(haveL, lPix(i < bs ? i : bs - 1), mux(haveA, aPix(0), defLeft)),
    ];
    final cornerC = mux(
      haveA & haveL,
      corner,
      mux(haveA, aPix(0), mux(haveL, lPix(0), Const(base, width: 8))),
    );

    final dr = HarborIntraDirAngle(bs: bs, name: 'dr');
    addSubModule(dr);
    dr.input('mode').srcConnection! <= mode;
    dr.input('angle_delta').srcConnection! <= input('angle_delta');
    dr.input('above').srcConnection! <=
        [for (var i = 2 * bs - 1; i >= 0; i--) aboveC[i]].concat();
    dr.input('left').srcConnection! <=
        [for (var i = 2 * bs - 1; i >= 0; i--) leftC[i]].concat();
    dr.input('corner').srcConnection! <= cornerC;

    final directional =
        mode.gte(Const(1, width: 4)) & mode.lte(Const(8, width: 4));
    output('pred') <= mux(directional, dr.output('pred'), nd.output('pred'));
  }
}
