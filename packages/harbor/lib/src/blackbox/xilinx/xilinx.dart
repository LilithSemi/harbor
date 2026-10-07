import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Xilinx 7-series MMCME2_ADV: Mixed-mode clock manager.
class XilinxMmcme2Adv extends BridgeModule {
  XilinxMmcme2Adv({
    required double clkfboutMult,
    required double clkout0Divide,
    required double divclkDivide,
    required double clkinPeriod,
    double clkout0Phase = 0.0,
    // Optional outputs CLKOUT1..3. MMCME2 CLKOUT1..6 take an INTEGER divide
    // (only CLKOUT0 is fractional). Set to enable secondary related clocks off
    // the same VCO. For the DDR3 clock tree the four are: CLKOUT0 (DDR CK,
    // fractional), CLKOUT1 (controller/CLKDIV), CLKOUT2 (IDELAYCTRL 200MHz ref),
    // CLKOUT3 (DDR CK @90deg for the write path).
    int? clkout1Divide,
    double clkout1Phase = 0.0,
    int? clkout2Divide,
    double clkout2Phase = 0.0,
    int? clkout3Divide,
    double clkout3Phase = 0.0,
    // CLKOUT4: the DDR3 write DQS launch clock. On the Arty HR bank (no ODELAYE2)
    // the HW-verified UberDDR3 oracle launches the DQS OSERDES on !i_ddr3_clk
    // (180-degree/inverted CK) while DQ/DM ride ck90, so the DQS edge lands
    // centered in the DQ eye AND the strobe frames the write off CK. This gives a
    // dedicated 180-degree (sweepable) DQS clock without inverting a global net.
    int? clkout4Divide,
    double clkout4Phase = 0.0,
    // CLKOUT5: a spare integer-divided output off the same VCO. Used to emit the
    // slow SoC/core clock from the SAME DDR3 MMCM (single-oscillator boards like
    // the Arty S7): a second MMCM on the raw clock pin cannot share the pin's one
    // dedicated CC->MMCM route, so folding the core clock onto a spare CLKOUT of
    // the DDR MMCM keeps ONE MMCM on the pin.
    int? clkout5Divide,
    double clkout5Phase = 0.0,
    // Feedback compensation. On the openXC7 flow the MMCM ONLY locks with
    // ZHOLD (and a BUFG in the feedback path, wired by the caller). The default
    // INTERNAL makes nextpnr drop or mis-lock the MMCM so it free-runs the VCO.
    String compensation = 'ZHOLD',
    super.name = 'mmcm',
  }) : super('MMCME2_ADV', isSystemVerilogLeaf: true) {
    createPort('CLKIN1', PortDirection.input);
    createPort('CLKIN2', PortDirection.input);
    createPort('CLKINSEL', PortDirection.input);
    createPort('CLKFBIN', PortDirection.input);
    createPort('RST', PortDirection.input);
    createPort('PWRDWN', PortDirection.input);
    addOutput('CLKOUT0');
    addOutput('CLKOUT1');
    addOutput('CLKOUT2');
    addOutput('CLKOUT3');
    addOutput('CLKOUT4');
    addOutput('CLKOUT5');
    addOutput('CLKOUT6');
    addOutput('CLKFBOUT');
    addOutput('LOCKED');

    createParameter('CLKFBOUT_MULT_F', '$clkfboutMult');
    createParameter('CLKOUT0_DIVIDE_F', '$clkout0Divide');
    createParameter('CLKOUT0_PHASE', '$clkout0Phase');
    if (clkout1Divide != null) {
      createParameter('CLKOUT1_DIVIDE', '$clkout1Divide');
      createParameter('CLKOUT1_PHASE', '$clkout1Phase');
    }
    if (clkout2Divide != null) {
      createParameter('CLKOUT2_DIVIDE', '$clkout2Divide');
      createParameter('CLKOUT2_PHASE', '$clkout2Phase');
    }
    if (clkout3Divide != null) {
      createParameter('CLKOUT3_DIVIDE', '$clkout3Divide');
      createParameter('CLKOUT3_PHASE', '$clkout3Phase');
    }
    if (clkout4Divide != null) {
      createParameter('CLKOUT4_DIVIDE', '$clkout4Divide');
      createParameter('CLKOUT4_PHASE', '$clkout4Phase');
    }
    if (clkout5Divide != null) {
      createParameter('CLKOUT5_DIVIDE', '$clkout5Divide');
      createParameter('CLKOUT5_PHASE', '$clkout5Phase');
    }
    createParameter('DIVCLK_DIVIDE', '${divclkDivide.toInt()}');
    createParameter('CLKIN1_PERIOD', '$clkinPeriod');
    createParameter('COMPENSATION', '"$compensation"');
  }
}

/// Xilinx 7-series PLLE2_ADV: the openXC7-proven DDR3 clock generator.
///
/// The HW-verified UberDDR3 openXC7 Arty-S7 flow drives its whole DDR3 clock
/// tree from a PLLE2_ADV with COMPENSATION "INTERNAL" and the feedback wired
/// DIRECTLY (CLKFBIN <= CLKFBOUT, no BUFG). MMCME2_ADV with ZHOLD + a feedback
/// BUFG builds and LOCKS on openXC7 in isolation, but once the DDR PHY's
/// ISERDES/OSERDES/IDELAY + BUFIO/BUFR clocking is in the same design the
/// router produces a physically-invalid clock net and NO clock reaches the
/// fabric. The PLLE2_ADV + INTERNAL + direct-feedback form is the one openXC7
/// actually realises correctly alongside the PHY. Integer divides only (no
/// fractional _F). PLLE2 VCO band is 800-1600 MHz.
class XilinxPlle2Adv extends BridgeModule {
  XilinxPlle2Adv({
    required int clkfboutMult,
    required int clkout0Divide,
    required int divclkDivide,
    required double clkinPeriod,
    double clkout0Phase = 0.0,
    int? clkout1Divide,
    double clkout1Phase = 0.0,
    int? clkout2Divide,
    double clkout2Phase = 0.0,
    int? clkout3Divide,
    double clkout3Phase = 0.0,
    int? clkout4Divide,
    double clkout4Phase = 0.0,
    int? clkout5Divide,
    double clkout5Phase = 0.0,
    super.name = 'pll',
  }) : super('PLLE2_ADV', isSystemVerilogLeaf: true) {
    createPort('CLKIN1', PortDirection.input);
    createPort('CLKIN2', PortDirection.input);
    createPort('CLKINSEL', PortDirection.input);
    createPort('CLKFBIN', PortDirection.input);
    createPort('RST', PortDirection.input);
    createPort('PWRDWN', PortDirection.input);
    // PLLE2_ADV has CLKOUT0..5 (no CLKOUT6).
    addOutput('CLKOUT0');
    addOutput('CLKOUT1');
    addOutput('CLKOUT2');
    addOutput('CLKOUT3');
    addOutput('CLKOUT4');
    addOutput('CLKOUT5');
    addOutput('CLKFBOUT');
    addOutput('LOCKED');

    createParameter('BANDWIDTH', '"OPTIMIZED"');
    createParameter('COMPENSATION', '"INTERNAL"');
    createParameter('STARTUP_WAIT', '"FALSE"');
    createParameter('CLKFBOUT_MULT', '$clkfboutMult');
    createParameter('CLKFBOUT_PHASE', '0.000');
    createParameter('CLKOUT0_DIVIDE', '$clkout0Divide');
    createParameter('CLKOUT0_PHASE', '$clkout0Phase');
    createParameter('CLKOUT0_DUTY_CYCLE', '0.500');
    if (clkout1Divide != null) {
      createParameter('CLKOUT1_DIVIDE', '$clkout1Divide');
      createParameter('CLKOUT1_PHASE', '$clkout1Phase');
      createParameter('CLKOUT1_DUTY_CYCLE', '0.500');
    }
    if (clkout2Divide != null) {
      createParameter('CLKOUT2_DIVIDE', '$clkout2Divide');
      createParameter('CLKOUT2_PHASE', '$clkout2Phase');
      createParameter('CLKOUT2_DUTY_CYCLE', '0.500');
    }
    if (clkout3Divide != null) {
      createParameter('CLKOUT3_DIVIDE', '$clkout3Divide');
      createParameter('CLKOUT3_PHASE', '$clkout3Phase');
      createParameter('CLKOUT3_DUTY_CYCLE', '0.500');
    }
    if (clkout4Divide != null) {
      createParameter('CLKOUT4_DIVIDE', '$clkout4Divide');
      createParameter('CLKOUT4_PHASE', '$clkout4Phase');
      createParameter('CLKOUT4_DUTY_CYCLE', '0.500');
    }
    if (clkout5Divide != null) {
      createParameter('CLKOUT5_DIVIDE', '$clkout5Divide');
      createParameter('CLKOUT5_PHASE', '$clkout5Phase');
      createParameter('CLKOUT5_DUTY_CYCLE', '0.500');
    }
    createParameter('DIVCLK_DIVIDE', '$divclkDivide');
    createParameter('CLKIN1_PERIOD', '$clkinPeriod');
  }
}

/// The four related clocks a DDR3-667 PHY needs off one MMCM VCO, each on its
/// own global buffer. Ratios are the UberDDR3 (HW-verified openXC7) scheme:
/// a fast DDR CK, a controller clock at CK/4 (the ISERDESE2 CLKDIV), a
/// ~200 MHz IDELAYCTRL reference, and a 90-degree copy of the DDR CK for the
/// write path.
class XilinxDdr3Clocks {
  const XilinxDdr3Clocks({
    required this.ddrCk,
    required this.controller,
    required this.idelayRef,
    required this.ddrCk90,
    required this.ddrCkDqs,
    required this.locked,
    required this.ddrCkMhz,
    required this.controllerMhz,
    required this.idelayRefMhz,
    required this.vcoMhz,
    required this.controllerClk,
    required this.controllerClkMhz,
    this.coreClk,
    this.coreClkMhz,
  });

  /// Fast DDR CK (~333 MHz), the ISERDESE2/OSERDESE2 CLK.
  final Logic ddrCk;

  /// Controller / CLKDIV clock (= DDR CK / 4, ~83 MHz), the SERDES CLKDIV +
  /// (at gearRatio 1) the sequencer clock. When the DDR runs a CK/8 controller
  /// (gearRatio 2) this stays CK/4 and feeds only the SERDES (HarborDdr3's
  /// `ddr_serdes_clk`); the sequencer moves to [controllerClk].
  final Logic controller;

  /// Controller-LOGIC clock the Ddr3Controller sequencer runs on. Equals
  /// [controller] (CK/4) at gearRatio 1 (byte-identical); at gearRatio 2 it is a
  /// CK/8 clock off the SAME VCO on the spare CLKOUT5 (integer 2:1 to CK/4, which
  /// the fabric gearbox requires), buying the congestion-limited command
  /// scheduler timing margin while the SERDES stays on [controller].
  final Logic controllerClk;

  /// IDELAYCTRL reference (~200 MHz). Must match the IDELAYE2 REFCLK_FREQUENCY
  /// or the taps never calibrate (RDY stays low).
  final Logic idelayRef;

  /// 90-degree DDR CK for the write launch path (ODDR/OSERDESE2 data centering).
  final Logic ddrCk90;

  /// DDR CK for the write DQS launch (default 180-degree = the UberDDR3 Arty
  /// HR-bank oracle's !i_ddr3_clk). DQS on this while DQ/DM ride ddrCk90 puts
  /// the DQS edge in the center of the DQ eye AND edge-frames the write off CK
  /// (JEDEC tDQSS). The phase is a build-sweepable bring-up knob.
  final Logic ddrCkDqs;

  /// MMCM LOCKED. On openXC7 this may not reach the fabric on silicon. Hold the
  /// core in reset with a fixed timer instead of gating on it.
  final Logic locked;

  /// Slow SoC/core clock off the SAME MMCM (CLKOUT5), present only when
  /// [buildXilinxDdr3ClockTree] is called with `coreClkHz`. Lets a
  /// single-oscillator board (Arty S7) run its core off this MMCM instead of a
  /// SECOND MMCM contending for the raw clock pin's one dedicated CC route.
  final Logic? coreClk;

  final double ddrCkMhz;
  final double controllerMhz;

  /// Realised [controllerClk] rate (= [controllerMhz] at gearRatio 1, half it at
  /// gearRatio 2).
  final double controllerClkMhz;
  final double idelayRefMhz;
  final double vcoMhz;
  final double? coreClkMhz;
}

/// Parameters for a [buildXilinxDdr3ClockTree] built INSIDE the SoC clock
/// generation (so the core/sys domain can run off the tree's spare core CLKOUT
/// on a single-oscillator board). The tree source is the SoC's own `clk` pin.
class XilinxDdr3TreeSpec {
  /// Oscillator input frequency in Hz (the SoC `clk` pin rate).
  final int sourceHz;

  /// Target DDR CK in Hz.
  final int ddrCkHz;

  /// IDELAYCTRL reference in Hz.
  final int idelayRefHz;

  /// DQS launch phase in degrees (CLKOUT4).
  final double dqsPhaseDeg;

  /// Slow SoC/core clock in Hz, emitted on the tree's spare CLKOUT5.
  final int coreClkHz;

  /// DDR controller-logic gearing (1 = CK/4 controller, 2 = CK/8 controller on
  /// the spare CLKOUT5). Forwarded to [buildXilinxDdr3ClockTree].
  final int ddrGearRatio;

  const XilinxDdr3TreeSpec({
    required this.sourceHz,
    required this.ddrCkHz,
    required this.coreClkHz,
    this.idelayRefHz = 200000000,
    this.dqsPhaseDeg = 180.0,
    this.ddrGearRatio = 1,
  });
}

/// Solves one 7-series MMCME2 VCO for the four DDR3 clocks: DDR CK (fractional
/// CLKOUT0), controller = CK/4 (integer CLKOUT1), IDELAYCTRL ref ~200 MHz
/// (integer CLKOUT2), DDR CK @90 (fractional would need CLKOUT0's copy, but the
/// integer CLKOUT3 at the same divide as the CK carries the 90-degree phase).
/// Keeps the VCO in 600-1200 MHz and the PFD (fin/D) in 10-450 MHz, minimising
/// the summed relative error of the DDR-CK and the IDELAYCTRL-ref targets.
///
/// Returns null when no in-band solution exists for the given source.
({
  double mult,
  int divclk,
  double ckDivide,
  int ctrlDivide,
  int refDivide,
  double vco,
})?
solveDdr3ClockTree(int finHz, int ddrCkHz, int idelayRefHz) {
  final ctrlHz = ddrCkHz ~/ 4;
  var bestScore = double.infinity;
  ({
    double mult,
    int divclk,
    double ckDivide,
    int ctrlDivide,
    int refDivide,
    double vco,
  })?
  best;
  for (var d = 1; d <= 8; d++) {
    final pfd = finHz / d;
    if (pfd < 10e6 || pfd > 450e6) continue;
    for (var m8 = 16; m8 <= 512; m8++) {
      final m = m8 / 8.0;
      final vco = finHz * m / d;
      if (vco < 600e6 || vco > 1200e6) continue;
      final ckDiv = ((vco / ddrCkHz) * 8).round() / 8.0;
      if (ckDiv < 1.0 || ckDiv > 128.0) continue;
      final ctrlDiv = (vco / ctrlHz).round();
      if (ctrlDiv < 1 || ctrlDiv > 128) continue;
      final refDiv = (vco / idelayRefHz).round();
      if (refDiv < 1 || refDiv > 128) continue;
      final ckErr = (vco / ckDiv - ddrCkHz).abs() / ddrCkHz;
      final ctrlErr = (vco / ctrlDiv - ctrlHz).abs() / ctrlHz;
      final refErr = (vco / refDiv - idelayRefHz).abs() / idelayRefHz;
      // The DDR-CK-@90 output (CLKOUT3) reuses the CK divide ROUNDED to an
      // integer (MMCM CLKOUT1..6 take only integer divides), so if ckDiv is
      // fractional the 90-degree clock lands at a DIFFERENT frequency than the CK
      // (e.g. VCO 600, ckDiv 1.5 -> CK 400 but ck90 = 600/round(1.5)=/2 = 300
      // MHz), desynchronising the write DQS/DQ launch. So among EQUAL-error
      // solutions strongly prefer an INTEGER ckDiv (ck90 == CK exactly). This is a
      // secondary TIE-BREAK, weighted far below a real CK/ctrl/ref frequency
      // error, so an off-grid source (12 MHz -> a small fractional CK error to
      // keep the 200 MHz ref in band) still wins over a worse-frequency integer
      // solution, while the exact 100 MHz -> CK/3 integer VCO=1200 beats the
      // fractional CK/1.5 VCO=600 that has the same output frequencies.
      final ckFrac = (ckDiv - ckDiv.round()).abs(); // 0 when integer
      final intBias = ckFrac * 1e-3;
      // Among otherwise-equal solutions prefer the HIGHEST VCO (lower MMCM output
      // jitter, matches the HW-verified UberDDR3 oracle's VCO=1200 for 100 MHz ->
      // CK 400). Tiny tie-break, below intBias so it never flips an integer CK.
      final vcoBias = ((1200e6 - vco) / 1200e6) * 1e-6;
      final score = ckErr + ctrlErr + refErr + intBias + vcoBias;
      if (score < bestScore) {
        bestScore = score;
        best = (
          mult: m,
          divclk: d,
          ckDivide: ckDiv,
          ctrlDivide: ctrlDiv,
          refDivide: refDiv,
          vco: vco,
        );
      }
    }
  }
  return best;
}

/// Builds the full DDR3-667 clock tree in [parent]: an MMCME2_ADV (BUFG
/// feedback + COMPENSATION ZHOLD, the only openXC7-lockable form) driven by
/// [source] at [sourceHz], with its four related outputs each buffered on a
/// dedicated BUFG. Returns the four clock nets plus LOCKED and the realised
/// frequencies. Throws if the source cannot reach the targets in-band.
///
/// This is the clock foundation for the Arty S7-50 real-DDR3 bring-up. The DDR
/// datapath (ISERDESE2 DATA_WIDTH=8 capture, VAR_LOAD IDELAY, calibration FSM,
/// 4:1 command SERDES) is the retiming work tracked separately. This piece just
/// produces the clocks those blocks consume.
XilinxDdr3Clocks buildXilinxDdr3ClockTree(
  BridgeModule parent, {
  required Logic source,
  required int sourceHz,
  int ddrCkHz = 333333333,
  int idelayRefHz = 200000000,
  // DQS launch phase (CLKOUT4). 180.0 = the UberDDR3 Arty HR-bank oracle
  // (!i_ddr3_clk). Sweepable for write-timing bring-up (135/180/225 walk tDQSS
  // in sub-CK steps, the phase the whole-tick sweep could never vary).
  double dqsPhaseDeg = 180.0,
  // Optional slow SoC/core clock (CLKOUT5) off the SAME VCO. When set, a
  // single-oscillator board runs its core off THIS MMCM instead of a second
  // MMCM (two MMCMs cannot share the raw clock pin's one dedicated CC route on
  // openXC7). The divide is round(VCO / coreClkHz), clamped to the 1..128
  // CLKOUT range. The realised rate is exposed as [XilinxDdr3Clocks.coreClkMhz].
  int? coreClkHz,
  // DDR controller-logic gearing. 1 = the controller runs on CK/4 ([controller]).
  // 2 = a CK/8 controller: emit the spare CLKOUT5 as CK/8 (integer 2x the CK/4
  // divide, same VCO -> phase-locked 2:1) and return it as [controllerClk]. The
  // CK/8 controller needs the fabric gearbox (HarborDdr3 controllerGearRatio 2).
  int ddrGearRatio = 1,
  String name = 'ddr3clk',
}) {
  final sol = solveDdr3ClockTree(sourceHz, ddrCkHz, idelayRefHz);
  if (sol == null) {
    throw StateError(
      'No MMCME2 DDR3 clock-tree solution for source=$sourceHz '
      'ddrCk=$ddrCkHz idelayRef=$idelayRefHz (VCO 600-1200 MHz unreachable).',
    );
  }
  final geared = ddrGearRatio > 1;
  if (geared && coreClkHz != null) {
    throw StateError(
      'DDR gearRatio $ddrGearRatio uses the spare CLKOUT5 for the CK/8 '
      'controller clock, but coreClkHz occupies it. Drive the core from a '
      'separate PLL (buildXilinxCorePll) so CLKOUT5 is free.',
    );
  }
  // CK/8 controller divide off the SAME VCO on CLKOUT5 (integer 2x the CK/4
  // ctrl divide, so CK/8 is a clean integer divide phase-locked to CK/4). Valid
  // for any ctrlDivide <= 64 (CLKOUT range is 1..128).
  final ctrlGearDivide = geared ? ddrGearRatio * sol.ctrlDivide : null;
  if (ctrlGearDivide != null && (ctrlGearDivide < 1 || ctrlGearDivide > 128)) {
    throw StateError(
      'DDR gearRatio $ddrGearRatio CK/${4 * ddrGearRatio} divide '
      '$ctrlGearDivide is out of the CLKOUT 1..128 range.',
    );
  }
  // Optional core-clock divide off the same VCO (CLKOUT5). round() lands the
  // nearest integer, clamp to the PLLE2 CLKOUT 1..128 range. Mutually exclusive
  // with [ctrlGearDivide] (both would claim CLKOUT5; asserted above).
  final coreDivide = coreClkHz == null
      ? null
      : (sol.vco / coreClkHz).round().clamp(1, 128);
  // PLLE2_ADV + COMPENSATION INTERNAL + DIRECT feedback: the UberDDR3-proven
  // openXC7 form. See [XilinxPlle2Adv]. All divides are integers.
  final pll = parent.addSubModule(
    XilinxPlle2Adv(
      clkfboutMult: sol.mult.round(),
      clkout0Divide: sol.ckDivide.round(),
      divclkDivide: sol.divclk.toInt(),
      clkinPeriod: 1e9 / sourceHz,
      // CLKOUT1 = controller (CK/4), CLKOUT2 = IDELAYCTRL ref, CLKOUT3 = CK@90.
      clkout1Divide: sol.ctrlDivide,
      clkout2Divide: sol.refDivide,
      clkout3Divide: sol.ckDivide.round(),
      // ck90 write-launch phase: 90 deg centers the write eye (hardware-swept,
      // 0/90/180/270 = errs 3/2/16/16, flat across 68-113).
      clkout3Phase: 90.0,
      // CLKOUT4 = DQS launch CK (same divide as CK, phase = dqsPhaseDeg,
      // default 180 = oracle !i_ddr3_clk).
      clkout4Divide: sol.ckDivide.round(),
      clkout4Phase: dqsPhaseDeg,
      // CLKOUT5 = slow SoC/core clock (optional) OR the CK/8 controller clock
      // when geared (mutually exclusive).
      clkout5Divide: coreDivide ?? ctrlGearDivide,
      name: '${name}_pll',
    ),
  );
  pll.input('CLKIN1').srcConnection! <= source;
  pll.input('CLKIN2').srcConnection! <= Const(0);
  pll.input('CLKINSEL').srcConnection! <= Const(1);
  // INTERNAL compensation: feedback wired directly, NO BUFG (UberDDR3 form).
  pll.input('CLKFBIN').srcConnection! <= pll.output('CLKFBOUT');
  pll.input('RST').srcConnection! <= Const(0);
  pll.input('PWRDWN').srcConnection! <= Const(0);

  Logic bufOut(String clkout, String tag) {
    final b = parent.addSubModule(XilinxBufg(name: '${name}_${tag}_bufg'));
    b.input('I').srcConnection! <= pll.output(clkout);
    return b.output('O');
  }

  // NOTE (do not "optimise" back to a BUFH): a PLLE2 CLKOUT cannot reliably
  // drive a regional BUFHCE directly. PLL outputs connect to GLOBAL BUFGs via
  // dedicated routes, while BUFHs are fed from BUFGs/CMT, so CLKOUTn -> BUFHCE.I
  // fails to route on nextpnr-xilinx ("Failed to route arc of net CLKOUTx").
  // Every PLL output therefore stays on its own global BUFG.
  // CK/4 SERDES/CLKDIV clock (also the sequencer clock at gearRatio 1).
  final ctrlNet = bufOut('CLKOUT1', 'ctrl');
  // CK/8 controller-logic clock on the spare CLKOUT5, only when geared.
  final ctrlGearNet = geared ? bufOut('CLKOUT5', 'ctrlgear') : null;
  return XilinxDdr3Clocks(
    ddrCk: bufOut('CLKOUT0', 'ck'),
    controller: ctrlNet,
    // gearRatio 1: the sequencer clock IS CK/4 (same net, byte-identical).
    controllerClk: ctrlGearNet ?? ctrlNet,
    controllerClkMhz: ctrlGearDivide == null
        ? sol.vco / sol.ctrlDivide / 1e6
        : sol.vco / ctrlGearDivide / 1e6,
    idelayRef: bufOut('CLKOUT2', 'idelayref'),
    ddrCk90: bufOut('CLKOUT3', 'ck90'),
    ddrCkDqs: bufOut('CLKOUT4', 'ckdqs'),
    locked: pll.output('LOCKED'),
    ddrCkMhz: sol.vco / sol.ckDivide / 1e6,
    controllerMhz: sol.vco / sol.ctrlDivide / 1e6,
    idelayRefMhz: sol.vco / sol.refDivide / 1e6,
    vcoMhz: sol.vco / 1e6,
    // Core clock on its own global BUFG (CLKOUT5), only when requested (never
    // together with the geared controller clock; asserted above).
    coreClk: coreDivide == null ? null : bufOut('CLKOUT5', 'core'),
    coreClkMhz: coreDivide == null ? null : sol.vco / coreDivide / 1e6,
  );
}

/// A standalone core/sys clock PLL for the single-oscillator DDR3 boards: a
/// SECOND PLLE2_ADV off the SAME oscillator as the DDR MMCM (both fed from one
/// shared input BUFG so openXC7 accepts two PLLs on the one clock-capable pin).
///
/// This exists because folding the core clock onto a spare CLKOUT of the DDR
/// MMCM makes the core (sys) clock and the DDR controller (ctrl) clock two
/// outputs of ONE VCO, hence phase-locked at a fixed sub-cycle relationship. The
/// async 2-FF gray synchronizer in the sys<->ctrl CDC bridge then sits
/// metastable at that pathological fixed phase and resolves the SAME wrong way,
/// corrupting the crossed read data intermittently (the creek Weir->Ferrite
/// boot coin-flip: the first ifetch of Ferrite's entry comes back as an illegal
/// instruction, mcause=2). Two SEPARATE PLLs each have their own VCO, so their
/// relative phase drifts within the PLL jitter bounds: the crossing is genuinely
/// asynchronous and the 2-FF synchronizer works as designed. A dedicated core
/// PLL also decouples the core frequency from the DDR clock tree (independent
/// CPU frequency scaling).
///
/// [source] must already be BUFG-buffered and shared with the DDR PLL. Returns
/// the (global-BUFG) core clock, the PLL LOCKED, and the realised MHz.
({Logic coreClk, Logic locked, double coreMhz}) buildXilinxCorePll(
  BridgeModule parent, {
  required Logic source,
  required int sourceHz,
  required int coreClkHz,
  String name = 'coreclk',
}) {
  // Solve VCO = sourceHz * mult in the PLLE2 800..1600 MHz band with an integer
  // CLKOUT0 divide (1..128) landing coreClkHz. Prefer the highest in-band VCO
  // (lowest jitter). divclk stays 1 (the source is already a clean osc rate).
  int? bestMult, bestDiv;
  double bestVco = 0;
  for (var mult = 1; mult <= 64; mult++) {
    final vco = sourceHz.toDouble() * mult;
    if (vco < 800e6 || vco > 1600e6) continue;
    final div = (vco / coreClkHz).round();
    if (div < 1 || div > 128) continue;
    // Require the realised rate to be within 0.5% of the request.
    if ((vco / div - coreClkHz).abs() / coreClkHz > 0.005) continue;
    if (vco > bestVco) {
      bestVco = vco;
      bestMult = mult;
      bestDiv = div;
    }
  }
  if (bestMult == null) {
    throw StateError(
      'No PLLE2 core-clock solution for source=$sourceHz core=$coreClkHz '
      '(VCO 800-1600 MHz with an integer CLKOUT0 divide unreachable).',
    );
  }
  final pll = parent.addSubModule(
    XilinxPlle2Adv(
      clkfboutMult: bestMult,
      clkout0Divide: bestDiv!,
      divclkDivide: 1,
      clkinPeriod: 1e9 / sourceHz,
      name: '${name}_pll',
    ),
  );
  pll.input('CLKIN1').srcConnection! <= source;
  pll.input('CLKIN2').srcConnection! <= Const(0);
  pll.input('CLKINSEL').srcConnection! <= Const(1);
  pll.input('CLKFBIN').srcConnection! <= pll.output('CLKFBOUT');
  pll.input('RST').srcConnection! <= Const(0);
  pll.input('PWRDWN').srcConnection! <= Const(0);
  final b = parent.addSubModule(XilinxBufg(name: '${name}_bufg'));
  b.input('I').srcConnection! <= pll.output('CLKOUT0');
  return (
    coreClk: b.output('O'),
    locked: pll.output('LOCKED'),
    coreMhz: bestVco / bestDiv / 1e6,
  );
}

/// Xilinx 7-series BUFG: Global clock buffer.
class XilinxBufg extends BridgeModule {
  XilinxBufg({super.name = 'bufg'}) : super('BUFG', isSystemVerilogLeaf: true) {
    createPort('I', PortDirection.input);
    addOutput('O');
  }
}

/// Xilinx 7-series BUFR: regional clock buffer. The ONLY primitive that can
/// drive an ILOGIC/ISERDESE2 CLKDIV pin (via the HCLK_IOI RCLK tree). A BUFG
/// cannot reach CLKDIV in the 7-series routing DB, so feeding CLKDIV from a BUFG
/// forces the clock onto the contested fabric CLK0 track and the router stalls
/// (overused). BUFR_DIVIDE 'BYPASS' = 1:1, keeping CLKDIV at the CLK rate.
class XilinxBufr extends BridgeModule {
  Logic get o => output('O');
  XilinxBufr({
    required Logic i,
    String bufrDivide = 'BYPASS',
    super.name = 'bufr',
  }) : super('BUFR', isSystemVerilogLeaf: true) {
    createParameter('BUFR_DIVIDE', '"$bufrDivide"');
    createParameter('SIM_DEVICE', '"7SERIES"');
    addInput('I', i);
    addInput('CE', Const(1));
    addInput('CLR', Const(0));
    addOutput('O');
  }
}

/// Xilinx 7-series BUFIO: I/O clock buffer.
///
/// Drives the high-speed IOCLK network from a clock-capable pad (typically a
/// DQS strobe via IBUF), giving a source-synchronous capture clock for the
/// ILOGIC/IDDR C pins in its I/O clock region. Unlike BUFR it has no CLKDIV
/// output and no divider, so it drives an IDDR clock directly (I -> O only, no
/// CE/CLR). Used for a DQS-synchronous DDR read capture.
class XilinxBufio extends BridgeModule {
  Logic get o => output('O');
  XilinxBufio({required Logic i, super.name = 'bufio'})
    : super('BUFIO', isSystemVerilogLeaf: true) {
    addInput('I', i);
    addOutput('O');
  }
}

/// Xilinx 7-series BUFH (BUFHCE): horizontal / regional clock buffer.
///
/// Drives the CLK_HROW leaf-clock tree of ONE clock region. Unlike a BUFG (which
/// lands on the global spine), a BUFH output reaches the HCLK_IOI leaf that feeds
/// the ILOGIC/ISERDESE2 CLK pins directly (HCLK_IOI_CK_BUFHCLK -> IOI_LEAF_GCLK
/// -> IOI_ILOGIC*_CLK). This is the path the HW-verified UberDDR3 bitstream uses
/// for its DDR read clock (7 BUFHCE in its routed .fasm). A plain BUFG feeding 16
/// ILOGIC CLK pins in the DDR bank cannot fan out on the leaf and the router
/// stalls (overused=32, 2 per ISERDESE2). BUFHCE bels ARE placeable on xc7s50
/// (unlike BUFR/BUFIO), so this routes on openXC7. CE tied high (always enabled).
class XilinxBufh extends BridgeModule {
  Logic get o => output('O');
  XilinxBufh({required Logic i, super.name = 'bufh'})
    : super('BUFHCE', isSystemVerilogLeaf: true) {
    // CE is intentionally LEFT UNCONNECTED: the nextpnr-xilinx BUFHCE packer
    // (pack_clocking_xc7.cc: `tie_port(ci, "CE", true, true)`) ties CE to VCC
    // itself, and its tie_port asserts the port has no existing net. Driving CE
    // here (even to Const(1)) trips `NPNR_ASSERT(port.net == nullptr)` and
    // crashes the tool at "Preparing clocking". So expose only I -> O. The SV
    // leaves .CE() open and the packer fills it. Enabled-always in hardware.
    addInput('I', i);
    addOutput('O');
  }
}

/// Xilinx 7-series IBUF: Input buffer.
class XilinxIbuf extends BridgeModule {
  XilinxIbuf({super.name = 'ibuf'}) : super('IBUF', isSystemVerilogLeaf: true) {
    createPort('I', PortDirection.input);
    addOutput('O');
  }
}

/// Xilinx 7-series OBUF: Output buffer. Drives the pad output [o] from the
/// single-ended [i]. Leaving [i] unset keeps the bare open port for callers that
/// wire `.input('I')` directly.
class XilinxObuf extends BridgeModule {
  /// Pad output net.
  Logic get o => output('O');

  XilinxObuf({Logic? i, super.name = 'obuf'})
    : super('OBUF', isSystemVerilogLeaf: true) {
    if (i != null) {
      addInput('I', i);
    } else {
      createPort('I', PortDirection.input);
    }
    addOutput('O');
  }
}

/// Xilinx 7-series OBUFDS: differential output buffer. A single-ended input [i]
/// drives a complementary pad pair: [o] (P) and [ob] (N). The DIFF IO standard
/// (e.g. DIFF_SSTL135) is set by the XDC on the P/N pins, not on the primitive.
///
/// On openXC7 (nextpnr-xilinx pack_io_xc7) this packs to a MASTER OBUF on the
/// IOB33M site driving the P pad from [i], plus a SLAVE OBUF on the paired
/// IOB33S site driving the N pad through the slave IOB output inverter (O_ININV).
/// One source, matched master/slave sites, and the complement generated at the
/// pad, so the P/N pair tracks far better than two independent single-ended
/// OBUFs. This gives the DRAM a clean differential CK so its on-die DLL holds
/// lock at the rated CK speed.
class XilinxObufds extends BridgeModule {
  /// P output pad net.
  Logic get o => output('O');

  /// N output pad net (the complement).
  Logic get ob => output('OB');

  XilinxObufds({Logic? i, super.name = 'obufds'})
    : super('OBUFDS', isSystemVerilogLeaf: true) {
    if (i != null) {
      addInput('I', i);
    } else {
      createPort('I', PortDirection.input);
    }
    addOutput('O');
    addOutput('OB');
  }
}

/// Xilinx 7-series IOBUF: Bidirectional I/O buffer.
///
/// Two forms:
///   - the legacy no-arg form leaves the ports open for the caller to wire (the
///     48 MHz path never used it, but it is kept for source compatibility).
///   - the [i]/[t]/[io] form binds the pad net AS the inOut source at
///     construction (the rohd_bridge idiom: a post-construction `<=` from
///     inOut('IO') does NOT bind it and the `.IO()` emits empty, severing the
///     pad from the buffer, exactly like [Ecp5Bb]). This is the form the
///     DDR3 write path uses so the write OSERDESE2 `.OQ` -> `.I` and its
///     in-site `.TQ` -> `.T` reach the pad with the tristate STILL in the
///     OLOGIC. [t] is active-HIGH = high-Z (drive when [t]=0), matching the
///     OSERDESE2 TQ polarity.
class XilinxIobuf extends BridgeModule {
  /// Pad-read output (the value seen on the bidirectional pad).
  Logic get o => output('O');

  XilinxIobuf({Logic? i, Logic? t, Logic? io, super.name = 'iobuf'})
    : super('IOBUF', isSystemVerilogLeaf: true) {
    if (i != null) {
      addInput('I', i);
    } else {
      createPort('I', PortDirection.input);
    }
    if (t != null) {
      addInput('T', t); // tristate (active HIGH = high-Z)
    } else {
      createPort('T', PortDirection.input);
    }
    addOutput('O');
    if (io != null) {
      // Bind the pad net at construction (source-at-construction idiom).
      addInOut('IO', io);
    } else {
      createPort('IO', PortDirection.inOut);
    }
  }
}

/// Xilinx 7-series IOBUFDS: differential bidirectional I/O buffer (a true diff
/// pair). Drives the complementary pad pair [io] (P) / [iob] (N) from the single-
/// ended [i] when [t]=0 (tristate is active HIGH = high-Z), and returns the
/// received differential value on [o]. Used for the DDR3 DQS strobe, a
/// differential inout. The DIFF_SSTL135 IO standard is set by the XDC on the P/N
/// pins, not the primitive. On openXC7 it packs to master/slave IOB33 sites (the
/// same decomposition as OBUFDS, plus the input path).
class XilinxIobufds extends BridgeModule {
  /// Pad-read output (the received differential value).
  Logic get o => output('O');

  XilinxIobufds({
    Logic? i,
    Logic? t,
    Logic? io,
    Logic? iob,
    super.name = 'iobufds',
  }) : super('IOBUFDS', isSystemVerilogLeaf: true) {
    if (i != null) {
      addInput('I', i);
    } else {
      createPort('I', PortDirection.input);
    }
    if (t != null) {
      addInput('T', t); // tristate (active HIGH = high-Z)
    } else {
      createPort('T', PortDirection.input);
    }
    addOutput('O');
    if (io != null) {
      addInOut('IO', io); // P pad
    } else {
      createPort('IO', PortDirection.inOut);
    }
    if (iob != null) {
      addInOut('IOB', iob); // N pad
    } else {
      createPort('IOB', PortDirection.inOut);
    }
  }
}

/// Xilinx 7-series RAMB36E1: 36Kbit block RAM.
class XilinxRamb36e1 extends BridgeModule {
  XilinxRamb36e1({
    int readWidthA = 36,
    int writeWidthA = 36,
    int readWidthB = 36,
    int writeWidthB = 36,
    super.name = 'bram',
  }) : super('RAMB36E1', isSystemVerilogLeaf: true) {
    // Port A
    createPort('DIADI', PortDirection.input, width: 32);
    createPort('DIPADIP', PortDirection.input, width: 4);
    createPort('ADDRARDADDR', PortDirection.input, width: 16);
    createPort('CLKARDCLK', PortDirection.input);
    createPort('ENARDEN', PortDirection.input);
    createPort('WEA', PortDirection.input, width: 4);
    createPort('REGCEAREGCE', PortDirection.input);
    createPort('RSTRAMARSTRAM', PortDirection.input);
    createPort('DOADO', PortDirection.output, width: 32);
    createPort('DOPADOP', PortDirection.output, width: 4);
    // Port B
    createPort('DIBDI', PortDirection.input, width: 32);
    createPort('DIPBDIP', PortDirection.input, width: 4);
    createPort('ADDRBWRADDR', PortDirection.input, width: 16);
    createPort('CLKBWRCLK', PortDirection.input);
    createPort('ENBWREN', PortDirection.input);
    createPort('WEBWE', PortDirection.input, width: 8);
    createPort('REGCEB', PortDirection.input);
    createPort('RSTRAMB', PortDirection.input);
    createPort('DOBDO', PortDirection.output, width: 32);
    createPort('DOPBDOP', PortDirection.output, width: 4);

    createParameter('READ_WIDTH_A', '$readWidthA');
    createParameter('WRITE_WIDTH_A', '$writeWidthA');
    createParameter('READ_WIDTH_B', '$readWidthB');
    createParameter('WRITE_WIDTH_B', '$writeWidthB');
  }
}

/// Xilinx 7-series BSCANE2: Boundary scan (JTAG) primitive.
class XilinxBscane2 extends BridgeModule {
  XilinxBscane2({int jtagChain = 1, super.name = 'bscan'})
    : super('BSCANE2', isSystemVerilogLeaf: true) {
    addOutput('CAPTURE');
    addOutput('DRCK');
    addOutput('RESET');
    addOutput('RUNTEST');
    addOutput('SEL');
    addOutput('SHIFT');
    addOutput('TCK');
    addOutput('TDI');
    createPort('TDO', PortDirection.input);
    addOutput('TMS');
    addOutput('UPDATE');

    createParameter('JTAG_CHAIN', '$jtagChain');
  }
}

/// Xilinx 7-series STARTUPE2: access to the dedicated configuration pins.
///
/// On 7-series the config-flash SPI clock has no user I/O pad. It is driven
/// onto the dedicated CCLK ball through STARTUPE2's [usrcclko] input (the
/// Xilinx equivalent of the ECP5 USRMCLK macro, used by the SPI-flash
/// controller for XIP). Only ONE STARTUPE2 may exist per design. [usrcclkts]
/// tied low (the default) keeps CCLK always driven. The unused control inputs
/// are tied to their inactive levels and the status outputs left open.
class XilinxStartupe2 extends BridgeModule {
  XilinxStartupe2({
    required Logic usrcclko,
    Logic? usrcclkts,
    super.name = 'startupe2',
  }) : super('STARTUPE2', isSystemVerilogLeaf: true) {
    createParameter('PROG_USR', '"FALSE"');
    createParameter('SIM_CCLK_FREQ', '0.0');
    addInput('CLK', Const(0));
    addInput('GSR', Const(0));
    addInput('GTS', Const(0));
    addInput('KEYCLEARB', Const(1));
    addInput('PACK', Const(0));
    addInput('USRCCLKO', usrcclko);
    addInput('USRCCLKTS', usrcclkts ?? Const(0));
    addInput('USRDONEO', Const(1));
    addInput('USRDONETS', Const(0));
    addOutput('CFGCLK');
    addOutput('CFGMCLK');
    addOutput('EOS');
    addOutput('PREQ');
  }
}

/// Xilinx 7-series XADC: Dual 12-bit analog-to-digital converter.
///
/// Provides on-die temperature and voltage monitoring.
/// Channel 0 = temperature, channel 1 = VCCINT, channel 2 = VCCAUX.
class XilinxXadc extends BridgeModule {
  XilinxXadc({super.name = 'xadc'}) : super('XADC', isSystemVerilogLeaf: true) {
    createPort('DCLK', PortDirection.input);
    createPort('DEN', PortDirection.input);
    createPort('DWE', PortDirection.input);
    createPort('DADDR', PortDirection.input, width: 7);
    createPort('DI', PortDirection.input, width: 16);
    addOutput('DO', width: 16);
    addOutput('DRDY');
    addOutput('OT'); // over-temperature alarm
    addOutput('ALM', width: 8); // alarm outputs
    createPort('CONVST', PortDirection.input);
    createPort('CONVSTCLK', PortDirection.input);
    createPort('RESET', PortDirection.input);
    createPort('VP', PortDirection.input);
    createPort('VN', PortDirection.input);
    addOutput('CHANNEL', width: 5);
    addOutput('EOC');
    addOutput('EOS');
    addOutput('BUSY');
  }
}

/// Xilinx 7-series DSP48E1: DSP slice.
class XilinxDsp48e1 extends BridgeModule {
  XilinxDsp48e1({super.name = 'dsp'})
    : super('DSP48E1', isSystemVerilogLeaf: true) {
    createPort('A', PortDirection.input, width: 30);
    createPort('B', PortDirection.input, width: 18);
    createPort('C', PortDirection.input, width: 48);
    createPort('D', PortDirection.input, width: 25);
    createPort('CLK', PortDirection.input);
    createPort('CEP', PortDirection.input);
    createPort('RSTP', PortDirection.input);
    createPort('OPMODE', PortDirection.input, width: 7);
    createPort('ALUMODE', PortDirection.input, width: 4);
    createPort('P', PortDirection.output, width: 48);
    createPort('PCOUT', PortDirection.output, width: 48);
  }
}

/// Xilinx 7-series ODDR: 1:2 gearing DDR output register.
///
/// With [ddrClkEdge] `"SAME_EDGE"`, [d1] launches on the rising edge of [c]
/// and [d2] on the falling edge (the ECP5 ODDRX1F d0/d1 equivalents).
class XilinxOddr extends BridgeModule {
  Logic get q => output('Q');

  XilinxOddr({
    required Logic c,
    required Logic d1,
    required Logic d2,
    Logic? ce,
    Logic? r,
    String ddrClkEdge = 'SAME_EDGE',
    super.name = 'oddr',
  }) : super('ODDR', isSystemVerilogLeaf: true) {
    createParameter('DDR_CLK_EDGE', '"$ddrClkEdge"');
    createParameter('INIT', "1'b0");
    createParameter('SRTYPE', '"SYNC"');
    addInput('C', c);
    addInput('CE', ce ?? Const(1));
    addInput('D1', d1);
    addInput('D2', d2);
    addInput('R', r ?? Const(0));
    addInput('S', Const(0));
    addOutput('Q');
  }
}

/// Xilinx 7-series IDDR: 1:2 gearing DDR input register.
///
/// With [ddrClkEdge] `"SAME_EDGE"`, [q1] (rising-edge bit) and [q2]
/// (falling-edge bit) of the same beat are presented together on the same [c]
/// edge (the ECP5 IDDRX1F q0/q1 equivalents). SAME_EDGE_PIPELINED (one extra
/// aligned cycle) is NOT used: the open nextpnr-xilinx FASM backend only accepts
/// SAME_EDGE / OPPOSITE_EDGE. The dropped pipeline cycle is absorbed by the PHY
/// read-window slack, which is board-tuned anyway.
class XilinxIddr extends BridgeModule {
  Logic get q1 => output('Q1');
  Logic get q2 => output('Q2');

  XilinxIddr({
    required Logic c,
    required Logic d,
    Logic? ce,
    Logic? r,
    String ddrClkEdge = 'SAME_EDGE',
    super.name = 'iddr',
  }) : super('IDDR', isSystemVerilogLeaf: true) {
    createParameter('DDR_CLK_EDGE', '"$ddrClkEdge"');
    createParameter('INIT_Q1', "1'b0");
    createParameter('INIT_Q2', "1'b0");
    createParameter('SRTYPE', '"SYNC"');
    addInput('C', c);
    addInput('CE', ce ?? Const(1));
    addInput('D', d);
    addInput('R', r ?? Const(0));
    addInput('S', Const(0));
    addOutput('Q1');
    addOutput('Q2');
  }
}

/// Xilinx 7-series OSERDESE2: output serial-to-parallel serializer with an
/// IN-SITE tristate serializer.
///
/// This is the HW-verified UberDDR3 write-datapath primitive (the openXC7 Arty
/// S7 oracle, /tmp/uberddr3_ref/rtl/ddr3_phy.v `OSERDESE2_data`). It replaces
/// the plain [XilinxOddr] + a SHARED FABRIC tristate on the DDR3 write DQ
/// pins, which is what stalled the DDR3 route at overused=32 on the OLOGIC
/// D1 pins: with a plain ODDR + a fabric-LUT tristate, nextpnr's ODDR packer
/// branch (pack_io_xc7.cc) fails to strip `$PACKER_GND_NET` off the OLOGIC spare
/// inputs and double-binds `wr_word[N]` + a GND tie onto `IOI_OLOGIC*_D1`. The
/// OSERDESE2 packer branch DOES strip it, and the in-site tristate keeps data
/// (OQ) and the tristate (TQ) both inside the OLOGIC so D1 never contends.
///
/// Recipe (matches the oracle EXACTLY for the ODELAY-not-supported branch, the
/// only one valid on the xc7s50 HR banks, lines 617-684):
///   - `DATA_RATE_OQ = "DDR"`, `DATA_RATE_TQ = "BUF"` (the in-site tristate: the
///     TQ output is a combinational BUF pass-through of T1, staying in the
///     OLOGIC as `ODDR_TDDR.IN_USE` rather than a routed fabric net),
///   - `DATA_WIDTH = 8` (BL8, 8 beats per CLKDIV cycle), `TRISTATE_WIDTH = 1`,
///   - `SERDES_MODE = "MASTER"`, `INIT_OQ` from the caller (0 for DQ/DM, 1 for
///     DQS so the idle strobe is high),
///   - `.OQ` -> the pad IOBUF `.I` (data), `.TQ` -> the pad IOBUF `.T` (in-site
///     tristate, DM/clock uses that leave TQ open pass `hasTristate: false`),
///   - `.D1..D8` the 8 parallel beats (D1 = FIRST out), `.T1` the tristate
///     control (high = high-Z / read), `.CLK` the fast DDR CK, `.CLKDIV` the
///     controller (CK/4), `.OCE`/`.TCE` tied high, `.RST` the sync reset.
///
/// The resulting FASM for a DQ site is exactly the oracle's write pin block:
/// `OSERDES.IN_USE`, `OSERDES.DATA_RATE_OQ.DDR`, `OSERDES.DATA_RATE_TQ.BUF`,
/// `OSERDES.DATA_WIDTH.DDR.W8`, `ODDR_TDDR.IN_USE`, `OQUSED`, `ZINV_T1`.
///
/// Un-cosimmable SystemVerilog leaf. The fabric write gearbox that feeds D1..D8
/// is verified against [Oserdese2SimModel] at the same serialize contract.
class XilinxOserdese2 extends BridgeModule {
  /// Serialized data output (drives the pad IOBUF `.I`).
  Logic get oq => output('OQ');

  /// In-site tristate output (drives the pad IOBUF `.T`). Only meaningful when
  /// [hasTristate].
  Logic get tq => output('TQ');

  XilinxOserdese2({
    required Logic clk,
    required Logic clkdiv,
    // The parallel beats, LSB-first ([d]0 = D1 = first serialized out). Must be
    // exactly [dataWidth] entries (8 for the DDR data/DQS/DM path, 4 for the SDR
    // command serializer that isolates a command onto ONE CK slot of the 4).
    required List<Logic> d,
    Logic? t1,
    Logic? oce,
    Logic? tce,
    Logic? rst,
    // When false (DM, DQS-less clock, the command serializer, ...) the tristate
    // serializer is not used: T1 ties low, TCE ties low, TQ is left open
    // (matching the oracle's DM OSERDESE2 with `.TCE(1'b0)`, `.T1(0)`, `.TQ()`),
    // so the FASM omits the ODDR_TDDR feature and the pin is a plain driven
    // output.
    bool hasTristate = true,
    // OQ serialize rate + parallel width. The DDR data/DQS/DM path is DDR/8 (the
    // BL8 gearbox, 8 beats over 4 CK). The command path is SDR/4: a 4:1 SERDES on
    // CLK=ck333, CLKDIV=ctrl83 places cs_n low on exactly ONE of the 4 CK rising
    // edges per controller cycle (SDR samples the CK rising edge only), so the
    // DRAM decodes the command once, not four times (the UberDDR3 command SERDES,
    // ddr3_phy.v OSERDESE2_cmd, DATA_WIDTH=4). Defaults keep every existing
    // caller (DDR/8) byte-identical.
    String dataRateOq = 'DDR',
    int dataWidth = 8,
    String initOq = "1'b0",
    // Invert CLK on-chip (IS_CLK_INVERTED). Used for the write DQS OSERDES to
    // clock it on !CK (the exact 180-deg DQS-vs-CK relationship for tDQSS) off
    // the SAME CK net as command/DQ, the UberDDR3 oracle's `.CLK(!i_ddr3_clk)`
    // instead of a separate CLKOUT4 net whose insertion-delay skew pushes DQS
    // off tDQSS.
    bool clkInverted = false,
    super.name = 'oserdes',
  }) : super('OSERDESE2', isSystemVerilogLeaf: true) {
    if (d.length != dataWidth) {
      throw ArgumentError(
        'OSERDESE2 DATA_WIDTH=$dataWidth needs exactly $dataWidth beats.',
      );
    }
    createParameter('DATA_RATE_OQ', '"$dataRateOq"');
    // Always BUF for the tristate rate (matches the oracle's DM OSERDESE2 too,
    // which uses DATA_RATE_TQ("BUF") with TCE=0 and TQ open). BUF keeps the
    // in-site ODDR_TDDR when the tristate is used and is harmless when it is not.
    createParameter('DATA_RATE_TQ', '"BUF"');
    createParameter('DATA_WIDTH', '$dataWidth');
    createParameter('TRISTATE_WIDTH', '1');
    createParameter('SERDES_MODE', '"MASTER"');
    createParameter('INIT_OQ', initOq);
    createParameter('INIT_TQ', "1'b1");
    createParameter('SRVAL_OQ', "1'b0");
    createParameter('SRVAL_TQ', "1'b1");
    createParameter('IS_CLK_INVERTED', clkInverted ? "1'b1" : "1'b0");
    // Clocks.
    addInput('CLK', clk);
    addInput('CLKDIV', clkdiv);
    // Parallel data beats D1..D<dataWidth>. Unused D pins tie low (a DATA_WIDTH=4
    // OSERDESE2 still has D1..D8 ports on the primitive, D5..D8 must be tied).
    for (var i = 0; i < 8; i++) {
      addInput('D${i + 1}', i < dataWidth ? d[i] : Const(0));
    }
    // Tristate control. In-site BUF: T1 -> TQ combinationally, TCE high. When
    // the tristate is unused, T1/TCE tie low and TQ stays open.
    addInput('T1', hasTristate ? (t1 ?? Const(0)) : Const(0));
    addInput('T2', Const(0));
    addInput('T3', Const(0));
    addInput('T4', Const(0));
    addInput('TCE', hasTristate ? (tce ?? Const(1)) : Const(0));
    addInput('TBYTEIN', Const(0));
    // Output clock enable + reset.
    addInput('OCE', oce ?? Const(1));
    addInput('RST', rst ?? Const(0));
    // Serial-expansion inputs tied off for a single-site (MASTER, no cascade).
    addInput('SHIFTIN1', Const(0));
    addInput('SHIFTIN2', Const(0));
    // Outputs. OQ (data) always used, TQ (tristate) only when hasTristate, but
    // always declared so [tq] is addressable. OFB/TFB are feedback outputs.
    addOutput('OQ');
    addOutput('OFB');
    addOutput('TQ');
    addOutput('TFB');
    addOutput('TBYTEOUT');
    addOutput('SHIFTOUT1');
    addOutput('SHIFTOUT2');
  }
}

/// Xilinx 7-series IDELAYE2: input delay line (31 taps).
///
/// This wraps the `IDELAY_TYPE = "FIXED"` static configuration used for the
/// DLL-off read path by default: the pad data [idatain] is delayed by a
/// synthesis-fixed [idelayValue] (the RAMB equivalent of the ECP5 DELAYG static
/// tap). Read training switches this to `IDELAY_TYPE = "VARIABLE"` via
/// [idelayType], walking the tap at runtime through the [ld]/[ce]/[inc] control
/// pins ([ld] loads [idelayValue], [ce]+[inc] step it up, [ce]+~[inc] down) and
/// reading the live tap back on [cntValueOut]. Those ports are OPTIONAL and
/// default to their inactive constants, so an existing FIXED instantiation
/// emits byte-identical SystemVerilog. Every IDELAYE2 needs an
/// [XilinxIdelayctrl] in the design.
class XilinxIdelaye2 extends BridgeModule {
  Logic get dataout => output('DATAOUT');
  Logic get cntValueOut => output('CNTVALUEOUT');

  XilinxIdelaye2({
    required Logic idatain,
    int idelayValue = 0,
    Logic? c,
    double refClkFrequency = 200.0,
    String idelayType = 'FIXED',
    Logic? ce,
    Logic? inc,
    Logic? ld,
    // Absolute 5-bit tap value loaded on an [ld] pulse in VAR_LOAD mode. Ignored
    // (tied 0) in the other modes.
    Logic? cntValueIn,
    // 'DATA' for a data line, 'CLOCK' for a strobe (DQS). A clock-like signal
    // needs the CLOCK pattern for the IDELAY to track it correctly (per UberDDR3,
    // the DQS read IDELAY uses SIGNAL_PATTERN=CLOCK).
    String signalPattern = 'DATA',
    super.name = 'idelay',
  }) : super('IDELAYE2', isSystemVerilogLeaf: true) {
    createParameter('IDELAY_TYPE', '"$idelayType"');
    createParameter('IDELAY_VALUE', '$idelayValue');
    createParameter('DELAY_SRC', '"IDATAIN"');
    createParameter('HIGH_PERFORMANCE_MODE', '"TRUE"');
    createParameter('REFCLK_FREQUENCY', '$refClkFrequency');
    createParameter('CINVCTRL_SEL', '"FALSE"');
    createParameter('PIPE_SEL', '"FALSE"');
    createParameter('SIGNAL_PATTERN', '"$signalPattern"');
    addInput('IDATAIN', idatain);
    addInput('DATAIN', Const(0));
    addInput('C', c ?? Const(0));
    addInput('CE', ce ?? Const(0));
    addInput('INC', inc ?? Const(0));
    addInput('LD', ld ?? Const(0));
    addInput('LDPIPEEN', Const(0));
    addInput('REGRST', Const(0));
    addInput('CINVCTRL', Const(0));
    addInput('CNTVALUEIN', cntValueIn ?? Const(0, width: 5), width: 5);
    addOutput('DATAOUT');
    addOutput('CNTVALUEOUT', width: 5);
  }
}

/// Xilinx 7-series ODELAYE2: the write-path analogue of IDELAYE2 - delays an
/// output ([odatain]) to [dataout] by a calibrated tap. HP (high-performance)
/// banks ONLY; HR banks (Spartan-7, Artix HR) have no ODELAYE2 and use the CK@90
/// write-launch path instead. Selected by [DdrParams.odelaySupported]; unused on
/// the Arty S7 (HR bank). Shares the DDR3-GROUP IODELAY calibration with
/// IDELAYCTRL. Kept for multi-FPGA (HP-bank) support.
class XilinxOdelaye2 extends BridgeModule {
  Logic get dataout => output('DATAOUT');
  Logic get cntValueOut => output('CNTVALUEOUT');

  XilinxOdelaye2({
    required Logic odatain,
    int odelayValue = 0,
    Logic? c,
    double refClkFrequency = 200.0,
    String odelayType = 'FIXED',
    Logic? ce,
    Logic? inc,
    Logic? ld,
    Logic? cntValueIn,
    String signalPattern = 'DATA',
    super.name = 'odelay',
  }) : super('ODELAYE2', isSystemVerilogLeaf: true) {
    createParameter('ODELAY_TYPE', '"$odelayType"');
    createParameter('ODELAY_VALUE', '$odelayValue');
    createParameter('DELAY_SRC', '"ODATAIN"');
    createParameter('HIGH_PERFORMANCE_MODE', '"TRUE"');
    createParameter('REFCLK_FREQUENCY', '$refClkFrequency');
    createParameter('CINVCTRL_SEL', '"FALSE"');
    createParameter('PIPE_SEL', '"FALSE"');
    createParameter('SIGNAL_PATTERN', '"$signalPattern"');
    addInput('ODATAIN', odatain);
    addInput('CLKIN', Const(0));
    addInput('C', c ?? Const(0));
    addInput('CE', ce ?? Const(0));
    addInput('INC', inc ?? Const(0));
    addInput('LD', ld ?? Const(0));
    addInput('LDPIPEEN', Const(0));
    addInput('REGRST', Const(0));
    addInput('CINVCTRL', Const(0));
    addInput('CNTVALUEIN', cntValueIn ?? Const(0, width: 5), width: 5);
    addOutput('DATAOUT');
    addOutput('CNTVALUEOUT', width: 5);
  }
}

/// Xilinx 7-series IDELAYCTRL: calibration reference for the IDELAYE2 taps.
///
/// One per I/O bank that uses IDELAYE2. [refclk] must be the ~200 MHz reference
/// the tap delays are calibrated against. On the board that comes from a
/// dedicated MMCM output (the bring-up build wires the system clock here, which
/// the calibration step on real hardware must correct).
class XilinxIdelayctrl extends BridgeModule {
  Logic get rdy => output('RDY');

  XilinxIdelayctrl({
    required Logic refclk,
    required Logic rst,
    super.name = 'idelayctrl',
  }) : super('IDELAYCTRL', isSystemVerilogLeaf: true) {
    addInput('REFCLK', refclk);
    addInput('RST', rst);
    addOutput('RDY');
  }
}

/// Xilinx 7-series ISERDESE2: input serial-to-parallel deserializer.
///
/// NETWORKING mode, DATA_RATE=DDR. At [dataWidth]=2 the serial clock [clk]
/// equals the fabric clock [clkdiv] (both = clk90), so 2 serial bits (one
/// rising + one falling DQ sample) deserialize per cycle onto Q1/Q2. IOBDELAY
/// "IFD" routes the pad through the IDELAYE2 DATAOUT into [ddly] (D is unused).
/// ALL Q1..Q8 + the scaling ports are wrapped so a later DATA_WIDTH=4/8 build
/// (2x/4x clk over clkdiv) needs no wrapper change. BITSLIP rotates the captured
/// word one position per pulse for glitch-free beat alignment.
class XilinxIserdese2 extends BridgeModule {
  Logic get q1 => output('Q1');
  Logic get q2 => output('Q2');

  XilinxIserdese2({
    required Logic clk,
    required Logic clkb,
    // CLKDIV is OPTIONAL, but a DATA_WIDTH=8 DDR deserializer REQUIRES it: the
    // 8-beat parallel word (Q1..Q8) is loaded and BITSLIP advances on CLKDIV.
    // Left unconnected, that parallel register never clocks and Q1..Q8 FREEZE at
    // their reset value. Every read returns a fixed constant regardless of the
    // captured DQ (HW-confirmed on the Arty DDR3 read: A==B==C == 0x73145241
    // for any write/address/IDELAY/window). EARLIER BELIEF (wrong): a BUFG-net
    // CLKDIV forced all 16 lanes onto the single contended IOI_CLK0 leaf
    // (overused=32) so it was left null to route. But the write OSERDESE2 in the
    // SAME I/O tiles routes its CLKDIV via a BUFH (XilinxBufh) onto the HCLK_IOI
    // clock LEAF fine. The read ISERDESE2 CLKDIV shares that exact BUFH net, so it
    // reaches the ILOGIC leaf and routes. So the read path drives CLKDIV with the
    // shared BUFH'd ctrl83. null is retained only for MEMORY-mode / standalone-
    // wrapper uses that legitimately have no CLKDIV. The sim model still gets a
    // real clkdiv edge so the fabric-side tests deserialize.
    Logic? clkdiv,
    // Serial data from IDELAYE2 (IOBDELAY="IFD"/"BOTH"). Leave null for the OFB
    // train path (IOBDELAY="NONE"), where DDLY is unused and MUST stay open - a
    // GND tie is unrouteable at a fabric-pinned ISERDESE2.
    Logic? ddly,
    required Logic bitslip,
    Logic? ce1,
    Logic? rst,
    int dataWidth = 2,
    String dataRate = 'DDR',
    String interfaceType = 'NETWORKING',
    String iobDelay = 'IFD',
    int numCe = 1,
    // OLOGIC->ILOGIC feedback capture. The bitslip-reference train serdes loops
    // an OSERDESE2's OFB output back into this ISERDESE2 with IOBDELAY="NONE" and
    // OFB_USED="TRUE" to model the ISERDES barrel-shift with no pad involved. Pass
    // the OSERDESE2's OFB net as [ofb] AND set [ofbUsed]; the read data/DQS path
    // leaves both unset so OFB stays an open port (the routing-critical default,
    // see the OFB note below).
    Logic? ofb,
    bool ofbUsed = false,
    super.name = 'iserdes',
  }) : super('ISERDESE2', isSystemVerilogLeaf: true) {
    createParameter('DATA_RATE', '"$dataRate"');
    createParameter('DATA_WIDTH', '$dataWidth');
    createParameter('INTERFACE_TYPE', '"$interfaceType"');
    createParameter('IOBDELAY', '"$iobDelay"');
    createParameter('NUM_CE', '$numCe');
    createParameter('SERDES_MODE', '"MASTER"');
    createParameter('OFB_USED', ofbUsed ? '"TRUE"' : '"FALSE"');
    createParameter('DYN_CLKDIV_INV_EN', '"FALSE"');
    createParameter('DYN_CLK_INV_EN', '"FALSE"');
    // Use the primitive's INTERNAL clock inversion for the complementary pins so
    // CLKB/OCLKB can be driven by the SAME clk net as CLK (no fabric ~clk90
    // net). A separate inverted clock net routed to 16 ILOGIC sites was the
    // structural routing congestion (all seeds stuck at overused=32). With these
    // set, CLKB/OCLKB tie to clk and the ISERDESE2 inverts them on-chip.
    createParameter('IS_CLKB_INVERTED', "1'b1");
    for (final q in [1, 2, 3, 4]) {
      createParameter('INIT_Q$q', "1'b0");
      createParameter('SRVAL_Q$q', "1'b0");
    }
    // Clocks.
    addInput('CLK', clk);
    addInput('CLKB', clkb);
    // Only bind CLKDIV when a driver is given. Left null (the NETWORKING read
    // path) the pin is emitted UNCONNECTED, 0 pips, matching the routed
    // UberDDR3 reference so the design routes on openXC7 (see the ctor doc).
    if (clkdiv != null) {
      addInput('CLKDIV', clkdiv);
    }
    createPort(
      'CLKDIVP',
      PortDirection.input,
    ); // open (unrouteable if GND-tied)
    // OCLK/OCLKB are OUTPUT-serdes clocks that physically exist ONLY in
    // INTERFACE_TYPE("MEMORY"). In NETWORKING (input-only capture) they must be
    // LEFT UNCONNECTED. The BUFG->ILOGIC/OCLKINV arc does not exist in 7-series
    // silicon (correctly absent from the chipdb), so ANY driver (Const OR a clock
    // net) makes the ISERDESE2 unrouteable. Matches UberDDR3's proven Arty S7
    // ISERDESE2 (.OCLK()/.OCLKB() open). So they are intentionally NOT declared.
    // Data ins: D is unused (IFD read path uses DDLY; the OFB train path uses
    // OFB) and MUST be left UNCONNECTED, not tied to GND. Tying D to GND makes
    // the router push $PACKER_GND_NET onto ILOGIC DINV_OUT, which is unrouteable
    // at a fabric-pinned (off-pad) ISERDESE2 like the bitslip-reference train
    // cell. Matches UberDDR3's proven `.D()` open. Declared as an open port.
    createPort('D', PortDirection.input);
    if (ddly != null) {
      addInput('DDLY', ddly);
    } else {
      createPort('DDLY', PortDirection.input);
    }
    // OFB is the OLOGIC->ILOGIC loopback feedback input. With OFB_USED("FALSE")
    // (IFD read path) it MUST be left UNCONNECTED, not tied to GND. Driving it
    // with Const(0) makes the router route $PACKER_GND_NET onto the ILOGIC OFB
    // pin, which back-drives the shared RIOI_OLOGIC_OFB->IOI_OLOGIC_D1 pip and
    // ties GND onto the OLOGIC D1 fabric input, contending with the write
    // OSERDESE2's real D1 net for INT_R.../IMUX34 -> the permanent overused=32
    // (16x OLOGIC_D1 + 16x IMUX34). Declared as an open port (createPort, no
    // driver) so the emitted SV is `.OFB()` open, matching the UberDDR3 oracle.
    // The bitslip-reference train serdes is the exception: OFB_USED="TRUE" with a
    // real OFB loopback net (the OLOGIC->ILOGIC feedback IS the intended path,
    // no pad), so it binds OFB as a driven input.
    if (ofbUsed && ofb != null) {
      addInput('OFB', ofb);
    } else {
      createPort('OFB', PortDirection.input);
    }
    // Control.
    addInput('CE1', ce1 ?? Const(1));
    addInput('CE2', Const(1));
    addInput('BITSLIP', bitslip);
    addInput('RST', rst ?? Const(0));
    // Unused control inputs are left OPEN (not GND-tied): a GND tie on these
    // ILOGIC sitewires is unrouteable at a fabric-pinned (off-pad) ISERDESE2
    // like the bitslip-reference train cell. Matches UberDDR3's proven open
    // `.DYNCLKSEL()/.DYNCLKDIVSEL()/.SHIFTIN1()/.SHIFTIN2()`.
    createPort('DYNCLKSEL', PortDirection.input);
    createPort('DYNCLKDIVSEL', PortDirection.input);
    createPort('SHIFTIN1', PortDirection.input);
    createPort('SHIFTIN2', PortDirection.input);
    // Parallel outs: wrap all Q1..Q8 (Q1/Q2 used at width 2).
    for (var q = 1; q <= 8; q++) {
      addOutput('Q$q');
    }
    addOutput('O');
    addOutput('SHIFTOUT1');
    addOutput('SHIFTOUT2');
  }
}
