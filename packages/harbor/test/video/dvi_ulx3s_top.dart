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
///
/// With [hdmi] the display is an HDMI build. `btn_fire1` gives
/// `hdmi_enable`, and an LFSR in the pixel domain offers a new packet at
/// each take. With [audio] too, the display sends its own packets. A
/// counter on the sys clock gives the samples, `btn_fire2` and `btn_up`
/// give `audio_fs_sel`, and the leds show the status counts.
class DviUlx3sTop extends BridgeModule {
  late final HarborDualClockDisplay display;

  DviUlx3sTop({
    required HarborFpgaTarget target,
    HarborDisplayTiming timing = const HarborDisplayTiming.vga640x480(),
    int pixelHz = 25000000,
    bool hdmi = false,
    bool audio = false,
  }) : super(
         audio
             ? 'HdmiAudioUlx3sTop'
             : hdmi
             ? 'HdmiUlx3sTop'
             : 'DviUlx3sTop',
         name: 'top',
       ) {
    if (audio && !hdmi) throw ArgumentError('audio needs hdmi');
    createPort('clk', PortDirection.input);
    createPort('rst_n', PortDirection.input);
    if (hdmi) createPort('btn_fire1', PortDirection.input);
    if (audio) {
      createPort('btn_fire2', PortDirection.input);
      createPort('btn_up', PortDirection.input);
    }
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

    // The fetcher's bus is internal only (the pattern slave below), so it
    // is a plain waist + Wishbone master pair, not a fabric-facing port.
    final memWaist = HarborMemoryWaist(
      const HarborMemoryWaistConfig(
        addressWidth: 32,
        dataWidth: 32,
        outstanding: 4,
      ),
    );
    final ready = Logic(name: 'packet_ready');
    final lfsr = Logic(name: 'packet_lfsr', width: 32);
    final sample = Logic(name: 'sample', width: 24);
    final sampleReady = Logic(name: 'sample_ready');
    if (audio) {
      Sequential(sys.clk, reset: sys.reset, [
        If(sampleReady, then: [sample < sample + 0x1234]),
      ]);
    }
    final packets = hdmi && !audio;
    if (packets) {
      // x^32 + x^22 + x^2 + x + 1.
      final fb = lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0];
      Sequential(pair.secondary.clk, reset: pair.secondary.reset, [
        If(
          ready,
          then: [
            lfsr <
                mux(
                  lfsr.eq(0),
                  Const(1, width: 32),
                  [lfsr.getRange(0, 31), fb].swizzle(),
                ),
          ],
        ),
      ]);
    }
    display = HarborDualClockDisplay(
      target: target,
      // N and CTS need the real pixel clock.
      timing: audio
          ? HarborDisplayTiming(
              hActive: timing.hActive,
              hFrontPorch: timing.hFrontPorch,
              hSyncWidth: timing.hSyncWidth,
              hBackPorch: timing.hBackPorch,
              vActive: timing.vActive,
              vFrontPorch: timing.vFrontPorch,
              vSyncWidth: timing.vSyncWidth,
              vBackPorch: timing.vBackPorch,
              pixelClock: pixelHz,
              hSyncPositive: timing.hSyncPositive,
              vSyncPositive: timing.vSyncPositive,
            )
          : timing,
      pixelClk: pair.secondary.clk,
      pixelReset: pair.secondary.reset,
      shiftClk: pair.primary.clk,
      shiftReset: pair.primary.reset,
      sysClk: sys.clk,
      sysReset: sys.reset,
      enable: Const(1),
      update: Const(1),
      fbBase: Const(0x1000, width: 32),
      memory: memWaist,
      hdmi: hdmi,
      hdmiEnable: hdmi ? input('btn_fire1') : null,
      hdmiPacketValid: packets ? Const(1) : null,
      hdmiPacketHeader: packets ? lfsr.getRange(0, 24) : null,
      hdmiPacketSubpacket: packets
          ? [
              for (var k = 0; k < 4; k++)
                [lfsr.getRange(2 * k, 24 + 2 * k), lfsr].swizzle() ^
                    Const(
                      0x5A5A5A5A5A5A5A * (k + 1) & 0xFFFFFFFFFFFFFF,
                      width: 56,
                    ),
            ]
          : null,
      hdmiVic: audio ? Const(1, width: 7) : null,
      audioFsSel: audio
          ? [input('btn_up'), input('btn_fire2')].swizzle()
          : null,
      audioValid: audio ? Const(1) : null,
      audioLeft: audio ? sample : null,
      audioRight: audio ? ~sample : null,
    );
    if (packets) ready <= display.output('hdmi_packet_ready');
    if (audio) sampleReady <= display.output('audio_ready');
    final wb = WishboneInterface(harborWishboneMemoryConfig(memWaist.config));
    HarborWishboneMemoryMaster(
      clk: sys.clk,
      reset: sys.reset,
      waist: memWaist,
      wb: wb,
    );
    final slave = DviPatternSlave(
      clk: sys.clk,
      reset: sys.reset,
      cyc: wb.cyc,
      stb: wb.stb,
      adr: wb.adr,
    );
    wb.ack <= slave.ack;
    wb.datMiso <= slave.datR;
    wb.err! <= Const(0);

    output('gpdi_dp') <= display.gpdi;
    output('led') <=
        (audio
            ? [
                Const(0, width: 4),
                display.output('hdmi_packets_dropped').xor(),
                display.output('hdmi_packets_missed').xor(),
                display.output('audio_underrun_count').xor(),
                display.underrun,
              ].swizzle()
            : [Const(0, width: 7), display.underrun].swizzle());
  }
}
