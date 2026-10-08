import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  group('WishboneToTileLinkBridge', () {
    test('creates without error', () {
      final wbConfig = WishboneConfig(addressWidth: 32, dataWidth: 32);
      final tlConfig = TileLinkConfig(addressWidth: 32, dataWidth: 32);
      final wb = WishboneInterface(wbConfig);
      final tl = TileLinkInterface(tlConfig);
      final bridge = WishboneToTileLinkBridge(
        wb,
        tl,
        clk: Logic(name: 'clk'),
        reset: Logic(name: 'reset'),
      );
      expect(bridge, isNotNull);
    });
  });

  group('TileLinkToWishboneBridge', () {
    test('creates without error', () {
      final wbConfig = WishboneConfig(addressWidth: 32, dataWidth: 32);
      final tlConfig = TileLinkConfig(addressWidth: 32, dataWidth: 32);
      final tl = TileLinkInterface(tlConfig);
      final wb = WishboneInterface(wbConfig);
      final bridge = TileLinkToWishboneBridge(
        tl,
        wb,
        clk: Logic(name: 'clk'),
        reset: Logic(name: 'reset'),
      );
      expect(bridge, isNotNull);
    });
  });

  group('WishboneDecoder', () {
    test('creates with config and mappings, hit output width is 1', () {
      final config = WishboneConfig(addressWidth: 32, dataWidth: 32);
      final mapping0 = HarborAddressMapping(
        range: BusAddressRange(0x0000, 0x1000),
        slaveIndex: 0,
      );
      final decoder = WishboneDecoder(config, [mapping0]);
      expect(decoder, isNotNull);
    });
  });

  group('WishboneArbiter', () {
    test('creates with single master, grant output exists', () {
      final config = WishboneConfig(addressWidth: 32, dataWidth: 32);
      final arbiter = WishboneArbiter(numMasters: 1, config: config);
      expect(arbiter.grant.width, equals(1));
    });
  });

  group('TileLinkDecoder', () {
    test('creates with config and mappings, hit output width is 1', () {
      final config = TileLinkConfig(addressWidth: 32, dataWidth: 32);
      final master = TileLinkInterface(config);
      final slave0 = TileLinkInterface(config);
      final mapping0 = HarborAddressMapping(
        range: BusAddressRange(0x0000, 0x1000),
        slaveIndex: 0,
      );
      final decoder = TileLinkDecoder(master, [(slave0, mapping0)]);
      expect(decoder.hit.width, equals(1));
    });
  });

  group('TileLinkArbiter', () {
    test('creates with single master, grant output exists', () {
      final config = TileLinkConfig(addressWidth: 32, dataWidth: 32);
      final master0 = TileLinkInterface(config);
      final slave = TileLinkInterface(config);
      final clk = Logic(name: 'clk');
      final reset = Logic(name: 'reset');
      final arbiter = TileLinkArbiter([master0], slave, clk: clk, reset: reset);
      expect(arbiter.grant.width, equals(1));
    });
  });
}
