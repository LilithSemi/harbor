import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Wishbone slave that returns a pattern made from the word address.
///
/// It acks one cycle after a request, the same pace as a simple memory, so
/// the scanout DMA fills its line buffers the way it does in a real design.
class DviPatternSlave extends Module {
  Logic get ack => output('ack');
  Logic get datR => output('dat_r');

  DviPatternSlave({
    required Logic clk,
    required Logic reset,
    required Logic cyc,
    required Logic stb,
    required Logic adr,
  }) : super(name: 'pattern') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    cyc = addInput('cyc', cyc);
    stb = addInput('stb', stb);
    adr = addInput('adr', adr, width: 32);
    final ack = addOutput('ack');
    final datR = addOutput('dat_r', width: 32);

    final word = adr.getRange(2, 26);
    Sequential(clk, reset: reset, [
      ack < cyc & stb & ~ack,
      datR < [word.getRange(0, 8), word ^ (word >>> 5)].swizzle(),
    ]);
  }
}

/// Ulx3s top for the display place and route check.
///
/// One ehxplll makes the 125 MHz shift clock (clkop) and the 25 MHz pixel
/// clock (clkos). The 25 MHz oscillator clocks the scanout DMA and a
/// [DviPatternSlave]. [HarborDualClockDisplay] drives the four gpdi lanes.
class DviUlx3sTop extends BridgeModule {
  late final HarborDualClockDisplay display;

  DviUlx3sTop({
    required HarborFpgaTarget target,
    HarborDisplayTiming timing = const HarborDisplayTiming.vga640x480(),
    int pixelHz = 25000000,
  }) : super('DviUlx3sTop', name: 'top') {
    createPort('clk', PortDirection.input);
    createPort('rst_n', PortDirection.input);
    addOutput('gpdi_dp', width: 4);
    addOutput('led', width: 8);

    final gen = HarborClockGenerator(
      parent: this,
      inputClk: input('clk'),
      inputReset: ~input('rst_n'),
      target: target,
    );
    final pair = gen.createDomainWithSecondary(
      HarborClockConfig.fixed(
        name: 'shift',
        frequency: pixelHz * 5,
        sourceFrequency: 25000000,
      ),
      secondaryFrequency: pixelHz,
      secondaryName: 'pixel',
    );
    final sys = gen.createDomain(
      HarborClockConfig.fixed(
        name: 'sys',
        frequency: 25000000,
        sourceFrequency: 25000000,
        isPrimary: true,
      ),
    );

    final mAck = Logic(name: 'm_ack');
    final mDat = Logic(name: 'm_dat', width: 32);
    display = HarborDualClockDisplay(
      target: target,
      timing: timing,
      pixelClk: pair.secondary.clk,
      pixelReset: pair.secondary.reset,
      shiftClk: pair.primary.clk,
      shiftReset: pair.primary.reset,
      sysClk: sys.clk,
      sysReset: sys.reset,
      enable: Const(1),
      fbBase: Const(0x1000, width: 32),
      mDataIn: mDat,
      mAck: mAck,
    );
    final slave = DviPatternSlave(
      clk: sys.clk,
      reset: sys.reset,
      cyc: display.mCyc,
      stb: display.mStb,
      adr: display.mAddr,
    );
    mAck <= slave.ack;
    mDat <= slave.datR;

    output('gpdi_dp') <= display.gpdi;
    output('led') <= [Const(0, width: 7), display.underrun].swizzle();
  }
}
