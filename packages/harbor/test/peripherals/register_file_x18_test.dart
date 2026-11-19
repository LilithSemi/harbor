import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _spartan7 = HarborFpgaTarget.spartan7(device: 's50', package: 'csga324');

bool _onPath(String tool) =>
    Process.runSync('sh', ['-c', 'command -v $tool']).exitCode == 0;

Future<HarborRegisterFile> _file(int entries, int width) async {
  final rf = HarborRegisterFile(
    numEntries: entries,
    dataWidth: width,
    numReadPorts: 1,
    byteWrite: true,
    reservedZero: false,
    target: _spartan7,
    useXilinxSdp72: true,
  );
  await rf.build();
  return rf;
}

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'a 2048 word, 64-bit file uses four x18 blocks with no depth mux',
    () async {
      final sv = (await _file(2048, 64)).dumpSystemVerilog();
      expect(RegExp(r'RAMB36E1 #').allMatches(sv), hasLength(4));
      expect(sv, contains('.READ_WIDTH_B(18)'));
      expect(sv, isNot(contains('rfBramDepthQ')));
    },
  );

  test('a 512 word file keeps the x72 block', () async {
    final sv = (await _file(512, 64)).dumpSystemVerilog();
    expect(RegExp(r'RAMB36E1 #').allMatches(sv), hasLength(1));
    expect(sv, contains('.READ_WIDTH_A(72)'));
  });

  test(
    'x18 blocks match an array under random byte writes',
    () async {
      final rf = await _file(2048, 64);
      final dir = Directory.systemTemp.createTempSync('harbor_x18_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/dut.sv').writeAsStringSync(rf.dumpSystemVerilog());
      final tb = File(
        'test/peripherals/register_file_x18_tb.sv',
      ).readAsStringSync().replaceFirst('DUT dut', '${rf.definitionName} dut');
      File('${dir.path}/tb.sv').writeAsStringSync(tb);
      final build = await Process.run('iverilog', [
        '-g2012',
        '-s',
        'tb',
        '-o',
        '${dir.path}/sim',
        '${dir.path}/tb.sv',
        '${dir.path}/dut.sv',
        '${Directory.current.path}/test/peripherals/ramb36_x18_model.sv',
      ]);
      expect(build.exitCode, 0, reason: '${build.stderr}${build.stdout}');
      final run = await Process.run('vvp', ['${dir.path}/sim']);
      expect('${run.stdout}', contains('PASS'), reason: '${run.stdout}');
    },
    skip: _onPath('iverilog') ? false : 'iverilog is not on PATH.',
  );
}
