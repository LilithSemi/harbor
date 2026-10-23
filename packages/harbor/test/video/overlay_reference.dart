import 'package:harbor/harbor.dart';

import 'csc_reference.dart';
import 'pixel_unpack_reference.dart';

/// `round(v / 255)` for v from 0 to 65025, as the display computes it.
int div255(int v) => (v + 128 + ((v + 128) >> 8)) >> 8;

/// One channel of the overlay blend.
int blend255(int ov, int pri, int alpha) =>
    div255(ov * alpha + pri * (255 - alpha));

/// The overlay state of one frame.
class OverlayFrame {
  final bool enable;

  /// The index of the format in the overlay set.
  final int format;
  final int srcX;
  final int srcY;
  final int dstX;
  final int dstY;
  final int width;
  final int height;
  final int alpha;

  const OverlayFrame({
    this.enable = true,
    this.format = 0,
    this.srcX = 0,
    this.srcY = 0,
    required this.dstX,
    required this.dstY,
    required this.width,
    required this.height,
    this.alpha = 255,
  });

  @override
  String toString() =>
      'OverlayFrame(${enable ? 'on' : 'off'} f$format src ($srcX, $srcY) '
      'dst ($dstX, $dstY) ${width}x$height alpha $alpha)';
}

/// The bases and pitches of the planes of a surface.
class PlaneLayout {
  final List<int> base;
  final List<int> pitch;

  const PlaneLayout(this.base, this.pitch);

  /// [count] bytes of line [line] of [plane] from byte [start].
  List<int> bytes(
    int Function(int addr) byte,
    int plane,
    int line,
    int start,
    int count,
  ) => [
    for (var i = 0; i < count; i++)
      byte(base[plane] + line * pitch[plane] + start + i),
  ];
}

/// The source origin after the scanout clears the bits that break the
/// chroma alignment of [f].
(int, int) alignedOrigin(HarborPixelFormat f, int srcX, int srcY) =>
    (srcX & ~(f.hSub - 1), srcY & ~(f.vSub - 1));

/// The R, G and B of the pixels of [format] in line [line] of a surface
/// at [layout], from pixel [x0] for [width] pixels. A YUV format converts
/// with the bit-exact model of [csc]. The chroma of a 4:2:0 format comes
/// from line `line >> 1`.
List<List<int>> surfaceLine({
  required HarborPixelFormat format,
  required PlaneLayout layout,
  required int Function(int addr) byte,
  required int line,
  required int x0,
  required int width,
  HarborCscCoefficients? csc,
}) {
  final planes = [
    for (var k = 0; k < format.planes.length; k++)
      layout.bytes(
        byte,
        k,
        k == 0 ? line : line >> 1,
        x0 ~/ format.planes[k].pixelsPerGroup * format.planes[k].bytesPerGroup,
        format.lineBytes(k, width),
      ),
  ];
  return [
    for (final p in unpackLine(format, width, planes))
      p.yuv ? cscFixed(csc!, p.a, p.b, p.c) : [p.a, p.b, p.c],
  ];
}

/// The expected R, G and B of every pixel of a frame, as `[y][x]`.
///
/// [primary] gives the primary R, G and B of each line. The overlay of
/// [format] lies in memory as [layout] says, with bytes from [byte]. A
/// YUV overlay converts with [csc]. The crop is unpacked as one line, so
/// the right edge of the crop repeats its last chroma sample.
List<List<List<int>>> overlayFrame({
  required int hActive,
  required int vActive,
  required List<List<int>> Function(int y) primary,
  required HarborPixelFormat format,
  required PlaneLayout layout,
  required int Function(int addr) byte,
  required OverlayFrame state,
  required HarborCscCoefficients csc,
}) {
  final (sx0, sy0) = alignedOrigin(format, state.srcX, state.srcY);
  final w = state.width;
  final lines = <int, List<List<int>>>{};
  List<List<int>> crop(int sy) => lines.putIfAbsent(
    sy,
    () => surfaceLine(
      format: format,
      layout: layout,
      byte: byte,
      line: sy,
      x0: sx0,
      width: w,
      csc: csc,
    ),
  );

  return [
    for (var y = 0; y < vActive; y++)
      () {
        final pri = primary(y);
        return [
          for (var x = 0; x < hActive; x++)
            () {
              final inside =
                  state.enable &&
                  x >= state.dstX &&
                  x < state.dstX + w &&
                  y >= state.dstY &&
                  y < state.dstY + state.height;
              if (!inside) return pri[x];
              final ov = crop(sy0 + y - state.dstY)[x - state.dstX];
              return [
                for (var i = 0; i < 3; i++)
                  blend255(ov[i], pri[x][i], state.alpha),
              ];
            }(),
        ];
      }(),
  ];
}

/// The overlay line fetches of a frame as (byte address, words), plane by
/// plane, for a screen of [hActive] by [vActive].
List<(int, int)> overlayFetches({
  required int hActive,
  required int vActive,
  required HarborPixelFormat format,
  required PlaneLayout layout,
  required OverlayFrame state,
}) {
  final s = state;
  if (!s.enable ||
      s.width == 0 ||
      s.height == 0 ||
      s.dstX >= hActive ||
      s.dstY >= vActive) {
    return const [];
  }
  final (sx0, sy0) = alignedOrigin(format, s.srcX, s.srcY);
  final visible = s.width < hActive - s.dstX ? s.width : hActive - s.dstX;
  final out = <(int, int)>[];
  for (var k = 0; k < format.planes.length; k++) {
    final sh = HarborScanoutOverlay.wordShift(format, k);
    final ahead = HarborScanoutOverlay.lookahead(format, k) ? 1 : 0;
    final first = sx0 >> sh;
    final words = ((sx0 + visible - 1 + ahead) >> sh) - first + 1;
    final step = k == 0 ? 1 : 2;
    for (var r = 0; r < s.height && s.dstY + r < vActive; r += step) {
      final line = k == 0 ? sy0 + r : (sy0 >> 1) + (r >> 1);
      out.add((layout.base[k] + line * layout.pitch[k] + 4 * first, words));
    }
  }
  return out;
}
