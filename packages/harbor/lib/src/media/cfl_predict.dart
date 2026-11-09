import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 CfL (chroma-from-luma) prediction apply step, bd8.
///
/// Mirrors libaom's CfL apply and alpha derivation. For this module the CfL
/// "AC" recon block is
/// assumed equal to the transform block size, i.e. `tw == cflW == width` and
/// `th == cflH == height`, so the apply loop covers the whole block.
///
/// Algorithm (bd8):
///   numPel = log2(width) + log2(height)
///   sum    = (1 << (numPel-1)) + Sum recon[i] over width*height
///   avg    = sum >> numPel
///   alpha  = cflAlpha(alphaIdx, signs, predType)   // signed, range -16..+16
///   for each (i,j):
///     ac     = recon[j*width+i] - avg               // signed -255..255
///     scaled = roundSigned(alpha * ac, 6)           // round half away from zero
///     pred[j*width+i] = clip(scaled + dcPred[j*width+i], 0, 255)
///
/// `roundSigned(v, n)` is round-half-away-from-zero:
///   v >= 0 ? (v + (1<<(n-1))) >> n : -((-v + (1<<(n-1))) >> n)
/// i.e. take |v|, add the bias 2^(n-1), logical-shift-right by n, reapply sign.
/// This is NOT a plain biased arithmetic shift, so the magnitude is computed
/// explicitly and the sign reapplied.
///
/// `cflAlpha(idx, js, predType)`:
///   signU = (js+1) ~/ 3,  signV = (js+1) - 3*signU       // js (= signs) is 0..7
///   sign  = predType == 0 ? signU : signV
///   if sign == 0 return 0                                 // CFL_SIGN_ZERO
///   absA  = predType == 0 ? (idx >> 4) : (idx & 0xf)
///   return sign == 2 ? absA + 1 : -absA - 1               // POS=2 -> +, NEG=1 -> -
///
/// Ports (all blocks packed row-major, LSB-first: pixel (r,c) at bit
/// `(r*width + c)*8`):
///   in  dc_pred   width*height*8  chroma DC prediction block (8b unsigned)
///   in  recon     width*height*8  luma AC source block (8b unsigned)
///   in  alpha_idx 8b              cfl_alpha index (U in [7:4], V in [3:0])
///   in  signs     3b              cfl_signs symbol (0..7)
///   in  plane     1b              0 => U (predType 0), 1 => V (predType 1)
///   out pred      width*height*8  CfL prediction block (8b unsigned, clipped)
///
/// Combinational.
class HarborCflPredict extends BridgeModule {
  /// Per-pixel bit width of the CfL luma-AC `recon` source. The real 4:2:0 CfL
  /// AC is `(a+b+c+d) << 1` over the collocated 2x2 luma (up to 2040 at bd8,
  /// i.e. 11 bits), so a real chroma path drives `reconBits` >= 11. Defaults to
  /// 8 (the historical width, exercised by cfl_predict_test with 8-bit AC).
  final int reconBits;

  /// Chroma sample bit depth (8/10/12): sets the `dc_pred` / `pred` pixel width
  /// and the final clip range `[0, (1<<bd)-1]`. bd 8 is byte-identical.
  final int bitDepth;

  HarborCflPredict({
    int width = 8,
    int height = 8,
    this.reconBits = 8,
    this.bitDepth = 8,
    String? name,
  }) : assert(bitDepth == 8 || bitDepth == 10 || bitDepth == 12, 'bit depth'),
       super('HarborCflPredict', name: name ?? 'cfl_predict') {
    if (width <= 0 || (width & (width - 1)) != 0) {
      throw ArgumentError(
        'HarborCflPredict.width must be a power of two, '
        'got $width',
      );
    }
    if (height <= 0 || (height & (height - 1)) != 0) {
      throw ArgumentError(
        'HarborCflPredict.height must be a power of two, '
        'got $height',
      );
    }
    if (reconBits < 8) {
      throw ArgumentError(
        'HarborCflPredict.reconBits must be >= 8, '
        'got $reconBits',
      );
    }

    final n = width * height;
    final log2w = _log2(width);
    final log2h = _log2(height);
    final numPel = log2w + log2h;
    final rb = reconBits;
    final pw = bitDepth; // chroma pixel width
    final maxV = (1 << bitDepth) - 1;

    createPort('dc_pred', PortDirection.input, width: n * pw);
    createPort('recon', PortDirection.input, width: n * rb);
    createPort('alpha_idx', PortDirection.input, width: 8);
    createPort('signs', PortDirection.input, width: 3);
    createPort('plane', PortDirection.input, width: 1);
    addOutput('pred', width: n * pw);

    final dcPred = input('dc_pred');
    final recon = input('recon');
    final alphaIdx = input('alpha_idx');
    final signs = input('signs');
    final plane = input('plane');

    Logic dc(int k) => dcPred.getRange(k * pw, k * pw + pw);
    Logic rec(int k) => recon.getRange(k * rb, k * rb + rb);

    final recMax = (1 << rb) - 1;
    // avg via reduction tree
    // sum = (1 << (numPel-1)) + Sum recon over n pixels.
    // max sum = 2^(numPel-1) + n*recMax. Pick a width that holds it comfortably.
    final sumW = (n * recMax + (1 << (numPel - 1))).bitLength + 2;
    Logic sumAdd(List<Logic> xs) => xs
        .map((x) => x.zeroExtend(sumW))
        .reduce((a, b) => (a + b).getRange(0, sumW));
    final terms = <Logic>[
      Const(1 << (numPel - 1), width: sumW),
      for (var k = 0; k < n; k++) rec(k),
    ];
    final sum = sumAdd(terms);
    // avg = sum >> numPel (sum is non-negative).
    final avg = sum.getRange(numPel, sumW); // sumW-numPel bits, value 0..255

    // alpha (signed)
    // js = signs (0..7). js+1 in 1..8.
    // signU = (js+1)~/3 in {0,1,2}. signV = (js+1) - 3*signU in {0,1,2}.
    const w = 24; // signed working width for alpha*ac + rounding
    final jp1 = signs.zeroExtend(8) + Const(1, width: 8); // 1..8, 8b ok
    // ~/3 for a value 1..8: result 0..2. Use a constant-divisor compare ladder.
    // signU = (jp1 >= 6) ? 2 : (jp1 >= 3) ? 1 : 0
    final ge3 = jp1.gte(Const(3, width: 8));
    final ge6 = jp1.gte(Const(6, width: 8));
    final signU = mux(
      ge6,
      Const(2, width: 2),
      mux<Logic>(ge3, Const(1, width: 2), Const(0, width: 2)),
    );
    // signV = jp1 - 3*signU. signU in 0..2 so 3*signU in {0,3,6}.
    final threeSignU =
        (signU.zeroExtend(8) + signU.zeroExtend(8) + signU.zeroExtend(8))
            .getRange(0, 8);
    final signV = (jp1 - threeSignU).getRange(0, 2); // 0..2

    final predType = plane; // 1b: 0 => U/predType0, 1 => V/predType1
    final sign = mux(predType, signV, signU); // 2b, in {0,1,2}

    // absA = predType==0 ? (idx>>4) : (idx&0xf)
    final absU = alphaIdx.getRange(4, 8).zeroExtend(w); // idx>>4, 0..15
    final absV = alphaIdx.getRange(0, 4).zeroExtend(w); // idx&0xf, 0..15
    final absA = mux(predType, absV, absU); // 0..15

    // magnitude = absA + 1, then signed: POS(sign==2) -> +mag, NEG(sign==1) -> -mag
    final mag = (absA + Const(1, width: w)).getRange(0, w); // 1..16
    final isZero = sign.eq(Const(0, width: 2));
    final isPos = sign.eq(Const(2, width: 2));
    // alpha (signed, w-wide two's complement):
    //   zero -> 0
    //   pos  -> +mag
    //   neg  -> -mag
    final negMag = (~mag + Const(1, width: w)).getRange(
      0,
      w,
    ); // -mag (two's comp)
    final alpha = mux(
      isZero,
      Const(0, width: w),
      mux(isPos, mag, negMag),
    ); // signed value in [-16,16]

    // per-pixel scaled add + clip
    final outParts = <Logic>[];
    for (var k = 0; k < n; k++) {
      // ac = recon[k] - avg, signed. recon 0..255, avg 0..255 -> ac in -255..255.
      final reconW = rec(k).zeroExtend(w);
      final avgW = avg.zeroExtend(w);
      final ac = (reconW - avgW).getRange(0, w); // two's complement signed

      // signed multiply: alpha (signed w) * ac (signed w), keep low w bits.
      final prod = (alpha * ac).getRange(0, w); // signed, |.| <= 16*255=4080

      // roundSigned(prod, 6) = round half away from zero by 6 bits.
      // mag = |prod|, (mag + 32) >> 6 logical, reapply sign of prod.
      final prodNeg = prod[w - 1];
      final prodMag = mux(
        prodNeg,
        (~prod + Const(1, width: w)).getRange(0, w),
        prod,
      );
      final biased = (prodMag + Const(1 << 5, width: w)).getRange(0, w);
      final shifted = biased.getRange(6, w).zeroExtend(w); // logical >> 6
      final scaledNeg = (~shifted + Const(1, width: w)).getRange(0, w);
      final scaled = mux(prodNeg, scaledNeg, shifted); // signed result

      // res = scaled + dcPred[k], clip to [0, (1<<bd)-1].
      final res = (scaled + dc(k).zeroExtend(w)).getRange(0, w); // signed
      final resNeg = res[w - 1];
      final gtMax = ~resNeg & res.gt(Const(maxV, width: w));
      final clipped = mux(
        resNeg,
        Const(0, width: pw),
        mux(gtMax, Const(maxV, width: pw), res.getRange(0, pw)),
      );
      outParts.add(clipped);
    }

    output('pred') <= outParts.reversed.toList().concat();
  }

  static int _log2(int v) {
    var n = 0;
    while ((1 << n) < v) {
      n++;
    }
    return n;
  }
}
