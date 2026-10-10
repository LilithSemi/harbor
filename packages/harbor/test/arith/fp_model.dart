/// Bit-exact IEEE 754 / RISC-V floating point reference model.
///
/// Every function takes and returns raw bit patterns (`BigInt`) plus a
/// format. Internally each op builds the exact value as an integer
/// significand times a power of two, then rounds once through
/// [_roundPack]. Division and square root compute extra guard bits and
/// carry a sticky flag instead of an exact value.
///
/// Flags are a 5-bit bundle, bit 4 down to bit 0: NV DZ OF UF NX, the same
/// order as RISC-V fflags. Tininess is always detected after rounding.
/// NaN results are canonical (sign 0, exponent all ones, mantissa MSB 1),
/// matching TestFloat built with `SPECIALIZE_TYPE=RISCV`.
///
/// Rounding modes are plain ints: 0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM. A
/// caller must pass a valid `rm`; it is not checked.
library;

import 'package:harbor/src/arith/fp_format.dart';

/// A floating point result: raw bits plus the 5 IEEE/RISC-V exception
/// flags that the operation raised.
class FpResult {
  final BigInt bits;
  final int flags;
  const FpResult(this.bits, this.flags);

  @override
  String toString() =>
      'FpResult(${bits.toRadixString(16)}, flags: '
      '${flags.toRadixString(16).padLeft(2, '0')})';
}

const int nvFlag = 1 << 4;
const int dzFlag = 1 << 3;
const int ofFlag = 1 << 2;
const int ufFlag = 1 << 1;
const int nxFlag = 1 << 0;

const int rmRne = 0;
const int rmRtz = 1;
const int rmRdn = 2;
const int rmRup = 3;
const int rmRmm = 4;

/// Quiet sign-injection kinds for [fpSgnj].
enum FpSgnjKind { inject, negate, xor }

/// Compare kinds for [fpCompare]. `lt`/`le` raise NV on any NaN; `ltq`/`leq`
/// raise NV only on a signaling NaN, matching the RISC-V 2019 quiet
/// compares.
enum FpCompareKind { eq, lt, le, ltq, leq }

enum _Class { zero, inf, qnan, snan, finite }

class _Decoded {
  final int sign;
  final _Class cls;
  final BigInt mantissa;
  final int exp2;
  final bool isSubnormal;

  const _Decoded._(
    this.sign,
    this.cls,
    this.mantissa,
    this.exp2,
    this.isSubnormal,
  );

  factory _Decoded.zero(int sign) =>
      _Decoded._(sign, _Class.zero, BigInt.zero, 0, false);
  factory _Decoded.inf(int sign) =>
      _Decoded._(sign, _Class.inf, BigInt.zero, 0, false);
  factory _Decoded.nan(int sign, bool signaling) => _Decoded._(
    sign,
    signaling ? _Class.snan : _Class.qnan,
    BigInt.zero,
    0,
    false,
  );
  factory _Decoded.finite(
    int sign,
    BigInt mantissa,
    int exp2,
    bool isSubnormal,
  ) => _Decoded._(sign, _Class.finite, mantissa, exp2, isSubnormal);

  bool get isNan => cls == _Class.snan || cls == _Class.qnan;

  _Decoded get negated =>
      _Decoded._(sign ^ 1, cls, mantissa, exp2, isSubnormal);
}

_Decoded _decode(HarborFpFormat f, BigInt bits) {
  final mantMask = (BigInt.one << f.mantissaWidth) - BigInt.one;
  final expMask = (BigInt.one << f.exponentWidth) - BigInt.one;
  final sign = ((bits >> (f.exponentWidth + f.mantissaWidth)) & BigInt.one)
      .toInt();
  final expBits = (bits >> f.mantissaWidth) & expMask;
  final mantBits = bits & mantMask;

  if (expBits == expMask) {
    if (mantBits == BigInt.zero) return _Decoded.inf(sign);
    final signaling =
        ((mantBits >> (f.mantissaWidth - 1)) & BigInt.one) == BigInt.zero;
    return _Decoded.nan(sign, signaling);
  }
  if (expBits == BigInt.zero) {
    if (mantBits == BigInt.zero) return _Decoded.zero(sign);
    return _Decoded.finite(sign, mantBits, 1 - f.bias - f.mantissaWidth, true);
  }
  final full = (BigInt.one << f.mantissaWidth) | mantBits;
  return _Decoded.finite(
    sign,
    full,
    expBits.toInt() - f.bias - f.mantissaWidth,
    false,
  );
}

/// Re-encodes a decoded value back to its exact bit pattern. Used where an
/// operation is exact and just needs to hand an operand straight through.
BigInt _reencode(HarborFpFormat f, _Decoded d) {
  switch (d.cls) {
    case _Class.zero:
      return _packZero(f, d.sign);
    case _Class.inf:
      return _packInf(f, d.sign);
    case _Class.qnan:
    case _Class.snan:
      return _packCanonicalNan(f);
    case _Class.finite:
      if (d.isSubnormal) return _assemble(f, d.sign, 0, d.mantissa);
      final expBits = d.exp2 + f.bias + f.mantissaWidth;
      final mantField =
          d.mantissa & ((BigInt.one << f.mantissaWidth) - BigInt.one);
      return _assemble(f, d.sign, expBits, mantField);
  }
}

_Decoded _flushIn(_Decoded d, bool ftz) {
  if (ftz && d.cls == _Class.finite && d.isSubnormal)
    return _Decoded.zero(d.sign);
  return d;
}

FpResult _flushOut(HarborFpFormat f, FpResult r, bool ftz) {
  if (!ftz) return r;
  final signBitPos = f.exponentWidth + f.mantissaWidth;
  final sign = ((r.bits >> signBitPos) & BigInt.one).toInt();
  final expBits =
      (r.bits >> f.mantissaWidth) &
      ((BigInt.one << f.exponentWidth) - BigInt.one);
  final mantBits = r.bits & ((BigInt.one << f.mantissaWidth) - BigInt.one);
  if (expBits == BigInt.zero && mantBits != BigInt.zero) {
    return FpResult(_packZero(f, sign), r.flags | ufFlag | nxFlag);
  }
  return r;
}

BigInt _assemble(HarborFpFormat f, int sign, int expBits, BigInt mantField) =>
    (BigInt.from(sign) << (f.exponentWidth + f.mantissaWidth)) |
    (BigInt.from(expBits) << f.mantissaWidth) |
    mantField;

BigInt _packZero(HarborFpFormat f, int sign) =>
    _assemble(f, sign, 0, BigInt.zero);

BigInt _packInf(HarborFpFormat f, int sign) =>
    _assemble(f, sign, (1 << f.exponentWidth) - 1, BigInt.zero);

BigInt _packCanonicalNan(HarborFpFormat f) => _assemble(
  f,
  0,
  (1 << f.exponentWidth) - 1,
  BigInt.one << (f.mantissaWidth - 1),
);

/// Packs an exact value (no rounding needed) whose leading bit is at
/// position `mantissa.bitLength - 1`, as a normal number.
BigInt _packExactNormal(HarborFpFormat f, int sign, BigInt mantissa, int exp2) {
  final bits = mantissa.bitLength;
  final te = exp2 + bits - 1;
  final expBits = te + f.bias;
  final shift = f.mantissaWidth - (bits - 1);
  final mantField =
      (mantissa << shift) & ((BigInt.one << f.mantissaWidth) - BigInt.one);
  return _assemble(f, sign, expBits, mantField);
}

/// Bit [pos] of a nonnegative [BigInt].
bool _testBit(BigInt x, int pos) => ((x >> pos) & BigInt.one) == BigInt.one;

bool _roundingDecision(
  int rm,
  int sign,
  bool roundBit,
  bool sticky,
  bool keptOdd,
) => switch (rm) {
  rmRne => roundBit && (sticky || keptOdd),
  rmRtz => false,
  rmRdn => sign == 1 && (roundBit || sticky),
  rmRup => sign == 0 && (roundBit || sticky),
  rmRmm => roundBit,
  _ => throw ArgumentError.value(rm, 'rm', 'must be 0 to 4'),
};

BigInt _overflowResult(HarborFpFormat f, int sign, int rm) {
  final toInf =
      rm == rmRne ||
      rm == rmRmm ||
      (rm == rmRup && sign == 0) ||
      (rm == rmRdn && sign == 1);
  if (toInf) return _packInf(f, sign);
  final expBits = (1 << f.exponentWidth) - 2;
  final mantField = (BigInt.one << f.mantissaWidth) - BigInt.one;
  return _assemble(f, sign, expBits, mantField);
}

/// Rounds `mantissa` (bit length `l`, arbitrary) to `keepBits` bits (which
/// may be 0 or negative) per [rm], returning the kept value plus whether
/// any dropped bit, or [extraSticky], was nonzero.
({BigInt kept, bool inexact}) _roundTo(
  BigInt mantissa,
  int l,
  int keepBits,
  int sign,
  int rm,
  bool extraSticky,
) {
  final shift = l - keepBits;
  bool roundBit;
  bool stickyBit;
  BigInt kept;
  if (shift <= 0) {
    kept = mantissa << (-shift);
    roundBit = false;
    stickyBit = extraSticky;
  } else {
    roundBit = _testBit(mantissa, shift - 1);
    final mask = shift >= 2
        ? (BigInt.one << (shift - 1)) - BigInt.one
        : BigInt.zero;
    stickyBit = (mantissa & mask) != BigInt.zero || extraSticky;
    kept = mantissa >> shift;
  }
  final keptOdd = (kept & BigInt.one) == BigInt.one;
  final inc = _roundingDecision(rm, sign, roundBit, stickyBit, keptOdd);
  return (kept: inc ? kept + BigInt.one : kept, inexact: roundBit || stickyBit);
}

/// Rounds the exact magnitude `mantissa * 2^exp2` into [f]. UF tininess is
/// decided by an unbounded-exponent pass before the real subnormal-grid
/// pass; the two can disagree exactly at the smallest normal value.
FpResult _roundPack(
  HarborFpFormat f,
  int sign,
  BigInt mantissa,
  int exp2,
  int rm, {
  bool extraSticky = false,
}) {
  final p = f.mantissaWidth + 1;
  final minNormalTe = 1 - f.bias;
  final maxNormalTe = (1 << f.exponentWidth) - 2 - f.bias;
  final l = mantissa.bitLength;

  final full = _roundTo(mantissa, l, p, sign, rm, extraSticky);
  final exp2Full = exp2 + (l - p);
  final teFull = full.kept == BigInt.zero
      ? exp2Full
      : exp2Full + full.kept.bitLength - 1;
  final tiny = teFull < minNormalTe;

  final te = exp2 + l - 1;
  final keepBits = te >= minNormalTe ? p : p - (minNormalTe - te);
  final r = _roundTo(mantissa, l, keepBits, sign, rm, extraSticky);
  final kept2 = r.kept;
  final exp2Result = exp2 + (l - keepBits);

  if (kept2 == BigInt.zero) {
    return FpResult(_packZero(f, sign), r.inexact ? (nxFlag | ufFlag) : 0);
  }

  final bitlen2 = kept2.bitLength;
  final teFinal = exp2Result + bitlen2 - 1;

  if (teFinal > maxNormalTe) {
    return FpResult(_overflowResult(f, sign, rm), ofFlag | nxFlag);
  }
  final ufBit = tiny && r.inexact ? ufFlag : 0;
  if (teFinal < minNormalTe) {
    return FpResult(
      _assemble(f, sign, 0, kept2),
      r.inexact ? (nxFlag | ufBit) : 0,
    );
  }
  final expBits = teFinal + f.bias;
  final mantField = kept2 & ((BigInt.one << f.mantissaWidth) - BigInt.one);
  return FpResult(
    _assemble(f, sign, expBits, mantField),
    r.inexact ? (nxFlag | ufBit) : 0,
  );
}

/// Rounds the magnitude `mantissa * 2^exp2` to an integer, per [rm].
({BigInt magnitude, bool inexact}) _roundMagnitudeToInt(
  int sign,
  BigInt mantissa,
  int exp2,
  int rm,
) {
  if (exp2 >= 0) {
    return (magnitude: mantissa << exp2, inexact: false);
  }
  final shift = -exp2;
  final roundBit = _testBit(mantissa, shift - 1);
  final mask = shift >= 2
      ? (BigInt.one << (shift - 1)) - BigInt.one
      : BigInt.zero;
  final sticky = (mantissa & mask) != BigInt.zero;
  final kept = mantissa >> shift;
  final keptOdd = (kept & BigInt.one) == BigInt.one;
  final inc = _roundingDecision(rm, sign, roundBit, sticky, keptOdd);
  return (
    magnitude: inc ? kept + BigInt.one : kept,
    inexact: roundBit || sticky,
  );
}

/// Floor sqrt of a nonnegative [BigInt], exact for perfect squares.
BigInt _isqrt(BigInt n) {
  if (n < BigInt.two) return n;
  var x = BigInt.one << ((n.bitLength + 1) ~/ 2);
  while (true) {
    final y = (x + n ~/ x) >> 1;
    if (y >= x) return x;
    x = y;
  }
}

int _floorDiv2(int n) => n >= 0 ? n ~/ 2 : (n - 1) ~/ 2;

/// Compares two finite-or-special decoded values. -0 and +0 compare equal.
int _compareValues(_Decoded da, _Decoded db) {
  final aZero = da.cls == _Class.zero;
  final bZero = db.cls == _Class.zero;
  if (aZero && bZero) return 0;
  if (aZero) return db.sign == 1 ? 1 : -1;
  if (bZero) return da.sign == 1 ? -1 : 1;

  final aInf = da.cls == _Class.inf;
  final bInf = db.cls == _Class.inf;
  if (aInf && bInf) {
    if (da.sign == db.sign) return 0;
    return da.sign == 1 ? -1 : 1;
  }
  if (aInf) return da.sign == 1 ? -1 : 1;
  if (bInf) return db.sign == 1 ? 1 : -1;

  final minExp = da.exp2 < db.exp2 ? da.exp2 : db.exp2;
  final va = da.mantissa << (da.exp2 - minExp);
  final vb = db.mantissa << (db.exp2 - minExp);
  final signedA = da.sign == 1 ? -va : va;
  final signedB = db.sign == 1 ? -vb : vb;
  return signedA.compareTo(signedB);
}

// Add / subtract

FpResult fpAdd(
  HarborFpFormat f,
  BigInt a,
  BigInt b,
  int rm, {
  bool ftz = false,
}) => _addImpl(f, a, b, rm, ftz, subtract: false);

FpResult fpSub(
  HarborFpFormat f,
  BigInt a,
  BigInt b,
  int rm, {
  bool ftz = false,
}) => _addImpl(f, a, b, rm, ftz, subtract: true);

FpResult _addImpl(
  HarborFpFormat f,
  BigInt aBits,
  BigInt bBits,
  int rm,
  bool ftz, {
  required bool subtract,
}) {
  final da = _flushIn(_decode(f, aBits), ftz);
  var db = _flushIn(_decode(f, bBits), ftz);
  if (subtract) db = db.negated;
  return _flushOut(f, _addDecoded(f, da, db, rm), ftz);
}

FpResult _addDecoded(HarborFpFormat f, _Decoded da, _Decoded db, int rm) {
  if (da.isNan || db.isNan) {
    final nv = da.cls == _Class.snan || db.cls == _Class.snan;
    return FpResult(_packCanonicalNan(f), nv ? nvFlag : 0);
  }
  final aInf = da.cls == _Class.inf;
  final bInf = db.cls == _Class.inf;
  if (aInf || bInf) {
    if (aInf && bInf && da.sign != db.sign) {
      return FpResult(_packCanonicalNan(f), nvFlag);
    }
    return FpResult(_packInf(f, aInf ? da.sign : db.sign), 0);
  }
  final aZero = da.cls == _Class.zero;
  final bZero = db.cls == _Class.zero;
  if (aZero && bZero) {
    if (da.sign == db.sign) return FpResult(_packZero(f, da.sign), 0);
    return FpResult(_packZero(f, rm == rmRdn ? 1 : 0), 0);
  }
  if (aZero) return FpResult(_reencode(f, db), 0);
  if (bZero) return FpResult(_reencode(f, da), 0);

  final minExp = da.exp2 < db.exp2 ? da.exp2 : db.exp2;
  final va = da.mantissa << (da.exp2 - minExp);
  final vb = db.mantissa << (db.exp2 - minExp);
  final sum = (da.sign == 1 ? -va : va) + (db.sign == 1 ? -vb : vb);
  if (sum == BigInt.zero) {
    return FpResult(_packZero(f, rm == rmRdn ? 1 : 0), 0);
  }
  final sign = sum < BigInt.zero ? 1 : 0;
  return _roundPack(f, sign, sum.abs(), minExp, rm);
}

// Multiply

FpResult fpMul(
  HarborFpFormat f,
  BigInt aBits,
  BigInt bBits,
  int rm, {
  bool ftz = false,
}) {
  final da = _flushIn(_decode(f, aBits), ftz);
  final db = _flushIn(_decode(f, bBits), ftz);
  return _flushOut(f, _mulDecoded(f, da, db, rm), ftz);
}

FpResult _mulDecoded(HarborFpFormat f, _Decoded da, _Decoded db, int rm) {
  if (da.isNan || db.isNan) {
    final nv = da.cls == _Class.snan || db.cls == _Class.snan;
    return FpResult(_packCanonicalNan(f), nv ? nvFlag : 0);
  }
  final sign = da.sign ^ db.sign;
  final aInf = da.cls == _Class.inf;
  final bInf = db.cls == _Class.inf;
  final aZero = da.cls == _Class.zero;
  final bZero = db.cls == _Class.zero;
  if ((aInf && bZero) || (aZero && bInf)) {
    return FpResult(_packCanonicalNan(f), nvFlag);
  }
  if (aInf || bInf) return FpResult(_packInf(f, sign), 0);
  if (aZero || bZero) return FpResult(_packZero(f, sign), 0);
  return _roundPack(f, sign, da.mantissa * db.mantissa, da.exp2 + db.exp2, rm);
}

// Fused multiply-add

/// `fa` is the multiplicand format for `a`/`b`; `fc` is the addend/result
/// format. They differ only for a widening FMA (narrow `a`,`b`, wide `c`).
FpResult fpFma(
  HarborFpFormat fa,
  HarborFpFormat fc,
  BigInt a,
  BigInt b,
  BigInt c,
  int rm, {
  bool negProduct = false,
  bool negAddend = false,
  bool ftz = false,
}) {
  var da = _flushIn(_decode(fa, a), ftz);
  final db = _flushIn(_decode(fa, b), ftz);
  var dc = _flushIn(_decode(fc, c), ftz);
  if (negProduct) da = da.negated;
  if (negAddend) dc = dc.negated;

  // A signaling operand always raises NV, even when some other operand is
  // already NaN, or the a x b product is itself invalid (0 x infinity).
  final anySignaling =
      da.cls == _Class.snan || db.cls == _Class.snan || dc.cls == _Class.snan;

  if (da.isNan || db.isNan) {
    return _flushOut(
      fc,
      FpResult(_packCanonicalNan(fc), anySignaling ? nvFlag : 0),
      ftz,
    );
  }

  final prodSign = da.sign ^ db.sign;
  final aInf = da.cls == _Class.inf;
  final bInf = db.cls == _Class.inf;
  final aZero = da.cls == _Class.zero;
  final bZero = db.cls == _Class.zero;
  final prodInvalid = (aInf && bZero) || (aZero && bInf);
  if (prodInvalid || dc.isNan) {
    final nv = anySignaling || prodInvalid;
    return _flushOut(fc, FpResult(_packCanonicalNan(fc), nv ? nvFlag : 0), ftz);
  }
  final prodIsInf = aInf || bInf;
  final prodIsZero = !prodIsInf && (aZero || bZero);

  if (prodIsInf && dc.cls == _Class.inf && prodSign != dc.sign) {
    return _flushOut(fc, FpResult(_packCanonicalNan(fc), nvFlag), ftz);
  }
  if (prodIsInf) {
    return _flushOut(fc, FpResult(_packInf(fc, prodSign), 0), ftz);
  }
  if (dc.cls == _Class.inf) {
    return _flushOut(fc, FpResult(_packInf(fc, dc.sign), 0), ftz);
  }

  if (prodIsZero && dc.cls == _Class.zero) {
    if (prodSign == dc.sign) {
      return _flushOut(fc, FpResult(_packZero(fc, prodSign), 0), ftz);
    }
    return _flushOut(fc, FpResult(_packZero(fc, rm == rmRdn ? 1 : 0), 0), ftz);
  }
  if (prodIsZero) {
    return _flushOut(fc, FpResult(_reencode(fc, dc), 0), ftz);
  }

  final prodMantissa = da.mantissa * db.mantissa;
  final prodExp2 = da.exp2 + db.exp2;
  if (dc.cls == _Class.zero) {
    return _flushOut(
      fc,
      _roundPack(fc, prodSign, prodMantissa, prodExp2, rm),
      ftz,
    );
  }

  final minExp = prodExp2 < dc.exp2 ? prodExp2 : dc.exp2;
  final vp = prodMantissa << (prodExp2 - minExp);
  final vc = dc.mantissa << (dc.exp2 - minExp);
  final sum = (prodSign == 1 ? -vp : vp) + (dc.sign == 1 ? -vc : vc);
  if (sum == BigInt.zero) {
    return _flushOut(fc, FpResult(_packZero(fc, rm == rmRdn ? 1 : 0), 0), ftz);
  }
  final sign = sum < BigInt.zero ? 1 : 0;
  return _flushOut(fc, _roundPack(fc, sign, sum.abs(), minExp, rm), ftz);
}

// Divide

FpResult fpDiv(
  HarborFpFormat f,
  BigInt aBits,
  BigInt bBits,
  int rm, {
  bool ftz = false,
}) {
  final da = _flushIn(_decode(f, aBits), ftz);
  final db = _flushIn(_decode(f, bBits), ftz);
  return _flushOut(f, _divDecoded(f, da, db, rm), ftz);
}

FpResult _divDecoded(HarborFpFormat f, _Decoded da, _Decoded db, int rm) {
  if (da.isNan || db.isNan) {
    final nv = da.cls == _Class.snan || db.cls == _Class.snan;
    return FpResult(_packCanonicalNan(f), nv ? nvFlag : 0);
  }
  final sign = da.sign ^ db.sign;
  final aInf = da.cls == _Class.inf;
  final bInf = db.cls == _Class.inf;
  final aZero = da.cls == _Class.zero;
  final bZero = db.cls == _Class.zero;
  if ((aInf && bInf) || (aZero && bZero)) {
    return FpResult(_packCanonicalNan(f), nvFlag);
  }
  if (aInf) return FpResult(_packInf(f, sign), 0);
  if (bZero) return FpResult(_packInf(f, sign), dzFlag);
  if (bInf) return FpResult(_packZero(f, sign), 0);
  if (aZero) return FpResult(_packZero(f, sign), 0);

  final p = f.mantissaWidth + 1;
  final shiftAmt = db.mantissa.bitLength + p + 8;
  final numerator = da.mantissa << shiftAmt;
  final q = numerator ~/ db.mantissa;
  final r = numerator - q * db.mantissa;
  final exp2 = da.exp2 - db.exp2 - shiftAmt;
  return _roundPack(f, sign, q, exp2, rm, extraSticky: r != BigInt.zero);
}

// Square root

FpResult fpSqrt(HarborFpFormat f, BigInt aBits, int rm, {bool ftz = false}) {
  final da = _flushIn(_decode(f, aBits), ftz);
  return _flushOut(f, _sqrtDecoded(f, da, rm), ftz);
}

FpResult _sqrtDecoded(HarborFpFormat f, _Decoded da, int rm) {
  if (da.isNan) {
    return FpResult(_packCanonicalNan(f), da.cls == _Class.snan ? nvFlag : 0);
  }
  if (da.cls == _Class.zero) return FpResult(_packZero(f, da.sign), 0);
  if (da.sign == 1) return FpResult(_packCanonicalNan(f), nvFlag);
  if (da.cls == _Class.inf) return FpResult(_packInf(f, 0), 0);

  var mantissa = da.mantissa;
  var exp2 = da.exp2;
  if (exp2.isOdd) {
    mantissa <<= 1;
    exp2 -= 1;
  }
  final extraBits = f.mantissaWidth + 1 + 8;
  final shiftAmt2 = 2 * extraBits;
  final radicand = mantissa << shiftAmt2;
  final s = _isqrt(radicand);
  final rem = radicand - s * s;
  final resultExp2 = (exp2 - shiftAmt2) ~/ 2;
  return _roundPack(f, 0, s, resultExp2, rm, extraSticky: rem != BigInt.zero);
}

// Compare

FpResult fpCompare(
  HarborFpFormat f,
  BigInt aBits,
  BigInt bBits,
  FpCompareKind kind, {
  bool ftz = false,
}) {
  final da = _flushIn(_decode(f, aBits), ftz);
  final db = _flushIn(_decode(f, bBits), ftz);
  final anyNan = da.isNan || db.isNan;
  final anySignaling = da.cls == _Class.snan || db.cls == _Class.snan;
  final quiet =
      kind == FpCompareKind.eq ||
      kind == FpCompareKind.ltq ||
      kind == FpCompareKind.leq;
  final nv = quiet ? anySignaling : anyNan;
  if (anyNan) {
    return FpResult(BigInt.zero, nv ? nvFlag : 0);
  }
  final cmp = _compareValues(da, db);
  final result = switch (kind) {
    FpCompareKind.eq => cmp == 0,
    FpCompareKind.lt || FpCompareKind.ltq => cmp < 0,
    FpCompareKind.le || FpCompareKind.leq => cmp <= 0,
  };
  return FpResult(result ? BigInt.one : BigInt.zero, nv ? nvFlag : 0);
}

// Min / max

FpResult fpMin(HarborFpFormat f, BigInt a, BigInt b, {bool ftz = false}) =>
    _minMax(f, a, b, max: false, canonicalizeSingle: false, ftz: ftz);

FpResult fpMax(HarborFpFormat f, BigInt a, BigInt b, {bool ftz = false}) =>
    _minMax(f, a, b, max: true, canonicalizeSingle: false, ftz: ftz);

FpResult fpMinM(HarborFpFormat f, BigInt a, BigInt b, {bool ftz = false}) =>
    _minMax(f, a, b, max: false, canonicalizeSingle: true, ftz: ftz);

FpResult fpMaxM(HarborFpFormat f, BigInt a, BigInt b, {bool ftz = false}) =>
    _minMax(f, a, b, max: true, canonicalizeSingle: true, ftz: ftz);

/// A flushed subnormal input has no original bit pattern left to return, so
/// the winning operand's bits come from here instead of the raw input bits
/// whenever that operand is zero (either originally, or by flushing).
BigInt _minMaxBits(HarborFpFormat f, BigInt raw, _Decoded d) =>
    d.cls == _Class.zero ? _packZero(f, d.sign) : raw;

FpResult _minMax(
  HarborFpFormat f,
  BigInt aBits,
  BigInt bBits, {
  required bool max,
  required bool canonicalizeSingle,
  bool ftz = false,
}) {
  final da = _flushIn(_decode(f, aBits), ftz);
  final db = _flushIn(_decode(f, bBits), ftz);
  final nv = da.cls == _Class.snan || db.cls == _Class.snan;
  if (da.isNan && db.isNan) {
    return FpResult(_packCanonicalNan(f), nv ? nvFlag : 0);
  }
  if (da.isNan) {
    return FpResult(
      canonicalizeSingle ? _packCanonicalNan(f) : _minMaxBits(f, bBits, db),
      nv ? nvFlag : 0,
    );
  }
  if (db.isNan) {
    return FpResult(
      canonicalizeSingle ? _packCanonicalNan(f) : _minMaxBits(f, aBits, da),
      nv ? nvFlag : 0,
    );
  }

  final aNegZero = da.cls == _Class.zero && da.sign == 1;
  final bNegZero = db.cls == _Class.zero && db.sign == 1;
  final aPosZero = da.cls == _Class.zero && da.sign == 0;
  final bPosZero = db.cls == _Class.zero && db.sign == 0;
  if ((aNegZero && bPosZero) || (aPosZero && bNegZero)) {
    final wantNeg = !max;
    final aWins = wantNeg ? aNegZero : aPosZero;
    return FpResult(
      aWins ? _minMaxBits(f, aBits, da) : _minMaxBits(f, bBits, db),
      0,
    );
  }

  final cmp = _compareValues(da, db);
  final aWins = max ? cmp >= 0 : cmp <= 0;
  return FpResult(
    aWins ? _minMaxBits(f, aBits, da) : _minMaxBits(f, bBits, db),
    0,
  );
}

// Classify / sign injection

FpResult fpClass(HarborFpFormat f, BigInt aBits) {
  final d = _decode(f, aBits);
  final bit = switch (d.cls) {
    _Class.inf => d.sign == 1 ? 0 : 7,
    _Class.zero => d.sign == 1 ? 3 : 4,
    _Class.snan => 8,
    _Class.qnan => 9,
    _Class.finite =>
      d.sign == 1 ? (d.isSubnormal ? 2 : 1) : (d.isSubnormal ? 5 : 6),
  };
  return FpResult(BigInt.one << bit, 0);
}

/// Sign injection never canonicalizes a NaN payload and never raises a
/// flag: it only ever touches the sign bit.
FpResult fpSgnj(HarborFpFormat f, BigInt aBits, BigInt bBits, FpSgnjKind kind) {
  final signBitPos = f.exponentWidth + f.mantissaWidth;
  final signA = (aBits >> signBitPos) & BigInt.one;
  final signB = (bBits >> signBitPos) & BigInt.one;
  final rest = aBits & ((BigInt.one << signBitPos) - BigInt.one);
  final sign = switch (kind) {
    FpSgnjKind.inject => signB,
    FpSgnjKind.negate => BigInt.one - signB,
    FpSgnjKind.xor => signA ^ signB,
  };
  return FpResult((sign << signBitPos) | rest, 0);
}

// Format and integer conversions

FpResult fpToFp(
  HarborFpFormat from,
  HarborFpFormat to,
  BigInt aBits,
  int rm, {
  bool ftz = false,
}) {
  final d = _flushIn(_decode(from, aBits), ftz);
  FpResult r;
  if (d.isNan) {
    r = FpResult(_packCanonicalNan(to), d.cls == _Class.snan ? nvFlag : 0);
  } else if (d.cls == _Class.inf) {
    r = FpResult(_packInf(to, d.sign), 0);
  } else if (d.cls == _Class.zero) {
    r = FpResult(_packZero(to, d.sign), 0);
  } else {
    r = _roundPack(to, d.sign, d.mantissa, d.exp2, rm);
  }
  return _flushOut(to, r, ftz);
}

/// Converts to a two's complement integer of [width] bits. NaN and
/// out-of-range values saturate and raise NV (not NX); NaN converts to the
/// maximum representable value, matching the RISC-V `fcvt` rules.
FpResult fpToInt(
  HarborFpFormat f,
  BigInt aBits,
  int width,
  bool signed,
  int rm, {
  bool ftz = false,
}) {
  final d = _flushIn(_decode(f, aBits), ftz);
  final maxVal = signed
      ? (BigInt.one << (width - 1)) - BigInt.one
      : (BigInt.one << width) - BigInt.one;
  final minVal = signed ? -(BigInt.one << (width - 1)) : BigInt.zero;
  final mask = (BigInt.one << width) - BigInt.one;

  if (d.isNan) return FpResult(maxVal & mask, nvFlag);
  if (d.cls == _Class.inf) {
    return FpResult((d.sign == 1 ? minVal : maxVal) & mask, nvFlag);
  }
  if (d.cls == _Class.zero) return FpResult(BigInt.zero, 0);

  final rounded = _roundMagnitudeToInt(d.sign, d.mantissa, d.exp2, rm);
  final value = d.sign == 1 ? -rounded.magnitude : rounded.magnitude;
  if (value < minVal || value > maxVal) {
    return FpResult((value > maxVal ? maxVal : minVal) & mask, nvFlag);
  }
  return FpResult(value & mask, rounded.inexact ? nxFlag : 0);
}

/// Converts a [width]-bit two's complement integer pattern to [f].
FpResult intToFp(
  HarborFpFormat f,
  BigInt xBits,
  int width,
  bool signed,
  int rm,
) {
  var value = xBits & ((BigInt.one << width) - BigInt.one);
  if (signed && _testBit(value, width - 1)) {
    value -= BigInt.one << width;
  }
  if (value == BigInt.zero) return FpResult(_packZero(f, 0), 0);
  final sign = value.isNegative ? 1 : 0;
  return _roundPack(f, sign, value.abs(), 0, rm);
}

/// `fcvtmod.w.d`: fp64 to a signed 32-bit integer, always RTZ, wrapping
/// modulo 2^32 instead of saturating. Flags match `fcvt.w.d` on the same
/// input: NV for NaN, infinity, or an out-of-int32-range result; NX for an
/// inexact in-range truncation. Returns the raw 32-bit pattern; XLEN
/// sign-extension is the caller's job.
FpResult fpCvtModWD(BigInt aBits, {bool ftz = false}) {
  const f = HarborFpFormat.fp64;
  final d = _flushIn(_decode(f, aBits), ftz);
  const width = 32;
  final maxVal = (BigInt.one << (width - 1)) - BigInt.one;
  final minVal = -(BigInt.one << (width - 1));
  final mask = (BigInt.one << width) - BigInt.one;

  if (d.isNan || d.cls == _Class.inf) {
    return FpResult(BigInt.zero, nvFlag);
  }
  if (d.cls == _Class.zero) return FpResult(BigInt.zero, 0);

  final rounded = _roundMagnitudeToInt(d.sign, d.mantissa, d.exp2, rmRtz);
  final value = d.sign == 1 ? -rounded.magnitude : rounded.magnitude;
  final outOfRange = value < minVal || value > maxVal;
  final flags = outOfRange ? nvFlag : (rounded.inexact ? nxFlag : 0);
  return FpResult(value & mask, flags);
}

/// `fround`/`froundnx`: round to an integer value, kept in format [f].
/// Zero and infinity pass through unmodified. [exact] selects `froundnx`,
/// which also raises NX on an inexact, non-NaN input; plain `fround`
/// raises only NV, and only for a signaling NaN.
FpResult fpRound(
  HarborFpFormat f,
  BigInt aBits,
  int rm, {
  bool exact = false,
  bool ftz = false,
}) {
  final d = _flushIn(_decode(f, aBits), ftz);
  if (d.isNan) {
    return FpResult(_packCanonicalNan(f), d.cls == _Class.snan ? nvFlag : 0);
  }
  if (d.cls == _Class.zero || d.cls == _Class.inf) {
    return _flushOut(f, FpResult(_reencode(f, d), 0), ftz);
  }
  final rounded = _roundMagnitudeToInt(d.sign, d.mantissa, d.exp2, rm);
  final flags = exact && rounded.inexact ? nxFlag : 0;
  if (rounded.magnitude == BigInt.zero) {
    return _flushOut(f, FpResult(_packZero(f, d.sign), flags), ftz);
  }
  final r = _roundPack(f, d.sign, rounded.magnitude, 0, rm);
  return _flushOut(f, FpResult(r.bits, flags), ftz);
}

// fli.*, RISC-V ISA manual, Zfa extension, table `flis`
// (src/unpriv/zfa.adoc). Entries are (mantissa, exp2): value = mantissa *
// 2^exp2. Index 1 (minimum positive normal), 30 (+inf) and 31 (canonical
// NaN) are format dependent and handled separately.

const Map<int, (int, int)> _fliTable = {
  0: (1, 0), // -1.0 (sign applied separately)
  2: (1, -16),
  3: (1, -15),
  4: (1, -8),
  5: (1, -7),
  6: (1, -4),
  7: (1, -3),
  8: (1, -2),
  9: (5, -4),
  10: (3, -3),
  11: (7, -4),
  12: (1, -1),
  13: (5, -3),
  14: (3, -2),
  15: (7, -3),
  16: (1, 0),
  17: (5, -2),
  18: (3, -1),
  19: (7, -2),
  20: (1, 1),
  21: (5, -1),
  22: (3, 0),
  23: (1, 2),
  24: (1, 3),
  25: (1, 4),
  26: (1, 7),
  27: (1, 8),
  28: (1, 15),
  29: (1, 16),
};

/// `fli.*`: loads one of 32 format constants. Never raises a flag. If an
/// entry overflows the format (entry 29 in half precision), the spec says
/// to load +infinity instead.
FpResult fpLi(HarborFpFormat f, int index) {
  if (index < 0 || index > 31) {
    throw ArgumentError.value(index, 'index', 'must be 0 to 31');
  }
  if (index == 1) {
    return FpResult(_packExactNormal(f, 0, BigInt.one, 1 - f.bias), 0);
  }
  if (index == 30) return FpResult(_packInf(f, 0), 0);
  if (index == 31) return FpResult(_packCanonicalNan(f), 0);

  final (m, e) = _fliTable[index]!;
  final mantissa = BigInt.from(m);
  final te = e + mantissa.bitLength - 1;
  final maxNormalTe = (1 << f.exponentWidth) - 2 - f.bias;
  if (te > maxNormalTe) return FpResult(_packInf(f, 0), 0);
  // Some entries (fp16 2^-16, 2^-15) land in the subnormal range for a
  // narrow format, so this packs through the rounder, not _packExactNormal.
  final sign = index == 0 ? 1 : 0;
  final bits = _roundPack(f, sign, mantissa, e, rmRne).bits;
  return FpResult(bits, 0);
}

// vfrec7.v / vfrsqrt7.v, RISC-V "V" vector extension 1.0, sections
// "Vector Floating-Point Reciprocal Estimate Instruction" and
// "... Reciprocal Square-Root Estimate Instruction" (v-spec.adoc), tables
// transcribed from vfrec7.adoc and vfrsqrt7.adoc.

const List<int> _vfrec7Table = [
  127,
  125,
  123,
  121,
  119,
  117,
  116,
  114,
  112,
  110,
  109,
  107,
  105,
  104,
  102,
  100,
  99,
  97,
  96,
  94,
  93,
  91,
  90,
  88,
  87,
  85,
  84,
  83,
  81,
  80,
  79,
  77,
  76,
  75,
  74,
  72,
  71,
  70,
  69,
  68,
  66,
  65,
  64,
  63,
  62,
  61,
  60,
  59,
  58,
  57,
  56,
  55,
  54,
  53,
  52,
  51,
  50,
  49,
  48,
  47,
  46,
  45,
  44,
  43,
  42,
  41,
  40,
  40,
  39,
  38,
  37,
  36,
  35,
  35,
  34,
  33,
  32,
  31,
  31,
  30,
  29,
  28,
  28,
  27,
  26,
  25,
  25,
  24,
  23,
  23,
  22,
  21,
  21,
  20,
  19,
  19,
  18,
  17,
  17,
  16,
  15,
  15,
  14,
  14,
  13,
  12,
  12,
  11,
  11,
  10,
  9,
  9,
  8,
  8,
  7,
  7,
  6,
  5,
  5,
  4,
  4,
  3,
  3,
  2,
  2,
  1,
  1,
  0,
];

const List<List<int>> _vfrsqrt7Table = [
  [
    52,
    51,
    50,
    48,
    47,
    46,
    44,
    43,
    42,
    41,
    40,
    39,
    38,
    36,
    35,
    34,
    33,
    32,
    31,
    30,
    30,
    29,
    28,
    27,
    26,
    25,
    24,
    23,
    23,
    22,
    21,
    20,
    19,
    19,
    18,
    17,
    16,
    16,
    15,
    14,
    14,
    13,
    12,
    12,
    11,
    10,
    10,
    9,
    9,
    8,
    7,
    7,
    6,
    6,
    5,
    4,
    4,
    3,
    3,
    2,
    2,
    1,
    1,
    0,
  ],
  [
    127,
    125,
    123,
    121,
    119,
    118,
    116,
    114,
    113,
    111,
    109,
    108,
    106,
    105,
    103,
    102,
    100,
    99,
    97,
    96,
    95,
    93,
    92,
    91,
    90,
    88,
    87,
    86,
    85,
    84,
    83,
    82,
    80,
    79,
    78,
    77,
    76,
    75,
    74,
    73,
    72,
    71,
    70,
    70,
    69,
    68,
    67,
    66,
    65,
    64,
    63,
    63,
    62,
    61,
    60,
    59,
    59,
    58,
    57,
    56,
    56,
    55,
    54,
    53,
  ],
];

/// The top [n] bits of [mantissa] after its leading one, zero-padded on the
/// right if fewer than [n] fraction bits exist (a normalized subnormal).
int _topNAfterLeadingOne(BigInt mantissa, int n) {
  final fracBits = mantissa.bitLength - 1;
  final frac = mantissa - (BigInt.one << fracBits);
  if (fracBits >= n) return (frac >> (fracBits - n)).toInt();
  return (frac << (n - fracBits)).toInt();
}

/// `vfrec7.v`: a 7-bit accurate estimate of 1/x.
FpResult fpRec7(HarborFpFormat f, BigInt aBits, int rm, {bool ftz = false}) {
  final d = _flushIn(_decode(f, aBits), ftz);
  return _flushOut(f, _rec7Decoded(f, d, rm), ftz);
}

FpResult _rec7Decoded(HarborFpFormat f, _Decoded d, int rm) {
  if (d.isNan) {
    return FpResult(_packCanonicalNan(f), d.cls == _Class.snan ? nvFlag : 0);
  }
  if (d.cls == _Class.zero) return FpResult(_packInf(f, d.sign), dzFlag);
  if (d.cls == _Class.inf) return FpResult(_packZero(f, d.sign), 0);

  final bias = f.bias;
  final te = d.exp2 + d.mantissa.bitLength - 1;
  final outExpNorm = bias - 1 - te;

  if (outExpNorm > 2 * bias) {
    return FpResult(_overflowResult(f, d.sign, rm), ofFlag | nxFlag);
  }

  final idx = _topNAfterLeadingOne(d.mantissa, 7);
  final outTop7 = _vfrec7Table[idx];
  final p = f.mantissaWidth;
  final fracField = BigInt.from(outTop7) << (p - 7);

  if (outExpNorm <= 0) {
    final normalizedSigFull = (BigInt.one << p) | fracField;
    final mantField = normalizedSigFull >> (1 - outExpNorm);
    return FpResult(_assemble(f, d.sign, 0, mantField), 0);
  }
  return FpResult(_assemble(f, d.sign, outExpNorm, fracField), 0);
}

/// `vfrsqrt7.v`: a 7-bit accurate estimate of 1/sqrt(x).
FpResult fpRsqrt7(HarborFpFormat f, BigInt aBits, {bool ftz = false}) {
  final d = _flushIn(_decode(f, aBits), ftz);
  return _flushOut(f, _rsqrt7Decoded(f, d), ftz);
}

FpResult _rsqrt7Decoded(HarborFpFormat f, _Decoded d) {
  if (d.isNan) {
    return FpResult(_packCanonicalNan(f), d.cls == _Class.snan ? nvFlag : 0);
  }
  if (d.sign == 1 && d.cls != _Class.zero) {
    return FpResult(_packCanonicalNan(f), nvFlag);
  }
  if (d.cls == _Class.zero) return FpResult(_packInf(f, d.sign), dzFlag);
  if (d.cls == _Class.inf) return FpResult(_packZero(f, 0), 0);

  final bias = f.bias;
  final te = d.exp2 + d.mantissa.bitLength - 1;
  final expLsb = (te + bias) & 1;
  final idx = _topNAfterLeadingOne(d.mantissa, 6);
  final outTop7 = _vfrsqrt7Table[expLsb][idx];
  final outExpField = _floorDiv2(2 * bias - 1 - te);
  final p = f.mantissaWidth;
  final fracField = BigInt.from(outTop7) << (p - 7);
  return FpResult(_assemble(f, 0, outExpField, fracField), 0);
}
