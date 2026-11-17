import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../arith/fpu_config.dart' show harborStableDefinitionName;
import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../bus/port/memory_port.dart';
import '../bus/port/reg_fifo.dart' show HarborFifoRam;
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
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
  const HarborLedPin(this.pixel, this.byte);
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
/// - 0x00 CTRL: [0] SEND (self-clears, ignored while BUSY or when MODE is 1
///   in the same write), [1] MODE, [2] POLARITY, [3] IDLE, [4] BPP,
///   [10:8] BYTE_ORDER. A BYTE_ORDER of 6 or 7 is stored as 0.
/// - 0x08 STATUS (RO): [0] BUSY, [1] UNDERRUN (set when the next item is not
///   ready at a tick, cleared by SEND), [23:16] completed trains
/// - 0x10 T0H, 0x18 T0L, 0x20 T1H, 0x28 T1L: 15 bits each
/// - 0x30 RESET: 20 bits
/// - 0x38 PIXEL_COUNT: bit width is the bit length of maxPixels
/// - 0x40 BASE_LO and 0x48 BASE_HI: only the dma source has them, others
///   read 0
/// - 0x50 REFRESH: 32 bits
/// - 0x58 LOOP: 8 bits, repeats of the raw train
/// - 0x60 ITEM_START: log2 of the item depth bits, copied at SEND
/// - 0x68 STATE (RO): the index of the item on the pin
///
/// The item window is at 0x400 (item i at 0x400 + 4 * i). A store writes an
/// item only when its byte select covers both item bytes. The pixel window is
/// at 0x800 (pixel p at 0x800 + 4 * p).
///
/// All channels share one read port of the item RAM. A channel reads an item
/// at most once per tick and the channels read in index order, so a train
/// stays exact when (DIV + 1) * duration is at least the channel count in
/// clocks for every item. A bus read of the item window waits while a
/// channel reads.
class HarborLedEngine extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  static const int maxChannels = 6;

  final int baseAddress;
  final List<HarborLedChannelConfig> channels;
  final int itemDepth;
  final HarborLedPixelSource pixelSource;
  final int maxPixels;
  final HarborLedRamKind ramKind;

  /// The clock in Hz, written to the DT and ACPI `clock-frequency` property.
  final int? clockHz;

  late final BusSlavePort bus;

  Logic get interrupt => output('interrupt');

  /// The output pins of channel [ch].
  List<Logic> channelOut(int ch) => _channelOut[ch];

  /// One clock high at each frame start, one bit per channel.
  Logic get frameTick => output('frame_tick');

  /// Diagnostics, 24 bits: bit ch is BUSY, bit 8+ch is the frame tick and
  /// bit 16+ch is UNDERRUN of channel ch.
  Logic get status => output('led_status');

  /// The pixel read master, present only for the dma pixel source.
  HarborMemoryMasterPort? get dma => null;

  late final List<List<Logic>> _channelOut;

  int get _pixelCountInfo =>
      pixelSource == HarborLedPixelSource.none ? 0 : maxPixels;

  HarborLedEngine({
    required this.baseAddress,
    this.channels = const [HarborLedChannelConfig.serial()],
    this.itemDepth = 64,
    this.pixelSource = HarborLedPixelSource.ram,
    this.maxPixels = 16,
    this.ramKind = HarborLedRamKind.lut,
    this.clockHz,
    HarborFabricKind fabricKind = HarborFabricKind.wishbone,
    bool crossFabricClock = false,
    int dmaAddressWidth = 32,
    int dmaDataWidth = 32,
    String? name,
  }) : super(
         harborStableDefinitionName('HarborLedEngine', [
           ...BusSlavePort.definitionNameParts(
             kind: fabricKind,
             addressWidth: 12,
             dataWidth: 32,
             cross: crossFabricClock,
           ),
           'ch${channels.length}',
           channels.map((c) => c.activeLow ? 'l' : 'h').join(),
           'i$itemDepth',
           'p$maxPixels',
           pixelSource.name,
           ramKind.name,
         ]),
         name: name ?? 'led_engine',
       ) {
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
    if (channels.any((c) => c.kind != HarborLedKind.serial)) {
      throw UnsupportedError(
        'HarborLedEngine: pwm channels are not built yet.',
      );
    }
    if (pixelSource == HarborLedPixelSource.dma) {
      throw UnsupportedError(
        'HarborLedEngine: the dma source is not built yet.',
      );
    }
    if (ramKind != HarborLedRamKind.lut) {
      throw UnsupportedError('HarborLedEngine: only the lut RAM is built.');
    }

    final n = channels.length;
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    addOutput('interrupt');
    addOutput('frame_tick', width: n);
    addOutput('led_status', width: 24);
    _channelOut = [
      for (var ch = 0; ch < n; ch++) [addOutput('led_ch$ch')],
    ];

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      kind: fabricKind,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: 12,
      dataWidth: 32,
      fabricClock: BusSlavePort.fabricClockInputs(
        this,
        cross: crossFabricClock,
      ),
    );

    final clk = input('clk');
    final reset = bus.reset;
    final aw = itemDepth.bitLength - 1;
    final hasPixels = pixelSource == HarborLedPixelSource.ram;
    final pixelAw = maxPixels > 1 ? (maxPixels - 1).bitLength : 1;
    final a = bus.addr;

    final accessStart = bus.stb & ~bus.ack;
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

    // Per channel registers.
    Logic reg(String nm, int w) => Logic(name: nm, width: w);
    final mode = [for (var c = 0; c < n; c++) reg('ch${c}_mode', 1)];
    final pol = [for (var c = 0; c < n; c++) reg('ch${c}_pol', 1)];
    final idle = [for (var c = 0; c < n; c++) reg('ch${c}_idle', 1)];
    final bpp = [for (var c = 0; c < n; c++) reg('ch${c}_bpp', 1)];
    final order = [for (var c = 0; c < n; c++) reg('ch${c}_order', 3)];
    final timing = [
      for (var c = 0; c < n; c++)
        [for (var k = 0; k < 4; k++) reg('ch${c}_t$k', 15)],
    ];
    final resetGap = [for (var c = 0; c < n; c++) reg('ch${c}_rst', 20)];
    final pixelCount = [
      for (var c = 0; c < n; c++) reg('ch${c}_pxn', maxPixels.bitLength),
    ];
    final refresh = [for (var c = 0; c < n; c++) reg('ch${c}_refresh', 32)];
    final loop = [for (var c = 0; c < n; c++) reg('ch${c}_loop', 8)];
    final itemStart = [for (var c = 0; c < n; c++) reg('ch${c}_istart', aw)];
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

    // Item RAM and the arbiter for its read port.
    final ramData = Logic(name: 'item_ram_data', width: 16);
    final grant = [for (var c = 0; c < n; c++) Logic(name: 'ram_grant$c')];
    final sendPulse = [for (var c = 0; c < n; c++) Logic(name: 'send$c')];
    final channelsRtl = [
      for (var c = 0; c < n; c++)
        HarborLedSerialChannel(
          clk: clk,
          reset: reset,
          tick: tick,
          send: sendPulse[c],
          polarity: pol[c],
          idle: idle[c],
          itemStart: itemStart[c],
          loop: loop[c],
          ramData: ramData,
          ramGrant: grant[c],
          addrWidth: aw,
          activeLow: channels[c].activeLow,
          name: 'led_ch${c}_serial',
        ),
    ];

    final itemWindowOk = aw == 8 ? Const(1) : a.getRange(2 + aw, 10).eq(0);
    final reqs = [for (final ch in channelsRtl) ch.ramReq];
    final anyReq = reqs.reduce((x, y) => x | y);
    var arbAddr = channelsRtl[0].ramAddr;
    for (var c = n - 1; c >= 0; c--) {
      arbAddr = mux(reqs[c], channelsRtl[c].ramAddr, arbAddr);
    }
    Logic noLower = Const(1);
    for (var c = 0; c < n; c++) {
      grant[c] <= reqs[c] & noLower;
      noLower = noLower & ~reqs[c];
    }
    final busItemRd = busRd & inItems;
    final busStall = busItemRd & anyReq;
    final itemRam = HarborFifoRam(
      name: 'item_ram',
      clk: clk,
      wrEn:
          busWr & inItems & itemWindowOk & bus.selAny(0, 1) & bus.selAny(1, 1),
      wrAddr: a.getRange(2, 2 + aw),
      wrData: bus.dataIn.getRange(0, 16),
      rdAddr: mux(anyReq, arbAddr, a.getRange(2, 2 + aw)),
      depth: itemDepth,
      zeroInit: true,
    );
    ramData <= itemRam.rdData;

    // Pixel RAM, written and read over the bus only.
    Logic pixelRead = Const(0, width: 32);
    if (hasPixels) {
      final pixelWindowOk = a.getRange(2, 11).lt(Const(maxPixels, width: 9));
      final pixelIdx = a.getRange(2, 2 + pixelAw);
      final pixelOld = Logic(name: 'pixel_old', width: 32);
      final pixelRam = HarborFifoRam(
        name: 'pixel_ram',
        clk: clk,
        wrEn: busWr & inPixels & pixelWindowOk & bus.selAny(0, 4),
        wrAddr: pixelIdx,
        wrData: bus.selMerge(pixelOld, 0),
        rdAddr: pixelIdx,
        depth: maxPixels,
        zeroInit: true,
      );
      pixelOld <= pixelRam.rdData;
      pixelRead = mux(
        inPixels & pixelWindowOk,
        pixelRam.rdData,
        Const(0, width: 32),
      );
    }

    final irqClear = mux(
      busWr & globalHit(2),
      irqFromWord(bus.selMasked(0x10, 16)),
      Const(0, width: 2 * n),
    );
    final doneBits = [
      bitsOf([for (final ch in channelsRtl) ch.done]),
      Const(0, width: n),
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
            mode[c] < bus.dataIn[1],
            pol[c] < bus.dataIn[2],
            idle[c] < bus.dataIn[3],
            bpp[c] < bus.dataIn[4],
          ],
        ),
      );
      final newOrder = bus.dataIn.getRange(8, 11);
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
      // MODE and SEND are taken from the same write.
      sendPulse[c] <=
          busWr &
              ctrlHit &
              bus.selAny(0x00, 1) &
              bus.dataIn[0] &
              ~bus.dataIn[1];
      for (var k = 0; k < 4; k++) {
        wr(chanHit(c, 2 + k), timing[c][k], 0x10 + 8 * k);
      }
      wr(chanHit(c, 6), resetGap[c], 0x30);
      wr(chanHit(c, 7), pixelCount[c], 0x38);
      wr(chanHit(c, 10), refresh[c], 0x50);
      wr(chanHit(c, 11), loop[c], 0x58);
      wr(chanHit(c, 12), itemStart[c], 0x60);
    }

    // Register reads.
    final globalRead = slotRead('global_read', {
      0: [
        Const(n, width: 4),
        Const(pixelSource.index, width: 4),
        Const(aw, width: 8),
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
      gate(inItems & itemWindowOk, ramData.zeroExtend(32)),
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
          channelsRtl[c].busy,
          channelsRtl[c].underrun,
          Const(0, width: 14),
          channelsRtl[c].frameCount,
          Const(0, width: 8),
        ].rconcat(),
        for (var k = 0; k < 4; k++) 2 + k: timing[c][k],
        6: resetGap[c],
        7: pixelCount[c],
        10: refresh[c],
        11: loop[c],
        12: itemStart[c],
        13: channelsRtl[c].state,
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
            mode[c] < 0,
            pol[c] < (channels[c].activeLow ? 1 : 0),
            idle[c] < 0,
            bpp[c] < 0,
            order[c] < Const(0, width: 3),
            for (var k = 0; k < 4; k++) timing[c][k] < Const(0, width: 15),
            resetGap[c] < Const(0, width: 20),
            pixelCount[c] < Const(0, width: maxPixels.bitLength),
            refresh[c] < Const(0, width: 32),
            loop[c] < Const(0, width: 8),
            itemStart[c] < Const(0, width: aw),
          ],
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          irqStatus < ((irqStatus & ~irqClear) | doneBits),
          ...writes,
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
          // A channel read of the item RAM goes first, so a bus read of the
          // item window waits.
          If(
            accessStart & ~busStall,
            then: [
              bus.ack < Const(1),
              If(~bus.we, then: [bus.dataOut < readValue]),
            ],
          ),
        ],
      ),
    ]);

    output('frame_tick') <= Const(0, width: n);
    output('led_status') <=
        [
          for (var b = 0; b < 24; b++)
            b % 8 < n
                ? switch (b ~/ 8) {
                    0 => channelsRtl[b % 8].busy,
                    1 => Const(0),
                    _ => channelsRtl[b % 8].underrun,
                  }
                : Const(0),
        ].rconcat();
    for (var c = 0; c < n; c++) {
      _channelOut[c][0] <= channelsRtl[c].pin;
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
    if (clockHz != null) 'clock-frequency': clockHz!,
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
