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

  HarborArtix7PciePhy({
    required Logic refClkP,
    required Logic refClkN,
    required Logic perstN,
    required Logic rxP,
    required Logic rxN,
    required HarborPciePipeLane pipe,
    this.waitForRxResetStatus = true,
    super.name = 'pcie_phy',
  }) : super(definitionName: 'HarborArtix7PciePhy_X1') {
    refClkP = addInput('refclk_p', refClkP);
    refClkN = addInput('refclk_n', refClkN);
    perstN = addInput('perst_n', perstN);
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
      common: commonPorts,
      channels: [channelPorts],
      pipes: [localPipe],
      drivePllReset: false,
      waitForRxResetStatus: waitForRxResetStatus,
    );

    addOutput('tx_p') <= channel.txP;
    addOutput('tx_n') <= channel.txN;
    addOutput('pclk') <= phy.pclk;
    addOutput('userclk1') <= phy.userClk1;
    addOutput('userclk2') <= phy.userClk2;
    addOutput('ready') <= phy.phyReady;
  }

  /// Wait for RXRESETDONE and startup PHYSTATUS before TX buffer alignment.
  final bool waitForRxResetStatus;
}
