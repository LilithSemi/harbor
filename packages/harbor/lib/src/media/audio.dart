import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../arith/fpu_config.dart' show harborStableDefinitionName;
import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../bus/port/dma_request_adapter.dart';
import '../bus/port/memory_port.dart';
import '../bus/port/memory_waist.dart';
import '../bus/port/reg_fifo.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';

/// Audio sample format.
enum HarborAudioFormat {
  /// Signed 16-bit PCM.
  s16le(16),

  /// Signed 24-bit PCM (packed in 32-bit).
  s24le(24),

  /// Signed 32-bit PCM.
  s32le(32),

  /// IEEE 754 32-bit float.
  float32(32);

  /// Bits per sample.
  final int bitsPerSample;

  const HarborAudioFormat(this.bitsPerSample);
}

/// Audio interface standard.
enum HarborAudioInterface {
  /// I2S (Inter-IC Sound).
  i2s,

  /// TDM (Time Division Multiplexing).
  tdm,

  /// AC97 legacy.
  ac97,

  /// S/PDIF (digital audio).
  spdif,

  /// PDM (Pulse Density Modulation) for MEMS microphones.
  pdm,
}

/// Audio codec hardware accelerator type.
enum HarborAudioCodecFormat {
  /// No hardware codec (PCM passthrough only).
  pcm('PCM'),

  /// AAC-LC encode/decode.
  aac('AAC-LC'),

  /// MP3 decode.
  mp3('MP3'),

  /// Opus encode/decode.
  opus('Opus'),

  /// FLAC decode.
  flac('FLAC'),

  /// Vorbis decode.
  vorbis('Vorbis');

  /// Display name.
  final String displayName;

  const HarborAudioCodecFormat(this.displayName);
}

/// Bitmask of [hwCodecs], one bit per [HarborAudioCodecFormat] index.
int _codecCapsOf(List<HarborAudioCodecFormat> hwCodecs) {
  var caps = 0;
  for (final c in hwCodecs) {
    caps |= 1 << c.index;
  }
  return caps;
}

/// Harbor Audio Controller.
///
/// Plays a ring of stereo samples from system memory. A DMA master port
/// (`dma`) reads the ring through a [HarborDmaRequestAdapter], and a
/// prefetch FIFO of [txFifoDepth] frames gives the stereo stream
/// `audio_valid`, `audio_left`, `audio_right` and `audio_ready` on `clk`.
/// A sample goes out when `audio_valid` and `audio_ready` are both high.
///
/// A ring frame is 8 bytes: the left sample, then the right sample, each a
/// 24-bit sample in bits 23:0 of a little endian 32-bit word ([formats] is
/// s24le). Bits 31:24 are ignored.
///
/// The ring starts at TX_DMA_ADDR and holds TX_DMA_SIZE bytes. TX_DMA_WR
/// and TX_DMA_RD are byte offsets into it. Software writes frames at
/// TX_DMA_WR and then moves it. The controller reads at TX_DMA_RD and moves
/// it past each frame it puts in the FIFO. The ring is empty when the two
/// are equal, so it holds at most TX_DMA_SIZE - 8 bytes. Bits 2:0 of the
/// four registers are always 0.
///
/// Register map (each register in its own 64-bit-aligned slot, so a 32-bit
/// access lands in the low word on both a 32-bit and a 64-bit fabric, and the
/// byte-address decode needs no high/low-half selection):
/// - 0x00: CTRL         (enable, interface select, master/slave)
/// - 0x08: STATUS       (read-only: bit 0 ring empty, bit 1 ring low, bit 2
///                        stream dry, bit 3 DMA halted, bit 4 fetch busy,
///                        bits 15:8 FIFO frames)
/// - 0x10: CLK_CFG      (MCLK divider, BCLK divider, LRCLK divider)
/// - 0x18: FORMAT       (read-only: bits 7:0 sample format index, bits 15:8
///                        channels)
/// - 0x20: TX_CTRL      (bit 0 play, bits 31:8 ring low level in bytes)
/// - 0x28: RX_CTRL      (rx enable, rx DMA enable, rx fifo threshold)
/// - 0x30: TX_DMA_ADDR  (ring base address)
/// - 0x38: TX_DMA_SIZE  (ring size in bytes)
/// - 0x40: TX_DMA_WR    (write offset, moved by software)
/// - 0x48: TX_DMA_RD    (read offset, moved by hardware, written by
///                        software only while play is 0 and no fetch runs)
/// - 0x50: RX_DMA_ADDR  (rx ring buffer base address)
/// - 0x58: RX_DMA_SIZE  (rx ring buffer size)
/// - 0x60: RX_DMA_WR    (rx write pointer, updated by hardware, read-only)
/// - 0x68: RX_DMA_RD    (rx read pointer, updated by software)
/// - 0x70: INT_STATUS   (W1C: bit 0 ring empty, bit 1 ring low, bit 4
///                        underrun, bit 7 DMA error)
/// - 0x78: INT_ENABLE   (interrupt enable mask)
/// - 0x80: VOLUME_L     (left channel volume, 0-255)
/// - 0x88: VOLUME_R     (right channel volume, 0-255)
/// - 0x90: MUTE         (bit 0: tx mute, bit 1: rx mute)
/// - 0x98: TX_UNDERRUN  (underrun count, stops at 0xffff, a write clears)
/// - 0xA0: TX_DMA_ERR   (W1C: bit 0 fabric error, bit 1 timeout)
/// - 0x100: CODEC_CTRL   (codec select, start, direction)
/// - 0x108: CODEC_STATUS  (codec busy/done/error)
/// - 0x110: CODEC_CAPS   (supported codecs bitmask, read-only)
///
/// While play is 1, ring empty and ring low (the bytes in the ring at or
/// below the low level) set their INT_STATUS bits each cycle. An underrun
/// is a time where the consumer is ready, the FIFO is empty and the ring is
/// empty. It counts once until the next frame goes in the FIFO. A failed
/// read sets a TX_DMA_ERR bit and stops the DMA at the failed frame until
/// software clears the bits. Play 0 empties the FIFO.
///
/// The `tx_underrun_count`, `tx_dma_error` and `tx_dma_timeout` outputs show
/// TX_UNDERRUN and the TX_DMA_ERR bits.
class HarborAudioController extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Supported audio interfaces.
  final List<HarborAudioInterface> audioInterfaces;

  /// Maximum number of channels.
  final int maxChannels;

  /// Supported sample rates in Hz.
  final List<int> sampleRates;

  /// Hardware codec acceleration (empty = PCM only).
  final List<HarborAudioCodecFormat> hwCodecs;

  /// Whether hardware sample rate conversion is supported.
  final bool hasSrc;

  /// Prefetch FIFO depth in stereo frames.
  final int txFifoDepth;

  /// RX FIFO depth in samples.
  final int rxFifoDepth;

  /// Address width of the register port. The registers decode the low 12
  /// bits, so a SoC sets it to the fabric width.
  final int busAddressWidth;

  /// Address width of the DMA master port.
  final int dmaAddressWidth;

  /// Cycles a DMA read may wait for the fabric before it fails.
  final int dmaTimeoutCycles;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// DMA master port. Add it to the SoC with `addMaster` and
  /// `busInterfaceName: 'dma'`.
  late final HarborMemoryMasterPort dma;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  /// I2S/TDM signals.
  Logic get mclk => output('mclk');
  Logic get bclk => output('bclk');
  Logic get lrclk => output('lrclk');
  Logic get sdataOut => output('sdata_out');
  Logic get sdataIn => input('sdata_in');

  /// S/PDIF output (null if S/PDIF not in audioInterfaces).
  Logic? get spdifOut => hasSpdif ? output('spdif_out') : null;

  /// S/PDIF input (null if S/PDIF not in audioInterfaces).
  Logic? get spdifIn => hasSpdif ? input('spdif_in') : null;

  /// PDM clock output (null if PDM not in audioInterfaces).
  Logic? get pdmClk => hasPdm ? output('pdm_clk') : null;

  /// PDM data input (null if PDM not in audioInterfaces).
  Logic? get pdmData => hasPdm ? input('pdm_data') : null;

  /// Stereo stream on `clk`.
  Logic get audioValid => output('audio_valid');
  Logic get audioLeft => output('audio_left');
  Logic get audioRight => output('audio_right');
  Logic get audioReady => input('audio_ready');

  /// TX_UNDERRUN.
  Logic get txUnderrunCount => output('tx_underrun_count');

  /// TX_DMA_ERR bit 0, a fabric error.
  Logic get dmaError => output('tx_dma_error');

  /// TX_DMA_ERR bit 1, a timeout.
  Logic get dmaTimeout => output('tx_dma_timeout');

  HarborAudioController({
    required this.baseAddress,
    this.audioInterfaces = const [HarborAudioInterface.i2s],
    this.maxChannels = 2,
    this.sampleRates = const [44100, 48000, 96000, 192000],
    this.hwCodecs = const [],
    this.hasSrc = false,
    this.txFifoDepth = 8,
    this.rxFifoDepth = 256,
    this.dmaAddressWidth = 32,
    this.busAddressWidth = 12,
    this.dmaTimeoutCycles = 1 << 16,
    HarborFabricKind fabricKind = HarborFabricKind.wishbone,
    bool crossFabricClock = false,
    String? name,
  }) : super(
         harborStableDefinitionName('HarborAudioController', [
           ...BusSlavePort.definitionNameParts(
             kind: fabricKind,
             addressWidth: busAddressWidth,
             dataWidth: 32,
             cross: crossFabricClock,
           ),
           audioInterfaces.map((i) => i.name).join('_'),
           'cc${_codecCapsOf(hwCodecs)}',
           'f$txFifoDepth',
           'm$dmaAddressWidth',
           't$dmaTimeoutCycles',
         ]),
         name: name ?? 'audio',
       ) {
    if (busAddressWidth < 12) {
      throw RangeError.value(
        busAddressWidth,
        'busAddressWidth',
        'must be >= 12',
      );
    }
    if (txFifoDepth < 1 || txFifoDepth > 255) {
      throw RangeError.range(txFifoDepth, 1, 255, 'txFifoDepth');
    }
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    addOutput('interrupt');

    // I2S/TDM signals
    addOutput('mclk');
    addOutput('bclk');
    addOutput('lrclk');
    addOutput('sdata_out');
    createPort('sdata_in', PortDirection.input);

    // Optional interfaces
    if (audioInterfaces.contains(HarborAudioInterface.spdif)) {
      addOutput('spdif_out');
      createPort('spdif_in', PortDirection.input);
    }

    if (audioInterfaces.contains(HarborAudioInterface.pdm)) {
      addOutput('pdm_clk');
      createPort('pdm_data', PortDirection.input);
    }

    addOutput('audio_valid');
    addOutput('audio_left', width: 24);
    addOutput('audio_right', width: 24);
    createPort('audio_ready', PortDirection.input);
    addOutput('tx_underrun_count', width: 16);
    addOutput('tx_dma_error');
    addOutput('tx_dma_timeout');

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
      dataWidth: 32,
      fabricClock: fabricClock,
    );
    dma = HarborMemoryMasterPort.create(
      module: this,
      name: 'dma',
      kind: fabricKind,
      config: HarborMemoryWaistConfig(
        addressWidth: dmaAddressWidth,
        dataWidth: 32,
      ),
      clk: input('clk'),
      reset: input('reset'),
      fabricClock: fabricClock,
    );

    final clk = input('clk');
    final reset = bus.reset;
    final regAddr = bus.addr.getRange(0, 12).named('reg_addr');

    // Registers
    final ctrl = Logic(name: 'ctrl', width: 32);
    final clkCfg = Logic(name: 'clk_cfg', width: 32);
    final txCtrl = Logic(name: 'tx_ctrl', width: 32);
    final rxCtrl = Logic(name: 'rx_ctrl', width: 32);
    final txDmaAddr = Logic(name: 'tx_dma_addr', width: 32);
    final txDmaSize = Logic(name: 'tx_dma_size', width: 32);
    final txDmaWr = Logic(name: 'tx_dma_wr', width: 32);
    final txDmaRd = Logic(name: 'tx_dma_rd', width: 32);
    final rxDmaAddr = Logic(name: 'rx_dma_addr', width: 32);
    final rxDmaSize = Logic(name: 'rx_dma_size', width: 32);
    final rxDmaWr = Logic(name: 'rx_dma_wr', width: 32);
    final rxDmaRd = Logic(name: 'rx_dma_rd', width: 32);
    final intStatus = Logic(name: 'int_status', width: 8);
    final intEnable = Logic(name: 'int_enable', width: 8);
    final volumeL = Logic(name: 'volume_l', width: 8);
    final volumeR = Logic(name: 'volume_r', width: 8);
    final muteReg = Logic(name: 'mute', width: 2);
    final underruns = Logic(name: 'tx_underruns', width: 16);
    final errBus = Logic(name: 'tx_err_bus');
    final errTimeout = Logic(name: 'tx_err_timeout');

    // Codec capabilities bitmask
    final codecCaps = _codecCapsOf(hwCodecs);
    final formatWord = 2 << 8 | HarborAudioFormat.s24le.index;

    interrupt <= (intStatus & intEnable).or();

    // Playback ring and fetch.
    final play = txCtrl[0];
    final lowLevel = txCtrl.getRange(8, 32).zeroExtend(32);
    final halted = (errBus | errTimeout).named('tx_halted');
    final ringEmpty = txDmaWr.eq(txDmaRd).named('ring_empty');
    final level = mux(
      txDmaWr.gte(txDmaRd),
      txDmaWr - txDmaRd,
      txDmaWr + txDmaSize - txDmaRd,
    ).named('ring_level');
    final ringLow = level.lte(lowLevel).named('ring_low');

    const fIdle = 0;
    const fLeft = 1;
    const fRight = 2;
    final fState = Logic(name: 'fetch_state', width: 2);
    final fetchIdle = fState.eq(Const(fIdle, width: 2));
    final inLeft = fState.eq(Const(fLeft, width: 2));
    final inRight = fState.eq(Const(fRight, width: 2));
    final leftSample = Logic(name: 'left_sample', width: 24);

    final readValid = Logic(name: 'dma_read_valid');
    final readData = Logic(name: 'dma_read_data', width: 32);
    final readErr = Logic(name: 'dma_read_err');
    final readTimeout = Logic(name: 'dma_read_timeout');
    final adapter = HarborDmaRequestAdapter(
      clk: clk,
      reset: reset,
      waist: dma.waist,
      readReq: (inLeft | inRight).named('dma_read_req'),
      readAddr:
          (txDmaAddr +
                  txDmaRd +
                  mux(inRight, Const(4, width: 32), Const(0, width: 32)))
              .slice(dmaAddressWidth <= 32 ? dmaAddressWidth - 1 : 31, 0)
              .zeroExtend(dmaAddressWidth)
              .named('dma_read_addr'),
      writeReq: Const(0),
      writeAddr: Const(0, width: dmaAddressWidth),
      writeData: Const(0, width: 32),
      timeoutCycles: dmaTimeoutCycles,
    );
    readValid <= adapter.readValid;
    readData <= adapter.readData;
    readErr <= adapter.err;
    readTimeout <= adapter.timeout;

    final popReady = Logic(name: 'fifo_pop_ready');
    final pushValid = (inRight & readValid & ~readErr & play).named(
      'fifo_push_valid',
    );
    final fifo = HarborRegFifo(
      name: 'tx_fifo',
      clk: clk,
      reset: reset | ~play,
      depth: txFifoDepth,
      pushValid: pushValid,
      pushData: [readData.slice(23, 0), leftSample].swizzle(),
      popReady: popReady,
      resetEntries: true,
    );
    final canFetch =
        (play & ~halted & ~ringEmpty & ~txDmaSize.eq(0) & fifo.pushReady).named(
          'can_fetch',
        );
    final rdStep = txDmaRd + Const(8, width: 32);
    final rdNext = mux(
      rdStep.gte(txDmaSize),
      Const(0, width: 32),
      rdStep,
    ).named('rd_next');

    Sequential(clk, reset: reset, [
      Case(fState, [
        CaseItem(Const(fIdle, width: 2), [
          If(canFetch, then: [fState < fLeft]),
        ]),
        CaseItem(Const(fLeft, width: 2), [
          If(
            readValid,
            then: [
              leftSample < readData.slice(23, 0),
              fState <
                  mux(
                    readErr | ~play,
                    Const(fIdle, width: 2),
                    Const(fRight, width: 2),
                  ),
            ],
          ),
        ]),
        CaseItem(Const(fRight, width: 2), [
          If(readValid, then: [fState < fIdle]),
        ]),
      ]),
    ]);

    final muted = muteReg[0];
    final streamValid = (play & fifo.popValid).named('stream_valid');
    popReady <= play & input('audio_ready');
    output('audio_valid') <= streamValid;
    output('audio_left') <=
        mux(muted, Const(0, width: 24), fifo.popData.slice(23, 0));
    output('audio_right') <=
        mux(muted, Const(0, width: 24), fifo.popData.slice(47, 24));

    // The stream is dry from an underrun until the next frame goes in.
    final dry = Logic(name: 'tx_dry');
    final dryNow = (play & input('audio_ready') & ~fifo.popValid & ringEmpty)
        .named('tx_dry_now');
    final underrun = (dryNow & ~dry).named('tx_underrun');
    Sequential(clk, reset: reset, [
      dry < play & ~fifo.pushFire & (dry | dryNow),
    ]);

    final readFail = (readValid & readErr & ~fetchIdle).named('dma_fail');
    final intSet = [
      readFail,
      Const(0, width: 2),
      underrun,
      Const(0, width: 2),
      play & ringLow,
      play & ringEmpty,
    ].swizzle().named('int_set');

    final regWrite = (bus.stb & ~bus.ack & bus.we).named('reg_write');
    Logic writes(int offset) => regWrite & regAddr.eq(Const(offset, width: 12));
    final intClear = mux(
      writes(0x70),
      bus.selMasked(0x70, 8),
      Const(0, width: 8),
    );
    final errClear = mux(
      writes(0xA0),
      bus.selMasked(0xA0, 2),
      Const(0, width: 2),
    );
    Logic aligned(Logic v) => [v.getRange(3), Const(0, width: 3)].swizzle();

    final status = [
      Const(0, width: 16),
      fifo.count.zeroExtend(8),
      Const(0, width: 3),
      ~fetchIdle,
      halted,
      dry,
      ringLow,
      ringEmpty,
    ].swizzle();

    // I2S clock generation (simplified: divider chain from system clock)
    final mclkDiv = Logic(name: 'mclk_div', width: 8);
    final bclkDiv = Logic(name: 'bclk_div', width: 8);
    final mclkCounter = Logic(name: 'mclk_counter', width: 8);
    final bclkCounter = Logic(name: 'bclk_counter', width: 8);
    final bitCounter = Logic(name: 'bit_counter', width: 6);

    Sequential(clk, [
      If(
        reset,
        then: [
          ctrl < Const(0, width: 32),
          clkCfg < Const(0, width: 32),
          txCtrl < Const(0, width: 32),
          rxCtrl < Const(0, width: 32),
          txDmaAddr < Const(0, width: 32),
          txDmaSize < Const(0, width: 32),
          txDmaWr < Const(0, width: 32),
          txDmaRd < Const(0, width: 32),
          rxDmaAddr < Const(0, width: 32),
          rxDmaSize < Const(0, width: 32),
          rxDmaWr < Const(0, width: 32),
          rxDmaRd < Const(0, width: 32),
          intStatus < Const(0, width: 8),
          intEnable < Const(0, width: 8),
          volumeL < Const(255, width: 8),
          volumeR < Const(255, width: 8),
          muteReg < Const(0, width: 2),
          underruns < Const(0, width: 16),
          errBus < Const(0),
          errTimeout < Const(0),
          mclkDiv < Const(4, width: 8),
          bclkDiv < Const(8, width: 8),
          mclkCounter < Const(0, width: 8),
          bclkCounter < Const(0, width: 8),
          bitCounter < Const(0, width: 6),
          output('mclk') < Const(0),
          output('bclk') < Const(0),
          output('lrclk') < Const(0),
          output('sdata_out') < Const(0),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          // MCLK generation
          If(
            mclkCounter.gte(mclkDiv),
            then: [
              mclkCounter < Const(0, width: 8),
              output('mclk') < ~output('mclk'),
            ],
            orElse: [mclkCounter < mclkCounter + 1],
          ),

          // BCLK generation
          If(
            bclkCounter.gte(bclkDiv),
            then: [
              bclkCounter < Const(0, width: 8),
              output('bclk') < ~output('bclk'),
              // Shift out/in data on BCLK edges
              bitCounter < bitCounter + 1,
              // LRCLK toggles every 32 (or 64) BCLK cycles
              If(
                bitCounter.eq(Const(31, width: 6)),
                then: [output('lrclk') < ~output('lrclk')],
              ),
            ],
            orElse: [bclkCounter < bclkCounter + 1],
          ),

          // Register access
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),
              Case(regAddr, [
                CaseItem(Const(0x00, width: 12), [
                  If(
                    bus.we,
                    then: [ctrl < bus.selMerge(ctrl, 0x00)],
                    orElse: [bus.dataOut < ctrl],
                  ),
                ]),
                CaseItem(Const(0x08, width: 12), [bus.dataOut < status]),
                CaseItem(Const(0x10, width: 12), [
                  If(
                    bus.we,
                    then: [clkCfg < bus.selMerge(clkCfg, 0x10)],
                    orElse: [bus.dataOut < clkCfg],
                  ),
                ]),
                CaseItem(Const(0x18, width: 12), [
                  bus.dataOut < Const(formatWord, width: 32),
                ]),
                CaseItem(Const(0x20, width: 12), [
                  If(
                    bus.we,
                    then: [txCtrl < bus.selMerge(txCtrl, 0x20)],
                    orElse: [bus.dataOut < txCtrl],
                  ),
                ]),
                CaseItem(Const(0x28, width: 12), [
                  If(
                    bus.we,
                    then: [rxCtrl < bus.selMerge(rxCtrl, 0x28)],
                    orElse: [bus.dataOut < rxCtrl],
                  ),
                ]),
                CaseItem(Const(0x30, width: 12), [
                  If(
                    bus.we,
                    then: [txDmaAddr < aligned(bus.selMerge(txDmaAddr, 0x30))],
                    orElse: [bus.dataOut < txDmaAddr],
                  ),
                ]),
                CaseItem(Const(0x38, width: 12), [
                  If(
                    bus.we,
                    then: [txDmaSize < aligned(bus.selMerge(txDmaSize, 0x38))],
                    orElse: [bus.dataOut < txDmaSize],
                  ),
                ]),
                CaseItem(Const(0x40, width: 12), [
                  If(
                    bus.we,
                    then: [txDmaWr < aligned(bus.selMerge(txDmaWr, 0x40))],
                    orElse: [bus.dataOut < txDmaWr],
                  ),
                ]),
                CaseItem(Const(0x48, width: 12), [
                  If(
                    bus.we,
                    then: [
                      If(
                        ~play & fetchIdle,
                        then: [txDmaRd < aligned(bus.selMerge(txDmaRd, 0x48))],
                      ),
                    ],
                    orElse: [bus.dataOut < txDmaRd],
                  ),
                ]),
                CaseItem(Const(0x50, width: 12), [
                  If(
                    bus.we,
                    then: [rxDmaAddr < bus.selMerge(rxDmaAddr, 0x50)],
                    orElse: [bus.dataOut < rxDmaAddr],
                  ),
                ]),
                CaseItem(Const(0x58, width: 12), [
                  If(
                    bus.we,
                    then: [rxDmaSize < bus.selMerge(rxDmaSize, 0x58)],
                    orElse: [bus.dataOut < rxDmaSize],
                  ),
                ]),
                CaseItem(Const(0x60, width: 12), [bus.dataOut < rxDmaWr]),
                CaseItem(Const(0x68, width: 12), [
                  If(
                    bus.we,
                    then: [rxDmaRd < bus.selMerge(rxDmaRd, 0x68)],
                    orElse: [bus.dataOut < rxDmaRd],
                  ),
                ]),
                // INT_STATUS (W1C below)
                CaseItem(Const(0x70, width: 12), [
                  bus.dataOut < intStatus.zeroExtend(32),
                ]),
                // INT_ENABLE
                CaseItem(Const(0x78, width: 12), [
                  If(
                    bus.we,
                    then: [intEnable < bus.selMerge(intEnable, 0x78)],
                    orElse: [bus.dataOut < intEnable.zeroExtend(32)],
                  ),
                ]),
                // VOLUME_L
                CaseItem(Const(0x80, width: 12), [
                  If(
                    bus.we,
                    then: [volumeL < bus.selMerge(volumeL, 0x80)],
                    orElse: [bus.dataOut < volumeL.zeroExtend(32)],
                  ),
                ]),
                // VOLUME_R
                CaseItem(Const(0x88, width: 12), [
                  If(
                    bus.we,
                    then: [volumeR < bus.selMerge(volumeR, 0x88)],
                    orElse: [bus.dataOut < volumeR.zeroExtend(32)],
                  ),
                ]),
                // MUTE
                CaseItem(Const(0x90, width: 12), [
                  If(
                    bus.we,
                    then: [muteReg < bus.selMerge(muteReg, 0x90)],
                    orElse: [bus.dataOut < muteReg.zeroExtend(32)],
                  ),
                ]),
                // TX_UNDERRUN (a write clears, below)
                CaseItem(Const(0x98, width: 12), [
                  bus.dataOut < underruns.zeroExtend(32),
                ]),
                // TX_DMA_ERR (W1C below)
                CaseItem(Const(0xA0, width: 12), [
                  bus.dataOut < [errTimeout, errBus].swizzle().zeroExtend(32),
                ]),
                // CODEC_CAPS
                CaseItem(Const(0x110, width: 12), [
                  bus.dataOut < Const(codecCaps, width: 32),
                ]),
              ]),
            ],
          ),

          // Hardware updates. A set in the same cycle as a clear wins.
          If(fifo.pushFire, then: [txDmaRd < rdNext]),
          intStatus < (intStatus & ~intClear) | intSet,
          errBus < (errBus & ~errClear[0]) | readFail & ~readTimeout,
          errTimeout < (errTimeout & ~errClear[1]) | readFail & readTimeout,
          If.block([
            Iff(writes(0x98), [underruns < Const(0, width: 16)]),
            ElseIf(underrun & ~underruns.and(), [underruns < underruns + 1]),
          ]),
        ],
      ),
    ]);

    output('tx_underrun_count') <= underruns;
    output('tx_dma_error') <= errBus;
    output('tx_dma_timeout') <= errTimeout;
  }

  /// Sample formats of the playback ring.
  List<HarborAudioFormat> get formats => const [HarborAudioFormat.s24le];

  /// Whether this controller supports playback.
  bool get canPlayback => true;

  /// Whether this controller supports capture.
  bool get canCapture => true;

  /// Whether S/PDIF is available.
  bool get hasSpdif => audioInterfaces.contains(HarborAudioInterface.spdif);

  /// Whether PDM microphone input is available.
  bool get hasPdm => audioInterfaces.contains(HarborAudioInterface.pdm);

  /// Whether hardware audio codecs are available.
  bool get hasHwCodec => hwCodecs.isNotEmpty;

  /// Maximum sample rate in Hz.
  int get maxSampleRate =>
      sampleRates.fold<int>(0, (max, r) => r > max ? r : max);

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,audio'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      '#sound-dai-cells': 0,
      'harbor,interfaces': audioInterfaces.map((i) => i.name).join(', '),
      'harbor,max-channels': maxChannels,
      'harbor,sample-rates': sampleRates.map((r) => '$r').join(', '),
      'harbor,formats': formats.map((f) => f.name).join(', '),
      if (hwCodecs.isNotEmpty)
        'harbor,codecs': hwCodecs.map((c) => c.displayName).join(', '),
      if (hasSrc) 'harbor,has-src': true,
      'harbor,tx-fifo-depth': txFifoDepth,
      'harbor,rx-fifo-depth': rxFifoDepth,
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,audio'],
      '#sound-dai-cells': 0,
      'harbor,interfaces': audioInterfaces.map((i) => i.name).join(', '),
      'harbor,max-channels': maxChannels,
      'harbor,sample-rates': sampleRates.map((r) => '$r').join(', '),
      'harbor,formats': formats.map((f) => f.name).join(', '),
      if (hwCodecs.isNotEmpty)
        'harbor,codecs': hwCodecs.map((c) => c.displayName).join(', '),
      if (hasSrc) 'harbor,has-src': true,
      'harbor,tx-fifo-depth': txFifoDepth,
      'harbor,rx-fifo-depth': rxFifoDepth,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'AUDIO',
    groupName: 'AUDIO',
    description: 'Audio controller',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
