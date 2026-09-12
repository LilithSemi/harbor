/// The full-speed USB device built on the ported tinyfpga protocol
/// engine. This is a drop-in replacement for [UsbEp0Engine] in
/// vendor-bulk applications: it serves chapter-9 control transfers on
/// endpoint 0 from a descriptor ROM and streams bulk data on endpoint 1.
///
/// The control endpoint follows the tinyfpga usb_serial_ctrl_ep state
/// machine: SETUP capture, an optional IN data stage (descriptor
/// bytes), status stages and the SET_ADDRESS after-status
/// application. The endpoint drain uses a pulsed get handshake instead
/// of the original's combinational feedback, which ROHD forbids.
///
/// Endpoint 1 streams the vendor command protocol: OUT bytes arrive on
/// cmd_valid/cmd_data with a cmd_ready handshake (one byte per three
/// cycles), IN bytes leave on resp_valid/resp_data with a resp_ready
/// handshake and resp_last marking the final byte of a response.
/// cmd_start pulses on the first packet of every EP1 OUT transfer so the
/// command engine can preempt a stale response. A packet that continues a
/// transfer, which is a packet that follows a full-size packet, gives no
/// pulse.
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'usb_dfu.dart' show UsbDescriptorEntry, UsbDescriptorRom;
import 'usb_fs_pe.dart';

/// Vendor full-speed USB device on the ported tinyfpga engine.
class HarborUsbFsDevice extends BridgeModule {
  /// The vendor descriptor set served on endpoint 0.
  final List<UsbDescriptorEntry> descriptors;

  /// When true, endpoint 1 bulk streams exist.
  final bool bulkEndpoints;

  /// Maximum packet payload per endpoint, in bytes.
  final int maxPacketSize;

  HarborUsbFsDevice({
    required this.descriptors,
    this.bulkEndpoints = true,
    this.maxPacketSize = 32,
    String? name,
  }) : super('HarborUsbFsDevice', name: name ?? 'usb_fs_device') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('dp', PortDirection.input);
    createPort('dm', PortDirection.input);
    createPort('cmd_ready', PortDirection.input);
    createPort('resp_data', PortDirection.input, width: 8);
    createPort('resp_valid', PortDirection.input);
    createPort('resp_last', PortDirection.input);

    addOutput('dp_out');
    addOutput('dm_out');
    addOutput('oe');
    addOutput('usb_pullup');
    addOutput('dev_addr', width: 7);
    addOutput('configured');
    addOutput('bus_reset');
    addOutput('cmd_data', width: 8);
    addOutput('cmd_valid');
    addOutput('resp_ready');
    addOutput('cmd_start');

    final clk = input('clk');
    final reset = input('reset');
    final cmdReady = input('cmd_ready');
    final respData = input('resp_data');
    final respValid = input('resp_valid');
    final respLast = input('resp_last');

    final numOutEps = bulkEndpoints ? 2 : 1;
    final numInEps = bulkEndpoints ? 2 : 1;

    // ==================================================================
    // Local signal declarations, in dependency order.
    // ==================================================================

    // Device address and configuration state.
    final devAddrReg = Logic(name: 'dev_addr_reg', width: 7);
    final newDevAddr = Logic(name: 'new_dev_addr', width: 7);
    final saveDevAddr = Logic(name: 'save_dev_addr');
    final configuredReg = Logic(name: 'configured_reg');

    // Control transfer states.
    const cIdle = 0;
    const cSetupCollect = 1;
    const cDataIn = 2;
    const cStatusIn = 4;
    const cStatusOut = 5;
    const cStall = 6;

    final ctrlState = Logic(name: 'ctrl_state', width: 3);
    final ctrlStateNext = Logic(name: 'ctrl_state_next', width: 3);

    // SETUP byte capture: 8 bytes, 2 cycles per byte.
    final setupBytes = List.generate(
      8,
      (i) => Logic(name: 'setup_byte_$i', width: 8),
    );
    final setupCount = Logic(name: 'setup_count', width: 4);
    final drainPhase = Logic(name: 'drain_phase');
    final getEp0 = Logic(name: 'ep0_get');

    // Request fields.
    final bmRequestType = setupBytes[0].named('bm_request_type');
    final bRequest = setupBytes[1].named('b_request');
    final wValue = [setupBytes[3], setupBytes[2]].swizzle().named('w_value');
    final wLength = [setupBytes[7], setupBytes[6]].swizzle().named('w_length');

    // IN data stage bookkeeping.
    final bytesSent = Logic(name: 'bytes_sent', width: 8);
    final allSentQ = Logic(name: 'all_sent_q');
    // The stall and ZLP are registered one-cycle pulses: driving them
    // combinationally from this state machine would re-enter the
    // engine's Combinational cascade, which ROHD forbids.
    final sendZlp = Logic(name: 'send_zlp_q');
    final inEp0Stall = Logic(name: 'ep0_in_stall_q');

    // EP1 bulk signals.
    final getEp1 = Logic(name: 'ep1_get');
    final ep1Gap = Logic(name: 'ep1_gap', width: 2);
    final cmdValid = Logic(name: 'cmd_valid_i');

    // ==================================================================
    // Bus reset detection on the received line view.
    // ==================================================================
    final busResetDet = HarborUsbFsResetDet(name: 'bus_reset_det');
    addSubModule(busResetDet);
    busResetDet.input('clk').srcConnection! <= clk;
    busResetDet.input('reset').srcConnection! <= reset;
    output('bus_reset') <= busResetDet.output('bus_reset');

    final combinedReset = (reset | busResetDet.output('bus_reset')).named(
      'fs_dev_reset',
    );

    // ==================================================================
    // The protocol engine and the pad mux.
    // ==================================================================
    final pe = HarborUsbFsPe(
      numOutEps: numOutEps,
      numInEps: numInEps,
      maxPacketSize: maxPacketSize,
      name: 'fs_pe',
    );
    addSubModule(pe);
    pe.input('clk').srcConnection! <= clk;
    pe.input('reset').srcConnection! <= combinedReset;
    pe.input('dev_addr').srcConnection! <= devAddrReg;

    output('dp_out') <= pe.output('usb_p_tx');
    output('dm_out') <= pe.output('usb_n_tx');
    output('oe') <= pe.output('usb_tx_en');
    output('usb_pullup') <= Const(1);

    final pRxMuxed = mux(
      pe.output('usb_tx_en'),
      Const(1),
      input('dp'),
    ).named('usb_p_rx_muxed');
    final nRxMuxed = mux(
      pe.output('usb_tx_en'),
      Const(0),
      input('dm'),
    ).named('usb_n_rx_muxed');
    pe.input('usb_p_rx').srcConnection! <= pRxMuxed;
    pe.input('usb_n_rx').srcConnection! <= nRxMuxed;
    busResetDet.input('usb_p_rx').srcConnection! <= pRxMuxed;
    busResetDet.input('usb_n_rx').srcConnection! <= nRxMuxed;

    // Endpoint 0 taps. The availability is registered at the FSM
    // boundary: a combinational read of the engine's avail output
    // would re-enter the engine's Combinational cascade through the
    // FSM's stall and done outputs, which ROHD forbids.
    final ep0AvailRaw = pe
        .output('out_ep_data_avail')
        .slice(0, 0)
        .named('ep0_avail_raw');
    final ep0Avail = Logic(name: 'ep0_avail_q');
    Sequential(clk, [
      If(
        combinedReset,
        then: [ep0Avail < Const(0)],
        orElse: [ep0Avail < ep0AvailRaw],
      ),
    ]);
    final ep0SetupFlag = pe
        .output('out_ep_setup')
        .slice(0, 0)
        .named('ep0_setup_flag');
    final ep0Data = pe.output('out_ep_data').named('ep0_data');
    final ep0Acked = pe.output('out_ep_acked').slice(0, 0).named('ep0_acked');
    final ep0InAcked = pe
        .output('in_ep_acked')
        .slice(0, 0)
        .named('ep0_in_acked');
    final ep0DataFree = pe
        .output('in_ep_data_free')
        .slice(0, 0)
        .named('ep0_free');

    // ==================================================================
    // The descriptor ROM.
    // ==================================================================
    final rom = UsbDescriptorRom(descriptors: descriptors, name: 'desc_rom');
    addSubModule(rom);
    final romOffset = Logic(name: 'rom_offset', width: 8);
    rom.input('desc_type').srcConnection! <= wValue.slice(15, 8);
    rom.input('desc_index').srcConnection! <= wValue.slice(7, 0);
    rom.input('offset').srcConnection! <= romOffset;

    final romData = rom.output('data').named('rom_data');
    final romLength = rom.output('length').named('rom_length');
    final romPresent = rom.output('present').named('rom_present');

    // GET_STATUS (device) and GET_CONFIGURATION serve small fixed
    // payloads rather than descriptor ROM contents.
    final isGetStatus =
        (bRequest.eq(Const(0, width: 8)) &
                bmRequestType.eq(Const(0x80, width: 8)))
            .named('is_get_status');
    final isGetConfig =
        (bRequest.eq(Const(8, width: 8)) &
                bmRequestType.eq(Const(0x80, width: 8)))
            .named('is_get_config');

    final effData = mux(
      isGetStatus,
      Const(0, width: 8),
      mux(isGetConfig, configuredReg.zeroExtend(8), romData),
    ).named('eff_data');
    final effLength = mux(
      isGetStatus,
      Const(2, width: 16),
      mux(isGetConfig, Const(1, width: 16), romLength),
    ).named('eff_length');
    final effPresent = (romPresent | isGetStatus | isGetConfig).named(
      'eff_present',
    );

    // The ROM offset follows the bytes sent.
    romOffset <= bytesSent;

    // ==================================================================
    // Control transfer combinational logic.
    // ==================================================================
    final inDataStage =
        (bmRequestType.slice(7, 7) & wLength.neq(Const(0, width: 16))).named(
          'in_data_stage',
        );
    final outDataStage =
        (~bmRequestType.slice(7, 7) & wLength.neq(Const(0, width: 16))).named(
          'out_data_stage',
        );

    final wLengthIsLarge = wLength
        .slice(15, 7)
        .neq(Const(0, width: 9))
        .named('wlength_is_large');
    final allDataSent =
        (bytesSent.zeroExtend(16).gte(effLength) |
                (~wLengthIsLarge & bytesSent.gte(wLength.slice(7, 0))))
            .named('all_data_sent');
    final moreDataToSend = ~allDataSent.named('more_data_to_send');

    // The put gate: descriptor bytes flow while the state machine is in
    // the data stage, data remains and the endpoint accepts.
    final ep0Put = (ctrlState.eq(Const(cDataIn, width: 3)) & moreDataToSend)
        .named('ep0_put');

    // The data-done edge: fires one cycle after the last byte lands.
    final allSentEdge = (~allSentQ & allDataSent).named('all_sent_edge');
    final ep0DataDone =
        (allSentEdge & ctrlState.eq(Const(cDataIn, width: 3)) | sendZlp).named(
          'ep0_data_done',
        );

    final ep0Req = (ctrlState.eq(Const(cDataIn, width: 3)) & moreDataToSend)
        .named('ep0_req');

    // The dispatch decision wires, internal to this module.
    final wantStall = (inDataStage & ~effPresent | outDataStage).named(
      'want_stall',
    );
    final wantZlp = (~inDataStage & ~outDataStage).named('want_zlp');
    final dispatched =
        (ctrlState.eq(Const(cSetupCollect, width: 3)) &
                setupCount.eq(Const(8, width: 4)))
            .named('dispatched');

    Combinational([
      ctrlStateNext < ctrlState,

      Case(
        ctrlState,
        [
          // Idle: a SETUP packet with data available starts capture.
          CaseItem(Const(cIdle, width: 3), [
            If(
              ep0Avail & ep0SetupFlag,
              then: [ctrlStateNext < Const(cSetupCollect, width: 3)],
            ),
          ]),

          // Capture the 8 SETUP bytes. When the last byte lands,
          // dispatch on the request.
          CaseItem(Const(cSetupCollect, width: 3), [
            If(
              setupCount.eq(Const(8, width: 4)),
              then: [
                If(
                  wantStall,
                  then: [ctrlStateNext < Const(cStall, width: 3)],
                  orElse: [
                    If(
                      inDataStage,
                      then: [ctrlStateNext < Const(cDataIn, width: 3)],
                      orElse: [ctrlStateNext < Const(cStatusIn, width: 3)],
                    ),
                  ],
                ),
              ],
            ),
          ]),

          // IN data stage: serve bytes until the host ACKs the last.
          CaseItem(Const(cDataIn, width: 3), [
            If(
              ep0InAcked & allDataSent,
              then: [ctrlStateNext < Const(cStatusOut, width: 3)],
            ),
          ]),

          // IN status stage: the host ACKs the zero-length packet.
          CaseItem(Const(cStatusIn, width: 3), [
            If(ep0InAcked, then: [ctrlStateNext < Const(cIdle, width: 3)]),
          ]),

          // OUT status stage: the host sends a zero-length OUT.
          CaseItem(Const(cStatusOut, width: 3), [
            If(ep0Acked, then: [ctrlStateNext < Const(cIdle, width: 3)]),
          ]),

          // Stall: a new SETUP packet restarts capture. The engine
          // clears the endpoint stall on the SETUP token.
          CaseItem(Const(cStall, width: 3), [
            If(
              ep0SetupFlag & ep0Avail,
              then: [ctrlStateNext < Const(cSetupCollect, width: 3)],
            ),
          ]),
        ],
        defaultItem: [ctrlStateNext < Const(cIdle, width: 3)],
      ),
    ]);

    output('configured') <= configuredReg;
    output('dev_addr') <= devAddrReg;

    // ==================================================================
    // Control transfer sequential logic.
    // ==================================================================
    Sequential(clk, [
      If(
        combinedReset,
        then: [
          ctrlState < Const(cIdle, width: 3),
          setupCount < Const(0, width: 4),
          drainPhase < Const(0),
          bytesSent < Const(0, width: 8),
          allSentQ < Const(0),
          devAddrReg < Const(0, width: 7),
          newDevAddr < Const(0, width: 7),
          configuredReg < Const(0),
          saveDevAddr < Const(0),
          inEp0Stall < Const(0),
          sendZlp < Const(0),
        ],
        orElse: [
          ctrlState < ctrlStateNext,
          allSentQ < allDataSent,

          // The dispatch pulses: one cycle of stall or ZLP.
          If(
            dispatched,
            then: [inEp0Stall < wantStall, sendZlp < wantZlp],
            orElse: [inEp0Stall < Const(0), sendZlp < Const(0)],
          ),

          // The SETUP drain: on phase 0 with data available, pulse
          // the get; phase 1 lets the read pipeline settle.
          If(
            ctrlState.eq(Const(cSetupCollect, width: 3)) &
                drainPhase.eq(Const(0)) &
                ep0Avail &
                setupCount.lt(Const(8, width: 4)),
            then: [
              setupCount < setupCount + Const(1, width: 4),
              drainPhase < Const(1),
            ],
          ),
          If(drainPhase.eq(Const(1)), then: [drainPhase < Const(0)]),

          // The IN data stage: count the bytes put.
          If(
            ep0Put & ep0DataFree,
            then: [bytesSent < bytesSent + Const(1, width: 8)],
          ),

          // SET_ADDRESS latches the new address when the status stage
          // completes, so the status token still uses the old address.
          If(
            ctrlState.eq(Const(cStatusIn, width: 3)) &
                bRequest.eq(Const(5, width: 8)) &
                ep0InAcked,
            then: [saveDevAddr < Const(1), newDevAddr < wValue.slice(6, 0)],
          ),
          If(
            saveDevAddr,
            then: [saveDevAddr < Const(0), devAddrReg < newDevAddr],
          ),

          // SET_CONFIGURATION latches the configured flag when the
          // status stage completes.
          If(
            ctrlState.eq(Const(cStatusIn, width: 3)) &
                bRequest.eq(Const(9, width: 8)) &
                ep0InAcked,
            then: [configuredReg < wValue.neq(Const(0, width: 16))],
          ),

          // Reset the byte counters when a transfer completes so the
          // next dispatch starts fresh. The original clears
          // setup_data_addr and bytes_sent together at the status
          // stage end.
          If(
            (ctrlState.eq(Const(cStatusIn, width: 3)) |
                    ctrlState.eq(Const(cStatusOut, width: 3))) &
                ctrlStateNext.eq(Const(cIdle, width: 3)),
            then: [
              bytesSent < Const(0, width: 8),
              setupCount < Const(0, width: 4),
            ],
          ),

          // Every SETUP capture starts at byte 0. The status stage end
          // above covers a transfer that completes, and this covers a
          // transfer that ends in the stall state, which has no status
          // stage. Without the clear the count stays at 8, the next
          // SETUP dispatches on the PREVIOUS request, and its 8 bytes
          // stay in the endpoint. Endpoint 0 then holds the OUT grant
          // for ever and no other endpoint can receive.
          If(
            ctrlStateNext.eq(Const(cSetupCollect, width: 3)) &
                ~ctrlState.eq(Const(cSetupCollect, width: 3)),
            then: [setupCount < Const(0, width: 4)],
          ),
        ],
      ),
    ]);

    // The SETUP byte registers, decoded by the count.
    for (var i = 0; i < 8; i++) {
      Sequential(clk, [
        If(
          combinedReset,
          then: [setupBytes[i] < Const(0, width: 8)],
          orElse: [
            If(
              ctrlState.eq(Const(cSetupCollect, width: 3)) &
                  drainPhase.eq(Const(0)) &
                  ep0Avail &
                  setupCount.eq(Const(i, width: 4)),
              then: [setupBytes[i] < ep0Data],
            ),
          ],
        ),
      ]);
    }

    // The EP0 get pulse drives the drain.
    getEp0 <=
        ctrlState.eq(Const(cSetupCollect, width: 3)) &
            drainPhase.eq(Const(0)) &
            ep0Avail &
            setupCount.lt(Const(8, width: 4));

    // ==================================================================
    // Engine input wiring (after all signals exist).
    // ==================================================================
    final ep1AvailPre = bulkEndpoints
        ? pe.output('out_ep_data_avail').slice(1, 1)
        : Const(0);
    final ep1Free = bulkEndpoints
        ? pe.output('in_ep_data_free').slice(1, 1)
        : Const(0);
    final ep1Done = (respValid & respLast & ep1Free).named('ep1_done');
    final ep1Put = (respValid & ep1Free).named('ep1_put');

    final outDataGet = bulkEndpoints
        ? [getEp0, getEp1].rswizzle()
        : [getEp0].rswizzle();
    final outEpReq = bulkEndpoints
        ? [ep0Avail, ep1AvailPre].rswizzle()
        : [ep0Avail].rswizzle();
    final inEpStall = bulkEndpoints
        ? [inEp0Stall, Const(0)].rswizzle()
        : [inEp0Stall].rswizzle();
    final inEpReq = bulkEndpoints
        ? [ep0Req, respValid].rswizzle()
        : [ep0Req].rswizzle();
    final inEpDataDone = bulkEndpoints
        ? [ep0DataDone, ep1Done].rswizzle()
        : [ep0DataDone].rswizzle();
    final inEpData = bulkEndpoints
        ? [effData, respData].rswizzle()
        : [effData].rswizzle();
    final ep0PutGated = ep0Put & ep0DataFree;
    final inEpDataPut = bulkEndpoints
        ? [ep0PutGated, ep1Put].rswizzle()
        : [ep0PutGated].rswizzle();

    pe.input('out_ep_data_get').srcConnection! <= outDataGet;
    pe.input('out_ep_req').srcConnection! <= outEpReq;
    pe.input('out_ep_stall').srcConnection! <= Const(0, width: numOutEps);
    pe.input('in_ep_stall').srcConnection! <= inEpStall;
    pe.input('in_ep_req').srcConnection! <= inEpReq;
    pe.input('in_ep_data_done').srcConnection! <= inEpDataDone;
    pe.input('in_ep_data').srcConnection! <= inEpData;
    pe.input('in_ep_data_put').srcConnection! <= inEpDataPut;

    // ==================================================================
    // Endpoint 1 bulk command/response adapters.
    // ==================================================================
    if (bulkEndpoints) {
      final ep1Avail = pe
          .output('out_ep_data_avail')
          .slice(1, 1)
          .named('ep1_avail');
      final ep1Data = pe.output('out_ep_data').named('ep1_data');

      // OUT: the endpoint data register loads one cycle after the
      // arbiter grant, so the byte is offered one cycle after the
      // grant. This matches the WaitData step of the original bridge
      // endpoint. The gap counts down after each acceptance and covers
      // the same read delay for the bytes that follow.
      final ep1Granted = pe
          .output('out_ep_grant')
          .slice(1, 1)
          .named('ep1_granted');
      final ep1DataValid = Logic(name: 'ep1_data_valid_q');
      Sequential(clk, [
        If(
          combinedReset,
          then: [ep1DataValid < Const(0)],
          orElse: [ep1DataValid < (ep1Avail & ep1Granted)],
        ),
      ]);
      cmdValid <= ep1DataValid & ep1Gap.eq(Const(0, width: 2));
      output('cmd_valid') <= cmdValid;
      output('cmd_data') <= ep1Data;

      // cmd_start marks the start of a bulk TRANSFER, not the start of a
      // packet. A USB bulk transfer that is longer than wMaxPacketSize
      // arrives as several packets: full-size packets, then a packet that
      // is shorter (a zero-length packet when the transfer length divides
      // by the packet size). So a packet that comes after a full-size
      // packet continues the transfer that is open, and a packet that
      // comes after a short packet, or the first packet after a reset,
      // starts a new command.
      //
      // The transfer flag holds the size class of the last accepted
      // packet. A pulse on every packet would tell the command engine to
      // drop its parse state in the middle of a command, which silently
      // loses every byte after the first packet.
      //
      // A host that ends a transfer whose length is a multiple of
      // wMaxPacketSize must send the terminating zero-length packet, as
      // USB requires. Without it the next command looks like a
      // continuation and gets no cmd_start pulse.
      final ep1Acked = pe.output('out_ep_acked').slice(1, 1).named('ep1_acked');
      final ep1PktFull = pe
          .output('out_ep_pkt_full')
          .slice(1, 1)
          .named('ep1_pkt_full');
      final ep1XfrOpen = Logic(name: 'ep1_xfr_open_q');
      Sequential(clk, [
        If(
          combinedReset,
          then: [ep1XfrOpen < Const(0)],
          orElse: [
            If(ep1Acked, then: [ep1XfrOpen < ep1PktFull]),
          ],
        ),
      ]);
      output('cmd_start') <= ep1Acked & ~ep1XfrOpen;

      final accept = (cmdValid & cmdReady).named('cmd_accept');
      Sequential(clk, [
        If(
          combinedReset,
          then: [getEp1 < Const(0), ep1Gap < Const(0, width: 2)],
          orElse: [
            If(
              accept,
              then: [getEp1 < Const(1), ep1Gap < Const(2, width: 2)],
              orElse: [
                getEp1 < Const(0),
                If(
                  ep1Gap.neq(Const(0, width: 2)),
                  then: [ep1Gap < ep1Gap - Const(1, width: 2)],
                ),
              ],
            ),
          ],
        ),
      ]);

      // IN: response bytes stream into the endpoint while free.
      output('resp_ready') <= ep1Free;
    } else {
      output('cmd_valid') <= Const(0);
      output('cmd_data') <= Const(0, width: 8);
      output('cmd_start') <= Const(0);
      output('resp_ready') <= Const(0);
    }
  }
}
