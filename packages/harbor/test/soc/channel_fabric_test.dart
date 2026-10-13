// HarborSoC.buildFabric channels: the masters of a channel reach only the
// slaves of that channel. One channel gives a shared fabric. More than one
// channel gives a crossbar, so the channels meet only at shared slaves.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

/// Wishbone master that, on `start`, writes `value` to `addr` then reads it
/// back, latching the result on `rdata` and asserting `done`. Same shape as the
/// multi_master_test helper, reused here to drive per-channel transactions.
class _RwMaster extends BridgeModule {
  _RwMaster(WishboneConfig cfg, int addr, int value, {String? name})
    : super('RwMaster', name: name ?? 'rw_master') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    final done = addOutput('done');
    final rdata = addOutput('rdata', width: cfg.dataWidth);

    final bus =
        addInterface(
              WishboneInterface(cfg),
              name: 'bus',
              role: PairRole.provider,
            ).internalInterface
            as WishboneInterface;

    final clk = input('clk');
    final reset = input('reset');
    final start = input('start');

    final st = Logic(name: 'st', width: 3);
    final cyc = Logic(name: 'cyc');
    final stb = Logic(name: 'stb');
    final we = Logic(name: 'we');
    final rdReg = Logic(name: 'rd_reg', width: cfg.dataWidth);
    final doneReg = Logic(name: 'done_reg');
    final ackNow = cyc & stb & bus.ack;

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(0, width: 3),
          cyc < Const(0),
          stb < Const(0),
          we < Const(0),
          rdReg < Const(0, width: cfg.dataWidth),
          doneReg < Const(0),
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(0, width: 3), [
              If(
                start,
                then: [
                  cyc < Const(1),
                  stb < Const(1),
                  we < Const(1),
                  st < Const(1, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(1, width: 3), [
              If(
                ackNow,
                then: [
                  cyc < Const(0),
                  stb < Const(0),
                  we < Const(0),
                  st < Const(2, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(2, width: 3), [
              cyc < Const(1),
              stb < Const(1),
              we < Const(0),
              st < Const(3, width: 3),
            ]),
            CaseItem(Const(3, width: 3), [
              If(
                ackNow,
                then: [
                  rdReg < bus.datMiso,
                  cyc < Const(0),
                  stb < Const(0),
                  doneReg < Const(1),
                  st < Const(4, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(4, width: 3), []),
          ]),
        ],
      ),
    ]);

    bus.cyc <= cyc;
    bus.stb <= stb;
    bus.we <= we;
    bus.adr <= Const(addr, width: cfg.addressWidth);
    bus.datMosi <= Const(value, width: cfg.dataWidth);
    bus.sel <=
        Const((1 << cfg.effectiveSelWidth) - 1, width: cfg.effectiveSelWidth);
    done <= doneReg;
    rdata <= rdReg;
  }
}

HarborWishboneFabric _fabric(HarborSoC soc) =>
    soc.fabric! as HarborWishboneFabric;

/// Each fabric of [soc] by name, as `masters > slaves`. Every one is shared.
Map<String, String> _shape(HarborSoC soc) => {
  for (final f in soc.fabrics.cast<HarborWishboneFabric>())
    f.name:
        '${f.masters.map((m) => m.name).join(' ')} > '
        '${f.slaves.map((s) => s.name).join(' ')}',
};

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('one channel', () {
    test('builds a shared fabric where every master reaches all', () async {
      const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);

      HarborWishboneFabric build(Map<String, Set<String>>? cs) {
        final soc = HarborSoC(name: 'IdSoC', compatible: 'test,id');
        soc.addMaster(
          _RwMaster(cfg, 0x20, 0, name: 'cpu'),
          busInterfaceName: 'bus',
        );
        soc.addPeripheral(
          HarborSram(
            baseAddress: 0,
            size: 4096,
            busAddressWidth: 32,
            name: 'sramA',
          ),
        );
        soc.addPeripheral(
          HarborSram(
            baseAddress: 0x1000,
            size: 4096,
            busAddressWidth: 32,
            name: 'sramB',
          ),
        );
        soc.buildFabric(channelSlaves: cs);
        return _fabric(soc);
      }

      final byDefault = build(null);
      expect(byDefault.topology, HarborFabricTopology.shared);
      expect(byDefault.masters.single.reach, isNull);
      expect(byDefault.slaves.map((s) => s.name), ['sramA', 'sramB']);
      await Simulator.reset();

      final byExplicit = build({
        'primary': {'sramA', 'sramB'},
      });
      expect(byExplicit.topology, HarborFabricTopology.shared);
      expect(byExplicit.masters.single.reach, {'sramA', 'sramB'});
    });
  });

  test('two channels, disjoint slaves: a fabric per channel', () async {
    const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
    final soc = HarborSoC(name: 'DisjointSoC', compatible: 'test,disjoint');
    // perA at 0x0.., perB at 0x1000..
    final mCpu = _RwMaster(cfg, 0x20, 0xAAAA1111, name: 'cpu');
    final mDma = _RwMaster(cfg, 0x1020, 0xBBBB2222, name: 'dma');
    // The out of reach master: perA is not in the dma channel.
    final mStray = _RwMaster(cfg, 0x40, 0xCCCC3333, name: 'stray');
    soc.addMaster(mCpu, busInterfaceName: 'bus', channel: 'primary');
    soc.addMaster(mDma, busInterfaceName: 'bus', channel: 'dma');
    soc.addMaster(mStray, busInterfaceName: 'bus', channel: 'dma');
    soc.addPeripheral(
      HarborSram(baseAddress: 0, size: 4096, busAddressWidth: 32, name: 'perA'),
    );
    soc.addPeripheral(
      HarborSram(
        baseAddress: 0x1000,
        size: 4096,
        busAddressWidth: 32,
        name: 'perB',
      ),
    );
    soc.buildFabric(
      channelSlaves: {
        'primary': {'perA'},
        'dma': {'perB'},
      },
    );
    final busError = soc.exposeBusError();

    // A shared fabric per channel over its own slaves, no converge fabric.
    expect(_shape(soc), {
      'fabric_primary': 'cpu > perA',
      'fabric_dma': 'dma stray > perB',
    });

    final clk = SimpleClockGenerator(10).clk;
    final resetL = Logic(name: 'reset')..inject(1);
    final start = Logic(name: 'start')..inject(0);
    soc.input('clk').srcConnection! <= clk;
    soc.input('reset').srcConnection! <= resetL;
    for (final m in [mCpu, mDma, mStray]) {
      m.input('start').srcConnection! <= start;
    }

    await soc.build();
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    resetL.inject(0);
    await clk.nextPosedge;
    expect(busError.value.toInt(), 0);
    start.inject(1);
    await clk.nextPosedge;
    start.inject(0);

    var guard = 0;
    while (guard++ < 500) {
      await clk.nextPosedge;
      if ([mCpu, mDma, mStray].every((m) => m.output('done').value.toBool())) {
        break;
      }
    }
    for (final m in [mCpu, mDma, mStray]) {
      expect(m.output('done').value.toBool(), isTrue, reason: m.name);
    }
    expect(mCpu.output('rdata').value.toInt(), equals(0xAAAA1111));
    expect(mDma.output('rdata').value.toInt(), equals(0xBBBB2222));
    // Out of reach: ACK with data 0 to a master with no ERR, and the fold
    // flag sets bus_error.
    expect(mStray.output('rdata').value.toInt(), equals(0));
    expect(busError.value.toInt(), 1);
    await Simulator.endSimulation();
  });

  test(
    'two channels sharing memory: convergence arbiter, both reach mem',
    () async {
      const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
      final soc = HarborSoC(name: 'SharedMemSoC', compatible: 'test,sharedmem');
      // perA at 0x0.. (primary only), mem at 0x1000.. (both channels).
      // primary writes/reads a mem word, dma writes/reads a different mem word.
      final mCpu = _RwMaster(cfg, 0x1020, 0xAAAA1111, name: 'cpu');
      final mDma = _RwMaster(cfg, 0x1040, 0xBBBB2222, name: 'dma');
      soc.addMaster(mCpu, busInterfaceName: 'bus', channel: 'primary');
      soc.addMaster(mDma, busInterfaceName: 'bus', channel: 'dma');
      soc.addPeripheral(
        HarborSram(
          baseAddress: 0,
          size: 4096,
          busAddressWidth: 32,
          name: 'perA',
        ),
      );
      soc.addPeripheral(
        HarborSram(
          baseAddress: 0x1000,
          size: 4096,
          busAddressWidth: 32,
          name: 'mem',
        ),
      );
      soc.buildFabric(
        channelSlaves: {
          'primary': {'perA', 'mem'},
          'dma': {'mem'},
        },
      );

      // The dma channel reaches mem only, so it cannot route to perA. Both
      // channels meet at mem through its converge fabric.
      expect(_shape(soc), {
        'fabric_primary': 'cpu > perA mem',
        'fabric_dma': 'dma > mem',
        'converge_mem': 'primary dma > mem',
      });

      final clk = SimpleClockGenerator(10).clk;
      final resetL = Logic(name: 'reset')..inject(1);
      final startA = Logic(name: 'startA')..inject(0);
      final startB = Logic(name: 'startB')..inject(0);
      soc.input('clk').srcConnection! <= clk;
      soc.input('reset').srcConnection! <= resetL;
      mCpu.input('start').srcConnection! <= startA;
      mDma.input('start').srcConnection! <= startB;

      await soc.build();
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      resetL.inject(0);
      await clk.nextPosedge;
      startA.inject(1);
      startB.inject(1);
      await clk.nextPosedge;
      startA.inject(0);
      startB.inject(0);

      var guard = 0;
      while (guard++ < 500) {
        await clk.nextPosedge;
        if (mCpu.output('done').value.toBool() &&
            mDma.output('done').value.toBool()) {
          break;
        }
      }
      // Both channels reached mem through the convergence arbiter.
      expect(
        mCpu.output('done').value.toBool(),
        isTrue,
        reason: 'primary reached mem',
      );
      expect(
        mDma.output('done').value.toBool(),
        isTrue,
        reason: 'dma reached mem',
      );
      expect(mCpu.output('rdata').value.toInt(), equals(0xAAAA1111));
      expect(mDma.output('rdata').value.toInt(), equals(0xBBBB2222));
      await Simulator.endSimulation();
    },
  );

  test('channels on an explicit crossbar give one fabric with reach sets', () {
    const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
    final soc = HarborSoC(
      name: 'XbarSoC',
      compatible: 'test,xbar',
      fabricTopology: HarborFabricTopology.crossbar,
    );
    soc.addMaster(_RwMaster(cfg, 0, 0, name: 'cpu'), busInterfaceName: 'bus');
    soc.addMaster(
      _RwMaster(cfg, 0x1000, 0, name: 'dma'),
      busInterfaceName: 'bus',
      channel: 'dma',
    );
    soc.addPeripheral(
      HarborSram(baseAddress: 0, size: 4096, busAddressWidth: 32, name: 'perA'),
    );
    soc.addPeripheral(
      HarborSram(
        baseAddress: 0x1000,
        size: 4096,
        busAddressWidth: 32,
        name: 'mem',
      ),
    );
    soc.buildFabric(
      channelSlaves: {
        'primary': {'perA', 'mem'},
        'dma': {'mem'},
      },
    );
    final f = _fabric(soc);
    expect(soc.fabrics, hasLength(1));
    expect(f.topology, HarborFabricTopology.crossbar);
    expect(f.masters.map((m) => m.reach), [
      {'perA', 'mem'},
      {'mem'},
    ]);
  });

  test('busTimeoutCycles leaves memory out, a peripheral can set its own', () {
    const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
    final soc = HarborSoC(name: 'ToSoC', compatible: 'test,to');
    soc.addMaster(_RwMaster(cfg, 0, 0, name: 'cpu'), busInterfaceName: 'bus');
    soc.addPeripheral(
      HarborSram(baseAddress: 0, size: 4096, busAddressWidth: 32, name: 'ram'),
    );
    soc.addPeripheral(
      HarborGpio(baseAddress: 0x10000, busAddressWidth: 32, name: 'gpio'),
    );
    soc.addPeripheral(
      HarborGpio(baseAddress: 0x11000, busAddressWidth: 32, name: 'slow'),
      busTimeoutCycles: 500,
    );
    soc.addPeripheral(
      HarborSram(
        baseAddress: 0x20000,
        size: 4096,
        busAddressWidth: 32,
        name: 'ram2',
      ),
      busTimeoutCycles: 9,
    );
    soc.addPeripheral(
      HarborSdram(
        config: const HarborSdramConfig.as4c16m16sb6(),
        baseAddress: 0x40000000,
        clockHz: 125000000,
        busAddressWidth: 32,
        target: const HarborFpgaTarget.ecp5(
          device: 'LFE5U-85F',
          package: 'CABGA381',
        ),
        name: 'sdram',
      ),
    );
    soc.addPeripheral(
      HarborDdr3(
        config: const HarborDdrConfig.orangeCrab(),
        baseAddress: 0x80000000,
        clockHz: 48000000,
        busAddressWidth: 32,
        name: 'ddr',
      ),
    );
    soc.buildFabric(busTimeoutCycles: 64);
    expect(
      {for (final s in _fabric(soc).slaves) s.name: s.timeout},
      {'ram': 0, 'gpio': 64, 'slow': 500, 'ram2': 9, 'sdram': 0, 'ddr': 0},
    );
  });

  test('converge: dualport throws UnimplementedError', () {
    const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
    final soc = HarborSoC(name: 'DualportSoC', compatible: 'test,dualport');
    soc.addMaster(
      _RwMaster(cfg, 0x1020, 0, name: 'cpu'),
      busInterfaceName: 'bus',
      channel: 'primary',
    );
    soc.addMaster(
      _RwMaster(cfg, 0x1040, 0, name: 'dma'),
      busInterfaceName: 'bus',
      channel: 'dma',
    );
    soc.addPeripheral(
      HarborSram(baseAddress: 0, size: 4096, busAddressWidth: 32, name: 'perA'),
    );
    soc.addPeripheral(
      HarborSram(
        baseAddress: 0x1000,
        size: 4096,
        busAddressWidth: 32,
        name: 'mem',
      ),
    );
    expect(
      () => soc.buildFabric(
        channelSlaves: {
          'primary': {'perA', 'mem'},
          'dma': {'mem'},
        },
        converge: HarborMemConverge.dualport,
      ),
      throwsA(isA<UnimplementedError>()),
    );
  });

  test('converge: sharedDecode throws UnimplementedError', () {
    const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
    final soc = HarborSoC(
      name: 'SharedDecodeSoC',
      compatible: 'test,shareddecode',
    );
    soc.addMaster(
      _RwMaster(cfg, 0x1020, 0, name: 'cpu'),
      busInterfaceName: 'bus',
      channel: 'primary',
    );
    soc.addMaster(
      _RwMaster(cfg, 0x1040, 0, name: 'dma'),
      busInterfaceName: 'bus',
      channel: 'dma',
    );
    soc.addPeripheral(
      HarborSram(baseAddress: 0, size: 4096, busAddressWidth: 32, name: 'perA'),
    );
    soc.addPeripheral(
      HarborSram(
        baseAddress: 0x1000,
        size: 4096,
        busAddressWidth: 32,
        name: 'mem',
      ),
    );
    expect(
      () => soc.buildFabric(
        channelSlaves: {
          'primary': {'perA', 'mem'},
          'dma': {'mem'},
        },
        converge: HarborMemConverge.sharedDecode,
      ),
      throwsA(isA<UnimplementedError>()),
    );
  });

  test('a channel with masters absent from channelSlaves is an error', () {
    const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
    final soc = HarborSoC(
      name: 'MissingChannelSoC',
      compatible: 'test,missing',
    );
    soc.addMaster(
      _RwMaster(cfg, 0x20, 0, name: 'cpu'),
      busInterfaceName: 'bus',
      channel: 'primary',
    );
    soc.addMaster(
      _RwMaster(cfg, 0x1020, 0, name: 'dma'),
      busInterfaceName: 'bus',
      channel: 'dma',
    );
    soc.addPeripheral(
      HarborSram(baseAddress: 0, size: 4096, busAddressWidth: 32, name: 'perA'),
    );
    soc.addPeripheral(
      HarborSram(
        baseAddress: 0x1000,
        size: 4096,
        busAddressWidth: 32,
        name: 'perB',
      ),
    );
    // 'dma' has a master but is not in the map.
    expect(
      () => soc.buildFabric(
        channelSlaves: {
          'primary': {'perA', 'perB'},
        },
      ),
      throwsStateError,
    );
  });
}
