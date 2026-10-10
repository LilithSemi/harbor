import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'fp_fma_path.dart' show harborFpProductWidth;
import 'fp_format.dart';
import 'fp_pipe_stage.dart';
import 'fp_unpack.dart' show harborFpSelect;
import 'fpu.dart';
import 'fpu_config.dart';

/// The [ratio] narrow units of one [format], one per element.
typedef _NarrowGroup = ({
  HarborFpFormat format,
  int ratio,
  List<HarborFpu> units,
});

/// Ops that never pack.
const _narrowExcludedOps = {
  HarborFpOp.fpToFp,
  HarborFpOp.fpToInt,
  HarborFpOp.intToFp,
  HarborFpOp.cvtModWD,
  HarborFpOp.div,
  HarborFpOp.sqrt,
};

const _widenCapableOps = {
  HarborFpOp.mul,
  HarborFpOp.madd,
  HarborFpOp.msub,
  HarborFpOp.nmsub,
  HarborFpOp.nmadd,
};

/// A vector lane built on [HarborFpu], for River's RVV vector unit and
/// Glacier's GPU warps.
///
/// One [HarborFpu] (`main`) does one element a beat at [laneWidth]. With
/// [liveSew], `in_sew` is the format index of the beat and can change
/// every beat. Without it, the lane runs at `fpu.widest`. A widening op
/// (`mul` or a madd op with `in_fmt_narrow` set) always runs on `main`.
///
/// With [packNarrow] (needs [liveSew]), the lane also has, for each format
/// narrower than `fpu.widest`, one single format [HarborFpu] per element:
/// 2 for fp32 and 4 for fp16 in a 64-bit lane. A beat at that format runs
/// on these units, element `i` in bits `i * width` up. Converts, `div` and
/// `sqrt` do not pack. They run on `main`, one element a beat.
///
/// Every unit gets the same `in_valid`, `out_ready` and `kill_mask` in
/// each cycle, so all units hold the same ops in the same slots. A unit
/// that the beat does not use computes a value that the lane ignores. The
/// lane ports `in_ready`, `out_valid`, `slot_valid`, `slot_tag` and
/// `kill_mask` thus have the slots of [HarborFpu]: the skid buffer, then
/// each cut, youngest first ([slotNames]). Every unit toggles every beat,
/// so dynamic power scales with the full unit count, not just the one the
/// lane selects.
///
/// `in_mask` has one bit per element ([elementsPerBeat] bits) and `in_tail`
/// is the count of elements before the tail. An element that is masked off
/// or at or past `in_tail` keeps its bits from `in_dest` and gives no flags.
/// `out_flags` is the OR of the flags of the other elements. On a beat that
/// runs on `main`, only element 0 is used, and its result has zeros above
/// the format. A packed beat zero-extends its element bits up to `outW`, so
/// when an [HarborFpuConfig.intWidths] width is wider than [laneWidth], the
/// `in_dest` bits above [laneWidth] do not pass through on that beat.
///
/// The div port (`div_*`) is the div port of `main` with no mask or tail.
/// It does one element a beat at every format.
class HarborVectorLane extends BridgeModule {
  /// The lane's `main` unit and (with `packNarrow`) narrow unit config.
  final HarborFpuConfig fpu;

  /// Width of the operand and result buses. Defaults to `fpu.widest.width`;
  /// passing a different value is an error.
  final int laneWidth;

  /// Exposes `in_sew` to pick the operand format every beat.
  final bool liveSew;

  /// Builds extra narrow units so a beat can pack more than one element.
  final bool packNarrow;

  /// Width of `in_tag`, `out_tag` and each `slot_tag` field.
  final int tagWidth;

  late final HarborFpu _main;
  final List<_NarrowGroup> _groups = [];

  /// Cycles from an accepted beat to its result, same for every route.
  int get latency => fpu.latency;

  /// Cycles on the div port, for the longest op. Null without a div port.
  int? get divLatency => _main.divLatency;

  /// True when the lane has a div port.
  bool get hasDiv => _main.hasDiv;

  /// Elements packed into one beat, the widest group's ratio or 1.
  late final int elementsPerBeat;

  /// Main pipe slots, the same as [HarborFpu.slotCountOf].
  static int slotCountOf(HarborFpuConfig fpu) => HarborFpu.slotCountOf(fpu);

  /// Main pipe slot names, the same as [HarborFpu.slotNamesOf].
  static List<String> slotNamesOf(HarborFpuConfig fpu) =>
      HarborFpu.slotNamesOf(fpu);

  /// Div port slots, the same as [HarborFpu.divSlotCountOf].
  static int divSlotCountOf(HarborFpuConfig fpu) =>
      HarborFpu.divSlotCountOf(fpu);

  /// Div port slot names, the same as [HarborFpu.divSlotNamesOf].
  static List<String> divSlotNamesOf(HarborFpuConfig fpu) =>
      HarborFpu.divSlotNamesOf(fpu);

  /// Width of `kill_mask` and `slot_valid`.
  int get slots => slotCountOf(fpu);

  List<String> get slotNames => slotNamesOf(fpu);

  /// Width of `div_kill_mask` and `div_slot_valid`, or 0 without one.
  int get divSlots => divSlotCountOf(fpu);

  List<String> get divSlotNames => divSlotNamesOf(fpu);

  HarborVectorLane(
    this.fpu, {
    int? laneWidth,
    this.liveSew = false,
    this.packNarrow = false,
    this.tagWidth = 0,
    String? name,
  }) : laneWidth = laneWidth ?? fpu.widest.width,
       super(
         _definitionName(fpu, liveSew, packNarrow, tagWidth),
         name: name ?? 'vector_lane',
         reserveDefinitionName: false,
       ) {
    if (packNarrow && !liveSew) {
      throw ArgumentError.value(packNarrow, 'packNarrow', 'needs liveSew');
    }
    if (this.laneWidth != fpu.widest.width) {
      throw ArgumentError.value(
        this.laneWidth,
        'laneWidth',
        'must equal fpu.widest.width (${fpu.widest.width})',
      );
    }

    final clk = _in('clk');
    final reset = _in('reset');

    _main = HarborFpu(fpu, tagWidth: tagWidth, name: 'main');
    if (!_main.hasMain) {
      throw ArgumentError.value(
        fpu.ops,
        'fpu.ops',
        'HarborVectorLane needs a non-div, non-sqrt op',
      );
    }

    // Narrow groups: one format narrower than fpu.widest whose width
    // divides laneWidth, replicated enough times to fill it.
    final narrowOps = fpu.ops.difference(_narrowExcludedOps);
    final mainPm = harborFpProductWidth(fpu);
    final narrowFormats = <(int, HarborFpFormat, int, Set<HarborFpOp>)>[];
    if (packNarrow) {
      for (var i = 0; i < fpu.formats.length; i++) {
        final f = fpu.formats[i];
        if (fpu.widest.width % f.width != 0) {
          throw ArgumentError.value(
            f,
            'fpu.formats',
            'packNarrow needs every format width to divide laneWidth',
          );
        }
        final ratio = fpu.widest.width ~/ f.width;
        if (ratio < 2) {
          continue;
        }
        if (narrowOps.isEmpty) {
          throw ArgumentError.value(
            fpu.ops,
            'fpu.ops',
            'packNarrow needs a non-convert, non-div op to pack',
          );
        }
        // A narrow unit builds its own product only when the format fits
        // main's product width. Otherwise its multiply ops run on main,
        // which gives the canonical NaN for them.
        final fits = f.mantissaWidth + 1 <= mainPm;
        final groupOps = fits
            ? narrowOps
            : narrowOps.difference(_widenCapableOps);
        if (groupOps.isEmpty) {
          continue;
        }
        narrowFormats.add((i, f, ratio, groupOps));
      }
    }
    elementsPerBeat = narrowFormats.isEmpty
        ? 1
        : narrowFormats.map((e) => e.$3).reduce(max);

    final n = fpu.latency;
    final killMask = _in('kill_mask', width: n + 1);
    final inValid = _in('in_valid');
    final outReady = _in('out_ready');
    final ctl = HarborFpPipeControl(
      clk: clk,
      reset: reset,
      killMask: killMask,
      inValid: inValid,
      outReady: outReady,
      stages: n,
    );
    _out('in_ready', ctl.inReady);
    _out('out_valid', ctl.outValid);
    _out('slot_valid', ctl.slotValids.rswizzle());

    _main.input('clk').srcConnection! <= clk;
    _main.input('reset').srcConnection! <= reset;
    _main.input('in_valid').srcConnection! <= inValid;
    _main.input('out_ready').srcConnection! <= outReady;
    _main.input('kill_mask').srcConnection! <= killMask;

    final op = _in('in_op', width: _main.input('in_op').width);
    _main.input('in_op').srcConnection! <= op;

    final fmtW = _main.input('in_fmt').width;
    final sew = liveSew ? _in('in_sew', width: fmtW) : null;
    final fixedFmt = Const(fpu.formats.indexOf(fpu.widest), width: fmtW);
    final sewVal = sew ?? fixedFmt;
    _main.input('in_fmt').srcConnection! <= sewVal;

    Logic? forwardOptional(String port) {
      if (!_main.inputs.containsKey(port)) {
        return null;
      }
      final v = _in(port, width: _main.input(port).width);
      _main.input(port).srcConnection! <= v;
      return v;
    }

    final fmtNarrow = forwardOptional('in_fmt_narrow');
    forwardOptional('in_fmt_dst');
    final rm = forwardOptional('in_rm');
    final a = forwardOptional('in_a');
    final b = forwardOptional('in_b');
    final c = forwardOptional('in_c');
    final liIndex = forwardOptional('in_li_index');
    // Integer fields never reach a narrow unit: int ops stay on main.
    forwardOptional('in_int_signed');
    forwardOptional('in_int_width');

    final tag = tagWidth > 0 ? _in('in_tag', width: tagWidth) : null;
    if (tag != null) {
      _main.input('in_tag').srcConnection! <= tag;
    }

    final maskW = elementsPerBeat;
    final tailW = elementsPerBeat.bitLength;
    final outW = _main.output('out_result').width;

    final mask = _in('in_mask', width: maskW);
    final tail = _in('in_tail', width: tailW);
    final dest = _in('in_dest', width: outW);

    // Build the narrow groups and wire each unit's own slice of the
    // packed operand buses, identically broadcast valid/ready/kill.
    for (final (fmtIndex, f, ratio, groupOps) in narrowFormats) {
      final narrowConfig = HarborFpuConfig(
        formats: [f],
        ops: groupOps,
        stages: fpu.stages,
        ftz: fpu.ftz,
        intWidths: const [],
        multiplier: fpu.multiplier,
        mulSlice: fpu.mulSlice,
      );
      // Slot count only depends on `stages`, shared with `fpu` above, so
      // a narrow unit always matches main's slot count here.
      final units = <HarborFpu>[];
      for (var k = 0; k < ratio; k++) {
        final u = HarborFpu(narrowConfig, name: 'narrow_${fmtIndex}_$k');
        u.input('clk').srcConnection! <= clk;
        u.input('reset').srcConnection! <= reset;
        u.input('in_valid').srcConnection! <= inValid;
        u.input('out_ready').srcConnection! <= outReady;
        u.input('kill_mask').srcConnection! <= killMask;
        u.input('in_op').srcConnection! <= op;
        u.input('in_fmt').srcConnection! <=
            Const(0, width: u.input('in_fmt').width);

        final lo = k * f.width;
        if (u.inputs.containsKey('in_rm') && rm != null) {
          u.input('in_rm').srcConnection! <= rm;
        }
        if (u.inputs.containsKey('in_a') && a != null) {
          u.input('in_a').srcConnection! <= a.getRange(lo, lo + f.width);
        }
        if (u.inputs.containsKey('in_b') && b != null) {
          u.input('in_b').srcConnection! <= b.getRange(lo, lo + f.width);
        }
        if (u.inputs.containsKey('in_c') && c != null) {
          u.input('in_c').srcConnection! <= c.getRange(lo, lo + f.width);
        }
        if (u.inputs.containsKey('in_li_index') && liIndex != null) {
          u.input('in_li_index').srcConnection! <= liIndex;
        }
        units.add(u);
      }
      _groups.add((format: f, ratio: ratio, units: units));
    }

    final routeW = _groups.isEmpty ? 0 : _groups.length.bitLength;

    // Thread the vector-only fields (mask, tail, dest, route) through the
    // same N registers as main, so they land on the output together.
    Logic maskQ = ctl.head(mask, 'mask');
    Logic tailQ = ctl.head(tail, 'tail');
    Logic destQ = ctl.head(dest, 'dest');
    Logic? routeQ;
    if (routeW > 0) {
      Logic isOp(Set<HarborFpOp> set) {
        final hits = fpu.ops.intersection(set);
        return hits.isEmpty
            ? Const(0)
            : hits
                  .map((o) => op.eq(Const(o.index, width: op.width)))
                  .reduce((x, y) => x | y);
      }

      var toMain = isOp(_narrowExcludedOps);
      if (fmtNarrow != null) {
        // in_fmt_narrow above fpu.widening.length is an invalid encoding.
        // It is still nonzero, so it routes here and main runs it as a
        // non-widening op (no widening pair matches it).
        toMain |=
            isOp(_widenCapableOps) &
            fmtNarrow.neq(Const(0, width: fmtNarrow.width));
      }
      // A plain multiply op in a format that does not fit main's product
      // width has no product in its narrow unit, so it runs on main too.
      if (fpu.formats.any((f) => f.mantissaWidth + 1 > mainPm)) {
        toMain |=
            isOp(_widenCapableOps) &
            harborFpSelect(sewVal, [
              for (final f in fpu.formats)
                Const(f.mantissaWidth + 1 > mainPm ? 1 : 0),
            ]);
      }
      final routeConsts = [
        for (var i = 0; i < fpu.formats.length; i++)
          Const(narrowFormats.indexWhere((e) => e.$1 == i) + 1, width: routeW),
      ];
      final routeRaw = mux(
        toMain,
        Const(0, width: routeW),
        harborFpSelect(sewVal, routeConsts),
      );
      routeQ = ctl.head(routeRaw, 'route');
    }
    for (var j = 0; j < n; j++) {
      maskQ = ctl.stage(j, maskQ, 'mask');
      tailQ = ctl.stage(j, tailQ, 'tail');
      destQ = ctl.stage(j, destQ, 'dest');
      if (routeQ != null) {
        routeQ = ctl.stage(j, routeQ, 'route');
      }
    }

    // Element i is live when its mask bit is set and i is before the tail.
    Logic active(int i) => maskQ[i] & tailQ.gt(Const(i, width: tailQ.width));

    final mainActive = active(0);
    final mainResult = mux(mainActive, _main.output('out_result'), destQ);
    final mainFlags = mux(
      mainActive,
      _main.output('out_flags'),
      Const(0, width: 5),
    );

    // result and flags already default to main's, for route 0.
    var result = mainResult;
    var flags = mainFlags;
    if (routeW > 0) {
      final route = routeQ!;
      for (var gi = 0; gi < _groups.length; gi++) {
        final g = _groups[gi];
        final sliceResults = <Logic>[];
        final sliceFlags = <Logic>[];
        for (var i = 0; i < g.ratio; i++) {
          final lo = i * g.format.width;
          final sliceActive = active(i);
          sliceResults.add(
            mux(
              sliceActive,
              g.units[i].output('out_result'),
              destQ.getRange(lo, lo + g.format.width),
            ),
          );
          sliceFlags.add(
            mux(
              sliceActive,
              g.units[i].output('out_flags'),
              Const(0, width: 5),
            ),
          );
        }
        // Zero-extends to outW, so dest bits above laneWidth never pass
        // through a packed beat (only matters when an intWidths width is
        // wider than laneWidth).
        final groupResult = sliceResults.rswizzle().zeroExtend(outW);
        final groupFlags = sliceFlags.reduce((x, y) => x | y);
        final sel = route.eq(Const(gi + 1, width: routeW));
        result = mux(sel, groupResult, result);
        flags = mux(sel, groupFlags, flags);
      }
    }

    _out('out_result', result);
    _out('out_flags', flags);
    if (tag != null) {
      _out('out_tag', _main.output('out_tag'));
      _out('slot_tag', _main.output('slot_tag'));
    }

    if (_main.hasDiv) {
      for (final p in const [
        'div_in_valid',
        'div_in_op',
        'div_in_fmt',
        'div_in_rm',
        'div_in_a',
        'div_in_b',
        'div_in_tag',
        'div_out_ready',
        'div_kill_mask',
      ]) {
        if (_main.inputs.containsKey(p)) {
          final v = _in(p, width: _main.input(p).width);
          _main.input(p).srcConnection! <= v;
        }
      }
      for (final p in const [
        'div_in_ready',
        'div_out_valid',
        'div_out_result',
        'div_out_flags',
        'div_out_tag',
        'div_slot_valid',
        'div_slot_tag',
      ]) {
        if (_main.outputs.containsKey(p)) {
          _out(p, _main.output(p));
        }
      }
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

  static String _definitionName(
    HarborFpuConfig fpu,
    bool liveSew,
    bool packNarrow,
    int tagWidth,
  ) {
    final ops = fpu.ops;
    final mf = fpu.mulFormats;
    final hasDivOps = ops.intersection(harborFpDivOps).isNotEmpty;
    final parts = [
      for (final f in fpu.formats) f.tag,
      for (final (n, w) in fpu.widening) 'W${n.tag}to${w.tag}',
      for (final o in HarborFpOp.values)
        if (ops.contains(o)) o.name,
      'S${fpu.stages}',
      if (fpu.ftz) 'Ftz',
      fpu.multiplier == HarborFpMultiplier.compressionTree
          ? 'Ct'
          : 'Dsp${fpu.mulSlice.$1}x${fpu.mulSlice.$2}',
      if (mf != null)
        'Mf${(mf.toList()..sort(harborFpFormatCompare)).map((f) => f.tag).join()}',
      for (final w in fpu.intWidths) 'I$w',
      if (hasDivOps)
        fpu.divMode == HarborFpDivMode.iterative
            ? 'DivR${fpu.divRadix}'
            : 'DivS${fpu.divStages}',
      if (liveSew) 'Sew',
      if (packNarrow) 'Pack',
      if (tagWidth > 0) 'T$tagWidth',
    ];
    return harborStableDefinitionName('HarborVectorLane', parts);
  }
}
