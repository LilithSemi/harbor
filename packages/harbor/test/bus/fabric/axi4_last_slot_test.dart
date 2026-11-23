// The last free slot of a target goes to a registered direction. On a target
// with no real-time master, a request in the other direction waits one cycle
// for its turn, so no combinational path goes from one direction's requests
// to the other direction's grant.

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../port/memory_harness.dart';
import 'axi4_fabric_harness.dart';

Burst _wr(int addr) => Burst(
  id: 0,
  write: true,
  addr: addr,
  len: 0,
  size: 2,
  burst: 1,
  data: [addr],
  strb: [0xf],
);

Burst _rd(int addr) =>
    Burst(id: 0, write: false, addr: addr, len: 0, size: 2, burst: 1);

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

/// The push of the request FIFO of [slave] in direction [d].
Logic _push(Module fabric, String slave, String d) =>
    _internal(fabric, '${slave}_${d}_push_fire');

String _sv(Module m) => [
  for (final f in SynthBuilder(
    m,
    SystemVerilogSynthesizer(),
  ).getSynthFileContents())
    f.contents,
].join('\n');

// FNV-1a over the code units of the SV, and its length.
(int, int) _hash(String s) {
  var h = 0xcbf29ce484222325;
  for (final c in s.codeUnits) {
    h = (h ^ c) * 0x100000001b3;
  }
  return (h, s.length);
}

// The SV of fabrics where every target is real-time, built by the tree before
// the registered last slot direction (commit 9707fd9c).
const _realtimeGolden = {
  HarborFabricTopology.shared: (-6565777653522790195, 710099),
  HarborFabricTopology.crossbar: (-9161587348457697530, 728450),
};

void main() {
  tearDown(endAndReset);

  for (final t in HarborFabricTopology.values) {
    group(t.name, () {
      test('a flood of AW and AR takes turns at the last slot', () async {
        final b = await Bench.start(
          t,
          stall: 0,
          masters: const [MasterCfg('ma', 2, 8), MasterCfg('mb', 2, 8)],
          slaves: const [SlaveCfg('s0', 4, 2, 0x00000, 0x10000)],
        );
        final inflight = _internal(b.sim.dut, 's0_inflight');
        final fires = <String>[];
        final waits = {'aw': 0, 'ar': 0};
        var longest = 0;
        var contested = 0;
        b.sim.onRise(() {
          if (inflight.previousValue!.toInt() != 1) return;
          final want = {
            'aw': b.sim.pre('ma_AWVALID') == 1,
            'ar': b.sim.pre('mb_ARVALID') == 1,
          };
          final fire = {
            'aw': want['aw']! && b.sim.pre('ma_AWREADY') == 1,
            'ar': want['ar']! && b.sim.pre('mb_ARREADY') == 1,
          };
          if (want['aw']! && want['ar']!) {
            contested++;
            for (final d in ['aw', 'ar']) {
              if (fire[d]!) fires.add(d);
            }
          }
          for (final d in ['aw', 'ar']) {
            waits[d] = fire[d]! || !want[d]! ? 0 : waits[d]! + 1;
            longest = longest > waits[d]! ? longest : waits[d]!;
          }
        });
        for (var i = 0; i < 200; i++) {
          b.managers['ma']!.write(_wr(i * 4));
          b.managers['mb']!.read(_rd(0x800 + i * 4));
        }
        await b.drain(limit: 20000);
        await b.sim.stop();
        must(b.errors, isEmpty);
        must(contested, greaterThan(50));
        for (var i = 1; i < fires.length; i++) {
          must(fires[i], isNot(fires[i - 1]), reason: 'fire $i');
        }
        must(longest, lessThanOrEqualTo(2));
      });

      test('a lone AW after an AR waits 1 cycle, a stream waits 0', () async {
        final b = await Bench.start(
          t,
          stall: 0,
          masters: const [MasterCfg('m0', 2, 8)],
          slaves: const [SlaveCfg('s0', 4, 1, 0x00000, 0x10000)],
        );
        final m = b.managers['m0']!;
        final awWaits = <int>[];
        var waiting = 0;
        b.sim.onRise(() {
          if (b.sim.pre('m0_AWVALID') != 1) return;
          if (b.sim.pre('m0_AWREADY') == 1) {
            awWaits.add(waiting);
            waiting = 0;
          } else {
            waiting++;
          }
        });
        m.read(_rd(0x100));
        await waitUntil(b.sim, () => m.rBeats.length == 1);
        for (var i = 0; i < 4; i++) {
          m.write(_wr(i * 4));
          await waitUntil(b.sim, () => m.bResp.length == i + 1);
        }
        await b.sim.stop();
        must(b.errors, isEmpty);
        must(awWaits, [1, 0, 0, 0]);
      });

      test('no path from one direction to the other without a real-time '
          'master', () async {
        final shell = FabricShell(
          t,
          masters: const [MasterCfg('m0', 2, 4), MasterCfg('m1', 3, 8)],
        );
        await shell.build();
        for (final s in slaves3) {
          for (final (from, to) in [('AW', 'ar'), ('AR', 'aw')]) {
            final targets = {_push(shell.fabric, s.name, to)};
            for (final m in ['m0', 'm1']) {
              must(
                _combPath(shell.input('${m}_${from}VALID'), targets),
                isFalse,
                reason: '${m}_${from}VALID to ${s.name} $to',
              );
            }
          }
        }
      });

      // In the shared topology one AR arbiter serves every target, so a
      // path into the real-time target s0 or the error target goes on to
      // the AR grant of every target. The crossbar keeps it on s0.
      test('the path stays on a real-time target only', () async {
        final shell = FabricShell(
          t,
          masters: const [
            MasterCfg('rt', 2, 4, realtime: true, reach: {'s0'}),
            MasterCfg('m1', 3, 8),
          ],
        );
        await shell.build();
        for (final s in slaves3) {
          final path = _combPath(shell.input('m1_AWVALID'), {
            _push(shell.fabric, s.name, 'ar'),
          });
          if (s.name == 's0' || t == HarborFabricTopology.crossbar) {
            must(path, s.name == 's0', reason: s.name);
          }
        }
      });

      test('a real-time target has the SV from before', () async {
        final shell = FabricShell(
          t,
          masters: const [
            MasterCfg('m0', 2, 4, realtime: true),
            MasterCfg('m1', 3, 8),
          ],
        );
        await shell.build();
        must(_hash(_sv(shell)), _realtimeGolden[t]);
      });
    });
  }
}
