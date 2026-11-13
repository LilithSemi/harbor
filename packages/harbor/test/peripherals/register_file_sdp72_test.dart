import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _spartan7 = HarborFpgaTarget.spartan7(device: 's50', package: 'csga324');

class _Cycle {
  const _Cycle(
    this.rd, {
    this.reset = false,
    this.en = false,
    this.addr = 0,
    this.data = 0,
  });

  final int rd;
  final bool reset;
  final bool en;
  final int addr;
  final int data;
}

Future<List<int?>> _simTrace({
  required int width,
  required List<_Cycle> cycles,
}) async {
  final rf = HarborRegisterFile(
    numEntries: 8,
    dataWidth: width,
    numReadPorts: 1,
    reservedZero: true,
    forceReadLatency: 1,
  );
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final en = Logic(name: 'wr_en');
  final addr = Logic(name: 'wr_addr', width: rf.addrWidth);
  final data = Logic(name: 'wr_data', width: width);
  final rd = Logic(name: 'rd_addr', width: rf.addrWidth);
  rf.input('clk').srcConnection! <= clk;
  rf.input('reset').srcConnection! <= reset;
  rf.input('wr_en').srcConnection! <= en;
  rf.input('wr_addr').srcConnection! <= addr;
  rf.input('wr_data').srcConnection! <= data;
  rf.input('rd0_addr').srcConnection! <= rd;
  await rf.build();

  final captured = Logic(name: 'captured', width: width);
  Sequential(clk, [captured < rf.readData(0)]);
  void apply(_Cycle c) {
    reset.inject(c.reset ? 1 : 0);
    en.inject(c.en ? 1 : 0);
    addr.inject(c.addr);
    data.inject(c.data);
    rd.inject(c.rd);
  }

  apply(cycles.first);
  Simulator.setMaxSimTime(100000);
  unawaited(Simulator.run());
  final result = <int?>[];
  for (var i = 0; i < cycles.length; i++) {
    await clk.nextNegedge;
    result.add(captured.value.isValid ? captured.value.toInt() : null);
    if (i + 1 < cycles.length) apply(cycles[i + 1]);
  }
  await Simulator.endSimulation();
  return result;
}

List<int?> _model(List<_Cycle> cycles, {required int entries}) {
  final mem = List<int>.filled(entries, 0);
  final now = <int?>[];
  for (final c in cycles) {
    now.add(
      c.reset
          ? null
          : c.rd == 0
          ? 0
          : c.en && c.addr == c.rd
          ? c.data
          : mem[c.rd],
    );
    if (c.reset) {
      mem.fillRange(0, entries, 0);
    } else if (c.en && c.addr != 0) {
      mem[c.addr] = c.data;
    }
  }
  return [for (var i = 0; i < cycles.length; i++) i == 0 ? null : now[i - 1]];
}

void main() {
  tearDown(() async => Simulator.reset());

  test('opt-in SDP72 uses one 72-bit block per read replica', () async {
    final rf = HarborRegisterFile(
      numEntries: 32,
      dataWidth: 64,
      numReadPorts: 2,
      target: _spartan7,
      useXilinxSdp72: true,
    );
    expect(rf.readLatency, 1);
    await rf.build();
    final sv = rf.dumpSystemVerilog();
    expect(RegExp(r'RAMB36E1 #').allMatches(sv), hasLength(2));
    expect(sv, contains('.RAM_MODE("SDP")'));
    expect(sv, contains('.READ_WIDTH_A(72)'));
    expect(sv, contains('.WRITE_WIDTH_B(72)'));
    expect(sv, contains('.READ_WIDTH_B(0)'));
    expect(sv, contains('.WRITE_WIDTH_A(0)'));
    expect(sv, contains('.DOADO('));
    expect(sv, contains('.DOBDO('));
    expect(sv, contains('.DIADI('));
    expect(sv, contains('.DIBDI('));
    expect(sv, contains('.DIADI('));
    expect(sv, contains('.DIBDI('));
    expect(sv, contains('DOBDO, /* 63:32 */'));
    expect(sv, contains('DOADO  /* 31: 0 */'));
  });

  test('56-bit SDP72 write enables use seven byte lanes', () async {
    final rf = HarborRegisterFile(
      numEntries: 32,
      dataWidth: 56,
      numReadPorts: 1,
      target: _spartan7,
      useXilinxSdp72: true,
    );
    await rf.build();
    final sv = rf.dumpSystemVerilog();
    expect(RegExp(r'RAMB36E1 #').allMatches(sv), hasLength(1));
    expect(sv, contains("1'h0, /* 7 */"));
    expect(sv, contains('wrEnLive_0, /* 6 */'));
  });

  test(
    'latency-one simulation covers full writes, no-write cycles, forwarding, x0, reset',
    () async {
      final cycles = [
        const _Cycle(0, reset: true),
        const _Cycle(0, reset: true),
        const _Cycle(1, en: true, addr: 1, data: 0x123456789abcdef),
        const _Cycle(1),
        const _Cycle(3, en: true, addr: 3, data: 0x6543210fedcba98),
        const _Cycle(3),
        const _Cycle(0, en: true, addr: 0, data: 0x123456789abcdef),
        const _Cycle(0),
        const _Cycle(
          1,
          reset: true,
          en: true,
          addr: 1,
          data: 0x6543210fedcba98,
        ),
        const _Cycle(1),
      ];
      final got = await _simTrace(width: 64, cycles: cycles);
      final want = _model(cycles, entries: 8);
      for (var i = 0; i < cycles.length; i++) {
        if (want[i] != null) expect(got[i], want[i], reason: 'cycle $i');
      }
    },
  );

  test(
    'latency-one simulation handles a 56-bit word with an inactive top byte lane',
    () async {
      const cycles = [
        _Cycle(0, reset: true),
        _Cycle(0, reset: true),
        _Cycle(2, en: true, addr: 2, data: 0x00f123456789abcd),
        _Cycle(2),
        _Cycle(2, en: true, addr: 2, data: 0x001fedcba9876543),
        _Cycle(2),
      ];
      final got = await _simTrace(width: 56, cycles: cycles);
      final want = _model(cycles, entries: 8);
      for (var i = 0; i < cycles.length; i++) {
        if (want[i] != null) expect(got[i], want[i], reason: 'cycle $i');
      }
    },
  );
}
