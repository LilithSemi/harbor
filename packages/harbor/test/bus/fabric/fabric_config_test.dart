import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'axi4_fabric_harness.dart';
import 'native_fabric_harness.dart' show NativeShell, PortCfg, portIntf;

Axi4Interface _axi({int id = 2, int addr = 20, int data = 32}) =>
    Axi4Interface(addressWidth: addr, dataWidth: data, idWidth: id);

Axi4LiteInterface _lite() => Axi4LiteInterface(addressWidth: 20, dataWidth: 32);

HarborFabricSlave _slave(
  String name,
  int start,
  int size, {
  int id = 2,
  int outstanding = 1,
  int timeout = 0,
  PairInterface? intf,
  bool? memory,
}) => HarborFabricSlave(
  name: name,
  range: BusAddressRange(start, size),
  interface: intf ?? _axi(id: id),
  outstanding: outstanding,
  timeout: timeout,
  memory: memory ?? intf is! Axi4LiteInterface,
);

List<String> _check(
  List<HarborFabricSlave> slaves, {
  HarborFabricKind kind = HarborFabricKind.axi4,
}) => HarborFabric.validateAddressMap(
  kind: kind,
  slaves: slaves,
  addressWidth: 20,
  dataWidth: 32,
);

HarborFabricModule _build({
  HarborFabricKind kind = HarborFabricKind.axi4,
  HarborFabricTopology topology = HarborFabricTopology.crossbar,
  List<HarborFabricMaster>? masters,
  List<HarborFabricSlave>? slaves,
}) => HarborFabric.build(
  kind: kind,
  topology: topology,
  clk: Logic(),
  reset: Logic(),
  masters:
      masters ??
      [
        HarborFabricMaster(name: 'm0', interface: _axi()),
        HarborFabricMaster(name: 'm1', interface: _axi(id: 3)),
      ],
  slaves:
      slaves ??
      [_slave('s0', 0, 0x10000), _slave('s1', 0x10000, 0x1000, id: 1)],
);

HarborFabricModule _native(
  HarborFabricKind kind, {
  HarborFabricTopology topology = HarborFabricTopology.crossbar,
  List<PortCfg> masters = const [PortCfg('m0')],
  List<PortCfg> slaves = const [PortCfg('s0', size: 0x1000)],
  Map<String, PairInterface> intf = const {},
  int? maxGrantCycles,
  int burstBeats = 8,
}) => HarborFabric.build(
  kind: kind,
  topology: topology,
  clk: Logic(),
  reset: Logic(),
  masters: [
    for (final m in masters)
      HarborFabricMaster(
        name: m.name,
        interface: intf[m.name] ?? portIntf(kind, m),
        outstanding: m.outstanding,
        memory: m.memory,
        reach: m.reach,
      ),
  ],
  slaves: [
    for (final s in slaves)
      HarborFabricSlave(
        name: s.name,
        range: s.range,
        interface: intf[s.name] ?? portIntf(kind, s),
        outstanding: s.outstanding,
        timeout: s.timeout,
        memory: s.memory,
      ),
  ],
  maxGrantCycles: maxGrantCycles,
  wishboneBurstBeats: burstBeats,
);

TileLinkInterface _tl({int size = 4, bool bce = false, int data = 32}) =>
    TileLinkInterface(
      TileLinkConfig(
        addressWidth: 20,
        dataWidth: data,
        sizeWidth: size,
        withBCE: bce,
      ),
    );

void main() {
  group('masters', () {
    test('the outstanding default follows the kind', () {
      final m = HarborFabricMaster(name: 'm0', interface: _axi());
      expect(m.outstandingOn(HarborFabricKind.wishbone), 1);
      expect(m.outstandingOn(HarborFabricKind.axi4), 4);
      expect(m.outstandingOn(HarborFabricKind.tilelink), 4);
      expect(_build(masters: [m]).definitionName, contains('o4'));
      // A Wishbone master with no limit set builds with 1.
      const wb = HarborFabricKind.wishbone;
      expect(
        () => HarborFabric.build(
          kind: wb,
          topology: HarborFabricTopology.shared,
          clk: Logic(),
          reset: Logic(),
          masters: [
            HarborFabricMaster(
              name: 'm0',
              interface: portIntf(wb, const PortCfg('m0')),
            ),
          ],
          slaves: [
            HarborFabricSlave(
              name: 's0',
              range: const BusAddressRange(0, 0x1000),
              interface: portIntf(wb, const PortCfg('s0')),
            ),
          ],
        ),
        returnsNormally,
      );
    });

    test('a reach set is checked and named', () {
      for (final k in HarborFabricKind.values) {
        String name(Set<String>? reach) => switch (k) {
          HarborFabricKind.axi4 => _build(
            masters: [
              HarborFabricMaster(name: 'm0', interface: _axi(), reach: reach),
            ],
          ).definitionName,
          _ => _native(
            k,
            masters: [PortCfg('m0', outstanding: 1, reach: reach)],
            slaves: const [
              PortCfg('s0', size: 0x1000),
              PortCfg('s1', base: 0x1000, size: 0x1000),
            ],
          ).definitionName,
        };
        final names = {
          name(null),
          name({'s0'}),
          name({'s1'}),
        };
        expect(names, hasLength(3), reason: k.name);
        expect(() => name({'nope'}), throwsArgumentError, reason: k.name);
      }
    });
  });

  test('a Wishbone crossbar slave one master reaches has no grant', () async {
    final f = _native(
      HarborFabricKind.wishbone,
      masters: const [
        PortCfg('m0', reach: {'s0', 's1'}),
        PortCfg('m1', reach: {'s1'}),
      ],
      slaves: const [
        PortCfg('s0', size: 0x1000),
        PortCfg('s1', base: 0x1000, size: 0x1000),
      ],
    );
    await f.build();
    final sv = f.generateSynth();
    expect(sv, isNot(contains('s0_held_grant')));
    expect(sv, contains('s1_held_grant'));
  });

  group('Wishbone decoder and arbiter names', () {
    const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
    final map = [
      HarborAddressMapping(
        range: const BusAddressRange(0, 0x1000),
        slaveIndex: 0,
      ),
    ];

    test('the decoder name follows config, timeout and map', () {
      final names = {
        WishboneDecoder(cfg, map).definitionName,
        WishboneDecoder(cfg.copyWith(useErr: true), map).definitionName,
        WishboneDecoder(cfg, map, timeoutCycles: 8).definitionName,
        WishboneDecoder(cfg, [
          HarborAddressMapping(
            range: const BusAddressRange(0x1000, 0x1000),
            slaveIndex: 0,
          ),
        ]).definitionName,
      };
      expect(names, hasLength(4));
      expect(
        WishboneDecoder(cfg, map).definitionName,
        WishboneDecoder(cfg, map).definitionName,
      );
    });

    test('the arbiter name follows config, arbitration and cap', () {
      WishboneArbiter arb({
        WishboneConfig c = cfg,
        BusArbitration a = BusArbitration.roundRobin,
        int? cap,
      }) => WishboneArbiter(
        numMasters: 2,
        config: c,
        arbitration: a,
        maxGrantCycles: cap,
      );
      final names = {
        arb().definitionName,
        arb(c: cfg.copyWith(useCti: true)).definitionName,
        arb(a: BusArbitration.fixed).definitionName,
        arb(cap: 4).definitionName,
      };
      expect(names, hasLength(4));
    });
  });

  group('address map', () {
    test('a good map passes', () {
      expect(
        _check([
          _slave('a', 0x0000, 0x3000),
          _slave('b', 0x4000, 0x1000),
          _slave('c', 0x5200, 0x100),
          _slave('d', 0x5000, 0x4),
        ]),
        isEmpty,
      );
    });

    test('overlap', () {
      expect(
        _check([_slave('a', 0x0000, 0x2000), _slave('b', 0x1000, 0x1000)]),
        [contains('overlap')],
      );
    });

    test('regions of 4 KB and up sit on 4 KB boundaries', () {
      expect(_check([_slave('a', 0x800, 0x1000)]), [contains('4 KB')]);
      expect(_check([_slave('a', 0x1000, 0x1800)]), [contains('4 KB')]);
    });

    test('smaller regions are aligned powers of two', () {
      expect(_check([_slave('a', 0x80, 0x100)]), [contains('power of two')]);
      expect(_check([_slave('a', 0x0, 0x300)]), [contains('power of two')]);
    });

    test('regions stay inside the address bits', () {
      expect(_check([_slave('a', 0xff000, 0x2000)]), [contains('outside')]);
    });

    test('empty regions', () {
      expect(_check([_slave('a', 0x1000, 0)]), [contains('empty')]);
    });

    test('Wishbone memory regions hold a burst block', () {
      final small = [_slave('a', 0x0, 0x10)];
      expect(_check(small), isEmpty);
      expect(_check(small, kind: HarborFabricKind.wishbone), [
        contains('burst block of 32 bytes'),
      ]);
      expect(
        _check([
          _slave('a', 0x0, 0x10, memory: false),
        ], kind: HarborFabricKind.wishbone),
        isEmpty,
      );
    });
  });

  group('build', () {
    test('rejects a bad map', () {
      expect(
        () => _build(
          slaves: [_slave('a', 0, 0x2000), _slave('b', 0x1000, 0x1000)],
        ),
        throwsArgumentError,
      );
    });

    test('rejects other interfaces, widths and repeated names', () {
      expect(
        () => _build(
          slaves: [
            _slave(
              'a',
              0,
              0x1000,
              intf: WishboneInterface(
                const WishboneConfig(addressWidth: 20, dataWidth: 32),
              ),
            ),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => _build(slaves: [_slave('a', 0, 0x1000, intf: _axi(data: 64))]),
        throwsArgumentError,
      );
      expect(
        () => _build(slaves: [_slave('m0', 0, 0x1000)]),
        throwsArgumentError,
      );
      expect(
        () => _build(slaves: [_slave('a', 0, 0x1000, outstanding: 0)]),
        throwsArgumentError,
      );
    });

    test('AXI4 port classes and Lite limits', () {
      expect(
        () => _build(slaves: [_slave('a', 0, 0x1000, memory: false)]),
        throwsArgumentError,
      );
      expect(
        () => _build(
          slaves: [_slave('a', 0, 0x1000, intf: _lite(), outstanding: 2)],
        ),
        throwsArgumentError,
      );
      expect(
        () => HarborFabric.build(
          kind: HarborFabricKind.axi4,
          topology: HarborFabricTopology.shared,
          clk: Logic(),
          reset: Logic(),
          masters: [HarborFabricMaster(name: 'm0', interface: _axi())],
          slaves: [_slave('a', 0, 0x1000)],
          maxGrantCycles: 4,
        ),
        throwsArgumentError,
      );
    });

    test('the definition name follows every parameter', () {
      String name({
        HarborFabricTopology topology = HarborFabricTopology.crossbar,
        int mOut = 4,
        int mId = 2,
        int sOut = 1,
        int sId = 2,
        int timeout = 0,
        int start = 0,
        int size = 0x10000,
        bool mLite = false,
        bool sLite = false,
      }) => _build(
        topology: topology,
        masters: [
          HarborFabricMaster(
            name: 'm0',
            interface: mLite ? _lite() : _axi(id: mId),
            outstanding: mOut,
            memory: !mLite,
          ),
        ],
        slaves: [
          _slave(
            's0',
            start,
            size,
            id: sId,
            outstanding: sOut,
            timeout: timeout,
            intf: sLite ? _lite() : null,
          ),
        ],
      ).definitionName;
      final base = name();
      expect(name(), base);
      final others = [
        name(topology: HarborFabricTopology.shared),
        name(mOut: 2),
        name(mId: 3),
        name(sOut: 4),
        name(sId: 1),
        name(timeout: 100),
        name(start: 0x10000),
        name(size: 0x20000),
        name(mLite: true),
        name(sLite: true),
      ];
      expect({base, ...others}, hasLength(others.length + 1));
    });
  });

  group('TileLink', () {
    const tl = HarborFabricKind.tilelink;
    test('rejects other interfaces, BCE, wide sizes and other widths', () {
      for (final i in [_axi(), _tl(bce: true), _tl(size: 6), _tl(data: 64)]) {
        expect(() => _native(tl, intf: {'s0': i}), throwsArgumentError);
      }
      expect(() => _native(tl), returnsNormally);
    });

    test('the definition name follows every parameter', () {
      String name({
        HarborFabricTopology topology = HarborFabricTopology.crossbar,
        PortCfg m = const PortCfg('m0', width: 2, outstanding: 4),
        PortCfg s = const PortCfg('s0', width: 2, outstanding: 2, size: 0x1000),
      }) => _native(
        tl,
        topology: topology,
        masters: [m],
        slaves: [s],
      ).definitionName;
      final base = name();
      expect(name(), base);
      final others = [
        name(topology: HarborFabricTopology.shared),
        name(m: const PortCfg('m0', width: 3, outstanding: 4)),
        name(m: const PortCfg('m0', width: 2, outstanding: 2)),
        name(m: const PortCfg('m0', width: 2, outstanding: 4, memory: false)),
        name(s: const PortCfg('s0', width: 1, outstanding: 2, size: 0x1000)),
        name(s: const PortCfg('s0', width: 2, outstanding: 3, size: 0x1000)),
        name(
          s: const PortCfg(
            's0',
            width: 2,
            outstanding: 2,
            size: 0x1000,
            memory: false,
          ),
        ),
        name(
          s: const PortCfg(
            's0',
            width: 2,
            outstanding: 2,
            size: 0x1000,
            timeout: 9,
          ),
        ),
        name(
          s: const PortCfg(
            's0',
            width: 2,
            outstanding: 2,
            base: 0x1000,
            size: 0x1000,
          ),
        ),
      ];
      expect({base, ...others}, hasLength(others.length + 1));
      expect(
        base,
        isNot(
          _native(
            HarborFabricKind.wishbone,
            masters: const [PortCfg('m0')],
            slaves: const [PortCfg('s0', size: 0x1000)],
          ).definitionName,
        ),
      );
    });
  });

  group('Wishbone', () {
    const wb = HarborFabricKind.wishbone;
    test('rejects bad ports and settings', () {
      final rty = WishboneInterface(
        const WishboneConfig(addressWidth: 20, dataWidth: 32, useRty: true),
      );
      final classic = WishboneInterface(
        const WishboneConfig(addressWidth: 20, dataWidth: 32, useErr: true),
      );
      expect(() => _native(wb, intf: {'s0': rty}), throwsArgumentError);
      expect(() => _native(wb, intf: {'s0': classic}), throwsArgumentError);
      expect(() => _native(wb, intf: {'s0': _axi()}), throwsArgumentError);
      expect(
        () => _native(wb, slaves: const [PortCfg('s0', outstanding: 2)]),
        throwsArgumentError,
      );
      expect(
        () => _native(wb, masters: const [PortCfg('m0', outstanding: 2)]),
        throwsArgumentError,
      );
      expect(() => _native(wb, maxGrantCycles: 0), throwsArgumentError);
      expect(() => _native(wb), returnsNormally);
    });

    test('a memory slave region holds a burst block', () {
      expect(
        () => _native(wb, slaves: const [PortCfg('s0', size: 0x10)]),
        throwsArgumentError,
      );
      expect(
        () => _native(
          wb,
          slaves: const [PortCfg('s0', size: 0x10, memory: false)],
        ),
        returnsNormally,
      );
      expect(
        () => _native(
          wb,
          slaves: const [PortCfg('s0', size: 0x20)],
          burstBeats: 16,
        ),
        throwsArgumentError,
      );
    });

    test('the definition name follows every parameter', () {
      String name({
        HarborFabricTopology topology = HarborFabricTopology.crossbar,
        PortCfg m = const PortCfg('m0'),
        PortCfg s = const PortCfg('s0', size: 0x1000),
        int? cap,
        int beats = 8,
      }) => _native(
        wb,
        topology: topology,
        masters: [m],
        slaves: [s],
        maxGrantCycles: cap,
        burstBeats: beats,
      ).definitionName;
      final base = name();
      expect(name(), base);
      final others = [
        name(topology: HarborFabricTopology.shared),
        name(m: const PortCfg('m0', memory: false)),
        name(m: const PortCfg('m0', memory: false, err: false)),
        name(s: const PortCfg('s0', size: 0x1000, memory: false)),
        name(s: const PortCfg('s0', size: 0x1000, timeout: 5)),
        name(s: const PortCfg('s0', base: 0x1000, size: 0x1000)),
        name(s: const PortCfg('s0', size: 0x2000)),
        name(cap: 4),
        name(beats: 4),
      ];
      expect({base, ...others}, hasLength(others.length + 1));
    });
  });

  for (final k in [HarborFabricKind.tilelink, HarborFabricKind.wishbone]) {
    for (final t in HarborFabricTopology.values) {
      test(
        '${k.name} ${t.name} fabric emits SystemVerilog',
        () => isolated(() async {
          final tl = k == HarborFabricKind.tilelink;
          final shell = NativeShell(
            k,
            t,
            masters: [
              PortCfg('m0', width: 2, outstanding: tl ? 4 : 1),
              PortCfg('m1', width: 1, memory: false, err: false),
            ],
            slaves: const [
              PortCfg('s0', width: 3, base: 0x0000, size: 0x1000, timeout: 9),
              PortCfg('s1', base: 0x1000, size: 0x100, memory: false),
            ],
          );
          await shell.build();
          final sv = shell.generateSynth();
          must(
            sv,
            contains(
              tl
                  ? 'module HarborTileLinkFabric'
                  : 'module HarborWishboneFabric',
            ),
          );
        }),
      );
    }
  }

  for (final t in HarborFabricTopology.values) {
    test(
      '${t.name} fabric emits SystemVerilog',
      () => isolated(() async {
        final shell = FabricShell(
          t,
          slaves: const [
            SlaveCfg('s0', 5, 8, 0x00000, 0x10000),
            SlaveCfg('s1', 1, 2, 0x10000, 0x10000, timeout: 100),
            SlaveCfg('s2', 3, 4, 0x20000, 0x8000),
            SlaveCfg('s3', 0, 1, 0x30000, 0x1000, timeout: 50, lite: true),
          ],
          masters: const [...masters3, MasterCfg('m3', 1, 2, lite: true)],
        );
        await shell.build();
        final sv = shell.generateSynth();
        must(sv, contains('module HarborAxi4Fabric'));
      }),
    );
  }
}
