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

// Bus turnaround timeout in clock cycles at 4 cycles per bit (USB 2.0
// 7.1.19.1). The response SYNC must start within 18 bit times. The
// receiver flags it after the 8 SYNC bits and about 1 bit of delay.
const _turnaroundCycles = (18 + 8 + 1) * 4;

// Hard limit on the handshake wait, from the end of the IN data packet. A
// legal handshake or token is flagged by the turnaround timeout and has at
// most 24 more bits, 4 stuff bits and the EOP. That is 58 bit times.
const _ackCeilingCycles = 64 * 4;

// Hard limit on an OUT data wait, from the end of the token, at 4 cycles
// per bit. The data packet starts by the turnaround timeout and has the
// PID, the payload, the CRC16, a stuff bit per 6 bits, the EOP and margin.
int _outCeilingCycles(int maxPacketSize) =>
    (27 + ((maxPacketSize + 3) * 8 * 7 + 5) ~/ 6 + 2 + 8) * 4;

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
    createPort('setup_token', PortDirection.input, width: numInEps);
    createPort('flush', PortDirection.input, width: numInEps);
    addOutput('in_ep_acked', width: numInEps);
    addOutput('busy', width: numInEps);

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
    final setupToken = input('setup_token');
    final flush = input('flush');
    final rxPktStart = input('rx_pkt_start');
    final rxPktEnd = input('rx_pkt_end');
    final rxPktValid = input('rx_pkt_valid');
    final rxPid = input('rx_pid');
    final rxAddr = input('rx_addr');
    final rxEndp = input('rx_endp');
    final txPktEnd = input('tx_pkt_end');
    final txDataGet = input('tx_data_get');

    // Endpoint states.
    const stReady = 0;
    const stPutting = 1;
    const stGetting = 2;

    final epState = List.generate(
      numInEps,
      (ep) => Logic(name: 'ep_state_$ep', width: 2),
    );
    final epStateNext = List.generate(
      numInEps,
      (ep) => Logic(name: 'ep_state_next_$ep', width: 2),
    );
    // Wide enough to hold the full-packet sentinel value maxPacketSize
    // itself, so put and get addresses never wrap before a packet fills.
    final addrWidth = maxPacketSize.bitLength;
    final epPutAddr = List.generate(
      numInEps,
      (ep) => Logic(name: 'ep_put_addr_$ep', width: addrWidth),
    );
    final epGetAddr = List.generate(
      numInEps,
      (ep) => Logic(name: 'ep_get_addr_$ep', width: addrWidth),
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

    // A put address at maxPacketSize means the buffer holds a full
    // packet. A direct comparison replaces a fixed top-bit check, which
    // only read true at maxPacketSize 32.
    final epPutFull = List.generate(
      numInEps,
      (ep) => epPutAddr[ep]
          .eq(Const(maxPacketSize, width: addrWidth))
          .named('ep_put_full_$ep'),
    );

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

    final inTokenReceived =
        (tokenReceived & rxPid.slice(3, 2).eq(Const(2, width: 2))).named(
          'in_token_received',
        );

    final ackReceived = (rxPktEnd & rxPktValid & rxPid.eq(Const(2, width: 4)))
        .named('ack_received');

    // The handshake wait starts at the end of the data packet. With no
    // packet start it ends at the turnaround timeout, and in any case at
    // the ceiling.
    final timerWidth = _ackCeilingCycles.bitLength;
    final ackTimer = Logic(name: 'ack_timer', width: timerWidth);
    final ackTimerRun = Logic(name: 'ack_timer_run');
    final ackPktSeen = Logic(name: 'ack_pkt_seen');
    final ackTimeout =
        (ackTimerRun &
                ((~ackPktSeen &
                        ~rxPktStart &
                        ackTimer.eq(
                          Const(_turnaroundCycles - 1, width: timerWidth),
                        )) |
                    ackTimer.eq(
                      Const(_ackCeilingCycles - 1, width: timerWidth),
                    )))
            .named('ack_timeout');
    Sequential(clk, [
      If(
        reset | ~inXfrState.eq(Const(xfrWaitAck, width: 2)),
        then: [
          ackTimerRun < Const(0),
          ackPktSeen < Const(0),
          ackTimer < Const(0, width: timerWidth),
        ],
        orElse: [
          If(
            txPktEnd,
            then: [
              ackTimerRun < Const(1),
              ackTimer < Const(0, width: timerWidth),
            ],
            orElse: [
              If(
                ackTimerRun,
                then: [ackTimer < ackTimer + Const(1, width: timerWidth)],
              ),
            ],
          ),
          If(rxPktStart, then: [ackPktSeen < Const(1)]),
        ],
      ),
    ]);

    // ------------------------------------------------------------------
    // Current-endpoint selects: state and data toggle.
    // ------------------------------------------------------------------
    Logic currentEpState = epState[0];
    Logic currentDataToggle = dataToggle[0];
    Logic currentStall = inEpStall[0];
    for (var ep = 1; ep < numInEps; ep++) {
      currentStall = mux(
        currentEndp.eq(Const(ep, width: 4)),
        inEpStall[ep],
        currentStall,
      );
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

    // An IN transaction on the endpoint is in progress. The token cycle
    // itself is idle.
    final busyBits = List.generate(
      numInEps,
      (ep) =>
          (~inXfrState.eq(Const(xfrIdle, width: 2)) &
                  currentEndp.eq(Const(ep, width: 4)))
              .named('busy_$ep'),
    );
    output('busy') <= busyBits.rswizzle();

    // A flush drops the packet and its bytes. It does nothing while the
    // endpoint is busy.
    final flushApply = List.generate(
      numInEps,
      (ep) => (flush[ep] & ~busyBits[ep]).named('flush_apply_$ep'),
    );

    // A toggle reset waits for the end of an IN transaction on its
    // endpoint and then sets only the toggle. A SETUP drops it.
    final togglePending = List.generate(
      numInEps,
      (ep) => Logic(name: 'toggle_pending_$ep'),
    );
    final toggleApply = List.generate(
      numInEps,
      (ep) =>
          ((resetEp[ep] | togglePending[ep]) & ~setupToken[ep] & ~busyBits[ep])
              .named('toggle_apply_$ep'),
    );
    for (var ep = 0; ep < numInEps; ep++) {
      Sequential(clk, [
        If(
          reset | setupToken[ep] | toggleApply[ep],
          then: [togglePending[ep] < Const(0)],
          orElse: [
            If(resetEp[ep], then: [togglePending[ep] < Const(1)]),
          ],
        ),
      ]);
    }

    for (var ep = 0; ep < numInEps; ep++) {
      Combinational([
        ackedBits[ep] < Const(0),
        epStateNext[ep] < epState[ep],
        Case(
          epState[ep],
          [
            CaseItem(Const(stReady, width: 2), [
              epStateNext[ep] < Const(stPutting, width: 2),
            ]),
            CaseItem(Const(stPutting, width: 2), [
              // A SETUP preempts a packet the function is still
              // writing (USB 2.0 8.5.3/9.2.6.4): drop it rather than
              // let a stale write finish arming after the request it
              // belonged to is already gone.
              If(
                setupToken[ep],
                then: [epStateNext[ep] < Const(stReady, width: 2)],
                orElse: [
                  If(
                    inEpDataDone.slice(ep, ep) | epPutFull[ep],
                    then: [epStateNext[ep] < Const(stGetting, width: 2)],
                    orElse: [epStateNext[ep] < Const(stPutting, width: 2)],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(stGetting, width: 2), [
              // Same rule for a packet already armed to send: a
              // SETUP drops it unsent.
              If(
                setupToken[ep],
                then: [epStateNext[ep] < Const(stReady, width: 2)],
                orElse: [
                  If(
                    inXfrEnd & currentEndp.eq(Const(ep, width: 4)),
                    then: [
                      epStateNext[ep] < Const(stReady, width: 2),
                      ackedBits[ep] < Const(1),
                    ],
                    orElse: [epStateNext[ep] < Const(stGetting, width: 2)],
                  ),
                ],
              ),
            ]),
          ],
          defaultItem: [epStateNext[ep] < Const(stReady, width: 2)],
        ),
        If(flushApply[ep], then: [epStateNext[ep] < Const(stReady, width: 2)]),
        dataFreeBits[ep] <
            ~epPutFull[ep] & epState[ep].eq(Const(stPutting, width: 2)),
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
          reset,
          then: [
            epState[ep] < Const(stReady, width: 2),
            // The original gives ep_put_addr an initial value of 0.
            epPutAddr[ep] < Const(0, width: addrWidth),
          ],
          orElse: [
            epState[ep] < epStateNext[ep],
            Case(epState[ep], [
              CaseItem(Const(stReady, width: 2), [
                epPutAddr[ep] < Const(0, width: addrWidth),
              ]),
              CaseItem(Const(stPutting, width: 2), [
                If(
                  inEpDataPut.slice(ep, ep) & ~epPutFull[ep],
                  then: [
                    epPutAddr[ep] < epPutAddr[ep] + Const(1, width: addrWidth),
                  ],
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
                ~epPutFull[ep] &
                epPutAddr[ep].eq(Const(i, width: addrWidth)),
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
          epGetAddr[ep].eq(Const(i, width: addrWidth)),
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
              currentStall,
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
                      rxPktEnd | ackTimeout,
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
    // Per-endpoint sequential: toggles and get addresses. The reset
    // override comes last so it wins, as in the original.
    // ------------------------------------------------------------------
    for (var ep = 0; ep < numInEps; ep++) {
      final isCurrent = currentEndp.eq(Const(ep, width: 4));
      Sequential(clk, [
        If(
          ~reset,
          then: [
            If(toggleApply[ep], then: [dataToggle[ep] < Const(0)]),
            If(setupToken[ep], then: [dataToggle[ep] < Const(1)]),
            If(
              rollbackInXfr & isCurrent,
              then: [epGetAddr[ep] < Const(0, width: addrWidth)],
            ),
            If(
              inXfrState.eq(Const(xfrSendData, width: 2)) &
                  txDataGet &
                  txDataAvail &
                  isCurrent,
              then: [
                epGetAddr[ep] < epGetAddr[ep] + Const(1, width: addrWidth),
              ],
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
          reset,
          then: [
            dataToggle[ep] < Const(0),
            epGetAddr[ep] < Const(0, width: addrWidth),
          ],
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

  /// Adds an `out_ep_length` output: each endpoint's payload length (put
  /// address minus the 2 CRC bytes). It is valid from the `out_ep_acked`
  /// cycle until the endpoint starts to receive its next packet.
  final bool exposeLength;

  /// Adds an `out_ep_release` input and an `out_ep_held` output. A received
  /// packet then stays held, and the endpoint NAKs, until a release pulse.
  /// Reading the last byte does not free the endpoint.
  final bool exposeRelease;

  /// Adds an `out_ep_setup_done` output: a one-cycle pulse per endpoint
  /// on the cycle the engine ACKs a SETUP data packet. Off by default.
  final bool exposeSetupDone;

  /// Adds an `out_ep_control` input that marks the control endpoints. Off
  /// by default, and then only endpoint 0 is a control endpoint.
  final bool exposeControl;

  HarborUsbFsOutPe({
    this.numOutEps = 1,
    this.maxPacketSize = 32,
    this.exposeLength = false,
    this.exposeRelease = false,
    this.exposeSetupDone = false,
    this.exposeControl = false,
    String? name,
  }) : super('HarborUsbFsOutPe', name: name ?? 'usb_fs_out_pe') {
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
    // The size class of the packet out_ep_acked reports: high for a full
    // maxPacketSize payload, low for a short or zero-length packet. A
    // bulk transfer ends on a short or zero-length packet, so this tells
    // a consumer whether the next packet continues the same transfer.
    addOutput('out_ep_pkt_full', width: numOutEps);
    createPort('out_ep_grant', PortDirection.input, width: numOutEps);
    if (exposeLength) {
      addOutput(
        'out_ep_length',
        width: numOutEps * (maxPacketSize + 2).bitLength,
      );
    }
    if (exposeRelease) {
      createPort('out_ep_release', PortDirection.input, width: numOutEps);
      addOutput('out_ep_held', width: numOutEps);
    }
    addOutput('out_ep_setup_token', width: numOutEps);
    if (exposeControl) {
      createPort('out_ep_control', PortDirection.input, width: numOutEps);
    }
    if (exposeSetupDone) {
      addOutput('out_ep_setup_done', width: numOutEps);
    }

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

    final epState = List.generate(
      numOutEps,
      (ep) => Logic(name: 'ep_state_$ep', width: 2),
    );
    final epStateNext = List.generate(
      numOutEps,
      (ep) => Logic(name: 'ep_state_next_$ep', width: 2),
    );
    // Wide enough to hold a full packet's payload plus its 2 CRC bytes,
    // so the put address never wraps before the packet is whole.
    final addrWidth = (maxPacketSize + 2).bitLength;
    final epGetAddr = List.generate(
      numOutEps,
      (ep) => Logic(name: 'ep_get_addr_$ep', width: addrWidth),
    );
    final epGetAddrNext = List.generate(
      numOutEps,
      (ep) => Logic(name: 'ep_get_addr_next_$ep', width: addrWidth),
    );
    final epPutAddr = List.generate(
      numOutEps,
      (ep) => Logic(name: 'ep_put_addr_$ep', width: addrWidth),
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
    final stallOutTransfer = Logic(name: 'stall_out_transfer');
    final setupXfr = Logic(name: 'setup_xfr_q');

    final currentEndp = Logic(name: 'current_endp', width: 4);

    final txPktStart = Logic(name: 'tx_pkt_start_i');
    final txPid = Logic(name: 'tx_pid_i', width: 4);

    // Set when the current packet has more bytes than the buffer holds.
    final rxOverflow = Logic(name: 'rx_overflow');

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

    // SETUP is for control endpoints only (USB 2.0 8.5.3). A SETUP to
    // another endpoint is ignored and gets no handshake.
    final controlMask = exposeControl
        ? input('out_ep_control')
        : Const(1, width: numOutEps);
    Logic rxIsControl = controlMask[0];
    for (var ep = 1; ep < numOutEps; ep++) {
      rxIsControl = mux(
        rxEndp.eq(Const(ep, width: 4)),
        controlMask[ep],
        rxIsControl,
      );
    }
    final setupTokenReceived =
        (tokenReceived & rxPid.slice(3, 2).eq(Const(3, width: 2)) & rxIsControl)
            .named('setup_token_received');

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
    Logic currentStall = outEpStall[0];
    for (var ep = 1; ep < numOutEps; ep++) {
      currentEpState = mux(
        currentEndp.eq(Const(ep, width: 4)),
        epState[ep],
        currentEpState,
      );
      currentStall = mux(
        currentEndp.eq(Const(ep, width: 4)),
        outEpStall[ep],
        currentStall,
      );
    }

    // Busy means a packet from before is still waiting to be read. A
    // SETUP is never busy: the stGetting case below leaves busy for a
    // SETUP before this flag is read.
    final currentEpBusy = currentEpState
        .eq(Const(stGetting, width: 2))
        .named('current_ep_busy');

    // The put address stops at a full payload plus CRC. One more byte
    // means the packet is too long and is dropped with no handshake.
    Logic currentPutFull = Const(0);
    for (var ep = 0; ep < numOutEps; ep++) {
      currentPutFull = mux(
        currentEndp.eq(Const(ep, width: 4)),
        epPutAddr[ep].eq(Const(maxPacketSize + 2, width: addrWidth)),
        currentPutFull,
      );
    }

    // The data packet must start within the turnaround time after the
    // token and end before the ceiling, or the transaction ends with no
    // handshake.
    final outCeiling = _outCeilingCycles(maxPacketSize);
    final timerWidth = outCeiling.bitLength;
    final dataTimer = Logic(name: 'data_timer', width: timerWidth);
    final dataTimeout =
        (outXfrState.eq(Const(xfrRcvdOut, width: 2)) &
                dataTimer.eq(Const(_turnaroundCycles - 1, width: timerWidth)) &
                ~rxPktStart)
            .named('data_timeout');
    final dataCeiling =
        (outXfrState.eq(Const(xfrRcvdDataStart, width: 2)) &
                dataTimer.eq(Const(outCeiling - 1, width: timerWidth)))
            .named('data_ceiling');
    Sequential(clk, [
      If(
        reset |
            ~(outXfrState.eq(Const(xfrRcvdOut, width: 2)) |
                outXfrState.eq(Const(xfrRcvdDataStart, width: 2))),
        then: [dataTimer < Const(0, width: timerWidth)],
        orElse: [dataTimer < dataTimer + Const(1, width: timerWidth)],
      ),
    ]);

    // The ACK branch condition for the data-end state.
    final ackBranch =
        (outXfrState.eq(Const(xfrRcvdDataEnd, width: 2)) & ~nakOutTransfer)
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
              orElse: [
                If(
                  dataTimeout,
                  then: [
                    outXfrStateNext < Const(xfrIdle, width: 2),
                    rollbackData < Const(1),
                  ],
                  orElse: [outXfrStateNext < Const(xfrRcvdOut, width: 2)],
                ),
              ],
            ),
          ]),
          CaseItem(Const(xfrRcvdDataStart, width: 2), [
            If(
              badDataToggle & ~stallOutTransfer,
              then: [
                outXfrStateNext < Const(xfrIdle, width: 2),
                rollbackData < Const(1),
                txPktStart < Const(1),
                txPid < Const(2, width: 4),
              ],
              orElse: [
                If(
                  invalidPacketReceived |
                      nonDataPacketReceived |
                      (dataPacketReceived & rxOverflow),
                  then: [
                    outXfrStateNext < Const(xfrIdle, width: 2),
                    rollbackData < Const(1),
                  ],
                  orElse: [
                    If(
                      dataPacketReceived,
                      then: [outXfrStateNext < Const(xfrRcvdDataEnd, width: 2)],
                      orElse: [
                        If(
                          dataCeiling,
                          then: [
                            outXfrStateNext < Const(xfrIdle, width: 2),
                            rollbackData < Const(1),
                          ],
                          orElse: [
                            outXfrStateNext < Const(xfrRcvdDataStart, width: 2),
                          ],
                        ),
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
              stallOutTransfer,
              then: [txPid < Const(14, width: 4), rollbackData < Const(1)],
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

    // A SETUP transfer is never stalled (USB 2.0 8.5.3).
    Sequential(clk, [
      If(
        reset,
        then: [setupXfr < Const(0)],
        orElse: [
          If(
            outXfrStart,
            then: [setupXfr < setupTokenReceived],
            orElse: [
              If(
                outXfrStateNext.eq(Const(xfrIdle, width: 2)),
                then: [setupXfr < Const(0)],
              ),
            ],
          ),
        ],
      ),
    ]);
    final setupTokenBits = List.generate(
      numOutEps,
      (ep) => setupTokenReceived & rxEndp.eq(Const(ep, width: 4)),
    );
    output('out_ep_setup_token') <= setupTokenBits.rswizzle();
    if (exposeSetupDone) {
      output('out_ep_setup_done') <=
          List.generate(
            numOutEps,
            (ep) => newPktEnd & setupXfr & currentEndp.eq(Const(ep, width: 4)),
          ).rswizzle();
    }

    // A toggle reset waits for the end of an OUT transaction on its
    // endpoint and then sets only the toggle. A held packet stays held.
    // A SETUP drops it.
    final togglePending = List.generate(
      numOutEps,
      (ep) => Logic(name: 'toggle_pending_$ep'),
    );
    final toggleApply = List.generate(
      numOutEps,
      (ep) =>
          ((resetEp[ep] | togglePending[ep]) &
                  ~setupTokenBits[ep] &
                  ~(~outXfrState.eq(Const(xfrIdle, width: 2)) &
                      currentEndp.eq(Const(ep, width: 4))))
              .named('toggle_apply_$ep'),
    );
    for (var ep = 0; ep < numOutEps; ep++) {
      Sequential(clk, [
        If(
          reset | setupTokenBits[ep] | toggleApply[ep],
          then: [togglePending[ep] < Const(0)],
          orElse: [
            If(resetEp[ep], then: [togglePending[ep] < Const(1)]),
          ],
        ),
      ]);
    }

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
                epPutAddr[ep].eq(Const(maxPacketSize + 2, width: addrWidth)),

        epStateNext[ep] < epState[ep],
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
                outXfrStart &
                    rxEndp.eq(Const(ep, width: 4)) &
                    setupTokenReceived,
                // A SETUP always preempts an unread packet from
                // before (USB 2.0 8.5.3.4): leave busy immediately,
                // whether or not that packet was ever drained.
                then: [epStateNext[ep] < Const(stPutting, width: 2)],
                orElse: [
                  If(
                    exposeRelease
                        ? input('out_ep_release').slice(ep, ep)
                        : epGetAddr[ep].gte(
                            epPutAddr[ep] - Const(2, width: addrWidth),
                          ),
                    then: [
                      // A token landing on or before the release cycle
                      // misses ready's one-cycle outXfrStart check, so
                      // this goes straight to putting. That transaction
                      // can fill it, NAK it, or end with no transfer.
                      If(
                        (outXfrStart & rxEndp.eq(Const(ep, width: 4))) |
                            (~outXfrState.eq(Const(xfrIdle, width: 2)) &
                                currentEndp.eq(Const(ep, width: 4))),
                        then: [epStateNext[ep] < Const(stPutting, width: 2)],
                        orElse: [epStateNext[ep] < Const(stReady, width: 2)],
                      ),
                    ],
                    orElse: [epStateNext[ep] < Const(stGetting, width: 2)],
                  ),
                ],
              ),
            ]),
          ],
          defaultItem: [epStateNext[ep] < Const(stReady, width: 2)],
        ),
        // Any state other than getting starts the next packet's get
        // address fresh at 0. Both the getting-to-ready move and a
        // direct getting-to-putting move (the same-cycle token race
        // above) must clear it, or the next packet reads back stale.
        If(
          epStateNext[ep].eq(Const(stGetting, width: 2)),
          then: [
            If(
              outEpDataGet.slice(ep, ep),
              then: [
                epGetAddrNext[ep] < epGetAddr[ep] + Const(1, width: addrWidth),
              ],
              orElse: [epGetAddrNext[ep] < epGetAddr[ep]],
            ),
          ],
          orElse: [epGetAddrNext[ep] < Const(0, width: addrWidth)],
        ),
        availBits[ep] <
            epGetAddr[ep].lt(epPutAddr[ep] - Const(2, width: addrWidth)) &
                epState[ep].eq(Const(stGetting, width: 2)),
      ]);
    }

    output('out_ep_data_avail') <= availBits.rswizzle();
    output('out_ep_acked') <= ackedBits.rswizzle();
    output('out_ep_pkt_full') <= pktFullBits.rswizzle();

    if (exposeLength) {
      final lengthBits = List.generate(
        numOutEps,
        (ep) =>
            (epPutAddr[ep] - Const(2, width: addrWidth)).named('ep_length_$ep'),
      );
      output('out_ep_length') <= lengthBits.rswizzle();
    }
    if (exposeRelease) {
      output('out_ep_held') <=
          List.generate(
            numOutEps,
            (ep) => epState[ep].eq(Const(stGetting, width: 2)),
          ).rswizzle();
    }

    // ------------------------------------------------------------------
    // Per-endpoint sequential: state and get address.
    // ------------------------------------------------------------------
    for (var ep = 0; ep < numOutEps; ep++) {
      Sequential(clk, [
        If(
          reset,
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
          epGetAddr[ep].eq(Const(i, width: addrWidth)),
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
          stallOutTransfer < Const(0),
          rxOverflow < Const(0),
        ],
        orElse: [
          outXfrState < outXfrStateNext,
          If(outXfrStart, then: [currentEndp < rxEndp]),
          If(
            outXfrState.eq(Const(xfrRcvdOut, width: 2)),
            then: [rxOverflow < Const(0)],
          ),
          If(
            outXfrState.eq(Const(xfrRcvdDataStart, width: 2)) &
                ~nakOutTransfer &
                rxDataPut &
                currentPutFull,
            then: [rxOverflow < Const(1)],
          ),
          If(
            outXfrState.eq(Const(xfrRcvdOut, width: 2)),
            then: [
              // A stall blocks the buffer write the same way a NAK does.
              nakOutTransfer < currentEpBusy | (currentStall & ~setupXfr),
              stallOutTransfer < currentStall & ~setupXfr,
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
            If(toggleApply[ep], then: [dataToggle[ep] < Const(0)]),
            If(newPktEnd & isCurrent, then: [dataToggle[ep] < ~dataToggle[ep]]),
            If(
              setupTokenReceived & rxEndp.eq(Const(ep, width: 4)),
              then: [dataToggle[ep] < Const(0)],
            ),
            If(
              outXfrState.eq(Const(xfrRcvdOut, width: 2)) &
                  ~currentEpBusy &
                  isCurrent,
              then: [epPutAddr[ep] < Const(0, width: addrWidth)],
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
                        epPutAddr[ep].lt(
                          Const(maxPacketSize, width: addrWidth),
                        ) &
                        epPutAddr[ep].eq(Const(i, width: addrWidth)),
                    then: [buffer[ep][i] < rxData],
                  ),
                If(
                  ~nakOutTransfer &
                      isCurrent &
                      rxDataPut &
                      ~epPutAddr[ep].eq(
                        Const(maxPacketSize + 2, width: addrWidth),
                      ),
                  then: [
                    epPutAddr[ep] < epPutAddr[ep] + Const(1, width: addrWidth),
                  ],
                ),
              ],
            ),
          ],
        ),
        If(
          reset,
          then: [
            dataToggle[ep] < Const(0),
            epPutAddr[ep] < Const(0, width: addrWidth),
          ],
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
///
/// The stall inputs are levels. A stalled endpoint answers STALL to a
/// transaction that starts while its stall is high. A packet that is
/// already held or armed stays. A SETUP to a control endpoint is always
/// ACKed, and a SETUP to another endpoint gets no handshake.
class HarborUsbFsPe extends BridgeModule {
  /// Number of OUT endpoints.
  final int numOutEps;

  /// Number of IN endpoints.
  final int numInEps;

  /// Maximum packet payload per endpoint, in bytes.
  final int maxPacketSize;

  /// Adds `out_ep_toggle_reset`/`in_ep_toggle_reset` inputs. A pulse sets
  /// the endpoint's next toggle to DATA0 (USB 2.0 9.4.5) when no
  /// transaction on that endpoint is in progress. It does not change a
  /// held packet, a buffer or a stall. Off by default.
  final bool exposeEpToggleReset;

  /// Adds an `out_ep_length` output (see [HarborUsbFsOutPe.exposeLength]).
  /// Off by default: a caller that does not pass this keeps the exact
  /// original port list.
  final bool exposeEpLength;

  /// Adds `out_ep_release` and `out_ep_held` (see
  /// [HarborUsbFsOutPe.exposeRelease]). Off by default.
  final bool exposeEpRelease;

  /// Adds an `out_ep_setup_done` output (see
  /// [HarborUsbFsOutPe.exposeSetupDone]). Off by default.
  final bool exposeEpSetupDone;

  /// Adds an `out_ep_control` input (see [HarborUsbFsOutPe.exposeControl]).
  /// Off by default.
  final bool exposeEpControl;

  /// Adds an `in_ep_flush` input and an `in_ep_busy` output. A flush pulse
  /// drops the endpoint's IN packet and buffered bytes, and is ignored
  /// while `in_ep_busy` shows an IN transaction on it. Off by default.
  final bool exposeEpFlush;

  HarborUsbFsPe({
    this.numOutEps = 1,
    this.numInEps = 1,
    this.maxPacketSize = 32,
    this.exposeEpToggleReset = false,
    this.exposeEpLength = false,
    this.exposeEpRelease = false,
    this.exposeEpSetupDone = false,
    this.exposeEpControl = false,
    this.exposeEpFlush = false,
    String? name,
  }) : super('HarborUsbFsPe', name: name ?? 'usb_fs_pe') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('dev_addr', PortDirection.input, width: 7);
    if (exposeEpToggleReset) {
      createPort('out_ep_toggle_reset', PortDirection.input, width: numOutEps);
      createPort('in_ep_toggle_reset', PortDirection.input, width: numInEps);
    }

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
    if (exposeEpLength) {
      addOutput(
        'out_ep_length',
        width: numOutEps * (maxPacketSize + 2).bitLength,
      );
    }
    if (exposeEpRelease) {
      createPort('out_ep_release', PortDirection.input, width: numOutEps);
      addOutput('out_ep_held', width: numOutEps);
    }
    if (exposeEpSetupDone) {
      addOutput('out_ep_setup_done', width: numOutEps);
    }
    addOutput('out_ep_setup_token', width: numOutEps);
    if (exposeEpControl) {
      createPort('out_ep_control', PortDirection.input, width: numOutEps);
    }

    // IN endpoint interface.
    createPort('in_ep_req', PortDirection.input, width: numInEps);
    addOutput('in_ep_grant', width: numInEps);
    addOutput('in_ep_data_free', width: numInEps);
    createPort('in_ep_data_put', PortDirection.input, width: numInEps);
    createPort('in_ep_data', PortDirection.input, width: numInEps * 8);
    createPort('in_ep_data_done', PortDirection.input, width: numInEps);
    createPort('in_ep_stall', PortDirection.input, width: numInEps);
    addOutput('in_ep_acked', width: numInEps);
    if (exposeEpFlush) {
      createPort('in_ep_flush', PortDirection.input, width: numInEps);
      addOutput('in_ep_busy', width: numInEps);
    }

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
    // The endpoint arbiters. The lowest requesting endpoint wins. The
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
    inPe.input('reset_ep').srcConnection! <=
        (exposeEpToggleReset
            ? input('in_ep_toggle_reset')
            : Const(0, width: numInEps));
    inPe.input('dev_addr').srcConnection! <= devAddr;

    inPe.input('in_ep_data_put').srcConnection! <= inEpDataPut;
    inPe.input('in_ep_data').srcConnection! <= arbInEpData;
    inPe.input('in_ep_data_done').srcConnection! <= inEpDataDone;
    inPe.input('in_ep_stall').srcConnection! <= inEpStall;
    inPe.input('flush').srcConnection! <=
        (exposeEpFlush ? input('in_ep_flush') : Const(0, width: numInEps));

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
    if (exposeEpFlush) output('in_ep_busy') <= inPe.output('busy');

    // ------------------------------------------------------------------
    // The OUT protocol engine.
    // ------------------------------------------------------------------
    final outPe = HarborUsbFsOutPe(
      numOutEps: numOutEps,
      maxPacketSize: maxPacketSize,
      exposeLength: exposeEpLength,
      exposeRelease: exposeEpRelease,
      exposeSetupDone: exposeEpSetupDone,
      exposeControl: exposeEpControl,
      name: 'fs_out_pe',
    );
    addSubModule(outPe);
    outPe.input('clk').srcConnection! <= clk;
    outPe.input('reset').srcConnection! <= reset;
    outPe.input('reset_ep').srcConnection! <=
        (exposeEpToggleReset
            ? input('out_ep_toggle_reset')
            : Const(0, width: numOutEps));
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
    if (exposeEpLength) {
      output('out_ep_length') <= outPe.output('out_ep_length');
    }
    if (exposeEpRelease) {
      outPe.input('out_ep_release').srcConnection! <= input('out_ep_release');
      output('out_ep_held') <= outPe.output('out_ep_held');
    }
    if (exposeEpSetupDone) {
      output('out_ep_setup_done') <= outPe.output('out_ep_setup_done');
    }
    final outSetupToken = outPe.output('out_ep_setup_token');
    output('out_ep_setup_token') <= outSetupToken;
    inPe.input('setup_token').srcConnection! <=
        List.generate(
          numInEps,
          (ep) => ep < numOutEps ? outSetupToken[ep] : Const(0),
        ).rswizzle();
    if (exposeEpControl) {
      outPe.input('out_ep_control').srcConnection! <= input('out_ep_control');
    }

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
