import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

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
  });

  group('HarborTrng operation', () {
    late HarborTrng trng;
    late Logic clk, reset, cyc, stb, we, adr, mosi;

    Future<int> busRead(int byteAddr) async {
      adr.inject(byteAddr);
      mosi.inject(0);
      we.inject(0);
      cyc.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (trng.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final data = trng.bus.dataOut.value.toInt();
      cyc.inject(0);
      stb.inject(0);
      await clk.nextPosedge;
      return data;
    }

    Future<void> setUpDut({required int seed, required Logic noiseSrc}) async {
      trng = HarborTrng(HarborTrngConfig(baseAddress: 0x40000000, seed: seed));
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      cyc = Logic(name: 'cyc');
      stb = Logic(name: 'stb');
      we = Logic(name: 'we');
      adr = Logic(name: 'adr', width: trng.input('bus_ADR').width);
      mosi = Logic(name: 'mosi', width: 32);

      trng.input('clk').srcConnection! <= clk;
      trng.input('reset').srcConnection! <= reset;
      trng.input('noise').srcConnection! <= noiseSrc;
      trng.input('bus_CYC').srcConnection! <= cyc;
      trng.input('bus_STB').srcConnection! <= stb;
      trng.input('bus_WE').srcConnection! <= we;
      trng.input('bus_ADR').srcConnection! <= adr;
      trng.input('bus_DAT_MOSI').srcConnection! <= mosi;
      trng.input('bus_SEL').srcConnection! <=
          Const(0xF, width: trng.input('bus_SEL').width);

      await trng.build();

      reset.inject(1);
      cyc.inject(0);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
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
  });
}
