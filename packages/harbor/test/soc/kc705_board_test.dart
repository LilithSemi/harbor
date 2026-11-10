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
  'sdram_ck[1]': 'AE11 DIFF_SSTL15',
  'sdram_ck_n[1]': 'AF11 DIFF_SSTL15',
  'sdram_cke[1]': 'AE10 SSTL15',
  'sdram_cs_n[1]': 'AE8 SSTL15',
  'sdram_odt[1]': 'AC10 SSTL15',
  'sfp_refclk_p': 'G8 MGT',
  'sfp_tx_disable': 'Y20 LVCMOS25',
  'hdmi_clk': 'K18 LVCMOS25',
  'hdmi_d[17]': 'K20 LVCMOS25',
  'sdram_ck': 'AG10 DIFF_SSTL15',
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
}
