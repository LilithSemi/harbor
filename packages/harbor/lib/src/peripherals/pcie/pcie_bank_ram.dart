import 'dart:async';

import 'package:rohd/rohd.dart';

/// A simple dual port RAM with a registered read, as `HarborBram`.
///
/// The simulation body is a Dart list, because a flop array of this depth
/// is slow in the simulator. Synthesis uses the same inferred RAM template
/// as `HarborBram`. A read and a write of one address in one cycle read
/// the old data.
class HarborPcieBankRam extends Module with SystemVerilog {
  final int width;
  final int depth;
  final int addrWidth;

  Logic get rdData => output('rd_data');

  HarborPcieBankRam(
    Logic clk, {
    required this.width,
    required this.depth,
    required Logic wrEn,
    required Logic wrAddr,
    required Logic wrData,
    required Logic rdAddr,
    super.name,
  }) : addrWidth = (depth - 1).bitLength.clamp(1, 32),
       super(
         definitionName: 'HarborPcieBankRam_${width}x$depth',
         reserveDefinitionName: true,
       ) {
    clk = addInput('clk', clk);
    wrEn = addInput('wr_en', wrEn);
    wrAddr = addInput('wr_addr', wrAddr, width: addrWidth);
    wrData = addInput('wr_data', wrData, width: width);
    rdAddr = addInput('rd_addr', rdAddr, width: addrWidth);
    final reg = Logic(name: 'rd_reg', width: width);
    addOutput('rd_data', width: width) <= reg;

    final unknown = LogicValue.filled(width, LogicValue.x);
    final cells = List<LogicValue>.filled(depth, unknown);
    reg.put(unknown);
    // Inputs are sampled at the clock edge. The read data changes when the
    // flops change, so other flops see it in the next cycle.
    clk.glitch.listen((event) {
      if (event.previousValue != LogicValue.zero ||
          event.newValue != LogicValue.one) {
        return;
      }
      final ra = rdAddr.value;
      final read = ra.isValid && ra.toInt() < depth
          ? cells[ra.toInt()]
          : unknown;
      final we = wrEn.value;
      if (we.isValid && we.toBool()) {
        final wa = wrAddr.value;
        if (!wa.isValid) {
          throw StateError('$name: write address is not valid');
        }
        if (wa.toInt() < depth) cells[wa.toInt()] = wrData.value;
      }
      unawaited(Simulator.clkStable.first.then((_) => reg.put(read)));
    });
  }

  @override
  String? definitionVerilog(String definitionType) =>
      '''
module $definitionType (
  input logic clk,
  input logic wr_en,
  input logic [${addrWidth - 1}:0] wr_addr,
  input logic [${width - 1}:0] wr_data,
  input logic [${addrWidth - 1}:0] rd_addr,
  output logic [${width - 1}:0] rd_data
);
  logic [${width - 1}:0] mem [0:${depth - 1}];
  always_ff @(posedge clk) begin
    if (wr_en) mem[wr_addr] <= wr_data;
    rd_data <= mem[rd_addr];
  end
endmodule''';
}

/// A buffer of 32-bit entries in [banks] RAM banks. Entry j is word
/// j / [banks] of bank j mod [banks].
///
/// A write puts `wrCount` entries of `wrLanes` at entry `wrStart` and up.
/// A read gives in [window] the [banks] entries from entry `rdStart`, one
/// cycle after the start. Thus each bank has one write port and one read
/// port, and a rotation mux puts the lanes in order. Entry indexes wrap at
/// [capacity].
class HarborPcieWindowBuffer {
  /// Number of banks, a power of two of at least 2.
  final int banks;

  /// Words in each bank, a power of two.
  final int bankDepth;

  int get capacity => banks * bankDepth;

  /// Entries `rdStart` to `rdStart + banks - 1` of the last cycle.
  late final List<Logic> window;

  HarborPcieWindowBuffer(
    Logic clk, {
    required int entries,
    required this.banks,
    required Logic wrEn,
    required Logic wrStart,
    required Logic wrCount,
    required List<Logic> wrLanes,
    required Logic rdStart,
    required String name,
  }) : bankDepth = _pow2Ceil((entries + banks - 1) ~/ banks) {
    if (banks < 2 || banks & (banks - 1) != 0) {
      throw ArgumentError.value(banks, 'banks', 'power of two >= 2');
    }
    if (wrLanes.length > banks) {
      throw ArgumentError('${wrLanes.length} lanes for $banks banks');
    }
    final bLog = banks.bitLength - 1;
    final aw = bankDepth.bitLength - 1;
    for (final s in [wrStart, rdStart]) {
      if (s.width < bLog + aw) {
        throw ArgumentError('start ${s.name} is narrower than ${bLog + aw}');
      }
    }
    Logic low(Logic s) => s.slice(bLog - 1, 0);
    Logic bankAddr(Logic s, Logic cb) =>
        s.slice(bLog + aw - 1, bLog) +
        mux(cb.lt(low(s)), Const(1), Const(0)).zeroExtend(aw);

    final cw = wrCount.width > bLog ? wrCount.width : bLog + 1;
    final lanes = [
      for (var k = 0; k < banks; k++)
        k < wrLanes.length ? wrLanes[k] : Const(0, width: 32),
    ];
    final bankOut = <Logic>[];
    for (var b = 0; b < banks; b++) {
      final cb = Const(b, width: bLog);
      final lane = (cb - low(wrStart)).named('${name}_w_lane_$b');
      final ram = HarborPcieBankRam(
        clk,
        width: 32,
        depth: bankDepth,
        wrEn: (wrEn & lane.zeroExtend(cw).lt(wrCount.zeroExtend(cw))).named(
          '${name}_w_en_$b',
        ),
        wrAddr: bankAddr(wrStart, cb).named('${name}_w_addr_$b'),
        wrData: lane.selectFrom(lanes).named('${name}_w_data_$b'),
        rdAddr: bankAddr(rdStart, cb).named('${name}_r_addr_$b'),
        name: '${name}_bank_$b',
      );
      bankOut.add(ram.rdData);
    }
    final rot = Logic(name: '${name}_rot', width: bLog);
    Sequential(clk, [rot < low(rdStart)]);
    window = [
      for (var k = 0; k < banks; k++)
        (rot + Const(k, width: bLog)).selectFrom(bankOut).named('${name}_$k'),
    ];
  }

  static int _pow2Ceil(int v) {
    var p = 2;
    while (p < v) {
      p <<= 1;
    }
    return p;
  }
}
