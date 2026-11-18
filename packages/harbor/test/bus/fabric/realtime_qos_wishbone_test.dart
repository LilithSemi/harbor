// Real-time QoS on the Wishbone fabric: a burst of another master ends at
// the cap while a real-time request waits, the wait stays under the bound,
// and every beat and memory word is right.

import 'dart:collection';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../port/memory_harness.dart';
import '../port/port_harness.dart';
import '../port/memory_native_harness.dart';
import 'axi4_fabric_harness.dart' show exposeInterface;
import 'native_fabric_harness.dart';
import 'wishbone_stage_harness.dart' show linkStage;
import 'wishbone_fabric_random_test.dart' show mixedSessions;

const _cap = 4;

const _masters = [PortCfg('rt', realtime: true), PortCfg('a'), PortCfg('b')];

const _masters2 = [
  PortCfg('rt', realtime: true),
  PortCfg('rt2', realtime: true),
  PortCfg('a'),
  PortCfg('b'),
];

const _slaves = [
  PortCfg('s0', base: 0x00000, size: 0x8000),
  PortCfg('s1', base: 0x10000, size: 0x8000),
];

WbTxn _rd(int addr, {int n = 1, bool burst = false}) => WbTxn(
  false,
  burst ? WbMode.burst : WbMode.classic,
  [for (var i = 0; i < n; i++) WbBeat(addr + i * busBytes, sel: 0xf)],
);

// What the slave saw of each cycle of the other masters: the beats it
// answered, and the beats answered when the real-time master began to wait.
class _Session {
  int beats = 0;
  int? beatsAtWait;
  bool cutEnd = false;
}

Future<void> _timing(
  HarborFabricTopology t, {
  List<PortCfg> masters = _masters,
  double keepCyc = 0,
  int? grantCap,
}) async {
  final rtN = masters.where((m) => m.realtime).length;
  final b = await WbBench.start(
    t,
    masters: masters,
    slaves: _slaves,
    gap: 0,
    keepCyc: keepCyc,
    wait: 0,
    maxGrantCycles: grantCap,
    realtimeBurstCap: _cap,
  );
  final sim = b.sim;
  final waits = <int>[];
  final sessions = <_Session>[];
  var now = 0;
  int? start;
  _Session? cur;
  var rtWaiting = false;
  sim.onRise(() {
    now++;
    final rtReq = sim.pre('rt_CYC') == 1 && sim.pre('rt_STB') == 1;
    final rtAck = sim.pre('rt_ACK') == 1;
    if (rtReq && start == null) start = now;
    rtWaiting = rtReq && !rtAck;
    if (rtReq && rtAck && start != null) {
      waits.add(now - start!);
      start = null;
    }
    final cyc = sim.pre('s0_CYC') == 1 && sim.pre('s0_STB') == 1;
    final owner = cyc ? ((sim.pre('s0_ADR') - 0) ~/ 0x800) : -1;
    if (cyc && owner >= rtN) {
      cur ??= _Session();
      if (rtWaiting) cur!.beatsAtWait ??= cur!.beats;
      if (sim.pre('s0_ACK') == 1) {
        cur!.beats++;
        if (sim.pre('s0_CTI') == 7) cur!.cutEnd = true;
      }
    }
    if (cur != null && sim.pre('s0_CYC') == 0) {
      sessions.add(cur!);
      cur = null;
    }
  });

  // The others run bursts of 8 beats on s0 first, with no real-time request.
  for (var i = 0; i < 6; i++) {
    b
      ..send(rtN, _rd(0x0800 * rtN + (i % 2) * 0x100, n: 8, burst: true))
      ..send(
        rtN + 1,
        _rd(0x0800 * (rtN + 1) + (i % 2) * 0x100, n: 8, burst: true),
      );
  }
  if (keepCyc == 0) {
    await waitUntil(sim, () => sessions.length >= 12, limit: 20000);
    final uncut = sessions.where((s) => s.beats == 8).length;
    expect(uncut, greaterThan(0), reason: 'no real-time request, no cut');
  }
  sessions.clear();

  for (var i = 0; i < 40; i++) {
    b
      ..send(rtN, _rd(0x0800 * rtN + (i % 4) * 0x100, n: 8, burst: true))
      ..send(
        rtN + 1,
        _rd(0x0800 * (rtN + 1) + (i % 4) * 0x100, n: 8, burst: true),
      );
  }
  const reads = 30;
  for (var i = 0; i < reads; i++) {
    await sim.cycles(13 + (i * 7) % 11);
    for (var k = 1; k < rtN; k++) {
      b.send(k, _rd(0x0800 * k + 0x400 + i * 4, n: 8, burst: true));
    }
    // With the grant cap on, a real-time master that holds the bus past the
    // cap loses it, and the others must still get it.
    b.send(
      0,
      grantCap == null || i.isOdd
          ? _rd(i.isEven ? 0x0100 + i * 4 : 0x10100 + i * 4)
          : _rd(0x0100, n: 24, burst: true),
    );
    final want = b.managers['rt']!.finished.length + 1;
    await waitUntil(
      sim,
      () => b.managers['rt']!.finished.length == want,
      limit: 5000,
    );
  }
  await b.drain(limit: 60000);
  await sim.stop();

  final bound = HarborFabric.realtimeWaitBound(
    kind: HarborFabricKind.wishbone,
    masters: [
      for (final m in masters)
        HarborFabricMaster(
          name: m.name,
          interface: WishboneInterface(
            const WishboneConfig(addressWidth: addrW, dataWidth: dataW),
          ),
          realtime: m.realtime,
          writeStallFree: true,
        ),
    ],
    cap: _cap,
    realtimeBeats: rtN > 1 ? 8 : _cap,
    wishboneGrantCap: grantCap,
  );
  final worst = waits.reduce(max);
  // ignore: avoid_print
  print('wishbone ${t.name}: worst wait $worst, bound $bound');
  if (grantCap == null) must(waits.length, reads);
  expect(worst, lessThanOrEqualTo(bound));
  var cuts = 0;
  for (final s in keepCyc == 0 ? sessions : <_Session>[]) {
    final k = s.beatsAtWait;
    if (k == null) continue;
    // Cut at the cap, or one beat after the real-time request came when
    // the burst was past the cap by then.
    expect(s.beats, lessThanOrEqualTo(max(_cap, k + 2)));
    if (s.beats < 8) cuts++;
  }
  if (keepCyc == 0) expect(cuts, greaterThan(0), reason: 'a burst was cut');
  must([...b.checkBeats(), ...b.checkMemories()], isEmpty);
}

const _memCfg = HarborMemoryWaistConfig(
  addressWidth: addrW,
  dataWidth: dataW,
  outstanding: 2,
);

// A real-time Wishbone port, and two Wishbone memory masters that run
// bursts, on a fabric to a Wishbone memory slave in front of a memory
// waist.
class _MemShell extends BridgeModule {
  _MemShell(
    HarborFabricTopology t, {
    int grantCap = harborDefaultWishboneGrantCap,
    bool stages = false,
  }) : super(
         'RtMemShell_${t.name}_g$grantCap${stages ? '_s' : ''}',
         name: 'shell',
       ) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final clk = input('clk');
    final reset = input('reset');
    final wcfg = harborWishboneMemoryConfig(_memCfg);
    final rt = WishboneInterface(wcfg);
    exposeInterface(this, rt, 'rt', PairDirection.fromProvider);
    final links = [WishboneInterface(wcfg), WishboneInterface(wcfg)];
    for (final (i, n) in ['ua', 'ub'].indexed) {
      final up = HarborMemoryWaist(_memCfg);
      HarborWishboneMemoryMaster(
        clk: clk,
        reset: reset,
        waist: up,
        wb: links[i],
      );
      exposeWaist(this, up, n, PairRole.consumer);
    }
    // With stages, each memory master sits behind a register stage.
    final fabricLinks = [
      for (final (i, l) in links.indexed)
        if (stages)
          () {
            final reg = WishboneRegisterStage(config: wcfg, name: 'stage$i');
            addSubModule(reg);
            reg.input('clk').srcConnection! <= clk;
            reg.input('reset').srcConnection! <= reset;
            final dn = WishboneInterface(wcfg);
            linkStage(this, reg, l, dn);
            return dn;
          }()
        else
          l,
    ];
    final slaveLink = WishboneInterface(wcfg);
    final down = HarborMemoryWaist(_memCfg);
    HarborWishboneMemorySlave(
      clk: clk,
      reset: reset,
      wb: slaveLink,
      waist: down,
    );
    exposeWaist(this, down, 'mem', PairRole.provider);
    HarborFabric.build(
      kind: HarborFabricKind.wishbone,
      topology: t,
      clk: clk,
      reset: reset,
      masters: [
        HarborFabricMaster(name: 'rt', interface: rt, realtime: true),
        HarborFabricMaster(name: 'a', interface: fabricLinks[0]),
        HarborFabricMaster(name: 'b', interface: fabricLinks[1]),
      ],
      slaves: [
        HarborFabricSlave(
          name: 's0',
          range: BusAddressRange(0, 0x10000),
          interface: slaveLink,
        ),
      ],
      realtimeBurstCap: _cap,
      maxGrantCycles: grantCap,
    );
  }
}

// A read-only waist memory whose first beat comes [_lat] cycles after the
// request is taken, then one beat per cycle.
const _lat = 20;

class _LatMem {
  final Sim s;
  final String p;
  final Queue<(int, Map<String, int>)> _beats = Queue();
  late final Source rdata;
  int now = 0;

  _LatMem(this.s, this.p, Random rng) {
    rdata = Source(s, '${p}_RDATA_VALID', '${p}_RDATA_READY', rng);
    Source(s, '${p}_WRESP_VALID', '${p}_WRESP_READY', rng);
    Sink(
      s,
      '${p}_WDATA_VALID',
      '${p}_WDATA_READY',
      ['${p}_WDATA_DATA'],
      rng,
      (_) => throw StateError('write data'),
    );
    s.onRise(() => now++);
    Sink(
      s,
      '${p}_REQ_VALID',
      '${p}_REQ_READY',
      ['${p}_REQ_ID', '${p}_REQ_WRITE', '${p}_REQ_ADDR', '${p}_REQ_LEN'],
      rng,
      (f) {
        if (f['${p}_REQ_WRITE'] == 1) throw StateError('write request');
        final len = f['${p}_REQ_LEN']!;
        final busy = _beats.isEmpty ? now : _beats.last.$1;
        final t0 = max(now + _lat, busy + 1);
        for (var i = 0; i <= len; i++) {
          _beats.add((
            t0 + i,
            {
              '${p}_RDATA_ID': f['${p}_REQ_ID']!,
              '${p}_RDATA_DATA': 0,
              '${p}_RDATA_ERR': 0,
              '${p}_RDATA_LAST': i == len ? 1 : 0,
            },
          ));
        }
      },
    );
    s.onFall(() {
      while (rdata.queue.isEmpty &&
          _beats.isNotEmpty &&
          _beats.first.$1 <= now) {
        rdata.queue.add(_beats.removeFirst().$2);
      }
    });
  }
}

// [latency]: a read-only memory that answers [_lat] cycles late, and the
// bound takes that as its access cycles. [failWrites]: every write fails at
// the memory, and each must come back with an error.
Future<void> _memory(
  HarborFabricTopology t, {
  bool latency = false,
  bool failWrites = false,
  bool stages = false,
}) async {
  final sim = Sim(_MemShell(t, stages: stages));
  final rng = Random(9);
  final errors = <String>[];
  final rt = WbMaster(sim, 'rt', rng, gap: 0, keepCyc: 0);
  final req = {
    for (final n in ['ua', 'ub'])
      n: WaistRequester(
        sim,
        n,
        rng,
        errors: errors,
        idle: failWrites ? 0.6 : 0,
        stall: 0,
      ),
  };
  if (latency) {
    _LatMem(sim, 'mem', rng);
  } else {
    WaistMemory(
      sim,
      'mem',
      rng,
      outstanding: 2,
      busBytes: busBytes,
      errors: errors,
      errBase: failWrites ? 0x2000 : 0xf000,
      perBeatErr: failWrites,
      errLine: failWrites ? 0x40 : null,
      stall: 0,
    );
  }
  final waits = <int>[];
  var now = 0;
  int? start;
  sim.onRise(() {
    now++;
    final rtReq = sim.pre('rt_CYC') == 1 && sim.pre('rt_STB') == 1;
    if (rtReq && start == null) start = now;
    if (rtReq && sim.pre('rt_ACK') == 1 && start != null) {
      waits.add(now - start!);
      start = null;
    }
  });
  await sim.start();
  Simulator.setMaxSimTime(8000000);
  for (var i = 0; i < 30; i++) {
    for (final (k, n) in ['ua', 'ub'].indexed) {
      final w = failWrites || (!latency && i.isOdd);
      req[n]!.send(
        Burst(
          id: 0,
          write: w,
          addr: 0x2000 + k * 0x1000 + (i % 4) * 0x40,
          len: 15,
          size: 2,
          burst: 1,
          data: w ? [for (var j = 0; j < 16; j++) i * 100 + j] : const [],
          strb: w ? List.filled(16, 0xf) : const [],
        ),
      );
    }
  }
  const reads = 24;
  for (var i = 0; i < reads; i++) {
    await sim.cycles(21 + (i * 7) % 17);
    rt.queue.add(_rd(0x100 + i * 4));
    final want = rt.finished.length + 1;
    await waitUntil(sim, () => rt.finished.length == want, limit: 5000);
  }
  await waitUntil(sim, () => req.values.every((r) => r.done), limit: 400000);
  await sim.stop();
  if (failWrites) {
    for (final e in req.entries) {
      final ok = e.value.writeResp.where((x) => x.$2 == 0).length;
      must(e.value.writeResp.length, 30);
      expect(ok, 0, reason: '${e.key}: a failed write came back with no error');
    }
    return;
  }
  final bound = HarborFabric.realtimeWaitBound(
    kind: HarborFabricKind.wishbone,
    masters: [
      for (final m in _masters)
        HarborFabricMaster(
          name: m.name,
          interface: WishboneInterface(
            const WishboneConfig(addressWidth: addrW, dataWidth: dataW),
          ),
          realtime: m.realtime,
          writeStallFree: true,
        ),
    ],
    cap: _cap,
    accessCycles: latency ? _lat + 2 : 4,
  );
  final worst = waits.reduce(max);
  // ignore: avoid_print
  print('wishbone memory ${t.name}: worst wait $worst, bound $bound');
  must(waits.length, reads);
  expect(worst, lessThanOrEqualTo(bound));
  must(errors, isEmpty);
}

Future<void> _data(HarborFabricTopology t) async {
  final b = await WbBench.start(
    t,
    masters: _masters,
    slaves: _slaves,
    seed: 4,
    realtimeBurstCap: _cap,
  );
  for (var i = 0; i < 25; i++) {
    for (var mi = 0; mi < 3; mi++) {
      b.send(mi, wbRandom(b, mi));
    }
  }
  await b.drain(limit: 100000);
  await b.sim.stop();
  must([...b.checkBeats(), ...b.checkMemories(), ...mixedSessions(b)], isEmpty);
}

void main() {
  tearDown(() async => Simulator.reset());

  for (final t in HarborFabricTopology.values) {
    test('wishbone ${t.name}: a burst ends at the cap while the real-time '
        'master waits', () async {
      await _timing(t);
    });
    test(
      'wishbone ${t.name}: memory masters and slave stay under the bound',
      () async {
        await _memory(t);
      },
    );
    test(
      'wishbone ${t.name}: a memory 20 cycles late stays under the bound',
      () async {
        await _memory(t, latency: true);
      },
    );
    test('wishbone ${t.name}: failed writes keep their error with a real-time '
        'master', () async {
      await _memory(t, failWrites: true);
    });
    test('wishbone ${t.name}: the default grant cap and the real-time preempt '
        'work together', () async {
      await _timing(
        t,
        masters: _masters2,
        grantCap: harborDefaultWishboneGrantCap,
      );
    });
    test('wishbone ${t.name}: failed writes keep their error behind register '
        'stages with the default cap', () async {
      await _memory(t, failWrites: true, stages: true);
    });
    test(
      'wishbone ${t.name}: two real-time masters stay under the bound',
      () async {
        await _timing(t, masters: _masters2);
      },
    );
    test(
      'wishbone ${t.name}: masters that hold CYC idle lose the grant',
      () async {
        await _timing(t, keepCyc: 1);
      },
    );
    test(
      'wishbone ${t.name}: cut bursts keep every beat and memory word',
      () async {
        await _data(t);
      },
    );
  }
}
