import 'package:rohd/rohd.dart';

import '../../soc/target.dart';
import '../bram.dart';
import 'gtp_pcie_phy.dart';
import 'gtp_primitives.dart';
import 'pcie_2_1.dart';
import 'pcie_interrupt.dart';
import 'pcie_pipe.dart';
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
class HarborPcieEndpoint extends Module {
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
  /// sees transfers in flight abort.
  Logic get linkRetrains => output('link_retrains');

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
    this.config = const HarborPcieEndpointConfig(),
    this.pipeStages = 1,
    super.name = 'pcie_endpoint',
  }) : super(definitionName: _definitionName(config, pipeStages)) {
    harborCheckPipeStages(pipeStages);
    _checkTarget(target);
    _checkConfig(config);
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
    final hardLinkUp = Logic(name: 'hard_link_up');
    final phy = HarborArtix7PciePhy(
      refClkP: refClkP,
      refClkN: refClkN,
      perstN: perstN,
      hardLinkUp: hardLinkUp,
      rxP: rxP,
      rxN: rxN,
      pipe: pipe,
      waitForRxResetStatus:
          (target as HarborFpgaTarget).vendor != HarborFpgaVendor.openXc7,
      pipeStages: pipeStages,
    );
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
    hardLinkUp <= link;
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
    addOutput('reset_state', width: 4) <= phy.resetState;
    addOutput('reset_fail_state', width: 4) <= phy.resetFailState;
    addOutput('reset_retries', width: 8) <= phy.resetRetries;
    addOutput('link_retrains', width: 8) <= phy.linkRetrains;
    addOutput('completer_id', width: 16) <=
        [busNumber, deviceNumber, functionNumber].swizzle();
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

  /// Registers on each PIPE signal between the GTP and the hard block.
  final int pipeStages;

  static void _checkTarget(HarborDeviceTarget target) {
    if (target is! HarborFpgaTarget ||
        (target.vendor != HarborFpgaVendor.vivado &&
            target.vendor != HarborFpgaVendor.openXc7) ||
        !target.device.toLowerCase().startsWith('xc7a')) {
      throw UnsupportedError(
        'HarborPcieEndpoint supports Xilinx Artix-7 targets only',
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

  static String _definitionName(
    HarborPcieEndpointConfig config,
    int pipeStages,
  ) => [
    'HarborPcieEndpoint_Xilinx7_X1',
    if (config.packetMemoryEntries != 2048) 'Pm${config.packetMemoryEntries}',
    if (config.bar2Bytes != 0) 'Bar2x${config.bar2Bytes.toRadixString(16)}',
    if (config.msiVectors != 1) 'Msi${config.msiVectors}',
    if (pipeStages != 0) 'Pipe$pipeStages',
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
