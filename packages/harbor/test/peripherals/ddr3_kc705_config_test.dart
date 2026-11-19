import 'package:harbor/src/blackbox/xilinx/xilinx.dart';
import 'package:harbor/src/peripherals/ddr3_config.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:harbor/src/peripherals/ddr3_timing.dart';
import 'package:test/test.dart';

/// The KC705 DDR3 at 333.33 MHz and at 300 MHz, with the controller at CK/4.
void main() {
  test('geometry matches four 1 Gb x8 devices of the SODIMM', () {
    const c = HarborDdrConfig.kc705();
    expect(c.dataWidth, 32);
    expect(c.banks, 8);
    expect(c.rowWidth, 14);
    expect(c.colWidth, 10);
    expect(c.size, c.banks * (1 << 14) * (1 << 10) * 4);
    expect(c.readReturnStage, isTrue);
  });

  for (final (hz, ps, controllerMhz) in [
    (333333333, 3000, 83.333),
    (300000000, 3333, 75.0),
  ]) {
    group('ck ${hz ~/ 1000000} MHz', () {
      final c = HarborDdrConfig.kc705(ckHz: hz);
      final p = DdrParams.fromConfig(c, ckPeriodPs: ps);
      final t = DdrTiming.fromPs(
        ddr3ClkPeriodPs: p.ddr3ClkPeriodPs,
        serdesRatio: p.serdesRatio,
        controllerClkRatio: p.controllerClkRatio,
        density: p.density,
      );

      test('every AC time is at least the datasheet time', () {
        for (final (ns, nck) in [
          (DdrTiming.tRcd, 5),
          (DdrTiming.tRp, 5),
          (DdrTiming.tRas, 11),
          (DdrTiming.tWr, 5),
        ]) {
          final n = t.nsToNck(ns);
          expect(n, greaterThanOrEqualTo(nck));
          expect(n * ps / 1000, greaterThanOrEqualTo(ns));
        }
        expect(t.nsToNck(t.tRfc) * ps / 1000, greaterThanOrEqualTo(t.tRfc));
      });

      test('MR0 write recovery field is WR 6, at least the 5 nCK of tWR', () {
        expect(t.wr, 2);
      });

      test('the clock tree gives CK/4 and a 200 MHz reference', () {
        final spec = XilinxDdr3TreeSpec.kc705(coreClkHz: 50000000, ddrCkHz: hz);
        final sol = solveDdr3ClockTree(
          spec.sourceHz,
          spec.ddrCkHz,
          spec.idelayRefHz,
        )!;
        expect(sol.vco / sol.ctrlDivide / 1e6, closeTo(controllerMhz, 0.01));
        expect(sol.vco / sol.refDivide, 200000000);
        expect(sol.ckDivide, sol.ckDivide.roundToDouble());
      });
    });
  }
}
