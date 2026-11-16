import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'l1_burst_bench.dart';

const _targets = {
  'ECP5': HarborFpgaTarget.ecp5(device: 'lfe5u-25f', package: 'CABGA256'),
  'iCE40': HarborFpgaTarget.ice40(device: 'up5k', package: 'sg48'),
  'Xilinx': HarborFpgaTarget.artix7(device: 'xc7a35t', package: 'csg324'),
};

/// Storage of the tag store [name] of [cache]: 'lutram', 'bram' or 'flops'.
String _tagKind(Module cache, String name) {
  if (cache.subModules.any((m) => m.name == '${name}_lutram')) return 'lutram';
  final blocks = cache.subModules
      .firstWhere((m) => m.name == name)
      .subModules
      .where(
        (m) => m is Ecp5Dp16kd || m is Ice40SbRam40_4kNR || m is XilinxRamb36e1,
      );
  return blocks.isEmpty ? 'flops' : 'bram';
}

void main() {
  tearDown(() async => Simulator.reset());

  for (final MapEntry(key: name, value: target) in _targets.entries) {
    // 256 lines with a 12-bit index and offset: the tag store holds
    // 256 * (reqAddrBits - 12) bits.
    for (final reqAddrBits in [28, 29]) {
      // Only the iCE40 keeps a small store in flops. 256 lines are too many
      // for LUT RAM.
      final kind = name == 'iCE40' && reqAddrBits == 28 ? 'flops' : 'bram';
      test('$name ${256 * (reqAddrBits - 12)}-bit I-cache tag store '
          'uses $kind', () async {
        final cache = HarborL1ICache(
          config: HarborL1iCacheConfig(size: 4096, ways: 1, lineSize: 16),
          xlen: 32,
          reqAddrBits: reqAddrBits,
          target: target,
        );
        await cache.build();
        expect(_tagKind(cache, 'l1i_tags'), kind);
      });
    }

    for (final size in [4096, 16384]) {
      // 4 KiB has 64 lines, 16 KiB has 256.
      final kind = size == 16384
          ? 'bram'
          : name == 'iCE40'
          ? 'flops'
          : 'lutram';
      test('$name $size-byte RV32 D-cache tag store uses $kind', () async {
        final cache = HarborL1DCache(
          config: HarborL1dCacheConfig(size: size, ways: 1, lineSize: 64),
          xlen: 32,
          physicalAddresses: true,
          memFaultIn: Logic(),
          target: target,
        );
        await cache.build();
        expect(_tagKind(cache, 'l1d_tags'), kind);
      });
    }
  }

  for (final instruction in [true, false]) {
    test('ECP5 ${instruction ? 'I' : 'D'}-cache with LUT RAM tags hits and '
        'misses', () async {
      final dut = await BurstDut.make(
        instruction: instruction,
        xlen: 64,
        lineSize: 64,
        size: 4096,
        physical: true,
        snoop: !instruction,
        target: _targets['ECP5'],
      );
      expect(
        _tagKind(dut.cache, instruction ? 'l1i_tags' : 'l1d_tags'),
        'lutram',
      );
      const a = 0x80000040;
      const b = a + 4096;
      expect(await dut.read(a), dut.mem.wordAt(a));
      expect(await dut.read(a + 8), dut.mem.wordAt(a + 8));
      expect(dut.mem.requests, hasLength(1));
      expect(await dut.read(b), dut.mem.wordAt(b));
      expect(await dut.read(a), dut.mem.wordAt(a));
      expect(dut.mem.requests, hasLength(3));
      if (!instruction) {
        expect(await dut.write(a + 8, 3, BigInt.from(0x1234)), isTrue);
        expect(await dut.read(a + 8), BigInt.from(0x1234));
        expect(dut.mem.requests, hasLength(4));
        dut.mem.writeValue(a, 3, BigInt.from(0x77));
        dut.drive('inval_valid', 1);
        dut.drive('inval_addr', a);
        await dut.step();
        dut.drive('inval_valid', 0);
        await dut.steps(3);
        expect(await dut.read(a), BigInt.from(0x77));
        expect(dut.mem.requests, hasLength(5));
      }
      await Simulator.endSimulation();
    });
  }

  test('Delta RV64 tiny I/D tag stores use Xilinx LUT RAM', () async {
    final target = HarborFpgaTarget.spartan7(
      device: 'xc7s50',
      package: 'csga324',
      useOpenXc7: true,
      useHimbaechel: true,
    );
    final icache = HarborL1ICache(
      config: HarborL1iCacheConfig(size: 64, ways: 1, lineSize: 8),
      xlen: 64,
      reqAddrBits: 64,
      target: target,
    );
    final dcache = HarborL1DCache(
      config: HarborL1dCacheConfig(size: 256, ways: 1, lineSize: 8),
      xlen: 64,
      reqAddrBits: 64,
      physicalAddresses: true,
      memFaultIn: Logic(),
      target: target,
    );
    await icache.build();
    await dcache.build();
    expect(_tagKind(icache, 'l1i_tags'), 'lutram');
    expect(_tagKind(dcache, 'l1d_tags'), 'lutram');
  });

  for (final MapEntry(key: name, value: target) in _targets.entries) {
    for (final xlen in [32, 64]) {
      for (final size in [1024, 4096]) {
        test('$name RV$xlen $size-byte D-cache emits SV', () async {
          final cache = HarborL1DCache(
            config: HarborL1dCacheConfig(size: size, ways: 1, lineSize: 16),
            xlen: xlen,
            ctxBits: 2,
            memFaultIn: Logic(),
            target: target,
          );
          await cache.build();
          expect(cache.dumpSystemVerilog(), contains('HarborL1DCache'));
        });
        for (final dualPort in [false, true]) {
          final ports = dualPort ? 'dual-port' : 'single-port';
          test('$name RV$xlen $size-byte $ports I-cache emits SV', () async {
            final cache = HarborL1ICache(
              config: HarborL1iCacheConfig(size: size, ways: 1, lineSize: 16),
              xlen: xlen,
              ctxBits: 2,
              dualPort: dualPort,
              target: target,
            );
            await cache.build();
            expect(cache.dumpSystemVerilog(), contains('HarborL1ICache'));
          });
        }
      }
    }

    test('$name RV32 16 KiB physical D-cache emits SV', () async {
      final cache = HarborL1DCache(
        config: HarborL1dCacheConfig(size: 16384, ways: 1, lineSize: 64),
        xlen: 32,
        physicalAddresses: true,
        memFaultIn: Logic(),
        target: target,
      );
      await cache.build();
      expect(cache.dumpSystemVerilog(), contains('HarborL1DCache'));
    });
  }
}
