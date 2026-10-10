import 'dart:async';
import 'dart:isolate';
import 'dart:math';

import 'package:harbor/src/arith/fp_fma_path.dart';
import 'package:harbor/src/arith/fp_format.dart';
import 'package:harbor/src/arith/fpu_config.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' show ColumnCompressor;
import 'package:test/test.dart';

import 'fp_model.dart';
import 'lane_sim.dart';
import 'testfloat_vectors.dart';

const _fp16 = HarborFpFormat.fp16;
const _fp32 = HarborFpFormat.fp32;
const _fp64 = HarborFpFormat.fp64;

final _tfNames = {_fp16: 'f16', _fp32: 'f32', _fp64: 'f64'};
const _rmNames = ['near_even', 'minMag', 'min', 'max', 'near_maxMag'];

String? get _skip => testFloatAvailable()
    ? null
    : 'testfloat_gen not found; set HARBOR_TESTFLOAT_GEN or run inside '
          '`nix develop`';

class _Case {
  final HarborFpOp op;
  final int fmt;
  final int narrow;
  final int rm;
  final BigInt a;
  final BigInt b;
  final BigInt c;

  const _Case(
    this.op,
    this.rm,
    this.a,
    this.b,
    this.c, {
    this.fmt = 0,
    this.narrow = 0,
  });

  @override
  String toString() =>
      '${op.name} fmt=$fmt narrow=$narrow rm=$rm '
      'a=${a.toRadixString(16)} b=${b.toRadixString(16)} '
      'c=${c.toRadixString(16)}';
}

/// The combinational path with free inputs.
class _Bench {
  final HarborFpuConfig config;
  final Logic op = Logic(name: 'op', width: harborFpOpWidth);
  final Logic rm = Logic(name: 'rm', width: 3);
  late final Logic fmt;
  late final Logic narrow;
  late final Logic a;
  late final Logic b;
  late final Logic c;

  /// The enable of every register, when the bench has a clock.
  final Logic en = Logic(name: 'en');
  late final HarborFpFmaPath path;
  late final LaneSim sim;

  _Bench._(this.config, Logic? clk) {
    fmt = Logic(
      name: 'fmt',
      width: max(1, (config.formats.length - 1).bitLength),
    );
    narrow = Logic(name: 'narrow', width: harborFpNarrowWidth(config));
    final w = config.widest.width;
    a = Logic(name: 'a', width: w);
    b = Logic(name: 'b', width: w);
    c = Logic(name: 'c', width: w);
    path = HarborFpFmaPath(
      config,
      op: op,
      fmt: fmt,
      fmtNarrow: narrow,
      rm: rm,
      a: a,
      b: b,
      c: c,
      clk: clk,
      enables: clk == null ? const {} : {for (final k in config.cuts) k: en},
    );
  }

  static Future<_Bench> create(HarborFpuConfig config, {Logic? clk}) async {
    final bench = _Bench._(config, clk);
    await bench.path.build();
    if (clk == null) {
      bench.sim = LaneSim(
        bench.path,
        [
          bench.path.op,
          bench.path.rm,
          bench.path.fmt,
          bench.path.fmtNarrow,
          bench.path.a,
          bench.path.b,
          bench.path.c,
        ],
        [bench.path.result, bench.path.flags],
      );
    }
    return bench;
  }

  List<FpResult> run(List<_Case> cases) {
    final out = <FpResult>[];
    for (var i = 0; i < cases.length; i += LaneSim.lanes) {
      final part = cases.sublist(i, min(i + LaneSim.lanes, cases.length));
      sim
        ..set(path.op, [for (final k in part) BigInt.from(k.op.index)])
        ..set(path.rm, [for (final k in part) BigInt.from(k.rm)])
        ..set(path.fmt, [for (final k in part) BigInt.from(k.fmt)])
        ..set(path.fmtNarrow, [for (final k in part) BigInt.from(k.narrow)])
        ..set(path.a, [for (final k in part) k.a])
        ..set(path.b, [for (final k in part) k.b])
        ..set(path.c, [for (final k in part) k.c])
        ..run();
      final bits = sim.get(path.result, part.length);
      final flags = sim.get(path.flags, part.length);
      for (var j = 0; j < part.length; j++) {
        out.add(FpResult(bits[j], flags[j].toInt()));
      }
    }
    return out;
  }

  /// Drives the ports of a built path in the ROHD simulator.
  void put(_Case k) {
    op.put(k.op.index);
    rm.put(k.rm);
    fmt.put(k.fmt);
    narrow.put(k.narrow);
    a.put(LogicValue.ofBigInt(k.a, a.width));
    b.put(LogicValue.ofBigInt(k.b, b.width));
    c.put(LogicValue.ofBigInt(k.c, c.width));
  }

  FpResult read() =>
      FpResult(path.result.value.toBigInt(), path.flags.value.toInt());
}

/// Compares [cases] run on [bench] with [expected], and lists the first
/// mismatches.
void _check(_Bench bench, List<_Case> cases, List<FpResult> expected) {
  final got = bench.run(cases);
  final bad = <String>[];
  var count = 0;
  for (var i = 0; i < cases.length; i++) {
    if (got[i].bits != expected[i].bits || got[i].flags != expected[i].flags) {
      count++;
      if (bad.length < 8) {
        bad.add('${cases[i]}: got ${got[i]}, want ${expected[i]}');
      }
    }
  }
  expect(
    count,
    0,
    reason: '$count of ${cases.length} wrong:\n${bad.join('\n')}',
  );
}

/// The ops that use the widening pair that `fmt_narrow` selects.
bool _widens(HarborFpOp op) => _fmaOps.contains(op) || op == HarborFpOp.mul;

/// The exact product rounded to the wide format. mul adds the zero that keeps
/// the sign of an exact zero product.
FpResult _wideMul(
  HarborFpFormat fa,
  HarborFpFormat fc,
  BigInt a,
  BigInt b,
  int rm,
  bool ftz,
) {
  final zero = rm == 2 ? BigInt.zero : BigInt.one << (fc.width - 1);
  return fpFma(fa, fc, a, b, zero, rm, ftz: ftz);
}

FpResult _model(HarborFpuConfig config, _Case k) {
  final ftz = config.ftz;
  if (k.narrow != 0 && _widens(k.op)) {
    final (fa, fc) = config.widening[k.narrow - 1];
    if (k.op == HarborFpOp.mul) {
      return _wideMul(fa, fc, k.a, k.b, k.rm, ftz);
    }
    return _fma(k.op, fa, fc, k.a, k.b, k.c, k.rm, ftz);
  }
  final f = config.formats[k.fmt];
  final pm = harborFpProductWidth(config);
  if (_widens(k.op) && f.mantissaWidth + 1 > pm) {
    return FpResult(_canonicalNan(f), 0x10);
  }
  return switch (k.op) {
    HarborFpOp.add => fpAdd(f, k.a, k.b, k.rm, ftz: ftz),
    HarborFpOp.sub => fpSub(f, k.a, k.b, k.rm, ftz: ftz),
    HarborFpOp.mul => fpMul(f, k.a, k.b, k.rm, ftz: ftz),
    _ => _fma(k.op, f, f, k.a, k.b, k.c, k.rm, ftz),
  };
}

BigInt _canonicalNan(HarborFpFormat f) =>
    (((BigInt.one << f.exponentWidth) - BigInt.one) << f.mantissaWidth) |
    (BigInt.one << (f.mantissaWidth - 1));

FpResult _fma(
  HarborFpOp op,
  HarborFpFormat fa,
  HarborFpFormat fc,
  BigInt a,
  BigInt b,
  BigInt c,
  int rm,
  bool ftz,
) => fpFma(
  fa,
  fc,
  a,
  b,
  c,
  rm,
  negProduct: op == HarborFpOp.nmsub || op == HarborFpOp.nmadd,
  negAddend: op == HarborFpOp.msub || op == HarborFpOp.nmadd,
  ftz: ftz,
);

BigInt _bits(Random r, int width) {
  var v = BigInt.zero;
  for (var i = 0; i < width; i += 16) {
    v |= BigInt.from(r.nextInt(1 << 16)) << i;
  }
  return v & ((BigInt.one << width) - BigInt.one);
}

BigInt _pack(HarborFpFormat f, int sign, int exp, BigInt mant) =>
    (BigInt.from(sign) << (f.width - 1)) |
    (BigInt.from(exp) << f.mantissaWidth) |
    mant;

/// A value with extra weight on zeros, subnormals, Inf, NaN and the ends of
/// the exponent range.
BigInt _value(Random r, HarborFpFormat f) {
  final m = f.mantissaWidth;
  final top = (1 << f.exponentWidth) - 1;
  final sign = r.nextInt(2);
  var mant = _bits(r, m);
  if (r.nextInt(4) == 0) {
    // Runs of ones or a single bit stress carries and sticky bits.
    mant = r.nextBool()
        ? (BigInt.one << m) - (BigInt.one << r.nextInt(m))
        : BigInt.one << r.nextInt(m);
  }
  return switch (r.nextInt(14)) {
    0 => _pack(f, sign, 0, BigInt.zero),
    1 || 2 => _pack(f, sign, 0, mant == BigInt.zero ? BigInt.one : mant),
    3 => _pack(f, sign, top, BigInt.zero),
    4 => _pack(f, sign, top, mant == BigInt.zero ? BigInt.one : mant),
    5 => _pack(f, sign, 1 + r.nextInt(3), mant),
    6 => _pack(f, sign, top - 1 - r.nextInt(3), mant),
    7 => _pack(f, sign, f.bias + r.nextInt(5) - 2, mant),
    _ => _pack(f, sign, 1 + r.nextInt(top - 1), mant),
  };
}

/// An addend near minus the product, so the sum cancels.
BigInt _cancel(
  Random r,
  HarborFpFormat fa,
  HarborFpFormat fc,
  BigInt a,
  BigInt b,
) {
  final wa = fa == fc ? a : fpToFp(fa, fc, a, 0).bits;
  final wb = fa == fc ? b : fpToFp(fa, fc, b, 0).bits;
  final p = fpMul(fc, wa, wb, r.nextInt(5)).bits;
  final flipped = p ^ (BigInt.one << (fc.width - 1));
  return r.nextBool() ? flipped : flipped ^ BigInt.from(r.nextInt(16));
}

const _fmaOps = [
  HarborFpOp.madd,
  HarborFpOp.msub,
  HarborFpOp.nmsub,
  HarborFpOp.nmadd,
];

List<BigInt> _corners(HarborFpFormat f) {
  final m = f.mantissaWidth;
  final top = (1 << f.exponentWidth) - 1;
  final ones = (BigInt.one << m) - BigInt.one;
  final quiet = BigInt.one << (m - 1);
  return [
    for (final s in [0, 1]) ...[
      _pack(f, s, 0, BigInt.zero),
      _pack(f, s, 0, BigInt.one),
      _pack(f, s, 0, ones),
      _pack(f, s, 1, BigInt.zero),
      _pack(f, s, f.bias, BigInt.zero),
      _pack(f, s, f.bias, BigInt.one),
      _pack(f, s, f.bias - 1, ones),
      _pack(f, s, top - 1, ones),
      _pack(f, s, top, BigInt.zero),
    ],
    _pack(f, 0, top, quiet),
    _pack(f, 0, top, BigInt.one),
  ];
}

Future<void> _testFloat(
  _Bench bench,
  HarborFpFormat f,
  HarborFpOp op,
  int rm, {
  int level = 1,
  int stride = 1,
}) async {
  final tfOp = '${_tfNames[f]}_${op == HarborFpOp.madd ? 'mulAdd' : op.name}';
  final vectors = await testFloatCases(
    tfOp,
    rm: _rmNames[rm],
    level: level,
    stride: stride,
  ).toList();
  expect(vectors, isNotEmpty);
  final cases = [
    for (final v in vectors)
      _Case(
        op,
        rm,
        v.operands[0],
        v.operands[1],
        v.operands.length > 2 ? v.operands[2] : BigInt.zero,
      ),
  ];
  _check(bench, cases, [for (final v in vectors) FpResult(v.result, v.flags)]);
}

/// Random cases of all seven ops with edge operands, all rm, and random
/// fmt and fmt_narrow.
List<_Case> _mixed(HarborFpuConfig config, Random r, int n) {
  final corners = {for (final f in config.formats) f: _corners(f)};
  BigInt pick(HarborFpFormat f) => r.nextInt(4) == 0
      ? corners[f]![r.nextInt(corners[f]!.length)]
      : _value(r, f);
  return [
    for (var i = 0; i < n; i++)
      () {
        final op = HarborFpOp.values[r.nextInt(7)];
        final narrow = config.widening.isNotEmpty && r.nextBool()
            ? 1 + r.nextInt(config.widening.length)
            : 0;
        final fmt = r.nextInt(config.formats.length);
        final (fa, fc) = narrow != 0 && _widens(op)
            ? config.widening[narrow - 1]
            : (config.formats[fmt], config.formats[fmt]);
        final addSub = op == HarborFpOp.add || op == HarborFpOp.sub;
        final a = pick(fa);
        final b = pick(addSub ? fc : fa);
        final c = i % 3 == 0 && fa == fc ? _cancel(r, fa, fc, a, b) : pick(fc);
        return _Case(op, i % 5, a, b, c, fmt: fmt, narrow: narrow);
      }(),
  ];
}

/// Runs [cases] on a combinational build in the ROHD simulator. The cases
/// are split over isolates, because the event simulator is slow on the
/// product tree.
Future<List<FpResult>> _rohdComb(
  HarborFpuConfig config,
  List<_Case> cases,
) async {
  final chunk = (cases.length / 32).ceil();
  final parts = await Future.wait([
    for (var i = 0; i < cases.length; i += chunk)
      _rohdCombPart(config, cases.sublist(i, min(i + chunk, cases.length))),
  ]);
  return [for (final part in parts) ...part];
}

Future<List<FpResult>> _rohdCombPart(
  HarborFpuConfig config,
  List<_Case> cases,
) => Isolate.run(() async {
  final bench = _Bench._(config, null);
  await bench.path.build();
  return [for (final k in cases) (bench..put(k)).read()];
});

/// Runs [cases] in order through a registered build in the ROHD simulator.
/// The enable of all registers goes low on random cycles, and other operands
/// are on the ports during those cycles. Returns each output seen as
/// `(case index, result)`, so a result that changes in a stall is caught.
Future<List<(int, FpResult)>> _rohdStall(
  HarborFpuConfig config,
  List<_Case> cases,
  List<_Case> junk,
  int seed,
) => Isolate.run(() async {
  final clk = SimpleClockGenerator(10).clk;
  final bench = _Bench._(config, clk);
  await bench.path.build();
  final r = Random(seed);
  final seen = <(int, FpResult)>[];
  bench
    ..put(junk.first)
    ..en.put(0);
  unawaited(Simulator.run());
  var issued = 0;
  for (;;) {
    await clk.nextNegedge;
    final i = issued - config.latency;
    if (i >= 0) {
      seen.add((i, bench.read()));
    }
    if (i >= cases.length - 1) {
      break;
    }
    // Stalls come alone or in runs.
    final go = r.nextInt(3) != 0;
    bench
      ..put(
        go && issued < cases.length
            ? cases[issued]
            : junk[r.nextInt(junk.length)],
      )
      ..en.put(go ? 1 : 0);
    if (go) {
      issued++;
    }
  }
  await Simulator.endSimulation();
  return seen;
});

/// Sum of the widths of the signals that cross each cut.
Map<HarborFpCut, int> _cutBits(HarborFpFmaPath path) => {
  for (final e in path.cuts.entries)
    e.key: e.value.fold(0, (s, l) => s + l.width),
};

class _XConst extends Module {
  _XConst(Logic a) {
    a = addInput('a', a, width: 2);
    addOutput('y', width: 2) <= a ^ Const(LogicValue.ofString('x1'));
  }
}

class _Loop extends Module {
  _Loop(Logic a) {
    a = addInput('a', a);
    final x = Logic(name: 'x');
    x <= ~(a & x);
    addOutput('y') <= x;
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  for (final mult in HarborFpMultiplier.values) {
    group(mult.name, () => _suite(mult));
  }

  group('TestFloat level 2', () {
    // add/mul/div's level 2 sweep is exhaustive over the operand space:
    // about 7.5M cases at fp32, 40M at fp64. The stride below samples
    // about 50,000 of them, evenly spread, through the dsp multiplier
    // only (round/pack correctness does not depend on the multiplier
    // mode, and level 1 already covers both modes on a small sample).
    //
    // mulAdd's level 2 set (three operands) has no stride-friendly path:
    // `testfloat_gen -n` refuses a count below the full exhaustive set
    // (measured floor at fp32: 14,512,627,712), and `stride` only thins
    // the stream after it is generated, so either way the generator must
    // run to completion first. At the observed ~2.5M lines/s that floor
    // alone is over 95 minutes of generation per rm, before any Dart-side
    // cost, so mulAdd's level 2 sweep is not run. Level 1's mulAdd stride
    // (every 61st case) and the random/corner mulAdd runs against the
    // Dart model, both already in this file, are the mulAdd coverage.
    final strides = {_fp32: 149, _fp64: 805};
    for (final f in [_fp32, _fp64]) {
      group(_tfNames[f], () {
        late _Bench bench;
        setUpAll(() async {
          bench = await _Bench.create(
            HarborFpuConfig(formats: [f], ops: harborFpFmaOps, stages: 0),
          );
        });

        for (var rm = 0; rm < 5; rm++) {
          for (final op in [HarborFpOp.add, HarborFpOp.mul]) {
            test(
              '${op.name} rm=${_rmNames[rm]}',
              () => _testFloat(bench, f, op, rm, level: 2, stride: strides[f]!),
              tags: ['slow'],
              skip: _skip,
              timeout: const Timeout(Duration(minutes: 30)),
            );
          }
        }
      });
    }
  });

  group('multiplier', () {
    for (final (f, count) in [(_fp16, 1), (_fp32, 4), (_fp64, 9)]) {
      test(
        'dsp mode builds $count slice products for ${_tfNames[f]}',
        () async {
          final bench = await _Bench.create(
            HarborFpuConfig(formats: [f], ops: harborFpFmaOps, stages: 0),
          );
          final muls = _modules(bench.path).whereType<Multiply>().toList();
          expect(muls, hasLength(count));
          for (final m in muls) {
            expect(m.out.width, lessThanOrEqualTo(36));
          }
          expect(_modules(bench.path).whereType<ColumnCompressor>(), isEmpty);
        },
      );
    }

    test('compressionTree mode has no multiply', () async {
      final bench = await _Bench.create(
        HarborFpuConfig(
          multiplier: HarborFpMultiplier.compressionTree,
          formats: [_fp32],
          ops: harborFpFmaOps,
          stages: 0,
        ),
      );
      expect(_modules(bench.path).whereType<Multiply>(), isEmpty);
    });

    test('mulSlice sets the slice products', () async {
      final bench = await _Bench.create(
        HarborFpuConfig(
          formats: [_fp32],
          ops: harborFpFmaOps,
          stages: 0,
          mulSlice: (26, 17),
        ),
      );
      final muls = _modules(bench.path).whereType<Multiply>().toList();
      expect([for (final m in muls) m.out.width], [24 + 12, 24 + 12]);
    });

    test('add and sub alone build no multiply', () async {
      final bench = await _Bench.create(
        HarborFpuConfig(
          formats: [_fp32],
          ops: {HarborFpOp.add, HarborFpOp.sub},
          stages: 0,
        ),
      );
      expect(bench.path.productWidth, 0);
      expect(_modules(bench.path).whereType<Multiply>(), isEmpty);
      final r = Random(23);
      final cases = [
        for (var i = 0; i < 4000; i++)
          _Case(
            i.isEven ? HarborFpOp.add : HarborFpOp.sub,
            i % 5,
            _value(r, _fp32),
            _value(r, _fp32),
            BigInt.zero,
          ),
      ];
      _check(bench, cases, [for (final k in cases) _model(bench.config, k)]);
    });

    test('mulFormats must be in formats', () {
      expect(
        () => HarborFpuConfig(
          formats: [_fp32],
          ops: harborFpFmaOps,
          stages: 0,
          mulFormats: {_fp16},
        ),
        throwsArgumentError,
      );
      expect(
        () => HarborFpuConfig(
          formats: [_fp32],
          ops: {HarborFpOp.madd},
          stages: 0,
          mulFormats: const {},
        ),
        throwsArgumentError,
      );
      expect(
        () => HarborFpuConfig(
          formats: [_fp32],
          ops: harborFpFmaOps,
          stages: 0,
          mulSlice: (18, 1),
        ),
        throwsArgumentError,
      );
    });
  });
}

/// [m] and every module below it.
Iterable<Module> _modules(Module m) sync* {
  yield m;
  for (final s in m.subModules) {
    yield* _modules(s);
  }
}

void _suite(HarborFpMultiplier mult) {
  final skip = _skip;

  for (final f in [_fp16, _fp32, _fp64]) {
    group('${_tfNames[f]} TestFloat', () {
      late _Bench bench;
      setUpAll(() async {
        bench = await _Bench.create(
          HarborFpuConfig(
            multiplier: mult,
            formats: [f],
            ops: harborFpFmaOps,
            stages: 0,
          ),
        );
      });

      for (var rm = 0; rm < 5; rm++) {
        for (final op in [HarborFpOp.add, HarborFpOp.sub, HarborFpOp.mul]) {
          test('${op.name} rm=${_rmNames[rm]}', () async {
            await _testFloat(bench, f, op, rm);
          }, skip: skip);
        }
        test('mulAdd rm=${_rmNames[rm]}, every 61st case', () async {
          await _testFloat(bench, f, HarborFpOp.madd, rm, stride: 61);
        }, skip: skip);
      }

      test('madd family against the model', () {
        final r = Random(f.width);
        final cases = <_Case>[];
        for (var i = 0; i < 40000; i++) {
          final op = _fmaOps[i % 4];
          final a = _value(r, f);
          final b = _value(r, f);
          final c = i % 3 == 0 ? _cancel(r, f, f, a, b) : _value(r, f);
          cases.add(_Case(op, r.nextInt(5), a, b, c));
        }
        final corners = _corners(f);
        for (final a in corners) {
          for (final b in corners) {
            for (final c in corners) {
              cases.add(_Case(_fmaOps[r.nextInt(4)], r.nextInt(5), a, b, c));
            }
          }
        }
        _check(bench, cases, [for (final k in cases) _model(bench.config, k)]);
      });
    });
  }

  for (final (narrow, wide) in [(_fp16, _fp32), (_fp32, _fp64)]) {
    final name =
        '${_tfNames[narrow]} x ${_tfNames[narrow]} + '
        '${_tfNames[wide]}';
    test('widening $name', () async {
      final config = HarborFpuConfig(
        multiplier: mult,
        formats: [narrow, wide],
        widening: [(narrow, wide)],
        ops: harborFpFmaOps,
        stages: 0,
      );
      final bench = await _Bench.create(config);
      final r = Random(narrow.width + wide.width);
      final cases = <_Case>[];
      _Case widen(HarborFpOp op, BigInt a, BigInt b, BigInt c) =>
          _Case(op, r.nextInt(5), a, b, c, fmt: r.nextInt(2), narrow: 1);
      for (var i = 0; i < 50000; i++) {
        final a = _value(r, narrow);
        final b = _value(r, narrow);
        final c = switch (i % 4) {
          0 => _cancel(r, narrow, wide, a, b),
          1 => fpToFp(narrow, wide, _value(r, narrow), 0).bits,
          _ => _value(r, wide),
        };
        cases.add(widen(_fmaOps[r.nextInt(4)], a, b, c));
      }
      final narrowCorners = _corners(narrow);
      final wideCorners = _corners(wide);
      for (final a in narrowCorners) {
        for (final b in narrowCorners) {
          for (final c in wideCorners) {
            cases.add(widen(_fmaOps[r.nextInt(4)], a, b, c));
          }
        }
      }
      _check(bench, cases, [for (final k in cases) _model(config, k)]);
    });
  }

  group('custom widening pairs', () {
    const wide40 = HarborFpFormat(11, 40);

    test('fp32 x fp32 + (11, 40) minimum subnormals', () async {
      final config = HarborFpuConfig(
        multiplier: mult,
        formats: [_fp32, wide40],
        widening: [(_fp32, wide40)],
        ops: {HarborFpOp.madd},
        stages: 0,
      );
      final bench = await _Bench.create(config);
      final c = BigInt.parse('8000000000001', radix: 16);
      final cases = [
        for (var rm = 0; rm < 5; rm++)
          _Case(HarborFpOp.madd, rm, BigInt.one, BigInt.one, c, narrow: 1),
      ];
      expect(
        _model(config, cases.first).bits,
        BigInt.parse('2d50000000000', radix: 16),
      );
      _check(bench, cases, [for (final k in cases) _model(config, k)]);
    });

    // The last pair has a narrow mantissa wider than the wide one.
    for (final (narrow, wide) in [
      (_fp16, const HarborFpFormat(8, 18)),
      (HarborFpFormat.bf16, const HarborFpFormat(8, 12)),
      (_fp32, wide40),
      (const HarborFpFormat(5, 20), const HarborFpFormat(11, 15)),
    ]) {
      test('$narrow to $wide with subnormal products', () async {
        final config = HarborFpuConfig(
          multiplier: mult,
          formats: [narrow, wide],
          widening: [(narrow, wide)],
          ops: harborFpFmaOps,
          stages: 0,
        );
        final bench = await _Bench.create(config);
        final r = Random(narrow.width * 100 + wide.width);
        BigInt sub() => _pack(
          narrow,
          r.nextInt(2),
          0,
          r.nextBool()
              ? BigInt.one << r.nextInt(narrow.mantissaWidth)
              : _bits(r, narrow.mantissaWidth) | BigInt.one,
        );
        BigInt tiny() => _pack(
          wide,
          r.nextInt(2),
          r.nextInt(3),
          _bits(r, wide.mantissaWidth),
        );
        final ops = [..._fmaOps, HarborFpOp.mul];
        final cases = <_Case>[];
        for (var i = 0; i < 8000; i++) {
          final a = r.nextInt(4) == 0 ? _value(r, narrow) : sub();
          final b = r.nextInt(4) == 0 ? _value(r, narrow) : sub();
          final c = switch (i % 3) {
            0 => tiny(),
            1 => _cancel(r, narrow, wide, a, b),
            _ => _value(r, wide),
          };
          cases.add(
            _Case(ops[r.nextInt(5)], i % 5, a, b, c, fmt: 1, narrow: 1),
          );
        }
        for (final a in _corners(narrow)) {
          for (final b in _corners(narrow)) {
            for (final c in _corners(wide)) {
              cases.add(
                _Case(_fmaOps[r.nextInt(4)], r.nextInt(5), a, b, c, narrow: 1),
              );
            }
          }
        }
        _check(bench, cases, [for (final k in cases) _model(config, k)]);
      });
    }
  });

  group('fmt_narrow', () {
    final config = HarborFpuConfig(
      multiplier: mult,
      formats: [_fp16, _fp32, _fp64],
      widening: [(_fp16, _fp32), (_fp32, _fp64)],
      ops: harborFpFmaOps,
      stages: 0,
    );
    late _Bench bench;
    setUpAll(() async {
      bench = await _Bench.create(config);
    });

    test('widening mul rounds the exact product to the wide format', () {
      final r = Random(19);
      final cases = <_Case>[];
      for (var i = 0; i < 20000; i++) {
        final narrow = 1 + r.nextInt(2);
        final f = config.widening[narrow - 1].$1;
        cases.add(
          _Case(
            HarborFpOp.mul,
            r.nextInt(5),
            _value(r, f),
            _value(r, f),
            _bits(r, 64),
            fmt: r.nextInt(3),
            narrow: narrow,
          ),
        );
      }
      for (var narrow = 1; narrow <= 2; narrow++) {
        final corners = _corners(config.widening[narrow - 1].$1);
        for (final a in corners) {
          for (final b in corners) {
            cases.add(
              _Case(
                HarborFpOp.mul,
                r.nextInt(5),
                a,
                b,
                BigInt.zero,
                narrow: narrow,
              ),
            );
          }
        }
      }
      _check(bench, cases, [
        for (final k in cases)
          _wideMul(
            config.widening[k.narrow - 1].$1,
            config.widening[k.narrow - 1].$2,
            k.a,
            k.b,
            k.rm,
            false,
          ),
      ]);
    });

    test('add and sub ignore it', () {
      final r = Random(23);
      final plain = <_Case>[];
      for (var i = 0; i < 20000; i++) {
        final fmt = r.nextInt(3);
        final f = config.formats[fmt];
        plain.add(
          _Case(
            r.nextBool() ? HarborFpOp.add : HarborFpOp.sub,
            r.nextInt(5),
            _value(r, f),
            _value(r, f),
            _bits(r, 64),
            fmt: fmt,
          ),
        );
      }
      final narrowed = [
        for (final k in plain)
          _Case(
            k.op,
            k.rm,
            k.a,
            k.b,
            k.c,
            fmt: k.fmt,
            narrow: 1 + r.nextInt(2),
          ),
      ];
      final want = [
        for (final k in plain)
          k.op == HarborFpOp.add
              ? fpAdd(config.formats[k.fmt], k.a, k.b, k.rm)
              : fpSub(config.formats[k.fmt], k.a, k.b, k.rm),
      ];
      _check(bench, plain, want);
      _check(bench, narrowed, want);
    });
  });

  test('fp16 + fp32 + fp64 selects the format at run time', () async {
    final config = HarborFpuConfig(
      multiplier: mult,
      formats: [_fp16, _fp32, _fp64],
      widening: [(_fp16, _fp32), (_fp32, _fp64)],
      ops: harborFpFmaOps,
      stages: 0,
    );
    final bench = await _Bench.create(config);
    final r = Random(7);
    final cases = <_Case>[];
    for (var i = 0; i < 30000; i++) {
      final op = HarborFpOp.values[r.nextInt(7)];
      // add and sub must ignore fmt_narrow.
      final narrow = r.nextInt(3) == 0 ? 1 + r.nextInt(2) : 0;
      final fmt = r.nextInt(3);
      final HarborFpFormat fa;
      final HarborFpFormat fc;
      if (narrow != 0 && _widens(op)) {
        (fa, fc) = config.widening[narrow - 1];
      } else {
        fa = config.formats[fmt];
        fc = fa;
      }
      // Bits above the selected format are noise the path must ignore.
      BigInt noisy(BigInt v, HarborFpFormat f) =>
          v | (_bits(r, 64) >> f.width << f.width);
      final a = _value(r, fa);
      final b = _value(
        r,
        op == HarborFpOp.add || op == HarborFpOp.sub ? fc : fa,
      );
      final c = i % 3 == 0 && fa == fc
          ? _cancel(r, fa, fc, a, b)
          : _value(r, fc);
      cases.add(
        _Case(
          op,
          r.nextInt(5),
          noisy(a, fa),
          noisy(b, fa),
          noisy(c, fc),
          fmt: fmt,
          narrow: narrow,
        ),
      );
    }
    final want = [
      for (final k in cases)
        _model(
          config,
          _Case(
            k.op,
            k.rm,
            k.a & _mask(k, config, 0),
            k.b & _mask(k, config, 0),
            k.c & _mask(k, config, 1),
            fmt: k.fmt,
            narrow: k.narrow,
          ),
        ),
    ];
    _check(bench, cases, want);
  });

  test('ftz flushes fp32 inputs and outputs', () async {
    final config = HarborFpuConfig(
      multiplier: mult,
      formats: [_fp32],
      ops: harborFpFmaOps,
      stages: 0,
      ftz: true,
    );
    final bench = await _Bench.create(config);
    final r = Random(11);
    final cases = <_Case>[];
    for (var i = 0; i < 30000; i++) {
      final op = HarborFpOp.values[r.nextInt(7)];
      // Exponents near the bottom give subnormal and tiny results.
      BigInt low() => r.nextBool()
          ? _value(r, _fp32)
          : _pack(_fp32, r.nextInt(2), r.nextInt(80), _bits(r, 23));
      final a = low();
      final b = i % 2 == 0
          ? _pack(_fp32, 0, 127 - r.nextInt(40), _bits(r, 23))
          : low();
      cases.add(_Case(op, r.nextInt(5), a, b, low()));
    }
    _check(bench, cases, [for (final k in cases) _model(config, k)]);
  });

  test('the product rows sum to the product', () async {
    final config = HarborFpuConfig(
      multiplier: mult,
      formats: [_fp64],
      ops: {HarborFpOp.mul},
      stages: 0,
    );
    final bench = await _Bench.create(config);
    // The tree cut drops the low zero bits of each row, so read the full
    // rows. The DSP rows are 2p bits and sum to the product exactly.
    final tree = mult == HarborFpMultiplier.compressionTree;
    final rows = bench.path.internalSignals
        .where((s) => s.name.startsWith(tree ? 'pp_full_row' : 'dsp_row'))
        .toList();
    expect(rows, hasLength(tree ? 4 : 5));
    final sim = LaneSim(bench.path, [
      bench.path.op,
      bench.path.rm,
      bench.path.fmt,
      bench.path.fmtNarrow,
      bench.path.a,
      bench.path.b,
      bench.path.c,
    ], rows);
    final r = Random(5);
    final p = bench.path.significandWidth;
    final mod = BigInt.one << (tree ? 2 * p + 1 : 4 * p);
    for (var round = 0; round < 20; round++) {
      final a = [for (var j = 0; j < 64; j++) _bits(r, 64)];
      final b = [for (var j = 0; j < 64; j++) _bits(r, 64)];
      sim
        ..set(bench.path.op, List.filled(64, BigInt.from(HarborFpOp.mul.index)))
        ..set(bench.path.a, a)
        ..set(bench.path.b, b)
        ..run();
      final got = [for (final row in rows) sim.get(row, 64)];
      for (var j = 0; j < 64; j++) {
        BigInt sig(BigInt v) {
          final exp = (v >> 52) & BigInt.from(0x7ff);
          final mant = v & ((BigInt.one << 52) - BigInt.one);
          return exp == BigInt.zero ? mant : mant | (BigInt.one << 52);
        }

        final sum = got.fold(BigInt.zero, (s, g) => s + g[j]) % mod;
        expect(sum, sig(a[j]) * sig(b[j]), reason: 'a=${a[j]} b=${b[j]}');
      }
    }
  });

  group('lane sim', () {
    final configs = {
      'fp16': HarborFpuConfig(
        multiplier: mult,
        formats: [_fp16],
        ops: harborFpFmaOps,
        stages: 0,
      ),
      'fp16 + fp32 widening': HarborFpuConfig(
        multiplier: mult,
        formats: [_fp16, _fp32],
        widening: [(_fp16, _fp32)],
        ops: harborFpFmaOps,
        stages: 0,
      ),
      'fp64': HarborFpuConfig(
        multiplier: mult,
        formats: [_fp64],
        ops: harborFpFmaOps,
        stages: 0,
      ),
    };
    for (final MapEntry(key: name, value: config) in configs.entries) {
      test('matches the ROHD simulator on $name', () async {
        final cases = _mixed(config, Random(13), 320);
        final bench = await _Bench.create(config);
        final lanes = bench.run(cases);
        final rohd = await _rohdComb(config, cases);
        for (var i = 0; i < cases.length; i++) {
          expect(rohd[i].bits, lanes[i].bits, reason: '${cases[i]}');
          expect(rohd[i].flags, lanes[i].flags, reason: '${cases[i]}');
        }
        _check(bench, cases, [for (final k in cases) _model(config, k)]);
      });
    }

    test('throws on a constant with X or Z bits', () async {
      final a = Logic(width: 2);
      final m = _XConst(a);
      await m.build();
      expect(
        () => LaneSim(m, [m.input('a')], [m.output('y')]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('X or Z'),
          ),
        ),
      );
    });

    test('throws on a combinational loop', () async {
      final a = Logic();
      final m = _Loop(a);
      await m.build();
      expect(
        () => LaneSim(m, [m.input('a')], [m.output('y')]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('loop'),
          ),
        ),
      );
    });
  });

  for (final stages in [2, 4, 6]) {
    test('registers at the cuts of $stages stages hold in a stall', () async {
      final config = HarborFpuConfig(
        multiplier: mult,
        formats: [_fp16, _fp32],
        widening: [(_fp16, _fp32)],
        ops: harborFpFmaOps,
        stages: stages,
      );
      final r = Random(stages);
      final cases = _mixed(config, r, 320);
      final junk = _mixed(config, r, 64);
      // Independent pipelines, each with its own share of the cases.
      const parts = 16;
      final chunk = cases.length ~/ parts;
      final runs = await Future.wait([
        for (var j = 0; j < parts; j++)
          _rohdStall(
            config,
            cases.sublist(j * chunk, (j + 1) * chunk),
            junk,
            stages * 100 + j,
          ),
      ]);
      var stalls = 0;
      for (var j = 0; j < parts; j++) {
        final seen = runs[j];
        stalls += seen.length - chunk;
        expect(
          [for (final (i, _) in seen) i].toSet(),
          hasLength(chunk),
          reason: 'every case comes out',
        );
        for (final (i, got) in seen) {
          final k = cases[j * chunk + i];
          final want = _model(config, k);
          expect(got.bits, want.bits, reason: '$k');
          expect(got.flags, want.flags, reason: '$k');
        }
      }
      expect(stalls, greaterThan(50));
    });
  }

  group('product width', () {
    test('the Glacier lane config builds the fp16 product only', () async {
      final config = HarborFpuConfig(
        multiplier: mult,
        formats: [_fp16, _fp32],
        widening: [(_fp16, _fp32)],
        ops: {HarborFpOp.madd, HarborFpOp.intToFp, HarborFpOp.fpToInt},
        stages: 0,
        intWidths: [32],
        mulFormats: const {},
      );
      final bench = await _Bench.create(config);
      final path = bench.path;
      expect(path.significandWidth, 24);
      expect(path.productWidth, 11);
      int width(HarborFpCut k, String name) =>
          path.cuts[k]!.singleWhere((s) => s.name == '${k.name}_$name').width;
      expect(width(HarborFpCut.c1, 'sig_a'), 11);
      expect(width(HarborFpCut.c1, 'sig_b'), 11);
      final rows = path.cuts[HarborFpCut.c2]!.where(
        (s) => s.name.startsWith('c2_pp_'),
      );
      if (mult == HarborFpMultiplier.dsp) {
        expect([for (final s in rows) s.width], [22]);
      } else {
        expect(rows, isNotEmpty);
        for (final s in rows) {
          expect(s.width, lessThanOrEqualTo(23));
        }
      }

      final r = Random(29);
      final cases = <_Case>[];
      for (var i = 0; i < 20000; i++) {
        final a = _value(r, _fp16);
        final b = _value(r, _fp16);
        final c = i % 4 == 0
            ? _cancel(r, _fp16, _fp32, a, b)
            : _value(r, _fp32);
        cases.add(_Case(HarborFpOp.madd, i % 5, a, b, c, fmt: 1, narrow: 1));
      }
      // A plain fp16 madd fits pm and is exact; a plain fp32 madd does not
      // and gives the canonical NaN with NV.
      for (var i = 0; i < 2000; i++) {
        final fmt = i % 2;
        final f = config.formats[fmt];
        cases.add(
          _Case(
            HarborFpOp.madd,
            i % 5,
            _value(r, f),
            _value(r, f),
            _value(r, f),
            fmt: fmt,
          ),
        );
      }
      _check(bench, cases, [for (final k in cases) _model(config, k)]);
    });

    test('add and sub keep all of a with a narrow product', () async {
      final config = HarborFpuConfig(
        multiplier: mult,
        formats: [_fp16, _fp32],
        widening: [(_fp16, _fp32)],
        ops: harborFpFmaOps,
        stages: 0,
        mulFormats: {_fp16},
      );
      final bench = await _Bench.create(config);
      expect(bench.path.productWidth, 11);
      final cases = _mixed(config, Random(31), 30000);
      _check(bench, cases, [for (final k in cases) _model(config, k)]);
    });

    test('registers hold in a stall with a narrow product', () async {
      final config = HarborFpuConfig(
        multiplier: mult,
        formats: [_fp16, _fp32],
        widening: [(_fp16, _fp32)],
        ops: harborFpFmaOps,
        stages: 6,
        mulFormats: {_fp16},
      );
      final r = Random(37);
      final cases = _mixed(config, r, 64);
      final runs = await Future.wait([
        for (var j = 0; j < 4; j++)
          _rohdStall(
            config,
            cases.sublist(j * 16, (j + 1) * 16),
            _mixed(config, r, 16),
            j,
          ),
      ]);
      for (var j = 0; j < 4; j++) {
        for (final (i, got) in runs[j]) {
          final k = cases[j * 16 + i];
          final want = _model(config, k);
          expect(got.bits, want.bits, reason: '$k');
          expect(got.flags, want.flags, reason: '$k');
        }
      }
    });
  });

  test('bits that cross each cut', () async {
    // C2 holds the tree rows, or one product per pair of DSP slices.
    final want = mult == HarborFpMultiplier.compressionTree
        ? {
            _fp32: [97, 202, 183, 108, 62, 53, 37],
            _fp64: [188, 411, 362, 200, 110, 88, 69],
          }
        : {
            _fp32: [97, 145, 183, 108, 62, 53, 37],
            _fp64: [188, 400, 362, 200, 110, 88, 69],
          };
    for (final f in [_fp32, _fp64]) {
      final bench = await _Bench.create(
        HarborFpuConfig(
          multiplier: mult,
          formats: [f],
          ops: harborFpFmaOps,
          stages: 0,
        ),
      );
      final bits = _cutBits(bench.path);
      expect(
        [for (final k in HarborFpCut.values) bits[k]],
        want[f],
        reason: _tfNames[f],
      );
    }
  });

  test('cut groups and op subsets', () async {
    final config = HarborFpuConfig(
      multiplier: mult,
      formats: [_fp16, _fp32],
      widening: [(_fp16, _fp32)],
      ops: {HarborFpOp.madd, HarborFpOp.div},
      stages: 0,
    );
    final bench = await _Bench.create(config);
    for (final k in HarborFpCut.values) {
      expect(bench.path.cuts[k], isNotEmpty, reason: '$k');
    }
    final r = Random(17);
    final cases = [
      for (var i = 0; i < 2000; i++)
        _Case(
          HarborFpOp.madd,
          r.nextInt(5),
          _value(r, _fp16),
          _value(r, _fp16),
          _value(r, _fp32),
          fmt: 1,
          narrow: 1,
        ),
    ];
    _check(bench, cases, [for (final k in cases) _model(config, k)]);
    expect(
      () => HarborFpFmaPath(
        HarborFpuConfig(
          multiplier: mult,
          formats: [_fp32],
          ops: {HarborFpOp.div},
          stages: 0,
        ),
        op: Logic(width: harborFpOpWidth),
        fmt: Logic(),
        fmtNarrow: Logic(),
        rm: Logic(width: 3),
        a: Logic(width: 32),
        b: Logic(width: 32),
        c: Logic(width: 32),
      ),
      throwsArgumentError,
    );
  });
}

/// The bits of operand [which] (0 for a and b, 1 for c) that the selected
/// format uses.
BigInt _mask(_Case k, HarborFpuConfig config, int which) {
  final HarborFpFormat f;
  if (k.narrow != 0 && _widens(k.op)) {
    final pair = config.widening[k.narrow - 1];
    f = which == 0 ? pair.$1 : pair.$2;
  } else {
    f = config.formats[k.fmt];
  }
  return (BigInt.one << f.width) - BigInt.one;
}
