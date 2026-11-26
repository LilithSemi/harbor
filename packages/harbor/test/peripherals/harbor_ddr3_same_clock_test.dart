import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../bus/port/memory_harness.dart';
import 'ddr3_fast_bench.dart';

const _artix = HarborFpgaTarget.artix7(device: 'xc7a200t', package: 'fbg484');
const _kc705Pins = ['clk', 'clk_n', 'uart_tx', 'uart_rx'];

HarborDdr3 _ddr({
  bool sameClock = false,
  bool performanceMonitor = false,
  HarborFabricKind protocol = HarborFabricKind.axi4,
  HarborDeviceTarget? target,
}) => HarborDdr3(
  config: const HarborDdrConfig.ax7203(),
  baseAddress: 0x80000000,
  clockHz: 83333333,
  busAddressWidth: 32,
  busDataWidth: 32,
  ckPeriodPs: 3000,
  protocol: protocol,
  sameClock: sameClock,
  performanceMonitor: performanceMonitor,
  target: target ?? _artix,
);

class _Cpu extends BridgeModule {
  _Cpu() : super('SameClockCpu', name: 'cpu') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final i = addInterface(
      Axi4Interface(addressWidth: 32, dataWidth: 32, idWidth: 1),
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

HarborSoC _soc({
  required List<HarborClockConfig> clocks,
  String? fabric,
  bool tree = true,
}) => HarborSoC(
  name: 'SameClockSoc',
  compatible: 'test,same-clock',
  fabricKind: HarborFabricKind.axi4,
  fabricClockDomain: fabric,
  target: HarborBoard.get('kc705').fpgaTarget(pins: _kc705Pins),
  clocks: clocks,
  xilinxDdr3Tree: tree
      ? const XilinxDdr3TreeSpec.kc705(coreClkHz: 50000000)
      : null,
);

const _core = HarborClockConfig(
  name: 'core',
  rate: HarborFixedClockRate(50000000),
  sourceFrequency: 200000000,
  source: HarborClockSource.ddr3Core,
);

const _bus = HarborClockConfig(
  name: 'bus',
  rate: HarborFixedClockRate(83333333),
  sourceFrequency: 200000000,
  source: HarborClockSource.ddr3Controller,
);

void _addDdrAndCpu(HarborSoC soc, {String? domain}) {
  soc.addMaster(_Cpu(), clockDomainName: domain);
  soc.addPeripheral(_ddr(sameClock: true), clockDomainName: domain);
}

void main() {
  tearDown(() async => Simulator.reset());

  group('the module', () {
    test('has no ddr_clk or ddr_reset port and no crossing', () async {
      final ddr = _ddr(sameClock: true);
      expect(ddr.sameClock, isTrue);
      expect(ddr.inputs.keys, isNot(contains('ddr_clk')));
      expect(ddr.inputs.keys, isNot(contains('ddr_reset')));
      expect(ddr.inputs.keys, contains('ddr_ck_fast'));
      expect(ddr.performanceEvents, isEmpty);
      expect(ddr.outputs.keys.where((n) => n.startsWith('perf_')), isEmpty);
      await ddr.build();
      final sv = ddr.dumpSystemVerilog();
      for (final name in [
        'Ddr3PerformanceMonitor',
        'ddr_performance_monitor',
        'HarborMemoryWaistCdc',
        'HarborCdcSync',
        'HarborCdcHandshake',
        'status_sync',
        'cal_state_cdc',
        'ddr_reset_sync1',
      ]) {
        expect(sv, isNot(contains(name)), reason: name);
      }
    });

    test('without the flag the crossing is still there', () async {
      final ddr = _ddr();
      expect(ddr.sameClock, isFalse);
      expect(ddr.inputs.keys, containsAll(['ddr_clk', 'ddr_reset']));
      expect(ddr.performanceEvents, isEmpty);
      await ddr.build();
      final sv = ddr.dumpSystemVerilog();
      for (final name in [
        'HarborMemoryWaistCdc',
        'status_sync',
        'cal_state_cdc',
      ]) {
        expect(sv, contains(name), reason: name);
      }
    });

    test('the performance monitor adds the perf ports', () async {
      final ddr = _ddr(sameClock: true, performanceMonitor: true);
      expect(ddr.definitionName, isNot(_ddr(sameClock: true).definitionName));
      expect(ddr.performanceClock, isNotNull);
      expect(
        ddr.performanceEvents.keys,
        containsAll([
          'controller_accept',
          'ch0_read_wait',
          'ch0_latency_ge64',
          'ch0_latency_invalid_cycles',
        ]),
      );
      for (final name in ddr.performanceEvents.keys) {
        expect(ddr.outputs.keys, contains('perf_$name'));
      }
      await ddr.build();
      expect(ddr.dumpSystemVerilog(), contains('Ddr3PerformanceMonitor'));
    });

    for (final (why, sameClock, protocol, target) in [
      ('without sameClock', false, HarborFabricKind.axi4, null),
      ('on a Wishbone port', true, HarborFabricKind.wishbone, null),
      ('on a sim target', true, HarborFabricKind.axi4, const HarborSimTarget()),
    ]) {
      test('the performance monitor is refused $why', () {
        expect(
          () => _ddr(
            sameClock: sameClock,
            performanceMonitor: true,
            protocol: protocol,
            target: target,
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.name,
              'name',
              'performanceMonitor',
            ),
          ),
        );
      });
    }

    test('the flag changes the definition name', () {
      expect(
        _ddr(sameClock: true).definitionName,
        isNot(_ddr().definitionName),
      );
    });

    test('a CK/8 controller cannot be same clock', () {
      expect(
        () => HarborDdr3(
          config: const HarborDdrConfig.ax7203(),
          baseAddress: 0,
          clockHz: 83333333,
          controllerGearRatio: 2,
          sameClock: true,
          target: _artix,
        ),
        throwsArgumentError,
      );
    });
  });

  group('the SoC check', () {
    test('a pll domain throws and names the device and the domain', () {
      final soc = _soc(
        tree: false,
        clocks: [
          HarborClockConfig.fixed(
            name: 'sys',
            frequency: 83333333,
            sourceFrequency: 200000000,
          ),
        ],
      );
      _addDdrAndCpu(soc);
      expect(
        soc.buildFabric,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('ddr3'), contains('"sys"')),
          ),
        ),
      );
    });

    test('a ddr3Controller domain that is not the fabric domain throws', () {
      final soc = _soc(clocks: [_core, _bus], fabric: 'core');
      _addDdrAndCpu(soc, domain: 'bus');
      expect(
        soc.buildFabric,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('ddr3'), contains('"bus"'), contains('fabric')),
          ),
        ),
      );
    });

    test('the ddr3Controller fabric domain passes', () {
      final soc = _soc(clocks: [_core, _bus], fabric: 'bus');
      _addDdrAndCpu(soc);
      soc.buildFabric();
    });
  });

  test('fast sim: writes read back with the device side on clk', () async {
    const cores = [CoreCfg('wr', 2, 8)];
    final top = Ddr3FabricBench(
      sameClock: true,
      cores: cores,
      readChannels: 1,
      outstanding: 8,
    );
    expect(top.ddr.inputs.keys, isNot(contains('ddr_clk')));
    final run = await Ddr3FabricRun.start(
      top,
      seed: 3,
      stall: 0,
      cores: ['wr'],
    );
    final rng = Random(3);
    final m = run.managers['wr']!;
    final golden = WordMemory(4);
    final errors = <String>[];
    for (var i = 0; i < 12; i++) {
      final addr = 0x20000 + rng.nextInt(0x3c0) * 4;
      final len = rng.nextInt(8);
      final beats = len + 1;
      final w = Burst(
        id: 0,
        write: true,
        addr: addr,
        len: len,
        size: 2,
        burst: HarborMemoryBurst.incr.value,
        data: [for (var k = 0; k < beats; k++) rng.nextInt(1 << 32)],
        strb: [for (var k = 0; k < beats; k++) 0xf],
      );
      final addrs = beatAddrs(w.addr, w.len, w.size, w.burst);
      for (var k = 0; k < beats; k++) {
        golden.write(addrs[k], w.data[k], w.strb[k]);
      }
      final bBefore = m.bResp.length;
      final rBefore = m.rBeats.length;
      m.write(w);
      await waitUntil(run.sim, () => m.bResp.length > bBefore);
      m.read(
        Burst(
          id: 0,
          write: false,
          addr: addr,
          len: len,
          size: 2,
          burst: HarborMemoryBurst.incr.value,
        ),
      );
      await waitUntil(run.sim, () => m.rBeats.length == rBefore + beats);
      for (var k = 0; k < beats; k++) {
        final got = m.rBeats[rBefore + k].$2;
        final want = golden.read(addrs[k]);
        if (got != want) errors.add('round $i beat $k: $got, want $want');
      }
    }
    await Simulator.endSimulation();
    expect([...errors, ...run.allErrors], isEmpty);
  });
}
