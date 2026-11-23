import 'package:rohd/rohd.dart';

import '../../soc/target.dart';
import '../bram.dart';
import 'gtp_pcie_phy.dart';
import 'gtp_primitives.dart';
import 'gtx_pcie_phy.dart';
import 'gtx_primitives.dart';
import 'pcie_2_1.dart';
import 'pcie_interrupt.dart';
import 'pcie_phy.dart';
import 'pcie_pipe.dart';
import 'pipe_clock.dart';
import 'pcie_reset_counters.dart';
import 'pcie_trn_axi.dart';

class HarborPcieEndpointConfig {
  final int vendorId;
  final int deviceId;
  final int revisionId;
  final int subsystemVendorId;
  final int subsystemId;
  final int classCode;
  final int bar0Bytes;
  final int optionRomBytes;
  final int deviceSerialNumber;
  final int packetMemoryEntries;

  /// BAR2 size in bytes, 64-bit and prefetchable. 0 disables BAR2.
  final int bar2Bytes;

  /// Number of MSI vectors the endpoint asks for: 1, 2, 4 or 8.
  final int msiVectors;

  const HarborPcieEndpointConfig({
    this.vendorId = 0x10ee,
    this.deviceId = 0x7203,
    this.revisionId = 0,
    this.subsystemVendorId = 0x10ee,
    this.subsystemId = 0x7203,
    this.classCode = 0x030000,
    this.bar0Bytes = 4096,
    this.optionRomBytes = 0,
    this.deviceSerialNumber = 0,
    this.packetMemoryEntries = 2048,
    this.bar2Bytes = 0,
    this.msiVectors = 1,
  });
}

/// PCIe physical endpoint with 64-bit AXI transmit and receive streams.
///
/// An Artix-7 target uses the GTP PHY at 2.5 GT/s. A Kintex-7 target uses the
/// GTX PHY, and it runs at 5 GT/s with [gen2].
///
/// [freeClk] is a clock that runs while PERST# is low, such as the board
/// oscillator. The reset counters use it to see PERST# on the pin. No
/// endpoint clock runs while PERST# is low: PERST# resets the MMCM, and the
/// host can stop the reference clock.
class HarborPcieEndpoint extends Module with HarborClockRateProvider {
  Logic get txP => output('tx_p');
  Logic get txN => output('tx_n');
  Logic get userClk => output('user_clk');
  Logic get userReset => output('user_reset');
  Logic get linkUp => output('link_up');
  Logic get completerId => output('completer_id');
  Logic get rxData => output('rx_data');
  Logic get rxKeep => output('rx_keep');
  Logic get rxLast => output('rx_last');
  Logic get rxValid => output('rx_valid');
  Logic get rxUser => output('rx_user');
  Logic get txReady => output('tx_ready');
  Logic get maxPayload => output('max_payload');
  Logic get maxReadRequest => output('max_read_request');
  Logic get rcb128 => output('rcb_128');
  Logic get busMasterEnable => output('bus_master_enable');
  Logic get msiEnable => output('msi_enable');

  /// Granted MSI vector count as log2, from the MSI Multiple Message Enable.
  Logic get msiVectorsGranted => output('msi_vectors_granted');

  /// MMCM lock, not synchronised.
  Logic get mmcmLock => output('mmcm_lock');

  /// Current [HarborGtpResetState] code.
  Logic get resetState => output('reset_state');

  /// [HarborGtpResetState] code of the last failure.
  Logic get resetFailState => output('reset_fail_state');

  /// Number of failures since reset, it stops at 255.
  Logic get resetRetries => output('reset_retries');

  /// Number of PHY restarts because the link did not come up, or went down
  /// and did not come back, since PERST# or power-on. It stops at 255. A
  /// restart resets all user logic on [userReset], so a bus master or driver
  /// sees transfers in flight abort. Null when the watchdog is off.
  Logic? get linkRetrains => _linkWait == 0 ? null : output('link_retrains');

  /// The [HarborPcieResetCounters] status, for the DMA reset status input.
  Logic get resetStatus => output('reset_status');

  /// Frequency of [userClk] in Hz, from the PHY. It is [userClkFreq] when set.
  /// Else it is 62.5 MHz for a GTP x1 or a GTX at 2.5 GT/s, and 125 MHz for a
  /// GTX at 5 GT/s. It is also the
  /// value of the hard block USER_CLK_FREQ parameter.
  int get userClkHz => _phy.userClkHz;

  /// Bits 0 to 4: CPLLLOCK, RXCDRLOCK, TXRESETDONE, RXRESETDONE, MMCM lock.
  /// Null with a GTP PHY.
  Logic? get phyLocks => gtx ? output('phy_locks') : null;

  /// A bit is high from the first timeout of a GTX reset wait until PERST#,
  /// see [HarborGtxPciePhy.timeoutFlags]. Null with a GTP PHY.
  Logic? get phyTimeoutFlags => gtx ? output('phy_timeout_flags') : null;

  /// See [HarborGtxPciePhy.rxDebug]. Null with a GTP PHY.
  Logic? get phyRxDebug => gtx ? output('phy_rx_debug') : null;

  /// Bits 0 to 3: TXDLYSRESETDONE, TXPHINITDONE, TXPHALIGNDONE and PHYSTATUS
  /// of the GT. Null with a GTP PHY.
  Logic? get phyTxSync => gtx ? output('phy_tx_sync') : null;

  /// Bits 0 to 2: the three TX sync done signals were high since PERST#.
  Logic? get phyTxSyncSeen => gtx ? output('phy_tx_sync_seen') : null;

  /// Number of TXPHALIGNDONE rising edges since PERST#, it stops at 15.
  Logic? get phyPhAlignCount => gtx ? output('phy_phalign_count') : null;

  /// PLLTSSMSTATE of the hard block. Null with a GTP PHY.
  Logic? get ltssmStateOut => gtx ? output('ltssm_state_out') : null;

  /// 0 for a 125 MHz PIPE clock and 1 for 250 MHz. Null with a GTP PHY.
  Logic? get pclkSel => gtx ? output('pclk_sel') : null;

  HarborPcieEndpoint({
    required HarborDeviceTarget target,
    required Logic refClkP,
    required Logic refClkN,
    required Logic perstN,
    required Logic rxP,
    required Logic rxN,
    required Logic rxReady,
    required Logic txData,
    required Logic txKeep,
    required Logic txLast,
    required Logic txValid,
    Logic? txUser,
    Logic? irqPending,
    Logic? freeClk,
    this.config = const HarborPcieEndpointConfig(),
    this.pipeStages = 1,
    this.timeouts = const HarborGtpPcieTimeouts(),
    this.gtxTimeouts = const HarborGtxPcieTimeouts(),
    bool? gen2,
    this.userClkFreq,
    this.waitRxCdrLock = false,
    this.debugSkipTxPhaseAlign = false,
    this.debugBuild = false,
    this.hardBlockOverrides = const {},
    super.name = 'pcie_endpoint',
  }) : gtx = _isKintex7(target),
       gen2 = gen2 ?? _isKintex7(target),
       super(
         definitionName: _definitionName(
           config,
           pipeStages,
           _isKintex7(target) ? gtxTimeouts.linkWait : timeouts.linkWait,
           freeClk != null,
           gtx: _isKintex7(target),
           gen2: gen2 ?? _isKintex7(target),
           userClkRequest: userClkFreq,
           waitRxCdrLock: waitRxCdrLock,
           debugSkip: debugSkipTxPhaseAlign,
           overrides: hardBlockOverrides,
           gtxTimeouts: gtxTimeouts,
         ),
       ) {
    harborCheckPipeStages(pipeStages);
    if (hardBlockOverrides.isNotEmpty && !debugBuild) {
      throw ArgumentError('hardBlockOverrides needs debugBuild');
    }
    for (final key in hardBlockOverrides.keys) {
      if (_derivedParameters.contains(key)) {
        throw ArgumentError.value(
          key,
          'hardBlockOverrides',
          'the endpoint derives this parameter',
        );
      }
    }
    _checkTarget(target);
    _checkConfig(config);
    if (this.gen2 && !gtx) {
      throw UnsupportedError('the GTP PHY runs at 2.5 GT/s only');
    }
    if (userClkFreq != null) {
      checkUserClk(gen2: this.gen2, hz: userClkFreq!);
      if (!gtx && userClkFreq != 62500000) {
        throw UnsupportedError('the GTP PHY has a 62.5 MHz user clock only');
      }
    }
    refClkP = addInput('refclk_p', refClkP);
    refClkN = addInput('refclk_n', refClkN);
    perstN = addInput('perst_n', perstN);
    rxP = addInput('rx_p', rxP);
    rxN = addInput('rx_n', rxN);
    rxReady = addInput('rx_ready', rxReady);
    txData = addInput('tx_data', txData, width: 64);
    txKeep = addInput('tx_keep', txKeep, width: 8);
    txLast = addInput('tx_last', txLast);
    txValid = addInput('tx_valid', txValid);
    final txUserPort = addInput(
      'tx_user',
      txUser ?? Const(0, width: 4),
      width: 4,
    );
    irqPending = addInput(
      'irq_pending',
      irqPending ?? Const(0, width: 8),
      width: 8,
    );

    final pipe = HarborPciePipeLane();
    final watch = _linkWait != 0;
    final hardLinkUp = watch ? Logic(name: 'hard_link_up') : null;
    final phyLinkUpN = watch ? Logic(name: 'phy_link_up_n') : null;
    final ltssmState = watch ? Logic(name: 'ltssm_state', width: 6) : null;
    final HarborPciePhy phy = gtx
        ? HarborKintex7PciePhy(
            refClkP: refClkP,
            refClkN: refClkN,
            perstN: perstN,
            hardLinkUp: hardLinkUp,
            phyLinkUpN: phyLinkUpN,
            ltssmState: ltssmState,
            rxP: rxP,
            rxN: rxN,
            pipe: pipe,
            gen2: this.gen2,
            userClkRequest: userClkFreq,
            waitRxCdrLock: waitRxCdrLock,
            debugSkipTxPhaseAlign: debugSkipTxPhaseAlign,
            debugBuild: debugBuild,
            pipeStages: pipeStages,
            timeouts: gtxTimeouts,
          )
        : HarborArtix7PciePhy(
            refClkP: refClkP,
            refClkN: refClkN,
            perstN: perstN,
            hardLinkUp: hardLinkUp,
            phyLinkUpN: phyLinkUpN,
            ltssmState: ltssmState,
            rxP: rxP,
            rxN: rxN,
            pipe: pipe,
            waitForRxResetStatus:
                (target as HarborFpgaTarget).vendor != HarborFpgaVendor.openXc7,
            pipeStages: pipeStages,
            timeouts: timeouts,
          );
    _phy = phy;
    final hardInputs = harborPcie21TiedInputs();
    hardInputs['PIPECLK'] = phy.pclk;
    hardInputs['USERCLK'] = phy.userClk1;
    hardInputs['USERCLK2'] = phy.userClk2;
    hardInputs['SYSRSTN'] = phy.ready;
    hardInputs['CFGDEVID'] = Const(config.deviceId, width: 16);
    hardInputs['CFGVENDID'] = Const(config.vendorId, width: 16);
    hardInputs['CFGREVID'] = Const(config.revisionId, width: 8);
    hardInputs['CFGSUBSYSID'] = Const(config.subsystemId, width: 16);
    hardInputs['CFGSUBSYSVENDID'] = Const(config.subsystemVendorId, width: 16);
    hardInputs['CFGDSN'] = Const(config.deviceSerialNumber, width: 64);
    hardInputs['PIPERX0DATA'] = pipe.rxData;
    hardInputs['PIPERX0CHARISK'] = pipe.rxDataK;
    hardInputs['PIPERX0VALID'] = pipe.rxValid;
    hardInputs['PIPERX0PHYSTATUS'] = pipe.phyStatus;
    hardInputs['PIPERX0ELECIDLE'] = pipe.rxElecIdle;
    hardInputs['PIPERX0STATUS'] = pipe.rxStatus;
    hardInputs['PIPERX0CHANISALIGNED'] = pipe.rxChanIsAligned;
    for (var lane = 1; lane < 8; lane++) {
      hardInputs['PIPERX${lane}ELECIDLE'] = Const(1);
    }
    final trnRxReady = Logic(name: 'trn_rx_ready');
    final trnTxData = Logic(name: 'trn_tx_data', width: 128);
    final trnTxRem = Logic(name: 'trn_tx_rem', width: 2);
    final trnTxSof = Logic(name: 'trn_tx_sof');
    final trnTxEof = Logic(name: 'trn_tx_eof');
    final trnTxSrcReady = Logic(name: 'trn_tx_src_ready');
    final trnTxSrcDsc = Logic(name: 'trn_tx_src_dsc');
    final trnTxErrFwd = Logic(name: 'trn_tx_err_fwd');
    final trnTxStr = Logic(name: 'trn_tx_str');
    final trnTxEcrcGen = Logic(name: 'trn_tx_ecrc_gen');
    final trnTxCfgGrant = Logic(name: 'trn_tx_cfg_grant');
    final mimTxReadData = Logic(name: 'mim_tx_read_data', width: 69);
    final mimRxReadData = Logic(name: 'mim_rx_read_data', width: 68);
    hardInputs['TRNRDSTRDY'] = trnRxReady;
    hardInputs['TRNTD'] = trnTxData;
    hardInputs['TRNTREM'] = trnTxRem;
    hardInputs['TRNTSOF'] = trnTxSof;
    hardInputs['TRNTEOF'] = trnTxEof;
    hardInputs['TRNTSRCRDY'] = trnTxSrcReady;
    hardInputs['TRNTSRCDSC'] = trnTxSrcDsc;
    hardInputs['TRNTERRFWD'] = trnTxErrFwd;
    hardInputs['TRNTSTR'] = trnTxStr;
    hardInputs['TRNTECRCGEN'] = trnTxEcrcGen;
    hardInputs['TRNTCFGGNT'] = trnTxCfgGrant;
    hardInputs['MIMTXRDATA'] = mimTxReadData;
    hardInputs['MIMRXRDATA'] = mimRxReadData;
    final interruptN = Logic(name: 'cfg_interrupt_n');
    final interruptDi = Logic(name: 'cfg_interrupt_di', width: 8);
    final interruptAssertN = Logic(name: 'cfg_interrupt_assert_n');
    hardInputs['CFGINTERRUPTN'] = interruptN;
    hardInputs['CFGINTERRUPTDI'] = interruptDi;
    hardInputs['CFGINTERRUPTASSERTN'] = interruptAssertN;

    final hardBlock = HarborXilinxPcie21(
      inputs: hardInputs,
      parameterOverrides: {
        'BAR0': _hex32(_barMask(config.bar0Bytes)),
        'CLASS_CODE':
            "24'h${config.classCode.toRadixString(16).padLeft(6, '0')}",
        'EXPANSION_ROM': _hex32(
          config.optionRomBytes == 0
              ? 0
              : (_barMask(config.optionRomBytes) | 1),
        ),
        if (config.bar2Bytes != 0) ...{
          'BAR2': _hex32(_barMask(config.bar2Bytes) | 0xc),
          'BAR3': _hex32(0xffffffff),
        },
        'MSI_CAP_MULTIMSGCAP': '${config.msiVectors.bitLength - 1}',
        ..._packetMemoryParameters(config.packetMemoryEntries),
        ..._gtxParameters,
        ...hardBlockOverrides,
      },
    );

    pipe.txData <= hardBlock.output('PIPETX0DATA');
    pipe.txDataK <= hardBlock.output('PIPETX0CHARISK');
    pipe.txDetectRx <= hardBlock.output('PIPETXRCVRDET');
    pipe.txElecIdle <= hardBlock.output('PIPETX0ELECIDLE');
    pipe.txCompliance <= hardBlock.output('PIPETX0COMPLIANCE');
    pipe.rxPolarity <= hardBlock.output('PIPERX0POLARITY');
    pipe.powerDown <= hardBlock.output('PIPETX0POWERDOWN');
    pipe.pipeRate <= hardBlock.output('PIPETXRATE');
    pipe.txMargin <= hardBlock.output('PIPETXMARGIN');
    pipe.txDeemph <= hardBlock.output('PIPETXDEEMPH');
    pipe.txSwing <= Const(0);

    final reset = ~hardBlock.output('USERRSTN');
    final link = hardBlock.output('TRNLNKUP');
    if (watch) {
      hardLinkUp! <= link;
      phyLinkUpN! <= hardBlock.output('PLPHYLNKUPN');
      ltssmState! <= hardBlock.output('PLLTSSMSTATE');
    }
    final stream = HarborPcieTrnAxi(
      clk: phy.userClk2,
      reset: reset,
      linkUp: link,
      rxReady: rxReady,
      txData: txData,
      txKeep: txKeep,
      txLast: txLast,
      txValid: txValid,
      txUser: txUserPort,
      trnRxData: hardBlock.output('TRNRD'),
      trnRxRem: hardBlock.output('TRNRREM'),
      trnRxSof: hardBlock.output('TRNRSOF'),
      trnRxEof: hardBlock.output('TRNREOF'),
      trnRxSrcReady: hardBlock.output('TRNRSRCRDY'),
      trnRxSrcDsc: hardBlock.output('TRNRSRCDSC'),
      trnRxErrFwd: hardBlock.output('TRNRERRFWD'),
      trnRxBarHit: hardBlock.output('TRNRBARHIT'),
      trnRxEcrcErr: hardBlock.output('TRNRECRCERR'),
      trnTxDstReady: hardBlock.output('TRNTDSTRDY'),
      trnTxCfgReq: hardBlock.output('TRNTCFGREQ'),
    );
    trnRxReady <= stream.trnRxReady;
    trnTxData <= stream.trnTxData;
    trnTxRem <= stream.trnTxRem;
    trnTxSof <= stream.trnTxSof;
    trnTxEof <= stream.trnTxEof;
    trnTxSrcReady <= stream.trnTxSrcReady;
    trnTxSrcDsc <= stream.trnTxSrcDsc;
    trnTxErrFwd <= stream.trnTxErrFwd;
    trnTxStr <= stream.trnTxStr;
    trnTxEcrcGen <= stream.trnTxEcrcGen;
    trnTxCfgGrant <= stream.trnTxCfgGrant;

    final interrupt = HarborPcieInterrupt(
      clk: phy.userClk2,
      reset: reset | ~link,
      irqPending: irqPending,
      txBusy: txValid | ~stream.txIdle,
      msiEnable: hardBlock.output('CFGINTERRUPTMSIENABLE'),
      mmEnable: hardBlock.output('CFGINTERRUPTMMENABLE'),
      busMasterEnable: hardBlock.output('CFGCOMMANDBUSMASTERENABLE'),
      interruptDisable: hardBlock.output('CFGCOMMANDINTERRUPTDISABLE'),
      interruptRdyN: hardBlock.output('CFGINTERRUPTRDYN'),
      // Send at most one MSI each millisecond, so that a held cause cannot
      // flood the host.
      minMsiCycles: (phy.userClkHz + 999) ~/ 1000,
    );
    interruptN <= interrupt.interruptN;
    interruptDi <= interrupt.interruptDi;
    interruptAssertN <= interrupt.interruptAssertN;

    final txRam = _HarborPcieBlockRam(
      clk: phy.userClk1,
      writeEnable: hardBlock.output('MIMTXWEN'),
      writeAddress: hardBlock.output('MIMTXWADDR'),
      writeData: hardBlock.output('MIMTXWDATA'),
      readEnable: hardBlock.output('MIMTXREN'),
      readAddress: hardBlock.output('MIMTXRADDR'),
      width: 69,
      depth: config.packetMemoryEntries,
      name: 'tx_packet_ram',
    );
    final rxRam = _HarborPcieBlockRam(
      clk: phy.userClk1,
      writeEnable: hardBlock.output('MIMRXWEN'),
      writeAddress: hardBlock.output('MIMRXWADDR'),
      writeData: hardBlock.output('MIMRXWDATA'),
      readEnable: hardBlock.output('MIMRXREN'),
      readAddress: hardBlock.output('MIMRXRADDR'),
      width: 68,
      depth: config.packetMemoryEntries,
      name: 'rx_packet_ram',
    );
    mimTxReadData <= txRam.readData;
    mimRxReadData <= rxRam.readData;

    final counters = HarborPcieResetCounters(
      clk: phy.userClk2,
      mmcmLock: phy.mmcmLock,
      freeClk: freeClk == null ? null : addInput('free_clk', freeClk),
      perstN: perstN,
      userReset: reset,
      hotReset: hardBlock.output('PLRECEIVEDHOTRST'),
      linkUp: link,
      phyResetState: phy.resetState,
      phyFailState: phy.resetFailState,
      phyRetries: phy.resetRetries,
      linkRetrains: watch ? phy.linkRetrains : null,
    );

    final busNumber = Logic(name: 'bus_number', width: 8);
    final deviceNumber = Logic(name: 'device_number', width: 5);
    final functionNumber = Logic(name: 'function_number', width: 3);
    Sequential(phy.userClk2, [
      If(
        ~link,
        then: [
          busNumber < Const(0, width: 8),
          deviceNumber < Const(0, width: 5),
          functionNumber < Const(0, width: 3),
        ],
        orElse: [
          If(
            ~hardBlock.output('CFGMSGRECEIVED'),
            then: [
              busNumber < hardBlock.output('CFGMSGDATA').slice(15, 8),
              deviceNumber < hardBlock.output('CFGMSGDATA').slice(7, 3),
              functionNumber < hardBlock.output('CFGMSGDATA').slice(2, 0),
            ],
          ),
        ],
      ),
    ]);

    addOutput('tx_p') <= phy.txP;
    addOutput('tx_n') <= phy.txN;
    addOutput('user_clk') <= phy.userClk2;
    addOutput('user_reset') <= reset;
    addOutput('link_up') <= link;
    addOutput('mmcm_lock') <= phy.mmcmLock;
    if (phy is HarborKintex7PciePhy) {
      addOutput('phy_locks', width: 5) <=
          [
            phy.mmcmLock,
            phy.rxResetDone,
            phy.txResetDone,
            phy.rxCdrLock,
            phy.cpllLock,
          ].concat();
      addOutput('phy_timeout_flags', width: HarborGtxPciePhy.timeoutFlagBits) <=
          phy.timeoutFlags;
      addOutput('pclk_sel') <= phy.pclkSel;
      addOutput('phy_rx_debug', width: HarborGtxPciePhy.rxDebugBits) <=
          phy.rxDebug;
      addOutput('phy_tx_sync', width: 4) <= phy.txSync;
      addOutput('phy_tx_sync_seen', width: 3) <= phy.txSyncSeen;
      addOutput('phy_phalign_count', width: 4) <= phy.phAlignCount;
    }
    if (gtx) {
      addOutput('ltssm_state_out', width: 6) <=
          hardBlock.output('PLLTSSMSTATE');
    }
    addOutput('reset_state', width: 4) <= phy.resetState;
    addOutput('reset_fail_state', width: 4) <= phy.resetFailState;
    addOutput('reset_retries', width: 8) <= phy.resetRetries;
    if (watch) addOutput('link_retrains', width: 8) <= phy.linkRetrains!;
    addOutput('reset_status', width: 64) <= counters.status;
    addOutput('completer_id', width: 16) <=
        [busNumber, deviceNumber, functionNumber].concat();
    addOutput('rx_data', width: 64) <= stream.rxData;
    addOutput('rx_keep', width: 8) <= stream.rxKeep;
    addOutput('rx_last') <= stream.rxLast;
    addOutput('rx_valid') <= stream.rxValid;
    addOutput('rx_user', width: 22) <= stream.rxUser;
    addOutput('tx_ready') <= stream.txReady;
    addOutput('max_payload', width: 3) <=
        hardBlock.output('CFGDEVCONTROLMAXPAYLOAD');
    addOutput('max_read_request', width: 3) <=
        hardBlock.output('CFGDEVCONTROLMAXREADREQ');
    addOutput('rcb_128') <= hardBlock.output('CFGLINKCONTROLRCB');
    addOutput('bus_master_enable') <=
        hardBlock.output('CFGCOMMANDBUSMASTERENABLE');
    addOutput('msi_enable') <= hardBlock.output('CFGINTERRUPTMSIENABLE');
    addOutput('msi_vectors_granted', width: 3) <=
        hardBlock.output('CFGINTERRUPTMMENABLE');
  }

  final HarborPcieEndpointConfig config;

  /// Registers on each PIPE signal between the GT and the hard block.
  final int pipeStages;

  /// Bounds of the GTP reset waits and of the link training watchdog, for an
  /// Artix-7 target. [HarborGtpPcieTimeouts.linkWait] 0 removes the watchdog.
  final HarborGtpPcieTimeouts timeouts;

  /// The same as [timeouts] for a Kintex-7 target.
  final HarborGtxPcieTimeouts gtxTimeouts;

  /// True when the PHY is a GTX, that is a Kintex-7 target.
  final bool gtx;

  /// The link runs at 5 GT/s when the partner supports it. The default is
  /// true on a Kintex-7 target and false on an Artix-7 target.
  final bool gen2;

  /// Wait for RXCDRLOCK in the GTX reset sequence.
  final bool waitRxCdrLock;

  /// Debug option, see [HarborGtxPciePhy.debugSkipTxPhaseAlign].
  final bool debugSkipTxPhaseAlign;

  /// Allows the debug options.
  final bool debugBuild;

  /// Parameters of the PCIe hard block, applied last.
  final Map<String, String> hardBlockOverrides;

  int get _linkWait => gtx ? gtxTimeouts.linkWait : timeouts.linkWait;

  late final HarborPciePhy _phy;

  /// The pipe clocks and their rates in MHz. [instance] is the path to this
  /// endpoint from the top module, `pcie_endpoint` for the default name in the
  /// top module.
  ///
  /// `pclk` is 250 MHz with [gen2] and 125 MHz without. `userclk1` is the
  /// user clock of the PHY. The net `txoutclk_buf` is TXOUTCLK after its
  /// buffer, 100 MHz from the reference clock. A GTX PHY also has the
  /// 62.5 MHz `oob_clk`.
  @override
  Map<String, double> clockRates(String instance) {
    final pipe =
        '$instance.${_phy.name}.${gtx ? 'gtx' : 'gtp'}_pcie_phy.pipe_clock';
    return {
      '$pipe.txoutclk_buf': 100,
      '$pipe.pclk': gen2 ? 250 : 125,
      '$pipe.userclk1': _phy.userClkHz / 1e6,
      if (gtx) '$pipe.oob_clk': 62.5,
    };
  }

  /// The user clock in Hz that the caller asked for, or null for the default:
  /// 62.5 MHz at 2.5 GT/s and 125 MHz at 5 GT/s. The interface is 64 bits
  /// wide at x1. It sets USER_CLK_FREQ and the user clock divide of the pipe
  /// clock MMCM. A slower clock gives the user logic more time per cycle.
  /// 62.5 MHz at 5 GT/s is the recommended clock of PG054 for x1.
  final int? userClkFreq;

  /// The user clock frequencies in Hz that the x1 64-bit interface allows
  /// for a link rate, PG054 Table 2-8 and Table 4-3. It is the set that the
  /// PHY can make, [HarborPipeClock.x1UserClkHz], at 2.5 and at 5.0 GT/s.
  static const Map<bool, Set<int>> legalUserClkHz = {
    false: HarborPipeClock.x1UserClkHz,
    true: HarborPipeClock.x1UserClkHz,
  };

  /// Throws an [ArgumentError] unless [hz] is a legal user clock for a x1
  /// link at 5 GT/s with [gen2] and at 2.5 GT/s without it.
  static void checkUserClk({required bool gen2, required int hz}) {
    if (!legalUserClkHz[gen2]!.contains(hz)) {
      throw ArgumentError.value(
        hz,
        'userClkFreq',
        'is not a user clock of a x1 64-bit link at '
            '${gen2 ? '5.0' : '2.5'} GT/s: ${legalUserClkHz[gen2]!.join(', ')}',
      );
    }
  }

  /// Hard block parameters of the endpoint, for a GTX PHY. USER_CLK_FREQ
  /// comes from the divide of the user clock MMCM output: 1 for 62.5 MHz, 2
  /// for 125 MHz and 3 for 250 MHz. PG054 recommends 62.5 MHz for a x1 link at
  /// 5 GT/s, and the default is 125 MHz. At 5 GT/s the link speed is 2. LINK_STATUS_SLOT_CLOCK_CONFIG
  /// says that the link uses the reference clock of the slot, as the PHY does.
  Map<String, String> get _gtxParameters => gtx
      ? {
          'USER_CLK_FREQ':
              '${HarborPipeClock.userClkFreqCode(HarborPipeClock.vcoHz ~/ _phy.userClkHz)}',
          'LINK_STATUS_SLOT_CLOCK_CONFIG': '"TRUE"',
          if (gen2) ...{
            'LINK_CAP_MAX_LINK_SPEED': "4'h2",
            'LINK_CTRL2_TARGET_LINK_SPEED': "4'h2",
          },
        }
      : const {};

  /// Parameters that the endpoint sets from its own options.
  static const _derivedParameters = {
    'USER_CLK_FREQ',
    'LINK_STATUS_SLOT_CLOCK_CONFIG',
    'LINK_CAP_MAX_LINK_SPEED',
    'LINK_CTRL2_TARGET_LINK_SPEED',
  };

  /// A stable 32-bit FNV-1a hash of [overrides], in hex.
  static String _overridesHash(Map<String, String> overrides) {
    var h = 0x811c9dc5;
    for (final key in overrides.keys.toList()..sort()) {
      for (final c in '$key=${overrides[key]};'.codeUnits) {
        h = ((h ^ c) * 0x01000193) & 0xffffffff;
      }
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  static bool _isKintex7(HarborDeviceTarget target) =>
      target is HarborFpgaTarget &&
      target.device.toLowerCase().startsWith('xc7k');

  static void _checkTarget(HarborDeviceTarget target) {
    if (target is! HarborFpgaTarget ||
        (target.vendor != HarborFpgaVendor.vivado &&
            target.vendor != HarborFpgaVendor.openXc7) ||
        !(target.device.toLowerCase().startsWith('xc7a') ||
            target.device.toLowerCase().startsWith('xc7k'))) {
      throw UnsupportedError(
        'HarborPcieEndpoint supports Xilinx Artix-7 and Kintex-7 targets only',
      );
    }
  }

  static void _checkConfig(HarborPcieEndpointConfig config) {
    for (final (name, value, bits) in [
      ('vendorId', config.vendorId, 16),
      ('deviceId', config.deviceId, 16),
      ('revisionId', config.revisionId, 8),
      ('subsystemVendorId', config.subsystemVendorId, 16),
      ('subsystemId', config.subsystemId, 16),
      ('classCode', config.classCode, 24),
    ]) {
      if (value < 0 || value >= 1 << bits) {
        throw RangeError.range(value, 0, (1 << bits) - 1, name);
      }
    }
    _checkRegion('bar0Bytes', config.bar0Bytes, allowZero: false);
    _checkRegion('optionRomBytes', config.optionRomBytes, allowZero: true);
    _checkRegion('bar2Bytes', config.bar2Bytes, allowZero: true);
    if (!const {1, 2, 4, 8}.contains(config.msiVectors)) {
      throw ArgumentError.value(
        config.msiVectors,
        'msiVectors',
        'must be 1, 2, 4 or 8',
      );
    }
    if (config.packetMemoryEntries != 1024 &&
        config.packetMemoryEntries != 2048) {
      throw ArgumentError.value(
        config.packetMemoryEntries,
        'packetMemoryEntries',
        'must be 1024 or 2048',
      );
    }
  }

  /// The user clock in Hz when [userClkFreq] is null.
  static int _defaultUserClkHz(bool gtx, bool gen2) =>
      HarborPipeClock.userClkHz(
        gtx ? HarborGtxPciePhy.userClkDivide(gen2: gen2) : 16,
      );

  static String _definitionName(
    HarborPcieEndpointConfig config,
    int pipeStages,
    int linkWait,
    bool freeClk, {
    required bool gtx,
    required bool gen2,
    int? userClkRequest,
    required bool waitRxCdrLock,
    required bool debugSkip,
    required Map<String, String> overrides,
    required HarborGtxPcieTimeouts gtxTimeouts,
  }) => [
    'HarborPcieEndpoint_Xilinx7_X1',
    if (gtx) 'Gtx',
    if (gen2) 'G2',
    if (userClkRequest != null &&
        userClkRequest != _defaultUserClkHz(gtx, gen2))
      'Uc${userClkRequest ~/ 1000}',
    if (gtx && waitRxCdrLock) 'CdrWait',
    if (gtx && gtxTimeouts.definitionTag.isNotEmpty) gtxTimeouts.definitionTag,
    if (debugSkip) 'DebugNoPhAlign',
    if (overrides.isNotEmpty) 'Ov${_overridesHash(overrides)}',
    if (config.packetMemoryEntries != 2048) 'Pm${config.packetMemoryEntries}',
    if (config.bar2Bytes != 0) 'Bar2x${config.bar2Bytes.toRadixString(16)}',
    if (config.msiVectors != 1) 'Msi${config.msiVectors}',
    if (pipeStages != 0) 'Pipe$pipeStages',
    if (linkWait != 0) 'LinkWd',
    if (freeClk) 'Free',
  ].join('_');

  static Map<String, String> _packetMemoryParameters(int entries) =>
      entries == 1024
      ? const {
          'DEV_CAP_MAX_PAYLOAD_SUPPORTED': '1',
          'VC0_RX_RAM_LIMIT': "13'h3FF",
          'VC0_TOTAL_CREDITS_CD': '370',
          'VC0_TOTAL_CREDITS_CH': '72',
          'VC0_TOTAL_CREDITS_NPH': '4',
          'VC0_TOTAL_CREDITS_NPD': '8',
          'VC0_TOTAL_CREDITS_PD': '32',
          'VC0_TOTAL_CREDITS_PH': '4',
          'VC0_TX_LASTPACKET': '28',
        }
      : const {};

  static void _checkRegion(String name, int bytes, {required bool allowZero}) {
    if ((allowZero && bytes == 0) ||
        (bytes >= 4096 && bytes <= 0x80000000 && bytes & (bytes - 1) == 0)) {
      return;
    }
    throw ArgumentError.value(
      bytes,
      name,
      'must be a power of 2 at least 4096',
    );
  }

  static int _barMask(int bytes) => (~(bytes - 1)) & 0xfffffff0;
  static String _hex32(int value) =>
      "32'h${value.toRadixString(16).padLeft(8, '0')}";
}

class _HarborPcieBlockRam extends Module {
  Logic get readData => output('read_data');

  _HarborPcieBlockRam({
    required Logic clk,
    required Logic writeEnable,
    required Logic writeAddress,
    required Logic writeData,
    required Logic readEnable,
    required Logic readAddress,
    required int width,
    required int depth,
    super.name,
  }) : super(definitionName: 'HarborPcieBlockRam_${width}x$depth') {
    clk = addInput('clk', clk);
    writeEnable = addInput('write_enable', writeEnable);
    writeAddress = addInput('write_address', writeAddress, width: 13);
    writeData = addInput('write_data', writeData, width: width);
    readEnable = addInput('read_enable', readEnable);
    readAddress = addInput('read_address', readAddress, width: 13);
    final addressWidth = (depth - 1).bitLength;
    final ram = HarborBram(
      clk,
      width: width,
      depth: depth,
      wrEn: writeEnable,
      wrAddr: writeAddress.slice(addressWidth - 1, 0),
      wrData: writeData,
      rdAddr: readAddress.slice(addressWidth - 1, 0),
    );
    final enableDelay = Logic(name: 'read_enable_delay');
    final data = Logic(name: 'read_data_reg', width: width);
    Sequential(clk, [
      enableDelay < readEnable,
      If(enableDelay, then: [data < ram.rdData]),
    ]);
    addOutput('read_data', width: width) <= data;
  }
}
