import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../blackbox/ecp5/ecp5.dart';
import '../blackbox/xilinx/xilinx.dart';
import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../bus/wishbone/wishbone_interface.dart';
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
/// - 0x08: STATUS    (card_detect, card_ready, busy, error)
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
/// - 0x70: ADMA_ADDR  (descriptor table base for DMA transfers)
///
/// CMD bits: [5:0] index, [7:6] response type (0 none, 1 short, 2 long R2,
/// 3 short+busy), [8] data present, [9] direction (0 write, 1 read), [10] use
/// ADMA DMA. INT_STATUS bits: [0] cmd-done, [1] data-done, [2] data-request,
/// [3] data-CRC-error, [4] cmd-timeout, [5] write-error.
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

  /// Expose the ADMA descriptor engine's memory port as a Wishbone-B4 master
  /// interface named `dma` (instead of the raw addr/wdata/rdata/we/stb/ack
  /// ports), so the SoC fabric can attach it with a single `addMaster`. Off by
  /// default so the ADMA unit tests keep driving the raw handshake.
  final bool fabricDma;

  /// Address width of the [fabricDma] Wishbone master. The ADMA engine computes
  /// 32-bit addresses; on a wider fabric they are zero-extended (fine while the
  /// addressable memory map sits below 4 GiB).
  final int dmaAddressWidth;

  /// Data width of the [fabricDma] Wishbone master (must match the fabric: 32 or
  /// 64). The ADMA engine moves 32-bit words; on a 64-bit fabric each word is
  /// placed into the half of the beat its address selects (byte-enables mask the
  /// other half), and reads extract that same half.
  final int dmaDataWidth;

  /// Controller input clock in Hz (the system clock the CLK_DIV register
  /// divides). Emitted as `clock-frequency`, because a driver cannot pick a
  /// divider without it: the SD clock is this rate over 2 * (CLK_DIV + 1).
  /// 0 leaves the property out.
  int clockFrequency;

  /// Beats the ADMA keeps CYC asserted for before releasing the bus for a
  /// cycle. The SoC arbiter locks the grant while a master holds CYC, so a
  /// master that drops CYC every beat re-arbitrates per word; on a fabric whose
  /// DDR slave is slow and whose CPU is polling the same bus, that ping-pong
  /// dominates the transfer. Holding CYC across a burst amortises it. The cap
  /// bounds how long another master can be kept waiting.
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

  /// Words the card-read ADMA buffers before it starts to drain a burst.
  ///
  /// The downstream DDR burst adapter combines sequential narrow writes into one
  /// wide DRAM burst only when they reach it close together; a write that stands
  /// alone for the adapter's idle window lands as its own single-word DRAM
  /// command. If the ADMA drained each SD word the instant it arrived, the words
  /// would reach the adapter one SD-clock apart, never combine, and every word
  /// would cost a whole DRAM burst. So the ADMA holds off until [dmaWriteBatch]
  /// words are waiting, then STREAMS them out back to back (STB held asserted).
  /// A full 128-bit burst is four 32-bit words, so four is the natural default.
  /// The end of the SD data phase always releases whatever partial batch is left,
  /// so no words are stranded and the batch never deadlocks. Clamped to the RX
  /// FIFO depth so it is always reachable.
  final int dmaWriteBatch;

  /// Hold a card-read DMA's data-done until a read-back of the last written
  /// address has completed on the ADMA master port.
  ///
  /// On a posted-write fabric (the DDR3 path: posted CDC bridge + write-combining
  /// burst adapter) the ADMA's block writes are ACKed before they COMMIT to the
  /// DRAM array, so raising data-done the instant the RX FIFO drains lets a
  /// driver (or the CPU) read the buffer while the last writes are still in
  /// flight, returning stale data. The read shares the CDC's one request FIFO
  /// with those writes, so it is served only after every write queued before it,
  /// and the in-order controller commits the writes (tWTR) before returning read
  /// data. When the read acks, the block is durable, so data-done now MEANS
  /// durable and the firmware drain guess is unnecessary. Off by default keeps
  /// the RTL byte-identical for single-cycle-ack fabrics that need no barrier.
  final bool readBackBarrier;

  // With [ownPads], the FSM's CMD/DAT input signals come from the inout pads;
  // held here so the late pad wiring can drive them.
  Logic? _sdCmdInInt;
  Logic? _sdDatInInt;

  HarborSdioController({
    required this.baseAddress,
    this.config = const HarborSdioConfig.sd(),
    BusProtocol protocol = BusProtocol.wishbone,
    this.target,
    this.ownPads = false,
    this.fabricDma = false,
    this.dmaAddressWidth = 32,
    this.dmaDataWidth = 32,
    this.busAddressWidth = 8,
    this.busDataWidth = 32,
    this.clockFrequency = 0,
    this.rxFifoDepth = 16,
    this.dmaBurstBeats = 16,
    this.dmaWriteBatch = 4,
    this.readBackBarrier = false,
    String? name,
  }) : assert(
         dmaDataWidth == 32 || dmaDataWidth == 64,
         'fabricDma dataWidth must be 32 or 64',
       ),
       assert(
         rxFifoDepth >= 2 && (rxFifoDepth & (rxFifoDepth - 1)) == 0,
         'rxFifoDepth must be a power of two, at least 2',
       ),
       assert(dmaBurstBeats >= 1, 'dmaBurstBeats must be at least 1'),
       assert(dmaWriteBatch >= 1, 'dmaWriteBatch must be at least 1'),
       super('HarborSdioController', name: name ?? 'sdio') {
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

    // Descriptor-driven DMA memory port. Either a Wishbone-B4 master (fabric)
    // or the raw single-beat ADMA handshake ports.
    if (fabricDma) {
      addInterface(
        WishboneInterface(
          WishboneConfig(
            addressWidth: dmaAddressWidth,
            dataWidth: dmaDataWidth,
          ),
        ),
        name: 'dma',
        role: PairRole.provider,
      );
    } else {
      addOutput('dma_addr', width: 32);
      // The raw handshake carries a full fabric beat, like the Wishbone master
      // does, so a 64-bit port can take a packed two-word beat.
      addOutput('dma_wdata', width: dmaDataWidth);
      addOutput('dma_sel', width: dmaDataWidth ~/ 8);
      // CYC alongside STB even on the raw handshake: it spans a burst, so a
      // consumer (and a test) can see the bus being held across beats.
      addOutput('dma_cyc');
      createPort('dma_rdata', PortDirection.input, width: dmaDataWidth);
      addOutput('dma_we');
      addOutput('dma_stb');
      createPort('dma_ack', PortDirection.input);
    }

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: busAddressWidth,
      dataWidth: dw,
    );

    final clk = input('clk');
    final reset = input('reset');
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
    // Shift FIFO: the head is ALWAYS at index 0. On a pop the whole array
    // shifts down toward index 0 by the number of words retired, and a push
    // writes at the tail. So the oldest word and the three lookahead words are
    // plain fixed-index reads with NO muxes at all. The old moving read pointer
    // needed a depth-wide mux for each of these four reads, which was the
    // dominant MUXF7/MUXF8 congestion in this peripheral.
    //
    // [rxHead] is the oldest word. [rxHead2] is the second oldest; a 64-bit
    // beat carries it together with [rxHead]. [rxHead3] and [rxHead4] are the
    // third and fourth oldest; a PACKED beat retires two words at once, so the
    // beat that follows a packed one starts two slots on. These let the engine
    // re-arm the next beat on the ack WITHOUT dropping STB, so the downstream
    // burst adapter keeps combining narrow words into wide bursts (see
    // aMemWrite streaming). Clamp the index so a small FIFO never reads out of
    // range; the lookahead beyond the true count is gated off downstream.
    Logic rxSlot(int i) => rxFifo[i < rxDepth ? i : rxDepth - 1];
    final rxHead = rxSlot(0).named('rx_head');
    final rxHead2 = rxSlot(1).named('rx_head2');
    final rxHead3 = rxSlot(2).named('rx_head3');
    final rxHead4 = rxSlot(3).named('rx_head4');

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

    // ADMA descriptor DMA. The engine walks a descriptor table in memory and
    // bridges memory to the DAT word handshake (dataReg/dataValid): on a card
    // read it writes each produced word to memory, on a card write it fetches
    // words from memory. Descriptor = two words: [address], [byte length in
    // [15:0], end flag in [31]].
    const aIdle = 0;
    const aFetchAddr = 1; // read descriptor word 0 (address)
    const aFetchCtrl = 2; // read descriptor word 1 (length + end flag)
    const aMemRead = 3; // card write: fetch a word from memory
    const aMemWrite = 4; // card read: store a produced word to memory
    const aNext = 5; // advance within / past the current descriptor
    const aBarrier = 6; // card read: read-back the last write before data-done

    final dmaMode = Logic(name: 'dma_mode');
    final admaState = Logic(name: 'adma_state', width: 3);
    final descPtr = Logic(name: 'adma_desc_ptr', width: 32);
    final descAddr = Logic(name: 'adma_addr', width: 32);
    final descBytes = Logic(name: 'adma_bytes', width: 16);
    final descEnd = Logic(name: 'adma_end');
    final admaBase = Logic(name: 'adma_base', width: 32);
    final dmaWb = fabricDma
        ? interface('dma').internalInterface! as WishboneInterface
        : null;
    final dmaAck = fabricDma ? dmaWb!.ack : input('dma_ack');
    // The last address the card-read ADMA wrote, re-read after the transfer to
    // fence the posted writes (see [readBackBarrier]). Only built when the
    // barrier is enabled, so the RTL is byte-identical otherwise.
    // Cycles to hold the DMA master fully idle after a card-read's last write,
    // before data-done. The idle bus lets the burst adapter's idle-flush land
    // its held write burst and the controller commit it (write + tWR), so
    // data-done MEANS the block is durable in DRAM. The wait injects NO new bus
    // transaction (an earlier read-back approach deadlocked the DRAM CDC bridge,
    // which needs CYC to drop between transactions); the CPU polls the SDIO
    // STATUS MMIO meanwhile, so DRAM is idle and the flush proceeds. Sized well
    // above the adapter idle-flush window + controller commit. Only built when
    // the barrier is enabled, so the RTL is byte-identical otherwise.
    final barrierWait = readBackBarrier
        ? Logic(name: 'dma_barrier_wait', width: 9)
        : null;
    // Master output drives (set by the ADMA FSM, default idle).
    final dmaAddrReg = Logic(name: 'dma_addr_reg', width: 32);
    final dmaWdataReg = Logic(name: 'dma_wdata_reg', width: 32);
    // High half of a packed 64-bit beat, and the flag that says this beat
    // carries two words instead of one. Only ever set when [dmaDataWidth] is
    // 64, the target is 8-byte aligned, and two words are ready to go.
    final dmaWdataHi = Logic(name: 'dma_wdata_hi', width: 32);
    final dmaPack = Logic(name: 'dma_pack');
    final dmaWeReg = Logic(name: 'dma_we_reg');
    final dmaStbReg = Logic(name: 'dma_stb_reg');
    // CYC is held across a burst of beats rather than pulsed per beat, so the
    // arbiter's grant lock keeps the bus for the burst. `dmaCycRelease` drops it
    // for one cycle at the burst boundary to let another master in.
    final dmaCycReg = Logic(name: 'dma_cyc_reg');
    final dmaCycRelease = Logic(name: 'dma_cyc_release');
    final burstBits = (dmaBurstBeats <= 1) ? 1 : (dmaBurstBeats - 1).bitLength;
    final dmaBurstCnt = Logic(name: 'dma_burst_cnt', width: burstBits);
    // Which 32-bit word of a wide beat this address selects (bit 2 for 64-bit).
    final dmaHiWord = dmaAddrReg[2];
    // Reads always take one 32-bit word: the addressed half of a wide beat.
    // Only card-read stores pack two words into a beat.
    final dmaMiso = fabricDma ? dmaWb!.datMiso : input('dma_rdata');
    final dmaRdata = dmaDataWidth == 32
        ? dmaMiso
        : mux(dmaHiWord, dmaMiso.getRange(32, 64), dmaMiso.getRange(0, 32));
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
    final busServed = Logic(name: 'bus_served');
    final busAccess = (bus.stb & ~bus.ack & ~busServed).named('bus_access');

    // Pop strobes. The ADMA retires a word when the fabric acks the beat that
    // carried it; the CPU retires one by reading DATA during a card read.
    final dmaBeatDone =
        (admaState.eq(Const(aMemWrite, width: 3)) &
                dmaStbReg &
                dmaWeReg &
                dmaAck)
            .named('dma_beat_done');
    // A packed beat retires TWO words from the FIFO, an unpacked one retires
    // one.
    final rxPopAdma = (dmaBeatDone & ~dmaPack).named('rx_pop_adma');
    final rxPopAdma2 = (dmaBeatDone & dmaPack).named('rx_pop_adma2');
    final rxPopCpu =
        (busAccess &
                ~bus.we &
                cmdDataDir &
                ~rxEmpty &
                bus.addr
                    .getRange(3, busAddressWidth)
                    .eq(Const(0x09, width: busAddressWidth - 3)))
            .named('rx_pop_cpu');
    final rxPop = (rxPopAdma | rxPopCpu).named('rx_pop');
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

    // Two words may share a beat only on a 64-bit port, at an 8-byte aligned
    // target, with at least 8 bytes still owed by the descriptor. An unaligned
    // start or an odd tail word falls back to a half-width beat, so no
    // descriptor length or alignment is refused.
    final packTarget = dmaDataWidth == 64
        ? (~descAddr[2] & descBytes.gte(Const(8, width: 16))).named(
            'dma_pack_target',
          )
        : Const(0);
    final rxHavePair = rxCount
        .gte(Const(2, width: rxPtrW + 1))
        .named('rx_have_pair');
    // Hold a lone word back while its partner is still on the way. Sending the
    // instant one word arrives is what kept every beat half width: the engine
    // never had two in hand at once. `dmaTailWait` marks the end of the SD data
    // phase, so the last odd word is always released rather than stranded.
    final dmaWaitPair = (packTarget & ~rxHavePair & ~dmaTailWait).named(
      'dma_wait_pair',
    );
    final canPack = (packTarget & rxHavePair).named('dma_can_pack');
    // Hold off starting a burst until a full wide-burst's worth of words is
    // buffered (or the SD data phase has ended, which releases the tail). This
    // is what lets the streamed beats reach the burst adapter close enough
    // together to combine; draining a lone word the instant it arrives put every
    // word into its own DRAM burst. Clamp to the FIFO depth so the threshold is
    // always reachable and the SD-clock stall (rxFull) can never wedge it.
    final batchWords = dmaWriteBatch > rxDepth ? rxDepth : dmaWriteBatch;
    final dmaBatchReady =
        (rxCount.gte(Const(batchWords, width: rxPtrW + 1)) | dmaTailWait).named(
          'dma_batch_ready',
        );
    final dmaArmBeat = (~rxEmpty & ~dmaWaitPair & dmaBatchReady).named(
      'dma_arm_beat',
    );

    // Streaming continuation (LiteX WishboneDMAWriter pattern). To let the
    // downstream burst adapter combine narrow words into wide bursts, the engine
    // holds STB asserted across beats: on each ack it re-arms the NEXT beat in
    // place instead of dropping STB and detouring through aNext. The signals
    // below describe that next beat, computed as if the current beat's pop has
    // already retired its word(s). A packed current beat retires two words, so
    // the next beat's first word sits two slots on (rxHead3) and its partner one
    // more (rxHead4); an unpacked current beat retires one, so the next word is
    // rxHead2 and its partner rxHead3. rxCount is reduced by the same amount,
    // which is conservative because a concurrent push can only add words.
    final dmaPopWords = mux(
      dmaPack,
      Const(2, width: rxPtrW + 1),
      Const(1, width: rxPtrW + 1),
    );
    final dmaNextAddr = mux(
      dmaPack,
      descAddr + Const(8, width: 32),
      descAddr + Const(4, width: 32),
    ).named('dma_next_addr');
    final dmaNextBytes = mux(
      dmaPack,
      descBytes - Const(8, width: 16),
      descBytes - Const(4, width: 16),
    ).named('dma_next_bytes');
    final dmaNextCount = (rxCount - dmaPopWords).named('dma_next_count');
    final dmaNextHead = mux(dmaPack, rxHead3, rxHead2).named('dma_next_head');
    final dmaNextHead2 = mux(dmaPack, rxHead4, rxHead3).named('dma_next_head2');
    final dmaNextPackTarget = dmaDataWidth == 64
        ? (~dmaNextAddr[2] & dmaNextBytes.gte(Const(8, width: 16))).named(
            'dma_next_pack_target',
          )
        : Const(0);
    final dmaNextHavePair = dmaNextCount
        .gte(Const(2, width: rxPtrW + 1))
        .named('dma_next_have_pair');
    final dmaNextCanPack = (dmaNextPackTarget & dmaNextHavePair).named(
      'dma_next_can_pack',
    );
    // Mirror dmaWaitPair for the next beat: hold a lone word back for its partner
    // unless the SD data phase has ended (dmaTailWait), when the odd tail word is
    // released instead of stranded.
    final dmaNextWaitPair =
        (dmaNextPackTarget & ~dmaNextHavePair & ~dmaTailWait).named(
          'dma_next_wait_pair',
        );
    final dmaNextHaveWord = dmaNextCount
        .gte(Const(1, width: rxPtrW + 1))
        .named('dma_next_have_word');
    final dmaNextArm = (dmaNextHaveWord & ~dmaNextWaitPair).named(
      'dma_next_arm',
    );
    final dmaNextMore = dmaNextBytes
        .neq(Const(0, width: 16))
        .named('dma_next_more');
    // Fairness boundary: the last beat of a burst window still drops CYC for one
    // cycle so a waiting master gets in, so streaming pauses there.
    final dmaBurstBoundary = dmaBurstCnt
        .eq(Const(dmaBurstBeats - 1, width: burstBits))
        .named('dma_burst_boundary');
    // Keep STB asserted and re-arm the next beat only when the descriptor still
    // owes bytes, the FIFO already holds the next beat's word(s), and this is not
    // a fairness burst boundary.
    final dmaStream = (dmaNextMore & dmaNextArm & ~dmaBurstBoundary).named(
      'dma_stream',
    );

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
    // The beat payload. On a 32-bit port it is simply the staged word. On a
    // 64-bit port a PACKED beat carries two consecutive words with every byte
    // enabled, which halves the number of round trips; an unpacked beat still
    // goes into the addressed half with the other half masked off, which is
    // what an unaligned start or an odd tail word needs.
    final Logic dmaBeatData;
    final Logic dmaBeatSel;
    if (dmaDataWidth == 32) {
      dmaBeatData = dmaWdataReg;
      dmaBeatSel = Const(0xF, width: 4);
    } else {
      // Only a write beat can be packed, so a stale flag can never widen the
      // byte-enables of a descriptor fetch.
      final packBeat = (dmaPack & dmaWeReg).named('dma_pack_beat');
      dmaBeatData = mux(
        packBeat,
        [dmaWdataHi, dmaWdataReg].swizzle(),
        mux(
          dmaHiWord,
          [dmaWdataReg, Const(0, width: 32)].swizzle(),
          [Const(0, width: 32), dmaWdataReg].swizzle(),
        ),
      ).named('dma_beat_data');
      dmaBeatSel = mux(
        packBeat,
        Const(0xFF, width: 8),
        mux(dmaHiWord, Const(0xF0, width: 8), Const(0x0F, width: 8)),
      ).named('dma_beat_sel');
    }

    if (fabricDma) {
      // Wishbone-B4 classic block transfer: CYC spans the burst, STB marks the
      // individual beats. CYC == STB (a fresh bus cycle per beat) made the
      // arbiter re-run for every word.
      dmaWb!.cyc <= (dmaCycReg | dmaStbReg) & ~dmaCycRelease;
      dmaWb.stb <= dmaStbReg;
      dmaWb.we <= dmaWeReg;
      dmaWb.adr <= dmaAddrReg.zeroExtend(dmaAddressWidth);
      dmaWb.datMosi <= dmaBeatData;
      dmaWb.sel <= dmaBeatSel;
    } else {
      output('dma_addr') <= dmaAddrReg;
      output('dma_wdata') <= dmaBeatData;
      output('dma_sel') <= dmaBeatSel;
      output('dma_we') <= dmaWeReg;
      output('dma_stb') <= dmaStbReg;
      output('dma_cyc') <= (dmaCycReg | dmaStbReg) & ~dmaCycRelease;
    }
    interrupt <= (intStatus & intEnable).or();

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
          dmaMode < Const(0),
          admaState < Const(aIdle, width: 3),
          descPtr < Const(0, width: 32),
          descAddr < Const(0, width: 32),
          descBytes < Const(0, width: 16),
          descEnd < Const(0),
          admaBase < Const(0, width: 32),
          if (barrierWait != null) barrierWait < Const(0, width: 9),
          dmaAddrReg < Const(0, width: 32),
          dmaWdataReg < Const(0, width: 32),
          dmaWdataHi < Const(0, width: 32),
          dmaPack < Const(0),
          dmaWeReg < Const(0),
          dmaStbReg < Const(0),
          dmaCycReg < Const(0),
          dmaCycRelease < Const(0),
          dmaBurstCnt < Const(0, width: burstBits),
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
                    datOutReg < crcOutVec,
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
                        If(
                          [
                            statShift.getRange(0, 2),
                            datIn[0],
                          ].swizzle().neq(Const(0x2, width: 3)),
                          then: [
                            intStatus <
                                (intStatus | Const(intWriteErr, width: 8)),
                          ],
                        ),
                        datState < Const(dWBusy, width: 4),
                        busySeen < Const(0),
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

          // A DMA read completes when the descriptor walker has parked AND the
          // RX FIFO has drained, so every received word is in memory.
          If(
            dmaTailWait & admaState.eq(Const(aIdle, width: 3)) & rxEmpty,
            then: [
              dmaTailWait < Const(0),
              busy < Const(0),
              intStatus < (intStatus | Const(intDataDone, width: 8)),
            ],
          ),

          // Burst release pulse: one cycle with CYC low at the burst boundary,
          // so a master that has been waiting behind the grant lock gets in.
          If(dmaCycRelease, then: [dmaCycRelease < Const(0)]),

          // ADMA descriptor walker. Runs concurrently with the DAT serial
          // engine (which paces the SD bus) and bridges memory to the
          // dataReg/dataValid word handshake. cmdDataDir == 1 is a card read
          // (the engine stores produced words to memory), == 0 is a card write
          // (it fetches words from memory).
          Case(admaState, [
            // Parked. Hold the master request low: a descriptor walk that ended
            // with a request still asserted would keep winning the arbiter and
            // starve the CPU, which looks like a whole-fabric hang.
            CaseItem(Const(aIdle, width: 3), [
              dmaStbReg < Const(0),
              dmaWeReg < Const(0),
              dmaCycReg < Const(0),
              dmaPack < Const(0),
              dmaBurstCnt < Const(0, width: burstBits),
            ]),
            CaseItem(Const(aFetchAddr, width: 3), [
              dmaCycReg < Const(1),
              dmaAddrReg < descPtr,
              dmaWeReg < Const(0),
              dmaStbReg < Const(1),
              If(
                dmaAck,
                then: [
                  descAddr < dmaRdata,
                  dmaStbReg < Const(0),
                  admaState < Const(aFetchCtrl, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(aFetchCtrl, width: 3), [
              dmaCycReg < Const(1),
              dmaAddrReg < (descPtr + Const(4, width: 32)),
              dmaWeReg < Const(0),
              dmaStbReg < Const(1),
              If(
                dmaAck,
                then: [
                  descBytes < dmaRdata.getRange(0, 16),
                  descEnd < dmaRdata[31],
                  dmaStbReg < Const(0),
                  If(
                    cmdDataDir,
                    then: [admaState < Const(aMemWrite, width: 3)],
                    orElse: [admaState < Const(aMemRead, width: 3)],
                  ),
                ],
              ),
            ]),
            // Card write: fetch a word into the DAT buffer when it is free.
            CaseItem(Const(aMemRead, width: 3), [
              // Nothing to move yet: drop CYC so a waiting master gets the bus
              // instead of sitting behind the grant lock.
              If(dataValid, then: [dmaCycReg < Const(0)]),
              If(
                ~dataValid,
                then: [
                  dmaCycReg < Const(1),
                  dmaAddrReg < descAddr,
                  dmaWeReg < Const(0),
                  dmaStbReg < Const(1),
                  If(
                    dmaAck,
                    then: [
                      dataReg < dmaRdata,
                      dataValid < Const(1),
                      dmaStbReg < Const(0),
                      descAddr < (descAddr + Const(4, width: 32)),
                      descBytes < (descBytes - Const(4, width: 16)),
                      admaState < Const(aNext, width: 3),
                      dmaBurstCnt < (dmaBurstCnt + Const(1, width: burstBits)),
                      If(
                        dmaBurstCnt.eq(
                          Const(dmaBurstBeats - 1, width: burstBits),
                        ),
                        then: [
                          dmaBurstCnt < Const(0, width: burstBits),
                          dmaCycReg < Const(0),
                          dmaCycRelease < Const(1),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            // Card read: store produced words to memory. The words come off the
            // RX FIFO, so the receive engine keeps running while a beat is
            // outstanding. `rxPopAdma`/`rxPopAdma2` retire them on the ack.
            //
            // On a 64-bit port two consecutive words go out as ONE full-width
            // beat, so a block costs half as many round trips. The decision is
            // latched with the rest of the beat and held until the ack: the SD
            // side keeps pushing while the beat is in flight, so a live
            // `canPack` would change SEL under an asserted STB.
            CaseItem(Const(aMemWrite, width: 3), [
              // Never drop CYC mid-beat, only when there is nothing to send
              // yet (empty, or one word waiting for the partner it will share
              // a beat with).
              If(~dmaArmBeat & ~dmaStbReg, then: [dmaCycReg < Const(0)]),
              If(
                dmaArmBeat | dmaStbReg,
                then: [
                  dmaCycReg < Const(1),
                  If(
                    ~dmaStbReg,
                    then: [
                      dmaAddrReg < descAddr,
                      dmaWdataReg < rxHead,
                      dmaWdataHi < rxHead2,
                      dmaPack < canPack,
                      dmaWeReg < Const(1),
                      dmaStbReg < Const(1),
                    ],
                  ),
                  If(
                    dmaAck,
                    then: [
                      // Advance the descriptor past the beat just accepted. The
                      // rxPopAdma/rxPopAdma2 strobes retire its word(s) at this
                      // same edge.
                      descAddr < dmaNextAddr,
                      descBytes < dmaNextBytes,
                      // Burst accounting: hand the bus back briefly every
                      // dmaBurstBeats so a waiting master is not starved.
                      dmaBurstCnt < (dmaBurstCnt + Const(1, width: burstBits)),
                      If(
                        dmaStream,
                        // The descriptor still owes bytes and the next beat's
                        // word(s) are already in the FIFO: KEEP STB/WE asserted
                        // and re-arm the next beat in place, so the burst
                        // adapter never sees a gap and keeps combining. Draining
                        // the whole buffered batch back to back (not one word
                        // per SD clock) is what lands the words inside the
                        // adapter's combine window.
                        then: [
                          dmaAddrReg < dmaNextAddr,
                          dmaWdataReg < dmaNextHead,
                          dmaWdataHi < dmaNextHead2,
                          dmaPack < dmaNextCanPack,
                        ],
                        // Nothing more to send yet, a fairness boundary, or the
                        // descriptor is exhausted: drop the request and let
                        // aNext walk the descriptor / release the bus.
                        orElse: [
                          dmaStbReg < Const(0),
                          dmaWeReg < Const(0),
                          dmaPack < Const(0),
                          admaState < Const(aNext, width: 3),
                          If(
                            dmaBurstBoundary,
                            then: [
                              dmaBurstCnt < Const(0, width: burstBits),
                              dmaCycReg < Const(0),
                              dmaCycRelease < Const(1),
                            ],
                          ),
                        ],
                      ),
                    ],
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
                    then: [
                      // Card read with the barrier on: fence the posted writes
                      // with a read-back of the last write before parking (and
                      // so before data-done). Otherwise park straight away.
                      if (readBackBarrier)
                        If(
                          cmdDataDir,
                          then: [
                            barrierWait! < Const(256, width: 9),
                            admaState < Const(aBarrier, width: 3),
                          ],
                          orElse: [admaState < Const(aIdle, width: 3)],
                        )
                      else
                        admaState < Const(aIdle, width: 3),
                    ],
                    orElse: [
                      descPtr < (descPtr + Const(8, width: 32)),
                      admaState < Const(aFetchAddr, width: 3),
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
            // Card-read fence (readBackBarrier only): hold the DMA master fully
            // idle so the burst adapter idle-flushes its held write burst and the
            // controller commits it, before parking (which releases data-done).
            // No new bus transaction is issued, so the DRAM CDC bridge is never
            // driven back-to-back. The CPU is polling the SDIO STATUS MMIO
            // meanwhile, so DRAM stays idle and the flush proceeds.
            if (readBackBarrier)
              CaseItem(Const(aBarrier, width: 3), [
                dmaCycReg < Const(0),
                dmaStbReg < Const(0),
                dmaWeReg < Const(0),
                If(
                  barrierWait!.neq(Const(0, width: 9)),
                  then: [barrierWait < (barrierWait - Const(1, width: 9))],
                  orElse: [admaState < Const(aIdle, width: 3)],
                ),
              ]),
          ]),

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
              // indices 0,1,2. Match the full configured address width, not
              // just enough low bits for the registers defined today, so an
              // address outside the map reads 0 and ignores writes instead of
              // aliasing a register.
              Case(bus.addr.getRange(3, busAddressWidth), [
                // 0x00: CTRL ([0] enable, [5:4] reports max bus width,
                // [8] read-data sample edge 0:rising 1:falling).
                CaseItem(Const(0x00, width: busAddressWidth - 3), [
                  If(
                    bus.we & bus.selAny(0x00, 2),
                    then: [
                      ctrlEnable < bus.dataIn[0],
                      // [5:4] selects the active bus width (0:1-bit, 1:4-bit,
                      // 2:8-bit), clamped to the configured maximum.
                      busWidthSel < bus.dataIn.getRange(4, 6),
                      // [8] picks the read-data sample edge. Firmware raises it
                      // to sample the read DAT on the falling edge for
                      // round-trip margin at speed.
                      sampleFall < bus.dataIn[8],
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
                CaseItem(Const(0x01, width: busAddressWidth - 3), [
                  bus.dataOut <
                      cardDetect.zeroExtend(dw) |
                          (busy.zeroExtend(dw) << Const(8, width: 32)) |
                          (mux(
                                cmdDataDir,
                                ~rxEmpty,
                                dataValid,
                              ).zeroExtend(dw) <<
                              Const(9, width: 32)),
                ]),
                // 0x10: CLK_DIV.
                CaseItem(Const(0x02, width: busAddressWidth - 3), [
                  If(
                    bus.we,
                    then: [clkDiv < bus.selMerge(clkDiv, 0x10)],
                    orElse: [bus.dataOut < clkDiv.zeroExtend(dw)],
                  ),
                ]),
                // 0x18: CMD. Writing triggers a command when not busy.
                // [5:0] index, [7:6] response type (0 none, 1 short, 2 long
                // R2, 3 short+busy), [8] data present, [9] data direction
                // (0 write, 1 read).
                CaseItem(Const(0x03, width: busAddressWidth - 3), [
                  If(
                    bus.we & bus.selAny(0x18, 2),
                    then: [
                      If(
                        ~busy,
                        then: [
                          cmdIndex < wrIndex,
                          cmdRespType < bus.dataIn.getRange(6, 8),
                          cmdDataPresent < bus.dataIn[8],
                          cmdDataDir < bus.dataIn[9],
                          dmaMode < bus.dataIn[10], // [10] use ADMA DMA
                          cmdShift < cmdFrame,
                          cmdCnt < Const(48, width: 7),
                          cmdOut < Const(1),
                          cmdOe < Const(1),
                          busy < Const(1),
                          state < Const(sSend, width: 2),
                          // Start every data phase from a known state: an empty
                          // RX FIFO and a released master request. A previous
                          // transfer that ended mid-descriptor would otherwise
                          // leave a stale word (shifting the new block) or a
                          // stuck bus request (starving the CPU master).
                          If(
                            bus.dataIn[8],
                            then: [
                              rxCount < Const(0, width: rxPtrW + 1),
                              dmaStbReg < Const(0),
                              dmaWeReg < Const(0),
                            ],
                          ),
                          // Pre-fetch the ADMA descriptor NOW, at command issue,
                          // so the two descriptor reads from memory overlap the
                          // command+response window. The engine then parks in its
                          // memory state, ready, before the first data word. If it
                          // waited until the command completed, the descriptor
                          // fetch latency dropped the first several data words and
                          // shifted the whole block early.
                          If(
                            bus.dataIn[10] & bus.dataIn[8],
                            then: [
                              // Direct single-buffer DMA: ADMA_ADDR IS the buffer
                              // physical address and BLK_COUNT*BLK_SIZE is the
                              // length, so the engine NEVER fetches a descriptor
                              // from DRAM. A DRAM descriptor fetch races the CPU's
                              // descriptor store on silicon (a stale fetch makes a
                              // chunk write to the wrong buffer / the stack and
                              // corrupt the return frame). No fetch == no race.
                              descAddr < admaBase,
                              descBytes <
                                  (blkCount * blkSize.zeroExtend(16)).getRange(
                                    0,
                                    16,
                                  ),
                              descEnd < Const(1),
                              If(
                                bus.dataIn[9],
                                then: [admaState < Const(aMemWrite, width: 3)],
                                orElse: [admaState < Const(aMemRead, width: 3)],
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
                CaseItem(Const(0x04, width: busAddressWidth - 3), [
                  If(
                    bus.we,
                    then: [cmdArg < bus.selMerge(cmdArg, 0x20)],
                    orElse: [bus.dataOut < cmdArg.zeroExtend(dw)],
                  ),
                ]),
                // 0x28-0x40: RESP0-3.
                for (var i = 0; i < 4; i++)
                  CaseItem(Const(0x05 + i, width: busAddressWidth - 3), [
                    bus.dataOut < resp[i].zeroExtend(dw),
                  ]),
                // 0x48: DATA. One-word PIO buffer. CPU writes fill it (for a
                // write transfer), reads drain it (for a read transfer).
                CaseItem(Const(0x09, width: busAddressWidth - 3), [
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
                CaseItem(Const(0x0A, width: busAddressWidth - 3), [
                  If(
                    bus.we,
                    then: [blkSize < bus.selMerge(blkSize, 0x50)],
                    orElse: [bus.dataOut < blkSize.zeroExtend(dw)],
                  ),
                ]),
                // 0x58: BLK_COUNT.
                CaseItem(Const(0x0B, width: busAddressWidth - 3), [
                  If(
                    bus.we,
                    then: [blkCount < bus.selMerge(blkCount, 0x58)],
                    orElse: [bus.dataOut < blkCount.zeroExtend(dw)],
                  ),
                ]),
                // 0x60: INT_STATUS (write-1-to-clear).
                CaseItem(Const(0x0C, width: busAddressWidth - 3), [
                  If(
                    bus.we,
                    then: [intStatus < (intStatus & ~bus.selMasked(0x60, 8))],
                    orElse: [bus.dataOut < intStatus.zeroExtend(dw)],
                  ),
                ]),
                // 0x68: INT_ENABLE.
                CaseItem(Const(0x0D, width: busAddressWidth - 3), [
                  If(
                    bus.we,
                    then: [intEnable < bus.selMerge(intEnable, 0x68)],
                    orElse: [bus.dataOut < intEnable.zeroExtend(dw)],
                  ),
                ]),
                // 0x70: ADMA_ADDR (descriptor table base for DMA transfers).
                CaseItem(Const(0x0E, width: busAddressWidth - 3), [
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
          rst: input('reset'),
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
