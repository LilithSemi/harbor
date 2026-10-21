import 'dart:async';

import 'package:harbor/src/peripherals/pcie/pcie_dma_tags.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Simulator.reset);

  // The engine aborts one cycle after a timeout, because the error is
  // registered. A completion header for the timed out tag in that cycle
  // still hits the slot, and must count as stale, as before the error was
  // registered.
  test(
    'a completion in the abort cycle after a timeout counts as stale',
    () async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final abort = Logic(name: 'abort');
      final cplHeader = Logic(name: 'cpl_header');
      final header = Logic(name: 'header', width: 128);
      final issue = Logic(name: 'issue');
      final tags = HarborPcieDmaTags(
        clk: clk,
        reset: reset,
        abort: abort,
        clearStale: Const(0),
        cplHeader: cplHeader,
        cplSeen: cplHeader,
        header: header,
        firstDw: Const(0, width: 32),
        rxFire: cplHeader,
        rxLast: Const(1),
        rxData: Const(0, width: 64),
        issue: issue,
        issueLen: Const(4, width: 13),
        issueLocal: Const(0, width: 16),
        issueHostLow: Const(0, width: 7),
        drainDone: Const(0),
        reservedBusy: Const(0),
        rdSlot: Logic(width: 3)..put(0),
        rdIndex: Logic(width: 10)..put(0),
        dataWidth: 64,
        addressWidth: 16,
        readTags: 8,
        maxReadRequestBytes: 512,
        timeoutCycles: 40,
      );
      // As in the engine: the registered error aborts.
      abort <= tags.err;
      await tags.build();

      reset.inject(1);
      cplHeader.inject(0);
      header.inject(0);
      issue.inject(0);
      Simulator.setMaxSimTime(100000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      final tag = tags.issueTag.value.toInt();
      issue.inject(1);
      await clk.nextPosedge;
      issue.inject(0);

      // Find the timeout cycle T.
      var cycles = 0;
      while (true) {
        await clk.nextNegedge;
        if (tags.errAhead.value.toBool()) break;
        if (++cycles > 100) fail('no timeout');
        await clk.nextPosedge;
      }
      expect(tags.err.value.toBool(), isFalse);
      await clk.nextPosedge;

      // Cycle T + 1: the error aborts, and the late CplD header arrives.
      final cplD =
          BigInt.from(0x4a000001) |
          BigInt.from(4) << 32 |
          BigInt.from(tag) << 72;
      header.inject(cplD);
      cplHeader.inject(1);
      await clk.nextNegedge;
      expect(tags.err.value.toBool(), isTrue);
      expect(tags.errCode.value.toInt(), HarborPcieDmaTags.codeTimeout);
      expect(abort.value.toBool(), isTrue);
      await clk.nextPosedge;
      cplHeader.inject(0);
      await clk.nextPosedge;
      expect(tags.staleCount.value.toInt(), 1);
      expect(tags.busy.value.toBool(), isFalse);
      await Simulator.endSimulation();
    },
  );
}
