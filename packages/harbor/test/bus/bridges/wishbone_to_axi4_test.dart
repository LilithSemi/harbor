import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());

  Future<void> withBridge(
    Future<void> Function(
      WishboneInterface wb,
      Axi4ReadInterface axiRead,
      Axi4WriteInterface axiWrite,
      Logic clk,
    )
    body,
  ) async {
    final wbConfig = WishboneConfig(
      addressWidth: 32,
      dataWidth: 32,
      useErr: true,
    );
    final wb = WishboneInterface(wbConfig);
    final axiRead = Axi4ReadInterface(
      idWidth: 0,
      addrWidth: 32,
      lenWidth: 0,
      dataWidth: 32,
      aruserWidth: 0,
      ruserWidth: 0,
      useLock: false,
      useLast: false,
    );
    final axiWrite = Axi4WriteInterface(
      idWidth: 0,
      addrWidth: 32,
      lenWidth: 0,
      dataWidth: 32,
      awuserWidth: 0,
      wuserWidth: 0,
      buserWidth: 0,
      useLock: false,
    );

    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    WishboneToAxi4Bridge(wb, axiRead, axiWrite, clk: clk, reset: reset);

    wb.cyc.inject(0);
    wb.stb.inject(0);
    wb.we.inject(0);
    wb.adr.inject(0);
    wb.datMosi.inject(0);
    wb.sel.inject(0xf);
    axiRead.arReady.inject(1);
    axiRead.rValid.inject(0);
    axiRead.rData.inject(0);
    axiRead.rResp!.inject(0);
    axiWrite.awReady.inject(1);
    axiWrite.wReady.inject(1);
    axiWrite.bValid.inject(0);
    axiWrite.bResp!.inject(0);

    reset.inject(1);
    Simulator.setMaxSimTime(20000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    await clk.nextPosedge;

    await body(wb, axiRead, axiWrite, clk);
    await Simulator.endSimulation();
  }

  // A classic master samples ACK at the next edge and holds CYC/STB until
  // then. The bridge must not take that held request as a new one.
  Future<void> holdThroughAck(Logic clk, List<Logic> valids) async {
    await clk.nextPosedge;
    await clk.nextNegedge;
    for (final v in valids) {
      expect(v.value, equals(LogicValue.zero), reason: 'request reissued');
    }
  }

  test('ARSIZE/AWSIZE come from SEL, not a fixed 4 bytes', () async {
    await withBridge((wb, axiRead, axiWrite, clk) async {
      // One byte selected (SEL=0b0001) -> SIZE 0 (1 byte), not the fixed
      // SIZE 2 (4 bytes) the bridge used to always report.
      axiRead.rValid.inject(1);
      wb.we.inject(0);
      wb.adr.inject(0x100);
      wb.sel.inject(0x1);
      wb.cyc.inject(1);
      wb.stb.inject(1);
      await clk.nextPosedge;
      await clk.nextNegedge;
      expect(axiRead.arSize!.value.toInt(), equals(0));
      wb.cyc.inject(0);
      wb.stb.inject(0);
      await clk.nextPosedge;

      axiWrite.bValid.inject(1);
      wb.we.inject(1);
      wb.adr.inject(0x100);
      wb.sel.inject(0x3); // two bytes -> SIZE 1
      wb.datMosi.inject(0x1234);
      wb.cyc.inject(1);
      wb.stb.inject(1);
      // The aborted read drains first, then AW is issued.
      for (var i = 0; i < 5 && !axiWrite.awValid.value.toBool(); i++) {
        await clk.nextNegedge;
      }
      expect(axiWrite.awValid.value, equals(LogicValue.one));
      expect(axiWrite.awSize!.value.toInt(), equals(1));
      wb.cyc.inject(0);
      wb.stb.inject(0);
      axiWrite.bValid.inject(0);
    });
  });

  test('normal read: AR issued once, R completes with ACK', () async {
    await withBridge((wb, axiRead, axiWrite, clk) async {
      axiRead.rData.inject(0xcafef00d);
      axiRead.rValid.inject(1);
      wb.we.inject(0);
      wb.adr.inject(0x100);
      wb.cyc.inject(1);
      wb.stb.inject(1);
      await clk.nextPosedge; // AR becomes valid
      await clk.nextNegedge;
      expect(axiRead.arValid.value, equals(LogicValue.one));
      await clk.nextPosedge; // AR accepted (ARREADY held high)
      await clk.nextNegedge;
      expect(
        axiRead.arValid.value,
        equals(LogicValue.zero),
        reason: 'AR must not stay valid once accepted',
      );
      await clk.nextPosedge; // R accepted, ACK presented
      expect(wb.ack.value, equals(LogicValue.one));
      expect(wb.err!.value, equals(LogicValue.zero));
      expect(wb.datMiso.value.toInt(), equals(0xcafef00d));
      await holdThroughAck(clk, [axiRead.arValid]);
      wb.cyc.inject(0);
      wb.stb.inject(0);
      axiRead.rValid.inject(0);
    });
  });

  test('normal write: AW+W issued once, B completes with ACK', () async {
    await withBridge((wb, axiRead, axiWrite, clk) async {
      axiWrite.bValid.inject(1);
      wb.we.inject(1);
      wb.adr.inject(0x200);
      wb.datMosi.inject(0x1234);
      wb.cyc.inject(1);
      wb.stb.inject(1);
      await clk.nextPosedge; // AW/W become valid
      await clk.nextNegedge;
      expect(axiWrite.awValid.value, equals(LogicValue.one));
      expect(axiWrite.wValid.value, equals(LogicValue.one));
      await clk.nextPosedge; // AW/W accepted
      await clk.nextNegedge;
      expect(axiWrite.awValid.value, equals(LogicValue.zero));
      expect(axiWrite.wValid.value, equals(LogicValue.zero));
      await clk.nextPosedge; // B accepted, ACK presented
      expect(wb.ack.value, equals(LogicValue.one));
      expect(wb.err!.value, equals(LogicValue.zero));
      await holdThroughAck(clk, [axiWrite.awValid, axiWrite.wValid]);
      wb.cyc.inject(0);
      wb.stb.inject(0);
      axiWrite.bValid.inject(0);
    });
  });

  test('error response: RRESP error reports ERR, not ACK', () async {
    await withBridge((wb, axiRead, axiWrite, clk) async {
      wb.we.inject(0);
      wb.adr.inject(0x300);
      wb.cyc.inject(1);
      wb.stb.inject(1);
      await clk.nextPosedge;
      axiRead.rResp!.inject(2); // SLVERR
      axiRead.rValid.inject(1);
      await clk.nextPosedge;
      await clk.nextPosedge;
      expect(wb.err!.value, equals(LogicValue.one));
      expect(wb.ack.value, equals(LogicValue.zero));
      await holdThroughAck(clk, [axiRead.arValid]);
      wb.cyc.inject(0);
      wb.stb.inject(0);
      axiRead.rValid.inject(0);
      axiRead.rResp!.inject(0);
    });
  });

  test(
    'backpressure: ARREADY withheld, AR stays valid until accepted',
    () async {
      await withBridge((wb, axiRead, axiWrite, clk) async {
        axiRead.arReady.inject(0);
        wb.we.inject(0);
        wb.adr.inject(0x400);
        wb.cyc.inject(1);
        wb.stb.inject(1);
        await clk.nextPosedge;
        for (var i = 0; i < 5; i++) {
          await clk.nextNegedge;
          expect(axiRead.arValid.value, equals(LogicValue.one));
          expect(wb.ack.value, equals(LogicValue.zero));
          await clk.nextPosedge;
        }
        axiRead.arReady.inject(1);
        await clk.nextNegedge;
        expect(axiRead.arValid.value, equals(LogicValue.one));
        await clk.nextPosedge; // AR finally accepted
        await clk.nextNegedge;
        expect(axiRead.arValid.value, equals(LogicValue.zero));
        axiRead.rData.inject(0x77);
        axiRead.rValid.inject(1);
        await clk.nextPosedge; // R accepted, ACK presented
        expect(wb.ack.value, equals(LogicValue.one));
        wb.cyc.inject(0);
        wb.stb.inject(0);
        axiRead.rValid.inject(0);
      });
    },
  );

  test(
    'abort: CYC drops before R arrives, response is drained and dropped',
    () async {
      await withBridge((wb, axiRead, axiWrite, clk) async {
        wb.we.inject(0);
        wb.adr.inject(0x500);
        wb.cyc.inject(1);
        wb.stb.inject(1);
        await clk.nextPosedge; // AR accepted, now waiting on R
        wb.cyc.inject(0);
        wb.stb.inject(0);
        // The R response arrives after the abort: AXI4 requires it to be
        // drained (RREADY must still fire), but it must not be acked.
        for (var i = 0; i < 5; i++) {
          await clk.nextPosedge;
          expect(wb.ack.value, equals(LogicValue.zero));
          expect(wb.err!.value, equals(LogicValue.zero));
        }
        axiRead.rData.inject(0xdead);
        axiRead.rValid.inject(1);
        await clk.nextNegedge;
        expect(
          axiRead.rReady.value,
          equals(LogicValue.one),
          reason: 'the orphaned response must still be drained',
        );
        await clk.nextPosedge;
        await clk.nextPosedge;
        expect(wb.ack.value, equals(LogicValue.zero));
        expect(wb.err!.value, equals(LogicValue.zero));
        axiRead.rValid.inject(0);

        // A fresh transaction afterwards must complete cleanly.
        wb.we.inject(0);
        wb.adr.inject(0x504);
        wb.cyc.inject(1);
        wb.stb.inject(1);
        await clk.nextPosedge;
        axiRead.rData.inject(0x9999);
        axiRead.rValid.inject(1);
        await clk.nextPosedge;
        await clk.nextPosedge;
        expect(wb.ack.value, equals(LogicValue.one));
        expect(wb.datMiso.value.toInt(), equals(0x9999));
        wb.cyc.inject(0);
        wb.stb.inject(0);
        axiRead.rValid.inject(0);
      });
    },
  );

  test('one AR or AW/W per classic transfer in a block cycle', () async {
    await withBridge((wb, axiRead, axiWrite, clk) async {
      axiRead.rValid.inject(1);
      axiWrite.bValid.inject(1);
      // R data is the address of the last accepted AR.
      var lastAr = 0;
      var ar = 0;
      final awAddrs = <int>[];
      clk.negedge.listen((_) {
        if (axiRead.arValid.value.toBool() && axiRead.arReady.value.toBool()) {
          ar++;
          lastAr = axiRead.arAddr.value.toInt();
        }
        if (axiWrite.awValid.value.toBool() &&
            axiWrite.awReady.value.toBool()) {
          awAddrs.add(axiWrite.awAddr.value.toInt());
        }
        axiRead.rData.inject(lastAr);
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
      wb.cyc.inject(0);
      wb.stb.inject(0);
      for (var i = 0; i < 10; i++) {
        await clk.nextPosedge;
      }
      await xfer(true, 0x300);
      wb.cyc.inject(0);
      wb.stb.inject(0);
      for (var i = 0; i < 10; i++) {
        await clk.nextPosedge;
      }
      expect(ar, equals(2));
      expect(r1, equals(0x100));
      expect(r2, equals(0x200));
      expect(awAddrs, equals([0x300]));
    });
  });

  test('abort while AWREADY is low keeps the issued payload', () async {
    await withBridge((wb, axiRead, axiWrite, clk) async {
      axiWrite.awReady.inject(0);
      axiWrite.wReady.inject(0);
      wb.we.inject(1);
      wb.adr.inject(0x600);
      wb.datMosi.inject(0x11223344);
      wb.sel.inject(0x3);
      wb.cyc.inject(1);
      wb.stb.inject(1);
      await clk.nextPosedge;
      wb.cyc.inject(0);
      wb.stb.inject(0);
      // The master moves on. The held request must not follow it.
      wb.we.inject(0);
      wb.adr.inject(0x700);
      wb.datMosi.inject(0xffffffff);
      wb.sel.inject(0xf);
      for (var i = 0; i < 4; i++) {
        await clk.nextNegedge;
        expect(axiWrite.awValid.value, equals(LogicValue.one));
        expect(axiWrite.wValid.value, equals(LogicValue.one));
        expect(axiWrite.awAddr.value.toInt(), equals(0x600));
        expect(axiWrite.awSize!.value.toInt(), equals(1));
        expect(axiWrite.wData.value.toInt(), equals(0x11223344));
        expect(axiWrite.wStrb.value.toInt(), equals(0x3));
        expect(axiRead.arValid.value, equals(LogicValue.zero));
      }
      axiWrite.awReady.inject(1);
      axiWrite.wReady.inject(1);
      axiWrite.bValid.inject(1);
      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
        expect(wb.ack.value, equals(LogicValue.zero));
      }
      await clk.nextNegedge;
      expect(axiWrite.awValid.value, equals(LogicValue.zero));
      expect(axiWrite.bReady.value, equals(LogicValue.zero));
    });
  });
}
