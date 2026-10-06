import 'dart:async';
import 'package:harbor/harbor.dart';
import 'package:harbor/src/bus/wishbone/wishbone_register_stage.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());
  const config = WishboneConfig(addressWidth: 32, dataWidth: 32, useErr: true);

  test(
    'register stage completes ERR-only once and clears it on reset',
    () async {
      final dut = WishboneRegisterStage(config: config);
      final clk = SimpleClockGenerator(10).clk;
      for (final input in dut.inputs.values) {
        if (input.name != 'clk') input.srcConnection!.put(0);
      }
      dut.input('clk').srcConnection! <= clk;
      void drive(String name, int value) =>
          dut.input(name).srcConnection!.inject(value);
      await dut.build();
      drive('reset', 1);
      Simulator.setMaxSimTime(1000);
      unawaited(Simulator.run());
      await clk.nextNegedge;
      expect(dut.output('up_ERR').value.toInt(), 0);
      drive('reset', 0);
      drive('up_CYC', 1);
      drive('up_STB', 1);
      await clk.nextNegedge;
      expect(dut.output('down_CYC').value.toInt(), 1);
      drive('down_ERR', 1);
      await clk.nextNegedge;
      expect(dut.output('up_ERR').value.toInt(), 1);
      expect(dut.output('up_ACK').value.toInt(), 0);
      expect(dut.output('down_CYC').value.toInt(), 0);
      await clk.nextNegedge;
      expect(dut.output('up_ERR').value.toInt(), 0);
      expect(dut.output('down_CYC').value.toInt(), 0);
      drive('up_CYC', 0);
      drive('up_STB', 0);
      drive('down_ERR', 0);
      await Simulator.endSimulation();
    },
  );

  test('decoder forwards only the selected active slave error', () async {
    final dut = WishboneDecoder(config, [
      for (var i = 0; i < 2; i++)
        HarborAddressMapping(
          range: BusAddressRange(i * 4096, 4096),
          slaveIndex: i,
        ),
    ]);
    for (final input in dut.inputs.values) {
      input.srcConnection!.put(0);
    }
    await dut.build();
    void drive(String name, int value) =>
        dut.input(name).srcConnection!.put(value);
    drive('master_CYC', 1);
    drive('master_STB', 1);
    drive('slave_1_ERR', 1);
    expect(dut.output('master_ERR').value.toInt(), 0);
    drive('master_ADR', 4096);
    expect(dut.output('master_ERR').value.toInt(), 1);
    expect(dut.output('master_ACK').value.toInt(), 0);
    drive('slave_1_ERR', 0);
    drive('slave_1_ACK', 1);
    expect(dut.output('master_ERR').value.toInt(), 0);
    expect(dut.output('master_ACK').value.toInt(), 1);
    drive('slave_1_ERR', 1);
    drive('master_STB', 0);
    expect(dut.output('master_ERR').value.toInt(), 0);
    drive('master_STB', 1);
    drive('master_ADR', 8192);
    expect(dut.output('master_ERR').value.toInt(), 1);
    drive('master_CYC', 0);
    expect(dut.output('master_ERR').value.toInt(), 0);
  });

  test(
    'arbiter routes an error only to the granted requesting master',
    () async {
      final dut = WishboneArbiter(
        numMasters: 2,
        config: config,
        arbitration: BusArbitration.fixed,
      );
      for (final input in dut.inputs.values) {
        input.srcConnection!.put(0);
      }
      final clk = SimpleClockGenerator(10).clk;
      dut.input('clk').srcConnection! <= clk;
      await dut.build();
      void drive(String name, int value) =>
          dut.input(name).srcConnection!.inject(value);
      drive('reset', 1);
      Simulator.setMaxSimTime(1000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextNegedge;
      drive('reset', 0);
      drive('slave_ERR', 1);
      for (var owner = 0; owner < 2; owner++) {
        drive('master_${owner}_CYC', 1);
        drive('master_${owner}_STB', 1);
        await clk.nextNegedge;
        expect(dut.output('master_${owner}_ERR').value.toInt(), 1);
        expect(dut.output('master_${1 - owner}_ERR').value.toInt(), 0);
        drive('master_${owner}_STB', 0);
        await clk.nextNegedge;
        expect(dut.output('master_${owner}_ERR').value.toInt(), 0);
        drive('master_${owner}_CYC', 0);
      }
      await Simulator.endSimulation();
    },
  );
}
