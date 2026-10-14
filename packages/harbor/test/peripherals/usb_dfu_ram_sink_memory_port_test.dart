import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../util/mem_target.dart';

/// [UsbDfuRamSink] runs its USB and bus domains on separate clocks, but
/// [MasterTop] drives every DUT on a single `clk`/`reset`. This ties both
/// domains to that one clock, which the sink's own CDC logic handles fine
/// (a synchronous crossing is still a valid crossing).
class _OneClockRamSink extends BridgeModule {
  late final UsbDfuRamSink sink;

  _OneClockRamSink(
    HarborFabricKind kind, {
    required int busDataWidth,
    required int regionBytes,
  }) : super('OneClockRamSink_${kind.name}_d$busDataWidth', name: 'dut') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    sink = UsbDfuRamSink(
      loadBase: 0,
      regionBytes: regionBytes,
      fabricKind: kind,
      busDataWidth: busDataWidth,
    );
    addSubModule(sink);
    sink.input('usb_clk').srcConnection! <= input('clk');
    sink.input('usb_reset').srcConnection! <= input('reset');
    sink.input('bus_clk').srcConnection! <= input('clk');
    sink.input('bus_reset').srcConnection! <= input('reset');
    pullUpInterface(sink.interface('dfu'), newIntfName: 'dfu');
    pullUpInterface(sink.interface('bus'), newIntfName: 'bus');
    const skipPrefixes = ['dfu_', 'bus_'];
    const skipPorts = ['usb_clk', 'usb_reset', 'bus_clk', 'bus_reset'];
    for (final p in [...sink.inputs.keys, ...sink.outputs.keys]) {
      if (skipPorts.contains(p)) continue;
      if (skipPrefixes.any((pre) => p.startsWith(pre))) continue;
      pullUpPort(sink.port(p), newPortName: p);
    }
  }
}

/// Drives [UsbDfuRamSink.dfu] directly (bypassing the USB stack) to push
/// [bytes] as one DFU block, then the zero-length DNLOAD that ends the
/// image, and waits for `done`.
Future<void> _downloadBytes(
  MasterTop top,
  Logic clk,
  Logic dataSig,
  Logic validSig,
  Logic endSig,
  List<int> bytes,
) async {
  for (final b in bytes) {
    while (!(top.output('dfu_ready').value.toBool())) {
      await clk.nextPosedge;
    }
    dataSig.inject(b);
    validSig.inject(1);
    await clk.nextPosedge;
  }
  validSig.inject(0);
  while (!(top.output('dfu_ready').value.toBool())) {
    await clk.nextPosedge;
  }
  endSig.inject(1);
  await clk.nextPosedge;
  endSig.inject(0);

  var done = false;
  for (var i = 0; i < 5000 && !done; i++) {
    await clk.nextPosedge;
    if (top.output('dfu_done').previousValue!.toBool()) done = true;
  }
  if (!done) {
    throw StateError('UsbDfuRamSink never raised dfu_done');
  }
}

Future<(MasterTop, Logic, BeatMemory)> _buildHarness(
  HarborFabricKind kind, {
  int busDataWidth = 32,
  int regionBytes = 64,
}) async {
  final dut = _OneClockRamSink(
    kind,
    busDataWidth: busDataWidth,
    regionBytes: regionBytes,
  );
  final top = MasterTop(
    dut,
    iface: 'bus',
    kind: kind,
    config: HarborMemoryWaistConfig(
      addressWidth: 32,
      dataWidth: busDataWidth,
      idWidth: 1,
      outstanding: 1,
    ),
  );
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final dataSig = Logic(name: 'dfu_data_drv', width: 8);
  final validSig = Logic(name: 'dfu_valid_drv');
  final targetSig = Logic(name: 'dfu_target_drv', width: 8);
  final blockSig = Logic(name: 'dfu_block_drv', width: 16);
  final endSig = Logic(name: 'dfu_end_drv');
  final clearSig = Logic(name: 'dfu_clear_drv');

  top.input('clk').srcConnection! <= clk;
  top.input('reset').srcConnection! <= reset;
  top.input('dfu_data').srcConnection! <= dataSig;
  top.input('dfu_valid').srcConnection! <= validSig;
  top.input('dfu_target').srcConnection! <= targetSig;
  top.input('dfu_block').srcConnection! <= blockSig;
  top.input('dfu_xfer_end').srcConnection! <= endSig;
  top.input('dfu_clear').srcConnection! <= clearSig;

  final mem = BeatMemory(top, clk);

  await top.build();
  mem.start();

  reset.inject(1);
  dataSig.inject(0);
  validSig.inject(0);
  targetSig.inject(0); // 0 selects RAM
  blockSig.inject(0);
  endSig.inject(0);
  clearSig.inject(0);
  Simulator.setMaxSimTime(2000000);
  unawaited(Simulator.run());
  for (var i = 0; i < 4; i++) {
    await clk.nextPosedge;
  }
  reset.inject(0);
  // The sink joins usb_reset/bus_reset through a short flop chain in each
  // domain (see harborCdcJoinReset), which stays asserted a couple of
  // cycles after the raw reset drops. Give it margin before driving data.
  for (var i = 0; i < 30; i++) {
    await clk.nextPosedge;
  }

  return (top, clk, mem);
}

void main() {
  tearDown(() async => Simulator.reset());

  for (final kind in HarborFabricKind.values) {
    test(
      'a DFU RAM download lands in memory byte for byte (${kind.name})',
      () async {
        final (top, clk, mem) = await _buildHarness(kind);
        final dataSig = top.input('dfu_data').srcConnection!;
        final validSig = top.input('dfu_valid').srcConnection!;
        final endSig = top.input('dfu_xfer_end').srcConnection!;

        // image_ready is a one-cycle pulse on the bus clock, well before the
        // CDC-synced `done` this test polls for, so a listener catches it
        // instead of a point-in-time read after the fact.
        var imageReadyPulses = 0;
        final sub = top.output('image_ready').changed.listen((e) {
          if (e.newValue.isValid && e.newValue.toBool()) imageReadyPulses++;
        });

        final image = [for (var i = 0; i < 37; i++) (i * 7 + 3) & 0xFF];
        await _downloadBytes(top, clk, dataSig, validSig, endSig, image);

        for (var i = 0; i < image.length; i++) {
          expect(mem.readBytes(i, 1), equals(image[i]), reason: 'byte[$i]');
        }
        expect(top.output('bytes_written').value.toInt(), equals(image.length));
        expect(imageReadyPulses, equals(1));
        await sub.cancel();
        await Simulator.endSimulation();
      },
    );
  }

  test(
    'a DFU RAM download on an 8-bit bus (wishbone) lands byte for byte',
    () async {
      final (top, clk, mem) = await _buildHarness(
        HarborFabricKind.wishbone,
        busDataWidth: 8,
      );
      final dataSig = top.input('dfu_data').srcConnection!;
      final validSig = top.input('dfu_valid').srcConnection!;
      final endSig = top.input('dfu_xfer_end').srcConnection!;

      final image = [for (var i = 0; i < 11; i++) (i * 13 + 1) & 0xFF];
      await _downloadBytes(top, clk, dataSig, validSig, endSig, image);

      for (var i = 0; i < image.length; i++) {
        expect(mem.readBytes(i, 1), equals(image[i]), reason: 'byte[$i]');
      }
      await Simulator.endSimulation();
    },
  );
}
