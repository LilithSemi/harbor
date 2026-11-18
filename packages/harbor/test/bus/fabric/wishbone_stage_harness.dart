import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'axi4_fabric_harness.dart' show exposeInterface;

/// Wires a [WishboneRegisterStage] between the master link [up] and the
/// fabric side link [down] inside [top]. [up] is driven by a master and
/// [down] is read by a fabric.
void linkStage(
  BridgeModule top,
  WishboneRegisterStage reg,
  WishboneInterface up,
  WishboneInterface down,
) {
  for (final e in up.getPorts([PairDirection.fromProvider]).entries) {
    reg.input('up_${e.key}').srcConnection! <= e.value;
  }
  for (final e in up.getPorts([PairDirection.fromConsumer]).entries) {
    e.value <= reg.output('up_${e.key}');
  }
  for (final e in down.getPorts([PairDirection.fromProvider]).entries) {
    e.value <= reg.output('down_${e.key}');
  }
  for (final e in down.getPorts([PairDirection.fromConsumer]).entries) {
    reg.input('down_${e.key}').srcConnection! <= e.value;
  }
}

/// Two masters `m0` and `m1`, each behind a register stage, on a Wishbone
/// fabric with the default grant cap, and one slave `s0` out on its ports.
/// The master ports are `m<i>_*` and the slave ports `s0_*`.
class StageFabricShell extends BridgeModule {
  late final HarborFabricModule fabric;

  StageFabricShell(HarborFabricTopology t, {int grantCap = 16})
    : super('StageFabricShell_${t.name}_g$grantCap', name: 'shell') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    const cfg = WishboneConfig(
      addressWidth: 32,
      dataWidth: 32,
      useErr: true,
      useCti: true,
      useBte: true,
    );
    final masters = <HarborFabricMaster>[];
    for (var i = 0; i < 2; i++) {
      final reg = WishboneRegisterStage(config: cfg, name: 'stage$i');
      addSubModule(reg);
      reg.input('clk').srcConnection! <= input('clk');
      reg.input('reset').srcConnection! <= input('reset');
      final up = WishboneInterface(cfg);
      exposeInterface(this, up, 'm$i', PairDirection.fromProvider);
      final down = WishboneInterface(cfg);
      linkStage(this, reg, up, down);
      masters.add(HarborFabricMaster(name: 'm$i', interface: down));
    }
    final s0 = WishboneInterface(cfg);
    exposeInterface(this, s0, 's0', PairDirection.fromConsumer);
    fabric = HarborFabric.build(
      kind: HarborFabricKind.wishbone,
      topology: t,
      clk: input('clk'),
      reset: input('reset'),
      masters: masters,
      slaves: [
        HarborFabricSlave(
          name: 's0',
          range: BusAddressRange(0, 0x10000),
          interface: s0,
        ),
      ],
      maxGrantCycles: grantCap,
    );
  }
}
