import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Host-side line encoder (from usb_fs_phy_test.dart).
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
  var line = 1;
  for (final bit in stuffed) {
    if (bit == 0) line = 1 - line;
    out.add(line == 1 ? [1, 0] : [0, 1]);
  }
  out.add([0, 0]);
  out.add([0, 0]);
  out.add([1, 0]);
  return out;
}

/// Decodes the packets that the engine drives on to the line.
///
/// The test calls [sample] after each clock edge. The watcher then keeps
/// the PID and the bytes of every packet that the engine completed.
class _LineWatch {
  _LineWatch(this.rx);

  /// The spare receiver that listens to the line.
  final HarborUsbFsRx rx;

  /// The PID of each completed packet, in order.
  final List<int> pids = <int>[];

  /// The bytes of each completed packet, in order. A handshake packet
  /// has no bytes. A data packet holds the payload and then the CRC16.
  final List<List<int>> packets = <List<int>>[];

  final List<int> _bytes = <int>[];
  int _first = 0;

  /// Reads the receiver outputs for the clock edge that just occurred.
  void sample() {
    final start = rx.output('pkt_start').value;
    if (start.isValid && start.toInt() == 1) {
      _first = _bytes.length;
    }
    final put = rx.output('rx_data_put').value;
    if (put.isValid && put.toInt() == 1) {
      final d = rx.output('rx_data').value;
      if (d.isValid) _bytes.add(d.toInt());
    }
    final end = rx.output('pkt_end').value;
    if (end.isValid && end.toInt() == 1) {
      final pid = rx.output('pid').value;
      if (pid.isValid) {
        pids.add(pid.toInt());
        packets.add(_bytes.sublist(_first));
      }
    }
  }
}

/// Attaches a spare receiver to the line that [pe] drives. The line
/// idles at J through the pull-up while the engine does not drive it.
///
/// Call this before the reset pulse and build the receiver before the
/// reset pulse too. A receiver that is built after reset goes low never
/// sees a reset edge, and every sample it takes is X.
_LineWatch _watchLine(HarborUsbFsPe pe, Logic clk, Logic reset) {
  final obsRx = HarborUsbFsRx(name: 'obs_rx');
  obsRx.input('clk').srcConnection! <= clk;
  obsRx.input('reset').srcConnection! <= reset;
  obsRx.input('dp').srcConnection! <=
      mux(pe.output('usb_tx_en'), pe.output('usb_p_tx'), Const(1));
  obsRx.input('dn').srcConnection! <=
      mux(pe.output('usb_tx_en'), pe.output('usb_n_tx'), Const(0));
  return _LineWatch(obsRx);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborUsbFsPe', () {
    test('OUT transaction delivers data and acks', () async {
      final pe = HarborUsbFsPe(numOutEps: 1, numInEps: 1, name: 'pe_out_test');
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final dp = Logic(name: 'dp');
      final dm = Logic(name: 'dm');

      pe.input('clk').srcConnection! <= clk;
      pe.input('reset').srcConnection! <= reset;
      pe.input('dev_addr').srcConnection! <= Const(0, width: 7);
      pe.input('usb_p_rx').srcConnection! <= dp;
      pe.input('usb_n_rx').srcConnection! <= dm;

      // Consumer model. The get signal is driven with an explicit
      // handshake from the test loop (one pulse per byte): a direct
      // combinational get-to-avail feedback re-enters the engine's
      // Combinational blocks, which ROHD forbids.
      final avail = Logic(name: 'avail_tap')
        ..gets(pe.output('out_ep_data_avail'));
      final getSig = Logic(name: 'get_sig');
      pe.input('out_ep_req').srcConnection! <= avail;
      pe.input('out_ep_data_get').srcConnection! <= getSig;
      pe.input('out_ep_stall').srcConnection! <= Const(0);

      // Leave the IN endpoint idle.
      pe.input('in_ep_req').srcConnection! <= Const(0);
      pe.input('in_ep_data_put').srcConnection! <= Const(0);
      pe.input('in_ep_data_done').srcConnection! <= Const(0);
      pe.input('in_ep_stall').srcConnection! <= Const(0);

      // Watch the driven line. The receiver is built before the reset
      // pulse so its registers start from a known state.
      final watch = _watchLine(pe, clk, reset);

      await pe.build();
      await watch.rx.build();

      reset.inject(1);
      dp.inject(1);
      dm.inject(0);
      getSig.inject(0);
      Simulator.setMaxSimTime(500000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      for (var i = 0; i < 30; i++) {
        await clk.nextPosedge;
      }

      // Host: OUT token (addr 0, endp 0) then DATA0 with a payload.
      final payload = <int>[0xC0, 0xFF, 0xEE];
      final crc = _crc16(payload);
      final tokenSyms = _encode([_pidByte(1), ..._tokenBytes(0, 0)]);
      // Inter-packet gap: 2 bit times of idle J.
      tokenSyms.addAll([
        [1, 0],
        [1, 0],
      ]);
      tokenSyms.addAll(
        _encode([_pidByte(3), ...payload, crc & 0xFF, (crc >> 8) & 0xFF]),
      );

      var ackedCount = 0;
      final gotBytes = <int>[];

      for (final s in tokenSyms) {
        for (var t = 0; t < 4; t++) {
          dp.inject(s[0]);
          dm.inject(s[1]);
          await clk.nextPosedge;
          watch.sample();
          if (pe.output('out_ep_acked').value.toInt() == 1) ackedCount++;
        }
      }

      // Idle long enough for the ACK handshake to reach the line, then
      // drain the buffer with an explicit handshake: one get pulse per
      // byte, then two cycles for the read pipeline.
      dp.inject(1);
      dm.inject(0);
      getSig.inject(0);
      for (var i = 0; i < 240; i++) {
        await clk.nextPosedge;
        watch.sample();
        if (pe.output('out_ep_acked').value.toInt() == 1) ackedCount++;
      }
      // out_ep_data already shows the byte at the current get
      // address, so sample first, then advance with a get pulse.
      var guard = 0;
      while (avail.value.toInt() == 1 && guard < 20) {
        guard++;
        gotBytes.add(pe.output('out_ep_data').value.toInt());
        getSig.inject(1);
        await clk.nextPosedge;
        watch.sample();
        getSig.inject(0);
        await clk.nextPosedge;
        watch.sample();
        await clk.nextPosedge;
        watch.sample();
      }
      for (var i = 0; i < 20; i++) {
        await clk.nextPosedge;
        watch.sample();
        if (pe.output('out_ep_acked').value.toInt() == 1) ackedCount++;
      }

      expect(ackedCount, 1, reason: 'one ACK pulse');
      expect(
        pe.output('out_ep_setup').value.toInt(),
        0,
        reason: 'OUT not SETUP',
      );
      // The payload arrives with the 2 CRC bytes stripped.
      expect(gotBytes, payload, reason: 'delivered payload bytes');
      // The engine must also put a real ACK handshake on the line. PID
      // 2 is ACK.
      expect(watch.pids, contains(2), reason: 'ACK handshake on the line');
      expect(
        watch.packets[watch.pids.indexOf(2)],
        isEmpty,
        reason: 'a handshake carries no bytes',
      );

      await Simulator.endSimulation();
    });

    test('SETUP transaction sets the setup flag', () async {
      final pe = HarborUsbFsPe(
        numOutEps: 1,
        numInEps: 1,
        name: 'pe_setup_test',
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final dp = Logic(name: 'dp');
      final dm = Logic(name: 'dm');

      pe.input('clk').srcConnection! <= clk;
      pe.input('reset').srcConnection! <= reset;
      pe.input('dev_addr').srcConnection! <= Const(0, width: 7);
      pe.input('usb_p_rx').srcConnection! <= dp;
      pe.input('usb_n_rx').srcConnection! <= dm;

      final avail = Logic(name: 'avail_tap')
        ..gets(pe.output('out_ep_data_avail'));
      final getReg = Logic(name: 'get_reg');
      pe.input('out_ep_req').srcConnection! <= avail;
      pe.input('out_ep_data_get').srcConnection! <= getReg;
      pe.input('out_ep_stall').srcConnection! <= Const(0);
      pe.input('in_ep_req').srcConnection! <= Const(0);
      pe.input('in_ep_data_put').srcConnection! <= Const(0);
      pe.input('in_ep_data_done').srcConnection! <= Const(0);
      pe.input('in_ep_stall').srcConnection! <= Const(0);

      // Watch the driven line. The receiver is built before the reset
      // pulse so its registers start from a known state.
      final watch = _watchLine(pe, clk, reset);

      await pe.build();
      await watch.rx.build();

      reset.inject(1);
      dp.inject(1);
      dm.inject(0);
      Simulator.setMaxSimTime(500000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      for (var i = 0; i < 30; i++) {
        await clk.nextPosedge;
      }

      // Host: SETUP token then DATA0 with an 8-byte request.
      final req = <int>[0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00];
      final crc = _crc16(req);
      final syms = _encode([_pidByte(13), ..._tokenBytes(0, 0)]);
      syms.addAll([
        [1, 0],
        [1, 0],
      ]);
      syms.addAll(
        _encode([_pidByte(3), ...req, crc & 0xFF, (crc >> 8) & 0xFF]),
      );

      for (final s in syms) {
        for (var t = 0; t < 4; t++) {
          dp.inject(s[0]);
          dm.inject(s[1]);
          await clk.nextPosedge;
          watch.sample();
        }
      }

      dp.inject(1);
      dm.inject(0);
      for (var i = 0; i < 300; i++) {
        await clk.nextPosedge;
        watch.sample();
      }

      expect(
        pe.output('out_ep_setup').value.toInt(),
        1,
        reason: 'SETUP flag set',
      );
      // The engine must answer the SETUP data with a real ACK
      // handshake. PID 2 is ACK.
      expect(watch.pids, contains(2), reason: 'ACK handshake on the line');

      await Simulator.endSimulation();
    });

    test('IN token with no data answers a NAK handshake on the line', () async {
      final pe = HarborUsbFsPe(numOutEps: 1, numInEps: 1, name: 'pe_nak_test');
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final dp = Logic(name: 'dp');
      final dm = Logic(name: 'dm');

      pe.input('clk').srcConnection! <= clk;
      pe.input('reset').srcConnection! <= reset;
      pe.input('dev_addr').srcConnection! <= Const(0, width: 7);
      pe.input('usb_p_rx').srcConnection! <= dp;
      pe.input('usb_n_rx').srcConnection! <= dm;

      pe.input('out_ep_req').srcConnection! <= Const(0);
      pe.input('out_ep_data_get').srcConnection! <= Const(0);
      pe.input('out_ep_stall').srcConnection! <= Const(0);
      pe.input('in_ep_req').srcConnection! <= Const(0);
      pe.input('in_ep_data_put').srcConnection! <= Const(0);
      pe.input('in_ep_data_done').srcConnection! <= Const(0);
      pe.input('in_ep_stall').srcConnection! <= Const(0);

      // Watch the driven line. The receiver is built before the reset
      // pulse so its registers start from a known state.
      final watch = _watchLine(pe, clk, reset);

      await pe.build();
      await watch.rx.build();

      reset.inject(1);
      dp.inject(1);
      dm.inject(0);
      Simulator.setMaxSimTime(500000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      for (var i = 0; i < 30; i++) {
        await clk.nextPosedge;
      }

      // Host: IN token (addr 0, endp 0).
      final syms = _encode([_pidByte(9), ..._tokenBytes(0, 0)]);

      var txEnabled = false;
      for (final s in syms) {
        for (var t = 0; t < 4; t++) {
          dp.inject(s[0]);
          dm.inject(s[1]);
          await clk.nextPosedge;
          watch.sample();
          if (pe.output('usb_tx_en').value.toInt() == 1) txEnabled = true;
        }
      }
      // Let the response finish.
      dp.inject(1);
      dm.inject(0);
      for (var i = 0; i < 400; i++) {
        await clk.nextPosedge;
        watch.sample();
        if (pe.output('usb_tx_en').value.toInt() == 1) txEnabled = true;
      }

      expect(txEnabled, true, reason: 'the device drove the line');
      // The endpoint holds no data, so the answer must be a real NAK
      // handshake. PID 10 is NAK.
      expect(watch.pids, contains(10), reason: 'NAK handshake on the line');
      expect(
        watch.packets[watch.pids.indexOf(10)],
        isEmpty,
        reason: 'a handshake carries no bytes',
      );
      expect(watch.pids, isNot(contains(3)), reason: 'no DATA0 answer');
      expect(watch.pids, isNot(contains(11)), reason: 'no DATA1 answer');

      await Simulator.endSimulation();
    });

    test('IN token with data sends the payload on the line', () async {
      final pe = HarborUsbFsPe(numOutEps: 1, numInEps: 1, name: 'pe_in_test');
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final dp = Logic(name: 'dp');
      final dm = Logic(name: 'dm');
      final inData = Logic(name: 'in_data', width: 8);
      final inPut = Logic(name: 'in_put');
      final inDone = Logic(name: 'in_done');

      pe.input('clk').srcConnection! <= clk;
      pe.input('reset').srcConnection! <= reset;
      pe.input('dev_addr').srcConnection! <= Const(0, width: 7);
      pe.input('usb_p_rx').srcConnection! <= dp;
      pe.input('usb_n_rx').srcConnection! <= dm;

      pe.input('out_ep_req').srcConnection! <= Const(0);
      pe.input('out_ep_data_get').srcConnection! <= Const(0);
      pe.input('out_ep_stall').srcConnection! <= Const(0);
      // The endpoint always requests the bus, so the arbiter passes its
      // byte to the IN engine.
      pe.input('in_ep_req').srcConnection! <= Const(1);
      pe.input('in_ep_data').srcConnection! <= inData;
      pe.input('in_ep_data_put').srcConnection! <= inPut;
      pe.input('in_ep_data_done').srcConnection! <= inDone;
      pe.input('in_ep_stall').srcConnection! <= Const(0);

      // Watch the driven line. The receiver is built before the reset
      // pulse so its registers start from a known state.
      final watch = _watchLine(pe, clk, reset);

      await pe.build();
      await watch.rx.build();

      reset.inject(1);
      dp.inject(1);
      dm.inject(0);
      inData.inject(0);
      inPut.inject(0);
      inDone.inject(0);
      Simulator.setMaxSimTime(1000000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      for (var i = 0; i < 30; i++) {
        await clk.nextPosedge;
      }

      // Fill the endpoint buffer: one put pulse per byte, then one
      // done pulse to close the packet.
      final payload = <int>[0x12, 0x34, 0x56];
      for (final b in payload) {
        expect(
          pe.output('in_ep_data_free').value.toInt(),
          1,
          reason: 'the endpoint has free space',
        );
        inData.inject(b);
        inPut.inject(1);
        await clk.nextPosedge;
        watch.sample();
        inPut.inject(0);
        await clk.nextPosedge;
        watch.sample();
      }
      inDone.inject(1);
      await clk.nextPosedge;
      watch.sample();
      inDone.inject(0);
      for (var i = 0; i < 10; i++) {
        await clk.nextPosedge;
        watch.sample();
      }

      // Host: IN token (addr 0, endp 0).
      final syms = _encode([_pidByte(9), ..._tokenBytes(0, 0)]);
      for (final s in syms) {
        for (var t = 0; t < 4; t++) {
          dp.inject(s[0]);
          dm.inject(s[1]);
          await clk.nextPosedge;
          watch.sample();
        }
      }
      dp.inject(1);
      dm.inject(0);
      for (var i = 0; i < 700; i++) {
        await clk.nextPosedge;
        watch.sample();
      }

      // PID 3 is DATA0 and PID 11 is DATA1. The data toggle picks one.
      final idx = watch.pids.indexWhere((p) => p == 3 || p == 11);
      expect(idx, isNot(-1), reason: 'a DATA packet on the line');
      final sent = watch.packets[idx];
      expect(sent.length, payload.length + 2, reason: 'payload plus crc16');
      expect(
        sent.sublist(0, payload.length),
        payload,
        reason: 'IN payload on the line',
      );
      expect(watch.pids, isNot(contains(10)), reason: 'no NAK answer');

      await Simulator.endSimulation();
    });
  });
}
