import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'frame_header_parse.dart';
import 'obu_parser.dart';
import 'seq_header_parse.dart';
import 'tile_group_parse.dart';

/// Harbor AV1 keyframe OBU front end: the integrated bitstream entry point.
///
/// Walks an OBU stream OBU-to-OBU (a byte-granular barrel shift of the buffer to
/// the running cursor feeds a combinational [HarborObuParser]), and routes the
/// two header OBUs into the full sequential parsers:
///  - OBU_SEQUENCE_HEADER (type 1) -> [HarborSeqHeaderParse]
///  - OBU_FRAME_HEADER (type 3)     -> [HarborFrameHeaderParse]
/// The sequence-header parser's field outputs are wired DIRECTLY into the
/// frame-header parser's sequence-dependency inputs (the proven composition), so
/// after the seq header is parsed its parameters drive the frame header parse.
/// Every other OBU (temporal delimiter, etc.) is skipped by advancing the cursor
/// `header_len + obu_size` bytes.
///
/// FSM: on `start`, walk from cursor 0, at each OBU pulse the matching parser and
/// wait for its `done`, then advance. Assert `done` when the cursor reaches
/// `stream_len`. Scope: one sequence header + one frame header per stream (a
/// keyframe access unit: TD, seq, frame header). The frame parser's keyframe
/// scope applies (see [HarborFrameHeaderParse]). The frame-header fields are
/// exposed as pass-through outputs.
class HarborObuFrontEnd extends BridgeModule {
  /// Buffer size in bytes (the whole OBU stream window).
  final int bufBytes;

  HarborObuFrontEnd({this.bufBytes = 128, String? name})
    : assert(bufBytes >= 80, 'need room for an OBU header window'),
      super('HarborObuFrontEnd', name: name ?? 'obu_front_end') {
    const seqBytes = 32, frameBytes = 64;
    final totalBits = bufBytes * 8;
    const cw = 12; // cursor / length width (bytes)
    final viewBits = totalBits < 640 ? totalBits : 640;

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: totalBits);
    createPort('stream_len', PortDirection.input, width: cw);

    addOutput('done');
    addOutput('obu_count', width: 8);
    addOutput('frame_unsupported');
    // frame-header pass-through fields
    addOutput('frame_type', width: 2);
    addOutput('show_frame');
    addOutput('frame_width', width: 32);
    addOutput('frame_height', width: 32);
    addOutput('base_q_idx', width: 8);
    addOutput('tile_cols', width: 8);
    addOutput('tile_rows', width: 8);
    addOutput('tile_cols_log2', width: 4);
    addOutput('tile_rows_log2', width: 4);
    addOutput('coded_lossless');
    addOutput('cdef_bits', width: 2);
    addOutput('tx_mode', width: 2);
    addOutput('seq_profile', width: 3);
    // tile group: per-tile coded-byte slices (relative to tile_group_base).
    addOutput('tile_count', width: 8);
    addOutput('tile_offsets', width: 8 * 12);
    addOutput('tile_sizes', width: 8 * 12);
    addOutput('tile_group_base', width: 12); // absolute byte offset of payload

    final clk = input('clk');
    final reset = input('reset');
    final start = input('start');
    final bytesIn = input('bytes');
    final streamLen = input('stream_len');

    // sub-modules
    final obu = HarborObuParser(name: 'obu');
    final seqp = HarborSeqHeaderParse(maxBytes: seqBytes, name: 'seq');
    final framep = HarborFrameHeaderParse(maxBytes: frameBytes, name: 'frame');
    final tgp = HarborTileGroupParse(bufBytes: 64, maxTiles: 8, name: 'tg');
    addSubModule(obu);
    addSubModule(seqp);
    addSubModule(framep);
    addSubModule(tgp);

    // registers
    final state = Logic(name: 'state', width: 3);
    final cursor = Logic(name: 'cursor', width: cw);
    final count = Logic(name: 'obu_count_r', width: 8);
    final tgBase = Logic(name: 'tg_base_r', width: cw);

    const sIdle = 0,
        sObu = 1,
        sSeqWait = 2,
        sFrameWait = 3,
        sAdvance = 4,
        sDone = 5,
        sTileGroupWait = 6;
    Logic st(int v) => Const(v, width: 3);

    // Byte-granular view at the cursor: bytes >> (cursor * 8).
    final cursorShift = [cursor, Const(0, width: 3)].concat(); // cursor*8
    final cursorView = (bytesIn >>> cursorShift.zeroExtend(totalBits))
        .getRange(0, viewBits)
        .named('cursor_view');
    obu.input('bytes').srcConnection! <= cursorView.getRange(0, 80);

    final obuType = obu.output('obu_type');
    final headerLen = obu.output('header_len');
    final obuSize = obu.output('obu_size');

    // Payload view: shift the cursor view past the OBU header.
    final hdrShift = [headerLen, Const(0, width: 3)].concat(); // header_len*8
    final payloadView = (cursorView >>> hdrShift.zeroExtend(viewBits))
        .getRange(0, 512)
        .named('payload_view');

    final seqStart = Logic(name: 'seq_start');
    final frameStart = Logic(name: 'frame_start');

    seqp.input('clk').srcConnection! <= clk;
    seqp.input('reset').srcConnection! <= reset;
    seqp.input('start').srcConnection! <= seqStart;
    seqp.input('bytes').srcConnection! <= payloadView.getRange(0, seqBytes * 8);

    framep.input('clk').srcConnection! <= clk;
    framep.input('reset').srcConnection! <= reset;
    framep.input('start').srcConnection! <= frameStart;
    framep.input('bytes').srcConnection! <=
        payloadView.getRange(0, frameBytes * 8);

    // Compose: every frame-header seq-dependency <= the matching seq output.
    void wire(String frameIn, String seqOut) =>
        framep.input(frameIn).srcConnection! <= seqp.output(seqOut);
    wire('seq_reduced_still_picture', 'reduced_still_picture');
    wire('seq_frame_id_numbers_present', 'frame_id_numbers_present');
    wire('seq_delta_frame_id_length_minus2', 'delta_frame_id_length_minus2');
    wire(
      'seq_additional_frame_id_length_minus1',
      'additional_frame_id_length_minus1',
    );
    wire('seq_force_screen_content_tools', 'seq_force_screen_content_tools');
    wire('seq_force_integer_mv', 'seq_force_integer_mv');
    wire('seq_order_hint_bits', 'order_hint_bits');
    wire('seq_enable_order_hint', 'enable_order_hint');
    wire('seq_decoder_model_info_present', 'decoder_model_info_present');
    wire('seq_frame_width_bits_minus1', 'frame_width_bits_minus1');
    wire('seq_frame_height_bits_minus1', 'frame_height_bits_minus1');
    wire('seq_max_frame_width_minus1', 'max_frame_width_minus1');
    wire('seq_max_frame_height_minus1', 'max_frame_height_minus1');
    wire('seq_enable_superres', 'enable_superres');
    wire('seq_use_128x128_superblock', 'use_128x128_superblock');
    wire('seq_num_planes', 'num_planes');
    wire('seq_separate_uv_delta_q', 'separate_uv_delta_q');
    wire('seq_enable_cdef', 'enable_cdef');
    wire('seq_enable_restoration', 'enable_restoration');
    wire('seq_subsampling_x', 'subsampling_x');
    wire('seq_subsampling_y', 'subsampling_y');
    wire('seq_film_grain_params_present', 'film_grain_params_present');
    // show_existing_frame shown-slot metadata: this front end has no DPB yet,
    // so tie the shown frame_type / order_hint low (show_existing streams are
    // handled by the integrated decoder, not this OBU walker).
    framep.input('shown_frame_type').srcConnection! <= Const(0, width: 2);
    framep.input('shown_order_hint').srcConnection! <= Const(0, width: 8);
    // global_motion primary-ref models: no DPB in this walker, so tie to the
    // identity default (primary_ref_frame == NONE case). Non-identity chaining is
    // handled by the integrated decoder.
    framep.input('gm_ref_params').srcConnection! <= _identityGmRefParams();

    // tile group parser: driven by the parsed frame header's tile geometry.
    final tileGroupStart = Logic(name: 'tg_start');
    final numTiles = (framep.output('tile_cols') * framep.output('tile_rows'))
        .getRange(0, 8);
    tgp.input('clk').srcConnection! <= clk;
    tgp.input('reset').srcConnection! <= reset;
    tgp.input('start').srcConnection! <= tileGroupStart;
    tgp.input('bytes').srcConnection! <= payloadView.getRange(0, 64 * 8);
    tgp.input('sz').srcConnection! <= obuSize.getRange(0, cw);
    tgp.input('num_tiles').srcConnection! <= numTiles;
    tgp.input('tile_size_bytes').srcConnection! <=
        framep.output('tile_size_bytes');

    // cursor advance = header_len + obu_size.
    final advance = (headerLen.zeroExtend(cw) + obuSize.getRange(0, cw))
        .getRange(0, cw);
    final nextCursor = (cursor + advance).getRange(0, cw);
    final atEnd = nextCursor.gte(streamLen);

    // Parser start pulses are combinational on the sObu state.
    Combinational([
      seqStart < Const(0),
      frameStart < Const(0),
      tileGroupStart < Const(0),
      If(
        state.eq(st(sObu)),
        then: [
          If(obuType.eq(Const(1, width: 4)), then: [seqStart < Const(1)]),
          If(obuType.eq(Const(3, width: 4)), then: [frameStart < Const(1)]),
          If(obuType.eq(Const(4, width: 4)), then: [tileGroupStart < Const(1)]),
        ],
      ),
    ]);

    Sequential(clk, [
      If(
        reset,
        then: [
          state < st(sIdle),
          cursor < Const(0, width: cw),
          count < Const(0, width: 8),
          tgBase < Const(0, width: cw),
        ],
        orElse: [
          Case(state, [
            CaseItem(st(sIdle), [
              If(
                start,
                then: [
                  cursor < Const(0, width: cw),
                  count < Const(0, width: 8),
                  state < st(sObu),
                ],
              ),
            ]),
            CaseItem(st(sObu), [
              count < (count + Const(1, width: 8)).getRange(0, 8),
              If(
                obuType.eq(Const(1, width: 4)),
                then: [state < st(sSeqWait)],
                orElse: [
                  If(
                    obuType.eq(Const(3, width: 4)),
                    then: [state < st(sFrameWait)],
                    orElse: [
                      If(
                        obuType.eq(Const(4, width: 4)),
                        then: [
                          // tile group payload begins at cursor + header_len.
                          tgBase <
                              (cursor + headerLen.zeroExtend(cw)).getRange(
                                0,
                                cw,
                              ),
                          state < st(sTileGroupWait),
                        ],
                        orElse: [state < st(sAdvance)],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(st(sSeqWait), [
              If(seqp.output('done'), then: [state < st(sAdvance)]),
            ]),
            CaseItem(st(sFrameWait), [
              If(framep.output('done'), then: [state < st(sAdvance)]),
            ]),
            CaseItem(st(sTileGroupWait), [
              If(tgp.output('done'), then: [state < st(sAdvance)]),
            ]),
            CaseItem(st(sAdvance), [
              cursor < nextCursor,
              If(atEnd, then: [state < st(sDone)], orElse: [state < st(sObu)]),
            ]),
            CaseItem(st(sDone), [
              If(~start, then: [state < st(sIdle)]),
            ]),
          ]),
        ],
      ),
    ]);

    output('done') <= state.eq(st(sDone));
    output('obu_count') <= count;
    output('frame_unsupported') <= framep.output('unsupported');
    output('frame_type') <= framep.output('frame_type');
    output('show_frame') <= framep.output('show_frame');
    output('frame_width') <= framep.output('frame_width');
    output('frame_height') <= framep.output('frame_height');
    output('base_q_idx') <= framep.output('base_q_idx');
    output('tile_cols') <= framep.output('tile_cols');
    output('tile_rows') <= framep.output('tile_rows');
    output('tile_cols_log2') <= framep.output('tile_cols_log2');
    output('tile_rows_log2') <= framep.output('tile_rows_log2');
    output('coded_lossless') <= framep.output('coded_lossless');
    output('cdef_bits') <= framep.output('cdef_bits');
    output('tx_mode') <= framep.output('tx_mode');
    output('seq_profile') <= seqp.output('seq_profile');
    output('tile_count') <= tgp.output('tile_count');
    output('tile_offsets') <= tgp.output('tile_offsets');
    output('tile_sizes') <= tgp.output('tile_sizes');
    output('tile_group_base') <= tgBase;
  }
}

/// Identity global-motion ref_params vector (7 refs x [0,0,1<<16,0,0,1<<16]),
/// packed with param (ref*6+j) at bit (ref*6+j)*32.
Logic _identityGmRefParams() {
  const ident = [0, 0, 1 << 16, 0, 0, 1 << 16];
  var v = BigInt.zero;
  for (var ref = 0; ref < 7; ref++) {
    for (var j = 0; j < 6; j++) {
      v |= BigInt.from(ident[j] & 0xFFFFFFFF) << ((ref * 6 + j) * 32);
    }
  }
  return Const(v, width: 7 * 6 * 32);
}
