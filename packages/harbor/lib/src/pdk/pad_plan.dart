import 'package:rohd/rohd.dart';

import 'io_ring.dart';
import 'pad_library.dart';

/// A core top port, or a tristate port group, that gets one pad per bit.
class HarborPadPort {
  /// Port name. For a bidir group this is the shared prefix.
  final String name;

  final int width;

  /// Signal pad kind. Power kinds are not permitted.
  final HarborPadKind kind;

  /// Bidir only: core port that drives the pad.
  final String? outputName;

  /// Bidir only: core port that enables the pad driver.
  final String? outputEnable;

  /// Bidir only: core port that receives the pad value.
  final String? inputName;

  HarborPadPort({
    required this.name,
    required this.width,
    required this.kind,
    this.outputName,
    this.outputEnable,
    this.inputName,
  }) {
    if (width < 1) {
      throw ArgumentError('Pad port $name has width $width');
    }
    if (kind.isPower) {
      throw ArgumentError(
        'Pad port $name cannot have the power kind ${kind.name}',
      );
    }
    final hasGroup =
        outputName != null || outputEnable != null || inputName != null;
    if (kind == HarborPadKind.bidir &&
        (outputName == null || outputEnable == null || inputName == null)) {
      throw ArgumentError(
        'Bidir pad port $name needs an output, an output enable and an input',
      );
    }
    if (kind != HarborPadKind.bidir && hasGroup) {
      throw ArgumentError(
        'Pad port $name is ${kind.name}, only bidir ports have tristate parts',
      );
    }
  }

  /// Pad ports of [top] in port order: inputs, then outputs, then inouts.
  ///
  /// A bidir group is an output `<p>_out`, an output `<p>_oe` and an input
  /// `<p>_in`, all of one width. Names in [clocks] get clock input pads.
  /// Only names in [analog] get analog pads.
  static List<HarborPadPort> fromModule(
    Module top, {
    Set<String> clocks = const {},
    Set<String> analog = const {},
  }) {
    final ports = {...top.inputs, ...top.outputs, ...top.inOuts};
    for (final name in {...clocks, ...analog}) {
      if (!ports.containsKey(name)) {
        throw ArgumentError('Pad port $name is not a port of ${top.name}');
      }
    }
    for (final name in clocks) {
      if (!top.inputs.containsKey(name) || analog.contains(name)) {
        throw ArgumentError('Clock pad port $name must be a digital input');
      }
    }

    final groups = <String>{};
    for (final name in top.outputs.keys) {
      if (!name.endsWith('_oe') || analog.contains(name)) continue;
      final p = name.substring(0, name.length - 3);
      final oe = top.outputs[name]!;
      final out = top.outputs['${p}_out'];
      final inp = top.inputs['${p}_in'];
      if (out == null || inp == null) {
        throw ArgumentError(
          'Bidir pad port $p has ${p}_oe but no '
          '${out == null ? '${p}_out output' : '${p}_in input'}',
        );
      }
      if (out.width != oe.width || inp.width != oe.width) {
        throw ArgumentError(
          'Bidir pad port $p has ${p}_out, ${p}_oe and ${p}_in '
          'of widths ${out.width}, ${oe.width} and ${inp.width}',
        );
      }
      groups.add(p);
    }
    bool inGroup(String name, String suffix) =>
        name.endsWith(suffix) &&
        groups.contains(name.substring(0, name.length - suffix.length));

    final result = <HarborPadPort>[];
    for (final MapEntry(key: name, value: logic) in top.inputs.entries) {
      if (inGroup(name, '_in') && !analog.contains(name)) continue;
      result.add(
        HarborPadPort(
          name: name,
          width: logic.width,
          kind: analog.contains(name)
              ? HarborPadKind.analog
              : clocks.contains(name)
              ? HarborPadKind.clockInput
              : HarborPadKind.input,
        ),
      );
    }
    for (final MapEntry(key: name, value: logic) in top.outputs.entries) {
      if (analog.contains(name)) {
        result.add(
          HarborPadPort(
            name: name,
            width: logic.width,
            kind: HarborPadKind.analog,
          ),
        );
      } else if (inGroup(name, '_out')) {
        final p = name.substring(0, name.length - 4);
        result.add(
          HarborPadPort(
            name: p,
            width: logic.width,
            kind: HarborPadKind.bidir,
            outputName: name,
            outputEnable: '${p}_oe',
            inputName: '${p}_in',
          ),
        );
      } else if (!inGroup(name, '_oe')) {
        result.add(
          HarborPadPort(
            name: name,
            width: logic.width,
            kind: HarborPadKind.output,
          ),
        );
      }
    }
    for (final MapEntry(key: name, value: logic) in top.inOuts.entries) {
      if (!analog.contains(name)) {
        throw ArgumentError(
          'Pad port $name is an inout that is not analog and has no pad kind',
        );
      }
      result.add(
        HarborPadPort(
          name: name,
          width: logic.width,
          kind: HarborPadKind.analog,
        ),
      );
    }
    return result;
  }

  @override
  String toString() => 'HarborPadPort($name, $width, ${kind.name})';
}

/// The number of power pads on each side.
class HarborPowerPadRule {
  /// I/O supply pairs (dvdd and dvss) on each side.
  final int ioPairsPerSide;

  /// Core supply pairs (vdd and vss) on each side.
  final int corePairsPerSide;

  /// Signal pads on a side for each more I/O supply pair.
  final int signalPadsPerExtraIoPair;

  const HarborPowerPadRule({
    this.ioPairsPerSide = 1,
    this.corePairsPerSide = 1,
    this.signalPadsPerExtraIoPair = 8,
  });
}

/// One pad cell in the pad ring.
class HarborPlacedPad {
  /// Instance name.
  final String inst;

  final HarborPadKind kind;

  /// Full cell name from the pad library.
  final String master;

  /// Core port of a signal pad. Null for a power pad.
  final HarborPadPort? port;

  /// Bit of [port] for a signal pad. Index of the pad of its kind for a
  /// power pad.
  final int bit;

  const HarborPlacedPad({
    required this.inst,
    required this.kind,
    required this.master,
    required this.port,
    required this.bit,
  });

  @override
  String toString() => 'HarborPlacedPad($inst, $master)';
}

/// Pads on each side of the die, in placement order along the side.
class HarborPadPlan {
  final Map<HarborIoPadEdge, List<HarborPlacedPad>> _sides;

  /// Side order of [all] and of the fill.
  static const sideOrder = [
    HarborIoPadEdge.south,
    HarborIoPadEdge.east,
    HarborIoPadEdge.north,
    HarborIoPadEdge.west,
  ];

  HarborPadPlan._(this._sides);

  /// Puts one signal pad per port bit on the sides, then adds power pads.
  ///
  /// [overrides] pins a port (all bits, at position + bit) or one bit
  /// (`<port>[bit]`) to a side and position. Pinned pads come first on
  /// their side, by position. The other pads fill south, east, north and
  /// west in port order, up to a quarter of the signal pads per side.
  factory HarborPadPlan.build({
    required List<HarborPadPort> ports,
    required HarborPadLibrary library,
    HarborIoRing? overrides,
    HarborPowerPadRule rule = const HarborPowerPadRule(),
  }) {
    if (rule.ioPairsPerSide < 0 ||
        rule.corePairsPerSide < 0 ||
        rule.signalPadsPerExtraIoPair < 1) {
      throw ArgumentError(
        'Power pad rule needs pair counts of 0 or more and '
        'signalPadsPerExtraIoPair of 1 or more',
      );
    }

    final names = <String>{};
    final signals = <HarborPlacedPad>[];
    final byName = <String, HarborPlacedPad>{};
    for (final port in ports) {
      if (!names.add(port.name)) {
        throw ArgumentError('Pad port ${port.name} is in the list twice');
      }
      final master = library.cellName(port.kind);
      for (var bit = 0; bit < port.width; bit++) {
        final pad = HarborPlacedPad(
          inst: '${port.name}_pad_$bit',
          kind: port.kind,
          master: master,
          port: port,
          bit: bit,
        );
        signals.add(pad);
        byName['${port.name}[$bit]'] = pad;
      }
    }

    final pinnedAt = <HarborPlacedPad, (HarborIoPadEdge, int)>{};
    final usedSlots = <(HarborIoPadEdge, int), String>{};
    void pin(HarborPlacedPad pad, HarborIoPadEdge edge, int position) {
      final slot = (edge, position);
      final other = usedSlots[slot];
      if (other != null) {
        throw ArgumentError(
          'Pad ${pad.port!.name}[${pad.bit}] and $other both pin '
          '${edge.name} position $position',
        );
      }
      if (pinnedAt.containsKey(pad)) {
        throw ArgumentError(
          'Pad ${pad.port!.name}[${pad.bit}] is pinned twice',
        );
      }
      usedSlots[slot] = '${pad.port!.name}[${pad.bit}]';
      pinnedAt[pad] = slot;
    }

    for (final o in overrides?.pads ?? const <HarborIoPad>[]) {
      if (o.isPower) {
        throw ArgumentError(
          'Pad ring override ${o.signalName} is a power pad, '
          'the power pad rule places power pads',
        );
      }
      final one = byName[o.signalName];
      if (one != null) {
        pin(one, o.edge, o.position);
        continue;
      }
      final matches = ports.where((p) => p.name == o.signalName);
      if (matches.isEmpty) {
        throw ArgumentError(
          'Pad ring override ${o.signalName} is not a pad port',
        );
      }
      final port = matches.single;
      for (var bit = 0; bit < port.width; bit++) {
        pin(byName['${port.name}[$bit]']!, o.edge, o.position + bit);
      }
    }

    final limit = (signals.length + 3) ~/ 4;
    final sideSignals = {
      for (final e in sideOrder)
        e:
            (pinnedAt.entries.where((p) => p.value.$1 == e).toList()
                  ..sort((a, b) => a.value.$2.compareTo(b.value.$2)))
                .map((p) => p.key)
                .toList(),
    };
    final free = signals.where((p) => !pinnedAt.containsKey(p)).iterator;
    var more = free.moveNext();
    for (final e in sideOrder) {
      final side = sideSignals[e]!;
      while (more && side.length < limit) {
        side.add(free.current);
        more = free.moveNext();
      }
    }
    // Pinned pads over the limit on one side leave room on the others.
    for (final e in sideOrder) {
      while (more) {
        sideSignals[e]!.add(free.current);
        more = free.moveNext();
      }
    }

    final counts = {
      for (final k in [
        HarborPadKind.ioPower,
        HarborPadKind.ioGround,
        HarborPadKind.corePower,
        HarborPadKind.coreGround,
      ])
        k: 0,
    };
    HarborPlacedPad power(HarborPadKind kind) {
      final n = counts[kind]!;
      counts[kind] = n + 1;
      final base = switch (kind) {
        HarborPadKind.ioPower => 'dvdd',
        HarborPadKind.ioGround => 'dvss',
        HarborPadKind.corePower => 'vdd',
        _ => 'vss',
      };
      return HarborPlacedPad(
        inst: '${base}_pad_$n',
        kind: kind,
        master: library.cellName(kind),
        port: null,
        bit: n,
      );
    }

    final sides = <HarborIoPadEdge, List<HarborPlacedPad>>{};
    for (final e in sideOrder) {
      final sig = sideSignals[e]!;
      final ioPairs =
          rule.ioPairsPerSide + sig.length ~/ rule.signalPadsPerExtraIoPair;
      final pairs = [
        for (var i = 0; i < ioPairs; i++)
          [power(HarborPadKind.ioGround), power(HarborPadKind.ioPower)],
        for (var i = 0; i < rule.corePairsPerSide; i++)
          [power(HarborPadKind.coreGround), power(HarborPadKind.corePower)],
      ];
      // Pair j goes before signal (j + 1) * n / (pairs + 1), so one pair is
      // in the middle and more pairs spread along the side.
      final out = <HarborPlacedPad>[];
      var j = 0;
      for (var i = 0; i <= sig.length; i++) {
        while (j < pairs.length &&
            (j + 1) * sig.length ~/ (pairs.length + 1) == i) {
          out.addAll(pairs[j++]);
        }
        if (i < sig.length) out.add(sig[i]);
      }
      sides[e] = List.unmodifiable(out);
    }
    return HarborPadPlan._(sides);
  }

  /// Pads on side [e], in order along the side.
  List<HarborPlacedPad> side(HarborIoPadEdge e) => _sides[e]!;

  /// Pads of all sides: south, east, north, then west.
  List<HarborPlacedPad> get all => [for (final e in sideOrder) ..._sides[e]!];
}
