import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

final _lib = Gf180mcuProvider(pdkRoot: '/pdk/gf180mcuD').padLibrary;

final _ports = [
  HarborPadPort(name: 'clk', width: 1, kind: HarborPadKind.clockInput),
  HarborPadPort(name: 'btn', width: 2, kind: HarborPadKind.input),
  HarborPadPort(name: 'led', width: 3, kind: HarborPadKind.output),
  HarborPadPort(
    name: 'sd',
    width: 2,
    kind: HarborPadKind.bidir,
    outputName: 'sd_out',
    outputEnable: 'sd_oe',
    inputName: 'sd_in',
  ),
  HarborPadPort(name: 'vref', width: 1, kind: HarborPadKind.analog),
];

void main() {
  final plan = HarborPadPlan.build(ports: _ports, library: _lib);
  final v = harborChipTopVerilog(
    plan: plan,
    library: _lib,
    coreModule: 'soc',
    corePorts: _ports,
  );
  final lines = v.split('\n');
  String padLine(String inst) =>
      lines.singleWhere((l) => l.contains(' $inst ('));

  test('one core instance and one keep line per pad', () {
    expect(RegExp(r'\bi_core\b').allMatches(v).length, 1);
    expect(RegExp(r'^module ', multiLine: true).allMatches(v).length, 1);
    for (final p in plan.all) {
      final l = padLine(p.inst);
      expect(l, startsWith('  (* keep *) ${p.master} ${p.inst} ('));
    }
    expect(RegExp(r'\(\* keep \*\)').allMatches(v).length, plan.all.length);
  });

  test('power pads have an empty pin list', () {
    for (final p in plan.all.where((p) => p.port == null)) {
      expect(padLine(p.inst).trim().endsWith('();'), isTrue);
    }
  });

  test('bidir pads take OE from the core and IE high', () {
    final l = padLine('sd_pad_1');
    expect(l, contains('.PAD(sd_PAD[1])'));
    expect(l, contains('.A(sd_out[1])'));
    expect(l, contains('.OE(sd_oe[1])'));
    expect(l, contains('.Y(sd_in[1])'));
    expect(l, contains("IE(1'b1)"));
  });

  test('output, input and analog pads', () {
    final o = padLine('led_pad_2');
    expect(o, contains('.A(led[2])'));
    expect(o, contains("OE(1'b1)"));
    expect(o, contains("IE(1'b0)"));
    expect(padLine('clk_pad_0'), contains('.PAD(clk_PAD)'));
    expect(padLine('clk_pad_0'), contains('.Y(clk)'));
    expect(padLine('vref_pad_0'), contains('.ASIG5V(vref_PAD)'));
    expect(v, contains('.vref(vref_PAD)'));
  });

  test('each core port bit meets one pad pin', () {
    int uses(String net) => RegExp(
      '\\.(PAD|Y|A|OE|ASIG5V)\\(${RegExp.escape(net)}\\)',
    ).allMatches(v).length;
    for (final n in [
      'clk',
      'btn[0]',
      'btn[1]',
      'led[0]',
      'led[1]',
      'led[2]',
      'sd_out[0]',
      'sd_out[1]',
      'sd_oe[0]',
      'sd_oe[1]',
      'sd_in[0]',
      'sd_in[1]',
    ]) {
      expect(uses(n), 1, reason: n);
    }
  });

  test('each pad takes its own bit', () {
    expect(padLine('btn_pad_1'), contains('.Y(btn[1])'));
    expect(padLine('btn_pad_1'), contains('.PAD(btn_PAD[1])'));
    expect(padLine('led_pad_0'), contains('.A(led[0])'));
  });

  test('wire, inout and core connections', () {
    expect(v, contains('  wire [1:0] btn;'));
    expect(v, contains('  wire [2:0] led;'));
    expect(v, contains('  wire [1:0] sd_oe;'));
    expect(v, contains('  wire clk;'));
    expect(v, contains('  inout [2:0] led_PAD'));
    expect(v, contains('  inout [1:0] sd_PAD'));
    expect(v, contains('  inout clk_PAD'));
    for (final n in ['clk', 'btn', 'led', 'sd_out', 'sd_oe', 'sd_in']) {
      expect(v, contains('.$n($n)'));
    }
  });

  test('analog pad has no tie-offs', () {
    expect(
      padLine('vref_pad_0').contains(RegExp(r'\.(PU|PD|OE|IE)\(')),
      isFalse,
    );
  });

  test('a pad port missing from the core ports throws', () {
    expect(
      () => harborChipTopVerilog(
        plan: plan,
        library: _lib,
        coreModule: 'soc',
        corePorts: _ports.where((p) => p.name != 'led').toList(),
      ),
      throwsA(isA<ArgumentError>().having((e) => '$e', 'msg', contains('led'))),
    );
  });

  test('a core port without a pad throws', () {
    expect(
      () => harborChipTopVerilog(
        plan: plan,
        library: _lib,
        coreModule: 'soc',
        corePorts: [
          ..._ports,
          HarborPadPort(name: 'extra', width: 1, kind: HarborPadKind.input),
        ],
      ),
      throwsA(
        isA<ArgumentError>().having((e) => '$e', 'msg', contains('extra')),
      ),
    );
  });

  test('spare pads are tied off', () {
    final slotPlan = HarborPadPlan.build(
      ports: _ports,
      library: _lib,
      slot: HarborFabSlot.waferSpace['0p5x0p5'],
    );
    final v = harborChipTopVerilog(
      plan: slotPlan,
      library: _lib,
      coreModule: 'soc',
      corePorts: _ports,
    );
    final spares = v
        .split('\n')
        .where((l) => l.contains(' spare_pad_'))
        .toList();
    expect(spares.length, 56 - 9 - 16);
    expect(
      spares.first,
      "  (* keep *) gf180mcu_fd_io__bi_24t spare_pad_0 (.A(1'b0), .OE(1'b0), "
      ".IE(1'b0), .CS(1'b0), .SL(1'b0), .PU(1'b0), .PD(1'b0));",
    );
    expect(v, contains('  (* keep *) gf180mcu_fd_io__dvdd dvdd_pad_0 ();'));
  });
}
