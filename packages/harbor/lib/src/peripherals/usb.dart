import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../clock/cdc.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import 'usb_fs_pe.dart';

/// USB endpoint transfer type, encoded in EP_CFG.
enum HarborUsbEndpointType { control, isochronous, bulk, interrupt }

/// Maximum packet payload per endpoint, in bytes (USB full speed).
const _maxPacketSize = 64;

// Global register byte offsets.
const _ctrlAddr = 0x000;
const _statusAddr = 0x008;
const _addrAddr = 0x010;
const _intStatusAddr = 0x018;
const _intEnableAddr = 0x020;
const _frameAddr = 0x028;

// The register window is 0x400 bytes.
const _windowBits = 10;

// Per-endpoint block layout.
const _epBase = 0x200;
const _epStride = 0x40;
const _cfgOff = 0x00;
const _outStatOff = 0x08;
const _outDataOff = 0x10;
const _outAckOff = 0x18;
const _inDataOff = 0x20;
const _inCommitOff = 0x28;
const _inStatOff = 0x30;
const _inFlushOff = 0x38;

// Cross-domain action opcodes (bus -> usb, single outstanding).
const _opPopOut = 1;
const _opRelease = 2;
const _opCommitIn = 3;
const _opCfg = 4;
const _opSetAddr = 5;
const _opCfgRead = 6;
const _opFlushIn = 7;

// usb-domain action FSM states.
const _uIdle = 0;
const _uPopAssert = 1;
const _uPopCapture = 2;
const _uReleaseSt = 3;
const _uCommitWait = 4;
const _uCfgSt = 5;
const _uSetAddrSt = 6;
const _uCfgReadSt = 7;
const _uFlushSt = 8;

/// Memory-mapped USB full-speed device controller.
///
/// Exposes [HarborUsbFsPe] to a CPU over a Wishbone slave for a Linux UDC
/// driver. The protocol engine runs on `usb_clk`. The register file runs on
/// `clk`. Crossings use [HarborCdcFifo] for bytes, [HarborCdcSync] for a
/// held level, or a toggle plus edge detect for a one-shot event.
///
/// Register map (8-byte slots, byte offsets from `baseAddress`):
///
/// | Offset | Register | Bits |
/// |---|---|---|
/// | 0x000 | CTRL | `[0]` enable, `[1]` connect |
/// | 0x008 | STATUS | `[0]` bus reset active |
/// | 0x010 | ADDR | `[6:0]` device address, 0 after a bus reset |
/// | 0x018 | INT_STATUS (W1C) | `[0]` reset, `[1]` SOF, `[2]` local reset, `[8+n]`/`[16+n]` EPn OUT/IN |
/// | 0x020 | INT_ENABLE | same layout |
/// | 0x028 | FRAME | `[10:0]` frame number of the last SOF |
/// | +0x00 per EP (`0x200+n*0x40`) | EP_CFG | `[0]` enable, `[2:1]` type (reset: control on EP0, bulk on others), `[3]`/`[4]` stall OUT/IN (read: state, write 1: set), `[5]`/`[6]` toggle reset OUT/IN, `[7]`/`[8]` stall clear OUT/IN (write 1) |
/// | +0x08 | OUT_STAT (RO) | `[0]` ready, `[1]` is SETUP, `[7:4]` tag, `[15:8]` length |
/// | +0x10 | OUT_DATA (RO) | pops one byte, 0 past the end |
/// | +0x18 | OUT_ACK (WO) | `[7:4]` tag: frees the packet with that tag |
/// | +0x20 | IN_DATA (WO) | pushes one byte |
/// | +0x28 | IN_COMMIT (WO) | arms the packet, zero length allowed |
/// | +0x30 | IN_STAT (RO) | `[0]` buffer free, `[1]` last packet acked |
/// | +0x38 | IN_FLUSH (WO) | any value: drops the IN packet and pushed bytes |
///
/// The endpoint NAKs OUT packets until OUT_ACK frees the held one. Write
/// back the OUT_STAT value to free it. A SETUP preempts the held packet and
/// gets a new tag, so a late OUT_ACK for the old packet does nothing. After
/// popping OUT_DATA, read OUT_STAT again before trusting the bytes: a SETUP
/// can preempt mid-read, and ready reads 0 or the tag changes.
///
/// Wait for IN-done before the next IN_COMMIT on an endpoint, because a
/// commit while a packet is armed holds the bus until the host reads it.
/// A zero-length IN_COMMIT while a packet is armed is lost.
/// A SETUP on a control endpoint drops its armed or partly pushed IN packet.
///
/// IN_FLUSH drops the armed IN packet and the bytes pushed since the last
/// commit, and the endpoint is unarmed. If an IN transaction on the
/// endpoint is in progress, the flush waits for it to end. A packet the
/// host ACKs then counts as sent. For any line state, the transaction
/// ends at most 256 `usb_clk` cycles (64 bit times) after the data packet,
/// and 108 cycles (27 bit times) after it if no packet starts. The flush
/// then acks after the clock crossings. When the write acks, IN-done for the
/// endpoint is clear in INT_STATUS and IN_STAT and cannot come later. The
/// flush does not change the toggle, a stall or the OUT side.
///
/// The bus side counts the IN_DATA bytes of each endpoint since its last
/// IN_COMMIT or IN_FLUSH and sends the count with that op. The USB side
/// arms or flushes only once exactly that many bytes of the endpoint came
/// out of the push FIFO, so the result does not depend on the clock ratio.
///
/// EP_CFG write bits `[3]` to `[8]` act on 1 and do nothing on
/// 0, so enable and type writes never change a stall. If set and clear are
/// both 1, set wins. Each EP_CFG access goes to the usb clock domain and
/// acks after it applies there. A read returns both stall bits from one
/// usb clock cycle.
///
/// A stall applies to a transaction whose handshake has not been sent yet:
/// an OUT whose data packet has not started, or an IN not yet armed with a
/// reply. A packet that is already held or armed stays. A SETUP to
/// an endpoint of type control is always ACKed (USB 2.0 8.5.3), and its
/// stall bits clear when the SETUP is held. A stall written before that
/// point, or on the same cycle, is cleared. A stall written after it
/// applies to the new request. A SETUP to another type is ignored with no
/// handshake. The driver can clear the EP0 stall when it reads a SETUP.
///
/// A toggle reset sets the next expected or sent toggle to DATA0 when no
/// transaction on that endpoint is in progress. It does not change a held
/// packet or a stall. A stall clear on a non-control endpoint also resets
/// that direction's toggle (USB 2.0 9.4.5). A SETUP sets the toggles of a
/// control endpoint and cancels a waiting toggle reset.
///
/// A bus reset discards all endpoint data, clears ADDR and every EP_CFG
/// stall bit, and leaves only INT_STATUS `[0]` set. ADDR writes while
/// STATUS `[0]` is set are ignored. EP_CFG enable is stored for the driver
/// only. Type selects which endpoints accept a SETUP. After reset only
/// EP0 is type control, and the others are bulk. A bus reset also
/// drops a waiting toggle reset.
///
/// `reset` resets everything. A lone `usb_reset` is a local reset. It keeps
/// CTRL, INT_ENABLE and EP_CFG, clears ADDR and the endpoint data, and
/// when it releases sets only INT_STATUS `[0]` and `[2]`. Write EP_CFG
/// again to restore a non-EP0 endpoint of type control.
///
/// While the local reset is active, registers that live on the bus side
/// read and write normally. An access that needs the USB side acks with
/// no effect and reads 0. An access in flight when it starts acks the same
/// way. After it releases, the pullup stays off for [localResetDetachUs]
/// so the host sees a detach and enumerates the device again.
class HarborUsbController extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Number of endpoints, including EP0 (1..8: the 0x400 register window
  /// has room for 8 endpoint blocks).
  final int numEndpoints;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  /// Frequency of `usb_clk` in Hz.
  final int usbClkHz;

  /// Time the pullup stays off after a local reset, in microseconds.
  final int localResetDetachUs;

  /// [localResetDetachUs] in `usb_clk` cycles.
  int get localResetDetachCycles =>
      (BigInt.from(usbClkHz) *
              BigInt.from(localResetDetachUs) ~/
              BigInt.from(1000000))
          .toInt();

  HarborUsbController({
    required this.baseAddress,
    this.numEndpoints = 4,
    this.usbClkHz = 48000000,
    this.localResetDetachUs = 10000,
    int busAddressWidth = 32,
    int busDataWidth = 32,
    String? name,
  }) : super('HarborUsbController', name: name ?? 'usb') {
    if (usbClkHz <= 0 || localResetDetachUs <= 0) {
      throw ArgumentError('usbClkHz and localResetDetachUs must be > 0');
    }
    if (localResetDetachCycles < 1 || localResetDetachCycles >= (1 << 32)) {
      throw ArgumentError(
        'localResetDetachCycles must be 1..2^32-1, got '
        '$localResetDetachCycles',
      );
    }
    if (numEndpoints < 1 || numEndpoints > 8) {
      throw ArgumentError('numEndpoints must be 1..8, got $numEndpoints');
    }
    if (busAddressWidth < _windowBits) {
      throw ArgumentError(
        'busAddressWidth must be at least $_windowBits, got $busAddressWidth',
      );
    }
    if (busDataWidth != 32 && busDataWidth != 64) {
      throw ArgumentError('busDataWidth must be 32 or 64, got $busDataWidth');
    }

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('usb_clk', PortDirection.input);
    createPort('usb_reset', PortDirection.input);
    createPort('dp', PortDirection.input);
    createPort('dm', PortDirection.input);
    addOutput('dp_out');
    addOutput('dm_out');
    addOutput('oe');
    addOutput('usb_pullup');
    addOutput('interrupt');

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: BusProtocol.wishbone,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: busAddressWidth,
      dataWidth: busDataWidth,
    );

    final clk = input('clk');
    final usbClk = input('usb_clk');
    // Either reset resets every crossing on both sides together. The
    // registers software owns reset on `reset` only. Its chain has the same
    // length as the joined one, so a reset of both releases on one edge.
    final busOwnReset = harborCdcJoinReset(
      clk,
      input('reset'),
      input('reset'),
      name: 'bus_own_reset',
    );
    final reset = harborCdcJoinReset(
      clk,
      input('reset'),
      input('usb_reset'),
      name: 'bus_join_reset',
    );
    final usbReset = harborCdcJoinReset(
      usbClk,
      input('usb_reset'),
      input('reset'),
      name: 'usb_join_reset',
    );
    final dw = busDataWidth;
    final epIdxWidth = numEndpoints <= 1 ? 1 : (numEndpoints - 1).bitLength;

    // ==================================================================
    // Protocol engine and bus-reset detector (usb_clk domain).
    // ==================================================================
    final busResetDet = HarborUsbFsResetDet(name: 'bus_reset_det');
    addSubModule(busResetDet);
    busResetDet.input('clk').srcConnection! <= usbClk;
    busResetDet.input('reset').srcConnection! <= usbReset;
    final busResetUsb = busResetDet.output('bus_reset');

    // A bus reset resets the engine only. The crossings stay paired.
    final peReset = (usbReset | busResetUsb).named('usb_pe_reset');

    final devAddrUsb = Logic(name: 'dev_addr_usb_q', width: 7);

    final pe = HarborUsbFsPe(
      numOutEps: numEndpoints,
      numInEps: numEndpoints,
      maxPacketSize: _maxPacketSize,
      exposeEpToggleReset: true,
      exposeEpLength: true,
      exposeEpRelease: true,
      exposeEpSetupDone: true,
      exposeEpControl: true,
      exposeEpFlush: true,
      name: 'fs_pe',
    );
    addSubModule(pe);
    pe.input('clk').srcConnection! <= usbClk;
    pe.input('reset').srcConnection! <= peReset;
    pe.input('dev_addr').srcConnection! <= devAddrUsb;
    final lenWidth = pe.output('out_ep_length').width ~/ numEndpoints;

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

    output('dp_out') <= pe.output('usb_p_tx');
    output('dm_out') <= pe.output('usb_n_tx');
    output('oe') <= pe.output('usb_tx_en');

    // ==================================================================
    // Bus-domain registers.
    // ==================================================================
    final ctrlEnable = Logic(name: 'ctrl_enable_q');
    final ctrlConnect = Logic(name: 'ctrl_connect_q');
    final addrReg = Logic(name: 'addr_reg_q', width: 7);
    final intStatus = Logic(name: 'int_status_q', width: 32);
    final intEnable = Logic(name: 'int_enable_q', width: 32);
    final frameBus = Logic(name: 'frame_bus_q', width: 11);

    final epEnableBus = List.generate(
      numEndpoints,
      (i) => Logic(name: 'ep_enable_${i}_q'),
    );
    final epTypeBus = List.generate(
      numEndpoints,
      (i) => Logic(name: 'ep_type_${i}_q', width: 2),
    );

    // OUT_STAT fields. They change together on one bus clock edge.
    final outReadyBus = List.generate(
      numEndpoints,
      (i) => Logic(name: 'out_ready_${i}_q'),
    );
    final outSetupBus = List.generate(
      numEndpoints,
      (i) => Logic(name: 'out_setup_${i}_q'),
    );
    final outTagBus = List.generate(
      numEndpoints,
      (i) => Logic(name: 'out_tag_${i}_q', width: 4),
    );
    final outLengthBus = List.generate(
      numEndpoints,
      (i) => Logic(name: 'out_length_${i}_q', width: lenWidth),
    );
    final outHeldPrevBus = List.generate(
      numEndpoints,
      (i) => Logic(name: 'out_held_prev_${i}_q'),
    );

    // Shared single-outstanding cross-domain action channel: at most one
    // register access needs the usb domain at a time, since the Wishbone
    // bus itself only ever has one transaction in flight.
    final opBusy = Logic(name: 'op_busy_q');
    final opRegBus = Logic(name: 'op_reg_bus_q', width: 3);
    final opEpBus = Logic(name: 'op_ep_bus_q', width: epIdxWidth);
    final opPayloadBus = Logic(name: 'op_payload_bus_q', width: 7);
    final opReqToggleBus = Logic(name: 'op_req_toggle_bus_q');
    final opDoneToggleUsb = Logic(name: 'op_done_toggle_usb_q');

    final inPushWrEn = Logic(name: 'in_push_wr_en_q');
    // IN_DATA bytes of each endpoint since its last commit or flush, and
    // the count sent with a commit or flush op.
    final inPushedBus = List.generate(
      numEndpoints,
      (i) => Logic(name: 'in_pushed_bus_${i}_q', width: 8),
    );
    final opCountBus = Logic(name: 'op_count_bus_q', width: 8);
    final inPushWrData = Logic(
      name: 'in_push_wr_data_q',
      width: 8 + epIdxWidth,
    );

    // ==================================================================
    // CDC primitives. Only the joined system resets touch these.
    // ==================================================================
    final opPulseUsb = _toggleEdgeDetect(
      opReqToggleBus,
      usbClk,
      usbReset,
      'op_req',
    );
    final opDonePulseBus = _toggleEdgeDetect(
      opDoneToggleUsb,
      clk,
      reset,
      'op_done',
    );
    final sofPulseBus = _pulseCrossing(
      srcClk: usbClk,
      srcReset: usbReset,
      srcPulse: pe.output('sof_valid'),
      dstClk: clk,
      dstReset: reset,
      name: 'sof',
    );

    // A packet is held from its ACK until OUT_ACK, a SETUP that preempts
    // it, or a bus reset. The tag counts packets per endpoint.
    final outHeldUsb = pe.output('out_ep_held');
    final heldPrevUsb = List.generate(
      numEndpoints,
      (i) => Logic(name: 'out_held_prev_usb_${i}_q'),
    );
    final tagUsb = List.generate(
      numEndpoints,
      (i) => Logic(name: 'out_tag_usb_${i}_q', width: 4),
    );
    final setupCapUsb = List.generate(
      numEndpoints,
      (i) => Logic(name: 'out_setup_cap_usb_${i}_q'),
    );
    final lengthCapUsb = List.generate(
      numEndpoints,
      (i) => Logic(name: 'out_length_cap_usb_${i}_q', width: lenWidth),
    );
    final pktToggleUsb = List.generate(
      numEndpoints,
      (i) => Logic(name: 'out_pkt_toggle_usb_${i}_q'),
    );
    final pktPulseBus = List.generate(
      numEndpoints,
      (i) => _toggleEdgeDetect(pktToggleUsb[i], clk, reset, 'out_pkt_$i'),
    );
    final heldBus = List.generate(
      numEndpoints,
      (i) => _levelCrossing(outHeldUsb.slice(i, i), clk, reset, 'out_held_$i'),
    );
    final frameUsb = Logic(name: 'frame_usb_q', width: 11);

    final inFreeBus = List.generate(
      numEndpoints,
      (i) => _levelCrossing(
        pe.output('in_ep_data_free').slice(i, i),
        clk,
        reset,
        'in_free_$i',
      ),
    );
    final busResetBus = _levelCrossing(
      busResetUsb,
      clk,
      reset,
      'bus_reset_lvl',
    );

    final ackedSticky = List.generate(
      numEndpoints,
      (i) => Logic(name: 'in_acked_sticky_${i}_q'),
    );
    final ackedBus = List.generate(
      numEndpoints,
      (i) => _levelCrossing(ackedSticky[i], clk, reset, 'in_acked_sticky_$i'),
    );

    // The usb domain owns the stall state. EP_CFG writes, a SETUP held on
    // a control endpoint, and a bus reset change it, in the order they
    // land here. The PE itself never stalls a SETUP.
    final stallOutUsb = List.generate(
      numEndpoints,
      (i) => Logic(name: 'stall_out_usb_${i}_q'),
    );
    final stallInUsb = List.generate(
      numEndpoints,
      (i) => Logic(name: 'stall_in_usb_${i}_q'),
    );
    final epControlUsb = List.generate(
      numEndpoints,
      (i) => Logic(name: 'ep_control_usb_${i}_q'),
    );
    final setupDoneUsb = pe.output('out_ep_setup_done');
    final setupClearUsb = List.generate(
      numEndpoints,
      (i) => (setupDoneUsb[i] & epControlUsb[i]).named('setup_clear_$i'),
    );
    pe.input('out_ep_control').srcConnection! <= epControlUsb.rswizzle();
    pe.input('out_ep_stall').srcConnection! <= stallOutUsb.rswizzle();
    pe.input('in_ep_stall').srcConnection! <= stallInUsb.rswizzle();

    // ==================================================================
    // Shared byte-path FIFOs.
    // ==================================================================
    final outRetFifo = HarborCdcFifo(dataWidth: 8, depth: 2, name: 'out_ret');
    addSubModule(outRetFifo);

    // An op is done once its done toggle crossed. A pop or EP_CFG read also
    // waits for its byte in out_ret: the FIFO empty flag can cross later
    // than the toggle, so the done is held until the byte is there.
    final opDoneHeld = Logic(name: 'op_done_held_q');
    final opNeedsRet =
        (opRegBus.eq(Const(_opPopOut, width: 3)) |
                opRegBus.eq(Const(_opCfgRead, width: 3)))
            .named('op_needs_ret');
    final opComplete =
        (opBusy &
                (opDonePulseBus | opDoneHeld) &
                (~opNeedsRet | ~outRetFifo.output('rd_empty')))
            .named('op_complete');
    outRetFifo.input('wr_clk').srcConnection! <= usbClk;
    outRetFifo.input('wr_reset').srcConnection! <= usbReset;
    outRetFifo.input('rd_clk').srcConnection! <= clk;
    outRetFifo.input('rd_reset').srcConnection! <= reset;
    outRetFifo.input('rd_en').srcConnection! <=
        (opComplete & opNeedsRet).named('out_ret_rd_en');

    final inPushFifo = HarborCdcFifo(
      dataWidth: 8 + epIdxWidth,
      depth: 64,
      name: 'in_push',
    );
    addSubModule(inPushFifo);
    inPushFifo.input('wr_clk').srcConnection! <= clk;
    inPushFifo.input('wr_reset').srcConnection! <= reset;
    inPushFifo.input('wr_en').srcConnection! <= inPushWrEn;
    inPushFifo.input('wr_data').srcConnection! <= inPushWrData;
    inPushFifo.input('rd_clk').srcConnection! <= usbClk;
    inPushFifo.input('rd_reset').srcConnection! <= usbReset;

    // ==================================================================
    // usb-domain action FSM: services one pop, release, commit, EP_CFG
    // or set-address request at a time. The bus-domain op registers
    // stay stable while the request toggle crosses, so it samples them.
    // ==================================================================
    final opState = Logic(name: 'op_state_usb_q', width: 4);
    final opRegUsb = Logic(name: 'op_reg_usb_q', width: 3);
    final opEpUsb = Logic(name: 'op_ep_usb_q', width: epIdxWidth);
    final opPayloadUsb = Logic(name: 'op_payload_usb_q', width: 7);
    final popHasData = Logic(name: 'pop_has_data_q');

    Logic selectByEp(Logic vec, Logic epSel) {
      Logic v = Const(0);
      for (var i = 0; i < numEndpoints; i++) {
        v = mux(epSel.eq(Const(i, width: epIdxWidth)), vec.slice(i, i), v);
      }
      return v;
    }

    // Sampled when the pop request arrives, so out_ep_data_get does not
    // depend on out_ep_data_avail in the same cycle.
    final reqOutAvail = selectByEp(
      pe.output('out_ep_data_avail'),
      opEpBus,
    ).named('req_out_avail');

    final popAssert = opState.eq(Const(_uPopAssert, width: 4));
    final outReqBits = List.generate(
      numEndpoints,
      (i) => (popAssert & opEpUsb.eq(Const(i, width: epIdxWidth))).named(
        'out_req_bit_$i',
      ),
    );
    final outGetBits = List.generate(
      numEndpoints,
      (i) => (outReqBits[i] & popHasData).named('out_get_bit_$i'),
    );
    pe.input('out_ep_req').srcConnection! <= outReqBits.rswizzle();
    pe.input('out_ep_data_get').srcConnection! <= outGetBits.rswizzle();

    final releaseBits = List.generate(
      numEndpoints,
      (i) =>
          (opState.eq(Const(_uReleaseSt, width: 4)) &
                  opEpUsb.eq(Const(i, width: epIdxWidth)) &
                  outHeldUsb[i] &
                  tagUsb[i].eq(opPayloadUsb.getRange(0, 4)))
              .named('out_release_$i'),
    );
    pe.input('out_ep_release').srcConnection! <= releaseBits.rswizzle();

    // Bytes of each endpoint popped from the push FIFO since its last
    // commit or flush. A commit or flush waits until this equals the count
    // the op carries.
    final inPoppedUsb = List.generate(
      numEndpoints,
      (i) => Logic(name: 'in_popped_usb_${i}_q', width: 8),
    );
    final opCountUsb = Logic(name: 'op_count_usb_q', width: 8);
    Logic poppedSel = Const(0, width: 8);
    for (var i = 0; i < numEndpoints; i++) {
      poppedSel = mux(
        opEpUsb.eq(Const(i, width: epIdxWidth)),
        inPoppedUsb[i],
        poppedSel,
      );
    }
    final opBytesIn = poppedSel.eq(opCountUsb).named('op_bytes_in');

    final commitFire = (opState.eq(Const(_uCommitWait, width: 4)) & opBytesIn)
        .named('commit_fire');
    final inDataDoneBits = List.generate(
      numEndpoints,
      (i) => (commitFire & opEpUsb.eq(Const(i, width: epIdxWidth))).named(
        'in_data_done_$i',
      ),
    );
    pe.input('in_ep_data_done').srcConnection! <= inDataDoneBits.rswizzle();

    // A flush waits until its bytes left the push FIFO and no IN
    // transaction on the endpoint is in progress. Its bytes drop meanwhile.
    final inFlushWait = opState
        .eq(Const(_uFlushSt, width: 4))
        .named('in_flush_wait');
    final inFlushFire =
        (inFlushWait &
                opBytesIn &
                ~selectByEp(pe.output('in_ep_busy'), opEpUsb))
            .named('in_flush_fire');
    final inFlushBits = List.generate(
      numEndpoints,
      (i) => (inFlushFire & opEpUsb.eq(Const(i, width: epIdxWidth))).named(
        'in_flush_$i',
      ),
    );
    pe.input('in_ep_flush').srcConnection! <= inFlushBits.rswizzle();

    // EP_CFG write payload: [0]/[1] toggle reset OUT/IN, [2]/[3] stall
    // set OUT/IN, [4] type is control, [5]/[6] stall clear OUT/IN.
    final toggleResetFire = opState.eq(Const(_uCfgSt, width: 4));
    final cfgSetOut = opPayloadUsb[2];
    final cfgSetIn = opPayloadUsb[3];
    final cfgControl = opPayloadUsb[4];
    final cfgClrOut = opPayloadUsb[5] & ~cfgSetOut;
    final cfgClrIn = opPayloadUsb[6] & ~cfgSetIn;

    // A stall clear on a non-control endpoint also resets the toggle to
    // DATA0 (USB 2.0 9.4.5). A SETUP sets the toggles of a control one.
    final outToggleBits = List.generate(
      numEndpoints,
      (i) =>
          (toggleResetFire &
                  opEpUsb.eq(Const(i, width: epIdxWidth)) &
                  (opPayloadUsb[0] | (cfgClrOut & ~cfgControl)))
              .named('out_toggle_reset_$i'),
    );
    final inToggleBits = List.generate(
      numEndpoints,
      (i) =>
          (toggleResetFire &
                  opEpUsb.eq(Const(i, width: epIdxWidth)) &
                  (opPayloadUsb[1] | (cfgClrIn & ~cfgControl)))
              .named('in_toggle_reset_$i'),
    );
    pe.input('out_ep_toggle_reset').srcConnection! <= outToggleBits.rswizzle();
    pe.input('in_ep_toggle_reset').srcConnection! <= inToggleBits.rswizzle();

    // Combinational: it fires while out_ep_data still holds the popped
    // byte, one cycle before the get address moves on.
    // An EP_CFG read returns both stall bits from one usb-domain cycle.
    final cfgReadFire = opState.eq(Const(_uCfgReadSt, width: 4));
    final stallPair = [
      selectByEp(stallInUsb.rswizzle(), opEpUsb),
      selectByEp(stallOutUsb.rswizzle(), opEpUsb),
    ].swizzle().named('stall_pair');
    final outRetPushEn =
        (opState.eq(Const(_uPopCapture, width: 4)) | cfgReadFire).named(
          'out_ret_push_en',
        );
    outRetFifo.input('wr_en').srcConnection! <= outRetPushEn;
    outRetFifo.input('wr_data').srcConnection! <=
        mux(
          cfgReadFire,
          stallPair.zeroExtend(8),
          mux(popHasData, pe.output('out_ep_data'), Const(0, width: 8)),
        );

    final outLengthUsb = pe.output('out_ep_length');
    final outSetupUsb = pe.output('out_ep_setup');

    Sequential(usbClk, [
      If(
        usbReset,
        then: [
          opState < Const(_uIdle, width: 4),
          opRegUsb < Const(0, width: 3),
          opEpUsb < Const(0, width: epIdxWidth),
          opPayloadUsb < Const(0, width: 7),
          opCountUsb < Const(0, width: 8),
          opDoneToggleUsb < Const(0),
          popHasData < Const(0),
          devAddrUsb < Const(0, width: 7),
          frameUsb < Const(0, width: 11),
          ...ackedSticky.map((a) => a < Const(0)),
          ...heldPrevUsb.map((h) => h < Const(0)),
          ...tagUsb.map((t) => t < Const(0, width: 4)),
          ...setupCapUsb.map((s) => s < Const(0)),
          ...lengthCapUsb.map((l) => l < Const(0, width: lenWidth)),
          ...pktToggleUsb.map((t) => t < Const(0)),
          ...stallOutUsb.map((s) => s < Const(0)),
          ...stallInUsb.map((s) => s < Const(0)),
          for (var i = 0; i < numEndpoints; i++)
            epControlUsb[i] < Const(i == 0 ? 1 : 0),
        ],
        orElse: [
          If(
            pe.output('sof_valid'),
            then: [frameUsb < pe.output('frame_index')],
          ),
          // The held packet's fields are stable from this edge on, so
          // they cross with the toggle that flips here.
          for (var i = 0; i < numEndpoints; i++) ...[
            heldPrevUsb[i] < outHeldUsb[i],
            If(
              outHeldUsb[i] & ~heldPrevUsb[i],
              then: [
                tagUsb[i] < tagUsb[i] + Const(1, width: 4),
                setupCapUsb[i] < outSetupUsb[i],
                lengthCapUsb[i] <
                    outLengthUsb.getRange(i * lenWidth, (i + 1) * lenWidth),
                pktToggleUsb[i] < ~pktToggleUsb[i],
              ],
            ),
          ],
          for (var i = 0; i < numEndpoints; i++)
            If(
              pe.output('in_ep_acked').slice(i, i),
              then: [ackedSticky[i] < Const(1)],
            ),
          If(
            commitFire | inFlushFire,
            then: [
              for (var i = 0; i < numEndpoints; i++)
                If(
                  opEpUsb.eq(Const(i, width: epIdxWidth)),
                  then: [ackedSticky[i] < Const(0)],
                ),
            ],
          ),
          Case(
            opState,
            [
              CaseItem(Const(_uIdle, width: 4), [
                If(
                  opPulseUsb,
                  then: [
                    opRegUsb < opRegBus,
                    opEpUsb < opEpBus,
                    opPayloadUsb < opPayloadBus,
                    opCountUsb < opCountBus,
                    Case(opRegBus, [
                      CaseItem(Const(_opPopOut, width: 3), [
                        popHasData < reqOutAvail,
                        opState < Const(_uPopAssert, width: 4),
                      ]),
                      CaseItem(Const(_opRelease, width: 3), [
                        opState < Const(_uReleaseSt, width: 4),
                      ]),
                      CaseItem(Const(_opCommitIn, width: 3), [
                        opState < Const(_uCommitWait, width: 4),
                      ]),
                      CaseItem(Const(_opCfg, width: 3), [
                        opState < Const(_uCfgSt, width: 4),
                      ]),
                      CaseItem(Const(_opSetAddr, width: 3), [
                        opState < Const(_uSetAddrSt, width: 4),
                      ]),
                      CaseItem(Const(_opCfgRead, width: 3), [
                        opState < Const(_uCfgReadSt, width: 4),
                      ]),
                      CaseItem(Const(_opFlushIn, width: 3), [
                        opState < Const(_uFlushSt, width: 4),
                      ]),
                    ]),
                  ],
                ),
              ]),
              CaseItem(Const(_uPopAssert, width: 4), [
                opState < Const(_uPopCapture, width: 4),
              ]),
              CaseItem(Const(_uPopCapture, width: 4), [
                opDoneToggleUsb < ~opDoneToggleUsb,
                opState < Const(_uIdle, width: 4),
              ]),
              CaseItem(Const(_uReleaseSt, width: 4), [
                opDoneToggleUsb < ~opDoneToggleUsb,
                opState < Const(_uIdle, width: 4),
              ]),
              CaseItem(Const(_uCommitWait, width: 4), [
                If(
                  commitFire,
                  then: [
                    opDoneToggleUsb < ~opDoneToggleUsb,
                    opState < Const(_uIdle, width: 4),
                  ],
                ),
              ]),
              CaseItem(Const(_uCfgSt, width: 4), [
                for (var i = 0; i < numEndpoints; i++)
                  If(
                    opEpUsb.eq(Const(i, width: epIdxWidth)),
                    then: [
                      If(cfgSetOut, then: [stallOutUsb[i] < Const(1)]),
                      If(cfgClrOut, then: [stallOutUsb[i] < Const(0)]),
                      If(cfgSetIn, then: [stallInUsb[i] < Const(1)]),
                      If(cfgClrIn, then: [stallInUsb[i] < Const(0)]),
                      epControlUsb[i] < cfgControl,
                    ],
                  ),
                opDoneToggleUsb < ~opDoneToggleUsb,
                opState < Const(_uIdle, width: 4),
              ]),
              CaseItem(Const(_uSetAddrSt, width: 4), [
                devAddrUsb < addrReg,
                opDoneToggleUsb < ~opDoneToggleUsb,
                opState < Const(_uIdle, width: 4),
              ]),
              CaseItem(Const(_uCfgReadSt, width: 4), [
                opDoneToggleUsb < ~opDoneToggleUsb,
                opState < Const(_uIdle, width: 4),
              ]),
              CaseItem(Const(_uFlushSt, width: 4), [
                If(
                  inFlushFire,
                  then: [
                    opDoneToggleUsb < ~opDoneToggleUsb,
                    opState < Const(_uIdle, width: 4),
                  ],
                ),
              ]),
            ],
            defaultItem: [opState < Const(_uIdle, width: 4)],
          ),
          // A SETUP held on the same cycle as an EP_CFG write wins, since
          // the driver cannot have seen it yet.
          for (var i = 0; i < numEndpoints; i++)
            If(
              setupClearUsb[i],
              then: [stallOutUsb[i] < Const(0), stallInUsb[i] < Const(0)],
            ),
          If(
            busResetUsb,
            then: [
              devAddrUsb < Const(0, width: 7),
              ...ackedSticky.map((a) => a < Const(0)),
              ...stallOutUsb.map((s) => s < Const(0)),
              ...stallInUsb.map((s) => s < Const(0)),
            ],
          ),
        ],
      ),
    ]);

    // ==================================================================
    // Continuous IN byte-push drain: pops the shared FIFO's head into
    // whichever endpoint it targets, as soon as that endpoint is ready.
    // During a bus reset it pops and discards, so the FIFO stays aligned.
    // ==================================================================
    final inFifoEmpty = inPushFifo.output('rd_empty');
    final inFifoHead = inPushFifo.output('rd_data');
    final inHeadByte = inFifoHead.getRange(0, 8).named('in_head_byte');
    final inHeadEp = inFifoHead.getRange(8, 8 + epIdxWidth).named('in_head_ep');
    final selInFree = selectByEp(
      pe.output('in_ep_data_free'),
      inHeadEp,
    ).named('sel_in_free');
    final inFlushDrop = (inFlushWait & inHeadEp.eq(opEpUsb)).named(
      'in_flush_drop',
    );
    final doPop = (~inFifoEmpty & (selInFree | busResetUsb | inFlushDrop))
        .named('in_push_do_pop');
    inPushFifo.input('rd_en').srcConnection! <= doPop;

    // Every pop counts, also one a bus reset or a flush drops, so the count
    // matches what the bus side pushed.
    Sequential(usbClk, [
      If(
        usbReset,
        then: [...inPoppedUsb.map((c) => c < Const(0, width: 8))],
        orElse: [
          for (var i = 0; i < numEndpoints; i++) ...[
            If(
              doPop & inHeadEp.eq(Const(i, width: epIdxWidth)),
              then: [inPoppedUsb[i] < inPoppedUsb[i] + Const(1, width: 8)],
            ),
            If(
              (commitFire | inFlushFire) &
                  opEpUsb.eq(Const(i, width: epIdxWidth)),
              then: [inPoppedUsb[i] < Const(0, width: 8)],
            ),
          ],
        ],
      ),
    ]);

    final inReqBits = List.generate(
      numEndpoints,
      (i) =>
          (doPop &
                  ~busResetUsb &
                  ~inFlushDrop &
                  inHeadEp.eq(Const(i, width: epIdxWidth)))
              .named('in_req_bit_$i'),
    );
    pe.input('in_ep_req').srcConnection! <= inReqBits.rswizzle();
    pe.input('in_ep_data_put').srcConnection! <= inReqBits.rswizzle();
    final inEpDataLanes = List.generate(
      numEndpoints,
      (i) => mux(
        inHeadEp.eq(Const(i, width: epIdxWidth)),
        inHeadByte,
        Const(0, width: 8),
      ),
    );
    pe.input('in_ep_data').srcConnection! <= inEpDataLanes.rswizzle();

    // ==================================================================
    // Bus-domain register decode.
    // ==================================================================
    // Local reset detach (bus side). detachHold rises with the local reset
    // and keeps the pullup off. It asks the USB side to count the detach
    // time, and falls once the USB side reports the count is done.
    final detachHold = Logic(name: 'detach_hold_q');
    final detachSeen = Logic(name: 'detach_seen_q');
    final detachReqBus = (detachHold & ~detachSeen).named('detach_req_bus');
    final detachReqUsb = _levelCrossing(
      detachReqBus,
      usbClk,
      usbReset,
      'detach_req',
    );
    final detachCnt = Logic(name: 'detach_cnt_usb_q', width: 32);
    Sequential(usbClk, [
      If(
        usbReset,
        then: [detachCnt < Const(0, width: 32)],
        orElse: [
          If(
            detachReqUsb,
            then: [detachCnt < Const(localResetDetachCycles, width: 32)],
            orElse: [
              If(
                detachCnt.neq(Const(0, width: 32)),
                then: [detachCnt < detachCnt - Const(1, width: 32)],
              ),
            ],
          ),
        ],
      ),
    ]);
    final detachActiveUsb = (detachReqUsb | detachCnt.neq(Const(0, width: 32)))
        .named('detach_active_usb');
    final detachActiveBus = _levelCrossing(
      detachActiveUsb,
      clk,
      reset,
      'detach_active',
    );

    output('usb_pullup') <= ctrlEnable & ctrlConnect & ~reset & ~detachHold;

    // Decode uses only the address bits inside the 0x400 window. An offset
    // in the window past the last register reads 0 and ignores writes.
    final windowAddr = bus.addr.getRange(0, _windowBits).named('window_addr');
    Const regAddr(int offset) => Const(offset, width: _windowBits);
    final freshAccess = (bus.stb & ~bus.ack & ~opBusy).named('fresh_access');

    final inDonePrev = List.generate(
      numEndpoints,
      (i) => Logic(name: 'in_done_prev_${i}_q'),
    );
    final busResetPrev = Logic(name: 'bus_reset_prev_q');
    final busResetRise = (busResetBus & ~busResetPrev).named('bus_reset_rise');

    // INT_STATUS: events OR in, a same-cycle write-1-to-clear ANDs out.
    // A bus reset start clears every other bit.
    final eventSetMask = List<Logic>.generate(32, (bit) {
      if (bit == 0) return busResetRise;
      if (bit == 1) return sofPulseBus;
      if (bit >= 8 && bit < 8 + numEndpoints) return pktPulseBus[bit - 8];
      if (bit >= 16 && bit < 16 + numEndpoints) {
        return ackedBus[bit - 16] & ~inDonePrev[bit - 16];
      }
      return Const(0);
    }).rswizzle().named('int_event_set_mask');
    final isIntStatusWrite =
        (freshAccess & bus.we & windowAddr.eq(regAddr(_intStatusAddr))).named(
          'is_int_status_write',
        );
    // A flush clears the IN-done of its endpoint as it acks, after any
    // event that crossed on the same cycle.
    final flushDoneBus = (opComplete & opRegBus.eq(Const(_opFlushIn, width: 3)))
        .named('in_flush_done_bus');
    final flushClearMask = List<Logic>.generate(32, (bit) {
      if (bit >= 16 && bit < 16 + numEndpoints) {
        return flushDoneBus & opEpBus.eq(Const(bit - 16, width: epIdxWidth));
      }
      return Const(0);
    }).rswizzle().named('in_flush_clear_mask');
    final intStatusNext = Logic(name: 'int_status_next', width: 32);
    Combinational([
      intStatusNext < ((intStatus | eventSetMask) & ~flushClearMask),
      If(
        isIntStatusWrite,
        then: [
          intStatusNext <
              ((intStatus | eventSetMask) &
                  ~bus.selMasked(_intStatusAddr, 32) &
                  ~flushClearMask),
        ],
      ),
      If(busResetRise, then: [intStatusNext < Const(1, width: 32)]),
    ]);

    Logic cfgEnType = Const(0, width: 3);
    for (var i = 0; i < numEndpoints; i++) {
      cfgEnType = mux(
        opEpBus.eq(Const(i, width: epIdxWidth)),
        [epTypeBus[i], epEnableBus[i]].swizzle(),
        cfgEnType,
      );
    }
    final cfgReadValue =
        (cfgEnType.zeroExtend(dw) |
                (outRetFifo.output('rd_data').getRange(0, 2).zeroExtend(dw) <<
                    Const(3, width: dw)))
            .named('cfg_read_value');

    final ctrlNext = bus
        .selMerge([ctrlConnect, ctrlEnable].swizzle(), _ctrlAddr)
        .named('ctrl_next');
    // EP_CFG bits [2:0] keep their value in a byte SEL does not select.
    // Bits [8:3] act on 1, so an unselected byte reads as 0 and does nothing.
    final cfgKeep = [
      for (var i = 0; i < numEndpoints; i++)
        bus
            .selMerge(
              [epTypeBus[i], epEnableBus[i]].swizzle(),
              _epBase + i * _epStride + _cfgOff,
            )
            .named('ep_cfg_keep_$i'),
    ];
    final cfgAct = [
      for (var i = 0; i < numEndpoints; i++)
        bus
            .selMasked(_epBase + i * _epStride + _cfgOff, 9)
            .named('ep_cfg_act_$i'),
    ];

    // The bus side of a local reset: the joined reset without our own.
    final peer = (reset & ~busOwnReset).named('local_reset_bus');
    final peerPrev = Logic(name: 'local_reset_prev_q');
    final peerRelease = (peerPrev & ~peer).named('local_reset_release');

    Sequential(clk, [
      If(
        busOwnReset,
        then: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: dw),
          ctrlEnable < Const(0),
          ctrlConnect < Const(0),
          addrReg < Const(0, width: 7),
          intStatus < Const(0, width: 32),
          intEnable < Const(0, width: 32),
          frameBus < Const(0, width: 11),
          opBusy < Const(0),
          opRegBus < Const(0, width: 3),
          opEpBus < Const(0, width: epIdxWidth),
          opPayloadBus < Const(0, width: 7),
          opReqToggleBus < Const(0),
          inPushWrEn < Const(0),
          inPushWrData < Const(0, width: 8 + epIdxWidth),
          ...inPushedBus.map((c) => c < Const(0, width: 8)),
          opCountBus < Const(0, width: 8),
          busResetPrev < Const(0),
          ...epEnableBus.map((e) => e < Const(0)),
          // Only EP0 resets to type control. The others reset to bulk.
          for (var i = 0; i < numEndpoints; i++)
            epTypeBus[i] <
                Const(
                  i == 0
                      ? HarborUsbEndpointType.control.index
                      : HarborUsbEndpointType.bulk.index,
                  width: 2,
                ),
          ...outReadyBus.map((r) => r < Const(0)),
          ...outSetupBus.map((s) => s < Const(0)),
          ...outTagBus.map((t) => t < Const(0, width: 4)),
          ...outLengthBus.map((l) => l < Const(0, width: lenWidth)),
          ...outHeldPrevBus.map((h) => h < Const(0)),
          ...inDonePrev.map((p) => p < Const(0)),
          peerPrev < Const(0),
          opDoneHeld < Const(0),
          detachHold < Const(0),
          detachSeen < Const(0),
        ],
        orElse: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: dw),
          inPushWrEn < Const(0),
          intStatus < intStatusNext,
          busResetPrev < busResetBus,
          If(sofPulseBus, then: [frameBus < frameUsb]),
          for (var i = 0; i < numEndpoints; i++) inDonePrev[i] < ackedBus[i],

          If(opBusy & opDonePulseBus, then: [opDoneHeld < Const(1)]),
          If(
            opBusy,
            then: [
              If(
                opComplete,
                then: [
                  opBusy < Const(0),
                  opDoneHeld < Const(0),
                  bus.ack < Const(1),
                  If(
                    opRegBus.eq(Const(_opPopOut, width: 3)),
                    then: [
                      bus.dataOut < outRetFifo.output('rd_data').zeroExtend(dw),
                    ],
                  ),
                  If(
                    opRegBus.eq(Const(_opCfgRead, width: 3)),
                    then: [bus.dataOut < cfgReadValue],
                  ),
                  If(
                    opRegBus.eq(Const(_opRelease, width: 3)),
                    then: [
                      for (var i = 0; i < numEndpoints; i++)
                        If(
                          opEpBus.eq(Const(i, width: epIdxWidth)),
                          then: [outReadyBus[i] < Const(0)],
                        ),
                    ],
                  ),
                ],
              ),
            ],
            orElse: [
              If(
                bus.stb & ~bus.ack,
                then: [
                  Case(
                    windowAddr,
                    [
                      CaseItem(regAddr(_ctrlAddr), [
                        If(
                          bus.we,
                          then: [
                            ctrlEnable < ctrlNext[0],
                            ctrlConnect < ctrlNext[1],
                          ],
                        ),
                        bus.ack < Const(1),
                        bus.dataOut <
                            (ctrlEnable.zeroExtend(dw) |
                                (ctrlConnect.zeroExtend(dw) <<
                                    Const(1, width: dw))),
                      ]),
                      CaseItem(regAddr(_statusAddr), [
                        bus.ack < Const(1),
                        bus.dataOut < busResetBus.zeroExtend(dw),
                      ]),
                      CaseItem(regAddr(_addrAddr), [
                        If(
                          bus.we & ~busResetBus & bus.selAny(_addrAddr, 1),
                          then: [
                            addrReg < bus.selMerge(addrReg, _addrAddr),
                            opBusy < Const(1),
                            opRegBus < Const(_opSetAddr, width: 3),
                            opReqToggleBus < ~opReqToggleBus,
                          ],
                          orElse: [bus.ack < Const(1)],
                        ),
                        bus.dataOut < addrReg.zeroExtend(dw),
                      ]),
                      CaseItem(regAddr(_intStatusAddr), [
                        bus.ack < Const(1),
                        bus.dataOut < intStatus.zeroExtend(dw),
                      ]),
                      CaseItem(regAddr(_intEnableAddr), [
                        If(
                          bus.we,
                          then: [
                            intEnable < bus.selMerge(intEnable, _intEnableAddr),
                          ],
                        ),
                        bus.ack < Const(1),
                        bus.dataOut < intEnable.zeroExtend(dw),
                      ]),
                      CaseItem(regAddr(_frameAddr), [
                        bus.ack < Const(1),
                        bus.dataOut < frameBus.zeroExtend(dw),
                      ]),
                      for (var i = 0; i < numEndpoints; i++) ...[
                        CaseItem(regAddr(_epBase + i * _epStride + _cfgOff), [
                          If(
                            bus.we,
                            then: [
                              epEnableBus[i] < cfgKeep[i][0],
                              epTypeBus[i] < cfgKeep[i].getRange(1, 3),
                              opBusy < Const(1),
                              opRegBus < Const(_opCfg, width: 3),
                              opEpBus < Const(i, width: epIdxWidth),
                              opPayloadBus <
                                  [
                                    cfgAct[i][8],
                                    cfgAct[i][7],
                                    cfgKeep[i]
                                        .getRange(1, 3)
                                        .eq(Const(0, width: 2)),
                                    cfgAct[i][4],
                                    cfgAct[i][3],
                                    cfgAct[i][6],
                                    cfgAct[i][5],
                                  ].swizzle(),
                              opReqToggleBus < ~opReqToggleBus,
                            ],
                            orElse: [
                              opBusy < Const(1),
                              opRegBus < Const(_opCfgRead, width: 3),
                              opEpBus < Const(i, width: epIdxWidth),
                              opReqToggleBus < ~opReqToggleBus,
                            ],
                          ),
                        ]),
                        CaseItem(
                          regAddr(_epBase + i * _epStride + _outStatOff),
                          [
                            bus.ack < Const(1),
                            bus.dataOut <
                                (outReadyBus[i].zeroExtend(dw) |
                                    (outSetupBus[i].zeroExtend(dw) <<
                                        Const(1, width: dw)) |
                                    (outTagBus[i].zeroExtend(dw) <<
                                        Const(4, width: dw)) |
                                    (outLengthBus[i].zeroExtend(dw) <<
                                        Const(8, width: dw))),
                          ],
                        ),
                        CaseItem(
                          regAddr(_epBase + i * _epStride + _outDataOff),
                          [
                            If(
                              ~bus.we,
                              then: [
                                opBusy < Const(1),
                                opRegBus < Const(_opPopOut, width: 3),
                                opEpBus < Const(i, width: epIdxWidth),
                                opReqToggleBus < ~opReqToggleBus,
                              ],
                              orElse: [bus.ack < Const(1)],
                            ),
                          ],
                        ),
                        CaseItem(
                          regAddr(_epBase + i * _epStride + _outAckOff),
                          [
                            If(
                              bus.we &
                                  bus.selAny(
                                    _epBase + i * _epStride + _outAckOff,
                                    1,
                                  ) &
                                  outReadyBus[i] &
                                  bus.dataIn.getRange(4, 8).eq(outTagBus[i]),
                              then: [
                                opBusy < Const(1),
                                opRegBus < Const(_opRelease, width: 3),
                                opEpBus < Const(i, width: epIdxWidth),
                                opPayloadBus <
                                    bus.dataIn.getRange(4, 8).zeroExtend(7),
                                opReqToggleBus < ~opReqToggleBus,
                              ],
                              orElse: [bus.ack < Const(1)],
                            ),
                          ],
                        ),
                        CaseItem(
                          regAddr(_epBase + i * _epStride + _inDataOff),
                          [
                            If(
                              bus.we &
                                  bus.selAny(
                                    _epBase + i * _epStride + _inDataOff,
                                    1,
                                  ),
                              then: [
                                If(
                                  ~inPushFifo.output('wr_full'),
                                  then: [
                                    inPushWrEn < Const(1),
                                    inPushWrData <
                                        [
                                          Const(i, width: epIdxWidth),
                                          bus.dataIn.getRange(0, 8),
                                        ].swizzle(),
                                    inPushedBus[i] <
                                        inPushedBus[i] + Const(1, width: 8),
                                    bus.ack < Const(1),
                                  ],
                                ),
                              ],
                              orElse: [bus.ack < Const(1)],
                            ),
                          ],
                        ),
                        CaseItem(
                          regAddr(_epBase + i * _epStride + _inCommitOff),
                          [
                            If(
                              bus.we &
                                  bus.selAny(
                                    _epBase + i * _epStride + _inCommitOff,
                                    4,
                                  ),
                              then: [
                                opBusy < Const(1),
                                opRegBus < Const(_opCommitIn, width: 3),
                                opEpBus < Const(i, width: epIdxWidth),
                                opCountBus < inPushedBus[i],
                                inPushedBus[i] < Const(0, width: 8),
                                opReqToggleBus < ~opReqToggleBus,
                              ],
                              orElse: [bus.ack < Const(1)],
                            ),
                          ],
                        ),
                        CaseItem(
                          regAddr(_epBase + i * _epStride + _inFlushOff),
                          [
                            If(
                              bus.we &
                                  bus.selAny(
                                    _epBase + i * _epStride + _inFlushOff,
                                    4,
                                  ),
                              then: [
                                opBusy < Const(1),
                                opRegBus < Const(_opFlushIn, width: 3),
                                opEpBus < Const(i, width: epIdxWidth),
                                opCountBus < inPushedBus[i],
                                inPushedBus[i] < Const(0, width: 8),
                                opReqToggleBus < ~opReqToggleBus,
                              ],
                              orElse: [bus.ack < Const(1)],
                            ),
                          ],
                        ),
                        CaseItem(
                          regAddr(_epBase + i * _epStride + _inStatOff),
                          [
                            bus.ack < Const(1),
                            bus.dataOut <
                                (inFreeBus[i].zeroExtend(dw) |
                                    (ackedBus[i].zeroExtend(dw) <<
                                        Const(1, width: dw))),
                          ],
                        ),
                      ],
                    ],
                    defaultItem: [bus.ack < Const(1)],
                  ),
                ],
              ),
            ],
          ),

          // OUT_STAT: a new packet sets every field at once. Ready clears
          // when the engine drops the packet (SETUP preempt or bus reset).
          for (var i = 0; i < numEndpoints; i++) ...[
            outHeldPrevBus[i] < heldBus[i],
            If(
              outHeldPrevBus[i] & ~heldBus[i],
              then: [outReadyBus[i] < Const(0)],
            ),
            If(
              pktPulseBus[i],
              then: [
                outReadyBus[i] < Const(1),
                outSetupBus[i] < setupCapUsb[i],
                outTagBus[i] < tagUsb[i],
                outLengthBus[i] < lengthCapUsb[i],
              ],
            ),
          ],
          If(busResetBus, then: [addrReg < Const(0, width: 7)]),

          // Local reset: the USB side and every crossing are in reset.
          // Nothing crosses, and any access waiting on the USB side
          // acks now with data 0.
          peerPrev < peer,
          If(
            peer,
            then: [
              opBusy < Const(0),
              opDoneHeld < Const(0),
              opReqToggleBus < Const(0),
              inPushWrEn < Const(0),
              ...inPushedBus.map((c) => c < Const(0, width: 8)),
              addrReg < Const(0, width: 7),
              busResetPrev < Const(0),
              ...outReadyBus.map((r) => r < Const(0)),
              ...outSetupBus.map((s) => s < Const(0)),
              ...outTagBus.map((t) => t < Const(0, width: 4)),
              ...outLengthBus.map((l) => l < Const(0, width: lenWidth)),
              ...outHeldPrevBus.map((h) => h < Const(0)),
              ...inDonePrev.map((p) => p < Const(0)),
              If(bus.stb & ~bus.ack, then: [bus.ack < Const(1)]),
              detachHold < Const(1),
              detachSeen < Const(0),
            ],
          ),
          If(peerRelease, then: [intStatus < Const(0x5, width: 32)]),
          If(
            detachHold & ~peer,
            then: [
              If(detachActiveBus, then: [detachSeen < Const(1)]),
              If(
                detachSeen & ~detachActiveBus,
                then: [detachHold < Const(0), detachSeen < Const(0)],
              ),
            ],
          ),
        ],
      ),
    ]);

    interrupt <= (intStatus & intEnable).or();
  }

  /// Synchronizes a one-shot [toggleSignal] into [dstClk]'s domain and
  /// returns a one-cycle pulse on each edge it observes.
  Logic _toggleEdgeDetect(
    Logic toggleSignal,
    Logic dstClk,
    Logic dstReset,
    String name,
  ) {
    final sync = HarborCdcSync(name: '${name}_sync');
    addSubModule(sync);
    sync.input('async_in').srcConnection! <= toggleSignal;
    sync.input('dst_clk').srcConnection! <= dstClk;
    sync.input('dst_reset').srcConnection! <= dstReset;
    final prev = Logic(name: '${name}_prev_q');
    Sequential(dstClk, [
      If(
        dstReset,
        then: [prev < Const(0)],
        orElse: [prev < sync.output('sync_out')],
      ),
    ]);
    return (sync.output('sync_out') ^ prev).named('${name}_pulse');
  }

  /// Crosses a one-cycle pulse from [srcClk] to [dstClk] as a toggle plus
  /// edge detect, so it can never be lost the way a raw pulse would be.
  Logic _pulseCrossing({
    required Logic srcClk,
    required Logic srcReset,
    required Logic srcPulse,
    required Logic dstClk,
    required Logic dstReset,
    required String name,
  }) {
    final toggle = Logic(name: '${name}_toggle_q');
    Sequential(srcClk, [
      If(
        srcReset,
        then: [toggle < Const(0)],
        orElse: [
          If(srcPulse, then: [toggle < ~toggle]),
        ],
      ),
    ]);
    return _toggleEdgeDetect(toggle, dstClk, dstReset, name);
  }

  /// Synchronizes a held [level] into [dstClk]'s domain with a 2-flop
  /// synchronizer.
  Logic _levelCrossing(Logic level, Logic dstClk, Logic dstReset, String name) {
    final sync = HarborCdcSync(name: name);
    addSubModule(sync);
    sync.input('async_in').srcConnection! <= level;
    sync.input('dst_clk').srcConnection! <= dstClk;
    sync.input('dst_reset').srcConnection! <= dstReset;
    return sync.output('sync_out');
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,usb'],
    reg: BusAddressRange(baseAddress, 0x400),
    properties: {'harbor,num-endpoints': numEndpoints},
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x400)],
    properties: {
      'compatible': ['harbor,usb'],
      'harbor,num-endpoints': numEndpoints,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'USB',
    groupName: 'USB',
    description: 'USB full-speed device controller',
    baseAddress: baseAddress,
    size: 0x400,
  );
}
