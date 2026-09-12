import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'l1d_dut.dart';

/// Flush-versus-op timing sweep for [HarborL1DCache].
///
/// A flush (fence.i, sfence.vma, a satp write) can land on ANY cycle of an op,
/// and the requester holds its request until the cache answers. Two properties
/// must hold at every offset:
///
///   1. the held request gets EXACTLY ONE answer, and
///   2. an uncached (MMIO) access reaches the device EXACTLY ONCE.
///
/// Property 2 is what makes this a device test and not a cache test. An SD or
/// UART receive register loses a byte when it is read twice, and a doubled
/// write-through corrupts a command register. The sweep covers a one-cycle
/// flush at every offset and a flush HELD across several cycles, which is what
/// a stalled pipeline presents.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const mmio = 0x10000000;
  const dram = 0x80001000;
  final want = BigInt.parse('DEADBEEF12345678', radix: 16);

  /// Runs one held request with a flush of [flushLen] cycles starting
  /// [offset] steps after the request is presented. Returns the number of
  /// answers seen, the memory access counts and the data.
  Future<({int answers, int reads, int writes, int accesses, BigInt data})>
  run({
    required int addr,
    required bool write,
    required int offset,
    required int flushLen,
    int latency = 8,
    int lineSize = 8,
  }) async {
    final dut = await makeDut(latency: latency, lineSize: lineSize);
    dut.backing.mem[addr & ~7] = want;
    dut['req_addr'].inject(addr);
    dut['req_data'].inject(want);
    dut['req_write'].inject(write ? 1 : 0);
    dut['req_size'].inject(3);
    dut['req_valid'].inject(1);

    var answers = 0;
    var data = BigInt.zero;
    // The request must be held until the answer, then dropped, exactly as the
    // exec unit does. Keep stepping afterwards so a SECOND answer or a second
    // memory access still shows up in the counts.
    var seen = false;
    for (var cycle = 0; cycle < 400; cycle++) {
      dut['flush'].inject(cycle >= offset && cycle < offset + flushLen ? 1 : 0);
      await dut.backing.step();
      if (dut.respValid) {
        answers++;
        if (!seen) {
          data = dut.cache.output('resp_data').value.toBigInt();
          seen = true;
          dut['req_valid'].inject(0);
          dut['req_write'].inject(0);
        }
      }
      if (seen && cycle > offset + flushLen + 3 * latency + 8) break;
    }
    final r = (
      answers: answers,
      reads: dut.backing.reads,
      writes: dut.backing.writes,
      accesses: dut.backing.accesses,
      data: data,
    );
    await Simulator.endSimulation();
    return r;
  }

  const latency = 8;

  /// Offsets 0..latency+3 cover the cycle the request is presented, every cycle
  /// the op is in flight, the completion cycle and the cycles after it. Each
  /// offset is its own test: one simulation per test keeps the ROHD simulator
  /// clean and keeps each case inside the default test timeout.
  for (var offset = 0; offset <= latency + 3; offset++) {
    for (final flushLen in [1, 3]) {
      test('uncached read: flush of $flushLen at offset $offset '
          'answers once and reads the device once', () async {
        final r = await run(
          addr: mmio,
          write: false,
          offset: offset,
          flushLen: flushLen,
          latency: latency,
        );
        expect(r.answers, equals(1), reason: 'answers');
        expect(r.reads, equals(1), reason: 'device reads');
        expect(r.data, equals(want), reason: 'data');
      });

      test('uncached write: flush of $flushLen at offset $offset '
          'answers once and writes the device once', () async {
        final r = await run(
          addr: mmio,
          write: true,
          offset: offset,
          flushLen: flushLen,
          latency: latency,
        );
        expect(r.answers, equals(1), reason: 'answers');
        expect(r.writes, equals(1), reason: 'device writes');
      });

      test('cached load: flush of $flushLen at offset $offset '
          'answers once with the right data', () async {
        final r = await run(
          addr: dram,
          write: false,
          offset: offset,
          flushLen: flushLen,
          latency: latency,
        );
        expect(r.answers, equals(1), reason: 'answers');
        expect(r.data, equals(want), reason: 'data');
      });
    }
  }

  /// A back-to-back stream of uncached reads, the shape an SD block transfer
  /// makes, with a flush pulsed between every pair. Each read must reach the
  /// device exactly once and return its own word.
  test(
    'stream of uncached reads with a flush between each reads once each',
    () async {
      const n = 12;
      final dut = await makeDut(latency: 5);
      for (var i = 0; i < n; i++) {
        dut.backing.mem[mmio + i * 8] = want + BigInt.from(i);
      }
      dut['req_write'].inject(0);
      dut['req_size'].inject(3);
      for (var i = 0; i < n; i++) {
        dut['req_addr'].inject(mmio + i * 8);
        dut['req_valid'].inject(1);
        // Flush while this read is presented and in flight.
        dut['flush'].inject(i.isEven ? 1 : 0);
        var guard = 0;
        var acked = false;
        while (!acked && guard < 200) {
          await dut.backing.step();
          guard++;
          if (guard >= 2) dut['flush'].inject(0);
          acked = dut.respValid;
        }
        expect(acked, isTrue, reason: 'read $i never completed');
        expect(
          dut.cache.output('resp_data').value.toBigInt(),
          equals(want + BigInt.from(i)),
          reason: 'read $i returned the wrong word',
        );
        dut['req_valid'].inject(0);
        await dut.backing.step();
      }
      final reads = dut.backing.reads;
      final log = List.of(dut.backing.readLog);
      await Simulator.endSimulation();
      expect(
        reads,
        equals(n),
        reason: 'the device was read $reads times for $n loads: $log',
      );
    },
  );
}
