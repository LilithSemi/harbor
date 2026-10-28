import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../arith/fpu_config.dart' show harborStableDefinitionName;
import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../bus/port/memory_port.dart';
import '../bus/port/memory_waist.dart';
import '../bus/port/waist_arbiter.dart';
import '../clock/cdc.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../soc/target.dart';
import 'ethernet/eth_byte_stream.dart';
import 'ethernet/eth_config.dart';
import 'ethernet/eth_constraint.dart';
import 'ethernet/eth_dma_rx.dart';
import 'ethernet/eth_dma_tx.dart';
import 'ethernet/eth_frame_fifo.dart';
import 'ethernet/eth_mac_rx.dart';
import 'ethernet/eth_mac_tx.dart';
import 'ethernet/eth_mdio.dart';
import 'ethernet/eth_phy_mii.dart';
import 'ethernet/eth_phy_rgmii.dart';
import 'ethernet/eth_phy_rmii.dart';
import 'ethernet/eth_regs.dart';

/// Ethernet MAC with descriptor DMA.
///
/// The MAC has a 32-bit register port `bus` with the map in [HarborEthReg],
/// a 32-bit memory master port `dma`, the MDIO pins, an `interrupt` output
/// and the pins of the PHY front end that [HarborEthernetConfig.phy]
/// selects:
///
/// - MII: inputs `mii_tx_clk`, `mii_rx_clk`, `mii_rxd`, `mii_rx_dv`,
///   `mii_rx_er`, `mii_crs`, `mii_col`. Outputs `mii_txd`, `mii_tx_en`,
///   `mii_tx_er`.
/// - RMII: inputs `rmii_ref_clk`, `rmii_rxd`, `rmii_crs_dv`, `rmii_rx_er`.
///   Outputs `rmii_txd`, `rmii_tx_en`.
/// - RGMII: inputs `clk125`, `clk125_90`, `rgmii_rxc`, `rgmii_rxd`,
///   `rgmii_rx_ctl`, and `clk200` when the front end builds an IDELAYCTRL.
///   Outputs `rgmii_txc`, `rgmii_txd`, `rgmii_tx_ctl`.
///
/// MDIO uses `mdc`, `mdio_out`, `mdio_oe` and `mdio_in`, and the board
/// makes the pad from them. With `mdioPad` true the MAC has one inout pad
/// `mdio` with a tristate buffer in their place.
///
/// The timing constraints of the PHY pins go into the SoC constraint file
/// when the SoC exposes the PHY pins. See [constraints]. The constraints of
/// the clock domain crossings go into it on Xilinx. See [cdcConstraints].
///
/// The TX and RX DMAs share `dma`. TX requests use ID 0 and RX requests use
/// ID 2, so the responses of the two never mix. A frame that the TX FIFO
/// drops because the TX clock is lost comes back with TX error code 4.
///
/// The MAC cores and the front end reset only with `reset`. CTRL soft_reset
/// resets the FIFOs and the DMAs after the DMAs are idle. It also restarts
/// the FIFO clock watches, so STATUS tx_clk_lost and rx_clk_lost read 0 and
/// a clock that is still lost is found again after the watch time. See
/// [HarborEthRegs].
///
/// The counters count at the MACs. TX_FRAMES counts each frame the TX MAC
/// ended, bad frames too. RX_FRAMES, RX_FCS_ERR, RX_RUNT and RX_OVERSIZE
/// count frames after the address filter, also frames that the RX FIFO
/// drops later (RX_OVERFLOW) or the RX DMA misses (RX_MISSED). Frames in the
/// TX FIFO when the TX clock is lost have a done write-back with no error
/// and are lost. TX_FRAMES shows how many went out.
///
/// Each MAC event crosses to the sys clock as a toggle, so events must be 3
/// sys cycles apart. Frame ends are at least 26 byte times apart, so the
/// sys clock must be at least 15 MHz at 1000 Mbps, 1.5 MHz at 100 Mbps and
/// 0.15 MHz at 10 Mbps. The DMA bandwidth usually asks for more.
class HarborEthernetMac extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider,
        HarborPinConstraintProvider,
        HarborInputClockConsumer {
  /// MAC configuration.
  final HarborEthernetConfig config;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Fabric kind of both ports.
  final HarborFabricKind fabricKind;

  /// Device the MAC is built for.
  final HarborDeviceTarget target;

  /// Register port address width. Decode uses the low 12 bits.
  final int busAddressWidth;

  /// Address width of the DMA master port, 12 to 64.
  final int dmaAddressWidth;

  /// True when MDIO is one inout pad `mdio`.
  final bool mdioPad;

  /// Rate of `clk` in Hz, or 0 when it is not known. The SoC gives it when
  /// it is 0. The device tree has it as `clock-frequency`, so the driver
  /// can set the MDC divider, and it sets the clock domain crossing
  /// constraints.
  int clockFrequency;

  /// Size of the register window.
  static const windowBytes = 0x1000;

  /// Register slave port.
  late final BusSlavePort bus;

  /// DMA memory master port.
  late final HarborMemoryMasterPort dma;

  HarborEthPhyRgmii? _rgmii;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  /// Interrupt output, the same as [interrupt].
  Logic get irq => interrupt;

  HarborEthernetMac({
    required this.baseAddress,
    required this.config,
    required this.fabricKind,
    required this.target,
    this.busAddressWidth = 12,
    this.dmaAddressWidth = 32,
    this.mdioPad = false,
    this.clockFrequency = 0,
    bool crossFabricClock = false,
    bool idelayCtrl = true,
    String? name,
  }) : super(
         harborStableDefinitionName('HarborEthernetMac', [
           ...BusSlavePort.definitionNameParts(
             kind: fabricKind,
             addressWidth: busAddressWidth,
             dataWidth: 32,
             cross: crossFabricClock,
           ),
           'm$dmaAddressWidth',
           config.phy.name,
           'c${config.hwCaps.toRadixString(16)}',
           'o${config.outstanding}',
           'b${config.burstBeats}',
           if (config.phy == HarborEthPhy.rgmii) ...[
             target.name.replaceAll(RegExp('[^A-Za-z0-9]'), '_'),
             's${config.txClockShift ? 1 : 0}',
             'd${config.rgmiiRxDelayTaps}',
             'p${config.rgmiiPhyRxDelay ? 1 : 0}',
             if (!idelayCtrl) 'nc',
           ],
           if (config.phy != HarborEthPhy.rgmii && target.blockRam != null)
             target.blockRam!.name,
           if (mdioPad) 'pad',
         ]),
         name: name ?? 'ethernet',
       ) {
    if (dmaAddressWidth < 12 || dmaAddressWidth > 64) {
      throw ArgumentError.value(
        dmaAddressWidth,
        'dmaAddressWidth',
        'must be 12 to 64',
      );
    }
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final irqOut = addOutput('interrupt');
    final mdcOut = addOutput('mdc');
    final Logic mdioIn;
    final Logic mdioOut;
    final Logic mdioOe;
    if (mdioPad) {
      createPort('mdio', PortDirection.inOut);
      mdioIn = inOut('mdio');
      mdioOut = Logic(name: 'mdio_o');
      mdioOe = Logic(name: 'mdio_t');
      inOut('mdio') <= TriStateBuffer(mdioOut, enable: mdioOe).out;
    } else {
      createPort('mdio_in', PortDirection.input);
      mdioIn = input('mdio_in');
      mdioOut = addOutput('mdio_out');
      mdioOe = addOutput('mdio_oe');
    }

    final fabricClock = BusSlavePort.fabricClockInputs(
      this,
      cross: crossFabricClock,
    );
    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      kind: fabricKind,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: busAddressWidth,
      dataWidth: 32,
      fabricClock: fabricClock,
    );
    final waistConfig = HarborMemoryWaistConfig(
      addressWidth: dmaAddressWidth,
      dataWidth: 32,
      idWidth: 1,
      outstanding: config.outstanding,
    );
    dma = HarborMemoryMasterPort.create(
      module: this,
      name: 'dma',
      kind: fabricKind,
      config: HarborMemoryWaistConfig(
        addressWidth: dmaAddressWidth,
        dataWidth: 32,
        idWidth: 2,
        outstanding: config.outstanding,
      ),
      clk: input('clk'),
      reset: input('reset'),
      fabricClock: fabricClock,
    );

    final clk = input('clk');
    final resetIn = crossFabricClock
        ? (bus.reset | dma.reset).named('core_reset')
        : bus.reset;
    // A registered copy of the reset, so the long reset net ends at one flop.
    final reset = Logic(name: 'sys_reset_r');
    Sequential(clk, [reset < resetIn]);

    // Values from blocks that are built after the register file.
    Logic fwd(String n, [int w = 1]) => Logic(name: n, width: w);
    const iw = HarborEthDmaTx.indexWidth;
    final txHead = fwd('tx_head', iw);
    final rxHead = fwd('rx_head', iw);
    final txBusy = fwd('tx_busy');
    final rxBusy = fwd('rx_busy');
    final busIdle = fwd('bus_idle');
    final txRingErr = fwd('tx_ring_err');
    final rxRingErr = fwd('rx_ring_err');
    final txDone = fwd('tx_done');
    final txErr = fwd('tx_err');
    final rxDone = fwd('rx_done');
    final rxErr = fwd('rx_err');
    final rxMissed = fwd('rx_missed');
    final txClkLost = fwd('tx_clk_lost');
    final rxClkLost = fwd('rx_clk_lost');
    final rxOverflow = fwd('rx_overflow');
    final evTx = fwd('ev_tx_frame');
    final evRx = fwd('ev_rx_frame');
    final evFcs = fwd('ev_rx_fcs');
    final evRunt = fwd('ev_rx_runt');
    final evOver = fwd('ev_rx_oversize');
    final mdioBusy = fwd('mdio_busy');
    final mdioRdone = fwd('mdio_rdone');
    final mdioRdata = fwd('mdio_rdata', 16);
    final txPathBusy = fwd('tx_path_busy');
    final rxPathBusy = fwd('rx_path_busy');

    final regs = HarborEthRegs(
      clk,
      reset,
      config: config,
      dmaAddressWidth: dmaAddressWidth,
      stb: bus.stb,
      addr: bus.windowAddr(windowBytes),
      we: bus.we,
      wdata: bus.dataIn,
      sel: bus.sel,
      txHead: txHead,
      rxHead: rxHead,
      txBusy: txBusy,
      rxBusy: rxBusy,
      busIdle: busIdle,
      txRingErr: txRingErr,
      rxRingErr: rxRingErr,
      txDone: txDone,
      txErr: txErr,
      rxDone: rxDone,
      rxErr: rxErr,
      rxMissed: rxMissed,
      txClkLost: txClkLost,
      rxClkLost: rxClkLost,
      rxOverflow: rxOverflow,
      evTxFrame: evTx,
      evRxFrame: evRx,
      evRxFcs: evFcs,
      evRxRunt: evRunt,
      evRxOversize: evOver,
      mdioBusy: mdioBusy,
      mdioRdone: mdioRdone,
      mdioRdata: mdioRdata,
      txPathBusy: txPathBusy,
      rxPathBusy: rxPathBusy,
    );
    // The register file resets one cycle after the port, so its ack stays
    // low in that cycle.
    bus.ack <= regs.ack & ~reset;
    bus.dataOut <= regs.rdata;
    irqOut <= regs.irq;

    final mdio = HarborEthMdio(
      clk,
      reset,
      config: config,
      start: regs.mdioStart,
      write: regs.mdioWrite,
      phy: regs.mdioPhy,
      reg: regs.mdioReg,
      wdata: regs.mdioWdata,
      div: regs.mdioDiv,
      mdioIn: mdioIn,
      c45: config.mdioC45 ? regs.mdioC45 : null,
      devad: config.mdioC45 ? regs.mdioDevad : null,
      addr: config.mdioC45 ? regs.mdioAddr : null,
    );
    mdioBusy <= mdio.busy;
    mdioRdone <= mdio.rdone;
    mdioRdata <= mdio.rdata;
    mdcOut <= mdio.mdc;
    mdioOut <= mdio.mdioOut;
    mdioOe <= mdio.mdioOe;

    final stream = HarborEthByteStream();
    _frontEnd(stream, reset, regs.speed, idelayCtrl);

    // Soft reset reaches the FIFOs, the DMAs and the bus arbiter.
    final dpReset = Logic(name: 'datapath_reset');
    Sequential(clk, [dpReset < resetIn | regs.softReset]);

    // TX path.
    final macInReady = fwd('mac_in_ready');
    final txW = HarborMemoryWaist(waistConfig);
    final fifoWReady = fwd('tx_fifo_w_ready');
    final fifoWDrop = fwd('tx_fifo_w_drop');
    final fifoWFree = fwd(
      'tx_fifo_w_free',
      (config.txFifoBytes ~/ 4).bitLength,
    );
    final dmaTx = HarborEthDmaTx(
      clk,
      dpReset,
      waist: txW,
      config: config,
      ringBase: regs.txRingBase,
      ringSize: regs.txRingSize,
      tail: regs.txTail,
      txEn: regs.txEn,
      ringReset: regs.txRingReset,
      wReady: fifoWReady,
      wFree: fifoWFree,
      txClkLost: fifoWDrop,
    );
    final txFifo = HarborEthTxFrameFifo(
      clk,
      dpReset,
      stream.txClk,
      stream.txReset,
      bytes: config.txFifoBytes,
      wValid: dmaTx.wValid,
      wData: dmaTx.wData,
      wBytes: dmaTx.wBytes,
      wLast: dmaTx.wLast,
      wErr: dmaTx.wErr,
      inReady: macInReady,
      clkLostClear: regs.txClkLostClear,
      target: target,
    );
    fifoWReady <= txFifo.wReady;
    fifoWDrop <= txFifo.wDrop;
    fifoWFree <= txFifo.wFree;
    // The MAC cores take registered copies of the PHY side resets, so they
    // can be far from the front end.
    final txCoreReset = Logic(name: 'tx_core_reset');
    Sequential(stream.txClk, [txCoreReset < stream.txReset]);
    final rxCoreReset = Logic(name: 'rx_core_reset');
    Sequential(stream.rxClk, [rxCoreReset < stream.rxReset]);
    final macTx = HarborEthMacTx(
      stream.txClk,
      txCoreReset,
      config: config,
      txStrobe: stream.txStrobe,
      inValid: txFifo.inValid,
      inData: txFifo.inData,
      inLast: txFifo.inLast,
      inErr: txFifo.inErr,
    );
    macInReady <= macTx.inReady;
    stream.txData <= macTx.txData;
    stream.txEn <= macTx.txEn;
    stream.txEr <= macTx.txEr;

    // RX path.
    final macRx = HarborEthMacRx(
      stream.rxClk,
      rxCoreReset,
      config: config,
      rxStrobe: stream.rxStrobe,
      rxData: stream.rxData,
      rxDv: stream.rxDv,
      rxEr: stream.rxEr,
      rxEn: regs.rxEn,
      macAddr: regs.macAddr,
      mcHash: config.multicastHash ? regs.mcHash : null,
      promisc: config.promiscuous ? regs.promisc : null,
    );
    final dmaRReady = fwd('rx_dma_r_ready');
    final rxFifo = HarborEthRxFrameFifo(
      stream.rxClk,
      stream.rxReset,
      clk,
      dpReset,
      bytes: config.rxFifoBytes,
      inValid: macRx.outValid,
      inData: macRx.outData,
      inLast: macRx.outLast,
      inStatus: macRx.outStatus,
      rReady: dmaRReady,
      clkLostClear: regs.rxClkLostClear,
      target: target,
    );
    final rxW = HarborMemoryWaist(waistConfig);
    final dmaRx = HarborEthDmaRx(
      clk,
      dpReset,
      waist: rxW,
      config: config,
      ringBase: regs.rxRingBase,
      ringSize: regs.rxRingSize,
      tail: regs.rxTail,
      rxEn: regs.rxEn,
      keepBad: regs.keepBad,
      ringReset: regs.rxRingReset,
      rValid: rxFifo.rValid,
      rData: rxFifo.rData,
      rBytes: rxFifo.rBytes,
      rLast: rxFifo.rLast,
      rStatus: rxFifo.rStatus,
    );
    dmaRReady <= dmaRx.rReady;

    final arb = HarborWaistArbiter(
      clk,
      dpReset,
      sources: [txW, rxW],
      out: dma.waist,
    );

    txHead <= dmaTx.head;
    rxHead <= dmaRx.head;
    txBusy <= dmaTx.busy;
    rxBusy <= dmaRx.busy;
    busIdle <= arb.idle;
    txRingErr <= dmaTx.ringErr;
    rxRingErr <= dmaRx.ringErr;
    txDone <= dmaTx.txDone;
    txErr <= dmaTx.txErr;
    rxDone <= dmaRx.rxDone;
    rxErr <= dmaRx.rxErr;
    rxMissed <= dmaRx.rxMissed;
    txClkLost <= txFifo.clkLost;
    rxClkLost <= rxFifo.clkLost;
    rxOverflow <= rxFifo.rxOverflow;

    // Each MAC event crosses to the sys clock as its own toggle.
    Logic sysPulse(String n, Logic phyClk, Logic phyReset, Logic ev) =>
        _toggleSync(n, phyClk, phyReset, ev, clk, reset);
    evTx <=
        sysPulse('tx_frame', stream.txClk, stream.txReset, macTx.txFrameDone);
    final rxEnd = (macRx.outValid & macRx.outLast).named('rx_frame_end');
    final st = macRx.outStatus;
    final bad = (st.getRange(0, 4).or()).named('rx_frame_bad');
    for (final (ev, n, cond) in [
      (evRx, 'rx_good', ~bad),
      (evFcs, 'rx_fcs', st[0]),
      (evRunt, 'rx_runt', st[1]),
      (evOver, 'rx_oversize', st[2]),
    ]) {
      ev <= sysPulse(n, stream.rxClk, stream.rxReset, rxEnd & cond);
    }

    // Path busy bits for STATUS running. The TX FIFO sys side counts its
    // words, the PHY sides come through synchronizers. The sys side holds
    // its bit 3 cycles longer, so that a word that moves to the TX side is
    // seen on one of the two at all times. The RX side also stays busy while
    // the RX MAC sees rx_en, since it can start a frame until then.
    final txPhyBusy = Logic(name: 'tx_phy_busy');
    Sequential(stream.txClk, reset: stream.txReset, [
      txPhyBusy < txFifo.outBusy | macTx.busy,
    ]);
    final rxPhyBusy = Logic(name: 'rx_phy_busy');
    Sequential(stream.rxClk, reset: stream.rxReset, [
      rxPhyBusy < macRx.busy | macRx.enabled,
    ]);
    final words = config.txFifoBytes ~/ 4;
    final notEmpty = txFifo.wFree
        .neq(Const(words - 1, width: txFifo.wFree.width))
        .named('tx_fifo_not_empty');
    final hold = Logic(name: 'tx_fifo_hold', width: 3);
    Sequential(clk, reset: reset, [
      hold < [hold.getRange(0, 2), notEmpty].swizzle(),
    ]);
    txPathBusy <=
        notEmpty | hold.or() | _sync('tx_phy_busy', txPhyBusy, clk, reset);
    rxPathBusy <= _sync('rx_phy_busy', rxPhyBusy, clk, reset);
  }

  static Logic _sync(String name, Logic src, Logic clk, Logic reset) {
    final s = HarborCdcSync(name: '${name}_sync');
    s.input('async_in').srcConnection! <= src;
    s.input('dst_clk').srcConnection! <= clk;
    s.input('dst_reset').srcConnection! <= reset;
    return s.syncOut;
  }

  void _frontEnd(
    HarborEthByteStream stream,
    Logic reset,
    Logic speed,
    bool idelayCtrl,
  ) {
    Logic inPort(String n, [int w = 1]) {
      createPort(n, PortDirection.input, width: w);
      return input(n);
    }

    switch (config.phy) {
      case HarborEthPhy.mii:
        final phy = HarborEthPhyMii(
          stream,
          reset: reset,
          speed: speed,
          miiTxClk: inPort('mii_tx_clk'),
          miiRxClk: inPort('mii_rx_clk'),
          miiRxd: inPort('mii_rxd', 4),
          miiRxDv: inPort('mii_rx_dv'),
          miiRxEr: inPort('mii_rx_er'),
          miiCrs: inPort('mii_crs'),
          miiCol: inPort('mii_col'),
        );
        addOutput('mii_txd', width: 4) <= phy.txd;
        addOutput('mii_tx_en') <= phy.txEn;
        addOutput('mii_tx_er') <= phy.txEr;
      case HarborEthPhy.rmii:
        final phy = HarborEthPhyRmii(
          stream,
          reset: reset,
          speed: speed,
          rmiiRefClk: inPort('rmii_ref_clk'),
          rmiiRxd: inPort('rmii_rxd', 2),
          rmiiCrsDv: inPort('rmii_crs_dv'),
          rmiiRxEr: inPort('rmii_rx_er'),
        );
        addOutput('rmii_txd', width: 2) <= phy.txd;
        addOutput('rmii_tx_en') <= phy.txEn;
      case HarborEthPhy.rgmii:
        final needs200 =
            config.rgmiiRxDelayTaps > 0 &&
            idelayCtrl &&
            target is HarborFpgaTarget &&
            (target as HarborFpgaTarget).vendor != HarborFpgaVendor.ecp5;
        final phy = HarborEthPhyRgmii(
          stream,
          config: config,
          target: target,
          reset: reset,
          speed: speed,
          clk125: inPort('clk125'),
          clk125_90: inPort('clk125_90'),
          rgmiiRxc: inPort('rgmii_rxc'),
          rgmiiRxd: inPort('rgmii_rxd', 4),
          rgmiiRxCtl: inPort('rgmii_rx_ctl'),
          clk200: needs200 ? inPort('clk200') : null,
          idelayCtrl: idelayCtrl,
        );
        _rgmii = phy;
        addOutput('rgmii_txc') <= phy.txc;
        addOutput('rgmii_txd', width: 4) <= phy.txd;
        addOutput('rgmii_tx_ctl') <= phy.txCtl;
    }
  }

  /// One sys cycle pulse for each cycle of [event] high on [srcClk]. Events
  /// must be at least 3 sys cycles apart.
  static Logic _toggleSync(
    String name,
    Logic srcClk,
    Logic srcReset,
    Logic event,
    Logic dstClk,
    Logic dstReset,
  ) {
    final tog = Logic(name: '${name}_tog');
    Sequential(srcClk, reset: srcReset, [
      If(event, then: [tog < ~tog]),
    ]);
    final synced = _sync(name, tog, dstClk, dstReset);
    final prev = Logic(name: '${name}_prev');
    Sequential(dstClk, reset: dstReset, [prev < synced]);
    return (synced ^ prev).named('${name}_pulse');
  }

  /// Timing constraints of the PHY pins. See [HarborEthPhyMii.constraints],
  /// [HarborEthPhyRmii.constraints] and [HarborEthPhyRgmii.constraints].
  List<HarborEthClockConstraint> constraints({
    String Function(String pin)? topPort,
    String? instance,
  }) => switch (config.phy) {
    HarborEthPhy.mii => HarborEthPhyMii.constraints(topPort: topPort),
    HarborEthPhy.rmii => HarborEthPhyRmii.constraints(topPort: topPort),
    HarborEthPhy.rgmii => _rgmii!.constraints(
      topPort: topPort,
      instance: instance,
    ),
  };

  /// Constraints of the clock domain crossings between `clk` and the PHY
  /// clocks.
  ///
  /// Each synchronizer first stage gets a data path delay of at most one
  /// period of the source clock, and each gray code bus also a skew of at
  /// most the smaller of the two periods. [sysPeriodNs] is the period of
  /// `clk`. The PHY periods are 40 ns for MII, 20 ns for RMII and 8 ns for
  /// RGMII. The asynchronous presets of the reset synchronizers get no
  /// timing check. The patterns use the register names that synthesis
  /// keeps, below the MAC instance [instance].
  List<HarborEthClockConstraint> cdcConstraints({
    required double sysPeriodNs,
    String? instance,
  }) {
    final phyNs = switch (config.phy) {
      HarborEthPhy.mii => 40.0,
      HarborEthPhy.rmii => 20.0,
      HarborEthPhy.rgmii => 8.0,
    };
    String at(String path) => instance == null ? '*$path' : '*$instance/*$path';
    const regs = 'eth_regs/';
    const txFifo = 'eth_tx_frame_fifo/';
    const rxFifo = 'eth_rx_frame_fifo/';
    final list = <HarborEthClockConstraint>[];
    void cross(
      List<String> from,
      List<String> to,
      double ns, {
      bool gray = false,
    }) {
      final f = [for (final c in from) at(c)];
      final t = [for (final c in to) at(c)];
      list.add(
        HarborEthClockConstraint(
          kind: HarborEthClockConstraintKind.maxDelay,
          clock: '',
          ports: const [],
          fromCells: f,
          toCells: t,
          maxNs: ns,
        ),
      );
      if (gray) {
        list.add(
          HarborEthClockConstraint(
            kind: HarborEthClockConstraintKind.busSkew,
            clock: '',
            ports: const [],
            fromCells: f,
            toCells: t,
            maxNs: sysPeriodNs < phyNs ? sysPeriodNs : phyNs,
          ),
        );
      }
    }

    // From clk to the PHY clocks.
    cross(['${regs}rx_en_r*'], ['rx_en_sync/sync_stage_0*'], sysPeriodNs);
    cross(
      ['${regs}mac_lo*', '${regs}mac_hi*'],
      ['mac_addr_sync/sync_stage_0*'],
      sysPeriodNs,
    );
    if (config.multicastHash) {
      cross(
        ['${regs}hash_lo*', '${regs}hash_hi*'],
        ['mc_hash_sync/sync_stage_0*'],
        sysPeriodNs,
      );
    }
    if (config.promiscuous) {
      cross(
        ['${regs}ctrl_promisc*'],
        ['promisc_sync/sync_stage_0*'],
        sysPeriodNs,
      );
    }
    final speedSyncs = switch (config.phy) {
      HarborEthPhy.mii => const <String>[],
      HarborEthPhy.rmii => const ['eth_phy_rmii/speed'],
      HarborEthPhy.rgmii => const ['tx_speed', 'rx_speed'],
    };
    if (speedSyncs.isNotEmpty) {
      cross(
        ['${regs}ctrl_speed*'],
        [for (final n in speedSyncs) '${n}_sync/sync_stage_0*'],
        sysPeriodNs,
      );
    }
    cross(
      ['${txFifo}w_frames_gray*'],
      ['${txFifo}frames_s0*'],
      sysPeriodNs,
      gray: true,
    );
    cross(
      ['${rxFifo}r_ptr_gray*'],
      ['${rxFifo}r_gray_s0*'],
      sysPeriodNs,
      gray: true,
    );

    // From the PHY clocks to clk.
    cross(['${txFifo}f_ptr_gray*'], ['${txFifo}f_gray_s0*'], phyNs, gray: true);
    cross(
      ['${rxFifo}w_frames_gray*'],
      ['${rxFifo}frames_s0*'],
      phyNs,
      gray: true,
    );
    cross(['${rxFifo}ovf_tog*'], ['${rxFifo}ovf_s0*'], phyNs);
    for (final f in [txFifo, rxFifo]) {
      cross(['${f}phy_div*'], ['${f}phy_tog_s0*'], phyNs);
    }
    for (final n in [
      'tx_frame',
      'rx_good',
      'rx_fcs',
      'rx_runt',
      'rx_oversize',
    ]) {
      cross(['${n}_tog*'], ['${n}_sync/sync_stage_0*'], phyNs);
    }
    for (final n in ['tx_phy_busy', 'rx_phy_busy']) {
      cross(['$n*'], ['${n}_sync/sync_stage_0*'], phyNs);
    }
    list.add(
      HarborEthClockConstraint(
        kind: HarborEthClockConstraintKind.falsePath,
        clock: '',
        ports: const [],
        toPins: [at('_rst_sync_*/PRE'), at('join_reset_sync_*/PRE')],
      ),
    );
    return list;
  }

  static const _phyPins = {
    HarborEthPhy.mii: [
      'mii_tx_clk',
      'mii_rx_clk',
      'mii_txd',
      'mii_tx_en',
      'mii_tx_er',
      'mii_rxd',
      'mii_rx_dv',
      'mii_rx_er',
    ],
    HarborEthPhy.rmii: [
      'rmii_ref_clk',
      'rmii_txd',
      'rmii_tx_en',
      'rmii_rxd',
      'rmii_crs_dv',
      'rmii_rx_er',
    ],
    HarborEthPhy.rgmii: [
      'rgmii_txc',
      'rgmii_txd',
      'rgmii_tx_ctl',
      'rgmii_rxc',
      'rgmii_rxd',
      'rgmii_rx_ctl',
    ],
  };

  /// The PHY pin constraints when every PHY pin is on the top level, and
  /// the clock domain crossing constraints. They are XDC lines on Xilinx
  /// and LPF lines on ECP5. LPF has only the clock periods.
  ///
  /// The period of `clk` is [clockFrequency], or the target frequency when
  /// it is 0.
  @override
  List<String> pinConstraints(
    HarborFpgaTarget target,
    String? Function(String port) topPort,
    String instance,
  ) {
    final hz = clockFrequency > 0 ? clockFrequency : target.frequency;
    final pinsOn = _phyPins[config.phy]!.every((p) => topPort(p) != null);
    final list = [
      if (pinsOn)
        ...constraints(topPort: (p) => topPort(p)!, instance: instance),
      if (hz > 0) ...cdcConstraints(sysPeriodNs: 1e9 / hz, instance: instance),
    ];
    return switch (target.vendor) {
      HarborFpgaVendor.vivado ||
      HarborFpgaVendor.openXc7 => [for (final c in list) ...c.toXdc()],
      HarborFpgaVendor.ecp5 => [
        for (final c in list)
          if (c.toLpf() case final l?) l,
      ],
      HarborFpgaVendor.ice40 => const [],
    };
  }

  /// Throws when the TX DMA cannot keep 1000 Mbps at the sys clock [hz].
  ///
  /// The TX DMA sends at most one buffer read of [HarborEthernetConfig.burstBeats]
  /// words each 4 sys cycles. 1000 Mbps needs 31.25 M words each second.
  static void checkDmaRate(HarborEthernetConfig config, int hz) {
    if (config.maxSpeed != HarborEthSpeed.mbps1000 || hz <= 0) return;
    final wordsPerSecond = config.burstBeats * hz / 4;
    if (wordsPerSecond < 31.25e6) {
      final minHz = (31.25e6 * 4 / config.burstBeats).ceil();
      throw StateError(
        'HarborEthernetMac: burstBeats ${config.burstBeats} at a sys clock '
        'of ${hz / 1e6} MHz gives ${wordsPerSecond / 1e6} M words/s, '
        'less than the 31.25 M words/s of 1000 Mbps. Use more burstBeats '
        'or a sys clock of at least ${minHz / 1e6} MHz.',
      );
    }
  }

  /// Checks the DMA rate against the sys clock, see [checkDmaRate].
  @override
  Future<void> build() async {
    final t = target;
    final targetHz = switch (t) {
      HarborFpgaTarget() => t.frequency,
      HarborSimTarget() => t.frequency,
      _ => 0,
    };
    checkDmaRate(config, clockFrequency > 0 ? clockFrequency : targetHz);
    await super.build();
  }

  @override
  int get inputClockHz => clockFrequency;

  @override
  void provideInputClockHz(int hz) {
    if (clockFrequency == 0) clockFrequency = hz;
  }

  String get _phyMode => switch (config.phy) {
    HarborEthPhy.mii => 'mii',
    HarborEthPhy.rmii => 'rmii',
    // The names say which delays the PHY adds.
    HarborEthPhy.rgmii =>
      config.txClockShift
          ? (config.rgmiiPhyRxDelay ? 'rgmii-rxid' : 'rgmii')
          : (config.rgmiiPhyRxDelay ? 'rgmii-id' : 'rgmii-txid'),
  };

  Map<String, Object> get _properties => {
    'phy-mode': _phyMode,
    'max-speed': config.maxSpeed.mbps,
    if (clockFrequency > 0) 'clock-frequency': clockFrequency,
  };

  /// Label of the PHY node, unique for each MAC instance.
  String get _phyLabel =>
      '${name.replaceAll(RegExp('[^A-Za-z0-9_]'), '_')}_phy';

  @override
  HarborDeviceTreeNode get dtNode {
    final addr = config.phyAddress;
    return HarborDeviceTreeNode(
      compatible: ['harbor,ethernet-1'],
      reg: BusAddressRange(baseAddress, windowBytes),
      properties: {
        ..._properties,
        if (addr != null) 'phy-handle': HarborDeviceTreeRef(_phyLabel),
      },
      children: [
        HarborDeviceTreeChild(
          name: 'mdio',
          properties: const {'#address-cells': 1, '#size-cells': 0},
          children: [
            if (addr != null)
              HarborDeviceTreeChild(
                name: 'ethernet-phy@${addr.toRadixString(16)}',
                label: _phyLabel,
                properties: {'reg': addr, ...config.phyDtProperties},
              ),
          ],
        ),
      ],
    );
  }

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, windowBytes)],
    properties: {
      'compatible': ['harbor,ethernet-1'],
      ..._properties,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'ETH',
    groupName: 'ETH',
    description: 'Ethernet MAC controller',
    baseAddress: baseAddress,
    size: windowBytes,
  );
}
