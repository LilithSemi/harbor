import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_recon_walk.dart';
import 'keyframe_mode_walk.dart';

/// End-to-end keyframe intra decode for one 8x8 superblock with variable leaf
/// size: coded bytes to a reconstructed 8x8 luma picture, joining the mode walk
/// and recon walk on a small sequencing + mapping FSM. Handles both a
/// NONE-partition 8x8 superblock (one 8x8 leaf, TX_8X8) and the SPLIT case (four
/// 4x4 leaves), selecting the recon footprint per leaf from the decoded size.
///
/// On `start`, runs [HarborKeyframeModeWalk] (rootBsize 3, coeffPrefix, txLeaf)
/// over `bytes`. When the walk asserts done, the per-leaf arrays are latched and
/// mapped into [HarborIntraReconWalk]'s packing, then the recon walk is pulsed.
/// When recon asserts done, this module asserts `done` with the 8x8 luma `frame`.
///
/// Mapping (walk -> recon), all combinational on the latched walk outputs:
///  - `leaf_count`: direct.
///  - `log2sizes` (per leaf, 2b): recon_log2 = walk_leaf_log2size - 2 (walk
///    emits pixel log2 8x8->3, 4x4->2, recon convention 8x8->1, 4x4->0).
///  - `y_modes` / `tx_types` (4b each): direct copy.
///  - `coeffs`: each leaf's 64 dequantized 16-bit coeffs into the low 64 of
///    recon's 256-coeff slot, the upper 192 zeroed.
///  - `positions`: derived from leaf_count (NONE/SPLIT only). count 1 -> leaf 0
///    at mi (0,0). Count 4 -> leaf l at mi (l>>1, l&1), DFS = raster order. Each
///    position slot is `[l*4 +: 4]` with miRow in the low 2 bits, miCol high.
///
/// Ports: clk, reset, start, bytes (maxBytes*8), dc_q (16), ac_q (16) -> done,
/// frame (512). Out of scope on this path: tx-split depth-1 8x8 leaves and
/// HORZ/VERT partitions (the mode walk does not produce them here).
class HarborKeyframeDecodeVar extends BridgeModule {
  /// Maximum coded bytes the internal mode-walk buffer holds.
  final int maxBytes;

  /// Coeff-table q-band (0..3) for the mode walk's coeff decode.
  final int qband;

  HarborKeyframeDecodeVar({this.maxBytes = 48, this.qband = 0, String? name})
    : assert(maxBytes > 0, 'maxBytes must be positive'),
      assert(qband >= 0 && qband < 4, 'qband 0..3'),
      super('HarborKeyframeDecodeVar', name: name ?? 'keyframe_decode_var') {
    const sbSize = 8; // 8x8 superblock
    const maxLeaves = 4; // NONE (1) or SPLIT (4)
    const f = sbSize; // 8 pixels
    const nPix = f * f; // 64
    const miBits = 2; // bitLength(sbSize/4) = bitLength(2) = 2
    const cntW = 3; // (maxLeaves + 1).bitLength = 5.bitLength = 3

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    createPort('dc_q', PortDirection.input, width: 16);
    createPort('ac_q', PortDirection.input, width: 16);
    addOutput('done');
    addOutput('frame', width: nPix * 8);

    final clk = input('clk');
    final reset = input('reset');

    final walk = HarborKeyframeModeWalk(
      rootBsize: 3,
      maxBytes: maxBytes,
      coeffPrefix: true,
      txLeaf: true,
      qband: qband,
      name: 'walk',
    );
    addSubModule(walk);
    final recon = HarborIntraReconWalk(
      sbSize: sbSize,
      maxLeaves: maxLeaves,
      name: 'recon',
    );
    addSubModule(recon);

    final walkStart = Logic(name: 'walk_start');
    final reconStart = Logic(name: 'recon_start');

    walk.input('clk').srcConnection! <= clk;
    walk.input('reset').srcConnection! <= reset;
    walk.input('start').srcConnection! <= walkStart;
    walk.input('bytes').srcConnection! <= input('bytes');
    walk.input('dc_q').srcConnection! <= input('dc_q');
    walk.input('ac_q').srcConnection! <= input('ac_q');

    // latched walk outputs
    final lcCap = Logic(name: 'leaf_count_cap', width: 12);
    final l2Cap = Logic(name: 'leaf_log2size_cap', width: 4 * 3);
    final ymCap = Logic(name: 'leaf_ymodes_cap', width: 4 * 4);
    final ttCap = Logic(name: 'leaf_txtypes_cap', width: 4 * 4);
    final coeffCap = Logic(name: 'leaf_coeffs_cap', width: 4 * 64 * 16);
    final tdCap = Logic(name: 'leaf_tx_depth_cap', width: 4 * 2);
    // depth-1 per-sub-block luma ext-tx types (sub-block s at [s*4 +: 4]).
    final stxCap = Logic(name: 'leaf_sub_txtypes_cap', width: 4 * 4);

    // mapping walk -> recon (combinational on the latched values).
    // leaf_count: low cntW bits of the captured 12-bit count.
    final reconLeafCount = lcCap.getRange(0, cntW);

    // log2sizes: per leaf recon_log2 = walk_log2 - 2 (3 -> 1, 2 -> 0).
    // swizzle() takes list index 0 as the MSB, so emit leaves high-to-low to
    // land leaf 0 in the LSB slot (matching the recon's [l*2 +: 2] packing).
    final reconLog2 = [
      for (var l = maxLeaves - 1; l >= 0; l--)
        (l2Cap.getRange(l * 3, l * 3 + 3) - Const(2, width: 3)).getRange(0, 2),
    ].concat();

    // y_modes / tx_types: direct copy (4 leaves x 4 bits).
    final reconYModes = ymCap;
    final reconTxTypes = ttCap;

    // coeffs: per leaf, the 64 captured coeffs into the low 64 of a 256-slot,
    // upper 192 zeroed.
    final reconCoeffs = [
      for (var l = maxLeaves - 1; l >= 0; l--) ...[
        Const(0, width: 192 * 16),
        coeffCap.getRange(l * 64 * 16, l * 64 * 16 + 64 * 16),
      ],
    ].concat();

    // positions: const-mux by leaf_count. leaf_count == 1 -> only leaf 0 at
    // mi (0,0). leaf_count == 4 -> leaf l at mi (l>>1, l&1). Each slot is
    // [l*4 +: 4] with miRow in the low 2 bits, miCol in the high 2 bits.
    int posVal(int row, int col) => row | (col << miBits);
    final splitPositions = [
      for (var l = maxLeaves - 1; l >= 0; l--)
        Const(posVal(l >> 1, l & 1), width: 2 * miBits),
    ].concat();
    final nonePositions = Const(posVal(0, 0), width: maxLeaves * 2 * miBits);
    final reconPositions = mux(
      reconLeafCount.eq(Const(1, width: cntW)),
      nonePositions,
      splitPositions,
    );

    // tx-split (depth-1) NONE leaf expansion.
    // A depth-1 8x8 leaf (one leaf, log2 pixel size 3, tx_depth 1) is recon-
    // equivalent to FOUR 4x4 leaves that all share the leaf's single y_mode and
    // tx_type (AV1 intra-predicts per transform block, raster order, each from
    // already-reconstructed neighbours). Expand into four 4x4 recon leaves. The
    // recon walk needs no change. This is additive and mux-guarded: the NONE
    // depth-0 and SPLIT mappings above are used unchanged when not depth-1.
    final isDepth1 =
        reconLeafCount.eq(Const(1, width: cntW)) &
        l2Cap.getRange(0, 3).eq(Const(3, width: 3)) &
        tdCap.getRange(0, 2).eq(Const(1, width: 2));

    // four 4x4 leaves.
    final d1LeafCount = Const(4, width: cntW);
    // positions: same 2x2 layout as SPLIT (leaf l at mi (l>>1, l&1)).
    final d1Positions = splitPositions;
    // log2sizes: all 0 (4x4).
    final d1Log2 = Const(0, width: maxLeaves * 2);
    // y_modes: leaf 0's value replicated to all four leaves (one luma mode for
    // the whole 8x8 SB). tx_types: each recon leaf l (= raster sub-block l) gets
    // its OWN sub-block tx_type from leaf_sub_txtypes[l*4 +: 4], so a non-uniform
    // depth-1 leaf is bit-exact (no replication of a single tx_type).
    final ym0 = ymCap.getRange(0, 4);
    final d1YModes = [for (var l = 0; l < maxLeaves; l++) ym0].concat();
    // swizzle list index 0 = MSB. Emit leaf 3 down to 0 so leaf l lands at
    // [l*4 +: 4], matching the recon's tx_types packing and stxCap's layout.
    final d1TxTypes = [
      for (var l = maxLeaves - 1; l >= 0; l--)
        stxCap.getRange(l * 4, l * 4 + 4),
    ].concat();
    // coeffs: de-interleave the 64-slot of leaf 0 into four 16-coeff 4x4-raster
    // blocks. recon leaf l (rowOff = l>>1, colOff = l&1) coeff (r4*4 + c4) =
    // slot64[(rowOff*4 + r4)*8 + (colOff*4 + c4)]. Pack each into the low 16 of
    // a 256-coeff slot (upper 240 zeroed), matching reconCoeffs' 4x4 packing.
    final leaf0Coeffs = coeffCap.getRange(0, 64 * 16);
    Logic d1SlotCoeff(int rowOff, int colOff, int r4, int c4) {
      final slot = (rowOff * 4 + r4) * 8 + (colOff * 4 + c4);
      return leaf0Coeffs.getRange(slot * 16, slot * 16 + 16);
    }

    final d1Coeffs = [
      for (var l = maxLeaves - 1; l >= 0; l--) ...[
        Const(0, width: 240 * 16),
        // 16 coeffs in 4x4 raster, leaf l = (rowOff = l>>1, colOff = l&1).
        // swizzle list index 0 = MSB, so emit raster index 15 down to 0.
        [
          for (var i = 15; i >= 0; i--)
            d1SlotCoeff(l >> 1, l & 1, i >> 2, i & 3),
        ].concat(),
      ],
    ].concat();

    // mux every recon input by the depth-1 detection.
    final muxLeafCount = mux(isDepth1, d1LeafCount, reconLeafCount);
    final muxPositions = mux(isDepth1, d1Positions, reconPositions);
    final muxLog2 = mux(isDepth1, d1Log2, reconLog2);
    final muxYModes = mux(isDepth1, d1YModes, reconYModes);
    final muxTxTypes = mux(isDepth1, d1TxTypes, reconTxTypes);
    final muxCoeffs = mux(isDepth1, d1Coeffs, reconCoeffs);

    recon.input('clk').srcConnection! <= clk;
    recon.input('reset').srcConnection! <= reset;
    recon.input('start').srcConnection! <= reconStart;
    recon.input('leaf_count').srcConnection! <= muxLeafCount;
    recon.input('positions').srcConnection! <= muxPositions;
    recon.input('log2sizes').srcConnection! <= muxLog2;
    recon.input('y_modes').srcConnection! <= muxYModes;
    recon.input('tx_types').srcConnection! <= muxTxTypes;
    recon.input('coeffs').srcConnection! <= muxCoeffs;

    output('frame') <= recon.output('frame');

    // sequencing FSM
    const sIdle = 0,
        sRunMode = 1,
        sLatch = 2,
        sRunRecon = 3,
        sReconWait = 4,
        sDone = 5;
    final st = Logic(name: 'st', width: 3);
    output('done') <= st.eq(Const(sDone, width: 3));

    Combinational([
      walkStart < Const(0),
      reconStart < Const(0),
      Case(st, [
        // pulse the mode-walk start for exactly one cycle leaving idle.
        CaseItem(Const(sIdle, width: 3), [
          If(input('start'), then: [walkStart < Const(1)]),
        ]),
        // pulse the recon start for exactly one cycle in sRunRecon.
        CaseItem(Const(sRunRecon, width: 3), [reconStart < Const(1)]),
      ]),
    ]);

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: 3),
          lcCap < Const(0, width: 12),
          l2Cap < Const(0, width: 4 * 3),
          ymCap < Const(0, width: 4 * 4),
          ttCap < Const(0, width: 4 * 4),
          coeffCap < Const(0, width: 4 * 64 * 16),
          tdCap < Const(0, width: 4 * 2),
          stxCap < Const(0, width: 4 * 4),
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(sIdle, width: 3), [
              If(input('start'), then: [st < Const(sRunMode, width: 3)]),
            ]),
            CaseItem(Const(sRunMode, width: 3), [
              If(walk.output('done'), then: [st < Const(sLatch, width: 3)]),
            ]),
            // walk outputs are stable while it holds done. Latch leaves.
            CaseItem(Const(sLatch, width: 3), [
              lcCap < walk.output('leaf_count'),
              l2Cap < walk.output('leaf_log2size'),
              ymCap < walk.output('leaf_ymodes'),
              ttCap < walk.output('leaf_txtypes'),
              coeffCap < walk.output('leaf_coeffs'),
              tdCap < walk.output('leaf_tx_depth'),
              stxCap < walk.output('leaf_sub_txtypes'),
              st < Const(sRunRecon, width: 3),
            ]),
            CaseItem(Const(sRunRecon, width: 3), [
              st < Const(sReconWait, width: 3),
            ]),
            CaseItem(Const(sReconWait, width: 3), [
              If(recon.output('done'), then: [st < Const(sDone, width: 3)]),
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
