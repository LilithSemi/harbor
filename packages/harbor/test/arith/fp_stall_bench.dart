import 'dart:async';
import 'dart:math';

import 'package:rohd/rohd.dart';

/// Runs [count] cases in order through a registered build in the ROHD
/// simulator. [put] drives case `i` on the ports, [putJunk] drives other
/// values. The enable [en] of all registers goes low on random cycles, and
/// junk is on the ports during those cycles.
///
/// Returns each output seen as `(case index, read())`, so a result that
/// changes in a stall is caught. Call after the module is built.
Future<List<(int, T)>> runWithStalls<T>({
  required Logic clk,
  required Logic en,
  required int latency,
  required int count,
  required void Function(int i) put,
  required void Function() putJunk,
  required T Function() read,
  required Random random,
}) async {
  final seen = <(int, T)>[];
  putJunk();
  en.put(0);
  unawaited(Simulator.run());
  var issued = 0;
  for (;;) {
    await clk.nextNegedge;
    final i = issued - latency;
    if (i >= 0) {
      seen.add((i, read()));
    }
    if (i >= count - 1) {
      break;
    }
    final go = random.nextInt(3) != 0;
    if (go && issued < count) {
      put(issued);
    } else {
      putJunk();
    }
    en.put(go ? 1 : 0);
    if (go) {
      issued++;
    }
  }
  await Simulator.endSimulation();
  return seen;
}

/// Checks that [seen] holds every case of [count] and that each output
/// matches [check]. Returns the number of stall cycles seen.
int checkStallRun<T>(
  List<(int, T)> seen,
  int count,
  void Function(int i, T got) check,
) {
  final indices = {for (final (i, _) in seen) i};
  if (indices.length != count) {
    throw StateError('${indices.length} of $count cases came out');
  }
  for (final (i, got) in seen) {
    check(i, got);
  }
  return seen.length - count;
}
