// Regression for a HarborSoC fabric that mixes two WishboneRegisterStage
// shapes: buildFabric(pipeline: true) puts a stage in front of every master,
// and the stage of a master with ERR differs from the stage of a master
// without it. Both must get their own definitionName, or ROHD refuses the
// second as a reserved-name clash.

import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

/// Minimal Wishbone master: a provider 'bus' interface tied idle.
class _IdleMaster extends BridgeModule {
  _IdleMaster(WishboneConfig cfg, {String? name})
    : super(
        cfg.useErr ? 'DefnameIdleMasterErr' : 'DefnameIdleMaster',
        name: name ?? 'idle_master',
      ) {
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
    bus.adr <= Const(0, width: cfg.addressWidth);
    bus.datMosi <= Const(0, width: cfg.dataWidth);
    bus.sel <= Const(0, width: cfg.effectiveSelWidth);
    if (bus.err != null) bus.err!.put(0);
    if (bus.rty != null) bus.rty!.put(0);
  }
}

void main() {
  test('a plain-config fabric stage and a DMA upConfig stage coexist in one '
      'generateAll (no reserved-name clash)', () async {
    const wbConfig = WishboneConfig(addressWidth: 32, dataWidth: 32);
    // Stands in for an SDIO dma=true master: same address/data/sel width
    // as the fabric (required), but its own bus adds ERR, which the fabric
    // config above does not have.
    const dmaMasterConfig = WishboneConfig(
      addressWidth: 32,
      dataWidth: 32,
      useErr: true,
    );

    final soc = HarborSoC(
      name: 'DefnameRepro',
      compatible: 'test,defname-repro',
    );

    soc.addMaster(_IdleMaster(wbConfig, name: 'cpu'), busInterfaceName: 'bus');
    soc.addMaster(
      _IdleMaster(dmaMasterConfig, name: 'dma'),
      busInterfaceName: 'bus',
      pipeline: true,
    );
    soc.addPeripheral(
      HarborSram(baseAddress: 0, size: 4096, busAddressWidth: 32),
    );

    // A stage per master: the plain one of the cpu differs from the ERR
    // one of the dma master.
    soc.buildFabric(pipeline: true);

    final dir = Directory.systemTemp.createTempSync('harbor_defname_');
    addTearDown(() => dir.deleteSync(recursive: true));
    await soc.generateAll(dir);

    final rtlDir = Directory('${dir.path}/rtl');
    expect(rtlDir.existsSync(), isTrue);
    final names = rtlDir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.startsWith('WishboneRegisterStage'))
        .toList();
    // Two structurally-different stages must land in two distinct files.
    expect(names.toSet(), hasLength(2));
  });
}
