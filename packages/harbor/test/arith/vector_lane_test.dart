import 'dart:math';

import 'package:harbor/src/arith/fp_format.dart';
import 'package:harbor/src/arith/fpu_config.dart';
import 'package:harbor/src/arith/vector_lane.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'fp_model.dart';
import 'fpu_bench.dart';

const _fp16 = HarborFpFormat.fp16;
const _fp32 = HarborFpFormat.fp32;
const _fp64 = HarborFpFormat.fp64;
const _tagW = 8;

const _noPack = {
  HarborFpOp.fpToFp,
  HarborFpOp.fpToInt,
  HarborFpOp.intToFp,
  HarborFpOp.cvtModWD,
};
const _widen = {
  HarborFpOp.mul,
  HarborFpOp.madd,
  HarborFpOp.msub,
  HarborFpOp.nmsub,
  HarborFpOp.nmadd,
};

HarborVectorLane _lane(
  HarborFpuConfig fpu, {
  bool liveSew = false,
  bool packNarrow = false,
}) => HarborVectorLane(
  fpu,
  laneWidth: fpu.widest.width,
  liveSew: liveSew,
  packNarrow: packNarrow,
  tagWidth: _tagW,
);

BigInt _ones(int n) => (BigInt.one << n) - BigInt.one;

BigInt _randBits(Random r, int n) {
  var v = BigInt.zero;
  for (var i = 0; i < n; i += 16) {
    v = (v << 16) | BigInt.from(r.nextInt(1 << 16));
  }
  return v & _ones(n);
}

/// Elements of format index [fmt] in one beat of [lane].
int _ratio(HarborVectorLane lane, int fmt) {
  final f = lane.fpu.formats[fmt];
  return lane.packNarrow ? lane.laneWidth ~/ f.width : 1;
}

/// The lane result of per element results [elems] under [mask] and [tail].
FpResult _merge(
  List<FpResult> elems,
  int width,
  int mask,
  int tail,
  BigInt dest,
) {
  if (elems.length == 1) {
    final on = mask & 1 != 0 && tail > 0;
    return on ? elems.first : FpResult(dest, 0);
  }
  var bits = BigInt.zero;
  var flags = 0;
  for (var k = 0; k < elems.length; k++) {
    final on = (mask >> k) & 1 != 0 && k < tail;
    final v = on ? elems[k].bits : (dest >> (k * width)) & _ones(width);
    bits |= v << (k * width);
    if (on) {
      flags |= elems[k].flags;
    }
  }
  return FpResult(bits, flags);
}

/// A random beat for [lane] with a random mask, tail and destination.
///
/// The op comes from [mainCase]. A beat that packs gets new operands for
/// each element.
FpuCase _laneCase(HarborVectorLane lane, Random r, {List<HarborFpOp>? ops}) {
  final config = lane.fpu;
  final widest = config.formats.indexOf(config.widest);
  late FpuCase base;
  late HarborFpOp op;
  late int fmt;
  late bool widening;
  while (true) {
    base = mainCase(config, r, ops: ops);
    op = HarborFpOp.values[base.fields['op']!.toInt()];
    fmt = base.fields['fmt']!.toInt();
    widening = _widen.contains(op) && base.fields['fmt_narrow']! != BigInt.zero;
    if (lane.liveSew || fmt == widest || widening) {
      break;
    }
  }
  final e = lane.elementsPerBeat;
  final outW = lane.output('out_result').width;
  final mask = r.nextInt(4) == 0 ? r.nextInt(1 << e) : (1 << e) - 1;
  final tail = r.nextInt(4) == 0 ? r.nextInt(e + 1) : e;
  final dest = _randBits(r, outW);
  final fields = {
    ...base.fields,
    'sew': BigInt.from(fmt),
    'mask': BigInt.from(mask),
    'tail': BigInt.from(tail),
    'dest': dest,
  };

  final ratio = _ratio(lane, fmt);
  if (ratio == 1 || widening || _noPack.contains(op)) {
    return FpuCase(
      fields,
      _merge([base.expect], 0, mask, tail, dest),
      '${base.label} m$mask t$tail',
    );
  }
  final f = config.formats[fmt];
  final rm = base.fields['rm']!.toInt();
  final li = base.fields['li_index']!.toInt();
  final round = op == HarborFpOp.round || op == HarborFpOp.roundNx;
  final elems = <FpResult>[];
  var a = BigInt.zero;
  var b = BigInt.zero;
  var c = BigInt.zero;
  for (var k = 0; k < ratio; k++) {
    final ak = fpValue(f, r, intRange: round);
    final bk = fpValue(f, r);
    final ck = fpValue(f, r);
    a |= ak << (k * f.width);
    b |= bk << (k * f.width);
    c |= ck << (k * f.width);
    elems.add(
      fpuModel(config, op, fmt: fmt, rm: rm, a: ak, b: bk, c: ck, liIndex: li),
    );
  }
  fields
    ..['a'] = a
    ..['b'] = b
    ..['c'] = c
    ..['fmt_narrow'] = BigInt.zero;
  return FpuCase(
    fields,
    _merge(elems, f.width, mask, tail, dest),
    '${op.name} ${ratio}x$f rm$rm m$mask t$tail',
  );
}

List<List<FpuCase>> _cases(
  HarborVectorLane lane,
  Random r,
  int lanes,
  int perLane, {
  List<HarborFpOp>? ops,
}) => [
  for (var l = 0; l < lanes; l++)
    [for (var i = 0; i < perLane; i++) _laneCase(lane, r, ops: ops)],
];

FpuPort _port(List<List<FpuCase>> cases) =>
    FpuPort('', cases, validGap: 0.2, slotKillRate: 0.05);

/// Runs 64 lanes of [perLane] beats with stalls, gaps, slot kills and
/// flushes on LaneSim, and checks every lane against the model.
Future<void> _volume(
  HarborVectorLane lane,
  int seed, {
  int perLane = 50,
  List<HarborFpOp>? ops,
}) async {
  await lane.build();
  final p = _port(_cases(lane, Random(seed), 64, perLane, ops: ops));
  await runBench(
    LaneDriver(lane),
    [p],
    random: Random(seed + 1),
    flushRate: 0.01,
  );
  var killed = 0;
  var held = 0;
  var outs = 0;
  for (var l = 0; l < 64; l++) {
    killed += checkLane(p, l, latency: lane.latency);
    held += p.logs[l].held.length;
    outs += p.logs[l].outs.length;
  }
  expect(killed, greaterThan(0));
  expect(held, greaterThan(0));
  expect(outs, greaterThan(64 * perLane ~/ 2));
}

/// Runs one lane of [count] beats on LaneSim and on the ROHD simulator and
/// checks that both give the same log.
Future<void> _crossCheck(
  HarborVectorLane Function() make,
  int seed, {
  int count = 40,
  List<HarborFpOp>? ops,
}) async {
  Future<FpuPort> run(FpuDriver d, HarborVectorLane lane) async {
    final p = _port(_cases(lane, Random(seed), 1, count, ops: ops));
    await runBench(d, [p], random: Random(seed + 1), flushRate: 0.01);
    checkLane(p, 0, latency: lane.latency);
    return p;
  }

  final lane = make();
  await lane.build();
  final a = await run(LaneDriver(lane), lane);
  final other = make();
  final rohd = await RohdDriver.start(other);
  final b = await run(rohd, other);
  await rohd.done();
  expect(b.logs[0].outs, a.logs[0].outs);
  expect(b.logs[0].accepts, a.logs[0].accepts);
  expect(b.logs[0].killed, a.logs[0].killed);
  expect(a.logs[0].outs, isNotEmpty);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('config checks', () {
    test('packNarrow needs liveSew', () {
      expect(
        () => HarborVectorLane(
          HarborFpuConfig(
            formats: [_fp32, _fp64],
            ops: {HarborFpOp.add},
            stages: 1,
          ),
          laneWidth: 64,
          packNarrow: true,
        ),
        throwsArgumentError,
      );
    });

    test('laneWidth is the widest format', () {
      expect(
        () => HarborVectorLane(
          HarborFpuConfig(
            formats: [_fp32, _fp64],
            ops: {HarborFpOp.add},
            stages: 1,
          ),
          laneWidth: 32,
        ),
        throwsArgumentError,
      );
    });

    test('slots and elements per beat', () {
      final fpu = HarborFpuConfig(
        formats: [_fp16, _fp32, _fp64],
        ops: {HarborFpOp.add},
        stages: 3,
      );
      final lane = _lane(fpu, liveSew: true, packNarrow: true);
      expect(lane.elementsPerBeat, 4);
      expect(lane.slots, 4);
      expect(lane.slotNames.first, 'skid');
      expect(lane.input('in_mask').width, 4);
      expect(lane.input('in_tail').width, 3);
      expect(lane.output('slot_tag').width, 4 * _tagW);
      expect(_lane(fpu, liveSew: true).elementsPerBeat, 1);
    });

    test('needs a non-div, non-sqrt main op', () {
      expect(
        () => HarborVectorLane(
          HarborFpuConfig(formats: [_fp32], ops: {HarborFpOp.div}, stages: 1),
          laneWidth: 32,
        ),
        throwsArgumentError,
      );
    });

    test('packNarrow needs every format width to divide laneWidth', () {
      const odd = HarborFpFormat(5, 18); // width 24, does not divide 64
      expect(
        () => HarborVectorLane(
          HarborFpuConfig(
            formats: [odd, _fp64],
            ops: {HarborFpOp.add},
            stages: 1,
          ),
          laneWidth: 64,
          liveSew: true,
          packNarrow: true,
        ),
        throwsArgumentError,
      );
    });

    test('packNarrow needs a packable op', () {
      expect(
        () => HarborVectorLane(
          HarborFpuConfig(
            formats: [_fp16, _fp32],
            ops: {HarborFpOp.fpToFp},
            stages: 1,
          ),
          laneWidth: 32,
          liveSew: true,
          packNarrow: true,
        ),
        throwsArgumentError,
      );
    });
  });

  group('fixed fp16 x fp16 + fp32 widening lane', () {
    final fpu = HarborFpuConfig(
      formats: [_fp16, _fp32],
      widening: [(_fp16, _fp32)],
      ops: {
        HarborFpOp.add,
        HarborFpOp.mul,
        HarborFpOp.madd,
        HarborFpOp.msub,
        HarborFpOp.nmsub,
        HarborFpOp.nmadd,
      },
      stages: 2,
    );

    test('LaneSim vs model, 3200 beats', () async {
      await _volume(_lane(fpu), 100);
    });

    test('ROHD simulator matches LaneSim', () async {
      await _crossCheck(() => _lane(fpu), 110, count: 60);
    });
  });

  group('live SEW switching', () {
    final fpu = HarborFpuConfig(
      formats: [_fp16, _fp32, _fp64],
      ops: HarborFpOp.values.toSet().difference({
        HarborFpOp.div,
        HarborFpOp.sqrt,
      }),
      stages: 3,
      intWidths: [32, 64],
    );

    test('every op, sew picked each beat, LaneSim vs model', () async {
      await _volume(_lane(fpu, liveSew: true), 200);
    });

    test('ROHD simulator matches LaneSim', () async {
      await _crossCheck(() => _lane(fpu, liveSew: true), 210);
    });
  });

  group('packNarrow per element results', () {
    const ops = {
      HarborFpOp.add,
      HarborFpOp.sub,
      HarborFpOp.mul,
      HarborFpOp.madd,
      HarborFpOp.nmsub,
      HarborFpOp.min,
      HarborFpOp.lt,
      HarborFpOp.sgnjx,
      HarborFpOp.classify,
      HarborFpOp.round,
      HarborFpOp.fpToFp,
    };

    test('2 x fp32 in a 64-bit lane', () async {
      final fpu = HarborFpuConfig(formats: [_fp32, _fp64], ops: ops, stages: 2);
      final lane = _lane(fpu, liveSew: true, packNarrow: true);
      expect(lane.elementsPerBeat, 2);
      await _volume(lane, 300);
    });

    test('4 x fp16 in a 64-bit lane', () async {
      final fpu = HarborFpuConfig(formats: [_fp16, _fp64], ops: ops, stages: 2);
      final lane = _lane(fpu, liveSew: true, packNarrow: true);
      expect(lane.elementsPerBeat, 4);
      await _volume(lane, 310);
    });

    final mixed = HarborFpuConfig(
      formats: [_fp16, _fp32, _fp64],
      widening: [(_fp16, _fp32), (_fp32, _fp64)],
      ops: ops,
      stages: 1,
    );

    test('fp16, fp32 and fp64 beats mixed, with widening', () async {
      await _volume(_lane(mixed, liveSew: true, packNarrow: true), 320);
    });

    test('ROHD simulator matches LaneSim', () async {
      await _crossCheck(
        () => _lane(mixed, liveSew: true, packNarrow: true),
        330,
      );
    });
  });

  group('packNarrow every op, two 16-bit groups', () {
    // fp16 and bf16 are both 16 bits, giving two narrow groups at ratio 4
    // plus fp32 at ratio 2, so routing picks among more than one group.
    // Covers every op the narrow units build, not just the common ones.
    HarborFpuConfig allOpsFpu(int stages) => HarborFpuConfig(
      formats: [_fp16, HarborFpFormat.bf16, _fp32, _fp64],
      widening: [(_fp16, _fp32), (_fp32, _fp64)],
      ops: HarborFpOp.values.toSet().difference({
        HarborFpOp.div,
        HarborFpOp.sqrt,
      }),
      stages: stages,
      intWidths: [32, 64],
    );

    for (final st in [0, 2, 7]) {
      test('every op, two 16-bit narrow groups, stages $st', () async {
        final lane = _lane(allOpsFpu(st), liveSew: true, packNarrow: true);
        expect(lane.elementsPerBeat, 4);
        await _volume(lane, 900 + st, perLane: 25);
      });
    }

    test('ROHD simulator matches LaneSim, stages 0', () async {
      await _crossCheck(
        () => _lane(allOpsFpu(0), liveSew: true, packNarrow: true),
        950,
      );
    });
  });

  group('mask, tail and flag OR-reduce', () {
    test(
      'every mask and tail 0 to 7 on 4 x fp16 with a different flag each',
      () async {
        final fpu = HarborFpuConfig(
          formats: [_fp16, _fp64],
          ops: {HarborFpOp.mul},
          stages: 1,
        );
        final lane = _lane(fpu, liveSew: true, packNarrow: true);
        await lane.build();

        // NV, OF and NX, NX alone, UF and NX.
        final a = [0x7d00, 0x7bff, 0x3c01, 0x0001];
        final b = [0x3c00, 0x4000, 0x3c01, 0x3800];
        final elems = [
          for (var k = 0; k < 4; k++)
            fpMul(_fp16, BigInt.from(a[k]), BigInt.from(b[k]), rmRne),
        ];
        expect(elems.map((e) => e.flags).toSet(), {
          nvFlag,
          ofFlag | nxFlag,
          nxFlag,
          ufFlag | nxFlag,
        });
        BigInt pack(List<int> v) => [
          for (var k = 0; k < 4; k++) BigInt.from(v[k]) << (16 * k),
        ].reduce((x, y) => x | y);

        final r = Random(400);
        final cases = <List<FpuCase>>[for (var l = 0; l < 64; l++) []];
        var i = 0;
        // Tail 5 to 7 are above elementsPerBeat (4) but still fit the
        // 3-bit field; they must behave the same as tail 4.
        for (var mask = 0; mask < 16; mask++) {
          for (var tail = 0; tail <= 7; tail++) {
            final dest = _randBits(r, 64);
            cases[i++ % 64].add(
              FpuCase(
                {
                  'op': BigInt.from(HarborFpOp.mul.index),
                  'sew': BigInt.zero,
                  'rm': BigInt.from(rmRne),
                  'a': pack(a),
                  'b': pack(b),
                  'mask': BigInt.from(mask),
                  'tail': BigInt.from(tail),
                  'dest': dest,
                },
                _merge(elems, 16, mask, tail, dest),
                'm$mask t$tail',
              ),
            );
          }
        }
        final p = FpuPort('', cases, readyLow: 0);
        await runBench(LaneDriver(lane), [p], random: Random(401));
        for (var l = 0; l < 64; l++) {
          checkLane(p, l, latency: lane.latency);
        }
      },
    );
  });

  group('div port', () {
    test('is the div port of main, next to a busy main pipe', () async {
      final fpu = HarborFpuConfig(
        formats: [_fp32],
        ops: {HarborFpOp.add, HarborFpOp.div, HarborFpOp.sqrt},
        stages: 1,
      );
      final lane = _lane(fpu);
      await lane.build();
      expect(lane.hasDiv, isTrue);
      final r = Random(500);
      final main = _port(_cases(lane, r, 64, 20));
      final div = FpuPort(
        'div_',
        [
          for (var l = 0; l < 64; l++)
            [for (var i = 0; i < 6; i++) divCase(fpu, r)],
        ],
        validGap: 0.3,
        slotKillRate: 0.02,
      );
      await runBench(LaneDriver(lane), [main, div], random: Random(501));
      for (var l = 0; l < 64; l++) {
        checkLane(main, l, latency: lane.latency);
        checkLane(div, l);
      }
    });
  });

  group('packNarrow multiply equivalence', () {
    // Element 0 of a packed beat and the one element an unpacked beat
    // runs must give the same result for every multiply op and format.
    HarborFpuConfig cfg(Set<HarborFpFormat>? mf) => HarborFpuConfig(
      formats: [_fp16, _fp32],
      widening: [(_fp16, _fp32)],
      ops: _widen,
      stages: 2,
      mulFormats: mf,
    );

    List<FpuCase> cases(HarborFpuConfig config, int seed) {
      final r = Random(seed);
      final ops = _widen.toList();
      final formats = config.formats;
      return [
        // _tagW is 8 bits, so the tag (the case index) must fit in 0..255.
        for (var i = 0; i < 200; i++)
          () {
            final op = ops[r.nextInt(ops.length)];
            final fmt = r.nextInt(formats.length);
            final f = formats[fmt];
            final rm = r.nextInt(5);
            return FpuCase(
              {
                'op': BigInt.from(op.index),
                'sew': BigInt.from(fmt),
                'fmt_narrow': BigInt.zero,
                'rm': BigInt.from(rm),
                'a': fpValue(f, r),
                'b': fpValue(f, r),
                'c': fpValue(f, r),
                'mask': BigInt.one,
                'tail': BigInt.one,
                'dest': BigInt.zero,
              },
              FpResult(BigInt.zero, 0),
              '${op.name} $f rm$rm',
            );
          }(),
      ];
    }

    Future<void> run(Set<HarborFpFormat>? mf, int seed) async {
      final config = cfg(mf);
      Future<FpuPort> go(HarborVectorLane lane) async {
        await lane.build();
        final p = FpuPort(
          '',
          [cases(config, seed)],
          validGap: 0.2,
          slotKillRate: 0.05,
        );
        await runBench(
          LaneDriver(lane),
          [p],
          random: Random(seed + 1),
          flushRate: 0.01,
        );
        return p;
      }

      final packed = HarborVectorLane(
        config,
        laneWidth: config.widest.width,
        liveSew: true,
        packNarrow: true,
        tagWidth: _tagW,
      );
      final unpacked = HarborVectorLane(
        config,
        laneWidth: config.widest.width,
        liveSew: true,
        tagWidth: _tagW,
      );
      final a = await go(packed);
      final b = await go(unpacked);
      expect(b.logs[0].accepts, a.logs[0].accepts);
      expect(b.logs[0].outs, a.logs[0].outs);
      expect(b.logs[0].killed, a.logs[0].killed);
      expect(a.logs[0].outs, isNotEmpty);
    }

    test('mulFormats null matches an unpacked lane', () async {
      await run(null, 601);
    });

    test('mulFormats const {} matches an unpacked lane', () async {
      await run(const {}, 603);
    });
  });
}
