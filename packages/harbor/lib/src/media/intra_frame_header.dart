import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'bit_reader.dart';
import 'cdef_params_parser.dart';
import 'delta_params_parser.dart';
import 'frame_size_parser.dart';
import 'loop_filter_params_parser.dart';
import 'lr_params_parser.dart';
import 'quant_params_parser.dart';
import 'render_size_parser.dart';
import 'tile_info_parser.dart';
import 'tx_mode_parser.dart';

/// Harbor AV1 intra (KEY_FRAME) frame-header parser: the header-layer capstone.
///
/// Composes the verified sub-parsers into one contiguous `uncompressed_header()`
/// walk for an intra frame, from `frame_size()` through `read_tx_mode()`, in AV1
/// order: frame_size -> render_size -> tile_info -> quantization_params ->
/// segmentation_enabled (inline, decoded disabled here) -> delta_q/lf_params ->
/// loop_filter_params -> cdef_params -> lr_params -> read_tx_mode. Each
/// offset-0 sub-parser is fed a 128-bit window shifted to the running bit offset
/// (`viewAt`), and the offset advances by each stage's `bits_consumed`.
///
/// Sequence-header context (frame-size bit widths, maxima, superres, plane
/// count, subsampling, superblock size, tool enables, lossless/intrabc) is
/// supplied as inputs. `cdef_disabled`/`lr_disabled` are derived from
/// lossless/intrabc/enable flags. Outputs the decoded per-frame parameters and
/// the total `bits_consumed`. Combinational.
///
/// SCOPE: assumes the leading uncompressed_header fields are already consumed
/// (start at frame_size) and segmentation is disabled (a single inline bit).
/// The full segmentation table and the inter-frame fields are composed the
/// same way when needed.
class HarborIntraFrameHeader extends BridgeModule {
  HarborIntraFrameHeader({String? name})
    : super('HarborIntraFrameHeader', name: name ?? 'intra_frame_header') {
    const bufBytes = 128;
    const totalBits = bufBytes * 8;

    createPort('bytes', PortDirection.input, width: totalBits);
    // Sequence-header context.
    createPort('frame_size_override', PortDirection.input, width: 1);
    createPort('frame_width_bits_minus_1', PortDirection.input, width: 4);
    createPort('frame_height_bits_minus_1', PortDirection.input, width: 4);
    createPort('max_frame_width_minus_1', PortDirection.input, width: 16);
    createPort('max_frame_height_minus_1', PortDirection.input, width: 16);
    createPort('enable_superres', PortDirection.input, width: 1);
    createPort('num_planes', PortDirection.input, width: 2);
    createPort('separate_uv_delta_q', PortDirection.input, width: 1);
    createPort('subsampling_x', PortDirection.input, width: 1);
    createPort('subsampling_y', PortDirection.input, width: 1);
    createPort('use_128x128_superblock', PortDirection.input, width: 1);
    createPort('enable_cdef', PortDirection.input, width: 1);
    createPort('enable_restoration', PortDirection.input, width: 1);
    createPort('coded_lossless', PortDirection.input, width: 1);
    createPort('allow_intrabc', PortDirection.input, width: 1);

    addOutput('frame_width', width: 17);
    addOutput('frame_height', width: 17);
    addOutput('mi_cols', width: 16);
    addOutput('mi_rows', width: 16);
    addOutput('render_width', width: 17);
    addOutput('render_height', width: 17);
    addOutput('tile_cols', width: 7);
    addOutput('tile_rows', width: 7);
    addOutput('base_q_idx', width: 8);
    addOutput('segmentation_enabled', width: 1);
    addOutput('delta_q_present', width: 1);
    addOutput('loop_filter_level_0', width: 6);
    addOutput('loop_filter_level_1', width: 6);
    addOutput('cdef_bits', width: 2);
    addOutput('cdef_damping', width: 4);
    addOutput('frame_restoration_type_0', width: 2);
    addOutput('uses_lr', width: 1);
    addOutput('tx_mode', width: 2);
    addOutput('bits_consumed', width: 11);

    final bytesIn = input('bytes');
    final gStream = [
      for (var i = 0; i < bufBytes; i++) bytesIn.getRange(i * 8, i * 8 + 8),
    ].concat();

    Logic viewAt(Logic b) {
      final shifted = (gStream << b.zeroExtend(totalBits)).getRange(
        totalBits - 128,
        totalBits,
      );
      return [
        for (var i = 0; i < 16; i++) shifted.getRange(i * 8, i * 8 + 8),
      ].concat();
    }

    final numPlanes = input('num_planes');
    final lossless = input('coded_lossless');
    final intrabc = input('allow_intrabc');
    final cdefDisabled = lossless | intrabc | ~input('enable_cdef');
    final lrDisabled = lossless | intrabc | ~input('enable_restoration');

    Logic off = Const(0, width: 11);
    Logic adv(Logic consumed) =>
        (off + consumed.zeroExtend(11)).getRange(0, 11);

    // frame_size().
    final fs = HarborFrameSizeParser(name: 'frame_size');
    addSubModule(fs);
    fs.input('bytes').srcConnection! <= viewAt(off);
    fs.input('frame_size_override').srcConnection! <=
        input('frame_size_override');
    fs.input('frame_width_bits_minus_1').srcConnection! <=
        input('frame_width_bits_minus_1');
    fs.input('frame_height_bits_minus_1').srcConnection! <=
        input('frame_height_bits_minus_1');
    fs.input('max_frame_width_minus_1').srcConnection! <=
        input('max_frame_width_minus_1');
    fs.input('max_frame_height_minus_1').srcConnection! <=
        input('max_frame_height_minus_1');
    fs.input('enable_superres').srcConnection! <= input('enable_superres');
    off = adv(fs.output('bits_consumed'));

    // render_size().
    final rs = HarborRenderSizeParser(name: 'render_size');
    addSubModule(rs);
    rs.input('bytes').srcConnection! <= viewAt(off);
    rs.input('upscaled_width').srcConnection! <= fs.output('upscaled_width');
    rs.input('frame_height').srcConnection! <= fs.output('frame_height');
    off = adv(rs.output('bits_consumed'));

    // tile_info().
    final ti = HarborTileInfoParser(name: 'tile_info');
    addSubModule(ti);
    ti.input('bytes').srcConnection! <= viewAt(off);
    ti.input('mi_cols').srcConnection! <= fs.output('mi_cols');
    ti.input('mi_rows').srcConnection! <= fs.output('mi_rows');
    ti.input('use_128x128_superblock').srcConnection! <=
        input('use_128x128_superblock');
    off = adv(ti.output('bits_consumed'));

    // quantization_params().
    final q = HarborQuantParamsParser(name: 'quant');
    addSubModule(q);
    q.input('bytes').srcConnection! <= viewAt(off);
    q.input('num_planes').srcConnection! <= numPlanes;
    q.input('separate_uv_delta_q').srcConnection! <=
        input('separate_uv_delta_q');
    off = adv(q.output('bits_consumed'));

    // segmentation_enabled (inline, decoded disabled in this scope = 1 bit).
    final seg = HarborBitReader(name: 'seg_en');
    addSubModule(seg);
    seg.input('bytes').srcConnection! <= viewAt(off);
    seg.input('bit_offset').srcConnection! <= Const(0, width: 8);
    seg.input('n').srcConnection! <= Const(1, width: 6);
    final segEnabled = seg.output('value').getRange(0, 1);
    off = adv(Const(1, width: 11));

    // delta_q_params() + delta_lf_params().
    final dp = HarborDeltaParamsParser(name: 'delta');
    addSubModule(dp);
    dp.input('bytes').srcConnection! <= viewAt(off);
    dp.input('base_q_idx').srcConnection! <= q.output('base_q_idx');
    dp.input('allow_intrabc').srcConnection! <= intrabc;
    off = adv(dp.output('bits_consumed'));

    // loop_filter_params().
    final lf = HarborLoopFilterParamsParser(name: 'lf');
    addSubModule(lf);
    lf.input('bytes').srcConnection! <= viewAt(off);
    lf.input('num_planes').srcConnection! <= numPlanes;
    lf.input('coded_lossless').srcConnection! <= lossless;
    off = adv(lf.output('bits_consumed'));

    // cdef_params().
    final cdef = HarborCdefParamsParser(name: 'cdef');
    addSubModule(cdef);
    cdef.input('bytes').srcConnection! <= viewAt(off);
    cdef.input('num_planes').srcConnection! <= numPlanes;
    cdef.input('cdef_disabled').srcConnection! <= cdefDisabled;
    off = adv(cdef.output('bits_consumed'));

    // lr_params().
    final lr = HarborLrParamsParser(name: 'lr');
    addSubModule(lr);
    lr.input('bytes').srcConnection! <= viewAt(off);
    lr.input('num_planes').srcConnection! <= numPlanes;
    lr.input('subsampling_x').srcConnection! <= input('subsampling_x');
    lr.input('subsampling_y').srcConnection! <= input('subsampling_y');
    lr.input('use_128x128_superblock').srcConnection! <=
        input('use_128x128_superblock');
    lr.input('lr_disabled').srcConnection! <= lrDisabled;
    off = adv(lr.output('bits_consumed'));

    // read_tx_mode().
    final tx = HarborTxModeParser(name: 'tx_mode');
    addSubModule(tx);
    tx.input('bytes').srcConnection! <= viewAt(off);
    tx.input('coded_lossless').srcConnection! <= lossless;
    off = adv(tx.output('bits_consumed'));

    output('frame_width') <= fs.output('frame_width');
    output('frame_height') <= fs.output('frame_height');
    output('mi_cols') <= fs.output('mi_cols');
    output('mi_rows') <= fs.output('mi_rows');
    output('render_width') <= rs.output('render_width');
    output('render_height') <= rs.output('render_height');
    output('tile_cols') <= ti.output('tile_cols');
    output('tile_rows') <= ti.output('tile_rows');
    output('base_q_idx') <= q.output('base_q_idx');
    output('segmentation_enabled') <= segEnabled;
    output('delta_q_present') <= dp.output('delta_q_present');
    output('loop_filter_level_0') <= lf.output('loop_filter_level_0');
    output('loop_filter_level_1') <= lf.output('loop_filter_level_1');
    output('cdef_bits') <= cdef.output('cdef_bits');
    output('cdef_damping') <= cdef.output('cdef_damping');
    output('frame_restoration_type_0') <= lr.output('frame_restoration_type_0');
    output('uses_lr') <= lr.output('uses_lr');
    output('tx_mode') <= tx.output('tx_mode');
    output('bits_consumed') <= off;
  }
}
