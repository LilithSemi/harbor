import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _base = 0x80000000;

/// Dual-port I-cache with 32 one-word lines and a memory that latches one
/// read and answers [latency] cycles later, also after `mem_en` drops.
class _Bench {
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final flush = Logic(name: 'flush');
  final reqAddr = [
    Logic(name: 'req_addr', width: 64),
    Logic(name: 'req_addr1', width: 64),
  ];
  final reqValid = [Logic(name: 'req_valid'), Logic(name: 'req_valid1')];
  final memDone = Logic(name: 'mem_done');
  final memValid = Logic(name: 'mem_valid');
  final memRdata = Logic(name: 'mem_rdata', width: 64);
  final int latency;
  late final HarborL1ICache cache;

  var reads = 0;
  var perfMisses = 0;
  var _active = false;
  var _countdown = 0;
  var _addr = 0;
  var _cooldown = 0;

  _Bench({this.latency = 3});

  Future<void> start() async {
    cache = HarborL1ICache(
      config: const HarborL1iCacheConfig(size: 256, ways: 1, lineSize: 8),
      xlen: 64,
      dualPort: true,
      reqAddrBits: 32,
    );
    cache.port('clk').getsLogic(clk);
    cache.port('reset').getsLogic(reset);
    cache.port('flush').getsLogic(flush);
    cache.port('req_addr').getsLogic(reqAddr[0]);
    cache.port('req_valid').getsLogic(reqValid[0]);
    cache.port('req_addr1').getsLogic(reqAddr[1]);
    cache.port('req_valid1').getsLogic(reqValid[1]);
    cache.port('mem_done').getsLogic(memDone);
    cache.port('mem_valid').getsLogic(memValid);
    cache.port('mem_rdata').getsLogic(memRdata);
    await cache.build();
    reset.inject(1);
    flush.inject(0);
    for (var p = 0; p < 2; p++) {
      reqValid[p].inject(0);
      reqAddr[p].inject(_base);
    }
    memDone.inject(0);
    memValid.inject(0);
    memRdata.inject(0);
    unawaited(Simulator.run());
    await step();
    reset.inject(0);
    await step();
  }

  bool respValid(int port) =>
      cache.output(port == 0 ? 'resp_valid' : 'resp_valid1').value.toBool();
  bool get perfMiss => cache.output('perf_miss').value.toBool();

  Future<void> step() async {
    await clk.nextPosedge;
    if (cache.output('perf_miss').value.toBool()) perfMisses++;
    var done = false;
    if (_active) {
      if (--_countdown <= 0) {
        done = true;
        _active = false;
        _cooldown = 1;
      }
    } else if (_cooldown > 0) {
      _cooldown--;
    } else if (cache.output('mem_en').value.toBool()) {
      _addr = cache.output('mem_addr').value.toInt();
      _countdown = latency;
      _active = true;
      reads++;
    }
    memDone.inject(done ? 1 : 0);
    memValid.inject(done ? 1 : 0);
    memRdata.inject(done ? _addr : 0);
  }

  /// Fetches [addr] on [port] and returns the data.
  Future<int> fetch(int port, int addr) async {
    reqAddr[port].inject(addr);
    reqValid[port].inject(1);
    for (var i = 0; i < 100; i++) {
      await step();
      if (respValid(port)) {
        final data = cache
            .output(port == 0 ? 'resp_data' : 'resp_data1')
            .value
            .toInt();
        reqValid[port].inject(0);
        await step();
        return data;
      }
    }
    fail('fetch of $addr on port $port never completed');
  }

  Future<void> end() async {
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  }
}

void main() {
  tearDown(Simulator.reset);

  for (final port in [0, 1]) {
    for (final flushCycles in [1, 3]) {
      test('fence.i blocks port $port for exactly the sweep '
          '($flushCycles-cycle flush)', () async {
        final b = _Bench();
        await b.start();
        try {
          const addr = _base + 0x18;
          expect(await b.fetch(port, addr), addr);
          final reads = b.reads;
          expect(await b.fetch(port, addr), addr);
          expect(b.reads, reads);

          b.reqAddr[port].inject(addr);
          b.reqValid[port].inject(1);
          b.flush.inject(1);
          for (var c = 0; c < flushCycles; c++) {
            await b.step();
          }
          b.flush.inject(0);
          // Count the cycles after the last flush edge with no answer.
          var blocked = 0;
          for (var c = 0; c < 20 && !b.respValid(port) && !b.perfMiss; c++) {
            blocked++;
            await b.step();
          }
          expect(blocked, b.cache.sweepCycles);
          expect(b.respValid(port), isFalse);
          expect(b.perfMiss, isTrue, reason: 'the line must miss');
        } finally {
          await b.end();
        }
      });
    }
  }

  test('flush clears every valid word of a dual-port I-cache', () async {
    final b = _Bench();
    await b.start();
    try {
      final lines = List.generate(32, (i) => _base + i * 8);
      for (final a in lines) {
        expect(await b.fetch(0, a), a);
      }
      final filled = b.reads;
      for (final a in lines) {
        expect(await b.fetch(1, a), a);
      }
      expect(b.reads, filled, reason: 'every line must hit before the flush');

      for (final port in [1, 0]) {
        b.flush.inject(1);
        await b.step();
        b.flush.inject(0);
        final before = b.reads;
        for (final a in lines) {
          final r = b.reads;
          expect(await b.fetch(port, a), a);
          expect(b.reads, r + 1, reason: 'line $a must miss on port $port');
        }
        expect(b.reads, before + 32);
      }
    } finally {
      await b.end();
    }
  });
}
