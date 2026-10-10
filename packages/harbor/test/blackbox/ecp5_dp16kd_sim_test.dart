import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Port A of one DP16KD, driven from the test at each falling edge.
class _Port {
  final clk = SimpleClockGenerator(10).clk;
  final ce = Logic(name: 'ce');
  final oce = Logic(name: 'oce');
  final we = Logic(name: 'we');
  final rst = Logic(name: 'rst');
  final cs = Logic(name: 'cs', width: 3);
  final ad = Logic(name: 'ad', width: 14);
  final di = Logic(name: 'di', width: 18);
  late final Ecp5Dp16kd bram;

  _Port({
    int width = 9,
    String regMode = 'NOREG',
    String writeMode = 'NORMAL',
    String csDecode = '0b000',
    List<BigInt>? initVals,
  }) {
    bram = Ecp5Dp16kd(
      dataWidthA: width,
      dataWidthB: width,
      regModeA: regMode,
      writeModeA: writeMode,
      csDecodeA: csDecode,
      initVals: initVals,
      clkA: clk,
      ceA: ce,
      oceA: oce,
      weA: we,
      rstA: rst,
      csA: cs,
      adA: ad,
      diA: di,
      clkB: clk,
      ceB: Const(0),
      oceB: Const(0),
      weB: Const(0),
      rstB: Const(0),
      adB: Const(0, width: 14),
      diB: Const(0, width: 18),
    );
  }

  Future<void> start() async {
    await bram.build();
    ce.inject(1);
    oce.inject(1);
    we.inject(0);
    rst.inject(0);
    cs.inject(0);
    ad.inject(0);
    di.inject(0);
    Simulator.setMaxSimTime(10000);
    unawaited(Simulator.run());
    await clk.nextNegedge;
  }

  /// Drives one cycle and returns DO as seen after its rising edge.
  Future<int> cycle({
    int ad = 0,
    int di = 0,
    bool we = false,
    bool ce = true,
    bool oce = true,
    bool rst = false,
    int cs = 0,
  }) async {
    this.ad.put(ad);
    this.di.put(di);
    this.we.put(we ? 1 : 0);
    this.ce.put(ce ? 1 : 0);
    this.oce.put(oce ? 1 : 0);
    this.rst.put(rst ? 1 : 0);
    this.cs.put(cs);
    await clk.nextNegedge;
    return bram.doA.value.toInt();
  }
}

/// x9 word address in AD[13:3].
int x9(int word) => word << 3;

/// Both ports of one x9 DP16KD on one clock. Returns DO_A and DO_B after
/// each cycle, with null for X.
Future<List<(int?, int?)>> _dual(
  List<(bool, int, int, bool, int, int)> cycles, {
  String writeModeA = 'NORMAL',
  String writeModeB = 'NORMAL',
}) async {
  final clk = SimpleClockGenerator(10).clk;
  final weA = Logic(name: 'we_a');
  final adA = Logic(name: 'ad_a', width: 14);
  final diA = Logic(name: 'di_a', width: 18);
  final weB = Logic(name: 'we_b');
  final adB = Logic(name: 'ad_b', width: 14);
  final diB = Logic(name: 'di_b', width: 18);
  final bram = Ecp5Dp16kd(
    dataWidthA: 9,
    dataWidthB: 9,
    writeModeA: writeModeA,
    writeModeB: writeModeB,
    clkA: clk,
    ceA: Const(1),
    oceA: Const(0),
    weA: weA,
    rstA: Const(0),
    adA: adA,
    diA: diA,
    clkB: clk,
    ceB: Const(1),
    oceB: Const(0),
    weB: weB,
    rstB: Const(0),
    adB: adB,
    diB: diB,
  );
  await bram.build();
  for (final l in [weA, adA, diA, weB, adB, diB]) {
    l.inject(0);
  }
  Simulator.setMaxSimTime(10000);
  unawaited(Simulator.run());
  await clk.nextNegedge;
  int? val(Logic l) =>
      l.value.getRange(0, 9).isValid ? l.value.getRange(0, 9).toInt() : null;
  final out = <(int?, int?)>[];
  for (final (wa, aa, da, wb, ab, db) in cycles) {
    weA.put(wa ? 1 : 0);
    adA.put(x9(aa));
    diA.put(da);
    weB.put(wb ? 1 : 0);
    adB.put(x9(ab));
    diB.put(db);
    await clk.nextNegedge;
    out.add((val(bram.doA), val(bram.doB)));
  }
  return out;
}

void main() {
  tearDown(() async {
    await Simulator.endSimulation();
    await Simulator.reset();
  });

  test('x9 read shows one edge after the address', () async {
    final p = _Port();
    await p.start();
    await p.cycle(ad: x9(5), di: 0x1A5, we: true);
    await p.cycle(ad: x9(6), di: 0x0C3, we: true);
    expect(await p.cycle(ad: x9(5)), 0x1A5);
    expect(await p.cycle(ad: x9(6)), 0x0C3);
  });

  for (final (mode, want) in [
    ('NORMAL', 0x11),
    ('WRITETHROUGH', 0x22),
    ('READBEFOREWRITE', 0x33),
  ]) {
    test('WRITEMODE $mode decides DO during a write', () async {
      final p = _Port(writeMode: mode);
      await p.start();
      await p.cycle(ad: x9(1), di: 0x11, we: true);
      await p.cycle(ad: x9(2), di: 0x33, we: true);
      expect(await p.cycle(ad: x9(1)), 0x11);
      expect(await p.cycle(ad: x9(2), di: 0x22, we: true), want);
      expect(await p.cycle(ad: x9(2)), 0x22);
    });
  }

  test('OUTREG adds a cycle and loads only with OCE', () async {
    final p = _Port(regMode: 'OUTREG');
    await p.start();
    await p.cycle(ad: x9(3), di: 0x77, we: true);
    await p.cycle(ad: x9(4), di: 0x88, we: true);
    expect(await p.cycle(ad: x9(3)), isNot(0x77));
    expect(await p.cycle(ad: x9(4)), 0x77);
    expect(await p.cycle(ad: x9(4), oce: false), 0x77);
    expect(await p.cycle(ad: x9(4)), 0x88);
  });

  test('CE low and a CS that does not match CSDECODE hold DO and block '
      'the write', () async {
    final p = _Port(csDecode: '0b101');
    await p.start();
    await p.cycle(ad: x9(7), di: 0x44, we: true, cs: 5);
    expect(await p.cycle(ad: x9(7), cs: 5), 0x44);
    expect(
      await p.cycle(ad: x9(8), di: 0x99, we: true, ce: false, cs: 5),
      0x44,
    );
    expect(await p.cycle(ad: x9(8), di: 0x99, we: true, cs: 0), 0x44);
    expect(await p.cycle(ad: x9(8), cs: 5), 0);
  });

  test('a synchronous reset clears DO and blocks the write', () async {
    final p = _Port();
    await p.start();
    await p.cycle(ad: x9(9), di: 0x5A, we: true);
    expect(await p.cycle(ad: x9(9)), 0x5A);
    expect(await p.cycle(ad: x9(9), di: 0xA5, we: true, rst: true), 0);
    expect(await p.cycle(ad: x9(9)), 0x5A);
  });

  test(
    'x18 writes only the halves whose byte enable AD[1:0] is high',
    () async {
      final p = _Port(width: 18);
      await p.start();
      // Word 2 is AD[13:4] = 2. AD[1:0] = 0 writes nothing.
      await p.cycle(ad: (2 << 4) | 0, di: 0x3FFFF, we: true);
      expect(await p.cycle(ad: 2 << 4), 0);
      await p.cycle(ad: (2 << 4) | 1, di: 0x3FFFF, we: true);
      expect(await p.cycle(ad: 2 << 4), 0x1FF);
      await p.cycle(ad: (2 << 4) | 3, di: 0x12345, we: true);
      expect(await p.cycle(ad: 2 << 4), 0x12345);
    },
  );

  test('INITVAL contents read back', () async {
    final words = [for (var i = 0; i < 40; i++) BigInt.from(i * 3)];
    final p = _Port(width: 18, initVals: Ecp5Dp16kd.initVals(words));
    await p.start();
    expect(await p.cycle(ad: 0 << 4), 0);
    expect(await p.cycle(ad: 17 << 4), 51);
    expect(await p.cycle(ad: 39 << 4), 117);
  });

  test('a write on port A and a read of that word on port B give X', () async {
    final out = await _dual([
      (true, 4, 0x55, false, 0, 0),
      (true, 4, 0x66, false, 4, 0),
      (false, 0, 0, false, 4, 0),
    ]);
    expect(out[1].$2, isNull);
    expect(out[2].$2, 0x66);
  });

  test('a read on port A of the word port B writes gives X', () async {
    final out = await _dual([
      (false, 4, 0, true, 4, 0x66),
      (false, 4, 0, false, 4, 0),
    ]);
    expect(out[0].$1, isNull);
    expect(out[1].$1, 0x66);
  });

  test('a write and a read of different words on one edge stay valid', () async {
    final out = await _dual([
      (true, 4, 0x55, false, 0, 0),
      // Words 4 and 5 share one x18 word but not their bits.
      (true, 5, 0x66, false, 4, 0),
      (true, 6, 0x77, false, 5, 0),
    ]);
    expect(out[1].$2, 0x55);
    expect(out[2].$2, 0x66);
  });

  test('two writes of one word on one edge make it X', () async {
    final out = await _dual([
      (true, 9, 0x11, true, 9, 0x22),
      (false, 9, 0, false, 9, 0),
      (true, 9, 0x33, false, 0, 0),
      (false, 9, 0, false, 9, 0),
    ]);
    expect(out[1].$1, isNull);
    expect(out[1].$2, isNull);
    expect(out[3].$2, 0x33);
  });

  for (final (mode, want) in [
    ('NORMAL', 0x11),
    ('WRITETHROUGH', 0x22),
    ('READBEFOREWRITE', 0x11),
  ]) {
    test('WRITEMODE $mode on one port is unchanged by a read of another '
        'word on the other port', () async {
      final out = await _dual(
        [
          (true, 2, 0x11, false, 0, 0),
          (false, 2, 0, false, 0, 0),
          (true, 2, 0x22, false, 3, 0),
        ],
        writeModeA: mode,
      );
      expect(out[2].$1, want);
      expect(out[2].$2, 0);
    });
  }

  test('Ecp5InitRom runtime write lands and reads back', () async {
    // x18 takes its byte enables from AD[1:0], so the write port must drive
    // them high. Tied low, a patch never reaches the block.
    final clk = SimpleClockGenerator(10).clk;
    final rdAddr = Logic(name: 'rd_addr', width: 6);
    final wrEn = Logic(name: 'wr_en');
    final wrAddr = Logic(name: 'wr_addr', width: 6);
    final wrData = Logic(name: 'wr_data', width: 24);
    final rom = Ecp5InitRom(
      clk,
      contents: [for (var i = 0; i < 64; i++) BigInt.from(0x100000 + i)],
      width: 24,
      rdAddr: rdAddr,
      wrEn: wrEn,
      wrAddr: wrAddr,
      wrData: wrData,
      definitionName: 'TestInitRom',
    );
    await rom.build();
    rdAddr.inject(7);
    wrEn.inject(0);
    wrAddr.inject(0);
    wrData.inject(0);
    Simulator.setMaxSimTime(10000);
    unawaited(Simulator.run());
    await clk.nextNegedge;
    await clk.nextNegedge;
    expect(rom.rdData.value.toInt(), 0x100007);
    wrEn.put(1);
    wrAddr.put(7);
    wrData.put(0xABCDEF);
    await clk.nextNegedge;
    // The read of word 7 on the edge of its write is a port collision.
    expect(rom.rdData.value.isValid, isFalse);
    wrEn.put(0);
    await clk.nextNegedge;
    await clk.nextNegedge;
    expect(rom.rdData.value.toInt(), 0xABCDEF);
  });
}
