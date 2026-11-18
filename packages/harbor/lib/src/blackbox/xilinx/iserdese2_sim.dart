import 'package:rohd/rohd.dart';

/// SIM-ONLY behavioral stand-in for [XilinxIserdese2] at DDR, DATA_WIDTH 2 or 8.
///
/// The real ISERDESE2 is an unmodelled SystemVerilog leaf (no ROHD co-sim).
/// The fabric read-assembly logic is verified against THIS flop model at the same
/// (1 clkdiv-cycle) latency, per the fpga-synthesis-fit "keep a flop fallback at
/// the same read latency" rule. It deserializes the [ddly] sample stream into a
/// [dataWidth]-wide parallel word presented on Q1..Q[dataWidth]. A [bitslip]
/// pulse rotates the sampling parity by one, mimicking the primitive's
/// glitch-free 1-position beat rotate. NOT for synthesis. The PHY instantiates
/// [XilinxIserdese2] there.
///
/// At DATA_WIDTH=8 (the DDR3-667 4:1 read gearbox), the model captures 8 serial
/// samples over 8 [clkdiv]-EDGE-equivalent phases and presents them together
/// once per fabric cycle. Since this is a pure-fabric flop model (the real
/// oversampling happens on the fast CLK inside the primitive), the sim harness
/// drives [ddly] with the intended 8-beat pattern one beat per model input via
/// [loadBeat]/direct wiring in tests. The model's job here is the Q1..Q8 port
/// map + bitslip rotate contract the assembler consumes, not fast-clock timing.
///
/// Xilinx bit-order convention (matches the real ISERDESE2 / UberDDR3 /
/// LiteDRAM): Q1 is the NEWEST (last-arriving) beat, Q[dataWidth] is the OLDEST
/// (first-arriving) beat. The PHY read packer therefore takes beat 0 (the first
/// DQ beat off the DRAM) from Q[dataWidth] and beat [dataWidth]-1 from Q1.
class IserdesE2SimModel extends Module {
  Logic get q1 => output('Q1');
  Logic get q2 => output('Q2');

  /// The parallel beat outputs Q1 (newest) .. Q[dataWidth] (oldest).
  Logic q(int i) => output('Q$i');

  final int dataWidth;

  IserdesE2SimModel(
    Logic clkdiv, {
    required Logic ddly,
    required Logic bitslip,
    Logic? reset,
    this.dataWidth = 2,
    super.name = 'iserdes_sim',
  }) {
    clkdiv = addInput('CLKDIV', clkdiv);
    ddly = addInput('DDLY', ddly);
    bitslip = addInput('BITSLIP', bitslip);
    reset = addInput('RST', reset ?? Const(0));
    for (var i = 1; i <= dataWidth; i++) {
      addOutput('Q$i');
    }

    // [dataWidth]-deep shift register: sr[dataWidth-1] = oldest sample,
    // sr[0] = newest. {sr[dataWidth-2:0], ddly} shifts ddly into the LSB.
    final sr = Logic(name: 'sr', width: dataWidth);
    // bitslip parity counter (0..dataWidth-1): each pulse advances the rotate
    // by one, matching the primitive's glitch-free beat rotate.
    final bsW = dataWidth <= 1 ? 1 : (dataWidth - 1).bitLength;
    final bs = Logic(name: 'bs_rot', width: bsW);

    Sequential(clkdiv, reset: reset, [
      sr < [sr.getRange(0, dataWidth - 1), ddly].concat(),
      If(
        bitslip,
        then: [
          If(
            bs.eq(Const(dataWidth - 1, width: bsW)),
            then: [bs < 0],
            orElse: [bs < bs + 1],
          ),
        ],
      ),
    ]);

    // Q1 = newest ... Q[dataWidth] = oldest (the real ISERDESE2 convention),
    // i.e. Qk = sr[k-1] (sr[0] = newest), with the whole map rotated by the
    // bitslip parity. Build the rotate as a mux tree.
    for (var k = 1; k <= dataWidth; k++) {
      // Base index (bs==0): Qk = sr[k-1].
      Logic sel = sr[k - 1];
      for (var r = 1; r < dataWidth; r++) {
        final idx = (k - 1 + r) % dataWidth;
        sel = mux(bs.eq(Const(r, width: bsW)), sr[idx], sel);
      }
      output('Q$k') <= sel;
    }
  }
}
