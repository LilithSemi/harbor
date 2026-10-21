import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/pcie_dma_bench.dart';
import '../util/pcie_gpu_bench.dart';

const _cplBase = 0x90000000;
const _lineCause = 1 << HarborPcieDma.causeLineShift;

/// Starts the bench with a 16 slot completion ring and all causes enabled.
Future<PcieGpuBench> _start(int granted, {int cplLog = 4}) async {
  final b = await PcieGpuBench.create(64, granted: granted);
  await b.start();
  await b.writeReg(HarborPcieDma.registerCplBaseLow, _cplBase);
  await b.writeReg(HarborPcieDma.registerCplBaseHigh, 0);
  await b.writeReg(HarborPcieDma.registerCplSize, cplLog);
  await b.writeReg(
    HarborPcieDma.registerIrqMask,
    HarborPcieDma.causeDone | HarborPcieDma.causeError | _lineCause,
  );
  await b.writeReg(HarborPcieDma.registerControl, HarborPcieDma.controlEnable);
  return b;
}

Future<void> _push(PcieGpuBench b, int cookie) =>
    b.writeRegs(HarborPcieDma.registerPush, [
      0x70000000 + 0x100 * cookie,
      0,
      0x1000,
      0,
      64,
      HarborPcieDma.flagDeviceToHost | HarborPcieDma.flagIrq,
      cookie,
      0,
    ]);

Future<void> _msi(PcieGpuBench b, int count) => b.waitUntil(
  () => b.host.msis.length >= count,
  timeout: 20000,
  what: 'MSI $count',
);

Future<void> _idle(PcieGpuBench b, int cycles) async {
  for (var i = 0; i < cycles; i++) {
    await b.clk.nextPosedge;
  }
}

void main() {
  tearDown(Simulator.reset);

  for (final granted in [3, 0]) {
    final vectors = 1 << granted;
    final lineVector = granted == 0 ? 0 : 1;

    test('each SoC line assertion gives an MSI when the handler clears '
        'while the line is high, $vectors vectors', () async {
      final b = await _start(granted);
      for (var assertion = 0; assertion < 2; assertion++) {
        final before = b.host.msis.length;
        b.irqLine.inject(1);
        await _msi(b, before + 1);
        // The handler clears while the line is still high. The cause is
        // still set, so it sends again.
        var cause = await b.readReg(HarborPcieDma.registerIrqCause);
        expect(cause & _lineCause, _lineCause);
        await b.writeReg(HarborPcieDma.registerIrqCause, cause);
        await _msi(b, before + 2);
        b.irqLine.inject(0);
        await _idle(b, 20);
        cause = await b.readReg(HarborPcieDma.registerIrqCause);
        await b.writeReg(HarborPcieDma.registerIrqCause, cause);
        await _idle(b, 200);
        expect(await b.readReg(HarborPcieDma.registerIrqCause), 0);
        expect(b.host.msis.length, before + 2, reason: 'no MSI after clear');
      }
      expect(b.host.msis, everyElement(lineVector));
      expect(b.violations, isEmpty);
      await b.finish();
    });

    test('a record between the cause read and its clear gives a second '
        'MSI, $vectors vectors', () async {
      final b = await _start(granted);
      await _push(b, 1);
      await _msi(b, 1);
      final cause = await b.readReg(HarborPcieDma.registerIrqCause);
      expect(cause, HarborPcieDma.causeDone);
      // The second record lands after the read and before the clear.
      await _push(b, 2);
      await b.waitUntil(
        () => DmaRecord(b.host.memory.read(_cplBase + 16, 16)).cookie == 2,
        what: 'record 2',
      );
      await _idle(b, 20);
      expect(b.host.msis, hasLength(1));
      await b.writeReg(HarborPcieDma.registerIrqCause, cause);
      await _msi(b, 2);
      final again = await b.readReg(HarborPcieDma.registerIrqCause);
      expect(again, HarborPcieDma.causeDone);
      await b.writeReg(HarborPcieDma.registerIrqCause, again);
      await _idle(b, 200);
      expect(await b.readReg(HarborPcieDma.registerIrqCause), 0);
      expect(b.host.msis, [0, 0]);
      await b.finish();
    });
  }

  test('a completion ring of 1 slot halts with code 5 and no record', () async {
    final b = await _start(3, cplLog: 0);
    await _push(b, 1);
    await _msi(b, 1);
    expect(b.host.msis, [0]);
    final status = await b.readReg(HarborPcieDma.registerStatus);
    expect(status & HarborPcieDma.statusHalted, HarborPcieDma.statusHalted);
    expect(
      (status >> HarborPcieDma.statusErrorShift) & 0xff,
      HarborPcieDma.errorAlignment,
    );
    expect(
      await b.readReg(HarborPcieDma.registerIrqCause),
      HarborPcieDma.causeError,
    );
    expect(
      b.sink.received.where((t) => t.kind.hasData && t.kind.isRequest),
      isEmpty,
      reason: 'no data and no record',
    );
    // Engine reset clears the halt. A ring of 16 slots then works.
    await b.writeReg(
      HarborPcieDma.registerControl,
      HarborPcieDma.controlEnable | HarborPcieDma.controlEngineReset,
    );
    while ((await b.readReg(HarborPcieDma.registerControl) &
            HarborPcieDma.controlEngineReset) !=
        0) {}
    final cleared = await b.readReg(HarborPcieDma.registerStatus);
    expect(cleared & (HarborPcieDma.statusHalted | 0xff00), 0);
    await b.writeReg(HarborPcieDma.registerIrqCause, HarborPcieDma.causeError);
    await b.writeReg(HarborPcieDma.registerCplSize, 4);
    await _push(b, 2);
    await b.waitUntil(
      () => DmaRecord(b.host.memory.read(_cplBase, 16)).cookie == 2,
      what: 'record after reset',
    );
    await b.finish();
  });
}
