import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';

/// Read-only flash/ROM memory module.
///
/// Provides a single-cycle read-only memory with a Wishbone slave
/// interface. Write requests are silently ignored.
///
/// Used for boot ROM, firmware storage, etc.
class HarborFlash extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// Memory size in bytes.
  final int size;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Data width in bits.
  final int dataWidth;

  /// Bus slave port.
  late final BusSlavePort bus;

  HarborFlash({
    required this.baseAddress,
    required this.size,
    this.dataWidth = 32,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborFlash', name: name ?? 'flash') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    final addrWidth = (size ~/ (dataWidth ~/ 8)).bitLength;

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: addrWidth,
      dataWidth: dataWidth,
    );

    final clk = input('clk');
    final datOut = bus.dataOut;
    final ack = bus.ack;
    final stb = bus.stb;

    Sequential(clk, [
      ack < Const(0),
      datOut < Const(0, width: dataWidth),
      If(
        stb & ~ack,
        then: [
          ack < Const(1),
          // Read-only: writes are ignored, reads return data
          // Actual ROM content would be loaded via initial values
          // or an external memory init file
        ],
      ),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,flash', 'mtd-rom'],
    reg: BusAddressRange(baseAddress, size),
    properties: {'data-width': dataWidth},
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, size)],
    properties: {
      'compatible': ['harbor,flash', 'mtd-rom'],
      'data-width': dataWidth,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'FLASH',
    groupName: 'FLASH',
    description: 'Read-only flash/ROM memory',
    baseAddress: baseAddress,
    size: size,
  );
}
