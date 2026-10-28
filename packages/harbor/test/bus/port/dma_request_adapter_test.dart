import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../../util/mem_target.dart';

const _config = HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32);
const _timeout = 40;

/// The adapter with its request ports as plain ports and the waist behind a
/// native master port `dma`.
class _AdapterDut extends BridgeModule {
  _AdapterDut(HarborFabricKind kind, int timeout)
    : super('AdapterDut_${kind.name}_t$timeout', name: 'dut') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final port = HarborMemoryMasterPort.create(
      module: this,
      name: 'dma',
      kind: kind,
      config: _config,
      clk: input('clk'),
      reset: input('reset'),
    );
    final a = HarborDmaRequestAdapter(
      clk: input('clk'),
      reset: port.reset,
      waist: port.waist,
      readReq: addInput('read_req', Logic()),
      readAddr: addInput('read_addr', Logic(width: 32), width: 32),
      writeReq: addInput('write_req', Logic()),
      writeAddr: addInput('write_addr', Logic(width: 32), width: 32),
      writeData: addInput('write_data', Logic(width: 32), width: 32),
      writeBe: addInput('write_be', Logic(width: 4), width: 4),
      timeoutCycles: timeout,
    );
    // Waist signals for the stability check.
    final w = port.waist;
    addOutput('dbg_req_valid') <= w.reqValid;
    addOutput('dbg_req_ready') <= w.reqReady;
    addOutput('dbg_req_write') <= w.reqWrite;
    addOutput('dbg_req_addr', width: 32) <= w.reqAddr;
    addOutput('dbg_w_valid') <= w.wdataValid;
    addOutput('dbg_w_ready') <= w.wdataReady;
    addOutput('dbg_w_data', width: 32) <= w.wdataData;
    addOutput('dbg_w_strb', width: 4) <= w.wdataStrb;
    for (final n in [
      'read_data',
      'read_valid',
      'write_ack',
      'err',
      'timeout',
    ]) {
      addOutput(n, width: a.output(n).width) <= a.output(n);
    }
  }
}

class _Bench {
  final MasterTop top;
  final Logic clk;
  final BeatMemory mem;
  final Map<String, Logic> drv;

  /// Waist beats that changed while the fabric had not taken them.
  final List<String> unstable = [];

  _Bench(this.top, this.clk, this.mem, this.drv) {
    List<int?> sample() => [
      for (final n in [
        'req_valid',
        'req_ready',
        'req_write',
        'req_addr',
        'w_valid',
        'w_ready',
        'w_data',
        'w_strb',
      ])
        top.output('dbg_$n').value.isValid
            ? top.output('dbg_$n').value.toInt()
            : null,
    ];
    var prev = sample();
    clk.negedge.listen((_) {
      final now = sample();
      if (prev[0] == 1 && prev[1] == 0) {
        for (final i in [2, 3]) {
          if (now[i] != prev[i]) unstable.add('request field $i');
        }
      }
      if (prev[4] == 1 && prev[5] == 0) {
        for (final i in [6, 7]) {
          if (now[i] != prev[i]) unstable.add('write beat field $i');
        }
      }
      prev = now;
    });
  }

  bool _high(String p) {
    final v = top.output(p).value;
    return v.isValid && v.toBool();
  }

  Future<({int data, bool err, bool timeout, int cycles})> _wait(
    String done,
    String req,
  ) async {
    for (var i = 0; i < 1000; i++) {
      await clk.nextNegedge;
      if (_high(done)) {
        final r = (
          data: top.output('read_data').value.toInt(),
          err: _high('err'),
          timeout: _high('timeout'),
          cycles: i,
        );
        drv[req]!.inject(0);
        return r;
      }
    }
    throw StateError('$done never came');
  }

  Future<({int data, bool err, bool timeout, int cycles})> read(int addr) {
    drv['read_addr']!.inject(addr);
    drv['read_req']!.inject(1);
    return _wait('read_valid', 'read_req');
  }

  Future<({int data, bool err, bool timeout, int cycles})> write(
    int addr,
    int data, {
    int be = 0xf,
  }) {
    drv['write_addr']!.inject(addr);
    drv['write_data']!.inject(data);
    drv['write_be']!.inject(be);
    drv['write_req']!.inject(1);
    return _wait('write_ack', 'write_req');
  }
}

Future<_Bench> _bench(
  HarborFabricKind kind, {
  int latency = 0,
  int timeout = _timeout,
}) async {
  final top = MasterTop(
    _AdapterDut(kind, timeout),
    iface: 'dma',
    kind: kind,
    config: _config,
    withErr: true,
  );
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  top.input('clk').srcConnection! <= clk;
  top.input('reset').srcConnection! <= reset;
  final drv = <String, Logic>{};
  for (final n in [
    'read_req',
    'read_addr',
    'write_req',
    'write_addr',
    'write_data',
    'write_be',
  ]) {
    final l = Logic(name: 'drv_$n', width: top.input(n).width);
    top.input(n).srcConnection! <= l;
    drv[n] = l;
  }
  final mem = BeatMemory(
    top,
    clk,
    latency: latency,
    fill: (i) => 0xA0000000 | i,
    driveErr: true,
  );
  await top.build();
  for (final l in drv.values) {
    l.inject(0);
  }
  reset.inject(1);
  Simulator.setMaxSimTime(1000000);
  unawaited(Simulator.run());
  mem.start();
  for (var i = 0; i < 4; i++) {
    await clk.nextPosedge;
  }
  reset.inject(0);
  await clk.nextPosedge;
  return _Bench(top, clk, mem, drv);
}

/// Checks that every beat in the memory log is one of [allowed], as
/// (write, byte address, data). A null data matches any data.
void _expectBeats(_Bench b, List<(bool, int, int?)> allowed) {
  for (final (write, addr, data, _) in b.mem.log) {
    final ok = allowed.any(
      (a) =>
          a.$1 == write &&
          a.$2 == addr &&
          (a.$3 == null || !write || a.$3 == data),
    );
    expect(ok, isTrue, reason: 'unexpected beat $write $addr $data');
  }
}

void main() {
  tearDown(() async => Simulator.reset());

  for (final kind in HarborFabricKind.values) {
    group(kind.name, () {
      test('writes land before the ack and reads return them', () async {
        final b = await _bench(kind, latency: 3);
        for (var k = 0; k < 4; k++) {
          final w = await b.write(0x100 + 4 * k, 0x11110000 + k);
          expect(w.err, isFalse);
          expect(b.mem.readWord(0x100 + 4 * k), 0x11110000 + k);
        }
        final p = await b.write(0x104, 0x00BB0000, be: 0x4);
        expect(p.err, isFalse);
        expect(b.mem.readWord(0x104), 0x11BB0001);
        for (var k = 0; k < 4; k++) {
          final r = await b.read(0x100 + 4 * k);
          expect(r.err, isFalse);
          expect(r.data, k == 1 ? 0x11BB0001 : 0x11110000 + k);
        }
        expect((await b.read(0x200)).data, 0xA0000000 | 0x80);
        await Simulator.endSimulation();
      });

      test('a fabric error ends the request with err', () async {
        final b = await _bench(kind);
        b.mem.err = true;
        final r = await b.read(0x40);
        expect(r.err, isTrue);
        expect(r.timeout, isFalse);
        expect(r.data, 0);
        final w = await b.write(0x40, 0x1234);
        expect(w.err, isTrue);
        expect(w.timeout, isFalse);
        b.mem.err = false;
        expect((await b.read(0x40)).data, 0xA0000010);
        await Simulator.endSimulation();
      });

      test('a stalled slave ends the request with a timeout', () async {
        final b = await _bench(kind);
        b.mem.stall = true;
        final r = await b.read(0x40);
        expect(r.err, isTrue);
        expect(r.timeout, isTrue);
        expect(r.cycles, inInclusiveRange(_timeout, _timeout + 10));
        // The fabric still owes the first read, so this one times out
        // while it waits for it.
        final r2 = await b.read(0x80);
        expect(r2.timeout, isTrue);
        b.mem.stall = false;
        // The late beat of 0x40 is dropped, so 0x80 gets its own data.
        final r3 = await b.read(0x80);
        expect(r3.err, isFalse);
        expect(r3.data, 0xA0000020);
        final w = await b.write(0x80, 0x5555);
        expect(w.err, isFalse);
        expect(b.mem.readWord(0x80), 0x5555);
        await Simulator.endSimulation();
      });

      test('a write after a timed out write keeps the owed beat', () async {
        // A short timeout ends the first write before the fabric took all of
        // its beats.
        for (final t in [2, 3, 4, 6]) {
          final b = await _bench(kind, latency: 2, timeout: t);
          await b.write(0x100, 0x11111111);
          // The device sends another write at once.
          await b.write(0x200, 0x22222222);
          for (var i = 0; i < 60; i++) {
            await b.clk.nextNegedge;
          }
          _expectBeats(b, [
            (true, 0x100, 0x11111111),
            (true, 0x200, 0x22222222),
          ]);
          expect(b.unstable, isEmpty, reason: 'timeout $t');
          await Simulator.endSimulation();
          await Simulator.reset();
        }
      });

      test('a write after a timed out read leaves nothing stuck', () async {
        for (final t in [2, 3, 4, 6]) {
          final b = await _bench(kind, latency: 2, timeout: t);
          await b.read(0x40);
          await b.write(0x300, 0x44444444);
          for (var i = 0; i < 60; i++) {
            await b.clk.nextNegedge;
          }
          _expectBeats(b, [(false, 0x40, null), (true, 0x300, 0x44444444)]);
          expect(b.unstable, isEmpty, reason: 'timeout $t');
          // Both orders keep working, so no handshake is owed forever.
          await b.write(0x300, 0x55555555);
          await b.read(0x40);
          await Simulator.endSimulation();
          await Simulator.reset();
        }
      });

      test('a stalled write then a write with other data', () async {
        final b = await _bench(kind);
        b.mem.stall = true;
        final w1 = await b.write(0x100, 0x11111111);
        expect(w1.timeout, isTrue);
        final w2 = await b.write(0x200, 0x22222222);
        expect(w2.timeout, isTrue);
        b.mem.stall = false;
        for (var i = 0; i < 60; i++) {
          await b.clk.nextNegedge;
        }
        _expectBeats(b, [(true, 0x100, 0x11111111)]);
        expect(b.unstable, isEmpty);
        final w3 = await b.write(0x200, 0x33333333);
        expect(w3.err, isFalse);
        expect(b.mem.readWord(0x200), 0x33333333);
        await Simulator.endSimulation();
      });

      test('a stalled read then a write leaves nothing stuck', () async {
        final b = await _bench(kind);
        b.mem.stall = true;
        expect((await b.read(0x40)).timeout, isTrue);
        expect((await b.write(0x300, 0x44444444)).timeout, isTrue);
        b.mem.stall = false;
        for (var i = 0; i < 60; i++) {
          await b.clk.nextNegedge;
        }
        final w = await b.write(0x300, 0x55555555);
        expect(w.err, isFalse);
        expect(b.mem.readWord(0x300), 0x55555555);
        expect((await b.read(0x300)).data, 0x55555555);
        await Simulator.endSimulation();
      });

      test('a request does not start in the cycle of its timeout', () async {
        // With one cycle of timeout, the first waiting cycle is also the
        // last, and the fabric owes nothing.
        final b = await _bench(kind, timeout: 1);
        final r = await b.read(0x40);
        expect(r.timeout, isTrue);
        final w = await b.write(0x40, 0x1234);
        expect(w.timeout, isTrue);
        for (var i = 0; i < 20; i++) {
          await b.clk.nextNegedge;
        }
        expect(b.mem.log, isEmpty);
        await Simulator.endSimulation();
      });
    });
  }

  test('the name includes the id width', () {
    String name(int idWidth) {
      final m = _NameProbe(idWidth);
      return m.adapter.definitionName;
    }

    expect(name(1), isNot(name(4)));
    expect(name(4), name(4));
  });

  test('the adapter fits the media engine request ports', () async {
    final top = _MediaTop();
    await top.build();
    final a = top.subModules.whereType<HarborDmaRequestAdapter>().single;
    expect(
      a.definitionName,
      'HarborDmaRequestAdapter_a40_d128_i1_r40_t65536_be',
    );
    expect(top.interfaces.keys, containsAll(['bus', 'dma']));
    expect(top.interface('dma').interface, isA<Axi4Interface>());
  });
}

/// A media engine with its request ports on the adapter and an AXI4
/// master port.
class _MediaTop extends BridgeModule {
  _MediaTop() : super('MediaAdapterTop', name: 'top') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final eng = addSubModule(
      HarborMediaEngine(
        baseAddress: 0x40000000,
        codecs: const [
          HarborCodecInstance(
            format: HarborCodecFormat.av1,
            capability: HarborCodecCapability.both,
          ),
        ],
        dmaAddrWidth: 40,
        fabricKind: HarborFabricKind.axi4,
      ),
    );
    eng.input('clk').srcConnection! <= input('clk');
    eng.input('reset').srcConnection! <= input('reset');
    pullUpInterface(eng.interface('bus'), newIntfName: 'bus');
    final port = HarborMemoryMasterPort.create(
      module: this,
      name: 'dma',
      kind: HarborFabricKind.axi4,
      config: const HarborMemoryWaistConfig(addressWidth: 40, dataWidth: 128),
      clk: input('clk'),
      reset: input('reset'),
    );
    final a = HarborDmaRequestAdapter(
      clk: input('clk'),
      reset: port.reset,
      waist: port.waist,
      readReq: eng.output('dma_read_req'),
      readAddr: eng.output('dma_read_addr'),
      writeReq: eng.output('dma_write_req'),
      writeAddr: eng.output('dma_write_addr'),
      writeData: eng.output('dma_write_data'),
      writeBe: eng.output('dma_write_be'),
    );
    eng.input('dma_read_data').srcConnection! <= a.readData;
    eng.input('dma_read_valid').srcConnection! <= a.readValid;
    eng.input('dma_write_ack').srcConnection! <= a.writeAck;
    addOutput('interrupt') <= eng.output('interrupt');
  }
}

/// Holds an adapter whose waist has an ID width of [idWidth].
class _NameProbe extends BridgeModule {
  late final HarborDmaRequestAdapter adapter;

  _NameProbe(int idWidth) : super('NameProbe$idWidth', name: 'probe') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final port = HarborMemoryMasterPort.create(
      module: this,
      name: 'dma',
      kind: HarborFabricKind.axi4,
      config: HarborMemoryWaistConfig(
        addressWidth: 32,
        dataWidth: 32,
        idWidth: idWidth,
      ),
      clk: input('clk'),
      reset: input('reset'),
    );
    adapter = HarborDmaRequestAdapter(
      clk: input('clk'),
      reset: port.reset,
      waist: port.waist,
      readReq: addInput('read_req', Logic()),
      readAddr: addInput('read_addr', Logic(width: 32), width: 32),
      writeReq: addInput('write_req', Logic()),
      writeAddr: addInput('write_addr', Logic(width: 32), width: 32),
      writeData: addInput('write_data', Logic(width: 32), width: 32),
    );
  }
}
