import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../util/pretty_string.dart';

/// USB speed mode.
enum HarborUsbSpeed {
  /// Low speed (1.5 Mbps, USB 1.0).
  low,

  /// Full speed (12 Mbps, USB 1.1).
  full,

  /// High speed (480 Mbps, USB 2.0).
  high,

  /// SuperSpeed (5 Gbps, USB 3.0 / USB 3.2 Gen 1).
  super_,

  /// SuperSpeed+ (10 Gbps, USB 3.1 / USB 3.2 Gen 2).
  superPlus,

  /// SuperSpeed+ (20 Gbps, USB 3.2 Gen 2x2).
  superPlus2x2,
}

/// USB role.
enum HarborUsbRole {
  /// Device (peripheral) mode.
  device,

  /// Host mode.
  host,

  /// OTG (On-The-Go) - supports both.
  otg,
}

/// USB endpoint type.
enum HarborUsbEndpointType { control, isochronous, bulk, interrupt }

/// USB endpoint direction.
enum HarborUsbEndpointDirection {
  /// OUT: host to device.
  out_,

  /// IN: device to host.
  in_,
}

/// USB endpoint configuration.
class HarborUsbEndpoint {
  /// Endpoint number (0-15).
  final int number;

  /// Direction.
  final HarborUsbEndpointDirection direction;

  /// Transfer type.
  final HarborUsbEndpointType type;

  /// Maximum packet size in bytes.
  final int maxPacketSize;

  const HarborUsbEndpoint({
    required this.number,
    required this.direction,
    required this.type,
    this.maxPacketSize = 64,
  });
}

/// USB controller configuration.
class HarborUsbConfig with HarborPrettyString {
  /// Maximum speed supported.
  final HarborUsbSpeed maxSpeed;

  /// Controller role.
  final HarborUsbRole role;

  /// Number of endpoints (including EP0).
  final int endpointCount;

  /// FIFO buffer size per endpoint in bytes.
  final int fifoSize;

  const HarborUsbConfig({
    this.maxSpeed = HarborUsbSpeed.full,
    this.role = HarborUsbRole.device,
    this.endpointCount = 4,
    this.fifoSize = 64,
  });

  /// Whether this configuration includes USB 3.x SuperSpeed.
  bool get isSuperSpeed =>
      maxSpeed == HarborUsbSpeed.super_ ||
      maxSpeed == HarborUsbSpeed.superPlus ||
      maxSpeed == HarborUsbSpeed.superPlus2x2;

  /// Whether this configuration includes USB 2.0 High Speed.
  bool get isHighSpeed => isSuperSpeed || maxSpeed == HarborUsbSpeed.high;

  @override
  String toString() =>
      'HarborUsbConfig(${maxSpeed.name}, ${role.name}, '
      '$endpointCount EPs)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborUsbConfig(\n');
    buf.writeln('${c}speed: ${maxSpeed.name},');
    buf.writeln('${c}role: ${role.name},');
    buf.writeln('${c}endpoints: $endpointCount,');
    buf.writeln('${c}fifoSize: $fifoSize bytes,');
    buf.write('$p)');
    return buf.toString();
  }
}

/// USB controller peripheral.
///
/// Register map (each register in its own 64-bit-aligned slot, so a 32-bit
/// access lands in the low word on both a 32-bit and a 64-bit fabric, and the
/// byte-address decode needs no high/low-half selection):
/// - 0x000: CTRL       (enable, speed, role, reset)
/// - 0x008: STATUS     (connected, suspended, speed_actual, ep0_setup)
/// - 0x010: ADDR       (device address, set after SET_ADDRESS)
/// - 0x018: INT_STATUS (interrupt status, write-1-to-clear)
/// - 0x020: INT_ENABLE (interrupt enable mask)
/// - 0x028: FRAME      (current frame number, read-only)
///
/// EP0 registers (the second 512-byte page, i.e. address bit 9 set). The page
/// is 0x200, not 0x100: at 8-byte slots the EP0 block spans 0x108 bytes and no
/// longer fits below the old 0x100 boundary.
/// - 0x200: EP0_CTRL   (write: [7:4] PID nibble, [2] arm-for-IN,
///                      [1] has-data, [0] start now, read returns busy)
/// - 0x218: EP0_TXDATA (write pushes one payload byte into the TX FIFO)
/// - 0x228: EP0_TXLEN  (write sets payload length and resets the TX FIFO)
/// - 0x280: EP0_RXLEN  (read: number of received body bytes)
/// - 0x288: EP0_RXDATA (read pops one received byte)
/// - 0x290: EP0_STATUS (read: [3:0] last PID, [4] tx busy, [5] awaiting
///                      data, [6] IN armed)
/// - 0x300: HOST_TOKEN (host/OTG: write starts a transaction, [3:0] token
///                      PID, [10:4] address, [14:11] endpoint, [15] toggle)
/// - 0x308: HOST_STATUS (host/OTG: [0] busy, [1] done, [3:2] result
///                      (0 ACK, 1 NAK, 2 timeout, 3 stall), [7:4] resp PID)
///
/// The transmit side serializes SYNC, the PID, the payload/token bytes, the
/// CRC16 and an EOP onto usb_dp/usb_dm with NRZI encoding and bit stuffing. The
/// receive side deserializes the line, de-stuffs, checks CRC5 (tokens) and
/// CRC16 (data).
///
/// The role is fixed at build time. A DEVICE build answers the host: it stores
/// SETUP/OUT data and replies ACK, and on an IN token transmits an armed packet
/// or NAKs (INT_STATUS bit 0 = SETUP, 1 = OUT, 2 = IN acked). A HOST build
/// drives transactions itself: HOST_TOKEN sends a token (computing the CRC5),
/// then sends the OUT data or receives the IN data and ACKs it, reporting the
/// device's handshake in HOST_STATUS. An OTG build instantiates both and picks
/// the role at run time via CTRL bit 1, so a smaller FPGA can drop to a
/// device-only or host-only build. Speed negotiation (FS/HS chirp, SuperSpeed
/// LTSSM) is shared across roles. The link layer is sim-grade: one line symbol
/// per system clock, no oversampling/8b10b/LFPS PHY.
class HarborUsbController extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// USB configuration.
  final HarborUsbConfig config;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  HarborUsbController({
    required this.config,
    required this.baseAddress,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborUsbController', name: name ?? 'usb') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // USB 2.0 PHY pins (always present for backwards compatibility)
    createPort('usb_dp_in', PortDirection.input); // D+ input
    createPort('usb_dm_in', PortDirection.input); // D- input
    addOutput('usb_dp_out'); // D+ output
    addOutput('usb_dm_out'); // D- output
    addOutput('usb_oe'); // output enable
    addOutput('usb_pullup'); // 1.5k pullup for device mode

    // USB 3.x SuperSpeed PHY pins (only when SuperSpeed is configured)
    if (config.isSuperSpeed) {
      createPort('ss_rx_p', PortDirection.input); // SuperSpeed RX+
      createPort('ss_rx_n', PortDirection.input); // SuperSpeed RX-
      addOutput('ss_tx_p'); // SuperSpeed TX+
      addOutput('ss_tx_n'); // SuperSpeed TX-
      addOutput('ss_tx_oe'); // SuperSpeed TX output enable
    }

    addOutput('interrupt');

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: 12,
      dataWidth: 32,
    );

    final clk = input('clk');
    final reset = input('reset');

    // Global registers
    final ctrlEnable = Logic(name: 'ctrl_enable');
    final deviceAddr = Logic(name: 'device_addr', width: 7);
    final intStatus = Logic(name: 'int_status', width: 8);
    final intEnable = Logic(name: 'int_enable', width: 8);
    final connected = Logic(name: 'connected');
    final frameNum = Logic(name: 'frame_num', width: 11);

    // Full-speed device packet transmitter (EP0).
    //
    // The serializer emits one line symbol per system clock onto the
    // usb_dp/usb_dm differential pair. A real PHY would gate this with a
    // recovered bit clock. Here one sysclk cycle is one bit time, which is
    // enough for functional verification of the framing, NRZI, bit stuffing
    // and CRC16. Pointer/index width covers the configured FIFO depth.
    final fifoSize = config.fifoSize;
    final ptrW = fifoSize.bitLength;

    // Packet phases.
    const pSync = 0;
    const pPid = 1;
    const pPayload = 2;
    const pCrc = 3;
    const pEop = 4;

    final txBusy = Logic(name: 'usb_tx_busy');
    final phase = Logic(name: 'usb_tx_phase', width: 3);
    final byteIdx = Logic(name: 'usb_tx_byte_idx', width: ptrW);
    final bitInByte = Logic(name: 'usb_tx_bit', width: 3);
    final crc16 = Logic(name: 'usb_tx_crc16', width: 16);
    final onesCount = Logic(name: 'usb_tx_ones', width: 3);
    final lineJ = Logic(name: 'usb_tx_line_j');
    final eopCnt = Logic(name: 'usb_tx_eop_cnt', width: 2);
    final pidReg = Logic(name: 'usb_tx_pid', width: 4);
    final hasData = Logic(name: 'usb_tx_has_data');
    final txLen = Logic(name: 'usb_tx_len', width: ptrW);
    final txWrPtr = Logic(name: 'usb_tx_wr_ptr', width: ptrW);
    final dpReg = Logic(name: 'usb_dp_reg');
    final dmReg = Logic(name: 'usb_dm_reg');
    final oeReg = Logic(name: 'usb_oe_reg');
    // A token packet sends two raw bytes (address/endpoint + CRC5) with no
    // appended CRC16. Raw mode skips the CRC phase, token mode swaps the
    // payload source from the data FIFO to the computed token bytes.
    final txRaw = Logic(name: 'usb_tx_raw');
    final txTokenMode = Logic(name: 'usb_tx_token_mode');
    final hostAddr = Logic(name: 'usb_host_addr', width: 7);
    final hostEndp = Logic(name: 'usb_host_endp', width: 4);
    final fifo = List.generate(
      fifoSize,
      (i) => Logic(name: 'usb_tx_fifo_$i', width: 8),
    );

    // Combinational view of the byte currently being shifted out.
    final pidByte = [~pidReg, pidReg].swizzle().named('usb_pid_byte');
    final notCrc = (~crc16).named('usb_crc_out');
    final crcByte = mux(
      byteIdx.eq(Const(0, width: ptrW)),
      notCrc.getRange(0, 8),
      notCrc.getRange(8, 16),
    ).named('usb_crc_byte');

    // Token bytes: an 11-bit {endp, addr} field with a 5-bit CRC5 appended.
    final tokField = [hostEndp, hostAddr].swizzle().named('usb_tok_field');
    Logic tokCrcCalc = Const(0x1F, width: 5);
    for (var i = 0; i < 11; i++) {
      final x = tokCrcCalc[0] ^ tokField[i];
      final sh = tokCrcCalc >>> 1;
      tokCrcCalc = mux(x, sh ^ Const(0x14, width: 5), sh);
    }
    final tokCrc5 = (~tokCrcCalc).named('usb_tok_crc5');
    final tokByte1 = [tokCrc5, tokField.getRange(8, 11)].swizzle();
    final tokenByteMux = mux(
      byteIdx.eq(Const(0, width: ptrW)),
      tokField.getRange(0, 8),
      tokByte1,
    ).named('usb_token_byte');

    Logic fifoByte = Const(0, width: 8);
    for (var i = fifoSize - 1; i >= 0; i--) {
      fifoByte = mux(byteIdx.eq(Const(i, width: ptrW)), fifo[i], fifoByte);
    }
    final payloadByte = mux(
      txTokenMode,
      tokenByteMux,
      fifoByte,
    ).named('usb_payload_byte');
    final effLen = mux(
      txTokenMode,
      Const(2, width: ptrW),
      txLen,
    ).named('usb_eff_len');

    Logic currentByte = Const(0x80, width: 8); // SYNC default
    currentByte = mux(phase.eq(Const(pPid, width: 3)), pidByte, currentByte);
    currentByte = mux(
      phase.eq(Const(pPayload, width: 3)),
      payloadByte,
      currentByte,
    );
    currentByte = mux(
      phase.eq(Const(pCrc, width: 3)),
      crcByte,
      currentByte,
    ).named('usb_cur_byte');

    final dataBit = (currentByte >>> bitInByte)[0].named('usb_data_bit');
    final stuffNow = onesCount.eq(Const(6, width: 3)).named('usb_stuff_now');
    final outBit = mux(stuffNow, Const(0), dataBit).named('usb_out_bit');
    // NRZI: a 1 holds the line, a 0 toggles it.
    final nextLineJ = mux(outBit, lineJ, ~lineJ).named('usb_next_line_j');
    final nextByteIdx = (byteIdx + Const(1, width: ptrW)).named('usb_next_idx');

    // PID nibbles (low nibble of the PID byte).
    const pidOut = 0x1;
    const pidIn = 0x9;
    const pidSof = 0x5;
    const pidSetup = 0xD;
    const pidData0 = 0x3;
    const pidData1 = 0xB;
    const pidAck = 0x2;
    const pidNak = 0xA;

    // Kicks the transmit serializer with a given PID and has-data flag. Used by
    // the bus, the device transaction layer (handshakes, IN data) and the host
    // layer (tokens, OUT data, ACKs). `raw` skips the CRC16. `token` sends the
    // computed token bytes instead of the data FIFO.
    List<Conditional> kickTx(
      Logic pid,
      Logic hd, {
      bool raw = false,
      bool token = false,
    }) => [
      txBusy < Const(1),
      phase < Const(pSync, width: 3),
      pidReg < pid,
      hasData < hd,
      txRaw < Const(raw ? 1 : 0),
      txTokenMode < Const(token ? 1 : 0),
      crc16 < Const(0xFFFF, width: 16),
      byteIdx < Const(0, width: ptrW),
      bitInByte < Const(0, width: 3),
      onesCount < Const(0, width: 3),
      lineJ < Const(1),
      eopCnt < Const(0, width: 2),
    ];

    //
    // The deserializer samples one line symbol per system clock (matching the
    // transmitter), NRZI-decodes, de-stuffs and reassembles bytes LSB first.
    // SYNC is byte 0, the PID is byte 1, the remaining bytes are the body and
    // CRC. CRC16 (data) and CRC5 (tokens) are accumulated over the post-PID
    // bits and checked against their residual constants at the EOP. Real
    // silicon needs an oversampling clock-recovery PHY in front of this. Here
    // one cycle is one bit time, enough to verify the protocol.
    final dpIn = input('usb_dp_in');
    final dmIn = input('usb_dm_in');
    final rxJ = (dpIn & ~dmIn).named('usb_rx_j');
    final rxSE0 = (~dpIn & ~dmIn).named('usb_rx_se0');

    final rxActive = Logic(name: 'usb_rx_active');
    final rxPrev = Logic(name: 'usb_rx_prev'); // last line state, 1=J 0=K
    final rxOnes = Logic(name: 'usb_rx_ones', width: 3);
    final rxBitCnt = Logic(name: 'usb_rx_bit', width: 3);
    final rxShift = Logic(name: 'usb_rx_shift', width: 8);
    final rxByteIdx = Logic(name: 'usb_rx_byte_idx', width: 8);
    final rxCrc16r = Logic(name: 'usb_rx_crc16', width: 16);
    final rxCrc5r = Logic(name: 'usb_rx_crc5', width: 5);
    final rxPid = Logic(name: 'usb_rx_pid', width: 4);
    final rxWrPtr = Logic(name: 'usb_rx_wr_ptr', width: ptrW);
    final rxRdPtr = Logic(name: 'usb_rx_rd_ptr', width: ptrW);
    final rxLen = Logic(name: 'usb_rx_len', width: ptrW);
    final awaitData = Logic(name: 'usb_await_data');
    final awaitSetup = Logic(name: 'usb_await_setup');
    final txReady = Logic(name: 'usb_tx_ready');
    final txQPid = Logic(name: 'usb_tx_q_pid', width: 4);
    final rxBuf = List.generate(
      fifoSize,
      (i) => Logic(name: 'usb_rx_buf_$i', width: 8),
    );

    // NRZI: same symbol as the last is a 1, a transition is a 0.
    final rxCur = rxJ.named('usb_rx_cur'); // 1=J, 0=K (valid when not SE0)
    final rxBit = rxCur.eq(rxPrev).named('usb_rx_bit_val');
    final rxCByte = [
      rxBit,
      rxShift.getRange(1, 8),
    ].swizzle().named('usb_rx_cbyte');

    Logic rxReadByte = Const(0, width: 8);
    for (var i = fifoSize - 1; i >= 0; i--) {
      rxReadByte = mux(rxRdPtr.eq(Const(i, width: ptrW)), rxBuf[i], rxReadByte);
    }
    rxReadByte = rxReadByte.named('usb_rx_read_byte');

    // Packet classification, valid at the EOP cycle.
    final isData =
        (rxPid.eq(Const(pidData0, width: 4)) |
                rxPid.eq(Const(pidData1, width: 4)))
            .named('usb_rx_is_data');
    final isInTok = rxPid.eq(Const(pidIn, width: 4)).named('usb_rx_is_in');
    final isOutTok = rxPid.eq(Const(pidOut, width: 4)).named('usb_rx_is_out');
    final isSetupTok = rxPid
        .eq(Const(pidSetup, width: 4))
        .named('usb_rx_is_setup');
    final isToken =
        (isInTok | isOutTok | isSetupTok | rxPid.eq(Const(pidSof, width: 4)))
            .named('usb_rx_is_token');
    final isAck = rxPid.eq(Const(pidAck, width: 4)).named('usb_rx_is_ack');
    final crc16ok = rxCrc16r
        .eq(Const(0xB001, width: 16))
        .named('usb_rx_crc16_ok');
    final crc5ok = rxCrc5r.eq(Const(0x06, width: 5)).named('usb_rx_crc5_ok');
    final addrMatch = rxBuf[0]
        .getRange(0, 7)
        .eq(deviceAddr)
        .named('usb_rx_addr_match');

    // Consumes one de-stuffed receive bit: shifts it in, accumulates the CRCs
    // for body bytes and completes bytes into the PID register or the buffer.
    List<Conditional> rxProcessBit() => [
      rxPrev < rxCur,
      If(
        rxOnes.eq(Const(6, width: 3)),
        then: [rxOnes < Const(0, width: 3)], // stuffed bit, drop it
        orElse: [
          rxOnes < mux(rxBit, rxOnes + Const(1, width: 3), Const(0, width: 3)),
          rxShift < rxCByte,
          If(
            rxByteIdx.gte(Const(2, width: 8)),
            then: [
              rxCrc16r <
                  mux(
                    rxCrc16r[0] ^ rxBit,
                    (rxCrc16r >>> 1) ^ Const(0xA001, width: 16),
                    rxCrc16r >>> 1,
                  ),
              rxCrc5r <
                  mux(
                    rxCrc5r[0] ^ rxBit,
                    (rxCrc5r >>> 1) ^ Const(0x14, width: 5),
                    rxCrc5r >>> 1,
                  ),
            ],
          ),
          If(
            rxBitCnt.eq(Const(7, width: 3)),
            then: [
              rxBitCnt < Const(0, width: 3),
              Case(
                rxByteIdx,
                [
                  // byte 0 is SYNC, byte 1 is the PID
                  CaseItem(Const(0, width: 8), [
                    rxByteIdx < Const(1, width: 8),
                  ]),
                  CaseItem(Const(1, width: 8), [
                    rxPid < rxCByte.getRange(0, 4),
                    rxByteIdx < Const(2, width: 8),
                  ]),
                ],
                defaultItem: [
                  for (var i = 0; i < fifoSize; i++)
                    If(
                      rxWrPtr.eq(Const(i, width: ptrW)),
                      then: [rxBuf[i] < rxCByte],
                    ),
                  rxWrPtr < (rxWrPtr + Const(1, width: ptrW)),
                  rxByteIdx < (rxByteIdx + Const(1, width: 8)),
                ],
              ),
            ],
            orElse: [rxBitCnt < (rxBitCnt + Const(1, width: 3))],
          ),
        ],
      ),
    ];

    //
    // After a bus reset (sustained SE0), a high-speed-capable device chirps K,
    // then watches for the host's alternating K-J chirp. Seeing enough K-J
    // pairs switches the device to high speed (the pullup is removed and the
    // reported speed becomes high). Configs that top out at full speed never
    // leave full speed. These registers simply stay idle for them.
    const chIdle = 0;
    const chDevChirp = 1;
    const chWaitHost = 2;
    const resetThresh = 8; // SE0 cycles that count as a bus reset
    const chirpLen = 8; // device-chirp duration
    const chirpEdgesNeeded = 6; // host K-J transitions before going HS

    final hsMode = Logic(name: 'usb_hs_mode');
    final chState = Logic(name: 'usb_ch_state', width: 2);
    final se0Cnt = Logic(name: 'usb_se0_cnt', width: 5);
    final chirpCnt = Logic(name: 'usb_chirp_cnt', width: 5);
    final chirpEdges = Logic(name: 'usb_chirp_edges', width: 4);
    final chirpPrev = Logic(name: 'usb_chirp_prev');
    final chirping = chState
        .eq(Const(chDevChirp, width: 2))
        .named('usb_chirping');
    final chReady = chState.eq(Const(chIdle, width: 2)).named('usb_ch_idle');

    //
    // A SuperSpeed-capable device detects its link partner on the SSRX pair,
    // runs a short polling handshake, then reaches U0 (the active link state).
    // Modelled with the same dwell-per-state approach as the PCIe LTSSM. The
    // SSTX pair carries a toggling training pattern while the link is active.
    const ssRxDetect = 0;
    const ssPolling = 1;
    const ssU0 = 2;
    const ssTrainDwell = 4;

    final ssLtssm = Logic(name: 'usb_ss_ltssm', width: 3);
    final ssDwell = Logic(name: 'usb_ss_dwell', width: 4);
    final ssLinkUp = Logic(name: 'usb_ss_link_up');
    final ssTog = Logic(name: 'usb_ss_tog');

    //
    // The role is fixed at build time: a device-only or host-only build omits
    // the other half's transaction logic so it fits a smaller FPGA, while an
    // OTG build instantiates both and picks the active role at run time via the
    // CTRL register. `hostMode` is constant for the fixed roles.
    final roleHasDevice = config.role != HarborUsbRole.host;
    final roleHasHost = config.role != HarborUsbRole.device;
    final hostModeReg = Logic(name: 'usb_host_mode_reg');
    final Logic hostMode = switch (config.role) {
      HarborUsbRole.host => Const(1),
      HarborUsbRole.device => Const(0),
      HarborUsbRole.otg => hostModeReg,
    };

    // Host transaction FSM (only used by host/OTG builds).
    const hIdle = 0;
    const hSendTok = 1;
    const hSendData = 2;
    const hRxResp = 3;
    const hRxData = 4;
    const hSendAck = 5;
    const hostTimeoutMax = 400;

    final hostState = Logic(name: 'usb_host_state', width: 3);
    final hostBusy = Logic(name: 'usb_host_busy');
    final hostDone = Logic(name: 'usb_host_done');
    final hostResult = Logic(name: 'usb_host_result', width: 2);
    final hostRespPid = Logic(name: 'usb_host_resp_pid', width: 4);
    final hostTxSeen = Logic(name: 'usb_host_tx_seen');
    final hostTimeout = Logic(name: 'usb_host_timeout', width: 9);
    final hostTokPid = Logic(name: 'usb_host_tok_pid', width: 4);
    final hostToggle = Logic(name: 'usb_host_toggle');

    // Pullup for device mode detection (removed once high speed is entered).
    output('usb_pullup') <= ctrlEnable & ~hsMode;
    output('usb_dp_out') <= dpReg;
    output('usb_dm_out') <= dmReg;
    output('usb_oe') <= oeReg;

    if (config.isSuperSpeed) {
      final ssActive = (ssLtssm.eq(Const(ssPolling, width: 3)) | ssLinkUp)
          .named('ss_active');
      output('ss_tx_p') <= (ssActive & ssTog);
      output('ss_tx_n') <= ~(ssActive & ssTog);
      output('ss_tx_oe') <= ssActive;
    }

    interrupt <= (intStatus & intEnable).or();

    Sequential(clk, [
      If(
        reset,
        then: [
          ctrlEnable < Const(0),
          deviceAddr < Const(0, width: 7),
          intStatus < Const(0, width: 8),
          intEnable < Const(0, width: 8),
          connected < Const(0),
          frameNum < Const(0, width: 11),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
          txBusy < Const(0),
          phase < Const(pSync, width: 3),
          byteIdx < Const(0, width: ptrW),
          bitInByte < Const(0, width: 3),
          crc16 < Const(0xFFFF, width: 16),
          onesCount < Const(0, width: 3),
          lineJ < Const(1),
          eopCnt < Const(0, width: 2),
          pidReg < Const(0, width: 4),
          hasData < Const(0),
          txLen < Const(0, width: ptrW),
          txWrPtr < Const(0, width: ptrW),
          dpReg < Const(0),
          dmReg < Const(0),
          oeReg < Const(0),
          rxActive < Const(0),
          rxPrev < Const(1),
          rxOnes < Const(0, width: 3),
          rxBitCnt < Const(0, width: 3),
          rxShift < Const(0, width: 8),
          rxByteIdx < Const(0, width: 8),
          rxCrc16r < Const(0xFFFF, width: 16),
          rxCrc5r < Const(0x1F, width: 5),
          rxPid < Const(0, width: 4),
          rxWrPtr < Const(0, width: ptrW),
          rxRdPtr < Const(0, width: ptrW),
          rxLen < Const(0, width: ptrW),
          awaitData < Const(0),
          awaitSetup < Const(0),
          txReady < Const(0),
          txQPid < Const(0, width: 4),
          txRaw < Const(0),
          txTokenMode < Const(0),
          hostAddr < Const(0, width: 7),
          hostEndp < Const(0, width: 4),
          hostModeReg < Const(0),
          hostState < Const(hIdle, width: 3),
          hostBusy < Const(0),
          hostDone < Const(0),
          hostResult < Const(0, width: 2),
          hostRespPid < Const(0, width: 4),
          hostTxSeen < Const(0),
          hostTimeout < Const(0, width: 9),
          hostTokPid < Const(0, width: 4),
          hostToggle < Const(0),
          hsMode < Const(0),
          chState < Const(chIdle, width: 2),
          se0Cnt < Const(0, width: 5),
          chirpCnt < Const(0, width: 5),
          chirpEdges < Const(0, width: 4),
          chirpPrev < Const(1),
          ssLtssm < Const(ssRxDetect, width: 3),
          ssDwell < Const(0, width: 4),
          ssLinkUp < Const(0),
          ssTog < Const(0),
          ...List.generate(fifoSize, (i) => fifo[i] < Const(0, width: 8)),
          ...List.generate(fifoSize, (i) => rxBuf[i] < Const(0, width: 8)),
        ],
        orElse: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          // Frame counter (increments every 1ms at full speed)
          If(ctrlEnable, then: [frameNum < (frameNum + Const(1, width: 11))]),

          // Bus access
          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              // Global registers (0x000-0x1FF). Also checks the upper address
              // bits above the page select, so an address past the two
              // defined 512-byte pages reads 0 and ignores writes instead of
              // aliasing a register.
              If(
                ~bus.addr[9] & bus.addr.getRange(10, 12).eq(Const(0, width: 2)),
                then: [
                  Case(bus.addr.getRange(0, 9), [
                    // 0x000: CTRL ([0] enable, [1] host mode for OTG builds)
                    CaseItem(Const(0x00, width: 9), [
                      If(
                        bus.we & bus.selAny(0x00, 1),
                        then: [
                          ctrlEnable < bus.dataIn[0],
                          if (config.role == HarborUsbRole.otg)
                            hostModeReg < bus.dataIn[1],
                        ],
                        orElse: [
                          bus.dataOut <
                              ctrlEnable.zeroExtend(32) |
                                  (hostMode.zeroExtend(32) <<
                                      Const(1, width: 32)),
                        ],
                      ),
                    ]),
                    // 0x008: STATUS ([0] connected, [7:4] negotiated speed,
                    // [8] high-speed, [9] SuperSpeed link up)
                    CaseItem(Const(0x08, width: 9), [
                      bus.dataOut <
                          connected.zeroExtend(32) |
                              (mux(
                                    ssLinkUp,
                                    Const(
                                      HarborUsbSpeed.super_.index,
                                      width: 32,
                                    ),
                                    mux(
                                      hsMode,
                                      Const(
                                        HarborUsbSpeed.high.index,
                                        width: 32,
                                      ),
                                      Const(
                                        HarborUsbSpeed.full.index,
                                        width: 32,
                                      ),
                                    ),
                                  ) <<
                                  Const(4, width: 32)) |
                              (hsMode.zeroExtend(32) << Const(8, width: 32)) |
                              (ssLinkUp.zeroExtend(32) << Const(9, width: 32)),
                    ]),
                    // 0x010: ADDR
                    CaseItem(Const(0x10, width: 9), [
                      If(
                        bus.we,
                        then: [deviceAddr < bus.selMerge(deviceAddr, 0x10)],
                        orElse: [bus.dataOut < deviceAddr.zeroExtend(32)],
                      ),
                    ]),
                    // 0x018: INT_STATUS (write-1-to-clear)
                    CaseItem(Const(0x18, width: 9), [
                      If(
                        bus.we,
                        then: [
                          intStatus < (intStatus & ~bus.selMasked(0x18, 8)),
                        ],
                        orElse: [bus.dataOut < intStatus.zeroExtend(32)],
                      ),
                    ]),
                    // 0x020: INT_ENABLE
                    CaseItem(Const(0x20, width: 9), [
                      If(
                        bus.we,
                        then: [intEnable < bus.selMerge(intEnable, 0x20)],
                        orElse: [bus.dataOut < intEnable.zeroExtend(32)],
                      ),
                    ]),
                    // 0x028: FRAME
                    CaseItem(Const(0x28, width: 9), [
                      bus.dataOut < frameNum.zeroExtend(32),
                    ]),
                  ]),
                ],
              ),

              // EP0 transmit registers (addr bit 8 set).
              // - 0x200: EP0_CTRL  write kicks a packet
              //              [7:4] PID nibble, [1] has-data, [0] start
              //              read returns busy in bit 0
              // - 0x218: EP0_TXDATA  write pushes a payload byte
              // - 0x228: EP0_TXLEN   write sets payload length, resets FIFO
              If(
                bus.addr[9] & bus.addr.getRange(10, 12).eq(Const(0, width: 2)),
                then: [
                  Case(bus.addr.getRange(0, 9), [
                    // EP0_CTRL: [7:4] PID, [2] arm-for-IN, [1] has-data,
                    // [0] start now. Arming queues the packet so the next IN
                    // token from the host transmits it.
                    CaseItem(Const(0x00, width: 9), [
                      If(
                        bus.we & bus.selAny(0x200, 1),
                        then: [
                          If(
                            bus.dataIn[2],
                            then: [
                              txReady < Const(1),
                              txQPid < bus.dataIn.getRange(4, 8),
                              hasData < bus.dataIn[1],
                            ],
                            orElse: kickTx(
                              bus.dataIn.getRange(4, 8),
                              bus.dataIn[1],
                            ),
                          ),
                        ],
                        orElse: [bus.dataOut < txBusy.zeroExtend(32)],
                      ),
                    ]),
                    // EP0_TXDATA
                    CaseItem(Const(0x18, width: 9), [
                      If(
                        bus.we & bus.selAny(0x218, 1),
                        then: [
                          for (var i = 0; i < fifoSize; i++)
                            If(
                              txWrPtr.eq(Const(i, width: ptrW)),
                              then: [fifo[i] < bus.dataIn.getRange(0, 8)],
                            ),
                          txWrPtr < (txWrPtr + Const(1, width: ptrW)),
                        ],
                      ),
                    ]),
                    // EP0_TXLEN
                    CaseItem(Const(0x28, width: 9), [
                      If(
                        bus.we,
                        then: [
                          txLen < bus.selMerge(txLen, 0x228),
                          txWrPtr < Const(0, width: ptrW),
                        ],
                        orElse: [bus.dataOut < txLen.zeroExtend(32)],
                      ),
                    ]),
                    // EP0_RXLEN: number of received body bytes (read-only)
                    CaseItem(Const(0x80, width: 9), [
                      bus.dataOut < rxLen.zeroExtend(32),
                    ]),
                    // EP0_RXDATA: pop one received byte
                    CaseItem(Const(0x88, width: 9), [
                      bus.dataOut < rxReadByte.zeroExtend(32),
                      If(
                        ~bus.we,
                        then: [rxRdPtr < (rxRdPtr + Const(1, width: ptrW))],
                      ),
                    ]),
                    // EP0_STATUS: [3:0] last PID, [4] tx busy, [5] awaiting
                    // data, [6] IN armed
                    CaseItem(Const(0x90, width: 9), [
                      bus.dataOut <
                          rxPid.zeroExtend(32) |
                              (txBusy.zeroExtend(32) << Const(4, width: 32)) |
                              (awaitData.zeroExtend(32) <<
                                  Const(5, width: 32)) |
                              (txReady.zeroExtend(32) << Const(6, width: 32)),
                    ]),
                    // HOST_TOKEN (0x20): write starts a host transaction.
                    //   [3:0] token PID, [10:4] address, [14:11] endpoint,
                    //   [15] data toggle (DATA1 when set)
                    if (roleHasHost)
                      CaseItem(Const(0x100, width: 9), [
                        If(
                          bus.we & hostMode & bus.selAny(0x300, 2),
                          then: [
                            hostBusy < Const(1),
                            hostDone < Const(0),
                            hostResult < Const(0, width: 2),
                            hostTokPid < bus.dataIn.getRange(0, 4),
                            hostAddr < bus.dataIn.getRange(4, 11),
                            hostEndp < bus.dataIn.getRange(11, 15),
                            hostToggle < bus.dataIn[15],
                            hostTxSeen < Const(0),
                            hostState < Const(hSendTok, width: 3),
                            ...kickTx(
                              bus.dataIn.getRange(0, 4),
                              Const(1),
                              raw: true,
                              token: true,
                            ),
                          ],
                        ),
                      ]),
                    // HOST_STATUS (0x21): [0] busy, [1] done, [3:2] result
                    //   (0 ACK, 1 NAK, 2 timeout, 3 stall), [7:4] response PID
                    if (roleHasHost)
                      CaseItem(Const(0x108, width: 9), [
                        bus.dataOut <
                            hostBusy.zeroExtend(32) |
                                (hostDone.zeroExtend(32) <<
                                    Const(1, width: 32)) |
                                (hostResult.zeroExtend(32) <<
                                    Const(2, width: 32)) |
                                (hostRespPid.zeroExtend(32) <<
                                    Const(4, width: 32)),
                      ]),
                  ]),
                ],
              ),
            ],
          ),

          // Hold the line idle (J, driver off) while not transmitting and not
          // driving a device chirp.
          If(
            ~txBusy & ~chirping,
            then: [
              oeReg < Const(0),
              dpReg < Const(0),
              dmReg < Const(0),
              lineJ < Const(1),
            ],
          ),

          // Serializer: one line symbol per cycle.
          If(
            txBusy,
            then: [
              oeReg < Const(1),
              If(
                phase.eq(Const(pEop, width: 3)),
                then: [
                  // EOP: SE0, SE0, then idle J before releasing the bus.
                  eopCnt < (eopCnt + Const(1, width: 2)),
                  Case(
                    eopCnt,
                    [
                      CaseItem(Const(0, width: 2), [
                        dpReg < Const(0),
                        dmReg < Const(0),
                      ]),
                      CaseItem(Const(1, width: 2), [
                        dpReg < Const(0),
                        dmReg < Const(0),
                      ]),
                    ],
                    defaultItem: [dpReg < Const(1), dmReg < Const(0)],
                  ),
                  If(
                    eopCnt.eq(Const(2, width: 2)),
                    then: [
                      txBusy < Const(0),
                      oeReg < Const(0),
                      phase < Const(pSync, width: 3),
                    ],
                  ),
                ],
                orElse: [
                  // Drive NRZI line state for this symbol.
                  dpReg < mux(nextLineJ, Const(1), Const(0)),
                  dmReg < mux(nextLineJ, Const(0), Const(1)),
                  lineJ < nextLineJ,
                  If(
                    stuffNow,
                    then: [
                      // Inserted stuffing bit: a 0, consumes no data.
                      onesCount < Const(0, width: 3),
                    ],
                    orElse: [
                      onesCount <
                          mux(
                            dataBit,
                            onesCount + Const(1, width: 3),
                            Const(0, width: 3),
                          ),
                      If(
                        phase.eq(Const(pPayload, width: 3)),
                        then: [
                          crc16 <
                              mux(
                                crc16[0] ^ dataBit,
                                (crc16 >>> 1) ^ Const(0xA001, width: 16),
                                crc16 >>> 1,
                              ),
                        ],
                      ),
                      If(
                        bitInByte.eq(Const(7, width: 3)),
                        then: [
                          bitInByte < Const(0, width: 3),
                          Case(phase, [
                            CaseItem(Const(pSync, width: 3), [
                              phase < Const(pPid, width: 3),
                            ]),
                            CaseItem(Const(pPid, width: 3), [
                              If(
                                hasData & effLen.gt(Const(0, width: ptrW)),
                                then: [
                                  phase < Const(pPayload, width: 3),
                                  byteIdx < Const(0, width: ptrW),
                                ],
                                orElse: [
                                  If(
                                    hasData & ~txRaw,
                                    then: [
                                      phase < Const(pCrc, width: 3),
                                      byteIdx < Const(0, width: ptrW),
                                    ],
                                    orElse: [phase < Const(pEop, width: 3)],
                                  ),
                                ],
                              ),
                            ]),
                            CaseItem(Const(pPayload, width: 3), [
                              If(
                                nextByteIdx.eq(effLen),
                                then: [
                                  If(
                                    txRaw,
                                    then: [phase < Const(pEop, width: 3)],
                                    orElse: [
                                      phase < Const(pCrc, width: 3),
                                      byteIdx < Const(0, width: ptrW),
                                    ],
                                  ),
                                ],
                                orElse: [byteIdx < nextByteIdx],
                              ),
                            ]),
                            CaseItem(Const(pCrc, width: 3), [
                              If(
                                byteIdx.eq(Const(0, width: ptrW)),
                                then: [byteIdx < Const(1, width: ptrW)],
                                orElse: [phase < Const(pEop, width: 3)],
                              ),
                            ]),
                          ]),
                        ],
                        orElse: [bitInByte < (bitInByte + Const(1, width: 3))],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),

          // Receiver and transaction layer. Frozen while we drive the line or
          // while a high-speed chirp negotiation is in progress.
          If(
            ~txBusy & chReady,
            then: [
              If(
                rxActive,
                then: [
                  If(
                    rxSE0,
                    then: [
                      // End of packet: classify and respond.
                      rxActive < Const(0),
                      rxPrev < Const(1),
                      rxBitCnt < Const(0, width: 3),
                      rxByteIdx < Const(0, width: 8),
                      // Device-role responder (disabled while in host mode).
                      if (roleHasDevice)
                        If(
                          ~hostMode,
                          then: [
                            // Token addressed to us: act on its kind.
                            If(
                              isToken & crc5ok & addrMatch,
                              then: [
                                If(
                                  isInTok,
                                  then: [
                                    If(
                                      txReady,
                                      then: [
                                        ...kickTx(txQPid, Const(1)),
                                        txReady < Const(0),
                                      ],
                                      orElse: kickTx(
                                        Const(pidNak, width: 4),
                                        Const(0),
                                      ),
                                    ),
                                  ],
                                ),
                                If(
                                  isOutTok | isSetupTok,
                                  then: [
                                    awaitData < Const(1),
                                    awaitSetup < isSetupTok,
                                  ],
                                ),
                              ],
                            ),
                            // Data after an OUT/SETUP token: store, flag, ACK.
                            If(
                              isData & crc16ok & awaitData,
                              then: [
                                awaitData < Const(0),
                                rxLen <
                                    (rxByteIdx - Const(4, width: 8)).getRange(
                                      0,
                                      ptrW,
                                    ),
                                rxRdPtr < Const(0, width: ptrW),
                                intStatus <
                                    (intStatus |
                                        mux(
                                          awaitSetup,
                                          Const(0x01, width: 8),
                                          Const(0x02, width: 8),
                                        )),
                                ...kickTx(Const(pidAck, width: 4), Const(0)),
                              ],
                            ),
                            // Host acknowledged our IN data.
                            If(
                              isAck,
                              then: [
                                intStatus < (intStatus | Const(0x04, width: 8)),
                              ],
                            ),
                          ],
                        ),
                      // Host-role reaction to a device response.
                      if (roleHasHost)
                        If(
                          hostMode,
                          then: [
                            hostRespPid < rxPid,
                            Case(hostState, [
                              // Handshake after our OUT/SETUP data phase.
                              CaseItem(Const(hRxResp, width: 3), [
                                hostResult <
                                    mux(
                                      isAck,
                                      Const(0, width: 2),
                                      mux(
                                        rxPid.eq(Const(pidNak, width: 4)),
                                        Const(1, width: 2),
                                        Const(3, width: 2),
                                      ),
                                    ),
                                hostBusy < Const(0),
                                hostDone < Const(1),
                                hostState < Const(hIdle, width: 3),
                              ]),
                              // Device DATA in response to our IN token.
                              CaseItem(Const(hRxData, width: 3), [
                                If(
                                  isData & crc16ok,
                                  then: [
                                    rxLen <
                                        (rxByteIdx - Const(4, width: 8))
                                            .getRange(0, ptrW),
                                    rxRdPtr < Const(0, width: ptrW),
                                    hostResult < Const(0, width: 2),
                                    ...kickTx(
                                      Const(pidAck, width: 4),
                                      Const(0),
                                    ),
                                    hostState < Const(hSendAck, width: 3),
                                  ],
                                  orElse: [
                                    hostResult < Const(1, width: 2),
                                    hostBusy < Const(0),
                                    hostDone < Const(1),
                                    hostState < Const(hIdle, width: 3),
                                  ],
                                ),
                              ]),
                            ]),
                          ],
                        ),
                    ],
                    orElse: rxProcessBit(),
                  ),
                ],
                orElse: [
                  // Idle: a K symbol is the first bit of a SYNC, start a packet.
                  If(
                    ctrlEnable & ~rxJ & ~rxSE0,
                    then: [
                      rxActive < Const(1),
                      rxOnes < Const(0, width: 3),
                      rxBitCnt < Const(0, width: 3),
                      rxByteIdx < Const(0, width: 8),
                      rxWrPtr < Const(0, width: ptrW),
                      rxCrc16r < Const(0xFFFF, width: 16),
                      rxCrc5r < Const(0x1F, width: 5),
                      ...rxProcessBit(),
                    ],
                  ),
                ],
              ),
            ],
          ),

          // High-speed reset/chirp negotiation (only for HS-capable configs).
          if (config.isHighSpeed)
            If(
              ctrlEnable,
              then: [
                Case(chState, [
                  CaseItem(Const(chIdle, width: 2), [
                    // A sustained SE0 on the line is a USB bus reset.
                    If(
                      rxSE0,
                      then: [
                        If(
                          se0Cnt.eq(Const(resetThresh, width: 5)),
                          then: [
                            chState < Const(chDevChirp, width: 2),
                            chirpCnt < Const(0, width: 5),
                            hsMode < Const(0),
                          ],
                          orElse: [se0Cnt < (se0Cnt + Const(1, width: 5))],
                        ),
                      ],
                      orElse: [se0Cnt < Const(0, width: 5)],
                    ),
                  ]),
                  CaseItem(Const(chDevChirp, width: 2), [
                    // Drive the device chirp (a sustained K).
                    oeReg < Const(1),
                    dpReg < Const(0),
                    dmReg < Const(1),
                    If(
                      chirpCnt.eq(Const(chirpLen, width: 5)),
                      then: [
                        chState < Const(chWaitHost, width: 2),
                        oeReg < Const(0),
                        chirpEdges < Const(0, width: 4),
                        chirpPrev < Const(1),
                      ],
                      orElse: [chirpCnt < (chirpCnt + Const(1, width: 5))],
                    ),
                  ]),
                  CaseItem(Const(chWaitHost, width: 2), [
                    // Count the host chirp's K-J transitions. Enough of them
                    // confirms a high-speed-capable host.
                    If(
                      rxJ.neq(chirpPrev),
                      then: [
                        chirpEdges < (chirpEdges + Const(1, width: 4)),
                        chirpPrev < rxJ,
                      ],
                    ),
                    If(
                      chirpEdges.gte(Const(chirpEdgesNeeded, width: 4)),
                      then: [
                        hsMode < Const(1),
                        chState < Const(chIdle, width: 2),
                        se0Cnt < Const(0, width: 5),
                      ],
                    ),
                  ]),
                ]),
              ],
            ),

          // SuperSpeed link training (only for SuperSpeed-capable configs).
          if (config.isSuperSpeed)
            If(
              ctrlEnable,
              then: [
                ssTog < ~ssTog,
                Case(ssLtssm, [
                  CaseItem(Const(ssRxDetect, width: 3), [
                    // Detect the link partner on the SSRX pair.
                    If(
                      input('ss_rx_p'),
                      then: [
                        If(
                          ssDwell.eq(Const(ssTrainDwell, width: 4)),
                          then: [
                            ssLtssm < Const(ssPolling, width: 3),
                            ssDwell < Const(0, width: 4),
                          ],
                          orElse: [ssDwell < (ssDwell + Const(1, width: 4))],
                        ),
                      ],
                      orElse: [ssDwell < Const(0, width: 4)],
                    ),
                  ]),
                  CaseItem(Const(ssPolling, width: 3), [
                    If(
                      ssDwell.eq(Const(ssTrainDwell, width: 4)),
                      then: [
                        ssLtssm < Const(ssU0, width: 3),
                        ssDwell < Const(0, width: 4),
                        ssLinkUp < Const(1),
                      ],
                      orElse: [ssDwell < (ssDwell + Const(1, width: 4))],
                    ),
                  ]),
                  CaseItem(Const(ssU0, width: 3), [
                    // Drop back to detect if the partner goes away.
                    If(
                      ~input('ss_rx_p'),
                      then: [
                        ssLtssm < Const(ssRxDetect, width: 3),
                        ssLinkUp < Const(0),
                      ],
                    ),
                  ]),
                ]),
              ],
            ),

          // Host transaction sequencer: drives the token / data / handshake
          // phases off the shared serializer. Device responses are handled in
          // the receive block above. Timeouts are counted here.
          if (roleHasHost)
            If(
              hostMode & ctrlEnable,
              then: [
                If(txBusy, then: [hostTxSeen < Const(1)]),
                Case(hostState, [
                  // Token sent: IN waits for data, OUT/SETUP sends data, a
                  // token-only request (SOF) finishes here.
                  CaseItem(Const(hSendTok, width: 3), [
                    If(
                      ~txBusy & hostTxSeen,
                      then: [
                        hostTxSeen < Const(0),
                        If(
                          hostTokPid.eq(Const(pidIn, width: 4)),
                          then: [
                            hostState < Const(hRxData, width: 3),
                            hostTimeout < Const(0, width: 9),
                          ],
                          orElse: [
                            If(
                              hostTokPid.eq(Const(pidOut, width: 4)) |
                                  hostTokPid.eq(Const(pidSetup, width: 4)),
                              then: [
                                ...kickTx(
                                  mux(
                                    hostToggle,
                                    Const(pidData1, width: 4),
                                    Const(pidData0, width: 4),
                                  ),
                                  Const(1),
                                ),
                                hostState < Const(hSendData, width: 3),
                              ],
                              orElse: [
                                hostBusy < Const(0),
                                hostDone < Const(1),
                                hostState < Const(hIdle, width: 3),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ]),
                  // OUT/SETUP data sent: wait for the device handshake.
                  CaseItem(Const(hSendData, width: 3), [
                    If(
                      ~txBusy & hostTxSeen,
                      then: [
                        hostTxSeen < Const(0),
                        hostState < Const(hRxResp, width: 3),
                        hostTimeout < Const(0, width: 9),
                      ],
                    ),
                  ]),
                  // ACK sent after an IN data phase: transaction complete.
                  CaseItem(Const(hSendAck, width: 3), [
                    If(
                      ~txBusy & hostTxSeen,
                      then: [
                        hostTxSeen < Const(0),
                        hostBusy < Const(0),
                        hostDone < Const(1),
                        hostState < Const(hIdle, width: 3),
                      ],
                    ),
                  ]),
                  // Waiting for a response: give up after a timeout.
                  CaseItem(Const(hRxResp, width: 3), [
                    If(
                      hostTimeout.eq(Const(hostTimeoutMax, width: 9)),
                      then: [
                        hostResult < Const(2, width: 2),
                        hostBusy < Const(0),
                        hostDone < Const(1),
                        hostState < Const(hIdle, width: 3),
                      ],
                      orElse: [
                        hostTimeout < (hostTimeout + Const(1, width: 9)),
                      ],
                    ),
                  ]),
                  CaseItem(Const(hRxData, width: 3), [
                    If(
                      hostTimeout.eq(Const(hostTimeoutMax, width: 9)),
                      then: [
                        hostResult < Const(2, width: 2),
                        hostBusy < Const(0),
                        hostDone < Const(1),
                        hostState < Const(hIdle, width: 3),
                      ],
                      orElse: [
                        hostTimeout < (hostTimeout + Const(1, width: 9)),
                      ],
                    ),
                  ]),
                ]),
              ],
            ),
        ],
      ),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,usb'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      'maximum-speed': _dtSpeedString(config.maxSpeed),
      'dr_mode': config.role == HarborUsbRole.otg ? 'otg' : config.role.name,
      'num-endpoints': config.endpointCount,
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,usb'],
      'maximum-speed': _dtSpeedString(config.maxSpeed),
      'dr_mode': config.role == HarborUsbRole.otg ? 'otg' : config.role.name,
      'num-endpoints': config.endpointCount,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'USB',
    groupName: 'USB',
    description: 'USB controller',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}

/// Maps HarborUsbSpeed to the Linux DT `maximum-speed` string.
String _dtSpeedString(HarborUsbSpeed speed) => switch (speed) {
  HarborUsbSpeed.low => 'low-speed',
  HarborUsbSpeed.full => 'full-speed',
  HarborUsbSpeed.high => 'high-speed',
  HarborUsbSpeed.super_ => 'super-speed',
  HarborUsbSpeed.superPlus => 'super-speed-plus',
  HarborUsbSpeed.superPlus2x2 => 'super-speed-plus',
};
