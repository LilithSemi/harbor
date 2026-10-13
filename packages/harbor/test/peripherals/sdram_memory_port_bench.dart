import 'dart:collection';
import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/port/memory_harness.dart';
import '../bus/port/port_harness.dart';
import 'memory_port_bench.dart';
import 'sdram_phy_ecp5_harness.dart';
import 'sdram_pin_model.dart';

const _pads = [
  'sdram_clk',
  'sdram_cke',
  'sdram_cs_n',
  'sdram_ras_n',
  'sdram_cas_n',
  'sdram_we_n',
  'sdram_ba',
  'sdram_addr',
  'sdram_dqm',
  'sdram_dq',
];

/// The sdram config of the benches: the ULX3S part with a short power-up.
HarborSdramConfig sdramBenchConfig() {
  const base = HarborSdramConfig.as4c16m16sb6();
  return base.copyWith(timing: base.timing.copyWith(powerUpNs: 2000));
}

/// A requester on the fabric clock `clk` linked to an ECP5 [HarborSdram]
/// on `mem_clk`, with the sdram pads on the top.
class SdramPortTop extends BridgeModule {
  late final HarborSdram sdram;

  SdramPortTop(
    HarborFabricKind kind,
    HarborMemoryWaistConfig config, {
    required int memHz,
    int scanoutPorts = 0,
  }) : super(
         'SdramPortBench_${kind.name}_n${config.outstanding}_m${memHz}'
         '_s$scanoutPorts',
         name: 'top',
       ) {
    for (final p in ['clk', 'reset', 'mem_clk', 'mem_reset']) {
      createPort(p, PortDirection.input);
    }
    sdram = addSubModule(
      HarborSdram(
        config: sdramBenchConfig(),
        baseAddress: 0,
        clockHz: memHz,
        busAddressWidth: config.addressWidth,
        protocol: kind,
        idWidth: config.idWidth,
        outstanding: config.outstanding,
        scanoutPorts: scanoutPorts,
        target: const HarborFpgaTarget.ecp5(
          device: 'LFE5U-85F',
          package: 'CABGA381',
        ),
      ),
    );
    for (final p in ['clk', 'reset', 'mem_clk', 'mem_reset']) {
      sdram.input(p).srcConnection! <= input(p);
    }
    for (final p in _pads) {
      pullUpPort(sdram.port(p), newPortName: p);
    }
    for (var i = 0; i < scanoutPorts; i++) {
      for (final p in [
        'rq_valid',
        'rq_addr',
        'rq_words',
        'rq_ready',
        'rd_valid',
        'rd_data',
      ]) {
        pullUpPort(sdram.port('scan${i}_$p'), newPortName: 'scan${i}_$p');
      }
    }
    linkRequester(this, sdram, config, kind);
  }
}

/// An [SdramPortTop] with its clocks, the pin model and a [Sim] on the
/// fabric clock, past reset and sdram init.
class SdramPortBench {
  final SdramPortTop top;
  final Sim s;
  final SdramPinModel model;
  final Logic memClk;

  SdramPortBench._(this.top, this.s, this.model, this.memClk);

  HarborSdram get sdram => top.sdram;

  /// Builds the bench and runs it to the end of the sdram init. [attach]
  /// adds the test's own callbacks before the simulation starts.
  static Future<SdramPortBench> start(
    HarborFabricKind kind,
    HarborMemoryWaistConfig config, {
    required int fabricPeriodPs,
    int memPeriodPs = 8000,
    int scanoutPorts = 0,
    required void Function(Sim s) attach,
  }) async {
    final memHz = 1000000000000 ~/ memPeriodPs;
    final top = SdramPortTop(
      kind,
      config,
      memHz: memHz,
      scanoutPorts: scanoutPorts,
    );
    final fabricClk = SimpleClockGenerator(fabricPeriodPs).clk;
    final memClk = SimpleClockGenerator(memPeriodPs).clk;
    for (final input in top.inputs.values) {
      if (!{'clk', 'mem_clk'}.contains(input.name)) {
        input.srcConnection!.put(input.name.endsWith('reset') ? 1 : 0);
      }
    }
    top.input('clk').srcConnection! <= fabricClk;
    top.input('mem_clk').srcConnection! <= memClk;
    await top.build();

    final cycles = top.sdram.cycles;
    final phy = top.sdram.subModules.whereType<SdramPhyEcp5>().single;
    final bbs = {for (final m in phy.subModules.whereType<Ecp5Bb>()) m.name: m};
    final dqBbs = [for (var i = 0; i < 16; i++) bbs['dq_bb_$i']!];
    const fpgaToSdramNs = 4.6;
    if (!sdramPhyCaptureOk(
      periodPs: memPeriodPs,
      tAcNs: cycles.casLatency == 3 ? 5.0 : 6.0,
      fpgaToSdramNs: fpgaToSdramNs,
      phy: const HarborSdramPhyConfig(),
    )) {
      throw ArgumentError('the capture window misses at $memPeriodPs ps');
    }
    final model = SdramPinModel(
      clk: top.output('sdram_clk'),
      cke: top.output('sdram_cke'),
      csN: top.output('sdram_cs_n'),
      rasN: top.output('sdram_ras_n'),
      casN: top.output('sdram_cas_n'),
      weN: top.output('sdram_we_n'),
      ba: top.output('sdram_ba'),
      addr: top.output('sdram_addr'),
      dqm: top.output('sdram_dqm'),
      dq: top.inOutSource('sdram_dq') as LogicNet,
      rules: const SdramModelRules.as4c16m16sb6().copyWith(powerUpNs: 2000),
      fpgaToSdramNs: fpgaToSdramNs,
      fpgaDqOe: [for (final bb in dqBbs) ~bb.input('T')].rswizzle(),
      fpgaDqOut: [for (final bb in dqBbs) bb.input('I')].rswizzle(),
      refreshPolicy: SdramRefreshPolicy(
        maxPostponed: cycles.maxPostponed,
        maxPulledIn: cycles.maxPulledIn,
        periodNs: cycles.refi * memPeriodPs / 1000,
        maxLatencyNs: 256 * memPeriodPs / 1000,
        initRefreshes: cycles.initRefreshes,
      ),
    );

    final s = Sim(top, clk: fabricClk);
    attach(s);
    s.attach();
    Simulator.setMaxSimTime(1 << 50);
    s.watchEnd();
    unawaited(Simulator.run());
    for (var i = 0; i < 8; i++) {
      await memClk.nextPosedge;
    }
    top.input('mem_reset').srcConnection!.inject(0);
    await fabricClk.nextNegedge;
    top.input('reset').srcConnection!.inject(0);
    await fabricClk.nextNegedge;
    while (top.sdram.output('init_done').value != LogicValue.one) {
      await memClk.nextPosedge;
    }
    s.running = true;
    return SdramPortBench._(top, s, model, memClk);
  }

  Future<void> stop() async {
    model.finish();
    await Simulator.endSimulation();
  }
}

/// Random bursts and IDs from a requester on a fabric clock of
/// [fabricPeriodPs] through the native [kind] port of an ECP5 [HarborSdram]
/// on a 125 MHz memory clock, against a reference memory. Returns the
/// errors found. With [pastTheEnd], it also checks the accesses past the
/// sdram size.
Future<List<String>> sdramRandomBursts(
  HarborFabricKind kind, {
  required int fabricPeriodPs,
  required int seed,
  int outstanding = 8,
  int count = 40,
  bool pastTheEnd = true,
}) async {
  final config = HarborMemoryWaistConfig(
    addressWidth: 26,
    dataWidth: 32,
    idWidth: 2,
    outstanding: outstanding,
  );
  late MemoryPortCheck check;
  final bench = await SdramPortBench.start(
    kind,
    config,
    fabricPeriodPs: fabricPeriodPs,
    attach: (s) {
      check = MemoryPortCheck(
        s,
        Random(seed),
        busBytes: 4,
        idWidth: config.idWidth,
        span: 0x2000,
        timeout: 4000000,
      );
    },
  );
  await check.fill();
  final bad = [
    ...await check.run(count, extra: longBursts(Random(seed), 4)),
    if (pastTheEnd) ...await _pastTheEnd(check),
    ...bench.model.errors.take(8),
  ];
  if (bench.sdram.busError.value.toInt() != 0) bad.add('bus_error is set');
  await bench.stop();
  return bad;
}

/// A write past the sdram size changes nothing, and a read there ends.
Future<List<String>> _pastTheEnd(MemoryPortCheck check) async {
  const top = 1 << 25;
  final req = check.req;
  final before = req.reads.length;
  req.send(
    Burst(
      id: 1,
      write: true,
      addr: top + 0x100,
      len: 3,
      size: 2,
      burst: 1,
      data: [0xdead0001, 0xdead0002, 0xdead0003, 0xdead0004],
      strb: [15, 15, 15, 15],
    ),
  );
  for (final a in [0x100, top + 0x100]) {
    req.send(Burst(id: 1, write: false, addr: a, len: 3, size: 2, burst: 1));
  }
  await waitUntil(check.s, () => req.done, limit: 400000);
  final bad = <String>[];
  for (var k = 0; k < 2; k++) {
    final got = req.readResp[before + k];
    for (var i = 0; i < 4; i++) {
      final want = check.want.read(0x100 + 4 * i);
      if (got.length != 4 || got[i].$2 != want) {
        bad.add('past the end, read $k beat $i: $got want $want');
        break;
      }
    }
  }
  return bad;
}

/// One throughput run: [bursts] reads of [beats] beats each, then the same
/// count of writes, with [outstanding] requests in flight. Returns the read
/// and write MB/s on the fabric side and the mean fabric cycles from a
/// request to its first read beat or its write response.
Future<({double readMBs, double writeMBs, double readWait, double writeWait})>
sdramThroughput({
  required int outstanding,
  required int beats,
  int bursts = 64,
  int fabricPeriodPs = 20000,
  HarborFabricKind kind = HarborFabricKind.axi4,
}) async {
  final config = HarborMemoryWaistConfig(
    addressWidth: 26,
    dataWidth: 32,
    idWidth: 2,
    outstanding: outstanding,
  );
  late WaistRequester req;
  final errors = <String>[];
  var cycle = 0;
  final reqAt = <int>[];
  final respAt = <int>[];
  var firstBeat = true;
  final bench = await SdramPortBench.start(
    kind,
    config,
    fabricPeriodPs: fabricPeriodPs,
    attach: (s) {
      req = WaistRequester(
        s,
        'up',
        Random(1),
        errors: errors,
        idle: 0,
        stall: 0,
      );
      s.onRise(() {
        cycle++;
        if (s.pre('up_REQ_VALID') == 1 && s.pre('up_REQ_READY') == 1) {
          reqAt.add(cycle);
        }
        if (s.pre('up_RDATA_VALID') == 1 && s.pre('up_RDATA_READY') == 1) {
          if (firstBeat) respAt.add(cycle);
          firstBeat = s.pre('up_RDATA_LAST') == 1;
        }
        if (s.pre('up_WRESP_VALID') == 1 && s.pre('up_WRESP_READY') == 1) {
          respAt.add(cycle);
        }
      });
    },
  );
  final rng = Random(7);
  // Spread over all banks and many rows, as a GPU working set is.
  int addr() => rng.nextInt(1 << 20) & ~(beats * 4 - 1);

  Future<(double, double)> phase(bool write) async {
    reqAt.clear();
    respAt.clear();
    final start = cycle;
    for (var i = 0; i < bursts; i++) {
      req.send(
        Burst(
          id: 0,
          write: write,
          addr: addr(),
          len: beats - 1,
          size: 2,
          burst: 1,
          data: write
              ? [for (var b = 0; b < beats; b++) rng.nextInt(1 << 32)]
              : const [],
          strb: write ? List.filled(beats, 15) : const [],
        ),
      );
    }
    await waitUntil(bench.s, () => req.done, limit: 4000000);
    final span = cycle - start;
    final mbs = bursts * beats * 4 / (span * fabricPeriodPs * 1e-12) / 1e6;
    var wait = 0;
    for (var i = 0; i < reqAt.length; i++) {
      wait += respAt[i] - reqAt[i];
    }
    return (mbs, wait / reqAt.length);
  }

  final (readMBs, readWait) = await phase(false);
  final (writeMBs, writeWait) = await phase(true);
  if (errors.isNotEmpty) throw StateError('requester: ${errors.take(4)}');
  if (bench.model.errors.isNotEmpty) {
    throw StateError('pin model: ${bench.model.errors.take(4)}');
  }
  await bench.stop();
  return (
    readMBs: readMBs,
    writeMBs: writeMBs,
    readWait: readWait,
    writeWait: writeWait,
  );
}

/// Holds a long read on RDATA so a later write waits in the front end, then
/// resets the fabric. Returns errors if a write that got its WRESP before
/// the reset does not read back after it.
Future<List<String>> sdramAckedWriteSurvivesReset() async {
  const config = HarborMemoryWaistConfig(
    addressWidth: 26,
    dataWidth: 32,
    idWidth: 2,
    outstanding: 8,
  );
  late WaistRequester req;
  final errors = <String>[];
  var hold = false;
  final bench = await SdramPortBench.start(
    HarborFabricKind.axi4,
    config,
    fabricPeriodPs: 20000,
    attach: (s) {
      req = WaistRequester(
        s,
        'up',
        Random(3),
        errors: errors,
        idle: 0,
        stall: 0,
      )..rdata.gate = () => !hold;
    },
  );
  final s = bench.s;
  const a = 0x240;
  Burst write(int value) => Burst(
    id: 1,
    write: true,
    addr: a,
    len: 0,
    size: 2,
    burst: 1,
    data: [value],
    strb: [15],
  );
  Burst read(int addr, int len) =>
      Burst(id: 0, write: false, addr: addr, len: len, size: 2, burst: 1);

  req.send(write(0x11111111));
  await waitUntil(s, () => req.done, limit: 100000);
  hold = true;
  req.send(read(0x1000, 255));
  req.send(write(0x22222222));
  await s.cycles(2000);
  final acked = req.writeResp.length == 2;

  final reset = bench.top.input('reset').srcConnection!;
  reset.inject(1);
  await s.cycles(8);
  req.reset();
  hold = false;
  reset.inject(0);
  await s.cycles(40);

  req.send(read(a, 0));
  await waitUntil(s, () => req.done, limit: 100000);
  final got = req.readResp.last.single.$2;
  if (acked && got != 0x22222222) {
    errors.add('acked write lost in the reset: 0x${got.toRadixString(16)}');
  }
  if (got != 0x11111111 && got != 0x22222222) {
    errors.add('torn write: 0x${got.toRadixString(16)}');
  }
  errors.addAll(bench.model.errors.take(4));
  await bench.stop();
  return errors;
}

/// Sends each burst alone and returns the sdram requests the front end
/// sent for it, next to [HarborSdram.busRequestsFor].
Future<List<(Burst, int, int)>> sdramRequestCounts(List<Burst> bursts) async {
  const config = HarborMemoryWaistConfig(
    addressWidth: 26,
    dataWidth: 32,
    idWidth: 2,
    outstanding: 8,
  );
  late WaistRequester req;
  final errors = <String>[];
  final bench = await SdramPortBench.start(
    HarborFabricKind.axi4,
    config,
    fabricPeriodPs: 20000,
    attach: (s) {
      req = WaistRequester(s, 'up', Random(4), errors: errors, idle: 0);
    },
  );
  final port = bench.sdram.subModules.whereType<SdramMemoryPort>().single;
  final take = port.output('req_valid') & port.input('req_ready');
  var count = 0;
  bench.memClk.posedge.listen((_) {
    if (take.value == LogicValue.one) count++;
  });
  final out = <(Burst, int, int)>[];
  for (final b in bursts) {
    count = 0;
    req.send(b);
    await waitUntil(bench.s, () => req.done, limit: 100000);
    await bench.s.cycles(4);
    out.add((
      b,
      count,
      HarborSdram.busRequestsFor(
        b.beats,
        size: b.size,
        burst: HarborMemoryBurst.values.firstWhere((x) => x.value == b.burst),
      ),
    ));
  }
  if (errors.isNotEmpty) throw StateError('requester: $errors');
  await bench.stop();
  return out;
}

/// Sends aligned writes of 1 to 16 beats with [outstanding] in flight and
/// returns an error for any WRESP the device gives before the arbiter has
/// taken the last sdram request of that write.
Future<List<String>> sdramWrespAfterTake(int outstanding) async {
  final config = HarborMemoryWaistConfig(
    addressWidth: 26,
    dataWidth: 32,
    idWidth: 2,
    outstanding: outstanding,
  );
  late WaistRequester req;
  final errors = <String>[];
  final bench = await SdramPortBench.start(
    HarborFabricKind.axi4,
    config,
    fabricPeriodPs: 20000,
    attach: (s) {
      req = WaistRequester(s, 'up', Random(6), errors: errors, idle: 0);
    },
  );
  final arb = bench.sdram.subModules.whereType<SdramArbiter>().single;
  final take =
      arb.input('bus_req_valid') &
      arb.output('bus_req_ready') &
      arb.input('bus_req_write');
  final d = bench.sdram.bus!.waist;
  final wresp = d.wrespValid & d.wrespReady;
  // Sdram requests each write needs, summed in order.
  final need = <int>[];
  var takes = 0;
  var resps = 0;
  bench.memClk.posedge.listen((_) {
    if (wresp.value == LogicValue.one) {
      if (resps >= need.length || takes < need[resps]) {
        errors.add('WRESP $resps after $takes write takes');
      }
      resps++;
    }
    if (take.value == LogicValue.one) takes++;
  });
  final rng = Random(8);
  var total = 0;
  for (var i = 0; i < 60; i++) {
    final beats = [1, 2, 4, 8, 16][rng.nextInt(5)];
    total += (beats + 3) ~/ 4;
    need.add(total);
    req.send(
      Burst(
        id: rng.nextInt(4),
        write: true,
        addr: rng.nextInt(1 << 16) & ~63,
        len: beats - 1,
        size: 2,
        burst: 1,
        data: [for (var b = 0; b < beats; b++) rng.nextInt(1 << 32)],
        strb: List.filled(beats, 15),
      ),
    );
  }
  await waitUntil(bench.s, () => req.done, limit: 400000);
  if (resps != need.length) errors.add('$resps WRESPs for ${need.length}');
  await bench.stop();
  return errors;
}

/// Keeps two scanout reads of other rows in flight, so the engine stays
/// busy, and sends a short bus read and then a one-word write. In the
/// mem_clk cycle after the WRESP it reads the word back on the scanout
/// port. Returns an error for each read that does not see the write.
Future<List<String>> sdramScanReadAfterWresp({int rounds = 24}) async {
  const config = HarborMemoryWaistConfig(
    addressWidth: 26,
    dataWidth: 32,
    idWidth: 2,
    outstanding: 8,
  );
  late WaistRequester req;
  final errors = <String>[];
  final bench = await SdramPortBench.start(
    HarborFabricKind.axi4,
    config,
    fabricPeriodPs: 20000,
    scanoutPorts: 1,
    attach: (s) {
      req = WaistRequester(s, 'up', Random(9), errors: errors, idle: 0);
    },
  );
  final top = bench.top;
  final d = bench.sdram.bus!.waist;
  final wresp = d.wrespValid & d.wrespReady;
  final rqValid = top.input('scan0_rq_valid').srcConnection!;
  final rqAddr = top.input('scan0_rq_addr').srcConnection!;
  final rqWords = top.input('scan0_rq_words').srcConnection!;
  final rng = Random(10);
  int? probe;
  // Scanout reads taken and not read back: (words, is the probe).
  final sent = Queue<(int, bool)>();
  final words = <int>[];
  final got = <int>[];
  var resps = 0;
  var fill = true;
  // The port outputs are registers, so the negedge sees this cycle's value.
  bench.memClk.negedge.listen((_) {
    if (top.output('scan0_rd_valid').value == LogicValue.one) {
      words.add(top.output('scan0_rd_data').value.toInt());
      final (n, isProbe) = sent.first;
      if (words.length == n) {
        if (isProbe) got.add(words[0] | words[1] << 16);
        sent.removeFirst();
        words.clear();
      }
    }
    final p = probe;
    final fills = sent.where((e) => !e.$2).length;
    final int? addr;
    if (p != null) {
      addr = p;
    } else if (fill && fills < 2) {
      // Other rows of every bank, so the reads miss and run long.
      addr = (300 + rng.nextInt(50)) << 12 | rng.nextInt(4) << 10;
    } else {
      addr = null;
    }
    rqValid.put(addr == null ? 0 : 1);
    if (addr == null) return;
    final n = p == null ? 8 : 2;
    rqAddr.put(addr);
    rqWords.put(n);
    if (top.output('scan0_rq_ready').value == LogicValue.one) {
      sent.add((n, p != null));
      probe = null;
    }
  });
  bench.memClk.posedge.listen((_) {
    if (wresp.value == LogicValue.one) resps++;
  });

  final want = <int>[];
  for (var i = 0; i < rounds; i++) {
    req.send(
      Burst(
        id: 0,
        write: false,
        addr: (200 + rng.nextInt(50)) << 12 | rng.nextInt(4) << 10,
        len: 3,
        size: 2,
        burst: 1,
      ),
    );
    final addr = 0x1000 * i + 4 * rng.nextInt(64);
    final value = rng.nextInt(1 << 32);
    want.add(value);
    req.send(
      Burst(
        id: 1,
        write: true,
        addr: addr,
        len: 0,
        size: 2,
        burst: 1,
        data: [value],
        strb: [15],
      ),
    );
    while (resps <= i) {
      await bench.memClk.nextPosedge;
    }
    probe = addr;
    while (got.length <= i) {
      await bench.memClk.nextPosedge;
    }
    await waitUntil(bench.s, () => req.done, limit: 100000);
    for (var k = rng.nextInt(16); k > 0; k--) {
      await bench.memClk.nextPosedge;
    }
  }
  fill = false;
  for (var i = 0; i < rounds; i++) {
    if (got[i] != want[i]) {
      errors.add(
        'round $i: read 0x${got[i].toRadixString(16)}, '
        'wrote 0x${want[i].toRadixString(16)}',
      );
    }
  }
  errors.addAll(bench.model.errors.take(4));
  await bench.stop();
  return errors;
}
