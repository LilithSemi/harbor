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

  _Dual(this.base, {bool crossMaster = true})
    : super('MasterDomainDual${crossMaster ? '' : 'Open'}', name: 'dual') {
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
      fabricClock: crossMaster ? fabricClock : null,
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

/// A master with a memory waist port `bus` that crosses to the fabric
/// clock, driven from `rq_*` and `wd_*` pins. It reads and writes one word.
class _MemMaster extends BridgeModule {
  _MemMaster() : super('MasterDomainMem', name: 'mem') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final fabricClock = BusSlavePort.fabricClockInputs(this, cross: true);
    final port = HarborMemoryMasterPort.create(
      module: this,
      name: 'bus',
      kind: HarborFabricKind.axi4,
      config: const HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32),
      clk: input('clk'),
      reset: input('reset'),
      fabricClock: fabricClock,
    );
    final w = port.waist;
    w.reqValid <= addInput('rq_valid', Logic());
    w.reqWrite <= addInput('rq_write', Logic());
    w.reqAddr <= addInput('rq_addr', Logic(width: 32), width: 32);
    w.reqId <= Const(0);
    w.reqLen <= Const(0, width: 8);
    w.reqSize <= Const(2, width: 3);
    w.reqBurst <= Const(HarborMemoryBurst.incr.value, width: 2);
    w.reqExclusive <= Const(0);
    w.wdataValid <= addInput('wd_valid', Logic());
    w.wdataData <= addInput('wd_data', Logic(width: 32), width: 32);
    w.wdataStrb <= Const(0xf, width: 4);
    w.wdataLast <= Const(1);
    w.rdataReady <= Const(1);
    w.wrespReady <= Const(1);
    addOutput('rq_ready') <= w.reqReady;
    addOutput('wd_ready') <= w.wdataReady;
    addOutput('rd_valid') <= w.rdataValid;
    addOutput('rd_data', width: 32) <= w.rdataData;
    addOutput('wr_valid') <= w.wrespValid;
  }

  void pullUp(HarborSoC soc) {
    for (final n in [...inputs.keys, ...outputs.keys]) {
      if (!RegExp('^(rq|wd|rd|wr)_').hasMatch(n)) continue;
      soc.pullUpPort(port(n), newPortName: 'mem_$n');
    }
  }
}

/// A master whose fabric clock inputs have other names than the SoC drives.
class _OwnClock extends BridgeModule {
  _OwnClock() : super('MasterDomainOwnClock', name: 'own') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('my_clk', PortDirection.input);
    createPort('my_reset', PortDirection.input);
    final m = BusMasterPort.create(
      module: this,
      name: 'm',
      kind: HarborFabricKind.wishbone,
      addressWidth: 32,
      dataWidth: 32,
      clk: input('clk'),
      reset: input('reset'),
      fabricClock: HarborFabricClock(
        clk: input('my_clk'),
        reset: input('my_reset'),
      ),
    );
    m.addr <= Const(0, width: 32);
    m.dataOut <= Const(0, width: 32);
    m.stb <= Const(0);
    m.we <= Const(0);
    m.sel <= Const(0xf, width: 4);
  }
}

/// A slave port crossed through `fabric_clk`, and a master port crossed to
/// other clock inputs.
class _Mixed extends BridgeModule with HarborDeviceTreeNodeProvider {
  _Mixed() : super('MasterDomainMixed', name: 'mixed') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('my_clk', PortDirection.input);
    createPort('my_reset', PortDirection.input);
    const kind = HarborFabricKind.wishbone;
    final m = BusMasterPort.create(
      module: this,
      name: 'm',
      kind: kind,
      addressWidth: 32,
      dataWidth: 32,
      clk: input('clk'),
      reset: input('reset'),
      fabricClock: HarborFabricClock(
        clk: input('my_clk'),
        reset: input('my_reset'),
      ),
    );
    m.addr <= Const(0, width: 32);
    m.dataOut <= Const(0, width: 32);
    m.stb <= Const(0);
    m.we <= Const(0);
    m.sel <= Const(0xf, width: 4);
    final bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      kind: kind,
      addressWidth: 32,
      dataWidth: 32,
      clk: input('clk'),
      reset: input('reset'),
      fabricClock: BusSlavePort.fabricClockInputs(this, cross: true),
    );
    Sequential(input('clk'), reset: bus.reset, [
      bus.ack < (bus.stb & ~bus.ack),
      bus.dataOut < bus.addr,
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['test,mixed'],
    reg: BusAddressRange(0x10005000, 0x1000),
  );
}

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

  test('a master port with no crossing throws even if another port of the '
      'module crosses', () {
    final soc = _soc(HarborFabricKind.wishbone);
    final dual = _Dual(0x10005000, crossMaster: false);
    soc.addMaster(dual, busInterfaceName: 'm', clockDomainName: 'core');
    soc.addPeripheral(dual, clockDomainName: 'core');
    expect(
      soc.buildFabric,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('dual'), contains('port m'), contains('"core"')),
        ),
      ),
    );
  });

  test('a master port crossed to other clock inputs throws even if the slave '
      'port of the module uses fabric_clk', () {
    final soc = _soc(HarborFabricKind.wishbone);
    final mixed = _Mixed();
    soc.addMaster(mixed, busInterfaceName: 'm', clockDomainName: 'core');
    soc.addPeripheral(mixed, clockDomainName: 'core');
    expect(
      soc.buildFabric,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('mixed'), contains('port m'), contains('"core"')),
        ),
      ),
    );
  });

  test('a crossing built on other clock inputs throws', () {
    final soc = _soc(HarborFabricKind.wishbone);
    soc.addMaster(_OwnClock(), busInterfaceName: 'm', clockDomainName: 'core');
    soc.addPeripheral(_Echo(HarborFabricKind.wishbone, 0x10005000));
    expect(
      soc.buildFabric,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('own'), contains(BusSlavePort.fabricClkPort)),
        ),
      ),
    );
  });

  test('a peripheral registered before the master drives the fabric clock '
      'once', () {
    final soc = _soc(HarborFabricKind.wishbone);
    final dual = _Dual(0x10005000);
    soc.addPeripheral(dual, clockDomainName: 'core');
    soc.addMaster(dual, busInterfaceName: 'm', clockDomainName: 'core');
    soc.buildFabric();
    final bus = soc.clockDomain('bus')!;
    expect(
      dual.input(BusSlavePort.fabricClkPort).srcConnection!.srcConnections,
      [bus.clk],
    );
  });

  group('one domain per module', () {
    test('a later registration with no name keeps the first domain', () {
      final soc = _soc(HarborFabricKind.wishbone);
      final dual = _Dual(0x10005000);
      soc.addMaster(dual, busInterfaceName: 'm', clockDomainName: 'core');
      soc.addPeripheral(dual);
      soc.buildFabric();
    });

    test('a later explicit name on another domain throws and names both', () {
      final soc = _soc(HarborFabricKind.wishbone);
      final dual = _Dual(0x10005000);
      soc.addMaster(dual, busInterfaceName: 'm', clockDomainName: 'core');
      expect(
        () => soc.addPeripheral(dual, clockDomainName: 'bus'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('dual'), contains('"core"'), contains('"bus"')),
          ),
        ),
      );
    });

    test('a first registration with no name binds the fabric domain', () {
      final soc = _soc(HarborFabricKind.wishbone);
      final dual = _Dual(0x10005000);
      soc.addPeripheral(dual);
      expect(
        () =>
            soc.addMaster(dual, busInterfaceName: 'm', clockDomainName: 'core'),
        throwsStateError,
      );
    });
  });

  test('a memory master port with a crossing reads and writes', () async {
    final soc = HarborSoC(
      name: 'MemMasterSoc',
      compatible: 'test,mem-master',
      fabricKind: HarborFabricKind.axi4,
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
    final mem = _MemMaster();
    soc.addMaster(mem, busInterfaceName: 'bus', clockDomainName: 'core');
    soc.addPeripheral(
      HarborSram(
        baseAddress: 0x80000000,
        size: 4096,
        busAddressWidth: 32,
        protocol: HarborFabricKind.axi4,
      ),
    );
    mem.pullUp(soc);
    soc.buildFabric();
    final bus = soc.clockDomain('bus')!;
    expect(
      mem.input(BusSlavePort.fabricClkPort).srcConnection!.srcConnections,
      [bus.clk],
    );
    final clk = SimpleClockGenerator(10).clk;
    final busClk = SimpleClockGenerator(14).clk;
    final reset = Logic(name: 'reset')..inject(1);
    soc.input('clk').srcConnection! <= clk;
    soc.input('bus_clk').srcConnection! <= busClk;
    soc.input('reset').srcConnection! <= reset;
    final pins = {
      for (final p in [
        'rq_valid',
        'rq_write',
        'rq_addr',
        'wd_valid',
        'wd_data',
      ])
        p: Logic(name: 'drv_$p', width: soc.input('mem_$p').width),
    };
    for (final e in pins.entries) {
      soc.input('mem_${e.key}').srcConnection! <= e.value;
      e.value.inject(0);
    }
    await soc.build();
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 8; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    for (var i = 0; i < 16; i++) {
      await clk.nextPosedge;
    }

    bool high(String n) => soc.output('mem_$n').previousValue!.toBool();
    Future<void> waitHigh(String n) async {
      for (var i = 0; i < 2000; i++) {
        await clk.nextPosedge;
        if (high(n)) return;
      }
      throw StateError('$n never rose');
    }

    Future<void> send(String valid, String ready) async {
      await clk.nextNegedge;
      pins[valid]!.inject(1);
      await waitHigh(ready);
      await clk.nextNegedge;
      pins[valid]!.inject(0);
    }

    Future<void> write(int addr, int data) async {
      await clk.nextNegedge;
      pins['rq_write']!.inject(1);
      pins['rq_addr']!.inject(addr);
      pins['wd_data']!.inject(data);
      await send('rq_valid', 'rq_ready');
      await send('wd_valid', 'wd_ready');
      await waitHigh('wr_valid');
    }

    Future<int> read(int addr) async {
      await clk.nextNegedge;
      pins['rq_write']!.inject(0);
      pins['rq_addr']!.inject(addr);
      await send('rq_valid', 'rq_ready');
      await waitHigh('rd_valid');
      return soc.output('mem_rd_data').previousValue!.toInt();
    }

    await write(0x80000010, 0xcafef00d);
    await write(0x80000014, 0x12345678);
    expect(await read(0x80000010), 0xcafef00d);
    expect(await read(0x80000014), 0x12345678);
    await Simulator.endSimulation();
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
