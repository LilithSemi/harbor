import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_wb_fail_cases.dart';
import 'sdram_wb_stack.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'sync: a memory reset mid-read ends the bus cycle',
    () async {
      final s = SdramWbStack(
        sysClockHz: 125000000,
        memClockHz: 125000000,
        busClockSync: true,
      );
      await s.start();
      await memResetCase(s);
      await s.stop();
      expect(s.errors, isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'sync: a memory reset with a bank open closes it before the real '
    '200 us power-up wait, so tRAS max never trips',
    () async {
      final s = SdramWbStack(
        sysClockHz: 125000000,
        memClockHz: 125000000,
        busClockSync: true,
        fastInit: false,
      );
      await s.start();
      final addrs = await seed(s, 5, 0x42000000);
      s.drive(byteAddr: addrs[1], write: false);
      await s.waitHigh(s.wbPort.output('req_valid'));
      // Leave the row open for a few cycles, as a real read would.
      for (var i = 0; i < 6; i++) {
        await s.memClk.nextPosedge;
      }
      s.memReset.inject(1);
      unawaited(s.idle(16).then((_) => s.memReset.inject(0)));
      await s.waitAck(limit: 60000);
      s.release();
      while (s.sdram.output('init_done').value != LogicValue.one) {
        await s.memClk.nextPosedge;
      }
      for (var i = 0; i < 50; i++) {
        await s.memClk.nextPosedge;
      }
      await s.stop();
      expect(s.errors, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
