import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Functional read-path test for [HarborSpiFlashController]. The prior stub
/// never sampled the data line and sent the command/address as leading zeros.
/// This drives a known bitstream on MISO and checks the controller returns the
/// correct little-endian word (byte at the lowest flash address -> bits [7:0]).
///
/// Standard SPI (0x03) is used because MISO is a plain INPUT (drivable from the
/// testbench without an inout co-sim). The read-data assembly + byte-swap +
/// command/address shift-out are identical to the quad path (which only differs
/// in bitsPerCycle and sampling the bidirectional spi_io instead of MISO).
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('standard 0x03 read assembles the little-endian word from MISO', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final stb = Logic(name: 'stb');
    final addr = Logic(name: 'addr', width: 32);
    final miso = Logic(name: 'miso');

    final flash = HarborSpiFlashController(
      config: const HarborSpiFlashConfig(
        size: 1024 * 1024,
        mode: HarborSpiFlashMode.standard,
        readCommand: 0x03,
        addressBytes: 3,
        dummyCycles: 0,
      ),
      baseAddress: 0x20000000,
      busAddressWidth: 32,
      busDataWidth: 32,
    );

    flash.input('clk').srcConnection! <= clk;
    flash.input('reset').srcConnection! <= reset;
    flash.input('bus_CYC').srcConnection! <= stb;
    flash.input('bus_STB').srcConnection! <= stb;
    flash.input('bus_WE').srcConnection! <= Const(0);
    flash.input('bus_ADR').srcConnection! <= addr;
    flash.input('bus_DAT_MOSI').srcConnection! <= Const(0, width: 32);
    flash.input('bus_SEL').srcConnection! <=
        Const(0xF, width: flash.input('bus_SEL').width);
    flash.input('spi_miso').srcConnection! <= miso;
    // Tie off the write/erase command interface (idle) so the write engine
    // stays in its idle state and the read FSM owns the SPI pins.
    flash.input('wr_req').srcConnection! <= Const(0);
    flash.input('wr_op').srcConnection! <= Const(0);
    flash.input('wr_addr').srcConnection! <= Const(0, width: 24);
    flash.input('wr_len').srcConnection! <= Const(0, width: 9);
    flash.input('wr_data').srcConnection! <= Const(0, width: 8);

    await flash.build();

    final spiClk = flash.output('spi_clk');
    final csN = flash.output('spi_cs_n');
    final ack = flash.output('bus_ACK');
    final misoOut = flash.output('bus_DAT_MISO');

    // Flash bytes returned (in flash address order): byte0 first, MSB-first.
    final bytes = [0xDE, 0xAD, 0xBE, 0xEF];
    // The controller shifts MISO in MSB-first then byte-swaps, so the CPU word
    // is little-endian: byte0 -> bits[7:0].
    final expected =
        bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);
    // 32 data bits, MSB-first across byte0..byte3.
    final dataBits = <int>[
      for (final b in bytes)
        for (var i = 7; i >= 0; i--) (b >> i) & 1,
    ];
    const dataStart = 8 + 24; // cmd + 24-bit address, all 1-bit

    reset.inject(1);
    stb.inject(0);
    addr.inject(0);
    miso.inject(0);
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    addr.inject(0x40);
    stb.inject(1);

    // Procedurally model the flash MISO: count spi_clk rising edges since CS
    // asserted. The controller samples on the following falling edge, so the
    // bit presented at rising edge k (k>=dataStart) is captured as data bit
    // k-dataStart.
    var prevClk = 0;
    var riseCount = 0;
    var prevCs = 1;
    var got = false;
    var data = 0;
    for (var i = 0; i < 1200; i++) {
      await clk.nextPosedge;
      final cs = csN.value.toInt();
      final sc = spiClk.value.toInt();
      if (cs == 1) {
        riseCount = 0;
      } else {
        if (prevCs == 1) riseCount = 0; // CS just asserted
        if (sc == 1 && prevClk == 0) {
          // rising edge: present the bit to be sampled at the next falling edge
          final idx = riseCount - dataStart;
          miso.inject(idx >= 0 && idx < dataBits.length ? dataBits[idx] : 0);
          riseCount++;
        }
      }
      prevClk = sc;
      prevCs = cs;

      if (ack.value.isValid && ack.value.toBool()) {
        data = misoOut.value.toInt();
        got = true;
        break;
      }
    }
    stb.inject(0);

    expect(got, isTrue, reason: 'controller never asserted ack');
    expect(
      data,
      equals(expected),
      reason:
          'got 0x${data.toRadixString(16)} '
          'expected 0x${expected.toRadixString(16)}',
    );

    await Simulator.endSimulation();
  });

  test(
    'readAheadWords: one command fills a line, sequential reads hit buffer',
    () async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final stb = Logic(name: 'stb');
      final addr = Logic(name: 'addr', width: 32);
      final miso = Logic(name: 'miso');

      // 4-word (16-byte) read-ahead line.
      final flash = HarborSpiFlashController(
        config: const HarborSpiFlashConfig(
          size: 1024 * 1024,
          mode: HarborSpiFlashMode.standard,
          readCommand: 0x03,
          addressBytes: 3,
          dummyCycles: 0,
          readAheadWords: 4,
        ),
        baseAddress: 0x20000000,
        busAddressWidth: 32,
        busDataWidth: 32,
      );
      flash.input('clk').srcConnection! <= clk;
      flash.input('reset').srcConnection! <= reset;
      flash.input('bus_CYC').srcConnection! <= stb;
      flash.input('bus_STB').srcConnection! <= stb;
      flash.input('bus_WE').srcConnection! <= Const(0);
      flash.input('bus_ADR').srcConnection! <= addr;
      flash.input('bus_DAT_MOSI').srcConnection! <= Const(0, width: 32);
      flash.input('bus_SEL').srcConnection! <=
          Const(0xF, width: flash.input('bus_SEL').width);
      flash.input('spi_miso').srcConnection! <= miso;
      flash.input('wr_req').srcConnection! <= Const(0);
      flash.input('wr_op').srcConnection! <= Const(0);
      flash.input('wr_addr').srcConnection! <= Const(0, width: 24);
      flash.input('wr_len').srcConnection! <= Const(0, width: 9);
      flash.input('wr_data').srcConnection! <= Const(0, width: 8);

      await flash.build();

      final spiClk = flash.output('spi_clk');
      final csN = flash.output('spi_cs_n');
      final ack = flash.output('bus_ACK');
      final misoOut = flash.output('bus_DAT_MISO');

      // 16 bytes at the line base (flash addr order, byte0 lowest). The controller
      // streams all 16 in one command, then serves each word little-endian.
      final line = [for (var i = 0; i < 16; i++) (i * 17 + 3) & 0xFF];
      final expectedWords = [
        for (var w = 0; w < 4; w++)
          line[w * 4] |
              (line[w * 4 + 1] << 8) |
              (line[w * 4 + 2] << 16) |
              (line[w * 4 + 3] << 24),
      ];
      final dataBits = <int>[
        for (final b in line)
          for (var i = 7; i >= 0; i--) (b >> i) & 1,
      ];
      const dataStart = 8 + 24;

      reset.inject(1);
      stb.inject(0);
      addr.inject(0);
      miso.inject(0);
      Simulator.setMaxSimTime(8000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      var prevClk = 0;
      var riseCount = 0;
      var prevCs = 1;
      var csAssertions = 0;

      // Read one word at `a`, driving the MISO model. Returns the data word.
      Future<int> readWord(int a) async {
        addr.inject(a);
        stb.inject(1);
        var got = false;
        var data = 0;
        for (var i = 0; i < 2000 && !got; i++) {
          await clk.nextPosedge;
          final cs = csN.value.toInt();
          final sc = spiClk.value.toInt();
          if (cs == 1) {
            riseCount = 0;
          } else {
            if (prevCs == 1) {
              riseCount = 0;
              csAssertions++; // a fresh flash command (miss)
            }
            if (sc == 1 && prevClk == 0) {
              final idx = riseCount - dataStart;
              miso.inject(
                idx >= 0 && idx < dataBits.length ? dataBits[idx] : 0,
              );
              riseCount++;
            }
          }
          prevClk = sc;
          prevCs = cs;
          if (ack.value.isValid && ack.value.toBool()) {
            data = misoOut.value.toInt();
            got = true;
          }
        }
        stb.inject(0);
        await clk.nextPosedge; // drop stb before the next request
        expect(got, isTrue, reason: 'no ack for addr 0x${a.toRadixString(16)}');
        return data;
      }

      // Four sequential words in the same line: first misses (one flash command),
      // the rest hit the buffer (no new CS assertion).
      for (var w = 0; w < 4; w++) {
        final got = await readWord(0x40 + w * 4);
        expect(
          got,
          equals(expectedWords[w]),
          reason:
              'word $w: got 0x${got.toRadixString(16)} '
              'expected 0x${expectedWords[w].toRadixString(16)}',
        );
      }
      await Simulator.endSimulation();

      expect(
        csAssertions,
        equals(1),
        reason:
            'expected ONE flash command for the whole line, '
            'got $csAssertions',
      );
    },
  );

  test('an aborted read runs as issued, is not acked, and the next read '
      'waits for it', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final stb = Logic(name: 'stb');
    final addr = Logic(name: 'addr', width: 32);

    final flash = HarborSpiFlashController(
      config: const HarborSpiFlashConfig(
        size: 1024 * 1024,
        mode: HarborSpiFlashMode.standard,
        readCommand: 0x03,
        addressBytes: 3,
        dummyCycles: 0,
      ),
      baseAddress: 0x20000000,
      busAddressWidth: 32,
      busDataWidth: 32,
    );
    flash.input('clk').srcConnection! <= clk;
    flash.input('reset').srcConnection! <= reset;
    flash.input('bus_CYC').srcConnection! <= stb;
    flash.input('bus_STB').srcConnection! <= stb;
    flash.input('bus_WE').srcConnection! <= Const(0);
    flash.input('bus_ADR').srcConnection! <= addr;
    flash.input('bus_DAT_MOSI').srcConnection! <= Const(0, width: 32);
    flash.input('bus_SEL').srcConnection! <=
        Const(0xF, width: flash.input('bus_SEL').width);
    flash.input('spi_miso').srcConnection! <= Const(0);
    flash.input('wr_req').srcConnection! <= Const(0);
    flash.input('wr_op').srcConnection! <= Const(0);
    flash.input('wr_addr').srcConnection! <= Const(0, width: 24);
    flash.input('wr_len').srcConnection! <= Const(0, width: 9);
    flash.input('wr_data').srcConnection! <= Const(0, width: 8);
    await flash.build();

    final spiClk = flash.output('spi_clk');
    final csN = flash.output('spi_cs_n');
    final mosi = flash.output('spi_mosi');
    final ack = flash.output('bus_ACK');

    reset.inject(1);
    stb.inject(0);
    addr.inject(0);
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    // Bits on each SCK rise, one list per CS-low frame.
    final frames = <List<int>>[];
    final acksInFrame = <int>[];
    var prevClk = 0;
    var prevCs = 1;
    Future<void> tick() async {
      await clk.nextPosedge;
      final cs = csN.value.toInt();
      final sc = spiClk.value.toInt();
      if (cs == 0 && prevCs == 1) frames.add([]);
      if (cs == 0 && sc == 1 && prevClk == 0) {
        frames.last.add(mosi.value.toInt());
      }
      if (ack.value.toBool()) acksInFrame.add(frames.length - 1);
      prevClk = sc;
      prevCs = cs;
    }

    addr.inject(0x40);
    stb.inject(1);
    for (var i = 0; i < 10; i++) {
      await tick();
    }
    stb.inject(0);
    await tick();
    addr.inject(0x80);
    stb.inject(1);
    for (var i = 0; i < 600 && acksInFrame.isEmpty; i++) {
      await tick();
    }
    stb.inject(0);
    await Simulator.endSimulation();

    int field(List<int> bits, int from, int n) =>
        bits.sublist(from, from + n).fold(0, (a, b) => (a << 1) | b);
    expect(frames.length, 2);
    expect(field(frames[0], 0, 8), 0x03);
    expect(field(frames[0], 8, 24), 0x40);
    expect(field(frames[1], 0, 8), 0x03);
    expect(field(frames[1], 8, 24), 0x80);
    expect(acksInFrame, [1], reason: 'only the second read is acked');
  });
}
