import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _ecp5 = HarborFpgaTarget.ecp5(device: 'lfe5u-25f', package: 'CABGA256');
const _targets = {
  'ECP5': _ecp5,
  'iCE40': HarborFpgaTarget.ice40(device: 'up5k', package: 'sg48'),
  'Xilinx': HarborFpgaTarget.artix7(device: 'xc7a35t', package: 'csg324'),
};

/// Block RAMs in the tag store [name] of [cache].
int _tagBlocks(Module cache, String name) => cache.subModules
    .firstWhere((m) => m.name == name)
    .subModules
    .whereType<Ecp5Dp16kd>()
    .length;

void main() {
  tearDown(() async => Simulator.reset());

  // 256 lines with a 12-bit index and offset: the tag store holds
  // 256 * (reqAddrBits - 12) bits.
  for (final (reqAddrBits, inRam) in [(28, false), (29, true)]) {
    test('a ${256 * (reqAddrBits - 12)}-bit I-cache tag store '
        '${inRam ? 'uses block RAM' : 'stays in flops'}', () async {
      final cache = HarborL1ICache(
        config: HarborL1iCacheConfig(size: 4096, ways: 1, lineSize: 16),
        xlen: 32,
        reqAddrBits: reqAddrBits,
        target: _ecp5,
      );
      await cache.build();
      expect(256 * (reqAddrBits - 12) > harborL1TagFlopBits, inRam);
      expect(_tagBlocks(cache, 'l1i_tags') > 0, inRam);
    });
  }

  for (final (size, inRam) in [(4096, false), (16384, true)]) {
    test('a $size-byte RV32 D-cache tag store '
        '${inRam ? 'uses block RAM' : 'stays in flops'}', () async {
      final cache = HarborL1DCache(
        config: HarborL1dCacheConfig(size: size, ways: 1, lineSize: 64),
        xlen: 32,
        physicalAddresses: true,
        memFaultIn: Logic(),
        target: _ecp5,
      );
      await cache.build();
      expect(_tagBlocks(cache, 'l1d_tags') > 0, inRam);
    });
  }

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
          expect(cache.generateSynth(), contains('HarborL1DCache'));
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
            expect(cache.generateSynth(), contains('HarborL1ICache'));
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
      expect(cache.generateSynth(), contains('HarborL1DCache'));
    });
  }
}
