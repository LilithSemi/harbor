import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// The TMDS output register is the one part of the display path that is a hard
/// cell, so it is the part that changes with the target. These tests hold the
/// three cases apart, because picking the wrong one fails quietly: a black box
/// with no body drives nothing, and the display simply stays dark.
void main() {
  const ecp5 = HarborFpgaTarget.ecp5(device: 'lfe5u-85f', package: 'CABGA381');
  const arty = HarborFpgaTarget.spartan7(
    device: 'xc7s50',
    package: 'csga324',
    useOpenXc7: true,
  );

  TmdsSerializer build(HarborDeviceTarget target) => TmdsSerializer(
    shiftClk: Logic(name: 'shift_clk'),
    reset: Logic(name: 'reset'),
    symbol: Logic(name: 'symbol', width: 10),
    align: Logic(name: 'align'),
    target: target,
  );

  test('a simulation uses plain logic, not a vendor cell', () async {
    final ser = build(const HarborSimTarget());
    await ser.build();
    final sv = ser.generateSynth();
    expect(
      sv,
      contains('HarborDdrOutput'),
      reason: 'a simulation needs a body it can run',
    );
    expect(
      sv,
      isNot(contains('ODDRX1F')),
      reason:
          'a simulation must not carry a Lattice cell: it stands for no '
          'real part, and the cell has no body to run',
    );
    expect(sv, isNot(contains('ODDR ')));
  });

  test('an ECP5 build uses the Lattice cell and one pin per lane', () async {
    final ser = build(ecp5);
    await ser.build();
    expect(ser.generateSynth(), contains('ODDRX1F'));
    // LVCMOS33D makes the complement in the pad, so the design drives one pin.
    expect(() => ser.qn, throwsA(anything));
  });

  test('an Arty build uses the Xilinx cell and drives both pins', () async {
    final ser = build(arty);
    await ser.build();
    final sv = ser.generateSynth();
    expect(sv, contains('ODDR'));
    expect(sv, isNot(contains('ODDRX1F')));

    // The complement comes from its own output register. A gate on q instead
    // would put the two lanes a gate delay apart, and a TMDS receiver reads
    // the difference between them.
    expect(TmdsSerializer.needsComplement(arty), isTrue);
    expect(ser.qn, isNotNull);
    expect(
      RegExp('ODDR').allMatches(sv).length,
      greaterThanOrEqualTo(2),
      reason: 'one output register per pin, true and complement',
    );
  });

  test('iCE40 says why it cannot, instead of building something dark', () {
    expect(
      () =>
          build(const HarborFpgaTarget.ice40(device: 'up5k', package: 'sg48')),
      throwsUnsupportedError,
    );
  });
}
