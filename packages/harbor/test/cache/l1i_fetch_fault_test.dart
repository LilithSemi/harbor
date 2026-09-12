import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// The icache must propagate a fetch page fault. When a refill returns
/// `mem_done & ~mem_valid` with `mem_fault` set (the MMU walk faulted), the fill
/// FSM must abort (never mark the line valid) and raise `resp_fault` for the held
/// request instead of stalling the fill forever. A subsequent request to a
/// different, mapped line must still fill and hit normally.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('l1i: a faulting refill raises resp_fault, does not hang', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final reqAddr = Logic(name: 'req_addr', width: 64);
    final reqValid = Logic(name: 'req_valid');
    final flush = Logic(name: 'flush');
    final memDone = Logic(name: 'mem_done');
    final memValid = Logic(name: 'mem_valid');
    final memFault = Logic(name: 'mem_fault');
    final memRdata = Logic(name: 'mem_rdata', width: 64);

    const faultAddr = 0x80008000; // the fetch that will page-fault
    const okAddr = 0x80000040; // a later, mapped line
    final okData = BigInt.parse('CCCCCCCCCCCCCCCC', radix: 16);

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
    final respValid = cache.output('resp_valid');
    final respFault = cache.output('resp_fault');

    // MMU-faithful delayed memory: one outstanding read, latched at launch,
    // completes `latency` cycles later. A read of `faultAddr` completes as a
    // page fault (done, not valid, fault); any other address returns data.
    const latency = 6;
    var active = false;
    var countdown = 0;
    var latchedAddr = 0;
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
        latchedAddr = memAddr.value.toInt() & ~7;
        countdown = latency;
        active = true;
      }
      if (doneNow) {
        final isFault = latchedAddr == faultAddr;
        memRdata.inject(isFault ? BigInt.zero : okData);
        memDone.inject(1);
        memValid.inject(isFault ? 0 : 1);
        memFault.inject(isFault ? 1 : 0);
      } else {
        memDone.inject(0);
        memValid.inject(0);
        memFault.inject(0);
      }
    }

    await step();
    reset.inject(0);
    await step();

    // Fetch the faulting address: the cache misses, fills, the MMU faults.
    reqValid.inject(1);
    reqAddr.inject(faultAddr);

    var sawFault = false;
    for (var i = 0; i < 60 && !sawFault; i++) {
      await step();
      if (respFault.value.toBool()) {
        sawFault = true;
        expect(
          respValid.value.toBool(),
          isFalse,
          reason: 'resp_valid must stay low on a fault',
        );
      }
    }
    expect(sawFault, isTrue, reason: 'icache never raised resp_fault (hung)');

    // The pipeline traps and redirects to a mapped line. resp_fault must drop and
    // the new line must fill and hit.
    reqAddr.inject(okAddr);
    BigInt? got;
    for (var i = 0; i < 60 && got == null; i++) {
      await step();
      if (respValid.value.toBool())
        got = cache.output('resp_data').value.toBigInt();
    }
    expect(
      got,
      equals(okData),
      reason: 'cache did not recover after the fault',
    );
    expect(
      respFault.value.toBool(),
      isFalse,
      reason: 'resp_fault stuck after retarget',
    );

    await Simulator.endSimulation();
  });
}
