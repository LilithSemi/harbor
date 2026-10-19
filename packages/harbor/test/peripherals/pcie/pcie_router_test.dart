import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/pcie_host_model.dart';

const _completerId = 0x0300;

/// A router with a driver and a sink on every port.
class _Bench {
  final Logic clk;
  final Logic reset;
  final HarborPcieStream upRx;
  final HarborPcieStream upTx;
  final HarborPcieRouter router;
  final PcieStreamDriver upDriver;
  final PcieStreamSink upSink;
  final Map<String, PcieStreamSink> clientSinks;
  final Map<String, PcieStreamDriver> clientDrivers;

  _Bench._(
    this.clk,
    this.reset,
    this.upRx,
    this.upTx,
    this.router,
    this.upDriver,
    this.upSink,
    this.clientSinks,
    this.clientDrivers,
  );

  static Future<_Bench> create({
    required int width,
    required List<(String, int, bool)> clients,
    double gapChance = 0.3,
    double readyChance = 0.6,
    int seed = 1,
  }) async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final completerId = Logic(name: 'completer_id', width: 16);
    final upRx = HarborPcieStream(width: width, name: 'up_rx');
    final upTx = HarborPcieStream(width: width, name: 'up_tx');
    final descriptors = [
      for (final (name, mask, takes) in clients)
        HarborPcieRouterClient(
          name: name,
          barMask: mask,
          takesCompletions: takes,
          rx: HarborPcieStream(width: width, name: '${name}_rx'),
          tx: HarborPcieStream(width: width, name: '${name}_tx'),
        ),
    ];
    final router = HarborPcieRouter(
      clk: clk,
      reset: reset,
      width: width,
      completerId: completerId,
      upstreamRx: upRx,
      upstreamTx: upTx,
      clients: descriptors,
    );
    await router.build();
    completerId.inject(_completerId);
    final upDriver = PcieStreamDriver(
      clk: clk,
      stream: upRx,
      seed: seed,
      gapChance: gapChance,
    );
    final upSink = PcieStreamSink(
      clk: clk,
      stream: upTx,
      seed: seed + 1,
      readyChance: readyChance,
    );
    final sinks = <String, PcieStreamSink>{};
    final drivers = <String, PcieStreamDriver>{};
    var next = seed + 10;
    for (final c in descriptors) {
      sinks[c.name] = PcieStreamSink(
        clk: clk,
        stream: c.rx,
        seed: next++,
        readyChance: readyChance,
      );
      drivers[c.name] = PcieStreamDriver(
        clk: clk,
        stream: c.tx,
        seed: next++,
        gapChance: gapChance,
      );
    }
    reset.inject(1);
    return _Bench._(
      clk,
      reset,
      upRx,
      upTx,
      router,
      upDriver,
      upSink,
      sinks,
      drivers,
    );
  }

  Future<void> start() async {
    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    for (var i = 0; i < 3; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    await clk.nextPosedge;
    upSink.start();
    for (final s in clientSinks.values) {
      s.start();
    }
  }

  Future<void> idle(int cycles) async {
    for (var i = 0; i < cycles; i++) {
      await clk.nextPosedge;
    }
  }

  Future<void> finish() async {
    upSink.stop();
    for (final s in clientSinks.values) {
      s.stop();
    }
    await clk.nextPosedge;
    await Simulator.endSimulation();
  }
}

const _bar0 = HarborPcieStream.userBar0;
const _bar2 = HarborPcieStream.userBar2;
const _rom = HarborPcieStream.userRom;

const _allClients = [
  ('dma', _bar0, true),
  ('mem', _bar2, false),
  ('rom', _rom, false),
];

Uint8List _bytes(Random random, int count) =>
    Uint8List.fromList([for (var i = 0; i < count; i++) random.nextInt(256)]);

List<List<int>> _dwords(Iterable<PcieTlp> tlps) => [
  for (final t in tlps) t.wireDwords(),
];

void main() {
  tearDown(() async => Simulator.reset());

  for (final width in [64, 128]) {
    group('W$width router', () {
      test('routes by BAR and completion type', () async {
        final bench = await _Bench.create(width: width, clients: _allClients);
        await bench.start();
        final random = Random(5);
        final toDma = <PcieTlp>[];
        final toMem = <PcieTlp>[];
        final toRom = <PcieTlp>[];

        Future<void> send(PcieTlp tlp, int user, List<PcieTlp> into) async {
          into.add(tlp);
          await bench.upDriver.send(tlp, user: user);
        }

        await send(
          PcieTlp.memWrite(address: 0x40, data: _bytes(random, 4)),
          _bar0,
          toDma,
        );
        await send(
          PcieTlp.memRead(address: 0x1000, lengthDw: 8, tag: 3),
          _bar2,
          toMem,
        );
        await send(
          PcieTlp.memWrite(address: 0x2000, data: _bytes(random, 40), tag: 4),
          _bar2,
          toMem,
        );
        await send(
          PcieTlp.memRead(address: 0x10, lengthDw: 1, tag: 5),
          _rom,
          toRom,
        );
        await send(
          PcieTlp.completion(
            completerId: 0x0100,
            requesterId: _completerId,
            tag: 6,
            byteCount: 16,
            data: _bytes(random, 16),
          ),
          0,
          toDma,
        );
        await send(
          PcieTlp.completion(
            completerId: 0x0100,
            requesterId: _completerId,
            tag: 7,
            status: PcieCplStatus.abort,
          ),
          _bar2,
          toDma,
        );
        await send(
          PcieTlp.memWrite(address: 0x80, data: _bytes(random, 64), tag: 8),
          _bar0,
          toDma,
        );
        await bench.clientSinks['dma']!.waitFor(toDma.length);
        await bench.clientSinks['mem']!.waitFor(toMem.length);
        await bench.clientSinks['rom']!.waitFor(toRom.length);
        await bench.idle(50);
        final dma = bench.clientSinks['dma']!;
        final mem = bench.clientSinks['mem']!;
        final rom = bench.clientSinks['rom']!;
        expect(_dwords(dma.received), _dwords(toDma));
        expect(_dwords(mem.received), _dwords(toMem));
        expect(_dwords(rom.received), _dwords(toRom));
        expect(mem.receivedUsers, everyElement(_bar2));
        expect(rom.receivedUsers, everyElement(_rom));
        expect(bench.upSink.received, isEmpty);
        await bench.finish();
      });

      test('answers an unclaimed read with an Unsupported Request', () async {
        final bench = await _Bench.create(
          width: width,
          clients: [_allClients[0], _allClients[1]],
        );
        await bench.start();
        final requests = [
          PcieTlp.memRead(
            address: 0x100,
            lengthDw: 1,
            requesterId: 0x0208,
            tag: 0x2a,
          ),
          PcieTlp.memRead(
            address: 0x1_0000_0000,
            lengthDw: 64,
            requesterId: 0x1234,
            tag: 0xf1,
          ),
        ];
        for (final request in requests) {
          await bench.upDriver.send(request, user: _rom);
        }
        await bench.upSink.waitFor(requests.length);
        await bench.idle(20);
        expect(bench.upSink.received, hasLength(requests.length));
        for (var i = 0; i < requests.length; i++) {
          final cpl = bench.upSink.received[i];
          expect(cpl.kind, PcieTlpKind.cpl);
          expect(cpl.status, PcieCplStatus.unsupported);
          expect(cpl.byteCount, 4);
          expect(cpl.lowerAddress, 0);
          expect(cpl.lengthDw, 0);
          expect(cpl.completerId, _completerId);
          expect(cpl.requesterId, requests[i].requesterId);
          expect(cpl.tag, requests[i].tag);
        }
        expect(bench.clientSinks['dma']!.received, isEmpty);
        expect(bench.clientSinks['mem']!.received, isEmpty);
        await bench.finish();
      });

      test('drops unclaimed posted packets and stray completions', () async {
        final bench = await _Bench.create(
          width: width,
          clients: [_allClients[1], _allClients[2]],
        );
        await bench.start();
        final random = Random(6);
        await bench.upDriver.send(
          PcieTlp.memWrite(address: 0x40, data: _bytes(random, 36)),
          user: _bar0,
        );
        await bench.upDriver.send(
          PcieTlp.completion(
            completerId: 1,
            requesterId: _completerId,
            tag: 1,
            byteCount: 8,
            data: _bytes(random, 8),
          ),
          user: 0,
        );
        final kept = PcieTlp.memWrite(address: 0x80, data: _bytes(random, 12));
        await bench.upDriver.send(kept, user: _bar2);
        await bench.clientSinks['mem']!.waitFor(1);
        await bench.idle(50);
        expect(_dwords(bench.clientSinks['mem']!.received), [
          kept.wireDwords(),
        ]);
        expect(bench.clientSinks['rom']!.received, isEmpty);
        expect(bench.upSink.received, isEmpty);
        await bench.finish();
      });

      test('keeps packets whole with three clients sending at once', () async {
        final bench = await _Bench.create(
          width: width,
          clients: _allClients,
          gapChance: 0,
          readyChance: 1,
        );
        await bench.start();
        final random = Random(7);
        final sent = {
          for (final (name, _, _) in _allClients)
            name: [
              for (var i = 0; i < 6; i++)
                PcieTlp.memWrite(
                  address: 0x1000 + i * 0x100,
                  data: _bytes(random, 64 + 16 * i),
                  tag: i,
                  requesterId: 0x1000 + _clientIndex(name),
                ),
            ],
        };
        await Future.wait([
          for (final entry in sent.entries)
            () async {
              for (final tlp in entry.value) {
                await bench.clientDrivers[entry.key]!.send(tlp);
              }
            }(),
        ]);
        final total = sent.values.fold<int>(0, (a, b) => a + b.length);
        await bench.upSink.waitFor(total);
        await bench.idle(20);
        expect(bench.upSink.received, hasLength(total));
        for (final entry in sent.entries) {
          final got = bench.upSink.received.where(
            (t) => t.requesterId == 0x1000 + _clientIndex(entry.key),
          );
          expect(_dwords(got), _dwords(entry.value), reason: entry.key);
        }
        await bench.finish();
      });

      for (final seed in [1, 2, 3]) {
        test(
          'runs mixed traffic under random backpressure, seed $seed',
          () async {
            final bench = await _Bench.create(
              width: width,
              clients: [_allClients[0], _allClients[1]],
              seed: seed * 100,
              gapChance: 0.4,
              readyChance: 0.4,
            );
            await bench.start();
            final random = Random(seed);
            final toDma = <PcieTlp>[];
            final toMem = <PcieTlp>[];
            final urRequests = <PcieTlp>[];
            final upstream = (() async {
              for (var i = 0; i < 30; i++) {
                final pick = random.nextInt(5);
                final PcieTlp tlp;
                final int user;
                switch (pick) {
                  case 0:
                    tlp = PcieTlp.memWrite(
                      address: i * 0x40,
                      data: _bytes(random, 4 * (1 + random.nextInt(20))),
                      tag: i,
                    );
                    user = _bar0;
                    toDma.add(tlp);
                  case 1:
                    tlp = PcieTlp.memRead(
                      address: i * 0x40,
                      lengthDw: 1 + random.nextInt(16),
                      tag: i,
                    );
                    user = _bar2;
                    toMem.add(tlp);
                  case 2:
                    tlp = PcieTlp.completion(
                      completerId: 5,
                      requesterId: _completerId,
                      tag: i,
                      byteCount: 8,
                      data: _bytes(random, 8),
                    );
                    user = 0;
                    toDma.add(tlp);
                  case 3:
                    tlp = PcieTlp.memRead(
                      address: i * 0x40,
                      lengthDw: 1 + random.nextInt(4),
                      requesterId: 0x0400 + i,
                      tag: i,
                    );
                    user = _rom;
                    urRequests.add(tlp);
                  default:
                    tlp = PcieTlp.memWrite(
                      address: i * 0x40,
                      data: _bytes(random, 8),
                      tag: i,
                    );
                    user = _rom;
                }
                await bench.upDriver.send(tlp, user: user);
              }
            })();
            final fromClients = <String, List<PcieTlp>>{'dma': [], 'mem': []};
            final clientsDone = Future.wait([
              for (final name in fromClients.keys)
                () async {
                  for (var i = 0; i < 12; i++) {
                    final tlp = i.isEven
                        ? PcieTlp.memWrite(
                            address: 0x8000 + i * 0x40,
                            data: _bytes(random, 4 * (1 + random.nextInt(24))),
                            tag: i,
                            requesterId: 0x1000 + _clientIndex(name),
                          )
                        : PcieTlp.completion(
                            completerId: _completerId,
                            requesterId: 0x1000 + _clientIndex(name),
                            tag: i,
                            byteCount: 4,
                            data: _bytes(random, 4),
                          );
                    fromClients[name]!.add(tlp);
                    await bench.clientDrivers[name]!.send(tlp);
                  }
                }(),
            ]);
            await Future.wait([upstream, clientsDone]);
            final expectedUp = 24 + urRequests.length;
            await bench.upSink.waitFor(expectedUp);
            await bench.clientSinks['dma']!.waitFor(toDma.length);
            await bench.clientSinks['mem']!.waitFor(toMem.length);
            await bench.idle(100);

            expect(
              _dwords(bench.clientSinks['dma']!.received),
              _dwords(toDma),
              reason: 'seed $seed',
            );
            expect(
              _dwords(bench.clientSinks['mem']!.received),
              _dwords(toMem),
              reason: 'seed $seed',
            );
            final up = bench.upSink.received;
            expect(up, hasLength(expectedUp), reason: 'seed $seed');
            final urs = up.where((t) => t.status != PcieCplStatus.success);
            expect(urs.map((t) => t.tag).toList(), [
              for (final r in urRequests) r.tag,
            ]);
            for (final name in fromClients.keys) {
              final got = up.where(
                (t) => t.requesterId == 0x1000 + _clientIndex(name),
              );
              expect(
                _dwords(got),
                _dwords(fromClients[name]!),
                reason: '$name seed $seed',
              );
            }
            await bench.finish();
          },
        );
      }
    });
  }

  group('constructor checks', () {
    HarborPcieRouter build(List<(String, int, bool)> clients) {
      final streams = [
        for (final (name, mask, takes) in clients)
          HarborPcieRouterClient(
            name: name,
            barMask: mask,
            takesCompletions: takes,
            rx: HarborPcieStream(width: 64, name: '${name}_rx'),
            tx: HarborPcieStream(width: 64, name: '${name}_tx'),
          ),
      ];
      return HarborPcieRouter(
        clk: Logic(),
        reset: Logic(),
        width: 64,
        completerId: Logic(width: 16),
        upstreamRx: HarborPcieStream(width: 64, name: 'u_rx'),
        upstreamTx: HarborPcieStream(width: 64, name: 'u_tx'),
        clients: streams,
      );
    }

    test('rejects overlapping masks', () {
      expect(
        () => build([('a', _bar0 | _bar2, false), ('b', _bar2, false)]),
        throwsArgumentError,
      );
    });

    test('rejects two completion takers', () {
      expect(
        () => build([('a', _bar0, true), ('b', _bar2, true)]),
        throwsArgumentError,
      );
    });

    test('rejects a mask outside the BAR bits', () {
      expect(() => build([('a', 1, false)]), throwsArgumentError);
    });

    test('names the definition by width and clients', () {
      final router = build(_allClients);
      expect(router.definitionName, contains('W64'));
      expect(router.definitionName, contains('dma_4c'));
      expect(router.definitionName, contains('rom_100n'));
    });
  });
}

int _clientIndex(String name) => _allClients.indexWhere((c) => c.$1 == name);
