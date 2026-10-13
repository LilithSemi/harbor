import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

// Register byte offsets presented on the bus address lines.
const _rand = 0x00;
const _status = 0x04;

/// Golden reference for the deterministic seeded stream. Must match the
/// hardware DRBG exactly (a 32-bit xorshift) when seed != 0 and the noise
/// source is held constant (no reseed entropy).
int _goldenNext(int state) {
  var x = state & 0xFFFFFFFF;
  x ^= (x << 13) & 0xFFFFFFFF;
  x ^= x >> 17;
  x ^= (x << 5) & 0xFFFFFFFF;
  return x & 0xFFFFFFFF;
}

void main() {
  group('HarborTrngConfig', () {
    test('defaults and seed', () {
      const config = HarborTrngConfig(baseAddress: 0x40000000);
      expect(config.baseAddress, equals(0x40000000));
      expect(config.seed, equals(0));
    });
  });

  group('HarborTrng metadata', () {
    test('DT node', () {
      final trng = HarborTrng(
        const HarborTrngConfig(baseAddress: 0x40000000, seed: 0xC0FFEE),
      );
      final dt = trng.dtNode;
      expect(dt.compatible.first, equals('lilithsemi,harbor-trng'));
      expect(dt.reg.size, equals(0x1000));
    });

    test('exposes a noise input pin and a bus', () {
      final trng = HarborTrng(const HarborTrngConfig(baseAddress: 0x40000000));
      expect(trng.bus, isNotNull);
      expect(trng.input('noise').width, equals(1));
    });

    test('different seeds get different definition names', () {
      final a = HarborTrng(
        const HarborTrngConfig(baseAddress: 0x40000000, seed: 1),
      );
      final b = HarborTrng(
        const HarborTrngConfig(baseAddress: 0x40000000, seed: 2),
      );
      expect(a.definitionName, isNot(equals(b.definitionName)));
    });
  });

  for (final kind in HarborFabricKind.values) {
    operationTests(kind);
  }
}

void operationTests(HarborFabricKind kind) {
  group('HarborTrng operation (${kind.name})', () {
    late HarborTrng trng;
    late Logic clk, reset;
    late RegBus bus;

    Future<int> busRead(int byteAddr) => bus.read(byteAddr);

    Future<void> setUpDut({
      required int seed,
      required Logic noiseSrc,
      int busDataWidth = 32,
    }) async {
      trng = HarborTrng(
        HarborTrngConfig(baseAddress: 0x40000000, seed: seed),
        fabricKind: kind,
        busDataWidth: busDataWidth,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');

      trng.input('clk').srcConnection! <= clk;
      trng.input('reset').srcConnection! <= reset;
      trng.input('noise').srcConnection! <= noiseSrc;
      bus = RegBus.attach(trng, clk);

      await trng.build();

      reset.inject(1);
      bus.idle();
      Simulator.setMaxSimTime(1000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    }

    tearDown(() async {
      await Simulator.reset();
    });

    test('ready asserts after reset and successive reads differ', () async {
      await setUpDut(seed: 0xC0FFEE, noiseSrc: Const(0));

      final status = await busRead(_status);
      expect(status & 0x1, equals(1), reason: 'ready (bit0) should be high');

      final a = await busRead(_rand);
      final b = await busRead(_rand);
      expect(a, isNot(equals(b)), reason: 'successive RAND reads must differ');

      await Simulator.endSimulation();
    });

    test('deterministic stream matches the software golden', () async {
      const seed = 0xC0FFEE;
      await setUpDut(seed: seed, noiseSrc: Const(0));

      // The hardware presents the current DRBG word on a RAND read and
      // advances afterward, so the stream is seed, xorshift(seed), ...
      var golden = seed;
      for (var i = 0; i < 8; i++) {
        final hw = await busRead(_rand);
        expect(
          hw,
          equals(golden),
          reason: 'RAND word $i mismatch with golden stream',
        );
        golden = _goldenNext(golden);
      }

      await Simulator.endSimulation();
    });

    test('health-test fails when noise is stuck constant', () async {
      await setUpDut(seed: 0xC0FFEE, noiseSrc: Const(0));

      // Clock through enough samples for the continuous health tests to
      // trip on the stuck (constant 0) source.
      for (var i = 0; i < 2048; i++) {
        await clk.nextPosedge;
      }
      final status = await busRead(_status);
      expect(
        (status & 0x2) != 0,
        isTrue,
        reason: 'health-test failed (bit1) should assert for stuck noise',
      );

      await Simulator.endSimulation();
    });

    // RAND has a side effect on read (it advances the DRBG). A write with no
    // byte selected must not trigger that advance.
    test('a write with no byte selected does not advance RAND', () async {
      await setUpDut(seed: 0xC0FFEE, noiseSrc: Const(0));

      final before = await busRead(_rand);
      await bus.write(_rand, 0xffffffff, sel: 0x0);
      final after = await busRead(_rand);
      expect(after, equals(_goldenNext(before)));

      await Simulator.endSimulation();
    });

    // RAND's advance is gated by its own lane (the low 4 bytes of its own
    // slot). On a 64-bit bus the upper 4 bytes are padding and a read of
    // them must not advance the generator.
    test(
      'a read of the padding lane does not advance RAND (64-bit bus)',
      () async {
        await setUpDut(seed: 0xC0FFEE, noiseSrc: Const(0), busDataWidth: 64);

        final before = await bus.read(_rand, sel: 0x0f);
        await bus.read(_rand, sel: 0xf0);
        final after = await bus.read(_rand, sel: 0x0f);
        expect(after, equals(_goldenNext(before)));

        await Simulator.endSimulation();
      },
    );
  });
}
