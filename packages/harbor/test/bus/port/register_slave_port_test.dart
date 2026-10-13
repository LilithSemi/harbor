import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'port_harness.dart';

/// Records the direction of every access the register file runs.
List<bool> _accesses(Sim sim, RegFile dut) {
  final order = <bool>[];
  sim.onRise(() {
    if (dut.bus.stb.previousValue!.toBool() &&
        dut.bus.ack.previousValue!.toBool()) {
      order.add(dut.bus.we.previousValue!.toBool());
    }
  });
  return order;
}

/// AXI4-Lite manager on the slave port pins.
class _AxiLite {
  final Sim s;
  final Sender aw;
  final Sender w;
  final Sender ar;
  final Receiver b;
  final Receiver r;

  _AxiLite(this.s)
    : aw = Sender(s, 'bus_AWVALID', 'bus_AWREADY'),
      w = Sender(s, 'bus_WVALID', 'bus_WREADY'),
      ar = Sender(s, 'bus_ARVALID', 'bus_ARREADY'),
      b = Receiver(s, 'bus_BVALID', 'bus_BREADY', ['bus_BRESP']),
      r = Receiver(s, 'bus_RVALID', 'bus_RREADY', ['bus_RDATA', 'bus_RRESP']);

  Future<void> _aw(int addr) => aw.send({'bus_AWADDR': addr});
  Future<void> _w(int data, int strb) =>
      w.send({'bus_WDATA': data, 'bus_WSTRB': strb});

  /// Returns BRESP.
  Future<int> write(
    int addr,
    int data, {
    int strb = 0xf,
    bool wFirst = false,
    int gap = 0,
    int bStall = 0,
  }) async {
    if (gap == 0) {
      await Future.wait([_aw(addr), _w(data, strb)]);
    } else if (wFirst) {
      await _w(data, strb);
      await s.cycles(gap);
      await _aw(addr);
    } else {
      await _aw(addr);
      await s.cycles(gap);
      await _w(data, strb);
    }
    return (await b.take(stall: bStall))['bus_BRESP']!;
  }

  /// Returns RDATA and RRESP.
  Future<(int, int)> read(int addr, {int rStall = 0}) async {
    await ar.send({'bus_ARADDR': addr});
    final rsp = await r.take(stall: rStall);
    return (rsp['bus_RDATA']!, rsp['bus_RRESP']!);
  }
}

/// TileLink-UL master on the slave port pins.
class _TileLink {
  final Sender a;
  final Receiver d;

  _TileLink(Sim s)
    : a = Sender(s, 'bus_A_VALID', 'bus_A_READY'),
      d = Receiver(s, 'bus_D_VALID', 'bus_D_READY', [
        'bus_D_OPCODE',
        'bus_D_DATA',
        'bus_D_DENIED',
        'bus_D_CORRUPT',
        'bus_D_SOURCE',
      ]);

  Future<void> request(
    int opcode,
    int addr, {
    int data = 0,
    int mask = 0xf,
    int source = 0,
    int size = 2,
  }) => a.send({
    'bus_A_OPCODE': opcode,
    'bus_A_ADDRESS': addr,
    'bus_A_DATA': data,
    'bus_A_MASK': mask,
    'bus_A_SIZE': size,
    'bus_A_SOURCE': source,
  });

  Future<Map<String, int>> access(
    int opcode,
    int addr, {
    int data = 0,
    int mask = 0xf,
  }) async {
    await request(opcode, addr, data: data, mask: mask);
    return d.take();
  }
}

StrobeMaster _wishbone(Sim s) => StrobeMaster(
  s,
  strobes: ['bus_CYC', 'bus_STB'],
  we: 'bus_WE',
  addr: 'bus_ADR',
  wdata: 'bus_DAT_MOSI',
  sel: 'bus_SEL',
  ack: 'bus_ACK',
  err: 'bus_ERR',
  rdata: 'bus_DAT_MISO',
);

List<int?> _d(Map<String, int> d, List<String> fields) => [
  for (final f in fields) d['bus_D_$f'],
];

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('AXI4-Lite register slave', () {
    for (final waitStates in [0, 2]) {
      test('reads, writes and byte strobes, $waitStates wait states', () async {
        final dut = RegFile(HarborFabricKind.axi4, waitStates: waitStates);
        final sim = Sim(dut);
        final axi = _AxiLite(sim);
        final order = _accesses(sim, dut);
        await sim.start();

        expect(await axi.write(0x0, 0x11223344), 0);
        expect(await axi.write(0x4, 0xaabbccdd), 0);
        expect(await axi.read(0x0), (0x11223344, 0));
        expect(await axi.read(0x4), (0xaabbccdd, 0));

        // Byte and halfword strobes change only the bytes they mark.
        expect(await axi.write(0x0, 0x000000ee, strb: 0x1), 0);
        expect(await axi.write(0x0, 0x55660000, strb: 0xc), 0);
        expect(await axi.read(0x0), (0x556633ee, 0));
        // An unaligned byte address lands on its word.
        expect(await axi.write(0x5, 0x00007700, strb: 0x2), 0);
        expect(await axi.read(0x4), (0xaabb77dd, 0));

        expect(order.length, 9);
        await sim.stop();
      });
    }

    test('AW before W and W before AW', () async {
      final dut = RegFile(HarborFabricKind.axi4);
      final sim = Sim(dut);
      final axi = _AxiLite(sim);
      final order = _accesses(sim, dut);
      await sim.start();

      expect(await axi.write(0x8, 0x01020304, gap: 3), 0);
      expect(await axi.read(0x8), (0x01020304, 0));
      expect(await axi.write(0x8, 0x0a0b0c0d, wFirst: true, gap: 3), 0);
      expect(await axi.read(0x8), (0x0a0b0c0d, 0));
      expect(order, [true, false, true, false]);
      await sim.stop();
    });

    test('a write waits for its other half', () async {
      final dut = RegFile(HarborFabricKind.axi4);
      final sim = Sim(dut);
      final axi = _AxiLite(sim);
      final order = _accesses(sim, dut);
      await sim.start();

      await axi.aw.send({'bus_AWADDR': 0x4});
      await sim.cycles(5);
      expect(order, isEmpty);
      await axi.w.send({'bus_WDATA': 0x99, 'bus_WSTRB': 0xf});
      expect((await axi.b.take())['bus_BRESP'], 0);
      expect(order, [true]);
      expect(await axi.read(0x4), (0x99, 0));
      await sim.stop();
    });

    test(
      'a read arriving mid wait-stated write does not flip direction',
      () async {
        final dut = RegFile(HarborFabricKind.axi4, waitStates: 3);
        final sim = Sim(dut);
        final axi = _AxiLite(sim);
        final order = _accesses(sim, dut);
        await sim.start();

        // The last completed access is a write, so an unlocked round robin
        // would favor the read as soon as it becomes ready.
        expect(await axi.write(0x4, 0x1), 0);

        final write = axi.write(0x4, 0xbeef);
        // AR becomes held while the write is still locked in and
        // wait-stated. The direction lock must keep serving the write.
        await sim.cycles(1);
        final read = axi.read(0x4);
        expect(await write, 0);
        expect(order, [
          true,
          true,
        ], reason: 'the read must not preempt the locked write');
        expect(await read, (0xbeef, 0));
        expect(order, [true, true, false]);
        await sim.stop();
      },
    );

    test('SLVERR from err on both directions', () async {
      final dut = RegFile(HarborFabricKind.axi4);
      final sim = Sim(dut);
      final axi = _AxiLite(sim);
      await sim.start();

      expect(await axi.write(errWord * 4, 0xdead), 2);
      expect((await axi.read(errWord * 4)).$2, 2);
      expect(await axi.write(0x4, 0x1234), 0);
      expect(await axi.read(0x4), (0x1234, 0));
      await sim.stop();
    });

    test('holds B and R under backpressure, runs each access once', () async {
      final dut = RegFile(HarborFabricKind.axi4);
      final sim = Sim(dut);
      final axi = _AxiLite(sim);
      final order = _accesses(sim, dut);
      await sim.start();

      expect(await axi.write(0x0, 0xcafef00d, bStall: 6), 0);
      expect(await axi.read(0x0, rStall: 6), (0xcafef00d, 0));
      expect(order, [true, false]);
      await sim.stop();
    });

    test('write and read in the same cycle take turns', () async {
      final dut = RegFile(HarborFabricKind.axi4);
      final sim = Sim(dut);
      final axi = _AxiLite(sim);
      final order = _accesses(sim, dut);
      await sim.start();

      await axi.write(0x4, 0x100);
      order.clear();
      for (var i = 0; i < 4; i++) {
        final results = await Future.wait([axi.write(0x0, i), axi.read(0x4)]);
        expect(results[0], 0);
        expect(results[1], (0x100, 0));
      }
      expect(order.length, 8);
      // Round robin: the directions alternate.
      for (var i = 1; i < 8; i++) {
        expect(order[i], isNot(order[i - 1]));
      }
      expect(await axi.read(0x0), (3, 0));
      await sim.stop();
    });

    test('back-to-back accesses', () async {
      final dut = RegFile(HarborFabricKind.axi4);
      final sim = Sim(dut);
      final axi = _AxiLite(sim);
      final order = _accesses(sim, dut);
      await sim.start();

      final writes = [for (var i = 0; i < 3; i++) axi.write(i * 4, 0x1000 + i)];
      expect(await Future.wait(writes), [0, 0, 0]);
      final reads = [for (var i = 0; i < 3; i++) axi.read(i * 4)];
      expect(await Future.wait(reads), [
        for (var i = 0; i < 3; i++) (0x1000 + i, 0),
      ]);
      expect(order, [true, true, true, false, false, false]);
      await sim.stop();
    });
  });

  group('TileLink-UL register slave', () {
    const get = 4, putFull = 0, putPartial = 1;

    test('Get, PutFullData and PutPartialData', () async {
      final dut = RegFile(HarborFabricKind.tilelink);
      final sim = Sim(dut);
      final tl = _TileLink(sim);
      await sim.start();

      var d = await tl.access(putFull, 0x0, data: 0x11223344);
      expect(_d(d, ['OPCODE', 'DENIED']), [0, 0]);
      d = await tl.access(get, 0x0);
      expect(_d(d, ['OPCODE', 'DATA', 'DENIED', 'CORRUPT']), [
        1,
        0x11223344,
        0,
        0,
      ]);

      d = await tl.access(putPartial, 0x2, data: 0x00aa0000, mask: 0x4);
      expect(_d(d, ['OPCODE', 'DENIED']), [0, 0]);
      d = await tl.access(get, 0x0);
      expect(d['bus_D_DATA'], 0x11aa3344);
      await sim.stop();
    });

    test('source comes back on D', () async {
      final dut = RegFile(HarborFabricKind.tilelink);
      final sim = Sim(dut);
      final tl = _TileLink(sim);
      await sim.start();

      await tl.request(get, 0x0, source: 1);
      expect((await tl.d.take())['bus_D_SOURCE'], 1);
      await sim.stop();
    });

    test('denied from err, and other opcodes denied', () async {
      final dut = RegFile(HarborFabricKind.tilelink);
      final sim = Sim(dut);
      final tl = _TileLink(sim);
      final order = _accesses(sim, dut);
      await sim.start();

      final fields = ['OPCODE', 'DENIED', 'CORRUPT'];
      var d = await tl.access(putFull, errWord * 4, data: 1);
      expect(_d(d, fields), [0, 1, 0]);
      d = await tl.access(get, errWord * 4);
      expect(_d(d, fields), [1, 1, 1]);

      // ArithmeticData and Intent never reach the device.
      d = await tl.access(2, 0x0, data: 5);
      expect(_d(d, fields), [1, 1, 1]);
      d = await tl.access(5, 0x0);
      expect(_d(d, fields), [2, 1, 0]);
      expect(order.length, 2);
      await sim.stop();
    });

    test('back-to-back requests while D is held', () async {
      final dut = RegFile(HarborFabricKind.tilelink, waitStates: 1);
      final sim = Sim(dut);
      final tl = _TileLink(sim);
      final order = _accesses(sim, dut);
      await sim.start();

      // Two requests go in before any response is taken.
      await tl.request(putFull, 0x4, data: 0x77);
      await tl.request(get, 0x4);
      await sim.cycles(6);
      expect(order, [true], reason: 'the Get waits for the D slot');
      final d0 = await tl.d.take();
      final d1 = await tl.d.take(stall: 2);
      expect(d0['bus_D_OPCODE'], 0);
      expect(_d(d1, ['OPCODE', 'DATA']), [1, 0x77]);
      expect(order, [true, false]);
      await sim.stop();
    });

    test('two sources queued behind a held D keep their own source', () async {
      final dut = RegFile(HarborFabricKind.tilelink, waitStates: 1);
      final sim = Sim(dut);
      final tl = _TileLink(sim);
      final order = _accesses(sim, dut);
      await sim.start();

      // Different sources, not the same one, queued behind a held D. The
      // config's source field is 1 bit wide, so 0 and 1 are the two values.
      await tl.request(get, 0x4, source: 0);
      await tl.request(get, 0x8, source: 1);
      await sim.cycles(6);
      expect(order, [false], reason: 'the second Get waits for the D slot');
      final d0 = await tl.d.take();
      final d1 = await tl.d.take(stall: 2);
      expect(d0['bus_D_SOURCE'], 0);
      expect(d1['bus_D_SOURCE'], 1);
      expect(order, [false, false]);
      await sim.stop();
    });

    test('an oversize Put is denied and every beat is drained', () async {
      final dut = RegFile(HarborFabricKind.tilelink);
      final sim = Sim(dut);
      final tl = _TileLink(sim);
      final order = _accesses(sim, dut);
      await sim.start();

      // Size 4 on a 32-bit port spans 4 beats. None of them should reach
      // the device, and only one AccessAck comes back.
      await tl.request(putFull, 0x0, data: 0x1, size: 4);
      await tl.request(putFull, 0x0, data: 0x2, size: 4);
      await tl.request(putFull, 0x0, data: 0x3, size: 4);
      await tl.request(putFull, 0x0, data: 0x4, size: 4);
      final d = await tl.d.take();
      expect(_d(d, ['OPCODE', 'DENIED', 'CORRUPT']), [0, 1, 0]);
      expect(order, isEmpty);

      // The fabric is back in sync for the next, in-range request.
      var ok = await tl.access(putFull, 0x4, data: 0x55);
      expect(_d(ok, ['OPCODE', 'DENIED']), [0, 0]);
      ok = await tl.access(get, 0x4);
      expect(ok['bus_D_DATA'], 0x55);
      await sim.stop();
    });

    test(
      'an oversize Get is denied with a matching number of D beats',
      () async {
        final dut = RegFile(HarborFabricKind.tilelink);
        final sim = Sim(dut);
        final tl = _TileLink(sim);
        final order = _accesses(sim, dut);
        await sim.start();

        // Size 3 spans 2 beats. A Get never bursts on A, only the response.
        await tl.request(get, 0x0, size: 3);
        final d0 = await tl.d.take();
        expect(_d(d0, ['OPCODE', 'DENIED', 'CORRUPT']), [1, 1, 1]);
        final d1 = await tl.d.take();
        expect(_d(d1, ['OPCODE', 'DENIED', 'CORRUPT']), [1, 1, 1]);
        expect(order, isEmpty);

        final ok = await tl.access(get, 0x0);
        expect(_d(ok, ['OPCODE', 'DENIED']), [1, 0]);
        await sim.stop();
      },
    );

    for (final (name, opcode) in [('Arithmetic', 2), ('Logical', 3)]) {
      test(
        'oversize $name drains A and denies with matching D beats',
        () async {
          final dut = RegFile(HarborFabricKind.tilelink);
          final sim = Sim(dut);
          final tl = _TileLink(sim);
          final order = _accesses(sim, dut);
          await sim.start();

          await tl.request(opcode, 0x0, data: 0x1, size: 3);
          // The response must wait for the second beat, not answer the first
          // beat as if it were its own, separate request.
          await sim.cycles(2);
          expect(sim.pre('bus_D_VALID'), 0);
          await tl.request(opcode, 0x0, data: 0x2, size: 3);
          final d0 = await tl.d.take();
          expect(_d(d0, ['OPCODE', 'DENIED', 'CORRUPT']), [1, 1, 1]);
          final d1 = await tl.d.take();
          expect(_d(d1, ['OPCODE', 'DENIED', 'CORRUPT']), [1, 1, 1]);
          expect(order, isEmpty);
          await sim.stop();
        },
      );
    }
  });

  group('Wishbone register slave', () {
    test('reads, writes, byte selects and errors', () async {
      final dut = RegFile(HarborFabricKind.wishbone);
      final sim = Sim(dut);
      final wb = _wishbone(sim);
      await sim.start();

      expect((await wb.access(true, 0x0, data: 0x12345678)).$2, 1);
      expect(await wb.access(false, 0x0), (0x12345678, 1, 0));
      await wb.access(true, 0x0, data: 0x0000ff00, byteSel: 0x2);
      expect((await wb.access(false, 0x0)).$1, 0x1234ff78);

      expect(await wb.access(true, errWord * 4, data: 1), (0, 0, 1));
      expect((await wb.access(false, errWord * 4)).$3, 1);
      await sim.stop();
    });

    test('back-to-back with the strobe held', () async {
      final dut = RegFile(HarborFabricKind.wishbone);
      final sim = Sim(dut);
      final wb = _wishbone(sim);
      final order = _accesses(sim, dut);
      await sim.start();

      final results = await Future.wait([
        wb.access(true, 0x4, data: 0xa),
        wb.access(true, 0x8, data: 0xb),
        wb.access(false, 0x4),
        wb.access(false, 0x8),
      ]);
      expect(results[2].$1, 0xa);
      expect(results[3].$1, 0xb);
      expect(order, [true, true, false, false]);
      await sim.stop();
    });

    test('addr is aligned down to the word even when ADR is not', () async {
      final dut = RegFile(HarborFabricKind.wishbone);
      final sim = Sim(dut);
      final wb = _wishbone(sim);
      final addrs = <int>[];
      sim.onRise(() {
        if (dut.bus.stb.previousValue!.toBool()) {
          addrs.add(dut.bus.addr.previousValue!.toInt());
        }
      });
      await sim.start();

      // ADR 0x5 is a byte address into the word at 0x4. sel marks the lane;
      // the device must see the aligned word address, not 0x5.
      await wb.access(true, 0x5, data: 0x0000aa00, byteSel: 0x2);
      expect(addrs, isNotEmpty);
      expect(addrs.toSet(), {0x4});
      expect((await wb.access(false, 0x4)).$1, 0x0000aa00);
      await sim.stop();
    });
  });
}
