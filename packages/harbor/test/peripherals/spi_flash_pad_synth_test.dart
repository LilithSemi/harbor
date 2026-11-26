import 'dart:async';
import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

String? _skipReason() =>
    Process.runSync('sh', ['-c', 'command -v yosys']).exitCode == 0
    ? null
    : 'yosys is not on PATH';

HarborSpiFlashController _controller() => HarborSpiFlashController(
  config: const HarborSpiFlashConfig.w25q128(),
  baseAddress: 0x20000000,
  busAddressWidth: 32,
  clockHz: 100000000,
  ownPads: true,
);

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

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('owned quad pads emit no parenthesised pad assign', () async {
    final f = _controller();
    await f.build();
    final sv = _sv(f);
    expect(sv, isNot(contains('assign (')));
    expect(sv, contains('inout wire [3:0] pad'));
    expect(f.inOut('spi_io').width, 4);
  });

  for (final flow in ['synth_ecp5', 'synth_xilinx']) {
    test('yosys $flow maps four tristate drivers on two enables', () async {
      final f = _controller();
      await f.build();
      final dir = Directory.systemTemp.createTempSync('harbor_flash_pad');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/top.sv').writeAsStringSync(_sv(f));
      final r = await Process.run('yosys', [
        '-p',
        'read_verilog -sv ${dir.path}/top.sv; '
            '$flow -top ${f.definitionName}; '
            'write_verilog -noattr ${dir.path}/net.v',
      ]);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      final net = File('${dir.path}/net.v').readAsStringSync();
      final tbufs = RegExp(
        r'\\\$_TBUF_\s+\S+\s*\(\s*\.A\([^)]*\),\s*\.E\(([^)]*)\)',
      ).allMatches(net).map((m) => m.group(1)).toList();
      expect(tbufs, hasLength(4));
      expect(tbufs.toSet(), hasLength(2));
    }, skip: _skipReason());
  }

  test('IO2 and IO3 are driven high when the read FSM is idle', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final f = _controller();
    f.input('clk').srcConnection! <= clk;
    f.input('reset').srcConnection! <= reset;
    f.input('wr_req').srcConnection! <= Const(0);
    f.input('wr_op').srcConnection! <= Const(0);
    f.input('wr_addr').srcConnection! <= Const(0, width: 24);
    f.input('wr_len').srcConnection! <= Const(0, width: 9);
    f.input('wr_data').srcConnection! <= Const(0, width: 8);
    f.input('bus_CYC').srcConnection! <= Const(0);
    f.input('bus_STB').srcConnection! <= Const(0);
    f.input('bus_WE').srcConnection! <= Const(0);
    f.input('bus_ADR').srcConnection! <=
        Const(0, width: f.input('bus_ADR').width);
    f.input('bus_DAT_MOSI').srcConnection! <= Const(0, width: 32);
    f.input('bus_SEL').srcConnection! <=
        Const(0xF, width: f.input('bus_SEL').width);
    await f.build();
    reset.inject(1);
    Simulator.setMaxSimTime(100000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;
    await clk.nextPosedge;
    final pad = f.inOut('spi_io').value;
    expect(pad[3], LogicValue.one);
    expect(pad[2], LogicValue.one);
    await Simulator.endSimulation();
  });
}
