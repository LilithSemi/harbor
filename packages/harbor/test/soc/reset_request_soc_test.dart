// A module in the SoC can request a reset of the logic of every domain. The
// SoC stretches the request on the board clock.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

const _gpio = 0x10001000;
const _reset = 0x10005000;
const _output = 0x08;
const _hold = HarborSoC.resetRequestHoldCycles;

class _Cpu extends BridgeModule {
  _Cpu() : super('ResetRequestCpu', name: 'cpu') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final i = addInterface(
      WishboneInterface(
        const WishboneConfig(addressWidth: 32, dataWidth: 32, useErr: true),
      ),
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

  void pullUp(HarborSoC soc) {
    for (final n in [...inputs.keys, ...outputs.keys]) {
      if (!n.startsWith('p_')) continue;
      soc.pullUpPort(port(n), newPortName: 'cpu_${n.substring(2)}');
    }
  }
}

HarborGpio _newGpio() => HarborGpio(
  baseAddress: _gpio,
  pinCount: 8,
  busAddressWidth: 32,
  name: 'gpio',
);

/// Counts the [clk] cycles that [reset] is high, until it stays low for 64
/// cycles or [limit] cycles go by.
Future<int> _held(Logic clk, Logic reset, {int limit = 4 * _hold}) async {
  var held = 0;
  var low = 0;
  for (var i = 0; i < limit && low < 64; i++) {
    await clk.nextPosedge;
    if (reset.value.toInt() == 1) {
      held++;
      low = 0;
    } else if (held > 0) {
      low++;
    }
  }
  return held;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('a one-cycle request holds a slow domain for the full hold', () async {
    final request = Logic(name: 'request');
    final soc = HarborSoC(
      name: 'reset_request_slow',
      compatible: 'test,reset-request',
      resetRequest: request,
      target: const HarborSimTarget(frequency: 100000000),
    );
    soc.createPort('go', PortDirection.input);
    request <= soc.input('go');
    final slowIn = soc.addInput('slow_clk', Logic());
    final slow = soc.addClockDomainFromNet(
      HarborClockConfig.fixed(name: 'slow', frequency: 12500000),
      slowIn,
      locked: soc.addInput('slow_locked', Logic()),
    );

    final clk = SimpleClockGenerator(10).clk;
    final slowClk = SimpleClockGenerator(80).clk;
    final reset = Logic(name: 'reset')..inject(1);
    final go = Logic(name: 'go')..inject(0);
    soc.input('clk').srcConnection! <= clk;
    soc.input('reset').srcConnection! <= reset;
    soc.input('go').srcConnection! <= go;
    soc.input('slow_clk').srcConnection! <= slowClk;
    soc.input('slow_locked').srcConnection! <= Const(1);
    await soc.build();
    Simulator.setMaxSimTime(1000000);
    unawaited(Simulator.run());

    for (var i = 0; i < 8; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    for (var i = 0; i < 40; i++) {
      await clk.nextPosedge;
    }
    expect(slow.reset.value.toInt(), 0);
    expect(soc.hardReset.value.toInt(), 0);

    go.inject(1);
    await clk.nextPosedge;
    go.inject(0);
    final hardSeen = <int>{};
    final watch = clk.posedge.listen(
      (_) => hardSeen.add(soc.hardReset.value.toInt()),
    );
    expect(await _held(clk, slow.reset), greaterThanOrEqualTo(_hold));
    await watch.cancel();
    expect(hardSeen, {0});
    expect(slow.reset.value.toInt(), 0);
    await Simulator.endSimulation();
  });

  test(
    'hardReset asserts at once and releases after two board clocks',
    () async {
      final soc = HarborSoC(
        name: 'reset_request_hard',
        compatible: 'test,reset-request',
        target: const HarborSimTarget(frequency: 100000000),
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset')..inject(1);
      soc.input('clk').srcConnection! <= clk;
      soc.input('reset').srcConnection! <= reset;
      await soc.build();
      Simulator.setMaxSimTime(100000);
      unawaited(Simulator.run());

      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
      }
      expect(soc.hardReset.value.toInt(), 1);
      await clk.nextNegedge;
      reset.inject(0);
      await clk.nextPosedge;
      await clk.nextNegedge;
      expect(soc.hardReset.value.toInt(), 1);
      await clk.nextPosedge;
      await clk.nextNegedge;
      expect(soc.hardReset.value.toInt(), 0);
      // It asserts between clock edges.
      final seen = Completer<int>();
      Simulator.registerAction(Simulator.time + 1, () => reset.put(1));
      Simulator.registerAction(
        Simulator.time + 2,
        () => seen.complete(soc.hardReset.value.toInt()),
      );
      expect(await seen.future, 1);
      await Simulator.endSimulation();
    },
  );

  for (final fpga in [false, true]) {
    final name = fpga ? 'the FPGA power-on reset with soft reset' : 'a pin';
    test('a GPIO that its own request clears still gets the full hold, '
        '$name', () async {
      final request = Logic(name: 'request');
      final soc = HarborSoC(
        name: 'reset_request_gpio_${fpga ? 'por' : 'pin'}',
        compatible: 'test,reset-request',
        resetRequest: request,
        softReset: fpga,
        target: fpga
            ? const HarborFpgaTarget.ecp5(
                device: 'LFE5U-85F',
                package: 'CABGA381',
                frequency: 50000000,
              )
            : const HarborSimTarget(frequency: 50000000),
        clocks: [
          HarborClockConfig.fixed(
            name: 'sys',
            frequency: 50000000,
            sourceFrequency: 50000000,
            isPrimary: true,
          ),
        ],
      );
      final cpu = soc.addMaster(_Cpu());
      final gpio = soc.addPeripheral(_newGpio());
      if (fpga) {
        soc.addResetController(HarborResetController(baseAddress: _reset));
      }
      request <= gpio.gpioOut[0];
      cpu.pullUp(soc);
      soc.buildFabric();

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset')..inject(1);
      soc.input('clk').srcConnection! <= clk;
      if (!fpga) soc.input('reset').srcConnection! <= reset;
      gpio.input('gpio_in').srcConnection! <= Const(0, width: 8);
      final bus = RegBus.attach(
        soc,
        clk,
        name: 'cpu',
        kind: HarborFabricKind.wishbone,
      );
      await soc.build();
      bus.idle();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());
      final sys = soc.clockDomain('sys')!.reset;
      // The power-on counter has no reset. An FPGA starts it at 0.
      if (fpga) {
        await clk.nextNegedge;
        soc.signals.firstWhere((s) => s.name == 'porCount').put(0);
      }
      for (var i = 0; i < 8; i++) {
        await clk.nextPosedge;
      }
      reset.inject(0);
      // The power-on reset and the hold of the reset controller end.
      for (var i = 0; i < 600; i++) {
        await clk.nextPosedge;
      }
      expect(sys.value.toInt(), 0);

      await bus.write(_gpio + _output, 0x80);
      expect(gpio.gpioOut.value.toInt(), 0x80);
      // The master resets with the SoC, so the response never comes.
      bus.timeout = 30;
      final count = _held(clk, sys);
      await bus.write(_gpio + _output, 0x81).then((_) {}, onError: (_) {});
      bus.timeout = 10000;
      expect(await count, greaterThanOrEqualTo(_hold));
      // The GPIO register cleared, so the request is low.
      expect(gpio.gpioOut.value.toInt(), 0);
      expect(sys.value.toInt(), 0);
      bus.idle();
      await bus.write(_gpio + _output, 0x40);
      expect(gpio.gpioOut.value.toInt(), 0x40);
      await Simulator.endSimulation();
    });
  }
}
