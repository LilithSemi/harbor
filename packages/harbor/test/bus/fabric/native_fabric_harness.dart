import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../port/memory_harness.dart';
import '../port/memory_native_harness.dart';
import '../port/port_harness.dart';
import 'axi4_fabric_harness.dart';

export '../port/cdc_harness.dart' show isolated, must;
export 'axi4_fabric_harness.dart' show addrW, busBytes, dataW, unmapped;

/// A port of a TileLink or Wishbone fabric under test.
///
/// - TileLink: [width] is the source width, and [memory] picks TL-UH (size
///   width 4) or TL-UL (size width 3).
/// - Wishbone: [memory] gives ERR, CTI and BTE. A register port has ERR
///   when [err] is set.
class PortCfg {
  final String name;
  final int width;
  final int outstanding;
  final bool memory;
  final bool err;
  final int base;
  final int size;
  final int timeout;

  /// Slaves a master reaches, or null for all.
  final Set<String>? reach;

  const PortCfg(
    this.name, {
    this.width = 1,
    this.outstanding = 1,
    this.memory = true,
    this.err = true,
    this.base = 0,
    this.size = 0,
    this.timeout = 0,
    this.reach,
  });

  BusAddressRange get range => BusAddressRange(base, size);
  bool hits(int addr) => addr >= base && addr < base + size;
}

PairInterface portIntf(HarborFabricKind kind, PortCfg p) => switch (kind) {
  HarborFabricKind.tilelink => TileLinkInterface(
    TileLinkConfig(
      addressWidth: addrW,
      dataWidth: dataW,
      sizeWidth: p.memory ? 4 : 3,
      sourceWidth: p.width,
    ),
  ),
  HarborFabricKind.wishbone => WishboneInterface(
    WishboneConfig(
      addressWidth: addrW,
      dataWidth: dataW,
      useErr: p.memory || p.err,
      useCti: p.memory,
      useBte: p.memory,
    ),
  ),
  HarborFabricKind.axi4 => throw UnsupportedError('use FabricShell'),
};

/// A TileLink or Wishbone fabric with every port out on `<name>_*`.
class NativeShell extends BridgeModule {
  late final HarborFabricModule fabric;

  NativeShell(
    HarborFabricKind kind,
    HarborFabricTopology topology, {
    required List<PortCfg> masters,
    required List<PortCfg> slaves,
    int? maxGrantCycles,
    int burstBeats = 8,
  }) : super('NativeFabricShell_${kind.name}_${topology.name}', name: 'shell') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final ms = <HarborFabricMaster>[];
    for (final m in masters) {
      final intf = portIntf(kind, m);
      exposeInterface(this, intf, m.name, PairDirection.fromProvider);
      ms.add(
        HarborFabricMaster(
          name: m.name,
          interface: intf,
          outstanding: m.outstanding,
          memory: m.memory,
          reach: m.reach,
        ),
      );
    }
    final ss = <HarborFabricSlave>[];
    for (final s in slaves) {
      final intf = portIntf(kind, s);
      exposeInterface(this, intf, s.name, PairDirection.fromConsumer);
      ss.add(
        HarborFabricSlave(
          name: s.name,
          range: s.range,
          interface: intf,
          outstanding: s.outstanding,
          timeout: s.timeout,
          memory: s.memory,
        ),
      );
    }
    fabric = HarborFabric.build(
      kind: kind,
      topology: topology,
      clk: input('clk'),
      reset: input('reset'),
      masters: ms,
      slaves: ss,
      maxGrantCycles: maxGrantCycles,
      wishboneBurstBeats: burstBeats,
    );
    createPort('bus_error', PortDirection.output);
    output('bus_error') <= fabric.busError;
    if (fabric.foldError case final fold?) {
      createPort('fold_error', PortDirection.output);
      output('fold_error') <= fold;
    }
  }
}

// ---------------------------------------------------------------------------
// TileLink

/// TL-UH masters with 4 and 8 sources and a TL-UL master with 2. Their
/// limits are below their source counts for m1.
const tlMasters = [
  PortCfg('m0', width: 2, outstanding: 4),
  PortCfg('m1', width: 3, outstanding: 6),
  PortCfg('m2', width: 1, outstanding: 2, memory: false),
];

/// s0 needs no remap. s1 and s3 remap, s1 has a timeout busy traffic never
/// reaches, and s2 is TL-UL.
const tlSlaves = [
  PortCfg('s0', width: 5, outstanding: 8, base: 0x00000, size: 0x8000),
  PortCfg(
    's1',
    width: 1,
    outstanding: 2,
    base: 0x10000,
    size: 0x8000,
    timeout: 64,
  ),
  PortCfg(
    's2',
    width: 1,
    outstanding: 2,
    base: 0x20000,
    size: 0x1000,
    memory: false,
  ),
  PortCfg('s3', width: 2, outstanding: 4, base: 0x30000, size: 0x8000),
];

/// The D opcode that answers A opcode [op].
int tlRespOp(int op) => switch (op) {
  tlGet || tlArithmetic || tlLogical => tlAccessAckData,
  tlIntent => tlHintAck,
  _ => tlAccessAck,
};

/// One expected D beat as (opcode, data, denied, corrupt).
typedef WantBeat = (int, int, int, int);

/// Layout of a slave in the tests: a page per master, a read only area per
/// master, and an error area at the top.
class TlLayout {
  final PortCfg s;
  const TlLayout(this.s);
  int get page => s.memory ? 0x800 : 0x100;
  int get errBase => s.base + (s.memory ? s.size - 0x1000 : 0x800);
  int pageOf(int m) => s.base + m * page;
  int readOnly(int m) => s.base + (s.memory ? 0x2000 : 0x400) + m * page;
}

/// A TileLink fabric with a manager per master and a memory per slave.
class TlBench {
  final Sim sim;
  final List<PortCfg> masterCfgs;
  final List<PortCfg> slaveCfgs;
  final Map<String, TlManager> managers = {};
  final Map<String, TlMemory> memories = {};
  final List<String> errors = [];
  final Random rng;

  /// What each message must get back.
  final Map<TlMsg, List<WantBeat>> want = {};

  /// The memory of each slave after the Puts sent so far.
  final Map<String, WordMemory> golden = {};

  TlBench._(this.sim, this.masterCfgs, this.slaveCfgs, this.rng);

  static Future<TlBench> start(
    HarborFabricTopology topology, {
    List<PortCfg> masters = tlMasters,
    List<PortCfg> slaves = tlSlaves,
    int seed = 1,
    double stall = 0.3,
    int maxTime = 8000000,
  }) async {
    final shell = NativeShell(
      HarborFabricKind.tilelink,
      topology,
      masters: masters,
      slaves: slaves,
    );
    final sim = Sim(shell);
    final rng = Random(seed);
    final b = TlBench._(sim, masters, slaves, rng);
    for (final m in masters) {
      b.managers[m.name] = TlManager(
        sim,
        m.name,
        rng,
        sources: 1 << m.width,
        busBytes: busBytes,
        errors: b.errors,
        idle: stall,
        stall: stall,
      );
    }
    for (final s in slaves) {
      b.memories[s.name] = TlMemory(
        sim,
        s.name,
        rng,
        busBytes: busBytes,
        errors: b.errors,
        errBase: TlLayout(s).errBase,
        stall: stall,
      );
      b.golden[s.name] = WordMemory(busBytes);
    }
    await sim.start();
    Simulator.setMaxSimTime(maxTime);
    return b;
  }

  int busError() => sim.pre('bus_error');

  Future<void> drain({int limit = 200000}) =>
      waitUntil(sim, () => managers.values.every((m) => m.done), limit: limit);

  PortCfg? slaveOf(int addr) {
    for (final s in slaveCfgs) {
      if (s.hits(addr)) return s;
    }
    return null;
  }

  /// True when the fabric takes [m] to its slave.
  bool fits(TlMsg m) {
    final s = slaveOf(m.addr);
    if (s == null) return false;
    if (s.memory) return m.op < tlAcquire && m.size <= 15;
    return (m.op == tlGet || m.isPut) && m.size <= log2(busBytes);
  }

  /// Sends [m] from master [master] and records what it must get back.
  void send(String master, TlMsg m) {
    want[m] = expect(m);
    managers[master]!.send(m);
  }

  /// The D beats [m] must get, given the Puts sent before it.
  List<WantBeat> expect(TlMsg m) {
    final op = tlRespOp(m.op);
    final n = op == tlAccessAckData ? tlBeats(m.size, busBytes) : 1;
    if (!fits(m)) {
      return [for (var i = 0; i < n; i++) (op, 0, 1, op == 1 ? 1 : 0)];
    }
    final s = slaveOf(m.addr)!;
    final eb = TlLayout(s).errBase;
    final region = m.addr < eb
        ? 0
        : m.addr < eb + 0x800
        ? 1
        : 2;
    final g = golden[s.name]!;
    if (m.op == tlGet) {
      return [
        for (var i = 0; i < n; i++)
          (
            tlAccessAckData,
            region == 0 ? g.read(m.addr + i * busBytes) : 0,
            region == 1 ? 1 : 0,
            region == 0 ? 0 : 1,
          ),
      ];
    }
    if (region == 0) {
      for (var i = 0; i < m.data.length; i++) {
        g.write(m.addr + i * busBytes, m.data[i], m.mask[i]);
      }
    }
    return [(tlAccessAck, 0, region == 0 ? 0 : 1, 0)];
  }

  /// Mismatches between what each message got and [want].
  List<String> checkResponses() {
    final out = <String>[];
    for (final e in want.entries) {
      final m = e.key;
      final got = [for (final d in m.d) (d.$1, d.$4, d.$5, d.$6)];
      if (got.toString() != e.value.toString()) {
        out.add('$m got $got want ${e.value}');
      }
      if (m.d.any((d) => d.$2 != m.size)) out.add('$m D size');
    }
    return out;
  }

  /// Mismatches between each slave memory and [golden].
  List<String> checkMemories() => [
    for (final s in slaveCfgs)
      ...diffMemory(
        golden[s.name]!,
        memories[s.name]!.mem,
      ).map((x) => '${s.name} $x'),
  ];
}

/// A random message from master [m] (index [mi]) in the bench's layout.
TlMsg tlRandom(TlBench b, PortCfg m, int mi) {
  final rng = b.rng;
  final bl = log2(busBytes);
  final uh = [
    for (final s in b.slaveCfgs)
      if (s.memory) s,
  ];
  final ul = [
    for (final s in b.slaveCfgs)
      if (!s.memory) s,
  ];
  int data() => rng.nextInt(1 << 32);
  int at(int base, int span, int size) =>
      (base + rng.nextInt(span)) & ~((1 << size) - 1);
  TlMsg msg(int op, int size, int addr) {
    final lanes = laneMask(addr, size, busBytes);
    if (op == tlGet || op == tlIntent) {
      return TlMsg(op: op, size: size, addr: addr, mask: [lanes]);
    }
    final n = tlBeats(size, busBytes);
    return TlMsg(
      op: op,
      size: size,
      addr: addr,
      data: [for (var i = 0; i < n; i++) data()],
      mask: [
        for (var i = 0; i < n; i++)
          op == tlPutPartial ? lanes & rng.nextInt(1 << busBytes) : lanes,
      ],
    );
  }

  int legalOp() => [tlGet, tlGet, tlPutFull, tlPutPartial][rng.nextInt(4)];
  final maxSize = m.memory ? bl + 4 : bl;
  final r = rng.nextDouble();
  if (r < 0.45 && uh.isNotEmpty) {
    final l = TlLayout(uh[rng.nextInt(uh.length)]);
    final size = rng.nextInt(maxSize + 1);
    return msg(legalOp(), size, at(l.pageOf(mi), l.page, size));
  }
  if (r < 0.6 && uh.isNotEmpty) {
    final l = TlLayout(uh[rng.nextInt(uh.length)]);
    final size = rng.nextInt(maxSize + 1);
    return msg(tlGet, size, at(l.readOnly(mi), l.page, size));
  }
  if (r < 0.75 && ul.isNotEmpty) {
    final l = TlLayout(ul[rng.nextInt(ul.length)]);
    if (!m.memory || rng.nextDouble() < 0.6) {
      final size = rng.nextInt(bl + 1);
      return msg(legalOp(), size, at(l.pageOf(mi), l.page, size));
    }
    final op = [
      tlGet,
      tlPutFull,
      tlArithmetic,
      tlLogical,
      tlIntent,
    ][rng.nextInt(5)];
    final size = op == tlGet || op == tlPutFull
        ? bl + 1 + rng.nextInt(3)
        : rng.nextInt(bl + 3);
    return msg(op, size, at(l.pageOf(mi), l.page, size));
  }
  if (r < 0.85 && uh.isNotEmpty) {
    final l = TlLayout(uh[rng.nextInt(uh.length)]);
    final size = rng.nextInt(maxSize + 1);
    return msg(legalOp(), size, at(l.errBase, 0x1000, size));
  }
  if (r < 0.9 && ul.isNotEmpty) {
    final l = TlLayout(ul[rng.nextInt(ul.length)]);
    final size = rng.nextInt(bl + 1);
    return msg(legalOp(), size, at(l.errBase, 0x800, size));
  }
  final ops = m.memory
      ? [tlGet, tlPutFull, tlPutPartial, tlArithmetic, tlLogical, tlIntent]
      : [tlGet, tlPutFull, tlPutPartial];
  final size = rng.nextInt(maxSize + 1);
  return msg(ops[rng.nextInt(ops.length)], size, at(unmapped, 0x1000, size));
}

// ---------------------------------------------------------------------------
// Wishbone

/// Two burst masters and a classic master with no ERR.
const wbMasters = [
  PortCfg('m0'),
  PortCfg('m1'),
  PortCfg('m2', memory: false, err: false),
];

/// A memory slave, a memory slave with a timeout busy traffic never
/// reaches, and a classic register slave with no ERR.
const wbSlaves = [
  PortCfg('s0', base: 0x00000, size: 0x8000),
  PortCfg('s1', base: 0x10000, size: 0x8000, timeout: 64),
  PortCfg('s2', base: 0x20000, size: 0x1000, memory: false, err: false),
];

/// One answered beat a slave saw: (master, address).
typedef WbSeen = (int, int);

/// A Wishbone fabric with a master per master port and a memory per slave.
class WbBench {
  final Sim sim;
  final List<PortCfg> masterCfgs;
  final List<PortCfg> slaveCfgs;
  final Map<String, WbMaster> managers = {};
  final Map<String, WbMemory> memories = {};
  final Random rng;

  /// The memory of each slave after the writes sent so far.
  final Map<String, WordMemory> golden = {};

  /// What each beat must get back as (ack, err, data). Data is null for a
  /// write.
  final Map<WbBeat, (int, int, int?)> want = {};

  WbBench._(this.sim, this.masterCfgs, this.slaveCfgs, this.rng);

  static Future<WbBench> start(
    HarborFabricTopology topology, {
    List<PortCfg> masters = wbMasters,
    List<PortCfg> slaves = wbSlaves,
    int seed = 1,
    double gap = 0.2,
    double keepCyc = 0.3,
    double wait = 0.3,
    int? maxGrantCycles,
    int maxTime = 8000000,
  }) async {
    final shell = NativeShell(
      HarborFabricKind.wishbone,
      topology,
      masters: masters,
      slaves: slaves,
      maxGrantCycles: maxGrantCycles,
    );
    final sim = Sim(shell);
    final rng = Random(seed);
    final b = WbBench._(sim, masters, slaves, rng);
    for (final m in masters) {
      b.managers[m.name] = WbMaster(
        sim,
        m.name,
        rng,
        gap: gap,
        keepCyc: keepCyc,
      );
    }
    for (final s in slaves) {
      b.memories[s.name] = WbMemory(
        sim,
        s.name,
        rng,
        busBytes: busBytes,
        errBase: wbErrBase(s),
        wait: wait,
      );
      b.golden[s.name] = WordMemory(busBytes);
    }
    await sim.start();
    Simulator.setMaxSimTime(maxTime);
    return b;
  }

  int busError() => sim.pre('bus_error');

  int foldError() => sim.pre('fold_error');

  Future<void> drain({int limit = 200000}) =>
      waitUntil(sim, () => managers.values.every((m) => m.done), limit: limit);

  PortCfg? slaveOf(int addr) {
    for (final s in slaveCfgs) {
      if (s.hits(addr)) return s;
    }
    return null;
  }

  /// Sends [t] from master [mi] and records what each beat must get back.
  void send(int mi, WbTxn t) {
    final m = masterCfgs[mi];
    final mErr = m.memory || m.err;
    for (final x in t.beats) {
      final hit = slaveOf(x.addr);
      final s = (m.reach?.contains(hit?.name) ?? true) ? hit : null;
      final bad = s == null || x.addr >= wbErrBase(s);
      if (bad) {
        // An unmapped beat reads 0 and a slave error reads poison.
        want[x] = mErr ? (0, 1, null) : (1, 0, s == null ? 0 : 0xDEADBEEF);
        // The cycle ends at the first error.
        break;
      }
      final g = golden[s.name]!;
      if (t.write) {
        g.write(x.addr, x.data, x.sel);
        want[x] = (1, 0, null);
      } else {
        want[x] = (1, 0, g.read(x.addr));
      }
    }
    managers[m.name]!.queue.add(t);
  }

  /// Mismatches between what each beat got and [want].
  List<String> checkBeats() {
    final out = <String>[];
    for (final m in managers.values) {
      for (final t in m.finished) {
        for (var i = 0; i < t.done; i++) {
          final x = t.beats[i];
          final w = want[x];
          if (w == null) {
            out.add('$t beat $i ran after an error');
            continue;
          }
          final dataOk = w.$3 == null || x.rdata == w.$3 || t.write;
          if (x.ack != w.$1 || x.err != w.$2 || !dataOk) {
            out.add('$t beat $x want $w');
          }
        }
        final last = t.done == 0 ? null : t.beats[t.done - 1];
        final ended = last != null && want[last]?.$2 == 1;
        final cut = t.done < t.beats.length;
        if (cut && !ended && t.abortAfter == null && !t.gaveUp) {
          out.add('$t ended early');
        }
      }
    }
    return out;
  }

  /// Mismatches between each slave memory and [golden].
  List<String> checkMemories() => [
    for (final s in slaveCfgs)
      ...diffMemory(
        golden[s.name]!,
        memories[s.name]!.mem,
      ).map((x) => '${s.name} $x'),
  ];
}

/// The error area of a Wishbone test slave: the top 0x400 bytes, or none
/// when the slave has no ERR.
int wbErrBase(PortCfg s) =>
    s.memory || s.err ? s.base + s.size - 0x400 : 1 << 40;

/// The page of master [mi] in slave [s].
int wbPage(PortCfg s, int mi) => s.base + mi * (s.memory ? 0x800 : 0x100);

/// The read only area of master [mi] in slave [s].
int wbReadOnly(PortCfg s, int mi) =>
    s.base + (s.memory ? 0x2000 : 0x400) + mi * (s.memory ? 0x800 : 0x100);

/// The master whose page or read only area holds [addr], by the layout.
int wbOwner(PortCfg s, int addr) {
  final span = s.memory ? 0x800 : 0x100;
  final off = addr - s.base;
  final ro = s.memory ? 0x2000 : 0x400;
  return off >= ro ? (off - ro) ~/ span : off ~/ span;
}

/// A random Wishbone cycle from master [mi] in the bench's layout.
WbTxn wbRandom(WbBench b, int mi) {
  final rng = b.rng;
  final m = b.masterCfgs[mi];
  final write = rng.nextBool();
  final mode = m.memory && rng.nextDouble() < 0.6
      ? WbMode.burst
      : WbMode.classic;
  final n = mode == WbMode.burst ? 1 + rng.nextInt(8) : 1;
  final s = b.slaveCfgs[rng.nextInt(b.slaveCfgs.length)];
  final r = rng.nextDouble();
  int start;
  var w = write;
  if (r < 0.08) {
    start = unmapped + rng.nextInt(0x100) * busBytes;
  } else if (r < 0.16 && (s.memory || s.err)) {
    start = wbErrBase(s) + rng.nextInt(0x40) * busBytes;
  } else if (r < 0.4) {
    w = false;
    start = wbReadOnly(s, mi) + rng.nextInt(0x20) * busBytes;
  } else {
    start = wbPage(s, mi) + rng.nextInt(0x20) * busBytes;
  }
  return WbTxn(w, mode, [
    for (var i = 0; i < n; i++)
      WbBeat(
        start + i * busBytes,
        data: rng.nextInt(1 << 32),
        sel: w ? 1 + rng.nextInt(15) : 0xf,
      ),
  ]);
}
