import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

String _pnrLine(String mk) =>
    mk.split('\n').firstWhere((l) => l.contains('nextpnr-ecp5'));

void main() {
  group('ecp5 speed grade', () {
    test('ulx3s-85f defaults to grade 6 and passes --speed 6', () {
      final board = HarborBoard.get('ulx3s-85f');
      expect(board.speedGrade, '6');
      final mk = board.fpgaTarget().generateMakefile('Top');
      expect(_pnrLine(mk), contains('--speed 6'));
    });

    test('ulx3s-85f:8 gives grade 8 and passes --speed 8', () {
      final board = HarborBoard.get('ulx3s-85f:8');
      expect(board.speedGrade, '8');
      final mk = board.fpgaTarget().generateMakefile('Top');
      expect(_pnrLine(mk), contains('--speed 8'));
    });

    test('a bare ecp5 target defaults to grade 6', () {
      const t = HarborFpgaTarget.ecp5(device: 'lfe5u-45f', package: 'CABGA381');
      expect(t.speedGrade, '6');
      expect(t.generateNextpnrCommand('Top'), contains('--speed 6'));
    });

    test('an invalid ecp5 grade throws', () {
      expect(() => HarborBoard.get('ulx3s-85f:5'), throwsArgumentError);
      expect(() => HarborBoard.get('ulx3s-85f:9'), throwsArgumentError);
      expect(() => HarborBoard.get('ulx3s-85f:'), throwsArgumentError);
      expect(() => HarborBoard.get('ulx3s-85f:2L'), throwsArgumentError);
      const t = HarborFpgaTarget.ecp5(
        device: 'lfe5u-45f',
        package: 'CABGA381',
        speedGrade: '3',
      );
      expect(() => t.generateNextpnrCommand('Top'), throwsArgumentError);
      expect(() => t.generateMakefile('Top'), throwsArgumentError);
    });

    test('an unknown preset with a suffix throws', () {
      expect(() => HarborBoard.get('nope:8'), throwsArgumentError);
    });

    test('the suffix round-trips through the name', () {
      final board = HarborBoard.get('ulx3s-85f:8');
      expect(board.name, 'ulx3s-85f:8');
      expect(HarborBoard.get(board.name).speedGrade, '8');
      expect(HarborBoard.get('ulx3s-85f:6').speedGrade, '6');
    });
  });

  group('xilinx speed grade', () {
    test('kc705 and arty PART strings are unchanged', () {
      expect(
        HarborBoard.get('kc705').fpgaTarget().generateMakefile('Top'),
        contains('PART ?= \$(DEVICE)\$(PACKAGE)-2'),
      );
      expect(
        HarborBoard.get('arty-s7-50').fpgaTarget().generateMakefile('Top'),
        contains('PART ?= \$(DEVICE)\$(PACKAGE)-1'),
      );
    });

    test('the suffix overrides a xilinx grade and rejects a bad one', () {
      expect(HarborBoard.get('kc705:3').speedGrade, '3');
      expect(() => HarborBoard.get('kc705:9'), throwsArgumentError);
      expect(() => HarborBoard.get('kc705:x'), throwsArgumentError);
    });
  });

  group('board.zon', () {
    test('ecp5 fpga_part carries the grade and the preset is the base name', () {
      final b = HarborBoard.get('ulx3s-85f:8');
      expect(HarborBoardZonGenerator.fpgaPart(b), 'lfe5u-85f-CABGA381-8');
    });
  });
}
