import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../bus/port/memory_harness.dart';
import '../util/mem_target.dart';

/// [HarborLineFetcher] behind a memory master waist of [kind], named `bus`.
class _FetcherRig extends BridgeModule {
  final int maxWords;
  final int burstWords;

  _FetcherRig({
    required HarborFabricKind kind,
    required int outstanding,
    this.maxWords = 2048,
    this.burstWords = 16,
  }) : super(
         harborStableDefinitionName('LineFetchKindsRig', [
           kind.name,
           'o$outstanding',
           'w$maxWords',
           'b$burstWords',
         ]),
         name: 'rig',
       ) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('fetch_start', PortDirection.input);
    createPort('fetch_addr', PortDirection.input, width: 32);
    createPort('words', PortDirection.input, width: 16);
    createPort('fill_sel', PortDirection.input);

    final idxW = (maxWords - 1).bitLength < 1 ? 1 : (maxWords - 1).bitLength;
    final mem = HarborMemoryMasterPort.create(
      module: this,
      name: 'bus',
      kind: kind,
      config: HarborMemoryWaistConfig(
        addressWidth: 32,
        dataWidth: 32,
        outstanding: outstanding,
      ),
      clk: input('clk'),
      reset: input('reset'),
    );
    final f = HarborLineFetcher(
      clk: input('clk'),
      reset: input('reset'),
      fetchStart: input('fetch_start'),
      fetchAddr: input('fetch_addr'),
      words: input('words'),
      fillSel: input('fill_sel'),
      waist: mem.waist,
      maxWords: maxWords,
      burstWords: burstWords,
    );
    addOutput('wr_en') <= f.wrEn;
    addOutput('wr_sel') <= f.wrSel;
    addOutput('wr_idx', width: idxW) <= f.wrIdx;
    addOutput('wr_data', width: 32) <= f.wrData;
    addOutput('busy') <= f.busy;
    addOutput('done') <= f.done;
  }
}

/// Finds the [HarborLineFetcher] under [top] and watches its request port
/// (`m_REQ_*`) for every fired request, in order, as (addr, beats).
class _ReqWatcher {
  final List<(int, int)> fired = [];

  _ReqWatcher(Module top, Logic clk) {
    Iterable<Module> all(Module m) sync* {
      yield m;
      for (final s in m.subModules) {
        yield* all(s);
      }
    }

    final f = all(top).whereType<HarborLineFetcher>().single;
    clk.posedge.listen((_) {
      final valid = f.output('m_REQ_VALID').previousValue!;
      final ready = f.input('m_REQ_READY').previousValue!;
      if (valid.isValid && valid.toBool() && ready.isValid && ready.toBool()) {
        fired.add((
          f.output('m_REQ_ADDR').previousValue!.toInt(),
          f.output('m_REQ_LEN').previousValue!.toInt() + 1,
        ));
      }
    });
  }
}

/// [HarborLineFetcher] with its waist on `m_*`, so the test is the memory.
class _BareRig extends BridgeModule {
  _BareRig() : super('LineFetchBareRig', name: 'rig') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final w = HarborMemoryWaist(
      const HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32),
    );
    exposeWaist(this, w, 'm', PairRole.provider);
    final f = HarborLineFetcher(
      clk: input('clk'),
      reset: input('reset'),
      fetchStart: Const(0),
      fetchAddr: Const(0, width: 32),
      words: Const(0, width: 16),
      fillSel: Const(0),
      waist: w,
    );
    addOutput('wr_en') <= f.wrEn;
  }
}

void main() {
  tearDown(() async => Simulator.reset());

  test('read data with no line in flight is not written', () async {
    final top = _BareRig();
    final clk = SimpleClockGenerator(10).clk;
    for (final input in top.inputs.values) {
      if (input.name != 'clk') input.srcConnection!.put(0);
    }
    top.input('clk').srcConnection! <= clk;
    await top.build();
    var written = false;
    var falls = 0;
    clk.negedge.listen((_) {
      falls++;
      top.input('reset').srcConnection!.inject(falls < 4 ? 1 : 0);
      top.input('m_RDATA_VALID').srcConnection!.inject(falls > 6 ? 1 : 0);
      if (falls > 6 && top.output('wr_en').value.toBool()) written = true;
    });
    Simulator.setMaxSimTime(300);
    await Simulator.run();
    expect(written, isFalse);
  });

  for (final kind in HarborFabricKind.values) {
    final outstanding = kind == HarborFabricKind.wishbone ? 1 : 4;
    for (final latency in [0, 2]) {
      test(
        '${kind.name} latency $latency: a line crossing a 4 KB boundary '
        'with a length not a multiple of burstWords, then a second line',
        () async {
          const config = HarborMemoryWaistConfig(
            addressWidth: 32,
            dataWidth: 32,
          );
          final top = MasterTop(
            _FetcherRig(kind: kind, outstanding: outstanding),
            iface: 'bus',
            kind: kind,
            config: config,
          );
          final clk = SimpleClockGenerator(10).clk;
          final reset = Logic(name: 'reset');
          final fetchStart = Logic(name: 'fetch_start');
          final fetchAddr = Logic(name: 'fetch_addr', width: 32);
          final words = Logic(name: 'words', width: 16);
          final fillSel = Logic(name: 'fill_sel');
          top.input('clk').srcConnection! <= clk;
          top.input('reset').srcConnection! <= reset;
          top.input('fetch_start').srcConnection! <= fetchStart;
          top.input('fetch_addr').srcConnection! <= fetchAddr;
          top.input('words').srcConnection! <= words;
          top.input('fill_sel').srcConnection! <= fillSel;
          final mem = BeatMemory(top, clk, latency: latency, fill: (i) => i);
          await top.build();
          final watcher = _ReqWatcher(top, clk);
          mem.start();

          reset.inject(1);
          fetchStart.inject(0);
          fetchAddr.inject(0);
          words.inject(0);
          fillSel.inject(0);
          Simulator.setMaxSimTime(4000000);
          unawaited(Simulator.run());
          for (var i = 0; i < 4; i++) {
            await clk.nextPosedge;
          }
          reset.inject(0);
          await clk.nextNegedge;

          final written = <int, int>{};
          void watchWrites() {
            if (top.output('wr_en').value == LogicValue.one) {
              written[top.output('wr_idx').value.toInt()] = top
                  .output('wr_data')
                  .value
                  .toInt();
            }
          }

          Future<void> fetch(int addr, int n) async {
            written.clear();
            watcher.fired.clear();
            fetchAddr.inject(addr);
            words.inject(n);
            fillSel.inject(0);
            fetchStart.inject(1);
            await clk.nextPosedge;
            fetchStart.inject(0);
            var guard = 0;
            while (top.output('done').value != LogicValue.one &&
                guard < 20000) {
              await clk.nextPosedge;
              watchWrites();
              guard++;
            }
            if (guard >= 20000)
              fail('line at 0x${addr.toRadixString(16)} never finished');
            await clk.nextNegedge;

            // Every write landed with the right index and data.
            expect(
              written.length,
              equals(n),
              reason: '0x${addr.toRadixString(16)}',
            );
            for (var i = 0; i < n; i++) {
              expect(
                written[i],
                equals(mem.readWord(addr + i * 4)),
                reason: '0x${addr.toRadixString(16)} word $i',
              );
            }

            // No request crossed a 4 KB boundary, and the requests cover
            // the line with no gap or overlap.
            var next = addr;
            var total = 0;
            for (final (a, beats) in watcher.fired) {
              expect(a, equals(next), reason: 'requests run in order');
              final end = a + beats * 4;
              expect(
                a ~/ 4096,
                equals((end - 1) ~/ 4096),
                reason:
                    'request at 0x${a.toRadixString(16)} of $beats '
                    'beats crosses a 4 KB boundary',
              );
              next = end;
              total += beats;
            }
            expect(total, equals(n));
          }

          // Crosses a 4 KB boundary (starts 32 bytes before it) with a
          // length that is not a multiple of burstWords (16).
          await fetch(0x0FE0, 37);
          // A second line, right behind the first.
          await fetch(0x4000, 20);

          await Simulator.endSimulation();
        },
      );
    }
  }
}
