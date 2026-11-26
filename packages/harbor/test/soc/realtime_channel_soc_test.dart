// Channel mode SoCs keep the real-time flag: the channel fabric marks the
// real-time master, and the converge fabric in front of a shared slave marks
// the leg of its channel, so a real-time access wins at both.

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

// Cycles after the start at which each master is done, with the master of
// the dma channel real-time or not.
Future<(int, int)> _run(bool rt) async {
  const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
  final soc = HarborSoC(
    name: 'RtChannelSoC${rt ? 'On' : 'Off'}',
    compatible: 'test,rt',
  );
  final mCpu = _RwMaster(cfg, 0x1020, 0xAAAA1111, name: 'cpu');
  final mDma = _RwMaster(cfg, 0x1040, 0xBBBB2222, name: 'dma');
  soc.addMaster(mCpu, busInterfaceName: 'bus', channel: 'primary');
  soc.addMaster(mDma, busInterfaceName: 'bus', channel: 'dma', realtime: rt);
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
  // The flag reaches the channel fabric and the leg to the converge fabric.
  bool anyRt(String n) => switch (soc.fabrics.firstWhere((f) => f.name == n)) {
    final HarborWishboneFabric f => f.masters.any((m) => m.realtime),
    _ => throw StateError(n),
  };
  expect(anyRt('fabric_dma'), rt);
  expect(anyRt('fabric_primary'), isFalse);
  expect(anyRt('converge_mem'), rt);

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
  var cpuAt = -1;
  var dmaAt = -1;
  for (var i = 0; i < 500 && (cpuAt < 0 || dmaAt < 0); i++) {
    await clk.nextPosedge;
    if (cpuAt < 0 && mCpu.output('done').value.toBool()) cpuAt = i;
    if (dmaAt < 0 && mDma.output('done').value.toBool()) dmaAt = i;
  }
  expect(mCpu.output('rdata').value.toInt(), 0xAAAA1111);
  expect(mDma.output('rdata').value.toInt(), 0xBBBB2222);
  await Simulator.endSimulation();
  return (cpuAt, dmaAt);
}

void main() {
  tearDown(() async => Simulator.reset());

  test('a real-time master in a channel wins at the converge fabric', () async {
    final (cpu, dma) = await _run(true);
    expect(dma, lessThan(cpu), reason: 'dma $dma cpu $cpu');
  });

  test('without the flag the other channel goes first', () async {
    final (cpu, dma) = await _run(false);
    expect(cpu, lessThan(dma), reason: 'dma $dma cpu $cpu');
  });
}
