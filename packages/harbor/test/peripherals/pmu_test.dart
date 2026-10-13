import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

// Register byte offsets.
const _ctrl = 0x00;
const _wakeupEn = 0x10;
const _domCtrl = 0x40;
const _domIso = 0x50;

void main() {
  group('HarborPowerDomain', () {
    test('basic properties', () {
      const domain = HarborPowerDomain(name: 'cpu', index: 0);
      expect(domain.canPowerOff, isTrue);
      expect(domain.canRetain, isTrue);
    });
  });

  group('HarborPmuConfig', () {
    test('toPrettyString', () {
      const config = HarborPmuConfig(
        domains: [
          HarborPowerDomain(name: 'cpu', index: 0),
          HarborPowerDomain(name: 'gpu', index: 1, canPowerOff: false),
        ],
        supportsDvfs: true,
      );
      final pretty = config.toPrettyString();
      expect(pretty, contains('domains: 2'));
      expect(pretty, contains('DVFS'));
      expect(pretty, contains('cpu'));
      expect(pretty, contains('gpu'));
    });
  });

  group('HarborPowerManagementUnit', () {
    test('creates with domains', () {
      final pmu = HarborPowerManagementUnit(
        config: const HarborPmuConfig(
          domains: [
            HarborPowerDomain(name: 'cpu', index: 0),
            HarborPowerDomain(name: 'io', index: 1),
          ],
        ),
        baseAddress: 0x10006000,
      );
      expect(pmu.bus, isNotNull);
      expect(pmu.domainPower, hasLength(2));
    });

    test('DT node', () {
      final pmu = HarborPowerManagementUnit(
        config: const HarborPmuConfig(
          domains: [HarborPowerDomain(name: 'cpu', index: 0)],
        ),
        baseAddress: 0x10006000,
      );
      final dt = pmu.dtNode;
      expect(dt.compatible.first, equals('harbor,pmu'));
      expect(dt.properties['num-domains'], equals(1));
    });

    test('different domain sets get different definition names', () {
      final a = HarborPowerManagementUnit(
        config: const HarborPmuConfig(
          domains: [HarborPowerDomain(name: 'cpu', index: 0)],
        ),
        baseAddress: 0x10006000,
      );
      final b = HarborPowerManagementUnit(
        config: const HarborPmuConfig(
          domains: [
            HarborPowerDomain(name: 'cpu', index: 0),
            HarborPowerDomain(name: 'gpu', index: 1),
          ],
        ),
        baseAddress: 0x10006000,
      );
      expect(a.definitionName, isNot(equals(b.definitionName)));
    });
  });

  for (final kind in HarborFabricKind.values) {
    _registerTests(kind);
  }
}

void _registerTests(HarborFabricKind kind) {
  group('HarborPowerManagementUnit register access (${kind.name})', () {
    late HarborPowerManagementUnit pmu;
    late Logic clk, reset;
    late RegBus bus;

    Future<void> busWrite(int addr, int data) => bus.write(addr, data);

    Future<int> busRead(int addr) => bus.read(addr);

    Future<void> busWriteSel(int addr, int selMask, int data) =>
        bus.write(addr, data, sel: selMask);

    Future<void> setUpDut() async {
      pmu = HarborPowerManagementUnit(
        config: const HarborPmuConfig(
          domains: [
            HarborPowerDomain(name: 'cpu', index: 0),
            HarborPowerDomain(name: 'io', index: 1),
          ],
        ),
        baseAddress: 0x10006000,
        fabricKind: kind,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');

      pmu.input('clk').srcConnection! <= clk;
      pmu.input('reset').srcConnection! <= reset;
      bus = RegBus.attach(pmu, clk);

      await pmu.build();

      reset.inject(1);
      bus.idle();
      Simulator.setMaxSimTime(200000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    }

    tearDown(() async {
      await Simulator.reset();
    });

    test('CTRL holds global enable and sleep mode', () async {
      await setUpDut();

      await busWrite(_ctrl, 0x31);
      final v = await busRead(_ctrl);
      expect(v & 0x1, equals(1));
      expect((v >> 4) & 0x3, equals(0x3));
      await Simulator.endSimulation();
    });

    test('WAKEUP_EN is read/write', () async {
      await setUpDut();

      await busWrite(_wakeupEn, 0xa5);
      expect(await busRead(_wakeupEn), equals(0xa5));
      await Simulator.endSimulation();
    });

    test(
      'DOM_CTRL moves a domain to retention and the power output drops',
      (() async {
        await setUpDut();

        expect(pmu.domainPower[0].value.toInt(), equals(1));
        await busWrite(_domCtrl, HarborPowerDomainState.retention.index);
        await clk.nextPosedge;
        expect(pmu.domainPower[0].value.toInt(), equals(0));
        await Simulator.endSimulation();
      }),
    );

    test('DOM_ISO is read/write per domain', () async {
      await setUpDut();

      await busWrite(_domIso, 1);
      expect(await busRead(_domIso), equals(1));
      await Simulator.endSimulation();
    });

    test('a write with no byte selected changes nothing', () async {
      await setUpDut();

      await busWrite(_ctrl, 0x31);
      await busWrite(_wakeupEn, 0xa5);
      await busWrite(_domIso, 1);

      await busWriteSel(_ctrl, 0x0, 0x00);
      await busWriteSel(_wakeupEn, 0x0, 0x00);
      await busWriteSel(_domIso, 0x0, 0x00);

      expect(await busRead(_ctrl), equals(0x31));
      expect(await busRead(_wakeupEn), equals(0xa5));
      expect(await busRead(_domIso), equals(1));
      await Simulator.endSimulation();
    });
  });
}
