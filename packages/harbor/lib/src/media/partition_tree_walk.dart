import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'av1_cdf_tables.dart' as cdf;
import 'od_ec_decoder.dart';

/// Harbor bit-exact AV1 partition-tree walk for ONE fully-interior superblock
/// on a SINGLE shared od_ec window (the first slice of the tile-assembly FSM).
///
/// Decodes the recursive `decode_partition` tree for a square superblock of
/// size [rootBsize] (BLOCK_16X16 = 6 / 32X32 = 9 / 64X64 = 12) that fills its
/// own frame, so every node has rows and cols available (no edge / forced-split
/// cases). Each node's partition type is read from the adapting
/// `default_partition_cdf` contexts (preloaded once, then adapted across the
/// whole walk, matching a real tile), the above/left partition-context arrays
/// are maintained, and the leaf footprints are emitted. To stay block-decode
/// free (testable in isolation) a leaf consumes NO further bits: it just updates
/// the partition-context arrays over its footprint, exactly as `_decodeBlock`'s
/// neighbour-context update.
///
/// Verification surface: `leaf_count`, `sym_count`, a running `chk` checksum of
/// the emitted leaves (in libaom emission order, key = (r<<10)|(c<<5)|bsize),
/// and the final `above_ctx` / `left_ctx` arrays. Pulse `start` with `bytes`
/// valid. `done` asserts when the walk completes.
class HarborPartitionTreeWalk extends BridgeModule {
  /// Maximum coded bytes the internal buffer holds.
  final int maxBytes;

  /// Root (superblock) block size, square BLOCK_16X16 = 6 / 32X32 = 9 / 64X64.
  final int rootBsize;

  static const _miWide = [
    1,
    1,
    2,
    2,
    2,
    4,
    4,
    4,
    8,
    8,
    8,
    16,
    16,
    16,
    32,
    32,
    1,
    4,
    2,
    8,
    4,
    16,
  ];
  static const _miHigh = [
    1,
    2,
    1,
    2,
    4,
    2,
    4,
    8,
    4,
    8,
    16,
    8,
    16,
    32,
    16,
    32,
    4,
    1,
    8,
    2,
    16,
    4,
  ];
  static const _miWideLog2 = [
    0,
    0,
    1,
    1,
    1,
    2,
    2,
    2,
    3,
    3,
    3,
    4,
    4,
    4,
    5,
    5,
    0,
    2,
    1,
    3,
    2,
    4,
  ];
  static const _partCtxAbove = [
    31,
    31,
    30,
    30,
    30,
    28,
    28,
    28,
    24,
    24,
    24,
    16,
    16,
    16,
    0,
    0,
    31,
    28,
    30,
    24,
    28,
    16,
  ];
  static const _partCtxLeft = [
    31,
    30,
    31,
    30,
    28,
    30,
    28,
    24,
    28,
    24,
    16,
    24,
    16,
    0,
    16,
    0,
    28,
    31,
    24,
    30,
    16,
    28,
  ];
  // Partition_Subsize[level][partition], level = miSizeWideLog2[bsize]-1
  // (0=8x8,1=16x16,2=32x32,3=64x64). -1 (undefined) stored as 0.
  static const _psub = [
    3, 2, 1, 0, 0, 0, 0, 0, 0, 0, //
    6, 5, 4, 3, 5, 5, 4, 4, 17, 16, //
    9, 8, 7, 6, 8, 8, 7, 7, 19, 18, //
    12, 11, 10, 9, 11, 11, 10, 10, 21, 20,
  ];

  HarborPartitionTreeWalk({
    this.rootBsize = 6,
    this.maxBytes = 32,
    String? name,
  }) : assert(
         rootBsize == 6 || rootBsize == 9 || rootBsize == 12,
         'root 16x16 / 32x32 / 64x64',
       ),
       super(
         'HarborPartitionTreeWalk',
         name: name ?? 'partition_tree_walk_$rootBsize',
       ) {
    final sbMi = _miWide[rootBsize];
    final ctxN = sbMi;
    final cW = (sbMi + 1).bitLength; // mi coord width (0..sbMi)
    const dStack = 96; // explicit recursion stack depth
    final spW = (dStack + 1).bitLength;

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    addOutput('done');
    addOutput('leaf_count', width: 12);
    addOutput('sym_count', width: 12);
    addOutput('chk', width: 32);
    addOutput('above_ctx', width: ctxN * 5);
    addOutput('left_ctx', width: ctxN * 5);

    final clk = input('clk');
    final reset = input('reset');

    final ec = HarborOdEcDecoder(maxSyms: 10, numCtx: 16, name: 'ec');
    addSubModule(ec);
    final cw = ec.ctxWidth;

    Logic packCdf(List<int> icdf) => [
      for (var s = 9; s >= 0; s--)
        Const(s < icdf.length ? icdf[s] : 0, width: 16),
    ].concat();
    Logic romSel(List<int> table, Logic idx, int w) {
      Logic v = Const(table.last, width: w);
      for (var i = table.length - 2; i >= 0; i--) {
        v = mux(
          idx.eq(Const(i, width: idx.width)),
          Const(table[i], width: w),
          v,
        );
      }
      return v;
    }

    Logic selList(List<Logic> arr, Logic idx) {
      Logic v = arr.last;
      for (var i = arr.length - 2; i >= 0; i--) {
        v = mux(idx.eq(Const(i, width: idx.width)), arr[i], v);
      }
      return v;
    }

    // byte buffer + cursor
    final buf = [
      for (var i = 0; i < maxBytes; i++) Logic(name: 'b_$i', width: 8),
    ];
    final cursor = Logic(name: 'cursor', width: (maxBytes + 4).bitLength);
    Logic byteAt(Logic ix) {
      Logic v = buf.last;
      for (var i = maxBytes - 2; i >= 0; i--) {
        v = mux(ix.eq(Const(i, width: cursor.width)), buf[i], v);
      }
      return mux(
        ix.gte(Const(maxBytes, width: cursor.width)),
        Const(0, width: 8),
        v,
      );
    }

    final ecInit = Logic(name: 'ec_init');
    final ecLoad = Logic(name: 'ec_load');
    final ecDecode = Logic(name: 'ec_decode');
    final ecCtx = Logic(name: 'ec_ctx', width: cw);
    final ecCdf = Logic(name: 'ec_cdf', width: 10 * 16);
    final ecNsyms = Logic(name: 'ec_nsyms', width: 5);
    ec.input('clk').srcConnection! <= clk;
    ec.input('reset').srcConnection! <= reset;
    ec.input('init').srcConnection! <= ecInit;
    ec.input('load').srcConnection! <= ecLoad;
    ec.input('decode').srcConnection! <= ecDecode;
    ec.input('ctx').srcConnection! <= ecCtx;
    ec.input('cdf').srcConnection! <= ecCdf;
    ec.input('num_syms').srcConnection! <= ecNsyms;
    ec.input('bytes_in').srcConnection! <=
        [
          byteAt(cursor),
          byteAt((cursor + Const(1, width: cursor.width))),
          byteAt((cursor + Const(2, width: cursor.width))),
        ].concat();
    final sym = ec.output('symbol');
    final bytePop = ec.output('byte_pop');

    // Preload CDF for context k: kAv1DefaultPartitionCdf[(k>>2)+1][k&3].
    Logic selPreloadCdf(Logic k) {
      Logic v = packCdf(cdf.kAv1DefaultPartitionCdf[4][3]);
      for (var kk = 14; kk >= 0; kk--) {
        v = mux(
          k.eq(Const(kk, width: k.width)),
          packCdf(cdf.kAv1DefaultPartitionCdf[(kk >> 2) + 1][kk & 3]),
          v,
        );
      }
      return v;
    }

    // partition-context arrays + stack + node/plan registers
    final aboveCtx = [
      for (var i = 0; i < ctxN; i++) Logic(name: 'ac_$i', width: 5),
    ];
    final leftCtx = [
      for (var i = 0; i < ctxN; i++) Logic(name: 'lc_$i', width: 5),
    ];
    final stR = [
      for (var i = 0; i < dStack; i++) Logic(name: 'str_$i', width: cW),
    ];
    final stC = [
      for (var i = 0; i < dStack; i++) Logic(name: 'stc_$i', width: cW),
    ];
    final stB = [
      for (var i = 0; i < dStack; i++) Logic(name: 'stb_$i', width: 5),
    ];
    final sp = Logic(name: 'sp', width: spW);
    final nr = Logic(name: 'nr', width: cW);
    final nc = Logic(name: 'nc', width: cW);
    final nbs = Logic(name: 'nbs', width: 5);
    final lr = [for (var i = 0; i < 4; i++) Logic(name: 'lr_$i', width: cW)];
    final lc = [for (var i = 0; i < 4; i++) Logic(name: 'lc_$i', width: cW)];
    final lbs = [for (var i = 0; i < 4; i++) Logic(name: 'lbs_$i', width: 5)];
    final leafN = Logic(name: 'leaf_n', width: 3);
    final emitIdx = Logic(name: 'emit_idx', width: 3);
    final pli = Logic(name: 'pli', width: 5);
    final leafCount = Logic(name: 'leaf_count_r', width: 12);
    final symCount = Logic(name: 'sym_count_r', width: 12);
    final chk = Logic(name: 'chk_r', width: 32);

    // node-derived combinational values (valid when nbs is a read node)
    final level = (romSel(_miWideLog2, nbs, 4) - Const(1, width: 4)).getRange(
      0,
      4,
    ); // 0..3 when nbs >= 8x8
    final psubLevelBase = (level.zeroExtend(8) * Const(10, width: 8)).getRange(
      0,
      8,
    );
    Logic subOf(int part) => romSel(
      _psub,
      (psubLevelBase + Const(part, width: 8)).getRange(0, 8),
      5,
    );
    final sub = [for (var p = 0; p < 10; p++) subOf(p)];
    final half = (romSel(_miWide, nbs, 6) >> 1).getRange(0, cW);
    final quarter = (romSel(_miWide, nbs, 6) >> 2).getRange(0, cW);

    final availU = nr.gt(Const(0, width: cW));
    final availL = nc.gt(Const(0, width: cW));
    final aboveBit = availU & (selList(aboveCtx, nc) >> level)[0];
    final leftBit = availL & (selList(leftCtx, nr) >> level)[0];
    final nodeCtx = ((leftBit.zeroExtend(2) << 1) | aboveBit.zeroExtend(2))
        .getRange(0, 2);
    final partIdxCtxBase =
        ((Const(3, width: cw) - level.zeroExtend(cw)) * Const(4, width: cw))
            .getRange(0, cw);
    final readCtxIdx = (partIdxCtxBase + nodeCtx.zeroExtend(cw)).getRange(
      0,
      cw,
    );

    output('leaf_count') <= leafCount;
    output('sym_count') <= symCount;
    output('chk') <= chk;
    output('above_ctx') <=
        [for (var i = ctxN - 1; i >= 0; i--) aboveCtx[i]].concat();
    output('left_ctx') <=
        [for (var i = ctxN - 1; i >= 0; i--) leftCtx[i]].concat();

    const sIdle = 0,
        sPreload = 1,
        sInit = 2,
        sPop = 3,
        sRead = 4,
        sReadCap = 5,
        sEmit = 6,
        sDone = 7;
    final st = Logic(name: 'st', width: 3);
    output('done') <= st.eq(Const(sDone, width: 3));

    Combinational([
      ecInit < Const(0),
      ecLoad < Const(0),
      ecDecode < Const(0),
      ecCtx < Const(0, width: cw),
      ecCdf < Const(0, width: 10 * 16),
      ecNsyms < Const(0, width: 5),
      Case(st, [
        CaseItem(Const(sPreload, width: 3), [
          ecLoad < Const(1),
          ecCtx < pli.getRange(0, cw),
          ecCdf < selPreloadCdf(pli),
          ecNsyms <
              mux<Logic>(
                pli.gte(Const(12, width: 5)),
                Const(4, width: 5),
                Const(10, width: 5),
              ),
        ]),
        CaseItem(Const(sInit, width: 3), [ecInit < Const(1)]),
        CaseItem(Const(sRead, width: 3), [
          ecDecode < Const(1),
          ecCtx < readCtxIdx,
        ]),
      ]),
    ]);

    Logic stackTop(List<Logic> arr) {
      final top = (sp - Const(1, width: spW)).getRange(0, spW);
      Logic v = arr.last;
      for (var i = arr.length - 2; i >= 0; i--) {
        v = mux(top.eq(Const(i, width: spW)), arr[i], v);
      }
      return v;
    }

    // Write (r,c,bs) into the stack at runtime position `pos`.
    List<Conditional> writeStack(Logic pos, Logic r, Logic c, Logic bs) => [
      for (var slot = 0; slot < dStack; slot++)
        If(
          pos.eq(Const(slot, width: spW)),
          then: [stR[slot] < r, stC[slot] < c, stB[slot] < bs],
        ),
    ];

    Logic chkStep(Logic r, Logic c, Logic bs) {
      final key =
          ((r.zeroExtend(32) << 10) |
                  (c.zeroExtend(32) << 5) |
                  bs.zeroExtend(32))
              .getRange(0, 32);
      return (chk * Const(31, width: 32) + key).getRange(0, 32);
    }

    // Set the leaf plan (up to 4 leaves) from explicit lists.
    List<Conditional> plan(List<List<Logic>> leaves) => [
      for (var i = 0; i < leaves.length; i++) ...[
        lr[i] < leaves[i][0],
        lc[i] < leaves[i][1],
        lbs[i] < leaves[i][2],
      ],
      leafN < Const(leaves.length, width: 3),
      st < Const(sEmit, width: 3),
    ];

    Logic rPlus(Logic v) => (nr + v).getRange(0, cW);
    Logic cPlus(Logic v) => (nc + v).getRange(0, cW);

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: 3),
          cursor < Const(0, width: cursor.width),
          sp < Const(0, width: spW),
          pli < Const(0, width: 5),
          leafCount < Const(0, width: 12),
          symCount < Const(0, width: 12),
          chk < Const(0, width: 32),
          nr < Const(0, width: cW),
          nc < Const(0, width: cW),
          nbs < Const(0, width: 5),
          leafN < Const(0, width: 3),
          emitIdx < Const(0, width: 3),
          for (var i = 0; i < ctxN; i++) ...[
            aboveCtx[i] < Const(0, width: 5),
            leftCtx[i] < Const(0, width: 5),
          ],
          for (var i = 0; i < dStack; i++) ...[
            stR[i] < Const(0, width: cW),
            stC[i] < Const(0, width: cW),
            stB[i] < Const(0, width: 5),
          ],
          for (var i = 0; i < maxBytes; i++) buf[i] < Const(0, width: 8),
        ],
        orElse: [
          cursor <
              (cursor + bytePop.zeroExtend(cursor.width)).getRange(
                0,
                cursor.width,
              ),
          Case(st, [
            CaseItem(Const(sIdle, width: 3), [
              If(
                input('start'),
                then: [
                  for (var i = 0; i < maxBytes; i++)
                    buf[i] < input('bytes').getRange(i * 8, i * 8 + 8),
                  cursor < Const(0, width: cursor.width),
                  pli < Const(0, width: 5),
                  leafCount < Const(0, width: 12),
                  symCount < Const(0, width: 12),
                  chk < Const(0, width: 32),
                  for (var i = 0; i < ctxN; i++) ...[
                    aboveCtx[i] < Const(0, width: 5),
                    leftCtx[i] < Const(0, width: 5),
                  ],
                  stR[0] < Const(0, width: cW),
                  stC[0] < Const(0, width: cW),
                  stB[0] < Const(rootBsize, width: 5),
                  sp < Const(1, width: spW),
                  st < Const(sPreload, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(sPreload, width: 3), [
              If(
                pli.eq(Const(15, width: 5)),
                then: [st < Const(sInit, width: 3)],
                orElse: [pli < (pli + Const(1, width: 5))],
              ),
            ]),
            CaseItem(Const(sInit, width: 3), [st < Const(sPop, width: 3)]),
            CaseItem(Const(sPop, width: 3), [
              If(
                sp.eq(Const(0, width: spW)),
                then: [st < Const(sDone, width: 3)],
                orElse: [
                  nr < stackTop(stR),
                  nc < stackTop(stC),
                  nbs < stackTop(stB),
                  sp < (sp - Const(1, width: spW)),
                  If(
                    stackTop(stB).lt(Const(3, width: 5)),
                    then: [
                      lr[0] < stackTop(stR),
                      lc[0] < stackTop(stC),
                      lbs[0] < stackTop(stB),
                      leafN < Const(1, width: 3),
                      emitIdx < Const(0, width: 3),
                      st < Const(sEmit, width: 3),
                    ],
                    orElse: [st < Const(sRead, width: 3)],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sRead, width: 3), [st < Const(sReadCap, width: 3)]),
            CaseItem(Const(sReadCap, width: 3), [
              symCount < (symCount + Const(1, width: 12)),
              emitIdx < Const(0, width: 3),
              Case(sym.getRange(0, 4), [
                CaseItem(
                  Const(0, width: 4),
                  plan([
                    [nr, nc, sub[0]],
                  ]),
                ),
                CaseItem(
                  Const(1, width: 4),
                  plan([
                    [nr, nc, sub[1]],
                    [rPlus(half), nc, sub[1]],
                  ]),
                ),
                CaseItem(
                  Const(2, width: 4),
                  plan([
                    [nr, nc, sub[2]],
                    [nr, cPlus(half), sub[2]],
                  ]),
                ),
                CaseItem(Const(3, width: 4), [
                  // SPLIT: push 4 children at subSplit (sub[3]). sp currently
                  // points at the just-freed slot, push children so TL pops first.
                  ...writeStack(sp, rPlus(half), cPlus(half), sub[3]),
                  ...writeStack(
                    (sp + Const(1, width: spW)).getRange(0, spW),
                    rPlus(half),
                    nc,
                    sub[3],
                  ),
                  ...writeStack(
                    (sp + Const(2, width: spW)).getRange(0, spW),
                    nr,
                    cPlus(half),
                    sub[3],
                  ),
                  ...writeStack(
                    (sp + Const(3, width: spW)).getRange(0, spW),
                    nr,
                    nc,
                    sub[3],
                  ),
                  sp < (sp + Const(4, width: spW)).getRange(0, spW),
                  st < Const(sPop, width: 3),
                ]),
                CaseItem(
                  Const(4, width: 4),
                  plan([
                    [nr, nc, sub[3]],
                    [nr, cPlus(half), sub[3]],
                    [rPlus(half), nc, sub[4]],
                  ]),
                ),
                CaseItem(
                  Const(5, width: 4),
                  plan([
                    [nr, nc, sub[5]],
                    [rPlus(half), nc, sub[3]],
                    [rPlus(half), cPlus(half), sub[3]],
                  ]),
                ),
                CaseItem(
                  Const(6, width: 4),
                  plan([
                    [nr, nc, sub[3]],
                    [rPlus(half), nc, sub[3]],
                    [nr, cPlus(half), sub[6]],
                  ]),
                ),
                CaseItem(
                  Const(7, width: 4),
                  plan([
                    [nr, nc, sub[7]],
                    [nr, cPlus(half), sub[3]],
                    [rPlus(half), cPlus(half), sub[3]],
                  ]),
                ),
                CaseItem(
                  Const(8, width: 4),
                  plan([
                    for (var i = 0; i < 4; i++)
                      [
                        rPlus((quarter * Const(i, width: cW)).getRange(0, cW)),
                        nc,
                        sub[8],
                      ],
                  ]),
                ),
                CaseItem(
                  Const(9, width: 4),
                  plan([
                    for (var i = 0; i < 4; i++)
                      [
                        nr,
                        cPlus((quarter * Const(i, width: cW)).getRange(0, cW)),
                        sub[9],
                      ],
                  ]),
                ),
              ]),
            ]),
            CaseItem(Const(sEmit, width: 3), [
              ...() {
                final er = selList(lr, emitIdx);
                final ec2 = selList(lc, emitIdx);
                final eb = selList(lbs, emitIdx);
                final bw4 = romSel(_miWide, eb, 8);
                final bh4 = romSel(_miHigh, eb, 8);
                final pa = romSel(_partCtxAbove, eb, 5);
                final pl = romSel(_partCtxLeft, eb, 5);
                final ec8 = ec2.zeroExtend(8);
                final er8 = er.zeroExtend(8);
                return <Conditional>[
                  for (var k = 0; k < ctxN; k++)
                    If(
                      Const(k, width: 8).gte(ec8) &
                          Const(k, width: 8).lt((ec8 + bw4).getRange(0, 8)),
                      then: [aboveCtx[k] < pa],
                    ),
                  for (var k = 0; k < ctxN; k++)
                    If(
                      Const(k, width: 8).gte(er8) &
                          Const(k, width: 8).lt((er8 + bh4).getRange(0, 8)),
                      then: [leftCtx[k] < pl],
                    ),
                  chk < chkStep(er, ec2, eb),
                  leafCount < (leafCount + Const(1, width: 12)),
                ];
              }(),
              If(
                (emitIdx + Const(1, width: 3)).eq(leafN),
                then: [st < Const(sPop, width: 3)],
                orElse: [emitIdx < (emitIdx + Const(1, width: 3))],
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
