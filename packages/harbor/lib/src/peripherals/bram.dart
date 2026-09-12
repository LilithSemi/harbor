library;

import 'package:rohd/rohd.dart';

import '../soc/target.dart';

/// Balanced mux-tree select: `entries[index]`.
Logic _sel(Logic index, List<Logic> entries) {
  if (entries.length == 1) return entries[0];
  final next = <Logic>[];
  for (var i = 0; i < entries.length; i += 2) {
    next.add(
      i + 1 < entries.length
          ? mux(index[0], entries[i + 1], entries[i])
          : entries[i],
    );
  }
  return _sel(index.getRange(1, index.width), next);
}

/// A single-write-port, single-registered-read-port block RAM: the raw dual-port
/// primitive (direct wr/rd ports, NOT a Wishbone peripheral like [HarborSram]),
/// sized for on-chip buffers such as a KV cache, an accumulator bank, or a result
/// FIFO.
///
/// It uses the `Module with SystemVerilog` split so it both SIMULATES and maps to
/// a real block RAM per FPGA vendor:
///   * the ROHD body is a behavioral flop-array memory with a REGISTERED read
///     (read data lands one cycle after the address: readLatency == 1), which
///     runs in the ROHD Simulator so tests exercise the exact hardware latency.
///   * [definitionVerilog] emits a plain INFERRABLE SystemVerilog memory
///     (`logic [W-1:0] mem [0:D-1]` with a synchronous write and a registered
///     read). The registered read is the block-RAM inference template on both
///     families, so yosys `synth_ecp5` infers a Lattice DP16KD and `synth_xilinx`
///     infers a Xilinx RAMB. The flop array never reaches silicon, only the
///     block RAM does. The emitted SV is vendor-neutral, so this primitive is
///     multitarget without a per-vendor branch.
///
/// Read/write share one clock. On a same-address, same-cycle read+write the read
/// returns the OLD value in both the sim model and the emitted always_ff, so the
/// two stay consistent. EXCEPT that an inferred block RAM returns UNDEFINED on
/// that collision on real silicon. A read-modify-write bank whose ports can hit
/// the same address in one cycle (e.g. a fp32 accumulator when a slow memory read
/// stalls the pipeline) must set [useFlops] to keep the deterministic flop body.
class HarborBram extends Module with SystemVerilog {
  final int width;
  final int depth;
  final int addrWidth;

  /// When true, DO NOT emit the inferrable [definitionVerilog]. Keep the flop-
  /// array body so synth maps this to fabric FLOPS. Needed for a read-modify-
  /// write bank whose read and write ports can hit the SAME address in one cycle:
  /// an inferred block RAM returns UNDEFINED on that collision while the flop
  /// model (and the required silicon behavior) is deterministic.
  final bool useFlops;

  /// Registered read data, one cycle behind [rd_addr] (readLatency == 1).
  Logic get rdData => output('rd_data');

  HarborBram(
    Logic clk, {
    required this.width,
    required this.depth,
    required Logic wrEn,
    required Logic wrAddr,
    required Logic wrData,
    required Logic rdAddr,
    String? name,
    this.useFlops = false,
  }) : addrWidth = (depth - 1).bitLength.clamp(1, 32),
       super(
         name: name ?? 'harbor_bram',
         // Distinct stable definition name per shape so the emitted SV file name
         // and the instantiation agree (two different-shaped RAMs are different
         // modules, same-shape RAMs dedupe to one).
         definitionName: 'HarborBram_${width}x$depth',
         reserveDefinitionName: true,
       ) {
    final aw = addrWidth;
    clk = addInput('clk', clk);
    wrEn = addInput('wr_en', wrEn);
    wrAddr = addInput('wr_addr', wrAddr, width: aw);
    wrData = addInput('wr_data', wrData, width: width);
    rdAddr = addInput('rd_addr', rdAddr, width: aw);
    final rd = addOutput('rd_data', width: width);

    // Replaced wholesale by [definitionVerilog] in synth, so these flops never
    // reach the netlist. They only give the Simulator a correct 1-cycle-latency
    // memory to verify the replay timing against.
    final cells = [
      for (var i = 0; i < depth; i++) Logic(name: 'cell$i', width: width),
    ];
    final rdReg = Logic(name: 'rd_reg', width: width);
    final rdSel = _sel(rdAddr, cells);
    Sequential(clk, [
      rdReg < rdSel,
      for (var i = 0; i < depth; i++)
        If(wrEn & wrAddr.eq(Const(i, width: aw)), then: [cells[i] < wrData]),
    ]);
    rd <= rdReg;
  }

  @override
  String? definitionVerilog(String definitionType) => useFlops
      ? null // keep the flop-array body -> synth maps to fabric flops (no BRAM)
      : '''
module $definitionType (
  input logic clk,
  input logic wr_en,
  input logic [${addrWidth - 1}:0] wr_addr,
  input logic [${width - 1}:0] wr_data,
  input logic [${addrWidth - 1}:0] rd_addr,
  output logic [${width - 1}:0] rd_data
);
  // Simple dual-port RAM: one synchronous write, one registered read
  // (readLatency == 1). yosys infers this as a block RAM (DP16KD on ECP5,
  // RAMB on Xilinx).
  logic [${width - 1}:0] mem [0:${depth - 1}];
  always_ff @(posedge clk) begin
    if (wr_en) mem[wr_addr] <= wr_data;
    rd_data <= mem[rd_addr];
  end
endmodule''';
}

/// A dual-clock, simple dual-port block RAM: one synchronous write port on
/// [wrClk] and one synchronous read port on [rdClk], with no shared clock
/// between them. This is the storage element of a clock-crossing FIFO, where
/// the producer and the consumer each own one port.
///
/// It uses the same `Module with SystemVerilog` split as [HarborBram], so it
/// both SIMULATES and maps to a real block RAM:
///   * the ROHD body is a behavioral memory with a REGISTERED read (read data
///     lands one cycle after the address, so `readLatency == 1`), which runs in
///     the ROHD Simulator and gives tests the exact hardware latency.
///   * [definitionVerilog] emits the vendor-neutral INFERENCE TEMPLATE for a
///     dual-clock memory. Each family's synthesis tool maps that template onto
///     the cell that [primitive] names (`DP16KD` on ECP5, `SB_RAM40_4K` on
///     iCE40, `RAMB*` on Xilinx). The flop array of the ROHD body never reaches
///     the netlist.
///
/// The template is inferred, not instantiated by hand, because the tool then
/// does the width and address mapping of the cell (the ECP5 `DP16KD` address
/// bus, for example, moves with the port width). A hand-wired cell cannot be
/// simulated in ROHD, so an error in it would reach silicon with no test that
/// can fail.
///
/// The two ports must NEVER hit the same address in the same cycle: a block RAM
/// gives UNDEFINED read data on that collision. A clock-crossing FIFO satisfies
/// this because the read side only reads an address that the write pointer has
/// already passed, and that pointer arrives through a two-flop synchronizer.
///
/// The memory cells have no reset, which is what a block RAM does. A read of a
/// cell that no write has filled therefore gives X in simulation, and a test
/// that reads such a cell fails. Only [rdData] has a reset.
class HarborDualClockBram extends Module with SystemVerilog {
  /// Data width in bits.
  final int width;

  /// Number of entries.
  final int depth;

  /// Address width in bits, derived from [depth].
  final int addrWidth;

  /// The vendor cell that this memory maps onto. It selects the comment in the
  /// emitted SystemVerilog and, through the definition name, keeps two
  /// different families from sharing one definition.
  final HarborBlockRam primitive;

  /// Registered read data, one [rdClk] cycle behind `rd_addr` and `rd_en`.
  Logic get rdData => output('rd_data');

  HarborDualClockBram({
    required Logic wrClk,
    required Logic wrEn,
    required Logic wrAddr,
    required Logic wrData,
    required Logic rdClk,
    required Logic rdReset,
    required Logic rdEn,
    required Logic rdAddr,
    required this.width,
    required this.depth,
    required this.primitive,
    String? name,
  }) : addrWidth = (depth - 1).bitLength.clamp(1, 32),
       super(
         name: name ?? 'dual_clock_bram',
         // One stable definition name for each shape and family, so the emitted
         // file name and the instantiation agree. Two memories of the same
         // shape and family are the same module and dedupe onto one definition.
         definitionName:
             'HarborDualClockBram_${width}x${depth}_${primitive.name}',
         reserveDefinitionName: true,
       ) {
    if (depth < 2) {
      throw ArgumentError.value(depth, 'depth', 'must be >= 2');
    }
    final aw = addrWidth;
    wrClk = addInput('wr_clk', wrClk);
    wrEn = addInput('wr_en', wrEn);
    wrAddr = addInput('wr_addr', wrAddr, width: aw);
    wrData = addInput('wr_data', wrData, width: width);
    rdClk = addInput('rd_clk', rdClk);
    rdReset = addInput('rd_reset', rdReset);
    rdEn = addInput('rd_en', rdEn);
    rdAddr = addInput('rd_addr', rdAddr, width: aw);
    final rd = addOutput('rd_data', width: width);

    // [definitionVerilog] replaces these in synthesis, so the cells never reach
    // the netlist. They only give the Simulator a memory with the correct
    // 1-cycle read latency.
    final cells = [
      for (var i = 0; i < depth; i++) Logic(name: 'cell$i', width: width),
    ];
    Sequential(wrClk, [
      If(
        wrEn,
        then: [
          for (var i = 0; i < depth; i++)
            If(wrAddr.eq(Const(i, width: aw)), then: [cells[i] < wrData]),
        ],
      ),
    ]);

    final rdReg = Logic(name: 'rd_reg', width: width);
    Sequential(rdClk, [
      If(
        rdReset,
        then: [rdReg < Const(0, width: width)],
        orElse: [
          If(rdEn, then: [rdReg < _sel(rdAddr, cells)]),
        ],
      ),
    ]);
    rd <= rdReg;
  }

  @override
  String? definitionVerilog(String definitionType) =>
      '''
module $definitionType (
  input logic wr_clk,
  input logic wr_en,
  input logic [${addrWidth - 1}:0] wr_addr,
  input logic [${width - 1}:0] wr_data,
  input logic rd_clk,
  input logic rd_reset,
  input logic rd_en,
  input logic [${addrWidth - 1}:0] rd_addr,
  output logic [${width - 1}:0] rd_data
);
  // Simple dual-port RAM with one clock for each port: a synchronous write on
  // wr_clk and a registered read on rd_clk (readLatency == 1). This is the
  // block RAM inference template, which yosys maps onto ${_primitiveCell}.
  logic [${width - 1}:0] mem [0:${depth - 1}];
  always_ff @(posedge wr_clk) begin
    if (wr_en) mem[wr_addr] <= wr_data;
  end
  always_ff @(posedge rd_clk) begin
    if (rd_reset) rd_data <= ${width}'d0;
    else if (rd_en) rd_data <= mem[rd_addr];
  end
endmodule''';

  /// The vendor cell name for the comment in the emitted SystemVerilog.
  String get _primitiveCell => switch (primitive) {
    HarborBlockRam.dp16kd => 'a Lattice ECP5 DP16KD',
    HarborBlockRam.sbRam40_4k => 'a Lattice iCE40 SB_RAM40_4K',
    HarborBlockRam.ramb => 'a Xilinx RAMB',
  };
}
