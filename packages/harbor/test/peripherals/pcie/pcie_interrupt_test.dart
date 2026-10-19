import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Answers cfg_interrupt like the hard block, after a random delay.
class _HardBlockStub {
  final Logic clk;
  final HarborPcieInterrupt dut;
  final Logic rdyN;
  final Logic msiEnable;
  final Logic mmEnable;
  final Logic busMaster;
  final Random random;
  final msis = <int>[];
  final msiTimes = <int>[];
  final intx = <bool>[];
  final violations = <String>[];
  var requestCycles = 0;
  var _running = true;

  _HardBlockStub(
    this.clk,
    this.dut,
    this.rdyN,
    this.msiEnable,
    this.mmEnable,
    this.busMaster,
    int seed,
  ) : random = Random(seed);

  Future<void> run() async {
    int? delay;
    var heldDi = 0;
    var heldAssert = false;
    var heldMsi = false;
    while (_running) {
      await clk.nextNegedge;
      if (rdyN.value.toInt() == 0) {
        rdyN.inject(1);
        continue;
      }
      if (dut.interruptN.value.toInt() != 0) {
        if (delay != null) violations.add('request dropped without RDYN');
        delay = null;
        continue;
      }
      requestCycles++;
      final di = dut.interruptDi.value.toInt();
      final assertMessage = dut.interruptAssertN.value.toInt() == 0;
      if (delay == null) {
        delay = random.nextInt(5);
        heldDi = di;
        heldAssert = assertMessage;
        heldMsi = msiEnable.value.toInt() != 0;
        if (heldMsi && busMaster.value.toInt() == 0) {
          violations.add('MSI without BME');
        }
      } else if (di != heldDi || assertMessage != heldAssert) {
        violations.add('request changed while held');
      }
      if (delay > 0) {
        delay--;
        continue;
      }
      delay = null;
      rdyN.inject(0);
      if (heldMsi) {
        if (di >= 1 << min(mmEnable.value.toInt(), 3)) {
          violations.add('MSI vector $di above the granted count');
        }
        msis.add(di);
        msiTimes.add(Simulator.time);
      } else {
        intx.add(assertMessage);
      }
    }
  }

  void stop() => _running = false;
}

class _Bench {
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final irq = Logic(name: 'irq', width: 8);
  final txBusy = Logic(name: 'tx_busy');
  final msiEnable = Logic(name: 'msi_enable');
  final mmEnable = Logic(name: 'mm_enable', width: 3);
  final busMaster = Logic(name: 'bme');
  final intDisable = Logic(name: 'int_disable');
  final rdyN = Logic(name: 'rdy_n');
  late final HarborPcieInterrupt dut;
  late final _HardBlockStub stub;

  Future<void> start({
    bool msi = true,
    int mm = 3,
    bool bme = true,
    int seed = 1,
  }) async {
    dut = HarborPcieInterrupt(
      clk: clk,
      reset: reset,
      irqPending: irq,
      txBusy: txBusy,
      msiEnable: msiEnable,
      mmEnable: mmEnable,
      busMasterEnable: busMaster,
      interruptDisable: intDisable,
      interruptRdyN: rdyN,
    );
    await dut.build();
    reset.inject(1);
    irq.inject(0);
    txBusy.inject(0);
    msiEnable.inject(msi ? 1 : 0);
    mmEnable.inject(mm);
    busMaster.inject(bme ? 1 : 0);
    intDisable.inject(0);
    rdyN.inject(1);
    stub = _HardBlockStub(clk, dut, rdyN, msiEnable, mmEnable, busMaster, seed);
    Simulator.setMaxSimTime(1000000);
    unawaited(Simulator.run());
    await idle(3);
    await clk.nextNegedge;
    reset.inject(0);
    unawaited(stub.run());
  }

  Future<void> idle(int cycles) async {
    for (var i = 0; i < cycles; i++) {
      await clk.nextPosedge;
    }
  }

  Future<void> set(Logic signal, int value) async {
    await clk.nextNegedge;
    signal.inject(value);
  }

  Future<void> finish() async {
    stub.stop();
    await idle(2);
    await Simulator.endSimulation();
    expect(stub.violations, isEmpty);
  }
}

void main() {
  tearDown(Simulator.reset);

  test('sends the lowest pending vector first with 8 granted', () async {
    final bench = _Bench();
    await bench.start();
    await bench.set(bench.irq, 0xa4);
    await bench.idle(40);
    expect(bench.stub.msis, [2, 5, 7]);
    await bench.finish();
  });

  test('maps vectors above the granted count to vector 0', () async {
    final bench = _Bench();
    await bench.start(mm: 0);
    await bench.set(bench.irq, 0x49);
    await bench.idle(40);
    expect(bench.stub.msis, [0]);
    await bench.set(bench.irq, 0);
    await bench.set(bench.mmEnable, 2);
    await bench.set(bench.irq, 0x42);
    await bench.idle(40);
    expect(bench.stub.msis, [0, 1, 0]);
    await bench.finish();
  });

  test('sends one MSI per rising edge', () async {
    final bench = _Bench();
    await bench.start(seed: 3);
    await bench.set(bench.irq, 0x02);
    await bench.idle(60);
    expect(bench.stub.msis, [1]);
    await bench.set(bench.irq, 0);
    await bench.idle(5);
    expect(bench.stub.msis, [1]);
    await bench.set(bench.irq, 0x02);
    await bench.idle(20);
    expect(bench.stub.msis, [1, 1]);
    await bench.finish();
  });

  test('keeps an edge that comes while its vector is in flight', () async {
    final bench = _Bench();
    await bench.start(seed: 4);
    await bench.set(bench.irq, 0x08);
    await bench.idle(1);
    await bench.set(bench.irq, 0);
    await bench.set(bench.irq, 0x08);
    await bench.idle(40);
    expect(bench.stub.msis, [3, 3]);
    await bench.finish();
  });

  test('holds the request while the TX stream is busy', () async {
    final bench = _Bench();
    await bench.start();
    await bench.set(bench.txBusy, 1);
    await bench.set(bench.irq, 0x01);
    await bench.idle(30);
    expect(bench.stub.requestCycles, 0);
    expect(bench.stub.msis, isEmpty);
    await bench.set(bench.txBusy, 0);
    await bench.idle(20);
    expect(bench.stub.msis, [0]);
    await bench.finish();
  });

  test('holds MSI until bus master enable', () async {
    final bench = _Bench();
    await bench.start(bme: false);
    await bench.set(bench.irq, 0x30);
    await bench.idle(30);
    expect(bench.stub.requestCycles, 0);
    await bench.set(bench.busMaster, 1);
    await bench.idle(30);
    expect(bench.stub.msis, [4, 5]);
    await bench.finish();
  });

  test('asserts INTA while any bit is set', () async {
    final bench = _Bench();
    await bench.start(msi: false);
    await bench.set(bench.irq, 0x08);
    await bench.idle(20);
    expect(bench.stub.intx, [true]);
    await bench.set(bench.irq, 0x18);
    await bench.idle(10);
    await bench.set(bench.irq, 0x10);
    await bench.idle(10);
    expect(bench.stub.intx, [true]);
    await bench.set(bench.irq, 0);
    await bench.idle(20);
    expect(bench.stub.intx, [true, false]);
    expect(bench.stub.msis, isEmpty);
    await bench.finish();
  });

  test('sends no INTx while interrupts are disabled', () async {
    final bench = _Bench();
    await bench.start(msi: false);
    await bench.set(bench.intDisable, 1);
    await bench.set(bench.irq, 0x01);
    await bench.idle(30);
    expect(bench.stub.requestCycles, 0);
    await bench.set(bench.intDisable, 0);
    await bench.idle(20);
    expect(bench.stub.intx, [true]);
    await bench.finish();
  });

  test('sends one MSI per edge under random traffic', () async {
    final bench = _Bench();
    await bench.start(seed: 7);
    final random = Random(11);
    final expected = List.filled(8, 0);
    var level = 0;
    for (var i = 0; i < 200; i++) {
      final next = random.nextInt(256);
      final rising = next & ~level;
      for (var bit = 0; bit < 8; bit++) {
        if (rising & (1 << bit) != 0) expected[bit]++;
      }
      level = next;
      await bench.set(bench.irq, level);
      await bench.set(bench.txBusy, random.nextInt(4) == 0 ? 1 : 0);
      await bench.idle(20);
      await bench.set(bench.txBusy, 0);
      await bench.idle(80);
    }
    final counts = List.filled(8, 0);
    for (final v in bench.stub.msis) {
      counts[v]++;
    }
    expect(counts, expected);
    await bench.finish();
  });

  test('sends Deassert_INTA when Interrupt Disable sets', () async {
    final bench = _Bench();
    await bench.start(msi: false);
    await bench.set(bench.irq, 0x01);
    await bench.idle(20);
    expect(bench.stub.intx, [true]);
    await bench.set(bench.intDisable, 1);
    await bench.idle(20);
    await bench.set(bench.irq, 0);
    await bench.idle(20);
    expect(bench.stub.intx, [true, false]);
    await bench.set(bench.intDisable, 0);
    await bench.idle(20);
    expect(bench.stub.intx, [true, false]);
    await bench.finish();
  });

  test('completes a held MSI once when bus master enable drops', () async {
    final bench = _Bench();
    await bench.start(seed: 5);
    await bench.set(bench.irq, 0x04);
    while (bench.dut.interruptN.value.toInt() != 0) {
      await bench.clk.nextNegedge;
    }
    bench.busMaster.inject(0);
    await bench.idle(30);
    expect(bench.stub.msis, [2]);
    await bench.set(bench.busMaster, 1);
    await bench.idle(30);
    expect(bench.stub.msis, [2]);
    await bench.finish();
  });

  test('sends one MSI when MSI turns on with a level high', () async {
    final bench = _Bench();
    await bench.start(msi: false);
    await bench.set(bench.irq, 0x04);
    await bench.idle(20);
    expect(bench.stub.intx, [true]);
    await bench.set(bench.msiEnable, 1);
    await bench.idle(30);
    expect(bench.stub.msis, [2]);
    expect(bench.stub.intx, [true]);
    await bench.set(bench.msiEnable, 0);
    await bench.idle(20);
    expect(bench.stub.intx, [true, true]);
    await bench.finish();
  });

  for (final msi in [true, false]) {
    test('follows fast random levels with ${msi ? 'MSI' : 'INTx'}', () async {
      final bench = _Bench();
      await bench.start(msi: msi, seed: 9);
      final random = Random(13);
      final edges = List.filled(8, 0);
      final lastEdge = List.filled(8, -1);
      var level = 0;
      for (var i = 0; i < 400; i++) {
        final next = i == 399 ? 0 : random.nextInt(256);
        await bench.clk.nextNegedge;
        for (var bit = 0; bit < 8; bit++) {
          if (next & ~level & (1 << bit) != 0) {
            edges[bit]++;
            lastEdge[bit] = Simulator.time;
          }
        }
        level = next;
        bench.irq.inject(level);
        bench.txBusy.inject(random.nextInt(4) == 0 ? 1 : 0);
        await bench.idle(random.nextInt(6));
      }
      await bench.set(bench.txBusy, 0);
      await bench.idle(100);
      if (msi) {
        for (var bit = 0; bit < 8; bit++) {
          final times = [
            for (var j = 0; j < bench.stub.msis.length; j++)
              if (bench.stub.msis[j] == bit) bench.stub.msiTimes[j],
          ];
          expect(times.length, lessThanOrEqualTo(edges[bit]));
          if (edges[bit] > 0) {
            expect(times, isNotEmpty);
            expect(times.last, greaterThan(lastEdge[bit]));
          }
        }
      } else {
        final intx = bench.stub.intx;
        expect(intx, isNotEmpty);
        for (var j = 0; j < intx.length; j++) {
          expect(intx[j], j.isEven);
        }
        expect(intx.last, isFalse);
      }
      await bench.finish();
    });
  }
}
