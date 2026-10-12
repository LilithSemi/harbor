import 'package:harbor/src/peripherals/ddr3_config.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:harbor/src/peripherals/ddr3_timing.dart';
import 'package:test/test.dart';

/// The AX7203 DDR3: two MT41J256M16HA-125 on a 32-bit bus at 400 MHz.
///
/// The ns values are the Micron MT41J256M16 -125 (DDR3-1600) datasheet
/// values. At tCK 2.5 ns each one rounds up to the nCK below. The controller
/// clock is CK/4, 10 ns.
void main() {
  const c = HarborDdrConfig.ax7203();
  final p = DdrParams.fromConfig(c, ckPeriodPs: 2500);
  final t = DdrTiming.fromPs(
    ddr3ClkPeriodPs: p.ddr3ClkPeriodPs,
    serdesRatio: p.serdesRatio,
    controllerClkRatio: p.controllerClkRatio,
    density: p.density,
  );

  test('geometry is 2 x 4 Gb x16, 8 banks, 15 rows, 10 columns', () {
    expect(c.type, HarborDdrType.ddr3);
    expect(c.dataWidth, 32);
    expect(c.frequency, 400000000);
    expect(c.dataRate, 800000000);
    expect(c.banks, 8);
    expect(c.rowWidth, 15);
    expect(c.colWidth, 10);
    expect(c.casLatency, 6);
    expect(c.density, DdrDensity.gb4);
    expect(c.size, c.banks * (1 << c.rowWidth) * (1 << c.colWidth) * 4);
    expect(c.size, 1 << 30);
  });

  test('controller params carry four lanes and the full 1 GB', () {
    expect(p.lanes, 4);
    expect(p.rowBits, 15);
    expect(p.colBits, 10);
    expect(p.baBits, 3);
    expect(p.wbDataBits, 256);
    expect(p.controllerClkRatio, 4);
    expect(p.sizeBytes, c.size);
  });

  group('AC timings at 400 MHz, in nCK (rounded up)', () {
    for (final (name, ns, nck) in [
      ('tRCD 13.75 ns', DdrTiming.tRcd, 6),
      ('tRP 13.75 ns', DdrTiming.tRp, 6),
      ('tRAS 35 ns', DdrTiming.tRas, 14),
      ('tWR 15 ns', DdrTiming.tWr, 6),
      // max(4 nCK, 7.5 ns) = 10 ns at tCK 2.5 ns.
      ('tWTR', t.tWtr, 4),
      ('tRTP', t.tRtp, 4),
      // The datasheet gives 260 ns for 4 Gb. 300 ns is the safe value used.
      ('tRFC', t.tRfc, 120),
    ]) {
      test(name, () => expect(t.nsToNck(ns), nck));
    }

    test('tRC 48.75 ns (20 nCK) is met by tRAS + tRP', () {
      expect(t.nsToNck(48.75), 20);
      expect(t.nsToNck(DdrTiming.tRas) + t.nsToNck(DdrTiming.tRp), 20);
    });

    test('CL 6 and CWL 5 (DDR3-800 bin)', () {
      expect(DdrTiming.clNck, 6);
      expect(DdrTiming.cwlNck, 5);
    });

    test('MR0 write recovery field', () {
      expect(t.wr, DdrTiming.wraModeRegisterValue(6));
    });
  });

  group('waits in 10 ns controller cycles', () {
    test('tREFI 7.8 us', () => expect(t.nsToCycles(7800), 780));
    test('tRFC 300 ns', () => expect(t.nsToCycles(t.tRfc), 30));
    test('tXPR = tRFC + 10 ns', () => expect(t.nsToCycles(t.tXpr), 31));
    // max(12 nCK, 15 ns), also covers tMRD 4 nCK.
    test('tMOD 12 nCK', () => expect(t.tMod, 3));
    // max(512 nCK, 640 ns).
    test('tZQinit 512 nCK', () => expect(t.tZqInit, 128));
  });

  test('x16 presets keep their geometry through fromConfig', () {
    final arty = DdrParams.fromConfig(
      const HarborDdrConfig.artyS7(),
      ckPeriodPs: 3333,
    );
    final ref = DdrParams.artyS7(ckPeriodPs: 3333);
    expect(arty.lanes, ref.lanes);
    expect(arty.rowBits, ref.rowBits);
    expect(arty.colBits, ref.colBits);
    expect(arty.density, ref.density);
    expect(arty.wbAddrBits, ref.wbAddrBits);
  });

  group('fromConfig rejects a config that is not a DDR3 part', () {
    void rejects(HarborDdrConfig cfg, String field) => expect(
      () => DdrParams.fromConfig(cfg, ckPeriodPs: 2500),
      throwsA(isA<ArgumentError>().having((e) => e.name, 'name', field)),
    );

    test('size must match the geometry', () {
      rejects(
        const HarborDdrConfig(
          type: HarborDdrType.ddr3,
          size: 128 * 1024 * 1024,
          frequency: 400000000,
          rowWidth: 14,
        ),
        'config.size',
      );
    });

    test('banks must be 8', () {
      rejects(
        const HarborDdrConfig(
          type: HarborDdrType.ddr3,
          size: 128 * 1024 * 1024,
          frequency: 400000000,
          banks: 4,
          rowWidth: 14,
        ),
        'config.banks',
      );
    });

    test('data width must be 1, 2 or 4 lanes', () {
      rejects(
        const HarborDdrConfig(
          type: HarborDdrType.ddr3,
          size: 3 * 256 * 1024 * 1024,
          dataWidth: 24,
          frequency: 400000000,
        ),
        'config.dataWidth',
      );
    });
  });
}
