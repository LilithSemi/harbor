import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test('short peer pulse between edges resets the full domain', () async {
    final clk = SimpleClockGenerator(10).clk;
    final own = Logic(name: 'own');
    final other = Logic(name: 'other');
    final joined = harborCdcJoinReset(clk, own, other, stages: 3);

    own.inject(1);
    other.inject(0);
    Simulator.registerAction(20, () => own.put(0));
    // Posedges fall at 5 + 10k. This 2 time-unit pulse sits between two
    // edges, so no edge of clk samples it.
    Simulator.registerAction(102, () => other.put(1));
    Simulator.registerAction(104, () => other.put(0));

    final seen = <int, bool>{};
    for (final t in [90, 103, 110, 120, 130, 140]) {
      Simulator.registerAction(t, () {
        seen[t] = joined.value.toBool();
      });
    }
    Simulator.setMaxSimTime(200);
    await Simulator.run();
    // Three edges of clk see the joined reset high.
    expect(
      seen,
      equals({
        90: false,
        103: true,
        110: true,
        120: true,
        130: false,
        140: false,
      }),
    );
  });
}
