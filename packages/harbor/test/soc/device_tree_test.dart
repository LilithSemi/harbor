import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  group('HarborDeviceTreeGenerator', () {
    test('generates valid DTS with CPUs and peripherals', () {
      final clint = HarborClint(baseAddress: 0x02000000);
      final plic = HarborPlic(baseAddress: 0x0C000000, sources: 32);
      final uart = HarborUart(
        baseAddress: 0x10000000,
        clockFrequency: 48000000,
      );

      final dts = HarborDeviceTreeGenerator(
        model: 'Test SoC',
        compatible: 'test,soc-v1',
        cpus: [HarborCpu(hartId: 0, isa: 'rv64imac', mmu: 'riscv,sv39')],
        peripherals: [clint, plic, uart],
      ).generate();

      expect(dts, contains('/dts-v1/'));
      expect(dts, contains('model = "Test SoC"'));
      expect(dts, contains('compatible = "test,soc-v1"'));

      // CPUs
      expect(dts, contains('cpu@0'));
      expect(dts, contains('riscv,isa = "rv64imac"'));
      expect(dts, contains('mmu-type = "riscv,sv39"'));

      // CLINT
      expect(dts, contains('compatible = "riscv,clint0"'));
      expect(dts, contains('0x2000000'));

      // PLIC
      expect(dts, contains('compatible = "sifive,plic-1.0.0"'));
      expect(dts, contains('interrupt-controller'));
      expect(dts, contains('riscv,ndev'));

      // UART
      expect(dts, contains('compatible = "ns16550a"'));
      expect(dts, contains('0x10000000'));
      expect(dts, contains('clock-frequency'));
    });

    test('emits the isa-base and isa-extensions pair', () {
      final dts = HarborDeviceTreeGenerator(
        model: 'Test SoC',
        compatible: 'test,soc-v1',
        cpus: [
          HarborCpu(
            hartId: 0,
            isa: 'rv64imafdc_zicsr_zifencei_sstc',
            isaBase: 'rv64i',
            isaExtensions: const [
              'i',
              'm',
              'a',
              'f',
              'd',
              'c',
              'zicsr',
              'zifencei',
              'sstc',
            ],
            mmu: 'riscv,sv39',
          ),
        ],
        peripherals: [HarborClint(baseAddress: 0x02000000)],
      ).generate();

      expect(dts, contains('riscv,isa-base = "rv64i"'));
      expect(
        dts,
        contains(
          'riscv,isa-extensions = "i", "m", "a", "f", "d", "c", '
          '"zicsr", "zifencei", "sstc";',
        ),
      );
    });

    test('leaves the pair out when the caller gives no extension list', () {
      final dts = HarborDeviceTreeGenerator(
        model: 'Test SoC',
        compatible: 'test,soc-v1',
        cpus: [HarborCpu(hartId: 0, isa: 'rv64imac')],
        peripherals: [HarborClint(baseAddress: 0x02000000)],
      ).generate();

      expect(dts, contains('riscv,isa = "rv64imac"'));
      expect(dts, isNot(contains('riscv,isa-base')));
      expect(dts, isNot(contains('riscv,isa-extensions')));
    });

    test('emits a device_type=memory root node for RAM spans', () {
      final dts = HarborDeviceTreeGenerator(
        model: 'Mem SoC',
        compatible: 'test,mem-v1',
        cpus: [HarborCpu(hartId: 0, isa: 'rv64imac')],
        memories: [BusAddressRange(0x80000000, 0x08000000)],
      ).generate();

      // A root memory node (not under /soc) an OS can discover.
      expect(dts, contains('memory@80000000 {'));
      expect(dts, contains('device_type = "memory";'));
      expect(dts, contains('reg = <0x80000000 0x8000000>;'));
    });

    test('emits timebase-frequency when the CPU carries it', () {
      final dts = HarborDeviceTreeGenerator(
        model: 'Timed SoC',
        compatible: 'test,timed-v1',
        cpus: [
          HarborCpu(hartId: 0, isa: 'rv64imac', timebaseFrequency: 25000000),
        ],
      ).generate();

      expect(dts, contains('timebase-frequency = <25000000>;'));
      // Linux reads it from /cpus, so it must sit right under that node.
      expect(
        dts,
        contains(
          '    cpus {\n'
          '        #address-cells = <1>;\n'
          '        #size-cells = <0>;\n'
          '        timebase-frequency = <25000000>;\n',
        ),
      );
    });

    test('rejects harts with different timebase-frequency values', () {
      final gen = HarborDeviceTreeGenerator(
        model: 'Mixed SoC',
        compatible: 'test,mixed-v1',
        cpus: [
          HarborCpu(hartId: 0, isa: 'rv64imac', timebaseFrequency: 25000000),
          HarborCpu(hartId: 1, isa: 'rv64imac', timebaseFrequency: 10000000),
        ],
      );
      expect(gen.generate, throwsArgumentError);
    });

    test('generates minimal DTS without CPUs', () {
      final dts = HarborDeviceTreeGenerator(
        model: 'Minimal',
        compatible: 'test,minimal',
      ).generate();

      expect(dts, contains('/dts-v1/'));
      expect(dts, contains('model = "Minimal"'));
      expect(dts, isNot(contains('cpus')));
      expect(dts, isNot(contains('soc')));
    });

    test('handles multi-hart setup', () {
      final dts = HarborDeviceTreeGenerator(
        model: 'Multi',
        compatible: 'test,multi',
        cpus: [
          HarborCpu(hartId: 0, isa: 'rv32imac'),
          HarborCpu(hartId: 1, isa: 'rv32imac'),
        ],
      ).generate();

      expect(dts, contains('cpu@0'));
      expect(dts, contains('cpu@1'));
    });
  });

  group('HarborDeviceTreeGenerator labels and interrupt domains', () {
    String gen(
      List<HarborDeviceTreeNodeProvider> p, {
      Map<HarborDeviceTreeNodeProvider, List<int>> irqs = const {},
    }) => HarborDeviceTreeGenerator(
      model: 'm',
      compatible: 'c',
      peripherals: p,
      interrupts: irqs,
    ).generate();

    test('a GPIO without an interrupt is not an interrupt controller', () {
      final gpio = HarborGpio(baseAddress: 0x10001000);
      final dts = gen([gpio]);
      expect(dts, isNot(contains('interrupt-controller')));
      expect(dts, isNot(contains('#interrupt-cells')));
    });

    test('a GPIO with an interrupt writes its interrupt domain', () {
      final gpio = HarborGpio(baseAddress: 0x10001000);
      final dts = gen(
        [gpio],
        irqs: {
          gpio: [5],
        },
      );
      expect(dts, contains('interrupts = <0x5>;'));
      expect(dts, contains('interrupt-controller;'));
      expect(dts, contains('#interrupt-cells = <2>;'));
    });

    test('two nodes with the same label are refused', () {
      final a = HarborGpio(baseAddress: 0x10001000);
      final b = HarborGpio(baseAddress: 0x10002000);
      expect(
        () => gen([a, b]),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'label')),
      );
      final named = HarborGpio(baseAddress: 0x10002000, dtLabel: 'gpio1');
      expect(gen([a, named]), contains('gpio1: gpio@10002000'));
    });

    test('a label on an interrupt controller is used', () {
      final plic = _LabelledController();
      final dts = gen([plic]);
      expect(dts, contains('myintc: labelled@c000000'));
      expect(dts, contains('interrupt-parent = <&myintc>;'));
    });
  });

  group('HarborDeviceTreeNodeProvider', () {
    test('CLINT has correct DT properties', () {
      final clint = HarborClint(baseAddress: 0x02000000);
      final dt = clint.dtNode;
      expect(dt.compatible.first, equals('riscv,clint0'));
      expect(dt.reg.start, equals(0x02000000));
      expect(dt.reg.size, equals(0x10000));
      expect(dt.interruptController, isFalse);
    });

    test('PLIC has correct DT properties', () {
      final plic = HarborPlic(baseAddress: 0x0C000000, sources: 64);
      final dt = plic.dtNode;
      expect(dt.compatible.first, equals('sifive,plic-1.0.0'));
      expect(dt.reg.start, equals(0x0C000000));
      expect(dt.interruptController, isTrue);
      expect(dt.interruptCells, equals(1));
      expect(dt.properties['riscv,ndev'], equals(64));
    });

    test('APLIC has correct DT properties', () {
      final aplic = HarborAplic(baseAddress: 0x0D000000, sources: 128);
      final dt = aplic.dtNode;
      expect(dt.compatible.first, equals('riscv,aplic'));
      expect(dt.interruptController, isTrue);
      expect(dt.interruptCells, equals(2));
      expect(dt.properties['riscv,num-sources'], equals(128));
    });

    test('UART has correct DT properties', () {
      final uart = HarborUart(
        baseAddress: 0x10000000,
        clockFrequency: 48000000,
      );
      final dt = uart.dtNode;
      expect(dt.compatible.first, equals('ns16550a'));
      expect(dt.reg.start, equals(0x10000000));
      expect(dt.reg.size, equals(0x1000));
      expect(dt.properties['clock-frequency'], equals(48000000));
    });

    test('nodeName generated from compatible', () {
      final uart = HarborUart(baseAddress: 0x10000000);
      expect(uart.dtNode.nodeName, equals('ns16550a@10000000'));
    });

    test('HarborDeviceTreeNode toString', () {
      final node = HarborDeviceTreeNode(
        compatible: ['ns16550a'],
        reg: BusAddressRange(0x10000000, 0x1000),
      );
      expect(node.toString(), contains('ns16550a'));
      expect(node.toString(), contains('0x10000000'));
    });

    group('model and cpu naming', () {
      String gen({String model = 'Test SoC', List<HarborCpu>? cpus}) =>
          HarborDeviceTreeGenerator(
            model: model,
            compatible: 'test,soc-v1',
            cpus: cpus ?? [HarborCpu(hartId: 0, isa: 'rv64imac')],
          ).generate();

      test('default cpu node is unchanged', () {
        final dts = gen();
        expect(dts, contains('    model = "Test SoC";\n'));
        expect(dts, contains('            compatible = "riscv";\n'));
        expect(
          RegExp(r'^\s+model = ', multiLine: true).allMatches(dts).length,
          equals(1),
        );
      });

      test('cpu model and vendor compatible are emitted', () {
        final dts = gen(
          model: 'Delta V1',
          cpus: [
            HarborCpu(
              hartId: 0,
              isa: 'rv64imac',
              model: 'River RC1.f',
              compatible: ['lilith,river-rc1f'],
            ),
            HarborCpu(
              hartId: 1,
              isa: 'rv64imac',
              model: 'River RC1.f',
              compatible: ['lilith,river-rc1f'],
            ),
          ],
        );
        expect(dts, contains('    model = "Delta V1";\n'));
        expect('model = "River RC1.f";'.allMatches(dts).length, equals(2));
        expect(
          'compatible = "lilith,river-rc1f", "riscv";'.allMatches(dts).length,
          equals(2),
        );
      });

      test('strings are escaped', () {
        final dts = gen(model: 'A "quoted" \\ name');
        expect(dts, contains(r'model = "A \"quoted\" \\ name";'));
      });
    });
  });
}

class _LabelledController with HarborDeviceTreeNodeProvider {
  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['test,labelled'],
    reg: BusAddressRange(0x0C000000, 0x1000),
    interruptController: true,
    label: 'myintc',
  );
}
