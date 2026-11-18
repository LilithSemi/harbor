// The SDIO ADMA on a SoC channel that reaches only an SRAM. An access to an
// address no slave decodes ends the transfer with the ADMA error and no
// data-done, on every fabric kind.

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../peripherals/sdio_adma_bench.dart';

const _unmapped = 0x80000000;

void main() {
  tearDown(() async => Simulator.reset());

  for (final kind in HarborFabricKind.values) {
    test('${kind.name}: a card read into an unmapped address', () async {
      final b = AdmaBench(kind, 32, onFabric: true, dmaOutstanding: 1);
      await b.start();
      await b.wr(admaBlkSize, 32);
      await b.wr(admaAdmaAddr, _unmapped);
      await b.wr(admaCmd, admaCmdRead);
      await b.cardReadBlocks([
        [for (var i = 0; i < 8; i++) i],
      ], cycles: 4000);
      expect(
        await b.rd(admaIntStatus) & (admaDataDone | admaAdmaErr),
        admaAdmaErr,
      );
      expect(b.irq.value.toInt(), 1, reason: 'error interrupt');
      expect(await b.rd(admaAdmaErrStatus), 3);
      expect(await b.rd(admaAdmaErrAddr), _unmapped);
      expect((await b.rd(admaStatus) >> 8) & 1, 0, reason: 'still busy');
      await Simulator.endSimulation();
    });

    test('${kind.name}: a card write from an unmapped address', () async {
      final b = AdmaBench(kind, 32, onFabric: true, dmaOutstanding: 1);
      await b.start();
      await b.wr(admaBlkSize, 8);
      await b.wr(admaAdmaAddr, _unmapped);
      await b.wr(admaCmd, admaCmdWrite);
      await b.cardWrite(throughBlock: true);
      expect(
        await b.rd(admaIntStatus) & (admaDataDone | admaAdmaErr),
        admaAdmaErr,
      );
      expect(await b.rd(admaAdmaErrStatus), 3);
      expect(await b.rd(admaAdmaErrAddr), _unmapped);
      expect((await b.rd(admaStatus) >> 8) & 1, 0, reason: 'still busy');
      await Simulator.endSimulation();
    });
  }
}
