import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
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
  'tx_done',
  'tx_err',
  'ring_err',
  'err_code',
  'busy',
  'w_valid',
  'w_data',
  'w_bytes',
  'w_last',
  'w_err',
];

/// The DMA with its waist on ports `mem_*`.
class _Top extends BridgeModule {
  _Top(HarborEthernetConfig cfg, int waistOutstanding)
    : super(
        'EthDmaTxTop_d${cfg.descBytes}_o${cfg.outstanding}'
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
    final dma = HarborEthDmaTx(
      input('clk'),
      input('reset'),
      waist: w,
      config: cfg,
      ringBase: addInput('ring_base', Logic(width: 32), width: 32),
      ringSize: addInput('ring_size', Logic(width: 4), width: 4),
      tail: addInput('tail', Logic(width: 12), width: 12),
      txEn: addInput('tx_en', Logic()),
      ringReset: addInput('ring_reset', Logic()),
      wReady: addInput('w_ready', Logic()),
      wFree: Const(
        cfg.txFifoBytes ~/ 4,
        width: (cfg.txFifoBytes ~/ 4).bitLength,
      ),
      txClkLost: addInput('tx_clk_lost', Logic()),
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
  final Map<int, int> bytes = {};

  /// Byte ranges [lo, hi) that answer with an error.
  final List<(int, int)> errRanges = [];

  /// Byte ranges [lo, hi) where a write answers with an error.
  final List<(int, int)> writeErrRanges = [];

  /// Word 3 addresses whose write has its WRESP.
  final Set<int> _w3Done = {};

  /// Called for each read request.
  void Function(_Req)? onRead;
  final Queue<_Req> _rq = Queue();
  final Queue<_Req> _wq = Queue();
  final Queue<(int, bool, int)> _bq = Queue();
  final List<_Req> reads = [];
  final List<_Req> writes = [];
  int inflight = 0;
  int maxInflight = 0;
  bool _rBusy = false;
  bool _bBusy = false;

  /// Checked on each write request. True when the request is legal now.
  bool Function()? writeGate;

  _Mem(
    this.s,
    this.rng, {
    required this.latency,
    required this.stall,
    required this.limit,
    required this.errors,
    required this.now,
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

  bool get readBusy => _rq.isNotEmpty;
  bool get writeBusy => _wq.isNotEmpty || _bq.isNotEmpty;

  int _p(String n) => s.pre('mem_$n');
  void _set(String n, int v) => s.set('mem_$n', v);

  void _rise() {
    final reqFire = _p('REQ_VALID') == 1 && _p('REQ_READY') == 1;
    final reqW = reqFire && _p('REQ_WRITE') == 1;
    if (_p('RDATA_READY') == 1 && _rq.isEmpty && !(reqFire && !reqW)) {
      errors.add('RDATA_READY high with no read in flight');
    }
    if (_p('WRESP_READY') == 1 && !writeBusy && !reqW) {
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
      if (done.$3 & 0xf == 12) _w3Done.add(done.$3);
      inflight--;
    }
    if (_p('WDATA_VALID') == 1 && _p('WDATA_READY') == 1) {
      final w = _wq.first;
      final a = w.addr + 4 * w.beat;
      final strb = _p('WDATA_STRB');
      final data = _p('WDATA_DATA');
      if ((_p('WDATA_LAST') == 1) != (w.beat == w.len)) {
        errors.add('WDATA_LAST wrong at 0x${a.toRadixString(16)}');
      }
      if (!_isWErr(a)) {
        for (var i = 0; i < 4; i++) {
          if (strb & (1 << i) != 0) bytes[a + i] = (data >> (8 * i)) & 0xff;
        }
      }
      w.beat++;
      if (w.beat > w.len) {
        _wq.removeFirst();
        _bq.add((now() + latency, _isWErr(w.addr), w.addr));
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
        if (_rq.isNotEmpty) errors.add('write-back passed a buffer read');
        if (writeGate != null && !writeGate!()) {
          errors.add('write-back before the frame is in the FIFO');
        }
        if (_wq.isNotEmpty || _bq.isNotEmpty || _bBusy) {
          errors.add('write issued before the previous WRESP');
        }
        if (addr & 0xf == 8 && !_w3Done.remove(addr + 4)) {
          errors.add('OWN clear before word 3 has its WRESP');
        }
        writes.add(r);
        _wq.add(r);
      } else {
        reads.add(r);
        _rq.add(r);
        onRead?.call(r);
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

/// The FIFO write side: random READY, frames collected whole.
class _Sink {
  final Sim s;
  final Random rng;
  double stall;
  final List<String> errors;
  final List<List<int>> frames = [];
  int dropped = 0;
  int words = 0;
  final List<int> _cur = [];
  bool _err = false;

  _Sink(this.s, this.rng, this.stall, this.errors) {
    s.onRise(() {
      if (s.pre('w_valid') != 1 || s.pre('w_ready') != 1) return;
      words++;
      final last = s.pre('w_last') == 1;
      final nb = s.pre('w_bytes');
      if (!last && nb != 0)
        errors.add('w_bytes $nb on a word that is not last');
      final n = last && nb != 0 ? nb : 4;
      final d = s.pre('w_data');
      for (var i = 0; i < n; i++) {
        _cur.add((d >> (8 * i)) & 0xff);
      }
      _err = _err || s.pre('w_err') == 1;
      if (last) {
        if (_err) {
          dropped++;
        } else {
          frames.add(List.of(_cur));
        }
        _cur.clear();
        _err = false;
      }
    });
    s.onFall(() => s.set('w_ready', rng.nextDouble() >= stall ? 1 : 0));
  }

  /// No frame is open and no word waits.
  bool get closed => _cur.isEmpty && !_err && s.pre('w_valid') == 0;
}

class _Frame {
  final List<(int, int)> bufs;
  final List<int> data;
  final bool irq;
  _Frame(this.bufs, this.data, this.irq);
}

class _Bench {
  final Sim s;
  final HarborEthernetConfig cfg;
  final Random rng;
  final List<String> errors = [];
  late final _Mem mem;
  late final _Sink sink;
  int cycle = 0;
  int txDone = 0;
  int txErr = 0;
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
    double fifoStall = 0.3,
    int seed = 1,
    int ringBase = 0x8000,
    int ringLog2 = 3,
  }) async {
    final s = Sim(_Top(cfg, cfg.outstanding));
    final b = _Bench._(s, cfg, Random(seed), ringBase)..ringLog2 = ringLog2;
    s.onRise(() => b.cycle++);
    b.mem = _Mem(
      s,
      b.rng,
      latency: latency,
      stall: stall,
      limit: cfg.outstanding,
      errors: b.errors,
      now: () => b.cycle,
    );
    b.sink = _Sink(s, b.rng, fifoStall, b.errors);
    b.mem.writeGate = () => b.sink.closed;
    s.onRise(() {
      if (s.pre('tx_done') == 1) b.txDone++;
      if (s.pre('tx_err') == 1) b.txErr++;
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
      ..set('tx_en', 1);
    return b;
  }

  int get mask => (1 << ringLog2) - 1;
  int out(String n) => s.dut.output(n).value.toInt();
  int descAddr(int i) => ringBase + i * cfg.descBytes;

  void putDesc(
    int i,
    int addr,
    int len, {
    bool sop = false,
    bool eop = false,
    bool irq = false,
    bool own = true,
  }) {
    final a = descAddr(i);
    mem
      ..putWord(a, addr)
      ..putWord(a + 4, 0)
      ..putWord(
        a + 8,
        len |
            (sop ? 1 << 16 : 0) |
            (eop ? 1 << 17 : 0) |
            (irq ? 1 << 18 : 0) |
            (own ? 1 << 31 : 0),
      )
      ..putWord(a + 12, 0xdead0000);
  }

  /// A buffer of [len] bytes at a random offset, or across a 4 KB boundary.
  int alloc(int len, {bool cross = false}) {
    int start;
    if (cross && len > 1) {
      final boundary = ((ptr + 4095) & ~4095) + 4096;
      start = boundary - 1 - rng.nextInt(min(len - 1, 300));
    } else {
      start = ptr + rng.nextInt(64);
    }
    ptr = start + len + 1;
    return start;
  }

  _Frame frame(
    int total,
    int nbufs, {
    bool irq = false,
    bool cross = false,
    List<int>? lens,
  }) {
    final cuts = [for (var i = 1; i < nbufs; i++) rng.nextInt(total + 1)]
      ..sort();
    var edges = [0, ...cuts, total];
    if (lens != null) {
      nbufs = lens.length;
      edges = [0];
      for (final l in lens) {
        edges.add(edges.last + l);
      }
    }
    final bufs = <(int, int)>[];
    final data = <int>[];
    for (var i = 0; i < nbufs; i++) {
      final len = edges[i + 1] - edges[i];
      final a = alloc(len, cross: cross && rng.nextBool());
      for (var j = 0; j < len; j++) {
        final v = rng.nextInt(256);
        mem.bytes[a + j] = v;
        data.add(v);
      }
      bufs.add((a, len));
    }
    return _Frame(bufs, data, irq);
  }

  /// Puts the descriptors of [frames] at the tail. Returns the first index of
  /// each frame.
  List<int> give(List<_Frame> frames) {
    final starts = <int>[];
    for (final f in frames) {
      starts.add(tail);
      for (var i = 0; i < f.bufs.length; i++) {
        final last = i == f.bufs.length - 1;
        putDesc(
          tail,
          f.bufs[i].$1,
          f.bufs[i].$2,
          sop: i == 0,
          eop: last,
          irq: last && f.irq,
        );
        tail = (tail + 1) & mask;
      }
    }
    s.set('tail', tail);
    return starts;
  }

  Future<void> until(bool Function() done, {int limit = 20000}) async {
    for (var i = 0; i < limit && !done(); i++) {
      await s.cycles(1);
    }
    expect(
      done(),
      isTrue,
      reason:
          'timed out: head ${out('head')} tail $tail busy ${out('busy')} '
          'err ${out('ring_err')} errors ${errors.take(5)}',
    );
  }

  /// Waits for the ring to empty or stop, then for the pulses to count.
  Future<void> idle() async {
    await until(() => out('head') == tail || out('ring_err') == 1);
    await s.cycles(2);
  }

  int word2(int i) => mem.word(descAddr(i) + 8);
  int word3(int i) => mem.word(descAddr(i) + 12);
}

HarborEthernetConfig _cfg({int outstanding = 4, int burst = 16}) =>
    HarborEthernetConfig(
      phy: HarborEthPhy.rgmii,
      outstanding: outstanding,
      burstBeats: burst,
    );

/// Sends [batches] of random frames and checks each one.
Future<void> _traffic(
  HarborEthernetConfig cfg, {
  required int latency,
  required int seed,
  int batches = 3,
}) async {
  final b = await _Bench.make(cfg, latency: latency, seed: seed);
  final sent = <_Frame>[];
  var irqs = 0;
  for (var k = 0; k < batches; k++) {
    final frames = <_Frame>[];
    var descs = 0;
    while (true) {
      final nb = 1 + b.rng.nextInt(3);
      if (descs + nb > b.mask) break;
      final total = 1 + b.rng.nextInt(HarborEthDmaTx.maxFrameBytes);
      final f = b.frame(total, nb, irq: b.rng.nextBool(), cross: true);
      frames.add(f);
      descs += nb;
      if (frames.length == 3) break;
    }
    final w2 = <int, int>{};
    final first = b.tail;
    b.give(frames);
    for (var i = 0; i < descs; i++) {
      final d = (first + i) & b.mask;
      w2[d] = b.word2(d);
    }
    await b.idle();
    expect(b.out('ring_err'), 0);
    for (final e in w2.entries) {
      expect(b.word2(e.key), e.value & 0x7fffffff, reason: 'OWN cleared');
      expect(b.word3(e.key), 1, reason: 'done, err 0');
    }
    sent.addAll(frames);
    irqs += frames.where((f) => f.irq).length;
  }
  await b.s.cycles(4);
  expect(b.errors, isEmpty);
  expect(b.sink.dropped, 0);
  expect(b.sink.frames.length, sent.length);
  for (var i = 0; i < sent.length; i++) {
    expect(
      b.sink.frames[i],
      sent[i].data,
      reason:
          'frame $i ${sent[i].bufs} got ${b.sink.frames[i].length} ${b.sink.frames[i].take(8)} want ${sent[i].data.take(8)}',
    );
  }
  expect(b.txDone, irqs);
  expect(b.txErr, 0);
  expect(b.mem.maxInflight, lessThanOrEqualTo(cfg.outstanding));
  if (cfg.outstanding > 1 && latency >= 8) {
    expect(b.mem.maxInflight, greaterThan(1), reason: 'reads pipeline');
  }
  final crossed = sent.any(
    (f) => f.bufs.any(
      (r) => r.$2 > 1 && (r.$1 >> 12) != ((r.$1 + r.$2 - 1) >> 12),
    ),
  );
  expect(crossed, isTrue, reason: 'a buffer crosses 4 KB');
  final ring = {for (var i = 0; i <= b.mask; i++) b.descAddr(i)};
  final maxBeats = b.mem.reads
      .where((r) => !ring.contains(r.addr))
      .map((r) => r.len + 1)
      .reduce(max);
  expect(maxBeats, lessThanOrEqualTo(cfg.burstBeats));
  await b.s.stop();
}

/// A register master whose native port pins are plain `p_<PORT>` ports.
class _Cpu extends BridgeModule {
  _Cpu(HarborFabricKind kind) : super('EthDmaCpu_${kind.name}', name: 'cpu') {
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

const _dIns = ['d_ring_base', 'd_ring_size', 'd_tail', 'd_tx_en', 'd_in_ready'];
const _dOuts = ['d_head', 'd_ring_err', 'd_in_valid', 'd_in_data', 'd_in_last'];

/// The DMA and a TX frame FIFO behind a memory master port named `bus`.
class _EthMaster extends BridgeModule {
  _EthMaster(HarborFabricKind kind, HarborEthernetConfig cfg)
    : super('EthDmaTxMaster_${kind.name}_n${cfg.outstanding}', name: 'ethdma') {
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
    final wReady = Logic(name: 'fifo_w_ready');
    final wFree = Logic(
      name: 'fifo_w_free',
      width: (cfg.txFifoBytes ~/ 4).bitLength,
    );
    final lost = Logic(name: 'fifo_lost');
    final dma = HarborEthDmaTx(
      clk,
      port.reset,
      waist: port.waist,
      config: cfg,
      ringBase: addInput('d_ring_base', Logic(width: 32), width: 32),
      ringSize: addInput('d_ring_size', Logic(width: 4), width: 4),
      tail: addInput('d_tail', Logic(width: 12), width: 12),
      txEn: addInput('d_tx_en', Logic()),
      ringReset: Const(0),
      wReady: wReady,
      wFree: wFree,
      txClkLost: lost,
    );
    final fifo = HarborEthTxFrameFifo(
      clk,
      port.reset,
      clk,
      port.reset,
      bytes: cfg.txFifoBytes,
      wValid: dma.wValid,
      wData: dma.wData,
      wBytes: dma.wBytes,
      wLast: dma.wLast,
      wErr: dma.wErr,
      inReady: addInput('d_in_ready', Logic()),
    );
    wReady <= fifo.wReady;
    wFree <= fifo.wFree;
    lost <= fifo.clkLost;
    addOutput('d_head', width: 12) <= dma.head;
    addOutput('d_ring_err') <= dma.ringErr;
    addOutput('d_in_valid') <= fifo.inValid;
    addOutput('d_in_data', width: 8) <= fifo.inData;
    addOutput('d_in_last') <= fifo.inLast;
  }
}

Future<void> _fabric(HarborFabricKind kind) async {
  const sram = 0x80000000;
  final cfg = _cfg(outstanding: kind == HarborFabricKind.wishbone ? 1 : 4);
  final soc = HarborSoC(
    name: 'ethdma_${kind.name}',
    compatible: 'test,ethdma',
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
  final memBytes = <int, int>{};
  Future<void> putBytes(int a, List<int> data) async {
    for (var i = 0; i < data.length; i++) {
      memBytes[a + i] = data[i];
    }
    for (var w = a & ~3; w < a + data.length; w += 4) {
      var v = 0;
      for (var i = 3; i >= 0; i--) {
        v = (v << 8) | (memBytes[w + i] ?? 0);
      }
      await bus.write(w, v);
    }
  }

  // Frame 0: one aligned buffer. Frame 1: three unaligned buffers, one
  // across the 4 KB boundary of the SRAM.
  final bufs = [
    [(sram + 0x200, 64)],
    [(sram + 0x301, 7), (sram + 0xfe3, 70), (sram + 0x1102, 13)],
  ];
  final frames = <List<int>>[];
  const ring = sram + 0x100;
  var idx = 0;
  for (var f = 0; f < bufs.length; f++) {
    final all = <int>[];
    for (var i = 0; i < bufs[f].length; i++) {
      final (a, len) = bufs[f][i];
      final data = [for (var j = 0; j < len; j++) rng.nextInt(256)];
      all.addAll(data);
      await putBytes(a, data);
      final last = i == bufs[f].length - 1;
      final d = ring + 16 * idx++;
      await bus.write(d, a);
      await bus.write(d + 4, 0);
      await bus.write(d + 8, len | (last ? 1 << 17 : 0) | (1 << 31));
      await bus.write(d + 12, 0);
    }
    frames.add(all);
  }

  final got = <List<int>>[];
  final cur = <int>[];
  clk.posedge.listen((_) {
    if (soc.output('d_in_valid').previousValue?.toBool() ?? false) {
      cur.add(soc.output('d_in_data').previousValue!.toInt());
      if (soc.output('d_in_last').previousValue!.toBool()) {
        got.add(List.of(cur));
        cur.clear();
      }
    }
  });
  await clk.nextNegedge;
  drv['d_ring_base']!.inject(ring);
  drv['d_ring_size']!.inject(3);
  drv['d_in_ready']!.inject(1);
  drv['d_tx_en']!.inject(1);
  drv['d_tail']!.inject(idx);
  for (var i = 0; i < 20000 && soc.output('d_head').value.toInt() != idx; i++) {
    await clk.nextPosedge;
  }
  expect(soc.output('d_head').value.toInt(), idx);
  for (var i = 0; i < 200 && got.length < frames.length; i++) {
    await clk.nextPosedge;
  }
  expect(soc.output('d_ring_err').value.toInt(), 0);
  expect(got, frames);
  for (var i = 0; i < idx; i++) {
    expect(await bus.read(ring + 16 * i + 8) >> 31, 0, reason: 'OWN $i');
    expect(await bus.read(ring + 16 * i + 12), 1, reason: 'word3 $i');
  }
  expect(busError.value.toInt(), 0);
  await Simulator.endSimulation();
}

/// The DMA on a real TX FIFO (same clock). The FIFO read side is on ports
/// `in_valid`, `in_data`, `in_last` and `in_ready`.
class _FifoTop extends BridgeModule {
  _FifoTop(HarborEthernetConfig cfg)
    : super(
        'EthDmaTxFifoTop_o${cfg.outstanding}_b${cfg.burstBeats}'
        '_f${cfg.txFifoBytes}',
        name: 'top',
      ) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final clk = input('clk');
    final reset = input('reset');
    final w = HarborMemoryWaist(
      HarborMemoryWaistConfig(
        addressWidth: 32,
        dataWidth: 32,
        outstanding: cfg.outstanding,
      ),
    );
    final fw = (cfg.txFifoBytes ~/ 4).bitLength;
    final wReady = Logic(name: 'f_w_ready');
    final wFree = Logic(name: 'f_w_free', width: fw);
    final wDrop = Logic(name: 'f_w_drop');
    final dma = HarborEthDmaTx(
      clk,
      reset,
      waist: w,
      config: cfg,
      ringBase: addInput('ring_base', Logic(width: 32), width: 32),
      ringSize: addInput('ring_size', Logic(width: 4), width: 4),
      tail: addInput('tail', Logic(width: 12), width: 12),
      txEn: addInput('tx_en', Logic()),
      ringReset: Const(0),
      wReady: wReady,
      wFree: wFree,
      txClkLost: wDrop,
    );
    final fifo = HarborEthTxFrameFifo(
      clk,
      reset,
      clk,
      reset,
      bytes: cfg.txFifoBytes,
      wValid: dma.wValid,
      wData: dma.wData,
      wBytes: dma.wBytes,
      wLast: dma.wLast,
      wErr: dma.wErr,
      inReady: addInput('in_ready', Logic()),
    );
    wReady <= fifo.wReady;
    wFree <= fifo.wFree;
    wDrop <= fifo.wDrop;
    exposeWaist(this, w, 'mem', PairRole.provider);
    for (final n in ['head', 'tx_done', 'tx_err', 'ring_err', 'err_code']) {
      addOutput(n, width: dma.output(n).width) <= dma.output(n);
    }
    addOutput('in_valid') <= fifo.inValid;
    addOutput('in_data', width: 8) <= fifo.inData;
    addOutput('in_last') <= fifo.inLast;
  }
}

/// Sends frames of [lens] (byte lengths of their buffers) through the DMA
/// and a real TX FIFO, each buffer at byte offset [offsets]. The FIFO read
/// side takes one byte every [every] cycles, so the FIFO fills. Returns the
/// frames read from the FIFO, the word 3 values, the error code, the memory
/// model errors and whether the DMA hangs. It runs in its own isolate, so
/// it has no `expect`.
Future<(List<List<int>>, List<int>, int, List<String>, bool)> _realFifo(
  HarborEthernetConfig cfg,
  List<List<int>> lens,
  List<int> offsets, {
  int every = 2,
  int limit = 200000,
  bool fill = false,
  double stall = 0.1,
}) async {
  final s = Sim(_FifoTop(cfg));
  final rng = Random(3);
  final errors = <String>[];
  var cycle = 0;
  s.onRise(() => cycle++);
  final mem = _Mem(
    s,
    rng,
    latency: 2,
    stall: stall,
    limit: cfg.outstanding,
    errors: errors,
    now: () => cycle,
  );
  final got = <List<int>>[];
  final cur = <int>[];
  s.onRise(() {
    if (s.pre('in_valid') != 1 || s.pre('in_ready') != 1) return;
    cur.add(s.pre('in_data'));
    if (s.pre('in_last') == 1) {
      got.add(List.of(cur));
      cur.clear();
    }
  });
  s.onFall(() => s.set('in_ready', cycle % every == 0 ? 1 : 0));
  await s.start();

  // On each cycle, `w_free` stays below the size, and the words in the FIFO
  // plus the words the DMA still owes never pass the size.
  Module find(Module m, bool Function(Module) f) =>
      m.subModules.firstWhere(f, orElse: () => find(m.subModules.first, f));
  final dma = find(s.dut, (m) => m is HarborEthDmaTx);
  final fifo = find(s.dut, (m) => m is HarborEthTxFrameFifo);
  Logic sig(Module m, String n) => m.signals.firstWhere((x) => x.name == n);
  final words = cfg.txFifoBytes ~/ 4;
  final pw = words.bitLength;
  final wFree = sig(fifo, 'w_free');
  final wPtr = sig(fifo, 'w_ptr');
  final fPtr = sig(fifo, 'f_ptr');
  final resv = sig(dma, 'resv_beats');
  final oValid = sig(dma, 'o_valid');
  final accN = sig(dma, 'acc_n');
  final state = sig(dma, 'state');
  var minFree = words;
  s.onRise(() {
    int v(Logic l) {
      final x = l.previousValue;
      return x == null || !x.isValid ? 0 : x.toInt();
    }

    final free = v(wFree);
    if (free < minFree) minFree = free;
    if (free > words - 1 && errors.length < 5) {
      errors.add('cycle $cycle: w_free $free above ${words - 1}');
    }
    final used = (v(wPtr) - v(fPtr)) & ((1 << pw) - 1);
    // In the last flush state the part word is already in `o_valid`.
    final part = v(accN) != 0 && v(state) != 6 ? 1 : 0;
    final owed = v(resv) + v(oValid) + part;
    if (used + owed > words && errors.length < 5) {
      errors.add('cycle $cycle: used $used + owed $owed above $words');
    }
  });
  Simulator.setMaxSimTime(1 << 40);
  const ring = 0x8000;
  var tail = 0;
  var ptr = 0x10000;
  var k = 0;
  final word3s = <int>[];
  final firsts = <int>[];
  final want = <List<int>>[];
  for (final f in lens) {
    firsts.add(tail);
    want.add([]);
    for (var i = 0; i < f.length; i++) {
      final a = (ptr & ~3) + offsets[k++ % offsets.length];
      ptr = a + f[i] + 64;
      for (var j = 0; j < f[i]; j++) {
        final v = rng.nextInt(256);
        mem.bytes[a + j] = v;
        want.last.add(v);
      }
      final d = ring + 16 * tail;
      mem
        ..putWord(d, a)
        ..putWord(d + 4, 0)
        ..putWord(
          d + 8,
          f[i] |
              (i == 0 ? 1 << 16 : 0) |
              (i == f.length - 1 ? 1 << 17 : 0) |
              (1 << 31),
        )
        ..putWord(d + 12, 0);
      tail++;
    }
  }
  s
    ..set('ring_base', ring)
    ..set('ring_size', 5)
    ..set('tx_en', 1)
    ..set('tail', tail);
  int out(String n) => s.dut.output(n).value.toInt();
  for (var i = 0; i < limit; i++) {
    if (out('head') == tail || out('ring_err') == 1) break;
    await s.cycles(1);
  }
  for (final f in firsts) {
    word3s.add(mem.word(ring + 16 * f + 12));
  }
  final ringErr = out('ring_err');
  final code = out('err_code');
  final hung = out('head') != tail && ringErr == 0;
  // Let the FIFO drain.
  if (!hung) await s.cycles(4 * 2048 * every);
  for (var i = 0; i < want.length; i++) {
    final ok = word3s.length > i && word3s[i] == 1;
    if (ok && (got.length <= i || !_eq(got[i], want[i]))) {
      final g = got.length > i ? got[i] : <int>[];
      var d = 0;
      while (d < g.length && d < want[i].length && g[d] == want[i][d]) {
        d++;
      }
      errors.add(
        'frame $i data differs: got ${g.length} bytes, want '
        '${want[i].length}, first difference at $d',
      );
    }
  }
  if (fill && minFree > 0) errors.add('the FIFO never got full');
  await s.stop();
  return (got, word3s, code, errors, hung);
}

bool _eq(List<int> a, List<int> b) =>
    a.length == b.length &&
    [for (var i = 0; i < a.length; i++) i].every((i) => a[i] == b[i]);

/// [_realFifo] in its own isolate. ROHD keeps a listener for every wire of
/// the earlier tests, which makes this bench slow late in the file.
Future<(List<List<int>>, List<int>, int)> _realFifoIso(
  HarborEthernetConfig cfg,
  List<List<int>> lens,
  List<int> offsets, {
  int limit = 200000,
  int every = 2,
  bool fill = false,
  double stall = 0.1,
}) async {
  final (got, w3, code, errors, hung) = await Isolate.run(
    () => _realFifo(
      cfg,
      lens,
      offsets,
      limit: limit,
      every: every,
      fill: fill,
      stall: stall,
    ),
  );
  expect(errors, isEmpty);
  expect(hung, isFalse, reason: 'the DMA hangs');
  return (got, w3, code);
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

  group('errors', () {
    test('a buffer read error drops the frame and stops the ring', () async {
      final b = await _Bench.make(_cfg(), latency: 8, seed: 11);
      final good = b.frame(100, 1);
      final bad = b.frame(0, 0, lens: [120, 180]);
      final next = b.frame(60, 1);
      final ea = bad.bufs[1].$1 & ~3;
      b.mem.errRanges.add((ea, ea + 4));
      final starts = b.give([good, bad, next]);
      final w2 = b.word2(starts[1]);
      await b.idle();
      await b.s.cycles(20);
      expect(b.out('ring_err'), 1);
      expect(b.out('err_code'), HarborEthDmaTx.errRead);
      expect(b.out('head'), starts[1]);
      expect(b.word3(starts[1]), 1 | (HarborEthDmaTx.errRead << 1));
      expect(b.word2(starts[1]), w2 & 0x7fffffff);
      expect(b.word2(starts[1] + 1) >> 31, 1, reason: 'second not written');
      expect(b.word2(starts[2]) >> 31, 1, reason: 'next frame not started');
      expect(b.sink.frames, [good.data]);
      expect(b.sink.dropped, 1);
      expect(b.txErr, 1);
      expect(b.errors, isEmpty);

      // A ring reset puts head at 0 and clears the error.
      b.s.set('ring_reset', 1);
      await b.s.cycles(1);
      b.s.set('ring_reset', 0);
      await b.s.cycles(2);
      expect(b.out('head'), 0);
      expect(b.out('ring_err'), 0);
      b.tail = 0;
      b.s.set('tail', 0);
      final again = b.frame(77, 2);
      b.give([again]);
      await b.idle();
      expect(b.out('ring_err'), 0);
      expect(b.sink.frames.last, again.data);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('a descriptor read error stops the ring', () async {
      final b = await _Bench.make(_cfg(), latency: 0, seed: 12);
      final f = b.frame(40, 1);
      b.mem.errRanges.add((b.descAddr(0), b.descAddr(0) + 16));
      b.give([f]);
      await b.idle();
      expect(b.out('err_code'), HarborEthDmaTx.errRead);
      expect(b.out('head'), 0);
      expect(b.sink.words, 0);
      expect(b.mem.reads.every((r) => r.addr == b.descAddr(0)), isTrue);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('a buffer above the waist address width stops the ring', () async {
      final b = await _Bench.make(_cfg(), latency: 0, seed: 32);
      final f = b.frame(0, 0, lens: [40, 30]);
      b.give([f]);
      b.mem.putWord(b.descAddr(1) + 4, 1);
      final w2 = b.word2(0);
      await b.idle();
      expect(b.out('ring_err'), 1);
      expect(b.out('err_code'), HarborEthDmaTx.errRead);
      expect(b.word3(0), 1 | (HarborEthDmaTx.errRead << 1));
      expect(b.word2(0), w2 & 0x7fffffff);
      expect(b.out('head'), 0);
      expect(b.sink.words, 0);
      final descs = {b.descAddr(0), b.descAddr(1)};
      expect(b.mem.reads.every((r) => descs.contains(r.addr)), isTrue);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('no EOP before tail stops the ring before a buffer read', () async {
      final b = await _Bench.make(_cfg(), latency: 8, seed: 13);
      final f = b.frame(200, 3);
      for (var i = 0; i < 3; i++) {
        b.putDesc(i, f.bufs[i].$1, f.bufs[i].$2, sop: i == 0);
      }
      final w2 = b.word2(0);
      b.tail = 3;
      b.s.set('tail', 3);
      await b.idle();
      await b.s.cycles(10);
      expect(b.out('ring_err'), 1);
      expect(b.out('err_code'), HarborEthDmaTx.errNoEop);
      expect(b.word3(0), 1 | (HarborEthDmaTx.errNoEop << 1));
      expect(b.word2(0), w2 & 0x7fffffff);
      expect(b.out('head'), 0);
      expect(b.sink.words, 0);
      final descs = {for (var i = 0; i < 3; i++) b.descAddr(i)};
      expect(b.mem.reads.every((r) => descs.contains(r.addr)), isTrue);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('a frame over 1518 bytes stops the ring', () async {
      final b = await _Bench.make(_cfg(), latency: 20, seed: 14);
      final f = b.frame(HarborEthDmaTx.maxFrameBytes + 1, 2);
      b.give([f]);
      await b.idle();
      await b.s.cycles(10);
      expect(b.out('err_code'), HarborEthDmaTx.errOversize);
      expect(b.word3(0), 1 | (HarborEthDmaTx.errOversize << 1));
      expect(b.out('head'), 0);
      expect(b.sink.words, 0);
      expect(b.txErr, 1);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('a frame of 1518 bytes is sent', () async {
      final b = await _Bench.make(_cfg(), latency: 0, seed: 15);
      final f = b.frame(HarborEthDmaTx.maxFrameBytes, 2);
      b.give([f]);
      await b.idle();
      expect(b.out('ring_err'), 0);
      expect(b.sink.frames, [f.data]);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('OWN clear waits for a new tail', () async {
      final b = await _Bench.make(_cfg(), latency: 0, seed: 16);
      final f = b.frame(50, 1);
      b.putDesc(0, f.bufs[0].$1, 50, eop: true, own: false);
      b.tail = 1;
      b.s.set('tail', 1);
      await b.s.cycles(60);
      expect(b.out('busy'), 0);
      expect(b.out('head'), 0);
      expect(b.mem.writes, isEmpty);
      expect(b.mem.reads.length, 1);
      b.putDesc(0, f.bufs[0].$1, 50, eop: true);
      await b.s.cycles(60);
      expect(b.mem.reads.length, 1, reason: 'same tail, no new read');
      final g = b.frame(30, 1);
      b.give([g]);
      await b.idle();
      expect(b.sink.frames, [f.data, g.data]);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('tx clock lost gives err 4 and the ring goes on', () async {
      final b = await _Bench.make(_cfg(), latency: 8, seed: 17);
      b.s.set('tx_clk_lost', 1);
      final f = b.frame(90, 2, irq: true);
      b.give([f]);
      await b.idle();
      expect(b.word3(0), 1 | (HarborEthDmaTx.errClkLost << 1));
      expect(b.word3(1), 1 | (HarborEthDmaTx.errClkLost << 1));
      expect(b.out('ring_err'), 0);
      expect(b.out('err_code'), HarborEthDmaTx.errClkLost);
      expect(b.txErr, 1);
      expect(b.txDone, 1);
      b.s.set('tx_clk_lost', 0);
      final g = b.frame(33, 1);
      b.give([g]);
      await b.idle();
      expect(b.word3(2), 1);
      expect(b.sink.frames.last, g.data);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('tx_en low pauses between frames and keeps head', () async {
      final b = await _Bench.make(_cfg(), latency: 8, seed: 19);
      final a = b.frame(70, 2);
      b.give([a]);
      await b.idle();
      expect(b.out('head'), 2);
      b.s.set('tx_en', 0);
      await b.s.cycles(4);
      expect(b.out('head'), 2);
      final c = b.frame(55, 1);
      b.give([c]);
      await b.s.cycles(150);
      expect(b.out('head'), 2, reason: 'no frame while paused');
      expect(b.out('busy'), 0);
      expect(b.sink.frames, [a.data]);
      b.s.set('tx_en', 1);
      await b.idle();
      expect(b.out('head'), 3);
      expect(b.sink.frames, [a.data, c.data]);
      expect(b.word3(2), 1);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    for (final fault in [HarborEthDmaTx.errClkLost, HarborEthDmaTx.errRead]) {
      test('word 3 lands before OWN is cleared, err $fault', () async {
        final b = await _Bench.make(_cfg(), latency: 8, seed: 20 + fault);
        final f = b.frame(90, 1);
        b.give([f]);
        // The last lap left done and ok in word 3.
        b.mem.putWord(b.descAddr(0) + 12, 1);
        if (fault == HarborEthDmaTx.errClkLost) {
          b.s.set('tx_clk_lost', 1);
        } else {
          final ea = f.bufs[0].$1 & ~3;
          b.mem.errRanges.add((ea, ea + 4));
        }
        final want = 1 | (fault << 1);
        var seen = 0;
        b.s.onRise(() {
          if (b.word2(0) >> 31 == 0) {
            seen++;
            if (b.word3(0) != want) b.errors.add('OWN clear with old word 3');
          }
        });
        await b.idle();
        await b.s.cycles(10);
        expect(seen, greaterThan(0));
        expect(b.word3(0), want);
        expect(b.errors, isEmpty);
        await b.s.stop();
      });
    }

    test('a write-back error stops the ring', () async {
      final b = await _Bench.make(_cfg(), latency: 8, seed: 30);
      final f = b.frame(60, 1);
      final next = b.frame(40, 1);
      b.mem.writeErrRanges.add((b.descAddr(0) + 12, b.descAddr(0) + 16));
      b.give([f, next]);
      await b.idle();
      await b.s.cycles(40);
      expect(b.out('busy'), 0);
      expect(b.out('ring_err'), 1);
      expect(b.out('err_code'), HarborEthDmaTx.errRead);
      expect(b.out('head'), 0);
      expect(b.txErr, 1);
      expect(b.txDone, 0);
      expect(b.sink.frames, [f.data]);
      expect(b.word2(0) >> 31, 1, reason: 'OWN stays set');
      expect(b.mem.writes.length, 1, reason: 'no write after the error');
      expect(b.word2(1) >> 31, 1, reason: 'next frame not started');
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('a length that grows between the passes aborts the frame', () async {
      final b = await _Bench.make(_cfg(), latency: 8, seed: 31);
      final f = b.frame(0, 0, lens: [100, 100]);
      b.give([f]);
      var grown = false;
      b.mem.onRead = (r) {
        if (!grown && r.addr >= 0x10000) {
          grown = true;
          b.mem.putWord(b.descAddr(1) + 8, 300 | (1 << 17) | (1 << 31));
        }
      };
      await b.idle();
      await b.s.cycles(20);
      expect(grown, isTrue);
      expect(b.out('ring_err'), 1);
      expect(b.out('err_code'), HarborEthDmaTx.errOversize);
      expect(b.word3(0), 1 | (HarborEthDmaTx.errOversize << 1));
      expect(b.out('head'), 0);
      expect(b.sink.frames, isEmpty);
      expect(b.sink.dropped, 1);
      expect(b.sink.words, lessThanOrEqualTo(200 ~/ 4 + 1));
      expect(b.txErr, 1);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('ring_reset in a frame waits for the frame to end', () async {
      final b = await _Bench.make(_cfg(), latency: 20, seed: 40);
      final p = b.frame(30, 1);
      b.give([p]);
      await b.idle();
      expect(b.out('head'), 1);
      final a = b.frame(0, 0, lens: [150, 150]);
      b.give([a]);
      final q = b.frame(44, 1);
      b.putDesc(0, q.bufs[0].$1, 44, sop: true, eop: true);
      await b.until(() => b.mem.reads.length > 4 && b.out('busy') == 1);
      b.s.set('ring_reset', 1);
      await b.s.cycles(1);
      b.s.set('ring_reset', 0);
      await b.idle();
      await b.s.cycles(150);
      expect(b.word3(1), 1);
      expect(b.word3(2), 1);
      expect(b.sink.frames, [p.data, a.data, q.data]);
      expect(b.word3(0), 1, reason: 'new ring frame sent after the reset');
      expect(b.out('head'), 1);
      expect(b.out('ring_err'), 0);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('ring_reset with a new tail does not start the old frame', () async {
      final b = await _Bench.make(_cfg(), latency: 8, seed: 41);
      final p = b.frame(30, 1);
      b.give([p]);
      await b.idle();
      final a = b.frame(0, 0, lens: [40, 40]);
      b.give([a]);
      b.s.set('ring_reset', 1);
      await b.s.cycles(1);
      b.s.set('ring_reset', 0);
      await b.s.cycles(150);
      expect(b.out('head'), 0);
      expect(b.out('ring_err'), 0);
      expect(b.word2(1) >> 31, 1);
      expect(b.word2(2) >> 31, 1);
      expect(b.sink.frames, [p.data]);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });

    test('IRQ only when asked', () async {
      final b = await _Bench.make(_cfg(), latency: 0, seed: 18);
      b.give([b.frame(64, 1), b.frame(64, 2)]);
      await b.idle();
      expect(b.txDone, 0);
      b.give([b.frame(64, 1, irq: true)]);
      await b.idle();
      await b.s.cycles(2);
      expect(b.txDone, 1);

      // A zero-length buffer at an unaligned address reads nothing.
      final z = b.frame(0, 0, lens: [20, 0, 9]);
      z.bufs[1] = (0x30001, 0);
      b.mem.errRanges.add((0x30000, 0x30004));
      b.give([z]);
      await b.idle();
      expect(b.out('ring_err'), 0);
      expect(b.sink.frames.last, z.data);
      expect(b.mem.reads.every((r) => r.addr != 0x30000), isTrue);
      expect(b.errors, isEmpty);
      await b.s.stop();
    });
  });

  group('real fifo', () {
    for (final (tag, cfg) in [
      ('basic', HarborEthernetConfig.basic(phy: HarborEthPhy.mii)),
      (
        'burst 16, 4 in flight',
        HarborEthernetConfig(
          phy: HarborEthPhy.mii,
          outstanding: 4,
          burstBeats: 16,
        ),
      ),
    ]) {
      for (var off = 0; off < 4; off++) {
        test('$tag: 1518 bytes at offset $off, 1 to 3 buffers', () async {
          const max = HarborEthDmaTx.maxFrameBytes;
          final lens = [
            [max],
            [700, max - 700],
            [1, max - 2, 1],
            [max],
          ];
          final (got, w3, _) = await _realFifoIso(cfg, lens, [off, 3 - off, 1]);
          expect(got, hasLength(lens.length));
          for (final g in got) {
            expect(g, hasLength(max));
          }
          expect(w3, everyElement(1), reason: 'done, no error');
        });
      }
      test('$tag: the FIFO fills, w_free and the reservation hold', () async {
        const max = HarborEthDmaTx.maxFrameBytes;
        final lens = [
          for (var i = 0; i < 6; i++) [max - 3 * i],
        ];
        final (got, w3, _) = await _realFifoIso(
          cfg,
          lens,
          [0, 1, 2, 3],
          every: 6,
          fill: true,
          stall: 0,
          limit: 400000,
        );
        expect(got, hasLength(lens.length));
        expect(w3, everyElement(1), reason: 'done, no error');
      });
      test('$tag: a frame of the FIFO size at offset 1 gets err 3', () async {
        final (got, w3, code) = await _realFifoIso(
          cfg,
          [
            [cfg.txFifoBytes],
          ],
          [1],
          limit: 40000,
        );
        expect(got, isEmpty);
        expect(w3, [1 | (HarborEthDmaTx.errOversize << 1)]);
        expect(code, HarborEthDmaTx.errOversize);
      });
      test('$tag: a 1519-byte frame gets err 3', () async {
        final (got, w3, code) = await _realFifoIso(
          cfg,
          [
            [1518],
            [1000, 519],
          ],
          [1],
        );
        expect(got, hasLength(1));
        expect(w3, [1, 1 | (HarborEthDmaTx.errOversize << 1)]);
        expect(code, HarborEthDmaTx.errOversize);
      });
    }
  });

  group('fabric', () {
    for (final kind in HarborFabricKind.values) {
      test('${kind.name}: frames from SRAM reach the FIFO', () async {
        await _fabric(kind);
      });
    }
  });
}
