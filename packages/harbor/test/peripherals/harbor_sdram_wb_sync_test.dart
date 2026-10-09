import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'harbor_sdram_wb_test.dart' show sdramByteAddr;
import 'sdram_wb_stack.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'HarborSdram over wishbone: busClockSync at 125 MHz',
    () async {
      final s = SdramWbStack(
        sysClockHz: 125000000,
        memClockHz: 125000000,
        busClockSync: true,
      );
      await s.start();
      expect(s.sdram.output('init_done').value, equals(LogicValue.one));

      for (var bank = 0; bank < s.config.banks; bank++) {
        for (final col in [0, 4, 20]) {
          final addr = sdramByteAddr(s, bank, 1, col);
          final data = 0x20000000 * (bank + 1) + col;
          await s.write32(addr, data);
          final got = await s.read32(addr);
          expect(got, equals(data), reason: 'bank $bank col $col');
        }
      }
      expect(s.errors, isEmpty);

      final selAddr = sdramByteAddr(s, 1, 2, 8);
      await s.write32(selAddr, 0x44332211);
      for (var selMask = 0; selMask < 16; selMask++) {
        final before = s.peek32(selAddr);
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

      final mixed = [
        sdramByteAddr(s, 3, 3, 0),
        sdramByteAddr(s, 2, 3, 0),
        sdramByteAddr(s, 1, 3, 0),
        sdramByteAddr(s, 0, 3, 0),
        sdramByteAddr(s, 3, 3, 4),
      ];
      for (var i = 0; i < mixed.length; i++) {
        await s.write32(mixed[i], 0x6b6b0000 + i);
      }
      for (var i = 0; i < mixed.length; i++) {
        final got = await s.read32(mixed[i]);
        expect(got, equals(0x6b6b0000 + i), reason: 'mixed $i');
      }

      expect(s.errors, isEmpty);
      await s.stop();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
