import 'dart:async';
import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../../util/pcie_dma_bench.dart';

void main() {
  tearDown(Simulator.reset);
  for (final interval in [0, 256]) {
    test('held cause, repeated ack, interval=$interval', () async {
      final b = await DmaBench.create(const DmaConfig(irqLines: 1));
      final irq = HarborPcieInterrupt(
        clk: b.clk,
        reset: b.reset,
        irqPending: b.dut.output('irq_pending'),
        txBusy: Const(0),
        msiEnable: b.msiEnable,
        mmEnable: b.granted,
        busMasterEnable: b.busMaster,
        interruptDisable: Const(1),
        interruptRdyN: Const(0),
        minMsiCycles: interval,
      );
      await irq.build();
      final times = <int>[];
      var monitor = true;
      Future<void> watch() async {
        while (monitor) {
          await b.clk.nextNegedge;
          if (irq.interruptN.value.isValid &&
              irq.interruptN.value.toInt() == 0) {
            times.add(Simulator.time);
          }
        }
      }

      unawaited(watch());
      await b.start();
      await b.setupRing(dmaCplBase, 4);
      b.msiEnable.inject(1);
      b.granted.inject(0);
      await b.enable(mask: 1 << HarborPcieDma.causeLineShift);
      b.lines!.inject(1);
      await b.cycles(20);
      expect(times.length, 1);
      for (var i = 0; i < 32; i++) {
        await b.readReg(HarborPcieDma.registerIrqCause);
        await b.writeReg(
          HarborPcieDma.registerIrqCause,
          1 << HarborPcieDma.causeLineShift,
        );
      }
      await b.cycles(1024);
      if (interval > 0) {
        // The cause stays high through all acks, so a later MSI must come.
        expect(times.length, greaterThan(1));
        for (var i = 1; i < times.length; i++) {
          expect(times[i] - times[i - 1], greaterThanOrEqualTo(interval * 10));
        }
      } else {
        expect(times.length, 33);
      }
      final count = times.length;
      await b.cycles(1024);
      expect(times.length, count);
      await b.writeReg(HarborPcieDma.registerIrqMask, 0);
      await b.cycles(1024);
      expect(times.length, count);
      monitor = false;
      await b.finish();
    });
  }
}
