import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'test_harness.dart';

/// Byte store to register [offset] on a bus of [lanes] bytes. The address is
/// aligned down to the bus word and the byte goes in its lane.
Future<void> _storeByte(
  PeripheralTestBench tb,
  int base,
  int lanes,
  int offset,
  int value,
) {
  final lane = offset % lanes;
  return tb.write(base + offset - lane, value << (8 * lane), sel: 1 << lane);
}

Future<int> _loadByte(
  PeripheralTestBench tb,
  int base,
  int lanes,
  int offset,
) async {
  final lane = offset % lanes;
  final word = await tb.read(base + offset - lane);
  return (word >> (8 * lane)) & 0xFF;
}

/// Samples TX until a full 8N1 frame at [cyclesPerBit] arrives.
Future<int?> _receiveByte(
  PeripheralTestBench tb,
  Logic tx,
  int cyclesPerBit,
) async {
  var guard = 0;
  while (tx.value.toInt() == 1) {
    if (guard++ > 200) return null;
    await tb.waitCycles(1);
  }
  // Move to the middle of the start bit, then one bit period per sample.
  await tb.waitCycles(cyclesPerBit ~/ 2);
  if (tx.value.toInt() != 0) return null;
  var byte = 0;
  for (var i = 0; i < 8; i++) {
    await tb.waitCycles(cyclesPerBit);
    byte |= tx.value.toInt() << i;
  }
  await tb.waitCycles(cyclesPerBit);
  if (tx.value.toInt() != 1) return null;
  return byte;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  final cases = [
    for (final width in [32, 64])
      for (final absolute in [true, false])
        for (final addressWidth in [32, null])
          (width: width, absolute: absolute, addressWidth: addressWidth),
  ];

  for (final c in cases) {
    final base = c.absolute ? 0x10000000 : 0;
    final where = c.absolute ? 'absolute' : 'relative';
    final aw = c.addressWidth ?? 12;

    group('HarborUart on a ${c.width}-bit bus, $where, $aw-bit address', () {
      test('configure and transmit puts the byte on TX', () async {
        final uart = HarborUart(
          baseAddress: 0x10000000,
          busAddressWidth: c.addressWidth,
          busDataWidth: c.width,
        );
        uart.port('rx').getsLogic(Const(1));
        final tb = PeripheralTestBench(uart);
        await tb.init();

        final lanes = c.width ~/ 8;
        // The bus port only carries the low address bits it declares.
        final b = base & ((1 << aw) - 1);
        await _storeByte(tb, b, lanes, 3, 0x83);
        await _storeByte(tb, b, lanes, 0, 4);
        await _storeByte(tb, b, lanes, 1, 0);
        await _storeByte(tb, b, lanes, 3, 0x03);
        expect(await _loadByte(tb, b, lanes, 3), equals(0x03));
        expect(await _loadByte(tb, b, lanes, 5) & 0x60, equals(0x60));

        await _storeByte(tb, b, lanes, 0, 0xA5);
        expect(await _receiveByte(tb, uart.tx, 4), equals(0xA5));

        await Simulator.endSimulation();
      });

      test('an unused offset in the window reads 0', () async {
        final uart = HarborUart(
          baseAddress: 0x10000000,
          busAddressWidth: c.addressWidth,
          busDataWidth: c.width,
        );
        uart.port('rx').getsLogic(Const(1));
        final tb = PeripheralTestBench(uart);
        await tb.init();

        final lanes = c.width ~/ 8;
        final b = base & ((1 << aw) - 1);
        await _storeByte(tb, b, lanes, 7, 0x5A);
        // 0x107 would alias SCR at 7 with a 3-bit decode.
        await _storeByte(tb, b, lanes, 0x107, 0xFF);
        expect(await _loadByte(tb, b, lanes, 7), equals(0x5A));
        expect(await tb.read(b + 0x100), equals(0));

        await Simulator.endSimulation();
      });
    });
  }
}
