import 'dart:math';

import 'package:harbor/src/peripherals/ethernet/eth_crc.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/eth_frames.dart';

class _CrcStep extends Module {
  Logic get next => output('next');

  _CrcStep(Logic crc, Logic byte) {
    crc = addInput('crc', crc, width: 32);
    byte = addInput('data', byte, width: 8);
    addOutput('next', width: 32) <= harborEthCrcByte(crc, byte);
  }
}

void main() {
  late Logic crc;
  late Logic byte;
  late _CrcStep dut;

  setUp(() async {
    crc = Logic(width: 32);
    byte = Logic(width: 8);
    dut = _CrcStep(crc, byte);
    await dut.build();
  });

  int run(List<int> bytes) {
    var state = 0xFFFFFFFF;
    for (final b in bytes) {
      crc.put(state);
      byte.put(b);
      state = dut.next.value.toInt();
    }
    return ~state & 0xFFFFFFFF;
  }

  test('check value of 123456789', () {
    expect(ethCrc32('123456789'.codeUnits), equals(0xCBF43926));
    expect(run('123456789'.codeUnits), equals(0xCBF43926));
  });

  test('random frames match the reference', () {
    final rand = Random(7);
    for (var i = 0; i < 12; i++) {
      final len = i == 0 ? 1 : (i == 1 ? 1522 : 1 + rand.nextInt(1522));
      final frame = [for (var j = 0; j < len; j++) rand.nextInt(256)];
      expect(run(frame), equals(ethCrc32(frame)), reason: 'length $len');
    }
  });

  test('known ARP frame FCS', () {
    expect(ethArpRequest.length, equals(60));
    expect(run(ethArpRequest), equals(ethArpRequestFcs));
    expect(ethCrc32(ethArpRequest), equals(ethArpRequestFcs));
  });

  test('FCS on the wire is the inverted CRC, low byte first', () {
    expect(ethFcsBytes(ethArpRequest), equals([0xAD, 0x8D, 0x88, 0x40]));
    // Running the CRC over frame plus FCS leaves the fixed residue.
    final state = ~run([...ethArpRequest, ...ethFcsBytes(ethArpRequest)]);
    expect(state & 0xFFFFFFFF, equals(0xDEBB20E3));
  });
}
