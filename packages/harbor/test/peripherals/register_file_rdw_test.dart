import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// One cycle of inputs for a single-write register file.
class _Cycle {
  final bool reset;
  final bool wrEn;
  final int wrAddr;
  final int wrData;
  final List<int> rdAddrs;

  const _Cycle(
    this.rdAddrs, {
    this.reset = false,
    this.wrEn = false,
    this.wrAddr = 0,
    this.wrData = 0,
  });
}

_Cycle _w(int addr, int data, List<int> rd) =>
    _Cycle(rd, wrEn: true, wrAddr: addr, wrData: data);

_Cycle _r(List<int> rd) => _Cycle(rd);

_Cycle _rst(List<int> rd) => _Cycle(rd, reset: true);

_Cycle _rstW(int addr, int data, List<int> rd) =>
    _Cycle(rd, reset: true, wrEn: true, wrAddr: addr, wrData: data);

/// Runs [cycles] on [rf] and returns the read data of each port in each
/// cycle, sampled just before the rising edge that ends the cycle.
Future<List<List<int?>>> _trace(
  HarborRegisterFile rf,
  List<_Cycle> cycles, {
  List<int?>? readyOut,
}) async {
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final wrEn = Logic(name: 'wr_en');
  final wrAddr = Logic(name: 'wr_addr', width: rf.addrWidth);
  final wrData = Logic(name: 'wr_data', width: rf.dataWidth);
  final rdAddrs = [
    for (var r = 0; r < rf.numReadPorts; r++)
      Logic(name: 'rd${r}_addr', width: rf.addrWidth),
  ];
  rf.input('clk').srcConnection! <= clk;
  rf.input('reset').srcConnection! <= reset;
  rf.input('wr_en').srcConnection! <= wrEn;
  rf.input('wr_addr').srcConnection! <= wrAddr;
  rf.input('wr_data').srcConnection! <= wrData;
  for (var r = 0; r < rf.numReadPorts; r++) {
    rf.input('rd${r}_addr').srcConnection! <= rdAddrs[r];
  }
  await rf.build();

  // The testbench flops hold the value each port had before the edge.
  final caps = [
    for (var r = 0; r < rf.numReadPorts; r++)
      Logic(name: 'cap_$r', width: rf.dataWidth),
  ];
  Sequential(clk, [
    for (var r = 0; r < rf.numReadPorts; r++) caps[r] < rf.readData(r),
  ]);

  void apply(_Cycle c) {
    reset.inject(c.reset ? 1 : 0);
    wrEn.inject(c.wrEn ? 1 : 0);
    wrAddr.inject(c.wrAddr);
    wrData.inject(c.wrData);
    for (var r = 0; r < rf.numReadPorts; r++) {
      rdAddrs[r].inject(c.rdAddrs[r]);
    }
  }

  apply(cycles.first);
  Simulator.setMaxSimTime(100000);
  unawaited(Simulator.run());

  // The clock rises at 5 and falls at 10, so each falling edge ends one cycle.
  final out = <List<int?>>[];
  for (var i = 0; i < cycles.length; i++) {
    await clk.nextNegedge;
    out.add([for (final c in caps) c.value.isValid ? c.value.toInt() : null]);
    final ready = rf.writeReady(0).value;
    readyOut?.add(ready.isValid ? ready.toInt() : null);
    if (i + 1 < cycles.length) apply(cycles[i + 1]);
  }
  await Simulator.endSimulation();
  return out;
}

/// Write-first model: a read of an entry in the same cycle as a write to it
/// gets the new data. The read data shows [latency] cycles after the address.
/// Returns null for cycles the model does not check.
List<List<int?>> _model(
  List<_Cycle> cycles, {
  required int numEntries,
  required int latency,
  required bool reservedZero,
  required bool resetClears,
}) {
  final mem = List<int>.filled(numEntries, 0);
  final now = <List<int?>>[];
  for (final c in cycles) {
    now.add([
      for (final a in c.rdAddrs)
        c.reset
            ? null
            : (reservedZero && a == 0)
            ? 0
            : (c.wrEn && c.wrAddr == a)
            ? c.wrData
            : mem[a],
    ]);
    if (c.reset) {
      if (resetClears) mem.fillRange(0, numEntries, 0);
    } else if (c.wrEn && !(reservedZero && c.wrAddr == 0)) {
      mem[c.wrAddr] = c.wrData;
    }
  }
  return [
    for (var i = 0; i < cycles.length; i++)
      i < latency
          ? [for (final _ in cycles[i].rdAddrs) null]
          : now[i - latency],
  ];
}

void _expectModel(
  List<List<int?>> got,
  List<List<int?>> want,
  List<_Cycle> cycles,
) {
  for (var i = 0; i < want.length; i++) {
    for (var r = 0; r < want[i].length; r++) {
      if (want[i][r] == null) continue;
      expect(
        got[i][r],
        want[i][r],
        reason:
            'cycle $i port $r: got ${got[i][r]?.toRadixString(16)}, '
            'want ${want[i][r]!.toRadixString(16)}',
      );
    }
  }
}

const _ecp5 = HarborFpgaTarget.ecp5(device: '25f', package: 'CABGA256');
const _ice40 = HarborFpgaTarget.ice40(device: 'up5k', package: 'sg48');
const _spartan7 = HarborFpgaTarget.spartan7(device: 's50', package: 'csga324');

/// Writes, then reads in the same cycle as a write to the same entry and to
/// another entry, on two ports. Then back-to-back writes, x0, and a reset.
final _cycles = <_Cycle>[
  _rst([0, 0]),
  _rst([0, 0]),
  _w(1, 0x111, [0, 0]),
  _w(2, 0x222, [1, 0]),
  _r([2, 1]),
  // Same entry on port 0, another entry on port 1.
  _w(3, 0x333, [3, 1]),
  // Read port 0 of a different entry than the write.
  _w(4, 0x444, [1, 2]),
  _r([4, 3]),
  // Back-to-back writes to one entry, read every cycle on both ports.
  _w(5, 0xA, [5, 5]),
  _w(5, 0xB, [5, 1]),
  _w(5, 0xC, [2, 5]),
  _r([5, 5]),
  // Both ports read the entry being written.
  _w(6, 0x666, [6, 6]),
  _r([6, 4]),
  // x0 stays zero, even in the cycle of a write to it.
  _w(0, 0xDEAD, [0, 0]),
  _r([0, 1]),
  // A write during reset is dropped.
  _rstW(1, 0xBAD, [1, 2]),
  _w(7, 0x777, [7, 7]),
  _w(8, 0x888, [7, 8]),
  _r([8, 7]),
  _r([1, 9]),
  _r([0, 0]),
];

Future<void> _checkPath({
  HarborDeviceTarget? target,
  int? forceReadLatency,
  bool resetClears = true,
  bool reservedZero = true,
}) async {
  final rf = HarborRegisterFile(
    numEntries: 32,
    dataWidth: 32,
    numReadPorts: 2,
    reservedZero: reservedZero,
    target: target,
    forceReadLatency: forceReadLatency,
  );
  final readyOut = <int?>[];
  final got = await _trace(rf, _cycles, readyOut: readyOut);
  final want = _model(
    _cycles,
    numEntries: 32,
    latency: rf.readLatency,
    reservedZero: reservedZero,
    resetClears: resetClears,
  );
  _expectModel(got, want, _cycles);
  for (var i = 0; i < _cycles.length; i++) {
    if (_cycles[i].reset) {
      expect(readyOut[i], 0, reason: 'wr_ready during reset at cycle $i');
    }
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('flop latency 0 reads the new data in a write cycle', () async {
    await _checkPath(forceReadLatency: 0);
  });

  test('flop latency 1 reads the new data in a write cycle', () async {
    await _checkPath(forceReadLatency: 1);
  });

  test('ECP5 block RAM reads the new data in a write cycle', () async {
    // Block RAM keeps its contents through reset.
    await _checkPath(target: _ecp5, resetClears: false);
  });

  test('ECP5 block RAM with entry 0 as storage', () async {
    await _checkPath(target: _ecp5, resetClears: false, reservedZero: false);
  });

  test('ECP5 and flop give the same trace', () async {
    // The reset in the middle is left out because only the flops clear on it.
    final cycles = [
      ..._cycles.take(2),
      ..._cycles.skip(2).where((c) => !c.reset),
    ];
    final ecp5 = await _trace(
      HarborRegisterFile(numReadPorts: 2, target: _ecp5),
      cycles,
    );
    await Simulator.reset();
    final flop = await _trace(
      HarborRegisterFile(numReadPorts: 2, forceReadLatency: 1),
      cycles,
    );
    expect(ecp5.skip(3).toList(), flop.skip(3).toList());
  });

  for (final depth in [0, 1]) {
    test('two write ports, buffer depth $depth: reads see both writes of '
        'the cycle', () async {
      final rf = HarborRegisterFile(
        numEntries: 32,
        dataWidth: 32,
        numWritePorts: 2,
        writeBufferDepth: depth,
      );
      final clk = SimpleClockGenerator(10).clk;
      Logic pin(String n, int v) {
        final l = Logic(name: n, width: rf.input(n).width)..inject(v);
        rf.input(n).srcConnection! <= l;
        return l;
      }

      rf.input('clk').srcConnection! <= clk;
      final reset = pin('reset', 1);
      final en0 = pin('wr0_en', 0);
      pin('wr0_addr', 2);
      pin('wr0_data', 0x11);
      final en1 = pin('wr1_en', 0);
      pin('wr1_addr', 4);
      pin('wr1_data', 0x22);
      pin('rd0_addr', 2);
      pin('rd1_addr', 4);
      await rf.build();
      final caps = [Logic(width: 32), Logic(width: 32)];
      Sequential(clk, [caps[0] < rf.readData(0), caps[1] < rf.readData(1)]);

      Simulator.setMaxSimTime(10000);
      unawaited(Simulator.run());
      await clk.nextNegedge;
      reset.inject(0);
      await clk.nextNegedge;
      en0.inject(1);
      en1.inject(1);
      await clk.nextNegedge;
      // With one bank the two writes collide: port 1 is buffered (depth 1)
      // or stalled (depth 0).
      final stalled = depth == 0;
      expect(caps[0].value.toInt(), 0x11);
      expect(caps[1].value.toInt(), stalled ? 0 : 0x22);
      await Simulator.endSimulation();
    });
  }

  test('two write ports with a buffer drop writes during reset', () async {
    final rf = HarborRegisterFile(
      numEntries: 32,
      dataWidth: 32,
      numWritePorts: 2,
      writeBufferDepth: 1,
    );
    final clk = SimpleClockGenerator(10).clk;
    Logic pin(String n, int v) {
      final l = Logic(name: n, width: rf.input(n).width)..inject(v);
      rf.input(n).srcConnection! <= l;
      return l;
    }

    rf.input('clk').srcConnection! <= clk;
    final reset = pin('reset', 1);
    pin('wr0_en', 1);
    pin('wr0_addr', 2);
    pin('wr0_data', 0x11);
    pin('wr1_en', 1);
    pin('wr1_addr', 4);
    pin('wr1_data', 0x22);
    pin('rd0_addr', 2);
    pin('rd1_addr', 4);
    await rf.build();
    final caps = [Logic(width: 32), Logic(width: 32)];
    Sequential(clk, [caps[0] < rf.readData(0), caps[1] < rf.readData(1)]);

    Simulator.setMaxSimTime(10000);
    unawaited(Simulator.run());
    await clk.nextNegedge;
    await clk.nextNegedge;
    // No forward of a write during reset.
    expect(caps[0].value.toInt(), 0);
    expect(caps[1].value.toInt(), 0);
    expect(rf.getData(LogicValue.ofInt(2, 5))!.toInt(), 0);
    expect(rf.getData(LogicValue.ofInt(4, 5))!.toInt(), 0);
    // wr0_ready / wr1_ready read 0 during reset, even though both ports are
    // requesting and neither one collides.
    expect(rf.writeReady(0).value.toInt(), 0);
    expect(rf.writeReady(1).value.toInt(), 0);
    reset.inject(0);
    await Simulator.endSimulation();
  });

  for (final (name, target, bad) in <(String, HarborDeviceTarget, int)>[
    ('ECP5', _ecp5, 0),
    ('Xilinx', _spartan7, 0),
    ('iCE40', _ice40, 1),
  ]) {
    test('$name block RAM rejects forceReadLatency $bad', () {
      final vendorName = (target as HarborFpgaTarget).vendor.name;
      expect(
        () => HarborRegisterFile(target: target, forceReadLatency: bad),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('forceReadLatency ($bad)'),
              contains('(${1 - bad})'),
              contains(vendorName),
              isNot(contains('Instance of')),
            ),
          ),
        ),
      );
    });

    test('$name block RAM takes its own latency as forceReadLatency', () {
      final rf = HarborRegisterFile(target: target, forceReadLatency: 1 - bad);
      expect(rf.readLatency, 1 - bad);
    });
  }

  test(
    'EBR multi-write rejection wins over a bad forceReadLatency',
    () {
      // numWritePorts=2 is both an unsupported EBR shape and a latency
      // mismatch (ECP5 EBR latency is 1). The unsupported-shape error is the
      // more useful one, so it must be the one thrown.
      expect(
        () => HarborRegisterFile(
          target: _ecp5,
          numWritePorts: 2,
          forceReadLatency: 0,
        ),
        throwsA(isA<UnimplementedError>()),
      );
    },
  );

  test('a Xilinx flop shape accepts any forceReadLatency', () {
    final rf = HarborRegisterFile(
      target: _spartan7,
      numWritePorts: 2,
      forceReadLatency: 1,
    );
    expect(rf.readLatency, 1);
  });

  test('every block RAM path has the read-during-write bypass', () async {
    // ECP5 is checked by the traces above, since its sim body gives X on the
    // port collision.
    const targets = <HarborDeviceTarget>[
      _ice40,
      _spartan7,
    ];
    for (final t in targets) {
      final rf = HarborRegisterFile(target: t);
      await rf.build();
      final sv = rf.generateSynth();
      expect(sv, contains('rfRdwHit_0'), reason: '$t');
      expect(sv, contains('rfRdwHit_1'), reason: '$t');
      await Simulator.reset();
    }
  });
}
