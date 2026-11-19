import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

const _output = 0x08;

/// A master with plain `p_<PORT>` pins and no fabric clock input.
class _Cpu extends BridgeModule {
  _Cpu(HarborFabricKind kind)
    : super('MasterDomainCpu_${kind.name}', name: 'cpu') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final PairInterface intf = switch (kind) {
      HarborFabricKind.wishbone => WishboneInterface(
        WishboneConfig(addressWidth: 32, dataWidth: 32),
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
}

/// A slave that reads back the address it sees.
class _Echo extends BridgeModule with HarborDeviceTreeNodeProvider {
  final int base;

  _Echo(HarborFabricKind kind, this.base)
    : super('MasterDomainEcho_${kind.name}', name: 'echo') {
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

/// A master port `m` with a fabric clock crossing, pinned out as
/// `m__<PORT>`, and an echo slave port `bus` that shares the same fabric
/// clock inputs.
class _Dual extends BridgeModule with HarborDeviceTreeNodeProvider {
  final int base;

  _Dual(this.base) : super('MasterDomainDual', name: 'dual') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final fabricClock = BusSlavePort.fabricClockInputs(this, cross: true);
    const kind = HarborFabricKind.wishbone;
    final m = BusMasterPort.create(
      module: this,
      name: 'm',
      kind: kind,
      addressWidth: 32,
      dataWidth: 32,
      clk: input('clk'),
      reset: input('reset'),
      useErr: true,
      fabricClock: fabricClock,
    );
    m.addr <= addInput('m__adr', Logic(width: 32), width: 32);
    m.dataOut <= addInput('m__wdat', Logic(width: 32), width: 32);
    m.stb <= addInput('m__stb', Logic());
    m.we <= addInput('m__we', Logic());
    m.sel <= addInput('m__sel', Logic(width: 4), width: 4);
    addOutput('m__rdat', width: 32) <= m.dataIn;
    addOutput('m__ack') <= m.ack;
    addOutput('m__err') <= m.err;
    final bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      kind: kind,
      addressWidth: 32,
      dataWidth: 32,
      clk: input('clk'),
      reset: input('reset'),
      fabricClock: fabricClock,
    );
    Sequential(input('clk'), reset: bus.reset, [
      bus.ack < (bus.stb & ~bus.ack),
      bus.dataOut < bus.addr,
    ]);
  }

  void pullUp(HarborSoC soc) {
    for (final n in [...inputs.keys, ...outputs.keys]) {
      if (!n.startsWith('m__')) continue;
      soc.pullUpPort(port(n), newPortName: 'dual_m_${n.substring(3)}');
    }
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['test,dual'],
    reg: BusAddressRange(base, 0x1000),
  );
}

HarborSoC _soc(HarborFabricKind kind) => HarborSoC(
  name: 'MasterDomainSoc',
  compatible: 'test,master-domain',
  fabricKind: kind,
  fabricClockDomain: 'bus',
  target: const HarborSimTarget(frequency: 50000000),
  clocks: [
    HarborClockConfig.fixed(
      name: 'core',
      frequency: 50000000,
      sourceFrequency: 50000000,
      isPrimary: true,
    ),
    HarborClockConfig.fixed(
      name: 'bus',
      frequency: 30000000,
      sourceFrequency: 50000000,
    ),
  ],
);

void main() {
  tearDown(() async => Simulator.reset());

  for (final kind in [HarborFabricKind.wishbone, HarborFabricKind.axi4]) {
    test(
      '${kind.name}: a master on another domain with no crossing throws',
      () {
        final soc = _soc(kind);
        soc.addMaster(_Cpu(kind), clockDomainName: 'core');
        soc.addPeripheral(_Echo(kind, 0x10005000));
        expect(
          soc.buildFabric,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('cpu'),
                contains('"core"'),
                contains('fabricClock'),
              ),
            ),
          ),
        );
      },
    );

    test('${kind.name}: a master on the fabric domain needs nothing', () {
      final soc = _soc(kind);
      final cpu = soc.addMaster(_Cpu(kind));
      soc.addPeripheral(_Echo(kind, 0x10005000));
      soc.buildFabric();
      expect(
        cpu.input('clk').srcConnection!.srcConnections,
        contains(soc.fabricDomain!.clk),
      );
    });
  }

  test('a master on the fabric domain by name needs nothing', () {
    final soc = _soc(HarborFabricKind.wishbone);
    soc.addMaster(_Cpu(HarborFabricKind.wishbone), clockDomainName: 'bus');
    soc.addPeripheral(_Echo(HarborFabricKind.wishbone, 0x10005000));
    soc.buildFabric();
  });

  test('an unknown explicit domain name throws and names the module', () {
    final soc = _soc(HarborFabricKind.wishbone);
    for (final add in [
      () => soc.addMaster(
        _Cpu(HarborFabricKind.wishbone),
        clockDomainName: 'typo',
      ),
      () => soc.addPeripheral(
        _Echo(HarborFabricKind.wishbone, 0x10005000),
        clockDomainName: 'typo',
      ),
    ]) {
      expect(
        add,
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('typo'), anyOf(contains('cpu'), contains('echo'))),
          ),
        ),
      );
    }
  });

  test('fabricDomain is the named domain', () {
    final soc = _soc(HarborFabricKind.wishbone);
    expect(soc.fabricDomain, same(soc.clockDomain('bus')));
  });

  test('a master and slave module with a crossing: one drive, both roles '
      'work', () async {
    const kind = HarborFabricKind.wishbone;
    final soc = _soc(kind);
    final dual = _Dual(0x10005000);
    soc.addMaster(dual, busInterfaceName: 'm', clockDomainName: 'core');
    soc.addPeripheral(dual, clockDomainName: 'core');
    final gpio = soc.addPeripheral(
      HarborGpio(
        baseAddress: 0x10001000,
        pinCount: 32,
        busAddressWidth: 32,
        fabricKind: kind,
        name: 'gpio',
      ),
    );
    dual.pullUp(soc);
    soc.buildFabric();
    final bus = soc.clockDomain('bus')!;
    expect(
      dual.input(BusSlavePort.fabricClkPort).srcConnection!.srcConnections,
      [bus.clk],
    );
    expect(
      dual.input(BusSlavePort.fabricResetPort).srcConnection!.srcConnections,
      [bus.reset],
    );

    final clk = SimpleClockGenerator(10).clk;
    final busClk = SimpleClockGenerator(14).clk;
    final reset = Logic(name: 'reset')..inject(1);
    soc.input('clk').srcConnection! <= clk;
    soc.input('bus_clk').srcConnection! <= busClk;
    soc.input('reset').srcConnection! <= reset;
    gpio.input('gpio_in').srcConnection! <= Const(0, width: 32);
    final pins = {
      for (final p in ['adr', 'wdat', 'stb', 'we', 'sel'])
        p: Logic(name: 'drv_$p', width: soc.input('dual_m_$p').width),
    };
    for (final e in pins.entries) {
      soc.input('dual_m_${e.key}').srcConnection! <= e.value;
      e.value.inject(0);
    }
    await soc.build();
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 8; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    for (var i = 0; i < 8; i++) {
      await clk.nextPosedge;
    }

    Future<int> access(int addr, {int data = 0, bool write = false}) async {
      await clk.nextNegedge;
      pins['adr']!.inject(addr);
      pins['wdat']!.inject(data);
      pins['we']!.inject(write ? 1 : 0);
      pins['sel']!.inject(0xf);
      pins['stb']!.inject(1);
      for (var i = 0; i < 2000; i++) {
        await clk.nextPosedge;
        if (soc.output('dual_m_ack').previousValue!.toBool()) {
          final r = soc.output('dual_m_rdat').previousValue!.toInt();
          await clk.nextNegedge;
          pins['stb']!.inject(0);
          return r;
        }
      }
      throw StateError('access at 0x${addr.toRadixString(16)} hung');
    }

    await access(0x10001000 + _output, data: 0xcafef00d, write: true);
    expect(await access(0x10001000 + _output), 0xcafef00d);
    expect(gpio.gpioOut.value.toInt(), 0xcafef00d);
    // The slave face of the same module answers through the fabric too.
    expect(await access(0x10005000 + 0x7c), 0x7c);
    await Simulator.endSimulation();
  });
}
