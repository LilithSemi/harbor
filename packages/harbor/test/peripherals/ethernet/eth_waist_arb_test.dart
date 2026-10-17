import 'dart:collection';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:harbor/src/peripherals/ethernet/eth_waist_arb.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../../bus/port/memory_harness.dart' show exposeWaist;
import '../../bus/port/port_harness.dart' show Sim;

const _cfg = HarborMemoryWaistConfig(
  addressWidth: 32,
  dataWidth: 32,
  outstanding: 4,
);

/// The arbiter with its sources on `s0_*`, `s1_*` and its output on `mem_*`.
class _Top extends BridgeModule {
  _Top() : super('EthWaistArbTop', name: 'top') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final src = [HarborMemoryWaist(_cfg), HarborMemoryWaist(_cfg)];
    final out = HarborMemoryWaist(_cfg);
    final arb = HarborEthWaistArbiter(
      input('clk'),
      input('reset'),
      tx: src[0],
      rx: src[1],
      out: out,
    );
    for (var i = 0; i < 2; i++) {
      exposeWaist(this, src[i], 's$i', PairRole.consumer);
    }
    exposeWaist(this, out, 'mem', PairRole.provider);
    addOutput('idle') <= arb.idle;
  }
}

class _Req {
  final int src;
  final int index;
  final bool write;
  final int addr;
  final int len;
  int beat = 0;
  _Req(this.src, this.index, this.write, this.addr, this.len);

  int wdata(int b) => (src << 28) | (index << 8) | b;
  int rdata(int b) => (addr + 4 * b) ^ 0x5a5a5a5a;
}

/// One DMA-like source: requests in order, write data after its request,
/// response READY only while a response of that kind is owed.
class _Source {
  final Sim s;
  final int id;
  final Random rng;
  final List<String> errors;
  final Queue<_Req> todo = Queue();
  final Queue<_Req> wq = Queue();
  final Queue<_Req> reads = Queue();
  final Queue<_Req> writes = Queue();
  int done = 0;
  bool _reqUp = false;
  bool _wUp = false;

  _Source(this.s, this.id, this.rng, this.errors, int n) {
    for (var k = 0; k < n; k++) {
      todo.add(
        _Req(
          id,
          k,
          rng.nextBool(),
          0x1000 * (id + 1) * 64 + 0x40 * k,
          rng.nextInt(4),
        ),
      );
    }
    String p(String n) => 's${id}_$n';
    s.onRise(() {
      if (_reqUp && s.pre(p('REQ_READY')) == 1) {
        final r = todo.removeFirst();
        _reqUp = false;
        if (r.write) {
          wq.add(r);
          writes.add(r);
        } else {
          reads.add(r);
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
        if (reads.isEmpty) {
          errors.add('source $id: read data with no read');
        } else {
          final r = reads.first;
          final d = s.pre(p('RDATA_DATA'));
          final last = s.pre(p('RDATA_LAST')) == 1;
          if (d != r.rdata(r.beat) || last != (r.beat == r.len)) {
            errors.add('source $id: read ${r.index} beat ${r.beat} wrong');
          }
          if (++r.beat > r.len) {
            reads.removeFirst();
            done++;
          }
        }
      }
      if (s.pre(p('WRESP_VALID')) == 1 && s.pre(p('WRESP_READY')) == 1) {
        if (writes.isEmpty) {
          errors.add('source $id: write response with no write');
        } else {
          writes.removeFirst();
          done++;
        }
      }
    });
    s.onFall(() {
      if (!_reqUp && todo.isNotEmpty && rng.nextDouble() < 0.6) _reqUp = true;
      final r = _reqUp ? todo.first : null;
      s
        ..set(p('REQ_VALID'), _reqUp ? 1 : 0)
        ..set(p('REQ_ID'), 0)
        ..set(p('REQ_WRITE'), r?.write ?? false ? 1 : 0)
        ..set(p('REQ_ADDR'), r?.addr ?? 0)
        ..set(p('REQ_LEN'), r?.len ?? 0)
        ..set(p('REQ_SIZE'), 2)
        ..set(p('REQ_BURST'), 1)
        ..set(p('REQ_EXCLUSIVE'), 0);
      if (!_wUp && wq.isNotEmpty && rng.nextDouble() < 0.7) _wUp = true;
      final w = _wUp ? wq.first : null;
      s
        ..set(p('WDATA_VALID'), _wUp ? 1 : 0)
        ..set(p('WDATA_DATA'), w?.wdata(w.beat) ?? 0)
        ..set(p('WDATA_STRB'), 0xf)
        ..set(p('WDATA_LAST'), w != null && w.beat == w.len ? 1 : 0)
        ..set(
          p('RDATA_READY'),
          reads.isNotEmpty && rng.nextDouble() < 0.6 ? 1 : 0,
        )
        ..set(
          p('WRESP_READY'),
          writes.isNotEmpty && rng.nextDouble() < 0.6 ? 1 : 0,
        );
    });
  }
}

/// A slave with random READY on every channel and random latency. It
/// checks that RDATA_READY and WRESP_READY are high only while a response
/// is owed, and that the write data of each request is the data its source
/// sent.
class _Slave {
  final Sim s;
  final Random rng;
  final List<String> errors;
  final Map<int, _Req> byAddr;
  final Queue<(int, _Req)> reads = Queue();
  final Queue<(int, _Req)> writesWaitData = Queue();
  final Queue<(int, _Req, int)> wresps = Queue();
  final Queue<(int, _Req, int)> readyReads = Queue();
  int cycle = 0;
  int _wBeat = 0;
  bool _rUp = false;
  bool _bUp = false;
  int _rBeat = 0;

  _Slave(this.s, this.rng, this.errors, this.byAddr) {
    int p(String n) => s.pre('mem_$n');
    s.onRise(() {
      cycle++;
      if (p('RDATA_READY') == 1 && readyReads.isEmpty && reads.isEmpty) {
        errors.add('cycle $cycle: RDATA_READY with no read owed');
      }
      if (p('WRESP_READY') == 1 && wresps.isEmpty && writesWaitData.isEmpty) {
        errors.add('cycle $cycle: WRESP_READY with no write owed');
      }
      if (p('REQ_VALID') == 1 && p('REQ_READY') == 1) {
        final r = byAddr[p('REQ_ADDR')];
        if (r == null ||
            r.write != (p('REQ_WRITE') == 1) ||
            r.len != p('REQ_LEN') ||
            r.src != p('REQ_ID')) {
          errors.add('cycle $cycle: unknown request');
        } else if (r.write) {
          writesWaitData.add((p('REQ_ID'), r));
        } else {
          reads.add((p('REQ_ID'), r));
        }
      }
      // Data may come before its request, so it waits here in order.
      if (p('WDATA_VALID') == 1 && p('WDATA_READY') == 1) {
        _early.add((p('WDATA_DATA'), p('WDATA_LAST')));
      }
      while (_early.isNotEmpty && writesWaitData.isNotEmpty) {
        final (d, l) = _early.removeFirst();
        _takeBeat(d, l);
      }
      if (_rUp && p('RDATA_READY') == 1) {
        _rUp = false;
        final (_, r, _) = readyReads.first;
        if (++_rBeat > r.len) {
          readyReads.removeFirst();
          _rBeat = 0;
        }
      }
      if (_bUp && p('WRESP_READY') == 1) {
        _bUp = false;
        wresps.removeFirst();
      }
      while (reads.isNotEmpty) {
        final (id, r) = reads.removeFirst();
        readyReads.add((id, r, cycle + rng.nextInt(6)));
      }
    });
    s.onFall(() {
      if (!_rUp &&
          readyReads.isNotEmpty &&
          readyReads.first.$3 <= cycle &&
          rng.nextDouble() < 0.7) {
        _rUp = true;
      }
      final rr = _rUp ? readyReads.first : null;
      if (!_bUp &&
          wresps.isNotEmpty &&
          wresps.first.$3 <= cycle &&
          rng.nextDouble() < 0.7) {
        _bUp = true;
      }
      final bb = _bUp ? wresps.first : null;
      s
        ..set('mem_REQ_READY', rng.nextDouble() < 0.5 ? 1 : 0)
        ..set('mem_WDATA_READY', rng.nextDouble() < 0.5 ? 1 : 0)
        ..set('mem_RDATA_VALID', _rUp ? 1 : 0)
        ..set('mem_RDATA_ID', rr?.$1 ?? 0)
        ..set('mem_RDATA_DATA', rr == null ? 0 : rr.$2.rdata(_rBeat))
        ..set('mem_RDATA_ERR', 0)
        ..set('mem_RDATA_EXOKAY', 0)
        ..set('mem_RDATA_LAST', rr != null && _rBeat == rr.$2.len ? 1 : 0)
        ..set('mem_WRESP_VALID', _bUp ? 1 : 0)
        ..set('mem_WRESP_ID', bb?.$1 ?? 0)
        ..set('mem_WRESP_ERR', 0)
        ..set('mem_WRESP_EXOKAY', 0);
    });
  }

  final Queue<(int, int)> _early = Queue();

  void _takeBeat(int d, int last) {
    final (id, r) = writesWaitData.first;
    if (d != r.wdata(_wBeat) || (last == 1) != (_wBeat == r.len)) {
      errors.add('cycle $cycle: write ${r.src}.${r.index} beat $_wBeat wrong');
    }
    if (++_wBeat > r.len) {
      _wBeat = 0;
      writesWaitData.removeFirst();
      wresps.add((id, r, cycle + rng.nextInt(6)));
    }
  }
}

Future<void> _run(int seed) async {
  final s = Sim(_Top());
  final rng = Random(seed);
  final errors = <String>[];
  const n = 80;
  final srcs = [for (var i = 0; i < 2; i++) _Source(s, i, rng, errors, n)];
  final byAddr = {
    for (final x in srcs)
      for (final r in x.todo) r.addr: r,
  };
  _Slave(s, rng, errors, byAddr);
  await s.start();
  Simulator.setMaxSimTime(1 << 40);
  for (var i = 0; i < 20000; i++) {
    if (srcs.every((x) => x.done == n) || errors.length > 5) break;
    await s.cycles(1);
  }
  await s.cycles(20);
  final idle = s.dut.output('idle').value.toInt();
  await s.stop();
  expect(errors, isEmpty);
  for (final x in srcs) {
    expect(x.done, n, reason: 'source ${x.id} got every response');
  }
  expect(idle, 1);
}

void main() {
  tearDown(() async => Simulator.reset());
  for (final seed in [1, 2, 3]) {
    test('random backpressure on every channel, seed $seed', () async {
      await _run(seed);
    });
  }
}
