import 'dart:collection';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'port_harness.dart';

const _reqFields = [
  'REQ_ID',
  'REQ_WRITE',
  'REQ_ADDR',
  'REQ_LEN',
  'REQ_SIZE',
  'REQ_BURST',
];

/// Brings a memory waist out to ports named `<name>_*`.
void exposeWaist(
  BridgeModule m,
  HarborMemoryWaist waist,
  String name,
  PairRole role,
) {
  final intf = m
      .addInterface(HarborMemoryWaist(waist.config), name: name, role: role)
      .internalInterface!;
  final out = role == PairRole.provider
      ? PairDirection.fromProvider
      : PairDirection.fromConsumer;
  for (final p in waist.getPorts([out]).keys) {
    intf.port(p) <= waist.port(p);
  }
  final inDir = role == PairRole.provider
      ? PairDirection.fromConsumer
      : PairDirection.fromProvider;
  for (final p in waist.getPorts([inDir]).keys) {
    waist.port(p) <= intf.port(p);
  }
}

String _cfgName(HarborMemoryWaistConfig c) =>
    'a${c.addressWidth}_d${c.dataWidth}_i${c.idWidth}_n${c.outstanding}';

/// A memory slave port of [kind] with its waist on ports `mem_*`.
class MemSlaveShell extends BridgeModule {
  late final HarborMemorySlavePort mem;

  MemSlaveShell(
    HarborMemoryWaistConfig config, {
    HarborFabricKind kind = HarborFabricKind.axi4,
    int burstBeats = 8,
  }) : super(
         'MemTestSlaveShell_${kind.name}_${_cfgName(config)}_b$burstBeats',
         name: 'shell',
       ) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    mem = HarborMemorySlavePort.create(
      module: this,
      name: 'bus',
      kind: kind,
      config: config,
      clk: input('clk'),
      reset: input('reset'),
      wishboneBurstBeats: burstBeats,
    );
    exposeWaist(this, mem.waist, 'mem', PairRole.provider);
  }
}

/// A memory master port of [kind] with its waist on ports `mem_*`.
class MemMasterShell extends BridgeModule {
  late final HarborMemoryMasterPort mem;

  MemMasterShell(
    HarborMemoryWaistConfig config, {
    HarborFabricKind kind = HarborFabricKind.axi4,
  }) : super(
         'MemTestMasterShell_${kind.name}_${_cfgName(config)}',
         name: 'shell',
       ) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    mem = HarborMemoryMasterPort.create(
      module: this,
      name: 'bus',
      kind: kind,
      config: config,
      clk: input('clk'),
      reset: input('reset'),
    );
    exposeWaist(this, mem.waist, 'mem', PairRole.consumer);
  }
}

/// A memory slave port of [kind] wired to a zero-latency device, on ports
/// `bus_*`. The device answers a 1-beat request in the same cycle as its
/// REQ: REQ_READY and WDATA_READY are always high, and RDATA/WRESP follow
/// REQ_VALID combinationally. It never issues more than one beat, so it
/// only fits requests of LEN 0.
class MemSlaveCombShell extends BridgeModule {
  late final HarborMemorySlavePort mem;

  MemSlaveCombShell(
    HarborMemoryWaistConfig config, {
    HarborFabricKind kind = HarborFabricKind.axi4,
  }) : super(
         'MemTestSlaveCombShell_${kind.name}_${_cfgName(config)}',
         name: 'shell',
       ) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    mem = HarborMemorySlavePort.create(
      module: this,
      name: 'bus',
      kind: kind,
      config: config,
      clk: input('clk'),
      reset: input('reset'),
    );
    final w = mem.waist;
    final dataW = config.dataWidth;
    w.reqReady <= Const(1);
    w.wdataReady <= Const(1);
    w.rdataValid <= w.reqValid & ~w.reqWrite;
    w.rdataId <= w.reqId;
    w.rdataData <=
        (w.reqAddr.width > dataW
            ? w.reqAddr.getRange(0, dataW)
            : w.reqAddr.zeroExtend(dataW));
    w.rdataErr <= Const(0);
    w.rdataLast <= Const(1);
    w.wrespValid <= w.reqValid & w.reqWrite;
    w.wrespId <= w.reqId;
    w.wrespErr <= Const(0);
  }
}

/// A master port wired straight to a slave port, both of [kind]. The
/// requester waist is on ports `up_*` and the memory waist on ports `mem_*`.
class MemLoopShell extends BridgeModule {
  MemLoopShell(
    HarborMemoryWaistConfig config, {
    HarborFabricKind kind = HarborFabricKind.axi4,
    int burstBeats = 8,
  }) : super(
         'MemTestLoopShell_${kind.name}_${_cfgName(config)}_b$burstBeats',
         name: 'shell',
       ) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final clk = input('clk');
    final reset = input('reset');
    final up = HarborMemoryWaist(config);
    final down = HarborMemoryWaist(config);
    switch (kind) {
      case HarborFabricKind.axi4:
        final link = Axi4Interface(
          addressWidth: config.addressWidth,
          dataWidth: config.dataWidth,
          idWidth: config.idWidth,
        );
        HarborAxi4MemoryMaster(clk: clk, reset: reset, waist: up, axi: link);
        HarborAxi4MemorySlave(clk: clk, reset: reset, axi: link, waist: down);
      case HarborFabricKind.tilelink:
        final link = TileLinkInterface(harborTileLinkMemoryConfig(config));
        HarborTileLinkMemoryMaster(clk: clk, reset: reset, waist: up, tl: link);
        HarborTileLinkMemorySlave(
          clk: clk,
          reset: reset,
          tl: link,
          waist: down,
        );
      case HarborFabricKind.wishbone:
        final link = WishboneInterface(harborWishboneMemoryConfig(config));
        HarborWishboneMemoryMaster(clk: clk, reset: reset, waist: up, wb: link);
        HarborWishboneMemorySlave(
          clk: clk,
          reset: reset,
          wb: link,
          waist: down,
          burstBeats: burstBeats,
        );
    }
    exposeWaist(this, up, 'up', PairRole.consumer);
    exposeWaist(this, down, 'mem', PairRole.provider);
  }
}

/// One burst request.
class Burst {
  final int id;
  final bool write;
  final int addr;
  final int len;
  final int size;
  final int burst;
  final List<int> data;
  final List<int> strb;

  Burst({
    required this.id,
    required this.write,
    required this.addr,
    required this.len,
    required this.size,
    required this.burst,
    this.data = const [],
    this.strb = const [],
  });

  int get beats => len + 1;

  @override
  String toString() =>
      '${write ? 'W' : 'R'}(id $id addr 0x${addr.toRadixString(16)} '
      'len $len size $size burst $burst)';
}

/// Byte address of every beat of a burst, by the AXI4 rules.
List<int> beatAddrs(int addr, int len, int size, int burst) {
  final bytes = 1 << size;
  final n = len + 1;
  final aligned = addr & ~(bytes - 1);
  if (burst == 0) return List.filled(n, addr);
  if (burst == 2) {
    final total = n * bytes;
    final lower = addr & ~(total - 1);
    return [
      for (var i = 0; i < n; i++) lower + ((addr - lower + i * bytes) % total),
    ];
  }
  return [for (var i = 0; i < n; i++) i == 0 ? addr : aligned + i * bytes];
}

/// True when the burst breaks the AXI4 burst rules for a bus of [busBytes].
bool illegalBurst(Burst b, int busBytes) {
  final bytes = 1 << b.size;
  if (bytes > busBytes || b.burst == 3) return true;
  if (b.burst == 0) return b.len > 15;
  if (b.burst == 2) {
    return ![1, 3, 7, 15].contains(b.len) || b.addr % bytes != 0;
  }
  final start = (b.addr & 0xfff) & ~(bytes - 1);
  return start + b.beats * bytes > 4096;
}

/// Word memory with a known start value at every word.
class WordMemory {
  final int busBytes;
  final int mask;
  final Map<int, int> words = {};

  WordMemory(this.busBytes)
    : mask = busBytes == 8 ? -1 : (1 << (busBytes * 8)) - 1;

  int _init(int word) => (word * 0x9e3779b1 + 0x1234567) & mask;

  int read(int addr) {
    final w = addr ~/ busBytes;
    return words[w] ?? _init(w);
  }

  void write(int addr, int data, int strb) {
    if (strb == 0) return;
    final w = addr ~/ busBytes;
    var out = words[w] ?? _init(w);
    for (var i = 0; i < busBytes; i++) {
      if (strb & (1 << i) != 0) {
        final m = 0xff << (8 * i);
        out = (out & ~m) | (data & m);
      }
    }
    words[w] = out & mask;
  }
}

/// Drives a valid/ready channel from a queue. VALID goes low between items
/// with probability [idle], and the payload holds until it is taken.
class Source {
  final Sim s;
  final String valid;
  final String ready;
  final Random rng;
  double idle;
  final Queue<Map<String, int>> queue = Queue();
  Map<String, int>? _cur;

  /// Called on the rising edge where an item is taken.
  void Function(Map<String, int> item)? onFire;

  Source(this.s, this.valid, this.ready, this.rng, {this.idle = 0}) {
    s.onRise(() {
      if (_cur != null && s.pre(valid) == 1 && s.pre(ready) == 1) {
        onFire?.call(_cur!);
        _cur = null;
      }
    });
    s.onFall(() {
      if (_cur == null && queue.isNotEmpty && rng.nextDouble() >= idle) {
        _cur = queue.removeFirst();
        _cur!.forEach(s.set);
      }
      s.set(valid, _cur == null ? 0 : 1);
    });
  }

  bool get idleNow => _cur == null && queue.isEmpty;

  /// Drops the item in progress and the queue.
  void reset() {
    _cur = null;
    queue.clear();
  }
}

/// Takes from a valid/ready channel. READY is low with probability [stall]
/// and always low while [gate] returns false.
class Sink {
  final Sim s;
  final String valid;
  final String ready;
  final List<String> fields;
  final Random rng;
  double stall;
  bool Function()? gate;
  final void Function(Map<String, int> item) onData;

  /// Reads the payload at the falling edge instead of with [Sim.pre]. Use
  /// it when the design drives the payload from registers only, since
  /// [Sim.pre] can return a stale value for a port that has not changed yet
  /// in the current tick.
  final bool latchOnFall;
  Map<String, int?> _latched = {};

  Sink(
    this.s,
    this.valid,
    this.ready,
    this.fields,
    this.rng,
    this.onData, {
    this.stall = 0,
    this.gate,
    this.latchOnFall = false,
  }) {
    s.onRise(() {
      if (s.pre(valid) == 1 && s.pre(ready) == 1) {
        onData({
          for (final f in fields)
            f: latchOnFall
                ? _latched[f] ?? (throw StateError('$f is not valid'))
                : s.pre(f),
        });
      }
    });
    s.onFall(() {
      final open = (gate?.call() ?? true) && rng.nextDouble() >= stall;
      s.set(ready, open ? 1 : 0);
      if (latchOnFall) {
        _latched = {for (final f in fields) f: _now(f)};
      }
    });
  }

  int? _now(String port) {
    final v = (s.dut.tryOutput(port) ?? s.dut.input(port).srcConnection!).value;
    return v.isValid ? v.toInt() : null;
  }
}

/// Checks that a channel the design drives keeps VALID and its payload
/// steady until READY.
class StableCheck {
  final Sim s;
  final List<String> errors;
  Map<String, int>? _held;

  StableCheck(
    this.s,
    String valid,
    String ready,
    List<String> payload,
    this.errors,
  ) {
    s.onRise(() {
      final v = s.pre(valid);
      final now = v == 1 ? {for (final p in payload) p: s.pre(p)} : null;
      if (_held != null) {
        if (v != 1) {
          errors.add('$valid dropped before $ready');
        } else if (now.toString() != _held.toString()) {
          errors.add('$valid payload changed before $ready: $_held -> $now');
        }
      }
      _held = v == 1 && s.pre(ready) == 0 ? now : null;
    });
  }
}

/// A memory behind a slave side waist on ports `<p>_*`.
///
/// Records each request and the read data it returns. A request at or above
/// [errBase] fails. Fails the test when the port sends write data with no
/// write taken, or has more than [outstanding] requests in flight.
class WaistMemory {
  final Sim s;
  final String p;
  final Random rng;
  final int outstanding;
  final int busBytes;
  final int errBase;

  /// Decides a write's err from every beat's own address, instead of the
  /// request's start address, so a request can carry both good and bad
  /// beats.
  final bool perBeatErr;
  final List<String> errors;
  final WordMemory mem;
  final List<Burst> reads = [];
  final List<Burst> writes = [];
  final List<List<int>> readData = [];
  final Queue<(Burst, List<int>)> _pendW = Queue();
  final Queue<(Burst, List<int>)> _pendR = Queue();
  late final Source rdata;
  late final Source wresp;
  late final Sink req;
  late final Sink wdata;
  int inflight = 0;
  int maxInflight = 0;

  WaistMemory(
    this.s,
    this.p,
    this.rng, {
    required this.outstanding,
    required this.busBytes,
    required this.errors,
    this.errBase = 0xf000,
    this.perBeatErr = false,
    double stall = 0.3,
  }) : mem = WordMemory(busBytes) {
    rdata = Source(s, '${p}_RDATA_VALID', '${p}_RDATA_READY', rng, idle: stall)
      ..onFire = (item) {
        if (item['${p}_RDATA_LAST'] == 1) _done();
      };
    wresp = Source(s, '${p}_WRESP_VALID', '${p}_WRESP_READY', rng, idle: stall)
      ..onFire = (_) => _done();
    req = Sink(
      s,
      '${p}_REQ_VALID',
      '${p}_REQ_READY',
      [for (final f in _reqFields) '${p}_$f'],
      rng,
      _onReq,
      stall: stall,
    );
    wdata = Sink(
      s,
      '${p}_WDATA_VALID',
      '${p}_WDATA_READY',
      ['${p}_WDATA_DATA', '${p}_WDATA_STRB', '${p}_WDATA_LAST'],
      rng,
      _onWdata,
      stall: stall,
    );
    s.onFall(_feedReads);
  }

  void _done() => inflight--;

  /// Forgets every request in flight, as a device reset does. The memory
  /// keeps its contents.
  void reset() {
    _pendW.clear();
    _pendR.clear();
    rdata.reset();
    wresp.reset();
    _beat = 0;
    _wErrSeen = false;
    _rBeat = 0;
    _rIndex = readData.length;
    inflight = 0;
  }

  void _onReq(Map<String, int> f) {
    final b = Burst(
      id: f['${p}_REQ_ID']!,
      write: f['${p}_REQ_WRITE'] == 1,
      addr: f['${p}_REQ_ADDR']!,
      len: f['${p}_REQ_LEN']!,
      size: f['${p}_REQ_SIZE']!,
      burst: f['${p}_REQ_BURST']!,
    );
    inflight++;
    maxInflight = max(maxInflight, inflight);
    if (inflight > outstanding) {
      errors.add('more than $outstanding requests in flight');
    }
    final addrs = beatAddrs(b.addr, b.len, b.size, b.burst);
    if (b.write) {
      writes.add(b);
      _pendW.add((b, addrs));
    } else {
      reads.add(b);
      _pendR.add((b, addrs));
      readData.add([]);
    }
  }

  int _beat = 0;
  bool _wErrSeen = false;

  void _onWdata(Map<String, int> f) {
    if (_pendW.isEmpty) {
      errors.add('write data with no write request taken');
      return;
    }
    final (b, addrs) = _pendW.first;
    final last = _beat == b.len;
    if ((f['${p}_WDATA_LAST'] == 1) != last) {
      errors.add('WDATA_LAST wrong on beat $_beat of $b');
    }
    final strb = f['${p}_WDATA_STRB']!;
    final addrErr = perBeatErr ? addrs[_beat] >= errBase : b.addr >= errBase;
    if (perBeatErr) {
      // A beat with every strobe low has no effect, so it must not be
      // able to fault the device.
      _wErrSeen = _wErrSeen || (strb != 0 && addrErr);
    }
    if (!addrErr) {
      mem.write(addrs[_beat], f['${p}_WDATA_DATA']!, strb);
    }
    _beat++;
    if (last) {
      final err = perBeatErr ? _wErrSeen : addrErr;
      _beat = 0;
      _wErrSeen = false;
      _pendW.removeFirst();
      wresp.queue.add({'${p}_WRESP_ID': b.id, '${p}_WRESP_ERR': err ? 1 : 0});
    }
  }

  int _rIndex = 0;
  int _rBeat = 0;

  // Queues the next read beat once the source is free.
  void _feedReads() {
    if (_pendR.isEmpty || rdata.queue.isNotEmpty) return;
    final (b, addrs) = _pendR.first;
    final err = b.addr >= errBase;
    final data = err ? 0 : mem.read(addrs[_rBeat]);
    readData[_rIndex].add(data);
    final last = _rBeat == b.len;
    rdata.queue.add({
      '${p}_RDATA_ID': b.id,
      '${p}_RDATA_DATA': data,
      '${p}_RDATA_ERR': err ? 1 : 0,
      '${p}_RDATA_LAST': last ? 1 : 0,
    });
    _rBeat++;
    if (last) {
      _rBeat = 0;
      _rIndex++;
      _pendR.removeFirst();
    }
  }
}

/// A requester on a master side waist on ports `<p>_*`.
///
/// Sends [Burst]s in order. Write data goes after the request is taken, or
/// right away with [earlyData]. Records responses as they come back: a
/// master waist may return different IDs in any order, but keeps the order
/// of responses that share an ID, so each ID's beats are routed to the read
/// slot at the front of that ID's own queue.
class WaistRequester {
  final Sim s;
  final String p;
  final Random rng;
  final List<String> errors;
  late final Source req;
  late final Source wdata;
  late final Sink rdata;
  late final Sink wresp;
  final bool earlyData;
  final List<Burst> reads = [];
  final List<Burst> writes = [];

  /// Read beats as (id, data, err, last) per read, indexed the same as
  /// [reads] no matter which order the reads complete in.
  final List<List<(int, int, int, int)>> readResp = [];

  /// Write responses as (id, err), in receipt order. Different IDs may
  /// interleave. Responses that share an ID stay in issue order.
  final List<(int, int)> writeResp = [];
  final Queue<Burst> _issued = Queue();

  /// Read slot indices still waiting on their last beat, per ID, oldest
  /// first.
  final Map<int, Queue<int>> _pendingReads = {};
  int _readsDone = 0;
  int _dataDone = 0;

  WaistRequester(
    this.s,
    this.p,
    this.rng, {
    required this.errors,
    this.earlyData = false,
    double idle = 0.2,
    double stall = 0.3,
  }) {
    req = Source(s, '${p}_REQ_VALID', '${p}_REQ_READY', rng, idle: idle)
      ..onFire = (_) {
        final b = _issued.removeFirst();
        if (b.write && !earlyData) _queueData(b);
      };
    wdata = Source(s, '${p}_WDATA_VALID', '${p}_WDATA_READY', rng, idle: idle)
      ..onFire = (f) {
        if (f['${p}_WDATA_LAST'] == 1) _dataDone++;
      };
    rdata = Sink(
      s,
      '${p}_RDATA_VALID',
      '${p}_RDATA_READY',
      ['${p}_RDATA_ID', '${p}_RDATA_DATA', '${p}_RDATA_ERR', '${p}_RDATA_LAST'],
      rng,
      _onRdata,
      stall: stall,
    );
    wresp = Sink(
      s,
      '${p}_WRESP_VALID',
      '${p}_WRESP_READY',
      ['${p}_WRESP_ID', '${p}_WRESP_ERR'],
      rng,
      (f) {
        // Writes send their data in order, so a WRESP needs one more
        // write with all its data sent.
        if (writeResp.length >= _dataDone) {
          errors.add('WRESP before the data of its write');
        }
        writeResp.add((f['${p}_WRESP_ID']!, f['${p}_WRESP_ERR']!));
      },
      stall: stall,
    );
  }

  void _queueData(Burst b) {
    for (var i = 0; i < b.beats; i++) {
      wdata.queue.add({
        '${p}_WDATA_DATA': b.data[i],
        '${p}_WDATA_STRB': b.strb[i],
        '${p}_WDATA_LAST': i == b.len ? 1 : 0,
      });
    }
  }

  void send(Burst b) {
    (b.write ? writes : reads).add(b);
    if (!b.write) {
      _pendingReads.putIfAbsent(b.id, () => Queue()).add(readResp.length);
      readResp.add([]);
    }
    _issued.add(b);
    req.queue.add({
      '${p}_REQ_ID': b.id,
      '${p}_REQ_WRITE': b.write ? 1 : 0,
      '${p}_REQ_ADDR': b.addr,
      '${p}_REQ_LEN': b.len,
      '${p}_REQ_SIZE': b.size,
      '${p}_REQ_BURST': b.burst,
    });
    if (b.write && earlyData) _queueData(b);
  }

  void _onRdata(Map<String, int> f) {
    final id = f['${p}_RDATA_ID']!;
    final q = _pendingReads[id];
    if (q == null || q.isEmpty) {
      errors.add('read data with no read in flight for id $id');
      return;
    }
    final last = f['${p}_RDATA_LAST']!;
    readResp[q.first].add((
      id,
      f['${p}_RDATA_DATA']!,
      f['${p}_RDATA_ERR']!,
      last,
    ));
    if (last == 1) {
      q.removeFirst();
      _readsDone++;
    }
  }

  bool get done =>
      _readsDone == reads.length && writeResp.length == writes.length;

  /// Forgets every request and response, as a device reset does.
  void reset() {
    req.reset();
    wdata.reset();
    _issued.clear();
    _pendingReads.clear();
    reads.clear();
    writes.clear();
    readResp.clear();
    writeResp.clear();
    _readsDone = 0;
    _dataDone = 0;
  }
}

/// Random bursts for a bus of [busBytes] below [span] bytes.
class BurstGen {
  final Random rng;
  final int busBytes;
  final int idWidth;
  final int span;
  final int errBase;

  /// Chance of a request that breaks the burst rules.
  final double illegal;

  /// Chance of a request in the error range.
  final double errors;

  /// Chance of a 256 beat INCR burst.
  final double long;

  BurstGen(
    this.rng, {
    required this.busBytes,
    required this.idWidth,
    this.span = 0x2000,
    this.errBase = 0xf000,
    this.illegal = 0,
    this.errors = 0,
    this.long = 0.03,
  });

  int get _busSize => busBytes.bitLength - 1;

  int _data() => busBytes == 8
      ? (rng.nextInt(1 << 32) << 32) | rng.nextInt(1 << 32)
      : rng.nextInt(1 << (busBytes * 8));

  /// Lanes a beat at [addr] of [size] may use.
  int _lanes(int addr, int size) {
    final bytes = 1 << size;
    final lo = addr % busBytes;
    final hi = (addr & ~(bytes - 1)) % busBytes + bytes;
    var m = 0;
    for (var i = lo; i < hi; i++) {
      m |= 1 << i;
    }
    return m;
  }

  Burst next({required bool write, int? id}) {
    final bid = id ?? rng.nextInt(1 << idWidth);
    Burst? b;
    while (b == null) {
      final kind = rng.nextInt(3);
      final size = rng.nextInt(4) == 0 ? rng.nextInt(_busSize + 1) : _busSize;
      final bytes = 1 << size;
      final len = switch (kind) {
        0 => rng.nextInt(16),
        2 => [1, 3, 7, 15][rng.nextInt(4)],
        _ => rng.nextDouble() < long ? 255 : rng.nextInt(16),
      };
      var addr = rng.nextInt(span);
      if (kind == 2) addr &= ~(bytes - 1);
      if (rng.nextDouble() < errors) {
        addr = errBase + rng.nextInt(2) * 0x800 + (addr & 0xff);
      }
      final c = Burst(
        id: bid,
        write: write,
        addr: addr,
        len: len,
        size: size,
        burst: kind,
      );
      if (!illegalBurst(c, busBytes)) b = c;
    }
    if (rng.nextDouble() < illegal) b = _breakRules(b);
    if (!write) return b;
    final addrs = beatAddrs(b.addr, b.len, b.size, b.burst);
    final strbMask = (1 << busBytes) - 1;
    return Burst(
      id: b.id,
      write: true,
      addr: b.addr,
      len: b.len,
      size: b.size,
      burst: b.burst,
      data: [for (var i = 0; i < b.beats; i++) _data()],
      strb: [
        for (final a in addrs)
          if (b.size > _busSize)
            strbMask
          else if (rng.nextBool())
            _lanes(a, b.size)
          else
            _lanes(a, b.size) & rng.nextInt(strbMask + 1),
      ],
    );
  }

  Burst _breakRules(Burst b) {
    final pick = rng.nextInt(6);
    int addr = b.addr, len = b.len, size = b.size, burst = b.burst;
    switch (pick) {
      case 0:
        burst = 2;
        len = 2;
        size = _busSize;
        addr &= ~(busBytes - 1);
      case 1:
        burst = 2;
        len = 3;
        size = _busSize;
        addr = (addr & ~(busBytes - 1)) | 1;
      case 2:
        burst = 1;
        size = _busSize;
        len = 15;
        addr = (addr | 0xfff) & ~(busBytes - 1);
      case 3:
        size = _busSize + 1;
      case 4:
        burst = 3;
      default:
        burst = 0;
        len = 16 + rng.nextInt(8);
    }
    return Burst(
      id: b.id,
      write: b.write,
      addr: addr,
      len: len,
      size: size,
      burst: burst,
    );
  }
}

/// An AXI4 manager on the ports `<p>_*` of a subordinate.
///
/// AW, W and AR run from their own queues, so W often runs ahead of AW.
/// Records the order AW and AR are taken and every B and R.
class AxiManager {
  final Sim s;
  final String p;
  late final Source aw;
  late final Source w;
  late final Source ar;
  late final Sink b;
  late final Sink r;
  final Queue<Burst> _aw = Queue();
  final Queue<Burst> _ar = Queue();
  final List<Burst> awOrder = [];
  final List<Burst> arOrder = [];
  final List<(int, int)> bResp = [];

  /// R beats as (id, data, resp, last).
  final List<(int, int, int, int)> rBeats = [];

  /// The port is AXI4-Lite: ID reads as 0 and RLAST as 1.
  final bool lite;

  AxiManager(
    this.s,
    this.p,
    Random rng, {
    double awIdle = 0.3,
    double wIdle = 0.1,
    double arIdle = 0.3,
    double stall = 0.3,
    this.lite = false,
  }) {
    aw = Source(s, '${p}_AWVALID', '${p}_AWREADY', rng, idle: awIdle)
      ..onFire = (_) => awOrder.add(_aw.removeFirst());
    w = Source(s, '${p}_WVALID', '${p}_WREADY', rng, idle: wIdle);
    ar = Source(s, '${p}_ARVALID', '${p}_ARREADY', rng, idle: arIdle)
      ..onFire = (_) => arOrder.add(_ar.removeFirst());
    b = Sink(
      s,
      '${p}_BVALID',
      '${p}_BREADY',
      [if (!lite) '${p}_BID', '${p}_BRESP'],
      rng,
      (f) => bResp.add((f['${p}_BID'] ?? 0, f['${p}_BRESP']!)),
      stall: stall,
    );
    r = Sink(
      s,
      '${p}_RVALID',
      '${p}_RREADY',
      [
        if (!lite) '${p}_RID',
        '${p}_RDATA',
        '${p}_RRESP',
        if (!lite) '${p}_RLAST',
      ],
      rng,
      (f) => rBeats.add((
        f['${p}_RID'] ?? 0,
        f['${p}_RDATA']!,
        f['${p}_RRESP']!,
        f['${p}_RLAST'] ?? 1,
      )),
      stall: stall,
    );
  }

  Map<String, int> _addr(String ch, Burst x) => lite
      ? {'${p}_${ch}ADDR': x.addr}
      : {
          '${p}_${ch}ID': x.id,
          '${p}_${ch}ADDR': x.addr,
          '${p}_${ch}LEN': x.len,
          '${p}_${ch}SIZE': x.size,
          '${p}_${ch}BURST': x.burst,
        };

  /// Queues AW, and the W beats unless [data] is false.
  void write(Burst x, {bool data = true}) {
    _aw.add(x);
    aw.queue.add(_addr('AW', x));
    if (!data) return;
    for (var i = 0; i < x.beats; i++) {
      w.queue.add({
        '${p}_WDATA': x.data[i],
        '${p}_WSTRB': x.strb[i],
        if (!lite) '${p}_WLAST': i == x.len ? 1 : 0,
      });
    }
  }

  void read(Burst x) {
    _ar.add(x);
    ar.queue.add(_addr('AR', x));
  }

  int get readBeatsExpected =>
      arOrder.fold(0, (n, x) => n + x.beats) +
      _ar.fold(0, (n, x) => n + x.beats);
}

/// An AXI4 subordinate memory on the ports `<p>_*` of a manager.
///
/// Takes W before its AW. Answers reads and writes with different IDs out of
/// order, and interleaves R beats of different IDs. Requests from [errBase]
/// get SLVERR and from `errBase + 0x800` get DECERR.
class AxiMemory {
  final Sim s;
  final String p;
  final Random rng;
  final int busBytes;
  final int outstanding;
  final int errBase;
  final List<String> errors;
  final WordMemory mem;
  late final Sink aw;
  late final Sink w;
  late final Sink ar;
  late final Source b;
  late final Source r;
  final Queue<Burst> _awQ = Queue();
  final Queue<(int, int, int)> _wBuf = Queue();
  int _wBeat = 0;
  final List<(int, int)> _pendB = [];
  final List<_PendRead> _pendR = [];
  final List<Burst> awOrder = [];
  final List<Burst> arOrder = [];
  final List<List<int>> readData = [];
  int inflight = 0;
  int maxInflight = 0;

  /// When set, and pending, answered ahead of every other ID. Lets a test
  /// force which ID overtakes, instead of relying on a lucky seed.
  int? preferId;

  /// Stops B and R responses from going out at all, so a test can get two
  /// requests pending together before letting either one answer.
  bool holdResponses = false;

  /// The port is AXI4-Lite: each request is one full width beat with ID 0.
  final bool lite;

  AxiMemory(
    this.s,
    this.p,
    this.rng, {
    required this.busBytes,
    required this.outstanding,
    required this.errors,
    this.errBase = 0xf000,
    double stall = 0.3,
    this.lite = false,
  }) : mem = WordMemory(busBytes) {
    List<String> addr(String ch) => [
      for (final f in lite ? ['ADDR'] : ['ID', 'ADDR', 'LEN', 'SIZE', 'BURST'])
        '${p}_$ch$f',
    ];
    Burst req(String ch, Map<String, int> f, bool write) => Burst(
      id: f['${p}_${ch}ID'] ?? 0,
      write: write,
      addr: f['${p}_${ch}ADDR']!,
      len: f['${p}_${ch}LEN'] ?? 0,
      size: f['${p}_${ch}SIZE'] ?? busBytes.bitLength - 1,
      burst: f['${p}_${ch}BURST'] ?? 1,
    );
    aw = Sink(s, '${p}_AWVALID', '${p}_AWREADY', addr('AW'), rng, (f) {
      final x = req('AW', f, true);
      awOrder.add(x);
      _awQ.add(x);
      _take();
      _drainW();
    }, stall: stall);
    w = Sink(
      s,
      '${p}_WVALID',
      '${p}_WREADY',
      ['${p}_WDATA', '${p}_WSTRB', if (!lite) '${p}_WLAST'],
      rng,
      (f) {
        _wBuf.add((f['${p}_WDATA']!, f['${p}_WSTRB']!, f['${p}_WLAST'] ?? 1));
        _drainW();
      },
      stall: stall,
    );
    ar = Sink(s, '${p}_ARVALID', '${p}_ARREADY', addr('AR'), rng, (f) {
      final x = req('AR', f, false);
      arOrder.add(x);
      _take();
      final resp = _resp(x.addr);
      final data = [
        for (final a in beatAddrs(x.addr, x.len, x.size, x.burst))
          resp == 0 ? mem.read(a) : 0,
      ];
      readData.add(data);
      _pendR.add(_PendRead(x, data, resp));
    }, stall: stall);
    b = Source(s, '${p}_BVALID', '${p}_BREADY', rng, idle: stall)
      ..onFire = (_) => inflight--;
    r = Source(s, '${p}_RVALID', '${p}_RREADY', rng, idle: stall)
      ..onFire = (f) {
        if ((f['${p}_RLAST'] ?? 1) == 1) inflight--;
      };
    s.onFall(_feed);
  }

  int _resp(int addr) => addr < errBase
      ? 0
      : addr < errBase + 0x800
      ? 2
      : 3;

  void _take() {
    inflight++;
    maxInflight = max(maxInflight, inflight);
    if (inflight > outstanding) {
      errors.add('more than $outstanding requests in flight on AXI');
    }
  }

  void _drainW() {
    while (_awQ.isNotEmpty && _wBuf.isNotEmpty) {
      final x = _awQ.first;
      final (data, strb, last) = _wBuf.removeFirst();
      if ((last == 1) != (_wBeat == x.len)) {
        errors.add('WLAST wrong on beat $_wBeat of $x');
      }
      final resp = _resp(x.addr);
      if (resp == 0) {
        mem.write(
          beatAddrs(x.addr, x.len, x.size, x.burst)[_wBeat],
          data,
          strb,
        );
      }
      _wBeat++;
      if (_wBeat == x.beats) {
        _wBeat = 0;
        _awQ.removeFirst();
        _pendB.add((x.id, resp));
      }
    }
  }

  // Picks the oldest entry of [preferId] if it is pending, else of a
  // random ID.
  int _pick<T>(List<T> items, int Function(T) id) {
    final firsts = <int>[];
    final seen = <int>{};
    for (var i = 0; i < items.length; i++) {
      if (seen.add(id(items[i]))) firsts.add(i);
    }
    if (preferId != null) {
      final i = firsts.indexWhere((i) => id(items[i]) == preferId);
      if (i != -1) return firsts[i];
    }
    return firsts[rng.nextInt(firsts.length)];
  }

  void _feed() {
    if (holdResponses) return;
    // B waits a while so that responses of different IDs pile up.
    if (b.queue.isEmpty && _pendB.isNotEmpty && rng.nextInt(4) == 0) {
      final (id, resp) = _pendB.removeAt(_pick(_pendB, (e) => e.$1));
      b.queue.add({if (!lite) '${p}_BID': id, '${p}_BRESP': resp});
    }
    if (r.queue.isEmpty && _pendR.isNotEmpty) {
      final i = _pick(_pendR, (e) => e.burst.id);
      final e = _pendR[i];
      final last = e.beat == e.burst.len;
      r.queue.add({
        if (!lite) '${p}_RID': e.burst.id,
        '${p}_RDATA': e.data[e.beat],
        '${p}_RRESP': e.resp,
        if (!lite) '${p}_RLAST': last ? 1 : 0,
      });
      e.beat++;
      if (last) _pendR.removeAt(i);
    }
  }
}

class _PendRead {
  final Burst burst;
  final List<int> data;
  final int resp;
  int beat = 0;
  _PendRead(this.burst, this.data, this.resp);
}

/// Stable checks on every channel a slave port drives on its waist `<p>_*`
/// and its AXI4 port `<a>_*`.
void slavePortChecks(Sim s, String a, String p, List<String> errors) {
  StableCheck(s, '${p}_REQ_VALID', '${p}_REQ_READY', [
    for (final f in _reqFields) '${p}_$f',
  ], errors);
  StableCheck(s, '${p}_WDATA_VALID', '${p}_WDATA_READY', [
    '${p}_WDATA_DATA',
    '${p}_WDATA_STRB',
    '${p}_WDATA_LAST',
  ], errors);
  StableCheck(s, '${a}_BVALID', '${a}_BREADY', [
    '${a}_BID',
    '${a}_BRESP',
  ], errors);
  StableCheck(s, '${a}_RVALID', '${a}_RREADY', [
    '${a}_RID',
    '${a}_RDATA',
    '${a}_RRESP',
    '${a}_RLAST',
  ], errors);
}

/// Stable checks on every channel a master port drives on its AXI4 port
/// `<a>_*` and its waist `<p>_*`.
void masterPortChecks(Sim s, String a, String p, List<String> errors) {
  for (final ch in ['AW', 'AR']) {
    StableCheck(s, '${a}_${ch}VALID', '${a}_${ch}READY', [
      for (final f in ['ID', 'ADDR', 'LEN', 'SIZE', 'BURST']) '${a}_$ch$f',
    ], errors);
  }
  StableCheck(s, '${a}_WVALID', '${a}_WREADY', [
    '${a}_WDATA',
    '${a}_WSTRB',
    '${a}_WLAST',
  ], errors);
  StableCheck(s, '${p}_RDATA_VALID', '${p}_RDATA_READY', [
    '${p}_RDATA_ID',
    '${p}_RDATA_DATA',
    '${p}_RDATA_ERR',
    '${p}_RDATA_LAST',
  ], errors);
  StableCheck(s, '${p}_WRESP_VALID', '${p}_WRESP_READY', [
    '${p}_WRESP_ID',
    '${p}_WRESP_ERR',
  ], errors);
}

/// Waits until [done] is true, for at most [limit] cycles.
Future<void> waitUntil(Sim s, bool Function() done, {int limit = 50000}) async {
  for (var i = 0; i < limit; i++) {
    if (done()) return;
    await s.cycles(1);
  }
  throw StateError('timed out after $limit cycles');
}

/// The memory after [writes] in order, leaving out those that break the
/// burst rules or start at or above [errBase].
WordMemory golden(List<Burst> writes, int busBytes, {int errBase = 0xf000}) {
  final m = WordMemory(busBytes);
  for (final x in writes) {
    if (illegalBurst(x, busBytes) || x.addr >= errBase) continue;
    final addrs = beatAddrs(x.addr, x.len, x.size, x.burst);
    for (var i = 0; i < x.beats; i++) {
      m.write(addrs[i], x.data[i], x.strb[i]);
    }
  }
  return m;
}

/// Mismatches between two memories over the words either one wrote.
List<String> diffMemory(WordMemory want, WordMemory got) => [
  for (final w in {...want.words.keys, ...got.words.keys})
    if (want.read(w * want.busBytes) != got.read(w * got.busBytes))
      'word 0x${w.toRadixString(16)}: want '
          '0x${want.read(w * want.busBytes).toRadixString(16)} got '
          '0x${got.read(w * got.busBytes).toRadixString(16)}',
];

/// Checks [got] against [want] split into queues by ID: a response is
/// matched against the oldest still-unmatched [want] entry with the same
/// ID. Different IDs may interleave in [got]. A mismatch inside one ID's
/// queue, or a response or a leftover entry with no match, is reported.
List<String> diffPerId<T, R>({
  required List<T> want,
  required List<R> got,
  required int Function(T) wantId,
  required int Function(R) gotId,
  required bool Function(T, R) matches,
}) {
  final queues = <int, Queue<T>>{};
  for (final w in want) {
    queues.putIfAbsent(wantId(w), () => Queue()).add(w);
  }
  final out = <String>[];
  for (final g in got) {
    final id = gotId(g);
    final q = queues[id];
    if (q == null || q.isEmpty) {
      out.add('unexpected response for id $id: $g');
      continue;
    }
    final w = q.removeFirst();
    if (!matches(w, g)) out.add('id $id: want $w got $g');
  }
  for (final e in queues.entries) {
    if (e.value.isNotEmpty) {
      out.add('id ${e.key}: ${e.value.length} response(s) missing');
    }
  }
  return out;
}

/// Mismatches between the request fields of two bursts.
String? diffReq(Burst want, Burst got) =>
    want.id == got.id &&
        want.write == got.write &&
        want.addr == got.addr &&
        want.len == got.len &&
        want.size == got.size &&
        want.burst == got.burst
    ? null
    : 'request $got, want $want';

/// Ends a simulation a failed test left running, then resets.
Future<void> endAndReset() async {
  if (Simulator.time > 0 && !Simulator.simulationHasEnded) {
    await Simulator.endSimulation();
  }
  await Simulator.reset();
}
