// A module in the SoC can request a reset of the whole SoC.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

/// Holds its request for [cycles] after a pulse on `go`, like a PCIe reset
/// monitor. Its own reset is the SoC hard reset.
class _Requester extends BridgeModule {
  Logic get request => output('request');

  _Requester({
    required Logic clk,
    required Logic reset,
    required Logic go,
    required int cycles,
  }) : super('ResetRequester') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    go = addInput('go', go);
    final left = Logic(name: 'left', width: cycles.bitLength);
    Sequential(clk, reset: reset, [
      If(
        go,
        then: [left < cycles],
        orElse: [
          If(left.neq(0), then: [left < left - 1]),
        ],
      ),
    ]);
    addOutput('request') <= left.neq(0);
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('a reset request resets the SoC and not the hard reset', () async {
    final request = Logic(name: 'request');
    final soc = HarborSoC(
      name: 'reset_request',
      compatible: 'test,reset-request',
      resetRequest: request,
      target: const HarborSimTarget(frequency: 50000000),
      clocks: [
        HarborClockConfig.fixed(
          name: 'sys',
          frequency: 50000000,
          sourceFrequency: 50000000,
          isPrimary: true,
        ),
      ],
    );
    soc.createPort('go', PortDirection.input);
    final requester = _Requester(
      clk: soc.boardClk,
      reset: soc.hardReset,
      go: soc.input('go'),
      cycles: 16,
    );
    soc.addSubModule(requester);
    request <= requester.request;
    final gpio = soc.addPeripheral(
      HarborGpio(
        baseAddress: 0x10001000,
        pinCount: 8,
        busAddressWidth: 32,
        name: 'gpio',
      ),
    );
    soc.buildFabric();

    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset')..inject(1);
    final go = Logic(name: 'go')..inject(0);
    soc.input('clk').srcConnection! <= clk;
    soc.input('reset').srcConnection! <= reset;
    soc.input('go').srcConnection! <= go;
    gpio.input('gpio_in').srcConnection! <= Const(0, width: 8);
    await soc.build();
    Simulator.setMaxSimTime(100000);
    unawaited(Simulator.run());

    final sysReset = soc.clockDomain('sys')!.reset;
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    for (var i = 0; i < 8; i++) {
      await clk.nextPosedge;
    }
    expect(sysReset.value.toInt(), 0);
    expect(soc.hardReset.value.toInt(), 0);

    go.inject(1);
    await clk.nextPosedge;
    go.inject(0);
    var held = 0;
    for (var i = 0; i < 40; i++) {
      await clk.nextPosedge;
      if (sysReset.value.toInt() == 1) held++;
      expect(soc.hardReset.value.toInt(), 0);
    }
    // The request is not cleared by the reset it makes.
    expect(held, greaterThanOrEqualTo(16));
    expect(sysReset.value.toInt(), 0);
    await Simulator.endSimulation();
  });
}
