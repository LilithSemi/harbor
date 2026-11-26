@Tags(['slow'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

const _sdramPorts = [
  'sdram_clk',
  'sdram_cke',
  'sdram_cs_n',
  'sdram_ras_n',
  'sdram_cas_n',
  'sdram_we_n',
  'sdram_ba',
  'sdram_addr',
  'sdram_dqm',
  'sdram_dq',
];
const _sdramBase = 0x80000000;
const _displayBase = 0x10008000;

/// A register master that turns the display on once, a little after reset.
class _BootMaster extends BridgeModule {
  _BootMaster() : super('ScanBootMaster', name: 'boot') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final i = addInterface(
      Axi4LiteInterface(addressWidth: 32, dataWidth: 32),
      name: 'dataBus',
      role: PairRole.provider,
    ).internalInterface!;
    final out = i.getPorts([PairDirection.fromProvider]);
    final inp = i.getPorts([PairDirection.fromConsumer]);
    final wait = Logic(name: 'wait', width: 12);
    final awDone = Logic(name: 'aw_done');
    final wDone = Logic(name: 'w_done');
    final done = Logic(name: 'done');
    final writing = (wait[11] & ~done).named('writing');
    Sequential(input('clk'), reset: input('reset'), [
      If(
        ~wait[11],
        then: [wait < wait + 1],
        orElse: [
          If(inp['AWREADY']! & ~awDone, then: [awDone < Const(1)]),
          If(inp['WREADY']! & ~wDone, then: [wDone < Const(1)]),
          If(inp['BVALID']! & writing, then: [done < Const(1)]),
        ],
      ),
    ]);
    for (final e in out.entries) {
      e.value <=
          switch (e.key) {
            'AWADDR' => Const(_displayBase, width: 32),
            'WDATA' => Const(1, width: 32),
            'WSTRB' => Const(0xf, width: 4),
            'AWVALID' => writing & ~awDone,
            'WVALID' => writing & ~wDone,
            'BREADY' => Const(1),
            _ => Const(0, width: e.value.width),
          };
    }
  }
}

bool _onPath(String tool) =>
    Process.runSync('sh', ['-c', 'command -v $tool']).exitCode == 0;

String? _skipReason() {
  for (final tool in ['yosys', 'nextpnr-ecp5']) {
    if (!_onPath(tool)) return '$tool is not on PATH';
  }
  return null;
}

Future<void> _pnr(int sysHz, {int? memHz}) async {
  final sdramHz = memHz ?? sysHz;
  {
    {
      final board = HarborBoard.get('ulx3s-85f');
      final sdramPins = board.pins.keys.where((k) => k.startsWith('sdram_'));
      final target = board.fpgaTarget(
        pins: ['clk', for (var i = 0; i < 4; i++) 'gpdi_dp[$i]', ...sdramPins],
      );
      final soc = HarborSoC(
        name: 'ScanDisplayUlx3s',
        compatible: 'test,scan-display-ulx3s',
        target: target,
        fabricKind: HarborFabricKind.axi4,
        clocks: [
          HarborClockConfig.fixed(
            name: 'sys',
            frequency: sysHz,
            sourceFrequency: 25000000,
            isPrimary: true,
          ),
          if (memHz != null)
            HarborClockConfig.fixed(
              name: 'sdram',
              frequency: memHz,
              sourceFrequency: 25000000,
            ),
        ],
      );
      soc.addMaster(_BootMaster());
      final sdram = soc.addPeripheral(
        HarborSdram(
          config: const HarborSdramConfig.as4c16m16sb6(),
          baseAddress: _sdramBase,
          clockHz: sdramHz,
          busClockSync: memHz == null,
          busAddressWidth: 32,
          protocol: HarborFabricKind.axi4,
          scanoutPorts: 1,
          scanoutLine: HarborScanoutLine.forMode(
            timing: const HarborDisplayTiming.vga640x480(),
            formats: const [HarborPixelFormat.rgb565],
            pixelClockHz: 25000000,
            sdramClockHz: sdramHz,
          ),
          target: target,
        ),
      );
      if (memHz != null) {
        final mem = soc.clockDomain('sdram')!;
        sdram.input('mem_clk').srcConnection! <= mem.clk;
        sdram.input('mem_reset').srcConnection! <= mem.reset;
      }
      for (final p in _sdramPorts) {
        soc.exposePin(sdram, p, externalName: p);
      }
      soc.addScanoutDisplay(
        sdram: sdram,
        timing: const HarborDisplayTiming.vga640x480(),
        pixelClockHz: 25000000,
        framebufferBase: 0x81e00000,
        baseAddress: _displayBase,
      );
      soc.buildFabric();

      final dir = Directory.systemTemp.createTempSync('harbor_scan_pnr_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final d = dir.path;
      await soc.generateAll(dir);
      File(
        '$d/synth.ys',
      ).writeAsStringSync(target.generateYosysTcl(soc.definitionName));

      final yosys = await Process.run('yosys', [
        '-q',
        '-l',
        'yosys.log',
        '-s',
        'synth.ys',
      ], workingDirectory: d);
      expect(yosys.exitCode, 0, reason: '${yosys.stdout}${yosys.stderr}');
      final log = File('$d/yosys.log').readAsStringSync();
      final cells = RegExp(
        r'^\s+(\d+)\s+(TRELLIS_\w+|CCU2C|DP16KD|EHXPLLL|MULT18X18D|LUT4)\s*$',
        multiLine: true,
      ).allMatches(log.substring(log.lastIndexOf('Printing statistics')));
      print(
        'yosys cells: '
        '${[for (final m in cells) '${m.group(2)} ${m.group(1)}'].join(', ')}',
      );

      final lpf = dir.listSync().whereType<File>().singleWhere(
        (f) => f.path.endsWith('.lpf'),
      );
      final seeds = [1, 2, 3];
      final runs = await Future.wait([
        for (final seed in seeds)
          Process.run('nextpnr-ecp5', [
            '--85k',
            '--package',
            'CABGA381',
            '--speed',
            board.speedGrade,
            '--seed',
            '$seed',
            '--json',
            '${soc.definitionName}.json',
            '--lpf',
            lpf.path,
            '--report',
            'report.$seed.json',
          ], workingDirectory: d),
      ]);
      for (final (i, r) in runs.indexed) {
        expect(r.exitCode, 0, reason: 'seed ${seeds[i]}: ${r.stderr}');
        final out = '${r.stdout}${r.stderr}';
        final util = RegExp(
          r'TRELLIS_COMB:\s+(\d+)/\s*(\d+)',
        ).allMatches(out).lastOrNull;
        print('seed ${seeds[i]} area: ${util?.group(0)}');
      }
      for (final seed in seeds) {
        final report =
            jsonDecode(File('$d/report.$seed.json').readAsStringSync())
                as Map<String, dynamic>;
        final fmax = (report['fmax'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, v as Map<String, dynamic>),
        );
        for (final e in fmax.entries) {
          print(
            'seed $seed ${e.key}: ${e.value['achieved']} MHz '
            '(constraint ${e.value['constraint']})',
          );
        }
        if (memHz != null) {
          final mem = fmax.entries.singleWhere(
            (e) => e.key.contains('sdram_mem_port'),
          );
          expect(
            mem.value['achieved'] as num,
            greaterThanOrEqualTo(memHz / 1e6),
            reason: 'seed $seed sdram clock',
          );
        }
        for (final e in fmax.entries) {
          expect(
            e.value['achieved'] as num,
            greaterThanOrEqualTo(e.value['constraint'] as num),
            reason: 'seed $seed ${e.key}',
          );
        }
      }
    }
  }
}

void main() {
  test(
    'ulx3s soc with the scanout display helper places and routes at 25 MHz',
    () => _pnr(25000000),
    skip: _skipReason(),
    timeout: const Timeout(Duration(minutes: 30)),
  );

  test(
    'ulx3s soc with the scanout display helper and a 125 MHz sdram domain '
    'places and routes',
    () => _pnr(25000000, memHz: 125000000),
    skip: _skipReason(),
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
