import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_pred_avail.dart';
import 'inv_txfm.dart';
import 'recon_add.dart';

/// Harbor variable-square intra RECON walk: reconstructs a square superblock
/// luma plane (`sbSize` x `sbSize` pixels) from a list of VARIABLE SQUARE intra
/// leaves (4x4 / 8x8 / 16x16) given in DECODE/RASTER order, each leaf predicting
/// from its already-reconstructed neighbours in a frame-buffer RAM (the
/// cross-leaf neighbour propagation the full tile decoder needs).
///
/// Generalizes [HarborKeyframeReconGrid]'s fixed-4x4 raster walk to variable
/// leaf sizes. Per leaf (in the given order): read the above row (leaf-side
/// samples), left column, and corner from the frame RAM (availability = the leaf
/// is not on the top / left plane edge), intra-predict via the size-appropriate
/// [HarborIntraPredAvail], inverse-transform the leaf's `coeffs` by `tx_type`
/// via the size-appropriate [HarborInvTxfm] (runtime tx_type), add + clip, and
/// write the leaf's square block back into the frame RAM. The variable size is
/// handled by instantiating ONE predictor + ONE transform per size (4/8/16) and
/// selecting the result block by the leaf's `log2size`. Square + luma only,
/// intra ext-tx set (DCT / ADST / IDTX 1D, no FLIPADST), bd 8.
///
/// Leaf-array packing (leaf l, fields little-endian within their per-leaf slot):
///  - `positions` width `maxLeaves*2*miBits` (miBits = bitLength(sbSize/4)):
///    leaf l at `[l*2*miBits +: 2*miBits]`, miRow in the low `miBits`, miCol in
///    the high `miBits` (mi = 4x4 unit coordinates).
///  - `log2sizes` width `maxLeaves*2`: leaf l's log2 size (0/1/2) at `[l*2 +: 2]`.
///  - `y_modes` width `maxLeaves*4`: leaf l's y_mode at `[l*4 +: 4]`.
///  - `tx_types` width `maxLeaves*4`: leaf l's tx_type at `[l*4 +: 4]`.
///  - `coeffs` width `maxLeaves*256*16`: leaf l's dequantized coeffs at
///    `[l*256*16 +: 256*16]`, row-major signed 16-bit, the low `side*side` used.
///  - `leaf_count`: number of valid leaves (1..maxLeaves).
///
/// `frame` output is the sbSize x sbSize plane, pixel (r, c) at `[(r*F+c)*8 +:
/// 8]` (F = sbSize). Pulse `start`. `done` asserts with `frame`.
///
/// TILE-RELATIVE AVAILABILITY (multi-superblock walk): the plane this module
/// reconstructs is one superblock at SB-origin (`sb_c`, `sb_r`) MI units inside
/// a tile whose top-left MI is (`tile_left_mi`, `tile_top_mi`). A leaf's above
/// neighbour is available iff its plane-absolute pixel row is above the tile top
/// edge boundary (`py_abs > tileTopPx`), its left neighbour iff `px_abs >
/// tileLeftPx` (mirrors the SW `haveTop`/`haveLeft` in tile_decode.dart). For a
/// leaf on the SB's TOP edge (py==0) whose tile-relative above IS available
/// (this SB is not at the tile top), the above row + corner come from the
/// EXTERNAL `ext_above` / `ext_corner` inputs (the previous SB-row's bottom line
/// fed in). For a leaf on the SB's LEFT edge (px==0) whose tile-relative left IS
/// available, the left column + corner come from `ext_left` / `ext_corner` (the
/// SB-to-the-left's reconstructed right column). Interior-leaf neighbours always
/// come from the frame RAM. With `sb_c == tile_left_mi` and `sb_r ==
/// tile_top_mi` (the tile-origin SB) and no external neighbours, every leaf
/// behaves exactly as the origin-pinned walk did: byte-identical.
class HarborIntraReconWalk extends BridgeModule {
  /// Plane side in pixels (square superblock). Must be a multiple of 4 and at
  /// least 8 (an 8x8 SB tiles into 4x4 / 8x8 leaves. A 16x16 leaf needs >= 16,
  /// but the 16x16 predictor/transform is simply never selected for a smaller
  /// plane).
  final int sbSize;

  /// Maximum number of leaves the walk can hold (sizes the packed arrays).
  final int maxLeaves;

  /// When true, expose the tile/SB placement + external-neighbour ports and use
  /// tile-relative availability. When false (default, single-SB wrappers) the
  /// module has NO such ports and behaves as the origin-pinned walk did.
  final bool tiled;

  /// Largest leaf transform size, as log2 of (side/4): 2 = up to 16x16 (default,
  /// `coeffs` 256-wide, byte-identical to the original), 3 = up to 32x32
  /// (`coeffs` 1024-wide, adds the 32x32 predictor + transform), 4 = up to 64x64
  /// (adds the ~2.5min-build 64x64 transform). The `coeffs` port width and the
  /// number of instantiated per-size predictor/transform lanes scale with this.
  final int maxLog2;

  HarborIntraReconWalk({
    this.sbSize = 16,
    this.maxLeaves = 16,
    this.tiled = false,
    this.maxLog2 = 2,
    String? name,
  }) : assert(sbSize >= 8 && sbSize % 4 == 0, 'sbSize multiple of 4, >= 8'),
       assert(maxLeaves >= 1 && maxLeaves <= 64, 'maxLeaves 1..64'),
       assert(maxLog2 >= 1 && maxLog2 <= 4, 'maxLog2 1..4'),
       // NOTE: maxLog2 may over-provision lanes/coeff-slots larger than the
       // plane (e.g. an 8x8 SB with the default maxLog2 2 = 16x16 lanes). That
       // is harmless: the unused large-leaf lanes are dead logic as long as the
       // caller only sends leaves that fit `sbSize` (a runtime contract). The
       // pre-parameter code always used 16x16 lanes for an 8x8 plane this way.
       super(
         'HarborIntraReconWalk_S${sbSize}_L${maxLeaves}_'
         'T${tiled ? 1 : 0}_G$maxLog2',
         name: name ?? 'intra_recon_walk_${sbSize}_$maxLeaves',
       ) {
    final f = sbSize; // frame side in pixels
    final nPix = f * f;
    final maxSide = 4 << maxLog2; // largest leaf side in pixels
    final coeffN = maxSide * maxSide; // coeff slot per leaf
    final mw = sbSize ~/ 4; // mi units per side
    final miBits = mw.bitLength; // holds a mi coordinate (0..mw)
    final cntW = (maxLeaves + 1).bitLength;
    final leafW = maxLeaves.bitLength; // index into the leaf arrays
    // Linear pixel-address width (nPix <= sbSize^2, allow margin for +side).
    final iw = (nPix + f).bitLength;

    // MI coordinate width: tile/SB origin coordinates in 4x4 units. Wide enough
    // for any reasonable tile. The test drives small values.
    const miAbsW = 16;

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('leaf_count', PortDirection.input, width: cntW);
    createPort('positions', PortDirection.input, width: maxLeaves * 2 * miBits);
    createPort('log2sizes', PortDirection.input, width: maxLeaves * 2);
    createPort('y_modes', PortDirection.input, width: maxLeaves * 4);
    createPort('tx_types', PortDirection.input, width: maxLeaves * 4);
    createPort('coeffs', PortDirection.input, width: maxLeaves * coeffN * 16);
    // Tile/SB placement (MI = 4x4 units) + external neighbours, only when
    // `tiled`. The above row is this SB's column span (the bottom line of the SB
    // above). The left column is this SB's row span (the right column of the SB
    // to the left). The corner is the above-left SB's bottom-right pixel.
    if (tiled) {
      createPort('sb_r', PortDirection.input, width: miAbsW);
      createPort('sb_c', PortDirection.input, width: miAbsW);
      createPort('tile_top_mi', PortDirection.input, width: miAbsW);
      createPort('tile_left_mi', PortDirection.input, width: miAbsW);
      createPort('ext_above', PortDirection.input, width: f * 8);
      createPort('ext_left', PortDirection.input, width: f * 8);
      createPort('ext_corner', PortDirection.input, width: 8);
    }
    addOutput('done');
    addOutput('frame', width: nPix * 8);

    final clk = input('clk');
    final reset = input('reset');

    // Frame-buffer RAM.
    final frame = [
      for (var i = 0; i < nPix; i++) Logic(name: 'f_$i', width: 8),
    ];
    final leaf = Logic(name: 'leaf', width: leafW); // current leaf index

    // Select per-leaf field [l*w +: w] of a packed input by the leaf index.
    Logic selSlice(String port, int w) {
      Logic v = input(port).getRange((maxLeaves - 1) * w, maxLeaves * w);
      for (var l = maxLeaves - 2; l >= 0; l--) {
        v = mux(
          leaf.eq(Const(l, width: leafW)),
          input(port).getRange(l * w, l * w + w),
          v,
        );
      }
      return v;
    }

    final posCur = selSlice('positions', 2 * miBits);
    final miR = posCur.getRange(0, miBits).zeroExtend(iw);
    final miC = posCur.getRange(miBits, 2 * miBits).zeroExtend(iw);
    final log2Cur = selSlice('log2sizes', 2);
    final yMode = selSlice('y_modes', 4);
    final txType = selSlice('tx_types', 4);
    final coeffsCur = selSlice('coeffs', coeffN * 16);

    // Pixel top-left of the current leaf, plane-relative (within this SB).
    final py = (miR * Const(4, width: iw)).getRange(0, iw);
    final px = (miC * Const(4, width: iw)).getRange(0, iw);

    // Above/left neighbour row/col addresses, used by both branches.
    final aboveRow = (py - Const(1, width: iw)).getRange(0, iw);
    final leftCol = (px - Const(1, width: iw)).getRange(0, iw);

    // Frame RAM read at a linear address.
    Logic selFrame(Logic idx) {
      Logic v = frame.last;
      for (var i = nPix - 2; i >= 0; i--) {
        v = mux(idx.eq(Const(i, width: iw)), frame[i], v);
      }
      return v;
    }

    Logic frameAt(Logic row, Logic col) =>
        selFrame((row * Const(f, width: iw) + col).getRange(0, iw));

    final Logic haveA;
    final Logic haveL;
    final List<Logic> aboveAll;
    final List<Logic> leftAll;
    final Logic corner;

    if (tiled) {
      // TILE-RELATIVE AVAILABILITY
      // Plane-absolute pixel position = SB-origin pixel + leaf plane offset. The
      // tile edge boundary in pixels = tile-origin MI * 4. The above neighbour
      // is available iff the absolute pixel row exceeds the tile top edge, the
      // left iff the absolute pixel col exceeds the tile left edge (SW
      // haveTop/haveLeft).
      final sbPyAbs = (input('sb_r') * Const(4, width: miAbsW)).getRange(
        0,
        miAbsW,
      );
      final sbPxAbs = (input('sb_c') * Const(4, width: miAbsW)).getRange(
        0,
        miAbsW,
      );
      final tileTopPx = (input('tile_top_mi') * Const(4, width: miAbsW))
          .getRange(0, miAbsW);
      final tileLeftPx = (input('tile_left_mi') * Const(4, width: miAbsW))
          .getRange(0, miAbsW);
      final pyAbs = (sbPyAbs + py.zeroExtend(miAbsW)).getRange(0, miAbsW);
      final pxAbs = (sbPxAbs + px.zeroExtend(miAbsW)).getRange(0, miAbsW);
      haveA = pyAbs.gt(tileTopPx);
      haveL = pxAbs.gt(tileLeftPx);

      // A leaf on the SB's own top/left edge (py==0 / px==0) draws its
      // above/left from the EXTERNAL inputs (the neighbouring SB's reconstructed
      // line). An interior leaf draws from this SB's frame RAM. The corner is
      // external when the leaf is at the SB top-left edge (both py==0 and px==0).
      final atSbTop = py.eq(Const(0, width: iw));
      final atSbLeft = px.eq(Const(0, width: iw));

      // ext_above / ext_left span the SB column / row (f entries). Index by a
      // runtime offset (the leaf's px+i column / py+i row within the SB span).
      Logic extAboveAt(Logic col) {
        Logic v = input('ext_above').getRange((f - 1) * 8, f * 8);
        for (var j = f - 2; j >= 0; j--) {
          v = mux(
            col.eq(Const(j, width: iw)),
            input('ext_above').getRange(j * 8, j * 8 + 8),
            v,
          );
        }
        return v;
      }

      Logic extLeftAt(Logic row) {
        Logic v = input('ext_left').getRange((f - 1) * 8, f * 8);
        for (var j = f - 2; j >= 0; j--) {
          v = mux(
            row.eq(Const(j, width: iw)),
            input('ext_left').getRange(j * 8, j * 8 + 8),
            v,
          );
        }
        return v;
      }

      // Neighbour samples for the largest size, smaller predictors use a prefix.
      // The above row: when on the SB top edge use ext_above[px + i] (the column
      // within the SB span), else read the frame RAM row above.
      aboveAll = [
        for (var i = 0; i < maxSide; i++)
          mux(
            atSbTop,
            extAboveAt((px + Const(i, width: iw)).getRange(0, iw)),
            frameAt(aboveRow, (px + Const(i, width: iw)).getRange(0, iw)),
          ),
      ];
      // The left column: when on the SB left edge use ext_left[py + i].
      leftAll = [
        for (var i = 0; i < maxSide; i++)
          mux(
            atSbLeft,
            extLeftAt((py + Const(i, width: iw)).getRange(0, iw)),
            frameAt((py + Const(i, width: iw)).getRange(0, iw), leftCol),
          ),
      ];
      // Corner (above-left): at the SB top-left it is ext_corner. On the SB top
      // edge (px>0) it is the above SB's bottom row at col px-1. On the SB left
      // edge (py>0) it is the left SB's right column at row py-1. Interior reads
      // the frame RAM diagonal.
      corner = mux(
        atSbTop & atSbLeft,
        input('ext_corner'),
        mux(
          atSbTop,
          extAboveAt(leftCol),
          mux(atSbLeft, extLeftAt(aboveRow), frameAt(aboveRow, leftCol)),
        ),
      );
    } else {
      // ORIGIN-PINNED AVAILABILITY (single-SB, no external neighbours)
      // Above available iff not on the plane top edge, left iff not on the plane
      // left edge. All neighbours read the frame RAM.
      haveA = py.gt(Const(0, width: iw));
      haveL = px.gt(Const(0, width: iw));
      aboveAll = [
        for (var i = 0; i < maxSide; i++)
          frameAt(aboveRow, (px + Const(i, width: iw)).getRange(0, iw)),
      ];
      leftAll = [
        for (var i = 0; i < maxSide; i++)
          frameAt((py + Const(i, width: iw)).getRange(0, iw), leftCol),
      ];
      corner = frameAt(aboveRow, leftCol);
    }

    // per-size predictor + transform, MUXed by log2size
    final sizes = [for (var i = 0; i <= maxLog2; i++) 4 << i];
    final txStart = Logic(name: 'tx_start');
    final reconBlk = <List<Logic>>[]; // reconBlk[s] = recon pixels for size s
    final txDoneBySize = <Logic>[];

    for (var s = 0; s < sizes.length; s++) {
      final side = sizes[s];
      final pred = HarborIntraPredAvail(bs: side, name: 'pred$side');
      addSubModule(pred);
      pred.input('mode').srcConnection! <= yMode;
      pred.input('have_above').srcConnection! <= haveA;
      pred.input('have_left').srcConnection! <= haveL;
      pred.input('above').srcConnection! <=
          [for (var i = side - 1; i >= 0; i--) aboveAll[i]].swizzle();
      pred.input('left').srcConnection! <=
          [for (var i = side - 1; i >= 0; i--) leftAll[i]].swizzle();
      pred.input('above_left').srcConnection! <= corner;

      // runtime tx_type only for TX_4X4 / 8X8 / 16X16 (s <= 2). TX_32X32 /
      // TX_64X64 intra are EXT_TX_SET_DCTONLY, so tx_type is always DCT_DCT: use
      // a fixed-DCT transform (HarborInvTxfm forbids runtimeTxType at s >= 3).
      final rtt = s <= 2;
      final tx = HarborInvTxfm(
        txSize: s,
        txType: 0,
        runtimeTxType: rtt,
        name: 'tx$side',
      );
      addSubModule(tx);
      tx.input('clk').srcConnection! <= clk;
      tx.input('reset').srcConnection! <= reset;
      tx.input('start').srcConnection! <= txStart;
      tx.input('coeffs').srcConnection! <=
          coeffsCur.getRange(0, side * side * 16);
      if (rtt) tx.input('tx_type').srcConnection! <= txType;
      txDoneBySize.add(tx.output('done'));

      final ra = HarborReconAdd(n: side * side, name: 'ra$side');
      addSubModule(ra);
      ra.input('pred').srcConnection! <= pred.output('pred');
      ra.input('residual').srcConnection! <= tx.output('residual');
      final recon = ra.output('recon');
      reconBlk.add([
        for (var i = 0; i < side * side; i++) recon.getRange(i * 8, i * 8 + 8),
      ]);
    }

    // The active transform's done, selected by log2size (mux chain over sizes).
    Logic txDone = txDoneBySize.last;
    for (var s = sizes.length - 2; s >= 0; s--) {
      txDone = mux(log2Cur.eq(Const(s, width: 2)), txDoneBySize[s], txDone);
    }

    // FSM
    const sIdle = 0, sPred = 1, sTxWait = 2, sWrite = 3, sDone = 4;
    final st = Logic(name: 'st', width: 3);
    output('done') <= st.eq(Const(sDone, width: 3));
    output('frame') <= [for (var i = nPix - 1; i >= 0; i--) frame[i]].swizzle();

    Combinational([
      txStart < Const(0),
      Case(st, [
        CaseItem(Const(sPred, width: 3), [txStart < Const(1)]),
      ]),
    ]);

    final lastLeaf = (input('leaf_count') - Const(1, width: cntW)).getRange(
      0,
      leafW,
    );

    // Write-back: for each pixel k of the frame, if it lies inside the current
    // leaf's square footprint, write the matching recon sample (size-selected).
    final kr = [for (var k = 0; k < nPix; k++) k ~/ f]; // pixel row
    final kc = [for (var k = 0; k < nPix; k++) k % f]; // pixel col

    // For size s, pixel k is inside iff py <= kr < py+side and px <= kc < px+side,
    // local index = (kr-py)*side + (kc-px).
    List<Conditional> writeBackFor(int s) {
      final side = sizes[s];
      final conds = <Conditional>[];
      for (var k = 0; k < nPix; k++) {
        final inRow =
            Const(kr[k], width: iw).gte(py) &
            Const(
              kr[k],
              width: iw,
            ).lt((py + Const(side, width: iw)).getRange(0, iw));
        final inCol =
            Const(kc[k], width: iw).gte(px) &
            Const(
              kc[k],
              width: iw,
            ).lt((px + Const(side, width: iw)).getRange(0, iw));
        // local index, computed from the (constant) k minus the (signal) py/px.
        final li =
            ((Const(kr[k], width: iw) - py).getRange(0, iw) *
                        Const(side, width: iw) +
                    (Const(kc[k], width: iw) - px).getRange(0, iw))
                .getRange(0, iw);
        // mux the recon sample by local index.
        Logic sample = reconBlk[s].last;
        for (var j = side * side - 2; j >= 0; j--) {
          sample = mux(li.eq(Const(j, width: iw)), reconBlk[s][j], sample);
        }
        conds.add(If(inRow & inCol, then: [frame[k] < sample]));
      }
      return conds;
    }

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: 3),
          leaf < Const(0, width: leafW),
          for (var i = 0; i < nPix; i++) frame[i] < Const(0, width: 8),
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(sIdle, width: 3), [
              If(
                input('start'),
                then: [
                  leaf < Const(0, width: leafW),
                  for (var i = 0; i < nPix; i++) frame[i] < Const(0, width: 8),
                  st < Const(sPred, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(sPred, width: 3), [st < Const(sTxWait, width: 3)]),
            CaseItem(Const(sTxWait, width: 3), [
              If(txDone, then: [st < Const(sWrite, width: 3)]),
            ]),
            CaseItem(Const(sWrite, width: 3), [
              // write the leaf block back (size-selected footprint).
              Case(log2Cur, [
                for (var s = 0; s < sizes.length; s++)
                  CaseItem(Const(s, width: 2), writeBackFor(s)),
              ]),
              If(
                leaf.eq(lastLeaf),
                then: [st < Const(sDone, width: 3)],
                orElse: [
                  leaf < (leaf + Const(1, width: leafW)).getRange(0, leafW),
                  st < Const(sPred, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(sDone, width: 3), [
              If(~input('start'), then: [st < Const(sIdle, width: 3)]),
            ]),
          ]),
        ],
      ),
    ]);
  }
}
