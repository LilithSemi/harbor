// Ddr3MemoryPort stops the simulation on a WRAP request of a length that is
// not 2, 4, 8 or 16 beats.
import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

Future<void> _wrap(int len) async {
  final cfg = HarborMemoryWaistConfig(
    addressWidth: 32,
    dataWidth: 64,
    idWidth: 1,
    outstanding: 2,
  );
  final w = HarborMemoryWaist(cfg);
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset')..put(1);
  final dut = Ddr3MemoryPort(
    clk: clk,
    reset: reset,
    clear: reset,
    waists: [w],
    ctrlAddrWidth: 24,
    ctrlDataWidth: 128,
    ctrlStall: Logic()..put(0),
    ctrlAck: Logic()..put(0),
    ctrlAckAux: Logic(width: 4)..put(0),
    ctrlData: Logic(width: 128)..put(0),
    ctrlAckPipeDepth: 6,
  );
  await dut.build();
  for (final name in [
    'REQ_VALID',
    'REQ_ID',
    'REQ_WRITE',
    'REQ_ADDR',
    'REQ_LEN',
    'REQ_SIZE',
    'REQ_BURST',
    'REQ_EXCLUSIVE',
    'WDATA_VALID',
    'WDATA_DATA',
    'WDATA_STRB',
    'WDATA_LAST',
    'RDATA_READY',
    'WRESP_READY',
  ]) {
    w.port(name).put(0);
  }
  Simulator.setMaxSimTime(2000);
  final done = Simulator.run();
  await clk.nextNegedge;
  await clk.nextNegedge;
  reset.put(0);
  await clk.nextNegedge;
  w.reqValid.put(1);
  w.reqWrite.put(0);
  w.reqLen.put(len);
  w.reqSize.put(3);
  w.reqBurst.put(HarborMemoryBurst.wrap.value);
  await done;
}

void main() {
  tearDown(Simulator.reset);

  for (final len in [2, 5]) {
    test('a WRAP request of len $len stops the simulation', () async {
      await expectLater(
        _wrap(len),
        throwsA(
          predicate((e) => e.toString().contains('WRAP burst of a length')),
        ),
      );
    });
  }

  test('a WRAP request of len 3 runs on', () async {
    await _wrap(3);
  });
}
