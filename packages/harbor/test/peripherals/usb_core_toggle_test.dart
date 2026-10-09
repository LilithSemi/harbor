import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_core_harness.dart';

Module _findModule(Module m, String name) {
  if (m.name == name) return m;
  for (final sub in m.subModules) {
    try {
      return _findModule(sub, name);
    } on StateError {
      continue;
    }
  }
  throw StateError('no module $name');
}

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

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // EP1 OUT holds an undrained packet when SET_CONFIGURATION resets its
  // toggle. The drain then ends on the token cycle of the host's DATA0.
  test('a SET_CONFIGURATION toggle reset with an undrained EP1 OUT packet '
      'loses no data', () async {
    final (dut, host, clk, _, _) = await buildEp1Harness();
    final hold = dut.input('out_hold').srcConnection!;
    final outPe = _findModule(dut, 'fs_out_pe');
    final state = _find(outPe, 'ep_state_1');
    final tok = _find(outPe, 'out_token_received');

    final got = <int>[];
    dut.output('out_byte_valid').changed.listen((e) {
      if (e.newValue.isValid && e.newValue.toBool()) {
        final d = dut.output('out_byte_data').value;
        if (d.isValid) got.add(d.toInt());
      }
    });
    var cyc = 0;
    // The release cycle is the last cycle the endpoint holds a packet.
    var prevHeld = false;
    var prevTok = false;
    int? relAt;
    int? tokAt;
    var same = false;
    clk.negedge.listen((_) {
      cyc++;
      final held = state.value.isValid && state.value.toInt() == 2;
      if (prevHeld && !held) {
        relAt ??= cyc - 1;
        if (prevTok) same = true;
      }
      final t = _hi(tok);
      if (t) tokAt ??= cyc;
      prevHeld = held;
      prevTok = t;
    });

    const setCfg = [0x00, 0x09, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00];
    var off = 0;
    for (var iter = 0; iter < 16 && !same; iter++) {
      // A is DATA0, so the endpoint expects DATA1 until the reset.
      expect(await host.controlNoData(0, setCfg), isTrue);
      hold.inject(1);
      final a = 0x10 + iter;
      final b = 0x80 + iter;
      await host.sendToken(1, 0, 1);
      await host.idle(2);
      await host.sendData(3, [a]);
      expect((await host.waitPacket())?.pid, equals(2));
      await host.idle(50);
      expect(await host.controlNoData(0, setCfg), isTrue);
      await host.idle(20 + (iter & 1));

      relAt = null;
      tokAt = null;
      final start = cyc;
      final release = () async {
        for (var i = 0; i < off; i++) {
          await clk.nextPosedge;
        }
        hold.inject(0);
      }();
      int? hs;
      for (var tries = 0; tries < 10; tries++) {
        await host.sendToken(1, 0, 1);
        await host.idle(2);
        await host.sendData(3, [b]);
        hs = (await host.waitPacket())?.pid;
        if (hs == 2) break;
        expect(hs, equals(10), reason: 'NAK while A is held');
        await release;
        await host.idle(20);
      }
      await release;
      expect(hs, equals(2));
      await host.idle(100);
      expect(
        got.sublist(got.length - 2),
        equals([a, b]),
        reason: 'off $off: A then B reach the function',
      );

      if (same) break;
      final d = (tokAt ?? start) - (relAt ?? start);
      off += d == 0 ? 1 : d;
      if (off < 0) off = 0;
    }
    expect(same, isTrue, reason: 'the drain end met the token cycle');

    await Simulator.endSimulation();
  });
}
