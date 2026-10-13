import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

import '../port/memory_harness.dart';
import 'axi4_fabric_harness.dart';

Burst _rd(int id, int addr, int len) =>
    Burst(id: id, write: false, addr: addr, len: len, size: 2, burst: 1);

Burst _wr(int id, int addr, int len) => Burst(
  id: id,
  write: true,
  addr: addr,
  len: len,
  size: 2,
  burst: 1,
  data: [for (var i = 0; i <= len; i++) (addr << 8) + i + id * 0x1000000],
  strb: List.filled(len + 1, 0xf),
);

// s0 gets a second read channel. m1 and m2 pin to it explicitly, so the
// default round robin keeps m0 on the channel no override claims (0).
// s0's ID width (5) already covers every master's own ID plus the 2 bit
// master index, so s0 never remaps: the ID a request arrives with at s0 is
// the exact full ID.
const _masters = [
  MasterCfg('m0', 2, 4),
  MasterCfg('m1', 3, 8, readChannel: 1),
  MasterCfg('m2', 1, 2, readChannel: 1),
];
const _slaves = [
  SlaveCfg('s0', 5, 8, 0x00000, 0x10000, readChannels: 2),
  SlaveCfg('s1', 1, 2, 0x10000, 0x10000),
  SlaveCfg('s2', 3, 4, 0x20000, 0x8000, timeout: 64),
];

/// The read channel each master in [_masters] uses at s0: an explicit
/// value pins it, and null spreads round robin over the channels no
/// override claims. Mirrors [HarborFabric.readChannelsOf].
List<int> _expectedChannel() {
  final claimed = {for (final m in _masters) ?m.readChannel};
  var free = [
    for (var c = 0; c < 2; c++)
      if (!claimed.contains(c)) c,
  ];
  if (free.isEmpty) free = [0, 1];
  var rank = 0;
  return [
    for (final m in _masters) m.readChannel ?? free[rank++ % free.length],
  ];
}

int _masterOf(int fullId) => fullId >> 3;

// Random traffic from every master at once, to a memory slave with 2 read
// channels plus a normal slave. Phase one mixes writes to each master's
// own page with reads of pages nobody writes. Phase two reads back the
// written pages, from every channel.
Future<void> _random(HarborFabricTopology topology, int seed) async {
  final b = await Bench.start(
    topology,
    seed: seed,
    masters: _masters,
    slaves: _slaves,
  );
  final rng = Random(seed * 31 + 7);
  Burst next(MasterCfg cfg, {required bool write}) => BurstGen(
    rng,
    busBytes: busBytes,
    idWidth: cfg.idWidth,
    span: 0x1000,
    long: 0.02,
  ).next(write: write);
  for (var k = 0; k < 70; k++) {
    for (var mi = 0; mi < _masters.length; mi++) {
      final cfg = _masters[mi];
      final write = rng.nextBool();
      final x = next(cfg, write: write);
      final s = _slaves[rng.nextInt(_slaves.length)];
      final base = s.base + (write ? mi : 4 + rng.nextInt(2)) * 0x1000;
      final y = moved(x, base);
      final m = b.managers[cfg.name]!;
      write ? m.write(y) : m.read(y);
    }
  }
  await b.drain();
  for (var k = 0; k < 35; k++) {
    for (final cfg in _masters) {
      final s = _slaves[rng.nextInt(_slaves.length)];
      final page = rng.nextInt(_masters.length);
      b.managers[cfg.name]!.read(
        moved(next(cfg, write: false), s.base + page * 0x1000),
      );
    }
  }
  await b.drain();
  await b.sim.stop();

  final golden = b.golden();
  final errors = [...b.errors];
  b.checkRegions();
  errors.addAll(b.errors);
  for (final cfg in _masters) {
    final m = b.managers[cfg.name]!;
    errors
      ..addAll(checkWrites(cfg.name, m.awOrder, m.bResp, b.respOf))
      ..addAll(
        checkReads(cfg.name, m.arOrder, m.rBeats, (x) {
          final resp = b.respOf(x);
          if (resp != 0) return (resp, null);
          return (
            0,
            [
              for (final a in beatAddrs(x.addr, x.len, x.size, x.burst))
                golden[b.slaveOf(x.addr)!].read(a),
            ],
          );
        }),
      );
  }
  for (var i = 0; i < _slaves.length; i++) {
    errors.addAll(diffMemory(golden[i], b.memories[_slaves[i].name]!.mem));
  }

  // Every read at s0 landed on the channel its master is assigned to.
  final expected = _expectedChannel();
  final s0Full = b.memories['s0']!;
  final s0Read = b.readMemories['s0']!.single;
  for (final x in s0Full.arOrder) {
    final mi = _masterOf(x.id);
    if (expected[mi] != 0) {
      errors.add(
        'm$mi read landed on s0 channel 0, want channel ${expected[mi]}',
      );
    }
  }
  for (final x in s0Read.arOrder) {
    final mi = _masterOf(x.id);
    if (expected[mi] != 1) {
      errors.add(
        'm$mi read landed on s0 channel 1, want channel ${expected[mi]}',
      );
    }
  }
  must(errors.take(20).toList(), isEmpty);
  must(s0Read.arOrder, isNotEmpty, reason: 's0 channel 1 saw no reads');
  for (final s in _slaves.where((s) => s.outstanding <= 4)) {
    must(
      b.memories[s.name]!.maxInflight,
      s.outstanding,
      reason: '${s.name} never reached its outstanding limit',
    );
  }
  must(b.busError(), 0);
}

// Two masters read from s0 at once, one on each channel: both reach their
// outstanding limit, and both make progress in overlapping cycles. A read
// issued by m2 after its own write's B comes back gets that write's data,
// even though m2's reads go to channel 1.
Future<void> _concurrencyAndOwnWrite(HarborFabricTopology t) async {
  final b = await Bench.start(t, masters: _masters, slaves: _slaves, stall: 0);
  final m0 = b.managers['m0']!;
  final m1 = b.managers['m1']!;
  final m2 = b.managers['m2']!;
  final ch0 = b.memories['s0']!;
  final ch1 = b.readMemories['s0']!.single;

  ch0.holdResponses = true;
  ch1.holdResponses = true;
  // m0 (channel 0 by default, since m1 and m2 claim 1) fills channel 0's shared
  // read+write counter with its own outstanding limit of 4 reads and 4
  // writes. m1 (channel 1, explicit) alone reaches channel 1's limit of 8
  // with reads, since its own outstanding is 8.
  for (var i = 0; i < 4; i++) {
    m0.read(_rd(0, 0x100 + i * 0x40, 0));
    m0.write(_wr(0, 0x1100 + i * 0x40, 0));
  }
  for (var i = 0; i < 8; i++) {
    m1.read(_rd(0, 0x200 + i * 0x40, 0));
  }
  await b.sim.cycles(400);
  must(ch0.maxInflight, 8, reason: 's0 channel 0 never reached its limit');
  must(ch1.maxInflight, 8, reason: 's0 channel 1 never reached its limit');

  final activeCh0 = <bool>[];
  final activeCh1 = <bool>[];
  b.sim.onRise(() {
    activeCh0.add(
      (b.sim.pre('s0_ARVALID') == 1 && b.sim.pre('s0_ARREADY') == 1) ||
          b.sim.pre('s0_RVALID') == 1,
    );
    activeCh1.add(
      (b.sim.pre('s0_r1_ARVALID') == 1 && b.sim.pre('s0_r1_ARREADY') == 1) ||
          b.sim.pre('s0_r1_RVALID') == 1,
    );
  });
  ch0.holdResponses = false;
  ch1.holdResponses = false;
  await b.drain();

  final overlap = [
    for (var i = 0; i < activeCh0.length; i++) i,
  ].any((i) => activeCh0[i] && activeCh1[i]);
  must(
    overlap,
    isTrue,
    reason:
        'both read channels should make progress in some of the same '
        'cycles',
  );

  // m2's reads always go to channel 1 (readChannel: 1). A read issued
  // after m2's own write settles must return that write's data.
  final write = _wr(1, 0x300, 0);
  m2.write(write);
  await waitUntil(b.sim, () => m2.bResp.isNotEmpty);
  m2.read(_rd(1, 0x300, 0));
  final before = ch1.arOrder.length;
  await waitUntil(b.sim, () => m2.rBeats.isNotEmpty);
  await b.sim.stop();

  must(
    ch1.arOrder.length,
    before + 1,
    reason: "m2's read did not land on channel 1",
  );
  final beat = m2.rBeats.last;
  must(beat.$1, 1);
  must(beat.$2, write.data.single);
  must(beat.$3, 0);
}

void main() {
  for (final topology in HarborFabricTopology.values) {
    for (final seed in [1, 2]) {
      test(
        '${topology.name} 2-channel random traffic, seed $seed',
        () => isolated(() => _random(topology, seed)),
        timeout: const Timeout(Duration(minutes: 10)),
      );
    }
    test(
      '${topology.name}: both read channels progress together and a '
      'channel 1 read sees its own write',
      () => isolated(() => _concurrencyAndOwnWrite(topology)),
    );
  }
}
