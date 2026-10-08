import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());

  Future<void> withBridge(
    Future<void> Function(WishboneInterface wb, TileLinkInterface tl, Logic clk)
    body,
  ) async {
    final wbConfig = WishboneConfig(
      addressWidth: 32,
      dataWidth: 32,
      useErr: true,
    );
    final wb = WishboneInterface(wbConfig);
    final tlConfig = TileLinkConfig(addressWidth: 32, dataWidth: 32);
    final tl = TileLinkInterface(tlConfig);

    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    WishboneToTileLinkBridge(wb, tl, clk: clk, reset: reset);

    wb.cyc.inject(0);
    wb.stb.inject(0);
    wb.we.inject(0);
    wb.adr.inject(0);
    wb.datMosi.inject(0);
    wb.sel.inject(0xf);
    tl.aReady.inject(1);
    tl.dValid.inject(0);
    tl.dData.inject(0);
    tl.dDenied.inject(0);

    reset.inject(1);
    Simulator.setMaxSimTime(20000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    await clk.nextPosedge;

    await body(wb, tl, clk);
    await Simulator.endSimulation();
  }

  // A classic master samples ACK at the next edge and holds CYC/STB until
  // then. The bridge must not take that held request as a new one.
  Future<void> holdThroughAck(Logic clk, Logic aValid) async {
    await clk.nextPosedge;
    await clk.nextNegedge;
    expect(aValid.value, equals(LogicValue.zero), reason: 'request reissued');
  }

  test('normal read: Channel A issued once, D completes with ACK', () async {
    await withBridge((wb, tl, clk) async {
      tl.dData.inject(0xcafef00d);
      tl.dValid.inject(1);
      wb.we.inject(0);
      wb.adr.inject(0x100);
      wb.cyc.inject(1);
      wb.stb.inject(1);
      await clk.nextPosedge; // A becomes valid
      await clk.nextNegedge;
      expect(tl.aValid.value, equals(LogicValue.one));
      expect(tl.aOpcode.value.toInt(), equals(4)); // Get
      await clk.nextPosedge; // A accepted
      await clk.nextNegedge;
      expect(
        tl.aValid.value,
        equals(LogicValue.zero),
        reason: 'A must not stay valid once accepted',
      );
      await clk.nextPosedge; // D accepted, ACK presented
      expect(wb.ack.value, equals(LogicValue.one));
      expect(wb.err!.value, equals(LogicValue.zero));
      expect(wb.datMiso.value.toInt(), equals(0xcafef00d));
      await holdThroughAck(clk, tl.aValid);
      wb.cyc.inject(0);
      wb.stb.inject(0);
      tl.dValid.inject(0);
    });
  });

  test(
    'normal write: Channel A issued once as Put, D completes with ACK',
    () async {
      await withBridge((wb, tl, clk) async {
        tl.dValid.inject(1);
        wb.we.inject(1);
        wb.adr.inject(0x200);
        wb.datMosi.inject(0x1234);
        wb.cyc.inject(1);
        wb.stb.inject(1);
        await clk.nextPosedge; // A becomes valid
        await clk.nextNegedge;
        expect(tl.aOpcode.value.toInt(), equals(0)); // PutFullData
        await clk.nextPosedge; // A accepted
        await clk.nextPosedge; // D accepted, ACK presented
        expect(wb.ack.value, equals(LogicValue.one));
        expect(wb.err!.value, equals(LogicValue.zero));
        await holdThroughAck(clk, tl.aValid);
        wb.cyc.inject(0);
        wb.stb.inject(0);
        tl.dValid.inject(0);
      });
    },
  );

  test('error response: D_DENIED reports ERR, not ACK', () async {
    await withBridge((wb, tl, clk) async {
      wb.we.inject(0);
      wb.adr.inject(0x300);
      wb.cyc.inject(1);
      wb.stb.inject(1);
      await clk.nextPosedge;
      tl.dDenied.inject(1);
      tl.dValid.inject(1);
      await clk.nextPosedge;
      await clk.nextPosedge;
      expect(wb.err!.value, equals(LogicValue.one));
      expect(wb.ack.value, equals(LogicValue.zero));
      await holdThroughAck(clk, tl.aValid);
      wb.cyc.inject(0);
      wb.stb.inject(0);
      tl.dValid.inject(0);
      tl.dDenied.inject(0);
    });
  });

  test(
    'backpressure: A_READY withheld, A stays valid until accepted',
    () async {
      await withBridge((wb, tl, clk) async {
        tl.aReady.inject(0);
        wb.we.inject(0);
        wb.adr.inject(0x400);
        wb.cyc.inject(1);
        wb.stb.inject(1);
        await clk.nextPosedge;
        for (var i = 0; i < 5; i++) {
          await clk.nextNegedge;
          expect(tl.aValid.value, equals(LogicValue.one));
          expect(wb.ack.value, equals(LogicValue.zero));
          await clk.nextPosedge;
        }
        tl.aReady.inject(1);
        await clk.nextPosedge; // A finally accepted
        await clk.nextNegedge;
        expect(tl.aValid.value, equals(LogicValue.zero));
        tl.dData.inject(0x77);
        tl.dValid.inject(1);
        await clk.nextPosedge; // D accepted, ACK presented
        expect(wb.ack.value, equals(LogicValue.one));
        wb.cyc.inject(0);
        wb.stb.inject(0);
        tl.dValid.inject(0);
      });
    },
  );

  test(
    'abort: CYC drops before D arrives, response is drained and dropped',
    () async {
      await withBridge((wb, tl, clk) async {
        wb.we.inject(0);
        wb.adr.inject(0x500);
        wb.cyc.inject(1);
        wb.stb.inject(1);
        await clk.nextPosedge; // A accepted, now waiting on D
        wb.cyc.inject(0);
        wb.stb.inject(0);
        for (var i = 0; i < 5; i++) {
          await clk.nextPosedge;
          expect(wb.ack.value, equals(LogicValue.zero));
          expect(wb.err!.value, equals(LogicValue.zero));
        }
        tl.dData.inject(0xdead);
        tl.dValid.inject(1);
        await clk.nextNegedge;
        expect(
          tl.dReady.value,
          equals(LogicValue.one),
          reason: 'the orphaned response must still be drained',
        );
        await clk.nextPosedge;
        await clk.nextPosedge;
        expect(wb.ack.value, equals(LogicValue.zero));
        expect(wb.err!.value, equals(LogicValue.zero));
        tl.dValid.inject(0);

        // A fresh transaction afterwards must complete cleanly.
        wb.we.inject(0);
        wb.adr.inject(0x504);
        wb.cyc.inject(1);
        wb.stb.inject(1);
        await clk.nextPosedge;
        tl.dData.inject(0x9999);
        tl.dValid.inject(1);
        await clk.nextPosedge;
        await clk.nextPosedge;
        expect(wb.ack.value, equals(LogicValue.one));
        expect(wb.datMiso.value.toInt(), equals(0x9999));
        wb.cyc.inject(0);
        wb.stb.inject(0);
        tl.dValid.inject(0);
      });
    },
  );

  test('one Channel A per classic transfer in a block cycle', () async {
    await withBridge((wb, tl, clk) async {
      tl.dValid.inject(1);
      var lastA = 0;
      final aAddrs = <int>[];
      clk.negedge.listen((_) {
        if (tl.aValid.value.toBool() && tl.aReady.value.toBool()) {
          lastA = tl.aAddress.value.toInt();
          aAddrs.add(lastA);
        }
        tl.dData.inject(lastA);
      });

      Future<int> xfer(bool we, int adr) async {
        wb.we.inject(we ? 1 : 0);
        wb.adr.inject(adr);
        wb.datMosi.inject(adr);
        wb.cyc.inject(1);
        wb.stb.inject(1);
        for (var g = 0; g < 50; g++) {
          await clk.nextNegedge;
          if (wb.ack.value.toBool() || wb.err!.value.toBool()) {
            final d = wb.datMiso.value.toInt();
            await clk.nextPosedge;
            return d;
          }
        }
        return -1;
      }

      final r1 = await xfer(false, 0x100);
      final r2 = await xfer(false, 0x200);
      await xfer(true, 0x300);
      wb.cyc.inject(0);
      wb.stb.inject(0);
      for (var i = 0; i < 10; i++) {
        await clk.nextPosedge;
      }
      expect(r1, equals(0x100));
      expect(r2, equals(0x200));
      expect(aAddrs, equals([0x100, 0x200, 0x300]));
    });
  });

  test('abort while A_READY is low keeps the issued payload', () async {
    await withBridge((wb, tl, clk) async {
      tl.aReady.inject(0);
      wb.we.inject(1);
      wb.adr.inject(0x600);
      wb.datMosi.inject(0x11223344);
      wb.sel.inject(0x3);
      wb.cyc.inject(1);
      wb.stb.inject(1);
      await clk.nextPosedge;
      wb.cyc.inject(0);
      wb.stb.inject(0);
      wb.we.inject(0);
      wb.adr.inject(0x700);
      wb.datMosi.inject(0xffffffff);
      wb.sel.inject(0xf);
      for (var i = 0; i < 4; i++) {
        await clk.nextNegedge;
        expect(tl.aValid.value, equals(LogicValue.one));
        expect(tl.aOpcode.value.toInt(), equals(0));
        expect(tl.aAddress.value.toInt(), equals(0x600));
        expect(tl.aSize.value.toInt(), equals(1));
        expect(tl.aData.value.toInt(), equals(0x11223344));
        expect(tl.aMask.value.toInt(), equals(0x3));
      }
      tl.aReady.inject(1);
      tl.dValid.inject(1);
      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
        expect(wb.ack.value, equals(LogicValue.zero));
      }
      await clk.nextNegedge;
      expect(tl.aValid.value, equals(LogicValue.zero));
      expect(tl.dReady.value, equals(LogicValue.zero));
    });
  });
}
