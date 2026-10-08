import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';

/// RISC-V Debug Module (DM) per the RISC-V Debug Specification 1.0.
///
/// Provides:
/// - Per-hart halt/resume/single-step control
/// - Abstract command execution (register access, memory access)
/// - Program buffer for arbitrary instruction execution
/// - System bus access for memory inspection
/// - Trigger module interface
///
/// Connects to the Debug Transport Module (DTM) via the DMI interface
/// and to each hart via halt/resume request/acknowledge signals.
///
/// Register map (DMI address space):
/// - 0x04: dmstatus     0x10: dmcontrol    0x11: hartinfo
/// - 0x12: haltsum1     0x16: abstracts    0x17: command
/// - 0x18: abstractauto 0x20-0x2F: progbuf  0x38: sbcs
/// - 0x39: sbaddress0   0x3C: sbdata0
class HarborDebugModule extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// Base address for the debug module's memory-mapped registers.
  final int baseAddress;

  /// Number of harts controlled by this debug module.
  final int numHarts;

  /// Program buffer size in 32-bit words.
  final int progBufSize;

  /// Number of abstract data registers.
  final int abstractDataCount;

  /// Whether to include system bus access.
  final bool hasSystemBusAccess;

  /// Bus slave port for system bus access.
  late final BusSlavePort? sysBus;

  HarborDebugModule({
    required this.baseAddress,
    this.numHarts = 1,
    this.progBufSize = 8,
    this.abstractDataCount = 2,
    this.hasSystemBusAccess = true,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborDebugModule', name: name ?? 'debug_module') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // DMI interface (from DTM)
    createPort('dmi_addr', PortDirection.input, width: 7);
    createPort('dmi_data_in', PortDirection.input, width: 32);
    createPort(
      'dmi_op',
      PortDirection.input,
      width: 2,
    ); // 0=nop, 1=read, 2=write
    createPort('dmi_valid', PortDirection.input);
    addOutput('dmi_data_out', width: 32);
    addOutput('dmi_ready');
    addOutput('dmi_error', width: 2);

    // Per-hart control signals
    for (var i = 0; i < numHarts; i++) {
      addOutput('hart${i}_halt_req');
      addOutput('hart${i}_resume_req');
      createPort('hart${i}_halted', PortDirection.input);
      createPort('hart${i}_running', PortDirection.input);
      createPort('hart${i}_unavail', PortDirection.input);

      // Abstract command interface to hart
      addOutput('hart${i}_reg_read');
      addOutput('hart${i}_reg_write');
      addOutput('hart${i}_reg_addr', width: 16);
      addOutput('hart${i}_reg_wdata', width: 64);
      createPort('hart${i}_reg_rdata', PortDirection.input, width: 64);
      createPort('hart${i}_reg_ready', PortDirection.input);
    }

    // Reset request output
    addOutput('ndmreset'); // non-debug module reset (resets the system)

    // System bus access
    if (hasSystemBusAccess) {
      sysBus = BusSlavePort.create(
        module: this,
        name: 'sysbus',
        protocol: protocol,
        clk: input('clk'),
        reset: input('reset'),
        addressWidth: 32,
        dataWidth: 32,
      );
    } else {
      sysBus = null;
    }

    final clk = input('clk');
    final reset = input('reset');

    // DM registers
    final dmcontrol = Logic(name: 'dmcontrol', width: 32);
    final dmstatus = Logic(name: 'dmstatus', width: 32);
    final abstractcs = Logic(name: 'abstractcs', width: 32);
    final command = Logic(name: 'command', width: 32);
    final hartsel = Logic(name: 'hartsel', width: 20);

    // Program buffer
    final progbuf = <Logic>[
      for (var i = 0; i < progBufSize; i++) Logic(name: 'progbuf$i', width: 32),
    ];

    // Abstract data
    final abstractData = <Logic>[
      for (var i = 0; i < abstractDataCount; i++)
        Logic(name: 'data$i', width: 32),
    ];

    final bus = sysBus;

    Sequential(clk, [
      If(
        reset,
        then: [
          dmcontrol < Const(0, width: 32),
          abstractcs < Const(0, width: 32),
          command < Const(0, width: 32),
          hartsel < Const(0, width: 20),
          output('dmi_ready') < Const(1),
          output('dmi_error') < Const(0, width: 2),
          output('ndmreset') < Const(0),
          for (var i = 0; i < numHarts; i++) ...[
            output('hart${i}_halt_req') < Const(0),
            output('hart${i}_resume_req') < Const(0),
            output('hart${i}_reg_read') < Const(0),
            output('hart${i}_reg_write') < Const(0),
          ],
          for (final p in progbuf) p < Const(0, width: 32),
          for (final d in abstractData) d < Const(0, width: 32),
          if (bus != null) ...[
            bus.ack < Const(0),
            bus.dataOut < Const(0, width: 32),
          ],
        ],
        orElse: [
          if (bus != null) ...[
            bus.ack < Const(0),
            bus.dataOut < Const(0, width: 32),
            // Debug memory is not designed yet. Every access gets ACK with 0.
            If(bus.stb & ~bus.ack, then: [bus.ack < Const(1)]),
          ],
          // DMI register access
          If(
            input('dmi_valid'),
            then: [
              Case(input('dmi_op'), [
                // Read
                CaseItem(Const(1, width: 2), [
                  Case(input('dmi_addr'), [
                    CaseItem(Const(0x04, width: 7), [
                      output('dmi_data_out') < dmstatus,
                    ]),
                    CaseItem(Const(0x10, width: 7), [
                      output('dmi_data_out') < dmcontrol,
                    ]),
                    CaseItem(Const(0x16, width: 7), [
                      output('dmi_data_out') < abstractcs,
                    ]),
                  ]),
                ]),
                // Write
                CaseItem(Const(2, width: 2), [
                  Case(input('dmi_addr'), [
                    CaseItem(Const(0x10, width: 7), [
                      dmcontrol < input('dmi_data_in'),
                      // Extract halt/resume requests and ndmreset
                      output('ndmreset') < input('dmi_data_in')[1],
                    ]),
                    CaseItem(Const(0x17, width: 7), [
                      command < input('dmi_data_in'),
                      // Execute abstract command
                    ]),
                  ]),
                ]),
              ]),
            ],
          ),
        ],
      ),
    ]);

    // Build dmstatus from hart states
    // dmstatus layout (RISC-V Debug Spec 1.0):
    // [31:23] reserved
    // [22] impebreak
    // [21:20] reserved
    // [19] allhavereset  [18] anyhavereset
    // [17] allresumeack  [16] anyresumeack
    // [15] allnonexistent [14] anynonexistent
    // [13] allunavail    [12] anyunavail
    // [11] allrunning    [10] anyrunning
    // [9]  allhalted     [8]  anyhalted
    // [7]  authenticated [6]  authbusy
    // [5]  hasresethaltreq [4] confstrptrvalid
    // [3:0] version = 3 (debug spec 1.0)
    Logic anyHalted = Const(0);
    Logic allHalted = Const(1);
    Logic anyRunning = Const(0);
    Logic allRunning = Const(1);
    Logic anyUnavail = Const(0);
    Logic allUnavail = Const(1);
    for (var i = 0; i < numHarts; i++) {
      anyHalted = anyHalted | input('hart${i}_halted');
      allHalted = allHalted & input('hart${i}_halted');
      anyRunning = anyRunning | input('hart${i}_running');
      allRunning = allRunning & input('hart${i}_running');
      anyUnavail = anyUnavail | input('hart${i}_unavail');
      allUnavail = allUnavail & input('hart${i}_unavail');
    }
    dmstatus <=
        [
          Const(0, width: 10), // [31:22] reserved + impebreak
          Const(0, width: 4), // [21:18] havereset/resumeack
          Const(0, width: 2), // [17:16] nonexistent (both zero)
          Const(0, width: 2), // [15:14] nonexistent (both zero)
          allUnavail, // [13]
          anyUnavail, // [12]
          allRunning, // [11]
          anyRunning, // [10]
          allHalted, // [9]
          anyHalted, // [8]
          Const(1), // [7] authenticated (always)
          Const(0), // [6] authbusy
          Const(1), // [5] hasresethaltreq
          Const(0), // [4] confstrptrvalid
          Const(3, width: 4), // [3:0] version = 3
        ].swizzle();

    // Hart control defaults
    for (var i = 0; i < numHarts; i++) {
      output('hart${i}_reg_addr') <= Const(0, width: 16);
      output('hart${i}_reg_wdata') <= Const(0, width: 64);
    }
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,debug-module', 'riscv,debug-013'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {'num-harts': numHarts, 'progbuf-size': progBufSize},
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,debug-module', 'riscv,debug-013'],
      'num-harts': numHarts,
      'progbuf-size': progBufSize,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'DEBUG',
    groupName: 'DEBUG',
    description: 'RISC-V debug module',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
