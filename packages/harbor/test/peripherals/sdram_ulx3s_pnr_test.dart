@Tags(['slow'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

import 'sdram_ulx3s_top.dart';

const _seeds = [1, 2, 3];

/// Lowest median mem clock Fmax, over [_seeds], that passes the packed
/// run, in MHz: 125 MHz plus 10 percent, so a path that is close in this
/// small top does not fail in a full soc. The median, not the worst
/// seed, is judged against this bar: a single unlucky placement should
/// not fail the run on its own, and the reset fanout check above is the
/// structural gate that catches a real regression.
const _memMinMhz = 137.5;

/// Lowest median mem clock Fmax, over [_seeds], that passes the spread
/// run, in MHz. The spread placement moves a lot from seed to seed, so
/// this bar is lower.
const _memMinMhzSpread = 130;

/// nextpnr pre-place script for the spread run. It pins the bus master and
/// the reset sources mid-die, far from the sdram pads on the right edge, as
/// a soc bus and reset tree are. Paths that only meet timing when the whole
/// controller packs next to its pads fail in this run.
const _spreadScript = '''
ctx.createRectangularRegion("mid", 45, 15, 60, 30)
n = 0
for name, cell in ctx.cells:
    for pname, port in cell.ports:
        net = port.net
        if net is None or port.type != PortType.PORT_OUT:
            continue
        if net.name.startswith(("bist.", "sdramReset", "sysReset", "sdram.mem_reset_sync")):
            ctx.constrainCellToRegion(name, "mid")
            n += 1
            break
print("spread cells: %d" % n)
''';

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

      File('$d/spread.py').writeAsStringSync(_spreadScript);

      // One run at a time: parallel nextpnr runs use a lot of memory.
      for (final spread in [false, true]) {
        final runTag = spread ? 'spread' : 'packed';
        final memMhzBySeed = <int, num>{};
        for (final seed in _seeds) {
          final tag = '$runTag.$seed';
          final r = await Process.run('nextpnr-ecp5', [
            '--85k',
            '--package',
            'CABGA381',
            '--seed',
            '$seed',
            '--json',
            '${top.definitionName}.json',
            '--lpf',
            'top.lpf',
            if (spread) ...['--pre-place', 'spread.py'],
            '--textcfg',
            'top.$tag.config',
            '--write',
            'pnr.$tag.json',
            '--report',
            'report.$tag.json',
          ], workingDirectory: d);
          expect(r.exitCode, 0, reason: '$tag: ${r.stderr}');
          if (spread) {
            final m = RegExp(
              r'spread cells: (\d+)',
            ).firstMatch('${r.stdout}${r.stderr}');
            expect(int.parse(m!.group(1)!), greaterThan(0), reason: tag);
          }

          final report =
              jsonDecode(File('$d/report.$tag.json').readAsStringSync())
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
          print('$tag: mem $memMhz MHz, sys $sysMhz MHz');
          memMhzBySeed[seed] = memMhz;
          // Fmax is judged on the median across seeds below, not here:
          // one seed's placement noise should not fail the run on its
          // own. sys has no seed noise worth tracking, so it is still
          // checked per seed.
          expect(sysMhz, greaterThanOrEqualTo(62.5), reason: '$tag sys');

          // The reset fanout check is the primary gate: a structural
          // count, not a timing number, so it runs on every seed.
          final routed = File('$d/pnr.$tag.json');
          final clkNets = _checkIologic(routed);
          expect(clkNets, equals({mem.key}), reason: tag);
          _checkResetFanout(routed, mem.key, tag);
        }

        final median = _median(memMhzBySeed.values.toList());
        print('$runTag median mem Fmax: $median MHz ($memMhzBySeed)');
        expect(
          median,
          greaterThanOrEqualTo(spread ? _memMinMhzSpread : _memMinMhz),
          reason: '$runTag median mem',
        );
      }
    },
    skip: _skipReason(),
  );
}

/// The median of [xs]. With an even count, the mean of the two middle
/// values.
num _median(List<num> xs) {
  final s = [...xs]..sort();
  final mid = s.length ~/ 2;
  return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

/// Checks the reset and clear nets on the mem clock. A net on many flop
/// LSR pins must come straight from a flop, and no net may reach more
/// than 256 of them. One reset flop on every LSR in the controller, or a
/// LUT in front of a wide clear, gave long paths in a full soc.
///
/// This is the primary gate: it is a structural count, not a timing
/// number that moves with seed noise.
void _checkResetFanout(File routed, String memClk, String tag) {
  final json = jsonDecode(routed.readAsStringSync()) as Map<String, dynamic>;
  final module =
      (json['modules'] as Map<String, dynamic>).values.single
          as Map<String, dynamic>;
  final cells = (module['cells'] as Map<String, dynamic>).values
      .cast<Map<String, dynamic>>();
  // A bit can have more than one netname alias (yosys keeps every name a
  // wire ever had). Keep every alias, so a clock or LSR net is matched
  // by name even when it is not the last alias written to its bit.
  final netNames = <int, Set<String>>{};
  for (final e in (module['netnames'] as Map<String, dynamic>).entries) {
    for (final b in (e.value as Map<String, dynamic>)['bits'] as List) {
      if (b is int) {
        netNames.putIfAbsent(b, () => <String>{}).add(e.key);
      }
    }
  }
  bool isNet(int bit, String name) => netNames[bit]?.contains(name) ?? false;
  String nameOf(int bit) => netNames[bit]?.join('/') ?? '<unknown>';

  int? bit(Map<String, dynamic> c, String pin) {
    final conn = (c['connections'] as Map<String, dynamic>)[pin] as List?;
    return conn == null || conn.isEmpty ? null : conn.single as int?;
  }

  final driverType = <int, String>{};
  for (final c in cells) {
    final dirs = c['port_directions'] as Map<String, dynamic>;
    for (final MapEntry(key: pin, value: dir) in dirs.entries) {
      final b = bit(c, pin);
      if (dir == 'output' && b != null) driverType[b] = c['type'] as String;
    }
  }
  final fanout = <int, int>{};
  for (final c in cells) {
    if (c['type'] != 'TRELLIS_FF') continue;
    final clk = bit(c, 'CLK');
    final lsr = bit(c, 'LSR');
    if (clk == null || lsr == null || !isNet(clk, memClk)) continue;
    fanout[lsr] = (fanout[lsr] ?? 0) + 1;
  }
  final maxFanout = fanout.values.fold(0, (a, b) => a > b ? a : b);
  print('$tag: largest mem clock LSR fanout: $maxFanout');
  for (final MapEntry(key: net, value: n) in fanout.entries) {
    final name = nameOf(net);
    expect(n, lessThanOrEqualTo(256), reason: '$tag: $name on $n LSR pins');
    if (n > 32) {
      expect(
        driverType[net],
        'TRELLIS_FF',
        reason: '$tag: $name on $n LSR pins is not driven by a flop',
      );
    }
  }
  // A broken clock-net match (the alias bug this guards against) finds
  // zero mem-clock flops and passes with nothing checked. Every build of
  // this top has well over 400 flops with a reset or clear on the mem
  // clock, so a low total means the match is broken, not that the
  // design got smaller.
  final total = fanout.values.fold(0, (a, b) => a + b);
  expect(
    total,
    greaterThan(400),
    reason:
        '$tag: only $total mem clock LSR pins found; the clock or LSR net '
        'match is likely broken',
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
