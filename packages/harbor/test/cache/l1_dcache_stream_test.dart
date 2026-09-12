import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:harbor/harbor.dart';

/// Reproduces the creek hardware bug (isolated by the RiverDdrVerify probe):
/// SINGLE-word / paced stores land perfectly, but back-to-back STREAMING stores
/// are dropped (~1 of N survives). ddrverify: single-word 8/8 OK, but a 4KB
/// sequential write read back 1023/1024 wrong, and a post-bulk read returned the
/// STALE pre-bulk value, i.e. the streaming stores never reached the array.
///
/// The existing l1_sim_test drives one store at a time with an IMMEDIATE memDone,
/// so it never exercises the stall path under back-to-back stores against a
/// realistic (multi-cycle) backing. This test does: a DELAYED backing (memDone D
/// cycles after the cache raises mem_en) + N streaming stores (req_valid held
/// high, address/data advanced the cycle the cache accepts) + a full read-back
/// verify. If the cache drops streaming stores, the backing is missing them.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  Future<void> streamStores({required int memLatency}) async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final reqAddr = Logic(name: 'req_addr', width: 64);
    final reqValid = Logic(name: 'req_valid');
    final reqWrite = Logic(name: 'req_write');
    final reqData = Logic(name: 'req_data', width: 64);
    final reqSize = Logic(name: 'req_size', width: 3);
    final flush = Logic(name: 'flush');
    final memDone = Logic(name: 'mem_done');
    final memValid = Logic(name: 'mem_valid');
    final memRdata = Logic(name: 'mem_rdata', width: 64);

    final cache = HarborL1DCache(
      config: const HarborL1dCacheConfig(size: 256, ways: 1, lineSize: 8),
      xlen: 64,
      reqAddrBits: 32,
    );
    for (final (n, l) in [
      ('clk', clk),
      ('reset', reset),
      ('req_addr', reqAddr),
      ('req_valid', reqValid),
      ('req_write', reqWrite),
      ('req_data', reqData),
      ('req_size', reqSize),
      ('flush', flush),
      ('mem_done', memDone),
      ('mem_valid', memValid),
      ('mem_rdata', memRdata),
    ]) {
      cache.port(n).getsLogic(l);
    }
    await cache.build();

    reset.inject(1);
    reqValid.inject(0);
    reqWrite.inject(0);
    reqAddr.inject(0);
    reqData.inject(0);
    reqSize.inject(3); // 8-byte (full-line) accesses
    flush.inject(0);
    memDone.inject(0);
    memValid.inject(0);
    memRdata.inject(0);

    unawaited(Simulator.run());

    final memEn = cache.output('mem_en');
    final memWe = cache.output('mem_we');
    final memAddr = cache.output('mem_addr');
    final memWdata = cache.output('mem_wdata');

    final mem = <int, BigInt>{};
    var writes = 0;
    var prevEn = false;
    // Model a multi-cycle backing: when the cache raises mem_en, count down
    // [memLatency] cycles, then pulse mem_done/mem_valid for one cycle and
    // commit (write) / present (read) the data. This is what the real DDR path
    // (CDC + downsizer + PHY) looks like to the cache: not instantaneous.
    var pending = 0;
    var pendA = 0;
    var pendWe = false;
    BigInt pendW = BigInt.zero;

    Future<void> step() async {
      await clk.nextPosedge;
      final en = memEn.value.toBool();
      final we = memWe.value.toBool();
      // New access edge: latch it, start the latency countdown.
      if (en && !prevEn) {
        pending = memLatency;
        pendA = memAddr.value.toInt() & ~7;
        pendWe = we;
        pendW = memWdata.value.toBigInt();
      }
      prevEn = en;
      var doneNow = false;
      if (pending > 0) {
        pending--;
        if (pending == 0) doneNow = true;
      }
      if (doneNow) {
        if (pendWe) {
          mem[pendA] = pendW;
          writes++;
        } else {
          memRdata.inject(mem[pendA] ?? BigInt.zero);
        }
        memDone.inject(1);
        memValid.inject(1);
      } else {
        memDone.inject(0);
        memValid.inject(0);
      }
    }

    await step();
    reset.inject(0);
    await step();

    const base = 0x80000000;
    const n = 32;
    BigInt val(int i) =>
        BigInt.parse('CAFE0000', radix: 16) + BigInt.from(i * 0x10001);

    // STREAMING stores: hold req_valid high, advance addr/data the cycle the
    // cache asserts resp_valid, never returning to idle between stores.
    reqWrite.inject(1);
    reqValid.inject(1);
    var issued = 0;
    reqAddr.inject(base);
    reqData.inject(val(0));
    var guard = 0;
    while (issued < n && guard < 20000) {
      await step();
      guard++;
      if (cache.output('resp_valid').value.toBool()) {
        issued++;
        if (issued < n) {
          reqAddr.inject(base + issued * 8);
          reqData.inject(val(issued));
        }
      }
    }
    reqValid.inject(0);
    reqWrite.inject(0);
    for (var i = 0; i < 20; i++) {
      await step();
    }
    await Simulator.endSimulation();

    expect(
      issued,
      equals(n),
      reason: 'cache did not accept all $n streamed stores',
    );
    expect(
      writes,
      equals(n),
      reason:
          'STREAMING WRITE DROP: cache issued $writes of $n write-throughs '
          '(the creek bug - back-to-back stores dropped)',
    );
    for (var i = 0; i < n; i++) {
      expect(
        mem[base + i * 8],
        equals(val(i)),
        reason: 'word $i lost/stale: streaming store did not reach memory',
      );
    }
  }

  test(
    'streaming 64-bit stores all reach memory (fast backing, D=6)',
    () async {
      await streamStores(memLatency: 6);
    },
  );
  test(
    'streaming 64-bit stores all reach memory (slower backing, D=12)',
    () async {
      await streamStores(memLatency: 12);
    },
  );
}
