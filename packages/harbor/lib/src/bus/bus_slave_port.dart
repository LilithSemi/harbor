import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../clock/wishbone_cdc_fifo.dart';
import 'axi4/axi4_lite_interface.dart';
import 'port/fabric_kind.dart';
import 'port/port_cdc.dart';
import 'port/register_waist.dart';
import 'tilelink/tilelink_interface.dart';
import 'wishbone/wishbone_interface.dart';

export 'port/fabric_kind.dart';

/// The register slave waist of a device, with the native port for one fabric
/// kind built in front of it.
///
/// The device sees one access at a time, the same for every kind. [stb] is
/// high while an access is presented and [addr], [we], [dataIn] and [sel]
/// stay stable until the device raises [ack] for one cycle. [dataOut] and
/// [err] are sampled in that cycle. [addr] is a byte address aligned down to
/// the data word.
///
/// ```dart
/// final bus = BusSlavePort.create(
///   module: this,
///   name: 'bus',
///   kind: HarborFabricKind.axi4,
///   addressWidth: 12,
///   dataWidth: 32,
///   clk: input('clk'),
///   reset: input('reset'),
/// );
/// ```
class BusSlavePort {
  /// Byte address of the access, aligned to the data word.
  final Logic addr;

  /// Write data.
  final Logic dataIn;

  /// Read data, driven by the device. Sampled with [ack].
  final Logic dataOut;

  /// High while an access is presented.
  final Logic stb;

  /// High for a write, low for a read.
  final Logic we;

  /// Byte lanes of the access, one bit per byte of [dataIn], for reads and
  /// writes. Read data is always the full word, but a register with a read
  /// side effect (a FIFO pop, a claim, a clear on read) must act only when
  /// its lanes are selected.
  final Logic sel;

  /// Driven by the device for one cycle to end the access.
  final Logic ack;

  /// Driven by the device with [ack] to fail the access. Only present when
  /// the port is created with `useErr`.
  final Logic? err;

  /// The fabric kind of the native port.
  final HarborFabricKind kind;

  /// The native interface on the module.
  final InterfaceReference<PairInterface> interfaceRef;

  /// The reset for device logic behind the port. With a crossing it is the
  /// device reset joined with the fabric reset, so the device resets when
  /// the fabric does and never sees [stb] drop in the middle of an access.
  final Logic reset;

  /// Entries in each FIFO of the crossing, or 0 when there is none.
  final int cdcDepth;

  BusSlavePort._({
    required this.addr,
    required this.dataIn,
    required this.dataOut,
    required this.stb,
    required this.we,
    required this.sel,
    required this.ack,
    required this.err,
    required this.kind,
    required this.interfaceRef,
    required this.reset,
    this.cdcDepth = 0,
  });

  /// Entries in each FIFO of a register port crossing.
  static const crossingDepth = 2;

  /// Input name of the fabric clock of a crossed port.
  static const fabricClkPort = 'fabric_clk';

  /// Input name of the fabric reset of a crossed port.
  static const fabricResetPort = 'fabric_reset';

  /// Adds the [fabricClkPort] and [fabricResetPort] inputs to [module] and
  /// returns them as the fabric clock for [create]. Returns null when
  /// [cross] is false. A SoC drives these inputs from its fabric clock.
  static HarborFabricClock? fabricClockInputs(
    BridgeModule module, {
    required bool cross,
  }) {
    if (!cross) return null;
    module
      ..createPort(fabricClkPort, PortDirection.input)
      ..createPort(fabricResetPort, PortDirection.input);
    return HarborFabricClock(
      clk: module.input(fabricClkPort),
      reset: module.input(fabricResetPort),
    );
  }

  /// Definition name parts of a device with one register port: the kind,
  /// the widths, ERR, and the crossing depth when [cross] is set.
  static List<String> definitionNameParts({
    required HarborFabricKind kind,
    required int addressWidth,
    required int dataWidth,
    bool useErr = false,
    bool cross = false,
  }) => [
    kind.name,
    'a$addressWidth',
    'd$dataWidth',
    if (useErr) 'e',
    if (cross) 'x$crossingDepth',
  ];

  /// Adds the native slave port for [kind] to [module] and returns the
  /// register waist the device drives.
  ///
  /// Wishbone gives a classic slave, AXI4 an AXI4-Lite subordinate and
  /// TileLink a TL-UL slave. Set [useErr] to get [err], which becomes Wishbone
  /// ERR, AXI4 SLVERR or a denied TileLink response.
  ///
  /// [clk] and [reset] are the device clock. When [fabricClock] is a
  /// different clock, the native port runs on it and a
  /// [HarborWishboneCdcFifoBridge] crosses the waist to the device. An access
  /// that waits while the device side resets ends with all-ones data and an
  /// error: SLVERR, denied, or Wishbone ERR when [useErr] is set.
  static BusSlavePort create({
    required BridgeModule module,
    required String name,
    required HarborFabricKind kind,
    required int addressWidth,
    required int dataWidth,
    required Logic clk,
    required Logic reset,
    bool useErr = false,
    HarborFabricClock? fabricClock,
  }) {
    if (fabricClock != null && fabricClock.crossesFrom(clk)) {
      return _crossed(
        module,
        name,
        kind,
        addressWidth,
        dataWidth,
        clk,
        reset,
        useErr,
        fabricClock,
      );
    }
    final dataOut = Logic(name: '${name}_dat_out', width: dataWidth);
    final ack = Logic(name: '${name}_ack_out');
    final err = useErr ? Logic(name: '${name}_err_out') : null;
    return switch (kind) {
      HarborFabricKind.wishbone => _wishbone(
        module,
        name,
        addressWidth,
        dataWidth,
        dataOut,
        ack,
        err,
        reset,
      ),
      HarborFabricKind.axi4 => _axi4Lite(
        module,
        name,
        addressWidth,
        dataWidth,
        dataOut,
        ack,
        err,
        clk,
        reset,
      ),
      HarborFabricKind.tilelink => _tileLink(
        module,
        name,
        addressWidth,
        dataWidth,
        dataOut,
        ack,
        err,
        clk,
        reset,
      ),
    };
  }

  // The native port runs on the fabric clock and a registered FIFO bridge
  // carries one access at a time to the device clock.
  static BusSlavePort _crossed(
    BridgeModule module,
    String name,
    HarborFabricKind kind,
    int addressWidth,
    int dataWidth,
    Logic clk,
    Logic reset,
    bool useErr,
    HarborFabricClock fabric,
  ) {
    const depth = crossingDepth;
    // A device reset fails the waiting access, so AXI4 and TileLink always
    // carry the error. A Wishbone port without ERR gets only the poison data.
    final inner = create(
      module: module,
      name: name,
      kind: kind,
      addressWidth: addressWidth,
      dataWidth: dataWidth,
      clk: fabric.clk,
      reset: fabric.reset,
      useErr: useErr || kind != HarborFabricKind.wishbone,
    );
    final cdc = module.addSubModule(
      HarborWishboneCdcFifoBridge(
        addressWidth: addressWidth,
        dataWidth: dataWidth,
        depth: depth,
        respDepth: depth,
        useErr: true,
        name: '${name}_cdc',
      ),
    );
    void drive(String port, Logic value) =>
        cdc.input(port).srcConnection! <= value;
    drive('s_clk', fabric.clk);
    drive('s_reset', fabric.reset);
    drive('s_cyc', inner.stb);
    drive('s_stb', Const(1));
    drive('s_we', inner.we);
    drive('s_adr', inner.addr);
    drive('s_dat_w', inner.dataIn);
    drive('s_sel', inner.sel);
    inner.ack <= cdc.output('s_ack');
    inner.dataOut <= cdc.output('s_dat_r');
    inner.err?.gets(cdc.output('s_err'));

    final dataOut = Logic(name: '${name}_dat_out', width: dataWidth);
    final ack = Logic(name: '${name}_ack_out');
    final err = useErr ? Logic(name: '${name}_err_out') : null;
    drive('m_clk', clk);
    drive('m_reset', reset);
    drive('m_ack', ack);
    drive('m_dat_r', dataOut);
    drive('m_err', err ?? Const(0));
    final stb = cdc.output('m_cyc');
    return BusSlavePort._(
      addr: cdc.output('m_adr'),
      dataIn: cdc.output('m_dat_w'),
      dataOut: dataOut,
      stb: stb,
      we: (cdc.output('m_we') & stb).named('${name}_we'),
      sel: cdc.output('m_sel'),
      ack: ack,
      err: err,
      kind: kind,
      interfaceRef: inner.interfaceRef,
      reset: cdc.output('m_reset_joined'),
      cdcDepth: depth,
    );
  }

  static BusSlavePort _wishbone(
    BridgeModule module,
    String name,
    int addressWidth,
    int dataWidth,
    Logic dataOut,
    Logic ack,
    Logic? err,
    Logic reset,
  ) {
    final intf = WishboneInterface(
      WishboneConfig(
        addressWidth: addressWidth,
        dataWidth: dataWidth,
        useErr: err != null,
      ),
    );
    final ref = module.addInterface(intf, name: name, role: PairRole.consumer);
    final wb = ref.internalInterface!;

    wb.datMiso <= dataOut;
    if (err != null) {
      wb.ack <= ack & ~err;
      wb.err! <= ack & err;
    } else {
      wb.ack <= ack;
    }

    return BusSlavePort._(
      addr: harborWordAddress(wb.adr, dataWidth).named('${name}_addr'),
      dataIn: wb.datMosi,
      dataOut: dataOut,
      stb: wb.cyc & wb.stb,
      we: wb.we,
      sel: wb.sel,
      ack: ack,
      err: err,
      kind: HarborFabricKind.wishbone,
      interfaceRef: ref,
      reset: reset,
    );
  }

  // AXI4-Lite has no read size, so a read selects the 32-bit lanes that
  // ARADDR points at. A bus of 32 bits or less selects every lane.
  static Logic _liteReadLanes(Logic addr, int strbWidth) {
    if (strbWidth <= 4) return Const(1, width: strbWidth, fill: true);
    final words = strbWidth ~/ 4;
    final idx = addr.getRange(2, 2 + (words - 1).bitLength);
    return [
      for (var i = words - 1; i >= 0; i--)
        mux(
          idx.eq(Const(i, width: idx.width)),
          Const(0xf, width: 4),
          Const(0, width: 4),
        ),
    ].swizzle();
  }

  // AW, W and AR each go into a holding register. A write runs once both AW
  // and W are held, a read once AR is held. When both are ready they take
  // turns. The response is registered and held until BREADY or RREADY.
  static BusSlavePort _axi4Lite(
    BridgeModule module,
    String name,
    int addressWidth,
    int dataWidth,
    Logic dataOut,
    Logic ack,
    Logic? err,
    Logic clk,
    Logic reset,
  ) {
    final intf = Axi4LiteInterface(
      addressWidth: addressWidth,
      dataWidth: dataWidth,
    );
    final ref = module.addInterface(intf, name: name, role: PairRole.consumer);
    final axi = ref.internalInterface!;
    final strbWidth = dataWidth ~/ 8;

    final awHeld = Logic(name: '${name}_aw_held');
    final awAddr = Logic(name: '${name}_aw_addr', width: addressWidth);
    final wHeld = Logic(name: '${name}_w_held');
    final wData = Logic(name: '${name}_w_data', width: dataWidth);
    final wStrb = Logic(name: '${name}_w_strb', width: strbWidth);
    final arHeld = Logic(name: '${name}_ar_held');
    final arAddr = Logic(name: '${name}_ar_addr', width: addressWidth);
    final bValid = Logic(name: '${name}_b_valid');
    final bErr = Logic(name: '${name}_b_err');
    final rValid = Logic(name: '${name}_r_valid');
    final rData = Logic(name: '${name}_r_data', width: dataWidth);
    final rErr = Logic(name: '${name}_r_err');
    // The access in front of the device keeps its direction until ACK, even
    // if the other direction becomes ready in the meantime.
    final locked = Logic(name: '${name}_locked');
    final lockedWrite = Logic(name: '${name}_locked_write');
    final lastWrite = Logic(name: '${name}_last_write');

    final writeReady = (awHeld & wHeld & ~bValid).named('${name}_write_ready');
    final readReady = (arHeld & ~rValid).named('${name}_read_ready');
    final isWrite = mux(
      locked,
      lockedWrite,
      mux(writeReady & readReady, ~lastWrite, writeReady),
    ).named('${name}_is_write');
    final stb = (locked | writeReady | readReady).named('${name}_stb');
    final done = stb & ack;
    final errNow = err ?? Const(0);

    Sequential(clk, reset: reset, [
      If(axi.awValid & ~awHeld, then: [awHeld < Const(1), awAddr < axi.awAddr]),
      If(
        axi.wValid & ~wHeld,
        then: [wHeld < Const(1), wData < axi.wData, wStrb < axi.wStrb],
      ),
      If(axi.arValid & ~arHeld, then: [arHeld < Const(1), arAddr < axi.arAddr]),
      If(bValid & axi.bReady, then: [bValid < Const(0)]),
      If(rValid & axi.rReady, then: [rValid < Const(0)]),
      If(
        done,
        then: [
          locked < Const(0),
          lastWrite < isWrite,
          If(
            isWrite,
            then: [
              awHeld < Const(0),
              wHeld < Const(0),
              bValid < Const(1),
              bErr < errNow,
            ],
            orElse: [
              arHeld < Const(0),
              rValid < Const(1),
              rData < dataOut,
              rErr < errNow,
            ],
          ),
        ],
        orElse: [
          If(stb, then: [locked < Const(1), lockedWrite < isWrite]),
        ],
      ),
    ]);

    // SLVERR is 0b10, OKAY is 0b00.
    Logic resp(Logic e) => [e, Const(0)].swizzle();

    axi.awReady <= ~awHeld;
    axi.wReady <= ~wHeld;
    axi.arReady <= ~arHeld;
    axi.bValid <= bValid;
    axi.bResp <= resp(bErr);
    axi.rValid <= rValid;
    axi.rData <= rData;
    axi.rResp <= resp(rErr);

    return BusSlavePort._(
      addr: harborWordAddress(
        mux(isWrite, awAddr, arAddr),
        dataWidth,
      ).named('${name}_addr'),
      dataIn: wData,
      dataOut: dataOut,
      stb: stb,
      we: isWrite & stb,
      sel: mux(isWrite, wStrb, _liteReadLanes(arAddr, strbWidth)),
      ack: ack,
      err: err,
      kind: HarborFabricKind.axi4,
      interfaceRef: ref,
      reset: reset,
    );
  }

  // Channel A goes into a holding register and the response into a D
  // register held until D_READY. Get, PutFullData and PutPartialData reach
  // the device. Any other opcode is denied without touching it.
  //
  // A request whose A_SIZE spans more than one beat is always denied, per
  // the TileLink 1.8 rules for denied operations: a Put-like request (whose
  // data arrives over several A beats) has every extra beat drained so the
  // channel stays in sync, then gets one denied AccessAck, which never
  // carries data and so is never itself a burst. A Get-like request (whose
  // response carries data) gets a denied AccessAckData that spans the same
  // number of D beats a successful reply would have used.
  static BusSlavePort _tileLink(
    BridgeModule module,
    String name,
    int addressWidth,
    int dataWidth,
    Logic dataOut,
    Logic ack,
    Logic? err,
    Logic clk,
    Logic reset,
  ) {
    final config = TileLinkConfig(
      addressWidth: addressWidth,
      dataWidth: dataWidth,
    );
    final intf = TileLinkInterface(config);
    final ref = module.addInterface(intf, name: name, role: PairRole.consumer);
    final tl = ref.internalInterface!;

    // One beat covers dataWidth/8 bytes. A larger A_SIZE is a burst.
    final beatLog2 = (dataWidth ~/ 8).bitLength - 1;
    final maxSize = (1 << config.sizeWidth) - 1;
    final maxBeats = maxSize > beatLog2 ? 1 << (maxSize - beatLog2) : 1;
    final beatCountWidth = maxBeats.bitLength > config.sizeWidth
        ? maxBeats.bitLength
        : config.sizeWidth;

    // True when a request of this A_SIZE needs more than one beat.
    Logic oversized(Logic size) =>
        size.gt(Const(beatLog2, width: config.sizeWidth));
    // Beats a request of this A_SIZE spans: 1 in range, else
    // 2^(size - beatLog2).
    Logic beatsOf(Logic size) {
      final shift = (size - Const(beatLog2, width: config.sizeWidth))
          .zeroExtend(beatCountWidth);
      return mux(
        oversized(size),
        Const(1, width: beatCountWidth) << shift,
        Const(1, width: beatCountWidth),
      );
    }

    final aHeld = Logic(name: '${name}_a_held');
    final aOpcode = Logic(name: '${name}_a_opcode', width: 3);
    final aSize = Logic(name: '${name}_a_size', width: config.sizeWidth);
    final aSource = Logic(name: '${name}_a_source', width: config.sourceWidth);
    final aAddress = Logic(name: '${name}_a_address', width: addressWidth);
    final aMask = Logic(name: '${name}_a_mask', width: config.maskWidth);
    final aData = Logic(name: '${name}_a_data', width: dataWidth);
    // Extra A beats still to drain for a Put-like burst beyond the first.
    final aDrainLeft = Logic(
      name: '${name}_a_drain_left',
      width: beatCountWidth,
    );
    final dValid = Logic(name: '${name}_d_valid');
    final dOpcode = Logic(name: '${name}_d_opcode', width: 3);
    final dSize = Logic(name: '${name}_d_size', width: config.sizeWidth);
    final dSource = Logic(name: '${name}_d_source', width: config.sourceWidth);
    final dData = Logic(name: '${name}_d_data', width: dataWidth);
    final dDenied = Logic(name: '${name}_d_denied');
    final dCorrupt = Logic(name: '${name}_d_corrupt');
    // D beats still to send, including the current one.
    final dBeatsLeft = Logic(
      name: '${name}_d_beats_left',
      width: beatCountWidth,
    );

    final draining = aDrainLeft
        .gt(Const(0, width: beatCountWidth))
        .named('${name}_draining');

    Logic isOp(TileLinkAOpcode op) => aOpcode.eq(Const(op.value, width: 3));
    final isGet = isOp(TileLinkAOpcode.get);
    final isPut =
        isOp(TileLinkAOpcode.putFullData) |
        isOp(TileLinkAOpcode.putPartialData);
    final oversize = oversized(aSize).named('${name}_oversize');
    // Free to decide the response once any burst has drained and the D slot
    // is clear.
    final free = aHeld & ~draining & ~dValid;
    final stb = (free & ~oversize & (isGet | isPut)).named('${name}_stb');
    final reject = (free & (oversize | (~isGet & ~isPut))).named(
      '${name}_reject',
    );
    final respond = (stb & ack) | reject;
    final denied = reject | (stb & (err ?? Const(0)));
    // Get, ArithmeticData and LogicalData answer with data. Intent answers
    // with HintAck. Puts and the rest answer with AccessAck.
    final withData =
        isGet | aOpcode.eq(Const(2, width: 3)) | aOpcode.eq(Const(3, width: 3));
    final respOpcode = mux(
      withData,
      Const(TileLinkDOpcode.accessAckData.value, width: 3),
      mux(
        aOpcode.eq(Const(5, width: 3)),
        Const(2, width: 3),
        Const(TileLinkDOpcode.accessAck.value, width: 3),
      ),
    );
    // AccessAck never carries data, so it is never a burst: only a
    // data-bearing denial spans more than one D beat.
    final dBeatsToSend = mux(
      withData,
      beatsOf(aSize),
      Const(1, width: beatCountWidth),
    );

    // Put, ArithmeticData and LogicalData carry request data over A, so an
    // oversize request of theirs bursts on A and must be drained.
    final incomingBurstsOnA =
        tl.aOpcode.eq(Const(TileLinkAOpcode.putFullData.value, width: 3)) |
        tl.aOpcode.eq(Const(TileLinkAOpcode.putPartialData.value, width: 3)) |
        tl.aOpcode.eq(Const(2, width: 3)) |
        tl.aOpcode.eq(Const(3, width: 3));
    final drainBeats = mux(
      oversized(tl.aSize) & incomingBurstsOnA,
      beatsOf(tl.aSize) - Const(1, width: beatCountWidth),
      Const(0, width: beatCountWidth),
    );

    Sequential(clk, reset: reset, [
      If.block([
        Iff(tl.aValid & ~aHeld, [
          aHeld < Const(1),
          aOpcode < tl.aOpcode,
          aSize < tl.aSize,
          aSource < tl.aSource,
          aAddress < tl.aAddress,
          aMask < tl.aMask,
          aData < tl.aData,
          aDrainLeft < drainBeats,
        ]),
        ElseIf(tl.aValid & draining, [
          aDrainLeft < aDrainLeft - Const(1, width: beatCountWidth),
        ]),
      ]),
      If(
        dValid & tl.dReady,
        then: [
          If(
            dBeatsLeft.gt(Const(1, width: beatCountWidth)),
            then: [dBeatsLeft < dBeatsLeft - Const(1, width: beatCountWidth)],
            orElse: [dValid < Const(0)],
          ),
        ],
      ),
      If(
        respond,
        then: [
          aHeld < Const(0),
          dValid < Const(1),
          dBeatsLeft < dBeatsToSend,
          dOpcode < respOpcode,
          dSize < aSize,
          dSource < aSource,
          dData < mux(stb, dataOut, Const(0, width: dataWidth)),
          dDenied < denied,
          // A denied response with data must also be corrupt.
          dCorrupt < (denied & withData),
        ],
      ),
    ]);

    tl.aReady <= (~aHeld | draining);
    tl.dValid <= dValid;
    tl.dOpcode <= dOpcode;
    tl.dParam <= Const(0, width: 2);
    tl.dSize <= dSize;
    tl.dSource <= dSource;
    tl.dSink <= Const(0, width: config.sinkWidth);
    tl.dData <= dData;
    tl.dCorrupt <= dCorrupt;
    tl.dDenied <= dDenied;

    return BusSlavePort._(
      addr: harborWordAddress(aAddress, dataWidth).named('${name}_addr'),
      dataIn: aData,
      dataOut: dataOut,
      stb: stb,
      we: isPut & stb,
      sel: aMask,
      ack: ack,
      err: err,
      kind: HarborFabricKind.tilelink,
      interfaceRef: ref,
      reset: reset,
    );
  }
}

/// Byte-lane write helpers for a [BusSlavePort].
///
/// On a bus wider than one register, a master aligns the address down to the
/// bus word and shifts the write data and [BusSlavePort.sel] into the byte
/// lane of the access (the River MMU convention; PLIC and CLINT decode this
/// the same way). A register write must look at [BusSlavePort.sel], not just
/// take the whole bus word, or a narrower store aliases other bytes of the
/// same bus word and a store to another lane clobbers a register it was
/// never addressed to.
extension BusSlavePortByteLane on BusSlavePort {
  /// Byte position of [offset] within the aligned bus word [sel] covers.
  int _lane(int offset) => offset % (dataIn.width ~/ 8);

  /// True when [sel] marks at least one of the [byteWidth] bytes a register
  /// at byte address [offset] occupies. Gates a write so a store that lands
  /// in a different lane, or a byte/halfword store that misses this
  /// register entirely, leaves it alone.
  Logic selAny(int offset, int byteWidth) {
    final lane = _lane(offset);
    return sel.getRange(lane, lane + byteWidth).or();
  }

  /// Next value for a register currently holding [oldValue], written from
  /// the bus word at byte address [offset]. A byte [sel] does not mark keeps
  /// its value from [oldValue]; a byte it marks takes the matching byte of
  /// [BusSlavePort.dataIn]. This is the merge a byte or halfword store
  /// needs: only the bytes [sel] selects change, and bytes outside this
  /// register's lane are never touched.
  Logic selMerge(Logic oldValue, int offset) {
    final lane = _lane(offset);
    final width = oldValue.width;
    final byteCount = (width + 7) ~/ 8;
    final bytes = <Logic>[
      for (var b = 0; b < byteCount; b++)
        mux(
          sel[lane + b],
          dataIn.getRange(
            lane * 8 + b * 8,
            lane * 8 + b * 8 + _byteBits(width, b),
          ),
          oldValue.getRange(b * 8, b * 8 + _byteBits(width, b)),
        ),
    ];
    return bytes.rswizzle();
  }

  /// [BusSlavePort.dataIn] at byte address [offset], with every byte [sel]
  /// does not mark forced to zero. For a write-1-to-clear register, this
  /// keeps a store that does not select a byte from clearing any bit in it.
  Logic selMasked(int offset, int width) {
    final lane = _lane(offset);
    final byteCount = (width + 7) ~/ 8;
    final bytes = <Logic>[
      for (var b = 0; b < byteCount; b++)
        mux(
          sel[lane + b],
          dataIn.getRange(
            lane * 8 + b * 8,
            lane * 8 + b * 8 + _byteBits(width, b),
          ),
          Const(0, width: _byteBits(width, b)),
        ),
    ];
    return bytes.rswizzle();
  }

  /// Width of byte [b] of a [width]-bit register: 8, except the last byte of
  /// a register whose width is not a multiple of 8.
  int _byteBits(int width, int b) {
    final lo = b * 8;
    final hi = lo + 8 > width ? width : lo + 8;
    return hi - lo;
  }
}

/// Address decode inside the window of a [BusSlavePort].
///
/// A fabric can give a slave its address relative to the window base, or the
/// absolute address. A peripheral decodes only the address bits inside its
/// window, so both work.
extension BusSlavePortWindow on BusSlavePort {
  /// The address bits inside a window of [windowBytes] bytes, zero-extended
  /// when the port is narrower than the window. [windowBytes] must be a power
  /// of two.
  Logic windowAddr(int windowBytes) {
    if (windowBytes <= 0 || windowBytes & (windowBytes - 1) != 0) {
      throw ArgumentError.value(
        windowBytes,
        'windowBytes',
        'must be a power of two',
      );
    }
    final bits = windowBytes.bitLength - 1;
    if (bits == 0) return Const(0);
    return addr.width >= bits ? addr.getRange(0, bits) : addr.zeroExtend(bits);
  }

  /// High when the address is in the first [spanBytes] of a window of
  /// [windowBytes] bytes. Gate register access on it, so an offset past the
  /// registers reads 0 and ignores writes.
  Logic inSpan(int spanBytes, int windowBytes) {
    if (spanBytes <= 0 || spanBytes > windowBytes) {
      throw ArgumentError.value(spanBytes, 'spanBytes', 'must fit the window');
    }
    final offset = windowAddr(windowBytes);
    if (spanBytes == windowBytes) return Const(1);
    if (spanBytes & (spanBytes - 1) == 0) {
      return offset.getRange(spanBytes.bitLength - 1).eq(0);
    }
    return offset.lt(Const(spanBytes, width: offset.width));
  }
}
