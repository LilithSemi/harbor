import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:harbor/harbor.dart';

/// Store-visibility tests for [HarborL1DCache].
///
/// The kernel failure that motivated these is a burst of four back-to-back
/// stores (Linux `__list_add`) where the LAST store never became visible. The
/// D-cache is write-through and no-write-allocate, so every store occupies the
/// memory port for many cycles. While one store is outstanding the FSM asserts
/// `blockHit`, and the idle arm cannot accept the next store. Whether the later
/// stores of a burst survive is therefore decided by the request handshake.
///
/// These tests drive the REAL cache and check the backing memory, not the
/// cache's own status outputs.
class _Backing {
  _Backing({
    required this.cache,
    required this.memDone,
    required this.memValid,
    required this.memRdata,
    required this.latency,
  });

  final HarborL1DCache cache;
  final Logic memDone;
  final Logic memValid;
  final Logic memRdata;
  final int latency;

  /// When set, every memory response is a FAULT (`mem_done` with `mem_valid`
  /// low), which is how the MMU reports a page fault.
  var faultResponse = false;

  final mem = <int, BigInt>{};
  final writeLog = <(int, BigInt)>[];
  var writes = 0;
  var reads = 0;

  /// Memory accesses started, faulting ones included.
  var accesses = 0;
  var _armed = false;
  var _pending = 0;
  var _pendA = 0;
  var _pendWe = false;
  BigInt _pendW = BigInt.zero;

  /// One clock step with the multi-cycle memory model. The memory takes an
  /// access whenever `mem_en` is high and it is idle, then answers [latency]
  /// cycles later with a one-cycle `mem_done`/`mem_valid` pulse. `mem_en` stays
  /// high across a multi-beat line fill, so arming must be level-based, not
  /// edge-based.
  Future<void> step() async {
    await cache.input('clk').srcConnection!.nextPosedge;
    final en = cache.output('mem_en').value.toBool();
    if (!_armed && en) {
      _armed = true;
      accesses++;
      _pending = latency;
      _pendA = cache.output('mem_addr').value.toInt() & ~7;
      _pendWe = cache.output('mem_we').value.toBool();
      final w = cache.output('mem_wdata').value;
      _pendW = w.isValid ? w.toBigInt() : BigInt.zero;
    }
    var doneNow = false;
    if (_armed) {
      _pending--;
      if (_pending <= 0) {
        doneNow = true;
        _armed = false;
      }
    }
    if (doneNow) {
      if (faultResponse) {
        memDone.inject(1);
        memValid.inject(0);
        return;
      }
      if (_pendWe) {
        mem[_pendA] = _pendW;
        writeLog.add((_pendA, _pendW));
        writes++;
      } else {
        reads++;
        memRdata.inject(mem[_pendA] ?? BigInt.zero);
      }
      memDone.inject(1);
      memValid.inject(1);
    } else {
      memDone.inject(0);
      memValid.inject(0);
    }
  }
}

class _Dut {
  _Dut(this.cache, this.ports, this.backing);
  final HarborL1DCache cache;
  final Map<String, Logic> ports;
  final _Backing backing;

  Logic operator [](String n) => ports[n]!;
  bool get respValid => cache.output('resp_valid').value.toBool();
  bool get respFault => cache.output('resp_fault').value.toBool();
}

Future<_Dut> makeDut({
  int latency = 6,
  int ctxBits = 0,
  int size = 256,
  int lineSize = 8,
  int? reqAddrBits = 32,
}) async {
  final clk = SimpleClockGenerator(10).clk;
  final ports = <String, Logic>{
    'reset': Logic(name: 'reset'),
    'req_addr': Logic(name: 'req_addr', width: 64),
    'req_valid': Logic(name: 'req_valid'),
    'req_write': Logic(name: 'req_write'),
    'req_data': Logic(name: 'req_data', width: 64),
    'req_size': Logic(name: 'req_size', width: 3),
    'flush': Logic(name: 'flush'),
    'mem_done': Logic(name: 'mem_done'),
    'mem_valid': Logic(name: 'mem_valid'),
    'mem_rdata': Logic(name: 'mem_rdata', width: 64),
    'mem_fault': Logic(name: 'mem_fault'),
    if (ctxBits > 0) 'req_ctx': Logic(name: 'req_ctx', width: ctxBits),
  };

  final cache = HarborL1DCache(
    config: HarborL1dCacheConfig(size: size, ways: 1, lineSize: lineSize),
    xlen: 64,
    ctxBits: ctxBits,
    reqAddrBits: reqAddrBits,
  );
  cache.port('clk').getsLogic(clk);
  ports.forEach((n, l) => cache.port(n).getsLogic(l));
  await cache.build();

  ports['reset']!.inject(1);
  ports['req_valid']!.inject(0);
  ports['req_write']!.inject(0);
  ports['req_addr']!.inject(0);
  ports['req_data']!.inject(0);
  ports['req_size']!.inject(3);
  ports['flush']!.inject(0);
  ports['mem_done']!.inject(0);
  ports['mem_valid']!.inject(0);
  ports['mem_rdata']!.inject(0);
  // This suite's denied responses model MMU page faults.
  ports['mem_fault']!.inject(1);
  if (ctxBits > 0) ports['req_ctx']!.inject(0);

  unawaited(Simulator.run());

  final backing = _Backing(
    cache: cache,
    memDone: ports['mem_done']!,
    memValid: ports['mem_valid']!,
    memRdata: ports['mem_rdata']!,
    latency: latency,
  );
  await backing.step();
  ports['reset']!.inject(0);
  await backing.step();
  return _Dut(cache, ports, backing);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const base = 0x80001000;
  BigInt val(int i) =>
      BigInt.parse('11110000', radix: 16) + BigInt.from(i * 0x2001);

  /// The exec unit's handshake: assert the request and HOLD it until the cache
  /// answers, then drop it for [gap] cycles before the next store.
  test('burst of four held stores all reach memory', () async {
    final dut = await makeDut();
    for (var gap = 0; gap < 4; gap++) {
      for (var i = 0; i < 4; i++) {
        dut['req_addr'].inject(base + gap * 0x100 + i * 8);
        dut['req_data'].inject(val(gap * 4 + i));
        dut['req_write'].inject(1);
        dut['req_valid'].inject(1);
        // Step first: `resp_valid` still carries the PREVIOUS store's
        // completion pulse in the cycle the next request is presented, exactly
        // as the exec unit sees it.
        var guard = 0;
        var acked = false;
        while (!acked && guard < 500) {
          await dut.backing.step();
          guard++;
          acked = dut.respValid;
        }
        expect(acked, isTrue, reason: 'store $gap.$i never completed');
        dut['req_valid'].inject(0);
        dut['req_write'].inject(0);
        for (var g = 0; g < gap; g++) {
          await dut.backing.step();
        }
      }
    }
    for (var i = 0; i < 10; i++) {
      await dut.backing.step();
    }
    await Simulator.endSimulation();
    expect(dut.backing.writes, equals(16));
    for (var gap = 0; gap < 4; gap++) {
      for (var i = 0; i < 4; i++) {
        expect(
          dut.backing.mem[base + gap * 0x100 + i * 8],
          equals(val(gap * 4 + i)),
          reason: 'store $gap.$i (gap $gap) never reached memory',
        );
      }
    }
  });

  /// The same burst with the request held ACROSS the completion pulse, i.e.
  /// the address and data change on the very cycle `resp_valid` is high and
  /// `req_valid` never drops. `blockHit` covers the completion cycle so the new
  /// store must be taken the cycle after.
  test('burst of four stores with no idle cycle between them', () async {
    final dut = await makeDut();
    dut['req_write'].inject(1);
    dut['req_valid'].inject(1);
    var issued = 0;
    dut['req_addr'].inject(base);
    dut['req_data'].inject(val(0));
    var guard = 0;
    while (issued < 4 && guard < 2000) {
      await dut.backing.step();
      guard++;
      if (dut.respValid) {
        issued++;
        if (issued < 4) {
          dut['req_addr'].inject(base + issued * 8);
          dut['req_data'].inject(val(issued));
        }
      }
    }
    dut['req_valid'].inject(0);
    dut['req_write'].inject(0);
    for (var i = 0; i < 10; i++) {
      await dut.backing.step();
    }
    await Simulator.endSimulation();
    expect(issued, equals(4));
    expect(dut.backing.writes, equals(4));
    for (var i = 0; i < 4; i++) {
      expect(dut.backing.mem[base + i * 8], equals(val(i)));
    }
  });

  /// A store that arrives while a line fill is in flight, and is HELD, must be
  /// accepted once the fill retires and must reach memory.
  test('store held across an in-flight fill still reaches memory', () async {
    final dut = await makeDut(latency: 8, lineSize: 32);
    // Start a cacheable load miss so the cache is filling.
    dut['req_addr'].inject(base);
    dut['req_write'].inject(0);
    dut['req_valid'].inject(1);
    await dut.backing.step();
    await dut.backing.step();
    expect(
      dut.cache.output('busy').value.toBool(),
      isTrue,
      reason: 'fill did not start',
    );
    // Now present a store and hold it, exactly as the exec unit does.
    dut['req_addr'].inject(base + 0x80);
    dut['req_data'].inject(val(7));
    dut['req_write'].inject(1);
    var guard = 0;
    while (!dut.respValid && guard < 500) {
      await dut.backing.step();
      guard++;
    }
    dut['req_valid'].inject(0);
    dut['req_write'].inject(0);
    for (var i = 0; i < 10; i++) {
      await dut.backing.step();
    }
    await Simulator.endSimulation();
    expect(
      dut.backing.mem[base + 0x80],
      equals(val(7)),
      reason: 'store presented during a fill never reached memory',
    );
  });

  /// A store presented for ONE cycle while the cache is busy and then withdrawn
  /// is dropped: the cache has no accept handshake. This documents the contract
  /// the requester must keep.
  test('store withdrawn while the cache is busy is dropped', () async {
    final dut = await makeDut(latency: 8, lineSize: 32);
    dut['req_addr'].inject(base);
    dut['req_write'].inject(0);
    dut['req_valid'].inject(1);
    await dut.backing.step();
    await dut.backing.step();
    expect(dut.cache.output('busy').value.toBool(), isTrue);
    // One-cycle store while busy, then withdraw.
    dut['req_addr'].inject(base + 0x80);
    dut['req_data'].inject(val(9));
    dut['req_write'].inject(1);
    await dut.backing.step();
    dut['req_valid'].inject(0);
    dut['req_write'].inject(0);
    for (var i = 0; i < 40; i++) {
      await dut.backing.step();
    }
    await Simulator.endSimulation();
    expect(
      dut.backing.mem[base + 0x80],
      isNull,
      reason:
          'the cache latched a store it was never given time to accept; if '
          'this ever passes the handshake changed and the contract note in '
          'HarborL1DCache is stale',
    );
  });

  /// A store must invalidate the resident line of EVERY context, and must not
  /// be gated on a context match.
  test('store from another context still writes and invalidates', () async {
    final dut = await makeDut(ctxBits: 2, latency: 4);
    dut.backing.mem[base] = val(1);
    // Fill the line under context 1 with a load.
    dut['req_ctx'].inject(1);
    dut['req_addr'].inject(base);
    dut['req_write'].inject(0);
    dut['req_valid'].inject(1);
    var guard = 0;
    while (!dut.respValid && guard < 500) {
      await dut.backing.step();
      guard++;
    }
    expect(
      dut.cache.output('resp_data').value.toBigInt(),
      equals(val(1)),
      reason: 'ctx 1 load did not read the backing value',
    );
    dut['req_valid'].inject(0);
    await dut.backing.step();

    // Store the same line from context 2.
    dut['req_ctx'].inject(2);
    dut['req_addr'].inject(base);
    dut['req_data'].inject(val(2));
    dut['req_write'].inject(1);
    dut['req_valid'].inject(1);
    guard = 0;
    while (!dut.respValid && guard < 500) {
      await dut.backing.step();
      guard++;
    }
    expect(
      dut.respValid,
      isTrue,
      reason: 'store from a foreign context never completed',
    );
    dut['req_valid'].inject(0);
    dut['req_write'].inject(0);
    await dut.backing.step();
    expect(
      dut.backing.mem[base],
      equals(val(2)),
      reason: 'store from a foreign context did not reach memory',
    );

    // Context 1 must NOT still see the old value out of the cache.
    dut['req_ctx'].inject(1);
    dut['req_addr'].inject(base);
    dut['req_write'].inject(0);
    dut['req_valid'].inject(1);
    guard = 0;
    while (!dut.respValid && guard < 500) {
      await dut.backing.step();
      guard++;
    }
    final got = dut.cache.output('resp_data').value.toBigInt();
    await Simulator.endSimulation();
    expect(
      got,
      equals(val(2)),
      reason:
          'ctx 1 read a stale line: the store did not invalidate the copy '
          'held by another context, so the store looks lost',
    );
  });

  /// A flush that lands while a store is in flight must let the store finish
  /// and must issue the write-through EXACTLY ONCE. Abandoning the store gave
  /// the requester no answer, so it held its request and the write ran a second
  /// time. A duplicated write to DRAM is invisible, but a duplicated write to a
  /// device register is not.
  test('flush during a store issues the write exactly once', () async {
    final dut = await makeDut(latency: 10);
    dut['req_addr'].inject(base);
    dut['req_data'].inject(val(3));
    dut['req_write'].inject(1);
    dut['req_valid'].inject(1);
    await dut.backing.step();
    await dut.backing.step();
    expect(
      dut.cache.output('busy').value.toBool(),
      isTrue,
      reason: 'store did not start',
    );
    dut['flush'].inject(1);
    await dut.backing.step();
    dut['flush'].inject(0);
    // The requester holds. The store must complete exactly once, eventually.
    var guard = 0;
    while (!dut.respValid && guard < 500) {
      await dut.backing.step();
      guard++;
    }
    dut['req_valid'].inject(0);
    dut['req_write'].inject(0);
    for (var i = 0; i < 20; i++) {
      await dut.backing.step();
    }
    await Simulator.endSimulation();
    expect(
      dut.respValid || guard < 500,
      isTrue,
      reason: 'store flushed mid-flight never completed (requester wedged)',
    );
    expect(
      dut.backing.mem[base],
      equals(val(3)),
      reason: 'store flushed mid-flight never reached memory',
    );
    expect(
      dut.backing.writes,
      equals(1),
      reason:
          'the flush abandoned the in-flight store, so the requester re-issued '
          'it and the write-through reached memory twice',
    );
  });

  /// The `__list_add` shape: four back-to-back stores to lines that are ALREADY
  /// resident, each read back through the cache afterwards. A write-through
  /// store must drop the resident copy, or the read-back returns the value from
  /// before the store and the store looks lost.
  test('burst of stores to resident lines is visible to later loads', () async {
    final dut = await makeDut(latency: 5);
    final addrs = [base, base + 8, base + 0x40, base + 0x48];
    for (final a in addrs) {
      dut.backing.mem[a] = BigInt.zero;
    }
    // Fill every line with a load first, so each store has a resident copy to
    // invalidate.
    for (final a in addrs) {
      dut['req_addr'].inject(a);
      dut['req_write'].inject(0);
      dut['req_valid'].inject(1);
      var guard = 0;
      var acked = false;
      while (!acked && guard < 500) {
        await dut.backing.step();
        guard++;
        acked = dut.respValid;
      }
      expect(acked, isTrue, reason: 'priming load of 0x${a.toRadixString(16)}');
      expect(
        dut.cache.output('resp_data').value.toBigInt(),
        equals(BigInt.zero),
      );
      dut['req_valid'].inject(0);
    }
    // The burst.
    for (var i = 0; i < addrs.length; i++) {
      dut['req_addr'].inject(addrs[i]);
      dut['req_data'].inject(val(20 + i));
      dut['req_write'].inject(1);
      dut['req_valid'].inject(1);
      var guard = 0;
      var acked = false;
      while (!acked && guard < 500) {
        await dut.backing.step();
        guard++;
        acked = dut.respValid;
      }
      expect(acked, isTrue, reason: 'burst store $i never completed');
      dut['req_valid'].inject(0);
      dut['req_write'].inject(0);
    }
    // Read every one back THROUGH the cache.
    final readBack = <int, BigInt>{};
    for (final a in addrs) {
      dut['req_addr'].inject(a);
      dut['req_write'].inject(0);
      dut['req_valid'].inject(1);
      var guard = 0;
      var acked = false;
      while (!acked && guard < 500) {
        await dut.backing.step();
        guard++;
        acked = dut.respValid;
      }
      expect(acked, isTrue, reason: 'read-back of 0x${a.toRadixString(16)}');
      readBack[a] = dut.cache.output('resp_data').value.toBigInt();
      dut['req_valid'].inject(0);
    }
    await Simulator.endSimulation();
    for (var i = 0; i < addrs.length; i++) {
      expect(
        dut.backing.mem[addrs[i]],
        equals(val(20 + i)),
        reason: 'burst store $i never reached memory',
      );
      expect(
        readBack[addrs[i]],
        equals(val(20 + i)),
        reason:
            'read-back $i returned the pre-store value: the write-through '
            'store did not invalidate the resident line, so the store looks '
            'lost to software',
      );
    }
  });

  /// A sub-word store to a resident line must still drop that line.
  test('sub-word store to a resident line invalidates it', () async {
    final dut = await makeDut(latency: 5);
    dut.backing.mem[base] = BigInt.parse('AAAAAAAAAAAAAAAA', radix: 16);
    dut['req_addr'].inject(base);
    dut['req_write'].inject(0);
    dut['req_valid'].inject(1);
    var guard = 0;
    var acked = false;
    while (!acked && guard < 500) {
      await dut.backing.step();
      guard++;
      acked = dut.respValid;
    }
    expect(acked, isTrue);
    dut['req_valid'].inject(0);
    // Byte store at base+3.
    dut['req_addr'].inject(base + 3);
    dut['req_size'].inject(0);
    dut['req_data'].inject(BigInt.from(0x5a));
    dut['req_write'].inject(1);
    dut['req_valid'].inject(1);
    guard = 0;
    acked = false;
    while (!acked && guard < 500) {
      await dut.backing.step();
      guard++;
      acked = dut.respValid;
    }
    expect(acked, isTrue, reason: 'sub-word store never completed');
    dut['req_valid'].inject(0);
    dut['req_write'].inject(0);
    dut['req_size'].inject(3);
    // The backing model is word granular, so model the merge here: what matters
    // is that the cache goes back to memory instead of answering from the line.
    dut.backing.mem[base] = BigInt.parse('AAAAAAAAAAAA5AAA', radix: 16);
    dut['req_addr'].inject(base);
    dut['req_write'].inject(0);
    dut['req_valid'].inject(1);
    guard = 0;
    acked = false;
    while (!acked && guard < 500) {
      await dut.backing.step();
      guard++;
      acked = dut.respValid;
    }
    final got = dut.cache.output('resp_data').value.toBigInt();
    await Simulator.endSimulation();
    expect(acked, isTrue);
    expect(
      got,
      equals(BigInt.parse('AAAAAAAAAAAA5AAA', radix: 16)),
      reason: 'the byte store left a stale line resident',
    );
  });

  /// The same for an uncached read. A flush must not throw away an in-flight
  /// MMIO read: the requester holds, so the read runs again, and a second read
  /// of a register with a read side effect (a receive FIFO) loses a byte.
  test('flush during an uncached read issues the read exactly once', () async {
    // Below cacheableBase, so the access bypasses the cache entirely.
    const mmio = 0x10000000;
    final dut = await makeDut(latency: 10);
    dut.backing.mem[mmio] = val(11);
    dut['req_addr'].inject(mmio);
    dut['req_write'].inject(0);
    dut['req_valid'].inject(1);
    await dut.backing.step();
    await dut.backing.step();
    expect(
      dut.cache.output('busy').value.toBool(),
      isTrue,
      reason: 'uncached read did not start',
    );
    dut['flush'].inject(1);
    await dut.backing.step();
    dut['flush'].inject(0);
    var guard = 0;
    var acked = false;
    while (!acked && guard < 500) {
      await dut.backing.step();
      guard++;
      acked = dut.respValid;
    }
    final got = dut.cache.output('resp_data').value.toBigInt();
    dut['req_valid'].inject(0);
    for (var i = 0; i < 10; i++) {
      await dut.backing.step();
    }
    await Simulator.endSimulation();
    expect(
      acked,
      isTrue,
      reason: 'uncached read never completed after a flush',
    );
    expect(got, equals(val(11)));
    expect(
      dut.backing.reads,
      equals(1),
      reason:
          'the flush abandoned the in-flight uncached read, so the requester '
          're-issued it and the device was read twice',
    );
  });

  /// A flush mid-fill still abandons the fill, and the drain still swallows the
  /// stale completion so it cannot become word 0 of the next line.
  test('flush during a fill abandons the line and drains', () async {
    final dut = await makeDut(latency: 6, lineSize: 32);
    dut.backing.mem[base] = val(12);
    dut['req_addr'].inject(base);
    dut['req_write'].inject(0);
    dut['req_valid'].inject(1);
    await dut.backing.step();
    await dut.backing.step();
    expect(dut.cache.output('busy').value.toBool(), isTrue);
    dut['flush'].inject(1);
    await dut.backing.step();
    dut['flush'].inject(0);
    // The requester holds; the load must eventually be served with the real
    // value, from a fresh fill.
    var guard = 0;
    var acked = false;
    while (!acked && guard < 800) {
      await dut.backing.step();
      guard++;
      acked = dut.respValid;
    }
    final got = dut.cache.output('resp_data').value.toBigInt();
    await Simulator.endSimulation();
    expect(acked, isTrue, reason: 'load flushed mid-fill never completed');
    expect(
      got,
      equals(val(12)),
      reason: 'the abandoned fill left the wrong word in the new line',
    );
  });

  /// A flush that lands while a store is in flight, where the memory then
  /// DENIES that store (`mem_done` with `mem_valid` low, how the MMU reports a
  /// page fault).
  ///
  /// The abandon-and-drain path swallowed that completion unconditionally: the
  /// drain handler does not look at `mem_valid`, so a denied store was
  /// discarded with no fault reported. The store must be reported as a fault
  /// off its OWN access, not silently discarded and not quietly replayed
  /// against the device.
  test('flush during a store that then faults reports the fault', () async {
    final dut = await makeDut(latency: 8);
    dut.backing.faultResponse = true;
    dut['req_addr'].inject(base);
    dut['req_data'].inject(val(13));
    dut['req_write'].inject(1);
    dut['req_valid'].inject(1);
    await dut.backing.step();
    await dut.backing.step();
    expect(
      dut.cache.output('busy').value.toBool(),
      isTrue,
      reason: 'store did not start',
    );
    dut['flush'].inject(1);
    await dut.backing.step();
    dut['flush'].inject(0);
    var guard = 0;
    var sawFault = false;
    var sawValid = false;
    var accessesAtFault = 0;
    while (!sawFault && !sawValid && guard < 400) {
      await dut.backing.step();
      guard++;
      sawFault = dut.respFault;
      sawValid = dut.respValid;
    }
    accessesAtFault = dut.backing.accesses;
    dut['req_valid'].inject(0);
    dut['req_write'].inject(0);
    await Simulator.endSimulation();
    expect(
      sawFault,
      isTrue,
      reason:
          'the flush put the cache into drain, which discarded the DENIED '
          'store completion without looking at mem_valid, so the store neither '
          'landed nor raised a fault',
    );
    expect(sawValid, isFalse, reason: 'a denied store reported success');
    expect(dut.backing.writes, equals(0));
    expect(
      accessesAtFault,
      equals(1),
      reason:
          'the denied store was abandoned and replayed against memory before '
          'the fault was reported',
    );
  });

  /// A faulting store must not report success, and must not write memory.
  /// A store that completes on `mem_done` alone would swallow a store page
  /// fault and let the core carry on as if the write had landed.
  test('faulting store reports a fault and writes nothing', () async {
    final dut = await makeDut(latency: 4);
    dut.backing.faultResponse = true;
    dut['req_addr'].inject(base);
    dut['req_data'].inject(val(5));
    dut['req_write'].inject(1);
    dut['req_valid'].inject(1);
    var sawFault = false;
    var sawValid = false;
    for (var i = 0; i < 40; i++) {
      await dut.backing.step();
      if (dut.respFault) sawFault = true;
      if (dut.respValid) sawValid = true;
    }
    await Simulator.endSimulation();
    expect(sawFault, isTrue, reason: 'faulting store did not report a fault');
    expect(
      sawValid,
      isFalse,
      reason: 'faulting store reported success as well as a fault',
    );
    expect(
      dut.backing.writes,
      equals(0),
      reason: 'a store completed without the write reaching memory',
    );
  });
}
