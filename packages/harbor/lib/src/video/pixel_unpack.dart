import 'dart:math';

import 'package:rohd/rohd.dart';

import '../peripherals/display.dart';

/// Pixel-domain unpack of the scanout words into Y, Cb and Cr or R, G and B.
///
/// Drive [x] with the pixel column on the cycle that reads the line
/// buffers. Read plane k at [planeCol] and give its word to `plane_data_k`
/// one clock later, as [HarborDualClockScanout] does. The outputs come
/// [latency] clocks after [x].
///
/// A YUV format gives 10-bit [y], [cb] and [cr] and sets [yuv]. An 8-bit
/// sample becomes `v << 2`, and a p010 sample is bits 15:6 of its 16 bits.
/// Chroma is co-sited: an even pixel takes its own chroma sample and an
/// odd pixel takes `(C[k] + C[k + 1] + 1) >> 1`, or `C[k]` at the right
/// edge. An RGB format gives 8-bit [red], [green] and [blue], with the bit
/// order of the display.
///
/// The chroma columns read one pixel ahead, `(x + 1) >> shift`, so C[k + 1]
/// is in the word that comes in and C[k] is in the word before it.
/// A packed 4:2:2 format reads plane 0 the same way.
class HarborPixelUnpack extends Module {
  /// Clocks from [x] to the outputs.
  static const latency = 3;

  final List<HarborPixelFormat> formats;
  final int hActive;

  /// The word index to read in [plane], from [x].
  Logic planeCol(int plane) => output('plane_col_$plane');

  Logic get y => output('y');
  Logic get cb => output('cb');
  Logic get cr => output('cr');

  /// High when the pixel is Y, Cb and Cr.
  Logic get yuv => output('yuv');
  Logic get red => output('red');
  Logic get green => output('green');
  Logic get blue => output('blue');

  HarborPixelUnpack({
    required Logic clk,
    required Logic reset,
    required Logic x,
    Logic? format,
    required List<Logic> planeData,
    required List<HarborPixelFormat> formats,
    required this.hActive,
    super.name = 'pixel_unpack',
  }) : formats = List.unmodifiable(formats),
       super(
         definitionName:
             'HarborPixelUnpack'
             '_f${formats.map(harborPixelFormatBitOrder.indexOf).join('x')}'
             '_w${hActive}_x${x.width}',
       ) {
    if (formats.isEmpty || formats.contains(HarborPixelFormat.rgb888)) {
      throw ArgumentError('formats must not be empty or hold rgb888');
    }
    final planes = formats.map((f) => f.planes.length).reduce(max);
    if (planeData.length != planes) {
      throw ArgumentError('give plane data for planes 0 to ${planes - 1}');
    }
    if ((formats.length > 1) != (format != null)) {
      throw ArgumentError('give format only when there is more than one');
    }
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    x = addInput('x', x, width: x.width);
    if (format != null) {
      format = addInput('format', format, width: format.width);
    }
    final cur = [
      for (var k = 0; k < planes; k++)
        addInput('plane_data_$k', planeData[k], width: 32),
    ];

    Logic pick(
      List<HarborPixelFormat> set,
      Logic Function(HarborPixelFormat) v,
    ) {
      var out = v(set.last);
      for (var i = set.length - 2; i >= 0; i--) {
        out = mux(format!.eq(formats.indexOf(set[i])), v(set[i]), out);
      }
      return out;
    }

    // Columns at stage 0.
    final xw = x.width;
    final xNext = x.zeroExtend(xw + 1) + 1;
    Logic col(HarborPixelFormat f, int k) {
      final p = f.planes[k];
      final shift =
          p.pixelsPerGroup.bitLength - 1 + 2 - (p.bytesPerGroup.bitLength - 1);
      final ahead = f.yuv && (k > 0 || f.planes.length == 1);
      final v = ahead ? xNext : x.zeroExtend(xw + 1);
      return v.getRange(shift).zeroExtend(xw + 1).getRange(0, xw);
    }

    for (var k = 0; k < planes; k++) {
      final users = [
        for (final f in formats)
          if (k < f.planes.length) f,
      ];
      addOutput('plane_col_$k', width: xw) <=
          (formats.length == 1
              ? col(users.single, k)
              : pick(formats, (f) {
                  return k < f.planes.length ? col(f, k) : Const(0, width: xw);
                }));
    }

    // Stage 1: the plane words come in. The word of the pixel before stays
    // in a register.
    Logic delay(Logic v, String name) => flop(clk, v, reset: reset).named(name);
    final x1 = delay(x, 'x_s1').zeroExtend(max(xw, 3));
    final prevs = <int, Logic>{};
    Logic prev(int k) =>
        prevs.putIfAbsent(k, () => delay(cur[k], 'plane${k}_prev'));
    final odd = x1[0];

    Logic byte(Logic w, int i) => w.getRange(8 * i, 8 * i + 8);
    Logic byteAt(Logic w, Logic i) => i.width == 1
        ? mux(i, byte(w, 1), byte(w, 0))
        : mux(
            i[1],
            mux(i[0], byte(w, 3), byte(w, 2)),
            mux(i[0], byte(w, 1), byte(w, 0)),
          );
    Logic up8(Logic v) => [v, Const(0, width: 2)].swizzle();
    Logic hi10(Logic w, int half) => w.getRange(16 * half + 6, 16 * half + 16);

    // Y, then Cb and Cr of C[k], then Cb and Cr of C[k + 1].
    List<Logic> samples(HarborPixelFormat f) {
      switch (f) {
        case HarborPixelFormat.yuyv:
        case HarborPixelFormat.uyvy:
          final (y0, cbAt, y1, crAt) = f == HarborPixelFormat.yuyv
              ? (0, 1, 2, 3)
              : (1, 0, 3, 2);
          final w0 = mux(odd, prev(0), cur[0]);
          return [
            up8(mux(odd, byte(prev(0), y1), byte(cur[0], y0))),
            up8(byte(w0, cbAt)),
            up8(byte(w0, crAt)),
            up8(byte(cur[0], cbAt)),
            up8(byte(cur[0], crAt)),
          ];
        case HarborPixelFormat.nv12:
          final w0 = mux(odd, prev(1), cur[1]);
          final i = x1[1];
          return [
            up8(byteAt(cur[0], x1.getRange(0, 2))),
            up8(mux(i, byte(w0, 2), byte(w0, 0))),
            up8(mux(i, byte(w0, 3), byte(w0, 1))),
            up8(mux(i, byte(cur[1], 0), byte(cur[1], 2))),
            up8(mux(i, byte(cur[1], 1), byte(cur[1], 3))),
          ];
        case HarborPixelFormat.p010:
          final w0 = mux(odd, prev(1), cur[1]);
          return [
            mux(x1[0], hi10(cur[0], 1), hi10(cur[0], 0)),
            hi10(w0, 0),
            hi10(w0, 1),
            hi10(cur[1], 0),
            hi10(cur[1], 1),
          ];
        case HarborPixelFormat.i420:
          final i = x1.getRange(1, 3);
          final i1 = i + 1;
          return [
            up8(byteAt(cur[0], x1.getRange(0, 2))),
            up8(byteAt(mux(odd, prev(1), cur[1]), i)),
            up8(byteAt(mux(odd, prev(2), cur[2]), i)),
            up8(byteAt(cur[1], i1)),
            up8(byteAt(cur[2], i1)),
          ];
        default:
          throw StateError('${f.name} is not a YUV format');
      }
    }

    List<Logic> rgb(HarborPixelFormat f) {
      final w = cur[0];
      if (f != HarborPixelFormat.rgb565) {
        return [w.getRange(16, 24), w.getRange(8, 16), w.getRange(0, 8)];
      }
      // Column 0 is the low half: little-endian memory order.
      final half = mux(x1[0], w.getRange(16, 32), w.getRange(0, 16));
      final r5 = half.getRange(11, 16);
      final g6 = half.getRange(5, 11);
      final b5 = half.getRange(0, 5);
      return [
        [r5, r5.getRange(2, 5)].swizzle(),
        [g6, g6.getRange(4, 6)].swizzle(),
        [b5, b5.getRange(2, 5)].swizzle(),
      ];
    }

    Logic select(
      List<HarborPixelFormat> set,
      List<Logic> Function(HarborPixelFormat) of,
      int i,
    ) {
      final values = {for (final f in set) f: of(f)[i]};
      return set.length == 1
          ? values[set.single]!
          : pick(set, (f) => values[f]!);
    }

    final yuvSet = [
      for (final f in formats)
        if (f.yuv) f,
    ];
    final rgbSet = [
      for (final f in formats)
        if (!f.yuv) f,
    ];
    final yuv1 = rgbSet.isEmpty
        ? Const(1)
        : yuvSet.isEmpty
        ? Const(0)
        : pick(formats, (f) => Const(f.yuv ? 1 : 0));
    addOutput('yuv') <= delay(delay(yuv1, 'yuv_s2'), 'yuv_s3');

    if (rgbSet.isNotEmpty) {
      final cache = <HarborPixelFormat, List<Logic>>{};
      List<Logic> of(HarborPixelFormat f) => cache.putIfAbsent(f, () => rgb(f));
      for (final (i, name) in [(0, 'red'), (1, 'green'), (2, 'blue')]) {
        addOutput(name, width: 8) <=
            delay(delay(select(rgbSet, of, i), '${name}_s2'), '${name}_s3');
      }
    }

    if (yuvSet.isNotEmpty) {
      final cache = <HarborPixelFormat, List<Logic>>{};
      List<Logic> of(HarborPixelFormat f) =>
          cache.putIfAbsent(f, () => samples(f));
      final s2 = [
        for (final (i, name) in [
          (0, 'y'),
          (1, 'cb_a'),
          (2, 'cr_a'),
          (3, 'cb_b'),
          (4, 'cr_b'),
        ])
          delay(select(yuvSet, of, i), '${name}_s2'),
      ];
      // An odd pixel takes the mean, but not at the right edge of an even
      // line, where C[k + 1] is not in the line.
      final edge = hActive.isEven ? x1.eq(hActive - 1) : Const(0);
      final mean = delay(odd & ~edge, 'mean_s2');

      // Stage 2: the mean of the two chroma samples.
      Logic avg(Logic a, Logic b) =>
          (a.zeroExtend(11) + b.zeroExtend(11) + 1).getRange(1, 11);
      addOutput('y', width: 10) <= delay(s2[0], 'y_s3');
      addOutput('cb', width: 10) <=
          delay(mux(mean, avg(s2[1], s2[3]), s2[1]), 'cb_s3');
      addOutput('cr', width: 10) <=
          delay(mux(mean, avg(s2[2], s2[4]), s2[2]), 'cr_s3');
    }
  }
}
