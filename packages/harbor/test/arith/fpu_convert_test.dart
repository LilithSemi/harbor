import 'dart:math';

import 'package:harbor/src/arith/fp_convert_path.dart';
import 'package:harbor/src/arith/fp_format.dart';
import 'package:harbor/src/arith/fpu_config.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'fp_model.dart';
import 'fp_stall_bench.dart';
import 'lane_sim.dart';
import 'testfloat_vectors.dart';

final _opIdxW = (HarborFpOp.values.length - 1).bitLength;
const _rmNames = ['near_even', 'minMag', 'min', 'max', 'near_maxMag'];

const _f16 = HarborFpFormat.fp16;
const _f32 = HarborFpFormat.fp32;
const _f64 = HarborFpFormat.fp64;
final _fmts = [_f16, _f32, _f64];
final _tfName = {_f16: 'f16', _f32: 'f32', _f64: 'f64'};

String? get _skip => testFloatAvailable()
    ? null
    : 'testfloat_gen not found; set HARBOR_TESTFLOAT_GEN or run inside '
          '`nix develop`';

/// The combinational path with free inputs, driven through [LaneSim].
class _Bench {
  final HarborFpuConfig config;
  final op = Logic(name: 'op', width: _opIdxW);
  late final Logic fmt;
  late final Logic fmtDst;
  final rm = Logic(name: 'rm', width: 3);
  late final Logic a;
  late final Logic intIn;
  late final Logic intWidth;
  final signedL = Logic(name: 'signed');
  final liIndex = Logic(name: 'li_index', width: 5);
  final en = Logic(name: 'en');
  late final HarborFpConvertPath path;
  late final LaneSim sim;

  _Bench(this.config, {Logic? clk}) {
    fmt = Logic(name: 'fmt', width: config.fmtWidth);
    fmtDst = Logic(name: 'fmt_dst', width: config.fmtWidth);
    a = Logic(name: 'a', width: config.widest.width);
    final maxIntW = config.intWidths.isEmpty ? 1 : config.intWidths.reduce(max);
    intIn = Logic(name: 'int_in', width: maxIntW);
    intWidth = Logic(
      name: 'int_width',
      width: max(1, (config.intWidths.length - 1).bitLength),
    );
    path = HarborFpConvertPath(
      config,
      op: op,
      fmt: fmt,
      fmtDst: fmtDst,
      rm: rm,
      a: a,
      intIn: intIn,
      intWidth: intWidth,
      signed: signedL,
      liIndex: liIndex,
      clk: clk,
      enables: clk == null ? const {} : {for (final k in config.cuts) k: en},
    );
  }

  Future<void> build() async {
    await path.build();
    if (config.cuts.isNotEmpty && path.tryInput('clk') != null) {
      return;
    }
    sim = LaneSim(
      path,
      [op, fmt, fmtDst, rm, a, intIn, intWidth, signedL, liIndex],
      [path.result, path.flags],
    );
  }

  /// Drives [k] on the ports, for the ROHD simulator.
  void put(_Case k) {
    op.put(k.op.index);
    fmt.put(k.fmt);
    fmtDst.put(k.fmtDst);
    rm.put(k.rm);
    a.put(LogicValue.ofBigInt(k.a, a.width));
    intIn.put(LogicValue.ofBigInt(k.intIn, intIn.width));
    intWidth.put(k.intWidth);
    signedL.put(k.signed ? 1 : 0);
    liIndex.put(k.li);
  }

  FpResult read() =>
      FpResult(path.result.value.toBigInt(), path.flags.value.toInt());

  /// Runs [cases] through [sim].
  List<FpResult> runCases(List<_Case> cases) => [
    for (final g in run(
      ops: [for (final k in cases) k.op.index],
      fmts: [for (final k in cases) k.fmt],
      fmtDsts: [for (final k in cases) k.fmtDst],
      rms: [for (final k in cases) k.rm],
      as: [for (final k in cases) k.a],
      intIns: [for (final k in cases) k.intIn],
      intWidths: [for (final k in cases) k.intWidth],
      signeds: [for (final k in cases) k.signed ? 1 : 0],
      liIndices: [for (final k in cases) k.li],
    ))
      FpResult(g.bits, g.flags),
  ];

  /// Runs full-length, parallel per-lane value lists through [sim].
  List<({BigInt bits, int flags})> run({
    required List<int> ops,
    required List<int> fmts,
    List<int>? fmtDsts,
    required List<int> rms,
    required List<BigInt> as,
    List<BigInt>? intIns,
    List<int>? intWidths,
    List<int>? signeds,
    List<int>? liIndices,
  }) {
    final n = ops.length;
    fmtDsts ??= List.filled(n, 0);
    intIns ??= List.filled(n, BigInt.zero);
    intWidths ??= List.filled(n, 0);
    signeds ??= List.filled(n, 0);
    liIndices ??= List.filled(n, 0);
    final out = <({BigInt bits, int flags})>[];
    for (var i = 0; i < n; i += LaneSim.lanes) {
      final end = min(i + LaneSim.lanes, n);
      sim
        ..set(op, [for (var j = i; j < end; j++) BigInt.from(ops[j])])
        ..set(fmt, [for (var j = i; j < end; j++) BigInt.from(fmts[j])])
        ..set(fmtDst, [for (var j = i; j < end; j++) BigInt.from(fmtDsts[j])])
        ..set(rm, [for (var j = i; j < end; j++) BigInt.from(rms[j])])
        ..set(a, as.sublist(i, end))
        ..set(intIn, intIns.sublist(i, end))
        ..set(intWidth, [
          for (var j = i; j < end; j++) BigInt.from(intWidths[j]),
        ])
        ..set(signedL, [for (var j = i; j < end; j++) BigInt.from(signeds[j])])
        ..set(liIndex, [
          for (var j = i; j < end; j++) BigInt.from(liIndices[j]),
        ])
        ..run();
      final bits = sim.get(path.result, end - i);
      final flags = sim.get(path.flags, end - i);
      for (var k = 0; k < end - i; k++) {
        out.add((bits: bits[k], flags: flags[k].toInt()));
      }
    }
    return out;
  }
}

HarborFpuConfig _fullConfig({bool ftz = false, int stages = 0}) =>
    HarborFpuConfig(
      formats: _fmts,
      ops: harborFpConvertOps,
      stages: stages,
      ftz: ftz,
      intWidths: [32, 64],
    );

const _intWidths = [32, 64];

/// One op on the ports of the convert path. Bits above the operand format
/// and above the selected integer width are noise.
class _Case {
  final HarborFpOp op;
  final int fmt;
  final int fmtDst;
  final int rm;
  final BigInt a;
  final BigInt intIn;
  final int intWidth;
  final bool signed;
  final int li;

  _Case(
    this.op, {
    this.fmt = 0,
    this.fmtDst = 0,
    this.rm = 0,
    BigInt? a,
    BigInt? intIn,
    this.intWidth = 0,
    this.signed = false,
    this.li = 0,
  }) : a = a ?? BigInt.zero,
       intIn = intIn ?? BigInt.zero;

  FpResult model({bool ftz = false}) {
    final f = _fmts[fmt];
    final x = a & ((BigInt.one << f.width) - BigInt.one);
    final w = _intWidths[intWidth];
    return switch (op) {
      HarborFpOp.fpToFp => fpToFp(f, _fmts[fmtDst], x, rm, ftz: ftz),
      HarborFpOp.fpToInt => fpToInt(f, x, w, signed, rm, ftz: ftz),
      HarborFpOp.intToFp => intToFp(f, intIn, w, signed, rm),
      HarborFpOp.cvtModWD => fpCvtModWD(x, ftz: ftz),
      HarborFpOp.li => fpLi(f, li),
      HarborFpOp.round => fpRound(f, x, rm, ftz: ftz),
      HarborFpOp.roundNx => fpRound(f, x, rm, exact: true, ftz: ftz),
      _ => throw ArgumentError.value(op),
    };
  }

  @override
  String toString() =>
      '$op fmt $fmt dst $fmtDst rm $rm a ${a.toRadixString(16)} '
      'int ${intIn.toRadixString(16)} w $intWidth signed $signed li $li';
}

BigInt _bits(Random r, int w) {
  var v = BigInt.zero;
  for (var i = 0; i < w; i += 16) {
    v = (v << 16) | BigInt.from(r.nextInt(1 << 16));
  }
  return v & ((BigInt.one << w) - BigInt.one);
}

/// A value of [f] with unbiased exponent near [e], or a subnormal, zero, Inf
/// or NaN, with noise above the format.
BigInt _value(Random r, HarborFpFormat f, int e) {
  final top = (1 << f.exponentWidth) - 1;
  final exp = switch (r.nextInt(12)) {
    0 => 0,
    1 => top,
    _ => (e + f.bias).clamp(0, top),
  };
  var mant = _bits(r, f.mantissaWidth);
  if (r.nextInt(8) == 0) {
    mant = BigInt.zero;
  }
  final v =
      (BigInt.from(r.nextInt(2)) << (f.width - 1)) |
      (BigInt.from(exp) << f.mantissaWidth) |
      mant;
  return v | (_bits(r, 64) >> f.width << f.width);
}

/// Random cases of [op] that reach the edges: subnormal sources and
/// results, integer range ends, and values near integers.
List<_Case> _cases(HarborFpOp op, Random r, int n) {
  _Case one() {
    final fi = r.nextInt(_fmts.length);
    final f = _fmts[fi];
    final rm = r.nextInt(5);
    final wi = r.nextInt(2);
    final w = _intWidths[wi];
    final signed = r.nextBool();
    switch (op) {
      case HarborFpOp.fpToFp:
        final di = r.nextInt(_fmts.length);
        final d = _fmts[di];
        // Near the destination subnormal range, its overflow, or anywhere.
        final e = switch (r.nextInt(3)) {
          0 => 1 - d.bias - r.nextInt(d.mantissaWidth + 3),
          1 => d.bias - 1 + r.nextInt(3),
          _ => r.nextInt(2 * f.bias + 2) - f.bias,
        };
        return _Case(op, fmt: fi, fmtDst: di, rm: rm, a: _value(r, f, e));
      case HarborFpOp.fpToInt:
        final e = r.nextBool() ? w - 3 + r.nextInt(5) : r.nextInt(w + 4) - 3;
        return _Case(
          op,
          fmt: fi,
          rm: rm,
          a: _value(r, f, e),
          intWidth: wi,
          signed: signed,
        );
      case HarborFpOp.intToFp:
        var v = _bits(r, 64);
        if (r.nextBool()) {
          v >>= r.nextInt(64);
        }
        if (r.nextInt(4) == 0) {
          // Near the top of the selected width.
          v =
              ((BigInt.one << (w - 1)) - BigInt.from(r.nextInt(5) - 2)) |
              (_bits(r, 64) >> w << w);
        }
        return _Case(
          op,
          fmt: fi,
          rm: rm,
          intIn: v,
          intWidth: wi,
          signed: signed,
        );
      case HarborFpOp.cvtModWD:
        final e = r.nextInt(100) - 4;
        return _Case(op, fmt: 2, rm: rm, a: _value(r, _f64, e));
      case HarborFpOp.li:
        return _Case(op, fmt: fi, rm: rm, li: r.nextInt(32), a: _bits(r, 64));
      case HarborFpOp.round || HarborFpOp.roundNx:
        final e = r.nextInt(f.mantissaWidth + 6) - 3;
        return _Case(op, fmt: fi, rm: rm, a: _value(r, f, e));
      default:
        throw ArgumentError.value(op);
    }
  }

  return [for (var i = 0; i < n; i++) one()];
}

void _checkAll(
  List<({BigInt bits, int flags})> got,
  List<BigInt> wantBits,
  List<int> wantFlags,
  List<String> labels,
) {
  final bad = <String>[];
  var count = 0;
  for (var i = 0; i < got.length; i++) {
    if (got[i].bits != wantBits[i] || got[i].flags != wantFlags[i]) {
      count++;
      if (bad.length < 8) {
        bad.add(
          '${labels[i]}: got ${got[i].bits.toRadixString(16)}/'
          '${got[i].flags}, want ${wantBits[i].toRadixString(16)}/'
          '${wantFlags[i]}',
        );
      }
    }
  }
  expect(count, 0, reason: '$count of ${got.length} wrong:\n${bad.join('\n')}');
}

void main() {
  tearDown(Simulator.reset);

  group('fpToFp, TestFloat level 1', () {
    final pairs = [
      (_f16, _f32),
      (_f32, _f16),
      (_f32, _f64),
      (_f64, _f32),
      (_f16, _f64),
      (_f64, _f16),
    ];
    for (final (src, dst) in pairs) {
      for (final rmv in [0, 1, 2, 3, 4]) {
        test('${_tfName[src]}_to_${_tfName[dst]} rm $rmv', () async {
          final b = _Bench(_fullConfig());
          await b.build();
          final cases = await testFloatCases(
            '${_tfName[src]}_to_${_tfName[dst]}',
            rm: _rmNames[rmv],
          ).toList();
          final srcIdx = _fmts.indexOf(src);
          final dstIdx = _fmts.indexOf(dst);
          final got = b.run(
            ops: List.filled(cases.length, HarborFpOp.fpToFp.index),
            fmts: List.filled(cases.length, srcIdx),
            fmtDsts: List.filled(cases.length, dstIdx),
            rms: List.filled(cases.length, rmv),
            as: [for (final c in cases) c.operands[0]],
          );
          _checkAll(
            got,
            [for (final c in cases) c.result],
            [for (final c in cases) c.flags],
            [for (final c in cases) '${c.operands[0].toRadixString(16)}'],
          );
        }, skip: _skip);
      }
    }
  });

  group('fpToInt, TestFloat level 1', () {
    final kinds = [
      ('i32', 32, 1, 0),
      ('ui32', 32, 0, 0),
      ('i64', 64, 1, 1),
      ('ui64', 64, 0, 1),
    ];
    for (final f in _fmts) {
      for (final (suffix, _, signed, widthSel) in kinds) {
        for (final rmv in [0, 1, 2, 3, 4]) {
          test('${_tfName[f]}_to_$suffix rm $rmv', () async {
            final b = _Bench(_fullConfig());
            await b.build();
            final cases = await testFloatCases(
              '${_tfName[f]}_to_$suffix',
              rm: _rmNames[rmv],
              exact: true,
            ).toList();
            final fmtIdx = _fmts.indexOf(f);
            final got = b.run(
              ops: List.filled(cases.length, HarborFpOp.fpToInt.index),
              fmts: List.filled(cases.length, fmtIdx),
              rms: List.filled(cases.length, rmv),
              as: [for (final c in cases) c.operands[0]],
              signeds: List.filled(cases.length, signed),
              intWidths: List.filled(cases.length, widthSel),
            );
            _checkAll(
              got,
              [for (final c in cases) c.result],
              [for (final c in cases) c.flags],
              [for (final c in cases) '${c.operands[0].toRadixString(16)}'],
            );
          }, skip: _skip);
        }
      }
    }
  });

  group('intToFp, TestFloat level 1', () {
    final kinds = [
      ('i32', 32, 1, 0),
      ('ui32', 32, 0, 0),
      ('i64', 64, 1, 1),
      ('ui64', 64, 0, 1),
    ];
    for (final f in _fmts) {
      for (final (suffix, _, signed, widthSel) in kinds) {
        for (final rmv in [0, 1, 2, 3, 4]) {
          test('${suffix}_to_${_tfName[f]} rm $rmv', () async {
            final b = _Bench(_fullConfig());
            await b.build();
            final cases = await testFloatCases(
              '${suffix}_to_${_tfName[f]}',
              rm: _rmNames[rmv],
              exact: true,
            ).toList();
            final fmtIdx = _fmts.indexOf(f);
            final got = b.run(
              ops: List.filled(cases.length, HarborFpOp.intToFp.index),
              fmts: List.filled(cases.length, fmtIdx),
              rms: List.filled(cases.length, rmv),
              as: List.filled(cases.length, BigInt.zero),
              intIns: [for (final c in cases) c.operands[0]],
              signeds: List.filled(cases.length, signed),
              intWidths: List.filled(cases.length, widthSel),
            );
            _checkAll(
              got,
              [for (final c in cases) c.result],
              [for (final c in cases) c.flags],
              [for (final c in cases) '${c.operands[0].toRadixString(16)}'],
            );
          }, skip: _skip);
        }
      }
    }
  });

  group('round / roundNx, TestFloat level 1', () {
    for (final f in _fmts) {
      for (final exact in [false, true]) {
        for (final rmv in [0, 1, 2, 3, 4]) {
          test('${_tfName[f]} roundToInt exact=$exact rm $rmv', () async {
            final b = _Bench(_fullConfig());
            await b.build();
            final cases = await testFloatCases(
              '${_tfName[f]}_roundToInt',
              rm: _rmNames[rmv],
              exact: exact,
            ).toList();
            final fmtIdx = _fmts.indexOf(f);
            final hop = exact ? HarborFpOp.roundNx : HarborFpOp.round;
            final got = b.run(
              ops: List.filled(cases.length, hop.index),
              fmts: List.filled(cases.length, fmtIdx),
              rms: List.filled(cases.length, rmv),
              as: [for (final c in cases) c.operands[0]],
            );
            _checkAll(
              got,
              [for (final c in cases) c.result],
              [for (final c in cases) c.flags],
              [for (final c in cases) '${c.operands[0].toRadixString(16)}'],
            );
          }, skip: _skip);
        }
      }
    }
  });

  test('cvtModWD vs model, random', () async {
    final b = _Bench(_fullConfig());
    await b.build();
    final r = Random(500);
    final fp64Idx = _fmts.indexOf(_f64);
    final n = 20000;
    final as = <BigInt>[];
    for (var i = 0; i < n; i++) {
      final bits =
          BigInt.from(r.nextInt(1 << 32)) << 32 |
          BigInt.from(r.nextInt(1 << 32));
      as.add(bits);
    }
    final got = b.run(
      ops: List.filled(n, HarborFpOp.cvtModWD.index),
      fmts: List.filled(n, fp64Idx),
      rms: List.filled(n, 1),
      as: as,
    );
    final want = [for (final bits in as) fpCvtModWD(bits)];
    _checkAll(
      got,
      [for (final w in want) w.bits],
      [for (final w in want) w.flags],
      [for (final bits in as) bits.toRadixString(16)],
    );
  });

  test('fli, every index and configured format', () async {
    final b = _Bench(_fullConfig());
    await b.build();
    final ops = <int>[];
    final fmts = <int>[];
    final liIndices = <int>[];
    for (var fi = 0; fi < _fmts.length; fi++) {
      for (var idx = 0; idx < 32; idx++) {
        ops.add(HarborFpOp.li.index);
        fmts.add(fi);
        liIndices.add(idx);
      }
    }
    final got = b.run(
      ops: ops,
      fmts: fmts,
      rms: List.filled(ops.length, 0),
      as: List.filled(ops.length, BigInt.zero),
      liIndices: liIndices,
    );
    var k = 0;
    for (var fi = 0; fi < _fmts.length; fi++) {
      for (var idx = 0; idx < 32; idx++) {
        final want = fpLi(_fmts[fi], idx);
        expect(got[k].bits, want.bits, reason: '${_fmts[fi]} index $idx');
        expect(got[k].flags, 0);
        k++;
      }
    }
  });

  group('ftz on value ops', () {
    test('fpToFp subnormal source flushes', () async {
      final b = _Bench(_fullConfig(ftz: true));
      await b.build();
      final r = Random(600);
      final n = 4000;
      final as = <BigInt>[];
      final fmts = <int>[];
      for (var i = 0; i < n; i++) {
        final fi = r.nextInt(_fmts.length);
        final f = _fmts[fi];
        var mant = BigInt.zero;
        for (var k = 0; k < f.mantissaWidth; k += 16) {
          mant = (mant << 16) | BigInt.from(r.nextInt(1 << 16));
        }
        mant = (mant & ((BigInt.one << f.mantissaWidth) - BigInt.one));
        if (mant == BigInt.zero) mant = BigInt.one;
        final sign = BigInt.from(r.nextInt(2)) << (f.width - 1);
        as.add(sign | mant);
        fmts.add(fi);
      }
      final got = b.run(
        ops: List.filled(n, HarborFpOp.fpToFp.index),
        fmts: fmts,
        fmtDsts: fmts,
        rms: List.filled(n, 0),
        as: as,
      );
      final want = [
        for (var i = 0; i < n; i++)
          fpToFp(_fmts[fmts[i]], _fmts[fmts[i]], as[i], 0, ftz: true),
      ];
      _checkAll(
        got,
        [for (final w in want) w.bits],
        [for (final w in want) w.flags],
        [for (final bits in as) bits.toRadixString(16)],
      );
    });

    BigInt subnormalBits(Random r, HarborFpFormat f) {
      var mant = BigInt.zero;
      for (var k = 0; k < f.mantissaWidth; k += 16) {
        mant = (mant << 16) | BigInt.from(r.nextInt(1 << 16));
      }
      mant &= (BigInt.one << f.mantissaWidth) - BigInt.one;
      if (mant == BigInt.zero) mant = BigInt.one;
      final sign = BigInt.from(r.nextInt(2)) << (f.width - 1);
      return sign | mant;
    }

    test('round/roundNx subnormal source flushes', () async {
      final b = _Bench(_fullConfig(ftz: true));
      await b.build();
      final r = Random(610);
      final n = 2000;
      final as = <BigInt>[];
      final fmts = <int>[];
      final ops = <int>[];
      for (var i = 0; i < n; i++) {
        final fi = r.nextInt(_fmts.length);
        as.add(subnormalBits(r, _fmts[fi]));
        fmts.add(fi);
        ops.add(
          r.nextBool() ? HarborFpOp.round.index : HarborFpOp.roundNx.index,
        );
      }
      final got = b.run(ops: ops, fmts: fmts, rms: List.filled(n, 0), as: as);
      final want = [
        for (var i = 0; i < n; i++)
          fpRound(
            _fmts[fmts[i]],
            as[i],
            0,
            exact: ops[i] == HarborFpOp.roundNx.index,
            ftz: true,
          ),
      ];
      _checkAll(
        got,
        [for (final w in want) w.bits],
        [for (final w in want) w.flags],
        [for (final bits in as) bits.toRadixString(16)],
      );
    });

    test('fpToInt subnormal source flushes', () async {
      final b = _Bench(_fullConfig(ftz: true));
      await b.build();
      final r = Random(620);
      final n = 2000;
      final as = <BigInt>[];
      final fmts = <int>[];
      for (var i = 0; i < n; i++) {
        final fi = r.nextInt(_fmts.length);
        as.add(subnormalBits(r, _fmts[fi]));
        fmts.add(fi);
      }
      final got = b.run(
        ops: List.filled(n, HarborFpOp.fpToInt.index),
        fmts: fmts,
        rms: List.filled(n, 0),
        as: as,
        signeds: List.filled(n, 1),
        intWidths: List.filled(n, 1),
      );
      final want = [
        for (var i = 0; i < n; i++)
          fpToInt(_fmts[fmts[i]], as[i], 64, true, 0, ftz: true),
      ];
      _checkAll(
        got,
        [for (final w in want) w.bits],
        [for (final w in want) w.flags],
        [for (final bits in as) bits.toRadixString(16)],
      );
    });

    test('cvtModWD subnormal source flushes', () async {
      final b = _Bench(_fullConfig(ftz: true));
      await b.build();
      final r = Random(630);
      final n = 2000;
      final fp64Idx = _fmts.indexOf(_f64);
      final as = [for (var i = 0; i < n; i++) subnormalBits(r, _f64)];
      final got = b.run(
        ops: List.filled(n, HarborFpOp.cvtModWD.index),
        fmts: List.filled(n, fp64Idx),
        rms: List.filled(n, 1),
        as: as,
      );
      final want = [for (final bits in as) fpCvtModWD(bits, ftz: true)];
      _checkAll(
        got,
        [for (final w in want) w.bits],
        [for (final w in want) w.flags],
        [for (final bits in as) bits.toRadixString(16)],
      );
    });

    test('li is unaffected by ftz', () async {
      final b = _Bench(_fullConfig(ftz: true));
      await b.build();
      final ops = <int>[];
      final fmts = <int>[];
      final liIndices = <int>[];
      for (var fi = 0; fi < _fmts.length; fi++) {
        for (var idx = 0; idx < 32; idx++) {
          ops.add(HarborFpOp.li.index);
          fmts.add(fi);
          liIndices.add(idx);
        }
      }
      final got = b.run(
        ops: ops,
        fmts: fmts,
        rms: List.filled(ops.length, 0),
        as: List.filled(ops.length, BigInt.zero),
        liIndices: liIndices,
      );
      var k = 0;
      for (var fi = 0; fi < _fmts.length; fi++) {
        for (var idx = 0; idx < 32; idx++) {
          final want = fpLi(_fmts[fi], idx);
          expect(got[k].bits, want.bits, reason: '${_fmts[fi]} index $idx');
          expect(got[k].flags, 0);
          k++;
        }
      }
    });
  });

  test('direct ROHD simulator cross-check', () async {
    final b = _Bench(_fullConfig());
    await b.build();
    final fmt = b.fmt;
    final fmtDst = b.fmtDst;
    final rm = b.rm;
    final a = b.a;
    final op = b.op;
    final r = Random(700);
    for (var i = 0; i < 200; i++) {
      final fi = r.nextInt(_fmts.length);
      final f = _fmts[fi];
      final bits =
          BigInt.from(r.nextInt(1 << 16)) &
          ((BigInt.one << f.width) - BigInt.one);
      final rmv = r.nextInt(5);
      op.put(HarborFpOp.fpToFp.index);
      fmt.put(fi);
      fmtDst.put(fi);
      rm.put(rmv);
      a.put(LogicValue.ofBigInt(bits, a.width));
      final want = fpToFp(f, f, bits, rmv);
      expect(b.path.result.value.toBigInt(), want.bits, reason: '$f $bits');
      expect(b.path.flags.value.toInt(), want.flags);
    }
  });

  group('ROHD simulator cross-check', () {
    for (final ftz in [false, true]) {
      for (final op in harborFpConvertOps) {
        test('$op, ftz $ftz', () async {
          final config = _fullConfig(ftz: ftz);
          final r = Random(op.index * 2 + (ftz ? 1 : 0));
          final cases = _cases(op, r, op == HarborFpOp.fpToFp ? 900 : 300);
          final lanes = _Bench(config);
          await lanes.build();
          final fromLanes = lanes.runCases(cases);
          Simulator.reset();
          final b = _Bench(config);
          await b.build();
          for (var i = 0; i < cases.length; i++) {
            final k = cases[i];
            b.put(k);
            final got = b.read();
            final want = k.model(ftz: ftz);
            expect(got.bits, want.bits, reason: '$k');
            expect(got.flags, want.flags, reason: '$k');
            expect(fromLanes[i].bits, got.bits, reason: 'lane sim $k');
            expect(fromLanes[i].flags, got.flags, reason: 'lane sim $k');
          }
        });
      }
    }
  });

  test('ftz flushes a subnormal result of a narrowing fpToFp', () async {
    final b = _Bench(_fullConfig(ftz: true));
    await b.build();
    final r = Random(800);
    final cases = <_Case>[];
    for (final (si, di) in [(1, 0), (2, 0), (2, 1)]) {
      final d = _fmts[di];
      for (var n = 0; n < 400; n++) {
        // A normal source whose value is subnormal in the destination.
        final e = 1 - d.bias - 1 - r.nextInt(d.mantissaWidth);
        cases.add(
          _Case(
            HarborFpOp.fpToFp,
            fmt: si,
            fmtDst: di,
            rm: r.nextInt(5),
            a:
                (BigInt.from(r.nextInt(2)) << (_fmts[si].width - 1)) |
                (BigInt.from(e + _fmts[si].bias) << _fmts[si].mantissaWidth) |
                _bits(r, _fmts[si].mantissaWidth),
          ),
        );
      }
    }
    final got = b.runCases(cases);
    var flushed = 0;
    for (var i = 0; i < cases.length; i++) {
      final want = cases[i].model(ftz: true);
      expect(got[i].bits, want.bits, reason: '${cases[i]}');
      expect(got[i].flags, want.flags, reason: '${cases[i]}');
      final d = _fmts[cases[i].fmtDst];
      final magnitude =
          got[i].bits & ((BigInt.one << (d.width - 1)) - BigInt.one);
      if (magnitude == BigInt.zero) {
        expect(got[i].flags, 0x3, reason: 'UF and NX on a flush');
        flushed++;
      }
    }
    expect(flushed, greaterThan(cases.length ~/ 2));
  });

  for (final (stages, ftz) in [(2, false), (6, true)]) {
    test(
      'registers at the cuts of $stages stages, mixed ops, stalls',
      () async {
        final config = _fullConfig(ftz: ftz, stages: stages);
        final clk = SimpleClockGenerator(10).clk;
        final b = _Bench(config, clk: clk);
        await b.build();
        final r = Random(stages + 20);
        final ops = harborFpConvertOps.toList();
        final pool = {for (final op in ops) op: _cases(op, r, 60)};
        final cases = <_Case>[
          // fpToFp then fpToInt back to back, and other pairs.
          for (var n = 0; n < 8; n++) pool[HarborFpOp.fpToFp]![n],
          for (var n = 0; n < 8; n++)
            pool[[HarborFpOp.fpToFp, HarborFpOp.fpToInt][n % 2]]![n + 8],
          for (var n = 0; n < 300; n++)
            pool[ops[r.nextInt(ops.length)]]![r.nextInt(60)],
        ];
        final seen = await runWithStalls(
          clk: clk,
          en: b.en,
          latency: config.latency,
          count: cases.length,
          put: (i) => b.put(cases[i]),
          putJunk: () => b.put(cases[r.nextInt(cases.length)]),
          read: b.read,
          random: r,
        );
        final stalls = checkStallRun(seen, cases.length, (i, got) {
          final want = cases[i].model(ftz: ftz);
          expect(got.bits, want.bits, reason: 'case $i ${cases[i]}');
          expect(got.flags, want.flags, reason: 'case $i ${cases[i]}');
        });
        expect(stalls, greaterThan(50));
      },
    );
  }

  test('bits that cross each cut', () async {
    final b = _Bench(_fullConfig());
    final bits = [
      for (final k in HarborFpCut.values)
        b.path.cuts[k]!.fold(0, (s, l) => s + l.width),
    ];
    expect(bits, [107, 101, 102, 97, 97, 167, 69]);
  });

  test('op subsets build and are correct', () async {
    final r = Random(900);
    var checked = 0;
    for (final formats in [
      [_f32],
      _fmts,
    ]) {
      for (final op in harborFpConvertOps) {
        if (op == HarborFpOp.cvtModWD && !formats.contains(_f64)) {
          continue;
        }
        Simulator.reset();
        final config = HarborFpuConfig(
          formats: formats,
          ops: {op},
          stages: 0,
          intWidths: _intWidths,
        );
        final b = _Bench(config);
        await b.build();
        for (final k in _cases(op, r, 120)) {
          // Map the format index onto this config.
          final fi = formats.indexOf(_fmts[k.fmt]);
          final di = formats.indexOf(_fmts[k.fmtDst]);
          if (fi < 0 || di < 0) {
            continue;
          }
          final c = _Case(
            k.op,
            fmt: fi,
            fmtDst: di,
            rm: k.rm,
            a: k.a & ((BigInt.one << formats.last.width) - BigInt.one),
            intIn: k.intIn,
            intWidth: k.intWidth,
            signed: k.signed,
            li: k.li,
          );
          b.put(c);
          final got = b.read();
          final want = k.model();
          expect(got.bits, want.bits, reason: '$formats $k');
          expect(got.flags, want.flags, reason: '$formats $k');
          checked++;
        }
      }
    }
    expect(checked, greaterThan(500));
  });
}
