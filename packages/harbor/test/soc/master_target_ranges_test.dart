// buildFabric checks the target ranges of a master against the slaves of its
// channel, and a burst master against slaves that cannot take bursts.

import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

import '../peripherals/sdio_adma_bench.dart';

const _kind = HarborFabricKind.wishbone;

HarborSoC _soc({
  List<BusAddressRange>? targets,
  Map<String, Set<String>>? channels,
  String channel = 'dma',
}) {
  final soc = HarborSoC(
    name: 'targets',
    compatible: 'test,targets',
    fabricKind: _kind,
    target: const HarborSimTarget(frequency: 50000000),
  );
  final cpu = soc.addMaster(AdmaCpu(_kind));
  final dma = HarborDmaController(
    baseAddress: 0x30000000,
    channels: 1,
    busAddressWidth: 32,
    fabricKind: _kind,
  );
  soc.addPeripheral(dma);
  soc.addMaster(
    dma,
    busInterfaceName: 'dma',
    memory: true,
    outstanding: 1,
    channel: channel,
    targetRanges: targets,
  );
  for (final (name, base) in [('sram_a', 0x08000000), ('sram_b', 0x08001000)]) {
    soc.addPeripheral(
      HarborSram(
        name: name,
        baseAddress: base,
        size: 0x1000,
        busAddressWidth: 32,
        protocol: _kind,
      ),
    );
  }
  cpu.pullUp(soc);
  soc.buildFabric(channelSlaves: channels);
  return soc;
}

const _channels = {
  'primary': {'dma', 'sram_a', 'sram_b'},
  'dma': {'sram_a'},
};

void main() {
  test('a SoC with no slave rejects any target range', () {
    final soc = HarborSoC(
      name: 'targets_none',
      compatible: 'test,targets',
      fabricKind: _kind,
      target: const HarborSimTarget(frequency: 50000000),
    );
    final dma = HarborDmaController(
      baseAddress: 0x30000000,
      channels: 1,
      busAddressWidth: 32,
      fabricKind: _kind,
    );
    soc.addMaster(
      dma,
      busInterfaceName: 'dma',
      memory: true,
      outstanding: 1,
      targetRanges: [const BusAddressRange(0x08000000, 0x1000)],
    );
    expect(
      soc.buildFabric,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('not covered'),
        ),
      ),
    );
  });

  test('a master without target ranges is not checked', () {
    expect(() => _soc(channels: _channels), returnsNormally);
  });

  test('a range inside one slave passes', () {
    expect(
      () => _soc(
        targets: [const BusAddressRange(0x08000000, 0x1000)],
        channels: _channels,
      ),
      returnsNormally,
    );
  });

  test('a range that no slave covers throws', () {
    expect(
      () => _soc(
        targets: [const BusAddressRange(0x80000000, 0x1000)],
        channels: _channels,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('target range'),
            contains('0x80000000'),
            contains('dma_dma'),
          ),
        ),
      ),
    );
  });

  test('a range that a slave of another channel covers throws', () {
    expect(
      () => _soc(
        targets: [const BusAddressRange(0x08001000, 0x1000)],
        channels: _channels,
      ),
      throwsStateError,
    );
  });

  test('a range that two adjacent slaves cover passes', () {
    expect(
      () => _soc(
        targets: [const BusAddressRange(0x08000800, 0x1000)],
        channels: {
          'primary': {'dma', 'sram_a', 'sram_b'},
          'dma': {'sram_a', 'sram_b'},
        },
      ),
      returnsNormally,
    );
  });

  test('a range that runs past the last slave throws', () {
    expect(
      () => _soc(
        targets: [const BusAddressRange(0x08000800, 0x2000)],
        channels: {
          'primary': {'dma', 'sram_a', 'sram_b'},
          'dma': {'sram_a', 'sram_b'},
        },
      ),
      throwsStateError,
    );
  });

  group('burst masters', () {
    // A DMA master with SRAM and a register slave, the register slave being
    // the only one that may lack burst support.
    HarborSoC burstSoc(
      HarborFabricKind kind, {
      List<BusAddressRange>? targets,
      List<BusAddressRange>? bursts,
    }) {
      final soc = HarborSoC(
        name: 'burst_${kind.name}',
        compatible: 'test,burst',
        fabricKind: kind,
        target: const HarborSimTarget(frequency: 50000000),
      );
      final cpu = soc.addMaster(AdmaCpu(kind));
      final dma = HarborDmaController(
        baseAddress: 0x30000000,
        channels: 1,
        busAddressWidth: 32,
        fabricKind: kind,
      );
      soc.addPeripheral(dma);
      soc.addMaster(
        dma,
        busInterfaceName: 'dma',
        memory: true,
        outstanding: 1,
        targetRanges: targets,
        burstRanges: bursts,
      );
      soc.addPeripheral(
        HarborSram(
          name: 'sram',
          baseAddress: 0x08000000,
          size: 0x1000,
          busAddressWidth: 32,
          protocol: kind,
        ),
      );
      soc.addPeripheral(
        HarborGpio(
          baseAddress: 0x40000000,
          pinCount: 8,
          busAddressWidth: 32,
          fabricKind: kind,
          name: 'gpio0',
        ),
      );
      cpu.pullUp(soc);
      soc.buildFabric();
      return soc;
    }

    const sram = BusAddressRange(0x08000000, 0x1000);
    const regs = BusAddressRange(0x40000000, 0x1000);

    test('a burst master onto a TL-UL slave throws and names all three', () {
      expect(
        () => burstSoc(HarborFabricKind.tilelink, bursts: [sram, regs]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('dma_dma'),
              contains('gpio0'),
              contains('0x40000000'),
              contains('burst range'),
              contains('cannot take bursts'),
            ),
          ),
        ),
      );
    });

    test('a range that holds only burst slaves passes', () {
      expect(
        () => burstSoc(HarborFabricKind.tilelink, bursts: [sram]),
        returnsNormally,
      );
    });

    test('target ranges alone are not a burst check', () {
      expect(
        () => burstSoc(HarborFabricKind.tilelink, targets: [sram, regs]),
        returnsNormally,
      );
    });

    for (final kind in [HarborFabricKind.axi4, HarborFabricKind.wishbone]) {
      test('${kind.name} takes bursts on every slave', () {
        expect(
          () => burstSoc(kind, targets: [sram, regs], bursts: [sram, regs]),
          returnsNormally,
        );
      });
    }
  });
}
