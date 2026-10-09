import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_test_host.dart';

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
      final crc = usbCrc16(payload);
      final tokenSyms = usbEncode([usbPidByte(1), ...usbTokenBytes(0, 0)]);
      // Inter-packet gap: 2 bit times of idle J.
      tokenSyms.addAll([
        [1, 0],
        [1, 0],
      ]);
      tokenSyms.addAll(
        usbEncode([usbPidByte(3), ...payload, crc & 0xFF, (crc >> 8) & 0xFF]),
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
      final crc = usbCrc16(req);
      final syms = usbEncode([usbPidByte(13), ...usbTokenBytes(0, 0)]);
      syms.addAll([
        [1, 0],
        [1, 0],
      ]);
      syms.addAll(
        usbEncode([usbPidByte(3), ...req, crc & 0xFF, (crc >> 8) & 0xFF]),
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
      final syms = usbEncode([usbPidByte(9), ...usbTokenBytes(0, 0)]);

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
      final syms = usbEncode([usbPidByte(9), ...usbTokenBytes(0, 0)]);
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

    test('a SETUP is accepted right after a stall', () async {
      final pe = HarborUsbFsPe(
        numOutEps: 1,
        numInEps: 1,
        name: 'pe_stall_setup_test',
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final dp = Logic(name: 'dp');
      final dm = Logic(name: 'dm');
      final outStall = Logic(name: 'out_stall');

      pe.input('clk').srcConnection! <= clk;
      pe.input('reset').srcConnection! <= reset;
      pe.input('dev_addr').srcConnection! <= Const(0, width: 7);
      pe.input('usb_p_rx').srcConnection! <= dp;
      pe.input('usb_n_rx').srcConnection! <= dm;

      final avail = Logic(name: 'avail_tap')
        ..gets(pe.output('out_ep_data_avail'));
      final getSig = Logic(name: 'get_sig');
      pe.input('out_ep_req').srcConnection! <= avail;
      pe.input('out_ep_data_get').srcConnection! <= getSig;
      pe.input('out_ep_stall').srcConnection! <= outStall;
      pe.input('in_ep_req').srcConnection! <= Const(0);
      pe.input('in_ep_data_put').srcConnection! <= Const(0);
      pe.input('in_ep_data_done').srcConnection! <= Const(0);
      pe.input('in_ep_stall').srcConnection! <= Const(0);

      final watch = _watchLine(pe, clk, reset);

      await pe.build();
      await watch.rx.build();

      reset.inject(1);
      dp.inject(1);
      dm.inject(0);
      outStall.inject(0);
      getSig.inject(0);
      Simulator.setMaxSimTime(500000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      for (var i = 0; i < 30; i++) {
        await clk.nextPosedge;
      }

      // The stall is a level, not a one-shot latch, so hold it high
      // for the rest of the test. A SETUP on a control endpoint is
      // accepted no matter the stall, but a later OUT still gets STALL.
      outStall.inject(1);
      for (var i = 0; i < 10; i++) {
        await clk.nextPosedge;
        watch.sample();
      }

      // Host: SETUP token then an 8-byte DATA0 request, same as any
      // other SETUP. USB 2.0 8.5.3.4 requires a SETUP to always be
      // accepted, even while the endpoint is stalled.
      final req = <int>[0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00];
      final crc = usbCrc16(req);
      final syms = usbEncode([usbPidByte(13), ...usbTokenBytes(0, 0)]);
      syms.addAll([
        [1, 0],
        [1, 0],
      ]);
      syms.addAll(
        usbEncode([usbPidByte(3), ...req, crc & 0xFF, (crc >> 8) & 0xFF]),
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
      expect(
        watch.pids,
        contains(2),
        reason: 'the SETUP data is ACKed, not NAKed, while stalled',
      );

      // The SETUP bytes must also be readable: a stall exit that gets
      // stuck short of the getting state leaves the engine ACKing on
      // the wire while avail never rises, which silently drops the
      // request.
      final gotBytes = <int>[];
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
      expect(
        gotBytes,
        req,
        reason: 'the SETUP bytes are readable after the stall',
      );

      // The stall is still held high, so a later non-SETUP transaction
      // on the same endpoint gets STALL, not an ACK.
      final pidsBeforeOut = watch.pids.length;
      final outPayload = <int>[0x01];
      final outCrc = usbCrc16(outPayload);
      final outSyms = usbEncode([usbPidByte(1), ...usbTokenBytes(0, 0)]);
      outSyms.addAll([
        [1, 0],
        [1, 0],
      ]);
      outSyms.addAll(
        usbEncode([
          usbPidByte(3),
          ...outPayload,
          outCrc & 0xFF,
          (outCrc >> 8) & 0xFF,
        ]),
      );

      for (final s in outSyms) {
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
        watch.pids.sublist(pidsBeforeOut),
        contains(14),
        reason: 'a stalled endpoint still answers STALL after a SETUP',
      );

      await Simulator.endSimulation();
    });

    test('a full maxPacketSize OUT packet is received intact', () async {
      final pe = HarborUsbFsPe(
        numOutEps: 1,
        numInEps: 1,
        maxPacketSize: 64,
        name: 'pe_full_packet_test',
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
      final getSig = Logic(name: 'get_sig');
      pe.input('out_ep_req').srcConnection! <= avail;
      pe.input('out_ep_data_get').srcConnection! <= getSig;
      pe.input('out_ep_stall').srcConnection! <= Const(0);
      pe.input('in_ep_req').srcConnection! <= Const(0);
      pe.input('in_ep_data_put').srcConnection! <= Const(0);
      pe.input('in_ep_data_done').srcConnection! <= Const(0);
      pe.input('in_ep_stall').srcConnection! <= Const(0);

      final watch = _watchLine(pe, clk, reset);

      await pe.build();
      await watch.rx.build();

      reset.inject(1);
      dp.inject(1);
      dm.inject(0);
      getSig.inject(0);
      Simulator.setMaxSimTime(1000000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      for (var i = 0; i < 30; i++) {
        await clk.nextPosedge;
      }

      // Host: OUT token (addr 0, endp 0) then a full 64-byte DATA0
      // payload, the largest full-speed packet.
      final payload = List.generate(64, (i) => i & 0xFF);
      final crc = usbCrc16(payload);
      final tokenSyms = usbEncode([usbPidByte(1), ...usbTokenBytes(0, 0)]);
      tokenSyms.addAll([
        [1, 0],
        [1, 0],
      ]);
      tokenSyms.addAll(
        usbEncode([usbPidByte(3), ...payload, crc & 0xFF, (crc >> 8) & 0xFF]),
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

      dp.inject(1);
      dm.inject(0);
      getSig.inject(0);
      for (var i = 0; i < 240; i++) {
        await clk.nextPosedge;
        watch.sample();
        if (pe.output('out_ep_acked').value.toInt() == 1) ackedCount++;
      }
      var guard = 0;
      while (avail.value.toInt() == 1 && guard < 80) {
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
      expect(gotBytes, payload, reason: 'all 64 bytes, intact and in order');

      await Simulator.endSimulation();
    });

    test(
      'a new token landing the cycle a drain completes still gets through',
      () async {
        // Drives HarborUsbFsOutPe at its rx_* ports directly, bypassing
        // the line PHY, so the drain's last get pulse and the next
        // token's arrival can be placed on the exact same cycle.
        final outPe = HarborUsbFsOutPe(numOutEps: 1, name: 'pe_race_test');
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final getSig = Logic(name: 'get_sig');
        final rxPktStart = Logic(name: 'rx_pkt_start');
        final rxPktEnd = Logic(name: 'rx_pkt_end');
        final rxPktValid = Logic(name: 'rx_pkt_valid');
        final rxPid = Logic(name: 'rx_pid', width: 4);
        final rxDataPut = Logic(name: 'rx_data_put');
        final rxData = Logic(name: 'rx_data', width: 8);

        outPe.input('clk').srcConnection! <= clk;
        outPe.input('reset').srcConnection! <= reset;
        outPe.input('reset_ep').srcConnection! <= Const(0);
        outPe.input('dev_addr').srcConnection! <= Const(0, width: 7);
        outPe.input('out_ep_data_get').srcConnection! <= getSig;
        outPe.input('out_ep_stall').srcConnection! <= Const(0);
        outPe.input('out_ep_grant').srcConnection! <= Const(1);
        outPe.input('rx_pkt_start').srcConnection! <= rxPktStart;
        outPe.input('rx_pkt_end').srcConnection! <= rxPktEnd;
        outPe.input('rx_pkt_valid').srcConnection! <= rxPktValid;
        outPe.input('rx_pid').srcConnection! <= rxPid;
        outPe.input('rx_addr').srcConnection! <= Const(0, width: 7);
        outPe.input('rx_endp').srcConnection! <= Const(0, width: 4);
        outPe.input('rx_frame_num').srcConnection! <= Const(0, width: 11);
        outPe.input('rx_data_put').srcConnection! <= rxDataPut;
        outPe.input('rx_data').srcConnection! <= rxData;
        outPe.input('tx_pkt_end').srcConnection! <= Const(0);

        await outPe.build();

        reset.inject(1);
        getSig.inject(0);
        rxPktStart.inject(0);
        rxPktEnd.inject(0);
        rxPktValid.inject(0);
        rxPid.inject(0);
        rxDataPut.inject(0);
        rxData.inject(0);
        Simulator.setMaxSimTime(200000);
        unawaited(Simulator.run());

        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);
        for (var i = 0; i < 10; i++) {
          await clk.nextPosedge;
        }

        // out_ep_acked is a one-cycle pulse, so it is counted on every
        // edge rather than sampled once after the fact.
        var ackedCount = 0;
        final sub = clk.posedge.listen((_) {
          if (outPe.output('out_ep_acked').value.toInt() == 1) ackedCount++;
        });

        // First OUT transaction: a 3-byte DATA0 payload.
        rxPktEnd.inject(1);
        rxPktValid.inject(1);
        rxPid.inject(1); // OUT token.
        await clk.nextPosedge;
        rxPktEnd.inject(0);
        rxPktValid.inject(0);
        await clk.nextPosedge;

        rxPktStart.inject(1);
        await clk.nextPosedge;
        rxPktStart.inject(0);

        final firstPayload = <int>[0xAA, 0xBB, 0xCC];
        for (final b in firstPayload) {
          rxDataPut.inject(1);
          rxData.inject(b);
          await clk.nextPosedge;
        }
        // Two CRC bytes: counted into the put address, not read back.
        for (var i = 0; i < 2; i++) {
          rxDataPut.inject(1);
          rxData.inject(0);
          await clk.nextPosedge;
        }
        rxDataPut.inject(0);

        rxPktEnd.inject(1);
        rxPktValid.inject(1);
        rxPid.inject(3); // DATA0.
        await clk.nextPosedge;
        rxPktEnd.inject(0);
        rxPktValid.inject(0);
        for (var i = 0; i < 5; i++) {
          await clk.nextPosedge;
        }

        expect(ackedCount, 1, reason: 'first packet ACKed');
        ackedCount = 0;

        // Drain all three bytes. out_ep_data already holds the byte at
        // the current get address, so each one is sampled before the
        // pulse that advances past it.
        final gotBytes = <int>[];
        for (var i = 0; i < 2; i++) {
          gotBytes.add(outPe.output('out_ep_data').value.toInt());
          getSig.inject(1);
          await clk.nextPosedge;
          getSig.inject(0);
          await clk.nextPosedge;
        }

        // The last byte's sample, and the sample's own get pulse, land
        // the same way. That pulse and the second OUT token's arrival
        // for the same endpoint land one cycle apart: the drain only
        // becomes visible (get address caught up to put address) the
        // cycle after the pulse, which is exactly the cycle this
        // token's own token-received pulse fires.
        gotBytes.add(outPe.output('out_ep_data').value.toInt());
        getSig.inject(1);
        await clk.nextPosedge;
        getSig.inject(0);
        rxPktEnd.inject(1);
        rxPktValid.inject(1);
        rxPid.inject(1); // OUT token, same endpoint.
        await clk.nextPosedge;
        rxPktEnd.inject(0);
        rxPktValid.inject(0);
        await clk.nextPosedge;

        rxPktStart.inject(1);
        await clk.nextPosedge;
        rxPktStart.inject(0);

        const secondPayload = [0xDD];
        for (final b in secondPayload) {
          rxDataPut.inject(1);
          rxData.inject(b);
          await clk.nextPosedge;
        }
        for (var i = 0; i < 2; i++) {
          rxDataPut.inject(1);
          rxData.inject(0);
          await clk.nextPosedge;
        }
        rxDataPut.inject(0);

        rxPktEnd.inject(1);
        rxPktValid.inject(1);
        rxPid.inject(11); // DATA1: the toggle flipped after the first ACK.
        await clk.nextPosedge;
        rxPktEnd.inject(0);
        rxPktValid.inject(0);
        for (var i = 0; i < 10; i++) {
          await clk.nextPosedge;
        }

        expect(ackedCount, 1, reason: 'second packet ACKed too');

        // Drain the second packet's one byte.
        var guard = 0;
        while (outPe.output('out_ep_data_avail').value.toInt() == 1 &&
            guard < 10) {
          guard++;
          gotBytes.add(outPe.output('out_ep_data').value.toInt());
          getSig.inject(1);
          await clk.nextPosedge;
          getSig.inject(0);
          await clk.nextPosedge;
        }

        expect(
          gotBytes,
          [...firstPayload, ...secondPayload],
          reason:
              'the second packet must still become available, not get '
              'stuck in ready forever',
        );

        await sub.cancel();
        await Simulator.endSimulation();
      },
    );
  });
}
