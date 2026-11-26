import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_recon_walk_seq.dart';
import 'keyframe_mode_walk.dart';

/// Harbor end-to-end AV1 keyframe intra decode for ONE 64x64 superblock ROOT
/// (BLOCK_64X64, `rootBsize` 12) that SPLITs into a 2x2 grid of FOUR 32x32
/// leaves, each a PARTITION_NONE leaf decoded as one TX_32X32 transform block:
/// coded bytes -> reconstructed 64x64 luma via the SEQUENTIAL recon walk.
///
/// The multi-leaf analog of [HarborKeyframeDecodeSb32] and the 32x32-leaf analog
/// of [HarborKeyframeDecodeRoot32]: four TX_32X32 leaves (1024 coeffs each)
/// decoded inline (maxTxN 1024 / tx32) and reconstructed by
/// [HarborIntraReconWalkSeq] (sbSize 64, maxLeaves 4, maxLog2 3 - the 32x32 recon
/// lane, which the flat recon walk could not build). Uses maxLog2 3 (NOT 4): the
/// leaves are 32x32, so the buildable 32x32 recon serves. The 64x64 LEAF recon
/// is not needed.
///
/// Mapping (walk -> recon), combinational on the latched walk outputs:
///  - `log2sizes`: recon_log2 = walk_leaf_log2size - 2 (32x32 walk emits pixel
///    log2 5 -> recon 3).
///  - `coeffs`: each leaf's 1024 coeffs copy directly (both 1024-wide).
///  - `positions`: four 32x32 leaves at MI (row (l>>1)*8, col (l&1)*8) (32x32 =
///    8 MI), miBits = bitLength(64/4) = 5.
///
/// Ports: clk, reset, start, bytes (maxBytes*8), dc_q/ac_q (16) -> done, frame
/// (64*64*8). Scope: a 64x64 SB SPLIT into four NONE TX_32X32 leaves, mono luma.
class HarborKeyframeDecodeRoot64 extends BridgeModule {
  final int maxBytes;

  HarborKeyframeDecodeRoot64({this.maxBytes = 512, String? name})
    : assert(maxBytes > 0, 'maxBytes must be positive'),
      super(
        'HarborKeyframeDecodeRoot64',
        name: name ?? 'keyframe_decode_root64',
      ) {
    const sbSize = 64;
    const maxLeaves = 4;
    const nPix = sbSize * sbSize;
    const miBits = 5; // bitLength(64/4) = bitLength(16) = 5
    const leafCoeffN = 1024; // TX_32X32

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
      rootBsize: 12,
      maxBytes: maxBytes,
      coeffPrefix: true,
      txLeaf: true,
      maxTxN: 1024,
      qband: 0,
      name: 'walk',
    );
    addSubModule(walk);
    final recon = HarborIntraReconWalkSeq(
      sbSize: sbSize,
      maxLeaves: maxLeaves,
      maxLog2: 3,
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

    final lcCap = Logic(name: 'leaf_count_cap', width: 12);
    final l2Cap = Logic(name: 'leaf_log2size_cap', width: 4 * 3);
    final ymCap = Logic(name: 'leaf_ymodes_cap', width: 4 * 4);
    final ttCap = Logic(name: 'leaf_txtypes_cap', width: 4 * 4);
    final coeffCap = Logic(name: 'leaf_coeffs_cap', width: 4 * leafCoeffN * 16);

    final cntW = recon.input('leaf_count').width;
    final reconLeafCount = lcCap.getRange(0, cntW);
    // recon_log2 = walk_log2 - 2 (32x32: 5 -> 3).
    final reconLog2 = [
      for (var l = maxLeaves - 1; l >= 0; l--)
        (l2Cap.getRange(l * 3, l * 3 + 3) - Const(2, width: 3)).getRange(0, 2),
    ].concat();
    final reconCoeffs = coeffCap;
    int posVal(int row, int col) => row | (col << miBits);
    final reconPositions = [
      for (var l = maxLeaves - 1; l >= 0; l--)
        Const(posVal((l >> 1) * 8, (l & 1) * 8), width: 2 * miBits),
    ].concat();

    recon.input('clk').srcConnection! <= clk;
    recon.input('reset').srcConnection! <= reset;
    recon.input('start').srcConnection! <= reconStart;
    recon.input('leaf_count').srcConnection! <= reconLeafCount;
    recon.input('positions').srcConnection! <= reconPositions;
    recon.input('log2sizes').srcConnection! <= reconLog2;
    recon.input('y_modes').srcConnection! <= ymCap;
    recon.input('tx_types').srcConnection! <= ttCap;
    recon.input('coeffs').srcConnection! <= reconCoeffs;

    output('frame') <= recon.output('frame');

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
