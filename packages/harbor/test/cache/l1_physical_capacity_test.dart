import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());
  for (final xlen in [32, 64]) {
    for (final size in [8192, 16384]) {
      test(
        'RV$xlen $size physical bytes retain distinct page-offset indices',
        () async {
          final clk = SimpleClockGenerator(10).clk;
          final fault = Logic();
          final cache = HarborL1DCache(
            config: HarborL1dCacheConfig(size: size, ways: 1, lineSize: 64),
            xlen: xlen,
            physicalAddresses: true,
            memFaultIn: fault,
          );
          final p = <String, Logic>{};
          for (final entry in cache.inputs.entries) {
            if (entry.key == 'clk') {
              entry.value.srcConnection! <= clk;
            } else if (entry.key == 'mem_fault') {
              p[entry.key] = fault;
            } else {
              p[entry.key] = Logic(width: entry.value.width);
              entry.value.srcConnection! <= p[entry.key]!;
            }
          }
          await cache.build();
          for (final port in p.values) {
            port.inject(0);
          }
          p['req_size']!.inject(xlen == 64 ? 3 : 2);
          p['reset']!.inject(1);
          unawaited(Simulator.run());
          await clk.nextPosedge;
          p['reset']!.inject(0);
          await clk.nextPosedge;
          final memory = <int, int>{};
          var pending = 0, address = 0, data = 0, reads = 0, writes = 0;
          var write = false;
          Future<void> step() async {
            await clk.nextPosedge;
            if (pending == 0 && cache.memEn.value.toBool()) {
              pending = 3;
              address = cache.memAddr.value.toInt();
              write = cache.memWe.value.toBool();
              data = write ? cache.memWdata.value.toInt() : 0;
            }
            if (pending > 0 && --pending == 0) {
              if (write) {
                memory[address] = data;
                writes++;
              } else {
                reads++;
              }
              p['mem_rdata']!.inject(memory[address] ?? (address ^ 0x55aa55aa));
              p['mem_done']!.inject(1);
              p['mem_valid']!.inject(1);
            } else {
              p['mem_done']!.inject(0);
              p['mem_valid']!.inject(0);
            }
          }

          Future<int> access(int a, {int? store}) async {
            p['req_addr']!.inject(a);
            p['req_write']!.inject(store == null ? 0 : 1);
            p['req_data']!.inject(store ?? 0);
            p['req_valid']!.inject(1);
            final before = reads;
            var done = false;
            for (var cycle = 0; cycle < 200; cycle++) {
              await step();
              expect(cache.respFault.value.toBool(), isFalse);
              if (cache.respValid.value.toBool()) {
                if (store == null)
                  expect(
                    cache.respData.value.toInt(),
                    memory[a] ?? (a ^ 0x55aa55aa),
                  );
                done = true;
                break;
              }
            }
            expect(done, isTrue, reason: 'physical request did not complete');
            p['req_valid']!.inject(0);
            await step();
            return reads - before;
          }

          const a = 0x80000000, b = a + 4096;
          final beats = 64 ~/ (xlen ~/ 8);
          expect(await access(a), beats);
          expect(await access(b), beats);
          expect(await access(a), 0);
          expect(await access(b), 0);
          // Same index but distinct physical tag must replace, not alias.
          expect(await access(a + size), beats);
          expect(await access(b), 0);
          expect(await access(a), beats);
          await access(b, store: 0x12345678);
          expect(writes, 1);
          expect(await access(b), beats);
          expect(await access(a), 0);
          p['flush']!.inject(1);
          await step();
          p['flush']!.inject(0);
          expect(await access(a), beats);
          await Simulator.endSimulation();
        },
      );
      test('RV$xlen $size virtual bytes remain rejected', () {
        expect(
          () => HarborL1DCache(
            config: HarborL1dCacheConfig(size: size, ways: 1, lineSize: 64),
            xlen: xlen,
          ),
          throwsArgumentError,
        );
      });
    }
    test('RV$xlen physical tags reject a truncated address width', () {
      expect(
        () => HarborL1DCache(
          config: const HarborL1dCacheConfig(size: 8192, ways: 1, lineSize: 64),
          xlen: xlen,
          physicalAddresses: true,
          reqAddrBits: xlen - 1,
        ),
        throwsArgumentError,
      );
    });
  }
}
