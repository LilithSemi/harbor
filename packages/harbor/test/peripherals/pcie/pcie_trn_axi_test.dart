import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Simulator.reset);

  test('converts RX beats and holds them under backpressure', () async {
    final clock = SimpleClockGenerator(10).clk;
    final reset = Logic()..inject(1);
    final linkUp = Logic()..inject(1);
    final rxReady = Logic()..inject(0);
    final trnData = Logic(width: 128)..inject(0x1122334455667788);
    final trnRem = Logic(width: 2)..inject(1);
    final trnSof = Logic()..inject(1);
    final trnEof = Logic()..inject(0);
    final trnValid = Logic()..inject(1);
    final dut = HarborPcieTrnAxi(
      clk: clock,
      reset: reset,
      linkUp: linkUp,
      rxReady: rxReady,
      txData: Logic(width: 64)..inject(0),
      txKeep: Logic(width: 8)..inject(0),
      txLast: Logic()..inject(0),
      txValid: Logic()..inject(0),
      trnRxData: trnData,
      trnRxRem: trnRem,
      trnRxSof: trnSof,
      trnRxEof: trnEof,
      trnRxSrcReady: trnValid,
      trnRxSrcDsc: Logic()..inject(0),
      trnRxErrFwd: Logic()..inject(0),
      trnRxBarHit: Logic(width: 8)..inject(1),
      trnRxEcrcErr: Logic()..inject(0),
      trnTxDstReady: Logic(width: 4)..inject(1),
      trnTxCfgReq: Logic()..inject(0),
    );
    await dut.build();
    unawaited(Simulator.run());
    await clock.nextPosedge;
    reset.inject(0);
    await clock.nextPosedge;
    await clock.nextNegedge;
    expect(dut.rxValid.value.toBool(), isTrue);
    expect(dut.rxData.value.toInt(), 0x5566778811223344);
    expect(dut.rxKeep.value.toInt(), 0xff);
    expect(dut.rxUser.value.toInt() >> 2 & 0x7f, 1);

    trnData.inject(0xaabbccddeeff0011);
    await clock.nextPosedge;
    await clock.nextNegedge;
    expect(dut.rxData.value.toInt(), 0x5566778811223344);
    expect(dut.trnRxReady.value.toBool(), isFalse);
    await Simulator.endSimulation();
  });

  test('converts TX beats and tracks packet start', () async {
    final clock = SimpleClockGenerator(10).clk;
    final reset = Logic()..inject(1);
    final txValid = Logic()..inject(0);
    final txLast = Logic()..inject(0);
    final dut = HarborPcieTrnAxi(
      clk: clock,
      reset: reset,
      linkUp: Logic()..inject(1),
      rxReady: Logic()..inject(1),
      txData: Logic(width: 64)..inject(0x1122334455667788),
      txKeep: Logic(width: 8)..inject(0xff),
      txLast: txLast,
      txValid: txValid,
      trnRxData: Logic(width: 128)..inject(0),
      trnRxRem: Logic(width: 2)..inject(0),
      trnRxSof: Logic()..inject(0),
      trnRxEof: Logic()..inject(0),
      trnRxSrcReady: Logic()..inject(0),
      trnRxSrcDsc: Logic()..inject(0),
      trnRxErrFwd: Logic()..inject(0),
      trnRxBarHit: Logic(width: 8)..inject(0),
      trnRxEcrcErr: Logic()..inject(0),
      trnTxDstReady: Logic(width: 4)..inject(1),
      trnTxCfgReq: Logic()..inject(0),
    );
    await dut.build();
    unawaited(Simulator.run());
    await clock.nextPosedge;
    reset.inject(0);
    txValid.inject(1);
    await clock.nextPosedge;
    await clock.nextNegedge;
    expect(dut.trnTxSrcReady.value.toBool(), isTrue);
    expect(dut.trnTxSof.value.toBool(), isTrue);
    expect(dut.trnTxData.value.toInt(), 0x5566778811223344);
    expect(dut.trnTxRem.value.toInt(), 1);

    await clock.nextPosedge;
    await clock.nextNegedge;
    expect(dut.trnTxSof.value.toBool(), isFalse);
    txLast.inject(1);
    await Simulator.endSimulation();
  });
}
