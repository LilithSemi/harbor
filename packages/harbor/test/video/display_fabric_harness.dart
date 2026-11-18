// A SoC with the scanout display as a fabric master, a 64 bit fabric, one
// SRAM and a register master. The pixel clock is its own clock, half of the
// system clock, so the line buffer crosses a real clock boundary.

import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../bus/port/memory_harness.dart';
import '../bus/port/port_harness.dart';
import '../util/reg_bus.dart';

const mem = 0x80000000;
const displayBase = 0x10008000;

/// A 64 bit register master with plain `p_<PORT>` ports.
class _Cpu extends BridgeModule {
  _Cpu(HarborFabricKind kind)
    : super('FabricDisplayCpu_${kind.name}', name: 'cpu') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final PairInterface intf = switch (kind) {
      HarborFabricKind.wishbone => WishboneInterface(
        const WishboneConfig(addressWidth: 32, dataWidth: 64, useErr: true),
      ),
      HarborFabricKind.axi4 => Axi4LiteInterface(
        addressWidth: 32,
        dataWidth: 64,
      ),
      HarborFabricKind.tilelink => TileLinkInterface(
        const TileLinkConfig(addressWidth: 32, dataWidth: 64),
      ),
    };
    final i = addInterface(
      intf,
      name: 'dataBus',
      role: PairRole.provider,
    ).internalInterface!;
    for (final e in i.getPorts([PairDirection.fromProvider]).entries) {
      final w = e.value.width;
      e.value <= addInput('p_${e.key}', Logic(width: w), width: w);
    }
    for (final e in i.getPorts([PairDirection.fromConsumer]).entries) {
      addOutput('p_${e.key}', width: e.value.width) <= e.value;
    }
  }

  void pullUp(HarborSoC soc) {
    for (final n in [...inputs.keys, ...outputs.keys]) {
      if (!n.startsWith('p_')) continue;
      soc.pullUpPort(port(n), newPortName: 'cpu_${n.substring(2)}');
    }
  }
}

/// A memory master port with its waist on `w_*`, for traffic.
class _Hammer extends BridgeModule {
  _Hammer(HarborFabricKind kind)
    : super('FabricDisplayHammer_${kind.name}', name: 'hammer') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final port = HarborMemoryMasterPort.create(
      module: this,
      name: 'bus',
      kind: kind,
      config: const HarborMemoryWaistConfig(
        addressWidth: 32,
        dataWidth: 64,
        idWidth: 2,
        outstanding: 2,
      ),
      clk: input('clk'),
      reset: input('reset'),
    );
    exposeWaist(this, port.waist, 'w', PairRole.consumer);
  }

  void pullUp(HarborSoC soc) {
    for (final n in [...inputs.keys, ...outputs.keys]) {
      if (!n.startsWith('w_')) continue;
      soc.pullUpPort(port(n), newPortName: 'hammer_$n');
    }
  }
}

/// The 16 bit rgb565 word of pixel (x, y), and its 8 bit channels.
int rgb565(int x, int y) =>
    (((y * 3 + x) & 0x1f) << 11) | ((x * 4 + y) << 5) | ((x ^ y) & 0x1f);

List<int> expandRgb565(int h) {
  final r = (h >> 11) & 0x1f, g = (h >> 5) & 0x3f, b = h & 0x1f;
  return [(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)];
}

/// The xrgb8888 word of pixel (x, y).
int xrgb(int x, int y) =>
    ((x * 7 + y * 31) & 0xff) << 16 |
    ((x * 3 + y) & 0xff) << 8 |
    ((x + y * 5) & 0xff);

List<int> expandXrgb(int w) => [(w >> 16) & 0xff, (w >> 8) & 0xff, w & 0xff];

class FetchCase {
  final HarborFabricKind kind;
  final HarborPixelFormat format;
  final int hActive;
  final int vActive;
  final int burstBeats;

  /// Byte offset of the framebuffer inside the SRAM.
  final int fbOffset;

  /// False builds the display master as a plain master.
  final bool realtime;

  /// Runs a master with long bursts at the same time.
  final bool hammer;
  final int lineClocks;

  const FetchCase({
    required this.kind,
    this.format = HarborPixelFormat.rgb565,
    this.hActive = 16,
    this.vActive = 4,
    this.burstBeats = 16,
    this.fbOffset = 0,
    this.realtime = true,
    this.hammer = false,
    this.lineClocks = 64,
  });

  int get lineBytes => format.lineBytes(0, hActive);
  int get stride =>
      (lineBytes + burstBeats * 8 - 1) ~/ (burstBeats * 8) * (burstBeats * 8);

  /// The word of pixel (x, y) of the picture [pic] (0 or 1).
  int word(int x, int y, [int pic = 0]) => format == HarborPixelFormat.rgb565
      ? rgb565(x + pic * 5, y)
      : xrgb(x + pic * 5, y);

  List<int> rgb(int x, int y, [int pic = 0]) =>
      format == HarborPixelFormat.rgb565
      ? expandRgb565(word(x, y, pic))
      : expandXrgb(word(x, y, pic));
}

/// A running display and the pixels it showed, by frame.
class FetchRun {
  final FetchCase c;
  final HarborSoC soc;
  final HarborScanoutDisplay display;
  final RegBus bus;
  final Logic clk;
  final Logic pixelClk;
  final List<Map<(int, int), List<int>>> frames = [{}];

  /// The traffic master of a case with [FetchCase.hammer].
  WaistRequester? hammer;
  final List<String> errors = [];

  FetchRun(this.c, this.soc, this.display, this.bus, this.clk, this.pixelClk) {
    final d = display.display;
    var last = false;
    pixelClk.posedge.listen((_) {
      final de = d.output('de').value;
      if (de.isValid && de.toBool()) {
        final x = d.output('x').value.toInt();
        final y = d.output('y').value.toInt();
        if (x == 0 && y == 0 && !last) frames.add({});
        // A line that was not fetched in time shows no known data.
        int channel(String n) {
          final v = d.output(n).value;
          return v.isValid ? v.toInt() : -1;
        }

        frames.last[(x, y)] = [
          channel('red'),
          channel('green'),
          channel('blue'),
        ];
        last = true;
      } else {
        last = false;
      }
    });
  }

  /// Queues [n] bursts of 256 beats, reads and writes, at 0x1800.
  void hammerBursts(int n) {
    for (var i = 0; i < n; i++) {
      final write = i.isEven;
      hammer!.send(
        Burst(
          id: 0,
          write: write,
          addr: mem + 0x1800,
          len: 255,
          size: 3,
          burst: 1,
          data: write ? [for (var k = 0; k < 256; k++) i * 1000 + k] : const [],
          strb: write ? List.filled(256, 0xff) : const [],
        ),
      );
    }
  }

  /// Writes picture [pic] at byte [offset] of the SRAM.
  Future<void> writePicture(int offset, int pic) async {
    final wordBytes = c.format == HarborPixelFormat.rgb565 ? 2 : 4;
    for (var y = 0; y < c.vActive; y++) {
      final line = mem + offset + y * c.stride;
      for (var w = 0; w < c.lineBytes ~/ 8; w++) {
        var v = BigInt.zero;
        for (var k = 0; k < 8 ~/ wordBytes; k++) {
          final x = w * (8 ~/ wordBytes) + k;
          v |= BigInt.from(c.word(x, y, pic)) << (8 * wordBytes * k);
        }
        await bus.accessWide(line + w * 8, data: v, write: true);
      }
    }
  }

  /// Waits until [n] full frames were seen since the call, at most [limit]
  /// system clocks.
  Future<void> waitFrames(int n, {int limit = 6000}) async {
    final start = full.length;
    for (var i = 0; i < limit && full.length < start + n; i += 100) {
      await cycles(100);
    }
    expect(full.length, greaterThanOrEqualTo(start + n), reason: 'frames');
  }

  Future<void> cycles(int n) async {
    for (var i = 0; i < n; i++) {
      await clk.nextPosedge;
    }
  }

  Future<int> reg(int offset) => bus.read(displayBase + offset);

  Future<void> write(int offset, int v) => bus.write(displayBase + offset, v);

  /// Frames that have all their pixels.
  List<Map<(int, int), List<int>>> get full =>
      frames.where((f) => f.length == c.hActive * c.vActive).toList();

  /// Checks every pixel of [frame] against the written framebuffer.
  void expectFrame(Map<(int, int), List<int>> frame, [int pic = 0]) {
    for (var y = 0; y < c.vActive; y++) {
      for (var x = 0; x < c.hActive; x++) {
        expect(frame[(x, y)], c.rgb(x, y, pic), reason: 'pixel $x,$y');
      }
    }
  }
}

/// Builds the SoC, writes the framebuffer through the register master and
/// leaves the display off. Call [FetchRun.write] to start it.
Future<FetchRun> startFetch(FetchCase c, {bool writeFrame = true}) async {
  final kind = c.kind;
  final soc = HarborSoC(
    name: 'FabricDisplay_${kind.name}',
    compatible: 'test,fabricdisplay',
    target: const HarborSimTarget(frequency: 50000000),
    fabricKind: kind,
    clocks: [
      HarborClockConfig.fixed(
        name: 'sys',
        frequency: 50000000,
        sourceFrequency: 50000000,
        isPrimary: true,
      ),
      HarborClockConfig.fixed(
        name: 'pixel',
        frequency: 25000000,
        sourceFrequency: 50000000,
      ),
      HarborClockConfig.fixed(
        name: 'shift',
        frequency: 125000000,
        sourceFrequency: 50000000,
      ),
    ],
  );
  final cpu = soc.addMaster(_Cpu(kind));
  _Hammer? hammer;
  if (c.hammer) {
    hammer = soc.addMaster(
      _Hammer(kind),
      busInterfaceName: 'bus',
      memory: true,
      outstanding: kind == HarborFabricKind.wishbone ? 1 : 2,
      writeStallFree: true,
    );
  }
  soc.addPeripheral(
    HarborSram(
      baseAddress: mem,
      size: 0x2000,
      busAddressWidth: 32,
      dataWidth: 64,
      protocol: kind,
    ),
  );
  final display = soc.addFabricScanoutDisplay(
    memory: BusAddressRange(mem, 0x2000),
    timing: HarborDisplayTiming(
      hActive: c.hActive,
      hFrontPorch: 8,
      hSyncWidth: 2,
      hBackPorch: c.lineClocks - c.hActive - 10,
      vActive: c.vActive,
      vFrontPorch: 1,
      vSyncWidth: 1,
      vBackPorch: 1,
      pixelClock: 25000000,
    ),
    formats: [c.format],
    baseAddress: displayBase,
    busDataWidth: 64,
    burstBeats: c.burstBeats,
    realtime: c.realtime,
  );
  cpu.pullUp(soc);
  hammer?.pullUp(soc);
  soc.buildFabric();

  final clk = SimpleClockGenerator(20).clk;
  final pixelClk = SimpleClockGenerator(40).clk;
  final shift = SimpleClockGenerator(8).clk;
  final reset = Logic(name: 'reset')..inject(1);
  soc.input('clk').srcConnection! <= clk;
  soc.input('pixel_clk').srcConnection! <= pixelClk;
  soc.input('shift_clk').srcConnection! <= shift;
  soc.input('reset').srcConnection! <= reset;
  final bus = RegBus.attach(soc, clk, name: 'cpu', kind: kind);
  await soc.build();
  bus.idle();
  // The traffic master's inputs are 0 before the first clock.
  for (final n in soc.inputs.keys.where((n) => n.startsWith('hammer_w_'))) {
    soc.input(n).srcConnection!.put(0);
  }
  Simulator.setMaxSimTime(200000000);
  unawaited(Simulator.run());
  for (var i = 0; i < 8; i++) {
    await clk.nextPosedge;
  }
  reset.inject(0);
  for (var i = 0; i < 4; i++) {
    await clk.nextPosedge;
  }
  final run = FetchRun(c, soc, display, bus, clk, pixelClk);
  if (c.hammer) {
    final sim = Sim(soc, clk: clk)
      ..attach()
      ..running = true;
    run.hammer = WaistRequester(
      sim,
      'hammer_w',
      Random(5),
      errors: run.errors,
      idle: 0,
      stall: 0,
    );
  }

  if (writeFrame) await run.writePicture(c.fbOffset, 0);
  return run;
}
