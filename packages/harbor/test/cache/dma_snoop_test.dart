import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Runs a snoop stage and records its invalidates and hold.
class _Probe {
  _Probe(this.snoop, this.clk) {
    // A line counts when it is shown and taken. Sample in the middle of the
    // cycle, when the inputs have settled.
    clk.negedge.listen((_) {
      final ready = snoop.input('inval_ready').value;
      if (snoop.output('inval_valid').value.toBool() &&
          (!ready.isValid || ready.toBool())) {
        lines.add(snoop.output('inval_addr').value.toInt());
      }
    });
  }
  final Module snoop;
  final Logic clk;
  final lines = <int>[];

  /// One rising edge.
  Future<void> step() => clk.nextPosedge;

  /// Waits for the falling edge, when the inputs of this cycle have settled.
  Future<void> settle() => clk.nextNegedge;

  Future<void> steps(int n) async {
    for (var i = 0; i < n; i++) {
      await step();
    }
  }
}

var _running = false;

/// Puts 0 on every port that the test drives.
void _zero(PairInterface master, PairInterface slave) {
  for (final p in master.getPorts([PairDirection.fromProvider]).values) {
    p.put(0);
  }
  for (final p in slave.getPorts([PairDirection.fromConsumer]).values) {
    p.put(0);
  }
}

Future<(_Probe, HarborDmaSnoop)> _start(
  HarborDmaSnoop Function(Logic clk, Logic reset) make,
) async {
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset')..put(1);
  final tap = make(clk, reset);
  tap.invalReadyIn.put(1);
  tap.invalQuietIn.put(1);
  tap.fillLineIn.put(0);
  await tap.build();
  Simulator.setMaxSimTime(100000);
  unawaited(Simulator.run());
  _running = true;
  final p = _Probe(tap, clk);
  await p.steps(2);
  reset.inject(0);
  await p.step();
  p.lines.clear();
  return (p, tap);
}

void main() {
  tearDown(() async {
    if (_running) await Simulator.endSimulation();
    _running = false;
    await Simulator.reset();
  });

  group('AXI4', () {
    late Axi4Interface m;
    late Axi4Interface s;

    Future<(_Probe, HarborDmaSnoop)> start({int awDepth = 4}) {
      m = Axi4Interface(addressWidth: 32, dataWidth: 64, idWidth: 2);
      s = Axi4Interface(addressWidth: 32, dataWidth: 64, idWidth: 2);
      _zero(m, s);
      return _start(
        (clk, reset) => HarborDmaSnoop.axi4(
          clk,
          reset,
          master: m,
          slave: s,
          lineSize: 32,
          awDepth: awDepth,
        ),
      );
    }

    /// Sends one AW and waits until the stage takes it.
    Future<void> aw(_Probe p, int addr, int len, int size, int burst) async {
      m.awValid.inject(1);
      m.awAddr.inject(addr);
      m.awLen.inject(len);
      m.awSize.inject(size);
      m.awBurst.inject(burst);
      s.awReady.inject(1);
      while (true) {
        await p.settle();
        final taken = m.awReady.value.toBool();
        await p.step();
        if (taken) break;
      }
      m.awValid.inject(0);
    }

    test('an INCR burst gives one line per cycle and B waits for it', () async {
      final (p, _) = await start();
      // 16 beats of 8 bytes from 0x1010: lines 0x1000 to 0x1080.
      await aw(p, 0x1010, 15, 3, 1);
      s.bValid.inject(1);
      m.bReady.inject(1);
      var held = 0;
      while (true) {
        await p.settle();
        if (m.bValid.value.toBool()) break;
        held++;
        await p.step();
      }
      await p.step();
      s.bValid.inject(0);
      expect(p.lines, [0x1000, 0x1020, 0x1040, 0x1060, 0x1080]);
      expect(held, greaterThanOrEqualTo(4));
    });

    test(
      'BVALID stays high until BREADY, also when a new AW is taken',
      () async {
        final (p, _) = await start();
        await aw(p, 0x1000, 0, 3, 1);
        await p.steps(4);
        // B arrives while the master is not ready, and the master sends its
        // next AW in the same cycle.
        s.bValid.inject(1);
        await p.settle();
        expect(m.bValid.value.toBool(), isTrue, reason: 'B shown');
        m.awValid.inject(1);
        m.awAddr.inject(0x2000);
        await p.step();
        m.awValid.inject(0);
        for (var c = 0; c < 4; c++) {
          await p.settle();
          expect(
            m.bValid.value.toBool(),
            isTrue,
            reason: 'BVALID fell with no handshake',
          );
          await p.step();
        }
        m.bReady.inject(1);
        await p.step();
        s.bValid.inject(0);
        m.bReady.inject(0);
      },
    );

    test('a WRAP burst covers its wrap block', () async {
      final (p, _) = await start();
      await aw(p, 0x2068, 7, 3, 2);
      await p.steps(4);
      expect(p.lines, [0x2040, 0x2060]);
    });

    test('long AWs back to back stall AWREADY and lose no line', () async {
      final (p, tap) = await start(awDepth: 2);
      tap.invalReadyIn.inject(0);
      // Four AWs of 16 lines each while the next stage takes nothing.
      m.awValid.inject(1);
      m.awLen.inject(63);
      m.awSize.inject(3);
      m.awBurst.inject(1);
      s.awReady.inject(1);
      var taken = 0;
      var stalled = 0;
      for (var c = 0; c < 400 && taken < 4; c++) {
        m.awAddr.inject(0x10000 + taken * 0x1000);
        if (c == 20) tap.invalReadyIn.inject(1);
        await p.settle();
        final t = m.awReady.value.toBool();
        if (!t) stalled++;
        await p.step();
        if (t) taken++;
      }
      m.awValid.inject(0);
      await p.steps(80);
      expect(taken, 4);
      expect(stalled, greaterThan(0));
      expect(p.lines, [
        for (var w = 0; w < 4; w++)
          for (var l = 0; l < 16; l++) 0x10000 + w * 0x1000 + l * 32,
      ]);
    });
  });

  group('Wishbone', () {
    test('the last ack waits for the lines and quiet', () async {
      final m = WishboneInterface(
        const WishboneConfig(addressWidth: 32, dataWidth: 64, useCti: true),
      );
      final s = WishboneInterface(
        const WishboneConfig(addressWidth: 32, dataWidth: 64, useCti: true),
      );
      _zero(m, s);
      final (p, tap) = await _start(
        (clk, reset) => HarborDmaSnoop.wishbone(
          clk,
          reset,
          master: m,
          slave: s,
          lineSize: 32,
        ),
      );
      tap.invalQuietIn.inject(0);
      var acks = 0;
      p.clk.negedge.listen((_) {
        if (m.ack.value.toBool()) acks++;
      });
      m.cyc.inject(1);
      m.we.inject(1);
      m.stb.inject(1);
      // Six beats from 0x6010, posted by the slave: the last one is held.
      for (var b = 0; b < 6; b++) {
        m.adr.inject(0x6010 + 8 * b);
        m.cti!.inject(b == 5 ? 7 : 2);
        await p.settle();
        s.ack.inject(s.stb.value.toBool() ? 1 : 0);
        await p.step();
      }
      s.ack.inject(0);
      await p.steps(4);
      // The posted beats are acknowledged, the last one is held.
      final before = acks;
      await p.steps(4);
      expect(acks, before, reason: 'held until quiet');
      tap.invalQuietIn.inject(1);
      await p.steps(4);
      expect(acks, before + 1);
      expect(p.lines, [0x6000, 0x6020]);
    });
  });

  group('TileLink', () {
    test('the AccessAck waits for the lines', () async {
      const cfg = TileLinkConfig(addressWidth: 32, dataWidth: 64, sizeWidth: 4);
      final m = TileLinkInterface(cfg);
      final s = TileLinkInterface(cfg);
      _zero(m, s);
      final (p, tap) = await _start(
        (clk, reset) => HarborDmaSnoop.tileLink(
          clk,
          reset,
          master: m,
          slave: s,
          lineSize: 32,
        ),
      );
      tap.invalQuietIn.inject(0);
      // PutFullData of 64 bytes: 8 beats.
      m.aValid.inject(1);
      s.aReady.inject(1);
      m.aOpcode.inject(0);
      m.aSize.inject(6);
      m.aAddress.inject(0x7040);
      await p.steps(8);
      // A Get is not a write.
      m.aOpcode.inject(4);
      m.aSize.inject(3);
      m.aAddress.inject(0x9000);
      await p.step();
      m.aValid.inject(0);
      s.dValid.inject(1);
      s.dOpcode.inject(0);
      m.dReady.inject(1);
      await p.steps(3);
      await p.settle();
      expect(m.dValid.value.toBool(), isFalse, reason: 'held until quiet');
      tap.invalQuietIn.inject(1);
      await p.step();
      await p.settle();
      expect(m.dValid.value.toBool(), isTrue);
      expect(p.lines, [0x7040, 0x7060]);
    });

    test(
      'an AccessAck stays shown until D_READY, also after a new Put',
      () async {
        const cfg = TileLinkConfig(
          addressWidth: 32,
          dataWidth: 64,
          sizeWidth: 4,
        );
        final m = TileLinkInterface(cfg);
        final s = TileLinkInterface(cfg);
        _zero(m, s);
        final (p, _) = await _start(
          (clk, reset) => HarborDmaSnoop.tileLink(
            clk,
            reset,
            master: m,
            slave: s,
            lineSize: 32,
          ),
        );
        Future<void> put(int addr) async {
          m.aValid.inject(1);
          s.aReady.inject(1);
          m.aOpcode.inject(0);
          m.aSize.inject(3);
          m.aAddress.inject(addr);
          await p.step();
          m.aValid.inject(0);
        }

        await put(0x7000);
        await p.steps(4);
        s.dValid.inject(1);
        s.dOpcode.inject(0);
        await p.settle();
        expect(m.dValid.value.toBool(), isTrue, reason: 'AccessAck shown');
        await put(0x8000);
        for (var c = 0; c < 4; c++) {
          await p.settle();
          expect(
            m.dValid.value.toBool(),
            isTrue,
            reason: 'D_VALID fell with no handshake',
          );
          await p.step();
        }
        m.dReady.inject(1);
        await p.step();
        s.dValid.inject(0);
      },
    );
  });

  group('merge', () {
    WishboneInterface wb() => WishboneInterface(
      const WishboneConfig(addressWidth: 32, dataWidth: 64),
    );

    test('needs one line size and a rate it can keep up with', () {
      final clk = Logic();
      final reset = Logic();
      HarborDmaSnoop tap(int line) => HarborDmaSnoop.wishbone(
        clk,
        reset,
        master: wb(),
        slave: wb(),
        lineSize: line,
      );
      expect(
        () => HarborDmaSnoopMerge(clk, reset, [
          tap(16),
          tap(32),
        ], addressWidth: 32),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () =>
            HarborDmaSnoopMerge(clk, reset, [tap(8), tap(8)], addressWidth: 32),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('dma_snoop'),
          ),
        ),
      );
    });
  });
}
