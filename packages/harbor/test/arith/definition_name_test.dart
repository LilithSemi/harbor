import 'package:harbor/src/arith/fp_format.dart';
import 'package:harbor/src/arith/fpu.dart';
import 'package:harbor/src/arith/fpu_config.dart';
import 'package:harbor/src/arith/vector_lane.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _fp16 = HarborFpFormat.fp16;
const _fp32 = HarborFpFormat.fp32;
const _fp64 = HarborFpFormat.fp64;

/// Every `definitionName` in [m]'s hierarchy, [m] itself included.
Set<String> _names(Module m) => {
  m.definitionName,
  for (final s in m.subModules) ..._names(s),
};

HarborFpuConfig _scalar({
  List<HarborFpFormat> formats = const [_fp32],
  Set<HarborFpOp> ops = const {HarborFpOp.add, HarborFpOp.mul},
  int stages = 2,
  bool ftz = false,
  int divRadix = 2,
  List<int> intWidths = const [],
}) => HarborFpuConfig(
  formats: formats,
  ops: ops,
  stages: stages,
  ftz: ftz,
  divRadix: divRadix,
  intWidths: intWidths,
);

HarborFpuConfig _narrowLane() => HarborFpuConfig(
  formats: [_fp16, _fp32],
  widening: [(_fp16, _fp32)],
  ops: const {HarborFpOp.madd},
  stages: 2,
  mulFormats: const {},
);

void main() {
  group('HarborFpu definitionName', () {
    test('two builds of the same config give the same names', () async {
      final a = HarborFpu(_scalar());
      final other = HarborFpu(_scalar(ftz: true)); // built in between
      final b = HarborFpu(_scalar());
      await a.build();
      await other.build();
      await b.build();
      expect(a.definitionName, b.definitionName);
      expect(_names(a), _names(b));
    });

    test('different configs give different names', () async {
      final base = HarborFpu(_scalar());
      final diffFormat = HarborFpu(_scalar(formats: const [_fp64]));
      final diffOps = HarborFpu(_scalar(ops: const {HarborFpOp.add}));
      final diffStages = HarborFpu(_scalar(stages: 3));
      final diffFtz = HarborFpu(_scalar(ftz: true));
      final diffDivRadix = HarborFpu(
        _scalar(ops: const {HarborFpOp.div}, divRadix: 4),
      );
      final diffIntWidths = HarborFpu(
        _scalar(ops: const {HarborFpOp.fpToInt}, intWidths: const [32]),
      );
      final diffTagWidth = HarborFpu(_scalar(), tagWidth: 4);
      final variants = [
        diffFormat,
        diffOps,
        diffStages,
        diffFtz,
        diffDivRadix,
        diffIntWidths,
        diffTagWidth,
      ];
      for (final v in variants) {
        await v.build();
      }
      await base.build();
      final names = [base, ...variants].map((m) => m.definitionName).toList();
      expect(names.toSet().length, names.length);
    });

    test('divRadix alone changes the name', () async {
      final r2 = HarborFpu(_scalar(ops: const {HarborFpOp.div}));
      final r4 = HarborFpu(_scalar(ops: const {HarborFpOp.div}, divRadix: 4));
      await r2.build();
      await r4.build();
      expect(r2.definitionName, isNot(r4.definitionName));
    });
  });

  group('HarborVectorLane definitionName', () {
    test('two builds of the same config give the same names', () async {
      final a = HarborVectorLane(
        _narrowLane(),
        liveSew: true,
        packNarrow: true,
      );
      final other = HarborVectorLane(_scalar(), liveSew: false);
      final b = HarborVectorLane(
        _narrowLane(),
        liveSew: true,
        packNarrow: true,
      );
      await a.build();
      await other.build();
      await b.build();
      expect(a.definitionName, b.definitionName);
      expect(_names(a), _names(b));
    });

    test('different configs give different names', () async {
      final base = HarborVectorLane(
        _narrowLane(),
        liveSew: true,
        packNarrow: true,
      );
      final noPack = HarborVectorLane(_narrowLane(), liveSew: true);
      final noSew = HarborVectorLane(_narrowLane());
      final tagged = HarborVectorLane(
        _narrowLane(),
        liveSew: true,
        packNarrow: true,
        tagWidth: 4,
      );
      final variants = [noPack, noSew, tagged];
      for (final v in variants) {
        await v.build();
      }
      await base.build();
      final names = [base, ...variants].map((m) => m.definitionName).toList();
      expect(names.toSet().length, names.length);
    });
  });
}
