import 'package:harbor/harbor.dart';

/// One unpacked pixel. A YUV pixel has 10-bit Y, Cb and Cr in [a], [b] and
/// [c]. An RGB pixel has 8-bit R, G and B.
class UnpackedPixel {
  final bool yuv;
  final int a;
  final int b;
  final int c;

  const UnpackedPixel.yuv(int y, int cb, int cr)
    : yuv = true,
      a = y,
      b = cb,
      c = cr;

  const UnpackedPixel.rgb(int r, int g, int bl)
    : yuv = false,
      a = r,
      b = g,
      c = bl;

  @override
  bool operator ==(Object other) =>
      other is UnpackedPixel &&
      other.yuv == yuv &&
      other.a == a &&
      other.b == b &&
      other.c == c;

  @override
  int get hashCode => Object.hash(yuv, a, b, c);

  @override
  String toString() => yuv ? 'yuv($a, $b, $c)' : 'rgb($a, $b, $c)';
}

/// Unpacks one line of [width] pixels of [format].
///
/// [planes] holds the bytes of each plane line, in memory order. For a
/// 4:2:0 format, the chroma planes hold the chroma line of this luma line.
List<UnpackedPixel> unpackLine(
  HarborPixelFormat format,
  int width,
  List<List<int>> planes,
) {
  int le16(List<int> m, int at) => m[at] | m[at + 1] << 8;
  int up8(int v) => v << 2;
  int p010(int v) => v >> 6;

  switch (format) {
    case HarborPixelFormat.xrgb8888:
    case HarborPixelFormat.argb8888:
      return [
        for (var x = 0; x < width; x++)
          UnpackedPixel.rgb(
            planes[0][4 * x + 2],
            planes[0][4 * x + 1],
            planes[0][4 * x],
          ),
      ];
    case HarborPixelFormat.rgb565:
      return [
        for (var x = 0; x < width; x++)
          () {
            final v = le16(planes[0], 2 * x);
            final r = v >> 11, g = v >> 5 & 0x3f, b = v & 0x1f;
            return UnpackedPixel.rgb(
              r << 3 | r >> 2,
              g << 2 | g >> 4,
              b << 3 | b >> 2,
            );
          }(),
      ];
    case HarborPixelFormat.rgb888:
      throw ArgumentError('rgb888 is not a scanout format');
    default:
      break;
  }

  final chroma = (width + 1) ~/ 2;
  final luma = List<int>.filled(width, 0);
  final cb = List<int>.filled(chroma, 0);
  final cr = List<int>.filled(chroma, 0);
  final p0 = planes[0];
  switch (format) {
    case HarborPixelFormat.yuyv:
    case HarborPixelFormat.uyvy:
      // Byte offsets of Y0, Cb, Y1 and Cr in each 4-byte group.
      final o = format == HarborPixelFormat.yuyv ? [0, 1, 2, 3] : [1, 0, 3, 2];
      for (var x = 0; x < width; x++) {
        luma[x] = up8(p0[4 * (x ~/ 2) + (x.isEven ? o[0] : o[2])]);
      }
      for (var k = 0; k < chroma; k++) {
        cb[k] = up8(p0[4 * k + o[1]]);
        cr[k] = up8(p0[4 * k + o[3]]);
      }
    case HarborPixelFormat.nv12:
      for (var x = 0; x < width; x++) {
        luma[x] = up8(p0[x]);
      }
      for (var k = 0; k < chroma; k++) {
        cb[k] = up8(planes[1][2 * k]);
        cr[k] = up8(planes[1][2 * k + 1]);
      }
    case HarborPixelFormat.p010:
      for (var x = 0; x < width; x++) {
        luma[x] = p010(le16(p0, 2 * x));
      }
      for (var k = 0; k < chroma; k++) {
        cb[k] = p010(le16(planes[1], 4 * k));
        cr[k] = p010(le16(planes[1], 4 * k + 2));
      }
    case HarborPixelFormat.i420:
      for (var x = 0; x < width; x++) {
        luma[x] = up8(p0[x]);
      }
      for (var k = 0; k < chroma; k++) {
        cb[k] = up8(planes[1][k]);
        cr[k] = up8(planes[2][k]);
      }
    default:
      throw StateError('unreachable');
  }

  // Co-sited chroma: an even pixel takes its own sample, an odd pixel the
  // mean of its two neighbours, or the left one at the right edge.
  int at(List<int> c, int x) {
    final k = x ~/ 2;
    if (x.isEven || k + 1 >= c.length) return c[k];
    return (c[k] + c[k + 1] + 1) >> 1;
  }

  return [
    for (var x = 0; x < width; x++)
      UnpackedPixel.yuv(luma[x], at(cb, x), at(cr, x)),
  ];
}
