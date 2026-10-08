import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import 'codec.dart';
import 'coeff_decoder.dart';
import 'inter_predictor.dart';
import 'intra_line_buffer.dart';
import 'intra_predictor.dart';

/// N-point integer DCT-II basis matrix (orthonormal, scaled by 4096).
List<List<int>> _dctMatrix(int n) => [
  for (var k = 0; k < n; k++)
    [
      for (var i = 0; i < n; i++)
        ((k == 0 ? sqrt(1 / n) : sqrt(2 / n)) *
                cos((2 * i + 1) * k * pi / (2 * n)) *
                4096)
            .round(),
    ],
];

/// N-point integer DST-VII (ADST) basis matrix, scaled by 4096.
List<List<int>> _adstMatrix(int n) => [
  for (var k = 0; k < n; k++)
    [
      for (var i = 0; i < n; i++)
        (sqrt(4 / (2 * n + 1)) *
                sin(pi * (2 * i + 1) * (k + 1) / (2 * n + 1)) *
                4096)
            .round(),
    ],
];

/// Transpose of a square integer matrix (the inverse of an orthonormal basis).
List<List<int>> _transpose(List<List<int>> m) => [
  for (var i = 0; i < m.length; i++)
    [for (var j = 0; j < m.length; j++) m[j][i]],
];

/// Harbor Media Engine: hardware video/image codec accelerator.
///
/// Provides encode and decode acceleration for video and image formats.
/// Supports multiple simultaneous sessions with independent codec
/// configurations. Designed for integration into GPU or standalone
/// media processing pipelines.
///
/// Architecture:
/// - **Session manager**: Up to [maxSessions] concurrent encode/decode sessions
/// - **Decoder pipeline**: Bitstream parser, entropy decoder, inverse transform,
///   motion compensation, deblocking filter, output DMA
/// - **Encoder pipeline**: Motion estimation, transform, entropy encoder,
///   rate control, output DMA
/// - **Frame buffer manager**: Manages reference frames and DPB
///   (Decoded Picture Buffer)
/// - **DMA engine**: Reads input buffers and writes output buffers
///
/// Register map (each register in its own 64-bit-aligned slot, so a 32-bit
/// access lands in the low word on both a 32-bit and a 64-bit fabric, and the
/// byte-address decode needs no high/low-half selection):
/// - 0x000: ENGINE_CTRL     (enable, reset, power state)
/// - 0x008: ENGINE_STATUS   (busy sessions, idle, error)
/// - 0x010: ENGINE_CAPS     (supported codecs bitmask, read-only)
/// - 0x018: ENGINE_VERSION  (hardware version, read-only)
/// - 0x020: INT_STATUS      (per-session done/error bits, W1C)
/// - 0x028: INT_ENABLE      (interrupt enable mask)
///
/// Per-session registers (0x100 + session * 0x100):
/// - +0x00: SESS_CTRL       (codec select, direction, start, abort)
/// - +0x08: SESS_STATUS     (idle/busy/done/error, progress)
/// - +0x10: SESS_SRC_ADDR   (source buffer DMA address)
/// - +0x18: SESS_SRC_SIZE   (source buffer size in bytes)
/// - +0x20: SESS_DST_ADDR   (destination buffer DMA address)
/// - +0x28: SESS_DST_SIZE   (destination buffer size / bytes written)
/// - +0x30: SESS_WIDTH      (frame width in pixels)
/// - +0x38: SESS_HEIGHT     (frame height in pixels)
/// - +0x40: SESS_PIXEL_FMT  (input/output pixel format)
/// - +0x48: SESS_BITRATE    (target bitrate for encoding, Kbps)
/// - +0x50: SESS_QP         (quantization parameter / CRF value)
/// - +0x58: SESS_RC_MODE    (rate control mode)
/// - +0x60: SESS_FPS        (framerate numerator)
/// - +0x68: SESS_FPS_DEN    (framerate denominator)
/// - +0x70: SESS_GOP_SIZE   (group of pictures size for encoding)
/// - +0x78: SESS_REF_FRAMES (max reference frames)
/// - +0x80: SESS_PROFILE    (codec profile)
/// - +0x88: SESS_LEVEL      (codec level)
/// - +0x90: SESS_BYTES_DONE (bytes processed, read-only)
/// - +0x98: SESS_FRAMES_DONE (frames processed, read-only)
class HarborMediaEngine extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Supported codec instances.
  final List<HarborCodecInstance> codecs;

  /// Maximum concurrent sessions.
  final int maxSessions;

  /// DMA address width.
  final int dmaAddrWidth;

  /// Inter-prediction interpolation tap count: 2 (bilinear) or 8 (AV1 sub-pel).
  /// With 8 taps the reference patch is 15x15 and a `filter_type` is selectable
  /// per session. With 2 it stays the cheap 9x9 bilinear path.
  final int interpTaps;

  /// Maximum block columns the on-chip intra line buffer spans (frame width in
  /// blocks). Bounds the tiled multi-block decode loop's row length.
  final int tileMaxCols;

  /// Use the real libaom od_ec range coder for the coefficient decoder (the
  /// byte feed widens to three bytes and the window inits from the stream bytes
  /// rather than a 64-bit load). Default keeps the simplified range coder.
  final bool useOdEc;

  /// Bus slave port for register access.
  late final BusSlavePort bus;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  /// DMA read interface.
  Logic get dmaReadAddr => output('dma_read_addr');
  Logic get dmaReadReq => output('dma_read_req');
  Logic get dmaReadData => input('dma_read_data');
  Logic get dmaReadValid => input('dma_read_valid');

  /// DMA write interface.
  Logic get dmaWriteAddr => output('dma_write_addr');
  Logic get dmaWriteData => output('dma_write_data');
  Logic get dmaWriteBe => output('dma_write_be');
  Logic get dmaWriteReq => output('dma_write_req');
  Logic get dmaWriteAck => input('dma_write_ack');

  HarborMediaEngine({
    required this.baseAddress,
    required this.codecs,
    this.maxSessions = 4,
    this.dmaAddrWidth = 32,
    this.interpTaps = 2,
    this.tileMaxCols = 8,
    this.useOdEc = false,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : assert(interpTaps == 2 || interpTaps == 8, 'only 2-tap or 8-tap'),
       super('HarborMediaEngine', name: name ?? 'media_engine') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    addOutput('interrupt');

    // DMA read port
    addOutput('dma_read_addr', width: dmaAddrWidth);
    addOutput('dma_read_req');
    createPort('dma_read_data', PortDirection.input, width: 128);
    createPort('dma_read_valid', PortDirection.input);

    // DMA write port. `dma_write_be` is a per-byte write-enable (16 bits for the
    // 128-bit beat). It is all-ones for normal full-beat writes, and selects the
    // valid half-beat for 2D frame-buffer writes of a 4x4 block row.
    addOutput('dma_write_addr', width: dmaAddrWidth);
    addOutput('dma_write_data', width: 128);
    addOutput('dma_write_be', width: 16);
    addOutput('dma_write_req');
    createPort('dma_write_ack', PortDirection.input);

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: 12,
      dataWidth: 32,
    );

    final clk = input('clk');
    final reset = input('reset');

    // Engine-level registers
    final engineCtrl = Logic(name: 'engine_ctrl', width: 32);
    final engineStatus = Logic(name: 'engine_status', width: 32);
    final intStatus = Logic(name: 'int_status', width: maxSessions);
    final intEnable = Logic(name: 'int_enable', width: maxSessions);

    // Codec capabilities bitmask
    var capsBits = 0;
    for (final c in codecs) {
      capsBits |= 1 << c.format.index;
    }
    final engineCaps = Const(capsBits, width: 32);

    interrupt <= (intStatus & intEnable).or();

    // Per-session state
    final sessCtrl = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_ctrl', width: 32),
    ];
    final sessStatus = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_status', width: 32),
    ];
    final sessSrcAddr = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_src_addr', width: dmaAddrWidth),
    ];
    final sessSrcSize = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_src_size', width: 32),
    ];
    final sessDstAddr = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_dst_addr', width: dmaAddrWidth),
    ];
    final sessDstSize = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_dst_size', width: 32),
    ];
    final sessWidth = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_width', width: 16),
    ];
    final sessHeight = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_height', width: 16),
    ];
    final sessPixFmt = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_pix_fmt', width: 8),
    ];
    final sessBitrate = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_bitrate', width: 32),
    ];
    final sessQp = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_qp', width: 8),
    ];
    // Reference-frame row stride in samples (gather mode, SESS_PIXEL_FMT slot).
    final sessRefStride = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_ref_stride', width: 16),
    ];
    final sessRcMode = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_rc_mode', width: 4),
    ];
    final sessBytesDone = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_bytes_done', width: 32),
    ];
    final sessFramesDone = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_frames_done', width: 32),
    ];

    // n-point integer transform datapath (dct/adst/flipadst/idtx). One
    // time-multiplexed 1D core transforms a row or column per cycle, so the
    // multiplier count is fixed as size grows. Rows use the horizontal type,
    // columns the vertical (AV1's 2D mixed transforms). Block size 4 or 8 is
    // per-session. Blocks live in a stride-8 grid for uniform row/column access.
    const w = 40; // signed two's-complement working width
    const dctShift = 12; // basis matrices are scaled by 2^12 = 4096
    final dct4 = _dctMatrix(4);
    final dct4t = _transpose(dct4);
    final dct8 = _dctMatrix(8);
    final dct8t = _transpose(dct8);
    final adst4 = _adstMatrix(4);
    final adst4t = _transpose(adst4);
    final adst8 = _adstMatrix(8);
    final adst8t = _transpose(adst8);

    final sessW = maxSessions <= 1 ? 1 : (maxSessions - 1).bitLength;
    const stIdle = 0;
    const stRead = 1;
    const stRows = 2;
    const stCols = 3;
    const stWrite = 4;
    const stDone = 5;
    const stBitLoad = 6; // load the coded bitstream into the coeff decoder
    const stEntWait = 7; // run the coefficient decoder, feeding it bytes
    const stEntRefill = 8; // DMA the next stream beat for the byte feed
    const stEntRead = 9; // read decoded coefficients into the block buffer
    const stNbrRead = 10; // DMA the intra-prediction neighbours
    const stPredict = 11; // reconstruct = intra prediction + residual
    const stRefRead = 12; // DMA the inter-prediction reference patch
    const stInterPred = 13; // reconstruct = inter prediction + residual
    const stStore = 14; // store the block's edges into the intra line buffer
    const stNewRow = 15; // pulse new_row at the start of a tiled block row
    const stMvRead = 16; // read the per-block motion vector from the field
    const stPatchGather = 17; // strided fetch of the reference patch at the MV

    final engState = Logic(name: 'eng_state', width: 5);
    final activeSess = Logic(name: 'active_sess', width: sessW);
    final beatCnt = Logic(name: 'beat_cnt', width: 3);
    final passIdx = Logic(name: 'pass_idx', width: 3);
    final srcAddrReg = Logic(name: 'src_addr_reg', width: dmaAddrWidth);
    final dstAddrReg = Logic(name: 'dst_addr_reg', width: dmaAddrWidth);
    final dirReg = Logic(name: 'dir_reg'); // 0 = forward, 1 = inverse
    final sizeReg = Logic(name: 'size_reg'); // 0 = 4x4, 1 = 8x8
    final hType = Logic(name: 'h_type', width: 2); // row transform type
    final vType = Logic(name: 'v_type', width: 2); // column transform type
    final qpReg = Logic(name: 'qp_reg', width: 8); // dequant quantizer index
    final deqEnReg = Logic(name: 'deq_en_reg'); // dequantize before inverse
    final decModeReg = Logic(name: 'dec_mode_reg'); // entropy-decode source
    final scanOrderReg = Logic(name: 'scan_order_reg'); // AV1 diagonal scan
    final entPhase = Logic(name: 'ent_phase'); // 0 = decode, 1 = capture
    final entRow = Logic(name: 'ent_row', width: 3);
    final entCol = Logic(name: 'ent_col', width: 3);
    // Double-buffered stream beats for the decoder byte feed: beatA holds the
    // bytes around the read cursor, beatB the next beat (so two consecutive
    // bytes are always available even across a beat boundary).
    final beatA = Logic(name: 'beat_a', width: 128);
    final beatB = Logic(name: 'beat_b', width: 128);
    final rfByte = Logic(
      name: 'rf_byte',
      width: 5,
    ); // cursor into beatA (0..16)
    final rfPop = Logic(name: 'rf_pop', width: 2); // bytes consumed last decode
    // Intra prediction: reconstruct = prediction(neighbours) + residual.
    final predEnReg = Logic(name: 'pred_en_reg');
    final predModeReg = Logic(name: 'pred_mode_reg', width: 3);
    final nbrAddrReg = Logic(name: 'nbr_addr_reg', width: dmaAddrWidth);
    final nbrA = Logic(name: 'nbr_a', width: 128); // above-left + above row
    final nbrB = Logic(name: 'nbr_b', width: 128); // left column
    // Inter prediction: reconstruct = motion-compensated reference + residual.
    // The 9x9 reference patch is six DMA beats. frac_x/frac_y are the 1/16-pel
    // sub-pixel offsets from the motion vector. The patch base address reuses
    // the prediction-source address (SESS_SRC_SIZE), same as the neighbours.
    final interEnReg = Logic(name: 'inter_en_reg');
    final fracXReg = Logic(name: 'frac_x_reg', width: 4);
    final fracYReg = Logic(name: 'frac_y_reg', width: 4);
    final filterTypeReg = Logic(name: 'filter_type_reg', width: 2);
    // Real reference-frame gather (SESS_CTRL[26], tiled+inter, bilinear): each
    // block reads a per-block MV from a motion field (SESS_DST_SIZE base, one
    // 32-bit MV per beat: [7:0] mvx, [15:8] mvy, [19:16] frac_x, [23:20] frac_y,
    // unsigned integer MV) then fetches its 9x9 patch from the reference frame
    // (SESS_SRC_SIZE base, frame width = blkCols*N samples) at (block + MV),
    // two aligned beats per patch row with an unaligned sample extract.
    final realGatherReg = Logic(name: 'real_gather_reg');
    final refStrideReg = Logic(
      name: 'ref_stride_reg',
      width: 16,
    ); // samples/row
    final mvAddrReg = Logic(name: 'mv_addr_reg', width: dmaAddrWidth);
    final prReg = Logic(name: 'pr_reg', width: 4); // patch row 0..8
    final rowBaseReg = Logic(name: 'row_base_reg', width: dmaAddrWidth);
    final sampleOffReg = Logic(name: 'sample_off_reg', width: 3);
    final patchBeat0 = Logic(name: 'patch_beat0', width: 128);
    final patchPx = interpTaps == 2
        ? [for (var i = 0; i < 81; i++) Logic(name: 'patch_px_$i', width: 8)]
        : <Logic>[];
    // Tiled multi-block decode loop: walk a grid of blocks in raster order,
    // feeding intra neighbours from the on-chip line buffer (SESS_CTRL[7]).
    // SESS_WIDTH = block columns, SESS_HEIGHT = block rows.
    final tileColW = tileMaxCols <= 1 ? 1 : (tileMaxCols - 1).bitLength;
    final tiledReg = Logic(name: 'tiled_reg');
    final bcReg = Logic(name: 'bc_reg', width: tileColW); // current block col
    final brReg = Logic(name: 'br_reg', width: 8); // current block row
    final blkColsM1 = Logic(name: 'blk_cols_m1', width: tileColW);
    final blkRowsM1 = Logic(name: 'blk_rows_m1', width: 8);
    // 2D frame-buffer output: write each block to its true (x,y) raster position
    // (frame width = blkCols*N samples) instead of block-sequential (SESS_CTRL
    // [12], tiled mode only).
    final frame2DReg = Logic(name: 'frame2d_reg');
    // 9x9 patch (bilinear) is 6 beats, 15x15 (8-tap) is 15 beats.
    final patchDim = 8 + interpTaps - 1;
    final patchBits = patchDim * patchDim * 8;
    final refBeatCount = (patchBits + 127) ~/ 128;
    final refCnt = Logic(
      name: 'ref_cnt',
      width: 4,
    ); // 0..14 for the patch fetch
    final refBeat = [
      for (var i = 0; i < refBeatCount; i++)
        Logic(name: 'ref_beat_$i', width: 128),
    ];
    final dmaReadAddrReg = Logic(name: 'dma_rd_addr_reg', width: dmaAddrWidth);
    final dmaReadReqReg = Logic(name: 'dma_rd_req_reg');
    final dmaWriteAddrReg = Logic(name: 'dma_wr_addr_reg', width: dmaAddrWidth);
    final dmaWriteReqReg = Logic(name: 'dma_wr_req_reg');
    final blk = [for (var i = 0; i < 64; i++) Logic(name: 'blk_$i', width: 16)];
    final tmp = [for (var i = 0; i < 64; i++) Logic(name: 'tmp_$i', width: 32)];

    // Signed helpers operating on w-bit two's-complement values.
    Logic sx(Logic v) => [v[v.width - 1].replicate(w - v.width), v].swizzle();
    Logic constW(int c) => Const(c & ((1 << w) - 1), width: w);
    Logic busToAddr(Logic d) => dmaAddrWidth <= 32
        ? d.getRange(0, dmaAddrWidth)
        : d.zeroExtend(dmaAddrWidth);
    Logic addrToBus(Logic a) =>
        dmaAddrWidth >= 32 ? a.getRange(0, 32) : a.zeroExtend(32);
    Logic ashr(Logic v, int s) =>
        [v[w - 1].replicate(s), v.getRange(s, w)].swizzle();
    Logic rshift(Logic v) => ashr(
      (v + Const(1 << (dctShift - 1), width: w)).getRange(0, w),
      dctShift,
    );
    // Selects arr[idx] from a list addressed by a runtime index.
    Logic selByIdx(List<Logic> arr, Logic idx) {
      Logic v = arr.last;
      for (var i = arr.length - 2; i >= 0; i--) {
        v = mux(idx.eq(Const(i, width: idx.width)), arr[i], v);
      }
      return v;
    }

    // Dequantizer: a decoder scales each coefficient by a quantizer derived
    // from the quantizer index before the inverse transform (DC and AC use
    // separate steps). This is a compact linear model of AV1's dc/ac_qlookup
    // tables. Real silicon would index the exact 256-entry tables. Only applied
    // on the inverse direction when dequant is enabled.
    final dcQ = ((qpReg.zeroExtend(16) << 1) + Const(4, width: 16)).named(
      'dc_q',
    );
    final acQ = ((qpReg.zeroExtend(16) << 2) + Const(8, width: 16)).named(
      'ac_q',
    );
    Logic deqLoad(Logic sample, {required bool isDc}) {
      final s32 = [sample[15].replicate(16), sample].swizzle();
      final scaled = (s32 * (isDc ? dcQ : acQ).zeroExtend(32)).getRange(0, 16);
      return mux(dirReg & deqEnReg, scaled, sample);
    }

    // Runtime-DC variant (the DC position is data-driven under the AV1 scan).
    Logic deqLoadR(Logic sample, Logic isDc) {
      final s32 = [sample[15].replicate(16), sample].swizzle();
      final scaled = (s32 * mux(isDc, dcQ, acQ).zeroExtend(32)).getRange(0, 16);
      return mux(dirReg & deqEnReg, scaled, sample);
    }

    final size8 = sizeReg.named('size8');
    final stateCols = engState.eq(Const(stCols, width: 5)).named('state_cols');
    // Current pass type: rows use the horizontal type, columns the vertical.
    final passType = mux(stateCols, vType, hType);
    final useAdst =
        (passType.eq(Const(1, width: 2)) | // ADST
                passType.eq(Const(2, width: 2)))
            .named('use_adst'); // FLIPADST
    final flipT = passType.eq(Const(2, width: 2)).named('flip_t');
    final identityT = passType.eq(Const(3, width: 2)).named('identity_t');

    // The 1D input vector: a row of blk (row pass) or a column of tmp (column
    // pass), selected by the pass index.
    final coreIn = <Logic>[];
    for (var n = 0; n < 8; n++) {
      final rowEl = sx(
        selByIdx([for (var r = 0; r < 8; r++) blk[r * 8 + n]], passIdx),
      );
      final colEl = sx(
        selByIdx([for (var r = 0; r < 8; r++) tmp[n * 8 + r]], passIdx),
      );
      coreIn.add(mux(stateCols, colEl, rowEl).named('core_in_$n'));
    }

    // 1D transform core: a matrix multiply (DCT or ADST, forward or inverse),
    // an output flip (FLIPADST), or a per-element scale (IDTX).
    Logic macRow(
      int npts,
      List<List<int>> mf,
      List<List<int>> mi,
      List<List<int>> af,
      List<List<int>> ai,
      int k,
    ) {
      Logic acc = Const(0, width: w);
      for (var n = 0; n < npts; n++) {
        final dctC = mux(dirReg, constW(mi[k][n]), constW(mf[k][n]));
        final adstC = mux(dirReg, constW(ai[k][n]), constW(af[k][n]));
        acc = (acc + (coreIn[n] * mux(useAdst, adstC, dctC)).getRange(0, w))
            .getRange(0, w);
      }
      return rshift(acc);
    }

    final mat4 = [
      for (var k = 0; k < 4; k++) macRow(4, dct4, dct4t, adst4, adst4t, k),
    ];
    final mat8 = [
      for (var k = 0; k < 8; k++) macRow(8, dct8, dct8t, adst8, adst8t, k),
    ];
    final matSel = [
      for (var k = 0; k < 8; k++)
        mux(size8, mat8[k], k < 4 ? mat4[k] : Const(0, width: w)),
    ];
    final flipSel = [
      for (var k = 0; k < 8; k++)
        mux(size8, matSel[7 - k], k < 4 ? matSel[3 - k] : Const(0, width: w)),
    ];
    final idScale = mux(size8, Const(8192, width: w), Const(5793, width: w));
    final idtxSel = [
      for (var k = 0; k < 8; k++) rshift((coreIn[k] * idScale).getRange(0, w)),
    ];
    final coreOut = [
      for (var k = 0; k < 8; k++)
        mux(
          identityT,
          idtxSel[k],
          mux(flipT, flipSel[k], matSel[k]),
        ).named('core_out_$k'),
    ];

    // Gather the finished block into 128-bit write beats (LSB-first samples).
    final w8 = [
      for (var j = 7; j >= 0; j--)
        selByIdx([for (var b = 0; b < 8; b++) blk[b * 8 + j]], beatCnt),
    ].swizzle();
    final w4lo = [
      blk[11],
      blk[10],
      blk[9],
      blk[8],
      blk[3],
      blk[2],
      blk[1],
      blk[0],
    ].swizzle();
    final w4hi = [
      blk[27],
      blk[26],
      blk[25],
      blk[24],
      blk[19],
      blk[18],
      blk[17],
      blk[16],
    ].swizzle();

    // 2D frame-buffer write path. Each beat carries one block row (beatCnt = row
    // index) to its raster address: frame width = blkCols*N samples, so block
    // (br,bc) row r sits at dst + ((br*N+r)*strideSamples + bc*N) * 2 bytes. A
    // 4x4 row is half a beat, placed in the low or high half (byte-enable) by
    // column parity.
    final nSamp = mux(size8, Const(8, width: 16), Const(4, width: 16));
    final strideSamples =
        ((blkColsM1.zeroExtend(16) + Const(1, width: 16)) * nSamp).getRange(
          0,
          16,
        );
    final blockRowTop = (brReg.zeroExtend(16) * nSamp).getRange(0, 16);
    final frameRow = (blockRowTop + beatCnt.zeroExtend(16)).getRange(0, 16);
    final colSamp = (bcReg.zeroExtend(16) * nSamp).getRange(0, 16);
    final sampleOff =
        ((frameRow.zeroExtend(32) * strideSamples.zeroExtend(32)).getRange(
                  0,
                  32,
                ) +
                colSamp.zeroExtend(32))
            .getRange(0, 32);
    final byteOff = (sampleOff << 1).getRange(0, 32); // 2 bytes per sample
    final writeAddr2D =
        (dstAddrReg +
                (dmaAddrWidth <= 32
                    ? byteOff.getRange(0, dmaAddrWidth)
                    : byteOff.zeroExtend(dmaAddrWidth)))
            .getRange(0, dmaAddrWidth);
    final w4row = [
      for (var j = 3; j >= 0; j--)
        selByIdx([for (var b = 0; b < 4; b++) blk[b * 8 + j]], beatCnt),
    ].swizzle(); // one 4x4 row (4 samples, 64 bits)
    final bcOdd = bcReg[0];
    final data2D = mux(
      size8,
      w8,
      mux(bcOdd, [w4row, Const(0, width: 64)].swizzle(), w4row.zeroExtend(128)),
    );
    final be2D = mux(
      size8,
      Const(0xFFFF, width: 16),
      mux(bcOdd, Const(0xFF00, width: 16), Const(0x00FF, width: 16)),
    );

    // real reference-frame gather. Patch base (samples) = block origin
    // (bc*N, br*N) + the per-block MV (read into dma_read_data during stMvRead).
    // The 9x9 patch is fetched two aligned beats per row: the row's beat-aligned
    // column is patchBaseX & ~7, and the 9 patch samples start at
    // sampleOff = patchBaseX & 7 within the 16 samples of the two beats.
    final refStrideBytes = (refStrideReg << 1).getRange(0, 16);
    final mvxRaw = input('dma_read_data').getRange(0, 8);
    final mvyRaw = input('dma_read_data').getRange(8, 16);
    // Signed integer MV (two's complement): the patch base may be negative or
    // run past the frame, so the reference buffer is expected to carry a border.
    final patchBaseX = (colSamp + mvxRaw.signExtend(16)).getRange(0, 16);
    final patchBaseY = (blockRowTop + mvyRaw.signExtend(16)).getRange(0, 16);
    final alignedCol = [
      patchBaseX.getRange(3, 16),
      Const(0, width: 3),
    ].swizzle(); // & ~7
    // The low bits of the unsigned product of the two's-complement operands
    // equal the signed product (mod 2^32), so the offset is correct for
    // negative patchBaseY / alignedCol too.
    final pr0SampleOff =
        ((patchBaseY.signExtend(32) * refStrideReg.zeroExtend(32)).getRange(
                  0,
                  32,
                ) +
                alignedCol.signExtend(32))
            .getRange(0, 32);
    final pr0ByteOff = (pr0SampleOff << 1).getRange(0, 32);
    final pr0RowAddr =
        (nbrAddrReg +
                (dmaAddrWidth <= 32
                    ? pr0ByteOff.getRange(0, dmaAddrWidth)
                    : pr0ByteOff.signExtend(dmaAddrWidth)))
            .getRange(0, dmaAddrWidth);
    // The two-beat window of 16 ref samples (low bytes) and a runtime extract.
    final gatherSamples = [
      for (var s = 0; s < 8; s++) patchBeat0.getRange(s * 16, s * 16 + 8),
      for (var s = 0; s < 8; s++)
        input('dma_read_data').getRange(s * 16, s * 16 + 8),
    ];
    Logic gatherByteAt(Logic idx) {
      Logic v = gatherSamples.last;
      for (var i = gatherSamples.length - 2; i >= 0; i--) {
        v = mux(idx.eq(Const(i, width: 4)), gatherSamples[i], v);
      }
      return v;
    }

    final patchByte = [
      for (var c = 0; c < 9; c++)
        gatherByteAt(
          (sampleOffReg.zeroExtend(4) + Const(c, width: 4)).getRange(0, 4),
        ),
    ];

    output('dma_read_addr') <= dmaReadAddrReg;
    output('dma_read_req') <= dmaReadReqReg;
    output('dma_write_addr') <= mux(frame2DReg, writeAddr2D, dmaWriteAddrReg);
    output('dma_write_req') <= dmaWriteReqReg;
    output('dma_write_data') <=
        mux(frame2DReg, data2D, mux(size8, w8, mux(beatCnt[0], w4hi, w4lo)));
    output('dma_write_be') <= mux(frame2DReg, be2D, Const(0xFFFF, width: 16));

    // coefficient decoder front-end. In decode mode the engine streams the coded
    // bitstream into a HarborCoeffDecoder (a range decoder running the AV1-style
    // coefficient syntax), then reads the decoded coefficients into the block
    // buffer for the inverse transform. Two beats are buffered and bytes fed from
    // a cursor. The decoder is stalled the cycle a fresh beat is DMA'd in.
    final coeffDec = HarborCoeffDecoder(
      maxCoeffs: 64,
      useOdEc: useOdEc,
      name: 'coeff',
    );
    addSubModule(coeffDec);
    final inBitLoad = engState.eq(Const(stBitLoad, width: 5));
    final inEntRefill = engState.eq(Const(stEntRefill, width: 5));
    // Stream byte b of a beat lives in bits [(15-b)*8 +: 8] (MSB first). The
    // cursor addresses beatA bytes 0..15 then beatB bytes 0..1 (indices 16,17).
    // od_ec consumes up to three bytes per op, so two beatB bytes are exposed.
    Logic beatByte(Logic beat, int b) =>
        beat.getRange((15 - b) * 8, (16 - b) * 8);
    final bytesAll = [
      for (var b = 0; b < 16; b++) beatByte(beatA, b),
      beatByte(beatB, 0),
      beatByte(beatB, 1),
    ];
    Logic byteAtCursor(Logic idx) {
      Logic v = bytesAll.last;
      for (var i = bytesAll.length - 2; i >= 0; i--) {
        v = mux(idx.eq(Const(i, width: 5)), bytesAll[i], v);
      }
      return v;
    }

    final feedByte0 = byteAtCursor(rfByte);
    final feedByte1 = byteAtCursor(rfByte + Const(1, width: 5));
    final feedByte2 = byteAtCursor(rfByte + Const(2, width: 5));
    // Linear scan position (for the coeff buffer) and the stride-8 block index.
    final posLin = mux(
      size8,
      (entRow.zeroExtend(7) << 3) | entCol.zeroExtend(7),
      (entRow.zeroExtend(7) << 2) | entCol.zeroExtend(7),
    ).named('pos_lin');
    // AV1 default (up-right diagonal) scan: maps the linear decode position to a
    // stride-8 block index. libaom default_scan_4x4 / default_scan_8x8 (the 8x8
    // raster index already equals the stride-8 index).
    const scan4Raster = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15];
    final scan4S8 = [for (final r in scan4Raster) (r ~/ 4) * 8 + r % 4];
    const scan8S8 = [
      0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, //
      12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28, //
      35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, //
      58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ];
    Logic scanLookup(List<int> table, Logic idx) {
      Logic v = Const(table.last, width: 6);
      for (var i = table.length - 2; i >= 0; i--) {
        v = mux(idx.eq(Const(i, width: 7)), Const(table[i], width: 6), v);
      }
      return v;
    }

    final scanIdx = mux(
      size8,
      scanLookup(scan8S8, posLin),
      scanLookup(scan4S8, posLin),
    );
    coeffDec.input('clk').srcConnection! <= input('clk');
    coeffDec.input('reset').srcConnection! <= input('reset');
    coeffDec.input('start').srcConnection! <=
        (inBitLoad & input('dma_read_valid') & beatCnt[0]);
    // In tiled decode mode, continue the bitstream into the next block (reusing
    // the adapted CDFs) when advancing within a row (stStore, not the last
    // column) or starting a new row (stNewRow).
    final inStore = engState.eq(Const(stStore, width: 5));
    final inNewRow = engState.eq(Const(stNewRow, width: 5));
    coeffDec.input('next_blk').srcConnection! <=
        (tiledReg & decModeReg & ((inStore & ~bcReg.eq(blkColsM1)) | inNewRow));
    coeffDec.input('stall').srcConnection! <= inEntRefill;
    coeffDec.input('num_coeffs').srcConnection! <=
        mux(
          size8,
          Const(64, width: coeffDec.posWidth),
          Const(16, width: coeffDec.posWidth),
        );
    // od_ec inits its window from the byte feed (no 64-bit stream load) and
    // takes three bytes. The simplified coder loads the 64-bit window + 2 bytes.
    if (!useOdEc)
      coeffDec.input('stream').srcConnection! <= beatA.getRange(64, 128);
    coeffDec.input('bytes_in').srcConnection! <=
        (useOdEc
            ? [feedByte0, feedByte1, feedByte2].swizzle()
            : [feedByte0, feedByte1].swizzle());
    coeffDec.input('coeff_addr').srcConnection! <=
        posLin.getRange(0, coeffDec.posWidth);
    final coeffBytePop = coeffDec.output('byte_pop');

    // Intra line buffer: in tiled mode the neighbours come from on-chip storage
    // updated as blocks are reconstructed (no per-block neighbour DMA). The
    // bottom row / right column of the just-finished block feed its store port.
    final lineBuf = HarborIntraLineBuffer(
      maxBlockCols: tileMaxCols,
      name: 'linebuf',
    );
    addSubModule(lineBuf);
    final blockBottom = mux(
      sizeReg,
      [for (var c = 7; c >= 0; c--) blk[56 + c].getRange(0, 8)].swizzle(),
      [for (var c = 7; c >= 0; c--) blk[24 + c].getRange(0, 8)].swizzle(),
    );
    final blockRight = mux(
      sizeReg,
      [for (var r = 7; r >= 0; r--) blk[r * 8 + 7].getRange(0, 8)].swizzle(),
      [for (var r = 7; r >= 0; r--) blk[r * 8 + 3].getRange(0, 8)].swizzle(),
    );
    lineBuf.input('clk').srcConnection! <= input('clk');
    lineBuf.input('reset').srcConnection! <= input('reset');
    lineBuf.input('size').srcConnection! <= sizeReg;
    lineBuf.input('bw_col').srcConnection! <= bcReg;
    lineBuf.input('store').srcConnection! <=
        engState.eq(Const(stStore, width: 5));
    lineBuf.input('new_row').srcConnection! <=
        engState.eq(Const(stNewRow, width: 5));
    lineBuf.input('block_bottom').srcConnection! <= blockBottom;
    lineBuf.input('block_right').srcConnection! <= blockRight;

    // Intra predictor: single-block mode takes neighbours from two DMA'd beats
    // (nbrA = above-left corner in byte 0 then the above row in bytes 1..8,
    // nbrB = the left column in bytes 0..7). Tiled mode takes them from the line
    // buffer. The residual is the current block buffer.
    final intraPred = HarborIntraPredictor(name: 'intra');
    addSubModule(intraPred);
    intraPred.input('mode').srcConnection! <= predModeReg;
    intraPred.input('size').srcConnection! <= sizeReg;
    intraPred.input('above').srcConnection! <=
        mux(tiledReg, lineBuf.output('above'), nbrA.getRange(8, 72));
    intraPred.input('left').srcConnection! <=
        mux(tiledReg, lineBuf.output('left'), nbrB.getRange(0, 64));
    intraPred.input('above_left').srcConnection! <=
        mux(tiledReg, lineBuf.output('above_left'), nbrA.getRange(0, 8));
    intraPred.input('residual').srcConnection! <=
        [for (var i = 63; i >= 0; i--) blk[i]].swizzle();
    final reconOut = intraPred.output('recon');

    // Inter predictor: the reference beats concatenate low-beat-first into the
    // patch the motion compensator expects (648-bit 9x9 for bilinear, 1800-bit
    // 15x15 for 8-tap), the residual is the current block buffer, and
    // frac_x/frac_y (+ filter_type for 8-tap) come from the session.
    final interPred = HarborInterPredictor(name: 'inter', taps: interpTaps);
    addSubModule(interPred);
    // Patch source: the contiguous DMA'd beats (single-block / blob-fed inter),
    // or, in real-gather mode (bilinear only), the 81 bytes assembled from the
    // strided reference-frame reads.
    final refBeatPatch = [
      for (var i = refBeatCount - 1; i >= 0; i--) refBeat[i],
    ].swizzle().getRange(0, patchBits);
    interPred.input('ref_patch').srcConnection! <=
        (interpTaps == 2
            ? mux(
                realGatherReg,
                [for (var i = 80; i >= 0; i--) patchPx[i]].swizzle(),
                refBeatPatch,
              )
            : refBeatPatch);
    interPred.input('frac_x').srcConnection! <= fracXReg;
    interPred.input('frac_y').srcConnection! <= fracYReg;
    if (interpTaps > 2) {
      interPred.input('filter_type').srcConnection! <= filterTypeReg;
    }
    interPred.input('residual').srcConnection! <=
        [for (var i = 63; i >= 0; i--) blk[i]].swizzle();
    final interReconOut = interPred.output('recon');

    // Bytes per block in memory: 4x4 = 16 samples x 2B = 32, 8x8 = 64 x 2 = 128.
    final blockBytes = mux(
      sizeReg,
      Const(128, width: dmaAddrWidth),
      Const(32, width: dmaAddrWidth),
    );

    final entIdx = [entRow, entCol].swizzle().named('ent_idx');
    final entLast =
        (entRow.eq(mux(size8, Const(7, width: 3), Const(3, width: 3))) &
                entCol.eq(mux(size8, Const(7, width: 3), Const(3, width: 3))))
            .named('ent_last');

    Sequential(clk, [
      If(
        reset,
        then: [
          engineCtrl < Const(0, width: 32),
          engineStatus < Const(0, width: 32),
          intStatus < Const(0, width: maxSessions),
          intEnable < Const(0, width: maxSessions),
          engState < Const(stIdle, width: 5),
          activeSess < Const(0, width: sessW),
          beatCnt < Const(0, width: 3),
          passIdx < Const(0, width: 3),
          srcAddrReg < Const(0, width: dmaAddrWidth),
          dstAddrReg < Const(0, width: dmaAddrWidth),
          dirReg < Const(0),
          sizeReg < Const(0),
          hType < Const(0, width: 2),
          vType < Const(0, width: 2),
          qpReg < Const(0, width: 8),
          deqEnReg < Const(0),
          decModeReg < Const(0),
          scanOrderReg < Const(0),
          entPhase < Const(0),
          entRow < Const(0, width: 3),
          entCol < Const(0, width: 3),
          beatA < Const(0, width: 128),
          beatB < Const(0, width: 128),
          rfByte < Const(0, width: 5),
          rfPop < Const(0, width: 2),
          predEnReg < Const(0),
          predModeReg < Const(0, width: 3),
          nbrAddrReg < Const(0, width: dmaAddrWidth),
          nbrA < Const(0, width: 128),
          nbrB < Const(0, width: 128),
          interEnReg < Const(0),
          fracXReg < Const(0, width: 4),
          fracYReg < Const(0, width: 4),
          filterTypeReg < Const(0, width: 2),
          refCnt < Const(0, width: 4),
          for (var i = 0; i < refBeatCount; i++)
            refBeat[i] < Const(0, width: 128),
          tiledReg < Const(0),
          bcReg < Const(0, width: tileColW),
          brReg < Const(0, width: 8),
          blkColsM1 < Const(0, width: tileColW),
          blkRowsM1 < Const(0, width: 8),
          frame2DReg < Const(0),
          realGatherReg < Const(0),
          refStrideReg < Const(0, width: 16),
          mvAddrReg < Const(0, width: dmaAddrWidth),
          prReg < Const(0, width: 4),
          rowBaseReg < Const(0, width: dmaAddrWidth),
          sampleOffReg < Const(0, width: 3),
          patchBeat0 < Const(0, width: 128),
          for (var i = 0; i < patchPx.length; i++)
            patchPx[i] < Const(0, width: 8),
          dmaReadAddrReg < Const(0, width: dmaAddrWidth),
          dmaReadReqReg < Const(0),
          dmaWriteAddrReg < Const(0, width: dmaAddrWidth),
          dmaWriteReqReg < Const(0),
          for (var i = 0; i < 64; i++) blk[i] < Const(0, width: 16),
          for (var i = 0; i < 64; i++) tmp[i] < Const(0, width: 32),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
          for (var i = 0; i < maxSessions; i++) ...[
            sessCtrl[i] < Const(0, width: 32),
            sessStatus[i] < Const(0, width: 32),
            sessSrcAddr[i] < Const(0, width: dmaAddrWidth),
            sessSrcSize[i] < Const(0, width: 32),
            sessDstAddr[i] < Const(0, width: dmaAddrWidth),
            sessDstSize[i] < Const(0, width: 32),
            sessWidth[i] < Const(0, width: 16),
            sessHeight[i] < Const(0, width: 16),
            sessPixFmt[i] < Const(0, width: 8),
            sessRefStride[i] < Const(0, width: 16),
            sessBitrate[i] < Const(0, width: 32),
            sessQp[i] < Const(0, width: 8),
            sessRcMode[i] < Const(0, width: 4),
            sessBytesDone[i] < Const(0, width: 32),
            sessFramesDone[i] < Const(0, width: 32),
          ],
        ],
        orElse: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              // Global registers (0x000 - 0x0FF)
              If(
                bus.addr.getRange(8, 12).eq(Const(0, width: 4)),
                then: [
                  Case(bus.addr.getRange(0, 8), [
                    // ENGINE_CTRL
                    CaseItem(Const(0x00, width: 8), [
                      If(
                        bus.we,
                        then: [engineCtrl < bus.selMerge(engineCtrl, 0x00)],
                        orElse: [bus.dataOut < engineCtrl],
                      ),
                    ]),
                    // ENGINE_STATUS
                    CaseItem(Const(0x08, width: 8), [
                      bus.dataOut < engineStatus,
                    ]),
                    // ENGINE_CAPS
                    CaseItem(Const(0x10, width: 8), [bus.dataOut < engineCaps]),
                    // INT_STATUS
                    CaseItem(Const(0x20, width: 8), [
                      If(
                        bus.we,
                        then: [
                          intStatus <
                              (intStatus & ~bus.selMasked(0x20, maxSessions)),
                        ],
                        orElse: [bus.dataOut < intStatus.zeroExtend(32)],
                      ),
                    ]),
                    // INT_ENABLE
                    CaseItem(Const(0x28, width: 8), [
                      If(
                        bus.we,
                        then: [intEnable < bus.selMerge(intEnable, 0x28)],
                        orElse: [bus.dataOut < intEnable.zeroExtend(32)],
                      ),
                    ]),
                  ]),
                ],
              ),

              // Per-session registers: session N at byte 0x100 + N*0x100, so
              // bits [11:8] select the session and [7:0] the sub-register. The
              // block is 0x100, not 0x20: at 8-byte slots the session registers
              // span 0x98 and a 0x20 block put them in the next session's.
              for (var i = 0; i < maxSessions; i++)
                If(
                  bus.addr.getRange(8, 12).eq(Const(1 + i, width: 4)),
                  then: [
                    Case(bus.addr.getRange(0, 8), [
                      // +0x00 SESS_CTRL ([0] start, [1] direction, [2] size
                      // (0=4x4 1=8x8), [3] dequant enable, [4] entropy-decode
                      // source, [5] intra-predict enable, [6] inter-predict
                      // enable, [7] tiled multi-block mode (SESS_WIDTH = block
                      // columns, SESS_HEIGHT = block rows, intra neighbours from
                      // the on-chip line buffer), [9:8] horizontal type,
                      // [11:10] vertical type, [12] 2D frame-buffer output
                      // (blocks land at raster (x,y), tiled mode only),
                      // [15:13] intra mode (0 DC 1 V 2 H 3 Paeth 4 SMOOTH
                      // 5 SMOOTH_V 6 SMOOTH_H 7 D45), [19:16] inter frac_x,
                      // [23:20] inter frac_y, [25:24] inter filter type (8-tap
                      // builds: 0 REGULAR 1 SMOOTH 2 SHARP), [26] real
                      // reference-frame gather (tiled+inter bilinear:
                      // SESS_SRC_SIZE = ref frame base, SESS_DST_SIZE = motion
                      // field base), [27] AV1 diagonal scan order (else raster).
                      // Transform type
                      // 0=DCT 1=ADST 2=FLIPADST 3=IDTX. SESS_SRC_SIZE doubles
                      // as the neighbour / reference-patch buffer address.
                      CaseItem(Const(0x00, width: 8), [
                        If(
                          bus.we,
                          then: [sessCtrl[i] < bus.selMerge(sessCtrl[i], 0x00)],
                          orElse: [bus.dataOut < sessCtrl[i]],
                        ),
                      ]),
                      // +0x08 SESS_STATUS (read-only: [0] busy, [1] done)
                      CaseItem(Const(0x08, width: 8), [
                        bus.dataOut < sessStatus[i],
                      ]),
                      // +0x10 SESS_SRC_ADDR
                      CaseItem(Const(0x10, width: 8), [
                        If(
                          bus.we,
                          then: [
                            sessSrcAddr[i] <
                                busToAddr(
                                  bus.selMerge(addrToBus(sessSrcAddr[i]), 0x10),
                                ),
                          ],
                          orElse: [bus.dataOut < addrToBus(sessSrcAddr[i])],
                        ),
                      ]),
                      // +0x18 SESS_SRC_SIZE
                      CaseItem(Const(0x18, width: 8), [
                        If(
                          bus.we,
                          then: [
                            sessSrcSize[i] < bus.selMerge(sessSrcSize[i], 0x18),
                          ],
                          orElse: [bus.dataOut < sessSrcSize[i]],
                        ),
                      ]),
                      // +0x20 SESS_DST_ADDR
                      CaseItem(Const(0x20, width: 8), [
                        If(
                          bus.we,
                          then: [
                            sessDstAddr[i] <
                                busToAddr(
                                  bus.selMerge(addrToBus(sessDstAddr[i]), 0x20),
                                ),
                          ],
                          orElse: [bus.dataOut < addrToBus(sessDstAddr[i])],
                        ),
                      ]),
                      // +0x28 SESS_DST_SIZE
                      CaseItem(Const(0x28, width: 8), [
                        If(
                          bus.we,
                          then: [
                            sessDstSize[i] < bus.selMerge(sessDstSize[i], 0x28),
                          ],
                          orElse: [bus.dataOut < sessDstSize[i]],
                        ),
                      ]),
                      // +0x30 SESS_WIDTH
                      CaseItem(Const(0x30, width: 8), [
                        If(
                          bus.we,
                          then: [
                            sessWidth[i] < bus.selMerge(sessWidth[i], 0x30),
                          ],
                          orElse: [bus.dataOut < sessWidth[i].zeroExtend(32)],
                        ),
                      ]),
                      // +0x38 SESS_HEIGHT
                      CaseItem(Const(0x38, width: 8), [
                        If(
                          bus.we,
                          then: [
                            sessHeight[i] < bus.selMerge(sessHeight[i], 0x38),
                          ],
                          orElse: [bus.dataOut < sessHeight[i].zeroExtend(32)],
                        ),
                      ]),
                      // +0x40 SESS_REF_STRIDE (gather: ref-frame samples/row)
                      CaseItem(Const(0x40, width: 8), [
                        If(
                          bus.we,
                          then: [
                            sessRefStride[i] <
                                bus.selMerge(sessRefStride[i], 0x40),
                          ],
                          orElse: [
                            bus.dataOut < sessRefStride[i].zeroExtend(32),
                          ],
                        ),
                      ]),
                      // +0x50 SESS_QP (dequantizer index)
                      CaseItem(Const(0x50, width: 8), [
                        If(
                          bus.we,
                          then: [sessQp[i] < bus.selMerge(sessQp[i], 0x50)],
                          orElse: [bus.dataOut < sessQp[i].zeroExtend(32)],
                        ),
                      ]),
                      // +0x90 SESS_BYTES_DONE (read-only)
                      CaseItem(Const(0x90, width: 8), [
                        bus.dataOut < sessBytesDone[i],
                      ]),
                      // +0x98 SESS_FRAMES_DONE (read-only)
                      CaseItem(Const(0x98, width: 8), [
                        bus.dataOut < sessFramesDone[i],
                      ]),
                    ]),
                  ],
                ),
            ],
          ),

          // session FSM: DMA in, row transform, column transform, out.
          Case(engState, [
            CaseItem(Const(stIdle, width: 5), [
              // When enabled, start the lowest-numbered session with its start
              // bit set (priority select).
              If(
                engineCtrl[0],
                then: [
                  for (var i = maxSessions - 1; i >= 0; i--)
                    If(
                      sessCtrl[i][0],
                      then: [
                        activeSess < Const(i, width: sessW),
                        srcAddrReg < sessSrcAddr[i],
                        dstAddrReg < sessDstAddr[i],
                        dirReg < sessCtrl[i][1],
                        sizeReg < sessCtrl[i][2],
                        deqEnReg < sessCtrl[i][3],
                        decModeReg < sessCtrl[i][4],
                        scanOrderReg < sessCtrl[i][27],
                        predEnReg < sessCtrl[i][5],
                        interEnReg < sessCtrl[i][6],
                        fracXReg < sessCtrl[i].getRange(16, 20),
                        fracYReg < sessCtrl[i].getRange(20, 24),
                        filterTypeReg < sessCtrl[i].getRange(24, 26),
                        realGatherReg < sessCtrl[i][26],
                        refStrideReg < sessRefStride[i],
                        // SESS_DST_SIZE is the motion-field base in gather mode.
                        mvAddrReg <
                            (dmaAddrWidth <= 32
                                ? sessDstSize[i].getRange(0, dmaAddrWidth)
                                : sessDstSize[i].zeroExtend(dmaAddrWidth)),
                        predModeReg < sessCtrl[i].getRange(13, 16),
                        hType < sessCtrl[i].getRange(8, 10),
                        vType < sessCtrl[i].getRange(10, 12),
                        qpReg < sessQp[i],
                        // SESS_SRC_SIZE doubles as the neighbour buffer address.
                        nbrAddrReg <
                            (dmaAddrWidth <= 32
                                ? sessSrcSize[i].getRange(0, dmaAddrWidth)
                                : sessSrcSize[i].zeroExtend(dmaAddrWidth)),
                        sessCtrl[i] < (sessCtrl[i] & ~Const(1, width: 32)),
                        sessStatus[i] < Const(1, width: 32), // busy
                        beatCnt < Const(0, width: 3),
                        // Tiled mode: SESS_CTRL[7], grid from SESS_WIDTH/HEIGHT.
                        tiledReg < sessCtrl[i][7],
                        bcReg < Const(0, width: tileColW),
                        brReg < Const(0, width: 8),
                        blkColsM1 <
                            (sessWidth[i] - Const(1, width: 16)).getRange(
                              0,
                              tileColW,
                            ),
                        blkRowsM1 <
                            (sessHeight[i] - Const(1, width: 16)).getRange(
                              0,
                              8,
                            ),
                        frame2DReg < sessCtrl[i][12],
                        // Decode mode (stBitLoad) and single-block coeff mode read
                        // now. Tiled coefficient-load mode issues its read later in
                        // stNewRow, so leave the request deasserted there.
                        dmaReadReqReg < (sessCtrl[i][4] | ~sessCtrl[i][7]),
                        dmaReadAddrReg < sessSrcAddr[i],
                        // Decode mode inits the bitstream window first (stBitLoad)
                        // whether tiled or not. Tiled coefficient-load mode runs the
                        // per-row loop, otherwise read the source block directly.
                        engState <
                            mux(
                              sessCtrl[i][4],
                              Const(stBitLoad, width: 5),
                              mux(
                                sessCtrl[i][7],
                                Const(stNewRow, width: 5),
                                Const(stRead, width: 5),
                              ),
                            ),
                      ],
                    ),
                ],
              ),
            ]),
            // DMA the source block in, scattering it into the stride-8 grid.
            CaseItem(Const(stRead, width: 5), [
              If(
                input('dma_read_valid'),
                then: [
                  If(
                    size8,
                    then: [
                      for (var pc = 0; pc < 8; pc++)
                        If(
                          beatCnt.eq(Const(pc, width: 3)),
                          then: [
                            for (var j = 0; j < 8; j++)
                              blk[pc * 8 + j] <
                                  deqLoad(
                                    input(
                                      'dma_read_data',
                                    ).getRange(j * 16, j * 16 + 16),
                                    isDc: pc == 0 && j == 0,
                                  ),
                          ],
                        ),
                    ],
                    orElse: [
                      If(
                        beatCnt.eq(Const(0, width: 3)),
                        then: [
                          for (var j = 0; j < 4; j++)
                            blk[j] <
                                deqLoad(
                                  input(
                                    'dma_read_data',
                                  ).getRange(j * 16, j * 16 + 16),
                                  isDc: j == 0,
                                ),
                          for (var j = 4; j < 8; j++)
                            blk[8 + (j - 4)] <
                                deqLoad(
                                  input(
                                    'dma_read_data',
                                  ).getRange(j * 16, j * 16 + 16),
                                  isDc: false,
                                ),
                        ],
                        orElse: [
                          for (var j = 0; j < 4; j++)
                            blk[16 + j] <
                                deqLoad(
                                  input(
                                    'dma_read_data',
                                  ).getRange(j * 16, j * 16 + 16),
                                  isDc: false,
                                ),
                          for (var j = 4; j < 8; j++)
                            blk[24 + (j - 4)] <
                                deqLoad(
                                  input(
                                    'dma_read_data',
                                  ).getRange(j * 16, j * 16 + 16),
                                  isDc: false,
                                ),
                        ],
                      ),
                    ],
                  ),
                  If(
                    mux(
                      size8,
                      beatCnt.eq(Const(7, width: 3)),
                      beatCnt.eq(Const(1, width: 3)),
                    ),
                    then: [
                      dmaReadReqReg < Const(0),
                      passIdx < Const(0, width: 3),
                      engState < Const(stRows, width: 5),
                    ],
                    orElse: [
                      beatCnt < (beatCnt + Const(1, width: 3)),
                      dmaReadAddrReg <
                          (dmaReadAddrReg + Const(16, width: dmaAddrWidth)),
                    ],
                  ),
                ],
              ),
            ]),
            // Row pass: transform row `passIdx` into tmp.
            CaseItem(Const(stRows, width: 5), [
              for (var pc = 0; pc < 8; pc++)
                If(
                  passIdx.eq(Const(pc, width: 3)),
                  then: [
                    for (var k = 0; k < 8; k++)
                      tmp[pc * 8 + k] < coreOut[k].getRange(0, 32),
                  ],
                ),
              If(
                passIdx.eq(mux(size8, Const(7, width: 3), Const(3, width: 3))),
                then: [
                  passIdx < Const(0, width: 3),
                  engState < Const(stCols, width: 5),
                ],
                orElse: [passIdx < (passIdx + Const(1, width: 3))],
              ),
            ]),
            // Column pass: transform column `passIdx` back into blk.
            CaseItem(Const(stCols, width: 5), [
              for (var pc = 0; pc < 8; pc++)
                If(
                  passIdx.eq(Const(pc, width: 3)),
                  then: [
                    for (var l = 0; l < 8; l++)
                      blk[l * 8 + pc] < coreOut[l].getRange(0, 16),
                  ],
                ),
              If(
                passIdx.eq(mux(size8, Const(7, width: 3), Const(3, width: 3))),
                then: [
                  beatCnt < Const(0, width: 3),
                  // Intra prediction fetches neighbours, inter prediction
                  // fetches the reference patch. Without either, the residual
                  // is written straight out.
                  If(
                    predEnReg,
                    then: [
                      // Tiled mode: neighbours are already in the line buffer,
                      // so reconstruct directly. Single-block mode DMAs them.
                      If(
                        tiledReg,
                        then: [engState < Const(stPredict, width: 5)],
                        orElse: [
                          dmaReadReqReg < Const(1),
                          dmaReadAddrReg < nbrAddrReg,
                          engState < Const(stNbrRead, width: 5),
                        ],
                      ),
                    ],
                    orElse: [
                      If(
                        interEnReg,
                        then: [
                          // Real gather reads the per-block MV first, otherwise
                          // fetch the contiguous reference-patch blob.
                          If(
                            realGatherReg,
                            then: [
                              dmaReadReqReg < Const(1),
                              dmaReadAddrReg < mvAddrReg,
                              engState < Const(stMvRead, width: 5),
                            ],
                            orElse: [
                              dmaReadReqReg < Const(1),
                              dmaReadAddrReg < nbrAddrReg,
                              refCnt < Const(0, width: 4),
                              engState < Const(stRefRead, width: 5),
                            ],
                          ),
                        ],
                        orElse: [
                          dmaWriteReqReg < Const(1),
                          dmaWriteAddrReg < dstAddrReg,
                          engState < Const(stWrite, width: 5),
                        ],
                      ),
                    ],
                  ),
                ],
                orElse: [passIdx < (passIdx + Const(1, width: 3))],
              ),
            ]),
            // Fetch the two neighbour beats for intra prediction.
            CaseItem(Const(stNbrRead, width: 5), [
              If(
                input('dma_read_valid'),
                then: [
                  dmaReadAddrReg <
                      (dmaReadAddrReg + Const(16, width: dmaAddrWidth)),
                  If(
                    beatCnt.eq(Const(0, width: 3)),
                    then: [
                      nbrA < input('dma_read_data'),
                      beatCnt < Const(1, width: 3),
                    ],
                    orElse: [
                      nbrB < input('dma_read_data'),
                      dmaReadReqReg < Const(0),
                      engState < Const(stPredict, width: 5),
                    ],
                  ),
                ],
              ),
            ]),
            // Reconstruct: blk = clamp(intra prediction + residual).
            CaseItem(Const(stPredict, width: 5), [
              for (var i = 0; i < 64; i++)
                blk[i] < reconOut.getRange(i * 8, i * 8 + 8).zeroExtend(16),
              beatCnt < Const(0, width: 3),
              dmaWriteReqReg < Const(1),
              dmaWriteAddrReg < dstAddrReg,
              engState < Const(stWrite, width: 5),
            ]),
            // Fetch the reference-patch beats for inter prediction (6 for the
            // 9x9 bilinear patch, 15 for the 15x15 8-tap patch).
            CaseItem(Const(stRefRead, width: 5), [
              If(
                input('dma_read_valid'),
                then: [
                  dmaReadAddrReg <
                      (dmaReadAddrReg + Const(16, width: dmaAddrWidth)),
                  for (var pc = 0; pc < refBeatCount; pc++)
                    If(
                      refCnt.eq(Const(pc, width: 4)),
                      then: [refBeat[pc] < input('dma_read_data')],
                    ),
                  If(
                    refCnt.eq(Const(refBeatCount - 1, width: 4)),
                    then: [
                      dmaReadReqReg < Const(0),
                      engState < Const(stInterPred, width: 5),
                    ],
                    orElse: [refCnt < (refCnt + Const(1, width: 4))],
                  ),
                ],
              ),
            ]),
            // Reconstruct: blk = clamp(inter prediction + residual).
            CaseItem(Const(stInterPred, width: 5), [
              for (var i = 0; i < 64; i++)
                blk[i] <
                    interReconOut.getRange(i * 8, i * 8 + 8).zeroExtend(16),
              beatCnt < Const(0, width: 3),
              dmaWriteReqReg < Const(1),
              dmaWriteAddrReg < dstAddrReg,
              engState < Const(stWrite, width: 5),
            ]),
            // Real gather: read the block's MV beat, latch frac_x/frac_y, and
            // set up the first patch-row read at (block origin + integer MV).
            CaseItem(Const(stMvRead, width: 5), [
              If(
                input('dma_read_valid'),
                then: [
                  fracXReg < input('dma_read_data').getRange(16, 20),
                  fracYReg < input('dma_read_data').getRange(20, 24),
                  rowBaseReg < pr0RowAddr,
                  sampleOffReg < patchBaseX.getRange(0, 3),
                  dmaReadAddrReg < pr0RowAddr,
                  prReg < Const(0, width: 4),
                  beatCnt < Const(0, width: 3),
                  engState < Const(stPatchGather, width: 5),
                ],
              ),
            ]),
            // Real gather: two aligned beats per patch row. The first is stored,
            // the second triggers the 9-sample extract into patchPx. After 9
            // rows the patch is complete and motion compensation runs.
            CaseItem(Const(stPatchGather, width: 5), [
              If(
                input('dma_read_valid'),
                then: [
                  If(
                    beatCnt.eq(Const(0, width: 3)),
                    then: [
                      patchBeat0 < input('dma_read_data'),
                      dmaReadAddrReg <
                          (dmaReadAddrReg + Const(16, width: dmaAddrWidth)),
                      beatCnt < Const(1, width: 3),
                    ],
                    orElse: [
                      if (patchPx.isNotEmpty)
                        for (var pr = 0; pr < 9; pr++)
                          If(
                            prReg.eq(Const(pr, width: 4)),
                            then: [
                              for (var c = 0; c < 9; c++)
                                patchPx[pr * 9 + c] < patchByte[c],
                            ],
                          ),
                      If(
                        prReg.eq(Const(8, width: 4)),
                        then: [
                          dmaReadReqReg < Const(0),
                          engState < Const(stInterPred, width: 5),
                        ],
                        orElse: [
                          prReg < (prReg + Const(1, width: 4)),
                          beatCnt < Const(0, width: 3),
                          rowBaseReg <
                              (rowBaseReg +
                                  refStrideBytes.zeroExtend(dmaAddrWidth)),
                          dmaReadAddrReg <
                              (rowBaseReg +
                                  refStrideBytes.zeroExtend(dmaAddrWidth)),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            // Tiled mode: pulse new_row (resets the line buffer left/corner for
            // the row), then begin the row's first block. Entropy mode continues
            // the bitstream (next_blk pulses here). Coefficient-load mode reads
            // the next source block.
            CaseItem(Const(stNewRow, width: 5), [
              If(
                decModeReg,
                then: [engState < Const(stEntWait, width: 5)],
                orElse: [
                  dmaReadReqReg < Const(1),
                  dmaReadAddrReg < srcAddrReg,
                  beatCnt < Const(0, width: 3),
                  engState < Const(stRead, width: 5),
                ],
              ),
            ]),
            // Tiled mode: the line buffer captured this block's edges (store
            // pulses while in this state). Advance to the next block in raster
            // order, stepping the source/destination by one block.
            CaseItem(Const(stStore, width: 5), [
              srcAddrReg < (srcAddrReg + blockBytes),
              // Inter mode steps the reference-patch base so each grid block
              // reads its own (block-sequential) patch blob. Gather mode steps
              // the motion-field pointer (one MV beat per block) instead.
              If(
                interEnReg,
                then: [
                  If(
                    realGatherReg,
                    then: [
                      mvAddrReg < (mvAddrReg + Const(16, width: dmaAddrWidth)),
                    ],
                    orElse: [
                      nbrAddrReg <
                          (nbrAddrReg +
                              Const(refBeatCount * 16, width: dmaAddrWidth)),
                    ],
                  ),
                ],
              ),
              // 2D mode keeps dst as the stable frame base (the 2D address is
              // computed per block from br/bc). Block-sequential mode steps it.
              If(~frame2DReg, then: [dstAddrReg < (dstAddrReg + blockBytes)]),
              If(
                bcReg.eq(blkColsM1),
                then: [
                  // Row complete.
                  If(
                    brReg.eq(blkRowsM1),
                    then: [engState < Const(stDone, width: 5)],
                    orElse: [
                      brReg < (brReg + Const(1, width: 8)),
                      bcReg < Const(0, width: tileColW),
                      engState < Const(stNewRow, width: 5),
                    ],
                  ),
                ],
                orElse: [
                  bcReg < (bcReg + Const(1, width: tileColW)),
                  // Entropy mode continues the bitstream (next_blk pulsed
                  // above). Coefficient-load mode reads the next source block.
                  If(
                    decModeReg,
                    then: [engState < Const(stEntWait, width: 5)],
                    orElse: [
                      dmaReadReqReg < Const(1),
                      dmaReadAddrReg < (srcAddrReg + blockBytes),
                      beatCnt < Const(0, width: 3),
                      engState < Const(stRead, width: 5),
                    ],
                  ),
                ],
              ),
            ]),
            // DMA the result block out.
            CaseItem(Const(stWrite, width: 5), [
              If(
                input('dma_write_ack'),
                then: [
                  If(
                    // 2D mode writes N rows (4 or 8). Block-sequential writes 2
                    // beats (4x4) or 8 (8x8).
                    mux(
                      size8,
                      beatCnt.eq(Const(7, width: 3)),
                      mux(
                        frame2DReg,
                        beatCnt.eq(Const(3, width: 3)),
                        beatCnt.eq(Const(1, width: 3)),
                      ),
                    ),
                    then: [
                      dmaWriteReqReg < Const(0),
                      // Tiled mode stores the block edges and loops, else done.
                      engState <
                          mux(
                            tiledReg,
                            Const(stStore, width: 5),
                            Const(stDone, width: 5),
                          ),
                    ],
                    orElse: [
                      beatCnt < (beatCnt + Const(1, width: 3)),
                      dmaWriteAddrReg <
                          (dmaWriteAddrReg + Const(16, width: dmaAddrWidth)),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(stDone, width: 5), [
              for (var i = 0; i < maxSessions; i++)
                If(
                  activeSess.eq(Const(i, width: sessW)),
                  then: [
                    sessStatus[i] < Const(2, width: 32), // done
                    sessFramesDone[i] <
                        (sessFramesDone[i] + Const(1, width: 32)),
                    sessBytesDone[i] <
                        (sessBytesDone[i] +
                            mux(
                              size8,
                              Const(128, width: 32),
                              Const(32, width: 32),
                            )),
                    intStatus < (intStatus | Const(1 << i, width: maxSessions)),
                  ],
                ),
              engState < Const(stIdle, width: 5),
            ]),
            // Decode mode: load two stream beats. Beat 0 inits the decoder
            // window (via entLoad). Both beats prime the byte-feed buffer.
            CaseItem(Const(stBitLoad, width: 5), [
              If(
                input('dma_read_valid'),
                then: [
                  dmaReadAddrReg <
                      (dmaReadAddrReg + Const(16, width: dmaAddrWidth)),
                  If(
                    beatCnt.eq(Const(0, width: 3)),
                    then: [
                      beatA < input('dma_read_data'),
                      beatCnt < Const(1, width: 3),
                    ],
                    orElse: [
                      beatB < input('dma_read_data'),
                      dmaReadReqReg < Const(0),
                      entRow < Const(0, width: 3),
                      entCol < Const(0, width: 3),
                      // Simplified coder seeded the 64-bit window from beat0 bytes
                      // 0..7. od_ec consumes from byte 0.
                      rfByte < Const(useOdEc ? 0 : 8, width: 5),
                      engState < Const(stEntWait, width: 5),
                    ],
                  ),
                ],
              ),
            ]),
            // Run the coefficient decoder: feed it bytes and advance the cursor
            // by what it consumed, refill a beat when the cursor crosses, and on
            // done move on to reading the coefficients out.
            CaseItem(Const(stEntWait, width: 5), [
              If(
                coeffDec.done,
                then: [
                  entRow < Const(0, width: 3),
                  entCol < Const(0, width: 3),
                  engState < Const(stEntRead, width: 5),
                ],
                orElse: [
                  If(
                    (rfByte + coeffBytePop.zeroExtend(5)).gte(
                      Const(16, width: 5),
                    ),
                    then: [
                      rfByte <
                          ((rfByte + coeffBytePop.zeroExtend(5)) -
                              Const(16, width: 5)),
                      dmaReadReqReg < Const(1),
                      engState < Const(stEntRefill, width: 5),
                    ],
                    orElse: [rfByte < (rfByte + coeffBytePop.zeroExtend(5))],
                  ),
                ],
              ),
            ]),
            // Slide the next beat in (the decoder is stalled this cycle).
            CaseItem(Const(stEntRefill, width: 5), [
              If(
                input('dma_read_valid'),
                then: [
                  beatA < beatB,
                  beatB < input('dma_read_data'),
                  dmaReadReqReg < Const(0),
                  dmaReadAddrReg <
                      (dmaReadAddrReg + Const(16, width: dmaAddrWidth)),
                  engState < Const(stEntWait, width: 5),
                ],
              ),
            ]),
            // Read each decoded coefficient into the block (raster scan),
            // dequantizing it when dequant is enabled (DC at position 0).
            CaseItem(Const(stEntRead, width: 5), [
              // Place the coefficient at its block position: the raster index in
              // raster mode, or the AV1 diagonal-scan index when enabled. The DC
              // is always scan position 0 (posLin == 0).
              for (var t = 0; t < 64; t++)
                If(
                  mux(scanOrderReg, scanIdx, entIdx).eq(Const(t, width: 6)),
                  then: [
                    blk[t] <
                        deqLoadR(
                          coeffDec.output('coeff_out'),
                          posLin.eq(Const(0, width: 7)),
                        ),
                  ],
                ),
              If(
                entLast,
                then: [
                  passIdx < Const(0, width: 3),
                  engState < Const(stRows, width: 5),
                ],
                orElse: [
                  If(
                    entCol.eq(
                      mux(size8, Const(7, width: 3), Const(3, width: 3)),
                    ),
                    then: [
                      entCol < Const(0, width: 3),
                      entRow < (entRow + Const(1, width: 3)),
                    ],
                    orElse: [entCol < (entCol + Const(1, width: 3))],
                  ),
                ],
              ),
            ]),
          ]),
        ],
      ),
    ]);
  }

  /// Whether this engine supports a specific codec format.
  bool supportsCodec(HarborCodecFormat format) =>
      codecs.any((c) => c.format == format);

  /// Whether this engine can decode a specific format.
  bool canDecode(HarborCodecFormat format) =>
      codecs.any((c) => c.format == format && c.canDecode);

  /// Whether this engine can encode a specific format.
  bool canEncode(HarborCodecFormat format) =>
      codecs.any((c) => c.format == format && c.canEncode);

  /// All formats that can be decoded.
  List<HarborCodecFormat> get decodableFormats =>
      codecs.where((c) => c.canDecode).map((c) => c.format).toList();

  /// All formats that can be encoded.
  List<HarborCodecFormat> get encodableFormats =>
      codecs.where((c) => c.canEncode).map((c) => c.format).toList();

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,media-engine'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      'max-sessions': maxSessions,
      'harbor,codecs': codecs.map((c) => c.format.displayName).join(', '),
      'harbor,max-width': codecs.fold<int>(
        0,
        (max, c) => c.maxWidth > max ? c.maxWidth : max,
      ),
      'harbor,max-height': codecs.fold<int>(
        0,
        (max, c) => c.maxHeight > max ? c.maxHeight : max,
      ),
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,media-engine'],
      'max-sessions': maxSessions,
      'harbor,codecs': codecs.map((c) => c.format.displayName).join(', '),
      'harbor,max-width': codecs.fold<int>(
        0,
        (max, c) => c.maxWidth > max ? c.maxWidth : max,
      ),
      'harbor,max-height': codecs.fold<int>(
        0,
        (max, c) => c.maxHeight > max ? c.maxHeight : max,
      ),
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'MEDIA',
    groupName: 'MEDIA',
    description: 'Media engine codec accelerator',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
