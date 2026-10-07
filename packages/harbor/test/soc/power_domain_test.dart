import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  group('HarborPowerDomainIntegration', () {
    late HarborPowerManagementUnit pmu;

    setUp(() {
      pmu = HarborPowerManagementUnit(
        baseAddress: 0x10008000,
        config: const HarborPmuConfig(
          domains: [
            HarborPowerDomain(name: 'core', index: 0),
            HarborPowerDomain(name: 'periph', index: 1),
            HarborPowerDomain(name: 'ddr', index: 2),
          ],
        ),
      );
    });

    test('assign adds peripheral to domain', () {
      final pdi = HarborPowerDomainIntegration(pmu: pmu);
      final uart = HarborUart(baseAddress: 0x10000000);

      pdi.assign(uart, domain: 1);
      expect(pdi.peripheralsInDomain(1), contains(uart));
      expect(pdi.domainOf(uart), equals(1));
    });

    test('assignAll adds multiple peripherals', () {
      final pdi = HarborPowerDomainIntegration(pmu: pmu);
      final uart = HarborUart(baseAddress: 0x10000000);
      final spi = HarborSpiController(baseAddress: 0x10002000);

      pdi.assignAll([uart, spi], domain: 1);
      expect(pdi.peripheralsInDomain(1), hasLength(2));
    });

    test('usedDomains tracks assignments', () {
      final pdi = HarborPowerDomainIntegration(pmu: pmu);
      final uart = HarborUart(baseAddress: 0x10000000);
      final ddr = HarborDdr3(
        baseAddress: 0x10006000,
        config: const HarborDdrConfig.orangeCrab(),
        clockHz: 48000000,
      );

      pdi.assign(uart, domain: 1);
      pdi.assign(ddr, domain: 2);

      expect(pdi.usedDomains, containsAll([1, 2]));
      expect(pdi.usedDomains, isNot(contains(0)));
    });

    test('domainOf returns null for unassigned', () {
      final pdi = HarborPowerDomainIntegration(pmu: pmu);
      final uart = HarborUart(baseAddress: 0x10000000);
      expect(pdi.domainOf(uart), isNull);
    });

    test('summary output', () {
      final pdi = HarborPowerDomainIntegration(pmu: pmu);
      final uart = HarborUart(baseAddress: 0x10000000);
      final spi = HarborSpiController(baseAddress: 0x10002000);

      pdi.assign(uart, domain: 1);
      pdi.assign(spi, domain: 1);

      final summary = pdi.summary();
      expect(summary, contains('Domain 1'));
      expect(summary, contains('uart'));
      expect(summary, contains('spi'));
    });

    test('negative domain throws', () {
      final pdi = HarborPowerDomainIntegration(pmu: pmu);
      final uart = HarborUart(baseAddress: 0x10000000);
      expect(() => pdi.assign(uart, domain: -1), throwsArgumentError);
    });
  });
}
