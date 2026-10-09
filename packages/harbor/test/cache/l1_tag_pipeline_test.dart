import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

class _Bench {
  final Module cache;
  final Logic clk;
  final Map<String, Logic> p;
  final int xlen;
  int reads = 0;
  int remaining = 0;
  BigInt pendingData = BigInt.zero;

  _Bench(this.cache, this.clk, this.p, this.xlen);

  BigInt value(BigInt address, int context) =>
      address ^ BigInt.from(0x13570000 + context * 0x10000);

  Future<void> step() async {
    await clk.nextPosedge;
    if (remaining == 0 && cache.output('mem_en').value.toBool()) {
      remaining = 3;
      reads++;
      pendingData = value(
        cache.output('mem_addr').value.toBigInt(),
        p['req_ctx']!.value.toInt(),
      );
    }
    if (remaining > 0 && --remaining == 0) {
      p['mem_rdata']!.inject(LogicValue.ofBigInt(pendingData, xlen));
      p['mem_done']!.inject(1);
      p['mem_valid']!.inject(1);
    } else {
      p['mem_done']!.inject(0);
      p['mem_valid']!.inject(0);
    }
  }

  Future<int> read(BigInt address, {int context = 0}) async {
    p['req_ctx']!.inject(context);
    p['req_addr']!.inject(LogicValue.ofBigInt(address, xlen));
    p['req_valid']!.inject(1);
    final before = reads;
    var complete = false;
    for (var i = 0; i < 80; i++) {
      await step();
      if (cache.output('resp_valid').value.toBool()) {
        expect(
          cache.output('resp_data').value.toBigInt(),
          value(address, context),
        );
        complete = true;
        break;
      }
    }
    expect(complete, isTrue, reason: 'cache did not complete the request');
    p['req_valid']!.inject(0);
    await step();
    return reads - before;
  }
}

Future<_Bench> _build(String kind, int xlen, int lines) async {
  final clk = SimpleClockGenerator(10).clk;
  final fault = Logic();
  final Module cache = kind == 'd'
      ? HarborL1DCache(
          config: HarborL1dCacheConfig(size: lines * 16, ways: 1, lineSize: 16),
          xlen: xlen,
          reqAddrBits: xlen,
          ctxBits: 2,
          memFaultIn: fault,
        )
      : HarborL1ICache(
          config: HarborL1iCacheConfig(size: lines * 16, ways: 1, lineSize: 16),
          xlen: xlen,
          reqAddrBits: xlen,
          ctxBits: 2,
          dualPort: kind == 'i2',
        );
  final p = <String, Logic>{};
  for (final entry in cache.inputs.entries) {
    if (entry.key == 'clk') {
      entry.value.srcConnection! <= clk;
    } else if (entry.key == 'mem_fault') {
      p[entry.key] = fault;
      if (kind != 'd') entry.value.srcConnection! <= fault;
    } else {
      p[entry.key] = Logic(width: entry.value.width);
      entry.value.srcConnection! <= p[entry.key]!;
    }
  }
  await cache.build();
  for (final signal in p.values) {
    signal.inject(0);
  }
  if (kind == 'd') p['req_size']!.inject(xlen == 64 ? 3 : 2);
  p['reset']!.inject(1);
  unawaited(Simulator.run());
  final bench = _Bench(cache, clk, p, xlen);
  await bench.step();
  p['reset']!.inject(0);
  await bench.step();
  return bench;
}

void main() {
  tearDown(() async => Simulator.reset());
  for (final xlen in [32, 64]) {
    for (final kind in ['d', 'i', 'i2']) {
      for (final lines in [1, 4]) {
        test(
          '$kind RV$xlen $lines lines align tags, data and contexts',
          () async {
            final b = await _build(kind, xlen, lines);
            final a = BigInt.from(0x80000000);
            final otherIndex = a + BigInt.from(16);
            final conflict =
                a + (xlen == 64 ? BigInt.one << 32 : BigInt.from(4096));
            final beats = 16 ~/ (xlen ~/ 8);
            expect(await b.read(a), beats);
            expect(await b.read(a), 0);
            expect(await b.read(conflict), beats);
            expect(await b.read(a), beats);
            // A changed permission context must not reuse a resident tag.
            expect(await b.read(a, context: 3), beats);
            expect(await b.read(a, context: 3), 0);
            if (lines > 1) {
              expect(await b.read(otherIndex, context: 3), beats);
              final before = b.reads;
              b.p['req_valid']!.inject(1);
              if (kind == 'i2') b.p['req_valid1']!.inject(1);
              for (var i = 0; i < 12; i++) {
                final address = i.isEven ? a : otherIndex;
                final address1 = i.isEven ? otherIndex : a;
                b.p['req_addr']!.inject(LogicValue.ofBigInt(address, xlen));
                if (kind == 'i2') {
                  b.p['req_addr1']!.inject(LogicValue.ofBigInt(address1, xlen));
                }
                await b.step();
                expect(b.cache.output('resp_valid').value.toBool(), isTrue);
                expect(
                  b.cache.output('resp_data').value.toBigInt(),
                  b.value(address, 3),
                );
                if (kind == 'i2') {
                  expect(b.cache.output('resp_valid1').value.toBool(), isTrue);
                  expect(
                    b.cache.output('resp_data1').value.toBigInt(),
                    b.value(address1, 3),
                  );
                }
              }
              expect(
                b.reads,
                before,
                reason: 'warm streaming hits must not refill',
              );
            }
            await Simulator.endSimulation();
          },
        );
      }
    }
  }
}
