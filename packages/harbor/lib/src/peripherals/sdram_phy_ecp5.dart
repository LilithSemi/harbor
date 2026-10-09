/// ECP5 PHY for sdr sdram: every pin through an `OFS1P3BX`/`IFS1P3BX`/
/// `IDDRX1F` io register, and an inverted sdram_clk from an `ODDRX1F`.
library;

import 'package:rohd/rohd.dart';

import '../blackbox/ecp5/ecp5.dart';
import 'sdram_config.dart';
import 'sdram_phy_base.dart';

/// Which controller clock edge captures a read data pin at the pad.
enum HarborSdramCaptureEdge {
  /// `IFS1P3BX`, capturing on the rising edge.
  rising,

  /// `IDDRX1F.Q1`, capturing on the falling edge.
  falling,
}

/// ECP5-specific PHY knobs: the dq capture sample point, its fabric
/// pipeline depth, and an optional fine delay line.
class HarborSdramPhyConfig {
  /// Cycles from the raw pad-level sample to a captured dq bit holding
  /// steady in fabric (the sample register itself is 1 of these).
  /// Fixed at synthesis: [SdramPhyEcp5.readLatency] depends on it.
  final int captureCycles;

  /// Which clock edge the raw pad-level sample is taken on.
  final HarborSdramCaptureEdge captureEdge;

  /// Extra whole sdram_clk cycles the raw pad-level sample point moves
  /// back by. Adds no extra register: the capture register already
  /// free-runs every cycle, so this only changes which later cycle
  /// [SdramPhyEcp5.readLatency] reads the bit from. Default 0.
  final int captureCycleOffset;

  /// `DELAYF` tap count on every dq input, or null for no delay line.
  final int? dqDelayTaps;

  const HarborSdramPhyConfig({
    this.captureCycles = 2,
    this.captureEdge = HarborSdramCaptureEdge.rising,
    this.captureCycleOffset = 0,
    this.dqDelayTaps,
  });
}

/// Sdr sdram PHY for the ULX3S ECP5. Every output pin is registered
/// through an `OFS1P3BX` (`OFS1P3DX` for cke, so it idles low across
/// power-up), the dq output-enable through its own `OFS1P3BX` driving a
/// `BB.T` directly, and dq capture through an `IFS1P3BX` or `IDDRX1F` per
/// [HarborSdramPhyConfig.captureEdge]. sdram_clk is an `ODDRX1F` inverting
/// the controller clock.
///
/// The read capture window needs the fpga-to-sdram-and-back board flight
/// `d` to land inside a chip-timed window (as4c16m16sb datasheet rev 2.0,
/// table 16 p21, fig 20 p24, via [SdramPinModel]'s capture timeline). At
/// the ULX3S's two clock points, with the default `captureCycleOffset: 0`:
/// rising capture wants `d` in about `[1.5, 7]` ns at 125 MHz CL3 and
/// `[2.5, 9]` ns at 100 MHz CL2. Falling capture is narrower (`d <= tCk -
/// tAC`, about 3-4 ns), with no part of a cycle free; `captureCycleOffset:
/// 1` widens it, for a board too slow for rising capture.
class SdramPhyEcp5 extends SdramPhyBase {
  /// ECP5 LVCMOS33 output limit (Lattice FPGA-DS-02012 v1.9, table 3.21).
  static const int maxClockHzLvcmos33 = 150000000;

  final int _casLatency;
  final HarborSdramPhyConfig _phyConfig;

  /// 1 output register cycle, plus the chip's cas latency, plus the
  /// capture-point cycle offset, plus the dq capture pipeline. The single
  /// source for this formula: a caller that needs the number before this
  /// phy is built (to size a pipeline ahead of it) calls this instead of
  /// repeating it.
  static int computeReadLatency(int casLatency, HarborSdramPhyConfig phy) =>
      1 + casLatency + phy.captureCycleOffset + phy.captureCycles;

  @override
  int get readLatency => computeReadLatency(_casLatency, _phyConfig);

  @override
  Logic get rdData => output('rd_data');
  @override
  Logic get oSdramClk => output('o_sdram_clk');
  @override
  Logic get oSdramCke => output('o_sdram_cke');
  @override
  Logic get oSdramCsN => output('o_sdram_cs_n');
  @override
  Logic get oSdramRasN => output('o_sdram_ras_n');
  @override
  Logic get oSdramCasN => output('o_sdram_cas_n');
  @override
  Logic get oSdramWeN => output('o_sdram_we_n');
  @override
  Logic get oSdramBa => output('o_sdram_ba');
  @override
  Logic get oSdramAddr => output('o_sdram_addr');
  @override
  Logic get oSdramDqm => output('o_sdram_dqm');
  @override
  Logic get ioSdramDq => inOut('io_sdram_dq');

  SdramPhyEcp5(
    HarborSdramConfig config, {
    required int casLatency,
    required Logic clk,
    required Logic reset,
    required Logic cke,
    required Logic csN,
    required Logic rasN,
    required Logic casN,
    required Logic weN,
    required Logic ba,
    required Logic addr,
    required Logic dqm,
    required Logic dqOut,
    required Logic dqOe,
    required LogicNet dqPad,
    HarborSdramPhyConfig phy = const HarborSdramPhyConfig(),
    super.name = 'sdram_phy_ecp5',
  }) : _casLatency = casLatency,
       _phyConfig = phy {
    final bankBits = config.bankBits;
    final dqmBits = config.dataWidth ~/ 8;
    if (ba.width != bankBits) {
      throw ArgumentError('ba must be $bankBits bits wide, got ${ba.width}');
    }
    if (addr.width != config.rowWidth) {
      throw ArgumentError(
        'addr must be ${config.rowWidth} bits wide, got ${addr.width}',
      );
    }
    if (dqm.width != dqmBits) {
      throw ArgumentError('dqm must be $dqmBits bits wide, got ${dqm.width}');
    }
    if (dqOut.width != config.dataWidth || dqOe.width != config.dataWidth) {
      throw ArgumentError(
        'dqOut and dqOe must be ${config.dataWidth} bits wide',
      );
    }
    if (dqPad.width != config.dataWidth) {
      throw ArgumentError('dqPad must be ${config.dataWidth} bits wide');
    }
    if (_phyConfig.captureCycles < 1) {
      throw ArgumentError('captureCycles must be at least 1');
    }
    if (_phyConfig.captureCycleOffset < 0) {
      throw ArgumentError('captureCycleOffset must not be negative');
    }

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    cke = addInput('cke', cke);
    csN = addInput('cs_n', csN);
    rasN = addInput('ras_n', rasN);
    casN = addInput('cas_n', casN);
    weN = addInput('we_n', weN);
    ba = addInput('ba', ba, width: bankBits);
    addr = addInput('addr', addr, width: config.rowWidth);
    dqm = addInput('dqm', dqm, width: dqmBits);
    dqOut = addInput('dq_out', dqOut, width: config.dataWidth);
    dqOe = addInput('dq_oe', dqOe, width: config.dataWidth);
    final dqPadIo = addInOut('io_sdram_dq', dqPad, width: config.dataWidth);

    final rdDataOut = addOutput('rd_data', width: config.dataWidth);
    final oClk = addOutput('o_sdram_clk');
    final oCke = addOutput('o_sdram_cke');
    final oCsN = addOutput('o_sdram_cs_n');
    final oRasN = addOutput('o_sdram_ras_n');
    final oCasN = addOutput('o_sdram_cas_n');
    final oWeN = addOutput('o_sdram_we_n');
    final oBa = addOutput('o_sdram_ba', width: bankBits);
    final oAddr = addOutput('o_sdram_addr', width: config.rowWidth);
    final oDqm = addOutput('o_sdram_dqm', width: dqmBits);

    Logic ofs(Logic d, String n) => Ecp5Ofs1p3bx(d: d, sclk: clk, name: n).q;

    // cke alone uses the clear (power-up-low) variant: every other pin
    // idling high at config is fine (cs# deselected, dqm masked, dq
    // high-z), but cke must stay low until the init sequence raises it,
    // or the device could sample a command before init even starts.
    oCke <= Ecp5Ofs1p3dx(d: cke, sclk: clk, name: 'cke_ofs').q;
    oCsN <= ofs(csN, 'cs_n_ofs');
    oRasN <= ofs(rasN, 'ras_n_ofs');
    oCasN <= ofs(casN, 'cas_n_ofs');
    oWeN <= ofs(weN, 'we_n_ofs');
    oBa <=
        [for (var i = 0; i < bankBits; i++) ofs(ba[i], 'ba_ofs_$i')].rswizzle();
    oAddr <=
        [
          for (var i = 0; i < config.rowWidth; i++) ofs(addr[i], 'addr_ofs_$i'),
        ].rswizzle();
    oDqm <=
        [
          for (var i = 0; i < dqmBits; i++) ofs(dqm[i], 'dqm_ofs_$i'),
        ].rswizzle();

    oClk <= Ecp5Oddrx1f(sclk: clk, d0: Const(0), d1: Const(1), rst: Const(0)).q;

    final captured = <Logic>[];
    for (var i = 0; i < config.dataWidth; i++) {
      final dOut = ofs(dqOut[i], 'dq_out_ofs_$i');
      // The oe flop's d can equal a sibling bit's (one shared engine-side
      // enable, broadcast to every dq bit), which risks a yosys merge of
      // otherwise-distinct per-bit flops, so it is kept.
      final tReg = Ecp5Ofs1p3bx(
        d: ~dqOe[i],
        sclk: clk,
        keep: true,
        name: 'dq_oe_ofs_$i',
      ).q;
      final bb = Ecp5Bb(i: dOut, t: tReg, b: dqPadIo[i], name: 'dq_bb_$i');

      Logic padIn = bb.o;
      if (_phyConfig.dqDelayTaps != null) {
        padIn = Ecp5Delayf(
          a: padIn,
          loadn: Const(1),
          move: Const(0),
          direction: Const(0),
          delValue: _phyConfig.dqDelayTaps!,
          name: 'dq_delay_$i',
        ).z;
      }

      final bit = _phyConfig.captureEdge == HarborSdramCaptureEdge.rising
          ? Ecp5Ifs1p3bx(d: padIn, sclk: clk, name: 'dq_in_ifs_$i').q
          : Ecp5Iddrx1f(
              sclk: clk,
              rst: reset,
              d: padIn,
              name: 'dq_in_iddr_$i',
            ).q1;
      captured.add(bit);
    }

    // The pad-level capture register above is 1 cycle. captureCycles - 1
    // more are a plain fabric delay once a bit is captured. captureCycleOffset
    // adds no register of its own: the capture register above already
    // free-runs every cycle, so readLatency alone (not more fabric here)
    // accounts for reading the bit it holds a cycle (or more) later.
    var capturedBus = captured.rswizzle();
    for (var c = 0; c < _phyConfig.captureCycles - 1; c++) {
      capturedBus = flop(clk, capturedBus, reset: reset);
    }
    rdDataOut <= capturedBus;
  }
}
