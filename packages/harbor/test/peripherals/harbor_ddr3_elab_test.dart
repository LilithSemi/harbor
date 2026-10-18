import 'package:harbor/harbor.dart';
import 'package:harbor/src/clock/wishbone_cdc_fifo.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Fails if any instance port in [sv] is left unconnected, e.g. `.cti()`.
/// [instanceContains] narrows the check to the instantiation line that
/// contains this text, such as a leaf module's instance name.
void expectNoEmptyPort(String sv, String instanceContains) {
  final line = sv.split('\n').firstWhere((l) => l.contains(instanceContains));
  final empty = RegExp(r'\.\w+\(\)').allMatches(line).map((m) => m.group(0));
  expect(empty, isEmpty, reason: 'empty port(s) in: $line');
}

Iterable<Module> _all(Module m) sync* {
  yield m;
  for (final s in m.subModules) {
    yield* _all(s);
  }
}

/// Elaboration smoke test: the [HarborDdr3] wrapper (memory port -> port
/// layer crossing -> burst adapter -> Ddr3Controller -> Ddr3Phy -> pads)
/// builds and generates SystemVerilog with no undriven signals / width
/// mismatches.
void main() {
  tearDown(() async => Simulator.reset());

  test('HarborDdr3 elaborates and generates SV', () async {
    const config = HarborDdrConfig(
      type: HarborDdrType.ddr3,
      size: 256 * 1024 * 1024,
      dataWidth: 16,
      frequency: 300000000,
      banks: 8,
      rowWidth: 14,
      colWidth: 10,
      casLatency: 5,
    );
    final ddr = HarborDdr3(
      config: config,
      baseAddress: 0x80000000,
      clockHz: 75000000,
      busAddressWidth: 25,
      busDataWidth: 32,
      ckPeriodPs: 3333,
    );
    await ddr.build();
    final sv = ddr.generateSynth();
    expect(sv, contains('module HarborDdr3'));
    expect(sv, contains('sdram_dq'));
    // The port layer crosses the memory waist, the device has no bridge.
    expect(sv, contains('HarborMemoryWaistCdcSlave'));
    expect(_all(ddr).whereType<HarborWishboneCdcFifoBridge>(), isEmpty);

    // A Wishbone port keeps the burst adapter, which resets with the device
    // side of the crossing, so a bus-side reset reaches both.
    final adapter = ddr.subModules.whereType<Ddr3BurstAdapter>().single;
    expect(adapter.input('reset').srcConnection, same(ddr.bus.reset));
    expect(ddr.subModules.whereType<Ddr3MemoryPort>(), isEmpty);
  });

  for (final kind in HarborFabricKind.values) {
    for (final rt in [false, true]) {
      test('Arty S7 ${kind.name} train=${rt ? 'runtime' : 'hw'} elaborates '
          'with the crossing in the port layer', () async {
        final ddr = HarborDdr3(
          config: const HarborDdrConfig.artyS7(),
          baseAddress: 0x80000000,
          clockHz: 75000000,
          busAddressWidth: 28,
          busDataWidth: 32,
          runtimeTrainable: rt,
          protocol: kind,
          target: const HarborFpgaTarget.spartan7(
            device: 's50',
            package: 'csga324',
          ),
        );
        await ddr.build();
        final sv = ddr.generateSynth();
        expect(sv, contains('sdram_dq'));
        expect(ddr.bus.kind, kind);
        final n = HarborDdr3.defaultOutstanding(kind);
        expect(ddr.outstanding, n);
        expect(ddr.bus.cdcDepth, harborCdcDepth(n));
        expect(ddr.definitionName, contains('_${kind.name}_'));
        final wb = kind == HarborFabricKind.wishbone;
        expect(
          ddr.definitionName,
          contains(wb ? '_n1_q4_b8' : '_n${n}_c1_q${harborCdcDepth(n)}'),
        );
        expect(
          ddr.subModules.whereType<Ddr3MemoryPort>(),
          wb ? isEmpty : hasLength(1),
        );
        expect(ddr.controller!.minReadGap, wb ? 0 : 1);
        final names = {for (final m in _all(ddr)) m.definitionName};
        expect(
          names.where((n) => n.startsWith('HarborMemoryWaistCdcSlave')),
          hasLength(1),
        );
        // Only the train port crosses through a register bridge.
        final bridges = _all(ddr).whereType<HarborWishboneCdcFifoBridge>();
        expect(bridges.map((b) => b.name), rt ? ['train_cdc'] : isEmpty);
        expect(ddr.trainBus?.cdcDepth, rt ? 2 : null);
      });
    }
  }

  test('two read channels on AXI4 cross each port once', () async {
    final ddr = _arty(HarborFabricKind.axi4, readChannels: 2, outstanding: 4);
    await ddr.build();
    final sv = ddr.generateSynth();
    expect(ddr.readBuses, hasLength(1));
    expect(ddr.interface('bus_r1').interface, isA<Axi4ReadOnlyInterface>());
    expect(sv, contains('bus_r1_ARVALID'));
    expect(sv, isNot(contains('bus_r1_AWVALID')));
    final names = [for (final m in _all(ddr)) m.definitionName];
    expect(
      names.where((n) => n.startsWith('HarborMemoryWaistCdcSlave')),
      hasLength(2),
    );
    expect(ddr.subModules.whereType<Ddr3MemoryPort>().single.readChannels, 2);
    expect(ddr.definitionName, contains('_n4_c2_'));
  });

  for (final kind in [HarborFabricKind.wishbone, HarborFabricKind.tilelink]) {
    test('two read channels on ${kind.name} throw', () {
      expect(
        () => _arty(kind, readChannels: 2),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('AXI4'),
          ),
        ),
      );
    });
  }

  test('a Wishbone port takes one request and keeps writeCombine', () {
    expect(
      () => _arty(HarborFabricKind.wishbone, outstanding: 4),
      throwsArgumentError,
    );
    expect(
      () => HarborDdr3(
        config: const HarborDdrConfig.artyS7(),
        baseAddress: 0,
        clockHz: 75000000,
        protocol: HarborFabricKind.axi4,
        writeCombine: true,
      ),
      throwsArgumentError,
    );
    final wc = HarborDdr3(
      config: const HarborDdrConfig.artyS7(),
      baseAddress: 0,
      clockHz: 75000000,
      writeCombine: true,
    );
    expect(wc.definitionName, contains('_wc_'));
  });

  test('fastSim needs a Xilinx target', () {
    for (final target in [
      const HarborSimTarget(),
      const HarborFpgaTarget.ecp5(device: 'LFE5U-25F', package: 'CSFBGA285'),
    ]) {
      expect(
        () => HarborDdr3(
          config: const HarborDdrConfig.orangeCrab(),
          baseAddress: 0,
          clockHz: 48000000,
          target: target,
          fastSim: true,
        ),
        throwsArgumentError,
      );
    }
  });

  test('fastSim puts the PHY boundary on ports and has no pads', () async {
    final ddr = HarborDdr3(
      config: const HarborDdrConfig.ax7203(),
      baseAddress: 0,
      clockHz: 100000000,
      busAddressWidth: 32,
      ckPeriodPs: 2500,
      protocol: HarborFabricKind.axi4,
      readChannels: 2,
      fastSim: true,
      target: const HarborFpgaTarget.artix7(
        device: 'xc7a200t',
        package: 'fbg484',
      ),
    );
    await ddr.build();
    expect(ddr.output('phy_data').width, 256);
    expect(ddr.input('phy_iserdes_data').width, 256);
    expect(ddr.tryOutput('sdram_cke'), isNull);
    expect(ddr.controller!.skipCalibration, isTrue);
  });

  test('definitionName changes with every body parameter', () {
    final base = _arty(HarborFabricKind.axi4);
    final variants = <String, HarborDdr3>{
      'readChannels': _arty(HarborFabricKind.axi4, readChannels: 2),
      'outstanding': _arty(HarborFabricKind.axi4, outstanding: 4),
      'readWords': _arty(HarborFabricKind.axi4, readWords: 8),
      'idWidth': _arty(HarborFabricKind.axi4, idWidth: 3),
      'runtimeTrainable': _arty(HarborFabricKind.axi4, rt: true),
      'ckPeriodPs': _arty(HarborFabricKind.axi4, ck: 3000),
      'busDataWidth': _arty(HarborFabricKind.axi4, dataWidth: 64),
      'protocol': _arty(HarborFabricKind.tilelink),
      'config': _arty(
        HarborFabricKind.axi4,
        config: const HarborDdrConfig.ax7203(),
        addressWidth: 30,
      ),
      'fastSim': _arty(HarborFabricKind.axi4, fastSim: true),
      'readGap': _arty(HarborFabricKind.axi4, readGap: 0),
      'himbaechel': _arty(HarborFabricKind.axi4, himbaechel: true),
    };
    final names = {base.definitionName};
    for (final MapEntry(:key, :value) in variants.entries) {
      expect(names.add(value.definitionName), isTrue, reason: key);
    }
  });

  test('a sim target with two read channels serves both ports', () async {
    final ddr = HarborDdr3(
      config: const HarborDdrConfig.artyS7(),
      baseAddress: 0x80000000,
      clockHz: 75000000,
      busAddressWidth: 28,
      target: const HarborSimTarget(),
      protocol: HarborFabricKind.axi4,
      readChannels: 2,
    );
    await ddr.build();
    final sv = ddr.generateSynth();
    expect(sv, contains('harbor_sim_dram'));
    expectNoEmptyPort(sv, 'sim_dram(');
  });

  test('a sim target has no crossing', () async {
    final ddr = HarborDdr3(
      config: const HarborDdrConfig.orangeCrab(),
      baseAddress: 0x40000000,
      clockHz: 48000000,
      busAddressWidth: 27,
      target: const HarborSimTarget(),
      protocol: HarborFabricKind.axi4,
    );
    await ddr.build();
    expect(ddr.bus.cdcDepth, 0);
    expect(ddr.definitionName, contains('_sim_'));
    expect(ddr.definitionName, contains('_q0'));
  });

  test('sim-mode HarborDdr3 drives every HarborSimDram port', () async {
    const config = HarborDdrConfig(
      type: HarborDdrType.ddr3,
      size: 128 * 1024 * 1024,
      dataWidth: 16,
      frequency: 300000000,
      banks: 8,
      rowWidth: 14,
      colWidth: 10,
      casLatency: 5,
    );
    final ddr = HarborDdr3(
      config: config,
      baseAddress: 0x80000000,
      clockHz: 75000000,
      busAddressWidth: 25,
      busDataWidth: 32,
      ckPeriodPs: 3333,
      target: const HarborSimTarget(),
    );
    await ddr.build();
    final sv = ddr.generateSynth();
    expect(sv, contains('harbor_sim_dram'));
    expectNoEmptyPort(sv, 'sim_dram(');
  });
}

HarborDdr3 _arty(
  HarborFabricKind kind, {
  int readChannels = 1,
  int? outstanding,
  int readWords = 4,
  int idWidth = 1,
  bool rt = false,
  int ck = 3333,
  int dataWidth = 32,
  int addressWidth = 28,
  bool fastSim = false,
  int readGap = 1,
  bool himbaechel = false,
  HarborDdrConfig config = const HarborDdrConfig.artyS7(),
}) => HarborDdr3(
  config: config,
  baseAddress: 0x80000000,
  clockHz: 75000000,
  busAddressWidth: addressWidth,
  busDataWidth: dataWidth,
  ckPeriodPs: ck,
  runtimeTrainable: rt,
  protocol: kind,
  idWidth: idWidth,
  readChannels: readChannels,
  outstanding: outstanding,
  readWords: readWords,
  fastSim: fastSim,
  readGap: readGap,
  target: HarborFpgaTarget.spartan7(
    device: 's50',
    package: 'csga324',
    useHimbaechel: himbaechel,
  ),
);
