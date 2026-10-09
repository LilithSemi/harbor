import 'package:harbor/harbor.dart';
import 'package:harbor/src/clock/wishbone_cdc_fifo.dart';
import 'package:test/test.dart';

const _ecp5 = HarborFpgaTarget.ecp5(device: 'lfe5u-25f', package: 'CABGA381');

HarborWishboneCdcFifoBridge _bridge({
  int addressWidth = 64,
  int dataWidth = 64,
  int depth = 16,
  int respDepth = 2,
  bool blockRam = false,
  bool postedWrites = false,
}) => HarborWishboneCdcFifoBridge(
  addressWidth: addressWidth,
  dataWidth: dataWidth,
  depth: depth,
  respDepth: respDepth,
  target: _ecp5,
  blockRam: blockRam,
  postedWrites: postedWrites,
);

void main() {
  group('HarborWishboneCdcFifoBridge parameters', () {
    test('bad depths throw an ArgumentError that names the field', () {
      for (final (depth, resp, field) in [
        (12, 2, 'depth'),
        (1, 2, 'depth'),
        (16, 1, 'respDepth'),
        (16, 3, 'respDepth'),
      ]) {
        expect(
          () => _bridge(depth: depth, respDepth: resp),
          throwsA(isA<ArgumentError>().having((e) => e.name, 'name', field)),
        );
      }
    });

    test('the Arty S7 DDR3 configuration keeps the short names', () {
      expect(_bridge().definitionName, 'HarborWishboneCdcFifoBridge');
      expect(
        _bridge(postedWrites: true).definitionName,
        'HarborWishboneCdcFifoBridgePosted',
      );
    });

    test('every structural parameter changes the definition name', () {
      final names = {
        _bridge().definitionName,
        _bridge(addressWidth: 32).definitionName,
        _bridge(dataWidth: 32).definitionName,
        _bridge(depth: 8).definitionName,
        _bridge(respDepth: 4).definitionName,
        _bridge(blockRam: true).definitionName,
        _bridge(postedWrites: true).definitionName,
      };
      expect(names, hasLength(7));
    });

    test('only the request FIFO follows blockRam', () {
      final b = _bridge(blockRam: true);
      final fifos = b.subModules.whereType<HarborCdcFifo>().toList();
      final req = fifos.singleWhere((f) => f.name == 'req_fifo');
      final resp = fifos.singleWhere((f) => f.name == 'resp_fifo');
      expect(req.usesBlockRam, isTrue);
      expect(resp.usesBlockRam, isFalse);
    });
  });
}
