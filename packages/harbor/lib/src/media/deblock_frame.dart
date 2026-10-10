import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'deblock14.dart';
import 'deblock4.dart';
import 'deblock6.dart';
import 'deblock8.dart';
import 'deblock_thresh.dart';

/// AV1 frame-level loop (deblocking) filter for luma and chroma with runtime
/// per-mi metadata ports. Generalizes [HarborDeblockLumaFrame]: the per-4x4
/// transform-size grid, per-mi filter levels (4 slots), sharpness, skip/inter
/// flags and prediction-block dims are all input ports, and both the luma and
/// the 4:2:0 chroma planes are filtered.
///
/// Walk order per AV1: for each plane (Y, U, V) apply all vertical
/// transform-block edges across the plane, then all horizontal edges on the
/// vertically-filtered result. An edge fires only on an interior transform
/// boundary when `currLevel || pvLvl` is non-zero and the skip/PU-edge
/// suppression (`pvSkip==0 || currSkip==0 || puEdge`) allows it. The kernel
/// length (0/4/8/14 luma, 0/4/6 chroma) is `min(unitLog2[ts], unitLog2[pvTs])`.
///
/// Since tx sizes are runtime, each interior edge instantiates every kernel that
/// could apply and muxes the write-back by the runtime filter length (a
/// passthrough when the edge does not fire). Every 4x4 grid line is visited, at
/// non-boundary lines the `tuEdge` gate forces filter length 0.
///
/// Chroma follows 4:2:0 subsampling: the mi position is
/// `sub | ((coord << sub) >> 2)` (bottom-right mi of each 2x2 group), the
/// previous mi steps by `1 << sub`, chroma tx sizes come from `mi_tx_uv` and the
/// chroma levels from slots 2 (U) / 3 (V).
///
/// A plane with base frame level 0 is skipped by passing all-zero per-mi levels
/// for it, so every edge sees `currLevel==0 && pvLvl==0` and nothing filters.
///
/// Ports:
///  - `frame` (width*height*bd) -> `out`. Luma pixel (y,x) at `[(y*w+x)*bd +: bd]`.
///  - chroma (numPlanes==3): `frame_u`/`frame_v` (cw*ch*bd) -> `out_u`/`out_v`,
///    cw=width>>subX, ch=height>>subY.
///  - `sharpness` (3b).
///  - `mi_tx_y`, `mi_tx_uv` (miRows*miCols*5): TX_SIZE per 4x4.
///  - `mi_level_yv`, `mi_level_yh`, `mi_level_u`, `mi_level_v` (miRows*miCols*6):
///    the 4 filter-level slots per mi.
///  - `mi_skip`, `mi_is_inter` (miRows*miCols, 1b/mi): interSkip=skip&is_inter.
///  - `mi_block_w`, `mi_block_h` (miRows*miCols*8): prediction block dims (luma
///    px) for the PU-edge term.
/// All packed LSB-first row-major per mi. Combinational.
class HarborDeblockFrame extends BridgeModule {
  static const List<int> _txSizeWide = [
    4, 8, 16, 32, 64, 4, 8, 8, 16, 16, 32, 32, 64, 4, 16, 8, 32, 16, 64, //
  ];
  static const List<int> _txSizeHigh = [
    4, 8, 16, 32, 64, 8, 4, 16, 8, 32, 16, 64, 32, 16, 4, 32, 8, 64, 16, //
  ];
  static const List<int> _txSizeWideUnitLog2 = [
    0, 1, 2, 3, 4, 0, 1, 1, 2, 2, 3, 3, 4, 0, 2, 1, 3, 2, 4, //
  ];
  static const List<int> _txSizeHighUnitLog2 = [
    0, 1, 2, 3, 4, 1, 0, 2, 1, 3, 2, 4, 3, 2, 0, 3, 1, 4, 2, //
  ];
  static const int _miSize = 4;
  static const int _miSizeLog2 = 2;
  static const int _maxMib = 32;
  static const int _txBits = 5; // TX_SIZE 0..18

  HarborDeblockFrame({
    int width = 16,
    int height = 16,
    int numPlanes = 3,
    int subX = 1,
    int subY = 1,
    int bd = 8,
    String? name,
  }) : super(
         'HarborDeblockFrame_W${width}_H${height}_P${numPlanes}_'
         'SX${subX}_SY${subY}_B$bd',
         name: name ?? 'deblock_frame',
       ) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('width/height must be positive');
    }
    if (bd != 8 && bd != 10 && bd != 12) {
      throw ArgumentError('bd must be 8, 10 or 12');
    }
    if (width % _miSize != 0 || height % _miSize != 0) {
      throw ArgumentError('width/height must be multiples of 4');
    }
    if (numPlanes != 1 && numPlanes != 3) {
      throw ArgumentError('numPlanes must be 1 or 3');
    }
    if (subX != 0 && subX != 1 || subY != 0 && subY != 1) {
      throw ArgumentError('subX/subY must be 0 or 1');
    }
    if (numPlanes == 3) {
      if (width % (1 << subX) != 0 || height % (1 << subY) != 0) {
        throw ArgumentError('chroma dims must divide evenly');
      }
    }
    final miRows = height ~/ _miSize;
    final miCols = width ~/ _miSize;
    if (miRows > _maxMib || miCols > _maxMib) {
      throw ArgumentError('single-superblock only: mi grid must be <= 32x32');
    }

    final cw = width >> subX;
    final ch = height >> subY;

    createPort('frame', PortDirection.input, width: width * height * bd);
    addOutput('out', width: width * height * bd);
    if (numPlanes == 3) {
      createPort('frame_u', PortDirection.input, width: cw * ch * bd);
      createPort('frame_v', PortDirection.input, width: cw * ch * bd);
      addOutput('out_u', width: cw * ch * bd);
      addOutput('out_v', width: cw * ch * bd);
    }
    createPort('sharpness', PortDirection.input, width: 3);
    createPort(
      'mi_tx_y',
      PortDirection.input,
      width: miRows * miCols * _txBits,
    );
    createPort(
      'mi_tx_uv',
      PortDirection.input,
      width: miRows * miCols * _txBits,
    );
    for (final s in [
      'mi_level_yv',
      'mi_level_yh',
      'mi_level_u',
      'mi_level_v',
    ]) {
      createPort(s, PortDirection.input, width: miRows * miCols * 6);
    }
    createPort('mi_skip', PortDirection.input, width: miRows * miCols);
    createPort('mi_is_inter', PortDirection.input, width: miRows * miCols);
    createPort('mi_block_w', PortDirection.input, width: miRows * miCols * 8);
    createPort('mi_block_h', PortDirection.input, width: miRows * miCols * 8);

    final sharp = input('sharpness');

    // per-mi metadata accessors (compile-time mi index, runtime value)
    Logic txAt(String port, int r, int c) => input(port).getRange(
      (r * miCols + c) * _txBits,
      (r * miCols + c) * _txBits + _txBits,
    );
    Logic levelAt(String slot, int r, int c) =>
        input(slot).getRange((r * miCols + c) * 6, (r * miCols + c) * 6 + 6);
    Logic bitAt(String port, int r, int c) =>
        input(port).getRange(r * miCols + c, r * miCols + c + 1);
    Logic dimAt(String port, int r, int c) =>
        input(port).getRange((r * miCols + c) * 8, (r * miCols + c) * 8 + 8);
    Logic interSkipAt(int r, int c) =>
        bitAt('mi_skip', r, c) & bitAt('mi_is_inter', r, c);

    // Combinational lookup of a small integer table by a runtime index Logic.
    Logic lut(Logic idx, List<int> values, int outW) {
      Logic build(int bit, int base) {
        if (bit < 0) {
          final v = base < values.length ? values[base] : 0;
          return Const(v, width: outW);
        }
        return mux(
          idx[bit],
          build(bit - 1, base | (1 << bit)),
          build(bit - 1, base),
        );
      }

      return build(idx.width - 1, 0);
    }

    // Cached per-(slot, mi) threshold triple [mblim, lim, hev].
    final threshCache = <String, List<Logic>>{};
    List<Logic> threshFor(String slot, int r, int c) {
      final key = '$slot:$r:$c';
      return threshCache.putIfAbsent(key, () {
        final t = HarborDeblockThresh(name: 'th_${slot}_${r}_$c');
        addSubModule(t);
        t.input('level').srcConnection! <= levelAt(slot, r, c);
        t.input('sharpness').srcConnection! <= sharp;
        return [t.output('mblim'), t.output('lim'), t.output('hev')];
      });
    }

    var inst = 0;

    // Fold candidate kernel outputs into one write value, priority high->low.
    // [pairs] are (selector, value) in increasing filter-length order.
    Logic foldWrite(Logic base, List<List<Logic>> pairs) {
      var acc = base;
      for (final p in pairs) {
        acc = mux(p[0], p[1], acc);
      }
      return acc;
    }

    // Deblock one plane. [grid] holds `pw*ph` 8-bit pixel Logics (row-major).
    // [txPort] gives the plane tx grid, [slotV]/[slotH] the level slots for
    // vertical/horizontal edges (equal for chroma).
    void deblockPlane({
      required List<Logic> grid,
      required int pw,
      required int ph,
      required int scaleH,
      required int scaleV,
      required String txPort,
      required String slotV,
      required String slotH,
      required bool isChroma,
    }) {
      final planeMiCols = (miCols + scaleH) >> scaleH;
      final planeMiRows = (miRows + scaleV) >> scaleV;
      final xRange = planeMiCols < (_maxMib >> scaleH)
          ? planeMiCols
          : (_maxMib >> scaleH);
      final yRange = planeMiRows < (_maxMib >> scaleV)
          ? planeMiRows
          : (_maxMib >> scaleV);

      // Emit one edge. [dir]==0 vertical, 1 horizontal. [coord] is the pixel
      // coordinate normal to the edge, [lineStart] the pixel index along the
      // edge, reads/writes are through the closures.
      void emitEdge({
        required int dir,
        required int coord, // currX (vert) / currY (horz), in plane px
        required int extent, // pw (vert) / ph (horz)
        required int miRow,
        required int miCol,
        required int pvRow,
        required int pvCol,
        required Logic Function(int tap) read,
        required void Function(int tap, Logic v) writeAt,
        required bool Function(int tap) inBounds,
      }) {
        final ts = txAt(txPort, miRow, miCol);
        final pvTs = txAt(txPort, pvRow, pvCol);
        final slot = dir == 0 ? slotV : slotH;

        // tuEdge: coord is a multiple of txSizeWide/High[ts].
        final wideTab = dir == 0 ? _txSizeWide : _txSizeHigh;
        final tuTab = [
          for (var t = 0; t < 32; t++)
            (t < wideTab.length && (coord & (wideTab[t] - 1)) == 0) ? 1 : 0,
        ];
        final tuEdge = lut(ts, tuTab, 1);

        final currLevel = levelAt(slot, miRow, miCol);
        final pvLvl = levelAt(slot, pvRow, pvCol);
        final currSkip = interSkipAt(miRow, miCol);
        final pvSkip = interSkipAt(pvRow, pvCol);

        // puEdge: coord is a multiple of the (subsampled, >=4) pred block dim.
        final blk = dir == 0
            ? dimAt('mi_block_w', miRow, miCol)
            : dimAt('mi_block_h', miRow, miCol);
        final scale = dir == 0 ? scaleH : scaleV;
        final blkShift = blk >>> scale; // 8b
        final planeDim = mux(
          blkShift.lt(Const(4, width: 8)),
          Const(4, width: 8),
          blkShift,
        );
        final predMask = (planeDim - Const(1, width: 8)).getRange(0, 8);
        final puEdge = (Const(coord, width: 8) & predMask).eq(
          Const(0, width: 8),
        );

        final levelNZ = currLevel.or() | pvLvl.or();
        final suppress = ~currSkip | ~pvSkip | puEdge;
        final edgeActive = tuEdge & levelNZ & suppress;

        final logTab = dir == 0 ? _txSizeWideUnitLog2 : _txSizeHighUnitLog2;
        final ul = lut(ts, logTab, 3);
        final pul = lut(pvTs, logTab, 3);
        final dim = mux(ul.lt(pul), ul, pul); // 3b

        // Effective threshold: currLevel!=0 ? thresh(curr) : thresh(pv).
        final tc = threshFor(slot, miRow, miCol);
        final tp = threshFor(slot, pvRow, pvCol);
        final currNZ = currLevel.or();
        final mblim = mux(currNZ, tc[0], tp[0]);
        final lim = mux(currNZ, tc[1], tp[1]);
        final hev = mux(currNZ, tc[2], tp[2]);

        if (isChroma) {
          final is4 = edgeActive & dim.eq(Const(0, width: 3));
          final is6 = edgeActive & ~dim.eq(Const(0, width: 3));
          // f4 (dim==0) taps -2..1, f6 taps -2..1 (op2/oq2 passthrough).
          final okF4 = inBounds(-2) && inBounds(1);
          final okF6 = inBounds(-3) && inBounds(2);
          final f4 = HarborDeblock4(name: 'cf4_${inst++}', bd: bd);
          addSubModule(f4);
          f4.input('p1').srcConnection! <= read(-2);
          f4.input('p0').srcConnection! <= read(-1);
          f4.input('q0').srcConnection! <= read(0);
          f4.input('q1').srcConnection! <= read(1);
          f4.input('blimit').srcConnection! <= mblim;
          f4.input('limit').srcConnection! <= lim;
          f4.input('thresh').srcConnection! <= hev;
          HarborDeblock6? f6;
          if (okF6) {
            f6 = HarborDeblock6(name: 'cf6_${inst++}', bd: bd);
            addSubModule(f6);
            f6.input('p2').srcConnection! <= read(-3);
            f6.input('p1').srcConnection! <= read(-2);
            f6.input('p0').srcConnection! <= read(-1);
            f6.input('q0').srcConnection! <= read(0);
            f6.input('q1').srcConnection! <= read(1);
            f6.input('q2').srcConnection! <= read(2);
            f6.input('blimit').srcConnection! <= mblim;
            f6.input('limit').srcConnection! <= lim;
            f6.input('thresh').srcConnection! <= hev;
          }
          void wr(int tap, String o4, String o6) {
            if (!inBounds(tap)) return;
            final pairs = <List<Logic>>[];
            if (okF4) pairs.add([is4, f4.output(o4)]);
            if (okF6 && f6 != null) pairs.add([is6, f6.output(o6)]);
            writeAt(tap, foldWrite(read(tap), pairs));
          }

          wr(-2, 'op1', 'op1');
          wr(-1, 'op0', 'op0');
          wr(0, 'oq0', 'oq0');
          wr(1, 'oq1', 'oq1');
        } else {
          final is4 = edgeActive & dim.eq(Const(0, width: 3));
          final is8 = edgeActive & dim.eq(Const(1, width: 3));
          final is14 = edgeActive & dim.gte(Const(2, width: 3));
          final okF4 = inBounds(-2) && inBounds(1);
          final okF8 = inBounds(-4) && inBounds(3);
          final okF14 = inBounds(-7) && inBounds(6);

          HarborDeblock4? f4;
          if (okF4) {
            f4 = HarborDeblock4(name: 'lf4_${inst++}', bd: bd);
            addSubModule(f4);
            f4.input('p1').srcConnection! <= read(-2);
            f4.input('p0').srcConnection! <= read(-1);
            f4.input('q0').srcConnection! <= read(0);
            f4.input('q1').srcConnection! <= read(1);
            f4.input('blimit').srcConnection! <= mblim;
            f4.input('limit').srcConnection! <= lim;
            f4.input('thresh').srcConnection! <= hev;
          }
          HarborDeblock8? f8;
          if (okF8) {
            f8 = HarborDeblock8(name: 'lf8_${inst++}', bd: bd);
            addSubModule(f8);
            const nm = ['p3', 'p2', 'p1', 'p0', 'q0', 'q1', 'q2', 'q3'];
            for (var k = 0; k < nm.length; k++) {
              f8.input(nm[k]).srcConnection! <= read(k - 4);
            }
            f8.input('blimit').srcConnection! <= mblim;
            f8.input('limit').srcConnection! <= lim;
            f8.input('thresh').srcConnection! <= hev;
          }
          HarborDeblock14? f14;
          if (okF14) {
            f14 = HarborDeblock14(name: 'lf14_${inst++}', bd: bd);
            addSubModule(f14);
            const nm = [
              'p6', 'p5', 'p4', 'p3', 'p2', 'p1', 'p0', //
              'q0', 'q1', 'q2', 'q3', 'q4', 'q5', 'q6',
            ];
            for (var k = 0; k < nm.length; k++) {
              f14.input(nm[k]).srcConnection! <= read(k - 7);
            }
            f14.input('blimit').srcConnection! <= mblim;
            f14.input('limit').srcConnection! <= lim;
            f14.input('thresh').srcConnection! <= hev;
          }

          // tap -> (f14 out, f8 out, f4 out), null when a kernel skips the tap.
          void wr(int tap, String? o14, String? o8, String? o4) {
            if (!inBounds(tap)) return;
            final pairs = <List<Logic>>[];
            if (o4 != null && okF4 && f4 != null) {
              pairs.add([is4, f4.output(o4)]);
            }
            if (o8 != null && okF8 && f8 != null) {
              pairs.add([is8, f8.output(o8)]);
            }
            if (o14 != null && okF14 && f14 != null) {
              pairs.add([is14, f14.output(o14)]);
            }
            writeAt(tap, foldWrite(read(tap), pairs));
          }

          wr(-6, 'op5', null, null);
          wr(-5, 'op4', null, null);
          wr(-4, 'op3', null, null);
          wr(-3, 'op2', 'op2', null);
          wr(-2, 'op1', 'op1', 'op1');
          wr(-1, 'op0', 'op0', 'op0');
          wr(0, 'oq0', 'oq0', 'oq0');
          wr(1, 'oq1', 'oq1', 'oq1');
          wr(2, 'oq2', 'oq2', null);
          wr(3, 'oq3', null, null);
          wr(4, 'oq4', null, null);
          wr(5, 'oq5', null, null);
        }
      }

      // vertical edges across the plane
      for (var y = 0; y < yRange; y++) {
        final currY = y * _miSize;
        for (var x = 1; x < xRange; x++) {
          final currX = x * _miSize;
          final miRow = scaleV | ((currY << scaleV) >> _miSizeLog2);
          final miCol = scaleH | ((currX << scaleH) >> _miSizeLog2);
          final pvRow = miRow;
          final pvCol = miCol - (1 << scaleH);
          if (pvCol < 0 || miRow >= miRows || miCol >= miCols) continue;
          for (var i = 0; i < _miSize; i++) {
            final row = currY + i;
            if (row >= ph) break;
            final base = row * pw;
            int clamp(int c) => c < 0 ? 0 : (c >= pw ? pw - 1 : c);
            emitEdge(
              dir: 0,
              coord: currX,
              extent: pw,
              miRow: miRow,
              miCol: miCol,
              pvRow: pvRow,
              pvCol: pvCol,
              read: (tap) => grid[base + clamp(currX + tap)],
              writeAt: (tap, v) => grid[base + (currX + tap)] = v,
              inBounds: (tap) => currX + tap >= 0 && currX + tap < pw,
            );
          }
        }
      }

      // horizontal edges on the vertically-filtered result
      for (var x = 0; x < xRange; x++) {
        final currX = x * _miSize;
        for (var y = 1; y < yRange; y++) {
          final currY = y * _miSize;
          final miRow = scaleV | ((currY << scaleV) >> _miSizeLog2);
          final miCol = scaleH | ((currX << scaleH) >> _miSizeLog2);
          final pvRow = miRow - (1 << scaleV);
          final pvCol = miCol;
          if (pvRow < 0 || miRow >= miRows || miCol >= miCols) continue;
          for (var i = 0; i < _miSize; i++) {
            final col = currX + i;
            if (col >= pw) break;
            int clamp(int r) => r < 0 ? 0 : (r >= ph ? ph - 1 : r);
            emitEdge(
              dir: 1,
              coord: currY,
              extent: ph,
              miRow: miRow,
              miCol: miCol,
              pvRow: pvRow,
              pvCol: pvCol,
              read: (tap) => grid[clamp(currY + tap) * pw + col],
              writeAt: (tap, v) => grid[(currY + tap) * pw + col] = v,
              inBounds: (tap) => currY + tap >= 0 && currY + tap < ph,
            );
          }
        }
      }
    }

    // luma plane
    final srcY = input('frame');
    final gridY = <Logic>[
      for (var i = 0; i < width * height; i++)
        srcY.getRange(i * bd, i * bd + bd),
    ];
    deblockPlane(
      grid: gridY,
      pw: width,
      ph: height,
      scaleH: 0,
      scaleV: 0,
      txPort: 'mi_tx_y',
      slotV: 'mi_level_yv',
      slotH: 'mi_level_yh',
      isChroma: false,
    );
    output('out') <=
        [for (var i = width * height - 1; i >= 0; i--) gridY[i]].swizzle();

    // chroma planes
    if (numPlanes == 3) {
      for (final plane in const ['u', 'v']) {
        final src = input('frame_$plane');
        final grid = <Logic>[
          for (var i = 0; i < cw * ch; i++) src.getRange(i * bd, i * bd + bd),
        ];
        deblockPlane(
          grid: grid,
          pw: cw,
          ph: ch,
          scaleH: subX,
          scaleV: subY,
          txPort: 'mi_tx_uv',
          slotV: 'mi_level_$plane',
          slotH: 'mi_level_$plane',
          isChroma: true,
        );
        output('out_$plane') <=
            [for (var i = cw * ch - 1; i >= 0; i--) grid[i]].swizzle();
      }
    }
  }
}
