// A write of 0xDEAD to SW_RST_KEY resets the whole SoC through the soft reset
// the reset controller adds to the SoC reset.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

const _reset = 0x10005000;
const _gpio = 0x10001000;
const _wdog = 0x10006000;
const _output = 0x08;

class _Cpu extends BridgeModule {
  _Cpu(HarborFabricKind kind) : super('ResetCpu_${kind.name}', name: 'cpu') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final PairInterface intf = switch (kind) {
      HarborFabricKind.wishbone => WishboneInterface(
        const WishboneConfig(addressWidth: 32, dataWidth: 32, useErr: true),
      ),
      HarborFabricKind.axi4 => Axi4LiteInterface(
        addressWidth: 32,
        dataWidth: 32,
      ),
      HarborFabricKind.tilelink => TileLinkInterface(
        const TileLinkConfig(addressWidth: 32, dataWidth: 32),
      ),
    };
    final i = addInterface(
      intf,
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

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  for (final kind in HarborFabricKind.values) {
    test('${kind.name}: SW_RST_KEY resets the SoC and releases it', () async {
      final soc = HarborSoC(
        name: 'soft_${kind.name}',
        compatible: 'test,soft',
        fabricKind: kind,
        softReset: true,
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
      final cpu = soc.addMaster(_Cpu(kind));
      final gpio = soc.addPeripheral(
        HarborGpio(
          baseAddress: _gpio,
          pinCount: 32,
          busAddressWidth: 32,
          fabricKind: kind,
          name: 'gpio',
        ),
      );
      final rc = soc.addResetController(
        HarborResetController(baseAddress: _reset, fabricKind: kind),
      );
      cpu.pullUp(soc);
      soc.buildFabric();

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset')..inject(1);
      soc.input('clk').srcConnection! <= clk;
      soc.input('reset').srcConnection! <= reset;
      gpio.input('gpio_in').srcConnection! <= Const(0, width: 32);
      final bus = RegBus.attach(soc, clk, name: 'cpu', kind: kind);
      await soc.build();
      bus.idle();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());
      for (var i = 0; i < 8; i++) {
        await clk.nextPosedge;
      }
      reset.inject(0);
      for (var i = 0; i < 300; i++) {
        await clk.nextPosedge;
      }

      await bus.write(_gpio + _output, 0x1234);
      expect(gpio.gpioOut.value.toInt(), 0x1234);
      // A write of another key does nothing.
      await bus.write(_reset + 0x30, 0xbeef);
      await clk.nextPosedge;
      expect(rc.systemReset.value.toInt(), 0);
      expect(gpio.gpioOut.value.toInt(), 0x1234);

      var held = 0;
      final count = clk.posedge.listen((_) {
        if (rc.systemReset.value.toInt() == 1) held++;
      });
      // The master resets with the SoC, so the response never comes.
      bus.timeout = 30;
      await bus.write(_reset + 0x30, 0xdead).then((_) {}, onError: (_) {});
      bus.timeout = 10000;
      for (var i = 0; i < 400; i++) {
        await clk.nextPosedge;
      }
      await count.cancel();
      expect(held, greaterThanOrEqualTo(256));
      expect(held, lessThan(300));
      expect(rc.systemReset.value.toInt(), 0);
      // The peripheral lost its state, and the bus works again.
      expect(gpio.gpioOut.value.toInt(), 0);
      await bus.write(_gpio + _output, 0x55);
      expect(await bus.read(_gpio + _output), 0x55);
      // The controller kept its cause: software.
      expect(
        await bus.read(_reset + 0x08) & 7,
        HarborResetSource.software.index,
      );
      await Simulator.endSimulation();
    });
  }

  for (final kind in HarborFabricKind.values) {
    test('${kind.name}: a watchdog expiry resets the SoC with no reset '
        'controller write', () async {
      final soc = HarborSoC(
        name: 'wdt_${kind.name}',
        compatible: 'test,wdt',
        fabricKind: kind,
        softReset: true,
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
      final cpu = soc.addMaster(_Cpu(kind));
      final gpio = soc.addPeripheral(
        HarborGpio(
          baseAddress: _gpio,
          pinCount: 32,
          busAddressWidth: 32,
          fabricKind: kind,
          name: 'gpio',
        ),
      );
      final wdt = soc.addPeripheral(
        HarborWatchdog(baseAddress: _wdog, fabricKind: kind),
      );
      final rc = soc.addResetController(
        HarborResetController(baseAddress: _reset, fabricKind: kind),
        watchdog: wdt.resetOut,
      );
      cpu.pullUp(soc);
      soc.buildFabric();

      expect(wdt.dtNode.properties['clock-frequency'], 50000000);
      expect(
        RegExp(
          r'harbor,watchdog[^}]*clock-frequency = <(0x2faf080|50000000)>',
        ).hasMatch(soc.generateDts()),
        isTrue,
      );

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset')..inject(1);
      soc.input('clk').srcConnection! <= clk;
      soc.input('reset').srcConnection! <= reset;
      gpio.input('gpio_in').srcConnection! <= Const(0, width: 32);
      final bus = RegBus.attach(soc, clk, name: 'cpu', kind: kind);
      await soc.build();
      bus.idle();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());
      for (var i = 0; i < 8; i++) {
        await clk.nextPosedge;
      }
      reset.inject(0);
      for (var i = 0; i < 300; i++) {
        await clk.nextPosedge;
      }

      expect(await bus.read(_reset + 0x28), 1);
      await bus.write(_gpio + _output, 0x1234);
      expect(gpio.gpioOut.value.toInt(), 0x1234);

      // Arm the watchdog: 200 cycles, enable and reset_en.
      await bus.write(_wdog + 0x10, 200);
      await bus.write(_wdog + 0x00, 0x03);
      bus.timeout = 30;
      var held = 0;
      final count = clk.posedge.listen((_) {
        if (rc.systemReset.value.toInt() == 1) held++;
      });
      for (var i = 0; i < 900; i++) {
        await clk.nextPosedge;
      }
      await count.cancel();
      bus.timeout = 10000;
      expect(held, greaterThanOrEqualTo(256));
      expect(rc.systemReset.value.toInt(), 0);
      expect(gpio.gpioOut.value.toInt(), 0);
      expect(
        await bus.read(_reset + 0x08) & 7,
        HarborResetSource.watchdog.index,
      );
      // The watchdog comes back disabled, and the enable stays 1.
      expect(await bus.read(_wdog + 0x00) & 1, 0);
      expect(await bus.read(_reset + 0x28), 1);
      await Simulator.endSimulation();
    });
  }

  for (final wired in [false, true]) {
    test('the WDOG_RST_EN reset value follows the wiring (watchdog '
        '${wired ? 'wired' : 'absent'})', () async {
      const kind = HarborFabricKind.wishbone;
      final soc = HarborSoC(
        name: 'wdt_wired_$wired',
        compatible: 'test,wdt',
        fabricKind: kind,
        softReset: true,
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
      final cpu = soc.addMaster(_Cpu(kind));
      final wdt = wired
          ? soc.addPeripheral(HarborWatchdog(baseAddress: _wdog))
          : null;
      soc.addResetController(
        HarborResetController(baseAddress: _reset),
        watchdog: wdt?.resetOut,
      );
      cpu.pullUp(soc);
      soc.buildFabric();

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset')..inject(1);
      soc.input('clk').srcConnection! <= clk;
      soc.input('reset').srcConnection! <= reset;
      final bus = RegBus.attach(soc, clk, name: 'cpu', kind: kind);
      await soc.build();
      bus.idle();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());
      for (var i = 0; i < 8; i++) {
        await clk.nextPosedge;
      }
      reset.inject(0);
      for (var i = 0; i < 300; i++) {
        await clk.nextPosedge;
      }
      expect(await bus.read(_reset + 0x28), wired ? 1 : 0);
      await Simulator.endSimulation();
    });
  }

  test(
    'a controller added through addPeripheral reads WDOG_RST_EN 0',
    () async {
      const kind = HarborFabricKind.wishbone;
      final soc = HarborSoC(
        name: 'wdt_plain',
        compatible: 'test,wdt',
        fabricKind: kind,
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
      final cpu = soc.addMaster(_Cpu(kind));
      soc.addPeripheral(HarborResetController(baseAddress: _reset));
      cpu.pullUp(soc);
      soc.buildFabric();
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset')..inject(1);
      soc.input('clk').srcConnection! <= clk;
      soc.input('reset').srcConnection! <= reset;
      final bus = RegBus.attach(soc, clk, name: 'cpu', kind: kind);
      await soc.build();
      bus.idle();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());
      for (var i = 0; i < 8; i++) {
        await clk.nextPosedge;
      }
      reset.inject(0);
      for (var i = 0; i < 300; i++) {
        await clk.nextPosedge;
      }
      expect(await bus.read(_reset + 0x28), 0);
      await Simulator.endSimulation();
    },
  );

  test('a watchdog on another clock domain than the controller throws', () {
    final soc = HarborSoC(
      name: 'wdt_cross',
      compatible: 'test,wdt',
      softReset: true,
      target: const HarborSimTarget(frequency: 50000000),
      clocks: [
        HarborClockConfig.fixed(
          name: 'ref',
          frequency: 50000000,
          sourceFrequency: 50000000,
          isPrimary: true,
        ),
        HarborClockConfig.fixed(
          name: 'sys',
          frequency: 25000000,
          sourceFrequency: 50000000,
        ),
      ],
    );
    final wdt = soc.addPeripheral(
      HarborWatchdog(baseAddress: _wdog, crossFabricClock: true),
      clockDomainName: 'ref',
    );
    expect(
      () => soc.addResetController(
        HarborResetController(baseAddress: _reset),
        clockDomainName: 'sys',
        watchdog: wdt.resetOut,
      ),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message.toString(),
          'message',
          contains('different clock domains'),
        ),
      ),
    );
  });

  test('a controller on a derived clock domain holds the reset for its hold '
      'time in that clock, and a reset pin reads as external', () async {
    const kind = HarborFabricKind.axi4;
    final soc = HarborSoC(
      name: 'soft_derived',
      compatible: 'test,soft',
      fabricKind: kind,
      softReset: true,
      target: const HarborSimTarget(frequency: 50000000),
      clocks: [
        HarborClockConfig.fixed(
          name: 'ref',
          frequency: 50000000,
          sourceFrequency: 50000000,
          isPrimary: true,
        ),
        HarborClockConfig.fixed(
          name: 'sys',
          frequency: 25000000,
          sourceFrequency: 50000000,
        ),
      ],
    );
    final cpu = soc.addMaster(_Cpu(kind));
    final gpio = soc.addPeripheral(
      HarborGpio(
        baseAddress: _gpio,
        pinCount: 32,
        busAddressWidth: 32,
        fabricKind: kind,
        name: 'gpio',
      ),
    );
    final crossed = soc.addPeripheral(
      HarborGpio(
        baseAddress: 0x10003000,
        pinCount: 32,
        busAddressWidth: 32,
        fabricKind: kind,
        crossFabricClock: true,
        name: 'gpio_c',
      ),
      clockDomainName: 'ref',
    );
    final rc = soc.addResetController(
      HarborResetController(baseAddress: _reset, fabricKind: kind),
      clockDomainName: 'sys',
    );
    cpu.pullUp(soc);
    soc.buildFabric();

    final clk = SimpleClockGenerator(10).clk;
    final sysClk = SimpleClockGenerator(20).clk;
    final reset = Logic(name: 'reset')..inject(1);
    soc.input('clk').srcConnection! <= clk;
    soc.input('sys_clk').srcConnection! <= sysClk;
    soc.input('reset').srcConnection! <= reset;
    gpio.input('gpio_in').srcConnection! <= Const(0, width: 32);
    crossed.input('gpio_in').srcConnection! <= Const(0, width: 32);
    final bus = RegBus.attach(soc, sysClk, name: 'cpu', kind: kind);
    await soc.build();
    bus.idle();
    Simulator.setMaxSimTime(8000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 8; i++) {
      await sysClk.nextPosedge;
    }
    reset.inject(0);
    for (var i = 0; i < 300; i++) {
      await sysClk.nextPosedge;
    }

    await bus.write(_gpio + _output, 0x1234);
    expect(gpio.gpioOut.value.toInt(), 0x1234);
    await bus.write(0x10003000 + _output, 0x77);
    expect(crossed.gpioOut.value.toInt(), 0x77);
    var held = 0;
    final count = sysClk.posedge.listen((_) {
      if (rc.systemReset.value.toInt() == 1) held++;
    });
    bus.timeout = 30;
    await bus.write(_reset + 0x30, 0xdead).then((_) {}, onError: (_) {});
    bus.timeout = 10000;
    for (var i = 0; i < 400; i++) {
      await sysClk.nextPosedge;
    }
    await count.cancel();
    expect(held, greaterThanOrEqualTo(256));
    expect(held, lessThan(300));
    expect(gpio.gpioOut.value.toInt(), 0);
    // Both sides of the crossing reset, and it works again.
    expect(crossed.gpioOut.value.toInt(), 0);
    await bus.write(0x10003000 + _output, 0x78);
    expect(await bus.read(0x10003000 + _output), 0x78);
    expect(await bus.read(_reset + 0x08) & 7, HarborResetSource.software.index);

    // A write below the least hold time sets the least.
    await bus.write(_reset + 0x10, 0);
    expect(await bus.read(_reset + 0x10), 16);
    await bus.write(_reset + 0x10, 300);
    expect(await bus.read(_reset + 0x10), 300);

    // The reset pin reads as an external reset.
    reset.inject(1);
    for (var i = 0; i < 12; i++) {
      await sysClk.nextPosedge;
    }
    reset.inject(0);
    for (var i = 0; i < 700; i++) {
      await sysClk.nextPosedge;
    }
    expect(
      await bus.read(_reset + 0x08) & 7,
      HarborResetSource.external_.index,
    );
    await Simulator.endSimulation();
  });

  test('the controller hold time covers four edges of the slowest domain', () {
    HarborSoC kc705() => HarborSoC(
      name: 'soft_hold',
      compatible: 'test,soft',
      softReset: true,
      target: const HarborSimTarget(frequency: 200000000),
      clocks: [
        HarborClockConfig.fixed(
          name: 'sys',
          frequency: 200000000,
          sourceFrequency: 200000000,
          isPrimary: true,
        ),
        HarborClockConfig.fixed(
          name: 'pixel',
          frequency: 25000000,
          sourceFrequency: 200000000,
        ),
      ],
    );
    final soc = kc705();
    expect(soc.requiredResetHoldCycles(null), 32);
    expect(
      () => soc.addResetController(HarborResetController(baseAddress: _reset)),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message.toString(),
          'message',
          contains('minHoldCycles: 32'),
        ),
      ),
    );
    kc705().addResetController(
      HarborResetController(baseAddress: _reset, minHoldCycles: 32),
    );
    // The controller on the slowest domain needs 4 cycles.
    expect(kc705().requiredResetHoldCycles('pixel'), 4);
  });

  test('a slower domain added after the controller fails buildFabric', () {
    final soc = HarborSoC(
      name: 'soft_late',
      compatible: 'test,soft',
      softReset: true,
      target: const HarborSimTarget(frequency: 200000000),
      clocks: [
        HarborClockConfig.fixed(
          name: 'sys',
          frequency: 200000000,
          sourceFrequency: 200000000,
          isPrimary: true,
        ),
      ],
    );
    soc.addResetController(HarborResetController(baseAddress: _reset));
    soc.addClockDomain(
      HarborClockConfig.fixed(
        name: 'pixel',
        frequency: 25000000,
        sourceFrequency: 200000000,
      ),
    );
    expect(
      soc.buildFabric,
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message.toString(),
          'message',
          contains('minHoldCycles: 32'),
        ),
      ),
    );
  });

  test('a clock ratio over the hold cap names no minHoldCycles', () {
    final soc = HarborSoC(
      name: 'soft_cap',
      compatible: 'test,soft',
      softReset: true,
      target: const HarborSimTarget(frequency: 200000000),
      clocks: [
        HarborClockConfig.fixed(
          name: 'sys',
          frequency: 200000000,
          sourceFrequency: 200000000,
          isPrimary: true,
        ),
        HarborClockConfig.fixed(
          name: 'slow',
          frequency: 1000000,
          sourceFrequency: 200000000,
        ),
      ],
    );
    expect(soc.requiredResetHoldCycles(null), 800);
    expect(
      () => soc.addResetController(
        HarborResetController(baseAddress: _reset, minHoldCycles: 256),
      ),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message.toString(),
          'message',
          allOf(contains('No valid minHoldCycles'), isNot(contains(': 800'))),
        ),
      ),
    );
  });

  test('addResetController needs softReset', () {
    final soc = HarborSoC(name: 'soft_off', compatible: 'test,soft');
    expect(
      () => soc.addResetController(HarborResetController(baseAddress: _reset)),
      throwsStateError,
    );
  });

  test('the reset controller node is a syscon with a syscon-reboot child', () {
    final n = HarborResetController(baseAddress: _reset).dtNode;
    expect(n.compatible, containsAll(['harbor,reset-controller', 'syscon']));
    final c = n.children.single;
    expect(c.properties['compatible'], 'syscon-reboot');
    expect(c.properties['offset'], [0x30]);
    expect(c.properties['value'], [0xdead]);
    expect(c.properties['priority'], 128);
  });
}
