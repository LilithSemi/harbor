import 'package:harbor/src/peripherals/ddr3_config.dart';
import 'package:harbor/src/peripherals/ddr3_timing.dart';
import 'package:test/test.dart';

/// Bytes the geometry addresses: banks * rows * columns * bytes per column.
int _geometryBytes(HarborDdrConfig c) =>
    c.banks * (1 << c.rowWidth) * (1 << c.colWidth) * (c.dataWidth ~/ 8);

void main() {
  group('HarborDdrConfig board presets match their DRAM part', () {
    test('OrangeCrab is a 1 Gb MT41K64M16 (13 row, 10 col, 8 banks)', () {
      const c = HarborDdrConfig.orangeCrab();
      expect(c.rowWidth, 13);
      expect(c.colWidth, 10);
      expect(c.banks, 8);
      expect(c.density, DdrDensity.gb1);
      expect(c.density.tRfcNs, 110.0);
      expect(_geometryBytes(c), c.size);
    });

    test('Arty S7 is a 2 Gb MT41K128M16 (14 row, 10 col, 8 banks)', () {
      const c = HarborDdrConfig.artyS7();
      expect(c.rowWidth, 14);
      expect(c.colWidth, 10);
      expect(c.density, DdrDensity.gb2);
      expect(_geometryBytes(c), c.size);
    });
  });
}
