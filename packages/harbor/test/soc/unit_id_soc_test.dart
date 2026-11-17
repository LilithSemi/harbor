import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

/// A Wishbone master with its port pins on plain ports.
class _Core extends BridgeModule {
  _Core() : super('UnitIdSocCore', name: 'core') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final i = addInterface(
      WishboneInterface(
        const WishboneConfig(addressWidth: 32, dataWidth: 32, useErr: true),
      ),
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

void main() {
  tearDown(Simulator.reset);

  const target = HarborFpgaTarget.artix7(
    device: 'xc7a100t',
    package: 'csg324',
    frequency: 100000000,
    useOpenXc7: true,
  );

  Future<HarborSoC> buildSoc() async {
    final soc = HarborSoC(
      name: 'UnitIdSoc',
      compatible: 'test,unit-id',
      target: target,
    );
    soc.addMaster(_Core()).pullUp(soc);
    final unit = HarborUnitId.fromTarget(
      baseAddress: 0x10005000,
      target: target,
      busClockHz: target.frequency,
      busAddressWidth: 32,
    )!;
    soc.addPeripheral(unit);
    soc.buildFabric();
    await soc.build();
    return soc;
  }

  test('the block joins the fabric and holds the DNA_PORT primitive', () async {
    final soc = await buildSoc();
    final sv = soc.dumpSystemVerilog();
    expect(sv, contains(RegExp(r'DNA_PORT\s+#')));
    expect(sv, contains(RegExp(r'\.SIM_DNA_VALUE\(57.h0\)')));
    expect(sv, contains('HarborUnitId_'));
    expect(soc.peripherals.whereType<HarborUnitId>().single.bus.addr.width, 32);
  });

  test('the device tree and the SVD list the block', () async {
    final soc = await buildSoc();
    final dts = soc.generateDts();
    expect(dts, contains('harbor,unit-id'));
    expect(dts, contains('unit-id@10005000'));
    expect(dts, contains('harbor,id-source = "dna57";'));
    final svd = soc.generateSvd();
    expect(svd, contains('<name>UNIT_ID</name>'));
    expect(svd, contains('<baseAddress>0x10005000</baseAddress>'));
    for (final reg in ['id_lo', 'id_hi', 'info']) {
      expect(svd, contains('<name>$reg</name>'));
    }
  });

  test('a master reads INFO through the interconnect', () async {
    final soc = await buildSoc();
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset')..inject(1);
    final bus = RegBus.attach(
      soc,
      clk,
      name: 'cpu',
      kind: HarborFabricKind.wishbone,
    );
    soc.input('clk').srcConnection! <= clk;
    soc.input('reset').srcConnection! <= reset;
    bus.idle();
    Simulator.setMaxSimTime(1000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);

    expect(await bus.read(0x10005010) & 1, 0, reason: 'valid is low early');
    for (var i = 0; i < 70 * 4; i++) {
      await clk.nextPosedge;
    }
    final info = await bus.read(0x10005010);
    expect(info & 1, 1);
    expect((info >> 4) & 0xf, 1);
    expect((info >> 8) & 0xff, 57);
    await Simulator.endSimulation();
  });
}
