import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'package:harbor/harbor.dart' show HarborLrUnit;

/// Harbor bit-exact AV1 loop-restoration FRAME-WALK over a single horizontal
/// stripe of restoration units (libaom `restoration.c` `filter_unit` /
/// `setup_processing_stripe_boundary`).
///
/// SCOPE (shipped): one interior stripe of `units` restoration units laid out
/// horizontally across a plane region of `planeW = units * width` by
/// `planeH = height`. The stripe is treated as NEITHER the first NOR the last
/// stripe in the plane, so BOTH the above and below stripe boundaries are
/// active. Each unit is one [HarborLrUnit]. The units run combinationally in
/// parallel (the region is intentionally small). The remaining follow-ups are
/// the multi-stripe vertical walk (stepping `y0` by the stripe height down the
/// plane and handling the first/last-stripe `copyAbove`/`copyBelow` toggles and
/// the RESTORATION_UNIT_OFFSET) and the boundary-line SOURCING (deriving the
/// above/below saved deblock/CDEF lines from the RDO save. Here they are direct
/// inputs).
///
/// THE STRIPE BOUNDARY SWAP is the defining AV1 detail and is modelled at build
/// time: when a unit's padded region is assembled, the rows OUTSIDE the stripe
/// (the +/-RESTORATION_BORDER=3 rows that sit at padded rows 0..2 and
/// height+3..height+5) are sourced from the saved boundary lines passed in as
/// `above`/`below`, NOT from any neighbouring stripe's pixels. This is exactly
/// what makes loop restoration stripe-bounded. With RESTORATION_CTX_VERT=2 only
/// two distinct context rows exist per side, mapped (mirrors
/// `_setupStripeBoundary`):
///   above: padded row 0 (body -3) -> ctx0, row 1 (body -2) -> ctx0,
///          row 2 (body -1) -> ctx1.
///   below: padded row height+3 (body height)   -> ctx0,
///          row height+4 (body height+1)        -> ctx1,
///          row height+5 (body height+2)        -> ctx1.
/// The horizontal direction replicates at the plane edges (no swap), matching
/// the padded-plane buffer and the boundary-line column clamp.
///
/// Ports (all 8b pixels, LSB-first packing):
///   in  `body`  : plane stripe body, `planeH * planeW` pixels, index
///                 `row * planeW + col`.
///   in  `above` : 2 context rows x `planeW`, index `ctx * planeW + col`.
///   in  `below` : 2 context rows x `planeW`, index `ctx * planeW + col`.
///   in  per unit u: `rtype$u` (2b), `h0_$u..h2_$u`/`v0_$u..v2_$u` (8b signed
///                 Wiener half-taps), `s0_$u`/`s1_$u` (12b SGR noise),
///                 `xq0_$u`/`xq1_$u` (8b signed SGR weights).
///   out `out`   : restored plane, `planeH * planeW` pixels, index
///                 `row * planeW + col`.
/// Combinational.
class HarborLrFrameWalk extends BridgeModule {
  static const int restorationBorder = 3;
  static const int restorationCtxVert = 2;

  HarborLrFrameWalk({
    int width = 8,
    int height = 8,
    int units = 2,
    String? name,
  }) : super('HarborLrFrameWalk', name: name ?? 'lr_frame_walk') {
    if (width <= 0) {
      throw ArgumentError('HarborLrFrameWalk.width must be positive: $width');
    }
    if (height <= 0) {
      throw ArgumentError('HarborLrFrameWalk.height must be positive: $height');
    }
    if (units <= 0) {
      throw ArgumentError('HarborLrFrameWalk.units must be positive: $units');
    }
    final planeW = units * width;
    final planeH = height;
    final pw = width + 6; // padded unit width
    final ph = height + 6; // padded unit height

    createPort('body', PortDirection.input, width: planeW * planeH * 8);
    createPort('above', PortDirection.input, width: planeW * 2 * 8);
    createPort('below', PortDirection.input, width: planeW * 2 * 8);
    for (var u = 0; u < units; u++) {
      createPort('rtype$u', PortDirection.input, width: 2);
      for (final t in ['h0', 'h1', 'h2', 'v0', 'v1', 'v2']) {
        createPort('${t}_$u', PortDirection.input, width: 8);
      }
      createPort('s0_$u', PortDirection.input, width: 12);
      createPort('s1_$u', PortDirection.input, width: 12);
      createPort('xq0_$u', PortDirection.input, width: 8);
      createPort('xq1_$u', PortDirection.input, width: 8);
    }
    addOutput('out', width: planeW * planeH * 8);

    final body = input('body');
    final above = input('above');
    final below = input('below');

    Logic bodyAt(int row, int col) {
      final k = row * planeW + col;
      return body.getRange(k * 8, k * 8 + 8);
    }

    Logic aboveAt(int ctx, int col) {
      final k = ctx * planeW + col;
      return above.getRange(k * 8, k * 8 + 8);
    }

    Logic belowAt(int ctx, int col) {
      final k = ctx * planeW + col;
      return below.getRange(k * 8, k * 8 + 8);
    }

    int hclamp(int c) => c < 0 ? 0 : (c >= planeW ? planeW - 1 : c);

    // Output pixel slices, row-major over the plane region.
    final outPlane = List<Logic?>.filled(
      planeH * planeW,
      null,
      growable: false,
    );

    for (var u = 0; u < units; u++) {
      // Assemble the (pw x ph) padded region for this unit, row-major LSB-first
      // to match HarborLrUnit's `padded` packing (body (0,0) at padded (3,3)).
      final region = <Logic>[];
      for (var r = 0; r < ph; r++) {
        final bodyRow = r - restorationBorder; // -3 .. height+2
        for (var c = 0; c < pw; c++) {
          final planeCol = hclamp(u * width + c - restorationBorder);
          Logic px;
          if (bodyRow < 0) {
            // above stripe boundary swap (ctx0 for body -3,-2, ctx1 for -1).
            final ctx = (bodyRow + restorationCtxVert) <= 0 ? 0 : 1;
            px = aboveAt(ctx, planeCol);
          } else if (bodyRow >= height) {
            // below stripe boundary swap (ctx0 for body height, ctx1 for +1,+2).
            final i = bodyRow - height; // 0,1,2
            final ctx = i < 1 ? 0 : 1;
            px = belowAt(ctx, planeCol);
          } else {
            px = bodyAt(bodyRow, planeCol);
          }
          region.add(px);
        }
      }
      final padded = region.reversed.toList().concat();

      final unit = HarborLrUnit(width: width, height: height, name: 'lru_$u');
      addSubModule(unit);
      unit.input('padded').srcConnection! <= padded;
      unit.input('rtype').srcConnection! <= input('rtype$u');
      unit.input('h0').srcConnection! <= input('h0_$u');
      unit.input('h1').srcConnection! <= input('h1_$u');
      unit.input('h2').srcConnection! <= input('h2_$u');
      unit.input('v0').srcConnection! <= input('v0_$u');
      unit.input('v1').srcConnection! <= input('v1_$u');
      unit.input('v2').srcConnection! <= input('v2_$u');
      unit.input('s0').srcConnection! <= input('s0_$u');
      unit.input('s1').srcConnection! <= input('s1_$u');
      unit.input('xq0').srcConnection! <= input('xq0_$u');
      unit.input('xq1').srcConnection! <= input('xq1_$u');
      final uOut = unit.output('out'); // packs (i,j) at i*width + j, 8b each.

      // Scatter the unit's body output into the plane columns it owns.
      for (var i = 0; i < height; i++) {
        for (var j = 0; j < width; j++) {
          final uk = i * width + j;
          final px = uOut.getRange(uk * 8, uk * 8 + 8);
          outPlane[i * planeW + (u * width + j)] = px;
        }
      }
    }

    final outParts = [for (final p in outPlane) p!];
    output('out') <= outParts.reversed.toList().concat();
  }
}
