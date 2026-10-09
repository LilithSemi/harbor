import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'harbor_sdram_wb_test.dart' show sdramByteAddr;
import 'sdram_wb_fail_cases.dart';
import 'sdram_wb_stack.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'async posted: a full request fifo holds back the bus and loses nothing',
    () async {
      final s = SdramWbStack(
        sysClockHz: 125000000,
        memClockHz: 125000000,
        postedWrites: true,
      );
      await s.start();
      final cdc = s.sdram.subModules.singleWhere((m) => m.name == 'sdram_cdc');
      // Bit 6 of the bridge's dbg output is the request fifo full flag.
      final dbg = cdc.output('dbg');
      var fullSeen = 0;
      final addrs = [
        for (var i = 0; i < 32; i++) sdramByteAddr(s, i % 4, 10 + i ~/ 4, 4),
      ];
      await streamHeld(
        s,
        [
          for (var i = 0; i < addrs.length; i++)
            (addr: addrs[i], write: true, data: 0xc0de0000 + i),
        ],
        onCycle: () {
          if (dbg.value[6] == LogicValue.one) fullSeen++;
        },
      );
      expect(fullSeen, greaterThan(0), reason: 'the fifo never filled');
      for (var i = 0; i < addrs.length; i++) {
        expect(await s.read32(addrs[i]), equals(0xc0de0000 + i));
      }
      await s.stop();
      expect(s.errors, isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'async non-posted: the bus holds for each write and loses nothing',
    () async {
      // Non-posted allows only one request in flight, so the request fifo
      // can never fill. The bus must instead wait, pending, for each
      // write's own round trip before the next one is accepted.
      final s = SdramWbStack(sysClockHz: 125000000, memClockHz: 125000000);
      await s.start();
      final cdc = s.sdram.subModules.singleWhere((m) => m.name == 'sdram_cdc');
      // Bit 0 of the bridge's dbg output is the slave-side pending flag,
      // bit 6 the request fifo full flag.
      final dbg = cdc.output('dbg');
      var pendingSeen = 0;
      var fullSeen = 0;
      final addrs = [
        for (var i = 0; i < 32; i++) sdramByteAddr(s, i % 4, 10 + i ~/ 4, 4),
      ];
      await streamHeld(
        s,
        [
          for (var i = 0; i < addrs.length; i++)
            (addr: addrs[i], write: true, data: 0xc0de0000 + i),
        ],
        onCycle: () {
          if (dbg.value[0] == LogicValue.one) pendingSeen++;
          if (dbg.value[6] == LogicValue.one) fullSeen++;
        },
      );
      expect(pendingSeen, greaterThan(0), reason: 'the bus was never held');
      expect(fullSeen, equals(0), reason: 'the request fifo should not fill');
      for (var i = 0; i < addrs.length; i++) {
        expect(await s.read32(addrs[i]), equals(0xc0de0000 + i));
      }
      await s.stop();
      expect(s.errors, isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
