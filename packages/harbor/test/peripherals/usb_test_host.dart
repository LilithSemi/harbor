import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';

// CRC5 for tokens (addr, endp fields).
int usbCrc5(int data, int nbits) {
  var crc = 0x1F;
  for (var i = 0; i < nbits; i++) {
    final bit = (data >> i) & 1;
    final xorIn = (crc & 1) ^ bit;
    crc >>= 1;
    if (xorIn != 0) crc ^= 0x14;
  }
  return (~crc) & 0x1F;
}

// CRC16 for data payloads.
int usbCrc16(List<int> bytes) {
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

// Token packet bytes (addr, endp with CRC5).
List<int> usbTokenBytes(int addr, int endp) {
  final field = (addr & 0x7F) | ((endp & 0xF) << 7);
  final v = field | (usbCrc5(field, 11) << 11);
  return [v & 0xFF, (v >> 8) & 0xFF];
}

// PID byte with complement nibble.
int usbPidByte(int nibble) => (nibble & 0xF) | ((~nibble & 0xF) << 4);

// Encodes bytes into line symbols [dp, dm] with SYNC, stuffing, NRZI, EOP.
List<List<int>> usbEncode(List<int> bytes) {
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

class UsbTestPacket {
  final int pid;
  final List<int> payload;

  UsbTestPacket({required this.pid, required this.payload});
}

class UsbTestHost {
  final Logic clk;
  final Logic reset;
  final Logic dp;
  final Logic dm;
  final Logic devOe;
  final Logic devDp;
  final Logic devDm;

  late HarborUsbFsRx _rx;
  final _rxBytes = <int>[];
  int _pktFirst = 0;

  // The last fully decoded packet, captured the instant it completes, by
  // whichever function is ticking the clock at the time (idle, drive, or
  // an explicit wait). A real host's receiver is always listening, so a
  // wait-for-packet call that starts only after a blind idle() must not
  // miss a reply that already finished during that idle, since pkt_end is
  // a one-cycle pulse, not a level.
  UsbTestPacket? _pendingPacket;

  UsbTestHost({
    required this.clk,
    required this.reset,
    required this.dp,
    required this.dm,
    required this.devOe,
    required this.devDp,
    required this.devDm,
  });

  Future<void> build() async {
    _rx = HarborUsbFsRx(name: 'usb_test_rx');
    _rx.input('clk').srcConnection! <= clk;
    _rx.input('reset').srcConnection! <= reset;
    _rx.input('dp').srcConnection! <= mux(devOe, devDp, Const(1));
    _rx.input('dn').srcConnection! <= mux(devOe, devDm, Const(0));
    await _rx.build();
  }

  Future<void> idle(int cycles) async {
    dp.inject(1);
    dm.inject(0);
    for (var i = 0; i < cycles; i++) {
      await clk.nextPosedge;
      await _sample();
    }
  }

  Future<void> sendToken(int pid, int addr, int endp) async {
    final syms = usbEncode([usbPidByte(pid), ...usbTokenBytes(addr, endp)]);
    await _driveSymbols(syms);
  }

  Future<void> sendData(int pid, List<int> bytes) async {
    final crc = usbCrc16(bytes);
    final all = [usbPidByte(pid), ...bytes, crc & 0xFF, (crc >> 8) & 0xFF];
    final syms = usbEncode(all);
    await _driveSymbols(syms);
  }

  Future<void> sendHandshake(int pid) async {
    final syms = usbEncode([usbPidByte(pid)]);
    await _driveSymbols(syms);
  }

  // A full-speed data packet runs 4 line cycles per bit, so a 64-byte
  // payload plus its PID and CRC16 takes about 2200 cycles to arrive.
  // The default leaves headroom above that. A packet already captured
  // by _sample during a preceding idle() or _driveSymbols() call is
  // returned first, so a reply already decoded is never missed.
  Future<UsbTestPacket?> waitPacket({int maxCycles = 3000}) =>
      _awaitPendingPacket(maxCycles);

  Future<UsbTestPacket?> _awaitPendingPacket(int maxCycles) async {
    if (_pendingPacket != null) {
      final p = _pendingPacket;
      _pendingPacket = null;
      return p;
    }
    for (var i = 0; i < maxCycles; i++) {
      await clk.nextPosedge;
      await _sample();
      if (_pendingPacket != null) {
        final p = _pendingPacket;
        _pendingPacket = null;
        return p;
      }
    }
    return null;
  }

  Future<List<int>?> controlRead(int addr, List<int> setup) async {
    // SETUP token and DATA0 packet.
    await sendToken(13, addr, 0);
    await _interPacketGap();
    await sendData(3, setup);
    if (!await _waitForSetupAck()) return null;

    final wLength = setup.length >= 8 ? setup[6] | (setup[7] << 8) : 0;

    final result = <int>[];
    var dataToggle = 1; // DATA1 for first IN response
    var retries = 0;
    const maxRetries = 200;

    while (retries < maxRetries) {
      // Send IN token.
      await sendToken(9, addr, 0);

      final pkt = await waitPacket();
      if (pkt == null || pkt.pid == 10) {
        // No response, or NAK: retry.
        retries++;
        await idle(50);
        continue;
      }
      if (pkt.pid == 14) return null; // STALL

      final expectedPid = dataToggle == 1 ? 11 : 3;
      if (pkt.pid != expectedPid) return null; // wrong data toggle

      result.addAll(pkt.payload);

      // ACK the data packet.
      await _interPacketGap();
      await sendHandshake(2);
      await idle(50);

      // Stop on a short packet or once wLength bytes arrived.
      if (pkt.payload.length < 64 || result.length >= wLength) break;
      dataToggle = 1 - dataToggle;
      retries = 0;
    }

    // Status: send OUT token with ZLP DATA1, then check the handshake.
    if (!await _waitStatusOut(addr)) return null;

    return result;
  }

  Future<bool> controlWrite(
    int addr,
    List<int> setup,
    List<int> data, {
    int maxPacket = 64,
  }) async {
    // SETUP token and DATA0.
    await sendToken(13, addr, 0);
    await _interPacketGap();
    await sendData(3, setup);
    if (!await _waitForSetupAck()) return false;

    // Send data packets.
    var offset = 0;
    var dataToggle = 1;
    while (offset < data.length) {
      final end =
          offset +
          (data.length - offset > maxPacket ? maxPacket : data.length - offset);
      final chunk = data.sublist(offset, end);
      final pid = dataToggle == 1 ? 11 : 3;

      var acked = false;
      var retries = 0;
      while (retries < 200) {
        // Resend the OUT token and the same DATA packet on every try.
        await sendToken(1, addr, 0);
        await _interPacketGap();
        await sendData(pid, chunk);

        final resp = await waitPacket();
        if (resp != null && resp.pid == 2) {
          acked = true;
          break;
        }
        if (resp != null && resp.pid == 14) return false; // STALL

        // No response, or NAK: retry.
        retries++;
        await idle(50);
      }
      if (!acked) return false;

      offset = end;
      dataToggle = 1 - dataToggle;
    }

    return _waitStatusIn(addr);
  }

  Future<bool> controlNoData(int addr, List<int> setup) async {
    // SETUP token and DATA0.
    await sendToken(13, addr, 0);
    await _interPacketGap();
    await sendData(3, setup);
    if (!await _waitForSetupAck()) return false;

    return _waitStatusIn(addr);
  }

  // USB 2.0 7.1.19.1: a host waits at least 18 bit times for a response
  // to start. A real host watches the line from the moment its own
  // packet ends, so this looks immediately rather than after a fixed
  // delay. The budget stays well above that spec minimum, since a SETUP
  // can land on a control endpoint still finishing an aborted data stage
  // or NAKed retries, so the ACK can arrive later than a bare wire
  // turnaround, though nowhere near what a full data packet needs.
  static const _handshakeTimeoutCycles = 500; // 125 bit times.

  Future<bool> _waitForSetupAck() async {
    final pkt = await _awaitPendingPacket(_handshakeTimeoutCycles);
    return pkt?.pid == 2;
  }

  // The IN status stage: send the IN token, wait for the device's
  // zero-length DATA1, then ACK it. Retries the IN on NAK.
  Future<bool> _waitStatusIn(int addr) async {
    var retries = 0;
    while (retries < 200) {
      await sendToken(9, addr, 0);

      final resp = await waitPacket();
      if (resp == null || resp.pid == 10) {
        retries++;
        await idle(50);
        continue;
      }
      if (resp.pid != 11) return false; // STALL, or not the expected ZLP

      await _interPacketGap();
      await sendHandshake(2);
      await idle(50);
      return true;
    }
    return false;
  }

  // The OUT status stage: send the OUT token and a zero-length DATA1,
  // then wait for the handshake. ACK means success. NAK resends the
  // OUT and the ZLP. STALL or a timeout fails outright.
  Future<bool> _waitStatusOut(int addr) async {
    var retries = 0;
    while (retries < 200) {
      await sendToken(1, addr, 0);
      await _interPacketGap();
      await sendData(11, []);

      final resp = await waitPacket();
      if (resp == null) return false; // timeout
      if (resp.pid == 2) return true; // ACK
      if (resp.pid == 10) {
        retries++;
        await idle(50);
        continue;
      }
      return false; // STALL
    }
    return false;
  }

  Future<void> _driveSymbols(List<List<int>> syms) async {
    // A packet captured but never claimed by a wait call is stale once
    // the host starts a new transmission: it was either a reply nobody
    // asked for, or a straggler that arrived after a previous wait timed
    // out. A real host's receiver would see it the same way once it
    // switches back to transmitting, so it does not carry forward into
    // a later, unrelated wait call.
    _pendingPacket = null;
    for (final s in syms) {
      for (var t = 0; t < 4; t++) {
        dp.inject(s[0]);
        dm.inject(s[1]);
        await clk.nextPosedge;
        await _sample();
      }
    }
  }

  Future<void> _interPacketGap() async {
    dp.inject(1);
    dm.inject(0);
    for (var i = 0; i < 2; i++) {
      await clk.nextPosedge;
    }
  }

  Future<void> _sample() async {
    final start = _rx.output('pkt_start').value;
    if (start.isValid && start.toInt() == 1) {
      _pktFirst = _rxBytes.length;
    }
    final put = _rx.output('rx_data_put').value;
    if (put.isValid && put.toInt() == 1) {
      final d = _rx.output('rx_data').value;
      if (d.isValid) _rxBytes.add(d.toInt());
    }
    final end = _rx.output('pkt_end').value;
    if (end.isValid && end.toInt() == 1) {
      final p = _rx.output('pid').value;
      if (p.isValid) {
        final pktPid = p.toInt();
        var payload = _rxBytes.sublist(_pktFirst);
        _rxBytes.clear();
        _pktFirst = 0;
        // DATA0/DATA1 carry a trailing CRC16 the caller never needs.
        if ((pktPid == 3 || pktPid == 11) && payload.length >= 2) {
          payload = payload.sublist(0, payload.length - 2);
        }
        _pendingPacket = UsbTestPacket(pid: pktPid, payload: payload);
      }
    }
  }
}
