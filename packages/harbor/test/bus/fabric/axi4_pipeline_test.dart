// Throughput and latency of each pipeline level of the AXI4 fabric.

import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

import '../port/memory_harness.dart';
import 'axi4_fabric_harness.dart';

// The cycle of the first AR at the slave, counted from the first rise after
// the master issues. With one slave the master has no input FIFO.
const _firstArOneSlave = {
  HarborFabricPipeline.compact: 4,
  HarborFabricPipeline.balanced: 6,
  HarborFabricPipeline.fast: 6,
};
const _firstArTwoSlaves = {
  HarborFabricPipeline.compact: 5,
  HarborFabricPipeline.balanced: 7,
  HarborFabricPipeline.fast: 7,
};

Burst _rd(int id, int addr) =>
    Burst(id: id, write: false, addr: addr, len: 0, size: 2, burst: 1);

// Issues [reads] from m0 and returns the cycles in which a slave took an
// AR, in order.
Future<List<int>> _arCycles(
  HarborFabricTopology t,
  HarborFabricPipeline p,
  List<SlaveCfg> slaves,
  List<Burst> reads,
) async {
  final b = await Bench.start(
    t,
    pipeline: p,
    stall: 0,
    masters: const [MasterCfg('m0', 2, 16)],
    slaves: slaves,
  );
  final m = b.managers['m0']!;
  var cycle = 0;
  final seen = <int>[];
  b.sim.onRise(() {
    cycle++;
    for (final s in slaves) {
      if (b.sim.pre('${s.name}_ARVALID') == 1 &&
          b.sim.pre('${s.name}_ARREADY') == 1) {
        seen.add(cycle);
      }
    }
  });
  for (final x in reads) {
    m.read(x);
  }
  await b.drain(limit: 20000);
  await b.sim.stop();
  must(b.errors, isEmpty);
  return seen;
}

Burst _wr(int id, int addr) => Burst(
  id: id,
  write: true,
  addr: addr,
  len: 0,
  size: 2,
  burst: 1,
  data: [addr * 3 + 1],
  strb: [0xf],
);

// Cycles from the R beat that frees a slot of outstanding 2 at the master
// to the next AR at the slave, with reads always waiting. The balanced
// level adds the grant register and the bubble of the eligibility flop.
const _slotReuse = {
  HarborFabricPipeline.compact: 2,
  HarborFabricPipeline.balanced: 4,
  HarborFabricPipeline.fast: 4,
};

void _consecutive(List<int> seen, int n) {
  must(seen.length, n);
  for (var i = 1; i < seen.length; i++) {
    must(seen[i], seen[i - 1] + 1, reason: 'AR $i');
  }
}

void main() {
  tearDown(endAndReset);

  for (final p in HarborFabricPipeline.values) {
    for (final t in HarborFabricTopology.values) {
      group('${p.name} ${t.name}', () {
        test('16 back to back ARs reach one slave on 16 cycles', () async {
          final seen = await _arCycles(
            t,
            p,
            const [SlaveCfg('s0', 4, 8, 0x00000, 0x10000)],
            [for (var i = 0; i < 16; i++) _rd(0, i * 4)],
          );
          _consecutive(seen, 16);
          must(seen.first, _firstArOneSlave[p]);
        });

        test('two IDs to two slaves issue every cycle', () async {
          final seen = await _arCycles(
            t,
            p,
            const [
              SlaveCfg('s0', 4, 8, 0x00000, 0x10000),
              SlaveCfg('s1', 4, 8, 0x10000, 0x10000),
            ],
            [
              for (var i = 0; i < 16; i++)
                _rd(i & 1, (i & 1) * 0x10000 + (i >> 1) * 4),
            ],
          );
          _consecutive(seen, 16);
          must(seen.first, _firstArTwoSlaves[p]);
        });

        test('outstanding 1 with reads and writes from two masters', () async {
          final b = await Bench.start(
            t,
            pipeline: p,
            stall: 0,
            masters: const [MasterCfg('m0', 2, 4), MasterCfg('m1', 2, 4)],
            slaves: const [SlaveCfg('s0', 4, 1, 0x00000, 0x10000)],
          );
          for (var i = 0; i < 12; i++) {
            b.managers['m0']!.read(_rd(i & 3, i * 4));
            b.managers['m1']!.write(_wr(i & 3, 0x100 + i * 4));
            b.managers['m0']!.write(_wr(i & 3, 0x200 + i * 4));
            b.managers['m1']!.read(_rd(i & 3, 0x300 + i * 4));
          }
          await b.drain(limit: 20000);
          await b.sim.stop();
          must(b.errors, isEmpty);
          final mem = b.memories['s0']!;
          must(mem.maxInflight, 1);
          must(mem.arOrder.length, 24);
          must(mem.awOrder.length, 24);
        });

        test(
          'a slave that takes nothing for 20 cycles loses nothing',
          () async {
            final b = await Bench.start(
              t,
              pipeline: p,
              stall: 0,
              masters: const [MasterCfg('m0', 2, 16)],
              slaves: const [SlaveCfg('s0', 4, 8, 0x00000, 0x10000)],
            );
            var cycle = 0;
            b.sim.onRise(() => cycle++);
            final mem = b.memories['s0']!;
            mem.ar.gate = () => cycle >= 20;
            final reads = [for (var i = 0; i < 12; i++) _rd(i & 3, i * 4)];
            for (final x in reads) {
              b.managers['m0']!.read(x);
            }
            await b.drain(limit: 20000);
            await b.sim.stop();
            must(b.errors, isEmpty);
            must(
              [for (final x in mem.arOrder) x.addr],
              [for (final x in reads) x.addr],
            );
          },
        );

        test('a freed slot of outstanding 2 is used again', () async {
          final b = await Bench.start(
            t,
            pipeline: p,
            stall: 0,
            masters: const [MasterCfg('m0', 2, 16)],
            slaves: const [SlaveCfg('s0', 4, 2, 0x00000, 0x10000)],
          );
          var cycle = 0;
          int? freed;
          final waits = <int>[];
          b.sim.onRise(() {
            cycle++;
            if (b.sim.pre('s0_ARVALID') == 1 && b.sim.pre('s0_ARREADY') == 1) {
              if (freed != null) waits.add(cycle - freed!);
              freed = null;
            }
            if (b.sim.pre('m0_RVALID') == 1 && b.sim.pre('m0_RREADY') == 1) {
              freed ??= cycle;
            }
          });
          for (var i = 0; i < 16; i++) {
            b.managers['m0']!.read(_rd(0, i * 4));
          }
          await b.drain(limit: 20000);
          await b.sim.stop();
          must(b.errors, isEmpty);
          must(b.memories['s0']!.maxInflight, 2);
          must(waits.length, greaterThanOrEqualTo(7));
          must(waits.toSet(), {_slotReuse[p]});
        });
      });
    }
  }
}
