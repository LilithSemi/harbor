@Tags(['slow'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:harbor/src/arith/fp_format.dart';
import 'package:harbor/src/arith/fpu.dart';
import 'package:harbor/src/arith/fpu_config.dart';
import 'package:harbor/src/arith/vector_lane.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

bool _onPath(String tool) =>
    Process.runSync('sh', ['-c', 'command -v $tool']).exitCode == 0;

String? _skipReason() {
  for (final tool in ['yosys', 'nextpnr-ecp5']) {
    if (!_onPath(tool)) return '$tool is not on PATH';
  }
  return null;
}

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
  final chunks = (outW + 15) ~/ 16;
  final b = StringBuffer()
    ..writeln('module bench_top(input clk, input sin, output reg sout);')
    ..writeln('  reg [${inW - 1}:0] ich;')
    ..writeln('  always @(posedge clk) ich <= {ich[${inW - 2}:0], sin};')
    ..writeln('  wire [${outW - 1}:0] ow;')
    ..writeln('  reg [${outW - 1}:0] oreg;')
    ..writeln('  always @(posedge clk) oreg <= ow;')
    ..writeln('  reg [${chunks - 1}:0] ox;');
  for (var i = 0; i < chunks; i++) {
    final hi = (i * 16 + 15).clamp(0, outW - 1);
    b.writeln('  always @(posedge clk) ox[$i] <= ^oreg[$hi:${i * 16}];');
  }
  b
    ..writeln('  always @(posedge clk) sout <= ^ox;')
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

/// Synthesizes and routes [dut] in the bench top on an ECP5 85F, then
/// checks that it routes and that its area is at most the ceilings.
Future<void> _route(
  Module dut, {
  required int comb,
  required int ff,
  required num minMhz,
}) async {
  await dut.build();
  final dir = Directory.systemTemp.createTempSync('harbor_fpu_pnr_');
  addTearDown(() => dir.deleteSync(recursive: true));
  final d = dir.path;
  File('$d/dut.sv').writeAsStringSync(dut.generateSynth());
  File('$d/top.sv').writeAsStringSync(_bench(dut));

  final yosys = await Process.run('yosys', [
    '-q',
    '-l',
    'yosys.log',
    '-p',
    'read_verilog -sv dut.sv top.sv; '
        'synth_ecp5 -top bench_top -json bench.json',
  ], workingDirectory: d);
  expect(yosys.exitCode, 0, reason: '${yosys.stdout}${yosys.stderr}');

  final pnr = await Process.run('nextpnr-ecp5', [
    '--85k',
    '--package',
    'CABGA381',
    '--freq',
    '100',
    '--timing-allow-fail',
    '--seed',
    '1',
    '--json',
    'bench.json',
    '--report',
    'report.json',
  ], workingDirectory: d);
  expect(pnr.exitCode, 0, reason: '${pnr.stderr}');

  final report =
      jsonDecode(File('$d/report.json').readAsStringSync())
          as Map<String, dynamic>;
  final use = (report['utilization'] as Map<String, dynamic>).map(
    (k, v) => MapEntry(k, (v as Map<String, dynamic>)['used'] as int),
  );
  final fmax = (report['fmax'] as Map<String, dynamic>).values
      .map((v) => (v as Map<String, dynamic>)['achieved'] as num)
      .reduce((a, b) => a < b ? a : b);
  printOnFailure(
    '${dut.definitionName}: ${use['TRELLIS_COMB']} comb, '
    '${use['TRELLIS_FF']} ff, ${fmax.toStringAsFixed(1)} MHz',
  );
  expect(use['TRELLIS_COMB'], lessThanOrEqualTo(comb));
  expect(use['TRELLIS_FF'], lessThanOrEqualTo(ff));
  expect(fmax, greaterThanOrEqualTo(minMhz));
}

void main() {
  // Ceilings are 10 percent over the routed bench top, which adds one
  // register per input and output bit.
  test(
    'glacier lane at 3 stages routes within its area ceiling',
    () async {
      final lane = HarborVectorLane(
        HarborFpuConfig(
          formats: [HarborFpFormat.fp16, HarborFpFormat.fp32],
          widening: [(HarborFpFormat.fp16, HarborFpFormat.fp32)],
          ops: {HarborFpOp.madd, HarborFpOp.intToFp, HarborFpOp.fpToInt},
          stages: 3,
          intWidths: [32],
          // Glacier runs only the widening madd.
          mulFormats: const {},
        ),
        laneWidth: 32,
        liveSew: true,
      );
      await _route(lane, comb: _laneComb, ff: _laneFf, minMhz: _laneMhz);
    },
    timeout: const Timeout(Duration(minutes: 60)),
    skip: _skipReason(),
  );

  test(
    'scalar fp64 fpu with every op at 4 stages routes within its area '
    'ceiling',
    () async {
      final fpu = HarborFpu(
        HarborFpuConfig(
          formats: [HarborFpFormat.fp32, HarborFpFormat.fp64],
          ops: HarborFpOp.values.toSet(),
          stages: 4,
          intWidths: [32, 64],
        ),
      );
      await _route(fpu, comb: _scalarComb, ff: _scalarFf, minMhz: _scalarMhz);
    },
    timeout: const Timeout(Duration(minutes: 120)),
    skip: _skipReason(),
  );
}

// Routed bench tops on 2026-10-10: lane 4847 comb and 912 ff, scalar
// 18416 comb and 2905 ff.
const _laneComb = 5332;
const _laneFf = 1003;
const _scalarComb = 20258;
const _scalarFf = 3196;

// Fmax floors, well under the routed numbers in speed-roundpack-report.md
// (lane N=3 57-62 MHz, scalar fp64 N=4 45.7-50.1 MHz across seeds). This
// bench's extra shift-chain I/O differs from that report's standalone
// block benches, so these catch a severe regression, not a target gate.
const _laneMhz = 40.0;
const _scalarMhz = 30.0;
