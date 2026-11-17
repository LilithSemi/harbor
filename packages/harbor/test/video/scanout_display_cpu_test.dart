@Tags(['slow'])
library;

import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../peripherals/sdram_pin_model.dart';
import '../util/reg_bus.dart';
import 'sdram_scanout_harness.dart' show waitInitDone;

/// A register master whose native port pins are plain `p_<PORT>` ports.
class _Cpu extends BridgeModule {
  _Cpu() : super('ScanCpuRegMaster', name: 'cpu') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final i = addInterface(
      Axi4LiteInterface(addressWidth: 32, dataWidth: 32),
      name: 'dataBus',
      role: PairRole.provider,
    ).internalInterface!;
    for (final e in i.getPorts([PairDirection.fromProvider]).entries) {
      final w = e.value.width;
      e.value <= addInput('p_${e.key}', Logic(width: w), width: w);
    }
    for (final e in i.getPorts([PairDirection.fromConsumer]).entries) {
      addOutput('p_${e.key}', width: e.value.width) <= e.value;
    }
  }
}

/// A [HarborLineFetcher] behind an AXI4 memory master port, the read traffic
/// of a cpu that refills cache lines.
class _Hammer extends BridgeModule {
  _Hammer() : super('ScanCpuHammer', name: 'hammer') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final port = HarborMemoryMasterPort.create(
      module: this,
      name: 'bus',
      kind: HarborFabricKind.axi4,
      config: const HarborMemoryWaistConfig(
        addressWidth: 32,
        dataWidth: 32,
        outstanding: 4,
      ),
      clk: input('clk'),
      reset: input('reset'),
    );
    final f = HarborLineFetcher(
      clk: input('clk'),
      reset: port.reset,
      fetchStart: addInput('f_start', Logic()),
      fetchAddr: addInput('f_addr', Logic(width: 32), width: 32),
      words: addInput('f_words', Logic(width: 16), width: 16),
      fillSel: Const(0),
      waist: port.waist,
      maxWords: 64,
      burstWords: 4,
    );
    addOutput('f_done') <= f.done;
  }
}

/// 640-pixel lines with the deadline of a 25 MHz VGA line, and few lines in
/// a frame so a frame stays short enough to simulate.
const _timing = HarborDisplayTiming(
  hActive: 640,
  hFrontPorch: 16,
  hSyncWidth: 96,
  hBackPorch: 48,
  vActive: 4,
  vFrontPorch: 1,
  vSyncWidth: 1,
  vBackPorch: 1,
  pixelClock: 25000000,
);

const _sdramBase = 0x80000000;
const _displayBase = 0x10008000;
const _fbBase = 0x80100000;

/// A ULX3S shaped SoC: AXI4, the sdram on the 25 MHz bus clock with the real
/// controller, phy and pin model, and the display from the one-call helper.
class _Bench {
  late final HarborSoC soc;
  late final HarborSdram sdram;
  late final HarborScanoutDisplay display;
  late final SdramPinModel model;
  late final Logic sysClk;
  late final Logic shiftClk;
  late final RegBus bus;
  final reset = Logic(name: 'reset');
  final fStart = Logic(name: 'drv_f_start');
  final fAddr = Logic(name: 'drv_f_addr', width: 32);
  final fWords = Logic(name: 'drv_f_words', width: 16);

  /// Busy time of the line fetcher for each line, in bus clocks.
  final lineCycles = <int>[];
  bool _count = false;

  static const sysPeriodPs = 40000;
  static const _pads = [
    'sdram_clk',
    'sdram_cke',
    'sdram_cs_n',
    'sdram_ras_n',
    'sdram_cas_n',
    'sdram_we_n',
    'sdram_ba',
    'sdram_addr',
    'sdram_dqm',
    'sdram_dq',
  ];

  Future<void> start() async {
    const base = HarborSdramConfig.as4c16m16sb6();
    final config = base.copyWith(timing: base.timing.copyWith(powerUpNs: 2000));
    final cycles = HarborSdramCycles(
      config,
      clockHz: 25000000,
      phyMaxClockHz: SdramPhyEcp5.maxClockHzLvcmos33,
    );

    soc = HarborSoC(
      name: 'ScanDisplaySoC',
      compatible: 'test,scan-display',
      fabricKind: HarborFabricKind.axi4,
      target: const HarborSimTarget(frequency: 25000000),
      clocks: [
        HarborClockConfig.fixed(
          name: 'sys',
          frequency: 25000000,
          sourceFrequency: 25000000,
          isPrimary: true,
        ),
        HarborClockConfig.fixed(
          name: 'shift',
          frequency: 125000000,
          sourceFrequency: 25000000,
        ),
        HarborClockConfig.fixed(
          name: 'pixel',
          frequency: 25000000,
          sourceFrequency: 25000000,
        ),
      ],
    );
    final cpu = soc.addMaster(_Cpu());
    final hammer = soc.addMaster(
      _Hammer(),
      busInterfaceName: 'bus',
      memory: true,
      outstanding: 4,
    );
    final shape = soc.memoryBusShape();
    sdram = soc.addPeripheral(
      HarborSdram(
        config: config,
        baseAddress: _sdramBase,
        clockHz: 25000000,
        busClockSync: true,
        busAddressWidth: 32,
        protocol: HarborFabricKind.axi4,
        idWidth: shape.idWidth,
        exclusive: shape.exclusive,
        scanoutPorts: 1,
        scanoutLine: HarborScanoutLine.forMode(
          timing: _timing,
          formats: const [HarborPixelFormat.rgb565],
          pixelClockHz: 25000000,
          sdramClockHz: 25000000,
        ),
        target: const HarborFpgaTarget.ecp5(
          device: 'LFE5U-85F',
          package: 'CABGA381',
        ),
      ),
    );
    display = soc.addScanoutDisplay(
      sdram: sdram,
      timing: _timing,
      framebufferBase: _fbBase,
      baseAddress: _displayBase,
    );
    for (final n in [...cpu.inputs.keys, ...cpu.outputs.keys]) {
      if (n.startsWith('p_')) {
        soc.pullUpPort(cpu.port(n), newPortName: 'cpu_${n.substring(2)}');
      }
    }
    for (final n in ['f_start', 'f_addr', 'f_words', 'f_done']) {
      soc.pullUpPort(hammer.port(n), newPortName: n);
    }
    for (final p in _pads) {
      soc.pullUpPort(sdram.port(p), newPortName: p);
    }
    soc.buildFabric();

    sysClk = SimpleClockGenerator(sysPeriodPs).clk;
    // The serializer is not checked here, and a 125 MHz clock makes the
    // simulation several times slower.
    shiftClk = Logic(name: 'shift_const');
    soc.input('clk').srcConnection! <= sysClk;
    soc.input('reset').srcConnection! <= reset;
    soc.input('shift_clk').srcConnection! <= shiftClk;
    soc.input('f_start').srcConnection! <= fStart;
    soc.input('f_addr').srcConnection! <= fAddr;
    soc.input('f_words').srcConnection! <= fWords;
    bus = RegBus.attach(soc, sysClk, name: 'cpu', kind: HarborFabricKind.axi4);
    await soc.build();
    shiftClk.inject(0);
    reset.inject(1);
    bus.idle();
    fStart.inject(0);
    fAddr.inject(0);
    fWords.inject(0);

    final phy = sdram.subModules.whereType<SdramPhyEcp5>().single;
    final bbs = {for (final m in phy.subModules.whereType<Ecp5Bb>()) m.name: m};
    final dqBbs = [for (var i = 0; i < 16; i++) bbs['dq_bb_$i']!];
    model = SdramPinModel(
      clk: soc.output('sdram_clk'),
      cke: soc.output('sdram_cke'),
      csN: soc.output('sdram_cs_n'),
      rasN: soc.output('sdram_ras_n'),
      casN: soc.output('sdram_cas_n'),
      weN: soc.output('sdram_we_n'),
      ba: soc.output('sdram_ba'),
      addr: soc.output('sdram_addr'),
      dqm: soc.output('sdram_dqm'),
      dq: soc.inOutSource('sdram_dq') as LogicNet,
      rules: const SdramModelRules.as4c16m16sb6().copyWith(powerUpNs: 2000),
      fpgaToSdramNs: 4.6,
      fpgaDqOe: [for (final bb in dqBbs) ~bb.input('T')].rconcat(),
      fpgaDqOut: [for (final bb in dqBbs) bb.input('I')].rconcat(),
      refreshPolicy: SdramRefreshPolicy(
        maxPostponed: cycles.maxPostponed,
        maxPulledIn: cycles.maxPulledIn,
        periodNs: cycles.refi * sysPeriodPs / 1000,
        maxLatencyNs: 256 * sysPeriodPs / 1000,
        initRefreshes: cycles.initRefreshes,
      ),
    );

    final fetcher = _all(
      display.display,
    ).whereType<HarborScanoutFetcher>().single.output('busy');
    var busyFor = 0;
    sysClk.posedge.listen((_) {
      if (fetcher.value == LogicValue.one) {
        busyFor++;
      } else if (busyFor > 0) {
        if (_count) lineCycles.add(busyFor);
        busyFor = 0;
      }
    });

    Simulator.setMaxSimTime(1 << 50);
    unawaited(Simulator.run());
    for (var i = 0; i < 8; i++) {
      await sysClk.nextPosedge;
    }
    reset.put(0);
    await waitInitDone(sdram, sysClk);
  }

  static Iterable<Module> _all(Module m) sync* {
    yield m;
    for (final s in m.subModules) {
      yield* _all(s);
    }
  }

  /// Fetches 64 words from a different row and bank each time for [cycles]
  /// bus clocks. Returns the completed fetches.
  Future<int> hammer(int cycles, {int gap = 0}) async {
    var done = 0;
    var i = 0;
    var cyc = 0;
    final sub = sysClk.posedge.listen((_) => cyc++);
    final f = soc.output('f_done');
    while (cyc < cycles) {
      fAddr.inject(
        _sdramBase + 0x400000 + ((i * 0x1100 + (i % 5) * 64) % 0x300000),
      );
      fWords.inject(64);
      fStart.inject(1);
      await sysClk.nextPosedge;
      fStart.inject(0);
      var guard = 0;
      while (f.value != LogicValue.one) {
        await sysClk.nextPosedge;
        if (guard++ > 4000) throw StateError('fetch $i never finished');
      }
      done++;
      i++;
      for (var g = 0; g <= gap; g++) {
        await sysClk.nextPosedge;
      }
    }
    await sub.cancel();
    return done;
  }

  void startCounting() {
    lineCycles.clear();
    _count = true;
  }

  void stopCounting() => _count = false;

  Future<void> stop() async {
    model.finish();
    await Simulator.endSimulation();
  }
}

void main() {
  tearDown(() async {
    if (!Simulator.simulationHasEnded) await Simulator.endSimulation();
    await Simulator.reset();
  });

  test('640x480 rgb565 lines at 25 MHz meet their deadline while a cpu master '
      'hammers the sdram', () async {
    final b = _Bench();
    await b.start();

    // Turn the display on through its registers on the fabric.
    expect(await b.bus.read(_displayBase + 0x10), _fbBase);
    expect(await b.bus.read(_displayBase + 0x18), 2048);
    await b.bus.write(_displayBase + 0x00, 1);
    print('ctrl ${await b.bus.read(_displayBase)}');
    for (var k = 0; k < 12; k++) {
      for (var i = 0; i < 3000; i++) {
        await b.sysClk.nextPosedge;
      }
      final st = await b.bus.read(_displayBase + 0x08);
      print('status 0x${st.toRadixString(16)}');
      if (st & 1 == 1) break;
    }
    expect(await b.bus.read(_displayBase + 0x08) & 1, 1, reason: 'running');

    // Idle bus: the cost of a line fetch alone.
    b.startCounting();
    for (var i = 0; i < 800 * 7 * 2; i++) {
      await b.sysClk.nextPosedge;
    }
    b.stopCounting();
    final idle = List.of(b.lineCycles);
    expect(idle.length, greaterThanOrEqualTo(4));

    const window = 800 * 7 * 2;
    const period = 800;
    final bound = HarborSdram.scanoutLineBound(
      b.sdram.cycles,
      b.sdram.config,
      640,
      periodCycles: 800,
    );
    print('line bound $bound of $period clocks');
    final idleMargin = period - idle.reduce(max);
    print(
      'idle: ${idle.length} lines, fetch ${idle.reduce(min)} to '
      '${idle.reduce(max)} clocks, margin $idleMargin of $period clocks',
    );
    expect(idleMargin, greaterThan(0));
    expect(await b.bus.read(_displayBase + 0x08) & 4, 0, reason: 'idle');

    // A cpu master that fetches 256 bytes from a new row, then waits [gap]
    // clocks, and one that never waits.
    for (final gap in [300, 0]) {
      await b.bus.write(_displayBase + 0x40, 2);
      b.startCounting();
      final fetches = await b.hammer(window, gap: gap);
      b.stopCounting();
      final busy = List.of(b.lineCycles);
      expect(busy.length, greaterThanOrEqualTo(4));
      final margin = period - busy.reduce(max);
      final mb = fetches * 256 / (window * 40e-9) / 1e6;
      final status = await b.bus.read(_displayBase + 0x08);
      print(
        'cpu gap $gap: ${busy.length} lines, fetch ${busy.reduce(min)} to '
        '${busy.reduce(max)} clocks, margin $margin of $period clocks, '
        '$fetches fetches in $window clocks, ${mb.toStringAsFixed(1)} MB/s, '
        'status 0x${status.toRadixString(16)}',
      );
      expect(margin, greaterThan(0), reason: 'gap $gap misses a line');
      expect(status & 4, 0, reason: 'gap $gap underrun');
      expect(busy.reduce(max), lessThanOrEqualTo(bound), reason: 'gap $gap');
      expect(fetches, greaterThan(0));

      // Writes and reads of the register master stay in order and are not
      // posted, while the scanout runs.
      const check = _sdramBase + 0x7f0000;
      for (var k = 0; k < 4; k++) {
        await b.bus.write(check + 4 * k, 0xa5000000 | (gap << 8) | k);
      }
      for (var k = 0; k < 4; k++) {
        expect(
          await b.bus.read(check + 4 * k),
          0xa5000000 | (gap << 8) | k,
          reason: 'gap $gap word $k',
        );
      }
    }
    expect(b.model.errors, isEmpty);
    await b.stop();
  }, timeout: const Timeout(Duration(minutes: 20)));
}
