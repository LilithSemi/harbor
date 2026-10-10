import 'package:rohd/rohd.dart';

import 'fpu_config.dart';

/// The cut points of one FPU path.
///
/// [cut] names a signal at a cut. When [clk] is set and the cut is in
/// [HarborFpuConfig.cuts], it also puts a register on the signal, which
/// loads when the enable of that cut is high, or on each clock when the cut
/// has no enable. [ride] holds the signals that later stages read, and
/// [pass] takes all of them through one cut.
class HarborFpCuts {
  final HarborFpuConfig config;
  final Logic? clk;
  final Map<HarborFpCut, Logic> enables;

  /// Signals that later stages read, by name.
  final ride = <String, Logic>{};

  final _groups = {for (final k in HarborFpCut.values) k: <Logic>[]};

  HarborFpCuts(this.config, {this.clk, this.enables = const {}});

  /// The signals that cross each cut point, before any register.
  Map<HarborFpCut, List<Logic>> get groups => {
    for (final k in HarborFpCut.values) k: List.unmodifiable(_groups[k]!),
  };

  Logic cut(HarborFpCut k, String name, Logic s) {
    final src = s.named('${k.name}_$name');
    _groups[k]!.add(src);
    final c = clk;
    if (c == null || !config.cuts.contains(k)) {
      return src;
    }
    return flop(c, src, en: enables[k]).named('${k.name}_${name}_q');
  }

  void pass(HarborFpCut k) {
    for (final e in ride.entries.toList()) {
      ride[e.key] = cut(k, e.key, e.value);
    }
  }

  /// Takes [ride] through every cut from [from] to [to].
  void passRange(HarborFpCut from, HarborFpCut to) {
    for (var i = from.index; i <= to.index; i++) {
      pass(HarborFpCut.values[i]);
    }
  }

  Logic operator [](String name) => ride[name]!;
  void operator []=(String name, Logic s) => ride[name] = s;
}
