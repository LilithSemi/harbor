import 'dart:async';
import 'dart:math';

import 'package:harbor/src/arith/fp_format.dart';
import 'package:harbor/src/arith/fpu.dart';
import 'package:harbor/src/arith/fpu_config.dart';
import 'package:rohd/rohd.dart';

import 'fp_model.dart';
import 'lane_sim.dart';

/// One op for a HarborFpu port: the value of each input field, without the
/// port prefix, and the result the model gives.
class FpuCase {
  final Map<String, BigInt> fields;
  final FpResult expect;
  final String label;
  const FpuCase(this.fields, this.expect, this.label);

  @override
  String toString() =>
      '$label ${fields.map((k, v) => MapEntry(k, v.toRadixString(16)))}';
}

BigInt _bits(Random r, int n) {
  var v = BigInt.zero;
  for (var i = 0; i < n; i += 16) {
    v = (v << 16) | BigInt.from(r.nextInt(1 << 16));
  }
  return v & ((BigInt.one << n) - BigInt.one);
}

BigInt _pack(HarborFpFormat f, int sign, int exp, BigInt mant) =>
    (BigInt.from(sign) << (f.width - 1)) |
    (BigInt.from(exp) << f.mantissaWidth) |
    mant;

/// A value of [f] weighted to zeros, subnormals, Inf, NaN and the exponent
/// ends. With [intRange] the exponent is often in the integer range.
BigInt fpValue(HarborFpFormat f, Random r, {bool intRange = false}) {
  final m = f.mantissaWidth;
  final emax = (1 << f.exponentWidth) - 1;
  final s = r.nextInt(2);
  final mant = _bits(r, m);
  if (intRange && r.nextBool()) {
    final e = (f.bias + r.nextInt(74) - 3).clamp(1, emax - 1);
    return _pack(f, s, e, mant);
  }
  return switch (r.nextInt(16)) {
    0 => _pack(f, s, 0, BigInt.zero),
    1 => _pack(f, s, emax, BigInt.zero),
    2 => _pack(f, s, emax, mant | (BigInt.one << (m - 1))),
    3 => _pack(
      f,
      s,
      emax,
      (mant & ((BigInt.one << (m - 1)) - BigInt.one)) | BigInt.one,
    ),
    4 || 5 => _pack(f, s, 0, mant == BigInt.zero ? BigInt.one : mant),
    6 => _pack(f, s, r.nextBool() ? 1 : emax - 1, mant),
    7 => _pack(
      f,
      s,
      1 + r.nextInt(emax - 1),
      r.nextBool() ? BigInt.zero : (BigInt.one << m) - BigInt.one,
    ),
    _ => _pack(f, s, (f.bias + r.nextInt(81) - 40).clamp(1, emax - 1), mant),
  };
}

/// [v] with random bits above [low] up to [width].
BigInt noise(Random r, BigInt v, int low, int width) {
  if (low >= width || r.nextBool()) {
    return v;
  }
  return (_bits(r, width - low) << low) | v;
}

/// The model result of a main pipe op of [config].
FpResult fpuModel(
  HarborFpuConfig config,
  HarborFpOp op, {
  required int fmt,
  int fmtDst = 0,
  int fmtNarrow = 0,
  required int rm,
  required BigInt a,
  required BigInt b,
  required BigInt c,
  int liIndex = 0,
  bool intSigned = false,
  int intWidth = 0,
}) {
  final f = config.formats[fmt];
  BigInt lo(BigInt x, HarborFpFormat g) =>
      x & ((BigInt.one << g.width) - BigInt.one);
  final fa = lo(a, f);
  final fb = lo(b, f);
  final ftz = config.ftz;
  const fmaFamily = {
    HarborFpOp.madd,
    HarborFpOp.msub,
    HarborFpOp.nmsub,
    HarborFpOp.nmadd,
  };
  if (fmtNarrow != 0 && (fmaFamily.contains(op) || op == HarborFpOp.mul)) {
    final (n, w) = config.widening[fmtNarrow - 1];
    final na = lo(a, n);
    final nb = lo(b, n);
    if (op == HarborFpOp.mul) {
      final z = rm == rmRdn ? BigInt.zero : BigInt.one << (w.width - 1);
      return fpFma(n, w, na, nb, z, rm, ftz: ftz);
    }
    return fpFma(
      n,
      w,
      na,
      nb,
      lo(c, w),
      rm,
      negProduct: op == HarborFpOp.nmsub || op == HarborFpOp.nmadd,
      negAddend: op == HarborFpOp.msub || op == HarborFpOp.nmadd,
      ftz: ftz,
    );
  }
  final fc = lo(c, f);
  return switch (op) {
    HarborFpOp.add => fpAdd(f, fa, fb, rm, ftz: ftz),
    HarborFpOp.sub => fpSub(f, fa, fb, rm, ftz: ftz),
    HarborFpOp.mul => fpMul(f, fa, fb, rm, ftz: ftz),
    HarborFpOp.madd ||
    HarborFpOp.msub ||
    HarborFpOp.nmsub ||
    HarborFpOp.nmadd => fpFma(
      f,
      f,
      fa,
      fb,
      fc,
      rm,
      negProduct: op == HarborFpOp.nmsub || op == HarborFpOp.nmadd,
      negAddend: op == HarborFpOp.msub || op == HarborFpOp.nmadd,
      ftz: ftz,
    ),
    HarborFpOp.eq => fpCompare(f, fa, fb, FpCompareKind.eq, ftz: ftz),
    HarborFpOp.lt => fpCompare(f, fa, fb, FpCompareKind.lt, ftz: ftz),
    HarborFpOp.le => fpCompare(f, fa, fb, FpCompareKind.le, ftz: ftz),
    HarborFpOp.ltq => fpCompare(f, fa, fb, FpCompareKind.ltq, ftz: ftz),
    HarborFpOp.leq => fpCompare(f, fa, fb, FpCompareKind.leq, ftz: ftz),
    HarborFpOp.min => fpMin(f, fa, fb, ftz: ftz),
    HarborFpOp.max => fpMax(f, fa, fb, ftz: ftz),
    HarborFpOp.minm => fpMinM(f, fa, fb, ftz: ftz),
    HarborFpOp.maxm => fpMaxM(f, fa, fb, ftz: ftz),
    HarborFpOp.classify => fpClass(f, fa),
    HarborFpOp.sgnj => fpSgnj(f, fa, fb, FpSgnjKind.inject),
    HarborFpOp.sgnjn => fpSgnj(f, fa, fb, FpSgnjKind.negate),
    HarborFpOp.sgnjx => fpSgnj(f, fa, fb, FpSgnjKind.xor),
    HarborFpOp.fpToFp => fpToFp(f, config.formats[fmtDst], fa, rm, ftz: ftz),
    HarborFpOp.fpToInt => fpToInt(
      f,
      fa,
      config.intWidths[intWidth],
      intSigned,
      rm,
      ftz: ftz,
    ),
    HarborFpOp.intToFp => intToFp(
      f,
      a,
      config.intWidths[intWidth],
      intSigned,
      rm,
    ),
    HarborFpOp.cvtModWD => fpCvtModWD(fa, ftz: ftz),
    HarborFpOp.li => fpLi(f, liIndex),
    HarborFpOp.round => fpRound(f, fa, rm, ftz: ftz),
    HarborFpOp.roundNx => fpRound(f, fa, rm, exact: true, ftz: ftz),
    HarborFpOp.rec7 => fpRec7(f, fa, rm, ftz: ftz),
    HarborFpOp.rsqrt7 => fpRsqrt7(f, fa, ftz: ftz),
    HarborFpOp.div => fpDiv(f, fa, fb, rm, ftz: ftz),
    HarborFpOp.sqrt => fpSqrt(f, fa, rm, ftz: ftz),
  };
}

/// A random main pipe op of [config], from [ops] or every main pipe op.
FpuCase mainCase(HarborFpuConfig config, Random r, {List<HarborFpOp>? ops}) {
  final pool =
      ops ?? config.ops.where((o) => !harborFpDivOps.contains(o)).toList();
  final op = pool[r.nextInt(pool.length)];
  final formats = config.formats;
  final opW = config.widest.width;
  final ints = config.intWidths;
  final dataW = max(opW, ints.isEmpty ? 0 : ints.reduce(max));
  var fmt = r.nextInt(formats.length);
  if (op == HarborFpOp.cvtModWD) {
    fmt = formats.indexOf(HarborFpFormat.fp64);
  }
  final fmtDst = r.nextInt(formats.length);
  final rm = r.nextInt(5);
  final liIndex = r.nextInt(32);
  final intSigned = r.nextBool();
  final intWidth = ints.isEmpty ? 0 : r.nextInt(ints.length);
  const narrowOps = {
    HarborFpOp.mul,
    HarborFpOp.madd,
    HarborFpOp.msub,
    HarborFpOp.nmsub,
    HarborFpOp.nmadd,
  };
  final pairs = config.widening.length;
  var fmtNarrow = pairs == 0 ? 0 : r.nextInt(pairs + 1);
  if (narrowOps.contains(op) && pairs > 0) {
    fmtNarrow = r.nextInt(4) == 0 ? 1 + r.nextInt(pairs) : 0;
  }
  final narrow = fmtNarrow != 0 && narrowOps.contains(op);
  final fab = narrow ? config.widening[fmtNarrow - 1].$1 : formats[fmt];
  final fc = narrow ? config.widening[fmtNarrow - 1].$2 : formats[fmt];
  const intRangeOps = {
    HarborFpOp.fpToInt,
    HarborFpOp.cvtModWD,
    HarborFpOp.round,
    HarborFpOp.roundNx,
  };
  final ir = intRangeOps.contains(op);
  var a = fpValue(fab, r, intRange: ir);
  var b = fpValue(fab, r);
  var c = fpValue(fc, r);
  if (op == HarborFpOp.intToFp) {
    a = switch (r.nextInt(3)) {
      0 =>
        BigInt.from(r.nextInt(1 << 20) - (1 << 19)) &
            ((BigInt.one << dataW) - BigInt.one),
      _ => _bits(r, dataW),
    };
  }
  if (!narrow &&
      {
        HarborFpOp.madd,
        HarborFpOp.msub,
        HarborFpOp.nmsub,
        HarborFpOp.nmadd,
      }.contains(op) &&
      r.nextInt(4) == 0) {
    // An addend near the product, for cancellation.
    final p = fpMul(fc, a, b, rm).bits;
    final flip = op == HarborFpOp.madd || op == HarborFpOp.nmadd;
    c = flip ? p ^ (BigInt.one << (fc.width - 1)) : p;
  }
  final expect = fpuModel(
    config,
    op,
    fmt: fmt,
    fmtDst: fmtDst,
    fmtNarrow: fmtNarrow,
    rm: rm,
    a: a,
    b: b,
    c: c,
    liIndex: liIndex,
    intSigned: intSigned,
    intWidth: intWidth,
  );
  if (op != HarborFpOp.intToFp) {
    a = noise(r, a, fab.width, dataW);
  }
  return FpuCase(
    {
      'op': BigInt.from(op.index),
      'fmt': BigInt.from(fmt),
      'fmt_dst': BigInt.from(fmtDst),
      'fmt_narrow': BigInt.from(fmtNarrow),
      'rm': BigInt.from(rm),
      'a': a,
      'b': noise(r, b, fab.width, opW),
      'c': noise(r, c, fc.width, opW),
      'li_index': BigInt.from(liIndex),
      'int_signed': BigInt.from(intSigned ? 1 : 0),
      'int_width': BigInt.from(intWidth),
    },
    expect,
    '${op.name} ${formats[fmt]}${narrow ? ' narrow $fmtNarrow' : ''} rm$rm',
  );
}

/// A random op for the div port of [config].
FpuCase divCase(HarborFpuConfig config, Random r) {
  final pool = config.ops.intersection(harborFpDivOps).toList();
  final op = pool[r.nextInt(pool.length)];
  final fmt = r.nextInt(config.formats.length);
  final f = config.formats[fmt];
  final rm = r.nextInt(5);
  final a = fpValue(f, r);
  final b = fpValue(f, r);
  final opW = config.widest.width;
  return FpuCase(
    {
      'op': BigInt.from(op.index),
      'fmt': BigInt.from(fmt),
      'rm': BigInt.from(rm),
      'a': noise(r, a, f.width, opW),
      'b': noise(r, b, f.width, opW),
    },
    fpuModel(config, op, fmt: fmt, rm: rm, a: a, b: b, c: BigInt.zero),
    '${op.name} $f rm$rm',
  );
}

/// Drives a built [HarborFpu], one lane per bench lane.
abstract class FpuDriver {
  int get lanes;
  bool has(String port);
  int width(String port);
  void put(String port, List<BigInt> perLane);
  void putMask(String port, int mask);

  /// Settles the logic after the inputs change.
  void eval();
  int mask(String port);
  List<BigInt> read(String port);

  /// [read] with unknown bits as zero, for registers that start unknown.
  List<BigInt> readLoose(String port) => read(port);

  /// One clock edge.
  Future<void> tick();
  Future<void> done() async {}
}

/// [FpuDriver] on [LaneSim]: 64 lanes, each its own bench. [module] is a
/// built [HarborFpu] or any module with the same port names.
class LaneDriver extends FpuDriver {
  final Module module;
  HarborFpu get dut => module as HarborFpu;
  late final LaneSim sim;

  LaneDriver(this.module) {
    sim = LaneSim(
      module,
      [
        for (final e in module.inputs.entries)
          if (e.key != 'clk') e.value,
      ],
      module.outputs.values.toList(),
      clock: module.input('clk'),
    );
  }

  @override
  int get lanes => LaneSim.lanes;
  @override
  bool has(String port) =>
      module.inputs.containsKey(port) || module.outputs.containsKey(port);
  @override
  int width(String port) =>
      (module.inputs[port] ?? module.outputs[port]!).width;
  @override
  void put(String port, List<BigInt> perLane) =>
      sim.set(module.input(port), perLane);
  @override
  void putMask(String port, int mask) => sim.setMask(module.input(port), mask);
  @override
  void eval() => sim.run();
  @override
  int mask(String port) => sim.getMask(module.output(port));
  @override
  List<BigInt> read(String port) => sim.get(module.output(port), lanes);
  @override
  Future<void> tick() async => sim.clock();
}

/// [FpuDriver] on the ROHD simulator: one lane. Call [done] before
/// `Simulator.reset`, else the running simulator writes to closed streams.
class RohdDriver extends FpuDriver {
  final Module module;
  HarborFpu get dut => module as HarborFpu;
  final Map<String, Logic> _src = {};
  late final Logic clk;

  RohdDriver._(this.module);

  /// Connects and builds [module], and starts the simulator.
  static Future<RohdDriver> start(Module module) async {
    final d = RohdDriver._(module);
    d.clk = SimpleClockGenerator(10).clk;
    for (final e in module.inputs.entries) {
      final s = e.key == 'clk'
          ? d.clk
          : (Logic(name: 'tb_${e.key}', width: e.value.width)..put(0));
      d._src[e.key] = s;
      e.value.srcConnection! <= s;
    }
    await module.build();
    unawaited(Simulator.run());
    await d.clk.nextNegedge;
    return d;
  }

  @override
  int get lanes => 1;
  @override
  bool has(String port) =>
      module.inputs.containsKey(port) || module.outputs.containsKey(port);
  @override
  int width(String port) =>
      (module.inputs[port] ?? module.outputs[port]!).width;
  @override
  void put(String port, List<BigInt> perLane) =>
      _src[port]!.put(perLane.isEmpty ? BigInt.zero : perLane.first);
  @override
  void putMask(String port, int mask) => _src[port]!.put(mask & 1);
  @override
  void eval() {}
  @override
  int mask(String port) {
    final v = module.output(port).value;
    if (!v.isValid) {
      throw StateError('$port is $v');
    }
    return v.toInt();
  }

  @override
  List<BigInt> read(String port) => [module.output(port).value.toBigInt()];
  @override
  List<BigInt> readLoose(String port) {
    final v = module.output(port).value;
    var x = BigInt.zero;
    for (var i = v.width - 1; i >= 0; i--) {
      x = (x << 1) | (v[i] == LogicValue.one ? BigInt.one : BigInt.zero);
    }
    return [x];
  }

  @override
  Future<void> tick() => clk.nextNegedge;
  @override
  Future<void> done() => Simulator.endSimulation();
}

/// A result taken from a port: the tag, the value and the cycle.
typedef FpuOut = ({int tag, BigInt result, int flags, int cycle});

/// The record of one lane of one port.
class LaneLog {
  final accepts = <({int tag, int cycle})>[];
  final outs = <FpuOut>[];

  /// Cycles with a nonzero kill mask.
  final kills = <int>[];

  /// Tags of the ops that a kill dropped.
  final killed = <int>{};

  /// `out_valid & ~out_ready` cycles with the tag and value seen.
  final held = <({int cycle, int tag, BigInt value})>[];
}

/// Kill events seen on a port, summed over all lanes.
class KillStats {
  /// Kills of a valid op, per slot.
  final List<int> hits;

  /// Kills of a valid op in a slot with valid ops on both sides. A slot at
  /// an end counts when some other slot is valid.
  final List<int> between;

  /// Mask bits on empty slots.
  var emptyHits = 0;

  /// Kills of the op at the output in a cycle with `out_ready` high.
  var outReadyKills = 0;

  /// Kill cycles with an accept on the input.
  var acceptKills = 0;

  /// Kill cycles with a take at the output.
  var takeKills = 0;

  /// Cycles with every mask bit set.
  var flushes = 0;

  KillStats(int slots)
    : hits = List.filled(slots, 0),
      between = List.filled(slots, 0);

  @override
  String toString() =>
      'hits $hits between $between empty $emptyHits outReady $outReadyKills '
      'accept $acceptKills take $takeKills flush $flushes';
}

/// A port of the bench: `''` for the main pipe or `'div_'`.
class FpuPort {
  final String prefix;
  final List<List<FpuCase>> cases;

  /// Chance that `out_ready` is low in a cycle.
  final double readyLow;

  /// Chance that `in_valid` is low in a cycle.
  final double validGap;

  /// Chance per cycle and lane of a kill on some slots of this port. Most
  /// of these kill one slot, picked at random, the rest a random set.
  final double slotKillRate;
  final List<LaneLog> logs;
  KillStats? stats;

  FpuPort(
    this.prefix,
    this.cases, {
    this.readyLow = 0.3,
    this.validGap = 0,
    this.slotKillRate = 0,
  }) : logs = [for (final _ in cases) LaneLog()];
}

/// Per cycle observer: cycle, port, `in_ready` mask, `out_valid` mask.
typedef CycleHook = void Function(int cycle, FpuPort p, int inReady, int outV);

/// Runs [ports] together on [d] until every case is out or killed, or
/// [maxCycles]. [flushRate] is the chance per cycle and lane that every
/// kill mask bit of every port is set, as an in-order flush. The tag of a
/// case is its index in its lane.
Future<int> runBench(
  FpuDriver d,
  List<FpuPort> ports, {
  required Random random,
  double flushRate = 0,
  int maxCycles = 20000,
  int resetCycles = 2,
  CycleHook? hook,
  int Function(int cycle, FpuPort p)? readyMask,
  int Function(int cycle, FpuPort p)? validMask,
  List<int> Function(int cycle, FpuPort p)? killMask,
}) async {
  final lanes = d.lanes;
  // Random draws only for lanes with cases, so a one lane LaneSim run and a
  // ROHD run see the same stimulus.
  final used = ports.map((p) => p.cases.length).reduce(max);
  final all = (lanes == 64) ? -1 : (1 << lanes) - 1;
  final slots = [
    for (final p in ports)
      d.has('${p.prefix}kill_mask') ? d.width('${p.prefix}kill_mask') : 0,
  ];
  final tagW = [
    for (final p in ports)
      d.has('${p.prefix}in_tag') ? d.width('${p.prefix}in_tag') : 0,
  ];
  for (var pi = 0; pi < ports.length; pi++) {
    ports[pi].stats = KillStats(slots[pi]);
  }
  void putKill(int pi, List<int> perLane) {
    if (slots[pi] > 0) {
      d.put('${ports[pi].prefix}kill_mask', [
        for (var l = 0; l < lanes; l++)
          BigInt.from(l < perLane.length ? perLane[l] : 0),
      ]);
    }
  }

  d.putMask('reset', all);
  for (var pi = 0; pi < ports.length; pi++) {
    final p = ports[pi];
    d.putMask('${p.prefix}in_valid', 0);
    d.putMask('${p.prefix}out_ready', 0);
    putKill(pi, const []);
  }
  for (var i = 0; i < resetCycles; i++) {
    d.eval();
    await d.tick();
  }
  d.putMask('reset', 0);
  final next = [for (final p in ports) List.filled(p.cases.length, 0)];
  final fieldNames = [
    for (final p in ports)
      {
        for (final c in p.cases.expand((l) => l))
          for (final k in c.fields.keys)
            if (d.has('${p.prefix}in_$k')) k,
      }.toList(),
  ];
  var cycle = 0;
  var moved = 0;
  for (; cycle < maxCycles; cycle++) {
    // A bench with no handshake for a long time has lost an op.
    if (cycle - moved > 500) {
      break;
    }
    // More results than ops is a duplicate. Stop and let the check fail.
    if (ports.any((p) => p.logs.any((g) => g.outs.length > g.accepts.length))) {
      break;
    }
    var busy = false;
    for (var pi = 0; pi < ports.length; pi++) {
      final p = ports[pi];
      for (var l = 0; l < p.cases.length; l++) {
        final g = p.logs[l];
        if (next[pi][l] < p.cases[l].length ||
            g.outs.length + g.killed.length < g.accepts.length) {
          busy = true;
        }
      }
    }
    if (!busy) {
      break;
    }
    var flush = 0;
    for (var l = 0; l < used; l++) {
      if (flushRate > 0 && random.nextDouble() < flushRate) {
        flush |= 1 << l;
      }
    }
    final valid = <int>[];
    final ready = <int>[];
    final masks = <List<int>>[];
    for (var pi = 0; pi < ports.length; pi++) {
      final p = ports[pi];
      final n = slots[pi];
      final full = (1 << n) - 1;
      var v = 0;
      var rd = 0;
      final km = List.filled(used, 0);
      for (var l = 0; l < used; l++) {
        final has = l < p.cases.length && next[pi][l] < p.cases[l].length;
        final gap = p.validGap > 0 && random.nextDouble() < p.validGap;
        if (has && !gap) {
          v |= 1 << l;
        }
        if (random.nextDouble() >= p.readyLow) {
          rd |= 1 << l;
        }
        if (n > 0 && p.slotKillRate > 0) {
          if (random.nextDouble() < p.slotKillRate) {
            km[l] = random.nextInt(4) == 0
                ? random.nextInt(full + 1)
                : 1 << random.nextInt(n);
          }
        }
        if (flush >> l & 1 != 0) {
          km[l] = full;
        }
      }
      if (validMask != null) {
        v &= validMask(cycle, p);
      }
      if (readyMask != null) {
        rd = readyMask(cycle, p);
      }
      if (killMask != null) {
        final k = killMask(cycle, p);
        for (var l = 0; l < used && l < k.length; l++) {
          km[l] |= k[l];
        }
      }
      valid.add(v);
      ready.add(rd);
      masks.add(km);
      d.putMask('${p.prefix}in_valid', v);
      d.putMask('${p.prefix}out_ready', rd);
      putKill(pi, km);
      for (final name in fieldNames[pi]) {
        d.put('${p.prefix}in_$name', [
          for (var l = 0; l < lanes; l++)
            l < p.cases.length && next[pi][l] < p.cases[l].length
                ? p.cases[l][next[pi][l]].fields[name]!
                : BigInt.zero,
        ]);
      }
      if (tagW[pi] > 0) {
        d.put('${p.prefix}in_tag', [
          for (var l = 0; l < lanes; l++)
            BigInt.from(l < p.cases.length ? next[pi][l] : 0),
        ]);
      }
    }
    d.eval();
    for (var pi = 0; pi < ports.length; pi++) {
      final p = ports[pi];
      final n = slots[pi];
      final km = masks[pi];
      final st = p.stats!;
      final inReady = d.mask('${p.prefix}in_ready');
      final outV = d.mask('${p.prefix}out_valid');
      hook?.call(cycle, p, inReady, outV);
      final acc = valid[pi] & inReady;
      final take = outV & ready[pi];
      final anyKill = km.any((k) => k != 0);
      if (acc != 0 || take != 0 || anyKill) {
        moved = cycle;
      }
      final stall = outV & ~ready[pi];
      List<BigInt>? res;
      List<BigInt>? flags;
      List<BigInt>? tags;
      if (take != 0 || stall != 0) {
        res = d.read('${p.prefix}out_result');
        flags = d.read('${p.prefix}out_flags');
        tags = d.read('${p.prefix}out_tag');
      }
      List<BigInt>? slotValid;
      List<BigInt>? slotTag;
      if (anyKill) {
        if (tagW[pi] == 0) {
          throw StateError('${p.prefix}kill needs tags to check');
        }
        slotValid = d.read('${p.prefix}slot_valid');
        slotTag = d.readLoose('${p.prefix}slot_tag');
      }
      for (var l = 0; l < p.cases.length; l++) {
        final log = p.logs[l];
        final k = km[l];
        if (k != 0) {
          log.kills.add(cycle);
          final sv = slotValid![l].toInt();
          if (k == (1 << n) - 1) {
            st.flushes++;
          }
          if (acc >> l & 1 != 0) {
            st.acceptKills++;
          }
          if (take >> l & 1 != 0) {
            st.takeKills++;
          }
          if (k >> (n - 1) & 1 != 0 &&
              sv >> (n - 1) & 1 != 0 &&
              ready[pi] >> l & 1 != 0) {
            st.outReadyKills++;
          }
          for (var i = 0; i < n; i++) {
            if (k >> i & 1 == 0) {
              continue;
            }
            if (sv >> i & 1 == 0) {
              st.emptyHits++;
              continue;
            }
            st.hits[i]++;
            final younger = sv & ((1 << i) - 1);
            final older = sv >> (i + 1);
            final ends = i == 0 || i == n - 1;
            if (ends ? (younger | older) != 0 : younger != 0 && older != 0) {
              st.between[i]++;
            }
            final w = tagW[pi];
            log.killed.add(
              ((slotTag![l] >> (i * w)) & ((BigInt.one << w) - BigInt.one))
                  .toInt(),
            );
          }
        }
        if (acc >> l & 1 != 0) {
          log.accepts.add((tag: next[pi][l], cycle: cycle));
          next[pi][l]++;
        }
        if (take >> l & 1 != 0) {
          log.outs.add((
            tag: tags![l].toInt(),
            result: res![l],
            flags: flags![l].toInt(),
            cycle: cycle,
          ));
        }
        if (stall >> l & 1 != 0) {
          log.held.add((cycle: cycle, tag: tags![l].toInt(), value: res![l]));
        }
      }
    }
    await d.tick();
  }
  return cycle;
}

/// Checks one lane of [p]: the results are the accepted ops less the
/// killed ones, each once, in order, with the model result and flags. No
/// result comes out less than [latency] cycles after its accept, and a held
/// result does not change before it is taken. Returns the number of killed
/// ops.
int checkLane(FpuPort p, int l, {int? latency}) {
  final log = p.logs[l];
  final cases = p.cases[l];
  final acceptAt = {for (final a in log.accepts) a.tag: a.cycle};
  for (final t in log.killed) {
    if (!acceptAt.containsKey(t)) {
      throw StateError('lane $l: killed tag $t was never accepted');
    }
  }
  final want = [
    for (final a in log.accepts)
      if (!log.killed.contains(a.tag)) a.tag,
  ];
  final got = [for (final o in log.outs) o.tag];
  for (var i = 0; i < got.length; i++) {
    if (log.killed.contains(got[i])) {
      throw StateError('lane $l: killed tag ${got[i]} came out');
    }
    if (i >= want.length || got[i] != want[i]) {
      throw StateError(
        'lane $l: out $i is tag ${got[i]}, expected '
        '${i < want.length ? want[i] : 'nothing'}',
      );
    }
  }
  if (got.length != want.length) {
    throw StateError('lane $l: ${got.length} of ${want.length} ops out');
  }
  for (final o in log.outs) {
    final at = acceptAt[o.tag]!;
    if (latency != null && o.cycle - at < latency) {
      throw StateError('lane $l: tag ${o.tag} out after ${o.cycle - at}');
    }
    final e = cases[o.tag].expect;
    if (o.result != e.bits || o.flags != e.flags) {
      throw StateError(
        'lane $l: ${cases[o.tag]}: got ${o.result.toRadixString(16)} '
        'flags ${o.flags.toRadixString(16)}, expected $e',
      );
    }
  }
  // A held result stays until it is taken, unless it is killed.
  var oi = 0;
  for (final h in log.held) {
    while (oi < log.outs.length && log.outs[oi].cycle < h.cycle) {
      oi++;
    }
    if (log.killed.contains(h.tag)) {
      continue;
    }
    if (oi == log.outs.length ||
        log.outs[oi].tag != h.tag ||
        log.outs[oi].result != h.value) {
      throw StateError('lane $l: held tag ${h.tag} at ${h.cycle} changed');
    }
  }
  if (log.kills.isEmpty && log.outs.length != cases.length) {
    throw StateError('lane $l: ${log.outs.length} of ${cases.length} out');
  }
  return log.killed.length;
}
