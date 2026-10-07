import 'dart:async';

import 'package:harbor/src/peripherals/ddr3_config.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:harbor/src/peripherals/ddr3_phy_ecp5.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Simulates the fabric of [Ddr3PhyEcp5] with its clock tree model. The ECP5
/// IO cells have no model, so only the fabric around them is checked.
class _Bench {
  final DdrParams p = DdrParams.orangeCrab();
  late final Logic ck;
  late final Logic ctrlClk;
  final Logic rstN = Logic(name: 'rst_n')..inject(0);
  late final Logic data;
  late final Logic dm;
  late final Ddr3PhyEcp5 phy;

  /// [ctrlOffset] sets which CK edge the CK/4 clock starts on.
  _Bench({int ctrlOffset = 0, List<int>? dmRemapping, Logic? dmWord}) {
    ck = SimpleClockGenerator(2).clk;
    final divInit = Logic(name: 'div_init')..inject(1);
    Simulator.registerAction(2, () => divInit.put(0));
    final div = Logic(name: 'div', width: 2);
    Sequential(
      ck,
      reset: divInit,
      resetValues: {div: ctrlOffset},
      [div < div + 1],
    );
    ctrlClk = div[1];

    // The write data changes every CK/4 tick.
    final tick = Logic(name: 'tick', width: 8);
    Sequential(ctrlClk, [tick < tick + 1], reset: divInit);
    data = [for (var i = 0; i < p.wbDataBits ~/ 8; i++) tick].swizzle();
    dm = dmWord ?? Const(0, width: p.wbSelBits);

    final cmdLen = 4 + 3 + p.baBits + p.rowBits;
    Logic z(int w) => Const(0, width: w);
    phy = Ddr3PhyEcp5(
      p,
      controllerClk: ctrlClk,
      ddr3Clk: ck,
      refClk: z(1),
      ddr3Clk90: z(1),
      rstN: rstN,
      controllerReset: z(1),
      cmd: Const(-1, width: cmdLen * 4),
      dqsTriControl: z(1),
      dqTriControl: z(1),
      toggleDqs: z(1),
      data: data,
      dm: dm,
      odelayDataCntValueIn: z(5),
      odelayDqsCntValueIn: z(5),
      idelayDataCntValueIn: z(5),
      idelayDqsCntValueIn: z(5),
      odelayDataLd: z(p.lanes),
      odelayDqsLd: z(p.lanes),
      idelayDataLd: z(p.lanes),
      idelayDqsLd: z(p.lanes),
      bitslip: z(p.lanes),
      writeLevelingCalib: z(1),
      readLevelStart: z(1),
      readLevelCheck: z(1),
      readLevelPass: z(p.lanes),
      dqPad: LogicNet(width: p.dqBits * p.lanes),
      dqsPad: LogicNet(width: p.lanes),
      dqsNPad: LogicNet(width: p.lanes),
      dmRemapping: dmRemapping,
    );
  }

  Logic sub(String module, String port) =>
      phy.subModules.firstWhere((m) => m.name == module).output(port);

  Logic signal(String name) => phy.signals.firstWhere((s) => s.name == name);
}

void main() {
  tearDown(() async => Simulator.reset());

  // Returns the CK/2 capture offsets after the CK/4 edge, in sim time units.
  Future<({Set<int> offsets, int changesBeforeDone})> regearPhase(
    int ctrlOffset,
    int releaseCycle,
  ) async {
    final b = _Bench(ctrlOffset: ctrlOffset);
    await b.phy.build();
    final full = b.sub('data_tx_regear', 'o_full');
    var lastCtrlRise = -1;
    var initDone = false;
    final offsets = <int>{};
    var changesBeforeDone = 0;
    b.ctrlClk.posedge.listen((_) => lastCtrlRise = Simulator.time);
    b.phy.idelayctrlRdy.changed.listen((_) {
      if (b.phy.idelayctrlRdy.value == LogicValue.one) initDone = true;
    });
    full.changed.listen((_) {
      if (!initDone) {
        if (Simulator.time > 20) changesBeforeDone++;
        return;
      }
      offsets.add(Simulator.time - lastCtrlRise);
    });
    Simulator.setMaxSimTime(20000);
    unawaited(Simulator.run());
    for (var i = 0; i < releaseCycle; i++) {
      await b.ck.nextPosedge;
    }
    b.rstN.inject(1);
    for (var i = 0; i < 400 && !initDone; i++) {
      await b.ctrlClk.nextPosedge;
    }
    expect(initDone, isTrue);
    for (var i = 0; i < 30; i++) {
      await b.ctrlClk.nextPosedge;
    }
    await Simulator.endSimulation();
    await Simulator.reset();
    return (offsets: offsets, changesBeforeDone: changesBeforeDone);
  }

  test('the regear is held until the init timeline is done, then always '
      'captures on the CK/2 edge between two CK/4 edges', () async {
    for (final ctrlOffset in [0, 2]) {
      final seen = <String>[];
      for (final release in [7, 8, 9, 10]) {
        final r = await regearPhase(ctrlOffset, release);
        expect(r.changesBeforeDone, 0, reason: 'regear ran before init done');
        // CK period 2, so a CK/4 tick is 8. The coincident CK/2 edge is at
        // +1 in this model, the middle one at +5.
        expect(r.offsets, {5}, reason: 'offset $ctrlOffset release $release');
        seen.add(r.offsets.toString());
      }
      expect(seen.toSet().length, 1);
    }
  });

  group('DM remapping', () {
    // Lane 1 masked on every beat, lane 0 written: dm[l + lanes * b].
    final lane1Masked = Const(0xAAAA, width: 16);

    Future<List<int>> dmPadBeats(List<int>? remap) async {
      final b = _Bench(dmRemapping: remap, dmWord: lane1Masked);
      await b.phy.build();
      Simulator.setMaxSimTime(20000);
      unawaited(Simulator.run());
      for (var i = 0; i < 8; i++) {
        await b.ck.nextPosedge;
      }
      b.rstN.inject(1);
      for (
        var i = 0;
        i < 400 && b.phy.idelayctrlRdy.value != LogicValue.one;
        i++
      ) {
        await b.ctrlClk.nextPosedge;
      }
      expect(b.phy.idelayctrlRdy.value, LogicValue.one);
      for (var i = 0; i < 6; i++) {
        await b.ctrlClk.nextPosedge;
      }
      final beats = [
        for (var l = 0; l < 2; l++) b.signal('dm_${l}_o_data').value.toInt(),
      ];
      await Simulator.endSimulation();
      return beats;
    }

    test(
      'the OrangeCrab config carries litex-boards dm_remapping {0:1, 1:0}',
      () {
        expect(const HarborDdrConfig.orangeCrab().dmRemapping, [1, 0]);
      },
    );

    test('a byte-masked write masks the right byte on each DM pad', () async {
      // OrangeCrab: pad 0 (DQS group 0) carries lane 1's mask.
      final crossed = await dmPadBeats(
        const HarborDdrConfig.orangeCrab().dmRemapping,
      );
      expect(crossed, [0xFF, 0x00]);
      await Simulator.reset();
      // The identity mapping would mask lane 0 on that board instead.
      final straight = await dmPadBeats(null);
      expect(straight, [0x00, 0xFF]);
      expect(straight, isNot(crossed));
    });
  });

  test('the command pipe idles as a deselect until the PHY is ready', () async {
    final b = _Bench();
    await b.phy.build();
    final cmdLen = 4 + 3 + b.p.baBits + b.p.rowBits;
    final slot = 0xF << (cmdLen - 4);
    final idle = slot | (slot << cmdLen);
    Simulator.setMaxSimTime(20000);
    unawaited(Simulator.run());
    for (var i = 0; i < 8; i++) {
      await b.ck.nextPosedge;
    }
    b.rstN.inject(1);
    var samples = 0;
    for (
      var i = 0;
      i < 400 && b.phy.idelayctrlRdy.value != LogicValue.one;
      i++
    ) {
      await b.ctrlClk.nextPosedge;
      expect(b.signal('cmd_half_d2').value.toInt(), idle);
      samples++;
    }
    await Simulator.endSimulation();
    expect(samples, greaterThan(50));
  });
}
