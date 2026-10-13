import 'dart:math';

import 'package:rohd/rohd.dart';

/// [d1] when [control] is 1, else [d0], with each bit kept apart.
///
/// A ROHD mux makes every bit X when one bit of the chosen input is X, so an
/// X data field in a packed entry would also hide its valid or error bits.
Logic harborBitMux(Logic control, Logic d1, Logic d0) {
  final out = Logic(width: d0.width);
  Combinational([
    If(control, then: [out < d1], orElse: [out < d0]),
  ]);
  return out;
}

/// A small register FIFO built in the current module.
///
/// With [HarborRegFifo.bypassWhenEmpty] off (the default), [pushReady] and
/// [popValid] come only from registers, so the FIFO cuts every combinational
/// path between its two sides. Depth 2 passes one entry per cycle.
class HarborRegFifo {
  /// Low when the FIFO is full.
  final Logic pushReady;

  /// High when the FIFO holds an entry.
  final Logic popValid;

  /// The oldest entry.
  final Logic popData;

  /// High in a cycle where an entry goes in.
  final Logic pushFire;

  /// High in a cycle where an entry goes out.
  final Logic popFire;

  /// Entries in the FIFO, `depth.bitLength` bits wide.
  final Logic count;

  HarborRegFifo._(
    this.pushReady,
    this.popValid,
    this.popData,
    this.pushFire,
    this.popFire,
    this.count,
  );

  /// Builds a FIFO of [depth] entries of [pushData]'s width. An entry goes
  /// in when [pushValid] and [pushReady] are high, and out when [popValid]
  /// and [popReady] are high.
  ///
  /// [resetEntries] also resets the data registers, so [popData] is never X
  /// before the first push. Turn it on only where that output feeds a port
  /// an external checker samples directly, such as an AXI4 output a BFM
  /// reads at the posedge.
  ///
  /// [bypassWhenEmpty] lets a push and a same-cycle pop of that same entry
  /// go through the FIFO while it is empty: [popValid] and [popData] follow
  /// [pushValid] and [pushData] for that one cycle, and the entry is not
  /// stored. Use it only where the other side can answer in the same cycle
  /// as its own request, so a push is never silently left unconsumed.
  factory HarborRegFifo({
    required String name,
    required Logic clk,
    required Logic reset,
    required int depth,
    required Logic pushValid,
    required Logic pushData,
    required Logic popReady,
    bool resetEntries = false,
    bool bypassWhenEmpty = false,
  }) {
    if (depth < 1) throw ArgumentError.value(depth, 'depth', 'must be >= 1');
    final width = pushData.width;
    final ptrWidth = max(1, (depth - 1).bitLength);
    final countWidth = depth.bitLength;
    final entries = [
      for (var i = 0; i < depth; i++) Logic(name: '${name}_e$i', width: width),
    ];
    final wr = Logic(name: '${name}_wr', width: ptrWidth);
    final rd = Logic(name: '${name}_rd', width: ptrWidth);
    final count = Logic(name: '${name}_count', width: countWidth);

    final pushReady = (~count.eq(
      Const(depth, width: countWidth),
    )).named('${name}_push_ready');
    final empty = count.eq(0);
    final pushFire = (pushValid & pushReady).named('${name}_push_fire');
    // With bypassWhenEmpty, a push into an empty FIFO is also visible to the
    // pop side in the same cycle, so the entry can go straight through.
    final popValid = (bypassWhenEmpty ? (empty & pushFire) | ~empty : ~empty)
        .named('${name}_pop_valid');
    final popFire = (popValid & popReady).named('${name}_pop_fire');

    var storedData = entries[0];
    for (var i = 1; i < depth; i++) {
      storedData = harborBitMux(
        rd.eq(Const(i, width: ptrWidth)),
        entries[i],
        storedData,
      );
    }
    final popData = bypassWhenEmpty
        ? harborBitMux(empty, pushData, storedData)
        : storedData;

    Logic next(Logic p) => depth == 1 << ptrWidth
        ? p + 1
        : mux(
            p.eq(Const(depth - 1, width: ptrWidth)),
            Const(0, width: ptrWidth),
            p + 1,
          );

    Sequential(clk, reset: reset, [
      If(pushFire, then: [wr < next(wr)]),
      If(popFire, then: [rd < next(rd)]),
      If.block([
        Iff(pushFire & ~popFire, [count < count + 1]),
        ElseIf(popFire & ~pushFire, [count < count - 1]),
      ]),
    ]);

    // resetEntries also resets the data registers, so popData is never X
    // before the first push. Off by default to save the reset fanout.
    Sequential(clk, reset: resetEntries ? reset : null, [
      for (var i = 0; i < depth; i++)
        If(
          pushFire & wr.eq(Const(i, width: ptrWidth)),
          then: [entries[i] < pushData],
        ),
    ]);

    return HarborRegFifo._(
      pushReady,
      popValid,
      popData.named('${name}_pop_data'),
      pushFire,
      popFire,
      count,
    );
  }
}

/// Packs [fields] into one bus, first field in the low bits.
Logic harborPack(List<Logic> fields) => fields.rswizzle();

/// Splits [bus] back into fields of [widths], first field in the low bits.
List<Logic> harborUnpack(Logic bus, List<int> widths) {
  final out = <Logic>[];
  var lo = 0;
  for (final w in widths) {
    out.add(bus.getRange(lo, lo + w));
    lo += w;
  }
  return out;
}

/// Byte lanes a beat of `2^size` bytes at [addr] covers on a bus of
/// [strbWidth] bytes. A size of the bus width or more covers every lane.
Logic harborLaneMask(Logic addr, Logic size, int strbWidth) {
  final busSize = strbWidth.bitLength - 1;
  if (busSize == 0) return Const(1);
  final low = addr.width >= busSize
      ? addr.getRange(0, busSize)
      : addr.zeroExtend(busSize);
  Logic out = Const(1, width: strbWidth, fill: true);
  for (var s = busSize - 1; s >= 0; s--) {
    final bytes = 1 << s;
    final base = low & Const(~(bytes - 1) & (strbWidth - 1), width: busSize);
    out = mux(
      size.eq(Const(s, width: size.width)),
      Const((BigInt.one << bytes) - BigInt.one, width: strbWidth) << base,
      out,
    );
  }
  return out;
}
