import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

void main() {
  tearDown(() async => Simulator.reset());

  for (final kind in HarborFabricKind.values) {
    busTests(kind);
  }
}

void busTests(HarborFabricKind kind) {
  test('bus port acks every access and reads 0 (${kind.name})', () async {
    final dm = HarborDebugModule(baseAddress: 0x0, fabricKind: kind);
    dm.port('dmi_addr').getsLogic(Const(0, width: 7));
    dm.port('dmi_data_in').getsLogic(Const(0, width: 32));
    dm.port('dmi_op').getsLogic(Const(0, width: 2));
    dm.port('dmi_valid').getsLogic(Const(0));
    for (final n in ['halted', 'running', 'unavail', 'reg_ready']) {
      dm.port('hart0_$n').getsLogic(Const(0));
    }
    dm.port('hart0_reg_rdata').getsLogic(Const(0, width: 64));

    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    dm.input('clk').srcConnection! <= clk;
    dm.input('reset').srcConnection! <= reset;
    final bus = RegBus.attach(dm, clk, name: 'bus');

    await dm.build();

    reset.inject(1);
    bus.idle();
    Simulator.setMaxSimTime(100000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    // Every access must complete (write and read both return, instead of
    // RegBus timing out) and every read must come back 0, since the debug
    // memory map is not designed yet.
    for (final a in [0x0, 0x380, 0x10380]) {
      await bus.write(a, 0x11223344);
      expect(await bus.read(a), 0);
    }
    await Simulator.endSimulation();
  });
}
