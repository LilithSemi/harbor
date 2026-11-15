import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';

import '../bus/port/memory_harness.dart';
import 'memory_port_bench.dart';
import 'sdram_memory_port_bench.dart';

/// The modules of [m] and everything under it.
Iterable<Module> moduleTree(Module m) sync* {
  yield m;
  for (final c in m.subModules) {
    yield* moduleTree(c);
  }
}

/// Definition names under [sdram] that belong to a clock crossing.
List<String> crossingModules(HarborSdram sdram) => [
  for (final m in moduleTree(sdram))
    if (RegExp('cdc|async', caseSensitive: false).hasMatch(m.definitionName) &&
        !m.definitionName.toLowerCase().contains('reset'))
      m.definitionName,
];

/// Builds a bench for the native [kind] port with a [dataWidth] bus, fills
/// the memory below `span`, runs [body] and returns the errors found. With
/// [sync] the sdram runs on the fabric clock.
Future<List<String>> sdramWidthRun(
  HarborFabricKind kind,
  int dataWidth,
  Future<void> Function(SdramPortBench bench, MemoryPortCheck check) body, {
  bool sync = false,
  HarborSdramAddressMap addressMap = HarborSdramAddressMap.rowBankCol,
  int seed = 1,
  int span = 0x2000,
}) async {
  final config = HarborMemoryWaistConfig(
    addressWidth: 26,
    dataWidth: dataWidth,
    idWidth: 2,
    outstanding: kind == HarborFabricKind.wishbone ? 1 : 8,
  );
  late MemoryPortCheck check;
  final bench = await SdramPortBench.start(
    kind,
    config,
    fabricPeriodPs: sync
        ? 8000
        : (kind == HarborFabricKind.wishbone ? 14000 : 20000),
    sync: sync,
    addressMap: addressMap,
    attach: (s) {
      check = MemoryPortCheck(
        s,
        Random(seed),
        busBytes: dataWidth ~/ 8,
        idWidth: config.idWidth,
        span: span,
        timeout: 4000000,
      );
    },
  );
  await check.fill();
  await body(bench, check);
  final bad = [
    ...check.errors,
    ...bench.model.errors.take(8),
    if (bench.sdram.busError.value.toInt() != 0) 'bus_error is set',
  ];
  await bench.stop();
  return bad;
}

Future<void> _drain(MemoryPortCheck check) => waitUntil(
  check.s,
  () => check.req.done && check.req.req.idleNow && check.req.wdata.idleNow,
  limit: check.timeout,
);

/// The reads from index [from] of [check] against its reference memory, for
/// full size beats.
List<String> _readErrors(MemoryPortCheck check, int from) {
  final bad = <String>[];
  final req = check.req;
  for (var k = from; k < req.reads.length; k++) {
    final x = req.reads[k];
    final addrs = beatAddrs(x.addr, x.len, x.size, x.burst);
    final got = req.readResp[k];
    if (got.length != x.beats) {
      bad.add('$x: ${got.length} beats');
      continue;
    }
    for (var i = 0; i < x.beats; i++) {
      final want = check.want.read(addrs[i]);
      final (id, data, err, last) = got[i];
      if (id != x.id ||
          data != want ||
          err != 0 ||
          (last == 1) != (i == x.len)) {
        bad.add(
          '$x beat $i at 0x${addrs[i].toRadixString(16)}: got '
          '(id $id, 0x${data.toRadixString(16)}, err $err, last $last) '
          'want 0x${want.toRadixString(16)}',
        );
        break;
      }
    }
    if (bad.length > 12) break;
  }
  return bad;
}

/// Every byte strobe pattern on a single beat write over a word that holds
/// other data, then reads the words back. A pattern with a whole 16-bit
/// half low gives an sdram word with all its dqm bits high.
Future<List<String>> sdramStrobePatterns(
  HarborFabricKind kind,
  int dataWidth, {
  bool sync = false,
}) => sdramWidthRun(kind, dataWidth, sync: sync, (bench, check) async {
  final bytes = check.busBytes;
  final size = bytes.bitLength - 1;
  final full = (1 << bytes) - 1;
  final rng = Random(5);
  int data() => bytes == 8
      ? (rng.nextInt(1 << 32) << 32) | rng.nextInt(1 << 32)
      : rng.nextInt(1 << 32);
  const base = 0x400;
  final req = check.req;
  for (final round in [0, 1]) {
    for (var p = 0; p <= full; p++) {
      final strb = round == 0 ? full : p;
      final value = data();
      final addr = base + p * bytes;
      req.send(
        Burst(
          id: 0,
          write: true,
          addr: addr,
          len: 0,
          size: size,
          burst: 1,
          data: [value],
          strb: [strb],
        ),
      );
      check.want.write(addr, value, strb);
    }
  }
  final from = req.reads.length;
  for (var p = 0; p <= full; p++) {
    req.send(
      Burst(
        id: 0,
        write: false,
        addr: base + p * bytes,
        len: 0,
        size: size,
        burst: 1,
      ),
    );
  }
  await _drain(check);
  check.errors.addAll(_readErrors(check, from));
});

/// INCR bursts that start before a 1 KiB boundary and end after it, which
/// is a bank change with the row, bank, column map and a row change with
/// the bank, row, column map. Also bursts that end at a 4 KiB boundary and
/// start at the next one, which change the row with either map.
Future<List<String>> sdramBoundaryBursts(
  HarborFabricKind kind,
  int dataWidth, {
  required HarborSdramAddressMap addressMap,
  bool sync = false,
}) => sdramWidthRun(kind, dataWidth, sync: sync, addressMap: addressMap, (
  bench,
  check,
) async {
  final bytes = check.busBytes;
  final size = bytes.bitLength - 1;
  final full = (1 << bytes) - 1;
  final rng = Random(6);
  int data() => bytes == 8
      ? (rng.nextInt(1 << 32) << 32) | rng.nextInt(1 << 32)
      : rng.nextInt(1 << 32);
  // (start, beats, random strobes)
  final shapes = <(int, int, bool)>[
    (0x400 - 8 * bytes, 32, false),
    (0x800 - 3 * bytes, 16, false),
    (0xc00 - 16 * bytes, 64, false),
    (0x1000 - 16 * bytes, 16, false),
    (0x1000, 32, false),
    (0x1000 - bytes, 1, false),
    (0x1400 - 5 * bytes, 21, false),
    (0x1800 - 40 * bytes, 80, true),
    (0x600 - 4 * bytes, 8, true),
  ];
  final req = check.req;
  final writes = <Burst>[];
  for (final (start, beats, partial) in shapes) {
    final b = Burst(
      id: 1,
      write: true,
      addr: start,
      len: beats - 1,
      size: size,
      burst: 1,
      data: [for (var i = 0; i < beats; i++) data()],
      strb: [
        for (var i = 0; i < beats; i++) partial ? rng.nextInt(full + 1) : full,
      ],
    );
    writes.add(b);
    req.send(b);
  }
  await _drain(check);
  for (final b in writes) {
    final addrs = beatAddrs(b.addr, b.len, b.size, b.burst);
    for (var i = 0; i < b.beats; i++) {
      check.want.write(addrs[i], b.data[i], b.strb[i]);
    }
  }
  final from = req.reads.length;
  for (final (start, beats, _) in shapes) {
    req.send(
      Burst(
        id: 1,
        write: false,
        addr: start,
        len: beats - 1,
        size: size,
        burst: 1,
      ),
    );
  }
  for (var a = 0; a < check.span; a += 256 * bytes) {
    req.send(
      Burst(id: 0, write: false, addr: a, len: 255, size: size, burst: 1),
    );
  }
  await _drain(check);
  check.errors.addAll(_readErrors(check, from));
});

/// The sdram commands on the pads for read bursts that stay inside one row
/// and for one that crosses into the next row or bank. Returns an error when
/// a burst takes more row activations than the rows it touches, with one
/// more for each refresh that ran inside it.
Future<List<String>> sdramRowCycles(
  HarborFabricKind kind,
  int dataWidth, {
  bool sync = false,
}) => sdramWidthRun(kind, dataWidth, sync: sync, (bench, check) async {
  final bytes = check.busBytes;
  final size = bytes.bitLength - 1;
  final top = bench.top;
  var acts = 0;
  var refs = 0;
  var reads = 0;
  bench.memClk.negedge.listen((_) {
    if (top.output('sdram_cs_n').value != LogicValue.zero) return;
    final ras = top.output('sdram_ras_n').value;
    final cas = top.output('sdram_cas_n').value;
    final we = top.output('sdram_we_n').value;
    if (ras == LogicValue.zero &&
        cas == LogicValue.one &&
        we == LogicValue.one) {
      acts++;
    } else if (ras == LogicValue.zero &&
        cas == LogicValue.zero &&
        we == LogicValue.one) {
      refs++;
    } else if (ras == LogicValue.one &&
        cas == LogicValue.zero &&
        we == LogicValue.one) {
      reads++;
    }
  });
  final cases = <(int, int, int)>[
    // start, beats, rows touched
    (0x800, 32, 1),
    (0x800, 1024 ~/ bytes, 1),
    (0x400 + 0x400 - 16 * bytes, 32, 2),
    (0x1000, 1024 ~/ bytes, 1),
  ];
  for (final (start, beats, rows) in cases) {
    acts = 0;
    refs = 0;
    reads = 0;
    check.req.send(
      Burst(
        id: 0,
        write: false,
        addr: start,
        len: beats - 1,
        size: size,
        burst: 1,
      ),
    );
    await _drain(check);
    await check.s.cycles(8);
    // One read command is one burst of 8 words, 16 bytes.
    final wantReads = beats * bytes ~/ 16;
    if (acts > rows + refs) {
      check.errors.add(
        '$beats beats at 0x${start.toRadixString(16)}: $acts activations '
        'for $rows rows and $refs refreshes',
      );
    }
    if (reads < wantReads || reads > wantReads + 1) {
      check.errors.add(
        '$beats beats at 0x${start.toRadixString(16)}: $reads read commands, '
        'want $wantReads',
      );
    }
  }
});
