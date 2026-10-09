import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Elaboration checks for [HarborSdram]: the ecp5 build has the sdr sdram
/// phy cell counts and no Xilinx cell, the device tree node matches its
/// properties, the sim target builds `harbor_sim_dram` with no sdram_*
/// pads, and the target and clock guards throw.
void main() {
  tearDown(() async => Simulator.reset());

  const config = HarborSdramConfig.as4c16m16sb6();
  const ecp5Target = HarborFpgaTarget.ecp5(
    device: 'LFE5U-85F',
    package: 'CABGA381',
  );

  int count(String sv, String cell) =>
      RegExp('\\b$cell\\b').allMatches(sv).length;

  test('ecp5 target: full stack, phy cell counts, no xilinx cell', () async {
    final sdram = HarborSdram(
      config: config,
      baseAddress: 0x40000000,
      clockHz: 125000000,
      target: ecp5Target,
    );
    await sdram.build();
    final sv = sdram.generateSynth();

    expect(sv, contains('module HarborSdram'));
    expect(count(sv, 'OFS1P3BX'), equals(53));
    expect(count(sv, 'OFS1P3DX'), equals(1));
    expect(count(sv, 'IFS1P3BX'), equals(16));
    expect(count(sv, 'ODDRX1F'), equals(1));
    expect(count(sv, 'BB'), equals(16));
    expect(count(sv, 'IDDRX1F'), equals(0));

    for (final cell in [
      'OSERDESE2',
      'ISERDESE2',
      'IDELAYE2',
      'ODELAYE2',
      'IDELAYCTRL',
      'IOBUF',
      'IOBUFDS',
      'OBUF',
      'OBUFDS',
    ]) {
      expect(count(sv, cell), 0, reason: '$cell (xilinx) leaked in');
    }

    // Port names and widths.
    expect(sdram.output('sdram_clk').width, equals(1));
    expect(sdram.output('sdram_cke').width, equals(1));
    expect(sdram.output('sdram_cs_n').width, equals(1));
    expect(sdram.output('sdram_ras_n').width, equals(1));
    expect(sdram.output('sdram_cas_n').width, equals(1));
    expect(sdram.output('sdram_we_n').width, equals(1));
    expect(sdram.output('sdram_ba').width, equals(2));
    expect(sdram.output('sdram_addr').width, equals(13));
    expect(sdram.output('sdram_dqm').width, equals(2));
    expect(sdram.inOut('sdram_dq').width, equals(16));
    expect(sdram.output('init_done').width, equals(1));
    expect(sdram.output('bus_error').width, equals(1));
    expect(sdram.busError, equals(sdram.output('bus_error')));
  });

  test('device tree node fields', () async {
    final sdram = HarborSdram(
      config: config,
      baseAddress: 0x40000000,
      clockHz: 125000000,
      target: ecp5Target,
    );
    await sdram.build();

    final node = sdram.dtNode;
    expect(
      node.compatible,
      equals(['harbor,sdram-controller', 'harbor,sdr-sdram']),
    );
    expect(node.reg.start, equals(0x40000000));
    expect(node.reg.size, equals(config.sizeBytes));
    expect(node.properties['sdram-type'], equals('sdr'));
    expect(node.properties['data-width'], equals(16));
    expect(node.properties['clock-frequency'], equals(125000000));
    expect(node.properties['harbor,sdram-part'], equals(config.part));
    expect(node.properties['harbor,sdram-cas-latency'], equals(3));
    expect(node.properties['harbor,sdram-banks'], equals(4));
    expect(node.properties['harbor,sdram-rows'], equals(13));
    expect(node.properties['harbor,sdram-cols'], equals(9));
    expect(node.properties['harbor,sdram-address-map'], equals('row-bank-col'));

    expect(
      sdram.systemMemory,
      equals([BusAddressRange(0x40000000, config.sizeBytes)]),
    );
    expect(sdram.svdPeripheral.name, equals('SDRAM'));
    expect(sdram.svdPeripheral.baseAddress, equals(0x40000000));
    expect(sdram.acpiDevice.properties['sdram-type'], equals('sdr'));
  });

  test('HarborSimTarget: harbor_sim_dram with no sdram_* ports', () async {
    final sdram = HarborSdram(
      config: config,
      baseAddress: 0,
      clockHz: 125000000,
      target: const HarborSimTarget(topCell: 'top', frequency: 50000000),
    );
    await sdram.build();
    final sv = sdram.generateSynth();

    expect(sv, contains('harbor_sim_dram'));
    expect(() => sdram.output('sdram_clk'), throwsA(anything));
    expect(() => sdram.inOut('sdram_dq'), throwsA(anything));
    expect(() => sdram.output('init_done'), throwsA(anything));
    expect(sdram.busError.width, equals(1));
    expect(sdram.inputs.keys, isNot(contains('mem_clk')));
    expect(sdram.inputs.keys, isNot(contains('mem_reset')));
  });

  test('busClockSync keeps mem_reset and drops mem_clk', () async {
    final sdram = HarborSdram(
      config: config,
      baseAddress: 0,
      clockHz: 125000000,
      target: ecp5Target,
      busClockSync: true,
    );
    await sdram.build();
    expect(sdram.inputs.keys, contains('mem_reset'));
    expect(sdram.inputs.keys, isNot(contains('mem_clk')));
    expect(sdram.busError.width, equals(1));
  });

  test('a null target throws', () {
    expect(
      () => HarborSdram(config: config, baseAddress: 0, clockHz: 125000000),
      throwsArgumentError,
    );
  });

  test('an iCE40 target throws', () {
    expect(
      () => HarborSdram(
        config: config,
        baseAddress: 0,
        clockHz: 125000000,
        target: const HarborFpgaTarget.ice40(device: 'UP5K', package: 'SG48'),
      ),
      throwsArgumentError,
    );
  });

  test('175 MHz throws on ecp5 (ecp5 output limit is 150 MHz)', () {
    expect(
      () => HarborSdram(
        config: config,
        baseAddress: 0,
        clockHz: 175000000,
        target: ecp5Target,
      ),
      throwsArgumentError,
    );
  });
}
