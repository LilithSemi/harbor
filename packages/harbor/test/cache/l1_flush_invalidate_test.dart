import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'l1d_dut.dart';

/// Does the whole-cache flush REALLY drop every line?
///
/// Both L1s sit in front of the MMU, so they are virtually indexed and
/// virtually tagged. A `satp` write re-points every virtual address at
/// different memory, and the core answers it with a single-cycle pulse on the
/// same `flush` net that carries `fence.i` and `sfence.vma`. Nothing checked
/// that the pulse is sufficient. These tests check the three ways it could be
/// insufficient:
///
///   1. a line that was valid BEFORE the pulse survives it,
///   2. a fill that was in flight AT the pulse still validates its line after,
///   3. the pulse itself wedges the cache, so nothing fills again.
///
/// Line arithmetic, D-cache (size 256 B, line 8 B, xlen 64, direct mapped):
///   wordBytes 8 -> byteBits 3, lineWords 1 -> offBits 0, 32 lines -> idxBits 5.
///   index = addr[7:3], tag = addr[31:8] at reqAddrBits 32.
///   0x80001000 -> index (0x1000 >> 3) & 0x1F = 0
///   0x80001008 -> index (0x1008 >> 3) & 0x1F = 1
/// Both are at or above cacheableBase (0x80000000), so both take the CACHED
/// path. An address below that bypasses the cache and proves nothing.
///
/// Line arithmetic, I-cache (size 256 B, line 8 B): identical, index =
/// addr[7:3].
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // Cacheable: at or above cacheableBase (0x80000000).
  const addrA = 0x80001000; // D/I line 0
  const addrB = 0x80001008; // D/I line 1
  final dataA = BigInt.parse('AAAAAAAAAAAAAAAA', radix: 16);
  final dataA2 = BigInt.parse('A2A2A2A2A2A2A2A2', radix: 16);
  final dataB = BigInt.parse('BBBBBBBBBBBBBBBB', radix: 16);

  /// Presents [addr] as a load until the cache answers. Returns the data.
  Future<BigInt> load(Dut dut, int addr, {int guardCycles = 200}) async {
    dut['req_addr'].inject(addr);
    dut['req_write'].inject(0);
    dut['req_size'].inject(3);
    dut['req_valid'].inject(1);
    var got = BigInt.zero;
    var acked = false;
    for (var i = 0; i < guardCycles && !acked; i++) {
      await dut.backing.step();
      if (dut.respValid) {
        got = dut.cache.output('resp_data').value.toBigInt();
        acked = true;
      }
    }
    expect(
      acked,
      isTrue,
      reason:
          'load of 0x${addr.toRadixString(16)} '
          'never completed',
    );
    dut['req_valid'].inject(0);
    await dut.backing.step();
    return got;
  }

  group('HarborL1DCache flush', () {
    /// The plain property: a line resident before the pulse must not answer a
    /// load issued after it. This is exactly what a `satp` write needs, because
    /// the SAME virtual address now names a different physical page.
    test(
      'a resident line does not answer a load issued after the pulse',
      () async {
        final dut = await makeDut(latency: 6);
        dut.backing.mem[addrA] = dataA;

        expect(await load(dut, addrA), equals(dataA));
        expect(dut.backing.reads, equals(1), reason: 'the fill must read once');

        // Confirm the line really is resident: a second load must NOT read again.
        expect(await load(dut, addrA), equals(dataA));
        final residentReads = dut.backing.reads;

        // The page now holds different memory, exactly as after a satp write.
        dut.backing.mem[addrA] = dataA2;

        dut['flush'].inject(1);
        await dut.backing.step();
        dut['flush'].inject(0);
        await dut.backing.step();

        final got = await load(dut, addrA);
        final reads = dut.backing.reads;
        await Simulator.endSimulation();

        expect(
          residentReads,
          equals(1),
          reason:
              'the second load re-read memory, so the line was never '
              'resident and this test proves nothing about the flush',
        );
        expect(
          reads,
          equals(2),
          reason:
              'STALE LINE: the load after the flush did not reach memory, '
              'so it hit the line the flush was supposed to drop',
        );
        expect(
          got,
          equals(dataA2),
          reason:
              'STALE DATA: the load after the flush returned the OLD '
              'address space data',
        );
      },
    );

    /// A fill already in flight when the pulse lands must not validate its
    /// line afterwards. The requester is dropped at the pulse, so nothing
    /// legitimately refills the line: any later hit is the abandoned fill.
    test('a fill in flight at the pulse does not validate its line', () async {
      final dut = await makeDut(latency: 8);
      dut.backing.mem[addrA] = dataA;

      dut['req_addr'].inject(addrA);
      dut['req_write'].inject(0);
      dut['req_size'].inject(3);
      dut['req_valid'].inject(1);
      // Get the fill in flight (miss detection takes a cycle, then the read).
      for (var i = 0; i < 4; i++) {
        await dut.backing.step();
      }
      expect(
        dut.cache.output('mem_en').value.toBool(),
        isTrue,
        reason: 'no fill was in flight, so the test window was wrong',
      );

      dut['flush'].inject(1);
      dut['req_valid'].inject(0);
      await dut.backing.step();
      dut['flush'].inject(0);

      // Let the abandoned read land and the drain clear.
      for (var i = 0; i < 30; i++) {
        await dut.backing.step();
      }
      final afterAbandon = dut.backing.reads;

      dut.backing.mem[addrA] = dataA2;
      final got = await load(dut, addrA);
      final reads = dut.backing.reads;
      await Simulator.endSimulation();

      expect(
        reads,
        greaterThan(afterAbandon),
        reason:
            'STALE LINE: the abandoned in-flight fill validated its '
            'line across the flush, so the next load hit it',
      );
      expect(
        got,
        equals(dataA2),
        reason: 'the load after the flush returned the OLD data',
      );
    });

    /// Same, with the pulse aligned on EVERY cycle of the fill including the
    /// completion cycle. The completion cycle is the interesting one: the
    /// flush arm and the fill-commit arm both want the valid bit that cycle.
    for (var offset = 0; offset <= 10; offset++) {
      test(
        'a fill flushed at offset $offset does not leave a valid line',
        () async {
          final dut = await makeDut(latency: 6);
          dut.backing.mem[addrA] = dataA;

          dut['req_addr'].inject(addrA);
          dut['req_write'].inject(0);
          dut['req_size'].inject(3);
          dut['req_valid'].inject(1);
          for (var cycle = 0; cycle < offset; cycle++) {
            await dut.backing.step();
          }
          dut['flush'].inject(1);
          dut['req_valid'].inject(0);
          await dut.backing.step();
          dut['flush'].inject(0);

          for (var i = 0; i < 40; i++) {
            await dut.backing.step();
          }
          final before = dut.backing.reads;

          dut.backing.mem[addrA] = dataA2;
          final got = await load(dut, addrA);
          final reads = dut.backing.reads;
          await Simulator.endSimulation();

          expect(
            reads,
            greaterThan(before),
            reason:
                'STALE LINE: a fill flushed at offset $offset still left '
                'a valid line behind',
          );
          expect(got, equals(dataA2), reason: 'stale data at offset $offset');
        },
      );
    }

    /// A different line filling at the pulse must not shield an OLDER line
    /// from the flush. Line 0 (addrA) is resident, line 1 (addrB) is filling.
    test(
      'a resident line is dropped even while another line is filling',
      () async {
        final dut = await makeDut(latency: 8);
        dut.backing.mem[addrA] = dataA;
        dut.backing.mem[addrB] = dataB;

        expect(await load(dut, addrA), equals(dataA));
        final afterA = dut.backing.reads;

        dut['req_addr'].inject(addrB);
        dut['req_valid'].inject(1);
        for (var i = 0; i < 4; i++) {
          await dut.backing.step();
        }
        dut['flush'].inject(1);
        dut['req_valid'].inject(0);
        await dut.backing.step();
        dut['flush'].inject(0);
        for (var i = 0; i < 30; i++) {
          await dut.backing.step();
        }

        dut.backing.mem[addrA] = dataA2;
        final got = await load(dut, addrA);
        final reads = dut.backing.reads;
        await Simulator.endSimulation();

        expect(
          reads,
          greaterThan(afterA + 1),
          reason:
              'STALE LINE: line 0 survived a flush that landed while '
              'line 1 was filling',
        );
        expect(got, equals(dataA2), reason: 'stale data from line 0');
      },
    );

    /// A store must drop the line at its INDEX, whatever tag that line holds.
    ///
    /// The cache is virtually tagged, so two virtual addresses for one physical
    /// word carry different tags. Every mapping of a frame shares the page
    /// offset, and the index is cut from inside the page offset, so the aliases
    /// of a stored word are all on the ONE line the index picks. Dropping that
    /// line is therefore the only way a virtually tagged cache can keep a hart
    /// seeing its own stores.
    ///
    ///   addrA 0x80001000 -> index (0x80001000 >> 3) & 0x1F = 0, tag 0x800010
    ///   addrC 0x80001100 -> index (0x80001100 >> 3) & 0x1F = 0, tag 0x800011
    ///   addrU 0x10001000 -> index (0x10001000 >> 3) & 0x1F = 0, below
    ///                       cacheableBase
    ///
    /// The system-level repro is river test/mmu/l1_vivt_synonym_store_test.dart.
    const addrC = 0x80001100; // same index as addrA, different tag
    const addrU = 0x10001000; // same index, below cacheableBase

    for (final other in const [addrC, addrU]) {
      final label = other == addrU ? 'uncacheable' : 'cacheable';
      test('a $label store drops the resident line at the same index', () async {
        final dut = await makeDut(latency: 6);
        dut.backing.mem[addrA] = dataA;

        expect(await load(dut, addrA), equals(dataA));
        expect(await load(dut, addrA), equals(dataA));
        final resident = dut.backing.reads;

        // The store names the same physical word through another mapping. The
        // backing memory here is keyed by address, so the value under addrA is
        // changed directly to model what the store did to the shared word.
        dut['req_addr'].inject(other);
        dut['req_data'].inject(dataA2);
        dut['req_size'].inject(3);
        dut['req_write'].inject(1);
        dut['req_valid'].inject(1);
        var acked = false;
        for (var i = 0; i < 100 && !acked; i++) {
          await dut.backing.step();
          acked = dut.respValid;
        }
        expect(acked, isTrue, reason: 'the store never completed');
        dut['req_valid'].inject(0);
        dut['req_write'].inject(0);
        await dut.backing.step();
        dut.backing.mem[addrA] = dataA2;

        final got = await load(dut, addrA);
        final reads = dut.backing.reads;
        await Simulator.endSimulation();

        expect(
          resident,
          equals(1),
          reason: 'the line was never resident, so this proves nothing',
        );
        expect(
          reads,
          greaterThan(resident),
          reason:
              'SYNONYM HOLE: a $label store did not drop the line at its '
              'own index, so a load through another mapping of the stored '
              'word still hit the pre-store value',
        );
        expect(got, equals(dataA2));
      });
    }

    /// A trap changes the privilege, and the privilege IS the D-cache context
    /// tag (core.dart drives `req_ctx` from `mode[1:0]`). A fill samples the
    /// context at its START (`fillTag < fullTagOf(addrQ)` in the idle arm) and
    /// commits it many cycles later, so a trap taken while a fill is in flight
    /// commits a line under a context that is no longer current.
    ///
    /// The safe direction is that the line keeps the context of the REQUESTER
    /// that started the fill. The unsafe one is that it takes the new context,
    /// because then the trap handler would hit a line whose data was fetched
    /// under the interrupted mode's translation with no permission check.
    test('a fill keeps the context of the requester that started it', () async {
      final dut = await makeDut(latency: 8, ctxBits: 2);
      dut.backing.mem[addrA] = dataA;

      // Supervisor (context 1) starts the fill.
      dut['req_ctx'].inject(1);
      dut['req_addr'].inject(addrA);
      dut['req_write'].inject(0);
      dut['req_size'].inject(3);
      dut['req_valid'].inject(1);
      for (var i = 0; i < 4; i++) {
        await dut.backing.step();
      }
      expect(
        dut.cache.output('mem_en').value.toBool(),
        isTrue,
        reason: 'no fill was in flight, so the test window was wrong',
      );

      // A trap lands mid-fill: the load is abandoned and the privilege becomes
      // machine (context 3). The request drops with it, so nothing legitimately
      // re-allocates the line under the new context.
      dut['req_ctx'].inject(3);
      dut['req_valid'].inject(0);
      for (var i = 0; i < 30; i++) {
        await dut.backing.step();
      }

      // Control: back in supervisor the line must be resident, otherwise the
      // abandoned fill never committed and the check below proves nothing.
      dut['req_ctx'].inject(1);
      final beforeSupervisor = dut.backing.reads;
      final supervisorGot = await load(dut, addrA);
      final afterSupervisor = dut.backing.reads;

      // Machine mode asks for the same address. It must NOT be served from the
      // line, so it must reach memory.
      dut.backing.mem[addrA] = dataA2;
      dut['req_ctx'].inject(3);
      final machineGot = await load(dut, addrA);
      final afterMachine = dut.backing.reads;
      await Simulator.endSimulation();

      expect(
        afterSupervisor,
        equals(beforeSupervisor),
        reason:
            'the abandoned fill left no resident line, so the context '
            'check below proves nothing',
      );
      expect(
        supervisorGot,
        equals(dataA),
        reason: 'the resident line held the wrong data',
      );
      expect(
        afterMachine,
        greaterThan(afterSupervisor),
        reason:
            'CONTEXT LEAK: a machine-mode load hit a line that a '
            'supervisor-mode fill allocated, with no permission check',
      );
      expect(
        machineGot,
        equals(dataA2),
        reason: 'the machine-mode load returned the supervisor line data',
      );
    });

    /// A faulting memory response landing on the SAME cycle as the flush must
    /// not wedge the cache. The D-cache arms its drain on `~mem_done`, so the
    /// completion that already arrived is not waited for a second time.
    test(
      'a faulting response on the flush cycle does not wedge the cache',
      () async {
        final dut = await makeDut(latency: 6);
        dut.backing.mem[addrA] = dataA;
        dut.backing.faultResponse = true;

        dut['req_addr'].inject(addrA);
        dut['req_write'].inject(0);
        dut['req_size'].inject(3);
        dut['req_valid'].inject(1);

        // Step until the cycle whose response is the fault, then raise the flush
        // so the cache samples both at the same edge.
        var aligned = false;
        for (var i = 0; i < 40 && !aligned; i++) {
          await dut.backing.step();
          if (dut['mem_done'].value.toBool()) aligned = true;
        }
        expect(aligned, isTrue, reason: 'the faulting response never came');
        dut['flush'].inject(1);
        dut['req_valid'].inject(0);
        await dut.backing.step();
        dut['flush'].inject(0);

        dut.backing.faultResponse = false;
        for (var i = 0; i < 20; i++) {
          await dut.backing.step();
        }

        final got = await load(dut, addrA, guardCycles: 400);
        await Simulator.endSimulation();
        expect(
          got,
          equals(dataA),
          reason:
              'the cache never served a load after a fault coincident '
              'with a flush',
        );
      },
    );
  });

  group('HarborL1ICache flush', () {
    /// Test bench for the I-cache: an MMU-faithful single-outstanding memory
    /// that latches a read at launch and answers [latency] cycles later even if
    /// `mem_en` drops. Mirrors l1i_flush_fill_test.dart.
    Future<
      ({
        HarborL1ICache cache,
        Logic reqAddr,
        Logic reqValid,
        Logic flush,
        Logic memDone,
        Map<int, BigInt> mem,
        List<int> reads,
        Future<void> Function() step,
        void Function(bool) setFault,
      })
    >
    makeICache({int latency = 6}) async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final reqAddr = Logic(name: 'req_addr', width: 64);
      final reqValid = Logic(name: 'req_valid');
      final flush = Logic(name: 'flush');
      final memDone = Logic(name: 'mem_done');
      final memValid = Logic(name: 'mem_valid');
      final memFault = Logic(name: 'mem_fault');
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
      cache.port('mem_fault').getsLogic(memFault);
      cache.port('mem_rdata').getsLogic(memRdata);
      await cache.build();

      reset.inject(1);
      reqValid.inject(0);
      reqAddr.inject(0);
      flush.inject(0);
      memDone.inject(0);
      memValid.inject(0);
      memFault.inject(0);
      memRdata.inject(0);
      unawaited(Simulator.run());

      final memEn = cache.output('mem_en');
      final memAddr = cache.output('mem_addr');
      final mem = <int, BigInt>{};
      final reads = <int>[];
      var fault = false;
      var active = false;
      var countdown = 0;
      var latched = 0;
      var cooldown = 0;

      Future<void> step() async {
        await clk.nextPosedge;
        var doneNow = false;
        if (active) {
          countdown--;
          if (countdown <= 0) {
            doneNow = true;
            active = false;
            cooldown = 1;
          }
        } else if (cooldown > 0) {
          cooldown--;
        } else if (memEn.value.toBool()) {
          latched = memAddr.value.toInt() & ~7;
          countdown = latency;
          active = true;
        }
        if (doneNow) {
          if (fault) {
            memDone.inject(1);
            memValid.inject(0);
            memFault.inject(1);
          } else {
            reads.add(latched);
            memRdata.inject(mem[latched] ?? BigInt.zero);
            memDone.inject(1);
            memValid.inject(1);
            memFault.inject(0);
          }
        } else {
          memDone.inject(0);
          memValid.inject(0);
          memFault.inject(0);
        }
      }

      await step();
      reset.inject(0);
      await step();
      return (
        cache: cache,
        reqAddr: reqAddr,
        reqValid: reqValid,
        flush: flush,
        memDone: memDone,
        mem: mem,
        reads: reads,
        step: step,
        setFault: (f) => fault = f,
      );
    }

    test(
      'a resident line does not answer a fetch issued after the pulse',
      () async {
        final d = await makeICache();
        d.mem[addrA] = dataA;

        Future<BigInt> fetch(int addr) async {
          d.reqAddr.inject(addr);
          d.reqValid.inject(1);
          BigInt? got;
          for (var i = 0; i < 200 && got == null; i++) {
            await d.step();
            if (d.cache.output('resp_valid').value.toBool()) {
              got = d.cache.output('resp_data').value.toBigInt();
            }
          }
          expect(got, isNotNull, reason: 'fetch never completed');
          d.reqValid.inject(0);
          await d.step();
          return got!;
        }

        expect(await fetch(addrA), equals(dataA));
        expect(d.reads.length, equals(1));
        expect(await fetch(addrA), equals(dataA));
        final residentReads = d.reads.length;

        d.mem[addrA] = dataA2;
        d.flush.inject(1);
        await d.step();
        d.flush.inject(0);
        await d.step();

        final got = await fetch(addrA);
        final reads = d.reads.length;
        await Simulator.endSimulation();

        expect(
          residentReads,
          equals(1),
          reason: 'the line was never resident, so this proves nothing',
        );
        expect(
          reads,
          equals(2),
          reason: 'STALE LINE: the fetch after the flush hit the old line',
        );
        expect(
          got,
          equals(dataA2),
          reason:
              'STALE DATA: the fetch after the flush ran the OLD address '
              'space instructions',
        );
      },
    );

    /// A flush at EVERY offset of a refill, with the refill answering with a
    /// page fault, must leave the cache able to fill again.
    ///
    /// The I-cache arms its drain when a memory op is still outstanding at the
    /// flush, and it CLEARS the drain on `mem_done` alone. The arm condition
    /// used to be `~(mem_done & mem_valid)`. A page fault answers with
    /// `mem_done` HIGH and `mem_valid` LOW, so a fault that landed on the same
    /// cycle as the flush armed a drain that was already satisfied. No second
    /// response ever came, the drain never cleared, and the cache blocked every
    /// future fill: the core stopped fetching for good.
    ///
    /// Linux reaches this every time a demand-paging fetch fault meets the
    /// `satp` write of a context switch, an `sfence.vma` or a `fence.i`. Only
    /// one offset in the sweep hits it, which is why a single-alignment test
    /// misses it.
    for (var offset = 0; offset < 16; offset++) {
      test('a faulting refill flushed at offset $offset does not wedge the '
          'cache', () async {
        final d = await makeICache();
        d.mem[addrA] = dataA;
        d.setFault(true);

        d.reqAddr.inject(addrA);
        d.reqValid.inject(1);
        for (var t = 0; t < 20; t++) {
          d.flush.inject(t == offset ? 1 : 0);
          if (t == offset) d.reqValid.inject(0);
          await d.step();
        }
        d.flush.inject(0);

        // The pipeline trapped, mapped the page and re-fetches. This must work.
        d.setFault(false);
        for (var i = 0; i < 10; i++) {
          await d.step();
        }
        d.reqAddr.inject(addrA);
        d.reqValid.inject(1);
        BigInt? got;
        for (var i = 0; i < 120 && got == null; i++) {
          await d.step();
          if (d.cache.output('resp_valid').value.toBool()) {
            got = d.cache.output('resp_data').value.toBigInt();
          }
        }
        final reads = List.of(d.reads);
        await Simulator.endSimulation();

        expect(
          got,
          isNotNull,
          reason:
              'WEDGED: the I-cache never filled again after a fetch page '
              'fault landed with a flush at offset $offset. Memory reads: '
              '$reads',
        );
        expect(got, equals(dataA));
      });
    }
  });
}
