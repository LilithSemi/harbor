import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

import 'native_fabric_harness.dart';

/// Answered beats of each CYC a slave saw that came from more than one
/// master, by the address layout.
List<String> mixedSessions(WbBench b) => [
  for (final s in b.slaveCfgs)
    for (final x in b.memories[s.name]!.sessions)
      if ({
            for (final f in x)
              if (f['ERR'] != 1) wbOwner(s, f['ADR']!),
          }.length >
          1)
        '${s.name}: one CYC holds beats of two masters: $x',
];

// Random classic cycles and bursts from two burst masters and a classic
// master with no ERR, to two memory slaves and a classic register slave.
Future<void> _random(HarborFabricTopology t, int seed, int count) async {
  final b = await WbBench.start(t, seed: seed);
  for (var i = 0; i < count; i++) {
    for (var mi = 0; mi < b.masterCfgs.length; mi++) {
      b.send(mi, wbRandom(b, mi));
    }
  }
  await b.drain();
  await b.sim.stop();
  final errors = [...b.checkBeats(), ...b.checkMemories(), ...mixedSessions(b)];
  must(errors.take(20).toList(), isEmpty);
  must(b.busError(), 0);
}

void main() {
  const long = Timeout(Duration(minutes: 20));
  for (final t in HarborFabricTopology.values) {
    for (final seed in [1, 2]) {
      test(
        '${t.name} random traffic, seed $seed',
        () => isolated(() => _random(t, seed, 200)),
        timeout: long,
      );
    }
  }
}
