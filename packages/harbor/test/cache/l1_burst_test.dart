import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'l1_burst_bench.dart';

const _base = 0x80000000;

void main() {
  tearDown(() async {
    await Simulator.endSimulation();
    await Simulator.reset();
  });

  for (final instruction in [true, false]) {
    final kind = instruction ? 'l1i' : 'l1d';
    for (final xlen in [32, 64]) {
      for (final lineSize in [8, 16, 32, 64]) {
        final wordBytes = xlen ~/ 8;
        if (lineSize < wordBytes) continue;
        final beats = lineSize ~/ wordBytes;
        for (final physical in instruction ? [false] : [false, true]) {
          final name =
              '$kind RV$xlen ${lineSize}B${physical ? ' physical' : ''}';

          test('$name: a miss is one burst and the line then hits', () async {
            final dut = await BurstDut.make(
              instruction: instruction,
              xlen: xlen,
              lineSize: lineSize,
              physical: physical,
              gap: -1,
            );
            final addr = _base + 3 * lineSize + (beats - 1) * wordBytes;
            expect(await dut.read(addr), dut.mem.wordAt(addr));
            expect(dut.mem.requests, hasLength(1));
            final req = dut.mem.requests.single;
            expect(req.addr, _base + 3 * lineSize);
            expect(req.len, beats - 1);
            expect(req.write, isFalse);
            expect(req.size, wordBytes.bitLength - 1);
            for (var w = 0; w < beats; w++) {
              final a = _base + 3 * lineSize + w * wordBytes;
              expect(await dut.read(a), dut.mem.wordAt(a));
            }
            expect(dut.mem.requests, hasLength(1));
          });

          for (var bad = 0; bad < beats; bad++) {
            test('$name: an error on beat $bad drops the line', () async {
              final dut = await BurstDut.make(
                instruction: instruction,
                xlen: xlen,
                lineSize: lineSize,
                physical: physical,
              );
              final addr = _base + lineSize;
              // The line holds data before the failed refill, so a half
              // written line would hit with the wrong tag.
              expect(await dut.read(addr + 2 * 1024), isNotNull);
              dut.mem.error = (req, beat) => req == 1 && beat == bad;
              expect(await dut.read(addr), isNull);
              expect(dut.mem.beatsGiven, [beats, beats]);
              expect(dut.out('mem_en'), isFalse);
              // Neither the failed line nor the victim may hit.
              expect(await dut.read(addr), dut.mem.wordAt(addr));
              expect(await dut.read(addr + 2 * 1024), isNotNull);
              expect(dut.mem.requests, hasLength(4));
            });
          }
        }
      }
    }
  }

  for (final instruction in [true, false]) {
    final kind = instruction ? 'l1i' : 'l1d';
    test('$kind: the cache takes every beat of a failed burst', () async {
      final dut = await BurstDut.make(
        instruction: instruction,
        xlen: 64,
        lineSize: 64,
        gap: 2,
      );
      dut.mem.error = (req, beat) => req == 0 && beat == 0;
      var enAfterError = 0;
      var started = false;
      dut.perCycle.add(() {
        if (dut.mem.busy) started = true;
        if (started && dut.mem.busy && dut.out('mem_en')) enAfterError++;
      });
      expect(await dut.read(_base), isNull);
      expect(dut.mem.beatsGiven, [8]);
      // mem_en stays high until the last beat, so it covers every gap.
      expect(enAfterError, greaterThanOrEqualTo(7 * 3));
      expect(await dut.read(_base + 8), dut.mem.wordAt(_base + 8));
      expect(dut.mem.requests, hasLength(2));
    });

    for (final (name, lastBeat) in [('early', 1), ('late', 4)]) {
      test(
        '$kind: an $name mem_last drops the line without the sim check',
        () async {
          final dut = await BurstDut.make(
            instruction: instruction,
            xlen: 64,
            lineSize: 32,
            checkMemLast: false,
          );
          dut.mem.lastBeat = lastBeat;
          expect(await dut.read(_base), isNull);
          expect(dut.mem.beatsGiven, [lastBeat + 1]);
          dut.mem.lastBeat = null;
          expect(await dut.read(_base + 8), dut.mem.wordAt(_base + 8));
          expect(await dut.read(_base + 24), dut.mem.wordAt(_base + 24));
          expect(dut.mem.requests, hasLength(2));
        },
      );
    }

    test('$kind: an early mem_last stops the simulation', () async {
      final dut = await BurstDut.make(
        instruction: instruction,
        xlen: 64,
        lineSize: 32,
      );
      final cache = dut.cache;
      dut.perCycle.add(() {
        if (dut.mem.busy && cache.input('mem_done').value.toBool()) {
          cache.input('mem_last').srcConnection!.inject(1);
        }
      });
      await expectLater(dut.read(_base, limit: 50), throwsA(anything));
      expect('${dut.simError}', contains('mem_last'));
    });

    for (var flushBeat = 0; flushBeat < 4; flushBeat++) {
      test('$kind: a flush on beat $flushBeat waits for mem_last', () async {
        final dut = await BurstDut.make(
          instruction: instruction,
          xlen: 64,
          lineSize: 32,
          latency: 4,
          gap: 1,
        );
        var beat = 0;
        var flushed = false;
        var requestsAtLast = -1;
        dut.perCycle.add(() {
          final done = dut.cache.input('mem_done').value.toBool();
          if (done && !flushed && beat == flushBeat) {
            dut.drive('flush', 1);
            flushed = true;
          } else if (flushed) {
            dut.drive('flush', 0);
          }
          if (done) {
            if (dut.cache.input('mem_last').value.toBool()) {
              requestsAtLast = dut.mem.requests.length;
            }
            beat++;
          }
        });
        dut.drive('req_addr', _base);
        if (!instruction) dut.drive('req_size', 3);
        dut.drive('req_valid', 1);
        while (requestsAtLast < 0) {
          await dut.step();
          // No new request may start before the last beat of the old one.
          expect(dut.mem.requests.length, lessThanOrEqualTo(1));
        }
        dut.perCycle.clear();
        dut.drive('flush', 0);
        dut.drive('req_valid', 0);
        await dut.steps(
          dut.cache is HarborL1ICache
              ? (dut.cache as HarborL1ICache).sweepCycles + 4
              : (dut.cache as HarborL1DCache).sweepCycles + 4,
        );
        dut.mem.bytes[_base + 0x400] = 0x5a;
        expect(await dut.read(_base + 0x400), dut.mem.wordAt(_base + 0x400));
        expect(await dut.read(_base + 0x408), dut.mem.wordAt(_base + 0x408));
        expect(dut.mem.requests, hasLength(2));
      });
    }
  }
}
