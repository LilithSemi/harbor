import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 wedge soft-mask producer: the per-block 7-bit (alpha
/// 0..64) mask used by COMPOUND_WEDGE prediction and wedge inter-intra. Mirrors
/// `av1_init_wedge_masks` + `av1_get_contiguous_soft_mask` in reconinter.c,
/// bit-exact with the AV1 wedge-mask spec / libaom.
///
/// The wedge geometry is fixed per `(bSize, wedgeIndex, sign)`, so the mask is a
/// build-time constant: [wedgeMask] computes the 64x64 master oblique / vertical
/// / horizontal masks once and extracts the `bw x bh` per-block mask, exactly as
/// the SW does. The ROHD module then drives that constant out the `mask` port so
/// it composes with [HarborCompoundBlend], whose `mask` port is 7-bit per pixel.
///
/// `mask` packs pixel `(y,x)` row-major LSB-first at index `y*bw + x`, 7 bits
/// each (the alpha range is 0..64, 64 needs 7 bits). Purely combinational, the
/// mask is a constant of the chosen `(bSize, wedgeIndex, sign)`.
class HarborWedgeMask extends BridgeModule {
  /// Number of distinct wedge codebook entries per wedge-enabled block size.
  static const maxWedgeTypes = 16;

  /// Block size index in BLOCK_SIZES_ALL.
  final int bSize;

  /// Wedge codebook index, `0 .. maxWedgeTypes-1`.
  final int wedgeIndex;

  /// Mask sign (0 or 1), selects the codebook entry's sign-flipped master.
  final int sign;

  HarborWedgeMask({
    required this.bSize,
    required this.wedgeIndex,
    required this.sign,
    String? name,
  }) : super('HarborWedgeMask', name: name ?? 'wedge_mask') {
    if (!isWedgeUsed(bSize)) {
      throw ArgumentError(
        'HarborWedgeMask.bSize=$bSize is not a wedge-enabled block size',
      );
    }
    if (wedgeIndex < 0 || wedgeIndex >= maxWedgeTypes) {
      throw ArgumentError(
        'HarborWedgeMask.wedgeIndex must be 0..'
        '${maxWedgeTypes - 1}, got $wedgeIndex',
      );
    }
    if (sign != 0 && sign != 1) {
      throw ArgumentError('HarborWedgeMask.sign must be 0 or 1, got $sign');
    }

    final bw = _bwTable[bSize], bh = _bhTable[bSize];
    final n = bw * bh;
    addOutput('mask', width: n * 7);

    final m = wedgeMask(bSize, wedgeIndex, sign);
    // Pack LSB-first row-major: pixel k occupies bits [k*7, k*7+7). swizzle is
    // MSB-first, so emit index n-1 down to 0.
    output('mask') <=
        [for (var i = n - 1; i >= 0; i--) Const(m[i], width: 7)].concat();
  }

  /// av1_is_wedge_used: wedge is signalled for these block sizes.
  static bool isWedgeUsed(int bSize) =>
      bSize >= 0 && bSize < _codebook.length && _codebook[bSize] != null;

  /// av1_get_contiguous_soft_mask: per-block wedge mask (alpha 0..64), row-major
  /// with stride `bw`, for the given block size / wedge index / sign. Each value
  /// is a 7-bit weight in `0..64`.
  static List<int> wedgeMask(int bSize, int index, int sign) {
    final cb = _codebook[bSize]!;
    final code = cb[index];
    final dir = code[0], xOff = code[1], yOff = code[2];
    final bw = _bwTable[bSize], bh = _bhTable[bSize];
    final woff = (xOff * bw) >> 3, hoff = (yOff * bh) >> 3;
    final wsignflip = _signflip[bSize][index];
    final master = _master[_maskIdx(sign ^ wsignflip, dir)];
    const half = _maskMasterSize ~/ 2, stride = _maskMasterStride;
    final base = stride * (half - hoff) + (half - woff);
    final out = List<int>.filled(bw * bh, 0);
    for (var y = 0; y < bh; y++) {
      for (var x = 0; x < bw; x++) {
        out[y * bw + x] = master[base + y * stride + x];
      }
    }
    return out;
  }
}

// master-mask construction, mirroring av1_init_wedge_masks (reconinter.c).
// built once, lazily, then cached.

const _maskMasterSize = 64; // MASK_MASTER_SIZE = MAX_WEDGE_SIZE(32) << 1
const _maskMasterStride = 64;
const _wedgeWeightBits = 6; // 1<<6 = 64
const _wedgeDirections = 6;

// WedgeDirectionType.
const _wHorizontal = 0, _wVertical = 1;
const _wOblique27 = 2, _wOblique63 = 3, _wOblique117 = 4, _wOblique153 = 5;

const _masterObliqueOdd = <int>[
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 6, 18, //
  37, 53, 60, 63, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, //
  64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64,
];
const _masterObliqueEven = <int>[
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 4, 11, 27, //
  46, 58, 62, 63, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, //
  64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64,
];
const _masterVertical = <int>[
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 7, 21, //
  43, 57, 62, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, //
  64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64,
];

// [BLOCK_SIZES_ALL][MAX_WEDGE_TYPES] sign-flip lookup (only wedge sizes used).
const _signflip = <List<int>>[
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], // 0
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], // 1
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], // 2
  [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 0, 1], // 3 8X8
  [1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 0, 1, 1, 1, 0, 1], // 4 8X16
  [1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 0, 1, 1, 1, 0, 1], // 5 16X8
  [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 0, 1], // 6 16X16
  [1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 0, 1, 1, 1, 0, 1], // 7 16X32
  [1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 0, 1, 1, 1, 0, 1], // 8 32X16
  [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 0, 1], // 9 32X32
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], // 10
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], // 11
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], // 12
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], // 13
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], // 14
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], // 15
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], // 16
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], // 17
  [1, 1, 1, 1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1], // 18 8X32
  [1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 0, 1, 0, 1, 0, 1], // 19 32X8
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], // 20
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], // 21
];

// Each entry: [direction, x_offset, y_offset].
const _cbHgtw = <List<int>>[
  [_wOblique27, 4, 4],
  [_wOblique63, 4, 4],
  [_wOblique117, 4, 4],
  [_wOblique153, 4, 4],
  [_wHorizontal, 4, 2],
  [_wHorizontal, 4, 4],
  [_wHorizontal, 4, 6],
  [_wVertical, 4, 4],
  [_wOblique27, 4, 2],
  [_wOblique27, 4, 6],
  [_wOblique153, 4, 2],
  [_wOblique153, 4, 6],
  [_wOblique63, 2, 4],
  [_wOblique63, 6, 4],
  [_wOblique117, 2, 4],
  [_wOblique117, 6, 4],
];
const _cbHltw = <List<int>>[
  [_wOblique27, 4, 4],
  [_wOblique63, 4, 4],
  [_wOblique117, 4, 4],
  [_wOblique153, 4, 4],
  [_wVertical, 2, 4],
  [_wVertical, 4, 4],
  [_wVertical, 6, 4],
  [_wHorizontal, 4, 4],
  [_wOblique27, 4, 2],
  [_wOblique27, 4, 6],
  [_wOblique153, 4, 2],
  [_wOblique153, 4, 6],
  [_wOblique63, 2, 4],
  [_wOblique63, 6, 4],
  [_wOblique117, 2, 4],
  [_wOblique117, 6, 4],
];
const _cbHeqw = <List<int>>[
  [_wOblique27, 4, 4],
  [_wOblique63, 4, 4],
  [_wOblique117, 4, 4],
  [_wOblique153, 4, 4],
  [_wHorizontal, 4, 2],
  [_wHorizontal, 4, 6],
  [_wVertical, 2, 4],
  [_wVertical, 6, 4],
  [_wOblique27, 4, 2],
  [_wOblique27, 4, 6],
  [_wOblique153, 4, 2],
  [_wOblique153, 4, 6],
  [_wOblique63, 2, 4],
  [_wOblique63, 6, 4],
  [_wOblique117, 2, 4],
  [_wOblique117, 6, 4],
];

// block size -> codebook (null = wedge not used for that size).
const _codebook = <List<List<int>>?>[
  null,
  null,
  null,
  _cbHeqw,
  _cbHgtw,
  _cbHltw,
  _cbHeqw,
  _cbHgtw,
  _cbHltw,
  _cbHeqw,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  _cbHgtw,
  _cbHltw,
  null,
  null,
];

// block_size_wide / high per BLOCK_SIZES_ALL.
const _bwTable = <int>[
  4, 4, 8, 8, 8, 16, 16, 16, 32, 32, 32, 64, 64, 64, 128, 128, 4, 16, 8, 32, //
  16, 64,
];
const _bhTable = <int>[
  4, 8, 4, 8, 16, 8, 16, 32, 16, 32, 64, 32, 64, 128, 64, 128, 16, 4, 32, 8, //
  64, 16,
];

int _maskIdx(int neg, int dir) => neg * _wedgeDirections + dir;

void _shiftCopy(
  List<int> src,
  List<int> dst,
  int dstOff,
  int shift,
  int width,
) {
  if (shift >= 0) {
    for (var i = 0; i < width - shift; i++) {
      dst[dstOff + shift + i] = src[i];
    }
    for (var i = 0; i < shift; i++) {
      dst[dstOff + i] = src[0];
    }
  } else {
    final s = -shift;
    for (var i = 0; i < width - s; i++) {
      dst[dstOff + i] = src[s + i];
    }
    for (var i = 0; i < s; i++) {
      dst[dstOff + width - s + i] = src[width - 1];
    }
  }
}

List<List<int>>? _masterCache;

List<List<int>> get _master => _masterCache ??= _initMaster();

List<List<int>> _initMaster() {
  final obl = [
    for (var i = 0; i < 2 * _wedgeDirections; i++)
      List<int>.filled(_maskMasterSize * _maskMasterSize, 0),
  ];
  const w = _maskMasterSize, h = _maskMasterSize, stride = _maskMasterStride;
  final o63 = obl[_maskIdx(0, _wOblique63)];
  final overt = obl[_maskIdx(0, _wVertical)];
  var shift = h ~/ 4;
  for (var i = 0; i < h; i += 2) {
    _shiftCopy(_masterObliqueEven, o63, i * stride, shift, _maskMasterSize);
    shift--;
    _shiftCopy(
      _masterObliqueOdd,
      o63,
      (i + 1) * stride,
      shift,
      _maskMasterSize,
    );
    for (var j = 0; j < _maskMasterSize; j++) {
      overt[i * stride + j] = _masterVertical[j];
      overt[(i + 1) * stride + j] = _masterVertical[j];
    }
  }
  final o27 = obl[_maskIdx(0, _wOblique27)];
  final o117 = obl[_maskIdx(0, _wOblique117)];
  final o153 = obl[_maskIdx(0, _wOblique153)];
  final ohorz = obl[_maskIdx(0, _wHorizontal)];
  final n63 = obl[_maskIdx(1, _wOblique63)];
  final n27 = obl[_maskIdx(1, _wOblique27)];
  final n117 = obl[_maskIdx(1, _wOblique117)];
  final n153 = obl[_maskIdx(1, _wOblique153)];
  final nvert = obl[_maskIdx(1, _wVertical)];
  final nhorz = obl[_maskIdx(1, _wHorizontal)];
  const wMax = 1 << _wedgeWeightBits; // 64
  for (var i = 0; i < h; ++i) {
    for (var j = 0; j < w; ++j) {
      final msk = o63[i * stride + j];
      o27[j * stride + i] = msk;
      o117[i * stride + w - 1 - j] = wMax - msk;
      o153[(w - 1 - j) * stride + i] = wMax - msk;
      n63[i * stride + j] = wMax - msk;
      n27[j * stride + i] = wMax - msk;
      n117[i * stride + w - 1 - j] = msk;
      n153[(w - 1 - j) * stride + i] = msk;
      final mskx = overt[i * stride + j];
      ohorz[j * stride + i] = mskx;
      nvert[i * stride + j] = wMax - mskx;
      nhorz[j * stride + i] = wMax - mskx;
    }
  }
  return obl;
}
