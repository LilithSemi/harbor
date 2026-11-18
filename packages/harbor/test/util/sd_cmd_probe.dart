import 'package:rohd/rohd.dart';

/// Tells when the host sends a command frame on CMD.
///
/// The pad enable is also high while CMD idles, so a frame starts at the first
/// low bit and ends when the host releases the pad. A bench keeps one probe and
/// calls [sending] once per clock.
class SdCmdProbe {
  var _inFrame = false;

  /// True while the host sends a command frame.
  bool sending(Logic oe, Logic out) {
    if (oe.value.toInt() != 1) {
      _inFrame = false;
      return false;
    }
    if (out.value.toInt() == 0) _inFrame = true;
    return _inFrame;
  }
}
