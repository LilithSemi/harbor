import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../blackbox/xilinx/xilinx.dart';
import '../soc/target.dart';

/// BT.709 limited range coefficients in 8 bit fixed point (divide by 256).
///
/// These are the equations of the ADV7511 probe on the KC705:
/// Y = 16 + (47R + 157G + 16B), Cb = 128 + (-26R - 87G + 112B) and
/// Cr = 128 + (112R - 102G - 10B). Each result is bits 15:8 of the sum.
class HarborBt709 {
  static const yR = 47, yG = 157, yB = 16;
  static const cbR = -26, cbG = -87, cbB = 112;
  static const crR = 112, crG = -102, crB = -10;

  /// Offsets in the 8.8 sum: 16 and 128 in the integer part.
  static const yOffset = 16 * 256 + 128;
  static const cOffset = 128 * 256 + 128;

  /// The 16 bit bus value of an inactive pixel: Cb of 0x80 and Y of 0x10.
  static const blank = 0x8010;

  static int _clip(int sum) => (sum & 0xffff) >> 8;

  static int y(int r, int g, int b) => _clip(yR * r + yG * g + yB * b + yOffset);
  static int cb(int r, int g, int b) =>
      _clip(cbR * r + cbG * g + cbB * b + cOffset);
  static int cr(int r, int g, int b) =>
      _clip(crR * r + crG * g + crB * b + cOffset);
}

/// RGB to 16 bit YCbCr 4:2:2 in the pixel clock domain.
///
/// The inputs are the registered RGB, DE and syncs of the display core. The
/// outputs come 3 clocks later: one stage of products, one of sums, one of
/// the output registers. [d] has Y in bits 7:0 and, in bits 15:8, Cb on an
/// even pixel and Cr on an odd pixel. The chroma comes from the even pixel
/// of each pair. The pair phase restarts at each rise of DE, so a line
/// always starts on an even pixel. [d] is 0x8010 while DE is low.
///
/// [tog] flips on each pixel clock. The pin stage reads it to find the
/// pixel boundary.
class HarborYcbcr422Converter extends Module {
  /// Clocks between an input pixel and its output.
  static const latency = 3;

  Logic get d => output('d');
  Logic get de => output('de_out');
  Logic get hsync => output('hsync_out');
  Logic get vsync => output('vsync_out');
  Logic get tog => output('tog');

  HarborYcbcr422Converter({
    required Logic clk,
    required Logic reset,
    required Logic red,
    required Logic green,
    required Logic blue,
    required Logic de,
    required Logic hsync,
    required Logic vsync,
    bool hsyncPositive = false,
    bool vsyncPositive = false,
    super.name = 'ycbcr422',
  }) : super(
         definitionName:
             'HarborYcbcr422Converter_'
             '${hsyncPositive ? 'p' : 'n'}${vsyncPositive ? 'p' : 'n'}',
       ) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    red = addInput('red', red, width: 8);
    green = addInput('green', green, width: 8);
    blue = addInput('blue', blue, width: 8);
    de = addInput('de', de);
    hsync = addInput('hsync', hsync);
    vsync = addInput('vsync', vsync);
    addOutput('d', width: 16);
    addOutput('de_out');
    addOutput('hsync_out');
    addOutput('vsync_out');
    addOutput('tog');

    Logic f(Logic v, String n, {int? resetValue}) => flop(
      clk,
      v,
      reset: reset,
      resetValue: resetValue ?? 0,
    ).named(n);

    Logic mul(Logic c, int k) =>
        (c.zeroExtend(18) * Const(k & 0x3ffff, width: 18));

    // Parity of the pixel inside a run of DE.
    final parity = Logic(name: 'parity');
    parity <= flop(clk, ~parity & de, reset: reset);
    final odd1 = f(parity, 'odd1');
    final de1 = f(de, 'de1');
    final hs1 = f(
      hsync,
      'hs1',
      resetValue: hsyncPositive ? 0 : 1,
    );
    final vs1 = f(
      vsync,
      'vs1',
      resetValue: vsyncPositive ? 0 : 1,
    );

    // Stage 1: products.
    final yr = f(mul(red, HarborBt709.yR), 'yr');
    final yg = f(mul(green, HarborBt709.yG), 'yg');
    final yb = f(mul(blue, HarborBt709.yB), 'yb');
    final ur = f(mul(red, HarborBt709.cbR), 'ur');
    final ug = f(mul(green, HarborBt709.cbG), 'ug');
    final ub = f(mul(blue, HarborBt709.cbB), 'ub');
    final vr = f(mul(red, HarborBt709.crR), 'vr');
    final vg = f(mul(green, HarborBt709.crG), 'vg');
    final vb = f(mul(blue, HarborBt709.crB), 'vb');

    // Stage 2: sums.
    Logic sum(Logic a, Logic b, Logic c, int off) =>
        (a + b + c + Const(off, width: 18));
    final y2 = f(
      sum(yr, yg, yb, HarborBt709.yOffset).getRange(8, 16),
      'y2',
    );
    final cb2 = f(
      sum(ur, ug, ub, HarborBt709.cOffset).getRange(8, 16),
      'cb2',
    );
    final cr2 = f(
      sum(vr, vg, vb, HarborBt709.cOffset).getRange(8, 16),
      'cr2',
    );
    final odd2 = f(odd1, 'odd2');
    final de2 = f(de1, 'de2');
    final hs2 = f(hs1, 'hs2', resetValue: hsyncPositive ? 0 : 1);
    final vs2 = f(vs1, 'vs2', resetValue: vsyncPositive ? 0 : 1);

    // Stage 3: the output registers. The odd pixel takes the Cr that the
    // even pixel stored one clock before.
    final crHold = Logic(name: 'cr_hold', width: 8);
    crHold <= flop(clk, cr2, en: ~odd2, reset: reset);
    final chroma = mux(odd2, crHold, cb2);
    output('d') <=
        flop(
          clk,
          mux(de2, [chroma, y2].concat(), Const(HarborBt709.blank, width: 16)),
          reset: reset,
          resetValue: HarborBt709.blank,
        );
    output('de_out') <= f(de2, 'de3');
    output('hsync_out') <= f(hs2, 'hs3', resetValue: hsyncPositive ? 0 : 1);
    output('vsync_out') <= f(vs2, 'vs3', resetValue: vsyncPositive ? 0 : 1);
    final tg = Logic(name: 'tog_q');
    tg <= flop(clk, ~tg, reset: reset);
    output('tog') <= tg;
  }
}

/// The pin stage of an ADV7511 output, on the clock of twice the pixel
/// rate.
///
/// It reads [tog] of the converter to find the first 2x clock after each
/// pixel clock edge. At that clock the pins take the new pixel and [clkOut]
/// goes high. The next clock sets it low. The pin clock has the pixel rate,
/// and each data change lines up with its rising edge.
class HarborAdv7511PinStage extends Module {
  Logic get d => output('pin_d');
  Logic get de => output('pin_de');
  Logic get hsync => output('pin_hsync');
  Logic get vsync => output('pin_vsync');
  Logic get clkOut => output('pin_clk');

  HarborAdv7511PinStage({
    required Logic clk2x,
    required Logic reset,
    required Logic tog,
    required Logic d,
    required Logic de,
    required Logic hsync,
    required Logic vsync,
    bool hsyncPositive = false,
    bool vsyncPositive = false,
    super.name = 'adv7511_pins',
  }) : super(
         definitionName:
             'HarborAdv7511PinStage_'
             '${hsyncPositive ? 'p' : 'n'}${vsyncPositive ? 'p' : 'n'}',
       ) {
    clk2x = addInput('clk2x', clk2x);
    reset = addInput('reset', reset);
    tog = addInput('tog', tog);
    d = addInput('d', d, width: 16);
    de = addInput('de', de);
    hsync = addInput('hsync', hsync);
    vsync = addInput('vsync', vsync);
    addOutput('pin_d', width: 16);
    addOutput('pin_de');
    addOutput('pin_hsync');
    addOutput('pin_vsync');
    addOutput('pin_clk');

    final seen = flop(clk2x, tog, reset: reset);
    final fresh = (tog ^ seen).named('fresh');
    Logic take(Logic v, {int resetValue = 0}) => flop(
      clk2x,
      v,
      en: fresh,
      reset: reset,
      resetValue: resetValue,
    );
    output('pin_d') <= take(d, resetValue: HarborBt709.blank);
    output('pin_de') <= take(de);
    output('pin_hsync') <= take(hsync, resetValue: hsyncPositive ? 0 : 1);
    output('pin_vsync') <= take(vsync, resetValue: vsyncPositive ? 0 : 1);
    output('pin_clk') <= flop(clk2x, fresh, reset: reset);
  }
}

/// Makes the pixel clock from the 2x clock on a Xilinx 7-series part.
///
/// A flop on [clk2x] toggles each clock, and a BUFG puts the result on a
/// clock net. The pixel clock edge follows a 2x clock edge, so the two
/// clocks keep a fixed phase. The pixel reset is [reset] taken in the pixel
/// clock through two flops.
///
/// The module reports the pixel clock net to the SoC clock constraints.
class HarborAdv7511PixelClock extends BridgeModule with HarborClockRateProvider {
  /// Rate of the pixel clock in Hz.
  final double pixelHz;

  Logic get pixelClk => output('pixel_clk');
  Logic get pixelReset => output('pixel_reset');

  HarborAdv7511PixelClock({
    required Logic clk2x,
    required Logic reset,
    required this.pixelHz,
    super.name = 'adv7511_pixel_clock',
  }) : super('HarborAdv7511PixelClock') {
    clk2x = addInput('clk2x', clk2x);
    reset = addInput('reset', reset);
    addOutput('pixel_clk');
    addOutput('pixel_reset');

    final phase = Logic(name: 'phase');
    phase <= flop(clk2x, ~phase, reset: reset);
    final bufg = XilinxBufg(name: 'pixel_bufg');
    bufg.input('I').srcConnection! <= phase;
    final clk = bufg.output('O').named('pixel_clk_net');
    output('pixel_clk') <= clk;
    final pipe = Logic(name: 'reset_pipe', width: 2);
    Sequential(clk, reset: reset, [pipe < [pipe[0], Const(1)].concat()]);
    output('pixel_reset') <= (reset | ~pipe[1]).named('pixel_reset_net');
  }

  @override
  Map<String, double> clockRates(String instance) => {
    '$instance.pixel_clk_net': pixelHz / 1e6,
  };
}
