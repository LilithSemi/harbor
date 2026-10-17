import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

const _artix = HarborFpgaTarget.artix7(
  device: 'xc7a200t',
  package: 'fbg484',
  speedGrade: '2',
  frequency: 100000000,
);

const _ecp5 = HarborFpgaTarget.ecp5(
  device: 'lfe5u-45f',
  package: 'CABGA381',
  frequency: 25000000,
);

HarborEthernetMac _mac(HarborEthernetConfig c, HarborFpgaTarget t) =>
    HarborEthernetMac(
      baseAddress: 0x40000000,
      config: c,
      fabricKind: HarborFabricKind.wishbone,
      target: t,
      name: 'eth0',
    );

List<String> _lines(HarborEthernetMac m, HarborFpgaTarget t) =>
    m.pinConstraints(t, (p) => 'eth0_$p', 'eth0');

String _cells(List<String> names) =>
    '[get_cells -hierarchical -filter {'
    '${names.map((n) => 'NAME =~ *eth0/*$n').join(' || ')}}]';

String _maxDelay(List<String> from, List<String> to, String ns) =>
    'set_max_delay -datapath_only -from ${_cells(from)} '
    '-to ${_cells(to)} $ns';

String _skew(List<String> from, List<String> to, String ns) =>
    'set_bus_skew -from ${_cells(from)} -to ${_cells(to)} $ns';

const _falsePath =
    'set_false_path -to [get_pins -hierarchical -filter '
    '{NAME =~ *eth0/*_rst_sync_*/PRE || NAME =~ *eth0/*join_reset_sync_*/PRE}]';

void main() {
  test('RGMII full build on Xilinx', () {
    final c = HarborEthernetConfig.full(phy: HarborEthPhy.rgmii);
    final m = _mac(c, _artix)..clockFrequency = 125000000;
    final x = _lines(m, _artix);
    expect(
      x,
      containsAll([
        'create_clock -name eth0_rgmii_rxc -period 8.000 '
            '[get_ports eth0_rgmii_rxc]',
        // Into the RX clock, one period of the 125 MHz clk.
        _maxDelay(['eth_regs/rx_en_r*'], ['rx_en_sync/sync_stage_0*'], '8.000'),
        _maxDelay(
          ['eth_regs/mac_lo*', 'eth_regs/mac_hi*'],
          ['mac_addr_sync/sync_stage_0*'],
          '8.000',
        ),
        _maxDelay(
          ['eth_regs/hash_lo*', 'eth_regs/hash_hi*'],
          ['mc_hash_sync/sync_stage_0*'],
          '8.000',
        ),
        _maxDelay(
          ['eth_regs/ctrl_promisc*'],
          ['promisc_sync/sync_stage_0*'],
          '8.000',
        ),
        _maxDelay(
          ['eth_regs/ctrl_speed*'],
          ['tx_speed_sync/sync_stage_0*', 'rx_speed_sync/sync_stage_0*'],
          '8.000',
        ),
        _maxDelay(
          ['eth_tx_frame_fifo/w_frames_gray*'],
          ['eth_tx_frame_fifo/frames_s0*'],
          '8.000',
        ),
        _skew(
          ['eth_rx_frame_fifo/r_ptr_gray*'],
          ['eth_rx_frame_fifo/r_gray_s0*'],
          '8.000',
        ),
        // Out of the PHY clocks.
        _maxDelay(
          ['eth_tx_frame_fifo/f_ptr_gray*'],
          ['eth_tx_frame_fifo/f_gray_s0*'],
          '8.000',
        ),
        _skew(
          ['eth_rx_frame_fifo/w_frames_gray*'],
          ['eth_rx_frame_fifo/frames_s0*'],
          '8.000',
        ),
        _maxDelay(
          ['eth_rx_frame_fifo/ovf_tog*'],
          ['eth_rx_frame_fifo/ovf_s0*'],
          '8.000',
        ),
        for (final f in ['eth_tx_frame_fifo', 'eth_rx_frame_fifo'])
          _maxDelay(['$f/phy_div*'], ['$f/phy_tog_s0*'], '8.000'),
        for (final n in [
          'tx_frame',
          'rx_good',
          'rx_fcs',
          'rx_runt',
          'rx_oversize',
        ])
          _maxDelay(['${n}_tog*'], ['${n}_sync/sync_stage_0*'], '8.000'),
        for (final n in ['tx_phy_busy', 'rx_phy_busy'])
          _maxDelay(['$n*'], ['${n}_sync/sync_stage_0*'], '8.000'),
        _falsePath,
      ]),
    );
    expect(x.where((l) => l.startsWith('set_max_delay')), hasLength(19));
    expect(x.where((l) => l.startsWith('set_bus_skew')), hasLength(4));
  });

  test('the sys period comes from the target without a clock rate', () {
    final c = HarborEthernetConfig.basic(phy: HarborEthPhy.mii);
    final x = _lines(_mac(c, _artix), _artix);
    // 100 MHz clk into the 25 MHz MII clocks, and 40 ns back.
    expect(
      x,
      containsAll([
        _maxDelay(
          ['eth_regs/rx_en_r*'],
          ['rx_en_sync/sync_stage_0*'],
          '10.000',
        ),
        _skew(
          ['eth_tx_frame_fifo/w_frames_gray*'],
          ['eth_tx_frame_fifo/frames_s0*'],
          '10.000',
        ),
        _maxDelay(
          ['eth_tx_frame_fifo/f_ptr_gray*'],
          ['eth_tx_frame_fifo/f_gray_s0*'],
          '40.000',
        ),
      ]),
    );
  });

  test('MII basic build on Xilinx', () {
    final c = HarborEthernetConfig.basic(phy: HarborEthPhy.mii);
    final x = _lines(_mac(c, _artix)..clockFrequency = 50000000, _artix);
    expect(
      x,
      containsAll([
        'create_clock -name eth0_mii_tx_clk -period 40.000 '
            '[get_ports eth0_mii_tx_clk]',
        'create_clock -name eth0_mii_rx_clk -period 40.000 '
            '[get_ports eth0_mii_rx_clk]',
        'set_output_delay -clock eth0_mii_tx_clk -max 15.000 '
            '[get_ports {eth0_mii_txd[*] eth0_mii_tx_en eth0_mii_tx_er}]',
        'set_output_delay -clock eth0_mii_tx_clk -min 0.000 '
            '[get_ports {eth0_mii_txd[*] eth0_mii_tx_en eth0_mii_tx_er}]',
        'set_input_delay -clock eth0_mii_rx_clk -max 30.000 '
            '[get_ports {eth0_mii_rxd[*] eth0_mii_rx_dv eth0_mii_rx_er}]',
        'set_input_delay -clock eth0_mii_rx_clk -min 10.000 '
            '[get_ports {eth0_mii_rxd[*] eth0_mii_rx_dv eth0_mii_rx_er}]',
        _maxDelay(
          ['eth_regs/rx_en_r*'],
          ['rx_en_sync/sync_stage_0*'],
          '20.000',
        ),
        _maxDelay(
          ['eth_rx_frame_fifo/w_frames_gray*'],
          ['eth_rx_frame_fifo/frames_s0*'],
          '40.000',
        ),
        _skew(
          ['eth_rx_frame_fifo/w_frames_gray*'],
          ['eth_rx_frame_fifo/frames_s0*'],
          '20.000',
        ),
        _maxDelay(['rx_good_tog*'], ['rx_good_sync/sync_stage_0*'], '40.000'),
        _falsePath,
      ]),
    );
    // No hash, no promiscuous mode and no speed synchronizer.
    for (final n in ['mc_hash', 'promisc', 'speed']) {
      expect(x.where((l) => l.contains('${n}_sync')), isEmpty, reason: n);
    }
    expect(x.where((l) => l.startsWith('set_max_delay')), hasLength(16));
    expect(x.where((l) => l.startsWith('set_bus_skew')), hasLength(4));
  });

  test('MII and RMII on ECP5 give LPF clock periods only', () {
    final mii = HarborEthernetConfig.basic(phy: HarborEthPhy.mii);
    expect(_lines(_mac(mii, _ecp5), _ecp5), [
      'FREQUENCY PORT "eth0_mii_tx_clk" 25.000 MHz;',
      'FREQUENCY PORT "eth0_mii_rx_clk" 25.000 MHz;',
    ]);
    final rmii = HarborEthernetConfig.basic(phy: HarborEthPhy.rmii);
    expect(_lines(_mac(rmii, _ecp5), _ecp5), [
      'FREQUENCY PORT "eth0_rmii_ref_clk" 50.000 MHz;',
    ]);
  });

  test('RMII pins on Xilinx', () {
    final c = HarborEthernetConfig.basic(phy: HarborEthPhy.rmii);
    final x = _lines(_mac(c, _artix), _artix);
    expect(
      x,
      containsAll([
        'create_clock -name eth0_rmii_ref_clk -period 20.000 '
            '[get_ports eth0_rmii_ref_clk]',
        'set_input_delay -clock eth0_rmii_ref_clk -max 14.000 '
            '[get_ports {eth0_rmii_rxd[*] eth0_rmii_crs_dv eth0_rmii_rx_er}]',
        'set_input_delay -clock eth0_rmii_ref_clk -min 2.000 '
            '[get_ports {eth0_rmii_rxd[*] eth0_rmii_crs_dv eth0_rmii_rx_er}]',
        'set_output_delay -clock eth0_rmii_ref_clk -max 4.000 '
            '[get_ports {eth0_rmii_txd[*] eth0_rmii_tx_en}]',
        'set_output_delay -clock eth0_rmii_ref_clk -min -2.000 '
            '[get_ports {eth0_rmii_txd[*] eth0_rmii_tx_en}]',
        _maxDelay(
          ['eth_regs/ctrl_speed*'],
          ['eth_phy_rmii/speed_sync/sync_stage_0*'],
          '10.000',
        ),
      ]),
    );
  });

  test('pin lines need every PHY pin on the top level', () {
    final c = HarborEthernetConfig.basic(phy: HarborEthPhy.mii);
    final x = _mac(c, _artix).pinConstraints(
      _artix,
      (p) => p == 'mii_tx_clk' ? 'eth0_$p' : null,
      'eth0',
    );
    expect(x.where((l) => l.contains('get_ports')), isEmpty);
    expect(x.where((l) => l.startsWith('set_max_delay')), isNotEmpty);
  });

  test('the device tree has clock-frequency when the rate is known', () {
    final c = HarborEthernetConfig.basic(phy: HarborEthPhy.mii);
    final m = _mac(c, _artix);
    expect(m.dtNode.properties, isNot(contains('clock-frequency')));
    m.provideInputClockHz(50000000);
    m.provideInputClockHz(1);
    expect(m.dtNode.properties['clock-frequency'], 50000000);
  });
}
