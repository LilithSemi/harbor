import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'fp_convert_path.dart';
import 'fp_estimate.dart';
import 'fp_fma_path.dart';
import 'fp_misc_path.dart';
import 'fp_pipe_stage.dart';
import 'fpu_config.dart';
import 'recurrence.dart';

/// The ops of the div and sqrt port.
const harborFpDivOps = {HarborFpOp.div, HarborFpOp.sqrt};

/// The fused FPU: every op in [HarborFpuConfig.ops] on one elastic
/// pipeline, and divide and square root on a separate port.
///
/// The main pipe sends each op to the FMA, misc, convert and estimate
/// datapaths at the same time. Only the paths that some op in the config
/// needs are built. Their registers at the cuts of [HarborFpuConfig.stages]
/// move together under one internal valid and ready control, so every main
/// pipe op has the same latency and the results come out in order. A
/// select after the last cut takes the result of the path of the op.
///
/// Main pipe ports:
///
///   - `in_op` is a [HarborFpOp] index. `div` and `sqrt` go to the div port.
///   - `in_fmt` is the format index. It is the source format of `fpToFp`,
///     `fpToInt` and `cvtModWD` (which must be fp64), and the result format
///     of `intToFp` and `li`.
///   - `in_fmt_dst` is the result format of `fpToFp`.
///   - `in_fmt_narrow` selects a widening pair for `mul` and the madd ops.
///   - `in_a`, `in_b`, `in_c` are right aligned. `add` and `sub` read `a`
///     and `b`. `intToFp` reads the integer from `in_a`.
///   - `in_int_width` selects one of [HarborFpuConfig.intWidths], and
///     `in_int_signed` selects a signed integer.
///   - `in_li_index` is the `fli` table index.
///   - `in_tag` rides with the op and comes out on `out_tag` with its
///     result. It is there only when [tagWidth] is not zero.
///   - `out_result` is right aligned with zeros above, and `out_flags` is
///     `{NV, DZ, OF, UF, NX}`.
///
/// The div port (`div_*`) is there only when `div` or `sqrt` is in the
/// config. `div_in_op` is a [HarborFpOp] index, `div` or `sqrt`. It uses
/// [HarborDivSqrtRecurrence], and a busy divide does not stop the main
/// pipe. Input ports that no configured op reads are not made.
///
/// An op is accepted only in a cycle with `in_valid` and `in_ready` high.
///
/// Kill is per slot. A slot is a register that can hold an op. On the main
/// pipe the slots are the input skid buffer and then each cut register in
/// order ([slotNames]). The div port has the slots of its recurrence
/// ([divSlotNames]). Index 0 is the youngest slot. `slot_valid` has one
/// bit per slot and `slot_tag` has the tag of each slot, slot 0 in the low
/// bits. Both come from registers. A set bit of `kill_mask` drops the op of
/// that slot in the same cycle with no result and no flags. The mask is
/// sampled each cycle, and a bit on an empty slot has no effect. A killed op
/// is never on `out_valid`. `in_ready` does not look at the mask, so an op
/// on the input in a kill cycle is accepted unless the caller drops
/// `in_valid`. An in-order core can drive every bit from one flush with
/// [harborKillAll].
class HarborFpu extends BridgeModule {
  final HarborFpuConfig config;

  /// Width of `in_tag`, `out_tag` and each `slot_tag` field, and the same
  /// on the div port. Zero means no tag ports.
  final int tagWidth;

  /// Cycles from the accept of an op on the main pipe to the first cycle
  /// with `out_valid` high, when `out_ready` stays high. It is the number of
  /// cuts. With zero stages the result is there in the accept cycle.
  int get latency => config.latency;

  /// Cycles from an accept on the div port to `div_out_valid`, for the
  /// longest op, when `div_out_ready` stays high. Null without a div port.
  int? get divLatency => _div?.latency;

  HarborDivSqrtRecurrence? _div;

  /// True when the main pipe is built.
  late final bool hasMain;

  /// True when the div port is built.
  late final bool hasDiv;

  /// Main pipe slots of [config]: the skid buffer and one per cut.
  static int slotCountOf(HarborFpuConfig config) => config.latency + 1;

  /// Main pipe slot names of [config], youngest first.
  static List<String> slotNamesOf(HarborFpuConfig config) {
    final cuts = config.cuts.toList()..sort((x, y) => x.index - y.index);
    return ['skid', for (final c in cuts) c.name];
  }

  /// Div port slots of [config].
  static int divSlotCountOf(HarborFpuConfig config) =>
      HarborDivSqrtRecurrence.slotCountOf(config.divMode, config.divStages);

  /// Div port slot names of [config], youngest first.
  static List<String> divSlotNamesOf(HarborFpuConfig config) =>
      HarborDivSqrtRecurrence.slotNamesOf(config.divMode, config.divStages);

  /// Width of `kill_mask` and `slot_valid`, or 0 without a main pipe.
  int get slots => hasMain ? slotCountOf(config) : 0;

  /// Width of `div_kill_mask` and `div_slot_valid`, or 0 when there is no
  /// div port or it has no registers.
  int get divSlots => hasDiv ? divSlotCountOf(config) : 0;

  List<String> get slotNames => hasMain ? slotNamesOf(config) : const [];
  List<String> get divSlotNames => hasDiv ? divSlotNamesOf(config) : const [];

  HarborFpu(this.config, {this.tagWidth = 0, String? name})
    : super(
        _definitionName(config, tagWidth),
        name: name ?? 'fpu',
        reserveDefinitionName: false,
      ) {
    if (tagWidth < 0) {
      throw ArgumentError.value(tagWidth, 'tagWidth', 'must not be negative');
    }
    final ops = config.ops;
    final unhandled = ops.difference(harborFpuHandledOps);
    if (unhandled.isNotEmpty) {
      throw ArgumentError.value(
        unhandled.map((o) => o.name).join(', '),
        'config.ops',
        'no path handles these ops',
      );
    }
    final mainOps = ops.difference(harborFpDivOps);
    hasMain = mainOps.isNotEmpty;
    hasDiv = ops.intersection(harborFpDivOps).isNotEmpty;
    if (!hasMain && !hasDiv) {
      throw ArgumentError.value(ops, 'config.ops', 'must not be empty');
    }

    final clk = _in('clk');
    final reset = _in('reset');
    if (hasMain) {
      _buildMain(clk, reset, mainOps);
    }
    if (hasDiv) {
      _buildDiv(clk, reset);
    }
  }

  Logic _in(String name, {int width = 1}) {
    createPort(name, PortDirection.input, width: width);
    return input(name);
  }

  void _out(String name, Logic value) {
    createPort(name, PortDirection.output, width: value.width);
    output(name) <= value;
  }

  void _buildMain(Logic clk, Logic reset, Set<HarborFpOp> mainOps) {
    final opW = config.widest.width;
    final intWidths = config.intWidths;
    final dataW = max(opW, intWidths.isEmpty ? 0 : intWidths.reduce(max));
    final fmtW = config.fmtWidth;
    bool uses(Set<HarborFpOp> s) => mainOps.intersection(s).isNotEmpty;
    // A port only when some op reads it, else a zero for the paths.
    Logic field(String name, int width, bool needed) =>
        needed ? _in(name, width: width) : Const(0, width: width);

    const madd = {
      HarborFpOp.madd,
      HarborFpOp.msub,
      HarborFpOp.nmsub,
      HarborFpOp.nmadd,
    };
    const intOps = {HarborFpOp.fpToInt, HarborFpOp.intToFp};
    final noRm = {
      ...harborFpMiscOps,
      HarborFpOp.li,
      HarborFpOp.cvtModWD,
      HarborFpOp.rsqrt7,
    };
    final noB = {...harborFpConvertOps, ...harborFpEstimateOps}
      ..add(HarborFpOp.classify);

    final inValid = _in('in_valid');
    final op = _in('in_op', width: harborFpOpWidth);
    final fmt = _in('in_fmt', width: fmtW);
    final fmtDst = field(
      'in_fmt_dst',
      fmtW,
      mainOps.contains(HarborFpOp.fpToFp),
    );
    final fmtNarrow = field(
      'in_fmt_narrow',
      harborFpNarrowWidth(config),
      config.widening.isNotEmpty && uses({...madd, HarborFpOp.mul}),
    );
    final rm = field('in_rm', 3, mainOps.difference(noRm).isNotEmpty);
    final a = field(
      'in_a',
      dataW,
      mainOps.difference({HarborFpOp.li}).isNotEmpty,
    );
    final b = field('in_b', opW, mainOps.difference(noB).isNotEmpty);
    final c = field('in_c', opW, uses(madd));
    final liIndex = field('in_li_index', 5, mainOps.contains(HarborFpOp.li));
    final intSigned = field('in_int_signed', 1, uses(intOps));
    final intWidth = field(
      'in_int_width',
      max(1, (intWidths.length - 1).bitLength),
      uses(intOps),
    );
    final tag = tagWidth > 0 ? _in('in_tag', width: tagWidth) : null;
    final outReady = _in('out_ready');

    final n = config.latency;
    final ctl = HarborFpPipeControl(
      clk: clk,
      reset: reset,
      killMask: _in('kill_mask', width: n + 1),
      inValid: inValid,
      outReady: outReady,
      stages: n,
    );
    _out('in_ready', ctl.inReady);
    _out('out_valid', ctl.outValid);
    _out('slot_valid', ctl.slotValids.rswizzle());

    Logic head(Logic data, String name) =>
        data is Const ? data : ctl.head(data, name);
    final hOp = head(op, 'op');
    final hFmt = head(fmt, 'fmt');
    final hRm = head(rm, 'rm');
    final hA = head(a, 'a');
    final hA0 = hA.getRange(0, opW);
    final hB = head(b, 'b');

    final pathClk = n > 0 ? clk : null;
    final cutList = config.cuts.toList()..sort((x, y) => x.index - y.index);
    final enables = {for (var j = 0; j < n; j++) cutList[j]: ctl.enables[j]};

    final paths = <(Set<HarborFpOp>, Logic, Logic)>[];
    if (uses(harborFpFmaOps)) {
      final p = HarborFpFmaPath(
        config,
        op: hOp,
        fmt: hFmt,
        fmtNarrow: head(fmtNarrow, 'fmt_narrow'),
        rm: hRm,
        a: hA0,
        b: hB,
        c: head(c, 'c'),
        clk: pathClk,
        enables: enables,
      );
      paths.add((harborFpFmaOps, p.result, p.flags));
    }
    if (uses(harborFpMiscOps)) {
      final p = HarborFpMiscPath(
        config,
        op: hOp,
        fmt: hFmt,
        a: hA0,
        b: hB,
        clk: pathClk,
        enables: enables,
      );
      paths.add((harborFpMiscOps, p.result, p.flags));
    }
    if (uses(harborFpConvertOps)) {
      final p = HarborFpConvertPath(
        config,
        op: hOp,
        fmt: hFmt,
        fmtDst: head(fmtDst, 'fmt_dst'),
        rm: hRm,
        a: hA0,
        intIn: hA.getRange(0, intWidths.isEmpty ? 1 : intWidths.reduce(max)),
        intWidth: head(intWidth, 'int_width'),
        signed: head(intSigned, 'int_signed'),
        liIndex: head(liIndex, 'li_index'),
        clk: pathClk,
        enables: enables,
      );
      paths.add((harborFpConvertOps, p.result, p.flags));
    }
    if (uses(harborFpEstimateOps)) {
      final p = HarborFpEstimate(
        config,
        op: hOp,
        fmt: hFmt,
        rm: hRm,
        a: hA0,
        clk: pathClk,
        enables: enables,
      );
      paths.add((harborFpEstimateOps, p.result, p.flags));
    }

    // One select bit per path rides with the op to the final select.
    var sel = <Logic>[
      if (paths.length > 1)
        for (final (pathOps, _, _) in paths)
          [
            for (final o in pathOps.intersection(config.ops))
              hOp.eq(Const(o.index, width: harborFpOpWidth)),
          ].reduce((x, y) => x | y),
    ];
    if (tag != null) {
      var t = ctl.head(tag, 'tag');
      final slotTags = [ctl.skid('tag')];
      for (var j = 0; j < n; j++) {
        t = ctl.stage(j, t, 'tag');
        slotTags.add(t);
      }
      _out('out_tag', t);
      _out('slot_tag', slotTags.rswizzle());
    }
    for (var j = 0; j < n; j++) {
      sel = [
        for (var i = 0; i < sel.length; i++) ctl.stage(j, sel[i], 'sel_$i'),
      ];
    }

    if (paths.length == 1) {
      final (_, r, f) = paths.first;
      _out('out_result', r.zeroExtend(dataW));
      _out('out_flags', f);
      return;
    }
    Logic pick(int i, Logic x) => x & sel[i].replicate(x.width);
    _out(
      'out_result',
      [
        for (var i = 0; i < paths.length; i++)
          pick(i, paths[i].$2.zeroExtend(dataW)),
      ].reduce((x, y) => x | y),
    );
    _out(
      'out_flags',
      [
        for (var i = 0; i < paths.length; i++) pick(i, paths[i].$3),
      ].reduce((x, y) => x | y),
    );
  }

  void _buildDiv(Logic clk, Logic reset) {
    final opW = config.widest.width;
    final inValid = _in('div_in_valid');
    final hasDivOp = config.ops.contains(HarborFpOp.div);
    final hasSqrt = config.ops.contains(HarborFpOp.sqrt);
    final op = hasDivOp && hasSqrt
        ? _in('div_in_op', width: harborFpOpWidth)
        : null;
    final fmt = _in('div_in_fmt', width: config.fmtWidth);
    final rm = _in('div_in_rm', width: 3);
    final a = _in('div_in_a', width: opW);
    final b = hasDivOp ? _in('div_in_b', width: opW) : Const(0, width: opW);
    final tag = tagWidth > 0 ? _in('div_in_tag', width: tagWidth) : null;
    final outReady = _in('div_out_ready');
    final slots = divSlotCountOf(config);
    final killMask = slots > 0 ? _in('div_kill_mask', width: slots) : null;

    final isSqrt = op == null
        ? Const(hasSqrt ? 1 : 0)
        : op.eq(Const(HarborFpOp.sqrt.index, width: harborFpOpWidth));
    final rec = HarborDivSqrtRecurrence(
      config,
      clk: clk,
      reset: reset,
      killMask: killMask,
      inValid: inValid,
      inOp: [Const(0), isSqrt].swizzle(),
      inFmt: fmt,
      inRm: rm,
      inA: a,
      inB: b,
      inTag: tag,
      outReady: outReady,
    );
    _div = rec;

    _out('div_in_ready', rec.inReady);
    _out('div_out_valid', rec.outValid);
    _out('div_out_result', rec.outResult);
    _out('div_out_flags', rec.outFlags);
    if (tag != null) {
      _out('div_out_tag', rec.outTag);
    }
    if (slots > 0) {
      _out('div_slot_valid', rec.slotValid);
      if (tag != null) {
        _out('div_slot_tag', rec.slotTag);
      }
    }
  }

  static String _definitionName(HarborFpuConfig config, int tagWidth) {
    final ops = config.ops;
    final mf = config.mulFormats;
    final hasDivOps = ops.intersection(harborFpDivOps).isNotEmpty;
    final parts = [
      for (final f in config.formats) f.tag,
      for (final (n, w) in config.widening) 'W${n.tag}to${w.tag}',
      for (final o in HarborFpOp.values)
        if (ops.contains(o)) o.name,
      'S${config.stages}',
      if (config.ftz) 'Ftz',
      config.multiplier == HarborFpMultiplier.compressionTree
          ? 'Ct'
          : 'Dsp${config.mulSlice.$1}x${config.mulSlice.$2}',
      if (mf != null)
        'Mf${(mf.toList()..sort(harborFpFormatCompare)).map((f) => f.tag).join()}',
      for (final w in config.intWidths) 'I$w',
      if (hasDivOps)
        config.divMode == HarborFpDivMode.iterative
            ? 'DivR${config.divRadix}'
            : 'DivS${config.divStages}',
      if (tagWidth > 0) 'T$tagWidth',
    ];
    return harborStableDefinitionName('HarborFpu', parts);
  }
}

/// Every op that some path of [HarborFpu] handles.
final harborFpuHandledOps = Set.unmodifiable({
  ...harborFpFmaOps,
  ...harborFpMiscOps,
  ...harborFpConvertOps,
  ...harborFpEstimateOps,
  ...harborFpDivOps,
});
