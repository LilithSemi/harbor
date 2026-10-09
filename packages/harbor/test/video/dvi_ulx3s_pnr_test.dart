@Tags(['slow'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

import 'dvi_ulx3s_top.dart';

const _seeds = [1, 2, 3];

bool _onPath(String tool) =>
    Process.runSync('sh', ['-c', 'command -v $tool']).exitCode == 0;

String? _skipReason() {
  for (final tool in ['yosys', 'nextpnr-ecp5']) {
    if (!_onPath(tool)) return '$tool is not on PATH';
  }
  return null;
}

void main() {
  test(
    'ulx3s dvi top meets the 25 MHz pixel and 125 MHz shift clocks',
    () async {
      final board = HarborBoard.get('ulx3s-85f');
      final target = board.fpgaTarget(
        pins: [
          'clk',
          'rst_n',
          for (var i = 0; i < 4; i++) 'gpdi_dp[$i]',
          for (var i = 0; i < 8; i++) 'led[$i]',
        ],
      );
      final top = DviUlx3sTop(target: target);
      await top.build();

      final dir = Directory.systemTemp.createTempSync('harbor_dvi_pnr_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final d = dir.path;
      File('$d/top.sv').writeAsStringSync(top.generateSynth());
      File('$d/synth.ys').writeAsStringSync(
        target.generateYosysTcl(top.definitionName, svFiles: ['top.sv']),
      );
      File('$d/top.lpf').writeAsStringSync(target.generateConstraints());

      final yosys = await Process.run('yosys', [
        '-q',
        '-l',
        'yosys.log',
        '-s',
        'synth.ys',
      ], workingDirectory: d);
      expect(yosys.exitCode, 0, reason: '${yosys.stdout}${yosys.stderr}');

      final runs = await Future.wait([
        for (final seed in _seeds)
          Process.run('nextpnr-ecp5', [
            '--85k',
            '--package',
            'CABGA381',
            '--seed',
            '$seed',
            '--json',
            '${top.definitionName}.json',
            '--lpf',
            'top.lpf',
            '--textcfg',
            'top.$seed.config',
            '--report',
            'report.$seed.json',
          ], workingDirectory: d),
      ]);
      for (final (i, r) in runs.indexed) {
        expect(r.exitCode, 0, reason: 'seed ${_seeds[i]}: ${r.stderr}');
      }

      for (final seed in _seeds) {
        final report =
            jsonDecode(File('$d/report.$seed.json').readAsStringSync())
                as Map<String, dynamic>;
        final fmax = (report['fmax'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, v as Map<String, dynamic>),
        );
        // The pll clkop net is named after its feedback wire.
        final shift = fmax.entries.singleWhere(
          (e) => (e.value['constraint'] as num) == 125,
        );
        final pixel = fmax.entries.singleWhere(
          (e) => e.key.contains('pixel_clk'),
        );
        final shiftMhz = shift.value['achieved'] as num;
        final pixelMhz = pixel.value['achieved'] as num;
        expect(pixelMhz, greaterThanOrEqualTo(25), reason: 'seed $seed pixel');
        expect(shiftMhz, greaterThanOrEqualTo(125), reason: 'seed $seed shift');

        // The serializer lock needs the symbols and the pixel toggle to cross
        // inside one shift period. Then the symbol sample is 2 to 3 shift
        // edges after the pixel edge, 2 or more before the next change.
        final crossing = (report['critical_paths'] as List)
            .cast<Map<String, dynamic>>()
            .singleWhere(
              (p) =>
                  p['from'] == 'posedge ${pixel.key}' &&
                  p['to'] == 'posedge ${shift.key}',
            );
        final crossNs = (crossing['path'] as List).fold<double>(
          0,
          (sum, step) => sum + ((step as Map)['delay'] as num),
        );
        printOnFailure(
          'seed $seed: pixel $pixelMhz MHz, shift $shiftMhz MHz, '
          'pixel to shift $crossNs ns',
        );
        expect(crossNs, lessThan(1000 / 125), reason: 'seed $seed crossing');
      }
    },
    skip: _skipReason(),
  );
}
