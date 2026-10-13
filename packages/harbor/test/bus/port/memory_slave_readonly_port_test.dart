import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import 'cdc_harness.dart';
import 'memory_harness.dart';
import 'port_harness.dart';

const _cfg = HarborMemoryWaistConfig(
  addressWidth: 16,
  dataWidth: 32,
  idWidth: 4,
  outstanding: 4,
);

String _cfgTag(HarborMemoryWaistConfig c) =>
    'a${c.addressWidth}_d${c.dataWidth}_i${c.idWidth}_n${c.outstanding}';

/// A read-only AXI4 memory slave port on the fabric clock `clk`/`reset`,
/// crossing to the device clock `clk_b`/`reset_b`. `clk_a`/`reset_a` exist
/// only so this fits [MultiSim]'s 3 domain port contract; nothing uses
/// them.
class _ReadOnlyCdcShell extends BridgeModule {
  late final HarborMemorySlavePort mem;

  _ReadOnlyCdcShell(HarborMemoryWaistConfig config)
    : super('MemTestSlaveReadOnlyCdcShell_${_cfgTag(config)}', name: 'shell') {
    for (final p in ['clk', 'reset', 'clk_a', 'reset_a', 'clk_b', 'reset_b']) {
      createPort(p, PortDirection.input);
    }
    mem = HarborMemorySlavePort.create(
      module: this,
      name: 'bus',
      kind: HarborFabricKind.axi4,
      config: config,
      clk: input('clk_b'),
      reset: input('reset_b'),
      readOnly: true,
      fabricClock: HarborFabricClock(clk: input('clk'), reset: input('reset')),
    );
    exposeWaist(this, mem.waist, 'mem', PairRole.provider);
  }
}

/// Checks every read [axi] issued against what [mem] actually served:
/// the forwarded request (illegal bursts get folded to a single full-width
/// beat), every R beat's id/data/resp/last, and the outstanding limit.
List<String> _checkReads(AxiManager axi, WaistMemory mem, int busBytes) {
  final bad = <String>[];
  if (mem.reads.length != axi.arOrder.length) {
    bad.add(
      'mem saw ${mem.reads.length} reads, manager issued '
      '${axi.arOrder.length}',
    );
    return bad;
  }
  var beat = 0;
  for (var k = 0; k < axi.arOrder.length; k++) {
    final x = axi.arOrder[k];
    final illegal = illegalBurst(x, busBytes);
    final forwarded = illegal
        ? Burst(
            id: x.id,
            write: false,
            addr: x.addr,
            len: x.len,
            size: busBytes.bitLength - 1,
            burst: 0,
          )
        : x;
    final mismatch = diffReq(forwarded, mem.reads[k]);
    if (mismatch != null) bad.add(mismatch);
    for (var i = 0; i <= x.len; i++) {
      final (id, data, resp, last) = axi.rBeats[beat++];
      final want = (
        x.id,
        illegal ? 0 : mem.readData[k][i],
        illegal ? 2 : 0,
        i == x.len ? 1 : 0,
      );
      if ((id, data, resp, last) != want) {
        bad.add('$x beat $i: got ${(id, data, resp, last)} want $want');
      }
    }
  }
  return bad;
}

void main() {
  tearDown(endAndReset);

  test('a read-only slave port serves random reads against a memory', () async {
    final sim = Sim(MemSlaveShell(_cfg, readOnly: true));
    final rng = Random(1);
    final axi = AxiManager(sim, 'bus', rng, readOnly: true);
    final errors = <String>[];
    final mem = WaistMemory(
      sim,
      'mem',
      rng,
      outstanding: _cfg.outstanding,
      busBytes: _cfg.strbWidth,
      errors: errors,
    );
    final gen = BurstGen(
      rng,
      busBytes: _cfg.strbWidth,
      idWidth: _cfg.idWidth,
      illegal: 0.05,
    );
    StableCheck(sim, 'bus_ARVALID', 'bus_ARREADY', [
      'bus_ARID',
      'bus_ARADDR',
      'bus_ARLEN',
      'bus_ARSIZE',
      'bus_ARBURST',
    ], errors);
    StableCheck(sim, 'bus_RVALID', 'bus_RREADY', [
      'bus_RID',
      'bus_RDATA',
      'bus_RRESP',
      'bus_RLAST',
    ], errors);

    await sim.start();
    Simulator.setMaxSimTime(4000000);
    for (var i = 0; i < 150; i++) {
      axi.read(gen.next(write: false));
    }
    await waitUntil(
      sim,
      () => axi.ar.idleNow && axi.rBeats.length == axi.readBeatsExpected,
    );
    await sim.stop();

    expect(errors, isEmpty);
    expect(mem.writes, isEmpty);
    expect(_checkReads(axi, mem, _cfg.strbWidth), isEmpty);
    expect(mem.maxInflight, _cfg.outstanding);
  });

  test('a read-only slave port crosses a fabric clock', () async {
    final ms = MultiSim(_ReadOnlyCdcShell(_cfg), const Ratio(20, 22, 18));
    await ms.start();
    final rng = Random(2);
    final axi = AxiManager(ms.fabric, 'bus', rng, readOnly: true);
    final errors = <String>[];
    final mem = WaistMemory(
      ms.b,
      'mem',
      rng,
      outstanding: _cfg.outstanding,
      busBytes: _cfg.strbWidth,
      errors: errors,
    );
    final gen = BurstGen(rng, busBytes: _cfg.strbWidth, idWidth: _cfg.idWidth);

    for (var i = 0; i < 80; i++) {
      axi.read(gen.next(write: false));
    }
    await waitUntil(
      ms.fabric,
      () => axi.ar.idleNow && axi.rBeats.length == axi.readBeatsExpected,
    );
    await Simulator.endSimulation();

    expect(errors, isEmpty);
    expect(_checkReads(axi, mem, _cfg.strbWidth), isEmpty);
  });

  test('readOnly exists only on AXI4', () {
    for (final kind in [HarborFabricKind.wishbone, HarborFabricKind.tilelink]) {
      expect(
        () => MemSlaveShell(_cfg, kind: kind, readOnly: true),
        throwsArgumentError,
        reason: kind.name,
      );
    }
  });
}
