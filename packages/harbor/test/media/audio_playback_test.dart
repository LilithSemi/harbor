import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/mem_target.dart';
import '../util/reg_bus.dart';

const _base = 0x2000;
const _timeout = 200;

int _left(int k) => (k * 0x010203 + 0x123456) & 0xffffff;
int _right(int k) => _left(k) ^ 0xA5A5A5;

/// A controller on a [MasterTop] with a [BeatMemory], a register driver and
/// a consumer on the stream.
class _Bench {
  final MasterTop top;
  final Logic clk;
  final RegBus bus;
  final BeatMemory mem;
  final Logic ready;
  final received = <(int, int)>[];

  /// Ready every cycle when 0, else one cycle in [period].
  int period = 0;
  int _cycle = 0;

  /// Ticks of the periodic consumer with no sample.
  int missed = 0;

  int size = 0;
  int wr = 0;
  int next = 0;

  _Bench(this.top, this.clk, this.bus, this.mem, this.ready) {
    clk.negedge.listen((_) {
      final r = period == 0 || _cycle % period == period - 1;
      _cycle++;
      ready.inject(r ? 1 : 0);
      if (!r) return;
      if (_high('audio_valid')) {
        received.add((
          top.output('audio_left').value.toInt(),
          top.output('audio_right').value.toInt(),
        ));
      } else if (period != 0) {
        missed++;
      }
    });
  }

  bool _high(String p) {
    final v = top.output(p).value;
    return v.isValid && v.toBool();
  }

  int port(String p) => top.output(p).value.toInt();

  Future<void> ring(int frames) async {
    size = frames * 8;
    wr = 0;
    await bus.write(0x30, _base);
    await bus.write(0x38, size);
    await bus.write(0x40, 0);
    await bus.write(0x48, 0);
  }

  /// Puts [n] frames in memory at the write offset and moves it.
  Future<void> put(int n) async {
    for (var i = 0; i < n; i++) {
      mem.writeWord(_base + wr, 0xEE000000 | _left(next));
      mem.writeWord(_base + wr + 4, 0x77000000 | _right(next));
      next++;
      wr = (wr + 8) % size;
    }
    await bus.write(0x40, wr);
  }

  Future<int> free() async {
    final rd = await bus.read(0x48);
    return ((rd - wr - 8) % size) ~/ 8;
  }

  Future<void> until(bool Function() done, {int cycles = 20000}) async {
    for (var i = 0; i < cycles; i++) {
      await clk.nextNegedge;
      if (done()) return;
    }
    throw StateError('condition not met in $cycles cycles');
  }

  Future<void> cycles(int n) async {
    for (var i = 0; i < n; i++) {
      await clk.nextPosedge;
    }
  }

  void expectInOrder(int from, int count) {
    expect(received, hasLength(count));
    for (var k = 0; k < count; k++) {
      expect(received[k], (_left(from + k), _right(from + k)), reason: '$k');
    }
  }
}

Future<_Bench> _bench(
  HarborFabricKind kind, {
  int latency = 2,
  int fifo = 8,
}) async {
  final audio = HarborAudioController(
    baseAddress: 0x10060000,
    fabricKind: kind,
    txFifoDepth: fifo,
    dmaTimeoutCycles: _timeout,
  );
  final top = MasterTop(
    audio,
    iface: 'dma',
    kind: kind,
    config: const HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32),
    withErr: true,
  );
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final ready = Logic(name: 'ready');
  top.input('clk').srcConnection! <= clk;
  top.input('reset').srcConnection! <= reset;
  top.input('sdata_in').srcConnection! <= Const(0);
  top.input('audio_ready').srcConnection! <= ready;
  final bus = RegBus.attach(top, clk);
  final mem = BeatMemory(top, clk, latency: latency, driveErr: true);
  await top.build();
  bus.idle();
  ready.inject(0);
  reset.inject(1);
  Simulator.setMaxSimTime(100000000);
  unawaited(Simulator.run());
  mem.start();
  final b = _Bench(top, clk, bus, mem, ready);
  await b.cycles(4);
  reset.inject(0);
  await b.cycles(2);
  return b;
}

void main() {
  tearDown(() async => Simulator.reset());

  // This test runs first. In one file, each simulation runs slower than the
  // one before it.
  test('keeps up with a 48 kHz consumer under fabric latency', () async {
    // A 25 MHz clock gives one sample each 520 cycles. Each read waits 60
    // cycles in the memory.
    final b = await _bench(HarborFabricKind.wishbone, latency: 60);
    await b.ring(65);
    await b.put(64);
    await b.bus.write(0x20, 1);
    b.period = 520;
    await b.until(() => b.received.length == 40, cycles: 41 * 520);
    expect(b.missed, 0);
    b.expectInOrder(0, 40);
    expect(b.port('tx_underrun_count'), 0);
    await Simulator.endSimulation();
  });

  for (final kind in HarborFabricKind.values) {
    group(kind.name, () {
      test('plays the ring in order and counts an underrun', () async {
        final b = await _bench(kind);
        await b.ring(16);
        await b.put(15);
        await b.bus.write(0x78, 0x13);
        await b.bus.write(0x20, 1);
        const total = 40;
        while (b.next < total) {
          final n = await b.free();
          if (n > 0) await b.put(n < total - b.next ? n : total - b.next);
          await b.cycles(20);
        }
        await b.until(() => b.received.length == total);
        b.expectInOrder(0, total);
        // Software stopped, so the consumer finds the ring empty.
        await b.until(() => (b.port('tx_underrun_count')) > 0);
        final count = b.port('tx_underrun_count');
        await b.cycles(200);
        expect(b.port('tx_underrun_count'), count);
        expect(await b.bus.read(0x98), count);
        expect(await b.bus.read(0x70) & 0x13, 0x13);
        expect(await b.bus.read(0x08) & 0x9, 0x1);
        expect(b.port('interrupt'), 1);
        await b.put(5);
        await b.until(() => b.received.length == total + 5);
        await b.until(() => b.port('tx_underrun_count') == count + 1);
        b.expectInOrder(0, total + 5);
        expect(b.port('tx_dma_error'), 0);
        expect(b.port('tx_dma_timeout'), 0);
        await b.bus.write(0x98, 0);
        expect(await b.bus.read(0x98), 0);
        await Simulator.endSimulation();
      });

      test('a fabric error stops the DMA until software clears it', () async {
        final b = await _bench(kind);
        b.mem.err = true;
        await b.ring(8);
        await b.put(4);
        await b.bus.write(0x78, 0x80);
        await b.bus.write(0x20, 1);
        await b.until(() => b.port('tx_dma_error') == 1);
        await b.cycles(50);
        expect(b.port('tx_dma_timeout'), 0);
        expect(await b.bus.read(0xA0), 1);
        expect(await b.bus.read(0x70) & 0x80, 0x80);
        expect(await b.bus.read(0x08) & 0x8, 0x8);
        expect(await b.bus.read(0x48), 0);
        expect(b.port('interrupt'), 1);
        expect(b.received, isEmpty);
        b.mem.err = false;
        await b.bus.write(0xA0, 1);
        await b.until(() => b.received.length == 4);
        b.expectInOrder(0, 4);
        expect(b.port('tx_dma_error'), 0);
        await Simulator.endSimulation();
      });

      test('a stalled slave ends the read with a timeout', () async {
        final b = await _bench(kind);
        b.mem.stall = true;
        await b.ring(8);
        await b.put(4);
        await b.bus.write(0x20, 1);
        await b.until(
          () => b.port('tx_dma_timeout') == 1,
          cycles: 4 * _timeout,
        );
        expect(b.port('tx_dma_error'), 0);
        expect(await b.bus.read(0xA0), 2);
        expect(b.received, isEmpty);
        b.mem.stall = false;
        await b.bus.write(0xA0, 2);
        await b.until(() => b.received.length == 4);
        b.expectInOrder(0, 4);
        expect(b.port('tx_dma_timeout'), 0);
        await Simulator.endSimulation();
      });

      test('a ring pointer write past the size is rejected', () async {
        final b = await _bench(kind);
        await b.ring(8);
        await b.bus.write(0x78, 0x80);
        expect(b.port('tx_dma_ptr_error'), 0);
        await b.bus.write(0x40, 0x18);
        expect(await b.bus.read(0x40), 0x18);
        expect(await b.bus.read(0xA0), 0);
        for (final bad in [64, 72, 0x1000]) {
          await b.bus.write(0x40, bad);
          expect(await b.bus.read(0x40), 0x18, reason: 'wr $bad');
        }
        expect(await b.bus.read(0xA0), 4);
        expect(b.port('tx_dma_ptr_error'), 1);
        expect(await b.bus.read(0x70) & 0x80, 0x80);
        expect(b.port('interrupt'), 1);
        await b.bus.write(0xA0, 4);
        expect(await b.bus.read(0xA0), 0);
        expect(b.port('tx_dma_ptr_error'), 0);
        await b.bus.write(0x48, 0x10);
        expect(await b.bus.read(0x48), 0x10);
        await b.bus.write(0x48, 64);
        expect(await b.bus.read(0x48), 0x10);
        expect(await b.bus.read(0xA0), 4);
        await b.bus.write(0xA0, 4);
        await b.bus.write(0x40, 0x38);
        expect(await b.bus.read(0x40), 0x38);
        expect(await b.bus.read(0xA0), 0);
        await Simulator.endSimulation();
      });
    });
  }
}
