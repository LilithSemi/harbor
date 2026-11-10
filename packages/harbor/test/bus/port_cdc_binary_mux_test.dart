import 'dart:async';

import 'package:harbor/src/bus/port/port_cdc.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'trusted CDC reads select the next binary pointer across wrap',
    () async {
      final fifo = HarborWaistCdcFifo(
        wrClk: Logic(name: 'wr_clk'),
        wrReset: Logic(name: 'wr_reset'),
        wrEn: Logic(name: 'wr_en'),
        wrData: Logic(name: 'wr_data', width: 8),
        rdClk: Logic(name: 'rd_clk'),
        rdReset: Logic(name: 'rd_reset'),
        rdEn: Logic(name: 'rd_en'),
        depth: 4,
        trustRead: true,
        trustWrite: true,
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final wrEn = Logic(name: 'wr_en_in');
      final wrData = Logic(name: 'wr_data_in', width: 8);
      final rdEn = Logic(name: 'rd_en_in');
      fifo.input('wr_clk').srcConnection! <= clk;
      fifo.input('rd_clk').srcConnection! <= clk;
      fifo.input('wr_reset').srcConnection! <= reset;
      fifo.input('rd_reset').srcConnection! <= reset;
      fifo.input('wr_en').srcConnection! <= wrEn;
      fifo.input('wr_data').srcConnection! <= wrData;
      fifo.input('rd_en').srcConnection! <= rdEn;
      await fifo.build();

      Simulator.setMaxSimTime(100000);
      unawaited(Simulator.run());
      reset.inject(1);
      wrEn.inject(0);
      rdEn.inject(0);
      wrData.inject(0);
      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
      }
      reset.inject(0);

      // Fill all four entries so the read pointer wraps after the final pop.
      const values = [0x13, 0x57, 0x9b, 0xdf];
      for (final value in values) {
        await clk.nextNegedge;
        wrData.inject(value);
        wrEn.inject(1);
        await clk.nextPosedge;
        wrEn.inject(0);
      }

      // Wait for the write pointer to cross into the read domain.
      for (var i = 0; i < 3; i++) {
        await clk.nextPosedge;
      }
      expect(fifo.output('rd_empty').value.toInt(), 0);
      expect(fifo.output('rd_data').value.toInt(), values.first);

      for (var i = 0; i < values.length; i++) {
        await clk.nextNegedge;
        rdEn.inject(1);
        await clk.nextPosedge;
        rdEn.inject(0);
        if (i + 1 < values.length) {
          expect(fifo.output('rd_data').value.toInt(), values[i + 1]);
        }
      }
      expect(fifo.output('rd_empty').value.toInt(), 1);
      await Simulator.endSimulation();
    },
  );
}
