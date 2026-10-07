import 'package:harbor/src/peripherals/ddr3_config.dart'
    show HarborDdrConfig, HarborDdrType;
import 'package:harbor/src/peripherals/harbor_ddr3.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Elaboration smoke test: the [HarborDdr3] wrapper (bus -> CDC -> burst adapter
/// -> Ddr3Controller -> Ddr3Phy -> pads) builds and generates SystemVerilog with
/// no undriven signals / width mismatches.
void main() {
  tearDown(() async => Simulator.reset());

  test('HarborDdr3 elaborates and generates SV', () async {
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
    );
    await ddr.build();
    final sv = ddr.generateSynth();
    expect(sv, contains('module HarborDdr3'));
    expect(sv, contains('sdram_dq'));
    // internal stack present
    expect(sv, contains('ddr_cdc'));
  });
}
