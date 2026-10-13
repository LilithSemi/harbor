// A HarborSoC on each fabric kind: a CPU-side master driven from the test,
// register peripherals, an unmapped access, bus_error, and a peripheral on
// another clock that crosses to the fabric clock.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

const _output = 0x08;
const _irqEn = 0x18;

/// A master whose native port pins are plain `p_<PORT>` ports.
class _Cpu extends BridgeModule {
  _Cpu(HarborFabricKind kind, {bool useErr = true, String name = 'cpu'})
    : super('FabricCpu_${kind.name}${useErr ? '' : '_noerr'}', name: name) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final PairInterface intf = switch (kind) {
      HarborFabricKind.wishbone => WishboneInterface(
        WishboneConfig(addressWidth: 32, dataWidth: 32, useErr: useErr),
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

  /// Pulls every pin up to [soc] as `cpu_<PORT>`.
  void pullUp(HarborSoC soc) {
    for (final n in [...inputs.keys, ...outputs.keys]) {
      if (!n.startsWith('p_')) continue;
      soc.pullUpPort(port(n), newPortName: '${name}_${n.substring(2)}');
    }
  }
}

/// Reads back the address it sees, so a test can check the offset.
class _Echo extends BridgeModule with HarborDeviceTreeNodeProvider {
  final int base;

  _Echo(HarborFabricKind kind, this.base)
    : super('FabricEcho_${kind.name}', name: 'echo') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      kind: kind,
      addressWidth: 32,
      dataWidth: 32,
      clk: input('clk'),
      reset: input('reset'),
    );
    Sequential(input('clk'), reset: bus.reset, [
      bus.ack < (bus.stb & ~bus.ack),
      bus.dataOut < bus.addr,
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['test,echo'],
    reg: BusAddressRange(base, 0x1000),
  );
}

HarborGpio _gpio(
  HarborFabricKind kind,
  int base,
  String name, {
  int pins = 32,
  bool cross = false,
}) => HarborGpio(
  baseAddress: base,
  pinCount: pins,
  busAddressWidth: 32,
  fabricKind: kind,
  crossFabricClock: cross,
  name: name,
);

HarborSoC _soc(HarborFabricKind kind) => HarborSoC(
  name: 'kind_${kind.name}',
  compatible: 'test,kind',
  fabricKind: kind,
  target: const HarborSimTarget(frequency: 50000000),
  clocks: [
    HarborClockConfig.fixed(
      name: 'sys',
      frequency: 50000000,
      sourceFrequency: 50000000,
      isPrimary: true,
    ),
    HarborClockConfig.fixed(
      name: 'periph',
      frequency: 30000000,
      sourceFrequency: 50000000,
    ),
  ],
);

List<HarborFabricSlave> _slavesOf(HarborFabricModule f) => switch (f) {
  HarborWishboneFabric(:final slaves) ||
  HarborAxi4Fabric(:final slaves) ||
  HarborTileLinkFabric(:final slaves) => slaves,
  _ => throw StateError('unknown fabric ${f.runtimeType}'),
};

Iterable<Module> _all(Module m) sync* {
  yield m;
  for (final s in m.subModules) {
    yield* _all(s);
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  for (final kind in HarborFabricKind.values) {
    test('${kind.name}: peripherals, a crossed peripheral, unmapped access '
        'and bus_error', () async {
      final soc = _soc(kind);
      final cpu = soc.addMaster(_Cpu(kind));
      final a = soc.addPeripheral(_gpio(kind, 0x10001000, 'gpio_a'));
      final b = soc.addPeripheral(_gpio(kind, 0x10002000, 'gpio_b', pins: 16));
      final c = soc.addPeripheral(
        _gpio(kind, 0x10003000, 'gpio_c', cross: true),
        clockDomainName: 'periph',
      );
      soc.addPeripheral(_Echo(kind, 0x10005000));
      cpu.pullUp(soc);
      soc.buildFabric();
      final busError = soc.exposeBusError();

      expect(a.definitionName, isNot(b.definitionName));
      expect(c.definitionName, contains('x${BusSlavePort.crossingDepth}'));
      expect(a.definitionName, contains(kind.name));
      // Every master here has a native error, so nothing folds.
      expect(soc.fabric!.foldError, isNull);

      final clk = SimpleClockGenerator(10).clk;
      final periphClk = SimpleClockGenerator(17).clk;
      final reset = Logic(name: 'reset')..inject(1);
      soc.input('clk').srcConnection! <= clk;
      soc.input('periph_clk').srcConnection! <= periphClk;
      soc.input('reset').srcConnection! <= reset;
      final pins = Logic(width: 32)..inject(0);
      for (final g in [a, b, c]) {
        g.input('gpio_in').srcConnection! <= pins.getRange(0, g.pinCount);
      }
      final bus = RegBus.attach(soc, clk, name: 'cpu', kind: kind);
      await soc.build();

      bool bridge(Module m) =>
          m.definitionName.startsWith('HarborWishboneCdcFifoBridge');
      expect(_all(c).where(bridge), hasLength(1));
      expect(_all(a).where(bridge), isEmpty);

      bus.idle();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());
      for (var i = 0; i < 8; i++) {
        await clk.nextPosedge;
      }
      reset.inject(0);
      for (var i = 0; i < 8; i++) {
        await clk.nextPosedge;
      }

      await bus.write(0x10001000 + _output, 0x11223344);
      await bus.write(0x10002000 + _output, 0x0000beef);
      await bus.write(0x10003000 + _output, 0xcafef00d);
      expect(await bus.read(0x10001000 + _output), 0x11223344);
      expect(await bus.read(0x10002000 + _output), 0x0000beef);
      expect(await bus.read(0x10003000 + _output), 0xcafef00d);
      expect(a.gpioOut.value.toInt(), 0x11223344);
      expect(c.gpioOut.value.toInt(), 0xcafef00d);

      // A write with no byte selected changes nothing, crossed or not.
      await bus.write(0x10001000 + _irqEn, 0, sel: 0);
      await bus.write(0x10001000 + _output, 0xffffffff, sel: 0);
      await bus.write(0x10003000 + _output, 0xffffffff, sel: 0);
      expect(await bus.read(0x10001000 + _output), 0x11223344);
      expect(await bus.read(0x10003000 + _output), 0xcafef00d);

      // Unmapped: the native decode error, and no bus_error because the
      // master has an error signal.
      final rd = await bus.access(0x20000000, write: false);
      expect(rd.err, isTrue);
      final wr = await bus.access(0x20000000, data: 1, write: true);
      expect(wr.err, isTrue);
      await clk.nextPosedge;
      expect(busError.value.toInt(), 0);

      // A slave sees the offset in its own region.
      expect(await bus.read(0x10005000 + 0x7c), 0x7c);

      // The fabric still works after the errors.
      expect(await bus.read(0x10002000 + _output), 0x0000beef);
      await Simulator.endSimulation();
    });
  }

  test('wishbone: a master without ERR gets ACK and data 0 on an unmapped '
      'access, and the fold flag sets bus_error', () async {
    const kind = HarborFabricKind.wishbone;
    final soc = _soc(kind);
    final cpu = soc.addMaster(_Cpu(kind, useErr: false));
    final a = soc.addPeripheral(_gpio(kind, 0x10001000, 'gpio_a'));
    cpu.pullUp(soc);
    soc.buildFabric();
    final busError = soc.exposeBusError();
    expect(soc.fabric!.foldError, isNotNull);

    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset')..inject(1);
    soc.input('clk').srcConnection! <= clk;
    soc.input('periph_clk').srcConnection! <= Const(0);
    soc.input('reset').srcConnection! <= reset;
    a.input('gpio_in').srcConnection! <= Const(0, width: 32);
    final bus = RegBus.attach(soc, clk, name: 'cpu', kind: kind);
    await soc.build();

    bus.idle();
    Simulator.setMaxSimTime(1000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 8; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    await bus.write(0x10001000 + _output, 0x5a5a5a5a);
    expect(await bus.read(0x10001000 + _output), 0x5a5a5a5a);
    expect(busError.value.toInt(), 0);

    final rd = await bus.access(0x20000000, write: false);
    expect(rd.err, isFalse);
    expect(rd.data, 0);
    await clk.nextPosedge;
    expect(busError.value.toInt(), 1);
    expect(soc.fabric!.foldError!.value.toInt(), 1);
    await Simulator.endSimulation();
  });

  for (final kind in HarborFabricKind.values) {
    test('${kind.name}: two channels meet at a shared slave', () async {
      final soc = _soc(kind);
      final cpu = soc.addMaster(_Cpu(kind));
      final dma = soc.addMaster(_Cpu(kind, name: 'dma'), channel: 'dma');
      final a = soc.addPeripheral(_gpio(kind, 0x10001000, 'gpio_a'));
      final b = soc.addPeripheral(_gpio(kind, 0x10002000, 'gpio_b'));
      cpu.pullUp(soc);
      dma.pullUp(soc);
      soc.buildFabric(
        channelSlaves: {
          'primary': {'gpio_a', 'gpio_b'},
          'dma': {'gpio_b'},
        },
      );
      expect(soc.fabrics.map((f) => f.name), [
        'fabric_primary',
        'fabric_dma',
        'converge_gpio_b',
      ]);

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset')..inject(1);
      soc.input('clk').srcConnection! <= clk;
      soc.input('periph_clk').srcConnection! <= Const(0);
      soc.input('reset').srcConnection! <= reset;
      for (final g in [a, b]) {
        g.input('gpio_in').srcConnection! <= Const(0, width: 32);
      }
      final cBus = RegBus.attach(soc, clk, name: 'cpu', kind: kind);
      final dBus = RegBus.attach(soc, clk, name: 'dma', kind: kind);
      await soc.build();
      cBus.idle();
      dBus.idle();
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      for (var i = 0; i < 8; i++) {
        await clk.nextPosedge;
      }
      reset.inject(0);
      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
      }
      await Future.wait([
        cBus.write(0x10001000 + _output, 0x1111),
        dBus.write(0x10002000 + _output, 0x2222),
      ]);
      expect(await cBus.read(0x10002000 + _output), 0x2222);
      expect(await dBus.read(0x10002000 + _output), 0x2222);
      expect(await cBus.read(0x10001000 + _output), 0x1111);
      // gpio_a is out of the dma channel's reach.
      expect((await dBus.access(0x10001000, write: false)).err, isTrue);
      await Simulator.endSimulation();
    });
  }

  for (final kind in HarborFabricKind.values) {
    test(
      '${kind.name}: the CPU reads and writes an SRAM memory slave',
      () async {
        final soc = _soc(kind);
        final cpu = soc.addMaster(_Cpu(kind));
        final sram = soc.addPeripheral(
          HarborSram(
            baseAddress: 0x80000000,
            size: 4096,
            busAddressWidth: 32,
            protocol: kind,
          ),
        );
        cpu.pullUp(soc);
        soc.buildFabric();
        final busError = soc.exposeBusError();
        final slave = _slavesOf(soc.fabric!).single;
        expect(slave.memory, isTrue);
        expect(slave.outstanding, HarborSram.outstanding);
        expect(sram.definitionName, contains(kind.name));

        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset')..inject(1);
        soc.input('clk').srcConnection! <= clk;
        soc.input('periph_clk').srcConnection! <= Const(0);
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
        for (var i = 0; i < 4; i++) {
          await clk.nextPosedge;
        }

        // A word never written reads X data, but the response stays clean.
        final fresh = await bus.access(0x80000800, write: false);
        expect(fresh.err, isFalse);
        expect(fresh.data, -1);

        final golden = <int, int>{};
        for (var i = 0; i < 8; i++) {
          final addr = 0x80000000 + i * 0x1f4 ~/ 4 * 4;
          final data = (0x9e3779b9 * (i + 1)) & 0xffffffff;
          await bus.write(addr, data);
          golden[addr] = data;
        }
        // One byte lane, then a write with no lane selected.
        await bus.write(0x80000000, 0x000000aa, sel: 0x1);
        golden[0x80000000] = (golden[0x80000000]! & 0xffffff00) | 0xaa;
        await bus.write(0x80000000, 0xffffffff, sel: 0);
        for (final MapEntry(key: addr, value: data) in golden.entries) {
          expect(await bus.read(addr), data, reason: addr.toRadixString(16));
        }
        // The top word of the region, at its offset.
        await bus.write(0x80000ffc, 0x5eed1234);
        expect(await bus.read(0x80000ffc), 0x5eed1234);
        await clk.nextPosedge;
        expect(busError.value.toInt(), 0);
        await Simulator.endSimulation();
      },
    );
  }

  for (final kind in HarborFabricKind.values) {
    test('${kind.name}: an SDRAM is a memory slave with its depth', () async {
      final soc = _soc(kind);
      final cpu = soc.addMaster(_Cpu(kind));
      final sdram = soc.addPeripheral(
        HarborSdram(
          config: const HarborSdramConfig.as4c16m16sb6(),
          baseAddress: 0x80000000,
          clockHz: 125000000,
          busAddressWidth: 32,
          protocol: kind,
          target: const HarborFpgaTarget.ecp5(
            device: 'LFE5U-85F',
            package: 'CABGA381',
          ),
        ),
      );
      cpu.pullUp(soc);
      soc.buildFabric();
      final slave = _slavesOf(soc.fabric!).single;
      expect(slave.memory, isTrue);
      expect(slave.outstanding, sdram.outstanding);
      expect(sdram.outstanding, kind == HarborFabricKind.wishbone ? 1 : 8);
      await soc.build();
      expect(
        soc.generateSynth(),
        contains(
          kind == HarborFabricKind.wishbone
              ? 'SdramWishbonePort'
              : 'SdramMemoryPort',
        ),
      );
    });
  }

  group('kind checks', () {
    test('a Wishbone master on an AXI4 fabric names the master task', () {
      final soc = _soc(HarborFabricKind.axi4);
      soc.addMaster(_Cpu(HarborFabricKind.wishbone));
      soc.addPeripheral(_gpio(HarborFabricKind.axi4, 0x10001000, 'gpio_a'));
      expect(
        soc.buildFabric,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('native master port for axi4 is not implemented'),
          ),
        ),
      );
    });

    test('an SRAM of another kind is refused', () {
      final soc = _soc(HarborFabricKind.tilelink);
      soc.addMaster(_Cpu(HarborFabricKind.tilelink));
      soc.addPeripheral(
        HarborSram(baseAddress: 0x80000000, size: 4096, busAddressWidth: 32),
      );
      expect(soc.buildFabric, throwsStateError);
    });

    test('an SDRAM of another kind is refused', () {
      final soc = _soc(HarborFabricKind.axi4);
      soc.addMaster(_Cpu(HarborFabricKind.axi4));
      soc.addPeripheral(
        HarborSdram(
          config: const HarborSdramConfig.as4c16m16sb6(),
          baseAddress: 0x80000000,
          clockHz: 125000000,
          busAddressWidth: 32,
          target: const HarborFpgaTarget.ecp5(
            device: 'LFE5U-85F',
            package: 'CABGA381',
          ),
        ),
      );
      expect(soc.buildFabric, throwsStateError);
    });

    test('a peripheral of another kind is refused', () {
      final soc = _soc(HarborFabricKind.axi4);
      soc.addMaster(_Cpu(HarborFabricKind.axi4));
      soc.addPeripheral(_gpio(HarborFabricKind.tilelink, 0x10001000, 'gpio_a'));
      expect(soc.buildFabric, throwsStateError);
    });

    test('a peripheral on another clock with no crossing is refused', () {
      final soc = _soc(HarborFabricKind.wishbone);
      soc.addMaster(_Cpu(HarborFabricKind.wishbone));
      soc.addPeripheral(
        _gpio(HarborFabricKind.wishbone, 0x10001000, 'gpio_a'),
        clockDomainName: 'periph',
      );
      expect(
        soc.buildFabric,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('crossFabricClock'),
          ),
        ),
      );
    });

    test('pipeline has no effect on an AXI4 fabric', () {
      final soc = _soc(HarborFabricKind.axi4);
      soc.addMaster(_Cpu(HarborFabricKind.axi4), pipeline: true);
      soc.addPeripheral(_gpio(HarborFabricKind.axi4, 0x10001000, 'gpio_a'));
      expect(soc.buildFabric, returnsNormally);
    });
  });
}
