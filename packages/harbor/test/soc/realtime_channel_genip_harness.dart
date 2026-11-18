// Shared helpers for the genip shaped tests: a SoC shaped like River genip: the real-time display master and a CPU like
// master on channel `primary`, a DMA master on channel `dma`, and one memory
// behind a converge fabric. The wait of the display read stays under the sum
// of the channel bound and the converge bound.

import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../bus/port/memory_harness.dart';
import '../bus/port/port_harness.dart';
import '../bus/fabric/axi4_fabric_harness.dart' show must;

const _mem = 0x80000000;
const _cap = 16;

// First access of the SRAM: the registered read and the acknowledge.
const _sramAccess = 2;

HarborMemoryWaistConfig _cfg(HarborFabricKind kind) => HarborMemoryWaistConfig(
  addressWidth: 32,
  dataWidth: 32,
  idWidth: kind == HarborFabricKind.axi4 ? 2 : 1,
  outstanding: 2,
);

// A memory master port of [kind] with its waist on ports `w_*`.
class _Master extends BridgeModule {
  _Master(HarborFabricKind kind, String tag)
    : super('GenipMaster_${kind.name}_$tag', name: tag) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final port = HarborMemoryMasterPort.create(
      module: this,
      name: 'bus',
      kind: kind,
      config: _cfg(kind),
      clk: input('clk'),
      reset: input('reset'),
    );
    exposeWaist(this, port.waist, 'w', PairRole.consumer);
  }

  void pullUp(HarborSoC soc) {
    for (final n in [...inputs.keys, ...outputs.keys]) {
      if (!n.startsWith('w_')) continue;
      soc.pullUpPort(port(n), newPortName: '${name}_$n');
    }
  }
}

Burst _rd(int addr, int len) =>
    Burst(id: 0, write: false, addr: addr, len: len, size: 2, burst: 1);

Burst _wr(int addr, int len) => Burst(
  id: 0,
  write: true,
  addr: addr,
  len: len,
  size: 2,
  burst: 1,
  data: [for (var i = 0; i <= len; i++) addr + i],
  strb: List.filled(len + 1, 0xf),
);

/// Runs the genip shaped SoC of [kind] and checks the wait of the display
/// read against the bound.
Future<void> runGenip(HarborFabricKind kind, {bool pipeline = false}) async {
  final soc = HarborSoC(
    name: 'Genip_${kind.name}',
    compatible: 'test,genip',
    fabricKind: kind,
    target: const HarborSimTarget(frequency: 50000000),
  );
  final rt = soc.addMaster(
    _Master(kind, 'rt'),
    busInterfaceName: 'bus',
    memory: true,
    outstanding: 1,
    realtime: true,
    channel: 'primary',
  );
  final cpu = soc.addMaster(
    _Master(kind, 'cpu'),
    busInterfaceName: 'bus',
    memory: true,
    outstanding: 1,
    writeStallFree: true,
    channel: 'primary',
  );
  final dma = soc.addMaster(
    _Master(kind, 'dma'),
    busInterfaceName: 'bus',
    memory: true,
    outstanding: 1,
    writeStallFree: true,
    channel: 'dma',
  );
  soc.addPeripheral(
    HarborSram(
      baseAddress: _mem,
      size: 0x1000,
      busAddressWidth: 32,
      protocol: kind,
      name: 'mem',
    ),
  );
  soc.buildFabric(
    channelSlaves: {
      'primary': {'mem'},
      'dma': {'mem'},
    },
    realtimeBurstCap: _cap,
    pipeline: pipeline,
  );
  for (final m in [rt, cpu, dma]) {
    m.pullUp(soc);
  }

  final sim = Sim(soc);
  final rng = Random(4);
  final errors = <String>[];
  final cpuReq = WaistRequester(
    sim,
    'cpu_w',
    rng,
    errors: errors,
    idle: 0,
    stall: 0,
  );
  final dmaReq = WaistRequester(
    sim,
    'dma_w',
    rng,
    errors: errors,
    idle: 0,
    stall: 0,
  );
  final rtReq = WaistRequester(
    sim,
    'rt_w',
    rng,
    errors: errors,
    idle: 0,
    stall: 0,
  );
  final waits = <int>[];
  final lasts = <int>[];
  final starts = <int>[];
  final writeDone = <int>[];
  final writeStarts = <int>[];
  var now = 0;
  int? start;
  sim.onRise(() {
    now++;
    if (sim.pre('rt_w_RDATA_VALID') == 1 &&
        sim.pre('rt_w_RDATA_READY') == 1 &&
        sim.pre('rt_w_RDATA_LAST') == 1) {
      lasts.add(now);
    }
    if (sim.pre('rt_w_REQ_VALID') == 1 &&
        sim.pre('rt_w_REQ_WRITE') == 1 &&
        writeStarts.length == writeDone.length) {
      writeStarts.add(now);
    }
    if (sim.pre('rt_w_WRESP_VALID') == 1 && sim.pre('rt_w_WRESP_READY') == 1) {
      writeDone.add(now);
    }
    if (start == null &&
        sim.pre('rt_w_REQ_VALID') == 1 &&
        sim.pre('rt_w_REQ_WRITE') == 0) {
      start = now;
      starts.add(now);
    }
    if (start != null &&
        sim.pre('rt_w_RDATA_VALID') == 1 &&
        sim.pre('rt_w_RDATA_READY') == 1) {
      waits.add(now - start!);
      start = null;
    }
  });
  await sim.start();
  Simulator.setMaxSimTime(20000000);

  // The SRAM reads X until it is written.
  for (var o = 0; o < 0x1000; o += 0x40) {
    cpuReq.send(_wr(_mem + o, 15));
  }
  await waitUntil(sim, () => cpuReq.done, limit: 20000);

  // The wait with no other traffic is the access cycles of the memory as the
  // display master sees them: its port, the fabrics and the memory.
  rtReq.send(_rd(_mem, 15));
  await waitUntil(sim, () => rtReq.done, limit: 20000);
  final unloaded = waits.single;
  // Cycles per beat at the memory, from the 16 beats of the same read.
  final beatCycles = max(
    1,
    ((lasts.single - starts.first - waits.single) / 15).ceil(),
  );
  // A write holds the memory for its beats and then a response latency.
  rtReq.send(_wr(_mem, 15));
  await waitUntil(sim, () => writeDone.isNotEmpty, limit: 20000);
  final writeLatency = writeDone.single - writeStarts.single - 15 * beatCycles;
  waits.clear();

  final dmaLen = kind == HarborFabricKind.axi4 ? 255 : 15;
  for (var i = 0; i < 12; i++) {
    cpuReq.send(
      i.isEven
          ? _rd(_mem + 0x400 + (i % 4) * 0x40, 15)
          : _wr(_mem + 0x400 + (i % 4) * 0x40, 15),
    );
    dmaReq.send(
      i.isEven
          ? _wr(_mem + 0x800 + (i % 2) * 0x400, dmaLen)
          : _rd(_mem + 0x800 + (i % 2) * 0x400, dmaLen),
    );
  }
  const reads = 16;
  for (var i = 0; i < reads; i++) {
    await sim.cycles(41 + (i * 13) % 23);
    rtReq.send(_rd(_mem + i * 0x40, 3));
    await waitUntil(sim, () => rtReq.done, limit: 20000);
  }
  await waitUntil(sim, () => cpuReq.done && dmaReq.done, limit: 300000);
  await sim.stop();

  FabricMasters of(String fabric) {
    final f = soc.fabrics.firstWhere((x) => x.name == fabric) as dynamic;
    return (
      f.masters as List<HarborFabricMaster>,
      f.slaves as List<HarborFabricSlave>,
    );
  }

  final (chan, _) = of('fabric_primary');
  final (conv, convSlaves) = of('converge_mem');
  final bound = HarborFabric.realtimeWaitBoundThrough(
    kind: kind,
    channelMasters: chan,
    convergeMasters: conv,
    cap: _cap,
    slaveOutstanding: convSlaves.first.outstanding,
    realtimeBeats: 16,
    maxMessageBeats: 16,
    accessCycles: _sramAccess,
    pathCycles: HarborFabric.pathCyclesOf(
      kind: kind,
      fabrics: 2,
      registerStages: pipeline ? 1 : 0,
    ),
    wishboneGrantCap: kind == HarborFabricKind.wishbone
        ? harborDefaultWishboneGrantCap
        : null,
    beatCycles: beatCycles,
  );
  final worst = waits.reduce(max);
  // ignore: avoid_print
  print(
    'genip ${kind.name}${pipeline ? ' pipeline' : ''}: worst wait $worst, '
    'bound $bound, unloaded $unloaded, write latency $writeLatency, '
    'cycles per beat $beatCycles',
  );
  must(waits.length, reads);
  expect(worst, lessThanOrEqualTo(bound));
  must(errors, isEmpty);
}

typedef FabricMasters = (List<HarborFabricMaster>, List<HarborFabricSlave>);
