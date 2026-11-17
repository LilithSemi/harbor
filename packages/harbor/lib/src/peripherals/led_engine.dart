import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../arith/fpu_config.dart' show harborStableDefinitionName;
import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../bus/port/memory_port.dart';
import '../bus/port/memory_waist.dart';
import '../bus/port/reg_fifo.dart' show HarborFifoRam;
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import 'bram.dart' show HarborBram;
import 'led_engine_stage.dart';

/// The kind of output stage of one channel.
enum HarborLedKind { serial, pwm }

/// Where the pixel words come from.
enum HarborLedPixelSource { none, ram, dma }

/// The memory type of the pixel RAM.
enum HarborLedRamKind { lut, bram }

/// A byte of a pixel word.
enum HarborLedByte { r, g, b, w }

/// One PWM pin: the pixel and the byte that set its duty.
class HarborLedPin {
  final int pixel;
  final HarborLedByte byte;

  /// The highest duty that software may set on this pixel. The driver
  /// reports it as the brightness ceiling. A pixel with several pins uses
  /// the lowest value of its pins.
  final int maxDuty;
  const HarborLedPin(this.pixel, this.byte, {this.maxDuty = 255});
}

/// The configuration of one channel.
class HarborLedChannelConfig {
  final HarborLedKind kind;

  /// The pins of a PWM channel. Empty for a serial channel.
  final List<HarborLedPin> pwmPins;

  /// The reset value of the POLARITY bit.
  final bool activeLow;

  const HarborLedChannelConfig.serial({this.activeLow = false})
    : kind = HarborLedKind.serial,
      pwmPins = const [];

  const HarborLedChannelConfig.pwm(this.pwmPins, {this.activeLow = false})
    : kind = HarborLedKind.pwm;

  /// The number of pixels that the pin map reads, 0 for a serial channel.
  int get pixelsUsed =>
      pwmPins.fold(0, (n, p) => p.pixel + 1 > n ? p.pixel + 1 : n);
}

/// An RMT style pulse engine for addressable LEDs.
///
/// Each register sits in its own 64-bit-aligned slot, so a 32-bit access
/// lands in the low word on a 32-bit and a 64-bit fabric. The window is
/// 4 KiB.
///
/// Global registers:
/// - 0x000 INFO (RO): [3:0] channels, [7:4] pixel source, [15:8] log2 of the
///   item depth, [27:16] pixel count
/// - 0x008 DIV: tick = clk / (DIV + 1), 16 bits
/// - 0x010 IRQ_STATUS (W1C): bit ch train done, bit 8+ch frame tick
/// - 0x018 IRQ_ENABLE
/// - 0x020 to 0x0FF: reserved, reads 0
///
/// Channel ch registers at 0x100 + ch * 0x80:
/// - 0x00 CTRL: [0] SEND (self-clears; a SEND while BUSY starts one more
///   frame when BUSY drops), [1] MODE
///   (0 raw, 1 pixel), [2] POLARITY, [3] IDLE, [4] BPP (0 is 24 bits, 1 is
///   32 bits), [10:8] BYTE_ORDER (0 GRB, 1 RGB, 2 BRG, 3 RBG, 4 GBR, 5 BGR,
///   W last in 32 bit mode). A BYTE_ORDER of 6 or 7 is stored as 0. A SEND
///   in the same write as MODE uses the new MODE. Without a pixel source,
///   SEND with MODE 1 does nothing.
/// - 0x08 STATUS (RO): [0] BUSY, [1] UNDERRUN (set when the next item is not
///   ready at a tick, cleared by SEND), [2] DMA_ERR (a pixel fetch got a bus
///   error, cleared by SEND), [3] KIND (1 for pwm, 0 for serial), [4] STALL
///   (a dma frame took no first item for stallClocks clocks, cleared by
///   SEND, the frame goes on), [23:16]
///   completed trains
/// - 0x10 T0H, 0x18 T0L, 0x20 T1H, 0x28 T1L: 15 bits each
/// - 0x30 RESET: 20 bits, the gap after the last pixel in ticks
/// - 0x38 PIXEL_COUNT: bit width is the bit length of maxPixels. A value
///   above maxPixels sends maxPixels pixels. It is copied at SEND.
/// - 0x40 BASE_LO and 0x48 BASE_HI: the byte address of the first pixel word
///   of the dma source. Only the dma source has them, others read 0 and
///   ignore writes. BASE_LO bits 1:0 read 0. BASE_HI has the bits above 32
///   and exists only when dmaAddressWidth is more than 32. Do not write them
///   while BUSY.
/// - 0x50 REFRESH: 32 bits, the period of an automatic SEND in clocks, 0 is
///   off. A write restarts the count, so the first frame starts one period
///   after the write. A frame that is due while BUSY starts when BUSY drops.
///   A write of 0 does not cancel a frame that is already due, so one more
///   frame can start.
/// - 0x58 LOOP: 8 bits, repeats of the raw train
/// - 0x60 ITEM_START: log2 of the item depth bits, copied at SEND
/// - 0x68 STATE (RO): the index of the item on the pin, or the index of the
///   pixel that is sent when the last frame ran in pixel mode
///
/// A pwm channel has CTRL (SEND, POLARITY, and MODE which always reads 1),
/// STATUS and REFRESH. Its other registers read 0 and ignore writes. A frame
/// reads the pixel of each pin from the pixel window, one pin per clock, and
/// latches the byte of the pin map as its duty. The pixel source must be ram.
/// A shared 8-bit counter steps at each tick, so a duty of d gives d ticks
/// high in each 256 ticks. The duties of the pins change one after another
/// during the load.
///
/// The item window is at 0x400 (item i at 0x400 + 4 * i). A store writes an
/// item only when its byte select covers both item bytes. The pixel window is
/// at 0x800 (pixel p at 0x800 + 4 * p), 0xWWRRGGBB. Update pixels on
/// the done event (IRQ bit ch) or between frames, and not on FRAME_TICK.
/// Pixel 0 is read at frame start, and a pixel that the frame has not sent
/// yet shows the new value when it is written during the frame. With the
/// block RAM, a store writes a pixel only when its byte select covers all
/// four bytes. An unwritten pixel reads 0 through the initial value of the
/// memory. A flow with no memory initial value, such as an ASIC, needs the
/// pixels written before the first pixel SEND. A block RAM pays off only for
/// a large pixel count: 512 pixels of 32 bits fill one block.
///
/// The dma source reads PIXEL_COUNT words from BASE in each pixel frame,
/// through the master port `dma`. A read is a burst of up to 4 words inside
/// an aligned block of 4 words, and it starts only when the 4 word FIFO of
/// the channel has room for all its beats. The frame starts when the first
/// word arrives. STALL is set when no first item was taken stallClocks clocks
/// after the start. A later word that is not there in time gives UNDERRUN.
/// On a shared Wishbone bus the fetch needs a grant hold cap
/// (`maxGrantCycles` of buildFabric), or a master that keeps CYC high can
/// keep the fetch off the bus. A bus
/// error on a read sets DMA_ERR and the IRQ done bit, ends the frame, and the
/// pin goes to its idle level. The engine only reads, and a pwm channel needs
/// the ram source. A pixel RAM word is a pixel, so with the dma source the
/// pixel window reads 0 and ignores writes. With a data width of more than 32
/// bits, each beat is a 4 byte transfer.
///
/// A duty that changes during a PWM period gives one period with the wrong
/// high time.
///
/// All channels share one read port of the item RAM, which exists only when
/// a channel is serial. Without one the item window reads 0, ignores writes
/// and INFO gives an item depth of 0. A serial pixel reader goes before a pwm
/// load in the pixel RAM, because a pixel read has a deadline. A channel reads an item
/// at most once per tick and the channels read in index order. A bus read of
/// the item window waits one clock, then it goes before the channels. It
/// takes a clock from the channels at most once in every channel count plus
/// 1 clocks. The read of the first item of a train goes after every other read and
/// has no deadline. A train stays exact when (DIV + 1) * duration is at
/// least the channel count plus 1 in clocks for every item. Below that limit
/// a train of a channel with a higher index can start late, and no flag
/// shows it.
/// The item RAM is always LUT RAM, because a channel uses the item in the
/// clock in which it reads it.
class HarborLedEngine extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  static const int maxChannels = 6;
  static const int maxPwmPins = 16;

  final int baseAddress;
  final List<HarborLedChannelConfig> channels;
  final int itemDepth;
  final HarborLedPixelSource pixelSource;
  final int maxPixels;
  final HarborLedRamKind ramKind;

  /// Width of the register bus, 32 or 64. Registers sit in 8-byte slots and
  /// read in the low 32 bits. The item and pixel windows keep 4-byte strides,
  /// and the byte lanes pick the half of a 64-bit beat.
  final int busDataWidth;

  /// Clocks after which a dma frame that has taken no item sets STALL.
  final int stallClocks;

  /// The clock in Hz, written to the DT and ACPI `clock-frequency` property.
  final int? clockHz;

  /// The address width of the dma read master.
  final int dmaAddressWidth;

  /// False when a coprocessor owns the engine. The DT then has
  /// `harbor,owner = "coprocessor"` and the kernel driver configures nothing.
  final bool kernelOwned;

  late final BusSlavePort bus;

  Logic get interrupt => output('interrupt');

  /// The output pins of channel [ch]. A pwm channel has one pin for each
  /// entry of its pin map.
  List<Logic> channelOut(int ch) => _channelOut[ch];

  /// One clock high at each frame start, one bit per channel.
  Logic get frameTick => output('frame_tick');

  /// Diagnostics, 40 bits: bit ch is BUSY, bit 8+ch is the frame tick, bit
  /// 16+ch is UNDERRUN, bit 24+ch is DMA_ERR and bit 32+ch is STALL of
  /// channel ch.
  Logic get status => output('led_status');

  /// The pixel read master, present only for the dma pixel source.
  HarborMemoryMasterPort? get dma => _dma;
  HarborMemoryMasterPort? _dma;

  late final List<List<Logic>> _channelOut;

  int get _pixelCountInfo =>
      pixelSource == HarborLedPixelSource.none ? 0 : maxPixels;

  Iterable<HarborLedPin> get _pwmPins => [
    for (final c in channels) ...c.pwmPins,
  ];

  /// The pixels that the property lists cover. A build with a serial channel
  /// covers every pixel of the window.
  int get _listedPixels {
    if (channels.any((c) => c.kind == HarborLedKind.serial)) {
      return _pixelCountInfo;
    }
    return channels.fold(0, (n, c) => c.pixelsUsed > n ? c.pixelsUsed : n);
  }

  Iterable<HarborLedPin> _pinsOf(int p) => _pwmPins.where((x) => x.pixel == p);

  // Per pixel, 0 for RGB and 1 for a mono LED. A pwm pixel with one pin is
  // mono. Every other pixel is RGB.
  List<int> get _pixelColors => [
    for (var p = 0; p < _listedPixels; p++) _pinsOf(p).length == 1 ? 1 : 0,
  ];

  // Per pixel, the byte that a mono LED reads: 0 R, 1 G, 2 B, 3 W.
  List<int> get _pixelMonoByte => [
    for (var p = 0; p < _listedPixels; p++)
      _pinsOf(p).length == 1
          ? const {
              HarborLedByte.r: 0,
              HarborLedByte.g: 1,
              HarborLedByte.b: 2,
              HarborLedByte.w: 3,
            }[_pinsOf(p).single.byte]!
          : 2,
  ];

  List<int> get _pixelMaxBrightness => [
    for (var p = 0; p < _listedPixels; p++)
      _pwmPins
          .where((x) => x.pixel == p)
          .fold(255, (m, x) => x.maxDuty < m ? x.maxDuty : m),
  ];

  HarborLedEngine({
    required this.baseAddress,
    this.channels = const [HarborLedChannelConfig.serial()],
    this.itemDepth = 64,
    this.pixelSource = HarborLedPixelSource.ram,
    this.maxPixels = 16,
    this.ramKind = HarborLedRamKind.lut,
    this.clockHz,
    this.kernelOwned = true,
    HarborFabricKind fabricKind = HarborFabricKind.wishbone,
    bool crossFabricClock = false,
    this.dmaAddressWidth = 32,
    int dmaDataWidth = 32,
    int busAddressWidth = 12,
    this.busDataWidth = 32,
    this.stallClocks = 65536,
    String? name,
  }) : super(
         harborStableDefinitionName('HarborLedEngine', [
           ...BusSlavePort.definitionNameParts(
             kind: fabricKind,
             addressWidth: busAddressWidth,
             dataWidth: busDataWidth,
             cross: crossFabricClock,
           ),
           'ch${channels.length}',
           channels
               .map(
                 (c) => c.kind == HarborLedKind.pwm
                     ? 'w${c.activeLow ? 'l' : 'h'}'
                           '${c.pwmPins.map((p) => '${p.pixel}${p.byte.name}').join()}'
                     : (c.activeLow ? 'l' : 'h'),
               )
               .join('_'),
           'i$itemDepth',
           'p$maxPixels',
           pixelSource.name,
           if (pixelSource == HarborLedPixelSource.dma) ...[
             'a$dmaAddressWidth',
             'd$dmaDataWidth',
             's$stallClocks',
           ],
           ramKind.name,
         ]),
         name: name ?? 'led_engine',
       ) {
    if (stallClocks < 1 || stallClocks > 0xFFFFFF) {
      throw ArgumentError(
        'HarborLedEngine: stallClocks is from 1 to 16777215 (got $stallClocks).',
      );
    }
    if (busAddressWidth < 12 || busAddressWidth > 64) {
      throw ArgumentError(
        'HarborLedEngine: busAddressWidth must be from 12 to 64 '
        '(got $busAddressWidth).',
      );
    }
    if (busDataWidth != 32 && busDataWidth != 64) {
      throw ArgumentError(
        'HarborLedEngine: busDataWidth must be 32 or 64 (got $busDataWidth).',
      );
    }
    if (channels.isEmpty || channels.length > maxChannels) {
      throw ArgumentError(
        'HarborLedEngine: 1 to $maxChannels channels are supported '
        '(got ${channels.length}).',
      );
    }
    if (itemDepth < 2 || itemDepth > 256 || itemDepth & (itemDepth - 1) != 0) {
      throw ArgumentError(
        'HarborLedEngine: itemDepth must be a power of 2 from 2 to 256 '
        '(got $itemDepth).',
      );
    }
    if (maxPixels < 1 || maxPixels > 512) {
      throw ArgumentError(
        'HarborLedEngine: maxPixels must be from 1 to 512 (got $maxPixels).',
      );
    }
    for (final c in channels.where((c) => c.kind == HarborLedKind.pwm)) {
      if (c.pwmPins.isEmpty || c.pwmPins.length > maxPwmPins) {
        throw ArgumentError(
          'HarborLedEngine: a pwm channel has 1 to $maxPwmPins pins '
          '(got ${c.pwmPins.length}).',
        );
      }
      if (pixelSource != HarborLedPixelSource.ram) {
        throw ArgumentError(
          'HarborLedEngine: a pwm channel needs a ram source.',
        );
      }
      if (c.pixelsUsed > maxPixels) {
        throw ArgumentError(
          'HarborLedEngine: the pin map reads ${c.pixelsUsed} pixels and '
          'maxPixels is $maxPixels.',
        );
      }
    }
    if (pixelSource == HarborLedPixelSource.dma &&
        (dmaAddressWidth < 16 ||
            dmaAddressWidth > 64 ||
            ![32, 64, 128].contains(dmaDataWidth))) {
      throw ArgumentError(
        'HarborLedEngine: dmaAddressWidth is 16 to 64 and dmaDataWidth is 32, '
        '64 or 128 (got $dmaAddressWidth and $dmaDataWidth).',
      );
    }

    final n = channels.length;
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    addOutput('interrupt');
    addOutput('frame_tick', width: n);
    addOutput('led_status', width: 40);
    _channelOut = [
      for (var ch = 0; ch < n; ch++)
        channels[ch].kind == HarborLedKind.pwm
            ? [
                for (var i = 0; i < channels[ch].pwmPins.length; i++)
                  addOutput('led_ch${ch}_$i'),
              ]
            : [addOutput('led_ch$ch')],
    ];

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
      dataWidth: busDataWidth,
      fabricClock: fabricClock,
    );
    final hasDma = pixelSource == HarborLedPixelSource.dma;
    final dmaPort = hasDma
        ? HarborMemoryMasterPort.create(
            module: this,
            name: 'dma',
            kind: fabricKind,
            config: HarborMemoryWaistConfig(
              addressWidth: dmaAddressWidth,
              dataWidth: dmaDataWidth,
              idWidth: 1,
              outstanding: 1,
            ),
            clk: input('clk'),
            reset: input('reset'),
            fabricClock: fabricClock,
            readOnly: true,
          )
        : null;
    _dma = dmaPort;

    final clk = input('clk');
    final reset = bus.reset;
    final aw = itemDepth.bitLength - 1;
    final hasPixels = pixelSource == HarborLedPixelSource.ram;
    final hasPixelSrc = hasPixels || hasDma;
    final hasSerial = channels.any((c) => c.kind == HarborLedKind.serial);
    final isBram = hasPixels && ramKind == HarborLedRamKind.bram;
    final pixelAw = maxPixels > 1 ? (maxPixels - 1).bitLength : 1;
    // On a 64-bit bus the slave port clears address bit 2, so the byte lanes
    // say which 32-bit half a window access means. The register slots decode
    // the half as address bit 2, which a register never uses.
    final wide = busDataWidth == 64;
    final upper = wide
        ? (bus.sel.getRange(4, 8).or() & ~bus.sel.getRange(0, 4).or()).named(
            'upper_half',
          )
        : Const(0);
    final a = wide
        ? [bus.addr.getRange(3), upper, bus.addr.getRange(0, 2)].concat()
        : bus.addr;
    final sel32 = wide
        ? mux(upper, bus.sel.getRange(4, 8), bus.sel.getRange(0, 4))
        : bus.sel;
    final din32 = wide
        ? mux(upper, bus.dataIn.getRange(32, 64), bus.dataIn.getRange(0, 32))
        : bus.dataIn;
    Logic laneSel(int lane) => wide ? sel32[lane] : bus.selAny(lane, 1);
    Logic busWord(Logic v) => wide
        ? mux(
            upper,
            [v, Const(0, width: 32)].concat(),
            [Const(0, width: 32), v].concat(),
          )
        : v;
    final isPwm = [for (final c in channels) c.kind == HarborLedKind.pwm];

    // A block RAM pixel read gives its data one clock after the address.
    final pxPend = Logic(name: 'px_pend');
    final accessStart = bus.stb & ~bus.ack & ~pxPend;
    final busWr = accessStart & bus.we;
    final busRd = accessStart & ~bus.we;
    final inRegs = a.getRange(10, 12).eq(0);
    final inItems = a.getRange(10, 12).eq(1);
    final inPixels = a[11];
    final slotOk = a.getRange(0, 3).eq(0);
    final slot = a.getRange(3, 7);
    final region = a.getRange(7, 10);
    final globalSel = inRegs & slotOk & region.eq(0);
    final chanSel = [
      for (var c = 0; c < n; c++) inRegs & slotOk & region.eq(c + 2),
    ];
    Logic globalHit(int s) => globalSel & slot.eq(s);
    Logic chanHit(int c, int s) => chanSel[c] & slot.eq(s);

    // A 32-bit read value picked by the slot number, 0 for other slots.
    Logic slotRead(String nm, Map<int, Logic> regs) {
      final out = Logic(name: nm, width: 32);
      Combinational([
        Case(
          slot,
          [
            for (final e in regs.entries)
              CaseItem(Const(e.key, width: 4), [out < e.value.zeroExtend(32)]),
          ],
          defaultItem: [out < Const(0, width: 32)],
        ),
      ]);
      return out;
    }

    Logic bitsOf(List<Logic> bits) =>
        bits.length == 1 ? bits[0] : bits.rconcat();

    // Prescaler.
    final div = Logic(name: 'div', width: 16);
    final pcnt = Logic(name: 'pcnt', width: 16);
    final tick = pcnt.eq(0);
    Sequential(clk, [
      If(
        reset,
        then: [pcnt < Const(0, width: 16)],
        orElse: [
          If(tick, then: [pcnt < div], orElse: [pcnt < (pcnt - 1)]),
        ],
      ),
    ]);

    // The shared PWM counter, one step at each tick.
    final pwmCnt = Logic(name: 'pwm_cnt', width: 8);
    if (isPwm.contains(true)) {
      Sequential(clk, [
        If(
          reset,
          then: [pwmCnt < Const(0, width: 8)],
          orElse: [
            If(tick, then: [pwmCnt < (pwmCnt + 1)]),
          ],
        ),
      ]);
    }

    // Per channel registers. A pwm channel has only POLARITY and REFRESH,
    // and MODE always reads 1.
    Logic reg(String nm, int w) => Logic(name: nm, width: w);
    Logic serialReg(int c, String nm, int w) =>
        isPwm[c] ? Const(0, width: w) : reg('ch${c}_$nm', w);
    final mode = [
      for (var c = 0; c < n; c++) isPwm[c] ? Const(1) : reg('ch${c}_mode', 1),
    ];
    final pol = [for (var c = 0; c < n; c++) reg('ch${c}_pol', 1)];
    final idle = [for (var c = 0; c < n; c++) serialReg(c, 'idle', 1)];
    final bpp = [for (var c = 0; c < n; c++) serialReg(c, 'bpp', 1)];
    final order = [for (var c = 0; c < n; c++) serialReg(c, 'order', 3)];
    final timing = [
      for (var c = 0; c < n; c++)
        [for (var k = 0; k < 4; k++) serialReg(c, 't$k', 15)],
    ];
    final resetGap = [for (var c = 0; c < n; c++) serialReg(c, 'rst', 20)];
    final pixelCount = [
      for (var c = 0; c < n; c++) serialReg(c, 'pxn', maxPixels.bitLength),
    ];
    final dmaAw = hasDma ? dmaAddressWidth : 32;
    final baseLoW = (dmaAw > 32 ? 32 : dmaAw) - 2;
    final baseHiW = dmaAw - 32;
    final baseLo = [
      for (var c = 0; c < n; c++)
        hasDma ? reg('ch${c}_base_lo', baseLoW) : Const(0, width: 30),
    ];
    final baseHi = [
      for (var c = 0; c < n; c++)
        hasDma && baseHiW > 0 ? reg('ch${c}_base_hi', baseHiW) : null,
    ];
    final dmaStall = [
      for (var c = 0; c < n; c++)
        hasDma ? reg('ch${c}_dma_stall', 1) : Const(0),
    ];
    final dmaErr = [
      for (var c = 0; c < n; c++) hasDma ? reg('ch${c}_dma_err', 1) : Const(0),
    ];
    final refresh = [for (var c = 0; c < n; c++) reg('ch${c}_refresh', 32)];
    final loop = [for (var c = 0; c < n; c++) serialReg(c, 'loop', 8)];
    final itemStart = [for (var c = 0; c < n; c++) serialReg(c, 'istart', aw)];
    // Bits 0 to n-1 train done, bits n to 2n-1 frame tick.
    final irqStatus = reg('irq_status', 2 * n);
    final irqEnable = reg('irq_enable', 2 * n);
    Logic irqWord(Logic v) => [
      v.getRange(0, n),
      Const(0, width: 8 - n),
      v.getRange(n, 2 * n),
      Const(0, width: 8 - n),
    ].rconcat().zeroExtend(32);
    Logic irqFromWord(Logic w) =>
        [w.getRange(0, n), w.getRange(8, 8 + n)].rconcat();

    // Refresh: a counter in clocks, and a pending start that waits for BUSY.
    final refreshCnt = [for (var c = 0; c < n; c++) reg('ch${c}_rcnt', 32)];
    final refreshDue = [for (var c = 0; c < n; c++) reg('ch${c}_due', 1)];
    final sendBusy = [
      for (var c = 0; c < n; c++) Logic(name: 'ch${c}_sendbusy'),
    ];
    final refreshRestart = [
      for (var c = 0; c < n; c++) Logic(name: 'ch${c}_rrestart'),
    ];

    // Item RAM and the arbiter for its read port.
    final ramData = Logic(name: 'item_ram_data', width: 16);
    final itemGrant = [for (var c = 0; c < n; c++) Logic(name: 'ram_grant$c')];
    final startNow = [for (var c = 0; c < n; c++) Logic(name: 'start$c')];
    final runPixel = [
      for (var c = 0; c < n; c++)
        isPwm[c] ? Const(1) : Logic(name: 'run_pixel$c'),
    ];
    final modeNow = [for (var c = 0; c < n; c++) Logic(name: 'mode_now$c')];
    final expLevel = [for (var c = 0; c < n; c++) Logic(name: 'exp_level$c')];
    final expDur = [
      for (var c = 0; c < n; c++) Logic(name: 'exp_dur$c', width: 15),
    ];
    final expReady = [for (var c = 0; c < n; c++) Logic(name: 'exp_ready$c')];
    final pixelRdData = Logic(name: 'pixel_rd_data', width: 32);
    final pxGrant = [for (var c = 0; c < n; c++) Logic(name: 'px_grant$c')];
    final pxGrantQ = [for (var c = 0; c < n; c++) Logic(name: 'px_grant_q$c')];
    final pixelIndex = [
      for (var c = 0; c < n; c++)
        hasPixelSrc && !isPwm[c]
            ? Logic(name: 'pixel_index$c', width: maxPixels.bitLength)
            : Const(0, width: maxPixels.bitLength),
    ];
    final abortW = [for (var c = 0; c < n; c++) Logic(name: 'dma_abort$c')];
    final chs = [
      for (var c = 0; c < n; c++)
        if (isPwm[c])
          _ChSignals.pwm(c, aw)
        else
          _ChSignals.serial(
            HarborLedSerialChannel(
              clk: clk,
              reset: reset,
              tick: tick,
              send: startNow[c],
              polarity: pol[c],
              idle: idle[c],
              itemStart: itemStart[c],
              loop: mux(modeNow[c], Const(0, width: 8), loop[c]),
              ramData: hasPixelSrc
                  ? mux(runPixel[c], [expLevel[c], expDur[c]].concat(), ramData)
                  : ramData,
              ramGrant: hasPixelSrc
                  ? mux(runPixel[c], expReady[c], itemGrant[c])
                  : itemGrant[c],
              pixel: runPixel[c],
              abort: hasDma ? abortW[c] : Const(0),
              addrWidth: aw,
              activeLow: channels[c].activeLow,
              name: 'led_ch${c}_serial',
            ),
          ),
    ];

    final itemWindowOk = aw == 8 ? Const(1) : a.getRange(2 + aw, 10).eq(0);
    final busAged = Logic(name: 'bus_aged');
    final busCool = Logic(name: 'bus_cool', width: 3);
    final busItemRd = busRd & inItems;
    Logic anyReq = Const(0);
    Logic busWin = Const(0);
    Logic itemLose = Const(0);
    if (hasSerial) {
      final reqs = [
        for (var c = 0; c < n; c++) chs[c].ramCritical & ~runPixel[c],
      ];
      final lowReqs = [
        for (var c = 0; c < n; c++)
          chs[c].ramReq & ~chs[c].ramCritical & ~runPixel[c],
      ];
      anyReq = reqs.reduce((x, y) => x | y);
      // A bus item read that waited one clock goes before the channels. After
      // it took a clock from a channel, the channels go first for n clocks.
      // The read of the first item of a train has no deadline and goes last.
      busWin = busItemRd & busAged & busCool.eq(0);
      itemLose = busItemRd & anyReq & ~busWin;
      var arbAddr = chs[0].ramAddr;
      for (var c = n - 1; c >= 0; c--) {
        arbAddr = mux(reqs[c], chs[c].ramAddr, arbAddr);
      }
      var lowAddr = chs[0].ramAddr;
      for (var c = n - 1; c >= 0; c--) {
        lowAddr = mux(lowReqs[c], chs[c].ramAddr, lowAddr);
      }
      Logic noLower = ~busWin;
      Logic noLowerLow = ~anyReq & ~busItemRd;
      for (var c = 0; c < n; c++) {
        itemGrant[c] <= (reqs[c] & noLower) | (lowReqs[c] & noLowerLow);
        noLower = noLower & ~reqs[c];
        noLowerLow = noLowerLow & ~lowReqs[c];
      }
      final itemRam = HarborFifoRam(
        name: 'item_ram',
        clk: clk,
        wrEn: busWr & inItems & itemWindowOk & laneSel(0) & laneSel(1),
        wrAddr: a.getRange(2, 2 + aw),
        wrData: din32.getRange(0, 16),
        rdAddr: mux(
          anyReq & ~busWin,
          arbAddr,
          mux(busItemRd, a.getRange(2, 2 + aw), lowAddr),
        ),
        depth: itemDepth,
        zeroInit: true,
      );
      ramData <= itemRam.rdData;
    } else {
      ramData <= Const(0, width: 16);
    }

    // The pixel source: the pixel RAM, or the fetch of the dma source. The
    // expanders, the pwm banks and the bus share the read port of the RAM. A
    // serial expander goes before a pwm load, because a pixel read of an
    // expander has a deadline and a pwm load has none.
    final banks = List<HarborLedPwmBank?>.filled(n, null);
    final dmaWord = [
      for (var c = 0; c < n; c++) Logic(name: 'dma_word$c', width: 32),
    ];
    final dmaGrant = [for (var c = 0; c < n; c++) Logic(name: 'dma_grant$c')];
    final dmaPop = [for (var c = 0; c < n; c++) Logic(name: 'dma_pop$c')];
    final dmaTotal = [
      for (var c = 0; c < n; c++)
        Logic(name: 'dma_total$c', width: maxPixels.bitLength),
    ];
    final dmaBeat = Logic(name: 'dma_beat');
    final dmaAccept = [for (var c = 0; c < n; c++) Logic(name: 'dma_acc$c')];
    final dmaRvalid = [for (var c = 0; c < n; c++) Logic(name: 'dma_rv$c')];
    Logic pixelRead = Const(0, width: 32);
    Logic pixelLose = Const(0);
    if (hasPixelSrc) {
      final expanders = <HarborLedPixelExpander?>[
        for (var c = 0; c < n; c++)
          isPwm[c]
              ? null
              : HarborLedPixelExpander(
                  clk: clk,
                  reset: reset,
                  start: startNow[c] & modeNow[c],
                  busy: chs[c].busy,
                  advance: chs[c].fetched,
                  bpp: bpp[c],
                  order: order[c],
                  timing: timing[c],
                  resetGap: resetGap[c],
                  count: pixelCount[c],
                  pxData: hasDma ? dmaWord[c] : pixelRdData,
                  pxGrant: hasDma ? dmaGrant[c] : pxGrant[c],
                  pxValid: hasDma
                      ? dmaGrant[c]
                      : (isBram ? pxGrantQ[c] : pxGrant[c]),
                  maxPixels: maxPixels,
                  pixelAddrWidth: pixelAw,
                  name: 'led_ch${c}_pixels',
                ),
      ];
      for (var c = 0; c < n; c++) {
        if (isPwm[c]) {
          final bank = HarborLedPwmBank(
            clk: clk,
            reset: reset,
            start: startNow[c],
            polarity: pol[c],
            counter: pwmCnt,
            pxData: pixelRdData,
            pxGrant: pxGrant[c],
            pxValid: isBram ? pxGrantQ[c] : pxGrant[c],
            pwmPins: channels[c].pwmPins,
            pixelAddrWidth: pixelAw,
            registeredRead: isBram,
            activeLow: channels[c].activeLow,
            name: 'led_ch${c}_pwm',
          );
          banks[c] = bank;
          chs[c].busy <= bank.busy;
          chs[c].done <= bank.done;
          chs[c].frameCount <= bank.frameCount;
        } else {
          final e = expanders[c]!;
          expLevel[c] <= e.level;
          expDur[c] <= e.dur;
          expReady[c] <= e.ready;
          pixelIndex[c] <= e.index;
          dmaPop[c] <= e.pxReq;
          dmaTotal[c] <= e.total;
        }
      }
      if (hasDma) {
        final mem = dmaPort!.waist;
        final chBits = n > 1 ? (n - 1).bitLength : 1;
        final ownValid = Logic(name: 'dma_own_valid');
        final sent = Logic(name: 'dma_sent');
        final own = Logic(name: 'dma_own', width: chBits);
        final ownIs = [
          for (var c = 0; c < n; c++)
            ownValid & own.eq(Const(c, width: chBits)),
        ];
        final fetches = [
          for (var c = 0; c < n; c++)
            HarborLedDmaFetch(
              clk: clk,
              reset: reset,
              start: startNow[c] & modeNow[c],
              total: dmaTotal[c],
              base: baseHi[c] == null
                  ? baseLo[c]
                  : [baseHi[c]!, baseLo[c]].concat(),
              accepted: dmaAccept[c],
              rvalid: dmaRvalid[c],
              rdata: mem.rdataData,
              rerr: mem.rdataErr,
              rlast: mem.rdataLast,
              popReq: dmaPop[c],
              addressWidth: dmaAddressWidth,
              dataWidth: dmaDataWidth,
              maxPixels: maxPixels,
              name: 'led_ch${c}_fetch',
            ),
        ];
        Logic pickOwn(List<Logic> v) {
          var r = v[0];
          for (var c = 1; c < n; c++) {
            r = mux(own.eq(Const(c, width: chBits)), v[c], r);
          }
          return r;
        }

        final reqs = [for (final f in fetches) f.req];
        final reqAny = reqs.reduce((x, y) => x | y);
        // The next owner is the first requester after the last owner.
        Logic pickFrom(int o) {
          Logic r = Const(o, width: chBits);
          for (var k = n; k >= 1; k--) {
            final c = (o + k) % n;
            r = mux(reqs[c], Const(c, width: chBits), r);
          }
          return r;
        }

        Logic pickNext = pickFrom(0);
        for (var o = 1; o < n; o++) {
          pickNext = mux(
            own.eq(Const(o, width: chBits)),
            pickFrom(o),
            pickNext,
          );
        }
        final ownReq = pickOwn(reqs);
        final handshake = mem.reqValid & mem.reqReady;
        mem.reqValid <= ownValid & ~sent & ownReq;
        mem.reqId <= Const(0, width: mem.config.idWidth);
        mem.reqWrite <= Const(0);
        mem.reqAddr <= pickOwn([for (final f in fetches) f.reqAddr]);
        mem.reqLen <=
            [
              Const(0, width: HarborMemoryWaistConfig.lenWidth - 2),
              pickOwn([for (final f in fetches) f.reqLen]),
            ].concat();
        mem.reqSize <= Const(2, width: HarborMemoryWaistConfig.sizeWidth);
        mem.reqBurst <=
            Const(
              HarborMemoryBurst.incr.value,
              width: HarborMemoryWaistConfig.burstWidth,
            );
        mem.reqExclusive <= Const(0);
        mem.wdataValid <= Const(0);
        mem.wdataData <= Const(0, width: mem.config.dataWidth);
        mem.wdataStrb <= Const(0, width: mem.config.strbWidth);
        mem.wdataLast <= Const(0);
        mem.rdataReady <= ownValid & sent;
        mem.wrespReady <= Const(0);
        dmaBeat <= mem.rdataValid & mem.rdataReady;
        for (var c = 0; c < n; c++) {
          dmaAccept[c] <= handshake & ownIs[c];
          dmaRvalid[c] <= dmaBeat & ownIs[c];
          dmaWord[c] <= fetches[c].word;
          dmaGrant[c] <= fetches[c].grant;
          abortW[c] <= fetches[c].abort;
        }
        // A frame whose first item is not taken after stallClocks clocks sets
        // STALL. The frame goes on.
        final sw = stallClocks.bitLength;
        final stallCnt = [
          for (var c = 0; c < n; c++) Logic(name: 'dma_stall_cnt$c', width: sw),
        ];
        final stallArmed = [
          for (var c = 0; c < n; c++) Logic(name: 'dma_stall_armed$c'),
        ];
        for (var c = 0; c < n; c++) {
          final hit =
              stallArmed[c] & stallCnt[c].eq(Const(stallClocks, width: sw));
          Sequential(clk, [
            If(
              reset,
              then: [
                stallCnt[c] < Const(0, width: sw),
                stallArmed[c] < 0,
                dmaStall[c] < 0,
              ],
              orElse: [
                If(
                  ~chs[c].busy | chs[c].started | hit,
                  then: [stallArmed[c] < 0],
                  orElse: [stallCnt[c] < (stallCnt[c] + 1)],
                ),
                If(hit, then: [dmaStall[c] < 1]),
                If(
                  startNow[c] & modeNow[c],
                  then: [
                    stallArmed[c] < 1,
                    stallCnt[c] < Const(0, width: sw),
                  ],
                ),
                If(startNow[c] | sendBusy[c], then: [dmaStall[c] < 0]),
              ],
            ),
          ]);
        }
        Sequential(clk, [
          If(
            reset,
            then: [
              ownValid < 0,
              sent < 0,
              own < Const(0, width: chBits),
            ],
            orElse: [
              If(
                ~ownValid & reqAny,
                then: [ownValid < 1, own < pickNext, sent < 0],
              ),
              If(ownValid & ~sent & ~ownReq, then: [ownValid < 0]),
              If(handshake, then: [sent < 1]),
              If(dmaBeat & mem.rdataLast, then: [ownValid < 0, sent < 0]),
            ],
          ),
        ]);
      }
      if (hasPixels) {
        final pixelWindowOk = maxPixels >= 512
            ? Const(1)
            : a.getRange(2, 11).lt(Const(maxPixels, width: 9));
        final pixelIdx = a.getRange(2, 2 + pixelAw);
        final prio = [
          for (var c = 0; c < n; c++)
            if (!isPwm[c]) c,
          for (var c = 0; c < n; c++)
            if (isPwm[c]) c,
        ];
        final pxReqs = [
          for (var c = 0; c < n; c++)
            isPwm[c] ? banks[c]!.pxReq : expanders[c]!.pxReq,
        ];
        final pxAddrs = [
          for (var c = 0; c < n; c++)
            isPwm[c] ? banks[c]!.pxAddr : expanders[c]!.pxAddr,
        ];
        final anyPxReq = pxReqs.reduce((x, y) => x | y);
        var pxAddr = pxAddrs[prio.first];
        for (var i = n - 1; i >= 0; i--) {
          pxAddr = mux(pxReqs[prio[i]], pxAddrs[prio[i]], pxAddr);
        }
        Logic pxNoLower = Const(1);
        for (final c in prio) {
          pxGrant[c] <= pxReqs[c] & pxNoLower;
          pxNoLower = pxNoLower & ~pxReqs[c];
        }
        pixelLose = (busRd | busWr) & inPixels & anyPxReq;
        final pixelRdAddr = mux(anyPxReq, pxAddr, pixelIdx);
        final pixelWrEn = accessStart & ~pixelLose & bus.we & inPixels;
        if (isBram) {
          final pixelRam = HarborBram(
            clk,
            name: 'pixel_ram',
            width: 32,
            depth: maxPixels,
            wrEn:
                ~reset &
                pixelWrEn &
                pixelWindowOk &
                laneSel(0) &
                laneSel(1) &
                laneSel(2) &
                laneSel(3),
            wrAddr: pixelIdx,
            wrData: din32,
            rdAddr: pixelRdAddr,
            zeroInit: true,
          );
          pixelRdData <= pixelRam.rdData;
        } else {
          final pixelOld = Logic(name: 'pixel_old', width: 32);
          final pixelRam = HarborFifoRam(
            name: 'pixel_ram',
            clk: clk,
            wrEn: pixelWrEn & pixelWindowOk & sel32.getRange(0, 4).or(),
            wrAddr: pixelIdx,
            wrData: wide
                ? [
                    for (var b = 3; b >= 0; b--)
                      mux(
                        sel32[b],
                        din32.getRange(8 * b, 8 * b + 8),
                        pixelOld.getRange(8 * b, 8 * b + 8),
                      ),
                  ].concat()
                : bus.selMerge(pixelOld, 0),
            rdAddr: pixelRdAddr,
            depth: maxPixels,
            zeroInit: true,
          );
          pixelOld <= pixelRam.rdData;
          pixelRdData <= pixelRam.rdData;
        }
        pixelRead = mux(
          inPixels & pixelWindowOk,
          pixelRdData,
          Const(0, width: 32),
        );
      }
    }
    final busStall = itemLose | pixelLose;

    final irqClear = mux(
      busWr & globalHit(2),
      irqFromWord(bus.selMasked(0x10, 16)),
      Const(0, width: 2 * n),
    );
    final ftQ = [for (var c = 0; c < n; c++) Logic(name: 'frame_tick_q$c')];
    final doneBits = [
      bitsOf([for (final ch in chs) ch.done]),
      bitsOf(ftQ),
    ].rconcat();
    interrupt <= (irqStatus & irqEnable).or();

    // Register writes.
    final writes = <Conditional>[];
    void wr(Logic hit, Logic r, int off) => writes.add(
      If(
        busWr & hit & bus.selAny(off, (r.width + 7) ~/ 8),
        then: [r < bus.selMerge(r, off)],
      ),
    );
    wr(globalHit(1), div, 0x08);
    writes.add(
      If(
        busWr & globalHit(3) & bus.selAny(0x18, 2),
        then: [irqEnable < irqFromWord(bus.selMerge(irqWord(irqEnable), 0x18))],
      ),
    );
    for (var c = 0; c < n; c++) {
      final ctrlHit = chanHit(c, 0);
      writes.add(
        If(
          busWr & ctrlHit & bus.selAny(0x00, 1),
          then: [
            if (!isPwm[c]) ...[
              mode[c] < bus.dataIn[1],
              idle[c] < bus.dataIn[3],
              bpp[c] < bus.dataIn[4],
            ],
            pol[c] < bus.dataIn[2],
          ],
        ),
      );
      final newOrder = bus.dataIn.getRange(8, 11);
      if (!isPwm[c]) {
        writes.add(
          If(
            busWr & ctrlHit & bus.selAny(0x01, 1),
            then: [
              order[c] <
                  mux(
                    newOrder.gte(Const(6, width: 3)),
                    Const(0, width: 3),
                    newOrder,
                  ),
            ],
          ),
        );
      }
      // MODE and SEND are taken from the same write.
      final ctrlWr = busWr & ctrlHit & bus.selAny(0x00, 1);
      modeNow[c] <= (isPwm[c] ? Const(1) : mux(ctrlWr, bus.dataIn[1], mode[c]));
      final startOk = hasPixelSrc ? Const(1) : ~modeNow[c];
      startNow[c] <=
          ((ctrlWr & bus.dataIn[0]) | refreshDue[c]) & ~chs[c].busy & startOk;
      sendBusy[c] <= ctrlWr & bus.dataIn[0] & chs[c].busy & startOk;
      refreshRestart[c] <= busWr & chanHit(c, 10) & bus.selAny(0x50, 4);
      wr(chanHit(c, 10), refresh[c], 0x50);
      if (isPwm[c]) continue;
      if (hasDma) {
        writes.add(
          If(
            busWr & chanHit(c, 8) & bus.selAny(0x40, 4),
            then: [
              baseLo[c] <
                  bus
                      .selMerge([baseLo[c], Const(0, width: 2)].concat(), 0x40)
                      .getRange(2, baseLoW + 2),
            ],
          ),
        );
        if (baseHi[c] != null) wr(chanHit(c, 9), baseHi[c]!, 0x48);
      }
      for (var k = 0; k < 4; k++) {
        wr(chanHit(c, 2 + k), timing[c][k], 0x10 + 8 * k);
      }
      wr(chanHit(c, 6), resetGap[c], 0x30);
      wr(chanHit(c, 7), pixelCount[c], 0x38);
      wr(chanHit(c, 11), loop[c], 0x58);
      wr(chanHit(c, 12), itemStart[c], 0x60);
    }

    // Register reads.
    final globalRead = slotRead('global_read', {
      0: [
        Const(n, width: 4),
        Const(pixelSource.index, width: 4),
        Const(hasSerial ? aw : 0, width: 8),
        Const(_pixelCountInfo, width: 12),
        Const(0, width: 4),
      ].rconcat(),
      1: div,
      2: irqWord(irqStatus),
      3: irqWord(irqEnable),
    });
    Logic gate(Logic hit, Logic v) => mux(hit, v, Const(0, width: 32));
    final reads = <Logic>[
      gate(globalSel, globalRead),
      hasSerial
          ? gate(inItems & itemWindowOk, ramData.zeroExtend(32))
          : Const(0, width: 32),
      pixelRead,
    ];
    for (var c = 0; c < n; c++) {
      final chRead = slotRead('ch${c}_read', {
        0: [
          Const(0),
          mode[c],
          pol[c],
          idle[c],
          bpp[c],
          Const(0, width: 3),
          order[c],
          Const(0, width: 21),
        ].rconcat(),
        1: [
          chs[c].busy,
          chs[c].underrun,
          dmaErr[c],
          Const(isPwm[c] ? 1 : 0),
          dmaStall[c],
          Const(0, width: 11),
          chs[c].frameCount,
          Const(0, width: 8),
        ].rconcat(),
        for (var k = 0; k < 4; k++) 2 + k: timing[c][k],
        6: resetGap[c],
        7: pixelCount[c],
        if (hasDma) 8: [baseLo[c], Const(0, width: 2)].concat(),
        if (baseHi[c] != null) 9: baseHi[c]!,
        10: refresh[c],
        11: loop[c],
        12: itemStart[c],
        13: mux(
          runPixel[c],
          pixelIndex[c].zeroExtend(16),
          chs[c].state.zeroExtend(16),
        ),
      });
      reads.add(gate(chanSel[c], chRead));
    }
    final readValue = reads.reduce((x, y) => x | y);

    Sequential(clk, [
      If(
        reset,
        then: [
          div < Const(0, width: 16),
          irqStatus < Const(0, width: 2 * n),
          irqEnable < Const(0, width: 2 * n),
          for (var c = 0; c < n; c++) ...[
            pol[c] < (channels[c].activeLow ? 1 : 0),
            refresh[c] < Const(0, width: 32),
            if (!isPwm[c]) ...[
              mode[c] < 0,
              idle[c] < 0,
              bpp[c] < 0,
              order[c] < Const(0, width: 3),
              for (var k = 0; k < 4; k++) timing[c][k] < Const(0, width: 15),
              resetGap[c] < Const(0, width: 20),
              pixelCount[c] < Const(0, width: maxPixels.bitLength),
              loop[c] < Const(0, width: 8),
              itemStart[c] < Const(0, width: aw),
            ],
            if (hasDma) ...[
              baseLo[c] < Const(0, width: baseLoW),
              if (baseHi[c] != null) baseHi[c]! < Const(0, width: baseHiW),
              dmaErr[c] < 0,
            ],
          ],
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: busDataWidth),
          pxPend < 0,
          if (hasSerial) ...[busAged < 0, busCool < Const(0, width: 3)],
          for (var c = 0; c < n; c++) ...[
            if (!isPwm[c]) runPixel[c] < 0,
            ftQ[c] < 0,
            if (hasPixels) pxGrantQ[c] < 0,
            refreshCnt[c] < Const(0, width: 32),
            refreshDue[c] < 0,
          ],
        ],
        orElse: [
          irqStatus < ((irqStatus & ~irqClear) | doneBits),
          ...writes,
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: busDataWidth),
          if (hasSerial) ...[
            busAged < itemLose,
            If(
              busWin & anyReq,
              then: [busCool < Const(n, width: 3)],
              orElse: [
                If(busCool.neq(0), then: [busCool < (busCool - 1)]),
              ],
            ),
          ],
          pxPend < 0,
          for (var c = 0; c < n; c++) ...[
            ftQ[c] < startNow[c],
            if (hasPixels) pxGrantQ[c] < pxGrant[c],
            if (hasDma && !isPwm[c]) ...[
              If(startNow[c], then: [dmaErr[c] < 0]),
              If(abortW[c], then: [dmaErr[c] < 1]),
            ],
            if (!isPwm[c]) If(startNow[c], then: [runPixel[c] < modeNow[c]]),
            If(startNow[c], then: [refreshDue[c] < 0]),
            If(sendBusy[c], then: [refreshDue[c] < 1]),
            If(
              refreshRestart[c] | refresh[c].eq(0),
              then: [refreshCnt[c] < Const(0, width: 32)],
              orElse: [
                If(
                  (refreshCnt[c] + 1).eq(refresh[c]),
                  then: [
                    refreshCnt[c] < Const(0, width: 32),
                    refreshDue[c] < 1,
                  ],
                  orElse: [refreshCnt[c] < (refreshCnt[c] + 1)],
                ),
              ],
            ),
          ],
          // A channel read goes first, once the bus read has waited one
          // clock, so a bus read of the item window waits at most one clock.
          If(
            accessStart & ~busStall,
            then: [
              If(
                isBram ? busRd & inPixels : Const(0),
                then: [pxPend < 1],
                orElse: [
                  bus.ack < Const(1),
                  If(~bus.we, then: [bus.dataOut < busWord(readValue)]),
                ],
              ),
            ],
          ),
          If(
            pxPend,
            then: [bus.ack < Const(1), bus.dataOut < busWord(readValue)],
          ),
        ],
      ),
    ]);

    output('frame_tick') <= bitsOf(ftQ);
    output('led_status') <=
        [
          for (var b = 0; b < 40; b++)
            b % 8 < n
                ? switch (b ~/ 8) {
                    0 => chs[b % 8].busy,
                    1 => ftQ[b % 8],
                    2 => chs[b % 8].underrun,
                    3 => dmaErr[b % 8],
                    _ => dmaStall[b % 8],
                  }
                : Const(0),
        ].rconcat();
    for (var c = 0; c < n; c++) {
      if (isPwm[c]) {
        for (var i = 0; i < channels[c].pwmPins.length; i++) {
          _channelOut[c][i] <= banks[c]!.pins[i];
        }
      } else {
        _channelOut[c][0] <= chs[c].pin;
      }
    }
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,led-engine'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: _properties,
  );

  Map<String, Object> get _properties => {
    'channels': channels.length,
    'harbor,kinds': [for (final c in channels) c.kind.name],
    'harbor,pixel-count': _pixelCountInfo,
    'harbor,pixel-source': pixelSource.name,
    if (_pixelCountInfo > 0) ...{
      'harbor,pixel-colors': _pixelColors,
      'harbor,pixel-mono-byte': _pixelMonoByte,
      'harbor,pixel-max-brightness': _pixelMaxBrightness,
    },
    if (clockHz != null) 'clock-frequency': clockHz!,
    if (pixelSource == HarborLedPixelSource.dma)
      'harbor,dma-address-width': dmaAddressWidth,
    if (!kernelOwned) 'harbor,owner': 'coprocessor',
  };

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,led-engine'],
      ..._properties,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'LED',
    groupName: 'LED',
    description: 'RMT style LED pulse engine',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}

/// The signals of one channel that the engine reads, for either kind.
class _ChSignals {
  final Logic busy;
  final Logic done;
  final Logic underrun;
  final Logic ramReq;
  final Logic started;
  final Logic ramCritical;
  final Logic fetched;
  final Logic ramAddr;
  final Logic frameCount;
  final Logic state;
  final Logic pin;

  _ChSignals.serial(HarborLedSerialChannel ch)
    : busy = ch.busy,
      done = ch.done,
      underrun = ch.underrun,
      ramReq = ch.ramReq,
      started = ch.started,
      ramCritical = ch.ramCritical,
      fetched = ch.fetched,
      ramAddr = ch.ramAddr,
      frameCount = ch.frameCount,
      state = ch.state,
      pin = ch.pin;

  // The busy, done and frame count wires are driven by the pwm bank.
  _ChSignals.pwm(int c, int addrWidth)
    : busy = Logic(name: 'ch${c}_pwm_busy'),
      done = Logic(name: 'ch${c}_pwm_done'),
      underrun = Const(0),
      ramReq = Const(0),
      started = Const(0),
      ramCritical = Const(0),
      fetched = Const(0),
      ramAddr = Const(0, width: addrWidth),
      frameCount = Logic(name: 'ch${c}_pwm_frames', width: 8),
      state = Const(0, width: addrWidth),
      pin = Const(0);
}
