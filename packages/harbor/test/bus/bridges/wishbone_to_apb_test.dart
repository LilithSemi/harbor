import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' show ApbInterface;
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());

  Future<void> withBridge(
    Future<void> Function(WishboneInterface wb, ApbInterface apb, Logic clk)
    body, {
    bool includeSlvErr = true,
  }) async {
    final wbConfig = WishboneConfig(
      addressWidth: 16,
      dataWidth: 32,
      useErr: true,
    );
    final wb = WishboneInterface(wbConfig);
    final apb = ApbInterface(
      addrWidth: 16,
      dataWidth: 32,
      includeSlvErr: includeSlvErr,
    );
    WishboneToApbBridge(wb, apb);

    final clk = SimpleClockGenerator(10).clk;
    apb.clk <= clk;
    apb.resetN.inject(0);
    wb.cyc.inject(0);
    wb.stb.inject(0);
    wb.we.inject(0);
    wb.adr.inject(0);
    wb.datMosi.inject(0);
    wb.sel.inject(0xf);
    apb.ready.inject(0);
    apb.rData.inject(0);
    if (apb.slvErr != null) apb.slvErr!.inject(0);

    Simulator.setMaxSimTime(20000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    apb.resetN.inject(1);
    await clk.nextPosedge;

    await body(wb, apb, clk);
    await Simulator.endSimulation();
  }

  test('normal write: setup then access, PREADY completes it', () async {
    await withBridge((wb, apb, clk) async {
      wb.we.inject(1);
      wb.adr.inject(0x10);
      wb.datMosi.inject(0x1234);
      wb.cyc.inject(1);
      wb.stb.inject(1);
      // Setup phase: PSEL is up, PENABLE is not.
      await clk.nextNegedge;
      expect(apb.enable.value, equals(LogicValue.zero));
      await clk.nextPosedge; // access phase begins
      expect(apb.enable.value, equals(LogicValue.one));
      expect(apb.write.value, equals(LogicValue.one));
      // ACK/ERR are combinational on PREADY & the access phase: valid
      // within the same cycle PREADY is asserted, not after a further edge.
      apb.ready.inject(1);
      await clk.nextNegedge;
      expect(wb.ack.value, equals(LogicValue.one));
      expect(wb.err, isNotNull);
      expect(wb.err!.value, equals(LogicValue.zero));
      await clk.nextPosedge;
      wb.cyc.inject(0);
      wb.stb.inject(0);
      apb.ready.inject(0);
    });
  });

  test('normal read: data comes back through PRDATA on PREADY', () async {
    await withBridge((wb, apb, clk) async {
      wb.we.inject(0);
      wb.adr.inject(0x20);
      wb.cyc.inject(1);
      wb.stb.inject(1);
      await clk.nextPosedge; // access phase
      apb.rData.inject(0xcafef00d);
      apb.ready.inject(1);
      await clk.nextNegedge;
      expect(wb.ack.value, equals(LogicValue.one));
      expect(wb.datMiso.value.toInt(), equals(0xcafef00d));
      await clk.nextPosedge;
      wb.cyc.inject(0);
      wb.stb.inject(0);
      apb.ready.inject(0);
    });
  });

  test('error response: PSLVERR reports ERR, not ACK', () async {
    await withBridge((wb, apb, clk) async {
      wb.we.inject(0);
      wb.adr.inject(0x30);
      wb.cyc.inject(1);
      wb.stb.inject(1);
      await clk.nextPosedge; // access phase
      apb.ready.inject(1);
      apb.slvErr!.inject(1);
      await clk.nextNegedge;
      expect(wb.err!.value, equals(LogicValue.one));
      expect(wb.ack.value, equals(LogicValue.zero));
      await clk.nextPosedge;
      wb.cyc.inject(0);
      wb.stb.inject(0);
      apb.ready.inject(0);
      apb.slvErr!.inject(0);
    });
  });

  test('ERR ties low when APB has no PSLVERR', () async {
    await withBridge(includeSlvErr: false, (wb, apb, clk) async {
      wb.we.inject(0);
      wb.adr.inject(0x30);
      wb.cyc.inject(1);
      wb.stb.inject(1);
      await clk.nextPosedge; // access phase
      apb.ready.inject(1);
      await clk.nextNegedge;
      expect(wb.ack.value, equals(LogicValue.one));
      expect(wb.err!.value, equals(LogicValue.zero));
      await clk.nextPosedge;
      wb.cyc.inject(0);
      wb.stb.inject(0);
      apb.ready.inject(0);
    });
  });

  test('backpressure: PREADY withheld for several cycles', () async {
    await withBridge((wb, apb, clk) async {
      wb.we.inject(0);
      wb.adr.inject(0x40);
      wb.cyc.inject(1);
      wb.stb.inject(1);
      await clk.nextPosedge; // access phase
      for (var i = 0; i < 5; i++) {
        expect(wb.ack.value, equals(LogicValue.zero));
        await clk.nextPosedge;
      }
      apb.rData.inject(0x55);
      apb.ready.inject(1);
      await clk.nextNegedge;
      expect(wb.ack.value, equals(LogicValue.one));
      await clk.nextPosedge;
      wb.cyc.inject(0);
      wb.stb.inject(0);
      apb.ready.inject(0);
    });
  });

  test(
    'abort: CYC drops mid-access, phase clears, next cycle is clean',
    () async {
      await withBridge((wb, apb, clk) async {
        wb.we.inject(0);
        wb.adr.inject(0x50);
        wb.cyc.inject(1);
        wb.stb.inject(1);
        await clk.nextPosedge; // access begins
        expect(apb.enable.value, equals(LogicValue.one));
        wb.cyc.inject(0);
        wb.stb.inject(0);
        await clk.nextPosedge;
        expect(apb.enable.value, equals(LogicValue.zero));
        expect(wb.ack.value, equals(LogicValue.zero));
        expect(wb.err!.value, equals(LogicValue.zero));

        // A fresh transaction must start cleanly from setup, not a stuck
        // access phase.
        wb.we.inject(0);
        wb.adr.inject(0x54);
        wb.cyc.inject(1);
        wb.stb.inject(1);
        await clk.nextNegedge;
        expect(apb.enable.value, equals(LogicValue.zero));
        await clk.nextPosedge;
        expect(apb.enable.value, equals(LogicValue.one));
        apb.rData.inject(0x99);
        apb.ready.inject(1);
        await clk.nextNegedge;
        expect(wb.ack.value, equals(LogicValue.one));
        await clk.nextPosedge;
        wb.cyc.inject(0);
        wb.stb.inject(0);
        apb.ready.inject(0);
      });
    },
  );
}
