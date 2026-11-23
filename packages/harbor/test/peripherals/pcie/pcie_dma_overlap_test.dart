// Host to device copies with more than one local write burst owed.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/pcie_dma_bench.dart';
import '../../util/pcie_host_model.dart';

const _host = 0x80000000;
const _local = 0x20000;

Logic _port(DmaBench b, String suffix) {
  final ports = {...b.dut.inputs, ...b.dut.outputs};
  return ports.entries
      .firstWhere((e) => e.key.startsWith('memory_') && e.key.endsWith(suffix))
      .value;
}

bool _high(Logic l) => l.value.isValid && l.value.toBool();

/// Logs each AXI write request address and each write response as
/// (cycle, id, error).
class _AxiLog {
  final List<(int, int)> requests = [];
  final List<(int, int, bool)> responses = [];
  var _cycle = 0;

  _AxiLog(DmaBench b) {
    final awValid = _port(b, 'AWVALID');
    final awReady = _port(b, 'AWREADY');
    final awAddr = _port(b, 'AWADDR');
    final bValid = _port(b, 'BVALID');
    final bReady = _port(b, 'BREADY');
    final bId = _port(b, 'BID');
    final bResp = _port(b, 'BRESP');
    // Mid cycle, the handshake signals are stable.
    b.clk.negedge.listen((_) {
      _cycle++;
      if (_high(awValid) && _high(awReady)) {
        requests.add((_cycle, awAddr.value.toInt()));
      }
      if (_high(bValid) && _high(bReady)) {
        responses.add((_cycle, bId.value.toInt(), bResp.value.toInt() != 0));
      }
    });
  }
}

/// Answers the read [t] with UR after the reads before it are answered.
void _lateUr(DmaBench b, PcieTlp t) => unawaited(
  b
      .cycles(600)
      .then(
        (_) => b.injected.add(
          PcieTlp.completion(
            completerId: 0x55,
            requesterId: t.requesterId,
            tag: t.tag,
            status: PcieCplStatus.unsupported,
            byteCount: t.lengthDw * 4,
            lowerAddress: t.address & 0x7f,
            data: const [],
          ),
        ),
      ),
);

int _sig(DmaBench b, String name) =>
    b.dut.signals.firstWhere((s) => s.name == name).value.toInt();

Future<DmaBench> _bench(DmaConfig config, {int seed = 1}) async {
  final b = await DmaBench.create(config, seed: seed);
  await b.start();
  await b.setupRing(dmaCplBase, 4);
  await b.enable();
  return b;
}

Future<void> _h2d(DmaBench b, int length, int cookie, {int offset = 0}) {
  b.seedHost(_host + offset, length);
  return b.push(
    hostAddress: _host + offset,
    localAddress: _local + offset,
    length: length,
    deviceToHost: false,
    cookie: cookie,
  );
}

/// Waits until ENGINE_RESET in CONTROL clears.
Future<void> _waitResetTaken(DmaBench b) async {
  for (var i = 0; i < 100; i++) {
    if (await b.readReg(HarborPcieDma.registerControl) == 1) return;
  }
  fail('engine reset not taken');
}

void main() {
  tearDown(() async => Simulator.reset());

  test('write responses out of order give the right record', () async {
    final b = await _bench(
      const DmaConfig(memoryOutstanding: 8, bReorder: true),
    );
    final log = _AxiLog(b);
    await _h2d(b, 0x2000, 0x31);
    await b.waitRecordWrites(0, 1);
    final r = b.record(0);
    expect(r.cookie, 0x31);
    expect(r.code, 0);
    expect(r.bytes, 0x2000);
    b.checkLocal(_host, _local, 0x2000);
    // The responses came in another order than the IDs were given.
    final ids = [for (final (_, id, _) in log.responses) id];
    expect(ids, hasLength(log.requests.length));
    expect([
      for (var i = 0; i < ids.length; i++) i % 8,
    ], isNot(orderedEquals(ids)));
    expect(b.host.violations, isEmpty);
    await b.finish();
  });

  test('a write error out of order counts only the tags before it', () async {
    final b = await _bench(
      const DmaConfig(memoryOutstanding: 8, bReorder: true),
    );
    final log = _AxiLog(b);
    // Tags are 512 bytes. The error is in the burst of tag 3. The held
    // responses leave newest first.
    b.memory.errorBeats.add(_local + 0x650);
    b.hold('b');
    await _h2d(b, 0x2000, 0x32);
    await b.waitUntil(() => log.requests.length >= 6, what: '6 bursts');
    // The data of the last bursts goes out, so their responses are kept.
    await b.cycles(500);
    b.hold('b', held: false);
    await b.waitRecordWrites(0, 1);
    final r = b.record(0);
    expect(r.code, HarborPcieDma.errorFabric);
    expect(r.bytes, 0x600);
    b.checkLocal(_host, _local, 0x600);
    // A good response of a later burst came before the error. One copy
    // gives the IDs in turn from 0.
    final queues = List.generate(8, (_) => <int>[]);
    for (var i = 0; i < log.requests.length; i++) {
      queues[i % 8].add(i);
    }
    final order = [
      for (final (_, id, _) in log.responses) queues[id].removeAt(0),
    ];
    final err = log.responses.indexWhere((e) => e.$3);
    expect(order.take(err).where((i) => i > order[err]), isNotEmpty);
    await b.finish();
  });

  test('later bursts are in flight when a write error comes back', () async {
    final b = await _bench(
      const DmaConfig(memoryOutstanding: 8, bReorder: true),
    );
    final log = _AxiLog(b);
    b.memory.errorBeats.add(_local + 0x250);
    b.hold('b');
    await _h2d(b, 0x2000, 0x33);
    await b.waitUntil(() => log.requests.length >= 5, what: '5 bursts');
    b.hold('b', held: false);
    await b.waitRecordWrites(0, 1);
    final r = b.record(0);
    expect(r.code, HarborPcieDma.errorFabric);
    expect(r.bytes, 0x200);
    b.checkLocal(_host, _local, 0x200);
    final errCycle = log.responses.firstWhere((e) => e.$3).$1;
    final later = log.requests.where(
      (e) => e.$1 < errCycle && e.$2 > _local + 0x250,
    );
    expect(later.length, greaterThanOrEqualTo(3));
    await b.finish();
  });

  for (final resetMemory in [false, true]) {
    test('engine reset waits for held write responses, '
        'resetMemory $resetMemory', () async {
      final b = await _bench(
        DmaConfig(
          memoryOutstanding: 8,
          bReorder: true,
          resetMemory: resetMemory,
        ),
      );
      final log = _AxiLog(b);
      b.hold('b');
      await _h2d(b, 0x2000, 0x34);
      await b.waitUntil(() => log.requests.length >= 3, what: '3 bursts');
      await b.engineReset();
      await b.cycles(300);
      expect(
        await b.readReg(HarborPcieDma.registerControl),
        3,
        reason: 'the reset waits for the responses',
      );
      final owed = log.requests.length - log.responses.length;
      expect(owed, greaterThan(1));
      b.hold('b', held: false);
      await _waitResetTaken(b);
      expect(log.responses.length, log.requests.length);
      expect(_sig(b, 'fab_dropped'), 0);
      expect(b.recordWrites(0), isEmpty);
      await _h2d(b, 0x400, 0x35, offset: 0x4000);
      await b.waitRecordWrites(0, 1);
      expect(b.record(0).cookie, 0x35);
      expect(b.record(0).code, 0);
      expect(b.record(0).bytes, 0x400);
      b.checkLocal(_host + 0x4000, _local + 0x4000, 0x400);
      await b.finish();
    });
  }

  test('after a completion error the drain waits for held responses', () async {
    final b = await DmaBench.create(
      const DmaConfig(memoryOutstanding: 8, bReorder: true),
    );
    // The read of tag 3 gets UR.
    b.sink.onTlp = (t) {
      final read =
          t.kind == PcieTlpKind.memRead32 || t.kind == PcieTlpKind.memRead64;
      if (read && t.address == _host + 0x600) {
        _lateUr(b, t);
        return;
      }
      b.host.receive(t);
    };
    await b.start();
    await b.setupRing(dmaCplBase, 4);
    await b.enable(mask: HarborPcieDma.causeError);
    final log = _AxiLog(b);
    b.hold('b');
    await _h2d(b, 0x800, 0x36);
    await b.waitUntil(() => log.requests.isNotEmpty, what: 'a burst');
    await b.cycles(500);
    expect(b.recordWrites(0), isEmpty, reason: 'responses are owed');
    b.hold('b', held: false);
    await b.waitRecordWrites(0, 1);
    final r = b.record(0);
    expect(r.code, HarborPcieDma.errorCompletion);
    expect(r.cookie, 0x36);
    // A tag is one burst. Each burst written counts.
    expect(log.requests.length, inInclusiveRange(1, 3));
    expect(r.bytes, 0x200 * log.requests.length);
    b.checkLocal(_host, _local, r.bytes);
    await b.finish();
  });

  test('the watchdog ends the drain, and the late responses are dropped, '
      'not given to the next copy', () async {
    const timeout = 2000;
    final b = await DmaBench.create(
      const DmaConfig(
        memoryOutstanding: 8,
        bReorder: true,
        timeoutCycles: timeout,
      ),
    );
    b.sink.onTlp = (t) {
      final read =
          t.kind == PcieTlpKind.memRead32 || t.kind == PcieTlpKind.memRead64;
      if (read && t.address == _host + 0x600) {
        _lateUr(b, t);
        return;
      }
      b.host.receive(t);
    };
    await b.start();
    await b.setupRing(dmaCplBase, 4);
    await b.enable(mask: HarborPcieDma.causeError);
    final log = _AxiLog(b);
    b.hold('b');
    await _h2d(b, 0x800, 0x37);
    await b.waitRecordWrites(0, 1);
    final r = b.record(0);
    expect(r.code, HarborPcieDma.errorCompletion);
    expect(r.bytes, 0);
    final stale = log.requests.length - log.responses.length;
    expect(stale, greaterThan(0));

    // The next copy starts while the old responses are still held.
    await b.writeReg(HarborPcieDma.registerIrqCause, HarborPcieDma.causeError);
    await b.engineReset();
    await _waitResetTaken(b);
    await _h2d(b, 0x800, 0x38, offset: 0x4000);
    await b.cycles(200);
    b.hold('b', held: false);
    // The engine reset starts the ring at slot 0 again.
    await b.waitRecordWrites(0, 2);
    final r2 = b.record(0);
    expect(r2.cookie, 0x38);
    expect(r2.code, 0);
    expect(r2.bytes, 0x800);
    b.checkLocal(_host + 0x4000, _local + 0x4000, 0x800);
    expect(_sig(b, 'fab_dropped'), stale);
    await b.finish();
  });

  for (final config in [
    const DmaConfig(memoryOutstanding: 8, kind: HarborFabricKind.wishbone),
    const DmaConfig(memoryOutstanding: 8, kind: HarborFabricKind.tilelink),
    const DmaConfig(memoryOutstanding: 2),
    const DmaConfig(memoryOutstanding: 8, resetMemory: true, crossing: true),
  ]) {
    test(
      'host to device copies, $config '
      'resetMemory ${config.resetMemory} crossing ${config.crossing}',
      () async {
        final b = await _bench(config, seed: 5);
        await _h2d(b, 0x1100, 0x40);
        await b.waitRecordWrites(0, 1);
        expect(b.record(0).code, 0);
        expect(b.record(0).bytes, 0x1100);
        b.checkLocal(_host, _local, 0x1100);
        // An engine reset in the middle of a copy, then a good copy.
        await _h2d(b, 0x2000, 0x41, offset: 0x4000);
        await b.cycles(400);
        await b.engineReset();
        await _waitResetTaken(b);
        await _h2d(b, 0x300, 0x42, offset: 0x8000);
        // The engine reset starts the ring at slot 0 again.
        await b.waitRecordWrites(0, 2);
        final last = b.record(0);
        expect(last.cookie, 0x42);
        expect(last.code, 0);
        b.checkLocal(_host + 0x8000, _local + 0x8000, 0x300);
        expect(b.host.violations, isEmpty);
        await b.finish();
      },
    );
  }
}
