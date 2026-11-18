// The scanout display as a real-time fabric master: a 64 bit AXI4 SoC with
// the framebuffer in an SRAM that the firmware placed. Every pixel of a
// frame is checked, and UNDERRUN_COUNT stays 0.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

const _mem = 0x80000000;
const _displayBase = 0x10008000;

// A small mode: 16x4 pixels. A line takes 48 clocks, enough for the fetch of
// a line across the clock crossing and the fabric.
const _timing = HarborDisplayTiming(
  hActive: 16,
  hFrontPorch: 14,
  hSyncWidth: 2,
  hBackPorch: 16,
  vActive: 4,
  vFrontPorch: 1,
  vSyncWidth: 1,
  vBackPorch: 1,
  pixelClock: 25000000,
);

/// An AXI4-Lite register master of 64 bits with plain `p_<PORT>` ports.
class _Cpu extends BridgeModule {
  _Cpu() : super('FabricFetchCpu', name: 'cpu') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final intf = Axi4LiteInterface(addressWidth: 32, dataWidth: 64);
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

int _rgb565(int x, int y) =>
    ((y * 3 + x) & 0x1f) << 11 | (x * 4 + y) << 5 | (x ^ y) & 0x1f;

List<int> _expand(int h) {
  final r = (h >> 11) & 0x1f, g = (h >> 5) & 0x3f, b = h & 0x1f;
  return [(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)];
}

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'axi4 64 bit: the display reads a framebuffer through the fabric',
    () async {
      final soc = HarborSoC(
        name: 'FabricFetchSoC',
        compatible: 'test,fabricfetch',
        target: const HarborSimTarget(frequency: 25000000),
        fabricKind: HarborFabricKind.axi4,
        clocks: [
          HarborClockConfig.fixed(
            name: 'sys',
            frequency: 25000000,
            sourceFrequency: 25000000,
            isPrimary: true,
          ),
          HarborClockConfig.fixed(
            name: 'pixel',
            frequency: 25000000,
            sourceFrequency: 25000000,
          ),
          HarborClockConfig.fixed(
            name: 'shift',
            frequency: 125000000,
            sourceFrequency: 25000000,
          ),
        ],
      );
      final cpu = soc.addMaster(_Cpu());
      final ram = soc.addPeripheral(
        HarborSram(
          baseAddress: _mem,
          size: 0x2000,
          busAddressWidth: 32,
          dataWidth: 64,
          protocol: HarborFabricKind.axi4,
        ),
      );
      expect(ram.baseAddress, _mem);
      final display = soc.addFabricScanoutDisplay(
        memory: BusAddressRange(_mem, 0x2000),
        timing: _timing,
        baseAddress: _displayBase,
        busDataWidth: 64,
      );
      cpu.pullUp(soc);
      soc.buildFabric();
      // Bursts of 16 beats of 8 bytes: 128 bytes a line, 16 pixels of 16 bits
      // fill a quarter of it.
      expect(display.strides, [128]);

      final clk = SimpleClockGenerator(40).clk;
      final shift = SimpleClockGenerator(8).clk;
      final reset = Logic(name: 'reset')..inject(1);
      soc.input('clk').srcConnection! <= clk;
      soc.input('reset').srcConnection! <= reset;
      soc.input('shift_clk').srcConnection! <= shift;
      final bus = RegBus.attach(
        soc,
        clk,
        name: 'cpu',
        kind: HarborFabricKind.axi4,
      );
      await soc.build();
      bus.idle();
      Simulator.setMaxSimTime(40000000);
      unawaited(Simulator.run());
      for (var i = 0; i < 8; i++) {
        await clk.nextPosedge;
      }
      reset.inject(0);
      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
      }

      // Write the frame, 4 pixels of a line in each 64 bit word.
      for (var y = 0; y < 4; y++) {
        for (var w = 0; w < 4; w++) {
          var v = BigInt.zero;
          for (var k = 0; k < 4; k++) {
            v |= BigInt.from(_rgb565(w * 4 + k, y)) << (16 * k);
          }
          await bus.accessWide(_mem + y * 128 + w * 8, data: v, write: true);
        }
      }
      await bus.write(_displayBase + HarborScanoutDisplay.fbBaseOffset, _mem);
      await bus.write(_displayBase + HarborScanoutDisplay.ctrlOffset, 1);

      // Collect the pixels of each frame from the display.
      final d = display.display;
      final frames = <Map<(int, int), List<int>>>[{}];
      var last = false;
      clk.posedge.listen((_) {
        final de = d.output('de').value;
        if (de.isValid && de.toBool()) {
          final x = d.output('x').value.toInt();
          final y = d.output('y').value.toInt();
          if (x == 0 && y == 0 && last == false) frames.add({});
          frames.last[(x, y)] = [
            d.output('red').value.toInt(),
            d.output('green').value.toInt(),
            d.output('blue').value.toInt(),
          ];
          last = true;
        } else {
          last = false;
        }
      });
      for (var i = 0; i < 1500; i++) {
        await clk.nextPosedge;
      }
      final full = frames.where((f) => f.length == 16 * 4).toList();
      expect(full.length, greaterThanOrEqualTo(2), reason: 'frames $frames');
      for (final f in full.skip(1)) {
        for (var y = 0; y < 4; y++) {
          for (var x = 0; x < 16; x++) {
            expect(f[(x, y)], _expand(_rgb565(x, y)), reason: 'pixel $x,$y');
          }
        }
      }
      expect(
        await bus.read(_displayBase + HarborScanoutDisplay.underrunCountOffset),
        0,
      );
      expect(
        (await bus.read(_displayBase + HarborScanoutDisplay.statusOffset)) &
            0x14,
        0,
        reason: 'no underrun, no bus error',
      );
      await Simulator.endSimulation();
    },
  );
}
