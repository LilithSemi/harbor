import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Harness: a line fetcher driving a double line buffer's write port, with a
/// fake memory on the fetcher's master port (0-latency ack, data = address).
class _Harness extends Module {
  Logic get rdData => output('rd_data');
  Logic get busy => output('busy');
  Logic get done => output('done');

  _Harness(
    Logic clk,
    Logic reset,
    Logic fetchStart,
    Logic fetchAddr,
    Logic words,
    Logic fillSel,
    Logic rdSel,
    Logic rdCol,
  ) : super(definitionName: 'LineFetchHarness') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    fetchStart = addInput('fetch_start', fetchStart);
    fetchAddr = addInput('fetch_addr', fetchAddr, width: 32);
    words = addInput('words', words, width: 16);
    fillSel = addInput('fill_sel', fillSel);
    rdSel = addInput('rd_sel', rdSel);
    rdCol = addInput('rd_col', rdCol, width: rdCol.width);
    addOutput('rd_data', width: 32);
    addOutput('busy');
    addOutput('done');

    final mDataIn = Logic(name: 'm_dat_i', width: 32);
    final mAck = Logic(name: 'm_ack');

    final fetcher = HarborLineFetcher(
      clk: clk,
      reset: reset,
      fetchStart: fetchStart,
      fetchAddr: fetchAddr,
      words: words,
      fillSel: fillSel,
      mDataIn: mDataIn,
      mAck: mAck,
      maxWords: 4,
    );
    final buffer = HarborDoubleLineBuffer(
      wrClk: clk,
      wrEn: fetcher.wrEn,
      wrSel: fetcher.wrSel,
      wrIdx: fetcher.wrIdx,
      wrData: fetcher.wrData,
      rdClk: clk,
      rdReset: reset,
      rdSel: rdSel,
      rdCol: rdCol,
      maxWords: 4,
    );

    mAck <= fetcher.mStb;
    mDataIn <= fetcher.mAddr;

    output('rd_data') <= buffer.rdData;
    output('busy') <= fetcher.busy;
    output('done') <= fetcher.done;
  }
}

void main() {
  test('bursts a line into the selected buffer', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final fetchStart = Logic(name: 'fetch_start');
    final fetchAddr = Logic(name: 'fetch_addr', width: 32);
    final words = Logic(name: 'words', width: 16);
    final fillSel = Logic(name: 'fill_sel');
    final rdSel = Logic(name: 'rd_sel');
    final rdCol = Logic(name: 'rd_col', width: 2);

    final h = _Harness(
      clk,
      reset,
      fetchStart,
      fetchAddr,
      words,
      fillSel,
      rdSel,
      rdCol,
    );
    await h.build();

    reset.inject(1);
    fetchStart.inject(0);
    fetchAddr.inject(0);
    words.inject(0);
    fillSel.inject(0);
    rdSel.inject(0);
    rdCol.inject(0);
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextNegedge;

    Future<void> fetch(int addr, int sel) async {
      fetchAddr.inject(addr);
      words.inject(4);
      fillSel.inject(sel);
      fetchStart.inject(1);
      await clk.nextPosedge;
      fetchStart.inject(0);
      var guard = 0;
      while (h.busy.value.toInt() == 1 && guard < 50) {
        await clk.nextPosedge;
        guard++;
      }
      await clk.nextNegedge;
    }

    await fetch(0x40, 0);
    rdSel.inject(0);
    for (var c = 0; c < 4; c++) {
      rdCol.inject(c);
      await clk.nextNegedge;
      expect(h.rdData.value.toInt(), equals(0x40 + c * 4), reason: 'buf0[$c]');
    }

    await fetch(0x80, 1);
    rdSel.inject(1);
    for (var c = 0; c < 4; c++) {
      rdCol.inject(c);
      await clk.nextNegedge;
      expect(h.rdData.value.toInt(), equals(0x80 + c * 4), reason: 'buf1[$c]');
    }

    await Simulator.endSimulation();
    Simulator.reset();
  });
}
