import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'harbor_ddr3_status_bench.dart';

const _artix = HarborFpgaTarget.artix7(device: 'xc7a200t', package: 'fbg484');

HarborDdr3 _ddr({
  HarborDeviceTarget? target,
  HarborDdrConfig config = const HarborDdrConfig.ax7203(),
  int gear = 1,
  bool fastSim = false,
}) => HarborDdr3(
  config: config,
  baseAddress: 0,
  clockHz: 100000000,
  busAddressWidth: 32,
  busDataWidth: 32,
  ckPeriodPs: gear == 1 ? 2500 : 3333,
  controllerGearRatio: gear,
  fastSim: fastSim,
  target: target,
);

void main() {
  tearDown(Simulator.reset);

  final targets = {
    'Xilinx': () => _ddr(target: _artix),
    'Xilinx CK/8': () => _ddr(target: _artix, gear: 2),
    'ECP5': () => _ddr(
      config: const HarborDdrConfig.orangeCrab(),
      target: const HarborFpgaTarget.ecp5(
        device: 'LFE5U-25F',
        package: 'CSFBGA285',
      ),
    ),
    'Xilinx fastSim': () => _ddr(target: _artix, fastSim: true),
    'sim': () => _ddr(target: const HarborSimTarget()),
  };
  for (final MapEntry(key: name, value: make) in targets.entries) {
    test('$name has the status outputs', () async {
      final ddr = make();
      await ddr.build();
      for (final n in ['init_done', 'cal_done', 'cal_failed']) {
        expect(ddr.output(n).width, 1, reason: n);
      }
      expect(ddr.output('cal_state').width, 6);
      final sv = ddr.generateSynth();
      for (final n in ['init_done', 'cal_done', 'cal_failed', 'cal_state']) {
        expect(sv, matches(RegExp('output logic (\\[5:0\\] )?$n\\b')));
      }
    });
  }

  test('fastSim: init_done and cal_done rise in order', () async {
    final ddr = _ddr(target: _artix, fastSim: true);
    final clk = SimpleClockGenerator(10).clk;
    final ddrClk = SimpleClockGenerator(14).clk;
    final reset = Logic(name: 'reset')..inject(1);
    final ddrReset = Logic(name: 'ddr_reset')..inject(1);
    ddr.input('clk').srcConnection! <= clk;
    ddr.input('reset').srcConnection! <= reset;
    ddr.input('ddr_clk').srcConnection! <= ddrClk;
    ddr.input('ddr_reset').srcConnection! <= ddrReset;
    for (final e in ddr.inputs.entries) {
      if (e.value.srcConnection!.srcConnection == null &&
          !{'clk', 'reset', 'ddr_clk', 'ddr_reset'}.contains(e.key)) {
        e.value.srcConnection! <= Const(0, width: e.value.width);
      }
    }
    await ddr.build();
    Simulator.setMaxSimTime(1 << 40);
    unawaited(Simulator.run());
    for (var i = 0; i < 8; i++) {
      await ddrClk.nextPosedge;
    }
    ddrReset.inject(0);
    await clk.nextNegedge;
    reset.inject(0);

    int? initAt;
    int? doneAt;
    var last = ddr3Status(ddr);
    for (var i = 0; i < 20000 && doneAt == null; i++) {
      await clk.nextPosedge;
      last = ddr3Status(ddr);
      if (last.init) initAt ??= i;
      if (last.done) doneAt = i;
    }
    for (var i = 0; i < 20; i++) {
      await clk.nextPosedge;
    }
    last = ddr3Status(ddr);
    await Simulator.endSimulation();
    expect(initAt, isNotNull, reason: 'init_done never rose');
    expect(doneAt, isNotNull, reason: 'cal_done never rose');
    expect(initAt, lessThanOrEqualTo(doneAt!));
    expect(last.init, isTrue);
    expect(last.done, isTrue);
    expect(last.failed, isFalse);
    expect(last.state, Ddr3Controller.calStateDone);
  });
}
