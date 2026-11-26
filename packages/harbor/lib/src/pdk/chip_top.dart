import 'pad_library.dart';
import 'pad_plan.dart';

String _range(int width) => width > 1 ? '[${width - 1}:0] ' : '';

String _bit(String name, int width, int bit) =>
    width > 1 ? '$name[$bit]' : name;

/// Verilog of the top cell with every pad of [plan] around [coreModule].
///
/// Each signal port gets an `inout` named `<port>_PAD`. A bidir group uses
/// `<p>_out`, `<p>_oe` and `<p>_in` on the core and one pad per bit.
String harborChipTopVerilog({
  required HarborPadPlan plan,
  required HarborPadLibrary library,
  required String coreModule,
  required List<HarborPadPort> corePorts,
  String topName = 'chip_top',
}) {
  final known = {for (final p in corePorts) p.name};
  for (final pad in plan.all) {
    final port = pad.port;
    if (port != null && !known.contains(port.name)) {
      throw ArgumentError(
        'Pad ${pad.inst} uses port ${port.name} that is not a core port',
      );
    }
  }
  final padded = {for (final pad in plan.all) pad.port?.name};
  for (final p in corePorts) {
    if (!padded.contains(p.name)) {
      throw ArgumentError('Core port ${p.name} has no pad in the pad plan');
    }
  }

  final pins = <String>[];
  final conns = <String>[];
  final wires = <String>[];
  final pads = <String>[];

  for (final p in corePorts) {
    final r = _range(p.width);
    if (p.kind == HarborPadKind.bidir) {
      for (final n in [p.outputName!, p.outputEnable!, p.inputName!]) {
        wires.add('  wire $r$n;');
        conns.add('    .$n($n)');
      }
    } else if (p.kind == HarborPadKind.analog) {
      conns.add('    .${p.name}(${p.name}_PAD)');
    } else {
      wires.add('  wire $r${p.name};');
      conns.add('    .${p.name}(${p.name})');
    }
    pins.add('  inout $r${p.name}_PAD');
  }

  for (final pad in plan.all) {
    final port = pad.port;
    final String body;
    if (port == null) {
      body = [
        for (final MapEntry(:key, :value)
            in (library.tieOffs[pad.kind] ?? const {}).entries)
          '.$key($value)',
      ].join(', ');
    } else {
      final w = port.width;
      final pin = <String>[];
      final padNet = _bit('${port.name}_PAD', w, pad.bit);
      switch (port.kind) {
        case HarborPadKind.analog:
          pin.add('.${library.analogPin}($padNet)');
        case HarborPadKind.input || HarborPadKind.clockInput:
          pin
            ..add('.${library.padPin}($padNet)')
            ..add('.${library.inPin}(${_bit(port.name, w, pad.bit)})');
        case HarborPadKind.output:
          pin
            ..add('.${library.padPin}($padNet)')
            ..add('.${library.outPin}(${_bit(port.name, w, pad.bit)})');
        case HarborPadKind.bidir:
          pin
            ..add('.${library.padPin}($padNet)')
            ..add('.${library.inPin}(${_bit(port.inputName!, w, pad.bit)})')
            ..add('.${library.outPin}(${_bit(port.outputName!, w, pad.bit)})')
            ..add('.${library.oePin}(${_bit(port.outputEnable!, w, pad.bit)})');
        default:
          throw ArgumentError('Pad ${pad.inst} has a power kind and a port');
      }
      if (port.kind != HarborPadKind.analog) {
        library.tieOffs[port.kind]?.forEach((k, v) => pin.add('.$k($v)'));
      }
      body = pin.join(', ');
    }
    pads.add('  (* keep *) ${pad.master} ${pad.inst} ($body);');
  }

  return [
    'module $topName (',
    '${pins.join(',\n')}',
    ');',
    ...wires,
    '',
    '  $coreModule i_core (',
    '${conns.join(',\n')}',
    '  );',
    '',
    ...pads,
    'endmodule',
    '',
  ].join('\n');
}
