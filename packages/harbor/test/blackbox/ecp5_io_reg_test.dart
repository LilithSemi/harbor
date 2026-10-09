import 'dart:async';

import 'package:harbor/src/blackbox/ecp5/ecp5.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Sim behavior and synth-leaf shape of the 4 ecp5 io register cells used by
/// [SdramPhyEcp5]: [Ecp5Ofs1p3bx], [Ecp5Ifs1p3bx], and the sim bodies added
/// here to [Ecp5Oddrx1f] and [Ecp5Iddrx1f] (both previously body-less).
/// A leaf cell emits no module body of its own, so its instantiation only
/// shows up in a parent's generated SV, and only if something in the parent
/// actually uses its output (an unconsumed leaf is pruned entirely).
class _Wrap extends Module {
  _Wrap(Logic Function() build) : super(name: 'wrap') {
    addOutput('out') <= build();
  }
}

void main() {
  tearDown(() async => Simulator.reset());

  /// True if [sv] instantiates [cell] with only `.PORT(signal)` connections
  /// (no vendor leaf ever emits its own module body).
  bool onlyPortConnections(String sv, String cell) {
    final inst = RegExp(
      '$cell\\s+\\w+\\s*\\(([^;]*)\\);',
      multiLine: true,
      dotAll: true,
    ).firstMatch(sv);
    if (inst == null) return false;
    final body = inst.group(1)!;
    if (RegExp(r'\balways\b|\binitial\b|\bcase\b').hasMatch(body)) {
      return false;
    }
    return RegExp(
      r'^(\s*\.\w+\([^()]*\)\s*,?\s*)+$',
      dotAll: true,
    ).hasMatch(body);
  }

  group('Ecp5Ofs1p3bx', () {
    test('presets to 1 before the first clock', () async {
      final sclk = SimpleClockGenerator(10).clk;
      final ofs = Ecp5Ofs1p3bx(
        d: Logic(name: 'd')..put(0),
        sclk: sclk,
      );
      await ofs.build();

      Simulator.setMaxSimTime(60);
      final before = Completer<void>();
      Simulator.registerAction(1, () {
        expect(ofs.q.value.toInt(), equals(1));
        before.complete();
      });
      unawaited(Simulator.run());
      await before.future;
      await Simulator.endSimulation();
    });

    test('q follows d on sclk rise, sp high, pd low by default', () async {
      final d = Logic(name: 'd');
      final sclk = SimpleClockGenerator(10).clk;
      final ofs = Ecp5Ofs1p3bx(d: d, sclk: sclk);
      await ofs.build();

      Simulator.setMaxSimTime(200);
      unawaited(Simulator.run());
      d.put(0);
      await sclk.nextPosedge;
      await sclk.nextPosedge;
      expect(ofs.q.value.toInt(), equals(0));
      d.put(1);
      await sclk.nextPosedge;
      await sclk.nextPosedge;
      expect(ofs.q.value.toInt(), equals(1));
      await Simulator.endSimulation();
    });

    test('pd forces q to 1 ahead of d', () async {
      final d = Logic(name: 'd')..put(0);
      final pd = Logic(name: 'pd')..put(1);
      final sclk = SimpleClockGenerator(10).clk;
      final ofs = Ecp5Ofs1p3bx(d: d, sclk: sclk, pd: pd);
      await ofs.build();

      Simulator.setMaxSimTime(100);
      unawaited(Simulator.run());
      await sclk.nextPosedge;
      await sclk.nextPosedge;
      expect(ofs.q.value.toInt(), equals(1));
      await Simulator.endSimulation();
    });

    test('pd forces q to 1 the instant it asserts, with no clock edge '
        'in between', () async {
      final d = Logic(name: 'd')..put(0);
      final pd = Logic(name: 'pd')..put(0);
      final sclk = SimpleClockGenerator(10).clk;
      final ofs = Ecp5Ofs1p3bx(d: d, sclk: sclk, pd: pd);
      await ofs.build();

      Simulator.setMaxSimTime(60);
      unawaited(Simulator.run());
      await sclk.nextPosedge;
      await sclk.nextNegedge;
      expect(ofs.q.value.toInt(), equals(0));
      pd.put(1); // mid-cycle, no edge: cells_ff.vh gives PD SRMODE("ASYNC").
      expect(
        ofs.q.value.toInt(),
        equals(1),
        reason: 'q must move right away, not wait for the next rise',
      );
      await Simulator.endSimulation();
    });

    test('pd keeps q at 1 after a pulse that releases again before the '
        'next clock edge', () async {
      final d = Logic(name: 'd')..put(0);
      final pd = Logic(name: 'pd')..put(0);
      final sclk = SimpleClockGenerator(10).clk;
      final ofs = Ecp5Ofs1p3bx(d: d, sclk: sclk, pd: pd);
      await ofs.build();

      Simulator.setMaxSimTime(100);
      unawaited(Simulator.run());
      await sclk.nextPosedge;
      await sclk.nextNegedge;
      expect(ofs.q.value.toInt(), equals(0));
      pd.put(1); // pulse, mid-cycle
      pd.put(0); // released again, still with no clock edge in between
      expect(
        ofs.q.value.toInt(),
        equals(1),
        reason: 'a real async set leaves the flop set, not just the wire',
      );
      await sclk.nextPosedge; // sp defaults 1, d is still 0
      expect(
        ofs.q.value.toInt(),
        equals(0),
        reason: 'the next edge now runs the plain d/sp capture normally',
      );
      await Simulator.endSimulation();
    });

    test('sp low holds the last value', () async {
      final d = Logic(name: 'd')..put(0);
      final sp = Logic(name: 'sp')..put(0);
      final sclk = SimpleClockGenerator(10).clk;
      final ofs = Ecp5Ofs1p3bx(d: d, sclk: sclk, sp: sp);
      await ofs.build();

      Simulator.setMaxSimTime(100);
      unawaited(Simulator.run());
      await sclk.nextPosedge;
      await sclk.nextPosedge;
      // sp held low the whole time, so the power-up preset of 1 never moved.
      expect(ofs.q.value.toInt(), equals(1));
      await Simulator.endSimulation();
    });

    test('a flop() on the same clock feeding d gives exactly one cycle '
        'of delay through the cell', () async {
      final a = Logic(name: 'a')..inject(0);
      final sclk = SimpleClockGenerator(10).clk;
      final d = flop(sclk, a);
      final ofs = Ecp5Ofs1p3bx(d: d, sclk: sclk);
      await ofs.build();

      Simulator.setMaxSimTime(100);
      unawaited(Simulator.run());
      await sclk.nextNegedge;
      a.put(1);
      // d, a plain register fed by a, updates right on this same edge.
      await sclk.nextPosedge;
      expect(d.value.toInt(), equals(1));
      // The cell must not already show it too: that would mean 0 cycles
      // of delay through the cell itself, not 1.
      expect(ofs.q.value.toInt(), equals(0), reason: 'cell is 1 edge behind d');
      // One more edge, and the cell catches up to d: exactly 1 cycle of
      // delay through it.
      await sclk.nextPosedge;
      expect(ofs.q.value.toInt(), equals(1));
      await Simulator.endSimulation();
    });

    test('two cells in series built in reverse order still give two '
        'cycles total, not zero or one', () async {
      // Built back to front (ob constructed, and so its sim body wired,
      // before oa's output even exists): a listener reading d's current
      // value instead of a Sequential's pre-edge one would make this
      // depend on that build order, since whichever listener happens to
      // run first on the shared edge would decide what the other reads.
      final a = Logic(name: 'a')..inject(0);
      final sclk = SimpleClockGenerator(10).clk;
      final f1 = flop(sclk, a);
      final x = Logic(name: 'x');
      final qb = Ecp5Ofs1p3bx(d: x, sclk: sclk, name: 'ob').q;
      final qa = Ecp5Ofs1p3bx(d: f1, sclk: sclk, name: 'oa').q;
      x <= qa;
      final f2 = flop(sclk, qb);

      Simulator.setMaxSimTime(200);
      unawaited(Simulator.run());
      await sclk.nextNegedge;
      a.put(1);
      await sclk.nextPosedge; // f1 sees it
      expect(f1.value.toInt(), equals(1));
      expect(qa.value.toInt(), equals(0));
      await sclk.nextPosedge; // qa (1 cycle behind f1)
      expect(qa.value.toInt(), equals(1));
      expect(qb.value.toInt(), equals(0));
      await sclk.nextPosedge; // qb (1 cycle behind qa: 2 behind f1)
      expect(qb.value.toInt(), equals(1));
      expect(f2.value.toInt(), equals(0));
      await sclk.nextPosedge; // f2 (the plain flop behind qb)
      expect(f2.value.toInt(), equals(1));
      await Simulator.endSimulation();
    });

    test('generated SV holds only port connections', () async {
      final wrap = _Wrap(() => Ecp5Ofs1p3bx(d: Logic(), sclk: Logic()).q);
      await wrap.build();
      final sv = wrap.generateSynth();
      expect(onlyPortConnections(sv, 'OFS1P3BX'), isTrue);
      expect(sv, isNot(contains('module OFS1P3BX')));
    });
  });

  group('Ecp5Ifs1p3bx', () {
    test('same sim body as Ecp5Ofs1p3bx: q follows d on sclk rise', () async {
      final d = Logic(name: 'd')..put(0);
      final sclk = SimpleClockGenerator(10).clk;
      final ifs = Ecp5Ifs1p3bx(d: d, sclk: sclk);
      await ifs.build();

      Simulator.setMaxSimTime(100);
      unawaited(Simulator.run());
      await sclk.nextPosedge;
      await sclk.nextPosedge;
      expect(ifs.q.value.toInt(), equals(0));
      await Simulator.endSimulation();
    });

    test('generated SV holds only port connections', () async {
      final wrap = _Wrap(() => Ecp5Ifs1p3bx(d: Logic(), sclk: Logic()).q);
      await wrap.build();
      final sv = wrap.generateSynth();
      expect(onlyPortConnections(sv, 'IFS1P3BX'), isTrue);
      expect(sv, isNot(contains('module IFS1P3BX')));
    });
  });

  group('Ecp5Ofs1p3dx', () {
    test('powers up and clears to 0, the opposite of Ecp5Ofs1p3bx', () async {
      final sclk = SimpleClockGenerator(10).clk;
      final dx = Ecp5Ofs1p3dx(
        d: Logic(name: 'd')..put(1),
        sclk: sclk,
      );
      await dx.build();

      Simulator.setMaxSimTime(60);
      final before = Completer<void>();
      Simulator.registerAction(1, () {
        expect(dx.q.value.toInt(), equals(0));
        before.complete();
      });
      unawaited(Simulator.run());
      await before.future;
      await sclk.nextPosedge;
      await sclk.nextPosedge;
      expect(dx.q.value.toInt(), equals(1), reason: 'sp high, d=1 by now');
      await Simulator.endSimulation();
    });

    test('cd clears q to 0 the instant it asserts', () async {
      final d = Logic(name: 'd')..put(1);
      final cd = Logic(name: 'cd')..put(0);
      final sclk = SimpleClockGenerator(10).clk;
      final dx = Ecp5Ofs1p3dx(d: d, sclk: sclk, cd: cd);
      await dx.build();

      Simulator.setMaxSimTime(60);
      unawaited(Simulator.run());
      await sclk.nextPosedge;
      await sclk.nextNegedge;
      expect(dx.q.value.toInt(), equals(1));
      cd.put(1);
      expect(dx.q.value.toInt(), equals(0));
      await Simulator.endSimulation();
    });

    test('generated SV holds only port connections', () async {
      final wrap = _Wrap(() => Ecp5Ofs1p3dx(d: Logic(), sclk: Logic()).q);
      await wrap.build();
      final sv = wrap.generateSynth();
      expect(onlyPortConnections(sv, 'OFS1P3DX'), isTrue);
      expect(sv, isNot(contains('module OFS1P3DX')));
    });
  });

  group('Ecp5Oddrx1f', () {
    test(
      'q tracks changing (d0,d1) pairs, both captured on the same rise',
      () async {
        final d0 = Logic(name: 'd0')..put(0);
        final d1 = Logic(name: 'd1')..put(0);
        final sclk = SimpleClockGenerator(10).clk;
        final oddr = Ecp5Oddrx1f(sclk: sclk, rst: Const(0), d0: d0, d1: d1);
        await oddr.build();

        const pairs = [(1, 0), (0, 1), (1, 1), (0, 0), (1, 0), (0, 1)];
        Simulator.setMaxSimTime(200);
        unawaited(Simulator.run());
        for (final (pa, pb) in pairs) {
          await sclk.nextNegedge;
          d0.put(pa);
          d1.put(pb);
          await sclk.nextPosedge;
          expect(
            oddr.q.value.toInt(),
            equals(pa),
            reason: 'high phase shows this rise\'s own d0=$pa',
          );
          // A real source register driving d1 could already have moved on
          // to the next pair's bit right after this same rise. q must
          // still show this pair's d1 at the fall, not that new one
          // (HarborDdrOutput's own doc describes this exact fault).
          d1.put(1 - pb);
          await sclk.nextNegedge;
          expect(
            oddr.q.value.toInt(),
            equals(pb),
            reason:
                'low phase shows this rise\'s own d1=$pb, not a value the '
                'source has already moved on to',
          );
        }
        await Simulator.endSimulation();
      },
    );

    test('generated SV holds only port connections', () async {
      final wrap = _Wrap(
        () => Ecp5Oddrx1f(
          sclk: Logic(),
          rst: Const(0),
          d0: Logic(),
          d1: Logic(),
        ).q,
      );
      await wrap.build();
      final sv = wrap.generateSynth();
      expect(onlyPortConnections(sv, 'ODDRX1F'), isTrue);
      expect(sv, isNot(contains('module ODDRX1F')));
    });
  });

  group('Ecp5Iddrx1f', () {
    test('q0/q1 track a changing d across several cycles, both moving '
        'together on the rise', () async {
      final d = Logic(name: 'd')..put(0);
      final sclk = SimpleClockGenerator(10).clk;
      final iddr = Ecp5Iddrx1f(sclk: sclk, rst: Const(0), d: d);
      await iddr.build();

      // d0Seq[i]/d1Seq[i]: the bit d must hold at rise i / at the fall
      // just before rise i, so q0(i)=d0Seq[i] and q1(i)=d1Seq[i].
      const d0Seq = [1, 0, 1, 1, 0];
      const d1Seq = [0, 1, 1, 0, 1, 0];
      Simulator.setMaxSimTime(200);
      unawaited(Simulator.run());
      d.put(d0Seq[0]);
      await sclk.nextPosedge; // rise 0: q1 not checked (no fall came first)
      for (var i = 1; i < d0Seq.length; i++) {
        d.put(d1Seq[i]);
        await sclk.nextNegedge;
        d.put(d0Seq[i]);
        await sclk.nextPosedge;
        expect(
          iddr.q0.value.toInt(),
          equals(d0Seq[i]),
          reason: 'q0 is d at the rise, i=$i',
        );
        expect(
          iddr.q1.value.toInt(),
          equals(d1Seq[i]),
          reason: 'q1 is d at the fall just before, i=$i',
        );
      }
      await Simulator.endSimulation();
    });

    test('generated SV holds only port connections', () async {
      final wrap = _Wrap(
        () => Ecp5Iddrx1f(sclk: Logic(), rst: Const(0), d: Logic()).q0,
      );
      await wrap.build();
      final sv = wrap.generateSynth();
      expect(onlyPortConnections(sv, 'IDDRX1F'), isTrue);
      expect(sv, isNot(contains('module IDDRX1F')));
    });
  });
}
