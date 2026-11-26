import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

class _Top extends Module {
  _Top({bool bidirIn = true, bool inout = false}) : super(name: 'top') {
    addInput('clk', Logic());
    addInput('rst_n', Logic());
    addInput('btn', Logic(width: 2), width: 2);
    addOutput('led', width: 3);
    addOutput('sd_out', width: 2);
    addOutput('sd_oe', width: 2);
    if (bidirIn) addInput('sd_in', Logic(width: 2), width: 2);
    addInput('vref', Logic());
    if (inout) addInOut('bus', LogicNet());
  }
}

final _lib = Gf180mcuProvider(pdkRoot: '/pdk/gf180mcuD').padLibrary;

List<HarborPadPort> _signals(int n) => [
  for (var i = 0; i < n; i++)
    HarborPadPort(name: 's$i', width: 1, kind: HarborPadKind.output),
];

List<String> _insts(List<HarborPlacedPad> pads) => [
  for (final p in pads) p.inst,
];

void main() {
  test('kinds and masters follow the gf180 table', () {
    final ports = HarborPadPort.fromModule(
      _Top(),
      clocks: {'clk'},
      analog: {'vref'},
    );
    expect(
      [for (final p in ports) '${p.name}:${p.width}:${p.kind.name}'],
      [
        'clk:1:clockInput',
        'rst_n:1:input',
        'btn:2:input',
        'vref:1:analog',
        'led:3:output',
        'sd:2:bidir',
      ],
    );
    final sd = ports.last;
    expect(sd.outputName, 'sd_out');
    expect(sd.outputEnable, 'sd_oe');
    expect(sd.inputName, 'sd_in');

    final plan = HarborPadPlan.build(ports: ports, library: _lib);
    final master = {for (final p in plan.all) p.inst: p.master};
    expect(master['clk_pad_0'], 'gf180mcu_fd_io__in_s');
    expect(master['rst_n_pad_0'], 'gf180mcu_fd_io__in_c');
    expect(master['btn_pad_1'], 'gf180mcu_fd_io__in_c');
    expect(master['led_pad_2'], 'gf180mcu_fd_io__bi_24t');
    expect(master['sd_pad_1'], 'gf180mcu_fd_io__bi_24t');
    expect(master['vref_pad_0'], 'gf180mcu_fd_io__asig_5p0');
    expect(master['dvdd_pad_0'], 'gf180mcu_fd_io__dvdd');
    expect(master['dvss_pad_0'], 'gf180mcu_fd_io__dvss');
    expect(master['vdd_pad_0'], 'gf180mcu_fd_io__dvdd');
    expect(master['vss_pad_0'], 'gf180mcu_fd_io__dvss');

    expect(_lib.tieOffs[HarborPadKind.output], {
      'OE': "1'b1",
      'IE': "1'b0",
      'CS': "1'b0",
      'SL': "1'b0",
      'PU': "1'b0",
      'PD': "1'b0",
    });
    expect(_lib.tieOffs[HarborPadKind.bidir]!.containsKey('OE'), isFalse);
    expect(_lib.tieOffs[HarborPadKind.bidir]!['IE'], "1'b1");
    expect(_lib.tieOffs[HarborPadKind.input], {'PU': "1'b0", 'PD': "1'b0"});
    expect(
      [_lib.padPin, _lib.inPin, _lib.outPin, _lib.oePin, _lib.analogPin],
      ['PAD', 'Y', 'A', 'OE', 'ASIG5V'],
    );
  });

  test('40 signals fill 10 per side in port order', () {
    final plan = HarborPadPlan.build(ports: _signals(40), library: _lib);
    var i = 0;
    for (final e in HarborPadPlan.sideOrder) {
      final sig = plan.side(e).where((p) => p.port != null).toList();
      expect(_insts(sig), [
        for (var k = 0; k < 10; k++) 's${i + k}_pad_0',
      ], reason: e.name);
      i += 10;
    }
    expect(_insts(plan.all.where((p) => p.port != null).toList()), [
      for (var k = 0; k < 40; k++) 's${k}_pad_0',
    ]);
  });

  test('a side with 10 signal pads gets 2 io pairs and 1 core pair', () {
    final plan = HarborPadPlan.build(ports: _signals(40), library: _lib);
    final south = plan.side(HarborIoPadEdge.south);
    int count(HarborPadKind k) => south.where((p) => p.kind == k).length;
    expect(count(HarborPadKind.ioPower), 2);
    expect(count(HarborPadKind.ioGround), 2);
    expect(count(HarborPadKind.corePower), 1);
    expect(count(HarborPadKind.coreGround), 1);
    expect(south.length, 16);
    expect(south.first.port, isNotNull);
    expect(south.last.port, isNotNull);
    expect(_insts(plan.side(HarborIoPadEdge.east)), contains('dvdd_pad_2'));
  });

  test('one power pair sits in the middle of its side', () {
    final plan = HarborPadPlan.build(
      ports: _signals(16),
      library: _lib,
      rule: const HarborPowerPadRule(corePairsPerSide: 0),
    );
    expect(_insts(plan.side(HarborIoPadEdge.south)), [
      's0_pad_0',
      's1_pad_0',
      'dvss_pad_0',
      'dvdd_pad_0',
      's2_pad_0',
      's3_pad_0',
    ]);
  });

  test('an override pins uart_tx first on west', () {
    final ports = [
      ..._signals(7),
      HarborPadPort(name: 'uart_tx', width: 1, kind: HarborPadKind.output),
    ];
    final plan = HarborPadPlan.build(
      ports: ports,
      library: _lib,
      overrides: const HarborIoRing(
        pads: [
          HarborIoPad(
            signalName: 'uart_tx',
            edge: HarborIoPadEdge.west,
            position: 0,
          ),
        ],
      ),
    );
    final west = plan
        .side(HarborIoPadEdge.west)
        .where((p) => p.port != null)
        .toList();
    expect(west.first.inst, 'uart_tx_pad_0');
    expect(plan.all.where((p) => p.inst == 'uart_tx_pad_0').length, 1);
    expect(
      _insts(
        plan.side(HarborIoPadEdge.south).where((p) => p.port != null).toList(),
      ),
      ['s0_pad_0', 's1_pad_0'],
    );
  });

  test('a bit override uses the port[bit] name', () {
    final plan = HarborPadPlan.build(
      ports: [HarborPadPort(name: 'd', width: 2, kind: HarborPadKind.output)],
      library: _lib,
      overrides: const HarborIoRing(
        pads: [HarborIoPad(signalName: 'd[1]', edge: HarborIoPadEdge.north)],
      ),
    );
    expect(
      plan.side(HarborIoPadEdge.north).where((p) => p.port != null).single.inst,
      'd_pad_1',
    );
  });

  group('refusals name the port', () {
    void refuses(void Function() f, String name) => expect(
      f,
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          contains(name),
        ),
      ),
    );

    test('an inout with no pad kind', () {
      refuses(
        () => HarborPadPort.fromModule(_Top(inout: true), analog: {'vref'}),
        'bus',
      );
    });

    test('a bidir without its input', () {
      refuses(() => HarborPadPort.fromModule(_Top(bidirIn: false)), 'sd_in');
    });

    test('a bidir port without its output enable', () {
      refuses(
        () => HarborPadPort(name: 'io', width: 1, kind: HarborPadKind.bidir),
        'io',
      );
    });

    test('a power kind on a port', () {
      refuses(
        () => HarborPadPort(name: 'p', width: 1, kind: HarborPadKind.ioPower),
        'p',
      );
    });

    test('a pinned position used twice', () {
      refuses(
        () => HarborPadPlan.build(
          ports: _signals(2),
          library: _lib,
          overrides: const HarborIoRing(
            pads: [
              HarborIoPad(signalName: 's0', edge: HarborIoPadEdge.east),
              HarborIoPad(signalName: 's1', edge: HarborIoPadEdge.east),
            ],
          ),
        ),
        's1',
      );
    });

    test('a pinned name that is not a port', () {
      refuses(
        () => HarborPadPlan.build(
          ports: _signals(2),
          library: _lib,
          overrides: const HarborIoRing(
            pads: [HarborIoPad(signalName: 'nope', edge: HarborIoPadEdge.east)],
          ),
        ),
        'nope',
      );
    });

    test('a clock name that is not a port', () {
      refuses(() => HarborPadPort.fromModule(_Top(), clocks: {'xclk'}), 'xclk');
    });
  });

  group('wafer.space slot', () {
    final slot = HarborFabSlot.waferSpace['0p5x0p5']!;
    void refuses(void Function() f, String text) => expect(
      f,
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          contains(text),
        ),
      ),
    );

    test('the table has the pad counts of each slot', () {
      expect(
        {
          for (final MapEntry(:key, :value) in HarborFabSlot.waferSpace.entries)
            key: [for (final e in HarborPadPlan.sideOrder) value.positions(e)],
        },
        {
          '0p5x0p5': [11, 17, 11, 17],
          '0p5x1': [8, 28, 8, 28],
          '1x0p5': [24, 12, 24, 12],
          '1x1': [17, 20, 17, 20],
        },
      );
      expect(slot.centers[HarborIoPadEdge.south], [
        for (var k = 0; k < 11; k++) 448 + 104.0 * k,
      ]);
      expect(slot.centers[HarborIoPadEdge.west], [
        for (var k = 0; k < 17; k++) 449.5 + 102.0 * k,
      ]);
      expect(
        slot.centers[HarborIoPadEdge.north],
        slot.centers[HarborIoPadEdge.south],
      );
      expect(
        slot.centers[HarborIoPadEdge.east],
        slot.centers[HarborIoPadEdge.west],
      );
    });

    test('a 0p5x0p5 plan has 11, 17, 11 and 17 pads', () {
      final plan = HarborPadPlan.build(
        ports: _signals(10),
        library: _lib,
        slot: slot,
      );
      expect(plan.slot, slot);
      expect(
        [for (final e in HarborPadPlan.sideOrder) plan.side(e).length],
        [11, 17, 11, 17],
      );
    });

    test('spare pads fill the positions that are left', () {
      final plan = HarborPadPlan.build(
        ports: _signals(10),
        library: _lib,
        slot: slot,
      );
      final spares = plan.all
          .where((p) => p.kind == HarborPadKind.spare)
          .toList();
      expect(spares.length, 56 - 10 - 16);
      expect(_insts(spares), [
        for (var n = 0; n < spares.length; n++) 'spare_pad_$n',
      ]);
      for (final p in spares) {
        expect(p.master, 'gf180mcu_fd_io__bi_24t');
        expect(p.port, isNull);
      }
      expect(_lib.tieOffs[HarborPadKind.spare], {
        'A': "1'b0",
        'OE': "1'b0",
        'IE': "1'b0",
        'CS': "1'b0",
        'SL': "1'b0",
        'PU': "1'b0",
        'PD': "1'b0",
      });
      // 3 signals, then the two power pairs near 1/3 and 2/3, then spares.
      expect(_insts(plan.side(HarborIoPadEdge.south)), [
        's0_pad_0',
        's1_pad_0',
        'dvss_pad_0',
        'dvdd_pad_0',
        's2_pad_0',
        'spare_pad_0',
        'vss_pad_0',
        'vdd_pad_0',
        'spare_pad_1',
        'spare_pad_2',
        'spare_pad_3',
      ]);
    });

    test('40 signals use every position', () {
      final plan = HarborPadPlan.build(
        ports: _signals(40),
        library: _lib,
        slot: slot,
        rule: const HarborPowerPadRule(signalPadsPerExtraIoPair: 16),
      );
      expect(plan.all.where((p) => p.kind == HarborPadKind.spare), isEmpty);
      expect(
        [
          for (final e in HarborPadPlan.sideOrder)
            plan.side(e).where((p) => p.port != null).length,
        ],
        [7, 13, 7, 13],
      );
    });

    test('a pinned pad goes to its position index', () {
      final plan = HarborPadPlan.build(
        ports: _signals(4),
        library: _lib,
        slot: slot,
        overrides: const HarborIoRing(
          pads: [
            HarborIoPad(
              signalName: 's3',
              edge: HarborIoPadEdge.west,
              position: 9,
            ),
          ],
        ),
      );
      expect(plan.side(HarborIoPadEdge.west)[9].inst, 's3_pad_0');
      expect(plan.side(HarborIoPadEdge.west).length, 17);
    });

    test('too many signal pads are refused', () {
      refuses(
        () => HarborPadPlan.build(
          ports: _signals(41),
          library: _lib,
          slot: slot,
          rule: const HarborPowerPadRule(signalPadsPerExtraIoPair: 16),
        ),
        'Slot 0p5x0p5 has no position for 1 more signal pads. Pads with '
        'power on each side: south 11 of 11, east 17 of 17, north 11 of 11, '
        'west 17 of 17',
      );
    });

    test('too many pinned pads on a side are refused', () {
      refuses(
        () => HarborPadPlan.build(
          ports: _signals(8),
          library: _lib,
          slot: slot,
          overrides: HarborIoRing(
            pads: [
              for (var i = 0; i < 8; i++)
                HarborIoPad(
                  signalName: 's$i',
                  edge: HarborIoPadEdge.south,
                  position: i,
                ),
            ],
          ),
        ),
        'The south side needs 14 pads, slot 0p5x0p5 has 11',
      );
    });

    test('a pinned position past the side is refused', () {
      refuses(
        () => HarborPadPlan.build(
          ports: _signals(1),
          library: _lib,
          slot: slot,
          overrides: const HarborIoRing(
            pads: [
              HarborIoPad(
                signalName: 's0',
                edge: HarborIoPadEdge.south,
                position: 11,
              ),
            ],
          ),
        ),
        'slot 0p5x0p5 has 11 positions',
      );
    });

    test('a port name that makes a spare pad name is refused', () {
      refuses(
        () => HarborPadPlan.build(
          ports: [
            HarborPadPort(name: 'spare', width: 1, kind: HarborPadKind.input),
          ],
          library: _lib,
          slot: slot,
        ),
        'Two pads have the instance name spare_pad_0',
      );
    });

    test('a spare kind on a port is refused', () {
      refuses(
        () => HarborPadPort(name: 'p', width: 1, kind: HarborPadKind.spare),
        'spare',
      );
    });
  });

  test('sky130 has no pad library', () {
    expect(Sky130Provider(pdkRoot: '/pdk/sky130A').padLibrary, isNull);
  });
}
