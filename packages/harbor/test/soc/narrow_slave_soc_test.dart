// A 64-bit SoC on each fabric kind with slaves that have a fixed 32-bit
// port: the PMU, the reset controller, the watchdog and a device that reads
// back the address it sees. The fabric puts a width adapter in front of each.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

const _addrW = 64;
const _dataW = 64;

const _pmu = 0x10006000;
const _reset = 0x10005000;
const _wdog = 0x10007000;
const _echo = 0x1000_0000_9000;

class _Cpu extends BridgeModule {
  _Cpu(HarborFabricKind kind) : super('NarrowCpu_${kind.name}', name: 'cpu') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final PairInterface intf = switch (kind) {
      HarborFabricKind.wishbone => WishboneInterface(
        const WishboneConfig(
          addressWidth: _addrW,
          dataWidth: _dataW,
          useErr: true,
        ),
      ),
      HarborFabricKind.axi4 => Axi4LiteInterface(
        addressWidth: _addrW,
        dataWidth: _dataW,
      ),
      HarborFabricKind.tilelink => TileLinkInterface(
        const TileLinkConfig(addressWidth: _addrW, dataWidth: _dataW),
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

/// A 32-bit device that reads back the address it sees and counts accesses.
class _Echo extends BridgeModule
    with HarborDeviceTreeNodeProvider, HarborNarrowSlaveOk {
  _Echo(HarborFabricKind kind)
    : super('NarrowEcho_${kind.name}', name: 'echo') {
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
    final hits = addOutput('hits', width: 16);
    final count = Logic(name: 'count', width: 16);
    hits <= count;
    Sequential(input('clk'), reset: bus.reset, [
      bus.ack < (bus.stb & ~bus.ack),
      bus.dataOut < bus.addr,
      count < count + (bus.stb & ~bus.ack).zeroExtend(16),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['test,echo'],
    reg: BusAddressRange(_echo, 0x1000),
  );
}

class _Bench {
  final HarborSoC soc;
  final RegBus bus;
  final Logic clk;
  final _Echo echo;
  _Bench(this.soc, this.bus, this.clk, this.echo);
}

Future<_Bench> _bench(HarborFabricKind kind) async {
  final soc = HarborSoC(
    name: 'narrow_${kind.name}',
    compatible: 'test,narrow',
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
  soc
    ..addPeripheral(
      HarborPowerManagementUnit(
        config: const HarborPmuConfig(
          domains: [HarborPowerDomain(name: 'cpu', index: 0)],
        ),
        baseAddress: _pmu,
        fabricKind: kind,
      ),
    )
    ..addPeripheral(
      HarborResetController(baseAddress: _reset, fabricKind: kind),
    )
    ..addPeripheral(HarborWatchdog(baseAddress: _wdog, fabricKind: kind));
  final echo = soc.addPeripheral(_Echo(kind));
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
  // The reset controller holds the power-on reset for 256 cycles.
  for (var i = 0; i < 300; i++) {
    await clk.nextPosedge;
  }
  return _Bench(soc, bus, clk, echo);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  for (final kind in HarborFabricKind.values) {
    group(kind.name, () {
      test('the PMU, reset controller and watchdog take register access '
          'through the adapter', () async {
        final b = await _bench(kind);
        expect(b.bus.dataWidth, 64);

        // A 32-bit access to the low word of its 8-byte slot.
        await b.bus.write(_pmu + 0x10, 0xa5, sel: 0x0f);
        expect(await b.bus.read(_pmu + 0x10, sel: 0x0f), 0xa5);
        await b.bus.write(_wdog + 0x10, 0x1234, sel: 0x0f);
        expect(await b.bus.read(_wdog + 0x10, sel: 0x0f), 0x1234);
        await b.bus.write(_reset + 0x10, 0x4321, sel: 0x0f);
        expect(await b.bus.read(_reset + 0x10, sel: 0x0f), 0x4321);

        // The registers are not aliases of one another.
        expect(await b.bus.read(_pmu + 0x10, sel: 0x0f), 0xa5);
        expect(await b.bus.read(_wdog + 0x10, sel: 0x0f), 0x1234);

        // A byte store changes one byte.
        await b.bus.write(_wdog + 0x10, 0x99, sel: 0x01);
        expect(await b.bus.read(_wdog + 0x10, sel: 0x0f), 0x1299);
        await Simulator.endSimulation();
      });

      test('the lane comes from the address and the byte selects', () async {
        final b = await _bench(kind);
        // Lane 0 sees its own word address, lane 1 the next word.
        expect(await b.bus.read(_echo + 0x10, sel: 0x0f), 0x10);
        // The slave sees the offset in its region, 32 bits wide, and the
        // data comes back in lane 1.
        expect(await b.bus.read(_echo + 0x14, sel: 0xf0), 0x14 << 32);
        expect(await b.bus.read(_echo + 0x7c, sel: 0xf0), 0x7c << 32);
        final before = b.echo.output('hits').value.toInt();
        final w = await b.bus.access(
          _echo + 0x24,
          data: 0x1,
          sel: 0xf0,
          write: true,
        );
        expect(w.err, isFalse);
        expect(b.echo.output('hits').value.toInt(), before + 1);
        await Simulator.endSimulation();
      });

      test('a write with byte selects in both words gets an error and never '
          'reaches the slave', () async {
        final b = await _bench(kind);
        final before = b.echo.output('hits').value.toInt();
        final w = await b.bus.access(
          _echo + 0x10,
          data: 0x1122334455667788,
          write: true,
        );
        expect(w.err, isTrue);
        await b.clk.nextPosedge;
        expect(b.echo.output('hits').value.toInt(), before);

        // The same register still works after the error.
        await b.bus.write(_wdog + 0x10, 0x77, sel: 0x0f);
        expect(await b.bus.read(_wdog + 0x10, sel: 0x0f), 0x77);
        // The reset controller takes no write of the whole word either.
        final r = await b.bus.access(
          _reset + 0x10,
          data: 0xffffffffffffffff,
          write: true,
        );
        expect(r.err, isTrue);
        expect(await b.bus.read(_reset + 0x10, sel: 0x0f), 0x100);
        await Simulator.endSimulation();
      });

      test(
        'a read of the whole word ${switch (kind) {
          HarborFabricKind.axi4 => 'takes the lane at its address, since '
              'AXI4-Lite has no read size',
          _ => 'gets an error, since its byte selects span both words',
        }}',
        () async {
          final b = await _bench(kind);
          final before = b.echo.output('hits').value.toInt();
          final r = await b.bus.access(_echo + 0x10, write: false);
          if (kind == HarborFabricKind.axi4) {
            expect(r.err, isFalse);
            expect(r.data, 0x10);
            expect(b.echo.output('hits').value.toInt(), before + 1);
          } else {
            expect(r.err, isTrue);
            expect(b.echo.output('hits').value.toInt(), before);
          }
          await Simulator.endSimulation();
        },
      );
    });
  }

  for (final kind in HarborFabricKind.values) {
    test('${kind.name}: a 32-bit XIP window on a 64-bit fabric throws', () {
      final soc = HarborSoC(
        name: 'narrow_xip_${kind.name}',
        compatible: 'test,narrow',
        fabricKind: kind,
        target: const HarborSimTarget(frequency: 50000000),
      );
      soc.addMaster(_Cpu(kind));
      soc.addPeripheral(_flash(kind));
      expect(
        soc.buildFabric,
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            allOf(contains('differ'), contains('busDataWidth')),
          ),
        ),
      );
    });
  }

  test('a device that does not opt in throws on a 64-bit fabric', () {
    final soc = HarborSoC(
      name: 'narrow_plain',
      compatible: 'test,narrow',
      fabricKind: HarborFabricKind.axi4,
      target: const HarborSimTarget(frequency: 50000000),
    );
    soc.addMaster(_Cpu(HarborFabricKind.axi4));
    soc.addPeripheral(_Plain());
    expect(soc.buildFabric, throwsA(isA<ArgumentError>()));
  });

  test('a slave wider than the fabric still throws', () async {
    final soc = HarborSoC(
      name: 'narrow_wide',
      compatible: 'test,narrow',
      fabricKind: HarborFabricKind.axi4,
      target: const HarborSimTarget(frequency: 50000000),
    );
    soc.addMaster(_Cpu(HarborFabricKind.axi4));
    soc.addPeripheral(_Wide());
    expect(soc.buildFabric, throwsA(isA<ArgumentError>()));
  });
}

// A SPI flash XIP window with a 32-bit port is a memory window, so it must
// not get a width adapter on a 64-bit fabric.
HarborSpiFlashController _flash(HarborFabricKind kind, {int? width}) =>
    HarborSpiFlashController(
      clockHz: 100000000,
      config: HarborSpiFlashConfig.n25q128(),
      baseAddress: 0x20000000,
      busAddressWidth: 32,
      busDataWidth: width,
      fabricKind: kind,
    );

/// A 32-bit register device that does not opt in to adapting.
class _Plain extends BridgeModule with HarborDeviceTreeNodeProvider {
  _Plain() : super('NarrowPlain', name: 'plain') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    BusSlavePort.create(
      module: this,
      name: 'bus',
      kind: HarborFabricKind.axi4,
      addressWidth: 12,
      dataWidth: 32,
      clk: input('clk'),
      reset: input('reset'),
    );
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['test,plain'],
    reg: BusAddressRange(0x10001000, 0x1000),
  );
}

class _Wide extends BridgeModule with HarborDeviceTreeNodeProvider {
  _Wide() : super('NarrowWide', name: 'wide') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    BusSlavePort.create(
      module: this,
      name: 'bus',
      kind: HarborFabricKind.axi4,
      addressWidth: 12,
      dataWidth: 128,
      clk: input('clk'),
      reset: input('reset'),
    );
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['test,wide'],
    reg: BusAddressRange(0x10001000, 0x1000),
  );
}
