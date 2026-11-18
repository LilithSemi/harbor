import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact 4x4 inverse transform (libaom `av1_inv_txfm2d_add_4x4_c`).
///
/// Unlike the orthonormal matrix-multiply approximation in [HarborInverseDct4],
/// this is a faithful port of libaom's integer butterfly transforms: the cosBit
/// 12 `idct4` / `iadst4` / `iidentity4` 1D cores, the column-major internal
/// input remap, per-stage range clamps, the rectangular-prescale skip (square),
/// the row/column round-shifts (`av1_inv_txfm_shift_ls[TX_4X4] = [0, -4]`), and
/// the up/down + left/right flips for the FLIPADST variants. The residual it
/// produces is byte-identical to the software decoder's `inverseTransform` for
/// every one of the 16 TX_TYPEs at TX_4X4, bd = 8.
///
/// [txType] is the libaom TX_TYPE enum (0 DCT_DCT .. 15 H_FLIPADST). It is
/// resolved at build time, so each instance emits only the datapath its type
/// needs. `coeffs` packs the dequantized levels row-major: element (r, c) at
/// `[(r*4 + c)*16 +: 16]`, signed two's complement. `residual` is the spatial
/// residual in the same layout (what libaom adds to the predictor before the
/// pixel clamp). Combinational.
class HarborInvTxfm4x4 extends BridgeModule {
  /// libaom TX_TYPE this instance implements.
  final int txType;

  HarborInvTxfm4x4({required this.txType, String? name})
    : assert(txType >= 0 && txType < 16, 'TX_TYPE 0..15'),
      super('HarborInvTxfm4x4', name: name ?? 'inv_txfm_4x4_$txType') {
    createPort('coeffs', PortDirection.input, width: 16 * 16);
    addOutput('residual', width: 16 * 16);

    // exact-arithmetic primitives (W-bit two's complement)
    const w = 64;
    // av1_cospi_arr_data[cos_bit-10][.], cos_bit = 12 -> index 2.
    const cospi = <int>[
      4096, 4095, 4091, 4085, 4076, 4065, 4052, 4036, 4017, 3996, 3973, //
      3948, 3920, 3889, 3857, 3822, 3784, 3745, 3703, 3659, 3612, 3564, //
      3513, 3461, 3406, 3349, 3290, 3229, 3166, 3102, 3035, 2967, 2896, //
      2824, 2751, 2675, 2598, 2520, 2440, 2359, 2276, 2191, 2106, 2019, //
      1931, 1842, 1751, 1660, 1567, 1474, 1380, 1285, 1189, 1092, 995, //
      897, 799, 700, 601, 501, 401, 301, 201, 101,
    ];
    // av1_sinpi_arr_data[2] = [0, 1321, 2482, 3344, 3803].
    const sinpi = <int>[0, 1321, 2482, 3344, 3803];
    const newSqrt2 = 5793; // 2^12 * sqrt(2)
    const newSqrt2Bits = 12;
    const cosBit = 12;

    Logic kc(int v) => Const(BigInt.from(v).toUnsigned(w), width: w);
    Logic ashr(Logic x, int s) =>
        s == 0 ? x : [x[w - 1].replicate(s), x.getRange(s, w)].concat();
    // Reinterpret the low 32 bits as a signed value (libaom `(int32_t)` cast).
    Logic s32(Logic v) => [v[31].replicate(w - 32), v.getRange(0, 32)].concat();
    Logic addW(Logic a, Logic b) => (a + b).getRange(0, w);
    Logic subW(Logic a, Logic b) => (a - b).getRange(0, w);
    // Full signed product, low w bits (operands fit so no wrap).
    Logic mulW(Logic a, int k) => (a * kc(k)).getRange(0, w);

    // half_btf(w0, in0, w1, in1, bit): each product truncated to int32, summed
    // in 64-bit, rounded, arithmetic-shifted, truncated to int32.
    Logic halfBtf(int w0, Logic in0, int w1, Logic in1) {
      final p0 = s32((in0 * kc(w0)).getRange(0, 32));
      final p1 = s32((in1 * kc(w1)).getRange(0, 32));
      final res = addW(p0, p1);
      final inter = addW(res, kc(1 << (cosBit - 1)));
      return s32(ashr(inter, cosBit));
    }

    // round_shift(value, bit) for bit >= 1: (value + (1<<(bit-1))) >> bit, int32.
    Logic roundShift(Logic value, int bit) {
      final t = addW(value, kc(1 << (bit - 1)));
      return s32(ashr(t, bit));
    }

    // clamp_value(value, bit): clamp to signed `bit`-bit range.
    Logic clampValue(Logic v, int bit) {
      final maxV = (1 << (bit - 1)) - 1;
      final minV = -(1 << (bit - 1));
      final gtMax = subW(kc(maxV), v)[w - 1]; // maxV - v < 0  => v > maxV
      final ltMin = subW(v, kc(minV))[w - 1]; // v - minV < 0  => v < minV
      return mux(ltMin, kc(minV), mux(gtMax, kc(maxV), v));
    }

    // 1D cores
    List<Logic> idct4(List<Logic> inp) {
      // stage 1
      final s1 = [inp[0], inp[2], inp[1], inp[3]];
      // stage 2
      final s2 = [
        halfBtf(cospi[32], s1[0], cospi[32], s1[1]),
        halfBtf(cospi[32], s1[0], -cospi[32], s1[1]),
        halfBtf(cospi[48], s1[2], -cospi[16], s1[3]),
        halfBtf(cospi[16], s1[2], cospi[48], s1[3]),
      ];
      // stage 3 (clamp to sr[3] = 16 for bd = 8)
      return [
        clampValue(addW(s2[0], s2[3]), 16),
        clampValue(addW(s2[1], s2[2]), 16),
        clampValue(subW(s2[1], s2[2]), 16),
        clampValue(subW(s2[0], s2[3]), 16),
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
      final s3 = s2c; // new s3 = old s2
      final s2 = mulW(s7, sinpi[3]); // new s2
      s0 = addW(s0, s5);
      s1 = subW(s1, s6);
      var rx0 = addW(s0, s3);
      var rx1 = addW(s1, s3);
      final rx2 = s2;
      var rx3 = addW(s0, s1);
      rx3 = subW(rx3, s3);
      return [
        roundShift(rx0, cosBit),
        roundShift(rx1, cosBit),
        roundShift(rx2, cosBit),
        roundShift(rx3, cosBit),
      ];
    }

    List<Logic> iidentity4(List<Logic> inp) => [
      for (var i = 0; i < 4; i++)
        roundShift(mulW(inp[i], newSqrt2), newSqrt2Bits),
    ];

    // type/flip resolution (build time)
    // vtx_tab / htx_tab : TX_TYPE -> TX_TYPE_1D (DCT=0 ADST=1 FLIPADST=2 IDTX=3)
    const vtxTab = <int>[0, 1, 0, 1, 2, 0, 2, 1, 2, 3, 0, 3, 1, 3, 2, 3];
    const htxTab = <int>[0, 0, 1, 1, 0, 2, 2, 2, 1, 3, 3, 0, 3, 1, 3, 2];
    List<Logic> Function(List<Logic>) funcFor(int type1d) {
      switch (type1d) {
        case 0: // DCT
          return idct4;
        case 1: // ADST
        case 2: // FLIPADST (flip handled at buffer level)
          return iadst4;
        default: // IDTX
          return iidentity4;
      }
    }

    final colFunc = funcFor(vtxTab[txType]); // vertical (column) transform
    final rowFunc = funcFor(htxTab[txType]); // horizontal (row) transform
    // ud_flip when the column type is FLIPADST, lr_flip when row is FLIPADST.
    final udFlip = vtxTab[txType] == 2;
    final lrFlip = htxTab[txType] == 2;
    // av1_inv_txfm_shift_ls[TX_4X4] = [0, -4]. Round-shift amount = -shift.
    const rowShiftBit = 0; // -shift[0]
    const colShiftBit = 4; // -shift[1]

    // 2D pipeline
    Logic coeff(int r, int c) =>
        input('coeffs').getRange((r * 4 + c) * 16, (r * 4 + c) * 16 + 16);

    // Internal input is column-major: input[c*4 + r] = coeff(r, c) (sign-ext).
    List<Logic> internal = [
      for (var c = 0; c < 4; c++)
        for (var r = 0; r < 4; r++) coeff(r, c).signExtend(w),
    ];

    // Rows: r-th row uses input[c*4 + r] for c in 0..3.
    final buf = List<Logic>.filled(16, Const(0, width: w));
    for (var r = 0; r < 4; r++) {
      final tempIn = [
        for (var c = 0; c < 4; c++) clampValue(internal[c * 4 + r], 16),
      ];
      final rowOut = rowFunc(tempIn);
      for (var c = 0; c < 4; c++) {
        // round_shift_array(rowOut, 4, rowShiftBit), bit 0 -> no-op.
        buf[r * 4 + c] = rowShiftBit == 0
            ? rowOut[c]
            : roundShift(rowOut[c], rowShiftBit);
      }
    }

    // Columns: optionally left/right flipped read, transform, round-shift,
    // optionally up/down flipped write.
    final res = List<Logic>.filled(16, Const(0, width: 16));
    for (var c = 0; c < 4; c++) {
      final tempIn = [
        for (var r = 0; r < 4; r++)
          clampValue(buf[r * 4 + (lrFlip ? (4 - c - 1) : c)], 16),
      ];
      final colOut = colFunc(tempIn);
      for (var r = 0; r < 4; r++) {
        final shifted = roundShift(
          colOut[udFlip ? (4 - r - 1) : r],
          colShiftBit,
        );
        res[r * 4 + c] = shifted.getRange(0, 16);
      }
    }

    output('residual') <= res.reversed.toList().concat();
  }
}
