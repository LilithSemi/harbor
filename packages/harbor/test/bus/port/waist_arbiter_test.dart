import 'dart:collection';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import 'memory_harness.dart' show exposeWaist;
import 'port_harness.dart' show Sim;

HarborMemoryWaistConfig _cfg(int id, {int outstanding = 4}) =>
    HarborMemoryWaistConfig(
      addressWidth: 32,
      dataWidth: 32,
      idWidth: id,
      outstanding: outstanding,
    );

/// The arbiter with its sources on `s<i>_*`, its output on `mem_*` and its
/// flush inputs on `flush_<i>`.
class _Top extends BridgeModule {
  _Top(List<int> srcIds, int outId, {bool flush = true, int outstanding = 4})
    : super('WaistArbTop', name: 'top') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final src = [for (final w in srcIds) HarborMemoryWaist(_cfg(w))];
    final out = HarborMemoryWaist(_cfg(outId, outstanding: outstanding));
    final fl = flush
        ? [
            for (var i = 0; i < srcIds.length; i++)
              (
                createPort('flush_$i', PortDirection.input),
                input('flush_$i'),
              ).$2,
          ]
        : null;
    final arb = HarborWaistArbiter(
      input('clk'),
      input('reset'),
      sources: src,
      out: out,
      flush: fl,
    );
    for (var i = 0; i < srcIds.length; i++) {
      exposeWaist(this, src[i], 's$i', PairRole.consumer);
      addOutput('idle_$i') <= arb.idleOf(i);
    }
    exposeWaist(this, out, 'mem', PairRole.provider);
    addOutput('idle') <= arb.idle;
  }
}

int _rom(int addr) => (addr * 0x9e3779b1 ^ 0x5a5a5a5a) & 0xffffffff;

class _Req {
  final int src;
  final int k;
  final int id;
  final bool write;
  final int addr;
  final int len;
  final bool excl;
  final List<int> data;
  final List<int> strb;
  int beat = 0;
  _Req(
    this.src,
    this.k,
    this.id,
    this.write,
    this.addr,
    this.len,
    this.excl,
    this.data,
    this.strb,
  );
}

/// A DMA-like source. It sends requests in order and write data after its
/// request, and holds response READY only while a response is owed. In
/// [garbage] mode it drives random values on every input of the arbiter,
/// like a source in reset, and must see no response.
class _Src {
  final Sim s;
  final int i;
  final int idBits;
  final Random rng;
  final List<String> errors;
  final Map<int, int> expectMem;
  double reqRate = 0.6;
  double wRate = 0.7;
  double respRate = 0.6;

  /// Stop write data after this many beats of a write.
  int? stallW;
  bool garbage = false;
  final Queue<_Req> todo = Queue();
  final Queue<_Req> wq = Queue();
  final Map<int, Queue<_Req>> reads = {};
  final Map<int, Queue<_Req>> writes = {};
  int done = 0;
  int _k = 0;
  bool _reqUp = false;
  bool _wUp = false;

  _Src(this.s, this.i, this.idBits, this.rng, this.errors, this.expectMem) {
    String p(String n) => 's${i}_$n';
    s.onRise(() {
      if (garbage) {
        if (s.pre(p('RDATA_VALID')) == 1 || s.pre(p('WRESP_VALID')) == 1) {
          errors.add('source $i: response while flushed');
        }
        if (s.pre(p('REQ_READY')) == 1) {
          errors.add('source $i: REQ_READY while flushed');
        }
        if (s.pre(p('WDATA_READY')) == 1) {
          errors.add('source $i: WDATA_READY while flushed');
        }
        return;
      }
      if (_reqUp && s.pre(p('REQ_READY')) == 1) {
        final r = todo.removeFirst();
        _reqUp = false;
        if (r.write) {
          wq.add(r);
          writes.putIfAbsent(r.id, Queue.new).add(r);
        } else {
          reads.putIfAbsent(r.id, Queue.new).add(r);
        }
      }
      if (_wUp && s.pre(p('WDATA_READY')) == 1) {
        final r = wq.first;
        _wUp = false;
        if (++r.beat > r.len) {
          wq.removeFirst();
          r.beat = 0;
        }
      }
      if (s.pre(p('RDATA_VALID')) == 1 && s.pre(p('RDATA_READY')) == 1) {
        final id = s.pre(p('RDATA_ID'));
        final q = reads[id];
        if (q == null || q.isEmpty) {
          errors.add('source $i: read data with no read on ID $id');
        } else {
          final r = q.first;
          final d = s.pre(p('RDATA_DATA'));
          final last = s.pre(p('RDATA_LAST')) == 1;
          final ex = s.pre(p('RDATA_EXOKAY')) == 1;
          if (d != _rom(r.addr + 4 * r.beat) ||
              last != (r.beat == r.len) ||
              ex != r.excl) {
            errors.add('source $i: read ${r.k} beat ${r.beat} wrong');
          }
          if (++r.beat > r.len) {
            q.removeFirst();
            done++;
          }
        }
      }
      if (s.pre(p('WRESP_VALID')) == 1 && s.pre(p('WRESP_READY')) == 1) {
        final id = s.pre(p('WRESP_ID'));
        final q = writes[id];
        if (q == null || q.isEmpty) {
          errors.add('source $i: write response with no write on ID $id');
        } else {
          final r = q.removeFirst();
          if ((s.pre(p('WRESP_EXOKAY')) == 1) != r.excl) {
            errors.add('source $i: write ${r.k} EXOKAY wrong');
          }
          done++;
        }
      }
    });
    s.onFall(() {
      if (garbage) {
        for (final n in [
          'REQ_VALID',
          'REQ_WRITE',
          'REQ_EXCLUSIVE',
          'WDATA_VALID',
          'WDATA_LAST',
          'RDATA_READY',
          'WRESP_READY',
        ]) {
          s.set(p(n), rng.nextInt(2));
        }
        s
          ..set(p('REQ_ID'), rng.nextInt(1 << idBits))
          ..set(p('REQ_ADDR'), rng.nextInt(1 << 32))
          ..set(p('REQ_LEN'), rng.nextInt(256))
          ..set(p('WDATA_DATA'), rng.nextInt(1 << 32))
          ..set(p('WDATA_STRB'), rng.nextInt(16));
        return;
      }
      if (!_reqUp && todo.isNotEmpty && rng.nextDouble() < reqRate) {
        _reqUp = true;
      }
      final r = _reqUp ? todo.first : null;
      s
        ..set(p('REQ_VALID'), _reqUp ? 1 : 0)
        ..set(p('REQ_ID'), r?.id ?? 0)
        ..set(p('REQ_WRITE'), r?.write ?? false ? 1 : 0)
        ..set(p('REQ_ADDR'), r?.addr ?? 0)
        ..set(p('REQ_LEN'), r?.len ?? 0)
        ..set(p('REQ_SIZE'), 2)
        ..set(p('REQ_BURST'), 1)
        ..set(p('REQ_EXCLUSIVE'), r?.excl ?? false ? 1 : 0);
      final stalled =
          stallW != null && wq.isNotEmpty && wq.first.beat >= stallW!;
      if (!_wUp && wq.isNotEmpty && !stalled && rng.nextDouble() < wRate) {
        _wUp = true;
      }
      final w = _wUp ? wq.first : null;
      s
        ..set(p('WDATA_VALID'), _wUp ? 1 : 0)
        ..set(p('WDATA_DATA'), w?.data[w.beat] ?? 0)
        ..set(p('WDATA_STRB'), w?.strb[w.beat] ?? 0)
        ..set(p('WDATA_LAST'), w != null && w.beat == w.len ? 1 : 0)
        ..set(
          p('RDATA_READY'),
          reads.values.any((q) => q.isNotEmpty) && rng.nextDouble() < respRate
              ? 1
              : 0,
        )
        ..set(
          p('WRESP_READY'),
          writes.values.any((q) => q.isNotEmpty) && rng.nextDouble() < respRate
              ? 1
              : 0,
        );
    });
  }

  int get base => 0x100000 * (i + 1);

  /// Adds a read of [len] + 1 beats from the read-only area.
  _Req read({int? len, int? id, bool? excl}) {
    final k = _k++;
    final r = _Req(
      i,
      k,
      id ?? rng.nextInt(1 << idBits),
      false,
      base + 0x80000 + 0x400 * k,
      len ?? rng.nextInt(4),
      excl ?? rng.nextInt(4) == 0,
      const [],
      const [],
    );
    todo.add(r);
    return r;
  }

  /// Adds a write of [len] + 1 beats. With [track], the expected memory
  /// gets its data.
  _Req write({int? len, int? id, bool? excl, bool track = true}) {
    final k = _k++;
    final l = len ?? rng.nextInt(4);
    final addr = base + 0x400 * k;
    final data = [for (var b = 0; b <= l; b++) (i << 28) | (k << 8) | b];
    final strb = [for (var b = 0; b <= l; b++) 1 + rng.nextInt(15)];
    final r = _Req(
      i,
      k,
      id ?? rng.nextInt(1 << idBits),
      true,
      addr,
      l,
      excl ?? rng.nextInt(4) == 0,
      data,
      strb,
    );
    if (track) {
      for (var b = 0; b <= l; b++) {
        expectMem[addr + 4 * b] = _merge(_rom(addr + 4 * b), data[b], strb[b]);
      }
    }
    todo.add(r);
    return r;
  }

  bool get busy =>
      todo.isNotEmpty ||
      wq.isNotEmpty ||
      reads.values.any((q) => q.isNotEmpty) ||
      writes.values.any((q) => q.isNotEmpty);

  void enterGarbage() {
    garbage = true;
    todo.clear();
    wq.clear();
    reads.clear();
    writes.clear();
    _reqUp = false;
    _wUp = false;
  }
}

int _merge(int old, int data, int strb) {
  var v = old;
  for (var b = 0; b < 4; b++) {
    if (strb >> b & 1 == 1) {
      final m = 0xff << (8 * b);
      v = (v & ~m) | (data & m);
    }
  }
  return v & 0xffffffff;
}

class _Pending {
  final int id;
  final bool excl;
  final int addr;
  final int len;
  final int due;
  final int index;
  _Pending(this.id, this.excl, this.addr, this.len, this.due, this.index);
}

/// A memory with random READY on every channel, random latency and
/// responses in random order across IDs. It checks the READY rules of the
/// waist and logs every request and write beat.
class _Mem {
  final Sim s;
  final Random rng;
  final List<String> errors;
  final int sw;
  final Map<int, int> mem = {};
  double reqReady = 0.5;
  double wReady = 0.5;
  double respRate = 0.7;
  int maxLatency = 6;

  /// No response goes out while this is set.
  bool hold = false;
  int cycle = 0;

  /// Accepted requests: (cycle, source index, write).
  final List<(int, int, bool)> reqLog = [];

  /// Responses done: (cycle, source index).
  final List<(int, int)> doneLog = [];

  /// Write beats: (address, data, strobe, last).
  final List<(int, int, int, bool)> beatLog = [];
  final List<_Pending> reads = [];
  final Queue<_Pending> writesWaitData = Queue();
  final List<_Pending> wresps = [];
  final Queue<(int, int, int)> _early = Queue();
  int _wBeat = 0;
  _Pending? _r;
  int _rBeat = 0;
  _Pending? _b;

  _Mem(this.s, this.rng, this.errors, this.sw) {
    int p(String n) => s.pre('mem_$n');
    s.onRise(() {
      cycle++;
      if (p('RDATA_READY') == 1 && reads.isEmpty && _r == null) {
        errors.add('cycle $cycle: RDATA_READY with no read owed');
      }
      if (p('WRESP_READY') == 1 &&
          wresps.isEmpty &&
          writesWaitData.isEmpty &&
          _b == null) {
        errors.add('cycle $cycle: WRESP_READY with no write owed');
      }
      if (p('REQ_VALID') == 1 && p('REQ_READY') == 1) {
        final id = p('REQ_ID');
        final x = _Pending(
          id,
          p('REQ_EXCLUSIVE') == 1,
          p('REQ_ADDR'),
          p('REQ_LEN'),
          cycle + rng.nextInt(maxLatency),
          id >> sw,
        );
        final w = p('REQ_WRITE') == 1;
        reqLog.add((cycle, x.index, w));
        if (w) {
          writesWaitData.add(x);
        } else {
          reads.add(x);
        }
      }
      if (p('WDATA_VALID') == 1 && p('WDATA_READY') == 1) {
        _early.add((p('WDATA_DATA'), p('WDATA_STRB'), p('WDATA_LAST')));
      }
      while (_early.isNotEmpty && writesWaitData.isNotEmpty) {
        final (d, st, l) = _early.removeFirst();
        final x = writesWaitData.first;
        final a = x.addr + 4 * _wBeat;
        beatLog.add((a, d, st, l == 1));
        mem[a] = _merge(mem[a] ?? _rom(a), d, st);
        if ((l == 1) != (_wBeat == x.len)) {
          errors.add('cycle $cycle: write LAST wrong at beat $_wBeat');
        }
        if (++_wBeat > x.len) {
          _wBeat = 0;
          writesWaitData.removeFirst();
          wresps.add(x);
        }
      }
      if (_r != null && p('RDATA_READY') == 1) {
        if (++_rBeat > _r!.len) {
          doneLog.add((cycle, _r!.index));
          _r = null;
          _rBeat = 0;
        }
      }
      if (_b != null && p('WRESP_READY') == 1) {
        doneLog.add((cycle, _b!.index));
        _b = null;
      }
    });
    s.onFall(() {
      // The first entry of each ID may go, in any order across IDs.
      _Pending? choose(List<_Pending> l) {
        final seen = <int>{};
        final ok = <_Pending>[];
        for (final x in l) {
          if (seen.add(x.id) && x.due <= cycle) ok.add(x);
        }
        if (ok.isEmpty || hold || rng.nextDouble() > respRate) return null;
        final x = ok[rng.nextInt(ok.length)];
        l.remove(x);
        return x;
      }

      _r ??= choose(reads);
      _b ??= choose(wresps);
      final r = _r;
      final b = _b;
      s
        ..set('mem_REQ_READY', rng.nextDouble() < reqReady ? 1 : 0)
        ..set('mem_WDATA_READY', rng.nextDouble() < wReady ? 1 : 0)
        ..set('mem_RDATA_VALID', r == null ? 0 : 1)
        ..set('mem_RDATA_ID', r?.id ?? 0)
        ..set('mem_RDATA_DATA', r == null ? 0 : _rom(r.addr + 4 * _rBeat))
        ..set('mem_RDATA_ERR', 0)
        ..set('mem_RDATA_EXOKAY', r?.excl ?? false ? 1 : 0)
        ..set('mem_RDATA_LAST', r != null && _rBeat == r.len ? 1 : 0)
        ..set('mem_WRESP_VALID', b == null ? 0 : 1)
        ..set('mem_WRESP_ID', b?.id ?? 0)
        ..set('mem_WRESP_ERR', 0)
        ..set('mem_WRESP_EXOKAY', b?.excl ?? false ? 1 : 0);
    });
  }

  bool get busy =>
      reads.isNotEmpty ||
      wresps.isNotEmpty ||
      writesWaitData.isNotEmpty ||
      _r != null ||
      _b != null;
}

class _Bench {
  final Sim s;
  final List<_Src> src;
  final _Mem mem;
  final List<String> errors;
  final Map<int, int> expectMem;
  _Bench(this.s, this.src, this.mem, this.errors, this.expectMem);

  static Future<_Bench> start(
    List<int> srcIds,
    int outId, {
    int seed = 1,
    bool flush = true,
    int outstanding = 4,
  }) async {
    final s = Sim(_Top(srcIds, outId, flush: flush, outstanding: outstanding));
    final rng = Random(seed);
    final errors = <String>[];
    final expectMem = <int, int>{};
    final sw = srcIds.reduce(max);
    final src = [
      for (var i = 0; i < srcIds.length; i++)
        _Src(s, i, srcIds[i], rng, errors, expectMem),
    ];
    final mem = _Mem(s, rng, errors, sw);
    await s.start();
    Simulator.setMaxSimTime(1 << 40);
    final b = _Bench(s, src, mem, errors, expectMem);
    addTearDown(() async {
      if (!b._stopped) await s.stop();
    });
    return b;
  }

  int out(String n) => s.dut.output(n).value.toInt();

  void flush(int i, bool on) => s.set('flush_$i', on ? 1 : 0);

  /// Source [i] drives its waist again one cycle before its flush ends.
  Future<void> unflush(int i) async {
    src[i].garbage = false;
    await s.cycles(1);
    flush(i, false);
  }

  /// Runs until [done] or [limit] cycles. Fails on a time out.
  Future<void> until(bool Function() done, {int limit = 20000}) async {
    for (var c = 0; c < limit; c++) {
      if (done() || errors.length > 5) return;
      await s.cycles(1);
    }
    fail(
      'timed out: ${[for (final x in src) '${x.i} todo ${x.todo.length} '
            'wq ${x.wq.length} done ${x.done} '
            'r ${x.reads.values.fold(0, (a, q) => a + q.length)} '
            'w ${x.writes.values.fold(0, (a, q) => a + q.length)}']}, mem '
      'r ${mem.reads.length} b ${mem.wresps.length} '
      'wd ${mem.writesWaitData.length} cur ${mem._r != null} ${mem._b != null} '
      'errors $errors',
    );
  }

  Future<void> settle() async {
    await until(() => !mem.busy && src.every((x) => !x.busy));
    await s.cycles(20);
  }

  bool _stopped = false;

  Future<void> finish() async {
    _stopped = true;
    await s.stop();
    expect(errors, isEmpty);
  }
}

Future<void> _random(List<int> srcIds, int outId, int seed) async {
  final b = await _Bench.start(srcIds, outId, seed: seed);
  const n = 60;
  for (final x in b.src) {
    for (var k = 0; k < n; k++) {
      if (x.rng.nextBool()) {
        x.write();
      } else {
        x.read();
      }
    }
  }
  await b.until(() => b.src.every((x) => x.done == n));
  await b.settle();
  expect(b.out('idle'), 1);
  for (var i = 0; i < srcIds.length; i++) {
    expect(b.out('idle_$i'), 1);
  }
  await b.finish();
  for (final e in b.expectMem.entries) {
    expect(b.mem.mem[e.key], e.value, reason: 'word at ${e.key}');
  }
}

void main() {
  tearDown(() async => Simulator.reset());

  group('parameters', () {
    HarborMemoryWaist w(int id, {int d = 32, int a = 32}) => HarborMemoryWaist(
      HarborMemoryWaistConfig(addressWidth: a, dataWidth: d, idWidth: id),
    );
    final clk = Logic();
    final reset = Logic();

    test('needs two sources', () {
      expect(
        () => HarborWaistArbiter(clk, reset, sources: [w(1)], out: w(2)),
        throwsArgumentError,
      );
    });
    test('data and address width must match', () {
      expect(
        () => HarborWaistArbiter(
          clk,
          reset,
          sources: [w(1), w(1, d: 64)],
          out: w(2),
        ),
        throwsArgumentError,
      );
      expect(
        () => HarborWaistArbiter(
          clk,
          reset,
          sources: [w(1), w(1, a: 16)],
          out: w(2),
        ),
        throwsArgumentError,
      );
    });
    test('out ID must hold the index and the source ID', () {
      expect(
        () => HarborWaistArbiter(
          clk,
          reset,
          sources: [w(2), w(1), w(1)],
          out: w(3),
        ),
        throwsArgumentError,
      );
    });
    test('flush has one signal for each source', () {
      expect(
        () => HarborWaistArbiter(
          clk,
          reset,
          sources: [w(1), w(1)],
          out: w(2),
          flush: [Logic()],
        ),
        throwsArgumentError,
      );
    });
    test('definition name follows the parameters', () {
      final a = HarborWaistArbiter.definitionNameFor([w(1), w(2)], w(3), true);
      final b = HarborWaistArbiter.definitionNameFor([w(2), w(1)], w(3), true);
      final c = HarborWaistArbiter.definitionNameFor([w(1), w(2)], w(3), false);
      expect({a, b, c}, hasLength(3));
    });
  });

  for (final seed in [1, 2]) {
    test('two sources, random traffic and order, seed $seed', () async {
      await _random([2, 1], 3, seed);
    });
    test('three sources, random traffic and order, seed $seed', () async {
      await _random([1, 2, 1], 5, seed);
    });
  }

  test('two sources without flush logic', () async {
    final b = await _Bench.start([1, 1], 2, flush: false);
    for (final x in b.src) {
      for (var k = 0; k < 30; k++) {
        if (x.rng.nextBool()) {
          x.write();
        } else {
          x.read();
        }
      }
    }
    await b.until(() => b.src.every((x) => x.done == 30));
    await b.settle();
    expect(b.out('idle'), 1);
    await b.finish();
  });

  test('round robin among three waiting sources', () async {
    final b = await _Bench.start([1, 1, 1], 3, outstanding: 8);
    b.mem
      ..reqReady = 1
      ..respRate = 1
      ..maxLatency = 1;
    for (final x in b.src) {
      x
        ..reqRate = 1
        ..respRate = 1;
      for (var k = 0; k < 40; k++) {
        x.read(len: 0, excl: false);
      }
    }
    await b.until(() => b.src.every((x) => x.done == 40));
    await b.finish();
    final idx = [for (final r in b.mem.reqLog) r.$2];
    for (var j = 3; j + 1 < 100; j++) {
      expect(idx[j + 1], (idx[j] + 1) % 3, reason: 'grant $j');
    }
  });

  test('exclusive requests pass EXOKAY back', () async {
    final b = await _Bench.start([1, 1], 2);
    for (final x in b.src) {
      for (var k = 0; k < 10; k++) {
        x
          ..read(excl: k.isEven)
          ..write(excl: k.isOdd);
      }
    }
    await b.until(() => b.src.every((x) => x.done == 20));
    await b.finish();
  });

  test('flush in a read burst drops its data, others go on', () async {
    final b = await _Bench.start([1, 1], 2);
    final s0 = b.src[0];
    final s1 = b.src[1];
    s0.respRate = 1;
    b.mem.respRate = 0.3;
    final r = s0.read(len: 15, excl: false);
    for (var k = 0; k < 8; k++) {
      s1
        ..read()
        ..write();
    }
    await b.until(() => r.beat >= 2);
    b.flush(0, true);
    s0.enterGarbage();
    await b.until(() => s1.done == 16);
    await b.unflush(0);
    s0.read(len: 3);
    s0.write(len: 2);
    await b.until(() => s0.done == 2);
    await b.settle();
    expect(b.out('idle'), 1);
    await b.finish();
  });

  test('flush with write data owed sends zero strobe beats', () async {
    final b = await _Bench.start([1, 1], 2);
    final s0 = b.src[0];
    final s1 = b.src[1];
    s0.stallW = 3;
    final w = s0.write(len: 9, excl: false, track: false);
    await b.until(() => w.beat == 3);
    await b.s.cycles(5);
    b.flush(0, true);
    s0.enterGarbage();
    for (var k = 0; k < 6; k++) {
      s1
        ..write()
        ..read();
    }
    await b.until(() => s1.done == 12);
    s0.stallW = null;
    await b.unflush(0);
    await b.settle();
    final beats = [
      for (final x in b.mem.beatLog)
        if (x.$1 >= w.addr && x.$1 < w.addr + 0x40) x,
    ];
    expect(beats, hasLength(10));
    for (var k = 0; k < 10; k++) {
      final (a, d, st, last) = beats[k];
      expect(a, w.addr + 4 * k);
      expect(last, k == 9);
      if (k < 3) {
        expect(d, w.data[k]);
        expect(st, w.strb[k]);
      } else {
        expect(st, 0, reason: 'beat $k');
      }
    }
    for (var k = 0; k < 10; k++) {
      final a = w.addr + 4 * k;
      final want = k < 3 ? _merge(_rom(a), w.data[k], w.strb[k]) : _rom(a);
      expect(b.mem.mem[a] ?? _rom(a), want, reason: 'word $k');
    }
    for (final e in b.expectMem.entries) {
      expect(b.mem.mem[e.key], e.value);
    }
    expect(b.out('idle'), 1);
    await b.finish();
  });

  test('responses due after flush are dropped before a new grant', () async {
    final b = await _Bench.start([1, 1], 2, outstanding: 8);
    final s0 = b.src[0];
    final s1 = b.src[1];
    b.mem.reqReady = 1;
    for (var k = 0; k < 3; k++) {
      s0
        ..read(len: 2)
        ..write(len: 1, track: false);
    }
    s0.reqRate = 1;
    s0.wRate = 1;
    b.mem.hold = true;
    await b.until(() => b.mem.reqLog.where((x) => x.$2 == 0).length == 6);
    await b.s.cycles(3);
    b.flush(0, true);
    s0.enterGarbage();
    await b.s.cycles(2);
    final flushCycle = b.mem.cycle;
    await b.unflush(0);
    final old = b.mem.reqLog.where((x) => x.$2 == 0).length;
    s0.read(len: 1);
    s1.read(len: 1);
    await b.s.cycles(40);
    expect(b.mem.reqLog.where((x) => x.$2 == 0).length, old);
    expect(b.out('idle_0'), 0);
    expect(b.out('idle_1'), 0);
    b.mem.hold = false;
    await b.until(() => s0.done == 1 && s1.done == 1);
    await b.settle();
    final lastOld = b.mem.doneLog
        .where((x) => x.$2 == 0)
        .take(old)
        .map((x) => x.$1)
        .reduce(max);
    final firstNew = b.mem.reqLog.where((x) => x.$2 == 0).skip(old).first.$1;
    expect(firstNew, greaterThan(lastOld));
    expect(firstNew, greaterThan(flushCycle));
    expect(b.out('idle'), 1);
    expect(b.out('idle_0'), 1);
    await b.finish();
  });

  test('idle follows each source', () async {
    final b = await _Bench.start([1, 1], 2);
    await b.s.cycles(2);
    expect(b.out('idle'), 1);
    expect(b.out('idle_0'), 1);
    expect(b.out('idle_1'), 1);
    b.mem.hold = true;
    b.src[1].read(len: 0);
    await b.until(() => b.mem.reqLog.isNotEmpty);
    await b.s.cycles(2);
    expect(b.out('idle'), 0);
    expect(b.out('idle_0'), 1);
    expect(b.out('idle_1'), 0);
    b.mem.hold = false;
    await b.settle();
    expect(b.out('idle'), 1);
    expect(b.out('idle_1'), 1);
    await b.finish();
  });
}
