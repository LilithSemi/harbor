import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_stack.dart';

/// Word address of (bank, row, col) for the stack's address map.
int sdramAddr(SdramEngineStack s, int bank, int row, int col) {
  final c = s.config;
  if (c.addressMap == HarborSdramAddressMap.rowBankCol) {
    return (((row << c.bankBits) | bank) << c.colWidth) | col;
  }
  return (((bank << c.rowWidth) | row) << c.colWidth) | col;
}

void main() {
  tearDown(() async => Simulator.reset());

  // One simulation per clock and address map. The simulator must stop
  // before a test returns, so each scenario below runs in turn inside one
  // test and drains before it checks.
  for (final clockHz in [100000000, 125000000]) {
    for (final map in HarborSdramAddressMap.values) {
      test('${clockHz ~/ 1000000} MHz ${map.name}', () async {
        final s = SdramEngineStack(clockHz: clockHz, map: map);
        await s.start();
        // Let the idle pull-in refreshes after init run out.
        await s.idle(200);

        var scenario = '';
        Future<void> settle() async {
          await s.drain();
          expect(s.errors, isEmpty, reason: scenario);
        }

        Future<void> test(String name, Future<void> Function() body) {
          scenario = name;
          return body();
        }

        // First, while every bank is still closed after init.
        await test('look-ahead opens the next bank during a read', () async {
          final x = sdramAddr(s, 0, 5, 0);
          final a = sdramAddr(s, 0, 5, 4);
          final b = sdramAddr(s, 1, 9, 0);
          final start = s.model.log.length;
          s.read(x, 1);
          s.read(a, 8);
          s.read(b, 1);
          await settle();
          final log = s.model.log.sublist(start);
          final reads = [
            for (final c in log)
              if (c.kind == 'read') c,
          ];
          expect(reads, hasLength(4));
          final actB = log.firstWhere(
            (c) => c.kind == 'activate' && c.bank == 1,
          );
          expect(actB.timePs, greaterThan(reads[1].timePs));
          expect(actB.timePs, lessThan(reads[2].timePs));
          expect(reads[3].bank, 1);
        });

        // Bank 1 now holds row 9. A request for row 21 behind a two-read
        // request on bank 0 gets its precharge before that request ends.
        await test(
          'look-ahead precharges the next bank during a read',
          () async {
            final a = sdramAddr(s, 0, 5, 4);
            final b = sdramAddr(s, 1, 21, 0);
            final start = s.model.log.length;
            s.read(a, 8);
            s.read(b, 1);
            await settle();
            await s.idle(4);
            final log = s.model.log.sublist(start);
            final readsA = [
              for (final c in log)
                if (c.kind == 'read' && c.bank == 0) c,
            ];
            final preB = log.firstWhere(
              (c) =>
                  c.kind == 'precharge' && c.bank == 1 && c.a & (1 << 10) == 0,
            );
            expect(readsA, hasLength(2));
            expect(preB.timePs, lessThan(readsA.last.timePs));
          },
        );

        await test('single and 2-word writes with every mask', () async {
          for (var m = 0; m < 4; m++) {
            final a = sdramAddr(s, 1, 7, 16 + m);
            s.write(a, [0xA5C3 ^ m], masks: [m]);
            s.read(a, 1);
          }
          for (var m = 0; m < 16; m++) {
            final a = sdramAddr(s, 2, 300, 64 + 2 * m);
            s.write(a, [0x1100 + m, 0x2200 + m], masks: [m & 3, m >> 2]);
            s.read(a, 2);
          }
          await settle();
        });

        await test('read after write, write after read', () async {
          final a = sdramAddr(s, 0, 42, 5);
          s.read(a, 3);
          s.write(a, [1, 2, 3]);
          s.read(a, 3);
          s.write(a + 1, [0xBEEF]);
          s.read(a, 3);
          await settle();
        });

        await test('read then write turnaround on the bus', () async {
          for (var n = 1; n <= 8; n++) {
            final a = sdramAddr(s, 3, 9, 32 * n);
            s.read(a, n);
            s.write(a + 8, [0x5A00 + n]);
            s.read(a + 8, 1);
          }
          await settle();
        });

        await test('row conflict on one bank', () async {
          final a = sdramAddr(s, 2, 10, 0);
          final b = sdramAddr(s, 2, 11, 0);
          s.write(a, [0x1111, 0x2222]);
          s.write(b, [0x3333]);
          s.read(a, 2);
          s.read(b, 1);
          s.write(a + 1, [0x4444]);
          s.read(a, 2);
          await settle();
        });

        await test('unaligned 8-word read uses one read per block', () async {
          final a = sdramAddr(s, 1, 77, 4);
          s.write(a, [for (var i = 0; i < 8; i++) 0x700 + i]);
          await s.drain();
          final before = s.model.log.where((c) => c.kind == 'read').length;
          s.read(a, 8);
          await settle();
          final reads = s.model.log.where((c) => c.kind == 'read').length;
          expect(reads - before, 2);
        });

        await s.idle(40);
        await s.stop();
        expect(s.errors, isEmpty);
      });
    }
  }
}
