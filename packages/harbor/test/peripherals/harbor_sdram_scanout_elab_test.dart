import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Elaboration checks for the [HarborSdram] scanout ports, the stride and
/// bound helpers, and the sim latency on a [HarborSimTarget] build.
void main() {
  tearDown(() async => Simulator.reset());

  const config = HarborSdramConfig.as4c16m16sb6();
  const ecp5Target = HarborFpgaTarget.ecp5(
    device: 'LFE5U-85F',
    package: 'CABGA381',
  );
  const simTarget = HarborSimTarget(topCell: 'top', frequency: 25000000);

  void expectScanPorts(HarborSdram s) {
    expect(s.input('scan0_rq_valid').width, 1);
    expect(s.input('scan0_rq_addr').width, 32);
    expect(s.input('scan0_rq_words').width, 4);
    expect(s.output('scan0_rq_ready').width, 1);
    expect(s.output('scan0_rd_valid').width, 1);
    expect(s.output('scan0_rd_data').width, 16);
    expect(s.output('scan_clk').width, 1);
    expect(s.output('scan_reset').width, 1);
  }

  test('ecp5: a scanout port joins the arbiter as a realtime port', () async {
    final s = HarborSdram(
      config: config,
      baseAddress: 0x80000000,
      clockHz: 125000000,
      target: ecp5Target,
      scanoutPorts: 1,
    );
    await s.build();
    expectScanPorts(s);
    final sv = s.generateSynth();
    expect(sv, contains('scan0_in_flight'));
    expect(sv, contains('scan0_req_valid'));
    expect(sv, contains('scan_reset'));
    expect(sv, contains('engine_data_reset'));
  });

  test('sim: the scanout port and the latency reach harbor_sim_dram', () async {
    final s = HarborSdram(
      config: config,
      baseAddress: 0x80000000,
      clockHz: 100000000,
      target: simTarget,
      scanoutPorts: 1,
      simReadLatency: HarborSimDram.latencyFor(
        busHz: 25000000,
        memHz: 100000000,
      ),
      simWriteLatency: 7,
    );
    await s.build();
    expectScanPorts(s);
    final dram = s.subModules.whereType<HarborSimDram>().single;
    expect(dram.readLatency, 11);
    expect(dram.writeLatency, 7);
    expect(dram.scanoutPorts, 1);
    expect(dram.definitionName, endsWith('_r11w7_s1'));
    expect(dram.simRtl, contains('scan0_rq_ready'));
    expect(dram.simRtl, contains('scan0_rd_data'));
  });

  test('sim: the defaults keep the old leaf', () async {
    final s = HarborSdram(
      config: config,
      baseAddress: 0,
      clockHz: 100000000,
      target: simTarget,
    );
    await s.build();
    final dram = s.subModules.whereType<HarborSimDram>().single;
    expect(dram.definitionName, 'harbor_sim_dram_26a32d8388608w');
  });

  test(
    'read port stages add registers and a queue on the scanout port',
    () async {
      HarborSdram make(int stages) => HarborSdram(
        config: config,
        baseAddress: 0x80000000,
        clockHz: 125000000,
        target: ecp5Target,
        scanoutPorts: 1,
        readPortStages: stages,
      );
      expect(() => make(-1), throwsArgumentError);
      final s = make(2);
      expect(s.definitionName, isNot(make(0).definitionName));
      expect(s.definitionName, isNot(make(1).definitionName));
      await s.build();
      expectScanPorts(s);
      expect(s.busWaitBound, HarborSdram.bestEffortWaitBound(s.cycles, 3) + 1);
      final sv = s.generateSynth();
      for (final n in [
        'scan0_rq_valid_s1',
        'scan0_rd_valid_s1',
        'scan0_q_valid_2',
      ]) {
        expect(sv, contains(n));
      }
      expect(sv, isNot(contains('scan0_slot_valid')));
    },
  );

  test('scanout stride puts each line on a new row', () {
    final s = HarborSdram(
      config: config,
      baseAddress: 0x80000000,
      clockHz: 125000000,
      target: ecp5Target,
    );
    expect(config.pageBytes, 1024);
    expect(s.scanoutStride(640 * 4), 3072);
    expect(s.scanoutStride(1024), 1024);
    expect(s.scanoutStride(640 * 2), 2048);
  });

  test('wait bounds follow the cycle counts', () {
    final want = {
      100000000: (31, [55, 73, 127]),
      125000000: (38, [65, 86, 149]),
    };
    for (final MapEntry(key: hz, value: (rt, be)) in want.entries) {
      final c = HarborSdramCycles(config, clockHz: hz);
      expect(HarborSdram.realtimeWaitBound(c), rt);
      for (var m = 1; m <= 3; m++) {
        expect(HarborSdram.bestEffortWaitBound(c, m), be[m - 1], reason: '$m');
      }
      expect(() => HarborSdram.bestEffortWaitBound(c, 4), throwsArgumentError);
    }
  });

  test('bad scanout arguments throw', () {
    HarborSdram make({int ports = 1, int inFlight = 3, int base = 0}) =>
        HarborSdram(
          config: config,
          baseAddress: base,
          clockHz: 125000000,
          target: ecp5Target,
          scanoutPorts: ports,
          scanoutMaxInFlight: inFlight,
        );
    expect(() => make(ports: -1), throwsArgumentError);
    expect(
      () => make(ports: 2),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('multiple scanout ports are not supported yet'),
        ),
      ),
    );
    expect(() => make(inFlight: 0), throwsArgumentError);
    expect(() => make(inFlight: 4), throwsArgumentError);
    for (var m = 1; m <= 3; m++) {
      expect(make(inFlight: m).scanoutMaxInFlight, m);
    }
    expect(() => make(base: 0x1000), throwsArgumentError);
  });
}
