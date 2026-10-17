import 'package:rohd/rohd.dart';

import '../../clock/cdc.dart';
import '../../soc/target.dart';
import '../bram.dart';

/// Sys clock cycles with no PHY clock toggle that set `clk_lost`.
const harborEthClkLostCycles = 1 << 12;

/// Status bit on a last RX word: a clock loss cut the frame.
const harborEthRxStatusCut = 1 << 6;

Logic _gray(Logic b) => b ^ (b >>> 1);

Logic _grayToBin(Logic g) {
  final n = g.width;
  final bits = List<Logic?>.filled(n, null);
  bits[n - 1] = g[n - 1];
  for (var i = n - 2; i >= 0; i--) {
    bits[i] = bits[i + 1]! ^ g[i];
  }
  return bits.reversed.map((b) => b!).toList().swizzle();
}

Logic _byteOf(Logic word, Logic idx) => mux(
  idx[1],
  mux(idx[0], word.getRange(24, 32), word.getRange(16, 24)),
  mux(idx[0], word.getRange(8, 16), word.getRange(0, 8)),
);

/// Dual clock word storage with a registered read, for a target with no
/// block RAM.
///
/// The emitted SystemVerilog is a plain memory array. The simulation model
/// keeps the words in a Dart list, because a flop array of this size makes
/// each clock edge slow.
class _FrameStore extends Module with SystemVerilog {
  final int width;
  final int depth;

  _FrameStore({
    required Logic wrClk,
    required Logic wrEn,
    required Logic wrAddr,
    required Logic wrData,
    required Logic rdClk,
    required Logic rdReset,
    required Logic rdEn,
    required Logic rdAddr,
    required this.depth,
  }) : width = wrData.width,
       super(
         name: 'storage',
         definitionName: 'HarborEthFrameStore_${wrData.width}x$depth',
       ) {
    wrClk = addInput('wr_clk', wrClk);
    wrEn = addInput('wr_en', wrEn);
    wrAddr = addInput('wr_addr', wrAddr, width: wrAddr.width);
    wrData = addInput('wr_data', wrData, width: width);
    rdClk = addInput('rd_clk', rdClk);
    rdReset = addInput('rd_reset', rdReset);
    rdEn = addInput('rd_en', rdEn);
    rdAddr = addInput('rd_addr', rdAddr, width: rdAddr.width);
    final rd = addOutput('rd_data', width: width)..put(0);

    final words = List<LogicValue>.filled(
      depth,
      LogicValue.filled(width, LogicValue.x),
    );
    wrClk.posedge.listen((_) {
      if (wrEn.previousValue != LogicValue.one) return;
      final a = wrAddr.previousValue!;
      if (a.isValid) words[a.toInt()] = wrData.previousValue!;
    });
    rdClk.posedge.listen((_) {
      if (rdReset.previousValue == LogicValue.one) {
        rd.put(0);
      } else if (rdEn.previousValue == LogicValue.one) {
        final a = rdAddr.previousValue!;
        rd.put(
          a.isValid ? words[a.toInt()] : LogicValue.filled(width, LogicValue.x),
        );
      }
    });
  }

  Logic get rdData => output('rd_data');

  @override
  String? definitionVerilog(String definitionType) {
    final aw = input('wr_addr').width;
    return '''
module $definitionType (
  input logic wr_clk,
  input logic wr_en,
  input logic [${aw - 1}:0] wr_addr,
  input logic [${width - 1}:0] wr_data,
  input logic rd_clk,
  input logic rd_reset,
  input logic rd_en,
  input logic [${aw - 1}:0] rd_addr,
  output logic [${width - 1}:0] rd_data
);
  logic [${width - 1}:0] mem [0:${depth - 1}];
  always_ff @(posedge wr_clk) begin
    if (wr_en) mem[wr_addr] <= wr_data;
  end
  always_ff @(posedge rd_clk) begin
    if (rd_reset) rd_data <= ${width}'d0;
    else if (rd_en) rd_data <= mem[rd_addr];
  end
endmodule''';
  }
}

/// Dual clock word storage with a registered read. It is block RAM when
/// [bram] is set.
Logic _store({
  required Logic wrClk,
  required Logic wrEn,
  required Logic wrAddr,
  required Logic wrData,
  required Logic rdClk,
  required Logic rdReset,
  required Logic rdEn,
  required Logic rdAddr,
  required int depth,
  required HarborBlockRam? bram,
}) {
  if (bram != null) {
    return HarborDualClockBram(
      wrClk: wrClk,
      wrEn: wrEn,
      wrAddr: wrAddr,
      wrData: wrData,
      rdClk: rdClk,
      rdReset: rdReset,
      rdEn: rdEn,
      rdAddr: rdAddr,
      width: wrData.width,
      depth: depth,
      primitive: bram,
      name: 'storage',
    ).rdData;
  }
  return _FrameStore(
    wrClk: wrClk,
    wrEn: wrEn,
    wrAddr: wrAddr,
    wrData: wrData,
    rdClk: rdClk,
    rdReset: rdReset,
    rdEn: rdEn,
    rdAddr: rdAddr,
    depth: depth,
  ).rdData;
}

/// Watchdog on the sys clock for a PHY clock.
///
/// The top bit of a 4-bit counter on the PHY clock changes once for each 8
/// PHY cycles. The sys side syncs it and counts sys cycles with no change.
/// After [harborEthClkLostCycles] cycles `lost` goes high. It goes low again
/// at the next change. `sticky` stays high until `clear`.
///
/// The division keeps the change rate far below the sys clock rate. Thus a
/// PHY clock at 2n times sys from one source cannot alias to no change. At
/// 2.5 MHz there is a change each 3.2 us, and 2^12 cycles of a 400 MHz sys
/// clock are 10 us.
({Logic lost, Logic sticky}) _clockWatch(
  Logic sysClk,
  Logic sysReset,
  Logic phyClk,
  Logic phyReset,
  Logic clear,
) {
  final div = Logic(name: 'phy_div', width: 4);
  Sequential(phyClk, [div < div + 1], reset: phyReset);
  final tog = div[3];

  final s0 = Logic(name: 'phy_tog_s0');
  final s1 = Logic(name: 'phy_tog_s1');
  final s2 = Logic(name: 'phy_tog_s2');
  const cw = 12;
  final cnt = Logic(name: 'watch_cnt', width: cw);
  final lost = Logic(name: 'phy_clk_lost');
  final sticky = Logic(name: 'phy_clk_lost_sticky');
  final edge = (s1 ^ s2).named('phy_tog_edge');
  final max = cnt.eq(harborEthClkLostCycles - 1).named('watch_max');
  Sequential(sysClk, [
    s0 < tog,
    s1 < s0,
    s2 < s1,
    If(
      edge,
      then: [cnt < Const(0, width: cw)],
      orElse: [
        If(~max, then: [cnt < cnt + 1]),
      ],
    ),
    lost < ~edge & (lost | max),
    sticky < lost | (sticky & ~clear),
  ], reset: sysReset);
  return (lost: lost, sticky: sticky);
}

void _checkBytes(int bytes) {
  if (bytes < 64 || bytes & (bytes - 1) != 0) {
    throw ArgumentError.value(bytes, 'bytes', 'must be a power of two >= 64');
  }
}

/// TX store and forward FIFO from the sys clock to the TX clock.
///
/// The write side takes 32-bit words on the sys clock. Byte 0 of a word goes
/// on the wire first. `w_bytes` on the word with `w_last` gives the valid
/// bytes, 0 means 4. `w_ready` is low while there is no space for one word.
///
/// A frame is released only when its last word is written. A frame count
/// crosses to the TX clock in gray code, and the read side starts a frame
/// only when the count says it is complete. So `in_valid` stays high from
/// the first byte to the last. A frame with `w_err` on any word never
/// releases. Its last word moves the write pointer back to the frame start.
/// A frame larger than [bytes] cannot be written, the writer must check the
/// length first.
///
/// The read side matches the input of HarborEthMacTx. `in_err` is always low.
///
/// When the TX clock stops, `clk_lost` goes high and stays high until
/// `clk_lost_clear`. The FIFO resets on both sides and the frames in it are
/// lost. While the clock is lost, `w_ready` is high and the FIFO drops all
/// words. A frame that the loss cut is dropped up to its last word, so the
/// first frame that starts after recovery is written. `w_drop` is high when
/// the FIFO drops the word on `w_data` for this reason. On the word with
/// `w_last` it tells that the frame did not go into the FIFO.
class HarborEthTxFrameFifo extends Module {
  /// Size of the storage in bytes.
  final int bytes;

  /// Target that gives the block RAM, or null for flops.
  final HarborDeviceTarget? target;

  /// Whether the storage is block RAM.
  bool get usesBlockRam => target?.blockRam != null;

  Logic get wReady => output('w_ready');
  Logic get inValid => output('in_valid');
  Logic get inData => output('in_data');
  Logic get inLast => output('in_last');
  Logic get inErr => output('in_err');

  /// TX clock lost, sticky until `clk_lost_clear`. Sys clock.
  Logic get clkLost => output('clk_lost');

  /// High when a clock loss or a reset drops the word on `w_data`.
  Logic get wDrop => output('w_drop');

  /// Free words on the sys side, at most one less than the size. The read
  /// pointer arrives late, so the value can be lower than the real space,
  /// never higher. It is the size less one when the FIFO is empty.
  Logic get wFree => output('w_free');

  /// TX clock: a whole frame waits, or a word waits for the MAC.
  Logic get outBusy => output('out_busy');

  HarborEthTxFrameFifo(
    Logic sysClk,
    Logic sysReset,
    Logic txClk,
    Logic txReset, {
    required this.bytes,
    required Logic wValid,
    required Logic wData,
    required Logic wBytes,
    required Logic wLast,
    required Logic wErr,
    required Logic inReady,
    Logic? clkLostClear,
    this.target,
    super.name = 'eth_tx_frame_fifo',
  }) : super(
         definitionName:
             'HarborEthTxFrameFifo_$bytes'
             '${target?.blockRam == null ? '' : '_${target!.blockRam!.name}'}',
       ) {
    _checkBytes(bytes);
    sysClk = addInput('sys_clk', sysClk);
    sysReset = addInput('sys_reset', sysReset);
    txClk = addInput('tx_clk', txClk);
    txReset = addInput('tx_reset', txReset);
    wValid = addInput('w_valid', wValid);
    wData = addInput('w_data', wData, width: 32);
    wBytes = addInput('w_bytes', wBytes, width: 2);
    wLast = addInput('w_last', wLast);
    wErr = addInput('w_err', wErr);
    inReady = addInput('in_ready', inReady);
    final clear = addInput('clk_lost_clear', clkLostClear ?? Const(0));

    final wReady = addOutput('w_ready');
    final inValid = addOutput('in_valid');
    final inData = addOutput('in_data', width: 8);
    final inLast = addOutput('in_last');
    addOutput('in_err') <= Const(0);
    final clkLost = addOutput('clk_lost');
    final wDrop = addOutput('w_drop');

    final words = bytes ~/ 4;
    final aw = words.bitLength - 1;
    final pw = aw + 1;
    final wFree = addOutput('w_free', width: pw);
    final outBusy = addOutput('out_busy');

    final watch = _clockWatch(sysClk, sysReset, txClk, txReset, clear);
    clkLost <= watch.sticky;

    final sysJoin = harborCdcJoinReset(
      sysClk,
      sysReset | watch.lost,
      txReset,
      name: 'sys_join_reset',
    );
    final sysRst = harborCdcSyncReset(
      sysClk,
      sysReset,
      sysJoin,
      name: 'sys_rst',
    );
    final txRst = harborCdcJoinReset(
      txClk,
      txReset,
      sysReset | watch.lost,
      name: 'tx_rst',
    );

    // Sys side.
    final wPtr = Logic(name: 'w_ptr', width: pw);
    final wStart = Logic(name: 'w_start', width: pw);
    final wFrames = Logic(name: 'w_frames', width: pw);
    final wFramesGray = Logic(name: 'w_frames_gray', width: pw);
    final errSeen = Logic(name: 'w_err_seen');
    final wMid = Logic(name: 'w_mid');
    final discard = Logic(name: 'w_discard');
    final fPtrGray = Logic(name: 'f_ptr_gray', width: pw);
    final fGrayS0 = Logic(name: 'f_gray_s0', width: pw);
    final fGrayS1 = Logic(name: 'f_gray_s1', width: pw);

    // The read pointer, `w_full` and `w_free` are registered, so no wide logic
    // follows the synchronizer or the write. The fill level comes from the
    // write pointer of the cycle before, so it can be one word low. Thus
    // the FIFO is full one word early, and `w_free` keeps one word back.
    // Two writes in a row can fill the FIFO to the size, so `w_free` stops
    // at 0.
    final fBin = Logic(name: 'f_ptr_bin', width: pw);
    final freeR = Logic(name: 'w_free_r', width: pw);
    final full = Logic(name: 'w_full');
    // `w_cut` is its own flop, equal to `sys_rst | w_discard` on each cycle,
    // so the DMA handshake does not use the reset synchronizer output. Its
    // first stage takes the join reset like the first stage of `sys_rst`.
    final cutA = Logic(name: 'w_cut_a');
    final cut = Logic(name: 'w_cut');
    wReady <= cut | ~full;
    wDrop <= cut;
    wFree <= freeR;
    final accept = (wValid & wReady).named('w_accept');
    final store = (accept & ~cut).named('w_store');
    final bad = (errSeen | wErr).named('w_bad');
    final commit = (store & wLast & ~bad).named('w_commit');
    final drop = (store & wLast & bad).named('w_bad_drop');
    final wPtrNext = mux(
      drop,
      wStart,
      mux(store, wPtr + 1, wPtr),
    ).named('w_ptr_next');
    final usedNow = (wPtr - fBin).named('w_used_now');

    Sequential(
      sysClk,
      [
        fBin < _grayToBin(fGrayS1),
        full < usedNow.gte(words - 1),
        freeR <
            mux(
              usedNow.gte(words - 1),
              Const(0, width: pw),
              Const(words - 1, width: pw) - usedNow,
            ),
      ],
      reset: sysRst,
      resetValues: {freeR: Const(words - 1, width: pw)},
    );

    Sequential(sysClk, [
      fGrayS0 < fPtrGray,
      fGrayS1 < fGrayS0,
      wPtr < wPtrNext,
      If(store, then: [errSeen < ~wLast & bad]),
      If(
        commit,
        then: [
          wStart < wPtr + 1,
          wFrames < wFrames + 1,
          wFramesGray < _gray(wFrames + 1),
        ],
      ),
    ], reset: sysRst);

    // A frame that a reset cut is dropped up to its last word.
    final discardNext = (cut & mux(accept, ~wLast, wMid)).named(
      'w_discard_next',
    );
    Sequential(sysClk, [
      If(accept, then: [wMid < ~wLast]),
      discard < discardNext,
    ], reset: sysReset);
    Sequential(
      sysClk,
      [cutA < sysJoin, cut < cutA | discardNext],
      reset: sysReset,
      resetValues: {cutA: Const(1), cut: Const(1)},
    );

    // TX side.
    final fPtr = Logic(name: 'f_ptr', width: pw);
    final doneFrames = Logic(name: 'done_frames', width: pw);
    final framesS0 = Logic(name: 'frames_s0', width: pw);
    final framesS1 = Logic(name: 'frames_s1', width: pw);
    final ramValid = Logic(name: 'ram_valid');
    final cur = Logic(name: 'cur', width: 35);
    final curValid = Logic(name: 'cur_valid');
    final bi = Logic(name: 'byte_idx', width: 2);

    final fetch = Logic(name: 'fetch');
    final ram = _store(
      wrClk: sysClk,
      wrEn: store,
      wrAddr: wPtr.getRange(0, aw),
      wrData: [wLast, mux(wLast, wBytes, Const(0, width: 2)), wData].swizzle(),
      rdClk: txClk,
      rdReset: txRst,
      rdEn: fetch,
      rdAddr: fPtr.getRange(0, aw),
      depth: words,
      bram: target?.blockRam,
    );
    final ramLast = ram[34];

    // The RAM is read only while its output register is empty. Then the
    // number of fetched frames cannot change from one cycle to the next, so
    // a registered `frame_avail` is safe, and the read enable comes from
    // flops only.
    final framesBin = Logic(name: 'frames_bin', width: pw);
    final availR = Logic(name: 'frame_avail_r');
    final fetched = (doneFrames + (ramValid & ramLast).zeroExtend(pw)).named(
      'fetched_frames',
    );
    final avail = (~fetched.eq(framesBin)).named('frame_avail');
    final curLast = cur[34];
    final curEnd = mux(
      curLast,
      cur.getRange(32, 34) - 1,
      Const(3, width: 2),
    ).named('cur_end');
    final take = (curValid & inReady).named('take');
    final wordDone = (take & bi.eq(curEnd)).named('word_done');
    final load = (ramValid & (~curValid | wordDone)).named('load');
    fetch <= availR & ~ramValid;

    Sequential(txClk, [
      framesS0 < wFramesGray,
      framesS1 < framesS0,
      framesBin < _grayToBin(framesS1),
      availR < avail,
      If(fetch, then: [fPtr < fPtr + 1, fPtrGray < _gray(fPtr + 1)]),
      ramValid < fetch | (ramValid & ~load),
      If(
        load,
        then: [
          cur < ram,
          curValid < Const(1),
          bi < Const(0, width: 2),
          If(ramLast, then: [doneFrames < doneFrames + 1]),
        ],
        orElse: [
          If(
            wordDone,
            then: [curValid < Const(0), bi < Const(0, width: 2)],
            orElse: [
              If(take, then: [bi < bi + 1]),
            ],
          ),
        ],
      ),
    ], reset: txRst);

    inValid <= curValid;
    outBusy <= availR | ramValid | curValid;
    inData <= _byteOf(cur.getRange(0, 32), bi);
    inLast <= curValid & curLast & bi.eq(curEnd);
  }
}

/// RX frame FIFO from the RX clock to the sys clock.
///
/// The write side takes the output of HarborEthMacRx. The FIFO packs the
/// bytes into 32-bit words, byte 0 first. A frame is visible on the read side
/// only when its last byte is written. A frame count crosses to the sys clock
/// in gray code.
///
/// When a word of a frame does not fit, the FIFO moves the write pointer back
/// to the frame start and drops the frame up to its last byte. No part of it
/// is visible. `rx_overflow` pulses for one sys cycle for each dropped frame.
///
/// The read side gives 32-bit words on the sys clock. `r_bytes` on the word
/// with `r_last` gives the valid bytes, 0 means 4. `r_status` on that word is
/// the status of the MAC.
///
/// When the RX clock stops, `clk_lost` goes high and stays high until
/// `clk_lost_clear`. The FIFO resets on both sides and the frames in it are
/// lost. If the reader has taken part of a frame, the read side gives one
/// more word with `r_last` and [harborEthRxStatusCut] in `r_status`. On the RX
/// side, the rest of a frame that the loss cut is dropped.
class HarborEthRxFrameFifo extends Module {
  /// Size of the storage in bytes.
  final int bytes;

  /// Target that gives the block RAM, or null for flops.
  final HarborDeviceTarget? target;

  /// Whether the storage is block RAM.
  bool get usesBlockRam => target?.blockRam != null;

  Logic get rValid => output('r_valid');
  Logic get rData => output('r_data');
  Logic get rBytes => output('r_bytes');
  Logic get rLast => output('r_last');
  Logic get rStatus => output('r_status');

  /// One sys cycle pulse for each frame dropped on overflow.
  Logic get rxOverflow => output('rx_overflow');

  /// RX clock lost, sticky until `clk_lost_clear`. Sys clock.
  Logic get clkLost => output('clk_lost');

  HarborEthRxFrameFifo(
    Logic rxClk,
    Logic rxReset,
    Logic sysClk,
    Logic sysReset, {
    required this.bytes,
    required Logic inValid,
    required Logic inData,
    required Logic inLast,
    required Logic inStatus,
    required Logic rReady,
    Logic? clkLostClear,
    this.target,
    super.name = 'eth_rx_frame_fifo',
  }) : super(
         definitionName:
             'HarborEthRxFrameFifo_$bytes'
             '${target?.blockRam == null ? '' : '_${target!.blockRam!.name}'}',
       ) {
    _checkBytes(bytes);
    rxClk = addInput('rx_clk', rxClk);
    rxReset = addInput('rx_reset', rxReset);
    sysClk = addInput('sys_clk', sysClk);
    sysReset = addInput('sys_reset', sysReset);
    inValid = addInput('in_valid', inValid);
    inData = addInput('in_data', inData, width: 8);
    inLast = addInput('in_last', inLast);
    inStatus = addInput('in_status', inStatus, width: 8);
    rReady = addInput('r_ready', rReady);
    final clear = addInput('clk_lost_clear', clkLostClear ?? Const(0));

    final rValid = addOutput('r_valid');
    final rData = addOutput('r_data', width: 32);
    final rBytes = addOutput('r_bytes', width: 2);
    final rLast = addOutput('r_last');
    final rStatus = addOutput('r_status', width: 8);
    final rxOverflow = addOutput('rx_overflow');
    final clkLost = addOutput('clk_lost');

    final words = bytes ~/ 4;
    final aw = words.bitLength - 1;
    final pw = aw + 1;

    final watch = _clockWatch(sysClk, sysReset, rxClk, rxReset, clear);
    clkLost <= watch.sticky;

    final sysJoin = harborCdcJoinReset(
      sysClk,
      sysReset | watch.lost,
      rxReset,
      name: 'sys_join_reset',
    );
    final sysRst = harborCdcSyncReset(
      sysClk,
      sysReset,
      sysJoin,
      name: 'sys_rst',
    );
    final rxRst = harborCdcJoinReset(
      rxClk,
      rxReset,
      sysReset | watch.lost,
      name: 'rx_rst',
    );

    // RX side. The input bytes and the reset that cuts them are registered,
    // so the MAC and the reset synchronizer can be far from the FIFO.
    final inValidR = Logic(name: 'in_valid_r');
    final inDataR = Logic(name: 'in_data_r', width: 8);
    final inLastR = Logic(name: 'in_last_r');
    final inStatusR = Logic(name: 'in_status_r', width: 8);
    Sequential(rxClk, [
      inValidR < inValid,
      inDataR < inData,
      inLastR < inLast,
      inStatusR < inStatus,
    ], reset: rxReset);
    inValid = inValidR;
    inData = inDataR;
    inLast = inLastR;
    inStatus = inStatusR;
    // `rx_rst` asserts between edges, so the copy for the cut goes through
    // the house sync, like `sys_rst` on the TX side.
    final rxRstR = harborCdcSyncReset(
      rxClk,
      rxReset,
      rxRst,
      name: 'rx_cut_rst',
    );

    final acc = Logic(name: 'acc', width: 24);
    final bi = Logic(name: 'byte_idx', width: 2);
    final wPtr = Logic(name: 'w_ptr', width: pw);
    final wStart = Logic(name: 'w_start', width: pw);
    final wFrames = Logic(name: 'w_frames', width: pw);
    final wFramesGray = Logic(name: 'w_frames_gray', width: pw);
    final ovfDrop = Logic(name: 'ovf_drop');
    final ovfTog = Logic(name: 'ovf_tog');
    final mid = Logic(name: 'w_mid');
    final cutDrop = Logic(name: 'cut_drop');
    final rPtrGray = Logic(name: 'r_ptr_gray', width: pw);
    final rGrayS0 = Logic(name: 'r_gray_s0', width: pw);
    final rGrayS1 = Logic(name: 'r_gray_s1', width: pw);

    // Registered read pointer and fill level. The fill level comes from the
    // write pointer of the cycle before, so it can be one word low. Thus the
    // FIFO is full one word early.
    final rBin = Logic(name: 'r_ptr_bin', width: pw);
    final full = Logic(name: 'w_full');
    final cut = (rxRstR | cutDrop).named('w_cut');
    final take = (inValid & ~cut & ~ovfDrop).named('w_take');
    final wordEnd = (take & (bi.eq(3) | inLast)).named('w_word_end');
    final overflow = (wordEnd & full).named('w_overflow');
    final write = (wordEnd & ~full).named('w_write');
    final commit = (write & inLast).named('w_commit');
    final lanes = [
      for (var k = 0; k < 4; k++)
        mux(
          bi.eq(k),
          inData,
          k < 3 ? acc.getRange(8 * k, 8 * k + 8) : Const(0, width: 8),
        ),
    ];
    final wWord = [
      mux(inLast, inStatus, Const(0, width: 8)),
      inLast,
      mux(inLast, bi + 1, Const(0, width: 2)),
      lanes.reversed.toList().swizzle(),
    ].swizzle().named('w_word');
    final wPtrNext = mux(
      overflow,
      wStart,
      mux(write, wPtr + 1, wPtr),
    ).named('w_ptr_next');

    Sequential(rxClk, [
      rGrayS0 < rPtrGray,
      rGrayS1 < rGrayS0,
      rBin < _grayToBin(rGrayS1),
      full < (wPtr - rBin).gte(words - 1),
      wPtr < wPtrNext,
      If(
        wordEnd,
        then: [acc < Const(0, width: 24), bi < Const(0, width: 2)],
        orElse: [
          If(
            take,
            then: [
              acc < lanes.sublist(0, 3).reversed.toList().swizzle(),
              bi < bi + 1,
            ],
          ),
        ],
      ),
      If(
        commit,
        then: [
          wStart < wPtr + 1,
          wFrames < wFrames + 1,
          wFramesGray < _gray(wFrames + 1),
        ],
      ),
      If(inValid & inLast, then: [ovfDrop < Const(0)]),
      If(overflow, then: [ovfDrop < ~inLast]),
    ], reset: rxRst);

    // A frame that a reset cut is dropped up to its last byte.
    Sequential(rxClk, [
      If(inValid, then: [mid < ~inLast]),
      cutDrop < cut & mux(inValid, ~inLast, mid),
    ], reset: rxReset);

    // The toggle and its sync clear in the join resets, so a reset of one
    // side cannot look like an overflow.
    Sequential(
      rxClk,
      [
        If(overflow, then: [ovfTog < ~ovfTog]),
      ],
      reset: rxRst,
      asyncReset: true,
    );

    // Sys side.
    final rPtr = Logic(name: 'r_ptr', width: pw);
    final doneFrames = Logic(name: 'done_frames', width: pw);
    final framesS0 = Logic(name: 'frames_s0', width: pw);
    final framesS1 = Logic(name: 'frames_s1', width: pw);
    final ramValid = Logic(name: 'ram_valid');
    final rMid = Logic(name: 'r_mid');
    final rAbort = Logic(name: 'r_abort');
    final ovfS0 = Logic(name: 'ovf_s0');
    final ovfS1 = Logic(name: 'ovf_s1');
    final ovfS2 = Logic(name: 'ovf_s2');

    final fetch = Logic(name: 'fetch');
    final ram = _store(
      wrClk: rxClk,
      wrEn: write,
      wrAddr: wPtr.getRange(0, aw),
      wrData: wWord,
      rdClk: sysClk,
      rdReset: sysRst,
      rdEn: fetch,
      rdAddr: rPtr.getRange(0, aw),
      depth: words,
      bram: target?.blockRam,
    );
    final ramLast = ram[34];

    // The words go from the RAM output register to a queue of two flop
    // registers. A word moves into the queue when the queue has fewer than
    // 2 words, so the RAM read enable does not wait for the reader.
    final framesBin = Logic(name: 'frames_bin', width: pw);
    final doneNext = Logic(name: 'done_frames_p1', width: pw);
    final qN = Logic(name: 'q_n', width: 2);
    final q0 = Logic(name: 'q0', width: ram.width);
    final q1 = Logic(name: 'q1', width: ram.width);
    final availNone = (~doneFrames.eq(framesBin)).named('avail_none');
    final availOne = (~doneNext.eq(framesBin)).named('avail_one');
    final avail = mux(
      ramValid & ramLast,
      availOne,
      availNone,
    ).named('frame_avail');
    final move = (ramValid & ~qN[1]).named('move');
    final headValid = (qN.neq(0) & ~sysRst).named('head_valid');
    final sReady = Logic(name: 'slice_ready');
    final pop = (sReady & headValid & ~rAbort).named('pop');
    fetch <= avail & (~ramValid | move);

    Sequential(
      sysClk,
      [
        framesS0 < wFramesGray,
        framesS1 < framesS0,
        framesBin < _grayToBin(framesS1),
        If(fetch, then: [rPtr < rPtr + 1, rPtrGray < _gray(rPtr + 1)]),
        ramValid < fetch | (ramValid & ~move),
        If(
          move & ramLast,
          then: [doneFrames < doneNext, doneNext < doneNext + 1],
        ),
        qN < qN + move.zeroExtend(2) - pop.zeroExtend(2),
        If.block([
          Iff(pop, [q0 < mux(qN[1], q1, ram)]),
          ElseIf(qN.eq(0), [q0 < ram]),
        ]),
        If(move & ~pop & qN.eq(1), then: [q1 < ram]),
      ],
      reset: sysRst,
      resetValues: {doneNext: Const(1, width: pw)},
    );

    final xValid = (rAbort | headValid).named('x_valid');
    final xLast = (rAbort | q0[34]).named('x_last');
    final xWord = [
      mux(rAbort, Const(harborEthRxStatusCut, width: 8), q0.getRange(35)),
      xLast,
      mux(rAbort, Const(0, width: 2), q0.getRange(32, 34)),
      mux(rAbort, Const(0, width: 32), q0.getRange(0, 32)),
    ].swizzle().named('x_word');
    final xTake = (xValid & sReady).named('x_take');

    Sequential(sysClk, [
      If(xTake, then: [rMid < ~xLast]),
      rAbort < mux(rAbort, ~sReady, sysRst & rMid),
    ], reset: sysReset);

    // A register slice between the queue and the reader. Its ready to the
    // queue is a flop, so the reader and the queue can be far apart. It
    // resets only with `sys_reset`, so a frame that it holds still ends
    // with the abort word.
    final oValid = Logic(name: 'out_valid');
    final oWord = Logic(name: 'out_word', width: xWord.width);
    final skValid = Logic(name: 'skid_valid');
    final skWord = Logic(name: 'skid_word', width: xWord.width);
    sReady <= ~skValid;
    Sequential(sysClk, [
      If(
        ~oValid | rReady,
        then: [
          If(
            skValid,
            then: [oWord < skWord, oValid < Const(1), skValid < Const(0)],
            orElse: [oWord < xWord, oValid < xValid],
          ),
        ],
        orElse: [
          If(xTake, then: [skWord < xWord, skValid < Const(1)]),
        ],
      ),
    ], reset: sysReset);
    rValid <= oValid;
    rData <= oWord.getRange(0, 32);
    rBytes <= oWord.getRange(32, 34);
    rLast <= oWord[34];
    rStatus <= oWord.getRange(35);
    Sequential(sysClk, [
      ovfS0 < ovfTog,
      ovfS1 < ovfS0,
      ovfS2 < ovfS1,
    ], reset: sysRst);
    rxOverflow <= (ovfS1 ^ ovfS2) & ~sysRst;
  }
}
