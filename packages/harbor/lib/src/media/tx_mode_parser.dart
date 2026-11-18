import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'bit_reader.dart';

/// Harbor AV1 `read_tx_mode()` parser.
///
/// Selects the frame's transform-size mode: when `coded_lossless` the mode is
/// forced to `ONLY_4X4` (0), otherwise `tx_mode_select = f(1)` picks
/// `TX_MODE_SELECT` (2, per-block tx size signalled) or `TX_MODE_LARGEST` (1,
/// always the largest tx for the block). Combinational.
class HarborTxModeParser extends BridgeModule {
  HarborTxModeParser({int maxBytes = 16, String? name})
    : super('HarborTxModeParser', name: name ?? 'tx_mode') {
    final totalBits = maxBytes * 8;

    createPort('bytes', PortDirection.input, width: totalBits);
    createPort('coded_lossless', PortDirection.input, width: 1);
    addOutput('tx_mode', width: 2);
    addOutput('bits_consumed', width: 8);

    final notLossless = ~input('coded_lossless');

    final r = HarborBitReader(maxBytes: maxBytes, name: 'fn');
    addSubModule(r);
    r.input('bytes').srcConnection! <= input('bytes');
    r.input('bit_offset').srcConnection! <=
        Const(0, width: totalBits.bitLength);
    r.input('n').srcConnection! <= Const(1, width: 6);

    final sel = r.output('value').getRange(0, 1);
    // lossless -> 0, else select ? 2 : 1.
    output('tx_mode') <=
        mux(
          notLossless,
          mux<Logic>(sel, Const(2, width: 2), Const(1, width: 2)),
          Const(0, width: 2),
        );
    output('bits_consumed') <=
        mux<Logic>(notLossless, Const(1, width: 8), Const(0, width: 8));
  }
}
