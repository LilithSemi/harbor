import 'dart:async';
import 'dart:collection';

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

/// One write buffer row, sampled before a rising edge.
typedef _Row = ({bool clear, bool headLoad, int count, bool ready, int commit});

/// A bare [SdramMemoryPort] with a `clear_next` input, a write requester on
/// the waist and a client port that takes each request.
class _Bench {
  static const cfg = HarborMemoryWaistConfig(
    addressWidth: 26,
    dataWidth: 32,
    idWidth: 2,
    outstanding: 2,
  );

  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic();
  final clearNext = Logic();
  final waist = HarborMemoryWaist(cfg);
  final port = SdramPortInterface();
  late final SdramMemoryPort dut;

  final rows = <_Row>[];
  final words = <int>[];
  final flagErrors = <String>[];
  final reqs = Queue<(int, List<int>)>();
  final beats = Queue<(int, bool)>();
  var reqOn = false;
  var dataOn = false;
  var reqTaken = false;
  var dataTaken = false;
  var committed = 0;
  var lastCommit = 0;
  var headLoads = 0;
  var watching = false;
  var clearAt = -1;
  var committedAtClear = 0;
  var headLoadsAtClear = 0;

  /// Cycles with a clear and a head load, and with a clear and a full buffer.
  var clearAndLoad = 0;
  var clearAndFull = 0;
  var clearLoadFull = 0;

  static bool hi(Logic l) => l.previousValue == LogicValue.one;

  Logic sig(String n) => dut.signals.firstWhere((l) => l.name == n);

  Future<void> start() async {
    dut = SdramMemoryPort(
      clk: clk,
      reset: reset,
      abort: Const(0),
      clearNext: clearNext,
      waist: waist,
      port: port,
    );
    for (final l in [
      ...waist.getPorts([PairDirection.fromProvider]).values,
      ...port.getPorts([PairDirection.fromProvider]).values,
      clearNext,
    ]) {
      l.put(0);
    }
    reset.put(1);
    clearNext.put(1);
    waist.rdataReady.put(1);
    waist.wrespReady.put(1);
    port.reqReady.put(1);
    await dut.build();
    final clear = sig('clear');
    final head = sig('head_load');
    final wr = sig('wb_wr');
    final rd = sig('wb_rd');
    final commit = sig('wb_commit');
    final any = sig('wb_cmt_any');
    clk.posedge.listen((_) {
      final v = [
        for (final l in [clear, head, wr, rd, commit, any]) l.previousValue!,
      ];
      reqTaken = hi(waist.reqValid) && hi(waist.reqReady);
      dataTaken = hi(waist.wdataValid) && hi(waist.wdataReady);
      if (hi(port.wrValid) && hi(port.wrReady)) {
        words.add(port.wrData.previousValue!.toInt());
      }
      if (v.any((x) => !x.isValid) || hi(reset)) {
        return;
      }
      final (c, h, w, r, k, a) = (
        v[0].toInt() == 1,
        v[1].toInt() == 1,
        v[2].toInt(),
        v[3].toInt(),
        v[4].toInt(),
        v[5].toInt(),
      );
      if (a != (r != k ? 1 : 0))
        flagErrors.add(
          'wb_cmt_any $a, rd $r, '
          'commit $k',
        );
      committed += (k - lastCommit) & 15;
      lastCommit = k;
      final full = ((w - r) & 15) == 8;
      final ready = hi(waist.wdataReady);
      if (ready && full) flagErrors.add('ready while full');
      if (h) headLoads++;
      if (!watching) return;
      if (c && h) clearAndLoad++;
      if (c && full) clearAndFull++;
      if (c && h && full) clearLoadFull++;
      if (c && clearAt < 0) {
        clearAt = rows.length;
        committedAtClear = committed;
        headLoadsAtClear = headLoads;
      }
      rows.add((
        clear: c,
        headLoad: h,
        count: (w - r) & 15,
        ready: ready,
        commit: k,
      ));
    });
    Simulator.setMaxSimTime(1 << 40);
    unawaited(Simulator.run());
    for (var i = 0; i < 3; i++) {
      await clk.nextNegedge;
    }
    reset.inject(0);
    clearNext.inject(0);
    await tick();
    await tick();
    watching = true;
    addTearDown(stop);
  }

  /// Sends a write of one 4 byte beat each of [data] to [addr].
  void send(int addr, List<int> data) => reqs.add((addr, data));

  void drive() {
    if (reqTaken && reqOn) reqOn = false;
    if (dataTaken && dataOn) dataOn = false;
    if (!reqOn) {
      if (reqs.isNotEmpty) {
        final (addr, data) = reqs.removeFirst();
        waist.reqAddr.inject(addr);
        waist.reqLen.inject(data.length - 1);
        waist.reqSize.inject(2);
        waist.reqBurst.inject(1);
        waist.reqWrite.inject(1);
        waist.reqValid.inject(1);
        reqOn = true;
        for (var i = 0; i < data.length; i++) {
          beats.add((data[i], i == data.length - 1));
        }
      } else {
        waist.reqValid.inject(0);
      }
    }
    if (!dataOn) {
      if (beats.isNotEmpty) {
        final (d, last) = beats.removeFirst();
        waist.wdataData.inject(d);
        waist.wdataStrb.inject(15);
        waist.wdataLast.inject(last ? 1 : 0);
        waist.wdataValid.inject(1);
        dataOn = true;
      } else {
        waist.wdataValid.inject(0);
      }
    }
  }

  Future<void> tick() async {
    await clk.nextNegedge;
    drive();
  }

  int val(String n) {
    final v = sig(n).value;
    return v.isValid ? v.toInt() : -1;
  }

  Future<void> until(bool Function() done, [int limit = 400]) async {
    for (var i = 0; i < limit; i++) {
      if (done()) return;
      await tick();
    }
    throw StateError('condition not met in $limit cycles');
  }

  /// Raises `clear_next` now, so `clear` is high in the next cycle, and
  /// drops the requests and beats the requester has not sent.
  void raiseClear() {
    clearNext.inject(1);
    reqs.clear();
    beats.clear();
    if (reqOn) waist.reqValid.inject(0);
    if (dataOn) waist.wdataValid.inject(0);
    reqOn = false;
    dataOn = false;
  }

  void setWrReady(int v) => port.wrReady.inject(v);

  /// The words of beats [data], low word first.
  static List<int> wordsOf(List<int> data) => [
    for (final d in data) ...[d & 0xffff, d >> 16],
  ];

  Future<void> stop() async {
    await Simulator.endSimulation();
  }
}

List<int> _beats(int seed, int n) => [
  for (var i = 0; i < n; i++) (0x1000 * (seed + i) + 0x0101 * i + 0x70000) * 3,
];

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

  group('a clear with the write buffer holding committed beats', () {
    test(
      'on the head load of the first committed beat',
      () async {
        final b = _Bench();
        await b.start();
        final first = _beats(1, 4);
        final second = _beats(9, 4);
        b.send(0x0, first);
        await b.until(() => b.val('issue') == 1 && b.val('s_write') == 1);
        b.raiseClear();
        await b.tick();
        b.clearNext.inject(0);
        b.send(0x40, second);
        await b.until(
          () =>
              b.clearAt >= 0 &&
              b.rows.length > b.clearAt + 1 &&
              b.rows.last.ready,
        );
        expect(b.clearAndLoad, 1);
        expect(b.committedAtClear, 4);
        expect(b.headLoadsAtClear, 1);
        final after = b.rows.skip(b.clearAt + 1).firstWhere((r) => r.ready);
        expect(after.count, 3);
        b.setWrReady(1);
        await b.until(() => b.words.length >= 16);
        for (var i = 0; i < 20; i++) {
          await b.tick();
        }
        expect(b.words, _Bench.wordsOf([...first, ...second]));
        expect(b.flagErrors, isEmpty);
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );

    test(
      'on a later head load with the word feeder running',
      () async {
        final b = _Bench();
        await b.start();
        final data = _beats(3, 16);
        final next = _beats(21, 4);
        b.setWrReady(1);
        b.send(0x0, data);
        await b.until(
          () =>
              b.headLoads >= 2 &&
              b.val('feed') == 1 &&
              b.val('feed_word') == 0 &&
              b.val('wb_cmt_any') == 1,
        );
        b.raiseClear();
        await b.tick();
        b.clearNext.inject(0);
        b.send(0x400, next);
        await b.until(
          () =>
              b.clearAt >= 0 &&
              b.rows.length > b.clearAt + 1 &&
              b.rows.last.ready,
        );
        expect(b.clearAndLoad, 1);
        expect(b.committedAtClear, lessThan(16));
        final k = b.committedAtClear;
        final after = b.rows.skip(b.clearAt + 1).firstWhere((r) => r.ready);
        expect(after.count, lessThanOrEqualTo(k - b.headLoadsAtClear));
        await b.until(() => b.words.length >= 2 * (k + 4));
        for (var i = 0; i < 20; i++) {
          await b.tick();
        }
        expect(b.words, _Bench.wordsOf([...data.take(k), ...next]));
        expect(b.flagErrors, isEmpty);
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );
  });

  group('a clear with a full write buffer', () {
    // A first beat of 1, then two blocks of 4, fills the 8 beat buffer with
    // committed beats and one beat in the head register.
    Future<(_Bench, List<int>)> fill() async {
      final b = _Bench();
      await b.start();
      final data = _beats(5, 9);
      b.send(0x0c, data);
      await b.until(
        () =>
            b.val('wb_commit') == 9 &&
            (b.val('wb_wr') - b.val('wb_rd')) & 15 == 8,
      );
      for (var i = 0; i < 4; i++) {
        await b.tick();
      }
      return (b, data);
    }

    test(
      'with no head load the buffer stays full and holds its beats',
      () async {
        final (b, data) = await fill();
        final next = _beats(31, 4);
        b.raiseClear();
        await b.tick();
        b.clearNext.inject(0);
        b.send(0x100, next);
        for (var i = 0; i < 8; i++) {
          await b.tick();
        }
        expect(b.clearAndFull, 1);
        expect(b.clearAndLoad, 0);
        final after = b.rows.skip(b.clearAt + 1).toList();
        expect(after.every((r) => r.count == 8 && !r.ready), isTrue);
        b.setWrReady(1);
        await b.until(() => b.words.length >= 2 * 13);
        for (var i = 0; i < 20; i++) {
          await b.tick();
        }
        expect(b.words, _Bench.wordsOf([...data, ...next]));
        expect(b.flagErrors, isEmpty);
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );

    test(
      'with a head load the buffer has room after the clear',
      () async {
        final (b, data) = await fill();
        final next = _beats(41, 4);
        b.raiseClear();
        await b.tick();
        b.clearNext.inject(0);
        b.send(0x100, next);
        b.setWrReady(1);
        await b.until(() => b.words.length >= 2 * 13);
        for (var i = 0; i < 20; i++) {
          await b.tick();
        }
        expect(b.clearAndFull, 1);
        expect(b.clearLoadFull, 1);
        expect(b.committedAtClear - b.headLoadsAtClear, 7);
        final first = b.rows.skip(b.clearAt + 1).firstWhere((r) => r.ready);
        expect(first.count, 7);
        expect(b.clearAndLoad, 1);
        expect(b.words, _Bench.wordsOf([...data, ...next]));
        expect(b.flagErrors, isEmpty);
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );
  });
}
