import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'gtp_pcie_phy.dart' show harborCheckPipeStages;
import 'gtp_primitives.dart';
import 'gtx_pcie_params.dart';
import 'gtx_pcie_phy.dart';
import 'pcie_phy.dart';
import 'pcie_pipe.dart';
import 'pipe_clock.dart';

/// GTXE2_CHANNEL with the PCIe parameter set of [gtxe2ChannelPcieParameters].
///
/// The CPLL takes the reference clock on GTREFCLK0.
/// CLKRSVD[0] is the OOB clock. Bit 3 of PCS_RSVD_ATTR selects it.
class HarborXilinxGtxe2Channel extends BridgeModule {
  Logic get txP => output('GTXTXP');
  Logic get txN => output('GTXTXN');

  HarborXilinxGtxe2Channel({
    required Logic rxP,
    required Logic rxN,
    required Logic refClk,
    required HarborGtxChannelPorts ports,
    super.name = 'pcie_gtx_channel',
  }) : super('GTXE2_CHANNEL', isSystemVerilogLeaf: true) {
    for (final parameter in gtxe2ChannelPcieParameters.entries) {
      createParameter(parameter.key, parameter.value);
    }
    HarborGtxChannelPorts().pairConnectIO(this, ports, PairRole.provider);
    addInput('GTXRXP', rxP);
    addInput('GTXRXN', rxN);
    addInput('GTREFCLK0', refClk);
    for (final tie in gtxe2ChannelPcieTieOffs.entries) {
      addInput(
        tie.key,
        Const(tie.value.$2, width: tie.value.$1),
        width: tie.value.$1,
      );
    }
    addOutput('GTXTXP');
    addOutput('GTXTXN');
  }
}

/// Kintex-7 x1 GTX physical layer for the 7-series PCIe hard block.
///
/// [refClkP] and [refClkN] go to an IBUFDS_GTE2, and its output is the CPLL
/// reference clock. The link inputs are optional as in [HarborGtxPciePhy].
class HarborKintex7PciePhy extends HarborPciePhy {
  /// 1 when the CPLL is locked, not synchronised.
  Logic get cpllLock => output('cpll_lock');

  /// 1 when the RX CDR is locked, not synchronised.
  Logic get rxCdrLock => output('rx_cdr_lock');

  /// TXRESETDONE and RXRESETDONE, synchronised to `pclk`.
  Logic get txResetDone => output('tx_reset_done');
  Logic get rxResetDone => output('rx_reset_done');

  /// A bit is 1 from the first timeout of a wait until PERST#, see
  /// [HarborGtxPciePhy.timeoutFlags].
  Logic get timeoutFlags => output('timeout_flags');

  /// 0 for 125 MHz `pclk` and 1 for 250 MHz.
  Logic get pclkSel => output('pclk_sel');

  /// See [HarborGtxPciePhy.txSync].
  Logic get txSync => output('tx_sync');

  /// See [HarborGtxPciePhy.txSyncSeen].
  Logic get txSyncSeen => output('tx_sync_seen');

  /// See [HarborGtxPciePhy.rxDebug].
  Logic get rxDebug => output('rx_debug');

  /// See [HarborGtxPciePhy.phAlignCount].
  Logic get phAlignCount => output('phalign_count');

  HarborKintex7PciePhy({
    required Logic refClkP,
    required Logic refClkN,
    required Logic perstN,
    Logic? hardLinkUp,
    Logic? phyLinkUpN,
    Logic? ltssmState,
    required Logic rxP,
    required Logic rxN,
    required HarborPciePipeLane pipe,
    this.gen2 = true,
    this.userClkRequest,
    this.registerMmcmLock = true,
    this.debugSkipTxPhaseAlign = false,
    this.debugBuild = false,
    this.waitRxCdrLock = false,
    this.waitForRxResetStatus = true,
    this.pipeStages = 1,
    this.timeouts = const HarborGtxPcieTimeouts(),
    super.name = 'pcie_phy',
  }) : super(
         definitionName: [
           'HarborKintex7PciePhy_X1',
           if (gen2) 'G2',
           if (userClkRequest != null &&
               userClkRequest !=
                   HarborPipeClock.vcoHz ~/
                       HarborGtxPciePhy.userClkDivide(gen2: gen2))
             'Uc${userClkRequest ~/ 1000}',
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
    refClkP = addInput('refclk_p', refClkP);
    refClkN = addInput('refclk_n', refClkN);
    perstN = addInput('perst_n', perstN);
    final watch = timeouts.linkWait != 0;
    Logic? port(String name, Logic? l, [int width = 1]) =>
        watch && l != null ? addInput(name, l, width: width) : null;
    hardLinkUp = port('hard_link_up', hardLinkUp);
    phyLinkUpN = port('phy_link_up_n', phyLinkUpN);
    ltssmState = port('ltssm_state', ltssmState, 6);
    rxP = addInput('rx_p', rxP);
    rxN = addInput('rx_n', rxN);
    final localPipe = HarborPciePipeLane()
      ..pairConnectIO(this, pipe, PairRole.provider);

    final refclk = HarborXilinxIbufdsGte2(p: refClkP, n: refClkN);
    final channelPorts = HarborGtxChannelPorts();
    final channel = HarborXilinxGtxe2Channel(
      rxP: rxP,
      rxN: rxN,
      refClk: refclk.clock,
      ports: channelPorts,
    );
    final phy = HarborGtxPciePhy(
      perstN: perstN,
      hardLinkUp: hardLinkUp,
      phyLinkUpN: phyLinkUpN,
      ltssmState: ltssmState,
      channel: channelPorts,
      pipe: localPipe,
      gen2: gen2,
      userClkHz: userClkRequest,
      registerMmcmLock: registerMmcmLock,
      debugSkipTxPhaseAlign: debugSkipTxPhaseAlign,
      debugBuild: debugBuild,
      waitRxCdrLock: waitRxCdrLock,
      waitForRxResetStatus: waitForRxResetStatus,
      pipeStages: pipeStages,
      timeouts: timeouts,
    );

    addOutput('tx_p') <= channel.txP;
    addOutput('tx_n') <= channel.txN;
    addOutput('pclk') <= phy.pclk;
    addOutput('userclk1') <= phy.userClk1;
    addOutput('userclk2') <= phy.userClk2;
    addOutput('ready') <= phy.phyReady;
    addOutput('mmcm_lock') <= phy.mmcmLock;
    addOutput('reset_state', width: 4) <= phy.resetState;
    addOutput('reset_fail_state', width: 4) <= phy.resetFailState;
    addOutput('reset_retries', width: 8) <= phy.resetRetries;
    addOutput('cpll_lock') <= channelPorts.port('CPLLLOCK');
    addOutput('rx_cdr_lock') <= channelPorts.port('RXCDRLOCK');
    addOutput('tx_reset_done') <= phy.txResetDone;
    addOutput('rx_reset_done') <= phy.rxResetDone;
    addOutput('timeout_flags', width: HarborGtxPciePhy.timeoutFlagBits) <=
        phy.timeoutFlags;
    addOutput('pclk_sel') <= phy.pclkSel;
    addOutput('rx_debug', width: HarborGtxPciePhy.rxDebugBits) <= phy.rxDebug;
    addOutput('tx_sync', width: 4) <= phy.txSync;
    addOutput('tx_sync_seen', width: 3) <= phy.txSyncSeen;
    addOutput('phalign_count', width: 4) <= phy.phAlignCount;
    if (watch) addOutput('link_retrains', width: 8) <= phy.linkRetrains!;
  }

  @override
  int get userClkHz => HarborPipeClock.userClkHz(
    HarborGtxPciePhy.userClkDivideFor(gen2: gen2, hz: userClkRequest),
  );

  /// The requested user clock in Hz, or null for the default of [gen2].
  final int? userClkRequest;

  /// Run at 5 GT/s when the hard block asks for it.
  final bool gen2;

  /// Debug option, see [HarborGtxPciePhy.debugSkipTxPhaseAlign].
  final bool debugSkipTxPhaseAlign;

  /// Allows the debug options.
  final bool debugBuild;

  /// Take the MMCM lock from a flop, see [HarborGtxPciePhy.registerMmcmLock].
  final bool registerMmcmLock;

  /// Wait for RXCDRLOCK before USERRDY.
  final bool waitRxCdrLock;

  /// Wait for RXRESETDONE and startup PHYSTATUS before TX phase alignment.
  final bool waitForRxResetStatus;

  /// Registers on each PIPE signal, 0 to 2.
  final int pipeStages;

  /// Bounds of the waits and of the link training watchdog.
  final HarborGtxPcieTimeouts timeouts;
}
