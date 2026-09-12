import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  group('HarborInterruptRouting', () {
    test('PLIC-based routing', () {
      final plic = HarborPlic(
        baseAddress: 0x0C000000,
        sources: 32,
        contexts: 2,
      );
      final routing = HarborInterruptRouting.plic(plic: plic);
      expect(routing.numHarts, equals(2));
    });

    test('APLIC wired routing', () {
      final aplic = HarborAplic(baseAddress: 0x0C000000, sources: 64, harts: 4);
      final routing = HarborInterruptRouting.aplicWired(aplic: aplic);
      expect(routing.numHarts, equals(4));
    });

    test('AIA routing with IMSIC', () {
      final aplic = HarborAplic(baseAddress: 0x0C000000, sources: 64, harts: 2);
      final imsic0 = HarborImsic(baseAddress: 0x24000000, hartIndex: 0);
      final imsic1 = HarborImsic(baseAddress: 0x24001000, hartIndex: 1);
      final routing = HarborInterruptRouting.aia(
        aplic: aplic,
        imsics: [imsic0, imsic1],
      );
      expect(routing.numHarts, equals(2));
    });

    test('connectSource assigns incrementing indices', () {
      final plic = HarborPlic(
        baseAddress: 0x0C000000,
        sources: 32,
        contexts: 1,
      );
      final routing = HarborInterruptRouting.plic(plic: plic);

      final uart = HarborUart(baseAddress: 0x10000000);
      final gpio = HarborGpio(baseAddress: 0x10001000);

      final uartIdx = routing.connectSource(uart);
      final gpioIdx = routing.connectSource(gpio);

      expect(uartIdx, equals(1)); // source 0 is reserved
      expect(gpioIdx, equals(2));
      expect(routing.sourceCount, equals(3));
    });

    test('connectSources skips interrupt controllers', () {
      final plic = HarborPlic(
        baseAddress: 0x0C000000,
        sources: 32,
        contexts: 1,
      );
      final routing = HarborInterruptRouting.plic(plic: plic);

      final uart = HarborUart(baseAddress: 0x10000000);
      final result = routing.connectSources([plic, uart]);

      // PLIC itself should be skipped
      expect(result, isNot(contains('plic')));
      expect(result.containsKey(uart.name), isTrue);
    });

    test('hartInterrupt returns PLIC ext_irq', () {
      final plic = HarborPlic(
        baseAddress: 0x0C000000,
        sources: 32,
        contexts: 2,
      );
      final routing = HarborInterruptRouting.plic(plic: plic);

      final irq0 = routing.hartInterrupt(0);
      final irq1 = routing.hartInterrupt(1);
      expect(irq0.width, equals(1));
      expect(irq1.width, equals(1));
    });

    test('hartInterrupt with IMSIC returns seip', () {
      final aplic = HarborAplic(baseAddress: 0x0C000000, sources: 32, harts: 1);
      final imsic = HarborImsic(baseAddress: 0x24000000, hartIndex: 0);
      final routing = HarborInterruptRouting.aia(aplic: aplic, imsics: [imsic]);

      final irq = routing.hartInterrupt(0);
      expect(irq.width, equals(1));
    });

    test('hartMachineInterrupt only with IMSIC', () {
      final plic = HarborPlic(
        baseAddress: 0x0C000000,
        sources: 32,
        contexts: 1,
      );
      final plicRouting = HarborInterruptRouting.plic(plic: plic);
      expect(plicRouting.hartMachineInterrupt(0), isNull);

      final aplic = HarborAplic(baseAddress: 0x0C000000, sources: 32, harts: 1);
      final imsic = HarborImsic(baseAddress: 0x24000000, hartIndex: 0);
      final aiaRouting = HarborInterruptRouting.aia(
        aplic: aplic,
        imsics: [imsic],
      );
      expect(aiaRouting.hartMachineInterrupt(0), isNotNull);
    });

    test('hartInterrupt out of range throws', () {
      final plic = HarborPlic(
        baseAddress: 0x0C000000,
        sources: 32,
        contexts: 1,
      );
      final routing = HarborInterruptRouting.plic(plic: plic);
      expect(() => routing.hartInterrupt(5), throwsRangeError);
    });

    test('source overflow throws', () {
      final plic = HarborPlic(baseAddress: 0x0C000000, sources: 3, contexts: 1);
      final routing = HarborInterruptRouting.plic(plic: plic);

      routing.connectSource(HarborUart(baseAddress: 0x10000000));
      routing.connectSource(HarborGpio(baseAddress: 0x10001000));
      expect(
        () =>
            routing.connectSource(HarborSpiController(baseAddress: 0x10002000)),
        throwsStateError,
      );
    });
  });

  group('HarborInterruptRouting SoC wiring', () {
    HarborSoC buildSoC() {
      final soc = HarborSoC(
        name: 'irq_soc',
        compatible: 'lilith,irq-soc',
        busConfig: WishboneConfig(addressWidth: 64, dataWidth: 64, selWidth: 8),
      );
      soc.addPeripheral(
        HarborUart(
          baseAddress: 0x10000000,
          busAddressWidth: 64,
          busDataWidth: 64,
        ),
      );
      soc.addPeripheral(
        HarborGpio(
          baseAddress: 0x10001000,
          busAddressWidth: 64,
          busDataWidth: 64,
        ),
      );
      soc.addPeripheral(
        HarborPlic(
          baseAddress: 0x0C000000,
          sources: 8,
          contexts: 1,
          busAddressWidth: 64,
          busDataWidth: 64,
        ),
      );
      return soc;
    }

    test('finds the SoC interrupt controller', () {
      final routing = HarborInterruptRouting.forSoC(buildSoC());
      expect(routing, isNotNull);
      expect(routing!.plic, isNotNull);
    });

    test('wires the numbers the device tree reports', () {
      final soc = buildSoC();
      final routing = HarborInterruptRouting.forSoC(soc)!;
      final assigned = routing.connectSoCSources(soc);

      // The peripheral order gives the uart source 1 and the gpio source 2.
      // The device tree must report exactly the same numbers: one allocator
      // feeds both the wires and the tables.
      expect(assigned.length, equals(2));
      expect(routing.sourceIndexOf('uart'), equals(1));
      expect(routing.sourceIndexOf('gpio'), equals(2));

      final dts = soc.generateDts();
      expect(dts, contains('ns16550a@10000000'));
      expect(dts, contains('interrupts = <0x1>'));
      expect(dts, contains('interrupts = <0x2>'));
    });

    test('never assigns source 0', () {
      final soc = buildSoC();
      final routing = HarborInterruptRouting.forSoC(soc)!;
      final assigned = routing.connectSoCSources(soc);
      expect(assigned.values, everyElement(greaterThanOrEqualTo(1)));
    });

    test('the interrupt controller is not its own source', () {
      final soc = buildSoC();
      final routing = HarborInterruptRouting.forSoC(soc)!;
      final assigned = routing.connectSoCSources(soc);
      expect(assigned.keys.map((m) => m.name), isNot(contains('plic')));
    });

    test('overflow of the source count throws', () {
      final soc = HarborSoC(
        name: 'small_irq_soc',
        compatible: 'lilith,small-irq-soc',
        busConfig: WishboneConfig(addressWidth: 64, dataWidth: 64, selWidth: 8),
      );
      soc.addPeripheral(
        HarborUart(
          baseAddress: 0x10000000,
          busAddressWidth: 64,
          busDataWidth: 64,
        ),
      );
      soc.addPeripheral(
        HarborGpio(
          baseAddress: 0x10001000,
          busAddressWidth: 64,
          busDataWidth: 64,
        ),
      );
      // Two sources need indices 1 and 2, so a 2-source controller is one short.
      soc.addPeripheral(
        HarborPlic(
          baseAddress: 0x0C000000,
          sources: 2,
          contexts: 1,
          busAddressWidth: 64,
          busDataWidth: 64,
        ),
      );
      final routing = HarborInterruptRouting.forSoC(soc)!;
      expect(() => routing.connectSoCSources(soc), throwsStateError);
    });
  });

  group('interrupt-controller device tree', () {
    HarborSoC socWith({
      required bool withPlic,
      List<HarborInterruptContext> contexts = const [],
      int harts = 1,
    }) {
      final soc = HarborSoC(
        name: 'dt_soc',
        compatible: 'lilith,dt-soc',
        busConfig: WishboneConfig(addressWidth: 64, dataWidth: 64, selWidth: 8),
        interruptContexts: contexts,
        cpus: [
          for (var h = 0; h < harts; h++) HarborCpu(hartId: h, isa: 'rv64imac'),
        ],
      );
      soc.addPeripheral(
        HarborUart(
          baseAddress: 0x10000000,
          busAddressWidth: 64,
          busDataWidth: 64,
        ),
      );
      if (withPlic) {
        soc.addPeripheral(
          HarborPlic(
            baseAddress: 0x0C000000,
            sources: 8,
            contexts: contexts.isEmpty ? 1 : contexts.length,
            busAddressWidth: 64,
            busDataWidth: 64,
          ),
        );
      }
      return soc;
    }

    test('a controller gets a phandle, a parent and its contexts', () {
      final dts = socWith(
        withPlic: true,
        contexts: const [
          HarborInterruptContext.machine(0),
          HarborInterruptContext.supervisor(0),
        ],
      ).generateDts();

      // Without a hart-local controller to point at, an OS has nothing to bind
      // the platform controller's contexts to.
      expect(dts, contains('cpu0_intc: interrupt-controller {'));
      expect(dts, contains('compatible = "riscv,cpu-intc"'));

      // Without these two an `interrupts = <n>` on a device resolves to nothing.
      expect(dts, contains('interrupt-parent = <&intc0>;'));
      expect(dts, contains('intc0: plic-1-0-0@c000000 {'));

      // Machine context first, then supervisor, matching the wiring order.
      expect(
        dts,
        contains('interrupts-extended = <&cpu0_intc 0xb>, <&cpu0_intc 0x9>;'),
      );
    });

    test('every phandle a reference names is defined', () {
      final dts = socWith(
        withPlic: true,
        contexts: const [
          HarborInterruptContext.machine(0),
          HarborInterruptContext.supervisor(0),
        ],
      ).generateDts();

      // A reference to a label with no `phandle` property is what makes a
      // consumer's lookup return null and silently drop the interrupt.
      final referenced = RegExp(
        r'&([A-Za-z_][A-Za-z0-9_]*)',
      ).allMatches(dts).map((m) => m.group(1)!).toSet();
      final defined = RegExp(
        r'([A-Za-z_][A-Za-z0-9_]*): [^\s]+ \{',
      ).allMatches(dts).map((m) => m.group(1)!).toSet();
      expect(referenced, isNotEmpty);
      expect(referenced.difference(defined), isEmpty);
      for (final label in referenced) {
        final node = dts.substring(dts.indexOf('$label: '));
        expect(
          node.substring(0, node.indexOf('};')),
          contains('phandle = <'),
          reason: '$label is referenced but carries no phandle',
        );
      }
    });

    test('one cpu-intc per hart', () {
      final dts = socWith(
        withPlic: true,
        harts: 2,
        contexts: const [
          HarborInterruptContext.machine(0),
          HarborInterruptContext.supervisor(0),
          HarborInterruptContext.machine(1),
          HarborInterruptContext.supervisor(1),
        ],
      ).generateDts();

      expect(dts, contains('cpu0_intc: interrupt-controller {'));
      expect(dts, contains('cpu1_intc: interrupt-controller {'));
      expect(
        dts,
        contains(
          'interrupts-extended = <&cpu0_intc 0xb>, <&cpu0_intc 0x9>, '
          '<&cpu1_intc 0xb>, <&cpu1_intc 0x9>;',
        ),
      );
    });

    test('a SoC with no interrupt controller stays plain', () {
      final dts = socWith(withPlic: false).generateDts();

      // Nothing to reference, so none of this belongs in the tree.
      expect(dts, isNot(contains('interrupt-parent')));
      expect(dts, isNot(contains('cpu-intc')));
      expect(dts, isNot(contains('phandle')));
    });
  });
}
