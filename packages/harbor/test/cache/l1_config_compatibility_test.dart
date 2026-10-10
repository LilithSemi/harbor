import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  const instruction = HarborL1iCacheConfig(size: 4096, ways: 1, lineSize: 16);
  const data = HarborL1dCacheConfig(size: 2048, ways: 1, lineSize: 16);

  test('explicit split configuration preserves both objects and rendering', () {
    const config = HarborL1CacheConfig(i: instruction, d: data);
    expect(config.i, same(instruction));
    expect(config.d, same(data));
    expect(config.isUnified, isFalse);
    expect(config.toString(), 'L1(I: $instruction, D: $data)');
    expect(config.toPrettyString(), contains('I-cache:'));
    expect(config.toPrettyString(), contains('D-cache:'));
  });

  test('unified configuration preserves geometry and rendering', () {
    const config = HarborL1CacheConfig.unified(data);
    expect(config.i, isNull);
    expect(config.d, same(data));
    expect(config.isUnified, isTrue);
    expect(config.toString(), 'L1(unified: $data)');
    expect(config.toPrettyString(), isNot(contains('I-cache:')));
    expect(config.toPrettyString(), contains('D-cache:'));
  });

  test('general constructor still requires a non-null data cache', () {
    expect(
      () => HarborL1CacheConfig(d: null as dynamic),
      throwsA(isA<TypeError>()),
    );
  });
  test('unified constructor rejects a null cache without assertions', () {
    expect(
      () => HarborL1CacheConfig.unified(null as dynamic),
      throwsA(isA<TypeError>()),
    );
  });
}
