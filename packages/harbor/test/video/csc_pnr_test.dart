@Tags(['slow'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// The 1080p60 pixel clock.
const _mhz = 148.5;

bool _onPath(String tool) =>
    Process.runSync('sh', ['-c', 'command -v $tool']).exitCode == 0;

String? _skip(List<String> tools) {
  for (final tool in ['timeout', 'yosys', ...tools]) {
    if (!_onPath(tool)) return '$tool is not on PATH';
  }
  return null;
}

/// The folder of the openXC7 chipdb files, when the nextpnr build has no
/// default.
final _chipdb = Platform.environment['NEXTPNR_XILINX_CHIPDB'];

const _ecp5 = HarborFpgaTarget.ecp5(device: 'LFE5U-85F', package: 'CABGA381');

/// A top with 3 pins: a shift chain feeds every input of [dut] from `sin`,
/// and every output goes to a register and then XORs into `sout`.
String _bench(Module dut) {
  final ins = {
    for (final e in dut.inputs.entries)
      if (e.key != 'clk') e.key: e.value.width,
  };
  final outs = {for (final e in dut.outputs.entries) e.key: e.value.width};
  final inW = ins.values.reduce((a, b) => a + b);
  final outW = outs.values.reduce((a, b) => a + b);
  final b = StringBuffer()
    ..writeln('module bench_top(input clk, input sin, output reg sout);')
    ..writeln('  reg [${inW - 1}:0] ich;')
    ..writeln('  always @(posedge clk) ich <= {ich[${inW - 2}:0], sin};')
    ..writeln('  wire [${outW - 1}:0] ow;')
    ..writeln('  reg [${outW - 1}:0] oreg;')
    ..writeln('  always @(posedge clk) oreg <= ow;')
    ..writeln('  always @(posedge clk) sout <= ^oreg;')
    ..write('  ${dut.definitionName} u (\n    .clk(clk)');
  var lo = 0;
  for (final MapEntry(:key, :value) in ins.entries) {
    b.write(',\n    .$key(ich[${lo + value - 1}:$lo])');
    lo += value;
  }
  lo = 0;
  for (final MapEntry(:key, :value) in outs.entries) {
    b.write(',\n    .$key(ow[${lo + value - 1}:$lo])');
    lo += value;
  }
  b.writeln('\n  );\nendmodule');
  return b.toString();
}

HarborCsc _csc(HarborDeviceTarget? target) => HarborCsc(
  clk: Logic(),
  y: Logic(width: 10),
  cb: Logic(width: 10),
  cr: Logic(width: 10),
  coeff: [for (var k = 0; k < 9; k++) Logic(width: 16)],
  inOffset: [for (var j = 0; j < 3; j++) Logic(width: 10)],
  outOffset: [for (var i = 0; i < 3; i++) Logic(width: 8)],
  target: target,
);

/// Synthesizes [flow] on the bench, or on the conversion alone when
/// [bench] is false.
Future<Directory> _synth(
  String flow,
  HarborDeviceTarget? target, {
  bool bench = true,
}) async {
  final dut = _csc(target);
  await dut.build();
  final top = bench ? 'bench_top' : dut.definitionName;
  final dir = Directory.systemTemp.createTempSync('harbor_csc_pnr_');
  addTearDown(() => dir.deleteSync(recursive: true));
  final d = dir.path;
  File('$d/dut.sv').writeAsStringSync(dut.generateSynth());
  File('$d/top.sv').writeAsStringSync(_bench(dut));
  final yosys = await Process.run('yosys', [
    '-q',
    '-l',
    'yosys.log',
    '-p',
    'read_verilog -sv dut.sv${bench ? ' top.sv' : ''}; '
        '$flow -top $top -json bench.json',
  ], workingDirectory: d);
  expect(yosys.exitCode, 0, reason: '${yosys.stdout}${yosys.stderr}');
  return dir;
}

/// The parameters of every cell of [type] in the netlist of the bench.
/// Parameters that are bit strings become integers.
List<Map<String, Object?>> _cells(Directory dir, String type) {
  final json =
      jsonDecode(File('${dir.path}/bench.json').readAsStringSync())
          as Map<String, dynamic>;
  final out = <Map<String, Object?>>[];
  for (final m in (json['modules'] as Map<String, dynamic>).values) {
    final cells = (m as Map<String, dynamic>)['cells'] as Map<String, dynamic>;
    for (final c in cells.values) {
      if ((c as Map<String, dynamic>)['type'] != type) continue;
      final params = c['parameters'] as Map<String, dynamic>;
      out.add({
        for (final e in params.entries)
          e.key: e.value is String && RegExp(r'^[01]+$').hasMatch(e.value)
              ? int.parse(e.value as String, radix: 2)
              : e.value,
      });
    }
  }
  return out;
}

/// Runs nextpnr with a 45 minute limit, then checks the exit code and Fmax.
/// These nextpnr versions print no hold analysis, so hold is not checked.
Future<void> _route(Directory dir, List<String> nextpnr) async {
  final d = dir.path;
  final pnr = await Process.run('timeout', [
    '-k',
    '30',
    '45m',
    ...nextpnr,
    '--freq',
    '$_mhz',
    '--timing-allow-fail',
    '--seed',
    '1',
    '--json',
    'bench.json',
    '--report',
    'report.json',
    '--log',
    'pnr.log',
  ], workingDirectory: d);
  expect(pnr.exitCode, 0, reason: 'did not route: ${pnr.stderr}');
  final report =
      jsonDecode(File('$d/report.json').readAsStringSync())
          as Map<String, dynamic>;
  final fmax = (report['fmax'] as Map<String, dynamic>).values
      .map((v) => (v as Map<String, dynamic>)['achieved'] as num)
      .reduce((a, b) => a < b ? a : b);
  printOnFailure('${nextpnr.first}: ${fmax.toStringAsFixed(1)} MHz');
  expect(fmax, greaterThanOrEqualTo(_mhz));
}

void main() {
  // Without the bench, the module ports drive the multipliers, so each
  // register in a DSP48E1 comes from the conversion.
  test(
    'the color conversion registers each DSP48E1 input on its own',
    () async {
      final dir = await _synth('synth_xilinx -flatten', null, bench: false);
      final dsps = _cells(dir, 'DSP48E1');
      printOnFailure('$dsps');
      expect(dsps, hasLength(9));
      for (final d in dsps) {
        expect(d['AREG'], 1);
        expect(d['BREG'], 1);
        expect(d['MREG'], 1);
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip: _skip([]),
  );

  test(
    'the color conversion meets 148.5 MHz on an ECP5 85F',
    () async {
      final dir = await _synth('synth_ecp5', _ecp5);
      final mults = _cells(dir, 'MULT18X18D');
      printOnFailure('$mults');
      expect(mults, hasLength(9));
      for (final m in mults) {
        expect(m['REG_INPUTA_CLK'], 'CLK0');
        expect(m['REG_INPUTB_CLK'], 'CLK0');
        expect(m['REG_OUTPUT_CLK'], 'CLK0');
        expect(m['REG_PIPELINE_CLK'] ?? 'NONE', 'NONE');
      }
      await _route(dir, ['nextpnr-ecp5', '--85k', '--package', 'CABGA381']);
    },
    timeout: const Timeout(Duration(minutes: 50)),
    skip: _skip(['nextpnr-ecp5']),
  );

  test(
    'the color conversion meets 148.5 MHz on an Artix-7 200T',
    () async {
      final dir = await _synth('synth_xilinx -flatten', null);
      // Himbaechel may not time the DSP48E1 arcs, so the registers of the
      // multipliers are checked in the netlist.
      final dsps = _cells(dir, 'DSP48E1');
      printOnFailure('$dsps');
      expect(dsps, hasLength(9));
      for (final d in dsps) {
        expect(d['AREG'], isNot(0));
        expect(d['BREG'], isNot(0));
        expect(d['MREG'], 1);
      }
      // The AX7203 clock, LED1 and LED2 pins.
      File('${dir.path}/top.xdc').writeAsStringSync('''
set_property -dict {PACKAGE_PIN R4 IOSTANDARD LVCMOS15} [get_ports clk]
set_property -dict {PACKAGE_PIN B13 IOSTANDARD LVCMOS33} [get_ports sin]
set_property -dict {PACKAGE_PIN C13 IOSTANDARD LVCMOS33} [get_ports sout]
create_clock -period ${(1000 / _mhz).toStringAsFixed(3)} [get_ports clk]
''');
      await _route(dir, [
        'nextpnr-himbaechel',
        if (_chipdb != null) ...['--chipdb', '$_chipdb/chipdb-xc7a200t.bin'],
        '--device',
        'xc7a200tfbg484-2',
        '-o',
        'xdc=top.xdc',
      ]);
    },
    timeout: const Timeout(Duration(minutes: 50)),
    skip: _skip(['nextpnr-himbaechel']),
  );
}
