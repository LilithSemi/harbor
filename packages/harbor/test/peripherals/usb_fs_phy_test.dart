import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Host-side line encoder (from usb_phy_test.dart). Builds [dp, dn] line
// symbols for a packet (SYNC prepended) with bit stuffing, NRZI and a
// trailing EOP (SE0 SE0 J).

int _crc5(int data, int nbits) {
  var crc = 0x1F;
  for (var i = 0; i < nbits; i++) {
    final bit = (data >> i) & 1;
    final xorIn = (crc & 1) ^ bit;
    crc >>= 1;
    if (xorIn != 0) crc ^= 0x14;
  }
  return (~crc) & 0x1F;
}

int _crc16(List<int> bytes) {
  var crc = 0xFFFF;
  for (final b in bytes) {
    for (var i = 0; i < 8; i++) {
      final bit = (b >> i) & 1;
      final xorIn = (crc & 1) ^ bit;
      crc >>= 1;
      if (xorIn != 0) crc ^= 0xA001;
    }
  }
  return (~crc) & 0xFFFF;
}

List<int> _tokenBytes(int addr, int endp) {
  final field = (addr & 0x7F) | ((endp & 0xF) << 7);
  final v = field | (_crc5(field, 11) << 11);
  return [v & 0xFF, (v >> 8) & 0xFF];
}

int _pidByte(int nibble) => (nibble & 0xF) | ((~nibble & 0xF) << 4);

List<List<int>> _encode(List<int> bytes) {
  final raw = <int>[];
  for (final b in [0x80, ...bytes]) {
    for (var i = 0; i < 8; i++) {
      raw.add((b >> i) & 1);
    }
  }
  final stuffed = <int>[];
  var ones = 0;
  for (final bit in raw) {
    stuffed.add(bit);
    if (bit == 1) {
      ones++;
      if (ones == 6) {
        stuffed.add(0);
        ones = 0;
      }
    } else {
      ones = 0;
    }
  }
  final out = <List<int>>[];
  var line = 1; // idle J
  for (final bit in stuffed) {
    if (bit == 0) line = 1 - line; // NRZI: 0 => transition
    out.add(line == 1 ? [1, 0] : [0, 1]);
  }
  out.add([0, 0]); // EOP SE0
  out.add([0, 0]); // EOP SE0
  out.add([1, 0]); // J
  return out;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborUsbFsRx', () {
    // Drives line symbols into the RX and collects the decoded stream.
    Future<Map<String, dynamic>> runSymbols(List<List<int>> syms) async {
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

      // Idle J to drain the pipeline.
      dp.inject(1);
      dn.inject(0);
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
        _encode([_pidByte(9), ..._tokenBytes(0x2A, 1)]),
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
      final r = await runSymbols(_encode([_pidByte(1), ..._tokenBytes(0, 0)]));
      expect(r['pid'], 1, reason: 'OUT pid');
      expect(r['addr'], 0, reason: 'token addr');
      expect(r['endp'], 0, reason: 'token endp');
      expect(r['valid'], 1, reason: 'crc5 ok');
    });

    test('decodes a SETUP token', () async {
      final r = await runSymbols(_encode([_pidByte(13), ..._tokenBytes(5, 0)]));
      expect(r['pid'], 13, reason: 'SETUP pid');
      expect(r['addr'], 5, reason: 'token addr');
      expect(r['endp'], 0, reason: 'token endp');
      expect(r['valid'], 1, reason: 'crc5 ok');
    });

    test('decodes a DATA0 packet payload', () async {
      final payload = <int>[0xDE, 0xAD, 0xBE, 0xEF];
      final crc = _crc16(payload);
      final bytes = [_pidByte(3), ...payload, crc & 0xFF, (crc >> 8) & 0xFF];
      final r = await runSymbols(_encode(bytes));
      expect(r['pid'], 3, reason: 'DATA0 pid');
      expect(r['valid'], 1, reason: 'crc16 ok');
      // The RX stream includes the 2 trailing CRC16 bytes by design; the
      // downstream OUT protocol engine strips them.
      expect(r['dataBytes'], [
        ...payload,
        crc & 0xFF,
        (crc >> 8) & 0xFF,
      ], reason: 'payload plus crc bytes');
    });

    test('decodes a DATA1 packet payload', () async {
      final payload = <int>[0x01, 0x02, 0x03];
      final crc = _crc16(payload);
      final bytes = [_pidByte(11), ...payload, crc & 0xFF, (crc >> 8) & 0xFF];
      final r = await runSymbols(_encode(bytes));
      expect(r['pid'], 11, reason: 'DATA1 pid');
      expect(r['valid'], 1, reason: 'crc16 ok');
      expect(r['dataBytes'], [
        ...payload,
        crc & 0xFF,
        (crc >> 8) & 0xFF,
      ], reason: 'payload plus crc bytes');
    });

    test('decodes an ACK handshake', () async {
      final r = await runSymbols(_encode([_pidByte(2)]));
      expect(r['pid'], 2, reason: 'ACK pid');
      expect(r['valid'], 1, reason: 'handshake valid');
      expect((r['dataBytes'] as List).isEmpty, true, reason: 'no data');
    });

    test('rejects a corrupted data packet', () async {
      final payload = <int>[0xAA, 0x55];
      final crc = _crc16(payload);
      // Corrupt one CRC byte.
      final bytes = [
        _pidByte(3),
        ...payload,
        (crc & 0xFF) ^ 0xFF,
        (crc >> 8) & 0xFF,
      ];
      final r = await runSymbols(_encode(bytes));
      expect(r['valid'], 0, reason: 'crc16 failure flags invalid');
    });

    test('decodes back-to-back packets', () async {
      final syms = <List<int>>[];
      // Token then data, each with a full EOP, no idle gap between them.
      syms.addAll(_encode([_pidByte(9), ..._tokenBytes(0x10, 2)]));
      syms.addAll(_encode([_pidByte(3), 0x77]));
      final r = await runSymbols(syms);
      expect(r['pktStarts'], 2, reason: 'two packet starts');
      expect(r['pktEnds'], 2, reason: 'two packet ends');
      expect(r['pid'], 3, reason: 'last packet is DATA0');
      expect(r['dataBytes'], [0x77], reason: 'data payload');
    });
  });

  _txTests();
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
      final crc = _crc16(data);
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
      final crc = _crc16(data);
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
