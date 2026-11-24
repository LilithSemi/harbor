// The grant goes through a register stage into each target request queue,
// so no combinational path goes from a master queue to a slave queue push.

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../port/memory_harness.dart';
import 'axi4_fabric_harness.dart';

/// The cycle of the first AR at the slave, counted from the first rise after
/// the master issues, in the fabric before the grant stage.
const _baseFirstAr = 3;

Iterable<Module> _tree(Module m) sync* {
  yield m;
  for (final s in m.subModules) {
    yield* _tree(s);
  }
}

Logic _internal(Module root, String name) => [
  for (final m in _tree(root)) ...m.signals,
].firstWhere((s) => s.name == name);

/// True when [to] is in the combinational fan out of [from]. A flop, or any
/// [Sequential], ends a path.
bool _combPath(Logic from, Set<Logic> to) {
  final seen = <Logic>{};
  final todo = [from];
  while (todo.isNotEmpty) {
    final s = todo.removeLast();
    if (!seen.add(s)) continue;
    if (to.contains(s)) return true;
    todo.addAll(s.dstConnections);
    final m = s.parentModule;
    if (s.isInput && m != null && m.subModules.isEmpty) {
      if (m is Sequential || m is FlipFlop) continue;
      todo.addAll(m.outputs.values);
    }
  }
  return false;
}

Burst _rd(int addr) =>
    Burst(id: 0, write: false, addr: addr, len: 0, size: 2, burst: 1);

void main() {
  tearDown(endAndReset);

  for (final t in HarborFabricTopology.values) {
    group(t.name, () {
      test(
        'no path from a master queue head to a slave request queue',
        () async {
          final shell = FabricShell(
            t,
            masters: const [MasterCfg('m0', 2, 4), MasterCfg('m1', 3, 8)],
          );
          await shell.build();
          for (final s in slaves3) {
            for (final d in ['aw', 'ar']) {
              final push = {
                _internal(shell.fabric, '${s.name}_${d}_push_fire'),
              };
              for (final m in ['m0', 'm1']) {
                must(
                  _combPath(
                    _internal(shell.fabric, '${m}_${d}_pop_valid'),
                    push,
                  ),
                  isFalse,
                  reason: '$m $d head to ${s.name}',
                );
                must(
                  _combPath(shell.input('${m}_${d.toUpperCase()}VALID'), push),
                  isFalse,
                  reason: '$m ${d.toUpperCase()}VALID to ${s.name}',
                );
              }
            }
          }
        },
      );

      test('ARs keep one per cycle, the first one cycle later', () async {
        final b = await Bench.start(
          t,
          stall: 0,
          masters: const [MasterCfg('m0', 2, 16)],
          slaves: const [SlaveCfg('s0', 4, 8, 0x00000, 0x10000)],
        );
        final m = b.managers['m0']!;
        var cycle = 0;
        final seen = <int>[];
        b.sim.onRise(() {
          cycle++;
          if (b.sim.pre('s0_ARVALID') == 1 && b.sim.pre('s0_ARREADY') == 1) {
            seen.add(cycle);
          }
        });
        for (var i = 0; i < 16; i++) {
          m.read(_rd(i * 4));
        }
        await b.drain(limit: 20000);
        await b.sim.stop();
        must(b.errors, isEmpty);
        must(seen.length, 16);
        must(seen.first, _baseFirstAr + 1);
        for (var i = 1; i < seen.length; i++) {
          must(seen[i], seen[i - 1] + 1, reason: 'AR $i');
        }
      });

      test('the AW is at the slave before the first W beat', () async {
        final b = await Bench.start(
          t,
          stall: 0,
          masters: const [MasterCfg('m0', 2, 4)],
          slaves: const [SlaveCfg('s0', 4, 4, 0x00000, 0x10000)],
        );
        final m = b.managers['m0']!;
        var cycle = 0;
        int? awAt;
        int? wAt;
        b.sim.onRise(() {
          cycle++;
          if (awAt == null && b.sim.pre('s0_AWVALID') == 1) awAt = cycle;
          if (wAt == null && b.sim.pre('s0_WVALID') == 1) wAt = cycle;
        });
        m.write(
          Burst(
            id: 0,
            write: true,
            addr: 0x40,
            len: 3,
            size: 2,
            burst: 1,
            data: [1, 2, 3, 4],
            strb: [0xf, 0xf, 0xf, 0xf],
          ),
        );
        await b.drain(limit: 20000);
        await b.sim.stop();
        must(b.errors, isEmpty);
        must(awAt, isNotNull);
        must(wAt, isNotNull);
        must(awAt! <= wAt!, isTrue, reason: 'AW at $awAt, W at $wAt');
      });
    });
  }
}
