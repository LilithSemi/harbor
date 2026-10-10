import 'package:rohd/rohd.dart';

/// A kill mask of [slots] bits that are all [flush], for an in-order core
/// that drops every op in flight at once.
///
/// ```dart
/// fpu.input('kill_mask') <= harborKillAll(flush, fpu.slots);
/// ```
Logic harborKillAll(Logic flush, int slots) {
  if (slots == 0) {
    throw ArgumentError.value(slots, 'slots', 'must be at least 1');
  }
  return slots == 1 ? flush : flush.replicate(slots);
}

/// The valid and ready control of an elastic pipeline with [stages]
/// registers and one skid buffer at the input.
///
/// Register `j` loads when it is empty or when the stage after it takes. A
/// stall at the output holds only the full registers in front of it, and a
/// register behind an empty one still moves up. The ready chain from
/// `outReady` back to the first register is combinational. The skid buffer
/// keeps an op that came in when the first register could not take it, so
/// [inReady] is a register output. When the skid buffer is empty, an op goes
/// to the first stage in the cycle it comes in and adds no latency.
///
/// An op is accepted only in a cycle with `inValid` and [inReady] high.
///
/// The slots are the skid buffer (index 0) and the registers in order, so
/// index 0 holds the youngest op. A set bit of `killMask` drops the op of
/// that slot in the same cycle, and the slot is then a bubble. A bit on an
/// empty slot has no effect. [outValid] is low when the op at the output is
/// killed, and [inReady] does not look at `killMask`.
///
/// The control is built in the module that calls it. [head] and [stage]
/// add the data registers.
class HarborFpPipeControl {
  final Logic clk;

  /// Number of registers.
  final int stages;

  /// The load enable of each register. Index 0 is the first register.
  late final List<Logic> enables;

  /// The valid bit of each slot before the kill: the skid buffer, then
  /// each register.
  late final List<Logic> slotValids;

  /// High when the skid buffer is empty.
  late final Logic inReady;

  /// High when the op at the output is valid and not killed.
  late final Logic outValid;

  /// High when the skid buffer holds an op.
  late final Logic skidFull;

  final Map<String, Logic> _skid = {};

  HarborFpPipeControl({
    required this.clk,
    required Logic reset,
    required Logic killMask,
    required Logic inValid,
    required Logic outReady,
    required this.stages,
  }) {
    if (killMask.width != stages + 1) {
      throw ArgumentError.value(
        killMask.width,
        'killMask.width',
        'must be ${stages + 1}',
      );
    }
    final full = Logic(name: 'skid_full');
    skidFull = full;
    final en = [
      for (var j = 0; j < stages; j++) Logic(name: 'stage_en_${j + 1}'),
    ];
    final skidLive = (full & ~killMask[0]).named('skid_live');
    final headValid = mux(full, skidLive, inValid).named('head_valid');
    final v = <Logic>[];
    final live = <Logic>[];
    var prev = headValid;
    for (var j = 0; j < stages; j++) {
      final vj = flop(
        clk,
        prev,
        en: en[j],
        reset: reset,
      ).named('stage_valid_${j + 1}');
      v.add(vj);
      prev = (vj & ~killMask[j + 1]).named('stage_live_${j + 1}');
      live.add(prev);
    }
    for (var j = 0; j < stages; j++) {
      en[j] <= ~live[j] | (j + 1 < stages ? en[j + 1] : outReady);
    }
    final take = stages == 0 ? outReady : en[0];
    full <= flop(clk, headValid & ~take, reset: reset);
    enables = List.unmodifiable(en);
    slotValids = List.unmodifiable([full, ...v]);
    inReady = ~full;
    outValid = stages == 0 ? headValid : live.last;
  }

  /// [data] from the input port, or from the skid buffer when it is full.
  Logic head(Logic data, String name) {
    final held = flop(clk, data, en: ~skidFull).named('skid_$name');
    _skid[name] = held;
    return mux(skidFull, held, data).named('head_$name');
  }

  /// The skid buffer register that [head] made for [name].
  Logic skid(String name) => _skid[name]!;

  /// [data] after register [j].
  Logic stage(int j, Logic data, String name) =>
      flop(clk, data, en: enables[j]).named('s${j + 1}_$name');
}
