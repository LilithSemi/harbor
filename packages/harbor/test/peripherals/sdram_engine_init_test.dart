import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_stack.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test('full 200 us init at 125 MHz', () async {
    final s = SdramEngineStack(clockHz: 125000000, fastInit: false);
    await s.start();
    expect(s.cycle, greaterThan(25000));
    await s.idle(100);
    await s.stop();
    expect(s.errors, isEmpty);

    final log = s.model.log;
    expect(log.length, greaterThanOrEqualTo(10));
    expect(log[0].kind, 'precharge');
    expect(log[0].a & (1 << 10), isNot(0));
    expect(log[0].timePs, greaterThanOrEqualTo(200000000));
    expect(log[1].kind, 'mrs');
    expect(log[1].a, 0x233);
    for (var i = 2; i < 10; i++) {
      expect(log[i].kind, 'refresh');
    }
    expect(s.model.initDone, isTrue);
  });
}
