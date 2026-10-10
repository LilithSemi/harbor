import 'dart:math';

import 'package:rohd/rohd.dart';

import 'fp_lzc.dart';
import 'fp_round_pack.dart';
import 'fp_unpack.dart';
import 'fpu_config.dart';

/// An operation of [HarborDivSqrtRecurrence]. The enum index is the `in_op`
/// encoding.
enum HarborDivSqrtOp {
  /// Floating point divide, `a / b`.
  fpDiv,

  /// Floating point square root of `a`.
  fpSqrt,

  /// Unsigned integer divide.
  divUnsigned,

  /// Signed integer divide.
  divSigned,
}

typedef _State = Map<String, Logic>;

/// A digit recurrence engine for floating point divide and square root and
/// for integer divide.
///
/// Each step is one radix 2 non-restoring step. The partial remainder `R` is
/// in two's complement, and its sign selects the next operation, so a step
/// is one carry chain with no compare and no digit table:
///
///   - divide: `R = 2R + x - D` when `R >= 0`, else `R = 2R + x + D`.
///   - square root: `R = 4R + xx - (4Q + 1)` when `R >= 0`, else
///     `R = 4R + xx + (4Q + 3)`.
///
/// `x` and `xx` are the next dividend or radicand bits, and `Q` is the
/// partial result. Each step shifts in the result bit `R >= 0`. These are the
/// restoring result bits, so only the final remainder needs a correction.
///
/// Radix 4 runs two steps in series in one cycle. On an FPGA this is two
/// carry chains. An SRT radix 4 engine keeps a redundant remainder and a
/// digit table, which doubles the remainder registers and needs a quotient
/// conversion, and its square root table depends on the partial root.
///
/// A floating point op normalizes subnormal operands first. An op needs
/// `p + 3` steps for a divide and `p + 2` for a square root, `p` the
/// significand of its format, and the integer width for an integer divide.
/// [steps] is the largest count.
///
/// Rounding and packing the floating point result run in two stages. An
/// integer divide gives the RISC-V results: a divide by
/// zero gives an all ones quotient and the dividend as the remainder, and
/// the most negative value over minus one gives the dividend and a zero
/// remainder.
///
/// A nonzero [narrowWidth] adds narrow integer ops, such as the RISC-V W
/// forms. With `in_narrow` high, the op uses the low [narrowWidth] bits of
/// the operands, and the quotient and remainder are sign extended.
///
/// The interface is elastic. An op is accepted only in a cycle with
/// `in_valid` and `in_ready` high, and `out_valid` and `out_ready` move a
/// result out. `out_result`, `out_flags`, `out_remainder` and `out_tag` stay
/// stable until the result is taken.
///
/// Kill is per slot. The slots are the registers that can hold an op, in
/// the order of [slotNames], index 0 the youngest. `slot_valid` and
/// `slot_tag` (slot 0 in the low bits) come from registers. A set bit of
/// `kill_mask` drops the op of that slot in the same cycle with no result
/// and no flags, and frees the slot: its `slot_valid` is low in the next
/// cycle and the slot can take a new op. The mask is sampled each cycle,
/// and a bit on an empty slot has no effect. A killed op is never on
/// `out_valid`. `in_ready` does not look at the mask.
///
/// In [HarborFpDivMode.iterative] mode there is one engine with four
/// register stages, which are also the four slots: the raw inputs, the step
/// state, the corrected remainder and the output. Pre processing runs
/// between the first two. The remainder correction and round run between
/// the step state and the post registers, and pack runs between the last
/// two. A floating point op needs only a zero test of the
/// corrected remainder, which has no carry chain. An op
/// runs only the steps of its own format or width, so [latencyOf] depends
/// on the op. An op can wait in the input registers while the one before
/// it runs its steps.
///
/// In [HarborFpDivMode.pipelined] mode the steps are unrolled and a new op
/// can start each cycle. Every op runs [steps] steps, so the latency is
/// [stages] for all ops and results stay in order. The [stages] registers
/// cut the chain of pre processing, steps, correction and round where the
/// largest stage has the least logic. A stall holds every stage. Each
/// stage is a slot, and the last one is the output. A killed op in the last
/// stage frees the pipe in the next cycle, so `in_ready` has no path from
/// `kill_mask`. With zero stages the module has no registers and no slots.
/// The radix has no effect in pipelined mode.
class HarborDivSqrtRecurrence extends Module {
  /// The floating point config, or null for an integer only engine.
  final HarborFpuConfig? fpConfig;

  /// The integer width, or 0 when there is no integer divide.
  final int intWidth;

  /// The narrow integer width, or 0 when there are no narrow ops.
  final int narrowWidth;

  final HarborFpDivMode mode;

  /// 2 or 4. Only used in iterative mode.
  final int radix;

  /// Register stages in pipelined mode.
  final int stages;

  /// Radix 2 steps of the longest op. Radix 4 rounds it up to an even count.
  late final int steps;

  /// Cycles from the accept to `out_valid` for the longest op, with
  /// `out_ready` high.
  int get latency =>
      mode == HarborFpDivMode.iterative ? steps ~/ _stepsPerCycle + 4 : stages;

  /// Cycles from the accept to `out_valid` for [op] in format index [fmt],
  /// or for a narrow integer op when [narrow] is set.
  int latencyOf(HarborDivSqrtOp op, {int fmt = 0, bool narrow = false}) {
    if (mode == HarborFpDivMode.pipelined) {
      return stages;
    }
    return _count(_need(op, fmt, narrow)) ~/ _stepsPerCycle + 4;
  }

  /// Cycles from accept to `out_valid` for an integer divide or remainder
  /// of [width] bits, without needing a built engine. [HarborIntMulDiv]
  /// uses this to size its own latency getters before it builds one.
  static int integerLatencyOf(
    HarborFpDivMode mode,
    int radix,
    int stages,
    int width,
  ) {
    if (mode == HarborFpDivMode.pipelined) {
      return stages;
    }
    final k = radix == 4 ? 2 : 1;
    final steps = (width + k - 1) ~/ k * k;
    return steps ~/ k + 4;
  }

  /// Number of slots for [mode] with [stages] pipelined stages.
  static int slotCountOf(HarborFpDivMode mode, int stages) =>
      mode == HarborFpDivMode.iterative ? 4 : stages;

  /// Slot names, youngest first.
  static List<String> slotNamesOf(HarborFpDivMode mode, int stages) =>
      mode == HarborFpDivMode.iterative
      ? const ['in', 'step', 'post', 'out']
      : [for (var c = 1; c <= stages; c++) 'stage_$c'];

  /// Width of `kill_mask` and `slot_valid`.
  int get slots => slotCountOf(mode, stages);

  List<String> get slotNames => slotNamesOf(mode, stages);

  int get _stepsPerCycle =>
      mode == HarborFpDivMode.iterative && radix == 4 ? 2 : 1;

  // Radix 2 steps an op needs before radix 4 rounds them up.
  int _need(HarborDivSqrtOp op, int fmt, bool narrow) {
    final fp = fpConfig;
    final p = fp == null
        ? 0
        : fp.formats[min(fmt, fp.formats.length - 1)].mantissaWidth + 1;
    return switch (op) {
      HarborDivSqrtOp.fpDiv => p + 3,
      HarborDivSqrtOp.fpSqrt => p + 2,
      _ => narrow ? narrowWidth : intWidth,
    };
  }

  // Steps an op runs. Pipelined mode runs every op through all steps.
  int _count(int need) {
    if (mode == HarborFpDivMode.pipelined) {
      return steps;
    }
    final k = _stepsPerCycle;
    return (need + k - 1) ~/ k * k;
  }

  Logic get inReady => output('in_ready');
  Logic get outValid => output('out_valid');

  /// The packed floating point result, right aligned, or the quotient.
  Logic get outResult => output('out_result');

  /// `{NV, DZ, OF, UF, NX}`, NX at bit 0. Only with floating point ops.
  Logic get outFlags => output('out_flags');

  /// The integer remainder. Only with integer divide.
  Logic get outRemainder => output('out_remainder');

  /// The tag of the op, when the module has a tag.
  Logic get outTag => output('out_tag');

  /// One bit per slot, high when the slot holds an op. Only with slots.
  Logic get slotValid => output('slot_valid');

  /// The tag of each slot, slot 0 in the low bits. Only with slots and a
  /// tag.
  Logic get slotTag => output('slot_tag');

  /// The floating point divide and square root engine for [config]. It uses
  /// [HarborFpuConfig.divMode], [HarborFpuConfig.divRadix] and
  /// [HarborFpuConfig.divStages], and builds only the ops in
  /// [HarborFpuConfig.ops]. A nonzero [intWidth] adds integer divide to the
  /// same engine.
  ///
  /// [inOp] is a [HarborDivSqrtOp] index. [inA] and [inB] are right aligned.
  /// [inNarrow] is needed when [narrowWidth] is not zero. [killMask] has
  /// [slotCountOf] bits, and is null only when there are no slots.
  HarborDivSqrtRecurrence(
    HarborFpuConfig config, {
    required Logic clk,
    required Logic reset,
    required Logic? killMask,
    required Logic inValid,
    required Logic inOp,
    required Logic inFmt,
    required Logic inRm,
    required Logic inA,
    required Logic inB,
    Logic? inNarrow,
    Logic? inTag,
    required Logic outReady,
    int intWidth = 0,
    int narrowWidth = 0,
    String name = 'div_sqrt',
  }) : this._(
         config,
         intWidth,
         narrowWidth,
         config.divMode,
         config.divRadix,
         config.divStages,
         clk: clk,
         reset: reset,
         killMask: killMask,
         inValid: inValid,
         inOp: inOp,
         inFmt: inFmt,
         inRm: inRm,
         inA: inA,
         inB: inB,
         inNarrow: inNarrow,
         inTag: inTag,
         outReady: outReady,
         name: name,
       );

  /// An integer divide engine of [width] bits. [inOp] is a [HarborDivSqrtOp]
  /// index, `divUnsigned` or `divSigned`.
  HarborDivSqrtRecurrence.integer(
    int width,
    HarborFpDivMode mode,
    int radix,
    int stages, {
    required Logic clk,
    required Logic reset,
    required Logic? killMask,
    required Logic inValid,
    required Logic inOp,
    required Logic inA,
    required Logic inB,
    Logic? inNarrow,
    Logic? inTag,
    required Logic outReady,
    int narrowWidth = 0,
    String name = 'int_div',
  }) : this._(
         null,
         width,
         narrowWidth,
         mode,
         radix,
         stages,
         clk: clk,
         reset: reset,
         killMask: killMask,
         inValid: inValid,
         inOp: inOp,
         inFmt: null,
         inRm: null,
         inA: inA,
         inB: inB,
         inNarrow: inNarrow,
         inTag: inTag,
         outReady: outReady,
         name: name,
       );

  HarborDivSqrtRecurrence._(
    this.fpConfig,
    this.intWidth,
    this.narrowWidth,
    this.mode,
    this.radix,
    this.stages, {
    required Logic clk,
    required Logic reset,
    required Logic? killMask,
    required Logic inValid,
    required Logic inOp,
    required Logic? inFmt,
    required Logic? inRm,
    required Logic inA,
    required Logic inB,
    required Logic? inNarrow,
    required Logic? inTag,
    required Logic outReady,
    required String name,
  }) : super(
         name: name,
         definitionName: _definitionName(
           fpConfig,
           intWidth,
           narrowWidth,
           mode,
           radix,
           stages,
         ),
       ) {
    final fp = fpConfig;
    final hasDiv = fp != null && fp.ops.contains(HarborFpOp.div);
    final hasSqrt = fp != null && fp.ops.contains(HarborFpOp.sqrt);
    final hasFp = hasDiv || hasSqrt;
    final hasInt = intWidth > 0;
    final hasNarrow = narrowWidth > 0;
    if (!hasFp && !hasInt) {
      throw ArgumentError('no div, sqrt or integer divide to build');
    }
    if (radix != 2 && radix != 4) {
      throw ArgumentError.value(radix, 'radix', 'must be 2 or 4');
    }
    if (hasNarrow && narrowWidth >= intWidth) {
      throw ArgumentError.value(
        narrowWidth,
        'narrowWidth',
        'must be less than the integer width',
      );
    }

    final w = intWidth;
    final nw = narrowWidth;
    final m = hasFp ? harborFpMaxMantissaWidth(fp) : 0;
    final p = m + 1;
    final ew = hasFp ? harborFpMaxExponentWidth(fp) + 3 : 0;
    final k = _stepsPerCycle;
    final need = [if (hasDiv) p + 3, if (hasSqrt) p + 2, if (hasInt) w];
    steps = (need.reduce(max) + k - 1) ~/ k * k;
    final n = steps;
    // Pre processing, every step, the correction and the round.
    final units = n + 3;
    if (mode == HarborFpDivMode.pipelined && (stages < 0 || stages > units)) {
      throw ArgumentError.value(stages, 'stages', 'must be 0 to $units');
    }
    final dw = [if (hasDiv) p + 1, if (hasInt) w, 0].reduce(max);
    final rw = [
      if (hasDiv) p + 3,
      if (hasSqrt) n + 4,
      if (hasInt) w + 2,
    ].reduce(max);
    final xw = [if (hasSqrt) (p + 2) ~/ 2 * 2, if (hasInt) n, 0].reduce(max);
    final inW = max(hasFp ? fp.widest.width : 0, w);
    final tagW = inTag?.width ?? 0;

    final nSlots = slots;
    if (nSlots > 0 && killMask?.width != nSlots) {
      throw ArgumentError.value(
        killMask?.width,
        'killMask.width',
        'must be $nSlots',
      );
    }
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final km = nSlots > 0
        ? addInput('kill_mask', killMask!, width: nSlots)
        : null;
    inValid = addInput('in_valid', inValid);
    inOp = addInput('in_op', inOp, width: 2);
    if (hasFp) {
      inFmt = addInput('in_fmt', inFmt!, width: fp.fmtWidth);
      inRm = addInput('in_rm', inRm!, width: 3);
    }
    inA = addInput('in_a', inA, width: inW);
    inB = addInput('in_b', inB, width: inW);
    if (hasNarrow) {
      if (inNarrow == null) {
        throw ArgumentError('inNarrow is needed with a narrow width');
      }
      inNarrow = addInput('in_narrow', inNarrow);
    }
    if (tagW > 0) {
      inTag = addInput('in_tag', inTag!, width: tagW);
    }
    outReady = addInput('out_ready', outReady);
    addOutput('in_ready');
    addOutput('out_valid');
    addOutput('out_result', width: inW);
    if (hasFp) {
      addOutput('out_flags', width: 5);
    }
    if (hasInt) {
      addOutput('out_remainder', width: w);
    }
    if (tagW > 0) {
      addOutput('out_tag', width: tagW);
    }
    if (nSlots > 0) {
      addOutput('slot_valid', width: nSlots);
      if (tagW > 0) {
        addOutput('slot_tag', width: nSlots * tagW);
      }
    }
    void slotsOut(List<Logic> valids, List<Logic> Function() tags) {
      slotValid <= valids.rswizzle();
      if (tagW > 0) {
        slotTag <= tags().rswizzle();
      }
    }

    Logic isOp(Logic op, HarborDivSqrtOp o) => op.eq(Const(o.index, width: 2));
    Logic isInt(Logic op) =>
        isOp(op, HarborDivSqrtOp.divUnsigned) |
        isOp(op, HarborDivSqrtOp.divSigned);
    Logic isSqrt(_State s) =>
        hasSqrt ? isOp(s['op']!, HarborDivSqrtOp.fpSqrt) : Const(0);
    Logic zero(int width) => Const(0, width: width);

    // Puts [v] at the top of a [width] bit field.
    Logic top(Logic v, int width) =>
        width > v.width ? [v, zero(width - v.width)].swizzle() : v;

    // Selects a value for the op of [s]. [fpDiv], [fpSqrt] and [integer] map
    // a format index or a narrow flag to the value.
    Logic perOp(
      _State s,
      Logic Function(int fmt) fpDiv,
      Logic Function(int fmt) fpSqrt,
      Logic Function(bool narrow) integer,
    ) {
      Logic? fpv;
      if (hasFp) {
        Logic sel(Logic Function(int) f) => harborFpSelect(s['fmt']!, [
          for (var i = 0; i < fp.formats.length; i++) f(i),
        ]);
        final d = hasDiv ? sel(fpDiv) : null;
        final q = hasSqrt ? sel(fpSqrt) : null;
        fpv = d == null ? q : (q == null ? d : mux(isSqrt(s), q, d));
      }
      Logic? iv;
      if (hasInt) {
        iv = hasNarrow
            ? mux(s['narrow']!, integer(true), integer(false))
            : integer(false);
      }
      if (fpv == null) {
        return iv!;
      }
      return iv == null ? fpv : mux(isInt(s['op']!), iv, fpv);
    }

    int count(HarborDivSqrtOp op, {int fmt = 0, bool narrow = false}) =>
        _count(_need(op, fmt, narrow));

    // Builds the loaded state from the raw inputs. Loop signals change each
    // step, the others ride along.
    _State pre(_State src) {
      final op = src['op']!;
      final a = src['a']!;
      final b = src['b']!;
      final s = <String, Logic>{'op': op};
      if (tagW > 0) {
        s['tag'] = src['tag']!;
      }
      final inits = <(Logic, Logic, Logic?, Logic?)>[];
      if (hasFp) {
        final fmt = src['fmt']!;
        final isSqrtOp = hasSqrt ? isOp(op, HarborDivSqrtOp.fpSqrt) : null;
        final isDivOp = hasDiv ? isOp(op, HarborDivSqrtOp.fpDiv) : null;
        final opW = fp.widest.width;
        final ua = HarborFpUnpack(
          fp,
          fmt: fmt,
          operand: a.getRange(0, opW),
          name: 'unpack_a',
        );
        final lzA = harborFpLeadingZeros(ua.significand).named('lz_a');
        final sigA = (ua.significand << lzA).named('sig_a');
        final expA = ua.exponent.signExtend(ew) - lzA.zeroExtend(ew);

        final nan = <Logic>[];
        final inf = <Logic>[];
        final zer = <Logic>[];
        final nv = <Logic>[];
        final dz = <Logic>[];
        final sign = <Logic>[];
        final exp = <Logic>[];
        if (hasDiv) {
          final ub = HarborFpUnpack(
            fp,
            fmt: fmt,
            operand: b.getRange(0, opW),
            name: 'unpack_b',
          );
          final lzB = harborFpLeadingZeros(ub.significand).named('lz_b');
          final sigB = (ub.significand << lzB).named('sig_b');
          final expB = ub.exponent.signExtend(ew) - lzB.zeroExtend(ew);
          final invalid = (ua.isInf & ub.isInf) | (ua.isZero & ub.isZero);
          final fNan = ua.isNan | ub.isNan | invalid;
          final fInf = ~fNan & (ua.isInf | ub.isZero);
          nan.add(fNan);
          inf.add(fInf);
          zer.add(~fNan & ~fInf & (ua.isZero | ub.isInf));
          nv.add(ua.isSnan | ub.isSnan | invalid);
          dz.add(~fNan & ~ua.isInf & ub.isZero);
          sign.add(ua.sign ^ ub.sign);
          exp.add(expA - expB);
          inits.add((
            isDivOp!,
            sigA.zeroExtend(rw),
            [sigB, Const(0)].swizzle().zeroExtend(dw),
            xw > 0 ? zero(xw) : null,
          ));
        }
        if (hasSqrt) {
          final negative = ua.sign & ~ua.isZero & ~ua.isNan;
          nan.add(ua.isNan | negative);
          inf.add(~ua.isNan & ~ua.sign & ua.isInf);
          zer.add(ua.isZero);
          nv.add(ua.isSnan | negative);
          dz.add(Const(0));
          sign.add(ua.sign);
          exp.add([expA[ew - 1], expA.getRange(1)].swizzle());
          // An odd exponent puts one more radicand bit above the point.
          final rad = mux(
            expA[0],
            [sigA, Const(0)].swizzle(),
            sigA.zeroExtend(p + 1),
          );
          inits.add((
            isSqrtOp!,
            zero(rw),
            dw > 0 ? zero(dw) : null,
            top(rad, xw),
          ));
        }
        Logic pick(List<Logic> v) =>
            v.length == 1 ? v.first : mux(isSqrtOp!, v[1], v[0]);
        s['fmt'] = fmt;
        s['rm'] = src['rm']!;
        s['force_nan'] = pick(nan);
        s['force_inf'] = pick(inf);
        s['force_zero'] = pick(zer);
        s['nv'] = pick(nv);
        s['dz'] = pick(dz);
        s['sign'] = pick(sign);
        s['exp'] = pick(exp);
      }
      if (hasInt) {
        final signed = isOp(op, HarborDivSqrtOp.divSigned);
        var aw = a.getRange(0, w);
        var bw = b.getRange(0, w);
        // A narrow operand is extended to full width, so one negate serves
        // both widths.
        if (hasNarrow) {
          Logic ext(Logic v) => mux(
            signed,
            v.getRange(0, nw).signExtend(w),
            v.getRange(0, nw).zeroExtend(w),
          );
          aw = mux(src['narrow']!, ext(aw), aw);
          bw = mux(src['narrow']!, ext(bw), bw);
          s['narrow'] = src['narrow']!;
        }
        final sa = signed & aw[w - 1];
        final sb = signed & bw[w - 1];
        final absA = mux(sa, ~aw + 1, aw);
        final absB = mux(sb, ~bw + 1, bw);
        final divZero = ~bw.or();
        s['q_neg'] = (sa ^ sb) & ~divZero;
        s['r_neg'] = sa;
        final cWide = count(HarborDivSqrtOp.divUnsigned);
        final cNarrow = count(HarborDivSqrtOp.divUnsigned, narrow: true);
        var dividend = top(absA.zeroExtend(cWide), xw);
        if (hasNarrow && cNarrow != cWide) {
          final cn = cNarrow;
          dividend = mux(
            src['narrow']!,
            top(absA.getRange(0, nw).zeroExtend(cn), xw),
            dividend,
          );
        }
        inits.add((
          hasFp ? isInt(op) : Const(1),
          zero(rw),
          absB.zeroExtend(dw),
          dividend,
        ));
      }
      var (_, r0, d0, x0) = inits.first;
      for (final (sel, r, d, x) in inits.skip(1)) {
        r0 = mux(sel, r, r0);
        if (d != null) {
          d0 = mux(sel, d, d0!);
        }
        if (x != null) {
          x0 = mux(sel, x, x0!);
        }
      }
      s['r'] = r0;
      s['q'] = zero(n);
      if (d0 != null) {
        s['d'] = d0;
      }
      if (x0 != null) {
        s['x'] = x0;
      }
      return s;
    }

    // One radix 2 step.
    _State step(_State s, int i) {
      final r = s['r']!;
      final q = s['q']!;
      final x = s['x'];
      final neg = r[rw - 1];
      final sqrt = isSqrt(s);
      final out = Map.of(s);

      Logic? r2;
      Logic? term;
      if (hasDiv || hasInt) {
        final d = s['d']!.zeroExtend(rw);
        r2 = [
          r.getRange(0, rw - 1),
          x == null ? Const(0) : x[xw - 1],
        ].swizzle();
        term = mux(neg, d, ~d);
      }
      if (hasSqrt) {
        final qz = q.zeroExtend(rw - 2);
        final r4 = [r.getRange(0, rw - 2), x!.getRange(xw - 2)].swizzle();
        final t4 = [mux(neg, qz, ~qz), Const(3, width: 2)].swizzle();
        r2 = r2 == null ? r4 : mux(sqrt, r4, r2);
        term = term == null ? t4 : mux(sqrt, t4, term);
      }
      final cin = ~sqrt & ~neg;
      final sum = ([r2!, Const(1)].swizzle() + [term!, cin].swizzle())
          .getRange(1)
          .named('r_step$i');
      out['r'] = sum;
      out['q'] = [q.getRange(0, n - 1), ~sum[rw - 1]].swizzle();
      if (x != null) {
        final x1 = [x.getRange(0, xw - 1), Const(0)].swizzle();
        out['x'] = hasSqrt
            ? mux(sqrt, [x.getRange(0, xw - 2), zero(2)].swizzle(), x1)
            : x1;
      }
      return out;
    }

    // Corrects the remainder, places the result bits, negates the quotient
    // and runs the first half of the round.
    _State postA(_State s) {
      final r = s['r']!;
      final q = s['q']!;
      final neg = r[rw - 1];
      final sqrt = isSqrt(s);
      Logic? fix;
      if (hasDiv || hasInt) {
        fix = s['d']!.zeroExtend(rw);
      }
      if (hasSqrt) {
        final f2 = [q, Const(1)].swizzle().zeroExtend(rw);
        fix = fix == null ? f2 : mux(sqrt, f2, fix);
      }
      final add = mux(neg, fix!, zero(rw));
      final out = <String, Logic>{'op': s['op']!};
      if (hasInt) {
        out['rem'] = (r + add).named('remainder');
      }
      if (tagW > 0) {
        out['tag'] = s['tag']!;
      }
      if (hasFp) {
        // An op with fewer steps than [n] has its result bits lower in q.
        Logic at(int c) =>
            c == n ? q : [q.getRange(0, c), zero(n - c)].swizzle();
        final qa = mode == HarborFpDivMode.pipelined
            ? q
            : perOp(
                s,
                (f) => at(count(HarborDivSqrtOp.fpDiv, fmt: f)),
                (f) => at(count(HarborDivSqrtOp.fpSqrt, fmt: f)),
                (_) => q,
              );
        Logic below(int bits) =>
            bits > 0 ? qa.getRange(0, bits).or() : Const(0);
        // A divide result below one has its leading bit one place lower.
        final low = hasDiv ? ~sqrt & ~qa[n - 1] : Const(0);
        final sig = hasDiv
            ? mux(low, qa.getRange(n - p - 3, n - 1), qa.getRange(n - p - 2))
            : qa.getRange(n - p - 2);
        final qSticky = hasDiv
            ? mux(low, below(n - p - 3), below(n - p - 2))
            : below(n - p - 2);
        // r + add is zero when each bit of r ^ add equals the carry into it,
        // and that carry is r | add of the bit below.
        final carries = [(r | add).getRange(0, rw - 1), Const(0)].swizzle();
        final remNz = (r ^ add ^ carries).or().named('rem_nz');
        final round = HarborFpRound(
          fp,
          fmt: s['fmt']!,
          rm: s['rm']!,
          sign: s['sign']!,
          exponent: s['exp']!,
          exponentDec: hasDiv ? low : null,
          significand: sig,
          sticky: qSticky | remNz,
          forceNan: s['force_nan']!,
          forceInf: s['force_inf']!,
          forceZero: s['force_zero']!,
          exponentWidth: ew,
        );
        for (final e in round.mid.entries) {
          out['rp_${e.key}'] = e.value;
        }
        out['nv'] = s['nv']!;
        out['dz'] = s['dz']!;
      }
      if (hasInt) {
        final qi = q.getRange(0, w);
        out['quot'] = mux(s['q_neg']!, ~qi + 1, qi);
        out['r_neg'] = s['r_neg']!;
        if (hasNarrow) {
          out['narrow'] = s['narrow']!;
        }
      }
      return out;
    }

    // Packs the rounded result, or negates the remainder.
    _State postB(_State s) {
      final out = <String, Logic>{};
      if (tagW > 0) {
        out['tag'] = s['tag']!;
      }
      Logic? fpResult;
      if (hasFp) {
        final pack = HarborFpPack(fp, {
          for (final e in s.entries)
            if (e.key.startsWith('rp_')) e.key.substring(3): e.value,
        });
        fpResult = pack.result.zeroExtend(inW);
        out['flags'] =
            pack.flags | [s['nv']!, s['dz']!, Const(0, width: 3)].swizzle();
      }
      if (hasInt) {
        final ri = s['rem']!.getRange(0, w);
        var quot = s['quot']!;
        var remv = mux(s['r_neg']!, ~ri + 1, ri);
        if (hasNarrow) {
          Logic ext(Logic v) => v.getRange(0, nw).signExtend(w);
          quot = mux(s['narrow']!, ext(quot), quot);
          remv = mux(s['narrow']!, ext(remv), remv);
        }
        out['remainder'] = remv;
        if (fpResult == null) {
          out['result'] = quot.zeroExtend(inW);
        } else {
          final intOp = isInt(s['op']!);
          out['result'] = mux(intOp, quot.zeroExtend(inW), fpResult);
          out['flags'] = mux(intOp, zero(5), out['flags']!);
        }
      } else {
        out['result'] = fpResult!;
      }
      return out;
    }

    _State drive(_State o) {
      outResult <= o['result']!;
      if (hasFp) {
        outFlags <= o['flags']!;
      }
      if (hasInt) {
        outRemainder <= o['remainder']!;
      }
      if (tagW > 0) {
        outTag <= o['tag']!;
      }
      return o;
    }

    final raw = <String, Logic>{
      'op': inOp,
      'a': inA,
      'b': inB,
      if (hasFp) 'fmt': inFmt!,
      if (hasFp) 'rm': inRm!,
      if (hasNarrow) 'narrow': inNarrow!,
      if (tagW > 0) 'tag': inTag!,
    };

    if (mode == HarborFpDivMode.iterative) {
      final cw = (n ~/ k).bitLength;
      final inV = Logic(name: 'in_valid_q');
      final stV = Logic(name: 'step_valid_q');
      final paV = Logic(name: 'post_valid_q');
      final outV = Logic(name: 'out_valid_q');
      final left = Logic(name: 'left', width: cw);

      final inL = (inV & ~km![0]).named('in_live');
      final stL = (stV & ~km[1]).named('step_live');
      final paL = (paV & ~km[2]).named('post_live');
      final outL = (outV & ~km[3]).named('out_live');
      final outFree = ~outL | outReady;
      final paFree = ~paL | outFree;
      final stepping = (stL & left.or()).named('stepping');
      final stMove = (stL & ~left.or() & paFree).named('step_move');
      final inMove = (inL & (~stL | stMove)).named('in_move');
      final paMove = (paL & outFree).named('post_move');
      final accept = (inValid & ~inV).named('accept');

      final held = {
        for (final e in raw.entries)
          e.key: flop(clk, e.value, en: accept).named('${e.key}_in'),
      };
      final loaded = pre(held);
      final regs = {
        for (final e in loaded.entries)
          e.key: Logic(name: '${e.key}_q', width: e.value.width),
      };
      var next = regs;
      for (var i = 0; i < k; i++) {
        next = step(next, i);
      }
      const loop = {'r', 'q', 'x'};
      for (final e in loaded.entries) {
        final key = e.key;
        if (loop.contains(key)) {
          regs[key]! <=
              flop(
                clk,
                mux(inMove, e.value, next[key]!),
                en: inMove | stepping,
              );
        } else {
          regs[key]! <= flop(clk, e.value, en: inMove);
        }
      }
      final iters = perOp(
        held,
        (f) => Const(count(HarborDivSqrtOp.fpDiv, fmt: f) ~/ k, width: cw),
        (f) => Const(count(HarborDivSqrtOp.fpSqrt, fmt: f) ~/ k, width: cw),
        (narrow) => Const(
          count(HarborDivSqrtOp.divUnsigned, narrow: narrow) ~/ k,
          width: cw,
        ),
      );
      left <=
          flop(
            clk,
            mux(inMove, iters, left - 1),
            en: inMove | stepping,
            reset: reset,
          );

      final corrected = {
        for (final e in postA(regs).entries)
          e.key: flop(clk, e.value, en: stMove).named('${e.key}_pa'),
      };
      final last = drive({
        for (final e in postB(corrected).entries)
          e.key: flop(clk, e.value, en: paMove),
      });

      Logic validFlop(Logic set, Logic stay) =>
          flop(clk, set | stay, reset: reset);
      inV <= validFlop(accept, inL & ~inMove);
      stV <= validFlop(inMove, stL & ~stMove);
      paV <= validFlop(stMove, paL & ~paMove);
      outV <= validFlop(paMove, outL & ~outReady);
      inReady <= ~inV;
      outValid <= outL;
      slotsOut([
        inV,
        stV,
        paV,
        outV,
      ], () => [held['tag']!, regs['tag']!, corrected['tag']!, last['tag']!]);
      return;
    }

    // Pipelined: the cuts split the units so the largest stage weight is
    // the least. Pre processing and each half of the round weigh about two
    // steps when there is floating point.
    final weights = [
      hasFp ? 2 : 1,
      for (var i = 0; i < n; i++) 1,
      hasFp ? 2 : 1,
      hasFp ? 2 : 1,
    ];
    final ends = _cuts(weights, stages);
    _State unit(_State s, int u) => switch (u) {
      0 => pre(s),
      _ when u <= n => step(s, u - 1),
      _ when u == n + 1 => postA(s),
      _ => postB(s),
    };
    // The stall enable looks at the last valid before the kill, so in_ready
    // has no path from kill_mask.
    final en = Logic(name: 'stage_en');
    var live = inValid;
    var valid = inValid;
    var state = raw;
    var done = 0;
    final valids = <Logic>[];
    final tags = <Logic>[];
    for (var c = 1; c <= stages; c++) {
      for (; done < ends[c - 1]; done++) {
        state = unit(state, done);
      }
      final v = Logic(name: 'valid_$c');
      final vl = (v & ~km![c - 1]).named('live_$c');
      v <= flop(clk, mux(en, live, vl), reset: reset);
      valid = v;
      live = vl;
      valids.add(v);
      state = {
        for (final e in state.entries)
          e.key: flop(clk, e.value, en: en).named('${e.key}_s$c'),
      };
      if (tagW > 0) {
        tags.add(state['tag']!);
      }
    }
    if (stages == 0) {
      for (; done < units; done++) {
        state = unit(state, done);
      }
      en <= outReady;
    } else {
      en <= ~valid | outReady;
      slotsOut(valids, () => tags);
    }
    drive(state);
    inReady <= en;
    outValid <= live;
  }

  /// The unit count after each cut, for [stages] cuts over [weights], so the
  /// heaviest stage is as light as it can be. Every stage gets one unit or
  /// more, and the last cut is after the last unit.
  static List<int> _cuts(List<int> weights, int stages) {
    final u = weights.length;
    if (stages == 0) {
      return const [];
    }
    final sum = [0];
    for (final x in weights) {
      sum.add(sum.last + x);
    }
    const inf = 1 << 40;
    // best[s][i]: the least heaviest stage for the first i units in s stages.
    final best = List.generate(stages + 1, (_) => List.filled(u + 1, inf));
    final from = List.generate(stages + 1, (_) => List.filled(u + 1, 0));
    best[0][0] = 0;
    for (var s = 1; s <= stages; s++) {
      for (var i = s; i <= u; i++) {
        for (var j = s - 1; j < i; j++) {
          final cost = max(best[s - 1][j], sum[i] - sum[j]);
          if (cost < best[s][i]) {
            best[s][i] = cost;
            from[s][i] = j;
          }
        }
      }
    }
    final ends = List.filled(stages, 0);
    var i = u;
    for (var s = stages; s >= 1; s--) {
      ends[s - 1] = i;
      i = from[s][i];
    }
    return ends;
  }

  static String _definitionName(
    HarborFpuConfig? fp,
    int intWidth,
    int narrowWidth,
    HarborFpDivMode mode,
    int radix,
    int stages,
  ) {
    final parts = [
      'HarborDivSqrtRecurrence',
      if (mode == HarborFpDivMode.iterative) 'R$radix' else 'S$stages',
      if (fp != null) ...[
        for (final f in fp.formats) 'E${f.exponentWidth}M${f.mantissaWidth}',
        if (fp.ops.contains(HarborFpOp.div)) 'Div',
        if (fp.ops.contains(HarborFpOp.sqrt)) 'Sqrt',
        if (fp.ftz) 'Ftz',
      ],
      if (intWidth > 0) 'I$intWidth',
      if (narrowWidth > 0) 'N$narrowWidth',
    ];
    return parts.join('_');
  }
}
