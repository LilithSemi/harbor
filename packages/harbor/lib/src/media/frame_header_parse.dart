import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'bit_reader.dart';
import 'gm_params.dart';

/// Harbor AV1 `uncompressed_header` parser for the KEYFRAME (intra) path,
/// Increment A: the front matter through `quantization_params`.
///
/// A sequential port of the `uncompressed_header` parse scoped to the common
/// intra-keyframe case.
/// Like [HarborSeqHeaderParse] it owns one [HarborBitReader] on a `pos` bit
/// cursor. Each state reads one `f(n)`/`su(n)` field, latches it, advances, and
/// branches on just-read bits. The sequence-header fields the frame header
/// depends on arrive as inputs (in the integrated decoder they come from
/// [HarborSeqHeaderParse]).
///
/// SCOPE (this increment): not-reduced + reduced still picture, KEY_FRAME /
/// INTRA_ONLY (intra), through prefix flags, frame_size (superres OFF),
/// render_size, allow_intrabc, disable_frame_end_update_cdf, single-superblock
/// tile_info, and quantization_params. The decoder needs exactly these (frame
/// type, dimensions, base qindex, dc/ac deltas, qmatrix) before the segmentation
/// / loop-filter / cdef / lr / tx-mode / film-grain TAIL (a follow-up
/// increment). The `unsupported` output asserts (matching where SW throws or
/// where this increment stops short) for: show_existing_frame, INTER/SWITCH
/// frames, decoder_model buffer removal, a multi-superblock frame (tile
/// splitting), non-uniform tiles, an error-resilient ref_order_hint loop, and
/// superres downscaling. `bits_consumed` is the cursor after
/// quantization_params.
class HarborFrameHeaderParse extends BridgeModule {
  /// Maximum coded bytes the input window holds.
  final int maxBytes;

  HarborFrameHeaderParse({this.maxBytes = 32, String? name})
    : assert(maxBytes > 0, 'maxBytes must be positive'),
      super('HarborFrameHeaderParse', name: name ?? 'frame_header_parse') {
    final totalBits = maxBytes * 8;
    final offW = totalBits.bitLength;

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: totalBits);

    // sequence-header dependencies (inputs)
    createPort('seq_reduced_still_picture', PortDirection.input);
    createPort('seq_frame_id_numbers_present', PortDirection.input);
    createPort(
      'seq_delta_frame_id_length_minus2',
      PortDirection.input,
      width: 4,
    );
    createPort(
      'seq_additional_frame_id_length_minus1',
      PortDirection.input,
      width: 3,
    );
    createPort('seq_force_screen_content_tools', PortDirection.input, width: 2);
    createPort('seq_force_integer_mv', PortDirection.input, width: 2);
    createPort('seq_order_hint_bits', PortDirection.input, width: 4);
    createPort('seq_enable_order_hint', PortDirection.input);
    createPort('seq_decoder_model_info_present', PortDirection.input);
    createPort('seq_frame_width_bits_minus1', PortDirection.input, width: 4);
    createPort('seq_frame_height_bits_minus1', PortDirection.input, width: 4);
    createPort('seq_max_frame_width_minus1', PortDirection.input, width: 32);
    createPort('seq_max_frame_height_minus1', PortDirection.input, width: 32);
    createPort('seq_enable_superres', PortDirection.input);
    createPort('seq_use_128x128_superblock', PortDirection.input);
    createPort('seq_num_planes', PortDirection.input, width: 2);
    createPort('seq_separate_uv_delta_q', PortDirection.input);
    createPort('seq_enable_cdef', PortDirection.input);
    createPort('seq_enable_restoration', PortDirection.input);
    createPort('seq_subsampling_x', PortDirection.input);
    createPort('seq_subsampling_y', PortDirection.input);
    createPort('seq_film_grain_params_present', PortDirection.input);
    // INTER-frame dependencies (default 0 for the keyframe-only path).
    createPort('seq_enable_ref_frame_mvs', PortDirection.input);
    createPort('seq_enable_warped_motion', PortDirection.input);
    // show_existing_frame: metadata of the DPB slot being re-displayed. The
    // caller muxes the reference-frame store by `frame_to_show_map_idx` (an
    // output of this parser) and feeds back the shown slot's saved frame_type
    // and order_hint. They drive the forced-refresh rule (a shown KEY_FRAME
    // refreshes all 8 slots) and the re-exported order_hint / frame_type,
    // exactly as the SW `parseFrameHeader` reads `rs.refFrameMap[idx]`.
    createPort('shown_frame_type', PortDirection.input, width: 2);
    createPort('shown_order_hint', PortDirection.input, width: 8);

    addOutput('done');
    addOutput('unsupported');
    addOutput('bits_consumed', width: offW);
    addOutput('frame_type', width: 2);
    addOutput('frame_is_intra');
    addOutput('show_frame');
    addOutput('showable_frame');
    addOutput('error_resilient_mode');
    addOutput('disable_cdf_update');
    addOutput('allow_screen_content_tools');
    addOutput('force_integer_mv', width: 2);
    addOutput('allow_intrabc');
    addOutput('order_hint', width: 8);
    addOutput('refresh_frame_flags', width: 8);
    // show_existing_frame path: re-display a stored reference (no decode).
    addOutput('show_existing_frame');
    addOutput('frame_to_show_map_idx', width: 3);
    addOutput('frame_width', width: 32);
    addOutput('frame_height', width: 32);
    addOutput('upscaled_width', width: 32);
    addOutput('render_width', width: 32);
    addOutput('render_height', width: 32);
    addOutput('superres_denom', width: 5);
    addOutput('disable_frame_end_update_cdf');
    addOutput('tile_cols', width: 8);
    addOutput('tile_rows', width: 8);
    addOutput('tile_cols_log2', width: 4);
    addOutput('tile_rows_log2', width: 4);
    addOutput('context_update_tile_id', width: 12);
    addOutput('tile_size_bytes', width: 3);
    addOutput('base_q_idx', width: 8);
    addOutput('delta_q_y_dc', width: 8);
    addOutput('delta_q_u_dc', width: 8);
    addOutput('delta_q_u_ac', width: 8);
    addOutput('delta_q_v_dc', width: 8);
    addOutput('delta_q_v_ac', width: 8);
    addOutput('using_qmatrix');
    addOutput('qm_y', width: 4);
    addOutput('qm_u', width: 4);
    addOutput('qm_v', width: 4);
    // Increment B: header tail through loop_filter_params.
    addOutput('segmentation_enabled');
    addOutput('delta_q_present');
    addOutput('delta_q_res', width: 2);
    addOutput('delta_lf_present');
    addOutput('delta_lf_res', width: 2);
    addOutput('delta_lf_multi');
    addOutput('coded_lossless');
    addOutput('loop_filter_level_0', width: 6);
    addOutput('loop_filter_level_1', width: 6);
    addOutput('loop_filter_level_2', width: 6);
    addOutput('loop_filter_level_3', width: 6);
    addOutput('loop_filter_sharpness', width: 3);
    addOutput('loop_filter_delta_enabled');
    addOutput('loop_filter_ref_deltas', width: 8 * 8); // 8 signed bytes
    addOutput('loop_filter_mode_deltas', width: 2 * 8); // 2 signed bytes
    // Increment C: cdef / lr / tx_mode / reduced_tx_set / film_grain.
    addOutput('cdef_damping_minus3', width: 2);
    addOutput('cdef_bits', width: 2);
    addOutput('cdef_y_pri_strength', width: 8 * 4);
    addOutput('cdef_y_sec_strength', width: 8 * 4);
    addOutput('cdef_uv_pri_strength', width: 8 * 4);
    addOutput('cdef_uv_sec_strength', width: 8 * 4);
    addOutput('frame_restoration_type', width: 3 * 2);
    addOutput('uses_lr');
    addOutput('lr_size_0', width: 9);
    addOutput('lr_size_1', width: 9);
    addOutput('lr_size_2', width: 9);
    addOutput('tx_mode', width: 2);
    addOutput('reduced_tx_set');
    addOutput('apply_grain');
    // INTER frame header outputs (0 / defaults on the intra path)
    addOutput('primary_ref_frame', width: 3);
    addOutput('ref_frame_idx', width: 7 * 3); // 7 refs, 3 bits each, [i*3+:3]
    addOutput('allow_high_precision_mv');
    addOutput('is_filter_switchable');
    addOutput('interpolation_filter', width: 3); // 0..3 or SWITCHABLE(4)
    addOutput('is_motion_mode_switchable');
    addOutput('use_ref_frame_mvs');
    addOutput(
      'reference_select',
    ); // frame_reference_mode: 1 == REFERENCE_MODE_SELECT
    addOutput('skip_mode_present');
    addOutput('allow_warped_motion');
    // global_motion_params: primary-ref saved models (LAST..ALTREF), resolved by
    // the caller from the DPB (identity default when primary_ref_frame == NONE).
    createPort('gm_ref_params', PortDirection.input, width: 7 * 6 * 32);
    // decoded per-reference global-motion type + 6-entry matrix (ref 0 == LAST).
    for (var r = 0; r < 7; r++) {
      addOutput('gm_type_$r', width: 2);
      for (var j = 0; j < 6; j++) {
        addOutput('gm_mat_${r}_$j', width: 32);
      }
    }

    final clk = input('clk');
    final reset = input('reset');
    final start = input('start');

    // sequence-header inputs
    final seqReduced = input('seq_reduced_still_picture');
    final seqFrameId = input('seq_frame_id_numbers_present');
    final seqDeltaIdM2 = input('seq_delta_frame_id_length_minus2');
    final seqAddIdM1 = input('seq_additional_frame_id_length_minus1');
    final seqForceScreen = input('seq_force_screen_content_tools');
    final seqForceIntMv = input('seq_force_integer_mv');
    final seqOrderHintBits = input('seq_order_hint_bits');
    final seqEnableOrderHint = input('seq_enable_order_hint');
    final seqDecModel = input('seq_decoder_model_info_present');
    final seqWBitsM1 = input('seq_frame_width_bits_minus1');
    final seqHBitsM1 = input('seq_frame_height_bits_minus1');
    final seqMaxWM1 = input('seq_max_frame_width_minus1');
    final seqMaxHM1 = input('seq_max_frame_height_minus1');
    final seqEnableSuperres = input('seq_enable_superres');
    final seqUse128 = input('seq_use_128x128_superblock');
    final seqNumPlanes = input('seq_num_planes');
    final seqSepUv = input('seq_separate_uv_delta_q');
    final seqEnableCdef = input('seq_enable_cdef');
    final seqEnableRestoration = input('seq_enable_restoration');
    final seqSubX = input('seq_subsampling_x');
    final seqSubY = input('seq_subsampling_y');
    final seqFilmGrain = input('seq_film_grain_params_present');
    final seqEnableRefFrameMvs = input('seq_enable_ref_frame_mvs');
    final seqEnableWarpedMotion = input('seq_enable_warped_motion');
    final shownFrameType = input('shown_frame_type');
    final shownOrderHint = input('shown_order_hint');

    final reader = HarborBitReader(maxBytes: maxBytes, name: 'fn');
    addSubModule(reader);

    // global_motion_params decoder (nested subexp FSM). Runs on the same byte
    // window starting at the header cursor. The parent FSM waits for `done` then
    // resumes at its `bits_consumed`.
    final gmp = HarborGmParams(maxBytes: maxBytes, name: 'gmp');
    addSubModule(gmp);

    // states
    const sIdle = 0;
    const sShowExisting = 1;
    const sFrameType = 2;
    const sShowFrame = 3;
    const sShowable = 4;
    const sErrCheck = 5;
    const sErrRead = 6;
    const sDisableCdf = 7;
    const sScreenCheck = 8;
    const sScreenRead = 9;
    const sForceMvCheck = 10;
    const sForceMvRead = 11;
    const sIntraForce = 12;
    const sFrameIdCheck = 13;
    const sCurrentFrameId = 14;
    const sFrameSizeOverride = 15;
    const sOrderHint = 16;
    const sDecModelCheck = 17;
    const sRefreshCheck = 18;
    const sRefreshRead = 19;
    const sRefOrderHintCheck = 20;
    const sFrameSizeStart = 21;
    const sFSWidth = 22;
    const sFSHeight = 23;
    const sSuperresCheck = 24;
    const sSuperresUse = 25;
    const sRenderCheck = 26;
    const sRenderW = 27;
    const sRenderH = 28;
    const sAfterRender = 29;
    const sIntrabc = 30;
    const sDisableFrameEnd = 31;
    const sDisableFrameEndRead = 32;
    const sTileInfo = 33;
    const sQuant = 34;
    const sDQYdc = 35;
    const sDQYdcVal = 36;
    const sQUVcheck = 37;
    const sDiffUV = 38;
    const sDiffUVRead = 39;
    const sDQUdc = 40;
    const sDQUdcVal = 41;
    const sDQUac = 42;
    const sDQUacVal = 43;
    const sVDeltaCheck = 44;
    const sDQVdc = 45;
    const sDQVdcVal = 46;
    const sDQVac = 47;
    const sDQVacVal = 48;
    const sUsingQM = 49;
    const sQMy = 50;
    const sQMu = 51;
    const sQMv = 52;
    // Increment B: header tail through loop_filter_params
    const sSegmentation = 53;
    const sDeltaQStart = 54;
    const sDeltaQRead = 55;
    const sDeltaQRes = 56;
    const sDeltaLfStart = 57;
    const sDeltaLfRead = 58;
    const sDeltaLfRes = 59;
    const sDeltaLfMulti = 60;
    const sLoopFilterStart = 61;
    const sLfLevel0 = 62;
    const sLfLevel1 = 63;
    const sLfChroma = 64;
    const sLfLevel2 = 65;
    const sLfLevel3 = 66;
    const sLfSharp = 67;
    const sLfDeltaEnabled = 68;
    const sLfUpdate = 69;
    const sLfRefBit = 70;
    const sLfRefVal = 71;
    const sLfModeBit = 72;
    const sLfModeVal = 73;
    // Increment C: cdef / lr / tx_mode / reduced_tx_set / film_grain
    const sCdefStart = 74;
    const sCdefDamping = 75;
    const sCdefBits = 76;
    const sCdefYpri = 77;
    const sCdefYsec = 78;
    const sCdefUvCheck = 79;
    const sCdefUvpri = 80;
    const sCdefUvsec = 81;
    const sCdefNext = 82;
    const sLrStart = 83;
    const sLrType = 84;
    const sLrNext = 85;
    const sLrUnit = 86;
    const sLrUnitA = 87;
    const sLrUnitB = 88;
    const sLrUvCheck = 89;
    const sLrUvRead = 90;
    const sLrFinish = 91;
    const sTxMode = 92;
    const sTxModeRead = 93;
    const sReducedTxSet = 94;
    const sFilmGrainCheck = 95;
    const sFilmGrainApply = 96;
    const sDone = 97;
    const sUnsupported = 98;
    // multi-tile tile_info (uniform spacing)
    const sTileColsLoop = 99;
    const sTileColsInc = 100;
    const sTileRowsInit = 101;
    const sTileRowsLoop = 102;
    const sTileRowsInc = 103;
    const sTileContextCheck = 104;
    const sTileContextId = 105;
    const sTileSizeBytes = 106;
    // INTER frame header states
    const sPrimaryRef = 107;
    const sInterRefStart = 108;
    const sShortSignaling = 109;
    const sRefIdxLoop = 110;
    const sRefIdxRead = 111;
    const sInterFrameSize = 112;
    const sHighPrecCheck = 113;
    const sHighPrecRead = 114;
    const sInterpSwitch = 115;
    const sInterpRead = 116;
    const sMotionModeSw = 117;
    const sUseRefMvsCheck = 118;
    const sUseRefMvsRead = 119;
    const sRefModeRead = 120;
    const sSkipModeParams = 121;
    const sAllowWarpedCheck = 122;
    const sAllowWarpedRead = 123;
    const sGmStart = 129;
    const sGmWait = 130;
    // show_existing_frame states
    const sSEIdx = 126;
    const sSEDisplayId = 127;
    const sSEFinish = 128;
    const stW = 8;

    Logic sc(int v) => Const(v, width: stW);

    // registers
    final st = Logic(name: 'st', width: stW);
    final pos = Logic(name: 'pos', width: offW);

    final rFrameType = Logic(name: 'r_frame_type', width: 2);
    final rIntra = Logic(name: 'r_intra');
    final rShowFrame = Logic(name: 'r_show_frame');
    final rShowable = Logic(name: 'r_showable');
    final rErr = Logic(name: 'r_err');
    final rDisableCdf = Logic(name: 'r_disable_cdf');
    final rAllowScreen = Logic(name: 'r_allow_screen');
    final rForceMv = Logic(name: 'r_force_mv', width: 2);
    final rSizeOverride = Logic(name: 'r_size_override');
    final rOrderHint = Logic(name: 'r_order_hint', width: 8);
    final rRefresh = Logic(name: 'r_refresh', width: 8);
    final rAllowIntrabc = Logic(name: 'r_allow_intrabc');
    final rFrameWidth = Logic(name: 'r_frame_width', width: 32);
    final rFrameHeight = Logic(name: 'r_frame_height', width: 32);
    final rUpscaledWidth = Logic(name: 'r_upscaled_width', width: 32);
    final rRenderWidth = Logic(name: 'r_render_width', width: 32);
    final rRenderHeight = Logic(name: 'r_render_height', width: 32);
    final rSuperresDenom = Logic(name: 'r_superres_denom', width: 5);
    final rDisableFrameEnd = Logic(name: 'r_disable_frame_end');
    final rTileCols = Logic(name: 'r_tile_cols', width: 8);
    final rTileRows = Logic(name: 'r_tile_rows', width: 8);
    final rTileColsLog2 = Logic(name: 'r_tile_cols_log2', width: 4);
    final rTileRowsLog2 = Logic(name: 'r_tile_rows_log2', width: 4);
    final rContextUpdate = Logic(name: 'r_context_update', width: 12);
    final rTileSizeBytes = Logic(name: 'r_tile_size_bytes', width: 3);
    final rBaseQ = Logic(name: 'r_base_q', width: 8);
    final rDQYdc = Logic(name: 'r_dq_y_dc', width: 8);
    final rDQUdc = Logic(name: 'r_dq_u_dc', width: 8);
    final rDQUac = Logic(name: 'r_dq_u_ac', width: 8);
    final rDQVdc = Logic(name: 'r_dq_v_dc', width: 8);
    final rDQVac = Logic(name: 'r_dq_v_ac', width: 8);
    final rDiffUv = Logic(name: 'r_diff_uv');
    final rUsingQm = Logic(name: 'r_using_qm');
    final rQmY = Logic(name: 'r_qm_y', width: 4);
    final rQmU = Logic(name: 'r_qm_u', width: 4);
    final rQmV = Logic(name: 'r_qm_v', width: 4);
    // Increment B tail registers
    final rSegEnabled = Logic(name: 'r_seg_enabled');
    final rDeltaQPresent = Logic(name: 'r_delta_q_present');
    final rDeltaQRes = Logic(name: 'r_delta_q_res', width: 2);
    final rDeltaLfPresent = Logic(name: 'r_delta_lf_present');
    final rDeltaLfRes = Logic(name: 'r_delta_lf_res', width: 2);
    final rDeltaLfMulti = Logic(name: 'r_delta_lf_multi');
    final rLfLevel0 = Logic(name: 'r_lf_level0', width: 6);
    final rLfLevel1 = Logic(name: 'r_lf_level1', width: 6);
    final rLfLevel2 = Logic(name: 'r_lf_level2', width: 6);
    final rLfLevel3 = Logic(name: 'r_lf_level3', width: 6);
    final rLfSharp = Logic(name: 'r_lf_sharp', width: 3);
    final rLfDeltaEnabled = Logic(name: 'r_lf_delta_enabled');
    final lfRefD = [
      for (var i = 0; i < 8; i++) Logic(name: 'r_lf_refd$i', width: 8),
    ];
    final lfModeD = [
      for (var i = 0; i < 2; i++) Logic(name: 'r_lf_moded$i', width: 8),
    ];
    final li = Logic(name: 'lf_loop_i', width: 4);
    // Increment C registers
    final rCdefDamping = Logic(name: 'r_cdef_damping', width: 2);
    final rCdefBits = Logic(name: 'r_cdef_bits', width: 2);
    final cdefYpri = [
      for (var i = 0; i < 8; i++) Logic(name: 'r_cdef_ypri$i', width: 4),
    ];
    final cdefYsec = [
      for (var i = 0; i < 8; i++) Logic(name: 'r_cdef_ysec$i', width: 4),
    ];
    final cdefUvpri = [
      for (var i = 0; i < 8; i++) Logic(name: 'r_cdef_uvpri$i', width: 4),
    ];
    final cdefUvsec = [
      for (var i = 0; i < 8; i++) Logic(name: 'r_cdef_uvsec$i', width: 4),
    ];
    final frameRestType = [
      for (var i = 0; i < 3; i++) Logic(name: 'r_lr_type$i', width: 2),
    ];
    final rUsesLr = Logic(name: 'r_uses_lr');
    final rUsesChromaLr = Logic(name: 'r_uses_chroma_lr');
    final rLrUnitShift = Logic(name: 'r_lr_unit_shift', width: 2);
    final rLrUvShift = Logic(name: 'r_lr_uv_shift');
    final rLrSize0 = Logic(name: 'r_lr_size0', width: 9);
    final rTxMode = Logic(name: 'r_tx_mode', width: 2);
    final rReducedTxSet = Logic(name: 'r_reduced_tx_set');
    final rApplyGrain = Logic(name: 'r_apply_grain');
    // INTER registers
    final rPrimaryRef = Logic(name: 'r_primary_ref', width: 3);
    final rShortSignaling = Logic(name: 'r_short_signaling');
    // ref_frame_idx shift register: reads i=0..6, shift-in => refFrameIdx[6-i]
    // lands at bits [i*3 +: 3], refFrameIdx[0] at MSB (bits 18..20).
    final rRefIdx = Logic(name: 'r_ref_idx', width: 7 * 3);
    final ri = Logic(name: 'r_ref_i', width: 3);
    final gi = Logic(name: 'r_gm_i', width: 3);
    final rHighPrecMv = Logic(name: 'r_high_prec_mv');
    final rIsFilterSw = Logic(name: 'r_is_filter_sw');
    final rInterpFilter = Logic(name: 'r_interp_filter', width: 3);
    final rMotionModeSw = Logic(name: 'r_motion_mode_sw');
    final rUseRefMvs = Logic(name: 'r_use_ref_mvs');
    final rRefSelect = Logic(name: 'r_ref_select');
    final rSkipModePresent = Logic(name: 'r_skip_mode_present');
    final rAllowWarped = Logic(name: 'r_allow_warped');
    // show_existing_frame registers.
    final rShowExisting = Logic(name: 'r_show_existing');
    final rFrameToShow = Logic(name: 'r_frame_to_show', width: 3);

    // current_frame_id length = add_id_m1 + delta_id_m2 + 3.
    final idLen =
        (seqAddIdM1.zeroExtend(6) +
                seqDeltaIdM2.zeroExtend(6) +
                Const(3, width: 6))
            .getRange(0, 6);
    final wPlus1 = (seqWBitsM1.zeroExtend(6) + Const(1, width: 6)).getRange(
      0,
      6,
    );
    final hPlus1 = (seqHBitsM1.zeroExtend(6) + Const(1, width: 6)).getRange(
      0,
      6,
    );

    // combinational field width per state
    final nSel = Logic(name: 'n_sel', width: 6);
    Logic n(int k) => Const(k, width: 6);
    Combinational([
      nSel < Const(0, width: 6),
      Case(st, [
        CaseItem(sc(sShowExisting), [nSel < n(1)]),
        CaseItem(sc(sSEIdx), [nSel < n(3)]),
        CaseItem(sc(sSEDisplayId), [nSel < idLen]),
        CaseItem(sc(sFrameType), [nSel < n(2)]),
        CaseItem(sc(sShowFrame), [nSel < n(1)]),
        CaseItem(sc(sShowable), [nSel < n(1)]),
        CaseItem(sc(sErrRead), [nSel < n(1)]),
        CaseItem(sc(sDisableCdf), [nSel < n(1)]),
        CaseItem(sc(sScreenRead), [nSel < n(1)]),
        CaseItem(sc(sForceMvRead), [nSel < n(1)]),
        CaseItem(sc(sCurrentFrameId), [nSel < idLen]),
        CaseItem(sc(sFrameSizeOverride), [nSel < n(1)]),
        CaseItem(sc(sOrderHint), [nSel < seqOrderHintBits.zeroExtend(6)]),
        CaseItem(sc(sRefreshRead), [nSel < n(8)]),
        CaseItem(sc(sFSWidth), [nSel < wPlus1]),
        CaseItem(sc(sFSHeight), [nSel < hPlus1]),
        CaseItem(sc(sSuperresUse), [nSel < n(1)]),
        CaseItem(sc(sRenderCheck), [nSel < n(1)]),
        CaseItem(sc(sRenderW), [nSel < n(16)]),
        CaseItem(sc(sRenderH), [nSel < n(16)]),
        CaseItem(sc(sIntrabc), [nSel < n(1)]),
        CaseItem(sc(sDisableFrameEndRead), [nSel < n(1)]),
        CaseItem(sc(sTileInfo), [nSel < n(1)]),
        CaseItem(sc(sQuant), [nSel < n(8)]),
        CaseItem(sc(sDQYdc), [nSel < n(1)]),
        CaseItem(sc(sDQYdcVal), [nSel < n(7)]),
        CaseItem(sc(sDiffUVRead), [nSel < n(1)]),
        CaseItem(sc(sDQUdc), [nSel < n(1)]),
        CaseItem(sc(sDQUdcVal), [nSel < n(7)]),
        CaseItem(sc(sDQUac), [nSel < n(1)]),
        CaseItem(sc(sDQUacVal), [nSel < n(7)]),
        CaseItem(sc(sDQVdc), [nSel < n(1)]),
        CaseItem(sc(sDQVdcVal), [nSel < n(7)]),
        CaseItem(sc(sDQVac), [nSel < n(1)]),
        CaseItem(sc(sDQVacVal), [nSel < n(7)]),
        CaseItem(sc(sUsingQM), [nSel < n(1)]),
        CaseItem(sc(sQMy), [nSel < n(4)]),
        CaseItem(sc(sQMu), [nSel < n(4)]),
        CaseItem(sc(sQMv), [nSel < n(4)]),
        // tail
        CaseItem(sc(sSegmentation), [nSel < n(1)]),
        CaseItem(sc(sDeltaQRead), [nSel < n(1)]),
        CaseItem(sc(sDeltaQRes), [nSel < n(2)]),
        CaseItem(sc(sDeltaLfRead), [nSel < n(1)]),
        CaseItem(sc(sDeltaLfRes), [nSel < n(2)]),
        CaseItem(sc(sDeltaLfMulti), [nSel < n(1)]),
        CaseItem(sc(sLfLevel0), [nSel < n(6)]),
        CaseItem(sc(sLfLevel1), [nSel < n(6)]),
        CaseItem(sc(sLfLevel2), [nSel < n(6)]),
        CaseItem(sc(sLfLevel3), [nSel < n(6)]),
        CaseItem(sc(sLfSharp), [nSel < n(3)]),
        CaseItem(sc(sLfDeltaEnabled), [nSel < n(1)]),
        CaseItem(sc(sLfUpdate), [nSel < n(1)]),
        CaseItem(sc(sLfRefBit), [nSel < n(1)]),
        CaseItem(sc(sLfRefVal), [nSel < n(7)]),
        CaseItem(sc(sLfModeBit), [nSel < n(1)]),
        CaseItem(sc(sLfModeVal), [nSel < n(7)]),
        // Increment C
        CaseItem(sc(sCdefDamping), [nSel < n(2)]),
        CaseItem(sc(sCdefBits), [nSel < n(2)]),
        CaseItem(sc(sCdefYpri), [nSel < n(4)]),
        CaseItem(sc(sCdefYsec), [nSel < n(2)]),
        CaseItem(sc(sCdefUvpri), [nSel < n(4)]),
        CaseItem(sc(sCdefUvsec), [nSel < n(2)]),
        CaseItem(sc(sLrType), [nSel < n(2)]),
        CaseItem(sc(sLrUnitA), [nSel < n(1)]),
        CaseItem(sc(sLrUnitB), [nSel < n(1)]),
        CaseItem(sc(sLrUvRead), [nSel < n(1)]),
        CaseItem(sc(sTxModeRead), [nSel < n(1)]),
        CaseItem(sc(sReducedTxSet), [nSel < n(1)]),
        CaseItem(sc(sFilmGrainApply), [nSel < n(1)]),
        // tile_info
        CaseItem(sc(sTileColsInc), [nSel < n(1)]),
        CaseItem(sc(sTileRowsInc), [nSel < n(1)]),
        CaseItem(sc(sTileContextId), [
          nSel <
              (rTileColsLog2.zeroExtend(6) + rTileRowsLog2.zeroExtend(6))
                  .getRange(0, 6),
        ]),
        CaseItem(sc(sTileSizeBytes), [nSel < n(2)]),
        // inter header read states
        CaseItem(sc(sPrimaryRef), [nSel < n(3)]),
        CaseItem(sc(sShortSignaling), [nSel < n(1)]),
        CaseItem(sc(sRefIdxRead), [nSel < n(3)]),
        CaseItem(sc(sHighPrecRead), [nSel < n(1)]),
        CaseItem(sc(sInterpSwitch), [nSel < n(1)]),
        CaseItem(sc(sInterpRead), [nSel < n(2)]),
        CaseItem(sc(sMotionModeSw), [nSel < n(1)]),
        CaseItem(sc(sUseRefMvsRead), [nSel < n(1)]),
        CaseItem(sc(sRefModeRead), [nSel < n(1)]),
        CaseItem(sc(sAllowWarpedRead), [nSel < n(1)]),
      ]),
    ]);

    reader.input('bytes').srcConnection! <= input('bytes');
    reader.input('bit_offset').srcConnection! <= pos;
    reader.input('n').srcConnection! <= nSel;

    // global_motion_params decoder wiring. `start` pulses for the one cycle the
    // parent is in sGmStart. The decoder latches base_offset = pos and runs.
    gmp.input('clk').srcConnection! <= clk;
    gmp.input('reset').srcConnection! <= reset;
    gmp.input('start').srcConnection! <= st.eq(sc(sGmStart));
    gmp.input('bytes').srcConnection! <= input('bytes');
    gmp.input('base_offset').srcConnection! <= pos;
    gmp.input('allow_high_precision_mv').srcConnection! <= rHighPrecMv;
    gmp.input('ref_params').srcConnection! <= input('gm_ref_params');
    for (var r = 0; r < 7; r++) {
      output('gm_type_$r') <= gmp.output('gm_type_$r');
      for (var j = 0; j < 6; j++) {
        output('gm_mat_${r}_$j') <= gmp.output('mat_${r}_$j');
      }
    }

    final rv = reader.output('value');
    final bit0 = rv.getRange(0, 1);
    final nextPos = reader.output('next_offset');
    // su(7): sign-extend the 7-bit field to 8 bits two's complement.
    final su7 = [rv.getRange(6, 7), rv.getRange(0, 7)].concat();
    // lr_type remap[lr_type] = [NONE, SWITCHABLE=3, WIENER=1, SGRPROJ=2].
    final lrType2 = rv.getRange(0, 2);
    final lrRemapped = mux(
      lrType2.eq(Const(0, width: 2)),
      Const(0, width: 2),
      mux(
        lrType2.eq(Const(1, width: 2)),
        Const(3, width: 2),
        mux<Logic>(
          lrType2.eq(Const(2, width: 2)),
          Const(1, width: 2),
          Const(2, width: 2),
        ),
      ),
    );
    final lrNonNone = ~lrRemapped.eq(Const(0, width: 2));

    const keyFrame = 0;
    const interFrame = 1;
    const switchFrame = 3;
    const primaryRefSelect =
        2; // SELECT_SCREEN_CONTENT_TOOLS / SELECT_INTEGER_MV

    // mi cols/rows from the (already-latched) frame size.
    Logic miFrom(Logic dim) =>
        (((dim + Const(7, width: 32)).getRange(0, 32) >>> 3) << 1).getRange(
          0,
          32,
        );
    final miCols = miFrom(rFrameWidth);
    final miRows = miFrom(rFrameHeight);
    Logic sbFrom(Logic mi) => mux(
      seqUse128,
      ((mi + Const(31, width: 32)).getRange(0, 32) >>> 5).getRange(0, 32),
      ((mi + Const(15, width: 32)).getRange(0, 32) >>> 4).getRange(0, 32),
    );
    final sbCols = sbFrom(miCols);
    final sbRows = sbFrom(miRows);

    // tile_info math (uniform spacing). tileLog2(blk, tgt) = count of k>=0 with
    // (blk << k) < tgt.
    Logic tileLog2(Logic blk, Logic tgt) {
      Logic count = Const(0, width: 5);
      for (var k = 0; k < 16; k++) {
        final shifted = (blk << k).getRange(0, 32);
        count = (count + shifted.lt(tgt).zeroExtend(5)).getRange(0, 5);
      }
      return count;
    }

    Logic minL(Logic a, Logic b) => mux(a.lt(b), a, b);
    Logic maxL(Logic a, Logic b) => mux(a.gt(b), a, b);

    final maxTileWidthSb = mux<Logic>(
      seqUse128,
      Const(32, width: 32),
      Const(64, width: 32),
    );
    final maxTileAreaSb = mux<Logic>(
      seqUse128,
      Const(576, width: 32),
      Const(2304, width: 32),
    );
    final sbCols64 = minL(sbCols, Const(64, width: 32));
    final sbRows64 = minL(sbRows, Const(64, width: 32));
    final minLog2TileCols = tileLog2(maxTileWidthSb, sbCols);
    final maxLog2TileCols = tileLog2(Const(1, width: 32), sbCols64);
    final maxLog2TileRows = tileLog2(Const(1, width: 32), sbRows64);
    final sbArea = (sbCols * sbRows).getRange(0, 32);
    final minLog2Tiles = maxL(minLog2TileCols, tileLog2(maxTileAreaSb, sbArea));
    // minLog2TileRows = max(minLog2Tiles - tileColsLog2, 0).
    final minLog2TileRows = mux(
      minLog2Tiles.gt(rTileColsLog2.zeroExtend(5)),
      (minLog2Tiles - rTileColsLog2.zeroExtend(5)).getRange(0, 5),
      Const(0, width: 5),
    );

    // ceil(num / den) for den >= 1, bounded by maxQ (count of k in [0,maxQ) with
    // k*den < num).
    Logic ceilDiv(Logic num, Logic den) {
      Logic count = Const(0, width: 8);
      for (var k = 0; k < 64; k++) {
        final kd = (den * Const(k, width: 32)).getRange(0, 32);
        count = (count + kd.lt(num).zeroExtend(8)).getRange(0, 8);
      }
      return count;
    }

    // tileWidthSb = ceil(sbCols / 2^tileColsLog2). tileCols = ceil(sbCols/that).
    final tileWidthSb =
        ((sbCols +
                        ((Const(1, width: 32) << rTileColsLog2.zeroExtend(5)) -
                                Const(1, width: 32))
                            .getRange(0, 32))
                    .getRange(0, 32) >>>
                rTileColsLog2.zeroExtend(32))
            .getRange(0, 32);
    final tileHeightSb =
        ((sbRows +
                        ((Const(1, width: 32) << rTileRowsLog2.zeroExtend(5)) -
                                Const(1, width: 32))
                            .getRange(0, 32))
                    .getRange(0, 32) >>>
                rTileRowsLog2.zeroExtend(32))
            .getRange(0, 32);
    final tileColsCalc = ceilDiv(sbCols, tileWidthSb);
    final tileRowsCalc = ceilDiv(sbRows, tileHeightSb);

    output('done') <= st.eq(sc(sDone)) | st.eq(sc(sUnsupported));
    output('unsupported') <= st.eq(sc(sUnsupported));
    output('bits_consumed') <= pos;
    output('frame_type') <= rFrameType;
    output('frame_is_intra') <= rIntra;
    output('show_frame') <= rShowFrame;
    output('showable_frame') <= rShowable;
    output('error_resilient_mode') <= rErr;
    output('disable_cdf_update') <= rDisableCdf;
    output('allow_screen_content_tools') <= rAllowScreen;
    output('force_integer_mv') <= rForceMv;
    output('allow_intrabc') <= rAllowIntrabc;
    output('order_hint') <= rOrderHint;
    output('refresh_frame_flags') <= rRefresh;
    output('show_existing_frame') <= rShowExisting;
    output('frame_to_show_map_idx') <= rFrameToShow;
    output('frame_width') <= rFrameWidth;
    output('frame_height') <= rFrameHeight;
    output('upscaled_width') <= rUpscaledWidth;
    output('render_width') <= rRenderWidth;
    output('render_height') <= rRenderHeight;
    output('superres_denom') <= rSuperresDenom;
    output('disable_frame_end_update_cdf') <= rDisableFrameEnd;
    output('tile_cols') <= rTileCols;
    output('tile_rows') <= rTileRows;
    output('tile_cols_log2') <= rTileColsLog2;
    output('tile_rows_log2') <= rTileRowsLog2;
    output('context_update_tile_id') <= rContextUpdate;
    output('tile_size_bytes') <= rTileSizeBytes;
    output('base_q_idx') <= rBaseQ;
    output('delta_q_y_dc') <= rDQYdc;
    output('delta_q_u_dc') <= rDQUdc;
    output('delta_q_u_ac') <= rDQUac;
    output('delta_q_v_dc') <= rDQVdc;
    output('delta_q_v_ac') <= rDQVac;
    output('using_qmatrix') <= rUsingQm;
    output('qm_y') <= rQmY;
    output('qm_u') <= rQmU;
    output('qm_v') <= rQmV;

    // coded_lossless: base_q_idx == 0 and every dc/ac delta == 0 (no
    // segmentation deltas, segmentation is disabled in this increment).
    final codedLossless =
        rBaseQ.eq(Const(0, width: 8)) &
        rDQYdc.eq(Const(0, width: 8)) &
        rDQUdc.eq(Const(0, width: 8)) &
        rDQUac.eq(Const(0, width: 8)) &
        rDQVdc.eq(Const(0, width: 8)) &
        rDQVac.eq(Const(0, width: 8));

    output('segmentation_enabled') <= rSegEnabled;
    output('delta_q_present') <= rDeltaQPresent;
    output('delta_q_res') <= rDeltaQRes;
    output('delta_lf_present') <= rDeltaLfPresent;
    output('delta_lf_res') <= rDeltaLfRes;
    output('delta_lf_multi') <= rDeltaLfMulti;
    output('coded_lossless') <= codedLossless;
    output('loop_filter_level_0') <= rLfLevel0;
    output('loop_filter_level_1') <= rLfLevel1;
    output('loop_filter_level_2') <= rLfLevel2;
    output('loop_filter_level_3') <= rLfLevel3;
    output('loop_filter_sharpness') <= rLfSharp;
    output('loop_filter_delta_enabled') <= rLfDeltaEnabled;
    output('loop_filter_ref_deltas') <=
        [for (var i = 7; i >= 0; i--) lfRefD[i]].concat();
    output('loop_filter_mode_deltas') <=
        [for (var i = 1; i >= 0; i--) lfModeD[i]].concat();

    // all_lossless: superres off => upscaledWidth == frameWidth, so == lossless.
    final allLossless = codedLossless & rFrameWidth.eq(rUpscaledWidth);
    // number of cdef strength entries = 1 << cdef_bits.
    final nCdef = (Const(1, width: 4) << rCdefBits.zeroExtend(4)).getRange(
      0,
      4,
    );
    final lrSize1 = (rLrSize0 >>> rLrUvShift.zeroExtend(9)).getRange(0, 9);

    output('cdef_damping_minus3') <= rCdefDamping;
    output('cdef_bits') <= rCdefBits;
    output('cdef_y_pri_strength') <=
        [for (var i = 7; i >= 0; i--) cdefYpri[i]].concat();
    output('cdef_y_sec_strength') <=
        [for (var i = 7; i >= 0; i--) cdefYsec[i]].concat();
    output('cdef_uv_pri_strength') <=
        [for (var i = 7; i >= 0; i--) cdefUvpri[i]].concat();
    output('cdef_uv_sec_strength') <=
        [for (var i = 7; i >= 0; i--) cdefUvsec[i]].concat();
    output('frame_restoration_type') <=
        [for (var i = 2; i >= 0; i--) frameRestType[i]].concat();
    output('uses_lr') <= rUsesLr;
    output('lr_size_0') <= rLrSize0;
    output('lr_size_1') <= lrSize1;
    output('lr_size_2') <= lrSize1;
    output('tx_mode') <= rTxMode;
    output('reduced_tx_set') <= rReducedTxSet;
    output('apply_grain') <= rApplyGrain;
    output('primary_ref_frame') <= rPrimaryRef;
    // rRefIdx shifted-in: refFrameIdx[0] at bits 18..20 ... [6] at bits 0..2.
    // Output wants [i*3 +: 3] = refFrameIdx[i], so reverse the 3-bit groups.
    output('ref_frame_idx') <=
        [
          for (var i = 0; i < 7; i++) rRefIdx.getRange(i * 3, i * 3 + 3),
        ].concat();
    output('allow_high_precision_mv') <= rHighPrecMv;
    output('is_filter_switchable') <= rIsFilterSw;
    output('interpolation_filter') <= rInterpFilter;
    output('is_motion_mode_switchable') <= rMotionModeSw;
    output('use_ref_frame_mvs') <= rUseRefMvs;
    output('reference_select') <= rRefSelect;
    output('skip_mode_present') <= rSkipModePresent;
    output('allow_warped_motion') <= rAllowWarped;

    Logic vv(int w) => rv.getRange(0, w);
    List<Conditional> step(Logic to) => [pos < nextPos, st < to];

    Sequential(clk, [
      If(
        reset,
        then: [
          st < sc(sIdle),
          pos < Const(0, width: offW),
          rFrameType < Const(keyFrame, width: 2),
          rIntra < Const(1),
          rShowFrame < Const(1),
          rShowable < Const(0),
          rErr < Const(0),
          rDisableCdf < Const(0),
          rAllowScreen < Const(0),
          rForceMv < Const(1, width: 2),
          rSizeOverride < Const(0),
          rOrderHint < Const(0, width: 8),
          rRefresh < Const(0xff, width: 8),
          rShowExisting < Const(0),
          rFrameToShow < Const(0, width: 3),
          rAllowIntrabc < Const(0),
          rFrameWidth < Const(0, width: 32),
          rFrameHeight < Const(0, width: 32),
          rUpscaledWidth < Const(0, width: 32),
          rRenderWidth < Const(0, width: 32),
          rRenderHeight < Const(0, width: 32),
          rSuperresDenom < Const(8, width: 5),
          rDisableFrameEnd < Const(1),
          rTileCols < Const(1, width: 8),
          rTileRows < Const(1, width: 8),
          rTileColsLog2 < Const(0, width: 4),
          rTileRowsLog2 < Const(0, width: 4),
          rContextUpdate < Const(0, width: 12),
          rTileSizeBytes < Const(1, width: 3),
          rBaseQ < Const(0, width: 8),
          rDQYdc < Const(0, width: 8),
          rDQUdc < Const(0, width: 8),
          rDQUac < Const(0, width: 8),
          rDQVdc < Const(0, width: 8),
          rDQVac < Const(0, width: 8),
          rDiffUv < Const(0),
          rUsingQm < Const(0),
          rQmY < Const(0, width: 4),
          rQmU < Const(0, width: 4),
          rQmV < Const(0, width: 4),
          rSegEnabled < Const(0),
          rDeltaQPresent < Const(0),
          rDeltaQRes < Const(0, width: 2),
          rDeltaLfPresent < Const(0),
          rDeltaLfRes < Const(0, width: 2),
          rDeltaLfMulti < Const(0),
          rLfLevel0 < Const(0, width: 6),
          rLfLevel1 < Const(0, width: 6),
          rLfLevel2 < Const(0, width: 6),
          rLfLevel3 < Const(0, width: 6),
          rLfSharp < Const(0, width: 3),
          rLfDeltaEnabled < Const(0),
          // default loop filter deltas: [1,0,0,0,-1,0,-1,-1] / [0,0].
          // (idx4 GOLDEN=-1, idx5 BWDREF=0, per AV1 setup_past_independence.)
          lfRefD[0] < Const(1, width: 8),
          lfRefD[1] < Const(0, width: 8),
          lfRefD[2] < Const(0, width: 8),
          lfRefD[3] < Const(0, width: 8),
          lfRefD[4] < Const(0xff, width: 8),
          lfRefD[5] < Const(0, width: 8),
          lfRefD[6] < Const(0xff, width: 8),
          lfRefD[7] < Const(0xff, width: 8),
          lfModeD[0] < Const(0, width: 8),
          lfModeD[1] < Const(0, width: 8),
          li < Const(0, width: 4),
          rCdefDamping < Const(0, width: 2),
          rCdefBits < Const(0, width: 2),
          for (var i = 0; i < 8; i++) cdefYpri[i] < Const(0, width: 4),
          for (var i = 0; i < 8; i++) cdefYsec[i] < Const(0, width: 4),
          for (var i = 0; i < 8; i++) cdefUvpri[i] < Const(0, width: 4),
          for (var i = 0; i < 8; i++) cdefUvsec[i] < Const(0, width: 4),
          for (var i = 0; i < 3; i++) frameRestType[i] < Const(0, width: 2),
          rUsesLr < Const(0),
          rUsesChromaLr < Const(0),
          rLrUnitShift < Const(0, width: 2),
          rLrUvShift < Const(0),
          rLrSize0 < Const(0, width: 9),
          rTxMode < Const(1, width: 2), // TX_MODE_LARGEST default
          rReducedTxSet < Const(0),
          rApplyGrain < Const(0),
          rPrimaryRef < Const(7, width: 3), // PRIMARY_REF_NONE
          rShortSignaling < Const(0),
          rRefIdx < Const(0, width: 7 * 3),
          ri < Const(0, width: 3),
          gi < Const(0, width: 3),
          rHighPrecMv < Const(0),
          rIsFilterSw < Const(0),
          rInterpFilter < Const(0, width: 3),
          rMotionModeSw < Const(0),
          rUseRefMvs < Const(0),
          rRefSelect < Const(0),
          rSkipModePresent < Const(0),
          rAllowWarped < Const(0),
        ],
        orElse: [
          Case(st, [
            CaseItem(sc(sIdle), [
              If(
                start,
                then: [
                  pos < Const(0, width: offW),
                  // reduced still picture: key/intra/show, no prefix reads.
                  If(
                    seqReduced,
                    then: [
                      rFrameType < Const(keyFrame, width: 2),
                      rIntra < Const(1),
                      rShowFrame < Const(1),
                      rShowable < Const(0),
                      rErr < Const(1),
                      st < sc(sDisableCdf),
                    ],
                    orElse: [st < sc(sShowExisting)],
                  ),
                ],
              ),
            ]),
            CaseItem(sc(sShowExisting), [
              pos < nextPos,
              // show_existing_frame: re-display a stored reference (no decode).
              If(
                bit0,
                then: [
                  rShowExisting < Const(1),
                  // temporal_point_info (decoder_model, !equal_picture_interval)
                  // would precede frame_to_show_map_idx and is unsupported.
                  If(
                    seqDecModel,
                    then: [st < sc(sUnsupported)],
                    orElse: [st < sc(sSEIdx)],
                  ),
                ],
                orElse: [st < sc(sFrameType)],
              ),
            ]),
            CaseItem(sc(sSEIdx), [
              rFrameToShow < vv(3),
              pos < nextPos,
              // display_frame_id f(idLen) only when frame_id_numbers_present.
              If(
                seqFrameId,
                then: [st < sc(sSEDisplayId)],
                orElse: [st < sc(sSEFinish)],
              ),
            ]),
            CaseItem(sc(sSEDisplayId), [...step(sc(sSEFinish))]),
            CaseItem(sc(sSEFinish), [
              // frame_type / order_hint come from the shown slot's saved metadata.
              // A shown KEY_FRAME refreshes all 8 slots, otherwise none.
              rFrameType < shownFrameType,
              rOrderHint < shownOrderHint,
              rShowFrame < Const(1),
              rShowable < Const(0),
              rRefresh <
                  mux<Logic>(
                    shownFrameType.eq(Const(keyFrame, width: 2)),
                    Const(0xff, width: 8),
                    Const(0, width: 8),
                  ),
              st < sc(sDone),
            ]),
            CaseItem(sc(sFrameType), [
              rFrameType < vv(2),
              pos < nextPos,
              // frame_type: KEY(0)/INTRA_ONLY(2) are intra, INTER(1) supported,
              // SWITCH(3) still out of scope.
              If(
                vv(2).eq(Const(interFrame, width: 2)),
                then: [rIntra < Const(0), st < sc(sShowFrame)],
                orElse: [
                  If(
                    vv(2)[0],
                    then: [
                      st < sc(sUnsupported), // SWITCH_FRAME
                    ],
                    orElse: [rIntra < Const(1), st < sc(sShowFrame)],
                  ),
                ],
              ),
            ]),
            CaseItem(sc(sShowFrame), [
              rShowFrame < bit0,
              // showable_frame initial = frameType != KEY_FRAME.
              rShowable < ~rFrameType.eq(Const(keyFrame, width: 2)),
              pos < nextPos,
              If(
                bit0,
                then: [st < sc(sErrCheck)],
                orElse: [st < sc(sShowable)],
              ),
            ]),
            CaseItem(sc(sShowable), [rShowable < bit0, ...step(sc(sErrCheck))]),
            CaseItem(sc(sErrCheck), [
              // (switch || (key && show)) -> error_resilient = 1, no read.
              If(
                rFrameType.eq(Const(switchFrame, width: 2)) |
                    (rFrameType.eq(Const(keyFrame, width: 2)) & rShowFrame),
                then: [rErr < Const(1), st < sc(sDisableCdf)],
                orElse: [st < sc(sErrRead)],
              ),
            ]),
            CaseItem(sc(sErrRead), [rErr < bit0, ...step(sc(sDisableCdf))]),
            CaseItem(sc(sDisableCdf), [
              rDisableCdf < bit0,
              ...step(sc(sScreenCheck)),
            ]),
            CaseItem(sc(sScreenCheck), [
              If(
                seqForceScreen.eq(Const(primaryRefSelect, width: 2)),
                then: [st < sc(sScreenRead)],
                orElse: [
                  rAllowScreen < ~seqForceScreen.eq(Const(0, width: 2)),
                  st < sc(sForceMvCheck),
                ],
              ),
            ]),
            CaseItem(sc(sScreenRead), [
              rAllowScreen < bit0,
              ...step(sc(sForceMvCheck)),
            ]),
            CaseItem(sc(sForceMvCheck), [
              If(
                rAllowScreen,
                then: [
                  If(
                    seqForceIntMv.eq(Const(primaryRefSelect, width: 2)),
                    then: [st < sc(sForceMvRead)],
                    orElse: [rForceMv < seqForceIntMv, st < sc(sIntraForce)],
                  ),
                ],
                orElse: [rForceMv < Const(0, width: 2), st < sc(sIntraForce)],
              ),
            ]),
            CaseItem(sc(sForceMvRead), [
              rForceMv < bit0.zeroExtend(2),
              ...step(sc(sIntraForce)),
            ]),
            CaseItem(sc(sIntraForce), [
              // frameIsIntra -> forceIntegerMv = 1. Inter keeps the read value.
              If(rIntra, then: [rForceMv < Const(1, width: 2)]),
              st < sc(sFrameIdCheck),
            ]),
            CaseItem(sc(sFrameIdCheck), [
              If(
                seqReduced,
                then: [st < sc(sRefreshCheck)],
                orElse: [
                  If(
                    seqFrameId,
                    then: [st < sc(sCurrentFrameId)],
                    orElse: [st < sc(sFrameSizeOverride)],
                  ),
                ],
              ),
            ]),
            CaseItem(sc(sCurrentFrameId), [...step(sc(sFrameSizeOverride))]),
            CaseItem(sc(sFrameSizeOverride), [
              rSizeOverride < bit0,
              ...step(sc(sOrderHint)),
            ]),
            CaseItem(sc(sOrderHint), [
              rOrderHint < vv(8),
              pos < nextPos,
              // primary_ref_frame: read f(3) when !err && !intra, else NONE(7).
              If(
                ~rErr & ~rIntra,
                then: [st < sc(sPrimaryRef)],
                orElse: [
                  rPrimaryRef < Const(7, width: 3),
                  st < sc(sDecModelCheck),
                ],
              ),
            ]),
            CaseItem(sc(sPrimaryRef), [
              rPrimaryRef < vv(3),
              ...step(sc(sDecModelCheck)),
            ]),
            CaseItem(sc(sDecModelCheck), [
              If(
                seqDecModel,
                then: [st < sc(sUnsupported)],
                orElse: [st < sc(sRefreshCheck)],
              ),
            ]),
            CaseItem(sc(sRefreshCheck), [
              If(
                rFrameType.eq(Const(keyFrame, width: 2)) & rShowFrame,
                then: [
                  rRefresh < Const(0xff, width: 8),
                  st < sc(sRefOrderHintCheck),
                ],
                orElse: [st < sc(sRefreshRead)],
              ),
            ]),
            CaseItem(sc(sRefreshRead), [
              rRefresh < vv(8),
              ...step(sc(sRefOrderHintCheck)),
            ]),
            CaseItem(sc(sRefOrderHintCheck), [
              // ref_order_hint loop: (!intra || refresh!=0xff) && err && orderHint.
              // The error-resilient 8x ref_order_hint read is deferred.
              If(
                (~rIntra | ~rRefresh.eq(Const(0xff, width: 8))) &
                    rErr &
                    seqEnableOrderHint,
                then: [st < sc(sUnsupported)],
                orElse: [
                  If(
                    rIntra,
                    then: [st < sc(sFrameSizeStart)],
                    orElse: [st < sc(sInterRefStart)],
                  ),
                ],
              ),
            ]),
            // INTER ref_frame_idx / set_frame_refs
            CaseItem(sc(sInterRefStart), [
              // frame_refs_short_signaling = enableOrderHint ? f(1) : 0.
              If(
                seqEnableOrderHint,
                then: [st < sc(sShortSignaling)],
                orElse: [
                  rShortSignaling < Const(0),
                  ri < Const(0, width: 3),
                  st < sc(sRefIdxLoop),
                ],
              ),
            ]),
            CaseItem(sc(sShortSignaling), [
              rShortSignaling < bit0,
              pos < nextPos,
              // set_frame_refs (order-hint ref derivation) needs the DPB: defer.
              If(
                bit0,
                then: [st < sc(sUnsupported)],
                orElse: [ri < Const(0, width: 3), st < sc(sRefIdxLoop)],
              ),
            ]),
            CaseItem(sc(sRefIdxLoop), [
              If(
                ri.lt(Const(7, width: 3)),
                then: [
                  // frame_id_numbers_present adds delta_frame_id bits: deferred.
                  If(
                    seqFrameId,
                    then: [st < sc(sUnsupported)],
                    orElse: [st < sc(sRefIdxRead)],
                  ),
                ],
                orElse: [st < sc(sInterFrameSize)],
              ),
            ]),
            CaseItem(sc(sRefIdxRead), [
              rRefIdx <
                  ((rRefIdx << 3) | vv(3).zeroExtend(7 * 3)).getRange(0, 7 * 3),
              ri < (ri + Const(1, width: 3)).getRange(0, 3),
              ...step(sc(sRefIdxLoop)),
            ]),
            CaseItem(sc(sInterFrameSize), [
              // frame_size_with_refs (found_ref copy from DPB) is deferred. The
              // common override==0 / err path uses the plain frame_size read.
              If(
                ~rErr & rSizeOverride,
                then: [st < sc(sUnsupported)],
                orElse: [st < sc(sFrameSizeStart)],
              ),
            ]),
            CaseItem(sc(sFrameSizeStart), [
              If(
                rSizeOverride,
                then: [st < sc(sFSWidth)],
                orElse: [
                  rFrameWidth <
                      (seqMaxWM1 + Const(1, width: 32)).getRange(0, 32),
                  rFrameHeight <
                      (seqMaxHM1 + Const(1, width: 32)).getRange(0, 32),
                  rUpscaledWidth <
                      (seqMaxWM1 + Const(1, width: 32)).getRange(0, 32),
                  st < sc(sSuperresCheck),
                ],
              ),
            ]),
            CaseItem(sc(sFSWidth), [
              rFrameWidth < (rv + Const(1, width: 32)).getRange(0, 32),
              rUpscaledWidth < (rv + Const(1, width: 32)).getRange(0, 32),
              ...step(sc(sFSHeight)),
            ]),
            CaseItem(sc(sFSHeight), [
              rFrameHeight < (rv + Const(1, width: 32)).getRange(0, 32),
              ...step(sc(sSuperresCheck)),
            ]),
            CaseItem(sc(sSuperresCheck), [
              If(
                seqEnableSuperres,
                then: [st < sc(sSuperresUse)],
                orElse: [
                  rSuperresDenom < Const(8, width: 5),
                  st < sc(sRenderCheck),
                ],
              ),
            ]),
            CaseItem(sc(sSuperresUse), [
              pos < nextPos,
              // superres downscaling (the codedDenom division) is out of scope.
              If(
                bit0,
                then: [st < sc(sUnsupported)],
                orElse: [
                  rSuperresDenom < Const(8, width: 5),
                  st < sc(sRenderCheck),
                ],
              ),
            ]),
            CaseItem(sc(sRenderCheck), [
              pos < nextPos,
              If(
                bit0,
                then: [st < sc(sRenderW)],
                orElse: [
                  rRenderWidth < rUpscaledWidth,
                  rRenderHeight < rFrameHeight,
                  st < sc(sAfterRender),
                ],
              ),
            ]),
            CaseItem(sc(sRenderW), [
              rRenderWidth < (rv + Const(1, width: 32)).getRange(0, 32),
              ...step(sc(sRenderH)),
            ]),
            CaseItem(sc(sRenderH), [
              rRenderHeight < (rv + Const(1, width: 32)).getRange(0, 32),
              ...step(sc(sAfterRender)),
            ]),
            CaseItem(sc(sAfterRender), [
              If(
                rIntra,
                then: [
                  // allow_intrabc is intra-only.
                  If(
                    rAllowScreen & rUpscaledWidth.eq(rFrameWidth),
                    then: [st < sc(sIntrabc)],
                    orElse: [
                      rAllowIntrabc < Const(0),
                      st < sc(sDisableFrameEnd),
                    ],
                  ),
                ],
                orElse: [st < sc(sHighPrecCheck)],
              ),
            ]),
            // INTER: high-prec MV, interp filter, motion-mode, ref-mvs
            CaseItem(sc(sHighPrecCheck), [
              // allow_high_precision_mv: forceIntegerMv ? 0 : f(1).
              If(
                ~rForceMv.eq(Const(0, width: 2)),
                then: [rHighPrecMv < Const(0), st < sc(sInterpSwitch)],
                orElse: [st < sc(sHighPrecRead)],
              ),
            ]),
            CaseItem(sc(sHighPrecRead), [
              rHighPrecMv < bit0,
              ...step(sc(sInterpSwitch)),
            ]),
            CaseItem(sc(sInterpSwitch), [
              // is_filter_switchable = f(1).
              rIsFilterSw < bit0,
              pos < nextPos,
              If(
                bit0,
                then: [
                  rInterpFilter < Const(4, width: 3), // SWITCHABLE
                  st < sc(sMotionModeSw),
                ],
                orElse: [st < sc(sInterpRead)],
              ),
            ]),
            CaseItem(sc(sInterpRead), [
              rInterpFilter < vv(2).zeroExtend(3),
              ...step(sc(sMotionModeSw)),
            ]),
            CaseItem(sc(sMotionModeSw), [
              rMotionModeSw < bit0,
              pos < nextPos,
              st < sc(sUseRefMvsCheck),
            ]),
            CaseItem(sc(sUseRefMvsCheck), [
              // use_ref_frame_mvs: !err && enableRefFrameMvs && enableOrderHint
              // && !intra ? f(1) : 0.
              If(
                ~rErr & seqEnableRefFrameMvs & seqEnableOrderHint & ~rIntra,
                then: [st < sc(sUseRefMvsRead)],
                orElse: [rUseRefMvs < Const(0), st < sc(sDisableFrameEnd)],
              ),
            ]),
            CaseItem(sc(sUseRefMvsRead), [
              rUseRefMvs < bit0,
              ...step(sc(sDisableFrameEnd)),
            ]),
            CaseItem(sc(sIntrabc), [
              rAllowIntrabc < bit0,
              ...step(sc(sDisableFrameEnd)),
            ]),
            CaseItem(sc(sDisableFrameEnd), [
              If(
                seqReduced | rDisableCdf,
                then: [rDisableFrameEnd < Const(1), st < sc(sTileInfo)],
                orElse: [st < sc(sDisableFrameEndRead)],
              ),
            ]),
            CaseItem(sc(sDisableFrameEndRead), [
              rDisableFrameEnd < bit0,
              ...step(sc(sTileInfo)),
            ]),
            CaseItem(sc(sTileInfo), [
              // uniform_tile_spacing_flag.
              pos < nextPos,
              If(
                bit0,
                then: [
                  rTileColsLog2 < minLog2TileCols.getRange(0, 4),
                  st < sc(sTileColsLoop),
                ],
                orElse: [
                  st < sc(sUnsupported), // non-uniform tile spacing
                ],
              ),
            ]),
            CaseItem(sc(sTileColsLoop), [
              If(
                rTileColsLog2.zeroExtend(5).lt(maxLog2TileCols),
                then: [st < sc(sTileColsInc)],
                orElse: [st < sc(sTileRowsInit)],
              ),
            ]),
            CaseItem(sc(sTileColsInc), [
              pos < nextPos,
              If(
                bit0,
                then: [
                  rTileColsLog2 <
                      (rTileColsLog2 + Const(1, width: 4)).getRange(0, 4),
                  st < sc(sTileColsLoop),
                ],
                orElse: [st < sc(sTileRowsInit)],
              ),
            ]),
            CaseItem(sc(sTileRowsInit), [
              rTileRowsLog2 < minLog2TileRows.getRange(0, 4),
              st < sc(sTileRowsLoop),
            ]),
            CaseItem(sc(sTileRowsLoop), [
              If(
                rTileRowsLog2.zeroExtend(5).lt(maxLog2TileRows),
                then: [st < sc(sTileRowsInc)],
                orElse: [st < sc(sTileContextCheck)],
              ),
            ]),
            CaseItem(sc(sTileRowsInc), [
              pos < nextPos,
              If(
                bit0,
                then: [
                  rTileRowsLog2 <
                      (rTileRowsLog2 + Const(1, width: 4)).getRange(0, 4),
                  st < sc(sTileRowsLoop),
                ],
                orElse: [st < sc(sTileContextCheck)],
              ),
            ]),
            CaseItem(sc(sTileContextCheck), [
              rTileCols < tileColsCalc,
              rTileRows < tileRowsCalc,
              If(
                rTileColsLog2.gt(Const(0, width: 4)) |
                    rTileRowsLog2.gt(Const(0, width: 4)),
                then: [st < sc(sTileContextId)],
                orElse: [
                  rContextUpdate < Const(0, width: 12),
                  rTileSizeBytes < Const(1, width: 3),
                  st < sc(sQuant),
                ],
              ),
            ]),
            CaseItem(sc(sTileContextId), [
              rContextUpdate < rv.getRange(0, 12),
              ...step(sc(sTileSizeBytes)),
            ]),
            CaseItem(sc(sTileSizeBytes), [
              rTileSizeBytes <
                  (vv(2).zeroExtend(3) + Const(1, width: 3)).getRange(0, 3),
              ...step(sc(sQuant)),
            ]),
            CaseItem(sc(sQuant), [rBaseQ < vv(8), ...step(sc(sDQYdc))]),
            CaseItem(sc(sDQYdc), [
              pos < nextPos,
              If(
                bit0,
                then: [st < sc(sDQYdcVal)],
                orElse: [rDQYdc < Const(0, width: 8), st < sc(sQUVcheck)],
              ),
            ]),
            CaseItem(sc(sDQYdcVal), [rDQYdc < su7, ...step(sc(sQUVcheck))]),
            CaseItem(sc(sQUVcheck), [
              If(
                seqNumPlanes.gt(Const(1, width: 2)),
                then: [st < sc(sDiffUV)],
                orElse: [st < sc(sUsingQM)],
              ),
            ]),
            CaseItem(sc(sDiffUV), [
              If(
                seqSepUv,
                then: [st < sc(sDiffUVRead)],
                orElse: [rDiffUv < Const(0), st < sc(sDQUdc)],
              ),
            ]),
            CaseItem(sc(sDiffUVRead), [rDiffUv < bit0, ...step(sc(sDQUdc))]),
            CaseItem(sc(sDQUdc), [
              pos < nextPos,
              If(
                bit0,
                then: [st < sc(sDQUdcVal)],
                orElse: [rDQUdc < Const(0, width: 8), st < sc(sDQUac)],
              ),
            ]),
            CaseItem(sc(sDQUdcVal), [rDQUdc < su7, ...step(sc(sDQUac))]),
            CaseItem(sc(sDQUac), [
              pos < nextPos,
              If(
                bit0,
                then: [st < sc(sDQUacVal)],
                orElse: [rDQUac < Const(0, width: 8), st < sc(sVDeltaCheck)],
              ),
            ]),
            CaseItem(sc(sDQUacVal), [rDQUac < su7, ...step(sc(sVDeltaCheck))]),
            CaseItem(sc(sVDeltaCheck), [
              If(
                rDiffUv,
                then: [st < sc(sDQVdc)],
                orElse: [rDQVdc < rDQUdc, rDQVac < rDQUac, st < sc(sUsingQM)],
              ),
            ]),
            CaseItem(sc(sDQVdc), [
              pos < nextPos,
              If(
                bit0,
                then: [st < sc(sDQVdcVal)],
                orElse: [rDQVdc < Const(0, width: 8), st < sc(sDQVac)],
              ),
            ]),
            CaseItem(sc(sDQVdcVal), [rDQVdc < su7, ...step(sc(sDQVac))]),
            CaseItem(sc(sDQVac), [
              pos < nextPos,
              If(
                bit0,
                then: [st < sc(sDQVacVal)],
                orElse: [rDQVac < Const(0, width: 8), st < sc(sUsingQM)],
              ),
            ]),
            CaseItem(sc(sDQVacVal), [rDQVac < su7, ...step(sc(sUsingQM))]),
            CaseItem(sc(sUsingQM), [
              rUsingQm < bit0,
              pos < nextPos,
              If(bit0, then: [st < sc(sQMy)], orElse: [st < sc(sSegmentation)]),
            ]),
            CaseItem(sc(sQMy), [rQmY < vv(4), ...step(sc(sQMu))]),
            CaseItem(sc(sQMu), [
              rQmU < vv(4),
              pos < nextPos,
              If(
                seqSepUv,
                then: [st < sc(sQMv)],
                orElse: [rQmV < vv(4), st < sc(sSegmentation)],
              ),
            ]),
            CaseItem(sc(sQMv), [rQmV < vv(4), ...step(sc(sSegmentation))]),
            // Increment B: header tail
            CaseItem(sc(sSegmentation), [
              rSegEnabled < bit0,
              pos < nextPos,
              // segmentation feature loop deferred: enabled => unsupported.
              If(
                bit0,
                then: [st < sc(sUnsupported)],
                orElse: [st < sc(sDeltaQStart)],
              ),
            ]),
            CaseItem(sc(sDeltaQStart), [
              // delta_q_present read only when base_q_idx > 0.
              If(
                rBaseQ.gt(Const(0, width: 8)),
                then: [st < sc(sDeltaQRead)],
                orElse: [rDeltaQPresent < Const(0), st < sc(sDeltaLfStart)],
              ),
            ]),
            CaseItem(sc(sDeltaQRead), [
              rDeltaQPresent < bit0,
              pos < nextPos,
              If(
                bit0,
                then: [st < sc(sDeltaQRes)],
                orElse: [st < sc(sDeltaLfStart)],
              ),
            ]),
            CaseItem(sc(sDeltaQRes), [
              rDeltaQRes < vv(2),
              ...step(sc(sDeltaLfStart)),
            ]),
            CaseItem(sc(sDeltaLfStart), [
              // delta_lf_present read only when delta_q_present && !allow_intrabc.
              If(
                rDeltaQPresent & ~rAllowIntrabc,
                then: [st < sc(sDeltaLfRead)],
                orElse: [rDeltaLfPresent < Const(0), st < sc(sLoopFilterStart)],
              ),
            ]),
            CaseItem(sc(sDeltaLfRead), [
              rDeltaLfPresent < bit0,
              pos < nextPos,
              If(
                bit0,
                then: [st < sc(sDeltaLfRes)],
                orElse: [st < sc(sLoopFilterStart)],
              ),
            ]),
            CaseItem(sc(sDeltaLfRes), [
              rDeltaLfRes < vv(2),
              ...step(sc(sDeltaLfMulti)),
            ]),
            CaseItem(sc(sDeltaLfMulti), [
              rDeltaLfMulti < bit0,
              ...step(sc(sLoopFilterStart)),
            ]),
            CaseItem(sc(sLoopFilterStart), [
              // coded_lossless || allow_intrabc => levels 0, deltas default, done.
              If(
                codedLossless | rAllowIntrabc,
                then: [
                  rLfLevel0 < Const(0, width: 6),
                  rLfLevel1 < Const(0, width: 6),
                  rLfLevel2 < Const(0, width: 6),
                  rLfLevel3 < Const(0, width: 6),
                  st < sc(sCdefStart),
                ],
                orElse: [st < sc(sLfLevel0)],
              ),
            ]),
            CaseItem(sc(sLfLevel0), [
              rLfLevel0 < vv(6),
              ...step(sc(sLfLevel1)),
            ]),
            CaseItem(sc(sLfLevel1), [
              rLfLevel1 < vv(6),
              ...step(sc(sLfChroma)),
            ]),
            CaseItem(sc(sLfChroma), [
              // chroma levels read only when numPlanes>1 and a luma level != 0.
              If(
                seqNumPlanes.gt(Const(1, width: 2)) &
                    (~rLfLevel0.eq(Const(0, width: 6)) |
                        ~rLfLevel1.eq(Const(0, width: 6))),
                then: [st < sc(sLfLevel2)],
                orElse: [st < sc(sLfSharp)],
              ),
            ]),
            CaseItem(sc(sLfLevel2), [
              rLfLevel2 < vv(6),
              ...step(sc(sLfLevel3)),
            ]),
            CaseItem(sc(sLfLevel3), [rLfLevel3 < vv(6), ...step(sc(sLfSharp))]),
            CaseItem(sc(sLfSharp), [
              rLfSharp < vv(3),
              ...step(sc(sLfDeltaEnabled)),
            ]),
            CaseItem(sc(sLfDeltaEnabled), [
              rLfDeltaEnabled < bit0,
              pos < nextPos,
              If(
                bit0,
                then: [st < sc(sLfUpdate)],
                orElse: [st < sc(sCdefStart)],
              ),
            ]),
            CaseItem(sc(sLfUpdate), [
              pos < nextPos,
              If(
                bit0,
                then: [li < Const(0, width: 4), st < sc(sLfRefBit)],
                orElse: [st < sc(sCdefStart)],
              ),
            ]),
            CaseItem(sc(sLfRefBit), [
              pos < nextPos,
              If(
                bit0,
                then: [st < sc(sLfRefVal)],
                orElse: [
                  // not present: keep default, advance to the next index.
                  If(
                    li.lt(Const(7, width: 4)),
                    then: [
                      li < (li + Const(1, width: 4)).getRange(0, 4),
                      st < sc(sLfRefBit),
                    ],
                    orElse: [li < Const(0, width: 4), st < sc(sLfModeBit)],
                  ),
                ],
              ),
            ]),
            CaseItem(sc(sLfRefVal), [
              // write su(7) into ref delta [li].
              for (var k = 0; k < 8; k++)
                If(li.eq(Const(k, width: 4)), then: [lfRefD[k] < su7]),
              pos < nextPos,
              If(
                li.lt(Const(7, width: 4)),
                then: [
                  li < (li + Const(1, width: 4)).getRange(0, 4),
                  st < sc(sLfRefBit),
                ],
                orElse: [li < Const(0, width: 4), st < sc(sLfModeBit)],
              ),
            ]),
            CaseItem(sc(sLfModeBit), [
              pos < nextPos,
              If(
                bit0,
                then: [st < sc(sLfModeVal)],
                orElse: [
                  If(
                    li.lt(Const(1, width: 4)),
                    then: [
                      li < (li + Const(1, width: 4)).getRange(0, 4),
                      st < sc(sLfModeBit),
                    ],
                    orElse: [st < sc(sCdefStart)],
                  ),
                ],
              ),
            ]),
            CaseItem(sc(sLfModeVal), [
              for (var k = 0; k < 2; k++)
                If(li.eq(Const(k, width: 4)), then: [lfModeD[k] < su7]),
              pos < nextPos,
              If(
                li.lt(Const(1, width: 4)),
                then: [
                  li < (li + Const(1, width: 4)).getRange(0, 4),
                  st < sc(sLfModeBit),
                ],
                orElse: [st < sc(sCdefStart)],
              ),
            ]),
            // Increment C: cdef / lr / tx_mode / reduced_tx_set / film_grain
            CaseItem(sc(sCdefStart), [
              If(
                codedLossless | rAllowIntrabc | ~seqEnableCdef,
                then: [
                  rCdefDamping < Const(0, width: 2),
                  rCdefBits < Const(0, width: 2),
                  for (var k = 0; k < 8; k++) cdefYpri[k] < Const(0, width: 4),
                  for (var k = 0; k < 8; k++) cdefYsec[k] < Const(0, width: 4),
                  for (var k = 0; k < 8; k++) cdefUvpri[k] < Const(0, width: 4),
                  for (var k = 0; k < 8; k++) cdefUvsec[k] < Const(0, width: 4),
                  st < sc(sLrStart),
                ],
                orElse: [st < sc(sCdefDamping)],
              ),
            ]),
            CaseItem(sc(sCdefDamping), [
              rCdefDamping < vv(2),
              ...step(sc(sCdefBits)),
            ]),
            CaseItem(sc(sCdefBits), [
              rCdefBits < vv(2),
              li < Const(0, width: 4),
              ...step(sc(sCdefYpri)),
            ]),
            CaseItem(sc(sCdefYpri), [
              for (var k = 0; k < 8; k++)
                If(li.eq(Const(k, width: 4)), then: [cdefYpri[k] < vv(4)]),
              ...step(sc(sCdefYsec)),
            ]),
            CaseItem(sc(sCdefYsec), [
              // sec_strength == 3 maps to 4.
              for (var k = 0; k < 8; k++)
                If(
                  li.eq(Const(k, width: 4)),
                  then: [
                    cdefYsec[k] <
                        mux(
                          vv(2).eq(Const(3, width: 2)),
                          Const(4, width: 4),
                          vv(2).zeroExtend(4),
                        ),
                  ],
                ),
              pos < nextPos,
              If(
                seqNumPlanes.gt(Const(1, width: 2)),
                then: [st < sc(sCdefUvpri)],
                orElse: [st < sc(sCdefNext)],
              ),
            ]),
            CaseItem(sc(sCdefUvCheck), [st < sc(sCdefUvpri)]),
            CaseItem(sc(sCdefUvpri), [
              for (var k = 0; k < 8; k++)
                If(li.eq(Const(k, width: 4)), then: [cdefUvpri[k] < vv(4)]),
              ...step(sc(sCdefUvsec)),
            ]),
            CaseItem(sc(sCdefUvsec), [
              for (var k = 0; k < 8; k++)
                If(
                  li.eq(Const(k, width: 4)),
                  then: [
                    cdefUvsec[k] <
                        mux(
                          vv(2).eq(Const(3, width: 2)),
                          Const(4, width: 4),
                          vv(2).zeroExtend(4),
                        ),
                  ],
                ),
              ...step(sc(sCdefNext)),
            ]),
            CaseItem(sc(sCdefNext), [
              // loop while (li + 1) < (1 << cdef_bits).
              If(
                (li + Const(1, width: 4)).getRange(0, 4).lt(nCdef),
                then: [
                  li < (li + Const(1, width: 4)).getRange(0, 4),
                  st < sc(sCdefYpri),
                ],
                orElse: [st < sc(sLrStart)],
              ),
            ]),
            CaseItem(sc(sLrStart), [
              If(
                allLossless | rAllowIntrabc | ~seqEnableRestoration,
                then: [
                  for (var k = 0; k < 3; k++)
                    frameRestType[k] < Const(0, width: 2),
                  rUsesLr < Const(0),
                  st < sc(sTxMode),
                ],
                orElse: [
                  li < Const(0, width: 4),
                  rUsesLr < Const(0),
                  rUsesChromaLr < Const(0),
                  st < sc(sLrType),
                ],
              ),
            ]),
            CaseItem(sc(sLrType), [
              for (var k = 0; k < 3; k++)
                If(
                  li.eq(Const(k, width: 4)),
                  then: [frameRestType[k] < lrRemapped],
                ),
              If(
                lrNonNone,
                then: [
                  rUsesLr < Const(1),
                  If(
                    li.gt(Const(0, width: 4)),
                    then: [rUsesChromaLr < Const(1)],
                  ),
                ],
              ),
              pos < nextPos,
              st < sc(sLrNext),
            ]),
            CaseItem(sc(sLrNext), [
              If(
                (li + Const(1, width: 4))
                    .getRange(0, 4)
                    .lt(seqNumPlanes.zeroExtend(4)),
                then: [
                  li < (li + Const(1, width: 4)).getRange(0, 4),
                  st < sc(sLrType),
                ],
                orElse: [st < sc(sLrUnit)],
              ),
            ]),
            CaseItem(sc(sLrUnit), [
              If(
                rUsesLr,
                then: [st < sc(sLrUnitA)],
                orElse: [st < sc(sTxMode)],
              ),
            ]),
            CaseItem(sc(sLrUnitA), [
              pos < nextPos,
              If(
                seqUse128,
                then: [
                  // lr_unit_shift = f(1) + 1.
                  rLrUnitShift <
                      (bit0.zeroExtend(2) + Const(1, width: 2)).getRange(0, 2),
                  st < sc(sLrUvCheck),
                ],
                orElse: [
                  rLrUnitShift < bit0.zeroExtend(2),
                  If(
                    bit0,
                    then: [st < sc(sLrUnitB)],
                    orElse: [st < sc(sLrUvCheck)],
                  ),
                ],
              ),
            ]),
            CaseItem(sc(sLrUnitB), [
              // lr_unit_shift (was 1) += f(1).
              rLrUnitShift <
                  (Const(1, width: 2) + bit0.zeroExtend(2)).getRange(0, 2),
              ...step(sc(sLrUvCheck)),
            ]),
            CaseItem(sc(sLrUvCheck), [
              If(
                seqSubX & seqSubY & rUsesChromaLr,
                then: [st < sc(sLrUvRead)],
                orElse: [rLrUvShift < Const(0), st < sc(sLrFinish)],
              ),
            ]),
            CaseItem(sc(sLrUvRead), [
              rLrUvShift < bit0,
              ...step(sc(sLrFinish)),
            ]),
            CaseItem(sc(sLrFinish), [
              // loopRestorationSize0 = 256 >> (2 - lr_unit_shift): 0->64,1->128,2->256.
              rLrSize0 <
                  mux(
                    rLrUnitShift.eq(Const(0, width: 2)),
                    Const(64, width: 9),
                    mux<Logic>(
                      rLrUnitShift.eq(Const(1, width: 2)),
                      Const(128, width: 9),
                      Const(256, width: 9),
                    ),
                  ),
              st < sc(sTxMode),
            ]),
            CaseItem(sc(sTxMode), [
              If(
                codedLossless,
                then: [
                  rTxMode < Const(0, width: 2), // TX_MODE_ONLY_4X4
                  // intra: straight to reduced_tx_set. Inter: reference_mode first.
                  If(
                    rIntra,
                    then: [st < sc(sReducedTxSet)],
                    orElse: [st < sc(sRefModeRead)],
                  ),
                ],
                orElse: [st < sc(sTxModeRead)],
              ),
            ]),
            CaseItem(sc(sTxModeRead), [
              // tx_mode_select ? TX_MODE_SELECT(2) : TX_MODE_LARGEST(1).
              rTxMode <
                  mux<Logic>(bit0, Const(2, width: 2), Const(1, width: 2)),
              pos < nextPos,
              If(
                rIntra,
                then: [st < sc(sReducedTxSet)],
                orElse: [st < sc(sRefModeRead)],
              ),
            ]),
            // INTER: frame_reference_mode / skip_mode / allow_warped
            CaseItem(sc(sRefModeRead), [
              // frame_reference_mode: f(1) ? REFERENCE_MODE_SELECT : SINGLE.
              rRefSelect < bit0,
              ...step(sc(sSkipModeParams)),
            ]),
            CaseItem(sc(sSkipModeParams), [
              // skip_mode not present for single-reference / !order_hint / intra.
              // The compound skip_mode_allowed derivation needs the DPB: deferred.
              If(
                ~seqEnableOrderHint | rIntra | ~rRefSelect,
                then: [rSkipModePresent < Const(0), st < sc(sAllowWarpedCheck)],
                orElse: [st < sc(sUnsupported)],
              ),
            ]),
            CaseItem(sc(sAllowWarpedCheck), [
              If(
                ~rErr & ~rIntra & seqEnableWarpedMotion,
                then: [st < sc(sAllowWarpedRead)],
                orElse: [rAllowWarped < Const(0), st < sc(sReducedTxSet)],
              ),
            ]),
            CaseItem(sc(sAllowWarpedRead), [
              rAllowWarped < bit0,
              ...step(sc(sReducedTxSet)),
            ]),
            CaseItem(sc(sReducedTxSet), [
              rReducedTxSet < bit0,
              pos < nextPos,
              // inter: global_motion_params before film_grain (nested subexp FSM).
              If(
                rIntra,
                then: [st < sc(sFilmGrainCheck)],
                orElse: [st < sc(sGmStart)],
              ),
            ]),
            CaseItem(sc(sGmStart), [
              // pulse the gm decoder (its `start` is st==sGmStart). It latches
              // base_offset = pos and runs on the shared byte window.
              st < sc(sGmWait),
            ]),
            CaseItem(sc(sGmWait), [
              If(
                gmp.output('done'),
                then: [
                  pos < gmp.output('bits_consumed'),
                  st < sc(sFilmGrainCheck),
                ],
              ),
            ]),
            CaseItem(sc(sFilmGrainCheck), [
              If(
                seqFilmGrain & (rShowFrame | rShowable),
                then: [st < sc(sFilmGrainApply)],
                orElse: [st < sc(sDone)],
              ),
            ]),
            CaseItem(sc(sFilmGrainApply), [
              rApplyGrain < bit0,
              pos < nextPos,
              // applied film grain (the AR-coeff block) is deferred.
              If(bit0, then: [st < sc(sUnsupported)], orElse: [st < sc(sDone)]),
            ]),
            CaseItem(sc(sDone), [
              If(~start, then: [st < sc(sIdle)]),
            ]),
            CaseItem(sc(sUnsupported), [
              If(~start, then: [st < sc(sIdle)]),
            ]),
          ]),
        ],
      ),
    ]);
  }
}
