import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// AV1 `gm_get_motion_vector` (spec 7.10.2.10 / libaom `gm_get_motion_vector`).
/// Combinational. Derives the GLOBALMV / GLOBAL_GLOBALMV predicted motion vector
/// for a block from a frame-level global-motion model.
///
/// Inputs are the per-reference decoded model: `gm_type`
/// (0=IDENTITY,1=TRANSLATION,2=ROTZOOM,3=AFFINE) and the 6-entry warp matrix
/// `mat0..mat5` (WARPEDMODEL_PREC_BITS=16), the block-size pixel dimensions
/// `block_wide`/`block_high`, the block mi row/col `mi_r`/`mi_c`, and the
/// header flags `allow_hp` (allowHighPrecisionMv) and `force_integer`
/// (forceIntegerMv != 0). Outputs the 1/8-pel MV `mv_row`/`mv_col`.
///
/// - IDENTITY -> (0,0).
/// - TRANSLATION -> (mat0>>13, mat1>>13) (GM_TRANS_ONLY_PREC_DIFF=13), then
///   integer-mv rounding when `force_integer`.
/// - ROTZOOM / AFFINE -> evaluate the affine warp at the block centre
///   x = mi_c*4 + (block_wide>>1) - 1, y = mi_r*4 + (block_high>>1) - 1,
///   xc = (mat2-2^16)*x + mat3*y + mat0, yc = mat4*x + (mat5-2^16)*y + mat1,
///   mv = (convertToTransPrec(yc), convertToTransPrec(xc)), then integer-mv
///   rounding when `force_integer`. `convertToTransPrec(coor)` is
///   `roundSigned(coor,13)` when `allow_hp`, else `roundSigned(coor,14)*2`.
///
/// All arithmetic is 64-bit two's-complement (arithmetic right shifts), matching
/// the Dart-native / libaom int64 reference exactly.
class HarborGlobalMv extends BridgeModule {
  static const int _w = 64; // working width
  static const int _warpedModelPrecBits = 16;

  HarborGlobalMv({String? name})
    : super('HarborGlobalMv', name: name ?? 'global_mv') {
    createPort('gm_type', PortDirection.input, width: 2);
    for (var i = 0; i < 6; i++) {
      createPort('mat$i', PortDirection.input, width: 32);
    }
    createPort('block_wide', PortDirection.input, width: 8);
    createPort('block_high', PortDirection.input, width: 8);
    createPort('mi_r', PortDirection.input, width: 16);
    createPort('mi_c', PortDirection.input, width: 16);
    createPort('allow_hp', PortDirection.input);
    createPort('force_integer', PortDirection.input);

    addOutput('mv_row', width: 32);
    addOutput('mv_col', width: 32);

    // 64-bit signed helpers
    Logic sc(int v) => Const(BigInt.from(v).toUnsigned(_w), width: _w);
    Logic sext(Logic x) => x.signExtend(_w);
    Logic zext(Logic x) => x.zeroExtend(_w);
    Logic add(Logic a, Logic b) => (a + b).getRange(0, _w);
    Logic sub(Logic a, Logic b) => (a - b).getRange(0, _w);
    Logic mul(Logic a, Logic b) => (a * b).getRange(0, _w);
    Logic neg(Logic a) => sub(sc(0), a);
    Logic sgn(Logic a) => a[_w - 1];
    Logic asrC(Logic x, int n) =>
        n <= 0 ? x : [x[_w - 1].replicate(n), x.getRange(n, _w)].concat();
    Logic absS(Logic a) => mux(sgn(a), neg(a), a);

    // ROUND_POWER_OF_TWO_SIGNED with a CONSTANT shift n (matches SW roundSigned:
    // v>=0 ? (v+half)>>n : -((-v+half)>>n)).
    Logic roundSignedC(Logic v, int n) {
      if (n <= 0) return v;
      final half = sc(1 << (n - 1));
      final posv = asrC(add(v, half), n);
      final negv = neg(asrC(add(neg(v), half), n));
      return mux(sgn(v), negv, posv);
    }

    // convert_to_trans_prec: allowHp ? roundSigned(coor,13) : roundSigned(coor,14)*2.
    final allowHp = input('allow_hp');
    Logic convertToTransPrec(Logic coor) => mux(
      allowHp,
      roundSignedC(coor, 13),
      mul(roundSignedC(coor, 14), sc(2)),
    );

    // integer_mv_precision on a single component (spec: round to nearest
    // multiple of 8, truncating toward zero, tie (|mod|==4) toward zero).
    Logic integerMvPrecision(Logic v) {
      final neg0 = sgn(v);
      final av = absS(v);
      final low = av.getRange(0, 3); // av & 7
      // magnitude with low 3 bits cleared: (av>>3)<<3.
      final cleared = [av.getRange(3, _w), Const(0, width: 3)].concat();
      final add8 = low.gt(Const(4, width: 3)); // low > 4 -> round up
      final m = mux(add8, add(cleared, sc(8)), cleared);
      return mux(neg0, neg(m), m);
    }

    final gmType = input('gm_type');
    final forceInt = input('force_integer');
    Logic matAt(int i) => sext(input('mat$i'));

    // TRANSLATION path.
    final transRow = asrC(matAt(0), 13);
    final transCol = asrC(matAt(1), 13);

    // ROTZOOM / AFFINE path: warp at block centre.
    final w = sc(1 << _warpedModelPrecBits);
    final x = sub(
      add(
        mul(zext(input('mi_c')), sc(4)),
        (zext(input('block_wide')) >> 1).getRange(0, _w),
      ),
      sc(1),
    );
    final y = sub(
      add(
        mul(zext(input('mi_r')), sc(4)),
        (zext(input('block_high')) >> 1).getRange(0, _w),
      ),
      sc(1),
    );
    final xc = add(add(mul(sub(matAt(2), w), x), mul(matAt(3), y)), matAt(0));
    final yc = add(add(mul(matAt(4), x), mul(sub(matAt(5), w), y)), matAt(1));
    final rzRow = convertToTransPrec(yc);
    final rzCol = convertToTransPrec(xc);

    // Select by type (0=IDENTITY,1=TRANSLATION, else ROTZOOM/AFFINE).
    final isIdentity = gmType.eq(Const(0, width: 2));
    final isTrans = gmType.eq(Const(1, width: 2));
    Logic pick(Logic transV, Logic rzV) =>
        mux(isTrans, transV, rzV); // identity handled below
    var row = pick(transRow, rzRow);
    var col = pick(transCol, rzCol);
    // integer-mv rounding (skipped for IDENTITY, which yields 0 anyway).
    row = mux(forceInt, integerMvPrecision(row), row);
    col = mux(forceInt, integerMvPrecision(col), col);
    row = mux(isIdentity, sc(0), row);
    col = mux(isIdentity, sc(0), col);

    output('mv_row') <= row.getRange(0, 32);
    output('mv_col') <= col.getRange(0, 32);
  }
}
