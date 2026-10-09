import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_stack.dart';

/// A request of 0 words or one that crosses a page stops the simulation.
void main() {
  tearDown(() async => Simulator.reset());

  for (final (name, col, words) in [
    ('0 words', 0, 0),
    ('a page cross', 510, 4),
  ]) {
    test('$name stops the simulation', () async {
      final s = SdramEngineStack(clockHz: 125000000);
      await s.start();
      s.rawRequest(col, words);
      await expectLater(
        s.simRun,
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('is not allowed'),
          ),
        ),
      );
    });
  }

  test('a request over the port limit stops the simulation', () async {
    final s = SdramEngineStack(clockHz: 125000000, portMaxGrantWords: [4]);
    await s.start();
    s.rawRequest(0, 6);
    await expectLater(
      s.simRun,
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('more than its maxGrantWords 4'),
        ),
      ),
    );
  });
}
