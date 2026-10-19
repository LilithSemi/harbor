import 'package:rohd/rohd.dart';

/// Converts the 7-series PCIe TRN interface to 64-bit AXI streams.
class HarborPcieTrnAxi extends Module {
  Logic get rxData => output('rx_data');
  Logic get rxKeep => output('rx_keep');
  Logic get rxLast => output('rx_last');
  Logic get rxValid => output('rx_valid');
  Logic get rxUser => output('rx_user');
  Logic get txReady => output('tx_ready');

  /// High when no TX beat is held and no TX packet is in progress.
  Logic get txIdle => output('tx_idle');

  Logic get trnRxReady => output('trn_rx_ready');
  Logic get trnTxData => output('trn_tx_data');
  Logic get trnTxRem => output('trn_tx_rem');
  Logic get trnTxSof => output('trn_tx_sof');
  Logic get trnTxEof => output('trn_tx_eof');
  Logic get trnTxSrcReady => output('trn_tx_src_ready');
  Logic get trnTxSrcDsc => output('trn_tx_src_dsc');
  Logic get trnTxErrFwd => output('trn_tx_err_fwd');
  Logic get trnTxStr => output('trn_tx_str');
  Logic get trnTxEcrcGen => output('trn_tx_ecrc_gen');
  Logic get trnTxCfgGrant => output('trn_tx_cfg_grant');

  HarborPcieTrnAxi({
    required Logic clk,
    required Logic reset,
    required Logic linkUp,
    required Logic rxReady,
    required Logic txData,
    required Logic txKeep,
    required Logic txLast,
    required Logic txValid,
    Logic? txUser,
    required Logic trnRxData,
    required Logic trnRxRem,
    required Logic trnRxSof,
    required Logic trnRxEof,
    required Logic trnRxSrcReady,
    required Logic trnRxSrcDsc,
    required Logic trnRxErrFwd,
    required Logic trnRxBarHit,
    required Logic trnRxEcrcErr,
    required Logic trnTxDstReady,
    required Logic trnTxCfgReq,
    super.name = 'pcie_trn_axi',
  }) : super(definitionName: 'HarborPcieTrnAxi') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    linkUp = addInput('link_up', linkUp);
    rxReady = addInput('rx_ready', rxReady);
    txData = addInput('tx_data', txData, width: 64);
    txKeep = addInput('tx_keep', txKeep, width: 8);
    txLast = addInput('tx_last', txLast);
    txValid = addInput('tx_valid', txValid);
    final txUserPort = addInput(
      'tx_user',
      txUser ?? Const(0, width: 4),
      width: 4,
    );
    trnRxData = addInput('trn_rx_data', trnRxData, width: 128);
    trnRxRem = addInput('trn_rx_rem', trnRxRem, width: 2);
    trnRxSof = addInput('trn_rx_sof', trnRxSof);
    trnRxEof = addInput('trn_rx_eof', trnRxEof);
    trnRxSrcReady = addInput('trn_rx_src_ready', trnRxSrcReady);
    trnRxSrcDsc = addInput('trn_rx_src_dsc', trnRxSrcDsc);
    trnRxErrFwd = addInput('trn_rx_err_fwd', trnRxErrFwd);
    trnRxBarHit = addInput('trn_rx_bar_hit', trnRxBarHit, width: 8);
    trnRxEcrcErr = addInput('trn_rx_ecrc_err', trnRxEcrcErr);
    trnTxDstReady = addInput('trn_tx_dst_ready', trnTxDstReady, width: 4);
    trnTxCfgReq = addInput('trn_tx_cfg_req', trnTxCfgReq);

    final rxDataReg = Logic(name: 'rx_data_reg', width: 64);
    final rxKeepReg = Logic(name: 'rx_keep_reg', width: 8);
    final rxLastReg = Logic(name: 'rx_last_reg');
    final rxValidReg = Logic(name: 'rx_valid_reg');
    final rxUserReg = Logic(name: 'rx_user_reg', width: 22);
    final rxInPacket = Logic(name: 'rx_in_packet');
    final acceptRx = (~rxValidReg | rxReady).named('accept_rx');
    final sourceRx = (trnRxSrcReady & (rxInPacket | (trnRxSof & ~trnRxSrcDsc)))
        .named('source_rx');
    final swappedRx = [
      trnRxData.slice(31, 0),
      trnRxData.slice(63, 32),
    ].swizzle();
    final eofLocation =
        (trnRxEof.zeroExtend(5) << Const(4, width: 5)) |
        (trnRxRem[0].zeroExtend(5) << Const(2, width: 5)) |
        Const(3, width: 5);
    final sofLocation = trnRxSof.zeroExtend(5) << Const(4, width: 5);
    final incomingUser =
        (eofLocation.zeroExtend(22) << Const(17, width: 22)) |
        (sofLocation.zeroExtend(22) << Const(10, width: 22)) |
        (trnRxBarHit.slice(6, 0).zeroExtend(22) << Const(2, width: 22)) |
        (trnRxErrFwd.zeroExtend(22) << Const(1, width: 22)) |
        trnRxEcrcErr.zeroExtend(22);

    addOutput('rx_data', width: 64) <= rxDataReg;
    addOutput('rx_keep', width: 8) <= rxKeepReg;
    addOutput('rx_last') <= rxLastReg;
    addOutput('rx_valid') <= rxValidReg;
    addOutput('rx_user', width: 22) <= rxUserReg;
    addOutput('trn_rx_ready') <= acceptRx;

    Sequential(clk, [
      If(
        reset | ~linkUp,
        then: [rxValidReg < Const(0), rxInPacket < Const(0)],
        orElse: [
          If(
            acceptRx,
            then: [
              rxValidReg < sourceRx,
              If(
                sourceRx,
                then: [
                  rxDataReg < swappedRx,
                  rxKeepReg <
                      mux(
                        trnRxRem[0],
                        Const(0xff, width: 8),
                        Const(0x0f, width: 8),
                      ),
                  rxLastReg < trnRxEof,
                  rxUserReg < incomingUser,
                ],
              ),
            ],
          ),
          If(
            trnRxSrcReady & acceptRx,
            then: [
              If(
                trnRxEof | trnRxSrcDsc,
                then: [rxInPacket < Const(0)],
                orElse: [
                  If(trnRxSof, then: [rxInPacket < Const(1)]),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    final txDataReg = Logic(name: 'tx_data_reg', width: 64);
    final txKeepReg = Logic(name: 'tx_keep_reg', width: 8);
    final txLastReg = Logic(name: 'tx_last_reg');
    final txValidReg = Logic(name: 'tx_valid_reg');
    final txUserReg = Logic(name: 'tx_user_reg', width: 4);
    final txInPacket = Logic(name: 'tx_in_packet');
    final trnAccept = (trnTxDstReady[0] & linkUp).named('trn_accept');
    final acceptTx = (~txValidReg | trnAccept).named('accept_tx');
    final txTransfer = (txValidReg & trnAccept).named('tx_transfer');
    final swappedTx = [
      txDataReg.slice(31, 0),
      txDataReg.slice(63, 32),
    ].swizzle();

    addOutput('tx_ready') <= acceptTx & linkUp & ~trnTxCfgReq;
    addOutput('tx_idle') <= ~txValidReg & ~txInPacket;
    addOutput('trn_tx_data', width: 128) <= swappedTx.zeroExtend(128);
    addOutput('trn_tx_rem', width: 2) <= txKeepReg[7].zeroExtend(2);
    addOutput('trn_tx_sof') <= txValidReg & ~txInPacket;
    addOutput('trn_tx_eof') <= txValidReg & txLastReg;
    addOutput('trn_tx_src_ready') <= txValidReg & linkUp;
    addOutput('trn_tx_src_dsc') <= txUserReg[3];
    addOutput('trn_tx_err_fwd') <= txUserReg[1];
    addOutput('trn_tx_str') <= txUserReg[2];
    addOutput('trn_tx_ecrc_gen') <= txUserReg[0];
    addOutput('trn_tx_cfg_grant') <= trnTxCfgReq & ~txInPacket & ~txValidReg;

    Sequential(clk, [
      If(
        reset | ~linkUp,
        then: [txValidReg < Const(0), txInPacket < Const(0)],
        orElse: [
          If(
            acceptTx,
            then: [
              txValidReg < txValid & ~trnTxCfgReq,
              If(
                txValid & ~trnTxCfgReq,
                then: [
                  txDataReg < txData,
                  txKeepReg < txKeep,
                  txLastReg < txLast,
                  txUserReg < txUserPort,
                ],
              ),
            ],
          ),
          If(
            txTransfer,
            then: [
              If(
                txLastReg,
                then: [txInPacket < Const(0)],
                orElse: [txInPacket < Const(1)],
              ),
            ],
          ),
        ],
      ),
    ]);
  }
}
