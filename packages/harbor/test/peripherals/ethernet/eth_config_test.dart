import 'package:harbor/src/peripherals/ethernet/eth_config.dart';
import 'package:test/test.dart';

void main() {
  group('hwCaps', () {
    test('basic', () {
      // log2 16 = 4, log2 2048 = 11.
      const fifo = (4 << 12) | (11 << 16) | (11 << 24);
      expect(
        HarborEthernetConfig.basic(phy: HarborEthPhy.mii).hwCaps,
        equals(fifo | 0x1),
      );
      expect(
        HarborEthernetConfig.basic(phy: HarborEthPhy.rmii).hwCaps,
        equals(fifo | 0x2),
      );
      expect(
        HarborEthernetConfig.basic(phy: HarborEthPhy.rgmii).hwCaps,
        equals(fifo | 0x4),
      );
    });

    test('full', () {
      // log2 4096 = 12.
      const fifo = (4 << 12) | (12 << 16) | (12 << 24);
      const filters = (1 << 4) | (1 << 5);
      expect(
        HarborEthernetConfig.full(phy: HarborEthPhy.mii).hwCaps,
        equals(fifo | filters | 0x1),
      );
      expect(
        HarborEthernetConfig.full(phy: HarborEthPhy.rmii).hwCaps,
        equals(fifo | filters | 0x2),
      );
      expect(
        HarborEthernetConfig.full(phy: HarborEthPhy.rgmii).hwCaps,
        equals(fifo | filters | 0x4 | (1 << 3)),
      );
    });

    test('mdioC45 bit, pause, checksum and PTP read 0', () {
      final c = HarborEthernetConfig(phy: HarborEthPhy.mii, mdioC45: true);
      expect(c.descBytes, equals(16));
      expect(
        c.hwCaps,
        equals(0x1 | (1 << 9) | (4 << 12) | (11 << 16) | (11 << 24)),
      );
      expect(c.hwCaps & (0x7 << 6), 0);
    });
  });

  group('presets', () {
    test('basic', () {
      final c = HarborEthernetConfig.basic(phy: HarborEthPhy.rgmii);
      expect(c.maxSpeed, HarborEthSpeed.mbps100);
      expect(c.multicastHash, isFalse);
      expect(c.promiscuous, isFalse);
      expect([
        c.txFifoBytes,
        c.rxFifoBytes,
        c.outstanding,
        c.burstBeats,
      ], equals([2048, 2048, 1, 4]));
    });

    test('full', () {
      final c = HarborEthernetConfig.full(phy: HarborEthPhy.rmii);
      expect(c.maxSpeed, HarborEthSpeed.mbps100);
      expect(c.pause || c.checksumOffload || c.ptp, isFalse);
      expect([
        c.txFifoBytes,
        c.rxFifoBytes,
        c.outstanding,
        c.burstBeats,
      ], equals([4096, 4096, 4, 16]));
    });
  });

  group('validation', () {
    test('gigabit needs rgmii', () {
      expect(
        () => HarborEthernetConfig(
          phy: HarborEthPhy.mii,
          maxSpeed: HarborEthSpeed.mbps1000,
        ),
        throwsArgumentError,
      );
    });

    test('FIFO size', () {
      for (final bytes in [1000, 1024, 3000]) {
        expect(
          () => HarborEthernetConfig(phy: HarborEthPhy.mii, txFifoBytes: bytes),
          throwsArgumentError,
        );
        expect(
          () => HarborEthernetConfig(phy: HarborEthPhy.mii, rxFifoBytes: bytes),
          throwsArgumentError,
        );
      }
    });

    test('options that are not built', () {
      Matcher notBuilt(String name) => throwsA(
        isA<ArgumentError>()
            .having((e) => e.name, 'name', name)
            .having((e) => e.message, 'message', contains('not built yet')),
      );
      expect(
        () => HarborEthernetConfig(phy: HarborEthPhy.mii, pause: true),
        notBuilt('pause'),
      );
      expect(
        () =>
            HarborEthernetConfig(phy: HarborEthPhy.mii, checksumOffload: true),
        notBuilt('checksumOffload'),
      );
      expect(
        () => HarborEthernetConfig(phy: HarborEthPhy.mii, ptp: true),
        notBuilt('ptp'),
      );
    });

    test('outstanding', () {
      expect(
        () => HarborEthernetConfig(phy: HarborEthPhy.mii, outstanding: 0),
        throwsArgumentError,
      );
    });

    test('burstBeats', () {
      for (final beats in [0, 257]) {
        expect(
          () => HarborEthernetConfig(phy: HarborEthPhy.mii, burstBeats: beats),
          throwsArgumentError,
        );
      }
      expect(
        HarborEthernetConfig(phy: HarborEthPhy.mii, burstBeats: 256).burstBeats,
        256,
      );
    });
  });
}
