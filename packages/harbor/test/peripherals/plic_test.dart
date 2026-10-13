import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

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

    test('different params get different definition names', () {
      final a = HarborPlic(baseAddress: 0x0C000000, sources: 32);
      final b = HarborPlic(baseAddress: 0x0C000000, sources: 64);
      expect(a.definitionName, isNot(equals(b.definitionName)));
    });
  });

  for (final kind in HarborFabricKind.values) {
    laneTests(kind);
  }
}

// Bus-lane decode, driven the way the core drives it. The master puts a
// word-aligned address on the bus and shifts the write data and SEL into the
// byte lane of the access. On a 64-bit bus the claim/complete register
// (offset 0x200004) is in lane 1 of the bus word at 0x200000, the same word as
// the threshold register.
void laneTests(HarborFabricKind kind) {
  group('HarborPlic bus lane decode (${kind.name})', () {
    late HarborPlic plic;
    late Logic clk, reset;
    late List<Logic> srcs;
    late RegBus bus;
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
        fabricKind: kind,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      srcs = [for (var i = 0; i < nSources; i++) Logic(name: 'src_$i')];

      plic.input('clk').srcConnection! <= clk;
      plic.input('reset').srcConnection! <= reset;
      for (var i = 0; i < nSources; i++) {
        plic.input('src_irq_$i').srcConnection! <= srcs[i];
      }
      bus = RegBus.attach(plic, clk);

      await plic.build();

      reset.inject(1);
      bus.idle();
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
      final addr = byteAddr - lane;
      final shifted = (value << (lane * 8)) & maskOf(busBytes * 8);
      final sel = ((1 << bytes) - 1) << lane;
      await bus.write(addr, shifted.toInt(), sel: sel);
    }

    // The claim register's read has a side effect gated by SEL (see
    // HarborPlic), so a read must restrict SEL to its own lane just like a
    // write does, instead of RegBus.read's default of every byte.
    Future<BigInt> coreRead(int byteAddr, int bytes) async {
      final lane = byteAddr % busBytes;
      final addr = byteAddr - lane;
      final sel = ((1 << bytes) - 1) << lane;
      final result = await bus.access(addr, sel: sel, write: false);
      final raw = BigInt.from(result.data);
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
      // threshold must return the threshold, not the claim id, and must not
      // claim the pending source either: the external interrupt must stay
      // asserted until the claim register itself is read.
      expect(await coreRead(0x200000, 4), equals(BigInt.zero));
      await clk.nextPosedge;
      expect(plic.output('ext_irq_0').value.toInt(), equals(1));

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

    // A write with no byte selected must not change the priority register,
    // the enable bitmap, the threshold register, or complete a source.
    test('a write with no byte selected changes nothing', () async {
      await setUpDut(dataWidth: 32);

      await coreWrite(0x4, 4, BigInt.one);
      await coreWrite(0x2000, 4, BigInt.two);
      await coreWrite(0x200000, 4, BigInt.from(3));

      await bus.write(0x4, 0xff, sel: 0x0);
      await bus.write(0x2000, 0xffffffff, sel: 0x0);
      await bus.write(0x200000, 0xff, sel: 0x0);

      expect(await coreRead(0x4, 4), equals(BigInt.one));
      expect(await coreRead(0x2000, 4), equals(BigInt.two));
      expect(await coreRead(0x200000, 4), equals(BigInt.from(3)));
      await Simulator.endSimulation();
    });
  });
}
