import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'warp_filter_tables.dart';

/// AV1 global-motion warp-model shear setup (libaom `av1_get_shear_params`
/// applied to a frame-level global-motion matrix). Combinational.
///
/// Given the 6-entry global-motion matrix `mat0..mat5` (WARPEDMODEL_PREC_BITS=16)
/// this passes the matrix through and produces the shear params
/// `alpha`/`beta`/`gamma`/`delta` plus a `valid` flag. `valid` is 0 exactly for
/// an invalid affine (`mat2<=0`) or a shear the fast warp filter cannot
/// represent. The caller then falls back to translational prediction. When
/// `valid`, the outputs feed [HarborWarpAffine] with the global model in place
/// of the local least-squares estimate, so global warped motion reuses the
/// already-proven warp kernel.
///
/// This is the shear half of [HarborWarpEstimate], detached from the
/// least-squares fit (the global model supplies `mat` directly). All arithmetic
/// is 64-bit two's-complement, matching libaom `int64_t` bit-for-bit.
class HarborGlobalWarpModel extends BridgeModule {
  static const int _w = 64;
  static const int _warpedModelPrecBits = 16;
  static const int _warpParamReduceBits = 6;
  static const int _divLutBits = 8;
  static const int _divLutPrecBits = 14;
  static const int _int16Min = -32768;
  static const int _int16Max = 32767;

  HarborGlobalWarpModel({String? name})
    : super('HarborGlobalWarpModel', name: name ?? 'global_warp_model') {
    for (var i = 0; i < 6; i++) {
      createPort('mat$i', PortDirection.input, width: 32);
    }
    addOutput('valid');
    addOutput('alpha', width: 16);
    addOutput('beta', width: 16);
    addOutput('gamma', width: 16);
    addOutput('delta', width: 16);

    // 64-bit signed helpers (mirror warp_estimate)
    Logic sc(int v) => Const(BigInt.from(v).toUnsigned(_w), width: _w);
    Logic sext(Logic x) => x.signExtend(_w);
    Logic add(Logic a, Logic b) => (a + b).getRange(0, _w);
    Logic sub(Logic a, Logic b) => (a - b).getRange(0, _w);
    Logic mul(Logic a, Logic b) => (a * b).getRange(0, _w);
    Logic neg(Logic a) => sub(sc(0), a);
    Logic sgn(Logic a) => a[_w - 1];
    Logic asrC(Logic x, int n) =>
        n <= 0 ? x : [x[_w - 1].replicate(n), x.getRange(n, _w)].concat();
    Logic lslC(Logic x, int n) =>
        n <= 0 ? x : [x.getRange(0, _w - n), Const(0, width: n)].concat();
    Logic slt(Logic a, Logic b) =>
        mux(sgn(a) ^ sgn(b), sgn(a), sub(a, b)[_w - 1]);
    Logic absS(Logic a) => mux(sgn(a), neg(a), a);
    Logic clampS(Logic x, Logic lo, Logic hi) =>
        mux(slt(x, lo), lo, mux(slt(hi, x), hi, x));

    Logic rpoC(Logic v, int n) =>
        n <= 0 ? v : asrC(add(v, sc(1 << (n - 1))), n);
    Logic rpoSignedC(Logic v, int n) =>
        mux(sgn(v), neg(rpoC(neg(v), n)), rpoC(v, n));

    Logic rpoVar(Logic v, Logic n) {
      Logic res = v;
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

    Logic getMsb(Logic x) {
      Logic r = Const(0, width: 7);
      for (var i = 0; i < _w; i++) {
        r = mux(x[i], Const(i, width: 7), r);
      }
      return r;
    }

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

    Logic divLut(Logic f) {
      Logic r = sc(kDivLut[256]);
      for (var i = 255; i >= 0; i--) {
        r = mux(f.eq(Const(i, width: 9)), sc(kDivLut[i]), r);
      }
      return r;
    }

    (Logic, Logic) resolveDivisor(Logic d) {
      final shift = getMsb(d);
      final e = sub(d, oneShl(shift.zeroExtend(_w)));
      Logic f = e.getRange(0, 9);
      for (var s = 0; s <= 40; s++) {
        Logic cand;
        if (s > _divLutBits) {
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

    // get_shear_params
    Logic matAt(int i) => sext(input('mat$i'));
    final mat2 = matAt(2), mat3 = matAt(3), mat4 = matAt(4), mat5 = matAt(5);

    final affineValid = ~slt(mat2, sc(1)); // mat2 > 0

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

    final shearBad =
        ~slt(
          add(mul(sc(4), absS(alphaR)), mul(sc(7), absS(betaR))),
          sc(1 << _warpedModelPrecBits),
        ) |
        ~slt(
          add(mul(sc(4), absS(gammaR)), mul(sc(4), absS(deltaR))),
          sc(1 << _warpedModelPrecBits),
        );

    output('valid') <= (affineValid & ~shearBad);
    output('alpha') <= alphaR.getRange(0, 16);
    output('beta') <= betaR.getRange(0, 16);
    output('gamma') <= gammaR.getRange(0, 16);
    output('delta') <= deltaR.getRange(0, 16);
  }
}
