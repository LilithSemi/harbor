// HarborIntraReconWalk's per-size loop instantiates HarborIntraPredAvail,
// HarborInvTxfm and HarborReconAdd once per leaf size (4x4/8x8/16x16 by
// default). Before each of those three carried its size/config in its
// definitionName, all three sizes shared one fixed name per class, and ROHD's
// uniquifier refused the second and third size as a reserved-name clash.
// Building even one default HarborIntraReconWalk already hits this, with no
// second caller needed.

import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a default HarborIntraReconWalk generates SV (3 leaf sizes, no '
    'reserved-name clash)',
    () async {
      final walk = HarborIntraReconWalk();
      await walk.build();
      final sv = walk.generateSynth();

      for (final prefix in [
        'HarborIntraPredAvail',
        'HarborInvTxfm',
        'HarborReconAdd',
      ]) {
        final names = RegExp('module ($prefix\\w*)')
            .allMatches(sv)
            .map((m) => m.group(1))
            .toSet();
        expect(
          names.length,
          greaterThanOrEqualTo(3),
          reason: '$prefix should emit one distinct module per leaf size',
        );
      }
    },
  );

  test('HarborIntraPredAvail definitionName varies with bs and bitDepth', () {
    final a = HarborIntraPredAvail(bs: 4);
    final b = HarborIntraPredAvail(bs: 8);
    final c = HarborIntraPredAvail(bs: 4, bitDepth: 10);
    final d = HarborIntraPredAvail(bs: 4);
    expect(a.definitionName, isNot(equals(b.definitionName)));
    expect(a.definitionName, isNot(equals(c.definitionName)));
    expect(a.definitionName, equals(d.definitionName));
  });

  test('HarborInvTxfm definitionName varies with txSize and runtimeTxType', () {
    final a = HarborInvTxfm(txSize: 0, txType: 0, runtimeTxType: true);
    final b = HarborInvTxfm(txSize: 1, txType: 0, runtimeTxType: true);
    final c = HarborInvTxfm(txSize: 0, txType: 0, runtimeTxType: false);
    expect(a.definitionName, isNot(equals(b.definitionName)));
    expect(a.definitionName, isNot(equals(c.definitionName)));
  });

  test('HarborReconAdd definitionName varies with n and bitDepth', () {
    final a = HarborReconAdd(n: 16);
    final b = HarborReconAdd(n: 64);
    final c = HarborReconAdd(n: 16, bitDepth: 10);
    expect(a.definitionName, isNot(equals(b.definitionName)));
    expect(a.definitionName, isNot(equals(c.definitionName)));
  });
}
