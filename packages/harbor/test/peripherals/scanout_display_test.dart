import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

const _timing = HarborDisplayTiming(
  hActive: 16,
  hFrontPorch: 2,
  hSyncWidth: 3,
  hBackPorch: 4,
  vActive: 8,
  vFrontPorch: 2,
  vSyncWidth: 1,
  vBackPorch: 3,
  pixelClock: 1000000,
  hSyncPositive: true,
);

const _fbBase = 0x80010000;
const _ctrl = HarborScanoutDisplay.ctrlOffset;
const _status = HarborScanoutDisplay.statusOffset;
const _fb = HarborScanoutDisplay.fbBaseOffset;
const _stride = HarborScanoutDisplay.fbStrideOffset;
const _intStatus = HarborScanoutDisplay.intStatusOffset;
const _intEnable = HarborScanoutDisplay.intEnableOffset;
const _format = HarborScanoutDisplay.formatOffset;

bool _high(Logic s) {
  final v = s.previousValue ?? s.value;
  return v.isValid && v.toBool();
}

/// The memory side of a sdram scanout port. A request is taken, `rq_ready`
/// is low for one clock, and the words come [latency] clocks later, one for
/// each clock.
class _ScanPort {
  final HarborScanoutDisplay dut;
  final Logic clk;
  static const latency = 3;
  final ready = Logic(name: 'm_ready');
  final valid = Logic(name: 'm_valid');
  final data = Logic(name: 'm_data', width: 16);

  /// While true, the port takes no request and returns no data.
  bool stall = false;

  /// Every request taken, as the byte address and the words.
  final requests = <(int, int)>[];

  final _words = <(int, int)>[];
  int _cycle = 0;
  bool _afterTake = false;

  _ScanPort(this.dut, this.clk) {
    dut.input('rq_ready').srcConnection! <= ready;
    dut.input('rd_valid').srcConnection! <= valid;
    dut.input('rd_data').srcConnection! <= data;
    for (final l in [ready, valid, data]) {
      l.inject(0);
    }
    clk.posedge.listen((_) => _edge());
    clk.negedge.listen((_) => _drive());
  }

  void _edge() {
    _cycle++;
    final take =
        !stall &&
        _high(dut.output('rq_valid')) &&
        (ready.previousValue ?? ready.value).toBool();
    _afterTake = take;
    if (take) {
      final addr =
          (dut.output('rq_addr').previousValue ?? dut.output('rq_addr').value)
              .toInt();
      final words =
          (dut.output('rq_words').previousValue ?? dut.output('rq_words').value)
              .toInt();
      requests.add((addr, words));
      for (var i = 0; i < words; i++) {
        _words.add((_cycle + latency + i, addr + 2 * i));
      }
    }
  }

  void _drive() {
    ready.inject(stall || _afterTake ? 0 : 1);
    if (!stall && _words.isNotEmpty && _words.first.$1 <= _cycle) {
      final w = _words.removeAt(0);
      valid.inject(1);
      data.inject(w.$2 & 0xffff);
    } else {
      valid.inject(0);
      data.inject(0);
    }
  }
}

class _Rig {
  final HarborScanoutDisplay dut;
  final Logic clk = SimpleClockGenerator(4).clk;
  final Logic pixelClk = SimpleClockGenerator(8).clk;
  final reset = Logic(name: 'reset');
  final pixelReset = Logic(name: 'pixel_reset');
  final initDone = Logic(name: 'init_done');
  final busErr = Logic(name: 'error_in');
  late final RegBus bus;
  late final _ScanPort port;

  _Rig(this.dut);

  Future<void> start() async {
    dut.input('clk').srcConnection! <= clk;
    dut.input('reset').srcConnection! <= reset;
    dut.input('scan_clk').srcConnection! <= clk;
    dut.input('scan_reset').srcConnection! <= reset;
    dut.input('pixel_clk').srcConnection! <= pixelClk;
    dut.input('pixel_reset').srcConnection! <= pixelReset;
    final shift = Logic(name: 'shift')..inject(0);
    dut.input('shift_clk').srcConnection! <= shift;
    dut.input('shift_reset').srcConnection! <= shift;
    if (dut.gateOnInitDone) {
      dut.input('init_done').srcConnection! <= initDone;
      initDone.inject(1);
    }
    dut.input('error_in').srcConnection! <= busErr;
    busErr.inject(0);
    bus = RegBus.attach(dut, clk);
    port = _ScanPort(dut, clk);
    await dut.build();
    reset.inject(1);
    pixelReset.inject(1);
    bus.idle();
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    pixelReset.inject(0);
    await clk.nextPosedge;
  }

  /// Clocks until [done] is true, within [limit] clocks.
  Future<void> until(bool Function() done, {int limit = 4000}) async {
    for (var i = 0; i < limit; i++) {
      if (done()) return;
      await clk.nextPosedge;
    }
    throw StateError('condition not met in $limit clocks');
  }

  Future<void> pendingClears() async {
    await until(() => false == _high(dut.updatePending), limit: 6000);
  }
}

HarborScanoutDisplay _display({
  List<HarborPixelFormat> formats = const [HarborPixelFormat.rgb565],
  List<int>? strides,
  bool gate = false,
  bool enableOnReset = false,
  HarborFabricKind kind = HarborFabricKind.wishbone,
  int busDataWidth = 32,
}) => HarborScanoutDisplay(
  baseAddress: 0x10008000,
  timing: _timing,
  formats: formats,
  strides:
      strides ?? [for (final f in formats) f.lineBytes(0, _timing.hActive) * 2],
  framebufferBase: _fbBase,
  framebufferSize: 0x4000,
  target: const HarborSimTarget(),
  gateOnInitDone: gate,
  enableOnReset: enableOnReset,
  fabricKind: kind,
  busDataWidth: busDataWidth,
);

void main() {
  tearDown(() async => Simulator.reset());

  group('HarborScanoutDisplay build', () {
    test('rejects a format a scanout cannot show', () {
      expect(
        () => _display(formats: [HarborPixelFormat.yuyv]),
        throwsArgumentError,
      );
    });

    test('rejects a short stride and a small region', () {
      expect(() => _display(strides: [16]), throwsArgumentError);
      expect(
        () => HarborScanoutDisplay(
          baseAddress: 0x10008000,
          timing: _timing,
          strides: [64],
          framebufferBase: _fbBase,
          framebufferSize: 64,
          target: const HarborSimTarget(),
        ),
        throwsArgumentError,
      );
    });

    test('names differ for different builds', () {
      final a = _display();
      final b = _display(enableOnReset: true);
      final c = _display(
        formats: [HarborPixelFormat.rgb565, HarborPixelFormat.xrgb8888],
      );
      expect({
        a.definitionName,
        b.definitionName,
        c.definitionName,
      }, hasLength(3));
    });
  });

  for (final (kind, width) in [
    for (final k in HarborFabricKind.values) (k, 32),
    (HarborFabricKind.axi4, 64),
  ]) {
    test(
      'reset values and the fixed registers over ${kind.name} $width',
      () async {
        final r = _Rig(_display(kind: kind, busDataWidth: width));
        await r.start();
        expect(await r.bus.read(_ctrl), 0);
        expect(await r.bus.read(_fb), _fbBase);
        expect(await r.bus.read(_stride), 64);
        expect(await r.bus.read(HarborScanoutDisplay.hActiveOffset), 16);
        expect(
          await r.bus.read(HarborScanoutDisplay.hTimingOffset),
          2 | (3 << 10) | (4 << 20) | (1 << 30),
        );
        expect(await r.bus.read(HarborScanoutDisplay.vActiveOffset), 8);
        expect(
          await r.bus.read(HarborScanoutDisplay.vTimingOffset),
          2 | (1 << 10) | (3 << 20),
        );
        expect(
          await r.bus.read(HarborScanoutDisplay.pixelClockOffset),
          1000000,
        );
        expect(await r.bus.read(_format), 0);
        expect(await r.bus.read(HarborScanoutDisplay.formatsOffset), 1);
        expect(await r.bus.read(_intStatus), 0);
        expect(await r.bus.read(_intEnable), 0);
        expect(await r.bus.read(0x70), 0, reason: 'an unused offset reads 0');
        await Simulator.endSimulation();
      },
    );
  }

  test(
    'CTRL and INT_ENABLE read back, a write with no byte changes nothing',
    () async {
      final r = _Rig(_display());
      await r.start();
      await r.bus.write(_intEnable, 0x7);
      expect(await r.bus.read(_intEnable), 7);
      await r.bus.write(_intEnable, 0xffffffff, sel: 0);
      expect(await r.bus.read(_intEnable), 7);
      await r.bus.write(_intEnable, 0xfffffff8);
      expect(await r.bus.read(_intEnable), 0, reason: 'only 3 bits exist');
      await r.bus.write(_ctrl, 1, sel: 0);
      expect(await r.bus.read(_ctrl), 0);
      await r.bus.write(_ctrl, 1);
      expect(await r.bus.read(_ctrl), 1);
      await r.bus.write(_ctrl, 0);
      expect(await r.bus.read(_ctrl), 0);
      await Simulator.endSimulation();
    },
  );

  test('read only registers ignore a write', () async {
    final r = _Rig(_display());
    await r.start();
    for (final off in [
      _status,
      _stride,
      HarborScanoutDisplay.hActiveOffset,
      HarborScanoutDisplay.hTimingOffset,
      HarborScanoutDisplay.vActiveOffset,
      HarborScanoutDisplay.vTimingOffset,
      HarborScanoutDisplay.pixelClockOffset,
      HarborScanoutDisplay.formatsOffset,
    ]) {
      final before = await r.bus.read(off);
      await r.bus.write(off, 0x5a5a5a5a);
      expect(await r.bus.read(off), before, reason: 'offset $off');
    }
    await Simulator.endSimulation();
  });

  test('FB_BASE takes effect at a frame start', () async {
    final r = _Rig(_display());
    await r.start();
    await r.pendingClears();
    await r.bus.write(_ctrl, 1);
    await r.until(() => (r.dut.running.value.toInt() == 1));
    expect(await r.bus.read(_status) & 1, 1);

    const next = _fbBase + 0x2000;
    r.port.requests.clear();
    await r.bus.write(_fb, next | 3);
    expect(
      await r.bus.read(_fb),
      _fbBase,
      reason: 'the old value stays until the frame start',
    );
    expect(await r.bus.read(_status) & 2, 2, reason: 'update pending');
    await r.pendingClears();
    await r.clk.nextPosedge;
    expect(await r.bus.read(_fb), next, reason: 'low 2 bits read 0');
    expect(await r.bus.read(_status) & 2, 0);

    // The frame after the take reads the new base.
    await r.until(() => r.port.requests.any((q) => q.$1 == next), limit: 6000);
    final oldAfter = r.port.requests.skipWhile((q) => q.$1 != next);
    expect(oldAfter.every((q) => q.$1 >= next), isTrue);
    await Simulator.endSimulation();
  });

  test('a write while an update is pending waits for it', () async {
    final r = _Rig(_display());
    await r.start();
    await r.pendingClears();
    await r.bus.write(_fb, _fbBase + 0x1000);
    await r.bus.write(_fb, _fbBase + 0x2000);
    await r.pendingClears();
    await r.until(() => true);
    for (var i = 0; i < 4; i++) {
      await r.clk.nextPosedge;
    }
    await r.pendingClears();
    expect(await r.bus.read(_fb), _fbBase + 0x2000);
    await Simulator.endSimulation();
  });

  test('the display is off until the sdram is ready', () async {
    final r = _Rig(_display(gate: true));
    await r.start();
    r.initDone.inject(0);
    await r.pendingClears();
    await r.bus.write(_ctrl, 1);
    await r.pendingClears();
    for (var i = 0; i < 1500; i++) {
      await r.clk.nextPosedge;
    }
    expect(await r.bus.read(_status), 0, reason: 'not ready, not running');
    expect(r.port.requests, isEmpty);
    r.initDone.inject(1);
    await r.until(() => r.dut.running.value.toInt() == 1, limit: 8000);
    expect(await r.bus.read(_status) & 0x9, 0x9);
    await r.until(() => r.port.requests.isNotEmpty, limit: 4000);
    await Simulator.endSimulation();
  });

  test('enableOnReset starts the display', () async {
    final r = _Rig(_display(enableOnReset: true));
    await r.start();
    expect(await r.bus.read(_ctrl), 1);
    await r.until(() => r.dut.running.value.toInt() == 1, limit: 8000);
    await Simulator.endSimulation();
  });

  test(
    'vblank sets INT_STATUS, drives the interrupt and clears with W1C',
    () async {
      final r = _Rig(_display());
      await r.start();
      await r.pendingClears();
      expect(r.dut.interrupt.value.toInt(), 0);
      await r.until(() => (r.dut.output('update_pending').value.toInt() == 0));

      // A vblank sets the status, with the interrupt off.
      await r.until(
        () =>
            false == _high(r.dut.interrupt) &&
            r.dut.display.vblank.value.toInt() == 1,
      );
      expect(await r.bus.read(_intStatus) & 1, 1);
      expect(r.dut.interrupt.value.toInt(), 0, reason: 'not enabled');

      await r.bus.write(_intEnable, 1);
      await r.until(() => r.dut.interrupt.value.toInt() == 1, limit: 100);
      // Writing 0 clears nothing. Writing the bit clears it.
      await r.bus.write(_intStatus, 0);
      expect(await r.bus.read(_intStatus) & 1, 1);
      await r.bus.write(_intStatus, 1);
      // The interrupt rises again at the next vblank, one frame later.
      var low = false;
      await r.until(() {
        if (r.dut.interrupt.value.toInt() == 0) low = true;
        return low && r.dut.interrupt.value.toInt() == 1;
      }, limit: 4000);
      expect(low, isTrue);
      await r.bus.write(_intEnable, 0);
      await r.bus.write(_intStatus, 1);
      expect(r.dut.interrupt.value.toInt(), 0);
      await Simulator.endSimulation();
    },
  );

  test('an underrun is sticky until INT_STATUS clears it', () async {
    final r = _Rig(_display());
    await r.start();
    await r.pendingClears();
    r.port.stall = true;
    await r.bus.write(_ctrl, 1);
    await r.until(() => r.dut.underrun.value.toInt() == 1, limit: 8000);
    expect(await r.bus.read(_status) & 4, 4);
    expect(await r.bus.read(_intStatus) & 2, 2);
    r.port.stall = false;
    // The flag stays after the display recovered.
    for (var i = 0; i < 1500; i++) {
      await r.clk.nextPosedge;
    }
    expect(await r.bus.read(_status) & 4, 4);
    await r.bus.write(_intStatus, 2);
    expect(await r.bus.read(_status) & 4, 0);
    expect(await r.bus.read(_intStatus) & 2, 0);
    // No underrun comes back with data in time.
    for (var i = 0; i < 3000; i++) {
      await r.clk.nextPosedge;
    }
    expect(await r.bus.read(_status) & 4, 0);
    await Simulator.endSimulation();
  });

  test(
    'a bus error is sticky, drives the interrupt and clears with W1C',
    () async {
      final r = _Rig(_display());
      await r.start();
      expect(await r.bus.read(_status) & 0x10, 0);
      await r.bus.write(_intEnable, 4);
      expect(r.dut.interrupt.value.toInt(), 0);
      r.busErr.inject(1);
      await r.clk.nextPosedge;
      await r.clk.nextPosedge;
      r.busErr.inject(0);
      await r.until(() => r.dut.interrupt.value.toInt() == 1, limit: 20);
      expect(await r.bus.read(_status) & 0x10, 0x10);
      expect(await r.bus.read(_intStatus) & 4, 4);
      await r.bus.write(_intStatus, 3);
      expect(await r.bus.read(_intStatus) & 4, 4, reason: 'other bits only');
      await r.bus.write(_intStatus, 4);
      expect(await r.bus.read(_intStatus) & 4, 0);
      expect(await r.bus.read(_status) & 0x10, 0);
      expect(r.dut.interrupt.value.toInt(), 0);
      await Simulator.endSimulation();
    },
  );

  test('a build with two formats selects the format and the stride', () async {
    final r = _Rig(
      _display(
        formats: [HarborPixelFormat.rgb565, HarborPixelFormat.xrgb8888],
        strides: [64, 128],
      ),
    );
    await r.start();
    expect(await r.bus.read(HarborScanoutDisplay.formatsOffset), 0x5);
    expect(await r.bus.read(_format), 0);
    expect(await r.bus.read(_stride), 64);
    await r.pendingClears();

    await r.bus.write(_format, 1);
    await r.bus.write(_fb, _fbBase);
    await r.pendingClears();
    for (var i = 0; i < 4; i++) {
      await r.clk.nextPosedge;
    }
    expect(await r.bus.read(_format), 0, reason: 'code 1 is not supported');

    await r.bus.write(_format, 2);
    expect(await r.bus.read(_format), 0, reason: 'FORMAT changes at the take');
    await r.bus.write(_fb, _fbBase);
    await r.pendingClears();
    for (var i = 0; i < 4; i++) {
      await r.clk.nextPosedge;
    }
    expect(await r.bus.read(_format), 2);
    expect(await r.bus.read(_stride), 128);
    await Simulator.endSimulation();
  });

  group('device tree, ACPI and SVD', () {
    test('the node values', () {
      final d = _display(
        formats: [HarborPixelFormat.rgb565, HarborPixelFormat.xrgb8888],
        strides: [64, 128],
      );
      final dt = d.dtNode;
      expect(dt.compatible, ['harbor,display']);
      expect(dt.reg.start, 0x10008000);
      expect(dt.reg.size, 0x1000);
      expect(dt.properties['harbor,hactive'], 16);
      expect(dt.properties['harbor,formats'], ['r5g6b5', 'x8r8g8b8']);
      expect(dt.properties['harbor,strides'], [64, 128]);
      expect(d.extraDtNodes.single.properties['format'], 'r5g6b5');
      expect(d.reservedMemory.single.range.start, _fbBase);
      final acpi = d.acpiDevice;
      expect(acpi.hid, 'PRP0001');
      expect(acpi.properties, isNot(contains('harbor,fb-base')));
      expect(acpi.memory, hasLength(1));
      final svd = d.svdPeripheral;
      expect(svd.registers!.validate(), isEmpty);
      expect(svd.registers!.fieldOffset('fb_base'), _fb);
    });

    test('no simple-framebuffer node when it is off', () {
      final d = HarborScanoutDisplay(
        baseAddress: 0x10008000,
        timing: _timing,
        strides: [32],
        framebufferBase: _fbBase,
        framebufferSize: 0x4000,
        target: const HarborSimTarget(),
        simpleFramebuffer: false,
      );
      expect(d.extraDtNodes, isEmpty);
    });
  });
}
