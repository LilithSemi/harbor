import 'dart:math';

import 'package:harbor/src/arith/fp_format.dart';
import 'package:harbor/src/arith/fp_pipe_stage.dart';
import 'package:harbor/src/arith/fpu.dart';
import 'package:harbor/src/arith/fpu_config.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'fpu_bench.dart';
import 'lane_sim.dart';

const _fp16 = HarborFpFormat.fp16;
const _fp32 = HarborFpFormat.fp32;
const _fp64 = HarborFpFormat.fp64;
const _tagW = 16;

/// Two flops on different clocks, for the LaneSim second clock check.
class _TwoClk extends Module {
  _TwoClk(Logic clk, Logic clk2, Logic reset, Logic d) {
    clk = addInput('clk', clk);
    clk2 = addInput('clk2', clk2);
    reset = addInput('reset', reset);
    d = addInput('d', d);
    addOutput('q') <= flop(clk, d, reset: reset) ^ flop(clk2, d, reset: reset);
  }
}

HarborFpuConfig _wide(
  int n, {
  HarborFpDivMode divMode = HarborFpDivMode.iterative,
  int divRadix = 2,
  int divStages = 1,
}) => HarborFpuConfig(
  formats: [_fp32, _fp64],
  widening: [(_fp32, _fp64)],
  ops: HarborFpOp.values.toSet(),
  stages: n,
  intWidths: [32, 64],
  divMode: divMode,
  divRadix: divRadix,
  divStages: divStages,
);

HarborFpuConfig _half(int n) => HarborFpuConfig(
  formats: [_fp16],
  ops: HarborFpOp.values.toSet().difference({HarborFpOp.cvtModWD}),
  stages: n,
  intWidths: [32],
  divMode: HarborFpDivMode.pipelined,
  divStages: 3,
);

final _lanes = <int, LaneDriver>{};
final _rnd = Random(99);

Future<LaneDriver> _wideLanes(int n) async {
  final known = _lanes[n];
  if (known != null) {
    return known;
  }
  final dut = HarborFpu(_wide(n), tagWidth: _tagW);
  await dut.build();
  return _lanes[n] = LaneDriver(dut);
}

List<List<FpuCase>> _cases(
  HarborFpuConfig config,
  Random r,
  int lanes,
  int perLane, {
  List<HarborFpOp>? ops,
}) => [
  for (var l = 0; l < lanes; l++)
    [for (var i = 0; i < perLane; i++) mainCase(config, r, ops: ops)],
];

void _checkAll(FpuPort p, {int? latency}) {
  for (var l = 0; l < p.cases.length; l++) {
    checkLane(p, l, latency: latency);
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('LaneSim rejects a flop on a second clock', () async {
    final clk = Logic(), clk2 = Logic(), reset = Logic(), d = Logic();
    final m = _TwoClk(clk, clk2, reset, d);
    await m.build();
    expect(
      () => LaneSim(
        m,
        [m.input('reset'), m.input('d'), m.input('clk2')],
        [m.output('q')],
        clock: m.input('clk'),
      ),
      throwsA(isA<UnsupportedError>()),
    );
  });

  group('ROHD simulator matches LaneSim cycle by cycle', () {
    final builds = [
      for (final n in [0, 2, 4, 6, 7]) ('fp16 N=$n', _half(n), 300, 50),
      // An iterative radix 4 divider on the div port.
      (
        'fp32 N=3',
        HarborFpuConfig(
          formats: [_fp32],
          ops: HarborFpOp.values.toSet().difference({HarborFpOp.cvtModWD}),
          stages: 3,
          intWidths: [32],
          divRadix: 4,
        ),
        120,
        12,
      ),
      // fp64 only, with an iterative divider. divOps is small: the
      // engine is shared, so each divide serializes for its full latency.
      (
        'fp64 N=2',
        HarborFpuConfig(
          formats: [_fp64],
          ops: HarborFpOp.values.toSet().difference({HarborFpOp.cvtModWD}),
          stages: 2,
          intWidths: [64],
          divRadix: 4,
        ),
        50,
        3,
      ),
    ];
    for (final (label, config, mainOps, divOps) in builds) {
      test('$label, stalls, gaps, slot kills and flushes', () async {
        final n = config.latency;
        Future<List<FpuPort>> run(FpuDriver d) async {
          // N=7's fixed seed gives no div port kill, so it uses one that
          // does (same as the review probe).
          final r = Random(n == 7 ? 908 : 900 + n);
          final main = FpuPort(
            '',
            _cases(config, r, 1, mainOps),
            validGap: 0.2,
            slotKillRate: 0.05,
          );
          final div = FpuPort(
            'div_',
            [
              [for (var i = 0; i < divOps; i++) divCase(config, r)],
            ],
            validGap: 0.3,
            slotKillRate: 0.02,
          );
          await runBench(
            d,
            [main, div],
            random: Random(n == 7 ? 1008 : 1000 + n),
            flushRate: 0.01,
          );
          checkLane(main, 0, latency: n);
          checkLane(div, 0);
          return [main, div];
        }

        final lane = HarborFpu(config, tagWidth: _tagW);
        await lane.build();
        final a = await run(LaneDriver(lane));
        final rohd = await RohdDriver.start(HarborFpu(config, tagWidth: _tagW));
        final b = await run(rohd);
        await rohd.done();
        for (var i = 0; i < 2; i++) {
          expect(b[i].logs[0].outs, a[i].logs[0].outs);
          expect(b[i].logs[0].accepts, a[i].logs[0].accepts);
          expect(b[i].logs[0].killed, a[i].logs[0].killed);
          expect(b[i].logs[0].killed, isNotEmpty);
        }
        expect(a[0].logs[0].outs.length, greaterThan(mainOps ~/ 2));
        expect(a[1].logs[0].outs.length, greaterThan(divOps ~/ 5));
      });
    }
  });

  group('N=6 stall at the output only', () {
    // Ops at cycles 0, 2 and 4 leave bubbles between them. From cycle 6
    // out_ready is low and in_valid is high. The bubbles close up, so
    // four more ops come in (three bubbles and the skid buffer).
    int valid(int c, FpuPort _) => c < 6 && c.isOdd ? 0 : -1;
    int ready(int c, FpuPort _) => c >= 6 && c < 16 ? 0 : -1;

    Future<FpuPort> run(FpuDriver d, HarborFpuConfig config) async {
      final p = FpuPort('', _cases(config, Random(7), 1, 12));
      final inReady = <int>[];
      await runBench(
        d,
        [p],
        random: Random(8),
        validMask: valid,
        readyMask: ready,
        hook: (_, _, ir, _) => inReady.add(ir & 1),
      );
      checkLane(p, 0, latency: 6);
      final log = p.logs[0];
      expect(log.accepts.map((a) => a.cycle).take(8), [
        0,
        2,
        4,
        6,
        7,
        8,
        9,
        17,
      ]);
      // The skid buffer empties in cycle 16, so in_ready is high again in 17.
      expect(inReady.sublist(10, 17), everyElement(0));
      expect(inReady[17], 1);
      expect(log.outs.map((o) => o.cycle).take(8), [
        16,
        17,
        18,
        19,
        20,
        21,
        22,
        23,
      ]);
      expect(log.held.map((h) => h.cycle), [for (var c = 6; c < 16; c++) c]);
      return p;
    }

    test('ROHD simulator, fp16, same as LaneSim', () async {
      final lane = HarborFpu(_half(6), tagWidth: _tagW);
      await lane.build();
      final a = await run(LaneDriver(lane), _half(6));
      await Simulator.reset();
      final rohd = await RohdDriver.start(HarborFpu(_half(6), tagWidth: _tagW));
      final b = await run(rohd, _half(6));
      await rohd.done();
      expect(b.logs[0].outs, a.logs[0].outs);
      expect(b.logs[0].accepts, a.logs[0].accepts);
    });

    test('LaneSim, fp32 and fp64', () async {
      await run(await _wideLanes(6), _wide(6));
    });
  });

  group('elaboration', () {
    test('latency is the number of cuts', () {
      for (var n = 0; n <= 7; n++) {
        final config = _wide(n);
        final dut = HarborFpu(config);
        expect(dut.latency, config.latency);
        expect(dut.latency, n);
      }
    });

    test('ports and widths', () async {
      final dut = HarborFpu(_wide(3), tagWidth: 5);
      await dut.build();
      Map<String, int> widths(Map<String, Logic> m) => {
        for (final e in m.entries) e.key: e.value.width,
      };
      expect(widths(dut.inputs), {
        'clk': 1,
        'reset': 1,
        'in_valid': 1,
        'in_op': 5,
        'in_fmt': 1,
        'in_fmt_dst': 1,
        'in_fmt_narrow': 1,
        'in_rm': 3,
        'in_a': 64,
        'in_b': 64,
        'in_c': 64,
        'in_li_index': 5,
        'in_int_signed': 1,
        'in_int_width': 1,
        'in_tag': 5,
        'out_ready': 1,
        'kill_mask': 4,
        'div_in_valid': 1,
        'div_in_op': 5,
        'div_in_fmt': 1,
        'div_in_rm': 3,
        'div_in_a': 64,
        'div_in_b': 64,
        'div_in_tag': 5,
        'div_out_ready': 1,
        'div_kill_mask': 4,
      });
      expect(widths(dut.outputs), {
        'in_ready': 1,
        'out_valid': 1,
        'out_result': 64,
        'out_flags': 5,
        'out_tag': 5,
        'slot_valid': 4,
        'slot_tag': 20,
        'div_in_ready': 1,
        'div_out_valid': 1,
        'div_out_result': 64,
        'div_out_flags': 5,
        'div_out_tag': 5,
        'div_slot_valid': 4,
        'div_slot_tag': 20,
      });
      expect(dut.slots, 4);
      expect(dut.slotNames, ['skid', 'c2', 'c4', 'c5']);
      expect(dut.divSlots, 4);
      expect(dut.divSlotNames, ['in', 'step', 'post', 'out']);
    });

    test('slot counts and names', () {
      for (var n = 0; n <= 7; n++) {
        final config = _wide(n, divMode: HarborFpDivMode.pipelined);
        expect(HarborFpu.slotCountOf(config), n + 1);
        expect(HarborFpu.slotNamesOf(config).length, n + 1);
        expect(HarborFpu.slotNamesOf(config).first, 'skid');
      }
      final p0 = _wide(2, divMode: HarborFpDivMode.pipelined, divStages: 0);
      expect(HarborFpu.divSlotCountOf(p0), 0);
      final p5 = _wide(2, divMode: HarborFpDivMode.pipelined, divStages: 5);
      expect(HarborFpu.divSlotNamesOf(p5), [
        for (var c = 1; c <= 5; c++) 'stage_$c',
      ]);
    });

    test('harborKillAll rejects zero slots', () {
      expect(() => harborKillAll(Logic(), 0), throwsA(isA<ArgumentError>()));
    });

    test('a pipelined div port with no stages has no kill ports', () async {
      final dut = HarborFpu(
        _wide(1, divMode: HarborFpDivMode.pipelined, divStages: 0),
        tagWidth: 3,
      );
      await dut.build();
      final ports = [...dut.inputs.keys, ...dut.outputs.keys];
      expect(ports, isNot(contains('div_kill_mask')));
      expect(ports, isNot(contains('div_slot_valid')));
      expect(ports, isNot(contains('div_slot_tag')));
      expect(ports, containsAll(['kill_mask', 'slot_valid', 'slot_tag']));
    });

    test('every op has a path', () {
      expect(harborFpuHandledOps, HarborFpOp.values.toSet());
    });

    test('no tag ports without a tag width', () async {
      final dut = HarborFpu(_half(1));
      await dut.build();
      expect(dut.inputs.keys, isNot(contains('in_tag')));
      expect(dut.inputs.keys, isNot(contains('div_in_tag')));
      expect(dut.outputs.keys, isNot(contains('out_tag')));
      expect(dut.outputs.keys, isNot(contains('div_out_tag')));
    });
  });

  group('random mixed ops, back to back, out_ready 30 percent low', () {
    for (var n = 0; n <= 7; n++) {
      test('N=$n', () async {
        final d = await _wideLanes(n);
        final r = Random(100 + n);
        final p = FpuPort('', _cases(d.dut.config, r, 64, 80));
        await runBench(d, [p], random: Random(200 + n));
        _checkAll(p, latency: n);
        final outs = p.logs.map((l) => l.outs.length).reduce((a, b) => a + b);
        expect(outs, 64 * 80);
        final stalls = p.logs.map((l) => l.held.length).reduce((a, b) => a + b);
        expect(stalls, greaterThan(500));
      });
    }
  });

  group('flush: every slot killed at once', () {
    for (var n = 0; n <= 7; n++) {
      test('N=$n', () async {
        final d = await _wideLanes(n);
        final r = Random(300 + n);
        final p = FpuPort('', _cases(d.dut.config, r, 64, 60));
        await runBench(d, [p], random: Random(400 + n), flushRate: 0.03);
        var dropped = 0;
        var kills = 0;
        var after = 0;
        for (var l = 0; l < 64; l++) {
          dropped += checkLane(p, l, latency: n);
          final log = p.logs[l];
          kills += log.kills.length;
          if (log.kills.isNotEmpty) {
            after += log.outs.where((o) => o.cycle > log.kills.last).length;
          }
        }
        expect(kills, greaterThan(100));
        expect(p.stats!.flushes, kills);
        expect(after, greaterThan(500));
        expect(p.stats!.acceptKills, greaterThan(20));
        if (n > 0) {
          expect(dropped, greaterThan(50));
        }
      });
    }
  });

  group('per-slot kill', () {
    // Each slot index is hit with ops in flight on both sides of it, on the
    // output in a cycle with out_ready high, and in cycles with an accept or
    // a take.
    void checkStats(FpuPort p, {required int least}) {
      final st = p.stats!;
      for (var i = 0; i < st.hits.length; i++) {
        expect(st.between[i], greaterThan(least), reason: '$st');
      }
      expect(st.outReadyKills, greaterThan(least), reason: '$st');
      expect(st.acceptKills, greaterThan(least), reason: '$st');
      expect(st.takeKills, greaterThan(least), reason: '$st');
      expect(st.emptyHits, greaterThan(least), reason: '$st');
      expect(st.flushes, greaterThan(least), reason: '$st');
    }

    for (final n in [2, 6]) {
      test('main pipe N=$n, every slot', () async {
        final d = await _wideLanes(n);
        final r = Random(700 + n);
        final p = FpuPort(
          '',
          _cases(d.dut.config, r, 64, 80),
          readyLow: 0.5,
          validGap: 0.1,
          slotKillRate: 0.1,
        );
        await runBench(d, [p], random: Random(800 + n), flushRate: 0.005);
        var killed = 0;
        var outs = 0;
        for (var l = 0; l < 64; l++) {
          killed += checkLane(p, l, latency: n);
          outs += p.logs[l].outs.length;
        }
        expect(p.stats!.hits.length, n + 1);
        checkStats(p, least: 20);
        expect(killed, greaterThan(200));
        expect(outs, greaterThan(2000));
      });
    }

    test('div port, iterative radix 2, every slot', () async {
      final d = await _wideLanes(4);
      final r = Random(31);
      final div = FpuPort(
        'div_',
        [
          for (var l = 0; l < 64; l++)
            [for (var i = 0; i < 24; i++) divCase(d.dut.config, r)],
        ],
        validGap: 0.1,
        slotKillRate: 0.05,
      );
      // Long out_ready bursts, so ops wait in every slot.
      await runBench(
        d,
        [div],
        random: Random(32),
        maxCycles: 40000,
        flushRate: 0.002,
        readyMask: (c, _) {
          var m = 0;
          for (var l = 0; l < 64; l++) {
            if ((c + 37 * l) ~/ 80 % 2 == 0) {
              m |= 1 << l;
            }
          }
          return m;
        },
      );
      var outs = 0;
      for (var l = 0; l < 64; l++) {
        checkLane(div, l);
        outs += div.logs[l].outs.length;
      }
      expect(div.stats!.hits.length, 4);
      checkStats(div, least: 5);
      expect(outs, greaterThan(300));
    });

    test('div port, pipelined, every slot', () async {
      final config = _wide(2, divMode: HarborFpDivMode.pipelined, divStages: 5);
      final dut = HarborFpu(config, tagWidth: _tagW);
      await dut.build();
      final d = LaneDriver(dut);
      final r = Random(33);
      final main = FpuPort('', _cases(config, r, 64, 30), slotKillRate: 0.05);
      final div = FpuPort(
        'div_',
        [
          for (var l = 0; l < 64; l++)
            [for (var i = 0; i < 60; i++) divCase(config, r)],
        ],
        validGap: 0.1,
        slotKillRate: 0.1,
      );
      await runBench(d, [main, div], random: Random(34), flushRate: 0.005);
      var outs = 0;
      for (var l = 0; l < 64; l++) {
        checkLane(main, l, latency: 2);
        checkLane(div, l, latency: 5);
        outs += div.logs[l].outs.length;
      }
      expect(div.stats!.hits.length, 5);
      checkStats(div, least: 20);
      expect(outs, greaterThan(1500));
    });

    test('a killed divide frees the engine at once', () async {
      final d = await _wideLanes(4);
      final config = d.dut.config;
      final lat = d.dut.divLatency!;
      final fp64 = config.formats.indexOf(_fp64);
      final r = Random(35);
      FpuCase fp64Div() {
        while (true) {
          final c = divCase(config, r);
          if (c.fields['op']!.toInt() == HarborFpOp.div.index &&
              c.fields['fmt']!.toInt() == fp64) {
            return c;
          }
        }
      }

      final ops = [for (var i = 0; i < 5; i++) fp64Div()];
      final slot = {for (final (i, s) in d.dut.divSlotNames.indexed) s: i};
      final step = 1 << slot['step']!;
      final inSlot = 1 << slot['in']!;
      void kill(int mask) =>
          d.put('div_kill_mask', List.filled(64, BigInt.from(mask)));
      int slots() => d.read('div_slot_valid').first.toInt();

      d
        ..putMask('reset', -1)
        ..putMask('div_out_ready', -1)
        ..putMask('in_valid', 0)
        ..putMask('div_in_valid', 0);
      kill(0);
      d.eval();
      await d.tick();
      d.putMask('reset', 0);

      var now = 0;
      final accepts = <int, int>{};
      final outs = <int, int>{};
      // One cycle with op [tag] on the input, or none.
      Future<void> cycle([int? tag]) async {
        d.putMask('div_in_valid', tag == null ? 0 : -1);
        for (final e in ops[tag ?? 0].fields.entries) {
          d.put('div_in_${e.key}', List.filled(64, e.value));
        }
        d.put('div_in_tag', List.filled(64, BigInt.from(tag ?? 0)));
        d.eval();
        if (tag != null && d.mask('div_in_ready') == -1) {
          accepts[tag] = now;
        }
        if (d.mask('div_out_valid') == -1) {
          final t = d.read('div_out_tag').first.toInt();
          outs[t] = now;
          expect(d.read('div_out_result').toSet(), {ops[t].expect.bits});
          expect(d.read('div_out_flags').toSet(), {
            BigInt.from(ops[t].expect.flags),
          });
        } else {
          expect(d.mask('div_out_valid'), 0);
        }
        await d.tick();
        now++;
      }

      Future<void> issue(int tag) async {
        while (!accepts.containsKey(tag)) {
          await cycle(tag);
        }
      }

      // Op 0 runs in the engine and op 1 waits in the input slot.
      await issue(0);
      await issue(1);
      while (now < 12) {
        await cycle();
      }
      d.eval();
      expect(slots(), step | inSlot);
      // Bits on the empty post and out slots do nothing.
      kill(1 << slot['post']! | 1 << slot['out']!);
      await cycle();
      d.eval();
      expect(slots(), step | inSlot);
      // Kill op 0 in the engine. Op 1 moves in the same cycle and op 2 is
      // accepted in the next cycle.
      final killAt = now;
      kill(step);
      await cycle();
      kill(0);
      d.eval();
      expect(slots(), step);
      await cycle(2);
      expect(accepts[2], killAt + 1);
      while (outs.length < 2 && now < killAt + 3 * lat) {
        await cycle();
      }
      expect(outs.keys, [1, 2]);
      // Op 1 left the input slot in the kill cycle, one cycle earlier than
      // the accept cycle plus one, so it is out one cycle before
      // killAt + lat. Op 2 waits for op 1 and then takes lat - 1 cycles.
      expect(outs[1], killAt + lat - 1);
      expect(outs[2], outs[1]! + lat - 3);

      // Op 3 alone, killed in the engine: the slot is empty in the next
      // cycle, and op 4 in that cycle has the full normal latency.
      await issue(3);
      for (var i = 0; i < 10; i++) {
        await cycle();
      }
      d.eval();
      expect(slots(), step);
      kill(step);
      await cycle();
      kill(0);
      d.eval();
      expect(slots(), 0);
      await issue(4);
      expect(accepts[4], accepts[3]! + 12);
      while (!outs.containsKey(4) && now < accepts[4]! + 2 * lat) {
        await cycle();
      }
      expect(outs.keys, [1, 2, 4]);
      expect(outs[4], accepts[4]! + lat);
    });

    test(
      'iterative: directed post, out and in kills with all slots full',
      () async {
        final d = await _wideLanes(2);
        final config = d.dut.config;
        final r = Random(41);
        final ops = <FpuCase>[];
        while (ops.length < 5) {
          final c = divCase(config, r);
          if (c.fields['op']!.toInt() == HarborFpOp.div.index) {
            ops.add(c);
          }
        }
        final idx = {for (final (i, s) in d.dut.divSlotNames.indexed) s: i};
        int bit(String s) => 1 << idx[s]!;
        void kill(int m) =>
            d.put('div_kill_mask', List.filled(64, BigInt.from(m)));
        int slots() => d.read('div_slot_valid').first.toInt();

        d
          ..putMask('reset', -1)
          ..putMask('in_valid', 0)
          ..putMask('div_in_valid', 0)
          ..putMask('div_out_ready', 0)
          ..putMask('kill_mask', 0);
        kill(0);
        d.eval();
        await d.tick();
        d.putMask('reset', 0);
        final outs = <int>[];
        final accepted = <int>{};
        Future<void> cyc({int? tag, bool ready = false}) async {
          d.putMask('div_in_valid', tag == null ? 0 : -1);
          for (final e in ops[tag ?? 0].fields.entries) {
            if (d.has('div_in_${e.key}')) {
              d.put('div_in_${e.key}', List.filled(64, e.value));
            }
          }
          d.put('div_in_tag', List.filled(64, BigInt.from(tag ?? 0)));
          d.putMask('div_out_ready', ready ? -1 : 0);
          d.eval();
          if (tag != null && d.mask('div_in_ready') == -1) {
            accepted.add(tag);
          }
          final ov = d.mask('div_out_valid');
          expect(ov == 0 || ov == -1, isTrue);
          if (ov == -1 && ready) {
            final t = d.read('div_out_tag').first.toInt();
            expect(
              d.read('div_out_result').first,
              ops[t].expect.bits,
              reason: 'tag $t',
            );
            expect(d.read('div_out_flags').first.toInt(), ops[t].expect.flags);
            outs.add(t);
          }
          await d.tick();
        }

        // Fill every slot: op 0 and 1 go through the engine, op 2 sits in
        // post or out, op 3 waits in the input slot.
        for (var t = 0; t < 4; t++) {
          while (!accepted.contains(t)) {
            await cyc(tag: t);
          }
        }
        for (var i = 0; i < 400; i++) {
          await cyc();
        }
        d.eval();
        expect(slots(), bit('in') | bit('step') | bit('post') | bit('out'));

        // Kill post (op 1): out (op 0) is unaffected this cycle. Step (op 2)
        // moves to post, in (op 3) to step.
        kill(bit('post'));
        d.eval();
        expect(d.mask('div_out_valid'), -1);
        await cyc();
        kill(0);
        d.eval();
        expect(slots(), bit('step') | bit('post') | bit('out'));
        for (var i = 0; i < 400; i++) {
          await cyc();
        }

        // Kill out (op 0) with out_ready low: out_valid drops, post (op 2)
        // moves up on the next cycle.
        kill(bit('out'));
        d.eval();
        expect(d.mask('div_out_valid'), 0);
        await cyc();
        kill(0);
        d.eval();
        expect(slots(), bit('post') | bit('out'));
        expect(d.read('div_out_tag').first.toInt(), 2);

        // Kill the op waiting in the input slot.
        while (!accepted.contains(4)) {
          await cyc(tag: 4);
        }
        d.eval();
        expect(slots() & bit('in'), bit('in'));
        kill(bit('in'));
        await cyc();
        kill(0);
        d.eval();
        expect(slots() & bit('in'), 0);
        for (var i = 0; i < 400; i++) {
          await cyc(ready: true);
        }
        // Only ops 2 and 3 survive, in order, with correct results, flags
        // and tags.
        expect(outs, [2, 3]);
      },
    );
  });

  group('in_ready stays high when out_ready is high', () {
    for (var n = 0; n <= 7; n++) {
      test('N=$n', () async {
        final d = await _wideLanes(n);
        final r = Random(500 + n);
        final p = FpuPort('', _cases(d.dut.config, r, 64, 40), validGap: 0.3);
        var cycles = 0;
        await runBench(
          d,
          [p],
          random: Random(600 + n),
          readyMask: (_, _) => -1,
          hook: (cycle, _, inReady, _) {
            cycles++;
            if (inReady != -1) {
              fail('in_ready low at cycle $cycle: ${inReady.toRadixString(2)}');
            }
          },
        );
        _checkAll(p, latency: n);
        expect(cycles, greaterThan(40));
        for (final log in p.logs) {
          final at = {for (final a in log.accepts) a.tag: a.cycle};
          expect(log.outs.length, 40);
          for (final o in log.outs) {
            expect(o.cycle, at[o.tag]! + n, reason: 'tag ${o.tag}');
          }
        }
      });
    }
  });

  group('div port', () {
    test('a busy divide does not stop the main pipe', () async {
      final config = _wide(4);
      final dut = HarborFpu(config, tagWidth: _tagW);
      await dut.build();
      final d = LaneDriver(dut);
      final r = Random(11);
      const fma = [
        HarborFpOp.add,
        HarborFpOp.sub,
        HarborFpOp.mul,
        HarborFpOp.madd,
        HarborFpOp.msub,
        HarborFpOp.nmsub,
        HarborFpOp.nmadd,
      ];
      final main = FpuPort('', _cases(config, r, 64, 150, ops: fma));
      final div = FpuPort('div_', [
        for (var l = 0; l < 64; l++)
          [for (var i = 0; i < 4; i++) divCase(config, r)],
      ]);
      var divBusy = 0;
      await runBench(
        d,
        [main, div],
        random: Random(12),
        readyMask: (_, p) => p == main
            ? -1
            : _rnd.nextInt(10) < 7
            ? -1
            : 0,
        hook: (cycle, p, inReady, _) {
          if (p == main && cycle < 150 && inReady != -1) {
            fail('main in_ready low at cycle $cycle');
          }
          if (p == div && cycle < 150 && inReady != -1) {
            divBusy++;
          }
        },
      );
      for (var l = 0; l < 64; l++) {
        checkLane(main, l, latency: 4);
        checkLane(div, l);
        expect(main.logs[l].accepts.map((a) => a.cycle), [
          for (var c = 0; c < 150; c++) c,
        ]);
      }
      expect(divBusy, greaterThan(100));
    });

    test('pipelined divider, stalls and kill', () async {
      final config = _wide(2, divMode: HarborFpDivMode.pipelined, divStages: 4);
      final dut = HarborFpu(config, tagWidth: _tagW);
      await dut.build();
      final d = LaneDriver(dut);
      final r = Random(13);
      final main = FpuPort('', _cases(config, r, 64, 30));
      final div = FpuPort('div_', [
        for (var l = 0; l < 64; l++)
          [for (var i = 0; i < 50; i++) divCase(config, r)],
      ], validGap: 0.2);
      await runBench(d, [main, div], random: Random(14), flushRate: 0.02);
      var outs = 0;
      for (var l = 0; l < 64; l++) {
        checkLane(main, l, latency: 2);
        checkLane(div, l, latency: dut.divLatency);
        outs += div.logs[l].outs.length;
      }
      expect(outs, greaterThan(500));
    });
  });

  test('wide sweep on the N=0 build in LaneSim', () async {
    final config = _wide(0, divMode: HarborFpDivMode.pipelined, divStages: 0);
    final dut = HarborFpu(config, tagWidth: _tagW);
    await dut.build();
    final d = LaneDriver(dut);
    final sim = d.sim;
    final r = Random(15);
    final names = [
      'op',
      'fmt',
      'fmt_dst',
      'fmt_narrow',
      'rm',
      'a',
      'b',
      'c',
      'li_index',
      'int_signed',
      'int_width',
    ];
    d
      ..putMask('reset', 0)
      ..putMask('in_valid', -1)
      ..putMask('out_ready', -1)
      ..putMask('div_in_valid', -1)
      ..putMask('div_out_ready', -1);
    final perOp = <HarborFpOp, int>{};
    var count = 0;
    for (var batch = 0; batch < 700; batch++) {
      final cases = [for (var l = 0; l < 64; l++) mainCase(config, r)];
      final divs = [for (var l = 0; l < 64; l++) divCase(config, r)];
      for (final name in names) {
        d.put('in_$name', [for (final c in cases) c.fields[name]!]);
      }
      for (final name in ['op', 'fmt', 'rm', 'a', 'b']) {
        d.put('div_in_$name', [for (final c in divs) c.fields[name]!]);
      }
      d.put('in_tag', [for (var l = 0; l < 64; l++) BigInt.from(batch + l)]);
      d.eval();
      expect(d.mask('out_valid'), -1);
      expect(d.mask('div_out_valid'), -1);
      final res = d.read('out_result');
      final flags = d.read('out_flags');
      final tags = d.read('out_tag');
      final dres = d.read('div_out_result');
      final dflags = d.read('div_out_flags');
      for (var l = 0; l < 64; l++) {
        final c = cases[l];
        final op = HarborFpOp.values[c.fields['op']!.toInt()];
        perOp[op] = (perOp[op] ?? 0) + 1;
        expect(
          (res[l], flags[l].toInt()),
          (c.expect.bits, c.expect.flags),
          reason: '$c',
        );
        expect(tags[l].toInt(), batch + l);
        if (batch < 100) {
          final dc = divs[l];
          expect(
            (dres[l], dflags[l].toInt()),
            (dc.expect.bits, dc.expect.flags),
            reason: '$dc',
          );
        }
        count++;
      }
    }
    expect(sim.flopCount, greaterThan(0));
    expect(count, 700 * 64);
    expect(perOp.length, HarborFpOp.values.length - 2);
  });
}
