/// SoC wrapper for the sdr sdram controller: a Wishbone bus -> optional cdc
/// -> [SdramWishbonePort], or an AXI4 or TileLink memory slave port -> port
/// layer crossing -> [SdramMemoryPort], then [SdramArbiter] -> [SdramEngine]
/// -> a phy.
library;

import 'package:meta/meta.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../arith/fpu_config.dart' show harborStableDefinitionName;
import '../blackbox/ecp5/ecp5.dart';
import '../bus/bus_exports.dart';
import '../clock/cdc.dart';
import '../clock/wishbone_cdc_fifo.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../soc/target.dart';
import 'memory_waist_beats.dart';
import 'sdram_config.dart';
import 'sdram_cycles.dart';
import 'sdram_engine.dart';
import 'sdram_memory_port.dart';
import 'sdram_phy_ecp5.dart';
import 'sdram_port.dart';
import 'sdram_wishbone_port.dart';
import 'sim_dram.dart';

/// SoC wrapper for the sdr sdram controller.
///
/// A Wishbone [protocol] has a classic Wishbone port with the ERR, CTI and
/// BTE signals of a Wishbone memory slave. It ignores CTI and BTE, so each
/// beat is one classic access, and it never drives ERR:
///
///   bus (clk, Wishbone B4 32b) -> HarborWishboneCdcFifoBridge 'sdram_cdc'
///     with flops on its memory side (skipped when [busClockSync])
///     -> SdramWishbonePort -> SdramPortSlice -> SdramArbiter -> SdramEngine
///     -> SdramPhyEcp5 -> sdram_* pads
///
/// With [postedWrites] false (the default), a write is acked only after
/// the memory side has taken it, so no acked write is lost on a bus
/// reset. With it true, writes are posted (about 3x faster back to
/// back), but a posted write still in the clock-crossing fifo is lost on
/// a bus reset. Either reset sets the sticky `bus_error`.
///
/// An AXI4 or TileLink [protocol] has a memory slave port:
///
///   bus (clk, memory slave port of [protocol], [outstanding] in flight)
///     -> port layer crossing to mem_clk
///     -> SdramMemoryPort -> SdramPortSlice -> SdramArbiter -> SdramEngine
///     -> SdramPhyEcp5 -> sdram_* pads
///
/// That port answers in acceptance order per direction. A burst goes to the
/// arbiter as sdram requests of up to [SdramMemoryPort.maxWords] words, one
/// for each aligned 4-beat block, so a long burst never holds the engine
/// for longer than a scanout request does. A write gets its response when
/// the arbiter has taken its last sdram request, so writes are not posted
/// across the crossing. A request that a reset cuts off ends with an error
/// response, which sets the sticky `bus_error`.
///
/// Everything after the crossing runs on `mem_clk`. The target must be a
/// Lattice ecp5 or a [HarborSimTarget], which replaces the whole stack with
/// [HarborSimDram] on the bus clock.
///
/// `mem_reset` re-initializes the device, so its contents are not
/// guaranteed after one. A bus `reset` alone keeps the sdram contents.
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
  /// port exists and the cdc bridge is skipped. `mem_reset` stays. It needs
  /// a Wishbone [protocol].
  final bool busClockSync;

  /// When true, a write is acked as soon as the cdc bridge queues it,
  /// before the memory side takes it. Faster, but a queued write is lost
  /// on a bus reset. Has no effect when [busClockSync] is true. It needs a
  /// Wishbone [protocol].
  final bool postedWrites;

  /// Bus address width.
  final int busAddressWidth;

  /// Bus data width. Only 32 is supported.
  final int busDataWidth;

  /// Fabric kind of the bus port.
  final HarborFabricKind protocol;

  /// Request ID width of the bus port.
  final int idWidth;

  /// The IDs of the AXI4 exclusive monitor on [bus], or null for no
  /// monitor. See [HarborMemorySlavePort.create].
  final HarborAxi4Exclusive? exclusive;

  /// Requests the bus port keeps in flight. A Wishbone port has only one in
  /// flight, so it must be 1. The others default to 8.
  final int outstanding;

  /// The largest Wishbone burst block the SoC fabric plans for. The
  /// Wishbone port does each beat as one classic access.
  final int wishboneBurstBeats;

  /// Entries in each FIFO of the crossing, or 0 when there is none. A
  /// Wishbone build uses 2, or 8 with [postedWrites].
  final int cdcDepth;

  /// Number of scanout ports, 0 or 1.
  final int scanoutPorts;

  /// Requests a scanout port may have in flight, taken and not yet read
  /// back to the last word, 1 to 3. More can keep the bus port waiting for
  /// a whole line. With 1, a line streams at about 74 MB/s at 100 MHz and
  /// 80 MB/s at 125 MHz, which is at or below the 80.5 MB/s of a 640x480
  /// 32 bpp display.
  final int scanoutMaxInFlight;

  /// Plain register stages on the request and the return path of each
  /// scanout port, so the port client can sit far from the controller. The
  /// in-flight limit covers the stages. Each stage adds one cycle to each
  /// path. No effect on a [HarborSimTarget] build.
  final int readPortStages;

  /// Largest scanout request, in 16-bit words.
  static const scanoutMaxWords = 8;

  /// Bus cycles from a read strobe to its ack on a [HarborSimTarget] build.
  /// [HarborSimDram.latencyFor] gives the cost of the real controller.
  final int simReadLatency;

  /// Bus cycles from a write strobe to its ack on a [HarborSimTarget] build.
  final int simWriteLatency;

  /// Memory slave port `bus` of an AXI4 or TileLink build. Null on a
  /// Wishbone build.
  late final HarborMemorySlavePort? bus;

  late final _WishboneBus _wb;

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
    this.protocol = HarborFabricKind.wishbone,
    this.idWidth = 1,
    this.exclusive,
    int? outstanding,
    this.wishboneBurstBeats = 8,
    int? cdcDepth,
    this.scanoutPorts = 0,
    this.scanoutMaxInFlight = 3,
    this.readPortStages = 0,
    this.simReadLatency = 1,
    this.simWriteLatency = 1,
    super.name = 'sdram',
  }) : busAddressWidth = busAddressWidth ?? config.sizeBytes.bitLength,
       outstanding = _outstanding(protocol, outstanding),
       cdcDepth = _cdcDepth(
         target,
         protocol,
         busClockSync,
         postedWrites,
         cdcDepth,
         _outstanding(protocol, outstanding),
       ),
       super(
         _definitionName(
           config: config,
           cycles: _cycles(
             config,
             clockHz,
             target,
             maxPostponedRefresh,
             maxPulledInRefresh,
           ),
           clockHz: clockHz,
           target: target,
           phy: phy,
           busClockSync: busClockSync,
           postedWrites: postedWrites,
           busAddressWidth: busAddressWidth ?? config.sizeBytes.bitLength,
           busDataWidth: busDataWidth,
           protocol: protocol,
           idWidth: idWidth,
           outstanding: _outstanding(protocol, outstanding),
           wishboneBurstBeats: wishboneBurstBeats,
           cdcDepth: _cdcDepth(
             target,
             protocol,
             busClockSync,
             postedWrites,
             cdcDepth,
             _outstanding(protocol, outstanding),
           ),
           scanoutPorts: scanoutPorts,
           scanoutMaxInFlight: scanoutMaxInFlight,
           readPortStages: readPortStages,
           simReadLatency: simReadLatency,
           simWriteLatency: simWriteLatency,
           exclusive: exclusive,
         ),
       ) {
    if (busDataWidth != 32) {
      throw ArgumentError('HarborSdram needs a 32-bit bus, got $busDataWidth');
    }
    if (this.outstanding < 1) {
      throw ArgumentError.value(
        this.outstanding,
        'outstanding',
        'must be >= 1',
      );
    }
    // A mem_reset resets the port of a busClockSync build. Only a Wishbone
    // master can run its cycle again. An AXI4 or TileLink master would wait
    // for a response that never comes.
    if (busClockSync && protocol != HarborFabricKind.wishbone) {
      throw ArgumentError.value(
        protocol,
        'protocol',
        'busClockSync needs a Wishbone port',
      );
    }
    if (exclusive != null && protocol != HarborFabricKind.axi4) {
      throw ArgumentError.value(
        protocol,
        'protocol',
        'an exclusive monitor needs an AXI4 port',
      );
    }
    if (postedWrites && protocol != HarborFabricKind.wishbone) {
      throw ArgumentError.value(
        protocol,
        'protocol',
        'postedWrites needs a Wishbone port',
      );
    }
    if (protocol == HarborFabricKind.wishbone) {
      if (this.outstanding != 1) {
        throw ArgumentError.value(
          this.outstanding,
          'outstanding',
          'a Wishbone port has one request in flight',
        );
      }
      if (cdcDepth != null) {
        throw ArgumentError.value(
          cdcDepth,
          'cdcDepth',
          'a Wishbone port takes its crossing depth from postedWrites',
        );
      }
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
    if (readPortStages < 0) {
      throw ArgumentError.value(
        readPortStages,
        'readPortStages',
        'must be >= 0',
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
    if (protocol == HarborFabricKind.wishbone) _wb = _wishbonePort();

    cycles = _cycles(
      config,
      clockHz,
      target,
      maxPostponedRefresh,
      maxPulledInRefresh,
    );

    _addScanPorts();
    if (target is HarborSimTarget) {
      if (protocol == HarborFabricKind.wishbone) {
        bus = null;
        _buildSimWishbone(clk, reset);
      } else {
        bus = _busPort(clk, reset);
        _buildSim(clk);
      }
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

    _build(clk, reset, memClkPort, memResetPort);
  }

  /// The memory waist of the bus port.
  HarborMemoryWaistConfig get _waistConfig => HarborMemoryWaistConfig(
    addressWidth: busAddressWidth,
    dataWidth: busDataWidth,
    idWidth: idWidth,
    outstanding: outstanding,
  );

  /// The memory slave port on [clk], crossed from the fabric clock
  /// [fabric] when that is given. Each channel of the crossing gets its own
  /// copy of the device reset, next to its loads.
  HarborMemorySlavePort _busPort(
    Logic clk,
    Logic reset, {
    HarborFabricClock? fabric,
  }) => HarborMemorySlavePort.create(
    module: this,
    name: 'bus',
    kind: protocol,
    config: _waistConfig,
    clk: clk,
    reset: reset,
    wishboneBurstBeats: wishboneBurstBeats,
    exclusive: exclusive,
    deviceAddressWidth: (config.sizeBytes - 1).bitLength,
    fabricClock: fabric,
    cdcDepth: fabric == null ? null : cdcDepth,
    deviceResetCopy: fabric == null
        ? null
        : (ck, d, set, name) =>
              Ecp5Fd1s3bx(d: d, ck: ck, pd: set, name: name).q,
  );

  /// The Wishbone port `bus`, with the signals of a Wishbone memory slave.
  /// It ignores CTI and BTE and never drives ERR.
  _WishboneBus _wishbonePort() {
    final ref = addInterface(
      WishboneInterface(harborWishboneMemoryConfig(_waistConfig)),
      name: 'bus',
      role: PairRole.consumer,
    );
    final wb = ref.internalInterface!;
    final datOut = Logic(name: 'bus_dat_out', width: busDataWidth);
    final ackOut = Logic(name: 'bus_ack_out');
    wb.datMiso <= datOut;
    wb.ack <= ackOut;
    wb.err! <= Const(0);
    return (
      addr: wb.adr,
      dataIn: wb.datMosi,
      dataOut: datOut,
      stb: wb.cyc & wb.stb,
      we: wb.we,
      sel: wb.sel,
      ack: ackOut,
    );
  }

  static int _outstanding(HarborFabricKind kind, int? n) =>
      n ?? (kind == HarborFabricKind.wishbone ? 1 : 8);

  static int _cdcDepth(
    HarborDeviceTarget? target,
    HarborFabricKind kind,
    bool busClockSync,
    bool postedWrites,
    int? depth,
    int outstanding,
  ) {
    if (target is HarborSimTarget || busClockSync) return 0;
    // Without posted writes only one request is in the fifo at a time.
    // Two entries keep the head read mux to one LUT level.
    if (kind == HarborFabricKind.wishbone) return postedWrites ? 8 : 2;
    return depth ?? harborCdcDepth(outstanding);
  }

  static HarborSdramCycles _cycles(
    HarborSdramConfig config,
    int clockHz,
    HarborDeviceTarget? target,
    int maxPostponed,
    int maxPulledIn,
  ) => HarborSdramCycles(
    config,
    clockHz: clockHz,
    maxPostponedRefresh: maxPostponed,
    maxPulledInRefresh: maxPulledIn,
    phyMaxClockHz: target is HarborFpgaTarget
        ? SdramPhyEcp5.maxClockHzLvcmos33
        : null,
  );

  static String _definitionName({
    required HarborSdramConfig config,
    required HarborSdramCycles cycles,
    required int clockHz,
    required HarborDeviceTarget? target,
    required HarborSdramPhyConfig phy,
    required bool busClockSync,
    required bool postedWrites,
    required int busAddressWidth,
    required int busDataWidth,
    required HarborFabricKind protocol,
    required int idWidth,
    required int outstanding,
    required int wishboneBurstBeats,
    required int cdcDepth,
    required int scanoutPorts,
    required int scanoutMaxInFlight,
    required int readPortStages,
    required int simReadLatency,
    required int simWriteLatency,
    required HarborAxi4Exclusive? exclusive,
  }) {
    final sim = target is HarborSimTarget;
    final c = cycles;
    final burst = protocol == HarborFabricKind.wishbone
        ? '_b$wishboneBurstBeats'
        : '';
    return harborStableDefinitionName(
      'HarborSdram_${sim ? 'sim' : 'ecp5'}_${protocol.name}_i${idWidth}'
      '_n${outstanding}_q$cdcDepth$burst',
      [
        config.part.replaceAll(RegExp('[^A-Za-z0-9]'), ''),
        'a$busAddressWidth',
        'd$busDataWidth',
        'bk${config.banks}r${config.rowWidth}c${config.colWidth}',
        'map${config.addressMap.index}',
        'ck$clockHz',
        'cl${c.casLatency}',
        't${c.rc}_${c.rfc}_${c.rcd}_${c.rp}_${c.rasMin}_${c.rrd}_${c.mrd}'
            '_${c.wr}_${c.refi}_${c.powerUp}_${c.initRefreshes}'
            '_${c.readHiz}_${c.rowAgeLimit}_${c.maxPostponed}'
            '_${c.maxPulledIn}',
        'p${phy.captureCycles}${phy.captureEdge.index}'
            '${phy.captureCycleOffset}_${phy.dqDelayTaps ?? 'x'}',
        if (busClockSync) 'sync',
        if (postedWrites) 'posted',
        's${scanoutPorts}f$scanoutMaxInFlight',
        if (readPortStages > 0 && !sim) 'rs$readPortStages',
        if (sim) 'rl${simReadLatency}wl$simWriteLatency',
        ?exclusive?.tag,
      ],
    );
  }

  /// Wishbone sim build: [HarborSimDram] sits directly on the bus, on the
  /// bus clock. There is no cdc, no phy, no `mem_clk` and no sdram_* pads.
  void _buildSimWishbone(Logic clk, Logic reset) {
    final words = config.sizeBytes ~/ (busDataWidth ~/ 8);
    final dram = HarborSimDram(
      addrWidth: _wb.addr.width,
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
    dram.input('stb').srcConnection! <= _wb.stb;
    dram.input('we').srcConnection! <= _wb.we;
    dram.input('adr').srcConnection! <= _wb.addr;
    dram.input('dat_w').srcConnection! <= _wb.dataIn;
    dram.input('sel').srcConnection! <= _wb.sel;
    // No classic/registered-feedback burst from the fabric yet, so this
    // leaf always sees a classic cycle.
    dram.input('cti').srcConnection! <= Const(0, width: 3);
    _wb.ack <= dram.output('ack');
    _wb.dataOut <= dram.output('dat_r');
    addOutput('bus_error') <= Const(0);
    _simScanPorts(dram, clk, reset);
  }

  /// Joins the scanout ports of a sim build to [dram].
  void _simScanPorts(HarborSimDram dram, Logic clk, Logic reset) {
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

  /// Sim build: [HarborSimDram] behind the bus port, on the bus clock, one
  /// beat at a time. There is no crossing, no phy, no `mem_clk` and no
  /// sdram_* pads. A host Verilator build cannot show that timing anyway.
  void _buildSim(Logic clk) {
    final words = config.sizeBytes ~/ (busDataWidth ~/ 8);
    final ack = Logic(name: 'mem_ack');
    final datOut = Logic(name: 'mem_dat_r', width: busDataWidth);
    final port = bus!;
    final beats = HarborMemoryBeats(
      clk: clk,
      reset: port.reset,
      waist: port.waist,
      ack: ack,
      dataOut: datOut,
    );
    final dram = HarborSimDram(
      addrWidth: beats.addr.width,
      dataWidth: busDataWidth,
      words: words,
      byteSize: config.sizeBytes,
      readLatency: simReadLatency,
      writeLatency: simWriteLatency,
      scanoutPorts: scanoutPorts,
    );
    addSubModule(dram);
    dram.input('clk').srcConnection! <= clk;
    dram.input('reset').srcConnection! <= port.reset;
    dram.input('stb').srcConnection! <= beats.stb;
    dram.input('we').srcConnection! <= beats.we;
    dram.input('adr').srcConnection! <= beats.addr;
    dram.input('dat_w').srcConnection! <= beats.dataIn;
    dram.input('sel').srcConnection! <= beats.sel;
    ack <= dram.output('ack');
    datOut <= dram.output('dat_r');
    _busError(clk, input('reset'), Const(0));
    _simScanPorts(dram, clk, input('reset'));
  }

  /// Drives the sticky `bus_error` on [clk]: set by an error response on
  /// the native port or on the fabric side waist, or by [also], cleared by
  /// [reset]. The waist side catches a response the crossing cut off even
  /// when the master leaves before it takes it.
  void _busError(Logic clk, Logic reset, Logic also) {
    final port = bus!;
    final w = port.fabricWaist;
    final errBeat =
        harborPortErrorBeat(port.interfaceRef.internalInterface!) |
        (w.rdataValid & w.rdataReady & w.rdataErr) |
        (w.wrespValid & w.wrespReady & w.wrespErr);
    final busErr = Logic(name: 'bus_error_r');
    Sequential(clk, [
      If(
        reset,
        then: [busErr < 0],
        orElse: [
          If(errBeat | also, then: [busErr < 1]),
        ],
      ),
    ]);
    addOutput('bus_error') <= busErr;
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

  /// Full stack build: bus front end -> arbiter -> engine -> ecp5 phy.
  void _build(Logic clk, Logic reset, Logic? memClkPort, Logic memResetPort) {
    final wishbone = protocol == HarborFabricKind.wishbone;
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
    final portReset = localReset(wishbone ? 'wb' : 'port');
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

    final Logic frontReset, engineAbort;
    Logic? abortNext;
    // The arbiter took a write of the bus port, from the slice.
    final busWrTaken = Logic(name: 'bus_wr_taken');
    if (wishbone) {
      bus = null;
      final front = _wishboneFront(
        clk,
        reset,
        memClk,
        frontLocalReset,
        cdcReset,
      );
      frontReset = front.frontReset;
      engineAbort = front.engineAbort;
      abortNext = front.abortNext;
      final clientPort = SdramPortInterface(
        addrWidth: config.wordAddrWidth,
        wordsWidth: 4,
      );
      final wbPort = SdramWishbonePort(
        clk: memClk,
        reset: portReset,
        abort: frontReset,
        cyc: front.cyc,
        we: front.we,
        adr: front.adr,
        datW: front.datW,
        sel: front.sel,
        port: clientPort,
        writeTaken: busWrTaken,
      );
      if (front.cdc case final cdc?) {
        cdc.input('m_ack').srcConnection! <= wbPort.ackPulse;
        cdc.input('m_dat_r').srcConnection! <= wbPort.datR;
      } else {
        _wb.ack <= wbPort.ack;
        _wb.dataOut <= wbPort.datR;
      }
      _buildBack(
        memClk: memClk,
        clientPort: clientPort,
        busWrTaken: busWrTaken,
        clientName: 'wishbone',
        frontReset: frontReset,
        engineAbort: engineAbort,
        abortNext: abortNext,
        localReset: localReset,
        arbiterReset: arbiterReset,
        engineReset: engineReset,
        engineDataReset: engineDataReset,
        timersReset: timersReset,
        phyReset: phyReset,
        coldReset: coldReset,
      );
      return;
    }

    final Logic portClear;
    final port = _busPort(
      memClk,
      cdcReset,
      fabric: HarborFabricClock(clk: clk, reset: reset),
    );
    bus = port;
    // The joined reset asserts without the clock, so it goes through two
    // flops before the front end uses it.
    final joined = port.reset;
    final abort0 = Logic(name: 'front_reset_0');
    final front = Logic(name: 'front_reset');
    Sequential(memClk, [
      If(
        frontLocalReset,
        then: [abort0 < 1, front < 1],
        orElse: [abort0 < joined, front < abort0],
      ),
    ]);
    frontReset = front;
    // A copy of [frontReset] for the engine, which the placer can keep
    // next to its loads. The engine also gets its next value.
    abortNext = frontLocalReset | abort0;
    engineAbort = Ecp5Fd1s3bx(
      d: abortNext,
      ck: memClk,
      pd: Const(0),
      name: 'engine_abort',
    ).q;
    // The front end clear is port reset or front reset, from one flop.
    portClear = Ecp5Fd1s3bx(
      d: memReset | abortNext,
      ck: memClk,
      pd: Const(0),
      name: 'port_clear',
    ).q;
    _busError(clk, reset, Const(0));

    final clientPort = SdramPortInterface(
      addrWidth: config.wordAddrWidth,
      wordsWidth: 4,
    );
    SdramMemoryPort(
      clk: memClk,
      reset: portReset,
      abort: frontReset,
      clear: portClear,
      waist: port.waist,
      port: clientPort,
      writeTaken: busWrTaken,
    );
    _buildBack(
      memClk: memClk,
      clientPort: clientPort,
      busWrTaken: busWrTaken,
      clientName: 'bus',
      frontReset: frontReset,
      engineAbort: engineAbort,
      abortNext: abortNext,
      localReset: localReset,
      arbiterReset: arbiterReset,
      engineReset: engineReset,
      engineDataReset: engineDataReset,
      timersReset: timersReset,
      phyReset: phyReset,
      coldReset: coldReset,
    );
  }

  /// The Wishbone front end up to [SdramWishbonePort]: the cdc bridge, or
  /// the bus itself with [busClockSync]. It also
  /// drives `bus_error`.
  ({
    HarborWishboneCdcFifoBridge? cdc,
    Logic frontReset,
    Logic engineAbort,
    Logic? abortNext,
    Logic cyc,
    Logic we,
    Logic adr,
    Logic datW,
    Logic sel,
  })
  _wishboneFront(
    Logic clk,
    Logic reset,
    Logic memClk,
    Logic frontLocalReset,
    Logic cdcReset,
  ) {
    if (busClockSync) {
      final frontReset = (reset | frontLocalReset).named('front_reset');
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
      return (
        cdc: null,
        frontReset: frontReset,
        engineAbort: frontReset,
        abortNext: null,
        cyc: _wb.stb,
        we: _wb.we,
        adr: _wb.addr,
        datW: _wb.dataIn,
        sel: _wb.sel,
      );
    }
    final busAW = busAddressWidth;
    final busDW = busDataWidth;
    final cdc = HarborWishboneCdcFifoBridge(
      addressWidth: busAW,
      dataWidth: busDW,
      selWidth: busDW ~/ 8,
      depth: cdcDepth,
      target: target,
      postedWrites: postedWrites,
      // The bus side of the bridge can sit far from the memory side, so
      // both directions are flop to flop there. Net latency cost is 0: the
      // removed wb_slice stage gives the request to the port 1 mem_clk
      // cycle earlier, and done_r pushes the response 1 mem_clk cycle later.
      registerMaster: true,
      name: 'sdram_cdc',
    );
    addSubModule(cdc);
    cdc.input('s_clk').srcConnection! <= clk;
    cdc.input('s_reset').srcConnection! <= reset;
    cdc.input('s_cyc').srcConnection! <= _wb.stb;
    cdc.input('s_stb').srcConnection! <= Const(1);
    cdc.input('s_we').srcConnection! <= _wb.we;
    cdc.input('s_adr').srcConnection! <= _wb.addr;
    cdc.input('s_dat_w').srcConnection! <= _wb.dataIn;
    cdc.input('s_sel').srcConnection! <= _wb.sel;
    _wb.ack <= cdc.output('s_ack');
    _wb.dataOut <= cdc.output('s_dat_r');
    cdc.input('m_clk').srcConnection! <= memClk;
    cdc.input('m_reset').srcConnection! <= cdcReset;
    // The joined reset asserts without the clock, so it goes through two
    // flops before the front end uses it.
    final joined = cdc.output('m_reset_joined');
    final abort0 = Logic(name: 'front_reset_0');
    final frontReset = Logic(name: 'front_reset');
    Sequential(memClk, [
      If(
        frontLocalReset,
        then: [abort0 < Const(1), frontReset < Const(1)],
        orElse: [abort0 < joined, frontReset < abort0],
      ),
    ]);
    // A copy of [frontReset] for the engine, which the placer can keep
    // next to its loads. The engine also gets its next value.
    final abortNext = frontLocalReset | abort0;
    final engineAbort = Ecp5Fd1s3bx(
      d: abortNext,
      ck: memClk,
      pd: Const(0),
      name: 'engine_abort',
    ).q;
    addOutput('bus_error') <= cdc.output('s_bus_error');
    return (
      cdc: cdc,
      frontReset: frontReset,
      engineAbort: engineAbort,
      abortNext: abortNext,
      cyc: cdc.output('m_cyc'),
      we: cdc.output('m_we'),
      adr: cdc.output('m_adr'),
      datW: cdc.output('m_dat_w'),
      sel: cdc.output('m_sel'),
    );
  }

  /// The scanout ports, the arbiter, the engine and the phy behind
  /// [clientPort], the bus port of the arbiter.
  void _buildBack({
    required Logic memClk,
    required SdramPortInterface clientPort,
    required Logic busWrTaken,
    required String clientName,
    required Logic frontReset,
    required Logic engineAbort,
    required Logic? abortNext,
    required Logic Function(String) localReset,
    required Logic arbiterReset,
    required Logic engineReset,
    required Logic engineDataReset,
    required Logic timersReset,
    required Logic phyReset,
    required Logic coldReset,
  }) {
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

    // The bus port client sits near the bus, so a slice gives it
    // registered ready signals toward the arbiter.
    final slicedPort = SdramPortInterface(
      addrWidth: clientPort.addrWidth,
      wordsWidth: clientPort.wordsWidth,
    );
    busWrTaken <=
        SdramPortSlice(
          clk: memClk,
          reset: localReset('slice'),
          abort: frontReset,
          client: clientPort,
          arbiter: slicedPort,
        ).writeTaken;

    SdramArbiter(
      clk: memClk,
      reset: arbiterReset,
      abort: frontReset,
      ports: [slicedPort, ...scanPorts],
      configs: [
        HarborSdramPortConfig(name: clientName),
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
  /// requests in flight, 1 to 3. The best effort port may send its requests
  /// back to back, as the bus port does with many requests in flight, and
  /// each of them is at most [scanoutMaxWords] words.
  ///
  /// The request waits for the entry ahead of it and for one entry per
  /// realtime win. Its own requests ahead of it do not add to this: one is
  /// that entry ahead, and the others are already past the arbiter.
  ///
  /// The realtime port wins at most [maxInFlight] grant points in a row,
  /// because its oldest read is still in flight at the next one.
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
  /// `mem_clk` cycles, plus one cycle in the [SdramPortSlice] in front of
  /// the arbiter. It holds for each sdram request of the bus port with any
  /// [outstanding], because [SdramMemoryPort] sends requests of at most
  /// [scanoutMaxWords] words.
  int get busWaitBound => bestEffortWaitBound(cycles, scanoutMaxInFlight) + 1;

  /// The sdram requests [SdramMemoryPort] sends for a burst of [beats]
  /// beats of 2^[size] bytes and type [burst]. A full size INCR or WRAP
  /// burst takes one per 4-beat block it touches, at most beats / 4 + 1. A
  /// FIXED or narrow burst takes one per beat.
  static int busRequestsFor(
    int beats, {
    int size = 2,
    HarborMemoryBurst burst = HarborMemoryBurst.incr,
  }) {
    if (beats < 1 || beats > 256) {
      throw ArgumentError.value(beats, 'beats', 'must be 1..256');
    }
    if (size < 2 || burst == HarborMemoryBurst.fixed) return beats;
    return (beats + 3) ~/ 4 + 1;
  }

  /// The most `mem_clk` cycles the scanout port adds to a bus burst once it
  /// is the oldest request in the controller: each of its
  /// [busRequestsFor] sdram requests waits at most [busWaitBound]. A
  /// request behind others in flight also waits for theirs.
  int busBurstWaitBound(
    int beats, {
    int size = 2,
    HarborMemoryBurst burst = HarborMemoryBurst.incr,
  }) => busRequestsFor(beats, size: size, burst: burst) * busWaitBound;

  /// Joins scanout port [i] to [sp], an arbiter port. Every port output
  /// comes from a register. A take is held back while
  /// [scanoutMaxInFlight] requests are taken and not yet read back to the
  /// last word, so the bus port gets the grant points between them.
  ///
  /// With no [readPortStages], a taken request waits in a one-entry slot
  /// that drives the arbiter. With stages, it goes through the stages to a
  /// queue of [scanoutMaxInFlight] entries in front of the arbiter, and the
  /// in-flight limit keeps that queue from overflow.
  void _buildScanPort(int i, Logic clk, Logic rst, SdramPortInterface sp) {
    final p = 'scan$i';
    final cw = scanoutMaxInFlight.bitLength;
    final count = Logic(name: '${p}_in_flight', width: cw);
    final ready = Logic(name: '${p}_ready');
    sp.reqWrite <= Const(0);
    sp.wrValid <= Const(0);
    sp.wrData <= Const(0, width: 16);
    sp.wrMask <= Const(0, width: 2);
    output('${p}_rq_ready') <= ready;

    // The arbiter registers the return path, the stages come after it.
    var rdValid = sp.rdValid;
    var rdLast = sp.rdLast;
    var rdData = sp.rdData;
    for (var k = 0; k < readPortStages; k++) {
      final v = Logic(name: '${p}_rd_valid_s$k');
      final l = Logic(name: '${p}_rd_last_s$k');
      final d = Logic(name: '${p}_rd_data_s$k', width: 16);
      Sequential(clk, [
        If(rst, then: [v < 0], orElse: [v < rdValid]),
        l < rdLast,
        d < rdData,
      ]);
      (rdValid, rdLast, rdData) = (v, l, d);
    }
    output('${p}_rd_valid') <= rdValid;
    output('${p}_rd_data') <= rdData;

    final take = (input('${p}_rq_valid') & ready).named('${p}_take');
    // A finish counts on the edge after the last word is on the port.
    final fin = rdValid & rdLast;
    // [ready] holds back a take at the limit, and a finish needs a take
    // before it, so the count stays in 0..[scanoutMaxInFlight]. The sim
    // check below stops the run if that breaks.
    final countNext = mux(
      take & ~fin,
      count + 1,
      mux(fin & ~take, count - 1, count),
    ).named('${p}_in_flight_next');
    _checkScan(
      clk,
      rst,
      (take & ~fin & count.eq(scanoutMaxInFlight)) |
          (fin & ~take & count.eq(0)),
      'scanout port $i in-flight count out of range',
    );
    final addr = _scanWordAddr(input('${p}_rq_addr'));
    final words = input('${p}_rq_words');

    final Logic readyNext;
    if (readPortStages == 0) {
      final slotValid = Logic(name: '${p}_slot_valid');
      final slotAddr = Logic(name: '${p}_slot_addr', width: sp.addrWidth);
      final slotWords = Logic(name: '${p}_slot_words', width: 4);
      sp.reqValid <= slotValid;
      sp.reqAddr <= slotAddr;
      sp.reqWords <= slotWords;
      // [ready] is high only while the slot is empty, so the slot loads
      // whenever it is empty and the port inputs never drive a clock
      // enable.
      final slotNext = take | (slotValid & ~sp.reqReady);
      readyNext = ~slotNext & countNext.neq(scanoutMaxInFlight);
      Sequential(clk, [
        If(~slotValid, then: [slotAddr < addr, slotWords < words]),
        If(rst, then: [slotValid < 0], orElse: [slotValid < slotNext]),
      ]);
    } else {
      _scanQueue(p, clk, rst, sp, take, addr, words);
      readyNext = ~take & countNext.neq(scanoutMaxInFlight);
    }
    Sequential(clk, [
      If(
        rst,
        then: [
          count < Const(0, width: cw),
          ready < 0,
        ],
        orElse: [count < countNext, ready < readyNext],
      ),
    ]);
  }

  /// The [readPortStages] request stages of scanout port [p] and the queue
  /// at their end that drives [sp]. Each taken request is one entry until
  /// the arbiter takes it.
  void _scanQueue(
    String p,
    Logic clk,
    Logic rst,
    SdramPortInterface sp,
    Logic take,
    Logic addr,
    Logic words,
  ) {
    var v = take;
    var a = addr;
    var w = words;
    for (var k = 0; k < readPortStages; k++) {
      final vs = Logic(name: '${p}_rq_valid_s$k');
      final as = Logic(name: '${p}_rq_addr_s$k', width: a.width);
      final ws = Logic(name: '${p}_rq_words_s$k', width: w.width);
      Sequential(clk, [
        If(rst, then: [vs < 0], orElse: [vs < v]),
        as < a,
        ws < w,
      ]);
      (v, a, w) = (vs, as, ws);
    }

    final depth = scanoutMaxInFlight;
    final qValid = [
      for (var j = 0; j < depth; j++) Logic(name: '${p}_q_valid_$j'),
    ];
    final qAddr = [
      for (var j = 0; j < depth; j++)
        Logic(name: '${p}_q_addr_$j', width: a.width),
    ];
    final qWords = [
      for (var j = 0; j < depth; j++)
        Logic(name: '${p}_q_words_$j', width: w.width),
    ];
    sp.reqValid <= qValid[0];
    sp.reqAddr <= qAddr[0];
    sp.reqWords <= qWords[0];

    // A take moves every entry one place down, then a new entry goes into
    // the first free place.
    final pop = qValid[0] & sp.reqReady;
    Logic after(List<Logic> q, int j, Logic empty) =>
        mux(pop, j + 1 < depth ? q[j + 1] : empty, q[j]);
    final vAfter = [for (var j = 0; j < depth; j++) after(qValid, j, Const(0))];
    _checkScan(clk, rst, v & vAfter[depth - 1], 'scanout $p queue overflow');
    final seq = <Conditional>[];
    for (var j = 0; j < depth; j++) {
      final free = ~vAfter[j] & (j == 0 ? Const(1) : vAfter[j - 1]);
      final we = v & free;
      seq
        ..add(qAddr[j] < mux(we, a, after(qAddr, j, qAddr[j])))
        ..add(qWords[j] < mux(we, w, after(qWords, j, qWords[j])));
      seq.add(
        If(rst, then: [qValid[j] < 0], orElse: [qValid[j] < vAfter[j] | we]),
      );
    }
    Sequential(clk, seq);
  }

  /// Stops the simulation when [bad] is high on a [clk] edge out of reset.
  void _checkScan(Logic clk, Logic rst, Logic bad, String message) {
    clk.glitch.listen((args) {
      if (!LogicValue.isPosedge(
            args.previousValue,
            args.newValue,
            ignoreInvalid: true,
          ) ||
          rst.value != LogicValue.zero) {
        return;
      }
      if (bad.value == LogicValue.one) {
        Simulator.throwException(Exception(message), StackTrace.current);
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

/// The device side of the Wishbone port `bus`.
typedef _WishboneBus = ({
  Logic addr,
  Logic dataIn,
  Logic dataOut,
  Logic stb,
  Logic we,
  Logic sel,
  Logic ack,
});
