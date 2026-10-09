import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Tests the double line buffer: a system-clock write port fills one of two
/// buffers word-by-word. A registered read port serves any buffer by column
/// one read-clock cycle later. Because scanout double-buffers, the
/// buffer being read is never the one being written, so the read can cross
/// into the pixel domain safely. Here the read clock differs from the write
/// clock to exercise that crossing. Both the flop and the block RAM storage
/// are checked.
void main() {
  for (final blockRam in [null, HarborBlockRam.dp16kd]) {
    test('writes one buffer and reads it back across clocks '
        '(${blockRam?.name ?? 'flops'})', () async {
      final wrClk = SimpleClockGenerator(10).clk;
      final rdClk = SimpleClockGenerator(14).clk; // different domain

      final wrEn = Logic(name: 'wr_en');
      final wrSel = Logic(name: 'wr_sel');
      final wrIdx = Logic(name: 'wr_idx', width: 2);
      final wrData = Logic(name: 'wr_data', width: 32);
      final rdSel = Logic(name: 'rd_sel');
      final rdCol = Logic(name: 'rd_col', width: 2);
      final rdReset = Logic(name: 'rd_reset');

      final lb = HarborDoubleLineBuffer(
        wrClk: wrClk,
        wrEn: wrEn,
        wrSel: wrSel,
        wrIdx: wrIdx,
        wrData: wrData,
        rdClk: rdClk,
        rdReset: rdReset,
        rdSel: rdSel,
        rdCol: rdCol,
        maxWords: 4,
        blockRam: blockRam,
      );
      await lb.build();

      wrEn.inject(0);
      wrSel.inject(0);
      wrIdx.inject(0);
      wrData.inject(0);
      rdSel.inject(0);
      rdCol.inject(0);
      rdReset.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await rdClk.nextPosedge;

      // Fill buffer 0 with 0xA0, 0xA1, 0xA2, 0xA3 on the write clock.
      for (var i = 0; i < 4; i++) {
        wrSel.inject(0);
        wrIdx.inject(i);
        wrData.inject(0xA0 + i);
        wrEn.inject(1);
        await wrClk.nextPosedge;
      }
      wrEn.inject(0);
      // Fill buffer 1 with different data to prove the buffers are independent.
      for (var i = 0; i < 4; i++) {
        wrSel.inject(1);
        wrIdx.inject(i);
        wrData.inject(0xB0 + i);
        wrEn.inject(1);
        await wrClk.nextPosedge;
      }
      wrEn.inject(0);
      await wrClk.nextNegedge;

      // Read from the read-clock domain. Just before each read edge, rdData
      // must still hold the previous word, so a combinational read fails.
      await rdClk.nextNegedge;
      var previous = 0xA0;
      Future<void> read(int sel, int col, int want) async {
        rdSel.inject(sel);
        rdCol.inject(col);
        LogicValue? beforeEdge;
        Simulator.registerAction(Simulator.time + 6, () {
          beforeEdge = lb.rdData.value;
        });
        await rdClk.nextPosedge;
        await rdClk.nextNegedge;
        expect(beforeEdge?.toInt(), equals(previous), reason: 'before $want');
        expect(lb.rdData.value.toInt(), equals(want), reason: 'after edge');
        previous = want;
      }

      for (var i = 0; i < 4; i++) {
        await read(0, i, 0xA0 + i);
      }
      for (var i = 0; i < 4; i++) {
        await read(1, i, 0xB0 + i);
      }

      // The read register clears on the read edge while rdReset is high, and
      // not before it.
      rdReset.inject(1);
      expect(lb.rdData.value.toInt(), equals(0xB3));
      await rdClk.nextPosedge;
      await rdClk.nextNegedge;
      expect(lb.rdData.value.toInt(), equals(0), reason: 'cleared by reset');
      await rdClk.nextPosedge;
      await rdClk.nextNegedge;
      expect(lb.rdData.value.toInt(), equals(0), reason: 'held in reset');
      rdReset.inject(0);
      previous = 0;
      await read(0, 2, 0xA2);

      await Simulator.endSimulation();
      Simulator.reset();
    });
  }
}
