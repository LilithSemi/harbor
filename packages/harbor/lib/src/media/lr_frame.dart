import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'package:harbor/harbor.dart' show HarborLrUnit;

/// Bit-exact AV1 loop-restoration full-frame walk for one plane (libaom
/// `restoration.c` `av1_loop_restoration_filter_frame` -> `filter_frame_unit`
/// path, bd8).
///
/// This generalizes [HarborLrFrameWalk] (a single interior stripe of a single
/// unit-row) to the whole plane:
///
///  * MULTI-STRIPE VERTICAL WALK. The plane is tiled by restoration units on a
///    `unitSize` grid (`horzUnits x vertUnits`, `av1_lr_count_units`). Each unit
///    rect `[vStart,vEnd) x [hStart,hEnd)` is derived exactly as
///    `applyRestorationPlane`: the last partial unit uses `extSize = 3/2 * unit`
///    and every unit's vertical extent is pulled up by `RESTORATION_UNIT_OFFSET`
///    (`voffset = unitOffset >> ssY`, except the plane top which clamps to 0 and
///    the plane bottom which is not pulled up). Inside a unit the stripe loop
///    steps by 64-row (`procUnitSize >> ssY`) processing stripes.
///
///  * FIRST / LAST STRIPE TOGGLES. Per stripe, `copyAbove` is disabled for the
///    plane-top stripe (`stripeVStart == 0`) and `copyBelow` for the plane-bottom
///    stripe (`stripeVStart + thisStripeHeight >= planeH`), exactly libaom's
///    `RESTORATION_STRIPE_HEIGHT`/first-stripe adjustment. When a toggle is off
///    the corresponding border rows fall back to the plane's own edge replicate
///    (the padded post-CDEF buffer), NOT the saved boundary lines.
///
///  * BOUNDARY-LINE SOURCING FROM THE DEBLOCKED SNAPSHOT. The saved stripe
///    boundary lines (`save_boundary_lines`) come from the pre-CDEF (deblock
///    only) plane for interior stripes and from the post-CDEF plane for the
///    frame edges, mirroring `_saveBoundaries`. For stripe `s` the above context
///    is deblocked rows `[y0-2 .. y0-1]` (`y0 = max(0, s*sh - off)`), the below
///    context is deblocked rows `[y1 .. y1+1]` (`y1 = min((s+1)*sh - off,
///    planeH)`); RESTORATION_CTX_VERT=2 collapses the +/-3 border rows onto two
///    context lines per side (above: body -3,-2 -> ctx0, -1 -> ctx1. Below: body
///    0 -> ctx0, +1,+2 -> ctx1).
///
///  * PER-PROC-UNIT + PER-UNIT COEFFICIENTS. Each stripe is filtered in
///    `procunitWidth = 64 >> ssX` wide chunks. Each (stripe, chunk) block is one
///    [HarborLrUnit] carrying the owning restoration unit's `rtype` + Wiener taps
///    + SGR params. Wiener columns are independent and each SGR chunk sources its
///    +/-3 horizontal border from real neighbour pixels, so the chunking is
///    bit-identical to libaom.
///
///  * CHROMA. Subsampling only enters through `ssX`/`ssY`: `stripeHeight =
///    procUnitSize >> ssY`, `procunitWidth = procUnitSize >> ssX`, `voffset =
///    unitOffset >> ssY`. The plane dims and `unitSize` are passed already
///    subsampled by the caller, so a chroma plane is just another instance with
///    its own `planeW`/`planeH`/`unitSize`.
///
/// `procUnitSize` (RESTORATION_PROC_UNIT_SIZE, default 64) and `unitOffset`
/// (RESTORATION_UNIT_OFFSET, default 8) are exposed as parameters SOLELY so tiny
/// multi-stripe planes can be exercised in fast simulation, production instances
/// use the defaults.
///
/// Ports (all 8b pixels, LSB-first packing, index `row * planeW + col`):
///   in  `postCdef`  : the post-CDEF (+superres) plane, `planeH * planeW` px.
///   in  `deblocked` : the deblock-only snapshot for the boundary lines, same
///                     layout. (Only the boundary rows are read.)
///   in  per unit u in [0, horzUnits*vertUnits): `rtype$u` (2b),
///                     `h0_$u..h2_$u`/`v0_$u..v2_$u` (8b signed Wiener half-taps),
///                     `s0_$u`/`s1_$u` (12b SGR noise), `xq0_$u`/`xq1_$u` (8b
///                     signed SGR weights). Units are laid out `rowNum*horzUnits
///                     + col`.
///   out `out`       : the restored plane, same layout.
/// Combinational.
class HarborLrFrame extends BridgeModule {
  static const int restorationBorder = 3;
  static const int restorationCtxVert = 2;

  final int planeW;
  final int planeH;
  final int bd;
  final int horzUnits;
  final int vertUnits;

  static int _countUnits(int unitSize, int planeSize) =>
      max((planeSize + (unitSize >> 1)) ~/ unitSize, 1);

  HarborLrFrame({
    required int planeW,
    required int planeH,
    int unitSize = 64,
    int ssX = 0,
    int ssY = 0,
    int procUnitSize = 64,
    int unitOffset = 8,
    int bd = 8,
    String? name,
  }) : planeW = planeW,
       planeH = planeH,
       bd = bd,
       horzUnits = _countUnits(unitSize, planeW),
       vertUnits = _countUnits(unitSize, planeH),
       super(
         'HarborLrFrame_W${planeW}_H${planeH}_U${unitSize}_'
         'SX${ssX}_SY${ssY}_P${procUnitSize}_O${unitOffset}_B$bd',
         name: name ?? 'lr_frame',
       ) {
    if (planeW <= 0) {
      throw ArgumentError('HarborLrFrame.planeW must be positive: $planeW');
    }
    if (planeH <= 0) {
      throw ArgumentError('HarborLrFrame.planeH must be positive: $planeH');
    }
    if (unitSize <= 0) {
      throw ArgumentError('HarborLrFrame.unitSize must be positive: $unitSize');
    }
    if (ssX != 0 && ssX != 1) {
      throw ArgumentError('HarborLrFrame.ssX must be 0 or 1: $ssX');
    }
    if (ssY != 0 && ssY != 1) {
      throw ArgumentError('HarborLrFrame.ssY must be 0 or 1: $ssY');
    }
    if (procUnitSize <= 0 || procUnitSize.isOdd) {
      throw ArgumentError(
        'HarborLrFrame.procUnitSize must be a positive even value: '
        '$procUnitSize',
      );
    }
    if (unitOffset < 0 || unitOffset >= procUnitSize) {
      throw ArgumentError(
        'HarborLrFrame.unitOffset must be in [0, '
        'procUnitSize): $unitOffset',
      );
    }

    final numUnits = horzUnits * vertUnits;

    createPort('postCdef', PortDirection.input, width: planeW * planeH * bd);
    createPort('deblocked', PortDirection.input, width: planeW * planeH * bd);
    for (var u = 0; u < numUnits; u++) {
      createPort('rtype$u', PortDirection.input, width: 2);
      for (final t in ['h0', 'h1', 'h2', 'v0', 'v1', 'v2']) {
        createPort('${t}_$u', PortDirection.input, width: 8);
      }
      createPort('s0_$u', PortDirection.input, width: 12);
      createPort('s1_$u', PortDirection.input, width: 12);
      createPort('xq0_$u', PortDirection.input, width: 8);
      createPort('xq1_$u', PortDirection.input, width: 8);
    }
    addOutput('out', width: planeW * planeH * bd);

    final postCdef = input('postCdef');
    final deblocked = input('deblocked');

    int clampX(int c) => c < 0 ? 0 : (c >= planeW ? planeW - 1 : c);
    int clampY(int r) => r < 0 ? 0 : (r >= planeH ? planeH - 1 : r);

    Logic postAt(int row, int col) {
      final k = clampY(row) * planeW + clampX(col);
      return postCdef.getRange(k * bd, k * bd + bd);
    }

    Logic deblockAt(int row, int col) {
      final k = clampY(row) * planeW + clampX(col);
      return deblocked.getRange(k * bd, k * bd + bd);
    }

    final stripeHeight = procUnitSize >> ssY;
    final stripeOff = unitOffset >> ssY;
    final procunitWidth = procUnitSize >> ssX;
    final runitOffset = stripeOff;
    final voffset = stripeOff;
    final extSize = unitSize * 3 ~/ 2;

    // Saved above/below boundary line (mirrors _saveBoundaries): for global
    // stripe `s` and context `ctx`, return the plane pixel Logic at column
    // `col`. Above interior stripes source the DEBLOCKED plane rows y0-2, y0-1,
    // the plane-top stripe sources post-CDEF row y0 (both contexts). Below is
    // symmetric with y1 and the post-CDEF fallback at the plane bottom.
    Logic boundaryAbove(int stripe, int ctx, int col) {
      final y0 = max(0, stripe * stripeHeight - stripeOff);
      if (stripe > 0) {
        final row = y0 - restorationCtxVert;
        final linesToSave = min(restorationCtxVert, planeH - row);
        final r = ctx == 0 ? row : (linesToSave >= 2 ? row + 1 : row);
        return deblockAt(r, col);
      }
      return postAt(y0, col);
    }

    Logic boundaryBelow(int stripe, int ctx, int col) {
      final y1 = min((stripe + 1) * stripeHeight - stripeOff, planeH);
      if (y1 < planeH) {
        final row = y1;
        final linesToSave = min(restorationCtxVert, planeH - row);
        final r = ctx == 0 ? row : (linesToSave >= 2 ? row + 1 : row);
        return deblockAt(r, col);
      }
      return postAt(y1 - 1, col);
    }

    final outPlane = List<Logic?>.filled(
      planeH * planeW,
      null,
      growable: false,
    );
    var instCount = 0;

    // Emit one (stripe, proc-unit-width chunk) HarborLrUnit block covering
    // `w x h` body pixels at plane origin (rowStart, colStart), assembling its
    // padded region with the stripe-boundary swap.
    void emitBlock(
      int unitIdx,
      int colStart,
      int rowStart,
      int w,
      int h,
      int frameStripe,
      bool copyAbove,
      bool copyBelow,
    ) {
      final pw = w + 6;
      final ph = h + 6;
      final region = <Logic>[];
      for (var r = 0; r < ph; r++) {
        final bodyRel = r - restorationBorder; // -3 .. h+2
        for (var c = 0; c < pw; c++) {
          final planeCol = colStart + c - restorationBorder;
          Logic px;
          if (bodyRel >= 0 && bodyRel < h) {
            px = postAt(rowStart + bodyRel, planeCol);
          } else if (bodyRel < 0) {
            if (copyAbove) {
              // ctx = max(i + CTX_VERT, 0): body -3,-2 -> ctx0, -1 -> ctx1.
              final ctx = bodyRel + restorationCtxVert <= 0 ? 0 : 1;
              px = boundaryAbove(frameStripe, ctx, planeCol);
            } else {
              px = postAt(rowStart + bodyRel, planeCol);
            }
          } else {
            if (copyBelow) {
              // ctx = min(i, CTX_VERT-1): body 0 -> ctx0, +1,+2 -> ctx1.
              final i = bodyRel - h;
              final ctx = i < 1 ? 0 : 1;
              px = boundaryBelow(frameStripe, ctx, planeCol);
            } else {
              px = postAt(rowStart + bodyRel, planeCol);
            }
          }
          region.add(px);
        }
      }
      final padded = region.reversed.toList().swizzle();

      final unit = HarborLrUnit(
        width: w,
        height: h,
        bd: bd,
        name: 'lru_${instCount++}',
      );
      addSubModule(unit);
      unit.input('padded').srcConnection! <= padded;
      unit.input('rtype').srcConnection! <= input('rtype$unitIdx');
      for (final t in [
        'h0',
        'h1',
        'h2',
        'v0',
        'v1',
        'v2',
        's0',
        's1',
        'xq0',
        'xq1',
      ]) {
        unit.input(t).srcConnection! <= input('${t}_$unitIdx');
      }
      final uOut = unit.output('out'); // packs (i,j) at i*w + j, bd bits each.
      for (var i = 0; i < h; i++) {
        for (var j = 0; j < w; j++) {
          final uk = i * w + j;
          outPlane[(rowStart + i) * planeW + (colStart + j)] = uOut.getRange(
            uk * bd,
            uk * bd + bd,
          );
        }
      }
    }

    // filter_unit: walk the 64-row processing stripes covering [vStart, vEnd),
    // splitting each into procunitWidth chunks.
    void filterUnit(int unitIdx, int hStart, int hEnd, int vStart, int vEnd) {
      final unitH = vEnd - vStart;
      final unitW = hEnd - hStart;
      var i = 0;
      while (i < unitH) {
        final stripeVStart = vStart + i;
        var copyAbove = true;
        var copyBelow = true;
        final firstInPlane = stripeVStart == 0;
        final thisStripeHeight =
            stripeHeight - (firstInPlane ? runitOffset : 0);
        final lastInPlane = stripeVStart + thisStripeHeight >= planeH;
        if (firstInPlane) copyAbove = false;
        if (lastInPlane) copyBelow = false;
        final frameStripe = (stripeVStart + runitOffset) ~/ stripeHeight;
        final nominalStripeHeight =
            stripeHeight - (frameStripe == 0 ? runitOffset : 0);
        final h = min(nominalStripeHeight, vEnd - stripeVStart);
        var jj = 0;
        while (jj < unitW) {
          final w = min(procunitWidth, unitW - jj);
          emitBlock(
            unitIdx,
            hStart + jj,
            stripeVStart,
            w,
            h,
            frameStripe,
            copyAbove,
            copyBelow,
          );
          jj += w;
        }
        i += h;
      }
    }

    // apply_restoration_plane: the outer unit grid over the plane.
    var y0 = 0;
    var rowNum = 0;
    while (y0 < planeH) {
      final remainingH = planeH - y0;
      final hUnit = remainingH < extSize ? remainingH : unitSize;
      var vStart = y0;
      var vEnd = y0 + hUnit;
      vStart = max(0, vStart - voffset);
      if (vEnd < planeH) vEnd -= voffset;
      var x0 = 0;
      var jcol = 0;
      while (x0 < planeW) {
        final remainingW = planeW - x0;
        final wUnit = remainingW < extSize ? remainingW : unitSize;
        final unitIdx = rowNum * horzUnits + jcol;
        filterUnit(unitIdx, x0, x0 + wUnit, vStart, vEnd);
        x0 += wUnit;
        jcol++;
      }
      y0 += hUnit;
      rowNum++;
    }

    final outParts = [for (final p in outPlane) p!];
    output('out') <= outParts.reversed.toList().swizzle();
  }
}
