import '../peripherals/display.dart';

/// Output types that currently have a built backend.
///
/// DVI and HDMI both ride the TMDS transmitter ([DviTransmitter]). HDMI's
/// signaling is DVI-compatible (audio/CEC are a later HDMI-only extra).
/// ParallelRgb drives raw RGB + HSYNC/VSYNC/DE + a forwarded pixel clock, for
/// a transmitter chip that wants parallel timing instead of TMDS (for example
/// the SiI9134 on Glacier's AX7203 board).
///
/// VGA is the same parallel RGB signal set, wired to a resistor DAC instead of
/// a transmitter chip, so it needs no new backend here, only DAC-facing board
/// wiring; it is not enabled by this set until that wiring exists.
/// DisplayPort/LVDS/MIPI are accepted by the type system so genip can offer
/// them, but are not driven yet.
const Set<HarborDisplayInterface> _supportedDisplayOutputs = {
  HarborDisplayInterface.dvi,
  HarborDisplayInterface.hdmi,
  HarborDisplayInterface.parallelRgb,
};

/// Whether Harbor can currently drive [type].
bool isDisplayOutputSupported(HarborDisplayInterface type) =>
    _supportedDisplayOutputs.contains(type);

/// Throws an [UnsupportedError] if [type] has no backend yet.
void requireDisplayOutputSupported(HarborDisplayInterface type) {
  if (!isDisplayOutputSupported(type)) {
    final supported = _supportedDisplayOutputs.map((e) => e.name).join(', ');
    throw UnsupportedError(
      'Display output "${type.name}" is not implemented yet. '
      'Supported: $supported. (VGA needs DAC board wiring on top of '
      'parallelRgb; DisplayPort is planned.)',
    );
  }
}
