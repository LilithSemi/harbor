import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import 'cdc_harness.dart';
import 'memory_harness.dart';

const _cfg = HarborMemoryWaistConfig(
  addressWidth: 16,
  dataWidth: 32,
  idWidth: 2,
  outstanding: 4,
);

/// A requester on clock a and a memory on clock b, linked through a memory
/// master port and a memory slave port that both cross to the fabric clock.
/// Each model resets while the port reset of its side is high.
class _Bench {
  final HarborFabricKind kind;
  final HarborMemoryWaistConfig config;
  final Random rng;
  final errors = <String>[];
  late final MultiSim ms;
  late final WaistRequester req;
  late final WaistMemory mem;
  late final BurstGen gen;

  _Bench(this.kind, Ratio ratio, int seed) : config = _cfg, rng = Random(seed) {
    ms = MultiSim(CdcMemLoop(config, kind), ratio);
    req = WaistRequester(ms.a, 'up', rng, errors: errors);
    mem = WaistMemory(
      ms.b,
      'mem',
      rng,
      outstanding: config.outstanding,
      busBytes: config.strbWidth,
      errors: errors,
    );
    gen = BurstGen(
      rng,
      busBytes: config.strbWidth,
      idWidth: config.idWidth,
      errors: 0.05,
      long: kind == HarborFabricKind.axi4 ? 0.02 : 0,
    );
    ms.a.onFall(() {
      if (ms.dut.output('a_reset_joined').value.toInt() == 1) req.reset();
    });
    ms.b.onFall(() {
      if (ms.dut.output('b_reset_joined').value.toInt() == 1) mem.reset();
    });
  }

  int get busBytes => config.strbWidth;

  Future<void> drain() =>
      settle(ms.a, () => req.done && req.req.idleNow && req.wdata.idleNow);

  /// Writes [count] bursts, then reads [count], and checks every response
  /// and the memory against its start state with the writes applied.
  Future<void> exact(int count) async {
    final start = WordMemory(busBytes)..words.addAll(mem.mem.words);
    req.reset();
    for (var i = 0; i < count; i++) {
      req.send(gen.next(write: true));
    }
    await drain();
    for (var i = 0; i < count; i++) {
      req.send(gen.next(write: false));
    }
    await drain();

    must(errors, isEmpty);
    must(
      diffPerId<Burst, (int, int)>(
        want: req.writes,
        got: req.writeResp,
        wantId: (x) => x.id,
        gotId: (r) => r.$1,
        matches: (x, r) => r.$2 == (x.addr >= 0xf000 ? 1 : 0),
      ),
      isEmpty,
    );
    final want = start;
    for (final x in req.writes) {
      if (x.addr >= 0xf000) continue;
      final addrs = beatAddrs(x.addr, x.len, x.size, x.burst);
      for (var i = 0; i < x.beats; i++) {
        want.write(addrs[i], x.data[i], x.strb[i]);
      }
    }
    final bad = <String>[];
    for (var k = 0; k < req.reads.length; k++) {
      final x = req.reads[k];
      final err = x.addr >= 0xf000 ? 1 : 0;
      final addrs = beatAddrs(x.addr, x.len, x.size, x.burst);
      final w = [
        for (var i = 0; i < x.beats; i++)
          (x.id, err == 1 ? 0 : want.read(addrs[i]), err, i == x.len ? 1 : 0),
      ];
      if (req.readResp[k].toString() != w.toString()) {
        bad.add('$x: got ${req.readResp[k]} want $w');
      }
    }
    must(bad, isEmpty);
    must(diffMemory(want, mem.mem), isEmpty);
  }

  /// Every request has its full response: one WRESP per write, and every
  /// beat of every read with LAST on the final one only.
  void complete() {
    must(errors, isEmpty);
    must(req.writeResp, hasLength(req.writes.length));
    final bad = <String>[];
    for (var k = 0; k < req.reads.length; k++) {
      final x = req.reads[k];
      final beats = req.readResp[k];
      final lasts = [for (final b in beats) b.$4];
      final want = [for (var i = 0; i < x.beats; i++) i == x.len ? 1 : 0];
      if (lasts.toString() != want.toString() ||
          beats.any((b) => b.$1 != x.id)) {
        bad.add('$x: got $beats');
      }
    }
    must(bad, isEmpty);
  }
}

Future<void> _random(HarborFabricKind kind, Ratio ratio, int seed) async {
  final b = _Bench(kind, ratio, seed);
  await b.ms.start();
  await b.exact(switch (kind) {
    HarborFabricKind.axi4 => 24,
    HarborFabricKind.tilelink => 14,
    HarborFabricKind.wishbone => 10,
  });
  await b.ms.stop();
}

/// Asserts [reset] in the middle of random traffic. Every request still in
/// the requester gets its full response, the memory sees only whole
/// bursts, and traffic after the reset is exact.
Future<void> _reset(
  HarborFabricKind kind,
  Ratio ratio,
  String reset,
  int seed,
) async {
  final b = _Bench(kind, ratio, seed);
  await b.ms.start();
  for (var i = 0; i < 16; i++) {
    b.req.send(b.gen.next(write: b.rng.nextBool()));
  }
  await b.ms.slow(12);
  await b.ms.pulse(reset, 6);
  await b.ms.slow(8);
  await b.drain();
  await settle(b.ms.b, () => b.mem.inflight == 0);
  b.complete();
  if (reset == 'reset_b') {
    must(
      b.req.writeResp.any((r) => r.$2 == 1) ||
          b.req.readResp.any((x) => x.any((beat) => beat.$3 == 1)),
      isTrue,
      reason: 'a device reset mid traffic fails some request',
    );
  }
  await b.exact(8);
  await b.ms.stop();
}

/// Asserts the device reset between fabric edges, at several offsets
/// before the edge that takes a last read beat or a write beat on the fabric
/// side. Every request still gets exactly one whole response.
Future<void> _resetBetweenEdges(HarborFabricKind kind, int seed) async {
  final b = _Bench(kind, ratios[1], seed);
  late final Module cdc;
  final reset = b.ms.dut.input('reset_b').srcConnection!;
  int at(String p) => (cdc.tryOutput(p) ?? cdc.input(p)).value.toInt();
  bool? read;
  var offset = 0;
  var fired = 0;
  // The inputs settle on the falling edge, so the handshake shown there
  // fires on the next rising edge, half a period later.
  b.ms.fabric.onFall(() {
    if (read == null) return;
    final hit = read!
        ? at('f_RDATA_VALID') == 1 &&
              at('f_RDATA_READY') == 1 &&
              at('f_RDATA_LAST') == 1
        : at('f_WDATA_VALID') == 1 && at('f_WDATA_READY') == 1;
    if (!hit) return;
    read = null;
    final t = Simulator.time + offset;
    Simulator.registerAction(t, () => reset.inject(1));
    Simulator.registerAction(t + 6 * ratios[1].b + 3, () {
      reset.inject(0);
      fired++;
    });
  });
  await b.ms.start();
  cdc = _find(b.ms.dut, 'HarborMemoryWaistCdcSlave');
  final half = ratios[1].fabric ~/ 2;
  for (final o in [1, half ~/ 2, half - 1]) {
    for (final r in [true, false]) {
      offset = o;
      for (var i = 0; i < 8; i++) {
        b.req.send(b.gen.next(write: !r));
      }
      final want = fired + 1;
      read = r;
      await settle(b.ms.fabric, () => fired == want);
      await b.ms.slow(8);
      await b.drain();
      await settle(b.ms.b, () => b.mem.inflight == 0);
      b.complete();
    }
  }
  await b.exact(8);
  await b.ms.stop();
}

Module _find(Module m, String prefix) =>
    _maybeFind(m, prefix) ?? (throw StateError('no $prefix under ${m.name}'));

Module? _maybeFind(Module m, String prefix) {
  if (m.definitionName.startsWith(prefix)) return m;
  for (final sub in m.subModules) {
    final hit = _maybeFind(sub, prefix);
    if (hit != null) return hit;
  }
  return null;
}

Future<void> _waitsForRequest() async {
  final b = _Bench(HarborFabricKind.axi4, ratios[1], 5);
  var open = false;
  b.mem.req.gate = () => open;
  await b.ms.start();
  final x = b.gen.next(write: true);
  b.req.send(x);
  // The data crosses long before the memory takes the request.
  await b.ms.b.cycles(60);
  must(b.errors, isEmpty);
  must(b.mem.writes, isEmpty);
  open = true;
  await b.drain();
  must(b.errors, isEmpty);
  must(b.req.writeResp, [(x.id, x.addr >= 0xf000 ? 1 : 0)]);
  await b.ms.stop();
}

/// A crossed AXI4 memory master port, with its AXI4 port on `bus_*`, its
/// device waist on `up_*` and its clocks on plain ports.
class _CrossedMaster extends BridgeModule {
  _CrossedMaster() : super('CdcTestCrossedMaster', name: 'top') {
    final dev = addSubModule(
      CdcMemDevice(_cfg, HarborFabricKind.axi4, slave: false, cross: true),
    );
    for (final p in ['clk', 'reset', 'fclk', 'freset']) {
      pullUpPort(dev.port(p), newPortName: p);
    }
    pullUpInterface(dev.interface('bus'), newIntfName: 'bus');
    pullUpInterface(dev.interface('up'), newIntfName: 'up');
  }
}

void main() {
  tearDown(endAndReset);

  for (final kind in HarborFabricKind.values) {
    group('${kind.name} memory crossing', () {
      for (var r = 0; r < ratios.length; r++) {
        final ratio = ratios[r];
        test(
          'random traffic at $ratio',
          () => isolated(() => _random(kind, ratio, 100 + r * 7 + kind.index)),
        );
      }

      test(
        'device reset between fabric edges answers each request once',
        () => isolated(() => _resetBetweenEdges(kind, 90 + kind.index)),
      );

      for (final (i, reset) in ['reset_a', 'reset_b', 'reset'].indexed) {
        test(
          '$reset mid traffic recovers',
          () => isolated(
            () => _reset(kind, ratios[i % ratios.length], reset, 40 + i),
          ),
        );
      }
    });
  }

  test(
    'write data waits for its request on the device side',
    () => isolated(_waitsForRequest),
  );

  test(
    'a read response with no read in flight never reaches the device',
    () async {
      final top = _CrossedMaster();
      final clk = SimpleClockGenerator(10).clk;
      for (final input in top.inputs.values) {
        if (input.name != 'clk' && input.name != 'fclk') {
          input.srcConnection!.put(0);
        }
      }
      top.input('clk').srcConnection! <= clk;
      top.input('fclk').srcConnection! <= clk;
      await top.build();
      void set(String p, int v) => top.input(p).srcConnection!.inject(v);
      set('reset', 1);
      set('freset', 1);
      var seen = false;
      var falls = 0;
      clk.negedge.listen((_) {
        falls++;
        if (falls == 4) {
          set('reset', 0);
          set('freset', 0);
        }
        if (falls == 20) {
          set('bus_RVALID', 1);
          set('bus_RDATA', 0x1234);
          set('bus_RLAST', 1);
        }
        if (falls == 21) set('bus_RVALID', 0);
        if (falls > 20 && top.output('up_RDATA_VALID').value.toBool()) {
          seen = true;
        }
      });
      Simulator.setMaxSimTime(1000);
      await Simulator.run();
      expect(seen, isFalse);
    },
  );

  test('a port on the fabric clock has no crossing', () async {
    for (final kind in HarborFabricKind.values) {
      final same = CdcMemLoop(_cfg, kind, cross: false);
      await same.build();
      expect(hasCrossing(same), isFalse, reason: kind.name);
    }
  });

  test('the crossing names carry the depth', () async {
    final top = CdcMemLoop(_cfg, HarborFabricKind.axi4);
    await top.build();
    final names = definitions(top);
    expect(names, contains('HarborMemoryWaistCdcSlave_a16_d32_i2_n4_q8'));
    expect(names, contains('HarborMemoryWaistCdcMaster_a16_d32_i2_n4_q8'));
    final deep = CdcMemLoop(_cfg, HarborFabricKind.axi4, depth: 16);
    await deep.build();
    expect(
      definitions(deep),
      contains('HarborMemoryWaistCdcSlave_a16_d32_i2_n4_q16'),
    );
  });
}
