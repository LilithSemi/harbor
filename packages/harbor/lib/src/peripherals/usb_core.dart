import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'usb_descriptors.dart' show UsbDescriptorEntry, UsbDescriptorRom;
import 'usb_fs_pe.dart';

/// The contract between [HarborUsbCore] and a function device (vendor bulk,
/// DFU, ...). The core is the provider: it drives SETUP/configuration state
/// and the endpoint 0 byte streams, and arbitrates any extra bulk endpoints
/// on the function's behalf. The function is the consumer: it decides class
/// and vendor requests and drives the endpoint 0 and extra endpoint data.
///
/// [numOutEps] and [numInEps] count only the extra endpoints, numbered 1
/// through n on the protocol engine (endpoint 0 is the core's own control
/// endpoint and is not part of this interface). A count of 0 leaves the
/// matching signals out of the interface entirely.
class UsbFunctionInterface extends PairInterface {
  /// Extra OUT endpoints, numbered 1..numOutEps on the protocol engine.
  final int numOutEps;

  /// Extra IN endpoints, numbered 1..numInEps on the protocol engine.
  final int numInEps;

  /// High while the device is in the configured state.
  Logic get configured => port('configured');

  /// High while the line stays at SE0 past the reset threshold.
  Logic get busReset => port('bus_reset');

  /// The current SET_INTERFACE alternate setting.
  Logic get altSetting => port('alt_setting');

  /// One-cycle strobe: a class or vendor SETUP packet was captured.
  Logic get setupValid => port('setup_valid');

  /// The 8 raw SETUP bytes, byte 0 (bmRequestType) in bits 7:0.
  Logic get setupData => port('setup_data');

  /// An OUT data stage byte, valid while [ep0OutValid] is high.
  Logic get ep0OutData => port('ep0_out_data');

  /// High while [ep0OutData] holds a byte the function has not taken yet.
  Logic get ep0OutValid => port('ep0_out_valid');

  /// One-cycle strobe: the OUT data stage delivered its last byte.
  Logic get ep0OutEnd => port('ep0_out_end');

  /// One-cycle strobe: a new SETUP preempted the control transfer in
  /// progress (USB 2.0 8.5.3/9.2.6.4). A function device uses this to drop
  /// any partial state the aborted stage left behind, rather than act on
  /// it for the new request.
  Logic get ep0Abort => port('ep0_abort');

  /// High while the core can accept an IN data stage byte.
  Logic get ep0InReady => port('ep0_in_ready');

  /// Exactly one pulse per [setupValid]: accept the request.
  Logic get setupAccept => port('setup_accept');

  /// Exactly one pulse per [setupValid]: stall the request.
  Logic get setupStall => port('setup_stall');

  /// High while the function can accept an OUT data stage byte.
  Logic get ep0OutReady => port('ep0_out_ready');

  /// An IN data stage byte, valid while [ep0InValid] is high.
  Logic get ep0InData => port('ep0_in_data');

  /// High while [ep0InData] holds a byte the core has not taken yet.
  Logic get ep0InValid => port('ep0_in_valid');

  /// High on the last byte of the IN data stage.
  Logic get ep0InLast => port('ep0_in_last');

  UsbFunctionInterface({this.numOutEps = 0, this.numInEps = 0})
    : super(
        portsFromProvider: [
          Logic.port('configured'),
          Logic.port('bus_reset'),
          Logic.port('alt_setting', 8),
          Logic.port('setup_valid'),
          Logic.port('setup_data', 64),
          Logic.port('ep0_out_data', 8),
          Logic.port('ep0_out_valid'),
          Logic.port('ep0_out_end'),
          Logic.port('ep0_abort'),
          Logic.port('ep0_in_ready'),
          if (numOutEps > 0) ...[
            Logic.port('out_ep_grant', numOutEps),
            Logic.port('out_ep_data_avail', numOutEps),
            Logic.port('out_ep_setup', numOutEps),
            Logic.port('out_ep_data', 8),
            Logic.port('out_ep_acked', numOutEps),
            Logic.port('out_ep_pkt_full', numOutEps),
          ],
          if (numInEps > 0) ...[
            Logic.port('in_ep_grant', numInEps),
            Logic.port('in_ep_data_free', numInEps),
            Logic.port('in_ep_acked', numInEps),
          ],
        ],
        portsFromConsumer: [
          Logic.port('setup_accept'),
          Logic.port('setup_stall'),
          Logic.port('ep0_out_ready'),
          Logic.port('ep0_in_data', 8),
          Logic.port('ep0_in_valid'),
          Logic.port('ep0_in_last'),
          if (numOutEps > 0) ...[
            Logic.port('out_ep_req', numOutEps),
            Logic.port('out_ep_data_get', numOutEps),
            Logic.port('out_ep_stall', numOutEps),
          ],
          if (numInEps > 0) ...[
            Logic.port('in_ep_req', numInEps),
            Logic.port('in_ep_data_put', numInEps),
            Logic.port('in_ep_data', numInEps * 8),
            Logic.port('in_ep_data_done', numInEps),
            Logic.port('in_ep_stall', numInEps),
          ],
        ],
      );

  @override
  UsbFunctionInterface clone() =>
      UsbFunctionInterface(numOutEps: numOutEps, numInEps: numInEps);
}

/// Walks the CONFIGURATION descriptor(s) in [descriptors] and returns every
/// (bInterfaceNumber, bAlternateSetting) pair they declare. Used to check a
/// SET_INTERFACE against the descriptors actually served, USB 2.0 9.4.10.
List<List<int>> _usbInterfaceAltPairs(List<UsbDescriptorEntry> descriptors) {
  final pairs = <List<int>>[];
  for (final d in descriptors) {
    if (d.type != 0x02) {
      continue;
    }
    final bytes = d.bytes;
    var i = 0;
    while (i < bytes.length) {
      final len = bytes[i];
      if (len == 0) {
        break;
      }
      if (i + 3 < bytes.length && bytes[i + 1] == 0x04) {
        pairs.add([bytes[i + 2], bytes[i + 3]]);
      }
      i += len;
    }
  }
  return pairs;
}

/// The single ch9 control endpoint for the Harbor USB stack.
///
/// [HarborUsbCore] owns the protocol engine and the whole of endpoint 0:
/// SETUP capture, standard requests served directly (GET_DESCRIPTOR,
/// GET_STATUS, GET_CONFIGURATION, SET_ADDRESS, SET_CONFIGURATION,
/// GET_INTERFACE, SET_INTERFACE, and the endpoint-recipient GET_STATUS,
/// SET_FEATURE and CLEAR_FEATURE for ENDPOINT_HALT), and an IN or OUT data
/// stage. Class and vendor requests are handed to a function device over
/// [UsbFunctionInterface] (`setup_valid`/`setup_accept`/`setup_stall`, then
/// a byte stream for the data stage). Extra bulk endpoints are passed
/// through to the function device unchanged, except that the core resets
/// their data toggle on SET_CONFIGURATION, SET_INTERFACE and
/// CLEAR_FEATURE(ENDPOINT_HALT), per USB 2.0 9.4.5. SET_CONFIGURATION also
/// clears every host-set halt and sets the alternate setting back to 0, per
/// USB 2.0 9.1.1.5.
///
/// Data stages count 16 bits, so any wLength works. The device descriptor
/// must give a bMaxPacketSize0 equal to [maxPacketSize].
///
/// The control endpoint follows the tinyfpga usb_serial_ctrl_ep state
/// machine ported into HarborUsbFsDevice: a pulsed get handshake drains the
/// engine's endpoint buffer instead of the original's combinational
/// feedback, which ROHD forbids.
class HarborUsbCore extends BridgeModule {
  /// The descriptors served on endpoint 0 for GET_DESCRIPTOR.
  final List<UsbDescriptorEntry> descriptors;

  /// Maximum packet payload per endpoint, in bytes.
  final int maxPacketSize;

  /// Extra OUT endpoints the function device needs, numbered 1..n.
  final int numOutEps;

  /// Extra IN endpoints the function device needs, numbered 1..n.
  final int numInEps;

  HarborUsbCore({
    required this.descriptors,
    this.maxPacketSize = 64,
    this.numOutEps = 0,
    this.numInEps = 0,
    String? name,
  }) : super('HarborUsbCore', name: name ?? 'usb_core') {
    if (![8, 16, 32, 64].contains(maxPacketSize)) {
      throw ArgumentError.value(
        maxPacketSize,
        'maxPacketSize',
        'must be 8, 16, 32 or 64',
      );
    }
    // Endpoint numbers are 4 bits and endpoint 0 is the core's own.
    if (numOutEps < 0 || numOutEps > 15) {
      throw ArgumentError.value(numOutEps, 'numOutEps', 'must be 0 to 15');
    }
    if (numInEps < 0 || numInEps > 15) {
      throw ArgumentError.value(numInEps, 'numInEps', 'must be 0 to 15');
    }
    final device = descriptors.where((d) => d.type == 0x01 && d.index == 0);
    if (device.isEmpty) {
      throw ArgumentError('descriptors must include a DEVICE descriptor');
    }
    final bytes = device.first.bytes;
    if (bytes.length < 8 || bytes[7] != maxPacketSize) {
      throw ArgumentError(
        'DEVICE descriptor bMaxPacketSize0 must equal maxPacketSize '
        '($maxPacketSize)',
      );
    }

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('dp', PortDirection.input);
    createPort('dm', PortDirection.input);

    addOutput('dp_out');
    addOutput('dm_out');
    addOutput('oe');
    addOutput('usb_pullup');
    addOutput('dev_addr', width: 7);
    addOutput('configured');
    addOutput('bus_reset');

    final funcRef = addInterface(
      UsbFunctionInterface(numOutEps: numOutEps, numInEps: numInEps),
      name: 'func',
      role: PairRole.provider,
    );
    final func = funcRef.internalInterface!;

    final clk = input('clk');
    final reset = input('reset');

    final pePortOutEps = 1 + numOutEps;
    final pePortInEps = 1 + numInEps;

    // ==================================================================
    // Control transfer states.
    // ==================================================================
    const cIdle = 0;
    const cSetupCollect = 1;
    const cDataIn = 2;
    const cStatusIn = 3;
    const cStatusOut = 4;
    const cStall = 5;
    const cFuncWait = 6;
    const cDataOut = 7;

    final ctrlState = Logic(name: 'ctrl_state', width: 3);
    final ctrlStateNext = Logic(name: 'ctrl_state_next', width: 3);

    // Device address and configuration state.
    final devAddrReg = Logic(name: 'dev_addr_reg', width: 7);
    final newDevAddr = Logic(name: 'new_dev_addr', width: 7);
    final saveDevAddr = Logic(name: 'save_dev_addr');
    final configuredReg = Logic(name: 'configured_reg');
    final altSettingReg = Logic(name: 'alt_setting_reg', width: 8);
    final newAltSetting = Logic(name: 'new_alt_setting', width: 8);
    final saveAltSetting = Logic(name: 'save_alt_setting');

    // SETUP byte capture: 8 bytes, 2 cycles per byte.
    final setupBytes = List.generate(
      8,
      (i) => Logic(name: 'setup_byte_$i', width: 8),
    );
    final setupCount = Logic(name: 'setup_count', width: 4);
    final drainPhase = Logic(name: 'drain_phase');
    final getEp0 = Logic(name: 'ep0_get');

    final bmRequestType = setupBytes[0].named('bm_request_type');
    final bRequest = setupBytes[1].named('b_request');
    final wValue = [setupBytes[3], setupBytes[2]].swizzle().named('w_value');
    final wLength = [setupBytes[7], setupBytes[6]].swizzle().named('w_length');

    // IN data stage bookkeeping, shared by the ROM path and the function
    // path. OUT reuses the same byte counter (never active at once).
    final bytesSent = Logic(name: 'bytes_sent', width: 16);
    final allSentQ = Logic(name: 'all_sent_q');
    final sendZlp = Logic(name: 'send_zlp_q');
    final ep0Stall = Logic(name: 'ep0_stall_q');
    final setupValidQ = Logic(name: 'setup_valid_q');
    final funcLastLatched = Logic(name: 'func_last_latched_q');

    // OUT data stage bookkeeping.
    final outHeld = Logic(name: 'ep0_out_held_q');
    final outByte = Logic(name: 'ep0_out_byte_q', width: 8);
    final outDrainPhase = Logic(name: 'ep0_out_drain_phase_q');
    final ep0OutEndQ = Logic(name: 'ep0_out_end_q');

    // One-cycle strobe to the function: a new SETUP just abandoned
    // whatever control transfer was in progress.
    final ep0AbortQ = Logic(name: 'ep0_abort_q');

    // True once the IN data stage has sent one more, zero-length
    // packet after a final packet that was exactly maxPacketSize.
    final zlpPendingQ = Logic(name: 'ep0_in_zlp_pending_q');
    // Delays the send_zlp pulse by the one cycle the engine's own
    // endpoint FSM needs to settle from getting back into putting
    // after the ack that triggers it.
    final zlpArmQ = Logic(name: 'ep0_in_zlp_arm_q');

    // ==================================================================
    // Bus reset detection on the received line view.
    // ==================================================================
    final busResetDet = HarborUsbFsResetDet(name: 'bus_reset_det');
    addSubModule(busResetDet);
    busResetDet.input('clk').srcConnection! <= clk;
    busResetDet.input('reset').srcConnection! <= reset;
    output('bus_reset') <= busResetDet.output('bus_reset');

    final combinedReset = (reset | busResetDet.output('bus_reset')).named(
      'core_reset',
    );

    // ==================================================================
    // The protocol engine and the pad mux.
    // ==================================================================
    final pe = HarborUsbFsPe(
      numOutEps: pePortOutEps,
      numInEps: pePortInEps,
      maxPacketSize: maxPacketSize,
      exposeEpToggleReset: true,
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

    output('configured') <= configuredReg;
    output('dev_addr') <= devAddrReg;

    // Endpoint 0 taps. The availability is registered at the FSM boundary,
    // same as HarborUsbFsDevice: a combinational read of the engine's avail
    // output would re-enter the engine's Combinational cascade through the
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
    // Descriptors are at most 255 bytes, and allDataSentStd stops the
    // stage at the descriptor length, so the low byte is enough.
    romOffset <= bytesSent.slice(7, 0);

    final romData = rom.output('data').named('rom_data');
    final romLength = rom.output('length').named('rom_length');
    final romPresent = rom.output('present').named('rom_present');

    // ==================================================================
    // Request classification.
    // ==================================================================
    final isStandard = bmRequestType
        .slice(6, 5)
        .eq(Const(0, width: 2))
        .named('is_standard');
    final reqDirIn = bmRequestType.slice(7, 7).named('req_dir_in');
    final wLengthIsZero = wLength
        .eq(Const(0, width: 16))
        .named('w_length_is_zero');

    // GET_STATUS, GET_CONFIGURATION and GET_INTERFACE serve small fixed
    // payloads rather than descriptor ROM contents. GET_DESCRIPTOR is the
    // only standard request the ROM answers. Any other, unimplemented
    // standard IN request must stall rather than read the ROM by luck.
    final isGetStatus =
        (bRequest.eq(Const(0, width: 8)) &
                bmRequestType.eq(Const(0x80, width: 8)))
            .named('is_get_status');
    final isGetDescriptor =
        (bRequest.eq(Const(6, width: 8)) &
                bmRequestType.eq(Const(0x80, width: 8)))
            .named('is_get_descriptor');
    final isGetConfig =
        (bRequest.eq(Const(8, width: 8)) &
                bmRequestType.eq(Const(0x80, width: 8)))
            .named('is_get_config');
    final isGetInterface =
        (bRequest.eq(Const(10, width: 8)) &
                bmRequestType.eq(Const(0x81, width: 8)))
            .named('is_get_interface');

    // ==================================================================
    // Standard endpoint-recipient requests: GET_STATUS, SET_FEATURE and
    // CLEAR_FEATURE(ENDPOINT_HALT), USB 2.0 9.4.5.
    // ==================================================================
    final wIndex = [setupBytes[5], setupBytes[4]].swizzle().named('w_index');
    final reqEpNum = wIndex.slice(3, 0).named('req_ep_num');
    final reqEpDirIn = wIndex.slice(7, 7).named('req_ep_dir_in');

    final isGetStatusEp =
        (bRequest.eq(Const(0, width: 8)) &
                bmRequestType.eq(Const(0x82, width: 8)))
            .named('is_get_status_ep');
    final isSetFeatureEp =
        (bRequest.eq(Const(3, width: 8)) &
                bmRequestType.eq(Const(0x02, width: 8)))
            .named('is_set_feature_ep');
    final isClearFeatureEp =
        (bRequest.eq(Const(1, width: 8)) &
                bmRequestType.eq(Const(0x02, width: 8)))
            .named('is_clear_feature_ep');
    final isEndpointHaltFeature = wValue
        .eq(Const(0, width: 16))
        .named('is_endpoint_halt_feature');

    // Bit i matches extra endpoint i+1 of the matching direction, so the
    // endpoint address (number and direction together) picks exactly one.
    final outEpMatchBits = List.generate(
      numOutEps,
      (i) =>
          (reqEpDirIn.eq(Const(0, width: 1)) &
                  reqEpNum.eq(Const(i + 1, width: 4)))
              .named('out_ep_match_${i + 1}'),
    );
    final inEpMatchBits = List.generate(
      numInEps,
      (i) =>
          (reqEpDirIn.eq(Const(1, width: 1)) &
                  reqEpNum.eq(Const(i + 1, width: 4)))
              .named('in_ep_match_${i + 1}'),
    );

    final setConfigStatusDone =
        (ctrlState.eq(Const(cStatusIn, width: 3)) &
                isStandard &
                bRequest.eq(Const(9, width: 8)) &
                ep0InAcked)
            .named('set_config_status_done');
    final setInterfaceStatusDone =
        (ctrlState.eq(Const(cStatusIn, width: 3)) &
                isStandard &
                bRequest.eq(Const(11, width: 8)) &
                ep0InAcked)
            .named('set_interface_status_done');
    final setFeatureEpStatusDone =
        (ctrlState.eq(Const(cStatusIn, width: 3)) &
                isSetFeatureEp &
                isEndpointHaltFeature &
                ep0InAcked)
            .named('set_feature_ep_status_done');
    final clearFeatureEpStatusDone =
        (ctrlState.eq(Const(cStatusIn, width: 3)) &
                isClearFeatureEp &
                isEndpointHaltFeature &
                ep0InAcked)
            .named('clear_feature_ep_status_done');

    // One flop per extra endpoint holds the host-requested ENDPOINT_HALT
    // state. The function's own stall request ORs with it further down.
    final hostHaltOutBits = List.generate(
      numOutEps,
      (i) => Logic(name: 'host_halt_out_${i + 1}_q'),
    );
    final hostHaltInBits = List.generate(
      numInEps,
      (i) => Logic(name: 'host_halt_in_${i + 1}_q'),
    );
    for (var i = 0; i < numOutEps; i++) {
      Sequential(clk, [
        If(
          combinedReset,
          then: [hostHaltOutBits[i] < Const(0)],
          orElse: [
            If(
              setFeatureEpStatusDone & outEpMatchBits[i],
              then: [hostHaltOutBits[i] < Const(1)],
              orElse: [
                If(
                  (clearFeatureEpStatusDone & outEpMatchBits[i]) |
                      setConfigStatusDone,
                  then: [hostHaltOutBits[i] < Const(0)],
                ),
              ],
            ),
          ],
        ),
      ]);
    }
    for (var i = 0; i < numInEps; i++) {
      Sequential(clk, [
        If(
          combinedReset,
          then: [hostHaltInBits[i] < Const(0)],
          orElse: [
            If(
              setFeatureEpStatusDone & inEpMatchBits[i],
              then: [hostHaltInBits[i] < Const(1)],
              orElse: [
                If(
                  (clearFeatureEpStatusDone & inEpMatchBits[i]) |
                      setConfigStatusDone,
                  then: [hostHaltInBits[i] < Const(0)],
                ),
              ],
            ),
          ],
        ),
      ]);
    }

    Logic orAcross(List<Logic> bits) =>
        bits.isEmpty ? Const(0, width: 1) : bits.rswizzle().or();

    final getStatusEpOutMatch = orAcross(
      outEpMatchBits,
    ).named('get_status_ep_out_match');
    final getStatusEpInMatch = orAcross(
      inEpMatchBits,
    ).named('get_status_ep_in_match');
    final isEp0Addressed = reqEpNum
        .eq(Const(0, width: 4))
        .named('is_ep0_addressed');
    final getStatusEpMatched =
        (isEp0Addressed | getStatusEpOutMatch | getStatusEpInMatch).named(
          'get_status_ep_matched',
        );

    final isFeatureEp = (isSetFeatureEp | isClearFeatureEp).named(
      'is_feature_ep',
    );
    // SET_FEATURE/CLEAR_FEATURE(ENDPOINT_HALT) only accepts an existing
    // extra endpoint. Any other feature selector, or an endpoint address
    // nothing claims (including EP0), STALLs instead of ACKing with no
    // effect. EP0's own halt is unsupported here, though USB 2.0 allows it.
    final featureEpExists = (getStatusEpOutMatch | getStatusEpInMatch).named(
      'feature_ep_exists',
    );
    final featureEpWantStall =
        (isFeatureEp & (~isEndpointHaltFeature | ~featureEpExists)).named(
          'feature_ep_want_stall',
        );

    // GET_STATUS(endpoint) reports halted for either source of a stall:
    // a host-requested halt, or the function's own stall request, which
    // matches what the endpoint actually does on the wire further down.
    final outHaltSelBits = List.generate(
      numOutEps,
      (i) =>
          ((hostHaltOutBits[i] | func.port('out_ep_stall').slice(i, i)) &
                  outEpMatchBits[i])
              .named('out_halt_sel_${i + 1}'),
    );
    final inHaltSelBits = List.generate(
      numInEps,
      (i) =>
          ((hostHaltInBits[i] | func.port('in_ep_stall').slice(i, i)) &
                  inEpMatchBits[i])
              .named('in_halt_sel_${i + 1}'),
    );
    final epHaltBit = (orAcross(outHaltSelBits) | orAcross(inHaltSelBits))
        .named('ep_halt_bit');
    // GET_STATUS(endpoint) returns a 2-byte word. Only byte 0 carries the
    // halt bit, byte 1 stays reserved/zero.
    final statusEpByte = mux(
      bytesSent.eq(Const(0, width: 16)),
      epHaltBit.zeroExtend(8),
      Const(0, width: 8),
    ).named('status_ep_byte');

    final effData = mux(
      isGetStatus,
      Const(0, width: 8),
      mux(
        isGetStatusEp,
        statusEpByte,
        mux(
          isGetConfig,
          configuredReg.zeroExtend(8),
          mux(isGetInterface, altSettingReg, romData),
        ),
      ),
    ).named('eff_data');
    final effLength = mux(
      isGetStatus,
      Const(2, width: 16),
      mux(
        isGetStatusEp,
        Const(2, width: 16),
        mux(
          isGetConfig,
          Const(1, width: 16),
          mux(isGetInterface, Const(1, width: 16), romLength),
        ),
      ),
    ).named('eff_length');
    final effPresent =
        (isGetStatus |
                (isGetStatusEp & getStatusEpMatched) |
                isGetConfig |
                isGetInterface |
                (isGetDescriptor & romPresent))
            .named('eff_present');

    // ==================================================================
    // IN data stage: byte source is the ROM for a standard request, or the
    // function device otherwise.
    // ==================================================================
    final inDataStage =
        (bmRequestType.slice(7, 7) & wLength.neq(Const(0, width: 16))).named(
          'in_data_stage',
        );
    final outDataStage =
        (~bmRequestType.slice(7, 7) & wLength.neq(Const(0, width: 16))).named(
          'out_data_stage',
        );

    final wLengthTruncBound = bytesSent
        .gte(wLength)
        .named('w_length_trunc_bound');

    final allDataSentStd = (bytesSent.gte(effLength) | wLengthTruncBound).named(
      'all_data_sent_std',
    );
    final allDataSentFunc = (funcLastLatched | wLengthTruncBound).named(
      'all_data_sent_func',
    );
    final allDataSent = mux(
      isStandard,
      allDataSentStd,
      allDataSentFunc,
    ).named('all_data_sent');
    final moreDataToSend = ~allDataSent.named('more_data_to_send');

    final ep0InValid = func.port('ep0_in_valid');
    final ep0InData = func.port('ep0_in_data');
    final ep0InLast = func.port('ep0_in_last');

    final ep0Put = (ctrlState.eq(Const(cDataIn, width: 3)) & moreDataToSend)
        .named('ep0_put');
    final ep0InAccept = mux(
      isStandard,
      ep0Put & ep0DataFree,
      ep0Put & ep0DataFree & ep0InValid,
    ).named('ep0_in_accept');
    final effDataFinal = mux(
      isStandard,
      effData,
      ep0InData,
    ).named('eff_data_final');

    final allSentEdge = (~allSentQ & allDataSent).named('all_sent_edge');
    final ep0DataDone =
        (allSentEdge & ctrlState.eq(Const(cDataIn, width: 3)) | sendZlp).named(
          'ep0_data_done',
        );

    // The last IN packet of the data stage landed exactly on a packet
    // boundary, with fewer bytes sent than the host asked for: USB 2.0
    // 8.5.3.2 then requires one more, empty packet so the host stops
    // polling instead of waiting for bytes that never come.
    final mpsBits = maxPacketSize.bitLength - 1;
    final atPacketBoundary = bytesSent
        .getRange(0, mpsBits)
        .eq(Const(0, width: mpsBits))
        .named('at_packet_boundary');
    final needZlp =
        (atPacketBoundary &
                bytesSent.gt(Const(0, width: 16)) &
                ~wLengthTruncBound)
            .named('need_in_zlp');
    final finishDataIn = (ep0InAcked & allDataSent).named('finish_data_in');
    final ep0Req = (ctrlState.eq(Const(cDataIn, width: 3)) & moreDataToSend)
        .named('ep0_req');
    final ep0InReadyOut =
        (ctrlState.eq(Const(cDataIn, width: 3)) &
                ~isStandard &
                moreDataToSend &
                ep0DataFree)
            .named('ep0_in_ready_out');

    // ==================================================================
    // OUT data stage: bytes drain from the engine's endpoint 0 buffer to
    // the function device with a ready/valid handshake. A byte is only
    // released from the engine once the function has taken the previous
    // one, so the engine NAKs the next OUT packet until the function
    // keeps up.
    // ==================================================================
    final ep0OutReady = func.port('ep0_out_ready');
    final consumeCond =
        (ctrlState.eq(Const(cDataOut, width: 3)) & outHeld & ep0OutReady).named(
          'ep0_out_consume',
        );
    final reachedAfterConsume = (bytesSent + Const(1, width: 16))
        .gte(wLength)
        .named('ep0_out_reached');
    final doneEdge = (consumeCond & reachedAfterConsume).named(
      'ep0_out_done_edge',
    );
    final captureCond =
        (ctrlState.eq(Const(cDataOut, width: 3)) &
                ~outHeld &
                outDrainPhase.eq(Const(0)) &
                ep0Avail)
            .named('ep0_out_capture');

    // SET_INTERFACE, USB 2.0 9.4.10: the (interface, alternate setting)
    // pair must be one the CONFIGURATION descriptor actually declares, or
    // the request STALLs instead of latching a setting nothing serves.
    final isSetInterface =
        (bmRequestType.eq(Const(0x01, width: 8)) &
                bRequest.eq(Const(11, width: 8)))
            .named('is_set_interface');
    final validInterfaceAlts = _usbInterfaceAltPairs(descriptors);
    final isValidInterfaceAlt =
        (validInterfaceAlts.isEmpty
                ? Const(0, width: 1)
                : validInterfaceAlts
                      .map(
                        (pair) =>
                            wIndex.eq(Const(pair[0], width: 16)) &
                            wValue.eq(Const(pair[1], width: 16)),
                      )
                      .reduce((a, b) => a | b))
            .named('is_valid_interface_alt');
    final setInterfaceWantStall = (isSetInterface & ~isValidInterfaceAlt).named(
      'set_interface_want_stall',
    );

    // ==================================================================
    // Dispatch decision wires for a standard request.
    // ==================================================================
    final wantStall =
        (inDataStage & ~effPresent |
                outDataStage |
                featureEpWantStall |
                setInterfaceWantStall)
            .named('want_stall');
    // Excludes wantStall so a feature request that is about to STALL
    // never also arms the zero-length-packet status path.
    final wantZlp = (~inDataStage & ~outDataStage & ~wantStall).named(
      'want_zlp',
    );
    final dispatched =
        (ctrlState.eq(Const(cSetupCollect, width: 3)) &
                setupCount.eq(Const(8, width: 4)))
            .named('dispatched');
    final acceptNow =
        (ctrlState.eq(Const(cFuncWait, width: 3)) & func.port('setup_accept'))
            .named('accept_now');
    final stallNow =
        (ctrlState.eq(Const(cFuncWait, width: 3)) & func.port('setup_stall'))
            .named('stall_now');

    // A new SETUP preempts whatever control transfer is in progress (USB
    // 2.0 8.5.3/9.2.6.4). cIdle, cSetupCollect and cStall already handle
    // this below. Every other state is a transfer this SETUP abandons.
    final newSetupWhileBusy =
        (ep0Avail &
                ep0SetupFlag &
                ~ctrlState.eq(Const(cIdle, width: 3)) &
                ~ctrlState.eq(Const(cSetupCollect, width: 3)) &
                ~ctrlState.eq(Const(cStall, width: 3)))
            .named('new_setup_while_busy');

    // ==================================================================
    // Control transfer combinational next-state logic.
    // ==================================================================
    Combinational([
      ctrlStateNext < ctrlState,

      Case(
        ctrlState,
        [
          CaseItem(Const(cIdle, width: 3), [
            If(
              ep0Avail & ep0SetupFlag,
              then: [ctrlStateNext < Const(cSetupCollect, width: 3)],
            ),
          ]),

          CaseItem(Const(cSetupCollect, width: 3), [
            If(
              setupCount.eq(Const(8, width: 4)),
              then: [
                If(
                  isStandard,
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
                  orElse: [ctrlStateNext < Const(cFuncWait, width: 3)],
                ),
              ],
            ),
          ]),

          CaseItem(Const(cFuncWait, width: 3), [
            If(
              func.port('setup_stall'),
              then: [ctrlStateNext < Const(cStall, width: 3)],
              orElse: [
                If(
                  func.port('setup_accept'),
                  then: [
                    If(
                      wLengthIsZero,
                      then: [ctrlStateNext < Const(cStatusIn, width: 3)],
                      orElse: [
                        If(
                          reqDirIn,
                          then: [ctrlStateNext < Const(cDataIn, width: 3)],
                          orElse: [ctrlStateNext < Const(cDataOut, width: 3)],
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ]),

          CaseItem(Const(cDataIn, width: 3), [
            If(
              finishDataIn & (zlpPendingQ | ~needZlp),
              then: [ctrlStateNext < Const(cStatusOut, width: 3)],
            ),
          ]),

          CaseItem(Const(cDataOut, width: 3), [
            If(doneEdge, then: [ctrlStateNext < Const(cStatusIn, width: 3)]),
          ]),

          CaseItem(Const(cStatusIn, width: 3), [
            If(ep0InAcked, then: [ctrlStateNext < Const(cIdle, width: 3)]),
          ]),

          CaseItem(Const(cStatusOut, width: 3), [
            If(ep0Acked, then: [ctrlStateNext < Const(cIdle, width: 3)]),
          ]),

          CaseItem(Const(cStall, width: 3), [
            If(
              ep0SetupFlag & ep0Avail,
              then: [ctrlStateNext < Const(cSetupCollect, width: 3)],
            ),
          ]),
        ],
        defaultItem: [ctrlStateNext < Const(cIdle, width: 3)],
      ),

      // Overrides whatever the Case above decided: a SETUP that lands
      // while a different transfer is in progress always wins.
      If(
        newSetupWhileBusy,
        then: [ctrlStateNext < Const(cSetupCollect, width: 3)],
      ),
    ]);

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
          bytesSent < Const(0, width: 16),
          allSentQ < Const(0),
          devAddrReg < Const(0, width: 7),
          newDevAddr < Const(0, width: 7),
          configuredReg < Const(0),
          saveDevAddr < Const(0),
          altSettingReg < Const(0, width: 8),
          newAltSetting < Const(0, width: 8),
          saveAltSetting < Const(0),
          ep0Stall < Const(0),
          sendZlp < Const(0),
          setupValidQ < Const(0),
          funcLastLatched < Const(0),
          outHeld < Const(0),
          outByte < Const(0, width: 8),
          outDrainPhase < Const(0),
          ep0OutEndQ < Const(0),
          zlpPendingQ < Const(0),
          zlpArmQ < Const(0),
          ep0AbortQ < Const(0),
        ],
        orElse: [
          ctrlState < ctrlStateNext,
          allSentQ < allDataSent,

          If(
            newSetupWhileBusy,
            then: [ep0AbortQ < Const(1)],
            orElse: [ep0AbortQ < Const(0)],
          ),

          // The engine stall input is a level, so EP0 stays stalled
          // until the next SETUP (USB 2.0 8.5.3.4).
          If(
            pe.output('out_ep_setup_token')[0],
            then: [ep0Stall < Const(0)],
            orElse: [
              If(
                (dispatched & isStandard & wantStall) | stallNow,
                then: [ep0Stall < Const(1)],
              ),
            ],
          ),
          // The OUT data stage has no use for EP0 IN, so the engine's
          // IN side is never pulled out of its idle put cycle. Pulsing
          // send_zlp once the last byte is taken moves it into the
          // state that answers the status stage with an empty packet.
          If(
            (dispatched & isStandard & wantZlp) |
                (acceptNow & wLengthIsZero) |
                doneEdge |
                zlpArmQ,
            then: [sendZlp < Const(1)],
            orElse: [sendZlp < Const(0)],
          ),
          // Tracks the trailing IN ZLP across the two acks it takes:
          // set on the ack that finds the boundary, cleared on the ack
          // of the empty packet that answers it. zlpArmQ pulses one
          // cycle later, once the engine's endpoint is back in putting.
          If(
            finishDataIn,
            then: [
              If(
                needZlp & ~zlpPendingQ,
                then: [zlpPendingQ < Const(1), zlpArmQ < Const(1)],
                orElse: [zlpPendingQ < Const(0), zlpArmQ < Const(0)],
              ),
            ],
            orElse: [zlpArmQ < Const(0)],
          ),
          If(
            dispatched & ~isStandard,
            then: [setupValidQ < Const(1)],
            orElse: [setupValidQ < Const(0)],
          ),

          // The SETUP drain: on phase 0 with data available, pulse the
          // get. Phase 1 lets the read pipeline settle.
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

          // The OUT data stage drain: same two-phase shape as SETUP. A
          // byte is only fetched once the previous one has been taken by
          // the function (outHeld low).
          If(
            captureCond,
            then: [
              outByte < ep0Data,
              outHeld < Const(1),
              outDrainPhase < Const(1),
            ],
          ),
          If(outDrainPhase.eq(Const(1)), then: [outDrainPhase < Const(0)]),
          If(
            consumeCond,
            then: [
              outHeld < Const(0),
              bytesSent < bytesSent + Const(1, width: 16),
            ],
          ),
          If(
            doneEdge,
            then: [ep0OutEndQ < Const(1)],
            orElse: [ep0OutEndQ < Const(0)],
          ),

          // The IN data stage: count the bytes put, from the ROM or the
          // function device.
          If(ep0InAccept, then: [bytesSent < bytesSent + Const(1, width: 16)]),
          If(
            ep0InAccept & ~isStandard & ep0InLast,
            then: [funcLastLatched < Const(1)],
          ),

          // SET_ADDRESS latches the new address when the status stage
          // completes, so the status token still uses the old address.
          If(
            ctrlState.eq(Const(cStatusIn, width: 3)) &
                isStandard &
                bRequest.eq(Const(5, width: 8)) &
                ep0InAcked,
            then: [saveDevAddr < Const(1), newDevAddr < wValue.slice(6, 0)],
          ),
          If(
            saveDevAddr,
            then: [saveDevAddr < Const(0), devAddrReg < newDevAddr],
          ),

          // SET_CONFIGURATION latches the configured flag and sets the
          // alternate setting back to 0 when the status stage completes.
          If(
            ctrlState.eq(Const(cStatusIn, width: 3)) &
                isStandard &
                bRequest.eq(Const(9, width: 8)) &
                ep0InAcked,
            then: [
              configuredReg < wValue.neq(Const(0, width: 16)),
              altSettingReg < Const(0, width: 8),
            ],
          ),

          // SET_INTERFACE latches the alternate setting the same way.
          If(
            ctrlState.eq(Const(cStatusIn, width: 3)) &
                isStandard &
                bRequest.eq(Const(11, width: 8)) &
                ep0InAcked,
            then: [
              saveAltSetting < Const(1),
              newAltSetting < wValue.slice(7, 0),
            ],
          ),
          If(
            saveAltSetting,
            then: [saveAltSetting < Const(0), altSettingReg < newAltSetting],
          ),

          // Reset the byte counters when a transfer completes, or when a
          // new SETUP abandons one early, so the next dispatch starts
          // fresh.
          If(
            ((ctrlState.eq(Const(cStatusIn, width: 3)) |
                        ctrlState.eq(Const(cStatusOut, width: 3))) &
                    ctrlStateNext.eq(Const(cIdle, width: 3))) |
                newSetupWhileBusy,
            then: [
              bytesSent < Const(0, width: 16),
              setupCount < Const(0, width: 4),
              funcLastLatched < Const(0),
            ],
          ),

          // Every SETUP capture starts at byte 0.
          If(
            ctrlStateNext.eq(Const(cSetupCollect, width: 3)) &
                ~ctrlState.eq(Const(cSetupCollect, width: 3)),
            then: [setupCount < Const(0, width: 4)],
          ),

          // An abandoned OUT data stage must not leave a stale held byte,
          // or trailing-ZLP bookkeeping, visible to the function or the
          // engine for the request that replaces it.
          If(
            newSetupWhileBusy,
            then: [
              outHeld < Const(0),
              outDrainPhase < Const(0),
              ep0OutEndQ < Const(0),
              sendZlp < Const(0),
              zlpPendingQ < Const(0),
              zlpArmQ < Const(0),
            ],
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

    // The EP0 get pulse drives both the SETUP drain and the OUT data
    // stage drain.
    getEp0 <=
        (ctrlState.eq(Const(cSetupCollect, width: 3)) &
                drainPhase.eq(Const(0)) &
                ep0Avail &
                setupCount.lt(Const(8, width: 4))) |
            captureCond;

    // ==================================================================
    // Function interface: provider side signals driven by the core.
    // ==================================================================
    func.port('configured') <= configuredReg;
    func.port('bus_reset') <= busResetDet.output('bus_reset');
    func.port('alt_setting') <= altSettingReg;
    func.port('setup_valid') <= setupValidQ;
    func.port('setup_data') <=
        [
          setupBytes[7],
          setupBytes[6],
          setupBytes[5],
          setupBytes[4],
          setupBytes[3],
          setupBytes[2],
          setupBytes[1],
          setupBytes[0],
        ].swizzle();
    func.port('ep0_out_data') <= outByte;
    func.port('ep0_out_valid') <= outHeld;
    func.port('ep0_out_end') <= ep0OutEndQ;
    func.port('ep0_abort') <= ep0AbortQ;
    func.port('ep0_in_ready') <= ep0InReadyOut;

    // ==================================================================
    // Engine input wiring: endpoint 0 plus any extra endpoints passed
    // through to the function device unchanged.
    // ==================================================================
    final outEpReqList = <Logic>[ep0Avail];
    final outDataGetList = <Logic>[getEp0];
    final outStallList = <Logic>[ep0Stall];
    final inEpReqList = <Logic>[ep0Req];
    final inEpDataPutList = <Logic>[ep0InAccept];
    final inEpDataList = <Logic>[effDataFinal];
    final inEpDataDoneList = <Logic>[ep0DataDone];
    final inStallList = <Logic>[ep0Stall];

    if (numOutEps > 0) {
      outEpReqList.add(func.port('out_ep_req'));
      outDataGetList.add(func.port('out_ep_data_get'));
      outStallList.add(func.port('out_ep_stall') | hostHaltOutBits.rswizzle());
    }
    if (numInEps > 0) {
      inEpReqList.add(func.port('in_ep_req'));
      inEpDataPutList.add(func.port('in_ep_data_put'));
      inEpDataList.add(func.port('in_ep_data'));
      inEpDataDoneList.add(func.port('in_ep_data_done'));
      inStallList.add(func.port('in_ep_stall') | hostHaltInBits.rswizzle());
    }

    pe.input('out_ep_data_get').srcConnection! <= outDataGetList.rswizzle();
    pe.input('out_ep_req').srcConnection! <= outEpReqList.rswizzle();
    pe.input('out_ep_stall').srcConnection! <= outStallList.rswizzle();
    pe.input('in_ep_stall').srcConnection! <= inStallList.rswizzle();
    pe.input('in_ep_req').srcConnection! <= inEpReqList.rswizzle();
    pe.input('in_ep_data_done').srcConnection! <= inEpDataDoneList.rswizzle();
    pe.input('in_ep_data').srcConnection! <= inEpDataList.rswizzle();
    pe.input('in_ep_data_put').srcConnection! <= inEpDataPutList.rswizzle();

    // SET_CONFIGURATION/SET_INTERFACE reset every extra endpoint's data
    // toggle. CLEAR_FEATURE(ENDPOINT_HALT) resets only the addressed one.
    final toggleResetAllDone = (setConfigStatusDone | setInterfaceStatusDone)
        .named('toggle_reset_all_done');
    final outEpToggleReset = [
      // ep0's OUT side never needs this: a SETUP preempts an unread
      // packet by itself (HarborUsbFsOutPe's stGetting case), so there
      // is never a stale received packet left armed to flush here.
      Const(0, width: 1),
      for (var i = 0; i < numOutEps; i++)
        (toggleResetAllDone | (clearFeatureEpStatusDone & outEpMatchBits[i]))
            .named('out_ep_toggle_reset_${i + 1}'),
    ].rswizzle();
    final inEpToggleReset = [
      // ep0's IN side never needs this: a SETUP preempts a packet the
      // function is writing or has armed to send (HarborUsbFsInPe's
      // stPutting/stGetting), so there is no stale packet to flush here.
      // It would also race the DATA1 the SETUP itself forces (USB 2.0
      // 8.5.3), so the toggle stays untouched by the abort.
      Const(0, width: 1),
      for (var i = 0; i < numInEps; i++)
        (toggleResetAllDone | (clearFeatureEpStatusDone & inEpMatchBits[i]))
            .named('in_ep_toggle_reset_${i + 1}'),
    ].rswizzle();
    pe.input('out_ep_toggle_reset').srcConnection! <= outEpToggleReset;
    pe.input('in_ep_toggle_reset').srcConnection! <= inEpToggleReset;

    if (numOutEps > 0) {
      func.port('out_ep_grant') <=
          pe.output('out_ep_grant').slice(numOutEps, 1);
      func.port('out_ep_data_avail') <=
          pe.output('out_ep_data_avail').slice(numOutEps, 1);
      func.port('out_ep_setup') <=
          pe.output('out_ep_setup').slice(numOutEps, 1);
      func.port('out_ep_data') <= pe.output('out_ep_data');
      func.port('out_ep_acked') <=
          pe.output('out_ep_acked').slice(numOutEps, 1);
      func.port('out_ep_pkt_full') <=
          pe.output('out_ep_pkt_full').slice(numOutEps, 1);
    }
    if (numInEps > 0) {
      func.port('in_ep_grant') <= pe.output('in_ep_grant').slice(numInEps, 1);
      func.port('in_ep_data_free') <=
          pe.output('in_ep_data_free').slice(numInEps, 1);
      func.port('in_ep_acked') <= pe.output('in_ep_acked').slice(numInEps, 1);
    }
  }
}
