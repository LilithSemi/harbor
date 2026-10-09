@Tags(['slow'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

import 'sdram_ulx3s_top.dart';

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
    'ulx3s sdram top meets timing with every sdram pad in iologic',
    () async {
      final board = HarborBoard.get('ulx3s-85f');
      final sdramPins = board.pins.keys.where((k) => k.startsWith('sdram_'));
      final target = board.fpgaTarget(
        pins: [
          'clk',
          'rst_n',
          for (var i = 0; i < 8; i++) 'led[$i]',
          ...sdramPins,
        ],
      );
      final top = SdramUlx3sTop(target: target);
      await top.build();

      final dir = Directory.systemTemp.createTempSync('harbor_sdram_pnr_');
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
            '--write',
            'pnr.$seed.json',
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
        final mem = fmax.entries.singleWhere(
          (e) => (e.value['constraint'] as num) == 125,
        );
        final sys = fmax.entries.singleWhere(
          (e) => (e.value['constraint'] as num) == 62.5,
        );
        final memMhz = mem.value['achieved'] as num;
        final sysMhz = sys.value['achieved'] as num;
        printOnFailure('seed $seed: mem $memMhz MHz, sys $sysMhz MHz');
        expect(memMhz, greaterThanOrEqualTo(125), reason: 'seed $seed mem');
        expect(sysMhz, greaterThanOrEqualTo(62.5), reason: 'seed $seed sys');

        final clkNets = _checkIologic(File('$d/pnr.$seed.json'));
        expect(clkNets, equals({mem.key}), reason: 'seed $seed');
      }
    },
    skip: _skipReason(),
  );
}

/// Checks that each sdram pad has an iologic cell at its own site, fed from
/// it. Returns the set of clock nets the sdram iologic cells use.
Set<String> _checkIologic(File routed) {
  final json = jsonDecode(routed.readAsStringSync()) as Map<String, dynamic>;
  final module =
      (json['modules'] as Map<String, dynamic>).values.single
          as Map<String, dynamic>;
  final cells = (module['cells'] as Map<String, dynamic>).values
      .cast<Map<String, dynamic>>();
  final ports = (module['ports'] as Map<String, dynamic>)
      .cast<String, Map<String, dynamic>>();

  final netNames = <int, String>{};
  for (final e in (module['netnames'] as Map<String, dynamic>).entries) {
    for (final b in (e.value as Map<String, dynamic>)['bits'] as List) {
      if (b is int) netNames[b] = e.key;
    }
  }
  String? bel(Map<String, dynamic> c) =>
      (c['attributes'] as Map<String, dynamic>)['NEXTPNR_BEL'] as String?;
  List<dynamic> conn(Map<String, dynamic> c, String pin) =>
      (c['connections'] as Map<String, dynamic>)[pin] as List? ?? const [];

  final byBel = {for (final c in cells) bel(c): c};
  final ioByPad = {
    for (final c in cells)
      if (c['type'] == 'TRELLIS_IO' && conn(c, 'B').isNotEmpty)
        conn(c, 'B').single: c,
  };

  var padded = 0;
  final clkNets = <String>{};
  for (final MapEntry(key: name, value: port) in ports.entries) {
    if (!name.startsWith('sdram_')) continue;
    final bits = port['bits'] as List;
    for (final (i, bit) in bits.indexed) {
      final pad = '$name[$i]';
      final io = ioByPad[bit];
      expect(io, isNotNull, reason: '$pad has no TRELLIS_IO');
      final parts = bel(io!)!.split('/');
      expect(parts[2], startsWith('PIO'), reason: pad);
      final letter = parts[2].substring(3);
      final site = '${parts[0]}/${parts[1]}';
      final iol =
          byBel['$site/IOLOGIC$letter'] ?? byBel['$site/SIOLOGIC$letter'];
      expect(iol, isNotNull, reason: '$pad at $site has no iologic');
      expect(conn(io, 'IOLDO'), isNotEmpty, reason: '$pad output bypasses');
      expect(conn(iol!, 'IOLDO'), equals(conn(io, 'IOLDO')), reason: pad);
      if (name == 'sdram_dq') {
        expect(conn(iol, 'IOLTO'), equals(conn(io, 'IOLTO')), reason: pad);
        expect(conn(io, 'IOLTO'), isNotEmpty, reason: '$pad oe bypasses');
        expect(conn(iol, 'PADDI'), equals(conn(io, 'O')), reason: pad);
        expect(conn(iol, 'INFF'), isNotEmpty, reason: '$pad input bypasses');
      }
      clkNets.add(netNames[conn(iol, 'CLK').single as int]!);
      padded++;
    }
  }
  expect(padded, 39);
  return clkNets;
}
