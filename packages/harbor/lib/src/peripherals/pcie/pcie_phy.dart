import 'package:rohd/rohd.dart';

/// The outputs that every 7-series PCIe PHY top gives to the endpoint.
///
/// The names of the output ports are the same in each PHY.
abstract class HarborPciePhy extends Module {
  HarborPciePhy({required super.name, required super.definitionName});

  Logic get txP => output('tx_p');
  Logic get txN => output('tx_n');
  Logic get pclk => output('pclk');
  Logic get userClk1 => output('userclk1');
  Logic get userClk2 => output('userclk2');
  Logic get ready => output('ready');

  /// Frequency of `userclk1` and `userclk2` in Hz.
  int get userClkHz;

  /// MMCM lock, not synchronised.
  Logic get mmcmLock => output('mmcm_lock');

  /// Current reset state code.
  Logic get resetState => output('reset_state');

  /// Reset state code of the last failure.
  Logic get resetFailState => output('reset_fail_state');

  /// Number of failures since reset, it stops at 255.
  Logic get resetRetries => output('reset_retries');

  /// Number of link training watchdog restarts, it stops at 255. Null when
  /// the watchdog is off.
  Logic? get linkRetrains =>
      outputs.containsKey('link_retrains') ? output('link_retrains') : null;
}
