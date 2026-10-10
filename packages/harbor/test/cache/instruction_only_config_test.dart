import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  const instruction = HarborL1iCacheConfig(size: 4096, ways: 1, lineSize: 16);

  test('instruction-only configuration retains I geometry without D', () {
    const config = HarborL1CacheConfig.instructionOnly(instruction);
    expect(config.i, same(instruction));
    expect(config.d, isNull);
    expect(config.isUnified, isFalse);
    expect(config.toString(), 'L1(I: $instruction)');
    expect(config.toPrettyString(), contains('I-cache:'));
    expect(config.toPrettyString(), isNot(contains('D-cache:')));
    final hierarchy = HarborCacheHierarchy(l1: config);
    expect(hierarchy.levels, 1);
    expect(hierarchy.toPrettyString(), contains('I-cache:'));
    expect(hierarchy.toPrettyString(), isNot(contains('D-cache:')));
  });

  test(
    'instruction-only constructor rejects a null cache without assertions',
    () {
      expect(
        () => HarborL1CacheConfig.instructionOnly(null as dynamic),
        throwsA(isA<TypeError>()),
      );
    },
  );
}
