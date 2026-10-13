import 'package:rohd/rohd.dart';

import 'axi4/axi4_fabric.dart';
import 'bus.dart';
import 'bus_error_source.dart';
import 'port/fabric_kind.dart';
import 'tilelink/tilelink_fabric.dart';
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

  const HarborFabricMaster({
    required this.name,
    required this.interface,
    this.outstanding,
    this.memory = true,
    this.reach,
    this.readChannel,
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

  const HarborFabricSlave({
    required this.name,
    required this.range,
    required this.interface,
    this.outstanding = 1,
    this.timeout = 0,
    this.memory = true,
    this.offset = false,
    this.readInterfaces = const [],
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

  /// Sticky flag, high after an error went to a master that has no error
  /// signal, so the master saw a normal response. Null when every master
  /// has an error signal.
  Logic? get foldError => tryOutput('fold_error');
}

/// Builds and checks bus fabrics on the SoC bus clock, natively for one
/// [HarborFabricKind].
abstract final class HarborFabric {
  /// Builds a fabric of [kind] with [topology] on [clk].
  ///
  /// [wishboneBurstBeats] is the aligned block of a Wishbone memory burst.
  /// The address map check uses it on Wishbone fabrics. [maxGrantCycles] is
  /// the Wishbone grant hold cap (see [WishboneArbiter.maxGrantCycles]). It
  /// is for Wishbone fabrics only.
  static HarborFabricModule build({
    required HarborFabricKind kind,
    required HarborFabricTopology topology,
    required Logic clk,
    required Logic reset,
    required List<HarborFabricMaster> masters,
    required List<HarborFabricSlave> slaves,
    int wishboneBurstBeats = 8,
    int? maxGrantCycles,
    String name = 'fabric',
  }) {
    if (maxGrantCycles != null && kind != HarborFabricKind.wishbone) {
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
          maxGrantCycles: maxGrantCycles,
          name: name,
        );
    }
  }

  /// Checks the slave regions of a fabric. Returns error messages, empty
  /// when the map is good.
  ///
  /// - Every region is inside the address space and no two overlap.
  /// - A region of 4 KB or more starts and ends on a 4 KB boundary, so an
  ///   AXI4 burst never leaves it. A smaller region is a power of two in
  ///   size and starts on a multiple of its size.
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
