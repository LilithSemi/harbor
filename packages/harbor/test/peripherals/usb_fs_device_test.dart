import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Host-side line encoder (shared with the other USB tests).
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

// The mimic device descriptor (18 bytes).
const _devDesc = <int>[
  18, 1, 0x00, 0x02, 0xFF, 0x00, 0x00, 64, //
  0x09, 0x12, 0xC1, 0x10, 0x00, 0x01, 1, 2, 0, 1,
];

// A minimal no-bulk config descriptor (18 bytes).
const _cfgDesc = <int>[
  9, 2, 18, 0x00, 1, 1, 0, 0x80, 50, //
  9, 4, 0, 0, 0, 0xFF, 0x00, 0x00, 3,
];

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborUsbFsDevice', () {
    // Drives the raw pads and collects the device's transmissions by
    // decoding its driven line with a local NRZI decoder.
    test('enumerates: SETUP, GET_DESCRIPTOR, data and status', () async {
      final dut = HarborUsbFsDevice(
        descriptors: [
          const UsbDescriptorEntry(0x01, 0, _devDesc),
          const UsbDescriptorEntry(0x02, 0, _cfgDesc),
        ],
        bulkEndpoints: false,
        name: 'dev_test',
      );

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final dp = Logic(name: 'dp');
      final dm = Logic(name: 'dm');

      dut.input('clk').srcConnection! <= clk;
      dut.input('reset').srcConnection! <= reset;
      dut.input('dp').srcConnection! <= dp;
      dut.input('dm').srcConnection! <= dm;
      dut.input('cmd_ready').srcConnection! <= Const(0);
      dut.input('resp_data').srcConnection! <= Const(0, width: 8);
      dut.input('resp_valid').srcConnection! <= Const(0);
      dut.input('resp_last').srcConnection! <= Const(0);

      // Observe the device's transmissions with a spare line
      // receiver wired to the device's driven line (J when idle). The
      // receiver is built before the reset pulse so its registers start
      // from a known state.
      final obsRx = HarborUsbFsRx(name: 'obs_rx');
      obsRx.input('clk').srcConnection! <= clk;
      obsRx.input('reset').srcConnection! <= reset;
      final obsDp = mux(dut.output('oe'), dut.output('dp_out'), Const(1));
      final obsDn = mux(dut.output('oe'), dut.output('dm_out'), Const(0));
      obsRx.input('dp').srcConnection! <= obsDp;
      obsRx.input('dn').srcConnection! <= obsDn;

      await dut.build();
      await obsRx.build();

      reset.inject(1);
      dp.inject(1);
      dm.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      for (var i = 0; i < 30; i++) {
        await clk.nextPosedge;
      }

      final txBytes = <int>[];
      var ackCount = 0;
      var pktFirstByte = 0;
      var data1Payload = <int>[];

      Future<void> sample() async {
        final startVal = obsRx.output('pkt_start').value;
        if (startVal.isValid && startVal.toInt() == 1) {
          pktFirstByte = txBytes.length;
        }
        final putVal = obsRx.output('rx_data_put').value;
        if (putVal.isValid && putVal.toInt() == 1) {
          final d = obsRx.output('rx_data').value;
          if (d.isValid) txBytes.add(d.toInt());
        }
        final endVal = obsRx.output('pkt_end').value;
        if (endVal.isValid && endVal.toInt() == 1) {
          final pidVal = obsRx.output('pid').value;
          if (pidVal.isValid) {
            final pid = pidVal.toInt();
            if (pid == 2) {
              ackCount++;
            }
            // The receiver reports the PID on its own port, so the byte
            // stream holds the payload and the CRC16 only.
            if (pid == 11) {
              data1Payload = txBytes.sublist(pktFirstByte);
            }
          }
        }
      }

      // Host: SETUP token then the 8-byte GET_DESCRIPTOR(DEVICE)
      // request as DATA0.
      final req = <int>[0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x40, 0x00];
      final crc = _crc16(req);
      final syms = <List<int>>[];
      syms.addAll(_encode([_pidByte(13), ..._tokenBytes(0, 0)]));
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
          await sample();
        }
      }

      // The device ACKs the setup data, then waits for the IN token.
      dp.inject(1);
      dm.inject(0);
      for (var i = 0; i < 300; i++) {
        await clk.nextPosedge;
        await sample();
      }

      // Host: IN token. The device sends the device descriptor in
      // DATA1.
      final inSyms = _encode([_pidByte(9), ..._tokenBytes(0, 0)]);
      for (final s in inSyms) {
        for (var t = 0; t < 4; t++) {
          dp.inject(s[0]);
          dm.inject(s[1]);
          await clk.nextPosedge;
          await sample();
        }
      }
      dp.inject(1);
      dm.inject(0);
      for (var i = 0; i < 1200; i++) {
        await clk.nextPosedge;
        await sample();
      }

      // The device must ACK the SETUP data packet.
      expect(ackCount, greaterThan(0), reason: 'setup data ACKed');
      // The device answers the IN token with a DATA1 packet that holds
      // the device descriptor and then the CRC16.
      expect(data1Payload, isNotEmpty, reason: 'DATA1 packet present');
      expect(data1Payload.length, 20, reason: 'descriptor plus crc16');
      expect(data1Payload[0], 18, reason: 'descriptor bLength');
      expect(data1Payload[1], 1, reason: 'descriptor type');
      expect(data1Payload[8], 0x09, reason: 'idVendor low');

      await Simulator.endSimulation();
    });

    // Endpoint 1 shares the engine vectors with endpoint 0. This test
    // moves a packet in each direction on endpoint 1 to prove the
    // per-endpoint bit order.
    test('bulk endpoint 1 moves an OUT packet and an IN packet', () async {
      final dut = HarborUsbFsDevice(
        descriptors: [const UsbDescriptorEntry(0x01, 0, _devDesc)],
        name: 'dev_bulk_test',
      );

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final dp = Logic(name: 'dp');
      final dm = Logic(name: 'dm');
      final respData = Logic(name: 'resp_data', width: 8);
      final respValid = Logic(name: 'resp_valid');
      final respLast = Logic(name: 'resp_last');

      dut.input('clk').srcConnection! <= clk;
      dut.input('reset').srcConnection! <= reset;
      dut.input('dp').srcConnection! <= dp;
      dut.input('dm').srcConnection! <= dm;
      dut.input('cmd_ready').srcConnection! <= Const(1);
      dut.input('resp_data').srcConnection! <= respData;
      dut.input('resp_valid').srcConnection! <= respValid;
      dut.input('resp_last').srcConnection! <= respLast;

      final obsRx = HarborUsbFsRx(name: 'obs_rx');
      obsRx.input('clk').srcConnection! <= clk;
      obsRx.input('reset').srcConnection! <= reset;
      obsRx.input('dp').srcConnection! <=
          mux(dut.output('oe'), dut.output('dp_out'), Const(1));
      obsRx.input('dn').srcConnection! <=
          mux(dut.output('oe'), dut.output('dm_out'), Const(0));

      await dut.build();
      await obsRx.build();

      reset.inject(1);
      dp.inject(1);
      dm.inject(0);
      respData.inject(0);
      respValid.inject(0);
      respLast.inject(0);
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      for (var i = 0; i < 30; i++) {
        await clk.nextPosedge;
      }

      final cmdBytes = <int>[];
      var cmdStartCount = 0;
      final txBytes = <int>[];
      var pktFirstByte = 0;
      var data0Payload = <int>[];

      Future<void> sample() async {
        final cv = dut.output('cmd_valid').value;
        if (cv.isValid && cv.toInt() == 1) {
          final cd = dut.output('cmd_data').value;
          expect(cd.isValid, isTrue, reason: 'cmd_data valid while offered');
          cmdBytes.add(cd.toInt());
        }
        final cs = dut.output('cmd_start').value;
        if (cs.isValid && cs.toInt() == 1) cmdStartCount++;
        final startVal = obsRx.output('pkt_start').value;
        if (startVal.isValid && startVal.toInt() == 1) {
          pktFirstByte = txBytes.length;
        }
        final putVal = obsRx.output('rx_data_put').value;
        if (putVal.isValid && putVal.toInt() == 1) {
          final d = obsRx.output('rx_data').value;
          if (d.isValid) txBytes.add(d.toInt());
        }
        final endVal = obsRx.output('pkt_end').value;
        if (endVal.isValid && endVal.toInt() == 1) {
          final pidVal = obsRx.output('pid').value;
          if (pidVal.isValid && pidVal.toInt() == 3) {
            data0Payload = txBytes.sublist(pktFirstByte);
          }
        }
      }

      // Host: OUT token for endpoint 1 then a DATA0 payload.
      final payload = <int>[0xC0, 0xFF, 0xEE];
      final crc = _crc16(payload);
      final syms = <List<int>>[];
      syms.addAll(_encode([_pidByte(1), ..._tokenBytes(0, 1)]));
      syms.addAll([
        [1, 0],
        [1, 0],
      ]);
      syms.addAll(
        _encode([_pidByte(3), ...payload, crc & 0xFF, (crc >> 8) & 0xFF]),
      );
      for (final s in syms) {
        for (var t = 0; t < 4; t++) {
          dp.inject(s[0]);
          dm.inject(s[1]);
          await clk.nextPosedge;
          await sample();
        }
      }
      dp.inject(1);
      dm.inject(0);
      for (var i = 0; i < 400; i++) {
        await clk.nextPosedge;
        await sample();
      }

      expect(cmdBytes, payload, reason: 'ep1 out payload');
      expect(cmdStartCount, 1, reason: 'one ep1 packet accepted');

      // Offer a two byte response, then send the IN token. The ready
      // flag is read before the edge, because the endpoint takes the
      // last byte on the same edge that clears the flag.
      final resp = <int>[0xA5, 0x5A];
      var idx = 0;
      respData.inject(resp[0]);
      respValid.inject(1);
      respLast.inject(resp.length == 1 ? 1 : 0);
      for (var i = 0; i < 40 && idx < resp.length; i++) {
        final rr = dut.output('resp_ready').value;
        final accepted = rr.isValid && rr.toInt() == 1;
        await clk.nextPosedge;
        await sample();
        if (accepted) {
          idx++;
          if (idx < resp.length) {
            respData.inject(resp[idx]);
            respLast.inject(idx == resp.length - 1 ? 1 : 0);
          } else {
            respValid.inject(0);
            respLast.inject(0);
          }
        }
      }
      respValid.inject(0);
      respLast.inject(0);
      expect(idx, resp.length, reason: 'ep1 in bytes accepted');

      final inSyms = _encode([_pidByte(9), ..._tokenBytes(0, 1)]);
      for (final s in inSyms) {
        for (var t = 0; t < 4; t++) {
          dp.inject(s[0]);
          dm.inject(s[1]);
          await clk.nextPosedge;
          await sample();
        }
      }
      dp.inject(1);
      dm.inject(0);
      for (var i = 0; i < 900; i++) {
        await clk.nextPosedge;
        await sample();
      }

      // The DATA0 packet holds the response bytes and then the CRC16.
      expect(data0Payload.length, 4, reason: 'response plus crc16');
      expect(data0Payload.sublist(0, 2), resp, reason: 'ep1 in payload');

      await Simulator.endSimulation();
    });

    // A bulk transfer longer than wMaxPacketSize arrives as more than one
    // packet: full-size packets, then a short packet that ends the
    // transfer. cmd_start marks the start of a TRANSFER, so it pulses only
    // on the first packet of each command. A pulse on every packet makes a
    // command engine that resets its parser on cmd_start drop the bytes of
    // every packet after the first.
    test('a multi-packet EP1 OUT transfer pulses cmd_start once', () async {
      final dut = HarborUsbFsDevice(
        descriptors: [const UsbDescriptorEntry(0x01, 0, _devDesc)],
        name: 'dev_multi_pkt_test',
      );

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final dp = Logic(name: 'dp');
      final dm = Logic(name: 'dm');

      dut.input('clk').srcConnection! <= clk;
      dut.input('reset').srcConnection! <= reset;
      dut.input('dp').srcConnection! <= dp;
      dut.input('dm').srcConnection! <= dm;
      dut.input('cmd_ready').srcConnection! <= Const(1);
      dut.input('resp_data').srcConnection! <= Const(0, width: 8);
      dut.input('resp_valid').srcConnection! <= Const(0);
      dut.input('resp_last').srcConnection! <= Const(0);

      final obsRx = HarborUsbFsRx(name: 'obs_rx');
      obsRx.input('clk').srcConnection! <= clk;
      obsRx.input('reset').srcConnection! <= reset;
      obsRx.input('dp').srcConnection! <=
          mux(dut.output('oe'), dut.output('dp_out'), Const(1));
      obsRx.input('dn').srcConnection! <=
          mux(dut.output('oe'), dut.output('dm_out'), Const(0));

      await dut.build();
      await obsRx.build();

      reset.inject(1);
      dp.inject(1);
      dm.inject(0);
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      for (var i = 0; i < 30; i++) {
        await clk.nextPosedge;
      }

      final cmdBytes = <int>[];
      var cmdStartCount = 0;
      var ackCount = 0;

      Future<void> sample() async {
        final cv = dut.output('cmd_valid').value;
        if (cv.isValid && cv.toInt() == 1) {
          final cd = dut.output('cmd_data').value;
          expect(cd.isValid, isTrue, reason: 'cmd_data valid while offered');
          cmdBytes.add(cd.toInt());
        }
        final cs = dut.output('cmd_start').value;
        if (cs.isValid && cs.toInt() == 1) cmdStartCount++;
        final endVal = obsRx.output('pkt_end').value;
        if (endVal.isValid && endVal.toInt() == 1) {
          final pidVal = obsRx.output('pid').value;
          if (pidVal.isValid && pidVal.toInt() == 2) ackCount++;
        }
      }

      // One OUT transaction: the token, then the data packet. The wait
      // after it lets the endpoint drain, so the next packet is never
      // NAKed.
      Future<void> sendOut(int pidNibble, List<int> payload) async {
        final crc = _crc16(payload);
        final syms = <List<int>>[];
        syms.addAll(_encode([_pidByte(1), ..._tokenBytes(0, 1)]));
        syms.addAll([
          [1, 0],
          [1, 0],
        ]);
        syms.addAll(
          _encode([
            _pidByte(pidNibble),
            ...payload,
            crc & 0xFF,
            (crc >> 8) & 0xFF,
          ]),
        );
        for (final s in syms) {
          for (var t = 0; t < 4; t++) {
            dp.inject(s[0]);
            dm.inject(s[1]);
            await clk.nextPosedge;
            await sample();
          }
        }
        dp.inject(1);
        dm.inject(0);
        for (var i = 0; i < 900; i++) {
          await clk.nextPosedge;
          await sample();
        }
      }

      // Transfer 1: 72 bytes over three packets (32, 32, 8). The data
      // toggle alternates on every accepted packet.
      final pkt0 = List.generate(32, (i) => i);
      final pkt1 = List.generate(32, (i) => 32 + i);
      final pkt2 = List.generate(8, (i) => 64 + i);
      await sendOut(3, pkt0);
      await sendOut(11, pkt1);
      await sendOut(3, pkt2);

      // Transfer 2: one short packet. It follows a short packet, so it
      // starts a new command.
      final pkt3 = <int>[0xAA, 0xBB, 0xCC, 0xDD];
      await sendOut(11, pkt3);

      expect(ackCount, 4, reason: 'the device ACKs all four packets');
      expect(cmdBytes, [
        ...pkt0,
        ...pkt1,
        ...pkt2,
        ...pkt3,
      ], reason: 'every byte reaches the command stream in order');
      expect(
        cmdStartCount,
        2,
        reason: 'one pulse per transfer, not one per packet',
      );

      await Simulator.endSimulation();
    });
  });
}
