import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  group('HarborPlic', () {
    test('creates with defaults', () {
      final plic = HarborPlic(baseAddress: 0x0C000000);
      expect(plic.externalInterrupt, hasLength(1));
      expect(plic.sourceInterrupt, hasLength(32));
    });

    test('creates with custom params', () {
      final plic = HarborPlic(
        baseAddress: 0x0C000000,
        sources: 64,
        contexts: 4,
        priorityBits: 4,
      );
      expect(plic.externalInterrupt, hasLength(4));
      expect(plic.sourceInterrupt, hasLength(64));
    });

    test('has bus interface', () {
      final plic = HarborPlic(baseAddress: 0x0C000000);
      expect(plic.bus, isNotNull);
    });

    test('DT node is correct', () {
      final plic = HarborPlic(baseAddress: 0x0C000000, sources: 32);
      final dt = plic.dtNode;
      expect(dt.compatible.first, equals('sifive,plic-1.0.0'));
      expect(dt.interruptController, isTrue);
      expect(dt.properties['riscv,ndev'], equals(32));
    });
  });

  laneTests();
}

// Bus-lane decode, driven the way the core drives it. The master puts a
// word-aligned address on the bus and shifts the write data and SEL into the
// byte lane of the access. On a 64-bit bus the claim/complete register
// (offset 0x200004) is in lane 1 of the bus word at 0x200000, the same word as
// the threshold register.
void laneTests() {
  group('HarborPlic bus lane decode', () {
    late HarborPlic plic;
    late Logic clk, reset, stb, we, adr, mosi, sel;
    late List<Logic> srcs;
    late int busBytes;

    const nSources = 4;

    Future<void> setUpDut({required int dataWidth}) async {
      busBytes = dataWidth ~/ 8;
      plic = HarborPlic(
        baseAddress: 0x0C000000,
        sources: nSources,
        contexts: 1,
        busAddressWidth: 32,
        busDataWidth: dataWidth,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      stb = Logic(name: 'stb');
      we = Logic(name: 'we');
      adr = Logic(name: 'adr', width: 32);
      mosi = Logic(name: 'mosi', width: dataWidth);
      sel = Logic(name: 'sel', width: busBytes);
      srcs = [for (var i = 0; i < nSources; i++) Logic(name: 'src_$i')];

      plic.input('clk').srcConnection! <= clk;
      plic.input('reset').srcConnection! <= reset;
      plic.input('bus_CYC').srcConnection! <= stb;
      plic.input('bus_STB').srcConnection! <= stb;
      plic.input('bus_WE').srcConnection! <= we;
      plic.input('bus_ADR').srcConnection! <= adr;
      plic.input('bus_DAT_MOSI').srcConnection! <= mosi;
      plic.input('bus_SEL').srcConnection! <= sel;
      for (var i = 0; i < nSources; i++) {
        plic.input('src_irq_$i').srcConnection! <= srcs[i];
      }

      await plic.build();

      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      sel.inject(0);
      for (final s in srcs) {
        s.inject(0);
      }
      Simulator.setMaxSimTime(200000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    }

    BigInt maskOf(int bits) => (BigInt.one << bits) - BigInt.one;

    Future<void> coreWrite(int byteAddr, int bytes, BigInt value) async {
      final lane = byteAddr % busBytes;
      adr.inject(byteAddr - lane);
      mosi.inject(
        LogicValue.ofBigInt(
          (value << (lane * 8)) & maskOf(busBytes * 8),
          busBytes * 8,
        ),
      );
      sel.inject(((1 << bytes) - 1) << lane);
      we.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (plic.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      stb.inject(0);
      we.inject(0);
      await clk.nextPosedge;
    }

    Future<BigInt> coreRead(int byteAddr, int bytes) async {
      final lane = byteAddr % busBytes;
      adr.inject(byteAddr - lane);
      sel.inject(((1 << bytes) - 1) << lane);
      we.inject(0);
      stb.inject(1);
      await clk.nextPosedge;
      while (plic.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final raw = plic.output('bus_DAT_MISO').value.toBigInt();
      stb.inject(0);
      await clk.nextPosedge;
      return (raw >> (lane * 8)) & maskOf(bytes * 8);
    }

    tearDown(() async {
      await Simulator.reset();
    });

    // The full driver sequence Linux runs: set a priority, enable the source,
    // wait for the external interrupt, claim it, then complete it.
    Future<void> claimCompleteFlow() async {
      // Priority of source 1 lives at offset 4, which is lane 1 on a 64-bit bus.
      await coreWrite(0x4, 4, BigInt.one);
      expect(await coreRead(0x4, 4), equals(BigInt.one));
      // Priority of source 2 must not have moved.
      expect(await coreRead(0x8, 4), equals(BigInt.zero));

      // Enable source 1 for context 0.
      await coreWrite(0x2000, 4, BigInt.two);

      srcs[1].inject(1);
      await clk.nextPosedge;
      await clk.nextPosedge;
      expect(plic.output('ext_irq_0').value.toInt(), equals(1));

      // Threshold and claim share a bus word on a 64-bit bus. Reading the
      // threshold must return the threshold, not the claim id.
      expect(await coreRead(0x200000, 4), equals(BigInt.zero));

      // Claim returns the source id and masks it.
      expect(await coreRead(0x200004, 4), equals(BigInt.one));
      await clk.nextPosedge;
      expect(plic.output('ext_irq_0').value.toInt(), equals(0));

      // Complete releases the source. The input is low again, so the interrupt
      // stays quiet.
      srcs[1].inject(0);
      await clk.nextPosedge;
      await coreWrite(0x200004, 4, BigInt.one);
      await clk.nextPosedge;
      expect(plic.output('ext_irq_0').value.toInt(), equals(0));

      // The threshold register still holds its own value after all of that.
      await coreWrite(0x200000, 4, BigInt.from(3));
      expect(await coreRead(0x200000, 4), equals(BigInt.from(3)));
    }

    test('64-bit bus: claim and complete work in lane 1', () async {
      await setUpDut(dataWidth: 64);
      await claimCompleteFlow();
      await Simulator.endSimulation();
    });

    test('32-bit bus keeps the plain word behaviour', () async {
      await setUpDut(dataWidth: 32);
      await claimCompleteFlow();
      await Simulator.endSimulation();
    });
  });
}
