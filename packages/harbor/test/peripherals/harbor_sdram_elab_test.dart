import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Elaboration checks for [HarborSdram]: the ecp5 build has the sdr sdram
/// phy cell counts and no Xilinx cell, the device tree node matches its
/// properties, the sim target builds `harbor_sim_dram` with no sdram_*
/// pads, and the target and clock guards throw.
void main() {
  tearDown(() async => Simulator.reset());

  const config = HarborSdramConfig.as4c16m16sb6();
  const ecp5Target = HarborFpgaTarget.ecp5(
    device: 'LFE5U-85F',
    package: 'CABGA381',
  );

  int count(String sv, String cell) =>
      RegExp('\\b$cell\\b').allMatches(sv).length;

  test('ecp5 target: full stack, phy cell counts, no xilinx cell', () async {
    final sdram = HarborSdram(
      config: config,
      baseAddress: 0x40000000,
      clockHz: 125000000,
      target: ecp5Target,
    );
    await sdram.build();
    final sv = sdram.generateSynth();

    expect(sv, contains('module HarborSdram'));
    expect(count(sv, 'OFS1P3BX'), equals(53));
    expect(count(sv, 'OFS1P3DX'), equals(1));
    expect(count(sv, 'IFS1P3BX'), equals(16));
    expect(count(sv, 'ODDRX1F'), equals(1));
    expect(count(sv, 'BB'), equals(16));
    expect(count(sv, 'IDDRX1F'), equals(0));

    for (final cell in [
      'OSERDESE2',
      'ISERDESE2',
      'IDELAYE2',
      'ODELAYE2',
      'IDELAYCTRL',
      'IOBUF',
      'IOBUFDS',
      'OBUF',
      'OBUFDS',
    ]) {
      expect(count(sv, cell), 0, reason: '$cell (xilinx) leaked in');
    }

    // Port names and widths.
    expect(sdram.output('sdram_clk').width, equals(1));
    expect(sdram.output('sdram_cke').width, equals(1));
    expect(sdram.output('sdram_cs_n').width, equals(1));
    expect(sdram.output('sdram_ras_n').width, equals(1));
    expect(sdram.output('sdram_cas_n').width, equals(1));
    expect(sdram.output('sdram_we_n').width, equals(1));
    expect(sdram.output('sdram_ba').width, equals(2));
    expect(sdram.output('sdram_addr').width, equals(13));
    expect(sdram.output('sdram_dqm').width, equals(2));
    expect(sdram.inOut('sdram_dq').width, equals(16));
    expect(sdram.output('init_done').width, equals(1));
    expect(sdram.output('bus_error').width, equals(1));
    expect(sdram.busError, equals(sdram.output('bus_error')));
  });

  test('device tree node fields', () async {
    final sdram = HarborSdram(
      config: config,
      baseAddress: 0x40000000,
      clockHz: 125000000,
      target: ecp5Target,
    );
    await sdram.build();

    final node = sdram.dtNode;
    expect(
      node.compatible,
      equals(['harbor,sdram-controller', 'harbor,sdr-sdram']),
    );
    expect(node.reg.start, equals(0x40000000));
    expect(node.reg.size, equals(config.sizeBytes));
    expect(node.properties['sdram-type'], equals('sdr'));
    expect(node.properties['data-width'], equals(16));
    expect(node.properties['clock-frequency'], equals(125000000));
    expect(node.properties['harbor,sdram-part'], equals(config.part));
    expect(node.properties['harbor,sdram-cas-latency'], equals(3));
    expect(node.properties['harbor,sdram-banks'], equals(4));
    expect(node.properties['harbor,sdram-rows'], equals(13));
    expect(node.properties['harbor,sdram-cols'], equals(9));
    expect(node.properties['harbor,sdram-address-map'], equals('row-bank-col'));

    expect(
      sdram.systemMemory,
      equals([BusAddressRange(0x40000000, config.sizeBytes)]),
    );
    expect(sdram.svdPeripheral.name, equals('SDRAM'));
    expect(sdram.svdPeripheral.baseAddress, equals(0x40000000));
    expect(sdram.acpiDevice.properties['sdram-type'], equals('sdr'));
  });

  test('HarborSimTarget: harbor_sim_dram with no sdram_* ports', () async {
    final sdram = HarborSdram(
      config: config,
      baseAddress: 0,
      clockHz: 125000000,
      target: const HarborSimTarget(topCell: 'top', frequency: 50000000),
    );
    await sdram.build();
    final sv = sdram.generateSynth();

    expect(sv, contains('harbor_sim_dram'));
    final dramLine = sv.split('\n').firstWhere((l) => l.contains('sim_dram('));
    expect(
      RegExp(r'\.\w+\(\)').allMatches(dramLine).map((m) => m.group(0)),
      isEmpty,
      reason: 'empty port(s) in: $dramLine',
    );
    expect(() => sdram.output('sdram_clk'), throwsA(anything));
    expect(() => sdram.inOut('sdram_dq'), throwsA(anything));
    expect(() => sdram.output('init_done'), throwsA(anything));
    expect(sdram.busError.width, equals(1));
    expect(sdram.inputs.keys, isNot(contains('mem_clk')));
    expect(sdram.inputs.keys, isNot(contains('mem_reset')));
  });

  test('busClockSync keeps mem_reset and drops mem_clk', () async {
    final sdram = HarborSdram(
      config: config,
      baseAddress: 0,
      clockHz: 125000000,
      target: ecp5Target,
      busClockSync: true,
    );
    await sdram.build();
    expect(sdram.inputs.keys, contains('mem_reset'));
    expect(sdram.inputs.keys, isNot(contains('mem_clk')));
    expect(sdram.busError.width, equals(1));
  });

  Iterable<Module> tree(Module m) sync* {
    yield m;
    for (final c in m.subModules) {
      yield* tree(c);
    }
  }

  for (final kind in [HarborFabricKind.axi4, HarborFabricKind.tilelink]) {
    test(
      '${kind.name}: a memory slave port crossed by the port layer',
      () async {
        final sdram = HarborSdram(
          config: config,
          baseAddress: 0,
          clockHz: 125000000,
          target: ecp5Target,
          protocol: kind,
          idWidth: 3,
        );
        await sdram.build();
        final q = harborCdcDepth(8);
        expect(sdram.outstanding, 8);
        expect(sdram.cdcDepth, q);
        expect(sdram.bus!.cdcDepth, q);
        final mods = tree(sdram).toList();
        final defs = mods.map((m) => m.definitionName).toList();
        final cdc = mods.singleWhere(
          (m) => m.definitionName.startsWith('HarborMemoryWaistCdcSlave'),
        );
        expect(cdc.definitionName, endsWith('_r'));
        // Per channel: a device reset copy and its early flop. Per device
        // valid or ready output: one enable copy.
        final copies = [
          for (final c in cdc.subModules.whereType<Ecp5Fd1s3bx>()) c.name,
        ];
        expect(copies, hasLength(12));
        for (final ch in ['req', 'wdata', 'rdata', 'wresp']) {
          expect(copies, contains('${ch}_device_reset'));
          expect(copies, contains('${ch}_device_reset_early'));
        }
        for (final o in [
          'req_valid',
          'wdata_valid',
          'rdata_ready',
          'wresp_ready',
        ]) {
          expect(copies, contains('d_${o}_r_n'));
        }
        expect(defs.where((d) => d.contains('CdcFifoBridge')), isEmpty);
        expect(
          defs.where((d) => d.startsWith('SdramMemoryPort')),
          hasLength(1),
        );
        expect(
          sdram.definitionName,
          startsWith('HarborSdram_ecp5_${kind.name}_i3_n8_q$q'),
        );
      },
    );
  }

  test('wishbone: the cdc bridge and SdramWishbonePort, no waist', () async {
    for (final posted in [false, true]) {
      final sdram = HarborSdram(
        config: config,
        baseAddress: 0,
        clockHz: 125000000,
        target: ecp5Target,
        postedWrites: posted,
      );
      await sdram.build();
      final q = posted ? 8 : 2;
      expect(sdram.outstanding, 1);
      expect(sdram.cdcDepth, q);
      expect(sdram.bus, isNull);
      final defs = tree(sdram).map((m) => m.definitionName).toList();
      expect(defs.where((d) => d.contains('Waist')), isEmpty);
      expect(defs.where((d) => d.contains('MemorySlave')), isEmpty);
      expect(defs.where((d) => d.startsWith('SdramMemoryPort')), isEmpty);
      expect(defs.where((d) => d == 'SdramWishbonePort'), hasLength(1));
      expect(
        defs.where((d) => d.startsWith('HarborWishboneCdcFifoBridge')),
        hasLength(1),
      );
      expect(
        sdram.definitionName,
        startsWith('HarborSdram_ecp5_wishbone_i1_n1_q$q'),
      );
      // The port a Wishbone fabric expects of a memory slave.
      for (final p in ['bus_CTI', 'bus_BTE']) {
        expect(sdram.inputs.keys, contains(p));
      }
      expect(sdram.outputs.keys, contains('bus_ERR'));
      await Simulator.reset();
    }
  });

  test('wishbone sim build: harbor_sim_dram on the bus', () async {
    final sdram = HarborSdram(
      config: config,
      baseAddress: 0,
      clockHz: 125000000,
      target: const HarborSimTarget(topCell: 'top', frequency: 50000000),
    );
    await sdram.build();
    final defs = tree(sdram).map((m) => m.definitionName).toList();
    expect(defs.where((d) => d.contains('Beats')), isEmpty);
    expect(defs.where((d) => d.contains('MemorySlave')), isEmpty);
  });

  test('sim and busClockSync builds do not cross', () async {
    for (final sdram in [
      HarborSdram(
        config: config,
        baseAddress: 0,
        clockHz: 125000000,
        target: const HarborSimTarget(topCell: 'top', frequency: 50000000),
        protocol: HarborFabricKind.axi4,
      ),
      HarborSdram(
        config: config,
        baseAddress: 0,
        clockHz: 125000000,
        target: ecp5Target,
        busClockSync: true,
      ),
    ]) {
      await sdram.build();
      expect(sdram.cdcDepth, 0);
      expect(
        tree(
          sdram,
        ).where((m) => m.definitionName.startsWith('HarborMemoryWaistCdc')),
        isEmpty,
      );
      expect(sdram.definitionName, contains('_q0'));
      await Simulator.reset();
    }
  });

  test('every body parameter changes the definition name', () {
    HarborSdram make({
      HarborFabricKind protocol = HarborFabricKind.axi4,
      bool posted = false,
      int id = 1,
      int? n,
      int? q,
      int beats = 8,
      int aw = 26,
      int hz = 125000000,
      bool sync = false,
      int scan = 0,
      int inFlight = 3,
      int post = 8,
      int pull = 8,
      HarborSdramPhyConfig phy = const HarborSdramPhyConfig(),
      HarborSdramConfig cfg = config,
    }) => HarborSdram(
      config: cfg,
      baseAddress: 0,
      clockHz: hz,
      target: ecp5Target,
      protocol: protocol,
      idWidth: id,
      outstanding: n,
      cdcDepth: q,
      wishboneBurstBeats: beats,
      busAddressWidth: aw,
      busClockSync: sync,
      postedWrites: posted,
      scanoutPorts: scan,
      scanoutMaxInFlight: inFlight,
      maxPostponedRefresh: post,
      maxPulledInRefresh: pull,
      phy: phy,
    );
    final names = [
      make(),
      make(protocol: HarborFabricKind.tilelink),
      make(protocol: HarborFabricKind.wishbone),
      make(protocol: HarborFabricKind.wishbone, beats: 4),
      make(protocol: HarborFabricKind.wishbone, posted: true),
      make(id: 2),
      make(n: 4),
      make(q: 32),
      make(aw: 32),
      make(hz: 100000000),
      make(protocol: HarborFabricKind.wishbone, sync: true),
      make(scan: 1),
      make(scan: 1, inFlight: 1),
      make(post: 9),
      make(pull: 9),
      make(phy: const HarborSdramPhyConfig(captureCycles: 3)),
      make(cfg: config.copyWith(addressMap: HarborSdramAddressMap.bankRowCol)),
      make(
        cfg: config.copyWith(timing: config.timing.copyWith(powerUpNs: 2000)),
      ),
    ].map((s) => s.definitionName).toList();
    expect(names.toSet(), hasLength(names.length), reason: '$names');
  });

  test('busClockSync and postedWrites need a Wishbone port', () {
    for (final kind in [HarborFabricKind.axi4, HarborFabricKind.tilelink]) {
      expect(
        () => HarborSdram(
          config: config,
          baseAddress: 0,
          clockHz: 125000000,
          target: ecp5Target,
          busClockSync: true,
          protocol: kind,
        ),
        throwsArgumentError,
      );
      expect(
        () => HarborSdram(
          config: config,
          baseAddress: 0,
          clockHz: 125000000,
          target: ecp5Target,
          postedWrites: true,
          protocol: kind,
        ),
        throwsArgumentError,
      );
    }
  });

  test('a Wishbone port takes no outstanding or cdc depth', () {
    expect(
      () => HarborSdram(
        config: config,
        baseAddress: 0,
        clockHz: 125000000,
        target: ecp5Target,
        outstanding: 2,
      ),
      throwsArgumentError,
    );
    expect(
      () => HarborSdram(
        config: config,
        baseAddress: 0,
        clockHz: 125000000,
        target: ecp5Target,
        cdcDepth: 4,
      ),
      throwsArgumentError,
    );
  });

  test('sdram requests per burst', () {
    const fixed = HarborMemoryBurst.fixed;
    const wrap = HarborMemoryBurst.wrap;
    expect(HarborSdram.busRequestsFor(16, burst: fixed), 16);
    expect(HarborSdram.busRequestsFor(16, size: 1), 16);
    expect(HarborSdram.busRequestsFor(16), 5);
    expect(HarborSdram.busRequestsFor(16, burst: wrap), 5);
    expect(HarborSdram.busRequestsFor(256), 65);
    expect(() => HarborSdram.busRequestsFor(257), throwsArgumentError);
    final s = HarborSdram(
      config: config,
      baseAddress: 0,
      clockHz: 125000000,
      target: ecp5Target,
      scanoutPorts: 1,
    );
    expect(s.busBurstWaitBound(16, burst: fixed), 16 * s.busWaitBound);
    expect(s.busBurstWaitBound(16), 5 * s.busWaitBound);
  });

  test('a wrong bus width or depth throws', () {
    expect(
      () => HarborSdram(
        config: config,
        baseAddress: 0,
        clockHz: 125000000,
        target: ecp5Target,
        busDataWidth: 64,
      ),
      throwsArgumentError,
    );
    expect(
      () => HarborSdram(
        config: config,
        baseAddress: 0,
        clockHz: 125000000,
        target: ecp5Target,
        outstanding: 0,
      ),
      throwsArgumentError,
    );
  });

  test('a null target throws', () {
    expect(
      () => HarborSdram(config: config, baseAddress: 0, clockHz: 125000000),
      throwsArgumentError,
    );
  });

  test('an iCE40 target throws', () {
    expect(
      () => HarborSdram(
        config: config,
        baseAddress: 0,
        clockHz: 125000000,
        target: const HarborFpgaTarget.ice40(device: 'UP5K', package: 'SG48'),
      ),
      throwsArgumentError,
    );
  });

  test('175 MHz throws on ecp5 (ecp5 output limit is 150 MHz)', () {
    expect(
      () => HarborSdram(
        config: config,
        baseAddress: 0,
        clockHz: 175000000,
        target: ecp5Target,
      ),
      throwsArgumentError,
    );
  });
}
