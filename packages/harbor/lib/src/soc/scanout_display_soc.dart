import 'dart:math';

import 'package:rohd/rohd.dart';

import '../bus/bus.dart';
import '../clock/clock_domain.dart';
import '../peripherals/display.dart';
import '../peripherals/harbor_sdram.dart';
import '../peripherals/scanout_display.dart';
import 'harbor_soc.dart';
import 'target.dart';

/// The memory bandwidth of a scanout, against the peak of an sdram.
///
/// The display reads each active line once for each frame. The peak is the
/// bus width of the sdram at its clock, one word for each cycle. Refresh,
/// row changes and the arbiter take some of the peak, so a build keeps the
/// scanout below [maxShare] of it.
class HarborScanoutBandwidth {
  /// Part of the sdram peak that a scanout may use.
  static const defaultMaxShare = 0.9;

  final HarborDisplayTiming timing;
  final HarborPixelFormat format;

  /// Data width of the sdram in bits.
  final int sdramDataBits;

  /// Clock of the sdram in Hz.
  final int sdramClockHz;

  const HarborScanoutBandwidth({
    required this.timing,
    required this.format,
    required this.sdramDataBits,
    required this.sdramClockHz,
  });

  /// Bytes in the active part of a frame.
  int get frameBytes => format.lineBytes(0, timing.hActive) * timing.vActive;

  /// Bytes that the scanout reads each second.
  double get bytesPerSecond => frameBytes * timing.refreshRate;

  /// Bytes that the sdram moves each second at most.
  double get peakBytesPerSecond => sdramDataBits / 8 * sdramClockHz;

  /// [bytesPerSecond] as a part of [peakBytesPerSecond].
  double get share => bytesPerSecond / peakBytesPerSecond;

  /// The part of the peak that the other bus masters can use, before the
  /// refresh and row change cost.
  double get remainingShare => 1 - share;

  /// Throws an [ArgumentError] when [share] is above [maxShare].
  void check({double maxShare = defaultMaxShare}) {
    if (share <= maxShare) return;
    throw ArgumentError(
      '${timing.resolution} ${format.name} needs '
      '${(bytesPerSecond / 1e6).toStringAsFixed(1)} MB/s, which is '
      '${(share * 100).toStringAsFixed(0)}% of the '
      '${(peakBytesPerSecond / 1e6).toStringAsFixed(1)} MB/s of the sdram '
      '(the limit is ${(maxShare * 100).toStringAsFixed(0)}%)',
    );
  }
}

/// The scanout display helper of a [HarborSoC].
extension HarborSocScanoutDisplay on HarborSoC {
  /// Adds a display that scans [sdram] through its scanout port.
  ///
  /// It builds a [HarborScanoutDisplay] at [baseAddress], joins its scanout
  /// port to the sdram port 0 in both directions, runs the scanout side on
  /// `scan_clk`, and gates the enable bit with the sdram `init_done`. It
  /// pulls the four video lanes up as the pin [pinName], ordered blue,
  /// green, red, clock, and the display `interrupt` output stays on the
  /// display for the interrupt wiring.
  ///
  /// [busAddressWidth] and [busDataWidth] are the widths of the fabric, which
  /// every slave port must match.
  ///
  /// The shift and pixel clocks come from the domains [shiftDomain] and
  /// [pixelDomain]. When the SoC has no such domain, the helper adds them
  /// from one PLL with [HarborScanoutDisplay.clockConfig], at [pixelClockHz]
  /// (the pixel clock of [timing] by default) from the source clock of the
  /// `sys` domain. On an ECP5 the PLL must give the shift clock of 5 times the
  /// pixel clock exactly, so the helper takes the nearest pixel clock that the
  /// PLL reaches, 25.0 MHz for 25.175 MHz from a 25 MHz source. The build
  /// throws an [ArgumentError] with the nearest clock when that clock is more
  /// than [pixelClockTolerancePpm] away from the wanted one. The default of
  /// 10000 ppm takes 25.0 MHz for 25.175 MHz, an error of 0.7%. The pixel clock
  /// of the display is the real rate of [pixelDomain], not the one in
  /// [timing].
  ///
  /// [framebuffer] says who places the framebuffer. With
  /// [HarborFramebufferPlacement.firmware] the helper takes no
  /// [framebufferBase]: the sdram `memory` node covers all of the sdram, the
  /// tree has no `reserved-memory` node and no `simple-framebuffer` node, the
  /// display node has no `memory-region`, FB_BASE resets to 0 and the display
  /// is off after a reset. The firmware makes the framebuffer, reserves it,
  /// and adds the nodes for the OS.
  ///
  /// With [HarborFramebufferPlacement.fixed], [framebufferBase] is the start of the framebuffer region. It must be
  /// aligned to a page of the sdram, and so must [framebufferSize]. The
  /// region is a `reserved-memory` node with `no-map`, a `shared-dma-pool`
  /// that the display driver takes its buffers from, so no other part of the
  /// system uses it. The region must end at the top of the sdram, and the
  /// `memory` node of the sdram ends at [framebufferBase], because the firmware
  /// reads `/memory` only and does not read `reserved-memory`. [simpleFramebuffer] adds a `simple-framebuffer` node for
  /// the same region, for the firmware and early boot, and it is on by default
  /// only with [enableOnReset], because a display that is off shows nothing
  /// for the firmware to hand over. The driver takes over from it.
  /// [framebufferBase] and the size are multiples of 4096. [framebufferSize]
  /// is two blocks of the next power of two of one frame by default, because
  /// the dma pool gives out blocks of a power of two.
  ///
  /// The line deadline is guaranteed by [HarborSdram.scanoutLineBound]: the
  /// sdram gives the bus port nothing while the scanout port has a request
  /// or a read in flight, so a line never takes longer than the bound, and
  /// the build throws when the bound and one bus request do not fit in the
  /// line period. The sdram must have a [HarborSdram.scanoutLine] that covers
  /// the mode (see [HarborScanoutLine.forMode]). The display has no buffer
  /// beyond the double line buffer, so the guarantee rests on that bound
  /// alone.
  ///
  /// [runningPin], [underrunPin], [updatePendingPin], [busErrorPin] and
  /// [memReadyPin] pull the status outputs of the display up as pins. A
  /// pin that is null is not pulled up.
  ///
  /// The stride of each format is [HarborSdram.scanoutStride] of its line,
  /// so each line starts on a new row. The build fails with an
  /// [ArgumentError] when a format needs more than [maxBandwidthShare] of the
  /// sdram bandwidth, see [HarborScanoutBandwidth].
  ///
  /// ```dart
  /// final soc = HarborSoC(
  ///   name: 'Delta',
  ///   compatible: 'river,delta',
  ///   target: target,
  ///   clocks: [HarborClockConfig.fixed(name: 'sys', frequency: 25000000,
  ///       sourceFrequency: 25000000, isPrimary: true)],
  /// );
  /// final sdram = soc.addPeripheral(HarborSdram(
  ///   config: const HarborSdramConfig.as4c16m16sb6(),
  ///   baseAddress: 0x80000000,
  ///   clockHz: 25000000,
  ///   busClockSync: true,
  ///   scanoutPorts: 1,
  ///   scanoutLine: HarborScanoutLine.forMode(
  ///     timing: const HarborDisplayTiming.vga640x480(),
  ///     formats: const [HarborPixelFormat.rgb565],
  ///     pixelClockHz: 25000000,
  ///     sdramClockHz: 25000000,
  ///   ),
  ///   target: target,
  /// ));
  /// final display = soc.addScanoutDisplay(
  ///   sdram: sdram,
  ///   timing: const HarborDisplayTiming.vga640x480(),
  ///   pixelClockHz: 25000000,
  ///   framebufferBase: 0x80100000,
  ///   baseAddress: 0x10008000,
  /// );
  /// ```
  HarborScanoutDisplay addScanoutDisplay({
    required HarborSdram sdram,
    required HarborDisplayTiming timing,
    List<HarborPixelFormat> formats = const [HarborPixelFormat.rgb565],
    HarborFramebufferPlacement framebuffer = HarborFramebufferPlacement.fixed,
    int? framebufferBase,
    int? framebufferSize,
    required int baseAddress,
    int? pixelClockHz,
    int pixelClockTolerancePpm = 10000,
    String shiftDomain = 'shift',
    String pixelDomain = 'pixel',
    String? busDomain,
    int busAddressWidth = 32,
    int busDataWidth = 32,
    String pinName = 'gpdi_dp',
    double maxBandwidthShare = HarborScanoutBandwidth.defaultMaxShare,
    bool? simpleFramebuffer,
    bool enableOnReset = false,
    String? runningPin,
    String? underrunPin,
    String? updatePendingPin,
    String? busErrorPin,
    String? memReadyPin,
    String name = 'display',
  }) {
    final target = this.target;
    if (target == null) {
      throw StateError('a scanout display needs a SoC target');
    }
    if (sdram.scanoutPorts < 1) {
      throw ArgumentError.value(
        sdram.scanoutPorts,
        'sdram',
        'needs scanoutPorts of 1',
      );
    }
    final firmwarePlaces = framebuffer == HarborFramebufferPlacement.firmware;
    if (firmwarePlaces && (framebufferBase != null || enableOnReset)) {
      throw ArgumentError(
        'a framebuffer that the firmware places has no framebufferBase, and '
        'the display is off after a reset',
      );
    }
    if (!firmwarePlaces && framebufferBase == null) {
      throw ArgumentError.notNull('framebufferBase');
    }
    final page = sdram.config.pageBytes;
    final sdramEnd = sdram.baseAddress + sdram.config.sizeBytes;
    final strides = [
      for (final f in formats)
        sdram.scanoutStride(f.lineBytes(0, timing.hActive)),
    ];
    final frame = strides.reduce(max) * timing.vActive;
    // The dma pool hands out blocks of a power of two, so one buffer takes
    // the next power of two of a frame, and the pool holds two of them.
    var block = 1;
    while (block < frame) {
      block <<= 1;
    }
    final size = framebufferSize ?? 2 * block;
    if (size < block) {
      throw ArgumentError.value(
        size,
        'framebufferSize',
        'the dma pool needs $block bytes for one buffer of $frame bytes',
      );
    }
    final fbBase = framebufferBase;
    if (fbBase != null) {
      if (fbBase % page != 0 ||
          size % page != 0 ||
          fbBase % 4096 != 0 ||
          size % 4096 != 0) {
        throw ArgumentError(
          'the framebuffer base and size must be multiples of the sdram page '
          'size $page and of 4096',
        );
      }
      if (fbBase < sdram.baseAddress || fbBase + size > sdramEnd) {
        throw ArgumentError(
          'the framebuffer must lie inside the sdram, from '
          '0x${sdram.baseAddress.toRadixString(16)} to '
          '0x${sdramEnd.toRadixString(16)}',
        );
      }
      if (fbBase + size != sdramEnd) {
        throw ArgumentError(
          'the framebuffer must end at the top of the sdram, 0x'
          '${sdramEnd.toRadixString(16)}: the firmware reads /memory only, so '
          'the memory node ends at the framebuffer base and nothing may lie '
          'above it',
        );
      }
    }

    var shift = clockDomain(shiftDomain);
    var pixel = clockDomain(pixelDomain);
    if ((shift == null) != (pixel == null)) {
      throw StateError(
        'give both the $shiftDomain and $pixelDomain domains, or neither',
      );
    }
    if (shift == null) {
      final sys = clockDomain('sys');
      final source = sys?.config.sourceFrequency;
      if (sys == null || source == null) {
        throw StateError(
          'add a sys domain with a source frequency before the display '
          'domains, so the bus clock stays the sys clock',
        );
      }
      shift = addClockDomain(
        HarborScanoutDisplay.clockConfig(
          pixelClockHz: _reachablePixelClock(
            target,
            source,
            pixelClockHz ?? timing.pixelClock,
            pixelClockTolerancePpm,
          ),
          sourceClockHz: source,
          shiftName: shiftDomain,
          pixelName: pixelDomain,
        ),
      );
      pixel = clockDomain(pixelDomain)!;
    }
    final realPixelHz = pixel!.config.frequency;
    if (shift.config.frequency != 5 * realPixelHz) {
      throw StateError(
        'the $shiftDomain clock must be 5 times the $pixelDomain clock',
      );
    }
    final mode = HarborDisplayTiming(
      hActive: timing.hActive,
      hFrontPorch: timing.hFrontPorch,
      hSyncWidth: timing.hSyncWidth,
      hBackPorch: timing.hBackPorch,
      vActive: timing.vActive,
      vFrontPorch: timing.vFrontPorch,
      vSyncWidth: timing.vSyncWidth,
      vBackPorch: timing.vBackPorch,
      pixelClock: realPixelHz,
      hSyncPositive: timing.hSyncPositive,
      vSyncPositive: timing.vSyncPositive,
    );
    for (final f in formats) {
      HarborScanoutBandwidth(
        timing: mode,
        format: f,
        sdramDataBits: sdram.config.dataWidth,
        sdramClockHz: sdram.clockHz,
      ).check(maxShare: maxBandwidthShare);
    }

    // The sdram must hold the bus port back for this line, and the worst
    // case line fetch must fit in the line period.
    final need = HarborScanoutLine.forMode(
      timing: mode,
      formats: formats,
      pixelClockHz: realPixelHz,
      sdramClockHz: sdram.clockHz,
      wordBytes: sdram.config.dataWidth ~/ 8,
    );
    final have = sdram.scanoutLine;
    if (have == null ||
        have.words < need.words ||
        have.periodCycles > need.periodCycles) {
      throw ArgumentError(
        'build the sdram with scanoutLine: $need, so the bus port yields to '
        'the scanout (the sdram has $have)',
      );
    }
    if (!HarborSdram.scanoutLineFits(
      sdram.cycles,
      sdram.config,
      need.words,
      need.periodCycles,
      maxInFlight: sdram.scanoutMaxInFlight,
      syncCycles: need.syncCycles,
    )) {
      final bound = HarborSdram.scanoutLineBound(
        sdram.cycles,
        sdram.config,
        need.words,
        periodCycles: need.periodCycles,
        maxInFlight: sdram.scanoutMaxInFlight,
      );
      throw ArgumentError(
        'the worst case line fetch of ${mode.resolution} takes $bound '
        'cycles, which leaves no room in the line period of '
        '${need.periodCycles} cycles at ${sdram.clockHz} Hz',
      );
    }

    if (fbBase != null) sdram.firmwareReservedBytes = sdramEnd - fbBase;

    final gate = sdram.tryOutput('init_done') != null;
    final display = addPeripheral(
      HarborScanoutDisplay(
        baseAddress: baseAddress,
        timing: mode,
        formats: formats,
        strides: strides,
        framebufferBase: fbBase ?? 0,
        placement: framebuffer,
        scanoutMemory: BusAddressRange(
          sdram.baseAddress,
          sdram.config.sizeBytes,
        ),
        framebufferSize: size,
        target: target,
        simpleFramebuffer:
            !firmwarePlaces && (simpleFramebuffer ?? enableOnReset),
        enableOnReset: enableOnReset,
        gateOnInitDone: gate,
        fabricKind: fabricKind,
        busAddressWidth: busAddressWidth,
        busDataWidth: busDataWidth,
        name: name,
      ),
      clockDomainName: busDomain,
    );
    display.input('pixel_clk').srcConnection! <= pixel.clk;
    display.input('pixel_reset').srcConnection! <= pixel.reset;
    display.input('shift_clk').srcConnection! <= shift.clk;
    display.input('shift_reset').srcConnection! <= shift.reset;
    display.input('scan_clk').srcConnection! <= sdram.output('scan_clk');
    display.input('scan_reset').srcConnection! <= sdram.output('scan_reset');
    display.input('rq_ready').srcConnection! <= sdram.output('scan0_rq_ready');
    display.input('rd_valid').srcConnection! <= sdram.output('scan0_rd_valid');
    display.input('rd_data').srcConnection! <= sdram.output('scan0_rd_data');
    sdram.input('scan0_rq_valid').srcConnection! <= display.output('rq_valid');
    sdram.input('scan0_rq_addr').srcConnection! <= display.output('rq_addr');
    sdram.input('scan0_rq_words').srcConnection! <= display.output('rq_words');
    if (gate) {
      display.input('init_done').srcConnection! <= sdram.output('init_done');
    }
    display.input('error_in').srcConnection! <= Const(0);
    exposePin(display, 'gpdi', externalName: pinName);
    if (display.tryOutput('gpdi_n') != null) {
      exposePin(
        display,
        'gpdi_n',
        externalName: '${pinName.replaceFirst('dp', 'dn')}',
      );
    }
    for (final (port, pin) in [
      ('running', runningPin),
      ('underrun', underrunPin),
      ('update_pending', updatePendingPin),
      ('bus_error', busErrorPin),
      ('mem_ready', memReadyPin),
    ]) {
      if (pin != null) exposePin(display, port, externalName: pin);
    }
    return display;
  }

  /// Adds a display that reads the framebuffer from [memory] through the
  /// fabric, as a real-time master with bursts of [burstBeats] beats.
  ///
  /// The display builds with [HarborScanoutDisplay.fabricMemory], and the
  /// helper joins its `fb` port with `addMaster(realtime: true)` and
  /// `targetRanges: [memory]`. The framebuffer is placed by the firmware: the
  /// display node has no `memory-region`, FB_BASE resets to 0 and the display
  /// is off after a reset. The display node names [memory] in
  /// `harbor,scanout-memory`. Pixel and shift clocks, the pin and the status
  /// pins work as in [addScanoutDisplay]. The stride of a format is the line
  /// bytes rounded up to [burstBeats] words of the bus.
  ///
  /// [memory] is the address range of a memory that the display reads.
  /// [busDataWidth] is the width of the fabric.
  HarborScanoutDisplay addFabricScanoutDisplay({
    required BusAddressRange memory,
    required HarborDisplayTiming timing,
    List<HarborPixelFormat> formats = const [HarborPixelFormat.rgb565],
    required int baseAddress,
    int? pixelClockHz,
    int pixelClockTolerancePpm = 10000,
    String shiftDomain = 'shift',
    String pixelDomain = 'pixel',
    String? busDomain,
    int busAddressWidth = 32,
    int busDataWidth = 32,
    int burstBeats = 16,
    String pinName = 'gpdi_dp',
    String? runningPin,
    String? underrunPin,
    String? updatePendingPin,
    String? busErrorPin,
    String name = 'display',
  }) {
    final target = this.target;
    if (target == null) {
      throw StateError('a scanout display needs a SoC target');
    }
    final wordBytes = busDataWidth ~/ 8;
    final step = burstBeats * wordBytes;
    final strides = [
      for (final f in formats)
        (f.lineBytes(0, timing.hActive) + step - 1) ~/ step * step,
    ];
    final frame = strides.reduce(max) * timing.vActive;

    var shift = clockDomain(shiftDomain);
    var pixel = clockDomain(pixelDomain);
    if ((shift == null) != (pixel == null)) {
      throw StateError(
        'give both the $shiftDomain and $pixelDomain domains, or neither',
      );
    }
    if (shift == null) {
      final sys = clockDomain('sys');
      final source = sys?.config.sourceFrequency;
      if (sys == null || source == null) {
        throw StateError(
          'add a sys domain with a source frequency before the display '
          'domains, so the bus clock stays the sys clock',
        );
      }
      shift = addClockDomain(
        HarborScanoutDisplay.clockConfig(
          pixelClockHz: _reachablePixelClock(
            target,
            source,
            pixelClockHz ?? timing.pixelClock,
            pixelClockTolerancePpm,
          ),
          sourceClockHz: source,
          shiftName: shiftDomain,
          pixelName: pixelDomain,
        ),
      );
      pixel = clockDomain(pixelDomain)!;
    }
    final realPixelHz = pixel!.config.frequency;
    if (shift.config.frequency != 5 * realPixelHz) {
      throw StateError(
        'the $shiftDomain clock must be 5 times the $pixelDomain clock',
      );
    }
    final mode = HarborDisplayTiming(
      hActive: timing.hActive,
      hFrontPorch: timing.hFrontPorch,
      hSyncWidth: timing.hSyncWidth,
      hBackPorch: timing.hBackPorch,
      vActive: timing.vActive,
      vFrontPorch: timing.vFrontPorch,
      vSyncWidth: timing.vSyncWidth,
      vBackPorch: timing.vBackPorch,
      pixelClock: realPixelHz,
      hSyncPositive: timing.hSyncPositive,
      vSyncPositive: timing.vSyncPositive,
    );

    final display = addPeripheral(
      HarborScanoutDisplay(
        baseAddress: baseAddress,
        timing: mode,
        formats: formats,
        strides: strides,
        framebufferBase: 0,
        placement: HarborFramebufferPlacement.firmware,
        scanoutMemory: memory,
        framebufferSize: frame,
        target: target,
        simpleFramebuffer: false,
        fabricMemory: true,
        burstBeats: burstBeats,
        fabricKind: fabricKind,
        busAddressWidth: busAddressWidth,
        busDataWidth: busDataWidth,
        name: name,
      ),
      clockDomainName: busDomain,
    );
    display.input('pixel_clk').srcConnection! <= pixel.clk;
    display.input('pixel_reset').srcConnection! <= pixel.reset;
    display.input('shift_clk').srcConnection! <= shift.clk;
    display.input('shift_reset').srcConnection! <= shift.reset;
    addMaster(
      display,
      busInterfaceName: 'fb',
      memory: true,
      outstanding: 2,
      realtime: true,
      writeStallFree: true,
      targetRanges: [memory],
      burstRanges: [memory],
    );
    exposePin(display, 'gpdi', externalName: pinName);
    if (display.tryOutput('gpdi_n') != null) {
      exposePin(
        display,
        'gpdi_n',
        externalName: pinName.replaceFirst('dp', 'dn'),
      );
    }
    for (final (port, pin) in [
      ('running', runningPin),
      ('underrun', underrunPin),
      ('update_pending', updatePendingPin),
      ('bus_error', busErrorPin),
    ]) {
      if (pin != null) exposePin(display, port, externalName: pin);
    }
    return display;
  }
}

/// The pixel clock of an ECP5 PLL that is nearest to [wantHz] and that has a
/// shift clock of exactly 5 times its rate from [sourceHz]. Other targets keep
/// [wantHz]. Throws when the nearest clock is more than [tolerancePpm] away.
int _reachablePixelClock(
  HarborDeviceTarget target,
  int sourceHz,
  int wantHz,
  int tolerancePpm,
) {
  if (target is! HarborFpgaTarget || target.vendor != HarborFpgaVendor.ecp5) {
    return wantHz;
  }
  final candidates = <int>{};
  for (var div = 1; div <= 128; div++) {
    for (var mult = 1; mult <= 80; mult++) {
      final shift = sourceHz * mult;
      if (shift % (div * 5) == 0) candidates.add(shift ~/ (div * 5));
    }
  }
  final ordered = candidates.toList()
    ..sort((a, b) => (a - wantHz).abs().compareTo((b - wantHz).abs()));
  for (final pixel in ordered) {
    try {
      HarborClockGenerator.ecp5CoSecondaryDividers(sourceHz, 5 * pixel, pixel);
    } on ArgumentError {
      continue;
    }
    final ppm = (pixel - wantHz).abs() * 1000000 / wantHz;
    if (ppm > tolerancePpm) {
      throw ArgumentError(
        'no ECP5 PLL setting makes a pixel clock of $wantHz Hz from '
        '$sourceHz Hz within $tolerancePpm ppm, the nearest is $pixel Hz '
        '(${ppm.toStringAsFixed(0)} ppm)',
      );
    }
    return pixel;
  }
  throw ArgumentError(
    'no ECP5 PLL setting makes a pixel clock of $wantHz Hz from $sourceHz Hz',
  );
}
