import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'cdef_params_parser.dart';
import 'loop_filter_params_parser.dart';
import 'lr_params_parser.dart';
import 'quant_params_parser.dart';

/// Harbor AV1 frame-header filter-configuration parse: a COMPOSITION of the
/// verified sub-parsers into one contiguous bitstream walk.
///
/// This is the integration pattern the full `uncompressed_header()` uses. It
/// chains `quantization_params()` -> `loop_filter_params()` -> `cdef_params()`
/// -> `lr_params()` back to back over one buffer, feeding each offset-0
/// sub-parser a bit-shifted window so it starts exactly where the previous one
/// finished. The window for offset `B` is built by shifting the big-endian
/// stream up by `B` and byte-reversing the top 128 bits back into the
/// LSB-first byte order the sub-parsers expect (`viewAt`).
///
/// `bytes` is a 64-byte buffer holding the four structures contiguously. Context
/// (num_planes, separate_uv_delta_q, coded_lossless, cdef/lr disable, chroma
/// subsampling, superblock size) is supplied as inputs. Outputs the key decoded
/// parameters of each stage plus the total `bits_consumed`. Combinational.
class HarborFilterConfigParser extends BridgeModule {
  HarborFilterConfigParser({String? name})
    : super('HarborFilterConfigParser', name: name ?? 'filter_config') {
    const bufBytes = 64;
    const totalBits = bufBytes * 8;

    createPort('bytes', PortDirection.input, width: totalBits);
    createPort('num_planes', PortDirection.input, width: 2);
    createPort('separate_uv_delta_q', PortDirection.input, width: 1);
    createPort('coded_lossless', PortDirection.input, width: 1);
    createPort('cdef_disabled', PortDirection.input, width: 1);
    createPort('lr_disabled', PortDirection.input, width: 1);
    createPort('subsampling_x', PortDirection.input, width: 1);
    createPort('subsampling_y', PortDirection.input, width: 1);
    createPort('use_128x128_superblock', PortDirection.input, width: 1);
    addOutput('base_q_idx', width: 8);
    addOutput('loop_filter_level_0', width: 6);
    addOutput('loop_filter_level_1', width: 6);
    addOutput('cdef_bits', width: 2);
    addOutput('cdef_damping', width: 4);
    addOutput('frame_restoration_type_0', width: 2);
    addOutput('uses_lr', width: 1);
    addOutput('bits_consumed', width: 10);

    final bytesIn = input('bytes');
    // Big-endian stream view of the whole buffer (byte 0 is the MSB).
    final gStream = [
      for (var i = 0; i < bufBytes; i++) bytesIn.getRange(i * 8, i * 8 + 8),
    ].concat();

    // 128-bit LSB-first window starting at global bit [B]: shift the stream up
    // by B, take the top 128 bits, then byte-reverse into LSB-first order.
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
    Logic off = Const(0, width: 10);

    // quantization_params.
    final quant = HarborQuantParamsParser(name: 'quant');
    addSubModule(quant);
    quant.input('bytes').srcConnection! <= viewAt(off);
    quant.input('num_planes').srcConnection! <= numPlanes;
    quant.input('separate_uv_delta_q').srcConnection! <=
        input('separate_uv_delta_q');
    off = (off + quant.output('bits_consumed').zeroExtend(10)).getRange(0, 10);

    // loop_filter_params.
    final lf = HarborLoopFilterParamsParser(name: 'lf');
    addSubModule(lf);
    lf.input('bytes').srcConnection! <= viewAt(off);
    lf.input('num_planes').srcConnection! <= numPlanes;
    lf.input('coded_lossless').srcConnection! <= input('coded_lossless');
    off = (off + lf.output('bits_consumed').zeroExtend(10)).getRange(0, 10);

    // cdef_params.
    final cdef = HarborCdefParamsParser(name: 'cdef');
    addSubModule(cdef);
    cdef.input('bytes').srcConnection! <= viewAt(off);
    cdef.input('num_planes').srcConnection! <= numPlanes;
    cdef.input('cdef_disabled').srcConnection! <= input('cdef_disabled');
    off = (off + cdef.output('bits_consumed').zeroExtend(10)).getRange(0, 10);

    // lr_params.
    final lr = HarborLrParamsParser(name: 'lr');
    addSubModule(lr);
    lr.input('bytes').srcConnection! <= viewAt(off);
    lr.input('num_planes').srcConnection! <= numPlanes;
    lr.input('subsampling_x').srcConnection! <= input('subsampling_x');
    lr.input('subsampling_y').srcConnection! <= input('subsampling_y');
    lr.input('use_128x128_superblock').srcConnection! <=
        input('use_128x128_superblock');
    lr.input('lr_disabled').srcConnection! <= input('lr_disabled');
    off = (off + lr.output('bits_consumed').zeroExtend(10)).getRange(0, 10);

    output('base_q_idx') <= quant.output('base_q_idx');
    output('loop_filter_level_0') <= lf.output('loop_filter_level_0');
    output('loop_filter_level_1') <= lf.output('loop_filter_level_1');
    output('cdef_bits') <= cdef.output('cdef_bits');
    output('cdef_damping') <= cdef.output('cdef_damping');
    output('frame_restoration_type_0') <= lr.output('frame_restoration_type_0');
    output('uses_lr') <= lr.output('uses_lr');
    output('bits_consumed') <= off;
  }
}
