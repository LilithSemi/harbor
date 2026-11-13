import 'package:rohd/rohd.dart';

/// SIM-ONLY behavioral stand-in for [XilinxOserdese2].
///
/// The real OSERDESE2 is an unmodelled SystemVerilog leaf (no ROHD co-sim). The
/// fabric write gearbox / command serializer that feeds D1..D[dataWidth] is
/// verified against THIS flop model at the same serialize contract, per the
/// fpga-synthesis-fit "keep a flop fallback at the same latency" rule (the write
/// mirror of [IserdesE2SimModel]).
///
/// Two configurations are modelled, matching the two [XilinxOserdese2] uses:
///   * DATA_RATE_OQ="DDR", DATA_WIDTH=8: the BL8 data/DQS/DM path: 8 beats shift
///     out two-per-[clk] (DDR), D1 first .. D8 last, over one [clkdiv] cycle.
///   * DATA_RATE_OQ="SDR", DATA_WIDTH=4: the UberDDR3 command serializer
///     (ddr3_phy.v OSERDESE2_cmd): 4 beats shift out one-per-[clk] (SDR), D1
///     first .. D4 last, over one [clkdiv] cycle. This is the CK-aligned
///     command/address/control path that places a command onto exactly one of
///     the 4 CK slots per controller tick.
///
/// Contract mirrored from the primitive / UberDDR3: the [dataWidth] parallel
/// beats are captured once per [clkdiv] cycle and shifted out onto [oq], D1
/// FIRST (D1 is the first serialized beat, D[dataWidth] last). The in-site
/// tristate is a pure BUF: [tq] follows [t1] combinationally (TQ = T1), which is
/// what `DATA_RATE_TQ("BUF")` means. NOT for synthesis. The PHY instantiates
/// [XilinxOserdese2] there.
///
/// This model runs its serialize shifter on [clk] (the fast DDR CK). A [clkdiv]
/// rising edge (detected against [clk]) reloads the beats. Between reloads the
/// shifter emits one beat per [clk] edge (DDR) or per [clk] rising edge (SDR).
/// Since a pure-fabric flop model cannot sub-divide a clock, the harness drives
/// [clkdiv] at the correct ratio (CK/4 for DDR/8, CK/4 for SDR/4) and the model's
/// job is the D1..D[dataWidth] -> OQ order + the TQ=T1 BUF contract the gearbox /
/// command tests assert, not the exact fast-clock phase.
class Oserdese2SimModel extends Module {
  Logic get oq => output('OQ');
  Logic get tq => output('TQ');

  final int dataWidth;

  Oserdese2SimModel(
    Logic clk, {
    // The parallel beats D1..D[dataWidth] (D1 first out). Exactly [dataWidth]
    // entries.
    required List<Logic> d,
    Logic? t1,
    Logic? clkdiv,
    Logic? reset,
    this.dataWidth = 8,
    super.name = 'oserdes_sim',
  }) {
    if (d.length != dataWidth) {
      throw ArgumentError(
        'Oserdese2SimModel DATA_WIDTH=$dataWidth needs $dataWidth beats.',
      );
    }
    clk = addInput('CLK', clk);
    t1 = addInput('T1', t1 ?? Const(0));
    clkdiv = addInput('CLKDIV', clkdiv ?? Const(0));
    reset = addInput('RST', reset ?? Const(0));
    final beats = <Logic>[
      for (var i = 0; i < dataWidth; i++) addInput('D${i + 1}', d[i]),
    ];
    addOutput('OQ');
    addOutput('TQ');

    // Pack the beats into one word, D1 in the LSB so a right-shift pops D1 first.
    final word = beats.rconcat().named('load_word');

    // CLKDIV edge detector on the fast CLK: reload the shifter on the CLKDIV
    // rising edge (its value differs from the registered copy and is high).
    final clkdivPrev = Logic(name: 'clkdiv_prev');
    final sr = Logic(name: 'ser_sr', width: dataWidth);

    Sequential(clk, reset: reset, [
      clkdivPrev < clkdiv,
      If(
        clkdiv & ~clkdivPrev,
        then: [
          // Reload: present D1 this edge, keep D2..D[dataWidth] queued.
          sr < word,
        ],
        orElse: [
          // Shift one beat out (LSB popped), fill high with 0.
          sr < [Const(0), sr.getRange(1, dataWidth)].concat(),
        ],
      ),
    ]);

    // OQ = current front beat (LSB of the shift register). On the reload edge the
    // combinational LSB is D1.
    oq <= mux(clkdiv & ~clkdivPrev, word[0], sr[0]);
    // In-site BUF tristate: TQ tracks T1 directly.
    tq <= t1;
  }
}
