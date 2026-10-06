import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Behavioural tests for the real HarborL1ICache / HarborL1DCache: a miss fills
/// its line one paced word at a time from the memory handshake, then the held
/// request hits out of the block RAM. This is the DDR-pacing property the caches
/// exist for, each miss is exactly one memory read, never a line burst.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('l1i: paced single-word fill then hit', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final reqAddr = Logic(name: 'req_addr', width: 64);
    final reqValid = Logic(name: 'req_valid');
    final flush = Logic(name: 'flush');
    final memDone = Logic(name: 'mem_done');
    final memValid = Logic(name: 'mem_valid');
    final memRdata = Logic(name: 'mem_rdata', width: 64);

    final cache = HarborL1ICache(
      config: const HarborL1iCacheConfig(size: 256, ways: 1, lineSize: 8),
      xlen: 64,
      reqAddrBits: 32,
    );
    cache.port('clk').getsLogic(clk);
    cache.port('reset').getsLogic(reset);
    cache.port('req_addr').getsLogic(reqAddr);
    cache.port('req_valid').getsLogic(reqValid);
    cache.port('flush').getsLogic(flush);
    cache.port('mem_done').getsLogic(memDone);
    cache.port('mem_valid').getsLogic(memValid);
    cache.port('mem_rdata').getsLogic(memRdata);

    await cache.build();

    const addr = 0x80000010;
    final data = BigInt.parse('DEADBEEF12345678', radix: 16);

    reset.inject(1);
    reqValid.inject(0);
    reqAddr.inject(0);
    flush.inject(0);
    memDone.inject(0);
    memValid.inject(0);
    memRdata.inject(data);

    unawaited(Simulator.run());

    // Always-ready single-word memory: answer whenever the cache asks.
    final memEn = cache.output('mem_en');
    var memPulses = 0;

    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    reqValid.inject(1);
    reqAddr.inject(addr);

    var served = false;
    BigInt? got;
    for (var cycle = 0; cycle < 40 && !served; cycle++) {
      await clk.nextPosedge;
      // Model the paced memory: assert done/valid the cycle the cache requests.
      final asking = memEn.value.toBool();
      if (asking) memPulses++;
      memDone.inject(asking ? 1 : 0);
      memValid.inject(asking ? 1 : 0);
      if (cache.output('resp_valid').value.toBool()) {
        served = true;
        got = cache.output('resp_data').value.toBigInt();
      }
    }

    expect(served, isTrue, reason: 'cache never served the fetch');
    expect(got, equals(data), reason: 'wrong word served');
    expect(
      memPulses,
      equals(1),
      reason: 'single-word line must fill with exactly one paced read',
    );

    // Steady state: the same address keeps hitting with no further memory reads.
    final pulsesBefore = memPulses;
    for (var cycle = 0; cycle < 8; cycle++) {
      await clk.nextPosedge;
      if (memEn.value.toBool()) memPulses++;
    }
    expect(memPulses, equals(pulsesBefore), reason: 'resident line re-fetched');
    expect(
      cache.output('resp_valid').value.toBool(),
      isTrue,
      reason: 'resident line stopped hitting',
    );

    await Simulator.endSimulation();
  });

  test('l1d: load-fill/hit, write-through store, invalidate-on-hit', () async {
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
    final memFault = Logic(name: 'mem_fault');

    final cache = HarborL1DCache(
      config: const HarborL1dCacheConfig(size: 256, ways: 1, lineSize: 8),
      xlen: 64,
      reqAddrBits: 32,
      memFaultIn: memFault,
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

    const addr = 0x80000020;
    final v0 = BigInt.parse('1111111122222222', radix: 16);
    final v1 = BigInt.parse('AAAABBBBCCCCDDDD', radix: 16);

    // Backing memory the cache writes through to.
    final mem = <int, BigInt>{addr: v0};

    reset.inject(1);
    reqValid.inject(0);
    reqWrite.inject(0);
    reqAddr.inject(0);
    reqData.inject(0);
    reqSize.inject(2);
    flush.inject(0);
    memDone.inject(0);
    memValid.inject(0);
    memRdata.inject(0);

    unawaited(Simulator.run());

    final memEn = cache.output('mem_en');
    final memWe = cache.output('mem_we');
    final memAddr = cache.output('mem_addr');
    final memWdata = cache.output('mem_wdata');

    var reads = 0;
    var writes = 0;
    var prevEn = false;

    // One clock step that also services the paced memory model.
    Future<void> step() async {
      await clk.nextPosedge;
      final en = memEn.value.toBool();
      final we = memWe.value.toBool();
      if (en && !prevEn) {
        if (we) {
          writes++;
        } else {
          reads++;
        }
      }
      prevEn = en;
      if (en) {
        final a = memAddr.value.toInt() & ~7;
        if (we) {
          mem[a] = memWdata.value.toBigInt();
        } else {
          memRdata.inject(mem[a] ?? BigInt.zero);
        }
        memDone.inject(1);
        memValid.inject(1);
      } else {
        memDone.inject(0);
        memValid.inject(0);
      }
    }

    // Drive one request until the cache responds, then return the served data.
    Future<BigInt> op({
      required int a,
      required bool write,
      BigInt? data,
    }) async {
      reqAddr.inject(a);
      reqData.inject(data ?? BigInt.zero);
      reqWrite.inject(write);
      reqValid.inject(1);
      BigInt? served;
      for (var i = 0; i < 40 && served == null; i++) {
        await step();
        if (cache.output('resp_valid').value.toBool()) {
          served = cache.output('resp_data').value.toBigInt();
        }
      }
      // Drop the request so the next op starts from idle.
      reqValid.inject(0);
      await step();
      expect(served, isNotNull, reason: 'cache never responded');
      return served!;
    }

    await step();
    reset.inject(0);
    await step();

    // Load A: miss -> paced fill -> serve V0.
    expect(await op(a: addr, write: false), equals(v0));
    expect(reads, equals(1), reason: 'load miss must be one paced read');

    // Load A again: resident hit, no new memory read.
    expect(await op(a: addr, write: false), equals(v0));
    expect(reads, equals(1), reason: 'resident load should not re-read memory');

    // Store A = V1: write-through to memory, invalidate the resident line.
    await op(a: addr, write: true, data: v1);
    expect(writes, equals(1), reason: 'store must write through to memory');
    expect(mem[addr], equals(v1), reason: 'memory did not receive the store');

    // Load A: the invalidate forced a re-fill, which returns the stored V1.
    expect(
      await op(a: addr, write: false),
      equals(v1),
      reason: 'store did not invalidate the cached line',
    );
    expect(
      reads,
      equals(2),
      reason: 'invalidated line must re-fill from memory',
    );

    await Simulator.endSimulation();
  });

  test(
    'l1d: uncacheable (MMIO) load bypasses, never caches a stale value',
    () async {
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
      final memFault = Logic(name: 'mem_fault');

      final cache = HarborL1DCache(
        config: const HarborL1dCacheConfig(size: 256, ways: 1, lineSize: 8),
        xlen: 64,
        reqAddrBits: 32,
        memFaultIn: memFault,
        // DRAM base, anything below is MMIO/SRAM/flash and must bypass.
        cacheableBase: 0x80000000,
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

      // A UART status register, below the cacheable base.
      const lsr = 0x10000005;
      // The value the "device" returns. It changes underneath us, exactly like a
      // TX-ready bit toggling. A cached load would latch the first value forever.
      var deviceWord = BigInt.from(0);

      reset.inject(1);
      for (final l in [
        reqValid,
        reqWrite,
        reqAddr,
        reqData,
        memDone,
        memValid,
      ]) {
        l.inject(0);
      }
      reqSize.inject(2);
      flush.inject(0);
      memRdata.inject(0);

      unawaited(Simulator.run());

      final memEn = cache.output('mem_en');
      var reads = 0;
      var prevEn = false;

      Future<void> step() async {
        await clk.nextPosedge;
        final en = memEn.value.toBool();
        if (en && !prevEn) reads++;
        prevEn = en;
        if (en) {
          memRdata.inject(deviceWord);
          memDone.inject(1);
          memValid.inject(1);
        } else {
          memDone.inject(0);
          memValid.inject(0);
        }
      }

      Future<BigInt> loadOnce(int a) async {
        reqAddr.inject(a);
        reqWrite.inject(0);
        reqValid.inject(1);
        BigInt? served;
        for (var i = 0; i < 40 && served == null; i++) {
          await step();
          if (cache.output('resp_valid').value.toBool()) {
            served = cache.output('resp_data').value.toBigInt();
          }
        }
        reqValid.inject(0);
        await step();
        expect(served, isNotNull, reason: 'uncacheable load never responded');
        return served!;
      }

      await step();
      reset.inject(0);
      await step();

      deviceWord = BigInt.from(0x20); // TX not ready
      expect(await loadOnce(lsr), equals(BigInt.from(0x20)));
      expect(reads, equals(1), reason: 'first MMIO load must read memory');

      // Device toggles. A cached load would still return 0x20 and hang the caller.
      deviceWord = BigInt.from(0x60); // TX ready
      expect(
        await loadOnce(lsr),
        equals(BigInt.from(0x60)),
        reason: 'MMIO load returned a stale cached value (cacheability bug)',
      );
      expect(reads, equals(2), reason: 'every MMIO load must re-read memory');

      await Simulator.endSimulation();
    },
  );
}
