import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'obu_parser.dart';
import 'seq_header_parser.dart';

/// Harbor AV1 OBU stream walker: the integrated front end.
///
/// This is the first piece that actually RUNS a bitstream end to end rather than
/// parsing one field in isolation. Given a byte buffer holding a small OBU
/// stream, it walks OBU to OBU (one per cycle): a [HarborObuParser] decodes each
/// header at the running byte cursor, and when the OBU is a sequence header
/// (type 1) a [HarborSeqHeaderParser] reads the payload and the walker latches
/// the stream parameters (profile, frame width/height). The cursor advances by
/// `header_len + obu_size` until it reaches `stream_len`, then `done` asserts.
///
/// Both sub-parsers are combinational and are fed a view of the buffer shifted
/// to the cursor (a byte-granular barrel shift), so each cycle re-parses the OBU
/// the cursor points at. `bytes` packs the buffer LSB-first (byte 0 at bit 0).
/// `stream_len` is the buffer length in bytes. Pulse `start` to begin.
///
/// This integrates OBU framing + sequence-header parsing. Routing frame headers
/// and tile groups into the decode engine is the next layer.
class HarborObuStreamWalker extends BridgeModule {
  HarborObuStreamWalker({int bufBytes = 48, String? name})
    : super('HarborObuStreamWalker', name: name ?? 'obu_walker') {
    final totalBits = bufBytes * 8;
    const cw = 12; // cursor / length width (bytes)

    createPort('clk', PortDirection.input, width: 1);
    createPort('reset', PortDirection.input, width: 1);
    createPort('bytes', PortDirection.input, width: totalBits);
    createPort('stream_len', PortDirection.input, width: cw);
    createPort('start', PortDirection.input, width: 1);
    addOutput('seq_profile', width: 3);
    addOutput('frame_width', width: 32);
    addOutput('frame_height', width: 32);
    addOutput('obu_count', width: 8);
    addOutput('last_obu_type', width: 4);
    addOutput('done', width: 1);

    final clk = input('clk');
    final reset = input('reset');
    final bytesIn = input('bytes');
    final streamLen = input('stream_len');
    final start = input('start');

    // Registers.
    final state = Logic(name: 'state', width: 2);
    final cursor = Logic(name: 'cursor', width: cw);
    final count = Logic(name: 'obu_count_r', width: 8);
    final profileReg = Logic(name: 'profile_r', width: 3);
    final widthReg = Logic(name: 'width_r', width: 32);
    final heightReg = Logic(name: 'height_r', width: 32);
    final lastTypeReg = Logic(name: 'last_type_r', width: 4);

    const sIdle = 0, sWalk = 1, sDone = 2;

    // Byte-granular view of the buffer at the cursor: bytes >> (cursor * 8).
    final cursorBits = [cursor, Const(0, width: 3)].concat(); // cursor * 8
    final view = (bytesIn >>> cursorBits.zeroExtend(totalBits))
        .getRange(0, totalBits)
        .named('view');

    final obu = HarborObuParser(name: 'obu');
    addSubModule(obu);
    obu.input('bytes').srcConnection! <= view.getRange(0, 80);

    final obuType = obu.output('obu_type');
    final headerLen = obu.output('header_len');
    final obuSize = obu.output('obu_size');
    final isSeq = obuType.eq(Const(1, width: 4));

    // Sequence-header payload view: shift past the OBU header.
    final hdrBits = [headerLen, Const(0, width: 3)].concat(); // header_len * 8
    final seqView = (view >>> hdrBits.zeroExtend(totalBits)).getRange(0, 128);
    final seq = HarborSeqHeaderParser(name: 'seq');
    addSubModule(seq);
    seq.input('bytes').srcConnection! <= seqView;

    // Bytes this OBU spans = header_len + obu_size.
    final advance = (headerLen.zeroExtend(cw) + obuSize.getRange(0, cw))
        .getRange(0, cw);
    final nextCursor = (cursor + advance).getRange(0, cw);
    final atEnd = nextCursor.gte(streamLen);

    Sequential(clk, [
      If(
        reset,
        then: [
          state < Const(sIdle, width: 2),
          cursor < Const(0, width: cw),
          count < Const(0, width: 8),
          profileReg < Const(0, width: 3),
          widthReg < Const(0, width: 32),
          heightReg < Const(0, width: 32),
          lastTypeReg < Const(0, width: 4),
        ],
        orElse: [
          If(
            state.eq(Const(sIdle, width: 2)),
            then: [
              If(
                start,
                then: [
                  cursor < Const(0, width: cw),
                  count < Const(0, width: 8),
                  state < Const(sWalk, width: 2),
                ],
              ),
            ],
            orElse: [
              If(
                state.eq(Const(sWalk, width: 2)),
                then: [
                  lastTypeReg < obuType,
                  count < (count + Const(1, width: 8)).getRange(0, 8),
                  cursor < nextCursor,
                  If(
                    isSeq,
                    then: [
                      profileReg < seq.output('seq_profile'),
                      widthReg < seq.output('frame_width'),
                      heightReg < seq.output('frame_height'),
                    ],
                  ),
                  If(atEnd, then: [state < Const(sDone, width: 2)]),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    output('seq_profile') <= profileReg;
    output('frame_width') <= widthReg;
    output('frame_height') <= heightReg;
    output('obu_count') <= count;
    output('last_obu_type') <= lastTypeReg;
    output('done') <= state.eq(Const(sDone, width: 2));
  }
}
