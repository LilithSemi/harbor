import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../util/mem_target.dart';

/// Rig: a line fetcher behind a memory master waist, driving a double line
/// buffer's write port.
class _FetcherRig extends BridgeModule {
  _FetcherRig({int maxWords = 4})
    : super('LineFetchRig_w$maxWords', name: 'rig') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('fetch_start', PortDirection.input);
    createPort('fetch_addr', PortDirection.input, width: 32);
    createPort('words', PortDirection.input, width: 16);
    createPort('fill_sel', PortDirection.input);
    createPort('rd_sel', PortDirection.input);
    createPort('rd_col', PortDirection.input, width: 2);

    final mem = HarborMemoryMasterPort.create(
      module: this,
      name: 'bus',
      kind: HarborFabricKind.wishbone,
      config: const HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32),
      clk: input('clk'),
      reset: input('reset'),
    );
    final fetcher = HarborLineFetcher(
      clk: input('clk'),
      reset: input('reset'),
      fetchStart: input('fetch_start'),
      fetchAddr: input('fetch_addr'),
      words: input('words'),
      fillSel: input('fill_sel'),
      waist: mem.waist,
      maxWords: maxWords,
    );
    final buffer = HarborDoubleLineBuffer(
      wrClk: input('clk'),
      wrEn: fetcher.wrEn,
      wrSel: fetcher.wrSel,
      wrIdx: fetcher.wrIdx,
      wrData: fetcher.wrData,
      rdClk: input('clk'),
      rdReset: input('reset'),
      rdSel: input('rd_sel'),
      rdCol: input('rd_col'),
      maxWords: maxWords,
    );

    addOutput('rd_data', width: 32) <= buffer.rdData;
    addOutput('busy') <= fetcher.busy;
    addOutput('done') <= fetcher.done;
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

    const config = HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32);
    final top = MasterTop(
      _FetcherRig(maxWords: 4),
      iface: 'bus',
      kind: HarborFabricKind.wishbone,
      config: config,
    );
    top.input('clk').srcConnection! <= clk;
    top.input('reset').srcConnection! <= reset;
    top.input('fetch_start').srcConnection! <= fetchStart;
    top.input('fetch_addr').srcConnection! <= fetchAddr;
    top.input('words').srcConnection! <= words;
    top.input('fill_sel').srcConnection! <= fillSel;
    top.input('rd_sel').srcConnection! <= rdSel;
    top.input('rd_col').srcConnection! <= rdCol;
    // Fake memory: 0-latency ack, data = address (fill(i) = word i's byte
    // address, since words are 4 bytes here).
    final mem = BeatMemory(top, clk, fill: (i) => i * 4);
    await top.build();
    mem.start();

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
      while (top.output('busy').value.toInt() == 1 && guard < 50) {
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
      expect(
        top.output('rd_data').value.toInt(),
        equals(0x40 + c * 4),
        reason: 'buf0[$c]',
      );
    }

    await fetch(0x80, 1);
    rdSel.inject(1);
    for (var c = 0; c < 4; c++) {
      rdCol.inject(c);
      await clk.nextNegedge;
      expect(
        top.output('rd_data').value.toInt(),
        equals(0x80 + c * 4),
        reason: 'buf1[$c]',
      );
    }

    await Simulator.endSimulation();
    Simulator.reset();
  });
}
