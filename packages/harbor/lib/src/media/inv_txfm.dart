import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 inverse transform (libaom `av1_inv_txfm2d_add_*_c`).
///
/// A faithful port of libaom's integer butterfly inverse transforms: the cosBit
/// 12 `idct{4,8,16}` / `iadst{4,8,16}` / `iidentity{4,8,16,32}` 1D cores, the
/// column-major internal-input remap, the per-stage range clamps (all 16-bit at
/// bd = 8), the rectangular `NewInvSqrt2` row prescale, the row/column
/// round-shifts (`av1_inv_txfm_shift_ls`), and the up/down + left/right flips
/// for the FLIPADST variants. The residual it produces is byte-identical to the
/// software decoder's `inverseTransform` for every TX_TYPE at bd = 8.
///
/// [txSize] is the libaom TX_SIZE enum, [txType] the TX_TYPE enum. Both resolve
/// at build time so each instance emits only the datapath its (size, type)
/// needs. All TX_SIZES_ALL sizes are supported. The 4/8/16-point cores cover
/// every TX_TYPE (DCT / ADST / FLIPADST / IDTX). The 32- and 64-point cores are
/// the `idct32` / `idct64` butterfly networks (DCT for both, plus IDTX for
/// 32-point), which is all AV1 codes at those sizes (ADST/FLIPADST are undefined
/// for dims > 16, and tx_size_sqr_up >= TX_32X32 forces EXT_TX_SET_DCTONLY for
/// intra). A 64-point transform codes only the top-left 32x32 coefficient
/// region. The 2D driver zeroes the high 32x32 quadrants and the idct64 core
/// downsamples, matching libaom exactly.
///
/// `coeffs` packs the dequantized levels row-major: element (r, c) at
/// `[(r*W + c)*16 +: 16]`, signed two's complement, W = tx_size_wide. `residual`
/// is the spatial residual in the same layout (what libaom adds to the predictor
/// before the pixel clamp). Combinational.
class HarborInvTxfm extends BridgeModule {
  /// libaom TX_SIZE this instance implements.
  final int txSize;

  /// libaom TX_TYPE this instance implements.
  final int txType;

  // tx_size geometry (TX_SIZES_ALL).
  static const _txSizeWide = [
    4,
    8,
    16,
    32,
    64,
    4,
    8,
    8,
    16,
    16,
    32,
    32,
    64,
    4,
    16,
    8,
    32,
    16,
    64,
  ];
  static const _txSizeHigh = [
    4,
    8,
    16,
    32,
    64,
    8,
    4,
    16,
    8,
    32,
    16,
    64,
    32,
    16,
    4,
    32,
    8,
    64,
    16,
  ];
  static const _invTxfmShiftLs = [
    [0, -4], [-1, -4], [-2, -4], [-2, -4], [-2, -4], //
    [0, -4], [0, -4], [-1, -4], [-1, -4], [-1, -4], [-1, -4], //
    [-1, -4], [-1, -4], [-1, -4], [-1, -4], [-2, -4], [-2, -4], //
    [-2, -4], [-2, -4],
  ];
  // TX_TYPE -> TX_TYPE_1D (DCT=0 ADST=1 FLIPADST=2 IDTX=3) for col / row.
  static const _vtxTab = [0, 1, 0, 1, 2, 0, 2, 1, 2, 3, 0, 3, 1, 3, 2, 3];
  static const _htxTab = [0, 0, 1, 1, 0, 2, 2, 2, 1, 3, 3, 0, 3, 1, 3, 2];

  /// Sample bit depth (8/10/12). Widens the per-stage range clamps and the
  /// residual output element width (residualW = bitDepth + 8).
  final int bitDepth;

  /// When set, the TX_TYPE is taken from a runtime `tx_type` input (4-bit)
  /// rather than [txType], and the row/col 1D cores are selected at runtime.
  /// Only the intra ext-tx set is supported (DCT / ADST / IDTX 1D types, no
  /// FLIPADST, so no buffer flips), valid for square TX_4X4 / TX_8X8 / TX_16X16
  /// AND the rectangular sizes whose both dims are <= 16 (TX_4X8 / TX_8X4 /
  /// TX_8X16 / TX_16X8 / TX_4X16 / TX_16X4). The intra rect ext-tx sets are
  /// DTT4_IDTX_1DDCT (max dim 8: adds V_DCT/H_DCT) and DTT4_IDTX (max dim 16),
  /// both entirely non-FLIPADST, so the runtime 1D-type mux (DCT/ADST/IDTX) plus
  /// the build-time rectangular NewInvSqrt2 prescale reproduce them exactly.
  /// [txType] is ignored.
  final bool runtimeTxType;

  // Rect TX sizes with both dims <= 16 (runtime-tx-type eligible).
  static const _rectRuntimeSizes = [5, 6, 7, 8, 13, 14];

  HarborInvTxfm({
    required this.txSize,
    required this.txType,
    this.bitDepth = 8,
    this.runtimeTxType = false,
    String? name,
  }) : assert(txSize >= 0 && txSize < 19, 'TX_SIZE'),
       assert(txType >= 0 && txType < 16, 'TX_TYPE'),
       assert(bitDepth == 8 || bitDepth == 10 || bitDepth == 12, 'bit depth'),
       assert(
         !runtimeTxType ||
             txSize == 0 ||
             txSize == 1 ||
             txSize == 2 ||
             _rectRuntimeSizes.contains(txSize),
         'runtimeTxType: square TX_4X4/8X8/16X16 or rect dims<=16 only',
       ),
       super(
         'HarborInvTxfm_T${txSize}_${runtimeTxType ? "Rt" : "Y$txType"}_B$bitDepth',
         name:
             name ??
             'inv_txfm_${txSize}_${runtimeTxType ? "rt" : txType}_$bitDepth',
       ) {
    final txw = _txSizeWide[txSize];
    final txh = _txSizeHigh[txSize];
    final residualW = bitDepth + 8; // signed residual element width

    // libaom av1_gen_inv_stage_range optimal ranges (bd 8/10/12).
    final rowBits = bitDepth == 8 ? 16 : (bitDepth == 10 ? 18 : 20);
    final colBits = bitDepth == 8 ? 16 : (bitDepth == 10 ? 16 : 18);
    final rowInBits = bitDepth + 8; // _clampBuf(tempIn, ., bd + 8)
    final colInBits = (bitDepth + 6) > 16 ? (bitDepth + 6) : 16; // max(bd+6,16)

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    addOutput('done');
    // Coeff element width = residualW (bd + 8): the dequantized level clamps to
    // +-(1<<(7+bd)), a signed (bd+8)-bit value. 16 at bd 8 (byte-identical).
    createPort('coeffs', PortDirection.input, width: txw * txh * residualW);
    addOutput('residual', width: txw * txh * residualW);
    if (runtimeTxType) createPort('tx_type', PortDirection.input, width: 4);

    // exact-arithmetic primitives (W-bit two's complement)
    //
    // At bd 8 libaom keeps every inter-stage value clamped to 16 bits and every
    // product/sum within int32, so a 32-bit working width reproduces the
    // `(int32_t)` semantics exactly while keeping the multiplier netlist small.
    // At bd 10/12 the stage ranges widen (18/20) and the half_btf SUM of two
    // int32 products needs int64, so the window grows to 48 bits (products are
    // still truncated to int32 via `s32`, matching the `(int32_t)` cast).
    final w = bitDepth == 8 ? 32 : 48;
    const cospi = <int>[
      4096, 4095, 4091, 4085, 4076, 4065, 4052, 4036, 4017, 3996, 3973, //
      3948, 3920, 3889, 3857, 3822, 3784, 3745, 3703, 3659, 3612, 3564, //
      3513, 3461, 3406, 3349, 3290, 3229, 3166, 3102, 3035, 2967, 2896, //
      2824, 2751, 2675, 2598, 2520, 2440, 2359, 2276, 2191, 2106, 2019, //
      1931, 1842, 1751, 1660, 1567, 1474, 1380, 1285, 1189, 1092, 995, //
      897, 799, 700, 601, 501, 401, 301, 201, 101,
    ];
    const sinpi = <int>[0, 1321, 2482, 3344, 3803];
    const newSqrt2 = 5793;
    const newInvSqrt2 = 2896;
    const newSqrt2Bits = 12;
    const cosBit = 12;

    Logic kc(int v) => Const(BigInt.from(v).toUnsigned(w), width: w);
    Logic ashr(Logic x, int s) =>
        s == 0 ? x : [x[w - 1].replicate(s), x.getRange(s, w)].swizzle();
    // Reinterpret the low 32 bits as signed (libaom `(int32_t)`). At w == 32
    // this is the identity (the value already is the low 32 bits).
    Logic s32(Logic v) => w == 32
        ? v.getRange(0, 32)
        : [v[31].replicate(w - 32), v.getRange(0, 32)].swizzle();
    Logic addW(Logic a, Logic b) => (a + b).getRange(0, w);
    Logic subW(Logic a, Logic b) => (a - b).getRange(0, w);
    Logic mulW(Logic a, int k) => (a * kc(k)).getRange(0, w);

    Logic halfBtf(int w0, Logic in0, int w1, Logic in1) {
      final p0 = s32((in0 * kc(w0)).getRange(0, 32));
      final p1 = s32((in1 * kc(w1)).getRange(0, 32));
      final inter = addW(addW(p0, p1), kc(1 << (cosBit - 1)));
      return s32(ashr(inter, cosBit));
    }

    Logic roundShift(Logic value, int bit) =>
        s32(ashr(addW(value, kc(1 << (bit - 1))), bit));

    // clamp_value to signed `bit`-bit range (always 16 at bd = 8).
    Logic clampN(Logic v, int bit) {
      final maxV = (1 << (bit - 1)) - 1;
      final minV = -(1 << (bit - 1));
      final gtMax = subW(kc(maxV), v)[w - 1];
      final ltMin = subW(v, kc(minV))[w - 1];
      return mux(ltMin, kc(minV), mux(gtMax, kc(maxV), v));
    }

    // The per-stage clamp width changes between the row pass (rowBits) and the
    // column pass (colBits). `curClamp` is set before each core is built.
    var curClamp = rowBits;
    Logic clamp16(Logic v) => clampN(v, curClamp);
    // Negate in two's complement (0 - v).
    Logic negW(Logic v) => subW(Const(0, width: w), v);
    // Clamped add / sub / (-a + b), the common butterfly-stage patterns.
    Logic ca(Logic a, Logic b) => clamp16(addW(a, b));
    Logic cs(Logic a, Logic b) => clamp16(subW(a, b));
    Logic cna(Logic a, Logic b) => clamp16(addW(negW(a), b));

    // 1D cores (input/output length = the 1D size)
    List<Logic> idct4(List<Logic> i) {
      final s1 = [i[0], i[2], i[1], i[3]];
      final s2 = [
        halfBtf(cospi[32], s1[0], cospi[32], s1[1]),
        halfBtf(cospi[32], s1[0], -cospi[32], s1[1]),
        halfBtf(cospi[48], s1[2], -cospi[16], s1[3]),
        halfBtf(cospi[16], s1[2], cospi[48], s1[3]),
      ];
      return [
        clamp16(addW(s2[0], s2[3])),
        clamp16(addW(s2[1], s2[2])),
        clamp16(subW(s2[1], s2[2])),
        clamp16(subW(s2[0], s2[3])),
      ];
    }

    List<Logic> iadst4(List<Logic> inp) {
      final x0 = inp[0], x1 = inp[1], x2 = inp[2], x3 = inp[3];
      var s0 = mulW(x0, sinpi[1]);
      var s1 = mulW(x0, sinpi[2]);
      final s2c = mulW(x1, sinpi[3]);
      final s3c = mulW(x2, sinpi[4]);
      final s4 = mulW(x2, sinpi[1]);
      final s5 = mulW(x3, sinpi[2]);
      final s6 = mulW(x3, sinpi[4]);
      final s7 = addW(subW(x0, x2), x3);
      s0 = addW(s0, s3c);
      s1 = subW(s1, s4);
      final s3 = s2c;
      final s2 = mulW(s7, sinpi[3]);
      s0 = addW(s0, s5);
      s1 = subW(s1, s6);
      final rx0 = addW(s0, s3);
      final rx1 = addW(s1, s3);
      final rx2 = s2;
      final rx3 = subW(addW(s0, s1), s3);
      return [
        roundShift(rx0, cosBit),
        roundShift(rx1, cosBit),
        roundShift(rx2, cosBit),
        roundShift(rx3, cosBit),
      ];
    }

    List<Logic> idct8(List<Logic> i) {
      // stage 1
      var b = [i[0], i[4], i[2], i[6], i[1], i[5], i[3], i[7]];
      // stage 2
      b = [
        b[0],
        b[1],
        b[2],
        b[3],
        halfBtf(cospi[56], b[4], -cospi[8], b[7]),
        halfBtf(cospi[24], b[5], -cospi[40], b[6]),
        halfBtf(cospi[40], b[5], cospi[24], b[6]),
        halfBtf(cospi[8], b[4], cospi[56], b[7]),
      ];
      // stage 3
      b = [
        halfBtf(cospi[32], b[0], cospi[32], b[1]),
        halfBtf(cospi[32], b[0], -cospi[32], b[1]),
        halfBtf(cospi[48], b[2], -cospi[16], b[3]),
        halfBtf(cospi[16], b[2], cospi[48], b[3]),
        clamp16(addW(b[4], b[5])),
        clamp16(subW(b[4], b[5])),
        clamp16(addW(negW(b[6]), b[7])),
        clamp16(addW(b[6], b[7])),
      ];
      // stage 4
      b = [
        clamp16(addW(b[0], b[3])),
        clamp16(addW(b[1], b[2])),
        clamp16(subW(b[1], b[2])),
        clamp16(subW(b[0], b[3])),
        b[4],
        halfBtf(-cospi[32], b[5], cospi[32], b[6]),
        halfBtf(cospi[32], b[5], cospi[32], b[6]),
        b[7],
      ];
      // stage 5
      return [
        clamp16(addW(b[0], b[7])),
        clamp16(addW(b[1], b[6])),
        clamp16(addW(b[2], b[5])),
        clamp16(addW(b[3], b[4])),
        clamp16(subW(b[3], b[4])),
        clamp16(subW(b[2], b[5])),
        clamp16(subW(b[1], b[6])),
        clamp16(subW(b[0], b[7])),
      ];
    }

    List<Logic> iadst8(List<Logic> i) {
      // stage 1
      var b = [i[7], i[0], i[5], i[2], i[3], i[4], i[1], i[6]];
      // stage 2
      b = [
        halfBtf(cospi[4], b[0], cospi[60], b[1]),
        halfBtf(cospi[60], b[0], -cospi[4], b[1]),
        halfBtf(cospi[20], b[2], cospi[44], b[3]),
        halfBtf(cospi[44], b[2], -cospi[20], b[3]),
        halfBtf(cospi[36], b[4], cospi[28], b[5]),
        halfBtf(cospi[28], b[4], -cospi[36], b[5]),
        halfBtf(cospi[52], b[6], cospi[12], b[7]),
        halfBtf(cospi[12], b[6], -cospi[52], b[7]),
      ];
      // stage 3
      b = [
        clamp16(addW(b[0], b[4])),
        clamp16(addW(b[1], b[5])),
        clamp16(addW(b[2], b[6])),
        clamp16(addW(b[3], b[7])),
        clamp16(subW(b[0], b[4])),
        clamp16(subW(b[1], b[5])),
        clamp16(subW(b[2], b[6])),
        clamp16(subW(b[3], b[7])),
      ];
      // stage 4
      b = [
        b[0],
        b[1],
        b[2],
        b[3],
        halfBtf(cospi[16], b[4], cospi[48], b[5]),
        halfBtf(cospi[48], b[4], -cospi[16], b[5]),
        halfBtf(-cospi[48], b[6], cospi[16], b[7]),
        halfBtf(cospi[16], b[6], cospi[48], b[7]),
      ];
      // stage 5
      b = [
        clamp16(addW(b[0], b[2])),
        clamp16(addW(b[1], b[3])),
        clamp16(subW(b[0], b[2])),
        clamp16(subW(b[1], b[3])),
        clamp16(addW(b[4], b[6])),
        clamp16(addW(b[5], b[7])),
        clamp16(subW(b[4], b[6])),
        clamp16(subW(b[5], b[7])),
      ];
      // stage 6
      b = [
        b[0],
        b[1],
        halfBtf(cospi[32], b[2], cospi[32], b[3]),
        halfBtf(cospi[32], b[2], -cospi[32], b[3]),
        b[4],
        b[5],
        halfBtf(cospi[32], b[6], cospi[32], b[7]),
        halfBtf(cospi[32], b[6], -cospi[32], b[7]),
      ];
      // stage 7
      return [
        b[0],
        negW(b[4]),
        b[6],
        negW(b[2]),
        b[3],
        negW(b[7]),
        b[5],
        negW(b[1]),
      ];
    }

    List<Logic> idct16(List<Logic> i) {
      // stage 1
      var b = [
        i[0],
        i[8],
        i[4],
        i[12],
        i[2],
        i[10],
        i[6],
        i[14],
        i[1],
        i[9],
        i[5],
        i[13],
        i[3],
        i[11],
        i[7],
        i[15],
      ];
      // stage 2
      b = [
        b[0],
        b[1],
        b[2],
        b[3],
        b[4],
        b[5],
        b[6],
        b[7],
        halfBtf(cospi[60], b[8], -cospi[4], b[15]),
        halfBtf(cospi[28], b[9], -cospi[36], b[14]),
        halfBtf(cospi[44], b[10], -cospi[20], b[13]),
        halfBtf(cospi[12], b[11], -cospi[52], b[12]),
        halfBtf(cospi[52], b[11], cospi[12], b[12]),
        halfBtf(cospi[20], b[10], cospi[44], b[13]),
        halfBtf(cospi[36], b[9], cospi[28], b[14]),
        halfBtf(cospi[4], b[8], cospi[60], b[15]),
      ];
      // stage 3
      b = [
        b[0],
        b[1],
        b[2],
        b[3],
        halfBtf(cospi[56], b[4], -cospi[8], b[7]),
        halfBtf(cospi[24], b[5], -cospi[40], b[6]),
        halfBtf(cospi[40], b[5], cospi[24], b[6]),
        halfBtf(cospi[8], b[4], cospi[56], b[7]),
        clamp16(addW(b[8], b[9])),
        clamp16(subW(b[8], b[9])),
        clamp16(addW(negW(b[10]), b[11])),
        clamp16(addW(b[10], b[11])),
        clamp16(addW(b[12], b[13])),
        clamp16(subW(b[12], b[13])),
        clamp16(addW(negW(b[14]), b[15])),
        clamp16(addW(b[14], b[15])),
      ];
      // stage 4
      b = [
        halfBtf(cospi[32], b[0], cospi[32], b[1]),
        halfBtf(cospi[32], b[0], -cospi[32], b[1]),
        halfBtf(cospi[48], b[2], -cospi[16], b[3]),
        halfBtf(cospi[16], b[2], cospi[48], b[3]),
        clamp16(addW(b[4], b[5])),
        clamp16(subW(b[4], b[5])),
        clamp16(addW(negW(b[6]), b[7])),
        clamp16(addW(b[6], b[7])),
        b[8],
        halfBtf(-cospi[16], b[9], cospi[48], b[14]),
        halfBtf(-cospi[48], b[10], -cospi[16], b[13]),
        b[11],
        b[12],
        halfBtf(-cospi[16], b[10], cospi[48], b[13]),
        halfBtf(cospi[48], b[9], cospi[16], b[14]),
        b[15],
      ];
      // stage 5
      b = [
        clamp16(addW(b[0], b[3])),
        clamp16(addW(b[1], b[2])),
        clamp16(subW(b[1], b[2])),
        clamp16(subW(b[0], b[3])),
        b[4],
        halfBtf(-cospi[32], b[5], cospi[32], b[6]),
        halfBtf(cospi[32], b[5], cospi[32], b[6]),
        b[7],
        clamp16(addW(b[8], b[11])),
        clamp16(addW(b[9], b[10])),
        clamp16(subW(b[9], b[10])),
        clamp16(subW(b[8], b[11])),
        clamp16(addW(negW(b[12]), b[15])),
        clamp16(addW(negW(b[13]), b[14])),
        clamp16(addW(b[13], b[14])),
        clamp16(addW(b[12], b[15])),
      ];
      // stage 6
      b = [
        clamp16(addW(b[0], b[7])),
        clamp16(addW(b[1], b[6])),
        clamp16(addW(b[2], b[5])),
        clamp16(addW(b[3], b[4])),
        clamp16(subW(b[3], b[4])),
        clamp16(subW(b[2], b[5])),
        clamp16(subW(b[1], b[6])),
        clamp16(subW(b[0], b[7])),
        b[8],
        b[9],
        halfBtf(-cospi[32], b[10], cospi[32], b[13]),
        halfBtf(-cospi[32], b[11], cospi[32], b[12]),
        halfBtf(cospi[32], b[11], cospi[32], b[12]),
        halfBtf(cospi[32], b[10], cospi[32], b[13]),
        b[14],
        b[15],
      ];
      // stage 7
      return [
        clamp16(addW(b[0], b[15])),
        clamp16(addW(b[1], b[14])),
        clamp16(addW(b[2], b[13])),
        clamp16(addW(b[3], b[12])),
        clamp16(addW(b[4], b[11])),
        clamp16(addW(b[5], b[10])),
        clamp16(addW(b[6], b[9])),
        clamp16(addW(b[7], b[8])),
        clamp16(subW(b[7], b[8])),
        clamp16(subW(b[6], b[9])),
        clamp16(subW(b[5], b[10])),
        clamp16(subW(b[4], b[11])),
        clamp16(subW(b[3], b[12])),
        clamp16(subW(b[2], b[13])),
        clamp16(subW(b[1], b[14])),
        clamp16(subW(b[0], b[15])),
      ];
    }

    List<Logic> iadst16(List<Logic> i) {
      // stage 1
      var b = [
        i[15],
        i[0],
        i[13],
        i[2],
        i[11],
        i[4],
        i[9],
        i[6],
        i[7],
        i[8],
        i[5],
        i[10],
        i[3],
        i[12],
        i[1],
        i[14],
      ];
      // stage 2
      b = [
        halfBtf(cospi[2], b[0], cospi[62], b[1]),
        halfBtf(cospi[62], b[0], -cospi[2], b[1]),
        halfBtf(cospi[10], b[2], cospi[54], b[3]),
        halfBtf(cospi[54], b[2], -cospi[10], b[3]),
        halfBtf(cospi[18], b[4], cospi[46], b[5]),
        halfBtf(cospi[46], b[4], -cospi[18], b[5]),
        halfBtf(cospi[26], b[6], cospi[38], b[7]),
        halfBtf(cospi[38], b[6], -cospi[26], b[7]),
        halfBtf(cospi[34], b[8], cospi[30], b[9]),
        halfBtf(cospi[30], b[8], -cospi[34], b[9]),
        halfBtf(cospi[42], b[10], cospi[22], b[11]),
        halfBtf(cospi[22], b[10], -cospi[42], b[11]),
        halfBtf(cospi[50], b[12], cospi[14], b[13]),
        halfBtf(cospi[14], b[12], -cospi[50], b[13]),
        halfBtf(cospi[58], b[14], cospi[6], b[15]),
        halfBtf(cospi[6], b[14], -cospi[58], b[15]),
      ];
      // stage 3
      b = [
        clamp16(addW(b[0], b[8])),
        clamp16(addW(b[1], b[9])),
        clamp16(addW(b[2], b[10])),
        clamp16(addW(b[3], b[11])),
        clamp16(addW(b[4], b[12])),
        clamp16(addW(b[5], b[13])),
        clamp16(addW(b[6], b[14])),
        clamp16(addW(b[7], b[15])),
        clamp16(subW(b[0], b[8])),
        clamp16(subW(b[1], b[9])),
        clamp16(subW(b[2], b[10])),
        clamp16(subW(b[3], b[11])),
        clamp16(subW(b[4], b[12])),
        clamp16(subW(b[5], b[13])),
        clamp16(subW(b[6], b[14])),
        clamp16(subW(b[7], b[15])),
      ];
      // stage 4
      b = [
        b[0],
        b[1],
        b[2],
        b[3],
        b[4],
        b[5],
        b[6],
        b[7],
        halfBtf(cospi[8], b[8], cospi[56], b[9]),
        halfBtf(cospi[56], b[8], -cospi[8], b[9]),
        halfBtf(cospi[40], b[10], cospi[24], b[11]),
        halfBtf(cospi[24], b[10], -cospi[40], b[11]),
        halfBtf(-cospi[56], b[12], cospi[8], b[13]),
        halfBtf(cospi[8], b[12], cospi[56], b[13]),
        halfBtf(-cospi[24], b[14], cospi[40], b[15]),
        halfBtf(cospi[40], b[14], cospi[24], b[15]),
      ];
      // stage 5
      b = [
        clamp16(addW(b[0], b[4])),
        clamp16(addW(b[1], b[5])),
        clamp16(addW(b[2], b[6])),
        clamp16(addW(b[3], b[7])),
        clamp16(subW(b[0], b[4])),
        clamp16(subW(b[1], b[5])),
        clamp16(subW(b[2], b[6])),
        clamp16(subW(b[3], b[7])),
        clamp16(addW(b[8], b[12])),
        clamp16(addW(b[9], b[13])),
        clamp16(addW(b[10], b[14])),
        clamp16(addW(b[11], b[15])),
        clamp16(subW(b[8], b[12])),
        clamp16(subW(b[9], b[13])),
        clamp16(subW(b[10], b[14])),
        clamp16(subW(b[11], b[15])),
      ];
      // stage 6
      b = [
        b[0],
        b[1],
        b[2],
        b[3],
        halfBtf(cospi[16], b[4], cospi[48], b[5]),
        halfBtf(cospi[48], b[4], -cospi[16], b[5]),
        halfBtf(-cospi[48], b[6], cospi[16], b[7]),
        halfBtf(cospi[16], b[6], cospi[48], b[7]),
        b[8],
        b[9],
        b[10],
        b[11],
        halfBtf(cospi[16], b[12], cospi[48], b[13]),
        halfBtf(cospi[48], b[12], -cospi[16], b[13]),
        halfBtf(-cospi[48], b[14], cospi[16], b[15]),
        halfBtf(cospi[16], b[14], cospi[48], b[15]),
      ];
      // stage 7
      b = [
        clamp16(addW(b[0], b[2])),
        clamp16(addW(b[1], b[3])),
        clamp16(subW(b[0], b[2])),
        clamp16(subW(b[1], b[3])),
        clamp16(addW(b[4], b[6])),
        clamp16(addW(b[5], b[7])),
        clamp16(subW(b[4], b[6])),
        clamp16(subW(b[5], b[7])),
        clamp16(addW(b[8], b[10])),
        clamp16(addW(b[9], b[11])),
        clamp16(subW(b[8], b[10])),
        clamp16(subW(b[9], b[11])),
        clamp16(addW(b[12], b[14])),
        clamp16(addW(b[13], b[15])),
        clamp16(subW(b[12], b[14])),
        clamp16(subW(b[13], b[15])),
      ];
      // stage 8
      b = [
        b[0],
        b[1],
        halfBtf(cospi[32], b[2], cospi[32], b[3]),
        halfBtf(cospi[32], b[2], -cospi[32], b[3]),
        b[4],
        b[5],
        halfBtf(cospi[32], b[6], cospi[32], b[7]),
        halfBtf(cospi[32], b[6], -cospi[32], b[7]),
        b[8],
        b[9],
        halfBtf(cospi[32], b[10], cospi[32], b[11]),
        halfBtf(cospi[32], b[10], -cospi[32], b[11]),
        b[12],
        b[13],
        halfBtf(cospi[32], b[14], cospi[32], b[15]),
        halfBtf(cospi[32], b[14], -cospi[32], b[15]),
      ];
      // stage 9
      return [
        b[0],
        negW(b[8]),
        b[12],
        negW(b[4]),
        b[6],
        negW(b[14]),
        b[10],
        negW(b[2]),
        b[3],
        negW(b[11]),
        b[15],
        negW(b[7]),
        b[5],
        negW(b[13]),
        b[9],
        negW(b[1]),
      ];
    }

    List<Logic> iidentity4(List<Logic> i) => [
      for (final v in i) roundShift(mulW(v, newSqrt2), newSqrt2Bits),
    ];
    List<Logic> iidentity8(List<Logic> i) => [
      for (final v in i) s32(mulW(v, 2)),
    ];
    List<Logic> iidentity16(List<Logic> i) => [
      for (final v in i) roundShift(mulW(v, newSqrt2 * 2), newSqrt2Bits),
    ];
    List<Logic> iidentity32(List<Logic> i) => [
      for (final v in i) s32(mulW(v, 4)),
    ];

    List<Logic> idct32(List<Logic> i) {
      final o = List<Logic>.filled(32, Const(0, width: w));
      final s = List<Logic>.filled(32, Const(0, width: w));
      Logic hb(int a, Logic x, int b, Logic y) => halfBtf(a, x, b, y);
      // stage 1
      const p1 = [
        0, 16, 8, 24, 4, 20, 12, 28, 2, 18, 10, 26, 6, 22, 14, 30, //
        1, 17, 9, 25, 5, 21, 13, 29, 3, 19, 11, 27, 7, 23, 15, 31,
      ];
      for (var k = 0; k < 32; k++) {
        o[k] = i[p1[k]];
      }
      // stage 2 (bf0=o, bf1=s)
      for (var k = 0; k < 16; k++) {
        s[k] = o[k];
      }
      s[16] = hb(cospi[62], o[16], -cospi[2], o[31]);
      s[17] = hb(cospi[30], o[17], -cospi[34], o[30]);
      s[18] = hb(cospi[46], o[18], -cospi[18], o[29]);
      s[19] = hb(cospi[14], o[19], -cospi[50], o[28]);
      s[20] = hb(cospi[54], o[20], -cospi[10], o[27]);
      s[21] = hb(cospi[22], o[21], -cospi[42], o[26]);
      s[22] = hb(cospi[38], o[22], -cospi[26], o[25]);
      s[23] = hb(cospi[6], o[23], -cospi[58], o[24]);
      s[24] = hb(cospi[58], o[23], cospi[6], o[24]);
      s[25] = hb(cospi[26], o[22], cospi[38], o[25]);
      s[26] = hb(cospi[42], o[21], cospi[22], o[26]);
      s[27] = hb(cospi[10], o[20], cospi[54], o[27]);
      s[28] = hb(cospi[50], o[19], cospi[14], o[28]);
      s[29] = hb(cospi[18], o[18], cospi[46], o[29]);
      s[30] = hb(cospi[34], o[17], cospi[30], o[30]);
      s[31] = hb(cospi[2], o[16], cospi[62], o[31]);
      // stage 3 (bf0=s, bf1=o)
      for (var k = 0; k < 8; k++) {
        o[k] = s[k];
      }
      o[8] = hb(cospi[60], s[8], -cospi[4], s[15]);
      o[9] = hb(cospi[28], s[9], -cospi[36], s[14]);
      o[10] = hb(cospi[44], s[10], -cospi[20], s[13]);
      o[11] = hb(cospi[12], s[11], -cospi[52], s[12]);
      o[12] = hb(cospi[52], s[11], cospi[12], s[12]);
      o[13] = hb(cospi[20], s[10], cospi[44], s[13]);
      o[14] = hb(cospi[36], s[9], cospi[28], s[14]);
      o[15] = hb(cospi[4], s[8], cospi[60], s[15]);
      o[16] = ca(s[16], s[17]);
      o[17] = cs(s[16], s[17]);
      o[18] = cna(s[18], s[19]);
      o[19] = ca(s[18], s[19]);
      o[20] = ca(s[20], s[21]);
      o[21] = cs(s[20], s[21]);
      o[22] = cna(s[22], s[23]);
      o[23] = ca(s[22], s[23]);
      o[24] = ca(s[24], s[25]);
      o[25] = cs(s[24], s[25]);
      o[26] = cna(s[26], s[27]);
      o[27] = ca(s[26], s[27]);
      o[28] = ca(s[28], s[29]);
      o[29] = cs(s[28], s[29]);
      o[30] = cna(s[30], s[31]);
      o[31] = ca(s[30], s[31]);
      // stage 4 (bf0=o, bf1=s)
      for (var k = 0; k < 4; k++) {
        s[k] = o[k];
      }
      s[4] = hb(cospi[56], o[4], -cospi[8], o[7]);
      s[5] = hb(cospi[24], o[5], -cospi[40], o[6]);
      s[6] = hb(cospi[40], o[5], cospi[24], o[6]);
      s[7] = hb(cospi[8], o[4], cospi[56], o[7]);
      s[8] = ca(o[8], o[9]);
      s[9] = cs(o[8], o[9]);
      s[10] = cna(o[10], o[11]);
      s[11] = ca(o[10], o[11]);
      s[12] = ca(o[12], o[13]);
      s[13] = cs(o[12], o[13]);
      s[14] = cna(o[14], o[15]);
      s[15] = ca(o[14], o[15]);
      s[16] = o[16];
      s[17] = hb(-cospi[8], o[17], cospi[56], o[30]);
      s[18] = hb(-cospi[56], o[18], -cospi[8], o[29]);
      s[19] = o[19];
      s[20] = o[20];
      s[21] = hb(-cospi[40], o[21], cospi[24], o[26]);
      s[22] = hb(-cospi[24], o[22], -cospi[40], o[25]);
      s[23] = o[23];
      s[24] = o[24];
      s[25] = hb(-cospi[40], o[22], cospi[24], o[25]);
      s[26] = hb(cospi[24], o[21], cospi[40], o[26]);
      s[27] = o[27];
      s[28] = o[28];
      s[29] = hb(-cospi[8], o[18], cospi[56], o[29]);
      s[30] = hb(cospi[56], o[17], cospi[8], o[30]);
      s[31] = o[31];
      // stage 5 (bf0=s, bf1=o)
      o[0] = hb(cospi[32], s[0], cospi[32], s[1]);
      o[1] = hb(cospi[32], s[0], -cospi[32], s[1]);
      o[2] = hb(cospi[48], s[2], -cospi[16], s[3]);
      o[3] = hb(cospi[16], s[2], cospi[48], s[3]);
      o[4] = ca(s[4], s[5]);
      o[5] = cs(s[4], s[5]);
      o[6] = cna(s[6], s[7]);
      o[7] = ca(s[6], s[7]);
      o[8] = s[8];
      o[9] = hb(-cospi[16], s[9], cospi[48], s[14]);
      o[10] = hb(-cospi[48], s[10], -cospi[16], s[13]);
      o[11] = s[11];
      o[12] = s[12];
      o[13] = hb(-cospi[16], s[10], cospi[48], s[13]);
      o[14] = hb(cospi[48], s[9], cospi[16], s[14]);
      o[15] = s[15];
      o[16] = ca(s[16], s[19]);
      o[17] = ca(s[17], s[18]);
      o[18] = cs(s[17], s[18]);
      o[19] = cs(s[16], s[19]);
      o[20] = cna(s[20], s[23]);
      o[21] = cna(s[21], s[22]);
      o[22] = ca(s[21], s[22]);
      o[23] = ca(s[20], s[23]);
      o[24] = ca(s[24], s[27]);
      o[25] = ca(s[25], s[26]);
      o[26] = cs(s[25], s[26]);
      o[27] = cs(s[24], s[27]);
      o[28] = cna(s[28], s[31]);
      o[29] = cna(s[29], s[30]);
      o[30] = ca(s[29], s[30]);
      o[31] = ca(s[28], s[31]);
      // stage 6 (bf0=o, bf1=s)
      s[0] = ca(o[0], o[3]);
      s[1] = ca(o[1], o[2]);
      s[2] = cs(o[1], o[2]);
      s[3] = cs(o[0], o[3]);
      s[4] = o[4];
      s[5] = hb(-cospi[32], o[5], cospi[32], o[6]);
      s[6] = hb(cospi[32], o[5], cospi[32], o[6]);
      s[7] = o[7];
      s[8] = ca(o[8], o[11]);
      s[9] = ca(o[9], o[10]);
      s[10] = cs(o[9], o[10]);
      s[11] = cs(o[8], o[11]);
      s[12] = cna(o[12], o[15]);
      s[13] = cna(o[13], o[14]);
      s[14] = ca(o[13], o[14]);
      s[15] = ca(o[12], o[15]);
      s[16] = o[16];
      s[17] = o[17];
      s[18] = hb(-cospi[16], o[18], cospi[48], o[29]);
      s[19] = hb(-cospi[16], o[19], cospi[48], o[28]);
      s[20] = hb(-cospi[48], o[20], -cospi[16], o[27]);
      s[21] = hb(-cospi[48], o[21], -cospi[16], o[26]);
      s[22] = o[22];
      s[23] = o[23];
      s[24] = o[24];
      s[25] = o[25];
      s[26] = hb(-cospi[16], o[21], cospi[48], o[26]);
      s[27] = hb(-cospi[16], o[20], cospi[48], o[27]);
      s[28] = hb(cospi[48], o[19], cospi[16], o[28]);
      s[29] = hb(cospi[48], o[18], cospi[16], o[29]);
      s[30] = o[30];
      s[31] = o[31];
      // stage 7 (bf0=s, bf1=o)
      o[0] = ca(s[0], s[7]);
      o[1] = ca(s[1], s[6]);
      o[2] = ca(s[2], s[5]);
      o[3] = ca(s[3], s[4]);
      o[4] = cs(s[3], s[4]);
      o[5] = cs(s[2], s[5]);
      o[6] = cs(s[1], s[6]);
      o[7] = cs(s[0], s[7]);
      o[8] = s[8];
      o[9] = s[9];
      o[10] = hb(-cospi[32], s[10], cospi[32], s[13]);
      o[11] = hb(-cospi[32], s[11], cospi[32], s[12]);
      o[12] = hb(cospi[32], s[11], cospi[32], s[12]);
      o[13] = hb(cospi[32], s[10], cospi[32], s[13]);
      o[14] = s[14];
      o[15] = s[15];
      o[16] = ca(s[16], s[23]);
      o[17] = ca(s[17], s[22]);
      o[18] = ca(s[18], s[21]);
      o[19] = ca(s[19], s[20]);
      o[20] = cs(s[19], s[20]);
      o[21] = cs(s[18], s[21]);
      o[22] = cs(s[17], s[22]);
      o[23] = cs(s[16], s[23]);
      o[24] = cna(s[24], s[31]);
      o[25] = cna(s[25], s[30]);
      o[26] = cna(s[26], s[29]);
      o[27] = cna(s[27], s[28]);
      o[28] = ca(s[27], s[28]);
      o[29] = ca(s[26], s[29]);
      o[30] = ca(s[25], s[30]);
      o[31] = ca(s[24], s[31]);
      // stage 8 (bf0=o, bf1=s)
      for (var k = 0; k < 16; k++) {
        s[k] = (k < 8) ? ca(o[k], o[15 - k]) : cs(o[15 - k], o[k]);
      }
      s[16] = o[16];
      s[17] = o[17];
      s[18] = o[18];
      s[19] = o[19];
      s[20] = hb(-cospi[32], o[20], cospi[32], o[27]);
      s[21] = hb(-cospi[32], o[21], cospi[32], o[26]);
      s[22] = hb(-cospi[32], o[22], cospi[32], o[25]);
      s[23] = hb(-cospi[32], o[23], cospi[32], o[24]);
      s[24] = hb(cospi[32], o[23], cospi[32], o[24]);
      s[25] = hb(cospi[32], o[22], cospi[32], o[25]);
      s[26] = hb(cospi[32], o[21], cospi[32], o[26]);
      s[27] = hb(cospi[32], o[20], cospi[32], o[27]);
      s[28] = o[28];
      s[29] = o[29];
      s[30] = o[30];
      s[31] = o[31];
      // stage 9 (bf0=s, bf1=o)
      for (var k = 0; k < 16; k++) {
        o[k] = ca(s[k], s[31 - k]);
      }
      for (var k = 16; k < 32; k++) {
        o[k] = cs(s[31 - k], s[k]);
      }
      return o;
    }

    List<Logic> idct64(List<Logic> i) {
      final o = List<Logic>.filled(64, Const(0, width: w));
      final s = List<Logic>.filled(64, Const(0, width: w));
      Logic hb(int a, Logic x, int b, Logic y) => halfBtf(a, x, b, y);
      // stage 1
      const p1 = [
        0, 32, 16, 48, 8, 40, 24, 56, 4, 36, 20, 52, 12, 44, 28, 60, //
        2, 34, 18, 50, 10, 42, 26, 58, 6, 38, 22, 54, 14, 46, 30, 62, //
        1, 33, 17, 49, 9, 41, 25, 57, 5, 37, 21, 53, 13, 45, 29, 61, //
        3, 35, 19, 51, 11, 43, 27, 59, 7, 39, 23, 55, 15, 47, 31, 63,
      ];
      for (var k = 0; k < 64; k++) {
        o[k] = i[p1[k]];
      }
      // stage 2 (bf0=o, bf1=s)
      for (var k = 0; k < 32; k++) {
        s[k] = o[k];
      }
      s[32] = hb(cospi[63], o[32], -cospi[1], o[63]);
      s[33] = hb(cospi[31], o[33], -cospi[33], o[62]);
      s[34] = hb(cospi[47], o[34], -cospi[17], o[61]);
      s[35] = hb(cospi[15], o[35], -cospi[49], o[60]);
      s[36] = hb(cospi[55], o[36], -cospi[9], o[59]);
      s[37] = hb(cospi[23], o[37], -cospi[41], o[58]);
      s[38] = hb(cospi[39], o[38], -cospi[25], o[57]);
      s[39] = hb(cospi[7], o[39], -cospi[57], o[56]);
      s[40] = hb(cospi[59], o[40], -cospi[5], o[55]);
      s[41] = hb(cospi[27], o[41], -cospi[37], o[54]);
      s[42] = hb(cospi[43], o[42], -cospi[21], o[53]);
      s[43] = hb(cospi[11], o[43], -cospi[53], o[52]);
      s[44] = hb(cospi[51], o[44], -cospi[13], o[51]);
      s[45] = hb(cospi[19], o[45], -cospi[45], o[50]);
      s[46] = hb(cospi[35], o[46], -cospi[29], o[49]);
      s[47] = hb(cospi[3], o[47], -cospi[61], o[48]);
      s[48] = hb(cospi[61], o[47], cospi[3], o[48]);
      s[49] = hb(cospi[29], o[46], cospi[35], o[49]);
      s[50] = hb(cospi[45], o[45], cospi[19], o[50]);
      s[51] = hb(cospi[13], o[44], cospi[51], o[51]);
      s[52] = hb(cospi[53], o[43], cospi[11], o[52]);
      s[53] = hb(cospi[21], o[42], cospi[43], o[53]);
      s[54] = hb(cospi[37], o[41], cospi[27], o[54]);
      s[55] = hb(cospi[5], o[40], cospi[59], o[55]);
      s[56] = hb(cospi[57], o[39], cospi[7], o[56]);
      s[57] = hb(cospi[25], o[38], cospi[39], o[57]);
      s[58] = hb(cospi[41], o[37], cospi[23], o[58]);
      s[59] = hb(cospi[9], o[36], cospi[55], o[59]);
      s[60] = hb(cospi[49], o[35], cospi[15], o[60]);
      s[61] = hb(cospi[17], o[34], cospi[47], o[61]);
      s[62] = hb(cospi[33], o[33], cospi[31], o[62]);
      s[63] = hb(cospi[1], o[32], cospi[63], o[63]);
      // stage 3 (bf0=s, bf1=o)
      for (var k = 0; k < 16; k++) {
        o[k] = s[k];
      }
      o[16] = hb(cospi[62], s[16], -cospi[2], s[31]);
      o[17] = hb(cospi[30], s[17], -cospi[34], s[30]);
      o[18] = hb(cospi[46], s[18], -cospi[18], s[29]);
      o[19] = hb(cospi[14], s[19], -cospi[50], s[28]);
      o[20] = hb(cospi[54], s[20], -cospi[10], s[27]);
      o[21] = hb(cospi[22], s[21], -cospi[42], s[26]);
      o[22] = hb(cospi[38], s[22], -cospi[26], s[25]);
      o[23] = hb(cospi[6], s[23], -cospi[58], s[24]);
      o[24] = hb(cospi[58], s[23], cospi[6], s[24]);
      o[25] = hb(cospi[26], s[22], cospi[38], s[25]);
      o[26] = hb(cospi[42], s[21], cospi[22], s[26]);
      o[27] = hb(cospi[10], s[20], cospi[54], s[27]);
      o[28] = hb(cospi[50], s[19], cospi[14], s[28]);
      o[29] = hb(cospi[18], s[18], cospi[46], s[29]);
      o[30] = hb(cospi[34], s[17], cospi[30], s[30]);
      o[31] = hb(cospi[2], s[16], cospi[62], s[31]);
      o[32] = ca(s[32], s[33]);
      o[33] = cs(s[32], s[33]);
      o[34] = cna(s[34], s[35]);
      o[35] = ca(s[34], s[35]);
      o[36] = ca(s[36], s[37]);
      o[37] = cs(s[36], s[37]);
      o[38] = cna(s[38], s[39]);
      o[39] = ca(s[38], s[39]);
      o[40] = ca(s[40], s[41]);
      o[41] = cs(s[40], s[41]);
      o[42] = cna(s[42], s[43]);
      o[43] = ca(s[42], s[43]);
      o[44] = ca(s[44], s[45]);
      o[45] = cs(s[44], s[45]);
      o[46] = cna(s[46], s[47]);
      o[47] = ca(s[46], s[47]);
      o[48] = ca(s[48], s[49]);
      o[49] = cs(s[48], s[49]);
      o[50] = cna(s[50], s[51]);
      o[51] = ca(s[50], s[51]);
      o[52] = ca(s[52], s[53]);
      o[53] = cs(s[52], s[53]);
      o[54] = cna(s[54], s[55]);
      o[55] = ca(s[54], s[55]);
      o[56] = ca(s[56], s[57]);
      o[57] = cs(s[56], s[57]);
      o[58] = cna(s[58], s[59]);
      o[59] = ca(s[58], s[59]);
      o[60] = ca(s[60], s[61]);
      o[61] = cs(s[60], s[61]);
      o[62] = cna(s[62], s[63]);
      o[63] = ca(s[62], s[63]);
      // stage 4 (bf0=o, bf1=s)
      for (var k = 0; k < 8; k++) {
        s[k] = o[k];
      }
      s[8] = hb(cospi[60], o[8], -cospi[4], o[15]);
      s[9] = hb(cospi[28], o[9], -cospi[36], o[14]);
      s[10] = hb(cospi[44], o[10], -cospi[20], o[13]);
      s[11] = hb(cospi[12], o[11], -cospi[52], o[12]);
      s[12] = hb(cospi[52], o[11], cospi[12], o[12]);
      s[13] = hb(cospi[20], o[10], cospi[44], o[13]);
      s[14] = hb(cospi[36], o[9], cospi[28], o[14]);
      s[15] = hb(cospi[4], o[8], cospi[60], o[15]);
      s[16] = ca(o[16], o[17]);
      s[17] = cs(o[16], o[17]);
      s[18] = cna(o[18], o[19]);
      s[19] = ca(o[18], o[19]);
      s[20] = ca(o[20], o[21]);
      s[21] = cs(o[20], o[21]);
      s[22] = cna(o[22], o[23]);
      s[23] = ca(o[22], o[23]);
      s[24] = ca(o[24], o[25]);
      s[25] = cs(o[24], o[25]);
      s[26] = cna(o[26], o[27]);
      s[27] = ca(o[26], o[27]);
      s[28] = ca(o[28], o[29]);
      s[29] = cs(o[28], o[29]);
      s[30] = cna(o[30], o[31]);
      s[31] = ca(o[30], o[31]);
      s[32] = o[32];
      s[33] = hb(-cospi[4], o[33], cospi[60], o[62]);
      s[34] = hb(-cospi[60], o[34], -cospi[4], o[61]);
      s[35] = o[35];
      s[36] = o[36];
      s[37] = hb(-cospi[36], o[37], cospi[28], o[58]);
      s[38] = hb(-cospi[28], o[38], -cospi[36], o[57]);
      s[39] = o[39];
      s[40] = o[40];
      s[41] = hb(-cospi[20], o[41], cospi[44], o[54]);
      s[42] = hb(-cospi[44], o[42], -cospi[20], o[53]);
      s[43] = o[43];
      s[44] = o[44];
      s[45] = hb(-cospi[52], o[45], cospi[12], o[50]);
      s[46] = hb(-cospi[12], o[46], -cospi[52], o[49]);
      s[47] = o[47];
      s[48] = o[48];
      s[49] = hb(-cospi[52], o[46], cospi[12], o[49]);
      s[50] = hb(cospi[12], o[45], cospi[52], o[50]);
      s[51] = o[51];
      s[52] = o[52];
      s[53] = hb(-cospi[20], o[42], cospi[44], o[53]);
      s[54] = hb(cospi[44], o[41], cospi[20], o[54]);
      s[55] = o[55];
      s[56] = o[56];
      s[57] = hb(-cospi[36], o[38], cospi[28], o[57]);
      s[58] = hb(cospi[28], o[37], cospi[36], o[58]);
      s[59] = o[59];
      s[60] = o[60];
      s[61] = hb(-cospi[4], o[34], cospi[60], o[61]);
      s[62] = hb(cospi[60], o[33], cospi[4], o[62]);
      s[63] = o[63];
      // stage 5 (bf0=s, bf1=o)
      for (var k = 0; k < 4; k++) {
        o[k] = s[k];
      }
      o[4] = hb(cospi[56], s[4], -cospi[8], s[7]);
      o[5] = hb(cospi[24], s[5], -cospi[40], s[6]);
      o[6] = hb(cospi[40], s[5], cospi[24], s[6]);
      o[7] = hb(cospi[8], s[4], cospi[56], s[7]);
      o[8] = ca(s[8], s[9]);
      o[9] = cs(s[8], s[9]);
      o[10] = cna(s[10], s[11]);
      o[11] = ca(s[10], s[11]);
      o[12] = ca(s[12], s[13]);
      o[13] = cs(s[12], s[13]);
      o[14] = cna(s[14], s[15]);
      o[15] = ca(s[14], s[15]);
      o[16] = s[16];
      o[17] = hb(-cospi[8], s[17], cospi[56], s[30]);
      o[18] = hb(-cospi[56], s[18], -cospi[8], s[29]);
      o[19] = s[19];
      o[20] = s[20];
      o[21] = hb(-cospi[40], s[21], cospi[24], s[26]);
      o[22] = hb(-cospi[24], s[22], -cospi[40], s[25]);
      o[23] = s[23];
      o[24] = s[24];
      o[25] = hb(-cospi[40], s[22], cospi[24], s[25]);
      o[26] = hb(cospi[24], s[21], cospi[40], s[26]);
      o[27] = s[27];
      o[28] = s[28];
      o[29] = hb(-cospi[8], s[18], cospi[56], s[29]);
      o[30] = hb(cospi[56], s[17], cospi[8], s[30]);
      o[31] = s[31];
      o[32] = ca(s[32], s[35]);
      o[33] = ca(s[33], s[34]);
      o[34] = cs(s[33], s[34]);
      o[35] = cs(s[32], s[35]);
      o[36] = cna(s[36], s[39]);
      o[37] = cna(s[37], s[38]);
      o[38] = ca(s[37], s[38]);
      o[39] = ca(s[36], s[39]);
      o[40] = ca(s[40], s[43]);
      o[41] = ca(s[41], s[42]);
      o[42] = cs(s[41], s[42]);
      o[43] = cs(s[40], s[43]);
      o[44] = cna(s[44], s[47]);
      o[45] = cna(s[45], s[46]);
      o[46] = ca(s[45], s[46]);
      o[47] = ca(s[44], s[47]);
      o[48] = ca(s[48], s[51]);
      o[49] = ca(s[49], s[50]);
      o[50] = cs(s[49], s[50]);
      o[51] = cs(s[48], s[51]);
      o[52] = cna(s[52], s[55]);
      o[53] = cna(s[53], s[54]);
      o[54] = ca(s[53], s[54]);
      o[55] = ca(s[52], s[55]);
      o[56] = ca(s[56], s[59]);
      o[57] = ca(s[57], s[58]);
      o[58] = cs(s[57], s[58]);
      o[59] = cs(s[56], s[59]);
      o[60] = cna(s[60], s[63]);
      o[61] = cna(s[61], s[62]);
      o[62] = ca(s[61], s[62]);
      o[63] = ca(s[60], s[63]);
      // stage 6 (bf0=o, bf1=s)
      s[0] = hb(cospi[32], o[0], cospi[32], o[1]);
      s[1] = hb(cospi[32], o[0], -cospi[32], o[1]);
      s[2] = hb(cospi[48], o[2], -cospi[16], o[3]);
      s[3] = hb(cospi[16], o[2], cospi[48], o[3]);
      s[4] = ca(o[4], o[5]);
      s[5] = cs(o[4], o[5]);
      s[6] = cna(o[6], o[7]);
      s[7] = ca(o[6], o[7]);
      s[8] = o[8];
      s[9] = hb(-cospi[16], o[9], cospi[48], o[14]);
      s[10] = hb(-cospi[48], o[10], -cospi[16], o[13]);
      s[11] = o[11];
      s[12] = o[12];
      s[13] = hb(-cospi[16], o[10], cospi[48], o[13]);
      s[14] = hb(cospi[48], o[9], cospi[16], o[14]);
      s[15] = o[15];
      s[16] = ca(o[16], o[19]);
      s[17] = ca(o[17], o[18]);
      s[18] = cs(o[17], o[18]);
      s[19] = cs(o[16], o[19]);
      s[20] = cna(o[20], o[23]);
      s[21] = cna(o[21], o[22]);
      s[22] = ca(o[21], o[22]);
      s[23] = ca(o[20], o[23]);
      s[24] = ca(o[24], o[27]);
      s[25] = ca(o[25], o[26]);
      s[26] = cs(o[25], o[26]);
      s[27] = cs(o[24], o[27]);
      s[28] = cna(o[28], o[31]);
      s[29] = cna(o[29], o[30]);
      s[30] = ca(o[29], o[30]);
      s[31] = ca(o[28], o[31]);
      s[32] = o[32];
      s[33] = o[33];
      s[34] = hb(-cospi[8], o[34], cospi[56], o[61]);
      s[35] = hb(-cospi[8], o[35], cospi[56], o[60]);
      s[36] = hb(-cospi[56], o[36], -cospi[8], o[59]);
      s[37] = hb(-cospi[56], o[37], -cospi[8], o[58]);
      s[38] = o[38];
      s[39] = o[39];
      s[40] = o[40];
      s[41] = o[41];
      s[42] = hb(-cospi[40], o[42], cospi[24], o[53]);
      s[43] = hb(-cospi[40], o[43], cospi[24], o[52]);
      s[44] = hb(-cospi[24], o[44], -cospi[40], o[51]);
      s[45] = hb(-cospi[24], o[45], -cospi[40], o[50]);
      s[46] = o[46];
      s[47] = o[47];
      s[48] = o[48];
      s[49] = o[49];
      s[50] = hb(-cospi[40], o[45], cospi[24], o[50]);
      s[51] = hb(-cospi[40], o[44], cospi[24], o[51]);
      s[52] = hb(cospi[24], o[43], cospi[40], o[52]);
      s[53] = hb(cospi[24], o[42], cospi[40], o[53]);
      s[54] = o[54];
      s[55] = o[55];
      s[56] = o[56];
      s[57] = o[57];
      s[58] = hb(-cospi[8], o[37], cospi[56], o[58]);
      s[59] = hb(-cospi[8], o[36], cospi[56], o[59]);
      s[60] = hb(cospi[56], o[35], cospi[8], o[60]);
      s[61] = hb(cospi[56], o[34], cospi[8], o[61]);
      s[62] = o[62];
      s[63] = o[63];
      // stage 7 (bf0=s, bf1=o)
      o[0] = ca(s[0], s[3]);
      o[1] = ca(s[1], s[2]);
      o[2] = cs(s[1], s[2]);
      o[3] = cs(s[0], s[3]);
      o[4] = s[4];
      o[5] = hb(-cospi[32], s[5], cospi[32], s[6]);
      o[6] = hb(cospi[32], s[5], cospi[32], s[6]);
      o[7] = s[7];
      o[8] = ca(s[8], s[11]);
      o[9] = ca(s[9], s[10]);
      o[10] = cs(s[9], s[10]);
      o[11] = cs(s[8], s[11]);
      o[12] = cna(s[12], s[15]);
      o[13] = cna(s[13], s[14]);
      o[14] = ca(s[13], s[14]);
      o[15] = ca(s[12], s[15]);
      o[16] = s[16];
      o[17] = s[17];
      o[18] = hb(-cospi[16], s[18], cospi[48], s[29]);
      o[19] = hb(-cospi[16], s[19], cospi[48], s[28]);
      o[20] = hb(-cospi[48], s[20], -cospi[16], s[27]);
      o[21] = hb(-cospi[48], s[21], -cospi[16], s[26]);
      o[22] = s[22];
      o[23] = s[23];
      o[24] = s[24];
      o[25] = s[25];
      o[26] = hb(-cospi[16], s[21], cospi[48], s[26]);
      o[27] = hb(-cospi[16], s[20], cospi[48], s[27]);
      o[28] = hb(cospi[48], s[19], cospi[16], s[28]);
      o[29] = hb(cospi[48], s[18], cospi[16], s[29]);
      o[30] = s[30];
      o[31] = s[31];
      o[32] = ca(s[32], s[39]);
      o[33] = ca(s[33], s[38]);
      o[34] = ca(s[34], s[37]);
      o[35] = ca(s[35], s[36]);
      o[36] = cs(s[35], s[36]);
      o[37] = cs(s[34], s[37]);
      o[38] = cs(s[33], s[38]);
      o[39] = cs(s[32], s[39]);
      o[40] = cna(s[40], s[47]);
      o[41] = cna(s[41], s[46]);
      o[42] = cna(s[42], s[45]);
      o[43] = cna(s[43], s[44]);
      o[44] = ca(s[43], s[44]);
      o[45] = ca(s[42], s[45]);
      o[46] = ca(s[41], s[46]);
      o[47] = ca(s[40], s[47]);
      o[48] = ca(s[48], s[55]);
      o[49] = ca(s[49], s[54]);
      o[50] = ca(s[50], s[53]);
      o[51] = ca(s[51], s[52]);
      o[52] = cs(s[51], s[52]);
      o[53] = cs(s[50], s[53]);
      o[54] = cs(s[49], s[54]);
      o[55] = cs(s[48], s[55]);
      o[56] = cna(s[56], s[63]);
      o[57] = cna(s[57], s[62]);
      o[58] = cna(s[58], s[61]);
      o[59] = cna(s[59], s[60]);
      o[60] = ca(s[59], s[60]);
      o[61] = ca(s[58], s[61]);
      o[62] = ca(s[57], s[62]);
      o[63] = ca(s[56], s[63]);
      // stage 8 (bf0=o, bf1=s)
      s[0] = ca(o[0], o[7]);
      s[1] = ca(o[1], o[6]);
      s[2] = ca(o[2], o[5]);
      s[3] = ca(o[3], o[4]);
      s[4] = cs(o[3], o[4]);
      s[5] = cs(o[2], o[5]);
      s[6] = cs(o[1], o[6]);
      s[7] = cs(o[0], o[7]);
      s[8] = o[8];
      s[9] = o[9];
      s[10] = hb(-cospi[32], o[10], cospi[32], o[13]);
      s[11] = hb(-cospi[32], o[11], cospi[32], o[12]);
      s[12] = hb(cospi[32], o[11], cospi[32], o[12]);
      s[13] = hb(cospi[32], o[10], cospi[32], o[13]);
      s[14] = o[14];
      s[15] = o[15];
      s[16] = ca(o[16], o[23]);
      s[17] = ca(o[17], o[22]);
      s[18] = ca(o[18], o[21]);
      s[19] = ca(o[19], o[20]);
      s[20] = cs(o[19], o[20]);
      s[21] = cs(o[18], o[21]);
      s[22] = cs(o[17], o[22]);
      s[23] = cs(o[16], o[23]);
      s[24] = cna(o[24], o[31]);
      s[25] = cna(o[25], o[30]);
      s[26] = cna(o[26], o[29]);
      s[27] = cna(o[27], o[28]);
      s[28] = ca(o[27], o[28]);
      s[29] = ca(o[26], o[29]);
      s[30] = ca(o[25], o[30]);
      s[31] = ca(o[24], o[31]);
      s[32] = o[32];
      s[33] = o[33];
      s[34] = o[34];
      s[35] = o[35];
      s[36] = hb(-cospi[16], o[36], cospi[48], o[59]);
      s[37] = hb(-cospi[16], o[37], cospi[48], o[58]);
      s[38] = hb(-cospi[16], o[38], cospi[48], o[57]);
      s[39] = hb(-cospi[16], o[39], cospi[48], o[56]);
      s[40] = hb(-cospi[48], o[40], -cospi[16], o[55]);
      s[41] = hb(-cospi[48], o[41], -cospi[16], o[54]);
      s[42] = hb(-cospi[48], o[42], -cospi[16], o[53]);
      s[43] = hb(-cospi[48], o[43], -cospi[16], o[52]);
      s[44] = o[44];
      s[45] = o[45];
      s[46] = o[46];
      s[47] = o[47];
      s[48] = o[48];
      s[49] = o[49];
      s[50] = o[50];
      s[51] = o[51];
      s[52] = hb(-cospi[16], o[43], cospi[48], o[52]);
      s[53] = hb(-cospi[16], o[42], cospi[48], o[53]);
      s[54] = hb(-cospi[16], o[41], cospi[48], o[54]);
      s[55] = hb(-cospi[16], o[40], cospi[48], o[55]);
      s[56] = hb(cospi[48], o[39], cospi[16], o[56]);
      s[57] = hb(cospi[48], o[38], cospi[16], o[57]);
      s[58] = hb(cospi[48], o[37], cospi[16], o[58]);
      s[59] = hb(cospi[48], o[36], cospi[16], o[59]);
      s[60] = o[60];
      s[61] = o[61];
      s[62] = o[62];
      s[63] = o[63];
      // stage 9 (bf0=s, bf1=o)
      for (var k = 0; k < 16; k++) {
        o[k] = (k < 8) ? ca(s[k], s[15 - k]) : cs(s[15 - k], s[k]);
      }
      o[16] = s[16];
      o[17] = s[17];
      o[18] = s[18];
      o[19] = s[19];
      o[20] = hb(-cospi[32], s[20], cospi[32], s[27]);
      o[21] = hb(-cospi[32], s[21], cospi[32], s[26]);
      o[22] = hb(-cospi[32], s[22], cospi[32], s[25]);
      o[23] = hb(-cospi[32], s[23], cospi[32], s[24]);
      o[24] = hb(cospi[32], s[23], cospi[32], s[24]);
      o[25] = hb(cospi[32], s[22], cospi[32], s[25]);
      o[26] = hb(cospi[32], s[21], cospi[32], s[26]);
      o[27] = hb(cospi[32], s[20], cospi[32], s[27]);
      o[28] = s[28];
      o[29] = s[29];
      o[30] = s[30];
      o[31] = s[31];
      o[32] = ca(s[32], s[47]);
      o[33] = ca(s[33], s[46]);
      o[34] = ca(s[34], s[45]);
      o[35] = ca(s[35], s[44]);
      o[36] = ca(s[36], s[43]);
      o[37] = ca(s[37], s[42]);
      o[38] = ca(s[38], s[41]);
      o[39] = ca(s[39], s[40]);
      o[40] = cs(s[39], s[40]);
      o[41] = cs(s[38], s[41]);
      o[42] = cs(s[37], s[42]);
      o[43] = cs(s[36], s[43]);
      o[44] = cs(s[35], s[44]);
      o[45] = cs(s[34], s[45]);
      o[46] = cs(s[33], s[46]);
      o[47] = cs(s[32], s[47]);
      o[48] = cna(s[48], s[63]);
      o[49] = cna(s[49], s[62]);
      o[50] = cna(s[50], s[61]);
      o[51] = cna(s[51], s[60]);
      o[52] = cna(s[52], s[59]);
      o[53] = cna(s[53], s[58]);
      o[54] = cna(s[54], s[57]);
      o[55] = cna(s[55], s[56]);
      o[56] = ca(s[55], s[56]);
      o[57] = ca(s[54], s[57]);
      o[58] = ca(s[53], s[58]);
      o[59] = ca(s[52], s[59]);
      o[60] = ca(s[51], s[60]);
      o[61] = ca(s[50], s[61]);
      o[62] = ca(s[49], s[62]);
      o[63] = ca(s[48], s[63]);
      // stage 10 (bf0=o, bf1=s)
      for (var k = 0; k < 32; k++) {
        s[k] = (k < 16) ? ca(o[k], o[31 - k]) : cs(o[31 - k], o[k]);
      }
      for (var k = 32; k < 40; k++) {
        s[k] = o[k];
      }
      s[40] = hb(-cospi[32], o[40], cospi[32], o[55]);
      s[41] = hb(-cospi[32], o[41], cospi[32], o[54]);
      s[42] = hb(-cospi[32], o[42], cospi[32], o[53]);
      s[43] = hb(-cospi[32], o[43], cospi[32], o[52]);
      s[44] = hb(-cospi[32], o[44], cospi[32], o[51]);
      s[45] = hb(-cospi[32], o[45], cospi[32], o[50]);
      s[46] = hb(-cospi[32], o[46], cospi[32], o[49]);
      s[47] = hb(-cospi[32], o[47], cospi[32], o[48]);
      s[48] = hb(cospi[32], o[47], cospi[32], o[48]);
      s[49] = hb(cospi[32], o[46], cospi[32], o[49]);
      s[50] = hb(cospi[32], o[45], cospi[32], o[50]);
      s[51] = hb(cospi[32], o[44], cospi[32], o[51]);
      s[52] = hb(cospi[32], o[43], cospi[32], o[52]);
      s[53] = hb(cospi[32], o[42], cospi[32], o[53]);
      s[54] = hb(cospi[32], o[41], cospi[32], o[54]);
      s[55] = hb(cospi[32], o[40], cospi[32], o[55]);
      for (var k = 56; k < 64; k++) {
        s[k] = o[k];
      }
      // stage 11 (bf0=s, bf1=o)
      for (var k = 0; k < 32; k++) {
        o[k] = ca(s[k], s[63 - k]);
      }
      for (var k = 32; k < 64; k++) {
        o[k] = cs(s[63 - k], s[k]);
      }
      return o;
    }

    List<Logic> Function(List<Logic>) coreFor(int dim, int type1d) {
      if (type1d == 0) {
        // DCT (all sizes)
        switch (dim) {
          case 4:
            return idct4;
          case 8:
            return idct8;
          case 16:
            return idct16;
          case 32:
            return idct32;
          default:
            return idct64;
        }
      } else if (type1d == 1 || type1d == 2) {
        // ADST / FLIPADST (only valid for dims <= 16, flip at buffer level)
        if (dim == 4) return iadst4;
        if (dim == 8) return iadst8;
        if (dim == 16) return iadst16;
        throw ArgumentError('ADST is undefined for a $dim-point 1D transform');
      } else {
        // IDTX (only valid for dims <= 32)
        switch (dim) {
          case 4:
            return iidentity4;
          case 8:
            return iidentity8;
          case 16:
            return iidentity16;
          case 32:
            return iidentity32;
          default:
            throw ArgumentError('IDTX is undefined for a $dim-point transform');
        }
      }
    }

    // type / flip / shift resolution
    final rowFunc = coreFor(txw, _htxTab[txType]); // horizontal (row), len txw
    final colFunc = coreFor(txh, _vtxTab[txType]); // vertical (col), len txh
    // Build-time flips (runtime intra set has none).
    final udFlip = runtimeTxType ? false : _vtxTab[txType] == 2;
    final lrFlip = runtimeTxType ? false : _htxTab[txType] == 2;

    // Runtime 1D-type select: build DCT/ADST/IDTX cores for the dim and mux per
    // element by the runtime type (0 DCT, 1 ADST, 3 IDTX, FLIPADST unsupported).
    Logic romSel4(List<int> table, Logic idx) {
      Logic v = Const(table.last, width: 4);
      for (var k = table.length - 2; k >= 0; k--) {
        v = mux(
          idx.eq(Const(k, width: idx.width)),
          Const(table[k], width: 4),
          v,
        );
      }
      return v;
    }

    final rowType1d = runtimeTxType
        ? romSel4(_htxTab, input('tx_type')).getRange(0, 2)
        : null;
    final colType1d = runtimeTxType
        ? romSel4(_vtxTab, input('tx_type')).getRange(0, 2)
        : null;

    List<Logic> runtimeCore(int dim, List<Logic> inp, Logic type1d) {
      final dct = coreFor(dim, 0)(inp);
      final adst = dim <= 16 ? coreFor(dim, 1)(inp) : null;
      final idtx = dim <= 32 ? coreFor(dim, 3)(inp) : null;
      return [
        for (var k = 0; k < dim; k++)
          mux(
            type1d.eq(Const(1, width: 2)),
            adst![k],
            mux(type1d.eq(Const(3, width: 2)), idtx![k], dct[k]),
          ),
      ];
    }

    final shift = _invTxfmShiftLs[txSize];
    final rowShiftBit = -shift[0];
    final colShiftBit = -shift[1];
    // rect_type: 0 square, +-1 2:1, +-2 4:1.
    int rectLog(int col, int row) {
      if (col == row) return 0;
      if (col > row) return col == row * 2 ? 1 : 2;
      return row == col * 2 ? -1 : -2;
    }

    final rectType = rectLog(txw, txh);

    // 2D pipeline
    // sequential 2D driver
    //
    // A monolithic combinational 2D transform explodes in area for the larger
    // sizes (one inline core per row AND per column), so this time-multiplexes
    // ONE row core then ONE column core over (txh + txw) cycles, exactly the
    // structure real AV1 transform hardware uses. Pulse `start` with `coeffs`
    // valid. `done` asserts when `residual` holds the result.
    final clk = input('clk');
    final reset = input('reset');
    Logic coeff(int idx) =>
        input('coeffs').getRange(idx * residualW, idx * residualW + residualW);

    const sIdle = 0, sRows = 1, sCols = 2, sDone = 3;
    final state = Logic(name: 'state', width: 2);
    final riW = txh <= 1 ? 1 : (txh - 1).bitLength;
    final ciW = txw <= 1 ? 1 : (txw - 1).bitLength;
    final ri = Logic(name: 'ri', width: riW);
    final ci = Logic(name: 'ci', width: ciW);

    // 64-length dims consume only the top-left 32 coefficients of that dim.
    final colLimit = txw == 64 ? 32 : txw;
    final rowLimit = txh == 64 ? 32 : txh;
    // round-shifted row results (iadst / high bit depth can exceed 16 bits)
    final bufW = rowBits + 4;
    final internalReg = [
      for (var i = 0; i < txw * txh; i++)
        Logic(name: 'int_$i', width: residualW),
    ];
    final bufReg = [
      for (var i = 0; i < txw * txh; i++) Logic(name: 'buf_$i', width: bufW),
    ];
    final resReg = [
      for (var i = 0; i < txw * txh; i++)
        Logic(name: 'res_$i', width: residualW),
    ];

    Logic selByIdx(List<Logic> arr, Logic idx) {
      Logic v = arr.last;
      for (var k = arr.length - 2; k >= 0; k--) {
        v = mux(idx.eq(Const(k, width: idx.width)), arr[k], v);
      }
      return v;
    }

    // Current-row inputs to the row core: internal[c*txh + ri] per column c,
    // with the rectangular prescale and the (bd+8)-bit input clamp.
    curClamp = rowInBits;
    final rowIn = <Logic>[];
    for (var c = 0; c < txw; c++) {
      final sel = selByIdx([
        for (var r = 0; r < txh; r++) internalReg[c * txh + r],
      ], ri).signExtend(w);
      final pre = rectType.abs() == 1
          ? roundShift(mulW(sel, newInvSqrt2), newSqrt2Bits)
          : sel;
      rowIn.add(clamp16(pre));
    }
    // Row core clamps every internal stage to rowBits.
    curClamp = rowBits;
    final rowOut = runtimeTxType
        ? runtimeCore(txw, rowIn, rowType1d!)
        : rowFunc(rowIn);
    final rowStore = [
      for (var c = 0; c < txw; c++)
        (rowShiftBit == 0 ? rowOut[c] : roundShift(rowOut[c], rowShiftBit))
            .getRange(0, bufW),
    ];

    // Current-column inputs to the column core: buf[r*txw + col], col = ci or
    // its mirror under lr_flip, max(bd+6,16)-bit clamp.
    curClamp = colInBits;
    final colIn = <Logic>[];
    for (var r = 0; r < txh; r++) {
      final cols = [
        for (var c = 0; c < txw; c++) bufReg[r * txw + c].signExtend(w),
      ];
      final idx = lrFlip
          ? (Const(txw - 1, width: ciW) - ci).getRange(0, ciW)
          : ci;
      colIn.add(clamp16(selByIdx(cols, idx)));
    }
    // Column core clamps every internal stage to colBits.
    curClamp = colBits;
    final colOut = runtimeTxType
        ? runtimeCore(txh, colIn, colType1d!)
        : colFunc(colIn);
    final colStore = [
      for (var r = 0; r < txh; r++)
        roundShift(
          colOut[udFlip ? (txh - r - 1) : r],
          colShiftBit,
        ).getRange(0, residualW),
    ];

    output('done') <= state.eq(Const(sDone, width: 2));
    output('residual') <=
        [for (var i = txw * txh - 1; i >= 0; i--) resReg[i]].swizzle();

    Sequential(clk, [
      If(
        reset,
        then: [
          state < Const(sIdle, width: 2),
          ri < Const(0, width: riW),
          ci < Const(0, width: ciW),
          for (var i = 0; i < txw * txh; i++) ...[
            internalReg[i] < Const(0, width: residualW),
            bufReg[i] < Const(0, width: bufW),
            resReg[i] < Const(0, width: residualW),
          ],
        ],
        orElse: [
          Case(state, [
            CaseItem(Const(sIdle, width: 2), [
              If(
                input('start'),
                then: [
                  for (var c = 0; c < txw; c++)
                    for (var r = 0; r < txh; r++)
                      internalReg[c * txh + r] <
                          ((c < colLimit && r < rowLimit)
                              ? coeff(r * txw + c)
                              : Const(0, width: residualW)),
                  ri < Const(0, width: riW),
                  state < Const(sRows, width: 2),
                ],
              ),
            ]),
            CaseItem(Const(sRows, width: 2), [
              for (var rr = 0; rr < txh; rr++)
                If(
                  ri.eq(Const(rr, width: riW)),
                  then: [
                    for (var c = 0; c < txw; c++)
                      bufReg[rr * txw + c] < rowStore[c],
                  ],
                ),
              If(
                ri.eq(Const(txh - 1, width: riW)),
                then: [
                  ci < Const(0, width: ciW),
                  state < Const(sCols, width: 2),
                ],
                orElse: [ri < (ri + Const(1, width: riW))],
              ),
            ]),
            CaseItem(Const(sCols, width: 2), [
              for (var cc = 0; cc < txw; cc++)
                If(
                  ci.eq(Const(cc, width: ciW)),
                  then: [
                    for (var r = 0; r < txh; r++)
                      resReg[r * txw + cc] < colStore[r],
                  ],
                ),
              If(
                ci.eq(Const(txw - 1, width: ciW)),
                then: [state < Const(sDone, width: 2)],
                orElse: [ci < (ci + Const(1, width: ciW))],
              ),
            ]),
            CaseItem(Const(sDone, width: 2), [
              If(~input('start'), then: [state < Const(sIdle, width: 2)]),
            ]),
          ]),
        ],
      ),
    ]);
  }
}
