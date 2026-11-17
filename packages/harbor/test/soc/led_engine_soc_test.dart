// The LED engine in a HarborSoC: one SoC per board preset with the board LED
// pins bound, a badge-like ECP5 SoC with a serial channel, and a SoC where
// the engine reads pixels as a master.

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../bus/port/memory_harness.dart' show exposeWaist;
import '../peripherals/sdio_adma_bench.dart';

const _base = 0x10005000;

/// A memory master of 64 data bits, a stand-in for a 64-bit core.
class _Master64 extends BridgeModule {
  _Master64(HarborFabricKind kind)
    : super('LedMaster64_${kind.name}', name: 'cpu') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final mem = HarborMemoryMasterPort.create(
      module: this,
      name: 'dataBus',
      kind: kind,
      config: const HarborMemoryWaistConfig(
        addressWidth: 32,
        dataWidth: 64,
        idWidth: 2,
        outstanding: 1,
      ),
      clk: input('clk'),
      reset: input('reset'),
    );
    exposeWaist(this, mem.waist, 'mem', PairRole.consumer);
  }

  void pullUp(HarborSoC soc) {
    for (final n in [...inputs.keys, ...outputs.keys]) {
      if (n.startsWith('mem_')) soc.pullUpPort(port(n), newPortName: 'cpu_$n');
    }
  }
}

/// The top-level port name of a catalog pin such as `led[3]`.
String _port(String pin) =>
    pin.replaceAllMapped(RegExp(r'\[(\d+)\]'), (m) => '_${m.group(1)}');

/// A SoC with [led] at [_base], a bus master, and the pins of [led] bound to
/// the top level under the names in [pins].
HarborSoC _soc(
  String name,
  HarborFabricKind kind,
  HarborLedEngine led, {
  HarborFpgaTarget? target,
  HarborBoard? board,
  List<String> pins = const [],
}) {
  final soc = HarborSoC(
    name: name,
    compatible: 'test,led',
    fabricKind: kind,
    board: board,
    target: target ?? const HarborSimTarget(frequency: 50000000),
  );
  final cpu = soc.addMaster(AdmaCpu(kind));
  soc.addPeripheral(led);
  final flat = [
    for (var c = 0; c < led.channels.length; c++) ...led.channelOut(c),
  ];
  for (var i = 0; i < pins.length; i++) {
    final port =
        led.channels.length == 1 &&
            led.channels.single.kind == HarborLedKind.pwm
        ? 'led_ch0_$i'
        : 'led_ch$i';
    soc.exposePin(led, port, externalName: _port(pins[i]));
  }
  expect(flat, isNotEmpty);
  cpu.pullUp(soc);
  return soc;
}

void _checkOutputs(HarborSoC soc, HarborLedEngine led, List<String> pins) {
  final sv = soc.dumpSystemVerilog();
  expect(sv, contains(led.definitionName));
  for (final pin in pins) {
    expect(soc.output(_port(pin)).width, 1, reason: pin);
    expect(sv, contains(_port(pin)), reason: pin);
  }
  final dts = soc.generateDts();
  expect(dts, contains('harbor,led'));
  expect(dts, contains('10005000'));
}

void main() {
  const sites = {
    'kc705': ['AB8'],
    'ulx3s-85f': ['B2'],
    'arty-s7-50': [
      'E18',
      'F13',
      'E13',
      'H15',
      'J15',
      'G17',
      'F15',
      'E15',
      'F18',
      'E14',
    ],
  };
  for (final name in ['kc705', 'ulx3s-85f', 'arty-s7-50']) {
    test('$name: the board LED channel binds its pins', () async {
      final board = HarborBoard.get(name);
      final ch = board.ledChannels.single;
      final target = board.fpgaTarget();
      final led = HarborLedEngine(
        baseAddress: _base,
        busAddressWidth: 32,
        channels: [ch.config],
        maxPixels: ch.pixels,
        clockHz: board.oscillatorHz,
      );
      final soc = _soc(
        'led_$name'.replaceAll('-', '_'),
        HarborFabricKind.wishbone,
        led,
        target: target,
        board: board,
      );
      soc.bindBoardLeds(led, board);
      soc.buildFabric();
      await soc.build();
      final ports = {
        for (final e in soc.outputs.entries)
          if (e.key.startsWith('led')) e.key: e.value.width,
      };
      expect(ports, isNotEmpty);
      expect(target.missingPins(ports), isEmpty);
      final constraints = target.generateConstraints(
        knownPorts: ports.keys.toSet(),
      );
      for (final pin in ch.pins) {
        final site = board.pins[pin]!.split(' ').first;
        expect(constraints, contains(site), reason: pin);
      }
      for (final site in sites[name]!) {
        expect(constraints, contains(site));
      }
      expect(soc.dumpSystemVerilog(), contains(led.definitionName));
      expect(soc.generateDts(), contains('harbor,led'));
    });
  }

  test(
    'a badge-like ECP5 SoC drives one serial channel on a free pin',
    () async {
      final board = HarborBoard.get('ulx3s-85f');
      final target = board.fpgaTarget(
        extraPins: {'led_ws': 'B2 LVCMOS33 DRIVE=4'},
      );
      final led = HarborLedEngine(
        baseAddress: _base,
        busAddressWidth: 32,
        clockHz: 25000000,
      );
      final soc = _soc(
        'led_badge',
        HarborFabricKind.wishbone,
        led,
        target: target,
        board: board,
        pins: const ['led_ws'],
      );
      soc.buildFabric();
      await soc.build();
      expect(led.channels.single.kind, HarborLedKind.serial);
      expect(target.missingPins({'led_ws': 1}), isEmpty);
      expect(
        target.generateConstraints(knownPorts: {'led_ws'}),
        contains('B2'),
      );
      _checkOutputs(soc, led, const ['led_ws']);
    },
  );

  for (final kind in [HarborFabricKind.wishbone, HarborFabricKind.axi4]) {
    test('${kind.name}: a dma engine joins the fabric as a master', () async {
      final led = HarborLedEngine(
        baseAddress: _base,
        busAddressWidth: 32,
        pixelSource: HarborLedPixelSource.dma,
        fabricKind: kind,
      );
      final soc = _soc(
        'led_dma_${kind.name}',
        kind,
        led,
        pins: const ['led_out'],
      );
      soc.addMaster(
        led,
        busInterfaceName: 'dma',
        memory: true,
        outstanding: 1,
        targetRanges: [const BusAddressRange(0x08000000, 0x1000)],
      );
      soc.addPeripheral(
        HarborSram(
          name: 'sram',
          baseAddress: 0x08000000,
          size: 0x1000,
          busAddressWidth: 32,
          protocol: kind,
        ),
      );
      soc.buildFabric();
      await soc.build();
      _checkOutputs(soc, led, const ['led_out']);
      expect(soc.dumpSystemVerilog(), contains('led_dma'));
    });
  }

  for (final kind in [HarborFabricKind.wishbone, HarborFabricKind.axi4]) {
    test(
      '${kind.name}: a 64-bit fabric takes the engine and its board LEDs',
      () async {
        final board = HarborBoard.get('kc705');
        final ch = board.ledChannels.single;
        final target = board.fpgaTarget();
        final led = HarborLedEngine(
          baseAddress: _base,
          busAddressWidth: 32,
          busDataWidth: 64,
          fabricKind: kind,
          channels: [ch.config],
          maxPixels: ch.pixels,
          clockHz: board.oscillatorHz,
        );
        final soc = HarborSoC(
          name: 'led64_${kind.name}',
          compatible: 'test,led',
          fabricKind: kind,
          board: board,
          target: target,
        );
        final cpu = soc.addMaster(_Master64(kind), memory: true);
        soc.addPeripheral(led);
        cpu.pullUp(soc);
        soc.bindBoardLeds(led, board);
        soc.buildFabric();
        await soc.build();
        final ports = {
          for (final e in soc.outputs.entries)
            if (e.key.startsWith('led')) e.key: e.value.width,
        };
        expect(ports, isNotEmpty);
        expect(target.missingPins(ports), isEmpty);
        expect(soc.dumpSystemVerilog(), contains(led.definitionName));
      },
    );
  }
}
