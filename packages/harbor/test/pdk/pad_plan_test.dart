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

  test('sky130 has no pad library', () {
    expect(Sky130Provider(pdkRoot: '/pdk/sky130A').padLibrary, isNull);
  });
}
