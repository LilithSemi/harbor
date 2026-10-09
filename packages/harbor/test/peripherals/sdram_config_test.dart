import 'package:harbor/src/peripherals/sdram_config.dart';
import 'package:harbor/src/peripherals/sdram_cycles.dart';
import 'package:harbor/src/peripherals/sdram_timing.dart';
import 'package:test/test.dart';

void main() {
  group('HarborSdramTiming', () {
    test('refiEffPs matches the datasheet refresh budget', () {
      final cycles = HarborSdramCycles(
        const HarborSdramConfig.as4c16m16sb6(),
        clockHz: 125000000,
      );
      expect(cycles.refiEffPs, equals(7797270));
    });
  });

  group('HarborSdramConfig geometry', () {
    const config = HarborSdramConfig.as4c16m16sb6();

    test('bankBits is 2 for 4 banks', () {
      expect(config.bankBits, equals(2));
    });

    test('wordAddrWidth is 24', () {
      expect(config.wordAddrWidth, equals(24));
    });

    test('sizeBytes is 32 MiB', () {
      expect(config.sizeBytes, equals(32 * 1024 * 1024));
    });

    test('pageBytes is 1024', () {
      expect(config.pageBytes, equals(1024));
    });

    test('addressMap defaults to rowBankCol', () {
      expect(config.addressMap, equals(HarborSdramAddressMap.rowBankCol));
    });

    test('bankRowCol is a distinct address map', () {
      const alt = HarborSdramConfig.as4c16m16sb6(
        addressMap: HarborSdramAddressMap.bankRowCol,
      );
      expect(alt.addressMap, equals(HarborSdramAddressMap.bankRowCol));
      expect(alt.addressMap, isNot(equals(config.addressMap)));
    });
  });

  group('HarborSdramConfig mode register', () {
    const config = HarborSdramConfig.as4c16m16sb6();

    test('CL3 mode register is 0x233', () {
      expect(config.modeRegister(3), equals(0x233));
    });

    test('CL2 mode register is 0x223', () {
      expect(config.modeRegister(2), equals(0x223));
    });

    test('non-BL8 config cannot encode a mode register', () {
      final bl4 = HarborSdramConfig(
        part: 'test',
        timing: HarborSdramTiming.as4c16m16sb6(),
        rowWidth: 13,
        colWidth: 9,
        burstLength: 4,
      );
      expect(() => bl4.modeRegister(3), throwsArgumentError);
    });
  });

  group('HarborSdramCycles expected cycle table', () {
    const cases = [
      (
        clockHz: 100000000,
        cl: 2,
        rc: 6,
        rfc: 6,
        rcd: 2,
        rp: 2,
        rasMin: 5,
        rrd: 2,
        mrd: 2,
        wr: 2,
        refi: 779,
        powerUp: 20000,
        readHiz: 1,
      ),
      (
        clockHz: 125000000,
        cl: 3,
        rc: 8,
        rfc: 8,
        rcd: 3,
        rp: 3,
        rasMin: 6,
        rrd: 2,
        mrd: 2,
        wr: 2,
        refi: 974,
        powerUp: 25000,
        readHiz: 2,
      ),
      (
        clockHz: 133333333,
        cl: 3,
        rc: 8,
        rfc: 8,
        rcd: 3,
        rp: 3,
        rasMin: 6,
        rrd: 2,
        mrd: 2,
        wr: 2,
        refi: 1039,
        powerUp: 26667,
        readHiz: 2,
      ),
      (
        clockHz: 150000000,
        cl: 3,
        rc: 9,
        rfc: 9,
        rcd: 3,
        rp: 3,
        rasMin: 7,
        rrd: 2,
        mrd: 2,
        wr: 2,
        refi: 1169,
        powerUp: 30000,
        readHiz: 2,
      ),
    ];

    for (final c in cases) {
      test('${c.clockHz} Hz picks CL${c.cl} and matches the cycle table', () {
        final cycles = HarborSdramCycles(
          const HarborSdramConfig.as4c16m16sb6(),
          clockHz: c.clockHz,
        );
        expect(cycles.casLatency, equals(c.cl));
        expect(cycles.rc, equals(c.rc));
        expect(cycles.rfc, equals(c.rfc));
        expect(cycles.rcd, equals(c.rcd));
        expect(cycles.rp, equals(c.rp));
        expect(cycles.rasMin, equals(c.rasMin));
        expect(cycles.rrd, equals(c.rrd));
        expect(cycles.mrd, equals(c.mrd));
        expect(cycles.wr, equals(c.wr));
        expect(cycles.refi, equals(c.refi));
        expect(cycles.powerUp, equals(c.powerUp));
        expect(cycles.readHiz, equals(c.readHiz));
        expect(cycles.modeRegister, equals(c.cl == 3 ? 0x233 : 0x223));
      });
    }

    test('166 MHz throws with the ECP5 LVCMOS33 limit', () {
      expect(
        () => HarborSdramCycles(
          const HarborSdramConfig.as4c16m16sb6(),
          clockHz: 166000000,
          phyMaxClockHz: 150000000,
        ),
        throwsArgumentError,
      );
    });

    test('166 MHz passes without a phy limit', () {
      expect(
        () => HarborSdramCycles(
          const HarborSdramConfig.as4c16m16sb6(),
          clockHz: 166000000,
        ),
        returnsNormally,
      );
    });

    test('200 MHz always throws (no CL fits)', () {
      expect(
        () => HarborSdramCycles(
          const HarborSdramConfig.as4c16m16sb6(),
          clockHz: 200000000,
        ),
        throwsArgumentError,
      );
      expect(
        () => HarborSdramCycles(
          const HarborSdramConfig.as4c16m16sb6(),
          clockHz: 200000000,
          phyMaxClockHz: 250000000,
        ),
        throwsArgumentError,
      );
    });
  });

  group('HarborSdramCycles throw cases', () {
    test('explicit CL too slow for the clock throws', () {
      const config = HarborSdramConfig.as4c16m16sb6(casLatency: 2);
      expect(
        () => HarborSdramCycles(config, clockHz: 125000000),
        throwsArgumentError,
      );
    });

    test('burstLength != 8 throws', () {
      final config = HarborSdramConfig(
        part: 'test',
        timing: HarborSdramTiming.as4c16m16sb6(),
        rowWidth: 13,
        colWidth: 9,
        burstLength: 4,
      );
      expect(
        () => HarborSdramCycles(config, clockHz: 125000000),
        throwsArgumentError,
      );
    });

    test('singleWrite false throws', () {
      final config = HarborSdramConfig(
        part: 'test',
        timing: HarborSdramTiming.as4c16m16sb6(),
        rowWidth: 13,
        colWidth: 9,
        singleWrite: false,
      );
      expect(
        () => HarborSdramCycles(config, clockHz: 125000000),
        throwsArgumentError,
      );
    });

    test('clockHz above phyMaxClockHz throws', () {
      const config = HarborSdramConfig.as4c16m16sb6();
      expect(
        () => HarborSdramCycles(
          config,
          clockHz: 125000000,
          phyMaxClockHz: 100000000,
        ),
        throwsArgumentError,
      );
    });

    test('refiEffPs >= tRefi throws', () {
      const timing = HarborSdramTiming.as4c16m16sb6();
      final config = HarborSdramConfig(
        part: 'test',
        timing: timing,
        rowWidth: 13,
        colWidth: 9,
      );
      expect(
        () => HarborSdramCycles(
          config,
          clockHz: 125000000,
          maxPostponedRefresh: 1,
          maxPulledInRefresh: 0,
        ),
        throwsArgumentError,
      );
    });

    test('rowAgeLimit <= 0 throws', () {
      const timing = HarborSdramTiming.as4c16m16sb6();
      final shortRas = timing.copyWith(tRasMax: 5.0);
      final config = HarborSdramConfig.as4c16m16sb6().copyWith(
        timing: shortRas,
      );
      expect(
        () => HarborSdramCycles(config, clockHz: 125000000),
        throwsArgumentError,
      );
    });

    test('maxPostponedRefresh < 1 throws', () {
      const config = HarborSdramConfig.as4c16m16sb6();
      expect(
        () => HarborSdramCycles(
          config,
          clockHz: 125000000,
          maxPostponedRefresh: 0,
        ),
        throwsArgumentError,
      );
    });

    test('maxPulledInRefresh < 0 throws', () {
      const config = HarborSdramConfig.as4c16m16sb6();
      expect(
        () => HarborSdramCycles(
          config,
          clockHz: 125000000,
          maxPulledInRefresh: -1,
        ),
        throwsArgumentError,
      );
    });

    test('initRefreshes below the datasheet minimum throws', () {
      const config = HarborSdramConfig.as4c16m16sb6();
      final tooFew = HarborSdramConfig(
        part: config.part,
        timing: config.timing,
        rowWidth: config.rowWidth,
        colWidth: config.colWidth,
        initRefreshes: 1,
      );
      expect(
        () => HarborSdramCycles(tooFew, clockHz: 125000000),
        throwsArgumentError,
      );
    });
  });

  group('HarborSdramConfig construction validation', () {
    test('banks not a power of two throws', () {
      expect(
        () => HarborSdramConfig(
          part: 'test',
          timing: const HarborSdramTiming.as4c16m16sb6(),
          banks: 3,
          rowWidth: 13,
          colWidth: 9,
        ),
        throwsArgumentError,
      );
    });

    test('rowWidth below 11 throws', () {
      expect(
        () => HarborSdramConfig(
          part: 'test',
          timing: const HarborSdramTiming.as4c16m16sb6(),
          rowWidth: 10,
          colWidth: 9,
        ),
        throwsArgumentError,
      );
    });

    test('colWidth below 3 throws', () {
      expect(
        () => HarborSdramConfig(
          part: 'test',
          timing: const HarborSdramTiming.as4c16m16sb6(),
          rowWidth: 13,
          colWidth: 2,
        ),
        throwsArgumentError,
      );
    });

    test('colWidth above 9 throws (would put a column bit on A10)', () {
      expect(
        () => HarborSdramConfig(
          part: 'test',
          timing: const HarborSdramTiming.as4c16m16sb6(),
          rowWidth: 13,
          colWidth: 10,
        ),
        throwsArgumentError,
      );
    });
  });

  group('readToWrite', () {
    test('counts CAS latency, burst beats and read high-Z', () {
      final cycles = HarborSdramCycles(
        const HarborSdramConfig.as4c16m16sb6(),
        clockHz: 125000000,
      );
      expect(cycles.readToWrite(8), equals(3 + 8 + 2));
    });
  });
}
