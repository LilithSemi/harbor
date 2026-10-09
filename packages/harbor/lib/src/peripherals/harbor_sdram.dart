/// SoC wrapper for the sdr sdram controller: wishbone bus -> optional cdc
/// -> [SdramWishbonePort] -> [SdramArbiter] -> [SdramEngine] -> a phy.
library;

import 'package:meta/meta.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_error_source.dart';
import '../bus/bus_slave_port.dart';
import '../clock/cdc.dart';
import '../clock/wishbone_cdc_fifo.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../soc/target.dart';
import 'sdram_config.dart';
import 'sdram_cycles.dart';
import 'sdram_engine.dart';
import 'sdram_phy_ecp5.dart';
import 'sdram_port.dart';
import 'sdram_wishbone_port.dart';
import 'sim_dram.dart';

/// SoC wrapper for the sdr sdram controller.
///
///   bus (sys clk, wishbone B4 32b) -> HarborWishboneCdcFifoBridge 'sdram_cdc'
///     (skipped when [busClockSync]) -> SdramWishbonePort -> SdramArbiter
///     (one port in v1) -> SdramEngine -> SdramPhyEcp5 -> sdram_* pads
///
/// Everything from the wishbone front end down runs on `mem_clk`. The target
/// must be a Lattice ecp5 or a [HarborSimTarget], which replaces the whole
/// stack with [HarborSimDram] on the bus directly.
///
/// `mem_reset` re-initializes the device, so its contents are not
/// guaranteed after one. A bus `reset` alone keeps the sdram contents.
/// Either reset sets the sticky `bus_error`.
///
/// With [postedWrites] false (the default), a write is acked only after
/// the memory side has taken it, so no acked write is lost on a bus
/// reset. With it true, writes are posted (about 3x faster back to
/// back), but a posted write still in the clock-crossing fifo is lost on
/// a bus reset.
class HarborSdram extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborSystemMemoryProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider,
        HarborBusErrorSource {
  /// The sdram device and controller configuration.
  final HarborSdramConfig config;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Controller clock frequency in Hz, 1:1 with sdram_clk.
  final int clockHz;

  /// Build target. Must be an ECP5 [HarborFpgaTarget] or a [HarborSimTarget].
  final HarborDeviceTarget? target;

  /// Ecp5 phy knobs.
  final HarborSdramPhyConfig phy;

  /// Refreshes the scheduler may postpone before it must catch up.
  final int maxPostponedRefresh;

  /// Refreshes the scheduler may pull in ahead of schedule.
  final int maxPulledInRefresh;

  /// When true, the bus clock is the same as `mem_clk`, so no `mem_clk`
  /// port exists and the cdc bridge is skipped. `mem_reset` stays.
  final bool busClockSync;

  /// When true, a write is acked as soon as the cdc bridge queues it,
  /// before the memory side takes it. Faster, but a queued write is lost
  /// on a bus reset. Has no effect when [busClockSync] is true.
  final bool postedWrites;

  /// Bus data width. Only 32 is supported.
  final int busDataWidth;

  /// Bus slave port, wishbone, `clk`/`reset`.
  late final BusSlavePort bus;

  /// Ac timing turned into controller cycles for [clockHz].
  late final HarborSdramCycles cycles;

  SdramEngine? _engine;

  /// The engine, for tests. Null on a [HarborSimTarget] build.
  @visibleForTesting
  SdramEngine? get engine => _engine;

  @override
  Logic get busError => output('bus_error');

  HarborSdram({
    required this.config,
    required this.baseAddress,
    required this.clockHz,
    this.target,
    this.phy = const HarborSdramPhyConfig(),
    this.maxPostponedRefresh = 8,
    this.maxPulledInRefresh = 8,
    this.busClockSync = false,
    this.postedWrites = false,
    int? busAddressWidth,
    this.busDataWidth = 32,
    super.name = 'sdram',
  }) : super('HarborSdram') {
    if (busDataWidth != 32) {
      throw ArgumentError('HarborSdram needs a 32-bit bus, got $busDataWidth');
    }

    final clk = addInput('clk', Logic());
    final reset = addInput('reset', Logic());

    final busAW = busAddressWidth ?? config.sizeBytes.bitLength;
    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: BusProtocol.wishbone,
      addressWidth: busAW,
      dataWidth: busDataWidth,
      clk: clk,
      reset: reset,
    );

    cycles = HarborSdramCycles(
      config,
      clockHz: clockHz,
      maxPostponedRefresh: maxPostponedRefresh,
      maxPulledInRefresh: maxPulledInRefresh,
      phyMaxClockHz: target is HarborFpgaTarget
          ? SdramPhyEcp5.maxClockHzLvcmos33
          : null,
    );

    if (target is HarborSimTarget) {
      _buildSim(clk, reset, busAW);
      return;
    }
    final memClkPort = busClockSync ? null : addInput('mem_clk', Logic());
    final memResetPort = addInput('mem_reset', Logic());
    final fpgaTarget = target;
    if (fpgaTarget is! HarborFpgaTarget ||
        fpgaTarget.vendor != HarborFpgaVendor.ecp5) {
      throw ArgumentError.value(
        target,
        'target',
        'HarborSdram needs an ecp5 target or a HarborSimTarget',
      );
    }

    createPort('sdram_clk', PortDirection.output);
    createPort('sdram_cke', PortDirection.output);
    createPort('sdram_cs_n', PortDirection.output);
    createPort('sdram_ras_n', PortDirection.output);
    createPort('sdram_cas_n', PortDirection.output);
    createPort('sdram_we_n', PortDirection.output);
    createPort('sdram_ba', PortDirection.output, width: config.bankBits);
    createPort('sdram_addr', PortDirection.output, width: config.rowWidth);
    createPort('sdram_dqm', PortDirection.output, width: config.dataWidth ~/ 8);
    createPort('sdram_dq', PortDirection.inOut, width: config.dataWidth);
    addOutput('init_done');

    _build(clk, reset, memClkPort, memResetPort, busAW, fpgaTarget);
  }

  /// Sim build: [HarborSimDram] sits directly on the bus, on the bus clock.
  /// There is no cdc, no phy, no `mem_clk` and no sdram_* pads. A host
  /// Verilator build cannot show that timing anyway.
  void _buildSim(Logic clk, Logic reset, int busAW) {
    final words = config.sizeBytes ~/ (busDataWidth ~/ 8);
    final dram = HarborSimDram(
      addrWidth: bus.addr.width,
      dataWidth: busDataWidth,
      words: words,
      byteSize: config.sizeBytes,
    );
    addSubModule(dram);
    dram.input('clk').srcConnection! <= clk;
    dram.input('reset').srcConnection! <= reset;
    dram.input('stb').srcConnection! <= bus.stb;
    dram.input('we').srcConnection! <= bus.we;
    dram.input('adr').srcConnection! <= bus.addr;
    dram.input('dat_w').srcConnection! <= bus.dataIn;
    dram.input('sel').srcConnection! <= bus.sel;
    bus.ack <= dram.output('ack');
    bus.dataOut <= dram.output('dat_r');
    addOutput('bus_error') <= Const(0);
  }

  /// Full stack build: wishbone front end -> arbiter -> engine -> ecp5 phy.
  void _build(
    Logic clk,
    Logic reset,
    Logic? memClkPort,
    Logic memResetPort,
    int busAW,
    HarborFpgaTarget fpgaTarget,
  ) {
    final busDW = busDataWidth;
    Logic frontReset, wbCyc, wbWe, wbAdr, wbDatW, wbSel;
    HarborWishboneCdcFifoBridge? cdc;
    final memClk = busClockSync ? clk : memClkPort!;
    final memReset = _releaseSync(memClk, memResetPort, 'mem_reset_sync');
    // The true power-on reset, synced into mem_clk, separate from a later
    // standalone mem_reset. The engine uses it to tell a fresh power-up
    // from a reset that may find a bank still open.
    final coldReset = harborCdcJoinReset(
      memClk,
      Const(0),
      reset,
      name: 'sdram_cold_reset',
    );

    if (busClockSync) {
      frontReset = (reset | memReset).named('front_reset');
      wbCyc = bus.stb;
      wbWe = bus.we;
      wbAdr = bus.addr;
      wbDatW = bus.dataIn;
      wbSel = bus.sel;
      // Set by a mem_reset after the first release, cleared by the bus
      // reset.
      final armed = Logic(name: 'mem_reset_armed');
      final busErr = Logic(name: 'bus_error_r');
      Sequential(clk, [
        If(
          reset,
          then: [armed < Const(0), busErr < Const(0)],
          orElse: [
            If(~memReset, then: [armed < Const(1)]),
            If(memReset & armed, then: [busErr < Const(1)]),
          ],
        ),
      ]);
      addOutput('bus_error') <= busErr;
    } else {
      cdc = HarborWishboneCdcFifoBridge(
        addressWidth: busAW,
        dataWidth: busDW,
        selWidth: busDW ~/ 8,
        depth: 8,
        target: fpgaTarget,
        postedWrites: postedWrites,
        name: 'sdram_cdc',
      );
      addSubModule(cdc);
      cdc.input('s_clk').srcConnection! <= clk;
      cdc.input('s_reset').srcConnection! <= reset;
      cdc.input('s_cyc').srcConnection! <= bus.stb;
      cdc.input('s_stb').srcConnection! <= Const(1);
      cdc.input('s_we').srcConnection! <= bus.we;
      cdc.input('s_adr').srcConnection! <= bus.addr;
      cdc.input('s_dat_w').srcConnection! <= bus.dataIn;
      cdc.input('s_sel').srcConnection! <= bus.sel;
      bus.ack <= cdc.output('s_ack');
      bus.dataOut <= cdc.output('s_dat_r');
      cdc.input('m_clk').srcConnection! <= memClk;
      cdc.input('m_reset').srcConnection! <= memReset;
      // The joined reset asserts without the clock, so it goes through two
      // flops before the front end uses it.
      final joined = cdc.output('m_reset_joined');
      final abort0 = Logic(name: 'front_reset_0');
      frontReset = Logic(name: 'front_reset');
      Sequential(memClk, [
        If(
          memReset,
          then: [abort0 < Const(1), frontReset < Const(1)],
          orElse: [abort0 < joined, frontReset < abort0],
        ),
      ]);
      // The cdc can start a request before the front reset ends. Hold it
      // back until then.
      wbCyc = cdc.output('m_cyc') & cdc.output('m_stb') & ~frontReset;
      wbWe = cdc.output('m_we');
      wbAdr = cdc.output('m_adr');
      wbDatW = cdc.output('m_dat_w');
      wbSel = cdc.output('m_sel');
      addOutput('bus_error') <= cdc.output('s_bus_error');
    }

    final clientPort = SdramPortInterface(
      addrWidth: config.wordAddrWidth,
      wordsWidth: 4,
    );

    final wbPort = SdramWishbonePort(
      clk: memClk,
      reset: memReset,
      abort: frontReset,
      cyc: wbCyc,
      we: wbWe,
      adr: wbAdr,
      datW: wbDatW,
      sel: wbSel,
      port: clientPort,
    );

    if (busClockSync) {
      bus.ack <= wbPort.ack;
      bus.dataOut <= wbPort.datR;
    } else {
      cdc!.input('m_ack').srcConnection! <= wbPort.ack;
      cdc.input('m_dat_r').srcConnection! <= wbPort.datR;
    }

    final enginePort = SdramPortInterface(
      addrWidth: config.wordAddrWidth,
      wordsWidth: clientPort.wordsWidth,
      portIdWidth: 1,
      wrLookahead: true,
    );

    // Computed ahead of building the phy, from the phy's own formula, so
    // the pipeline that waits for phy data can be sized before the phy
    // exists. Checked against the phy's own [SdramPhyEcp5.readLatency]
    // once it is built, below.
    final phyReadLatency = SdramPhyEcp5.computeReadLatency(
      cycles.casLatency,
      phy,
    );
    final phyRdData = Logic(name: 'phy_rd_data', width: config.dataWidth);

    final engineInst = SdramEngine(
      config,
      cycles,
      clk: memClk,
      reset: memReset,
      abort: frontReset,
      coldReset: coldReset,
      port: enginePort,
      phyRdData: phyRdData,
      phyReadLatency: phyReadLatency,
    );
    _engine = engineInst;

    SdramArbiter(
      clk: memClk,
      reset: memReset,
      abort: frontReset,
      ports: [clientPort],
      configs: const [HarborSdramPortConfig(name: 'wishbone')],
      engine: enginePort,
    );

    final dqPad = inOut('sdram_dq') as LogicNet;
    final phyInst = SdramPhyEcp5(
      config,
      casLatency: cycles.casLatency,
      clk: memClk,
      reset: memReset,
      cke: engineInst.phyCke,
      csN: engineInst.phyCsN,
      rasN: engineInst.phyRasN,
      casN: engineInst.phyCasN,
      weN: engineInst.phyWeN,
      ba: engineInst.phyBa,
      addr: engineInst.phyAddr,
      dqm: engineInst.phyDqm,
      dqOut: engineInst.phyDqOut,
      dqOe: engineInst.phyDqOe,
      dqPad: dqPad,
      phy: phy,
    );
    assert(
      phyReadLatency == phyInst.readLatency,
      'phyReadLatency ($phyReadLatency) must match '
      'SdramPhyEcp5.readLatency (${phyInst.readLatency})',
    );
    phyRdData <= phyInst.rdData;

    output('sdram_clk') <= phyInst.oSdramClk;
    output('sdram_cke') <= phyInst.oSdramCke;
    output('sdram_cs_n') <= phyInst.oSdramCsN;
    output('sdram_ras_n') <= phyInst.oSdramRasN;
    output('sdram_cas_n') <= phyInst.oSdramCasN;
    output('sdram_we_n') <= phyInst.oSdramWeN;
    output('sdram_ba') <= phyInst.oSdramBa;
    output('sdram_addr') <= phyInst.oSdramAddr;
    output('sdram_dqm') <= phyInst.oSdramDqm;
    output('init_done') <= engineInst.initDone;
  }

  /// Asserts with [rst] at once and releases it on a [clk] edge.
  Logic _releaseSync(Logic clk, Logic rst, String name) {
    final s0 = Logic(name: '${name}_0');
    final s1 = Logic(name: name);
    Sequential(
      clk,
      [s0 < Const(0), s1 < s0],
      reset: rst,
      asyncReset: true,
      resetValues: {s0: Const(1), s1: Const(1)},
    );
    return s1;
  }

  String get _addressMapName =>
      config.addressMap == HarborSdramAddressMap.rowBankCol
      ? 'row-bank-col'
      : 'bank-row-col';

  Map<String, Object> get _commonProperties => {
    'sdram-type': 'sdr',
    'data-width': config.dataWidth,
    'clock-frequency': clockHz,
    'harbor,sdram-part': config.part,
    'harbor,sdram-cas-latency': cycles.casLatency,
    'harbor,sdram-banks': config.banks,
    'harbor,sdram-rows': config.rowWidth,
    'harbor,sdram-cols': config.colWidth,
  };

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: const ['harbor,sdram-controller', 'harbor,sdr-sdram'],
    reg: BusAddressRange(baseAddress, config.sizeBytes),
    properties: {
      ..._commonProperties,
      'harbor,sdram-address-map': _addressMapName,
    },
  );

  @override
  List<BusAddressRange> get systemMemory => [
    BusAddressRange(baseAddress, config.sizeBytes),
  ];

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, config.sizeBytes)],
    properties: {
      'compatible': const ['harbor,sdram-controller', 'harbor,sdr-sdram'],
      ..._commonProperties,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'SDRAM',
    groupName: 'SDRAM',
    description: 'SDR sdram controller',
    baseAddress: baseAddress,
    size: config.sizeBytes,
  );
}
