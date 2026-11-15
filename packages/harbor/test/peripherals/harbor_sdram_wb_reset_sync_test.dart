import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'harbor_sdram_wb_test.dart' show sdramByteAddr;
import 'sdram_wb_stack.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test('sync: there is no mem_reset port, and a bus reset re-initializes the '
      'device, which then serves again', () async {
    final s = SdramWbStack(
      sysClockHz: 125000000,
      memClockHz: 125000000,
      busClockSync: true,
    );
    await s.start();
    expect(s.sdram.inputs.keys, isNot(contains('mem_reset')));
    final a = sdramByteAddr(s, 1, 3, 8);
    await s.write32(a, 0x12345678);
    expect(await s.read32(a), equals(0x12345678));

    s.sysReset.inject(1);
    await s.idle(8);
    s.sysReset.inject(0);
    await s.idle(4);
    while (s.sdram.output('init_done').value != LogicValue.one) {
      await s.memClk.nextPosedge;
    }
    final b = sdramByteAddr(s, 2, 5, 4);
    await s.write32(b, 0x0badcafe);
    expect(await s.read32(b), equals(0x0badcafe));
    expect(s.sdram.output('bus_error').value, equals(LogicValue.zero));
    await s.stop();
    expect(s.errors, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
