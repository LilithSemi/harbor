import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';

/// RISC-V Incoming MSI Controller (IMSIC).
///
/// Part of the RISC-V Advanced Interrupt Architecture (AIA).
/// Each hart has its own IMSIC instance that receives Message
/// Signaled Interrupts (MSIs) from devices (PCIe, IOMMU, etc.)
/// and presents them as external interrupts.
///
/// Each IMSIC has per-privilege-level interrupt files:
/// - Machine-level interrupt file
/// - Supervisor-level interrupt file
/// - VS-level interrupt files (one per guest, for H extension)
///
/// Register map (per interrupt file, memory-mapped):
/// - 0x000: seteipnum  (write-only, set EIP bit by number)
/// - 0x004: reserved
/// - Accessed via IMSIC CSRs (miselect/mireg or siselect/sireg):
///   - eidelivery, eithreshold, eip[], eie[]
///
/// The IMSIC address for each hart is used as the MSI target address
/// by devices. Writing an interrupt identity to seteipnum sets the
/// corresponding pending bit.
class HarborImsic extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// Base address for this hart's IMSIC.
  final int baseAddress;

  /// Number of external interrupt identities (max 2048).
  final int numIds;

  /// Number of guest interrupt files (for H extension).
  final int numGuests;

  /// Hart index this IMSIC belongs to.
  final int hartIndex;

  /// Bus slave port (for MSI writes from devices).
  late final BusSlavePort bus;

  /// External interrupt output to hart (machine level).
  Logic get meip => output('meip');

  /// External interrupt output to hart (supervisor level).
  Logic get seip => output('seip');

  /// Per-guest external interrupt outputs (null if numGuests == 0).
  Logic? get vseip => numGuests > 0 ? output('vseip') : null;

  HarborImsic({
    required this.baseAddress,
    this.numIds = 256,
    this.numGuests = 0,
    this.hartIndex = 0,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborImsic', name: name ?? 'imsic_hart$hartIndex') {
    assert(numIds > 0 && numIds <= 2048, 'numIds must be 1-2048');
    assert(numIds & (numIds - 1) == 0, 'numIds must be power of 2');

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    addOutput('meip'); // machine external interrupt pending
    addOutput('seip'); // supervisor external interrupt pending
    if (numGuests > 0) {
      addOutput('vseip', width: numGuests);
    }

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: 12,
      dataWidth: 32,
    );

    // CSR interface (miselect/mireg, siselect/sireg)
    createPort('csr_select', PortDirection.input, width: 12);
    createPort('csr_write', PortDirection.input);
    createPort('csr_wdata', PortDirection.input, width: 64);
    addOutput('csr_rdata', width: 64);
    createPort('csr_priv', PortDirection.input, width: 2); // M=3, S=1, VS=0

    final clk = input('clk');
    final reset = input('reset');

    // Number of 64-bit EIP/EIE registers needed
    final numRegs = (numIds + 63) ~/ 64;

    // Machine interrupt file
    final mEip = <Logic>[
      for (var i = 0; i < numRegs; i++) Logic(name: 'm_eip$i', width: 64),
    ];
    final mEie = <Logic>[
      for (var i = 0; i < numRegs; i++) Logic(name: 'm_eie$i', width: 64),
    ];
    final mEidelivery = Logic(name: 'm_eidelivery');
    final mEithreshold = Logic(name: 'm_eithreshold', width: 11);

    // Supervisor interrupt file
    final sEip = <Logic>[
      for (var i = 0; i < numRegs; i++) Logic(name: 's_eip$i', width: 64),
    ];
    final sEie = <Logic>[
      for (var i = 0; i < numRegs; i++) Logic(name: 's_eie$i', width: 64),
    ];
    final sEidelivery = Logic(name: 's_eidelivery');
    final sEithreshold = Logic(name: 's_eithreshold', width: 11);

    // Interrupt pending = any (EIP & EIE) bit set and delivery enabled
    Logic mPending = Const(0);
    Logic sPending = Const(0);
    for (var i = 0; i < numRegs; i++) {
      mPending = mPending | (mEip[i] & mEie[i]).or();
      sPending = sPending | (sEip[i] & sEie[i]).or();
    }
    meip <= mPending & mEidelivery;
    seip <= sPending & sEidelivery;

    Sequential(clk, [
      If(
        reset,
        then: [
          mEidelivery < Const(0),
          mEithreshold < Const(0, width: 11),
          sEidelivery < Const(0),
          sEithreshold < Const(0, width: 11),
          for (final r in mEip) r < Const(0, width: 64),
          for (final r in mEie) r < Const(0, width: 64),
          for (final r in sEip) r < Const(0, width: 64),
          for (final r in sEie) r < Const(0, width: 64),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          bus.ack < Const(0),

          // MSI delivery: write to seteipnum sets EIP bit
          If(
            bus.stb & bus.we & ~bus.ack,
            then: [
              bus.ack < Const(1),
              // Address determines which interrupt file
              // Data is the interrupt identity number
              // Sets the corresponding bit in EIP
            ],
          ),

          // CSR access for eidelivery/eithreshold/eip/eie
          If(
            input('csr_write'),
            then: [
              // Decode csr_select to determine which register
              // Write to appropriate EIP/EIE/delivery/threshold
            ],
          ),
        ],
      ),
    ]);

    output('csr_rdata') <= Const(0, width: 64);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['riscv,imsics'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      'riscv,num-ids': numIds,
      if (numGuests > 0) 'riscv,num-guest-ids': numIds,
      '#interrupt-cells': 0,
      'interrupt-controller': true,
      'msi-controller': true,
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['riscv,imsics'],
      'riscv,num-ids': numIds,
      if (numGuests > 0) 'riscv,num-guest-ids': numIds,
      '#interrupt-cells': 0,
      'interrupt-controller': true,
      'msi-controller': true,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'IMSIC',
    groupName: 'IMSIC',
    description: 'RISC-V Incoming MSI Controller',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
