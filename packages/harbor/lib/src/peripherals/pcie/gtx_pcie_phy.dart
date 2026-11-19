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

  /// TXDLYSRESET until TXDLYSRESETDONE rises. TXDLYSRESET stays low for
  /// [HarborGtxPcieTimeouts.txSettle] cycles after the state starts.
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
  /// this wait. The default is 2^10 cycles, 8 us at 125 MHz. A lock loss in
  /// the wait starts the count again.
  final int clockSettle;

  /// Cycles between the start of [HarborGtxResetState.txDlySReset] and the
  /// rise of TXDLYSRESET, on each start of the TX sync. TXUSERRDY, the user
  /// clocks and the TX reset are then stable when the phase alignment starts.
  /// UG476 ch.3 (TX buffer bypass, manual TX phase alignment) gives the
  /// order of the alignment steps but no time for this wait. The default is
  /// 2^10 cycles: 8 us at 125 MHz. A KC705 build with no wait had one TXPHINIT
  /// retry before the link came up. 0 removes the wait. The count is part of
  /// the [txSync] bound of the step. A done pulse in the wait is ignored.
  final int txSettle;

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
    this.txSettle = 1 << 10,
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
      txSettle,
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
      d.txSettle,
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

  /// Divide value for a user clock of [hz], or the default of [gen2] with
  /// null. [hz] is 62.5, 125 or 250 MHz.
  static int userClkDivideFor({required bool gen2, int? hz}) {
    if (hz == null) return userClkDivide(gen2: gen2);
    if (!HarborPipeClock.x1UserClkHz.contains(hz)) {
      throw ArgumentError.value(
        hz,
        'userClkHz',
        'must be 62.5, 125 or 250 MHz',
      );
    }
    return HarborPipeClock.vcoHz ~/ hz;
  }

  /// The user clock divide of this PHY.
  final int userClkDivideValue;

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
  int get userClkHz => HarborPipeClock.userClkHz(userClkDivideValue);

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
    int? userClkHz,
    this.waitRxCdrLock = false,
    this.waitForRxResetStatus = true,
    this.pipeStages = 1,
    this.timeouts = const HarborGtxPcieTimeouts(),
    super.name = 'gtx_pcie_phy',
  }) : userClkDivideValue = userClkDivideFor(gen2: gen2, hz: userClkHz),
       super(
         definitionName: [
           'HarborGtxPciePhy_X1',
           if (gen2) 'G2',
           if (userClkHz != null &&
               userClkHz != HarborPipeClock.vcoHz ~/ userClkDivide(gen2: gen2))
             'Uc${userClkHz ~/ 1000}',
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
    if (timeouts.txSettle < 0 || timeouts.txSettle + 4 >= timeouts.txSync) {
      throw ArgumentError.value(
        timeouts.txSettle,
        'txSettle',
        'must be 0 or more and 4 below the txSync bound',
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
        userClkDivide: userClkDivideValue,
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
    final rIdle = Logic(name: 'rate_idle');
    final rSwitch = Logic(name: 'rate_switch');
    final rWait = Logic(name: 'rate_wait');
    final rTake = Logic(name: 'rate_take');
    final rBack = Logic(name: 'rate_back');
    final rDone = Logic(name: 'rate_done');
    final rateIdle = rIdle;
    final rateDone = rDone;

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
    final timer = Logic(name: 'timer', width: tw);
    final cpllHold = Logic(name: 'cpll_hold');
    Logic orAll(Iterable<Logic> l) =>
        l.isEmpty ? Const(0) : l.reduce((a, b) => a | b);
    Logic andAll(Iterable<Logic> l) =>
        l.isEmpty ? Const(1) : l.reduce((a, b) => a & b);

    // Each decision is a flop and the flop that applies it is later, so no
    // flop input is behind a chain of compares. A compare of a counter with
    // a constant is a row of flops that each compare 5 bits.
    List<Logic> chunkEq(String name, Logic count, int value, Logic mask) {
      final out = <Logic>[];
      for (var lo = 0, i = 0; lo < count.width; lo += 5, i++) {
        final hi = lo + 5 < count.width ? lo + 5 : count.width;
        final q = Logic(name: '${name}_c$i');
        final part = Const(
          (value >> lo) & ((1 << (hi - lo)) - 1),
          width: hi - lo,
        );
        Sequential(pclk, [
          q < (count.slice(hi - 1, lo).eq(part) & mask),
        ], reset: rst);
        out.add(q);
      }
      return out;
    }

    final order = [
      _S.cfgWait,
      _S.cpllReset,
      _S.cpllLock,
      _S.gtRelease,
      _S.clockLock,
      _S.resetDone,
      _S.txDlySReset,
      _S.txPhInit,
      _S.txPhAlign,
      _S.txDlyEn,
      _S.idle,
    ];
    final st = {for (final v in order) v: Logic(name: 's_${v.name}')};
    final go = {for (final v in order) v: Logic(name: 'go_${v.name}')};
    final target = <_S, _S>{
      _S.cfgWait: _S.cpllReset,
      _S.cpllReset: _S.cpllLock,
      _S.cpllLock: _S.gtRelease,
      _S.gtRelease: _S.clockLock,
      _S.clockLock: _S.resetDone,
      _S.resetDone: debugSkipTxPhaseAlign ? _S.idle : _S.txDlySReset,
      _S.txDlySReset: _S.txPhInit,
      _S.txPhInit: _S.txPhAlign,
      _S.txPhAlign: _S.txDlyEn,
      _S.txDlyEn: _S.idle,
      _S.idle: _S.txDlySReset,
    };
    final sIdle = st[_S.idle]!;

    // A failure goes through flops: a cause, a failure, then the retry or the
    // restart that changes the state.
    final tmoK = {
      for (final v in [
        _S.cpllReset,
        _S.cpllLock,
        _S.clockLock,
        _S.resetDone,
        _S.txDlySReset,
        _S.txPhInit,
        _S.txPhAlign,
        _S.txDlyEn,
      ])
        v: Logic(name: 'tmo_k_${v.name}'),
    };
    final lostK = Logic(name: 'fail_lost_k');
    final rateK = Logic(name: 'fail_rate_k');
    final wdK = Logic(name: 'fail_wd_k');
    final wdPend = Logic(name: 'fail_wd_pend');
    final badQ = Logic(name: 'fail_onehot_q');
    final tmoQ = Logic(name: 'fail_tmo_q');
    final lostQ = Logic(name: 'fail_lost_q');
    final rateQf = Logic(name: 'fail_rate_q');
    final wdQ = Logic(name: 'fail_wd_q');
    final failQ = Logic(name: 'fail');
    final wd2Q = Logic(name: 'fail_wd2_q');
    final retryQ = Logic(name: 'retry_q');
    final fullQ = Logic(name: 'full_q');
    final blockQ = Logic(name: 'fail_block_q');
    final ovr = (retryQ | fullQ).named('fail_apply');
    final clrPa = Logic(name: 'timer_clr_pa');
    final clrPb = Logic(name: 'timer_clr_pb');
    final clrPc = Logic(name: 'timer_clr_pc');
    final clrQ = Logic(name: 'timer_clr_q');
    final clrQ2 = Logic(name: 'timer_clr_q2');

    // hit is high from `lead` cycles before the timer counts n cycles.
    final hits = <String, Logic>{};
    Logic at(int cycles, int lead) {
      assert(cycles > lead + 2, 'timer compare needs more cycles');
      return hits.putIfAbsent('${cycles}_$lead', () {
        final h = Logic(name: 'timer_hit_${cycles}_$lead');
        final chunks = chunkEq(
          'timer_eq_${cycles}_$lead',
          timer,
          cycles - lead,
          ~clrQ,
        );
        Sequential(pclk, [h < (~clrQ & (h | andAll(chunks)))], reset: rst);
        return h;
      });
    }

    final clockOk = (mmcmLocked & (waitRxCdrLock ? cdrLocked : Const(1))).named(
      'clock_ok',
    );
    final settleCount = Logic(
      name: 'settle_count',
      width: timeouts.clockSettle.bitLength + 1,
    );
    final settled = Logic(name: 'settled');
    final settleRun = (st[_S.clockLock]! & clockOk).named('settle_run');
    final settleChunks = chunkEq(
      'settle_eq',
      settleCount,
      timeouts.clockSettle > 2 ? timeouts.clockSettle - 2 : 0,
      settleRun,
    );
    Sequential(pclk, [
      If(
        settleRun,
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
      settled < (settleRun & (settled | andAll(settleChunks))),
    ], reset: rst);

    final txSettleCount = Logic(
      name: 'tx_settle_count',
      width: timeouts.txSettle.bitLength + 1,
    );
    final txSettled = Logic(name: 'tx_settled');
    final syncRun = (st[_S.txDlySReset]! & ~failQ & ~retryQ).named('sync_run');
    final txSettleChunks = chunkEq(
      'tx_settle_eq',
      txSettleCount,
      timeouts.txSettle > 2 ? timeouts.txSettle - 2 : 0,
      syncRun,
    );
    Sequential(pclk, [
      If(
        syncRun,
        then: [
          If(
            ~txSettleCount.eq(
              Const(timeouts.txSettle, width: txSettleCount.width),
            ),
            then: [txSettleCount < txSettleCount + 1],
          ),
        ],
        orElse: [txSettleCount < 0],
      ),
      txSettled < (syncRun & (txSettled | andAll(txSettleChunks))),
    ], reset: rst);

    // Wait ends, from flops, one cycle old.
    final done = <_S, Logic>{};
    Logic doneFlop(_S v, String name, Logic d) {
      final q = Logic(name: 'done_$name');
      Sequential(pclk, [q < d], reset: rst);
      return done[v] = q;
    }

    done[_S.cfgWait] = at(64, 5);
    doneFlop(_S.cpllReset, 'cpll_reset', resetLow & ~cpllLocked & cpllHold);
    doneFlop(_S.cpllLock, 'cpll_lock', cpllLocked);
    done[_S.gtRelease] = Const(1);
    doneFlop(_S.clockLock, 'clock_lock', clockOk & settled);
    doneFlop(_S.resetDone, 'reset_done', resetDoneOk);
    doneFlop(_S.txDlySReset, 'dlysreset', dlySDoneRise & dlySReset);
    doneFlop(_S.txPhInit, 'phinit', phInitDoneRise);
    final phAlignDone = doneFlop(_S.txPhAlign, 'phalign', phAlignDoneRise);
    done[_S.txDlyEn] = phAlignDone;
    if (debugSkipTxPhaseAlign) {
      done[_S.idle] = Const(0);
    } else {
      doneFlop(_S.idle, 'take', rTake);
    }
    final holdCount = Logic(
      name: 'cpll_hold_count',
      width: HarborGtxPcieTimeouts.cpllResetHold.bitLength,
    );

    final bound = <_S, int>{
      _S.cpllReset: timeouts.resetDone,
      _S.cpllLock: timeouts.cpllLock,
      _S.clockLock: timeouts.clockLock,
      _S.resetDone: timeouts.resetDone,
      _S.txDlySReset: timeouts.txSync,
      _S.txPhInit: timeouts.txSync,
      _S.txPhAlign: timeouts.txSync,
      _S.txDlyEn: timeouts.txSync,
    };

    final goD = {
      for (final v in order)
        v: (st[v]! & done[v]! & ~go[v]! & ~blockQ).named('go_d_${v.name}'),
    };
    final tmoD = {
      for (final e in bound.entries)
        e.key:
            (st[e.key]! &
                    ~done[e.key]! &
                    at(e.value, 8) &
                    ~go[e.key]! &
                    ~blockQ)
                .named('tmo_d_${e.key.name}'),
    };
    final afterCpllLock = Logic(name: 'after_cpll_lock');
    final afterMmcmLock = Logic(name: 'after_mmcm_lock');
    final lostD =
        (((afterCpllLock & ~cpllLocked) |
                    (afterMmcmLock & ~mmcmLocked) |
                    badQ) &
                ~blockQ)
            .named('lost_d');
    final rateHit = Logic(name: 'rate_hit');
    final rateD = (rWait & rateHit & ~blockQ).named('rate_d');
    final restartPulse = timeouts.linkWait == 0
        ? null
        : Logic(name: 'link_restart');

    final causeSync1 = Logic(name: 'fail_cause_sync_1');
    final code1 = Logic(name: 'fail_cause_1', width: 4);
    final flags1 = Logic(name: 'fail_flags_1', width: timeoutFlagBits);
    final causeSync1b = Logic(name: 'fail_cause_sync_1b');
    final code1b = Logic(name: 'fail_cause_1b', width: 4);
    final flags1b = Logic(name: 'fail_flags_1b', width: timeoutFlagBits);
    final causeSync2 = Logic(name: 'fail_cause_sync');
    final failTmo2 = Logic(name: 'fail_timeout');
    final code2 = Logic(name: 'fail_cause', width: 4);
    final flags2 = Logic(name: 'fail_flags_2', width: timeoutFlagBits);
    final triesLeft = Logic(name: 'sync_tries_left');
    final syncTries = Logic(name: 'sync_tries', width: 8);
    final retries = Logic(name: 'retries', width: 8);
    final retriesFull = Logic(name: 'retries_full');
    final failState = Logic(name: 'fail_state', width: 4);
    final flags = Logic(name: 'timeout_flags_q', width: timeoutFlagBits);

    Logic codeOf(_S v) => Const(v.code, width: 4);
    final stateCode = List<Logic>.generate(4, (b) {
      return orAll([
        for (final v in order)
          if (((v.code >> b) & 1) == 1) st[v]!,
      ]);
    }).rconcat();
    final syncStates = [
      st[_S.txDlySReset]!,
      st[_S.txPhInit]!,
      st[_S.txPhAlign]!,
      st[_S.txDlyEn]!,
    ];
    final tmoAny = orAll(tmoK.values);

    // A one-hot vector with no bit or two bits set is a failure. Groups of 4
    // bits give an any and a multi flop. The first group reads as set and the
    // last flop reads as clear while a failure is applied, so the flops hold
    // no old result when it ends.
    Logic oneHotBad(String name, List<Logic> bits) {
      final anys = <Logic>[];
      final multis = <Logic>[];
      for (var lo = 0, i = 0; lo < bits.length; lo += 4, i++) {
        final g = bits.sublist(lo, lo + 4 < bits.length ? lo + 4 : bits.length);
        final a = Logic(name: '${name}_any$i');
        final m = Logic(name: '${name}_multi$i');
        final pairs = [
          for (var x = 0; x < g.length; x++)
            for (var y = x + 1; y < g.length; y++) g[x] & g[y],
        ];
        Sequential(
          pclk,
          [
            a < (i == 0 ? orAll(g) | blockQ : orAll(g) & ~blockQ),
            m < (orAll(pairs) & ~blockQ),
          ],
          reset: rst,
          resetValues: {if (i == 0) a: Const(1)},
        );
        anys.add(a);
        multis.add(m);
      }
      final cross = [
        for (var x = 0; x < anys.length; x++)
          for (var y = x + 1; y < anys.length; y++) anys[x] & anys[y],
      ];
      final bad = Logic(name: '${name}_bad');
      Sequential(pclk, [
        bad < (~orAll(anys) | orAll(multis) | orAll(cross)),
      ], reset: rst);
      return bad;
    }

    final badSt = oneHotBad('onehot_state', [for (final v in order) st[v]!]);
    final badRate = oneHotBad('onehot_rate', [
      rIdle,
      rSwitch,
      rWait,
      rTake,
      rBack,
      rDone,
    ]);
    Sequential(pclk, [badQ < ((badSt | badRate) & ~blockQ)], reset: rst);
    final retryD = (failQ & failTmo2 & causeSync2 & triesLeft & ~wd2Q).named(
      'retry_d',
    );
    final fullD = ((failQ | wd2Q) & ~retryD).named('full_d');
    final failD = ((tmoQ | lostQ | rateQf) & ~failQ & ~retryQ & ~fullQ).named(
      'fail_d',
    );
    final wd2D = (wdQ & ~wd2Q).named('wd2_d');

    Sequential(pclk, [
      for (final v in order) go[v]! < goD[v]!,
      clrPa < orAll(order.take(6).map((v) => go[v]!)),
      clrPb < orAll(order.skip(6).map((v) => go[v]!)),
      clrPc < ovr,
      clrQ < (clrPa | clrPb | clrPc),
      clrQ2 < clrQ,
      blockQ < (failD | wd2D | retryD | fullD),
      for (final e in tmoK.entries) e.value < tmoD[e.key]!,
      lostK < lostD,
      rateK < rateD,
      wdK <
          (restartPulse == null
              ? Const(0)
              : restartPulse & ~blockQ & ~wdK & ~wdQ & ~wdPend),
      // One restart pulse counts once, however long it stays high.
      wdPend < ((wdPend | wdK) & (restartPulse ?? Const(0))),
      // The cause is taken when the decision is made, and moves on with it.
      causeSync1 < (~rateD & orAll(syncStates)),
      code1 < mux(rateD, codeOf(_S.rateChange), stateCode),
      flags1 <
          [
            rateD,
            ~rateD & orAll(syncStates),
            ~rateD & st[_S.resetDone]!,
            ~rateD & st[_S.clockLock]!,
            ~rateD & (st[_S.cpllReset]! | st[_S.cpllLock]!),
          ].concat(),
      causeSync1b < causeSync1,
      code1b < code1,
      flags1b < flags1,
      tmoQ < (tmoAny & ~clrQ & ~clrQ2),
      lostQ < lostK,
      rateQf < rateK,
      wdQ < wdK,
      failQ < failD,
      wd2Q < wd2D,
      causeSync2 < causeSync1b,
      failTmo2 < (tmoQ | rateQf),
      code2 < code1b,
      flags2 < flags1b,
      retryQ < retryD,
      fullQ < fullD,
    ], reset: rst);

    Sequential(
      pclk,
      [
        for (final v in order)
          st[v]! <
              ((orAll([
                            for (final p in order)
                              if (target[p] == v) go[p]!,
                          ]) |
                          (st[v]! & ~go[v]!)) &
                      ~ovr) |
                  (v == _S.cpllReset
                      ? fullQ
                      : v == _S.txDlySReset
                      ? retryQ
                      : Const(0)),
      ],
      reset: rst,
      resetValues: {st[_S.cfgWait]!: Const(1)},
    );

    // Bookkeeping when a failure is applied.
    Sequential(
      pclk,
      [
        retriesFull < retries.and(),
        If(
          failQ,
          then: [
            failState < code2,
            If(~retriesFull, then: [retries < retries + 1]),
            If(failTmo2, then: [flags < (flags2 | flags)]),
          ],
        ),
        If(
          retryQ,
          then: [
            syncTries < syncTries + 1,
            triesLeft <
                syncTries.lt(
                  Const(
                    timeouts.syncRetries > 0 ? timeouts.syncRetries - 1 : 0,
                    width: 8,
                  ),
                ),
          ],
          orElse: [
            If(
              fullQ | go[_S.txDlyEn]!,
              then: [
                syncTries < 0,
                triesLeft < Const(timeouts.syncRetries > 0 ? 1 : 0),
              ],
            ),
          ],
        ),
      ],
      reset: rst,
      resetValues: {
        failState: codeOf(_S.none),
        triesLeft: Const(timeouts.syncRetries > 0 ? 1 : 0),
      },
    );

    // The timer clears in the first cycle of a state, so it counts the cycles
    // after that.
    Sequential(pclk, [
      If(
        clrQ,
        then: [timer < 0],
        orElse: [
          If(~sIdle, then: [timer < timer + 1]),
        ],
      ),
      If(
        st[_S.cpllReset]! & ~holdCount[holdCount.width - 1],
        then: [holdCount < holdCount + 1],
        orElse: [
          If(~st[_S.cpllReset]!, then: [holdCount < 0]),
        ],
      ),
      cpllHold < (st[_S.cpllReset]! & holdCount[holdCount.width - 1]),
    ], reset: rst);

    // Outputs to the GT.
    cpllRst <= st[_S.cpllReset]!;
    Sequential(pclk, [
      gtRst < (fullQ | go[_S.cfgWait]! | (gtRst & ~go[_S.cpllLock]!)),
      afterCpllLock < ((afterCpllLock & ~fullQ) | go[_S.cpllLock]!),
      afterMmcmLock < ((afterMmcmLock & ~fullQ) | go[_S.clockLock]!),
      dlySReset <
          (st[_S.txDlySReset]! &
              txSettled &
              ~failQ &
              ~retryQ &
              ~go[_S.txDlySReset]!),
      dlyEn <
          (go[_S.txPhAlign]! |
              (dlyEn &
                  ~(debugSkipTxPhaseAlign ? go[_S.txDlyEn]! : go[_S.idle]!) &
                  ~ovr)),
      linkUp <
          ((orAll([
                    for (final p in order)
                      if (target[p] == _S.idle) go[p]!,
                  ]) |
                  (sIdle & ~go[_S.idle]!) |
                  ~rIdle) &
              ~blockQ),
    ], reset: rst);
    userRdy <= afterMmcmLock;
    phInit <= st[_S.txPhInit]!;
    phAlign <= st[_S.txPhAlign]!;

    // Rate change. The hard block drives one rate. The `pclk` select changes
    // first, then TXRATE and RXRATE.
    final rw = timeouts.rate.bitLength;
    final rateTimer = Logic(name: 'rate_timer', width: rw);
    final txRateSeen = Logic(name: 'tx_rate_seen');
    final rxRateSeen = Logic(name: 'rx_rate_seen');
    final phySeen = Logic(name: 'phy_seen');
    final seenAll = Logic(name: 'rate_seen_all');
    final rateChg = Logic(name: 'rate_change_q');
    final switchHit = Logic(name: 'switch_hit');
    final takeGo = debugSkipTxPhaseAlign ? Const(1) : ~sIdle;
    final rateChunks = chunkEq(
      'rate_eq',
      rateTimer,
      timeouts.rate > 5 ? timeouts.rate - 3 : 0,
      rWait,
    );
    final switchChunks = chunkEq(
      'switch_eq',
      rateTimer,
      timeouts.clockSwitch - 3,
      rSwitch,
    );
    Sequential(
      pclk,
      [
        rateQ < _pipeDelay(pclk, p.pipeRate, pipeStages, 'rate'),
        rateChg < (rateQ ^ gtRate),
        rateHit < (rWait & (rateHit | andAll(rateChunks))),
        switchHit < (rSwitch & andAll(switchChunks)),
        txRateSeen < (rWait & (txRateSeen | txRateDoneS)),
        rxRateSeen < (rWait & (rxRateSeen | rxRateDoneS)),
        phySeen < (rWait & (phySeen | gtPhyStatus)),
        seenAll < (txRateSeen & rxRateSeen & phySeen),
        rIdle < (fullQ | rDone | (rIdle & ~(rateChg & sIdle))),
        rSwitch <
            (~fullQ & ((rIdle & rateChg & sIdle) | (rSwitch & ~switchHit))),
        rWait < (~fullQ & ((rSwitch & switchHit) | (rWait & ~seenAll))),
        rTake < (~fullQ & ((rWait & seenAll) | (rTake & ~takeGo))),
        rBack < (~fullQ & ((rTake & takeGo) | (rBack & ~sIdle))),
        rDone < (~fullQ & rBack & sIdle),
        If(
          fullQ | rIdle | (rSwitch & switchHit),
          then: [rateTimer < 0],
          orElse: [
            If(rSwitch | rWait, then: [rateTimer < rateTimer + 1]),
          ],
        ),
        If(
          fullQ,
          then: [gtRate < 0, pclkSelQ < 0],
          orElse: [
            If(rSwitch & switchHit, then: [gtRate < rateQ]),
            If(rIdle & rateChg & sIdle, then: [pclkSelQ < rateQ]),
          ],
        ),
      ],
      reset: rst,
      resetValues: {rIdle: Const(1)},
    );

    final state = stateCode;
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
        ~sIdle,
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

    if (restartPulse == null) return;
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

    // The watchdog reads its own copy of `link_up`, so the logic near the hard
    // block pins does not load the `link_up` flop.
    final linkUpWd = Logic(name: 'link_up_wd');
    Sequential(pclk, [linkUpWd < linkUp], reset: rst);
    final dlDown = (linkUpWd & ~hardUp).named('dl_down');
    final training = (dlDown & ~phyUp).named('link_training');
    final detect = _watch(
      pclk,
      rst,
      'detect',
      timeouts.linkWait,
      run: training & inDetect,
      clear: ~training,
    );
    final l0 = (dlDown & phyUp).named('link_l0_dl_down');
    final l0Watch = _watch(
      pclk,
      rst,
      'l0',
      timeouts.dataLinkWait,
      run: l0,
      clear: ~l0,
    );
    restartPulse <= (detect.hit & detect.run) | (l0Watch.hit & l0Watch.run);
    final linkRetrains = Logic(name: 'link_retrains', width: 8);
    final retrainsFull = Logic(name: 'link_retrains_full');
    Sequential(pclk, [
      retrainsFull < linkRetrains.and(),
      If(wdQ & ~retrainsFull, then: [linkRetrains < linkRetrains + 1]),
    ], reset: rst);
    addOutput('link_retrains', width: 8) <= linkRetrains;
  }

  /// A timer that counts while [run] is high, holds while [run] and [clear]
  /// are low, and goes to 0 while [clear] is high. `hit` goes high a few
  /// cycles after [bound] counted cycles and stays high until [clear]. The
  /// inputs and the compare are flops. `run` is the registered copy of [run].
  static ({Logic hit, Logic run}) _watch(
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
    final eq = Logic(name: '${name}_eq');
    final runQ = Logic(name: '${name}_run_q');
    final clearQ = Logic(name: '${name}_clear_q');
    final chunks = <Logic>[];
    final value = bound > 3 ? bound - 3 : 0;
    for (var lo = 0, i = 0; lo < w; lo += 5, i++) {
      final hi = lo + 5 < w ? lo + 5 : w;
      final q = Logic(name: '${name}_c$i');
      final part = Const(
        (value >> lo) & ((1 << (hi - lo)) - 1),
        width: hi - lo,
      );
      Sequential(clk, [q < timer.slice(hi - 1, lo).eq(part)], reset: reset);
      chunks.add(q);
    }
    Sequential(clk, [
      runQ < run,
      clearQ < clear,
      eq < chunks.reduce((a, b) => a & b),
      If(
        clearQ,
        then: [timer < 0, hit < 0],
        orElse: [
          If(runQ & ~hit, then: [timer < timer + 1]),
          If(runQ & eq, then: [hit < 1]),
        ],
      ),
    ], reset: reset);
    return (hit: hit, run: runQ);
  }
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
