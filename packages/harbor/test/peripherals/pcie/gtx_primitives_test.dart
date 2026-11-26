import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../support/gtxe2_primitive_names.dart';

/// Parameters of GTXE2_CHANNEL in the Yosys Xilinx cell library and its
/// number of input ports.
const _primitiveParameters = 207;
const _primitiveInputs = 166;

/// The values of the build list for x1, 100 MHz refclk, CPLL.
const _buildValues = {
  'CPLL_REFCLK_DIV': '1',
  'CPLL_FBDIV_45': '5',
  'CPLL_FBDIV': '5',
  'CPLL_CFG': "24'hA407CC",
  'TXOUT_DIV': '2',
  'RXOUT_DIV': '2',
  'TX_CLK25_DIV': '4',
  'RX_CLK25_DIV': '4',
  'TX_XCLK_SEL': '"TXUSR"',
  'TXBUF_EN': '"FALSE"',
  'PCS_RSVD_ATTR': "48'h1CF",
  'RXCDR_CFG': "72'h03000023FF10200020",
  'CLK_COR_MIN_LAT': '13',
  'CLK_COR_MAX_LAT': '15',
  'PMA_RSV': "32'h18480",
  'PMA_RSV2': "16'h2050",
  'RX_CM_SEL': "2'h3",
  'RX_CM_TRIM': "3'h2",
  'PCS_PCIE_EN': '"TRUE"',
  'TX_DRIVE_MODE': '"PIPE"',
  'RX_DATA_WIDTH': '20',
  'TX_DATA_WIDTH': '20',
};

void main() {
  tearDown(() async => Simulator.reset());

  group('GTXE2 attribute table', () {
    test('has every parameter of the primitive', () {
      expect(gtxe2ChannelPcieAttributes, hasLength(_primitiveParameters));
      expect(gtxe2ChannelPcieParameters, hasLength(_primitiveParameters));
    });

    test('each value has a source', () {
      for (final e in gtxe2ChannelPcieAttributes.entries) {
        expect(e.value.value, isNotEmpty, reason: e.key);
        expect(e.value.source, isNotEmpty, reason: e.key);
        expect(
          e.value.source,
          anyOf(
            startsWith('UG476'),
            startsWith('PG054'),
            startsWith('KC705'),
            startsWith('openXC7'),
          ),
          reason: e.key,
        );
      }
    });

    test('the names are the names of the primitive', () {
      expect(
        gtxe2ChannelPcieAttributes.keys.toSet(),
        gtxe2ChannelParameterNames,
      );
      final consumers = HarborGtxChannelPorts()
          .getPorts({PairDirection.fromConsumer})
          .keys
          .toSet();
      final providers = HarborGtxChannelPorts()
          .getPorts({PairDirection.fromProvider})
          .keys
          .toSet();
      expect({
        ...gtxe2ChannelPcieTieOffs.keys,
        ...consumers,
        'GTREFCLK0',
        'GTXRXP',
        'GTXRXN',
      }, gtxe2ChannelInputNames);
      expect(gtxe2ChannelOutputNames.containsAll(providers), isTrue);
    });

    test('TXPHDLY_CFG is 0 as on the working KC705 build', () {
      expect(gtxe2ChannelPcieParameters['TXPHDLY_CFG'], "24'h0");
      expect(gtxe2ChannelPcieParameters['RXDFELPMRESET_TIME'], "7'h11");
    });

    test('PCS_RSVD_ATTR and DMONITOR_CFG name the hardware source', () {
      for (final n in ['PCS_RSVD_ATTR', 'DMONITOR_CFG']) {
        expect(
          gtxe2ChannelPcieAttributes[n]!.source,
          'KC705 hardware-proven value (Glacier probe)',
        );
      }
    });

    test('the build list values', () {
      for (final e in _buildValues.entries) {
        expect(gtxe2ChannelPcieParameters[e.key], e.value, reason: e.key);
      }
    });

    test('the CPLL gives 2.5 GHz and the line rates', () {
      int p(String k) => int.parse(gtxe2ChannelPcieParameters[k]!);
      const refMhz = 100;
      final vco =
          refMhz * p('CPLL_FBDIV') * p('CPLL_FBDIV_45') ~/ p('CPLL_REFCLK_DIV');
      expect(vco, 2500);
      // The line rate in Mb/s is 2 x VCO / D.
      expect(2 * vco ~/ p('TXOUT_DIV'), 2500);
      expect(2 * vco ~/ 1, 5000);
      expect(refMhz ~/ p('TX_CLK25_DIV'), 25);
    });

    test('literals are well formed', () {
      final sized = RegExp(r"^\d+'h[0-9A-F]+$");
      final string = RegExp(r'^"[A-Z0-9_.]+"$');
      for (final e in gtxe2ChannelPcieParameters.entries) {
        expect(
          sized.hasMatch(e.value) ||
              string.hasMatch(e.value) ||
              int.tryParse(e.value) != null,
          isTrue,
          reason: '${e.key} ${e.value}',
        );
      }
    });

    test('tie-offs, PHY ports and special pins cover the inputs', () {
      final ports = HarborGtxChannelPorts();
      final consumers = ports
          .getPorts({PairDirection.fromConsumer})
          .keys
          .toSet();
      for (final name in consumers) {
        expect(gtxe2ChannelPcieTieOffs.containsKey(name), isFalse);
      }
      expect(
        gtxe2ChannelPcieTieOffs.length + consumers.length + 3,
        _primitiveInputs,
        reason: 'the three are GTREFCLK0, GTXRXP and GTXRXN',
      );
      for (final special in ['GTREFCLK0', 'GTXRXP', 'GTXRXN']) {
        expect(gtxe2ChannelPcieTieOffs.containsKey(special), isFalse);
      }
      expect(gtxe2ChannelPcieTieOffs['CPLLREFCLKSEL'], (3, 1));
      expect(gtxe2ChannelPcieTieOffs['TXOUTCLKSEL'], (3, 3));
      expect(gtxe2ChannelPcieTieOffs['TXPHALIGNEN'], (1, 1));
      expect(gtxe2ChannelPcieTieOffs['TXDLYBYPASS'], (1, 0));
      expect(gtxe2ChannelPcieTieOffs['RXDLYBYPASS'], (1, 1));
      expect(gtxe2ChannelPcieTieOffs['CPLLLOCKEN'], (1, 1));
    });
  });

  group('GTXE2 primitives', () {
    test('the channel wrapper has the primitive ports', () async {
      final channel = HarborXilinxGtxe2Channel(
        rxP: Logic(),
        rxN: Logic(),
        refClk: Logic(),
        ports: HarborGtxChannelPorts(),
      );
      await channel.build();
      expect(channel.definitionName, 'GTXE2_CHANNEL');
      for (final e in gtxe2ChannelPcieTieOffs.entries) {
        expect(channel.inputs.containsKey(e.key), isTrue, reason: e.key);
        expect(channel.input(e.key).width, e.value.$1, reason: e.key);
      }
      expect(channel.inputs, hasLength(_primitiveInputs));
      expect(channel.input('TXDATA').width, 64);
      expect(channel.input('CLKRSVD').width, 4);
      expect(channel.output('RXDATA').width, 64);
      expect(channel.output('GTXTXP').width, 1);
    });
  });

  group('HarborKintex7PciePhy', () {
    for (final gen2 in [true, false]) {
      test('gen2 $gen2: the PIPE seam and the primitives elaborate', () async {
        final pipe = HarborPciePipeLane();
        final phy = HarborKintex7PciePhy(
          refClkP: Logic(),
          refClkN: Logic(),
          perstN: Logic(),
          hardLinkUp: Logic(),
          phyLinkUpN: Logic(),
          ltssmState: Logic(width: 6),
          rxP: Logic(),
          rxN: Logic(),
          pipe: pipe,
          gen2: gen2,
        );
        await phy.build();
        final sv = phy.dumpSystemVerilog();
        int count(String cell) => RegExp('\\b$cell\\b').allMatches(sv).length;
        expect(count('GTXE2_CHANNEL'), 1);
        expect(count('IBUFDS_GTE2'), 1);
        expect(count('MMCME2_ADV'), 1);
        expect(count('BUFGCTRL'), gen2 ? 1 : 0);
        expect(count('GTXE2_COMMON'), 0);
        for (final e in gtxe2ChannelPcieParameters.entries) {
          expect(sv, contains('.${e.key}(${e.value})'), reason: e.key);
        }
        expect(sv, contains(".CPLLREFCLKSEL(3'h1)"));
        expect(sv, contains(".TXOUTCLKSEL(3'h3)"));
        expect(phy.definitionName, contains('Kintex7'));
        expect(phy.output('rxdata').width, 16);
        expect(phy.input('txdata').width, 16);
        expect(phy.input('rate').width, 1);
        expect(phy.output('phystatus').width, 1);
        for (final (name, width) in [
          ('reset_state', 4),
          ('reset_fail_state', 4),
          ('reset_retries', 8),
          ('link_retrains', 8),
          ('cpll_lock', 1),
          ('rx_cdr_lock', 1),
          ('tx_reset_done', 1),
          ('rx_reset_done', 1),
          ('timeout_flags', 5),
          ('pclk_sel', 1),
          ('mmcm_lock', 1),
          ('ready', 1),
        ]) {
          expect(phy.output(name).width, width, reason: name);
        }
      });
    }

    test('without the watchdog there is no link_retrains', () async {
      final phy = HarborKintex7PciePhy(
        refClkP: Logic(),
        refClkN: Logic(),
        perstN: Logic(),
        rxP: Logic(),
        rxN: Logic(),
        pipe: HarborPciePipeLane(),
        timeouts: const HarborGtxPcieTimeouts(linkWait: 0),
      );
      await phy.build();
      expect(phy.linkRetrains, isNull);
      expect(phy.outputs.containsKey('link_retrains'), isFalse);
    });
  });
}
