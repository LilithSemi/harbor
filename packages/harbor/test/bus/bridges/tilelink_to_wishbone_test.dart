import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());

  Future<void> withBridge(
    Future<void> Function(TileLinkInterface tl, WishboneInterface wb, Logic clk)
    body,
  ) async {
    final tlConfig = TileLinkConfig(addressWidth: 32, dataWidth: 32);
    final tl = TileLinkInterface(tlConfig);
    final wbConfig = WishboneConfig(
      addressWidth: 32,
      dataWidth: 32,
      useErr: true,
    );
    final wb = WishboneInterface(wbConfig);

    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    TileLinkToWishboneBridge(tl, wb, clk: clk, reset: reset);

    tl.aValid.inject(0);
    tl.aOpcode.inject(4); // Get
    tl.aParam.inject(0);
    tl.aSize.inject(2);
    tl.aSource.inject(0);
    tl.aAddress.inject(0);
    tl.aMask.inject(0xf);
    tl.aData.inject(0);
    tl.aCorrupt.inject(0);
    tl.dReady.inject(1);
    wb.ack.inject(0);
    wb.datMiso.inject(0);
    wb.err!.inject(0);

    reset.inject(1);
    Simulator.setMaxSimTime(20000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    await clk.nextPosedge;

    await body(tl, wb, clk);
    await Simulator.endSimulation();
  }

  test('normal read: CYC/STB issued once, D completes with ACK', () async {
    await withBridge((tl, wb, clk) async {
      wb.ack.inject(1);
      wb.datMiso.inject(0xcafef00d);
      tl.aOpcode.inject(4); // Get
      tl.aAddress.inject(0x100);
      tl.aValid.inject(1);
      await clk.nextPosedge; // CYC/STB asserted
      await clk.nextNegedge;
      expect(wb.cyc.value, equals(LogicValue.one));
      expect(wb.we.value, equals(LogicValue.zero));
      await clk.nextPosedge; // ACK observed, D latched
      await clk.nextNegedge;
      expect(
        wb.cyc.value,
        equals(LogicValue.zero),
        reason: 'CYC must not stay up once ACK is seen',
      );
      expect(tl.dValid.value, equals(LogicValue.one));
      expect(tl.dDenied.value, equals(LogicValue.zero));
      expect(tl.dData.value.toInt(), equals(0xcafef00d));
      tl.aValid.inject(0);
      await clk.nextPosedge; // D_READY drains it
      expect(tl.dValid.value, equals(LogicValue.zero));
      wb.ack.inject(0);
    });
  });

  test(
    'normal write: CYC/STB issued once as a write, D completes with ACK',
    () async {
      await withBridge((tl, wb, clk) async {
        wb.ack.inject(1);
        tl.aOpcode.inject(0); // PutFullData
        tl.aAddress.inject(0x200);
        tl.aData.inject(0x1234);
        tl.aValid.inject(1);
        await clk.nextPosedge; // CYC/STB asserted
        await clk.nextNegedge;
        expect(wb.we.value, equals(LogicValue.one));
        await clk.nextPosedge; // ACK observed, D latched
        expect(tl.dValid.value, equals(LogicValue.one));
        expect(tl.dOpcode.value.toInt(), equals(0)); // AccessAck
        tl.aValid.inject(0);
        wb.ack.inject(0);
      });
    },
  );

  test('error response: WB ERR reports D_DENIED, not a fake ACK', () async {
    await withBridge((tl, wb, clk) async {
      tl.aOpcode.inject(4);
      tl.aAddress.inject(0x300);
      tl.aValid.inject(1);
      await clk.nextPosedge;
      wb.err!.inject(1);
      await clk.nextPosedge;
      expect(tl.dValid.value, equals(LogicValue.one));
      expect(tl.dDenied.value, equals(LogicValue.one));
      tl.aValid.inject(0);
      wb.err!.inject(0);
    });
  });

  test('RTY holds and re-presents the same request (no false ACK)', () async {
    await withBridge((tl, wb, clk) async {
      tl.aOpcode.inject(4);
      tl.aAddress.inject(0x310);
      tl.aValid.inject(1);
      await clk.nextPosedge;
      // Neither ACK nor ERR: the Wishbone side is retrying (RTY). CYC/STB
      // must stay asserted on the same address, not drop or fake-ack.
      for (var i = 0; i < 4; i++) {
        await clk.nextNegedge;
        expect(wb.cyc.value, equals(LogicValue.one));
        expect(wb.adr.value.toInt(), equals(0x310));
        expect(tl.dValid.value, equals(LogicValue.zero));
        await clk.nextPosedge;
      }
      wb.ack.inject(1);
      await clk.nextPosedge;
      expect(tl.dValid.value, equals(LogicValue.one));
      expect(tl.dDenied.value, equals(LogicValue.zero));
      tl.aValid.inject(0);
      wb.ack.inject(0);
    });
  });

  test(
    'backpressure: D_READY withheld, response held without re-executing',
    () async {
      await withBridge((tl, wb, clk) async {
        tl.dReady.inject(0);
        wb.ack.inject(1);
        wb.datMiso.inject(0x55);
        tl.aOpcode.inject(4);
        tl.aAddress.inject(0x400);
        tl.aValid.inject(1);
        await clk.nextPosedge; // CYC/STB asserted
        await clk.nextPosedge; // ACK observed, D latched but not drained
        for (var i = 0; i < 5; i++) {
          await clk.nextNegedge;
          expect(tl.dValid.value, equals(LogicValue.one));
          expect(tl.dData.value.toInt(), equals(0x55));
          await clk.nextPosedge;
        }
        // A new Channel A request must not be accepted while the old
        // response is still undrained.
        await clk.nextNegedge;
        expect(tl.aReady.value, equals(LogicValue.zero));
        tl.dReady.inject(1);
        await clk.nextPosedge; // response drains
        await clk.nextNegedge;
        expect(tl.dValid.value, equals(LogicValue.zero));
        expect(tl.aReady.value, equals(LogicValue.one));
        tl.aValid.inject(0);
        wb.ack.inject(0);
      });
    },
  );

  test('abort-equivalent: A has no mid-flight cancel, but a slow WB slave '
      'never produces a spurious ACK', () async {
    await withBridge((tl, wb, clk) async {
      tl.aOpcode.inject(4);
      tl.aAddress.inject(0x500);
      tl.aValid.inject(1);
      await clk.nextPosedge; // CYC/STB asserted, slave never acks
      for (var i = 0; i < 10; i++) {
        await clk.nextPosedge;
        expect(tl.dValid.value, equals(LogicValue.zero));
      }
      wb.ack.inject(1);
      await clk.nextPosedge;
      expect(tl.dValid.value, equals(LogicValue.one));
      tl.aValid.inject(0);
      wb.ack.inject(0);
    });
  });
}
