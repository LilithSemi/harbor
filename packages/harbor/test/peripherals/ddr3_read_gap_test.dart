// RD to RD command spacing: the controller must hold `readGap` empty
// cycles between any two read commands, on any bank (Ddr3Controller
// minReadGap). This drives directed read traffic through the fast sim
// bench and checks the spacing of every RD command it decodes off
// `phy_cmd`, the same way Ddr3PhyWordModel finds a read slot.

import 'package:harbor/harbor.dart';
import 'package:harbor/src/peripherals/ddr3_mode_registers.dart' show Ddr3Cmd;
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../bus/port/memory_harness.dart';
import 'ddr3_fast_bench.dart';

// Bank bits of the controller word address start right after the column
// bits the SERDES ratio already spans (Ddr3Controller.bankOf). Flipping
// word-address bit [colBits - clog2(serdesRatio*2)] moves to bank 1 and
// keeps row and column at 0.
final _bankShift =
    ax7203Params.colBits - ((ax7203Params.serdesRatio * 2).bitLength - 1);
final _wordBytes = ax7203Params.wbDataBits ~/ 8;
final _bank0Addr = 0;
final _bank1Addr = (1 << _bankShift) * _wordBytes;

/// Controller cycle and bank of every RD command [cmd] carries, decoded
/// the way [Ddr3PhyWordModel] finds a read slot.
class RdMonitor {
  final List<(int, int)> events = [];
  int _cycle = 0;

  RdMonitor(Logic clk, Logic cmd) {
    final rowBits = ax7203Params.rowBits;
    final baBits = ax7203Params.baBits;
    final cmdLen = 4 + 3 + baBits + rowBits;
    clk.negedge.listen((_) {
      final n = _cycle++;
      final v = cmd.value;
      if (!v.isValid) return;
      for (var s = 0; s < ax7203Params.serdesRatio; s++) {
        final slot = v.getRange(cmdLen * s, cmdLen * (s + 1));
        if (slot[cmdLen - 1].toInt() != 0) continue;
        final op = slot.getRange(cmdLen - 4, cmdLen - 1).toInt();
        if (op != Ddr3Cmd.rd & 7) continue;
        final bank = slot.getRange(rowBits, rowBits + baBits).toInt();
        events.add((n, bank));
      }
    });
  }
}

Burst _read(int addr, int beats) => Burst(
  id: 0,
  write: false,
  addr: addr,
  len: beats - 1,
  size: 2,
  burst: HarborMemoryBurst.incr.value,
);

// Every RD must follow the one before it by at least readGap + 1
// controller cycles, and the tightest pair observed must hit that bound,
// so the run actually stressed the gap rather than staying loose on it.
void _checkSpacing(List<(int, int)> events, int readGap) {
  expect(events.length, greaterThan(8));
  var minGap = events[1].$1 - events[0].$1;
  for (var i = 1; i < events.length; i++) {
    final gap = events[i].$1 - events[i - 1].$1;
    expect(
      gap,
      greaterThanOrEqualTo(readGap + 1),
      reason:
          'RD at cycle ${events[i].$1} follows cycle '
          '${events[i - 1].$1} too closely',
    );
    if (gap < minGap) minGap = gap;
  }
  expect(minGap, readGap + 1);
}

void main() {
  tearDown(Simulator.reset);

  for (final gap in [0, 1, 3]) {
    test('RD to RD spacing, same bank, gap $gap', () async {
      final top = Ddr3FabricBench(
        cores: const [CoreCfg('a', 2, 4)],
        readChannels: 1,
        outstanding: 4,
        readGap: gap,
      );
      final run = await Ddr3FabricRun.start(top, stall: 0, cores: const ['a']);
      final monitor = RdMonitor(run.ddrClk, top.output('phy_cmd'));
      final a = run.managers['a']!;
      a.read(_read(_bank0Addr, 128));
      await waitUntil(run.sim, () => a.rBeats.length == 128, limit: 100000);
      await Simulator.endSimulation();

      expect(run.allErrors, isEmpty);
      expect(monitor.events.every((e) => e.$2 == 0), isTrue);
      _checkSpacing(monitor.events, gap);
    });

    test('RD to RD spacing, cross bank, gap $gap', () async {
      final top = Ddr3FabricBench(
        cores: const [
          CoreCfg('a', 2, 4, readChannel: 0),
          CoreCfg('b', 2, 4, readChannel: 1),
        ],
        readChannels: 2,
        outstanding: 4,
        readGap: gap,
      );
      final run = await Ddr3FabricRun.start(
        top,
        stall: 0,
        cores: const ['a', 'b'],
      );
      final monitor = RdMonitor(run.ddrClk, top.output('phy_cmd'));
      final a = run.managers['a']!;
      final b = run.managers['b']!;
      a.read(_read(_bank0Addr, 128));
      b.read(_read(_bank1Addr, 128));
      await waitUntil(
        run.sim,
        () => a.rBeats.length == 128 && b.rBeats.length == 128,
        limit: 100000,
      );
      await Simulator.endSimulation();

      expect(run.allErrors, isEmpty);
      expect(monitor.events.any((e) => e.$2 == 0), isTrue);
      expect(monitor.events.any((e) => e.$2 == 1), isTrue);
      _checkSpacing(monitor.events, gap);
    });
  }
}
