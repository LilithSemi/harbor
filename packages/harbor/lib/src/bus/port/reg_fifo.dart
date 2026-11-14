import 'dart:async';
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

/// [d] when [load] is high, else [q], as plain logic. A register that takes
/// it as its next value has no flop enable, so it shares the control set of
/// the other flops on its clock and reset. A register of a few flops with
/// an enable of its own takes a slice for itself.
Logic harborLoad(Logic q, Logic load, Logic d) {
  final l = load.replicate(q.width);
  return (d & l) | (q & ~l);
}

/// A small FIFO built in the current module.
///
/// With [HarborRegFifo.bypassWhenEmpty] off (the default), [pushReady] and
/// [popValid] come only from registers, so the FIFO cuts every combinational
/// path between its two sides. Depth 2 passes one entry per cycle.
///
/// A FIFO of 2 or more entries and [ramBits] or more stored bits keeps its
/// entries in a RAM with one write port and an asynchronous read port, which
/// is distributed RAM on Xilinx and ECP5. The cycle timing does not change.
/// Each entry in flops has its own write enable, so it costs a control set
/// and a slice of flops for each 4 bits. A RAM32M holds 6 bits of up to 32
/// entries in 4 LUTs and needs no flops.
class HarborRegFifo {
  /// Stored bits from which an entry array of 2 or more entries is a RAM.
  static const ramBits = 8;

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

  final List<Logic>? _entries;

  /// Index of the entry at the head.
  final Logic readIndex;

  /// Index of the entry the next push writes.
  final Logic writeIndex;

  HarborRegFifo._(
    this.pushReady,
    this.popValid,
    this.popData,
    this.pushFire,
    this.popFire,
    this.count,
    this._entries,
    this.readIndex,
    this.writeIndex,
  );

  /// The entry registers, for logic that reads them in place. Only a FIFO
  /// built with `inPlace` has them.
  List<Logic> get entries =>
      _entries ??
      (throw StateError(
        'the entries of this FIFO are in a RAM; build it with inPlace',
      ));

  /// Builds a FIFO of [depth] entries of [pushData]'s width. An entry goes
  /// in when [pushValid] and [pushReady] are high, and out when [popValid]
  /// and [popReady] are high.
  ///
  /// [resetEntries] makes [popData] never X before the first push: flop
  /// entries reset, and RAM entries start at zero and take no write during
  /// reset. Turn it on only where that output feeds a port an external
  /// checker samples directly, such as an AXI4 output a BFM reads at the
  /// posedge.
  ///
  /// [bypassWhenEmpty] lets a push and a same-cycle pop of that same entry
  /// go through the FIFO while it is empty: [popValid] and [popData] follow
  /// [pushValid] and [pushData] for that one cycle, and the entry is not
  /// stored. Use it only where the other side can answer in the same cycle
  /// as its own request, so a push is never silently left unconsumed.
  ///
  /// [inPlace] keeps the entries in flops, so logic can read [entries].
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
    bool inPlace = false,
  }) {
    if (depth < 1) throw ArgumentError.value(depth, 'depth', 'must be >= 1');
    final width = pushData.width;
    final ptrWidth = max(1, (depth - 1).bitLength);
    final countWidth = depth.bitLength;
    final ram = !inPlace && depth >= 2 && width * depth >= ramBits;
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

    List<Logic>? entries;
    final Logic storedData;
    if (ram) {
      storedData = _FifoRam(
        name: '${name}_ram',
        clk: clk,
        wrEn: resetEntries ? pushFire & ~reset : pushFire,
        wrAddr: wr,
        wrData: pushData,
        rdAddr: rd,
        depth: depth,
        zeroInit: resetEntries,
      ).rdData;
    } else {
      final e = [
        for (var i = 0; i < depth; i++)
          Logic(name: '${name}_e$i', width: width),
      ];
      entries = e;
      var data = e[0];
      for (var i = 1; i < depth; i++) {
        data = harborBitMux(rd.eq(Const(i, width: ptrWidth)), e[i], data);
      }
      storedData = data;
      // resetEntries also resets the data registers, so popData is never X
      // before the first push. Off by default to save the reset fanout.
      // Entries under 4 bits take no flop enable.
      Sequential(clk, reset: resetEntries ? reset : null, [
        for (var i = 0; i < depth; i++)
          if (width < 4)
            e[i] <
                harborLoad(
                  e[i],
                  pushFire & wr.eq(Const(i, width: ptrWidth)),
                  pushData,
                )
          else
            If(
              pushFire & wr.eq(Const(i, width: ptrWidth)),
              then: [e[i] < pushData],
            ),
      ]);
    }
    final popData = bypassWhenEmpty
        ? harborBitMux(empty, pushData, storedData)
        : storedData;

    // The pointers and the count take no flop enable, so they share the
    // control set of the other flops on this clock and reset.
    Logic step(Logic p, Logic go) {
      final inc = p + go.zeroExtend(ptrWidth);
      if (depth == 1 << ptrWidth) return inc;
      final wrap = go & p.eq(Const(depth - 1, width: ptrWidth));
      return inc & ~wrap.replicate(ptrWidth);
    }

    Sequential(clk, reset: reset, [
      wr < step(wr, pushFire),
      rd < step(rd, popFire),
      count <
          count +
              pushFire.zeroExtend(countWidth) -
              popFire.zeroExtend(countWidth),
    ]);

    return HarborRegFifo._(
      pushReady,
      popValid,
      popData.named('${name}_pop_data'),
      pushFire,
      popFire,
      count,
      entries,
      rd,
      wr,
    );
  }
}

/// The entries of a [HarborRegFifo]: one write port and an asynchronous read
/// port on one clock. A write takes the values from before the clock edge,
/// as a flop does.
class _FifoRam extends Module with SystemVerilog {
  final int width;
  final int depth;
  final int addrWidth;
  final bool zeroInit;

  Logic get rdData => output('rd_data');

  _FifoRam({
    required String name,
    required Logic clk,
    required Logic wrEn,
    required Logic wrAddr,
    required Logic wrData,
    required Logic rdAddr,
    required this.depth,
    required this.zeroInit,
  }) : width = wrData.width,
       addrWidth = wrAddr.width,
       super(
         name: name,
         definitionName:
             'HarborRegFifoRam_${wrData.width}x$depth${zeroInit ? '_z' : ''}',
         reserveDefinitionName: true,
       ) {
    clk = addInput('clk', clk);
    wrEn = addInput('wr_en', wrEn);
    wrAddr = addInput('wr_addr', wrAddr, width: addrWidth);
    wrData = addInput('wr_data', wrData, width: width);
    rdAddr = addInput('rd_addr', rdAddr, width: addrWidth);
    final out = addOutput('rd_data', width: width);

    final unknown = LogicValue.filled(width, LogicValue.x);
    final cells = List<LogicValue>.filled(
      depth,
      zeroInit ? LogicValue.filled(width, LogicValue.zero) : unknown,
    );
    void read() {
      final a = rdAddr.value;
      out.put(a.isValid && a.toInt() < depth ? cells[a.toInt()] : unknown);
    }

    read();
    rdAddr.glitch.listen((_) => read());
    clk.posedge.listen((_) {
      final we = wrEn.previousValue ?? wrEn.value;
      // With zeroInit, an X enable writes nothing, as `if (wr_en)` does in
      // the SystemVerilog. The X comes from reset or a push valid that is
      // X before the first edges, and the entries must stay known.
      if (we == LogicValue.zero || (zeroInit && !we.isValid)) return;
      final wa = wrAddr.previousValue ?? wrAddr.value;
      if (we == LogicValue.one && wa.isValid && wa.toInt() < depth) {
        cells[wa.toInt()] = wrData.previousValue ?? wrData.value;
      } else {
        // An X enable or address can write any entry.
        cells.fillRange(0, depth, unknown);
      }
      // The read waits for clkStable, so a flop that samples rd_data at this
      // edge takes the value from before the edge. When the simulation
      // ends first, the stream has no element and no read is needed.
      unawaited(
        Simulator.clkStable.first
            .then((_) => read())
            .catchError((_) {}, test: (e) => e is StateError),
      );
    });
  }

  @override
  String? definitionVerilog(String definitionType) {
    final init = zeroInit
        ? "  initial for (int i = 0; i < $depth; i++) mem[i] = '0;\n"
        : '';
    return '''
module $definitionType (
  input logic clk,
  input logic wr_en,
  input logic [${addrWidth - 1}:0] wr_addr,
  input logic [${width - 1}:0] wr_data,
  input logic [${addrWidth - 1}:0] rd_addr,
  output logic [${width - 1}:0] rd_data
);
  logic [${width - 1}:0] mem [0:${depth - 1}];
$init  always_ff @(posedge clk) begin
    if (wr_en) mem[wr_addr] <= wr_data;
  end
  assign rd_data = mem[rd_addr];
endmodule''';
  }
}

/// Packs [fields] into one bus, first field in the low bits.
Logic harborPack(List<Logic> fields) => fields.rconcat();

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
