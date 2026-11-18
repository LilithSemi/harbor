// Real-time QoS on the TileLink fabric: a real-time message is granted
// before the messages of the other masters, and it waits for at most the
// message that holds the target plus the messages ahead of it at the slave.
// A message cannot be cut, so the cap does not apply.

import 'dart:collection';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../port/memory_harness.dart' show Sink, Source, WordMemory, waitUntil;
import '../port/port_harness.dart' show Sim;
import '../port/memory_native_harness.dart';
import 'native_fabric_harness.dart';

const _masters = [
  PortCfg('rt', width: 1, outstanding: 2, realtime: true),
  PortCfg('a', width: 2, outstanding: 4),
  PortCfg('b', width: 2, outstanding: 4),
];

const _slaves = [
  PortCfg('s0', width: 4, outstanding: 4, base: 0x00000, size: 0x8000),
  PortCfg('s1', width: 1, outstanding: 2, base: 0x10000, size: 0x8000),
];

const _masters3 = [
  PortCfg('r3', width: 1, outstanding: 2, realtime: true),
  PortCfg('r2', width: 1, outstanding: 2, realtime: true),
  PortCfg('rt', width: 1, outstanding: 2, realtime: true),
  PortCfg('a', width: 2, outstanding: 4),
];

// Beats of the largest message the others send: size 6 on a 4 byte bus.
const _largest = 16;

TlMsg _get(int size, int addr) => TlMsg(
  op: tlGet,
  size: size,
  addr: addr,
  mask: [laneMask(addr, size, busBytes)],
);

// An in order slave that answers Get with one D beat per cycle.
class _DetMem {
  final String p;
  final WordMemory mem = WordMemory(busBytes);
  final Queue<Map<String, int>> _beats = Queue();
  late final Source d;

  _DetMem(Sim s, this.p, Random rng) {
    Sink(
      s,
      '${p}_A_VALID',
      '${p}_A_READY',
      [
        for (final f in ['OPCODE', 'SIZE', 'SOURCE', 'ADDRESS']) '${p}_A_$f',
      ],
      rng,
      (f) {
        final size = f['${p}_A_SIZE']!;
        final addr = f['${p}_A_ADDRESS']!;
        for (var i = 0; i < tlBeats(size, busBytes); i++) {
          _beats.add({
            '${p}_D_OPCODE': tlAccessAckData,
            '${p}_D_PARAM': 0,
            '${p}_D_SIZE': size,
            '${p}_D_SOURCE': f['${p}_A_SOURCE']!,
            '${p}_D_SINK': 0,
            '${p}_D_DATA': mem.read(addr + i * busBytes),
            '${p}_D_DENIED': 0,
            '${p}_D_CORRUPT': 0,
          });
        }
      },
      latchOnFall: true,
    );
    d = Source(s, '${p}_D_VALID', '${p}_D_READY', rng);
    s.onFall(() {
      if (d.queue.isEmpty && _beats.isNotEmpty)
        d.queue.add(_beats.removeFirst());
    });
  }
}

Future<void> _timing(
  HarborFabricTopology t,
  List<PortCfg> masters,
  List<PortCfg> slaves,
) async {
  final shell = NativeShell(
    HarborFabricKind.tilelink,
    t,
    masters: masters,
    slaves: slaves,
  );
  final sim = Sim(shell);
  final rng = Random(2);
  final errors = <String>[];
  final mgr = {
    for (final m in masters)
      m.name: TlManager(
        sim,
        m.name,
        rng,
        sources: 1 << m.width,
        busBytes: busBytes,
        errors: errors,
        idle: 0,
        stall: 0,
      ),
  };
  for (final s in slaves) {
    _DetMem(sim, s.name, rng);
  }
  final others = [
    for (final (i, m) in masters.indexed)
      if (!m.realtime) (i, m.name),
  ];
  final extraRt = [
    for (final (i, m) in masters.indexed)
      if (m.realtime && m.name != 'rt') (i, m.name),
  ];
  final rtIndex = masters.indexWhere((m) => m.name == 'rt');
  final waits = <int>[];
  var now = 0;
  int? start;
  sim.onRise(() {
    now++;
    if (start == null && sim.pre('rt_A_VALID') == 1) start = now;
    if (start != null &&
        sim.pre('rt_D_VALID') == 1 &&
        sim.pre('rt_D_READY') == 1) {
      waits.add(now - start!);
      start = null;
    }
  });
  await sim.start();
  Simulator.setMaxSimTime(8000000);
  for (var i = 0; i < 30; i++) {
    for (final (mi, n) in others) {
      for (final s in slaves) {
        final l = TlLayout(s);
        mgr[n]!.send(_get(6, l.pageOf(mi) + (i % 2) * 0x40));
      }
    }
  }
  const reads = 24;
  for (var i = 0; i < reads; i++) {
    await sim.cycles(17 + (i * 5) % 13);
    final l = TlLayout(slaves[i % slaves.length]);
    for (final (mi, n) in extraRt) {
      mgr[n]!.send(_get(6, l.pageOf(mi) + 0x400));
    }
    final m = _get(4, l.pageOf(rtIndex) + (i % 8) * 0x10);
    mgr['rt']!.send(m);
    await waitUntil(sim, () => m.d.length == 4, limit: 5000);
  }
  await waitUntil(sim, () => mgr.values.every((m) => m.done), limit: 200000);
  await sim.stop();

  final bound = HarborFabric.realtimeWaitBound(
    kind: HarborFabricKind.tilelink,
    masters: [
      for (final m in masters)
        HarborFabricMaster(
          name: m.name,
          interface: TileLinkInterface(
            const TileLinkConfig(
              addressWidth: addrW,
              dataWidth: dataW,
              sizeWidth: 4,
            ),
          ),
          realtime: m.realtime,
          writeStallFree: true,
        ),
    ],
    cap: 16,
    slaveOutstanding: slaves.map((s) => s.outstanding).reduce(max),
    sharedSlaves: t == HarborFabricTopology.shared ? slaves.length : 1,
    realtimeBeats: extraRt.isEmpty ? 4 : 16,
    maxMessageBeats: _largest,
  );
  final worst = waits.reduce(max);
  // ignore: avoid_print
  print(
    'tilelink ${t.name} ${extraRt.length + 1} rt: worst wait $worst, '
    'bound $bound',
  );
  must(waits.length, reads);
  expect(worst, lessThanOrEqualTo(bound));
  must(errors, isEmpty);
}

Future<void> _data(HarborFabricTopology t) async {
  final b = await TlBench.start(
    t,
    masters: _masters,
    slaves: _slaves,
    seed: 6,
    stall: 0.2,
  );
  for (var i = 0; i < 25; i++) {
    for (var mi = 0; mi < 3; mi++) {
      final m = _masters[mi];
      b.send(m.name, tlRandom(b, m, mi));
    }
  }
  await b.drain(limit: 400000);
  await b.sim.stop();
  must([...b.errors, ...b.checkResponses(), ...b.checkMemories()], isEmpty);
}

void main() {
  tearDown(() async => Simulator.reset());

  for (final t in HarborFabricTopology.values) {
    test(
      'tilelink ${t.name}: the real-time wait stays under the bound',
      () async {
        await _timing(t, _masters, _slaves);
      },
    );
    test(
      'tilelink ${t.name}: three real-time masters stay under the bound',
      () async {
        await _timing(t, _masters3, const [
          PortCfg('s0', width: 4, outstanding: 1, base: 0x00000, size: 0x8000),
        ]);
      },
    );
    test('tilelink ${t.name}: real-time grants keep every message and '
        'memory word', () async {
      await _data(t);
    });
  }
}
