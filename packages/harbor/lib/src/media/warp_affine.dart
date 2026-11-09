import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 warped-motion affine predictor (libaom
/// `av1_warp_affine_c`, single-prediction / non-compound path), bitDepth 8,
/// subX=subY=0. Combinational. Produces one 8x8 predicted luma block.
///
/// This implements the inner per-8x8 loop only: the caller supplies the warp
/// shear params (`alpha`/`beta`/`gamma`/`delta`) and the masked sub-pixel base
/// coordinates (`sx4`/`sy4`), i.e. the values the inner loop holds *after*
/// `sx4 += alpha*-4 + beta*-4` then `sx4 &= ~63` (and likewise for `sy4`). The
/// block integer source position (`ix4`,`iy4`) is absorbed into the reference
/// patch geometry (below). `setup`/`get_shear` are out of scope.
///
/// Patch geometry (the load-bearing mapping):
/// The horizontal pass reads `ref[clamp(iy4+k,0,H-1)][clamp(ix4+m+l-3,0,W-1)]`
/// for k in -7..7, l in -4..3, m in 0..7, so the reachable, edge-clamped support
/// is rows `iy4-7 .. iy4+7` and cols `ix4-7 .. ix4+7`: a 15x15 window. The caller
/// must pre-apply the AV1 edge replication and pass that 15x15 patch as
///   `patch[r][c] = ref[clamp(iy4 - 7 + r, 0, H-1)][clamp(ix4 - 7 + c, 0, W-1)]`
/// for r,c in 0..14. Hence `patch[7][7]` is the block-origin integer source
/// sample `ref[iy4][ix4]`. Inside the module the patch is indexed directly with
/// no further clamping (the caller already did the frame clamp), exactly
/// reproducing the SW reads:
///   horizontal tmp[k+7][l+4] sums patch[k+7][m + l + 4] over m=0..7,
///   vertical out[k+4][l+4]   sums tmp[(k+m+4)][l+4]    over m=0..7.
/// `patch` packs sample (r,c) row-major LSB-first at bit `(r*15 + c)*8`.
///
/// Phase indexing (per the SW):
///   horizontal phase for (k,l): `offs = ((sx + 512) >> 10) + 64`,
///     `sx = sx4 + beta*(k+4) + alpha*l` (arithmetic, signed),
///   vertical phase for k:        `offs = ((sy + 512) >> 10) + 64`,
///     `sy = sy4 + delta*(k+4)`.
/// `offs` indexes the 193-row `kWarpedFilter` table (0..192). A per-tap ROM mux
/// over the 193 rows selects the 8 signed taps.
///
/// Rounding (single-pred, bd8): ROUND0 = 3 (reduce_bits_horiz), ROUND1 = 11
/// (reduce_bits_vert), offset_bits_horiz = 14, offset_bits_vert = 19. The
/// horizontal accumulator seeds at `1<<14` and right-shifts by 3 (always
/// non-negative, <= 13b). The vertical accumulator seeds at `1<<19`, right-shifts
/// by 11, then subtracts `(1<<7) + (1<<8)` and clips to [0,255].
///
/// Arithmetic widths: signed working width `_wH`=24 for the horizontal stage
/// (products `coeff*pixel` up to +/-4590, biased accumulator in [4399, 61009]),
/// `_wV`=28 for the vertical stage (products `coeff*tmp` up to +/-137268, biased
/// accumulator in [262116, 1832988]). The phase datapath uses signed width
/// `_wP`=24 (|sx| can reach ~1.0e6 over the swept param range).
class HarborWarpAffine extends BridgeModule {
  /// 193x8 libaom warped-motion filter (`av1_warped_filter` / `kWarpedFilter`),
  /// transcribed verbatim. Row index is the warp phase `offs` (0..192). Each row
  /// is 8 signed taps summing to 128.
  static const List<List<int>> kWarpedFilter = [
    [0, 0, 127, 1, 0, 0, 0, 0],
    [0, -1, 127, 2, 0, 0, 0, 0],
    [1, -3, 127, 4, -1, 0, 0, 0],
    [1, -4, 126, 6, -2, 1, 0, 0],
    [1, -5, 126, 8, -3, 1, 0, 0],
    [1, -6, 125, 11, -4, 1, 0, 0],
    [1, -7, 124, 13, -4, 1, 0, 0],
    [2, -8, 123, 15, -5, 1, 0, 0],
    [2, -9, 122, 18, -6, 1, 0, 0],
    [2, -10, 121, 20, -6, 1, 0, 0],
    [2, -11, 120, 22, -7, 2, 0, 0],
    [2, -12, 119, 25, -8, 2, 0, 0],
    [3, -13, 117, 27, -8, 2, 0, 0],
    [3, -13, 116, 29, -9, 2, 0, 0],
    [3, -14, 114, 32, -10, 3, 0, 0],
    [3, -15, 113, 35, -10, 2, 0, 0],
    [3, -15, 111, 37, -11, 3, 0, 0],
    [3, -16, 109, 40, -11, 3, 0, 0],
    [3, -16, 108, 42, -12, 3, 0, 0],
    [4, -17, 106, 45, -13, 3, 0, 0],
    [4, -17, 104, 47, -13, 3, 0, 0],
    [4, -17, 102, 50, -14, 3, 0, 0],
    [4, -17, 100, 52, -14, 3, 0, 0],
    [4, -18, 98, 55, -15, 4, 0, 0],
    [4, -18, 96, 58, -15, 3, 0, 0],
    [4, -18, 94, 60, -16, 4, 0, 0],
    [4, -18, 91, 63, -16, 4, 0, 0],
    [4, -18, 89, 65, -16, 4, 0, 0],
    [4, -18, 87, 68, -17, 4, 0, 0],
    [4, -18, 85, 70, -17, 4, 0, 0],
    [4, -18, 82, 73, -17, 4, 0, 0],
    [4, -18, 80, 75, -17, 4, 0, 0],
    [4, -18, 78, 78, -18, 4, 0, 0],
    [4, -17, 75, 80, -18, 4, 0, 0],
    [4, -17, 73, 82, -18, 4, 0, 0],
    [4, -17, 70, 85, -18, 4, 0, 0],
    [4, -17, 68, 87, -18, 4, 0, 0],
    [4, -16, 65, 89, -18, 4, 0, 0],
    [4, -16, 63, 91, -18, 4, 0, 0],
    [4, -16, 60, 94, -18, 4, 0, 0],
    [3, -15, 58, 96, -18, 4, 0, 0],
    [4, -15, 55, 98, -18, 4, 0, 0],
    [3, -14, 52, 100, -17, 4, 0, 0],
    [3, -14, 50, 102, -17, 4, 0, 0],
    [3, -13, 47, 104, -17, 4, 0, 0],
    [3, -13, 45, 106, -17, 4, 0, 0],
    [3, -12, 42, 108, -16, 3, 0, 0],
    [3, -11, 40, 109, -16, 3, 0, 0],
    [3, -11, 37, 111, -15, 3, 0, 0],
    [2, -10, 35, 113, -15, 3, 0, 0],
    [3, -10, 32, 114, -14, 3, 0, 0],
    [2, -9, 29, 116, -13, 3, 0, 0],
    [2, -8, 27, 117, -13, 3, 0, 0],
    [2, -8, 25, 119, -12, 2, 0, 0],
    [2, -7, 22, 120, -11, 2, 0, 0],
    [1, -6, 20, 121, -10, 2, 0, 0],
    [1, -6, 18, 122, -9, 2, 0, 0],
    [1, -5, 15, 123, -8, 2, 0, 0],
    [1, -4, 13, 124, -7, 1, 0, 0],
    [1, -4, 11, 125, -6, 1, 0, 0],
    [1, -3, 8, 126, -5, 1, 0, 0],
    [1, -2, 6, 126, -4, 1, 0, 0],
    [0, -1, 4, 127, -3, 1, 0, 0],
    [0, 0, 2, 127, -1, 0, 0, 0],
    [0, 0, 0, 127, 1, 0, 0, 0],
    [0, 0, -1, 127, 2, 0, 0, 0],
    [0, 1, -3, 127, 4, -2, 1, 0],
    [0, 1, -5, 127, 6, -2, 1, 0],
    [0, 2, -6, 126, 8, -3, 1, 0],
    [-1, 2, -7, 126, 11, -4, 2, -1],
    [-1, 3, -8, 125, 13, -5, 2, -1],
    [-1, 3, -10, 124, 16, -6, 3, -1],
    [-1, 4, -11, 123, 18, -7, 3, -1],
    [-1, 4, -12, 122, 20, -7, 3, -1],
    [-1, 4, -13, 121, 23, -8, 3, -1],
    [-2, 5, -14, 120, 25, -9, 4, -1],
    [-1, 5, -15, 119, 27, -10, 4, -1],
    [-1, 5, -16, 118, 30, -11, 4, -1],
    [-2, 6, -17, 116, 33, -12, 5, -1],
    [-2, 6, -17, 114, 35, -12, 5, -1],
    [-2, 6, -18, 113, 38, -13, 5, -1],
    [-2, 7, -19, 111, 41, -14, 6, -2],
    [-2, 7, -19, 110, 43, -15, 6, -2],
    [-2, 7, -20, 108, 46, -15, 6, -2],
    [-2, 7, -20, 106, 49, -16, 6, -2],
    [-2, 7, -21, 104, 51, -16, 7, -2],
    [-2, 7, -21, 102, 54, -17, 7, -2],
    [-2, 8, -21, 100, 56, -18, 7, -2],
    [-2, 8, -22, 98, 59, -18, 7, -2],
    [-2, 8, -22, 96, 62, -19, 7, -2],
    [-2, 8, -22, 94, 64, -19, 7, -2],
    [-2, 8, -22, 91, 67, -20, 8, -2],
    [-2, 8, -22, 89, 69, -20, 8, -2],
    [-2, 8, -22, 87, 72, -21, 8, -2],
    [-2, 8, -21, 84, 74, -21, 8, -2],
    [-2, 8, -22, 82, 77, -21, 8, -2],
    [-2, 8, -21, 79, 79, -21, 8, -2],
    [-2, 8, -21, 77, 82, -22, 8, -2],
    [-2, 8, -21, 74, 84, -21, 8, -2],
    [-2, 8, -21, 72, 87, -22, 8, -2],
    [-2, 8, -20, 69, 89, -22, 8, -2],
    [-2, 8, -20, 67, 91, -22, 8, -2],
    [-2, 7, -19, 64, 94, -22, 8, -2],
    [-2, 7, -19, 62, 96, -22, 8, -2],
    [-2, 7, -18, 59, 98, -22, 8, -2],
    [-2, 7, -18, 56, 100, -21, 8, -2],
    [-2, 7, -17, 54, 102, -21, 7, -2],
    [-2, 7, -16, 51, 104, -21, 7, -2],
    [-2, 6, -16, 49, 106, -20, 7, -2],
    [-2, 6, -15, 46, 108, -20, 7, -2],
    [-2, 6, -15, 43, 110, -19, 7, -2],
    [-2, 6, -14, 41, 111, -19, 7, -2],
    [-1, 5, -13, 38, 113, -18, 6, -2],
    [-1, 5, -12, 35, 114, -17, 6, -2],
    [-1, 5, -12, 33, 116, -17, 6, -2],
    [-1, 4, -11, 30, 118, -16, 5, -1],
    [-1, 4, -10, 27, 119, -15, 5, -1],
    [-1, 4, -9, 25, 120, -14, 5, -2],
    [-1, 3, -8, 23, 121, -13, 4, -1],
    [-1, 3, -7, 20, 122, -12, 4, -1],
    [-1, 3, -7, 18, 123, -11, 4, -1],
    [-1, 3, -6, 16, 124, -10, 3, -1],
    [-1, 2, -5, 13, 125, -8, 3, -1],
    [-1, 2, -4, 11, 126, -7, 2, -1],
    [0, 1, -3, 8, 126, -6, 2, 0],
    [0, 1, -2, 6, 127, -5, 1, 0],
    [0, 1, -2, 4, 127, -3, 1, 0],
    [0, 0, 0, 2, 127, -1, 0, 0],
    [0, 0, 0, 1, 127, 0, 0, 0],
    [0, 0, 0, -1, 127, 2, 0, 0],
    [0, 0, 1, -3, 127, 4, -1, 0],
    [0, 0, 1, -4, 126, 6, -2, 1],
    [0, 0, 1, -5, 126, 8, -3, 1],
    [0, 0, 1, -6, 125, 11, -4, 1],
    [0, 0, 1, -7, 124, 13, -4, 1],
    [0, 0, 2, -8, 123, 15, -5, 1],
    [0, 0, 2, -9, 122, 18, -6, 1],
    [0, 0, 2, -10, 121, 20, -6, 1],
    [0, 0, 2, -11, 120, 22, -7, 2],
    [0, 0, 2, -12, 119, 25, -8, 2],
    [0, 0, 3, -13, 117, 27, -8, 2],
    [0, 0, 3, -13, 116, 29, -9, 2],
    [0, 0, 3, -14, 114, 32, -10, 3],
    [0, 0, 3, -15, 113, 35, -10, 2],
    [0, 0, 3, -15, 111, 37, -11, 3],
    [0, 0, 3, -16, 109, 40, -11, 3],
    [0, 0, 3, -16, 108, 42, -12, 3],
    [0, 0, 4, -17, 106, 45, -13, 3],
    [0, 0, 4, -17, 104, 47, -13, 3],
    [0, 0, 4, -17, 102, 50, -14, 3],
    [0, 0, 4, -17, 100, 52, -14, 3],
    [0, 0, 4, -18, 98, 55, -15, 4],
    [0, 0, 4, -18, 96, 58, -15, 3],
    [0, 0, 4, -18, 94, 60, -16, 4],
    [0, 0, 4, -18, 91, 63, -16, 4],
    [0, 0, 4, -18, 89, 65, -16, 4],
    [0, 0, 4, -18, 87, 68, -17, 4],
    [0, 0, 4, -18, 85, 70, -17, 4],
    [0, 0, 4, -18, 82, 73, -17, 4],
    [0, 0, 4, -18, 80, 75, -17, 4],
    [0, 0, 4, -18, 78, 78, -18, 4],
    [0, 0, 4, -17, 75, 80, -18, 4],
    [0, 0, 4, -17, 73, 82, -18, 4],
    [0, 0, 4, -17, 70, 85, -18, 4],
    [0, 0, 4, -17, 68, 87, -18, 4],
    [0, 0, 4, -16, 65, 89, -18, 4],
    [0, 0, 4, -16, 63, 91, -18, 4],
    [0, 0, 4, -16, 60, 94, -18, 4],
    [0, 0, 3, -15, 58, 96, -18, 4],
    [0, 0, 4, -15, 55, 98, -18, 4],
    [0, 0, 3, -14, 52, 100, -17, 4],
    [0, 0, 3, -14, 50, 102, -17, 4],
    [0, 0, 3, -13, 47, 104, -17, 4],
    [0, 0, 3, -13, 45, 106, -17, 4],
    [0, 0, 3, -12, 42, 108, -16, 3],
    [0, 0, 3, -11, 40, 109, -16, 3],
    [0, 0, 3, -11, 37, 111, -15, 3],
    [0, 0, 2, -10, 35, 113, -15, 3],
    [0, 0, 3, -10, 32, 114, -14, 3],
    [0, 0, 2, -9, 29, 116, -13, 3],
    [0, 0, 2, -8, 27, 117, -13, 3],
    [0, 0, 2, -8, 25, 119, -12, 2],
    [0, 0, 2, -7, 22, 120, -11, 2],
    [0, 0, 1, -6, 20, 121, -10, 2],
    [0, 0, 1, -6, 18, 122, -9, 2],
    [0, 0, 1, -5, 15, 123, -8, 2],
    [0, 0, 1, -4, 13, 124, -7, 1],
    [0, 0, 1, -4, 11, 125, -6, 1],
    [0, 0, 1, -3, 8, 126, -5, 1],
    [0, 0, 1, -2, 6, 126, -4, 1],
    [0, 0, 0, -1, 4, 127, -3, 1],
    [0, 0, 0, 0, 2, 127, -1, 0],
    [0, 0, 0, 0, 2, 127, -1, 0],
  ];

  // Single-prediction bd8 constants.
  static const int _bd = 8;
  static const int _filterBits = 7;
  static const int _round0 = 3; // reduce_bits_horiz
  static const int _round1 = 2 * _filterBits - _round0; // 11, reduce_bits_vert
  static const int _offsetBitsHoriz = _bd + _filterBits - 1; // 14
  static const int _offsetBitsVert = _bd + 2 * _filterBits - _round0; // 19
  static const int _warpedDiffPrecBits = 10; // 16 - 6
  static const int _warpedPixelPrecShifts = 64; // 1 << 6

  // Working widths.
  static const int _wH = 24; // horizontal stage signed accumulator width
  static const int _wV = 28; // vertical stage signed accumulator width
  static const int _wP = 24; // phase-datapath signed width

  HarborWarpAffine({String? name})
    : super('HarborWarpAffine', name: name ?? 'warp_affine') {
    // 15x15 edge-clamped reference patch (see class doc for geometry).
    createPort('patch', PortDirection.input, width: 15 * 15 * 8);
    // Masked sub-pixel base coords (signed, the post `&= ~63` inner-loop value).
    createPort('sx4', PortDirection.input, width: 20);
    createPort('sy4', PortDirection.input, width: 20);
    // Signed warp shear params (int16 range).
    createPort('alpha', PortDirection.input, width: 16);
    createPort('beta', PortDirection.input, width: 16);
    createPort('gamma', PortDirection.input, width: 16);
    createPort('delta', PortDirection.input, width: 16);
    // 8x8 predicted block, 8b pixels, packed (oy*8 + ox) LSB-first.
    addOutput('pred', width: 8 * 8 * 8);

    final patch = input('patch');
    final sx4 = input('sx4').signExtend(_wP);
    final sy4 = input('sy4').signExtend(_wP);
    final alpha = input('alpha').signExtend(_wP);
    final beta = input('beta').signExtend(_wP);
    final gamma = input('gamma').signExtend(_wP);
    final delta = input('delta').signExtend(_wP);

    // patch access.
    Logic patchAt(int r, int c) {
      final base = (r * 15 + c) * 8;
      return patch.getRange(base, base + 8);
    }

    // phase datapath (signed width _wP).
    Logic constP(int v) => Const(BigInt.from(v).toUnsigned(_wP), width: _wP);
    Logic addP(Logic a, Logic b) => (a + b).getRange(0, _wP);
    Logic mulP(Logic a, Logic b) => (a * b).getRange(0, _wP);
    Logic asrP(Logic x, int n) =>
        [x[_wP - 1].replicate(n), x.getRange(n, _wP)].concat();

    // offs = ((sx + 512) >> 10) + 64, arithmetic. Result is 0..192 for valid
    // streams. Slice to an 8b index (covers 0..255, table guards 0..192).
    Logic phaseIndex(Logic sx) {
      final shifted = asrP(
        addP(sx, constP(1 << (_warpedDiffPrecBits - 1))),
        _warpedDiffPrecBits,
      );
      final offs = addP(shifted, constP(_warpedPixelPrecShifts));
      return offs.getRange(0, 8);
    }

    // horizontal stage (signed width _wH).
    Logic tapH(int v) => Const(BigInt.from(v).toUnsigned(_wH), width: _wH);
    Logic pxH(int r, int c) => patchAt(r, c).zeroExtend(_wH);
    Logic mulH(Logic a, Logic b) => (a * b).getRange(0, _wH);
    Logic addCH(Logic x, int c) =>
        (x + Const(BigInt.from(c).toUnsigned(_wH), width: _wH)).getRange(
          0,
          _wH,
        );
    Logic asrH(Logic x, int n) =>
        [x[_wH - 1].replicate(n), x.getRange(n, _wH)].concat();

    // Select the 8 taps for a phase index from the 193-row table (width _wH).
    List<Logic> tapsH(Logic phase) {
      final out = <Logic>[];
      for (var m = 0; m < 8; m++) {
        Logic acc = tapH(kWarpedFilter[192][m]);
        for (var p = 191; p >= 0; p--) {
          acc = mux(
            phase.eq(Const(p, width: 8)),
            tapH(kWarpedFilter[p][m]),
            acc,
          );
        }
        out.add(acc);
      }
      return out;
    }

    // tmp[kk][ll] for kk=k+7 (0..14), ll=l+4 (0..7).
    // sx = sx4 + beta*(k+4) + alpha*l, offs from sx, sum patch[kk][m+ll].
    final tmp = <List<Logic>>[]; // [15][8], each width _wH
    for (var k = -7; k < 8; k++) {
      final kk = k + 7;
      final row = <Logic>[];
      for (var l = -4; l < 4; l++) {
        final ll = l + 4;
        // sx for (k,l): the SW seeds sx = sx4 + beta*(k+4) at l=-4 then does
        // sx += alpha per column, so column ll has alpha applied ll times.
        final sx = addP(
          addP(sx4, mulP(beta, constP(k + 4))),
          mulP(alpha, constP(ll)),
        );
        final taps = tapsH(phaseIndex(sx));
        Logic acc = Const(1 << _offsetBitsHoriz, width: _wH);
        for (var m = 0; m < 8; m++) {
          acc = (acc + mulH(taps[m], pxH(kk, m + ll))).getRange(0, _wH);
        }
        // (acc + 4) >> 3, always non-negative here.
        row.add(asrH(addCH(acc, 1 << (_round0 - 1)), _round0));
      }
      tmp.add(row);
    }

    // vertical stage (signed width _wV).
    Logic tapV(int v) => Const(BigInt.from(v).toUnsigned(_wV), width: _wV);
    Logic tmpV(Logic t) => t.zeroExtend(_wV); // tmp non-negative (<= 13b)
    Logic mulV(Logic a, Logic b) => (a * b).getRange(0, _wV);
    Logic addCV(Logic x, int c) =>
        (x + Const(BigInt.from(c).toUnsigned(_wV), width: _wV)).getRange(
          0,
          _wV,
        );
    Logic asrV(Logic x, int n) =>
        [x[_wV - 1].replicate(n), x.getRange(n, _wV)].concat();

    List<Logic> tapsV(Logic phase) {
      final out = <Logic>[];
      for (var m = 0; m < 8; m++) {
        Logic acc = tapV(kWarpedFilter[192][m]);
        for (var p = 191; p >= 0; p--) {
          acc = mux(
            phase.eq(Const(p, width: 8)),
            tapV(kWarpedFilter[p][m]),
            acc,
          );
        }
        out.add(acc);
      }
      return out;
    }

    // Final clip of a signed width-_wV value to [0,255] -> 8b.
    Logic clip8(Logic v) {
      final neg = v[_wV - 1];
      final overMax = v.gt(Const(255, width: _wV));
      final clamped = mux(
        neg,
        Const(0, width: _wV),
        mux(overMax, Const(255, width: _wV), v),
      );
      return clamped.getRange(0, 8);
    }

    // out[oy][ox] for oy=k+4, ox=l+4 (0..7). The SW advances the vertical phase
    // by delta per row and by gamma per column: sy = sy4 + delta*(k+4) at l=-4
    // then sy += gamma each column, i.e. sy(k,l) = sy4 + delta*(k+4) + gamma*ox.
    // sum tmp[(k+m+4)][ox] = tmp[oy+m][ox] over m=0..7.
    final outParts = <Logic>[]; // 64 pixels, index oy*8 + ox
    for (var k = -4; k < 4; k++) {
      final oy = k + 4;
      for (var l = -4; l < 4; l++) {
        final ox = l + 4;
        final sy = addP(
          addP(sy4, mulP(delta, constP(k + 4))),
          mulP(gamma, constP(ox)),
        );
        final taps = tapsV(phaseIndex(sy));
        Logic acc = Const(1 << _offsetBitsVert, width: _wV);
        for (var m = 0; m < 8; m++) {
          acc = (acc + mulV(taps[m], tmpV(tmp[oy + m][ox]))).getRange(0, _wV);
        }
        // (acc + 1024) >> 11, then - (1<<7) - (1<<8), then clip.
        var res = asrV(addCV(acc, 1 << (_round1 - 1)), _round1);
        res = addCV(res, -((1 << (_bd - 1)) + (1 << _bd)));
        outParts.add(clip8(res));
      }
    }

    // Pack output (oy*8 + ox) LSB-first row-major.
    output('pred') <= outParts.reversed.toList().concat();
  }
}
