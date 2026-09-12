/// Full-speed USB protocol engines ported from the proven
/// tinyfpga_bx_usbserial core (davidthings). This file is a faithful ROHD
/// translation of usb_fs_in_pe.v and usb_fs_out_pe.v plus the composed
/// usb_fs_pe.v top (arbiters, TX mux and the USB reset detector).
///
/// The IN protocol engine answers IN tokens with data: each endpoint
/// buffers up to one packet, tracks its data toggle and sends DATA0/DATA1,
/// NAK or STALL as appropriate. The OUT protocol engine receives OUT and
/// SETUP transactions: it validates the data toggle, buffers the payload
/// and answers ACK, NAK or STALL.
///
/// HarborUsbFsPe composes both engines with the line PHY
/// (HarborUsbFsRx/HarborUsbFsTx) and exposes per-endpoint byte-stream
/// interfaces.
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'usb_fs_phy.dart';

/// IN endpoint protocol engine, ported from usb_fs_in_pe.v.
class HarborUsbFsInPe extends BridgeModule {
  /// Number of IN endpoints this engine serves.
  final int numInEps;

  /// Maximum packet payload per endpoint, in bytes.
  final int maxPacketSize;

  HarborUsbFsInPe({this.numInEps = 1, this.maxPacketSize = 32, String? name})
    : super('HarborUsbFsInPe', name: name ?? 'usb_fs_in_pe') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('reset_ep', PortDirection.input, width: numInEps);
    createPort('dev_addr', PortDirection.input, width: 7);

    addOutput('in_ep_data_free', width: numInEps);
    createPort('in_ep_data_put', PortDirection.input, width: numInEps);
    createPort('in_ep_data', PortDirection.input, width: 8);
    createPort('in_ep_data_done', PortDirection.input, width: numInEps);
    createPort('in_ep_stall', PortDirection.input, width: numInEps);
    addOutput('in_ep_acked', width: numInEps);

    createPort('rx_pkt_start', PortDirection.input);
    createPort('rx_pkt_end', PortDirection.input);
    createPort('rx_pkt_valid', PortDirection.input);
    createPort('rx_pid', PortDirection.input, width: 4);
    createPort('rx_addr', PortDirection.input, width: 7);
    createPort('rx_endp', PortDirection.input, width: 4);
    createPort('rx_frame_num', PortDirection.input, width: 11);

    addOutput('tx_pkt_start');
    createPort('tx_pkt_end', PortDirection.input);
    addOutput('tx_pid', width: 4);
    addOutput('tx_data_avail');
    createPort('tx_data_get', PortDirection.input);
    addOutput('tx_data', width: 8);

    final clk = input('clk');
    final reset = input('reset');
    final resetEp = input('reset_ep');
    final devAddr = input('dev_addr');
    final inEpDataPut = input('in_ep_data_put');
    final inEpData = input('in_ep_data');
    final inEpDataDone = input('in_ep_data_done');
    final inEpStall = input('in_ep_stall');
    final rxPktEnd = input('rx_pkt_end');
    final rxPktValid = input('rx_pkt_valid');
    final rxPid = input('rx_pid');
    final rxAddr = input('rx_addr');
    final rxEndp = input('rx_endp');
    final txDataGet = input('tx_data_get');

    // Endpoint states.
    const stReady = 0;
    const stPutting = 1;
    const stGetting = 2;
    const stStall = 3;

    final epState = List.generate(
      numInEps,
      (ep) => Logic(name: 'ep_state_$ep', width: 2),
    );
    final epStateNext = List.generate(
      numInEps,
      (ep) => Logic(name: 'ep_state_next_$ep', width: 2),
    );
    final epPutAddr = List.generate(
      numInEps,
      (ep) => Logic(name: 'ep_put_addr_$ep', width: 6),
    );
    final epGetAddr = List.generate(
      numInEps,
      (ep) => Logic(name: 'ep_get_addr_$ep', width: 6),
    );
    final dataToggle = List.generate(
      numInEps,
      (ep) => Logic(name: 'data_toggle_$ep'),
    );

    // The endpoint payload buffers, one byte list per endpoint.
    final buffer = List.generate(numInEps, (ep) {
      return List.generate(
        maxPacketSize,
        (i) => Logic(name: 'in_buf_${ep}_$i', width: 8),
      );
    });

    // Transfer states.
    const xfrIdle = 0;
    const xfrRcvdIn = 1;
    const xfrSendData = 2;
    const xfrWaitAck = 3;

    final inXfrState = Logic(name: 'in_xfr_state', width: 2);
    final inXfrStateNext = Logic(name: 'in_xfr_state_next', width: 2);
    final inXfrStart = Logic(name: 'in_xfr_start');
    final inXfrEnd = Logic(name: 'in_xfr_end');
    final rollbackInXfr = Logic(name: 'rollback_in_xfr');

    final currentEndp = Logic(name: 'current_endp', width: 4);

    final txPktStart = Logic(name: 'tx_pkt_start_i');
    final txPid = Logic(name: 'tx_pid_i', width: 4);
    final txDataAvail = Logic(name: 'tx_data_avail_i');
    final txData = Logic(name: 'tx_data_i', width: 8);

    // ------------------------------------------------------------------
    // Token decode.
    // ------------------------------------------------------------------
    final tokenReceived =
        (rxPktEnd &
                rxPktValid &
                rxPid.slice(1, 0).eq(Const(1, width: 2)) &
                rxAddr.eq(devAddr) &
                rxEndp.lt(Const(numInEps, width: 4)))
            .named('token_received');

    final setupTokenReceived =
        (tokenReceived & rxPid.slice(3, 2).eq(Const(3, width: 2))).named(
          'setup_token_received',
        );

    final inTokenReceived =
        (tokenReceived & rxPid.slice(3, 2).eq(Const(2, width: 2))).named(
          'in_token_received',
        );

    final ackReceived = (rxPktEnd & rxPktValid & rxPid.eq(Const(2, width: 4)))
        .named('ack_received');

    // ------------------------------------------------------------------
    // Current-endpoint selects: state and data toggle.
    // ------------------------------------------------------------------
    Logic currentEpState = epState[0];
    Logic currentDataToggle = dataToggle[0];
    for (var ep = 1; ep < numInEps; ep++) {
      currentEpState = mux(
        currentEndp.eq(Const(ep, width: 4)),
        epState[ep],
        currentEpState,
      );
      currentDataToggle = mux(
        currentEndp.eq(Const(ep, width: 4)),
        dataToggle[ep],
        currentDataToggle,
      );
    }

    // ------------------------------------------------------------------
    // Per-endpoint combinational: next state, acked, free.
    // ------------------------------------------------------------------
    final ackedBits = List.generate(numInEps, (ep) => Logic(name: 'acked_$ep'));
    final dataFreeBits = List.generate(
      numInEps,
      (ep) => Logic(name: 'data_free_$ep'),
    );

    for (var ep = 0; ep < numInEps; ep++) {
      Combinational([
        ackedBits[ep] < Const(0),
        epStateNext[ep] < epState[ep],
        If(
          inEpStall.slice(ep, ep),
          then: [epStateNext[ep] < Const(stStall, width: 2)],
          orElse: [
            Case(
              epState[ep],
              [
                CaseItem(Const(stReady, width: 2), [
                  epStateNext[ep] < Const(stPutting, width: 2),
                ]),
                CaseItem(Const(stPutting, width: 2), [
                  If(
                    inEpDataDone.slice(ep, ep) | epPutAddr[ep].slice(5, 5),
                    then: [epStateNext[ep] < Const(stGetting, width: 2)],
                    orElse: [epStateNext[ep] < Const(stPutting, width: 2)],
                  ),
                ]),
                CaseItem(Const(stGetting, width: 2), [
                  If(
                    inXfrEnd & currentEndp.eq(Const(ep, width: 4)),
                    then: [
                      epStateNext[ep] < Const(stReady, width: 2),
                      ackedBits[ep] < Const(1),
                    ],
                    orElse: [epStateNext[ep] < Const(stGetting, width: 2)],
                  ),
                ]),
                CaseItem(Const(stStall, width: 2), [
                  If(
                    setupTokenReceived & rxEndp.eq(Const(ep, width: 4)),
                    then: [epStateNext[ep] < Const(stReady, width: 2)],
                    orElse: [epStateNext[ep] < Const(stStall, width: 2)],
                  ),
                ]),
              ],
              defaultItem: [epStateNext[ep] < Const(stReady, width: 2)],
            ),
          ],
        ),
        dataFreeBits[ep] <
            ~epPutAddr[ep].slice(5, 5) &
                epState[ep].eq(Const(stPutting, width: 2)),
      ]);
    }

    output('in_ep_acked') <= ackedBits.rswizzle();
    output('in_ep_data_free') <= dataFreeBits.rswizzle();

    // ------------------------------------------------------------------
    // Per-endpoint sequential: state and put address.
    // ------------------------------------------------------------------
    for (var ep = 0; ep < numInEps; ep++) {
      Sequential(clk, [
        If(
          reset | resetEp.slice(ep, ep),
          then: [
            epState[ep] < Const(stReady, width: 2),
            // The original gives ep_put_addr an initial value of 0.
            epPutAddr[ep] < Const(0, width: 6),
          ],
          orElse: [
            epState[ep] < epStateNext[ep],
            Case(epState[ep], [
              CaseItem(Const(stReady, width: 2), [
                epPutAddr[ep] < Const(0, width: 6),
              ]),
              CaseItem(Const(stPutting, width: 2), [
                If(
                  inEpDataPut.slice(ep, ep) & ~epPutAddr[ep].slice(5, 5),
                  then: [epPutAddr[ep] < epPutAddr[ep] + Const(1, width: 6)],
                ),
              ]),
            ]),
          ],
        ),
      ]);
    }

    // ------------------------------------------------------------------
    // The endpoint number decode from data_put: the highest index wins.
    // ------------------------------------------------------------------
    final inEpNum = Logic(name: 'in_ep_num', width: 4);
    Combinational([
      inEpNum < Const(0, width: 4),
      for (var ep = 0; ep < numInEps; ep++)
        If(inEpDataPut.slice(ep, ep), then: [inEpNum < Const(ep, width: 4)]),
    ]);

    // ------------------------------------------------------------------
    // Buffer writes: the arbitrated byte lands in the decoded endpoint
    // at its put address while the endpoint accepts data.
    // ------------------------------------------------------------------
    for (var ep = 0; ep < numInEps; ep++) {
      for (var i = 0; i < maxPacketSize; i++) {
        Sequential(clk, [
          If(
            inEpNum.eq(Const(ep, width: 4)) &
                epState[ep].eq(Const(stPutting, width: 2)) &
                inEpDataPut.slice(ep, ep) &
                ~epPutAddr[ep].slice(5, 5) &
                epPutAddr[ep].slice(4, 0).eq(Const(i, width: 5)),
            then: [buffer[ep][i] < inEpData],
          ),
        ]);
      }
    }

    // ------------------------------------------------------------------
    // The registered buffer read for tx_data, muxed by the current
    // endpoint and its get address.
    // ------------------------------------------------------------------
    Logic readMux = Const(0, width: 8);
    for (var ep = 0; ep < numInEps; ep++) {
      Logic epMux = Const(0, width: 8);
      for (var i = 0; i < maxPacketSize; i++) {
        epMux = mux(
          epGetAddr[ep].slice(4, 0).eq(Const(i, width: 5)),
          buffer[ep][i],
          epMux,
        );
      }
      readMux = mux(currentEndp.eq(Const(ep, width: 4)), epMux, readMux);
    }
    Sequential(clk, [txData < readMux]);
    output('tx_data') <= txData;

    // ------------------------------------------------------------------
    // More-data and tx_data_avail.
    // ------------------------------------------------------------------
    Logic moreData = Const(0);
    for (var ep = 0; ep < numInEps; ep++) {
      moreData = mux(
        currentEndp.eq(Const(ep, width: 4)),
        epGetAddr[ep].lt(epPutAddr[ep]),
        moreData,
      );
    }
    final moreDataToSend = moreData.named('more_data_to_send');

    txDataAvail <= inXfrState.eq(Const(xfrSendData, width: 2)) & moreDataToSend;
    output('tx_data_avail') <= txDataAvail;

    // ------------------------------------------------------------------
    // The transfer state machine (combinational next state).
    // ------------------------------------------------------------------
    Combinational([
      inXfrStateNext < inXfrState,
      inXfrStart < Const(0),
      inXfrEnd < Const(0),
      txPktStart < Const(0),
      txPid < Const(0, width: 4),
      rollbackInXfr < Const(0),

      Case(
        inXfrState,
        [
          CaseItem(Const(xfrIdle, width: 2), [
            rollbackInXfr < Const(1),
            If(
              inTokenReceived,
              then: [inXfrStateNext < Const(xfrRcvdIn, width: 2)],
              orElse: [inXfrStateNext < Const(xfrIdle, width: 2)],
            ),
          ]),
          CaseItem(Const(xfrRcvdIn, width: 2), [
            txPktStart < Const(1),
            If(
              currentEpState.eq(Const(stStall, width: 2)),
              then: [
                inXfrStateNext < Const(xfrIdle, width: 2),
                txPid < Const(14, width: 4),
              ],
              orElse: [
                If(
                  currentEpState.eq(Const(stGetting, width: 2)),
                  then: [
                    inXfrStateNext < Const(xfrSendData, width: 2),
                    txPid < [currentDataToggle, Const(3, width: 3)].swizzle(),
                    inXfrStart < Const(1),
                  ],
                  orElse: [
                    inXfrStateNext < Const(xfrIdle, width: 2),
                    txPid < Const(10, width: 4),
                  ],
                ),
              ],
            ),
          ]),
          CaseItem(Const(xfrSendData, width: 2), [
            If(
              ~moreDataToSend,
              then: [inXfrStateNext < Const(xfrWaitAck, width: 2)],
              orElse: [inXfrStateNext < Const(xfrSendData, width: 2)],
            ),
          ]),
          CaseItem(Const(xfrWaitAck, width: 2), [
            If(
              ackReceived,
              then: [
                inXfrStateNext < Const(xfrIdle, width: 2),
                inXfrEnd < Const(1),
              ],
              orElse: [
                If(
                  inTokenReceived,
                  then: [
                    inXfrStateNext < Const(xfrRcvdIn, width: 2),
                    rollbackInXfr < Const(1),
                  ],
                  orElse: [
                    If(
                      rxPktEnd,
                      then: [
                        inXfrStateNext < Const(xfrIdle, width: 2),
                        rollbackInXfr < Const(1),
                      ],
                      orElse: [inXfrStateNext < Const(xfrWaitAck, width: 2)],
                    ),
                  ],
                ),
              ],
            ),
          ]),
        ],
        defaultItem: [inXfrStateNext < Const(xfrIdle, width: 2)],
      ),
    ]);

    output('tx_pkt_start') <= txPktStart;
    output('tx_pid') <= txPid;

    // ------------------------------------------------------------------
    // Shared sequential: the transfer state and the endpoint latch.
    // ------------------------------------------------------------------
    Sequential(clk, [
      If(
        reset,
        then: [
          inXfrState < Const(xfrIdle, width: 2),
          // The original declares current_endp with an initial value of
          // 0. Without a reset the endpoint select stays unknown and
          // makes the get address, and then tx_data_avail, unknown.
          currentEndp < Const(0, width: 4),
        ],
        orElse: [
          inXfrState < inXfrStateNext,
          If(inTokenReceived, then: [currentEndp < rxEndp]),
        ],
      ),
    ]);

    // ------------------------------------------------------------------
    // Per-endpoint sequential: toggles and get addresses. The reset_ep
    // override comes last so it wins, as in the original.
    // ------------------------------------------------------------------
    for (var ep = 0; ep < numInEps; ep++) {
      final isCurrent = currentEndp.eq(Const(ep, width: 4));
      Sequential(clk, [
        If(
          ~reset,
          then: [
            If(
              setupTokenReceived & rxEndp.eq(Const(ep, width: 4)),
              then: [dataToggle[ep] < Const(1)],
            ),
            If(
              rollbackInXfr & isCurrent,
              then: [epGetAddr[ep] < Const(0, width: 6)],
            ),
            If(
              inXfrState.eq(Const(xfrSendData, width: 2)) &
                  txDataGet &
                  txDataAvail &
                  isCurrent,
              then: [epGetAddr[ep] < epGetAddr[ep] + Const(1, width: 6)],
            ),
            If(
              inXfrState.eq(Const(xfrWaitAck, width: 2)) &
                  ackReceived &
                  isCurrent,
              then: [dataToggle[ep] < ~dataToggle[ep]],
            ),
          ],
        ),
        If(
          reset | resetEp.slice(ep, ep),
          then: [dataToggle[ep] < Const(0), epGetAddr[ep] < Const(0, width: 6)],
        ),
      ]);
    }
  }
}

/// OUT endpoint protocol engine, ported from usb_fs_out_pe.v.
class HarborUsbFsOutPe extends BridgeModule {
  /// Number of OUT endpoints this engine serves.
  final int numOutEps;

  /// Maximum packet payload per endpoint, in bytes.
  final int maxPacketSize;

  HarborUsbFsOutPe({this.numOutEps = 1, this.maxPacketSize = 32, String? name})
    : super('HarborUsbFsOutPe', name: name ?? 'usb_fs_out_pe') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('reset_ep', PortDirection.input, width: numOutEps);
    createPort('dev_addr', PortDirection.input, width: 7);

    addOutput('out_ep_data_avail', width: numOutEps);
    addOutput('out_ep_setup', width: numOutEps);
    createPort('out_ep_data_get', PortDirection.input, width: numOutEps);
    addOutput('out_ep_data', width: 8);
    createPort('out_ep_stall', PortDirection.input, width: numOutEps);
    addOutput('out_ep_acked', width: numOutEps);
    // The size class of the packet that out_ep_acked reports. High when
    // that packet carried a full maxPacketSize payload, low when it was
    // shorter (a short packet or a zero-length packet). A bulk transfer
    // ends on a short or zero-length packet, so this tells a consumer
    // whether the next packet continues the same transfer.
    addOutput('out_ep_pkt_full', width: numOutEps);
    createPort('out_ep_grant', PortDirection.input, width: numOutEps);

    createPort('rx_pkt_start', PortDirection.input);
    createPort('rx_pkt_end', PortDirection.input);
    createPort('rx_pkt_valid', PortDirection.input);
    createPort('rx_pid', PortDirection.input, width: 4);
    createPort('rx_addr', PortDirection.input, width: 7);
    createPort('rx_endp', PortDirection.input, width: 4);
    createPort('rx_frame_num', PortDirection.input, width: 11);
    createPort('rx_data_put', PortDirection.input);
    createPort('rx_data', PortDirection.input, width: 8);

    addOutput('tx_pkt_start');
    createPort('tx_pkt_end', PortDirection.input);
    addOutput('tx_pid', width: 4);

    final clk = input('clk');
    final reset = input('reset');
    final resetEp = input('reset_ep');
    final devAddr = input('dev_addr');
    final outEpDataGet = input('out_ep_data_get');
    final outEpStall = input('out_ep_stall');
    final outEpGrant = input('out_ep_grant');
    final rxPktStart = input('rx_pkt_start');
    final rxPktEnd = input('rx_pkt_end');
    final rxPktValid = input('rx_pkt_valid');
    final rxPid = input('rx_pid');
    final rxAddr = input('rx_addr');
    final rxEndp = input('rx_endp');
    final rxDataPut = input('rx_data_put');
    final rxData = input('rx_data');

    // Endpoint states.
    const stReady = 0;
    const stPutting = 1;
    const stGetting = 2;
    const stStall = 3;

    final epState = List.generate(
      numOutEps,
      (ep) => Logic(name: 'ep_state_$ep', width: 2),
    );
    final epStateNext = List.generate(
      numOutEps,
      (ep) => Logic(name: 'ep_state_next_$ep', width: 2),
    );
    final epGetAddr = List.generate(
      numOutEps,
      (ep) => Logic(name: 'ep_get_addr_$ep', width: 6),
    );
    final epGetAddrNext = List.generate(
      numOutEps,
      (ep) => Logic(name: 'ep_get_addr_next_$ep', width: 6),
    );
    final epPutAddr = List.generate(
      numOutEps,
      (ep) => Logic(name: 'ep_put_addr_$ep', width: 6),
    );
    final dataToggle = List.generate(
      numOutEps,
      (ep) => Logic(name: 'data_toggle_$ep'),
    );

    final buffer = List.generate(numOutEps, (ep) {
      return List.generate(
        maxPacketSize,
        (i) => Logic(name: 'out_buf_${ep}_$i', width: 8),
      );
    });

    // Transfer states.
    const xfrIdle = 0;
    const xfrRcvdOut = 1;
    const xfrRcvdDataStart = 2;
    const xfrRcvdDataEnd = 3;

    final outXfrState = Logic(name: 'out_xfr_state', width: 2);
    final outXfrStateNext = Logic(name: 'out_xfr_state_next', width: 2);
    final outXfrStart = Logic(name: 'out_xfr_start');
    final newPktEnd = Logic(name: 'new_pkt_end');
    final rollbackData = Logic(name: 'rollback_data');
    final nakOutTransfer = Logic(name: 'nak_out_transfer');

    final currentEndp = Logic(name: 'current_endp', width: 4);

    final txPktStart = Logic(name: 'tx_pkt_start_i');
    final txPid = Logic(name: 'tx_pid_i', width: 4);

    final outEpSetup = Logic(name: 'out_ep_setup_i', width: numOutEps);
    final ackedBits = List.generate(
      numOutEps,
      (ep) => Logic(name: 'acked_$ep'),
    );
    final availBits = List.generate(
      numOutEps,
      (ep) => Logic(name: 'avail_$ep'),
    );
    final pktFullBits = List.generate(
      numOutEps,
      (ep) => Logic(name: 'pkt_full_$ep'),
    );

    // ------------------------------------------------------------------
    // Token and packet decode.
    // ------------------------------------------------------------------
    final tokenReceived =
        (rxPktEnd &
                rxPktValid &
                rxPid.slice(1, 0).eq(Const(1, width: 2)) &
                rxAddr.eq(devAddr) &
                rxEndp.lt(Const(numOutEps, width: 4)))
            .named('token_received');

    final outTokenReceived =
        (tokenReceived & rxPid.slice(3, 2).eq(Const(0, width: 2))).named(
          'out_token_received',
        );

    final setupTokenReceived =
        (tokenReceived & rxPid.slice(3, 2).eq(Const(3, width: 2))).named(
          'setup_token_received',
        );

    final invalidPacketReceived = (rxPktEnd & ~rxPktValid).named(
      'invalid_packet_received',
    );

    final dataPacketReceived =
        (rxPktEnd & rxPktValid & rxPid.slice(2, 0).eq(Const(3, width: 3)))
            .named('data_packet_received');

    final nonDataPacketReceived =
        (rxPktEnd & rxPktValid & ~rxPid.slice(2, 0).eq(Const(3, width: 3)))
            .named('non_data_packet_received');

    // Bad data toggle: the received PID toggle bit must match the
    // targeted endpoint toggle.
    Logic endpToggle = Const(0);
    for (var ep = 0; ep < numOutEps; ep++) {
      endpToggle = mux(
        rxEndp.eq(Const(ep, width: 4)),
        dataToggle[ep],
        endpToggle,
      );
    }

    final badDataToggle =
        (dataPacketReceived & ~rxPid.slice(3, 3).eq(endpToggle)).named(
          'bad_data_toggle',
        );

    // ------------------------------------------------------------------
    // Current-endpoint state select.
    // ------------------------------------------------------------------
    Logic currentEpState = epState[0];
    for (var ep = 1; ep < numOutEps; ep++) {
      currentEpState = mux(
        currentEndp.eq(Const(ep, width: 4)),
        epState[ep],
        currentEpState,
      );
    }

    final currentEpBusy =
        (currentEpState.eq(Const(stGetting, width: 2)) |
                currentEpState.eq(Const(stReady, width: 2)))
            .named('current_ep_busy');

    // The ACK branch condition for the data-end state.
    final ackBranch =
        (outXfrState.eq(Const(xfrRcvdDataEnd, width: 2)) &
                ~currentEpState.eq(Const(stStall, width: 2)) &
                ~nakOutTransfer)
            .named('ack_branch');

    // ------------------------------------------------------------------
    // The transfer state machine (combinational next state).
    // ------------------------------------------------------------------
    Combinational([
      outXfrStateNext < outXfrState,
      outXfrStart < Const(0),
      txPktStart < Const(0),
      txPid < Const(0, width: 4),
      newPktEnd < Const(0),
      rollbackData < Const(0),

      Case(
        outXfrState,
        [
          CaseItem(Const(xfrIdle, width: 2), [
            If(
              outTokenReceived | setupTokenReceived,
              then: [
                outXfrStateNext < Const(xfrRcvdOut, width: 2),
                outXfrStart < Const(1),
              ],
              orElse: [outXfrStateNext < Const(xfrIdle, width: 2)],
            ),
          ]),
          CaseItem(Const(xfrRcvdOut, width: 2), [
            If(
              rxPktStart,
              then: [outXfrStateNext < Const(xfrRcvdDataStart, width: 2)],
              orElse: [outXfrStateNext < Const(xfrRcvdOut, width: 2)],
            ),
          ]),
          CaseItem(Const(xfrRcvdDataStart, width: 2), [
            If(
              badDataToggle,
              then: [
                outXfrStateNext < Const(xfrIdle, width: 2),
                rollbackData < Const(1),
                txPktStart < Const(1),
                txPid < Const(2, width: 4),
              ],
              orElse: [
                If(
                  invalidPacketReceived | nonDataPacketReceived,
                  then: [
                    outXfrStateNext < Const(xfrIdle, width: 2),
                    rollbackData < Const(1),
                  ],
                  orElse: [
                    If(
                      dataPacketReceived,
                      then: [outXfrStateNext < Const(xfrRcvdDataEnd, width: 2)],
                      orElse: [
                        outXfrStateNext < Const(xfrRcvdDataStart, width: 2),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ]),
          CaseItem(Const(xfrRcvdDataEnd, width: 2), [
            outXfrStateNext < Const(xfrIdle, width: 2),
            txPktStart < Const(1),
            If(
              currentEpState.eq(Const(stStall, width: 2)),
              then: [txPid < Const(14, width: 4)],
              orElse: [
                If(
                  nakOutTransfer,
                  then: [txPid < Const(10, width: 4), rollbackData < Const(1)],
                  orElse: [txPid < Const(2, width: 4), newPktEnd < Const(1)],
                ),
              ],
            ),
          ]),
        ],
        defaultItem: [outXfrStateNext < Const(xfrIdle, width: 2)],
      ),
    ]);

    output('tx_pkt_start') <= txPktStart;
    output('tx_pid') <= txPid;

    // ------------------------------------------------------------------
    // Per-endpoint combinational: acked, next state, get address next,
    // data available.
    // ------------------------------------------------------------------
    for (var ep = 0; ep < numOutEps; ep++) {
      Combinational([
        // The acked vector bit: the ACK branch for the current endpoint.
        ackedBits[ep] < ackBranch & currentEndp.eq(Const(ep, width: 4)),

        // The put address holds the payload bytes plus the two CRC16
        // bytes when the ACK branch runs, because it only steps in the
        // data-start state. A full packet therefore puts maxPacketSize
        // plus two bytes.
        pktFullBits[ep] <
            ackedBits[ep] &
                epPutAddr[ep].eq(Const(maxPacketSize + 2, width: 6)),

        epStateNext[ep] < epState[ep],
        If(
          outEpStall.slice(ep, ep),
          then: [epStateNext[ep] < Const(stStall, width: 2)],
          orElse: [
            Case(
              epState[ep],
              [
                CaseItem(Const(stReady, width: 2), [
                  If(
                    outXfrStart & rxEndp.eq(Const(ep, width: 4)),
                    then: [epStateNext[ep] < Const(stPutting, width: 2)],
                    orElse: [epStateNext[ep] < Const(stReady, width: 2)],
                  ),
                ]),
                CaseItem(Const(stPutting, width: 2), [
                  If(
                    newPktEnd & currentEndp.eq(Const(ep, width: 4)),
                    then: [epStateNext[ep] < Const(stGetting, width: 2)],
                    orElse: [
                      If(
                        rollbackData & currentEndp.eq(Const(ep, width: 4)),
                        then: [epStateNext[ep] < Const(stReady, width: 2)],
                        orElse: [epStateNext[ep] < Const(stPutting, width: 2)],
                      ),
                    ],
                  ),
                ]),
                CaseItem(Const(stGetting, width: 2), [
                  If(
                    epGetAddr[ep].gte(epPutAddr[ep] - Const(2, width: 6)),
                    then: [epStateNext[ep] < Const(stReady, width: 2)],
                    orElse: [epStateNext[ep] < Const(stGetting, width: 2)],
                  ),
                ]),
                CaseItem(Const(stStall, width: 2), [
                  If(
                    setupTokenReceived & rxEndp.eq(Const(ep, width: 4)),
                    then: [epStateNext[ep] < Const(stReady, width: 2)],
                    orElse: [epStateNext[ep] < Const(stStall, width: 2)],
                  ),
                ]),
              ],
              defaultItem: [epStateNext[ep] < Const(stReady, width: 2)],
            ),
          ],
        ),
        If(
          epStateNext[ep].eq(Const(stReady, width: 2)),
          then: [epGetAddrNext[ep] < Const(0, width: 6)],
          orElse: [
            If(
              epStateNext[ep].eq(Const(stGetting, width: 2)) &
                  outEpDataGet.slice(ep, ep),
              then: [epGetAddrNext[ep] < epGetAddr[ep] + Const(1, width: 6)],
              orElse: [epGetAddrNext[ep] < epGetAddr[ep]],
            ),
          ],
        ),
        availBits[ep] <
            epGetAddr[ep].lt(epPutAddr[ep] - Const(2, width: 6)) &
                epState[ep].eq(Const(stGetting, width: 2)),
      ]);
    }

    output('out_ep_data_avail') <= availBits.rswizzle();
    output('out_ep_acked') <= ackedBits.rswizzle();
    output('out_ep_pkt_full') <= pktFullBits.rswizzle();

    // ------------------------------------------------------------------
    // Per-endpoint sequential: state and get address.
    // ------------------------------------------------------------------
    for (var ep = 0; ep < numOutEps; ep++) {
      Sequential(clk, [
        If(
          reset | resetEp.slice(ep, ep),
          then: [epState[ep] < Const(stReady, width: 2)],
          orElse: [epState[ep] < epStateNext[ep]],
        ),
        epGetAddr[ep] < epGetAddrNext[ep],
      ]);
    }

    // ------------------------------------------------------------------
    // The setup flag: SETUP sets it, OUT clears it, per endpoint.
    // ------------------------------------------------------------------
    {
      Logic setupNext = outEpSetup;
      for (var ep = 0; ep < numOutEps; ep++) {
        setupNext = mux(
          setupTokenReceived & rxEndp.eq(Const(ep, width: 4)),
          outEpSetup | Const(1 << ep, width: numOutEps),
          setupNext,
        );
        setupNext = mux(
          outTokenReceived & rxEndp.eq(Const(ep, width: 4)),
          outEpSetup & ~Const(1 << ep, width: numOutEps),
          setupNext,
        );
      }
      Sequential(clk, [
        If(
          reset,
          then: [outEpSetup < Const(0, width: numOutEps)],
          orElse: [outEpSetup < setupNext],
        ),
        for (var ep = 0; ep < numOutEps; ep++)
          If(
            resetEp.slice(ep, ep),
            then: [outEpSetup < outEpSetup & ~Const(1 << ep, width: numOutEps)],
          ),
      ]);
    }
    output('out_ep_setup') <= outEpSetup;

    // ------------------------------------------------------------------
    // The endpoint number decode from the grant: the highest granted
    // index wins.
    // ------------------------------------------------------------------
    final outEpNum = Logic(name: 'out_ep_num', width: 4);
    Combinational([
      outEpNum < Const(0, width: 4),
      for (var ep = 0; ep < numOutEps; ep++)
        If(outEpGrant.slice(ep, ep), then: [outEpNum < Const(ep, width: 4)]),
    ]);

    // ------------------------------------------------------------------
    // The registered buffer read for out_ep_data.
    // ------------------------------------------------------------------
    Logic readMux = Const(0, width: 8);
    for (var ep = 0; ep < numOutEps; ep++) {
      Logic epMux = Const(0, width: 8);
      for (var i = 0; i < maxPacketSize; i++) {
        epMux = mux(
          epGetAddr[ep].slice(4, 0).eq(Const(i, width: 5)),
          buffer[ep][i],
          epMux,
        );
      }
      readMux = mux(outEpNum.eq(Const(ep, width: 4)), epMux, readMux);
    }
    final outEpData = Logic(name: 'out_ep_data_i', width: 8);
    Sequential(clk, [outEpData < readMux]);
    output('out_ep_data') <= outEpData;

    // ------------------------------------------------------------------
    // Shared sequential: the transfer state, the endpoint latch and
    // the NAK decision.
    // ------------------------------------------------------------------
    Sequential(clk, [
      If(
        reset,
        then: [
          outXfrState < Const(xfrIdle, width: 2),
          // The original declares current_endp and nak_out_transfer
          // with initial values of 0. Without a reset they stay
          // unknown and make the endpoint selects unknown.
          currentEndp < Const(0, width: 4),
          nakOutTransfer < Const(0),
        ],
        orElse: [
          outXfrState < outXfrStateNext,
          If(outXfrStart, then: [currentEndp < rxEndp]),
          If(
            outXfrState.eq(Const(xfrRcvdOut, width: 2)),
            then: [
              If(
                currentEpBusy,
                then: [nakOutTransfer < Const(1)],
                orElse: [nakOutTransfer < Const(0)],
              ),
            ],
          ),
        ],
      ),
    ]);

    // ------------------------------------------------------------------
    // Per-endpoint sequential: toggles, put addresses and buffer writes.
    // The reset_ep override comes last so it wins, as in the original.
    // ------------------------------------------------------------------
    for (var ep = 0; ep < numOutEps; ep++) {
      final isCurrent = currentEndp.eq(Const(ep, width: 4));
      Sequential(clk, [
        If(
          ~reset,
          then: [
            If(newPktEnd & isCurrent, then: [dataToggle[ep] < ~dataToggle[ep]]),
            If(
              setupTokenReceived & rxEndp.eq(Const(ep, width: 4)),
              then: [dataToggle[ep] < Const(0)],
            ),
            If(
              outXfrState.eq(Const(xfrRcvdOut, width: 2)) &
                  ~currentEpBusy &
                  isCurrent,
              then: [epPutAddr[ep] < Const(0, width: 6)],
            ),
            If(
              outXfrState.eq(Const(xfrRcvdDataStart, width: 2)),
              then: [
                // Buffer write: rx_data lands at the put address.
                for (var i = 0; i < maxPacketSize; i++)
                  If(
                    ~nakOutTransfer &
                        isCurrent &
                        rxDataPut &
                        ~epPutAddr[ep].slice(5, 5) &
                        epPutAddr[ep].slice(4, 0).eq(Const(i, width: 5)),
                    then: [buffer[ep][i] < rxData],
                  ),
                If(
                  ~nakOutTransfer & isCurrent & rxDataPut,
                  then: [epPutAddr[ep] < epPutAddr[ep] + Const(1, width: 6)],
                ),
              ],
            ),
          ],
        ),
        If(
          reset | resetEp.slice(ep, ep),
          then: [dataToggle[ep] < Const(0), epPutAddr[ep] < Const(0, width: 6)],
        ),
      ]);
    }
  }
}

/// USB bus reset detector, ported from usb_reset_det.v.
///
/// Asserts the reset output after the line stays single-ended zero for
/// about 625 us at 48 MHz. An EOP (two bit times of SE0, about 166 ns)
/// never reaches the threshold.
class HarborUsbFsResetDet extends BridgeModule {
  HarborUsbFsResetDet({String? name})
    : super('HarborUsbFsResetDet', name: name ?? 'usb_fs_reset_det') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    addOutput('bus_reset');
    createPort('usb_p_rx', PortDirection.input);
    createPort('usb_n_rx', PortDirection.input);

    final clk = input('clk');
    final reset = input('reset');
    final usbPRx = input('usb_p_rx');
    final usbNRx = input('usb_n_rx');

    final resetTimer = Logic(name: 'reset_timer', width: 17);
    final resetI = Logic(name: 'reset_i');

    final timerExpired = resetTimer
        .gt(Const(30000, width: 17))
        .named('timer_expired');

    // The power-on reset clears the detector so an undefined line
    // before the pads settle cannot poison the reset output.
    Sequential(clk, [
      If(reset, then: [resetI < Const(0)], orElse: [resetI < timerExpired]),
    ]);
    output('bus_reset') <= resetI;

    Sequential(clk, [
      If(
        reset,
        then: [resetTimer < Const(0, width: 17)],
        orElse: [
          If(
            usbPRx | usbNRx,
            then: [resetTimer < Const(0, width: 17)],
            orElse: [
              If(
                ~timerExpired,
                then: [resetTimer < resetTimer + Const(1, width: 17)],
              ),
            ],
          ),
        ],
      ),
    ]);
  }
}

/// The composed full-speed USB protocol engine, ported from usb_fs_pe.v.
///
/// Wires the line receiver and transmitter with the IN and OUT endpoint
/// protocol engines, the endpoint arbiters and the TX mux. Exposes the
/// per-endpoint byte-stream interfaces plus the raw line signals.
class HarborUsbFsPe extends BridgeModule {
  /// Number of OUT endpoints.
  final int numOutEps;

  /// Number of IN endpoints.
  final int numInEps;

  /// Maximum packet payload per endpoint, in bytes.
  final int maxPacketSize;

  HarborUsbFsPe({
    this.numOutEps = 1,
    this.numInEps = 1,
    this.maxPacketSize = 32,
    String? name,
  }) : super('HarborUsbFsPe', name: name ?? 'usb_fs_pe') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('dev_addr', PortDirection.input, width: 7);

    // OUT endpoint interface.
    createPort('out_ep_req', PortDirection.input, width: numOutEps);
    addOutput('out_ep_grant', width: numOutEps);
    addOutput('out_ep_data_avail', width: numOutEps);
    addOutput('out_ep_setup', width: numOutEps);
    createPort('out_ep_data_get', PortDirection.input, width: numOutEps);
    addOutput('out_ep_data', width: 8);
    createPort('out_ep_stall', PortDirection.input, width: numOutEps);
    addOutput('out_ep_acked', width: numOutEps);
    addOutput('out_ep_pkt_full', width: numOutEps);

    // IN endpoint interface.
    createPort('in_ep_req', PortDirection.input, width: numInEps);
    addOutput('in_ep_grant', width: numInEps);
    addOutput('in_ep_data_free', width: numInEps);
    createPort('in_ep_data_put', PortDirection.input, width: numInEps);
    createPort('in_ep_data', PortDirection.input, width: numInEps * 8);
    createPort('in_ep_data_done', PortDirection.input, width: numInEps);
    createPort('in_ep_stall', PortDirection.input, width: numInEps);
    addOutput('in_ep_acked', width: numInEps);

    // SOF interface.
    addOutput('sof_valid');
    addOutput('frame_index', width: 11);

    // Line interface.
    addOutput('usb_p_tx');
    addOutput('usb_n_tx');
    createPort('usb_p_rx', PortDirection.input);
    createPort('usb_n_rx', PortDirection.input);
    addOutput('usb_tx_en');

    final clk = input('clk');
    final reset = input('reset');
    final devAddr = input('dev_addr');
    final outEpReq = input('out_ep_req');
    final outEpDataGet = input('out_ep_data_get');
    final outEpStall = input('out_ep_stall');
    final inEpReq = input('in_ep_req');
    final inEpData = input('in_ep_data');
    final inEpDataPut = input('in_ep_data_put');
    final inEpDataDone = input('in_ep_data_done');
    final inEpStall = input('in_ep_stall');

    // ------------------------------------------------------------------
    // The line receiver.
    // ------------------------------------------------------------------
    final rx = HarborUsbFsRx(name: 'fs_rx');
    addSubModule(rx);
    rx.input('clk').srcConnection! <= clk;
    rx.input('reset').srcConnection! <= reset;
    rx.input('dp').srcConnection! <= input('usb_p_rx');
    rx.input('dn').srcConnection! <= input('usb_n_rx');

    output('sof_valid') <=
        rx.output('pkt_end') &
            rx.output('valid_packet') &
            rx.output('pid').eq(Const(5, width: 4));
    output('frame_index') <= rx.output('frame_num');

    // ------------------------------------------------------------------
    // The endpoint arbiters. The lowest requesting endpoint wins; the
    // granted endpoint's data byte feeds the IN engine.
    // ------------------------------------------------------------------
    final outGrantBits = List.generate(
      numOutEps,
      (ep) => Logic(name: 'out_grant_$ep'),
    );
    {
      Logic granted = Const(0);
      for (var ep = 0; ep < numOutEps; ep++) {
        outGrantBits[ep] <= outEpReq.slice(ep, ep) & ~granted;
        granted = granted | outEpReq.slice(ep, ep);
      }
    }
    output('out_ep_grant') <= outGrantBits.rswizzle();

    final inGrantBits = List.generate(
      numInEps,
      (ep) => Logic(name: 'in_grant_$ep'),
    );
    Logic arbInEpData = Const(0, width: 8);
    {
      Logic granted = Const(0);
      for (var ep = 0; ep < numInEps; ep++) {
        inGrantBits[ep] <= inEpReq.slice(ep, ep) & ~granted;
        arbInEpData = mux(
          inEpReq.slice(ep, ep) & ~granted,
          inEpData.slice(ep * 8 + 7, ep * 8),
          arbInEpData,
        );
        granted = granted | inEpReq.slice(ep, ep);
      }
    }
    output('in_ep_grant') <= inGrantBits.rswizzle();

    // ------------------------------------------------------------------
    // Nets driven by the transmitter below: packet end and the data
    // pull signal, which flows from the transmitter to the IN engine.
    // ------------------------------------------------------------------
    final txPktEndNet = Logic(name: 'tx_pkt_end_net');
    final txDataGetNet = Logic(name: 'tx_data_get_net');

    // ------------------------------------------------------------------
    // The IN protocol engine.
    // ------------------------------------------------------------------
    final inPe = HarborUsbFsInPe(
      numInEps: numInEps,
      maxPacketSize: maxPacketSize,
      name: 'fs_in_pe',
    );
    addSubModule(inPe);
    inPe.input('clk').srcConnection! <= clk;
    inPe.input('reset').srcConnection! <= reset;
    inPe.input('reset_ep').srcConnection! <= Const(0, width: numInEps);
    inPe.input('dev_addr').srcConnection! <= devAddr;

    inPe.input('in_ep_data_put').srcConnection! <= inEpDataPut;
    inPe.input('in_ep_data').srcConnection! <= arbInEpData;
    inPe.input('in_ep_data_done').srcConnection! <= inEpDataDone;
    inPe.input('in_ep_stall').srcConnection! <= inEpStall;

    inPe.input('rx_pkt_start').srcConnection! <= rx.output('pkt_start');
    inPe.input('rx_pkt_end').srcConnection! <= rx.output('pkt_end');
    inPe.input('rx_pkt_valid').srcConnection! <= rx.output('valid_packet');
    inPe.input('rx_pid').srcConnection! <= rx.output('pid');
    inPe.input('rx_addr').srcConnection! <= rx.output('addr');
    inPe.input('rx_endp').srcConnection! <= rx.output('endp');
    inPe.input('rx_frame_num').srcConnection! <= rx.output('frame_num');

    inPe.input('tx_pkt_end').srcConnection! <= txPktEndNet;
    inPe.input('tx_data_get').srcConnection! <= txDataGetNet;

    output('in_ep_data_free') <= inPe.output('in_ep_data_free');
    output('in_ep_acked') <= inPe.output('in_ep_acked');

    // ------------------------------------------------------------------
    // The OUT protocol engine.
    // ------------------------------------------------------------------
    final outPe = HarborUsbFsOutPe(
      numOutEps: numOutEps,
      maxPacketSize: maxPacketSize,
      name: 'fs_out_pe',
    );
    addSubModule(outPe);
    outPe.input('clk').srcConnection! <= clk;
    outPe.input('reset').srcConnection! <= reset;
    outPe.input('reset_ep').srcConnection! <= Const(0, width: numOutEps);
    outPe.input('dev_addr').srcConnection! <= devAddr;

    outPe.input('out_ep_data_get').srcConnection! <= outEpDataGet;
    outPe.input('out_ep_stall').srcConnection! <= outEpStall;
    outPe.input('out_ep_grant').srcConnection! <= outGrantBits.rswizzle();

    outPe.input('rx_pkt_start').srcConnection! <= rx.output('pkt_start');
    outPe.input('rx_pkt_end').srcConnection! <= rx.output('pkt_end');
    outPe.input('rx_pkt_valid').srcConnection! <= rx.output('valid_packet');
    outPe.input('rx_pid').srcConnection! <= rx.output('pid');
    outPe.input('rx_addr').srcConnection! <= rx.output('addr');
    outPe.input('rx_endp').srcConnection! <= rx.output('endp');
    outPe.input('rx_frame_num').srcConnection! <= rx.output('frame_num');
    outPe.input('rx_data_put').srcConnection! <= rx.output('rx_data_put');
    outPe.input('rx_data').srcConnection! <= rx.output('rx_data');

    outPe.input('tx_pkt_end').srcConnection! <= txPktEndNet;

    output('out_ep_data_avail') <= outPe.output('out_ep_data_avail');
    output('out_ep_setup') <= outPe.output('out_ep_setup');
    output('out_ep_data') <= outPe.output('out_ep_data');
    output('out_ep_acked') <= outPe.output('out_ep_acked');
    output('out_ep_pkt_full') <= outPe.output('out_ep_pkt_full');

    // ------------------------------------------------------------------
    // The TX mux: the OUT engine wins when it starts a packet.
    // ------------------------------------------------------------------
    final txPktStartNet =
        (inPe.output('tx_pkt_start') | outPe.output('tx_pkt_start')).named(
          'tx_pkt_start_mux',
        );
    final txPidNet = mux(
      outPe.output('tx_pkt_start'),
      outPe.output('tx_pid'),
      inPe.output('tx_pid'),
    ).named('tx_pid_mux');

    // ------------------------------------------------------------------
    // The line transmitter.
    // ------------------------------------------------------------------
    final tx = HarborUsbFsTx(name: 'fs_tx');
    addSubModule(tx);
    tx.input('clk').srcConnection! <= clk;
    tx.input('reset').srcConnection! <= reset;
    tx.input('bit_strobe').srcConnection! <= rx.output('bit_strobe');
    tx.input('pkt_start').srcConnection! <= txPktStartNet;
    tx.input('pid').srcConnection! <= txPidNet;
    tx.input('tx_data_avail').srcConnection! <= inPe.output('tx_data_avail');
    tx.input('tx_data').srcConnection! <= inPe.output('tx_data');

    txPktEndNet <= tx.output('pkt_end');
    txDataGetNet <= tx.output('tx_data_get');

    output('usb_p_tx') <= tx.output('dp');
    output('usb_n_tx') <= tx.output('dn');
    output('usb_tx_en') <= tx.output('oe');
  }
}
