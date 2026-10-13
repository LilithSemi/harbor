import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

import '../port/memory_native_harness.dart';
import 'native_fabric_harness.dart';

// Random traffic from TL-UH and TL-UL masters to TL-UH and TL-UL slaves,
// with unmapped messages and messages a TL-UL slave cannot take.
Future<void> _random(HarborFabricTopology t, int seed, int count) async {
  final b = await TlBench.start(t, seed: seed);
  for (var i = 0; i < count; i++) {
    for (var mi = 0; mi < b.masterCfgs.length; mi++) {
      final m = b.masterCfgs[mi];
      b.send(m.name, tlRandom(b, m, mi));
    }
  }
  await b.drain();
  await b.sim.stop();

  final errors = [...b.errors, ...b.checkResponses(), ...b.checkMemories()];
  for (final s in b.slaveCfgs) {
    final mem = b.memories[s.name]!;
    if (mem.maxInflight > s.outstanding) {
      errors.add('${s.name}: ${mem.maxInflight} in flight');
    }
    if (!s.memory) {
      for (final x in mem.msgs) {
        if (!(x.op == tlGet || x.isPut) || x.size > 2) {
          errors.add('${s.name} is TL-UL and got $x');
        }
      }
    }
  }
  must(errors.take(20).toList(), isEmpty);
  must(b.memories['s1']!.maxInflight, 2);
  must(b.memories['s2']!.msgs, isNotEmpty);
  must(b.busError(), 0);
}

void main() {
  const long = Timeout(Duration(minutes: 20));
  for (final t in HarborFabricTopology.values) {
    for (final seed in [1, 2]) {
      test(
        '${t.name} random traffic, seed $seed',
        () => isolated(() => _random(t, seed, 400)),
        timeout: long,
      );
    }
  }
}
