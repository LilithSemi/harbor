import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:harbor/harbor.dart';

/// Both L1 caches sit in FRONT of the MMU, so they are virtually indexed AND
/// virtually tagged: the pipeline presents a VIRTUAL address and only a MISS is
/// translated. The tag was sized from a physical-address width of 32, so
/// the stored tag covered only VA[31:tagLo] and VA[63:32] was never compared.
///
/// Under Sv39 the supervisor half holds several regions whose low 32 bits
/// overlap: the linear map, vmalloc (where VMAP_STACK puts kernel stacks) and
/// kernel text sit at different VA[38:32]. Two such addresses were therefore the
/// SAME cache line, and a load of one returned the other's data. That is a bad
/// READ, but to software it is indistinguishable from a store that never landed.
///
/// The addresses below are a linear-map address and a vmalloc address that share
/// their low 32 bits, taken from the RISC-V Sv39 kernel layout. They are
/// different pages, mapped to different physical frames, in the SAME privilege
/// context, so no context tag and no flush can be claimed to cover the case.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  /// Linear map (PAGE_OFFSET half).
  final linearMap = BigInt.parse('FFFFFFD602087000', radix: 16);

  /// vmalloc half. Differs from [linearMap] only in VA[38:32].
  final vmalloc = BigInt.parse('FFFFFFD002087000', radix: 16);

  /// Kernel text half. Also shares the low 32 bits.
  final kernelText = BigInt.parse('FFFFFFFE02087000', radix: 16);

  final dataOf = <BigInt, BigInt>{
    linearMap: BigInt.parse('1111111111111111', radix: 16),
    vmalloc: BigInt.parse('2222222222222222', radix: 16),
    kernelText: BigInt.parse('3333333333333333', radix: 16),
  };

  LogicValue lv(BigInt v) => LogicValue.ofBigInt(v, 64);

  /// Drives a load through a cache that holds its request until `resp_valid`,
  /// and reports the word served plus how many line fills the memory saw.
  /// Both L1s use the same request protocol, so one driver serves both.
  Future<(BigInt, int)> readThrough({
    required Module cache,
    required Logic clk,
    required Map<String, Logic> ports,
    required BigInt addr,
    required Map<BigInt, BigInt> mem,
    int latency = 3,
  }) async {
    var fills = 0;
    var armed = false;
    var pending = 0;
    var pendA = BigInt.zero;
    ports['req_addr']!.inject(lv(addr));
    ports['req_valid']!.inject(1);
    var served = BigInt.zero;
    var done = false;
    for (var i = 0; i < 400 && !done; i++) {
      await clk.nextPosedge;
      if (!armed && cache.output('mem_en').value.toBool()) {
        armed = true;
        fills++;
        pendA = cache.output('mem_addr').value.toBigInt();
        pending = latency;
      }
      if (armed) {
        pending--;
        if (pending <= 0) {
          armed = false;
          // Word granular: the line base carries the word this test cares about.
          ports['mem_rdata']!.inject(lv(mem[pendA] ?? BigInt.zero));
          ports['mem_done']!.inject(1);
          ports['mem_valid']!.inject(1);
        } else {
          ports['mem_done']!.inject(0);
          ports['mem_valid']!.inject(0);
        }
      } else {
        ports['mem_done']!.inject(0);
        ports['mem_valid']!.inject(0);
      }
      if (cache.output('resp_valid').value.toBool()) {
        served = cache.output('resp_data').value.toBigInt();
        done = true;
      }
    }
    ports['req_valid']!.inject(0);
    await clk.nextPosedge;
    expect(done, isTrue, reason: 'load of $addr never completed');
    return (served, fills);
  }

  group('D-cache', () {
    Future<(Module, Logic, Map<String, Logic>)> build({int ctxBits = 0}) async {
      final clk = SimpleClockGenerator(10).clk;
      final ports = <String, Logic>{
        'reset': Logic(name: 'reset'),
        'req_addr': Logic(name: 'req_addr', width: 64),
        'req_valid': Logic(name: 'req_valid'),
        'req_write': Logic(name: 'req_write'),
        'req_data': Logic(name: 'req_data', width: 64),
        'req_size': Logic(name: 'req_size', width: 3),
        'flush': Logic(name: 'flush'),
        'mem_done': Logic(name: 'mem_done'),
        'mem_valid': Logic(name: 'mem_valid'),
        'mem_rdata': Logic(name: 'mem_rdata', width: 64),
        'mem_fault': Logic(name: 'mem_fault'),
        if (ctxBits > 0) 'req_ctx': Logic(name: 'req_ctx', width: ctxBits),
      };
      final cache = HarborL1DCache(
        config: const HarborL1dCacheConfig(size: 256, ways: 1, lineSize: 8),
        xlen: 64,
        ctxBits: ctxBits,
        // Sv39: the request is a 39-bit canonical virtual address.
        reqAddrBits: 39,
      );
      cache.port('clk').getsLogic(clk);
      ports.forEach((n, l) => cache.port(n).getsLogic(l));
      await cache.build();
      ports.forEach((n, l) => l.inject(0));
      ports['reset']!.inject(1);
      ports['req_size']!.inject(3);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      ports['reset']!.inject(0);
      await clk.nextPosedge;
      return (cache, clk, ports);
    }

    test('a vmalloc address does not hit a linear-map line', () async {
      final (cache, clk, ports) = await build();
      final mem = Map<BigInt, BigInt>.from(dataOf);
      final (gotLinear, _) = await readThrough(
        cache: cache,
        clk: clk,
        ports: ports,
        addr: linearMap,
        mem: mem,
      );
      final (gotVmalloc, fillsVmalloc) = await readThrough(
        cache: cache,
        clk: clk,
        ports: ports,
        addr: vmalloc,
        mem: mem,
      );
      await Simulator.endSimulation();
      expect(gotLinear, equals(dataOf[linearMap]));
      expect(
        fillsVmalloc,
        equals(1),
        reason:
            'the vmalloc load HIT the linear-map line: the tag does not '
            'compare VA[38:32], so two different pages are one cache line',
      );
      expect(
        gotVmalloc,
        equals(dataOf[vmalloc]),
        reason: 'the vmalloc load was served the linear-map page data',
      );
    });

    test('a kernel-text address does not hit a linear-map line', () async {
      final (cache, clk, ports) = await build();
      final mem = Map<BigInt, BigInt>.from(dataOf);
      await readThrough(
        cache: cache,
        clk: clk,
        ports: ports,
        addr: linearMap,
        mem: mem,
      );
      final (got, fills) = await readThrough(
        cache: cache,
        clk: clk,
        ports: ports,
        addr: kernelText,
        mem: mem,
      );
      await Simulator.endSimulation();
      expect(fills, equals(1));
      expect(got, equals(dataOf[kernelText]));
    });

    test('the same address still hits, so caching still works', () async {
      final (cache, clk, ports) = await build();
      final mem = Map<BigInt, BigInt>.from(dataOf);
      await readThrough(
        cache: cache,
        clk: clk,
        ports: ports,
        addr: linearMap,
        mem: mem,
      );
      final (got, fills) = await readThrough(
        cache: cache,
        clk: clk,
        ports: ports,
        addr: linearMap,
        mem: mem,
      );
      await Simulator.endSimulation();
      expect(got, equals(dataOf[linearMap]));
      expect(
        fills,
        equals(0),
        reason:
            'the second load of the SAME address missed: the wider tag '
            'stopped the cache from hitting at all',
      );
    });

    test('aliasing is not covered by the context tag', () async {
      final (cache, clk, ports) = await build(ctxBits: 2);
      final mem = Map<BigInt, BigInt>.from(dataOf);
      // One privilege context throughout, so only the address differs.
      ports['req_ctx']!.inject(1);
      await readThrough(
        cache: cache,
        clk: clk,
        ports: ports,
        addr: linearMap,
        mem: mem,
      );
      final (got, fills) = await readThrough(
        cache: cache,
        clk: clk,
        ports: ports,
        addr: vmalloc,
        mem: mem,
      );
      await Simulator.endSimulation();
      expect(fills, equals(1));
      expect(
        got,
        equals(dataOf[vmalloc]),
        reason:
            'same context, different page: the context tag cannot separate '
            'these, only the address tag can',
      );
    });
  });

  group('I-cache', () {
    Future<(Module, Logic, Map<String, Logic>)> build({int ctxBits = 0}) async {
      final clk = SimpleClockGenerator(10).clk;
      final ports = <String, Logic>{
        'reset': Logic(name: 'reset'),
        'req_addr': Logic(name: 'req_addr', width: 64),
        'req_valid': Logic(name: 'req_valid'),
        'flush': Logic(name: 'flush'),
        'mem_done': Logic(name: 'mem_done'),
        'mem_valid': Logic(name: 'mem_valid'),
        'mem_fault': Logic(name: 'mem_fault'),
        'mem_rdata': Logic(name: 'mem_rdata', width: 64),
        if (ctxBits > 0) 'req_ctx': Logic(name: 'req_ctx', width: ctxBits),
      };
      final cache = HarborL1ICache(
        config: const HarborL1iCacheConfig(size: 256, ways: 1, lineSize: 8),
        xlen: 64,
        ctxBits: ctxBits,
        reqAddrBits: 39,
      );
      cache.port('clk').getsLogic(clk);
      ports.forEach((n, l) => cache.port(n).getsLogic(l));
      await cache.build();
      ports.forEach((n, l) => l.inject(0));
      ports['reset']!.inject(1);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      ports['reset']!.inject(0);
      await clk.nextPosedge;
      return (cache, clk, ports);
    }

    test('a kernel-text fetch does not hit a linear-map line', () async {
      final (cache, clk, ports) = await build();
      final mem = Map<BigInt, BigInt>.from(dataOf);
      final (gotLinear, _) = await readThrough(
        cache: cache,
        clk: clk,
        ports: ports,
        addr: linearMap,
        mem: mem,
      );
      final (got, fills) = await readThrough(
        cache: cache,
        clk: clk,
        ports: ports,
        addr: kernelText,
        mem: mem,
      );
      await Simulator.endSimulation();
      expect(gotLinear, equals(dataOf[linearMap]));
      expect(
        fills,
        equals(1),
        reason:
            'the kernel-text fetch HIT a line filled from the linear map: the '
            'I-cache tag does not compare VA[38:32]',
      );
      expect(got, equals(dataOf[kernelText]));
    });

    test('the same address still hits, so caching still works', () async {
      final (cache, clk, ports) = await build();
      final mem = Map<BigInt, BigInt>.from(dataOf);
      await readThrough(
        cache: cache,
        clk: clk,
        ports: ports,
        addr: kernelText,
        mem: mem,
      );
      final (got, fills) = await readThrough(
        cache: cache,
        clk: clk,
        ports: ports,
        addr: kernelText,
        mem: mem,
      );
      await Simulator.endSimulation();
      expect(got, equals(dataOf[kernelText]));
      expect(fills, equals(0));
    });
  });
}
