import 'dart:collection';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../port/memory_harness.dart';
import '../port/port_harness.dart';

export '../port/cdc_harness.dart' show isolated, must;

const addrW = 20;
const dataW = 32;
const busBytes = dataW ~/ 8;

/// Addresses at or above this hit no slave.
const unmapped = 0x80000;

class MasterCfg {
  final String name;
  final int idWidth;
  final int outstanding;

  /// The port is AXI4-Lite and [idWidth] is not used.
  final bool lite;

  /// This master's explicit read channel at every multi-channel slave it
  /// reaches. Null spreads it round robin.
  final int? readChannel;
  const MasterCfg(
    this.name,
    this.idWidth,
    this.outstanding, {
    this.lite = false,
    this.readChannel,
  });
}

class SlaveCfg {
  final String name;
  final int idWidth;
  final int outstanding;
  final int base;
  final int size;
  final int timeout;

  /// The port is AXI4-Lite and [idWidth] is not used.
  final bool lite;

  /// Read channels on this slave: 1 is the full port alone, 2 or more adds
  /// read-only ports.
  final int readChannels;
  const SlaveCfg(
    this.name,
    this.idWidth,
    this.outstanding,
    this.base,
    this.size, {
    this.timeout = 0,
    this.lite = false,
    this.readChannels = 1,
  });
}

PairInterface _intf(int idWidth, bool lite) => lite
    ? Axi4LiteInterface(addressWidth: addrW, dataWidth: dataW)
    : Axi4Interface(addressWidth: addrW, dataWidth: dataW, idWidth: idWidth);

/// Three masters and three slaves with different ID widths and outstanding
/// limits. s0 needs no remap, s1 and s2 do. s2 has a timeout that busy
/// traffic must never reach.
const masters3 = [
  MasterCfg('m0', 2, 4),
  MasterCfg('m1', 3, 8),
  MasterCfg('m2', 1, 2),
];
const slaves3 = [
  SlaveCfg('s0', 5, 8, 0x00000, 0x10000),
  SlaveCfg('s1', 1, 2, 0x10000, 0x10000),
  SlaveCfg('s2', 3, 4, 0x20000, 0x8000, timeout: 64),
];

// Brings an interface out to ports `<name>_*`. [drive] is the direction
// the test drives.
void exposeInterface(
  BridgeModule m,
  PairInterface intf,
  String name,
  PairDirection drive,
) {
  final other = drive == PairDirection.fromProvider
      ? PairDirection.fromConsumer
      : PairDirection.fromProvider;
  for (final e in intf.getPorts([drive]).entries) {
    m.createPort('${name}_${e.key}', PortDirection.input, width: e.value.width);
    e.value <= m.input('${name}_${e.key}');
  }
  for (final e in intf.getPorts([other]).entries) {
    m.createPort(
      '${name}_${e.key}',
      PortDirection.output,
      width: e.value.width,
    );
    m.output('${name}_${e.key}') <= e.value;
  }
}

/// An AXI4 fabric with every master and slave port out on `<name>_*`.
class FabricShell extends BridgeModule {
  late final HarborFabricModule fabric;

  FabricShell(
    HarborFabricTopology topology, {
    List<MasterCfg> masters = masters3,
    List<SlaveCfg> slaves = slaves3,
  }) : super('FabricTestShell_${topology.name}', name: 'shell') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final ms = <HarborFabricMaster>[];
    for (final m in masters) {
      final intf = _intf(m.idWidth, m.lite);
      exposeInterface(this, intf, m.name, PairDirection.fromProvider);
      ms.add(
        HarborFabricMaster(
          name: m.name,
          interface: intf,
          outstanding: m.outstanding,
          memory: !m.lite,
          readChannel: m.readChannel,
        ),
      );
    }
    final ss = <HarborFabricSlave>[];
    for (final s in slaves) {
      final intf = _intf(s.idWidth, s.lite);
      exposeInterface(this, intf, s.name, PairDirection.fromConsumer);
      final readIntfs = <PairInterface>[];
      for (var k = 1; k < s.readChannels; k++) {
        final ri = Axi4ReadOnlyInterface(
          addressWidth: addrW,
          dataWidth: dataW,
          idWidth: s.idWidth,
        );
        exposeInterface(this, ri, '${s.name}_r$k', PairDirection.fromConsumer);
        readIntfs.add(ri);
      }
      ss.add(
        HarborFabricSlave(
          name: s.name,
          range: BusAddressRange(s.base, s.size),
          interface: intf,
          outstanding: s.outstanding,
          timeout: s.timeout,
          memory: !s.lite,
          readInterfaces: readIntfs,
        ),
      );
    }
    fabric = HarborFabric.build(
      kind: HarborFabricKind.axi4,
      topology: topology,
      clk: input('clk'),
      reset: input('reset'),
      masters: ms,
      slaves: ss,
    );
    createPort('bus_error', PortDirection.output);
    output('bus_error') <= fabric.busError;
  }
}

/// A test bench: the shell, a manager per master and a memory per slave.
class Bench {
  final Sim sim;
  final List<MasterCfg> masterCfgs;
  final List<SlaveCfg> slaveCfgs;
  final Map<String, AxiManager> managers = {};
  final Map<String, AxiMemory> memories = {};

  /// Extra read-only ports of a slave with [SlaveCfg.readChannels] over 1,
  /// by slave name, sharing the full port's memory.
  final Map<String, List<AxiReadMemory>> readMemories = {};
  final List<String> errors = [];
  final Random rng;

  Bench._(this.sim, this.masterCfgs, this.slaveCfgs, this.rng);

  /// Builds and starts a bench. [stall] is the VALID gap and READY stall
  /// chance of the test side.
  static Future<Bench> start(
    HarborFabricTopology topology, {
    List<MasterCfg> masters = masters3,
    List<SlaveCfg> slaves = slaves3,
    int seed = 1,
    double stall = 0.3,
    int maxTime = 4000000,
  }) async {
    final shell = FabricShell(topology, masters: masters, slaves: slaves);
    final sim = Sim(shell);
    final rng = Random(seed);
    final b = Bench._(sim, masters, slaves, rng);
    for (final m in masters) {
      b.managers[m.name] = AxiManager(
        sim,
        m.name,
        rng,
        awIdle: stall,
        wIdle: stall / 3,
        arIdle: stall,
        stall: stall,
        lite: m.lite,
      );
    }
    for (final s in slaves) {
      b.memories[s.name] = AxiMemory(
        sim,
        s.name,
        rng,
        busBytes: busBytes,
        outstanding: s.outstanding,
        errors: b.errors,
        errBase: 1 << 40,
        stall: stall,
        lite: s.lite,
      );
      // Requests stay in the region and every response holds until taken.
      final fields = s.lite ? ['ADDR'] : ['ID', 'ADDR', 'LEN', 'SIZE', 'BURST'];
      for (final ch in ['AW', 'AR']) {
        StableCheck(sim, '${s.name}_${ch}VALID', '${s.name}_${ch}READY', [
          for (final f in fields) '${s.name}_$ch$f',
        ], b.errors);
      }
      StableCheck(sim, '${s.name}_WVALID', '${s.name}_WREADY', [
        '${s.name}_WDATA',
        '${s.name}_WSTRB',
        if (!s.lite) '${s.name}_WLAST',
      ], b.errors);
      final extras = <AxiReadMemory>[];
      for (var k = 1; k < s.readChannels; k++) {
        final p = '${s.name}_r$k';
        extras.add(
          AxiReadMemory(
            sim,
            p,
            rng,
            busBytes: busBytes,
            outstanding: s.outstanding,
            errors: b.errors,
            mem: b.memories[s.name]!.mem,
            errBase: 1 << 40,
            stall: stall,
          ),
        );
        StableCheck(sim, '${p}_ARVALID', '${p}_ARREADY', [
          for (final f in fields) '${p}_AR$f',
        ], b.errors);
      }
      b.readMemories[s.name] = extras;
    }
    for (final m in masters) {
      StableCheck(sim, '${m.name}_BVALID', '${m.name}_BREADY', [
        if (!m.lite) '${m.name}_BID',
        '${m.name}_BRESP',
      ], b.errors);
      StableCheck(sim, '${m.name}_RVALID', '${m.name}_RREADY', [
        if (!m.lite) '${m.name}_RID',
        '${m.name}_RDATA',
        '${m.name}_RRESP',
        if (!m.lite) '${m.name}_RLAST',
      ], b.errors);
    }
    await sim.start();
    Simulator.setMaxSimTime(maxTime);
    return b;
  }

  int busError() => sim.pre('bus_error');

  /// Waits until every manager has all its responses.
  Future<void> drain({int limit = 30000}) => waitUntil(
    sim,
    () => managers.values.every(
      (m) =>
          m.aw.idleNow &&
          m.bResp.length == m.awOrder.length &&
          m.ar.idleNow &&
          m.rBeats.length == m.readBeatsExpected,
    ),
    limit: limit,
  );

  /// Slave index of [addr], or null when it is unmapped.
  int? slaveOf(int addr) {
    for (var i = 0; i < slaveCfgs.length; i++) {
      final s = slaveCfgs[i];
      if (addr >= s.base && addr < s.base + s.size) return i;
    }
    return null;
  }

  /// The response code [x] must get: DECERR when unmapped, SLVERR for a
  /// burst or a narrow access to an AXI4-Lite slave.
  int respOf(Burst x) {
    final s = slaveOf(x.addr);
    if (s == null) return 3;
    final full = busBytes.bitLength - 1;
    if (slaveCfgs[s].lite && (x.len != 0 || x.size != full)) return 2;
    return 0;
  }

  /// The memory of each slave after every write that must succeed.
  List<WordMemory> golden() {
    final out = [for (final _ in slaveCfgs) WordMemory(busBytes)];
    for (final m in managers.values) {
      for (final x in m.awOrder) {
        if (respOf(x) != 0) continue;
        final addrs = beatAddrs(x.addr, x.len, x.size, x.burst);
        for (var i = 0; i < x.beats; i++) {
          out[slaveOf(x.addr)!].write(addrs[i], x.data[i], x.strb[i]);
        }
      }
    }
    return out;
  }

  /// Every request each slave took lies inside its region.
  void checkRegions() {
    for (final s in slaveCfgs) {
      final m = memories[s.name]!;
      for (final x in [...m.awOrder, ...m.arOrder]) {
        if (x.addr < s.base || x.addr >= s.base + s.size) {
          errors.add('${s.name} got $x outside its region');
        }
      }
    }
  }
}

/// [b] moved up by [base].
Burst moved(Burst b, int base) => Burst(
  id: b.id,
  write: b.write,
  addr: b.addr + base,
  len: b.len,
  size: b.size,
  burst: b.burst,
  data: b.data,
  strb: b.strb,
);

/// Expected response code and data per beat of a read.
typedef ReadWant = (int resp, List<int>? data);

/// Checks one master's R beats against [want], matching each beat to the
/// oldest read of its ID still open. Returns mismatches.
List<String> checkReads(
  String name,
  List<Burst> issued,
  List<(int, int, int, int)> beats,
  ReadWant Function(Burst) want,
) {
  final out = <String>[];
  final open = <int, Queue<(Burst, int)>>{};
  for (final b in issued) {
    open.putIfAbsent(b.id, Queue.new).add((b, 0));
  }
  for (final (id, data, resp, last) in beats) {
    final q = open[id];
    if (q == null || q.isEmpty) {
      out.add('$name: R beat for id $id with no read open');
      continue;
    }
    final (b, i) = q.removeFirst();
    final (wResp, wData) = want(b);
    if (resp != wResp) out.add('$name: $b beat $i resp $resp, want $wResp');
    if (wData != null && data != wData[i]) {
      out.add(
        '$name: $b beat $i data 0x${data.toRadixString(16)}, want '
        '0x${wData[i].toRadixString(16)}',
      );
    }
    final isLast = i == b.len;
    if ((last == 1) != isLast) out.add('$name: $b beat $i RLAST $last');
    if (!isLast) q.addFirst((b, i + 1));
  }
  for (final e in open.entries) {
    if (e.value.isNotEmpty) {
      out.add('$name: id ${e.key} has ${e.value.length} read(s) open');
    }
  }
  return out;
}

/// Checks one master's B responses: per ID in issue order with [want].
List<String> checkWrites(
  String name,
  List<Burst> issued,
  List<(int, int)> got,
  int Function(Burst) want,
) => [
  for (final e in diffPerId<Burst, (int, int)>(
    want: issued,
    got: got,
    wantId: (b) => b.id,
    gotId: (g) => g.$1,
    matches: (b, g) => g.$2 == want(b),
  ))
    '$name: $e',
];
