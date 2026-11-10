import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _targets = {
  'ECP5': HarborFpgaTarget.ecp5(device: 'lfe5u-25f', package: 'CABGA256'),
  'iCE40': HarborFpgaTarget.ice40(device: 'up5k', package: 'sg48'),
  'Xilinx': HarborFpgaTarget.artix7(device: 'xc7a35t', package: 'csg324'),
};

/// Block RAMs in the tag store [name] of [cache].
int _tagBlocks(Module cache, String name) => cache.subModules
    .firstWhere((m) => m.name == name)
    .subModules
    .where(
      (m) => m is Ecp5Dp16kd || m is Ice40SbRam40_4kNR || m is XilinxRamb36e1,
    )
    .length;

void main() {
  tearDown(() async => Simulator.reset());

  for (final MapEntry(key: name, value: target) in _targets.entries) {
    // 256 lines with a 12-bit index and offset: the tag store holds
    // 256 * (reqAddrBits - 12) bits.
    for (final reqAddrBits in [28, 29]) {
      final inRam = name == 'Xilinx' || reqAddrBits == 29;
      test('$name ${256 * (reqAddrBits - 12)}-bit I-cache tag store '
          '${inRam ? 'uses block RAM' : 'stays in flops'}', () async {
        final cache = HarborL1ICache(
          config: HarborL1iCacheConfig(size: 4096, ways: 1, lineSize: 16),
          xlen: 32,
          reqAddrBits: reqAddrBits,
          target: target,
        );
        await cache.build();
        expect(_tagBlocks(cache, 'l1i_tags') > 0, inRam);
      });
    }

    for (final size in [4096, 16384]) {
      final inRam = name == 'Xilinx' || size == 16384;
      test('$name $size-byte RV32 D-cache tag store '
          '${inRam ? 'uses block RAM' : 'stays in flops'}', () async {
        final cache = HarborL1DCache(
          config: HarborL1dCacheConfig(size: size, ways: 1, lineSize: 64),
          xlen: 32,
          physicalAddresses: true,
          memFaultIn: Logic(),
          target: target,
        );
        await cache.build();
        expect(_tagBlocks(cache, 'l1d_tags') > 0, inRam);
      });
    }
  }

  test('Delta RV64 tiny I/D tag stores use Xilinx block RAM', () async {
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
    expect(_tagBlocks(icache, 'l1i_tags'), greaterThan(0));
    expect(_tagBlocks(dcache, 'l1d_tags'), greaterThan(0));
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
