import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../bus/port/memory_harness.dart';
import 'ddr3_fast_bench.dart';

// The writer uses read channel 0 and the reader read channel 1. A third
// core keeps the controller busy on both channels.
const _cores = [
  CoreCfg('wr', 2, 8, readChannel: 0),
  CoreCfg('rd', 2, 8, readChannel: 1),
  CoreCfg('bg', 2, 8),
];

void main() {
  tearDown(Simulator.reset);

  test(
    'a read on channel 1 accepted after a write WRESP returns that write',
    () async {
      final top = Ddr3FabricBench(
        cores: _cores,
        readChannels: 2,
        outstanding: 8,
      );
      final run = await Ddr3FabricRun.start(
        top,
        seed: 7,
        stall: 0,
        cores: [for (final c in _cores) c.name],
      );
      final rng = Random(7);
      final wr = run.managers['wr']!;
      final rd = run.managers['rd']!;
      final bg = run.managers['bg']!;
      final bgGen = BurstGen(rng, busBytes: 4, idWidth: 2, span: 0x3000);
      final errors = <String>[];
      final golden = WordMemory(4);

      for (var i = 0; i < 40; i++) {
        for (var j = 0; j < 4; j++) {
          final b = bgGen.next(write: rng.nextBool());
          final x = Burst(
            id: b.id,
            write: b.write,
            addr: b.addr + 0x40000,
            len: b.len,
            size: b.size,
            burst: b.burst,
            data: b.data,
            strb: b.strb,
          );
          if (x.write) {
            bg.write(x);
          } else {
            bg.read(x);
          }
        }
        final addr = 0x20000 + rng.nextInt(0x3c0) * 4;
        final len = rng.nextInt(16);
        final beats = len + 1;
        final w = Burst(
          id: rng.nextInt(4),
          write: true,
          addr: addr,
          len: len,
          size: 2,
          burst: HarborMemoryBurst.incr.value,
          data: [for (var k = 0; k < beats; k++) rng.nextInt(1 << 32)],
          strb: [for (var k = 0; k < beats; k++) 0xf],
        );
        final addrs = beatAddrs(w.addr, w.len, w.size, w.burst);
        for (var k = 0; k < beats; k++) {
          golden.write(addrs[k], w.data[k], w.strb[k]);
        }
        final bBefore = wr.bResp.length;
        final rBefore = rd.rBeats.length;
        wr.write(w);
        // The read goes in only after the write got its WRESP.
        await waitUntil(run.sim, () => wr.bResp.length > bBefore);
        rd.read(
          Burst(
            id: rng.nextInt(4),
            write: false,
            addr: addr,
            len: len,
            size: 2,
            burst: HarborMemoryBurst.incr.value,
          ),
        );
        await waitUntil(run.sim, () => rd.rBeats.length == rBefore + beats);
        for (var k = 0; k < beats; k++) {
          final got = rd.rBeats[rBefore + k].$2;
          final want = golden.read(addrs[k]);
          if (got != want) {
            errors.add(
              'round $i beat $k at 0x${addrs[k].toRadixString(16)}: '
              '0x${got.toRadixString(16)}, want 0x${want.toRadixString(16)}',
            );
          }
        }
      }
      await waitUntil(
        run.sim,
        () =>
            bg.bResp.length == bg.awOrder.length &&
            bg.rBeats.length == bg.readBeatsExpected,
        limit: 200000,
      );
      await Simulator.endSimulation();
      expect([...errors, ...run.allErrors], isEmpty);
    },
    timeout: const Timeout(Duration(hours: 2)),
  );
}
