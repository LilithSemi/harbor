import 'package:rohd/rohd.dart';

import '../blackbox/ecp5/ecp5.dart';
import '../blackbox/xilinx/xilinx.dart';
import '../soc/target.dart';

/// Which edge of the forwarded pixel clock a parallel RGB transmitter (for
/// example the SiI9134) latches RGB/HSYNC/VSYNC/DE on.
///
/// Harbor's own output registers change on the rising edge of the pixel
/// clock. [HarborPixelClockForward] phases its output so the receiver's
/// chosen latch edge always lands half a pixel period after that change,
/// clear of the data transition.
enum HarborParallelRgbLatchEdge {
  /// Receiver latches on the forwarded clock's rising edge. The clock is
  /// inverted relative to the pixel clock, so that edge trails the data
  /// change by half a period.
  rising,

  /// Receiver latches on the forwarded clock's falling edge (the default).
  /// The clock is forwarded in phase with the pixel clock, so the falling
  /// edge trails the data change by half a period.
  falling,
}

/// Forwards the pixel clock onto a parallel RGB clock output pin through the
/// target's clock-forwarding primitive.
///
/// The DDR output register's two data inputs are tied to constants, so the
/// register acts as a plain clock buffer: once it has latched one edge, [q]
/// tracks [clk] (or its inversion, with [latchEdge]) exactly. Using the same
/// kind of output register as the data pins keeps the clock-to-pad delay in
/// line with theirs, which is the point of forwarding a clock rather than
/// leaving the receiver to re-derive it.
///
/// Sim uses a plain combinational forward: there is no pad delay to model
/// and no vendor cell to stand in for. ECP5 uses `ODDRX1F`; Xilinx 7-series
/// uses `ODDR` with its data inputs set to the non-toggling pair (`D1=1,
/// D2=0`, or swapped to invert).
class HarborPixelClockForward extends Module {
  /// The forwarded clock output.
  Logic get q => output('q');

  HarborPixelClockForward({
    required Logic clk,
    required HarborDeviceTarget target,
    HarborParallelRgbLatchEdge latchEdge = HarborParallelRgbLatchEdge.falling,
    super.name = 'pixel_clock_forward',
  }) : super(definitionName: 'HarborPixelClockForward') {
    clk = addInput('clk', clk);
    addOutput('q');

    final invert = latchEdge == HarborParallelRgbLatchEdge.rising;
    final hi = invert ? Const(0) : Const(1);
    final lo = invert ? Const(1) : Const(0);

    q <=
        switch (target) {
          HarborSimTarget() => invert ? ~clk : clk,
          HarborFpgaTarget(vendor: HarborFpgaVendor.ecp5) => Ecp5Oddrx1f(
            sclk: clk,
            rst: Const(0),
            d0: hi,
            d1: lo,
          ).q,
          HarborFpgaTarget(vendor: HarborFpgaVendor.vivado) ||
          HarborFpgaTarget(
            vendor: HarborFpgaVendor.openXc7,
          ) => XilinxOddr(c: clk, d1: hi, d2: lo, r: Const(0)).q,
          HarborFpgaTarget(vendor: HarborFpgaVendor.ice40) =>
            throw UnsupportedError(
              'HarborPixelClockForward has no clock-forward primitive for '
              'iCE40: the family has no DDR output primitive in this '
              'catalog. Use an ECP5 or a Xilinx 7-series part for parallel '
              'RGB output.',
            ),
          HarborAsicTarget() => throw UnsupportedError(
            'HarborPixelClockForward has no clock-forward primitive for an '
            'ASIC target: a clock output pad is process specific and comes '
            'from the foundry IO library.',
          ),
        };
  }
}
