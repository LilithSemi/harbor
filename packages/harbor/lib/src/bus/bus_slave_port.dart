import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'wishbone/wishbone_interface.dart';
import 'tilelink/tilelink_interface.dart';

/// Which bus protocol to use for a peripheral.
enum BusProtocol { wishbone, tilelink }

/// A bus-protocol-agnostic slave port for peripherals.
///
/// Provides a uniform internal interface (addr, dataIn, dataOut,
/// stb, we, sel, ack) that peripherals wire their register logic to.
/// The external bus protocol (Wishbone, TileLink, etc.) is handled
/// transparently.
///
/// ```dart
/// class MyDevice extends BridgeModule with HarborDeviceTreeNodeProvider {
///   MyDevice({required int baseAddress}) : super('MyDevice') {
///     createPort('clk', PortDirection.input);
///     createPort('reset', PortDirection.input);
///
///     final bus = BusSlavePort.create(
///       module: this,
///       name: 'bus',
///       protocol: BusProtocol.wishbone,
///       addressWidth: 8,
///       dataWidth: 32,
///     );
///
///     // Use bus.addr, bus.dataIn, bus.dataOut, bus.stb, bus.we, bus.sel,
///     // bus.ack regardless of which protocol was chosen
///   }
/// }
/// ```
class BusSlavePort {
  /// Address signal (from master).
  final Logic addr;

  /// Write data signal (from master).
  final Logic dataIn;

  /// Read data signal (to master).
  final Logic dataOut;

  /// Strobe/valid signal (from master, transaction active).
  final Logic stb;

  /// Write enable (from master, 1=write, 0=read).
  final Logic we;

  /// Byte-lane selects (from master, one bit per byte of [dataIn]). On
  /// Wishbone this is SEL, on TileLink the A-channel mask.
  final Logic sel;

  /// Acknowledge (to master, transaction complete).
  final Logic ack;

  /// Error signal (to master, optional).
  final Logic? err;

  /// The protocol being used.
  final BusProtocol protocol;

  /// The rohd_bridge interface reference (for connectInterfaces).
  final InterfaceReference<PairInterface> interfaceRef;

  BusSlavePort._({
    required this.addr,
    required this.dataIn,
    required this.dataOut,
    required this.stb,
    required this.we,
    required this.sel,
    required this.ack,
    this.err,
    required this.protocol,
    required this.interfaceRef,
  });

  /// Creates a bus slave port on [module] using the specified [protocol].
  ///
  /// Adds the appropriate bus interface to the module and returns
  /// a [BusSlavePort] with protocol-agnostic signals.
  static BusSlavePort create({
    required BridgeModule module,
    required String name,
    required BusProtocol protocol,
    required int addressWidth,
    required int dataWidth,
    Logic? clk,
    Logic? reset,
  }) {
    switch (protocol) {
      case BusProtocol.wishbone:
        return _createWishbone(module, name, addressWidth, dataWidth);
      case BusProtocol.tilelink:
        if (clk == null || reset == null) {
          throw ArgumentError(
            'BusProtocol.tilelink needs clk and reset to hold a response '
            'until D_READY',
          );
        }
        return _createTileLink(
          module,
          name,
          addressWidth,
          dataWidth,
          clk,
          reset,
        );
    }
  }

  static BusSlavePort _createWishbone(
    BridgeModule module,
    String name,
    int addressWidth,
    int dataWidth,
  ) {
    final intf = WishboneInterface(
      WishboneConfig(addressWidth: addressWidth, dataWidth: dataWidth),
    );
    final ref = module.addInterface(intf, name: name, role: PairRole.consumer);
    final busIntf = ref.internalInterface!;

    final datOut = Logic(name: '${name}_dat_out', width: dataWidth);
    final ackOut = Logic(name: '${name}_ack_out');

    busIntf.datMiso <= datOut;
    busIntf.ack <= ackOut;

    return BusSlavePort._(
      addr: busIntf.adr,
      dataIn: busIntf.datMosi,
      dataOut: datOut,
      stb: busIntf.cyc & busIntf.stb,
      we: busIntf.we,
      sel: busIntf.sel,
      ack: ackOut,
      err: null,
      protocol: BusProtocol.wishbone,
      interfaceRef: ref,
    );
  }

  static BusSlavePort _createTileLink(
    BridgeModule module,
    String name,
    int addressWidth,
    int dataWidth,
    Logic clk,
    Logic reset,
  ) {
    final intf = TileLinkInterface(
      TileLinkConfig(addressWidth: addressWidth, dataWidth: dataWidth),
    );
    final ref = module.addInterface(intf, name: name, role: PairRole.consumer);
    final busIntf = ref.internalInterface!;

    final datOut = Logic(name: '${name}_dat_out', width: dataWidth);
    final ackOut = Logic(name: '${name}_ack_out');

    // A response the peripheral has already produced but D_READY has not
    // yet accepted. Held so it is never lost, and so the peripheral is not
    // re-triggered against the same still-presented request while it waits.
    final respValid = Logic(name: '${name}_resp_valid');
    final respData = Logic(name: '${name}_resp_data', width: dataWidth);
    final respWe = Logic(name: '${name}_resp_we');

    final we =
        busIntf.aOpcode.eq(Const(0, width: 3)) | // PutFullData
        busIntf.aOpcode.eq(Const(1, width: 3)); // PutPartialData
    final addr = busIntf.aAddress;
    final dataIn = busIntf.aData;
    // Hide STB from the peripheral while a response is held: otherwise a
    // request the master cannot yet advance past (A_READY withheld) would
    // look like a fresh one and re-execute.
    final stb = busIntf.aValid & ~respValid;

    final dValidNow = ackOut | respValid;
    final dDataNow = mux(respValid, respData, datOut);
    final dWeNow = mux(respValid, respWe, we);

    Sequential(clk, reset: reset, [
      If(
        dValidNow & ~busIntf.dReady,
        then: [respValid < Const(1), respData < dDataNow, respWe < dWeNow],
        orElse: [respValid < Const(0)],
      ),
    ]);

    // Internal signals -> TileLink Channel D, held until D_READY.
    busIntf.dValid <= dValidNow;
    busIntf.dOpcode <= mux(dWeNow, Const(0, width: 3), Const(1, width: 3));
    busIntf.dParam <= Const(0, width: 2);
    busIntf.dSize <= busIntf.aSize;
    busIntf.dSource <= busIntf.aSource;
    busIntf.dSink <= Const(0, width: intf.config.sinkWidth);
    busIntf.dData <= dDataNow;
    busIntf.dCorrupt <= Const(0);
    busIntf.dDenied <= Const(0);

    // Accept a new Channel A request only once the previous response has
    // drained: single outstanding, matching the Wishbone side.
    busIntf.aReady <= (dValidNow & busIntf.dReady) | ~busIntf.aValid;

    return BusSlavePort._(
      addr: addr,
      dataIn: dataIn,
      dataOut: datOut,
      stb: stb,
      we: we,
      sel: busIntf.aMask,
      ack: ackOut,
      err: null,
      protocol: BusProtocol.tilelink,
      interfaceRef: ref,
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
