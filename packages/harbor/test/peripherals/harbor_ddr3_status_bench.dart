import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:rohd/rohd.dart';

import 'ddr3_ecp5_pad_dram_model.dart';

/// The status outputs of [HarborDdr3], sampled on `clk`.
typedef Ddr3Status = ({bool init, bool done, bool failed, int state});

Ddr3Status ddr3Status(HarborDdr3 ddr) {
  bool high(String n) => ddr.output(n).value == LogicValue.one;
  final s = ddr.output('cal_state').value;
  return (
    init: high('init_done'),
    done: high('cal_done'),
    failed: high('cal_failed'),
    state: s.isValid ? s.toInt() : -1,
  );
}

/// A running ECP5 [HarborDdr3] with a pad level DRAM model on its pins.
///
/// CK has period 4 and `ddr_clk` is CK/4. A large CK period in the
/// parameters makes the reset ROM timers short.
class Ddr3Ecp5StatusRun {
  final HarborDdr3 ddr;
  final Logic clk;
  final Logic ddrClk;
  final Logic reset;
  final Logic ddrReset;
  final Ddr3PinDramModel dram;

  Ddr3Ecp5StatusRun._(
    this.ddr,
    this.clk,
    this.ddrClk,
    this.reset,
    this.ddrReset,
    this.dram,
  );

  /// Builds and starts the run. [readSkewBeats] delays the read data of the
  /// model. 40 is more than leveling can correct, so calibration fails.
  static Future<Ddr3Ecp5StatusRun> start({int readSkewBeats = 0}) async {
    const config = HarborDdrConfig.orangeCrab();
    final ddr = HarborDdr3(
      config: config,
      baseAddress: 0x40000000,
      clockHz: 48000000,
      busAddressWidth: 27,
      busDataWidth: 32,
      ckPeriodPs: 200000,
      target: const HarborFpgaTarget.ecp5(
        device: 'LFE5U-25F',
        package: 'CSFBGA285',
      ),
    );
    final ck = SimpleClockGenerator(4).clk;
    final divInit = Logic(name: 'div_init')..inject(1);
    Simulator.registerAction(4, () => divInit.put(0));
    final div = Logic(name: 'div', width: 2);
    Sequential(ck, reset: divInit, [div < div + 1]);
    final ddrClk = div[1];
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset')..inject(1);
    final ddrReset = Logic(name: 'ddr_reset')..inject(1);
    ddr.input('clk').srcConnection! <= clk;
    ddr.input('reset').srcConnection! <= reset;
    ddr.input('ddr_clk').srcConnection! <= ddrClk;
    ddr.input('ddr_reset').srcConnection! <= ddrReset;
    ddr.input('ddr_ck_fast').srcConnection! <= ck;
    for (final n in ['ddr_ck90_fast', 'ddr_ck_dqs_fast', 'ddr_idelay_ref']) {
      ddr.input(n).srcConnection! <= Const(0);
    }
    // The bus stays idle.
    for (final e in ddr.inputs.entries) {
      if (e.key.startsWith('bus_')) {
        e.value.srcConnection! <= Const(0, width: e.value.width);
      }
    }
    await ddr.build();

    final dram = Ddr3PinDramModel(
      DdrParams.orangeCrab(ckPeriodPs: 200000),
      ck: ddr.output('sdram_ck'),
      cke: ddr.output('sdram_cke'),
      resetN: ddr.output('sdram_reset_n'),
      csN: ddr.output('sdram_cs_n'),
      rasN: ddr.output('sdram_ras_n'),
      casN: ddr.output('sdram_cas_n'),
      weN: ddr.output('sdram_we_n'),
      ba: ddr.output('sdram_ba'),
      addr: ddr.output('sdram_addr'),
      dm: ddr.output('sdram_dm'),
      dqPad: ddr.inOutSource('sdram_dq') as LogicNet,
      dqsPad: ddr.inOutSource('sdram_dqs') as LogicNet,
      readSkewBeats: readSkewBeats,
      dmRemapping: config.dmRemapping,
    );

    Simulator.setMaxSimTime(1 << 40);
    unawaited(Simulator.run());
    for (var i = 0; i < 20; i++) {
      await ck.nextPosedge;
    }
    ddrReset.inject(0);
    await clk.nextNegedge;
    reset.inject(0);
    return Ddr3Ecp5StatusRun._(ddr, clk, ddrClk, reset, ddrReset, dram);
  }

  Ddr3Status get status => ddr3Status(ddr);
}
