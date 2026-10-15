import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_memory_port_bench.dart';

/// Synchronizers on the bus clock. The rule covers only the memory clock.
const _busSide = {
  's_join_reset',
  's_join_sync',
  'fabric_join_reset',
  'fabric_join_sync',
};

Iterable<Module> _tree(Module m) sync* {
  yield m;
  for (final s in m.subModules) {
    yield* _tree(s);
  }
}

/// Each reset synchronizer output under [root], found by the names of its
/// chain: `<n>_sync_1` for a join reset, `<n>_0` for a release or edge
/// synchronizer `<n>` that ends in `_sync`.
List<Logic> _syncOutputs(Module root) => [
  for (final m in _tree(root))
    if (m is! Ecp5Fd1s3bx)
      for (final names in [
        {for (final s in m.signals) s.name},
      ])
        for (final s in m.signals)
          if (!_busSide.contains(s.name) &&
              !s.isPort &&
              (names.contains('${s.name}_sync_1') ||
                  (s.name.endsWith('_sync') && names.contains('${s.name}_0'))))
            s,
];

/// The loads of [net] that are not the D input of an [Ecp5Fd1s3bx]. It
/// follows wires and output ports to their loads.
List<String> _badLoads(Logic net, [String? path]) {
  final at = path ?? '${net.parentModule?.name}.${net.name}';
  return [
    for (final d in net.dstConnections)
      if (d.parentModule is Ecp5Fd1s3bx && d.name == 'D')
        ...const <String>[]
      else if (d.isOutput || (!d.isPort && d.parentModule == net.parentModule))
        ..._badLoads(d, at)
      else
        '$at drives ${d.parentModule?.name}.${d.name}',
  ];
}

Logic _signal(Module m, String name) =>
    m.signals.firstWhere((s) => s.name == name);

Logic _copy(Module m, String name) =>
    m.subModules.whereType<Ecp5Fd1s3bx>().firstWhere((c) => c.name == name).q;

void main() {
  tearDown(Simulator.reset);

  const config = HarborMemoryWaistConfig(
    addressWidth: 26,
    dataWidth: 32,
    idWidth: 2,
    outstanding: 2,
  );

  for (final kind in HarborFabricKind.values) {
    test('${kind.name}: the reset synchronizer outputs on the memory clock '
        'drive only copy flops', () async {
      final wishbone = kind == HarborFabricKind.wishbone;
      final top = SdramPortTop(
        kind,
        HarborMemoryWaistConfig(
          addressWidth: config.addressWidth,
          dataWidth: config.dataWidth,
          idWidth: config.idWidth,
          outstanding: wishbone ? 1 : config.outstanding,
        ),
        memHz: 100000000,
      );
      await top.build();
      final syncs = _syncOutputs(top.sdram);
      expect(
        syncs.map((s) => s.name).toSet(),
        containsAll([
          'mem_reset_sync',
          'sdram_cold_reset',
          wishbone ? 'm_join_reset' : 'device_join_reset',
        ]),
      );
      expect([for (final s in syncs) ..._badLoads(s)], isEmpty);
    });
  }

  test('wishbone bus clock sync: the reset synchronizer outputs drive only '
      'copy flops', () async {
    final sdram = HarborSdram(
      config: sdramBenchConfig(),
      baseAddress: 0,
      clockHz: 100000000,
      busClockSync: true,
      target: const HarborFpgaTarget.ecp5(
        device: 'LFE5U-85F',
        package: 'CABGA381',
      ),
    );
    await sdram.build();
    final syncs = _syncOutputs(sdram);
    expect(syncs.map((s) => s.name), contains('mem_reset_sync'));
    expect([for (final s in syncs) ..._badLoads(s)], isEmpty);
  });

  for (final kind in [HarborFabricKind.axi4, HarborFabricKind.tilelink]) {
    test('${kind.name}: clear_next is the next clear across a mem_reset and a '
        'bus reset', () async {
      final top = SdramPortTop(kind, config, memHz: 100000000);
      final fabricClk = SimpleClockGenerator(20000).clk;
      final memClk = SimpleClockGenerator(10000).clk;
      for (final input in top.inputs.values) {
        if (!{'clk', 'mem_clk'}.contains(input.name)) {
          input.srcConnection!.put(input.name.endsWith('reset') ? 1 : 0);
        }
      }
      top.input('clk').srcConnection! <= fabricClk;
      top.input('mem_clk').srcConnection! <= memClk;
      await top.build();

      final sdram = top.sdram;
      final port = sdram.subModules.whereType<SdramMemoryPort>().single;
      final clearNext = port.input('clear_next');
      final clear = _signal(port, 'clear');
      final portReset = port.input('reset');
      final abort = sdram.subModules.whereType<SdramPortSlice>().single.input(
        'abort',
      );
      final pairs = [
        (_copy(sdram, 'port_reset'), _copy(sdram, 'front_local_reset')),
        (_copy(sdram, 'port_abort'), _copy(sdram, 'front_reset_0')),
      ];
      final early = _copy(sdram, 'port_early_reset');

      final rows = <List<int>>[];
      var sampling = false;
      memClk.negedge.listen((_) {
        if (!sampling) return;
        rows.add([
          for (final l in [clearNext, clear, portReset, abort, early])
            l.value.toInt(),
          for (final (a, b) in pairs) a.value == b.value ? 1 : 0,
        ]);
      });

      Simulator.setMaxSimTime(1 << 40);
      final run = Simulator.run();
      Future<void> memCycles(int n) async {
        for (var i = 0; i < n; i++) {
          await memClk.nextNegedge;
        }
      }

      Future<void> fabricCycles(int n) async {
        for (var i = 0; i < n; i++) {
          await fabricClk.nextNegedge;
        }
      }

      await memCycles(8);
      sampling = true;
      top.input('mem_reset').srcConnection!.inject(0);
      await fabricCycles(1);
      top.input('reset').srcConnection!.inject(0);
      await memCycles(40);
      // An edge of mem_reset away from the mem_clk edges.
      await fabricClk.nextPosedge;
      top.input('mem_reset').srcConnection!.inject(1);
      await memCycles(3);
      top.input('mem_reset').srcConnection!.inject(0);
      await memCycles(40);
      top.input('reset').srcConnection!.inject(1);
      await fabricCycles(3);
      top.input('reset').srcConnection!.inject(0);
      await memCycles(40);
      sampling = false;
      await Simulator.endSimulation();
      await run;

      final bad = <String>[];
      var risesAfterRelease = 0;
      for (var i = 0; i < rows.length; i++) {
        final [cn, c, r, a, e, sameReset, sameAbort] = rows[i];
        if (c != (r | a)) bad.add('cycle $i: clear $c, reset $r, abort $a');
        if (sameReset != 1) bad.add('cycle $i: port_reset differs');
        if (sameAbort != 1) bad.add('cycle $i: port_abort differs');
        if (i + 1 < rows.length) {
          final next = rows[i + 1];
          if (next[1] != cn)
            bad.add('cycle $i: clear_next $cn, next ${next[1]}');
          if (next[2] != e) bad.add('cycle $i: port_early $e, next ${next[2]}');
          if (i > 0 && rows[i - 1][1] == 0 && c == 1) risesAfterRelease++;
        }
      }
      expect(bad.take(8), isEmpty);
      // The mem_reset pulse and the bus reset each set clear again.
      expect(risesAfterRelease, 2);
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}
