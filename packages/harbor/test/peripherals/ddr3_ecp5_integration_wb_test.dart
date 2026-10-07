import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'ddr3_ecp5_integration_stack.dart';

/// After DONE_CALIBRATE, a write/read pattern sweep and a
/// byte-masked write (through the [1, 0] DM remap) on the Wishbone side,
/// checked against the pad-level model. Separate file: needs a full
/// calibration run first.
void main() {
  tearDown(() async => Simulator.reset());

  test('write/read sweep and a byte-masked write through the Wishbone side, '
      'checked against the pad-level model', () async {
    final s = Ddr3Ecp5IntegrationStack(ddr3Ecp5TestParams());
    await s.build();
    await s.run();
    expect(await s.waitDone(), 23);

    // all-0, all-1, walking-1, address-in-data, on both BIST addresses.
    final patterns = [
      LogicValue.filled(s.p.wbDataBits, LogicValue.zero),
      LogicValue.filled(s.p.wbDataBits, LogicValue.one),
      LogicValue.ofBigInt(BigInt.one << 37, s.p.wbDataBits),
      LogicValue.ofBigInt(
        BigInt.from(0xA5A5) | (BigInt.from(1) << 100),
        s.p.wbDataBits,
      ),
    ];
    for (final addr in [0, 1]) {
      for (final pat in patterns) {
        await s.wbWrite(addr, pat);
        final back = await s.wbRead(addr);
        expect(back, pat, reason: 'addr $addr pattern $pat');
      }
    }

    // Byte-masked write: seed addr 0 with a known word, then write a new
    // word masking every other byte (sel alternating 1010...), through the
    // DM remap [1, 0]. Only the selected bytes should change.
    final seed = LogicValue.ofBigInt(
      BigInt.parse('11' * 16, radix: 16),
      s.p.wbDataBits,
    );
    await s.wbWrite(0, seed);
    final newWord = LogicValue.ofBigInt(
      BigInt.parse('22' * 16, radix: 16),
      s.p.wbDataBits,
    );
    final altSel = LogicValue.ofBigInt(
      BigInt.parse('A' * (s.p.wbSelBits ~/ 4), radix: 16),
      s.p.wbSelBits,
    );
    await s.wbWrite(0, newWord, sel: altSel);
    final merged = await s.wbRead(0);
    for (var byte = 0; byte < s.p.wbDataBits ~/ 8; byte++) {
      final gotByte = merged.getRange(byte * 8, byte * 8 + 8);
      final selBit = altSel[byte];
      final expected = selBit.toBool()
          ? newWord.getRange(byte * 8, byte * 8 + 8)
          : seed.getRange(byte * 8, byte * 8 + 8);
      expect(gotByte, expected, reason: 'byte $byte mask mismatch');
    }
    expect(s.dram.errors, isEmpty);

    await Simulator.endSimulation();
  });
}
