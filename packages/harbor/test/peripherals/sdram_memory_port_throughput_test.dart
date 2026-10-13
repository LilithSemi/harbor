import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_memory_port_bench.dart';

void main() {
  tearDown(Simulator.reset);

  // AXI4 at 50 MHz into the 125 MHz sdram, random addresses over 1 MiB.
  for (final beats in [1, 8]) {
    test(
      'axi4 $beats-beat bursts: 8 in flight beats 1 in flight',
      () async {
        final one = await sdramThroughput(outstanding: 1, beats: beats);
        await Simulator.reset();
        final eight = await sdramThroughput(outstanding: 8, beats: beats);
        String row(String n, dynamic r) =>
            '$n in flight: read ${r.readMBs.toStringAsFixed(1)} MB/s, '
            'wait ${r.readWait.toStringAsFixed(1)} cycles; write '
            '${r.writeMBs.toStringAsFixed(1)} MB/s, wait '
            '${r.writeWait.toStringAsFixed(1)} cycles';
        print('axi4 $beats-beat bursts at 50 MHz');
        print(row('1', one));
        print(row('8', eight));
        expect(eight.readMBs, greaterThan(one.readMBs));
        expect(eight.writeMBs, greaterThan(one.writeMBs));
      },
      timeout: const Timeout(Duration(hours: 1)),
    );
  }
}
