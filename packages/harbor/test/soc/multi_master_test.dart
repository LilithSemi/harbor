// HarborSoC.buildFabric multi-master support: when >1 master is added, the
// fabric inserts a WishboneArbiter (round-robin, grant-locked) merging them
// onto the single decoder/peripheral fabric. Here we verify it elaborates and
// emits the arbiter in the generated RTL.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

/// Minimal Wishbone master: a provider 'bus' interface tied idle. Enough to
/// exercise fabric composition (the arbiter's behaviour is covered elsewhere).
class _IdleMaster extends BridgeModule {
  _IdleMaster(WishboneConfig cfg, {String? name})
    : super('IdleMaster', name: name ?? 'idle_master') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final bus =
        addInterface(
              WishboneInterface(cfg),
              name: 'bus',
              role: PairRole.provider,
            ).internalInterface
            as WishboneInterface;
    bus.cyc <= Const(0);
    bus.stb <= Const(0);
    bus.we <= Const(0);
    bus.adr <= Const(0, width: cfg.addressWidth);
    bus.datMosi <= Const(0, width: cfg.dataWidth);
    bus.sel <= Const(0, width: cfg.effectiveSelWidth);
  }
}

/// Wishbone master that, on `start`, writes `value` to `addr` then reads it
/// back, latching the result on `rdata` and asserting `done`. Used to exercise
/// two masters contending on a shared peripheral through the arbiter.
class _RwMaster extends BridgeModule {
  _RwMaster(WishboneConfig cfg, int addr, int value, {String? name})
    : super(
        cfg.useErr ? 'RwMaster_${name ?? "default"}' : 'RwMaster',
        name: name ?? 'rw_master',
      ) {
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
    if (cfg.useErr) addOutput('error') <= bus.err!;
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  for (final topology in ['single', 'private', 'shared']) {
    for (final pipeline in [false, true]) {
      test(
        'ACK-only slaves have defined ERR: $topology pipeline=$pipeline',
        () async {
          const cfg = WishboneConfig(
            addressWidth: 32,
            dataWidth: 32,
            useErr: true,
          );
          final soc = HarborSoC(
            name: 'ErrorSoC',
            compatible: 'test,error',
            busConfig: cfg,
          );
          final a = _RwMaster(cfg, 0x20, 0x12345678, name: 'cpu');
          final b = _RwMaster(
            cfg,
            topology == 'private' ? 0x1040 : 0x40,
            0x76543210,
            name: 'dma',
          );
          soc.addMaster(a, busInterfaceName: 'bus');
          if (topology != 'single') {
            soc.addMaster(b, busInterfaceName: 'bus', channel: 'dma');
          }
          soc.addPeripheral(
            HarborSram(
              baseAddress: 0,
              size: 4096,
              busAddressWidth: 32,
              name: 'ram_a',
            ),
          );
          if (topology == 'private') {
            // Give the private decoders different slave counts so this fixture
            // does not collide on ROHD's reserved WishboneDecoder_S1 name.
            soc.addPeripheral(
              HarborSram(
                baseAddress: 8192,
                size: 4096,
                busAddressWidth: 32,
                name: 'spare',
              ),
            );
            soc.addPeripheral(
              HarborSram(
                baseAddress: 4096,
                size: 4096,
                busAddressWidth: 32,
                name: 'ram_b',
              ),
            );
          }
          soc.buildFabric(
            pipeline: pipeline,
            channelSlaves: topology == 'single'
                ? null
                : {
                    'primary': {'ram_a', if (topology == 'private') 'spare'},
                    'dma': {topology == 'private' ? 'ram_b' : 'ram_a'},
                  },
          );
          final clk = SimpleClockGenerator(10).clk;
          final reset = Logic()..inject(1);
          final start = Logic()..inject(0);
          soc.input('clk').srcConnection! <= clk;
          soc.input('reset').srcConnection! <= reset;
          final masters = [a, if (topology != 'single') b];
          for (final master in masters) {
            master.input('start').srcConnection! <= start;
          }
          await soc.build();
          // Also exercise RTL generation, not only ROHD evaluation.
          final rtl = soc.generateSynth();
          Simulator.setMaxSimTime(10000);
          unawaited(Simulator.run());
          try {
            await clk.nextNegedge;
            await clk.nextNegedge;
            reset.inject(0);
            start.inject(1);
            await clk.nextNegedge;
            start.inject(0);
            var completed = false;
            for (var i = 0; i < 200; i++) {
              await clk.nextNegedge;
              for (final master in masters) {
                expect(
                  master.output('error').value,
                  LogicValue.zero,
                  reason: 'ACK-only peripheral must not leave ERR floating',
                );
              }
              if (masters.every((m) => m.output('done').value.toBool())) {
                completed = true;
                break;
              }
            }
            expect(completed, isTrue);
            expect(
              rtl,
              contains(
                topology == 'shared'
                    ? ".slave_ERR(1'h0)"
                    : ".slave_0_ERR(1'h0)",
              ),
            );
            expect(a.output('rdata').value.toInt(), 0x12345678);
            if (topology != 'single') {
              expect(b.output('rdata').value.toInt(), 0x76543210);
            }
          } finally {
            await Simulator.endSimulation();
            await Simulator.simulationEnded;
          }
        },
      );
    }
  }

  test('buildFabric inserts a WishboneArbiter for >1 master', () async {
    const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
    final soc = HarborSoC(
      name: 'MultiMasterSoC',
      compatible: 'test,multimaster',
      busConfig: cfg,
    );

    soc.addMaster(_IdleMaster(cfg, name: 'm_a'), busInterfaceName: 'bus');
    soc.addMaster(_IdleMaster(cfg, name: 'm_b'), busInterfaceName: 'bus');
    soc.addPeripheral(
      HarborSram(baseAddress: 0, size: 4096, busAddressWidth: 32),
    );

    soc.buildFabric();
    await soc.build();

    final sv = soc.generateSynth();
    expect(sv, contains('WishboneArbiter_M2'));
    expect(sv, contains('WishboneDecoder'));
  });

  test('single master uses the decoder directly (no arbiter)', () async {
    const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
    final soc = HarborSoC(
      name: 'SingleMasterSoC',
      compatible: 'test,singlemaster',
      busConfig: cfg,
    );
    soc.addMaster(_IdleMaster(cfg, name: 'm_only'), busInterfaceName: 'bus');
    soc.addPeripheral(
      HarborSram(baseAddress: 0, size: 4096, busAddressWidth: 32),
    );
    soc.buildFabric();
    await soc.build();

    final sv = soc.generateSynth();
    expect(sv, contains('WishboneDecoder'));
    expect(sv, isNot(contains('WishboneArbiter')));
  });

  test('two masters contend on a shared SRAM and both complete', () async {
    const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
    final soc = HarborSoC(
      name: 'ContendSoC',
      compatible: 'test,contend',
      busConfig: cfg,
    );
    // Distinct words in the SRAM (word stride 4): 0x20 and 0x40.
    final mA = _RwMaster(cfg, 0x20, 0xAAAA1111, name: 'm_a');
    final mB = _RwMaster(cfg, 0x40, 0xBBBB2222, name: 'm_b');
    soc.addMaster(mA, busInterfaceName: 'bus');
    soc.addMaster(mB, busInterfaceName: 'bus');
    soc.addPeripheral(
      HarborSram(baseAddress: 0, size: 4096, busAddressWidth: 32),
    );
    soc.buildFabric();

    final clk = SimpleClockGenerator(10).clk;
    final resetL = Logic(name: 'reset')..inject(1);
    final startA = Logic(name: 'startA')..inject(0);
    final startB = Logic(name: 'startB')..inject(0);
    soc.input('clk').srcConnection! <= clk;
    soc.input('reset').srcConnection! <= resetL;
    mA.input('start').srcConnection! <= startA;
    mB.input('start').srcConnection! <= startB;

    await soc.build();
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    resetL.inject(0);
    await clk.nextPosedge;

    // Kick both masters on the SAME cycle -> they contend every transaction.
    startA.inject(1);
    startB.inject(1);
    await clk.nextPosedge;
    startA.inject(0);
    startB.inject(0);

    var guard = 0;
    while (guard++ < 500) {
      await clk.nextPosedge;
      if (mA.output('done').value.toBool() &&
          mB.output('done').value.toBool()) {
        break;
      }
    }
    expect(
      mA.output('done').value.toBool(),
      isTrue,
      reason: 'A done (no livelock)',
    );
    expect(
      mB.output('done').value.toBool(),
      isTrue,
      reason: 'B done (no livelock)',
    );
    expect(mA.output('rdata').value.toInt(), equals(0xAAAA1111));
    expect(mB.output('rdata').value.toInt(), equals(0xBBBB2222));
    await Simulator.endSimulation();
  });

  test('pipelined single-master fabric round-trips a write+read', () async {
    const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
    final soc = HarborSoC(
      name: 'PipeSingleSoC',
      compatible: 'test,pipe1',
      busConfig: cfg,
    );
    final m = _RwMaster(cfg, 0x30, 0xC0DECAFE, name: 'm');
    soc.addMaster(m, busInterfaceName: 'bus');
    soc.addPeripheral(
      HarborSram(baseAddress: 0, size: 4096, busAddressWidth: 32),
    );
    soc.buildFabric(pipeline: true);

    final clk = SimpleClockGenerator(10).clk;
    final resetL = Logic(name: 'reset')..inject(1);
    final start = Logic(name: 'start')..inject(0);
    soc.input('clk').srcConnection! <= clk;
    soc.input('reset').srcConnection! <= resetL;
    m.input('start').srcConnection! <= start;

    await soc.build();
    // The register slice must actually be in the netlist.
    expect(soc.generateSynth(), contains('WishboneRegisterStage'));

    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    resetL.inject(0);
    await clk.nextPosedge;
    start.inject(1);
    await clk.nextPosedge;
    start.inject(0);

    var guard = 0;
    while (guard++ < 500) {
      await clk.nextPosedge;
      if (m.output('done').value.toBool()) break;
    }
    expect(
      m.output('done').value.toBool(),
      isTrue,
      reason: 'completed through the register slice',
    );
    expect(m.output('rdata').value.toInt(), equals(0xC0DECAFE));
    await Simulator.endSimulation();
  });

  test('pipelined two-master fabric: both contend and complete', () async {
    const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
    final soc = HarborSoC(
      name: 'PipeContendSoC',
      compatible: 'test,pipe2',
      busConfig: cfg,
    );
    final mA = _RwMaster(cfg, 0x20, 0xAAAA1111, name: 'm_a');
    final mB = _RwMaster(cfg, 0x40, 0xBBBB2222, name: 'm_b');
    soc.addMaster(mA, busInterfaceName: 'bus');
    soc.addMaster(mB, busInterfaceName: 'bus');
    soc.addPeripheral(
      HarborSram(baseAddress: 0, size: 4096, busAddressWidth: 32),
    );
    soc.buildFabric(pipeline: true);

    final clk = SimpleClockGenerator(10).clk;
    final resetL = Logic(name: 'reset')..inject(1);
    final startA = Logic(name: 'startA')..inject(0);
    final startB = Logic(name: 'startB')..inject(0);
    soc.input('clk').srcConnection! <= clk;
    soc.input('reset').srcConnection! <= resetL;
    mA.input('start').srcConnection! <= startA;
    mB.input('start').srcConnection! <= startB;

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
      if (mA.output('done').value.toBool() &&
          mB.output('done').value.toBool()) {
        break;
      }
    }
    expect(
      mA.output('done').value.toBool(),
      isTrue,
      reason: 'A done (pipelined)',
    );
    expect(
      mB.output('done').value.toBool(),
      isTrue,
      reason: 'B done (pipelined)',
    );
    expect(mA.output('rdata').value.toInt(), equals(0xAAAA1111));
    expect(mB.output('rdata').value.toInt(), equals(0xBBBB2222));
    await Simulator.endSimulation();
  });
}
