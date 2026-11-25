// A fabric with no real-time master has the same SystemVerilog whatever the
// burst cap is, and none of the real-time logic is in it. The golden hashes
// are of the SV that the tree before real-time QoS built for the same
// configurations: commit 655ca67 for the fabric shells with the grant cap
// off, and commit 122c86f for the SoCs, which have the default grant cap.
// The Wishbone SoC hash moved when the grant cap learned to take the grant
// from an idle owner, which is not a real-time change. All hashes moved
// when the fabric started to count the slaves that a bus timeout cut off,
// which is not a real-time change.

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import 'axi4_fabric_harness.dart';
import 'native_fabric_harness.dart';

String _sv(Module m) => [
  for (final f in SynthBuilder(
    m,
    SystemVerilogSynthesizer(),
  ).getSynthFileContents())
    f.contents,
].join('\n');

Future<String> _build(
  HarborFabricKind kind,
  HarborFabricTopology t, {
  required int cap,
  required bool realtime,
}) async {
  final BridgeModule shell;
  switch (kind) {
    case HarborFabricKind.axi4:
      shell = FabricShell(
        t,
        masters: [
          MasterCfg('m0', 2, 4, realtime: realtime),
          const MasterCfg('m1', 3, 8),
        ],
        slaves: slaves3,
        realtimeBurstCap: cap,
      );
    case HarborFabricKind.tilelink:
      shell = NativeShell(
        kind,
        t,
        masters: [
          PortCfg('m0', width: 2, outstanding: 4, realtime: realtime),
          const PortCfg('m1', width: 3, outstanding: 6),
        ],
        slaves: tlSlaves,
        realtimeBurstCap: cap,
      );
    case HarborFabricKind.wishbone:
      shell = NativeShell(
        kind,
        t,
        masters: [
          PortCfg('m0', realtime: realtime),
          const PortCfg('m1'),
        ],
        slaves: wbSlaves,
        realtimeBurstCap: cap,
      );
  }
  await shell.build();
  return _sv(shell);
}

// FNV-1a over the code units of the SV, and its length.
(int, int) _hash(String s) {
  var h = 0xcbf29ce484222325;
  for (final c in s.codeUnits) {
    h = (h ^ c) * 0x100000001b3;
  }
  return (h, s.length);
}

const _sram = 0x80000000;
const _dma = 0x30000000;

/// A register master whose native port pins are plain `p_<PORT>` ports.
class _Cpu extends BridgeModule {
  _Cpu(HarborFabricKind kind)
    : super('MasterSocCpu_${kind.name}', name: 'cpu') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final PairInterface intf = switch (kind) {
      HarborFabricKind.wishbone => WishboneInterface(
        const WishboneConfig(addressWidth: 32, dataWidth: 32, useErr: true),
      ),
      HarborFabricKind.axi4 => Axi4LiteInterface(
        addressWidth: 32,
        dataWidth: 32,
      ),
      HarborFabricKind.tilelink => TileLinkInterface(
        const TileLinkConfig(addressWidth: 32, dataWidth: 32),
      ),
    };
    final i = addInterface(
      intf,
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

Future<String> _soc(
  HarborFabricKind kind, {
  HarborFabricPipeline axi4Pipeline = HarborFabricPipeline.balanced,
}) async {
  final soc = HarborSoC(
    name: 'masters_${kind.name}',
    compatible: 'test,masters',
    fabricKind: kind,
    target: const HarborSimTarget(frequency: 50000000),
  );
  final cpu = soc.addMaster(_Cpu(kind));
  final dma = HarborDmaController(
    baseAddress: _dma,
    channels: 1,
    busAddressWidth: 32,
    fabricKind: kind,
  );
  soc.addPeripheral(dma);
  soc.addMaster(dma, busInterfaceName: 'dma', memory: true, outstanding: 1);
  soc.addPeripheral(
    HarborSram(
      baseAddress: _sram,
      size: 4096,
      busAddressWidth: 32,
      protocol: kind,
    ),
  );
  cpu.pullUp(soc);
  soc.buildFabric(axi4Pipeline: axi4Pipeline);
  soc.input('clk').srcConnection! <= Logic(name: 'clk');
  soc.input('reset').srcConnection! <= Logic(name: 'reset');
  await soc.build();
  return _sv(soc);
}

void main() {
  const golden = <String, (int, int)>{
    'axi4_crossbar': (-1806727016848880604, 725461),
    'axi4_shared': (-4758848597611908600, 703895),
    'axi4_balanced_crossbar': (173297470315991894, 1043312),
    'axi4_balanced_shared': (-3919233163272566078, 993695),
    'axi4_fast_crossbar': (-177625609682684969, 1043312),
    'axi4_fast_shared': (-8551066521692636977, 993695),
    'soc_axi4': (-2031679295772626019, 763298),
    'soc_axi4_compact': (-394717168575693814, 718079),
    'soc_tilelink': (3980852489748109613, 671753),
    'soc_wishbone': (2951180329469432230, 536162),
    'tl_crossbar': (-5608642720268730264, 149685),
    'tl_shared': (171527483369796812, 308006),
    'wb_crossbar': (-3765011429854336056, 33613),
    'wb_shared': (-1007195441028053844, 33574),
  };
  for (final t in HarborFabricTopology.values) {
    for (final p in HarborFabricPipeline.values) {
      test('axi4 ${p.name} ${t.name}: SV equals its golden', () async {
        final shell = FabricShell(t, pipeline: p);
        await shell.build();
        final key = p == HarborFabricPipeline.compact
            ? 'axi4_${t.name}'
            : 'axi4_${p.name}_${t.name}';
        expect(_hash(_sv(shell)), golden[key]);
      });
    }
    test('wishbone ${t.name}: SV equals the SV before real-time QoS', () async {
      final shell = NativeShell(
        HarborFabricKind.wishbone,
        t,
        masters: wbMasters,
        slaves: wbSlaves,
      );
      await shell.build();
      expect(_hash(_sv(shell)), golden['wb_${t.name}']);
    });
    test('tilelink ${t.name}: SV equals the SV before real-time QoS', () async {
      final shell = NativeShell(
        HarborFabricKind.tilelink,
        t,
        masters: tlMasters,
        slaves: tlSlaves,
      );
      await shell.build();
      expect(_hash(_sv(shell)), golden['tl_${t.name}']);
    });
  }
  test('axi4 SoC at compact: SV equals the SV before the levels', () async {
    expect(
      _hash(
        await _soc(
          HarborFabricKind.axi4,
          axi4Pipeline: HarborFabricPipeline.compact,
        ),
      ),
      golden['soc_axi4_compact'],
    );
  });
  for (final kind in HarborFabricKind.values) {
    test('${kind.name} SoC: SV equals the SV before real-time QoS', () async {
      expect(_hash(await _soc(kind)), golden['soc_${kind.name}']);
    });
  }

  for (final kind in HarborFabricKind.values) {
    for (final t in HarborFabricTopology.values) {
      test(
        '${kind.name} ${t.name}: no real-time master, same SV for any cap',
        () async {
          final a = await _build(kind, t, cap: 16, realtime: false);
          final b = await _build(kind, t, cap: 3, realtime: false);
          expect(a, b);
          expect(a, isNot(contains('rt_')));
          expect(a, isNot(contains('_split_')));
        },
      );
    }
    test('${kind.name}: a real-time master adds logic', () async {
      final a = await _build(
        kind,
        HarborFabricTopology.shared,
        cap: 4,
        realtime: false,
      );
      final b = await _build(
        kind,
        HarborFabricTopology.shared,
        cap: 4,
        realtime: true,
      );
      expect(b, isNot(a));
    });
  }

  test(
    'the bound needs writeStallFree on every master that is not real-time',
    () {
      final intf = WishboneInterface(
        const WishboneConfig(addressWidth: 32, dataWidth: 32),
      );
      HarborFabricMaster m(String n, {bool rt = false, bool free = false}) =>
          HarborFabricMaster(
            name: n,
            interface: intf,
            realtime: rt,
            writeStallFree: free,
          );
      int bound(List<HarborFabricMaster> ms, {bool allow = false}) =>
          HarborFabric.realtimeWaitBound(
            kind: HarborFabricKind.wishbone,
            masters: ms,
            cap: 8,
            allowUnproven: allow,
          );
      expect(() => bound([m('rt', rt: true), m('a')]), throwsArgumentError);
      expect(bound([m('rt', rt: true), m('a')], allow: true), greaterThan(0));
      expect(bound([m('rt', rt: true), m('a', free: true)]), greaterThan(0));
    },
  );
}
