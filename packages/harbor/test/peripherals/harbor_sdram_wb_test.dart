import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_wb_stack.dart';

/// Byte address of (bank, row, col), per the stack's address map.
int sdramByteAddr(SdramWbStack s, int bank, int row, int col) {
  final c = s.config;
  final word = c.addressMap == HarborSdramAddressMap.rowBankCol
      ? (((row << c.bankBits) | bank) << c.colWidth) | col
      : (((bank << c.rowWidth) | row) << c.colWidth) | col;
  return word << 1;
}

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'HarborSdram over wishbone: async bus (50 MHz) / mem (125 MHz)',
    () async {
      final s = SdramWbStack(sysClockHz: 50000000, memClockHz: 125000000);
      await s.start();
      expect(s.sdram.output('init_done').value, equals(LogicValue.one));

      // 32-bit write and read at several addresses in every bank.
      for (var bank = 0; bank < s.config.banks; bank++) {
        for (final col in [0, 4, 20]) {
          final addr = sdramByteAddr(s, bank, 1, col);
          final data = 0x10000000 * (bank + 1) + col;
          await s.write32(addr, data);
          final got = await s.read32(addr);
          expect(got, equals(data), reason: 'bank $bank col $col');
        }
      }
      expect(s.errors, isEmpty);

      // All 16 sel patterns over a seeded word: only selected bytes change.
      final selAddr = sdramByteAddr(s, 0, 2, 8);
      await s.write32(selAddr, 0x11223344);
      for (var selMask = 0; selMask < 16; selMask++) {
        final before = s.peek32(selAddr);
        // The complement of the current word: every byte differs from
        // `before`, so a selected byte always changes and a byte left out
        // never does, with no chance of a coincidental match either way.
        final data = (~before) & 0xffffffff;
        await s.write32(selAddr, data, selMask: selMask);
        final expected = s.peek32(selAddr);
        final got = await s.read32(selAddr);
        expect(
          got,
          equals(expected),
          reason: 'sel 0x${selMask.toRadixString(16)}',
        );
        for (var byte = 0; byte < 4; byte++) {
          final shift = byte * 8;
          final changed = ((got >> shift) & 0xff) != ((before >> shift) & 0xff);
          expect(
            changed,
            equals((selMask >> byte) & 1 == 1),
            reason: 'sel 0x${selMask.toRadixString(16)} byte $byte',
          );
        }
      }
      expect(s.errors, isEmpty);

      // Back-to-back mixed accesses across banks.
      final mixed = [
        sdramByteAddr(s, 0, 3, 0),
        sdramByteAddr(s, 1, 3, 0),
        sdramByteAddr(s, 2, 3, 0),
        sdramByteAddr(s, 3, 3, 0),
        sdramByteAddr(s, 0, 3, 4),
      ];
      for (var i = 0; i < mixed.length; i++) {
        await s.write32(mixed[i], 0x5a5a0000 + i);
      }
      for (var i = 0; i < mixed.length; i++) {
        final got = await s.read32(mixed[i]);
        expect(got, equals(0x5a5a0000 + i), reason: 'mixed $i');
      }

      expect(s.errors, isEmpty);
      await s.stop();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
