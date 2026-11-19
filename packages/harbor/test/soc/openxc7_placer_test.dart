import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  test('the Himbaechel Makefile places with the static placer', () {
    final target = HarborBoard.get('kc705').fpgaTarget(useHimbaechel: true);
    final makefile = target.generateMakefile('soc');
    expect(makefile, contains('PLACER ?= static\n'));
    expect(makefile, contains('--placer \$(PLACER)'));
  });

  test('the nextpnr-xilinx Makefile places with the static placer', () {
    final target = HarborBoard.get('kc705').fpgaTarget();
    final makefile = target.generateMakefile('soc');
    expect(makefile, contains('PLACER ?= static\n'));
    expect(makefile, contains('--placer \$(PLACER)'));
  });

  test('the target sets another default placer', () {
    final target = HarborBoard.get(
      'kc705',
    ).fpgaTarget(useHimbaechel: true, placer: 'heap');
    expect(target.generateMakefile('soc'), contains('PLACER ?= heap\n'));
  });
}
