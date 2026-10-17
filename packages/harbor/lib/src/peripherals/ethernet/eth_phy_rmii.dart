import 'package:rohd/rohd.dart';

import '../../clock/cdc.dart';
import 'eth_byte_stream.dart';
import 'eth_constraint.dart';
import 'eth_phy_rx_stage.dart';

/// RMII front end for the Ethernet MAC cores.
///
/// Both directions use the 50 MHz reference clock, 2 bits on each clock with
/// the low pair first. At 100 Mbps the byte stream has one strobe on every
/// fourth clock. At 10 Mbps each pair stays on the pins for 10 clocks.
///
/// [speed] is 1 for 100 Mbps. Any other value selects 10 Mbps. Change it
/// only while the transmitter and the receiver are stopped.
///
/// The receiver starts a frame at the first `01` pair with `crs_dv` high.
/// A frame ends when `crs_dv` is low on two pairs in a row. At the end of a
/// frame the PHY can toggle `crs_dv` at the nibble rate while data is still
/// valid. A pair with `crs_dv` low is data when the next pair has `crs_dv`
/// high. At 10 Mbps the receiver samples the middle of each repeated pair.
/// A last half byte is dropped and sets `rx_er` on the last whole byte.
/// A preamble that lost pairs still works. The first `11` pair after the
/// `01` pairs is the top pair of the SFD, and sets the byte alignment.
/// `rx_er` high on any clock of a pair counts for that pair.
class HarborEthPhyRmii extends Module {
  /// Transmit data pins.
  Logic get txd => output('rmii_txd');

  /// Transmit enable pin.
  Logic get txEn => output('rmii_tx_en');

  HarborEthPhyRmii(
    HarborEthByteStream stream, {
    required Logic reset,
    required Logic speed,
    required Logic rmiiRefClk,
    required Logic rmiiRxd,
    required Logic rmiiCrsDv,
    required Logic rmiiRxEr,
    super.name = 'eth_phy_rmii',
  }) : super(definitionName: 'HarborEthPhyRmii') {
    final s = HarborEthByteStream()
      ..pairConnectIO(this, stream, PairRole.provider);
    reset = addInput('reset', reset);
    speed = addInput('speed', speed, width: 2);
    final clk = addInput('rmii_ref_clk', rmiiRefClk);
    final rxd = addInput('rmii_rxd', rmiiRxd, width: 2);
    final crsDv = addInput('rmii_crs_dv', rmiiCrsDv);
    final rxEr = addInput('rmii_rx_er', rmiiRxEr);

    final txd = addOutput('rmii_txd', width: 2);
    final txEn = addOutput('rmii_tx_en');

    final rst = harborCdcJoinReset(clk, reset, Const(0), name: 'ref_rst');
    s.txClk <= clk;
    s.rxClk <= clk;
    s.txReset <= rst;
    s.rxReset <= rst;

    final speedSync = HarborCdcSync(width: 2, name: 'speed_sync');
    speedSync.input('async_in').srcConnection! <= speed;
    speedSync.input('dst_clk').srcConnection! <= clk;
    speedSync.input('dst_reset').srcConnection! <= rst;
    final fastIn = speedSync.syncOut.eq(1).named('fast_in');
    final fast = Logic(name: 'fast');
    Sequential(clk, [fast < fastIn], reset: rst);

    Logic dibit(Logic byte, Logic idx) => mux(
      idx[1],
      mux(idx[0], byte.slice(7, 6), byte.slice(5, 4)),
      mux(idx[0], byte.slice(3, 2), byte.slice(1, 0)),
    );

    // Transmit: [txSub] counts the clocks of one pair at 10 Mbps. The end
    // of a pair and the strobe are flops that look one clock ahead.
    final txSub = Logic(name: 'tx_sub', width: 4);
    final txIdx = Logic(name: 'tx_idx', width: 2);
    final txAt9 = Logic(name: 'tx_at9');
    final txStrobe = Logic(name: 'tx_strobe_r');
    final txStep = (fast | txAt9).named('tx_step');
    final subNext = mux(txStep, Const(0, width: 4), txSub + 1);
    final idxNext = txIdx + txStep.zeroExtend(2);
    Sequential(clk, [
      txSub < subNext,
      txIdx < idxNext,
      txAt9 < subNext.eq(9),
      txStrobe < (fastIn | subNext.eq(9)) & idxNext.eq(3),
    ], reset: rst);
    s.txStrobe <= txStrobe;

    final txdR = Logic(name: 'txd_r', width: 2);
    final txEnR = Logic(name: 'tx_en_r');
    Sequential(clk, [
      txdR < dibit(s.txData, txIdx),
      txEnR < s.txEn,
    ], reset: rst);
    txd <= txdR;
    txEn <= txEnR;

    // Receive: [tick] is the sample point of one pair.
    final sub = Logic(name: 'rx_sub', width: 4);
    final inFrame = Logic(name: 'rx_in_frame');
    final idx = Logic(name: 'rx_idx', width: 2);
    final buf = Logic(name: 'rx_buf', width: 6);
    final acc = Logic(name: 'rx_acc');
    final pData = Logic(name: 'rx_p_data', width: 2);
    final pCrs = Logic(name: 'rx_p_crs');
    final pEr = Logic(name: 'rx_p_er');
    final locked = Logic(name: 'rx_locked');
    final erWin = Logic(name: 'rx_er_win');

    final tick = (fast | sub.eq(5)).named('rx_tick');
    final startCond = (crsDv & rxd.eq(1)).named('rx_start');
    final valid = (pCrs | crsDv).named('rx_valid');
    final frameEnd = (inFrame & tick & ~valid).named('rx_frame_end');
    final sfdPair = ~locked & pData.eq(3);
    final lastPair = (idx.eq(3) | sfdPair).named('rx_last_pair');
    final erAny = (rxEr | erWin).named('rx_er_any');

    Sequential(clk, [
      If(
        ~fast,
        then: [
          If(
            ~inFrame & ~startCond,
            then: [sub < 0, pCrs < 0],
            orElse: [
              If(sub.eq(9), then: [sub < 0], orElse: [sub < sub + 1]),
            ],
          ),
        ],
        orElse: [sub < 0],
      ),
      If(~tick, then: [erWin < erAny]),
      If(
        tick,
        then: [
          If(
            inFrame,
            then: [
              If(
                valid,
                then: [
                  buf < [pData, buf.slice(5, 2)].swizzle(),
                  idx < mux(lastPair, Const(0, width: 2), idx + 1),
                  If(sfdPair, then: [locked < 1]),
                  acc < mux(lastPair, Const(0), acc | pEr),
                ],
                orElse: [inFrame < 0, idx < 0, acc < 0, sub < 0, locked < 0],
              ),
            ],
            orElse: [
              If(
                pCrs & pData.eq(1),
                then: [
                  inFrame < 1,
                  buf < [pData, buf.slice(5, 2)].swizzle(),
                  idx < 1,
                  acc < pEr,
                  locked < 0,
                ],
              ),
            ],
          ),
          pData < rxd,
          pCrs < crsDv,
          pEr < erAny,
          erWin < 0,
          If(frameEnd, then: [pCrs < 0]),
        ],
      ),
    ], reset: rst);

    final idleCnt = Logic(name: 'rx_idle_cnt', width: 6);
    final idleLast = idleCnt.gte(
      mux(fast, Const(3, width: 6), Const(39, width: 6)),
    );
    Sequential(
      clk,
      [
        If(idleLast, then: [idleCnt < 0], orElse: [idleCnt < idleCnt + 1]),
      ],
      reset: rst,
      resetValues: {idleCnt: Const(63, width: 6)},
    );

    final out = harborEthPhyRxStage(
      clk,
      rst,
      byteIn: inFrame & tick & valid & lastPair,
      byteData: [pData, buf].swizzle(),
      byteEr: acc | pEr,
      frameEnd: frameEnd,
      dribble: idx.neq(0),
      idleTick: ~inFrame & idleLast,
    );
    s.rxData <= out.data;
    s.rxDv <= out.dv;
    s.rxEr <= out.er;
    s.rxStrobe <= out.strobe;
  }

  /// Timing constraints of the RMII pins.
  ///
  /// [topPort] gives the top-level name of a front end pin. The clock name
  /// is the top-level name of `rmii_ref_clk`. The values come from the AC
  /// timing of the RMII Consortium specification rev 1.2. Outputs change 2
  /// to 14 ns after REF_CLK rises, so the input delay is 14 ns max and 2 ns
  /// min. Inputs have 4 ns setup and 2 ns hold, so the output delay is 4 ns
  /// max and -2 ns min.
  static List<HarborEthClockConstraint> constraints({
    String Function(String pin)? topPort,
  }) {
    final p = topPort ?? (String n) => n;
    final clk = p('rmii_ref_clk');
    return [
      HarborEthClockConstraint(
        kind: HarborEthClockConstraintKind.clock,
        clock: clk,
        ports: [clk],
        periodNs: 20.0,
      ),
      HarborEthClockConstraint(
        kind: HarborEthClockConstraintKind.inputDelay,
        clock: clk,
        ports: ['${p('rmii_rxd')}[*]', p('rmii_crs_dv'), p('rmii_rx_er')],
        maxNs: 14.0,
        minNs: 2.0,
      ),
      HarborEthClockConstraint(
        kind: HarborEthClockConstraintKind.outputDelay,
        clock: clk,
        ports: ['${p('rmii_txd')}[*]', p('rmii_tx_en')],
        maxNs: 4.0,
        minNs: -2.0,
      ),
    ];
  }
}
