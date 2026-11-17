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
const _blkSize = 0x50;
const _blkCount = 0x58;
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

/// Reference SD data CRC16 (CCITT) over an MSB-first bit list. Returns 16 bits,
/// MSB-first.
List<int> _crc16(List<int> bits) {
  var c = List<int>.filled(16, 0);
  for (final b in bits) {
    final inv = b ^ c[15];
    c = [
      for (var i = 0; i < 16; i++)
        if (i == 0)
          inv
        else if (i == 5)
          c[4] ^ inv
        else if (i == 12)
          c[11] ^ inv
        else
          c[i - 1],
    ];
  }
  return [for (var i = 15; i >= 0; i--) c[i]];
}

List<int> _bitsMsb(int value, int width) => [
  for (var i = width - 1; i >= 0; i--) (value >> i) & 1,
];

/// A 4-bit SD card that follows the physical layer timing: it answers a command
/// a few clocks after its end bit, waits for the write block start bit, checks
/// the end bit and every lane CRC16, sends the CRC status token two clocks after
/// the data end bit, then holds DAT0 low while it programs. It samples on the
/// rising SD clock and changes its outputs after that edge. A released host lane
/// reads high, as the pull-ups make it.
class _SdCard {
  _SdCard({this.busyClocks = 60, this.busyDelay = 0, this.multiBlocks = 1});

  final int busyClocks;
  final int busyDelay;

  /// Blocks a CMD25 write takes. The card waits for the next block when the
  /// busy of the last one ends.
  final int multiBlocks;

  int cmdLine = 1;
  int datLine = 0xF;

  var _prevClk = 0;
  final _cmdBits = <int>[];
  var _cmdActive = false;
  var _cmdGap = 0;
  List<int>? _resp;
  var _respPos = 0;

  var _wrWait = false;
  var _recv = false;
  final _groups = <int>[];
  var _tokenGap = -1;
  List<int> _token = const [];
  var _tokenPos = 0;
  var _busyLeft = 0;
  var _busyGap = 0;
  var _programming = false;

  var blockOk = false;
  var endBitOk = false;
  var crcOk = false;
  var blocks = 0;
  var cmdErrors = 0;
  var _rises = 0;
  var _respEndRise = -1;
  var _busyEndRise = -1;

  /// SD clocks from the card driving the last response bit to the host
  /// start bit of the first block.
  int respToStart = -1;

  /// SD clocks from the card releasing busy to the start bit of each next
  /// block.
  final busyToStart = <int>[];
  final commands = <int>[];
  bool get programming => _programming;
  int get stateCode => _programming ? 7 : 4;

  List<int> _r1(int index) {
    final status = (stateCode << 9) | (_programming ? 0 : 0x100);
    final head = [0, 0, ..._bitsMsb(index, 6), ..._bitsMsb(status, 32)];
    return [...head, ..._crc7(head.sublist(1)), 1];
  }

  void step({
    required int sdClk,
    required int cmdOe,
    required int cmdOut,
    required int datOe,
    required int datOut,
    required int blockBytes,
  }) {
    final rising = _prevClk == 0 && sdClk == 1;
    _prevClk = sdClk;
    if (!rising) return;
    _rises++;

    // Command receiver.
    final cmdBit = cmdOe == 1 ? cmdOut : 1;
    if (_cmdActive) {
      _cmdBits.add(cmdBit);
      if (_cmdBits.length == 48) {
        _cmdActive = false;
        final crc = _crc7(_cmdBits.sublist(1, 40));
        final good =
            _cmdBits[47] == 1 &&
            _cmdBits[1] == 1 &&
            [for (var i = 0; i < 7; i++) _cmdBits[40 + i]].join() == crc.join();
        if (good) {
          final index = [
            for (var i = 2; i < 8; i++) _cmdBits[i],
          ].fold<int>(0, (a, b) => (a << 1) | b);
          commands.add(index);
          if (index == 13 || index == 24 || index == 25) {
            _resp = _r1(index);
            _cmdGap = 5;
            if (index == 24 || index == 25) {
              _wrWait = true;
              _groups.clear();
            }
          }
        } else {
          cmdErrors++;
        }
      }
    } else if (cmdBit == 0 && cmdOe == 1 && _resp == null) {
      _cmdActive = true;
      _cmdBits
        ..clear()
        ..add(0);
    }

    // Response transmitter, one bit per rising edge after the gap.
    cmdLine = 1;
    final resp = _resp;
    if (resp != null && !_cmdActive) {
      if (_cmdGap > 0) {
        _cmdGap--;
      } else {
        cmdLine = resp[_respPos++];
        if (_respPos == resp.length) {
          _resp = null;
          _respPos = 0;
          _respEndRise = _rises;
        }
      }
    }

    // Write block receiver. The host holds off until the response is out.
    final lanes = [
      for (var l = 0; l < 4; l++)
        ((datOe >> l) & 1) == 1 ? (datOut >> l) & 1 : 1,
    ].reversed.fold<int>(0, (a, b) => (a << 1) | b);
    if (_wrWait && _resp == null) {
      if (lanes == 0 && _cmdGap == 0) {
        if (blocks == 0 && respToStart < 0 && _respEndRise >= 0) {
          respToStart = _rises - _respEndRise;
        } else if (_busyEndRise >= 0) {
          busyToStart.add(_rises - _busyEndRise);
        }
        _wrWait = false;
        _recv = true;
        _groups.clear();
      }
    } else if (_recv) {
      _groups.add(lanes);
      final dataGroups = blockBytes * 2;
      if (_groups.length == dataGroups + 16 + 1) {
        _recv = false;
        endBitOk = lanes == 0xF;
        crcOk = true;
        for (var l = 0; l < 4; l++) {
          final bits = [
            for (var i = 0; i < dataGroups; i++) (_groups[i] >> l) & 1,
          ];
          final want = _crc16(bits);
          final got = [
            for (var i = 0; i < 16; i++) (_groups[dataGroups + i] >> l) & 1,
          ];
          if (want.join() != got.join()) crcOk = false;
        }
        blockOk = crcOk && endBitOk;
        _token = blockOk ? [0, 0, 1, 0, 1] : [0, 1, 0, 1, 1];
        _tokenGap = 2;
        _tokenPos = 0;
        _busyGap = busyDelay;
        _programming = true;
      }
    }

    // CRC status token, then the busy window on DAT0.
    var dat0 = 1;
    if (_tokenGap > 0) {
      _tokenGap--;
    } else if (_tokenGap == 0 && _tokenPos < _token.length) {
      dat0 = _token[_tokenPos++];
      if (_tokenPos == _token.length) {
        _busyLeft = busyClocks;
        _tokenGap = -1;
      }
    } else if (_programming) {
      if (_busyGap > 0) {
        _busyGap--;
      } else if (_busyLeft > 0) {
        dat0 = 0;
        _busyLeft--;
        if (_busyLeft == 0) {
          _programming = false;
          blocks++;
          _busyEndRise = _rises;
          if (blocks < multiBlocks) {
            _wrWait = true;
            _groups.clear();
          }
        }
      }
    }
    datLine = 0xE | dat0;
  }
}

void main() {
  group('HarborSdioController CMD engine', () {
    late HarborSdioController sdio;
    late Logic clk, reset, stb, we, adr, mosi;
    late Logic cmdIn, cmdOut, cmdOe, sdClk, irq;
    late Logic datIn, datOut, datOe;
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
      datOut = top.output('sd_dat_out');
      datOe = top.output('sd_dat_oe');

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

    // A write then a status poll, the way the MMC core drives a card.
    Future<_SdCard> writeThenStatus({
      required int busyClocks,
      int busyDelay = 0,
      int clkDivider = 0,
      bool fall = false,
      int blocks = 1,
    }) async {
      final words = [
        for (var i = 0; i < 128 * blocks; i++) 0x01020304 * (i + 1),
      ];
      await setUpDut(
        dmaMem: [
          0x40,
          0x80000000 | (512 * blocks),
          ...List.filled(14, 0),
          ...words,
        ],
      );
      await busWrite(_clkDiv, clkDivider);
      await busWrite(_ctrl, 0x11 | (fall ? 0x100 : 0));
      strictResponse = true;
      final card = _SdCard(
        busyClocks: busyClocks,
        busyDelay: busyDelay,
        multiBlocks: blocks,
      );
      var running = true;
      unawaited(() async {
        while (running) {
          await clk.nextPosedge;
          card.step(
            sdClk: sdClk.value.toInt(),
            cmdOe: cmdOe.value.toInt(),
            cmdOut: cmdOut.value.toInt(),
            datOe: datOe.value.toInt(),
            datOut: datOut.value.toInt(),
            blockBytes: 512,
          );
          cmdIn.inject(card.cmdLine);
          datIn.inject(card.datLine);
        }
      }());

      Future<int> run(int cmd, {int arg = 0}) async {
        await busWrite(_intStatus, 0x1FF);
        await busWrite(_cmdArg, arg);
        await busWrite(_cmd, cmd);
        for (var i = 0; i < 60000; i++) {
          if ((await busRead(_status)) & 0x100 == 0) break;
        }
        return busRead(_intStatus);
      }

      await busWrite(_blkSize, 512);
      await busWrite(_blkCount, blocks);
      final wr = await run(
        (blocks > 1 ? 25 : 24) | (1 << 6) | (1 << 8) | (1 << 10) | (1 << 11),
      );
      expect(wr & 0x22, equals(0x02), reason: 'write done without error');
      expect(
        card.programming,
        isFalse,
        reason: 'the write ends after the card leaves busy',
      );
      final st = await run(13 | (1 << 6));
      expect(st & 0x10, equals(0), reason: 'CMD13 after the write answers');
      expect(st & 0x01, equals(0x01));
      expect(card.commands, equals([blocks > 1 ? 25 : 24, 13]));
      expect(card.cmdErrors, equals(0));
      expect(card.blockOk, isTrue);
      running = false;
      return card;
    }

    // The physical layer wants at least two clocks with no driver between the
    // response end bit and the first block (Nwr). The count here is
    // `S - R - 2`: R is the clock the card drives its last bit and S the clock
    // the card samples the start bit. The host keeps three, one more than the
    // specification, for its own output delay. After busy it needs one more,
    // because it samples DAT0 a clock late.
    const nwrClocks = 3;
    const nwrBusyClocks = 4;

    test('the first block starts after enough released clocks', () async {
      final card = await writeThenStatus(busyClocks: 60);
      expect(card.respToStart - 2, greaterThanOrEqualTo(nwrClocks));
      await Simulator.endSimulation();
    });

    test('the next block starts after enough clocks past busy', () async {
      final card = await writeThenStatus(busyClocks: 60, blocks: 2);
      expect(card.blocks, equals(2));
      expect(card.busyToStart, hasLength(1));
      expect(card.busyToStart.single - 2, greaterThanOrEqualTo(nwrBusyClocks));
      await Simulator.endSimulation();
    });

    test('a 4-bit write is accepted and CMD13 answers after it', () async {
      final card = await writeThenStatus(busyClocks: 60);
      expect(card.endBitOk, isTrue);
      expect(card.crcOk, isTrue);
      await Simulator.endSimulation();
    });

    // One command with a response of [frame] ([stuckLow] holds CMD low
    // instead). Returns INT_STATUS once the controller stops.
    Future<int> strictCommand(
      int cmd,
      List<int>? frame, {
      bool stuckLow = false,
    }) async {
      await setUpDut();
      strictResponse = true;
      await busWrite(_intEnable, 0xE11);
      await busWrite(_cmdArg, 0);
      await busWrite(_cmd, cmd);
      if (stuckLow) cmdIn.inject(0);
      var sawDrive = false;
      var k = 0;
      for (var i = 0; i < 4000; i++) {
        await clk.nextPosedge;
        final sending = cmdProbe.sending(cmdOe, cmdOut);
        if (sending) sawDrive = true;
        if (frame != null &&
            sawDrive &&
            !sending &&
            sdClk.value.toInt() == 0 &&
            k < frame.length) {
          cmdIn.inject(frame[k++]);
        }
        if (irq.value.toInt() == 1) break;
      }
      if (frame != null && k == frame.length) {
        await clk.nextPosedge;
        cmdIn.inject(1);
      }
      return busRead(_intStatus);
    }

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

    test('a stuck-low CMD line is an error and never cmd-done', () async {
      final st = await strictCommand(13 | (1 << 6), null, stuckLow: true);
      expect(st & 0x01, equals(0));
      expect(st & 0x400, equals(0x400));
      await Simulator.endSimulation();
    });

    test('a stuck-low CMD line fails a long response too', () async {
      final st = await strictCommand(2 | (2 << 6), null, stuckLow: true);
      expect(st & 0x01, equals(0));
      expect(st & 0x400, equals(0x400));
      await Simulator.endSimulation();
    });

    test('a good R1 frame completes', () async {
      final st = await strictCommand(13 | (1 << 6), r1Frame(13));
      expect(st & 0xE01, equals(0x01));
      await Simulator.endSimulation();
    });

    test('a bad CRC7 sets the CRC error and not cmd-done', () async {
      final st = await strictCommand(13 | (1 << 6), r1Frame(13, crcXor: 0x10));
      expect(st & 0xE01, equals(0x200));
      await Simulator.endSimulation();
    });

    test('a bad end bit sets the end bit error', () async {
      final st = await strictCommand(13 | (1 << 6), r1Frame(13, end: 0));
      expect(st & 0xE01, equals(0x400));
      await Simulator.endSimulation();
    });

    test('a transmission bit of 1 alone sets the end bit error', () async {
      final st = await strictCommand(13 | (1 << 6), r1Frame(13, tx: 1));
      expect(st & 0xE01, equals(0x400));
      await Simulator.endSimulation();
    });

    test('a wrong echoed index sets the index error', () async {
      final st = await strictCommand(13 | (1 << 6), r1Frame(17));
      expect(st & 0xE01, equals(0x800));
      await Simulator.endSimulation();
    });

    test('a good R2 frame completes', () async {
      final st = await strictCommand(2 | (2 << 6), r2Frame());
      expect(st & 0xE01, equals(0x01));
      await Simulator.endSimulation();
    });

    test('an R2 frame with a bad CRC7 fails', () async {
      final st = await strictCommand(2 | (2 << 6), r2Frame(crcXor: 0x04));
      expect(st & 0xE01, equals(0x200));
      await Simulator.endSimulation();
    });

    test('an R3 frame has no CRC7 and no index check', () async {
      final head = [0, 0, ...List.filled(6, 1), ..._bitsMsb(0xC0FF8000, 32)];
      final frame = [...head, ...List.filled(7, 1), 1];
      final st = await strictCommand(41 | (1 << 6) | (3 << 12), frame);
      expect(st & 0xE01, equals(0x01));
      await Simulator.endSimulation();
    });

    test('a CRC error in a response stops a DMA write before data', () async {
      final st = await strictCommand(
        24 | (1 << 6) | (1 << 8) | (1 << 10),
        r1Frame(24, crcXor: 1),
      );
      expect(st & 0x202, equals(0x200));
      expect((await busRead(_status)) & 0x100, equals(0));
      await Simulator.endSimulation();
    });
  });
}
