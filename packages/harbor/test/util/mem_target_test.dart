import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../bus/port/memory_harness.dart';
import 'mem_target.dart';

void main() {
  tearDown(() async => Simulator.reset());

  for (final kind in HarborFabricKind.values) {
    test(
      'MasterTop runs a write burst and a read burst (${kind.name})',
      () async {
        const cfg = HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32);
        final top = MasterTop(
          MemMasterShell(cfg, kind: kind),
          iface: 'bus',
          kind: kind,
          config: cfg,
        );
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        top.input('clk').srcConnection! <= clk;
        top.input('reset').srcConnection! <= reset;
        final drv = <String, Logic>{};
        for (final p in top.inputs.keys.where((p) => p.startsWith('mem_'))) {
          final l = Logic(name: 'drv_$p', width: top.input(p).width);
          top.input(p).srcConnection! <= l;
          drv[p] = l;
        }
        final mem = BeatMemory(top, clk, latency: 1, fill: (i) => 0x1000 + i);
        await top.build();
        for (final l in drv.values) {
          l.inject(0);
        }
        drv['mem_RDATA_READY']!.inject(1);
        drv['mem_WRESP_READY']!.inject(1);
        reset.inject(1);
        mem.start();
        Simulator.setMaxSimTime(200000);
        unawaited(Simulator.run());
        for (var i = 0; i < 4; i++) {
          await clk.nextPosedge;
        }
        reset.inject(0);

        Future<void> req(bool write, int addr, int len) async {
          await clk.nextNegedge;
          drv['mem_REQ_VALID']!.inject(1);
          drv['mem_REQ_WRITE']!.inject(write ? 1 : 0);
          drv['mem_REQ_ADDR']!.inject(addr);
          drv['mem_REQ_LEN']!.inject(len);
          drv['mem_REQ_SIZE']!.inject(2);
          drv['mem_REQ_BURST']!.inject(1);
          while (true) {
            await clk.nextPosedge;
            if (top.output('mem_REQ_READY').previousValue!.toBool()) break;
          }
          await clk.nextNegedge;
          drv['mem_REQ_VALID']!.inject(0);
        }

        await req(true, 0x100, 3);
        for (var b = 0; b < 4; b++) {
          drv['mem_WDATA_VALID']!.inject(1);
          drv['mem_WDATA_DATA']!.inject(0xa0 + b);
          drv['mem_WDATA_STRB']!.inject(0xf);
          drv['mem_WDATA_LAST']!.inject(b == 3 ? 1 : 0);
          while (true) {
            await clk.nextPosedge;
            if (top.output('mem_WDATA_READY').previousValue!.toBool()) break;
          }
          await clk.nextNegedge;
        }
        drv['mem_WDATA_VALID']!.inject(0);
        while (!top.output('mem_WRESP_VALID').value.toBool()) {
          await clk.nextNegedge;
        }
        for (var b = 0; b < 4; b++) {
          expect(mem.readWord(0x100 + 4 * b), 0xa0 + b);
        }

        await req(false, 0x200, 1);
        final got = <int>[];
        while (got.length < 2) {
          await clk.nextPosedge;
          if (top.output('mem_RDATA_VALID').previousValue!.toBool()) {
            got.add(top.output('mem_RDATA_DATA').previousValue!.toInt());
          }
        }
        expect(got, [0x1000 + 0x80, 0x1000 + 0x81]);
        await Simulator.endSimulation();
      },
    );
  }
}
