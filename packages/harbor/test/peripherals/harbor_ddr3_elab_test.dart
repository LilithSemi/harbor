import 'package:harbor/harbor.dart';
import 'package:harbor/src/clock/wishbone_cdc_fifo.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Fails if any instance port in [sv] is left unconnected, e.g. `.cti()`.
/// [instanceContains] narrows the check to the instantiation line that
/// contains this text, such as a leaf module's instance name.
void expectNoEmptyPort(String sv, String instanceContains) {
  final line = sv
      .split('\n')
      .firstWhere((l) => l.contains(instanceContains));
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

    // The burst adapter resets with the device side of the crossing, so a
    // bus-side reset reaches both.
    final adapter = ddr.subModules.whereType<Ddr3BurstAdapter>().single;
    expect(adapter.input('reset').srcConnection, same(ddr.bus.reset));
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
        expect(ddr.bus.cdcDepth, 4);
        expect(ddr.definitionName, contains('_${kind.name}_'));
        expect(ddr.definitionName, contains('_n1_q4'));
        expect(ddr.definitionName, contains(rt ? '_rt' : '_g1_'));
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
