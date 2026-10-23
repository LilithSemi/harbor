import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'csc_reference.dart';

/// Streams [inputs] through a [HarborCsc] with [set], one each clock, and
/// gives the R, G and B of each.
Future<List<List<int>>> _run(
  HarborCscCoefficients set,
  List<List<int>> inputs, {
  HarborDeviceTarget? target,
}) async {
  final clk = SimpleClockGenerator(10).clk;
  final y = Logic(width: 10), cb = Logic(width: 10), cr = Logic(width: 10);
  final coeff = [for (var k = 0; k < 9; k++) Logic(width: 16)];
  final inOff = [for (var j = 0; j < 3; j++) Logic(width: 10)];
  final outOff = [for (var i = 0; i < 3; i++) Logic(width: 8)];
  final csc = HarborCsc(
    clk: clk,
    y: y,
    cb: cb,
    cr: cr,
    coeff: coeff,
    inOffset: inOff,
    outOffset: outOff,
    target: target,
  );
  await csc.build();
  final regs = set.registers();
  for (var k = 0; k < 9; k++) {
    coeff[k].inject(regs[k]);
  }
  for (var j = 0; j < 3; j++) {
    inOff[j].inject(regs[9 + j]);
    outOff[j].inject(regs[12 + j]);
  }
  unawaited(Simulator.run());
  final got = <List<int>>[];
  final lat = csc.latency;
  for (var i = 0; i < inputs.length + lat; i++) {
    await clk.nextNegedge;
    if (i >= lat) {
      got.add([
        csc.red.value.toInt(),
        csc.green.value.toInt(),
        csc.blue.value.toInt(),
      ]);
    }
    final v = inputs[min(i, inputs.length - 1)];
    y.inject(v[0]);
    cb.inject(v[1]);
    cr.inject(v[2]);
  }
  await Simulator.endSimulation();
  await Simulator.reset();
  return got;
}

List<List<int>> _corners() => [
  for (final y in [0, 1023])
    for (final cb in [0, 512, 1023])
      for (final cr in [0, 512, 1023]) [y, cb, cr],
];

/// 75 percent color bars: white, yellow, cyan, green, magenta, red, blue,
/// black.
List<List<int>> _bars(CscStandard s) => [
  for (final (r, g, b) in [
    (1, 1, 1),
    (1, 1, 0),
    (0, 1, 1),
    (0, 1, 0),
    (1, 0, 1),
    (1, 0, 0),
    (0, 0, 1),
    (0, 0, 0),
  ])
    cscForward(s, 191 * r, 191 * g, 191 * b),
];

HarborCscCoefficients _named(String name) => switch (name) {
  'bt601Limited' => HarborCscCoefficients.bt601Limited,
  'bt601Full' => HarborCscCoefficients.bt601Full,
  'bt709Limited' => HarborCscCoefficients.bt709Limited,
  'bt709Full' => HarborCscCoefficients.bt709Full,
  'bt2020Limited' => HarborCscCoefficients.bt2020Limited,
  'bt2020Full' => HarborCscCoefficients.bt2020Full,
  _ => throw ArgumentError(name),
};

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('the standard sets come from the matrices', () {
    final s = HarborCscCoefficients.bt709Limited;
    expect(s.coeff, [4769, 0, 7343, 4769, -873, -2183, 4769, 8652, 0]);
    expect(s.inOffset, [64, 512, 512]);
    expect(s.outOffset, [0, 0, 0]);
    expect(HarborCscCoefficients.bt601Full.inOffset, [0, 512, 512]);
    expect(HarborCscCoefficients.bt601Full.coeff[0], 4096);
    expect(
      HarborCscCoefficients.bt709Limited.registers(),
      [4769, 0, 7343, 4769, 0x10000 - 873, 0x10000 - 2183, 4769, 8652, 0] +
          [64, 512, 512, 0, 0, 0],
    );
  });

  for (final std in cscStandards) {
    test('${std.name} matches the float and fixed-point models', () async {
      final set = _named(std.name);
      final rng = Random(std.name.hashCode);
      final inputs = [
        ..._corners(),
        [std.yOffset, 512, 512],
        [std.limited ? 940 : 1020, 512, 512],
        if (std.limited) ..._bars(std),
        for (var i = 0; i < 400; i++)
          [rng.nextInt(1024), rng.nextInt(1024), rng.nextInt(1024)],
      ];
      final got = await _run(set, inputs);
      var worst = 0;
      for (final (i, v) in inputs.indexed) {
        expect(
          got[i],
          equals(cscFixed(set, v[0], v[1], v[2])),
          reason: 'fixed $v',
        );
        final f = cscFloat(std, v[0], v[1], v[2]);
        for (var c = 0; c < 3; c++) {
          worst = max(worst, (got[i][c] - f[c]).abs());
        }
        expect(
          [for (var c = 0; c < 3; c++) (got[i][c] - f[c]).abs()],
          everyElement(lessThanOrEqualTo(1)),
          reason: 'float $v: got ${got[i]}, float $f',
        );
      }
      printOnFailure('${std.name}: worst ${worst}');
      // Black and white are exact.
      expect(got[18], [0, 0, 0]);
      expect(got[19], [255, 255, 255]);
      if (std.limited) {
        final bars = got.sublist(20, 28);
        expect(bars.first, [191, 191, 191]);
        expect(bars.last, [0, 0, 0]);
      }
    });
  }

  test('each channel clamps under 0 and over 255', () async {
    final set = HarborCscCoefficients.bt709Limited;
    final inputs = [
      [0, 512, 512],
      [1023, 512, 512],
      [512, 512, 0],
      [512, 512, 1023],
      [512, 0, 512],
      [512, 1023, 512],
      [940, 0, 0],
      [64, 1023, 1023],
    ];
    final got = await _run(set, inputs);
    expect(got[0], [0, 0, 0]);
    expect(got[1], [255, 255, 255]);
    expect(got[2][0], 0);
    expect(got[3][0], 255);
    expect(got[4][2], 0);
    expect(got[5][2], 255);
    expect(got[6][1], 255);
    expect(got[7][1], 0);
    for (final (i, v) in inputs.indexed) {
      expect(got[i], cscFixed(set, v[0], v[1], v[2]), reason: '$v');
    }
  });

  const ecp5 = HarborFpgaTarget.ecp5(device: 'LFE5U-85F', package: 'CABGA381');
  for (final target in [null, ecp5]) {
    final kind = target == null ? 'inferred' : 'MULT18X18D';
    test(
      'any coefficients and offsets match the fixed-point model, $kind',
      () async {
        final rng = Random(7);
        for (var n = 0; n < 4; n++) {
          final set = HarborCscCoefficients(
            coeff: [for (var k = 0; k < 9; k++) rng.nextInt(0x10000) - 0x8000],
            inOffset: [for (var j = 0; j < 3; j++) rng.nextInt(1024)],
            outOffset: [for (var i = 0; i < 3; i++) rng.nextInt(256)],
          );
          final inputs = [
            ..._corners(),
            for (var i = 0; i < 100; i++)
              [rng.nextInt(1024), rng.nextInt(1024), rng.nextInt(1024)],
          ];
          final got = await _run(set, inputs, target: target);
          for (final (i, v) in inputs.indexed) {
            expect(got[i], cscFixed(set, v[0], v[1], v[2]), reason: '$n $v');
          }
        }
      },
    );
  }

  test('an ECP5 target uses MULT18X18D cells with their registers', () async {
    final csc = HarborCsc(
      clk: Logic(),
      y: Logic(width: 10),
      cb: Logic(width: 10),
      cr: Logic(width: 10),
      coeff: [for (var k = 0; k < 9; k++) Logic(width: 16)],
      inOffset: [for (var j = 0; j < 3; j++) Logic(width: 10)],
      outOffset: [for (var i = 0; i < 3; i++) Logic(width: 8)],
      target: ecp5,
    );
    await csc.build();
    expect(csc.definitionName, 'HarborCsc_ecp5');
    final sv = csc.generateSynth();
    expect(RegExp(r'MULT18X18D\s*#').allMatches(sv), hasLength(9));
    expect(sv, contains('.REG_OUTPUT_CLK("CLK0")'));
  });

  test('an output offset adds in 8-bit units', () async {
    final set = HarborCscCoefficients(
      coeff: [4096, 0, 0, 0, 4096, 0, 0, 0, 4096],
      inOffset: [0, 0, 0],
      outOffset: [16, 0, 255],
    );
    final got = await _run(set, [
      [400, 2, 0],
      [401, 1, 1],
    ]);
    expect(got[0], [116, 1, 255]);
    expect(got[1], [116, 0, 255]);
  });

  test('a value out of its register range throws', () {
    expect(
      () => HarborCscCoefficients(
        coeff: [0x8000, 0, 0, 0, 0, 0, 0, 0, 0],
        inOffset: [0, 0, 0],
        outOffset: [0, 0, 0],
      ),
      throwsArgumentError,
    );
  });
}
