import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  group('Sky130Provider', () {
    late Sky130Provider pdk;

    setUp(() {
      pdk = Sky130Provider(pdkRoot: '/pdk/sky130A');
    });

    test('name', () {
      expect(pdk.name, equals('SkyWater SKY130'));
    });

    test('node', () {
      expect(pdk.node, equals('130nm'));
    });

    test('metalLayers', () {
      expect(pdk.metalLayers, equals(5));
    });

    test('supplyVoltage', () {
      expect(pdk.supplyVoltage, equals(1.8));
    });

    test('standardCellLibrary', () {
      final lib = pdk.standardCellLibrary;
      expect(lib.name, equals('sky130_fd_sc_hd'));
      expect(lib.libertyPath, contains('sky130_fd_sc_hd'));
    });

    test('ioCell returns AnalogBlock', () {
      final cell = pdk.ioCell(index: 0);
      expect(cell, isA<AnalogBlock>());
      expect(cell.pinMapping, containsPair('padIn', 'PAD'));
    });

    test('pll returns AnalogBlock', () {
      final p = pdk.pll(index: 0);
      expect(p, isA<AnalogBlock>());
      expect(p.pinMapping, containsPair('refClk', 'CLK'));
    });

    test('hasEfuse is true', () {
      expect(pdk.hasEfuse, isTrue);
    });

    test('efuse returns AnalogBlock', () {
      final ef = pdk.efuse(bits: 256);
      expect(ef, isA<AnalogBlock>());
      expect(ef!.pinMapping, containsPair('program', 'PGM'));
    });

    test('hasTemperatureSensor is true', () {
      expect(pdk.hasTemperatureSensor, isTrue);
    });

    test('temperatureSensor returns AnalogBlock', () {
      final ts = pdk.temperatureSensor();
      expect(ts, isA<AnalogBlock>());
      expect(ts!.pinMapping, containsPair('vbe', 'B'));
    });
  });

  group('Gf180mcuProvider', () {
    test('3.3V variant', () {
      final pdk = Gf180mcuProvider(pdkRoot: '/pdk/gf180mcuD');
      expect(pdk.name, equals('GlobalFoundries GF180MCU'));
      expect(pdk.node, equals('180nm'));
      expect(pdk.metalLayers, equals(5));
      expect(pdk.supplyVoltage, equals(3.3));
      expect(pdk.standardCellLibrary.name, equals('gf180mcu_fd_sc_mcu7t5v0'));
    });

    test('5.0V variant', () {
      final pdk = Gf180mcuProvider(
        pdkRoot: '/pdk/gf180mcuD',
        voltage: Gf180mcuVoltage.v5_0,
      );
      expect(pdk.supplyVoltage, equals(5.0));
      expect(pdk.standardCellLibrary.name, equals('gf180mcu_fd_sc_mcu9t5v0'));
    });

    test('ioCell returns AnalogBlock', () {
      final pdk = Gf180mcuProvider(pdkRoot: '/pdk/gf180mcuD');
      final cell = pdk.ioCell(index: 0);
      expect(cell, isA<AnalogBlock>());
    });

    test('pll returns AnalogBlock', () {
      final pdk = Gf180mcuProvider(pdkRoot: '/pdk/gf180mcuD');
      expect(pdk.pll(index: 0), isA<AnalogBlock>());
    });

    test('hasEfuse is true', () {
      final pdk = Gf180mcuProvider(pdkRoot: '/pdk/gf180mcuD');
      expect(pdk.hasEfuse, isTrue);
    });

    test('efuse returns AnalogBlock', () {
      final pdk = Gf180mcuProvider(pdkRoot: '/pdk/gf180mcuD');
      final ef = pdk.efuse(bits: 128);
      expect(ef, isA<AnalogBlock>());
    });

    test('hasTemperatureSensor is true', () {
      final pdk = Gf180mcuProvider(pdkRoot: '/pdk/gf180mcuD');
      expect(pdk.hasTemperatureSensor, isTrue);
    });

    test('temperatureSensor returns AnalogBlock', () {
      final pdk = Gf180mcuProvider(pdkRoot: '/pdk/gf180mcuD');
      expect(pdk.temperatureSensor(), isA<AnalogBlock>());
    });
  });

  group('AnalogBlock', () {
    test('symbolPath and pinMapping', () {
      const block = AnalogBlock(
        symbolPath: '/path/to/cell.lef',
        pinMapping: {'a': 'A', 'b': 'B'},
      );
      expect(block.symbolPath, equals('/path/to/cell.lef'));
      expect(block.pinMapping, hasLength(2));
      expect(block.pinMapping['a'], equals('A'));
    });

    test('toPrettyString contains field info', () {
      const block = AnalogBlock(
        symbolPath: '/test.lef',
        pinMapping: {'in': 'IN'},
        properties: {'name': 'test'},
      );
      final pretty = block.toPrettyString();
      expect(pretty, contains('AnalogBlock'));
      expect(pretty, contains('/test.lef'));
      expect(pretty, contains('in -> IN'));
    });
  });

  group('HarborIoRing', () {
    late HarborIoRing ring;

    setUp(() {
      ring = HarborIoRing(
        pads: [
          const HarborIoPad(
            signalName: 'clk',
            edge: HarborIoPadEdge.west,
            position: 0,
          ),
          const HarborIoPad(
            signalName: 'reset',
            edge: HarborIoPadEdge.west,
            position: 1,
          ),
          const HarborIoPad(
            signalName: 'uart_tx',
            edge: HarborIoPadEdge.south,
            position: 0,
          ),
          const HarborIoPad.vdd(edge: HarborIoPadEdge.north, position: 0),
          const HarborIoPad.vss(edge: HarborIoPadEdge.north, position: 1),
        ],
      );
    });

    test('padsOnEdge returns sorted pads', () {
      final westPads = ring.padsOnEdge(HarborIoPadEdge.west);
      expect(westPads, hasLength(2));
      expect(westPads[0].signalName, equals('clk'));
      expect(westPads[1].signalName, equals('reset'));
    });

    test('signalPads excludes power', () {
      expect(ring.signalPads, hasLength(3));
    });

    test('powerPads only returns power', () {
      expect(ring.powerPads, hasLength(2));
      expect(ring.powerPads.every((p) => p.isPower), isTrue);
    });

    test('totalPads', () {
      expect(ring.totalPads, equals(5));
    });

    test('toPrettyString', () {
      final pretty = ring.toPrettyString();
      expect(pretty, contains('HarborIoRing'));
      expect(pretty, contains('clk'));
      expect(pretty, contains('VDD'));
    });
  });

  group('HarborIoPad', () {
    test('vdd constructor', () {
      const pad = HarborIoPad.vdd(edge: HarborIoPadEdge.north);
      expect(pad.signalName, equals('VDD'));
      expect(pad.isPower, isTrue);
      expect(pad.powerNet, equals('VDD'));
    });

    test('vss constructor', () {
      const pad = HarborIoPad.vss(edge: HarborIoPadEdge.south);
      expect(pad.signalName, equals('VSS'));
      expect(pad.isPower, isTrue);
      expect(pad.powerNet, equals('VSS'));
    });
  });

  group('HarborKlayoutScripts', () {
    late HarborKlayoutScripts scripts;

    setUp(() {
      scripts = HarborKlayoutScripts(
        pdkName: 'sky130',
        topCell: 'TestSoC',
        drc: const HarborKlayoutDrcConfig(deckPath: '/pdk/drc.lydrc'),
        lvsNetlistPath: '/build/netlist.v',
      );
    });

    test('generateGdsMerge returns non-empty string containing klayout', () {
      final result = scripts.generateGdsMerge(
        digitalGdsPath: '/build/digital.gds',
        analogGdsPaths: ['/pdk/io.gds'],
        outputGdsPath: '/build/final.gds',
      );
      expect(result, isNotEmpty);
      expect(result, contains('klayout'));
    });

    test('generateDrc returns non-empty string', () {
      final result = scripts.generateDrc(gdsPath: '/build/final.gds');
      expect(result, isNotEmpty);
      expect(result, contains('klayout'));
      expect(result, contains('DRC'));
    });

    test('generateDrc runs the deck and fails on violations', () {
      final result = HarborKlayoutScripts(
        pdkName: 'gf180',
        topCell: 'TestSoC',
        drc: const HarborKlayoutDrcConfig(
          deckPath: '/deck/main.drc',
          options: {'thr': '4'},
        ),
      ).generateDrc(gdsPath: 'TestSoC.gds');
      expect(result, contains('"/deck/main.drc"'));
      expect(result, contains('"input=TestSoC.gds"'));
      expect(result, contains('"report=TestSoC_drc.xml"'));
      expect(result, contains('"thr=4"'));
      expect(result, contains('db.load(report)'));
      expect(
        RegExp(r'sys\.exit\(1\)').allMatches(result),
        hasLength(3),
        reason: 'deck error, missing report and violations each fail',
      );
      expect(result, isNot(contains('exec(')));
    });

    test('generateDrc needs a deck', () {
      expect(
        () => const HarborKlayoutScripts(
          pdkName: 'gf180',
          topCell: 'TestSoC',
        ).generateDrc(gdsPath: 'TestSoC.gds'),
        throwsStateError,
      );
    });

    test('generateLvs returns non-empty string', () {
      final result = scripts.generateLvs(gdsPath: '/build/final.gds');
      expect(result, isNotEmpty);
      expect(result, contains('klayout'));
      expect(result, contains('LVS'));
    });

    test('generateDefToGds returns non-empty string', () {
      final result = scripts.generateDefToGds(
        defPath: '/build/top.def',
        techLefPath: '/pdk/tech.lef',
        outputGdsPath: '/build/top.gds',
      );
      expect(result, isNotEmpty);
      expect(result, contains('klayout'));
    });
  });
}
