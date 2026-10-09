// Checks SdramInitSequencer's command/cke/done trace cycle-for-cycle
// against the phase lengths HarborSdramCycles computes, at both 125 MHz
// CL3 and 100 MHz CL2.

import 'dart:async';

import 'package:harbor/src/peripherals/sdram_command.dart';
import 'package:harbor/src/peripherals/sdram_config.dart';
import 'package:harbor/src/peripherals/sdram_cycles.dart';
import 'package:harbor/src/peripherals/sdram_init.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// The expected (cmd, cke, addr, ba, done) at edge [k] (1-based: k=1 is the
/// first clock edge after reset is released), derived only from the phase
/// lengths in [cycles].
({int cmd, int cke, int addr, int ba, int done}) _expectedAt(
  HarborSdramCycles cycles,
  int k,
) {
  final p = cycles.powerUp;
  final rp = cycles.rp;
  final mrd = cycles.mrd;
  final rfc = cycles.rfc;
  final nref = cycles.initRefreshes;

  if (k <= p) {
    return (cmd: SdramCommand.nop.index, cke: 0, addr: 0, ba: 0, done: 0);
  }
  if (k == p + 1) {
    return (cmd: SdramCommand.nop.index, cke: 1, addr: 0, ba: 0, done: 0);
  }
  if (k == p + 2) {
    return (cmd: SdramCommand.preAll.index, cke: 1, addr: 0, ba: 0, done: 0);
  }
  if (k <= p + 2 + rp) {
    return (cmd: SdramCommand.nop.index, cke: 1, addr: 0, ba: 0, done: 0);
  }
  if (k == p + 3 + rp) {
    return (
      cmd: SdramCommand.mrs.index,
      cke: 1,
      addr: cycles.modeRegister,
      ba: 0,
      done: 0,
    );
  }
  final afterMrd = p + 3 + rp + mrd;
  if (k <= afterMrd) {
    return (cmd: SdramCommand.nop.index, cke: 1, addr: 0, ba: 0, done: 0);
  }
  final refBlock = 1 + rfc;
  final refEdges = k - afterMrd;
  if (refEdges <= nref * refBlock) {
    final posInBlock = (refEdges - 1) % refBlock; // 0 = the ref edge itself
    if (posInBlock == 0) {
      return (cmd: SdramCommand.ref.index, cke: 1, addr: 0, ba: 0, done: 0);
    }
    return (cmd: SdramCommand.nop.index, cke: 1, addr: 0, ba: 0, done: 0);
  }
  return (cmd: SdramCommand.nop.index, cke: 1, addr: 0, ba: 0, done: 1);
}

int _totalEdges(HarborSdramCycles cycles) =>
    cycles.powerUp +
    3 +
    cycles.rp +
    cycles.mrd +
    cycles.initRefreshes * (1 + cycles.rfc) +
    1;

Future<void> _runTrace(int clockHz) async {
  final cycles = HarborSdramCycles(
    const HarborSdramConfig.as4c16m16sb6(),
    clockHz: clockHz,
  );
  final clk = SimpleClockGenerator(cycles.tCkPs).clk;
  final reset = Logic(name: 'reset')..inject(1);
  final dut = SdramInitSequencer(cycles, clk: clk, reset: reset);
  await dut.build();

  final total = _totalEdges(cycles);
  Simulator.setMaxSimTime((total + 10) * cycles.tCkPs * 2);
  unawaited(Simulator.run());

  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.inject(0);

  for (var k = 1; k <= total; k++) {
    await clk.nextPosedge;
    final expected = _expectedAt(cycles, k);
    expect(dut.cmd.value.toInt(), expected.cmd, reason: 'cmd at edge $k');
    expect(dut.cke.value.toInt(), expected.cke, reason: 'cke at edge $k');
    expect(dut.done.value.toInt(), expected.done, reason: 'done at edge $k');
    if (expected.cmd == SdramCommand.mrs.index) {
      expect(dut.cmdAddr.value.toInt(), expected.addr, reason: 'mrs addr');
      expect(dut.cmdBa.value.toInt(), expected.ba, reason: 'mrs ba');
    }
  }

  // done must stay high past the end of the computed trace.
  await clk.nextPosedge;
  expect(dut.done.value.toInt(), 1);

  await Simulator.endSimulation();
}

void main() {
  tearDown(() async => Simulator.reset());

  test('125 MHz CL3 init trace matches HarborSdramCycles', () async {
    await _runTrace(125000000);
  });

  test('100 MHz CL2 init trace matches HarborSdramCycles', () async {
    await _runTrace(100000000);
  });

  test('done rises only after the last tRFC wait', () async {
    final cycles = HarborSdramCycles(
      const HarborSdramConfig.as4c16m16sb6(),
      clockHz: 125000000,
    );
    final clk = SimpleClockGenerator(cycles.tCkPs).clk;
    final reset = Logic(name: 'reset')..inject(1);
    final dut = SdramInitSequencer(cycles, clk: clk, reset: reset);
    await dut.build();

    final total = _totalEdges(cycles);
    Simulator.setMaxSimTime((total + 10) * cycles.tCkPs * 2);
    unawaited(Simulator.run());

    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);

    var doneSeenAt = -1;
    for (var k = 1; k <= total; k++) {
      await clk.nextPosedge;
      if (dut.done.value.toInt() == 1 && doneSeenAt == -1) {
        doneSeenAt = k;
      }
    }
    expect(doneSeenAt, total, reason: 'done should rise exactly at the end');

    await Simulator.endSimulation();
  });
}
