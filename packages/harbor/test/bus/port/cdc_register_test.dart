import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

import 'cdc_harness.dart';
import 'memory_harness.dart' show endAndReset;
import 'port_harness.dart';

/// A register master on clock a and a register file on clock b, both behind
/// ports that cross to the fabric clock.
class _Bench {
  final MultiSim ms;
  late final StrobeMaster master;
  final Random rng;
  final model = [0, 0, 0, 0];

  _Bench(HarborFabricKind kind, Ratio ratio, int seed, {CdcRegLoop? loop})
    : ms = MultiSim(loop ?? CdcRegLoop(kind), ratio),
      rng = Random(seed) {
    master = StrobeMaster(
      ms.a,
      strobes: ['m_stb'],
      we: 'm_we',
      addr: 'm_addr',
      wdata: 'm_wdata',
      sel: 'm_sel',
      ack: 'm_ack',
      err: 'm_err',
      rdata: 'm_rdata',
    );
  }

  /// Runs [count] random accesses and checks each against [model].
  Future<void> exact(int count) async {
    final bad = <String>[];
    final runs = <Future<void>>[];
    for (var i = 0; i < count; i++) {
      final index = rng.nextInt(4);
      final write = rng.nextBool();
      final data = rng.nextInt(1 << 32);
      final sel = rng.nextInt(16);
      final isErr = index == errWord;
      int? want;
      if (!isErr) {
        if (write) {
          model[index] = mergeBytes(model[index], data, sel);
        } else {
          want = model[index];
        }
      }
      runs.add(
        master.access(write, index * 4, data: data, byteSel: sel).then((r) {
          final (rdata, ack, err) = r;
          if (ack != 1 || err != (isErr ? 1 : 0)) {
            bad.add('access $i to $index: ack $ack err $err');
          }
          if (want != null && rdata != want) {
            bad.add('read $i of $index: got $rdata want $want');
          }
        }),
      );
    }
    await Future.wait(runs);
    must(bad, isEmpty);
  }

  /// Writes every register, so [model] is known again after a reset.
  Future<void> rewrite() async {
    for (var i = 0; i < 4; i++) {
      if (i == errWord) continue;
      model[i] = rng.nextInt(1 << 32);
      await master.access(true, i * 4, data: model[i]);
    }
  }
}

/// Asserts [reset] while accesses run. Every access ends (an access the
/// requester reset drops ends with -1), and accesses after it are exact.
Future<void> _reset(
  HarborFabricKind kind,
  Ratio ratio,
  String reset,
  int seed,
) async {
  final b = _Bench(kind, ratio, seed);
  if (reset == 'reset_a') {
    b.ms.a.onFall(() {
      if (b.ms.dut.input('reset_a').srcConnection!.value.toInt() == 1) {
        b.master.abort();
      }
    });
  }
  await b.ms.start();
  final runs = [
    for (var i = 0; i < 20; i++)
      b.master.access(
        b.rng.nextBool(),
        b.rng.nextInt(4) * 4,
        data: b.rng.nextInt(1 << 32),
      ),
  ];
  await b.ms.slow(6);
  await b.ms.pulse(reset, 5);
  final results = await Future.wait(runs);
  if (reset == 'reset_a') {
    must(results, contains((-1, -1, -1)));
  } else {
    must(results.where((r) => r.$2 != 1), isEmpty);
  }
  await b.ms.slow(10);
  await b.rewrite();
  await b.exact(30);
  await b.ms.stop();
}

Future<void> _random(HarborFabricKind kind, Ratio ratio, int seed) async {
  final b = _Bench(kind, ratio, seed);
  await b.ms.start();
  await b.exact(60);
  await b.ms.stop();
}

/// A device without err resets while it holds an access. The native port
/// still fails the access: SLVERR for AXI4, denied for TileLink.
Future<void> _deviceResetFails(HarborFabricKind kind) async {
  final b = _Bench(
    kind,
    ratios[3],
    3,
    loop: CdcRegLoop(kind, waitStates: 15, fileErr: false),
  );
  var armed = false;
  b.ms.b.onRise(() {
    if (armed && b.ms.b.pre('dev_stb') == 1) {
      armed = false;
      unawaited(b.ms.pulse('reset_b', 4));
    }
  });
  await b.ms.start();
  for (final write in [true, false]) {
    armed = true;
    final (_, ack, err) = await b.master.access(write, 4, data: 0x1234);
    must((ack, err), (1, 1), reason: 'write $write');
    await b.ms.slow(10);
  }
  must((await b.master.access(true, 8, data: 0x55aa)).$3, 0);
  must(await b.master.access(false, 8), (0x55aa, 1, 0));
  await b.ms.stop();
}

/// An AXI4-Lite slave that holds READY low while the device side of a
/// register master port resets. AWVALID, WVALID and ARVALID and their
/// payloads stay up until READY.
Future<void> _axiHoldsThroughReset() async {
  final ms = MultiSim(CdcMasterShell(HarborFabricKind.axi4), ratios[1]);
  final master = StrobeMaster(
    ms.a,
    strobes: ['m_stb'],
    we: 'm_we',
    addr: 'm_addr',
    wdata: 'm_wdata',
    sel: 'm_sel',
    ack: 'm_ack',
    err: 'm_err',
    rdata: 'm_rdata',
  );
  ms.a.onFall(() {
    if (ms.dut.input('reset_a').srcConnection!.value.toInt() == 1) {
      master.abort();
    }
  });
  final s = ms.fabric;
  const channels = {
    'AW': ['bus_AWADDR'],
    'W': ['bus_WDATA', 'bus_WSTRB'],
    'AR': ['bus_ARADDR'],
  };
  final held = <String, List<int>>{};
  final bad = <String>[];
  var ready = false;
  var seen = 0;
  var aw = false;
  var w = false;
  var ar = false;
  var bOut = false;
  var rOut = false;
  var writes = 0;
  var reads = 0;
  s.onRise(() {
    for (final MapEntry(key: c, value: fields) in channels.entries) {
      final valid = s.pre('bus_${c}VALID');
      // X shows as -1, so a payload that goes X is a change.
      final payload = [
        for (final f in fields)
          ms.dut.tryOutput(f)!.previousValue!.isValid ? s.pre(f) : -1,
      ];
      final last = held.remove(c);
      if (last != null &&
          (valid != 1 || payload.toString() != last.toString())) {
        bad.add('$c dropped or changed before READY: $payload, was $last');
      }
      if (valid == 1) {
        seen++;
        if (s.pre('bus_${c}READY') == 0) held[c] = payload;
      }
    }
    if (s.pre('bus_AWVALID') == 1 && s.pre('bus_AWREADY') == 1) aw = true;
    if (s.pre('bus_WVALID') == 1 && s.pre('bus_WREADY') == 1) w = true;
    if (s.pre('bus_ARVALID') == 1 && s.pre('bus_ARREADY') == 1) ar = true;
    if (s.pre('bus_BVALID') == 1 && s.pre('bus_BREADY') == 1) bOut = false;
    if (s.pre('bus_RVALID') == 1 && s.pre('bus_RREADY') == 1) rOut = false;
    if (aw && w && !bOut) {
      (aw, w, bOut) = (false, false, true);
      writes++;
    }
    if (ar && !rOut) {
      (ar, rOut) = (false, true);
      reads++;
    }
  });
  s.onFall(() {
    s.set('bus_AWREADY', ready && !aw ? 1 : 0);
    s.set('bus_WREADY', ready && !w ? 1 : 0);
    s.set('bus_ARREADY', ready && !ar ? 1 : 0);
    s.set('bus_BVALID', bOut ? 1 : 0);
    s.set('bus_BRESP', 0);
    s.set('bus_RVALID', rOut ? 1 : 0);
    s.set('bus_RDATA', 0x600d);
    s.set('bus_RRESP', 0);
  });
  await ms.start();
  for (final write in [true, false]) {
    ready = false;
    seen = 0;
    final run = master.access(write, 0x40, data: 0xabcd, byteSel: 0x5);
    await settle(s, () => seen > 0);
    await ms.slow(2);
    await ms.pulse('reset_a', 4);
    await ms.slow(10);
    must(await run, (-1, -1, -1));
    must(bad, isEmpty);
    ready = true;
    await settle(s, () => (write ? writes : reads) == 1 && !bOut && !rOut);
  }
  ready = true;
  must(await master.access(false, 0x40), (0x600d, 1, 0));
  must(bad, isEmpty);
  must((writes, reads), (1, 2));
  await ms.stop();
}

void main() {
  tearDown(endAndReset);

  for (final kind in HarborFabricKind.values) {
    group('${kind.name} register crossing', () {
      for (var r = 0; r < ratios.length; r++) {
        final ratio = ratios[r];
        test(
          'random accesses at $ratio',
          () => isolated(() => _random(kind, ratio, 10 + r + kind.index * 5)),
        );
      }

      for (final (i, reset) in ['reset_a', 'reset_b', 'reset'].indexed) {
        test(
          '$reset mid traffic recovers',
          () => isolated(
            () => _reset(kind, ratios[(i + 1) % ratios.length], reset, 70 + i),
          ),
        );
      }
    });
  }

  for (final kind in [HarborFabricKind.axi4, HarborFabricKind.tilelink]) {
    test(
      '${kind.name} device reset fails the access without device err',
      () => isolated(() => _deviceResetFails(kind)),
    );
  }

  test(
    'axi4 master holds AW, W and AR through a device reset',
    () => isolated(_axiHoldsThroughReset),
  );

  test('a port on the fabric clock has no crossing', () async {
    for (final kind in HarborFabricKind.values) {
      final same = CdcRegLoop(kind, cross: false);
      await same.build();
      expect(hasCrossing(same), isFalse, reason: kind.name);
      final crossed = CdcRegLoop(kind);
      await crossed.build();
      expect(hasCrossing(crossed), isTrue, reason: kind.name);
    }
  });
}
