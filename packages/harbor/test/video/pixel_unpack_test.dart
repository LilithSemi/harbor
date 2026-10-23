import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'pixel_unpack_reference.dart';

const _scanFormats = [
  HarborPixelFormat.rgb565,
  HarborPixelFormat.xrgb8888,
  HarborPixelFormat.argb8888,
  HarborPixelFormat.yuyv,
  HarborPixelFormat.uyvy,
  HarborPixelFormat.nv12,
  HarborPixelFormat.p010,
  HarborPixelFormat.i420,
];

/// One frame in memory: plane k, plane line, then bytes.
class _Frame {
  final HarborPixelFormat format;
  final int lines;
  final List<List<List<int>>> planes;

  _Frame(this.format, this.lines, this.planes);

  /// The plane line bytes of luma line [y].
  List<List<int>> lineOf(int y) => [
    for (var k = 0; k < planes.length; k++)
      planes[k][y ~/ format.planes[k].vSub],
  ];
}

int _words(HarborPixelFormat f, int plane, int width) =>
    (f.lineBytes(plane, width) + 3) ~/ 4;

_Frame _randomFrame(
  HarborPixelFormat f,
  int width,
  int lines,
  Random rng,
) => _Frame(f, lines, [
  for (var k = 0; k < f.planes.length; k++)
    [
      for (var l = 0; l < f.planeLines(k, lines); l++)
        [for (var i = 0; i < 4 * _words(f, k, width); i++) rng.nextInt(256)],
    ],
]);

/// Pads each plane line of [f] at [width] to whole words.
_Frame _handFrame(HarborPixelFormat f, int width, List<List<int>> planes) =>
    _Frame(f, 1, [
      for (var k = 0; k < planes.length; k++)
        [
          [
            ...planes[k],
            ...List.filled(4 * _words(f, k, width) - planes[k].length, 0),
          ],
        ],
    ]);

/// Line memory with a read latency of one clock, the same as the scanout.
class _Bench extends Module {
  late final HarborPixelUnpack unpack;

  _Bench({
    required Logic clk,
    required Logic reset,
    required Logic x,
    required Logic line,
    required Logic frame,
    required Logic? format,
    required List<HarborPixelFormat> formats,
    required int hActive,
    required List<_Frame> frames,
  }) : super(name: 'bench') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    x = addInput('x', x, width: x.width);
    line = addInput('line', line, width: line.width);
    frame = addInput('frame', frame, width: frame.width);
    if (format != null)
      format = addInput('format', format, width: format.width);
    final planes = formats.map((f) => f.planes.length).reduce(max);
    final data = [for (var k = 0; k < planes; k++) Logic(width: 32)];
    final rom = [
      for (var k = 0; k < planes; k++) Logic(name: 'rom$k', width: 32),
    ];
    unpack = HarborPixelUnpack(
      clk: clk,
      reset: reset,
      x: x,
      format: format,
      planeData: data,
      formats: formats,
      hActive: hActive,
    );
    const colBits = 6;
    for (var k = 0; k < planes; k++) {
      final col = unpack.planeCol(k);
      final c = col.width >= colBits
          ? col.getRange(0, colBits)
          : col.zeroExtend(colBits);
      final l = k == 0 ? line : line.getRange(1).zeroExtend(line.width);
      final idx = [frame, l, c].swizzle();
      final items = <CaseItem>[];
      for (var f = 0; f < frames.length; f++) {
        if (k >= frames[f].planes.length) continue;
        final lines = frames[f].planes[k];
        for (var pl = 0; pl < lines.length; pl++) {
          final bytes = lines[pl];
          for (var w = 0; w < bytes.length ~/ 4; w++) {
            final v =
                bytes[4 * w] |
                bytes[4 * w + 1] << 8 |
                bytes[4 * w + 2] << 16 |
                bytes[4 * w + 3] << 24;
            final at = ((f << line.width) | pl) << colBits | w;
            items.add(CaseItem(Const(at, width: idx.width), [rom[k] < v]));
          }
        }
      }
      Combinational([
        Case(idx, items, defaultItem: [rom[k] < 0]),
      ]);
      data[k] <= flop(clk, rom[k]);
    }
  }
}

/// Runs [frames] through an unpack of [formats] and returns, per frame and
/// line, the pixels the RTL gives.
Future<List<List<List<UnpackedPixel>>>> _run({
  required List<HarborPixelFormat> formats,
  required int hActive,
  required List<_Frame> frames,
}) async {
  final hTotal = hActive + 4;
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final x = Logic(name: 'x', width: (hTotal - 1).bitLength);
  final lines = frames.map((f) => f.lines).reduce(max);
  final line = Logic(name: 'line', width: max(2, (lines - 1).bitLength));
  final frame = Logic(
    name: 'frame',
    width: max(1, (frames.length - 1).bitLength),
  );
  final format = formats.length > 1
      ? Logic(name: 'format', width: (formats.length - 1).bitLength)
      : null;
  final bench = _Bench(
    clk: clk,
    reset: reset,
    x: x,
    line: line,
    frame: frame,
    format: format,
    formats: formats,
    hActive: hActive,
    frames: frames,
  );
  await bench.build();
  final u = bench.unpack;
  final hasYuv = formats.any((f) => f.yuv);
  final hasRgb = formats.any((f) => !f.yuv);

  reset.inject(1);
  x.inject(0);
  line.inject(0);
  frame.inject(0);
  format?.inject(formats.indexOf(frames.first.format));
  Simulator.setMaxSimTime(100000000);
  final done = Simulator.run();
  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.inject(0);

  final inputs = <(int, int, int)>[];
  final outputs = <UnpackedPixel>[];
  UnpackedPixel sample() {
    final yuv = hasYuv && (!hasRgb || u.yuv.value.toInt() == 1);
    return yuv
        ? UnpackedPixel.yuv(
            u.y.value.toInt(),
            u.cb.value.toInt(),
            u.cr.value.toInt(),
          )
        : UnpackedPixel.rgb(
            u.red.value.toInt(),
            u.green.value.toInt(),
            u.blue.value.toInt(),
          );
  }

  Future<void> step(int f, int y, int tx) async {
    await clk.nextNegedge;
    outputs.add(
      inputs.length >= HarborPixelUnpack.latency &&
              inputs[inputs.length - HarborPixelUnpack.latency].$3 < hActive
          ? sample()
          : const UnpackedPixel.rgb(-1, -1, -1),
    );
    inputs.add((f, y, tx));
    x.put(tx);
    line.put(y);
    frame.put(f);
    format?.put(formats.indexOf(frames[f].format));
  }

  for (var f = 0; f < frames.length; f++) {
    for (var y = 0; y < frames[f].lines; y++) {
      for (var tx = 0; tx < hTotal; tx++) {
        await step(f, y, tx);
      }
    }
  }
  for (var i = 0; i < HarborPixelUnpack.latency; i++) {
    await step(frames.length - 1, 0, hActive);
  }
  await Simulator.endSimulation();
  await done;
  await Simulator.reset();

  final result = [
    for (final fr in frames)
      [
        for (var y = 0; y < fr.lines; y++)
          List.filled(hActive, const UnpackedPixel.rgb(-1, -1, -1)),
      ],
  ];
  for (var i = 0; i + HarborPixelUnpack.latency < outputs.length; i++) {
    final (f, y, tx) = inputs[i];
    if (tx < hActive) {
      result[f][y][tx] = outputs[i + HarborPixelUnpack.latency];
    }
  }
  return result;
}

Future<void> _checkFrames(
  List<HarborPixelFormat> formats,
  int width,
  List<_Frame> frames,
) async {
  final got = await _run(formats: formats, hActive: width, frames: frames);
  for (var f = 0; f < frames.length; f++) {
    final fr = frames[f];
    for (var y = 0; y < fr.lines; y++) {
      expect(
        got[f][y],
        equals(unpackLine(fr.format, width, fr.lineOf(y))),
        reason: '${fr.format.name} width $width frame $f line $y',
      );
    }
  }
}

void main() {
  tearDown(Simulator.reset);

  group('one format', () {
    for (final f in _scanFormats) {
      for (final width in [16, 17, 7, 1]) {
        test('${f.name} width $width matches the reference', () async {
          final rng = Random(width * 31 + f.index);
          await _checkFrames([f], width, [_randomFrame(f, width, 4, rng)]);
        });
      }
    }
  });

  for (final width in [16, 17]) {
    test('all formats in one build, width $width', () async {
      final rng = Random(width);
      await _checkFrames(_scanFormats, width, [
        for (final f in _scanFormats) _randomFrame(f, width, 3, rng),
        _randomFrame(HarborPixelFormat.p010, width, 2, rng),
        _randomFrame(HarborPixelFormat.rgb565, width, 1, rng),
      ]);
    });
  }

  test('a yuv set without rgb and a mixed set', () async {
    final rng = Random(5);
    const yuv = [
      HarborPixelFormat.nv12,
      HarborPixelFormat.yuyv,
      HarborPixelFormat.i420,
    ];
    await _checkFrames(yuv, 9, [
      for (final f in yuv) _randomFrame(f, 9, 4, rng),
    ]);
    const mixed = [HarborPixelFormat.xrgb8888, HarborPixelFormat.p010];
    await _checkFrames(mixed, 10, [
      for (final f in mixed) _randomFrame(f, 10, 2, rng),
    ]);
  });

  group('hand-checked values', () {
    Future<List<UnpackedPixel>> one(
      HarborPixelFormat f,
      int width,
      List<List<int>> planes,
    ) async {
      final frame = _handFrame(f, width, planes);
      final got = await _run(formats: [f], hActive: width, frames: [frame]);
      expect(got[0][0], equals(unpackLine(f, width, frame.lineOf(0))));
      return got[0][0];
    }

    const yuv = UnpackedPixel.yuv;

    test('nv12 averages odd pixels and repeats at the edge', () async {
      final px = await one(HarborPixelFormat.nv12, 4, [
        [1, 2, 3, 4],
        [10, 20, 31, 41],
      ]);
      expect(px, [
        yuv(4, 40, 80),
        yuv(8, 82, 122),
        yuv(12, 124, 164),
        yuv(16, 124, 164),
      ]);
    });

    test('nv12 averages across a chroma word boundary', () async {
      final px = await one(HarborPixelFormat.nv12, 6, [
        [0, 0, 0, 0, 0, 0],
        [10, 20, 30, 40, 50, 60],
      ]);
      expect(px[3], yuv(0, 160, 200));
      expect(px[4], yuv(0, 200, 240));
      expect(px[5], yuv(0, 200, 240));
    });

    test('p010 takes bits 15:6 and rounds the mean up', () async {
      final px = await one(HarborPixelFormat.p010, 3, [
        [0x7f, 0x8a, 0x3f, 0x00, 0xc0, 0xff],
        [0x40, 0x00, 0x80, 0x00, 0x80, 0x00, 0x00, 0x01],
      ]);
      expect(px, [yuv(553, 1, 2), yuv(0, 2, 3), yuv(1023, 2, 4)]);
    });

    test('p010 repeats the last chroma at an even width', () async {
      final px = await one(HarborPixelFormat.p010, 2, [
        [0x00, 0x01, 0x40, 0x00],
        [0x40, 0x00, 0xff, 0xff],
      ]);
      expect(px, [yuv(4, 1, 1023), yuv(1, 1, 1023)]);
    });

    test('yuyv and uyvy byte order', () async {
      expect(
        await one(HarborPixelFormat.yuyv, 4, [
          [1, 10, 2, 20, 3, 31, 4, 41],
        ]),
        [yuv(4, 40, 80), yuv(8, 82, 122), yuv(12, 124, 164), yuv(16, 124, 164)],
      );
      expect(
        await one(HarborPixelFormat.uyvy, 2, [
          [5, 6, 7, 8],
        ]),
        [yuv(24, 20, 28), yuv(32, 20, 28)],
      );
    });

    test('i420 averages across a chroma word boundary', () async {
      final px = await one(HarborPixelFormat.i420, 10, [
        List.filled(10, 1),
        [1, 2, 3, 4, 5],
        [9, 9, 9, 9, 7],
      ]);
      expect(px[7], yuv(4, 18, 32));
      expect(px[8], yuv(4, 20, 28));
      expect(px[9], yuv(4, 20, 28));
    });

    test('rgb formats keep the display bit order', () async {
      expect(
        await one(HarborPixelFormat.xrgb8888, 1, [
          [0x33, 0x22, 0x11, 0xee],
        ]),
        [const UnpackedPixel.rgb(0x11, 0x22, 0x33)],
      );
      expect(
        await one(HarborPixelFormat.rgb565, 2, [
          [0x00, 0xf8, 0x1f, 0x00],
        ]),
        [
          const UnpackedPixel.rgb(0xff, 0, 0),
          const UnpackedPixel.rgb(0, 0, 0xff),
        ],
      );
    });
  });

  test('the definition name follows the format set and width', () {
    HarborPixelUnpack make(List<HarborPixelFormat> fs, int w) =>
        HarborPixelUnpack(
          clk: Logic(),
          reset: Logic(),
          x: Logic(width: 8),
          format: fs.length > 1
              ? Logic(width: (fs.length - 1).bitLength)
              : null,
          planeData: [
            for (var k = 0; k < fs.map((f) => f.planes.length).reduce(max); k++)
              Logic(width: 32),
          ],
          formats: fs,
          hActive: w,
        );
    final names = {
      make([HarborPixelFormat.nv12], 16).definitionName,
      make([HarborPixelFormat.nv12], 17).definitionName,
      make([HarborPixelFormat.p010], 16).definitionName,
      make([HarborPixelFormat.nv12, HarborPixelFormat.i420], 16).definitionName,
      make([HarborPixelFormat.i420, HarborPixelFormat.nv12], 16).definitionName,
    };
    expect(names, hasLength(5));
    final yuyv = make([HarborPixelFormat.yuyv], 16);
    expect(yuyv.inputs.keys, isNot(contains('plane_data_1')));
    expect(yuyv.outputs.keys, isNot(contains('red')));
    final rgb = make([HarborPixelFormat.xrgb8888], 16);
    expect(rgb.outputs.keys, isNot(contains('cb')));
  });
}
