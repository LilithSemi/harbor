// HarborKeyframeDecodeHorzVert builds two HarborInvTxfm siblings (tx84/tx48,
// txSize 6 and 5) and two HarborIntraPredRect siblings (pred84/pred48, 8x4
// and 4x8). Before each carried its size in its definitionName, the two
// siblings of each class shared one fixed name and ROHD's uniquifier refused
// the second as a reserved-name clash.

import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a default HarborKeyframeDecodeHorzVert generates SV (no reserved-name '
    'clash between its tx84/tx48 and pred84/pred48 siblings)',
    () async {
      final dut = HarborKeyframeDecodeHorzVert();
      await dut.build();
      final sv = dut.generateSynth();

      for (final prefix in ['HarborInvTxfm', 'HarborIntraPredRect']) {
        final names = RegExp('module ($prefix\\w*)')
            .allMatches(sv)
            .map((m) => m.group(1))
            .toSet();
        expect(
          names.length,
          greaterThanOrEqualTo(2),
          reason: '$prefix should emit a distinct module per sibling shape',
        );
      }
    },
  );

  test(
    'a default HarborKeyframeDecodeHorzVertYuv generates SV (same sibling '
    'shapes, luma + chroma)',
    () async {
      final dut = HarborKeyframeDecodeHorzVertYuv();
      await dut.build();
      final sv = dut.generateSynth();

      for (final prefix in ['HarborInvTxfm', 'HarborIntraPredRect']) {
        final names = RegExp('module ($prefix\\w*)')
            .allMatches(sv)
            .map((m) => m.group(1))
            .toSet();
        expect(
          names.length,
          greaterThanOrEqualTo(2),
          reason: '$prefix should emit a distinct module per sibling shape',
        );
      }
    },
  );
}
