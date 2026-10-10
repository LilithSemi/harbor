import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../integration/test_harness.dart';

/// One bus access the scripted master makes.
class _Op {
  final bool write;
  final int addr;
  final int data;
  final int sel;
  const _Op.read(this.addr) : write = false, data = 0, sel = 0xF;
  const _Op.write(this.addr, this.data, {this.sel = 0xF}) : write = true;
}

/// How the master moves from one access to the next.
enum _Mode {
  /// Registered master that drops STB for one cycle after each ACK.
  gap,

  /// Registered master that holds STB and shows the next access in the cycle
  /// after the ACK, the way a pipelined core does.
  held,

  /// Master that shows the next access in the ACK cycle itself.
  comb,
}

/// One cycle of the bus as the master sees it.
typedef _Cycle = ({bool stb, bool we, int adr, bool ack, int? dat});

/// Runs [ops] against [sram] and returns the bus trace, one entry per cycle
/// from the first request to the last ACK.
Future<List<_Cycle>> _trace(HarborSram sram, List<_Op> ops, _Mode mode) async {
  final tb = PeripheralTestBench(sram);
  final clk = tb.clk;
  final reset = Logic(name: 'r');
  final n = {
    for (final k in ['cyc', 'stb', 'we']) k: Logic(name: 'n_$k'),
    'adr': Logic(name: 'n_adr', width: tb.input('adr').width),
    'dat': Logic(name: 'n_dat', width: 32),
    'sel': Logic(name: 'n_sel', width: 4),
  };
  final r = {
    for (final e in n.entries)
      e.key: Logic(name: 'q_${e.key}', width: e.value.width),
  };
  Sequential(clk, [for (final k in n.keys) r[k]! < n[k]!]);
  final drive = mode == _Mode.comb ? n : r;
  tb.port('clk').getsLogic(clk);
  tb.port('reset').getsLogic(reset);
  tb.port('cyc').getsLogic(drive['cyc']!);
  tb.port('stb').getsLogic(drive['stb']!);
  tb.port('we').getsLogic(drive['we']!);
  tb.port('adr').getsLogic(drive['adr']!);
  tb.port('dat_out').getsLogic(drive['dat']!);
  tb.port('sel').getsLogic(drive['sel']!);
  await tb.build();

  void present(_Op? op) {
    n['cyc']!.put(op == null ? 0 : 1);
    n['stb']!.put(op == null ? 0 : 1);
    n['we']!.put(op?.write ?? false ? 1 : 0);
    n['adr']!.put(op?.addr ?? 0);
    n['dat']!.put(op?.data ?? 0);
    n['sel']!.put(op?.sel ?? 0xF);
  }

  reset.inject(1);
  present(null);
  Simulator.setMaxSimTime(200000);
  unawaited(Simulator.run());
  for (var i = 0; i < 4; i++) {
    await clk.nextNegedge;
  }
  reset.put(0);
  await clk.nextNegedge;

  final trace = <_Cycle>[];
  var next = 0;
  var idle = false;
  present(ops[next]);
  if (mode != _Mode.comb) {
    // A registered master shows the request one cycle after it is decided.
    await clk.nextNegedge;
  }
  while (next < ops.length) {
    await clk.nextNegedge;
    if (trace.length > ops.length * 8) {
      throw StateError('no ACK for access $next');
    }
    final stb = tb.input('stb').value.toBool();
    final ack = tb.ack.value.isValid && tb.ack.value.toBool();
    final we = tb.input('we').value.toBool();
    final dat = tb.datIn.value;
    trace.add((
      stb: stb,
      we: we,
      adr: tb.input('adr').value.toInt(),
      ack: ack,
      dat: ack && !we ? (dat.isValid ? dat.toInt() : -1) : null,
    ));
    if (idle) {
      idle = false;
      present(ops[next]);
      continue;
    }
    if (!stb || !ack) continue;
    next++;
    if (next == ops.length) {
      present(null);
    } else if (mode == _Mode.gap) {
      present(null);
      idle = true;
    } else {
      present(ops[next]);
    }
  }
  await Simulator.endSimulation();
  await Simulator.reset();
  return trace;
}

/// The value each read in [ops] must return, from a plain byte-lane model.
List<int> _golden(List<_Op> ops) {
  final mem = <int, int>{};
  final out = <int>[];
  for (final op in ops) {
    final w = op.addr & ~3;
    if (op.write) {
      var v = mem[w] ?? 0;
      for (var b = 0; b < 4; b++) {
        if ((op.sel >> b) & 1 == 1) {
          v = (v & ~(0xFF << (8 * b))) | (op.data & (0xFF << (8 * b)));
        }
      }
      mem[w] = v;
    } else {
      out.add(mem[w] ?? 0);
    }
  }
  return out;
}

String _fmt(List<_Cycle> t) => [
  for (var i = 0; i < t.length; i++)
    'c$i stb=${t[i].stb ? 1 : 0} we=${t[i].we ? 1 : 0} '
        'adr=0x${t[i].adr.toRadixString(16)} ack=${t[i].ack ? 1 : 0}'
        '${t[i].dat == null ? '' : ' dat=0x${t[i].dat!.toRadixString(16)}'}',
].join('\n');

const _ecp5 = HarborFpgaTarget.ecp5(device: '85f', package: 'CABGA381');

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // Fill, back-to-back reads, read after write to the same and to another
  // word, sub-word stores, and the repro kernel's fill then fold.
  final ops = <_Op>[
    for (var a = 0x14; a < 0x54; a += 4) _Op.write(a, 0x08000000 + a),
    for (var a = 0x14; a < 0x54; a += 4) _Op.read(a),
    const _Op.write(0x100, 0xDEADBEEF),
    const _Op.read(0x100),
    const _Op.write(0x104, 0x11223344),
    const _Op.read(0x100),
    const _Op.read(0x104),
    const _Op.write(0x104, 0xAA, sel: 0x1),
    const _Op.write(0x104, 0xBB000000, sel: 0x8),
    const _Op.read(0x104),
    const _Op.read(0x104),
    const _Op.write(0x108, 0x55555555),
    const _Op.write(0x10C, 0x66666666),
    const _Op.read(0x10C),
    const _Op.read(0x108),
    const _Op.read(0x14),
  ];
  final expected = _golden(ops);

  for (final mode in _Mode.values) {
    test('ECP5 block RAM path matches the sim model cycle for cycle '
        '(${mode.name})', () async {
      final ref = await _trace(
        HarborSram(baseAddress: 0, size: 4096),
        ops,
        mode,
      );
      final ecp5 = await _trace(
        HarborSram(baseAddress: 0, size: 4096, target: _ecp5),
        ops,
        mode,
      );
      expect(
        [
          for (final c in ref)
            if (c.dat != null) c.dat,
        ],
        equals(expected),
        reason: 'reference model\n${_fmt(ref)}',
      );
      expect(
        _fmt(ecp5),
        equals(_fmt(ref)),
        reason: 'the ECP5 path must ack and answer as the sim model does',
      );
    });
  }

  test('ECP5 path with many banks answers each bank in turn', () async {
    // 128 KiB is 16 banks of 2048 words. The accesses cross banks back to
    // back, which a single bank cannot show.
    final banked = <_Op>[
      for (var b = 0; b < 16; b++) _Op.write(b * 0x2000 + 4 * b, 0x100 + b),
      for (var b = 15; b >= 0; b--) _Op.read(b * 0x2000 + 4 * b),
      for (var b = 0; b < 16; b++) _Op.read(b * 0x2000 + 4 * b),
    ];
    final want = _golden(banked);
    for (final mode in _Mode.values) {
      final t = await _trace(
        HarborSram(baseAddress: 0, size: 128 * 1024, target: _ecp5),
        banked,
        mode,
      );
      expect(
        [
          for (final c in t)
            if (c.dat != null) c.dat,
        ],
        equals(want),
        reason: '${mode.name}\n${_fmt(t)}',
      );
    }
  });
}
