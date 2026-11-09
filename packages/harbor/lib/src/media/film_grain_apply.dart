import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// AV1 film-grain apply engine (the `add_noise` process). Adds the synthesized
/// grain templates to the reconstructed display planes.
///
/// Clocked, single-pixel-per-cycle raster datapath. Per output pixel it forms
/// the grain sample from the template at the block's pseudo-random offset,
/// applies the AV1 grain-block OVERLAP blend at the 2-pixel block seams
/// (closed form: column overlap then row overlap, with the corner double
/// blended), looks up the piecewise-linear scaling factor (luma by pixel value,
/// chroma by the luma-average / cross-multiply index), and adds
/// `round2(scaling * grain, scaling_shift)` with the video/full-range clip.
///
/// Structural parameters baked at elaboration (profile/header/geometry
/// constants): frame `w`/`h`, `ssx`/`ssy`, `bd`, `overlap`, which chroma planes
/// are applied and chroma-from-luma, and the restricted-range clip. Runtime
/// ports: the grain seed, `scaling_shift`, the effective chroma
/// mult/luma-mult/offset triples, the three 256-entry scaling LUTs, the grain
/// templates and the reconstructed planes.
///
/// Template buses are in natural position order (position `c` at bits
/// `[c*grainW, c*grainW+grainW)`, row major with the template stride). Recon and
/// output pixel buses are natural position order, [pxW] bits per sample. Output
/// samples are emitted in shift-register slot order (position `c` of a plane of
/// size `n` at slot `n-1-c`), callers reverse.
class HarborFilmGrainApply extends BridgeModule {
  final int w, h, ssx, ssy, bd;
  final bool overlap, genCb, genCr, chromaFromLuma, clipRestricted;

  /// Signed width of a stored grain sample (matches HarborFilmGrainSynth).
  static const int grainW = 16;

  /// Unsigned width of a pixel sample (covers bd 8/10/12).
  static const int pxW = 16;

  late final int cw, ch;
  late final int lumaStride, chromaStride, nLuma, nChroma;
  late final int nLumaPx, nChromaPx;
  late final int blocksY, blocksX;

  HarborFilmGrainApply({
    this.w = 64,
    this.h = 64,
    this.ssx = 1,
    this.ssy = 1,
    this.bd = 8,
    this.overlap = false,
    this.genCb = true,
    this.genCr = true,
    this.chromaFromLuma = false,
    this.clipRestricted = false,
    String? name,
  }) : super('HarborFilmGrainApply', name: name ?? 'film_grain_apply') {
    const leftPad = 3, rightPad = 3, topPad = 3, bottomPad = 0, arPadding = 3;
    const lumaSubY = 32, lumaSubX = 32;
    final chromaSubY = lumaSubY >> ssy, chromaSubX = lumaSubX >> ssx;
    final lumaBlockY = topPad + 2 * arPadding + lumaSubY * 2 + bottomPad;
    lumaStride =
        leftPad + 2 * arPadding + lumaSubX * 2 + 2 * arPadding + rightPad;
    final chromaBlockY =
        topPad + (2 >> ssy) * arPadding + chromaSubY * 2 + bottomPad;
    chromaStride =
        leftPad +
        (2 >> ssx) * arPadding +
        chromaSubX * 2 +
        (2 >> ssx) * arPadding +
        rightPad;
    nLuma = lumaBlockY * lumaStride;
    nChroma = chromaBlockY * chromaStride;
    cw = (w + ssx) >> ssx;
    ch = (h + ssy) >> ssy;
    nLumaPx = w * h;
    nChromaPx = cw * ch;
    blocksY = ((h ~/ 2) + 15) ~/ 16;
    blocksX = ((w ~/ 2) + 15) ~/ 16;

    final grainCenter = 128 << (bd - 8);
    final grainMin = 0 - grainCenter, grainMax = grainCenter - 1;
    final chromaClampHi = (256 << (bd - 8)) - 1;
    final applyCb = genCb || chromaFromLuma;
    final applyCr = genCr || chromaFromLuma;
    int minL, maxL, minC, maxC;
    if (clipRestricted) {
      minL = 16 << (bd - 8);
      maxL = 235 << (bd - 8);
      minC = 16 << (bd - 8);
      maxC = 240 << (bd - 8);
    } else {
      minL = 0;
      maxL = (256 << (bd - 8)) - 1;
      minC = 0;
      maxC = maxL;
    }

    // ports
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('seed', PortDirection.input, width: 16);
    createPort('scaling_shift', PortDirection.input, width: 4);
    createPort('cb_luma_mult', PortDirection.input, width: 16);
    createPort('cb_mult', PortDirection.input, width: 16);
    createPort('cb_offset', PortDirection.input, width: 32);
    createPort('cr_luma_mult', PortDirection.input, width: 16);
    createPort('cr_mult', PortDirection.input, width: 16);
    createPort('cr_offset', PortDirection.input, width: 32);
    createPort('lut_y', PortDirection.input, width: 256 * 16);
    createPort('lut_cb', PortDirection.input, width: 256 * 16);
    createPort('lut_cr', PortDirection.input, width: 256 * 16);
    createPort('tmpl_y', PortDirection.input, width: nLuma * grainW);
    createPort('tmpl_cb', PortDirection.input, width: nChroma * grainW);
    createPort('tmpl_cr', PortDirection.input, width: nChroma * grainW);
    createPort('recon_y', PortDirection.input, width: nLumaPx * pxW);
    createPort('recon_cb', PortDirection.input, width: nChromaPx * pxW);
    createPort('recon_cr', PortDirection.input, width: nChromaPx * pxW);
    addOutput('out_y', width: nLumaPx * pxW);
    addOutput('out_cb', width: nChromaPx * pxW);
    addOutput('out_cr', width: nChromaPx * pxW);
    addOutput('done');

    final clk = input('clk');
    final reset = input('reset');
    final start = input('start');
    final seed = input('seed');
    final scalingShift = input('scaling_shift');
    final cbLumaMult = input('cb_luma_mult');
    final cbMult = input('cb_mult');
    final cbOffset = input('cb_offset');
    final crLumaMult = input('cr_luma_mult');
    final crMult = input('cr_mult');
    final crOffset = input('cr_offset');
    final lutY = input('lut_y');
    final lutCb = input('lut_cb');
    final lutCr = input('lut_cr');
    final tmplY = input('tmpl_y');
    final tmplCb = input('tmpl_cb');
    final tmplCr = input('tmpl_cr');
    final reconY = input('recon_y');
    final reconCb = input('recon_cb');
    final reconCr = input('recon_cr');

    // helpers
    Logic treeMux(Logic sel, List<Logic> vals) {
      final vw = vals.first.width;
      var level = List<Logic>.from(vals);
      var pow2 = 1;
      while (pow2 < level.length) {
        pow2 <<= 1;
      }
      while (level.length < pow2) {
        level.add(Const(0, width: vw));
      }
      var bit = 0;
      while (level.length > 1) {
        final next = <Logic>[];
        for (var i = 0; i < level.length; i += 2) {
          next.add(mux(sel[bit], level[i + 1], level[i]));
        }
        level = next;
        bit++;
      }
      return level[0];
    }

    // Arithmetic right shift of signed [x] (width vw) by runtime [sh] (0..15).
    Logic asr(Logic x, int vw, Logic sh) {
      Logic build(int k) {
        if (k == 0) return x;
        if (k >= vw) return x[vw - 1].replicate(vw);
        return [x[vw - 1].replicate(k), x.getRange(k, vw)].concat();
      }

      Logic v = build(0);
      for (var k = 1; k <= 15; k++) {
        v = mux(sh.eq(Const(k, width: 4)), build(k), v);
      }
      return v;
    }

    // Signed clamp of 32b [x] to [lo,hi] (small operands, no overflow).
    Logic clampS(Logic x, int lo, int hi) {
      final loC = Const(lo & 0xFFFFFFFF, width: 32);
      final hiC = Const(hi & 0xFFFFFFFF, width: 32);
      final xLt = (x - loC).getRange(31, 32);
      final c1 = mux(xLt, loC, x);
      final gt = (hiC - c1).getRange(31, 32);
      return mux(gt, hiC, c1);
    }

    Logic grainSlice(Logic bus, Logic pos, int n) => treeMux(pos, [
      for (var p = 0; p < n; p++) bus.getRange(p * grainW, p * grainW + grainW),
    ]);
    Logic pxSlice(Logic bus, Logic pos, int n) => treeMux(pos, [
      for (var p = 0; p < n; p++) bus.getRange(p * pxW, p * pxW + pxW),
    ]);
    Logic lutSlice(Logic bus, Logic idx) => treeMux(idx, [
      for (var p = 0; p < 256; p++) bus.getRange(p * 16, p * 16 + 16),
    ]);

    // block offsets (combinational from seed)
    List<Logic> lfsrStep(Logic r) {
      final b = r[0] ^ r[1] ^ r[3] ^ r[12];
      final next = [b, r.getRange(1, 16)].concat();
      return [next];
    }

    int initConst(int by) {
      final ln = by; // lumaLine = by*16*2 = 32*by ; lumaNum = 32by>>5 = by
      final hi = ((ln * 37 + 178) & 255) << 8;
      final lo = (ln * 173 + 105) & 255;
      return (hi ^ lo) & 0xffff;
    }

    // offY[by][bx], offX[by][bx] as 4-bit Logics.
    final offY = List.generate(blocksY, (_) => <Logic>[]);
    final offX = List.generate(blocksY, (_) => <Logic>[]);
    for (var by = 0; by < blocksY; by++) {
      var r = seed ^ Const(initConst(by), width: 16);
      for (var bx = 0; bx < blocksX; bx++) {
        final nr = lfsrStep(r)[0];
        offY[by].add(nr.getRange(8, 12)); // (nr>>8)&15
        offX[by].add(nr.getRange(12, 16)); // (nr>>12)&15
        r = nr;
      }
    }

    // Select an offset for a runtime (by,bx) index.
    Logic selOff(List<List<Logic>> off, Logic by, Logic bx) {
      Logic v = off[0][0];
      for (var iy = 0; iy < blocksY; iy++) {
        for (var ix = 0; ix < blocksX; ix++) {
          v = mux(
            by.eq(Const(iy, width: by.width)) &
                bx.eq(Const(ix, width: bx.width)),
            off[iy][ix],
            v,
          );
        }
      }
      return v;
    }

    // Overlap blend helpers (a = neighbour/above, b = current).
    Logic blend2(Logic a, Logic b, Logic pos0) {
      // pos0=1 => weight (27a+17b). Else (17a+27b). Then >>5, clamp grain range.
      final aw = mux<Logic>(pos0, Const(27, width: 32), Const(17, width: 32));
      final bw = mux<Logic>(pos0, Const(17, width: 32), Const(27, width: 32));
      final s =
          (aw * a.signExtend(32) + bw * b.signExtend(32) + Const(16, width: 32))
              .getRange(0, 32);
      final sh = [s[31].replicate(5), s.getRange(5, 32)].concat();
      return clampS(sh, grainMin, grainMax).getRange(0, grainW);
    }

    Logic blend1(Logic a, Logic b) {
      final s =
          (Const(23, width: 32) * a.signExtend(32) +
                  Const(22, width: 32) * b.signExtend(32) +
                  Const(16, width: 32))
              .getRange(0, 32);
      final sh = [s[31].replicate(5), s.getRange(5, 32)].concat();
      return clampS(sh, grainMin, grainMax).getRange(0, grainW);
    }

    // counters / FSM
    const sIdle = 0, sY = 1, sC = 2, sDone = 3;
    final st = Logic(name: 'st', width: 2);
    final xR = Logic(name: 'xR', width: 16);
    final yR = Logic(name: 'yR', width: 16);
    final cxR = Logic(name: 'cxR', width: 16);
    final cyR = Logic(name: 'cyR', width: 16);
    output('done') <= st.eq(Const(sDone, width: 2));

    final outYbus = Logic(name: 'out_y_bus', width: nLumaPx * pxW);
    final outCbBus = Logic(name: 'out_cb_bus', width: nChromaPx * pxW);
    final outCrBus = Logic(name: 'out_cr_bus', width: nChromaPx * pxW);

    Logic shiftPx(Logic bus, Logic v, int n) =>
        [bus.getRange(0, (n - 1) * pxW), v.getRange(0, pxW)].concat();

    // block indices for luma pixel (yR,xR): by=Y>>5, bx=X>>5, li=Y&31, lj=X&31.
    Logic bY() => yR.getRange(5, 16);
    Logic bX() => xR.getRange(5, 16);
    Logic liY() => yR.getRange(0, 5);
    Logic ljX() => xR.getRange(0, 5);

    // luma grain template index for block offsets (oy,ox) and local (li,lj) in
    // extended coords: idx = (9 + 2*oy + li)*lumaStride + (9 + 2*ox + lj).
    Logic lumaIdx(Logic oy, Logic ox, Logic li, Logic lj) {
      final row =
          (Const(9, width: 16) + (oy.zeroExtend(16) << 1) + li.zeroExtend(16))
              .getRange(0, 16);
      final col =
          (Const(9, width: 16) + (ox.zeroExtend(16) << 1) + lj.zeroExtend(16))
              .getRange(0, 16);
      return (row * Const(lumaStride, width: 16) + col).getRange(0, 16);
    }

    // Column-resolved luma grain for block (by,bx), local (li,lj) [li 0..33].
    Logic colGY(Logic by, Logic bx, Logic li, Logic lj) {
      final oy = selOff(offY, by, bx), ox = selOff(offX, by, bx);
      final cur = grainSlice(tmplY, lumaIdx(oy, ox, li, lj), nLuma);
      if (!overlap) return cur;
      final bxm1 = (bx - Const(1, width: bx.width)).getRange(0, bx.width);
      final loy = selOff(offY, by, bxm1), lox = selOff(offX, by, bxm1);
      final leftIdx = lumaIdx(
        loy,
        lox,
        li,
        (lj + Const(32, width: 16)).getRange(0, 16),
      );
      final left = grainSlice(tmplY, leftIdx, nLuma);
      final doBlend =
          bx.gt(Const(0, width: bx.width)) & lj.lt(Const(2, width: 16));
      return mux(doBlend, blend2(left, cur, lj.eq(Const(0, width: 16))), cur);
    }

    Logic grainYval() {
      final by = bY(),
          bx = bX(),
          li = liY().zeroExtend(16),
          lj = ljX().zeroExtend(16);
      final cur = colGY(by, bx, li, lj);
      if (!overlap) return cur;
      final bym1 = (by - Const(1, width: by.width)).getRange(0, by.width);
      final above = colGY(
        bym1,
        bx,
        (li + Const(32, width: 16)).getRange(0, 16),
        lj,
      );
      final doBlend =
          by.gt(Const(0, width: by.width)) & li.lt(Const(2, width: 16));
      return mux(doBlend, blend2(above, cur, li.eq(Const(0, width: 16))), cur);
    }

    // chroma
    final ovcX = 2 >> ssx, ovcY = 2 >> ssy;
    final csubX = 32 >> ssx, csubY = 32 >> ssy;
    Logic bCY() => cyR.getRange(4, 16);
    Logic bCX() => cxR.getRange(4, 16);
    Logic cliY() => cyR.getRange(0, 4);
    Logic cljX() => cxR.getRange(0, 4);

    Logic chromaIdx(Logic oy, Logic ox, Logic cli, Logic clj) {
      final row = (Const(6, width: 16) + oy.zeroExtend(16) + cli.zeroExtend(16))
          .getRange(0, 16);
      final col = (Const(6, width: 16) + ox.zeroExtend(16) + clj.zeroExtend(16))
          .getRange(0, 16);
      return (row * Const(chromaStride, width: 16) + col).getRange(0, 16);
    }

    Logic colGC(Logic tmpl, Logic cli, Logic clj) {
      final by = bCY(), bx = bCX();
      final oy = selOff(offY, by, bx), ox = selOff(offX, by, bx);
      final cur = grainSlice(tmpl, chromaIdx(oy, ox, cli, clj), nChroma);
      if (!overlap) return cur;
      final bxm1 = (bx - Const(1, width: bx.width)).getRange(0, bx.width);
      final loy = selOff(offY, by, bxm1), lox = selOff(offX, by, bxm1);
      final leftIdx = chromaIdx(
        loy,
        lox,
        cli,
        (clj + Const(csubX, width: 16)).getRange(0, 16),
      );
      final left = grainSlice(tmpl, leftIdx, nChroma);
      final doBlend =
          bx.gt(Const(0, width: bx.width)) & clj.lt(Const(ovcX, width: 16));
      final blended = ovcX == 1
          ? blend1(left, cur)
          : blend2(left, cur, clj.eq(Const(0, width: 16)));
      return mux(doBlend, blended, cur);
    }

    Logic grainCval(Logic tmpl) {
      final cli = cliY().zeroExtend(16), clj = cljX().zeroExtend(16);
      final cur = colGC(tmpl, cli, clj);
      if (!overlap) return cur;
      // Above uses column-resolved grain of the block above at rows csubY+cli.
      // Re-evaluate colGC with the above block's counters via a temporary shift
      // of the block-row index is not possible here, recompute inline.
      final by = bCY(), bx = bCX();
      final bym1 = (by - Const(1, width: by.width)).getRange(0, by.width);
      Logic colGCat(Logic bby, Logic cliA, Logic cljA) {
        final oy = selOff(offY, bby, bx), ox = selOff(offX, bby, bx);
        final curA = grainSlice(tmpl, chromaIdx(oy, ox, cliA, cljA), nChroma);
        final bxm1 = (bx - Const(1, width: bx.width)).getRange(0, bx.width);
        final loy = selOff(offY, bby, bxm1), lox = selOff(offX, bby, bxm1);
        final leftIdx = chromaIdx(
          loy,
          lox,
          cliA,
          (cljA + Const(csubX, width: 16)).getRange(0, 16),
        );
        final left = grainSlice(tmpl, leftIdx, nChroma);
        final doBlend =
            bx.gt(Const(0, width: bx.width)) & cljA.lt(Const(ovcX, width: 16));
        final blended = ovcX == 1
            ? blend1(left, curA)
            : blend2(left, curA, cljA.eq(Const(0, width: 16)));
        return mux(doBlend, blended, curA);
      }

      final above = colGCat(
        bym1,
        (cli + Const(csubY, width: 16)).getRange(0, 16),
        clj,
      );
      final doBlend =
          by.gt(Const(0, width: by.width)) & cli.lt(Const(ovcY, width: 16));
      final blended = ovcY == 1
          ? blend1(above, cur)
          : blend2(above, cur, cli.eq(Const(0, width: 16)));
      return mux(doBlend, blended, cur);
    }

    // per-pixel apply datapath
    // noise = (scale*grain + round) >> scalingShift. Out = clamp(recon+noise).
    Logic applyPix(Logic recon, Logic scale, Logic grain, int lo, int hi) {
      Logic rnd = Const(0, width: 32);
      for (var k = 1; k <= 15; k++) {
        rnd = mux(
          scalingShift.eq(Const(k, width: 4)),
          Const(1 << (k - 1), width: 32),
          rnd,
        );
      }
      final prod = (scale.zeroExtend(32) * grain.signExtend(32)).getRange(
        0,
        32,
      );
      final noise = asr((prod + rnd).getRange(0, 32), 32, scalingShift);
      final sum = (recon.zeroExtend(32) + noise).getRange(0, 32);
      return clampS(sum, lo, hi).getRange(0, pxW);
    }

    // scaleLut(lut, index, bd): bd8 => lut[index], hbd => interpolate.
    Logic scaleOf(Logic lut, Logic index) {
      final x = index.getRange(bd - 8, bd - 8 + 8); // index >> (bd-8), 8 bits
      final base = lutSlice(lut, x);
      if (bd == 8) return base;
      final xp1 = (x + Const(1, width: 8)).getRange(0, 8);
      final nxt = lutSlice(lut, xp1);
      final frac = index.getRange(0, bd - 8).zeroExtend(32);
      final diff = (nxt.signExtend(32) - base.signExtend(32)).getRange(0, 32);
      final interp =
          (base.signExtend(32) +
                  ((diff * frac + Const(1 << (bd - 9), width: 32)).getRange(
                        0,
                        32,
                      ) >>>
                      (bd - 8)))
              .getRange(0, 32);
      // if x==255, no next, use base.
      final is255 = x.eq(Const(255, width: 8));
      return mux(is255, base.zeroExtend(interp.width), interp).getRange(0, 16);
    }

    // Luma pixel value + apply.
    final yPixIdx = (yR * Const(w, width: 16) + xR).getRange(0, 16);
    final reconYval = pxSlice(reconY, yPixIdx, nLumaPx);
    final scaleY = scaleOf(lutY, reconYval);
    // Luma grain is always applied for a film-grain frame (num_y_points > 0).
    final outYval = applyPix(reconYval, scaleY, grainYval(), minL, maxL);

    // Chroma pixel: avgLuma from recon luma, index, scale, apply for cb & cr.
    final cPixIdx = (cyR * Const(cw, width: 16) + cxR).getRange(0, 16);
    final lyPos = (((cyR << ssy) * Const(w, width: 16)) + (cxR << ssx))
        .getRange(0, 16);
    final lumaA = pxSlice(reconY, lyPos, nLumaPx);
    Logic avgLuma;
    if (ssx != 0) {
      final lumaA1 = pxSlice(
        reconY,
        (lyPos + Const(1, width: 16)).getRange(0, 16),
        nLumaPx,
      );
      avgLuma =
          ((lumaA.zeroExtend(32) +
                      lumaA1.zeroExtend(32) +
                      Const(1, width: 32)) >>>
                  1)
              .getRange(0, 32);
    } else {
      avgLuma = lumaA.zeroExtend(32);
    }

    Logic chromaOut(
      Logic reconBus,
      Logic lut,
      Logic lumaMult,
      Logic mult,
      Logic offset,
      Logic tmpl,
    ) {
      final rec = pxSlice(reconBus, cPixIdx, nChromaPx);
      // idx = clamp(((avgLuma*lumaMult + mult*rec)>>6) + offset, 0, chromaClampHi)
      final t1 =
          (avgLuma * lumaMult.signExtend(32) +
                  mult.signExtend(32) * rec.zeroExtend(32))
              .getRange(0, 32);
      final t2 = [t1[31].replicate(6), t1.getRange(6, 32)].concat();
      final idx = clampS((t2 + offset).getRange(0, 32), 0, chromaClampHi);
      final scale = scaleOf(lut, idx.getRange(0, 16));
      return applyPix(rec, scale, grainCval(tmpl), minC, maxC);
    }

    final outCbVal = applyCb
        ? chromaOut(reconCb, lutCb, cbLumaMult, cbMult, cbOffset, tmplCb)
        : pxSlice(reconCb, cPixIdx, nChromaPx);
    final outCrVal = applyCr
        ? chromaOut(reconCr, lutCr, crLumaMult, crMult, crOffset, tmplCr)
        : pxSlice(reconCr, cPixIdx, nChromaPx);

    // sequencing
    final lastX = xR.eq(Const(w - 1, width: 16));
    final lastY = yR.eq(Const(h - 1, width: 16));
    final lastCX = cxR.eq(Const(cw - 1, width: 16));
    final lastCY = cyR.eq(Const(ch - 1, width: 16));

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: 2),
          xR < Const(0, width: 16),
          yR < Const(0, width: 16),
          cxR < Const(0, width: 16),
          cyR < Const(0, width: 16),
          outYbus < Const(0, width: nLumaPx * pxW),
          outCbBus < Const(0, width: nChromaPx * pxW),
          outCrBus < Const(0, width: nChromaPx * pxW),
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(sIdle, width: 2), [
              If(
                start,
                then: [
                  xR < Const(0, width: 16),
                  yR < Const(0, width: 16),
                  cxR < Const(0, width: 16),
                  cyR < Const(0, width: 16),
                  st < Const(sY, width: 2),
                ],
              ),
            ]),
            CaseItem(Const(sY, width: 2), [
              outYbus < shiftPx(outYbus, outYval, nLumaPx),
              If(
                lastX & lastY,
                then: [st < Const(sC, width: 2)],
                orElse: [
                  If(
                    lastX,
                    then: [
                      xR < Const(0, width: 16),
                      yR < (yR + Const(1, width: 16)).getRange(0, 16),
                    ],
                    orElse: [xR < (xR + Const(1, width: 16)).getRange(0, 16)],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sC, width: 2), [
              outCbBus < shiftPx(outCbBus, outCbVal, nChromaPx),
              outCrBus < shiftPx(outCrBus, outCrVal, nChromaPx),
              If(
                lastCX & lastCY,
                then: [st < Const(sDone, width: 2)],
                orElse: [
                  If(
                    lastCX,
                    then: [
                      cxR < Const(0, width: 16),
                      cyR < (cyR + Const(1, width: 16)).getRange(0, 16),
                    ],
                    orElse: [cxR < (cxR + Const(1, width: 16)).getRange(0, 16)],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sDone, width: 2), [
              If(~start, then: [st < Const(sIdle, width: 2)]),
            ]),
          ]),
        ],
      ),
    ]);

    output('out_y') <= outYbus;
    output('out_cb') <= outCbBus;
    output('out_cr') <= outCrBus;
  }
}
