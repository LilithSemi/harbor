import 'package:rohd/rohd.dart';

import '../../clock/cdc.dart';
import 'gtp_pcie_phy.dart' show harborCheckPipeStages;
import 'pcie_pipe.dart';
import 'pipe_clock.dart';

typedef _S = HarborGtxResetState;

/// The GTXE2_CHANNEL ports that the PCIe PHY uses.
///
/// The names are the primitive port names, so a wrapper can connect them by
/// name. The GT is the provider. The other ports of the primitive are tie-offs
/// (see `gtxe2ChannelPcieTieOffs`) or direct wires to the pins.
class HarborGtxChannelPorts extends PairInterface {
  HarborGtxChannelPorts()
    : super(
        portsFromProvider: [
          Logic.port('TXOUTCLK'),
          Logic.port('CPLLLOCK'),
          Logic.port('RXCDRLOCK'),
          Logic.port('RXBYTEISALIGNED'),
          Logic.port('TXRESETDONE'),
          Logic.port('RXRESETDONE'),
          Logic.port('TXDLYSRESETDONE'),
          Logic.port('TXPHINITDONE'),
          Logic.port('TXPHALIGNDONE'),
          Logic.port('TXRATEDONE'),
          Logic.port('RXRATEDONE'),
          Logic.port('PHYSTATUS'),
          Logic.port('RXVALID'),
          Logic.port('RXELECIDLE'),
          Logic.port('RXCHANISALIGNED'),
          Logic.port('RXSTATUS', 3),
          Logic.port('RXDATA', 64),
          Logic.port('RXCHARISK', 8),
        ],
        portsFromConsumer: [
          Logic.port('CPLLRESET'),
          Logic.port('GTTXRESET'),
          Logic.port('GTRXRESET'),
          Logic.port('TXUSERRDY'),
          Logic.port('RXUSERRDY'),
          Logic.port('TXUSRCLK'),
          Logic.port('TXUSRCLK2'),
          Logic.port('RXUSRCLK'),
          Logic.port('RXUSRCLK2'),
          Logic.port('CLKRSVD', 4),
          Logic.port('TXDLYSRESET'),
          Logic.port('TXPHINIT'),
          Logic.port('TXPHALIGN'),
          Logic.port('TXDLYEN'),
          Logic.port('TXDETECTRX'),
          Logic.port('TXELECIDLE'),
          Logic.port('RXPOLARITY'),
          Logic.port('TXPD', 2),
          Logic.port('RXPD', 2),
          Logic.port('TXRATE', 3),
          Logic.port('RXRATE', 3),
          Logic.port('TXDATA', 64),
          Logic.port('TXCHARISK', 8),
          Logic.port('TXCHARDISPMODE', 8),
          Logic.port('TXMARGIN', 3),
          Logic.port('TXSWING'),
          Logic.port('TXDEEMPH'),
        ],
      );

  @override
  HarborGtxChannelPorts clone() => HarborGtxChannelPorts();
}

/// States of the GTX reset sequence, as the `reset_state` output shows them.
enum HarborGtxResetState {
  /// The link is ready.
  idle(1),

  /// Wait 64 clocks after PERST# releases.
  cfgWait(0),

  /// CPLLRESET, GTTXRESET and GTRXRESET are high. Wait until CPLLLOCK and
  /// the reset done signals are low.
  cpllReset(2),

  /// CPLLRESET is low. Wait for CPLLLOCK.
  cpllLock(3),

  /// Release GTTXRESET and GTRXRESET.
  gtRelease(4),

  /// Wait for the MMCM lock, and for RXCDRLOCK when the PHY waits for it.
  clockLock(5),

  /// USERRDY is high. Wait for TX and RX reset done.
  resetDone(6),

  /// TXDLYSRESET until TXDLYSRESETDONE rises.
  txDlySReset(7),

  /// TXPHINIT until TXPHINITDONE rises.
  txPhInit(8),

  /// TXPHALIGN until TXPHALIGNDONE rises.
  txPhAlign(9),

  /// TXDLYEN until TXPHALIGNDONE rises again.
  txDlyEn(10),

  /// Only in `reset_fail_state`: a rate change did not complete.
  rateChange(13),

  /// Only in `reset_fail_state`: no failure since PERST#.
  none(15);

  /// Value on the debug outputs.
  final int code;

  const HarborGtxResetState(this.code);

  /// The state with [code].
  static HarborGtxResetState fromCode(int code) =>
      values.firstWhere((s) => s.code == code);
}

/// Bounds, in `pclk` cycles, of the waits in the GTX reset sequence.
///
/// When a wait reaches its bound, the sequence starts again at
/// [HarborGtxResetState.cpllReset]. The defaults are for 125 MHz.
class HarborGtxPcieTimeouts {
  /// Wait for the reset done signals and CPLLLOCK to go low in
  /// [HarborGtxResetState.cpllReset], and for reset done high in
  /// [HarborGtxResetState.resetDone].
  final int resetDone;

  /// Wait for CPLLLOCK.
  final int cpllLock;

  /// Wait for the MMCM lock and RXCDRLOCK.
  final int clockLock;

  /// Each step of the TX phase alignment. UG476 gives no time for a step, so
  /// the default is 2^15 cycles: 262 us at 125 MHz and 131 us at 250 MHz. A
  /// KC705 build with 2^12 cycles (33 us) met the done flags in some tries
  /// and not in others.
  final int txSync;

  /// Cycles that the MMCM lock, and RXCDRLOCK when the PHY waits for it, stay
  /// high in [HarborGtxResetState.clockLock] before USERRDY rises. The user
  /// clocks are then stable when the TX sync starts. UG476 gives no time for
  /// this wait. The default is 2^10 cycles, 8 us at 125 MHz. A lock loss in the wait starts the count again.
  final int clockSettle;

  /// Number of times a TX sync step may time out and restart at
  /// [HarborGtxResetState.txDlySReset] without a new CPLL reset. After that
  /// the next timeout starts the whole sequence again.
  final int syncRetries;

  /// Wait for TXRATEDONE, RXRATEDONE and PHYSTATUS after a rate change.
  final int rate;

  /// Cycles between the `pclk` select change and the new TXRATE and RXRATE.
  /// The glitch free clock mux needs a few cycles of the old and the new clock.
  final int clockSwitch;

  /// Bound of the link training watchdog in Detect. See
  /// [HarborGtpPcieTimeouts] for the meaning, the watchdog is the same. 0
  /// removes the watchdog.
  final int linkWait;

  /// Bound of the link training watchdog in L0.
  final int dataLinkWait;

  const HarborGtxPcieTimeouts({
    this.resetDone = 1 << 17,
    this.cpllLock = 1 << 18,
    this.clockLock = 1 << 17,
    this.txSync = 1 << 15,
    this.syncRetries = 8,
    this.clockSettle = 1 << 10,
    this.rate = 1 << 14,
    this.clockSwitch = 16,
    this.linkWait = 1 << 25,
    this.dataLinkWait = 1 << 27,
  });

  /// Cycles that CPLLRESET stays high at least.
  static const int cpllResetHold = 16;

  List<int> get all => [resetDone, cpllLock, clockLock, txSync, rate];

  /// A name part for the definition of a module that has these timeouts as
  /// constants. Empty when all values are the defaults.
  String get definitionTag {
    const d = HarborGtxPcieTimeouts();
    final values = [
      resetDone,
      cpllLock,
      clockLock,
      txSync,
      syncRetries,
      clockSettle,
      rate,
      clockSwitch,
      linkWait,
      dataLinkWait,
    ];
    final defaults = [
      d.resetDone,
      d.cpllLock,
      d.clockLock,
      d.txSync,
      d.syncRetries,
      d.clockSettle,
      d.rate,
      d.clockSwitch,
      d.linkWait,
      d.dataLinkWait,
    ];
    var same = true;
    var h = 0x811c9dc5;
    for (var i = 0; i < values.length; i++) {
      if (values[i] != defaults[i]) same = false;
      for (final c in '${values[i]},'.codeUnits) {
        h = ((h ^ c) * 0x01000193) & 0xffffffff;
      }
    }
    return same ? '' : 'To${h.toRadixString(16).padLeft(8, '0')}';
  }
}

/// The GTX side and the PIPE side of a PCIe x1 link, with the GTX reset
/// sequence of UG476 and the rate change to 5 GT/s.
///
/// [channel] is the GTXE2_CHANNEL. The sequence runs on `pclk`. PERST# low
/// sets it to [HarborGtxResetState.cfgWait]. The order follows UG476 chapter 2
/// (reset and initialization, power down) and chapter 3 ("TX Buffer Bypass",
/// manual mode):
///
/// 1. Wait 64 clocks.
/// 2. Set CPLLRESET, GTTXRESET and GTRXRESET. Wait until CPLLLOCK and the
///    reset done signals are low. CPLLRESET stays high for 16 cycles at least.
/// 3. Clear CPLLRESET and wait for CPLLLOCK.
/// 4. Clear the GT resets.
/// 5. Wait for the MMCM lock, and for RXCDRLOCK with [waitRxCdrLock].
/// 6. Set TXUSERRDY and RXUSERRDY. Wait for TX and RX reset done high with
///    PHYSTATUS low.
/// 7. TX sync: TXDLYSRESET until its done rises, TXPHINIT until its done
///    rises, TXPHALIGN until TXPHALIGNDONE rises, then TXDLYEN until
///    TXPHALIGNDONE rises again. TXDLYEN stays high in idle.
///
/// Each wait has a bound in [timeouts]. A bound in step 7 starts step 7 again,
/// at most [HarborGtxPcieTimeouts.syncRetries] times in a row. At any other
/// bound, or when CPLLLOCK or the MMCM lock goes low after its wait, the
/// sequence starts again at step 2.
/// `reset_fail_state` holds the state of the last failure and `reset_retries`
/// counts the failures. A bit of `timeout_flags` is high from the first
/// timeout of a wait until PERST#.
///
/// A change of the PIPE rate in idle does these steps with no DRP access:
/// the `pclk` select changes, the PHY waits [HarborGtxPcieTimeouts.clockSwitch]
/// cycles, TXRATE and RXRATE take the new rate (0 for 2.5 GT/s, 1 for 5 GT/s,
/// the dividers of UG476 ch.2), the PHY waits for TXRATEDONE, RXRATEDONE and
/// PHYSTATUS, does the TX sync again, and then gives one PHYSTATUS pulse.
///
/// With [HarborGtxPcieTimeouts.linkWait] above 0, the link watchdog is the
/// same as the one of the GTP PHY. The restart goes to step 2 and counts in
/// `link_retrains`.
///
/// With [clocks] null, the PHY makes [HarborPipeClock] from TXOUTCLK. With
/// [clocks] set, the PHY uses those clocks and the TXOUTCLK port is not
/// used. TXOUTCLK is the reference clock (TXOUTCLKSEL 3, UG476 ch.3).
///
/// [pipeStages] registers go on each PIPE signal between the GT and the hard
/// block, in the two directions. The reset and rate logic see the GT side.
class HarborGtxPciePhy extends Module {
  /// Number of bits of `timeout_flags`.
  static const int timeoutFlagBits = 5;

  /// Number of bits of `rx_debug`.
  static const int rxDebugBits = 15;

  /// Divide value of the user clock MMCM output: 125 MHz at 5 GT/s and 62.5
  /// MHz at 2.5 GT/s, which the hard block needs for a x1 link.
  static int userClkDivide({required bool gen2}) => gen2 ? 8 : 16;

  /// Run at 5 GT/s when the PIPE rate asks for it.
  final bool gen2;

  /// Debug only, and [debugBuild] must be true. Go from [HarborGtxResetState.resetDone] to
  /// [HarborGtxResetState.idle] with no TX phase alignment.
  final bool debugSkipTxPhaseAlign;

  /// Allows the debug options. The constructor throws when a debug option is
  /// set and this is false.
  final bool debugBuild;

  /// Take the MMCM lock from a flop on its input clock, see
  /// [HarborPipeClock.registerLock].
  final bool registerMmcmLock;

  /// Wait for RXCDRLOCK before USERRDY.
  final bool waitRxCdrLock;

  /// Wait for RXRESETDONE and startup PHYSTATUS before TX phase alignment.
  final bool waitForRxResetStatus;

  /// Registers on each PIPE signal, 0 to 2.
  final int pipeStages;

  /// Bounds of the waits.
  final HarborGtxPcieTimeouts timeouts;

  /// Frequency of `userclk1` and `userclk2` in Hz.
  int get userClkHz => HarborPipeClock.userClkHz(userClkDivide(gen2: gen2));

  /// PIPE clock.
  Logic get pclk => output('pclk');

  /// User clock 1.
  Logic get userClk1 => output('userclk1');

  /// User clock 2.
  Logic get userClk2 => output('userclk2');

  /// MMCM lock, not synchronised.
  Logic get mmcmLock => output('mmcm_lock');

  /// 0 for a 125 MHz `pclk` and 1 for a 250 MHz `pclk`.
  Logic get pclkSel => output('pclk_sel');

  /// Current [HarborGtxResetState] code.
  Logic get resetState => output('reset_state');

  /// [HarborGtxResetState] code of the last failure.
  Logic get resetFailState => output('reset_fail_state');

  /// Number of failures since reset, it stops at 255.
  Logic get resetRetries => output('reset_retries');

  /// Synchronised TXRESETDONE.
  Logic get txResetDone => output('tx_reset_done');

  /// Synchronised RXRESETDONE.
  Logic get rxResetDone => output('rx_reset_done');

  /// Bits 0 to 3: synchronised TXDLYSRESETDONE, TXPHINITDONE, TXPHALIGNDONE
  /// and the PHYSTATUS of the GT.
  Logic get txSync => output('tx_sync');

  /// Bits 0 to 2: TXDLYSRESETDONE, TXPHINITDONE and TXPHALIGNDONE were high
  /// since PERST#.
  Logic get txSyncSeen => output('tx_sync_seen');

  /// The PIPE side of the receive path, from bit 0: RXELECIDLE, RXELECIDLE
  /// was low since idle, RXVALID, RXVALID was high since idle, RXBYTEISALIGNED
  /// (synchronised), it was high since idle, RXCHARISK was not 0 with RXVALID
  /// since idle, RXSTATUS (3 bits), power down (2 bits), TXELECIDLE,
  /// TXDETECTRX and the PIPE rate. The "since idle" bits clear while the
  /// reset state is not idle.
  Logic get rxDebug => output('rx_debug');

  /// Number of rising edges of TXPHALIGNDONE since PERST#, it stops at 15.
  Logic get phAlignCount => output('phalign_count');

  /// Bits 0 to 4: a wait timed out in the CPLL reset or CPLL lock, in the
  /// clock lock, in reset done, in the TX sync, in a rate change. A bit stays
  /// high until PERST#.
  Logic get timeoutFlags => output('timeout_flags');

  /// Number of watchdog restarts since PERST# or power-on, it stops at 255.
  /// Null when the watchdog is off.
  Logic? get linkRetrains =>
      timeouts.linkWait == 0 ? null : output('link_retrains');

  /// High when the PIPE side is up.
  Logic get phyReady => output('phy_ready');

  HarborGtxPciePhy({
    required Logic perstN,
    Logic? hardLinkUp,
    Logic? phyLinkUpN,
    Logic? ltssmState,
    required HarborGtxChannelPorts channel,
    required HarborPciePipeLane pipe,
    HarborPipeClocks? clocks,
    Logic? mmcmReset,
    int? mmcmLockTimerBits,
    this.registerMmcmLock = true,
    this.debugSkipTxPhaseAlign = false,
    this.debugBuild = false,
    this.gen2 = true,
    this.waitRxCdrLock = false,
    this.waitForRxResetStatus = true,
    this.pipeStages = 1,
    this.timeouts = const HarborGtxPcieTimeouts(),
    super.name = 'gtx_pcie_phy',
  }) : super(
         definitionName: [
           'HarborGtxPciePhy_X1',
           if (gen2) 'G2',
           if (!registerMmcmLock) 'DirectLock',
           if (debugSkipTxPhaseAlign) 'DebugNoPhAlign',
           if (waitRxCdrLock) 'CdrWait',
           if (!waitForRxResetStatus) 'NoRxRst',
           if (pipeStages != 0) 'Pipe$pipeStages',
           if (timeouts.linkWait != 0) 'LinkWd',
           if (timeouts.definitionTag.isNotEmpty) timeouts.definitionTag,
         ].join('_'),
       ) {
    harborCheckPipeStages(pipeStages);
    if (debugSkipTxPhaseAlign && !debugBuild) {
      throw ArgumentError('debugSkipTxPhaseAlign needs debugBuild');
    }
    for (final t in timeouts.all) {
      if (t < 4) throw ArgumentError.value(t, 'timeouts', 'below 4 cycles');
    }
    if (timeouts.resetDone <= HarborGtxPcieTimeouts.cpllResetHold + 4) {
      throw ArgumentError.value(
        timeouts.resetDone,
        'resetDone',
        'must be above ${HarborGtxPcieTimeouts.cpllResetHold + 4} cycles',
      );
    }
    if (timeouts.clockSwitch < 3 || timeouts.clockSwitch >= timeouts.rate) {
      throw ArgumentError.value(
        timeouts.clockSwitch,
        'clockSwitch',
        'must be 3 or more and below the rate bound',
      );
    }
    if (timeouts.clockSettle < 0 ||
        timeouts.clockSettle + 4 >= timeouts.clockLock) {
      throw ArgumentError.value(
        timeouts.clockSettle,
        'clockSettle',
        'must be 0 or more and 4 below the clockLock bound',
      );
    }
    final linkWait = timeouts.linkWait;
    if (linkWait < 0 || (linkWait > 0 && linkWait < 4)) {
      throw ArgumentError.value(linkWait, 'linkWait', 'must be 0 or 4 and up');
    }
    if (linkWait != 0) {
      if (timeouts.dataLinkWait < 4) {
        throw ArgumentError.value(
          timeouts.dataLinkWait,
          'dataLinkWait',
          'below 4 cycles',
        );
      }
      if (hardLinkUp == null || phyLinkUpN == null || ltssmState == null) {
        throw ArgumentError(
          'hardLinkUp, phyLinkUpN and ltssmState must be given when linkWait '
          'is not 0',
        );
      }
    }

    perstN = addInput('perst_n', perstN);
    final gt = HarborGtxChannelPorts()
      ..pairConnectIO(
        this,
        channel,
        PairRole.consumer,
        uniquify: (n) => 'gt_$n',
      );
    final p = HarborPciePipeLane()
      ..pairConnectIO(
        this,
        pipe,
        PairRole.provider,
        uniquify: (n) => 'pipe_$n',
      );

    // The flop that drives the select of the `pclk` mux is on `pclk`.
    final pclkSelQ = Logic(name: 'pclk_sel_q');
    final HarborPipeClocks clk;
    if (clocks == null) {
      clk = HarborPipeClock(
        txOutClk: gt.port('TXOUTCLK'),
        reset: mmcmReset == null
            ? (~perstN).named('mmcm_rst')
            : (~perstN | addInput('mmcm_reset', mmcmReset)).named('mmcm_rst'),
        userClkDivide: userClkDivide(gen2: gen2),
        lockTimerBits: mmcmLockTimerBits,
        registerLock: registerMmcmLock,
        gen2: gen2,
        oobClock: true,
        pclkSel: gen2 ? pclkSelQ : null,
      ).clocks;
    } else {
      clk = HarborPipeClocks(
        pclk: addInput('pclk_in', clocks.pclk),
        userClk1: addInput('userclk1_in', clocks.userClk1),
        userClk2: addInput('userclk2_in', clocks.userClk2),
        mmcmLock: addInput('mmcm_lock_in', clocks.mmcmLock),
        oobClk: clocks.oobClk == null
            ? null
            : addInput('oob_clk_in', clocks.oobClk!),
      );
    }
    final pclk = clk.pclk;
    addOutput('pclk') <= pclk;
    addOutput('userclk1') <= clk.userClk1;
    addOutput('userclk2') <= clk.userClk2;
    addOutput('mmcm_lock') <= clk.mmcmLock;
    addOutput('pclk_sel') <= pclkSelQ;

    // Power-on reset. FPGA flops are zero after configuration, so these flops
    // need no reset at power-up. The reset holds until the MMCM locks, then
    // for 64 clean cycles. A later lock loss does not set it again.
    // PERST# resets the MMCM and pclk stops, so PERST# also clears these
    // flops without a clock and the hold starts again after the relock.
    final porLock0 = Logic(name: 'por_lock_0');
    final porLock1 = Logic(name: 'por_lock_1');
    final porCount = Logic(name: 'por_count', width: 7);
    Sequential(
      pclk,
      [
        porLock0 < clk.mmcmLock,
        porLock1 < porLock0,
        If(
          ~porCount[6],
          then: [
            If(
              porLock1,
              then: [porCount < porCount + 1],
              orElse: [porCount < 0],
            ),
          ],
        ),
      ],
      reset: ~perstN,
      asyncReset: true,
    );
    final por = (~porCount[6]).named('por_reset');
    final rst = harborCdcJoinReset(pclk, ~perstN, por, name: 'perst_rst');

    Logic sync(Logic d, String name) {
      final s = HarborCdcSync(name: '${name}_sync');
      s.input('async_in').srcConnection! <= d;
      s.input('dst_clk').srcConnection! <= pclk;
      s.input('dst_reset').srcConnection! <= rst;
      return s.syncOut.named(name);
    }

    final cpllLocked = sync(gt.port('CPLLLOCK'), 'cpll_lock_s');
    final cdrLocked = sync(gt.port('RXCDRLOCK'), 'rx_cdr_lock_s');
    final mmcmLocked = sync(clk.mmcmLock, 'mmcm_lock_s');
    final txResetDoneS = sync(gt.port('TXRESETDONE'), 'tx_resetdone_s');
    final rxResetDoneS = sync(gt.port('RXRESETDONE'), 'rx_resetdone_s');
    final dlySDoneS = sync(gt.port('TXDLYSRESETDONE'), 'tx_dlysresetdone_s');
    final phInitDoneS = sync(gt.port('TXPHINITDONE'), 'tx_phinitdone_s');
    final phAlignDoneS = sync(gt.port('TXPHALIGNDONE'), 'tx_phaligndone_s');
    final txRateDoneS = sync(gt.port('TXRATEDONE'), 'tx_ratedone_s');
    final rxRateDoneS = sync(gt.port('RXRATEDONE'), 'rx_ratedone_s');
    final gtPhyStatus = sync(gt.port('PHYSTATUS'), 'gt_phystatus_s');
    final elecIdle = sync(gt.port('RXELECIDLE'), 'rx_elecidle_s');
    final chanAligned = sync(gt.port('RXCHANISALIGNED'), 'rx_chanisaligned_s');

    // Sequence outputs, registered from the next state.
    final cpllRst = Logic(name: 'cpll_reset');
    final gtRst = Logic(name: 'gt_reset');
    final userRdy = Logic(name: 'user_rdy');
    final dlySReset = Logic(name: 'tx_dlysreset');
    final phInit = Logic(name: 'tx_phinit');
    final phAlign = Logic(name: 'tx_phalign');
    final dlyEn = Logic(name: 'tx_dlyen');
    final linkUp = Logic(name: 'link_up');
    final rateQ = Logic(name: 'rate_q');
    final gtRate = Logic(name: 'gt_rate');
    final rateState = Logic(name: 'rate_state', width: 3);
    final rateIdle = rateState.eq(_r(_rIdle)).named('rate_idle');
    final rateDone = rateState.eq(_r(_rDone)).named('rate_done');

    gt.port('CPLLRESET') <= cpllRst;
    gt.port('GTTXRESET') <= gtRst;
    gt.port('GTRXRESET') <= gtRst;
    gt.port('TXUSERRDY') <= userRdy;
    gt.port('RXUSERRDY') <= userRdy;
    gt.port('TXDLYSRESET') <= dlySReset;
    gt.port('TXPHINIT') <= phInit;
    gt.port('TXPHALIGN') <= phAlign;
    gt.port('TXDLYEN') <= dlyEn;
    for (final c in ['TXUSRCLK', 'TXUSRCLK2', 'RXUSRCLK', 'RXUSRCLK2']) {
      gt.port(c) <= pclk;
    }
    gt.port('CLKRSVD') <= [Const(0, width: 3), clk.oobClk ?? pclk].concat();
    gt.port('TXRATE') <= gtRate.zeroExtend(3);
    gt.port('RXRATE') <= gtRate.zeroExtend(3);

    Logic stage(Logic d, String name) => _pipeDelay(pclk, d, pipeStages, name);
    gt.port('TXDATA') <= stage(p.txData, 'txdata').zeroExtend(64);
    gt.port('TXCHARISK') <= stage(p.txDataK, 'txdatak').zeroExtend(8);
    gt.port('TXCHARDISPMODE') <=
        stage(p.txCompliance, 'txcompliance').zeroExtend(8);
    gt.port('TXDETECTRX') <= stage(p.txDetectRx, 'txdetectrx');
    gt.port('TXELECIDLE') <= stage(p.txElecIdle, 'txelecidle');
    gt.port('RXPOLARITY') <= stage(p.rxPolarity, 'rxpolarity');
    final powerDown = stage(p.powerDown, 'powerdown');
    gt.port('TXPD') <= powerDown;
    gt.port('RXPD') <= powerDown;
    gt.port('TXMARGIN') <= stage(p.txMargin, 'txmargin');
    gt.port('TXSWING') <= stage(p.txSwing, 'txswing');
    gt.port('TXDEEMPH') <= stage(p.txDeemph, 'txdeemph');

    p.rxData <= stage(gt.port('RXDATA').slice(15, 0), 'rxdata');
    p.rxDataK <= stage(gt.port('RXCHARISK').slice(1, 0), 'rxdatak');
    p.rxStatus <= stage(gt.port('RXSTATUS'), 'rxstatus');
    p.rxElecIdle <= stage(elecIdle, 'rxelecidle');
    p.rxChanIsAligned <= stage(chanAligned, 'rxchanisaligned');

    // RXVALID goes to the hard block only after the GT holds it high for 16
    // cycles, and only while the link is up.
    final gtValid = gt.port('RXVALID');
    final validCount = Logic(name: 'rxvalid_count', width: 5);
    Sequential(pclk, [
      If(
        gtValid & ~gtRst,
        then: [
          If(~validCount[4], then: [validCount < validCount + 1]),
        ],
        orElse: [validCount < 0],
      ),
    ], reset: rst);
    p.rxValid <= stage(linkUp & validCount[4] & gtValid, 'rxvalid');

    // PHYSTATUS is high while the link is down. During a rate change only the
    // done pulse goes out. It is not synchronised, so it is on the same cycle
    // as RXSTATUS (both are on RXUSRCLK2). The reset logic uses the
    // synchronised copy.
    p.phyStatus <=
        stage(
          ~linkUp | (rateIdle & gt.port('PHYSTATUS')) | rateDone,
          'phystatus',
        );

    final resetLow = ~(txResetDoneS | rxResetDoneS);
    final resetDoneOk = waitForRxResetStatus
        ? txResetDoneS & rxResetDoneS & ~gtPhyStatus
        : txResetDoneS;

    Logic rise(Logic s, String name) {
      final q = Logic(name: '${name}_q');
      Sequential(pclk, [q < s], reset: rst);
      return (s & ~q).named('${name}_rise');
    }

    final dlySDoneRise = rise(dlySDoneS, 'dlysresetdone');
    final phInitDoneRise = rise(phInitDoneS, 'phinitdone');
    final phAlignDoneRise = rise(phAlignDoneS, 'phaligndone');

    final maxWait = [...timeouts.all, 64].reduce((a, b) => a > b ? a : b);
    final tw = maxWait.bitLength;
    final state = Logic(name: 'state', width: 4);
    final next = Logic(name: 'state_next', width: 4);
    final timer = Logic(name: 'timer', width: tw);
    final stepNext = Logic(name: 'step_next', width: 4);
    final timedOut = Logic(name: 'timed_out');
    final rateFail = Logic(name: 'rate_fail');
    final cpllHold = Logic(name: 'cpll_hold');

    Logic s(HarborGtxResetState v) => Const(v.code, width: 4);
    // The timer compares are registered: hit_n is high when the timer was
    // n - 2 in the last cycle. timer_zero is high when the timer was cleared
    // at the last edge, so the timer did not count up.
    final timerZero = Logic(name: 'timer_zero');
    final hits = <int, Logic>{};
    Logic at(int cycles) {
      assert(cycles >= 3, 'timer compare needs 3 or more cycles');
      return hits.putIfAbsent(cycles, () => Logic(name: 'timer_hit_$cycles')) &
          ~timerZero;
    }

    Logic isState(List<HarborGtxResetState> l) =>
        l.map((v) => state.eq(s(v))).reduce((a, b) => a | b);

    CaseItem wait(
      HarborGtxResetState st,
      Logic done,
      HarborGtxResetState to,
      int bound,
    ) => CaseItem(s(st), [
      If.block([
        Iff(done, [stepNext < s(to)]),
        ElseIf(at(bound), [timedOut < 1]),
      ]),
    ]);

    // The lock must stay up for clockSettle cycles in clockLock.
    final clockOk = (mmcmLocked & (waitRxCdrLock ? cdrLocked : Const(1))).named(
      'clock_ok',
    );
    final settleCount = Logic(
      name: 'settle_count',
      width: timeouts.clockSettle.bitLength + 1,
    );
    Sequential(pclk, [
      If(
        state.eq(s(_S.clockLock)) & clockOk,
        then: [
          If(
            ~settleCount.eq(
              Const(timeouts.clockSettle, width: settleCount.width),
            ),
            then: [settleCount < settleCount + 1],
          ),
        ],
        orElse: [settleCount < 0],
      ),
    ], reset: rst);
    final settled = settleCount.eq(
      Const(timeouts.clockSettle, width: settleCount.width),
    );

    final afterCpllLock = isState([
      _S.gtRelease,
      _S.clockLock,
      _S.resetDone,
      _S.txDlySReset,
      _S.txPhInit,
      _S.txPhAlign,
      _S.txDlyEn,
      _S.idle,
    ]);
    final afterMmcmLock = isState([
      _S.resetDone,
      _S.txDlySReset,
      _S.txPhInit,
      _S.txPhAlign,
      _S.txDlyEn,
      _S.idle,
    ]);
    final lostLock =
        (afterCpllLock & ~cpllLocked) | (afterMmcmLock & ~mmcmLocked);
    final rateTake = rateState.eq(_r(_rTake));

    Combinational([
      stepNext < state,
      timedOut < 0,
      Case(
        state,
        [
          CaseItem(s(_S.cfgWait), [
            If(at(64), then: [stepNext < s(_S.cpllReset)]),
          ]),
          wait(
            _S.cpllReset,
            resetLow & ~cpllLocked & cpllHold,
            _S.cpllLock,
            timeouts.resetDone,
          ),
          wait(_S.cpllLock, cpllLocked, _S.gtRelease, timeouts.cpllLock),
          CaseItem(s(_S.gtRelease), [stepNext < s(_S.clockLock)]),
          wait(
            _S.clockLock,
            clockOk & settled,
            _S.resetDone,
            timeouts.clockLock,
          ),
          wait(
            _S.resetDone,
            resetDoneOk,
            debugSkipTxPhaseAlign ? _S.idle : _S.txDlySReset,
            timeouts.resetDone,
          ),
          wait(_S.txDlySReset, dlySDoneRise, _S.txPhInit, timeouts.txSync),
          wait(_S.txPhInit, phInitDoneRise, _S.txPhAlign, timeouts.txSync),
          wait(_S.txPhAlign, phAlignDoneRise, _S.txDlyEn, timeouts.txSync),
          wait(_S.txDlyEn, phAlignDoneRise, _S.idle, timeouts.txSync),
          CaseItem(s(_S.idle), [
            If(
              rateTake & ~Const(debugSkipTxPhaseAlign ? 1 : 0),
              then: [stepNext < s(_S.txDlySReset)],
            ),
          ]),
        ],
        defaultItem: [timedOut < 1],
      ),
    ]);
    // A failure is registered, so it starts the retry one cycle after the
    // cause. The cycle after a failure cannot fail again, so a lock loss
    // counts once.
    final holdHit = at(HarborGtxPcieTimeouts.cpllResetHold);
    final failNow = (timedOut | lostLock | rateFail).named('fail_now');
    final fail = Logic(name: 'fail');
    final failCause = Logic(name: 'fail_cause', width: 4);
    Logic causeInSync(Logic c) => [
      _S.txDlySReset,
      _S.txPhInit,
      _S.txPhAlign,
      _S.txDlyEn,
    ].map((v) => c.eq(s(v))).reduce((a, b) => a | b);
    final failTimeout = Logic(name: 'fail_timeout');
    // A watchdog restart takes the retry path, but it is not a failure.
    final restart = timeouts.linkWait == 0 ? null : Logic(name: 'link_restart');
    final failOrRestart = restart == null ? fail : fail | restart;
    // A timeout in a TX sync step starts the sync again, up to
    // [HarborGtxPcieTimeouts.syncRetries] times in a row. A lock loss, a
    // watchdog restart and any other timeout start the whole sequence.
    final syncTries = Logic(name: 'sync_tries', width: 8);
    final syncRetry =
        (fail &
                failTimeout &
                causeInSync(failCause) &
                syncTries.lt(Const(timeouts.syncRetries, width: 8)) &
                (restart == null ? Const(1) : ~restart))
            .named('sync_retry');
    final fullFail = (failOrRestart & ~syncRetry).named('full_fail');
    next <=
        mux(
          syncRetry,
          s(_S.txDlySReset),
          mux(fullFail, s(_S.cpllReset), stepNext),
        );

    Logic nextIs(List<HarborGtxResetState> l) =>
        l.map((v) => next.eq(s(v))).reduce((a, b) => a | b);

    final failState = Logic(name: 'fail_state', width: 4);
    final retries = Logic(name: 'retries', width: 8);
    final flags = Logic(name: 'timeout_flags_q', width: timeoutFlagBits);
    Logic causeIs(List<HarborGtxResetState> l) =>
        l.map((v) => failCause.eq(s(v))).reduce((a, b) => a | b);
    final causeFlags = [
      causeIs([_S.cpllReset, _S.cpllLock]),
      causeIs([_S.clockLock]),
      causeIs([_S.resetDone]),
      causeIs([_S.txDlySReset, _S.txPhInit, _S.txPhAlign, _S.txDlyEn]),
      causeIs([_S.rateChange]),
    ];
    Sequential(
      pclk,
      [
        state < next,
        If(
          syncRetry,
          then: [syncTries < syncTries + 1],
          orElse: [
            If(fullFail | nextIs([_S.idle]), then: [syncTries < 0]),
          ],
        ),
        fail < failNow & ~fail,
        failTimeout < (timedOut | rateFail),
        failCause < mux(rateFail, s(_S.rateChange), state),
        timerZero < fail | ~next.eq(state),
        for (final MapEntry(key: n, value: hit) in hits.entries)
          hit < timer.eq(Const(n - 2, width: tw)),
        If(
          fail | ~next.eq(state),
          then: [timer < 0],
          orElse: [
            If(~state.eq(s(_S.idle)), then: [timer < timer + 1]),
          ],
        ),
        cpllHold < (state.eq(s(_S.cpllReset)) & (cpllHold | holdHit)),
        If(
          fail,
          then: [
            failState < failCause,
            If(~retries.and(), then: [retries < retries + 1]),
            If(
              failTimeout,
              then: [
                flags <
                    [for (final f in causeFlags.reversed) f].concat() | flags,
              ],
            ),
          ],
        ),
        cpllRst < nextIs([_S.cpllReset]),
        gtRst < nextIs([_S.cpllReset, _S.cpllLock]),
        userRdy <
            nextIs([
              _S.resetDone,
              _S.txDlySReset,
              _S.txPhInit,
              _S.txPhAlign,
              _S.txDlyEn,
              _S.idle,
            ]),
        dlySReset < nextIs([_S.txDlySReset]),
        phInit < nextIs([_S.txPhInit]),
        phAlign < nextIs([_S.txPhAlign]),
        dlyEn <
            nextIs(
              debugSkipTxPhaseAlign ? [_S.txDlyEn] : [_S.txDlyEn, _S.idle],
            ),
      ],
      reset: rst,
      resetValues: {
        state: s(_S.cfgWait),
        failState: s(_S.none),
        timerZero: Const(1),
      },
    );

    // Rate change. The hard block drives one rate. The `pclk` select changes
    // first, then TXRATE and RXRATE.
    final rateTimer = Logic(name: 'rate_timer', width: timeouts.rate.bitLength);
    final txRateSeen = Logic(name: 'tx_rate_seen');
    final rxRateSeen = Logic(name: 'rx_rate_seen');
    final phySeen = Logic(name: 'phy_seen');
    final rateChange = (rateQ ^ gtRate).named('rate_change');
    final idleNow = state.eq(s(_S.idle));
    // rate_hit is high when the timer was rate - 2 in wait in the last
    // cycle. In wait the timer counts up on each cycle.
    final rateHit = Logic(name: 'rate_hit');
    final rateWait = rateState.eq(_r(_rWait));
    rateFail <= rateWait & rateHit;
    final rw = timeouts.rate.bitLength;
    Sequential(pclk, [
      rateQ < _pipeDelay(pclk, p.pipeRate, pipeStages, 'rate'),
      rateHit < rateWait & rateTimer.eq(Const(timeouts.rate - 2, width: rw)),
      If(
        fullFail,
        then: [rateState < _r(_rIdle), rateTimer < 0, gtRate < 0, pclkSelQ < 0],
        orElse: [
          Case(
            rateState,
            [
              CaseItem(_r(_rIdle), [
                If(
                  rateChange & idleNow,
                  then: [
                    rateState < _r(_rSwitch),
                    rateTimer < 0,
                    pclkSelQ < rateQ,
                  ],
                ),
              ]),
              CaseItem(_r(_rSwitch), [
                rateTimer < rateTimer + 1,
                If(
                  rateTimer.eq(Const(timeouts.clockSwitch - 1, width: rw)),
                  then: [
                    gtRate < rateQ,
                    rateState < _r(_rWait),
                    rateTimer < 0,
                    txRateSeen < 0,
                    rxRateSeen < 0,
                    phySeen < 0,
                  ],
                ),
              ]),
              CaseItem(_r(_rWait), [
                rateTimer < rateTimer + 1,
                If(txRateDoneS, then: [txRateSeen < 1]),
                If(rxRateDoneS, then: [rxRateSeen < 1]),
                If(gtPhyStatus, then: [phySeen < 1]),
                If(
                  txRateSeen & rxRateSeen & phySeen,
                  then: [rateState < _r(_rTake)],
                ),
              ]),
              CaseItem(_r(_rTake), [
                If(
                  ~idleNow | Const(debugSkipTxPhaseAlign ? 1 : 0),
                  then: [rateState < _r(_rBack)],
                ),
              ]),
              CaseItem(_r(_rBack), [
                If(idleNow, then: [rateState < _r(_rDone)]),
              ]),
              CaseItem(_r(_rDone), [rateState < _r(_rIdle)]),
            ],
            defaultItem: [rateState < _r(_rIdle)],
          ),
        ],
      ),
      linkUp <
          (nextIs([_S.idle]) | ~rateState.eq(_r(_rIdle))) &
              ~fullFail &
              ~failNow,
    ], reset: rst);

    addOutput('reset_state', width: 4) <= state;
    addOutput('reset_fail_state', width: 4) <= failState;
    addOutput('reset_retries', width: 8) <= retries;
    addOutput('phy_ready') <= linkUp;
    final seen = Logic(name: 'tx_sync_seen_q', width: 3);
    final alignCount = Logic(name: 'phalign_count_q', width: 4);
    Sequential(pclk, [
      seen < (seen | [phAlignDoneS, phInitDoneS, dlySDoneS].concat()),
      If(
        phAlignDoneRise & ~alignCount.and(),
        then: [alignCount < alignCount + 1],
      ),
    ], reset: rst);
    addOutput('tx_sync', width: 4) <=
        [gtPhyStatus, phAlignDoneS, phInitDoneS, dlySDoneS].concat();
    addOutput('tx_sync_seen', width: 3) <= seen;
    addOutput('phalign_count', width: 4) <= alignCount;
    final rxIdleSeen = Logic(name: 'rx_debug_seen', width: 4);
    final byteAligned = sync(gt.port('RXBYTEISALIGNED'), 'rx_byteisaligned_s');
    final rxValidOut = p.rxValid;
    final kSeen = (p.rxDataK.or() & rxValidOut);
    Sequential(pclk, [
      If(
        ~state.eq(s(_S.idle)),
        then: [rxIdleSeen < 0],
        orElse: [
          rxIdleSeen <
              (rxIdleSeen |
                  [kSeen, byteAligned, rxValidOut, ~p.rxElecIdle].concat()),
        ],
      ),
    ], reset: rst);
    addOutput('rx_debug', width: rxDebugBits) <=
        [
          p.pipeRate,
          p.txDetectRx,
          p.txElecIdle,
          p.powerDown,
          p.rxStatus,
          rxIdleSeen[3],
          rxIdleSeen[2],
          byteAligned,
          rxIdleSeen[1],
          rxValidOut,
          rxIdleSeen[0],
          p.rxElecIdle,
        ].concat();
    addOutput('tx_reset_done') <= txResetDoneS;
    addOutput('rx_reset_done') <= rxResetDoneS;
    addOutput('timeout_flags', width: timeoutFlagBits) <= flags;

    if (restart == null) return;
    final hardUp = sync(
      addInput('hard_link_up', hardLinkUp!),
      'hard_link_up_s',
    );
    final phyUp = sync(
      ~addInput('phy_link_up_n', phyLinkUpN!),
      'phy_link_up_s',
    );
    final ltssm = HarborCdcSync(width: 6, name: 'ltssm_state_sync');
    ltssm.input('async_in').srcConnection! <=
        addInput('ltssm_state', ltssmState!, width: 6);
    ltssm.input('dst_clk').srcConnection! <= pclk;
    ltssm.input('dst_reset').srcConnection! <= rst;
    final ltssmS = ltssm.syncOut.named('ltssm_state_s');
    final ltssmQ = Logic(name: 'ltssm_state_q', width: 6);
    final inDetect = Logic(name: 'ltssm_detect');
    // Codes 0 to 3 are the Detect states (PG054).
    Sequential(pclk, [
      ltssmQ < ltssmS,
      inDetect < ltssmS.eq(ltssmQ) & ltssmS.getRange(2).eq(0),
    ], reset: rst);

    final dlDown = (linkUp & ~hardUp).named('dl_down');
    final training = (dlDown & ~phyUp).named('link_training');
    final detectRestart = _watch(
      pclk,
      rst,
      'detect',
      timeouts.linkWait,
      run: training & inDetect,
      clear: ~training,
    );
    final l0 = (dlDown & phyUp).named('link_l0_dl_down');
    final l0Restart = _watch(
      pclk,
      rst,
      'l0',
      timeouts.dataLinkWait,
      run: l0,
      clear: ~l0,
    );
    restart <= detectRestart | l0Restart;
    final linkRetrains = Logic(name: 'link_retrains', width: 8);
    Sequential(pclk, [
      If(
        restart & ~linkRetrains.and(),
        then: [linkRetrains < linkRetrains + 1],
      ),
    ], reset: rst);
    addOutput('link_retrains', width: 8) <= linkRetrains;
  }

  /// A timer that counts while [run] is high, holds while [run] and [clear]
  /// are low, and goes to 0 while [clear] is high. The result is high on the
  /// first cycle with [run] high after [bound] counted cycles.
  static Logic _watch(
    Logic clk,
    Logic reset,
    String name,
    int bound, {
    required Logic run,
    required Logic clear,
  }) {
    final w = bound.bitLength;
    final timer = Logic(name: '${name}_timer', width: w);
    final hit = Logic(name: '${name}_hit');
    Sequential(clk, [
      If(
        clear,
        then: [timer < 0, hit < 0],
        orElse: [
          If(
            run & ~hit,
            then: [
              timer < timer + 1,
              hit < timer.eq(Const(bound - 1, width: w)),
            ],
          ),
        ],
      ),
    ], reset: reset);
    return (hit & run).named('${name}_restart');
  }

  static const _rIdle = 0;
  static const _rSwitch = 1;
  static const _rWait = 2;
  static const _rTake = 3;
  static const _rBack = 4;
  static const _rDone = 5;

  static Logic _r(int v) => Const(v, width: 3);
}

/// Puts [stages] registers on [d], with no reset.
Logic _pipeDelay(Logic clk, Logic d, int stages, String name) {
  var q = d;
  for (var i = 0; i < stages; i++) {
    final r = Logic(name: '${name}_stage$i', width: d.width);
    Sequential(clk, [r < q]);
    q = r;
  }
  return q;
}
