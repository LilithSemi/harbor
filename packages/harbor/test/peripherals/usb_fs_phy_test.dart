import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_test_host.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborUsbFsRx', () {
    // Drives line symbols into the RX and collects the decoded stream.
    Future<Map<String, dynamic>> runSymbols(
      List<List<int>> syms, {
      List<int> drain = const [1, 0],
    }) async {
      final dut = HarborUsbFsRx(name: 'rx_test');
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final dp = Logic(name: 'dp');
      final dn = Logic(name: 'dn');

      dut.input('clk').srcConnection! <= clk;
      dut.input('reset').srcConnection! <= reset;
      dut.input('dp').srcConnection! <= dp;
      dut.input('dn').srcConnection! <= dn;

      await dut.build();

      reset.inject(1);
      dp.inject(1);
      dn.inject(0);
      Simulator.setMaxSimTime(500000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      // Let the synchronizer and line state settle.
      for (var i = 0; i < 20; i++) {
        await clk.nextPosedge;
      }

      var pktStarts = 0;
      var pktEnds = 0;
      final dataBytes = <int>[];

      Future<void> sample() async {
        if (dut.output('pkt_start').value.toInt() == 1) pktStarts++;
        if (dut.output('pkt_end').value.toInt() == 1) pktEnds++;
        if (dut.output('rx_data_put').value.toInt() == 1) {
          dataBytes.add(dut.output('rx_data').value.toInt());
        }
      }

      for (final s in syms) {
        for (var t = 0; t < 4; t++) {
          dp.inject(s[0]);
          dn.inject(s[1]);
          await clk.nextPosedge;
          await sample();
        }
      }

      // Hold the drain state, idle J by default, to drain the pipeline.
      dp.inject(drain[0]);
      dn.inject(drain[1]);
      for (var i = 0; i < 60; i++) {
        await clk.nextPosedge;
        await sample();
      }

      final result = {
        'pktStarts': pktStarts,
        'pktEnds': pktEnds,
        'dataBytes': dataBytes,
        'pid': dut.output('pid').value.toInt(),
        'addr': dut.output('addr').value.toInt(),
        'endp': dut.output('endp').value.toInt(),
        'valid': dut.output('valid_packet').value.toInt(),
      };

      await Simulator.endSimulation();
      return result;
    }

    test('decodes an IN token', () async {
      final r = await runSymbols(
        usbEncode([usbPidByte(9), ...usbTokenBytes(0x2A, 1)]),
      );
      expect(r['pktStarts'], 1, reason: 'one packet start');
      expect(r['pktEnds'], 1, reason: 'one packet end');
      expect(r['pid'], 9, reason: 'IN pid');
      expect(r['addr'], 0x2A, reason: 'token addr');
      expect(r['endp'], 1, reason: 'token endp');
      expect(r['valid'], 1, reason: 'crc5 ok');
      expect((r['dataBytes'] as List).isEmpty, true, reason: 'no data bytes');
    });

    test('decodes an OUT token for address 0 endpoint 0', () async {
      final r = await runSymbols(
        usbEncode([usbPidByte(1), ...usbTokenBytes(0, 0)]),
      );
      expect(r['pid'], 1, reason: 'OUT pid');
      expect(r['addr'], 0, reason: 'token addr');
      expect(r['endp'], 0, reason: 'token endp');
      expect(r['valid'], 1, reason: 'crc5 ok');
    });

    test('decodes a SETUP token', () async {
      final r = await runSymbols(
        usbEncode([usbPidByte(13), ...usbTokenBytes(5, 0)]),
      );
      expect(r['pid'], 13, reason: 'SETUP pid');
      expect(r['addr'], 5, reason: 'token addr');
      expect(r['endp'], 0, reason: 'token endp');
      expect(r['valid'], 1, reason: 'crc5 ok');
    });

    test('decodes a DATA0 packet payload', () async {
      final payload = <int>[0xDE, 0xAD, 0xBE, 0xEF];
      final crc = usbCrc16(payload);
      final bytes = [usbPidByte(3), ...payload, crc & 0xFF, (crc >> 8) & 0xFF];
      final r = await runSymbols(usbEncode(bytes));
      expect(r['pid'], 3, reason: 'DATA0 pid');
      expect(r['valid'], 1, reason: 'crc16 ok');
      // The RX stream includes the 2 trailing CRC16 bytes by design. The
      // downstream OUT protocol engine strips them.
      expect(r['dataBytes'], [
        ...payload,
        crc & 0xFF,
        (crc >> 8) & 0xFF,
      ], reason: 'payload plus crc bytes');
    });

    test('decodes a DATA1 packet payload', () async {
      final payload = <int>[0x01, 0x02, 0x03];
      final crc = usbCrc16(payload);
      final bytes = [usbPidByte(11), ...payload, crc & 0xFF, (crc >> 8) & 0xFF];
      final r = await runSymbols(usbEncode(bytes));
      expect(r['pid'], 11, reason: 'DATA1 pid');
      expect(r['valid'], 1, reason: 'crc16 ok');
      expect(r['dataBytes'], [
        ...payload,
        crc & 0xFF,
        (crc >> 8) & 0xFF,
      ], reason: 'payload plus crc bytes');
    });

    test('decodes an ACK handshake', () async {
      final r = await runSymbols(usbEncode([usbPidByte(2)]));
      expect(r['pid'], 2, reason: 'ACK pid');
      expect(r['valid'], 1, reason: 'handshake valid');
      expect((r['dataBytes'] as List).isEmpty, true, reason: 'no data');
    });

    test('rejects a corrupted data packet', () async {
      final payload = <int>[0xAA, 0x55];
      final crc = usbCrc16(payload);
      // Corrupt one CRC byte.
      final bytes = [
        usbPidByte(3),
        ...payload,
        (crc & 0xFF) ^ 0xFF,
        (crc >> 8) & 0xFF,
      ];
      final r = await runSymbols(usbEncode(bytes));
      expect(r['valid'], 0, reason: 'crc16 failure flags invalid');
    });

    test('decodes back-to-back packets', () async {
      final syms = <List<int>>[];
      // Token then data, each with a full EOP, no idle gap between them.
      syms.addAll(usbEncode([usbPidByte(9), ...usbTokenBytes(0x10, 2)]));
      syms.addAll(usbEncode([usbPidByte(3), 0x77]));
      final r = await runSymbols(syms);
      expect(r['pktStarts'], 2, reason: 'two packet starts');
      expect(r['pktEnds'], 2, reason: 'two packet ends');
      expect(r['pid'], 3, reason: 'last packet is DATA0');
      expect(r['dataBytes'], [0x77], reason: 'data payload');
    });

    const k = [0, 1];
    const j = [1, 0];
    const se1 = [1, 1];
    const cut = [k, j, k, j, k, j, k, k, j, j, k];

    test('ends a cut packet as invalid on a bit stuff error', () async {
      // SYNC and 3 PID bits, then the line stays at J with no EOP.
      final r = await runSymbols(cut);
      expect(r['pktStarts'], 1);
      expect(r['pktEnds'], 1, reason: '7 bits with no transition');
      expect(r['valid'], 0);
    });

    test('ends a full ACK PID with no EOP as invalid', () async {
      final ack = usbEncode([usbPidByte(2)]);
      final r = await runSymbols(ack.sublist(0, ack.length - 3));
      expect(r['pktEnds'], 1);
      expect(r['valid'], 0);
    });

    test('ends a packet held at SE1 as invalid', () async {
      final r = await runSymbols(cut, drain: se1);
      expect(r['pktStarts'], 1);
      expect(r['pktEnds'], 1, reason: 'two SE1 bits');
      expect(r['valid'], 0);
    });

    test('ignores a SYNC right after an abort', () async {
      final r = await runSymbols([
        ...cut,
        se1,
        se1,
        se1,
        j,
        ...usbEncode([usbPidByte(2)]),
      ]);
      expect(r['pktStarts'], 1, reason: 'no SE0 or 8 idle bits before it');
      expect(r['pktEnds'], 1);
    });

    test('decodes a packet after an abort and 8 idle bits', () async {
      final r = await runSymbols([
        ...cut,
        se1,
        se1,
        se1,
        ...List.filled(9, j),
        ...usbEncode([usbPidByte(2)]),
      ]);
      expect(r['pktStarts'], 2);
      expect(r['pktEnds'], 2);
      expect(r['pid'], 2);
      expect(r['valid'], 1);
    });
  });

  _txTests();
  _txTimingTests();
}

/// Transmitted-packet monitor: collects a decoded byte stream from an RX
/// that observes a TX driving the same line, using the RX recovered strobe
/// to pace the TX (a self-timed loopback).
Future<Map<String, dynamic>> _runLoopback({
  required int pid,
  required List<int> dataBytes,
}) async {
  final tx = HarborUsbFsTx(name: 'tx_lb');
  final rx = HarborUsbFsRx(name: 'rx_lb');

  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final pktStart = Logic(name: 'pkt_start');
  final pidIn = Logic(name: 'pid_in', width: 4);

  tx.input('clk').srcConnection! <= clk;
  tx.input('reset').srcConnection! <= reset;
  rx.input('clk').srcConnection! <= clk;
  rx.input('reset').srcConnection! <= reset;

  // The RX recovered strobe paces the TX, as the top module wires it.
  tx.input('bit_strobe').srcConnection! <= rx.output('bit_strobe');

  // The line: the TX drives when oe is high, else the pull-up holds J.
  final rxDp = mux(tx.output('oe'), tx.output('dp'), Const(1)).named('rx_dp');
  final rxDn = mux(tx.output('oe'), tx.output('dn'), Const(0)).named('rx_dn');
  rx.input('dp').srcConnection! <= rxDp;
  rx.input('dn').srcConnection! <= rxDn;

  tx.input('pkt_start').srcConnection! <= pktStart;
  tx.input('pid').srcConnection! <= pidIn;

  // Byte source: serves dataBytes in order, one per get pulse.
  final byteIdx = Logic(name: 'byte_idx', width: 5);
  Logic txDataLogic = Const(dataBytes[0], width: 8);
  for (var i = 1; i < dataBytes.length; i++) {
    txDataLogic = mux(
      byteIdx.eq(Const(i, width: 5)),
      Const(dataBytes[i], width: 8),
      txDataLogic,
    );
  }
  tx.input('tx_data').srcConnection! <= txDataLogic;
  tx.input('tx_data_avail').srcConnection! <=
      byteIdx.lt(Const(dataBytes.length, width: 5));

  Sequential(clk, [
    If(
      reset,
      then: [byteIdx < Const(0, width: 5)],
      orElse: [
        If(
          tx.output('tx_data_get'),
          then: [byteIdx < byteIdx + Const(1, width: 5)],
        ),
      ],
    ),
  ]);

  await tx.build();
  await rx.build();

  reset.inject(1);
  pktStart.inject(0);
  pidIn.inject(pid);
  Simulator.setMaxSimTime(500000);
  unawaited(Simulator.run());

  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.inject(0);
  for (var i = 0; i < 30; i++) {
    await clk.nextPosedge;
  }

  // Start the packet.
  pktStart.inject(1);
  await clk.nextPosedge;
  pktStart.inject(0);

  final rxBytes = <int>[];
  var txPktEnd = 0;
  for (var i = 0; i < 20000; i++) {
    await clk.nextPosedge;
    if (rx.output('rx_data_put').value.toInt() == 1) {
      rxBytes.add(rx.output('rx_data').value.toInt());
    }
    if (tx.output('pkt_end').value.toInt() == 1) {
      txPktEnd++;
      // Drain the tail so the last bytes land.
      for (var j = 0; j < 200; j++) {
        await clk.nextPosedge;
        if (rx.output('rx_data_put').value.toInt() == 1) {
          rxBytes.add(rx.output('rx_data').value.toInt());
        }
      }
      break;
    }
  }

  final result = {
    'rxBytes': rxBytes,
    'txPktEnd': txPktEnd,
    'pid': rx.output('pid').value.toInt(),
    'valid': rx.output('valid_packet').value.toInt(),
  };

  await Simulator.endSimulation();
  return result;
}

void _txTests() {
  group('HarborUsbFsTx', () {
    test('transmits a DATA0 packet the RX decodes', () async {
      final data = <int>[0xDE, 0xAD, 0xBE, 0xEF];
      final crc = usbCrc16(data);
      final r = await _runLoopback(pid: 3, dataBytes: data);
      expect(r['txPktEnd'], 1, reason: 'tx packet end pulse');
      expect(r['pid'], 3, reason: 'decoded DATA0 pid');
      expect(r['valid'], 1, reason: 'decoded crc16 valid');
      expect(r['rxBytes'], [
        ...data,
        crc & 0xFF,
        (crc >> 8) & 0xFF,
      ], reason: 'decoded payload plus crc');
    });

    test('transmits a handshake (no data) the RX decodes', () async {
      final r = await _runLoopback(pid: 2, dataBytes: [0xFF]);
      expect(r['txPktEnd'], 1, reason: 'tx packet end pulse');
      expect(r['pid'], 2, reason: 'decoded ACK pid');
      expect(r['valid'], 1, reason: 'handshake valid');
      expect((r['rxBytes'] as List).isEmpty, true, reason: 'no data bytes');
    });

    test('transmits a long packet with stuffing', () async {
      // 0xFF bytes force stuff bits (six ones in a row).
      final data = List<int>.generate(20, (i) => i == 10 ? 0xFF : 0x0F);
      final crc = usbCrc16(data);
      final r = await _runLoopback(pid: 3, dataBytes: data);
      expect(r['valid'], 1, reason: 'decoded crc16 valid');
      expect(r['rxBytes'], [
        ...data,
        crc & 0xFF,
        (crc >> 8) & 0xFF,
      ], reason: 'decoded payload plus crc');
    });
  });
}

/// Drives `pkt_start` into a bare TX at a chosen bit-strobe phase and bit
/// count, then counts clock cycles until `oe` asserts and reports the line
/// value (dp, dn) at that cycle.
///
/// `bit_strobe` is a plain divide-by-4 pulse train driven by the test, not
/// the RX's recovered clock, so every phase and bit count combination can
/// be reproduced exactly. `phase` is the clk offset (0-3) from the last bit
/// strobe when `pkt_start` is asserted. `bitCountAtStart` is the TX's
/// free-running bit counter value at that same moment, so waiting
/// `bitCountAtStart * 4 + phase` clocks after reset lands on it exactly.
///
/// `oe` and the SYNC field's first line edge land on the same clock cycle,
/// so the sampled line value must be K (dp=0, dn=1), the transition away
/// from idle J that marks SYNC's first bit.
Future<Map<String, dynamic>> _txStartDelay({
  required int phase,
  required int bitCountAtStart,
}) async {
  final tx = HarborUsbFsTx(name: 'tx_timing');
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final bitStrobe = Logic(name: 'bit_strobe');
  final pktStart = Logic(name: 'pkt_start');
  final pidIn = Logic(name: 'pid_in', width: 4);
  final txDataAvail = Logic(name: 'tx_data_avail');

  tx.input('clk').srcConnection! <= clk;
  tx.input('reset').srcConnection! <= reset;
  tx.input('bit_strobe').srcConnection! <= bitStrobe;
  tx.input('pkt_start').srcConnection! <= pktStart;
  tx.input('pid').srcConnection! <= pidIn;
  tx.input('tx_data_avail').srcConnection! <= txDataAvail;
  tx.input('tx_data').srcConnection! <= Const(0, width: 8);

  await tx.build();

  reset.inject(1);
  bitStrobe.inject(0);
  pktStart.inject(0);
  // ACK: a handshake has no data payload, so this is the shortest packet.
  pidIn.inject(2);
  txDataAvail.inject(0);
  Simulator.setMaxSimTime(5000);
  unawaited(Simulator.run());

  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.inject(0);

  var edge = 0;
  Future<void> tick({bool start = false}) async {
    bitStrobe.inject(edge % 4 == 3 ? 1 : 0);
    pktStart.inject(start ? 1 : 0);
    await clk.nextPosedge;
    edge++;
  }

  final target = bitCountAtStart * 4 + phase;
  for (var i = 0; i < target; i++) {
    await tick();
  }

  final startEdge = edge;
  await tick(start: true);

  var oeDelay = -1;
  var dpAtOe = -1;
  var dnAtOe = -1;

  for (var i = 0; i < 64 && oeDelay == -1; i++) {
    await tick();
    final capturedEdge = edge - 1;
    final oe = tx.output('oe').value.toInt();
    if (oe == 1) {
      oeDelay = capturedEdge - startEdge;
      dpAtOe = tx.output('dp').value.toInt();
      dnAtOe = tx.output('dn').value.toInt();
    }
  }

  await Simulator.endSimulation();
  return {'oeDelay': oeDelay, 'dpAtOe': dpAtOe, 'dnAtOe': dnAtOe};
}

void _txTimingTests() {
  group('HarborUsbFsTx start timing', () {
    tearDown(() async {
      await Simulator.reset();
    });

    test('the delay from pkt_start to oe and the first SYNC edge stays '
        'short and the edge is always correct, for every phase and bit '
        'count', () async {
      // USB 2.0 7.1.18.1: a function with a detachable cable must begin
      // its response within 6.5 bit times of the host's EOP, from the
      // SE0-to-J transition to the J-to-K transition that starts the
      // reply. This module only covers the TX's own pkt_start-to-first-edge
      // delay, a part of that budget. The rest goes to decoding the token,
      // which reaches pkt_start before this clock starts, so a margin of a
      // couple of bit times here leaves headroom for that other latency.
      const oneBitTimeCycles = 4;
      var minOe = 1 << 30;
      var maxOe = -1;

      for (var phase = 0; phase < 4; phase++) {
        for (var bitCount = 0; bitCount < 8; bitCount++) {
          if (phase != 0 || bitCount != 0) await Simulator.reset();
          final r = await _txStartDelay(
            phase: phase,
            bitCountAtStart: bitCount,
          );
          final oeDelay = r['oeDelay'] as int;
          expect(
            oeDelay,
            isNot(-1),
            reason: 'oe never asserted for phase=$phase bitCount=$bitCount',
          );
          minOe = oeDelay < minOe ? oeDelay : minOe;
          maxOe = oeDelay > maxOe ? oeDelay : maxOe;
          expect(
            oeDelay,
            lessThanOrEqualTo(3 * oneBitTimeCycles),
            reason:
                'phase=$phase bitCount=$bitCount took '
                '${oeDelay / oneBitTimeCycles} bit times to assert oe',
          );
          // The line must read K (dp=0, dn=1) the instant oe asserts:
          // the transition away from idle J that is SYNC's first bit.
          // A wrong value here means the line driver's internal NRZI
          // state picked up a spurious extra toggle while oe was still
          // off, flipping the sense of every bit behind it.
          expect(
            [r['dpAtOe'], r['dnAtOe']],
            [0, 1],
            reason:
                'phase=$phase bitCount=$bitCount drove '
                '${r['dpAtOe']},${r['dnAtOe']} instead of K when oe '
                'asserted',
          );
        }
      }

      // The whole point of the fix: the delay no longer depends on how
      // far bit_count is from wrapping, so the spread across all
      // phases and bit counts stays under one bit time.
      expect(
        maxOe - minOe,
        lessThan(oneBitTimeCycles),
        reason:
            'spread between best and worst case is '
            '${(maxOe - minOe) / oneBitTimeCycles} bit times',
      );
    });
  });

  group('HarborUsbFsTx start timing with the receiver', () {
    tearDown(() async {
      await Simulator.reset();
    });

    test('decodes a stuffed payload correctly no matter how many idle bit '
        'strobes pass before pkt_start', () async {
      // 0xFF forces six-ones stuff bits. Sweeping the warm-up count
      // exercises every bit_count phase pkt_start can land on.
      final data = List<int>.generate(16, (i) => i.isEven ? 0xFF : 0x00);
      final crc = usbCrc16(data);

      for (var warmup = 0; warmup < 8; warmup++) {
        if (warmup != 0) await Simulator.reset();
        final r = await _runLoopbackWithWarmup(
          pid: 3,
          dataBytes: data,
          warmupBitStrobes: warmup,
        );
        expect(r['valid'], 1, reason: 'warmup=$warmup crc16 valid');
        expect(r['rxBytes'], [
          ...data,
          crc & 0xFF,
          (crc >> 8) & 0xFF,
        ], reason: 'warmup=$warmup payload plus crc decode');
      }
    });

    test('decodes a second packet correctly when it starts only a few bit '
        'strobes after the first one ends', () async {
      // A short, fast response reuses the serializer's shift registers
      // before they have drained from the previous packet, unlike a
      // packet sent after a long idle. Sweeping the gap down to zero
      // checks that pkt_start clears them rather than relying on
      // leftover bits happening to be zero already.
      for (var gap = 0; gap <= 8; gap++) {
        if (gap != 0) await Simulator.reset();
        final r = await _runBackToBackLoopback(gapBitStrobes: gap);
        expect(r['valid1'], 1, reason: 'gap=$gap first packet crc16 valid');
        expect(r['valid2'], 1, reason: 'gap=$gap second packet crc16 valid');
        expect(r['pid1'], 3, reason: 'gap=$gap first packet is DATA0');
        expect(r['pid2'], 3, reason: 'gap=$gap second packet is DATA0');
      }
    });
  });
}

/// Sends two DATA0 packets (one 0xFF byte each, to also exercise bit
/// stuffing) back to back, with only [gapBitStrobes] idle bit strobes
/// between the first packet's end and the second's pkt_start, and
/// decodes both through the real RX.
Future<Map<String, dynamic>> _runBackToBackLoopback({
  required int gapBitStrobes,
}) async {
  final tx = HarborUsbFsTx(name: 'tx_b2b');
  final rx = HarborUsbFsRx(name: 'rx_b2b');

  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final pktStart = Logic(name: 'pkt_start');
  final pidIn = Logic(name: 'pid_in', width: 4);
  final txDataAvail = Logic(name: 'tx_data_avail');

  tx.input('clk').srcConnection! <= clk;
  tx.input('reset').srcConnection! <= reset;
  rx.input('clk').srcConnection! <= clk;
  rx.input('reset').srcConnection! <= reset;
  tx.input('bit_strobe').srcConnection! <= rx.output('bit_strobe');

  final rxDp = mux(tx.output('oe'), tx.output('dp'), Const(1)).named('rx_dp');
  final rxDn = mux(tx.output('oe'), tx.output('dn'), Const(0)).named('rx_dn');
  rx.input('dp').srcConnection! <= rxDp;
  rx.input('dn').srcConnection! <= rxDn;

  tx.input('pkt_start').srcConnection! <= pktStart;
  tx.input('pid').srcConnection! <= pidIn;
  tx.input('tx_data_avail').srcConnection! <= txDataAvail;
  tx.input('tx_data').srcConnection! <= Const(0xFF, width: 8);

  await tx.build();
  await rx.build();

  reset.inject(1);
  pktStart.inject(0);
  pidIn.inject(3); // DATA0.
  txDataAvail.inject(0);
  Simulator.setMaxSimTime(500000);
  unawaited(Simulator.run());

  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.inject(0);
  for (var i = 0; i < 30; i++) {
    await clk.nextPosedge;
  }

  Future<int> sendOneAndWaitForEnd() async {
    txDataAvail.inject(1);
    pktStart.inject(1);
    await clk.nextPosedge;
    pktStart.inject(0);
    var sent = false;
    for (var i = 0; i < 20000; i++) {
      await clk.nextPosedge;
      if (tx.output('tx_data_get').value.toInt() == 1 && !sent) {
        sent = true;
        txDataAvail.inject(0);
      }
      if (tx.output('pkt_end').value.toInt() == 1) {
        for (var j = 0; j < 50; j++) {
          await clk.nextPosedge;
        }
        return rx.output('pid').value.toInt();
      }
    }
    return -1;
  }

  final pid1 = await sendOneAndWaitForEnd();
  final valid1 = rx.output('valid_packet').value.toInt();

  var strobes = 0;
  while (strobes < gapBitStrobes) {
    await clk.nextPosedge;
    if (rx.output('bit_strobe').value.toInt() == 1) strobes++;
  }

  final pid2 = await sendOneAndWaitForEnd();
  final valid2 = rx.output('valid_packet').value.toInt();

  await Simulator.endSimulation();
  return {'pid1': pid1, 'valid1': valid1, 'pid2': pid2, 'valid2': valid2};
}

/// Same loopback as [_runLoopback], but pkt_start waits for a chosen
/// number of RX bit strobes after reset instead of a fixed settle time,
/// so the test can land it on a specific bit_count phase.
Future<Map<String, dynamic>> _runLoopbackWithWarmup({
  required int pid,
  required List<int> dataBytes,
  required int warmupBitStrobes,
}) async {
  final tx = HarborUsbFsTx(name: 'tx_lb_w');
  final rx = HarborUsbFsRx(name: 'rx_lb_w');

  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final pktStart = Logic(name: 'pkt_start');
  final pidIn = Logic(name: 'pid_in', width: 4);

  tx.input('clk').srcConnection! <= clk;
  tx.input('reset').srcConnection! <= reset;
  rx.input('clk').srcConnection! <= clk;
  rx.input('reset').srcConnection! <= reset;

  tx.input('bit_strobe').srcConnection! <= rx.output('bit_strobe');

  final rxDp = mux(tx.output('oe'), tx.output('dp'), Const(1)).named('rx_dp');
  final rxDn = mux(tx.output('oe'), tx.output('dn'), Const(0)).named('rx_dn');
  rx.input('dp').srcConnection! <= rxDp;
  rx.input('dn').srcConnection! <= rxDn;

  tx.input('pkt_start').srcConnection! <= pktStart;
  tx.input('pid').srcConnection! <= pidIn;

  final byteIdx = Logic(name: 'byte_idx', width: 5);
  Logic txDataLogic = Const(dataBytes[0], width: 8);
  for (var i = 1; i < dataBytes.length; i++) {
    txDataLogic = mux(
      byteIdx.eq(Const(i, width: 5)),
      Const(dataBytes[i], width: 8),
      txDataLogic,
    );
  }
  tx.input('tx_data').srcConnection! <= txDataLogic;
  tx.input('tx_data_avail').srcConnection! <=
      byteIdx.lt(Const(dataBytes.length, width: 5));

  Sequential(clk, [
    If(
      reset,
      then: [byteIdx < Const(0, width: 5)],
      orElse: [
        If(
          tx.output('tx_data_get'),
          then: [byteIdx < byteIdx + Const(1, width: 5)],
        ),
      ],
    ),
  ]);

  await tx.build();
  await rx.build();

  reset.inject(1);
  pktStart.inject(0);
  pidIn.inject(pid);
  Simulator.setMaxSimTime(500000);
  unawaited(Simulator.run());

  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.inject(0);
  for (var i = 0; i < 30; i++) {
    await clk.nextPosedge;
  }

  var strobes = 0;
  while (strobes < warmupBitStrobes) {
    await clk.nextPosedge;
    if (rx.output('bit_strobe').value.toInt() == 1) strobes++;
  }

  pktStart.inject(1);
  await clk.nextPosedge;
  pktStart.inject(0);

  final rxBytes = <int>[];
  var txPktEnd = 0;
  for (var i = 0; i < 20000; i++) {
    await clk.nextPosedge;
    if (rx.output('rx_data_put').value.toInt() == 1) {
      rxBytes.add(rx.output('rx_data').value.toInt());
    }
    if (tx.output('pkt_end').value.toInt() == 1) {
      txPktEnd++;
      for (var j = 0; j < 200; j++) {
        await clk.nextPosedge;
        if (rx.output('rx_data_put').value.toInt() == 1) {
          rxBytes.add(rx.output('rx_data').value.toInt());
        }
      }
      break;
    }
  }

  final result = {
    'rxBytes': rxBytes,
    'txPktEnd': txPktEnd,
    'pid': rx.output('pid').value.toInt(),
    'valid': rx.output('valid_packet').value.toInt(),
  };

  await Simulator.endSimulation();
  return result;
}
