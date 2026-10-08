import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
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

/// Harbor Audio Controller.
///
/// Provides I2S/TDM/S/PDIF/PDM audio interfaces with optional
/// hardware codec acceleration. Supports playback and capture
/// with DMA-based buffer management.
///
/// Architecture:
/// - **I2S/TDM transmitter**: Serializes PCM samples to the DAC/codec
/// - **I2S/TDM receiver**: Deserializes PCM samples from the ADC/codec
/// - **S/PDIF transmitter/receiver**: Digital audio output/input
/// - **PDM receiver**: For MEMS microphone arrays
/// - **Sample rate converter**: Optional hardware SRC
/// - **DMA engine**: Ring buffer for playback/capture
/// - **Audio codec**: Optional hardware encode/decode (AAC, Opus, etc.)
///
/// Register map (each register in its own 64-bit-aligned slot, so a 32-bit
/// access lands in the low word on both a 32-bit and a 64-bit fabric, and the
/// byte-address decode needs no high/low-half selection):
/// - 0x00: CTRL         (enable, interface select, master/slave)
/// - 0x08: STATUS       (tx fifo level, rx fifo level, underrun, overrun)
/// - 0x10: CLK_CFG      (MCLK divider, BCLK divider, LRCLK divider)
/// - 0x18: FORMAT       (sample format, channels, bit width, justification)
/// - 0x20: TX_CTRL      (tx enable, tx DMA enable, tx fifo threshold)
/// - 0x28: RX_CTRL      (rx enable, rx DMA enable, rx fifo threshold)
/// - 0x30: TX_DMA_ADDR  (tx ring buffer base address)
/// - 0x38: TX_DMA_SIZE  (tx ring buffer size)
/// - 0x40: TX_DMA_WR    (tx write pointer, updated by software)
/// - 0x48: TX_DMA_RD    (tx read pointer, updated by hardware, read-only)
/// - 0x50: RX_DMA_ADDR  (rx ring buffer base address)
/// - 0x58: RX_DMA_SIZE  (rx ring buffer size)
/// - 0x60: RX_DMA_WR    (rx write pointer, updated by hardware, read-only)
/// - 0x68: RX_DMA_RD    (rx read pointer, updated by software)
/// - 0x70: INT_STATUS   (W1C: tx empty, tx threshold, rx full, rx threshold,
///                        underrun, overrun, codec done)
/// - 0x78: INT_ENABLE   (interrupt enable mask)
/// - 0x80: VOLUME_L     (left channel volume, 0-255)
/// - 0x88: VOLUME_R     (right channel volume, 0-255)
/// - 0x90: MUTE         (bit 0: tx mute, bit 1: rx mute)
/// - 0x100: CODEC_CTRL   (codec select, start, direction)
/// - 0x108: CODEC_STATUS  (codec busy/done/error)
/// - 0x110: CODEC_CAPS   (supported codecs bitmask, read-only)
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

  /// Supported sample formats.
  final List<HarborAudioFormat> formats;

  /// Hardware codec acceleration (empty = PCM only).
  final List<HarborAudioCodecFormat> hwCodecs;

  /// Whether hardware sample rate conversion is supported.
  final bool hasSrc;

  /// TX FIFO depth in samples.
  final int txFifoDepth;

  /// RX FIFO depth in samples.
  final int rxFifoDepth;

  /// Bus slave port.
  late final BusSlavePort bus;

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

  /// DMA read interface.
  Logic get dmaReadAddr => output('dma_read_addr');
  Logic get dmaReadReq => output('dma_read_req');
  Logic get dmaReadData => input('dma_read_data');
  Logic get dmaReadValid => input('dma_read_valid');

  /// DMA write interface.
  Logic get dmaWriteAddr => output('dma_write_addr');
  Logic get dmaWriteData => output('dma_write_data');
  Logic get dmaWriteReq => output('dma_write_req');
  Logic get dmaWriteAck => input('dma_write_ack');

  HarborAudioController({
    required this.baseAddress,
    this.audioInterfaces = const [HarborAudioInterface.i2s],
    this.maxChannels = 2,
    this.sampleRates = const [44100, 48000, 96000, 192000],
    this.formats = const [HarborAudioFormat.s16le, HarborAudioFormat.s24le],
    this.hwCodecs = const [],
    this.hasSrc = false,
    this.txFifoDepth = 256,
    this.rxFifoDepth = 256,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborAudioController', name: name ?? 'audio') {
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

    // DMA
    addOutput('dma_read_addr', width: 32);
    addOutput('dma_read_req');
    createPort('dma_read_data', PortDirection.input, width: 32);
    createPort('dma_read_valid', PortDirection.input);
    addOutput('dma_write_addr', width: 32);
    addOutput('dma_write_data', width: 32);
    addOutput('dma_write_req');
    createPort('dma_write_ack', PortDirection.input);

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

    // Registers
    final ctrl = Logic(name: 'ctrl', width: 32);
    final clkCfg = Logic(name: 'clk_cfg', width: 32);
    final format = Logic(name: 'format', width: 32);
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

    // Codec capabilities bitmask
    var codecCaps = 0;
    for (final c in hwCodecs) {
      codecCaps |= 1 << c.index;
    }

    interrupt <= (intStatus & intEnable).or();

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
          format < Const(0, width: 32),
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
          mclkDiv < Const(4, width: 8),
          bclkDiv < Const(8, width: 8),
          mclkCounter < Const(0, width: 8),
          bclkCounter < Const(0, width: 8),
          bitCounter < Const(0, width: 6),
          output('mclk') < Const(0),
          output('bclk') < Const(0),
          output('lrclk') < Const(0),
          output('sdata_out') < Const(0),
          output('dma_read_req') < Const(0),
          output('dma_write_req') < Const(0),
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
              Case(bus.addr, [
                CaseItem(Const(0x00, width: 12), [
                  If(
                    bus.we,
                    then: [ctrl < bus.selMerge(ctrl, 0x00)],
                    orElse: [bus.dataOut < ctrl],
                  ),
                ]),
                CaseItem(Const(0x08, width: 12), [
                  // STATUS: read-only
                  bus.dataOut < Const(0, width: 32), // placeholder
                ]),
                CaseItem(Const(0x10, width: 12), [
                  If(
                    bus.we,
                    then: [clkCfg < bus.selMerge(clkCfg, 0x10)],
                    orElse: [bus.dataOut < clkCfg],
                  ),
                ]),
                CaseItem(Const(0x18, width: 12), [
                  If(
                    bus.we,
                    then: [format < bus.selMerge(format, 0x18)],
                    orElse: [bus.dataOut < format],
                  ),
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
                    then: [txDmaAddr < bus.selMerge(txDmaAddr, 0x30)],
                    orElse: [bus.dataOut < txDmaAddr],
                  ),
                ]),
                CaseItem(Const(0x38, width: 12), [
                  If(
                    bus.we,
                    then: [txDmaSize < bus.selMerge(txDmaSize, 0x38)],
                    orElse: [bus.dataOut < txDmaSize],
                  ),
                ]),
                CaseItem(Const(0x40, width: 12), [
                  If(
                    bus.we,
                    then: [txDmaWr < bus.selMerge(txDmaWr, 0x40)],
                    orElse: [bus.dataOut < txDmaWr],
                  ),
                ]),
                CaseItem(Const(0x48, width: 12), [bus.dataOut < txDmaRd]),
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
                // INT_STATUS (W1C)
                CaseItem(Const(0x70, width: 12), [
                  If(
                    bus.we,
                    then: [intStatus < (intStatus & ~bus.selMasked(0x70, 8))],
                    orElse: [bus.dataOut < intStatus.zeroExtend(32)],
                  ),
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
                // CODEC_CAPS
                CaseItem(Const(0x110, width: 12), [
                  bus.dataOut < Const(codecCaps, width: 32),
                ]),
              ]),
            ],
          ),
        ],
      ),
    ]);

    output('dma_read_addr') <= Const(0, width: 32);
    output('dma_write_addr') <= Const(0, width: 32);
    output('dma_write_data') <= Const(0, width: 32);
  }

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
