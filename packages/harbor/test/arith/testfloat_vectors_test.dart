import 'dart:io';

import 'package:test/test.dart';

import 'testfloat_vectors.dart';

/// Tests for the [testFloatCases] loader, not the arithmetic itself.
void main() {
  final skipReason = testFloatAvailable()
      ? null
      : 'testfloat_gen not found; set HARBOR_TESTFLOAT_GEN or run inside '
            '`nix develop`';
  final procSkipReason =
      skipReason ??
      (Platform.isLinux ? null : 'this check reads /proc, Linux only');

  test('f32_add RNE cases have the expected field widths', () async {
    final cases = await testFloatCases(
      'f32_add',
      rm: 'near_even',
    ).take(1000).toList();

    expect(cases.length, 1000);
    for (final c in cases) {
      expect(c.operands.length, 2);
      for (final operand in c.operands) {
        expect(operand, greaterThanOrEqualTo(BigInt.zero));
        expect(operand, lessThanOrEqualTo(BigInt.parse('FFFFFFFF', radix: 16)));
      }
      expect(c.result, greaterThanOrEqualTo(BigInt.zero));
      expect(c.result, lessThanOrEqualTo(BigInt.parse('FFFFFFFF', radix: 16)));
      expect(c.flags, greaterThanOrEqualTo(0));
      expect(c.flags, lessThanOrEqualTo(0x1F));
    }
  }, skip: skipReason);

  test('f32_add RNE includes the known 1.0 + 1.0 case', () async {
    final one = BigInt.parse('3F800000', radix: 16);
    final two = BigInt.parse('40000000', radix: 16);

    final known = await testFloatCases(
      'f32_add',
      rm: 'near_even',
    ).firstWhere((c) => c.operands[0] == one && c.operands[1] == one);

    expect(known.result, two);
    expect(known.flags, 0);
  }, skip: skipReason);

  test('a stride samples every nth case instead of a prefix', () async {
    final full = await testFloatCases(
      'f32_add',
      rm: 'near_even',
    ).take(20).toList();
    final strided = await testFloatCases(
      'f32_add',
      rm: 'near_even',
      stride: 5,
    ).take(4).toList();

    expect(
      strided.map((c) => c.toString()),
      [full[0], full[5], full[10], full[15]].map((c) => c.toString()),
    );
  }, skip: skipReason);

  test(
    'cancelling the stream early kills the testfloat_gen process',
    () async {
      Process? started;
      await testFloatCases(
        'f32_add',
        rm: 'near_even',
        onStart: (p) => started = p,
      ).take(10).toList();
      final pid = started!.pid;

      // testfloat_gen can take a moment to exit after the kill signal, so
      // poll. Checking /proc for this exact pid, not pgrep by name, keeps
      // another running testfloat_gen from changing this test's result.
      var stillRunning = true;
      for (var i = 0; i < 20 && stillRunning; i++) {
        stillRunning = Directory('/proc/$pid').existsSync();
        if (stillRunning) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      expect(
        stillRunning,
        isFalse,
        reason:
            'testfloat_gen (pid $pid) kept running after the stream was '
            'cancelled',
      );
    },
    skip: procSkipReason,
  );
}
