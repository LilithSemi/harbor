import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'l1_burst_bench.dart';

const _base = 0x80000000;

BigInt? _low(BigInt? v, int size) =>
    v == null ? null : v & ((BigInt.one << (8 << size)) - BigInt.one);

void main() {
  tearDown(() async {
    await Simulator.endSimulation();
    await Simulator.reset();
  });

  for (final xlen in [32, 64]) {
    final wordBytes = xlen ~/ 8;
    for (final lineSize in [8, 32, 64]) {
      if (lineSize < wordBytes) continue;
      for (final physical in [false, true]) {
        final name = 'l1d RV$xlen ${lineSize}B${physical ? ' physical' : ''}';

        test(
          '$name: a store hit writes its bytes and keeps the line',
          () async {
            final dut = await BurstDut.make(
              instruction: false,
              xlen: xlen,
              lineSize: lineSize,
              physical: physical,
            );
            final line = _base + 5 * lineSize;
            final word = line + lineSize - wordBytes;
            await dut.read(word);
            var requests = dut.mem.requests.length;
            var value = 0x11;
            for (var size = 0; (1 << size) <= wordBytes; size++) {
              for (var lane = 0; lane < wordBytes; lane += 1 << size) {
                final data = BigInt.from(value++) * BigInt.from(0x01010101);
                expect(await dut.write(word + lane, size, data), isTrue);
                expect(dut.mem.requests, hasLength(requests + 1));
                final req = dut.mem.requests.last;
                expect(req.write, isTrue);
                expect(req.len, 0);
                requests++;
                // The load hits and sees the new bytes.
                expect(await dut.read(word), dut.mem.wordAt(word));
                expect(
                  _low(await dut.read(word + lane, size: size), size),
                  dut.mem.valueAt(word + lane, size),
                );
                expect(dut.mem.requests, hasLength(requests));
              }
            }
            // The other words of the line are still there.
            expect(await dut.read(line), dut.mem.wordAt(line));
            expect(dut.mem.requests, hasLength(requests));
          },
        );

        test('$name: a store that faults changes nothing', () async {
          final dut = await BurstDut.make(
            instruction: false,
            xlen: xlen,
            lineSize: lineSize,
            physical: physical,
          );
          final addr = _base + lineSize;
          final old = await dut.read(addr);
          dut.mem.error = (req, beat) => req == 1;
          expect(await dut.write(addr, 0, BigInt.from(0xa5)), isFalse);
          dut.mem.error = null;
          expect(await dut.read(addr), old);
          expect(dut.mem.requests, hasLength(2));
        });

        test('$name: a store miss does not allocate', () async {
          final dut = await BurstDut.make(
            instruction: false,
            xlen: xlen,
            lineSize: lineSize,
            physical: physical,
          );
          final resident = _base + 2 * lineSize;
          // Same index, other tag.
          final other = resident + 1024;
          await dut.read(resident);
          expect(await dut.write(other, 0, BigInt.from(0x3c)), isTrue);
          expect(dut.mem.requests, hasLength(2));
          expect(await dut.read(resident), dut.mem.wordAt(resident));
          // A physical cache keeps the resident line. A virtual cache drops
          // it, because the store can be to an alias of it.
          expect(dut.mem.requests, hasLength(physical ? 2 : 3));
          expect(await dut.read(other), dut.mem.wordAt(other));
        });

        test('$name: random loads and stores match memory', () async {
          final dut = await BurstDut.make(
            instruction: false,
            xlen: xlen,
            lineSize: lineSize,
            physical: physical,
            size: 256,
            gap: -1,
          );
          final rng = Random(xlen * 131 + lineSize + (physical ? 7 : 0));
          for (var i = 0; i < 400; i++) {
            final size = rng.nextInt(wordBytes.bitLength);
            final addr = (_base + rng.nextInt(1024)) & ~((1 << size) - 1);
            if (rng.nextInt(3) == 0) {
              final data = BigInt.from(rng.nextInt(1 << 30));
              expect(await dut.write(addr, size, data), isTrue);
            } else {
              expect(
                _low(await dut.read(addr, size: size), size),
                dut.mem.valueAt(addr, size),
                reason: 'load $i of $size at 0x${addr.toRadixString(16)}',
              );
            }
          }
        });
      }
    }
  }
}
