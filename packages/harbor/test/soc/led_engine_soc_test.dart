// The LED engine in a HarborSoC: one SoC per board preset with the board LED
// pins bound, a badge-like ECP5 SoC with a serial channel, and a SoC where
// the engine reads pixels as a master.

import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

import '../peripherals/sdio_adma_bench.dart';

const _base = 0x10005000;

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
  for (final name in ['kc705', 'ulx3s-85f', 'arty-s7-50']) {
    test('$name: the board LED channel binds its pins', () async {
      final board = HarborBoard.get(name);
      final ch = board.ledChannels.single;
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
        target: board.fpgaTarget(),
        board: board,
        pins: ch.pins,
      );
      soc.buildFabric();
      await soc.build();
      expect(ch.pins, hasLength(led.channelOut(0).length));
      for (final pin in ch.pins) {
        expect(board.pins.containsKey(pin), isTrue, reason: pin);
      }
      _checkOutputs(soc, led, ch.pins);
    });
  }

  test(
    'a badge-like ECP5 SoC drives one serial channel on a free pin',
    () async {
      final board = HarborBoard.get('ulx3s-85f');
      final led = HarborLedEngine(
        baseAddress: _base,
        busAddressWidth: 32,
        clockHz: 25000000,
      );
      final soc = _soc(
        'led_badge',
        HarborFabricKind.wishbone,
        led,
        target: board.fpgaTarget(),
        board: board,
        pins: const ['led[7]'],
      );
      soc.buildFabric();
      await soc.build();
      expect(board.pins.containsKey('led[7]'), isTrue);
      expect(led.channels.single.kind, HarborLedKind.serial);
      _checkOutputs(soc, led, const ['led[7]']);
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
}
