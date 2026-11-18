import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../arith/fpu_config.dart' show harborStableDefinitionName;
import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../bus/port/memory_port.dart';
import '../bus/port/memory_waist.dart';
import '../clock/clock_domain.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../soc/target.dart';
import '../video/dual_clock_display.dart';
import 'device_register.dart';
import 'display.dart';

/// Who places the framebuffer of a [HarborScanoutDisplay].
enum HarborFramebufferPlacement {
  /// The build fixes the framebuffer pool. The device tree has a
  /// `reserved-memory` node for it and a `simple-framebuffer` node in
  /// `/chosen`, and FB_BASE resets to the pool base.
  fixed,

  /// The firmware places the framebuffer. The device tree has no
  /// `reserved-memory` node, no `simple-framebuffer` node and no
  /// `memory-region` on the display node. FB_BASE resets to 0 and the display
  /// is off after a reset.
  firmware,
}

/// A display with a register block, scanning an sdram through its scanout
/// port.
///
/// The module holds a [HarborDualClockDisplay] and the registers that drive
/// it. Software sets the enable bit and the framebuffer address, and the
/// display takes the change at the next frame start. The register port
/// runs on `clk`, the scanout port on `scan_clk` (the sdram `scan_clk`) and
/// the video on `pixel_clk` and `shift_clk`.
///
/// Each register has its own 8-byte slot, so a 32-bit access lands in the
/// low word on a 32-bit and on a 64-bit fabric. The window is 0x1000 bytes.
///
/// | offset | name        | access | content |
/// |--------|-------------|--------|---------|
/// | 0x00   | CTRL        | rw     | bit 0 enable |
/// | 0x08   | STATUS      | ro     | bit 0 running, 1 update pending, 2 underrun (sticky), 3 memory ready |
/// | 0x10   | FB_BASE     | rw     | framebuffer byte address, bits 1:0 read 0 |
/// | 0x18   | FB_STRIDE   | ro     | bytes from one line to the next |
/// | 0x20   | H_ACTIVE    | ro     | active pixels of a line |
/// | 0x28   | H_TIMING    | ro     | 9:0 front porch, 19:10 sync, 29:20 back porch, 30 sync high |
/// | 0x30   | V_ACTIVE    | ro     | active lines |
/// | 0x38   | V_TIMING    | ro     | like H_TIMING, in lines |
/// | 0x40   | INT_STATUS  | rw1c   | bit 0 vblank, bit 1 underrun, bit 2 bus error |
/// | 0x48   | INT_ENABLE  | rw     | one bit for each INT_STATUS bit |
/// | 0x50   | PIXEL_CLOCK | ro     | pixel clock in Hz |
/// | 0x58   | FORMAT      | rw     | pixel format code in use, see [harborPixelFormatBitOrder] |
/// | 0x60   | FORMATS     | ro     | bit n is set when format code n is supported |
/// | 0x68   | UNDERRUN_COUNT | ro  | 15:0 underruns since reset, saturating |
///
/// With [fabricMemory] the display reads the framebuffer through a memory
/// master port `fb` of the fabric kind, with bursts of [burstBeats] beats, so
/// it can read any memory of the SoC. It has no `rq_*`, `rd_*`, `scan_*` and
/// `init_done` ports, and the scanout runs on `clk`. Add it to a SoC with
/// `addMaster(display, busInterfaceName: 'fb', memory: true, realtime: true)`.
/// FB_STRIDE is a multiple of [burstBeats] words of the bus.
///
/// A write to CTRL or FB_BASE starts an update. The display copies CTRL,
/// FB_BASE and FORMAT together and takes them at the next frame start, so
/// write FORMAT first and FB_BASE last. A write to FORMAT with a code that
/// the build does not support changes nothing. FB_BASE, FB_STRIDE and
/// FORMAT read the value that the display uses now, so they change at the
/// frame start after the write. CTRL reads the last written value. STATUS
/// bit 1 is high from the write until the frame start, and an update that
/// comes while it is high waits for it. It stays high while the pixel clock
/// is stopped.
///
/// FB_STRIDE is read only. A scanout port needs each line to start on a new
/// sdram row, so the only legal stride is the one from
/// [HarborSdram.scanoutStride] for the format. A build with more than one
/// format gives the stride of the format in use.
///
/// The display runs only when the sdram is ready: the register block ANDs
/// the enable bit with `init_done` when the build has that input. STATUS bit
/// 3 shows it, and bit 0 shows the enable that the display took.
///
/// The input `error_in` is a one clock pulse for a bus error on a
/// framebuffer read. It sets INT_STATUS bit 2 and STATUS bit 4, with the
/// pulse of the display for a memory waist build. The sdram scanout port has
/// no error response, so a SoC with that port ties it to 0.
///
/// INT_STATUS bit 0 sets at the start of each vertical blank. Bit 1 sets
/// when the display reports an underrun, and is also STATUS bit 2. A write
/// of 1 to a bit clears it. `interrupt` is high while a bit of INT_STATUS
/// and INT_ENABLE is high.
///
/// FB_BASE is 0x0 after a reset unless the build has [framebufferBase],
/// which is the reset value. The display is off after a reset unless
/// [enableOnReset] is set.
class HarborScanoutDisplay extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider,
        HarborReservedMemoryProvider {
  /// Size of the register window in bytes.
  static const windowBytes = 0x1000;

  static const ctrlOffset = 0x00;
  static const statusOffset = 0x08;
  static const fbBaseOffset = 0x10;
  static const fbStrideOffset = 0x18;
  static const hActiveOffset = 0x20;
  static const hTimingOffset = 0x28;
  static const vActiveOffset = 0x30;
  static const vTimingOffset = 0x38;
  static const intStatusOffset = 0x40;
  static const intEnableOffset = 0x48;
  static const pixelClockOffset = 0x50;
  static const formatOffset = 0x58;
  static const formatsOffset = 0x60;
  static const underrunCountOffset = 0x68;

  /// STATUS bit: the display took the enable bit.
  static const statusRunning = 1 << 0;

  /// STATUS bit: an update waits for the next frame start.
  static const statusUpdatePending = 1 << 1;

  /// STATUS bit: an underrun happened, until a write to INT_STATUS clears it.
  static const statusUnderrun = 1 << 2;

  /// STATUS bit: the sdram finished its init.
  static const statusMemoryReady = 1 << 3;

  /// INT_STATUS bit: a vertical blank started.
  static const intVblank = 1 << 0;

  /// INT_STATUS bit: the display ran out of data.
  static const intUnderrun = 1 << 1;

  /// INT_STATUS bit: a read of the framebuffer ended with a bus error.
  static const intBusError = 1 << 2;

  /// STATUS bit: a bus error happened, until a write to INT_STATUS clears it.
  static const statusBusError = 1 << 4;

  /// The pixel formats a scanout display can show.
  static const supportedFormats = [
    HarborPixelFormat.rgb565,
    HarborPixelFormat.xrgb8888,
    HarborPixelFormat.argb8888,
  ];

  /// The PLL clock config for the shift and pixel clocks of a display. One
  /// PLL makes both: the shift clock, 5 times the pixel clock, on CLKOP and
  /// the pixel clock on CLKOS. Give it to [HarborSoC.new] in `clocks`, or let
  /// [HarborSocScanoutDisplay.addScanoutDisplay] add it.
  static HarborClockConfig clockConfig({
    required int pixelClockHz,
    required int sourceClockHz,
    String shiftName = 'shift',
    String pixelName = 'pixel',
  }) => HarborClockConfig(
    name: shiftName,
    rate: HarborFixedClockRate(pixelClockHz * 5),
    sourceFrequency: sourceClockHz,
    coClkosSecondary: (
      name: pixelName,
      frequency: pixelClockHz,
      tolerancePpm: 0,
    ),
  );

  /// Base address of the register window.
  final int baseAddress;

  /// The video mode. The pixel clock is the real rate of `pixel_clk`.
  final HarborDisplayTiming timing;

  /// The formats of the build. The first one is the format after a reset.
  final List<HarborPixelFormat> formats;

  /// Bytes from one line to the next, for each of [formats].
  final List<int> strides;

  /// First byte of the framebuffer region, and the reset value of FB_BASE.
  final int framebufferBase;

  /// Size of the framebuffer region in bytes.
  final int framebufferSize;

  /// The sdram span that the scanout port reads, or null when unknown. It is
  /// the `harbor,scanout-memory` property of the node, so the firmware can
  /// place the framebuffer where the display can read it.
  final BusAddressRange? scanoutMemory;

  /// Who places the framebuffer, see [HarborFramebufferPlacement].
  final HarborFramebufferPlacement placement;

  /// True when the node tree has a `simple-framebuffer` node for the
  /// region, for the firmware and early boot.
  final bool simpleFramebuffer;

  /// True when the display is on after a reset.
  final bool enableOnReset;

  /// True when the display reads the framebuffer through the memory master
  /// port [fb] and has no sdram scanout port.
  final bool fabricMemory;

  /// Beats of a framebuffer burst, with [fabricMemory].
  final int burstBeats;

  /// The memory master port of a build with [fabricMemory].
  late final HarborMemoryMasterPort fb;

  /// True when the build has the `init_done` input.
  final bool gateOnInitDone;

  /// Label of the reserved memory node.
  String get reservedLabel =>
      '${name}_fb'.replaceAll(RegExp('[^a-zA-Z0-9_]'), '_');

  /// Address width of the register port. It is the width of the fabric.
  final int busAddressWidth;

  /// Data width of the register port, the width of the fabric. The registers
  /// are 32 bits wide and sit in the low word.
  final int busDataWidth;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// The display behind the registers.
  late final HarborDualClockDisplay display;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  /// The display took the enable bit.
  Logic get running => output('running');

  /// An update waits for the next frame start.
  Logic get updatePending => output('update_pending');

  /// An underrun happened and INT_STATUS did not clear it.
  Logic get underrun => output('underrun');

  /// Underruns since reset, saturating at 0xffff (UNDERRUN_COUNT).
  Logic get underrunCount => output('underrun_count');

  /// A bus error happened and INT_STATUS did not clear it.
  Logic get busError => output('bus_error');

  /// The sdram finished its init (STATUS bit 3).
  Logic get memReady => output('mem_ready');

  /// The four serialized video lanes, ordered blue, green, red, clock.
  Logic get gpdi => output('gpdi');

  HarborScanoutDisplay({
    required this.baseAddress,
    required this.timing,
    this.formats = const [HarborPixelFormat.rgb565],
    required this.strides,
    required this.framebufferBase,
    required this.framebufferSize,
    required HarborDeviceTarget target,
    this.scanoutMemory,
    this.placement = HarborFramebufferPlacement.fixed,
    this.simpleFramebuffer = true,
    this.enableOnReset = false,
    bool? gateOnInitDone,
    this.fabricMemory = false,
    this.burstBeats = 16,
    HarborFabricKind fabricKind = HarborFabricKind.wishbone,
    this.busAddressWidth = 12,
    this.busDataWidth = 32,
    bool crossFabricClock = false,
    super.name = 'display',
  }) : gateOnInitDone = gateOnInitDone ?? !fabricMemory,
       super(
         harborStableDefinitionName('HarborScanoutDisplay', [
           ...BusSlavePort.definitionNameParts(
             kind: fabricKind,
             addressWidth: busAddressWidth,
             dataWidth: busDataWidth,
             cross: crossFabricClock,
           ),
           'f${formats.map(harborPixelFormatBitOrder.indexOf).join('x')}',
           's${strides.join('x')}',
           'h${timing.hActive}_${timing.hFrontPorch}_${timing.hSyncWidth}_'
               '${timing.hBackPorch}${timing.hSyncPositive ? 'p' : 'n'}',
           'v${timing.vActive}_${timing.vFrontPorch}_${timing.vSyncWidth}_'
               '${timing.vBackPorch}${timing.vSyncPositive ? 'p' : 'n'}',
           'c${timing.pixelClock}',
           'b${framebufferBase.toRadixString(16)}',
           if (placement == HarborFramebufferPlacement.firmware) 'fw',
           if (enableOnReset) 'on',
           if (gateOnInitDone ?? !fabricMemory) 'g',
           if (fabricMemory) 'fm$burstBeats',
           target is HarborFpgaTarget ? target.vendor.name : 'generic',
         ]),
       ) {
    _check();
    if (fabricMemory && this.gateOnInitDone) {
      throw ArgumentError(
        'a display with fabricMemory reads the fabric, which has no init_done '
        'to gate on',
      );
    }
    if (fabricMemory && crossFabricClock) {
      throw ArgumentError(
        'a display with fabricMemory runs its fb port on the clk of the '
        'register port, so crossFabricClock is not supported',
      );
    }
    final multi = formats.length > 1;

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('pixel_clk', PortDirection.input);
    createPort('pixel_reset', PortDirection.input);
    createPort('shift_clk', PortDirection.input);
    createPort('shift_reset', PortDirection.input);
    if (!fabricMemory) {
      createPort('scan_clk', PortDirection.input);
      createPort('scan_reset', PortDirection.input);
      createPort('rq_ready', PortDirection.input);
      createPort('rd_valid', PortDirection.input);
      createPort('rd_data', PortDirection.input, width: 16);
      if (this.gateOnInitDone) createPort('init_done', PortDirection.input);
      createPort('error_in', PortDirection.input);
    }

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      kind: fabricKind,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: busAddressWidth,
      dataWidth: busDataWidth,
      fabricClock: BusSlavePort.fabricClockInputs(
        this,
        cross: crossFabricClock,
      ),
    );
    final clk = input('clk');
    final reset = bus.reset;

    final fmtBits = max(1, (formats.length - 1).bitLength);
    int abi(HarborPixelFormat f) => harborPixelFormatBitOrder.indexOf(f);

    // Low bits of the word address that FB_BASE ignores.
    final alignBits = fabricMemory ? (busDataWidth ~/ 8).bitLength - 3 : 0;
    final resetFb = framebufferBase >> 2;
    final enableStage = Logic(name: 'enable_stage');
    final fbStage = Logic(name: 'fb_stage', width: 30);
    final fmtStage = Logic(name: 'fmt_stage', width: fmtBits);
    final snapFb = Logic(name: 'fb_snap', width: 30);
    final snapFmt = Logic(name: 'fmt_snap', width: fmtBits);
    final activeFb = Logic(name: 'fb_active', width: 30);
    final activeFmt = Logic(name: 'fmt_active', width: fmtBits);
    final dirty = Logic(name: 'dirty');
    final update = Logic(name: 'update');
    final pendingPrev = Logic(name: 'pending_prev');
    final vblankFlag = Logic(name: 'int_vblank');
    final underrunFlag = Logic(name: 'int_underrun');
    final busErrorFlag = Logic(name: 'int_bus_error');
    final intStatus = [busErrorFlag, underrunFlag, vblankFlag].concat();
    final intEnable = Logic(name: 'int_enable', width: 3);
    final vblankPrev = Logic(name: 'vblank_prev');
    final underrunPrev = Logic(name: 'underrun_prev');
    final enablePrev = Logic(name: 'enable_prev');

    // The sdram init flag crosses into the register clock.
    Logic memReady;
    if (this.gateOnInitDone) {
      memReady = input('init_done');
      for (var i = 0; i < 2; i++) {
        memReady = flop(clk, memReady, reset: reset).named('init_done_sync$i');
      }
    } else {
      memReady = Const(1);
    }
    final enableEff = (enableStage & memReady).named('enable_eff');

    Logic byFormat(Logic sel, List<int> values, int width) {
      if (!multi) return Const(values.first, width: width);
      Logic out = Const(values.last, width: width);
      for (var i = values.length - 2; i >= 0; i--) {
        out = mux(sel.eq(i), Const(values[i], width: width), out);
      }
      return out;
    }

    final stagePitch = byFormat(fmtStage, strides, 32).named('stage_pitch');
    final activeStride = byFormat(
      activeFmt,
      strides,
      32,
    ).named('active_stride');
    final activeCode = byFormat(activeFmt, [
      for (final f in formats) abi(f),
    ], 8).named('active_code');

    if (fabricMemory) {
      fb = HarborMemoryMasterPort.create(
        module: this,
        name: 'fb',
        kind: fabricKind,
        config: HarborMemoryWaistConfig(
          addressWidth: 32,
          dataWidth: busDataWidth,
          idWidth: 1,
          outstanding: 2,
        ),
        clk: clk,
        reset: input('reset'),
        readOnly: true,
      );
    }

    display = HarborDualClockDisplay(
      target: target,
      timing: timing,
      pixelClk: input('pixel_clk'),
      pixelReset: input('pixel_reset'),
      shiftClk: input('shift_clk'),
      shiftReset: input('shift_reset'),
      sysClk: fabricMemory ? clk : input('scan_clk'),
      sysReset: fabricMemory ? reset : input('scan_reset'),
      controlClk: clk,
      controlReset: reset,
      enable: enableEff,
      update: update,
      fbBase: [fbStage, Const(0, width: 2)].concat(),
      memory: fabricMemory ? fb.waist : null,
      burstWords: burstBeats,
      rqReady: fabricMemory ? null : input('rq_ready'),
      rdValid: fabricMemory ? null : input('rd_valid'),
      rdData: fabricMemory ? null : input('rd_data'),
      lineStride: multi ? null : strides.first,
      formats: formats,
      formatSel: multi ? fmtStage : null,
      planePitch: multi ? [stagePitch] : const [],
      outputType: HarborDisplayInterface.dvi,
    );

    if (!fabricMemory) {
      addOutput('rq_valid') <= display.rqValid;
      addOutput('rq_addr', width: 32) <= display.rqAddr;
      addOutput('rq_words', width: display.rqWords.width) <= display.rqWords;
    }
    addOutput('gpdi', width: 4) <= display.gpdi;
    if (display.tryOutput('gpdi_n') != null) {
      addOutput('gpdi_n', width: 4) <= display.gpdiN;
    }
    addOutput('interrupt');
    addOutput('running') <= display.active;
    addOutput('update_pending');
    addOutput('underrun');
    addOutput('underrun_count', width: 16);
    addOutput('bus_error');
    addOutput('mem_ready');

    final pending = display.updatePending;
    final anyPending = (pending | dirty | update).named('any_pending');
    output('update_pending') <= anyPending;
    final vblankEvent = display.vblank & ~vblankPrev;
    final busErrorEvent =
        (fabricMemory ? display.busError : display.busError | input('error_in'))
            .named('bus_error_event');
    final underrunCounter = Logic(name: 'underrun_counter', width: 16);
    // The display counts late and skipped lines. Without that count, the
    // register block counts frames of an underrun.
    final lineCount =
        display.tryOutput('underrun_count') ??
        display.tryOutput('plane_underrun_count_0');
    final underrunEvent = display.underrun & ~underrunPrev;
    output('interrupt') <= (intStatus & intEnable).or();
    output('underrun') <= underrunFlag;
    output('underrun_count') <= (lineCount ?? underrunCounter);
    output('bus_error') <= busErrorFlag;
    output('mem_ready') <= memReady;

    final statusWord = [
      Const(0, width: 27),
      busErrorFlag,
      memReady,
      underrunFlag,
      anyPending,
      display.active,
    ].concat();

    final writeAny = bus.stb & ~bus.ack & bus.we;
    Logic writeAt(int offset, {int bytes = 4}) =>
        writeAny &
        bus.windowAddr(windowBytes).eq(Const(offset, width: 12)) &
        bus.selAny(offset, bytes);
    final writeCtrl = writeAt(ctrlOffset, bytes: 1).named('write_ctrl');
    final writeFb = writeAt(fbBaseOffset).named('write_fb_base');
    final formatCode = bus.dataIn.getRange(0, 8);

    final fbMerged = bus.selMerge(
      [fbStage, Const(0, width: 2)].concat(),
      fbBaseOffset,
    );
    final intClear = bus.selMasked(intStatusOffset, 3);
    final intMerged = bus.selMerge(intEnable, intEnableOffset);

    final fire = (dirty & ~pending & ~update).named('update_fire');
    final took = (pendingPrev & ~pending).named('update_took');
    final enableChanged = (enableEff ^ enablePrev).named('enable_changed');

    Sequential(
      clk,
      reset: reset,
      resetValues: {
        enableStage: enableOnReset ? 1 : 0,
        fbStage: resetFb,
        fmtStage: 0,
        snapFb: resetFb,
        snapFmt: 0,
        activeFb: resetFb,
        activeFmt: 0,
        dirty: 0,
        update: 0,
        pendingPrev: 0,
        vblankFlag: 0,
        underrunFlag: 0,
        busErrorFlag: 0,
        intEnable: 0,
        vblankPrev: 0,
        underrunPrev: 0,
        enablePrev: 0,
        underrunCounter: 0,
      },
      [
        update < fire,
        pendingPrev < pending,
        vblankPrev < display.vblank,
        underrunPrev < display.underrun,
        enablePrev < enableEff,
        If(fire, then: [dirty < Const(0)]),
        If(writeCtrl | writeFb | enableChanged, then: [dirty < Const(1)]),
        If(update, then: [snapFb < fbStage, snapFmt < fmtStage]),
        If(took, then: [activeFb < snapFb, activeFmt < snapFmt]),
        If(writeCtrl, then: [enableStage < bus.dataIn[0]]),
        // A 64 bit waist reads whole beats, so FB_BASE keeps no bit below the
        // beat.
        If(
          writeFb,
          then: [
            fbStage <
                (alignBits == 0
                    ? fbMerged.getRange(2, 32)
                    : [
                        fbMerged.getRange(2 + alignBits, 32),
                        Const(0, width: alignBits),
                      ].concat()),
          ],
        ),
        if (multi)
          If(
            writeAt(formatOffset, bytes: 1),
            then: [
              for (var i = 0; i < formats.length; i++)
                If(
                  formatCode.eq(Const(abi(formats[i]), width: 8)),
                  then: [fmtStage < Const(i, width: fmtBits)],
                ),
            ],
          ),
        // A set wins over a clear in the same clock.
        If(
          writeAt(intStatusOffset),
          then: [
            If(intClear[0], then: [vblankFlag < Const(0)]),
            If(intClear[1], then: [underrunFlag < Const(0)]),
            If(intClear[2], then: [busErrorFlag < Const(0)]),
          ],
        ),
        If(vblankEvent, then: [vblankFlag < Const(1)]),
        If(underrunEvent, then: [underrunFlag < Const(1)]),
        If(
          underrunEvent & underrunCounter.neq(Const(0xffff, width: 16)),
          then: [underrunCounter < underrunCounter + 1],
        ),
        If(busErrorEvent, then: [busErrorFlag < Const(1)]),
        If(writeAt(intEnableOffset), then: [intEnable < intMerged]),
      ],
    );

    final readData = Logic(name: 'read_data', width: 32);
    Combinational([
      readData < Const(0, width: 32),
      Case(bus.windowAddr(windowBytes), [
        CaseItem(Const(ctrlOffset, width: 12), [
          readData < enableStage.zeroExtend(32),
        ]),
        CaseItem(Const(statusOffset, width: 12), [readData < statusWord]),
        CaseItem(Const(fbBaseOffset, width: 12), [
          readData < [activeFb, Const(0, width: 2)].concat(),
        ]),
        CaseItem(Const(fbStrideOffset, width: 12), [readData < activeStride]),
        CaseItem(Const(hActiveOffset, width: 12), [
          readData < Const(timing.hActive, width: 32),
        ]),
        CaseItem(Const(hTimingOffset, width: 12), [
          readData <
              Const(
                _timingWord(
                  timing.hFrontPorch,
                  timing.hSyncWidth,
                  timing.hBackPorch,
                  timing.hSyncPositive,
                ),
                width: 32,
              ),
        ]),
        CaseItem(Const(vActiveOffset, width: 12), [
          readData < Const(timing.vActive, width: 32),
        ]),
        CaseItem(Const(vTimingOffset, width: 12), [
          readData <
              Const(
                _timingWord(
                  timing.vFrontPorch,
                  timing.vSyncWidth,
                  timing.vBackPorch,
                  timing.vSyncPositive,
                ),
                width: 32,
              ),
        ]),
        CaseItem(Const(intStatusOffset, width: 12), [
          readData < intStatus.zeroExtend(32),
        ]),
        CaseItem(Const(intEnableOffset, width: 12), [
          readData < intEnable.zeroExtend(32),
        ]),
        CaseItem(Const(pixelClockOffset, width: 12), [
          readData < Const(timing.pixelClock, width: 32),
        ]),
        CaseItem(Const(formatOffset, width: 12), [
          readData < activeCode.zeroExtend(32),
        ]),
        CaseItem(Const(formatsOffset, width: 12), [
          readData < Const(display.planeFormats.first, width: 32),
        ]),
        CaseItem(Const(underrunCountOffset, width: 12), [
          readData < (lineCount ?? underrunCounter).zeroExtend(32),
        ]),
      ]),
    ]);

    Sequential(
      clk,
      reset: reset,
      resetValues: {bus.ack: 0, bus.dataOut: 0},
      [
        bus.ack < Const(0),
        bus.dataOut < Const(0, width: busDataWidth),
        If(
          bus.stb & ~bus.ack,
          then: [
            bus.ack < Const(1),
            bus.dataOut < readData.zeroExtend(busDataWidth),
          ],
        ),
      ],
    );
  }

  void _check() {
    if (formats.isEmpty) {
      throw ArgumentError.value(formats, 'formats', 'must not be empty');
    }
    for (final f in formats) {
      if (!supportedFormats.contains(f)) {
        throw ArgumentError.value(
          f,
          'formats',
          'a scanout display shows rgb565, xrgb8888 and argb8888',
        );
      }
    }
    if (formats.toSet().length != formats.length) {
      throw ArgumentError.value(formats, 'formats', 'must be distinct');
    }
    if (strides.length != formats.length) {
      throw ArgumentError.value(
        strides,
        'strides',
        'needs one stride for each format',
      );
    }
    for (final (i, f) in formats.indexed) {
      final line = f.lineBytes(0, timing.hActive);
      final step = fabricMemory ? burstBeats * (busDataWidth ~/ 8) : 4;
      if (strides[i] < line || strides[i] % step != 0) {
        throw ArgumentError.value(
          strides[i],
          'strides',
          '${f.name} needs a multiple of $step and at least $line',
        );
      }
    }
    if (placement == HarborFramebufferPlacement.firmware &&
        (framebufferBase != 0 || enableOnReset || simpleFramebuffer)) {
      throw ArgumentError(
        'a framebuffer that the firmware places has a framebufferBase of 0, '
        'no simple-framebuffer node, and a display that is off after a reset',
      );
    }
    if (fabricMemory && framebufferBase % (busDataWidth ~/ 8) != 0) {
      throw ArgumentError.value(
        framebufferBase,
        'framebufferBase',
        'must be a multiple of ${busDataWidth ~/ 8} on a fabric memory build',
      );
    }
    if (framebufferBase % 4 != 0 || framebufferBase < 0) {
      throw ArgumentError.value(
        framebufferBase,
        'framebufferBase',
        'must be a multiple of 4',
      );
    }
    final need = [for (final s in strides) s * timing.vActive].reduce(max);
    if (framebufferSize < need) {
      throw ArgumentError.value(
        framebufferSize,
        'framebufferSize',
        'a frame needs $need bytes',
      );
    }
    if (timing.hFrontPorch > 1023 ||
        timing.hSyncWidth > 1023 ||
        timing.hBackPorch > 1023 ||
        timing.vFrontPorch > 1023 ||
        timing.vSyncWidth > 1023 ||
        timing.vBackPorch > 1023) {
      throw ArgumentError('a timing field has at most 10 bits');
    }
  }

  static int _timingWord(int fp, int sync, int bp, bool high) =>
      fp | (sync << 10) | (bp << 20) | ((high ? 1 : 0) << 30);

  static String _fbName(HarborPixelFormat f) => switch (f) {
    HarborPixelFormat.rgb565 => 'r5g6b5',
    HarborPixelFormat.xrgb8888 => 'x8r8g8b8',
    HarborPixelFormat.argb8888 => 'a8r8g8b8',
    _ => throw ArgumentError.value(f, 'format'),
  };

  BusAddressRange get _framebufferRange =>
      BusAddressRange(framebufferBase, framebufferSize);

  Map<String, Object> get _modeProperties => {
    'harbor,hactive': timing.hActive,
    'harbor,hfront-porch': timing.hFrontPorch,
    'harbor,hsync-len': timing.hSyncWidth,
    'harbor,hback-porch': timing.hBackPorch,
    'harbor,hsync-active': timing.hSyncPositive ? 1 : 0,
    'harbor,vactive': timing.vActive,
    'harbor,vfront-porch': timing.vFrontPorch,
    'harbor,vsync-len': timing.vSyncWidth,
    'harbor,vback-porch': timing.vBackPorch,
    'harbor,vsync-active': timing.vSyncPositive ? 1 : 0,
    'harbor,pixel-clock-hz': timing.pixelClock,
    'harbor,formats': [for (final f in formats) _fbName(f)],
    'harbor,strides': strides,
  };

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: const ['harbor,display'],
    reg: BusAddressRange(baseAddress, windowBytes),
    properties: {
      ..._modeProperties,
      if (scanoutMemory != null)
        'harbor,scanout-memory': HarborDeviceTreeRegion(scanoutMemory!),
      if (placement == HarborFramebufferPlacement.fixed)
        'memory-region': HarborDeviceTreeRef(reservedLabel),
    },
  );

  @override
  List<HarborDeviceTreeNode> get chosenDtNodes =>
      !simpleFramebuffer || placement == HarborFramebufferPlacement.firmware
      ? const []
      : [
          HarborDeviceTreeNode(
            compatible: const ['simple-framebuffer'],
            name: 'framebuffer',
            reg: _framebufferRange,
            properties: {
              'width': timing.hActive,
              'height': timing.vActive,
              'stride': strides.first,
              'format': _fbName(formats.first),
            },
          ),
        ];

  @override
  List<HarborReservedMemory> get reservedMemory =>
      placement == HarborFramebufferPlacement.firmware
      ? const []
      : [
          HarborReservedMemory(
            label: reservedLabel,
            name: 'framebuffer',
            range: _framebufferRange,
            compatible: 'shared-dma-pool',
          ),
        ];

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, windowBytes)],
    properties: {
      'compatible': const ['harbor,display'],
      ..._modeProperties,
      if (scanoutMemory != null)
        'harbor,scanout-memory': [scanoutMemory!.start, scanoutMemory!.size],
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'DISPLAY',
    groupName: 'DISPLAY',
    description: 'Scanout display controller',
    baseAddress: baseAddress,
    size: windowBytes,
    registers: HarborDeviceRegisterMap(
      name: 'display',
      fields: [
        HarborDeviceField(
          name: 'ctrl',
          width: 4,
          offset: ctrlOffset,
          resetValue: enableOnReset ? 1 : 0,
        ),
        const HarborDeviceField(
          name: 'status',
          width: 4,
          offset: statusOffset,
          readOnly: true,
        ),
        HarborDeviceField(
          name: 'fb_base',
          width: 4,
          offset: fbBaseOffset,
          resetValue: framebufferBase,
        ),
        HarborDeviceField(
          name: 'fb_stride',
          width: 4,
          offset: fbStrideOffset,
          readOnly: true,
          resetValue: strides.first,
        ),
        HarborDeviceField(
          name: 'h_active',
          width: 4,
          offset: hActiveOffset,
          readOnly: true,
          resetValue: timing.hActive,
        ),
        HarborDeviceField(
          name: 'h_timing',
          width: 4,
          offset: hTimingOffset,
          readOnly: true,
          resetValue: _timingWord(
            timing.hFrontPorch,
            timing.hSyncWidth,
            timing.hBackPorch,
            timing.hSyncPositive,
          ),
        ),
        HarborDeviceField(
          name: 'v_active',
          width: 4,
          offset: vActiveOffset,
          readOnly: true,
          resetValue: timing.vActive,
        ),
        HarborDeviceField(
          name: 'v_timing',
          width: 4,
          offset: vTimingOffset,
          readOnly: true,
          resetValue: _timingWord(
            timing.vFrontPorch,
            timing.vSyncWidth,
            timing.vBackPorch,
            timing.vSyncPositive,
          ),
        ),
        const HarborDeviceField(
          name: 'int_status',
          width: 4,
          offset: intStatusOffset,
        ),
        const HarborDeviceField(
          name: 'int_enable',
          width: 4,
          offset: intEnableOffset,
        ),
        HarborDeviceField(
          name: 'pixel_clock',
          width: 4,
          offset: pixelClockOffset,
          readOnly: true,
          resetValue: timing.pixelClock,
        ),
        HarborDeviceField(
          name: 'format',
          width: 4,
          offset: formatOffset,
          resetValue: harborPixelFormatBitOrder.indexOf(formats.first),
        ),
        HarborDeviceField(
          name: 'formats',
          width: 4,
          offset: formatsOffset,
          readOnly: true,
          resetValue: HarborDualClockDisplay.formatMask(formats),
        ),
      ],
    ),
  );
}
