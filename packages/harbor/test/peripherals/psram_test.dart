import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborPsramController construction', () {
    test('standard mode exposes directional mosi/miso, no bidir', () {
      final p = HarborPsramController(
        config: const HarborPsramConfig(
          size: 8 * 1024 * 1024,
          mode: HarborPsramMode.standard,
        ),
        baseAddress: 0x80000000,
      );
      expect(p.tryOutput('spi_mosi'), isNotNull);
      expect(p.tryInput('spi_miso'), isNotNull);
      expect(p.tryOutput('spi_io_out'), isNull);
      expect(p.tryOutput('spi_io_oe'), isNull);
      expect(p.tryInput('spi_io_in'), isNull);
      expect(p.dtNode.properties['psram-mode'], equals('standard'));
    });

    test('quad mode exposes split io_out/io_oe/io_in, no mosi/miso', () {
      final p = HarborPsramController(
        config: const HarborPsramConfig.aps6404(),
        baseAddress: 0x80000000,
      );
      expect(p.tryOutput('spi_io_out')!.width, equals(4));
      expect(p.tryOutput('spi_io_oe')!.width, equals(4));
      expect(p.tryInput('spi_io_in')!.width, equals(4));
      expect(p.tryOutput('spi_mosi'), isNull);
      expect(p.tryInput('spi_miso'), isNull);
      expect(p.dtNode.properties['psram-mode'], equals('quad'));
      expect(p.dtNode.compatible, contains('harbor,qspi-psram'));
      expect(p.systemMemory.single.size, equals(8 * 1024 * 1024));
    });
  });

  test('standard read round-trips the word shifted in on MISO', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final stb = Logic(name: 'stb');
    final addr = Logic(name: 'addr', width: 32);
    final miso = Logic(name: 'miso');

    final p = HarborPsramController(
      config: const HarborPsramConfig(
        size: 8 * 1024 * 1024,
        mode: HarborPsramMode.standard,
      ),
      baseAddress: 0x80000000,
    );
    p.input('clk').srcConnection! <= clk;
    p.input('reset').srcConnection! <= reset;
    p.input('bus_CYC').srcConnection! <= stb;
    p.input('bus_STB').srcConnection! <= stb;
    p.input('bus_WE').srcConnection! <= Const(0);
    p.input('bus_ADR').srcConnection! <= addr;
    p.input('bus_DAT_MOSI').srcConnection! <= Const(0, width: 32);
    p.input('bus_SEL').srcConnection! <=
        Const(0xF, width: p.input('bus_SEL').width);
    p.input('spi_miso').srcConnection! <= miso;
    await p.build();

    final spiClk = p.output('spi_clk');
    final csN = p.output('spi_cs_n');
    final ack = p.output('bus_ACK');
    final misoOut = p.output('bus_DAT_MISO');

    // The 32 data bits are shifted in MSB-first, so the returned word has the
    // first bit in [31]. Pick a distinctive pattern.
    const word = 0xC3A5F00F;
    final dataBits = <int>[for (var i = 31; i >= 0; i--) (word >> i) & 1];
    const dataStart = 8 + 24; // cmd(8) + addr(24), all single-bit

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

    var prevClk = 0;
    var prevCs = 1;
    var riseCount = 0;
    var got = false;
    var data = 0;
    for (var i = 0; i < 2000; i++) {
      await clk.nextPosedge;
      final cs = csN.value.toInt();
      final sc = spiClk.value.toInt();
      if (cs == 1) {
        riseCount = 0;
        miso.inject(0);
      } else {
        if (prevCs == 1) riseCount = 0;
        // The FSM samples on the SCK rising edge using the value present going
        // into that cycle, so present the next data bit on the preceding
        // falling edge.
        if (sc == 0 && prevClk == 1) {
          final idx = riseCount - dataStart;
          miso.inject(idx >= 0 && idx < dataBits.length ? dataBits[idx] : 0);
        }
        if (sc == 1 && prevClk == 0) riseCount++;
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
      equals(word),
      reason:
          'got 0x${data.toRadixString(16)} expected 0x${word.toRadixString(16)}',
    );
    await Simulator.endSimulation();
  });

  test(
    'quad read round-trips the word shifted in on the four IO lines',
    () async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final stb = Logic(name: 'stb');
      final addr = Logic(name: 'addr', width: 32);
      final ioIn = Logic(name: 'io_in', width: 4);

      final p = HarborPsramController(
        config: const HarborPsramConfig.aps6404(),
        baseAddress: 0x80000000,
      );
      p.input('clk').srcConnection! <= clk;
      p.input('reset').srcConnection! <= reset;
      p.input('bus_CYC').srcConnection! <= stb;
      p.input('bus_STB').srcConnection! <= stb;
      p.input('bus_WE').srcConnection! <= Const(0);
      p.input('bus_ADR').srcConnection! <= addr;
      p.input('bus_DAT_MOSI').srcConnection! <= Const(0, width: 32);
      p.input('bus_SEL').srcConnection! <=
          Const(0xF, width: p.input('bus_SEL').width);
      p.input('spi_io_in').srcConnection! <= ioIn;
      await p.build();

      final spiClk = p.output('spi_clk');
      final csN = p.output('spi_cs_n');
      final ack = p.output('bus_ACK');
      final misoOut = p.output('bus_DAT_MISO');

      // Quad data shifts in 4 bits/cycle, MSB nibble first: word[31:28] first.
      const word = 0xDEADBEEF;
      final nibbles = <int>[for (var i = 28; i >= 0; i -= 4) (word >> i) & 0xF];
      // cmd(8 single edges) + addr(24 bits / 4 = 6 quad edges) + 6 dummy edges.
      const dataStart = 8 + 6 + 6;

      reset.inject(1);
      stb.inject(0);
      addr.inject(0);
      ioIn.inject(0);
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      addr.inject(0x40);
      stb.inject(1);

      var prevClk = 0;
      var prevCs = 1;
      var riseCount = 0;
      var got = false;
      var data = 0;
      for (var i = 0; i < 2000; i++) {
        await clk.nextPosedge;
        final cs = csN.value.toInt();
        final sc = spiClk.value.toInt();
        if (cs == 1) {
          riseCount = 0;
          ioIn.inject(0);
        } else {
          if (prevCs == 1) riseCount = 0;
          // Present the next nibble on the falling edge before the rising-edge
          // sample.
          if (sc == 0 && prevClk == 1) {
            final idx = riseCount - dataStart;
            ioIn.inject(idx >= 0 && idx < nibbles.length ? nibbles[idx] : 0);
          }
          if (sc == 1 && prevClk == 0) riseCount++;
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
        equals(word),
        reason:
            'got 0x${data.toRadixString(16)} expected 0x${word.toRadixString(16)}',
      );
      await Simulator.endSimulation();
    },
  );

  test('an aborted write runs as issued, is not acked, and the next request '
      'waits for it', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final stb = Logic(name: 'stb');
    final we = Logic(name: 'we');
    final addr = Logic(name: 'addr', width: 32);
    final dat = Logic(name: 'dat', width: 32);

    final p = HarborPsramController(
      config: const HarborPsramConfig(
        size: 8 * 1024 * 1024,
        mode: HarborPsramMode.standard,
      ),
      baseAddress: 0x80000000,
    );
    p.input('clk').srcConnection! <= clk;
    p.input('reset').srcConnection! <= reset;
    p.input('bus_CYC').srcConnection! <= stb;
    p.input('bus_STB').srcConnection! <= stb;
    p.input('bus_WE').srcConnection! <= we;
    p.input('bus_ADR').srcConnection! <= addr;
    p.input('bus_DAT_MOSI').srcConnection! <= dat;
    p.input('bus_SEL').srcConnection! <=
        Const(0xF, width: p.input('bus_SEL').width);
    p.input('spi_miso').srcConnection! <= Const(0);
    await p.build();

    final spiClk = p.output('spi_clk');
    final csN = p.output('spi_cs_n');
    final mosi = p.output('spi_mosi');
    final ack = p.output('bus_ACK');

    reset.inject(1);
    stb.inject(0);
    we.inject(0);
    addr.inject(0);
    dat.inject(0);
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    // Bits on each SCK rise, one list per CS-low frame. ACK cycles count by
    // frame index.
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

    we.inject(1);
    addr.inject(0x40);
    dat.inject(0xAABBCCDD);
    stb.inject(1);
    for (var i = 0; i < 10; i++) {
      await tick();
    }
    // Abort, then ask for a read right away.
    stb.inject(0);
    await tick();
    we.inject(0);
    addr.inject(0x80);
    dat.inject(0x11111111);
    stb.inject(1);
    for (var i = 0; i < 400 && acksInFrame.isEmpty; i++) {
      await tick();
    }
    stb.inject(0);
    await Simulator.endSimulation();

    int field(List<int> bits, int from, int n) =>
        bits.sublist(from, from + n).fold(0, (a, b) => (a << 1) | b);
    expect(frames.length, 2);
    expect(field(frames[0], 0, 8), 0x02);
    expect(field(frames[0], 8, 24), 0x40);
    expect(field(frames[0], 32, 32), 0xAABBCCDD);
    expect(field(frames[1], 0, 8), 0x03);
    expect(field(frames[1], 8, 24), 0x80);
    expect(acksInFrame, [1], reason: 'only the read is acked');
  });
}
