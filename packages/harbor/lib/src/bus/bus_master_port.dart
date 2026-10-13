import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../clock/wishbone_cdc_fifo.dart';
import 'axi4/axi4_lite_interface.dart';
import 'port/fabric_kind.dart';
import 'port/port_cdc.dart';
import 'port/register_waist.dart';
import 'tilelink/tilelink_interface.dart';
import 'wishbone/wishbone_interface.dart';

/// The register master waist of a device, with the native master port for
/// one fabric kind built behind it.
///
/// The device raises [stb] with [addr], [we], [dataOut] and [sel] and holds
/// them until [ack] is high for one cycle. [dataIn] and [err] are valid in
/// that cycle. If [stb] stays high after [ack], that is the next access.
/// [addr] is a byte address aligned to the data word, and [sel] marks the
/// bytes a write changes.
class BusMasterPort {
  /// Byte address of the access, driven by the device.
  final Logic addr;

  /// Write data, driven by the device.
  final Logic dataOut;

  /// Read data. Valid with [ack].
  final Logic dataIn;

  /// Driven by the device while an access is presented.
  final Logic stb;

  /// Driven by the device. High for a write, low for a read.
  final Logic we;

  /// Byte-lane selects, driven by the device.
  final Logic sel;

  /// High for one cycle when the access ends.
  final Logic ack;

  /// High with [ack] when the access failed. Always low on a Wishbone port
  /// created without `useErr`.
  final Logic err;

  /// The fabric kind of the native port.
  final HarborFabricKind kind;

  /// The native interface on the module.
  final InterfaceReference<PairInterface> interfaceRef;

  /// Entries in each FIFO of the crossing, or 0 when there is none.
  final int cdcDepth;

  BusMasterPort._({
    required this.addr,
    required this.dataOut,
    required this.dataIn,
    required this.stb,
    required this.we,
    required this.sel,
    required this.ack,
    required this.err,
    required this.kind,
    required this.interfaceRef,
    this.cdcDepth = 0,
  });

  /// Adds the native master port for [kind] to [module] and returns the
  /// register waist the device drives.
  ///
  /// Wishbone gives a classic master, AXI4 an AXI4-Lite manager and TileLink
  /// a TL-UL master. [useErr] adds ERR to a Wishbone port.
  ///
  /// [clk] and [reset] are the device clock. When [fabricClock] is a
  /// different clock, the native port runs on it and a
  /// [HarborWishboneCdcFifoBridge] crosses the waist from the device. An
  /// access that waits while the fabric side resets ends with all-ones data
  /// and [err]. A device reset drops the access in flight, and on AXI4 and
  /// TileLink the fabric side still finishes it.
  static BusMasterPort create({
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
    final crossed = fabricClock != null && fabricClock.crossesFrom(clk);
    BusMasterPort waist(String tag, InterfaceReference<PairInterface> ref) =>
        BusMasterPort._(
          addr: Logic(name: '$name${tag}_adr_in', width: addressWidth),
          dataOut: Logic(name: '$name${tag}_dat_in', width: dataWidth),
          dataIn: Logic(name: '$name${tag}_dat_out', width: dataWidth),
          stb: Logic(name: '$name${tag}_stb_in'),
          we: Logic(name: '$name${tag}_we_in'),
          sel: Logic(name: '$name${tag}_sel_in', width: dataWidth ~/ 8),
          ack: Logic(name: '$name${tag}_ack_out'),
          err: Logic(name: '$name${tag}_err_out'),
          kind: kind,
          interfaceRef: ref,
          cdcDepth: crossed ? 2 : 0,
        );
    final port = waist('', switch (kind) {
      HarborFabricKind.wishbone => module.addInterface(
        WishboneInterface(
          WishboneConfig(
            addressWidth: addressWidth,
            dataWidth: dataWidth,
            useErr: useErr,
          ),
        ),
        name: name,
        role: PairRole.provider,
      ),
      HarborFabricKind.axi4 => module.addInterface(
        Axi4LiteInterface(addressWidth: addressWidth, dataWidth: dataWidth),
        name: name,
        role: PairRole.provider,
      ),
      HarborFabricKind.tilelink => module.addInterface(
        TileLinkInterface(
          TileLinkConfig(addressWidth: addressWidth, dataWidth: dataWidth),
        ),
        name: name,
        role: PairRole.provider,
      ),
    });
    final native = crossed ? waist('_fabric', port.interfaceRef) : port;
    final (nClk, nReset) = crossed
        ? (fabricClock.clk, fabricClock.reset)
        : (clk, reset);
    switch (port.interfaceRef.internalInterface) {
      case final WishboneInterface wb:
        native._wishbone(wb);
      case final Axi4LiteInterface axi:
        native._axi4Lite(axi, name, nClk, nReset);
      case final TileLinkInterface tl:
        native._tileLink(tl, name, nClk, nReset);
    }
    if (crossed) {
      _cross(module, name, port, native, clk, reset, fabricClock);
    }
    return port;
  }

  // A registered FIFO bridge carries one access at a time from the device
  // clock to the fabric clock. AXI4 and TileLink cannot drop an access once
  // it started, so a hold stage keeps it up until the native port is done,
  // even when the bridge resets under it. Its answer is then dropped.
  static void _cross(
    BridgeModule module,
    String name,
    BusMasterPort device,
    BusMasterPort native,
    Logic clk,
    Logic reset,
    HarborFabricClock fabric,
  ) {
    final width = device.dataOut.width;
    final cdc = module.addSubModule(
      HarborWishboneCdcFifoBridge(
        addressWidth: device.addr.width,
        dataWidth: width,
        depth: 2,
        respDepth: 2,
        useErr: true,
        name: '${name}_cdc',
      ),
    );
    void drive(String port, Logic value) =>
        cdc.input(port).srcConnection! <= value;
    drive('s_clk', clk);
    drive('s_reset', reset);
    drive('s_cyc', device.stb);
    drive('s_stb', Const(1));
    drive('s_we', device.we);
    drive('s_adr', device.addr);
    drive('s_dat_w', device.dataOut);
    drive('s_sel', device.sel);
    device.ack <= cdc.output('s_ack');
    device.dataIn <= cdc.output('s_dat_r');
    device.err <= cdc.output('s_err');
    drive('m_clk', fabric.clk);
    drive('m_reset', fabric.reset);
    drive('m_dat_r', native.dataIn);
    drive('m_err', native.err);

    final cyc = cdc.output('m_cyc');
    if (native.kind == HarborFabricKind.wishbone) {
      native.stb <= cyc;
      native.we <= cdc.output('m_we');
      native.addr <= cdc.output('m_adr');
      native.dataOut <= cdc.output('m_dat_w');
      native.sel <= cdc.output('m_sel');
      drive('m_ack', native.ack);
      return;
    }
    final busy = Logic(name: '${name}_hold_busy');
    final orphan = Logic(name: '${name}_hold_orphan');
    final hWe = Logic(name: '${name}_hold_we');
    final hAddr = Logic(name: '${name}_hold_adr', width: device.addr.width);
    final hData = Logic(name: '${name}_hold_dat', width: width);
    final hSel = Logic(name: '${name}_hold_sel', width: device.sel.width);
    Sequential(fabric.clk, reset: fabric.reset, [
      If.block([
        Iff(~busy & cyc, [
          busy < Const(1),
          orphan < Const(0),
          hWe < cdc.output('m_we'),
          hAddr < cdc.output('m_adr'),
          hData < cdc.output('m_dat_w'),
          hSel < cdc.output('m_sel'),
        ]),
        ElseIf(busy & native.ack, [busy < Const(0)]),
      ]),
      // The bridge dropped the cycle, so it reset. The answer has no owner.
      If(busy & ~cyc, then: [orphan < Const(1)]),
    ]);
    native.stb <= busy;
    native.we <= hWe;
    native.addr <= hAddr;
    native.dataOut <= hData;
    native.sel <= hSel;
    drive('m_ack', busy & native.ack & ~orphan);
  }

  void _wishbone(WishboneInterface wb) {
    wb.cyc <= stb;
    wb.stb <= stb;
    wb.we <= we;
    wb.adr <= addr;
    wb.datMosi <= dataOut;
    wb.sel <= sel;
    final wbErr = wb.err ?? Const(0);
    ack <= stb & (wb.ack | wbErr);
    err <= stb & wbErr;
    dataIn <= wb.datMiso;
  }

  // AW and W are raised together and each drops once it is taken. The access
  // ends on B or R. BREADY and RREADY stay high since only one access is in
  // flight.
  void _axi4Lite(Axi4LiteInterface axi, String name, Logic clk, Logic reset) {
    final awDone = Logic(name: '${name}_aw_done');
    final wDone = Logic(name: '${name}_w_done');
    final arDone = Logic(name: '${name}_ar_done');
    final write = stb & we;
    final read = stb & ~we;

    axi.awValid <= write & ~awDone;
    axi.awAddr <= addr;
    axi.awProt <= Const(0, width: Axi4LiteInterface.protWidth);
    axi.wValid <= write & ~wDone;
    axi.wData <= dataOut;
    axi.wStrb <= sel;
    axi.bReady <= Const(1);
    axi.arValid <= read & ~arDone;
    axi.arAddr <= addr;
    axi.arProt <= Const(0, width: Axi4LiteInterface.protWidth);
    axi.rReady <= Const(1);

    final done =
        (write & awDone & wDone & axi.bValid) | (read & arDone & axi.rValid);
    ack <= done;
    // SLVERR and DECERR both have bit 1 set.
    err <= done & mux(we, axi.bResp[1], axi.rResp[1]);
    dataIn <= axi.rData;

    Sequential(clk, reset: reset, [
      If.block([
        // An access ends normally, or the device drops stb before the
        // response arrives. Either way the done flags clear, so a dropped
        // access never leaves a stale done flag blocking the next one.
        Iff(done, [awDone < Const(0), wDone < Const(0), arDone < Const(0)]),
        ElseIf(~stb, [awDone < Const(0), wDone < Const(0), arDone < Const(0)]),
        Else([
          If(axi.awValid & axi.awReady, then: [awDone < Const(1)]),
          If(axi.wValid & axi.wReady, then: [wDone < Const(1)]),
          If(axi.arValid & axi.arReady, then: [arDone < Const(1)]),
        ]),
      ]),
    ]);
  }

  // One request on channel A, then wait for its D response. A write with
  // every byte selected is PutFullData, otherwise PutPartialData.
  void _tileLink(TileLinkInterface tl, String name, Logic clk, Logic reset) {
    final config = tl.config;
    final dataWidth = dataOut.width;
    final aSent = Logic(name: '${name}_a_sent');
    final aFire = tl.aValid & tl.aReady;

    tl.aValid <= stb & ~aSent;
    tl.aOpcode <=
        mux(
          we,
          mux(
            sel.and(),
            Const(TileLinkAOpcode.putFullData.value, width: 3),
            Const(TileLinkAOpcode.putPartialData.value, width: 3),
          ),
          Const(TileLinkAOpcode.get.value, width: 3),
        );
    tl.aParam <= Const(0, width: 3);
    tl.aSize <= Const((dataWidth ~/ 8).bitLength - 1, width: config.sizeWidth);
    tl.aSource <= Const(0, width: config.sourceWidth);
    tl.aAddress <= harborWordAddress(addr, dataWidth);
    tl.aMask <= mux(we, sel, Const(1, width: config.maskWidth, fill: true));
    tl.aData <= dataOut;
    tl.aCorrupt <= Const(0);
    tl.dReady <= Const(1);

    final done = stb & (aSent | aFire) & tl.dValid;
    ack <= done;
    err <= done & (tl.dDenied | tl.dCorrupt);
    dataIn <= tl.dData;

    Sequential(clk, reset: reset, [
      If.block([
        Iff(done, [aSent < Const(0)]),
        ElseIf(aFire, [aSent < Const(1)]),
      ]),
    ]);
  }
}
