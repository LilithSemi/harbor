import 'dart:math';

import 'package:rohd/rohd.dart';

import 'axi4/axi4_exclusive.dart';
import 'axi4/axi4_fabric.dart';
import 'bus.dart';
import 'bus_error_source.dart';
import 'port/fabric_kind.dart';
import 'tilelink/tilelink_fabric.dart';
import 'tilelink/tilelink_interface.dart';
import 'wishbone/wishbone_arbiter.dart';
import 'wishbone/wishbone_fabric.dart';

/// How a fabric connects its masters to its slaves.
enum HarborFabricTopology {
  /// One bus per request channel with a round robin arbiter. Responses come
  /// back on one shared channel per direction and go to the master named by
  /// the master index prefix of their ID.
  shared,

  /// An arbiter per slave and an address decoder per master, so masters
  /// that use different slaves move at the same time.
  crossbar,
}

/// A master on a fabric. [interface] is the native port of the master
/// device, for example an `Axi4Interface` on an AXI4 fabric.
///
/// A master must not make its write data wait for the response of a later
/// request. On a shared fabric, write data moves in one global order.
class HarborFabricMaster {
  /// Unique name. The fabric ports for this master are `<name>_*`.
  final String name;

  /// The native interface the master device drives.
  final PairInterface interface;

  /// Most requests in flight per direction from this master. Null gives 1
  /// on Wishbone and 4 on the other kinds (see [outstandingOn]).
  final int? outstanding;

  /// Names of the slaves this master can reach. Null reaches every slave.
  /// An access to a slave out of reach ends with the decode error.
  final Set<String>? reach;

  /// True for a memory port (AXI4, TileLink-UH, Wishbone with bursts), false
  /// for a register port (AXI4-Lite, TileLink-UL, Wishbone classic).
  final bool memory;

  /// The read channel this master uses at every slave with more than one
  /// read channel (see [HarborFabricSlave.readChannels]). Null spreads
  /// masters round robin over the channels that no override claims at that
  /// slave, in master list order. So giving only the display channel 1 keeps
  /// every other master on the rest. When the overrides claim every
  /// channel, the others spread over all of them. Writes always use
  /// channel 0.
  final int? readChannel;

  /// AXI4 exclusive access: null or 0 for none, N to give the low IDs 0 to
  /// N-1 a reservation slot in each monitored memory slave, or
  /// [HarborExclusive.auto] to let the builder pick N from a slot budget
  /// (see [HarborExclusive.slotCounts]). An exclusive access on an ID with
  /// no slot gets OKAY. Only a full AXI4 master on an AXI4 fabric can set
  /// it. Slots cost timing: in one ECP5 check, 4 masters with 16 slots each
  /// reached about 80 MHz, against about 111 MHz with 2 slots each.
  final int? exclusiveIds;

  /// True when this master uses exclusive access.
  bool get exclusive => (exclusiveIds ?? 0) != 0;

  /// True for a real-time master. Its requests win arbitration, and while
  /// one waits, the bursts of the other masters toward the same slave are
  /// capped (see [HarborFabric.build]).
  final bool realtime;

  /// True when this master never stalls its write data inside a burst: it
  /// holds the data of a whole burst before it sends the request, or each
  /// beat follows the last without a gap. The real-time wait bound holds only
  /// with such masters (see [HarborFabric.realtimeWaitBound]).
  final bool writeStallFree;

  const HarborFabricMaster({
    required this.name,
    required this.interface,
    this.outstanding,
    this.memory = true,
    this.reach,
    this.readChannel,
    this.exclusiveIds,
    this.realtime = false,
    this.writeStallFree = false,
  });

  /// The outstanding limit of this master on a fabric of [kind].
  int outstandingOn(HarborFabricKind kind) =>
      outstanding ?? (kind == HarborFabricKind.wishbone ? 1 : 4);

  /// True when this master can reach the slave named [slave].
  bool reaches(String slave) => reach?.contains(slave) ?? true;

  /// Name tag for the reach set over [slaves], empty when it reaches all.
  String reachTag(List<HarborFabricSlave> slaves) {
    if (reach == null) return '';
    var mask = BigInt.zero;
    for (var i = 0; i < slaves.length; i++) {
      if (reaches(slaves[i].name)) mask |= BigInt.one << i;
    }
    return 'R${mask.toRadixString(16)}';
  }
}

/// A slave on a fabric. [interface] is the native port of the slave device.
///
/// The slave must use the reset of the fabric. The fabric has no record of
/// a response that comes after a reset of the fabric only.
class HarborFabricSlave {
  /// Unique name. The fabric ports for this slave are `<name>_*`.
  final String name;

  /// Address region of the slave. The slave sees the full address unless
  /// [offset] is set.
  final BusAddressRange range;

  /// The native interface the slave device answers on.
  final PairInterface interface;

  /// Most requests in flight at the slave, both directions together. The
  /// fabric never issues more. AXI4-Lite and Wishbone slaves have 1.
  final int outstanding;

  /// Cycles the slave may owe a response with no progress before the fabric
  /// cuts it off. 0 turns the timeout off.
  final int timeout;

  /// True for a memory port (AXI4, TileLink-UH, Wishbone with bursts), false
  /// for a register port (AXI4-Lite, TileLink-UL, Wishbone classic).
  final bool memory;

  /// When set, the slave sees the address minus the start of [range], so
  /// the device does not depend on where it sits in the map.
  final bool offset;

  /// Extra read-only native ports on this slave, one per extra read
  /// channel. On AXI4 each entry is an [Axi4ReadOnlyInterface] with this
  /// slave's widths. Only an AXI4 fabric supports this; TileLink and
  /// Wishbone builders throw when this is not empty.
  final List<PairInterface> readInterfaces;

  /// The AXI4 exclusive monitor of this slave, or null when it has none.
  /// The fabric checks that its slots are those of its exclusive masters
  /// (see [HarborAxi4Fabric.exclusiveOf]) and that the slave sees full
  /// master IDs.
  final HarborAxi4Exclusive? exclusive;

  /// True when the fabric may put a width adapter in front of this slave if
  /// its port is narrower than the fabric. Only a register slave may set it.
  /// Software reads a memory window such as a SPI flash XIP window with
  /// wide loads, and a fetch reads whole words, so such a window must be
  /// built with the fabric data width instead.
  /// On AXI4, a read wider than the slave returns the lane at its address,
  /// 0 in the other lanes and OKAY.
  final bool narrowOk;

  const HarborFabricSlave({
    required this.name,
    required this.range,
    required this.interface,
    this.outstanding = 1,
    this.timeout = 0,
    this.memory = true,
    this.offset = false,
    this.readInterfaces = const [],
    this.exclusive,
    this.narrowOk = false,
  });

  /// The value the fabric subtracts from each address to this slave.
  int get base => offset ? range.start : 0;

  /// Most read channels at this slave: 1 plus [readInterfaces.length].
  /// Channel 0 is the full port and counts reads and writes together, as
  /// [outstanding] always has. Each extra channel is read-only and holds
  /// up to [outstanding] reads in flight on its own.
  int get readChannels => 1 + readInterfaces.length;
}

/// A fabric module built by [HarborFabric.build].
///
/// - Addresses that hit no slave go to an internal error slave that gives
///   the native decode error.
/// - A slave with a timeout that stops making progress gets cut off until
///   reset. Its requests then end with a slave error, its late responses are
///   dropped, and [busError] goes high and stays high.
abstract class HarborFabricModule extends Module with HarborBusErrorSource {
  HarborFabricModule({required super.definitionName, super.name});

  @override
  Logic get busError => output('bus_error');

  /// Slaves the fabric cut off, on the fabric clock. A slave stays cut off
  /// until reset, so this is also the number of timeouts since reset.
  Logic get timeoutCount => output('timeout_count');

  /// Sticky flag, high after an error went to a master that has no error
  /// signal, so the master saw a normal response. Null when every master
  /// has an error signal.
  Logic? get foldError => tryOutput('fold_error');
}

/// The Wishbone grant hold cap a fabric with two or more masters uses when
/// the caller gives none.
const harborDefaultWishboneGrantCap = 16;

/// Builds and checks bus fabrics on the SoC bus clock, natively for one
/// [HarborFabricKind].
abstract final class HarborFabric {
  /// Builds a fabric of [kind] with [topology] on [clk].
  ///
  /// [wishboneBurstBeats] is the aligned block of a Wishbone memory burst.
  /// The address map check uses it on Wishbone fabrics. [maxGrantCycles] is
  /// the Wishbone grant hold cap (see [WishboneArbiter.maxGrantCycles]). It
  /// is for Wishbone fabrics only. It defaults to
  /// [harborDefaultWishboneGrantCap] on a fabric with two or more masters.
  /// Null or 0 turns the cap off. A fabric with one master has no cap.
  ///
  /// A master with [HarborFabricMaster.realtime] wins every arbitration it
  /// is part of. [realtimeBurstCap] is the most beats of a burst of another
  /// master that go to a slave in one grant while a real-time request
  /// waits, and [realtimeWaitBound] gives the resulting wait. A fabric with
  /// no real-time master ignores it and builds the same logic as before.
  ///
  /// - Wishbone: a burst of another master ends with CTI 111 at the capped
  ///   beat. The master keeps CYC and STB, and it gets the rest of its
  ///   burst after the real-time transfer.
  /// - AXI4: a burst longer than the cap goes to the slave as bursts of up
  ///   to [realtimeBurstCap] beats, each with its own grant. The master
  ///   still sees one burst. Only INCR bursts split: a FIXED or WRAP burst
  ///   has 16 beats or fewer and goes whole.
  /// - TileLink: a message cannot be cut, so the cap does not apply. A
  ///   real-time message waits for the message that holds the target. The
  ///   largest message of the other masters sets the bound.
  static HarborFabricModule build({
    required HarborFabricKind kind,
    required HarborFabricTopology topology,
    required Logic clk,
    required Logic reset,
    required List<HarborFabricMaster> masters,
    required List<HarborFabricSlave> slaves,
    int wishboneBurstBeats = 8,
    int? maxGrantCycles = harborDefaultWishboneGrantCap,
    int realtimeBurstCap = defaultRealtimeBurstCap,
    String name = 'fabric',
  }) {
    if (realtimeBurstCap < 1) {
      throw ArgumentError.value(
        realtimeBurstCap,
        'realtimeBurstCap',
        'must be >= 1',
      );
    }
    if (maxGrantCycles != null && maxGrantCycles < 0) {
      throw ArgumentError.value(
        maxGrantCycles,
        'maxGrantCycles',
        'must be 0 (off) or >= 1',
      );
    }
    if (maxGrantCycles != null &&
        maxGrantCycles != harborDefaultWishboneGrantCap &&
        kind != HarborFabricKind.wishbone) {
      throw ArgumentError.value(
        maxGrantCycles,
        'maxGrantCycles',
        'is for Wishbone fabrics only',
      );
    }
    switch (kind) {
      case HarborFabricKind.axi4:
        return HarborAxi4Fabric(
          topology: topology,
          clk: clk,
          reset: reset,
          masters: masters,
          slaves: slaves,
          realtimeBurstCap: realtimeBurstCap,
          name: name,
        );
      case HarborFabricKind.tilelink:
        return HarborTileLinkFabric(
          topology: topology,
          clk: clk,
          reset: reset,
          masters: masters,
          slaves: slaves,
          name: name,
        );
      case HarborFabricKind.wishbone:
        return HarborWishboneFabric(
          topology: topology,
          clk: clk,
          reset: reset,
          masters: masters,
          slaves: slaves,
          wishboneBurstBeats: wishboneBurstBeats,
          maxGrantCycles: masters.length < 2 || maxGrantCycles == 0
              ? null
              : maxGrantCycles,
          realtimeBurstCap: realtimeBurstCap,
          name: name,
        );
    }
  }

  /// The default of [build]'s `realtimeBurstCap`, in beats.
  static const int defaultRealtimeBurstCap = 16;

  /// The most cycles a real-time request waits before a slave starts to
  /// serve it, in a fabric of [kind] built with [realtimeBurstCap] [cap].
  /// One beat takes [beatCycles] cycles at the slave. Each memory access that
  /// comes before the first beat of the request, with the access of the
  /// request itself, costs [accessCycles] (the worst first access latency of
  /// the memory itself) plus [pathCycles] (the register stages of the path
  /// between the master and the memory, see [pathCyclesOf]). The bound is the
  /// wait until the first response beat, so a caller does not add the access
  /// of the memory again.
  ///
  /// - [masters] holds every master that reaches the slave. At least one
  ///   has [HarborFabricMaster.realtime]. A real-time master has up to one
  ///   transfer ahead of the request, for each other real-time master.
  /// - [realtimeBeats] is the longest transfer of a real-time master in
  ///   beats. Real-time masters are not capped.
  /// - [slaveOutstanding] is the [HarborFabricSlave.outstanding] of the
  ///   slave.
  /// - [sharedSlaves] is the number of slaves that share one response
  ///   channel with the slave: all slaves on a shared fabric, 1 on a
  ///   crossbar.
  /// - [maxMessageBeats] is the beats of the largest TileLink message of
  ///   the other masters. Null takes it from the size field of their ports,
  ///   which is a very large figure, so a build that wants a useful bound
  ///   gives it.
  /// - [wishboneBurstBeats] is the aligned burst block of the Wishbone
  ///   memory slave.
  /// - [wishboneGrantCap] is the Wishbone grant hold cap of the fabric (see
  ///   [harborDefaultWishboneGrantCap] after the cap lands). An owner holds
  ///   the grant for at most that many cycles, so a burst that the real-time
  ///   cap does not cut ends there, and the bound uses the smaller of the two
  ///   for `cap`. Null means no grant cap.
  ///
  /// Formulas, with `r` for the real-time masters, `rt` for [realtimeBeats],
  /// `bc` for [beatCycles] and `ac` for [accessCycles] plus [pathCycles]:
  /// - Wishbone: `(oc + 1 + (r - 1) * rt + (burst - 1)) * bc + n * ac + 3`,
  ///   with `oc = min(cap, grant cap)`,
  ///   with `n = ceil((cap + 1) / burst) + 1 + (r - 1) * ceil(rt / burst) +
  ///   1` accesses: the blocks the owner can cross, one more for the burst
  ///   that the slave finishes after a cut, the blocks of the other
  ///   real-time masters, and the access of the request itself.
  ///   The owner of the bus ends its burst at the cap, and a transfer
  ///   already in progress when the real-time request comes ends first.
  ///   After a cut the slave finishes the aligned block of its burst, up to
  ///   `burst - 1` beats. A grant is a register, so the next owner starts 2
  ///   cycles after the end and 1 more cycle covers the cut transfer. The
  ///   wait for the write response of the last write transfer is part of
  ///   `ac`.
  /// - AXI4: `shared * (outstanding + r - 1) * (max(max(cap, 16), rt) * bc +
  ///   ac + 4) + ac + 8`. The slave has up to `outstanding` requests ahead and
  ///   each other real-time master adds one request ahead. A request is a
  ///   burst of at most the cap (a FIXED or WRAP burst has up to 16 beats),
  ///   and the response channel is shared with the other slaves. A request
  ///   crosses the fabric stages in a few cycles.
  /// - TileLink: `(shared * outstanding + r) * (max(maxMessage, rt) * bc +
  ///   ac) + ac + 8`. A message cannot be cut, so the cap does not apply.
  ///
  /// The AXI4 bound is for reads. It holds when every master takes R and B
  /// beats at once (RREADY and BREADY high) and sends write data without
  /// stalls. A real-time write path needs more terms.
  ///
  /// The bound throws [ArgumentError] when a master that is not real-time
  /// does not declare [HarborFabricMaster.writeStallFree], unless
  /// [allowUnproven] is set. [allowUnproven] is a recorded best-effort flag.
  static int realtimeWaitBound({
    required HarborFabricKind kind,
    required List<HarborFabricMaster> masters,
    required int cap,
    int slaveOutstanding = 1,
    int sharedSlaves = 1,
    int? realtimeBeats,
    int? maxMessageBeats,
    int beatCycles = 1,
    int accessCycles = 0,
    int pathCycles = 0,
    int wishboneBurstBeats = 8,
    int? wishboneGrantCap,
    bool allowUnproven = false,
  }) {
    if (cap < 1) {
      throw ArgumentError.value(cap, 'cap', 'must be >= 1');
    }
    if (slaveOutstanding < 1 ||
        sharedSlaves < 1 ||
        beatCycles < 1 ||
        accessCycles < 0 ||
        pathCycles < 0 ||
        wishboneBurstBeats < 1) {
      throw ArgumentError(
        'slaveOutstanding, sharedSlaves, beatCycles and wishboneBurstBeats '
        'must be >= 1, accessCycles and pathCycles >= 0',
      );
    }
    final r = masters.where((m) => m.realtime).length;
    if (r < 1) {
      throw ArgumentError.value(masters, 'masters', 'has no realtime master');
    }
    if (!allowUnproven) {
      final open = [
        for (final m in masters)
          if (!m.realtime && !m.writeStallFree) m.name,
      ];
      if (open.isNotEmpty) {
        throw ArgumentError(
          'the bound holds only for masters that never stall write data '
          'inside a burst, and $open do not declare writeStallFree. Declare '
          'it, or pass allowUnproven to take the bound without that proof.',
        );
      }
    }
    final rt = realtimeBeats ?? cap;
    final ac = accessCycles + pathCycles;
    final ownerCap = wishboneGrantCap == null || wishboneGrantCap < 1
        ? cap
        : min(cap, wishboneGrantCap);
    switch (kind) {
      case HarborFabricKind.wishbone:
        int blocks(int beats) =>
            (beats + wishboneBurstBeats - 1) ~/ wishboneBurstBeats;
        final accesses = blocks(ownerCap + 1) + 1 + (r - 1) * blocks(rt) + 1;
        return (ownerCap + 1 + (r - 1) * rt + (wishboneBurstBeats - 1)) *
                beatCycles +
            accesses * ac +
            3;
      case HarborFabricKind.axi4:
        final int piece = max<int>(max<int>(cap, 16), rt);
        return sharedSlaves *
                (slaveOutstanding + r - 1) *
                (piece * beatCycles + ac + 4) +
            ac +
            8;
      case HarborFabricKind.tilelink:
        final int message =
            maxMessageBeats ?? _tileLinkMaxMessageBeats(masters);
        return (sharedSlaves * slaveOutstanding + r) *
                (max<int>(message, rt) * beatCycles + ac) +
            ac +
            8;
    }
  }

  /// Register stages of the path of one access, from the master to the first
  /// response beat, as an upper bound. A caller passes the sum as
  /// `pathCycles` of [realtimeWaitBound].
  ///
  /// - [fabrics] is the number of fabrics the access crosses: 1, or 2 through
  ///   a channel fabric and a converge fabric.
  /// - A fabric has 2 stages on Wishbone (the grant register and the
  ///   response), and 4 on AXI4 and TileLink (the request FIFOs of the master
  ///   and the slave side, the response FIFO, and the response arbitration).
  /// - [memoryPorts] is the number of memory master and slave port pairs. A
  ///   pair has 8 stages: the request, data and response FIFOs of both ports.
  /// - [registerStages] is the number of `WishboneRegisterStage` slices on
  ///   the path (`HarborSoC.buildFabric` with `pipeline`, or a master with
  ///   `pipeline`). Each costs 2 cycles.
  /// - [cdcCycles] is the latency of each clock crossing on the path, from
  ///   its own documentation.
  static int pathCyclesOf({
    required HarborFabricKind kind,
    int fabrics = 1,
    int memoryPorts = 1,
    int registerStages = 0,
    int cdcCycles = 0,
  }) =>
      fabrics * (kind == HarborFabricKind.wishbone ? 2 : 4) +
      memoryPorts * 8 +
      registerStages * 2 +
      cdcCycles;

  /// The wait of a real-time request that goes through a channel fabric and
  /// then a converge fabric to a slave (see `HarborSoC.buildFabric`).
  ///
  /// It is [realtimeWaitBound] of the channel fabric, with [channelMasters],
  /// plus [realtimeWaitBound] of the converge fabric, with [convergeMasters]
  /// (the legs of the channels, one of them real-time), less one access
  /// ([accessCycles] plus [pathCycles]). Both fabrics charge the access of
  /// each transfer ahead, because a transfer ahead in either fabric has its
  /// own memory access, and the access of the request itself counts once.
  /// [pathCycles] is the path of the whole access (`pathCyclesOf` with
  /// `fabrics: 2`). [channelSharedSlaves] and [convergeSharedSlaves] are the
  /// [sharedSlaves] of each fabric, and [slaveOutstanding] and
  /// [channelSlaveOutstanding] are the limits at the slave and at the leg
  /// (the same by default). The other parameters are those of
  /// [realtimeWaitBound].
  static int realtimeWaitBoundThrough({
    required HarborFabricKind kind,
    required List<HarborFabricMaster> channelMasters,
    required List<HarborFabricMaster> convergeMasters,
    required int cap,
    int slaveOutstanding = 1,
    int? channelSlaveOutstanding,
    int channelSharedSlaves = 1,
    int convergeSharedSlaves = 1,
    int? realtimeBeats,
    int? maxMessageBeats,
    int beatCycles = 1,
    int accessCycles = 0,
    int pathCycles = 0,
    int wishboneBurstBeats = 8,
    int? wishboneGrantCap,
    bool allowUnproven = false,
  }) =>
      realtimeWaitBound(
        kind: kind,
        masters: channelMasters,
        cap: cap,
        slaveOutstanding: channelSlaveOutstanding ?? slaveOutstanding,
        sharedSlaves: channelSharedSlaves,
        realtimeBeats: realtimeBeats,
        maxMessageBeats: maxMessageBeats,
        beatCycles: beatCycles,
        accessCycles: accessCycles,
        pathCycles: pathCycles,
        wishboneBurstBeats: wishboneBurstBeats,
        wishboneGrantCap: wishboneGrantCap,
        allowUnproven: allowUnproven,
      ) +
      realtimeWaitBound(
        kind: kind,
        masters: convergeMasters,
        cap: cap,
        slaveOutstanding: slaveOutstanding,
        sharedSlaves: convergeSharedSlaves,
        realtimeBeats: realtimeBeats,
        maxMessageBeats: maxMessageBeats,
        beatCycles: beatCycles,
        accessCycles: accessCycles,
        pathCycles: pathCycles,
        wishboneBurstBeats: wishboneBurstBeats,
        wishboneGrantCap: wishboneGrantCap,
        allowUnproven: allowUnproven,
      ) -
      (accessCycles + pathCycles);

  static int _tileLinkMaxMessageBeats(List<HarborFabricMaster> masters) {
    var most = 1;
    for (final m in masters) {
      if (m.realtime) continue;
      final intf = m.interface;
      if (intf is! TileLinkInterface) continue;
      final c = intf.config;
      final bytes = BigInt.one << ((1 << c.sizeWidth) - 1);
      final beats = (bytes ~/ BigInt.from(c.dataWidth ~/ 8)).toInt();
      most = max(most, max(1, beats));
    }
    return most;
  }

  /// Checks the slave regions of a fabric. Returns error messages, empty
  /// when the map is good.
  ///
  /// - Every region is inside the address space and no two overlap.
  /// - A region of 4 KB or more starts and ends on a 4 KB boundary, so an
  ///   AXI4 burst never leaves it. A smaller region is a power of two in
  ///   size and starts on a multiple of its size.
  /// - On AXI4, a region holds at least one data word, so a write strobe
  ///   never falls outside the bits of the slave address.
  /// - On Wishbone, a memory slave region holds at least one burst block of
  ///   [wishboneBurstBeats] beats and starts on a block boundary, so the pad
  ///   beats of a burst never leave the region.
  static List<String> validateAddressMap({
    required HarborFabricKind kind,
    required List<HarborFabricSlave> slaves,
    required int addressWidth,
    required int dataWidth,
    int wishboneBurstBeats = 8,
  }) {
    final errors = <String>[];
    final top = BigInt.one << addressWidth;
    for (final s in slaves) {
      final r = s.range;
      if (r.size <= 0 || r.start < 0) {
        errors.add('${s.name}: $r is empty or negative');
        continue;
      }
      if (BigInt.from(r.start) + BigInt.from(r.size) > top) {
        errors.add('${s.name}: $r is outside $addressWidth address bits');
      }
      if (kind == HarborFabricKind.axi4 && r.size < dataWidth ~/ 8) {
        errors.add(
          '${s.name}: $r is smaller than the ${dataWidth ~/ 8} byte AXI4 '
          'data word',
        );
      }
      if (r.size >= 0x1000) {
        if (r.start % 0x1000 != 0 || r.size % 0x1000 != 0) {
          errors.add('${s.name}: $r is not on 4 KB boundaries');
        }
      } else if (r.size & (r.size - 1) != 0 || r.start % r.size != 0) {
        errors.add(
          '${s.name}: $r is under 4 KB and not a power of two aligned to '
          'its size',
        );
      }
      if (kind == HarborFabricKind.wishbone && s.memory) {
        final block = wishboneBurstBeats * (dataWidth ~/ 8);
        if (r.size < block || r.start % block != 0) {
          errors.add(
            '${s.name}: $r does not hold an aligned Wishbone burst block of '
            '$block bytes',
          );
        }
      }
    }
    final mappings = [
      for (var i = 0; i < slaves.length; i++)
        HarborAddressMapping(range: slaves[i].range, slaveIndex: i),
    ];
    errors.addAll(validateAddressMappings(mappings));
    return errors;
  }

  /// True when a fabric of [kind] can deliver a multi-beat burst to a slave
  /// port with the [HarborFabricSlave.memory] flag [memory].
  ///
  /// - AXI4: every slave. An AXI4-Lite slave gets the burst as single beat
  ///   requests from the fabric.
  /// - Wishbone: every slave. A classic slave sees the beats of a burst as
  ///   classic cycles.
  /// - TileLink: memory slaves only. A TL-UL slave takes one beat or less,
  ///   and a larger message to it ends denied.
  static bool slaveTakesBursts(HarborFabricKind kind, {required bool memory}) =>
      switch (kind) {
        HarborFabricKind.axi4 || HarborFabricKind.wishbone => true,
        HarborFabricKind.tilelink => memory,
      };

  /// Throws [ArgumentError] when the master and slave lists cannot form a
  /// fabric of [kind]. Each builder calls it first.
  static void checkPorts({
    required HarborFabricKind kind,
    required List<HarborFabricMaster> masters,
    required List<HarborFabricSlave> slaves,
    required int addressWidth,
    required int dataWidth,
    int wishboneBurstBeats = 8,
  }) {
    if (masters.isEmpty) {
      throw ArgumentError.value(masters, 'masters', 'must not be empty');
    }
    final names = [
      for (final m in masters) m.name,
      for (final s in slaves) s.name,
    ];
    if (names.toSet().length != names.length) {
      throw ArgumentError('master and slave names must be unique: $names');
    }
    final slaveNames = {for (final s in slaves) s.name};
    for (final m in masters) {
      if (m.outstandingOn(kind) < 1) {
        throw ArgumentError('${m.name}: outstanding must be >= 1');
      }
      final unknown = m.reach?.difference(slaveNames) ?? const <String>{};
      if (unknown.isNotEmpty) {
        throw ArgumentError('${m.name}: reach names no slave: $unknown');
      }
    }
    for (final s in slaves) {
      if (s.outstanding < 1 || s.timeout < 0) {
        throw ArgumentError(
          '${s.name}: outstanding must be >= 1 and timeout >= 0',
        );
      }
      if (kind != HarborFabricKind.axi4 && s.readInterfaces.isNotEmpty) {
        throw ArgumentError('${s.name}: readChannels > 1 needs an AXI4 fabric');
      }
      if (kind != HarborFabricKind.axi4 && s.exclusive != null) {
        throw ArgumentError('${s.name}: an exclusive monitor needs AXI4');
      }
    }
    for (final m in masters) {
      if (kind != HarborFabricKind.axi4 && m.exclusive) {
        throw ArgumentError('${m.name}: exclusive access needs AXI4');
      }
    }
    for (final m in masters) {
      final rc = m.readChannel;
      if (rc == null) continue;
      if (rc < 0) {
        throw ArgumentError('${m.name}: readChannel must be >= 0');
      }
      for (final s in slaves) {
        if (s.readChannels <= 1 || !m.reaches(s.name)) continue;
        if (rc >= s.readChannels) {
          throw ArgumentError(
            '${m.name}: readChannel $rc is out of range for ${s.name} '
            'with ${s.readChannels} read channels',
          );
        }
      }
    }
    final errors = validateAddressMap(
      kind: kind,
      slaves: slaves,
      addressWidth: addressWidth,
      dataWidth: dataWidth,
      wishboneBurstBeats: wishboneBurstBeats,
    );
    if (errors.isNotEmpty) {
      throw ArgumentError('bad address map:\n${errors.join('\n')}');
    }
  }

  /// The read channel at [slave] for each master in [masters], in list
  /// order: -1 for a master that does not reach [slave], else the master's
  /// explicit [HarborFabricMaster.readChannel], else the next channel in
  /// round robin order over the channels no override claims (all channels
  /// when the overrides claim every one). Always 0 when
  /// [slave] has only one read channel, even for a master with an
  /// explicit [HarborFabricMaster.readChannel] set for some other slave.
  static List<int> readChannelsOf(
    HarborFabricSlave slave,
    List<HarborFabricMaster> masters,
  ) {
    final out = <int>[];
    if (slave.readChannels <= 1) {
      return [for (final m in masters) m.reaches(slave.name) ? 0 : -1];
    }
    // Masters with no override share the channels no override claims, or
    // every channel when the overrides claim them all.
    final claimed = {
      for (final m in masters)
        if (m.reaches(slave.name) && m.readChannel != null) m.readChannel!,
    };
    var free = [
      for (var c = 0; c < slave.readChannels; c++)
        if (!claimed.contains(c)) c,
    ];
    if (free.isEmpty) free = [for (var c = 0; c < slave.readChannels; c++) c];
    var rank = 0;
    for (final m in masters) {
      if (!m.reaches(slave.name)) {
        out.add(-1);
      } else if (m.readChannel != null) {
        out.add(m.readChannel!);
      } else {
        out.add(free[rank++ % free.length]);
      }
    }
    return out;
  }
}
