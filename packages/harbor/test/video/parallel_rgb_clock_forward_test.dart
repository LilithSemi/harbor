import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// [HarborPixelClockForward] picks a different clock-forward primitive per
/// target, the same way [TmdsSerializer] does for its output register. Each
/// case must show its own primitive, since a wrong pick fails quietly (a
/// blackbox with no body drives nothing, so the clock pin stays dark).
void main() {
  const ecp5 = HarborFpgaTarget.ecp5(device: 'lfe5u-85f', package: 'CABGA381');
  const arty = HarborFpgaTarget.spartan7(
    device: 'xc7s50',
    package: 'csga324',
    useOpenXc7: true,
  );

  HarborPixelClockForward build(
    HarborDeviceTarget target, {
    HarborParallelRgbLatchEdge latchEdge = HarborParallelRgbLatchEdge.falling,
  }) => HarborPixelClockForward(
    clk: Logic(name: 'clk'),
    target: target,
    latchEdge: latchEdge,
  );

  test('a simulation forwards the clock with plain logic', () async {
    final fwd = build(const HarborSimTarget());
    await fwd.build();
    final sv = fwd.generateSynth();
    expect(
      sv,
      isNot(contains('ODDRX1F')),
      reason:
          'a simulation must not carry a Lattice cell: it stands for no '
          'real part',
    );
    expect(sv, isNot(contains('ODDR ')));
  });

  test('an ECP5 build uses ODDRX1F', () async {
    final fwd = build(ecp5);
    await fwd.build();
    expect(fwd.generateSynth(), contains('ODDRX1F'));
  });

  test('a Xilinx 7-series build uses ODDR', () async {
    final fwd = build(arty);
    await fwd.build();
    final sv = fwd.generateSynth();
    expect(sv, contains('ODDR'));
    expect(sv, isNot(contains('ODDRX1F')));
  });

  test('iCE40 says why it cannot, instead of building something dark', () {
    expect(
      () =>
          build(const HarborFpgaTarget.ice40(device: 'up5k', package: 'sg48')),
      throwsUnsupportedError,
    );
  });
}
