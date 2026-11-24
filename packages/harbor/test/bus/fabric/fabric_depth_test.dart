import 'package:harbor/harbor.dart';
import 'package:harbor/src/bus/port/reg_fifo.dart' show HarborFifoRam;
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'axi4_fabric_harness.dart';

// Flops in front of and behind [body], so the walk sees one path.
class _Tiny extends Module {
  _Tiny(int width, int count, Logic Function(Logic clk, List<Logic>) body)
    : super(name: 'tiny') {
    final clk = addInput('clk', Logic());
    final ins = [
      for (var i = 0; i < count; i++)
        flop(clk, addInput('i$i', Logic(width: width), width: width)),
    ];
    final out = body(clk, ins);
    addOutput('o', width: out.width) <= flop(clk, out);
  }
}

class _Inner extends Module {
  Logic get out => output('out');

  _Inner(Logic c, Logic a, Logic b) : super(name: 'inner') {
    c = addInput('c', c);
    a = addInput('a', a);
    b = addInput('b', b);
    addOutput('out') <= mux(c, a, b);
  }
}

HarborFifoRam _ram(Logic clk, Logic wrData, Logic rdAddr) => HarborFifoRam(
  name: 'ram',
  clk: clk,
  wrEn: Logic()..put(1),
  wrAddr: Const(0, width: rdAddr.width),
  wrData: wrData,
  rdAddr: rdAddr,
  depth: 1 << rdAddr.width,
  zeroInit: true,
);

Future<int> _depth(
  int width,
  int count,
  Logic Function(Logic clk, List<Logic>) body,
) async {
  final m = _Tiny(width, count, body);
  await m.build();
  return harborWorstDepth(m).levels;
}

// Seven masters and seventeen targets as on the KC705: s0 has a second read
// channel, the even targets remap IDs, m6 is real-time, so bursts split, and
// m5 is a memory master behind a clock crossing, as PCIe DMA is.
final _kc705Masters = [
  for (var i = 0; i < 7; i++)
    MasterCfg(
      'm$i',
      4,
      4,
      realtime: i == 6,
      readChannel: i < 2 ? 1 : null,
      cdc: i == 5,
    ),
];
// s2 has 2 slave ID bits for 8 requests, so its ID remap has fewer slots
// than requests, and s16 is an AXI4-Lite slave with a 1 KB region, so the
// bursts to it check the region end.
final _kc705Slaves = [
  const SlaveCfg('s0', 4, 8, 0x00000, 0x10000, readChannels: 2),
  for (var i = 1; i < 17; i++)
    SlaveCfg(
      's$i',
      i == 2 ? 2 : (i.isEven ? 1 : 8),
      i > 12 ? 1 : (i == 2 ? 8 : 2),
      0x10000 + i * 0x4000,
      i == 16 ? 0x400 : 0x4000,
      lite: i > 12,
    ),
];

final _configs = {
  'kc705': (_kc705Masters, _kc705Slaves),
  '2x3': (masters3.sublist(0, 2), slaves3),
};

// The compact worst depth per config and topology. A change in the fabric
// or the model must update it.
const _compact = {
  ('kc705', HarborFabricTopology.shared): 23,
  ('kc705', HarborFabricTopology.crossbar): 21,
  ('2x3', HarborFabricTopology.shared): 16,
  ('2x3', HarborFabricTopology.crossbar): 15,
};

// The worst depth of the whole fabric at the balanced level. It is on the
// responses, which are not yet registered, and must not grow.
const _balanced = {
  ('kc705', HarborFabricTopology.shared): 16,
  ('kc705', HarborFabricTopology.crossbar): 15,
  ('2x3', HarborFabricTopology.shared): 16,
  ('2x3', HarborFabricTopology.crossbar): 15,
};

// The worst depth of the crossing and memory master in front of m5.
const _crossing = 7;

Iterable<Module> _leaves(Module m) sync* {
  if (m.subModules.isEmpty) {
    yield m;
    return;
  }
  for (final s in m.subModules) {
    yield* _leaves(s);
  }
}

// The request path budget: from the master FIFO and head register through
// the arbiter, the credits and the grant register into the grant FIFO.
const _requestBudget = 6;

// The cells of the request path, by the names of the flops they drive.
final _requestCell = RegExp(
  r'^m\d+_(aw|ar)_(wr|rd|has|full|ram)$|'
  r'_(aw|ar)_(head_.*|issued_.*|pop_q|fire_q|non_final_q|split_.*|order_.*|'
  r'rr|grant_reg|elig|slot_elig|want_q|rt_want_q|grant_used|remap_used|'
  r'grant_pop_q|'
  r'remap_.*|grant_(wr|rd|count|ram))$|_prefer_read$|_inflight$',
);

// The cells of the slave side, the responses and W, by target (s<i>,
// s<i>_r<k>, err) or master (m<i>) prefix. A FIFO counts by its internal
// names only.
const _fifo = r'(wr|rd|count|ram|e\d+)';
const _target = r'(s\d+(_r\d+)?|err)';
final _otherCell = RegExp(
  '^${_target}_(aw|ar|w|req)_$_fifo\$|'
  '^${_target}_(aw|ar|w|req)_shown\$|'
  '^${_target}_lite_.*\$|^${_target}_req_(valid|entry)\$|'
  '^${_target}_(timer|cut_off)\$|^${_target}_rec\\d+_.*\$|'
  '^${_target}_w_(aw_held|source_$_fifo|order_$_fifo)\$|'
  '^err_(r_beat|w_done)\$|'
  '^m\\d+_(b|r|w)_$_fifo\$|^m\\d+_(b|r)_(pieces|worst|resp_rr)\$|'
  '^m\\d+_w_(count|pieces|route_$_fifo)\$|'
  '^bus_(b|r)_resp_rr\$|^bus_w_(count|order_$_fifo)\$',
);

// The cells of the AXI4-Lite slave paths of the kc705 config.
final _liteCell = RegExp(
  r'^s1[3-6]_(lite_.*|req_(valid|entry|shown)|w_(wr|rd|count|ram|e\d+))$',
);

List<String> _cellNames(Module cell) => cell is HarborFifoRam
    ? [cell.name]
    : [
        for (final o in cell.outputs.values)
          for (final d in o.dstConnections) d.name,
      ];

bool _inRequest(Module cell) => _cellNames(cell).any(_requestCell.hasMatch);

Iterable<Module> _cells(Module m) sync* {
  if (m.subModules.isEmpty) {
    if (m is Sequential || m is FlipFlop || m is HarborFifoRam) yield m;
    return;
  }
  for (final s in m.subModules) {
    yield* _cells(s);
  }
}

// True when [to] is in the combinational fan out of [from]. A flop ends a
// path.
bool _combPath(Logic from, Set<Logic> to) {
  final seen = <Logic>{};
  final todo = [from];
  while (todo.isNotEmpty) {
    final s = todo.removeLast();
    if (!seen.add(s)) continue;
    if (to.contains(s)) return true;
    todo.addAll(s.dstConnections);
    final m = s.parentModule;
    if (s.isInput && m != null && m.subModules.isEmpty) {
      if (m is Sequential || m is FlipFlop) continue;
      todo.addAll(m.outputs.values);
    }
  }
  return false;
}

Future<HarborAxi4Fabric> _fabric(
  String config,
  HarborFabricTopology t,
  HarborFabricPipeline p,
) async {
  final (masters, slaves) = _configs[config]!;
  final shell = FabricShell(t, masters: masters, slaves: slaves, pipeline: p);
  await shell.build();
  return shell.fabric as HarborAxi4Fabric;
}

Future<HarborDepthPath> _fabricDepth(
  String config,
  HarborFabricTopology t,
  HarborFabricPipeline p,
) async => harborWorstDepth(await _fabric(config, t, p));

void main() {
  group('cost model', () {
    test('a 7-input AND is 2', () async {
      expect(await _depth(1, 7, (_, i) => i.reduce((a, b) => a & b)), 2);
      expect(await _depth(1, 7, (_, i) => i.concat().and()), 2);
    });

    test('a flop to flop wire is 0', () async {
      expect(await _depth(8, 1, (_, i) => i.first), 0);
    });

    test('a 32-bit adder is 3', () async {
      expect(await _depth(32, 2, (_, i) => i[0] + i[1]), 3);
    });

    test('a counter with four 1-bit steps is one 5-operand adder', () async {
      expect(
        await _depth(
          4,
          5,
          (_, i) =>
              i[0] +
              i[1].getRange(0, 1).zeroExtend(4) +
              i[2].getRange(0, 1).zeroExtend(4) -
              i[3].getRange(0, 1).zeroExtend(4) -
              i[4].getRange(0, 1).zeroExtend(4),
        ),
        3,
      );
    });

    test('an add result used twice is not collapsed', () async {
      expect(
        await _depth(4, 3, (_, i) {
          final ab = i[0] + i[1];
          return (ab + i[2]) ^ ab;
        }),
        5,
      );
    });

    test('two chained 2:1 muxes are 2', () async {
      expect(
        await _depth(1, 5, (_, i) => mux(i[0], mux(i[1], i[2], i[3]), i[4])),
        2,
      );
    });

    test('a 17-bit equality is 2', () async {
      expect(await _depth(17, 2, (_, i) => i[0].eq(i[1])), 2);
    });

    test('a path through a flop stops', () async {
      expect(await _depth(1, 3, (clk, i) => flop(clk, i[0] & i[1]) & i[2]), 1);
    });

    test('a slice of the shallow field of a bus stays shallow', () async {
      expect(
        await _depth(
          8,
          3,
          (_, i) => [i[0] + i[1], i[2]].concat().getRange(0, 8),
        ),
        0,
      );
      expect(
        await _depth(8, 3, (_, i) => [i[0] + i[1], i[2]].concat().getRange(8)),
        2,
      );
    });

    test('a RAM read goes from its address to its data', () async {
      expect(
        await _depth(4, 3, (clk, i) {
          final ram = _ram(clk, i[0], i[1]);
          return ram.rdData & i[2];
        }),
        2,
      );
    });

    test('a RAM write ends a path', () async {
      final m = _Tiny(32, 3, (clk, i) {
        final ram = _ram(clk, i[0] + i[1], i[2].getRange(0, 4));
        return ram.rdData;
      });
      await m.build();
      final p = harborWorstDepth(m);
      expect(p.levels, 3);
      expect(p.signals.last.parentModule, isA<HarborFifoRam>());
    });

    test('a path crosses a submodule boundary', () async {
      expect(
        await _depth(
          1,
          5,
          (_, i) => mux(i[3], _Inner(i[0], i[1], i[2]).out, i[4]),
        ),
        2,
      );
    });

    test('an If and else Combinational is a 2:1 mux', () async {
      expect(
        await _depth(1, 5, (_, i) {
          final o = Logic();
          Combinational([
            If(i[0], then: [o < i[1]], orElse: [o < i[2]]),
          ]);
          return mux(i[3], o, i[4]);
        }),
        2,
      );
    });

    test('another Combinational shape throws', () async {
      expect(
        () => _depth(1, 3, (_, i) {
          final o = Logic();
          Combinational([
            o < i[2],
            If(i[0], then: [o < i[1]]),
          ]);
          return o;
        }),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('Combinational'),
          ),
        ),
      );
    });

    test('a NOT costs 0', () async {
      expect(await _depth(1, 2, (_, i) => ~(~i[0] & i[1])), 1);
    });

    test('an unknown leaf throws with its type', () async {
      expect(
        () => _depth(8, 2, (_, i) => i[0] * i[1]),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('Multiply'),
          ),
        ),
      );
    });

    test('the path names its signals from start to end', () async {
      final m = _Tiny(1, 3, (_, i) => (i[0] & i[1]).named('both') | i[2]);
      await m.build();
      final p = harborWorstDepth(m);
      expect(p.levels, 1);
      expect(p.signals.last.parentModule, isA<Sequential>());
    });
  });

  for (final config in _configs.keys) {
    for (final t in HarborFabricTopology.values) {
      group('$config ${t.name}', () {
        test('compact keeps its recorded depth', () async {
          final p = await _fabricDepth(config, t, HarborFabricPipeline.compact);
          printOnFailure('$p');
          expect(p.levels, _compact[(config, t)]);
        });

        for (final level in [
          HarborFabricPipeline.balanced,
          HarborFabricPipeline.fast,
        ]) {
          test(
            '${level.name} request path fits $_requestBudget levels',
            () async {
              final f = await _fabric(config, t, level);
              final p = harborWorstDepth(
                f,
                cut: f.requestCut,
                endIn: _inRequest,
              );
              printOnFailure('$p');
              expect(p.levels, lessThanOrEqualTo(_requestBudget));
            },
          );
        }

        test('every flop of the balanced fabric has a part', () async {
          final f = await _fabric(config, t, HarborFabricPipeline.balanced);
          final open = {
            for (final cell in _cells(f))
              for (final n in _cellNames(cell))
                if (!_requestCell.hasMatch(n) && !_otherCell.hasMatch(n)) n,
          };
          must(open, isEmpty);
        });

        if (config == 'kc705') {
          for (final level in [
            HarborFabricPipeline.balanced,
            HarborFabricPipeline.fast,
          ]) {
            test('${level.name} AXI4-Lite slave paths fit '
                '$_requestBudget levels', () async {
              final f = await _fabric(config, t, level);
              final p = harborWorstDepth(
                f,
                cut: f.requestCut,
                endIn: (c) => _cellNames(c).any(_liteCell.hasMatch),
              );
              printOnFailure('$p');
              expect(p.levels, lessThanOrEqualTo(_requestBudget));
            });
          }
        }

        test('balanced keeps its recorded depth', () async {
          final p = await _fabricDepth(
            config,
            t,
            HarborFabricPipeline.balanced,
          );
          printOnFailure('$p');
          expect(p.levels, _balanced[(config, t)]);
        });

        test('fast fits 6 levels', () async {
          final p = await _fabricDepth(config, t, HarborFabricPipeline.fast);
          printOnFailure('$p');
          expect(p.levels, lessThanOrEqualTo(6));
        }, skip: 'responses and W are not registered yet');
      });
    }
  }

  for (final t in HarborFabricTopology.values) {
    test(
      'kc705 ${t.name}: no path from a CDC RAM read into the fabric',
      () async {
        final (masters, slaves) = _configs['kc705']!;
        final shell = FabricShell(
          t,
          masters: masters,
          slaves: slaves,
          pipeline: HarborFabricPipeline.balanced,
        );
        await shell.build();
        final into = shell.fabric.inputs.values.toSet();
        final reads = [
          for (final c in _leaves(shell))
            if (c.definitionName.startsWith('HarborWaistCdcRam_'))
              c.output('rd_data'),
        ];
        must(reads, isNotEmpty);
        for (final x in reads) {
          must(_combPath(x, into), isFalse, reason: x.parentModule!.name);
        }
      },
    );

    test(
      'kc705 ${t.name}: the crossing side keeps its recorded depth',
      () async {
        final (masters, slaves) = _configs['kc705']!;
        final shell = FabricShell(
          t,
          masters: masters,
          slaves: slaves,
          pipeline: HarborFabricPipeline.balanced,
        );
        await shell.build();
        final fabric = shell.fabric;
        final p = harborWorstDepth(
          shell,
          endIn: (c) => !c.hierarchy().contains(fabric),
        );
        printOnFailure('$p');
        expect(p.levels, _crossing);
      },
    );
  }

  // Glacier routed 14 to 20 LUT levels on the compact KC705 fabric.
  test('the model gives the KC705 compact fabric 14 levels or more', () async {
    final p = await _fabricDepth(
      'kc705',
      HarborFabricTopology.shared,
      HarborFabricPipeline.compact,
    );
    printOnFailure('$p');
    expect(p.levels, greaterThanOrEqualTo(14));
  });

  test('pathCyclesOf counts the AXI4 stages of each level', () {
    const stages = {
      HarborFabricPipeline.compact: 5,
      HarborFabricPipeline.balanced: 7,
      HarborFabricPipeline.fast: 7,
    };
    for (final p in HarborFabricPipeline.values) {
      expect(
        HarborFabric.pathCyclesOf(
          kind: HarborFabricKind.axi4,
          pipeline: p,
          memoryPorts: 0,
        ),
        stages[p],
      );
    }
  });
}
