import 'dart:async';
import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

List<BigInt> _pattern(int depth, int width) {
  final mask = (BigInt.one << width) - BigInt.one;
  return [
    for (var a = 0; a < depth; a++)
      (BigInt.from(a) * BigInt.from(0x2D5B7) + BigInt.from(0x3C7)) & mask,
  ];
}

Future<Ecp5InitRom> _start({
  required List<BigInt> contents,
  required int width,
  required Logic clk,
  required Logic rdAddr,
  Logic? wrEn,
  Logic? wrAddr,
  Logic? wrData,
}) async {
  final rom = Ecp5InitRom(
    clk,
    contents: contents,
    width: width,
    rdAddr: rdAddr,
    wrEn: wrEn,
    wrAddr: wrAddr,
    wrData: wrData,
    definitionName: 'DepthRom${contents.length}x$width',
  );
  await rom.build();
  rdAddr.inject(0);
  wrEn?.inject(0);
  wrAddr?.inject(0);
  wrData?.inject(0);
  Simulator.setMaxSimTime(100000000);
  unawaited(Simulator.run());
  await clk.nextNegedge;
  return rom;
}

Future<void> _readAll(
  Ecp5InitRom rom,
  Logic clk,
  Logic rdAddr,
  List<BigInt> contents,
) async {
  for (var a = 0; a < contents.length; a++) {
    rdAddr.put(a);
    await clk.nextNegedge;
    expect(rom.rdData.value.toBigInt(), contents[a], reason: 'addr $a');
  }
}

void _readTest(String name, int depth, int width, int dataWidth, int pages) {
  test('$name reads every word', () async {
    expect(Ecp5InitRom.plan(depth, width).dataWidth, dataWidth);
    expect(Ecp5InitRom.plan(depth, width).pages, pages);
    final contents = _pattern(depth, width);
    final clk = SimpleClockGenerator(10).clk;
    final rdAddr = Logic(name: 'rd_addr', width: 14);
    final rom = await _start(
      contents: contents,
      width: width,
      clk: clk,
      rdAddr: rdAddr,
    );
    await _readAll(rom, clk, rdAddr, contents);
    await Simulator.endSimulation();
  });
}

void _patchTest(String name, int depth, int width, int patchAt) {
  test('$name patch write reads back', () async {
    final contents = _pattern(depth, width);
    final clk = SimpleClockGenerator(10).clk;
    final rdAddr = Logic(name: 'rd_addr', width: 14);
    final wrEn = Logic(name: 'wr_en');
    final wrAddr = Logic(name: 'wr_addr', width: 14);
    final wrData = Logic(name: 'wr_data', width: width);
    final rom = await _start(
      contents: contents,
      width: width,
      clk: clk,
      rdAddr: rdAddr,
      wrEn: wrEn,
      wrAddr: wrAddr,
      wrData: wrData,
    );
    final patch = contents[patchAt] ^ ((BigInt.one << width) - BigInt.one);
    wrEn.put(1);
    wrAddr.put(patchAt);
    wrData.put(patch);
    rdAddr.put(0);
    await clk.nextNegedge;
    wrEn.put(0);
    await clk.nextNegedge;
    // Every word is read, so a write that lands in the wrong page shows.
    for (var a = 0; a < depth; a++) {
      rdAddr.put(a);
      await clk.nextNegedge;
      expect(
        rom.rdData.value.toBigInt(),
        a == patchAt ? patch : contents[a],
        reason: 'addr $a',
      );
    }
    await Simulator.endSimulation();
  });
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('plan', () {
    test('keeps x18 up to 1024 words', () {
      for (final w in [1, 9, 18, 19, 36, 139]) {
        for (final d in [1, 64, 679, 1024]) {
          final p = Ecp5InitRom.plan(d, w);
          expect(p.dataWidth, 18, reason: '$d x $w');
          expect(p.pages, 1);
          expect(p.blocks, (w + 17) ~/ 18);
        }
      }
    });

    test('picks the narrow mode with fewer blocks', () {
      expect(Ecp5InitRom.plan(2048, 18).dataWidth, 9);
      expect(Ecp5InitRom.plan(2048, 18).blocks, 2);
      expect(Ecp5InitRom.plan(2048, 9).dataWidth, 9);
      expect(Ecp5InitRom.plan(2048, 9).blocks, 1);
      expect(Ecp5InitRom.plan(4096, 4).dataWidth, 4);
      expect(Ecp5InitRom.plan(8192, 2).dataWidth, 2);
      expect(Ecp5InitRom.plan(16384, 1).dataWidth, 1);
      expect(Ecp5InitRom.plan(16384, 1).blocks, 1);
    });

    test('keeps x18 pages when they use fewer blocks', () {
      final p = Ecp5InitRom.plan(3000, 18);
      expect((p.dataWidth, p.pages, p.blocks), (18, 3, 3));
    });

    test('ties go to fewer pages then the wider mode', () {
      // 1100 x 18: x18 needs 2 blocks and 2 pages, x9 2 blocks and 1 page.
      expect(Ecp5InitRom.plan(1100, 18).dataWidth, 9);
      // 1024 x 9: x18 and x9 both use 1 block and 1 page.
      expect(Ecp5InitRom.plan(1024, 9).dataWidth, 18);
    });
  });

  group('INITVAL packing', () {
    // Unpacks per the yosys memory_libmap init swizzle: the physical word w
    // is INITVAL[w ~/ 16] bits [(w % 16) * 20 +: 18], and slot s of a narrow
    // mode sits at the bit offset listed for that mode.
    BigInt unpack(List<BigInt> iv, int mode, int e) {
      final per = {18: 1, 9: 2, 4: 4, 2: 8, 1: 16}[mode]!;
      final w = e ~/ per;
      final s = e % per;
      final base = mode == 18
          ? 0
          : mode == 9
          ? s * 9
          : (s ~/ (per ~/ 2)) * 9 + (s % (per ~/ 2)) * mode;
      final phys =
          (iv[w ~/ 16] >> ((w % 16) * 20)) & ((BigInt.one << 18) - BigInt.one);
      return (phys >> base) & ((BigInt.one << mode) - BigInt.one);
    }

    for (final m in [18, 9, 4, 2, 1]) {
      test('x$m round trips', () {
        final depth = 1024 * 18 ~/ (m == 18 ? 18 : (m == 9 ? 9 : 8));
        final entries = _pattern(depth, m);
        final iv = Ecp5Dp16kd.initValsForWidth(entries, m);
        expect(iv.length, 64);
        for (var e = 0; e < depth; e++) {
          expect(unpack(iv, m, e), entries[e], reason: 'x$m entry $e');
        }
      });
    }
  });

  group('sim', () {
    _readTest('1025 x 18 (x9)', 1025, 18, 9, 1);
    _readTest('2048 x 9', 2048, 9, 9, 1);
    _readTest('4096 x 4', 4096, 4, 4, 1);
    _readTest('3000 x 18 (3 x18 pages)', 3000, 18, 18, 3);
    _readTest('2500 x 40 (x18 pages)', 2500, 40, 18, 3);
    _patchTest('3000 x 18', 3000, 18, 1500);
    _patchTest('2048 x 9', 2048, 9, 1500);
    _patchTest('4096 x 4', 4096, 4, 3000);
    _patchTest('8192 x 2', 8192, 2, 5000);
    _patchTest('5000 x 9 (x9 pages)', 5000, 9, 3000);
    _patchTest('9000 x 4 (x4 pages)', 9000, 4, 6000);
    _patchTest('3000 x 18 low page', 3000, 18, 20);
    _readTest('8192 x 2', 8192, 2, 2, 1);
    _readTest('16384 x 1', 16384, 1, 1, 1);
    _readTest('5000 x 9', 5000, 9, 9, 3);
  });

  group('emit', () {
    test('1024 x 18 output equals the earlier output', () async {
      // The golden file holds the output of the code before narrow modes.
      final c = [
        for (var a = 0; a < 5; a++)
          (BigInt.from(a + 1) * BigInt.from(0x2D5B7A1)) &
              ((BigInt.one << 30) - BigInt.one),
      ];
      final rom = Ecp5InitRom(
        Logic(name: 'clk'),
        contents: c,
        width: 30,
        rdAddr: Logic(name: 'a', width: 10),
        wrEn: Logic(name: 'we'),
        wrAddr: Logic(name: 'wa', width: 10),
        wrData: Logic(name: 'wd', width: 30),
        definitionName: 'GoldenRom',
      );
      await rom.build();
      final sv = rom
          .dumpSystemVerilog()
          .split('\n')
          .where((l) => !l.contains('Generation time'))
          .join('\n');
      final golden = File(
        'test/blackbox/golden/ecp5_init_rom_1024.sv',
      ).readAsStringSync();
      expect(sv, golden);
    });

    test('deeper ROM names one block set for each page', () async {
      final rom = Ecp5InitRom(
        Logic(name: 'clk'),
        contents: _pattern(3000, 18),
        width: 18,
        rdAddr: Logic(name: 'a', width: 12),
        definitionName: 'EmitRomDeep',
      );
      await rom.build();
      final sv = rom.dumpSystemVerilog();
      for (final p in [0, 1, 2]) {
        expect(sv, contains('rom_p${p}_w0'));
      }
    });

    test('a rdAddr too narrow for the words throws', () {
      for (final (d, w, bits) in [(3000, 18, 10), (2048, 9, 10), (64, 8, 5)]) {
        expect(
          () => Ecp5InitRom(
            Logic(name: 'clk'),
            contents: _pattern(d, w),
            width: w,
            rdAddr: Logic(name: 'a', width: bits),
            definitionName: 'NarrowRom$d',
          ),
          throwsArgumentError,
          reason: '$d x $w with $bits bits',
        );
      }
    });

    test('a wrAddr too narrow for the words throws', () {
      expect(
        () => Ecp5InitRom(
          Logic(name: 'clk'),
          contents: _pattern(2048, 9),
          width: 9,
          rdAddr: Logic(name: 'a', width: 11),
          wrEn: Logic(name: 'we'),
          wrAddr: Logic(name: 'wa', width: 10),
          wrData: Logic(name: 'wd', width: 9),
          definitionName: 'NarrowWrRom',
        ),
        throwsArgumentError,
      );
    });

    test('initValsForWidth throws for too many entries', () {
      expect(
        () => Ecp5Dp16kd.initValsForWidth(_pattern(2049, 9), 9),
        throwsArgumentError,
      );
    });
  });

  group('write above the ROM', () {
    for (final (d, w) in [(1000, 18), (3000, 18), (2048, 9)]) {
      test('$d x $w ignores an address past the last word', () async {
        final contents = _pattern(d, w);
        final clk = SimpleClockGenerator(10).clk;
        final rdAddr = Logic(name: 'rd_addr', width: 14);
        final wrEn = Logic(name: 'wr_en');
        final wrAddr = Logic(name: 'wr_addr', width: 14);
        final wrData = Logic(name: 'wr_data', width: w);
        final rom = await _start(
          contents: contents,
          width: w,
          clk: clk,
          rdAddr: rdAddr,
          wrEn: wrEn,
          wrAddr: wrAddr,
          wrData: wrData,
        );
        // Addresses one and two pages up alias a real word in the low bits.
        wrEn.put(1);
        wrData.put((BigInt.one << w) - BigInt.one);
        for (final hi in [1 << 13, 1 << 12 | 1 << 13]) {
          wrAddr.put(hi + 100);
          await clk.nextNegedge;
        }
        wrEn.put(0);
        await clk.nextNegedge;
        await _readAll(rom, clk, rdAddr, contents);
        await Simulator.endSimulation();
      });
    }
  });
}
