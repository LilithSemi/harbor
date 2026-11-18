import 'dart:math';

import 'package:rohd/rohd.dart';

import 'bus.dart';
import 'port/reg_fifo.dart' show harborLoad;

/// Width that holds 0 to [maxValue].
int widthOf(int maxValue) => max(1, maxValue.bitLength);

/// Width that holds an index of [n] items.
int indexWidth(int n) => max(1, (n - 1).bitLength);

/// OR of [xs], or 0 when it is empty.
Logic anyOf(Iterable<Logic> xs) =>
    xs.isEmpty ? Const(0) : xs.reduce((a, b) => a | b);

/// The item whose bit is set in the one-hot [oh], or 0.
Logic pick(List<Logic> oh, List<Logic> items) {
  final w = items.first.width;
  Logic out = Const(0, width: w);
  for (var i = 0; i < items.length; i++) {
    out = out | (items[i] & oh[i].replicate(w));
  }
  return out;
}

/// The index of the set bit of the one-hot [oh].
Logic indexOf(List<Logic> oh, int width) =>
    pick(oh, [for (var i = 0; i < oh.length; i++) Const(i, width: width)]);

/// [idx] as [n] one-hot bits.
List<Logic> decodeIndex(Logic idx, int n) => [
  for (var i = 0; i < n; i++) idx.eq(Const(i, width: idx.width)),
];

/// The lowest set bit of [v], one-hot.
List<Logic> lowestOf(List<Logic> v) {
  final out = <Logic>[];
  Logic seen = Const(0);
  for (final b in v) {
    out.add(b & ~seen);
    seen = seen | b;
  }
  return out;
}

/// The highest set bit of [v], one-hot.
List<Logic> highestOf(List<Logic> v) =>
    lowestOf(v.reversed.toList()).reversed.toList();

/// The number of set bits in [bits].
Logic countOf(List<Logic> bits, int width) =>
    bits.map((b) => b.zeroExtend(width)).reduce((a, b) => a + b);

/// Round robin over [req]. The caller puts every condition of a transfer in
/// [req], so a grant is always taken and the pointer moves on each grant.
List<Logic> roundRobin(String name, Logic clk, Logic reset, List<Logic> req) {
  final n = req.length;
  if (n == 1) return req;
  final r = req.rconcat();
  final last = Logic(name: '${name}_rr', width: n);
  final masked = r & ~((last << 1) - 1);
  final pick = mux(masked.neq(0), masked, r);
  final g = (pick & (~pick + 1)).named('${name}_grant');
  Sequential(clk, reset: reset, [last < harborLoad(last, r.neq(0), g)]);
  return [for (var i = 0; i < n; i++) g[i]];
}

/// [req] with the requests of masters that are not real-time held back
/// while a real-time request is up. [rt] has one flag per request. With no
/// real-time flag it returns [req] unchanged.
List<Logic> realtimeFirst(List<Logic> req, List<bool> rt) {
  if (!rt.contains(true)) return req;
  final any = anyOf([
    for (var i = 0; i < req.length; i++)
      if (rt[i]) req[i],
  ]);
  return [for (var i = 0; i < req.length; i++) rt[i] ? req[i] : req[i] & ~any];
}

/// Simulation only: calls [check] at each rising edge of [clk] out of
/// [reset], and stops the simulation with the message it returns. The
/// generated RTL does not have it.
void harborSimWatch(Logic clk, Logic reset, String? Function() check) {
  clk.glitch.listen((args) {
    if (!LogicValue.isPosedge(
          args.previousValue,
          args.newValue,
          ignoreInvalid: true,
        ) ||
        reset.value != LogicValue.zero) {
      return;
    }
    final message = check();
    if (message != null) {
      Simulator.throwException(Exception(message), StackTrace.current);
    }
  });
}

/// The value of [l] as a bool, false when it has an unknown bit.
bool simHigh(Logic l) => l.value.isValid && l.value.toBigInt() != BigInt.zero;

/// The value of [l] as an int, 0 when it has an unknown bit.
int simInt(Logic l) => l.value.isValid ? l.value.toInt() : 0;

/// High when [addr] is in [range].
Logic inRange(Logic addr, BusAddressRange range) {
  final w = addr.width;
  final size = range.size;
  if (size & (size - 1) == 0 && range.start % size == 0) {
    final low = size.bitLength - 1;
    if (low >= w) return Const(1);
    return addr
        .getRange(low)
        .eq(Const(BigInt.from(range.start) >> low, width: w - low));
  }
  final lo = addr.gte(Const(BigInt.from(range.start), width: w));
  final end = BigInt.from(range.start) + BigInt.from(size);
  if (end >= BigInt.one << w) return lo;
  return lo & addr.lt(Const(end, width: w));
}

/// VALID to a slave that a cut off stops. A beat the slave already sees
/// stays until the slave takes it, as the handshake rules ask. No new beat
/// shows once [dead] is high.
Logic cutValid(
  String name,
  Logic clk,
  Logic reset,
  Logic valid,
  Logic ready,
  Logic dead,
) {
  if (dead is Const) return valid;
  final shown = Logic(name: '${name}_shown');
  final out = (valid & (~dead | shown)).named('${name}_valid');
  Sequential(clk, reset: reset, [shown < (out & ~ready)]);
  return out;
}
