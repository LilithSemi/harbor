@Tags(['slow'])
library;

import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

bool _onPath(String tool) =>
    Process.runSync('sh', ['-c', 'command -v $tool']).exitCode == 0;

void main() {
  if (!_onPath('yosys')) {
    print('l1_tag_ram_synth_test: skipped, yosys is not on PATH.');
  }
  tearDown(() async => Simulator.reset());

  test(
    'ECP5 synthesis keeps a 64-line tag store in LUT RAM',
    () async {
      final cache = HarborL1DCache(
        config: const HarborL1dCacheConfig(size: 4096, ways: 1, lineSize: 64),
        xlen: 64,
        reqAddrBits: 64,
        physicalAddresses: true,
        memFaultIn: Const(0),
        target: const HarborFpgaTarget.ecp5(
          device: 'lfe5u-85f',
          package: 'CABGA381',
        ),
      );
      await cache.build();
      final dir = Directory.systemTemp.createTempSync('harbor_l1_tag_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/dut.sv').writeAsStringSync(cache.dumpSystemVerilog());
      final yosys = await Process.run('yosys', [
        '-p',
        'read_verilog -sv dut.sv; '
            'synth_ecp5 -top ${cache.definitionName}; stat',
      ], workingDirectory: dir.path);
      expect(yosys.exitCode, 0, reason: '${yosys.stderr}');
      final out = '${yosys.stdout}';
      int count(String cell) {
        final m = RegExp('(\\d+)\\s+$cell\\b').allMatches(out);
        return m.isEmpty ? 0 : int.parse(m.last.group(1)!);
      }

      // The data RAM is 8 EBRs. The tags add none.
      expect(count('DP16KD'), 8);
      expect(count('TRELLIS_DPR16X4'), greaterThan(0));
    },
    skip: _onPath('yosys')
        ? false
        : 'yosys is not on PATH, so the LUT RAM mapping of the tag store is '
              'not checked. Put yosys on PATH to run this test.',
  );
}
