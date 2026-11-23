import 'dart:math';
import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Simulator.reset);
  for (final seed in [1, 7, 91]) {
    test(
      'configuration arbitration preserves packets with stalls seed=$seed',
      () async {
        final random = Random(seed);
        final clk = Logic()..inject(0);
        final reset = Logic()..inject(1);
        final data = Logic(width: 64)..inject(0);
        final valid = Logic()..inject(0);
        final last = Logic()..inject(0);
        final ready = Logic(width: 4)..inject(0);
        final cfg = Logic()..inject(0);
        final dut = HarborPcieTrnAxi(
          clk: clk,
          reset: reset,
          linkUp: Const(1),
          rxReady: Const(1),
          txData: data,
          txKeep: Const(255, width: 8),
          txLast: last,
          txValid: valid,
          trnRxData: Const(0, width: 128),
          trnRxRem: Const(0, width: 2),
          trnRxSof: Const(0),
          trnRxEof: Const(0),
          trnRxSrcReady: Const(0),
          trnRxSrcDsc: Const(0),
          trnRxErrFwd: Const(0),
          trnRxBarHit: Const(0, width: 8),
          trnRxEcrcErr: Const(0),
          trnTxDstReady: ready,
          trnTxCfgReq: cfg,
        );
        await dut.build();
        Future<void> edge() async {
          clk.inject(1);
          await Simulator.tick();
          clk.inject(0);
          await Simulator.tick();
        }

        await Simulator.tick();
        await edge();
        reset.inject(0);
        final firsts = <bool>[];
        final lasts = <bool>[];
        for (var packet = 0; packet < 100; packet++) {
          final length = 1 + random.nextInt(17);
          for (var beat = 0; beat < length; beat++) {
            firsts.add(beat == 0);
            lasts.add(beat == length - 1);
          }
        }
        var sent = 0;
        var received = 0;
        var sourceHeld = false;
        var request = false;
        var requestAge = 0;
        var grants = 0;
        var packetOpen = false;
        for (var cycle = 0; cycle < 30000 && received < lasts.length; cycle++) {
          if (!request && random.nextInt(6) == 0) request = true;
          if (!sourceHeld && sent < lasts.length)
            sourceHeld = random.nextInt(4) != 0;
          final sinkReady = random.nextBool();
          cfg.inject(request ? 1 : 0);
          valid.inject(sourceHeld ? 1 : 0);
          data.inject(sent + 1);
          last.inject(sent < lasts.length && lasts[sent] ? 1 : 0);
          ready.inject(sinkReady ? 1 : 0);
          await Simulator.tick();
          final inputTransfer = sourceHeld && dut.txReady.value.toBool();
          if (dut.trnTxSrcReady.value.toBool() && sinkReady) {
            expect(received, lessThan(sent));
            expect(
              dut.trnTxData.value.toBigInt(),
              BigInt.from(received + 1) << 32,
            );
            expect(dut.trnTxSof.value.toBool(), firsts[received]);
            expect(dut.trnTxEof.value.toBool(), lasts[received]);
            packetOpen = !lasts[received];
            received++;
          }
          final grant = dut.trnTxCfgGrant.value.toBool();
          if (grant) {
            expect(request, isTrue);
            expect(packetOpen, isFalse);
            expect(dut.trnTxSrcReady.value.toBool(), isFalse);
            expect(inputTransfer, isFalse);
            grants++;
          }
          await edge();
          if (inputTransfer) {
            sent++;
            sourceHeld = false;
          }
          if (grant) {
            request = false;
            requestAge = 0;
          }
          if (request) {
            requestAge++;
            expect(
              requestAge,
              lessThan(1000),
              reason: 'configuration request deadlocked',
            );
          }
        }
        expect(received, lasts.length);
        expect(sent, lasts.length);
        expect(grants, greaterThan(20));
        await Simulator.run();
      },
    );
  }
}
