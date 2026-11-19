import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

class _Cpu extends BridgeModule {
  _Cpu() : super('FabricDomainCpu', name: 'cpu') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final i = addInterface(
      WishboneInterface(WishboneConfig(addressWidth: 32, dataWidth: 32)),
      name: 'dataBus',
      role: PairRole.provider,
    ).internalInterface!;
    for (final e in i.getPorts([PairDirection.fromProvider]).entries) {
      final w = e.value.width;
      e.value <= addInput('p_${e.key}', Logic(width: w), width: w);
    }
    for (final e in i.getPorts([PairDirection.fromConsumer]).entries) {
      addOutput('p_${e.key}', width: e.value.width) <= e.value;
    }
  }

  void pullUp(HarborSoC soc) {
    for (final n in [...inputs.keys, ...outputs.keys]) {
      if (!n.startsWith('p_')) continue;
      soc.pullUpPort(port(n), newPortName: 'cpu_${n.substring(2)}');
    }
  }
}

HarborClockConfig _clk(String name, int hz) => HarborClockConfig.fixed(
  name: name,
  frequency: hz,
  sourceFrequency: 50000000,
  isPrimary: false,
);

HarborSoC _soc(List<HarborClockConfig> clocks, {String? fabric}) => HarborSoC(
  name: 'FabricDomainSoc',
  compatible: 'test,fabric-domain',
  target: const HarborSimTarget(frequency: 50000000),
  clocks: clocks,
  fabricClockDomain: fabric,
);

HarborUart _uart() =>
    HarborUart(baseAddress: 0x10000000, busAddressWidth: 32, busDataWidth: 32);

void main() {
  tearDown(() async => Simulator.reset());

  group('a named fabric domain', () {
    test('drives the fabric, an unnamed peripheral and its rate', () {
      final soc = _soc([
        _clk('sys', 50000000),
        _clk('bus', 25000000),
      ], fabric: 'bus');
      final bus = soc.clockDomain('bus')!;
      final cpu = soc.addMaster(_Cpu());
      final uart = soc.addPeripheral(_uart());
      cpu.pullUp(soc);
      soc.buildFabric();
      expect(identical(soc.defaultClock.$1, bus.clk), isTrue);
      expect(soc.domainFor(null), same(bus));
      expect(soc.fabric!.input('clk').srcConnection, same(bus.clk));
      expect(
        uart.input('clk').srcConnection!.srcConnections,
        contains(bus.clk),
      );
      expect(soc.inputClockHzFor(null), 25000000);
      expect(soc.simClockOf(uart, 50000000), (port: 'bus_clk', hz: 25000000));
      expect(
        soc.generateDts(),
        matches(RegExp(r'@10000000 \{[^}]*clock-frequency = <25000000>')),
      );
    });

    test('a missing name throws at buildFabric and names it', () {
      final soc = _soc([_clk('sys', 50000000)], fabric: 'bus');
      expect(
        soc.buildFabric,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('bus'),
          ),
        ),
      );
    });

    test('a peripheral with no domain before the domain exists throws', () {
      final soc = _soc([], fabric: 'bus');
      expect(
        () => soc.addPeripheral(_uart()),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('"bus"'),
              contains('FabricDomainSoc'),
              contains('before addPeripheral'),
            ),
          ),
        ),
      );
    });

    test('a master with no domain follows the named domain', () {
      final soc = _soc([
        _clk('sys', 50000000),
        _clk('bus', 25000000),
      ], fabric: 'bus');
      final cpu = soc.addMaster(_Cpu());
      expect(
        cpu.input('clk').srcConnection!.srcConnections,
        contains(soc.clockDomain('bus')!.clk),
      );
    });

    test('a net domain has no sim clock to report', () {
      final soc = _soc([_clk('sys', 50000000)], fabric: 'bus');
      final ext = soc.addInput('ext_clk', Logic());
      soc.addClockDomainFromNet(_clk('bus', 25000000), ext);
      final uart = soc.addPeripheral(_uart());
      expect(
        () => soc.simClockOf(uart, 50000000),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('"bus"'),
          ),
        ),
      );
    });

    test('a domain added after the constructor is found', () {
      final soc = _soc([_clk('sys', 50000000)], fabric: 'bus');
      final ext = soc.addInput('ext_clk', Logic());
      final bus = soc.addClockDomainFromNet(_clk('bus', 25000000), ext);
      expect(soc.domainFor(null), same(bus));
      soc.buildFabric();
    });
  });

  group('with no fabric domain', () {
    test('sys wins over the first domain', () {
      final soc = _soc([_clk('first', 25000000), _clk('sys', 40000000)]);
      final sys = soc.clockDomain('sys')!;
      final uart = soc.addPeripheral(_uart());
      expect(soc.domainFor(null), same(sys));
      expect(identical(soc.defaultClock.$1, sys.clk), isTrue);
      expect(soc.simClockOf(uart, 1).hz, 40000000);
    });

    test('the first domain wins when there is no sys', () {
      final soc = _soc([_clk('a', 25000000), _clk('b', 12500000)]);
      final a = soc.clockDomain('a')!;
      final uart = soc.addPeripheral(_uart());
      expect(soc.domainFor(null), same(a));
      expect(identical(soc.defaultClock.$1, a.clk), isTrue);
      expect(soc.simClockOf(uart, 1).hz, 25000000);
    });

    test('a sys secondary stays the default on all three paths', () {
      final board = HarborBoard.get('ulx3s-85f');
      final soc = HarborSoC(
        name: 'SecondarySoc',
        compatible: 'test,secondary',
        target: board.fpgaTarget(pins: ['clk']),
        clocks: [
          const HarborClockConfig(
            name: 'fast',
            rate: HarborFixedClockRate(125000000),
            sourceFrequency: 25000000,
            coClkosSecondary: (
              name: 'sys',
              frequency: 62500000,
              tolerancePpm: 0,
            ),
          ),
        ],
      );
      final sys = soc.clockDomain('sys')!;
      final uart = soc.addPeripheral(_uart());
      expect(soc.domainFor(null), same(sys));
      expect(identical(soc.defaultClock.$1, sys.clk), isTrue);
      expect(() => soc.simClockOf(uart, 25000000), throwsStateError);
    });

    test('a coClkos pair can name either output as the fabric', () {
      HarborSoC pair(String fabric) => HarborSoC(
        name: 'PairSoc',
        compatible: 'test,pair',
        target: HarborBoard.get('ulx3s-85f').fpgaTarget(pins: ['clk']),
        fabricClockDomain: fabric,
        clocks: [
          const HarborClockConfig(
            name: 'fast',
            rate: HarborFixedClockRate(125000000),
            sourceFrequency: 25000000,
            coClkosSecondary: (
              name: 'sys',
              frequency: 62500000,
              tolerancePpm: 0,
            ),
          ),
        ],
      );
      final secondary = pair('sys');
      expect(secondary.domainFor(null), same(secondary.clockDomain('sys')));
      final primary = pair('fast');
      expect(primary.domainFor(null), same(primary.clockDomain('fast')));
      expect(primary.inputClockHzFor(null), 125000000);
    });
  });
}
