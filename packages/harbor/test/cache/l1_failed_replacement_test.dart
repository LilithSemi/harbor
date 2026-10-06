import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Simulator.reset);

  for (final instruction in [true, false]) {
    for (final xlen in [32, 64]) {
      final wordBytes = xlen ~/ 8;
      const lineSize = 32;
      for (final faultWord in [1, lineSize ~/ wordBytes - 1]) {
        test('${instruction ? "l1i" : "l1d"} RV$xlen failed replacement '
            'at word $faultWord invalidates victim', () async {
          const size = 256;
          const victim = 0x80000000;
          const replacement = victim + size; // Same index, different tag.
          final Module cache = instruction
              ? HarborL1ICache(
                  config: const HarborL1iCacheConfig(
                    size: size,
                    ways: 1,
                    lineSize: lineSize,
                  ),
                  xlen: xlen,
                )
              : HarborL1DCache(
                  config: const HarborL1dCacheConfig(
                    size: size,
                    ways: 1,
                    lineSize: lineSize,
                  ),
                  xlen: xlen,
                );
          final clk = SimpleClockGenerator(10).clk;
          for (final input in cache.inputs.values) {
            if (input.name != 'clk') input.srcConnection!.put(0);
          }
          cache.input('clk').srcConnection! <= clk;
          void drive(String name, int value) =>
              cache.input(name).srcConnection!.inject(value);
          bool out(String name) => cache.output(name).value.toBool();
          drive('reset', 1);
          if (!instruction) drive('req_size', wordBytes.bitLength - 1);
          await cache.build();
          Simulator.setMaxSimTime(20000);
          unawaited(Simulator.run());

          final reads = <int>[];
          var pending = 0;
          var address = 0;
          var cooldown = 0;
          var injectFault = true;
          int dataAt(int a) => a < replacement
              ? 0x1100 + (a - victim) ~/ wordBytes
              : 0x2200 + (a - replacement) ~/ wordBytes;

          Future<void> step() async {
            await clk.nextPosedge;
            var done = false;
            if (pending > 0) {
              pending--;
              if (pending == 0) {
                done = true;
                cooldown = 1;
              }
            } else if (cooldown > 0) {
              cooldown--;
            } else if (out('mem_en')) {
              address = cache.output('mem_addr').value.toInt();
              reads.add(address);
              pending = 3;
            }
            final fault =
                done &&
                injectFault &&
                address == replacement + faultWord * wordBytes;
            drive('mem_done', done ? 1 : 0);
            drive('mem_valid', done && !fault ? 1 : 0);
            if (instruction) drive('mem_fault', fault ? 1 : 0);
            if (done && !fault) drive('mem_rdata', dataAt(address));
          }

          Future<void> request(int a, {bool fault = false}) async {
            drive('req_valid', 0);
            await step();
            drive('req_addr', a);
            drive('req_valid', 1);
            for (var i = 0; i < 150; i++) {
              await step();
              if (out('resp_valid') || out('resp_fault')) {
                expect(out('resp_fault'), fault);
                expect(out('resp_valid'), !fault);
                if (!fault) {
                  expect(
                    cache.output('resp_data').value.toInt(),
                    dataAt(a),
                    reason: 'old tag must not expose partially replaced data',
                  );
                }
                return;
              }
            }
            fail('No response for 0x${a.toRadixString(16)}');
          }

          try {
            await step();
            drive('reset', 0);
            await step();
            await request(victim);
            expect(reads.length, lineSize ~/ wordBytes);
            final beforeHit = reads.length;
            await request(victim);
            expect(reads.length, beforeHit, reason: 'victim must be resident');

            await request(replacement, fault: true);
            expect(reads.sublist(beforeHit), [
              for (var w = 0; w <= faultWord; w++) replacement + w * wordBytes,
            ]);
            final beforeRecovery = reads.length;
            await request(victim);
            expect(reads.sublist(beforeRecovery), [
              for (var w = 0; w < lineSize ~/ wordBytes; w++)
                victim + w * wordBytes,
            ], reason: 'failed replacement must force the victim to refill');
            for (var w = 1; w < lineSize ~/ wordBytes; w++) {
              await request(victim + w * wordBytes);
            }
            injectFault = false;
            await request(replacement);
          } finally {
            await Simulator.endSimulation();
            await Simulator.simulationEnded;
          }
        });
      }
    }
  }
}
