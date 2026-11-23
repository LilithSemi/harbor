import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/mem_target.dart';
import '../util/sd_cmd_probe.dart';

// Register byte offsets: each register in its own 8-byte slot (the byte-addressed
// fabric decodes byte-offset >> 3).
const _ctrl = 0x00;
const _status = 0x08;
const _clkDiv = 0x10;
const _cmd = 0x18;
const _cmdArg = 0x20;
const _intStatus = 0x60;
const _intEnable = 0x68;

/// Reference SD CRC7 (x^7 + x^3 + 1) over an MSB-first bit list, mirroring the
/// hardware. Returns 7 bits, MSB-first.
List<int> _crc7(List<int> bits) {
  var c = List<int>.filled(7, 0);
  for (final b in bits) {
    final inv = b ^ c[6];
    c = [inv, c[0], c[1], c[2] ^ inv, c[3], c[4], c[5]];
  }
  return [c[6], c[5], c[4], c[3], c[2], c[1], c[0]];
}

List<int> _bitsMsb(int value, int width) => [
  for (var i = width - 1; i >= 0; i--) (value >> i) & 1,
];

void main() {
  group('HarborSdioController CMD engine', () {
    late HarborSdioController sdio;
    late Logic clk, reset, stb, we, adr, mosi;
    late Logic cmdIn, cmdOut, cmdOe, sdClk, irq;
    late Logic datIn;
    late Logic cardDetectLine;
    late MasterTop top;
    var cmdProbe = SdCmdProbe();
    late BeatMemory memory;

    // The frames most tests send carry no valid CRC7 or index, so the
    // command skips those checks unless a test turns [strictResponse] on.
    var strictResponse = false;

    Future<void> busWrite(int addr, int data) async {
      adr.inject(addr);
      mosi.inject(addr == _cmd && !strictResponse ? data | 0x3000 : data);
      we.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (top.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      stb.inject(0);
      we.inject(0);
      await clk.nextPosedge;
    }

    Future<int> busRead(int addr) async {
      adr.inject(addr);
      we.inject(0);
      stb.inject(1);
      await clk.nextPosedge;
      while (top.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final v = top.output('bus_DAT_MISO').value.toInt();
      stb.inject(0);
      await clk.nextPosedge;
      return v;
    }

    Future<void> setUpDut({
      List<int> dmaMem = const [],
      int ackDelay = 0,
      int fifoDepth = 16,
      int dmaDataWidth = 32,
      HarborSdioConfig? config,
      int cardDetectLevel = 0,
      int? writeBusyTimeout,
    }) async {
      strictResponse = false;
      cmdProbe = SdCmdProbe();
      sdio = HarborSdioController(
        baseAddress: 0x60000000,
        config: config ?? const HarborSdioConfig.sd(),
        rxFifoDepth: fifoDepth,
        writeBusyTimeout: writeBusyTimeout,
        dmaDataWidth: dmaDataWidth,
      );
      top = MasterTop(
        sdio,
        iface: 'dma',
        kind: HarborFabricKind.wishbone,
        config: HarborMemoryWaistConfig(
          addressWidth: 32,
          dataWidth: dmaDataWidth,
          outstanding: 4,
        ),
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      stb = Logic(name: 'stb');
      we = Logic(name: 'we');
      adr = Logic(name: 'adr', width: 12);
      mosi = Logic(name: 'mosi', width: 32);
      cmdIn = Logic(name: 'cmd_in');
      datIn = Logic(name: 'dat_in', width: 4);
      cardDetectLine = Logic(name: 'card_detect');

      top.input('clk').srcConnection! <= clk;
      top.input('reset').srcConnection! <= reset;
      top.input('bus_CYC').srcConnection! <= stb;
      top.input('bus_STB').srcConnection! <= stb;
      top.input('bus_WE').srcConnection! <= we;
      top.input('bus_ADR').srcConnection! <= adr;
      top.input('bus_DAT_MOSI').srcConnection! <= mosi;
      top.input('bus_SEL').srcConnection! <=
          Const(0xF, width: top.input('bus_SEL').width);
      top.input('sd_cmd_in').srcConnection! <= cmdIn;
      top.input('sd_cd').srcConnection! <= cardDetectLine;
      top.input('sd_dat_in').srcConnection! <= datIn;

      // [ackDelay] holds every beat off for that many cycles, the way a real
      // DDR controller does.
      memory = BeatMemory(top, clk, latency: ackDelay);

      await top.build();
      for (var i = 0; i < dmaMem.length; i++) {
        memory.writeBytes(4 * i, dmaMem[i], 4);
      }

      cmdOut = top.output('sd_cmd_out');
      cmdOe = top.output('sd_cmd_oe');
      sdClk = top.output('sd_clk');
      irq = top.output('interrupt');

      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      cmdIn.inject(1); // CMD line idles high
      datIn.inject(0);
      cardDetectLine.inject(cardDetectLevel);
      memory.start();
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      // Enable, fastest clock (toggle every cycle), unmask cmd-done + timeout.
      await busWrite(_clkDiv, 0);
      await busWrite(_intEnable, 0x11);
      await busWrite(_ctrl, 0x1);
    }

    tearDown(() async {
      await Simulator.reset();
    });

    List<int> r1Frame(int index, {int crcXor = 0, int end = 1, int tx = 0}) {
      final head = [0, tx, ..._bitsMsb(index, 6), ..._bitsMsb(0x900, 32)];
      final crc = _bitsMsb(
        _crc7(head).fold<int>(0, (a, b) => (a << 1) | b) ^ crcXor,
        7,
      );
      return [...head, ...crc, end];
    }

    List<int> r2Frame({int crcXor = 0}) {
      final data = [for (var i = 0; i < 120; i++) (i * 7 + 3) & 1];
      final crc = _bitsMsb(
        _crc7(data).fold<int>(0, (a, b) => (a << 1) | b) ^ crcXor,
        7,
      );
      return [0, 0, ...List.filled(6, 1), ...data, ...crc, 1];
    }

    Logic sig(String n) => sdio.signals.firstWhere((x) => x.name == n);

    // Sends [cmd] and answers it with [frame]. After the last response bit it
    // waits [lateAfter] SD clocks and then pulls CMD low for [lateLow] clocks,
    // as a card does that answers late. It checks every clock that the host pad
    // enable is low while the card drives. With [rewrite] software writes a new
    // command as soon as the error shows. The result is the host pad enable
    // and value [settle] SD clocks after the card lets go, and the SD clocks
    // from the end of the frame to the first low bit the host sends.
    Future<(int, int, int)> lateCard(
      List<int> frame, {
      int cmd = 13 | (1 << 6),
      required int lateAfter,
      required int lateLow,
      int settle = 0,
      bool rewrite = false,
    }) async {
      await setUpDut();
      strictResponse = true;
      await busWrite(_intEnable, 0xE11);
      await busWrite(_cmdArg, 0);
      await busWrite(_cmd, cmd);
      var sawDrive = false;
      var k = 0;
      var prev = sdClk.value.toInt();
      var clocks = 0;
      var cardLow = false;
      var rewritten = false;
      var hostStart = -1;
      for (var i = 0; i < 60000 && clocks < lateAfter + lateLow + settle; i++) {
        await clk.nextPosedge;
        final sending = cmdProbe.sending(cmdOe, cmdOut);
        if (sending) sawDrive = true;
        if (rewritten && sending && hostStart < 0) hostStart = clocks;
        final c = sdClk.value.toInt();
        if (sawDrive && !sending && c == 0 && k < frame.length) {
          cmdIn.inject(frame[k++]);
        }
        if (rewrite && !rewritten && irq.value.toInt() == 1) {
          rewritten = true;
          unawaited(() async {
            await busWrite(_intStatus, 0x1FF);
            await busWrite(_cmd, 13 | (1 << 6));
          }());
        }
        if (prev == 0 && c == 1 && k == frame.length) {
          clocks++;
          if (clocks == lateAfter) {
            cardLow = true;
            cmdIn.inject(0);
          }
          if (clocks == lateAfter + lateLow) {
            cardLow = false;
            cmdIn.inject(1);
          }
        }
        prev = c;
        if (cardLow) {
          expect(cmdOe.value.toInt(), equals(0), reason: 'host drives CMD');
        }
      }
      return (cmdOe.value.toInt(), cmdOut.value.toInt(), hostStart);
    }

    for (final after in [2, 40, 100, 150]) {
      test(
        'CMD stays released while a card answers $after clocks late',
        () async {
          await lateCard(
            r1Frame(13, crcXor: 1),
            lateAfter: after,
            lateLow: 48,
            settle: 2,
          );
          await Simulator.endSimulation();
        },
      );
    }

    test('CMD stays released through a long late answer', () async {
      await lateCard(
        r2Frame(crcXor: 4),
        cmd: 2 | (2 << 6),
        lateAfter: 2,
        lateLow: 136,
        settle: 2,
      );
      await Simulator.endSimulation();
    });

    test(
      'a command written after the error waits for the quiet time',
      () async {
        final (_, _, hostStart) = await lateCard(
          r1Frame(13, crcXor: 1),
          lateAfter: 20,
          lateLow: 100,
          settle: 300,
          rewrite: true,
        );
        expect(hostStart, greaterThanOrEqualTo(195));
        await Simulator.endSimulation();
      },
    );

    test('CMD stays released after the quiet time', () async {
      final (oe, _, _) = await lateCard(
        r1Frame(13, crcXor: 1),
        lateAfter: 20,
        lateLow: 16,
        settle: 240,
      );
      expect(oe, equals(0));
      await Simulator.endSimulation();
    });

    // Clears enable while a command is on the wire. The state stops, CMD is
    // released and stays so for the quiet time after enable returns.
    for (final state in [1, 4]) {
      test(
        'clearing enable in state $state releases CMD for the quiet time',
        () async {
          await setUpDut();
          strictResponse = true;
          await busWrite(_intEnable, 0xE11);
          final cmdState = sig('cmd_state');
          await busWrite(_clkDiv, 6);
          await busWrite(_cmdArg, 0);
          await busWrite(_cmd, 13 | (1 << 6));
          for (var i = 0; i < 4000; i++) {
            await clk.nextPosedge;
            if (cmdState.value.toInt() == state) break;
          }
          expect(cmdState.value.toInt(), equals(state));
          await busWrite(_ctrl, 0x10);
          for (var i = 0; i < 10; i++) {
            await clk.nextPosedge;
          }
          expect(cmdState.value.toInt(), equals(0));
          expect(cmdOe.value.toInt(), equals(0));
          expect((await busRead(_status) >> 8) & 1, equals(0));
          expect((await busRead(_intStatus)) & 0x10, equals(0x10));
          await busWrite(_ctrl, 0x11);
          await busWrite(_cmdArg, 0);
          await busWrite(_cmd, 13 | (1 << 6));
          var rises = 0;
          var prev = sdClk.value.toInt();
          var firstOe = -1;
          for (var i = 0; i < 20000 && firstOe < 0; i++) {
            await clk.nextPosedge;
            final c = sdClk.value.toInt();
            if (prev == 0 && c == 1) rises++;
            prev = c;
            if (cmdOe.value.toInt() == 1) firstOe = rises;
          }
          expect(firstOe, inInclusiveRange(190, 210));
          await Simulator.endSimulation();
        },
      );
    }

    test('CMD is released at rest and while waiting', () async {
      await setUpDut();
      strictResponse = true;
      await busWrite(_intEnable, 0xE11);
      final frame = r1Frame(13);
      expect(cmdOe.value.toInt(), equals(0));
      await busWrite(_cmdArg, 0);
      await busWrite(_cmd, 13 | (1 << 6));
      var sawDrive = false;
      var k = 0;
      final states = <int>{};
      for (var i = 0; i < 3000; i++) {
        await clk.nextPosedge;
        final sending = cmdProbe.sending(cmdOe, cmdOut);
        if (sending) sawDrive = true;
        if (sawDrive &&
            !sending &&
            sdClk.value.toInt() == 0 &&
            k < frame.length) {
          cmdIn.inject(frame[k++]);
        }
        final st = sig('cmd_state').value.toInt();
        states.add(st);
        if (st == 0 || st == 2 || st == 3) {
          expect(cmdOe.value.toInt(), equals(0), reason: 'state $st');
        }
        if (irq.value.toInt() == 1) break;
      }
      expect(states, containsAll([0, 1, 2, 3]));
      await Simulator.endSimulation();
    });

    Future<void> expectReleased(int cycles, String when) async {
      for (var i = 0; i < cycles; i++) {
        await clk.nextPosedge;
        expect(cmdOe.value.toInt(), equals(0), reason: when);
      }
    }

    test('CMD is released after reset and while reset is held', () async {
      await setUpDut();
      await expectReleased(100, 'after reset');
      reset.inject(1);
      await expectReleased(5, 'in reset');
      reset.inject(0);
      await expectReleased(50, 'after reset again');
      await Simulator.endSimulation();
    });

    test('CMD is released after a good response', () async {
      await setUpDut();
      await busWrite(_intEnable, 0xE11);
      await busWrite(_cmdArg, 0);
      await busWrite(_cmd, 13 | (1 << 6));
      final frame = r1Frame(13);
      var sawDrive = false;
      var k = 0;
      for (var i = 0; i < 3000 && irq.value.toInt() == 0; i++) {
        await clk.nextPosedge;
        final sending = cmdProbe.sending(cmdOe, cmdOut);
        if (sending) sawDrive = true;
        if (sawDrive &&
            !sending &&
            sdClk.value.toInt() == 0 &&
            k < frame.length) {
          cmdIn.inject(frame[k++]);
        }
      }
      expect(irq.value.toInt(), equals(1));
      cmdIn.inject(1);
      await expectReleased(300, 'after a good response');
      await Simulator.endSimulation();
    });

    test('CMD is released after a response error', () async {
      final (oe, _, _) = await lateCard(
        r1Frame(13, crcXor: 1),
        lateAfter: 2,
        lateLow: 2,
        settle: 2,
      );
      expect(oe, equals(0));
      await expectReleased(300, 'after a response error');
      await Simulator.endSimulation();
    });

    test('CMD is released after a timeout', () async {
      await setUpDut();
      await busWrite(_intEnable, 0xE11);
      await busWrite(_cmdArg, 0);
      await busWrite(_cmd, 13 | (1 << 6));
      for (var i = 0; i < 60000 && irq.value.toInt() == 0; i++) {
        await clk.nextPosedge;
      }
      expect(irq.value.toInt(), equals(1));
      expect((await busRead(_intStatus)) & 0x10, equals(0x10));
      await expectReleased(300, 'after a timeout');
      await Simulator.endSimulation();
    });

    test('CMD is released after a clock stop', () async {
      await setUpDut();
      await busWrite(_intEnable, 0xE11);
      await busWrite(_cmdArg, 0);
      await busWrite(_cmd, 13 | (1 << 6));
      for (var i = 0; i < 4000 && sig('cmd_state').value.toInt() != 1; i++) {
        await clk.nextPosedge;
      }
      await busWrite(_ctrl, 0x10);
      await expectReleased(300, 'after a clock stop');
      await Simulator.endSimulation();
    });

    test('CMD is driven only from the start bit to the end-bit hold', () async {
      await setUpDut();
      await busWrite(_intEnable, 0xE11);
      await expectReleased(20, 'before the command');
      await busWrite(_cmdArg, 0);
      await busWrite(_cmd, 13 | (1 << 6));
      var prevOe = 0;
      var pulses = 0;
      var prevClk = sdClk.value.toInt();
      var risesWhileOe = 0;
      for (var i = 0; i < 3000 && irq.value.toInt() == 0; i++) {
        await clk.nextPosedge;
        final oe = cmdOe.value.toInt();
        if (oe == 1 && prevOe == 0) pulses++;
        final c = sdClk.value.toInt();
        if (oe == 1 && prevClk == 0 && c == 1) risesWhileOe++;
        prevOe = oe;
        prevClk = c;
      }
      expect(pulses, equals(1));
      expect(risesWhileOe, inInclusiveRange(48, 50));
      await Simulator.endSimulation();
    });

    test(
      'a card that holds CMD low at rest never meets a host drive',
      () async {
        await setUpDut();
        cmdIn.inject(0);
        await expectReleased(300, 'card low, idle');
        reset.inject(1);
        await expectReleased(5, 'card low, reset');
        reset.inject(0);
        await expectReleased(100, 'card low, after reset');
        await Simulator.endSimulation();
      },
    );
  });
}
