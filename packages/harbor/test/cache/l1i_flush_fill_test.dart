import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Regression for the flush-during-fill corruption (the creek Weir->Ferrite
/// handoff `fence.i` hang): if the icache is flushed while a line fill is in
/// flight to the MMU/DRAM, that abandoned read is NOT cancelled (the MMU latched
/// it at arbitration and runs the wishbone cycle to completion). A new fill
/// re-asserts `mem_en` for a DIFFERENT line, and the abandoned read's completion
/// lands as word 0 of the NEW line, so the fetch reads a stale instruction from
/// the wrong address. It is timing-dependent (whether a fill is in flight at the
/// fence) -> the boot is a coin-flip.
///
/// This models the MMU ifetch port faithfully: a read is LATCHED when it
/// launches and completes `latency` cycles later regardless of `mem_en`
/// dropping, single-outstanding.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test(
    'l1i: flush mid-fill must not capture the abandoned read into a new line',
    () async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final reqAddr = Logic(name: 'req_addr', width: 64);
      final reqValid = Logic(name: 'req_valid');
      final flush = Logic(name: 'flush');
      final memDone = Logic(name: 'mem_done');
      final memValid = Logic(name: 'mem_valid');
      final memRdata = Logic(name: 'mem_rdata', width: 64);

      // Two distinct single-word lines (lineSize 8 = 1 word/line).
      const addrA = 0x80000000;
      const addrB = 0x80000040;
      final dataA = BigInt.parse('AAAAAAAAAAAAAAAA', radix: 16);
      final dataB = BigInt.parse('BBBBBBBBBBBBBBBB', radix: 16);
      final backing = <int, BigInt>{addrA: dataA, addrB: dataB};

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

      reset.inject(1);
      reqValid.inject(0);
      reqAddr.inject(0);
      flush.inject(0);
      memDone.inject(0);
      memValid.inject(0);
      memRdata.inject(0);

      unawaited(Simulator.run());

      final memEn = cache.output('mem_en');
      final memAddr = cache.output('mem_addr');

      // MMU-faithful delayed memory: one outstanding read, latched at launch,
      // completes `latency` cycles later even if mem_en drops meanwhile.
      const latency = 6;
      var active = false;
      var countdown = 0;
      var latchedAddr = 0;
      var cooldown = 0; // one idle cycle after a completion (MMU justCompleted)

      Future<void> step() async {
        await clk.nextPosedge;
        // Default: no completion this cycle.
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
          // Launch a new read for the currently presented address.
          latchedAddr = memAddr.value.toInt() & ~7;
          countdown = latency;
          active = true;
        }
        if (doneNow) {
          memRdata.inject(backing[latchedAddr] ?? BigInt.zero);
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

      // Start fetching A: cache misses and launches the fill for line A.
      reqValid.inject(1);
      reqAddr.inject(addrA);
      // Let the read get in flight (a couple cycles into its latency).
      await step();
      await step();

      // fence.i mid-fill: flush the icache while A's read is still outstanding.
      flush.inject(1);
      await step();
      flush.inject(0);

      // Immediately fetch B (Ferrite's first instruction line).
      reqAddr.inject(addrB);

      // Run until the cache serves B (or give up).
      BigInt? got;
      for (var i = 0; i < 60 && got == null; i++) {
        await step();
        if (cache.output('resp_valid').value.toBool()) {
          got = cache.output('resp_data').value.toBigInt();
        }
      }

      expect(
        got,
        isNotNull,
        reason: 'cache never served B after a flush mid-fill',
      );
      expect(
        got,
        equals(dataB),
        reason: 'line B captured the abandoned A read (flush-during-fill bug)',
      );

      await Simulator.endSimulation();
    },
  );
}
