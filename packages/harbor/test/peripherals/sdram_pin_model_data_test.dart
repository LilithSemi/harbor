import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_pin_model.dart';

/// A tiny controller-side pin driver: it owns every sdram pin, plus its own
/// TriStateBuffer onto the dq net standing in for the fpga, and changes pins
/// on `clk` negedges so every edge sees a stable setup/hold margin.
class _Driver {
  _Driver(this.clk) {
    dq <= TriStateBuffer(dqDrv, enable: dqEn, name: 'fpga_dq').out;
    Simulator.injectAction(() {
      dqDrv.put(0);
      dqEn.put(0);
    });
  }

  final Logic clk;
  final Logic cke = Logic(name: 'cke')..inject(0);
  final Logic csN = Logic(name: 'cs_n')..inject(1);
  final Logic rasN = Logic(name: 'ras_n')..inject(1);
  final Logic casN = Logic(name: 'cas_n')..inject(1);
  final Logic weN = Logic(name: 'we_n')..inject(1);
  final Logic ba = Logic(name: 'ba', width: 2)..inject(0);
  final Logic addr = Logic(name: 'addr', width: 13)..inject(0);
  final Logic dqm = Logic(name: 'dqm', width: 2)..inject(0);
  final LogicNet dq = LogicNet(name: 'dq', width: 16);
  final Logic dqDrv = Logic(name: 'fpga_dq_drv', width: 16);
  final Logic dqEn = Logic(name: 'fpga_dq_en');

  Future<void> _issue(
    int cmd3, {
    int bank = 0,
    int a = 0,
    int cke = 1,
    int? data,
    int? dqmBits,
  }) async {
    await clk.nextNegedge;
    rasN.put((cmd3 >> 2) & 1);
    casN.put((cmd3 >> 1) & 1);
    weN.put(cmd3 & 1);
    csN.put(0);
    ba.put(bank);
    addr.put(a);
    this.cke.put(cke);
    if (dqmBits != null) dqm.put(dqmBits);
    if (data != null) {
      dqDrv.put(data);
      dqEn.put(1);
    } else {
      dqEn.put(0);
    }
    await clk.nextPosedge;
  }

  Future<void> nop({int cke = 1}) => _issue(7, cke: cke);
  Future<void> prechargeAll() => _issue(2, a: 1 << 10);
  Future<void> precharge(int bank) => _issue(2, bank: bank);
  Future<void> mrs(int word) => _issue(0, a: word);
  Future<void> refresh() => _issue(1);
  Future<void> activate(int bank, int row) => _issue(3, bank: bank, a: row);
  Future<void> read(int bank, int col) => _issue(5, bank: bank, a: col);

  Future<void> write(int bank, int col, int data, {int dqmBits = 0}) =>
      _issue(4, bank: bank, a: col, data: data, dqmBits: dqmBits);

  /// Holds dqm at the next edge without issuing a command (stays nop).
  Future<void> setDqm(int bits) => _issue(7, dqmBits: bits);

  Future<void> waitEdges(int n) async {
    for (var i = 0; i < n; i++) {
      await nop();
    }
  }
}

Future<void> _powerUp(_Driver d, int periodPs, double powerUpNs) async {
  final cycles = ((powerUpNs * 1000) / periodPs).ceil() + 2;
  for (var i = 0; i < cycles; i++) {
    await d.nop(cke: 0);
  }
  await d.nop(cke: 1);
}

int _ceilCycles(double ns, int periodPs) => (ns * 1000 / periodPs).ceil();

(_Driver, SdramPinModel) _buildRig(
  int periodPs, {
  bool withFpgaSignals = true,
}) {
  const rules = SdramModelRules.as4c16m16sb6();
  final clk = SimpleClockGenerator(periodPs).clk;
  final d = _Driver(clk);
  final model = SdramPinModel(
    clk: clk,
    cke: d.cke,
    csN: d.csN,
    rasN: d.rasN,
    casN: d.casN,
    weN: d.weN,
    ba: d.ba,
    addr: d.addr,
    dqm: d.dqm,
    dq: d.dq,
    rules: rules.copyWith(powerUpNs: 2000),
    fpgaDqOe: withFpgaSignals ? d.dqEn : null,
    fpgaDqOut: withFpgaSignals ? d.dqDrv : null,
  );
  return (d, model);
}

Future<void> _initToReady(
  _Driver d,
  int mrsWord,
  int periodPs,
  SdramModelRules rules,
) async {
  await _powerUp(d, periodPs, rules.powerUpNs);
  await d.prechargeAll();
  await d.waitEdges(_ceilCycles(rules.tRp, periodPs));
  await d.mrs(mrsWord);
  final mrdCycles = _ceilCycles(rules.tMrd, periodPs);
  await d.waitEdges(mrdCycles > rules.tMrdNck ? mrdCycles : rules.tMrdNck);
  await d.refresh();
  await d.waitEdges(_ceilCycles(rules.tRfc, periodPs));
  await d.refresh();
  await d.waitEdges(_ceilCycles(rules.tRfc, periodPs));
}

const _dPs = 5100;

/// The exact drive-timeline formula the model uses, duplicated here so the
/// test can pick times inside and outside the valid window on purpose: tAC
/// counts from the edge before `edgePs`, tOH from `edgePs` itself (fig 20,
/// p24).
(int, int) _validWindowPs(
  SdramModelRules rules,
  int cl,
  int edgePs,
  int periodPs,
) {
  final tAcPs = (rules.tAcByCl[cl]! * 1000).round();
  final tOhPs = (rules.tOh * 1000).round();
  return (edgePs - periodPs + _dPs + tAcPs, edgePs + _dPs + tOhPs);
}

/// The window a one-cycle-late read would have used (tAC and tOH both
/// counted from `edgePs`, with no shift back by one period). Sampling here
/// proves the model is not making that mistake: the value shown must not
/// be this beat's own data any more.
(int, int) _oneCycleLateWindowPs(
  SdramModelRules rules,
  int cl,
  int edgePs,
  int periodPs,
) {
  final tAcPs = (rules.tAcByCl[cl]! * 1000).round();
  final tOhPs = (rules.tOh * 1000).round();
  return (edgePs + _dPs + tAcPs, edgePs + periodPs + _dPs + tOhPs);
}

/// Samples dq mid-window for the beat at [edgePs] and asserts it reads
/// [expected], so a legal run proves the data and its order, not just that
/// it ran error-free.
void _sampleBeat(
  _Driver d,
  SdramModelRules rules,
  int cl,
  int periodPs,
  int edgePs,
  int expected,
) {
  final (validStart, validEnd) = _validWindowPs(rules, cl, edgePs, periodPs);
  Simulator.registerAction((validStart + validEnd) ~/ 2, () {
    expect(
      d.dq.value.isValid,
      isTrue,
      reason: 'beat at $edgePs should be valid',
    );
    expect(
      d.dq.value.toInt(),
      expected,
      reason: 'beat at $edgePs data mismatch',
    );
  });
}

void main() {
  tearDown(() async => Simulator.reset());

  Future<void> runCase(int periodPs, int cl, int mrsWord) async {
    const rules = SdramModelRules.as4c16m16sb6();
    final clk = SimpleClockGenerator(periodPs).clk;
    final d = _Driver(clk);
    final model = SdramPinModel(
      clk: clk,
      cke: d.cke,
      csN: d.csN,
      rasN: d.rasN,
      casN: d.casN,
      weN: d.weN,
      ba: d.ba,
      addr: d.addr,
      dqm: d.dqm,
      dq: d.dq,
      rules: rules.copyWith(powerUpNs: 2000),
      fpgaDqOe: d.dqEn,
      fpgaDqOut: d.dqDrv,
    );

    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());

    await _initToReady(d, mrsWord, periodPs, rules.copyWith(powerUpNs: 2000));
    expect(model.initDone, isTrue);

    await d.activate(0, 5);
    await d.waitEdges(_ceilCycles(rules.tRcd, periodPs));

    await d.write(0, 0, 0x1111);
    await d.write(0, 1, 0x2222, dqmBits: 1);
    await d.write(0, 2, 0x3333, dqmBits: 2);
    await d.write(0, 3, 0x4444, dqmBits: 3);
    await d.setDqm(0); // dqm is sticky: drop the mask before the read below.
    await d.waitEdges(_ceilCycles(rules.tWr, periodPs));

    expect(model.peek(0, 5, 0), 0x1111);
    expect(
      model.peek(0, 5, 1),
      (SdramPinModel.initialWord(0, 5, 1) & 0x00FF) | 0x2200,
    );
    expect(
      model.peek(0, 5, 2),
      (SdramPinModel.initialWord(0, 5, 2) & 0xFF00) | 0x0033,
    );
    expect(model.peek(0, 5, 3), SdramPinModel.initialWord(0, 5, 3));

    await d.precharge(0);
    await d.waitEdges(_ceilCycles(rules.tRp, periodPs));
    await d.activate(0, 5);
    await d.waitEdges(_ceilCycles(rules.tRcd, periodPs));

    await d.read(0, 5);
    final readAt = Simulator.time;
    final firstBeatEdge = readAt + cl * periodPs;
    final expectedOrder = [5, 6, 7, 0, 1, 2, 3, 4];
    for (var k = 0; k < 8; k++) {
      final edge = firstBeatEdge + k * periodPs;
      final expected = model.peek(0, 5, expectedOrder[k]);
      final (validStart, validEnd) = _validWindowPs(rules, cl, edge, periodPs);
      final sampleAt = (validStart + validEnd) ~/ 2;
      Simulator.registerAction(sampleAt, () {
        expect(
          d.dq.value.isValid,
          isTrue,
          reason: 'beat $k should be valid inside its window',
        );
        expect(d.dq.value.toInt(), expected, reason: 'beat $k data mismatch');
      });
      final outsideAt = validEnd + 400;
      Simulator.registerAction(outsideAt, () {
        expect(
          d.dq.value.isValid,
          isFalse,
          reason:
              'beat $k should read X (or z, once released) outside its window',
        );
      });
      // A one-cycle-late sample (the window this beat would have used
      // before the fig 20 fix) must not still read this beat's own value.
      final (lateStart, lateEnd) = _oneCycleLateWindowPs(
        rules,
        cl,
        edge,
        periodPs,
      );
      Simulator.registerAction((lateStart + lateEnd) ~/ 2, () {
        if (d.dq.value.isValid) {
          expect(
            d.dq.value.toInt(),
            isNot(expected),
            reason: 'beat $k should not still be showing one cycle late',
          );
        }
      });
    }
    await d.waitEdges(10);

    model.finish();
    await Simulator.endSimulation();
    expect(model.errors, isEmpty, reason: model.errors.join('\n'));
  }

  test(
    'legal traffic at 125 MHz CL3: init, dqm writes, BL8 wrap read',
    () async {
      await runCase(8000, 3, 0x233);
    },
  );

  test(
    'legal traffic at 100 MHz CL2: init, dqm writes, BL8 wrap read',
    () async {
      await runCase(10000, 2, 0x223);
    },
  );

  test('a precharge cuts a read burst at p + CL - 1', () async {
    const rules = SdramModelRules.as4c16m16sb6();
    const periodPs = 8000;
    const cl = 3;
    final clk = SimpleClockGenerator(periodPs).clk;
    final d = _Driver(clk);
    final model = SdramPinModel(
      clk: clk,
      cke: d.cke,
      csN: d.csN,
      rasN: d.rasN,
      casN: d.casN,
      weN: d.weN,
      ba: d.ba,
      addr: d.addr,
      dqm: d.dqm,
      dq: d.dq,
      rules: rules.copyWith(powerUpNs: 2000),
      fpgaDqOe: d.dqEn,
      fpgaDqOut: d.dqDrv,
    );

    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());

    await _initToReady(d, 0x233, periodPs, rules.copyWith(powerUpNs: 2000));
    await d.activate(0, 5);
    await d.waitEdges(_ceilCycles(rules.tRcd, periodPs));
    await d.read(0, 0);
    final readAt = Simulator.time;
    final firstBeatEdge = readAt + cl * periodPs;

    // Wait past tRAS min, then precharge two beats into the burst.
    await d.waitEdges(2);
    await d.precharge(0);
    final pEdge = Simulator.time;
    final lastBeatEdge = pEdge + cl * periodPs - periodPs;

    final (validStart, validEnd) = _validWindowPs(
      rules,
      cl,
      lastBeatEdge,
      periodPs,
    );
    Simulator.registerAction((validStart + validEnd) ~/ 2, () {
      expect(d.dq.value.isValid, isTrue);
    });
    final nextBeatEdge = lastBeatEdge + periodPs;
    if (nextBeatEdge < firstBeatEdge + 8 * periodPs) {
      Simulator.registerAction(nextBeatEdge + periodPs, () {
        expect(
          d.dq.value.isFloating,
          isTrue,
          reason: 'burst should be released after the cut',
        );
      });
    }

    await d.waitEdges(_ceilCycles(rules.tRp, periodPs) + 2);
    model.finish();
    await Simulator.endSimulation();
    expect(model.errors, isEmpty, reason: model.errors.join('\n'));
  });

  test(
    'legal traffic: a read interrupted by a read gives zero errors',
    () async {
      const rules = SdramModelRules.as4c16m16sb6();
      const periodPs = 8000;
      const cl = 3;
      final (d, model) = _buildRig(periodPs);

      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());

      await _initToReady(d, 0x233, periodPs, rules.copyWith(powerUpNs: 2000));
      await d.activate(0, 5);
      await d.waitEdges(_ceilCycles(rules.tRcd, periodPs));
      await d.read(0, 0); // fig 5, p9: a read one edge later takes over.
      final firstBeatEdge = Simulator.time + cl * periodPs;
      await d.waitEdges(1);
      await d.read(0, 4);
      final secondBeatEdge = Simulator.time + cl * periodPs;

      // Only the old read's first beat (col 0) survives before the new
      // read's own first beat (col 4) takes over, in BL8 wrap order.
      _sampleBeat(d, rules, cl, periodPs, firstBeatEdge, model.peek(0, 5, 0));
      const newOrder = [4, 5, 6, 7, 0, 1, 2, 3];
      for (var k = 0; k < 8; k++) {
        _sampleBeat(
          d,
          rules,
          cl,
          periodPs,
          secondBeatEdge + k * periodPs,
          model.peek(0, 5, newOrder[k]),
        );
      }
      await d.waitEdges(cl + 9);

      model.finish();
      await Simulator.endSimulation();
      expect(model.errors, isEmpty, reason: model.errors.join('\n'));
    },
  );

  test(
    'legal traffic: a read-to-write turnaround with dqm first gives zero errors',
    () async {
      const rules = SdramModelRules.as4c16m16sb6();
      const periodPs = 8000;
      final (d, model) = _buildRig(periodPs);

      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());

      await _initToReady(d, 0x233, periodPs, rules.copyWith(powerUpNs: 2000));
      await d.activate(0, 5);
      await d.waitEdges(_ceilCycles(rules.tRcd, periodPs));
      // fig 7/8, p10: dqm high the 2 edges before the write. Asserted right
      // after the read (not just before the write) so it also masks the
      // read's own first beat (dqm read latency is 2 clocks, p9 text),
      // which is what actually gives the write a released bus to drive.
      await d.read(0, 0);
      await d.setDqm(3);
      await d.waitEdges(2);
      await d.write(0, 1, 0xabcd);
      await d.setDqm(0);
      await d.waitEdges(10);

      model.finish();
      await Simulator.endSimulation();
      expect(model.errors, isEmpty, reason: model.errors.join('\n'));
      expect(model.peek(0, 5, 1), 0xabcd);
    },
  );

  test(
    'legal traffic: a write followed by a read the next cycle gives zero errors',
    () async {
      const rules = SdramModelRules.as4c16m16sb6();
      const periodPs = 8000;
      const cl = 3;
      final (d, model) = _buildRig(periodPs);

      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());

      await _initToReady(d, 0x233, periodPs, rules.copyWith(powerUpNs: 2000));
      await d.activate(0, 5);
      await d.waitEdges(_ceilCycles(rules.tRcd, periodPs));
      await d.write(0, 0, 0x5a5a); // fig 12, p12: a read may follow next cycle.
      await d.read(0, 0);
      final firstBeatEdge = Simulator.time + cl * periodPs;
      const order = [0, 1, 2, 3, 4, 5, 6, 7];
      for (var k = 0; k < 8; k++) {
        _sampleBeat(
          d,
          rules,
          cl,
          periodPs,
          firstBeatEdge + k * periodPs,
          model.peek(0, 5, order[k]),
        );
      }
      await d.waitEdges(cl + 9);

      model.finish();
      await Simulator.endSimulation();
      expect(model.errors, isEmpty, reason: model.errors.join('\n'));
      expect(model.peek(0, 5, 0), 0x5a5a);
    },
  );

  test(
    'legal traffic: two banks open and used at once gives zero errors',
    () async {
      const rules = SdramModelRules.as4c16m16sb6();
      const periodPs = 8000;
      const cl = 3;
      final (d, model) = _buildRig(periodPs);

      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());

      await _initToReady(d, 0x233, periodPs, rules.copyWith(powerUpNs: 2000));
      await d.activate(0, 5);
      await d.waitEdges(_ceilCycles(rules.tRrd, periodPs));
      await d.activate(1, 6);
      await d.waitEdges(_ceilCycles(rules.tRcd, periodPs));
      await d.write(0, 0, 0x1111);
      await d.write(1, 0, 0x2222);
      await d.waitEdges(_ceilCycles(rules.tWr, periodPs));
      await d.read(0, 0);
      final bank0Edge = Simulator.time + cl * periodPs;
      const order = [0, 1, 2, 3, 4, 5, 6, 7];
      for (var k = 0; k < 8; k++) {
        _sampleBeat(
          d,
          rules,
          cl,
          periodPs,
          bank0Edge + k * periodPs,
          model.peek(0, 5, order[k]),
        );
      }
      await d.waitEdges(cl + 9);
      await d.read(1, 0);
      final bank1Edge = Simulator.time + cl * periodPs;
      for (var k = 0; k < 8; k++) {
        _sampleBeat(
          d,
          rules,
          cl,
          periodPs,
          bank1Edge + k * periodPs,
          model.peek(1, 6, order[k]),
        );
      }
      await d.waitEdges(cl + 9);
      await d.precharge(0);
      await d.precharge(1);
      await d.waitEdges(_ceilCycles(rules.tRp, periodPs));

      model.finish();
      await Simulator.endSimulation();
      expect(model.errors, isEmpty, reason: model.errors.join('\n'));
      expect(model.peek(0, 5, 0), 0x1111);
      expect(model.peek(1, 6, 0), 0x2222);
    },
  );

  test(
    'legal traffic: 8 init refreshes then 8 pulled-in refreshes gives zero errors',
    () async {
      const rules = SdramModelRules.as4c16m16sb6();
      const periodPs = 8000;
      final clk = SimpleClockGenerator(periodPs).clk;
      final d = _Driver(clk);
      final model = SdramPinModel(
        clk: clk,
        cke: d.cke,
        csN: d.csN,
        rasN: d.rasN,
        casN: d.casN,
        weN: d.weN,
        ba: d.ba,
        addr: d.addr,
        dqm: d.dqm,
        dq: d.dq,
        rules: rules.copyWith(powerUpNs: 2000),
        fpgaDqOe: d.dqEn,
        fpgaDqOut: d.dqDrv,
        // k = p = 8, refiEffPs rounded to ns. maxLatencyNs stays 0: at
        // this P, 8192+k+p cycles already use nearly the whole 64ms
        // budget (by construction), so there is only a few ns of margin
        // left for L.
        refreshPolicy: const SdramRefreshPolicy(
          maxPostponed: 8,
          maxPulledIn: 8,
          periodNs: 7797.27,
          maxLatencyNs: 0,
          initRefreshes: 8,
        ),
      );

      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());

      await _powerUp(d, periodPs, 2000);
      await d.prechargeAll();
      await d.waitEdges(_ceilCycles(rules.tRp, periodPs));
      await d.mrs(0x233);
      final mrdCycles = _ceilCycles(rules.tMrd, periodPs);
      await d.waitEdges(mrdCycles > rules.tMrdNck ? mrdCycles : rules.tMrdNck);
      // t0 is fixed at the 8th refresh: the 8 pulled straight in right
      // after it are n=1..8, each comfortably inside the p=8 pull-in
      // credit, so legal.
      for (var i = 0; i < 8; i++) {
        await d.refresh();
        await d.waitEdges(_ceilCycles(rules.tRfc, periodPs));
      }
      for (var i = 0; i < 8; i++) {
        await d.refresh();
        await d.waitEdges(_ceilCycles(rules.tRfc, periodPs));
      }

      model.finish();
      await Simulator.endSimulation();
      expect(model.errors, isEmpty, reason: model.errors.join('\n'));
    },
  );

  test(
    'legal traffic: pulled-in refreshes let later ones run late and stay legal',
    () async {
      const rules = SdramModelRules.as4c16m16sb6();
      const periodPs = 8000;
      const policyPeriodPs = 2000000; // 2000ns.
      final clk = SimpleClockGenerator(periodPs).clk;
      final d = _Driver(clk);
      final model = SdramPinModel(
        clk: clk,
        cke: d.cke,
        csN: d.csN,
        rasN: d.rasN,
        casN: d.casN,
        weN: d.weN,
        ba: d.ba,
        addr: d.addr,
        dqm: d.dqm,
        dq: d.dq,
        rules: rules.copyWith(powerUpNs: 2000),
        fpgaDqOe: d.dqEn,
        fpgaDqOut: d.dqDrv,
        refreshPolicy: const SdramRefreshPolicy(
          maxPostponed: 8,
          maxPulledIn: 8,
          periodNs: 2000,
          maxLatencyNs: 0,
          initRefreshes: 8,
        ),
      );

      Simulator.setMaxSimTime(200000000);
      unawaited(Simulator.run());

      await _powerUp(d, periodPs, 2000);
      await d.prechargeAll();
      await d.waitEdges(_ceilCycles(rules.tRp, periodPs));
      await d.mrs(0x233);
      final mrdCycles = _ceilCycles(rules.tMrd, periodPs);
      await d.waitEdges(mrdCycles > rules.tMrdNck ? mrdCycles : rules.tMrdNck);
      // 8 init refreshes: t0 is fixed at the 8th, at its own command edge
      // (not after the tRFC wait that follows it).
      var t0Ps = 0;
      for (var i = 0; i < 8; i++) {
        await d.refresh();
        if (i == 7) t0Ps = Simulator.time;
        await d.waitEdges(_ceilCycles(rules.tRfc, periodPs));
      }
      // 8 more, pulled straight in (n=1..8): each spends from the p=8
      // pull-in credit, which the much later refreshes below draw back
      // out as postpone slack (the window is per-n, not a running total,
      // so spending the credit early still frees up being late later).
      for (var i = 0; i < 8; i++) {
        await d.refresh();
        await d.waitEdges(_ceilCycles(rules.tRfc, periodPs));
      }
      await d.activate(0, 5);
      await d.waitEdges(6); // tRAS min.
      await d.precharge(0);
      await d.waitEdges(3); // tRP.
      // n=9..12, each nominally due at (n+8)P but actually issued right
      // up against (n+8)P itself: legal only because of the slack the
      // early pulls above bought (lower bound is t0+(n-p)P).
      for (var j = 1; j <= 4; j++) {
        final target = t0Ps + (j + 16) * policyPeriodPs - 50000;
        while (Simulator.time + periodPs < target) {
          await d.nop();
        }
        await d.refresh();
      }
      await d.waitEdges(4);

      model.finish();
      await Simulator.endSimulation();
      expect(model.errors, isEmpty, reason: model.errors.join('\n'));
    },
  );

  test(
    'legal traffic: a masked write lane changing after the write edge gives zero errors',
    () async {
      const rules = SdramModelRules.as4c16m16sb6();
      const periodPs = 8000;
      final (d, model) = _buildRig(periodPs);

      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());

      await _initToReady(d, 0x233, periodPs, rules.copyWith(powerUpNs: 2000));
      await d.activate(0, 5);
      await d.waitEdges(_ceilCycles(rules.tRcd, periodPs));
      // High lane masked: the fpga changing it after the write edge is
      // its own business, not a hold or setup violation (probe6 c).
      await d.write(0, 1, 0x0012, dqmBits: 2);
      Simulator.registerAction(Simulator.time + 300, () {
        d.dqDrv.put(0xff12);
      });
      await d.waitEdges(3);

      model.finish();
      await Simulator.endSimulation();
      expect(model.errors, isEmpty, reason: model.errors.join('\n'));
      expect(model.peek(0, 5, 1) & 0xff, 0x12);
    },
  );
}
