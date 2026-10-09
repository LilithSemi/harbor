import 'dart:io';

import 'package:harbor/harbor.dart';
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

void main() {
  test('ulx3s soc with the sdram on a shared pll', () async {
    final board = HarborBoard.get('ulx3s-85f');
    final pins = board.pins.keys.where((k) => k.startsWith('sdram_')).toList();
    expect(pins, hasLength(39));
    final target = board.fpgaTarget(pins: ['clk', ...pins]);

    final soc = HarborSoC(
      name: 'SdramUlx3sSoC',
      compatible: 'test,sdram-ulx3s',
      busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
      target: target,
      clocks: [
        const HarborClockConfig(
          name: 'sdram',
          rate: HarborFixedClockRate(125000000),
          sourceFrequency: 25000000,
          coClkosSecondary: (name: 'sys', frequency: 62500000),
        ),
      ],
    );
    final sdram = HarborSdram(
      config: const HarborSdramConfig.as4c16m16sb6(),
      baseAddress: 0x40000000,
      clockHz: 125000000,
      target: target,
    );
    soc.addPeripheral(sdram, clockDomainName: 'sys');
    final mem = soc.clockDomain('sdram')!;
    sdram.input('mem_clk').srcConnection! <= mem.clk;
    sdram.input('mem_reset').srcConnection! <= mem.reset;
    for (final p in _sdramPorts) {
      soc.exposePin(sdram, p, externalName: p);
    }

    final dir = Directory.systemTemp.createTempSync('harbor_sdram_ulx3s_');
    addTearDown(() => dir.deleteSync(recursive: true));
    await soc.generateAll(dir);

    final lpfFile = dir.listSync().whereType<File>().singleWhere(
      (f) => f.path.endsWith('.lpf'),
    );
    final lpf = lpfFile.readAsStringSync();
    for (final p in pins) {
      final site = board.pins[p]!.split(' ').first;
      expect(lpf, contains('LOCATE COMP "$p" SITE "$site";'));
    }

    final sv = Directory(
      '${dir.path}/rtl',
    ).listSync().whereType<File>().map((f) => f.readAsStringSync()).join('\n');
    final top = File('${dir.path}/rtl/SdramUlx3sSoC.sv').readAsStringSync();
    for (final p in _sdramPorts) {
      expect(top, matches(RegExp('(output|inout) .*\\b$p\\b')), reason: p);
    }
    expect(RegExp(r'\bEHXPLLL\b\s*#').allMatches(sv), hasLength(1));
  });
}
