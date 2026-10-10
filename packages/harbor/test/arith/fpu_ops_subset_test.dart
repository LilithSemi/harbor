import 'dart:math';

import 'package:harbor/src/arith/fp_format.dart';
import 'package:harbor/src/arith/fpu.dart';
import 'package:harbor/src/arith/fpu_config.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'fpu_bench.dart';

const _fp16 = HarborFpFormat.fp16;
const _fp32 = HarborFpFormat.fp32;

const _subsetOps = {HarborFpOp.madd, HarborFpOp.intToFp, HarborFpOp.fpToInt};

HarborFpuConfig _config(Set<HarborFpOp> ops, int n) => HarborFpuConfig(
  formats: [_fp16, _fp32],
  widening: [(_fp16, _fp32)],
  ops: ops,
  stages: n,
  intWidths: [32],
);

Set<String> _definitions(Module m) => {
  for (final s in m.subModules) ...{s.definitionName, ..._definitions(s)},
};

void main() {
  group('ops {madd, intToFp, fpToInt}, fp16 and fp32 widening', () {
    test('builds no div port and no misc or estimate logic', () async {
      final dut = HarborFpu(_config(_subsetOps, 2), tagWidth: 4);
      await dut.build();
      expect(dut.hasDiv, isFalse);
      final ports = [...dut.inputs.keys, ...dut.outputs.keys];
      expect(ports.where((p) => p.startsWith('div_')), isEmpty);
      // madd reads a, b and c; intToFp and fpToInt read the int fields. No
      // op reads in_fmt_dst or in_li_index.
      expect(ports.toSet(), {
        'clk',
        'reset',
        'in_valid',
        'in_op',
        'in_fmt',
        'in_fmt_narrow',
        'in_rm',
        'in_a',
        'in_b',
        'in_c',
        'in_int_signed',
        'in_int_width',
        'in_tag',
        'out_ready',
        'kill_mask',
        'in_ready',
        'out_valid',
        'out_result',
        'out_flags',
        'out_tag',
        'slot_valid',
        'slot_tag',
      });
      final defs = _definitions(dut);
      bool built(String prefix) => defs.any((d) => d.startsWith(prefix));
      expect(built('HarborFpFmaPath'), isTrue);
      expect(built('HarborFpConvertPath'), isTrue);
      expect(built('HarborFpMiscPath'), isFalse);
      expect(built('HarborFpEstimate'), isFalse);
      expect(defs.where((d) => d.startsWith('HarborDivSqrt')), isEmpty);

      final sv = dut.generateSynth();
      expect(sv, isNot(contains('HarborFpMiscPath')));
      expect(sv, isNot(contains('div_in')));
      final full = HarborFpu(
        _config(HarborFpOp.values.toSet().difference({HarborFpOp.cvtModWD}), 2),
        tagWidth: 4,
      );
      await full.build();
      final fullSv = full.generateSynth();
      expect(sv.length, lessThan(fullSv.length * 0.8));
    });

    test('N=0 sweep in LaneSim matches the model', () async {
      final config = _config(_subsetOps, 0);
      final dut = HarborFpu(config, tagWidth: 4);
      await dut.build();
      final d = LaneDriver(dut)
        ..putMask('reset', 0)
        ..putMask('in_valid', -1)
        ..putMask('out_ready', -1);
      final r = Random(1);
      var narrow = 0;
      for (var batch = 0; batch < 300; batch++) {
        final cases = [for (var l = 0; l < 64; l++) mainCase(config, r)];
        for (final name in cases.first.fields.keys) {
          if (!d.has('in_$name')) {
            continue;
          }
          d.put('in_$name', [for (final c in cases) c.fields[name]!]);
        }
        d.eval();
        final res = d.read('out_result');
        final flags = d.read('out_flags');
        for (var l = 0; l < 64; l++) {
          final c = cases[l];
          if (c.label.contains('narrow')) {
            narrow++;
          }
          expect(
            (res[l], flags[l].toInt()),
            (c.expect.bits, c.expect.flags),
            reason: '$c',
          );
        }
      }
      expect(narrow, greaterThan(500));
    });

    test('N=3 clocked, stalls and kill', () async {
      final config = _config(_subsetOps, 3);
      final dut = HarborFpu(config, tagWidth: 12);
      await dut.build();
      final r = Random(2);
      final q = FpuPort(
        '',
        [
          for (var l = 0; l < 64; l++)
            [for (var i = 0; i < 60; i++) mainCase(config, r)],
        ],
        validGap: 0.1,
        slotKillRate: 0.03,
      );
      await runBench(LaneDriver(dut), [q], random: Random(3), flushRate: 0.01);
      var outs = 0;
      for (var l = 0; l < 64; l++) {
        checkLane(q, l, latency: 3);
        outs += q.logs[l].outs.length;
      }
      expect(outs, greaterThan(2000));
    });
  });

  group('other subsets', () {
    test('div and sqrt only build no main pipe', () async {
      final dut = HarborFpu(_config({HarborFpOp.div, HarborFpOp.sqrt}, 2));
      await dut.build();
      expect(dut.hasMain, isFalse);
      expect(dut.inputs.keys.where((p) => p.startsWith('in_')), isEmpty);
      expect(dut.inputs.keys, contains('div_in_valid'));
      expect(dut.divLatency, isNotNull);
    });

    test('ports follow the ops that read them', () async {
      Future<Set<String>> inputs(Set<HarborFpOp> ops) async {
        final dut = HarborFpu(_config(ops, 1));
        await dut.build();
        return dut.inputs.keys.toSet();
      }

      const base = {
        'clk',
        'reset',
        'in_valid',
        'in_op',
        'in_fmt',
        'out_ready',
        'kill_mask',
      };
      expect(await inputs({HarborFpOp.classify}), {...base, 'in_a'});
      expect(await inputs({HarborFpOp.eq}), {...base, 'in_a', 'in_b'});
      expect(await inputs({HarborFpOp.li}), {...base, 'in_li_index'});
      expect(await inputs({HarborFpOp.add}), {
        ...base,
        'in_rm',
        'in_a',
        'in_b',
      });
      expect(await inputs({HarborFpOp.mul}), {
        ...base,
        'in_rm',
        'in_a',
        'in_b',
        'in_fmt_narrow',
      });
      expect(await inputs({HarborFpOp.fpToFp}), {
        ...base,
        'in_rm',
        'in_a',
        'in_fmt_dst',
      });
      expect(await inputs({HarborFpOp.rsqrt7}), {...base, 'in_a'});
      expect(await inputs({HarborFpOp.sqrt}), {
        'clk',
        'reset',
        'div_in_valid',
        'div_in_fmt',
        'div_in_rm',
        'div_in_a',
        'div_out_ready',
        'div_kill_mask',
      });
    });

    test('one path each', () async {
      final cases = {
        HarborFpOp.classify: 'HarborFpMiscPath',
        HarborFpOp.rsqrt7: 'HarborFpEstimate',
        HarborFpOp.li: 'HarborFpConvertPath',
        HarborFpOp.add: 'HarborFpFmaPath',
      };
      const paths = {
        'HarborFpMiscPath',
        'HarborFpEstimate',
        'HarborFpConvertPath',
        'HarborFpFmaPath',
      };
      for (final e in cases.entries) {
        final dut = HarborFpu(_config({e.key}, 1));
        await dut.build();
        final defs = _definitions(dut);
        final matched = {
          for (final p in paths)
            if (defs.any((d) => d.startsWith(p))) p,
        };
        expect(matched, {e.value});
        expect(dut.hasDiv, isFalse);
      }
    });

    test('an empty op set is rejected', () {
      expect(() => HarborFpu(_config({}, 0)), throwsArgumentError);
    });
  });
}
