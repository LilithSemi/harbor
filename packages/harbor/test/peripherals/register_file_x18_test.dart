import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _spartan7 = HarborFpgaTarget.spartan7(device: 's50', package: 'csga324');

bool _onPath(String tool) =>
    Process.runSync('sh', ['-c', 'command -v $tool']).exitCode == 0;

Future<HarborRegisterFile> _file(
  int entries,
  int width, {
  int reads = 1,
  bool zero = false,
  bool sdp72 = true,
}) async {
  final rf = HarborRegisterFile(
    numEntries: entries,
    dataWidth: width,
    numReadPorts: reads,
    byteWrite: true,
    reservedZero: zero,
    target: _spartan7,
    useXilinxSdp72: sdp72,
  );
  await rf.build();
  return rf;
}

typedef _Shape = ({
  String name,
  int entries,
  int width,
  int reads,
  bool zero,
  bool sdp72,
});

const _shapes = <_Shape>[
  (
    name: 'x18 2048x64',
    entries: 2048,
    width: 64,
    reads: 1,
    zero: false,
    sdp72: true,
  ),
  (
    name: 'x18 4096x32 depth mux, x0',
    entries: 4096,
    width: 32,
    reads: 1,
    zero: true,
    sdp72: true,
  ),
  (
    name: 'x18 2048x64 two reads',
    entries: 2048,
    width: 64,
    reads: 2,
    zero: false,
    sdp72: true,
  ),
  (
    name: 'x72 512x64',
    entries: 512,
    width: 64,
    reads: 1,
    zero: false,
    sdp72: true,
  ),
  (
    name: 'x72 1024x64 depth mux, two reads, x0',
    entries: 1024,
    width: 64,
    reads: 2,
    zero: true,
    sdp72: true,
  ),
  (
    name: 'x36 1024x64',
    entries: 1024,
    width: 64,
    reads: 1,
    zero: false,
    sdp72: false,
  ),
  (
    name: 'x36 2048x32 depth mux, two reads, x0',
    entries: 2048,
    width: 32,
    reads: 2,
    zero: true,
    sdp72: false,
  ),
];

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

  test('every write port reads the old word on a collision', () async {
    for (final f in [
      await _file(2048, 64),
      await _file(512, 64),
      await _file(1024, 64, sdp72: false),
    ]) {
      final sv = f.dumpSystemVerilog();
      expect(sv, contains('READ_FIRST'));
      Simulator.reset();
    }
  });

  for (final shape in _shapes) {
    test(
      '${shape.name} matches an array under random byte writes',
      () async {
        final rf = await _file(
          shape.entries,
          shape.width,
          reads: shape.reads,
          zero: shape.zero,
          sdp72: shape.sdp72,
        );
        final dir = Directory.systemTemp.createTempSync('harbor_x18_');
        addTearDown(() => dir.deleteSync(recursive: true));
        File('${dir.path}/dut.sv').writeAsStringSync(rf.dumpSystemVerilog());
        final tb = File('test/peripherals/register_file_x18_tb.sv')
            .readAsStringSync()
            .replaceAll('@DEPTH@', '${shape.entries}')
            .replaceAll('@WIDTH@', '${shape.width}')
            .replaceAll('@RESZ@', shape.zero ? '1' : '0')
            .replaceAll('@NRD@', '${shape.reads}')
            .replaceAll('@NAME@', rf.definitionName)
            .replaceAll(
              '@PORTS@',
              shape.reads == 2
                  ? ', .rd1_addr(rd1_addr), .rd1_data(rd1_data)'
                  : '',
            );
        File('${dir.path}/tb.sv').writeAsStringSync(tb);
        final build = await Process.run('iverilog', [
          '-g2012',
          '-s',
          'tb',
          '-o',
          '${dir.path}/sim',
          '${dir.path}/tb.sv',
          '${dir.path}/dut.sv',
          '${Directory.current.path}/test/peripherals/ramb36_model.sv',
        ]);
        expect(build.exitCode, 0, reason: '${build.stderr}${build.stdout}');
        final run = await Process.run('vvp', ['${dir.path}/sim']);
        expect('${run.stdout}', contains('PASS'), reason: '${run.stdout}');
      },
      skip: _onPath('iverilog') ? false : 'iverilog is not on PATH.',
    );
  }
}
