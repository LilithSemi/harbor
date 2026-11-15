import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'ddr3_scheduled_clock.dart';

HarborDdr3 _ddr({int? powerOnCycles}) => HarborDdr3(
  config: const HarborDdrConfig.orangeCrab(),
  baseAddress: 0x40000000,
  clockHz: 48000000,
  target: const HarborFpgaTarget.ecp5(
    device: 'LFE5U-25F',
    package: 'CSFBGA285',
  ),
  powerOnCycles: powerOnCycles ?? 4095,
);

/// Memory clock edges after the domain reset releases until rst_n is high.
Future<int> _holdCycles(int powerOnCycles) async {
  final ddr = HarborDdr3(
    config: const HarborDdrConfig.orangeCrab(),
    baseAddress: 0x40000000,
    clockHz: 48000000,
    busAddressWidth: 27,
    busDataWidth: 32,
    ckPeriodPs: 2500,
    target: const HarborFpgaTarget.ecp5(
      device: 'LFE5U-25F',
      package: 'CSFBGA285',
    ),
    powerOnCycles: powerOnCycles,
  );
  final ck = SimpleClockGenerator(2).clk;
  final ddrClk = scheduledClock(firstRise: 5, halfPeriod: 4);
  final reset = Logic(name: 'ddr_reset')..inject(1);
  ddr.input('ddr_ck_fast').srcConnection! <= ck;
  ddr.input('ddr_clk').srcConnection! <= ddrClk;
  ddr.input('ddr_reset').srcConnection! <= reset;
  ddr.input('clk').srcConnection! <= ck;
  ddr.input('reset').srcConnection! <= reset;
  for (final n in ['ddr_ck90_fast', 'ddr_ck_dqs_fast', 'ddr_idelay_ref']) {
    ddr.input(n).srcConnection! <= Const(0);
  }
  await ddr.build();
  final rstN = ddr.signals.firstWhere((s) => s.name == 'ddr_rst_n');
  Simulator.setMaxSimTime(100000);
  unawaited(Simulator.run());
  for (var i = 0; i < 5; i++) {
    await ddrClk.nextPosedge;
  }
  reset.inject(0);
  var cycles = 0;
  while (rstN.value != LogicValue.one && cycles < 200) {
    await ddrClk.nextPosedge;
    cycles++;
  }
  await Simulator.endSimulation();
  return cycles;
}

void main() {
  tearDown(() async => Simulator.reset());

  test('a power on hold outside 1 to 4095 cycles is refused', () {
    expect(() => _ddr(powerOnCycles: 0), throwsArgumentError);
    expect(() => _ddr(powerOnCycles: 4096), throwsArgumentError);
  });

  test('the ends of the power on hold range are accepted', () {
    expect(() => _ddr(powerOnCycles: 1), returnsNormally);
    expect(() => _ddr(powerOnCycles: 4095), returnsNormally);
  });

  test('fastSim refuses a power on hold other than the default', () {
    HarborDdr3 fast(int cycles) => HarborDdr3(
      config: const HarborDdrConfig.ax7203(),
      baseAddress: 0,
      clockHz: 100000000,
      busAddressWidth: 32,
      busDataWidth: 32,
      ckPeriodPs: 2500,
      fastSim: true,
      powerOnCycles: cycles,
      target: const HarborFpgaTarget.artix7(
        device: 'xc7a200t',
        package: 'fbg484',
      ),
    );
    expect(() => fast(64), throwsArgumentError);
    expect(() => fast(4095), returnsNormally);
  });

  test('a shorter power on hold gets its own definition name', () {
    expect(
      _ddr(powerOnCycles: 64).definitionName,
      isNot(_ddr().definitionName),
    );
    expect(_ddr(powerOnCycles: 64).definitionName, contains('p64'));
  });

  test('rst_n rises powerOnCycles edges later for a longer hold', () async {
    final short = await _holdCycles(3);
    await Simulator.reset();
    final long = await _holdCycles(10);
    expect(short, lessThan(200));
    expect(long - short, 7);
  });
}
