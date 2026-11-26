import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// DviOutput is structural (its encoder/timing/serializer pieces are unit-
/// tested elsewhere), so this verifies it elaborates and wires the expected
/// submodules: one timing generator, three TMDS encoders, and four serializers
/// (three data channels plus the clock channel) onto a 4-bit GPDI output.
void main() {
  test('elaborates with three encoders and four serializers', () async {
    final pixelClk = Logic(name: 'pixel_clk');
    final shiftClk = Logic(name: 'shift_clk');
    final pixelReset = Logic(name: 'pixel_reset');
    final shiftReset = Logic(name: 'shift_reset');
    final dvi = DviOutput(
      target: const HarborSimTarget(),
      timing: const HarborDisplayTiming.vga640x480(),
      pixelClk: pixelClk,
      shiftClk: shiftClk,
      pixelReset: pixelReset,
      shiftReset: shiftReset,
    );
    await dvi.build();
    final sv = dvi.dumpSystemVerilog();

    expect(dvi.gpdi.width, equals(4));
    expect(sv, contains('VideoTimingGenerator'));
    expect('TmdsEncoder'.allMatches(sv).length, greaterThanOrEqualTo(3));
    expect('TmdsSerializer'.allMatches(sv).length, greaterThanOrEqualTo(4));
  });
}
