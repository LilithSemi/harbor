import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'warp_filter_tables.dart';

/// Harbor bit-exact AV1 local warped-motion model estimation: the integer
/// least-squares affine fit (`av1_find_projection` / `find_affine_int`) followed
/// by `av1_get_shear_params`. Combinational.
///
/// Given up to [leastSquaresSamplesMax] neighbour warp samples (the SELECTED
/// samples from `av1_findSamples` + `av1_selectSamples`, in 1/8-pel-*8 units,
/// i.e. the `pts1`/`pts2` arrays fed to `av1_find_projection`), the block width
/// and height (pixels), the block MV (`mvy`/`mvx`, 1/8-pel), and the block's mi
/// row/col, this produces the 6-entry warp matrix `wmmat`, the shear params
/// `alpha`/`beta`/`gamma`/`delta`, and a `valid` flag. `valid` is 0 exactly when
/// libaom would return null (degenerate `Det==0`, invalid affine `mat[2]<=0`, or
/// a shear the fast warp filter cannot represent). The caller then falls back
/// to translational prediction.
///
/// All internal arithmetic is 64-bit two's-complement with wraparound and
/// arithmetic right shifts, matching the Dart-native / libaom `int64_t` reference
/// bit-for-bit. This is a faithful port of av1/common/warped_motion.c.
class HarborWarpEstimate extends BridgeModule {
  static const int leastSquaresSamplesMax = 8;

  // Precision / clamp constants (av1 warped_motion.c).
  static const int _w = 64; // working width
  static const int _warpedModelPrecBits = 16;
  static const int _warpParamReduceBits = 6;
  static const int _divLutBits = 8;
  static const int _divLutPrecBits = 14;
  static const int _lsStep = 8;
  static const int _lsMvMax = 256; // LEAST_SQUARES_MV_MAX
  static const int _nondiagClamp = 1 << (_warpedModelPrecBits - 3); // 8192
  static const int _transClamp = 128 << _warpedModelPrecBits; // 8388608
  static const int _int16Min = -32768;
  static const int _int16Max = 32767;

  /// Sample-coordinate input width (signed, 1/8-pel-*8 plane coords).
  static const int _coordW = 24;

  HarborWarpEstimate({String? name})
    : super('HarborWarpEstimate', name: name ?? 'warp_estimate') {
    createPort('np', PortDirection.input, width: 4);
    // pts1 (src) and pts2 (in-ref): 8 samples, interleaved (px,py) per sample.
    createPort(
      'pts1',
      PortDirection.input,
      width: leastSquaresSamplesMax * 2 * _coordW,
    );
    createPort(
      'pts2',
      PortDirection.input,
      width: leastSquaresSamplesMax * 2 * _coordW,
    );
    createPort('bw', PortDirection.input, width: 8); // block width px
    createPort('bh', PortDirection.input, width: 8);
    createPort('mvx', PortDirection.input, width: 16); // signed mvC0 (1/8-pel)
    createPort('mvy', PortDirection.input, width: 16); // signed mvR0
    createPort('mi_row', PortDirection.input, width: 16);
    createPort('mi_col', PortDirection.input, width: 16);

    addOutput('valid');
    // 6 warp-matrix entries, each signed 32b (mat0/1 up to +/-2^23, mat2..5
    // around 2^16 +/- 2^13).
    for (var i = 0; i < 6; i++) {
      addOutput('mat$i', width: 32);
    }
    addOutput('alpha', width: 16);
    addOutput('beta', width: 16);
    addOutput('gamma', width: 16);
    addOutput('delta', width: 16);

    // 64-bit signed helpers.
    Logic sc(int v) => Const(BigInt.from(v).toUnsigned(_w), width: _w);
    Logic sext(Logic x) => x.signExtend(_w);
    Logic add(Logic a, Logic b) => (a + b).getRange(0, _w);
    Logic sub(Logic a, Logic b) => (a - b).getRange(0, _w);
    Logic mul(Logic a, Logic b) => (a * b).getRange(0, _w);
    Logic neg(Logic a) => sub(sc(0), a);
    Logic sgn(Logic a) => a[_w - 1];
    // arithmetic shift right by constant n.
    Logic asrC(Logic x, int n) =>
        n <= 0 ? x : [x[_w - 1].replicate(n), x.getRange(n, _w)].concat();
    // logical shift left by constant n.
    Logic lslC(Logic x, int n) =>
        n <= 0 ? x : [x.getRange(0, _w - n), Const(0, width: n)].concat();
    // signed less-than.
    Logic slt(Logic a, Logic b) =>
        mux(sgn(a) ^ sgn(b), sgn(a), sub(a, b)[_w - 1]);
    Logic absS(Logic a) => mux(sgn(a), neg(a), a);
    Logic clampS(Logic x, Logic lo, Logic hi) =>
        mux(slt(x, lo), lo, mux(slt(hi, x), hi, x));

    // ROUND_POWER_OF_TWO with a CONSTANT shift n (arithmetic, signed value).
    Logic rpoC(Logic v, int n) =>
        n <= 0 ? v : asrC(add(v, sc(1 << (n - 1))), n);
    Logic rpoSignedC(Logic v, int n) =>
        mux(sgn(v), neg(rpoC(neg(v), n)), rpoC(v, n));

    // ROUND_POWER_OF_TWO with a VARIABLE shift n (0..63), value non-negative.
    Logic rpoVar(Logic v, Logic n) {
      Logic res = v; // n == 0
      for (var k = 1; k < _w; k++) {
        res = mux(
          n.eq(Const(k, width: n.width)),
          asrC(add(v, sc(1 << (k - 1))), k),
          res,
        );
      }
      return res;
    }

    Logic rpoSignedVar(Logic v, Logic n) =>
        mux(sgn(v), neg(rpoVar(neg(v), n)), rpoVar(v, n));

    // position of the MSB of a positive value (0..63), 0 when x==0.
    Logic getMsb(Logic x) {
      Logic r = Const(0, width: 7);
      for (var i = 0; i < _w; i++) {
        r = mux(x[i], Const(i, width: 7), r);
      }
      return r;
    }

    // variable left shift by a small amount (0..63).
    Logic lslVar(Logic x, Logic n) {
      Logic res = x;
      for (var k = 1; k < _w; k++) {
        res = mux(n.eq(Const(k, width: n.width)), lslC(x, k), res);
      }
      return res;
    }

    // 1 << shift, shift 0..63 (as a 64-bit value).
    Logic oneShl(Logic shift) {
      Logic res = sc(1);
      for (var k = 1; k < _w; k++) {
        res = mux(
          shift.eq(Const(k, width: shift.width)),
          Const(BigInt.one << k, width: _w),
          res,
        );
      }
      return res;
    }

    // kDivLut[f], f in 0..256.
    Logic divLut(Logic f) {
      Logic r = sc(kDivLut[256]);
      for (var i = 255; i >= 0; i--) {
        r = mux(f.eq(Const(i, width: 9)), sc(kDivLut[i]), r);
      }
      return r;
    }

    // resolve_divisor (works for 32/64-bit d): returns (1/D as div-lut value,
    // shift). d is a positive magnitude (64b). Matches resolve_divisor_64.
    (Logic, Logic) resolveDivisor(Logic d) {
      final shift = getMsb(d); // 7b, uniform for 32/64-bit path
      final e = sub(d, oneShl(shift.zeroExtend(_w)));
      // f = shift>8 ? rpo(e, shift-8) : e << (8-shift). Result 0..256.
      Logic f = e.getRange(0, 9);
      for (var s = 0; s <= 40; s++) {
        Logic cand;
        if (s > _divLutBits) {
          // round_power_of_two(e, s-8), e >= 0 -> logical shift.
          final m = s - _divLutBits;
          cand = asrC(add(e, sc(1 << (m - 1))), m).getRange(0, 9);
        } else {
          cand = lslC(e, _divLutBits - s).getRange(0, 9);
        }
        f = mux(shift.eq(Const(s, width: 7)), cand, f);
      }
      final shiftOut = (shift.zeroExtend(8) + Const(_divLutPrecBits, width: 8))
          .getRange(0, 8);
      return (divLut(f), shiftOut);
    }

    // inputs.
    final np = input('np');
    final bw = input('bw');
    final bh = input('bh');
    final mvx = sext(input('mvx'));
    final mvy = sext(input('mvy'));
    final miRow = input('mi_row').zeroExtend(_w);
    final miCol = input('mi_col').zeroExtend(_w);

    Logic pts1At(int idx) =>
        sext(input('pts1').getRange(idx * _coordW, idx * _coordW + _coordW));
    Logic pts2At(int idx) =>
        sext(input('pts2').getRange(idx * _coordW, idx * _coordW + _coordW));

    // rsuy = bh/2 - 1. rsux = bw/2 - 1 (block dims are >= 8, even).
    final rsuy = sub((bh.zeroExtend(_w) >> 1).getRange(0, _w), sc(1));
    final rsux = sub((bw.zeroExtend(_w) >> 1).getRange(0, _w), sc(1));
    final suy = mul(rsuy, sc(8));
    final sux = mul(rsux, sc(8));
    final duy = add(suy, mvy);
    final dux = add(sux, mvx);

    // LS macros.
    Logic lsSquare(Logic a) => asrC(
      add(
        add(mul(mul(a, a), sc(4)), mul(a, sc(4 * _lsStep))),
        sc(_lsStep * _lsStep * 2),
      ),
      4,
    );
    Logic lsProduct1(Logic a, Logic b) => asrC(
      add(
        add(mul(mul(a, b), sc(4)), mul(add(a, b), sc(2 * _lsStep))),
        sc(_lsStep * _lsStep),
      ),
      4,
    );
    Logic lsProduct2(Logic a, Logic b) => asrC(
      add(
        add(mul(mul(a, b), sc(4)), mul(add(a, b), sc(2 * _lsStep))),
        sc(_lsStep * _lsStep * 2),
      ),
      4,
    );

    // least-squares accumulation.
    Logic a00 = sc(0), a01 = sc(0), a11 = sc(0);
    Logic bx0 = sc(0), bx1 = sc(0), by0 = sc(0), by1 = sc(0);
    for (var i = 0; i < leastSquaresSamplesMax; i++) {
      final dx = sub(pts2At(2 * i), dux);
      final dy = sub(pts2At(2 * i + 1), duy);
      final sx = sub(pts1At(2 * i), sux);
      final sy = sub(pts1At(2 * i + 1), suy);
      final within =
          slt(absS(sub(sx, dx)), sc(_lsMvMax)) &
          slt(absS(sub(sy, dy)), sc(_lsMvMax));
      final active = Const(i, width: 4).lt(np) & within;
      Logic g(Logic term) => mux(active, term, sc(0));
      a00 = add(a00, g(lsSquare(sx)));
      a01 = add(a01, g(lsProduct1(sx, sy)));
      a11 = add(a11, g(lsSquare(sy)));
      bx0 = add(bx0, g(lsProduct2(sx, dx)));
      bx1 = add(bx1, g(lsProduct1(sy, dx)));
      by0 = add(by0, g(lsProduct1(sx, dy)));
      by1 = add(by1, g(lsProduct2(sy, dy)));
    }

    final det = sub(mul(a00, a11), mul(a01, a01));
    final detZero = det.eq(sc(0));
    final (iDetLut, rdShift) = resolveDivisor(absS(det));
    final iDet0 = mux(sgn(det), neg(iDetLut), iDetLut);
    // shift = rdShift - 16. If <0: iDet <<= -shift, shift = 0.
    final shift0 = sub(rdShift.zeroExtend(_w), sc(_warpedModelPrecBits));
    final shiftNeg = sgn(shift0);
    final iDet = mux(shiftNeg, lslVar(iDet0, neg(shift0)), iDet0);
    final shift = mux(shiftNeg, sc(0), shift0);

    final px0 = sub(mul(a11, bx0), mul(a01, bx1));
    final px1 = sub(mul(a00, bx1), mul(a01, bx0));
    final py0 = sub(mul(a11, by0), mul(a01, by1));
    final py1 = sub(mul(a00, by1), mul(a01, by0));

    Logic multShiftDiag(Logic px) => clampS(
      rpoSignedVar(mul(px, iDet), shift),
      sc((1 << _warpedModelPrecBits) - _nondiagClamp + 1),
      sc((1 << _warpedModelPrecBits) + _nondiagClamp - 1),
    );
    Logic multShiftNdiag(Logic px) => clampS(
      rpoSignedVar(mul(px, iDet), shift),
      sc(-_nondiagClamp + 1),
      sc(_nondiagClamp - 1),
    );

    final mat2 = multShiftDiag(px0);
    final mat3 = multShiftNdiag(px1);
    final mat4 = multShiftNdiag(py0);
    final mat5 = multShiftDiag(py1);

    final isuy = add(mul(miRow, sc(4)), rsuy);
    final isux = add(mul(miCol, sc(4)), rsux);
    final vx = sub(
      mul(mvx, sc(1 << (_warpedModelPrecBits - 3))),
      add(mul(isux, sub(mat2, sc(1 << _warpedModelPrecBits))), mul(isuy, mat3)),
    );
    final vy = sub(
      mul(mvy, sc(1 << (_warpedModelPrecBits - 3))),
      add(mul(isux, mat4), mul(isuy, sub(mat5, sc(1 << _warpedModelPrecBits)))),
    );
    final mat0 = clampS(vx, sc(-_transClamp), sc(_transClamp - 1));
    final mat1 = clampS(vy, sc(-_transClamp), sc(_transClamp - 1));

    // get_shear_params.
    final affineValid = ~slt(mat2, sc(1)); // mat2 > 0
    // reduce helper: rpoSigned(x,6) * (1<<6).
    Logic reduce(Logic x) =>
        mul(rpoSignedC(x, _warpParamReduceBits), sc(1 << _warpParamReduceBits));

    final alpha0 = clampS(
      sub(mat2, sc(1 << _warpedModelPrecBits)),
      sc(_int16Min),
      sc(_int16Max),
    );
    final beta0 = clampS(mat3, sc(_int16Min), sc(_int16Max));
    final (yv, sh2) = resolveDivisor(absS(mat2));
    final y = mux(sgn(mat2), neg(yv), yv);
    final gv = mul(mul(mat4, sc(1 << _warpedModelPrecBits)), y);
    final gamma0 = clampS(rpoSignedVar(gv, sh2), sc(_int16Min), sc(_int16Max));
    final dv = mul(mul(mat3, mat4), y);
    final delta0 = clampS(
      sub(sub(mat5, rpoSignedVar(dv, sh2)), sc(1 << _warpedModelPrecBits)),
      sc(_int16Min),
      sc(_int16Max),
    );

    final alphaR = reduce(alpha0);
    final betaR = reduce(beta0);
    final gammaR = reduce(gamma0);
    final deltaR = reduce(delta0);

    // is_affine_shear_allowed.
    final shearBad =
        ~slt(
          add(mul(sc(4), absS(alphaR)), mul(sc(7), absS(betaR))),
          sc(1 << _warpedModelPrecBits),
        ) |
        ~slt(
          add(mul(sc(4), absS(gammaR)), mul(sc(4), absS(deltaR))),
          sc(1 << _warpedModelPrecBits),
        );

    final valid = ~detZero & affineValid & ~shearBad;

    output('valid') <= valid;
    output('mat0') <= mat0.getRange(0, 32);
    output('mat1') <= mat1.getRange(0, 32);
    output('mat2') <= mat2.getRange(0, 32);
    output('mat3') <= mat3.getRange(0, 32);
    output('mat4') <= mat4.getRange(0, 32);
    output('mat5') <= mat5.getRange(0, 32);
    output('alpha') <= alphaR.getRange(0, 16);
    output('beta') <= betaR.getRange(0, 16);
    output('gamma') <= gammaR.getRange(0, 16);
    output('delta') <= deltaR.getRange(0, 16);
  }
}
