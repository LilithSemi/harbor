/// SoC wrapper for the sdr sdram controller: wishbone bus -> optional cdc
/// -> [SdramWishbonePort] -> [SdramArbiter] -> [SdramEngine] -> a phy.
library;

import 'package:meta/meta.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../blackbox/ecp5/ecp5.dart';
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
///     and one register stage (both skipped when [busClockSync])
///     -> SdramWishbonePort -> SdramArbiter -> SdramEngine -> SdramPhyEcp5
///     -> sdram_* pads
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
///
/// A scanout port ([scanoutPorts] is 0 or 1) is a read port for a display,
/// such as [HarborDualClockDisplay], that joins the arbiter next to the bus
/// port as a realtime port. It runs on `scan_clk` (`mem_clk`, or `clk` on a
/// [HarborSimTarget]). Port `i` has `scan<i>_rq_valid`, `scan<i>_rq_addr`
/// (a byte address in the SoC memory map), `scan<i>_rq_words` and
/// `scan<i>_rq_ready` for requests, and `scan<i>_rd_valid` and
/// `scan<i>_rd_data` for the 16-bit words that come back. Every port output
/// comes from a register, and `scan<i>_rq_ready` is low on the cycle after
/// a take. A request is at most [scanoutMaxWords] words and must not cross
/// a page. A port has at
/// most [scanoutMaxInFlight] requests in flight, which bounds the wait of
/// the bus port, see [busWaitBound]. A bus `reset` drops only the reads of
/// the bus port. `scan_reset` follows `mem_reset` only (the bus reset on a
/// [HarborSimTarget] build), and a scanout port client must reset on it.
///
/// Two items of the scanout design are not done yet. A page-size CSR would
/// let software pick a framebuffer stride that starts each line on a new
/// row. A refresh hint from the display blanking would move refreshes out
/// of the line fetch, but it adds logic to the command pick.
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

  /// Number of scanout ports, 0 or 1.
  final int scanoutPorts;

  /// Requests a scanout port may have in flight, taken and not yet read
  /// back to the last word, 1 to 3. More can keep the bus port waiting for
  /// a whole line. With 1, a line streams at about 74 MB/s at 100 MHz and
  /// 80 MB/s at 125 MHz, which is at or below the 80.5 MB/s of a 640x480
  /// 32 bpp display.
  final int scanoutMaxInFlight;

  /// Largest scanout request, in 16-bit words.
  static const scanoutMaxWords = 8;

  /// Bus cycles from a read strobe to its ack on a [HarborSimTarget] build.
  /// [HarborSimDram.latencyFor] gives the cost of the real controller.
  final int simReadLatency;

  /// Bus cycles from a write strobe to its ack on a [HarborSimTarget] build.
  final int simWriteLatency;

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
    this.scanoutPorts = 0,
    this.scanoutMaxInFlight = 3,
    this.simReadLatency = 1,
    this.simWriteLatency = 1,
    super.name = 'sdram',
  }) : super('HarborSdram') {
    if (busDataWidth != 32) {
      throw ArgumentError('HarborSdram needs a 32-bit bus, got $busDataWidth');
    }
    if (scanoutPorts < 0) {
      throw ArgumentError.value(scanoutPorts, 'scanoutPorts', 'must be 0 or 1');
    }
    if (scanoutPorts > 1) {
      throw ArgumentError.value(
        scanoutPorts,
        'scanoutPorts',
        'multiple scanout ports are not supported yet, the bus wait bound '
            'holds for one port only',
      );
    }
    if (scanoutMaxInFlight < 1 || scanoutMaxInFlight > 3) {
      throw ArgumentError.value(
        scanoutMaxInFlight,
        'scanoutMaxInFlight',
        'must be 1..3, more can keep the bus port waiting for a whole line',
      );
    }
    if (scanoutPorts > 0 && baseAddress % config.sizeBytes != 0) {
      throw ArgumentError.value(
        baseAddress,
        'baseAddress',
        'must be aligned to the sdram size for scanout ports',
      );
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

    _addScanPorts();
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
      readLatency: simReadLatency,
      writeLatency: simWriteLatency,
      scanoutPorts: scanoutPorts,
      scanoutMaxInFlight: scanoutMaxInFlight,
    );
    addSubModule(dram);
    dram.input('clk').srcConnection! <= clk;
    dram.input('reset').srcConnection! <= reset;
    dram.input('stb').srcConnection! <= bus.stb;
    dram.input('we').srcConnection! <= bus.we;
    dram.input('adr').srcConnection! <= bus.addr;
    dram.input('dat_w').srcConnection! <= bus.dataIn;
    dram.input('sel').srcConnection! <= bus.sel;
    // No classic/registered-feedback burst from the fabric yet, so this
    // leaf always sees a classic cycle.
    dram.input('cti').srcConnection! <= Const(0, width: 3);
    bus.ack <= dram.output('ack');
    bus.dataOut <= dram.output('dat_r');
    addOutput('bus_error') <= Const(0);
    if (scanoutPorts == 0) return;
    addOutput('scan_clk') <= clk;
    addOutput('scan_reset') <= reset;
    for (var i = 0; i < scanoutPorts; i++) {
      dram.input('scan${i}_rq_valid').srcConnection! <=
          input('scan${i}_rq_valid');
      dram.input('scan${i}_rq_addr').srcConnection! <=
          _scanWordAddr(input('scan${i}_rq_addr'));
      dram.input('scan${i}_rq_words').srcConnection! <=
          input('scan${i}_rq_words');
      output('scan${i}_rq_ready') <= dram.output('scan${i}_rq_ready');
      output('scan${i}_rd_valid') <= dram.output('scan${i}_rd_valid');
      output('scan${i}_rd_data') <= dram.output('scan${i}_rd_data');
    }
  }

  /// Adds the scanout port pins.
  void _addScanPorts() {
    for (var i = 0; i < scanoutPorts; i++) {
      addInput('scan${i}_rq_valid', Logic());
      addInput('scan${i}_rq_addr', Logic(width: 32), width: 32);
      addInput('scan${i}_rq_words', Logic(width: 4), width: 4);
      addOutput('scan${i}_rq_ready');
      addOutput('scan${i}_rd_valid');
      addOutput('scan${i}_rd_data', width: 16);
    }
  }

  /// The 16-bit word address of a scanout byte address. The base is aligned
  /// to the size, so the low bits are the offset.
  Logic _scanWordAddr(Logic byteAddr) =>
      byteAddr.getRange(1, 1 + config.wordAddrWidth);

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
    Logic frontReset, engineAbort, wbCyc, wbWe, wbAdr, wbDatW, wbSel;
    Logic? abortNext;
    HarborWishboneCdcFifoBridge? cdc;
    final memClk = busClockSync ? clk : memClkPort!;
    final memReset = _releaseSync(memClk, memResetPort, 'mem_reset_sync');
    // One copy of the reset per block, so no single reset net spans the
    // die. Each copy follows [memReset] one cycle later. Only the two
    // synchronizer flops see the raw reset, so the placer can keep that
    // async path short. Every block resets synchronously anyway.
    Logic localReset(String n) => Ecp5Fd1s3bx(
      d: memReset,
      ck: memClk,
      pd: Const(0),
      name: '${n}_reset',
    ).q;
    final frontLocalReset = localReset('front');
    final cdcReset = localReset('cdc');
    final wbReset = localReset('wb');
    final arbiterReset = localReset('arbiter');
    final engineReset = localReset('engine');
    final engineDataReset = localReset('engine_data');
    final timersReset = localReset('timers');
    final phyReset = localReset('phy');
    // The true power-on reset, synced into mem_clk, separate from a later
    // standalone mem_reset. The engine uses it to tell a fresh power-up
    // from a reset that may find a bank still open.
    // One more flop after the synchronizer, so the flops on the raw bus
    // reset drive one load and can sit near its source.
    final coldReset = Ecp5Fd1s3bx(
      d: harborCdcJoinReset(memClk, Const(0), reset, name: 'sdram_cold_reset'),
      ck: memClk,
      pd: Const(0),
      name: 'sdram_cold_reset_copy',
    ).q;

    if (busClockSync) {
      frontReset = (reset | frontLocalReset).named('front_reset');
      engineAbort = frontReset;
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
            If(~frontLocalReset, then: [armed < Const(1)]),
            If(frontLocalReset & armed, then: [busErr < Const(1)]),
          ],
        ),
      ]);
      addOutput('bus_error') <= busErr;
    } else {
      cdc = HarborWishboneCdcFifoBridge(
        addressWidth: busAW,
        dataWidth: busDW,
        selWidth: busDW ~/ 8,
        // Without posted writes only one request is in the fifo at a time.
        // Two entries keep the head read mux to one LUT level.
        depth: postedWrites ? 8 : 2,
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
      cdc.input('m_reset').srcConnection! <= cdcReset;
      // The joined reset asserts without the clock, so it goes through two
      // flops before the front end uses it.
      final joined = cdc.output('m_reset_joined');
      final abort0 = Logic(name: 'front_reset_0');
      frontReset = Logic(name: 'front_reset');
      Sequential(memClk, [
        If(
          frontLocalReset,
          then: [abort0 < Const(1), frontReset < Const(1)],
          orElse: [abort0 < joined, frontReset < abort0],
        ),
      ]);
      // A copy of [frontReset] for the engine, which the placer can keep
      // next to its loads. The engine also gets its next value.
      abortNext = frontLocalReset | abort0;
      engineAbort = Ecp5Fd1s3bx(
        d: abortNext,
        ck: memClk,
        pd: Const(0),
        name: 'engine_abort',
      ).q;
      // One register stage between the cdc fifo head and the front end, so
      // neither the fifo read mux nor the front end has to sit next to the
      // other. Each request starts one mem_clk cycle later.
      wbCyc = Logic(name: 'wb_slice_cyc');
      wbWe = Logic(name: 'wb_slice_we');
      wbAdr = Logic(name: 'wb_slice_adr', width: busAW);
      wbDatW = Logic(name: 'wb_slice_dat_w', width: busDW);
      wbSel = Logic(name: 'wb_slice_sel', width: busDW ~/ 8);
      Sequential(memClk, [
        // The cdc can start a request before the front reset ends. Hold it
        // back until then.
        If(
          frontLocalReset,
          then: [wbCyc < Const(0)],
          orElse: [
            wbCyc < cdc.output('m_cyc') & cdc.output('m_stb') & ~frontReset,
          ],
        ),
        wbWe < cdc.output('m_we'),
        wbAdr < cdc.output('m_adr'),
        wbDatW < cdc.output('m_dat_w'),
        wbSel < cdc.output('m_sel'),
      ]);
      addOutput('bus_error') <= cdc.output('s_bus_error');
    }

    final clientPort = SdramPortInterface(
      addrWidth: config.wordAddrWidth,
      wordsWidth: 4,
    );

    final wbPort = SdramWishbonePort(
      clk: memClk,
      reset: wbReset,
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

    final scanPorts = [
      for (var i = 0; i < scanoutPorts; i++)
        SdramPortInterface(addrWidth: config.wordAddrWidth, wordsWidth: 4),
    ];
    if (scanoutPorts > 0) {
      // The bus reset keeps scanout reads, so only mem_reset resets the
      // scanout side.
      final scanReset = localReset('scan');
      addOutput('scan_clk') <= memClk;
      addOutput('scan_reset') <= scanReset;
      for (var i = 0; i < scanoutPorts; i++) {
        _buildScanPort(i, memClk, scanReset, scanPorts[i]);
      }
    }

    final enginePort = SdramPortInterface(
      addrWidth: config.wordAddrWidth,
      wordsWidth: clientPort.wordsWidth,
      portIdWidth: scanoutPorts.bitLength.clamp(1, 3),
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
      reset: engineReset,
      dataReset: engineDataReset,
      keepReadsOnAbort: {for (var i = 1; i <= scanoutPorts; i++) i},
      abort: engineAbort,
      abortNext: abortNext,
      coldReset: coldReset,
      timersReset: timersReset,
      port: enginePort,
      phyRdData: phyRdData,
      phyReadLatency: phyReadLatency,
    );
    _engine = engineInst;

    SdramArbiter(
      clk: memClk,
      reset: arbiterReset,
      abort: frontReset,
      ports: [clientPort, ...scanPorts],
      configs: [
        const HarborSdramPortConfig(name: 'wishbone'),
        for (var i = 0; i < scanoutPorts; i++)
          HarborSdramPortConfig(
            name: 'scan$i',
            maxGrantWords: scanoutMaxWords,
            realtime: true,
            abortable: false,
          ),
      ],
      engine: enginePort,
    );

    final dqPad = inOut('sdram_dq') as LogicNet;
    final phyInst = SdramPhyEcp5(
      config,
      casLatency: cycles.casLatency,
      clk: memClk,
      reset: phyReset,
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

  /// Bytes from one line to the next for a line of [lineBytes]: the line
  /// size rounded up to a page, so every line starts on a new row.
  int scanoutStride(int lineBytes) =>
      (lineBytes + config.pageBytes - 1) ~/ config.pageBytes * config.pageBytes;

  /// The most `mem_clk` cycles one request of up to [words] words keeps the
  /// engine busy: a row miss after a write in the same bank, with the bus
  /// turned around after a read.
  static int entryCycles(HarborSdramCycles c, int words) {
    final open = c.rcd + words;
    return c.rp + (open > c.rasMin ? open : c.rasMin) + c.wr + c.casLatency + 2;
  }

  /// The most `mem_clk` cycles a forced refresh and a row age precharge add
  /// between two requests.
  static int refreshCycles(HarborSdramCycles c) => 2 * c.rp + c.rfc;

  /// The longest wait of a realtime request at the arbiter, in `mem_clk`
  /// cycles, from `req_valid` up to the take: the request in progress, a
  /// refresh and the arbiter and engine registers.
  static int realtimeWaitBound(HarborSdramCycles c) =>
      entryCycles(c, scanoutMaxWords) + refreshCycles(c) + 3;

  /// The longest wait of a best effort request at the arbiter, in `mem_clk`
  /// cycles, with one realtime port that keeps at most [maxInFlight]
  /// requests in flight, 1 to 3.
  ///
  /// The request waits for the entry ahead of it and for one entry per
  /// realtime win. The realtime port wins at most [maxInFlight] grant points
  /// in a row, because its oldest read is still in flight at the next one.
  /// At 3, a forced refresh or row age precharge can let that read finish
  /// first, so each of the two stalls can add one more win and one entry.
  /// The last term covers the registers and the short grant gaps after a
  /// stall.
  static int bestEffortWaitBound(HarborSdramCycles c, int maxInFlight) {
    if (maxInFlight < 1 || maxInFlight > 3) {
      throw ArgumentError.value(maxInFlight, 'maxInFlight', 'must be 1..3');
    }
    final entries = maxInFlight + 1 + (maxInFlight == 3 ? 2 : 0);
    return entries * entryCycles(c, scanoutMaxWords) + refreshCycles(c) + 9;
  }

  /// [realtimeWaitBound] for this controller.
  int get scanoutWaitBound => realtimeWaitBound(cycles);

  /// [bestEffortWaitBound] for the bus port of this controller, in
  /// `mem_clk` cycles. It adds to the bus access time with no scanout.
  int get busWaitBound => bestEffortWaitBound(cycles, scanoutMaxInFlight);

  /// Joins scanout port [i] to [sp], an arbiter port. Every port output
  /// comes from a register, and a taken request waits in a one-entry slot
  /// that drives the arbiter. A take is held back while
  /// [scanoutMaxInFlight] requests are taken and not yet read back to the
  /// last word, so the bus port gets the grant points between them.
  void _buildScanPort(int i, Logic clk, Logic rst, SdramPortInterface sp) {
    final cw = scanoutMaxInFlight.bitLength;
    final count = Logic(name: 'scan${i}_in_flight', width: cw);
    final ready = Logic(name: 'scan${i}_ready');
    final slotValid = Logic(name: 'scan${i}_slot_valid');
    final slotAddr = Logic(name: 'scan${i}_slot_addr', width: sp.addrWidth);
    final slotWords = Logic(name: 'scan${i}_slot_words', width: 4);
    final rdValid = Logic(name: 'scan${i}_rd_valid_reg');
    final rdData = Logic(name: 'scan${i}_rd_data_reg', width: 16);
    sp.reqValid <= slotValid;
    sp.reqWrite <= Const(0);
    sp.reqAddr <= slotAddr;
    sp.reqWords <= slotWords;
    sp.wrValid <= Const(0);
    sp.wrData <= Const(0, width: 16);
    sp.wrMask <= Const(0, width: 2);
    output('scan${i}_rq_ready') <= ready;
    output('scan${i}_rd_valid') <= rdValid;
    output('scan${i}_rd_data') <= rdData;

    // [ready] is high only while the slot is empty, so the slot loads
    // whenever it is empty and the port inputs never drive a clock enable.
    final take = (input('scan${i}_rq_valid') & ready).named('scan${i}_take');
    // A finish counts on the edge that puts the last word on the port.
    final fin = sp.rdValid & sp.rdLast;
    final slotNext = take | (slotValid & ~sp.reqReady);
    // [ready] holds back a take at the limit, and a finish needs a take
    // before it, so the count stays in 0..[scanoutMaxInFlight]. The sim
    // check below stops the run if that breaks.
    final countNext = mux(
      take & ~fin,
      count + 1,
      mux(fin & ~take, count - 1, count),
    ).named('scan${i}_in_flight_next');
    _checkInFlight(
      clk,
      rst,
      i,
      take & ~fin & count.eq(scanoutMaxInFlight),
      fin & ~take & count.eq(0),
    );
    Sequential(clk, [
      If(
        ~slotValid,
        then: [
          slotAddr < _scanWordAddr(input('scan${i}_rq_addr')),
          slotWords < input('scan${i}_rq_words'),
        ],
      ),
      rdData < sp.rdData,
      If(
        rst,
        then: [
          count < Const(0, width: cw),
          ready < Const(0),
          slotValid < Const(0),
          rdValid < Const(0),
        ],
        orElse: [
          count < countNext,
          ready < ~slotNext & countNext.neq(scanoutMaxInFlight),
          slotValid < slotNext,
          rdValid < sp.rdValid,
        ],
      ),
    ]);
  }

  /// Stops the simulation when the in-flight count of scanout port [i]
  /// would go past [scanoutMaxInFlight] or below 0.
  void _checkInFlight(Logic clk, Logic rst, int i, Logic over, Logic under) {
    clk.glitch.listen((args) {
      if (!LogicValue.isPosedge(
            args.previousValue,
            args.newValue,
            ignoreInvalid: true,
          ) ||
          rst.value != LogicValue.zero) {
        return;
      }
      if (over.value == LogicValue.one || under.value == LogicValue.one) {
        Simulator.throwException(
          Exception('scanout port $i in-flight count out of range'),
          StackTrace.current,
        );
      }
    });
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
