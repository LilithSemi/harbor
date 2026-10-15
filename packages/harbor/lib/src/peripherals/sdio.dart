import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../arith/fpu_config.dart' show harborStableDefinitionName;
import '../blackbox/ecp5/ecp5.dart';
import '../blackbox/xilinx/xilinx.dart';
import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../bus/port/memory_port.dart';
import '../bus/port/memory_waist.dart';
import '../bus/port/port_cdc.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../soc/target.dart';
import '../util/pretty_string.dart';

/// SD/SDIO bus width.
enum HarborSdioBusWidth {
  /// 1-bit data bus.
  one(1),

  /// 4-bit data bus.
  four(4),

  /// 8-bit data bus (eMMC only).
  eight(8);

  final int width;
  const HarborSdioBusWidth(this.width);
}

/// SD/SDIO speed mode.
enum HarborSdioSpeed {
  /// Default speed (25 MHz, SD).
  defaultSpeed,

  /// High speed (50 MHz, SD).
  highSpeed,

  /// UHS-I SDR12 (25 MHz, SD 3.0).
  sdr12,

  /// UHS-I SDR25 (50 MHz, SD 3.0).
  sdr25,

  /// UHS-I SDR50 (100 MHz, SD 3.0).
  sdr50,

  /// UHS-I SDR104 (208 MHz, SD 3.0).
  sdr104,

  /// UHS-I DDR50 (50 MHz DDR, SD 3.0).
  ddr50,

  /// HS200 (200 MHz, eMMC 4.5).
  hs200,

  /// HS400 (200 MHz DDR, eMMC 5.0).
  hs400,
}

/// SD/SDIO controller configuration.
class HarborSdioConfig with HarborPrettyString {
  /// Maximum bus width supported.
  final HarborSdioBusWidth maxBusWidth;

  /// Maximum speed mode supported.
  final HarborSdioSpeed maxSpeed;

  /// Whether SDIO (I/O card) mode is supported.
  final bool supportsIo;

  /// Whether eMMC mode is supported.
  final bool supportsEmmc;

  /// Whether 1.8V signaling is supported (UHS-I).
  final bool supports1v8;

  /// Maximum clock frequency in Hz.
  final int maxFrequency;

  /// Maximum number of SDIO I/O functions (1-7, 0 = no I/O support).
  ///
  /// WiFi/BT combo chips typically use 2 functions
  /// (function 1: WiFi, function 2: Bluetooth).
  final int maxIoFunctions;

  /// Reset default for the read-data sample edge.
  ///
  /// When false the read DAT lines sample on the SD clock rising edge (the
  /// standard host behaviour). When true they sample half a clock period later,
  /// on the falling edge, which gives the card-to-host round-trip more time to
  /// settle at speed. The active edge is also a runtime bit (CTRL[8]), so
  /// firmware can override this default and calibrate against a known pattern.
  final bool sampleReadOnFall;

  const HarborSdioConfig({
    this.maxBusWidth = HarborSdioBusWidth.four,
    this.maxSpeed = HarborSdioSpeed.highSpeed,
    this.supportsIo = false,
    this.supportsEmmc = false,
    this.supports1v8 = false,
    this.maxFrequency = 50000000,
    this.maxIoFunctions = 0,
    this.sampleReadOnFall = false,
  });

  /// SD card controller (standard 4-bit, up to high speed).
  const HarborSdioConfig.sd()
    : maxBusWidth = HarborSdioBusWidth.four,
      maxSpeed = HarborSdioSpeed.highSpeed,
      supportsIo = false,
      supportsEmmc = false,
      supports1v8 = false,
      maxFrequency = 50000000,
      maxIoFunctions = 0,
      sampleReadOnFall = false;

  /// SDIO WiFi/BT controller (4-bit, high speed, I/O functions).
  ///
  /// Suitable for chips like ESP32, CYW43455, RTL8822, etc.
  const HarborSdioConfig.wifi()
    : maxBusWidth = HarborSdioBusWidth.four,
      maxSpeed = HarborSdioSpeed.highSpeed,
      supportsIo = true,
      supportsEmmc = false,
      supports1v8 = false,
      maxFrequency = 50000000,
      maxIoFunctions = 2,
      sampleReadOnFall = false;

  /// SD 3.0 UHS-I controller with full SDIO support.
  const HarborSdioConfig.uhs()
    : maxBusWidth = HarborSdioBusWidth.four,
      maxSpeed = HarborSdioSpeed.sdr104,
      supportsIo = true,
      supportsEmmc = false,
      supports1v8 = true,
      maxFrequency = 208000000,
      maxIoFunctions = 7,
      sampleReadOnFall = false;

  /// eMMC controller (8-bit, HS200).
  const HarborSdioConfig.emmc()
    : maxBusWidth = HarborSdioBusWidth.eight,
      maxSpeed = HarborSdioSpeed.hs200,
      supportsIo = false,
      supportsEmmc = true,
      supports1v8 = true,
      maxFrequency = 200000000,
      maxIoFunctions = 0,
      sampleReadOnFall = false;

  @override
  String toString() =>
      'HarborSdioConfig(${maxBusWidth.width}-bit, ${maxSpeed.name}, '
      '${maxFrequency ~/ 1000000} MHz)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborSdioConfig(\n');
    buf.writeln('${c}busWidth: ${maxBusWidth.width}-bit,');
    buf.writeln('${c}speed: ${maxSpeed.name},');
    buf.writeln('${c}maxFrequency: ${maxFrequency ~/ 1000000} MHz,');
    if (supportsIo) buf.writeln('${c}SDIO I/O,');
    if (supportsEmmc) buf.writeln('${c}eMMC,');
    if (supports1v8) buf.writeln('${c}1.8V signaling,');
    buf.write('$p)');
    return buf.toString();
  }
}

/// SD/SDIO/eMMC host controller.
///
/// Register map (each register in its own 8-byte slot; the byte-addressed fabric
/// decodes byte-offset >> 3, so these byte offsets map to indices 0,1,2,...):
/// - 0x00: CTRL      (enable, bus width, speed mode, reset)
/// - 0x08: STATUS    ([0] card detect, [8] busy, [9] data ready)
/// - 0x10: CLK_DIV   (clock divider)
/// - 0x18: CMD       (command index + argument trigger)
/// - 0x20: CMD_ARG   (command argument)
/// - 0x28: RESP0     (response bits 31:0)
/// - 0x30: RESP1     (response bits 63:32)
/// - 0x38: RESP2     (response bits 95:64)
/// - 0x40: RESP3     (response bits 127:96)
/// - 0x48: DATA      (read/write data FIFO)
/// - 0x50: BLK_SIZE  (block size for data transfers)
/// - 0x58: BLK_COUNT (block count for multi-block transfers)
/// - 0x60: INT_STATUS (interrupt status, write-1-to-clear)
/// - 0x68: INT_ENABLE (interrupt enable)
/// - 0x70: ADMA_ADDR  (DMA buffer address, or descriptor table base)
///
/// CMD bits: [5:0] index, [7:6] response type (0 none, 1 short, 2 long R2,
/// 3 short+busy), [8] data present, [9] direction (0 write, 1 read), [10] use
/// ADMA DMA, [11] ADMA_ADDR is a descriptor table. INT_STATUS bits (each
/// write-1-to-clear): [0] cmd-done, [1] data-done, [2] data-request,
/// [3] data-CRC-error, [4] cmd-timeout, [5] write-error, [6] RX overrun,
/// [7] ADMA error.
///
/// DMA: with CMD[10] set and CMD[11] clear, ADMA_ADDR is the buffer address
/// and BLK_COUNT * BLK_SIZE is its length. With CMD[11] set, ADMA_ADDR points
/// to a table of 8-byte descriptors: word 0 is the buffer address, word 1 has
/// the byte length in [15:0] and the end flag in [31]. Buffer addresses and
/// lengths are word multiples.
///
/// The ADMA is a memory master on the interface `dma`, of the same fabric
/// kind as `bus`. A card read sends INCR write bursts of up to
/// [dmaBurstBeats] beats that do not cross a 4 KB boundary. On a 64-bit port
/// an 8-byte aligned run uses full beats of two words. Data-done comes after
/// the last write response, so the data is in memory when the driver sees
/// it. Reads (descriptors and card-write data) go out only when no write is
/// in flight. Add it to a SoC with
/// `soc.addMaster(sdio, busInterfaceName: 'dma', memory: true,
/// outstanding: sdio.dmaOutstanding)`.
///
/// A read or write error response sets ADMA error and stops the walker. The
/// transfer still ends: on a card read the controller drops the rest of the
/// card data, on a card write it sends zero words to the card until the
/// block count ends. Each card write block from the error on goes out with
/// an inverted CRC16, so the card rejects it and does not program it. The
/// driver must treat the transfer as failed.
///
/// STATUS[8] busy is also set while an ADMA access is in flight, for example
/// after a command timeout. A CMD write while busy is ignored, so the driver
/// must wait for busy to clear first.
class HarborSdioController extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider,
        HarborSimModelProvider,
        HarborInputClockConsumer {
  /// Controller configuration.
  final HarborSdioConfig config;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// Build target. When set on a UHS-capable [config], the read sampling path
  /// is conditioned with per-vendor IO primitives (input delay for SDR50/104
  /// tuning, DDR gearing for DDR50/HS400). This is a structural,
  /// not-yet-calibrated layer (placeholder taps), the SDIO analogue of the
  /// Xilinx DDR PHY. Null or a non-UHS config leaves the proven SDR datapath
  /// untouched.
  final HarborDeviceTarget? target;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  /// Collapse the split CMD/DAT out+oe+in triplets into single bidirectional
  /// `sd_cmd` / `sd_dat` pads (a `TriStateBuffer` per line), the shape an FPGA
  /// IOBUF wants. Off by default so the verification tests drive the split
  /// ports; genip turns it on to bind one inout pad per line to a board pin.
  final bool ownPads;

  /// The ADMA memory master port, interface `dma`.
  late final HarborMemoryMasterPort dmaPort;

  /// Address width of the ADMA master. The ADMA engine computes 32-bit
  /// addresses. On a wider fabric they are zero-extended.
  final int dmaAddressWidth;

  /// Data width of the ADMA master, 32 or 64. On a 64-bit port a single word
  /// goes in the half of the beat its address selects, and reads take that
  /// same half.
  final int dmaDataWidth;

  /// Requests the ADMA master can have in flight.
  final int dmaOutstanding;

  /// Controller input clock in Hz (the system clock the CLK_DIV register
  /// divides). Emitted as `clock-frequency`, because a driver cannot pick a
  /// divider without it: the SD clock is this rate over 2 * (CLK_DIV + 1).
  /// 0 leaves the property out.
  int clockFrequency;

  /// The most beats in one ADMA write request, 1 to 256.
  final int dmaBurstBeats;

  /// Depth of the elastic RX FIFO, in 32-bit words. It decouples the SD receive
  /// engine from memory latency: the SD clock only stalls once this many words
  /// are waiting to be drained. 16 words (64 bytes) covers a slow-DDR round trip
  /// with room to spare. Must be a power of two.
  final int rxFifoDepth;

  /// Register (slave) bus widths. Default to a 32-bit register interface for the
  /// unit tests; genip sets them to the SoC fabric widths (e.g. 64) so the
  /// controller drops onto a wider fabric. The 32-bit registers read/write in
  /// the low word of a wider bus.
  final int busAddressWidth;
  final int busDataWidth;

  /// Words the card-read ADMA waits for before it sends a write request, so
  /// requests carry bursts and not single words. The end of the SD data phase
  /// releases a smaller tail. Clamped to the RX FIFO depth.
  final int dmaWriteBatch;

  /// SD clocks a card write waits for the end of the card's busy after the
  /// CRC status. Then the transfer ends with write error and data-done.
  final int writeBusyTimeout;

  /// The default [writeBusyTimeout]: 0.67 s at 25 MHz.
  static const defaultWriteBusyTimeout = 1 << 24;

  // With [ownPads], the FSM's CMD/DAT input signals come from the inout pads;
  // held here so the late pad wiring can drive them.
  Logic? _sdCmdInInt;
  Logic? _sdDatInInt;

  HarborSdioController({
    required this.baseAddress,
    this.config = const HarborSdioConfig.sd(),
    HarborFabricKind fabricKind = HarborFabricKind.wishbone,
    bool crossFabricClock = false,
    this.target,
    this.ownPads = false,
    this.dmaAddressWidth = 32,
    this.dmaDataWidth = 32,
    this.dmaOutstanding = 4,
    this.busAddressWidth = 12,
    this.busDataWidth = 32,
    this.clockFrequency = 0,
    this.rxFifoDepth = 16,
    this.dmaBurstBeats = 16,
    this.dmaWriteBatch = 4,
    this.writeBusyTimeout = defaultWriteBusyTimeout,
    String? name,
  }) : assert(
         dmaDataWidth == 32 || dmaDataWidth == 64,
         'dmaDataWidth must be 32 or 64',
       ),
       assert(
         rxFifoDepth >= 2 && (rxFifoDepth & (rxFifoDepth - 1)) == 0,
         'rxFifoDepth must be a power of two, at least 2',
       ),
       assert(
         dmaBurstBeats >= 1 && dmaBurstBeats <= 256,
         'dmaBurstBeats must be 1 to 256',
       ),
       assert(dmaWriteBatch >= 1, 'dmaWriteBatch must be at least 1'),
       assert(writeBusyTimeout >= 1, 'writeBusyTimeout must be at least 1'),
       assert(dmaOutstanding >= 1, 'dmaOutstanding must be at least 1'),
       super(
         harborStableDefinitionName('HarborSdioController', [
           ...BusSlavePort.definitionNameParts(
             kind: fabricKind,
             addressWidth: busAddressWidth,
             dataWidth: busDataWidth,
             cross: crossFabricClock,
           ),
           'bw${config.maxBusWidth.width}',
           'sp${config.maxSpeed.name}',
           'sf${config.sampleReadOnFall}',
           if (target is HarborFpgaTarget) 'tg${target.vendor.name}',
           if (ownPads) 'pads',
           'ma$dmaAddressWidth',
           'md$dmaDataWidth',
           'mo$dmaOutstanding',
           if (crossFabricClock) 'mx${harborCdcDepth(dmaOutstanding)}',
           'rx$rxFifoDepth',
           'db$dmaBurstBeats',
           'wb$dmaWriteBatch',
           if (writeBusyTimeout != defaultWriteBusyTimeout)
             'bt$writeBusyTimeout',
         ]),
         name: name ?? 'sdio',
       ) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    final maxBusW = config.maxBusWidth.width;
    final dw = busDataWidth; // register-bus data width (32 or the fabric width)

    // SD/SDIO pins. With [ownPads] the bidirectional CMD/DAT lines are single
    // inout pads (tristate driven below); otherwise they are the split
    // out/oe/in triplets the sim tests exercise.
    addOutput('sd_clk');
    if (ownPads) {
      createPort('sd_cmd', PortDirection.inOut);
      // One scalar inout pad per DAT lane (sd_dat0..sd_datN-1). Separate scalars
      // each bind to their own board pin with a plain XDC constraint; a single
      // N-bit inout would need indexed `get_ports name[i]` that the openXC7 XDC
      // parser chokes on.
      for (var l = 0; l < maxBusW; l++) {
        createPort('sd_dat$l', PortDirection.inOut);
      }
      _sdCmdInInt = Logic(name: 'sd_cmd_in_int');
      _sdDatInInt = Logic(name: 'sd_dat_in_int', width: maxBusW);
    } else {
      addOutput('sd_cmd_out');
      addOutput('sd_cmd_oe');
      createPort('sd_cmd_in', PortDirection.input);
      addOutput('sd_dat_out', width: maxBusW);
      addOutput('sd_dat_oe');
      createPort('sd_dat_in', PortDirection.input, width: maxBusW);
    }
    createPort('sd_cd', PortDirection.input); // card detect
    addOutput('interrupt');

    final fabricClock = BusSlavePort.fabricClockInputs(
      this,
      cross: crossFabricClock,
    );
    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      kind: fabricKind,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: busAddressWidth,
      dataWidth: dw,
      fabricClock: fabricClock,
    );
    dmaPort = HarborMemoryMasterPort.create(
      module: this,
      name: 'dma',
      kind: fabricKind,
      config: HarborMemoryWaistConfig(
        addressWidth: dmaAddressWidth,
        dataWidth: dmaDataWidth,
        outstanding: dmaOutstanding,
      ),
      clk: input('clk'),
      reset: input('reset'),
      fabricClock: fabricClock,
    );

    final clk = input('clk');
    final reset = crossFabricClock
        ? (bus.reset | dmaPort.reset).named('core_reset')
        : bus.reset;
    final cardDetect = input('sd_cd');
    // Raw CMD-in source: the inout pad's captured value (ownPads) or the split
    // input port. CMD stays SDR even in HS400, so it only gets input-delay tune.
    final cmdInRaw = ownPads ? _sdCmdInInt! : input('sd_cmd_in');
    final cmdIn = _uhsTuned
        ? _uhsConditionBit(cmdInRaw, 'cmd', ddr: false)
        : cmdInRaw;

    // CMD FSM states.
    const sIdle = 0;
    const sSend = 1;
    const sWait = 2;
    const sRecv = 3;

    // INT_STATUS bits.
    const intCmdDone = 0x01;
    const intCmdTimeout = 0x10;

    // Response NCR timeout, in SD clocks (spec allows up to 64, round up).
    const respTimeout = 128;

    // Registers
    final ctrlEnable = Logic(name: 'ctrl_enable');
    // Read-data sample edge (CTRL[8]). 0 samples the read DAT lines on the SD
    // clock rising edge, 1 samples on the falling edge (half a period later)
    // so the card round-trip has more time to settle. Resets to the configured
    // default and is firmware-overridable.
    final sampleFall = Logic(name: 'sample_fall');
    final clkDiv = Logic(name: 'clk_div', width: 16);
    final cmdIndex = Logic(name: 'cmd_index', width: 6);
    final cmdArg = Logic(name: 'cmd_arg', width: 32);
    final cmdRespType = Logic(name: 'cmd_resp_type', width: 2);
    final cmdDataPresent = Logic(name: 'cmd_data_present');
    final cmdDataDir = Logic(name: 'cmd_data_dir');
    final resp = List.generate(4, (i) => Logic(name: 'resp$i', width: 32));
    final blkSize = Logic(name: 'blk_size', width: 12);
    final blkCount = Logic(name: 'blk_count', width: 16);
    final intStatus = Logic(name: 'int_status', width: 8);
    final intEnable = Logic(name: 'int_enable', width: 8);
    final busy = Logic(name: 'busy');
    final divCount = Logic(name: 'div_count', width: 16);
    final sdClkReg = Logic(name: 'sd_clk_reg');

    // CMD engine state.
    final state = Logic(name: 'cmd_state', width: 2);
    final cmdShift = Logic(name: 'cmd_shift', width: 48);
    final cmdCnt = Logic(name: 'cmd_cnt', width: 7);
    final cmdOut = Logic(name: 'cmd_out');
    final cmdOe = Logic(name: 'cmd_oe');
    final respShift = Logic(name: 'resp_shift', width: 136);
    final respCnt = Logic(name: 'resp_cnt', width: 8);
    final toCnt = Logic(name: 'to_cnt', width: 16);

    // DAT engine state. PIO block read/write at 1/4/8-bit width (selected at
    // runtime via CTRL[5:4]): [laneCount] bits move per SD clock, one per lane,
    // each lane carrying its own CRC16. A one-word holding register the CPU
    // services through DATA carries the payload, with a data-request flag.
    const dIdle = 0;
    const dRWait = 1; // read: hunt for the block start bit
    const dRead = 2; // read: shift data bytes in
    const dRCrc = 3; // read: shift the 16-bit CRC in and check it
    const dWStart = 4; // write: drive the block start bit
    const dWrite = 5; // write: shift data bytes out
    const dWCrc = 6; // write: shift the 16-bit CRC out
    const dWEnd = 7; // write: end bit
    const dWStatWait = 8; // write: hunt for the CRC status token start bit
    const dWStat = 9; // write: capture the 3-bit CRC status
    const dWBusy = 10; // write: wait out card programming (DAT0 busy)

    const intDataDone = 0x02;
    const intDataReq = 0x04;
    const intDataCrcErr = 0x08;
    const intWriteErr = 0x20; // card reported a write/CRC-status error
    const intRxOverrun = 0x40; // a received word was dropped (RX FIFO full)

    final maxW = config.maxBusWidth.width;
    final datState = Logic(name: 'dat_state', width: 4);
    // One CRC16 generator and CRC shift register per data lane.
    final crc16 = [
      for (var l = 0; l < maxW; l++) Logic(name: 'dat_crc16_$l', width: 16),
    ];
    final crcShift = [
      for (var l = 0; l < maxW; l++) Logic(name: 'dat_crc_shift_$l', width: 16),
    ];
    final byteShift = Logic(name: 'dat_byte_shift', width: 8);
    final bitsInByte = Logic(name: 'dat_bits_in_byte', width: 4);
    final byteCnt = Logic(name: 'dat_byte_cnt', width: 13);
    final blockLeft = Logic(name: 'dat_block_left', width: 16);
    final crcBitCnt = Logic(name: 'dat_crc_bit_cnt', width: 5);
    // Card-write holding register: the CPU (through DATA) or the ADMA fills it
    // and the serializer drains it. The card-READ direction does NOT use this;
    // it goes through the elastic RX FIFO below.
    final dataReg = Logic(name: 'dat_word', width: 32);
    final dataValid = Logic(name: 'dat_word_valid');
    final byteInWord = Logic(name: 'dat_byte_in_word', width: 2);
    // Elastic RX FIFO, between the DAT receive engine and whoever drains it (the
    // ADMA on a DMA transfer, the CPU through DATA on a PIO one).
    //
    // Without it the SD clock had to stall for the WHOLE memory round-trip of
    // every single word, because the receive engine could not produce word N+1
    // until word N had reached DRAM. On a slow-DDR SoC that is milliseconds per
    // word and it capped card reads at a few KB/s. With the FIFO the SD clock
    // free-runs and the ADMA drains behind it, so the stall engages only if the
    // FIFO actually fills. This is what a real SDHCI host does.
    //
    // It also removes a lost-word race: the old single-register handshake had
    // the ADMA clear `dat_word_valid` on its memory ack while the receive engine
    // set it for a freshly completed word in the same cycle. Last-write-wins
    // dropped that word, and the ADMA then waited forever for a word count that
    // could no longer arrive, leaving its bus request asserted.
    final rxDepth = rxFifoDepth;
    final rxPtrW = (rxDepth - 1).bitLength;
    final rxFifo = [
      for (var i = 0; i < rxDepth; i++) Logic(name: 'rx_fifo_$i', width: 32),
    ];
    final rxCount = Logic(name: 'rx_fifo_count', width: rxPtrW + 1);
    final rxEmpty = rxCount.eq(Const(0, width: rxPtrW + 1)).named('rx_empty');
    final rxFull = rxCount
        .eq(Const(rxDepth, width: rxPtrW + 1))
        .named('rx_full');
    // Shift FIFO: the head is always at index 0. On a pop the whole array
    // shifts down toward index 0 by the number of words retired, and a push
    // writes at the tail, so the head reads need no muxes.
    //
    // [rxHead] is the oldest word. [rxHead2] is the second oldest, which a
    // full 64-bit beat carries together with [rxHead].
    final rxHead = rxFifo[0].named('rx_head');
    final rxHead2 = rxFifo[1].named('rx_head2');

    // Write: set when the serializer has consumed all four bytes of the holding
    // register and needs the NEXT word before it can shift again. The SD clock
    // is frozen while it is set (see [datStall]), so the producer (the ADMA, or
    // the CPU through DATA) refills on the always-on system clock and the DAT
    // stream stays gapless.
    final wrNeedFill = Logic(name: 'dat_wr_need_fill');
    // Set when the SD side of a DMA read has finished but the ADMA still has
    // buffered words to land in memory. busy stays high and data-done stays
    // clear until it drains, so a driver that copies its bounce buffer the
    // moment it sees data-done cannot read words the engine has not written.
    final dmaTailWait = Logic(name: 'dma_tail_wait');
    final busWidthSel = Logic(name: 'bus_width_sel', width: 2);
    // Write CRC-status token + busy tracking.
    final statShift = Logic(name: 'dat_stat_shift', width: 3);
    final statCnt = Logic(name: 'dat_stat_cnt', width: 2);
    final busySeen = Logic(name: 'dat_busy_seen');
    final statWaitCnt = Logic(name: 'dat_stat_wait', width: 16);
    final busyW = writeBusyTimeout.bitLength;
    final busyCnt = Logic(name: 'dat_busy_wait', width: busyW);

    // ADMA. It bridges memory to the DAT word handshake: on a card read it
    // writes the RX FIFO words to memory, on a card write it reads words into
    // dataReg. It walks a descriptor table when CMD[11] is set.
    const aIdle = 0;
    const aFetch = 1; // read descriptor word [fetchHi]
    const aMemRead = 2; // card write: read a word from memory
    const aMemWrite = 3; // card read: write FIFO words to memory
    const aNext = 4; // advance within or past the current descriptor

    final dmaMode = Logic(name: 'dma_mode');
    final admaState = Logic(name: 'adma_state', width: 3);
    final descPtr = Logic(name: 'adma_desc_ptr', width: 32);
    final descAddr = Logic(name: 'adma_addr', width: 32);
    final descBytes = Logic(name: 'adma_bytes', width: 16);
    final descEnd = Logic(name: 'adma_end');
    final admaBase = Logic(name: 'adma_base', width: 32);
    final fetchHi = Logic(name: 'adma_fetch_hi');
    final admaErr = Logic(name: 'adma_err');
    // Set by an error in a card write. The CRC16 then goes out inverted.
    final wrAbort = Logic(name: 'dat_wr_abort');

    final mw = dmaPort.waist;
    final reqValid = Logic(name: 'dma_req_valid');
    final reqWrite = Logic(name: 'dma_req_write');
    final reqAddr = Logic(name: 'dma_req_addr', width: 32);
    final reqLen = Logic(name: 'dma_req_len', width: 8);
    final reqSize = Logic(name: 'dma_req_size', width: 3);
    // One read in flight at most, and which half of a 64-bit beat it wants.
    final rdPending = Logic(name: 'dma_rd_pending');
    final rdHi = Logic(name: 'dma_rd_hi');
    // Write data of the request last sent: beats left, two words per beat,
    // and the half a single word goes in.
    final wActive = Logic(name: 'dma_w_active');
    final wLeft = Logic(name: 'dma_w_left', width: 8);
    final wPack = Logic(name: 'dma_w_pack');
    final wHi = Logic(name: 'dma_w_hi');
    // Write requests sent and not yet answered.
    final ifW = (dmaOutstanding + 1).bitLength;
    final wInflight = Logic(name: 'dma_w_inflight', width: ifW);

    final reqFire = (reqValid & mw.reqReady).named('dma_req_fire');
    final wFire = (wActive & mw.wdataReady).named('dma_w_fire');
    final rFire = (rdPending & mw.rdataValid).named('dma_r_fire');
    final bFire = (mw.wrespValid & mw.wrespReady).named('dma_b_fire');
    final dmaFault = ((rFire & mw.rdataErr) | (bFire & mw.wrespErr)).named(
      'dma_fault',
    );
    final writesBusy = (wActive | wInflight.neq(Const(0, width: ifW))).named(
      'dma_writes_busy',
    );
    final dmaInFlight = (writesBusy | reqValid | rdPending).named(
      'dma_in_flight',
    );
    final rdWord = dmaDataWidth == 32
        ? mw.rdataData
        : mux(
            rdHi,
            mw.rdataData.getRange(32, 64),
            mw.rdataData.getRange(0, 32),
          ).named('dma_rd_word');
    // Read assembles bytes 0..2 here, byte 3 is the live one.
    final asmB0 = Logic(name: 'dat_asm_b0', width: 8);
    final asmB1 = Logic(name: 'dat_asm_b1', width: 8);
    final asmB2 = Logic(name: 'dat_asm_b2', width: 8);
    final datOutReg = Logic(name: 'dat_out_reg', width: maxW);
    final datOeReg = Logic(name: 'dat_oe_reg');

    // Active lane count (1/4/8, clamped to the configured maximum) and the
    // matching low-lane mask, selected at runtime from CTRL[5:4].
    final wSel1 = busWidthSel.eq(Const(0, width: 2));
    final wSel4 = busWidthSel.eq(Const(1, width: 2));
    final Logic laneCount;
    final Logic laneMask;
    if (maxW >= 8) {
      laneCount = mux(
        wSel1,
        Const(1, width: 4),
        mux(wSel4, Const(4, width: 4), Const(8, width: 4)),
      );
      laneMask = mux(
        wSel1,
        Const(0x01, width: maxW),
        mux(wSel4, Const(0x0F, width: maxW), Const(0xFF, width: maxW)),
      );
    } else if (maxW >= 4) {
      laneCount = mux(wSel1, Const(1, width: 4), Const(4, width: 4));
      laneMask = mux(wSel1, Const(0x01, width: maxW), Const(0x0F, width: maxW));
    } else {
      laneCount = Const(1, width: 4);
      laneMask = Const(0x01, width: maxW);
    }

    // SD clock and its sysclk-domain edge strobes. The engine drives CMD on the
    // falling edge and samples on the rising edge, all in the sysclk domain (the
    // SD clock is a gated divide of sysclk, so there is no clock crossing).
    // DMA read backpressure. When a received word has not yet been drained by the
    // ADMA (dataValid still set) and the SD clock is low, hold it low so the card
    // pauses and the receive engine does not produce the next word on top of the
    // undrained one. The ADMA runs on the always-on system clock, drains the word,
    // and the clock resumes. This is SD-native flow control (the host may stop
    // SDCLK mid-block), so DMA lands correctly regardless of memory latency, with
    // no startup word drops, and the descriptor/bounce can live in ordinary DRAM.
    final datDmaStall =
        (dmaMode &
                cmdDataDir &
                datState.eq(Const(dRead, width: 4)) &
                rxFull &
                ~sdClkReg)
            .named('dat_dma_stall');
    // Write backpressure, the mirror of the read stall above. The serializer
    // empties the holding register every four bytes; hold the clock low until
    // the producer refills it and the shifter takes the new word's first byte.
    // Without this the engine kept shifting and put a stale byte on the wire.
    final datWrStall =
        (datState.eq(Const(dWrite, width: 4)) & wrNeedFill & ~sdClkReg).named(
          'dat_wr_stall',
        );
    final datStall = (datDmaStall | datWrStall).named('dat_stall');
    final divTick = (ctrlEnable & divCount.eq(Const(0, width: 16)) & ~datStall)
        .named('div_tick');
    final sdRise = (divTick & ~sdClkReg).named('sd_rise');
    final sdFall = (divTick & sdClkReg).named('sd_fall');
    // The edge the read datapath samples DAT on. All four read-DAT consumers
    // (the start-bit hunt, the data shift, the CRC shift, and the RX FIFO push
    // strobe) MUST share this so the byte counter and the FIFO push stay in
    // lockstep. Rising is the default, falling shifts the sample half a period
    // later for round-trip margin.
    final readEdge = mux(sampleFall, sdFall, sdRise).named('read_edge');

    // Receive combinationals, hoisted out of the DAT engine below so the RX FIFO
    // push condition can share them: the lane group sampled this SD clock, the
    // byte it completes, and whether it completes one.
    final rawDatIn = ownPads ? _sdDatInInt! : input('sd_dat_in');
    final datIn = _uhsTuned
        ? [
            for (var l = 0; l < maxW; l++)
              _uhsConditionBit(rawDatIn[l], 'dat$l', ddr: _uhsDdr),
          ].rswizzle()
        : rawDatIn;

    final rdGroup = (datIn & laneMask).named('dat_rd_group');
    final rdFull = ((byteShift << laneCount) | rdGroup.zeroExtend(8))
        .getRange(0, 8)
        .named('dat_rd_full');
    final byteDone = bitsInByte
        .eq(laneCount.zeroExtend(4))
        .named('dat_byte_done');

    // A received word completes on the SD clock that finishes byte 3. This is
    // the RX FIFO's push strobe, and the word it pushes.
    final rxPush =
        (datState.eq(Const(dRead, width: 4)) &
                readEdge &
                byteDone &
                byteInWord.eq(Const(3, width: 2)))
            .named('rx_push');
    final rxWord = [asmB0, asmB1, asmB2, rdFull].rswizzle().named('rx_word');

    // One register access per bus cycle. ACK is a single-cycle pulse, so a
    // master that keeps STB asserted after seeing it would re-enter the handler
    // and run the access a second time - which on a DATA read pops the RX FIFO
    // twice and skips a word. `busServed` holds until STB drops.
    // Only a direct Wishbone port needs this. The AXI4 and TileLink ports and
    // the crossing present each access once, and can keep STB high across two
    // accesses, which this hold would stall forever.
    final busServed = Logic(name: 'bus_served');
    final holdServed =
        bus.kind == HarborFabricKind.wishbone && bus.cdcDepth == 0;
    final busAccess =
        (holdServed ? bus.stb & ~bus.ack & ~busServed : bus.stb & ~bus.ack)
            .named('bus_access');

    // Pop strobes. The ADMA retires its word or words on the WDATA handshake.
    // The CPU retires one by reading DATA during a card read. A walker that
    // has parked during a DMA card read drops the words that are left, so a
    // failed or short transfer cannot stall the SD clock.
    final rxPopAdma = (wFire & ~wPack).named('rx_pop_adma');
    final rxPopAdma2 = (wFire & wPack).named('rx_pop_adma2');
    final rxPopCpu =
        (busAccess &
                ~bus.we &
                cmdDataDir &
                ~rxEmpty &
                bus.windowAddr(0x1000).getRange(3).eq(Const(0x09, width: 9)) &
                bus.selAny(0x48, 4))
            .named('rx_pop_cpu');
    final rxPopDrop =
        (dmaMode &
                cmdDataDir &
                admaState.eq(Const(aIdle, width: 3)) &
                ~wActive &
                ~rxEmpty)
            .named('rx_pop_drop');
    final rxPop = (rxPopAdma | rxPopCpu | rxPopDrop).named('rx_pop');
    // A word is only really taken when the FIFO had one to give.
    final rxPushOk = (rxPush & ~rxFull).named('rx_push_ok');
    // How many words leave the FIFO this cycle. A packed pop is only armed when
    // two words were counted, so the count cannot underflow.
    final rxPop2Ok = (rxPopAdma2 & rxCount.gte(Const(2, width: rxPtrW + 1)))
        .named('rx_pop2_ok');
    final rxPop1Ok = (rxPop & ~rxEmpty & ~rxPop2Ok).named('rx_pop1_ok');
    // Shift-FIFO update helpers (see the sequential RX FIFO block). A pop
    // shifts the whole array down toward index 0 by this many words.
    final rxPopCount = mux(
      rxPop2Ok,
      Const(2, width: rxPtrW + 1),
      mux(rxPop1Ok, Const(1, width: rxPtrW + 1), Const(0, width: rxPtrW + 1)),
    );
    // Tail slot a push writes, after the same-cycle shift has moved it. It
    // equals the new occupancy before the push (count minus popped words).
    final rxTailIdx = (rxCount - rxPopCount).named('rx_tail_idx');
    // Value slot i takes after the shift. Out-of-range shift sources hold the
    // current value; those slots are always past the new valid range, so the
    // held value is unused (a tail insert or the next push overwrites it).
    Logic rxShifted(int i) {
      if (i + 2 < rxDepth) {
        return mux(
          rxPop2Ok,
          rxFifo[i + 2],
          mux(rxPop1Ok, rxFifo[i + 1], rxFifo[i]),
        );
      }
      if (i + 1 < rxDepth) {
        return mux(rxPop1Ok, rxFifo[i + 1], rxFifo[i]);
      }
      return rxFifo[i];
    }

    // Card-read write requests. A request covers only words already in the
    // RX FIFO, so its write data never waits on the card. On a 64-bit port a
    // run at an 8-byte aligned address with at least 8 bytes left uses full
    // beats of two words. Otherwise a beat carries one word in its addressed
    // half.
    final packTarget = dmaDataWidth == 64
        ? (~descAddr[2] & descBytes.gte(Const(8, width: 16))).named(
            'dma_pack_target',
          )
        : Const(0);
    final rxHavePair = rxCount
        .gte(Const(2, width: rxPtrW + 1))
        .named('rx_have_pair');
    final usePack = (packTarget & rxHavePair).named('dma_use_pack');
    // A lone word waits for its partner while the card is still sending.
    final useSingle = (~rxEmpty & (~packTarget | dmaTailWait)).named(
      'dma_use_single',
    );
    // Wait for a batch of words so a request carries a burst. The end of the
    // SD data phase releases the tail.
    final batchWords = dmaWriteBatch > rxDepth ? rxDepth : dmaWriteBatch;
    final dmaBatchReady =
        (rxCount.gte(Const(batchWords, width: rxPtrW + 1)) | dmaTailWait).named(
          'dma_batch_ready',
        );
    final wRoom = wInflight
        .lt(Const(dmaOutstanding, width: ifW))
        .named('dma_w_room');
    final issueWrite =
        (admaState.eq(Const(aMemWrite, width: 3)) &
                descBytes.neq(Const(0, width: 16)) &
                ~wActive &
                ~reqValid &
                wRoom &
                dmaBatchReady &
                (usePack | useSingle))
            .named('dma_issue_write');

    // Beats of the request: the fewest of the burst cap, the words ready, the
    // descriptor bytes left and the beats to the next 4 KB boundary.
    const cw = 17;
    Logic min2(Logic a, Logic b) => mux(a.lt(b), a, b);
    final to4k =
        (Const(4096, width: cw) - descAddr.getRange(0, 12).zeroExtend(cw))
            .named('dma_to_4k');
    final bytesLeft = descBytes.zeroExtend(cw);
    final wordsReady = rxCount.zeroExtend(cw);
    final capBeats = Const(dmaBurstBeats, width: cw);
    final Logic wrBeats;
    final Logic wrBytes;
    if (dmaDataWidth == 32) {
      wrBeats = min2(
        min2(capBeats, wordsReady),
        min2((bytesLeft + Const(3, width: cw)) >> 2, to4k >> 2),
      ).named('dma_wr_beats');
      wrBytes = (wrBeats << 2).named('dma_wr_bytes');
    } else {
      final packBeats = min2(
        min2(capBeats, wordsReady >> 1),
        min2(bytesLeft >> 3, to4k >> 3),
      ).named('dma_pack_beats');
      wrBeats = mux(
        usePack,
        packBeats,
        Const(1, width: cw),
      ).named('dma_wr_beats');
      wrBytes = mux(
        usePack,
        packBeats << 3,
        Const(4, width: cw),
      ).named('dma_wr_bytes');
    }
    final wrLen = (wrBeats - Const(1, width: cw)).getRange(0, 8);
    final bytesAfter = mux(
      bytesLeft.gt(wrBytes),
      bytesLeft - wrBytes,
      Const(0, width: cw),
    ).getRange(0, 16).named('dma_bytes_after');

    // Reads go out only when no write is in flight.
    final fetchAddr =
        (descPtr + mux(fetchHi, Const(4, width: 32), Const(0, width: 32)))
            .named('adma_fetch_addr');
    final readReady = (~rdPending & ~reqValid & ~writesBusy).named(
      'dma_read_ready',
    );
    final issueFetch = (admaState.eq(Const(aFetch, width: 3)) & readReady)
        .named('dma_issue_fetch');
    final issueMemRead =
        (admaState.eq(Const(aMemRead, width: 3)) &
                busy &
                ~dataValid &
                readReady)
            .named('dma_issue_mem_read');

    mw.reqValid <= reqValid;
    mw.reqId <= Const(0, width: mw.config.idWidth);
    mw.reqWrite <= reqWrite;
    mw.reqAddr <=
        (dmaAddressWidth <= 32
            ? reqAddr.getRange(0, dmaAddressWidth)
            : reqAddr.zeroExtend(dmaAddressWidth));
    mw.reqLen <= reqLen;
    mw.reqSize <= reqSize;
    mw.reqBurst <= Const(HarborMemoryBurst.incr.value, width: 2);
    mw.reqExclusive <= Const(0);
    mw.wdataValid <= wActive;
    mw.wdataLast <= wLeft.eq(Const(0, width: 8));
    if (dmaDataWidth == 32) {
      mw.wdataData <= rxHead;
      mw.wdataStrb <= Const(0xF, width: 4);
    } else {
      mw.wdataData <= [mux(wPack, rxHead2, rxHead), rxHead].swizzle();
      mw.wdataStrb <=
          mux(
            wPack,
            Const(0xFF, width: 8),
            mux(wHi, Const(0xF0, width: 8), Const(0x0F, width: 8)),
          );
    }
    mw.rdataReady <= rdPending;
    mw.wrespReady <= writesBusy | (reqValid & reqWrite);

    output('sd_clk') <= sdClkReg & ctrlEnable;
    if (ownPads) {
      // One IOBUF per bidirectional line: drive when the FSM asserts its output
      // enable, otherwise release and read the pad back in.
      final cmdPad = inOut('sd_cmd');
      cmdPad <= TriStateBuffer(cmdOut, enable: cmdOe).out;
      _sdCmdInInt! <= cmdPad;
      // Per-lane IOBUF: lane l drives its pad when datOeReg is set, else reads.
      final datInBits = <Logic>[];
      for (var l = 0; l < maxBusW; l++) {
        final datPad = inOut('sd_dat$l');
        datPad <= TriStateBuffer(datOutReg[l], enable: datOeReg).out;
        datInBits.add(datPad);
      }
      _sdDatInInt! <= datInBits.rswizzle(); // lane 0 = LSB
    } else {
      output('sd_cmd_out') <= cmdOut;
      output('sd_cmd_oe') <= cmdOe;
      output('sd_dat_out') <= datOutReg;
      output('sd_dat_oe') <= datOeReg;
    }
    final intView = (intStatus | (admaErr.zeroExtend(8) << 7)).named(
      'int_view',
    );
    interrupt <= (intView & intEnable).or();

    // Command frame from the value being written to CMD (index + flags) plus
    // the already-latched argument: {0, 1, index[5:0], arg[31:0]} then CRC7 and
    // the end bit, MSB-first.
    final wrIndex = bus.dataIn.getRange(0, 6);
    final cmdContent = [
      Const(0, width: 1),
      Const(1, width: 1),
      wrIndex,
      cmdArg,
    ].swizzle();
    final cmdFrame = [
      cmdContent,
      _crc7(cmdContent),
      Const(1, width: 1),
    ].swizzle();

    // Received response after the in-flight bit is shifted in.
    final respNext = [respShift.getRange(0, 135), cmdIn].swizzle();

    Sequential(clk, [
      If(
        reset,
        then: [
          ctrlEnable < Const(0),
          sampleFall < Const(config.sampleReadOnFall ? 1 : 0),
          clkDiv < Const(124, width: 16), // ~400 kHz from 50 MHz
          cmdIndex < Const(0, width: 6),
          cmdArg < Const(0, width: 32),
          cmdRespType < Const(0, width: 2),
          cmdDataPresent < Const(0),
          cmdDataDir < Const(0),
          for (var i = 0; i < 4; i++) resp[i] < Const(0, width: 32),
          blkSize < Const(512, width: 12),
          blkCount < Const(1, width: 16),
          intStatus < Const(0, width: 8),
          intEnable < Const(0, width: 8),
          busy < Const(0),
          divCount < Const(0, width: 16),
          sdClkReg < Const(0),
          state < Const(sIdle, width: 2),
          cmdShift < Const(0, width: 48),
          cmdCnt < Const(0, width: 7),
          cmdOut < Const(1), // CMD idles high
          cmdOe < Const(0),
          respShift < Const(0, width: 136),
          respCnt < Const(0, width: 8),
          toCnt < Const(0, width: 16),
          datState < Const(dIdle, width: 4),
          for (final c in crc16) c < Const(0, width: 16),
          for (final c in crcShift) c < Const(0, width: 16),
          byteShift < Const(0, width: 8),
          bitsInByte < Const(8, width: 4),
          byteCnt < Const(0, width: 13),
          blockLeft < Const(0, width: 16),
          crcBitCnt < Const(0, width: 5),
          dataReg < Const(0, width: 32),
          dataValid < Const(0),
          rxCount < Const(0, width: rxPtrW + 1),
          for (final w in rxFifo) w < Const(0, width: 32),
          byteInWord < Const(0, width: 2),
          wrNeedFill < Const(0),
          busWidthSel < Const(0, width: 2),
          statShift < Const(0, width: 3),
          statCnt < Const(0, width: 2),
          busySeen < Const(0),
          statWaitCnt < Const(0, width: 16),
          busyCnt < Const(0, width: busyW),
          dmaMode < Const(0),
          admaState < Const(aIdle, width: 3),
          descPtr < Const(0, width: 32),
          descAddr < Const(0, width: 32),
          descBytes < Const(0, width: 16),
          descEnd < Const(0),
          admaBase < Const(0, width: 32),
          fetchHi < Const(0),
          admaErr < Const(0),
          wrAbort < Const(0),
          reqValid < Const(0),
          reqWrite < Const(0),
          reqAddr < Const(0, width: 32),
          reqLen < Const(0, width: 8),
          reqSize < Const(0, width: 3),
          rdPending < Const(0),
          rdHi < Const(0),
          wActive < Const(0),
          wLeft < Const(0, width: 8),
          wPack < Const(0),
          wHi < Const(0),
          wInflight < Const(0, width: ifW),
          dmaTailWait < Const(0),
          asmB0 < Const(0, width: 8),
          asmB1 < Const(0, width: 8),
          asmB2 < Const(0, width: 8),
          datOutReg < Const(0, width: maxW),
          datOeReg < Const(0),
          bus.ack < Const(0),
          busServed < Const(0),
          bus.dataOut < Const(0, width: dw),
        ],
        orElse: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: dw),

          // SD clock divider. Frozen while datStall holds, so the clock stays
          // low and the card pauses until the ADMA drains the pending read word
          // or refills the pending write word.
          If(
            ctrlEnable & ~datStall,
            then: [
              If(
                divCount.eq(Const(0, width: 16)),
                then: [divCount < clkDiv, sdClkReg < ~sdClkReg],
                orElse: [divCount < (divCount - Const(1, width: 16))],
              ),
            ],
          ),

          // CMD engine.
          Case(state, [
            // Serialize the command, MSB-first, one bit per SD falling edge.
            CaseItem(Const(sSend, width: 2), [
              If(
                sdFall,
                then: [
                  cmdOut < cmdShift[47],
                  cmdShift < [cmdShift.getRange(0, 47), Const(0)].swizzle(),
                  cmdCnt < (cmdCnt - Const(1, width: 7)),
                  If(
                    cmdCnt.eq(Const(1, width: 7)),
                    then: [
                      If(
                        cmdRespType.eq(Const(0, width: 2)),
                        // No response expected: command done, release the line.
                        then: [
                          state < Const(sIdle, width: 2),
                          busy < Const(0),
                          cmdOe < Const(0),
                          intStatus < (intStatus | Const(intCmdDone, width: 8)),
                        ],
                        // Wait for the card to drive the response.
                        orElse: [
                          state < Const(sWait, width: 2),
                          cmdOe < Const(0),
                          toCnt < Const(0, width: 16),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            // Hunt for the response start bit, with an NCR timeout.
            CaseItem(Const(sWait, width: 2), [
              If(
                sdRise,
                then: [
                  If(
                    ~cmdIn,
                    then: [
                      state < Const(sRecv, width: 2),
                      respShift < Const(0, width: 136),
                      respCnt <
                          mux(
                            cmdRespType.eq(Const(2, width: 2)),
                            Const(
                              135,
                              width: 8,
                            ), // R2 long response (136-bit frame)
                            Const(47, width: 8), // short 48-bit frame
                          ),
                    ],
                    orElse: [
                      toCnt < (toCnt + Const(1, width: 16)),
                      If(
                        toCnt.eq(Const(respTimeout, width: 16)),
                        then: [
                          state < Const(sIdle, width: 2),
                          busy < Const(0),
                          intStatus <
                              (intStatus | Const(intCmdTimeout, width: 8)),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            // Shift the response in on rising edges, capture on the last bit.
            CaseItem(Const(sRecv, width: 2), [
              If(
                sdRise,
                then: [
                  respShift < respNext,
                  respCnt < (respCnt - Const(1, width: 8)),
                  If(
                    respCnt.eq(Const(1, width: 8)),
                    then: [
                      state < Const(sIdle, width: 2),
                      intStatus < (intStatus | Const(intCmdDone, width: 8)),
                      // Hand off to the data engine when the command carries a
                      // data phase, otherwise the command is done.
                      If(
                        cmdDataPresent,
                        then: [
                          byteCnt < blkSize.zeroExtend(13),
                          blockLeft < blkCount,
                          for (final c in crc16) c < Const(0, width: 16),
                          bitsInByte < Const(8, width: 4),
                          byteInWord < Const(0, width: 2),
                          If(
                            cmdDataDir,
                            then: [datState < Const(dRWait, width: 4)],
                            orElse: [datState < Const(dWStart, width: 4)],
                          ),
                        ],
                        orElse: [busy < Const(0)],
                      ),
                      // The ADMA descriptor fetch is kicked off at command issue
                      // (see the CMD write handler), not here, so the engine is
                      // already parked in its memory state before the first data
                      // word and no startup words are dropped.
                      // R2: low 128 bits of the 136-bit frame into RESP0-3.
                      // Short: the 32-bit payload (frame bits [39:8]) into RESP0.
                      If(
                        cmdRespType.eq(Const(2, width: 2)),
                        then: [
                          resp[0] < respNext.getRange(0, 32),
                          resp[1] < respNext.getRange(32, 64),
                          resp[2] < respNext.getRange(64, 96),
                          resp[3] < respNext.getRange(96, 128),
                        ],
                        orElse: [
                          resp[0] < respNext.getRange(8, 40),
                          resp[1] < Const(0, width: 32),
                          resp[2] < Const(0, width: 32),
                          resp[3] < Const(0, width: 32),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
          ]),

          // DAT engine (1/4/8-bit PIO). Each SD clock moves [laneCount] bits,
          // one per active lane, MSB group first, each lane has its own CRC16.
          () {
            final bitsNext = mux(
              byteDone,
              Const(8, width: 4),
              bitsInByte - laneCount.zeroExtend(4),
            );
            // Write: the group driven this clock (top [laneCount] bits of the
            // byte), aligned so lane 0 is the lowest of the group.
            final wrShift = Const(8, width: 4) - laneCount.zeroExtend(4);
            final wrGroup = (byteShift >> wrShift).getRange(0, maxW) & laneMask;
            // Next CRC16 per lane, for the bit that lane carries this clock.
            final crcNextRd = [
              for (var l = 0; l < maxW; l++)
                mux(laneMask[l], _crc16Next(crc16[l], datIn[l]), crc16[l]),
            ];
            final crcNextWr = [
              for (var l = 0; l < maxW; l++)
                mux(laneMask[l], _crc16Next(crc16[l], wrGroup[l]), crc16[l]),
            ];
            // Read CRC shift-in (value after this clock) and the CRC drive vec.
            final rxCrcNext = [
              for (var l = 0; l < maxW; l++)
                [crcShift[l].getRange(0, 15), datIn[l]].swizzle(),
            ];
            final crcOutVec =
                [for (var l = 0; l < maxW; l++) crcShift[l][15]].rswizzle() &
                laneMask;
            // Read CRC mismatch on any active lane.
            var crcBad = Const(0) as Logic;
            for (var l = 0; l < maxW; l++) {
              crcBad = crcBad | (laneMask[l] & crc16[l].neq(rxCrcNext[l]));
            }
            // Next data byte for write (within the current word).
            final nextByte = mux(
              byteInWord.eq(Const(0, width: 2)),
              dataReg.getRange(8, 16),
              mux(
                byteInWord.eq(Const(1, width: 2)),
                dataReg.getRange(16, 24),
                dataReg.getRange(24, 32),
              ),
            );

            return Case(datState, [
              // READ: hunt for the block start bit (0) on DAT0.
              CaseItem(Const(dRWait, width: 4), [
                If(
                  readEdge & ~datIn[0],
                  then: [
                    datState < Const(dRead, width: 4),
                    bitsInByte < Const(8, width: 4),
                    byteShift < Const(0, width: 8),
                  ],
                ),
              ]),
              // READ data, [laneCount] bits per clock, CRC16 per lane.
              CaseItem(Const(dRead, width: 4), [
                If(
                  readEdge,
                  then: [
                    byteShift < mux(byteDone, Const(0, width: 8), rdFull),
                    bitsInByte < bitsNext,
                    for (var l = 0; l < maxW; l++) crc16[l] < crcNextRd[l],
                    If(
                      byteDone,
                      then: [
                        // Assemble the byte into the word, byte 0 in the low lane.
                        Case(byteInWord, [
                          CaseItem(Const(0, width: 2), [asmB0 < rdFull]),
                          CaseItem(Const(1, width: 2), [asmB1 < rdFull]),
                          CaseItem(Const(2, width: 2), [asmB2 < rdFull]),
                          // Byte 3 completes a word. The word itself is pushed
                          // into the RX FIFO by the block below, off `rxPush`.
                          CaseItem(Const(3, width: 2), [
                            intStatus <
                                (intStatus | Const(intDataReq, width: 8)),
                          ]),
                        ]),
                        byteInWord < (byteInWord + Const(1, width: 2)),
                        byteCnt < (byteCnt - Const(1, width: 13)),
                        If(
                          byteCnt.eq(Const(1, width: 13)),
                          then: [
                            datState < Const(dRCrc, width: 4),
                            crcBitCnt < Const(16, width: 5),
                            for (final c in crcShift) c < Const(0, width: 16),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ]),
              // READ the per-lane 16-bit CRC and compare.
              CaseItem(Const(dRCrc, width: 4), [
                If(
                  readEdge,
                  then: [
                    for (var l = 0; l < maxW; l++) crcShift[l] < rxCrcNext[l],
                    crcBitCnt < (crcBitCnt - Const(1, width: 5)),
                    If(
                      crcBitCnt.eq(Const(1, width: 5)),
                      then: [
                        // Latch CRC-error and (on the final block) data-done in
                        // ONE intStatus write. Two separate `intStatus < ...`
                        // assignments race under last-write-wins, so a CRC error
                        // on the final block was silently dropped by the later
                        // data-done write.
                        intStatus <
                            (intStatus |
                                mux(
                                  crcBad,
                                  Const(intDataCrcErr, width: 8),
                                  Const(0, width: 8),
                                ) |
                                mux(
                                  blockLeft.eq(Const(1, width: 16)) & ~dmaMode,
                                  Const(intDataDone, width: 8),
                                  Const(0, width: 8),
                                )),
                        If(
                          blockLeft.eq(Const(1, width: 16)),
                          then: [
                            datState < Const(dIdle, width: 4),
                            // On a DMA read the transfer ends when the ADMA has
                            // landed the last buffered word, not here.
                            If(
                              dmaMode,
                              then: [dmaTailWait < Const(1)],
                              orElse: [busy < Const(0)],
                            ),
                          ],
                          orElse: [
                            blockLeft < (blockLeft - Const(1, width: 16)),
                            byteCnt < blkSize.zeroExtend(13),
                            for (final c in crc16) c < Const(0, width: 16),
                            byteInWord < Const(0, width: 2),
                            datState < Const(dRWait, width: 4),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ]),
              // WRITE: drive the start bit once the CPU has provided data.
              CaseItem(Const(dWStart, width: 4), [
                If(
                  sdFall & dataValid,
                  then: [
                    datOeReg < Const(1),
                    datOutReg <
                        Const(0, width: maxW), // start bit (all lanes 0)
                    byteShift < dataReg.getRange(0, 8),
                    bitsInByte < Const(8, width: 4),
                    byteInWord < Const(0, width: 2),
                    wrNeedFill < Const(0),
                    datState < Const(dWrite, width: 4),
                  ],
                ),
              ]),
              // WRITE data, [laneCount] bits per clock, CRC16 per lane.
              CaseItem(Const(dWrite, width: 4), [
                If(
                  sdFall,
                  then: [
                    datOutReg < wrGroup,
                    for (var l = 0; l < maxW; l++) crc16[l] < crcNextWr[l],
                    byteShift < (byteShift << laneCount).getRange(0, 8),
                    bitsInByte < bitsNext,
                    If(
                      byteDone,
                      then: [
                        byteCnt < (byteCnt - Const(1, width: 13)),
                        byteInWord < (byteInWord + Const(1, width: 2)),
                        If(
                          byteCnt.eq(Const(1, width: 13)),
                          then: [
                            // Last data byte: send the finished CRC next. Release
                            // the holding register too, so a multi-block write
                            // starts its next block on a freshly supplied word
                            // instead of replaying this block's last one.
                            for (var l = 0; l < maxW; l++)
                              crcShift[l] < crcNextWr[l],
                            crcBitCnt < Const(16, width: 5),
                            dataValid < Const(0),
                            intStatus <
                                (intStatus | Const(intDataReq, width: 8)),
                            datState < Const(dWCrc, width: 4),
                          ],
                          orElse: [
                            If(
                              byteInWord.eq(Const(3, width: 2)),
                              // Word exhausted. Release it and ask for the next.
                              // `nextByte` cannot serve here: it reads the word
                              // being retired, so loading it replayed byte 3.
                              // Raise wrNeedFill instead, which freezes the SD
                              // clock until the refill below lands.
                              then: [
                                dataValid < Const(0),
                                wrNeedFill < Const(1),
                                intStatus <
                                    (intStatus | Const(intDataReq, width: 8)),
                              ],
                              orElse: [byteShift < nextByte],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
                // Refill from the next word, on the system clock rather than an
                // SD edge: the clock is frozen while wrNeedFill holds, so this
                // costs no bit time and the DAT stream has no gap.
                If(
                  wrNeedFill & dataValid,
                  then: [
                    byteShift < dataReg.getRange(0, 8),
                    bitsInByte < Const(8, width: 4),
                    wrNeedFill < Const(0),
                  ],
                ),
              ]),
              // WRITE the per-lane 16-bit CRC, MSB-first.
              CaseItem(Const(dWCrc, width: 4), [
                If(
                  sdFall,
                  then: [
                    datOutReg < mux(wrAbort, ~crcOutVec & laneMask, crcOutVec),
                    for (var l = 0; l < maxW; l++)
                      crcShift[l] <
                          [crcShift[l].getRange(0, 15), Const(0)].swizzle(),
                    crcBitCnt < (crcBitCnt - Const(1, width: 5)),
                    If(
                      crcBitCnt.eq(Const(1, width: 5)),
                      then: [datState < Const(dWEnd, width: 4)],
                    ),
                  ],
                ),
              ]),
              // WRITE the end bit, then release the line for the card's
              // CRC-status token.
              CaseItem(Const(dWEnd, width: 4), [
                If(
                  sdFall,
                  then: [
                    datOutReg < laneMask, // end bit (1 on active lanes)
                    datOeReg < Const(0),
                    datState < Const(dWStatWait, width: 4),
                    statWaitCnt < Const(0, width: 16),
                  ],
                ),
              ]),
              // WRITE: hunt for the CRC status token start bit on DAT0.
              CaseItem(Const(dWStatWait, width: 4), [
                If(
                  sdRise,
                  then: [
                    If(
                      ~datIn[0],
                      then: [
                        datState < Const(dWStat, width: 4),
                        statShift < Const(0, width: 3),
                        statCnt < Const(3, width: 2),
                      ],
                      orElse: [
                        statWaitCnt < (statWaitCnt + Const(1, width: 16)),
                        If(
                          statWaitCnt.eq(Const(respTimeout, width: 16)),
                          then: [
                            // No token: treat as a write error and finish.
                            datState < Const(dIdle, width: 4),
                            busy < Const(0),
                            intStatus <
                                (intStatus |
                                    Const(intWriteErr | intDataDone, width: 8)),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ]),
              // WRITE: capture the 3-bit CRC status (010 == accepted).
              CaseItem(Const(dWStat, width: 4), [
                If(
                  sdRise,
                  then: [
                    statShift < [statShift.getRange(0, 2), datIn[0]].swizzle(),
                    statCnt < (statCnt - Const(1, width: 2)),
                    If(
                      statCnt.eq(Const(1, width: 2)),
                      then: [
                        // A rejected block has no busy, so the transfer
                        // ends here.
                        If(
                          [
                            statShift.getRange(0, 2),
                            datIn[0],
                          ].swizzle().neq(Const(0x2, width: 3)),
                          then: [
                            datState < Const(dIdle, width: 4),
                            busy < Const(0),
                            intStatus <
                                (intStatus |
                                    Const(intWriteErr | intDataDone, width: 8)),
                          ],
                          orElse: [datState < Const(dWBusy, width: 4)],
                        ),
                        busySeen < Const(0),
                        busyCnt < Const(0, width: busyW),
                      ],
                    ),
                  ],
                ),
              ]),
              // WRITE: wait out programming. The card pulls DAT0 low (busy),
              // then releases it high when done.
              CaseItem(Const(dWBusy, width: 4), [
                If(
                  sdRise,
                  then: [
                    If(~datIn[0], then: [busySeen < Const(1)]),
                    busyCnt < (busyCnt + Const(1, width: busyW)),
                    If(
                      busyCnt.eq(Const(writeBusyTimeout, width: busyW)),
                      then: [
                        datState < Const(dIdle, width: 4),
                        busy < Const(0),
                        intStatus <
                            (intStatus |
                                Const(intWriteErr | intDataDone, width: 8)),
                      ],
                    ),
                    If(
                      busySeen & datIn[0],
                      then: [
                        If(
                          blockLeft.eq(Const(1, width: 16)),
                          then: [
                            datState < Const(dIdle, width: 4),
                            busy < Const(0),
                            intStatus <
                                (intStatus | Const(intDataDone, width: 8)),
                          ],
                          orElse: [
                            blockLeft < (blockLeft - Const(1, width: 16)),
                            byteCnt < blkSize.zeroExtend(13),
                            for (final c in crc16) c < Const(0, width: 16),
                            byteInWord < Const(0, width: 2),
                            datState < Const(dWStart, width: 4),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ]),
            ]);
          }(),

          // RX FIFO update, shift-FIFO discipline. Push and pop can land in the
          // same cycle, so the count moves by the net of the two and both the
          // shift and the tail insert must compose.
          //
          // On a pop the whole array shifts down toward index 0 by the number
          // of words retired (1 or 2). The head therefore stays at index 0 and
          // the four reads above need no muxes. On a push the new word goes at
          // the tail, which the same-cycle shift has already moved to index
          // (count - popped). That slot holds a word that is beyond the old
          // valid range, so the tail insert overwrites it with no conflict.
          //
          // The push is GATED on the FIFO having room. An ungated push past the
          // last slot would overwrite an entry nobody has read yet, so the
          // transfer would return a mix of old and new words - a read that is
          // not byte-stable. It also broke the full flag itself:
          // `rx_fifo_count` is wide enough to hold depth+1, so one overflow
          // made `rx_full` compare false again and released the clock stall,
          // letting the corruption run away. Drop the word and say so instead.
          for (var i = 0; i < rxDepth; i++)
            rxFifo[i] <
                mux(
                  rxPushOk & rxTailIdx.eq(Const(i, width: rxPtrW + 1)),
                  rxWord,
                  rxShifted(i),
                ),
          If(
            rxPush & rxFull & ~rxPop,
            then: [intStatus < (intStatus | Const(intRxOverrun, width: 8))],
          ),
          // count' = count + (1 if pushed) - (words popped)
          rxCount <
              (rxCount +
                  mux(
                    rxPushOk,
                    Const(1, width: rxPtrW + 1),
                    Const(0, width: rxPtrW + 1),
                  ) -
                  mux(
                    rxPop2Ok,
                    Const(2, width: rxPtrW + 1),
                    mux(
                      rxPop1Ok,
                      Const(1, width: rxPtrW + 1),
                      Const(0, width: rxPtrW + 1),
                    ),
                  )),

          // ADMA channels. A request holds until REQ_READY, and the write data
          // of the request last sent runs on its own until LAST.
          If(reqFire, then: [reqValid < Const(0)]),
          If(rFire, then: [rdPending < Const(0)]),
          If(
            wFire,
            then: [
              If(
                wLeft.eq(Const(0, width: 8)),
                then: [wActive < Const(0)],
                orElse: [wLeft < (wLeft - Const(1, width: 8))],
              ),
            ],
          ),
          wInflight <
              (wInflight + issueWrite.zeroExtend(ifW) - bFire.zeroExtend(ifW)),
          If(dmaFault, then: [admaErr < Const(1)]),
          If(dmaFault & dmaMode & ~cmdDataDir, then: [wrAbort < Const(1)]),

          // A DMA read completes when the walker has parked, the RX FIFO is
          // empty and every write response is back, so every received word
          // is in memory.
          If(
            dmaTailWait &
                admaState.eq(Const(aIdle, width: 3)) &
                rxEmpty &
                ~dmaInFlight,
            then: [
              dmaTailWait < Const(0),
              busy < Const(0),
              intStatus < (intStatus | Const(intDataDone, width: 8)),
            ],
          ),

          // ADMA walker. cmdDataDir 1 is a card read (words go to memory), 0
          // is a card write (words come from memory).
          Case(admaState, [
            CaseItem(Const(aFetch, width: 3), [
              If(
                issueFetch,
                then: [
                  reqValid < Const(1),
                  reqWrite < Const(0),
                  reqAddr < fetchAddr,
                  reqLen < Const(0, width: 8),
                  reqSize < Const(2, width: 3),
                  rdPending < Const(1),
                  rdHi < fetchAddr[2],
                ],
              ),
              If(
                rFire & ~mw.rdataErr,
                then: [
                  If(
                    fetchHi,
                    then: [
                      descBytes < rdWord.getRange(0, 16),
                      descEnd < rdWord[31],
                      fetchHi < Const(0),
                      admaState < Const(aNext, width: 3),
                    ],
                    orElse: [descAddr < rdWord, fetchHi < Const(1)],
                  ),
                ],
              ),
            ]),
            // Card write: read a word into the DAT buffer when it is free.
            CaseItem(Const(aMemRead, width: 3), [
              If(
                issueMemRead,
                then: [
                  reqValid < Const(1),
                  reqWrite < Const(0),
                  reqAddr < descAddr,
                  reqLen < Const(0, width: 8),
                  reqSize < Const(2, width: 3),
                  rdPending < Const(1),
                  rdHi < descAddr[2],
                ],
              ),
              If(
                rFire & ~mw.rdataErr,
                then: [
                  dataReg < rdWord,
                  dataValid < Const(1),
                  descAddr < (descAddr + Const(4, width: 32)),
                  descBytes <
                      mux(
                        descBytes.gt(Const(4, width: 16)),
                        descBytes - Const(4, width: 16),
                        Const(0, width: 16),
                      ),
                  admaState < Const(aNext, width: 3),
                ],
              ),
              // The card write ended before the descriptors did. A word
              // fetched for it is dropped.
              If(
                ~busy & ~rdPending,
                then: [
                  admaState < Const(aIdle, width: 3),
                  dataValid < Const(0),
                ],
              ),
            ]),
            // Card read: send the FIFO words as a write burst.
            CaseItem(Const(aMemWrite, width: 3), [
              If(
                issueWrite,
                then: [
                  reqValid < Const(1),
                  reqWrite < Const(1),
                  reqAddr < descAddr,
                  reqLen < wrLen,
                  reqSize <
                      mux(usePack, Const(3, width: 3), Const(2, width: 3)),
                  wActive < Const(1),
                  wLeft < wrLen,
                  wPack < usePack,
                  wHi < descAddr[2],
                  descAddr < (descAddr + wrBytes.zeroExtend(32)),
                  descBytes < bytesAfter,
                  If(
                    bytesAfter.eq(Const(0, width: 16)),
                    then: [admaState < Const(aNext, width: 3)],
                  ),
                ],
                // The card has finished and no word is left.
                orElse: [
                  If(
                    dmaTailWait & rxEmpty,
                    then: [admaState < Const(aIdle, width: 3)],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(aNext, width: 3), [
              If(
                descBytes.eq(Const(0, width: 16)),
                then: [
                  If(
                    descEnd,
                    then: [admaState < Const(aIdle, width: 3)],
                    orElse: [
                      descPtr < (descPtr + Const(8, width: 32)),
                      fetchHi < Const(0),
                      admaState < Const(aFetch, width: 3),
                    ],
                  ),
                ],
                orElse: [
                  If(
                    cmdDataDir,
                    then: [admaState < Const(aMemWrite, width: 3)],
                    orElse: [admaState < Const(aMemRead, width: 3)],
                  ),
                ],
              ),
            ]),
          ]),
          // An error response stops the walker. Writes already sent finish.
          If(dmaFault, then: [admaState < Const(aIdle, width: 3)]),
          // A parked walker in a DMA card write feeds zero words, so the
          // serializer reaches the end of the block count.
          If(
            dmaMode &
                ~cmdDataDir &
                admaState.eq(Const(aIdle, width: 3)) &
                ~dataValid &
                (datState.eq(Const(dWStart, width: 4)) |
                    (datState.eq(Const(dWrite, width: 4)) & wrNeedFill)),
            then: [dataReg < Const(0, width: 32), dataValid < Const(1)],
          ),

          // Bus access.
          If(~bus.stb, then: [busServed < Const(0)]),
          If(
            busAccess,
            then: [
              busServed < Const(1),
              bus.ack < Const(1),

              // Each register sits in its own 8-byte slot (byte offset >> 3),
              // matching every other Harbor peripheral on the byte-addressed
              // fabric. The documented byte offsets 0x00,0x08,0x10,... map to
              // indices 0,1,2. Decode every address bit of the 0x1000 window
              // and ignore the bits above it, so absolute and relative
              // addresses both work. An unused offset reads 0 and ignores
              // writes.
              Case(bus.windowAddr(0x1000).getRange(3), [
                // 0x00: CTRL ([0] enable, [5:4] reports max bus width,
                // [8] read-data sample edge 0:rising 1:falling).
                CaseItem(Const(0x00, width: 9), [
                  If(
                    bus.we,
                    then: [
                      // [0] enable and [5:4] bus width live in byte 0; [8] the
                      // sample edge lives in byte 1. A store that selects only
                      // one of the two bytes must leave the other alone.
                      If(
                        bus.selAny(0x00, 1),
                        then: [
                          ctrlEnable < bus.dataIn[0],
                          // [5:4] selects the active bus width (0:1-bit,
                          // 1:4-bit, 2:8-bit), clamped to the configured
                          // maximum.
                          busWidthSel < bus.dataIn.getRange(4, 6),
                        ],
                      ),
                      // [8] picks the read-data sample edge. Firmware raises it
                      // to sample the read DAT on the falling edge for
                      // round-trip margin at speed.
                      If(
                        bus.selAny(0x01, 1),
                        then: [sampleFall < bus.dataIn[8]],
                      ),
                    ],
                    orElse: [
                      bus.dataOut <
                          ctrlEnable.zeroExtend(dw) |
                              (busWidthSel.zeroExtend(dw) <<
                                  Const(4, width: 32)) |
                              (sampleFall.zeroExtend(dw) <<
                                  Const(8, width: 32)),
                    ],
                  ),
                ]),
                // 0x08: STATUS ([0] card detect, [8] busy, [9] data ready).
                // Busy includes ADMA accesses in flight, which also block
                // a CMD write.
                CaseItem(Const(0x01, width: 9), [
                  bus.dataOut <
                      cardDetect.zeroExtend(dw) |
                          ((busy | dmaInFlight).zeroExtend(dw) <<
                              Const(8, width: 32)) |
                          (mux(
                                cmdDataDir,
                                ~rxEmpty,
                                dataValid,
                              ).zeroExtend(dw) <<
                              Const(9, width: 32)),
                ]),
                // 0x10: CLK_DIV.
                CaseItem(Const(0x02, width: 9), [
                  If(
                    bus.we,
                    then: [clkDiv < bus.selMerge(clkDiv, 0x10)],
                    orElse: [bus.dataOut < clkDiv.zeroExtend(dw)],
                  ),
                ]),
                // 0x18: CMD. Writing triggers a command when not busy and the
                // ADMA has nothing in flight. [5:0] index, [7:6] response
                // type (0 none, 1 short, 2 long R2, 3 short+busy), [8] data
                // present, [9] data direction (0 write, 1 read), [10] use
                // ADMA DMA, [11] ADMA_ADDR is a descriptor table.
                CaseItem(Const(0x03, width: 9), [
                  If(
                    bus.we & bus.selAny(0x18, 2),
                    then: [
                      If(
                        ~busy & ~dmaInFlight,
                        then: [
                          cmdIndex < wrIndex,
                          cmdRespType < bus.dataIn.getRange(6, 8),
                          cmdDataPresent < bus.dataIn[8],
                          cmdDataDir < bus.dataIn[9],
                          wrAbort < Const(0),
                          dmaMode < bus.dataIn[10],
                          cmdShift < cmdFrame,
                          cmdCnt < Const(48, width: 7),
                          cmdOut < Const(1),
                          cmdOe < Const(1),
                          busy < Const(1),
                          state < Const(sSend, width: 2),
                          // Start every data phase with an empty RX FIFO, so
                          // a word left by an earlier transfer cannot shift
                          // the new block.
                          If(
                            bus.dataIn[8],
                            then: [rxCount < Const(0, width: rxPtrW + 1)],
                          ),
                          // Start the ADMA at command issue, so its first
                          // memory access overlaps the command and response.
                          If(
                            bus.dataIn[10] & bus.dataIn[8],
                            then: [
                              fetchHi < Const(0),
                              If(
                                bus.dataIn[11],
                                then: [
                                  descPtr < admaBase,
                                  admaState < Const(aFetch, width: 3),
                                ],
                                // One buffer: ADMA_ADDR is its address and
                                // BLK_COUNT * BLK_SIZE its length.
                                orElse: [
                                  descAddr < admaBase,
                                  descBytes <
                                      (blkCount * blkSize.zeroExtend(16))
                                          .getRange(0, 16),
                                  descEnd < Const(1),
                                  If(
                                    bus.dataIn[9],
                                    then: [
                                      admaState < Const(aMemWrite, width: 3),
                                    ],
                                    orElse: [
                                      admaState < Const(aMemRead, width: 3),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                    orElse: [
                      bus.dataOut <
                          cmdIndex.zeroExtend(dw) |
                              (cmdRespType.zeroExtend(dw) <<
                                  Const(6, width: 32)),
                    ],
                  ),
                ]),
                // 0x20: CMD_ARG.
                CaseItem(Const(0x04, width: 9), [
                  If(
                    bus.we,
                    then: [cmdArg < bus.selMerge(cmdArg, 0x20)],
                    orElse: [bus.dataOut < cmdArg.zeroExtend(dw)],
                  ),
                ]),
                // 0x28-0x40: RESP0-3.
                for (var i = 0; i < 4; i++)
                  CaseItem(Const(0x05 + i, width: 9), [
                    bus.dataOut < resp[i].zeroExtend(dw),
                  ]),
                // 0x48: DATA. One-word PIO buffer. CPU writes fill it (for a
                // write transfer), reads drain it (for a read transfer).
                CaseItem(Const(0x09, width: 9), [
                  If(
                    bus.we & bus.selAny(0x48, 4),
                    then: [
                      dataReg < bus.selMerge(dataReg, 0x48),
                      dataValid < Const(1),
                    ],
                    // A card read pops the RX FIFO (see `rxPopCpu`); a card write
                    // reads back the holding register.
                    orElse: [
                      bus.dataOut <
                          mux(cmdDataDir, rxHead, dataReg).zeroExtend(dw),
                    ],
                  ),
                ]),
                // 0x50: BLK_SIZE.
                CaseItem(Const(0x0A, width: 9), [
                  If(
                    bus.we,
                    then: [blkSize < bus.selMerge(blkSize, 0x50)],
                    orElse: [bus.dataOut < blkSize.zeroExtend(dw)],
                  ),
                ]),
                // 0x58: BLK_COUNT.
                CaseItem(Const(0x0B, width: 9), [
                  If(
                    bus.we,
                    then: [blkCount < bus.selMerge(blkCount, 0x58)],
                    orElse: [bus.dataOut < blkCount.zeroExtend(dw)],
                  ),
                ]),
                // 0x60: INT_STATUS (write-1-to-clear).
                CaseItem(Const(0x0C, width: 9), [
                  If(
                    bus.we,
                    then: [
                      intStatus < (intStatus & ~bus.selMasked(0x60, 8)),
                      admaErr <
                          ((admaErr | dmaFault) & ~bus.selMasked(0x60, 8)[7]),
                    ],
                    orElse: [bus.dataOut < intView.zeroExtend(dw)],
                  ),
                ]),
                // 0x68: INT_ENABLE.
                CaseItem(Const(0x0D, width: 9), [
                  If(
                    bus.we,
                    then: [intEnable < bus.selMerge(intEnable, 0x68)],
                    orElse: [bus.dataOut < intEnable.zeroExtend(dw)],
                  ),
                ]),
                // 0x70: ADMA_ADDR (descriptor table base for DMA transfers).
                CaseItem(Const(0x0E, width: 9), [
                  If(
                    bus.we,
                    then: [admaBase < bus.selMerge(admaBase, 0x70)],
                    orElse: [bus.dataOut < admaBase.zeroExtend(dw)],
                  ),
                ]),
              ]),
            ],
          ),
        ],
      ),
    ]);
  }

  /// Bit-serial SD CRC7 (polynomial x^7 + x^3 + 1) over [data], which is
  /// presented MSB-first. Returns the 7-bit CRC, MSB-first.
  Logic _crc7(Logic data) {
    var c = List<Logic>.generate(7, (_) => Const(0)); // c[0] = LSB
    for (var i = data.width - 1; i >= 0; i--) {
      final inv = data[i] ^ c[6];
      c = [inv, c[0], c[1], c[2] ^ inv, c[3], c[4], c[5]];
    }
    return [c[6], c[5], c[4], c[3], c[2], c[1], c[0]].swizzle();
  }

  /// One step of the SD data CRC16 (CCITT, x^16 + x^12 + x^5 + 1) over [bit].
  /// Returns the next 16-bit CRC, seed with zero at the start of each block.
  Logic _crc16Next(Logic crc, Logic bit) {
    final inv = bit ^ crc[15];
    final next = <Logic>[
      for (var i = 0; i < 16; i++)
        if (i == 0)
          inv
        else if (i == 5)
          crc[4] ^ inv
        else if (i == 12)
          crc[11] ^ inv
        else
          crc[i - 1],
    ];
    return next.rswizzle(); // next[0] is the LSB
  }

  /// Whether the read path is conditioned with UHS IO primitives: a target is
  /// set and the config supports SDR50 or faster.
  bool get _uhsTuned =>
      target is HarborFpgaTarget &&
      config.maxSpeed.index >= HarborSdioSpeed.sdr50.index;

  /// Whether the config is a double-data-rate UHS mode (DDR50 / HS400).
  bool get _uhsDdr =>
      config.maxSpeed == HarborSdioSpeed.ddr50 ||
      config.maxSpeed == HarborSdioSpeed.hs400;

  /// Conditions one input bit with the per-vendor UHS IO primitives: a static
  /// input delay for SDR50/SDR104 sampling, then DDR capture when [ddr]. This
  /// is structural and NOT board-calibrated (placeholder tap values, rising
  /// half only), real bring-up tunes the tap via CMD19 and adds the
  /// falling-edge datapath. Lattice iCE40 has no UHS-class primitive, so it
  /// passes through.
  Logic _uhsConditionBit(Logic raw, String tag, {required bool ddr}) {
    final fpga = target as HarborFpgaTarget;
    final Logic delayed;
    switch (fpga.vendor) {
      case HarborFpgaVendor.vivado:
      case HarborFpgaVendor.openXc7:
        delayed = XilinxIdelaye2(
          idatain: raw,
          idelayValue: 8,
          name: 'sd_idelay_$tag',
        ).dataout;
      case HarborFpgaVendor.ecp5:
        delayed = Ecp5Delayg(a: raw, delValue: 40, name: 'sd_delay_$tag').z;
      case HarborFpgaVendor.ice40:
        delayed = raw;
    }
    if (!ddr) return delayed;
    switch (fpga.vendor) {
      case HarborFpgaVendor.vivado:
      case HarborFpgaVendor.openXc7:
        return XilinxIddr(c: input('clk'), d: delayed, name: 'sd_iddr_$tag').q1;
      case HarborFpgaVendor.ecp5:
        return Ecp5Iddrx1f(
          sclk: input('clk'),
          rst: bus.reset,
          d: delayed,
          name: 'sd_iddr_$tag',
        ).q0;
      case HarborFpgaVendor.ice40:
        return delayed;
    }
  }

  @override
  int get inputClockHz => clockFrequency;

  @override
  void provideInputClockHz(int hz) {
    if (clockFrequency == 0) clockFrequency = hz;
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: config.supportsEmmc ? ['harbor,sdhci-emmc'] : ['harbor,sdhci'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      'bus-width': config.maxBusWidth.width,
      'max-frequency': config.maxFrequency,
      if (clockFrequency > 0) 'clock-frequency': clockFrequency,
      if (config.supports1v8) 'sd-uhs-sdr12': true,
      if (config.supports1v8) 'sd-uhs-sdr25': true,
      if (config.maxSpeed.index >= HarborSdioSpeed.sdr50.index)
        'sd-uhs-sdr50': true,
      if (config.maxSpeed.index >= HarborSdioSpeed.sdr104.index)
        'sd-uhs-sdr104': true,
      if (config.supportsEmmc) 'non-removable': true,
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': config.supportsEmmc
          ? ['harbor,sdhci-emmc']
          : ['harbor,sdhci'],
      'bus-width': config.maxBusWidth.width,
      'max-frequency': config.maxFrequency,
      if (clockFrequency > 0) 'clock-frequency': clockFrequency,
      if (config.supports1v8) 'sd-uhs-sdr12': true,
      if (config.supports1v8) 'sd-uhs-sdr25': true,
      if (config.maxSpeed.index >= HarborSdioSpeed.sdr50.index)
        'sd-uhs-sdr50': true,
      if (config.maxSpeed.index >= HarborSdioSpeed.sdr104.index)
        'sd-uhs-sdr104': true,
      if (config.supportsEmmc) 'non-removable': true,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'SDIO',
    groupName: 'SDIO',
    description: 'SD SDIO and eMMC host controller',
    baseAddress: baseAddress,
    size: 0x1000,
  );

  @override
  List<HarborSimModel> simModels(HarborSimModelContext ctx) {
    // Only when the split (ownPads=false) ports are exposed at the top level -
    // i.e. a Verilator build. On the FPGA/ASIC the CMD/DAT pads are inout and no
    // host model can drive them, so emit nothing.
    final clk = ctx.topPort('sd_clk');
    final cmdOe = ctx.topPort('sd_cmd_oe');
    final cmdOut = ctx.topPort('sd_cmd_out');
    final cmdIn = ctx.topPort('sd_cmd_in');
    final datOe = ctx.topPort('sd_dat_oe');
    final datOut = ctx.topPort('sd_dat_out');
    final datIn = ctx.topPort('sd_dat_in');
    if ([
      clk,
      cmdOe,
      cmdOut,
      cmdIn,
      datOe,
      datOut,
      datIn,
    ].any((p) => p == null)) {
      return const [];
    }
    final inst = '${name}_card';
    return [
      HarborSimModel(
        className: 'SdCard',
        clockPort: ctx.primaryClockPort,
        header: _sdCardHeader,
        declaration: 'static SdCard $inst("$name");',
        tick:
            '$inst.tick(top->$clk, top->$cmdOe, top->$cmdOut, top->$datOe, '
            'top->$datOut); top->$cmdIn = $inst.cmd_in; '
            'top->$datIn = $inst.dat_in;',
        cliOption:
            'else if (!strncmp(argv[a], "--sd-image=", 11))\n'
            '      $inst.open_image(argv[a] + 11);',
      ),
    ];
  }

  static const _sdCardHeader = r'''
#pragma once
// Simulated SD card for the Verilator harness. Speaks enough of the SD protocol
// for a host controller to identify the card (CMD0/8/55/ACMD41/2/3/9/7/16/ACMD6)
// and read 512-byte blocks (CMD17) off a raw disk image supplied with
// --sd-image=<path>. Presents as a high-capacity (SDHC, block-addressed) card.
//
// It drives the SD bus only: it collects the command frame off cmd_out while
// cmd_oe is high, then injects the response on cmd_in on FALLING SD-clock edges,
// and for a read injects the data block on the 4-bit dat_in lines. The real
// SDIO controller RTL (in the sim) shifts these off the bus into RESP0..3 / DATA
// and drives its own STATUS/INT_STATUS + ADMA - the card never touches registers.
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>

struct SdCard {
  const char* tag;
  FILE* img = nullptr;
  uint64_t num_blocks = 0;

  int prev_clk = 0;
  int prev_oe = 0;

  int   rx_active = 0;
  int   rx_n = 0;
  uint8_t rx[48];

  int   resp_active = 0;
  int   resp_gap = 0;
  int   resp_len = 0;
  int   resp_i = 0;
  uint8_t resp[136];

  int   data_gap = 0;
  int   data_active = 0;
  int   data_i = 0;
  int   data_n = 0;
  uint8_t data_nib[1 + 1024 + 16 + 1];

  int  bus4 = 0;
  uint32_t rca = 0x0001;

  int cmd_in = 1;
  int dat_in = 0xf;

  explicit SdCard(const char* t) : tag(t), num_blocks(131072) {}

  void open_image(const char* image_path) {
    img = fopen(image_path, "rb");
    if (img) {
      fseek(img, 0, SEEK_END);
      num_blocks = (uint64_t)ftell(img) / 512;
      fseek(img, 0, SEEK_SET);
      fprintf(stderr, "[sd] %s: %s, %llu blocks\n", tag, image_path,
              (unsigned long long)num_blocks);
    } else {
      fprintf(stderr, "[sd] %s: could not open %s\n", tag, image_path);
    }
  }

  static uint8_t crc7(const uint8_t* b, int n) {
    uint8_t c = 0;
    for (int i = 0; i < n; i++) {
      uint8_t fb = ((c >> 6) & 1) ^ (b[i] & 1);
      c = (c << 1) & 0x7f;
      if (fb) c ^= 0x09;
    }
    return c & 0x7f;
  }
  static uint16_t crc16_next(uint16_t crc, int bit) {
    int inv = ((crc >> 15) ^ (bit & 1)) & 1;
    uint16_t n = 0;
    for (int i = 0; i < 16; i++) {
      int b;
      if (i == 0)       b = inv;
      else if (i == 5)  b = ((crc >> 4) & 1) ^ inv;
      else if (i == 12) b = ((crc >> 11) & 1) ^ inv;
      else              b = (crc >> (i - 1)) & 1;
      n |= (b & 1) << i;
    }
    return n;
  }

  void build_short(int index, uint32_t arg) {
    memset(resp, 0, sizeof(resp));
    resp[0] = 0;
    resp[1] = 0;
    for (int i = 0; i < 6; i++) resp[2 + i] = (index >> (5 - i)) & 1;
    for (int i = 0; i < 32; i++) resp[8 + i] = (arg >> (31 - i)) & 1;
    uint8_t c = crc7(resp, 40);
    for (int i = 0; i < 7; i++) resp[40 + i] = (c >> (6 - i)) & 1;
    resp[47] = 1;
    resp_len = 48;
  }

  void build_r2(const uint8_t reg[128]) {
    resp[0] = 0;
    resp[1] = 0;
    for (int i = 0; i < 6; i++) resp[2 + i] = 1;
    for (int i = 0; i < 128; i++) resp[8 + i] = reg[127 - i];
    resp_len = 136;
  }

  void csd_reg(uint8_t reg[128]) {
    memset(reg, 0, 128);
    uint32_t c_size = (uint32_t)(num_blocks / 1024);
    if (c_size) c_size -= 1;
    reg[127] = 0; reg[126] = 1;
    for (int i = 0; i < 22; i++) reg[48 + i] = (c_size >> i) & 1;
    reg[0] = 1;
  }
  void cid_reg(uint8_t reg[128]) {
    memset(reg, 0, 128);
    reg[127] = 1;
    reg[0] = 1;
  }

  void arm_data_read(uint64_t lba) {
    static uint8_t blk[512];
    if (img && lba < num_blocks) {
      fseek(img, (long)(lba * 512), SEEK_SET);
      if (fread(blk, 1, 512, img) != 512) memset(blk, 0, 512);
    } else {
      memset(blk, 0, 512);
    }
    int n = 0;
    data_nib[n++] = 0x0;
    uint16_t crc[4] = {0, 0, 0, 0};
    for (int i = 0; i < 512; i++) {
      uint8_t byte = blk[i];
      for (int half = 1; half >= 0; half--) {
        uint8_t nib = (byte >> (half * 4)) & 0xf;
        data_nib[n++] = nib;
        for (int l = 0; l < 4; l++) crc[l] = crc16_next(crc[l], (nib >> l) & 1);
      }
    }
    for (int k = 0; k < 16; k++) {
      uint8_t nib = 0;
      for (int l = 0; l < 4; l++) nib |= ((crc[l] >> (15 - k)) & 1) << l;
      data_nib[n++] = nib;
    }
    data_nib[n++] = 0xf;
    data_n = n; data_i = 0;
    data_gap = 3; data_active = 0;
  }

  void decode_and_respond() {
    int index = 0;
    for (int i = 0; i < 6; i++) index = (index << 1) | rx[2 + i];
    uint32_t arg = 0;
    for (int i = 0; i < 32; i++) arg = (arg << 1) | rx[8 + i];
    static int expect_acmd = 0;
    int acmd = expect_acmd; expect_acmd = 0;

    resp_gap = 2; resp_i = 0; resp_active = 1; data_active = 0; data_n = 0;

    if (index == 0) {
      resp_active = 0; return;
    }
    if (acmd && index == 41) {
      build_short(index, 0xC0FF8000);
      return;
    }
    if (acmd && index == 6) {
      bus4 = 1; build_short(index, 0); return;
    }
    switch (index) {
      case 8:  build_short(index, arg & 0xfff); break;
      case 55: build_short(index, 0); expect_acmd = 1; break;
      case 2:  { uint8_t r[128]; cid_reg(r); build_r2(r); } break;
      case 3:  build_short(index, rca << 16); break;
      case 9:  { uint8_t r[128]; csd_reg(r); build_r2(r); } break;
      case 7:  build_short(index, 0); break;
      case 16: build_short(index, 0); break;
      case 17: build_short(index, 0); arm_data_read(arg); break;
      default: build_short(index, 0); break;
    }
  }

  void tick(int sclk, int cmd_oe, int cmd_out, int /*dat_oe*/, int /*dat_out*/) {
    int rise = !prev_clk && sclk;
    int fall = prev_clk && !sclk;
    prev_clk = sclk;

    if (prev_oe && !cmd_oe && rx_active && rx_n >= 40) {
      rx_active = 0;
      decode_and_respond();
    }
    prev_oe = cmd_oe;

    if (rise) {
      if (cmd_oe) {
        if (!rx_active) {
          if (cmd_out == 0) { rx_active = 1; rx_n = 0; rx[rx_n++] = 0; }
        } else if (rx_n < 48) {
          rx[rx_n++] = cmd_out & 1;
        }
      }
    }
    if (fall) {
      if (resp_active) {
        if (resp_gap > 0) { resp_gap--; cmd_in = 1; }
        else if (resp_i < resp_len) { cmd_in = resp[resp_i++]; }
        else {
          resp_active = 0; cmd_in = 1;
          if (data_n) data_active = 1;
        }
      } else {
        cmd_in = 1;
      }
      if (data_active) {
        if (data_gap > 0) { data_gap--; dat_in = 0xf; }
        else if (data_i < data_n) { dat_in = data_nib[data_i++]; }
        else { data_active = 0; data_n = 0; dat_in = 0xf; }
      } else {
        dat_in = 0xf;
      }
    }
  }
};
''';
}
