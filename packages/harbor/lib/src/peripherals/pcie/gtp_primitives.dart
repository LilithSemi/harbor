import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'gtp_pcie_params.dart';
import 'gtp_pcie_phy.dart';
import 'pcie_pipe.dart';

class HarborXilinxIbufdsGte2 extends BridgeModule {
  Logic get clock => output('O');

  HarborXilinxIbufdsGte2({
    required Logic p,
    required Logic n,
    super.name = 'pcie_refclk_buffer',
  }) : super('IBUFDS_GTE2', isSystemVerilogLeaf: true) {
    addInput('I', p);
    addInput('IB', n);
    addInput('CEB', Const(0));
    addOutput('O');
    addOutput('ODIV2');
  }
}

class HarborXilinxGtpe2Common extends BridgeModule {
  Logic get pll0OutClk => output('PLL0OUTCLK');
  Logic get pll0OutRefClk => output('PLL0OUTREFCLK');

  HarborXilinxGtpe2Common({
    required Logic refClk1,
    required HarborGtpCommonPorts ports,
    super.name = 'pcie_gtp_common',
  }) : super('GTPE2_COMMON', isSystemVerilogLeaf: true) {
    for (final parameter in gtpe2CommonPcieParameters.entries) {
      createParameter(parameter.key, parameter.value);
    }
    HarborGtpCommonPorts().pairConnectIO(this, ports, PairRole.provider);
    addInput('GTREFCLK1', refClk1);
    for (final tie in gtpe2CommonPcieTieOffs.entries) {
      addInput(
        tie.key,
        Const(tie.value.$2, width: tie.value.$1),
        width: tie.value.$1,
      );
    }
    addOutput('PLL0OUTCLK');
    addOutput('PLL0OUTREFCLK');
  }
}

class HarborXilinxGtpe2Channel extends BridgeModule {
  Logic get txP => output('GTPTXP');
  Logic get txN => output('GTPTXN');

  HarborXilinxGtpe2Channel({
    required Logic rxP,
    required Logic rxN,
    required Logic pll0Clk,
    required Logic pll0RefClk,
    required HarborGtpChannelPorts ports,
    super.name = 'pcie_gtp_channel',
  }) : super('GTPE2_CHANNEL', isSystemVerilogLeaf: true) {
    for (final parameter in gtpe2ChannelPcieParameters.entries) {
      createParameter(parameter.key, parameter.value);
    }
    HarborGtpChannelPorts().pairConnectIO(this, ports, PairRole.provider);
    addInput('GTPRXP', rxP);
    addInput('GTPRXN', rxN);
    addInput('PLL0CLK', pll0Clk);
    addInput('PLL0REFCLK', pll0RefClk);
    addInput('PLL1CLK', Const(0));
    addInput('PLL1REFCLK', Const(0));
    for (final tie in gtpe2ChannelPcieTieOffs.entries) {
      addInput(
        tie.key,
        Const(tie.value.$2, width: tie.value.$1),
        width: tie.value.$1,
      );
    }
    addOutput('GTPTXP');
    addOutput('GTPTXN');
  }
}

/// Artix-7 x1 GTP physical layer for the 7-series PCIe hard block.
class HarborArtix7PciePhy extends Module {
  Logic get txP => output('tx_p');
  Logic get txN => output('tx_n');
  Logic get pclk => output('pclk');
  Logic get userClk1 => output('userclk1');
  Logic get userClk2 => output('userclk2');
  Logic get ready => output('ready');

  /// MMCM lock, not synchronised.
  Logic get mmcmLock => output('mmcm_lock');

  /// Current [HarborGtpResetState] code.
  Logic get resetState => output('reset_state');

  /// [HarborGtpResetState] code of the last failure.
  Logic get resetFailState => output('reset_fail_state');

  /// Number of failures since reset, it stops at 255.
  Logic get resetRetries => output('reset_retries');

  /// Number of link training watchdog restarts, it stops at 255. Null when
  /// the watchdog is off.
  Logic? get linkRetrains =>
      timeouts.linkWait == 0 ? null : output('link_retrains');

  /// The link inputs are optional as in [HarborGtpPciePhy]. They are
  /// necessary only when [HarborGtpPcieTimeouts.linkWait] is not 0, and the
  /// PHY gives an [ArgumentError] when they are missing.
  HarborArtix7PciePhy({
    required Logic refClkP,
    required Logic refClkN,
    required Logic perstN,
    Logic? hardLinkUp,
    Logic? phyLinkUpN,
    Logic? ltssmState,
    required Logic rxP,
    required Logic rxN,
    required HarborPciePipeLane pipe,
    this.waitForRxResetStatus = true,
    this.pipeStages = 1,
    this.timeouts = const HarborGtpPcieTimeouts(),
    super.name = 'pcie_phy',
  }) : super(
         definitionName: [
           'HarborArtix7PciePhy_X1',
           if (pipeStages != 0) 'Pipe$pipeStages',
           if (timeouts.linkWait != 0) 'LinkWd',
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
    final commonPorts = HarborGtpCommonPorts();
    final common = HarborXilinxGtpe2Common(
      refClk1: refclk.clock,
      ports: commonPorts,
    );
    final channelPorts = HarborGtpChannelPorts();
    final channel = HarborXilinxGtpe2Channel(
      rxP: rxP,
      rxN: rxN,
      pll0Clk: common.pll0OutClk,
      pll0RefClk: common.pll0OutRefClk,
      ports: channelPorts,
    );
    final phy = HarborGtpPciePhy(
      perstN: perstN,
      hardLinkUp: hardLinkUp,
      phyLinkUpN: phyLinkUpN,
      ltssmState: ltssmState,
      common: commonPorts,
      channels: [channelPorts],
      pipes: [localPipe],
      drivePllReset: false,
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
    if (watch) addOutput('link_retrains', width: 8) <= phy.linkRetrains!;
  }

  /// Bounds of the waits and of the link training watchdog.
  final HarborGtpPcieTimeouts timeouts;

  /// Wait for RXRESETDONE and startup PHYSTATUS before TX buffer alignment.
  final bool waitForRxResetStatus;

  /// Registers on each PIPE signal, 0 to 2.
  final int pipeStages;
}
