import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/eth_mdio_model.dart';

const _ins = {
  'start': 1,
  'write': 1,
  'phyad': 5,
  'regad': 5,
  'wdata': 16,
  'div': 8,
  'c45': 1,
  'devad': 5,
  'addr': 16,
};

class _Top extends Module {
  _Top(
    HarborEthernetConfig config,
    Logic clk,
    Logic reset,
    Logic mdioIn,
    Map<String, Logic> drv,
  ) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    Logic i(String n) => addInput(n, drv[n]!, width: _ins[n]!);
    final m = HarborEthMdio(
      clk,
      reset,
      config: config,
      start: i('start'),
      write: i('write'),
      phy: i('phyad'),
      reg: i('regad'),
      wdata: i('wdata'),
      div: i('div'),
      mdioIn: addInput('mdio_in', mdioIn),
      c45: config.mdioC45 ? i('c45') : null,
      devad: config.mdioC45 ? i('devad') : null,
      addr: config.mdioC45 ? i('addr') : null,
    );
    for (final n in ['busy', 'rdone', 'rdata', 'mdc', 'mdio_out', 'mdio_oe']) {
      addOutput(n, width: m.output(n).width) <= m.output(n);
    }
  }
}

class _Bench {
  final _Top top;
  final Logic clk;
  final Map<String, Logic> drv;
  final EthMdioPhy phy;
  _Bench(this.top, this.clk, this.drv, this.phy);

  static Future<_Bench> start({bool c45 = false, int div = 2}) async {
    final config = HarborEthernetConfig(phy: HarborEthPhy.mii, mdioC45: c45);
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final drv = {
      for (final e in _ins.entries) e.key: Logic(name: e.key, width: e.value),
    };
    final mdioIn = Logic(name: 'mdio_in_drv');
    final top = _Top(config, clk, reset, mdioIn, drv);
    final phy = EthMdioPhy(
      top.output('mdc'),
      top.output('mdio_out'),
      top.output('mdio_oe'),
    );
    mdioIn <= phy.mdioIn;
    await top.build();
    for (final l in drv.values) {
      l.inject(0);
    }
    drv['div']!.inject(div);
    reset.inject(1);
    phy.start();
    Simulator.setMaxSimTime(10000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 3; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    await clk.nextPosedge;
    return _Bench(top, clk, drv, phy);
  }

  bool get busy => top.output('busy').value.toBool();

  /// Starts one access and returns the cycles with busy high.
  Future<int> run({
    required bool write,
    int phy = 3,
    int reg = 0,
    int data = 0,
    bool c45 = false,
    int devad = 0,
    int addr = 0,
  }) async {
    await clk.nextNegedge;
    drv['write']!.inject(write ? 1 : 0);
    drv['phyad']!.inject(phy);
    drv['regad']!.inject(reg);
    drv['wdata']!.inject(data);
    drv['c45']!.inject(c45 ? 1 : 0);
    drv['devad']!.inject(devad);
    drv['addr']!.inject(addr);
    drv['start']!.inject(1);
    await clk.nextNegedge;
    drv['start']!.inject(0);
    // Inputs change while busy. The master must use the latched values.
    drv['wdata']!.inject(0);
    drv['regad']!.inject(0);
    var cycles = 0;
    while (busy) {
      cycles++;
      await clk.nextNegedge;
      if (cycles > 100000) throw StateError('busy does not end');
    }
    return cycles;
  }
}

List<int> _bits(int v, int w) => [
  for (var i = w - 1; i >= 0; i--) (v >> i) & 1,
];

void main() {
  tearDown(() async => Simulator.reset());

  test('a clause 22 write frame has the exact bits', () async {
    final b = await _Bench.start();
    await b.run(write: true, reg: 7, data: 0xABCD);
    expect(b.phy.frames, hasLength(1));
    expect(b.phy.frames.single.bits, [
      ..._bits(0xFFFFFFFF, 32),
      0, 1, // ST
      0, 1, // OP write
      ..._bits(3, 5),
      ..._bits(7, 5),
      1, 0, // TA
      ..._bits(0xABCD, 16),
    ]);
    expect(b.phy.c22[7], 0xABCD);
    expect(b.top.output('mdio_oe').value.toInt(), 0, reason: 'line released');
    await Simulator.endSimulation();
  });

  test('a clause 22 read releases the line and returns the data', () async {
    final b = await _Bench.start();
    b.phy.c22[2] = 0x1234;
    var released = false;
    var rdone = 0;
    b.clk.posedge.listen((_) {
      if (b.busy && b.top.output('mdio_oe').value.toInt() == 0) {
        released = true;
      }
      if (b.top.output('rdone').value.toBool()) rdone++;
    });
    await b.run(write: false, reg: 2);
    await b.clk.nextPosedge;
    final f = b.phy.frames.single;
    expect(f.st, 1);
    expect(f.op, 2);
    expect(f.ta, 2, reason: 'TA bit 1 floats high, bit 2 is the PHY 0');
    expect(released, isTrue);
    expect(b.phy.contention, 0);
    expect(b.phy.masterInRead, isEmpty);
    expect(rdone, 1);
    expect(b.top.output('rdata').value.toInt(), 0x1234);
    await Simulator.endSimulation();
  });

  for (final div in [0, 2, 9]) {
    test('busy and MDC timing with div $div', () async {
      final b = await _Bench.start(div: div);
      final rises = <int>[];
      var t = 0;
      var prev = 0;
      b.clk.posedge.listen((_) {
        t++;
        final m = b.top.output('mdc').value.toInt();
        if (m == 1 && prev == 0) rises.add(t);
        prev = m;
      });
      final cycles = await b.run(write: true, reg: 1, data: 0x5A5A);
      final half = div + 1;
      expect(cycles, 64 * 2 * half);
      expect(rises, hasLength(64));
      for (var i = 1; i < rises.length; i++) {
        expect(rises[i] - rises[i - 1], 2 * half);
      }
      expect(b.phy.c22[1], 0x5A5A);
      await Simulator.endSimulation();
    });
  }

  test('start while busy is ignored', () async {
    final b = await _Bench.start();
    await b.clk.nextNegedge;
    b.drv['write']!.inject(1);
    b.drv['regad']!.inject(4);
    b.drv['wdata']!.inject(0x1111);
    b.drv['start']!.inject(1);
    for (var i = 0; i < 20; i++) {
      await b.clk.nextNegedge;
    }
    b.drv['start']!.inject(0);
    while (b.busy) {
      await b.clk.nextNegedge;
    }
    for (var i = 0; i < 20; i++) {
      await b.clk.nextNegedge;
    }
    expect(b.phy.frames, hasLength(1));
    await Simulator.endSimulation();
  });

  test('clause 45 write then read', () async {
    final b = await _Bench.start(c45: true);
    final wc = await b.run(
      write: true,
      c45: true,
      devad: 1,
      addr: 0x0807,
      data: 0xBEEF,
    );
    expect(wc, 128 * 2 * 3, reason: 'two frames');
    expect(b.phy.frames, hasLength(2));
    final a = b.phy.frames[0];
    expect([a.st, a.op, a.phy, a.reg, a.ta, a.data], [0, 0, 3, 1, 2, 0x0807]);
    final w = b.phy.frames[1];
    expect([w.st, w.op, w.phy, w.reg, w.ta, w.data], [0, 1, 3, 1, 2, 0xBEEF]);
    expect(b.phy.c45[(1 << 16) | 0x0807], 0xBEEF);

    b.phy.c45[(7 << 16) | 0x003C] = 0x4321;
    await b.run(write: false, c45: true, devad: 7, addr: 0x003C);
    await b.clk.nextPosedge;
    final r = b.phy.frames[3];
    expect([r.st, r.op, r.phy, r.reg], [0, 3, 3, 7]);
    expect(b.phy.frames[2].data, 0x003C);
    expect(b.top.output('rdata').value.toInt(), 0x4321);
    expect(b.phy.contention, 0);
    expect(b.phy.masterInRead, isEmpty);
    await Simulator.endSimulation();
  });

  test('clause 22 still works with mdioC45 and c45 low', () async {
    final b = await _Bench.start(c45: true);
    b.phy.c22[5] = 0x0F0F;
    await b.run(write: false, reg: 5);
    await b.clk.nextPosedge;
    expect(b.phy.frames.single.st, 1);
    expect(b.top.output('rdata').value.toInt(), 0x0F0F);
    await Simulator.endSimulation();
  });

  test('without mdioC45 the module has no c45 ports', () {
    final m = HarborEthMdio(
      Logic(),
      Logic(),
      config: HarborEthernetConfig(phy: HarborEthPhy.rmii),
      start: Logic(),
      write: Logic(),
      phy: Logic(width: 5),
      reg: Logic(width: 5),
      wdata: Logic(width: 16),
      div: Logic(width: 8),
      mdioIn: Logic(),
    );
    expect(m.inputs.keys, isNot(contains('c45')));
    expect(m.inputs.keys, isNot(contains('addr')));
    expect(
      m.definitionName,
      isNot(
        HarborEthMdio(
          Logic(),
          Logic(),
          config: HarborEthernetConfig(phy: HarborEthPhy.rmii, mdioC45: true),
          start: Logic(),
          write: Logic(),
          phy: Logic(width: 5),
          reg: Logic(width: 5),
          wdata: Logic(width: 16),
          div: Logic(width: 8),
          mdioIn: Logic(),
          c45: Logic(),
          devad: Logic(width: 5),
          addr: Logic(width: 16),
        ).definitionName,
      ),
    );
  });
}
