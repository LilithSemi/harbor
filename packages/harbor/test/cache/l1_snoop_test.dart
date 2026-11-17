import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'l1_burst_bench.dart';

const _base = 0x80000000;
const _line = 32;

Future<BurstDut> _dut({
  void Function(Module cache, Logic clk)? connect,
  int latency = 3,
}) => BurstDut.make(
  instruction: false,
  xlen: 64,
  lineSize: _line,
  physical: true,
  snoop: true,
  connect: connect,
  latency: latency,
);

/// A DMA write of [value] to the word at [addr], seen by memory now.
void _dmaWrite(BurstDut dut, int addr, int value) =>
    dut.mem.writeValue(addr, 3, BigInt.from(value));

Future<void> _inval(BurstDut dut, List<int> lines) async {
  for (final a in lines) {
    dut.drive('inval_valid', 1);
    dut.drive('inval_addr', a);
    await dut.step();
  }
  dut.drive('inval_valid', 0);
  await dut.steps(3);
}

void main() {
  tearDown(() async {
    await Simulator.endSimulation();
    await Simulator.reset();
  });

  test('a snoop drops a resident line', () async {
    final dut = await _dut();
    const a = _base + 3 * _line;
    await dut.read(a);
    _dmaWrite(dut, a, 0x1234);
    await _inval(dut, [a]);
    expect(await dut.read(a + 0), BigInt.from(0x1234));
    expect(dut.mem.requests, hasLength(2));
  });

  test('a snoop to another tag at the index keeps the line', () async {
    final dut = await _dut();
    const a = _base + 3 * _line;
    await dut.read(a);
    await _inval(dut, [a + 1024]);
    expect(await dut.read(a), dut.mem.wordAt(a));
    expect(dut.mem.requests, hasLength(1));
  });

  test('back to back snoops drop each line of a DMA burst', () async {
    final dut = await _dut();
    final lines = [for (var i = 0; i < 4; i++) _base + (8 + i) * _line];
    for (final a in lines) {
      await dut.read(a + 8);
    }
    for (final a in lines) {
      _dmaWrite(dut, a + 8, a ^ 0x5555);
    }
    await _inval(dut, lines);
    for (final a in lines) {
      expect(await dut.read(a + 8), BigInt.from(a ^ 0x5555));
    }
    expect(dut.mem.requests, hasLength(8));
  });

  // Offsets from the first beat: the beats, the commit and the cycles in
  // which the valid bit waits to be written.
  for (var offset = 0; offset < 8; offset++) {
    test(
      'a snoop $offset cycles into a refill of its line kills the refill',
      () async {
        final dut = await _dut();
        const a = _base + 5 * _line;
        var seen = -1;
        dut.perCycle.add(() {
          if (dut.cache.input('mem_done').value.toBool() && seen < 0) seen = 0;
          if (seen >= 0) {
            dut.drive('inval_valid', seen == offset ? 1 : 0);
            dut.drive('inval_addr', a);
            if (seen == offset) _dmaWrite(dut, a, 0xbeef);
            seen++;
          }
        });
        await dut.read(a);
        while (seen <= offset + 1) {
          await dut.step();
        }
        dut.perCycle.clear();
        dut.drive('inval_valid', 0);
        await dut.steps(4);
        expect(await dut.read(a), BigInt.from(0xbeef));
        expect(dut.mem.requests, hasLength(2));
      },
    );
  }

  test('inval_hold during a refill keeps the line invalid', () async {
    final dut = await _dut(latency: 6);
    const a = _base + 7 * _line;
    var cycle = 0;
    dut.perCycle.add(() => dut.drive('inval_hold', ++cycle == 3 ? 1 : 0));
    expect(await dut.read(a + 16), dut.mem.wordAt(a + 16));
    dut.perCycle.clear();
    dut.drive('inval_hold', 0);
    expect(await dut.read(a + 16), dut.mem.wordAt(a + 16));
    expect(dut.mem.requests, hasLength(2));
  });

  test('a snoop in the cycle of a store hit drops the line', () async {
    final dut = await _dut();
    const a = _base + 9 * _line;
    await dut.read(a);
    var pulse = 0;
    dut.perCycle.add(() {
      if (pulse == 1) dut.drive('inval_valid', 0);
      if (pulse > 0) pulse--;
    });
    // The snoop is in the same cycle as the store acknowledge.
    dut.mem.onWrite = (req) {
      dut.drive('inval_valid', 1);
      dut.drive('inval_addr', a);
      pulse = 2;
    };
    expect(await dut.write(a + 8, 3, BigInt.from(0x77)), isTrue);
    dut.perCycle.clear();
    dut.drive('inval_valid', 0);
    await dut.steps(3);
    _dmaWrite(dut, a, 0x99);
    expect(await dut.read(a), BigInt.from(0x99));
    expect(await dut.read(a + 8), BigInt.from(0x77));
    expect(dut.mem.requests, hasLength(3));
  });

  test('snoop clears do not lose the valid bit of a refill', () async {
    final dut = await _dut();
    // Lines in other valid RAM words than the refill line.
    final others = [for (var i = 0; i < 6; i++) _base + (16 + i) * _line];
    for (final o in others) {
      await dut.read(o);
    }
    const a = _base + 2 * _line;
    var i = 0;
    dut.perCycle.add(() {
      dut.drive('inval_valid', 1);
      dut.drive('inval_addr', others[i++ % others.length]);
    });
    expect(await dut.read(a), dut.mem.wordAt(a));
    dut.perCycle.clear();
    dut.drive('inval_valid', 0);
    await dut.steps(3);
    final before = dut.mem.requests.length;
    expect(await dut.read(a + 8), dut.mem.wordAt(a + 8));
    expect(dut.mem.requests, hasLength(before));
    for (final o in others) {
      await dut.read(o);
    }
    expect(dut.mem.requests, hasLength(before + others.length));
  });

  group('inline stage', () {
    const wbCfg = WishboneConfig(
      addressWidth: 32,
      dataWidth: 64,
      useCti: true,
      useErr: true,
    );

    void zero(PairInterface m, PairInterface s) {
      for (final p in m.getPorts([PairDirection.fromProvider]).values) {
        p.put(0);
      }
      for (final p in s.getPorts([PairDirection.fromConsumer]).values) {
        p.put(0);
      }
    }

    /// One Wishbone write burst from [addr] through the stage. The fabric
    /// acknowledges each beat in the cycle it sees STB, and the beat lands in
    /// memory then. Returns when the master sees the last acknowledge.
    Future<void> wbWrite(
      BurstDut dut,
      WishboneInterface m,
      WishboneInterface s,
      int addr,
      List<int> values,
    ) async {
      m.cyc.inject(1);
      m.we.inject(1);
      m.stb.inject(1);
      var b = 0;
      while (true) {
        m.adr.inject(addr + 8 * b);
        m.cti!.inject(b == values.length - 1 ? 7 : 2);
        await dut.clk.nextNegedge;
        final take = b < values.length && s.stb.value.toBool();
        s.ack.inject(take ? 1 : 0);
        if (take) _dmaWrite(dut, addr + 8 * b, values[b]);
        await dut.clk.nextNegedge;
        final done = m.ack.value.toBool() && b == values.length - 1;
        await dut.step();
        s.ack.inject(0);
        if (done) break;
        if (take && b < values.length - 1) b++;
      }
      m.cyc.inject(0);
      m.we.inject(0);
      m.stb.inject(0);
    }

    Future<(BurstDut, WishboneInterface, WishboneInterface)> wbDut() async {
      late WishboneInterface m;
      late WishboneInterface s;
      final dut = await _dut(
        connect: (cache, clk) {
          m = WishboneInterface(wbCfg);
          s = WishboneInterface(wbCfg);
          zero(m, s);
          HarborDmaSnoop.wishbone(
            clk,
            cache.input('reset').srcConnection!,
            master: m,
            slave: s,
            lineSize: _line,
          ).connectCache(cache as HarborL1DCache);
        },
      );
      return (dut, m, s);
    }

    for (var gap = 0; gap <= 4; gap++) {
      test(
        'Wishbone: a load $gap cycles after the last ack sees the write',
        () async {
          final (dut, m, s) = await wbDut();
          const a = _base + 4 * _line + 8;
          await dut.read(a);
          await wbWrite(dut, m, s, a, [0x4000]);
          await dut.steps(gap);
          expect(await dut.read(a), BigInt.from(0x4000), reason: 'stale hit');
        },
      );

      test('AXI4: a load $gap cycles after B sees the write', () async {
        late Axi4Interface m;
        late Axi4Interface s;
        final dut = await _dut(
          connect: (cache, clk) {
            m = Axi4Interface(addressWidth: 32, dataWidth: 64, idWidth: 2);
            s = Axi4Interface(addressWidth: 32, dataWidth: 64, idWidth: 2);
            zero(m, s);
            HarborDmaSnoop.axi4(
              clk,
              cache.input('reset').srcConnection!,
              master: m,
              slave: s,
              lineSize: _line,
            ).connectCache(cache as HarborL1DCache);
          },
        );
        const a = _base + 4 * _line + 8;
        await dut.read(a);
        m.awValid.inject(1);
        m.awAddr.inject(a);
        m.awSize.inject(3);
        m.awBurst.inject(1);
        s.awReady.inject(1);
        while (true) {
          await dut.clk.nextNegedge;
          final taken = m.awReady.value.toBool();
          await dut.step();
          if (taken) break;
        }
        m.awValid.inject(0);
        _dmaWrite(dut, a, 0x5000);
        s.bValid.inject(1);
        m.bReady.inject(1);
        while (true) {
          await dut.clk.nextNegedge;
          final done = m.bValid.value.toBool();
          await dut.step();
          if (done) break;
        }
        s.bValid.inject(0);
        m.bReady.inject(0);
        await dut.steps(gap);
        expect(await dut.read(a), BigInt.from(0x5000), reason: 'stale hit');
      });
    }

    test('a DMA burst across several lines drops every line', () async {
      final (dut, m, s) = await wbDut();
      const a = _base + 10 * _line;
      for (var l = 0; l < 3; l++) {
        await dut.read(a + l * _line);
      }
      // 12 beats of 8 bytes from the middle of the first line.
      await wbWrite(dut, m, s, a + 16, [
        for (var b = 0; b < 12; b++) 0x700 + b,
      ]);
      for (var b = 0; b < 12; b++) {
        expect(await dut.read(a + 16 + 8 * b), BigInt.from(0x700 + b));
      }
      // Lines a, a+32, a+64 and the part of a+96 the burst reached.
      expect(dut.mem.requests, hasLength(3 + 4));
    });

    test(
      'a DMA write during a refill of its line leaves the line invalid',
      () async {
        late WishboneInterface m;
        late WishboneInterface s;
        final dut = await BurstDut.make(
          instruction: false,
          xlen: 64,
          lineSize: _line,
          physical: true,
          snoop: true,
          latency: 8,
          connect: (cache, clk) {
            m = WishboneInterface(wbCfg);
            s = WishboneInterface(wbCfg);
            zero(m, s);
            HarborDmaSnoop.wishbone(
              clk,
              cache.input('reset').srcConnection!,
              master: m,
              slave: s,
              lineSize: _line,
            ).connectCache(cache as HarborL1DCache);
          },
        );
        const a = _base + 12 * _line;
        final load = dut.read(a);
        while (!dut.mem.busy) {
          await dut.clk.nextPosedge;
        }
        // The write is in memory before the refill reads it, so the refill
        // gets the new word, but the line must not stay valid with words the
        // refill read earlier.
        m.cyc.inject(1);
        m.we.inject(1);
        m.stb.inject(1);
        m.adr.inject(a + 24);
        m.cti!.inject(7);
        await dut.clk.nextNegedge;
        s.ack.inject(1);
        _dmaWrite(dut, a + 24, 0x6060);
        await dut.clk.nextPosedge;
        s.ack.inject(0);
        await load;
        m.cyc.inject(0);
        m.we.inject(0);
        m.stb.inject(0);
        await dut.steps(6);
        expect(await dut.read(a + 24), BigInt.from(0x6060));
        expect(dut.mem.requests, hasLength(2));
      },
    );

    test('two masters: the data is new when the descriptor is', () async {
      late WishboneInterface ma, sa, mb, sb;
      final dut = await _dut(
        connect: (cache, clk) {
          ma = WishboneInterface(wbCfg);
          sa = WishboneInterface(wbCfg);
          mb = WishboneInterface(wbCfg);
          sb = WishboneInterface(wbCfg);
          zero(ma, sa);
          zero(mb, sb);
          final reset = cache.input('reset').srcConnection!;
          final a = HarborDmaSnoop.wishbone(
            clk,
            reset,
            master: ma,
            slave: sa,
            lineSize: _line,
            name: 'data_dma',
          );
          final b = HarborDmaSnoop.wishbone(
            clk,
            reset,
            master: mb,
            slave: sb,
            lineSize: _line,
            name: 'desc_dma',
          );
          HarborDmaSnoopMerge(clk, reset, [
            a,
            b,
          ], addressWidth: 32).connectCache(cache as HarborL1DCache);
        },
      );
      const data = _base + 32 * _line;
      const desc = _base + 2 * _line;
      for (var l = 0; l < 4; l++) {
        await dut.read(data + l * _line);
      }
      expect(await dut.read(desc), isNot(BigInt.from(1)));
      // The data master writes 4 lines, then the other master writes the
      // descriptor once the data write is complete.
      await wbWrite(dut, ma, sa, data, [
        for (var w = 0; w < 16; w++) 0x900 + w,
      ]);
      await wbWrite(dut, mb, sb, desc, [1]);
      while (await dut.read(desc) != BigInt.one) {}
      for (var w = 0; w < 16; w++) {
        expect(await dut.read(data + 8 * w), BigInt.from(0x900 + w));
      }
    });
  });

  group('AXI4 tap into the cache', () {
    for (final (latency, land, window) in [
      (3, 1, null),
      (8, 1, null),
      (8, 6, null),
      (3, 1, 'in'),
      (3, 1, 'out'),
      // The data lands late, so a refill can start after the last invalidate.
      (3, 12, null),
      (3, 12, 'out'),
    ]) {
      for (final kind in ['single', 'incr4', 'wrap', 'b2b']) {
        test(
          'a refill started around the AW sees the write: lat $latency '
          'land +$land $kind${window == null ? '' : ' window $window'}',
          () async {
            await _raceSweep(latency, land, kind, window);
          },
        );
      }
    }

    test('B the cycle after AW does not pass the invalidate', () async {
      late Axi4Interface m;
      late Axi4Interface s;
      final dut = await _dut(
        connect: (cache, clk) {
          m = Axi4Interface(addressWidth: 32, dataWidth: 64, idWidth: 2);
          s = Axi4Interface(addressWidth: 32, dataWidth: 64, idWidth: 2);
          _zeroPorts(m, s);
          HarborDmaSnoop.axi4(
            clk,
            cache.input('reset').srcConnection!,
            master: m,
            slave: s,
            lineSize: _line,
          )..connectCache(cache as HarborL1DCache);
        },
      );
      const a = _base + 0x100;
      await dut.read(a + 8);
      _dmaWrite(dut, a + 8, 0x4321);
      s.awReady.inject(1);
      m.bReady.inject(1);
      m.awValid.inject(1);
      m.awAddr.inject(a + 8);
      m.awLen.inject(0);
      m.awSize.inject(3);
      m.awBurst.inject(1);
      await dut.step();
      m.awValid.inject(0);
      s.bValid.inject(1);
      // The master loads in the cycle after it sees B.
      for (var i = 0; i < 20; i++) {
        await dut.clk.nextNegedge;
        final seen = m.bValid.value.toBool();
        await dut.step();
        if (seen) {
          s.bValid.inject(0);
          break;
        }
      }
      expect(await dut.read(a + 8), BigInt.from(0x4321));
    });

    test('a write outside the window does not leave a stale line', () async {
      late Axi4Interface m;
      late Axi4Interface s;
      late HarborDmaSnoop tap;
      final dut = await _dut(
        connect: (cache, clk) {
          m = Axi4Interface(addressWidth: 32, dataWidth: 64, idWidth: 2);
          s = Axi4Interface(addressWidth: 32, dataWidth: 64, idWidth: 2);
          _zeroPorts(m, s);
          tap = HarborDmaSnoop.axi4(
            clk,
            cache.input('reset').srcConnection!,
            master: m,
            slave: s,
            lineSize: _line,
            writeWindow: const [BusAddressRange(0x80100000, 0x10000)],
          )..connectCache(cache as HarborL1DCache);
        },
      );
      const a = 0x80000100;
      await dut.read(a + 8);
      s.awReady.inject(1);
      m.bReady.inject(1);
      m.awValid.inject(1);
      m.awAddr.inject(a + 8);
      m.awLen.inject(0);
      m.awSize.inject(3);
      m.awBurst.inject(1);
      await dut.step();
      m.awValid.inject(0);
      dut.mem.writeValue(a + 8, 3, BigInt.from(0x1234));
      s.bValid.inject(1);
      for (var i = 0; i < 20; i++) {
        await dut.clk.nextNegedge;
        final take = m.bValid.value.toBool();
        await dut.step();
        if (take) {
          s.bValid.inject(0);
          break;
        }
      }
      expect(tap.output('window_miss').value.toBool(), isTrue);
      await dut.steps(4);
      expect(await dut.read(a + 8), BigInt.from(0x1234));
    });
  });
}

void _zeroPorts(PairInterface m, PairInterface s) {
  for (final p in m.getPorts([PairDirection.fromProvider]).values) {
    p.put(0);
  }
  for (final p in s.getPorts([PairDirection.fromConsumer]).values) {
    p.put(0);
  }
}

typedef _Aw = ({int addr, int len, int size, int burst});

/// Bursts that cover the word [a] + 8 of line [a].
Map<String, List<_Aw>> _kinds(int a) => {
  'single': [(addr: a + 8, len: 0, size: 3, burst: 1)],
  // Four lines, the last one is the target.
  'incr4': [(addr: a - 3 * _line, len: 15, size: 3, burst: 1)],
  // A 64 byte wrap block that starts in its upper half, so the target wraps.
  'wrap': [(addr: (a & ~63) + ((a & 32) ^ 32) + 8, len: 7, size: 3, burst: 2)],
  // Another line first, then the target in the next cycle.
  'b2b': [
    (addr: a + 16 * _line, len: 0, size: 3, burst: 1),
    (addr: a + 8, len: 0, size: 3, burst: 1),
  ],
};

/// Starts a refill of the target line at each cycle around the AW, and lets
/// the DMA write land [land] cycles after the last AW. The load after the B
/// must read the new value.
Future<void> _raceSweep(
  int latency,
  int land,
  String kind,
  String? window,
) async {
  late Axi4Interface m;
  late Axi4Interface s;
  final dut = await _dut(
    latency: latency,
    connect: (cache, clk) {
      m = Axi4Interface(addressWidth: 32, dataWidth: 64, idWidth: 2);
      s = Axi4Interface(addressWidth: 32, dataWidth: 64, idWidth: 2);
      _zeroPorts(m, s);
      HarborDmaSnoop.axi4(
        clk,
        cache.input('reset').srcConnection!,
        master: m,
        slave: s,
        lineSize: _line,
        writeWindow: switch (window) {
          'in' => const [BusAddressRange(_base, 1 << 20)],
          'out' => const [BusAddressRange(0x90000000, 1 << 20)],
          _ => null,
        },
      )..connectCache(cache as HarborL1DCache);
    },
  );
  s.awReady.inject(1);
  m.bReady.inject(1);
  var idx = 0;
  for (var d = -8; d <= 14; d++) {
    final a = _base + (8 + 4 * idx++) * _line;
    final newV = 0xd0000 + idx;
    final aws = _kinds(a)[kind]!;
    // Cycle numbers are the rising edges from here.
    const start = 12;
    final target = start + aws.length - 1;
    final readAt = target + d;
    final landAt = target + land;
    var c = 0;
    var awI = 0;
    var readOn = false;
    var readDone = false;
    var bDone = false;
    void showAw() {
      if (awI < aws.length && c >= start + awI - 1) {
        final w = aws[awI];
        m.awValid.inject(1);
        m.awAddr.inject(w.addr);
        m.awLen.inject(w.len);
        m.awSize.inject(w.size);
        m.awBurst.inject(w.burst);
      }
    }

    showAw();
    while (!(readDone && bDone) || c < target + 2) {
      await dut.clk.nextNegedge;
      final next = c + 1;
      if (readOn && dut.out('resp_valid')) {
        dut.drive('req_valid', 0);
        readOn = false;
        readDone = true;
      }
      if (next == readAt) {
        dut.drive('req_addr', a + 8);
        dut.drive('req_write', 0);
        dut.drive('req_size', 3);
        dut.drive('req_valid', 1);
        readOn = true;
      }
      if (next == landAt) _dmaWrite(dut, a + 8, newV);
      final awTake = m.awValid.value.toBool() && m.awReady.value.toBool();
      final bTake = s.bValid.value.toBool() && m.bValid.value.toBool();
      await dut.step();
      c++;
      if (awTake) {
        awI++;
        m.awValid.inject(0);
        showAw();
      } else if (!m.awValid.value.toBool()) {
        showAw();
      }
      if (bTake) {
        s.bValid.inject(0);
        bDone = true;
      } else if (!bDone && awI == aws.length && c >= landAt) {
        s.bValid.inject(1);
      }
      if (c > 400) throw StateError('stuck');
    }
    final got = await dut.read(a + 8);
    await dut.steps(4);
    expect(got, BigInt.from(newV), reason: 'stale at d=$d');
    await dut.steps(4);
  }
}
