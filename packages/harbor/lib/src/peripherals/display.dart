import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../util/pretty_string.dart';

/// Display output interface type.
enum HarborDisplayInterface {
  /// Parallel RGB (directly driven from FPGA pins).
  parallelRgb,

  /// VGA (analog RGB via DAC).
  vga,

  /// DVI (digital only, TMDS encoding).
  dvi,

  /// HDMI (DVI + audio/CEC).
  hdmi,

  /// DisplayPort.
  displayPort,

  /// LVDS (for panel displays).
  lvds,

  /// MIPI DSI (for mobile panels).
  mipiDsi,
}

/// Display pixel format.
enum HarborPixelFormat {
  rgb565(16),
  rgb888(24),
  xrgb8888(32),
  argb8888(32);

  final int bitsPerPixel;
  const HarborPixelFormat(this.bitsPerPixel);
}

/// Display timing parameters.
class HarborDisplayTiming with HarborPrettyString {
  /// Horizontal active pixels.
  final int hActive;

  /// Horizontal front porch.
  final int hFrontPorch;

  /// Horizontal sync width.
  final int hSyncWidth;

  /// Horizontal back porch.
  final int hBackPorch;

  /// Vertical active lines.
  final int vActive;

  /// Vertical front porch.
  final int vFrontPorch;

  /// Vertical sync width.
  final int vSyncWidth;

  /// Vertical back porch.
  final int vBackPorch;

  /// Pixel clock in Hz.
  final int pixelClock;

  /// Horizontal sync polarity (true = active high).
  final bool hSyncPositive;

  /// Vertical sync polarity (true = active high).
  final bool vSyncPositive;

  const HarborDisplayTiming({
    required this.hActive,
    required this.hFrontPorch,
    required this.hSyncWidth,
    required this.hBackPorch,
    required this.vActive,
    required this.vFrontPorch,
    required this.vSyncWidth,
    required this.vBackPorch,
    required this.pixelClock,
    this.hSyncPositive = false,
    this.vSyncPositive = false,
  });

  /// VGA 640x480 @ 60 Hz.
  const HarborDisplayTiming.vga640x480()
    : hActive = 640,
      hFrontPorch = 16,
      hSyncWidth = 96,
      hBackPorch = 48,
      vActive = 480,
      vFrontPorch = 10,
      vSyncWidth = 2,
      vBackPorch = 33,
      pixelClock = 25175000,
      hSyncPositive = false,
      vSyncPositive = false;

  /// SVGA (800x600 @ 60 Hz).
  const HarborDisplayTiming.svga800x600()
    : hActive = 800,
      hFrontPorch = 40,
      hSyncWidth = 128,
      hBackPorch = 88,
      vActive = 600,
      vFrontPorch = 1,
      vSyncWidth = 4,
      vBackPorch = 23,
      pixelClock = 40000000,
      hSyncPositive = true,
      vSyncPositive = true;

  /// 720p (1280x720 @ 60 Hz).
  const HarborDisplayTiming.hd720()
    : hActive = 1280,
      hFrontPorch = 110,
      hSyncWidth = 40,
      hBackPorch = 220,
      vActive = 720,
      vFrontPorch = 5,
      vSyncWidth = 5,
      vBackPorch = 20,
      pixelClock = 74250000,
      hSyncPositive = true,
      vSyncPositive = true;

  /// 1080p (1920x1080 @ 60 Hz).
  const HarborDisplayTiming.fhd1080()
    : hActive = 1920,
      hFrontPorch = 88,
      hSyncWidth = 44,
      hBackPorch = 148,
      vActive = 1080,
      vFrontPorch = 4,
      vSyncWidth = 5,
      vBackPorch = 36,
      pixelClock = 148500000,
      hSyncPositive = true,
      vSyncPositive = true;

  /// Total horizontal pixels per line.
  int get hTotal => hActive + hFrontPorch + hSyncWidth + hBackPorch;

  /// Total vertical lines per frame.
  int get vTotal => vActive + vFrontPorch + vSyncWidth + vBackPorch;

  /// Refresh rate in Hz.
  double get refreshRate => pixelClock / (hTotal * vTotal);

  /// Resolution string.
  String get resolution => '${hActive}x$vActive';

  @override
  String toString() => '$resolution @ ${refreshRate.toStringAsFixed(1)} Hz';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborDisplayTiming(\n');
    buf.writeln('${c}resolution: $resolution,');
    buf.writeln('${c}refresh: ${refreshRate.toStringAsFixed(1)} Hz,');
    buf.writeln('${c}pixelClock: ${pixelClock ~/ 1000000} MHz,');
    buf.writeln('${c}hTotal: $hTotal, vTotal: $vTotal,');
    buf.write('$p)');
    return buf.toString();
  }
}

/// Display controller configuration.
class HarborDisplayConfig with HarborPrettyString {
  /// Output interface.
  final HarborDisplayInterface interface_;

  /// Default timing mode.
  final HarborDisplayTiming timing;

  /// Pixel format.
  final HarborPixelFormat pixelFormat;

  /// Maximum horizontal resolution.
  final int maxWidth;

  /// Maximum vertical resolution.
  final int maxHeight;

  const HarborDisplayConfig({
    required this.interface_,
    required this.timing,
    this.pixelFormat = HarborPixelFormat.xrgb8888,
    this.maxWidth = 1920,
    this.maxHeight = 1080,
  });

  @override
  String toString() =>
      'HarborDisplayConfig(${interface_.name}, ${timing.resolution})';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborDisplayConfig(\n');
    buf.writeln('${c}interface: ${interface_.name},');
    buf.writeln('${c}format: ${pixelFormat.name},');
    buf.writeln('${c}max: ${maxWidth}x$maxHeight,');
    buf.writeln(timing.toPrettyString(options.nested()));
    buf.write('$p)');
    return buf.toString();
  }
}

/// Framebuffer display controller.
///
/// Reads pixel data from a framebuffer in memory via DMA and
/// generates video timing signals. Supports multiple output
/// interfaces and resolution modes.
///
/// Register map (each register in its own 64-bit-aligned slot, so a 32-bit
/// access lands in the low word on both a 32-bit and a 64-bit fabric, and the
/// byte-address decode needs no high/low-half selection):
/// - 0x00: CTRL       (enable, interface, pixel format)
/// - 0x08: STATUS     (vblank, underrun)
/// - 0x10: FB_BASE    (framebuffer base address)
/// - 0x18: FB_STRIDE  (bytes per line)
/// - 0x20: H_ACTIVE   (horizontal active pixels)
/// - 0x28: H_TIMING   (front porch, sync, back porch)
/// - 0x30: V_ACTIVE   (vertical active lines)
/// - 0x38: V_TIMING   (front porch, sync, back porch)
/// - 0x40: INT_STATUS (W1C: vblank, underrun)
/// - 0x48: INT_ENABLE
class HarborDisplayController extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// Display configuration.
  final HarborDisplayConfig config;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Bus slave port (register access).
  late final BusSlavePort bus;

  /// Interrupt output (vsync/vblank).
  Logic get interrupt => output('interrupt');

  HarborDisplayController({
    required this.config,
    required this.baseAddress,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborDisplayController', name: name ?? 'display') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('pixel_clk', PortDirection.input);
    addOutput('interrupt');

    // Video output signals
    addOutput('hsync');
    addOutput('vsync');
    addOutput('de'); // data enable
    addOutput('pixel_r', width: 8);
    addOutput('pixel_g', width: 8);
    addOutput('pixel_b', width: 8);

    // DMA master for framebuffer read
    addOutput('fb_addr', width: 32);
    createPort('fb_data', PortDirection.input, width: 32);
    addOutput('fb_stb');
    createPort('fb_ack', PortDirection.input);

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: 12,
      dataWidth: 32,
    );

    final clk = input('clk');
    final reset = input('reset');
    final pixClk = input('pixel_clk');

    // Registers
    final enable = Logic(name: 'enable');
    final fbBase = Logic(name: 'fb_base', width: 32);
    final fbStride = Logic(name: 'fb_stride', width: 16);
    final hActive = Logic(name: 'h_active', width: 12);
    final hFp = Logic(name: 'h_fp', width: 8);
    final hSync = Logic(name: 'h_sync', width: 8);
    final hBp = Logic(name: 'h_bp', width: 8);
    final vActive = Logic(name: 'v_active', width: 12);
    final vFp = Logic(name: 'v_fp', width: 8);
    final vSync = Logic(name: 'v_sync', width: 8);
    final vBp = Logic(name: 'v_bp', width: 8);
    final intStatus = Logic(name: 'int_status', width: 4);
    final intEnable = Logic(name: 'int_enable', width: 4);

    // Pixel counters (driven by pixel clock)
    final hCount = Logic(name: 'h_count', width: 12);
    final vCount = Logic(name: 'v_count', width: 12);

    interrupt <= (intStatus & intEnable).or();

    // Video timing generator (pixel clock domain)
    final hTotal =
        hActive +
        hFp.zeroExtend(12) +
        hSync.zeroExtend(12) +
        hBp.zeroExtend(12);
    final vTotal =
        vActive +
        vFp.zeroExtend(12) +
        vSync.zeroExtend(12) +
        vBp.zeroExtend(12);

    final inHActive = hCount.lt(hActive);
    final inVActive = vCount.lt(vActive);
    final hSyncStart = hActive + hFp.zeroExtend(12);
    final hSyncEnd = hSyncStart + hSync.zeroExtend(12);
    final vSyncStart = vActive + vFp.zeroExtend(12);
    final vSyncEnd = vSyncStart + vSync.zeroExtend(12);

    final inActive = (enable & inHActive & inVActive).named('in_active');
    output('de') <= inActive;
    output('hsync') <= hCount.gte(hSyncStart) & hCount.lt(hSyncEnd);
    output('vsync') <= vCount.gte(vSyncStart) & vCount.lt(vSyncEnd);

    // Framebuffer fetch: during active video, read the current pixel's word
    // and drive RGB. Address = base + row*stride + col*bytesPerPixel. This is a
    // per-pixel combinational fetch in the pixel-clock domain (a real design
    // prefetches a line into a buffer across the pixel/system clock crossing).
    final bpp = config.pixelFormat.bitsPerPixel ~/ 8;
    final fbData = input('fb_data');
    final lineOff = (vCount.zeroExtend(32) * fbStride.zeroExtend(32)).getRange(
      0,
      32,
    );
    final colOff = (hCount.zeroExtend(32) * Const(bpp, width: 32)).getRange(
      0,
      32,
    );
    output('fb_addr') <= (fbBase + lineOff + colOff);
    output('fb_stb') <= inActive;
    // 0xXXRRGGBB byte order: R[23:16], G[15:8], B[7:0]. Blanked outside active.
    output('pixel_r') <=
        mux(inActive, fbData.getRange(16, 24), Const(0, width: 8));
    output('pixel_g') <=
        mux(inActive, fbData.getRange(8, 16), Const(0, width: 8));
    output('pixel_b') <=
        mux(inActive, fbData.getRange(0, 8), Const(0, width: 8));

    Sequential(pixClk, [
      If(
        reset,
        then: [hCount < Const(0, width: 12), vCount < Const(0, width: 12)],
        orElse: [
          If(
            enable,
            then: [
              hCount < (hCount + Const(1, width: 12)),
              If(
                hCount.gte(hTotal),
                then: [
                  hCount < Const(0, width: 12),
                  vCount < (vCount + Const(1, width: 12)),
                  If(vCount.gte(vTotal), then: [vCount < Const(0, width: 12)]),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    // Register access (system clock domain)
    Sequential(clk, [
      If(
        reset,
        then: [
          enable < Const(0),
          fbBase < Const(0, width: 32),
          fbStride <
              Const(
                config.timing.hActive * config.pixelFormat.bitsPerPixel ~/ 8,
                width: 16,
              ),
          hActive < Const(config.timing.hActive, width: 12),
          hFp < Const(config.timing.hFrontPorch, width: 8),
          hSync < Const(config.timing.hSyncWidth, width: 8),
          hBp < Const(config.timing.hBackPorch, width: 8),
          vActive < Const(config.timing.vActive, width: 12),
          vFp < Const(config.timing.vFrontPorch, width: 8),
          vSync < Const(config.timing.vSyncWidth, width: 8),
          vBp < Const(config.timing.vBackPorch, width: 8),
          intStatus < Const(0, width: 4),
          intEnable < Const(0, width: 4),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              // Byte-address decode: registers sit 8 bytes apart (see the map
              // above). Decode every address bit of the 0x1000 window and
              // ignore the bits above it, so absolute and relative addresses
              // both work. An unused offset reads 0 and ignores writes.
              Case(bus.windowAddr(0x1000), [
                CaseItem(Const(0x00, width: 12), [
                  If(
                    bus.we & bus.selAny(0x00, 1),
                    then: [enable < bus.dataIn[0]],
                    orElse: [bus.dataOut < enable.zeroExtend(32)],
                  ),
                ]),
                CaseItem(Const(0x08, width: 12), [
                  bus.dataOut < Const(0, width: 32), // STATUS
                ]),
                CaseItem(Const(0x10, width: 12), [
                  If(
                    bus.we,
                    then: [fbBase < bus.selMerge(fbBase, 0x10)],
                    orElse: [bus.dataOut < fbBase],
                  ),
                ]),
                CaseItem(Const(0x18, width: 12), [
                  If(
                    bus.we,
                    then: [fbStride < bus.selMerge(fbStride, 0x18)],
                    orElse: [bus.dataOut < fbStride.zeroExtend(32)],
                  ),
                ]),
                CaseItem(Const(0x20, width: 12), [
                  If(
                    bus.we,
                    then: [hActive < bus.selMerge(hActive, 0x20)],
                    orElse: [bus.dataOut < hActive.zeroExtend(32)],
                  ),
                ]),
                CaseItem(Const(0x28, width: 12), [
                  If(
                    bus.we,
                    then: [
                      // hFp, hSync, and hBp each take one byte of this word,
                      // so each updates only when its own byte is selected.
                      If(
                        bus.selAny(0x28, 1),
                        then: [hFp < bus.dataIn.getRange(0, 8)],
                      ),
                      If(
                        bus.selAny(0x29, 1),
                        then: [hSync < bus.dataIn.getRange(8, 16)],
                      ),
                      If(
                        bus.selAny(0x2A, 1),
                        then: [hBp < bus.dataIn.getRange(16, 24)],
                      ),
                    ],
                    orElse: [
                      bus.dataOut <
                          hFp.zeroExtend(32) |
                              (hSync.zeroExtend(32) << Const(8, width: 32)) |
                              (hBp.zeroExtend(32) << Const(16, width: 32)),
                    ],
                  ),
                ]),
                CaseItem(Const(0x30, width: 12), [
                  If(
                    bus.we,
                    then: [vActive < bus.selMerge(vActive, 0x30)],
                    orElse: [bus.dataOut < vActive.zeroExtend(32)],
                  ),
                ]),
                CaseItem(Const(0x38, width: 12), [
                  If(
                    bus.we,
                    then: [
                      // vFp, vSync, and vBp each take one byte of this word,
                      // so each updates only when its own byte is selected.
                      If(
                        bus.selAny(0x38, 1),
                        then: [vFp < bus.dataIn.getRange(0, 8)],
                      ),
                      If(
                        bus.selAny(0x39, 1),
                        then: [vSync < bus.dataIn.getRange(8, 16)],
                      ),
                      If(
                        bus.selAny(0x3A, 1),
                        then: [vBp < bus.dataIn.getRange(16, 24)],
                      ),
                    ],
                    orElse: [
                      bus.dataOut <
                          vFp.zeroExtend(32) |
                              (vSync.zeroExtend(32) << Const(8, width: 32)) |
                              (vBp.zeroExtend(32) << Const(16, width: 32)),
                    ],
                  ),
                ]),
                CaseItem(Const(0x40, width: 12), [
                  If(
                    bus.we,
                    then: [intStatus < (intStatus & ~bus.selMasked(0x40, 4))],
                    orElse: [bus.dataOut < intStatus.zeroExtend(32)],
                  ),
                ]),
                CaseItem(Const(0x48, width: 12), [
                  If(
                    bus.we,
                    then: [intEnable < bus.selMerge(intEnable, 0x48)],
                    orElse: [bus.dataOut < intEnable.zeroExtend(32)],
                  ),
                ]),
              ]),
            ],
          ),
        ],
      ),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,display'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      'output-interface': config.interface_.name,
      'max-width': config.maxWidth,
      'max-height': config.maxHeight,
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,display'],
      'output-interface': config.interface_.name,
      'max-width': config.maxWidth,
      'max-height': config.maxHeight,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'DISPLAY',
    groupName: 'DISPLAY',
    description: 'Framebuffer display controller',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
