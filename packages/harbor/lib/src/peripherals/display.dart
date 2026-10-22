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

/// One memory plane of a pixel format.
class HarborPixelPlane {
  /// Bytes in one group of pixels.
  final int bytesPerGroup;

  /// Horizontal luma pixels that one group covers.
  final int pixelsPerGroup;

  /// Luma lines per plane line (1 = every line, 2 = every second line).
  final int vSub;

  const HarborPixelPlane(this.bytesPerGroup, this.pixelsPerGroup, this.vSub);
}

/// Display pixel format.
enum HarborPixelFormat {
  rgb565(
    yuv: false,
    bitDepth: 8,
    hSub: 1,
    vSub: 1,
    planes: [HarborPixelPlane(2, 1, 1)],
  ),
  rgb888(
    yuv: false,
    bitDepth: 8,
    hSub: 1,
    vSub: 1,
    planes: [HarborPixelPlane(3, 1, 1)],
  ),
  xrgb8888(
    yuv: false,
    bitDepth: 8,
    hSub: 1,
    vSub: 1,
    planes: [HarborPixelPlane(4, 1, 1)],
  ),
  argb8888(
    yuv: false,
    bitDepth: 8,
    hSub: 1,
    vSub: 1,
    planes: [HarborPixelPlane(4, 1, 1)],
  ),
  yuyv(
    yuv: true,
    bitDepth: 8,
    hSub: 2,
    vSub: 1,
    planes: [HarborPixelPlane(4, 2, 1)],
  ),
  uyvy(
    yuv: true,
    bitDepth: 8,
    hSub: 2,
    vSub: 1,
    planes: [HarborPixelPlane(4, 2, 1)],
  ),

  /// Y plane, then interleaved CbCr plane.
  nv12(
    yuv: true,
    bitDepth: 8,
    hSub: 2,
    vSub: 2,
    planes: [HarborPixelPlane(1, 1, 1), HarborPixelPlane(2, 2, 2)],
  ),

  /// Like nv12 with 10-bit samples, MSB aligned in 16-bit containers.
  p010(
    yuv: true,
    bitDepth: 10,
    hSub: 2,
    vSub: 2,
    planes: [HarborPixelPlane(2, 1, 1), HarborPixelPlane(4, 2, 2)],
  ),

  /// Y plane, then Cb plane, then Cr plane.
  i420(
    yuv: true,
    bitDepth: 8,
    hSub: 2,
    vSub: 2,
    planes: [
      HarborPixelPlane(1, 1, 1),
      HarborPixelPlane(1, 2, 2),
      HarborPixelPlane(1, 2, 2),
    ],
  );

  /// True when the samples are Y, Cb and Cr.
  final bool yuv;

  /// Component depth in bits after unpack, before color conversion.
  final int bitDepth;

  /// Horizontal chroma subsampling factor.
  final int hSub;

  /// Vertical chroma subsampling factor.
  final int vSub;

  /// Memory planes in order.
  final List<HarborPixelPlane> planes;

  const HarborPixelFormat({
    required this.yuv,
    required this.bitDepth,
    required this.hSub,
    required this.vSub,
    required this.planes,
  });

  /// True for one plane of 4 bytes per pixel.
  bool get isPacked32 =>
      planes.length == 1 &&
      planes[0].bytesPerGroup == 4 &&
      planes[0].pixelsPerGroup == 1;

  /// Bytes in one line of [width] luma pixels in [plane].
  ///
  /// A partial group at the end of the line counts as a full group.
  int lineBytes(int plane, int width) {
    final p = planes[plane];
    return (width + p.pixelsPerGroup - 1) ~/ p.pixelsPerGroup * p.bytesPerGroup;
  }

  /// Lines in [plane] for [height] luma lines.
  int planeLines(int plane, int height) {
    final v = planes[plane].vSub;
    return (height + v - 1) ~/ v;
  }
}

/// Fixed ABI order of the pixel formats for capability bits.
///
/// Bit N of a capability word stands for the format at index N. Add new
/// formats at the end.
const harborPixelFormatBitOrder = <HarborPixelFormat>[
  HarborPixelFormat.rgb565,
  HarborPixelFormat.rgb888,
  HarborPixelFormat.xrgb8888,
  HarborPixelFormat.argb8888,
  HarborPixelFormat.yuyv,
  HarborPixelFormat.uyvy,
  HarborPixelFormat.nv12,
  HarborPixelFormat.p010,
  HarborPixelFormat.i420,
];

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

  /// XGA (1024x768 @ 60 Hz), VESA DMT.
  const HarborDisplayTiming.xga1024x768()
    : hActive = 1024,
      hFrontPorch = 24,
      hSyncWidth = 136,
      hBackPorch = 160,
      vActive = 768,
      vFrontPorch = 3,
      vSyncWidth = 6,
      vBackPorch = 29,
      pixelClock = 65000000,
      hSyncPositive = false,
      vSyncPositive = false;

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
