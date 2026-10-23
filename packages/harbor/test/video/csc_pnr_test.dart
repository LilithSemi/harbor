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

Future<Directory> _synth(String flow, HarborDeviceTarget? target) async {
  final dut = _csc(target);
  await dut.build();
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
    'read_verilog -sv dut.sv top.sv; $flow -top bench_top -json bench.json',
  ], workingDirectory: d);
  expect(yosys.exitCode, 0, reason: '${yosys.stdout}${yosys.stderr}');
  return dir;
}

/// Runs nextpnr with a 45 minute limit, then checks the exit code, Fmax
/// and hold.
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
  final log = File('$d/pnr.log').readAsStringSync();
  expect(
    RegExp(r'hold (time )?violation', caseSensitive: false).hasMatch(log),
    isFalse,
    reason: 'hold',
  );
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
  test(
    'the color conversion meets 148.5 MHz on an ECP5 85F',
    () async {
      final dir = await _synth('synth_ecp5', _ecp5);
      await _route(dir, ['nextpnr-ecp5', '--85k', '--package', 'CABGA381']);
    },
    timeout: const Timeout(Duration(minutes: 50)),
    skip: _skip(['nextpnr-ecp5']),
  );

  test(
    'the color conversion meets 148.5 MHz on an Artix-7 200T',
    () async {
      final dir = await _synth('synth_xilinx -flatten', null);
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
