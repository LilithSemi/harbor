import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_recon_walk.dart';
import 'keyframe_mode_walk.dart';

/// AV1 keyframe intra decode for one 16x16 superblock root (BLOCK_16X16,
/// `rootBsize` 6) that SPLITs into a 2x2 grid of four 8x8 leaves, each a
/// PARTITION_NONE leaf decoded as a single TX_8X8 block: coded bytes -> 16x16
/// luma picture. Reuses the 8x8-leaf coeff + transform + recon path with a
/// bigger root and a recon that walks the deeper partition tree.
///
/// On `start`, runs [HarborKeyframeModeWalk] (rootBsize 6, coeffPrefix, txLeaf)
/// over `bytes` with `dc_q`/`ac_q`. On a PARTITION_SPLIT root the DFS pushes
/// four 8x8 sub-blocks. Each reads its PARTITION_NONE symbol and decodes mode
/// info + one TX_8X8 luma block on the shared od_ec window, maintaining the
/// cross-leaf neighbour arrays (partition ctx + skip + y_mode + coeff EC). The
/// four per-leaf arrays are latched and mapped into [HarborIntraReconWalk]'s
/// 16x16 packing, then the recon walk (sbSize 16) is pulsed. Its done drives
/// this module's `done` and the 16x16 luma `frame`.
///
/// Mapping (walk -> recon), all combinational on the latched walk outputs:
///  - `leaf_count`: direct (this path qualifies only on leaf_count == 4).
///  - `log2sizes` (per leaf, 2b): recon_log2 = walk_leaf_log2size - 2 (walk
///    emits pixel log2 8x8 -> 3, recon convention 8x8 -> 1).
///  - `y_modes` / `tx_types` (4b each): direct copy.
///  - `coeffs`: each leaf's 64 dequantized 16-bit coeffs into the low 64 of
///    recon's 256-coeff slot, the upper 192 zeroed.
///  - `positions`: the four 8x8 leaves land in DFS = raster order at MI (0,0),
///    (0,2), (2,0), (2,2) (leaf l at MI row (l>>1)*2, col (l&1)*2). Each recon
///    position slot is `[l*2*miBits +: 2*miBits]` (miBits = 3): miRow in the low
///    3 bits, miCol in the high 3 bits.
///
/// Ports: clk, reset, start, bytes (maxBytes*8), dc_q (16), ac_q (16) -> done,
/// frame (2048). Scope: one 16x16 SB SPLIT into four PARTITION_NONE 8x8 leaves,
/// each TX_8X8 (tx depth 0), mono luma. Out of scope: NONE / HORZ / VERT roots,
/// 4x4 leaves, per-leaf tx-split, and YUV.
class HarborKeyframeDecodeRoot16 extends BridgeModule {
  /// Maximum coded bytes the internal mode-walk buffer holds.
  final int maxBytes;

  /// Coeff-table q-band (0..3) for the mode walk's coeff decode.
  final int qband;

  HarborKeyframeDecodeRoot16({this.maxBytes = 64, this.qband = 0, String? name})
    : assert(maxBytes > 0, 'maxBytes must be positive'),
      assert(qband >= 0 && qband < 4, 'qband 0..3'),
      super(
        'HarborKeyframeDecodeRoot16',
        name: name ?? 'keyframe_decode_root16',
      ) {
    const sbSize = 16; // 16x16 superblock root
    const maxLeaves = 4; // four 8x8 leaves of a SPLIT 16x16 root
    const f = sbSize; // 16 pixels
    const nPix = f * f; // 256
    const miBits = 3; // bitLength(sbSize/4) = bitLength(4) = 3
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

    // mode walk: a 16x16 root with the coeff + txLeaf path. The leaf-output
    // buffers are 4 entries wide (this path's four 8x8 leaves).
    final walk = HarborKeyframeModeWalk(
      rootBsize: 6,
      maxBytes: maxBytes,
      coeffPrefix: true,
      txLeaf: true,
      qband: qband,
      name: 'walk',
    );
    addSubModule(walk);
    // recon walk over a 16x16 plane with four 8x8 leaves. sbSize 16 selects the
    // 16x16 frame RAM + the variable-square walk.
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

    // latched walk outputs (four 8x8 leaves)
    final lcCap = Logic(name: 'leaf_count_cap', width: 12);
    final l2Cap = Logic(name: 'leaf_log2size_cap', width: 4 * 3);
    final ymCap = Logic(name: 'leaf_ymodes_cap', width: 4 * 4);
    final ttCap = Logic(name: 'leaf_txtypes_cap', width: 4 * 4);
    final coeffCap = Logic(name: 'leaf_coeffs_cap', width: 4 * 64 * 16);

    // mapping walk -> recon (combinational on the latched values).
    // leaf_count: low cntW bits of the captured 12-bit count (== 4 here).
    final reconLeafCount = lcCap.getRange(0, cntW);

    // log2sizes: per leaf recon_log2 = walk_log2 - 2 (3 -> 1 for an 8x8 leaf).
    // swizzle() takes list index 0 as the MSB, so emit leaves high-to-low to
    // land leaf 0 in the LSB slot (recon's [l*2 +: 2] packing).
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

    // positions: the four 8x8 leaves of a 16x16 SPLIT root, in DFS = raster
    // order, at MI (row (l>>1)*2, col (l&1)*2). Each slot is [l*2*miBits +:
    // 2*miBits] with miRow in the low miBits, miCol in the high miBits.
    int posVal(int row, int col) => row | (col << miBits);
    final reconPositions = [
      for (var l = maxLeaves - 1; l >= 0; l--)
        Const(posVal((l >> 1) * 2, (l & 1) * 2), width: 2 * miBits),
    ].concat();

    recon.input('clk').srcConnection! <= clk;
    recon.input('reset').srcConnection! <= reset;
    recon.input('start').srcConnection! <= reconStart;
    recon.input('leaf_count').srcConnection! <= reconLeafCount;
    recon.input('positions').srcConnection! <= reconPositions;
    recon.input('log2sizes').srcConnection! <= reconLog2;
    recon.input('y_modes').srcConnection! <= reconYModes;
    recon.input('tx_types').srcConnection! <= reconTxTypes;
    recon.input('coeffs').srcConnection! <= reconCoeffs;

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
        // pulse the mode-walk start for one cycle leaving idle.
        CaseItem(Const(sIdle, width: 3), [
          If(input('start'), then: [walkStart < Const(1)]),
        ]),
        // pulse the recon start for one cycle in sRunRecon.
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
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(sIdle, width: 3), [
              If(input('start'), then: [st < Const(sRunMode, width: 3)]),
            ]),
            CaseItem(Const(sRunMode, width: 3), [
              If(walk.output('done'), then: [st < Const(sLatch, width: 3)]),
            ]),
            // walk outputs are stable while it holds done, latch leaves.
            CaseItem(Const(sLatch, width: 3), [
              lcCap < walk.output('leaf_count'),
              l2Cap < walk.output('leaf_log2size'),
              ymCap < walk.output('leaf_ymodes'),
              ttCap < walk.output('leaf_txtypes'),
              coeffCap < walk.output('leaf_coeffs'),
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
