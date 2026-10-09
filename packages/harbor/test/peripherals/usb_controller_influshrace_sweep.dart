import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';
import 'usb_test_host.dart';

// The IN flush race sweep, shared by the race test files. Kept out of a
// _test.dart file so dart test runs those files in parallel.

const _inFlushOff = 0x38;

Logic _find(Module m, String name) {
  for (final s in m.signals) {
    if (s.name == name) return s;
  }
  for (final sub in m.subModules) {
    try {
      return _find(sub, name);
    } on StateError {
      continue;
    }
  }
  throw StateError('no signal $name');
}

bool _hi(Logic l) => l.value.isValid && l.value.toInt() != 0;

/// Arms packet A on EP1, then sweeps an IN_FLUSH write against the host's
/// IN transaction for A. The host ACKs the data when [ack] is set, and
/// otherwise sends an SOF in place of the handshake. Each iteration checks
/// that the flush leaves no IN-done for A, that the endpoint is unarmed,
/// and that packet B goes out with the right toggle.
Future<void> inFlushRaceSweep({required bool ack, int busPeriod = 20}) async {
  final (dut, host, clk, _, _) = await buildUsbControllerHarness(
    maxSimTime: 40000000,
    busPeriod: busPeriod,
  );
  final wait = _find(dut, 'in_flush_wait');
  final tok = _find(dut, 'in_token_received');
  final hs = _find(dut, ack ? 'ack_received' : 'rx_pkt_end');
  await dut.write(clk, ctrlAddr, 0x3);
  await dut.write(clk, epAddr(1, cfgOff), 0x05);

  var cyc = 0;
  int? reqAt;
  int? tokAt;
  int? hsAt;
  host.clk.negedge.listen((_) {
    cyc++;
    if (_hi(wait)) reqAt ??= cyc;
    if (_hi(tok)) tokAt ??= cyc;
    if (tokAt != null && cyc > tokAt! && _hi(hs)) hsAt ??= cyc;
  });

  var toggle = 3;
  final hit = <String>{};
  int? lastReq;
  int? lastTok;
  int? lastHs;

  Future<void> iterate(int off, int pad) async {
    final a = 0x40 + (off & 0x3F);
    await dut.write(clk, epAddr(1, inDataOff), a);
    await dut.write(clk, epAddr(1, inCommitOff), 1);
    await host.idle(20 + pad);
    reqAt = null;
    tokAt = null;
    hsAt = null;
    final w = () async {
      for (var i = 0; i < off; i++) {
        await host.clk.nextPosedge;
      }
      await dut.write(clk, epAddr(1, _inFlushOff), 1);
    }();
    await host.sendToken(9, 0, 1);
    final p = await host.waitPacket();
    final sent = p != null && (p.pid == 3 || p.pid == 11);
    if (sent) {
      expect(p.pid, equals(toggle), reason: 'off $off: A toggle');
      expect(p.payload, equals([a]), reason: 'off $off: A payload');
      await host.idle(2);
      if (ack) {
        await host.sendHandshake(2);
      } else {
        await host.sendToken(5, 0, 0);
      }
    } else {
      expect(p?.pid, equals(10), reason: 'off $off: A is NAKed');
    }
    await w;
    lastReq = reqAt;
    lastTok = tokAt;
    lastHs = hsAt;
    if (sent && ack) toggle ^= 8;
    if (lastReq != null && lastReq == lastTok) hit.add('token');
    if (lastReq != null && lastReq == lastHs) hit.add('handshake');

    expect(
      await dut.read(clk, intStatusAddr) & (1 << 17),
      equals(0),
      reason: 'off $off: no IN-done for A',
    );
    await host.idle(40);
    expect(await _inPid(host), equals(10), reason: 'off $off: unarmed');
    await host.idle(40);
    expect(
      await dut.read(clk, intStatusAddr) & (1 << 17),
      equals(0),
      reason: 'off $off: still no IN-done for A',
    );
    expect(await dut.read(clk, epAddr(1, inStatOff)), equals(0x1));

    await dut.write(clk, epAddr(1, inDataOff), 0xB0);
    await dut.write(clk, epAddr(1, inCommitOff), 1);
    await host.sendToken(9, 0, 1);
    final b = await host.waitPacket();
    expect(b?.pid, equals(toggle), reason: 'off $off: B toggle');
    expect(b!.payload, equals([0xB0]));
    await host.idle(2);
    await host.sendHandshake(2);
    toggle ^= 8;
    await host.idle(60);
    expect(
      await dut.read(clk, intStatusAddr) & (1 << 17),
      isNot(0),
      reason: 'off $off: IN-done for B',
    );
    await dut.write(clk, intStatusAddr, 1 << 17);
  }

  // Coarse sweep over the whole transaction. Each iteration that sees a
  // reference cycle gives a start offset for the aimed passes below.
  final start = <String, int>{};
  for (var off = 0; off < 520; off += 40) {
    await iterate(off, off & 1);
    if (lastReq == null) continue;
    if (lastTok != null) start['token'] ??= off + lastTok! - lastReq!;
    if (lastHs != null) start['handshake'] ??= off + lastHs! - lastReq!;
  }

  // Aim the flush request at the token cycle, then at the handshake.
  for (final target in ['token', 'handshake']) {
    var off = start[target] ?? 0;
    for (var i = 0; i < 16 && !hit.contains(target); i++) {
      await iterate(off < 0 ? 0 : off, i & 1);
      final ref = target == 'token' ? lastTok : lastHs;
      if (lastReq == null || ref == null) {
        off += 1;
        continue;
      }
      final d = ref - lastReq!;
      off += d == 0 ? 1 : d;
    }
  }
  expect(hit, containsAll(['token', 'handshake']));

  await Simulator.endSimulation();
}

Future<int?> _inPid(UsbTestHost host) async {
  await host.sendToken(9, 0, 1);
  return (await host.waitPacket())?.pid;
}
