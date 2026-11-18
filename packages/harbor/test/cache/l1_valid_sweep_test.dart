import 'package:harbor/harbor.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'l1d_dut.dart';

Future<BigInt> _load(Dut dut, int addr) async {
  dut['req_addr'].inject(addr);
  dut['req_write'].inject(0);
  dut['req_valid'].inject(1);
  for (var i = 0; i < 200; i++) {
    await dut.backing.step();
    expect(dut.respFault, isFalse);
    if (dut.respValid) {
      final data = dut.cache.output('resp_data').value.toBigInt();
      dut['req_valid'].inject(0);
      await dut.backing.step();
      return data;
    }
  }
  fail('load never completed');
}

Future<void> _end() async {
  await Simulator.endSimulation();
  await Simulator.simulationEnded;
}

void main() {
  tearDown(Simulator.reset);

  group('sweep length', () {
    // (size, lineSize, lines, cycles): a RAM word holds 8 lines.
    for (final (size, lineSize, lines, cycles) in [
      (8, 8, 1, 1),
      (32, 8, 4, 1),
      (256, 8, 32, 4),
      (4096, 64, 64, 8),
      (32768, 64, 512, 64),
    ]) {
      test('$lines lines sweep in $cycles cycles', () {
        final i = HarborL1ICache(
          config: HarborL1iCacheConfig(size: size, ways: 1, lineSize: lineSize),
          xlen: 64,
          dualPort: true,
        );
        final d = HarborL1DCache(
          config: HarborL1dCacheConfig(size: size, ways: 1, lineSize: lineSize),
          xlen: 64,
          physicalAddresses: true,
          memFaultIn: Logic(),
        );
        expect(i.sweepCycles, cycles);
        expect(d.sweepCycles, cycles);
      });
    }

    test(
      'busy stays high for the sweep after reset and after a flush',
      () async {
        final dut = await makeDut();
        try {
          for (final (port, holdCycles) in [
            ('reset', 1),
            ('reset', 2),
            ('flush', 1),
            ('flush', 3),
          ]) {
            dut[port].inject(1);
            for (var c = 0; c < holdCycles; c++) {
              await dut.backing.step();
            }
            dut[port].inject(0);
            // Count the cycles after the last reset or flush edge.
            var busyCycles = 0;
            for (var c = 0; c < 20 && dut.busy; c++) {
              busyCycles++;
              await dut.backing.step();
            }
            expect(busyCycles, dut.cache.sweepCycles, reason: '$port');
          }
        } finally {
          await _end();
        }
      },
    );
  });

  test('a load right after reset misses', () async {
    final dut = await makeDut();
    try {
      dut.backing.mem[0x80000010] = BigInt.from(0x11);
      expect(await _load(dut, 0x80000010), BigInt.from(0x11));
      final primed = dut.backing.accesses;
      expect(await _load(dut, 0x80000010), BigInt.from(0x11));
      expect(dut.backing.accesses, primed);

      dut.backing.mem[0x80000010] = BigInt.from(0x22);
      dut['reset'].inject(1);
      await dut.backing.step();
      dut['reset'].inject(0);
      // Present the load on the first cycle after reset.
      expect(await _load(dut, 0x80000010), BigInt.from(0x22));
      expect(dut.backing.accesses, primed + 1);
    } finally {
      await _end();
    }
  });

  test('a load right after a flush misses', () async {
    final dut = await makeDut();
    try {
      for (var a = 0; a < 32; a++) {
        dut.backing.mem[0x80000000 + a * 8] = BigInt.from(a);
      }
      for (var a = 0; a < 32; a++) {
        expect(await _load(dut, 0x80000000 + a * 8), BigInt.from(a));
      }
      final primed = dut.backing.accesses;
      for (var a = 0; a < 32; a++) {
        dut.backing.mem[0x80000000 + a * 8] = BigInt.from(0x100 + a);
      }
      // Keep the load request on the flush cycle and after it.
      dut['req_addr'].inject(0x80000000 + 31 * 8);
      dut['req_valid'].inject(1);
      dut['flush'].inject(1);
      await dut.backing.step();
      dut['flush'].inject(0);
      for (var a = 31; a >= 0; a--) {
        expect(await _load(dut, 0x80000000 + a * 8), BigInt.from(0x100 + a));
      }
      expect(dut.backing.accesses, primed + 32);
    } finally {
      await _end();
    }
  });

  for (final flushAt in [0, 2, 5]) {
    test('flush $flushAt cycles into a fill leaves the line invalid', () async {
      final dut = await makeDut(lineSize: 32, size: 256, latency: 3);
      try {
        const base = 0x80000040;
        for (var w = 0; w < 4; w++) {
          dut.backing.mem[base + w * 8] = BigInt.from(0x10 + w);
        }
        while (dut.busy) {
          await dut.backing.step();
        }
        final before = dut.backing.accesses;
        dut['req_addr'].inject(base + 8);
        dut['req_write'].inject(0);
        dut['req_valid'].inject(1);
        while (dut.backing.accesses == before) {
          await dut.backing.step();
        }
        for (var c = 0; c < flushAt; c++) {
          await dut.backing.step();
        }
        dut['flush'].inject(1);
        await dut.backing.step();
        dut['flush'].inject(0);
        dut['req_valid'].inject(0);
        for (var w = 0; w < 4; w++) {
          dut.backing.mem[base + w * 8] = BigInt.from(0x20 + w);
        }
        for (var c = 0; c < 20; c++) {
          await dut.backing.step();
        }
        // The abandoned fill must not hit with old data.
        for (var w = 0; w < 4; w++) {
          expect(await _load(dut, base + w * 8), BigInt.from(0x20 + w));
        }
        final filled = dut.backing.accesses;
        expect(await _load(dut, base + 16), BigInt.from(0x22));
        expect(dut.backing.accesses, filled);
      } finally {
        await _end();
      }
    });
  }

  test('generated SV keeps the valid bits in a RAM', () async {
    for (final BridgeModule cache in [
      HarborL1ICache(
        config: HarborL1iCacheConfig(size: 32768, ways: 1, lineSize: 64),
        xlen: 64,
        dualPort: true,
      ),
      HarborL1DCache(
        config: HarborL1dCacheConfig(size: 32768, ways: 1, lineSize: 64),
        xlen: 64,
        physicalAddresses: true,
        memFaultIn: Logic(),
      ),
    ]) {
      await cache.build();
      final sv = cache.dumpSystemVerilog();
      expect(sv, isNot(matches(RegExp(r'\bvalid_\d+\b'))));
      expect(sv, contains('HarborL1ValidRam_w8d64'));
      expect(sv, contains('assign rd0_data = mem[rd0_addr];'));
      Simulator.reset();
    }
  });
}
