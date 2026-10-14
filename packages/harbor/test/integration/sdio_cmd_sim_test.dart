import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'test_harness.dart';

// Register WORD indices (the fabric strips the byte offset, so the documented
// byte offsets 0x00,0x04,0x08,... map to indices 0,1,2,...).
// Byte offsets: each register in its own 8-byte slot (the byte-addressed fabric).
const _ctrl = 0x00;
const _status = 0x08;
const _clkDiv = 0x10;
const _cmd = 0x18;
const _cmdArg = 0x20;
const _resp0 = 0x28;

// CMD field encoding: [5:0] index, [7:6] response type.
const _respNone = 0;
const _respShort = 1;

const _stBusy = 1 << 8;

int _cmdWord(int index, int respType) => index | (respType << 6);

int _bit(Logic l) {
  final v = l.value;
  return v.isValid ? v.toInt() : 0;
}

List<int> _toBits(int value, int n) {
  final bits = <int>[];
  for (var i = n - 1; i >= 0; i--) {
    bits.add((value >> i) & 1);
  }
  return bits; // MSB first
}

int _fromBits(List<int> bits) {
  var v = 0;
  for (final b in bits) {
    v = (v << 1) | (b & 1);
  }
  return v;
}

// SD CRC7: poly x^7 + x^3 + 1 (0x09), MSB-first over the given bits, init 0.
// Independent of the RTL _crc7, so a match cross-checks the RTL serializer.
int _crc7(List<int> bits) {
  var crc = 0;
  for (final b in bits) {
    final fb = ((crc >> 6) & 1) ^ (b & 1);
    crc = (crc << 1) & 0x7f;
    if (fb != 0) crc ^= 0x09;
  }
  return crc;
}

/// A behavioral native-SD card model, the verification oracle for the command
/// engine. It hunts for the host's start bit on `sd_cmd_out` (the SD clock
/// free-runs, so the phase is arbitrary), samples the 47 framing+content bits
/// while the host drives CMD, cross-checks the CRC7, then drives a short (R1/R3/
/// R6/R7-style) response back on `sd_cmd_in`, changing the line on falling edges
/// so the host samples a stable value on the following rising edge.
class _FakeSdCard {
  final HarborSdioController dut;
  final Logic cmdIn;

  int gotIndex = -1;
  int gotArg = -1;
  int gotCrcRx = -1;
  int gotCrcCalc = -1;
  bool gotCrcOk = false;
  int commandCount = 0;
  bool stop = false;

  /// Echo this 32-bit value in the response argument field instead of the
  /// received argument, to prove RESP0 tracks the card, not a CMD_ARG loopback.
  int? forceRespArg;

  _FakeSdCard(this.dut, this.cmdIn);

  List<int> _buildR1(int index, int arg) {
    final bits = <int>[];
    bits.add(0); // start
    bits.add(0); // transmission (card -> host)
    bits.addAll(_toBits(index, 6));
    bits.addAll(_toBits(arg, 32));
    bits.addAll(_toBits(_crc7(bits.sublist(0, 40)), 7));
    bits.add(1); // end
    return bits; // 48 bits, MSB first
  }

  Future<void> run(Logic clk) async {
    var prevClk = 0;
    var prevOe = 0;
    var collecting = false;
    final cmdBits = <int>[];
    var responding = false;
    var respBits = <int>[];
    var gap = 0;

    while (!stop) {
      await clk.nextPosedge;
      final sclk = _bit(dut.output('sd_clk'));
      final oe = _bit(dut.output('sd_cmd_oe'));
      final cmdOut = _bit(dut.output('sd_cmd_out'));
      final rise = prevClk == 0 && sclk == 1;
      final fall = prevClk == 1 && sclk == 0;

      // Command RX: hunt for the start bit, then collect on rising edges while
      // the host drives CMD (the end bit is not sampled: cmdOe drops with it).
      if (oe == 1 && rise) {
        if (!collecting) {
          if (cmdOut == 0) {
            collecting = true;
            cmdBits.add(0);
          }
        } else {
          cmdBits.add(cmdOut);
        }
      }

      // Host released CMD: decode the 47 collected bits and arm the response.
      if (prevOe == 1 && oe == 0 && collecting && !responding) {
        if (cmdBits.length >= 47) {
          final f = cmdBits.sublist(0, 47);
          gotIndex = _fromBits(f.sublist(2, 8));
          gotArg = _fromBits(f.sublist(8, 40));
          gotCrcCalc = _crc7(f.sublist(0, 40));
          gotCrcRx = _fromBits(f.sublist(40, 47));
          gotCrcOk = gotCrcCalc == gotCrcRx;
          commandCount++;
          respBits = _buildR1(gotIndex, forceRespArg ?? gotArg);
          responding = true;
          gap = 2; // let the host reach sWait before the start bit
        }
        collecting = false;
        cmdBits.clear();
      }

      // Drive the response on falling edges (host samples on the next rise).
      if (responding && fall) {
        if (gap > 0) {
          gap--;
          cmdIn.inject(1);
        } else if (respBits.isNotEmpty) {
          cmdIn.inject(respBits.removeAt(0));
        } else {
          cmdIn.inject(1);
          responding = false;
        }
      }

      prevClk = sclk;
      prevOe = oe;
    }
  }
}

/// Brings up the controller (enable + a small clock divider) and attaches the
/// fake card. Returns the bench and card.
Future<(PeripheralTestBench, _FakeSdCard, Logic)> _bringUp() async {
  final sdio = HarborSdioController(baseAddress: 0x9000);
  final cmdIn = Logic(name: 'fake_cmd_in');
  final cd = Logic(name: 'fake_cd');
  final datIn = Logic(name: 'fake_dat_in', width: 4);
  sdio.port('sd_cmd_in').getsLogic(cmdIn);
  sdio.port('sd_cd').getsLogic(cd);
  sdio.port('sd_dat_in').getsLogic(datIn);
  for (final p in sdio.inputs.keys.where((p) => p.startsWith('dma_'))) {
    sdio.port(p).getsLogic(Const(0, width: sdio.input(p).width));
  }

  final tb = PeripheralTestBench(sdio);
  final card = _FakeSdCard(sdio, cmdIn);
  await tb.init(maxSimTime: 4000000);
  cmdIn.inject(1);
  cd.inject(1);
  datIn.inject(0xf);
  unawaited(card.run(tb.clk));

  await tb.write(_clkDiv, 1); // SD clock period = 4 bus cycles
  await tb.write(_ctrl, 1); // enable -> SD clock runs
  return (tb, card, cmdIn);
}

Future<int> _waitCommand(PeripheralTestBench tb, {int max = 40000}) async {
  var status = _stBusy;
  for (var i = 0; i < max; i++) {
    status = await tb.read(_status);
    if (status & _stBusy == 0) break;
  }
  return status;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('SDIO command engine', () {
    test(
      'CMD8 SEND_IF_COND: valid frame on the wire and R7 echo in RESP0',
      () async {
        final (tb, card, _) = await _bringUp();

        await tb.write(_cmdArg, 0x1aa); // 2.7-3.6V + check pattern 0xaa
        await tb.write(_cmd, _cmdWord(8, _respShort));

        final status = await _waitCommand(tb);
        expect(status & _stBusy, equals(0), reason: 'command must complete');

        expect(card.commandCount, equals(1));
        expect(card.gotIndex, equals(8), reason: 'command index on the wire');
        expect(card.gotArg, equals(0x1aa), reason: 'argument on the wire');
        expect(
          card.gotCrcOk,
          isTrue,
          reason:
              'host CRC7 0x${card.gotCrcRx.toRadixString(16)} != golden '
              '0x${card.gotCrcCalc.toRadixString(16)}',
        );

        expect(
          await tb.read(_resp0),
          equals(0x1aa),
          reason: 'R7 argument echo lands in RESP0',
        );

        card.stop = true;
        await Simulator.endSimulation();
      },
    );

    test('RESP0 is the card response, not a CMD_ARG loopback', () async {
      final sdio = HarborSdioController(baseAddress: 0x9000);
      final cmdIn = Logic(name: 'fake_cmd_in');
      final cd = Logic(name: 'fake_cd');
      final datIn = Logic(name: 'fake_dat_in', width: 4);
      sdio.port('sd_cmd_in').getsLogic(cmdIn);
      sdio.port('sd_cd').getsLogic(cd);
      sdio.port('sd_dat_in').getsLogic(datIn);
      for (final p in sdio.inputs.keys.where((p) => p.startsWith('dma_'))) {
        sdio.port(p).getsLogic(Const(0, width: sdio.input(p).width));
      }

      final tb = PeripheralTestBench(sdio);
      final card = _FakeSdCard(sdio, cmdIn)..forceRespArg = 0x00ff8000;
      await tb.init(maxSimTime: 4000000);
      cmdIn.inject(1);
      cd.inject(1);
      datIn.inject(0xf);
      unawaited(card.run(tb.clk));

      await tb.write(_clkDiv, 1);
      await tb.write(_ctrl, 1);
      await tb.write(_cmdArg, 0x40000000); // ACMD41-style HCS argument
      await tb.write(_cmd, _cmdWord(41, _respShort));

      final status = await _waitCommand(tb);
      expect(status & _stBusy, equals(0));
      expect(card.gotArg, equals(0x40000000), reason: 'host sent the argument');
      expect(
        await tb.read(_resp0),
        equals(0x00ff8000),
        reason: 'RESP0 is the card-driven response argument',
      );

      card.stop = true;
      await Simulator.endSimulation();
    });

    test(
      'CMD0 GO_IDLE_STATE: no-response command completes without a timeout',
      () async {
        final (tb, card, _) = await _bringUp();

        await tb.write(_cmdArg, 0);
        await tb.write(_cmd, _cmdWord(0, _respNone));

        final status = await _waitCommand(tb);
        expect(status & _stBusy, equals(0), reason: 'CMD0 completes');
        expect(
          card.commandCount,
          equals(1),
          reason: 'the card still saw a well-framed CMD0',
        );
        expect(card.gotIndex, equals(0));
        expect(card.gotCrcOk, isTrue);

        card.stop = true;
        await Simulator.endSimulation();
      },
    );

    test('CRC7 is correct across a range of index/argument values', () async {
      final (tb, card, _) = await _bringUp();

      final vectors = <(int, int)>[
        (0, 0x00000000),
        (8, 0x000001aa),
        (17, 0x00000000),
        (24, 0xdeadbeef),
        (55, 0xffffffff),
        (3, 0xa5a5a5a5),
      ];

      for (final (index, arg) in vectors) {
        await tb.write(_cmdArg, arg);
        await tb.write(_cmd, _cmdWord(index, _respShort));
        final status = await _waitCommand(tb);
        expect(status & _stBusy, equals(0), reason: 'CMD$index completes');
        expect(card.gotIndex, equals(index), reason: 'index $index');
        expect(
          card.gotArg,
          equals(arg),
          reason: 'arg 0x${arg.toRadixString(16)}',
        );
        expect(
          card.gotCrcOk,
          isTrue,
          reason:
              'CMD$index arg 0x${arg.toRadixString(16)}: '
              'host CRC7 0x${card.gotCrcRx.toRadixString(16)} != golden '
              '0x${card.gotCrcCalc.toRadixString(16)}',
        );
      }

      card.stop = true;
      await Simulator.endSimulation();
    });
  });
}
