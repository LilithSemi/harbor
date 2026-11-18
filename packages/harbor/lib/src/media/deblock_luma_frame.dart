import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'deblock14.dart';
import 'deblock4.dart';
import 'deblock8.dart';

/// AV1 luma deblocking frame walk for an intra keyframe.
///
/// Deblocks a `width` x `height` reconstructed luma plane edge-by-edge: all
/// vertical transform-block edges across the plane first, then all horizontal
/// edges on the vertically-filtered result. Edge positions and per-edge filter
/// length (0/4/8/14) come from the per-4x4 transform-size grid [miTx] (min tx
/// size across each edge -> tx_dim_to_filter_length). The thresholds
/// (mblim/lim/hev) come from the uniform [level] and [sharpness] via the same
/// `update_sharpness` derivation as `HarborDeblockThresh`.
///
/// Scope: luma, intra keyframe, single superblock (`miRows`, `miCols` <= 32), no
/// subsampling. There is no per-mi level, skip or prediction-block grid, so the
/// skip suppression and PU-edge terms collapse: for a uniform non-zero [level]
/// an edge fires whenever its coordinate is an interior transform boundary
/// (coord != 0).
///
/// Since the tx layout and level are fixed at build time, each edge selects
/// exactly one kernel (no per-edge mux fan-out) and the thresholds are
/// constant-folded (computed in Dart, driven as `Const`).
///
/// Ports: input `frame` (width*height*8) and output `out` (same), pixel (y,x)
/// packed LSB-first row-major at `[(y*width + x)*8 +: 8]`. Combinational.
class HarborDeblockLumaFrame extends BridgeModule {
  /// Transform dimension tables (TX_SIZES_ALL) from the AV1 spec.
  static const List<int> _txSizeWide = [
    4, 8, 16, 32, 64, 4, 8, 8, 16, 16, 32, 32, 64, 4, 16, 8, 32, 16, 64, //
  ];
  static const List<int> _txSizeHigh = [
    4, 8, 16, 32, 64, 8, 4, 16, 8, 32, 16, 64, 32, 16, 4, 32, 8, 64, 16, //
  ];
  static const List<int> _txSizeWideUnit = [
    1, 2, 4, 8, 16, 1, 2, 2, 4, 4, 8, 8, 16, 1, 4, 2, 8, 4, 16, //
  ];
  static const List<int> _txSizeHighUnit = [
    1, 2, 4, 8, 16, 2, 1, 4, 2, 8, 4, 16, 8, 4, 1, 8, 2, 16, 4, //
  ];
  static const List<int> _txSizeWideUnitLog2 = [
    0, 1, 2, 3, 4, 0, 1, 1, 2, 2, 3, 3, 4, 0, 2, 1, 3, 2, 4, //
  ];
  static const List<int> _txSizeHighUnitLog2 = [
    0, 1, 2, 3, 4, 1, 0, 2, 1, 3, 2, 4, 3, 2, 0, 3, 1, 4, 2, //
  ];
  static const List<int> _txDimToFilterLength = [4, 8, 14, 14, 14];
  static const int _miSize = 4;

  /// Builds the threshold triple (mblim, lim, hev) for a given [level] and
  /// [sharpness], mirroring `_buildThresholds` / `HarborDeblockThresh`.
  static List<int> _thresh(int level, int sharpness) {
    var bil = level >> ((sharpness > 0 ? 1 : 0) + (sharpness > 4 ? 1 : 0));
    if (sharpness > 0 && bil > (9 - sharpness)) bil = 9 - sharpness;
    if (bil < 1) bil = 1;
    final lim = bil;
    final mblim = 2 * (level + 2) + bil;
    final hev = level >> 4;
    return [mblim, lim, hev];
  }

  HarborDeblockLumaFrame({
    int width = 16,
    int height = 16,
    required List<List<int>> miTx,
    required int level,
    int sharpness = 0,
    String? name,
  }) : super('HarborDeblockLumaFrame', name: name ?? 'deblock_luma_frame') {
    if (width <= 0 || height <= 0) {
      throw ArgumentError(
        'width/height must be positive, got $width x $height',
      );
    }
    if (width % _miSize != 0 || height % _miSize != 0) {
      throw ArgumentError(
        'width/height must be multiples of 4, got $width x $height',
      );
    }
    final miRows = miTx.length;
    if (miRows == 0) throw ArgumentError('miTx must be non-empty');
    final miCols = miTx[0].length;
    for (final row in miTx) {
      if (row.length != miCols) {
        throw ArgumentError('miTx must be rectangular');
      }
      for (final ts in row) {
        if (ts < 0 || ts >= _txSizeWide.length) {
          throw ArgumentError('miTx entry $ts out of TX_SIZE range');
        }
      }
    }
    if (miRows != height ~/ _miSize || miCols != width ~/ _miSize) {
      throw ArgumentError(
        'miTx must be ${height ~/ _miSize}x'
        '${width ~/ _miSize} for a $width x $height frame, got '
        '${miRows}x$miCols',
      );
    }
    if (miRows > 32 || miCols > 32) {
      throw ArgumentError('single-superblock only: mi grid must be <= 32x32');
    }
    if (level < 0 || level > 63) {
      throw ArgumentError('level must be 0..63, got $level');
    }
    if (sharpness < 0 || sharpness > 7) {
      throw ArgumentError('sharpness must be 0..7, got $sharpness');
    }

    createPort('frame', PortDirection.input, width: width * height * 8);
    addOutput('out', width: width * height * 8);

    final th = _thresh(level, sharpness);
    final mblimC = Const(th[0], width: 8);
    final limC = Const(th[1], width: 8);
    final hevC = Const(th[2], width: 8);

    // Mutable working grid of 8-bit pixel slices, indexed [y*width + x].
    final src = input('frame');
    final grid = <Logic>[
      for (var i = 0; i < width * height; i++) src.getRange(i * 8, i * 8 + 8),
    ];

    var inst = 0;

    // Apply one kernel of [filterLength] along an edge. `read(tap)` returns the
    // current pixel Logic at signed tap offset (tap -1 == p0, 0 == q0). `write`
    // stores the filtered pixel back. Only the taps the kernel rewrites are
    // written. Reads outside the frame must be guarded by the caller.
    void applyKernel(
      int filterLength,
      Logic Function(int) read,
      void Function(int, Logic) write,
    ) {
      switch (filterLength) {
        case 4:
          {
            // filter4 with the 4-tap filter_mask2 (not the 8-tap mask): the
            // dedicated HarborDeblock4 matches _applyEdgeSample case 4 exactly.
            final f = HarborDeblock4(name: 'f4_${inst++}');
            addSubModule(f);
            f.input('p1').srcConnection! <= read(-2);
            f.input('p0').srcConnection! <= read(-1);
            f.input('q0').srcConnection! <= read(0);
            f.input('q1').srcConnection! <= read(1);
            f.input('blimit').srcConnection! <= mblimC;
            f.input('limit').srcConnection! <= limC;
            f.input('thresh').srcConnection! <= hevC;
            write(-2, f.output('op1'));
            write(-1, f.output('op0'));
            write(0, f.output('oq0'));
            write(1, f.output('oq1'));
            break;
          }
        case 8:
          {
            final f = HarborDeblock8(name: 'f8_${inst++}');
            addSubModule(f);
            const names = ['p3', 'p2', 'p1', 'p0', 'q0', 'q1', 'q2', 'q3'];
            for (var k = 0; k < names.length; k++) {
              f.input(names[k]).srcConnection! <= read(k - 4);
            }
            f.input('limit').srcConnection! <= limC;
            f.input('blimit').srcConnection! <= mblimC;
            f.input('thresh').srcConnection! <= hevC;
            write(-3, f.output('op2'));
            write(-2, f.output('op1'));
            write(-1, f.output('op0'));
            write(0, f.output('oq0'));
            write(1, f.output('oq1'));
            write(2, f.output('oq2'));
            break;
          }
        case 14:
          {
            final f = HarborDeblock14(name: 'f14_${inst++}');
            addSubModule(f);
            const names = [
              'p6', 'p5', 'p4', 'p3', 'p2', 'p1', 'p0', //
              'q0', 'q1', 'q2', 'q3', 'q4', 'q5', 'q6',
            ];
            for (var k = 0; k < names.length; k++) {
              f.input(names[k]).srcConnection! <= read(k - 7);
            }
            f.input('limit').srcConnection! <= limC;
            f.input('blimit').srcConnection! <= mblimC;
            f.input('thresh').srcConnection! <= hevC;
            write(-6, f.output('op5'));
            write(-5, f.output('op4'));
            write(-4, f.output('op3'));
            write(-3, f.output('op2'));
            write(-2, f.output('op1'));
            write(-1, f.output('op0'));
            write(0, f.output('oq0'));
            write(1, f.output('oq1'));
            write(2, f.output('oq2'));
            write(3, f.output('oq3'));
            write(4, f.output('oq4'));
            write(5, f.output('oq5'));
            break;
          }
        default:
          break;
      }
    }

    // vertical edges across the whole plane
    for (var yu = 0; yu < miRows; yu++) {
      var xu = 0;
      while (xu < miCols) {
        final currX = xu * _miSize;
        final currY = yu * _miSize;
        final ts = miTx[yu][xu];
        final fl = _vertFilterLength(miTx, yu, xu, currX);
        if (fl != 0) {
          for (var i = 0; i < _miSize; i++) {
            final row = currY + i;
            if (row >= height) break;
            applyKernel(
              fl,
              (tap) => grid[row * width + (currX + tap)],
              (tap, v) => grid[row * width + (currX + tap)] = v,
            );
          }
        }
        xu += _txSizeWideUnit[ts];
      }
    }

    // horizontal edges on the vertically-filtered result
    for (var xu = 0; xu < miCols; xu++) {
      var yu = 0;
      while (yu < miRows) {
        final currX = xu * _miSize;
        final currY = yu * _miSize;
        final ts = miTx[yu][xu];
        final fl = _horzFilterLength(miTx, yu, xu, currY);
        if (fl != 0) {
          for (var i = 0; i < _miSize; i++) {
            final col = currX + i;
            if (col >= width) break;
            applyKernel(
              fl,
              (tap) => grid[(currY + tap) * width + col],
              (tap, v) => grid[(currY + tap) * width + col] = v,
            );
          }
        }
        yu += _txSizeHighUnit[ts];
      }
    }

    output('out') <=
        [for (var i = width * height - 1; i >= 0; i--) grid[i]].concat();
  }

  /// Vertical-edge filter length at mi (yu, xu) whose top-left pixel x is
  /// [currX]. Mirrors the luma path of `_setLpfParameters` for a vertical edge:
  /// only a transform boundary that is interior (currX != 0) fires, and the
  /// length is tx_dim_to_filter_length[min(wideLog2[ts], wideLog2[pvTs])].
  static int _vertFilterLength(
    List<List<int>> miTx,
    int yu,
    int xu,
    int currX,
  ) {
    final ts = miTx[yu][xu];
    if ((currX & (_txSizeWide[ts] - 1)) != 0) return 0; // not a tu edge
    if (currX == 0) return 0; // no left neighbour
    final pvTs = miTx[yu][xu - 1];
    final dim = _txSizeWideUnitLog2[ts] < _txSizeWideUnitLog2[pvTs]
        ? _txSizeWideUnitLog2[ts]
        : _txSizeWideUnitLog2[pvTs];
    return _txDimToFilterLength[dim];
  }

  /// Horizontal-edge filter length at mi (yu, xu) whose top-left pixel y is
  /// [currY]. Mirrors the luma path of `_setLpfParameters` for a horizontal
  /// edge.
  static int _horzFilterLength(
    List<List<int>> miTx,
    int yu,
    int xu,
    int currY,
  ) {
    final ts = miTx[yu][xu];
    if ((currY & (_txSizeHigh[ts] - 1)) != 0) return 0; // not a tu edge
    if (currY == 0) return 0; // no top neighbour
    final pvTs = miTx[yu - 1][xu];
    final dim = _txSizeHighUnitLog2[ts] < _txSizeHighUnitLog2[pvTs]
        ? _txSizeHighUnitLog2[ts]
        : _txSizeHighUnitLog2[pvTs];
    return _txDimToFilterLength[dim];
  }
}
