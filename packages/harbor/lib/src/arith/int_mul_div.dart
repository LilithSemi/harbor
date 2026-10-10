import 'dart:math';

import 'package:rohd/rohd.dart';

import 'fpu_config.dart';
import 'recurrence.dart';

/// Multiply iteration strategy for [HarborIntMulDiv].
enum HarborIntMulMode {
  /// A new multiply can start every cycle. `a * b` is written as a plain
  /// operator so a DSP block can infer it. Results come out in order.
  pipelined,

  /// One result at a time, `mulRadix` bits of shift and add per cycle.
  iterative,
}

/// An integer multiply or divide operation. The enum index is the `in_op`
/// encoding. The `w` forms are RISC-V RV64 word ops and need `width == 64`.
enum HarborIntOp {
  /// Signed times signed, low word. RV32M MUL.
  mul,

  /// Signed times signed, high word. RV32M MULH.
  mulh,

  /// Signed times unsigned, high word. RV32M MULHSU.
  mulhsu,

  /// Unsigned times unsigned, high word. RV32M MULHU.
  mulhu,

  /// Signed times signed, low 32 bits sign extended. RV64M MULW.
  mulw,

  /// Signed quotient. RV32M DIV.
  div,

  /// Unsigned quotient. RV32M DIVU.
  divu,

  /// Signed remainder. RV32M REM.
  rem,

  /// Unsigned remainder. RV32M REMU.
  remu,

  /// Signed quotient, low 32 bits sign extended. RV64M DIVW.
  divw,

  /// Unsigned quotient, low 32 bits sign extended. RV64M DIVUW.
  divuw,

  /// Signed remainder, low 32 bits sign extended. RV64M REMW.
  remw,

  /// Unsigned remainder, low 32 bits sign extended. RV64M REMUW.
  remuw,
}

/// Width of an `in_op` port that holds a [HarborIntOp] index.
final int harborIntOpWidth = (HarborIntOp.values.length - 1).bitLength;

Logic _isOp(Logic op, HarborIntOp o) =>
    op.eq(Const(o.index, width: harborIntOpWidth));

/// Converts [a] and [b] to magnitudes for [op], and the sign of the signed
/// product. mulhu has no signed operand. mulhsu's `b` is unsigned.
(Logic absA, Logic absB, Logic sign) _mulMagnitudes(
  int width,
  Logic op,
  Logic a,
  Logic b,
) {
  final signA = (~_isOp(op, HarborIntOp.mulhu) & a[width - 1]).named(
    'mul_sign_a',
  );
  final signB =
      (~_isOp(op, HarborIntOp.mulhsu) &
              ~_isOp(op, HarborIntOp.mulhu) &
              b[width - 1])
          .named('mul_sign_b');
  final absA = mux(signA, ~a + 1, a).named('mul_abs_a');
  final absB = mux(signB, ~b + 1, b).named('mul_abs_b');
  return (absA, absB, signA ^ signB);
}

/// The final result for [op] from the signed [prod], a `2 * width` bit
/// magnitude product corrected by [sign]. The low word of a truncated
/// product does not depend on signedness. mul and mulw share the low word
/// path. Only the sign of the full product matters for mulh, mulhsu and
/// mulhu.
Logic _mulResult(int width, Logic prod, Logic sign, Logic op) {
  final signed = mux(sign, ~prod + 1, prod).named('mul_signed_prod');
  final high =
      _isOp(op, HarborIntOp.mulh) |
      _isOp(op, HarborIntOp.mulhsu) |
      _isOp(op, HarborIntOp.mulhu);
  final low = signed.getRange(0, width);
  final lowWord = width == 64
      ? mux(
          _isOp(op, HarborIntOp.mulw),
          low.getRange(0, 32).signExtend(width),
          low,
        )
      : low;
  return mux(high, signed.getRange(width, 2 * width), lowWord);
}

/// The unit count after each cut, for [stages] cuts over [weights], so the
/// heaviest stage is as light as it can be. Every stage gets one unit or
/// more. Copied from the same algorithm in `HarborDivSqrtRecurrence`.
List<int> _cuts(List<int> weights, int stages) {
  final u = weights.length;
  final sum = [0];
  for (final x in weights) {
    sum.add(sum.last + x);
  }
  const inf = 1 << 40;
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

typedef _State = Map<String, Logic>;

/// The seq of the oldest valid slot in [seqs], ordered youngest first, and
/// whether any slot is valid.
(Logic valid, Logic seq) _oldest(List<Logic> valids, List<Logic> seqs) {
  var seq = seqs.first;
  for (var i = 1; i < seqs.length; i++) {
    seq = mux(valids[i], seqs[i], seq);
  }
  return (valids.reduce((a, b) => a | b), seq);
}

/// The RISC-V M extension integer multiply and divide unit, and the GPU
/// integer lanes.
///
/// Multiply and divide are independent paths fed by one input port and
/// drained by one output port. A busy divide does not block a multiply:
/// each path has its own readiness, decoded from `in_op`, and a divide
/// going slow only stalls its own path.
///
/// Results leave in the order their ops were accepted, whichever path they
/// ran on. Each op gets a sequence number when it is accepted. Each path
/// keeps its ops in order, so the output takes the result of the path whose
/// oldest op is older. The sequence numbers are internal and wide enough
/// for every op in flight. `in_ready` is low in the rare case that an op
/// held back by kills would wrap.
///
/// Multiply has two modes. [HarborIntMulMode.pipelined] computes `a * b` as
/// a plain operator on magnitude operands, so ECP5 MULT18X18D and Xilinx
/// DSP48 can infer it, and [mulStages] registers cut the pre, multiply and
/// post stages. A stall holds every stage. [HarborIntMulMode.iterative] is
/// a shift and add multiplier, `mulRadix` bits a cycle, one op at a time.
/// mulh, mulhsu and mulhu read the full `2 * width` product. mul and mulw
/// read the low word, which does not depend on signedness, so both modes
/// share one magnitude-and-correct datapath for every op.
///
/// Divide instantiates [HarborDivSqrtRecurrence.integer] and reads the
/// quotient or remainder it needs from `out_result` and `out_remainder`.
/// Which one it wants travels as an extra bit in the tag given to the
/// recurrence, so the recurrence does not need to know about it.
///
/// An op is accepted only in a cycle with `in_valid` and `in_ready` high.
///
/// Kill is per slot. The slots are the multiply slots and then the divide
/// slots ([slotNames]). The multiply slots are the stage registers
/// (`mul_1` to `mul_S`) in pipelined mode, or the one engine (`mul`) in
/// iterative mode. The divide slots are the recurrence slots with a `div_`
/// prefix. In each path index order is age order, the lowest index the
/// youngest. Ops on different paths have no fixed order, so a core compares
/// `slot_tag`. `slot_valid` has one bit per slot and `slot_tag` has the tag
/// of each slot, slot 0 in the low bits. Both come from registers. A set bit
/// of `kill_mask` drops the op of that slot in the same cycle with no result
/// and frees the slot, so a killed iterative engine can take a new op in
/// the next cycle. The mask is sampled each cycle, and a bit on an empty
/// slot has no effect. A killed op is never on `out_valid`. `in_ready` does
/// not look at the mask. An in-order core can drive every bit from one
/// flush with `harborKillAll`.
///
/// With [shareRecurrence], this unit builds no recurrence of its own.
/// Instead it exposes the recurrence's own ports, named `shared_*`, so a
/// parent can wire one engine to both this unit and an FP divide path.
/// `busy` is high from the cycle after this unit issues into the shared
/// engine until that op leaves through this unit's output or is killed, so
/// at most one divide of this unit is in the engine. The parent must:
///   - drive `shared_in_ready` high only when the engine is ready and holds
///     no op of the other side, and let the other side issue only while
///     `busy` is low. Then every op in the engine is this unit's op while
///     `busy` is high.
///   - wire the engine's `slot_valid` to `shared_slot_valid`, and OR
///     `shared_kill_mask` into the engine's `kill_mask`.
/// This unit forwards the engine slots as its divide slots while `busy` is
/// high, and drives `shared_kill_mask` from its own divide mask bits.
///
/// Two more rules for the parent, both about ownership of the shared engine:
///   - A side must not set kill bits on the engine's slots for an op it
///     does not own. This unit already keeps that rule: `shared_kill_mask`
///     is its own divide mask bits ANDed with `busy`, so it is all zero
///     whenever this unit holds no op in the engine. The FP divide path
///     must gate its own kill bits the same way, by its own ownership, not
///     by this unit's `busy`.
///   - When both sides want to issue into the engine on the same cycle
///     while `busy` is low, only one can actually land, since the engine
///     takes one input. This unit has no visibility into the other side's
///     request, so it cannot pick a winner. Picking one, and only routing
///     that side's op onto the engine's real input that cycle, is the
///     parent's job. A fixed priority (for example, the FP path always
///     wins a tie) is enough. This unit's own `in_ready` for divide already
///     stays low on the cycle it loses, so it simply tries again the next
///     cycle.
///
/// The engine's real `in_valid` must come from that same grant, not a plain
/// forward of `shared_in_valid`: `shared_in_valid` is a standing request,
/// still high on a cycle this unit was not actually granted, so wiring it
/// straight to the engine lets the engine accept a ghost copy of this
/// unit's request on a cycle the other side holds the engine. The engine's
/// real `out_ready` must come from whichever side currently owns the op in
/// the engine (checked the same way as the kill above, `shared_slot_valid`
/// against each side's ownership), not from one side alone, or the owner
/// still waiting to drain can leave the engine stalled.
///
/// `busy` clears on a drain or on a kill of the slot holding this unit's
/// op, wherever in the engine that op currently sits: the kill check is
/// `shared_kill_mask & shared_slot_valid`, one bit per engine slot, not a
/// fixed slot index, so it still finds the op after it has moved.
class HarborIntMulDiv extends Module {
  /// Operand and result width, 32 or 64.
  final int width;

  /// Multiply iteration strategy.
  final HarborIntMulMode mulMode;

  /// Multiply pipeline stages, 1 to 3. Only used in pipelined mode.
  final int mulStages;

  /// Multiply radix: `mulRadix` bits per cycle. Only used in iterative
  /// mode.
  final int mulRadix;

  /// Divider iteration strategy, passed to the recurrence.
  final HarborFpDivMode divMode;

  /// Divider radix, 2 or 4, passed to the recurrence.
  final int divRadix;

  /// Divider pipeline stages, passed to the recurrence.
  final int divStages;

  /// When true, this unit builds no recurrence and instead exposes the
  /// recurrence-facing `shared_*` ports for a parent to connect one engine.
  final bool shareRecurrence;

  Logic get inReady => output('in_ready');
  Logic get outValid => output('out_valid');
  Logic get outResult => output('out_result');
  Logic get outTag => output('out_tag');
  Logic get slotValid => output('slot_valid');

  /// Only present when `in_tag` is given.
  Logic get slotTag => output('slot_tag');

  /// High while this unit has a divide in the shared engine. Only present
  /// with [shareRecurrence].
  Logic get busy => output('busy');

  /// The request this unit makes of the shared engine. Only present with
  /// [shareRecurrence].
  Logic get sharedInValid => output('shared_in_valid');
  Logic get sharedInOp => output('shared_in_op');
  Logic get sharedInA => output('shared_in_a');
  Logic get sharedInB => output('shared_in_b');
  Logic get sharedInNarrow => output('shared_in_narrow');
  Logic get sharedInTag => output('shared_in_tag');
  Logic get sharedOutReady => output('shared_out_ready');
  Logic get sharedKillMask => output('shared_kill_mask');

  /// Number of multiply slots.
  static int mulSlotCountOf(HarborIntMulMode mulMode, int mulStages) =>
      mulMode == HarborIntMulMode.pipelined ? mulStages : 1;

  /// Number of divide slots, the same with or without [shareRecurrence].
  static int divSlotCountOf(HarborFpDivMode divMode, int divStages) =>
      HarborDivSqrtRecurrence.slotCountOf(divMode, divStages);

  /// Width of `kill_mask` and `slot_valid`.
  static int slotCountOf(
    HarborIntMulMode mulMode,
    int mulStages,
    HarborFpDivMode divMode,
    int divStages,
  ) => mulSlotCountOf(mulMode, mulStages) + divSlotCountOf(divMode, divStages);

  /// Slot names in slot order.
  static List<String> slotNamesOf(
    HarborIntMulMode mulMode,
    int mulStages,
    HarborFpDivMode divMode,
    int divStages,
  ) => [
    if (mulMode == HarborIntMulMode.pipelined)
      for (var c = 1; c <= mulStages; c++) 'mul_$c'
    else
      'mul',
    for (final n in HarborDivSqrtRecurrence.slotNamesOf(divMode, divStages))
      'div_$n',
  ];

  int get mulSlots => mulSlotCountOf(mulMode, mulStages);
  int get divSlots => divSlotCountOf(divMode, divStages);
  int get slots => mulSlots + divSlots;
  List<String> get slotNames =>
      slotNamesOf(mulMode, mulStages, divMode, divStages);

  /// Cycles from accept to `out_valid` for a multiply, `out_ready` high. In
  /// iterative mode the `+ 1` is the merge cycle after the last shift-add
  /// step, where the sign correction and word select land in `resultReg`.
  int get mulLatency => mulMode == HarborIntMulMode.pipelined
      ? mulStages
      : (width + mulRadix - 1) ~/ mulRadix + 1;

  /// Cycles from accept to `out_valid` for a wide divide or remainder.
  int get divLatency => _divLatency(width);

  /// Cycles from accept to `out_valid` for a narrow (w-form) divide or
  /// remainder. Only meaningful when [width] is 64.
  int get divNarrowLatency => _divLatency(32);

  int _divLatency(int w) =>
      HarborDivSqrtRecurrence.integerLatencyOf(divMode, divRadix, divStages, w);

  /// [killMask] has [slotCountOf] bits. With [shareRecurrence],
  /// [sharedSlotValid] has [divSlotCountOf] bits.
  HarborIntMulDiv({
    required this.width,
    this.mulMode = HarborIntMulMode.pipelined,
    this.mulStages = 2,
    this.mulRadix = 2,
    this.divMode = HarborFpDivMode.iterative,
    this.divRadix = 2,
    this.divStages = 1,
    this.shareRecurrence = false,
    required Logic clk,
    required Logic reset,
    required Logic killMask,
    required Logic inValid,
    required Logic inOp,
    required Logic inA,
    required Logic inB,
    Logic? inTag,
    required Logic outReady,
    Logic? sharedInReady,
    Logic? sharedOutValid,
    Logic? sharedOutResult,
    Logic? sharedOutRemainder,
    Logic? sharedOutTag,
    Logic? sharedSlotValid,
    String name = 'int_mul_div',
  }) : super(
         name: name,
         definitionName: _definitionName(
           width,
           mulMode,
           mulStages,
           mulRadix,
           divMode,
           divRadix,
           divStages,
           shareRecurrence,
         ),
       ) {
    if (width != 32 && width != 64) {
      throw ArgumentError.value(width, 'width', 'must be 32 or 64');
    }
    if (mulRadix < 1 || mulRadix > width) {
      throw ArgumentError.value(mulRadix, 'mulRadix', 'must be 1 to width');
    }
    if (mulMode == HarborIntMulMode.pipelined &&
        (mulStages < 1 || mulStages > 3)) {
      throw ArgumentError.value(mulStages, 'mulStages', 'must be 1 to 3');
    }
    if (divRadix != 2 && divRadix != 4) {
      throw ArgumentError.value(divRadix, 'divRadix', 'must be 2 or 4');
    }
    if (divMode == HarborFpDivMode.pipelined) {
      final k = divRadix == 4 ? 2 : 1;
      final steps = (width + k - 1) ~/ k * k;
      final units = steps + 3;
      if (divStages < 1 || divStages > units) {
        throw ArgumentError.value(
          divStages,
          'divStages',
          'must be 1 to $units',
        );
      }
    }
    final nMul = mulSlots;
    final nDiv = divSlots;
    final nSlots = nMul + nDiv;
    if (killMask.width != nSlots) {
      throw ArgumentError.value(
        killMask.width,
        'killMask.width',
        'must be $nSlots',
      );
    }
    if (shareRecurrence) {
      if (sharedInReady == null ||
          sharedOutValid == null ||
          sharedOutResult == null ||
          sharedOutRemainder == null ||
          sharedOutTag == null ||
          sharedSlotValid == null) {
        throw ArgumentError(
          'shareRecurrence needs sharedInReady, sharedOutValid, '
          'sharedOutResult, sharedOutRemainder, sharedOutTag and '
          'sharedSlotValid',
        );
      }
      if (sharedSlotValid.width != nDiv) {
        throw ArgumentError.value(
          sharedSlotValid.width,
          'sharedSlotValid.width',
          'must be $nDiv',
        );
      }
    }

    final tagW = inTag?.width ?? 0;
    final opW = harborIntOpWidth;
    // Every op in flight sits in a slot, and a shared engine holds at most
    // one of ours. One more bit leaves room for the ages to grow.
    final inFlight = nMul + (shareRecurrence ? 1 : nDiv);
    final seqW = inFlight.bitLength + 1;
    final divTagW = shareRecurrence ? tagW + 1 : tagW + seqW + 1;

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    killMask = addInput('kill_mask', killMask, width: nSlots);
    inValid = addInput('in_valid', inValid);
    inOp = addInput('in_op', inOp, width: opW);
    inA = addInput('in_a', inA, width: width);
    inB = addInput('in_b', inB, width: width);
    if (tagW > 0) {
      inTag = addInput('in_tag', inTag!, width: tagW);
    }
    outReady = addInput('out_ready', outReady);
    addOutput('in_ready');
    addOutput('out_valid');
    addOutput('out_result', width: width);
    if (tagW > 0) {
      addOutput('out_tag', width: tagW);
    }
    addOutput('slot_valid', width: nSlots);
    if (tagW > 0) {
      addOutput('slot_tag', width: nSlots * tagW);
    }

    if (shareRecurrence) {
      sharedInReady = addInput('shared_in_ready', sharedInReady!);
      sharedOutValid = addInput('shared_out_valid', sharedOutValid!);
      sharedOutResult = addInput(
        'shared_out_result',
        sharedOutResult!,
        width: width,
      );
      sharedOutRemainder = addInput(
        'shared_out_remainder',
        sharedOutRemainder!,
        width: width,
      );
      sharedOutTag = addInput('shared_out_tag', sharedOutTag!, width: divTagW);
      sharedSlotValid = addInput(
        'shared_slot_valid',
        sharedSlotValid!,
        width: nDiv,
      );
      addOutput('busy');
      addOutput('shared_in_valid');
      addOutput('shared_in_op', width: 2);
      addOutput('shared_in_a', width: width);
      addOutput('shared_in_b', width: width);
      if (width == 64) {
        addOutput('shared_in_narrow');
      }
      addOutput('shared_in_tag', width: divTagW);
      addOutput('shared_out_ready');
      addOutput('shared_kill_mask', width: nDiv);
    }

    final mulKill = [for (var i = 0; i < nMul; i++) killMask[i]];
    final divKillMask = killMask.getRange(nMul, nSlots);

    // Op decode. mul-class ops are indices 0..4, div-class 5..12.
    final isDivClassOp = inOp
        .gte(Const(HarborIntOp.div.index, width: opW))
        .named('is_div_class');
    final isWFormOp =
        (_isOp(inOp, HarborIntOp.mulw) |
                inOp.gte(Const(HarborIntOp.divw.index, width: opW)))
            .named('is_w_form');
    final wantsRemainderOp =
        (_isOp(inOp, HarborIntOp.rem) |
                _isOp(inOp, HarborIntOp.remu) |
                _isOp(inOp, HarborIntOp.remw) |
                _isOp(inOp, HarborIntOp.remuw))
            .named('wants_remainder');
    final signedDivOp =
        (_isOp(inOp, HarborIntOp.div) |
                _isOp(inOp, HarborIntOp.rem) |
                _isOp(inOp, HarborIntOp.divw) |
                _isOp(inOp, HarborIntOp.remw))
            .named('signed_div');

    final nextSeq = Logic(name: 'next_seq', width: seqW);
    final ageOk = Logic(name: 'age_ok');
    final selMul = Logic(name: 'sel_mul');
    final selDiv = Logic(name: 'sel_div');

    final busyReg = shareRecurrence ? Logic(name: 'busy_reg') : null;
    final busyFree = busyReg == null ? Const(1) : ~busyReg;

    final mulValid = (inValid & ~isDivClassOp & ageOk).named('mul_in_v');
    final divValid = (inValid & isDivClassOp & ageOk & busyFree).named(
      'div_in_v',
    );
    final mulOutReady = (outReady & selMul).named('mul_out_ready');
    final divOutReady = (outReady & selDiv).named('div_out_ready');

    // --- Multiply path ---

    final Logic mulOutValid;
    final Logic mulOutResult;
    final Logic? mulOutTag;
    final Logic mulInReady;
    final mulSlotValids = <Logic>[];
    final mulSlotTags = <Logic>[];
    final mulSlotSeqs = <Logic>[];

    if (mulMode == HarborIntMulMode.pipelined) {
      _State preMulS(_State s) {
        final (absA, absB, sign) = _mulMagnitudes(
          width,
          s['op']!,
          s['a']!,
          s['b']!,
        );
        return {'op': s['op']!, 'sign': sign, 'a': absA, 'b': absB};
      }

      _State mulUnitS(_State s) => {
        'op': s['op']!,
        'sign': s['sign']!,
        'prod': (s['a']!.zeroExtend(2 * width) * s['b']!.zeroExtend(2 * width))
            .named('mul_prod'),
      };

      _State postMulS(_State s) => {
        'result': _mulResult(width, s['prod']!, s['sign']!, s['op']!),
      };

      final units = [preMulS, mulUnitS, postMulS];
      final ends = _cuts([1, 2, 1], mulStages);
      // The stall uses the raw last valid, so in_ready has no path from
      // kill_mask. A killed op in the last stage frees the pipe next cycle.
      final en = Logic(name: 'mul_stage_en');
      var live = mulValid;
      _State state = {'op': inOp, 'a': inA, 'b': inB};
      _State side = {'seq': nextSeq, if (tagW > 0) 'tag': inTag!};
      var done = 0;
      Logic? lastRaw;
      for (var c = 1; c <= mulStages; c++) {
        for (; done < ends[c - 1]; done++) {
          state = units[done](state);
        }
        final v = Logic(name: 'mul_valid_$c');
        final vLive = (v & ~mulKill[c - 1]).named('mul_live_$c');
        v <= flop(clk, mux(en, live, vLive), reset: reset);
        live = vLive;
        lastRaw = v;
        state = {
          for (final e in state.entries)
            e.key: flop(clk, e.value, en: en).named('${e.key}_ms$c'),
        };
        side = {
          for (final e in side.entries)
            e.key: flop(clk, e.value, en: en).named('mul_${e.key}_$c'),
        };
        mulSlotValids.add(v);
        mulSlotSeqs.add(side['seq']!);
        if (tagW > 0) {
          mulSlotTags.add(side['tag']!);
        }
      }
      en <= ~lastRaw! | mulOutReady;
      mulOutValid = live;
      mulOutResult = state['result']!;
      mulOutTag = side['tag'];
      mulInReady = en;
    } else {
      final kk = mulRadix;
      final cycles = (width + kk - 1) ~/ kk;
      final cntW = cycles.bitLength;

      final running = Logic(name: 'mul_running');
      final held = Logic(name: 'mul_held');
      final counter = Logic(name: 'mul_counter', width: cntW);
      final heldOp = Logic(name: 'mul_op_h', width: opW);
      final heldSign = Logic(name: 'mul_sign_h');
      final heldSeq = Logic(name: 'mul_seq_h', width: seqW);
      final heldTag = tagW > 0 ? Logic(name: 'mul_tag_h', width: tagW) : null;
      final prod = Logic(name: 'mul_prod', width: 2 * width);
      final mcand = Logic(name: 'mul_mcand', width: 2 * width);
      final mplier = Logic(name: 'mul_mplier', width: width);
      final resultReg = Logic(name: 'mul_result_reg', width: width);

      final inReadyEngine = (~running & ~held).named('mul_in_ready');
      final start = (mulValid & inReadyEngine).named('mul_start');
      final killed = mulKill[0];
      final (ldAbsA, ldAbsB, ldSign) = _mulMagnitudes(width, inOp, inA, inB);

      // One radix 2 shift-add step: conditionally add the shifted
      // multiplicand, then shift the multiplicand left and the remaining
      // multiplier right by one bit.
      (Logic, Logic, Logic) microStep(Logic p, Logic mc, Logic mp) {
        final bit = mp[0];
        final newProd = (p + mux(bit, mc, Const(0, width: 2 * width))).named(
          'mul_prod_step',
        );
        final newMcand = [mc.getRange(0, 2 * width - 1), Const(0)].swizzle();
        final newMplier = [Const(0), mp.getRange(1, width)].swizzle();
        return (newProd, newMcand, newMplier);
      }

      var pN = prod;
      var mcN = mcand;
      var mpN = mplier;
      for (var i = 0; i < kk; i++) {
        final r = microStep(pN, mcN, mpN);
        pN = r.$1;
        mcN = r.$2;
        mpN = r.$3;
      }

      final counterIsOne = counter.eq(Const(1, width: cntW));
      final lastStep = (running & counterIsOne).named('mul_last_step');
      final heldLive = (held & ~killed).named('mul_held_live');
      final taken = (heldLive & mulOutReady).named('mul_taken');

      prod <=
          flop(
            clk,
            mux(start, Const(0, width: 2 * width), pN),
            en: start | running,
            reset: reset,
          );
      mcand <=
          flop(
            clk,
            mux(start, ldAbsA.zeroExtend(2 * width), mcN),
            en: start | running,
            reset: reset,
          );
      mplier <=
          flop(clk, mux(start, ldAbsB, mpN), en: start | running, reset: reset);
      counter <=
          flop(
            clk,
            mux(
              start,
              Const(cycles, width: cntW),
              counter - Const(1, width: cntW),
            ),
            en: start | running,
            reset: reset,
          );
      heldOp <= flop(clk, inOp, en: start, reset: reset);
      heldSign <= flop(clk, ldSign, en: start, reset: reset);
      heldSeq <= flop(clk, nextSeq, en: start, reset: reset);
      if (heldTag != null) {
        heldTag <= flop(clk, inTag!, en: start, reset: reset);
      }
      running <=
          flop(clk, start | (running & ~lastStep & ~killed), reset: reset);
      held <=
          flop(
            clk,
            ((lastStep & ~killed) | (held & ~taken & ~killed)),
            reset: reset,
          );
      resultReg <=
          flop(
            clk,
            _mulResult(width, pN, heldSign, heldOp),
            en: lastStep,
            reset: reset,
          );

      mulSlotValids.add((running | held).named('mul_slot_valid'));
      mulSlotSeqs.add(heldSeq);
      if (heldTag != null) {
        mulSlotTags.add(heldTag);
      }
      mulOutValid = heldLive;
      mulOutResult = resultReg;
      mulOutTag = heldTag;
      mulInReady = inReadyEngine;
    }

    // --- Divide path ---

    final combinedTagIn = [
      if (tagW > 0) inTag!,
      if (!shareRecurrence) nextSeq,
      wantsRemainderOp,
    ].swizzle();
    final divOpSel = mux(
      signedDivOp,
      Const(HarborDivSqrtOp.divSigned.index, width: 2),
      Const(HarborDivSqrtOp.divUnsigned.index, width: 2),
    );

    final Logic divInReady;
    final Logic divOutValid;
    final Logic divResult;
    final Logic? divOutTag;
    final divSlotValids = <Logic>[];
    final divSlotTags = <Logic>[];
    final divSlotSeqs = <Logic>[];

    if (!shareRecurrence) {
      final rec = HarborDivSqrtRecurrence.integer(
        width,
        divMode,
        divRadix,
        divStages,
        clk: clk,
        reset: reset,
        killMask: divKillMask,
        inValid: divValid,
        inOp: divOpSel,
        inA: inA,
        inB: inB,
        inNarrow: width == 64 ? isWFormOp : null,
        inTag: combinedTagIn,
        outReady: divOutReady,
        narrowWidth: width == 64 ? 32 : 0,
      );
      divInReady = rec.inReady;
      divOutValid = rec.outValid;
      divOutTag = tagW > 0 ? rec.outTag.getRange(1 + seqW, divTagW) : null;
      divResult = mux(rec.outTag[0], rec.outRemainder, rec.outResult);
      for (var i = 0; i < nDiv; i++) {
        final t = rec.slotTag.getRange(i * divTagW, (i + 1) * divTagW);
        divSlotValids.add(rec.slotValid[i]);
        divSlotSeqs.add(t.getRange(1, 1 + seqW));
        if (tagW > 0) {
          divSlotTags.add(t.getRange(1 + seqW, divTagW));
        }
      }
    } else {
      sharedInValid <= divValid;
      sharedInOp <= divOpSel;
      sharedInA <= inA;
      sharedInB <= inB;
      if (width == 64) {
        sharedInNarrow <= isWFormOp;
      }
      sharedInTag <= combinedTagIn;
      sharedOutReady <= divOutReady;
      final busyNow = busyReg!;
      sharedKillMask <= divKillMask & busyNow.replicate(nDiv);

      divInReady = (sharedInReady! & busyFree).named('div_in_ready_shared');
      divOutValid = sharedOutValid!;
      divOutTag = tagW > 0 ? sharedOutTag!.getRange(1, divTagW) : null;
      divResult = mux(sharedOutTag![0], sharedOutRemainder!, sharedOutResult!);

      final issue = (divValid & divInReady).named('div_issue');
      final seqReg = flop(
        clk,
        nextSeq,
        en: issue,
        reset: reset,
      ).named('div_seq_h');
      final tagReg = tagW > 0
          ? flop(clk, inTag!, en: issue, reset: reset).named('div_tag_h')
          : null;
      final killed = (divKillMask & sharedSlotValid!).or() & busyNow;
      final drain = (divOutValid & divOutReady).named('div_drain');
      busyNow <= flop(clk, issue | (busyNow & ~drain & ~killed), reset: reset);
      busy <= busyNow;
      for (var i = 0; i < nDiv; i++) {
        divSlotValids.add(sharedSlotValid[i] & busyNow);
        divSlotSeqs.add(seqReg);
        if (tagReg != null) {
          divSlotTags.add(tagReg);
        }
      }
    }

    // --- Merge ---

    // Ages count back from next_seq, so the larger age is the older op.
    final (mulOldV, mulOldSeq) = _oldest(mulSlotValids, mulSlotSeqs);
    final (divOldV, divOldSeq) = _oldest(divSlotValids, divSlotSeqs);
    final mulAge = (nextSeq - mulOldSeq).named('mul_age');
    final divAge = (nextSeq - divOldSeq).named('div_age');
    final maxAge = Const((1 << seqW) - 1, width: seqW);
    ageOk <= ~(mulOldV & mulAge.eq(maxAge)) & ~(divOldV & divAge.eq(maxAge));
    selMul <= mulOldV & (~divOldV | mulAge.gt(divAge));
    selDiv <= divOldV & (~mulOldV | divAge.gt(mulAge));

    final inReadyVal = (mux(isDivClassOp, divInReady, mulInReady) & ageOk)
        .named('in_ready_val');
    final accept = (inValid & inReadyVal).named('accept');
    nextSeq <= flop(clk, nextSeq + accept.zeroExtend(seqW), reset: reset);

    outValid <= (selMul & mulOutValid) | (selDiv & divOutValid);
    outResult <= mux(selDiv, divResult, mulOutResult);
    if (tagW > 0) {
      outTag <= mux(selDiv, divOutTag!, mulOutTag!);
    }
    inReady <= inReadyVal;
    slotValid <= [...mulSlotValids, ...divSlotValids].rswizzle();
    if (tagW > 0) {
      slotTag <= [...mulSlotTags, ...divSlotTags].rswizzle();
    }
  }

  static String _definitionName(
    int width,
    HarborIntMulMode mulMode,
    int mulStages,
    int mulRadix,
    HarborFpDivMode divMode,
    int divRadix,
    int divStages,
    bool shareRecurrence,
  ) {
    final parts = [
      'HarborIntMulDiv',
      'W$width',
      mulMode == HarborIntMulMode.pipelined
          ? 'MulS$mulStages'
          : 'MulR$mulRadix',
      divMode == HarborFpDivMode.iterative ? 'DivR$divRadix' : 'DivS$divStages',
      if (shareRecurrence) 'Shared',
    ];
    return parts.join('_');
  }
}
