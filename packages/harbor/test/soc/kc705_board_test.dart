import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

/// Sites written again from the Xilinx KC705 board file (part0_pins.xml).
/// The DDR3, HDMI and SI5324 sites are from LiteX.
const _expected = <String, String>{
  'clk': 'AD12 DIFF_SSTL15',
  'clk_n': 'AD11 DIFF_SSTL15',
  'reset': 'AB7 LVCMOS15',
  'uart_tx': 'K24 LVCMOS25',
  'uart_rx': 'M19 LVCMOS25',
  'led[0]': 'AB8 LVCMOS15',
  'led[4]': 'AE26 LVCMOS25',
  'led[7]': 'F16 LVCMOS25',
  'btn_c': 'G12 LVCMOS25',
  'btn_e': 'AG5 LVCMOS15',
  'dip[3]': 'Y28 LVCMOS25',
  'spi_cs_n': 'U19 LVCMOS25',
  'spi_io[0]': 'P24 LVCMOS25',
  'pcie_refclk_p': 'U8 MGT',
  'pcie_perst_n': 'G25 LVCMOS25 PULLTYPE=PULLUP',
  'pcie_rxp[7]': 'AA4 MGT',
  'pcie_txn[7]': 'Y1 MGT',
  'eth0_gmii_gtx_clk': 'K30 LVCMOS25',
  'eth0_gmii_rxd[7]': 'T28 LVCMOS25',
  'eth0_mdio': 'J21 LVCMOS25',
  'i2c_scl': 'K21 LVCMOS25',
  'sfp_txp': 'H2 MGT',
  'sfp_rxp': 'G4 MGT',
  'sfp_rxn': 'G3 MGT',
  'sdram_ck[0]': 'AG10 DIFF_SSTL15',
  'sdram_cs_n[0]': 'AC12 SSTL15',
  'sdram_cke[0]': 'AF10 SSTL15',
  'sdram_odt[0]': 'AD8 SSTL15',
  'sdram_ck_n[0]': 'AH10 DIFF_SSTL15',
  'sdram_ck[1]': 'AE11 DIFF_SSTL15',
  'sdram_ck_n[1]': 'AF11 DIFF_SSTL15',
  'sdram_cke[1]': 'AE10 SSTL15',
  'sdram_cs_n[1]': 'AE8 SSTL15',
  'sdram_odt[1]': 'AC10 SSTL15',
  'sfp_refclk_p': 'G8 MGT',
  'sfp_tx_disable': 'Y20 LVCMOS25',
  'hdmi_clk': 'K18 LVCMOS25',
  'hdmi_d[17]': 'K20 LVCMOS25',
  'sdram_addr[15]': 'AK11 SSTL15',
  'sdram_dq[63]': 'AD4 SSTL15 IN_TERM=UNTUNED_SPLIT_50',
  'sdram_reset_n': 'AK3 LVCMOS15',
};

void main() {
  final board = HarborBoard.get('kc705');

  test('preset part, clock and speed grade', () {
    expect(board.name, 'kc705');
    expect(board.vendor, HarborFpgaVendor.openXc7);
    expect(board.device, 'xc7k325t');
    expect(board.package, 'ffg900');
    expect(board.speedGrade, '2');
    expect(board.oscillatorHz, 200000000);
    expect(board.clockPortName, 'clk');
    expect(board.clockNPortName, 'clk_n');
    expect(board.progCommand, contains('openFPGALoader -b kc705'));
    final t = board.fpgaTarget();
    expect(t.name, 'kintex7-xc7k325t');
    final mk = t.generateMakefile('Top');
    expect(mk, contains('FAMILY = kintex7'));
    expect(mk, contains('PART ?= \$(DEVICE)\$(PACKAGE)-2'));
  });

  test('key sites', () {
    for (final e in _expected.entries) {
      expect(board.pins[e.key], e.value, reason: e.key);
    }
  });

  test('pad counts', () {
    int count(String prefix) =>
        board.pins.keys.where((k) => k.startsWith(prefix)).length;
    expect(count('sdram_dq['), 64);
    expect(count('sdram_dqs['), 8);
    expect(count('sdram_dqs_n['), 8);
    expect(count('sdram_dm['), 8);
    expect(count('sdram_addr['), 16);
    expect(count('sdram_ba['), 3);
    expect(count('pcie_rx'), 16);
    expect(count('pcie_tx'), 16);
    expect(count('led['), 8);
    expect(count('dip['), 4);
    expect(count('eth0_gmii_txd['), 8);
    expect(count('eth0_gmii_rxd['), 8);
    expect(count('hdmi_d['), 18);
  });

  test('every ball is used once', () {
    final byBall = <String, List<String>>{};
    for (final e in board.pins.entries) {
      byBall.putIfAbsent(e.value.split(' ').first, () => []).add(e.key);
    }
    expect(byBall.values.where((v) => v.length > 1), isEmpty);
  });

  test('the reset button is active high and matches the SoC port', () {
    expect(board.pins.containsKey('reset'), isTrue);
    expect(board.pins.containsKey('reset_n'), isFalse);
    expect(board.pins.containsKey('rst_n'), isFalse);
  });

  test('clock capability', () {
    expect(board.siteIsClockCapable(board.pins['clk']!), isTrue);
    expect(board.siteIsClockCapable(board.pins['eth0_gmii_rx_clk']!), isTrue);
    expect(board.siteIsClockCapable(board.pins['uart_tx']!), isFalse);
  });

  test('MGT pads have a package pin and no IOSTANDARD', () {
    final mgt = board.pins.keys
        .where((k) => board.pins[k]!.endsWith(' MGT'))
        .toList();
    expect(mgt, hasLength(2 + 32 + 2 + 4 + 2));
    final xdc = board.fpgaTarget(pins: mgt).generateConstraints();
    for (final port in mgt) {
      final line = xdc
          .split('\n')
          .singleWhere((l) => l.endsWith('[get_ports $port]'));
      expect(line, contains('PACKAGE_PIN'));
      expect(line, isNot(contains('IOSTANDARD')));
      expect(line, isNot(contains('MGT')));
    }
  });

  test('generated XDC', () {
    final xdc = board.fpgaTarget().generateConstraints();
    expect(
      xdc,
      contains(
        'set_property -dict {PACKAGE_PIN AD12 IOSTANDARD DIFF_SSTL15} '
        '[get_ports clk]',
      ),
    );
    expect(
      xdc,
      contains(
        'set_property -dict {PACKAGE_PIN AB7 IOSTANDARD LVCMOS15} '
        '[get_ports reset]',
      ),
    );
    expect(
      xdc,
      contains(
        'set_property -dict {PACKAGE_PIN AD4 IOSTANDARD SSTL15 '
        'IN_TERM UNTUNED_SPLIT_50} [get_ports sdram_dq[63]]',
      ),
    );
    expect(xdc, contains('create_clock -period 5.000 [get_ports clk]'));
    expect(
      xdc,
      contains(
        'set_property -dict {PACKAGE_PIN G25 IOSTANDARD LVCMOS25 '
        'PULLTYPE PULLUP} [get_ports pcie_perst_n]',
      ),
    );
  });

  group('PCIe', () {
    const pcie = [
      'clk',
      'clk_n',
      'pcie_refclk_p',
      'pcie_refclk_n',
      'pcie_perst_n',
      'pcie_rxp[0]',
      'pcie_rxn[0]',
      'pcie_txp[0]',
      'pcie_txn[0]',
    ];
    const fasmLines = [
      'GTX_CHANNEL_3_X219Y254.GTXE2_CHANNEL.GTREFCLK1_USED',
      'GTX_COMMON_X219Y231.GTXE2_COMMON.GTREFCLK0_USED',
      'GTX_COMMON_X219Y231.GTXE2_COMMON.GTREFCLK1_USED',
    ];

    test('lane 0 and the reference clock pins', () {
      expect(board.pins['pcie_rxp[0]'], 'M6 MGT');
      expect(board.pins['pcie_rxn[0]'], 'M5 MGT');
      expect(board.pins['pcie_txp[0]'], 'L4 MGT');
      expect(board.pins['pcie_txn[0]'], 'L3 MGT');
      expect(board.pins['pcie_refclk_p'], 'U8 MGT');
      expect(board.pins['pcie_refclk_n'], 'U7 MGT');
      expect(board.pins['pcie_perst_n'], startsWith('G25 LVCMOS25'));
    });

    test('the board declares the inter-quad reference clock patch', () {
      expect(board.bitstreamPatches, hasLength(1));
      final patch = board.bitstreamPatches.single;
      expect(patch.whenPin, 'pcie_refclk_p');
      expect(patch.fasmLines, fasmLines);
      expect(patch.frames, hasLength(1));
      expect(patch.frames.single.frame, 0x00002C9F);
      expect(patch.frames.single.word, 46);
      expect(patch.frames.single.orMask, 0x00020000);
      expect(patch.frames.single.frameText, '0x00002C9F');
      expect(patch.frames.single.maskText, '0x00020000');
    });

    test('the Makefile appends the FASM lines after nextpnr', () {
      final mk = board.fpgaTarget(pins: pcie).generateMakefile('Top');
      final lines = mk.split('\n');
      final nextpnr = lines.indexWhere((l) => l.contains('nextpnr-xilinx'));
      final frames = lines.indexWhere((l) => l.contains('fasm2frames'));
      final echoes = [
        for (final f in fasmLines) lines.indexOf("\techo '$f' >> \$(TOP).fasm"),
      ];
      for (final i in echoes) {
        expect(i, greaterThan(nextpnr));
        expect(i, lessThan(frames));
      }
      expect(echoes, [...echoes]..sort());
    });

    test('the Makefile sets the frame bit after fasm2frames', () {
      final mk = board.fpgaTarget(pins: pcie).generateMakefile('Top');
      final lines = mk.split('\n');
      final frames = lines.indexWhere((l) => l.contains('fasm2frames'));
      final perl = lines.indexWhere((l) => l.contains('perl -pi -e'));
      final bit = lines.indexWhere((l) => l.contains('xc7frames2bit'));
      expect(perl, frames + 1);
      expect(perl, lessThan(bit));
      expect(lines[perl], contains('0x00002C9F'));
      expect(lines[perl], contains(r'$$w[46]'));
      expect(lines[perl], contains('0x00020000'));
      expect(lines[perl], endsWith(r'$(TOP).frames'));
    });

    test('the frame recipe ORs the mask into the word', () {
      final perl = Process.runSync('perl', ['-v']);
      if (perl.exitCode != 0) {
        markTestSkipped('perl is not installed');
        return;
      }
      final mk = board.fpgaTarget(pins: pcie).generateMakefile('Top');
      final recipe = mk
          .split('\n')
          .firstWhere((l) => l.contains('perl -pi -e'))
          .trim();
      final dir = Directory.systemTemp.createTempSync('kc705_frames');
      addTearDown(() => dir.deleteSync(recursive: true));
      String run(String frames) {
        final file = File('${dir.path}/Top.frames')..writeAsStringSync(frames);
        final shell = recipe
            .replaceAll(r'$$', r'$')
            .replaceAll(r'$(TOP)', '${dir.path}/Top');
        final r = Process.runSync('sh', ['-c', shell]);
        return r.exitCode == 0 ? file.readAsStringSync() : 'failed';
      }

      final words = List.generate(101, (i) => '0x${i.toRadixString(16)}');
      words[46] = '0x00001E00';
      final other = words.join(',');
      final input =
          '0x00000010 $other\n0x00002C9F ${words.join(',')}\n0x00002CA0 $other\n';
      words[46] = '0x00021E00';
      expect(
        run(input),
        '0x00000010 $other\n0x00002C9F ${words.join(',')}\n'
        '0x00002CA0 $other\n',
      );
      expect(run('0x00000010 $other\n'), 'failed');
    });

    test('the patch follows the ports of the design', () {
      final target = board.fpgaTarget();
      expect(target.generateMakefile('Top'), contains('GTXE2'));
      expect(
        target.generateMakefile('Top', knownPorts: {'clk', 'uart_tx'}),
        isNot(contains('GTXE2')),
      );
      expect(
        target.generateMakefile('Top', knownPorts: {'pcie_refclk_p'}),
        allOf(contains('GTXE2'), contains('perl')),
      );
    });

    test('a speed grade suffix keeps the patch', () {
      final b = HarborBoard.get('kc705:3');
      expect(b.bitstreamPatches, hasLength(1));
    });

    test('fpgaTarget takes extra constraints and keeps the patch', () {
      final t = board.fpgaTarget(
        pins: pcie,
        extraConstraints: const {'rate': 'create_clock -period 4 [get_nets x]'},
      );
      expect(t.extraConstraints, hasLength(1));
      expect(t.bitstreamPatches, hasLength(1));
      expect(t.generateMakefile('Top'), contains('GTXE2'));
    });

    test('the Xilinx named constructors take bitstream patches', () {
      const patch = HarborBitstreamPatch(whenPin: 'x', fasmLines: ['A.B.C']);
      final targets = [
        HarborFpgaTarget.spartan7(
          device: 'xc7s50',
          package: 'csga324',
          useOpenXc7: true,
          pinMap: const {'x': 'A1'},
          bitstreamPatches: const [patch],
        ),
        HarborFpgaTarget.artix7(
          device: 'xc7a35t',
          package: 'cpg236',
          useOpenXc7: true,
          pinMap: const {'x': 'A1'},
          bitstreamPatches: const [patch],
        ),
        HarborFpgaTarget.kintex7(
          device: 'xc7k325t',
          package: 'ffg900',
          useOpenXc7: true,
          pinMap: const {'x': 'A1'},
          bitstreamPatches: const [patch],
        ),
      ];
      for (final t in targets) {
        expect(t.bitstreamPatches, hasLength(1), reason: t.name);
        expect(t.generateMakefile('Top'), contains("echo 'A.B.C'"));
      }
    });

    test('a KC705 target with the refclk pin and no patch throws', () {
      final rebuilt = HarborFpgaTarget.kintex7(
        device: 'xc7k325t',
        package: 'ffg900',
        useOpenXc7: true,
        pinMap: const {'pcie_refclk_p': 'U8 MGT'},
      );
      expect(() => rebuilt.generateMakefile('Top'), throwsStateError);
      expect(
        () => rebuilt.generateMakefile('Top', knownPorts: {'clk'}),
        returnsNormally,
      );
      expect(
        () => rebuilt.generateMakefile('Top', knownPorts: {'pcie_refclk_p'}),
        throwsStateError,
      );
    });

    test('a failed patch does not leave a file behind', () {
      final mk = board.fpgaTarget(pins: pcie).generateMakefile('Top');
      expect(mk, contains('\n.DELETE_ON_ERROR:\n'));
      // The recipe of the fasm rule has no break from nextpnr to the patch.
      final lines = mk.split('\n');
      final first = lines.indexWhere(
        (l) => l.startsWith('\t') && l.contains('nextpnr-xilinx'),
      );
      final last = lines.indexWhere((l) => l.contains('GTREFCLK1_USED'));
      expect(lines.indexOf('.DELETE_ON_ERROR:'), lessThan(first));
      for (var i = first; i <= last; i++) {
        expect(lines[i], startsWith('\t'), reason: lines[i]);
      }
      expect(
        board.fpgaTarget(pins: ['clk', 'clk_n']).generateMakefile('Top'),
        contains('\n.DELETE_ON_ERROR:\n'),
      );
    });

    test('FASM lines with shell characters are rejected', () {
      for (final bad in ["A'B", r'A$B', 'A\nB']) {
        final target = HarborFpgaTarget.kintex7(
          device: 'xc7k325t',
          package: 'ffg900',
          useOpenXc7: true,
          pinMap: const {'x': 'A1'},
          bitstreamPatches: [
            HarborBitstreamPatch(whenPin: 'x', fasmLines: [bad]),
          ],
        );
        expect(() => target.generateMakefile('Top'), throwsArgumentError);
      }
    });

    test('there is no patch without the PCIe reference clock', () {
      final mk = board
          .fpgaTarget(pins: ['clk', 'clk_n', 'uart_tx'])
          .generateMakefile('Top');
      expect(mk, isNot(contains('GTXE2')));
      expect(mk, isNot(contains('perl')));
    });

    test('other boards have no patch', () {
      for (final name in HarborBoard.byName.keys.where((n) => n != 'kc705')) {
        final b = HarborBoard.get(name);
        expect(b.bitstreamPatches, isEmpty, reason: name);
        expect(
          b.fpgaTarget(ddrDllOn: true).generateMakefile('Top'),
          isNot(contains('perl')),
        );
      }
    });
  });
}
