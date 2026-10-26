import 'package:rohd/rohd.dart';

import '../../clock/cdc.dart';
import 'gtp_drp_reset.dart';
import 'pcie_pipe.dart';
import 'pipe_clock.dart';

typedef _S = HarborGtpResetState;

/// The GTPE2_CHANNEL ports that the PCIe PHY uses.
///
/// The names are the primitive port names, so a wrapper can connect them by
/// name. The GT is the provider. The other ports of the primitive are tie-offs
/// (see `gtpe2ChannelPcieTieOffs`) or direct wires to GTPE2_COMMON and the pins.
class HarborGtpChannelPorts extends PairInterface {
  HarborGtpChannelPorts()
    : super(
        portsFromProvider: [
          Logic.port('TXOUTCLK'),
          Logic.port('TXRESETDONE'),
          Logic.port('RXRESETDONE'),
          Logic.port('RXPMARESETDONE'),
          Logic.port('TXDLYSRESETDONE'),
          Logic.port('TXPHINITDONE'),
          Logic.port('TXPHALIGNDONE'),
          Logic.port('TXRATEDONE'),
          Logic.port('RXRATEDONE'),
          Logic.port('PHYSTATUS'),
          Logic.port('RXVALID'),
          Logic.port('RXELECIDLE'),
          Logic.port('RXCHANISALIGNED'),
          Logic.port('RXSYNCOUT'),
          Logic.port('RXSTATUS', 3),
          Logic.port('RXDATA', 32),
          Logic.port('RXCHARISK', 4),
          Logic.port('DRPDO', 16),
          Logic.port('DRPRDY'),
        ],
        portsFromConsumer: [
          Logic.port('GTTXRESET'),
          Logic.port('GTRXRESET'),
          Logic.port('TXUSERRDY'),
          Logic.port('RXUSERRDY'),
          Logic.port('TXUSRCLK'),
          Logic.port('TXUSRCLK2'),
          Logic.port('RXUSRCLK'),
          Logic.port('RXUSRCLK2'),
          Logic.port('SIGVALIDCLK'),
          Logic.port('TXDLYSRESET'),
          Logic.port('TXPHINIT'),
          Logic.port('TXPHALIGN'),
          Logic.port('TXDLYEN'),
          Logic.port('RXSYNCIN'),
          Logic.port('TXDETECTRX'),
          Logic.port('TXELECIDLE'),
          Logic.port('RXPOLARITY'),
          Logic.port('TXPD', 2),
          Logic.port('RXPD', 2),
          Logic.port('TXRATE', 3),
          Logic.port('RXRATE', 3),
          Logic.port('TXDATA', 32),
          Logic.port('TXCHARISK', 4),
          Logic.port('TXCHARDISPMODE', 4),
          Logic.port('TXMARGIN', 3),
          Logic.port('TXSWING'),
          Logic.port('TXDEEMPH'),
          Logic.port('DRPCLK'),
          Logic.port('DRPADDR', 9),
          Logic.port('DRPDI', 16),
          Logic.port('DRPEN'),
          Logic.port('DRPWE'),
        ],
      );

  @override
  HarborGtpChannelPorts clone() => HarborGtpChannelPorts();
}

/// The GTPE2_COMMON ports that the PCIe PHY uses. The GT is the provider.
class HarborGtpCommonPorts extends PairInterface {
  HarborGtpCommonPorts()
    : super(
        portsFromProvider: [Logic.port('PLL0LOCK')],
        portsFromConsumer: [
          Logic.port('PLL0RESET'),
          Logic.port('PLL0REFCLKSEL', 3),
        ],
      );

  @override
  HarborGtpCommonPorts clone() => HarborGtpCommonPorts();
}

/// States of the GTP reset sequence, as the `reset_state` output shows them.
enum HarborGtpResetState {
  /// The link is ready.
  idle(1),

  /// Wait 64 clocks after PERST# releases.
  cfgWait(0),

  /// PLL and GT reset are high. Wait until reset done is low.
  pllReset(2),

  /// PLL reset is low. Wait for PLL0LOCK.
  pllLock(3),

  /// Release GTTXRESET and GTRXRESET.
  gtReset(4),

  /// Wait for RXPMARESETDONE high.
  pmaHigh(5),

  /// Wait for RXPMARESETDONE low.
  pmaLow(6),

  /// Wait for the MMCM lock, then set TXUSERRDY and RXUSERRDY.
  mmcmLock(7),

  /// Wait for TX and RX reset done with PHYSTATUS low.
  resetDone(8),

  /// TXDLYSRESET until TXDLYSRESETDONE rises.
  txDlySReset(9),

  /// TXPHINIT until TXPHINITDONE rises.
  txPhInit(10),

  /// TXPHALIGN until TXPHALIGNDONE rises.
  txPhAlign(11),

  /// TXDLYEN until TXPHALIGNDONE rises again.
  txDlyEn(12),

  /// Only in `reset_fail_state`: a rate change did not complete.
  rateChange(13),

  /// Only in `reset_fail_state`: the receive reset DRP transaction timed out.
  drpReset(14),

  /// Only in `reset_fail_state`: no failure since PERST#.
  none(15);

  /// Value on the debug outputs.
  final int code;

  const HarborGtpResetState(this.code);

  /// The state with [code].
  static HarborGtpResetState fromCode(int code) =>
      values.firstWhere((s) => s.code == code);
}

/// Bounds, in `pclk` cycles, of the waits in the GTP reset sequence.
///
/// When a wait reaches its bound, the sequence starts again at
/// [HarborGtpResetState.pllReset]. The defaults are for 125 MHz.
class HarborGtpPcieTimeouts {
  /// Wait for PLL0LOCK.
  final int pllLock;

  /// Wait for reset done low in PLL reset, and for reset done high.
  final int resetDone;

  /// Each wait for RXPMARESETDONE.
  final int pmaResetDone;

  /// Wait for the MMCM lock.
  final int mmcmLock;

  /// Each step of the TX buffer bypass sync.
  final int txSync;

  /// Wait for TXRATEDONE, RXRATEDONE and PHYSTATUS after a rate change.
  final int rate;

  /// Each wait for DRPRDY in the receive reset DRP transaction.
  final int drp;

  /// Bound of the link training watchdog. When the PHY is ready and the hard
  /// block link up stays low for this many cycles, the sequence starts again
  /// at [HarborGtpResetState.pllReset]. 0 removes the watchdog.
  ///
  /// The default is 2^25 cycles, 268 ms at 125 MHz. One LTSSM pass through
  /// Detect, Polling and Configuration with each state at its timeout takes
  /// about 130 ms, so a slow partner gets two passes.
  ///
  /// A restart pulls the PHY ready low, and the hard block then resets all
  /// user logic on its user reset. Transfers in flight stop.
  final int linkWait;

  const HarborGtpPcieTimeouts({
    this.pllLock = 1 << 18,
    this.resetDone = 1 << 17,
    this.pmaResetDone = 1 << 17,
    this.mmcmLock = 1 << 17,
    this.txSync = 1 << 12,
    this.rate = 1 << 14,
    this.drp = 1 << 12,
    this.linkWait = 1 << 25,
  });

  List<int> get all => [
    pllLock,
    resetDone,
    pmaResetDone,
    mmcmLock,
    txSync,
    rate,
    drp,
  ];
}

/// Checks a PIPE pipeline stage count.
void harborCheckPipeStages(int pipeStages) {
  if (pipeStages < 0 || pipeStages > 2) {
    throw ArgumentError.value(pipeStages, 'pipeStages', 'must be 0, 1 or 2');
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

/// The GTP side and the PIPE side of one PCIe lane.
///
/// All GT status signals go through two flop synchronisers to `pclk`. The
/// receive data, RXVALID and PHYSTATUS are on RXUSRCLK2, which is `pclk`, so
/// they do not. RXVALID goes to the hard block only after the GT holds it high
/// for 16 cycles, and only while [linkUp] is high. PHYSTATUS is high while
/// [linkUp] is low. During a rate change [rateIdle] is low and only the
/// [rateDone] pulse goes out as PHYSTATUS.
///
/// Each PIPE signal gets [pipeStages] registers between the GT and the PIPE
/// side, in the two directions. The lane logic sees the GT side.
class HarborGtpPcieLane extends Module {
  /// Registers on each PIPE signal, 0 to 2.
  final int pipeStages;

  /// Synchronised TXRESETDONE.
  Logic get txResetDone => output('tx_resetdone');

  /// Synchronised RXRESETDONE.
  Logic get rxResetDone => output('rx_resetdone');

  /// Synchronised RXPMARESETDONE.
  Logic get rxPmaResetDone => output('rx_pmaresetdone');

  /// Synchronised TXDLYSRESETDONE.
  Logic get txDlySResetDone => output('tx_dlysresetdone');

  /// Synchronised TXPHINITDONE.
  Logic get txPhInitDone => output('tx_phinitdone');

  /// Synchronised TXPHALIGNDONE.
  Logic get txPhAlignDone => output('tx_phaligndone');

  /// Synchronised TXRATEDONE.
  Logic get txRateDone => output('tx_ratedone');

  /// Synchronised RXRATEDONE.
  Logic get rxRateDone => output('rx_ratedone');

  /// Synchronised PHYSTATUS of the GT.
  Logic get gtPhyStatus => output('gt_phystatus');

  Logic get drpDataOut => output('drp_data_out');

  Logic get drpReady => output('drp_ready');

  HarborGtpPcieLane(
    HarborGtpChannelPorts gt,
    HarborPciePipeLane pipe, {
    required Logic pclk,
    required Logic reset,
    required Logic sigValidClk,
    required Logic gtReset,
    required Logic userRdy,
    required Logic txDlySReset,
    required Logic txPhInit,
    required Logic txPhAlign,
    required Logic txDlyEn,
    required Logic linkUp,
    required Logic rateIdle,
    required Logic rateDone,
    required Logic rate,
    required Logic drpAddr,
    required Logic drpDataIn,
    required Logic drpEnable,
    required Logic drpWrite,
    required this.pipeStages,
    super.name = 'gtp_pcie_lane',
  }) : super(
         definitionName: pipeStages == 0
             ? 'HarborGtpPcieLane'
             : 'HarborGtpPcieLane_Pipe$pipeStages',
       ) {
    harborCheckPipeStages(pipeStages);
    final g = HarborGtpChannelPorts()
      ..pairConnectIO(this, gt, PairRole.consumer);
    final p = HarborPciePipeLane()
      ..pairConnectIO(this, pipe, PairRole.provider);
    pclk = addInput('pclk', pclk);
    reset = addInput('reset', reset);
    sigValidClk = addInput('sigvalidclk', sigValidClk);
    gtReset = addInput('gt_reset', gtReset);
    userRdy = addInput('user_rdy', userRdy);
    txDlySReset = addInput('tx_dlysreset', txDlySReset);
    txPhInit = addInput('tx_phinit', txPhInit);
    txPhAlign = addInput('tx_phalign', txPhAlign);
    txDlyEn = addInput('tx_dlyen', txDlyEn);
    linkUp = addInput('link_up', linkUp);
    rateIdle = addInput('rate_idle', rateIdle);
    rateDone = addInput('rate_done', rateDone);
    rate = addInput('gt_rate', rate);
    drpAddr = addInput('drp_addr', drpAddr, width: 9);
    drpDataIn = addInput('drp_data_in', drpDataIn, width: 16);
    drpEnable = addInput('drp_enable', drpEnable);
    drpWrite = addInput('drp_write', drpWrite);
    Logic stage(Logic d, String name) => _pipeDelay(pclk, d, pipeStages, name);

    Logic sync(String port, String name) {
      final s = HarborCdcSync(name: '${name}_sync');
      s.input('async_in').srcConnection! <= g.port(port);
      s.input('dst_clk').srcConnection! <= pclk;
      s.input('dst_reset').srcConnection! <= reset;
      return s.syncOut;
    }

    for (final (port, name) in [
      ('TXRESETDONE', 'tx_resetdone'),
      ('RXRESETDONE', 'rx_resetdone'),
      ('RXPMARESETDONE', 'rx_pmaresetdone'),
      ('TXDLYSRESETDONE', 'tx_dlysresetdone'),
      ('TXPHINITDONE', 'tx_phinitdone'),
      ('TXPHALIGNDONE', 'tx_phaligndone'),
      ('TXRATEDONE', 'tx_ratedone'),
      ('RXRATEDONE', 'rx_ratedone'),
      ('PHYSTATUS', 'gt_phystatus'),
    ]) {
      addOutput(name) <= sync(port, name);
    }
    final elecIdle = sync('RXELECIDLE', 'rx_elecidle');
    final chanAligned = sync('RXCHANISALIGNED', 'rx_chanisaligned');

    for (final c in ['TXUSRCLK', 'TXUSRCLK2', 'RXUSRCLK', 'RXUSRCLK2']) {
      g.port(c) <= pclk;
    }
    g.port('SIGVALIDCLK') <= sigValidClk;
    g.port('GTTXRESET') <= gtReset;
    g.port('GTRXRESET') <= gtReset;
    g.port('TXUSERRDY') <= userRdy;
    g.port('RXUSERRDY') <= userRdy;
    g.port('TXDLYSRESET') <= txDlySReset;
    g.port('TXPHINIT') <= txPhInit;
    g.port('TXPHALIGN') <= txPhAlign;
    g.port('TXDLYEN') <= txDlyEn;
    g.port('RXSYNCIN') <= g.port('RXSYNCOUT');

    g.port('TXDATA') <= stage(p.txData, 'txdata').zeroExtend(32);
    g.port('TXCHARISK') <= stage(p.txDataK, 'txdatak').zeroExtend(4);
    g.port('TXCHARDISPMODE') <=
        stage(p.txCompliance, 'txcompliance').zeroExtend(4);
    g.port('TXDETECTRX') <= stage(p.txDetectRx, 'txdetectrx');
    g.port('TXELECIDLE') <= stage(p.txElecIdle, 'txelecidle');
    g.port('RXPOLARITY') <= stage(p.rxPolarity, 'rxpolarity');
    final powerDown = stage(p.powerDown, 'powerdown');
    g.port('TXPD') <= powerDown;
    g.port('RXPD') <= powerDown;
    g.port('TXRATE') <= rate.zeroExtend(3);
    g.port('RXRATE') <= rate.zeroExtend(3);
    g.port('TXMARGIN') <= stage(p.txMargin, 'txmargin');
    g.port('TXSWING') <= stage(p.txSwing, 'txswing');
    g.port('TXDEEMPH') <= stage(p.txDeemph, 'txdeemph');
    g.port('DRPCLK') <= pclk;
    g.port('DRPADDR') <= drpAddr;
    g.port('DRPDI') <= drpDataIn;
    g.port('DRPEN') <= drpEnable;
    g.port('DRPWE') <= drpWrite;
    addOutput('drp_data_out', width: 16) <= g.port('DRPDO');
    addOutput('drp_ready') <= g.port('DRPRDY');

    p.rxData <= stage(g.port('RXDATA').slice(15, 0), 'rxdata');
    p.rxDataK <= stage(g.port('RXCHARISK').slice(1, 0), 'rxdatak');
    p.rxStatus <= stage(g.port('RXSTATUS'), 'rxstatus');
    p.rxElecIdle <= stage(elecIdle, 'rxelecidle');
    p.rxChanIsAligned <= stage(chanAligned, 'rxchanisaligned');

    final gtValid = g.port('RXVALID');
    final validCount = Logic(name: 'rxvalid_count', width: 5);
    Sequential(pclk, [
      If(
        gtValid & ~gtReset,
        then: [
          If(~validCount[4], then: [validCount < validCount + 1]),
        ],
        orElse: [validCount < 0],
      ),
    ], reset: reset);
    p.rxValid <= stage(linkUp & validCount[4] & gtValid, 'rxvalid');

    p.phyStatus <=
        stage(
          ~linkUp | (rateIdle & g.port('PHYSTATUS')) | rateDone,
          'phystatus',
        );
  }
}

/// PIPE PHY for PCIe on 7-series GTP transceivers, Gen1 x1 or x4.
///
/// The PHY connects to one GTPE2_COMMON through [common] and to one
/// GTPE2_CHANNEL for each lane through [channels]. It gives one PIPE bundle
/// for each lane in [pipes]. PLL0 takes GTREFCLK1, so PLL0REFCLKSEL is
/// 3'b010.
///
/// The reset sequence runs on `pclk`. PERST# low sets it to
/// [HarborGtpResetState.cfgWait]. The order follows UG482 chapter 2
/// (PLL reset and lock) and chapter 3 ("TX Initialization and Reset",
/// sequential mode, and "TX Buffer Bypass" in manual mode):
///
/// 1. Wait 64 clocks.
/// 2. Set PLL0RESET (only with [drivePllReset]) and GTTXRESET and GTRXRESET.
///    Wait until TX and RX reset done and RXPMARESETDONE are low.
/// 3. Clear PLL0RESET and wait for PLL0LOCK. Then clear the GT resets.
/// 4. Wait for RXPMARESETDONE high, then low (only with
///    [waitRxPmaResetDone]). A short high pulse before the wait counts.
/// 5. Wait for the MMCM lock. Then set TXUSERRDY and RXUSERRDY.
/// 6. Wait for TX and RX reset done high with PHYSTATUS low.
/// 7. TX sync: TXDLYSRESET until its done rises, TXPHINIT until its done
///    rises, TXPHALIGN until TXPHALIGNDONE rises, then TXDLYEN until
///    TXPHALIGNDONE rises again. TXDLYEN stays high in idle.
///
/// Each wait has a bound in [timeouts]. At the bound, or when PLL0LOCK or the
/// MMCM lock goes low after its wait, the sequence starts again at step 2.
/// `reset_fail_state` holds the state of the last failure and `reset_retries`
/// counts the failures. A change of `rate` in idle waits for TXRATEDONE,
/// RXRATEDONE and PHYSTATUS, does the TX sync again, and then gives one
/// PHYSTATUS pulse.
///
/// With [HarborGtpPcieTimeouts.linkWait] above 0, a watchdog looks at the
/// link up of the hard block on `hard_link_up`. It goes through two flop
/// synchronisers to `pclk`. When the PHY is ready and the link stays down
/// for `linkWait` cycles, the sequence starts again at step 2 and
/// `link_retrains` counts up. This is not a failure, so `reset_fail_state`
/// and `reset_retries` do not change. `reset_retries` counts GT faults and
/// `link_retrains` counts restarts with no link partner.
///
/// The sequence uses the TX sync done signals of lane 0 only. Lanes 1 to 3
/// get the same sync controls.
///
/// With [clocks] null, the PHY makes [HarborPipeClock] from the TXOUTCLK of
/// lane 0. With [clocks] set, the PHY uses those clocks, and the TXOUTCLK
/// ports are not used.
///
/// [pipeStages] registers go on each PIPE signal between the GT and the hard
/// block, in the two directions, as PIPE_PIPELINE_STAGES does in the AMD
/// core. The reset and rate logic see the GT side.
class HarborGtpPciePhy extends Module {
  /// Number of lanes, 1 or 4.
  final int lanes;

  /// Registers on each PIPE signal, 0 to 2.
  final int pipeStages;

  /// Bounds of the waits.
  final HarborGtpPcieTimeouts timeouts;

  /// Drive PLL0RESET in the sequence. When false, PLL0RESET stays low.
  final bool drivePllReset;

  /// Wait for the RXPMARESETDONE pulse after the GT reset.
  final bool waitRxPmaResetDone;

  /// Wait for RXRESETDONE and startup PHYSTATUS before TX buffer alignment.
  final bool waitForRxResetStatus;

  /// PIPE clock.
  Logic get pclk => output('pclk');

  /// User clock 1.
  Logic get userClk1 => output('userclk1');

  /// User clock 2.
  Logic get userClk2 => output('userclk2');

  /// MMCM lock, not synchronised.
  Logic get mmcmLock => output('mmcm_lock');

  /// Current [HarborGtpResetState] code.
  Logic get resetState => output('reset_state');

  /// [HarborGtpResetState] code of the last failure.
  Logic get resetFailState => output('reset_fail_state');

  /// Number of failures since reset, it stops at 255.
  Logic get resetRetries => output('reset_retries');

  /// Number of watchdog restarts since PERST# or power-on, it stops at 255.
  /// Null when the watchdog is off.
  Logic? get linkRetrains =>
      timeouts.linkWait == 0 ? null : output('link_retrains');

  /// High when the PIPE side is up.
  Logic get phyReady => output('phy_ready');

  HarborGtpPciePhy({
    required Logic perstN,
    Logic? hardLinkUp,
    required HarborGtpCommonPorts common,
    required List<HarborGtpChannelPorts> channels,
    required List<HarborPciePipeLane> pipes,
    this.lanes = 1,
    HarborPipeClocks? clocks,
    Logic? mmcmReset,
    int? mmcmLockTimerBits,
    this.timeouts = const HarborGtpPcieTimeouts(),
    this.drivePllReset = false,
    this.waitRxPmaResetDone = true,
    this.waitForRxResetStatus = true,
    this.pipeStages = 1,
    super.name = 'gtp_pcie_phy',
  }) : super(
         definitionName: [
           'HarborGtpPciePhy_X$lanes',
           if (pipeStages != 0) 'Pipe$pipeStages',
           if (timeouts.linkWait != 0) 'LinkWd',
         ].join('_'),
       ) {
    harborCheckPipeStages(pipeStages);
    if (lanes != 1 && lanes != 4) {
      throw ArgumentError.value(lanes, 'lanes', 'must be 1 or 4');
    }
    if (channels.length != lanes || pipes.length != lanes) {
      throw ArgumentError(
        'need $lanes channels and pipes, got ${channels.length} and '
        '${pipes.length}',
      );
    }
    for (final t in timeouts.all) {
      if (t < 4) throw ArgumentError.value(t, 'timeouts', 'below 4 cycles');
    }
    final linkWait = timeouts.linkWait;
    if (linkWait < 0 || (linkWait > 0 && linkWait < 4)) {
      throw ArgumentError.value(linkWait, 'linkWait', 'must be 0 or 4 and up');
    }
    if ((linkWait != 0) != (hardLinkUp != null)) {
      throw ArgumentError(
        'hardLinkUp must be given when linkWait is not 0, and only then',
      );
    }

    perstN = addInput('perst_n', perstN);
    final com = HarborGtpCommonPorts()
      ..pairConnectIO(
        this,
        common,
        PairRole.consumer,
        uniquify: (n) => 'gtc_$n',
      );
    final gts = [
      for (var i = 0; i < lanes; i++)
        HarborGtpChannelPorts()..pairConnectIO(
          this,
          channels[i],
          PairRole.consumer,
          uniquify: (n) => 'gt${i}_$n',
        ),
    ];
    final pps = [
      for (var i = 0; i < lanes; i++)
        HarborPciePipeLane()..pairConnectIO(
          this,
          pipes[i],
          PairRole.provider,
          uniquify: (n) => 'pipe${i}_$n',
        ),
    ];

    final HarborPipeClocks clk;
    if (clocks == null) {
      clk = HarborPipeClock(
        txOutClk: gts[0].port('TXOUTCLK'),
        reset: mmcmReset == null
            ? (~perstN).named('mmcm_rst')
            : (~perstN | addInput('mmcm_reset', mmcmReset)).named('mmcm_rst'),
        userClkDivide: lanes == 1 ? 16 : 8,
        lockTimerBits: mmcmLockTimerBits,
      ).clocks;
    } else {
      clk = HarborPipeClocks(
        pclk: addInput('pclk_in', clocks.pclk),
        userClk1: addInput('userclk1_in', clocks.userClk1),
        userClk2: addInput('userclk2_in', clocks.userClk2),
        mmcmLock: addInput('mmcm_lock_in', clocks.mmcmLock),
      );
    }
    final pclk = clk.pclk;
    addOutput('pclk') <= pclk;
    addOutput('userclk1') <= clk.userClk1;
    addOutput('userclk2') <= clk.userClk2;
    addOutput('mmcm_lock') <= clk.mmcmLock;

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

    final pllLocked = sync(com.port('PLL0LOCK'), 'pll0lock_s');
    final mmcmLocked = sync(clk.mmcmLock, 'mmcm_lock_s');

    // Sequence outputs, registered from the next state.
    final pllRst = Logic(name: 'pll_reset');
    final gtRst = Logic(name: 'gt_reset');
    final userRdy = Logic(name: 'user_rdy');
    final dlySReset = Logic(name: 'tx_dlysreset');
    final phInit = Logic(name: 'tx_phinit');
    final phAlign = Logic(name: 'tx_phalign');
    final dlyEn = Logic(name: 'tx_dlyen');
    final linkUp = Logic(name: 'link_up');
    final rateQ = Logic(name: 'rate_q');
    final rateState = Logic(name: 'rate_state', width: 3);
    final rateIdle = rateState.eq(_r(_rIdle)).named('rate_idle');
    final rateDone = rateState.eq(_r(_rDone)).named('rate_done');
    final laneGtReset = Logic(name: 'lane_gt_reset');
    final drpAddr = Logic(name: 'drp_addr', width: 9);
    final drpDataIn = Logic(name: 'drp_data_in', width: 16);
    final drpEnable = Logic(name: 'drp_enable');
    final drpWrite = Logic(name: 'drp_write');
    final drpStart = Logic(name: 'drp_start');

    final sigValidClk = Logic(name: 'sigvalidclk');
    Sequential(pclk, [sigValidClk < ~sigValidClk], reset: rst);
    com.port('PLL0RESET') <= pllRst;
    com.port('PLL0REFCLKSEL') <= Const(0x2, width: 3);

    final laneMods = [
      for (var i = 0; i < lanes; i++)
        HarborGtpPcieLane(
          gts[i],
          pps[i],
          pclk: pclk,
          reset: rst,
          sigValidClk: sigValidClk,
          gtReset: laneGtReset,
          userRdy: userRdy,
          txDlySReset: dlySReset,
          txPhInit: phInit,
          txPhAlign: phAlign,
          txDlyEn: dlyEn,
          linkUp: linkUp,
          rateIdle: rateIdle,
          rateDone: rateDone,
          rate: rateQ,
          drpAddr: drpAddr,
          drpDataIn: drpDataIn,
          drpEnable: drpEnable,
          drpWrite: drpWrite,
          pipeStages: pipeStages,
          name: 'lane$i',
        ),
    ];
    Logic all(Logic Function(HarborGtpPcieLane l) f) =>
        laneMods.map(f).reduce((a, b) => a & b);
    Logic any(Logic Function(HarborGtpPcieLane l) f) =>
        laneMods.map(f).reduce((a, b) => a | b);
    final txDone = all((l) => l.txResetDone).named('tx_resetdone_all');
    final rxDone = all((l) => l.rxResetDone).named('rx_resetdone_all');
    final resetLow = ~any((l) => l.txResetDone | l.rxResetDone);
    final phyAny = any((l) => l.gtPhyStatus).named('gt_phystatus_any');
    final resetDone = waitForRxResetStatus ? txDone & rxDone & ~phyAny : txDone;
    final lane0 = laneMods[0];
    final pma = lane0.rxPmaResetDone;

    final drpReset = HarborGtpDrpReset(
      clk: pclk,
      reset: rst,
      start: drpStart,
      rxPmaResetDone: pma,
      drpReady: lane0.drpReady,
      drpDataOut: lane0.drpDataOut,
      timeoutCycles: timeouts.drp,
    );
    laneGtReset <= gtRst | drpReset.gtReset;
    drpAddr <= drpReset.drpAddr;
    drpDataIn <= drpReset.drpDataIn;
    drpEnable <= drpReset.drpEnable;
    drpWrite <= drpReset.drpWrite;

    Logic rise(Logic s, String name) {
      final q = Logic(name: '${name}_q');
      Sequential(pclk, [q < s], reset: rst);
      return (s & ~q).named('${name}_rise');
    }

    final dlySDoneRise = rise(lane0.txDlySResetDone, 'dlysresetdone');
    final phInitDoneRise = rise(lane0.txPhInitDone, 'phinitdone');
    final phAlignDoneRise = rise(lane0.txPhAlignDone, 'phaligndone');

    final maxWait = [...timeouts.all, 64].reduce((a, b) => a > b ? a : b);
    final tw = maxWait.bitLength;
    final state = Logic(name: 'state', width: 4);
    drpStart <= state.eq(Const(_S.gtReset.code, width: 4));
    final next = Logic(name: 'state_next', width: 4);
    final timer = Logic(name: 'timer', width: tw);
    final pmaSeen = Logic(name: 'pma_seen');
    final stepNext = Logic(name: 'step_next', width: 4);
    final timedOut = Logic(name: 'timed_out');
    final rateFail = Logic(name: 'rate_fail');

    Const s(HarborGtpResetState v) => Const(v.code, width: 4);
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

    Logic isState(List<HarborGtpResetState> l) =>
        l.map((v) => state.eq(s(v))).reduce((a, b) => a | b);

    CaseItem wait(
      HarborGtpResetState st,
      Logic done,
      HarborGtpResetState to,
      int bound,
    ) => CaseItem(s(st), [
      If.block([
        Iff(done, [stepNext < s(to)]),
        ElseIf(at(bound), [timedOut < 1]),
      ]),
    ]);

    final afterPllLock = isState([
      _S.gtReset,
      _S.pmaHigh,
      _S.pmaLow,
      _S.mmcmLock,
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
        (afterPllLock & ~pllLocked) | (afterMmcmLock & ~mmcmLocked);
    final rateTake = rateState.eq(_r(_rTake));

    Combinational([
      stepNext < state,
      timedOut < 0,
      Case(
        state,
        [
          CaseItem(s(_S.cfgWait), [
            If(at(64), then: [stepNext < s(_S.pllReset)]),
          ]),
          wait(
            _S.pllReset,
            resetLow & ~pma & (drivePllReset ? ~pllLocked : Const(1)),
            _S.pllLock,
            timeouts.resetDone,
          ),
          wait(_S.pllLock, pllLocked, _S.gtReset, timeouts.pllLock),
          wait(
            _S.gtReset,
            drpReset.done,
            waitRxPmaResetDone ? _S.pmaHigh : _S.mmcmLock,
            timeouts.pmaResetDone,
          ),
          wait(_S.pmaHigh, pma | pmaSeen, _S.mmcmLock, timeouts.pmaResetDone),
          CaseItem(s(_S.pmaLow), [stepNext < s(_S.mmcmLock)]),
          wait(_S.mmcmLock, mmcmLocked, _S.resetDone, timeouts.mmcmLock),
          wait(_S.resetDone, resetDone, _S.txDlySReset, timeouts.resetDone),
          wait(_S.txDlySReset, dlySDoneRise, _S.txPhInit, timeouts.txSync),
          wait(_S.txPhInit, phInitDoneRise, _S.txPhAlign, timeouts.txSync),
          wait(_S.txPhAlign, phAlignDoneRise, _S.txDlyEn, timeouts.txSync),
          wait(_S.txDlyEn, phAlignDoneRise, _S.idle, timeouts.txSync),
          CaseItem(s(_S.idle), [
            If(rateTake, then: [stepNext < s(_S.txDlySReset)]),
          ]),
        ],
        defaultItem: [timedOut < 1],
      ),
    ]);
    // A failure is registered, so it starts the retry one cycle after the
    // cause. The cycle after a failure cannot fail again, so a lock loss
    // counts once. A DRP failure is a one cycle pulse and takes the same path.
    final failNow = (timedOut | lostLock | rateFail).named('fail_now');
    final fail = Logic(name: 'fail');
    final failCause = Logic(name: 'fail_cause', width: 4);
    // A watchdog restart takes the retry path, but it is not a failure.
    final restart = linkWait == 0 ? null : Logic(name: 'link_restart');
    final failOrRestart = restart == null ? fail : fail | restart;
    next <= mux(failOrRestart, s(_S.pllReset), stepNext);

    Logic nextIs(List<HarborGtpResetState> l) =>
        l.map((v) => next.eq(s(v))).reduce((a, b) => a | b);

    final failState = Logic(name: 'fail_state', width: 4);
    final retries = Logic(name: 'retries', width: 8);
    Sequential(
      pclk,
      [
        state < next,
        fail < drpReset.failed | (failNow & ~fail),
        failCause <
            mux(
              drpReset.failed,
              s(_S.drpReset),
              mux(rateFail, s(_S.rateChange), state),
            ),
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
        If(
          state.eq(s(_S.pllReset)),
          then: [pmaSeen < 0],
          orElse: [
            If(
              pma & isState([_S.pllLock, _S.gtReset, _S.pmaHigh]),
              then: [pmaSeen < 1],
            ),
          ],
        ),
        If(
          fail,
          then: [
            failState < failCause,
            If(~retries.and(), then: [retries < retries + 1]),
          ],
        ),
        pllRst < (drivePllReset ? nextIs([_S.pllReset]) : Const(0)),
        gtRst < nextIs([_S.pllReset, _S.pllLock]),
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
        dlyEn < nextIs([_S.txDlyEn, _S.idle]),
      ],
      reset: rst,
      resetValues: {
        state: s(_S.cfgWait),
        failState: s(_S.none),
        timerZero: Const(1),
      },
    );

    // Rate change, on the rate of lane 0. The hard block drives one rate for
    // all lanes.
    final rateQ2 = Logic(name: 'rate_q2');
    final rateTimer = Logic(name: 'rate_timer', width: timeouts.rate.bitLength);
    final txRateSeen = Logic(name: 'tx_rate_seen');
    final rxRateSeen = Logic(name: 'rx_rate_seen');
    final phySeen = Logic(name: 'phy_seen');
    final rateChange = (rateQ ^ rateQ2).named('rate_change');
    final idleNow = state.eq(s(_S.idle));
    // rate_hit is high when the timer was rate - 2 in wait in the last
    // cycle. In wait the timer counts up on each cycle.
    final rateHit = Logic(name: 'rate_hit');
    final rateWait = rateState.eq(_r(_rWait));
    rateFail <= rateWait & rateHit;
    Sequential(pclk, [
      rateQ < _pipeDelay(pclk, pps[0].pipeRate, pipeStages, 'rate'),
      rateQ2 < rateQ,
      rateHit <
          rateWait &
              rateTimer.eq(
                Const(timeouts.rate - 2, width: timeouts.rate.bitLength),
              ),
      If(
        failOrRestart,
        then: [rateState < _r(_rIdle), rateTimer < 0],
        orElse: [
          Case(
            rateState,
            [
              CaseItem(_r(_rIdle), [
                If(
                  rateChange & idleNow,
                  then: [
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
                If(lane0.txRateDone, then: [txRateSeen < 1]),
                If(lane0.rxRateDone, then: [rxRateSeen < 1]),
                If(lane0.gtPhyStatus, then: [phySeen < 1]),
                If(
                  txRateSeen & rxRateSeen & phySeen,
                  then: [rateState < _r(_rTake)],
                ),
              ]),
              CaseItem(_r(_rTake), [
                If(~idleNow, then: [rateState < _r(_rBack)]),
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
              ~failOrRestart &
              ~failNow &
              ~drpReset.failed,
    ], reset: rst);

    addOutput('reset_state', width: 4) <= state;
    addOutput('reset_fail_state', width: 4) <= failState;
    addOutput('reset_retries', width: 8) <= retries;
    addOutput('phy_ready') <= linkUp;

    if (restart == null) return;
    final hardUp = sync(
      addInput('hard_link_up', hardLinkUp!),
      'hard_link_up_s',
    );
    final waiting = (linkUp & ~hardUp).named('link_waiting');
    final lw = linkWait.bitLength;
    final linkTimer = Logic(name: 'link_timer', width: lw);
    final linkHit = Logic(name: 'link_hit');
    final linkRetrains = Logic(name: 'link_retrains', width: 8);
    restart <= linkHit & waiting;
    // link_hit is high when the timer was linkWait - 1 in the last cycle.
    Sequential(pclk, [
      If(waiting, then: [linkTimer < linkTimer + 1], orElse: [linkTimer < 0]),
      linkHit < waiting & linkTimer.eq(Const(linkWait - 1, width: lw)),
      If(
        restart & ~linkRetrains.and(),
        then: [linkRetrains < linkRetrains + 1],
      ),
    ], reset: rst);
    addOutput('link_retrains', width: 8) <= linkRetrains;
  }

  static const _rIdle = 0;
  static const _rWait = 1;
  static const _rTake = 2;
  static const _rBack = 3;
  static const _rDone = 4;

  static Const _r(int v) => Const(v, width: 3);
}
