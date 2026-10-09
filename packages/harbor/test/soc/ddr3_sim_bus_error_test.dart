import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

class _Probe extends BridgeModule {
  _Probe(WishboneConfig cfg) : super('Probe', name: 'probe') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final bus =
        addInterface(
              WishboneInterface(cfg),
              name: 'bus',
              role: PairRole.provider,
            ).internalInterface
            as WishboneInterface;
    bus.cyc <= Const(0);
    bus.stb <= Const(0);
    bus.we <= Const(0);
    bus.adr <= Const(0, width: 32);
    bus.datMosi <= Const(0, width: 32);
    bus.sel <= Const(0xF, width: 4);
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  for (final external in [false, true]) {
    test('a sim target HarborDdr3 gives bus_error '
        '(external memory $external)', () async {
      const target = HarborSimTarget(topCell: 'soc');
      final soc = HarborSoC(
        name: 'DdrSimSoc',
        compatible: 'test,ddr-sim',
        busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
        target: target,
      );
      soc.addMaster(
        _Probe(const WishboneConfig(addressWidth: 32, dataWidth: 32)),
        busInterfaceName: 'bus',
      );
      final ddr = HarborDdr3(
        config: const HarborDdrConfig.orangeCrab(),
        baseAddress: 0x40000000,
        clockHz: 48000000,
        target: target,
        busAddressWidth: 32,
        simExternalMem: external,
      );
      soc.addPeripheral(ddr);
      soc.buildFabric();
      expect(soc.exposeBusError, returnsNormally);
      expect(ddr.busError.width, 1);
    });
  }
}
