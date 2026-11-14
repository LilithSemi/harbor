import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:harbor/src/bus/port/reg_fifo.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

class _Shell extends Module {
  late final HarborRegFifo fifo;

  _Shell({
    required int depth,
    required int width,
    required bool bypass,
    required bool resetEntries,
    required bool inPlace,
  }) : super(name: 'shell') {
    final clk = addInput('clk', Logic());
    final reset = addInput('reset', Logic());
    final pushValid = addInput('push_valid', Logic());
    final pushData = addInput('push_data', Logic(width: width), width: width);
    final popReady = addInput('pop_ready', Logic());
    fifo = HarborRegFifo(
      name: 'q',
      clk: clk,
      reset: reset,
      depth: depth,
      pushValid: pushValid,
      pushData: pushData,
      popReady: popReady,
      bypassWhenEmpty: bypass,
      resetEntries: resetEntries,
      inPlace: inPlace,
    );
    addOutput('push_ready') <= fifo.pushReady;
    addOutput('pop_valid') <= fifo.popValid;
    addOutput('pop_data', width: width) <= fifo.popData;
  }
}

String _sv(Module m) => SynthBuilder(
  m,
  SystemVerilogSynthesizer(),
).getSynthFileContents().map((f) => f.contents).join();

bool _isRam(HarborRegFifo f) {
  try {
    f.entries;
    return false;
  } on StateError {
    return true;
  }
}

// Random pushes, pops and data against a reference queue. Inputs change at
// the negative edge, and each positive edge checks the values just before
// it.
Future<void> _run({
  required int seed,
  required int depth,
  required int width,
  bool bypass = false,
  bool resetEntries = false,
  bool inPlace = false,
}) async {
  final rng = Random(seed);
  final dut = _Shell(
    depth: depth,
    width: width,
    bypass: bypass,
    resetEntries: resetEntries,
    inPlace: inPlace,
  );
  await dut.build();
  expect(
    _isRam(dut.fifo),
    !inPlace && depth >= 2 && depth * width >= HarborRegFifo.ramBits,
  );

  final clk = SimpleClockGenerator(10).clk;
  dut.input('clk').srcConnection! <= clk;
  final reset = dut.input('reset').srcConnection!;
  final pushValid = dut.input('push_valid').srcConnection!;
  final pushData = dut.input('push_data').srcConnection!;
  final popReady = dut.input('pop_ready').srcConnection!;
  final pushReady = dut.output('push_ready');
  final popValid = dut.output('pop_valid');
  final popData = dut.output('pop_data');

  final ref = Queue<LogicValue>();
  final errors = <String>[];
  var pushes = 0;
  var pops = 0;
  Simulator.setMaxSimTime(200000);
  unawaited(Simulator.run());
  reset.inject(1);
  pushValid.inject(0);
  popReady.inject(0);
  pushData.inject(0);
  for (var i = 0; i < 3; i++) {
    await clk.nextPosedge;
  }
  await clk.nextNegedge;
  reset.inject(0);

  final pushRate = 0.2 + 0.8 * rng.nextDouble();
  final popRate = 0.2 + 0.8 * rng.nextDouble();
  for (var cycle = 0; cycle < 1500; cycle++) {
    final full = width >= 63
        ? LogicValue.ofBigInt(
            BigInt.from(rng.nextInt(1 << 31)) << 32 |
                BigInt.from(rng.nextInt(1 << 31)),
            width,
          )
        : LogicValue.ofInt(rng.nextInt(1 << min(width, 31)), width);
    pushValid.inject(rng.nextDouble() < pushRate ? 1 : 0);
    popReady.inject(rng.nextDouble() < popRate ? 1 : 0);
    pushData.inject(full);
    await clk.nextPosedge;

    final pv = pushValid.previousValue!.toBool();
    final pd = pushData.previousValue!;
    final pr = popReady.previousValue!.toBool();
    final ready = pushReady.previousValue!;
    final valid = popValid.previousValue!;
    final data = popData.previousValue!;
    final wantReady = ref.length < depth;
    final pushFire = pv && wantReady;
    final through = bypass && ref.isEmpty && pushFire;
    final wantValid = ref.isNotEmpty || through;
    if (ready != LogicValue.ofBool(wantReady)) {
      errors.add('cycle $cycle: push_ready $ready, want $wantReady');
    }
    if (valid != LogicValue.ofBool(wantValid)) {
      errors.add('cycle $cycle: pop_valid $valid, want $wantValid');
    }
    if (wantValid) {
      final head = through ? pd : ref.first;
      if (data != head) {
        errors.add('cycle $cycle: pop_data $data, want $head');
      }
    }
    if (resetEntries && !data.isValid) {
      errors.add('cycle $cycle: pop_data $data has X');
    }
    if (pushFire) {
      ref.add(pd);
      pushes++;
    }
    if (wantValid && pr) {
      ref.removeFirst();
      pops++;
    }
    if (errors.length > 10) break;
    await clk.nextNegedge;
  }
  await Simulator.endSimulation();
  await Simulator.simulationEnded;
  await Simulator.reset();
  expect(errors, isEmpty);
  expect(pushes, greaterThan(100));
  expect(pops, greaterThan(100));
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  for (final depth in [1, 2, 3, 4, 8]) {
    for (final width in [1, 4, 40, 72]) {
      for (final bypass in [false, true]) {
        for (final resetEntries in [false, true]) {
          test(
            'depth $depth width $width bypass $bypass '
            'resetEntries $resetEntries',
            () => _run(
              seed:
                  depth * 1000 +
                  width * 10 +
                  (bypass ? 2 : 0) +
                  (resetEntries ? 1 : 0),
              depth: depth,
              width: width,
              bypass: bypass,
              resetEntries: resetEntries,
            ),
          );
        }
      }
    }
  }

  test('inPlace keeps flop entries', () async {
    await _run(seed: 7, depth: 4, width: 40, inPlace: true);
  });

  test(
    'a RAM FIFO emits one memory with a write port and a read port',
    () async {
      final flops = _Shell(
        depth: 2,
        width: 1,
        bypass: false,
        resetEntries: false,
        inPlace: false,
      );
      await flops.build();
      expect(_sv(flops), isNot(contains('HarborRegFifoRam')));

      final dut = _Shell(
        depth: 2,
        width: 40,
        bypass: false,
        resetEntries: true,
        inPlace: false,
      );
      await dut.build();
      final sv = _sv(dut);
      expect(sv, contains('module HarborRegFifoRam_40x2_z'));
      expect(sv, contains('logic [39:0] mem [0:1];'));
      expect(sv, contains('if (wr_en) mem[wr_addr] <= wr_data;'));
      expect(sv, contains('assign rd_data = mem[rd_addr];'));
      expect(sv, contains("mem[i] = '0;"));
      expect(sv, isNot(contains('q_e0')));
    },
  );
}
