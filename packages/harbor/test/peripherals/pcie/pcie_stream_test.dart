import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/pcie_host_model.dart';

/// Wraps a header capture and exposes every header helper as an output.
class _Probe extends Module {
  _Probe({
    required Logic clk,
    required Logic reset,
    required HarborPcieStream outer,
    required Logic readyIn,
  }) : super(name: 'probe', definitionName: 'PcieStreamProbe_W${outer.width}') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final rx = HarborPcieStream.addSink(this, outer);
    rx.ready <= addInput('ready_in', readyIn);
    final capture = HarborPcieHeaderCapture(clk: clk, reset: reset, stream: rx);
    final h = capture.header;
    for (final (name, signal) in [
      ('header_valid', capture.headerValid),
      ('payload_in_header_beat', capture.payloadInHeaderBeat),
      ('first_payload_dw', capture.firstPayloadDw),
      ('swapped_payload_dw', tlpSwapBytes(capture.firstPayloadDw)),
      ('fmt_type', tlpFmtType(h)),
      ('is_4dw', tlpIs4Dw(h)),
      ('has_data', tlpHasData(h)),
      ('poisoned', tlpPoisoned(h)),
      ('length', tlpLength(h)),
      ('requester_id', tlpRequesterId(h)),
      ('tag', tlpTag(h)),
      ('last_be', tlpLastBe(h)),
      ('first_be', tlpFirstBe(h)),
      ('address', tlpAddress(h)),
      ('completer_id', tlpCompleterId(h)),
      ('cpl_status', tlpCplStatus(h)),
      ('byte_count', tlpByteCount(h)),
      ('cpl_requester_id', tlpCplRequesterId(h)),
      ('cpl_tag', tlpCplTag(h)),
      ('lower_address', tlpLowerAddress(h)),
    ]) {
      addOutput(name, width: signal.width) <= signal;
    }
  }
}

/// Passes a stream from a sink side to a source side with no logic.
class _Wire extends Module {
  _Wire({required HarborPcieStream rx, required HarborPcieStream tx})
    : super(name: 'wire', definitionName: 'PcieStreamWire_W${rx.width}') {
    final inner = HarborPcieStream.addSink(this, rx);
    final outer = HarborPcieStream.addSource(this, tx);
    outer.data <= inner.data;
    outer.keep <= inner.keep;
    outer.last <= inner.last;
    outer.valid <= inner.valid;
    outer.user <= inner.user;
    inner.ready <= outer.ready;
  }
}

Uint8List _bytes(Random random, int count) =>
    Uint8List.fromList([for (var i = 0; i < count; i++) random.nextInt(256)]);

/// One TLP of every kind, with random fields.
List<PcieTlp> _everyKind(Random random) {
  int id() => random.nextInt(0x10000);
  int tag() => random.nextInt(256);
  int low() => random.nextInt(0x40000000) * 4;
  int high() => (1 + random.nextInt(0xff)) * 0x100000000 + low();
  return [
    PcieTlp.memRead(
      address: low(),
      lengthDw: 1,
      requesterId: id(),
      tag: tag(),
      firstBe: 0x9,
    ),
    PcieTlp.memRead(
      address: low(),
      lengthDw: 1024,
      requesterId: id(),
      tag: tag(),
    ),
    PcieTlp.memRead(
      address: high(),
      lengthDw: 17,
      requesterId: id(),
      tag: tag(),
      lastBe: 0x6,
    ),
    PcieTlp.memWrite(
      address: low(),
      data: _bytes(random, 4),
      requesterId: id(),
      tag: tag(),
      firstBe: 0x3,
    ),
    PcieTlp.memWrite(
      address: low(),
      data: _bytes(random, 36),
      requesterId: id(),
      tag: tag(),
      lastBe: 0xc,
    ),
    PcieTlp.memWrite(
      address: high(),
      data: _bytes(random, 8),
      requesterId: id(),
      tag: tag(),
      poisoned: true,
    ),
    PcieTlp.memWrite(
      address: high(),
      data: _bytes(random, 4),
      requesterId: id(),
      tag: tag(),
    ),
    for (final status in PcieCplStatus.values)
      PcieTlp.completion(
        completerId: id(),
        requesterId: id(),
        tag: tag(),
        status: status,
        byteCount: random.nextInt(4096),
        lowerAddress: random.nextInt(128),
      ),
    PcieTlp.completion(
      completerId: id(),
      requesterId: id(),
      tag: tag(),
      byteCount: 64,
      lowerAddress: 0x40,
      data: _bytes(random, 16),
    ),
    PcieTlp.completion(
      completerId: id(),
      requesterId: id(),
      tag: tag(),
      byteCount: 4096,
      data: _bytes(random, 8),
    ),
    PcieTlp.completion(
      completerId: id(),
      requesterId: id(),
      tag: tag(),
      byteCount: 4,
      lowerAddress: 0x7c,
      data: _bytes(random, 4),
      poisoned: true,
    ),
  ];
}

void main() {
  tearDown(() async => Simulator.reset());

  group('host model encoding', () {
    test('matches the stream the DMA parses today', () {
      final cpl = PcieTlp.completion(
        completerId: 0x0200,
        requesterId: 0,
        tag: 0x41,
        byteCount: 4,
        data: [0x44, 0x33, 0x22, 0x11],
      );
      expect(cpl.wireDwords(), [
        0x4a000001,
        0x02000004,
        0x00004100,
        0x44332211,
      ]);

      final write = PcieTlp.memWrite(
        address: 0x40,
        data: [0x78, 0x56, 0x34, 0x12],
        requesterId: 0x1234,
        firstBe: 0xf,
      );
      expect(write.wireDwords(), [0x40000001, 0x1234000f, 0x40, 0x78563412]);
    });

    for (final width in [64, 128]) {
      test('round trips every kind through W$width beats', () {
        for (final tlp in _everyKind(Random(width))) {
          final beats = tlp.toBeats(width);
          expect(beats.last.last, isTrue);
          expect(beats.where((b) => b.last), hasLength(1));
          expect(PcieTlp.fromBeats(beats).wireDwords(), tlp.wireDwords());
        }
      });
    }

    test('writes and decodes a byte count of 4096 as 0', () {
      final cpl = PcieTlp.completion(
        completerId: 1,
        requesterId: 2,
        tag: 3,
        byteCount: 4096,
        data: List.filled(64, 0),
      );
      expect(cpl.wireDwords()[1] & 0xfff, 0);
      expect(PcieTlp.fromDwords(cpl.wireDwords()).byteCount, 4096);
    });

    test('rejects lastBe on a 1 DW request', () {
      expect(
        () => PcieTlp.memRead(address: 0, lengthDw: 1, lastBe: 0xf),
        throwsArgumentError,
      );
    });

    test('decodes fields', () {
      final tlp = PcieTlp.fromDwords(
        PcieTlp.memRead(
          address: 0x1234567890,
          lengthDw: 1024,
          requesterId: 0xabcd,
          tag: 0x5a,
          lastBe: 0x7,
        ).wireDwords(),
      );
      expect(tlp.kind, PcieTlpKind.memRead64);
      expect(tlp.address, 0x1234567890);
      expect(tlp.lengthDw, 1024);
      expect(tlp.requesterId, 0xabcd);
      expect(tlp.tag, 0x5a);
      expect(tlp.lastBe, 0x7);
    });
  });

  group('host memory', () {
    test('reads zero where nothing was written and honors byte enables', () {
      final memory = PcieHostMemory();
      expect(memory.read(0x100, 4), [0, 0, 0, 0]);
      memory.applyWrite(
        PcieTlp.memWrite(
          address: 0x100,
          data: List.generate(12, (i) => i + 1),
          firstBe: 0xc,
          lastBe: 0x3,
        ),
      );
      expect(memory.read(0x100, 12), [0, 0, 3, 4, 5, 6, 7, 8, 9, 10, 0, 0]);
    });
  });

  group('read responder', () {
    PcieReadResponder make(int seed, {int rcb = 64, int maxPayload = 128}) {
      final memory = PcieHostMemory()
        ..write(0, List.generate(0x2000, (i) => (i * 7 + 3) & 0xff));
      return PcieReadResponder(
        memory: memory,
        seed: seed,
        completerId: 0x0100,
        rcb: rcb,
        maxPayload: maxPayload,
      );
    }

    for (final rcb in [64, 128]) {
      test('splits at RCB $rcb and keeps the data', () {
        final responder = make(3, rcb: rcb);
        final request = PcieTlp.memRead(
          address: 0x1010,
          lengthDw: 100,
          requesterId: 0x0200,
          tag: 9,
        );
        responder.accept(request);
        final chunks = <PcieTlp>[];
        for (var c = responder.next(); c != null; c = responder.next()) {
          chunks.add(c);
        }
        var address = 0x1010;
        for (final chunk in chunks) {
          expect(chunk.kind, PcieTlpKind.cplD);
          expect(chunk.tag, 9);
          expect(chunk.requesterId, 0x0200);
          expect(chunk.lowerAddress, address & 0x7f);
          expect(chunk.byteCount, 0x1010 + 400 - address);
          final end = chunk.data.length + address;
          expect(chunk.data, responder.memory.read(address, chunk.data.length));
          address = end;
        }
        expect(address, 0x1010 + 400);
      });
    }

    for (final (rcb, mps) in [(64, 128), (64, 256), (128, 128), (128, 256)]) {
      test('follows every split rule with RCB $rcb and MPS $mps', () {
        var sawLarge = false;
        var sawSmall = false;
        for (var seed = 0; seed < 12; seed++) {
          final responder = make(seed, rcb: rcb, maxPayload: mps);
          const begin = 0x1008;
          const total = 128 * 4;
          responder.accept(
            PcieTlp.memRead(address: begin, lengthDw: total ~/ 4, tag: 1),
          );
          final chunks = <PcieTlp>[];
          for (var c = responder.next(); c != null; c = responder.next()) {
            chunks.add(c);
          }
          var address = begin;
          for (var i = 0; i < chunks.length; i++) {
            final chunk = chunks[i];
            final size = chunk.data.length;
            final isLast = i == chunks.length - 1;
            expect(size, lessThanOrEqualTo(mps));
            expect(chunk.byteCount, begin + total - address);
            expect(chunk.lowerAddress, address & 0x7f);
            if (i == 0) {
              expect(
                address + size,
                (address ~/ rcb + 1) * rcb,
                reason: 'first chunk ends at the boundary',
              );
            } else {
              expect(address % rcb, 0);
              if (!isLast) expect(size % rcb, 0, reason: 'middle chunk');
            }
            if (i > 0 && !isLast) {
              sawLarge |= size > rcb;
              sawSmall |= size == rcb;
            }
            expect(chunk.data, responder.memory.read(address, size));
            address += size;
          }
          expect(address, begin + total);
        }
        expect(sawSmall, isTrue);
        expect(sawLarge, mps > rcb);
      });
    }

    test('rejects a maximum payload below RCB', () {
      expect(
        () => PcieReadResponder(
          memory: PcieHostMemory(),
          seed: 1,
          rcb: 128,
          maxPayload: 64,
        ),
        throwsArgumentError,
      );
    });

    test('answers reads in a seeded random order', () {
      List<int> order(int seed) {
        final responder = make(seed);
        for (var tag = 0; tag < 8; tag++) {
          responder.accept(
            PcieTlp.memRead(address: tag * 0x100, lengthDw: 32, tag: tag),
          );
        }
        final tags = <int>[];
        for (var c = responder.next(); c != null; c = responder.next()) {
          tags.add(c.tag);
        }
        return tags;
      }

      final first = order(11);
      expect(order(11), first);
      expect(order(12), isNot(first));
      expect(first.toSet(), {for (var i = 0; i < 8; i++) i});
      for (var tag = 0; tag < 8; tag++) {
        expect(first.where((t) => t == tag), hasLength(2));
      }
      expect(first, isNot(equals([...first]..sort())));
    });

    test('answers with a failure status in one completion', () {
      final responder = make(1)..statusFor = (_) => PcieCplStatus.abort;
      responder.accept(PcieTlp.memRead(address: 0x40, lengthDw: 64, tag: 5));
      final cpl = responder.next()!;
      expect(cpl.kind, PcieTlpKind.cpl);
      expect(cpl.status, PcieCplStatus.abort);
      expect(responder.next(), isNull);
    });

    test('host model flags rule breaks', () {
      final host = PcieHostModel(maxPayload: 128, maxReadRequest: 256)
        ..busMasterEnable = false;
      host.receive(PcieTlp.memWrite(address: 0xff0, data: List.filled(32, 0)));
      host.receive(PcieTlp.memRead(address: 0, lengthDw: 128));
      host.recordMsi(3);
      expect(host.violations, hasLength(5));
      expect(host.violations, [
        contains('without bus master'),
        contains('crosses a 4 KB boundary'),
        contains('without bus master'),
        contains('larger than the maximum read request'),
        'MSI 3 sent without bus master',
      ]);
    });
  });

  for (final width in [64, 128]) {
    group('W$width stream', () {
      test('header helpers match the host model for every kind', () async {
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic();
        final readyIn = Logic();
        final outer = HarborPcieStream(width: width, name: 'probe');
        final probe = _Probe(
          clk: clk,
          reset: reset,
          outer: outer,
          readyIn: readyIn,
        );
        await probe.build();

        final tlps = _everyKind(Random(100 + width));
        final driver = PcieStreamDriver(
          clk: clk,
          stream: outer,
          seed: 5,
          gapChance: 0.4,
        );
        reset.inject(1);
        readyIn.inject(0);
        Simulator.setMaxSimTime(5000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;

        final random = Random(6);
        final seen = <Map<String, BigInt>>[];
        var sending = true;
        var beatIndex = 0;
        final headerBeat = width == 64 ? 1 : 0;
        final wrongHeaderValid = <int>[];
        unawaited(() async {
          while (sending) {
            final ready = random.nextDouble() < 0.5;
            readyIn.inject(ready ? 1 : 0);
            await clk.nextNegedge;
            if (outer.valid.value.toBool()) {
              final high = probe.output('header_valid').value.toBool();
              if (high != (beatIndex == headerBeat)) {
                wrongHeaderValid.add(beatIndex);
              }
              if (ready)
                beatIndex = outer.last.value.toBool() ? 0 : beatIndex + 1;
            }
            if (ready &&
                outer.valid.value.toBool() &&
                probe.output('header_valid').value.toBool()) {
              seen.add({
                for (final entry in probe.outputs.entries)
                  entry.key: entry.value.value.isValid
                      ? entry.value.value.toBigInt()
                      : BigInt.from(-1),
              });
            }
            await clk.nextPosedge;
          }
        }());
        for (final tlp in tlps) {
          await driver.send(tlp);
        }
        await clk.nextPosedge;
        await clk.nextPosedge;
        sending = false;
        await clk.nextPosedge;
        await Simulator.endSimulation();

        expect(wrongHeaderValid, isEmpty);
        expect(seen, hasLength(tlps.length));
        for (var i = 0; i < tlps.length; i++) {
          final tlp = tlps[i];
          final got = seen[i];
          int field(String name) => got[name]!.toInt();
          final reason = 'TLP $i $tlp';
          expect(field('fmt_type'), tlp.kind.fmtType, reason: reason);
          expect(field('is_4dw'), tlp.kind.is4Dw ? 1 : 0, reason: reason);
          expect(field('has_data'), tlp.kind.hasData ? 1 : 0, reason: reason);
          expect(field('poisoned'), tlp.poisoned ? 1 : 0, reason: reason);
          final inHeader = tlp.kind.hasData && !tlp.kind.is4Dw;
          expect(
            field('payload_in_header_beat'),
            inHeader ? 1 : 0,
            reason: reason,
          );
          if (inHeader) {
            expect(
              field('first_payload_dw'),
              tlp.wireDwords()[3],
              reason: reason,
            );
            final d = tlp.data;
            expect(
              field('swapped_payload_dw'),
              d[0] | (d[1] << 8) | (d[2] << 16) | (d[3] << 24),
              reason: reason,
            );
          }
          if (tlp.kind.isRequest) {
            expect(field('length'), tlp.lengthDw & 0x3ff, reason: reason);
            expect(field('requester_id'), tlp.requesterId, reason: reason);
            expect(field('tag'), tlp.tag, reason: reason);
            expect(field('first_be'), tlp.firstBe, reason: reason);
            expect(field('last_be'), tlp.lastBe, reason: reason);
            expect(got['address'], BigInt.from(tlp.address), reason: reason);
          } else {
            expect(field('completer_id'), tlp.completerId, reason: reason);
            expect(field('cpl_status'), tlp.status.code, reason: reason);
            expect(field('byte_count'), tlp.byteCount & 0xfff, reason: reason);
            expect(field('cpl_requester_id'), tlp.requesterId, reason: reason);
            expect(field('cpl_tag'), tlp.tag, reason: reason);
            expect(field('lower_address'), tlp.lowerAddress, reason: reason);
          }
        }
      });

      test('model TLPs cross a module with backpressure', () async {
        final clk = SimpleClockGenerator(10).clk;
        final rx = HarborPcieStream(width: width, name: 'rx');
        final tx = HarborPcieStream(width: width, name: 'tx');
        final wire = _Wire(rx: rx, tx: tx);
        await wire.build();
        expect(wire.inputs.keys, contains('rx_data'));
        expect(wire.output('rx_ready').width, 1);
        expect(wire.input('tx_ready').width, 1);
        expect(wire.output('tx_keep').width, width ~/ 8);
        expect(wire.output('tx_user').width, 22);

        final host = PcieHostModel(seed: 2);
        final driver = PcieStreamDriver(
          clk: clk,
          stream: rx,
          seed: 7,
          gapChance: 0.4,
        );
        final sink = PcieStreamSink(
          clk: clk,
          stream: tx,
          seed: 8,
          readyChance: 0.5,
          onTlp: host.receive,
        );
        Simulator.setMaxSimTime(20000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        sink.start();

        final random = Random(9);
        final sent = [..._everyKind(random), ..._everyKind(random)]
          ..shuffle(random);
        final users = [
          HarborPcieStream.userBar0,
          HarborPcieStream.userBar2,
          HarborPcieStream.userRom,
        ];
        for (var i = 0; i < sent.length; i++) {
          await driver.send(sent[i], user: users[i % users.length]);
        }
        await sink.waitFor(sent.length);
        sink.stop();
        await clk.nextPosedge;
        await Simulator.endSimulation();

        expect(sink.received.map((t) => t.wireDwords()).toList(), [
          for (final tlp in sent) tlp.wireDwords(),
        ]);
        expect(sink.receivedUsers, [
          for (var i = 0; i < sent.length; i++) users[i % users.length],
        ]);
      });
    });
  }

  for (final width in [64, 128]) {
    test('register stage keeps every beat in order, W$width', () async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final up = HarborPcieStream(width: width, name: 'up');
      final down = HarborPcieStream(width: width, name: 'down');
      final stage = HarborPcieStreamRegister(
        clk: clk,
        reset: reset,
        upstream: up,
        downstream: down,
      );
      await stage.build();
      expect(stage.definitionName, 'HarborPcieStreamRegister_W$width');
      final driver = PcieStreamDriver(
        clk: clk,
        stream: up,
        seed: width,
        gapChance: 0.2,
      );
      final sink = PcieStreamSink(
        clk: clk,
        stream: down,
        seed: width + 1,
        readyChance: 0.5,
      );
      reset.inject(1);
      Simulator.setMaxSimTime(10000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
      sink.start();
      final random = Random(width);
      final sent = <PcieTlp>[];
      final users = <int>[];
      for (var i = 0; i < 60; i++) {
        final dw = 1 + random.nextInt(20);
        final tlp = PcieTlp.memWrite(
          address: 0x1000 * i,
          data: [for (var b = 0; b < dw * 4; b++) random.nextInt(256)],
        );
        final user = random.nextInt(1 << HarborPcieStream.userWidth);
        sent.add(tlp);
        users.add(user);
        await driver.send(tlp, user: user);
      }
      await sink.waitFor(sent.length);
      sink.stop();
      for (var i = 0; i < sent.length; i++) {
        expect(sink.received[i].wireDwords(), sent[i].wireDwords());
        expect(sink.receivedUsers[i], users[i]);
      }
      await Simulator.endSimulation();
    });
  }
}
