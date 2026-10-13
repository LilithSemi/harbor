import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

List<String> _names(PairInterface i, PairDirection d) => [
  for (final p in i.getPorts([d]).values) p.name,
];

void main() {
  group('HarborRegisterWaist', () {
    test('requester and device sides', () {
      final w = HarborRegisterWaist(addressWidth: 12, dataWidth: 64);
      expect(_names(w, PairDirection.fromProvider), [
        'ADDR',
        'WDATA',
        'STB',
        'WE',
        'SEL',
      ]);
      expect(_names(w, PairDirection.fromConsumer), ['RDATA', 'ACK', 'ERR']);
      expect(w.sel.width, 8);
      expect(w.clone().addr.width, 12);
    });

    test('rejects a bad data width', () {
      expect(
        () => HarborRegisterWaist(addressWidth: 8, dataWidth: 24),
        throwsArgumentError,
      );
    });
  });

  group('HarborMemoryWaist', () {
    test('channels and widths', () {
      final w = HarborMemoryWaist(
        const HarborMemoryWaistConfig(
          addressWidth: 32,
          dataWidth: 128,
          idWidth: 4,
          outstanding: 8,
        ),
      );
      expect(_names(w, PairDirection.fromProvider), [
        'REQ_VALID',
        'REQ_ID',
        'REQ_WRITE',
        'REQ_ADDR',
        'REQ_LEN',
        'REQ_SIZE',
        'REQ_BURST',
        'WDATA_VALID',
        'WDATA_DATA',
        'WDATA_STRB',
        'WDATA_LAST',
        'RDATA_READY',
        'WRESP_READY',
      ]);
      expect(_names(w, PairDirection.fromConsumer), [
        'REQ_READY',
        'WDATA_READY',
        'RDATA_VALID',
        'RDATA_ID',
        'RDATA_DATA',
        'RDATA_ERR',
        'RDATA_LAST',
        'WRESP_VALID',
        'WRESP_ID',
        'WRESP_ERR',
      ]);
      expect(w.reqLen.width, 8);
      expect(w.wdataStrb.width, 16);
      expect(w.rdataId.width, 4);
      expect(w.clone().config.outstanding, 8);
    });

    test('burst encodings match AXI4', () {
      expect([for (final b in HarborMemoryBurst.values) b.value], [0, 1, 2]);
    });

    test('rejects bad parameters', () {
      for (final c in [
        const HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 48),
        const HarborMemoryWaistConfig(
          addressWidth: 32,
          dataWidth: 32,
          idWidth: 0,
        ),
        const HarborMemoryWaistConfig(
          addressWidth: 32,
          dataWidth: 32,
          outstanding: 0,
        ),
      ]) {
        expect(() => HarborMemoryWaist(c), throwsArgumentError);
      }
    });
  });

  test('Axi4LiteInterface carries only the Lite signals', () {
    final i = Axi4LiteInterface(addressWidth: 16, dataWidth: 32);
    expect(i.getPorts().length, 19);
    expect(i.wStrb.width, 4);
  });
}
