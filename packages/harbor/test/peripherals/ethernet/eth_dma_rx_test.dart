import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../../bus/port/memory_harness.dart' show exposeWaist;
import '../../bus/port/port_harness.dart' show Sim;
import '../../util/reg_bus.dart';

const _outs = [
  'head',
  'rx_done',
  'rx_err',
  'rx_missed',
  'ring_err',
  'err_code',
  'busy',
  'r_ready',
];

const _fcs = 1 << 0;
const _runt = 1 << 1;
const _oversize = 1 << 2;
const _rxEr = 1 << 3;
const _mcast = 1 << 4;
const _bcast = 1 << 5;
const _cut = 1 << 6;

/// The DMA with its waist on ports `mem_*`.
class _Top extends BridgeModule {
  _Top(HarborEthernetConfig cfg, int waistOutstanding)
    : super(
        'EthDmaRxTop_d${cfg.descBytes}_o${cfg.outstanding}'
        '_b${cfg.burstBeats}_n$waistOutstanding',
        name: 'top',
      ) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final w = HarborMemoryWaist(
      HarborMemoryWaistConfig(
        addressWidth: 32,
        dataWidth: 32,
        outstanding: waistOutstanding,
      ),
    );
    final dma = HarborEthDmaRx(
      input('clk'),
      input('reset'),
      waist: w,
      config: cfg,
      ringBase: addInput('ring_base', Logic(width: 32), width: 32),
      ringSize: addInput('ring_size', Logic(width: 4), width: 4),
      tail: addInput('tail', Logic(width: 12), width: 12),
      rxEn: addInput('rx_en', Logic()),
      keepBad: addInput('keep_bad', Logic()),
      ringReset: addInput('ring_reset', Logic()),
      rValid: addInput('r_valid', Logic()),
      rData: addInput('r_data', Logic(width: 32), width: 32),
      rBytes: addInput('r_bytes', Logic(width: 2), width: 2),
      rLast: addInput('r_last', Logic()),
      rStatus: addInput('r_status', Logic(width: 8), width: 8),
    );
    exposeWaist(this, w, 'mem', PairRole.provider);
    for (final n in _outs) {
      addOutput(n, width: dma.output(n).width) <= dma.output(n);
    }
  }
}

class _Req {
  final bool write;
  final int addr;
  final int len;
  final int readyAt;
  int beat = 0;
  _Req(this.write, this.addr, this.len, this.readyAt);
}

/// A memory behind the waist with a fixed latency and random stalls.
class _Mem {
  final Sim s;
  final Random rng;
  final int latency;
  final double stall;
  final int limit;
  final List<String> errors;
  final int Function() now;
  final bool Function(int) isRing;
  final Map<int, int> bytes = {};

  /// Byte addresses written with a strobe set.
  final Set<int> written = {};

  /// Word address of every write beat, strobes set or not.
  final List<int> beatAddrs = [];

  /// Byte ranges [lo, hi) that answer a read with an error.
  final List<(int, int)> errRanges = [];

  /// Byte ranges [lo, hi) where a write answers with an error.
  final List<(int, int)> writeErrRanges = [];

  /// Word 3 addresses whose write has its WRESP.
  final Set<int> _w3Done = {};

  final Queue<_Req> _rq = Queue();
  final Queue<_Req> _wq = Queue();
  final Queue<(int, bool, int)> _bq = Queue();
  final List<_Req> reads = [];
  final List<_Req> writes = [];

  /// Write requests sent after a WRESP with an error.
  int writesAfterErr = 0;
  bool _errSeen = false;
  int inflight = 0;
  int maxInflight = 0;
  bool _rBusy = false;
  bool _bBusy = false;

  _Mem(
    this.s,
    this.rng, {
    required this.latency,
    required this.stall,
    required this.limit,
    required this.errors,
    required this.now,
    required this.isRing,
  }) {
    s.onRise(_rise);
    s.onFall(_fall);
  }

  int byte(int a) => bytes[a] ?? ((a * 131 + 7) ^ (a >> 8)) & 0xff;

  int word(int a) => [
    for (var i = 3; i >= 0; i--) byte(a + i),
  ].fold(0, (v, b) => (v << 8) | b);

  void putWord(int a, int v) {
    for (var i = 0; i < 4; i++) {
      bytes[a + i] = (v >> (8 * i)) & 0xff;
    }
  }

  bool _isErr(int a) => errRanges.any((r) => a >= r.$1 && a < r.$2);

  bool _isWErr(int a) => writeErrRanges.any((r) => a >= r.$1 && a < r.$2);

  bool get writeBusy => _wq.isNotEmpty || _bq.isNotEmpty || _bBusy;

  int _p(String n) => s.pre('mem_$n');
  void _set(String n, int v) => s.set('mem_$n', v);

  void _rise() {
    final reqFire = _p('REQ_VALID') == 1 && _p('REQ_READY') == 1;
    final reqW = reqFire && _p('REQ_WRITE') == 1;
    if (_p('RDATA_READY') == 1 && _rq.isEmpty && !(reqFire && !reqW)) {
      errors.add('RDATA_READY high with no read in flight');
    }
    if (_p('WRESP_READY') == 1 && _wq.isEmpty && _bq.isEmpty && !reqW) {
      errors.add('WRESP_READY high with no write in flight');
    }
    if (_rBusy && _p('RDATA_VALID') == 1 && _p('RDATA_READY') == 1) {
      _rBusy = false;
      final r = _rq.first;
      r.beat++;
      if (r.beat > r.len) {
        _rq.removeFirst();
        inflight--;
      }
    }
    if (_bBusy && _p('WRESP_VALID') == 1 && _p('WRESP_READY') == 1) {
      _bBusy = false;
      final done = _bq.removeFirst();
      if (done.$2) _errSeen = true;
      if (!done.$2 && isRing(done.$3) && done.$3 & 0xf == 12) {
        _w3Done.add(done.$3);
      }
      inflight--;
    }
    if (_p('WDATA_VALID') == 1 && _p('WDATA_READY') == 1) {
      if (_wq.isEmpty) {
        errors.add('write data with no write request');
      } else {
        final w = _wq.first;
        final a = w.addr + 4 * w.beat;
        final strb = _p('WDATA_STRB');
        final data = _p('WDATA_DATA');
        beatAddrs.add(a);
        if ((_p('WDATA_LAST') == 1) != (w.beat == w.len)) {
          errors.add('WDATA_LAST wrong at 0x${a.toRadixString(16)}');
        }
        if (!_isWErr(a)) {
          for (var i = 0; i < 4; i++) {
            if (strb & (1 << i) != 0) {
              bytes[a + i] = (data >> (8 * i)) & 0xff;
              written.add(a + i);
            }
          }
        }
        w.beat++;
        if (w.beat > w.len) {
          _wq.removeFirst();
          final err = List.generate(
            w.len + 1,
            (k) => w.addr + 4 * k,
          ).any(_isWErr);
          _bq.add((now() + latency, err, w.addr));
        }
      }
    }
    if (reqFire) {
      final addr = _p('REQ_ADDR');
      final len = _p('REQ_LEN');
      if (_p('REQ_SIZE') != 2 || _p('REQ_BURST') != 1 || addr & 3 != 0) {
        errors.add('bad request at 0x${addr.toRadixString(16)}');
      }
      if ((addr & 0xfff) + (len + 1) * 4 > 4096) {
        errors.add('burst at 0x${addr.toRadixString(16)} crosses 4 KB');
      }
      inflight++;
      maxInflight = max(maxInflight, inflight);
      if (inflight > limit) errors.add('more than $limit requests in flight');
      final r = _Req(reqW, addr, len, now() + latency);
      if (reqW) {
        if (_errSeen) writesAfterErr++;
        if (_rq.isNotEmpty) errors.add('write while a read is in flight');
        if (isRing(addr)) {
          if (writeBusy) {
            errors.add('write-back before every buffer WRESP');
          }
          if (addr & 0xf == 8 && !_w3Done.remove(addr + 4)) {
            errors.add('OWN clear before word 3 has its WRESP');
          }
        }
        writes.add(r);
        _wq.add(r);
      } else {
        if (writeBusy) errors.add('read while a write is in flight');
        reads.add(r);
        _rq.add(r);
      }
    }
  }

  bool _go() => rng.nextDouble() >= stall;

  void _fall() {
    _set('REQ_READY', _go() ? 1 : 0);
    _set('WDATA_READY', _wq.isNotEmpty && _go() ? 1 : 0);
    if (!_rBusy && _rq.isNotEmpty && _rq.first.readyAt <= now() && _go()) {
      final r = _rq.first;
      final a = r.addr + 4 * r.beat;
      _rBusy = true;
      _set('RDATA_ID', 0);
      _set('RDATA_DATA', _isErr(a) ? 0 : word(a));
      _set('RDATA_ERR', _isErr(a) ? 1 : 0);
      _set('RDATA_EXOKAY', 0);
      _set('RDATA_LAST', r.beat == r.len ? 1 : 0);
    }
    _set('RDATA_VALID', _rBusy ? 1 : 0);
    if (!_bBusy && _bq.isNotEmpty && _bq.first.$1 <= now() && _go()) {
      _bBusy = true;
      _set('WRESP_ID', 0);
      _set('WRESP_ERR', _bq.first.$2 ? 1 : 0);
      _set('WRESP_EXOKAY', 0);
    }
    _set('WRESP_VALID', _bBusy ? 1 : 0);
  }
}

/// The FIFO read side: whole frames with random gaps between words.
class _Src {
  final Sim s;
  final Random rng;
  double gap;
  final Queue<(List<int>, int)> _frames = Queue();
  int _word = 0;
  bool _shown = false;
  bool _abort = false;
  int taken = 0;

  _Src(this.s, this.rng, this.gap) {
    s.onRise(() {
      if (s.pre('r_valid') == 1 && s.pre('r_ready') == 1) {
        _shown = false;
        final f = _frames.first;
        _word++;
        if (_abort || _word * 4 >= f.$1.length) {
          _frames.removeFirst();
          _word = 0;
          _abort = false;
          taken++;
        }
      }
    });
    s.onFall(() {
      if (!_shown && _frames.isNotEmpty && rng.nextDouble() >= gap) {
        final (data, status) = _frames.first;
        final lo = _word * 4;
        final n = min(4, data.length - lo);
        final last = _abort || lo + 4 >= data.length;
        var v = 0;
        for (var i = n - 1; i >= 0 && !_abort; i--) {
          v = (v << 8) | data[lo + i];
        }
        s
          ..set('r_data', v)
          ..set('r_bytes', last && !_abort ? n & 3 : 0)
          ..set('r_last', last ? 1 : 0)
          ..set('r_status', _abort ? _cut : (last ? status : 0));
        _shown = true;
      }
      s.set('r_valid', _shown ? 1 : 0);
    });
  }

  void push(List<int> data, int status) => _frames.add((data, status));

  /// Models an RX side reset of the FIFO. Call it after a falling edge. A
  /// frame not yet started is lost. A started frame ends with one abort
  /// word with the cut status, like the FIFO gives.
  void vanish() {
    _shown = false;
    s.set('r_valid', 0);
    if (_word == 0) {
      _frames.removeFirst();
    } else {
      _abort = true;
    }
  }

  bool get empty => _frames.isEmpty;
  int get pending => _frames.length;
}

class _Buf {
  final int addr;
  final int size;
  _Buf(this.addr, this.size);
}

class _Bench {
  final Sim s;
  final HarborEthernetConfig cfg;
  final Random rng;
  final List<String> errors = [];
  late final _Mem mem;
  late final _Src src;
  int cycle = 0;
  int rxDone = 0;
  int rxErr = 0;
  int rxMissed = 0;
  int lastHead = 0;
  int ptr = 0x10000;
  int tail = 0;
  int ringLog2 = 3;
  final int ringBase;

  _Bench._(this.s, this.cfg, this.rng, this.ringBase);

  static Future<_Bench> make(
    HarborEthernetConfig cfg, {
    int latency = 0,
    double stall = 0.3,
    double gap = 0.3,
    int seed = 1,
    int ringBase = 0x8000,
    int ringLog2 = 3,
  }) async {
    final s = Sim(_Top(cfg, cfg.outstanding));
    final b = _Bench._(s, cfg, Random(seed), ringBase)..ringLog2 = ringLog2;
    s.onRise(() => b.cycle++);
    final ringEnd = ringBase + (cfg.descBytes << ringLog2);
    b.mem = _Mem(
      s,
      b.rng,
      latency: latency,
      stall: stall,
      limit: cfg.outstanding,
      errors: b.errors,
      now: () => b.cycle,
      isRing: (a) => a >= ringBase && a < ringEnd,
    );
    b.src = _Src(s, b.rng, gap);
    s.onRise(() {
      if (s.pre('rx_done') == 1) b.rxDone++;
      if (s.pre('rx_err') == 1) b.rxErr++;
      if (s.pre('rx_missed') == 1) b.rxMissed++;
      final h = s.pre('head');
      if (h != b.lastHead) {
        if (b.mem.writeBusy) b.errors.add('head moved before every WRESP');
        b.lastHead = h;
      }
    });
    await s.start();
    Simulator.setMaxSimTime(50000000);
    await s.cycles(1);
    s
      ..set('ring_base', ringBase)
      ..set('ring_size', ringLog2)
      ..set('rx_en', 1);
    return b;
  }

  int get mask => (1 << ringLog2) - 1;
  int out(String n) => s.dut.output(n).value.toInt();
  int descAddr(int i) => ringBase + i * cfg.descBytes;

  void putDesc(int i, int addr, int size, {bool own = true}) {
    final a = descAddr(i);
    mem
      ..putWord(a, addr)
      ..putWord(a + 4, 0)
      ..putWord(a + 8, size | (own ? 1 << 31 : 0))
      ..putWord(a + 12, 0xdead0000);
  }

  /// A 4-byte aligned buffer, or one across a 4 KB boundary.
  _Buf alloc(int size, {bool cross = false}) {
    int start;
    if (cross && size >= 8) {
      final boundary = ((ptr + 4095) & ~4095) + 4096;
      start = boundary - 4 * (1 + rng.nextInt(min(size ~/ 4, 80)));
    } else {
      start = ((ptr + 3) & ~3) + 4 * rng.nextInt(16);
    }
    ptr = start + size + 8;
    return _Buf(start, size);
  }

  /// Gives [bufs] at the tail. Returns their indexes.
  List<int> give(List<_Buf> bufs) {
    final idx = <int>[];
    for (final buf in bufs) {
      idx.add(tail);
      putDesc(tail, buf.addr, buf.size);
      tail = (tail + 1) & mask;
    }
    s.set('tail', tail);
    return idx;
  }

  List<int> data(int len) => [for (var i = 0; i < len; i++) rng.nextInt(256)];

  Future<void> until(bool Function() done, {int limit = 40000}) async {
    for (var i = 0; i < limit && !done(); i++) {
      await s.cycles(1);
    }
    expect(
      done(),
      isTrue,
      reason:
          'timed out: head ${out('head')} tail $tail busy ${out('busy')} '
          'err ${out('ring_err')} frames ${src.pending} '
          'errors ${errors.take(5)}',
    );
  }

  /// Waits until every frame is taken and the DMA is idle.
  Future<void> idle() async {
    await until(() => src.empty && out('busy') == 0);
    await s.cycles(2);
  }

  Future<void> pulse(String n) async {
    s.set(n, 1);
    await s.cycles(1);
    s.set(n, 0);
  }

  int word2(int i) => mem.word(descAddr(i) + 8);
  int word3(int i) => mem.word(descAddr(i) + 12);

  List<int> read(int a, int len) => [
    for (var i = 0; i < len; i++) mem.byte(a + i),
  ];

  /// No byte in [a, a + len) was written.
  void untouched(int a, int len, String why) {
    for (var i = 0; i < len; i++) {
      expect(mem.written.contains(a + i), isFalse, reason: '$why +$i');
    }
  }
}

int _w3(int len, int status, int err) =>
    len | (3 << 16) | (((status >> 4) & 3) << 18) | (err << 22);

HarborEthernetConfig _cfg({int outstanding = 4, int burst = 16}) =>
    HarborEthernetConfig(
      phy: HarborEthPhy.rgmii,
      outstanding: outstanding,
      burstBeats: burst,
    );

/// Sends [batches] of random good frames and checks each one.
Future<void> _traffic(
  HarborEthernetConfig cfg, {
  required int latency,
  required int seed,
  int batches = 3,
}) async {
  final b = await _Bench.make(cfg, latency: latency, seed: seed);
  final fixed = [1, 2, 3, 4, 5, 1522, 7, 1521];
  final sent = <(_Buf, List<int>)>[];
  for (var k = 0; k < batches; k++) {
    final n = 3 + b.rng.nextInt(b.mask - 2);
    final bufs = <_Buf>[];
    final frames = <(List<int>, int)>[];
    for (var i = 0; i < n; i++) {
      final len = fixed.isNotEmpty
          ? fixed.removeAt(0)
          : 1 + b.rng.nextInt(1522);
      final size = b.rng.nextBool() ? len : len + b.rng.nextInt(9);
      bufs.add(b.alloc(size, cross: b.rng.nextBool()));
      frames.add((b.data(len), b.rng.nextInt(4) << 4));
    }
    final idx = b.give(bufs);
    for (final f in frames) {
      b.src.push(f.$1, f.$2);
    }
    await b.idle();
    expect(b.errors, isEmpty);
    expect(b.out('ring_err'), 0);
    expect(b.out('head'), b.tail);
    for (var i = 0; i < n; i++) {
      final buf = bufs[i];
      final (data, status) = frames[i];
      expect(b.read(buf.addr, data.length), data, reason: 'frame $k.$i');
      b.untouched(buf.addr + data.length, buf.size + 4 - data.length, 'tail');
      expect(b.word2(idx[i]), buf.size, reason: 'OWN cleared');
      expect(b.word3(idx[i]), _w3(data.length, status, 0));
      sent.add((buf, data));
    }
  }
  await b.s.cycles(4);
  expect(b.errors, isEmpty);
  expect(b.rxDone, sent.length);
  expect(b.rxErr, 0);
  expect(b.rxMissed, 0);
  expect(b.mem.maxInflight, lessThanOrEqualTo(cfg.outstanding));
  if (cfg.outstanding > 1 && latency >= 8) {
    expect(b.mem.maxInflight, greaterThan(1), reason: 'writes pipeline');
  }
  final crossed = sent.any(
    (f) => (f.$1.addr >> 12) != ((f.$1.addr + f.$2.length - 1) >> 12),
  );
  expect(crossed, isTrue, reason: 'a buffer crosses 4 KB');
  for (final w in b.mem.written) {
    final inRing = w >= b.ringBase && w < b.descAddr(b.mask + 1);
    final inFrame = sent.any(
      (f) => w >= f.$1.addr && w < f.$1.addr + f.$2.length,
    );
    expect(
      inRing || inFrame,
      isTrue,
      reason: 'stray write 0x${w.toRadixString(16)}',
    );
  }
  for (final a in b.mem.beatAddrs) {
    final inRing = a >= b.ringBase && a < b.descAddr(b.mask + 1);
    final inBuf = sent.any(
      (f) => a >= f.$1.addr && a < f.$1.addr + ((f.$1.size + 3) & ~3),
    );
    expect(
      inRing || inBuf,
      isTrue,
      reason: 'beat outside a buffer 0x${a.toRadixString(16)}',
    );
  }
  final maxBeats = b.mem.writes.map((r) => r.len + 1).reduce(max);
  expect(maxBeats, lessThanOrEqualTo(cfg.burstBeats));
  await b.s.stop();
}

/// A register master whose native port pins are plain `p_<PORT>` ports.
class _Cpu extends BridgeModule {
  _Cpu(HarborFabricKind kind) : super('EthDmaRxCpu_${kind.name}', name: 'cpu') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final PairInterface intf = switch (kind) {
      HarborFabricKind.wishbone => WishboneInterface(
        const WishboneConfig(addressWidth: 32, dataWidth: 32, useErr: true),
      ),
      HarborFabricKind.axi4 => Axi4LiteInterface(
        addressWidth: 32,
        dataWidth: 32,
      ),
      HarborFabricKind.tilelink => TileLinkInterface(
        const TileLinkConfig(addressWidth: 32, dataWidth: 32),
      ),
    };
    final i = addInterface(
      intf,
      name: 'dataBus',
      role: PairRole.provider,
    ).internalInterface!;
    for (final e in i.getPorts([PairDirection.fromProvider]).entries) {
      final w = e.value.width;
      e.value <= addInput('p_${e.key}', Logic(width: w), width: w);
    }
    for (final e in i.getPorts([PairDirection.fromConsumer]).entries) {
      addOutput('p_${e.key}', width: e.value.width) <= e.value;
    }
  }

  void pullUp(HarborSoC soc) {
    for (final n in [...inputs.keys, ...outputs.keys]) {
      if (!n.startsWith('p_')) continue;
      soc.pullUpPort(port(n), newPortName: 'cpu_${n.substring(2)}');
    }
  }
}

const _dIns = [
  'd_ring_base',
  'd_ring_size',
  'd_tail',
  'd_rx_en',
  'd_in_valid',
  'd_in_data',
  'd_in_last',
  'd_in_status',
];
const _dOuts = ['d_head', 'd_ring_err', 'd_rx_missed'];

/// The DMA and an RX frame FIFO behind a memory master port named `bus`.
class _EthMaster extends BridgeModule {
  _EthMaster(HarborFabricKind kind, HarborEthernetConfig cfg)
    : super('EthDmaRxMaster_${kind.name}_n${cfg.outstanding}', name: 'ethdma') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final clk = input('clk');
    final port = HarborMemoryMasterPort.create(
      module: this,
      name: 'bus',
      kind: kind,
      config: HarborMemoryWaistConfig(
        addressWidth: 32,
        dataWidth: 32,
        outstanding: cfg.outstanding,
      ),
      clk: clk,
      reset: input('reset'),
    );
    final rReady = Logic(name: 'fifo_r_ready');
    final fifo = HarborEthRxFrameFifo(
      clk,
      port.reset,
      clk,
      port.reset,
      bytes: cfg.rxFifoBytes,
      inValid: addInput('d_in_valid', Logic()),
      inData: addInput('d_in_data', Logic(width: 8), width: 8),
      inLast: addInput('d_in_last', Logic()),
      inStatus: addInput('d_in_status', Logic(width: 8), width: 8),
      rReady: rReady,
    );
    final dma = HarborEthDmaRx(
      clk,
      port.reset,
      waist: port.waist,
      config: cfg,
      ringBase: addInput('d_ring_base', Logic(width: 32), width: 32),
      ringSize: addInput('d_ring_size', Logic(width: 4), width: 4),
      tail: addInput('d_tail', Logic(width: 12), width: 12),
      rxEn: addInput('d_rx_en', Logic()),
      keepBad: Const(0),
      ringReset: Const(0),
      rValid: fifo.rValid,
      rData: fifo.rData,
      rBytes: fifo.rBytes,
      rLast: fifo.rLast,
      rStatus: fifo.rStatus,
    );
    rReady <= dma.rReady;
    addOutput('d_head', width: 12) <= dma.head;
    addOutput('d_ring_err') <= dma.ringErr;
    addOutput('d_rx_missed') <= dma.rxMissed;
  }
}

Future<void> _fabric(HarborFabricKind kind) async {
  const sram = 0x80000000;
  final cfg = _cfg(outstanding: kind == HarborFabricKind.wishbone ? 1 : 4);
  final soc = HarborSoC(
    name: 'ethdmarx_${kind.name}',
    compatible: 'test,ethdmarx',
    fabricKind: kind,
    target: const HarborSimTarget(frequency: 50000000),
  );
  final cpu = soc.addMaster(_Cpu(kind));
  final eth = _EthMaster(kind, cfg);
  soc.addMaster(
    eth,
    busInterfaceName: 'bus',
    memory: true,
    outstanding: cfg.outstanding,
  );
  // Two SRAMs, so a burst across the 4 KB boundary between them would fail.
  for (var i = 0; i < 2; i++) {
    soc.addPeripheral(
      HarborSram(
        baseAddress: sram + 0x1000 * i,
        size: 4096,
        busAddressWidth: 32,
        protocol: kind,
        name: 'sram$i',
      ),
    );
  }
  cpu.pullUp(soc);
  for (final n in [..._dIns, ..._dOuts]) {
    soc.pullUpPort(eth.port(n), newPortName: n);
  }
  soc.buildFabric();
  final busError = soc.exposeBusError();
  final drv = {
    for (final n in _dIns) n: Logic(name: 'drv_$n', width: eth.port(n).width),
  };
  for (final e in drv.entries) {
    soc.input(e.key).srcConnection! <= e.value;
  }
  final clk = SimpleClockGenerator(10).clk;
  final bus = RegBus.attach(soc, clk, name: 'cpu', kind: kind);
  final reset = Logic(name: 'reset')..inject(1);
  soc.input('clk').srcConnection! <= clk;
  soc.input('reset').srcConnection! <= reset;
  await soc.build();
  bus.idle();
  for (final l in drv.values) {
    l.inject(0);
  }
  Simulator.setMaxSimTime(20000000);
  unawaited(Simulator.run());
  for (var i = 0; i < 8; i++) {
    await clk.nextPosedge;
  }
  reset.inject(0);
  for (var i = 0; i < 4; i++) {
    await clk.nextPosedge;
  }

  final rng = Random(7);
  // Frame 1 crosses the 4 KB boundary between the SRAMs. Frame 2 ends in
  // the middle of a word.
  final bufs = [(sram + 0x200, 64), (sram + 0xfa4, 210), (sram + 0x400, 8)];
  final lens = [64, 203, 7];
  const fill = 0xa5a5a5a5;
  const ring = sram + 0x100;
  for (var f = 0; f < bufs.length; f++) {
    final (a, size) = bufs[f];
    for (var w = a; w < a + size + 4; w += 4) {
      await bus.write(w, fill);
    }
    final d = ring + 16 * f;
    await bus.write(d, a);
    await bus.write(d + 4, 0);
    await bus.write(d + 8, size | (1 << 31));
    await bus.write(d + 12, 0);
  }
  final frames = [
    for (final l in lens) [for (var j = 0; j < l; j++) rng.nextInt(256)],
  ];

  await clk.nextNegedge;
  drv['d_ring_base']!.inject(ring);
  drv['d_ring_size']!.inject(3);
  drv['d_rx_en']!.inject(1);
  drv['d_tail']!.inject(bufs.length);
  for (var f = 0; f < frames.length; f++) {
    for (var j = 0; j < frames[f].length; j++) {
      final last = j == frames[f].length - 1;
      drv['d_in_valid']!.inject(1);
      drv['d_in_data']!.inject(frames[f][j]);
      drv['d_in_last']!.inject(last ? 1 : 0);
      drv['d_in_status']!.inject(last && f == 1 ? _bcast : 0);
      await clk.nextNegedge;
    }
    drv['d_in_valid']!.inject(0);
    for (var i = 0; i < 12; i++) {
      await clk.nextNegedge;
    }
  }
  for (
    var i = 0;
    i < 20000 &&
        soc.output('d_head').value.toInt() != bufs.length &&
        soc.output('d_ring_err').value.toInt() == 0;
    i++
  ) {
    await clk.nextPosedge;
  }
  expect(soc.output('d_head').value.toInt(), bufs.length);
  expect(soc.output('d_ring_err').value.toInt(), 0);
  for (var f = 0; f < bufs.length; f++) {
    final (a, size) = bufs[f];
    final got = <int>[];
    for (var w = a; w < a + size + 4; w += 4) {
      final v = await bus.read(w);
      for (var i = 0; i < 4; i++) {
        got.add((v >> (8 * i)) & 0xff);
      }
    }
    final want = [
      ...frames[f],
      for (var i = frames[f].length; i < got.length; i++) 0xa5,
    ];
    expect(got, want, reason: 'buffer $f');
    final d = ring + 16 * f;
    expect(await bus.read(d + 8), size, reason: 'OWN $f');
    expect(
      await bus.read(d + 12),
      _w3(lens[f], f == 1 ? _bcast : 0, 0),
      reason: 'word3 $f',
    );
  }
  expect(busError.value.toInt(), 0);
  await Simulator.endSimulation();
}

void main() {
  tearDown(() async => Simulator.reset());

  group('traffic', () {
    for (final latency in [0, 8, 20, 40]) {
      test('latency $latency, 4 in flight, 16 beats', () async {
        await _traffic(_cfg(), latency: latency, seed: latency + 1);
      });
    }
    test('latency 20, 1 in flight, 4 beats', () async {
      await _traffic(_cfg(outstanding: 1, burst: 4), latency: 20, seed: 5);
    });
    test('latency 8, 2 in flight, 1 beat', () async {
      await _traffic(_cfg(outstanding: 2, burst: 1), latency: 8, seed: 6);
    });
  });

  group('frames', () {
    test('no descriptor gives rx_missed and the next frame lands', () async {
      final b = await _Bench.make(_cfg(), latency: 8, seed: 11);
      final lost = b.data(300);
      b.src.push(lost, 0);
      await b.idle();
      expect(b.rxMissed, 1);
      expect(b.mem.writes, isEmpty);
      expect(b.mem.reads, isEmpty);
      expect(b.out('head'), 0);

      // OWN clear at head is also no descriptor.
      final skip = b.alloc(100);
      b.give([skip]);
      b.putDesc(0, skip.addr, 100, own: false);
      b.src.push(b.data(60), 0);
      await b.idle();
      expect(b.rxMissed, 2);
      expect(b.mem.writes, isEmpty);
      expect(b.out('head'), 0);

      b.putDesc(0, skip.addr, 100);
      final good = b.data(90);
      b.src.push(good, 0);
      await b.idle();
      expect(b.read(skip.addr, 90), good);
      expect(b.word3(0), _w3(90, 0, 0));
      expect(b.out('head'), 1);
      expect(b.rxDone, 1);
      expect(b.rxErr, 0);
      expect(b.out('ring_err'), 0);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('bad frames are dropped with keep_bad low', () async {
      final b = await _Bench.make(_cfg(), latency: 8, seed: 12);
      final buf = b.alloc(1600);
      b.give([buf]);
      for (final st in [_fcs, _runt, _oversize, _rxEr, _cut]) {
        b.src.push(b.data(200), st);
      }
      final good = b.data(120);
      b.src.push(good, _mcast);
      await b.idle();
      expect(b.out('head'), 1);
      expect(b.rxErr, 5);
      expect(b.rxDone, 1);
      expect(b.out('err_code'), HarborEthDmaRx.errCut);
      expect(b.word3(0), _w3(120, _mcast, 0));
      expect(b.read(buf.addr, 120), good);
      final descWrites = b.mem.writes.where(
        (w) => w.addr >= b.ringBase && w.addr < 0x9000,
      );
      expect(descWrites.length, 2, reason: 'one write-back');
      expect(b.out('ring_err'), 0);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('keep_bad writes back each error code', () async {
      final b = await _Bench.make(_cfg(), latency: 0, seed: 13, ringLog2: 4);
      b.s.set('keep_bad', 1);
      final cases = [
        (_fcs, HarborEthDmaRx.errFcs),
        (_runt, HarborEthDmaRx.errRunt),
        (_oversize, HarborEthDmaRx.errOversize),
        (_rxEr, HarborEthDmaRx.errRxEr),
        (_cut, HarborEthDmaRx.errCut),
        (_fcs | _runt, HarborEthDmaRx.errFcs),
        (_runt | _oversize | _bcast, HarborEthDmaRx.errOversize),
        (_fcs | _rxEr, HarborEthDmaRx.errRxEr),
        (_cut | _rxEr | _fcs, HarborEthDmaRx.errCut),
      ];
      final bufs = [for (final _ in cases) b.alloc(64)];
      final idx = b.give(bufs);
      final lens = <int>[];
      for (final c in cases) {
        final len = 10 + b.rng.nextInt(50);
        lens.add(len);
        b.src.push(b.data(len), c.$1);
      }
      await b.idle();
      for (var i = 0; i < cases.length; i++) {
        // The word with the cut status adds no bytes.
        final tailBytes = lens[i] % 4 == 0 ? 4 : lens[i] % 4;
        final len = cases[i].$1 & _cut != 0 ? lens[i] - tailBytes : lens[i];
        expect(
          b.word3(idx[i]),
          _w3(len, cases[i].$1, cases[i].$2),
          reason: 'case $i',
        );
        expect(b.word2(idx[i]) >> 31, 0);
      }
      expect(b.rxDone, cases.length);
      expect(b.rxErr, cases.length);
      expect(b.out('head'), cases.length);
      expect(b.out('ring_err'), 0);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('a frame longer than the buffer gets err 3', () async {
      final b = await _Bench.make(_cfg(), latency: 8, seed: 14);
      // Buffer sizes: whole words, a part word, one byte short, empty.
      final sizes = [100, 101, 102, 0];
      final lens = [150, 400, 103, 20];
      final bufs = [for (final s in sizes) b.alloc(s, cross: true)];
      final idx = b.give(bufs);
      final frames = [for (final l in lens) b.data(l)];
      for (final f in frames) {
        b.src.push(f, 0);
      }
      final good = b.data(30);
      final last = b.alloc(40);
      b.give([last]);
      b.src.push(good, 0);
      await b.idle();
      for (var i = 0; i < sizes.length; i++) {
        expect(
          b.word3(idx[i]),
          _w3(sizes[i], 0, HarborEthDmaRx.errOversize),
          reason: 'buffer $i',
        );
        expect(b.read(bufs[i].addr, sizes[i]), frames[i].sublist(0, sizes[i]));
        b.untouched(bufs[i].addr + sizes[i], 8, 'buffer $i end');
      }
      expect(b.read(last.addr, 30), good);
      expect(b.word3(4), _w3(30, 0, 0));
      expect(b.rxErr, 4);
      expect(b.rxDone, 5);
      expect(b.out('ring_err'), 0);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test(
      'a bad frame longer than the buffer drops with keep_bad low',
      () async {
        final b = await _Bench.make(_cfg(), latency: 8, seed: 19);
        final buf = b.alloc(40);
        b.give([buf]);
        b.src.push(b.data(100), _fcs);
        final good = b.data(30);
        b.src.push(good, 0);
        await b.idle();
        expect(b.rxErr, 1);
        expect(b.rxDone, 1);
        expect(b.out('head'), 1);
        expect(b.word3(0), _w3(30, 0, 0));
        expect(b.read(buf.addr, 30), good);
        expect(b.errors, isEmpty);
        await b.s.stop();
      },
    );

    test('an unaligned buffer gets err 3 and no data', () async {
      final b = await _Bench.make(_cfg(), latency: 8, seed: 15);
      final buf = b.alloc(200);
      b.putDesc(0, buf.addr + 2, 198);
      b.tail = 1;
      b.s.set('tail', 1);
      b.src.push(b.data(50), 0);
      await b.idle();
      expect(b.word3(0), _w3(0, 0, HarborEthDmaRx.errOversize));
      expect(b.mem.writes.every((w) => w.addr < 0x9000), isTrue);
      expect(b.rxErr, 1);
      expect(b.out('head'), 1);

      // An address above the 32-bit waist is not cut to its low bits.
      final high = b.alloc(200);
      b.give([high]);
      b.mem.putWord(b.descAddr(1) + 4, 1);
      b.src.push(b.data(50), 0);
      await b.idle();
      expect(b.word3(1), _w3(0, 0, HarborEthDmaRx.errOversize));
      expect(b.mem.writes.every((w) => w.addr < 0x9000), isTrue);
      expect(b.rxErr, 2);
      expect(b.out('head'), 2);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('rx_en low pauses between frames and keeps head', () async {
      final b = await _Bench.make(_cfg(), latency: 8, seed: 16);
      final bufs = [b.alloc(200), b.alloc(200)];
      b.give(bufs);
      final a = b.data(150);
      b.src.push(a, 0);
      await b.idle();
      expect(b.out('head'), 1);
      b.s.set('rx_en', 0);
      final c = b.data(80);
      b.src.push(c, 0);
      await b.s.cycles(200);
      expect(b.out('head'), 1);
      expect(b.out('busy'), 0);
      expect(b.src.pending, 1, reason: 'frame waits in the FIFO');
      b.s.set('rx_en', 1);
      await b.idle();
      expect(b.out('head'), 2);
      expect(b.read(bufs[1].addr, 80), c);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('ring_reset in a frame waits for the frame to end', () async {
      final b = await _Bench.make(_cfg(), latency: 20, seed: 17);
      final bufs = [b.alloc(1600), b.alloc(1600)];
      b.give(bufs);
      final a = b.data(1500);
      b.src.push(a, 0);
      await b.until(() => b.mem.writes.length > 3);
      await b.pulse('ring_reset');
      await b.idle();
      expect(b.read(bufs[0].addr, 1500), a);
      expect(b.word3(0), _w3(1500, 0, 0));
      expect(b.out('head'), 0, reason: 'reset after the frame');
      expect(b.word2(1) >> 31, 1);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('ring_reset blocks a frame that arrives with it', () async {
      final b = await _Bench.make(_cfg(), latency: 8, seed: 18);
      final bufs = [b.alloc(100), b.alloc(100), b.alloc(100)];
      b.give(bufs);
      b.src.push(b.data(40), 0);
      await b.idle();
      expect(b.out('head'), 1);
      // Desc 0 is given again with the reset.
      b.putDesc(0, bufs[2].addr, 100);
      final c = b.data(70);
      b.src.push(c, 0);
      await b.pulse('ring_reset');
      await b.idle();
      expect(b.out('head'), 1);
      expect(b.read(bufs[2].addr, 70), c);
      expect(b.word2(1) >> 31, 1, reason: 'old head not used');
      expect(b.errors, isEmpty);
      await b.s.stop();
    });
  });

  group('errors', () {
    test('a buffer write error stops the ring', () async {
      final b = await _Bench.make(_cfg(), latency: 8, seed: 21);
      final bufs = [b.alloc(1600), b.alloc(1600)];
      b.give(bufs);
      final ea = bufs[0].addr + 400;
      b.mem.writeErrRanges.add((ea, ea + 4));
      b.src.push(b.data(1000), 0);
      final next = b.data(64);
      b.src.push(next, 0);
      await b.until(() => b.src.pending == 1 && b.out('busy') == 0);
      await b.s.cycles(100);
      expect(b.out('ring_err'), 1);
      expect(b.out('err_code'), HarborEthDmaRx.errWrite);
      expect(b.out('head'), 0);
      expect(b.rxErr, 1);
      expect(b.rxDone, 0);
      expect(b.src.pending, 1, reason: 'the bad frame drained, no next one');
      expect(b.word2(0) >> 31, 1, reason: 'OWN stays set');
      expect(b.word3(0), 0xdead0000);
      expect(b.mem.writesAfterErr, 0);
      expect(b.errors, isEmpty);

      // A ring reset clears the error and the next frame lands at 0.
      b.mem.writeErrRanges.clear();
      b.tail = 0;
      b.give([b.alloc(100)]);
      await b.s.cycles(20);
      expect(b.src.pending, 1, reason: 'no frame while ring_err is set');
      await b.pulse('ring_reset');
      await b.idle();
      expect(b.out('ring_err'), 0);
      expect(b.word3(0), _w3(64, 0, 0));
      expect(b.out('head'), 1);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('a word 3 write error leaves OWN set', () async {
      final b = await _Bench.make(_cfg(), latency: 8, seed: 22);
      b.give([b.alloc(100)]);
      b.mem.writeErrRanges.add((b.descAddr(0) + 12, b.descAddr(0) + 16));
      b.src.push(b.data(50), 0);
      await b.idle();
      await b.s.cycles(20);
      expect(b.out('ring_err'), 1);
      expect(b.out('err_code'), HarborEthDmaRx.errWrite);
      expect(b.word2(0) >> 31, 1);
      expect(b.mem.writesAfterErr, 0);
      expect(
        b.mem.writes.where((w) => w.addr >= 0x8000 && w.addr < 0x9000).length,
        1,
      );
      expect(b.out('head'), 0);
      expect(b.rxErr, 1);
      expect(b.rxDone, 0);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('a descriptor read error stops the ring', () async {
      final b = await _Bench.make(_cfg(), latency: 0, seed: 23);
      b.give([b.alloc(100)]);
      b.mem.errRanges.add((b.descAddr(0), b.descAddr(0) + 16));
      b.src.push(b.data(50), 0);
      await b.idle();
      expect(b.out('ring_err'), 1);
      expect(b.out('err_code'), HarborEthDmaRx.errWrite);
      expect(b.mem.writes, isEmpty);
      expect(b.out('head'), 0);
      expect(b.rxErr, 1);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('a frame that vanishes on the descriptor path ends', () async {
      final b = await _Bench.make(_cfg(), latency: 40, seed: 25, gap: 0);
      final bufs = [b.alloc(1600), b.alloc(1600), b.alloc(1600)];
      b.give(bufs);
      final first = b.data(64);
      b.src.push(first, 0);
      await b.idle();
      expect(b.out('head'), 1);
      b.src.push(b.data(600), 0);
      await b.until(() => b.out('busy') == 1 && b.mem.reads.length == 2);
      b.src.vanish();
      await b.until(() => b.out('busy') == 0, limit: 2000);
      expect(b.mem.writeBusy, isFalse, reason: 'no write left open');
      expect(b.out('head'), 1);
      expect(b.word2(1) >> 31, 1, reason: 'descriptor not used');
      final next = b.data(90);
      b.src.push(next, 0);
      await b.idle();
      expect(b.read(bufs[1].addr, 90), next);
      expect(b.out('head'), 2);
      await b.pulse('ring_reset');
      await b.s.cycles(4);
      expect(b.out('head'), 0);
      expect(b.out('ring_err'), 0);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('a vanished frame kept with keep_bad has no abort bytes', () async {
      final b = await _Bench.make(_cfg(), latency: 40, seed: 27, gap: 0);
      b.s.set('keep_bad', 1);
      final buf = b.alloc(1600);
      b.give([buf]);
      final f = b.data(600);
      b.src.push(f, 0);
      await b.until(() => b.out('busy') == 1 && b.mem.reads.length == 1);
      b.src.vanish();
      await b.until(() => b.out('busy') == 0, limit: 2000);
      expect(b.word3(0), _w3(4, 0, HarborEthDmaRx.errCut));
      expect(b.read(buf.addr, 4), f.sublist(0, 4));
      b.untouched(buf.addr + 4, 8, 'abort word');
      expect(b.out('head'), 1);
      expect(b.mem.writeBusy, isFalse);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('a frame that vanishes on the missed path ends', () async {
      final b = await _Bench.make(_cfg(), latency: 8, seed: 26, gap: 0);
      b.give([b.alloc(200)]);
      b.src.push(b.data(64), 0);
      await b.idle();
      expect(b.out('head'), 1);
      b.src.push(b.data(600), 0);
      await b.until(() => b.out('busy') == 1);
      b.src.vanish();
      await b.until(() => b.out('busy') == 0, limit: 2000);
      await b.s.cycles(2);
      expect(b.rxMissed, 1);
      await b.pulse('ring_reset');
      await b.s.cycles(4);
      expect(b.out('head'), 0);
      b.tail = 0;
      final buf = b.alloc(200);
      b.give([buf]);
      final next = b.data(70);
      b.src.push(next, 0);
      await b.idle();
      expect(b.read(buf.addr, 70), next);
      expect(b.out('head'), 1);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('write-back waits for the last WRESP at a long latency', () async {
      final b = await _Bench.make(_cfg(), latency: 60, seed: 24, stall: 0);
      final bufs = [b.alloc(1600), b.alloc(1600)];
      b.give(bufs);
      final a = b.data(1522);
      final c = b.data(1500);
      b.src
        ..gap = 0
        ..push(a, 0)
        ..push(c, 0);
      await b.idle();
      expect(b.read(bufs[0].addr, 1522), a);
      expect(b.read(bufs[1].addr, 1500), c);
      expect(b.errors, isEmpty);
      expect(b.word3(0), _w3(1522, 0, 0));
      expect(b.word3(1), _w3(1500, 0, 0));
      expect(b.word2(0), 1600);
      expect(b.word2(1), 1600);
      expect(b.mem.maxInflight, 4);
      await b.s.stop();
    });
  });

  group('fabric', () {
    for (final kind in HarborFabricKind.values) {
      test('${kind.name}: frames from the FIFO reach SRAM', () async {
        await _fabric(kind);
      });
    }
  });
}
