import 'dart:async';
import 'dart:isolate';
import 'dart:math';

import 'package:harbor/src/arith/fp_format.dart';
import 'package:harbor/src/arith/fpu_config.dart';
import 'package:harbor/src/arith/recurrence.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'fp_model.dart';
import 'lane_sim.dart';
import 'testfloat_vectors.dart';

const _fp16 = HarborFpFormat.fp16;
const _fp32 = HarborFpFormat.fp32;
const _fp64 = HarborFpFormat.fp64;
const _all = [_fp16, _fp32, _fp64];

final _tfNames = {_fp16: 'f16', _fp32: 'f32', _fp64: 'f64'};
const _rmNames = ['near_even', 'minMag', 'min', 'max', 'near_maxMag'];

const _iterative = HarborFpDivMode.iterative;
const _pipelined = HarborFpDivMode.pipelined;

const _fpDiv = HarborDivSqrtOp.fpDiv;
const _fpSqrt = HarborDivSqrtOp.fpSqrt;
const _divU = HarborDivSqrtOp.divUnsigned;
const _divS = HarborDivSqrtOp.divSigned;

const _tagWidth = 16;

String? get _skip => testFloatAvailable()
    ? null
    : 'testfloat_gen not found; set HARBOR_TESTFLOAT_GEN or run inside '
          '`nix develop`';

/// What to build.
class _Spec {
  final List<HarborFpFormat> formats;
  final Set<HarborFpOp> fpOps;
  final bool ftz;
  final int intWidth;
  final int narrowWidth;
  final HarborFpDivMode mode;
  final int radix;
  final int stages;

  const _Spec({
    this.formats = const [],
    this.fpOps = const {HarborFpOp.div, HarborFpOp.sqrt},
    this.ftz = false,
    this.intWidth = 0,
    this.narrowWidth = 0,
    this.mode = _pipelined,
    this.radix = 2,
    this.stages = 0,
  });

  HarborFpuConfig? get config => formats.isEmpty
      ? null
      : HarborFpuConfig(
          formats: formats,
          ops: fpOps,
          stages: 0,
          ftz: ftz,
          divMode: mode,
          divRadix: radix,
          divStages: stages,
        );

  int get width => max(
    formats.isEmpty ? 0 : formats.map((f) => f.width).reduce(max),
    intWidth,
  );

  @override
  String toString() =>
      '${mode.name} radix $radix stages $stages '
      '${formats.map((f) => _tfNames[f]).join('+')}'
      '${intWidth > 0 ? ' int$intWidth' : ''}'
      '${narrowWidth > 0 ? ' narrow$narrowWidth' : ''}${ftz ? ' ftz' : ''}';
}

class _Op {
  final HarborDivSqrtOp op;
  final int fmt;
  final int rm;
  final BigInt a;
  final BigInt b;
  final bool narrow;

  const _Op(
    this.op,
    this.a,
    this.b, {
    this.fmt = 0,
    this.rm = 0,
    this.narrow = false,
  });

  bool get isInt => op == _divU || op == _divS;

  @override
  String toString() =>
      '${op.name}${narrow ? ' narrow' : ''} fmt=$fmt rm=$rm '
      'a=${a.toRadixString(16)} b=${b.toRadixString(16)}';
}

class _Out {
  final BigInt result;
  final int flags;
  final BigInt remainder;

  const _Out(this.result, this.flags, this.remainder);

  @override
  bool operator ==(Object other) =>
      other is _Out &&
      other.result == result &&
      other.flags == flags &&
      other.remainder == remainder;

  @override
  int get hashCode => Object.hash(result, flags, remainder);

  @override
  String toString() =>
      '(${result.toRadixString(16)}, flags ${flags.toRadixString(16)}, '
      'rem ${remainder.toRadixString(16)})';
}

BigInt _mask(int w) => (BigInt.one << w) - BigInt.one;

BigInt _signed(BigInt v, int w) =>
    v >= BigInt.one << (w - 1) ? v - (BigInt.one << w) : v;

/// The expected output. Integer ops have zero flags, and floating point ops
/// do not check the remainder. A narrow op sign extends its results.
_Out _model(_Spec spec, _Op o) {
  if (o.isInt) {
    final w = o.narrow ? spec.narrowWidth : spec.intWidth;
    final m = _mask(w);
    BigInt ext(BigInt v) => o.narrow ? _signed(v, w) & _mask(spec.intWidth) : v;
    final ua = o.a & m;
    final ub = o.b & m;
    if (ub == BigInt.zero) {
      return _Out(ext(m), 0, ext(ua));
    }
    final signed = o.op == _divS;
    final a = signed ? _signed(ua, w) : ua;
    final b = signed ? _signed(ub, w) : ub;
    return _Out(ext((a ~/ b) & m), 0, ext(a.remainder(b) & m));
  }
  final f = spec.formats[o.fmt];
  final r = o.op == _fpDiv
      ? fpDiv(f, o.a, o.b, o.rm, ftz: spec.ftz)
      : fpSqrt(f, o.a, o.rm, ftz: spec.ftz);
  return _Out(r.bits, r.flags, BigInt.zero);
}

/// The module with free inputs.
class _Rig {
  final _Spec spec;
  final Logic clk;
  final Logic reset = Logic(name: 'reset');
  late final Logic? killMask;
  final Logic inValid = Logic(name: 'in_valid');
  final Logic inOp = Logic(name: 'in_op', width: 2);
  late final Logic inFmt;
  final Logic inRm = Logic(name: 'in_rm', width: 3);
  late final Logic inA;
  late final Logic inB;
  final Logic inTag = Logic(name: 'in_tag', width: _tagWidth);
  final Logic inNarrow = Logic(name: 'in_narrow');
  final Logic outReady = Logic(name: 'out_ready');
  late final HarborDivSqrtRecurrence dut;

  _Rig(this.spec, {Logic? clk}) : clk = clk ?? Logic(name: 'clk') {
    final w = spec.width;
    final slots = HarborDivSqrtRecurrence.slotCountOf(spec.mode, spec.stages);
    killMask = slots > 0 ? Logic(name: 'kill_mask', width: slots) : null;
    inA = Logic(name: 'in_a', width: w);
    inB = Logic(name: 'in_b', width: w);
    final config = spec.config;
    if (config == null) {
      inFmt = Logic(name: 'in_fmt');
      dut = HarborDivSqrtRecurrence.integer(
        spec.intWidth,
        spec.mode,
        spec.radix,
        spec.stages,
        clk: this.clk,
        reset: reset,
        killMask: killMask,
        inValid: inValid,
        inOp: inOp,
        inA: inA,
        inB: inB,
        inNarrow: spec.narrowWidth > 0 ? inNarrow : null,
        inTag: inTag,
        outReady: outReady,
        narrowWidth: spec.narrowWidth,
      );
    } else {
      inFmt = Logic(
        name: 'in_fmt',
        width: max(1, (config.formats.length - 1).bitLength),
      );
      dut = HarborDivSqrtRecurrence(
        config,
        clk: this.clk,
        reset: reset,
        killMask: killMask,
        inValid: inValid,
        inOp: inOp,
        inFmt: inFmt,
        inRm: inRm,
        inA: inA,
        inB: inB,
        inNarrow: spec.narrowWidth > 0 ? inNarrow : null,
        inTag: inTag,
        outReady: outReady,
        intWidth: spec.intWidth,
        narrowWidth: spec.narrowWidth,
      );
    }
  }

  bool get hasFp => spec.config != null;
  bool get hasInt => spec.intWidth > 0;
  bool get hasNarrow => spec.narrowWidth > 0;

  void put(_Op o, int tag) {
    inOp.put(o.op.index);
    inFmt.put(o.fmt);
    inRm.put(o.rm);
    inA.put(LogicValue.ofBigInt(o.a, inA.width));
    inB.put(LogicValue.ofBigInt(o.b, inB.width));
    inTag.put(tag);
    inNarrow.put(o.narrow ? 1 : 0);
  }

  _Out read(_Op o) => _Out(
    dut.outResult.value.toBigInt(),
    hasFp ? dut.outFlags.value.toInt() : 0,
    o.isInt ? dut.outRemainder.value.toBigInt() : BigInt.zero,
  );
}

/// Runs [ops] through a zero stage pipelined build, 64 cases at a time.
class _Lanes {
  final _Spec spec;
  late final _Rig rig;
  late final LaneSim sim;

  _Lanes._(this.spec);

  static Future<_Lanes> create(_Spec spec) async {
    final l = _Lanes._(spec);
    l.rig = _Rig(spec);
    final d = l.rig.dut;
    await d.build();
    l.sim = LaneSim(
      d,
      [
        d.input('in_op'),
        if (l.rig.hasFp) ...[d.input('in_fmt'), d.input('in_rm')],
        d.input('in_a'),
        d.input('in_b'),
        if (l.rig.hasNarrow) d.input('in_narrow'),
      ],
      [
        d.outResult,
        if (l.rig.hasFp) d.outFlags,
        if (l.rig.hasInt) d.outRemainder,
      ],
    );
    return l;
  }

  List<_Out> run(List<_Op> ops) {
    final d = rig.dut;
    final out = <_Out>[];
    for (var i = 0; i < ops.length; i += LaneSim.lanes) {
      final part = ops.sublist(i, min(i + LaneSim.lanes, ops.length));
      sim.set(d.input('in_op'), [
        for (final o in part) BigInt.from(o.op.index),
      ]);
      if (rig.hasFp) {
        sim
          ..set(d.input('in_fmt'), [for (final o in part) BigInt.from(o.fmt)])
          ..set(d.input('in_rm'), [for (final o in part) BigInt.from(o.rm)]);
      }
      if (rig.hasNarrow) {
        sim.set(d.input('in_narrow'), [
          for (final o in part) o.narrow ? BigInt.one : BigInt.zero,
        ]);
      }
      sim
        ..set(d.input('in_a'), [for (final o in part) o.a])
        ..set(d.input('in_b'), [for (final o in part) o.b])
        ..run();
      final res = sim.get(d.outResult, part.length);
      final flags = rig.hasFp ? sim.get(d.outFlags, part.length) : null;
      final rem = rig.hasInt ? sim.get(d.outRemainder, part.length) : null;
      for (var j = 0; j < part.length; j++) {
        out.add(
          _Out(
            res[j],
            flags?[j].toInt() ?? 0,
            part[j].isInt ? rem![j] : BigInt.zero,
          ),
        );
      }
    }
    return out;
  }
}

/// Lists the first mismatches of [got] against the model.
void _check(_Spec spec, List<_Op> ops, List<_Out> got, {List<int>? tags}) {
  final bad = <String>[];
  var count = 0;
  for (var i = 0; i < got.length; i++) {
    final o = ops[tags == null ? i : tags[i]];
    final want = _model(spec, o);
    if (got[i] != want) {
      count++;
      if (bad.length < 8) {
        bad.add('$o: got ${got[i]}, want $want');
      }
    }
  }
  expect(count, 0, reason: '$count of ${got.length} wrong:\n${bad.join('\n')}');
}

/// The trace of one clocked run.
class _Trace {
  /// `(tag, output)` in the order taken.
  final List<(int, _Out)> taken;

  /// The accept cycle of each tag, and the cycle of each take.
  final Map<int, int> acceptCycles;
  final List<int> takeCycles;

  /// Rule breaks seen on the way.
  final List<String> errors;
  final int cycles;

  const _Trace(
    this.taken,
    this.acceptCycles,
    this.takeCycles,
    this.errors,
    this.cycles,
  );
}

/// Runs [ops] in order through a clocked build in the ROHD simulator.
///
/// `in_valid` is low on a [gap] share of cycles and `out_ready` is low on a
/// [stall] share. Every kill mask bit is high on the cycles in [kills]. An
/// op on the input in a kill cycle is accepted as usual, and no result may
/// come out in a kill cycle. With [serial], an op goes in only when no
/// other op is in flight.
Future<_Trace> _clocked(
  _Spec spec,
  List<_Op> ops, {
  int seed = 1,
  double gap = 0.2,
  double stall = 0.3,
  Set<int> kills = const {},
  bool serial = false,
}) => Isolate.run(() async {
  final clk = SimpleClockGenerator(10).clk;
  final rig = _Rig(spec, clk: clk);
  final dut = rig.dut;
  await dut.build();
  final r = Random(seed);
  final taken = <(int, _Out)>[];
  final accepts = <int, int>{};
  final takes = <int>[];
  final errors = <String>[];
  final inFlight = <int>[];

  rig.reset.put(1);
  rig.killMask?.put(0);
  rig.inValid.put(0);
  rig.outReady.put(0);
  rig.put(ops.first, 0);
  unawaited(Simulator.run());
  await clk.nextNegedge;
  await clk.nextNegedge;
  rig.reset.put(0);

  var next = 0;
  var cycle = 0;
  var acceptedLast = false;
  final limit = 200 + ops.length * (dut.latency + 4) * 4;
  while ((next < ops.length || inFlight.isNotEmpty) && cycle < limit) {
    await clk.nextNegedge;
    cycle++;
    final kill = kills.contains(cycle);
    final valid =
        next < ops.length &&
        r.nextDouble() >= gap &&
        (!serial || inFlight.isEmpty);
    final ready = r.nextDouble() >= stall;
    final km = rig.killMask;
    km?.put(kill ? (BigInt.one << km.width) - BigInt.one : BigInt.zero);
    rig.inValid.put(valid ? 1 : 0);
    rig.outReady.put(ready ? 1 : 0);
    if (next < ops.length) {
      rig.put(ops[next], next);
    }
    final inReady = dut.inReady.value.toBool();
    final outValid = dut.outValid.value.toBool();
    if (spec.mode == _pipelined && ready && !inReady) {
      errors.add('cycle $cycle: in_ready low with out_ready high');
    }
    if (spec.mode == _iterative) {
      // The input register holds an accepted op for one cycle or more.
      if (inReady && acceptedLast) {
        errors.add('cycle $cycle: in_ready high after an accept');
      }
      if (inFlight.length > 4) {
        errors.add('cycle $cycle: ${inFlight.length} ops in flight');
      }
    }
    acceptedLast = valid && inReady;
    if (kill && rig.killMask != null) {
      inFlight.clear();
      if (outValid) {
        errors.add('cycle $cycle: out_valid high in a kill cycle');
      }
    }
    if (outValid && ready) {
      final tag = dut.outTag.value.toInt();
      if (inFlight.isEmpty || inFlight.first != tag) {
        errors.add('cycle $cycle: tag $tag out of order');
      } else {
        inFlight.removeAt(0);
      }
      taken.add((tag, rig.read(ops[tag])));
      takes.add(cycle);
    }
    if (valid && inReady) {
      inFlight.add(next);
      accepts[next] = cycle;
      next++;
    }
  }
  if (cycle >= limit) {
    errors.add('timed out with ${inFlight.length} ops in flight');
  }
  await Simulator.endSimulation();
  return _Trace(taken, accepts, takes, errors, cycle);
});

/// Checks a clocked run where nothing is killed: every op comes back once,
/// in order, with its own tag and the model result.
void _checkAll(_Spec spec, List<_Op> ops, _Trace t) {
  expect(t.errors, isEmpty);
  expect(
    [for (final (tag, _) in t.taken) tag],
    [for (var i = 0; i < ops.length; i++) i],
  );
  _check(
    spec,
    ops,
    [for (final (_, o) in t.taken) o],
    tags: [for (final (tag, _) in t.taken) tag],
  );
}

BigInt _bits(Random r, int width) {
  var v = BigInt.zero;
  for (var i = 0; i < width; i += 16) {
    v |= BigInt.from(r.nextInt(1 << 16)) << i;
  }
  return v & _mask(width);
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
    mant = r.nextBool()
        ? (BigInt.one << m) - (BigInt.one << r.nextInt(m))
        : BigInt.one << r.nextInt(m);
  }
  return switch (r.nextInt(12)) {
    0 => _pack(f, sign, 0, BigInt.zero),
    1 || 2 => _pack(f, sign, 0, mant == BigInt.zero ? BigInt.one : mant),
    3 => _pack(f, sign, top, BigInt.zero),
    4 => _pack(f, sign, top, mant == BigInt.zero ? BigInt.one : mant),
    5 => _pack(f, sign, 1 + r.nextInt(3), mant),
    6 => _pack(f, sign, top - 1 - r.nextInt(3), mant),
    _ => _pack(f, sign, 1 + r.nextInt(top - 1), mant),
  };
}

/// Random floating point ops over every format of [spec], with a positive
/// operand for most square roots.
List<_Op> _randomFp(_Spec spec, Random r, int n) => [
  for (var i = 0; i < n; i++)
    () {
      final fmt = r.nextInt(spec.formats.length);
      final f = spec.formats[fmt];
      final sqrt =
          spec.fpOps.contains(HarborFpOp.sqrt) &&
          (!spec.fpOps.contains(HarborFpOp.div) || r.nextBool());
      var a = _value(r, f);
      if (sqrt && r.nextInt(4) != 0) {
        a &= _mask(f.width - 1);
      }
      return _Op(
        sqrt ? _fpSqrt : _fpDiv,
        a,
        _value(r, f),
        fmt: fmt,
        rm: r.nextInt(5),
      );
    }(),
];

List<BigInt> _intCorners(int w) {
  final m = _mask(w);
  final min = BigInt.one << (w - 1);
  return [
    BigInt.zero,
    BigInt.one,
    BigInt.two,
    m,
    m - BigInt.one,
    min,
    min - BigInt.one,
    min + BigInt.one,
    BigInt.from(7),
    m - BigInt.from(6),
  ];
}

/// Every corner pair, then random pairs with a mix of operand sizes.
List<_Op> _intOps(int w, Random r, int n) {
  final corners = _intCorners(w);
  BigInt pick() => switch (r.nextInt(5)) {
    0 => corners[r.nextInt(corners.length)],
    1 => _bits(r, 1 + r.nextInt(8)),
    2 => _mask(w) - _bits(r, 1 + r.nextInt(8)),
    _ => _bits(r, 1 + r.nextInt(w)) ^ (r.nextBool() ? _mask(w) : BigInt.zero),
  };
  return [
    for (final a in corners)
      for (final b in corners) ...[_Op(_divU, a, b), _Op(_divS, a, b)],
    for (var i = 0; i < n; i++)
      _Op(r.nextBool() ? _divS : _divU, pick(), pick()),
  ];
}

/// Narrow ops of [nw] bits with random bits above the narrow operands.
List<_Op> _narrowOps(int w, int nw, Random r, int n) => [
  for (final o in _intOps(nw, r, n))
    _Op(
      o.op,
      o.a | (_bits(r, w - nw) << nw),
      o.b | (_bits(r, w - nw) << nw),
      narrow: true,
    ),
];

/// Every TestFloat level 1 case of [f] and [op] in [rm], every [stride]th.
Future<List<_Op>> _testFloat(
  _Spec spec,
  HarborFpFormat f,
  HarborDivSqrtOp op,
  int rm, {
  int stride = 1,
}) async {
  final name = '${_tfNames[f]}_${op == _fpDiv ? 'div' : 'sqrt'}';
  final vectors = await testFloatCases(
    name,
    rm: _rmNames[rm],
    stride: stride,
  ).toList();
  final fmt = spec.formats.indexOf(f);
  return [
    for (final v in vectors)
      _Op(
        op,
        v.operands[0],
        v.operands.length > 1 ? v.operands[1] : BigInt.zero,
        fmt: fmt,
        rm: rm,
      ),
  ];
}

/// TestFloat cases checked against TestFloat itself, so the model is not
/// trusted here.
Future<void> _testFloatLanes(
  _Lanes lanes,
  HarborFpFormat f,
  HarborDivSqrtOp op,
  int rm, {
  int level = 1,
  int stride = 1,
}) async {
  final name = '${_tfNames[f]}_${op == _fpDiv ? 'div' : 'sqrt'}';
  final vectors = await testFloatCases(
    name,
    rm: _rmNames[rm],
    level: level,
    stride: stride,
  ).toList();
  expect(vectors, isNotEmpty);
  final fmt = lanes.spec.formats.indexOf(f);
  final ops = [
    for (final v in vectors)
      _Op(
        op,
        v.operands[0],
        v.operands.length > 1 ? v.operands[1] : BigInt.zero,
        fmt: fmt,
        rm: rm,
      ),
  ];
  final got = lanes.run(ops);
  final bad = <String>[];
  var count = 0;
  for (var i = 0; i < ops.length; i++) {
    final v = vectors[i];
    if (got[i].result != v.result || got[i].flags != v.flags) {
      count++;
      if (bad.length < 8) {
        bad.add('${ops[i]}: got ${got[i]}, want $v');
      }
    }
  }
  expect(count, 0, reason: '$count of ${ops.length} wrong:\n${bad.join('\n')}');
}

/// A TestFloat sample over every format, op and rm of [spec], in a mixed
/// order.
Future<List<_Op>> _sample(_Spec spec, {int perCase = 24, int seed = 3}) async {
  final ops = <_Op>[];
  for (final f in spec.formats) {
    for (final op in [_fpDiv, _fpSqrt]) {
      for (var rm = 0; rm < 5; rm++) {
        final all = await _testFloat(spec, f, op, rm);
        final stride = max(1, all.length ~/ perCase);
        ops.addAll([for (var i = rm; i < all.length; i += stride) all[i]]);
      }
    }
  }
  return ops..shuffle(Random(seed));
}

void main() {
  final skip = _skip;

  tearDown(() async {
    await Simulator.reset();
  });

  group('elaboration', () {
    test('rejects a bad radix, too many stages and an empty op set', () {
      expect(
        () => _Rig(const _Spec(intWidth: 32, mode: _iterative, radix: 3)),
        throwsArgumentError,
      );
      expect(
        () => _Rig(const _Spec(intWidth: 32, stages: 36)),
        throwsArgumentError,
      );
      expect(
        () => _Rig(const _Spec(intWidth: 32, narrowWidth: 32)),
        throwsArgumentError,
      );
      expect(
        () => _Rig(const _Spec(formats: [_fp32], fpOps: {HarborFpOp.add})),
        throwsArgumentError,
      );
    });

    test('slot ports follow the mode', () async {
      Map<String, int> slotPorts(_Spec spec) {
        final d = _Rig(spec).dut;
        return {
          for (final e in {...d.inputs, ...d.outputs}.entries)
            if (e.key.contains('slot') || e.key.contains('kill'))
              e.key: e.value.width,
        };
      }

      const it = _Spec(formats: [_fp32], mode: _iterative);
      expect(slotPorts(it), {
        'kill_mask': 4,
        'slot_valid': 4,
        'slot_tag': 4 * _tagWidth,
      });
      expect(_Rig(it).dut.slotNames, ['in', 'step', 'post', 'out']);
      expect(slotPorts(const _Spec(intWidth: 8, stages: 3)), {
        'kill_mask': 3,
        'slot_valid': 3,
        'slot_tag': 3 * _tagWidth,
      });
      expect(slotPorts(const _Spec(intWidth: 8)), isEmpty);
      expect(
        () => HarborDivSqrtRecurrence.integer(
          8,
          _pipelined,
          2,
          3,
          clk: Logic(),
          reset: Logic(),
          killMask: Logic(width: 2),
          inValid: Logic(),
          inOp: Logic(width: 2),
          inA: Logic(width: 8),
          inB: Logic(width: 8),
          outReady: Logic(),
        ),
        throwsArgumentError,
      );
    });

    test('step counts and latency', () {
      final it2 = _Rig(const _Spec(formats: _all, mode: _iterative)).dut;
      final it4 = _Rig(
        const _Spec(formats: _all, mode: _iterative, radix: 4),
      ).dut;
      final p5 = _Rig(const _Spec(formats: _all, stages: 5)).dut;
      expect(it2.steps, 56);
      expect(it2.latency, 60);
      expect(it4.steps, 56);
      expect(it4.latency, 32);
      expect(p5.latency, 5);
      expect(p5.latencyOf(_fpDiv), 5);
      // fp16, fp32 and fp64 are format 0, 1 and 2.
      expect(
        [for (var f = 0; f < 3; f++) it2.latencyOf(_fpDiv, fmt: f)],
        [18, 31, 60],
      );
      expect(
        [for (var f = 0; f < 3; f++) it2.latencyOf(_fpSqrt, fmt: f)],
        [17, 30, 59],
      );
      expect(
        [for (var f = 0; f < 3; f++) it4.latencyOf(_fpDiv, fmt: f)],
        [11, 18, 32],
      );
      expect(
        [for (var f = 0; f < 3; f++) it4.latencyOf(_fpSqrt, fmt: f)],
        [11, 17, 32],
      );
      final i32 = _Rig(
        const _Spec(intWidth: 32, mode: _iterative, radix: 4),
      ).dut;
      expect(i32.steps, 32);
      expect(i32.latency, 20);
      final f32 = _Rig(
        const _Spec(formats: [_fp32], mode: _iterative, radix: 4),
      ).dut;
      expect(f32.steps, 28);
      expect(f32.latency, 18);
      final shared = _Rig(
        const _Spec(
          formats: [_fp64],
          intWidth: 64,
          narrowWidth: 32,
          mode: _iterative,
        ),
      ).dut;
      expect(shared.latency, 68);
      expect(shared.latencyOf(_fpDiv), 60);
      expect(shared.latencyOf(_divS), 68);
      expect(shared.latencyOf(_divS, narrow: true), 36);
    });

    test('definition names carry the parameters', () {
      final a = _Rig(const _Spec(formats: [_fp32], mode: _iterative)).dut;
      final b = _Rig(
        const _Spec(formats: [_fp32], mode: _iterative, radix: 4),
      ).dut;
      final c = _Rig(const _Spec(intWidth: 64, narrowWidth: 32, stages: 3)).dut;
      expect(a.definitionName, 'HarborDivSqrtRecurrence_R2_E8M23_Div_Sqrt');
      expect(b.definitionName, 'HarborDivSqrtRecurrence_R4_E8M23_Div_Sqrt');
      expect(c.definitionName, 'HarborDivSqrtRecurrence_S3_I64_N32');
    });

    test('a divide only build has no square root logic', () async {
      final div = _Rig(const _Spec(formats: [_fp32], fpOps: {HarborFpOp.div}));
      final sqrt = _Rig(
        const _Spec(formats: [_fp32], fpOps: {HarborFpOp.sqrt}),
      );
      await div.dut.build();
      await sqrt.dut.build();
      expect(div.dut.generateSynth(), isNot(contains('x_q')));
      expect(sqrt.dut.generateSynth(), isNot(contains('unpack_b')));
    });
  });

  group('floating point, zero stages', () {
    late _Lanes lanes;
    setUpAll(() async {
      lanes = await _Lanes.create(const _Spec(formats: _all));
    });

    for (final f in _all) {
      for (final op in [_fpDiv, _fpSqrt]) {
        for (var rm = 0; rm < 5; rm++) {
          test(
            'TestFloat ${_tfNames[f]} ${op.name} ${_rmNames[rm]}',
            () => _testFloatLanes(lanes, f, op, rm),
            skip: skip,
          );
        }
      }
    }

    test('random ops in every format against the model', () {
      final ops = _randomFp(lanes.spec, Random(11), 20000);
      _check(lanes.spec, ops, lanes.run(ops));
    });
  });

  group('TestFloat level 2', () {
    // div's level 2 sweep is exhaustive over the operand space, the same
    // size as add/mul (about 7.5M cases at fp32, 40M at fp64): the stride
    // below samples about 50,000, evenly spread. sqrt is unary and level
    // 2 is already small (under 30,000 at fp64), so it runs in full.
    final strides = {_fp32: 149, _fp64: 805};
    late _Lanes lanes;
    setUpAll(() async {
      lanes = await _Lanes.create(const _Spec(formats: [_fp32, _fp64]));
    });

    for (final f in [_fp32, _fp64]) {
      for (var rm = 0; rm < 5; rm++) {
        test(
          '${_tfNames[f]} div ${_rmNames[rm]}',
          () => _testFloatLanes(
            lanes,
            f,
            _fpDiv,
            rm,
            level: 2,
            stride: strides[f]!,
          ),
          tags: ['slow'],
          skip: skip,
          timeout: const Timeout(Duration(minutes: 30)),
        );
        test(
          '${_tfNames[f]} sqrt ${_rmNames[rm]}',
          () => _testFloatLanes(lanes, f, _fpSqrt, rm, level: 2),
          tags: ['slow'],
          skip: skip,
          timeout: const Timeout(Duration(minutes: 5)),
        );
      }
    }
  });

  group('one format builds', () {
    for (final spec in const [
      _Spec(formats: [_fp32]),
      _Spec(formats: [_fp32], fpOps: {HarborFpOp.div}),
      _Spec(formats: [_fp64], fpOps: {HarborFpOp.sqrt}),
      _Spec(formats: [_fp16]),
    ]) {
      test('$spec ${spec.fpOps.map((o) => o.name).join('+')}', () async {
        final lanes = await _Lanes.create(spec);
        final ops = _randomFp(spec, Random(5), 10000);
        _check(spec, ops, lanes.run(ops));
      });
    }

    test('TestFloat f32 div and sqrt in a one format build', () async {
      final lanes = await _Lanes.create(const _Spec(formats: [_fp32]));
      for (var rm = 0; rm < 5; rm++) {
        await _testFloatLanes(lanes, _fp32, _fpDiv, rm);
        await _testFloatLanes(lanes, _fp32, _fpSqrt, rm);
      }
    }, skip: skip);

    test('ftz flushes fp32 inputs and outputs', () async {
      const spec = _Spec(formats: [_fp32], ftz: true);
      final lanes = await _Lanes.create(spec);
      final r = Random(9);
      final ops = _randomFp(spec, r, 20000);
      // Quotients near the subnormal range.
      for (var i = 0; i < 4000; i++) {
        final a = _pack(_fp32, r.nextInt(2), 1 + r.nextInt(30), _bits(r, 23));
        final b = _pack(_fp32, r.nextInt(2), 110 + r.nextInt(40), _bits(r, 23));
        ops.add(_Op(_fpDiv, a, b, rm: r.nextInt(5)));
      }
      _check(spec, ops, lanes.run(ops));
      final flushed = ops.where((o) {
        final res = _model(spec, o);
        return res.flags & ufFlag != 0 && res.result & _mask(31) == BigInt.zero;
      });
      expect(flushed, isNotEmpty);
    });
  });

  group('integer, zero stages', () {
    for (final w in [32, 64]) {
      test('$w bit against BigInt', () async {
        final spec = _Spec(intWidth: w);
        final lanes = await _Lanes.create(spec);
        final ops = _intOps(w, Random(w), 20000);
        _check(spec, ops, lanes.run(ops));
      });
    }

    test('narrow 32 bit ops on a 64 bit engine', () async {
      const spec = _Spec(intWidth: 64, narrowWidth: 32);
      final lanes = await _Lanes.create(spec);
      final r = Random(13);
      final ops = [..._intOps(64, r, 5000), ..._narrowOps(64, 32, r, 5000)]
        ..shuffle(r);
      _check(spec, ops, lanes.run(ops));
    });

    test('fp64 and int64 in one engine', () async {
      const spec = _Spec(formats: [_fp32, _fp64], intWidth: 64);
      final lanes = await _Lanes.create(spec);
      final r = Random(4);
      final ops = [..._randomFp(spec, r, 5000), ..._intOps(64, r, 5000)]
        ..shuffle(r);
      _check(spec, ops, lanes.run(ops));
    });
  });

  group('clocked', () {
    for (final spec in const [
      _Spec(formats: _all, mode: _iterative, radix: 2),
      _Spec(formats: _all, mode: _iterative, radix: 4),
      _Spec(formats: _all, stages: 5),
      _Spec(formats: _all, stages: 14),
    ]) {
      test('$spec TestFloat sample with stalls', () async {
        final ops = await _sample(spec);
        final traces = await Future.wait([
          for (var i = 0; i < 4; i++)
            _clocked(
              spec,
              ops.sublist(i * ops.length ~/ 4, (i + 1) * ops.length ~/ 4),
              seed: i,
            ),
        ]);
        for (var i = 0; i < 4; i++) {
          _checkAll(
            spec,
            ops.sublist(i * ops.length ~/ 4, (i + 1) * ops.length ~/ 4),
            traces[i],
          );
        }
      }, skip: skip);
    }

    // Few stages put many steps in one cone, which the event simulator runs
    // slowly, so these runs use narrow builds. 15 and 9 stages are the
    // step count plus one.
    for (final spec in const [
      _Spec(formats: [_fp16], stages: 1),
      _Spec(formats: [_fp16], stages: 2),
      _Spec(formats: [_fp16], stages: 15),
      _Spec(formats: [_fp16], stages: 17),
      _Spec(formats: [_fp16], fpOps: {HarborFpOp.sqrt}, stages: 15),
    ]) {
      test('$spec random ops with stalls', () async {
        final ops = _randomFp(spec, Random(21), 250);
        _checkAll(spec, ops, await _clocked(spec, ops, seed: 9));
      });
    }

    for (final spec in const [
      _Spec(intWidth: 8, stages: 1),
      _Spec(intWidth: 8, stages: 2),
      _Spec(intWidth: 8, stages: 9),
      _Spec(intWidth: 8, stages: 11),
    ]) {
      test('$spec against BigInt with stalls', () async {
        final ops = _intOps(8, Random(3), 150);
        _checkAll(spec, ops, await _clocked(spec, ops, seed: 4));
      });
    }

    for (final spec in const [
      _Spec(intWidth: 64, narrowWidth: 32, mode: _iterative, radix: 2),
      _Spec(intWidth: 64, narrowWidth: 32, mode: _iterative, radix: 4),
      _Spec(intWidth: 64, narrowWidth: 32, stages: 5),
    ]) {
      test('$spec narrow and wide ops with stalls', () async {
        final r = Random(17);
        final ops = [..._intOps(64, r, 60), ..._narrowOps(64, 32, r, 60)]
          ..shuffle(r);
        _checkAll(spec, ops, await _clocked(spec, ops, seed: 5));
      });
    }

    test('ftz fp32 iterative radix 4', () async {
      const spec = _Spec(
        formats: [_fp32],
        ftz: true,
        mode: _iterative,
        radix: 4,
      );
      final ops = _randomFp(spec, Random(2), 400);
      _checkAll(spec, ops, await _clocked(spec, ops));
    });

    for (final w in [32, 64]) {
      for (final spec in [
        _Spec(intWidth: w, mode: _iterative, radix: 2),
        _Spec(intWidth: w, mode: _iterative, radix: 4),
        _Spec(intWidth: w, stages: 4),
      ]) {
        test('$spec against BigInt with stalls', () async {
          final ops = _intOps(w, Random(w + spec.radix), 200);
          _checkAll(spec, ops, await _clocked(spec, ops, seed: w));
        });
      }
    }

    test('fp64 and int64 share an iterative radix 4 engine', () async {
      const spec = _Spec(
        formats: [_fp64],
        intWidth: 64,
        mode: _iterative,
        radix: 4,
      );
      final r = Random(8);
      final ops = [..._randomFp(spec, r, 150), ..._intOps(64, r, 50)]
        ..shuffle(r);
      _checkAll(spec, ops, await _clocked(spec, ops));
    });

    for (final radix in [2, 4]) {
      test('iterative radix $radix: each format runs its own steps', () async {
        final spec = _Spec(
          formats: const [_fp32, _fp64],
          mode: _iterative,
          radix: radix,
        );
        final ops = _randomFp(spec, Random(radix), 40);
        final t = await _clocked(spec, ops, gap: 0, stall: 0, serial: true);
        _checkAll(spec, ops, t);
        final dut = _Rig(spec).dut;
        final want = {
          for (final (op, fmt) in [
            (_fpDiv, 0),
            (_fpSqrt, 0),
            (_fpDiv, 1),
            (_fpSqrt, 1),
          ])
            (op, fmt): dut.latencyOf(op, fmt: fmt),
        };
        expect(want, {
          (_fpDiv, 0): radix == 2 ? 31 : 18,
          (_fpSqrt, 0): radix == 2 ? 30 : 17,
          (_fpDiv, 1): radix == 2 ? 60 : 32,
          (_fpSqrt, 1): radix == 2 ? 59 : 32,
        });
        for (var i = 0; i < ops.length; i++) {
          expect(
            t.takeCycles[i] - t.acceptCycles[i]!,
            want[(ops[i].op, ops[i].fmt)],
            reason: '${ops[i]}',
          );
        }
        expect(ops.map((o) => o.fmt).toSet(), {0, 1});
      });

      test('iterative radix $radix: narrow ops run their own steps', () async {
        final spec = _Spec(
          intWidth: 64,
          narrowWidth: 32,
          mode: _iterative,
          radix: radix,
        );
        final r = Random(radix + 30);
        final ops = [..._intOps(64, r, 10), ..._narrowOps(64, 32, r, 10)]
          ..shuffle(r);
        final t = await _clocked(spec, ops, gap: 0, stall: 0, serial: true);
        _checkAll(spec, ops, t);
        for (var i = 0; i < ops.length; i++) {
          final narrow = ops[i].narrow;
          expect(
            t.takeCycles[i] - t.acceptCycles[i]!,
            radix == 2 ? (narrow ? 36 : 68) : (narrow ? 20 : 36),
            reason: '${ops[i]}',
          );
        }
      });

      test(
        'iterative radix $radix: one op each steps plus one cycle',
        () async {
          final spec = _Spec(intWidth: 32, mode: _iterative, radix: radix);
          final ops = _intOps(32, Random(radix), 10).sublist(0, 12);
          final t = await _clocked(spec, ops, gap: 0, stall: 0);
          _checkAll(spec, ops, t);
          final iters = 32 ~/ (radix ~/ 2);
          final latency = _Rig(spec).dut.latency;
          expect(latency, iters + 4);
          expect(t.takeCycles[0] - t.acceptCycles[0]!, latency);
          // The next op waits in the input registers.
          for (var i = 2; i < ops.length; i++) {
            expect(t.acceptCycles[i]! - t.acceptCycles[i - 1]!, iters + 1);
          }
        },
      );
    }

    test('pipelined takes one op each cycle', () async {
      const spec = _Spec(formats: _all, stages: 4);
      final ops = _randomFp(spec, Random(6), 60);
      final t = await _clocked(spec, ops, gap: 0, stall: 0);
      _checkAll(spec, ops, t);
      for (var i = 0; i < ops.length; i++) {
        expect(t.acceptCycles[i], t.acceptCycles[0]! + i);
        expect(t.takeCycles[i], t.acceptCycles[i]! + 4);
      }
    });

    for (final spec in const [
      _Spec(formats: _all, mode: _iterative, radix: 4),
      _Spec(formats: _all, stages: 6),
      _Spec(formats: [_fp16], stages: 1),
      _Spec(intWidth: 32, mode: _iterative, radix: 2),
      _Spec(intWidth: 64, stages: 3),
    ]) {
      test('$spec: kill drops ops in flight, the next ops are clean', () async {
        final r = Random(12);
        final ops = spec.intWidth > 0
            ? _intOps(spec.intWidth, r, 40).sublist(0, 40)
            : _randomFp(spec, r, 40);
        final lat = _Rig(spec).dut.latency;
        final kills = {6, 7 + lat ~/ 2, 12 + 3 * lat};
        final t = await _clocked(spec, ops, kills: kills, gap: 0.1);
        expect(t.errors, isEmpty);
        final tags = [for (final (tag, _) in t.taken) tag];
        expect(tags, isNotEmpty);
        for (var i = 1; i < tags.length; i++) {
          expect(tags[i], greaterThan(tags[i - 1]));
        }
        // An op accepted before a kill comes out before it or never.
        for (var i = 0; i < t.taken.length; i++) {
          final tag = tags[i];
          for (final k in kills) {
            final accepted = t.acceptCycles[tag]! < k;
            if (accepted) {
              expect(t.takeCycles[i], lessThan(k), reason: 'tag $tag');
            }
          }
        }
        expect(tags.length, lessThan(ops.length));
        // Every op accepted in or after the last kill cycle comes out.
        final last = kills.reduce(max);
        final after = [
          for (final e in t.acceptCycles.entries)
            if (e.value >= last) e.key,
        ];
        expect(after, isNotEmpty);
        expect(tags.toSet().containsAll(after), isTrue);
        _check(spec, ops, [for (final (_, o) in t.taken) o], tags: tags);
      });
    }
  });
}
