import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'bit_reader.dart';

/// AV1 `global_motion_params` decoder (spec 5.9.24 / libaom
/// `read_global_motion_params`). A BitReader-driven FSM that decodes the seven
/// reference global-motion models (LAST_FRAME .. ALTREF_FRAME) from the
/// uncompressed header.
///
/// Per reference it reads `is_global = f(1)`. If non-identity, the type
/// (ROTZOOM / TRANSLATION / AFFINE) and then the subexp-coded warp parameters
/// (`decode_signed_subexp_with_ref` -> `decode_unsigned_subexp_with_ref` ->
/// `decode_subexp` -> `read_primitive_quniform`, with the recentering), each
/// reconstructed relative to the primary reference's saved model
/// (`ref_params`). The variable-length subexp read is a nested sub-FSM.
///
/// Inputs: `bytes` (byte window, bit 0 = first bit of global_motion_params),
/// `allow_high_precision_mv`, and `ref_params` (7 refs x 6 int32 params, the
/// primary-ref saved `globalMotion[ref]` or the default identity model). Outputs:
/// `gm_type_i` (2b) and `mat_i_j` (32b) for ref i in 0..6, param j in 0..5, plus
/// `bits_consumed` and `done`. Combinational-free of the tile pipeline: this is a
/// header-time block, not a per-pixel datapath.
class HarborGmParams extends BridgeModule {
  static const int _w = 32; // datapath working width
  static const int _numRefs = 7;
  static const int _identity = 0, _translation = 1, _rotzoom = 2, _affine = 3;

  HarborGmParams({int maxBytes = 32, String? name})
    : super('HarborGmParams', name: name ?? 'gm_params') {
    final totalBits = maxBytes * 8;
    final offW = totalBits.bitLength;

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: totalBits);
    createPort('allow_high_precision_mv', PortDirection.input);
    // bit cursor (into `bytes`) where global_motion_params begins. `bits_consumed`
    // reports the absolute cursor after the section, so the host header FSM can
    // resume from it directly.
    createPort('base_offset', PortDirection.input, width: offW);
    // ref_params[ref*6 + j], each int32, ref 0..6, j 0..5.
    createPort('ref_params', PortDirection.input, width: _numRefs * 6 * 32);

    addOutput('done');
    addOutput('bits_consumed', width: offW);
    for (var r = 0; r < _numRefs; r++) {
      addOutput('gm_type_$r', width: 2);
      for (var j = 0; j < 6; j++) {
        addOutput('mat_${r}_$j', width: 32);
      }
    }

    final reader = HarborBitReader(maxBytes: maxBytes, name: 'gm_rd');
    addSubModule(reader);

    // signed helpers (32b)
    Logic sc(int v) => Const(BigInt.from(v).toUnsigned(_w), width: _w);
    Logic add(Logic a, Logic b) => (a + b).getRange(0, _w);
    Logic sub(Logic a, Logic b) => (a - b).getRange(0, _w);
    Logic mul(Logic a, Logic b) => (a * b).getRange(0, _w);
    Logic neg(Logic a) => sub(sc(0), a);
    Logic sgn(Logic a) => a[_w - 1];
    Logic asrC(Logic x, int n) =>
        n <= 0 ? x : [x[_w - 1].replicate(n), x.getRange(n, _w)].concat();
    Logic slt(Logic a, Logic b) =>
        mux(sgn(a) ^ sgn(b), sgn(a), sub(a, b)[_w - 1]);
    Logic sle(Logic a, Logic b) => ~slt(b, a);
    Logic lslVar(Logic x, Logic amt) {
      Logic res = x;
      for (var k = 1; k <= 20; k++) {
        res = mux(
          amt.eq(Const(k, width: amt.width)),
          [x.getRange(0, _w - k), Const(0, width: k)].concat(),
          res,
        );
      }
      return res;
    }

    Logic asrVar(Logic x, Logic amt) {
      Logic res = x;
      for (var k = 1; k <= 20; k++) {
        res = mux(amt.eq(Const(k, width: amt.width)), asrC(x, k), res);
      }
      return res;
    }

    // position of MSB (0..31), 0 for x==0. x treated as unsigned magnitude here.
    Logic getMsb(Logic x) {
      Logic r = Const(0, width: 6);
      for (var i = 0; i < _w; i++) {
        r = mux(x[i], Const(i, width: 6), r);
      }
      return r;
    }

    // state
    const sIdle = 0,
        sIsGlobal = 1,
        sType1 = 2,
        sType2 = 3,
        sParamInit = 4,
        sSubIter = 5,
        sSubFinal = 6,
        sQuniStep = 7,
        sQuniStep2 = 8,
        sStore = 9,
        sDone = 10;
    const stW = 4;
    Logic st4(int v) => Const(v, width: stW);

    final st = Logic(name: 'gm_st', width: stW);
    final pos = Logic(name: 'gm_pos', width: offW);
    final gi = Logic(name: 'gm_gi', width: 3); // ref 0..6
    final rType = Logic(name: 'gm_type_r', width: 2);
    final rTarget = Logic(name: 'gm_target', width: 3); // wm index 0..5
    final subI = Logic(name: 'gm_subi', width: 5);
    final subMk = Logic(name: 'gm_submk', width: _w);
    final rRaw = Logic(name: 'gm_raw', width: _w); // subexp result
    final rQv = Logic(name: 'gm_qv', width: _w); // quniform partial

    // per-ref params storage
    final mats = [
      for (var r = 0; r < _numRefs; r++)
        [for (var j = 0; j < 6; j++) Logic(name: 'gm_m${r}_$j', width: _w)],
    ];
    final types = [
      for (var r = 0; r < _numRefs; r++) Logic(name: 'gm_t$r', width: 2),
    ];

    Logic refParam(Logic refIdx, int j) {
      // ref_params[ref*6 + j]
      Logic v = sc(0);
      for (var r = 0; r < _numRefs; r++) {
        v = mux(
          refIdx.eq(Const(r, width: 3)),
          input('ref_params').getRange((r * 6 + j) * 32, (r * 6 + j) * 32 + 32),
          v,
        );
      }
      return v;
    }

    final allowHp = input('allow_high_precision_mv');

    // per-target parameter constants (combinational from rType/target/hp)
    final isTrans = rType.eq(Const(_translation, width: 2));
    // trans bits/decFactor/precDiff
    final transBits = mux(isTrans, mux(allowHp, sc(9), sc(8)), sc(12));
    final transDecFactor = mux(
      isTrans,
      mux(allowHp, sc(1 << 13), sc(1 << 14)),
      sc(1 << 10),
    );
    final transPrecDiff = mux(isTrans, mux(allowHp, sc(13), sc(14)), sc(10));

    // is the current target a trans param (0/1) or alpha param (2..5)?
    final tgtIsTrans = rTarget.lt(Const(2, width: 3));
    // paramN for current target
    final paramN = mux(
      tgtIsTrans,
      add(lslVar(sc(1), transBits.getRange(0, 5)), sc(1)),
      sc(4097),
    );
    final scaledN = sub(add(paramN, paramN), sc(1)); // 2N-1
    // center per target
    Logic centerFor() {
      // alpha diag targets 2,5 -> (refP>>1) - 32768, 3,4 -> refP>>1,
      // trans 0,1 -> refP >> transPrecDiff
      final rp0 = refParam(gi, 0);
      final rp1 = refParam(gi, 1);
      final rp2 = refParam(gi, 2);
      final rp3 = refParam(gi, 3);
      final rp4 = refParam(gi, 4);
      final rp5 = refParam(gi, 5);
      final c2 = sub(asrC(rp2, 1), sc(1 << 15));
      final c3 = asrC(rp3, 1);
      final c4 = asrC(rp4, 1);
      final c5 = sub(asrC(rp5, 1), sc(1 << 15));
      final c0 = asrVar(rp0, transPrecDiff.getRange(0, 5));
      final c1 = asrVar(rp1, transPrecDiff.getRange(0, 5));
      Logic r = c0;
      r = mux(rTarget.eq(Const(1, width: 3)), c1, r);
      r = mux(rTarget.eq(Const(2, width: 3)), c2, r);
      r = mux(rTarget.eq(Const(3, width: 3)), c3, r);
      r = mux(rTarget.eq(Const(4, width: 3)), c4, r);
      r = mux(rTarget.eq(Const(5, width: 3)), c5, r);
      return r;
    }

    final center = centerFor();
    final recRef = add(center, sub(paramN, sc(1))); // ref + N - 1

    // subexp iteration derived values (from subI, subMk, scaledN)
    // b2 = (subI==0)?3 : subI+2
    final b2 = mux(
      subI.eq(Const(0, width: 5)),
      sc(3),
      add(subI.zeroExtend(_w), sc(2)),
    );
    final aVal = lslVar(sc(1), b2.getRange(0, 5));
    // cond: scaledN <= subMk + 3*a
    final subCond = sle(scaledN, add(subMk, mul(sc(3), aVal)));
    // quniform m = scaledN - subMk
    final qm = sub(scaledN, subMk);
    final qmLe1 = sle(qm, sc(1));
    final ql = add(getMsb(qm).zeroExtend(_w), sc(1)); // get_msb(m)+1
    final qExtra = sub(lslVar(sc(1), ql.getRange(0, 5)), qm); // (1<<l)-m
    // qv < extra ?
    final qvLtExtra = slt(rQv, qExtra);

    // reader wiring
    // nSel per state
    final nSel = Logic(name: 'gm_nsel', width: 6);
    Combinational([
      nSel < Const(0, width: 6),
      Case(st, [
        CaseItem(st4(sIsGlobal), [nSel < Const(1, width: 6)]),
        CaseItem(st4(sType1), [nSel < Const(1, width: 6)]),
        CaseItem(st4(sType2), [nSel < Const(1, width: 6)]),
        // sSubIter: read a flag bit only when NOT cond (else 0, go quniform).
        CaseItem(st4(sSubIter), [
          nSel < mux<Logic>(subCond, Const(0, width: 6), Const(1, width: 6)),
        ]),
        CaseItem(st4(sSubFinal), [nSel < b2.getRange(0, 6)]),
        // sQuniStep: read (l-1) bits unless m<=1.
        CaseItem(st4(sQuniStep), [
          nSel < mux(qmLe1, Const(0, width: 6), sub(ql, sc(1)).getRange(0, 6)),
        ]),
        // sQuniStep2: read 1 extra bit unless qv<extra.
        CaseItem(st4(sQuniStep2), [
          nSel < mux<Logic>(qvLtExtra, Const(0, width: 6), Const(1, width: 6)),
        ]),
      ]),
    ]);

    reader.input('bytes').srcConnection! <= input('bytes');
    reader.input('bit_offset').srcConnection! <= pos;
    reader.input('n').srcConnection! <= nSel;
    final rv = reader.output('value');
    final bit0 = rv.getRange(0, 1);
    final nextPos = reader.output('next_offset');
    final rvW = rv; // 32b

    // recenter (combinational, from rRaw + recRef + scaledN)
    // inv_recenter_nonneg(v, r): v>2r? v : (v&1 ? r-((v+1)>>1) : r+(v>>1))
    Logic invRecenterNonneg(Logic v, Logic rr) {
      final twoR = add(rr, rr);
      final odd = v[0];
      final oddV = sub(rr, asrC(add(v, sc(1)), 1));
      final evenV = add(rr, asrC(v, 1));
      return mux(slt(twoR, v), v, mux(odd, oddV, evenV));
    }

    // inv_recenter_finite_nonneg(n, r, v): 2r<=n ? invNonneg(v,r) : n-1-invNonneg(v, n-1-r)
    final twoRec = add(recRef, recRef);
    final branchA = invRecenterNonneg(rRaw, recRef);
    final nm1 = sub(scaledN, sc(1));
    final branchB = sub(nm1, invRecenterNonneg(rRaw, sub(nm1, recRef)));
    final recentered = mux(sle(twoRec, scaledN), branchA, branchB);
    // signed value = recentered - (paramN - 1)
    final decodedValue = sub(recentered, sub(paramN, sc(1)));

    // transform decodedValue -> wm[target]
    // targets 2,5: value*2 + 65536, 3,4: value*2, 0,1: value*transDecFactor
    final alphaScaled = add(mul(decodedValue, sc(2)), sc(1 << 16));
    final betaScaled = mul(decodedValue, sc(2));
    final transScaled = mul(decodedValue, transDecFactor);
    Logic storedVal() {
      Logic r = transScaled; // targets 0,1
      r = mux(rTarget.eq(Const(2, width: 3)), alphaScaled, r);
      r = mux(rTarget.eq(Const(3, width: 3)), betaScaled, r);
      r = mux(rTarget.eq(Const(4, width: 3)), betaScaled, r);
      r = mux(rTarget.eq(Const(5, width: 3)), alphaScaled, r);
      return r;
    }

    // next target sequencing given rType and current rTarget.
    // affine: 2,3,4,5,0,1, rotzoom: 2,3,0,1, translation: 0,1.
    final isAffine = rType.eq(Const(_affine, width: 2));
    // returns (nextTarget, lastFlag)
    Logic nextTarget() {
      Logic nt = Const(0, width: 3);
      // from 2 -> 3
      nt = mux(rTarget.eq(Const(2, width: 3)), Const(3, width: 3), nt);
      // from 3 -> affine?4:0
      nt = mux(
        rTarget.eq(Const(3, width: 3)),
        mux<Logic>(isAffine, Const(4, width: 3), Const(0, width: 3)),
        nt,
      );
      // from 4 -> 5
      nt = mux(rTarget.eq(Const(4, width: 3)), Const(5, width: 3), nt);
      // from 5 -> 0
      nt = mux(rTarget.eq(Const(5, width: 3)), Const(0, width: 3), nt);
      // from 0 -> 1
      nt = mux(rTarget.eq(Const(0, width: 3)), Const(1, width: 3), nt);
      // from 1 -> 1 (terminal, handled by lastFlag)
      nt = mux(rTarget.eq(Const(1, width: 3)), Const(1, width: 3), nt);
      return nt;
    }

    final targetIsLast = rTarget.eq(Const(1, width: 3));
    // after storing target 3 in a non-affine model, set wm4=-wm3, wm5=wm2.
    final setNdiagDefaults = rTarget.eq(Const(3, width: 3)) & ~isAffine;

    // helper to write default identity params for ref gi
    List<Conditional> resetRef(Logic idx) {
      final out = <Conditional>[];
      for (var r = 0; r < _numRefs; r++) {
        out.add(
          If(
            idx.eq(Const(r, width: 3)),
            then: [
              mats[r][0] < sc(0),
              mats[r][1] < sc(0),
              mats[r][2] < sc(1 << 16),
              mats[r][3] < sc(0),
              mats[r][4] < sc(0),
              mats[r][5] < sc(1 << 16),
            ],
          ),
        );
      }
      return out;
    }

    List<Conditional> writeMat(Logic idx, Logic tgt, Logic val) {
      final out = <Conditional>[];
      for (var r = 0; r < _numRefs; r++) {
        for (var j = 0; j < 6; j++) {
          out.add(
            If(
              idx.eq(Const(r, width: 3)) & tgt.eq(Const(j, width: 3)),
              then: [mats[r][j] < val],
            ),
          );
        }
      }
      return out;
    }

    List<Conditional> writePair(Logic idx, int j, Logic val) {
      final out = <Conditional>[];
      for (var r = 0; r < _numRefs; r++) {
        out.add(If(idx.eq(Const(r, width: 3)), then: [mats[r][j] < val]));
      }
      return out;
    }

    Logic readMat(Logic idx, int j) {
      Logic v = sc(0);
      for (var r = 0; r < _numRefs; r++) {
        v = mux(idx.eq(Const(r, width: 3)), mats[r][j], v);
      }
      return v;
    }

    List<Conditional> writeType(Logic idx, Logic val) {
      final out = <Conditional>[];
      for (var r = 0; r < _numRefs; r++) {
        out.add(If(idx.eq(Const(r, width: 3)), then: [types[r] < val]));
      }
      return out;
    }

    Sequential(input('clk'), [
      If(
        input('reset'),
        then: [
          st < st4(sIdle),
          pos < Const(0, width: offW),
          gi < Const(0, width: 3),
          rType < Const(0, width: 2),
          rTarget < Const(0, width: 3),
          subI < Const(0, width: 5),
          subMk < sc(0),
          rRaw < sc(0),
          rQv < sc(0),
          for (var r = 0; r < _numRefs; r++) ...[
            types[r] < Const(0, width: 2),
            mats[r][0] < sc(0),
            mats[r][1] < sc(0),
            mats[r][2] < sc(1 << 16),
            mats[r][3] < sc(0),
            mats[r][4] < sc(0),
            mats[r][5] < sc(1 << 16),
          ],
        ],
        orElse: [
          Case(st, [
            CaseItem(st4(sIdle), [
              If(
                input('start'),
                then: [
                  st < st4(sIsGlobal),
                  pos < input('base_offset'),
                  gi < Const(0, width: 3),
                  for (var r = 0; r < _numRefs; r++) ...[
                    types[r] < Const(0, width: 2),
                    mats[r][0] < sc(0),
                    mats[r][1] < sc(0),
                    mats[r][2] < sc(1 << 16),
                    mats[r][3] < sc(0),
                    mats[r][4] < sc(0),
                    mats[r][5] < sc(1 << 16),
                  ],
                ],
              ),
            ]),
            CaseItem(st4(sIsGlobal), [
              pos < nextPos,
              ...resetRef(gi),
              If(
                bit0,
                then: [st < st4(sType1)],
                orElse: [
                  // identity
                  ...writeType(gi, Const(_identity, width: 2)),
                  If(
                    gi.eq(Const(_numRefs - 1, width: 3)),
                    then: [st < st4(sDone)],
                    orElse: [
                      gi < (gi + Const(1, width: 3)).getRange(0, 3),
                      st < st4(sIsGlobal),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(st4(sType1), [
              pos < nextPos,
              If(
                bit0,
                then: [
                  rType < Const(_rotzoom, width: 2),
                  ...writeType(gi, Const(_rotzoom, width: 2)),
                  rTarget < Const(2, width: 3),
                  st < st4(sParamInit),
                ],
                orElse: [st < st4(sType2)],
              ),
            ]),
            CaseItem(st4(sType2), [
              pos < nextPos,
              // bit==1 -> TRANSLATION, else AFFINE
              If(
                bit0,
                then: [
                  rType < Const(_translation, width: 2),
                  ...writeType(gi, Const(_translation, width: 2)),
                  rTarget < Const(0, width: 3),
                ],
                orElse: [
                  rType < Const(_affine, width: 2),
                  ...writeType(gi, Const(_affine, width: 2)),
                  rTarget < Const(2, width: 3),
                ],
              ),
              st < st4(sParamInit),
            ]),
            CaseItem(st4(sParamInit), [
              subI < Const(0, width: 5),
              subMk < sc(0),
              st < st4(sSubIter),
            ]),
            CaseItem(st4(sSubIter), [
              If(
                subCond,
                then: [
                  // no read, go to quniform
                  st < st4(sQuniStep),
                ],
                orElse: [
                  pos < nextPos,
                  If(
                    bit0,
                    then: [
                      // flag==1: mk += a, i++
                      subMk < add(subMk, aVal),
                      subI < (subI + Const(1, width: 5)).getRange(0, 5),
                      st < st4(sSubIter),
                    ],
                    orElse: [
                      // flag==0: read b2 bits next
                      st < st4(sSubFinal),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(st4(sSubFinal), [
              pos < nextPos,
              rRaw < add(rvW, subMk),
              st < st4(sStore),
            ]),
            CaseItem(st4(sQuniStep), [
              If(
                qmLe1,
                then: [rRaw < subMk, st < st4(sStore)],
                orElse: [pos < nextPos, rQv < rvW, st < st4(sQuniStep2)],
              ),
            ]),
            CaseItem(st4(sQuniStep2), [
              If(
                qvLtExtra,
                then: [rRaw < add(rQv, subMk), st < st4(sStore)],
                orElse: [
                  pos < nextPos,
                  // q = (qv<<1) - extra + bit
                  rRaw <
                      add(
                        add(sub(mul(rQv, sc(2)), qExtra), bit0.zeroExtend(_w)),
                        subMk,
                      ),
                  st < st4(sStore),
                ],
              ),
            ]),
            CaseItem(st4(sStore), [
              // write the decoded param
              ...writeMat(gi, rTarget, storedVal()),
              // non-affine ndiag defaults after target 3
              If(
                setNdiagDefaults,
                then: [
                  ...writePair(gi, 4, neg(betaScaled)), // wm4 = -wm3(new)
                  ...writePair(
                    gi,
                    5,
                    readMat(gi, 2),
                  ), // wm5 = wm2 (already stored)
                ],
              ),
              If(
                targetIsLast,
                then: [
                  // finished this ref
                  If(
                    gi.eq(Const(_numRefs - 1, width: 3)),
                    then: [st < st4(sDone)],
                    orElse: [
                      gi < (gi + Const(1, width: 3)).getRange(0, 3),
                      st < st4(sIsGlobal),
                    ],
                  ),
                ],
                orElse: [
                  rTarget < nextTarget(),
                  subI < Const(0, width: 5),
                  subMk < sc(0),
                  st < st4(sSubIter),
                ],
              ),
            ]),
            CaseItem(st4(sDone), []),
          ]),
        ],
      ),
    ]);

    output('done') <= st.eq(st4(sDone));
    output('bits_consumed') <= pos;
    for (var r = 0; r < _numRefs; r++) {
      output('gm_type_$r') <= types[r];
      for (var j = 0; j < 6; j++) {
        output('mat_${r}_$j') <= mats[r][j];
      }
    }
  }
}
