import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 coefficient-decode context derivation (libaom
/// `txb_common.h` / `decodetxb.c`).
///
/// Given the partially-decoded `levels` buffer (the padded column-major
/// magnitude map, clipped 0..255 per entry) and a scan position, this computes
/// every entropy context the coefficient reader needs:
/// - `base_ctx_2d`  : get_lower_levels_ctx_2d (TX_CLASS_2D fast path)
/// - `base_ctx_gen` : get_lower_levels_ctx (general / HORIZ / VERT, and c==0)
/// - `base_eob_ctx` : get_lower_levels_ctx_eob (the eob-1 coefficient)
/// - `br_ctx_2d`    : get_br_ctx_2d
/// - `br_ctx_gen`   : get_br_ctx
/// - `br_ctx_eob`   : get_br_ctx_eob
///
/// The neighbour template, the `min(level,3)` / `min(level,15)` clips, the
/// `(stats+1)>>1` cap-4 / `(mag+1)>>1` cap-6 reductions, the per-position 2D
/// offset table, the 1D class offsets, and the +7/+14 region terms all match
/// libaom exactly. [txSize] (TX_4X4 or TX_8X8 for now) fixes `bhl`, the stride,
/// the buffer length and the 2D offset ROM at build time.
///
/// `levels` packs entry i at `[i*8 +: 8]`. `coeff_idx` is the raster (column-
/// major) scan position `pos`. `scan_idx` is c (the index in scan order, for the
/// eob context). `tx_class` selects 2D(0)/HORIZ(1)/VERT(2) for the general
/// paths. Combinational.
class HarborCoeffContext extends BridgeModule {
  /// libaom TX_SIZE. The square sizes TX_4X4..TX_64X64 (0..4) and the
  /// rectangular sizes TX_4X8/8X4/8X16/16X8/4X16/16X4 (5,6,7,8,13,14) plus the
  /// tall TX_16X32/TX_8X32 (9,15) are supported.
  final int txSize;

  /// Level-read mechanism.
  ///
  /// - `false` (default): the whole padded `levels` magnitude map is a
  ///   combinational input bus and each template neighbour is selected by a
  ///   full-width mux over it. Byte-identical to the original design, used by
  ///   the verified intra decoder path (keyframe_mode_walk / coeff_levels).
  /// - `true`: the level buffer becomes an addressed memory owned by this
  ///   module. The caller drives a single write port (`wr_en`/`wr_idx`/
  ///   `wr_val`, `clear`) one cell per cycle. The ~9 template neighbours and
  ///   `cur_level` are addressed reads that simulate as O(1) array indexes
  ///   instead of an N-way combinational mux. The context arithmetic below is
  ///   identical either way. Only the level READ changes. This makes the
  ///   large transforms (TX_32X32 / TX_64X64, N = 1024 / 4096) tractable to
  ///   simulate. For silicon this addressed buffer maps to a flop RegisterFile
  ///   / RAM macro (same read/write ports). The behavioural model here is the
  ///   fast simulation equivalent.
  final bool memBacked;

  // adjusted (64->32 clamped) geometry per supported TX_SIZE.
  static const _bhlFor = {
    0: 2, 1: 3, 2: 4, 3: 5, 4: 5, //
    5: 3, 6: 2, 7: 4, 8: 3, 13: 4, 14: 2, 9: 5, 15: 5,
  };
  static const _widthFor = {
    0: 4, 1: 8, 2: 16, 3: 32, 4: 32, //
    5: 4, 6: 8, 7: 8, 8: 16, 13: 4, 14: 16, 9: 16, 15: 8,
  };

  // av1_nz_map_ctx_offset for the rectangular sizes (the square sizes use the
  // band formula). Indexed by the column-major coeff position, transposed reuse
  // matches libaom's _av1NzMapCtxOffset[txSize] mapping (e.g. TX_8X4 -> 16x4).
  static const _off4x8 = [
    0, 11, 6, 6, 21, 21, 21, 21, 11, 11, 6, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 11, 11, 21, 21, 21, 21, 21, 21,
  ];
  static const _off16x4 = [
    0, 16, 16, 16, 16, 16, 16, 16, 6, 6, 21, 21, 6, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21,
  ];
  static const _off4x16 = [
    0, 11, 6, 6, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 6, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21,
  ];
  static const _off8x16 = [
    0, 11, 6, 6, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 6, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21,
  ];
  static const _off32x8 = [
    0, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, //
    6, 6, 21, 21, 21, 21, 21, 21, 6, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21,
  ];
  static const _off16x32 = [
    0, 11, 6, 6, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 6, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21,
  ];
  static const _off8x32 = [
    0, 11, 6, 6, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 6, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    11, 11, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, //
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21,
  ];
  static const _rectOffsetFor = {
    5: _off4x8,
    6: _off16x4,
    7: _off8x16,
    8: _off32x8,
    13: _off4x16,
    14: _off16x4,
    9: _off16x32,
    15: _off8x32,
  };
  // nz_map_ctx_offset_1d[32] = {26, 31, 36, 36, ...36}.
  static const _nzMapCtxOffset1d = [
    26, 31, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, //
    36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36,
  ];
  // The 2D per-position offset is banded by the anti-diagonal: for square sizes
  // `av1_nz_map_ctx_offset_NxN[idx] = NZ_2D_BAND[min(row + col, 4)]` exactly.
  static const _nz2dBand = [0, 1, 6, 6, 21];

  HarborCoeffContext({
    required this.txSize,
    this.memBacked = false,
    String? name,
  }) : assert(_bhlFor[txSize] != null, 'unsupported TX_SIZE'),
       super(
         'HarborCoeffContext_T${txSize}_M${memBacked ? 1 : 0}',
         name: name ?? 'coeff_ctx_$txSize',
       ) {
    const txPadHor = 4, txPadHorLog2 = 2;
    final bhl = _bhlFor[txSize]!;
    final width = _widthFor[txSize]!;
    final stride = (1 << bhl) + txPadHor;
    final height = 1 << bhl;
    final n = width * height; // coefficients (adjusted)
    // levels buffer length (matches libaom: (h+TX_PAD_HOR)*(w+TX_PAD_VER)+END).
    final bufLen = (height + txPadHor) * (width + 4) + 16;

    final posW = (n - 1).bitLength;
    createPort('coeff_idx', PortDirection.input, width: posW);
    createPort('scan_idx', PortDirection.input, width: posW + 1);
    createPort('tx_class', PortDirection.input, width: 2);
    addOutput('base_ctx_2d', width: 6);
    addOutput('base_ctx_gen', width: 6);
    addOutput('base_eob_ctx', width: 2);
    addOutput('br_ctx_2d', width: 5);
    addOutput('br_ctx_gen', width: 5);
    addOutput('br_ctx_eob', width: 4);

    final ci = input('coeff_idx');
    final txClass = input('tx_class');
    final is2d = txClass.eq(Const(0, width: 2));
    final isHoriz = txClass.eq(Const(1, width: 2));
    final isVert = txClass.eq(Const(2, width: 2));

    // col = ci >> bhl, row = ci - (col << bhl), base = col*stride + row.
    final aw = posW + 6; // address width with headroom
    final col = ci.getRange(bhl, posW).zeroExtend(aw);
    final row = ci.getRange(0, bhl).zeroExtend(aw);
    final base = (col * Const(stride, width: aw) + row).getRange(0, aw);
    final caw = (bufLen - 1).bitLength; // clamped-address width

    // lrd(off) = the (clamped) level at padded address base+off. The two
    // implementations return byte-identical values for a given buffer state.
    // They differ only in HOW the read simulates.
    final Logic Function(int off) lrd;
    if (!memBacked) {
      // whole-buffer combinational read
      createPort('levels', PortDirection.input, width: bufLen * 8);
      final levelArr = [
        for (var i = 0; i < bufLen; i++)
          input('levels').getRange(i * 8, i * 8 + 8),
      ];
      Logic selByIdx(List<Logic> arr, Logic idx) {
        Logic v = arr.last;
        for (var k = arr.length - 2; k >= 0; k--) {
          v = mux(idx.eq(Const(k, width: idx.width)), arr[k], v);
        }
        return v;
      }

      lrd = (off) {
        final addr = (base + Const(off, width: aw)).getRange(0, aw);
        final clamped = mux(
          addr.gte(Const(bufLen, width: aw)),
          Const(bufLen - 1, width: aw),
          addr,
        );
        return selByIdx(levelArr, clamped.getRange(0, caw));
      };
    } else {
      // addressed-memory read (O(1) simulation)
      // A behavioural model of the padded level buffer: a single write port
      // (one cell per cycle, plus a synchronous clear) and addressed reads
      // that index the backing store directly rather than muxing over it.
      createPort('clk', PortDirection.input, width: 1);
      createPort('reset', PortDirection.input, width: 1);
      createPort('clear', PortDirection.input, width: 1);
      createPort('wr_en', PortDirection.input, width: 1);
      createPort('wr_idx', PortDirection.input, width: posW);
      createPort('wr_val', PortDirection.input, width: 8);
      addOutput('cur_level', width: 8); // level at coeff_idx (offset 0)

      final store = List<int>.filled(bufLen, 0);
      final refreshers = <void Function()>[];
      lrd = (off) {
        final addr = (base + Const(off, width: aw)).getRange(0, aw);
        final clamped = mux(
          addr.gte(Const(bufLen, width: aw)),
          Const(bufLen - 1, width: aw),
          addr,
        );
        final caddr = clamped.getRange(0, caw);
        final data = Logic(name: 'lvl_rd', width: 8);
        void refresh() {
          final v = caddr.value;
          data.put(v.isValid ? store[v.toInt()] : 0);
        }

        // Refresh when this read's own (settled) address changes.
        caddr.glitch.listen((_) => refresh());
        refreshers.add(refresh); // and after each clocked write.
        return data;
      };

      final clk = input('clk');
      final reset = input('reset');
      final clear = input('clear');
      final wrEn = input('wr_en');
      final wrIdx = input('wr_idx');
      final wrVal = input('wr_val');
      final mask = (1 << bhl) - 1;
      clk.posedge.listen((_) {
        if (reset.previousValue == LogicValue.one ||
            clear.previousValue == LogicValue.one) {
          for (var i = 0; i < bufLen; i++) {
            store[i] = 0;
          }
        } else if (wrEn.previousValue == LogicValue.one) {
          final wi = wrIdx.previousValue!;
          final wv = wrVal.previousValue!;
          if (wi.isValid && wv.isValid) {
            final pos = wi.toInt();
            final wb = (pos & mask) + (pos >> bhl) * stride;
            if (wb < bufLen) store[wb] = wv.toInt() & 0xff;
          }
        }
        for (final r in refreshers) {
          r();
        }
      });
      output('cur_level') <= lrd(0);
    }

    Logic minK(Logic v, int k) =>
        mux(v.lt(Const(k, width: 8)), v, Const(k, width: 8));
    Logic z16(Logic v) => v.zeroExtend(16);

    // base contexts
    // get_lower_levels_ctx_2d: 5-neighbour template, min(level,3).
    final mag2d =
        (z16(minK(lrd(stride), 3)) +
                z16(minK(lrd(1), 3)) +
                z16(minK(lrd(stride + 1), 3)) +
                z16(minK(lrd((2 << bhl) + (2 << txPadHorLog2)), 3)) +
                z16(minK(lrd(2), 3)))
            .getRange(0, 16);
    final ctx2d = capCtx((mag2d + Const(1, width: 16)).getRange(0, 16), 4);
    // 2D per-position offset: square sizes use NZ_2D_BAND[min(row+col,4)], the
    // rectangular sizes use their per-position table.
    final Logic off2dRom;
    if (txSize <= 4) {
      final dd = (col + row).getRange(0, aw);
      final band = mux(
        dd.gte(Const(4, width: aw)),
        Const(4, width: 3),
        dd.getRange(0, 3),
      );
      off2dRom = romLookup(_nz2dBand, band, 6);
    } else {
      off2dRom = romLookup(_rectOffsetFor[txSize]!, ci, 6);
    }
    output('base_ctx_2d') <= (ctx2d + off2dRom).getRange(0, 6);

    // get_lower_levels_ctx (general): nz_mag depends on tx_class.
    final magCommon = (z16(minK(lrd(stride), 3)) + z16(minK(lrd(1), 3)));
    final mag2dG =
        (magCommon +
                z16(minK(lrd(stride + 1), 3)) +
                z16(minK(lrd((2 << bhl) + (2 << txPadHorLog2)), 3)) +
                z16(minK(lrd(2), 3)))
            .getRange(0, 16);
    final magVert =
        (magCommon +
                z16(minK(lrd(2), 3)) +
                z16(minK(lrd(3), 3)) +
                z16(minK(lrd(4), 3)))
            .getRange(0, 16);
    final magHoriz =
        (magCommon +
                z16(minK(lrd((2 << bhl) + (2 << txPadHorLog2)), 3)) +
                z16(minK(lrd((3 << bhl) + (3 << txPadHorLog2)), 3)) +
                z16(minK(lrd((4 << bhl) + (4 << txPadHorLog2)), 3)))
            .getRange(0, 16);
    final stats = mux(
      is2d,
      mag2dG,
      mux(isVert, magVert, magHoriz),
    ).getRange(0, 16);
    final ctxGen = capCtx((stats + Const(1, width: 16)).getRange(0, 16), 4);
    // offsets: 2d -> per-position ROM, horiz -> offset1d[col], vert -> [row].
    final off1dCol = romLookup(_nzMapCtxOffset1d, ci.getRange(bhl, posW), 6);
    final rowIdx = ci.getRange(0, bhl);
    final off1dRow = romLookup(_nzMapCtxOffset1d, rowIdx, 6);
    final genOffset = mux(is2d, off2dRom, mux(isHoriz, off1dCol, off1dRow));
    // (tx_class | coeff_idx) == 0 -> ctx 0.
    final isZeroCase = is2d & ci.eq(Const(0, width: posW));
    output('base_ctx_gen') <=
        mux(
          isZeroCase,
          Const(0, width: 6),
          (ctxGen + genOffset).getRange(0, 6),
        );

    // get_lower_levels_ctx_eob: by scan position only.
    final si = input('scan_idx');
    final wbhl = width << bhl;
    final eob1 = wbhl ~/ 8, eob2 = wbhl ~/ 4;
    output('base_eob_ctx') <=
        mux(
          si.eq(Const(0, width: si.width)),
          Const(0, width: 2),
          mux(
            si.lte(Const(eob1, width: si.width)),
            Const(1, width: 2),
            mux(
              si.lte(Const(eob2, width: si.width)),
              Const(2, width: 2),
              Const(3, width: 2),
            ),
          ),
        );

    // br contexts (pos == base)
    final rowLt2 = row.lt(Const(2, width: aw));
    final colLt2 = col.lt(Const(2, width: aw));
    final cZero = ci.eq(Const(0, width: posW));

    // get_br_ctx_2d: min(level,15) on 3 neighbours.
    final magBr2dRaw =
        (z16(minK(lrd(1), 15)) +
                z16(minK(lrd(stride), 15)) +
                z16(minK(lrd(1 + stride), 15)))
            .getRange(0, 16);
    final magBr2d = capCtx(
      (magBr2dRaw + Const(1, width: 16)).getRange(0, 16),
      6,
    );
    output('br_ctx_2d') <=
        mux(
          rowLt2 & colLt2,
          (magBr2d + Const(7, width: 6)).getRange(0, 5),
          (magBr2d + Const(14, width: 6)).getRange(0, 5),
        );

    // get_br_ctx (general): raw levels, third neighbour by class.
    final brCommon = (z16(lrd(1)) + z16(lrd(stride))).getRange(0, 16);
    final brMag2d = (brCommon + z16(lrd(stride + 1))).getRange(0, 16);
    final brMagHoriz = (brCommon + z16(lrd(stride << 1))).getRange(0, 16);
    final brMagVert = (brCommon + z16(lrd(2))).getRange(0, 16);
    final brMagSel = mux(
      is2d,
      brMag2d,
      mux(isHoriz, brMagHoriz, brMagVert),
    ).getRange(0, 16);
    final brMag = capCtx((brMagSel + Const(1, width: 16)).getRange(0, 16), 6);
    // region term: c==0 -> mag, (2d: row<2&col<2)/(horiz: col==0)/(vert: row==0)
    // -> mag+7, else mag+14.
    final near = mux(
      is2d,
      rowLt2 & colLt2,
      mux(isHoriz, col.eq(Const(0, width: aw)), row.eq(Const(0, width: aw))),
    );
    output('br_ctx_gen') <=
        mux(
          cZero,
          brMag.getRange(0, 5),
          mux(
            near,
            (brMag + Const(7, width: 6)).getRange(0, 5),
            (brMag + Const(14, width: 6)).getRange(0, 5),
          ),
        );

    // get_br_ctx_eob.
    final nearEob = mux(
      is2d,
      rowLt2 & colLt2,
      mux(isHoriz, col.eq(Const(0, width: aw)), row.eq(Const(0, width: aw))),
    );
    output('br_ctx_eob') <=
        mux(
          cZero,
          Const(0, width: 4),
          mux(nearEob, Const(7, width: 4), Const(14, width: 4)),
        );
  }

  /// (v) >> 1 then cap to `m` (the `(stats+1)>>1` cap-4 / `(mag+1)>>1` cap-6
  /// reductions share this shape, the caller pre-adds 1).
  Logic capCtx(Logic vPlus1, int m) {
    final sh = vPlus1.getRange(1, 16); // >> 1
    return mux(
      sh.gt(Const(m, width: 15)),
      Const(m, width: 6),
      sh.getRange(0, 6),
    );
  }

  /// Look up a build-time table by a runtime index, returning a `w`-bit value.
  /// The index may be narrower than the table. Only the reachable prefix is
  /// used (the trailing entries are constant in every AV1 offset table).
  Logic romLookup(List<int> table, Logic idx, int w) {
    final reach = 1 << idx.width;
    final tbl = table.length <= reach ? table : table.sublist(0, reach);
    Logic v = Const(tbl.last, width: w);
    for (var k = tbl.length - 2; k >= 0; k--) {
      v = mux(idx.eq(Const(k, width: idx.width)), Const(tbl[k], width: w), v);
    }
    return v;
  }
}
