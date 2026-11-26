import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async {
    await Simulator.endSimulation();
    await Simulator.reset();
  });

  for (final primitive in <HarborBlockRam?>[HarborBlockRam.dp16kd, null]) {
    for (final depth in [1024, 4096]) {
      test(
        'HarborTdpBram ${primitive?.name ?? 'generic'} depth $depth',
        () async {
          final aw = (depth - 1).bitLength;
          final clk = SimpleClockGenerator(10).clk;
          final aAddr = Logic(width: aw);
          final bAddr = Logic(width: aw);
          final bWe = Logic();
          final bWdata = Logic(width: 16);
          final ram = HarborTdpBram(
            clk,
            width: 16,
            depth: depth,
            aAddr: aAddr,
            bAddr: bAddr,
            bWe: bWe,
            bWdata: bWdata,
            primitive: primitive,
          );
          await ram.build();
          aAddr.inject(0);
          bAddr.inject(0);
          bWe.inject(0);
          bWdata.inject(0);
          Simulator.setMaxSimTime(1000000);
          unawaited(Simulator.run());

          Future<void> clock({
            int? a,
            int? b,
            bool we = false,
            int d = 0,
          }) async {
            await clk.nextNegedge;
            if (a != null) aAddr.inject(a);
            if (b != null) bAddr.inject(b);
            bWe.inject(we);
            bWdata.inject(d);
            await clk.nextNegedge;
          }

          int aOut() => ram.aRdata.value.toInt();
          int bOut() => ram.bRdata.value.toInt();

          // Zero init.
          await clock(a: 5, b: 7);
          expect(aOut(), 0);
          expect(bOut(), 0);

          // A write on B shows on both ports.
          await clock(a: 0x123, b: 0x123, we: true, d: 0xBEEF);
          await clock(a: 0x123, b: 0x123);
          expect(aOut(), 0xBEEF);
          expect(bOut(), 0xBEEF);

          // The same address on both ports in a write clock: A is X and B holds.
          await clock(a: 0x123, b: 0x123, we: true, d: 0x1111);
          expect(ram.aRdata.value.isValid, isFalse);
          expect(bOut(), 0xBEEF);
          await clock(a: 0x123, b: 0x123);
          expect(aOut(), 0x1111);

          // Each bank answers on both ports.
          final banks = depth ~/ 1024;
          for (var k = 0; k < banks; k++) {
            await clock(b: k * 1024 + 3, we: true, d: 0x1000 + k);
          }
          for (var k = 0; k < banks; k++) {
            await clock(a: k * 1024 + 3, b: ((k + 1) % banks) * 1024 + 3);
            expect(aOut(), 0x1000 + k, reason: 'port A bank $k');
            expect(bOut(), 0x1000 + (k + 1) % banks, reason: 'port B bank $k');
          }

          // A write in another bank leaves B's read data alone.
          if (banks > 1) {
            await clock(a: 3, b: 3);
            expect(bOut(), 0x1000);
            await clock(a: 3, b: 2 * 1024 + 9, we: true, d: 0x0B0B);
            expect(bOut(), 0x1000);
            expect(aOut(), 0x1000);
            await clock(b: 2 * 1024 + 9);
            expect(bOut(), 0x0B0B);
          }
        },
      );
    }
  }
}
