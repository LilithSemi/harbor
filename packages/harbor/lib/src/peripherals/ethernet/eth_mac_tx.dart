import 'package:rohd/rohd.dart';

import 'eth_config.dart';
import 'eth_crc.dart';

/// Ethernet MAC transmit core. It runs byte wide on the TX clock.
///
/// The core moves one byte slot on each cycle with `tx_strobe` high.
/// `tx_data`, `tx_en` and `tx_er` hold between strobes. A frame on the wire
/// is 7 bytes of 0x55, 0xD5, the data, 0x00 pad up to 60 bytes, and the FCS.
/// The core starts a frame only after 12 idle byte slots.
///
/// The input gives one byte when `in_valid` and `in_ready` are high.
/// `in_ready` is high only on a strobe cycle that takes a data byte. The
/// source must keep `in_valid` high from the first byte to the byte with
/// `in_last`. If `in_valid` is low when a byte is necessary, the core ends
/// the frame with a 0x00 byte and marks it bad.
///
/// A bad frame, from `in_err` on a byte or from a missing byte, gets the
/// correct FCS with all bits inverted and `tx_er` on its last FCS byte.
/// `tx_frame_done` pulses after each frame and `tx_frame_err` pulses with
/// it for a bad frame.
class HarborEthMacTx extends Module {
  /// Configuration of the MAC that contains this core.
  final HarborEthernetConfig config;

  /// High when the core takes the byte on `in_data`.
  Logic get inReady => output('in_ready');

  /// Transmit data byte.
  Logic get txData => output('tx_data');

  /// Transmit enable.
  Logic get txEn => output('tx_en');

  /// Transmit error.
  Logic get txEr => output('tx_er');

  /// One cycle pulse after the last byte of a frame.
  Logic get txFrameDone => output('tx_frame_done');

  /// One cycle pulse with [txFrameDone] for a bad frame.
  Logic get txFrameErr => output('tx_frame_err');

  /// High from the first preamble byte to the end of the gap after a frame.
  Logic get busy => output('busy');

  static const _idle = 0;
  static const _preamble = 1;
  static const _data = 2;
  static const _pad = 3;
  static const _fcs = 4;
  static const _end = 5;
  static const _ifg = 6;

  /// Minimum frame length without the FCS.
  static const minFrameBytes = 60;

  /// Idle byte slots between two frames.
  static const ifgBytes = 12;

  HarborEthMacTx(
    Logic clk,
    Logic reset, {
    required this.config,
    required Logic txStrobe,
    required Logic inValid,
    required Logic inData,
    required Logic inLast,
    required Logic inErr,
    super.name = 'eth_mac_tx',
  }) : super(definitionName: 'HarborEthMacTx') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    txStrobe = addInput('tx_strobe', txStrobe);
    inValid = addInput('in_valid', inValid);
    inData = addInput('in_data', inData, width: 8);
    inLast = addInput('in_last', inLast);
    inErr = addInput('in_err', inErr);

    final inReady = addOutput('in_ready');
    final txData = addOutput('tx_data', width: 8);
    final txEn = addOutput('tx_en');
    final txEr = addOutput('tx_er');
    final done = addOutput('tx_frame_done');
    final frameErr = addOutput('tx_frame_err');
    final busyOut = addOutput('busy');

    final state = Logic(name: 'state', width: 3);
    // Preamble, data length up to 60, FCS byte or IFG slot.
    final cnt = Logic(name: 'cnt', width: 6);
    final crc = Logic(name: 'crc', width: 32);
    final err = Logic(name: 'err');

    Logic st(int s) => state.eq(Const(s, width: 3));
    Logic cntIs(int v) => cnt.eq(Const(v, width: 6));
    Conditional cntSet(int v) => cnt < Const(v, width: 6);
    Conditional go(int s) => state < Const(s, width: 3);
    Logic byteConst(int v) => Const(v, width: 8);

    busyOut <= ~st(_idle);
    final inDataState = st(_data);
    inReady <= inDataState & txStrobe;

    // A missing byte is a 0x00 byte that ends the frame.
    final byte = mux(inValid, inData, byteConst(0)).named('byte');
    final byteLast = ~inValid | inLast;
    final byteErr = ~inValid | inErr;
    final crcNext = harborEthCrcByte(
      crc,
      mux(inDataState, byte, byteConst(0)),
    ).named('crc_next');
    final minReached = cnt.gte(Const(minFrameBytes - 1, width: 6));
    final cntUp = cnt + Const(1, width: 6);

    Sequential(clk, [
      done < 0,
      frameErr < 0,
      If(
        txStrobe,
        then: [
          Case(
            state,
            [
              CaseItem(Const(_idle, width: 3), [
                If(
                  inValid,
                  then: [
                    txData < byteConst(0x55),
                    txEn < 1,
                    txEr < 0,
                    cntSet(1),
                    go(_preamble),
                  ],
                ),
              ]),
              CaseItem(Const(_preamble, width: 3), [
                If(
                  cntIs(7),
                  then: [
                    txData < byteConst(0xD5),
                    cntSet(0),
                    crc < Const(0xFFFFFFFF, width: 32),
                    err < 0,
                    go(_data),
                  ],
                  orElse: [txData < byteConst(0x55), cnt < cntUp],
                ),
              ]),
              CaseItem(Const(_data, width: 3), [
                txData < byte,
                crc < crcNext,
                err < err | byteErr,
                If.block([
                  Iff(byteLast & minReached, [cntSet(0), go(_fcs)]),
                  Iff(byteLast, [cnt < cntUp, go(_pad)]),
                  Iff(~cntIs(minFrameBytes), [cnt < cntUp]),
                ]),
              ]),
              CaseItem(Const(_pad, width: 3), [
                txData < byteConst(0),
                crc < crcNext,
                If(
                  minReached,
                  then: [cntSet(0), go(_fcs)],
                  orElse: [cnt < cntUp],
                ),
              ]),
              CaseItem(Const(_fcs, width: 3), [
                txData < mux(err, crc.slice(7, 0), ~crc.slice(7, 0)),
                txEr < err & cntIs(3),
                crc < (crc >>> 8),
                cnt < cntUp,
                If(cntIs(3), then: [go(_end)]),
              ]),
              CaseItem(Const(_end, width: 3), [
                txData < byteConst(0),
                txEn < 0,
                txEr < 0,
                done < 1,
                frameErr < err,
                cntSet(0),
                go(_ifg),
              ]),
              CaseItem(Const(_ifg, width: 3), [
                cnt < cntUp,
                // The slot of the end state is the first idle slot.
                If(cntIs(ifgBytes - 2), then: [go(_idle)]),
              ]),
            ],
            defaultItem: [go(_idle)],
          ),
        ],
      ),
    ], reset: reset);
  }
}
