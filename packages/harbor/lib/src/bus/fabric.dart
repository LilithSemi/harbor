import 'package:rohd_bridge/rohd_bridge.dart';

import 'bus.dart';
import 'bus_slave_port.dart';

/// Interconnect topology for the system bus fabric.
enum HarborFabricTopology {
  /// Shared bus with round-robin arbitration.
  sharedBus,

  /// Full crossbar allowing concurrent transactions.
  crossbar,

  /// Partial crossbar with configurable connectivity.
  partialCrossbar,
}

/// A port on the fabric connected to a bus master (CPU, DMA, etc.).
class HarborFabricMasterPort {
  /// Unique name for this master.
  final String name;

  /// Priority (lower = higher priority).
  final int priority;

  /// Bus protocol used by this master.
  final BusProtocol protocol;

  /// Address width.
  final int addressWidth;

  /// Data width.
  final int dataWidth;

  const HarborFabricMasterPort({
    required this.name,
    this.priority = 0,
    this.protocol = BusProtocol.wishbone,
    this.addressWidth = 32,
    this.dataWidth = 32,
  });
}

/// A port on the fabric connected to a bus slave (peripheral, memory, etc.).
class HarborFabricSlavePort {
  /// Unique name for this slave.
  final String name;

  /// Address region this slave occupies.
  final BusAddressRange addressRange;

  /// Bus protocol used by this slave.
  final BusProtocol protocol;

  /// Data width.
  final int dataWidth;

  const HarborFabricSlavePort({
    required this.name,
    required this.addressRange,
    this.protocol = BusProtocol.wishbone,
    this.dataWidth = 32,
  });
}

/// System bus fabric / interconnect generator.
///
/// Takes a set of master ports and slave ports with address ranges,
/// and generates the interconnect logic (arbitration, address decoding,
/// and optional protocol bridging).
///
/// ```dart
/// final fabric = HarborBusFabric(
///   topology: HarborFabricTopology.crossbar,
///   masters: [
///     HarborFabricMasterPort(name: 'cpu_i', priority: 0),
///     HarborFabricMasterPort(name: 'cpu_d', priority: 0),
///     HarborFabricMasterPort(name: 'dma', priority: 1),
///   ],
///   slaves: [
///     HarborFabricSlavePort(name: 'sram', addressRange: BusAddressRange(0x00000000, 0x10000)),
///     HarborFabricSlavePort(name: 'uart', addressRange: BusAddressRange(0x10000000, 0x1000)),
///     HarborFabricSlavePort(name: 'ddr', addressRange: BusAddressRange(0x80000000, 0x40000000)),
///   ],
/// )
/// ```
class HarborBusFabric extends BridgeModule {
  /// Interconnect topology.
  final HarborFabricTopology topology;

  /// Master ports (initiators).
  final List<HarborFabricMasterPort> masters;

  /// Slave ports (targets).
  final List<HarborFabricSlavePort> slaves;

  /// Default slave index for unmapped addresses (-1 for bus error).
  final int defaultSlaveIndex;

  /// Generated master-side bus ports.
  late final List<BusSlavePort> masterPorts;

  /// Generated slave-side bus ports (directly connectable to peripherals).
  late final List<BusSlavePort> slavePorts;

  HarborBusFabric({
    required this.topology,
    required this.masters,
    required this.slaves,
    this.defaultSlaveIndex = -1,
    String? name,
  }) : super('HarborBusFabric', name: name ?? 'fabric') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    masterPorts = [];
    slavePorts = [];

    // Create master-side ports (these face the masters, so Harbor is slave)
    for (final m in masters) {
      masterPorts.add(
        BusSlavePort.create(
          module: this,
          name: 'master_${m.name}',
          protocol: m.protocol,
          addressWidth: m.addressWidth,
          dataWidth: m.dataWidth,
          clk: input('clk'),
          reset: input('reset'),
        ),
      );
    }

    // Create slave-side ports (these face the slaves, so Harbor is master)
    for (final s in slaves) {
      slavePorts.add(
        BusSlavePort.create(
          module: this,
          name: 'slave_${s.name}',
          protocol: s.protocol,
          addressWidth: 32,
          dataWidth: s.dataWidth,
          clk: input('clk'),
          reset: input('reset'),
        ),
      );
    }

    // Note: actual signal interconnect is handled by HarborSoC.buildFabric()
    // which uses rohd_bridge's connectInterfaces. The fabric module provides
    // the port/interface structure and address map. The SoC wires them.
  }

  /// Returns the address map as a list of [HarborAddressMapping].
  List<HarborAddressMapping> get addressMap => [
    for (var i = 0; i < slaves.length; i++)
      HarborAddressMapping(slaveIndex: i, range: slaves[i].addressRange),
  ];
}
