import 'dart:async';
import 'dart:isolate';
import 'dart:math';

import 'package:harbor/src/arith/fp_pipe_stage.dart';
import 'package:harbor/src/arith/fpu_config.dart';
import 'package:harbor/src/arith/int_mul_div.dart';
import 'package:harbor/src/arith/recurrence.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'lane_sim.dart';

const _pipelined = HarborIntMulMode.pipelined;
const _iterative = HarborIntMulMode.iterative;
const _divIter = HarborFpDivMode.iterative;
const _divPipe = HarborFpDivMode.pipelined;

// --- BigInt oracle --------------------------------------------------------

BigInt _mask(int w) => (BigInt.one << w) - BigInt.one;

/// The quotient or remainder for RISC-V div/divu/rem/remu at width [w],
/// with the divide-by-zero and INT_MIN/-1 special cases.
BigInt _divRem(
  BigInt a,
  BigInt b,
  int w, {
  required bool signed,
  required bool wantRem,
}) {
  final au = a.toUnsigned(w);
  final bu = b.toUnsigned(w);
  if (!signed) {
    if (bu == BigInt.zero) {
      return wantRem ? au : _mask(w);
    }
    return (wantRem ? au.remainder(bu) : au ~/ bu).toUnsigned(w);
  }
  final as_ = au.toSigned(w);
  final bs = bu.toSigned(w);
  if (bs == BigInt.zero) {
    return wantRem ? as_.toUnsigned(w) : _mask(w);
  }
  final minSigned = -(BigInt.one << (w - 1));
  if (as_ == minSigned && bs == BigInt.from(-1)) {
    return wantRem ? BigInt.zero : as_.toUnsigned(w);
  }
  return (wantRem ? as_.remainder(bs) : as_ ~/ bs).toUnsigned(w);
}

/// The expected `out_result` bit pattern for [op] on the raw [aBits] and
/// [bBits] bit patterns, at [width].
BigInt _oracle(HarborIntOp op, BigInt aBits, BigInt bBits, int width) {
  switch (op) {
    case HarborIntOp.mul:
      return (aBits.toUnsigned(width) * bBits.toUnsigned(width)).toUnsigned(
        width,
      );
    case HarborIntOp.mulw:
      final low = (aBits.toUnsigned(64) * bBits.toUnsigned(64)).toUnsigned(32);
      return low.toSigned(32).toUnsigned(64);
    case HarborIntOp.mulh:
    case HarborIntOp.mulhsu:
    case HarborIntOp.mulhu:
      final signedA = op != HarborIntOp.mulhu;
      final signedB = op == HarborIntOp.mulh;
      final av = signedA ? aBits.toSigned(width) : aBits.toUnsigned(width);
      final bv = signedB ? bBits.toSigned(width) : bBits.toUnsigned(width);
      final full = av * bv;
      return (full >> width).toUnsigned(width);
    case HarborIntOp.div:
      return _divRem(aBits, bBits, width, signed: true, wantRem: false);
    case HarborIntOp.divu:
      return _divRem(aBits, bBits, width, signed: false, wantRem: false);
    case HarborIntOp.rem:
      return _divRem(aBits, bBits, width, signed: true, wantRem: true);
    case HarborIntOp.remu:
      return _divRem(aBits, bBits, width, signed: false, wantRem: true);
    case HarborIntOp.divw:
      return _divRem(
        aBits,
        bBits,
        32,
        signed: true,
        wantRem: false,
      ).toSigned(32).toUnsigned(64);
    case HarborIntOp.divuw:
      return _divRem(
        aBits,
        bBits,
        32,
        signed: false,
        wantRem: false,
      ).toSigned(32).toUnsigned(64);
    case HarborIntOp.remw:
      return _divRem(
        aBits,
        bBits,
        32,
        signed: true,
        wantRem: true,
      ).toSigned(32).toUnsigned(64);
    case HarborIntOp.remuw:
      return _divRem(
        aBits,
        bBits,
        32,
        signed: false,
        wantRem: true,
      ).toSigned(32).toUnsigned(64);
  }
}

bool _isWForm(HarborIntOp op) =>
    op == HarborIntOp.mulw || op.index >= HarborIntOp.divw.index;

List<HarborIntOp> _opsFor(int width) => width == 64
    ? HarborIntOp.values
    : HarborIntOp.values.where((o) => !_isWForm(o)).toList();

List<BigInt> _corners(int w) => [
  BigInt.zero,
  BigInt.one,
  _mask(w),
  BigInt.one << (w - 1),
  (BigInt.one << (w - 1)) - BigInt.one,
  BigInt.two,
  _mask(w) - BigInt.one,
];

BigInt _randBits(Random r, int w) {
  var v = BigInt.zero;
  var bits = 0;
  while (bits < w) {
    v = (v << 16) | BigInt.from(r.nextInt(0x10000));
    bits += 16;
  }
  return v.toUnsigned(w);
}

typedef _Case = (HarborIntOp op, BigInt a, BigInt b);

List<_Case> _genCases(int width, Random r, int randomCount) {
  final ops = _opsFor(width);
  final corners = _corners(width);
  final cases = <_Case>[
    for (final op in ops)
      for (final a in corners)
        for (final b in corners) (op, a, b),
  ];
  for (var i = 0; i < randomCount; i++) {
    cases.add((
      ops[r.nextInt(ops.length)],
      _randBits(r, width),
      _randBits(r, width),
    ));
  }
  return cases;
}

int _onesMask(int n) => n >= 64 ? -1 : (1 << n) - 1;

// --- LaneSim bulk oracle check (iterative mul, no `*` in the design) ------

/// Runs [cases] through a combinational-input, elastic-output build, 64 at
/// a time. Each lane issues exactly once and is never reissued, so lanes
/// with different latencies (mul vs divide, wide vs narrow) finish at
/// different cycles; LaneSim tracks that per lane.
Future<void> _laneBulk({
  required int width,
  int mulRadix = 2,
  required HarborFpDivMode divMode,
  required int divRadix,
  required int divStages,
  required List<_Case> cases,
}) async {
  final clk = Logic(name: 'clk');
  final reset = Logic(name: 'reset');
  final killMask = Logic(
    name: 'kill_mask',
    width: HarborIntMulDiv.slotCountOf(_iterative, 0, divMode, divStages),
  );
  final inValid = Logic(name: 'in_valid');
  final inOp = Logic(name: 'in_op', width: harborIntOpWidth);
  final inA = Logic(name: 'in_a', width: width);
  final inB = Logic(name: 'in_b', width: width);
  final outReady = Logic(name: 'out_ready');
  final dut = HarborIntMulDiv(
    width: width,
    mulMode: _iterative,
    mulRadix: mulRadix,
    divMode: divMode,
    divRadix: divRadix,
    divStages: divStages,
    clk: clk,
    reset: reset,
    killMask: killMask,
    inValid: inValid,
    inOp: inOp,
    inA: inA,
    inB: inB,
    outReady: outReady,
  );
  await dut.build();
  final sim = LaneSim(
    dut,
    [reset, killMask, inValid, inOp, inA, inB, outReady],
    [dut.inReady, dut.outValid, dut.outResult],
  );

  sim.setMask(reset, 0);
  sim.set(killMask, List.filled(64, BigInt.zero));
  sim.setMask(outReady, -1);

  final limit =
      max(dut.mulLatency, max(dut.divLatency, dut.divNarrowLatency)) + 20;
  var idx = 0;
  while (idx < cases.length) {
    final batch = cases.skip(idx).take(64).toList();
    final n = batch.length;
    idx += n;

    sim.set(inOp, [for (final c in batch) BigInt.from(c.$1.index)]);
    sim.set(inA, [for (final c in batch) c.$2]);
    sim.set(inB, [for (final c in batch) c.$3]);

    final full = _onesMask(n);
    var issued = 0;
    var finished = 0;
    final results = List<BigInt?>.filled(n, null);
    var cycles = 0;
    while ((finished & full) != full && cycles < limit) {
      sim.setMask(inValid, -1 & ~issued);
      sim.run();
      final inReadyMask = sim.getMask(dut.inReady);
      issued |= (-1 & ~issued) & inReadyMask;
      final newly = sim.getMask(dut.outValid) & full & ~finished;
      if (newly != 0) {
        final got = sim.get(dut.outResult, n);
        for (var i = 0; i < n; i++) {
          if ((newly >> i) & 1 == 1) {
            results[i] = got[i];
          }
        }
        finished |= newly;
      }
      sim.clock();
      cycles++;
    }
    expect(
      cycles < limit,
      isTrue,
      reason: 'batch timed out at $width $divMode',
    );
    for (var i = 0; i < n; i++) {
      final (op, a, b) = batch[i];
      expect(
        results[i],
        _oracle(op, a, b, width),
        reason:
            '$op a=${a.toRadixString(16)} b=${b.toRadixString(16)} '
            'width=$width divMode=$divMode',
      );
    }
  }
}

// --- Clocked (ROHD simulator, isolate) harness -----------------------------

const _tagWidth = 16;

/// A build of [HarborIntMulDiv] for the clocked harness.
typedef _Build = ({
  int width,
  HarborIntMulMode mulMode,
  int mulStages,
  int mulRadix,
  HarborFpDivMode divMode,
  int divRadix,
  int divStages,
});

_Build _build(
  int width, {
  HarborIntMulMode mulMode = _pipelined,
  int mulStages = 2,
  int mulRadix = 2,
  HarborFpDivMode divMode = _divIter,
  int divRadix = 2,
  int divStages = 1,
}) => (
  width: width,
  mulMode: mulMode,
  mulStages: mulStages,
  mulRadix: mulRadix,
  divMode: divMode,
  divRadix: divRadix,
  divStages: divStages,
);

int _slotsOf(_Build b) =>
    HarborIntMulDiv.slotCountOf(b.mulMode, b.mulStages, b.divMode, b.divStages);

List<String> _namesOf(_Build b) =>
    HarborIntMulDiv.slotNamesOf(b.mulMode, b.mulStages, b.divMode, b.divStages);

/// What the harness sees in one cycle, before it drives the kill mask.
typedef _View = ({int cycle, int next, int slotValid, List<int> slotTags});

class _KillStats {
  final List<int> hits;
  final List<int> both;
  var outReady = 0;
  var inAccept = 0;
  var inTake = 0;
  var empty = 0;
  var flushes = 0;
  final cycles = <int>[];
  _KillStats(int n) : hits = List.filled(n, 0), both = List.filled(n, 0);
}

class _Trace {
  final List<(int tag, BigInt result)> taken;
  final List<String> errors;
  final int cycles;
  final Map<int, int> acceptCycles;
  final Map<int, int> outCycles;
  final Set<int> killed;
  final List<int> slotValids;
  final _KillStats stats;
  const _Trace(
    this.taken,
    this.errors,
    this.cycles,
    this.acceptCycles,
    this.outCycles,
    this.killed,
    this.slotValids,
    this.stats,
  );
}

/// Runs [ops] in order through a clocked [HarborIntMulDiv], tag = op index.
///
/// `in_valid` is low on a [gap] share of cycles. `out_ready` goes low on a
/// [stall] share of cycles for 1 to [stallBurst] cycles. Each cycle, with
/// [killRate], one random slot is killed (a random subset one time in
/// four), and with [flushRate] every slot is killed. [killAt], [validAt]
/// and [readyAt] replace the random choices when given.
///
/// The harness checks that every accepted op that is not killed comes out
/// once, in order, and that a killed op never comes out.
Future<_Trace> _clocked(
  _Build b,
  List<_Case> ops, {
  int seed = 1,
  double gap = 0.2,
  double stall = 0.3,
  int stallBurst = 1,
  double killRate = 0,
  double flushRate = 0,
  int Function(_View v)? killAt,
  bool Function(_View v)? validAt,
  bool Function(_View v)? readyAt,
}) => Isolate.run(() async {
  final width = b.width;
  final nSlots = _slotsOf(b);
  final names = _namesOf(b);
  final mulOut = names.lastIndexWhere((n) => n.startsWith('mul'));
  final divOut = nSlots - 1;
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final killMask = Logic(name: 'kill_mask', width: nSlots);
  final inValid = Logic(name: 'in_valid');
  final inOp = Logic(name: 'in_op', width: harborIntOpWidth);
  final inA = Logic(name: 'in_a', width: width);
  final inB = Logic(name: 'in_b', width: width);
  final inTag = Logic(name: 'in_tag', width: _tagWidth);
  final outReady = Logic(name: 'out_ready');
  final dut = HarborIntMulDiv(
    width: width,
    mulMode: b.mulMode,
    mulStages: b.mulStages,
    mulRadix: b.mulRadix,
    divMode: b.divMode,
    divRadix: b.divRadix,
    divStages: b.divStages,
    clk: clk,
    reset: reset,
    killMask: killMask,
    inValid: inValid,
    inOp: inOp,
    inA: inA,
    inB: inB,
    inTag: inTag,
    outReady: outReady,
  );
  await dut.build();
  final r = Random(seed);
  final taken = <(int, BigInt)>[];
  final errors = <String>[];
  final inFlight = <int>[];
  final acceptCycles = <int, int>{};
  final outCycles = <int, int>{};
  final killed = <int>{};
  final killedAt = <int, String>{};
  final slotValids = <int>[];
  final stats = _KillStats(nSlots);

  void put(int tag) {
    final (op, a, b) = ops[tag];
    inOp.put(op.index);
    inA.put(a);
    inB.put(b);
    inTag.put(tag);
  }

  reset.put(1);
  killMask.put(0);
  inValid.put(0);
  outReady.put(0);
  if (ops.isNotEmpty) {
    put(0);
  }
  unawaited(Simulator.run());
  await clk.nextNegedge;
  await clk.nextNegedge;
  reset.put(0);

  var next = 0;
  var cycle = 0;
  var stallLeft = 0;
  final limit = 200 + ops.length * (dut.mulLatency + dut.divLatency + 4) * 2;
  while ((next < ops.length || inFlight.isNotEmpty) && cycle < limit) {
    await clk.nextNegedge;
    cycle++;
    final sv = dut.slotValid.value.toInt();
    final st = dut.slotTag.value;
    final tags = [
      for (var i = 0; i < nSlots; i++)
        (sv >> i) & 1 == 1
            ? st.getRange(i * _tagWidth, (i + 1) * _tagWidth).toInt()
            : -1,
    ];
    slotValids.add(sv);
    final view = (cycle: cycle, next: next, slotValid: sv, slotTags: tags);

    var mask = 0;
    if (killAt != null) {
      mask = killAt(view);
    } else if (r.nextDouble() < flushRate) {
      mask = _onesMask(nSlots);
      stats.flushes++;
    } else if (r.nextDouble() < killRate) {
      mask = r.nextInt(4) == 0
          ? r.nextInt(1 << nSlots)
          : 1 << r.nextInt(nSlots);
    }
    final valid =
        next < ops.length &&
        (validAt != null ? validAt(view) : r.nextDouble() >= gap);
    final bool ready;
    if (readyAt != null) {
      ready = readyAt(view);
    } else if (stallLeft > 0) {
      stallLeft--;
      ready = false;
    } else if (r.nextDouble() < stall) {
      stallLeft = r.nextInt(stallBurst);
      ready = false;
    } else {
      ready = true;
    }
    killMask.put(0);
    inValid.put(valid ? 1 : 0);
    outReady.put(ready ? 1 : 0);
    if (next < ops.length) {
      put(next);
    }
    final readyNoKill = dut.inReady.value.toBool();
    killMask.put(mask);
    final inReady = dut.inReady.value.toBool();
    if (inReady != readyNoKill) {
      errors.add('cycle $cycle: in_ready changed with kill_mask');
    }
    final outValid = dut.outValid.value.toBool();
    final accepted = valid && inReady;

    var killedNow = false;
    for (var i = 0; i < nSlots; i++) {
      if ((mask >> i) & 1 == 0) {
        continue;
      }
      final tag = tags[i];
      if (tag < 0) {
        stats.empty++;
        continue;
      }
      killedNow = true;
      stats.hits[i]++;
      final older = inFlight.any((t) => t < tag);
      final younger = accepted || inFlight.any((t) => t > tag);
      if (older && younger) {
        stats.both[i]++;
      }
      if (ready && (i == mulOut || i == divOut)) {
        stats.outReady++;
      }
      if (!inFlight.remove(tag)) {
        errors.add(
          'cycle $cycle: slot ${names[i]} shows tag $tag, not in flight',
        );
      }
      killed.add(tag);
      killedAt[tag] = 'cycle $cycle slot ${names[i]} mask $mask sv $sv';
    }
    if (killedNow) {
      stats.cycles.add(cycle);
    }
    if (killedNow && accepted) {
      stats.inAccept++;
    }

    if (outValid) {
      // Checked on every cycle out_valid is high, whatever out_ready is: a
      // killed op must never show on out_valid, even while it is held for
      // a consumer that is not ready yet.
      final shownTag = dut.outTag.value.toInt();
      if (killed.contains(shownTag)) {
        errors.add(
          'cycle $cycle: killed tag $shownTag on out_valid '
          '(${killedAt[shownTag]})',
        );
      }
    }
    if (outValid && ready) {
      final tag = dut.outTag.value.toInt();
      if (killedNow) {
        stats.inTake++;
      }
      if (inFlight.isEmpty || inFlight.first != tag) {
        errors.add(
          'cycle $cycle: tag $tag out of order, expected '
          '${inFlight.isEmpty ? '(empty)' : inFlight.first}',
        );
      } else {
        inFlight.removeAt(0);
      }
      taken.add((tag, dut.outResult.value.toBigInt()));
      outCycles[tag] = cycle;
    }
    if (accepted) {
      inFlight.add(next);
      acceptCycles[next] = cycle;
      next++;
    }
  }
  if (cycle >= limit) {
    errors.add('timed out with ${inFlight.length} ops in flight');
  }
  await Simulator.endSimulation();
  return _Trace(
    taken,
    errors,
    cycle,
    acceptCycles,
    outCycles,
    killed,
    slotValids,
    stats,
  );
});

/// Every op that was not killed came out once, in order, with the oracle
/// result.
void _checkAll(List<_Case> ops, int width, _Trace t) {
  expect(t.errors, isEmpty, reason: t.errors.take(10).join('\n'));
  expect(
    [for (final (tag, _) in t.taken) tag],
    [
      for (var i = 0; i < ops.length; i++)
        if (!t.killed.contains(i)) i,
    ],
  );
  final bad = <String>[];
  for (final (tag, got) in t.taken) {
    final (op, a, b) = ops[tag];
    final want = _oracle(op, a, b, width);
    if (got != want) {
      bad.add(
        '$op a=${a.toRadixString(16)} b=${b.toRadixString(16)} '
        'got=${got.toRadixString(16)} want=${want.toRadixString(16)}',
      );
    }
  }
  expect(bad, isEmpty, reason: bad.join('\n'));
}

/// A mix of random ops with about [divShare] divides.
List<_Case> _mixed(int width, Random r, int count, double divShare) {
  final ops = _opsFor(width);
  final muls = ops.where((o) => o.index < HarborIntOp.div.index).toList();
  final divs = ops.where((o) => o.index >= HarborIntOp.div.index).toList();
  return [
    for (var i = 0; i < count; i++)
      (
        r.nextDouble() < divShare
            ? divs[r.nextInt(divs.length)]
            : muls[r.nextInt(muls.length)],
        _randBits(r, width),
        _randBits(r, width),
      ),
  ];
}

/// Kills the first slot named [slot] that holds [tag], once.
int Function(_View) _killOnce(List<String> names, String slot, int tag) {
  var done = false;
  final i = names.indexOf(slot);
  return (v) {
    if (!done && v.slotTags[i] == tag) {
      done = true;
      return 1 << i;
    }
    return 0;
  };
}

void main() {
  group('elaboration', () {
    HarborIntMulDiv build({
      int width = 32,
      HarborIntMulMode mulMode = _pipelined,
      int mulStages = 2,
      int mulRadix = 2,
      HarborFpDivMode divMode = _divIter,
      int divRadix = 2,
      int divStages = 1,
      bool shareRecurrence = false,
      int? maskWidth,
    }) {
      final clk = Logic(name: 'clk');
      final reset = Logic(name: 'reset');
      final n = mulMode == _pipelined && (mulStages < 1 || mulStages > 3)
          ? 1
          : HarborIntMulDiv.slotCountOf(mulMode, mulStages, divMode, divStages);
      final killMask = Logic(name: 'kill_mask', width: maskWidth ?? n);
      final inValid = Logic(name: 'in_valid');
      final inOp = Logic(name: 'in_op', width: harborIntOpWidth);
      final inA = Logic(name: 'in_a', width: width);
      final inB = Logic(name: 'in_b', width: width);
      final outReady = Logic(name: 'out_ready');
      return HarborIntMulDiv(
        width: width,
        mulMode: mulMode,
        mulStages: mulStages,
        mulRadix: mulRadix,
        divMode: divMode,
        divRadix: divRadix,
        divStages: divStages,
        shareRecurrence: shareRecurrence,
        clk: clk,
        reset: reset,
        killMask: killMask,
        inValid: inValid,
        inOp: inOp,
        inA: inA,
        inB: inB,
        outReady: outReady,
      );
    }

    test('bad width rejected', () {
      expect(() => build(width: 48), throwsArgumentError);
    });

    test('bad mulRadix rejected', () {
      expect(() => build(mulRadix: 0), throwsArgumentError);
      expect(() => build(mulRadix: 33), throwsArgumentError);
    });

    test('bad mulStages rejected', () {
      expect(() => build(mulStages: 0), throwsArgumentError);
      expect(() => build(mulStages: 4), throwsArgumentError);
    });

    test('bad divRadix rejected', () {
      expect(() => build(divRadix: 3), throwsArgumentError);
    });

    test('bad divStages rejected', () {
      expect(
        () => build(divMode: _divPipe, divStages: 1000),
        throwsArgumentError,
      );
      expect(() => build(divMode: _divPipe, divStages: 0), throwsArgumentError);
    });

    test('shareRecurrence needs the shared ports', () {
      expect(() => build(shareRecurrence: true), throwsArgumentError);
    });

    test('wrong kill mask width rejected', () {
      expect(() => build(maskWidth: 3), throwsArgumentError);
    });

    test('definition names differ by width and mode', () {
      final a = build(width: 32);
      final b = build(width: 64);
      final c = build(mulMode: _iterative);
      expect(a.definitionName, isNot(b.definitionName));
      expect(a.definitionName, isNot(c.definitionName));
    });

    test('latency getters', () {
      final pipe = build(mulMode: _pipelined, mulStages: 3);
      expect(pipe.mulLatency, 3);
      final iter = build(mulMode: _iterative, mulRadix: 2, width: 32);
      expect(iter.mulLatency, 16 + 1);
      final div = build(divMode: _divIter, divRadix: 2, width: 32);
      expect(div.divLatency, 32 + 4);
      final div64 = build(divMode: _divIter, divRadix: 2, width: 64);
      expect(div64.divNarrowLatency, 32 + 4);
    });

    test('slot counts, names and ports', () {
      expect(HarborIntMulDiv.slotNamesOf(_pipelined, 3, _divIter, 1), [
        'mul_1',
        'mul_2',
        'mul_3',
        'div_in',
        'div_step',
        'div_post',
        'div_out',
      ]);
      expect(HarborIntMulDiv.slotNamesOf(_iterative, 0, _divPipe, 2), [
        'mul',
        'div_stage_1',
        'div_stage_2',
      ]);
      expect(HarborIntMulDiv.slotCountOf(_iterative, 0, _divIter, 1), 5);
      final d = build(mulStages: 1, divMode: _divPipe, divStages: 4);
      expect(d.slots, 5);
      expect(d.mulSlots, 1);
      expect(d.divSlots, 4);
      expect(
        d.slotNames,
        HarborIntMulDiv.slotNamesOf(_pipelined, 1, _divPipe, 4),
      );
      expect(d.inputs.keys, contains('kill_mask'));
      expect(d.inputs.keys, isNot(contains('kill')));
      expect(d.input('kill_mask').width, 5);
      expect(d.slotValid.width, 5);
    });
  });

  group('LaneSim bulk oracle, iterative mul', () {
    for (final width in [32, 64]) {
      for (final spec in [
        (
          name: 'mul r2, div iterative r2',
          mulRadix: 2,
          mode: _divIter,
          radix: 2,
          stages: 0,
        ),
        (
          name: 'mul r2, div pipelined s1',
          mulRadix: 2,
          mode: _divPipe,
          radix: 2,
          stages: 1,
        ),
        (
          name: 'mul r4, div iterative r4',
          mulRadix: 4,
          mode: _divIter,
          radix: 4,
          stages: 0,
        ),
      ]) {
        test(
          'width $width, ${spec.name}',
          () async {
            final r = Random(
              width * 7 + spec.mode.index * 3 + spec.radix + spec.mulRadix * 5,
            );
            final cases = _genCases(width, r, 20000);
            await _laneBulk(
              width: width,
              mulRadix: spec.mulRadix,
              divMode: spec.mode,
              divRadix: spec.radix,
              divStages: spec.stages,
              cases: cases,
            );
          },
          timeout: const Timeout(Duration(minutes: 5)),
        );
      }
    }
  });

  group('clocked oracle, pipelined mul', () {
    for (final width in [32, 64]) {
      test('width $width', () async {
        final r = Random(width * 11 + 1);
        final ops = _opsFor(width);
        final corners = _corners(width);
        final cases = <_Case>[
          for (final op in ops)
            for (final a in corners)
              for (final b in corners) (op, a, b),
        ];
        for (var i = 0; i < 1500; i++) {
          cases.add((
            ops[r.nextInt(ops.length)],
            _randBits(r, width),
            _randBits(r, width),
          ));
        }
        final t = await _clocked(_build(width), cases, gap: 0, stall: 0);
        _checkAll(cases, width, t);
      }, timeout: const Timeout(Duration(minutes: 5)));
    }
  });

  group('clocked oracle, iterative mul and pipelined div', () {
    // LaneSim above runs the bulk volume. This group runs the pipelined
    // divide build with iterative mul under elastic stress in the ROHD
    // simulator, which is slower per op, so it uses fewer cases.
    for (final width in [32, 64]) {
      test('width $width', () async {
        final r = Random(width * 13 + 5);
        final ops = _opsFor(width);
        final corners = _corners(width).take(width == 64 ? 3 : 4).toList();
        final cases = <_Case>[
          for (final op in ops)
            for (final a in corners)
              for (final b in corners) (op, a, b),
        ];
        for (var i = 0; i < 80; i++) {
          cases.add((
            ops[r.nextInt(ops.length)],
            _randBits(r, width),
            _randBits(r, width),
          ));
        }
        final t = await _clocked(
          _build(width, mulMode: _iterative, divMode: _divPipe, divStages: 3),
          cases,
        );
        _checkAll(cases, width, t);
      }, timeout: const Timeout(Duration(minutes: 10)));
    }
  });

  test(
    'clocked oracle, mul radix 4 and div radix 4',
    () async {
      final r = Random(44);
      final cases = _mixed(64, r, 160, 0.5);
      final t = await _clocked(
        _build(64, mulMode: _iterative, mulRadix: 4, divRadix: 4),
        cases,
      );
      _checkAll(cases, 64, t);
      final cycles = [
        for (var i = 0; i < cases.length; i++)
          if (cases[i].$1.index < HarborIntOp.div.index)
            t.outCycles[i]! - t.acceptCycles[i]!,
      ];
      expect(cycles.reduce(min), 64 ~/ 4 + 1);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  group('elastic', () {
    test('mul issue while a divide is busy', () async {
      final cases = <_Case>[
        (HarborIntOp.div, BigInt.from(100000), BigInt.from(7)),
        (HarborIntOp.mul, BigInt.from(3), BigInt.from(4)),
        (HarborIntOp.mul, BigInt.from(5), BigInt.from(6)),
        (HarborIntOp.mulh, BigInt.from(-3) & _mask(32), BigInt.from(9)),
        (HarborIntOp.mul, BigInt.from(11), BigInt.from(12)),
      ];
      final t = await _clocked(_build(32), cases, gap: 0, stall: 0);
      _checkAll(cases, 32, t);
      // A busy divide does not hold back a multiply: tag 1 is accepted a
      // cycle or two after tag 0, long before the divide finishes.
      expect(t.acceptCycles[1]! - t.acceptCycles[0]!, lessThan(4));
    });

    test('pipelined mul: in_ready high whenever out_ready is', () async {
      final r = Random(7);
      final cases = _genCases(
        32,
        r,
        200,
      ).where((c) => c.$1.index < HarborIntOp.div.index).toList();
      final t = await _clocked(_build(32), cases, gap: 0.3, stall: 0.4);
      _checkAll(cases, 32, t);
    });
  });

  group('per-slot kill', () {
    // Each build runs random single-slot kills, random subsets and
    // flushes over mixed traffic with long out_ready stalls, so ops wait
    // in every slot. The harness checks that killed tags never come out.
    for (final spec in [
      (
        name: 'mul pipelined 3, div iterative r2, width 32',
        b: _build(32, mulStages: 3),
        ops: 3000,
        min: 20,
      ),
      (
        name: 'mul iterative r4, div pipelined 4, width 32',
        b: _build(
          32,
          mulMode: _iterative,
          mulRadix: 4,
          divMode: _divPipe,
          divStages: 4,
        ),
        ops: 2000,
        min: 20,
      ),
    ]) {
      test(spec.name, () async {
        final r = Random(spec.ops + spec.b.width);
        final cases = _mixed(spec.b.width, r, spec.ops, 0.5);
        final t = await _clocked(
          spec.b,
          cases,
          seed: 5,
          gap: 0.1,
          stall: 0.06,
          stallBurst: 80,
          killRate: 0.1,
          flushRate: 0.002,
        );
        _checkAll(cases, spec.b.width, t);
        final s = t.stats;
        final names = _namesOf(spec.b);
        printOnFailure(
          'slots $names hits ${s.hits} both ${s.both} out ${s.outReady} '
          'accept ${s.inAccept} take ${s.inTake} empty ${s.empty} '
          'flushes ${s.flushes} killed ${t.killed.length} '
          'taken ${t.taken.length} cycles ${t.cycles}',
        );
        for (var i = 0; i < names.length; i++) {
          expect(
            s.both[i],
            greaterThan(1),
            reason: 'kills on ${names[i]} with older and younger ops',
          );
          expect(
            s.hits[i],
            greaterThan(spec.min),
            reason: 'kills on ${names[i]}',
          );
        }
        expect(s.outReady, greaterThan(spec.min), reason: 'output kills');
        expect(s.inAccept, greaterThan(spec.min), reason: 'accept cycles');
        expect(s.inTake, greaterThan(spec.min), reason: 'take cycles');
        expect(s.empty, greaterThan(spec.min), reason: 'empty slots');
        expect(s.flushes, greaterThan(0));
        expect(t.killed.length, greaterThan(200));
        expect(t.taken.length, greaterThan(spec.ops ~/ 4));
      }, timeout: const Timeout(Duration(minutes: 6)));
    }

    // An older mul sits frozen in its own output slot, unconsumed, while a
    // younger iterative divide runs to completion and is killed right
    // where it holds its result. The mul must still come out afterward,
    // and no divide result must ever appear.
    for (final spec in [
      (
        name: 'mul iterative, older op held in mul',
        b: _build(32, mulMode: _iterative),
      ),
      (
        name: 'mul pipelined 3, older op held in mul_S',
        b: _build(32, mulStages: 3),
      ),
    ]) {
      test(
        'div_out killed while held, ${spec.name}',
        () async {
          final names = _namesOf(spec.b);
          final cases = <_Case>[
            (HarborIntOp.mul, BigInt.from(3), BigInt.from(4)),
            (HarborIntOp.div, BigInt.from(100000), BigInt.from(7)),
            (HarborIntOp.mul, BigInt.from(11), BigInt.from(12)),
          ];
          int? killCycle;
          final kill = _killOnce(names, 'div_out', 1);
          final t = await _clocked(
            spec.b,
            cases,
            gap: 0,
            killAt: (v) {
              final m = kill(v);
              if (m != 0) {
                killCycle = v.cycle;
              }
              return m;
            },
            readyAt: (v) => killCycle != null && v.cycle > killCycle!,
          );
          _checkAll(cases, 32, t);
          expect(t.killed, {1});
        },
        timeout: const Timeout(Duration(minutes: 1)),
      );
    }

    test(
      'flush drops every op in flight',
      () async {
        final r = Random(99);
        final cases = _genCases(32, r, 300);
        const flushes = {40, 90, 140, 200};
        final b = _build(32, mulMode: _iterative);
        final n = _slotsOf(b);
        final t = await _clocked(
          b,
          cases,
          gap: 0.1,
          stall: 0.2,
          killAt: (v) => flushes.contains(v.cycle) ? _onesMask(n) : 0,
        );
        _checkAll(cases, 32, t);
        for (final c in flushes) {
          // Only an op accepted in the flush cycle can be in a slot after it.
          expect(t.slotValids[c] & ~3, 0, reason: 'cycle ${c + 1} after flush');
        }
        expect(t.killed, isNotEmpty);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('killed iterative divide frees the engine at once', () async {
      final b = _build(32);
      final names = _namesOf(b);
      final cases = <_Case>[
        (HarborIntOp.div, BigInt.from(100000), BigInt.from(7)),
        (HarborIntOp.rem, BigInt.from(100000), BigInt.from(7)),
      ];
      int? killCycle;
      final kill = _killOnce(names, 'div_step', 0);
      final t = await _clocked(
        b,
        cases,
        gap: 0,
        stall: 0,
        killAt: (v) {
          final m = kill(v);
          if (m != 0) {
            killCycle = v.cycle;
          }
          return m;
        },
        validAt: (v) =>
            v.next == 0 || (killCycle != null && v.cycle > killCycle!),
      );
      _checkAll(cases, 32, t);
      expect(t.killed, {0});
      final k = t.stats.cycles.single;
      // slotValids[k] is what the harness saw in the cycle after the kill.
      expect(t.slotValids[k], 0, reason: 'slots empty after the kill');
      expect(t.acceptCycles[1], k + 1);
      expect(t.outCycles[1]! - t.acceptCycles[1]!, 36);
    });

    test('killed iterative multiply frees the engine at once', () async {
      final b = _build(32, mulMode: _iterative);
      final names = _namesOf(b);
      final cases = <_Case>[
        (HarborIntOp.mul, BigInt.from(1234), BigInt.from(77)),
        (HarborIntOp.mulhu, BigInt.from(-5) & _mask(32), BigInt.from(9)),
      ];
      int? killCycle;
      final kill = _killOnce(names, 'mul', 0);
      var seen = 0;
      final t = await _clocked(
        b,
        cases,
        gap: 0,
        stall: 0,
        killAt: (v) {
          // Kill in the middle of the shift and add steps.
          if (v.slotTags[0] == 0 && ++seen < 5) {
            return 0;
          }
          final m = kill(v);
          if (m != 0) {
            killCycle = v.cycle;
          }
          return m;
        },
        validAt: (v) =>
            v.next == 0 || (killCycle != null && v.cycle > killCycle!),
      );
      _checkAll(cases, 32, t);
      expect(t.killed, {0});
      final k = t.stats.cycles.single;
      expect(t.slotValids[k], 0, reason: 'engine empty after the kill');
      expect(t.acceptCycles[1], k + 1);
      expect(t.outCycles[1]! - t.acceptCycles[1]!, 17);
    });
  });

  group('shareRecurrence', () {
    // These tests drive the ROHD Simulator directly in the main isolate,
    // not through Isolate.run. If one times out, the test runner cancels
    // it without calling Simulator.endSimulation, which would leave the
    // simulator running for the next test in this isolate.
    tearDown(() async {
      await Simulator.reset();
    });

    test(
      'plumbing, busy and kills through the shared engine',
      () async {
        final width = 32;
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final flush = Logic(name: 'flush');
        final inValid = Logic(name: 'in_valid');
        final inOp = Logic(name: 'in_op', width: harborIntOpWidth);
        final inA = Logic(name: 'in_a', width: width);
        final inB = Logic(name: 'in_b', width: width);
        final inTag = Logic(name: 'in_tag', width: 8);
        final outReady = Logic(name: 'out_ready');
        final nDiv = HarborIntMulDiv.divSlotCountOf(_divIter, 1);
        final nSlots = HarborIntMulDiv.slotCountOf(_pipelined, 2, _divIter, 1);

        final sharedInValid = Logic(name: 'shared_in_valid');
        final sharedInOp = Logic(name: 'shared_in_op', width: 2);
        final sharedInA = Logic(name: 'shared_in_a', width: width);
        final sharedInB = Logic(name: 'shared_in_b', width: width);
        final sharedInTag = Logic(name: 'shared_in_tag', width: 9);
        final sharedOutReady = Logic(name: 'shared_out_ready');
        final sharedKill = Logic(name: 'shared_kill', width: nDiv);

        final recurrence = HarborDivSqrtRecurrence.integer(
          width,
          _divIter,
          2,
          1,
          clk: clk,
          reset: reset,
          killMask: sharedKill,
          inValid: sharedInValid,
          inOp: sharedInOp,
          inA: sharedInA,
          inB: sharedInB,
          inTag: sharedInTag,
          outReady: sharedOutReady,
        );

        final dut = HarborIntMulDiv(
          width: width,
          divMode: _divIter,
          divRadix: 2,
          divStages: 1,
          shareRecurrence: true,
          clk: clk,
          reset: reset,
          killMask: harborKillAll(flush, nSlots),
          inValid: inValid,
          inOp: inOp,
          inA: inA,
          inB: inB,
          inTag: inTag,
          outReady: outReady,
          sharedInReady: recurrence.inReady,
          sharedOutValid: recurrence.outValid,
          sharedOutResult: recurrence.outResult,
          sharedOutRemainder: recurrence.outRemainder,
          sharedOutTag: recurrence.outTag,
          sharedSlotValid: recurrence.slotValid,
        );
        sharedInValid <= dut.sharedInValid;
        sharedInOp <= dut.sharedInOp;
        sharedInA <= dut.sharedInA;
        sharedInB <= dut.sharedInB;
        sharedInTag <= dut.sharedInTag;
        sharedOutReady <= dut.sharedOutReady;
        sharedKill <= dut.sharedKillMask;

        await dut.build();
        await recurrence.build();

        final r = Random(3);
        final ops = <_Case>[
          for (var i = 0; i < 60; i++)
            (
              [HarborIntOp.div, HarborIntOp.remu, HarborIntOp.mul][r.nextInt(
                3,
              )],
              _randBits(r, width),
              _randBits(r, width),
            ),
        ];
        const flushes = {30, 95, 180, 300};

        reset.put(1);
        flush.put(0);
        inValid.put(0);
        outReady.put(1);
        unawaited(Simulator.run());
        await clk.nextNegedge;
        await clk.nextNegedge;
        reset.put(0);

        var next = 0;
        final inFlight = <int>[];
        final taken = <int>[];
        final errors = <String>[];
        var sawBusy = 0;
        var killedDiv = 0;
        var cycle = 0;
        while ((next < ops.length || inFlight.isNotEmpty) && cycle < 4000) {
          await clk.nextNegedge;
          cycle++;
          final doFlush = flushes.contains(cycle);
          final valid = next < ops.length;
          flush.put(doFlush ? 1 : 0);
          inValid.put(valid ? 1 : 0);
          if (valid) {
            final (op, a, b) = ops[next];
            inOp.put(op.index);
            inA.put(a);
            inB.put(b);
            inTag.put(next);
          }
          if (dut.busy.value.toBool()) {
            sawBusy++;
            if (recurrence.slotValid.value.toInt() == 0) {
              errors.add('cycle $cycle: busy with an empty engine');
            }
          }
          if (doFlush) {
            if (dut.busy.value.toBool()) {
              killedDiv++;
            }
            inFlight.clear();
            if (dut.outValid.value.toBool()) {
              errors.add('cycle $cycle: out_valid in a flush');
            }
          }
          if (dut.outValid.value.toBool()) {
            final tag = dut.outTag.value.toInt();
            if (inFlight.isEmpty || inFlight.first != tag) {
              errors.add('cycle $cycle: tag $tag out of order');
            } else {
              inFlight.removeAt(0);
            }
            final (op, a, b) = ops[tag];
            if (dut.outResult.value.toBigInt() != _oracle(op, a, b, width)) {
              errors.add('cycle $cycle: tag $tag $op wrong result');
            }
            taken.add(tag);
          }
          if (valid && dut.inReady.value.toBool()) {
            inFlight.add(next);
            next++;
          }
        }
        await Simulator.endSimulation();
        expect(errors, isEmpty, reason: errors.take(10).join('\n'));
        expect(inFlight, isEmpty);
        expect(sawBusy, greaterThan(100));
        expect(killedDiv, greaterThan(0));
        expect(taken.length, greaterThan(40));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('per-slot kills, out_ready stalls and FP-side traffic on the shared '
        'engine', () async {
      // A second ("FP") side sharing the recurrence: it issues only while
      // dut.busy is low and never sets a kill bit of its own, since kill
      // ownership flows through dut's shared_kill_mask. FP wins any tie.
      final width = 32;
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final nDiv = HarborIntMulDiv.divSlotCountOf(_divIter, 1);
      final nSlots = HarborIntMulDiv.slotCountOf(_pipelined, 2, _divIter, 1);

      final killMask = Logic(name: 'kill_mask', width: nSlots);
      final inValid = Logic(name: 'in_valid');
      final inOp = Logic(name: 'in_op', width: harborIntOpWidth);
      final inA = Logic(name: 'in_a', width: width);
      final inB = Logic(name: 'in_b', width: width);
      final inTag = Logic(name: 'in_tag', width: 8);
      final outReady = Logic(name: 'out_ready');

      final dutSharedInReady = Logic(name: 'dut_shared_in_ready');
      final recInValid = Logic(name: 'rec_in_valid');
      final recInOp = Logic(name: 'rec_in_op', width: 2);
      final recInA = Logic(name: 'rec_in_a', width: width);
      final recInB = Logic(name: 'rec_in_b', width: width);
      final recInTag = Logic(name: 'rec_in_tag', width: 9);
      final recOutReady = Logic(name: 'rec_out_ready');
      final sharedKill = Logic(name: 'shared_kill', width: nDiv);

      final recurrence = HarborDivSqrtRecurrence.integer(
        width,
        _divIter,
        2,
        1,
        clk: clk,
        reset: reset,
        killMask: sharedKill,
        inValid: recInValid,
        inOp: recInOp,
        inA: recInA,
        inB: recInB,
        inTag: recInTag,
        outReady: recOutReady,
      );

      final dut = HarborIntMulDiv(
        width: width,
        divMode: _divIter,
        divRadix: 2,
        divStages: 1,
        shareRecurrence: true,
        clk: clk,
        reset: reset,
        killMask: killMask,
        inValid: inValid,
        inOp: inOp,
        inA: inA,
        inB: inB,
        inTag: inTag,
        outReady: outReady,
        sharedInReady: dutSharedInReady,
        sharedOutValid: recurrence.outValid,
        sharedOutResult: recurrence.outResult,
        sharedOutRemainder: recurrence.outRemainder,
        sharedOutTag: recurrence.outTag,
        sharedSlotValid: recurrence.slotValid,
      );
      sharedKill <= dut.sharedKillMask;

      await dut.build();
      await recurrence.build();

      final r = Random(11);
      final tagW = inTag.width;
      final mulSlots = dut.mulSlots;
      final ops = <_Case>[
        for (var i = 0; i < 160; i++)
          (
            [HarborIntOp.div, HarborIntOp.remu, HarborIntOp.mul][r.nextInt(3)],
            _randBits(r, width),
            _randBits(r, width),
          ),
      ];

      reset.put(1);
      killMask.put(0);
      inValid.put(0);
      outReady.put(1);
      recInValid.put(0);
      recOutReady.put(0);
      dutSharedInReady.put(0);
      unawaited(Simulator.run());
      await clk.nextNegedge;
      await clk.nextNegedge;
      reset.put(0);

      var next = 0;
      final inFlight = <int>[];
      final killed = <int>{};
      final taken = <int>[];
      final errors = <String>[];
      var sawBusy = 0;
      var divSlotKills = 0;
      var fpGrants = 0;
      var fpDrains = 0;
      var fpBusy = false;
      var fpTag = 1000;
      var cycle = 0;

      while ((next < ops.length || inFlight.isNotEmpty) && cycle < 12000) {
        await clk.nextNegedge;
        cycle++;

        final sv = dut.slotValid.value.toInt();
        final st = dut.slotTag.value;
        final tags = [
          for (var i = 0; i < nSlots; i++)
            (sv >> i) & 1 == 1
                ? st.getRange(i * tagW, (i + 1) * tagW).toInt()
                : -1,
        ];

        final valid = next < ops.length;
        inValid.put(valid ? 1 : 0);
        if (valid) {
          final (op, a, b) = ops[next];
          inOp.put(op.index);
          inA.put(a);
          inB.put(b);
          inTag.put(next);
        }

        // Mostly a single random slot, sometimes a random subset.
        final mask = r.nextDouble() < 0.15
            ? (r.nextInt(4) == 0
                  ? r.nextInt(1 << nSlots)
                  : 1 << r.nextInt(nSlots))
            : 0;
        killMask.put(mask);
        outReady.put(r.nextDouble() >= 0.3 ? 1 : 0);
        final ready = outReady.value.toBool();

        for (var i = 0; i < nSlots; i++) {
          if ((mask >> i) & 1 == 0 || tags[i] < 0) {
            continue;
          }
          if (i >= mulSlots) {
            divSlotKills++;
          }
          if (inFlight.remove(tags[i])) {
            killed.add(tags[i]);
          }
        }

        if (dut.busy.value.toBool()) {
          sawBusy++;
          if (recurrence.slotValid.value.toInt() == 0) {
            errors.add('cycle $cycle: busy with an empty engine');
          }
        }

        // Arbitrate the engine between dut and the FP model: dut must
        // not see shared_in_ready while the FP model owns the engine or
        // wins this cycle's tie, and the FP model must not issue while
        // dut.busy is high.
        final engineReady = recurrence.inReady.value.toBool();
        final fpWant = !fpBusy && r.nextDouble() < 0.2;
        final fpGrant = fpWant && engineReady && !dut.busy.value.toBool();
        final dutGranted = engineReady && !fpBusy && !fpGrant;
        dutSharedInReady.put(dutGranted ? 1 : 0);

        if (fpGrant) {
          fpGrants++;
          fpTag++;
          recInValid.put(1);
          recInOp.put(r.nextBool() ? 1 : 0);
          recInA.put(_randBits(r, width));
          recInB.put(_randBits(r, width));
          recInTag.put(fpTag & 0x1ff);
        } else if (dutGranted) {
          // Forward dut's request to the engine only on a cycle it is
          // actually granted; sharedInValid is a standing request, so
          // forwarding it unconditionally would accept a ghost copy.
          recInValid.put(dut.sharedInValid.value);
          recInOp.put(dut.sharedInOp.value);
          recInA.put(dut.sharedInA.value);
          recInB.put(dut.sharedInB.value);
          recInTag.put(dut.sharedInTag.value);
        } else {
          recInValid.put(0);
        }
        // The FP model never kills, so it always drains as soon as its
        // result is up; dut's own out_ready need carries its own share.
        recOutReady.put(fpBusy ? 1 : dut.sharedOutReady.value);

        if (fpBusy && recurrence.outValid.value.toBool()) {
          fpBusy = false;
          fpDrains++;
        }
        if (fpGrant) {
          fpBusy = true;
        }

        if (dut.outValid.value.toBool() && ready) {
          final tag = dut.outTag.value.toInt();
          if (killed.contains(tag)) {
            errors.add('cycle $cycle: killed tag $tag came out');
          } else if (inFlight.isEmpty || inFlight.first != tag) {
            errors.add('cycle $cycle: tag $tag out of order');
          } else {
            inFlight.removeAt(0);
            final (op, a, b) = ops[tag];
            if (dut.outResult.value.toBigInt() != _oracle(op, a, b, width)) {
              errors.add('cycle $cycle: tag $tag $op wrong result');
            }
          }
          taken.add(tag);
        }
        if (valid && dut.inReady.value.toBool()) {
          inFlight.add(next);
          next++;
        }
      }
      await Simulator.endSimulation();
      expect(errors, isEmpty, reason: errors.take(10).join('\n'));
      expect(inFlight, isEmpty);
      expect(sawBusy, greaterThan(50));
      expect(divSlotKills, greaterThan(0));
      expect(fpGrants, greaterThan(5));
      expect(fpDrains, greaterThan(5));
      expect(killed, isNotEmpty);
      expect(taken.length, greaterThan(30));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
