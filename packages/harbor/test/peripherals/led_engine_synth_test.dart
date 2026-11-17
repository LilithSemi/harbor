@Tags(['slow'])
library;

import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

bool _onPath(String tool) =>
    Process.runSync('sh', ['-c', 'command -v $tool']).exitCode == 0;

String? _skip() {
  for (final tool in ['yosys', 'nextpnr-ecp5']) {
    if (!_onPath(tool)) return '$tool is not on PATH';
  }
  return null;
}

/// The SystemVerilog of [m], with the two-port `net_connect` helper changed
/// the same way the SoC export does it.
String _sv(Module m) =>
    SynthBuilder(m, SystemVerilogSynthesizer()).getSynthFileContents().map((f) {
      if (f.name != 'net_connect') return '${f.contents}\n';
      return 'module net_connect #(parameter int WIDTH=1) (w0, w1);\n'
          'inout wire [WIDTH-1:0] w0;\n'
          'inout wire [WIDTH-1:0] w1;\n'
          'assign w0 = w1;\n'
          'assign w1 = w0;\n'
          'endmodule\n';
    }).join();

HarborLedChannelConfig _board(String name) =>
    HarborBoard.get(name).ledChannels.single.config;

/// Packs [engine] for an ECP5 85F and gives its TRELLIS_COMB count.
Future<int> _combs(HarborLedEngine engine) async {
  await engine.build();
  final dir = Directory.systemTemp.createTempSync('harbor_led_area');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('${dir.path}/top.sv').writeAsStringSync(_sv(engine));
  final top = engine.definitionName;
  final y = await Process.run('yosys', [
    '-q',
    '-p',
    'read_verilog -sv ${dir.path}/top.sv; '
        'synth_ecp5 -top $top -json ${dir.path}/top.json',
  ]);
  expect(y.exitCode, 0, reason: '${y.stdout}\n${y.stderr}');
  final n = await Process.run('nextpnr-ecp5', [
    '--85k',
    '--package',
    'CABGA381',
    '--freq',
    '25',
    '--timing-allow-fail',
    '--seed',
    '1',
    '--pack-only',
    '--json',
    '${dir.path}/top.json',
  ]);
  expect(n.exitCode, 0, reason: '${n.stdout}\n${n.stderr}');
  final m = RegExp(
    r'TRELLIS_COMB:\s*(\d+)',
  ).allMatches('${n.stdout}\n${n.stderr}').last;
  final count = int.parse(m.group(1)!);
  // ignore: avoid_print
  print('${engine.definitionName}: TRELLIS_COMB $count');
  return count;
}

/// Maps [engine] for an Artix-7 family part and expects yosys to finish.
Future<void> _xilinx(HarborLedEngine engine) async {
  await engine.build();
  final dir = Directory.systemTemp.createTempSync('harbor_led_xilinx');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('${dir.path}/top.sv').writeAsStringSync(_sv(engine));
  final r = await Process.run('yosys', [
    '-q',
    '-p',
    'read_verilog -sv ${dir.path}/top.sv; '
        'synth_xilinx -family xc7 -top ${engine.definitionName}',
  ]);
  expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // Each gate sits about 10% above the measured count.
  final cases = <String, (HarborLedEngine Function(), int)>{
    'badge: 1 serial, ram, LUT, 16 pixels, 64 items': (
      () => HarborLedEngine(baseAddress: 0x10005000),
      1400,
    ),
    'badge with bram': (
      () => HarborLedEngine(
        baseAddress: 0x10005000,
        ramKind: HarborLedRamKind.bram,
      ),
      1300,
    ),
    'kc705 pwm': (
      () => HarborLedEngine(
        baseAddress: 0x10005000,
        maxPixels: 8,
        channels: [_board('kc705')],
      ),
      600,
    ),
    'arty pwm': (
      () => HarborLedEngine(
        baseAddress: 0x10005000,
        maxPixels: 6,
        channels: [_board('arty-s7-50')],
      ),
      650,
    ),
    'dma on Wishbone': (
      () => HarborLedEngine(
        baseAddress: 0x10005000,
        pixelSource: HarborLedPixelSource.dma,
        fabricKind: HarborFabricKind.wishbone,
      ),
      1650,
    ),
    'dma on AXI4': (
      () => HarborLedEngine(
        baseAddress: 0x10005000,
        pixelSource: HarborLedPixelSource.dma,
        fabricKind: HarborFabricKind.axi4,
      ),
      1640,
    ),
  };

  for (final MapEntry(key: name, value: (make, gate)) in cases.entries) {
    test('ecp5 $name stays at or below $gate COMB', () async {
      expect(await _combs(make()), lessThanOrEqualTo(gate));
    }, skip: _skip());
  }

  for (final board in ['kc705', 'arty-s7-50']) {
    test('xilinx $board pwm maps', () async {
      await _xilinx(
        HarborLedEngine(
          baseAddress: 0x10005000,
          maxPixels: board == 'kc705' ? 8 : 6,
          channels: [_board(board)],
        ),
      );
    }, skip: _skip());
  }
}
