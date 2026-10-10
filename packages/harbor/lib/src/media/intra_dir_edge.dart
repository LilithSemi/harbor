import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 directional intra prediction WITH runtime angle_delta,
/// the intra EDGE FILTER, the corner filter and edge UPSAMPLE (bd 8). This is
/// the composition [HarborIntraDirAngle] was missing: a faithful port of
/// libaom's `av1_predict_intra_block` directional branch
/// (`build_intra_predictors` -> corner filter -> `av1_filter_intra_edge` ->
/// `av1_upsample_intra_edge` -> `dr_predictor` z1/z2/z3), for a
/// FULLY-AVAILABLE interior block (`nTopPx == bs`, `nLeftPx == bs`, extension
/// pixels supplied by the caller with libaom's replication / real-neighbour
/// semantics, corner == cornerSrc).
///
/// The prediction angle is `mode_to_angle[mode] + angle_delta*ANGLE_STEP(3)`.
/// The edge filter strength and the upsample decision are derived at RUNTIME
/// from the angle (they depend only on `|pAngle-90|` / `|pAngle-180|` and the
/// build-time block dimensions), so the whole path is one combinational block.
///
/// Ports mirror [HarborIntraDirAngle] plus the two sequence-header-ish controls:
///   `mode` (4b, 1..8), `angle_delta` (4b signed two's complement, -3..3),
///   `above` / `left` (2*bs pixels, 8b, the constructed reference incl. the
///   `bs`-pixel extension), `corner` (8b, above_row[-1]),
///   `enable_edge_filter` (1b, the seq-header flag, 0 => pure dr_predictor),
///   `filter_type` (1b, `intra_edge_filter_type`: 0 luma / 1 smooth-neighbour)
///   -> `pred` (bs*bs, 8b, pixel (r,c) at `[(r*bs+c)*8 +: 8]`). Combinational.
class HarborIntraDirEdge extends BridgeModule {
  /// Block size (square): 4, 8 or 16. Upsample only ever fires for bs <= 8
  /// (blkWh = 2*bs <= 16 luma / <= 8 chroma), so bs=16 stays cheap.
  final int bs;

  static const _modeToAngle = [0, 90, 180, 45, 135, 113, 157, 203, 67];
  static const _drDeriv = [
    0, 0, 0, 1023, 0, 0, 547, 0, 0, 372, 0, 0, 0, 0, 273, 0, 0, 215, 0, 0, //
    178, 0, 0, 151, 0, 0, 132, 0, 0, 116, 0, 0, 102, 0, 0, 0, 90, 0, 0, 80, //
    0, 0, 71, 0, 0, 64, 0, 0, 57, 0, 0, 51, 0, 0, 45, 0, 0, 0, 40, 0, 0, 35, //
    0, 0, 31, 0, 0, 27, 0, 0, 23, 0, 0, 19, 0, 0, 15, 0, 0, 0, 0, 11, 0, 0, //
    7, 0, 0, 3, 0, 0,
  ];

  HarborIntraDirEdge({required this.bs, String? name})
    : assert(bs == 4 || bs == 8 || bs == 16, 'bs 4/8/16'),
      super('HarborIntraDirEdge_S$bs', name: name ?? 'intra_dir_edge_$bs') {
    createPort('mode', PortDirection.input, width: 4);
    createPort('angle_delta', PortDirection.input, width: 4);
    createPort('above', PortDirection.input, width: 2 * bs * 8);
    createPort('left', PortDirection.input, width: 2 * bs * 8);
    createPort('corner', PortDirection.input, width: 8);
    createPort('enable_edge_filter', PortDirection.input);
    createPort('filter_type', PortDirection.input);
    addOutput('pred', width: bs * bs * 8);

    final mode = input('mode');
    final angleDelta = input('angle_delta');
    final enFilt = input('enable_edge_filter');
    final filterType = input('filter_type');
    Logic aSrc(int j) => input('above').getRange(j * 8, j * 8 + 8);
    Logic lSrc(int j) => input('left').getRange(j * 8, j * 8 + 8);
    final corner = input('corner');

    // angle
    Logic romSel(List<int> table, Logic idx, int wd) {
      Logic v = Const(table.last, width: wd);
      for (var i = table.length - 2; i >= 0; i--) {
        v = mux(
          idx.eq(Const(i, width: idx.width)),
          Const(table[i], width: wd),
          v,
        );
      }
      return v;
    }

    final baseAngle = romSel(_modeToAngle, mode, 9);
    final deltaS = angleDelta.signExtend(9);
    final delta3 = (deltaS * Const(3, width: 9)).getRange(0, 9);
    final angle = (baseAngle.zeroExtend(10) + delta3.signExtend(10)).getRange(
      0,
      10,
    );
    Logic angEq(int a) => angle.eq(Const(a, width: 10));
    Logic angLt(int a) => angle.lt(Const(a, width: 10));
    Logic angGt(int a) => angle.gt(Const(a, width: 10));
    final isZ1 = angGt(0) & angLt(90);
    final isZ2 = angGt(90) & angLt(180);
    final isZ3 = angGt(180) & angLt(270);
    final isV = angEq(90);
    final isH = angEq(180);

    // need flags for a directional mode (SW _build, dr branch):
    // pAngle <= 90 : needAbove, !needLeft. 90<pAngle<180 : both.
    // pAngle >= 180: !needAbove, needLeft.
    final needAbove =
        angle.lte(Const(90, width: 10)) | (angGt(90) & angLt(180));
    final needLeft = angGt(90); // pAngle > 90 (z2 or z3)
    final needRight = angLt(90); // pAngle < 90
    final needBottom = angGt(180); // pAngle > 180
    // corner/edge filter only for pAngle != 90 && pAngle != 180.
    final notCard = ~isV & ~isH;
    final doFilter = enFilt & notCard;

    // dx / dy from dr_intra_derivative.
    final dxIdx = mux(
      isZ1,
      angle.getRange(0, 8),
      (Const(180, width: 9) - angle.getRange(0, 9)).getRange(0, 8),
    );
    final dyIdx = mux(
      isZ2,
      (angle.getRange(0, 9) - Const(90, width: 9)).getRange(0, 8),
      (Const(270, width: 10) - angle).getRange(0, 8),
    );
    final dx = mux(
      isZ1 | isZ2,
      romSel(_drDeriv, dxIdx, 11),
      Const(1, width: 11),
    );
    final dy = mux(
      isZ2 | isZ3,
      romSel(_drDeriv, dyIdx, 11),
      Const(1, width: 11),
    );

    // |pAngle-90| and |pAngle-180| for strength / upsample decisions.
    Logic absDelta(int cardinal) {
      final d = (angle.zeroExtend(11) - Const(cardinal, width: 11)).getRange(
        0,
        11,
      );
      final neg = d[10];
      return mux(
        neg,
        (Const(0, width: 11) - d).getRange(0, 11),
        d,
      ).getRange(0, 8);
    }

    final adAbove = absDelta(90); // for above edge / upsample
    final adLeft = absDelta(180); // for left edge / upsample

    // hw port of intra_edge_filter_strength(bs,bs,delta,type) -> 2b.
    Logic strengthOf(Logic ad) {
      final blkWh = 2 * bs;
      Logic ge(int t) => ad.gte(Const(t, width: 8));
      // returns strength for type0 and type1, muxed by filter_type.
      int s0Max = 3, s1Max = 3;
      // Build type0.
      Logic t0;
      if (blkWh <= 8) {
        t0 = mux(ge(56), Const(1, width: 2), Const(0, width: 2));
        s0Max = 1;
      } else if (blkWh <= 16) {
        t0 = mux(ge(40), Const(1, width: 2), Const(0, width: 2));
        s0Max = 1;
      } else if (blkWh <= 24) {
        t0 = mux(
          ge(32),
          Const(3, width: 2),
          mux(
            ge(16),
            Const(2, width: 2),
            mux(ge(8), Const(1, width: 2), Const(0, width: 2)),
          ),
        );
      } else if (blkWh <= 32) {
        t0 = mux(
          ge(32),
          Const(3, width: 2),
          mux(
            ge(4),
            Const(2, width: 2),
            mux(ge(1), Const(1, width: 2), Const(0, width: 2)),
          ),
        );
      } else {
        t0 = mux(ge(1), Const(3, width: 2), Const(0, width: 2));
      }
      // Build type1.
      Logic t1;
      if (blkWh <= 8) {
        t1 = mux(
          ge(64),
          Const(2, width: 2),
          mux(ge(40), Const(1, width: 2), Const(0, width: 2)),
        );
        s1Max = 2;
      } else if (blkWh <= 16) {
        t1 = mux(
          ge(48),
          Const(2, width: 2),
          mux(ge(20), Const(1, width: 2), Const(0, width: 2)),
        );
        s1Max = 2;
      } else if (blkWh <= 24) {
        t1 = mux(ge(4), Const(3, width: 2), Const(0, width: 2));
      } else {
        t1 = mux(ge(1), Const(3, width: 2), Const(0, width: 2));
      }
      assert(s0Max <= 3 && s1Max <= 3);
      return mux(filterType, t1, t0);
    }

    // hw port of use_intra_edge_upsample(bs,bs,delta,type) -> 1b.
    Logic upsampleOf(Logic ad) {
      final blkWh = 2 * bs;
      final nz = ad.neq(Const(0, width: 8));
      final lt40 = ad.lt(Const(40, width: 8));
      // type0 => blkWh<=16. type1 => blkWh<=8.
      final t0ok = blkWh <= 16;
      final t1ok = blkWh <= 8;
      final okConst = mux(filterType, Const(t1ok ? 1 : 0), Const(t0ok ? 1 : 0));
      return nz & lt40 & okConst;
    }

    final strAbove = strengthOf(adAbove);
    final strLeft = strengthOf(adLeft);
    final upAbove = doFilter & (needAbove) & upsampleOf(adAbove);
    final upLeft = doFilter & (needLeft) & upsampleOf(adLeft);

    // reference buffers (SW index space, off=16)
    const off = 16;
    const n = 80;
    // above[off+i] = aSrc[i] (i in 0..2bs-1). above[off-1] = corner.
    final a0 = List<Logic>.generate(n, (j) {
      if (j == off - 1) return corner;
      if (j >= off && j < off + 2 * bs) return aSrc(j - off);
      return Const(127, width: 8); // _bdBase-1 padding
    });
    final l0 = List<Logic>.generate(n, (j) {
      if (j == off - 1) return corner;
      if (j >= off && j < off + 2 * bs) return lSrc(j - off);
      return Const(129, width: 8); // _bdBase+1 padding
    });

    // corner filter (needAbove && needLeft && 2bs>=24 && notCard)
    // s = left[off]*5 + above[off-1]*6 + above[off]*5. (s+8)>>4.
    final doCorner =
        doFilter & needAbove & needLeft & Const(2 * bs >= 24 ? 1 : 0);
    final cs =
        (l0[off].zeroExtend(16) * Const(5, width: 16) +
                a0[off - 1].zeroExtend(16) * Const(6, width: 16) +
                a0[off].zeroExtend(16) * Const(5, width: 16))
            .getRange(0, 16);
    final cornerFilt = ((cs + Const(8, width: 16)).getRange(0, 16) >>> 4)
        .getRange(0, 8);
    final a1 = [...a0];
    final l1 = [...l0];
    a1[off - 1] = mux(doCorner, cornerFilt, a0[off - 1]);
    l1[off - 1] = mux(doCorner, cornerFilt, l0[off - 1]);

    // edge filter: 5-tap, runtime strength, runtime length (needRight/
    // needBottom pick szShort/szLong). Sample 0 (the corner) copied.
    List<Logic> edgeFilter(
      List<Logic> buf,
      int startIdx,
      int sz,
      Logic strength,
    ) {
      const kernels = [
        [0, 4, 8, 4, 0],
        [0, 5, 6, 5, 0],
        [2, 4, 4, 4, 2],
      ];
      final out = List<Logic>.filled(sz, Const(0, width: 8));
      out[0] = buf[startIdx];
      for (var i = 1; i < sz; i++) {
        final filtered = <Logic>[];
        for (final k in kernels) {
          Logic acc = Const(0, width: 16);
          for (var j = 0; j < 5; j++) {
            if (k[j] == 0) continue;
            var idx = i - 2 + j;
            if (idx < 0) idx = 0;
            if (idx > sz - 1) idx = sz - 1;
            acc =
                (acc +
                        (buf[startIdx + idx].zeroExtend(16) *
                                Const(k[j], width: 16))
                            .getRange(0, 16))
                    .getRange(0, 16);
          }
          filtered.add(
            ((acc + Const(8, width: 16)).getRange(0, 16) >>> 4).getRange(0, 8),
          );
        }
        out[i] = mux(
          strength.eq(Const(0, width: 2)),
          buf[startIdx + i],
          mux(
            strength.eq(Const(1, width: 2)),
            filtered[0],
            mux(strength.eq(Const(2, width: 2)), filtered[1], filtered[2]),
          ),
        );
      }
      return out;
    }

    // above edge filter over aboveRow[off-1 ..], nPx = bs+1 (+bs if needRight).
    final szAshort = bs + 1;
    final szAlong = 2 * bs + 1;
    final aShort = edgeFilter(a1, off - 1, szAshort, strAbove);
    final aLong = edgeFilter(a1, off - 1, szAlong, strAbove);
    final applyA = doFilter & needAbove;
    final a2 = [...a1];
    for (var i = 1; i < szAlong; i++) {
      final idx = off - 1 + i;
      final short = i < szAshort ? aShort[i] : a1[idx];
      final filtered = mux(needRight, aLong[i], short);
      a2[idx] = mux(applyA, filtered, a1[idx]);
    }

    // left edge filter over leftCol[off-1 ..], nPx = bs+1 (+bs if needBottom).
    final szLshort = bs + 1;
    final szLlong = 2 * bs + 1;
    final lShort = edgeFilter(l1, off - 1, szLshort, strLeft);
    final lLong = edgeFilter(l1, off - 1, szLlong, strLeft);
    final applyL = doFilter & needLeft;
    final l2 = [...l1];
    for (var i = 1; i < szLlong; i++) {
      final idx = off - 1 + i;
      final short = i < szLshort ? lShort[i] : l1[idx];
      final filtered = mux(needBottom, lLong[i], short);
      l2[idx] = mux(applyL, filtered, l1[idx]);
    }

    // upsample (bs <= 8 only). Produces a buffer where above[off+k] is the
    // upsampled sample k for k in [-2 .. 2*szUp-2].
    List<Logic> upsample(List<Logic> buf, int sz) {
      // in[0]=in[1]=buf[off-1]. in[i+2]=buf[off+i] i in 0..sz-1. in[sz+2]=buf[off+sz-1]
      Logic inp(int m) {
        if (m <= 1) return buf[off - 1];
        if (m <= sz + 1) return buf[off + (m - 2)];
        return buf[off + sz - 1];
      }

      final out = [...buf];
      out[off - 2] = inp(0);
      for (var i = 0; i < sz; i++) {
        final a = inp(i).zeroExtend(16);
        final b = inp(i + 1).zeroExtend(16);
        final c = inp(i + 2).zeroExtend(16);
        final d = inp(i + 3).zeroExtend(16);
        final s =
            ((b * Const(9, width: 16)).getRange(0, 16) +
                    (c * Const(9, width: 16)).getRange(0, 16) -
                    a -
                    d)
                .getRange(0, 16);
        final biased = (s + Const(8, width: 16)).getRange(0, 16);
        final shifted = [
          biased[15].replicate(4),
          biased.getRange(4, 16),
        ].swizzle();
        final neg = shifted[15];
        final gt255 = shifted.gt(Const(255, width: 16));
        final clipped = mux(
          neg,
          Const(0, width: 16),
          mux(gt255, Const(255, width: 16), shifted),
        ).getRange(0, 8);
        out[off + 2 * i - 1] = clipped;
        out[off + 2 * i] = inp(i + 2);
      }
      return out;
    }

    // The upsampled buffers (only built for bs<=8). SW upsample length is
    // txw + (needRight?txh:0) for above and txh + (needBottom?txw:0) for left,
    // so mux the short (sz=bs) and long (sz=2bs) variants by needRight/needBottom.
    List<Logic> aboveUp, leftUp;
    if (bs <= 8) {
      final aUpS = upsample(a2, bs);
      final aUpL = upsample(a2, 2 * bs);
      final lUpS = upsample(l2, bs);
      final lUpL = upsample(l2, 2 * bs);
      aboveUp = [for (var j = 0; j < n; j++) mux(needRight, aUpL[j], aUpS[j])];
      leftUp = [for (var j = 0; j < n; j++) mux(needBottom, lUpL[j], lUpS[j])];
    } else {
      aboveUp = a2;
      leftUp = l2;
    }

    // dr_predictor. Build for (ua,ul) combos, mux by upAbove/upLeft.
    // interp: round((32-shift)*a0 + shift*a1, 5), shift 0..31.
    Logic interp(Logic p0, Logic p1, Logic shift) {
      final s = shift.zeroExtend(6);
      final inv = (Const(32, width: 6) - s).getRange(0, 6);
      final t0 = (p0.zeroExtend(15) * inv.zeroExtend(15)).getRange(0, 15);
      final t1 = (p1.zeroExtend(15) * s.zeroExtend(15)).getRange(0, 15);
      final sum = (t0 + t1).getRange(0, 15);
      return (sum + Const(16, width: 15)).getRange(5, 13);
    }

    const w = 20; // signed working width
    // buffer reader with runtime signed index (SW absolute off+base). Covers
    // the used window. Outside -> nearest padding default.
    Logic reader(List<Logic> buf, Logic absIdx, int lo, int hi) {
      Logic v = buf[hi];
      for (var j = hi - 1; j >= lo; j--) {
        v = mux(absIdx.eq(Const(j, width: absIdx.width)), buf[j], v);
      }
      return v;
    }

    // Build the z1/z2/z3 prediction for a given (ua, ul) pair over the chosen
    // above/left buffers. Returns row-major bs*bs list of 8b Logic.
    List<Logic> drCore(
      List<Logic> aboveBuf,
      List<Logic> leftBuf,
      int ua,
      int ul,
    ) {
      final maxBaseX = (2 * bs - 1) << ua;
      final maxBaseY = (2 * bs - 1) << ul;
      final fracX = 6 - ua;
      final fracY = 6 - ul;
      final baseIncX = 1 << ua;
      final baseIncY = 1 << ul;
      final minBaseX = -(1 << ua);
      // index windows (absolute) for the readers.
      final aLo = off - 2, aHi = off + maxBaseX + 1;
      final lLo = off - 2, lHi = off + maxBaseY + 1;
      Logic aAt(Logic absIdx) => reader(aboveBuf, absIdx, aLo, aHi);
      Logic lAt(Logic absIdx) => reader(leftBuf, absIdx, lLo, lHi);

      final out = List<Logic>.filled(bs * bs, Const(0, width: 8));
      for (var r = 0; r < bs; r++) {
        for (var c = 0; c < bs; c++) {
          // z1: x=(r+1)*dx. base=(x>>fracX). shift=((x<<ua)&63)>>1. base+=c*baseIncX
          final xz1 = (Const((r + 1), width: 18) * dx.zeroExtend(18)).getRange(
            0,
            18,
          );
          final baseZ1 =
              (xz1.getRange(fracX, 18).zeroExtend(13) +
                      Const(c * baseIncX, width: 13))
                  .getRange(0, 12);
          final xShL1 = (xz1 << ua).getRange(0, 18);
          final shZ1 = xShL1.getRange(1, 6);
          final z1idx = (Const(off, width: 12) + baseZ1).getRange(0, 12);
          final z1v = mux(
            baseZ1.lt(Const(maxBaseX, width: 12)),
            interp(
              aAt(z1idx),
              aAt((z1idx + Const(1, width: 12)).getRange(0, 12)),
              shZ1,
            ),
            aAt(Const(off + maxBaseX, width: 12)),
          );

          // z3: y=(c+1)*dy. base=(y>>fracY). shift. base += r*baseIncY
          final yz3 = (Const((c + 1), width: 18) * dy.zeroExtend(18)).getRange(
            0,
            18,
          );
          final baseZ3 =
              (yz3.getRange(fracY, 18).zeroExtend(13) +
                      Const(r * baseIncY, width: 13))
                  .getRange(0, 12);
          final yShL3 = (yz3 << ul).getRange(0, 18);
          final shZ3 = yShL3.getRange(1, 6);
          final z3idx = (Const(off, width: 12) + baseZ3).getRange(0, 12);
          final z3v = mux(
            baseZ3.lt(Const(maxBaseY, width: 12)),
            interp(
              lAt(z3idx),
              lAt((z3idx + Const(1, width: 12)).getRange(0, 12)),
              shZ3,
            ),
            lAt(Const(off + maxBaseY, width: 12)),
          );

          // z2: y=r+1. x=(c<<6)-y*dx. baseX=x>>fracX. if baseX>=minBaseX above
          // else x=c+1. y=(r<<6)-x*dy. baseY=y>>fracY. left.
          final xz2 =
              (Const(c << 6, width: w) -
                      (Const((r + 1), width: w) * dx.zeroExtend(w)).getRange(
                        0,
                        w,
                      ))
                  .getRange(0, w);
          final baseX = [
            xz2[w - 1].replicate(fracX),
            xz2.getRange(fracX, w),
          ].swizzle().getRange(0, w);
          final xShL2 = (xz2 << ua).getRange(0, w);
          final shX = xShL2.getRange(1, 6);
          // baseX >= minBaseX (minBaseX < 0) <=> (baseX - minBaseX) >= 0.
          final geMin = ~((baseX - Const(minBaseX, width: w)).getRange(
            0,
            w,
          ))[w - 1];
          final z2aIdx = (Const(off, width: w) + baseX).getRange(0, 12);
          final z2above = interp(
            aAt(z2aIdx),
            aAt((z2aIdx + Const(1, width: 12)).getRange(0, 12)),
            shX,
          );
          final yz2 =
              (Const(r << 6, width: w) -
                      (Const((c + 1), width: w) * dy.zeroExtend(w)).getRange(
                        0,
                        w,
                      ))
                  .getRange(0, w);
          final baseY = [
            yz2[w - 1].replicate(fracY),
            yz2.getRange(fracY, w),
          ].swizzle().getRange(0, w);
          final yShL2 = (yz2 << ul).getRange(0, w);
          final shY = yShL2.getRange(1, 6);
          final z2lIdx = (Const(off, width: w) + baseY).getRange(0, 12);
          final z2left = interp(
            lAt(z2lIdx),
            lAt((z2lIdx + Const(1, width: 12)).getRange(0, 12)),
            shY,
          );
          final z2v = mux(geMin, z2above, z2left);

          final vV = aAt(Const(off + c, width: 12)); // V predictor
          final hV = lAt(Const(off + r, width: 12)); // H predictor
          out[r * bs + c] = mux(
            isZ1,
            z1v,
            mux(isZ2, z2v, mux(isZ3, z3v, mux(isV, vV, hV))),
          );
        }
      }
      return out;
    }

    // Base (no-upsample) prediction always exists.
    final pred00 = drCore(a2, l2, 0, 0);
    List<Logic> finalPred;
    if (bs <= 8) {
      final pred10 = drCore(aboveUp, l2, 1, 0);
      final pred01 = drCore(a2, leftUp, 0, 1);
      final pred11 = drCore(aboveUp, leftUp, 1, 1);
      finalPred = [
        for (var i = 0; i < bs * bs; i++)
          mux(
            upAbove,
            mux(upLeft, pred11[i], pred10[i]),
            mux(upLeft, pred01[i], pred00[i]),
          ),
      ];
    } else {
      finalPred = pred00;
    }

    output('pred') <=
        [for (var i = bs * bs - 1; i >= 0; i--) finalPred[i]].swizzle();
  }
}
