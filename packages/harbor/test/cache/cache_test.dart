import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  group('HarborCacheConfig', () {
    test('basic properties', () {
      const cache = HarborCacheConfig(size: 32 * 1024, ways: 4);
      expect(cache.sets, equals(128)); // 32KB / (64B * 4)
      expect(cache.lines, equals(512)); // 32KB / 64B
      expect(cache.indexBits, equals(7));
      expect(cache.offsetBits, equals(6));
      expect(cache.isDirectMapped, isFalse);
    });

    test('direct-mapped', () {
      const cache = HarborCacheConfig(size: 4096, ways: 1);
      expect(cache.isDirectMapped, isTrue);
      expect(cache.sets, equals(64));
    });

    test('fully associative', () {
      const cache = HarborCacheConfig(size: 4096, lineSize: 64, ways: 64);
      expect(cache.isFullyAssociative, isTrue);
      expect(cache.sets, equals(1));
    });

    test('toPrettyString', () {
      const cache = HarborCacheConfig(
        size: 256 * 1024,
        ways: 8,
        writePolicy: HarborWritePolicy.writeBack,
      );
      final pretty = cache.toPrettyString();
      expect(pretty, contains('256 KB'));
      expect(pretty, contains('ways: 8'));
      expect(pretty, contains('writeBack'));
    });
  });

  group('HarborL1CacheConfig', () {
    test('split I/D', () {
      final l1 = HarborL1CacheConfig.split(
        iSize: 32 * 1024,
        dSize: 32 * 1024,
        ways: 4,
      );
      expect(l1.isUnified, isFalse);
      expect(l1.i, isNotNull);
      expect(l1.i!.size, equals(32 * 1024));
      expect(
        l1.d,
        isA<HarborL1dCacheConfig>().having((d) => d.size, 'size', 32 * 1024),
      );
    });

    test('unified', () {
      const l1 = HarborL1CacheConfig.unified(
        HarborL1dCacheConfig(size: 64 * 1024, ways: 4),
      );
      expect(l1.isUnified, isTrue);
      expect(l1.i, isNull);
    });
  });

  group('HarborCacheHierarchy', () {
    test('single level', () {
      final h = HarborCacheHierarchy(
        l1: HarborL1CacheConfig.split(iSize: 32768, dSize: 32768, ways: 4),
      );
      expect(h.levels, equals(1));
      expect(h.isCoherent, isFalse);
    });

    test('two levels', () {
      final h = HarborCacheHierarchy(
        l1: HarborL1CacheConfig.split(iSize: 32768, dSize: 32768, ways: 4),
        l2: const HarborCacheConfig(size: 256 * 1024, ways: 8),
      );
      expect(h.levels, equals(2));
    });

    test('three levels with coherency', () {
      final h = HarborCacheHierarchy(
        l1: HarborL1CacheConfig.split(iSize: 32768, dSize: 32768, ways: 8),
        l2: const HarborCacheConfig(size: 256 * 1024, ways: 8),
        l3: const HarborCacheConfig(size: 4 * 1024 * 1024, ways: 16),
        coherency: const HarborCoherencyConfig(
          protocol: HarborCoherencyProtocol.mesi,
          l2Sharing: HarborCacheSharing.perCore,
          l3Sharing: HarborCacheSharing.shared,
        ),
      );
      expect(h.levels, equals(3));
      expect(h.isCoherent, isTrue);
      expect(h.coherency.protocol, equals(HarborCoherencyProtocol.mesi));
      expect(h.coherency.l2Sharing, equals(HarborCacheSharing.perCore));
      expect(h.coherency.l3Sharing, equals(HarborCacheSharing.shared));
    });

    test('toPrettyString shows hierarchy', () {
      final h = HarborCacheHierarchy(
        l1: HarborL1CacheConfig.split(iSize: 32768, dSize: 32768, ways: 4),
        l2: const HarborCacheConfig(size: 256 * 1024, ways: 8),
        coherency: const HarborCoherencyConfig(
          protocol: HarborCoherencyProtocol.moesi,
          directoryBased: true,
        ),
      );
      final pretty = h.toPrettyString();
      expect(pretty, contains('L1:'));
      expect(pretty, contains('L2'));
      expect(pretty, contains('moesi'));
      expect(pretty, contains('directory-based'));
    });
  });

  group('HarborCoherencyProtocol', () {
    test('all protocols', () {
      expect(HarborCoherencyProtocol.values, hasLength(4));
      expect(HarborCoherencyProtocol.none.name, equals('none'));
      expect(HarborCoherencyProtocol.msi.name, equals('msi'));
      expect(HarborCoherencyProtocol.mesi.name, equals('mesi'));
      expect(HarborCoherencyProtocol.moesi.name, equals('moesi'));
    });
  });

  group('HarborCacheLineState', () {
    test('MOESI states', () {
      expect(HarborCacheLineState.values, hasLength(5));
      expect(HarborCacheLineState.invalid.name, equals('invalid'));
      expect(HarborCacheLineState.modified.name, equals('modified'));
      expect(HarborCacheLineState.owned.name, equals('owned'));
    });
  });

  group('HarborReplacementPolicy', () {
    test('all policies', () {
      expect(HarborReplacementPolicy.values, hasLength(4));
    });
  });
}
