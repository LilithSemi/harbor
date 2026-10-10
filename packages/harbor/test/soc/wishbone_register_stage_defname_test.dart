// Regression for a HarborSoC fabric that mixes two WishboneRegisterStage
// shapes: buildFabric(pipeline: true) puts a plain config==wbConfig stage
// in front of the decoder, and a pipelined master whose own bus config
// differs from wbConfig (e.g. a DMA master with ERR) gets a second stage
// built with upConfig != config. Before both stages carried the same fixed
// definitionName, ROHD's uniquifier refused the second as a reserved-name
// clash. This must pass only once WishboneRegisterStage.definitionName
// encodes the up/down config.

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
  test(
    'a plain-config fabric stage and a DMA upConfig stage coexist in one '
    'generateAll (no reserved-name clash)',
    () async {
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
        busConfig: wbConfig,
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

      // Decoder-side pipeline stage: plain config == wbConfig, structurally
      // different from the DMA master's upConfig stage above.
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
    },
  );
}
