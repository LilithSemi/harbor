import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../peripherals/sdram_phy_ecp5_harness.dart';
import '../peripherals/sdram_pin_model.dart';

/// A fabric master that the test bench drives one access at a time.
class _BenchMaster extends BridgeModule {
  _BenchMaster(WishboneConfig cfg) : super('BenchMaster', name: 'bench') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('t_cyc', PortDirection.input);
    createPort('t_we', PortDirection.input);
    createPort('t_adr', PortDirection.input, width: 32);
    createPort('t_dat', PortDirection.input, width: 32);
    addOutput('t_ack');
    addOutput('t_dat_r', width: 32);
    final bus =
        addInterface(
              WishboneInterface(cfg),
              name: 'bus',
              role: PairRole.provider,
            ).internalInterface
            as WishboneInterface;
    bus.cyc <= input('t_cyc');
    bus.stb <= input('t_cyc');
    bus.we <= input('t_we');
    bus.adr <= input('t_adr');
    bus.datMosi <= input('t_dat');
    bus.sel <= Const(0xF, width: 4);
    output('t_ack') <= bus.ack;
    output('t_dat_r') <= bus.datMiso;
  }
}

/// [HarborDualClockDisplay] as a fabric master.
class _BenchDisplay extends BridgeModule {
  _BenchDisplay(
    WishboneConfig cfg, {
    required HarborDisplayTiming timing,
    required int burstWords,
  }) : super('BenchDisplay', name: 'display') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('pixel_clk', PortDirection.input);
    createPort('pixel_reset', PortDirection.input);
    createPort('fb_base', PortDirection.input, width: 32);
    createPort('enable', PortDirection.input);
    final bus =
        addInterface(
              WishboneInterface(cfg),
              name: 'bus',
              role: PairRole.provider,
            ).internalInterface
            as WishboneInterface;
    final shift = Const(0);
    final d = HarborDualClockDisplay(
      target: const HarborSimTarget(),
      timing: timing,
      pixelClk: input('pixel_clk'),
      pixelReset: input('pixel_reset'),
      shiftClk: shift,
      shiftReset: shift,
      sysClk: input('clk'),
      sysReset: input('reset'),
      enable: input('enable'),
      fbBase: input('fb_base'),
      mDataIn: bus.datMiso,
      mAck: bus.ack,
      burstWords: burstWords,
    );
    bus.cyc <= d.mCyc;
    bus.stb <= d.mStb;
    bus.we <= d.mWe;
    bus.adr <= d.mAddr;
    bus.sel <= d.mSel;
    bus.datMosi <= d.mDataOut;
    addOutput('underrun') <= d.underrun;
  }
}

/// Wait and grant counts of one fabric master, in system clock cycles.
class MasterStats {
  /// Cycles with `cyc` high and the grant on another master.
  int waitNoGrant = 0;

  /// Cycles with the grant on this master.
  int granted = 0;

  /// Longest single access, from `cyc` high to `ack`.
  int longestAccess = 0;

  /// Longest single access to the sram.
  int longestSramAccess = 0;

  @override
  String toString() =>
      'waitNoGrant $waitNoGrant, granted $granted, '
      'longestAccess $longestAccess, longestSramAccess $longestSramAccess';
}

/// An SoC with a display, a bench master, a [HarborSdram] (real controller,
/// ecp5 phy, pin-level sdram model) and a [HarborSram] behind one fabric
/// arbiter and decoder, as in a Glacier SoC.
class ScanoutContentionBench {
  static const sdramBase = 0x80000000;
  static const sramBase = 0x10000000;
  static const sramSize = 1024;

  final HarborDisplayTiming timing;
  final int burstWords;
  final int sysPeriodPs;
  final int memPeriodPs;
  final int pixelPeriodPs;
  final int fbBase;

  late final HarborSoC soc;
  late final HarborSdram sdram;
  late final SdramPinModel model;
  late final _BenchMaster bench;
  late final _BenchDisplay display;
  late final Logic sysClk;
  late final Logic memClk;
  late final Logic pixelClk;
  final sysReset = Logic(name: 'sys_reset');
  final memReset = Logic(name: 'mem_reset');
  final pixelReset = Logic(name: 'pixel_reset');
  final enable = Logic(name: 'enable');
  final tCyc = Logic(name: 'tb_cyc');
  final tWe = Logic(name: 'tb_we');
  final tAdr = Logic(name: 'tb_adr', width: 32);
  final tDat = Logic(name: 'tb_dat', width: 32);

  final benchStats = MasterStats();
  final displayStats = MasterStats();

  /// Fetch time of each line, in system clock cycles.
  final lineCycles = <int>[];

  /// System clock cycles with the underrun flag high.
  int underrunCycles = 0;

  late final HarborSdramConfig _config;

  ScanoutContentionBench({
    required this.timing,
    required this.burstWords,
    this.sysPeriodPs = 40000,
    this.memPeriodPs = 10000,
    this.pixelPeriodPs = 39722,
    this.fbBase = sdramBase + 0x10000,
  });

  int get _memHz => 1000000000000 ~/ memPeriodPs;

  Future<void> start() async {
    const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
    const base = HarborSdramConfig.as4c16m16sb6();
    _config = base.copyWith(timing: base.timing.copyWith(powerUpNs: 2000));
    final cycles = HarborSdramCycles(
      _config,
      clockHz: _memHz,
      phyMaxClockHz: SdramPhyEcp5.maxClockHzLvcmos33,
    );

    soc = HarborSoC(name: 'ScanoutSoC', compatible: 'test,scanout');
    bench = soc.addMaster(_BenchMaster(cfg), busInterfaceName: 'bus');
    display = soc.addMaster(
      _BenchDisplay(cfg, timing: timing, burstWords: burstWords),
      busInterfaceName: 'bus',
    );
    sdram = soc.addPeripheral(
      HarborSdram(
        config: _config,
        baseAddress: sdramBase,
        clockHz: _memHz,
        busAddressWidth: 32,
        target: const HarborFpgaTarget.ecp5(
          device: 'LFE5U-85F',
          package: 'CABGA381',
        ),
      ),
    );
    soc.addPeripheral(
      HarborSram(baseAddress: sramBase, size: sramSize, busAddressWidth: 32),
    );
    soc.buildFabric();

    sysClk = SimpleClockGenerator(sysPeriodPs).clk;
    memClk = SimpleClockGenerator(memPeriodPs).clk;
    pixelClk = SimpleClockGenerator(pixelPeriodPs).clk;

    soc.input('clk').srcConnection! <= sysClk;
    soc.input('reset').srcConnection! <= sysReset;
    sdram.input('mem_clk').srcConnection! <= memClk;
    sdram.input('mem_reset').srcConnection! <= memReset;
    bench.input('t_cyc').srcConnection! <= tCyc;
    bench.input('t_we').srcConnection! <= tWe;
    bench.input('t_adr').srcConnection! <= tAdr;
    bench.input('t_dat').srcConnection! <= tDat;
    display.input('pixel_clk').srcConnection! <= pixelClk;
    display.input('pixel_reset').srcConnection! <= pixelReset;
    display.input('fb_base').srcConnection! <= Const(fbBase, width: 32);
    display.input('enable').srcConnection! <= enable;
    for (final s in [sysReset, memReset, pixelReset]) {
      s.inject(1);
    }
    enable.inject(0);
    tCyc.inject(0);
    tWe.inject(0);
    tAdr.inject(0);
    tDat.inject(0);

    await soc.build();

    final phy = sdram.subModules.whereType<SdramPhyEcp5>().single;
    final bbs = {for (final m in phy.subModules.whereType<Ecp5Bb>()) m.name: m};
    final dqBbs = [for (var i = 0; i < 16; i++) bbs['dq_bb_$i']!];
    const fpgaToSdramNs = 4.6;
    final tAcNs = cycles.casLatency == 3 ? 5.0 : 6.0;
    if (!sdramPhyCaptureOk(
      periodPs: memPeriodPs,
      tAcNs: tAcNs,
      fpgaToSdramNs: fpgaToSdramNs,
      phy: const HarborSdramPhyConfig(),
    )) {
      throw ArgumentError('the capture window misses at $memPeriodPs ps');
    }
    model = SdramPinModel(
      clk: sdram.output('sdram_clk'),
      cke: sdram.output('sdram_cke'),
      csN: sdram.output('sdram_cs_n'),
      rasN: sdram.output('sdram_ras_n'),
      casN: sdram.output('sdram_cas_n'),
      weN: sdram.output('sdram_we_n'),
      ba: sdram.output('sdram_ba'),
      addr: sdram.output('sdram_addr'),
      dqm: sdram.output('sdram_dqm'),
      dq: sdram.inOutSource('sdram_dq') as LogicNet,
      rules: const SdramModelRules.as4c16m16sb6().copyWith(powerUpNs: 2000),
      fpgaToSdramNs: fpgaToSdramNs,
      fpgaDqOe: [for (final bb in dqBbs) ~bb.input('T')].rswizzle(),
      fpgaDqOut: [for (final bb in dqBbs) bb.input('I')].rswizzle(),
      refreshPolicy: SdramRefreshPolicy(
        maxPostponed: cycles.maxPostponed,
        maxPulledIn: cycles.maxPulledIn,
        periodNs: cycles.refi * memPeriodPs / 1000,
        maxLatencyNs: 256 * memPeriodPs / 1000,
        initRefreshes: cycles.initRefreshes,
      ),
    );

    _watch();
    Simulator.setMaxSimTime(1 << 50);
    unawaited(Simulator.run());

    for (var i = 0; i < 8; i++) {
      await sysClk.nextPosedge;
    }
    sysReset.put(0);
    pixelReset.put(0);
    for (var i = 0; i < 8; i++) {
      await memClk.nextPosedge;
    }
    memReset.put(0);
    while (sdram.output('init_done').value != LogicValue.one) {
      await memClk.nextPosedge;
    }
    enable.put(1);
  }

  /// The fetcher's busy flag, found by type in the display.
  Logic _fetcherBusy() {
    Iterable<Module> all(Module m) sync* {
      yield m;
      for (final s in m.subModules) {
        yield* all(s);
      }
    }

    final f = all(display).firstWhere((m) => m is HarborLineFetcher);
    return f.output('busy');
  }

  void _watch() {
    final grant = (soc.fabric! as HarborWishboneFabric).grant;
    final busy = _fetcherBusy();
    final iface = display.interface('bus').interface as WishboneInterface;
    var dispAccess = 0;

    sysClk.posedge.listen((_) {
      final g = grant!.value;
      bool owns(int i) => g.isValid && g[i] == LogicValue.one;
      if (owns(0)) benchStats.granted++;
      if (tCyc.value == LogicValue.one && !owns(0)) benchStats.waitNoGrant++;
      if (owns(1)) displayStats.granted++;
      if (iface.cyc.value == LogicValue.one) {
        dispAccess++;
        if (!owns(1)) displayStats.waitNoGrant++;
        if (iface.ack.value == LogicValue.one) {
          displayStats.longestAccess = max(
            displayStats.longestAccess,
            dispAccess,
          );
          dispAccess = 0;
        }
      } else {
        dispAccess = 0;
      }
    });

    var busyFor = 0;
    final under = display.output('underrun');
    sysClk.posedge.listen((_) {
      if (under.value == LogicValue.one) underrunCycles++;
      if (busy.value == LogicValue.one) {
        busyFor++;
      } else if (busyFor > 0) {
        lineCycles.add(busyFor);
        busyFor = 0;
      }
    });
  }

  Future<int> _access(int addr, {int? write, int limit = 1 << 20}) async {
    tAdr.inject(addr);
    tDat.inject(write ?? 0);
    tWe.inject(write == null ? 0 : 1);
    tCyc.inject(1);
    var n = 0;
    while (true) {
      await sysClk.nextPosedge;
      n++;
      if (bench.output('t_ack').value == LogicValue.one) break;
      if (n > limit) throw StateError('no ack at 0x${addr.toRadixString(16)}');
    }
    benchStats.longestAccess = max(benchStats.longestAccess, n);
    if (addr < sdramBase) {
      benchStats.longestSramAccess = max(benchStats.longestSramAccess, n);
    }
    final r = bench.output('t_dat_r').value;
    final v = r.isValid ? r.toInt() : -1;
    tCyc.inject(0);
    tWe.inject(0);
    await sysClk.nextPosedge;
    return v;
  }

  Future<void> write(int addr, int data) => _access(addr, write: data);
  Future<int> read(int addr) => _access(addr);

  Future<void> stop() async {
    model.finish();
    await Simulator.endSimulation();
  }
}
