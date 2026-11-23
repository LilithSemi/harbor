import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/pcie_completer_bench.dart';
import '../../util/pcie_host_model.dart';

void main() {
  tearDown(() async => Simulator.reset());

  group('memory timeout', () {
    const config = CompleterConfig(width: 64, dataWidth: 64);
    const limit = 64;

    Future<CompleterBench> start(CompleterConfig c, int seed) async {
      final bench = await CompleterBench.create(
        c,
        seed: seed,
        timeoutCycles: limit,
      );
      await bench.start();
      return bench;
    }

    Future<void> readBack(CompleterBench bench, int address, int tag) async {
      final tlp = PcieTlp.memRead(address: address, lengthDw: 8, tag: tag);
      final want = await bench.read(tlp);
      final first = bench.sink.received.length;
      await bench.sink.waitFor(first + 1);
      final got = bench.sink.received[first];
      expect(got.status, PcieCplStatus.success);
      expect(got.tag, tag);
      expect(got.data, want);
    }

    test('a silent slave drops a write and the block recovers', () async {
      final bench = await start(config, 31);
      final r = Random(31);
      bench.memory.writeLimit = 0;
      await bench.driver.send(
        PcieTlp.memWrite(address: 0xc0000200, data: randomBytes(r, 32)),
        user: HarborPcieStream.userBar2,
      );
      await bench.idle(limit * 3);
      expect(bench.timeoutErrors, 1);
      expect(bench.writeErrors, 1);
      bench.memory.writeLimit = null;
      await bench.write(
        PcieTlp.memWrite(address: 0xc0000300, data: randomBytes(r, 32)),
      );
      await readBack(bench, 0xc0000300, 1);
      expect(bench.timeoutErrors, 1);
      expect(bench.wedged, 0);
      await bench.finish();
    });

    for (final kind in HarborFabricKind.values) {
      test(
        'a long write that stalls in the data beats, ${kind.name}',
        () async {
          final bench = await start(
            CompleterConfig(dataWidth: 32, kind: kind),
            35,
          );
          final r = Random(35);
          bench.memory.writeLimit = 0;
          await bench.driver.send(
            PcieTlp.memWrite(address: 0xc0000200, data: randomBytes(r, 128)),
            user: HarborPcieStream.userBar2,
          );
          await bench.idle(limit * 3);
          expect(bench.timeoutErrors, 1);
          expect(bench.writeErrors, 1);
          expect(bench.wedged, 1);
          bench.memory.writeLimit = null;
          await bench.idle(limit * 8);
          expect(bench.wedged, 0);
          expect(bench.timeoutErrors, 1);
          final good = PcieTlp.memWrite(
            address: 0xc0000400,
            data: randomBytes(r, 64),
          );
          await bench.write(good);
          final flush = PcieTlp.memRead(address: 0xc0000400, lengthDw: 16);
          final want = await bench.read(flush);
          await bench.checkReads([(flush, want)], rcb: 64, maxPayload: 256);
          expect(bench.timeoutErrors, 1);
          // The port holds a few beats the completer already sent, and the
          // stalled beat lands. No drain beat after them writes a byte.
          final landed = switch (kind) {
            HarborFabricKind.wishbone => 12,
            HarborFabricKind.axi4 => 20,
            HarborFabricKind.tilelink => 36,
          };
          final first = bench.fabric(0xc0000200) + landed;
          bench.checkMemory(
            bench.span(0xc0000200, 128).where((a) => a >= first),
          );
          await bench.finish();
        },
      );
    }

    test('a stalled write beat holds its data across a timeout', () async {
      final bench = await start(
        CompleterConfig(dataWidth: 32, kind: HarborFabricKind.wishbone),
        39,
      );
      final r = Random(39);
      final dut = bench.top.subModules.firstWhere(
        (m) => m.name == 'pcie_memory_completer',
      );
      String? prev;
      var pending = false;
      var broken = 0;
      bench.clk.negedge.listen((_) {
        final stb = dut.output('memory_STB').value;
        if (!stb.isValid) return;
        final now =
            '${dut.output('memory_SEL').value} '
            '${dut.output('memory_DAT_MOSI').value}';
        if (pending && (!stb.toBool() || now != prev)) broken++;
        pending = stb.toBool() && !dut.input('memory_ACK').value.toBool();
        prev = now;
      });
      bench.memory.writeLimit = 1;
      await bench.driver.send(
        PcieTlp.memWrite(address: 0xc0000200, data: randomBytes(r, 128)),
        user: HarborPcieStream.userBar2,
      );
      await bench.idle(limit * 2 + 8);
      expect(bench.timeoutErrors, 1);
      await bench.driver.send(
        PcieTlp.memWrite(address: 0xc0000300, data: randomBytes(r, 64)),
        user: HarborPcieStream.userBar2,
      );
      await bench.idle(limit);
      bench.memory.writeLimit = null;
      await bench.idle(limit * 8);
      expect(broken, 0);
      expect(bench.wedged, 0);
      await bench.finish();
    });

    test('a request while the memory stays dead is answered at once', () async {
      final bench = await start(config, 36);
      final r = Random(36);
      bench.memory.writeLimit = 0;
      bench.memory.readLimit = 0;
      await bench.driver.send(
        PcieTlp.memWrite(address: 0xc0000200, data: randomBytes(r, 128)),
        user: HarborPcieStream.userBar2,
      );
      await bench.idle(limit * 3);
      expect(bench.wedged, 1);
      await bench.driver.send(
        PcieTlp.memWrite(address: 0xc0000300, data: randomBytes(r, 16)),
        user: HarborPcieStream.userBar2,
      );
      await bench.idle(limit ~/ 4);
      expect(bench.writeErrors, 2);
      final tlp = PcieTlp.memRead(address: 0xc0000100, lengthDw: 8, tag: 9);
      await bench.driver.send(tlp, user: HarborPcieStream.userBar2);
      await bench.idle(limit ~/ 4);
      expect(bench.sink.received.length, 1);
      expect(bench.sink.received.single.status, PcieCplStatus.abort);
      expect(bench.sink.received.single.tag, 9);
      expect(bench.timeoutErrors, 1);
      await bench.finish();
    });

    test('a silent slave gives a CA completion on a read', () async {
      final bench = await start(config, 32);
      bench.memory.readLimit = 0;
      final tlp = PcieTlp.memRead(address: 0xc0000100, lengthDw: 8, tag: 5);
      final want = await bench.read(tlp);
      await bench.checkReads(
        [(tlp, want)],
        rcb: 64,
        maxPayload: 256,
        aborted: {0},
      );
      expect(bench.sink.received.single.tag, 5);
      expect(bench.timeoutErrors, 1);
      expect(bench.writeErrors, 0);
      bench.memory.readLimit = null;
      await bench.idle(limit);
      await readBack(bench, 0xc0000140, 6);
      await bench.finish();
    });

    test('a read that stalls partway drains the tail', () async {
      final bench = await start(CompleterConfig(dataWidth: 32), 37);
      bench.memory.readLimit = 3;
      final tlp = PcieTlp.memRead(address: 0xc0000100, lengthDw: 16, tag: 3);
      await bench.driver.send(tlp, user: HarborPcieStream.userBar2);
      await bench.sink.waitFor(1);
      expect(bench.sink.received.single.status, PcieCplStatus.abort);
      expect(bench.sink.received.single.byteCount, 64);
      expect(bench.wedged, 1);
      expect(bench.timeoutErrors, 1);
      bench.memory.readLimit = null;
      await bench.idle(limit * 4);
      expect(bench.wedged, 0);
      await readBack(bench, 0xc0000800, 4);
      expect(bench.timeoutErrors, 1);
      await bench.finish();
    });

    test('a read that stalls in a later chunk gets SC then CA', () async {
      final bench = await start(config, 38);
      bench.memory.readLimit = 8;
      final tlp = PcieTlp.memRead(address: 0xc0000100, lengthDw: 32, tag: 7);
      await bench.driver.send(tlp, user: HarborPcieStream.userBar2);
      await bench.sink.waitFor(2);
      final [sc, ca] = bench.sink.received;
      expect(sc.status, PcieCplStatus.success);
      expect(sc.lengthDw, 16);
      expect(sc.byteCount, 128);
      expect(ca.status, PcieCplStatus.abort);
      expect(ca.byteCount, 64);
      expect(ca.lowerAddress, 0x40);
      expect(ca.tag, 7);
      await bench.finish();
    });

    test('a late write response is drained before the next write', () async {
      final bench = await start(config, 33);
      final r = Random(33);
      bench.memory.writeLimit = 0;
      await bench.driver.send(
        PcieTlp.memWrite(address: 0xc0000200, data: randomBytes(r, 8)),
        user: HarborPcieStream.userBar2,
      );
      await bench.idle(limit * 3);
      expect(bench.timeoutErrors, 1);
      await bench.driver.send(
        PcieTlp.memWrite(address: 0xc0000400, data: randomBytes(r, 8)),
        user: HarborPcieStream.userBar2,
      );
      await bench.idle(8);
      expect(bench.writeErrors, 2);
      bench.memory.writeLimit = null;
      await bench.idle(limit * 3);
      expect(bench.wedged, 0);
      await bench.write(
        PcieTlp.memWrite(address: 0xc0000400, data: randomBytes(r, 8)),
      );
      await readBack(bench, 0xc0000400, 2);
      expect(bench.timeoutErrors, 1);
      await bench.finish();
    });

    test('late responses after two timeouts are not taken', () async {
      final bench = await start(config, 39);
      final r = Random(39);
      for (var round = 0; round < 2; round++) {
        bench.memory.readLimit = bench.memory.readBeats;
        final tlp = PcieTlp.memRead(
          address: 0xc0000100,
          lengthDw: 16,
          tag: round,
        );
        await bench.driver.send(tlp, user: HarborPcieStream.userBar2);
        await bench.sink.waitFor(round + 1);
        expect(bench.sink.received.last.status, PcieCplStatus.abort);
        bench.memory.readLimit = null;
        await bench.idle(limit * 4);
        expect(bench.wedged, 0);
      }
      expect(bench.timeoutErrors, 2);
      await bench.write(
        PcieTlp.memWrite(address: 0xc0000300, data: randomBytes(r, 32)),
      );
      await readBack(bench, 0xc0000300, 5);
      expect(bench.timeoutErrors, 2);
      await bench.finish();
    });

    test('late read data is not taken for a later read', () async {
      final bench = await start(config, 34);
      bench.memory.readLimit = 0;
      final first = PcieTlp.memRead(address: 0xc0000100, lengthDw: 16, tag: 1);
      await bench.read(first);
      await bench.idle(limit * 3);
      expect(bench.timeoutErrors, 1);
      bench.memory.readLimit = null;
      await bench.idle(limit * 4);
      await readBack(bench, 0xc0000800, 2);
      expect(bench.timeoutErrors, 1);
      await bench.finish();
    });
  });
}
