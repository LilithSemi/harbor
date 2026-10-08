import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../integration/test_harness.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test('bus port acks every access and reads 0', () async {
    final dm = HarborDebugModule(baseAddress: 0x0);
    dm.port('dmi_addr').getsLogic(Const(0, width: 7));
    dm.port('dmi_data_in').getsLogic(Const(0, width: 32));
    dm.port('dmi_op').getsLogic(Const(0, width: 2));
    dm.port('dmi_valid').getsLogic(Const(0));
    for (final n in ['halted', 'running', 'unavail', 'reg_ready']) {
      dm.port('hart0_$n').getsLogic(Const(0));
    }
    dm.port('hart0_reg_rdata').getsLogic(Const(0, width: 64));
    final tb = PeripheralTestBench(dm, busName: 'sysbus');
    await tb.init();

    var acks = 0;
    tb.clk.posedge.listen((_) {
      if (tb.ack.value.toBool()) acks++;
    });
    for (final a in [0x0, 0x380, 0x10380]) {
      await tb.write(a, 0x11223344);
      expect(await tb.read(a), 0);
    }
    expect(acks, 6, reason: 'one ACK pulse per access');
    await Simulator.endSimulation();
  });
}
