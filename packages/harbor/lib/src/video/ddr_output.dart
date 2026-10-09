import 'package:rohd/rohd.dart';

/// A 1:2 gearing DDR output register, written in plain logic.
///
/// Every FPGA family has a hard cell for this ([Ecp5Oddrx1f] on Lattice,
/// [XilinxOddr] on Xilinx 7 series), and a build for a real part must use that
/// cell, because only the cell can put the register in the pad. A simulation
/// build uses this module instead, so it never depends on a cell that stands
/// for a part the build is not targeting (true even for [Ecp5Oddrx1f], which
/// does have a sim body now, added for sdram).
///
/// It is deliberately vendor neutral. A simulation of a Xilinx design must not
/// pull in a Lattice primitive to stand in for a Xilinx one, because that hides
/// which part the design is for and puts a cell in the netlist that the part
/// does not have.
///
/// Gearing: BOTH inputs are captured on the RISING edge of [clk]. [q] then
/// shows [d0] while [clk] is high and [d1] while [clk] is low, so the output
/// changes two times per clock period from logic that runs on one edge only.
/// Capturing [d1] on the falling edge instead sends the wrong bit, because the
/// source register has already moved on by then. That fault shows as a
/// scrambled data stream, not as an error, so it is easy to miss.
///
/// The output delay of a real pad is not modelled. No cycle level simulation
/// can see it.
class HarborDdrOutput extends Module {
  /// The DDR output. Changes two times per [clk] period.
  Logic get q => output('q');

  HarborDdrOutput({
    required Logic clk,
    required Logic reset,
    required Logic d0,
    required Logic d1,
    super.name = 'ddr_output',
  }) : super(definitionName: 'HarborDdrOutput') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    d0 = addInput('d0', d0);
    d1 = addInput('d1', d1);
    addOutput('q');

    final qRise = Logic(name: 'q_rise');
    final qFall = Logic(name: 'q_fall');

    Sequential(clk, reset: reset, [qRise < d0, qFall < d1]);

    // The clock is a data input here. That is correct for this module and only
    // this module: it is how one edge of logic drives two output values, and it
    // is why a real build uses the pad cell instead.
    q <= mux(clk, qRise, qFall);
  }
}
