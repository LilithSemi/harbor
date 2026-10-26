import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/port/memory_harness.dart';
import '../bus/port/port_harness.dart';
import '../peripherals/memory_port_bench.dart';
import '../peripherals/sdram_memory_port_bench.dart';
import '../peripherals/sdram_phy_ecp5_harness.dart';
import '../peripherals/sdram_pin_model.dart';
import 'sdram_scanout_harness.dart';

const _fbBase = 0x10000;
const _stride = 3072;

/// A requester of [kind] on the fabric clock, an ECP5 [HarborSdram] with a
/// scanout port, and a display on that port.
class _WaistScanTop extends BridgeModule {
  late final HarborSdram sdram;
  late final BenchScanDisplay display;

  _WaistScanTop(
    HarborFabricKind kind,
    HarborMemoryWaistConfig config,
    HarborDisplayTiming timing, {
    required int memHz,
  }) : super('WaistScanTop_${kind.name}_n${config.outstanding}', name: 'top') {
    for (final p in [
      'clk',
      'reset',
      'mem_clk',
      'mem_reset',
      'pixel_clk',
      'pixel_reset',
      'enable',
    ]) {
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
        scanoutPorts: 1,
        target: const HarborFpgaTarget.ecp5(
          device: 'LFE5U-85F',
          package: 'CABGA381',
        ),
      ),
    );
    for (final p in ['clk', 'reset', 'mem_clk', 'mem_reset']) {
      sdram.input(p).srcConnection! <= input(p);
    }
    display = addSubModule(BenchScanDisplay(timing: timing, stride: _stride));
    display.input('pixel_clk').srcConnection! <= input('pixel_clk');
    display.input('pixel_reset').srcConnection! <= input('pixel_reset');
    display.input('fb_base').srcConnection! <= Const(_fbBase, width: 32);
    display.input('enable').srcConnection! <= input('enable');
    display.input('clk').srcConnection! <= sdram.output('scan_clk');
    display.input('reset').srcConnection! <= sdram.output('scan_reset');
    for (final p in ['rq_ready', 'rd_valid', 'rd_data']) {
      display.input(p).srcConnection! <= sdram.output('scan0_$p');
    }
    for (final p in ['rq_valid', 'rq_addr', 'rq_words']) {
      sdram.input('scan0_$p').srcConnection! <= display.output(p);
    }
    for (final p in [
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
    ]) {
      pullUpPort(sdram.port(p), newPortName: p);
    }
    linkRequester(this, sdram, config, kind);
  }
}

/// Result of [runWaistScanout].
typedef WaistScanResult = ({
  int frames,
  int underrunFrames,
  int busWait,
  int busWaitBound,
  int scanWait,
  int scanWaitBound,
  int bursts,
  List<String> errors,
});

/// Scans 640-pixel 32 bpp lines from the scanout port while a [kind]
/// requester with [outstanding] requests in flight keeps the bus port busy
/// with random bursts outside the frame. Measures the longest wait of each
/// arbiter port in `mem_clk` cycles and checks the frame and the bursts.
Future<WaistScanResult> runWaistScanout({
  required HarborFabricKind kind,
  required int outstanding,
  required int memPeriodPs,
  int fabricPeriodPs = 20000,
  int lines = 3,
  int frames = 4,
}) async {
  final timing = vgaLines(lines);
  final config = HarborMemoryWaistConfig(
    addressWidth: 26,
    dataWidth: 32,
    idWidth: 2,
    outstanding: outstanding,
  );
  final memHz = 1000000000000 ~/ memPeriodPs;
  final top = _WaistScanTop(kind, config, timing, memHz: memHz);
  final fabricClk = SimpleClockGenerator(fabricPeriodPs).clk;
  final memClk = SimpleClockGenerator(memPeriodPs).clk;
  final pixelClk = SimpleClockGenerator(39722).clk;
  for (final input in top.inputs.values) {
    if (!input.name.endsWith('clk')) {
      input.srcConnection!.put(input.name.endsWith('reset') ? 1 : 0);
    }
  }
  top.input('clk').srcConnection! <= fabricClk;
  top.input('mem_clk').srcConnection! <= memClk;
  top.input('pixel_clk').srcConnection! <= pixelClk;
  await top.build();

  final sdram = top.sdram;
  final cycles = sdram.cycles;
  final phy = sdram.subModules.whereType<SdramPhyEcp5>().single;
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
  final errors = <String>[];
  final req = WaistRequester(
    s,
    'up',
    Random(5),
    errors: errors,
    idle: 0,
    stall: 0,
  );
  s.attach();

  // The longest wait of a request at each arbiter port.
  final arb = sdram.subModules.whereType<SdramArbiter>().single;
  var busWait = 0;
  var scanWait = 0;
  var busFor = 0;
  var scanFor = 0;
  var started = false;
  memClk.posedge.listen((_) {
    if (!started) return;
    if (arb.input('bus_req_valid').value == LogicValue.one) {
      busFor++;
      if (arb.output('bus_req_ready').value == LogicValue.one) {
        busWait = max(busWait, busFor);
        busFor = 0;
      }
    }
    if (arb.input('scan0_req_valid').value == LogicValue.one) {
      scanFor++;
      if (arb.output('scan0_req_ready').value == LogicValue.one) {
        scanWait = max(scanWait, scanFor);
        scanFor = 0;
      }
    }
  });

  // Frames, underruns and the pixels of the frame being scanned.
  final display = top.display;
  final de = display.output('de');
  final x = display.output('x');
  final y = display.output('y');
  final word = display.output('pixel_word');
  final under = display.output('underrun');
  final frame = <int, int>{};
  final fb = <int, int>{};
  var frameCount = 0;
  var underrunFrames = 0;
  var checked = false;
  var sawUnder = false;
  // The display takes enable at a frame start, so the frames count from
  // the first frame that showed pixels.
  var shown = false;
  var prevY = -1;
  pixelClk.posedge.listen((_) {
    if (top.input('enable').value != LogicValue.one || !y.value.isValid) {
      return;
    }
    final yv = y.value.toInt();
    if (de.value == LogicValue.one) {
      shown = true;
      frame[yv * 640 + x.value.toInt()] = word.value.isValid
          ? word.value.toInt()
          : -1;
    }
    if (under.value == LogicValue.one) sawUnder = true;
    if (prevY == timing.vActive - 1 && yv == timing.vActive && !shown) {
      sawUnder = false;
    } else if (prevY == timing.vActive - 1 && yv == timing.vActive) {
      frameCount++;
      if (checked) {
        for (var py = 0; py < lines && errors.length < 8; py++) {
          for (var px = 0; px < 640; px++) {
            final want = fb[_fbBase + py * _stride + px * 4];
            if (frame[py * 640 + px] != want) {
              errors.add('pixel ($px,$py) ${frame[py * 640 + px]} want $want');
              break;
            }
          }
        }
      }
      if (sawUnder && frameCount > 1) underrunFrames++;
      sawUnder = false;
    }
    prevY = yv;
  });

  Simulator.setMaxSimTime(1 << 50);
  s.watchEnd();
  unawaited(Simulator.run());
  for (var i = 0; i < 8; i++) {
    await memClk.nextPosedge;
  }
  top.input('mem_reset').srcConnection!.inject(0);
  top.input('pixel_reset').srcConnection!.inject(0);
  await fabricClk.nextNegedge;
  top.input('reset').srcConnection!.inject(0);
  while (sdram.output('init_done').value != LogicValue.one) {
    await memClk.nextPosedge;
  }
  s.running = true;
  final rng = Random(11);

  // The frame first, in 64-beat bursts.
  for (var py = 0; py < lines; py++) {
    for (var px = 0; px < 640; px += 64) {
      final a = _fbBase + py * _stride + px * 4;
      final data = [for (var i = 0; i < 64; i++) rng.nextInt(1 << 32)];
      for (var i = 0; i < 64; i++) {
        fb[a + 4 * i] = data[i];
      }
      req.send(
        Burst(
          id: 0,
          write: true,
          addr: a,
          len: 63,
          size: 2,
          burst: 1,
          data: data,
          strb: List.filled(64, 15),
        ),
      );
    }
  }
  // The traffic region next, so every read there has a known value.
  final mem = WordMemory(4);
  const region = 0x100000;
  for (var a = 0; a < 0x8000; a += 1024) {
    req.send(
      Burst(
        id: 0,
        write: true,
        addr: region + a,
        len: 255,
        size: 2,
        burst: 1,
        data: [for (var i = 0; i < 256; i++) mem.read(a + 4 * i)],
        strb: List.filled(256, 15),
      ),
    );
  }
  await waitUntil(s, () => req.done, limit: 4000000);
  top.input('enable').srcConnection!.inject(1);
  started = true;
  await waitUntilFrames(
    pixelClk,
    () => frameCount,
    1,
    limit: 4 * timing.hTotal * timing.vTotal,
  );
  checked = true;

  // Then rounds of random writes and reads outside the frame until enough
  // frames went by.
  final gen = BurstGen(
    rng,
    busBytes: 4,
    idWidth: config.idWidth,
    span: 0x8000,
    long: 0.1,
  );
  var bursts = 0;
  while (frameCount < frames + 1 && errors.isEmpty) {
    final writes = [for (var i = 0; i < 16; i++) _at(gen.next(write: true))];
    for (final b in writes) {
      req.send(b);
    }
    await waitUntil(s, () => req.done, limit: 4000000);
    for (final b in writes) {
      final addrs = beatAddrs(b.addr, b.len, b.size, b.burst);
      for (var i = 0; i < b.beats; i++) {
        mem.write(addrs[i] - region, b.data[i], b.strb[i]);
      }
    }
    final first = req.reads.length;
    final reads = [for (var i = 0; i < 16; i++) _at(gen.next(write: false))];
    for (final b in reads) {
      req.send(b);
    }
    await waitUntil(s, () => req.done, limit: 4000000);
    for (var k = 0; k < reads.length && errors.length < 8; k++) {
      final b = reads[k];
      final got = req.readResp[first + k];
      final addrs = beatAddrs(b.addr, b.len, b.size, b.burst);
      for (var i = 0; i < b.beats; i++) {
        final lanes = _lanes(addrs[i], b.size);
        final want = mem.read(addrs[i] - region) & lanes;
        if ((got[i].$2 & lanes) != want || got[i].$3 != 0) {
          errors.add('$b beat $i: 0x${got[i].$2.toRadixString(16)}');
          break;
        }
      }
    }
    bursts += 32;
  }
  for (final r in req.writeResp) {
    if (r.$2 != 0) errors.add('write response with ERR');
  }
  errors.addAll(model.errors.take(4));
  model.finish();
  await Simulator.endSimulation();
  return (
    frames: frameCount,
    underrunFrames: underrunFrames,
    busWait: busWait,
    busWaitBound: sdram.busWaitBound,
    scanWait: scanWait,
    scanWaitBound: sdram.scanoutWaitBound,
    bursts: bursts,
    errors: errors,
  );
}

/// [b] moved up into the traffic region.
Burst _at(Burst b) => Burst(
  id: b.id,
  write: b.write,
  addr: b.addr + 0x100000,
  len: b.len,
  size: b.size,
  burst: b.burst,
  data: b.data,
  strb: b.strb,
);

int _lanes(int addr, int size) {
  if (size >= 2) return 0xffffffff;
  final bytes = 1 << size;
  final lo = (addr & ~(bytes - 1)) % 4;
  var m = 0;
  for (var i = lo; i < lo + bytes; i++) {
    m |= 0xff << (8 * i);
  }
  return m;
}

/// Waits until [count] has grown by [n]. It fails after [limit] clocks.
Future<void> waitUntilFrames(
  Logic clk,
  int Function() count,
  int n, {
  required int limit,
}) async {
  final target = count() + n;
  for (var i = 0; count() < target; i++) {
    if (i > limit) throw StateError('no $n frames in $limit clocks');
    await clk.nextPosedge;
  }
}
