import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_recon_walk.dart';
import 'keyframe_mode_walk.dart';

/// AV1 keyframe intra decode for one 32x32 superblock root (BLOCK_32X32,
/// `rootBsize` 9) that SPLITs into a 2x2 grid of four 16x16 leaves, each a
/// PARTITION_NONE leaf decoded as a single TX_16X16 block: coded bytes -> 32x32
/// luma picture. The leaves are TX_16X16 (256 coeffs), exercising the inline
/// 16x16 coeff decode (`maxTxN` 256) through the variable-square
/// [HarborIntraReconWalk] (`sizes` = [4, 8, 16]).
///
/// On `start`, runs the mode walk (rootBsize 9, coeffPrefix, txLeaf, maxTxN 256)
/// over `bytes` with `dc_q`/`ac_q`. On a PARTITION_SPLIT root the DFS pushes
/// four 16x16 sub-blocks, each reads its PARTITION_NONE symbol and decodes mode
/// info + one TX_16X16 luma block on the shared od_ec window, maintaining the
/// cross-leaf neighbour arrays (partition ctx + skip + y_mode + coeff EC +
/// tx-size). The four per-leaf arrays are latched and mapped into the recon
/// walk's 32x32 packing, then the recon walk (sbSize 32) is pulsed. Its done
/// drives this module's `done` and the 32x32 luma `frame`.
///
/// Mapping (walk -> recon), all combinational on the latched walk outputs:
///  - `leaf_count`: direct (this path qualifies only on leaf_count == 4).
///  - `log2sizes` (per leaf, 2b): recon_log2 = walk_leaf_log2size - 2 (walk
///    emits pixel log2 16x16 -> 4, recon convention 16x16 -> 2).
///  - `y_modes` / `tx_types` (4b each): direct copy.
///  - `coeffs`: each leaf's 256 dequantized 16-bit coeffs copy directly into the
///    recon's 256-coeff slot (both TX_16X16, raster row-major).
///  - `positions`: the four 16x16 leaves land in DFS = raster order at MI (0,0),
///    (0,4), (4,0), (4,4) (leaf l at MI row (l>>1)*4, col (l&1)*4, a 16x16 block
///    is 4 MI units). Each recon position slot is `[l*2*miBits +: 2*miBits]`
///    (miBits = 4): miRow in the low 4 bits, miCol in the high 4 bits.
///
/// Ports: clk, reset, start, bytes (maxBytes*8), dc_q (16), ac_q (16) -> done,
/// frame (8192). Scope: one 32x32 SB SPLIT into four PARTITION_NONE 16x16
/// leaves, each TX_16X16 (tx depth 0), mono luma. Out of scope: NONE / HORZ /
/// VERT roots, mixed / smaller leaves, per-leaf tx-split, and YUV.
class HarborKeyframeDecodeRoot32 extends BridgeModule {
  /// Maximum coded bytes the internal mode-walk buffer holds.
  final int maxBytes;

  /// Coeff-table q-band (0..3). TX_16X16 inline coeff is Q0-only, so 0.
  final int qband;

  HarborKeyframeDecodeRoot32({
    this.maxBytes = 320,
    this.qband = 0,
    String? name,
  }) : assert(maxBytes > 0, 'maxBytes must be positive'),
       assert(qband == 0, 'TX_16X16 inline coeff is Q0-only'),
       super(
         'HarborKeyframeDecodeRoot32',
         name: name ?? 'keyframe_decode_root32',
       ) {
    const sbSize = 32; // 32x32 superblock root
    const maxLeaves = 4; // four 16x16 leaves of a SPLIT 32x32 root
    const f = sbSize; // 32 pixels
    const nPix = f * f; // 1024
    const miBits = 4; // bitLength(sbSize/4) = bitLength(8) = 4
    const cntW = 3; // (maxLeaves + 1).bitLength = 5.bitLength = 3
    const leafCoeffN = 256; // TX_16X16 (maxTxN)

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

    // mode walk: a 32x32 root with the coeff + txLeaf path and TX_16X16 inline
    // coeff (maxTxN 256). Four 16x16 leaves => maxLeafOut 4.
    final walk = HarborKeyframeModeWalk(
      rootBsize: 9,
      maxBytes: maxBytes,
      coeffPrefix: true,
      txLeaf: true,
      maxTxN: 256,
      qband: qband,
      name: 'walk',
    );
    addSubModule(walk);
    // recon walk over a 32x32 plane with four 16x16 leaves.
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

    // latched walk outputs (four 16x16 leaves)
    final lcCap = Logic(name: 'leaf_count_cap', width: 12);
    final l2Cap = Logic(name: 'leaf_log2size_cap', width: 4 * 3);
    final ymCap = Logic(name: 'leaf_ymodes_cap', width: 4 * 4);
    final ttCap = Logic(name: 'leaf_txtypes_cap', width: 4 * 4);
    final coeffCap = Logic(name: 'leaf_coeffs_cap', width: 4 * leafCoeffN * 16);

    // mapping walk -> recon (combinational on the latched values).
    final reconLeafCount = lcCap.getRange(0, cntW);

    // log2sizes: per leaf recon_log2 = walk_log2 - 2 (4 -> 2 for a 16x16 leaf).
    // swizzle() takes list index 0 as the MSB, so emit leaves high-to-low.
    final reconLog2 = [
      for (var l = maxLeaves - 1; l >= 0; l--)
        (l2Cap.getRange(l * 3, l * 3 + 3) - Const(2, width: 3)).getRange(0, 2),
    ].concat();

    final reconYModes = ymCap;
    final reconTxTypes = ttCap;

    // coeffs: each leaf's 256 captured coeffs copy directly (both TX_16X16).
    final reconCoeffs = coeffCap;

    // positions: the four 16x16 leaves of a 32x32 SPLIT root, in DFS = raster
    // order, at MI (row (l>>1)*4, col (l&1)*4). Each slot is [l*2*miBits +:
    // 2*miBits] with miRow in the low miBits, miCol in the high miBits.
    int posVal(int row, int col) => row | (col << miBits);
    final reconPositions = [
      for (var l = maxLeaves - 1; l >= 0; l--)
        Const(posVal((l >> 1) * 4, (l & 1) * 4), width: 2 * miBits),
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
        CaseItem(Const(sIdle, width: 3), [
          If(input('start'), then: [walkStart < Const(1)]),
        ]),
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
          coeffCap < Const(0, width: 4 * leafCoeffN * 16),
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(sIdle, width: 3), [
              If(input('start'), then: [st < Const(sRunMode, width: 3)]),
            ]),
            CaseItem(Const(sRunMode, width: 3), [
              If(walk.output('done'), then: [st < Const(sLatch, width: 3)]),
            ]),
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
