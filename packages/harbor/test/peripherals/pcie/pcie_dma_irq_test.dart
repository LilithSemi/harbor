import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/pcie_dma_bench.dart';
import '../../util/pcie_host_model.dart';

const _line = 1 << HarborPcieDma.causeLineShift;

Logic _signal(DmaBench b, String name) =>
    b.dut.signals.firstWhere((s) => s.name == name);

/// Starts a bench with one SoC line, all causes on and 8 vectors granted.
Future<DmaBench> _start() async {
  final b = await DmaBench.create(const DmaConfig(irqLines: 1));
  await b.start();
  await b.setupRing(dmaCplBase, 4);
  await b.enable(
    mask: HarborPcieDma.causeDone | HarborPcieDma.causeError | _line,
  );
  b.msiEnable.inject(1);
  b.granted.inject(3);
  return b;
}

/// A one cycle pulse on the line, set at the falling edge before the rising
/// edge that samples it.
Future<void> _pulse(DmaBench b) async {
  b.lines!.inject(1);
  await b.clk.nextPosedge;
  b.lines!.inject(0);
}

/// Waits for the falling edge of the cycle where [name] is high.
Future<void> _waitHigh(DmaBench b, String name, {Logic? and}) async {
  final s = _signal(b, name);
  for (var i = 0; i < 2000; i++) {
    await b.clk.nextNegedge;
    if (s.value.isValid &&
        s.value.toBool() &&
        (and == null || (and.value.isValid && and.value.toBool()))) {
      return;
    }
  }
  fail('$name never high');
}

void main() {
  tearDown(Simulator.reset);

  test('a line event in the IRQ_CAUSE read cycle stays fresh', () async {
    final b = await _start();
    // The read is sent, and the line pulses in its gather cycle.
    final read = b.readRaw(HarborPcieDma.registerIrqCause, 1);
    await _waitHigh(b, 'irq_cause_read');
    await _pulse(b);
    final c = await read;
    expect(DmaRecord.le(c.data, 0), 0, reason: 'the read misses the event');
    // The handler clears what it read and more, but not the new event.
    await b.writeReg(HarborPcieDma.registerIrqCause, 0xffffffff);
    await b.cycles(4);
    expect(await b.readReg(HarborPcieDma.registerIrqCause), _line);
    expect(b.irqPending & 2, 2);
    // After a read that saw it, the clear works.
    await b.writeReg(HarborPcieDma.registerIrqCause, _line);
    await b.cycles(4);
    expect(await b.readReg(HarborPcieDma.registerIrqCause), 0);
    await b.finish();
  });

  test('a line event in the W1C cycle stays set and sends again', () async {
    final b = await _start();
    await _pulse(b);
    await b.cycles(4);
    expect(await b.readReg(HarborPcieDma.registerIrqCause), _line);
    // The W1C and a new event land in the same cycle.
    final write = b.writeReg(HarborPcieDma.registerIrqCause, _line);
    await _waitHigh(
      b,
      'reg_w_en',
      and: _signal(b, 'reg_w_addr').eq(HarborPcieDma.registerIrqCause ~/ 4),
    );
    await _pulse(b);
    await write;
    // irq_pending vector 1 dips for one cycle, then rises again.
    final seen = <int>[];
    for (var i = 0; i < 6; i++) {
      seen.add(b.irqPending & 2);
      await b.clk.nextPosedge;
    }
    expect(seen.last, 2);
    expect(await b.readReg(HarborPcieDma.registerIrqCause), _line);
    await b.finish();
  });

  test('a zero length read of IRQ_CAUSE does not count as a read', () async {
    final b = await _start();
    await _pulse(b);
    await b.cycles(4);
    final before = b.host.completions.length;
    await b.send(
      PcieTlp.memRead(
        address: dmaBar0 + HarborPcieDma.registerIrqCause,
        lengthDw: 1,
        firstBe: 0,
        tag: 0x55,
      ),
    );
    await b.waitUntil(
      () => b.host.completions.length > before,
      what: 'zero length read',
    );
    await b.writeReg(HarborPcieDma.registerIrqCause, _line);
    await b.cycles(4);
    expect(await b.readReg(HarborPcieDma.registerIrqCause), _line);
    await b.writeReg(HarborPcieDma.registerIrqCause, _line);
    await b.cycles(4);
    expect(await b.readReg(HarborPcieDma.registerIrqCause), 0);
    await b.finish();
  });

  test('a partial IRQ_CAUSE read clears fresh only in its bytes', () async {
    final b = await _start();
    Future<PcieTlp> read(
      int address,
      int lengthDw,
      int firstBe,
      int lastBe,
    ) async {
      final before = b.host.completions.length;
      await b.send(
        PcieTlp.memRead(
          address: dmaBar0 + address,
          lengthDw: lengthDw,
          firstBe: firstBe,
          lastBe: lastBe,
          tag: 0x56,
        ),
      );
      await b.waitUntil(
        () => b.host.completions.length > before,
        what: 'partial read',
      );
      return b.host.completions.last;
    }

    Future<int> clearLine() async {
      await b.writeReg(HarborPcieDma.registerIrqCause, _line);
      await b.cycles(4);
      return b.readReg(HarborPcieDma.registerIrqCause);
    }

    await _pulse(b);
    await b.cycles(4);
    // The line bit is in byte 1. A read of byte 0 does not see it.
    await read(HarborPcieDma.registerIrqCause, 1, 0x1, 0);
    expect(await clearLine(), _line, reason: 'byte 1 was not read');
    // The full read in clearLine read byte 1, so this W1C clears it.
    expect(await clearLine(), 0);

    // A 2 DW read from STATUS that reads only byte 0 of IRQ_CAUSE.
    await _pulse(b);
    await b.cycles(4);
    await read(HarborPcieDma.registerStatus, 2, 0xf, 0x1);
    await b.writeReg(HarborPcieDma.registerIrqCause, _line);
    await b.cycles(4);
    // Byte 1 was not read, so the W1C did not clear the line bit.
    final c = await read(HarborPcieDma.registerIrqCause, 1, 0x2, 0);
    expect(DmaRecord.le(c.data, 0) & _line, _line);
    await b.writeReg(HarborPcieDma.registerIrqCause, _line);
    await b.cycles(4);
    expect(await b.readReg(HarborPcieDma.registerIrqCause), 0);
    await b.finish();
  });

  test('engine reset clears the fresh bits', () async {
    final b = await _start();
    await _pulse(b);
    await b.cycles(4);
    await b.engineReset();
    await b.cycles(10);
    await b.writeReg(HarborPcieDma.registerIrqCause, _line);
    await b.cycles(4);
    expect(await b.readReg(HarborPcieDma.registerIrqCause), 0);
    await b.finish();
  });

  test('a W1C of a line bit does not drop vector 0', () async {
    final b = await _start();
    await b.push(
      hostAddress: 0x80000000,
      localAddress: 0,
      length: 4,
      irq: true,
    );
    await b.waitRecordWrites(0, 1);
    b.lines!.inject(1);
    await b.cycles(4);
    expect(b.irqPending & 3, 3);
    final write = b.writeReg(HarborPcieDma.registerIrqCause, _line);
    final v0 = <int>[];
    final v1 = <int>[];
    var done = false;
    write.then((_) => done = true);
    while (!done) {
      await b.clk.nextNegedge;
      v0.add(b.irqPending & 1);
      v1.add(b.irqPending & 2);
      await b.clk.nextPosedge;
    }
    for (var i = 0; i < 4; i++) {
      await b.clk.nextNegedge;
      v0.add(b.irqPending & 1);
      v1.add(b.irqPending & 2);
      await b.clk.nextPosedge;
    }
    expect(v0, everyElement(1), reason: 'vector 0 has no gap');
    expect(v1, contains(0), reason: 'vector 1 gets its gap');
    expect(v1.last, 2, reason: 'the line is still high');
    b.lines!.inject(0);
    await b.finish();
  });

  test('with MSI off, IRQ writes give irq_pending no gap', () async {
    final b = await _start();
    b.msiEnable.inject(0);
    b.lines!.inject(1);
    await b.cycles(4);
    expect(b.irqPending & 1, 1);
    final seen = <int>[];
    var done = false;
    Future<void> writes() async {
      await b.writeReg(HarborPcieDma.registerIrqCause, _line);
      await b.writeReg(HarborPcieDma.registerIrqMask, _line);
      await b.cycles(4);
    }

    final write = writes().then((_) => done = true);
    while (!done) {
      await b.clk.nextNegedge;
      seen.add(b.irqPending & 1);
      await b.clk.nextPosedge;
    }
    await write;
    for (var i = 0; i < 4; i++) {
      await b.clk.nextNegedge;
      seen.add(b.irqPending & 1);
      await b.clk.nextPosedge;
    }
    expect(seen, everyElement(1), reason: 'INTx stays asserted');
    b.lines!.inject(0);
    await b.finish();
  });

  test('CPL ring writes are dropped while the engine runs', () async {
    final b = await _start();
    b.seedHost(0x80001000, 0x100);
    b.holdCompletions = true;
    await b.push(
      hostAddress: 0x80001000,
      localAddress: 0x200,
      length: 0x100,
      deviceToHost: false,
      cookie: 9,
    );
    await b.waitUntil(() => b.reads.isNotEmpty, what: 'the H2D read');
    await b.writeReg(HarborPcieDma.registerCplSize, 0);
    await b.writeReg(HarborPcieDma.registerCplBaseLow, 0x12345670);
    expect(await b.readReg(HarborPcieDma.registerCplSize), 4);
    expect(await b.readReg(HarborPcieDma.registerCplBaseLow), dmaCplBase);
    b.holdCompletions = false;
    await b.waitRecordWrites(0, 1);
    expect(b.record(0).cookie, 9);
    expect(b.record(0).code, 0);
    b.checkLocal(0x80001000, 0x200, 0x100);
    // The ring holds a record, so an idle engine still drops the writes.
    await b.cycles(20);
    await b.writeReg(HarborPcieDma.registerCplSize, 5);
    expect(await b.readReg(HarborPcieDma.registerCplSize), 4);
    // After an engine reset, the writes take effect.
    await b.engineReset();
    await b.cycles(10);
    await b.writeReg(HarborPcieDma.registerCplSize, 5);
    expect(await b.readReg(HarborPcieDma.registerCplSize), 5);
    await b.finish();
  });

  test('a CPL_SIZE write to an idle engine with records does not move '
      'the ring', () async {
    final b = await DmaBench.create(const DmaConfig());
    await b.start();
    await b.setupRing(dmaCplBase, 4);
    await b.enable();
    for (var i = 0; i < 6; i++) {
      await b.push(
        hostAddress: 0x80000000 + 0x100 * i,
        localAddress: 0,
        length: 4,
        cookie: i + 1,
      );
    }
    await b.waitRecordWrites(5, 1);
    await b.writeReg(HarborPcieDma.registerCplHead, 6);
    await b.cycles(20);
    // A 4 slot ring would put the next record at slot 6, past its end.
    await b.writeReg(HarborPcieDma.registerCplSize, 2);
    await b.writeReg(HarborPcieDma.registerCplBaseLow, dmaCplBase + 0x1000);
    expect(await b.readReg(HarborPcieDma.registerCplSize), 4);
    expect(await b.readReg(HarborPcieDma.registerCplBaseLow), dmaCplBase);
    await b.push(
      hostAddress: 0x80001000,
      localAddress: 0,
      length: 4,
      cookie: 7,
    );
    await b.waitRecordWrites(6, 1);
    expect(b.record(6).cookie, 7);
    expect(await b.readReg(HarborPcieDma.registerCplTail), 7);
    await b.finish();
  });
}
