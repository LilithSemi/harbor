import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Simulator.reset);

  const base = HarborSdramConfig.as4c16m16sb6();
  final config = base.copyWith(timing: base.timing.copyWith(powerUpNs: 2000));

  for (final sync in [true, false]) {
    for (final cycles in [1, 2, 3]) {
      test('${sync ? 'sync' : 'crossed'}: a power-on reset of $cycles '
          'cycles still runs init', () async {
        final clk = SimpleClockGenerator(8000).clk;
        final reset = Logic(name: 'r')..inject(1);
        final sdram = HarborSdram(
          config: config,
          baseAddress: 0,
          clockHz: 125000000,
          busClockSync: sync,
          target: const HarborFpgaTarget.ecp5(
            device: 'LFE5U-85F',
            package: 'CABGA381',
          ),
        );
        sdram.input('clk').srcConnection! <= clk;
        sdram.input('reset').srcConnection! <= reset;
        if (!sync) {
          sdram.input('mem_clk').srcConnection! <= clk;
          sdram.input('mem_reset').srcConnection! <= reset;
        }
        for (final p in sdram.inputs.keys.where((k) => k.startsWith('bus_'))) {
          sdram.input(p).srcConnection! <=
              Const(0, width: sdram.input(p).width);
        }
        await sdram.build();
        Simulator.setMaxSimTime(100000000);
        unawaited(Simulator.run());
        for (var i = 0; i < cycles; i++) {
          await clk.nextPosedge;
        }
        reset.put(0);
        var waited = 0;
        while (sdram.output('init_done').value != LogicValue.one &&
            waited < 3000) {
          await clk.nextPosedge;
          waited++;
        }
        expect(sdram.output('init_done').value, LogicValue.one);
        await Simulator.endSimulation();
      }, timeout: const Timeout(Duration(minutes: 5)));
    }
  }
}
