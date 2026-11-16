import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _ecp5 = HarborFpgaTarget.ecp5(device: 'lfe5u-85f', package: 'CABGA381');
const _spartan7 = HarborFpgaTarget.spartan7(device: 's50', package: 'csga324');
const _ice40 = HarborFpgaTarget.ice40(device: 'up5k', package: 'sg48');

/// Writes a full word, then a partial strobe write, and reads the entry back.
/// The second partial write is read in the same cycle, so it also checks the
/// write-first bypass by byte.
Future<List<BigInt>> _partialWrite(HarborDeviceTarget? target) async {
  final rf = HarborRegisterFile(
    numEntries: 16,
    dataWidth: 64,
    numReadPorts: 1,
    reservedZero: false,
    byteWrite: true,
    target: target,
    forceReadLatency: 1,
  );
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset')..put(1);
  final en = Logic(name: 'wr_en')..put(0);
  final addr = Logic(name: 'wr_addr', width: rf.addrWidth)..put(0);
  final data = Logic(name: 'wr_data', width: 64)..put(0);
  final strb = Logic(name: 'wr_strb', width: 8)..put(0);
  final rd = Logic(name: 'rd_addr', width: rf.addrWidth)..put(5);
  rf.input('clk').srcConnection! <= clk;
  rf.input('reset').srcConnection! <= reset;
  rf.input('wr_en').srcConnection! <= en;
  rf.input('wr_addr').srcConnection! <= addr;
  rf.input('wr_data').srcConnection! <= data;
  rf.input('wr_strb').srcConnection! <= strb;
  rf.input('rd0_addr').srcConnection! <= rd;
  await rf.build();
  unawaited(Simulator.run());
  Future<void> cycle() => clk.nextPosedge;
  await cycle();
  await cycle();
  reset.inject(0);
  await cycle();
  void write(int value, int lanes) {
    en.inject(1);
    addr.inject(5);
    data.inject(BigInt.parse(value.toRadixString(16), radix: 16));
    strb.inject(lanes);
  }

  write(0x1122334455667788, 0xff);
  await cycle();
  write(0x00aa000000bb0000, 0x44);
  await cycle();
  en.inject(0);
  await cycle();
  final first = rf.readData(0).value.toBigInt();
  // A write and a read of the same entry in one cycle.
  write(0x00000000000000cc, 0x01);
  await cycle();
  en.inject(0);
  await cycle();
  final second = rf.readData(0).value.toBigInt();
  await Simulator.endSimulation();
  return [first, second];
}

void main() {
  tearDown(() async => Simulator.reset());

  for (final (name, target) in [('flop', null), ('ECP5 x9', _ecp5)]) {
    test('$name partial strobe writes only the strobed bytes', () async {
      final got = await _partialWrite(target);
      expect(got[0], BigInt.parse('11aa334455bb7788', radix: 16));
      expect(got[1], BigInt.parse('11aa334455bb77cc', radix: 16));
    });
  }

  Future<String> sv(HarborDeviceTarget target, {bool sdp72 = false}) async {
    final rf = HarborRegisterFile(
      numEntries: 512,
      dataWidth: 64,
      numReadPorts: 1,
      reservedZero: false,
      byteWrite: true,
      useXilinxSdp72: sdp72,
      target: target,
    );
    await rf.build();
    return rf.dumpSystemVerilog();
  }

  test('SDP72 drives each WEBWE bit from its strobe bit', () async {
    final s = await sv(_spartan7, sdp72: true);
    for (var lane = 0; lane < 8; lane++) {
      expect(s, contains('wr_strb[$lane]'));
    }
    expect(RegExp(r'RAMB36E1 #').allMatches(s), hasLength(1));
  });

  test('x36 drives each WEA bit from its strobe bit', () async {
    final s = await sv(_spartan7);
    for (var lane = 0; lane < 8; lane++) {
      expect(s, contains('wr_strb[$lane]'));
    }
    expect(RegExp(r'RAMB36E1 #').allMatches(s), hasLength(2));
  });

  test('iCE40 masks the bytes that are not strobed', () async {
    final s = await sv(_ice40);
    // Each 16-bit block masks bits 15..8 with the high byte strobe and bits
    // 7..0 with the low one. MASK high means no write.
    for (var w = 0; w < 4; w++) {
      final start = s.indexOf('ebr_r0_d0_w$w(');
      expect(start, isNot(-1), reason: 'block $w');
      final mask = s.substring(
        s.indexOf('.MASK(', start),
        s.indexOf('}))', s.indexOf('.MASK(', start)),
      );
      final bits = RegExp(
        r'\(~\(wr_strb\[(\d+)\]\)\)',
      ).allMatches(mask).map((m) => int.parse(m.group(1)!)).toList();
      expect(bits, [
        ...List.filled(8, 2 * w + 1),
        ...List.filled(8, 2 * w),
      ], reason: 'MASK of block $w');
    }
  });

  test('ECP5 puts one byte in each x9 block', () async {
    final s = await sv(_ecp5);
    expect(RegExp(r'DP16KD #').allMatches(s), hasLength(8));
    for (var lane = 0; lane < 8; lane++) {
      expect(s, contains('wr_strb[$lane]'));
    }
  });

  test('byteWrite needs one write port', () {
    expect(
      () => HarborRegisterFile(numWritePorts: 2, byteWrite: true),
      throwsArgumentError,
    );
  });
}
