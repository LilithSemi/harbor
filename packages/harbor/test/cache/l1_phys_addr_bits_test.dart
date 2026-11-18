import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'l1_burst_bench.dart';

const _base = 0x80000000;
const _line = 32;

HarborL1DCache _cache({
  int size = 1024,
  int xlen = 64,
  bool snoop = false,
  bool physical = true,
  int? physAddrBits,
  int? cacheAddrBits,
  int? reqAddrBits,
  int cacheableBase = 0x80000000,
}) => HarborL1DCache(
  config: HarborL1dCacheConfig(size: size, ways: 1, lineSize: _line),
  xlen: xlen,
  physicalAddresses: physical,
  snoop: snoop,
  physAddrBits: physAddrBits,
  cacheAddrBits: cacheAddrBits,
  cacheableBase: cacheableBase,
  reqAddrBits: reqAddrBits,
  memFaultIn: Const(0),
);

void main() {
  tearDown(() async => Simulator.reset());

  for (final bits in [34, 40]) {
    test(
      'a 64-bit cache with $bits physical bits hits, misses and fills',
      () async {
        final dut = await BurstDut.make(
          instruction: false,
          xlen: 64,
          lineSize: _line,
          physical: true,
          physAddrBits: bits,
        );
        addTearDown(() => Simulator.endSimulation());
        expect(dut.cache.input('req_addr').width, bits);
        const a = _base + 3 * _line;
        const hiBit = 1 << 30;
        expect(await dut.read(a), dut.mem.wordAt(a));
        expect(dut.mem.requests, hasLength(1));
        expect(await dut.read(a), dut.mem.wordAt(a));
        expect(dut.mem.requests, hasLength(1));
        // Same index and a different tag: miss, then evict.
        expect(await dut.read(a + 1024), dut.mem.wordAt(a + 1024));
        expect(dut.mem.requests, hasLength(2));
        expect(await dut.read(a), dut.mem.wordAt(a));
        expect(dut.mem.requests, hasLength(3));
        // The top bit of the narrow address is part of the tag.
        expect(await dut.read(a + hiBit), dut.mem.wordAt(a + hiBit));
        expect(dut.mem.requests, hasLength(4));
        expect(dut.mem.requests.last.addr, a + hiBit);
      },
    );
  }

  test('the request port has no bit above the physical width', () {
    final cache = _cache(physAddrBits: 34, snoop: true);
    expect(cache.input('req_addr').width, 34);
    expect(cache.input('inval_addr').width, 34);
    expect(cache.output('mem_addr').width, 64);
  });

  test('tag storage keeps only the physical address bits', () async {
    // 1 KB with 32 B lines puts 10 bits in the offset and index, so a 34-bit
    // range has a 24-bit tag and a 28-bit range has an 18-bit tag.
    Future<int> tagWidth(int? bits, {int? narrow}) async {
      final cache = _cache(
        physAddrBits: bits,
        cacheAddrBits: narrow,
        cacheableBase: narrow == null ? 0x80000000 : 0,
      );
      await cache.build();
      final sv = cache.dumpSystemVerilog();
      final m = RegExp(
        r'logic\s*(?:\[(\d+):0\])?\s*l1d_tags_wr_data\b',
      ).firstMatch(sv);
      expect(m, isNotNull, reason: sv);
      await Simulator.reset();
      return m!.group(1) == null ? 1 : int.parse(m.group(1)!) + 1;
    }

    expect(await tagWidth(34), 24);
    expect(await tagWidth(null), 54);
    expect(await tagWidth(32, narrow: 28), 18);
  });

  test('a narrow snoop drops a resident line', () async {
    final dut = await BurstDut.make(
      instruction: false,
      xlen: 64,
      lineSize: _line,
      physical: true,
      snoop: true,
      physAddrBits: 34,
    );
    addTearDown(() => Simulator.endSimulation());
    expect(dut.cache.input('inval_addr').width, 34);
    const a = _base + 3 * _line;
    await dut.read(a);
    dut.mem.writeValue(a, 3, BigInt.from(0x1234));
    dut.drive('inval_valid', 1);
    dut.drive('inval_addr', a);
    await dut.step();
    dut.drive('inval_valid', 0);
    await dut.steps(3);
    expect(await dut.read(a), BigInt.from(0x1234));
    expect(dut.mem.requests, hasLength(2));
  });

  test(
    'a 32-bit bus with a 28-bit cacheable range bypasses above it',
    () async {
      final dut = await BurstDut.make(
        instruction: false,
        xlen: 64,
        lineSize: _line,
        physical: true,
        physAddrBits: 32,
        cacheAddrBits: 28,
        cacheableBase: 0,
      );
      addTearDown(() => Simulator.endSimulation());
      expect(dut.cache.input('req_addr').width, 32);
      const a = 0x100;
      const alias = 0x10000100;
      expect(await dut.read(a), dut.mem.wordAt(a));
      expect(dut.mem.requests, hasLength(1));
      expect(dut.mem.requests.last.len, greaterThan(0));
      // Same index and same 28-bit tag: it must not hit the line of [a].
      expect(await dut.read(alias), dut.mem.wordAt(alias));
      expect(dut.mem.requests, hasLength(2));
      expect(dut.mem.requests.last, (
        addr: alias,
        len: 0,
        write: false,
        size: 3,
      ));
      expect(await dut.read(alias), dut.mem.wordAt(alias));
      expect(dut.mem.requests, hasLength(3));
      // The line of [a] is still resident, and a store above the range does
      // not write into it.
      expect(await dut.write(alias, 3, BigInt.from(0xdead)), isTrue);
      final before = dut.mem.requests.length;
      expect(await dut.read(a), dut.mem.wordAt(a));
      expect(dut.mem.requests, hasLength(before));
      expect(dut.mem.wordAt(alias), BigInt.from(0xdead));
    },
  );

  Future<BurstDut> narrow({bool snoop = false}) async {
    final dut = await BurstDut.make(
      instruction: false,
      xlen: 64,
      lineSize: _line,
      physical: true,
      snoop: snoop,
      physAddrBits: 32,
      cacheAddrBits: 28,
      cacheableBase: 0,
    );
    addTearDown(() => Simulator.endSimulation());
    return dut;
  }

  test('a store to a resident in-range line hits in a narrow cache', () async {
    final dut = await narrow();
    const a = 0x100;
    await dut.read(a);
    expect(await dut.write(a, 3, BigInt.from(0xbeef)), isTrue);
    final before = dut.mem.requests.length;
    expect(await dut.read(a), BigInt.from(0xbeef));
    expect(dut.mem.requests, hasLength(before));
  });

  test('the top line of the cacheable range fills and hits', () async {
    final dut = await narrow();
    const top = (1 << 28) - _line;
    expect(await dut.read(top), dut.mem.wordAt(top));
    expect(dut.mem.requests, hasLength(1));
    expect(dut.mem.requests.single.addr, top);
    expect(dut.mem.requests.single.len, greaterThan(0));
    expect(await dut.read(top + 8), dut.mem.wordAt(top + 8));
    expect(dut.mem.requests, hasLength(1));
  });

  test('a snoop above the cacheable range drops the aliased line', () async {
    final dut = await narrow(snoop: true);
    const a = 0x100;
    await dut.read(a);
    dut.drive('inval_valid', 1);
    dut.drive('inval_addr', a + (1 << 28));
    await dut.step();
    dut.drive('inval_valid', 0);
    await dut.steps(3);
    await dut.read(a);
    expect(dut.mem.requests, hasLength(2));
  });

  group('validation', () {
    test('reqAddrBits that differs from the physical width throws', () {
      expect(
        () => _cache(physAddrBits: 34, reqAddrBits: 40),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Physical cache tags must retain all 34'),
          ),
        ),
      );
      expect(() => _cache(reqAddrBits: 63), throwsArgumentError);
    });
    test('a derived cacheAddrBits is named in the error', () {
      expect(
        () => _cache(physAddrBits: 10, cacheableBase: 0),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('from physAddrBits'),
          ),
        ),
      );
    });
    test('physAddrBits needs physical addresses', () {
      expect(
        () => _cache(physical: false, physAddrBits: 34),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('need physicalAddresses'),
          ),
        ),
      );
    });
    test('physAddrBits must lie between the index bits and xlen', () {
      expect(() => _cache(physAddrBits: 65), throwsArgumentError);
      expect(() => _cache(physAddrBits: 0), throwsArgumentError);
      expect(() => _cache(physAddrBits: 10), throwsArgumentError);
      expect(() => _cache(physAddrBits: 11, cacheableBase: 0), returnsNormally);
      expect(
        () => _cache(physAddrBits: 32, cacheAddrBits: 33),
        throwsArgumentError,
      );
    });
    test('cacheableBase must lie inside the cacheable range', () {
      expect(
        () => _cache(physAddrBits: 32, cacheAddrBits: 28),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('outside the 28-bit cacheable range'),
          ),
        ),
      );
      expect(
        () => _cache(physAddrBits: 32, cacheAddrBits: 28, cacheableBase: 0),
        returnsNormally,
      );
    });
  });
}
