import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../../clock/cdc.dart';
import '../axi4/axi4_exclusive.dart';
import '../axi4/axi4_interface.dart';
import '../axi4/axi4_memory_port.dart';
import '../tilelink/tilelink_interface.dart';
import '../tilelink/tilelink_memory_port.dart';
import '../wishbone/wishbone_interface.dart';
import '../wishbone/wishbone_memory_port.dart';
import 'fabric_kind.dart';
import 'memory_waist.dart';
import 'port_cdc.dart';

/// The memory slave waist of a device, with the native memory port for one
/// fabric kind built in front of it.
///
/// The device is the memory. It takes requests and write data from [waist]
/// and drives REQ_READY, WDATA_READY, the read data and the write responses.
/// It returns responses in request order per direction.
///
/// ```dart
/// final mem = HarborMemorySlavePort.create(
///   module: this,
///   name: 'mem',
///   kind: HarborFabricKind.axi4,
///   config: const HarborMemoryWaistConfig(
///     addressWidth: 28,
///     dataWidth: 32,
///     idWidth: 4,
///     outstanding: 8,
///   ),
///   clk: input('clk'),
///   reset: input('reset'),
/// );
/// ```
class HarborMemorySlavePort {
  /// The waist the device drives as the consumer.
  final HarborMemoryWaist waist;

  /// The fabric kind of the native port.
  final HarborFabricKind kind;

  /// The native interface on the module.
  final InterfaceReference<PairInterface> interfaceRef;

  /// The reset for device logic behind the waist. With a crossing it is the
  /// device reset joined with the fabric reset.
  final Logic reset;

  /// Entries in each FIFO of the crossing, or 0 when there is none.
  final int cdcDepth;

  /// The waist on the fabric clock, between the native port and the
  /// crossing. It is [waist] when there is no crossing. A device reads it
  /// to see the responses the crossing gives in place of the device.
  final HarborMemoryWaist fabricWaist;

  HarborMemorySlavePort._(
    this.waist,
    this.kind,
    this.interfaceRef,
    this.reset,
    this.cdcDepth, [
    HarborMemoryWaist? fabricWaist,
  ]) : fabricWaist = fabricWaist ?? waist;

  /// Adds the native memory slave port for [kind] to [module] and returns the
  /// waist behind it. AXI4 gives a full AXI4 subordinate, TileLink a TL-UH
  /// slave and Wishbone a slave with registered feedback bursts.
  ///
  /// [wishboneBurstBeats] is the aligned block a Wishbone burst request
  /// covers. See [HarborWishboneMemorySlave]. Its mid-burst write beats get
  /// ACK before they reach the device, and a write error comes back on the
  /// last beat of the block.
  ///
  /// [clk] and [reset] are the device clock. When [fabricClock] is a
  /// different clock, the native port runs on it and a
  /// [HarborMemoryWaistCdc] of [cdcDepth] entries (default
  /// [harborCdcDepth]) crosses the waist to the device, with
  /// [deviceResetCopy] as in [HarborMemoryWaistCdc].
  ///
  /// [readOnly] adds a read-only native port instead: an [Axi4ReadOnlyInterface]
  /// on AXI4, with [HarborAxi4MemorySlaveReadOnly] in front of the waist.
  /// The waist stays a full [HarborMemoryWaist]; the adapter never raises a
  /// write request or write data, and keeps WRESP_READY high. Read-only
  /// ports exist only on AXI4: on Wishbone or TileLink this throws.
  ///
  /// [exclusive] adds an AXI4 exclusive access monitor (see
  /// [HarborAxi4ExclusiveMonitor]) keyed on the low [deviceAddressWidth]
  /// address bits, all of them when null. It needs a full AXI4 port, so with
  /// another kind or [readOnly] this throws.
  static HarborMemorySlavePort create({
    required BridgeModule module,
    required String name,
    required HarborFabricKind kind,
    required HarborMemoryWaistConfig config,
    required Logic clk,
    required Logic reset,
    int wishboneBurstBeats = 8,
    HarborFabricClock? fabricClock,
    int? cdcDepth,
    HarborResetCopy? deviceResetCopy,
    bool readOnly = false,
    HarborAxi4Exclusive? exclusive,
    int? deviceAddressWidth,
  }) {
    if (readOnly && kind != HarborFabricKind.axi4) {
      throw ArgumentError('read-only memory ports exist only on AXI4');
    }
    if (exclusive != null && (readOnly || kind != HarborFabricKind.axi4)) {
      throw ArgumentError('an exclusive monitor needs a full AXI4 port');
    }
    final waist = HarborMemoryWaist(config);
    if (fabricClock != null && fabricClock.crossesFrom(clk)) {
      final inner = create(
        module: module,
        name: name,
        kind: kind,
        config: config,
        clk: fabricClock.clk,
        reset: fabricClock.reset,
        wishboneBurstBeats: wishboneBurstBeats,
        readOnly: readOnly,
        exclusive: exclusive,
        deviceAddressWidth: deviceAddressWidth,
      );
      final cdc = HarborMemoryWaistCdc(
        fabricClk: fabricClock.clk,
        fabricReset: fabricClock.reset,
        deviceClk: clk,
        deviceReset: reset,
        fabric: inner.waist,
        device: waist,
        slave: true,
        depth: cdcDepth,
        deviceResetCopy: deviceResetCopy,
        name: '${name}_cdc',
      );
      return HarborMemorySlavePort._(
        waist,
        kind,
        inner.interfaceRef,
        cdc.deviceReset,
        cdc.depth,
        inner.waist,
      );
    }
    switch (kind) {
      case HarborFabricKind.axi4:
        if (readOnly) {
          final ref = module.addInterface(
            Axi4ReadOnlyInterface(
              addressWidth: config.addressWidth,
              dataWidth: config.dataWidth,
              idWidth: config.idWidth,
            ),
            name: name,
            role: PairRole.consumer,
          );
          HarborAxi4MemorySlaveReadOnly(
            clk: clk,
            reset: reset,
            axi: ref.internalInterface!,
            waist: waist,
            name: '${name}_axi4',
          );
          return HarborMemorySlavePort._(waist, kind, ref, reset, 0);
        }
        final ref = module.addInterface(
          _axi4(config),
          name: name,
          role: PairRole.consumer,
        );
        HarborAxi4MemorySlave(
          clk: clk,
          reset: reset,
          axi: ref.internalInterface!,
          waist: waist,
          exclusive: exclusive,
          deviceAddressWidth: deviceAddressWidth,
          name: '${name}_axi4',
        );
        return HarborMemorySlavePort._(waist, kind, ref, reset, 0);
      case HarborFabricKind.wishbone:
        final ref = module.addInterface(
          WishboneInterface(harborWishboneMemoryConfig(config)),
          name: name,
          role: PairRole.consumer,
        );
        HarborWishboneMemorySlave(
          clk: clk,
          reset: reset,
          wb: ref.internalInterface!,
          waist: waist,
          burstBeats: wishboneBurstBeats,
          name: '${name}_wishbone',
        );
        return HarborMemorySlavePort._(waist, kind, ref, reset, 0);
      case HarborFabricKind.tilelink:
        final ref = module.addInterface(
          TileLinkInterface(harborTileLinkMemoryConfig(config)),
          name: name,
          role: PairRole.consumer,
        );
        HarborTileLinkMemorySlave(
          clk: clk,
          reset: reset,
          tl: ref.internalInterface!,
          waist: waist,
          name: '${name}_tilelink',
        );
        return HarborMemorySlavePort._(waist, kind, ref, reset, 0);
    }
  }
}

/// The memory master waist of a device, with the native memory port for one
/// fabric kind built behind it.
///
/// The device is the requester. It drives requests, write data, RDATA_READY
/// and WRESP_READY on [waist]. Responses come back ordered per ID only: each
/// one carries its ID, and different IDs may come back in any order. Read
/// beats of different IDs may interleave with each other beat by beat,
/// mid-burst.
///
/// On AXI4 the device can do exclusive access with REQ_EXCLUSIVE. Add the
/// port to a fabric with `exclusiveIds`. Only the low IDs 0 to N-1 get a
/// reservation slot. An exclusive pair must use one of these IDs for both
/// accesses and keep the size rules in [HarborMemoryWaist]. Else an
/// exclusive write can change memory and still get EXOKAY 0. On Wishbone
/// and TileLink an exclusive request is a plain access with EXOKAY 0.
class HarborMemoryMasterPort {
  /// The waist the device drives as the provider.
  final HarborMemoryWaist waist;

  /// The fabric kind of the native port.
  final HarborFabricKind kind;

  /// The native interface on the module.
  final InterfaceReference<PairInterface> interfaceRef;

  /// The reset for device logic behind the waist. With a crossing it is the
  /// device reset joined with the fabric reset.
  final Logic reset;

  /// Entries in each FIFO of the crossing, or 0 when there is none.
  final int cdcDepth;

  HarborMemoryMasterPort._(
    this.waist,
    this.kind,
    this.interfaceRef,
    this.reset,
    this.cdcDepth,
  );

  /// Adds the native memory master port for [kind] to [module] and returns
  /// the waist in front of it. [fabricClock] and [cdcDepth] work as for
  /// [HarborMemorySlavePort.create]. AXI4 gives a full AXI4 manager, TileLink a
  /// TL-UH master and Wishbone a master with registered feedback bursts.
  static HarborMemoryMasterPort create({
    required BridgeModule module,
    required String name,
    required HarborFabricKind kind,
    required HarborMemoryWaistConfig config,
    required Logic clk,
    required Logic reset,
    HarborFabricClock? fabricClock,
    int? cdcDepth,
  }) {
    final waist = HarborMemoryWaist(config);
    if (fabricClock != null && fabricClock.crossesFrom(clk)) {
      final inner = create(
        module: module,
        name: name,
        kind: kind,
        config: config,
        clk: fabricClock.clk,
        reset: fabricClock.reset,
      );
      final cdc = HarborMemoryWaistCdc(
        fabricClk: fabricClock.clk,
        fabricReset: fabricClock.reset,
        deviceClk: clk,
        deviceReset: reset,
        fabric: inner.waist,
        device: waist,
        slave: false,
        depth: cdcDepth,
        name: '${name}_cdc',
      );
      return HarborMemoryMasterPort._(
        waist,
        kind,
        inner.interfaceRef,
        cdc.deviceReset,
        cdc.depth,
      );
    }
    switch (kind) {
      case HarborFabricKind.axi4:
        final ref = module.addInterface(
          _axi4(config),
          name: name,
          role: PairRole.provider,
        );
        HarborAxi4MemoryMaster(
          clk: clk,
          reset: reset,
          waist: waist,
          axi: ref.internalInterface!,
          name: '${name}_axi4',
        );
        return HarborMemoryMasterPort._(waist, kind, ref, reset, 0);
      case HarborFabricKind.wishbone:
        final ref = module.addInterface(
          WishboneInterface(harborWishboneMemoryConfig(config)),
          name: name,
          role: PairRole.provider,
        );
        HarborWishboneMemoryMaster(
          clk: clk,
          reset: reset,
          waist: waist,
          wb: ref.internalInterface!,
          name: '${name}_wishbone',
        );
        return HarborMemoryMasterPort._(waist, kind, ref, reset, 0);
      case HarborFabricKind.tilelink:
        final ref = module.addInterface(
          TileLinkInterface(harborTileLinkMemoryConfig(config)),
          name: name,
          role: PairRole.provider,
        );
        HarborTileLinkMemoryMaster(
          clk: clk,
          reset: reset,
          waist: waist,
          tl: ref.internalInterface!,
          name: '${name}_tilelink',
        );
        return HarborMemoryMasterPort._(waist, kind, ref, reset, 0);
    }
  }
}

Axi4Interface _axi4(HarborMemoryWaistConfig config) => Axi4Interface(
  addressWidth: config.addressWidth,
  dataWidth: config.dataWidth,
  idWidth: config.idWidth,
);
