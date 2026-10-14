import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../arith/fpu_config.dart' show harborStableDefinitionName;
import '../bus/bus.dart';
import '../bus/bus_master_port.dart';
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

  /// Register slave port: the debug module's own memory-mapped window at
  /// [baseAddress]. The debug memory map is not designed yet, so it acks
  /// every access and reads 0.
  late final BusSlavePort bus;

  /// Register master port the system bus access registers (sbcs,
  /// sbaddress0, sbdata0) drive. Null unless [hasSystemBusAccess].
  late final BusMasterPort? sba;

  HarborDebugModule({
    required this.baseAddress,
    this.numHarts = 1,
    this.progBufSize = 8,
    this.abstractDataCount = 2,
    this.hasSystemBusAccess = true,
    HarborFabricKind fabricKind = HarborFabricKind.wishbone,
    bool crossFabricClock = false,
    String? name,
  }) : super(
         harborStableDefinitionName('HarborDebugModule', [
           ...BusSlavePort.definitionNameParts(
             kind: fabricKind,
             addressWidth: 32,
             dataWidth: 32,
             cross: crossFabricClock,
           ),
           if (hasSystemBusAccess) ...[fabricKind.name, 'sba', 'e'],
           'h$numHarts',
           'pb$progBufSize',
           'ad$abstractDataCount',
         ]),
         name: name ?? 'debug_module',
       ) {
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

    final fabricClock = BusSlavePort.fabricClockInputs(
      this,
      cross: crossFabricClock,
    );

    // Register slave port: the DM's own window. Always built, so this
    // module can be added to a SoC as an ordinary peripheral.
    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      kind: fabricKind,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: 32,
      dataWidth: 32,
      fabricClock: fabricClock,
    );

    // Register master port for system bus access.
    sba = hasSystemBusAccess
        ? BusMasterPort.create(
            module: this,
            name: 'sba',
            kind: fabricKind,
            addressWidth: 32,
            dataWidth: 32,
            clk: input('clk'),
            reset: input('reset'),
            useErr: true,
            fabricClock: fabricClock,
          )
        : null;

    final clk = input('clk');
    final reset = bus.reset;

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

    // System bus access (sbcs/sbaddress0/sbdata0), built only when a master
    // port exists. One access (read or write, 8/16/32-bit) runs at a time
    // on [sba]. These lists feed the DMI read/write cases and the reset and
    // per-cycle bodies of the main register block below.
    final sbResetAssigns = <Conditional>[];
    final sbCompletionAssigns = <Conditional>[];
    final sbReadCases = <CaseItem>[];
    final sbWriteCases = <CaseItem>[];

    if (sba != null) {
      final master = sba!;
      final sbBusy = Logic(name: 'sb_busy');
      final sbBusyError = Logic(name: 'sb_busyerror');
      final sbError = Logic(name: 'sb_error', width: 3);
      final sbReadOnAddr = Logic(name: 'sb_readonaddr');
      final sbReadOnData = Logic(name: 'sb_readondata');
      final sbAutoIncrement = Logic(name: 'sb_autoincrement');
      final sbAccess = Logic(name: 'sb_access', width: 3);
      final sbAddress = Logic(name: 'sb_address', width: 32);
      final sbData = Logic(name: 'sb_data', width: 32);
      final pendingWe = Logic(name: 'sb_pending_we');
      final pendingAddr = Logic(name: 'sb_pending_addr', width: 32);
      final pendingLane = Logic(name: 'sb_pending_lane', width: 2);
      final pendingSize = Logic(name: 'sb_pending_size', width: 2);
      final pendingWdata = Logic(name: 'sb_pending_wdata', width: 32);

      // Byte lane select for a [size] (0=byte, 1=half, 2=word) access at
      // byte offset [lane] (the low 2 bits of the address) within the word.
      Logic selFor(Logic size, Logic lane) {
        final byteSel = Const(1, width: 4) << lane;
        final halfSel = mux(
          lane[1],
          Const(0xc, width: 4),
          Const(0x3, width: 4),
        );
        return mux(
          size.eq(Const(2, width: 2)),
          Const(0xf, width: 4),
          mux(size.eq(Const(1, width: 2)), halfSel, byteSel),
        );
      }

      // Write data with the low byte or halfword of [data] replicated into
      // every lane, so whichever lane [selFor] picks gets the right bytes.
      Logic replicateFor(Logic size, Logic data) {
        final byteVal = data.getRange(0, 8);
        final halfVal = data.getRange(0, 16);
        final byteRep = [byteVal, byteVal, byteVal, byteVal].swizzle();
        final halfRep = [halfVal, halfVal].swizzle();
        return mux(
          size.eq(Const(2, width: 2)),
          data,
          mux(size.eq(Const(1, width: 2)), halfRep, byteRep),
        );
      }

      // Read data from the selected lane of [data], shifted down to the low
      // bits and zero-extended.
      Logic shiftRead(Logic size, Logic lane, Logic data) {
        final bytes = [
          data.getRange(0, 8),
          data.getRange(8, 16),
          data.getRange(16, 24),
          data.getRange(24, 32),
        ];
        final byteSel = mux(
          lane.eq(Const(0, width: 2)),
          bytes[0],
          mux(
            lane.eq(Const(1, width: 2)),
            bytes[1],
            mux(lane.eq(Const(2, width: 2)), bytes[2], bytes[3]),
          ),
        ).zeroExtend(32);
        final halfSel = mux(
          lane[1],
          data.getRange(16, 32),
          data.getRange(0, 16),
        ).zeroExtend(32);
        return mux(
          size.eq(Const(2, width: 2)),
          data,
          mux(size.eq(Const(1, width: 2)), halfSel, byteSel),
        );
      }

      // Bytes a [size] access covers, for autoincrement.
      Logic sizeBytesFor(Logic size) => mux(
        size.eq(Const(2, width: 2)),
        Const(4, width: 32),
        mux(
          size.eq(Const(1, width: 2)),
          Const(2, width: 32),
          Const(1, width: 32),
        ),
      );

      // Starts an access at byte address [addr] (word-aligned down for
      // [pendingAddr]) once sbbusy and sberror are known clear. Sets
      // sberror 4 for an unsupported sbaccess, 3 for a misaligned address,
      // else latches the access and raises sbbusy.
      List<Conditional> maybeStart({
        required Logic we,
        required Logic addr,
        required Logic data,
      }) {
        final lane = addr.getRange(0, 2);
        final wordAddr = [addr.getRange(2), Const(0, width: 2)].swizzle();
        final size2 = sbAccess.getRange(0, 2);
        final sizeValid = sbAccess.lt(Const(3, width: 3));
        final misaligned = mux(
          size2.eq(Const(2, width: 2)),
          lane.neq(Const(0, width: 2)),
          mux(size2.eq(Const(1, width: 2)), lane[0], Const(0)),
        );
        return [
          If(
            ~sbError.or() & ~sbBusyError,
            then: [
              If(
                ~sizeValid,
                then: [sbError < Const(4, width: 3)],
                orElse: [
                  If(
                    misaligned,
                    then: [sbError < Const(3, width: 3)],
                    orElse: [
                      sbBusy < Const(1),
                      pendingWe < we,
                      pendingAddr < wordAddr,
                      pendingLane < lane,
                      pendingSize < size2,
                      pendingWdata < data,
                    ],
                  ),
                ],
              ),
            ],
          ),
        ];
      }

      final sbcsValue = [
        Const(1, width: 3), // sbversion
        Const(0, width: 6), // reserved
        sbBusyError,
        sbBusy,
        sbReadOnAddr,
        sbAccess,
        sbAutoIncrement,
        sbReadOnData,
        sbError,
        Const(32, width: 7), // sbasize
        Const(0), // sbaccess128
        Const(0), // sbaccess64
        Const(1), // sbaccess32
        Const(1), // sbaccess16
        Const(1), // sbaccess8
      ].swizzle();

      sbResetAssigns.addAll([
        sbBusy < Const(0),
        sbBusyError < Const(0),
        sbError < Const(0, width: 3),
        sbReadOnAddr < Const(0),
        sbReadOnData < Const(0),
        sbAutoIncrement < Const(0),
        sbAccess < Const(2, width: 3),
        sbAddress < Const(0, width: 32),
        sbData < Const(0, width: 32),
        pendingWe < Const(0),
        pendingAddr < Const(0, width: 32),
        pendingLane < Const(0, width: 2),
        pendingSize < Const(0, width: 2),
        pendingWdata < Const(0, width: 32),
      ]);

      // An outstanding access ends here, every cycle, independent of DMI.
      sbCompletionAssigns.add(
        If(
          sbBusy & master.ack,
          then: [
            sbBusy < Const(0),
            If(master.err, then: [sbError < Const(2, width: 3)]),
            If(
              ~pendingWe & ~master.err,
              then: [
                sbData < shiftRead(pendingSize, pendingLane, master.dataIn),
              ],
            ),
            If(
              sbAutoIncrement & ~master.err,
              then: [sbAddress < sbAddress + sizeBytesFor(pendingSize)],
            ),
          ],
        ),
      );

      sbReadCases.addAll([
        CaseItem(Const(0x38, width: 7), [output('dmi_data_out') < sbcsValue]),
        CaseItem(Const(0x39, width: 7), [output('dmi_data_out') < sbAddress]),
        CaseItem(Const(0x3C, width: 7), [
          output('dmi_data_out') < sbData,
          If(
            sbBusy,
            then: [sbBusyError < Const(1)],
            orElse: [
              If(
                sbReadOnData,
                then: maybeStart(
                  we: Const(0),
                  addr: sbAddress,
                  data: Const(0, width: 32),
                ),
              ),
            ],
          ),
        ]),
      ]);

      sbWriteCases.addAll([
        // sbbusyerror and sberror are write-1-to-clear. The rest are plain
        // read/write fields.
        CaseItem(Const(0x38, width: 7), [
          sbBusyError < (sbBusyError & ~input('dmi_data_in')[22]),
          sbError < (sbError & ~input('dmi_data_in').getRange(12, 15)),
          sbReadOnAddr < input('dmi_data_in')[20],
          sbAccess < input('dmi_data_in').getRange(17, 20),
          sbAutoIncrement < input('dmi_data_in')[16],
          sbReadOnData < input('dmi_data_in')[15],
        ]),
        CaseItem(Const(0x39, width: 7), [
          If(
            sbBusy,
            then: [sbBusyError < Const(1)],
            orElse: [
              sbAddress < input('dmi_data_in'),
              If(
                sbReadOnAddr,
                then: maybeStart(
                  we: Const(0),
                  addr: input('dmi_data_in'),
                  data: Const(0, width: 32),
                ),
              ),
            ],
          ),
        ]),
        CaseItem(Const(0x3C, width: 7), [
          If(
            sbBusy,
            then: [sbBusyError < Const(1)],
            // With sberror or sbbusyerror set, the write does nothing.
            orElse: [
              If(
                ~sbError.or() & ~sbBusyError,
                then: [
                  sbData < input('dmi_data_in'),
                  ...maybeStart(
                    we: Const(1),
                    addr: sbAddress,
                    data: input('dmi_data_in'),
                  ),
                ],
              ),
            ],
          ),
        ]),
      ]);

      master.addr <= pendingAddr;
      master.we <= pendingWe;
      master.sel <= selFor(pendingSize, pendingLane);
      master.dataOut <= replicateFor(pendingSize, pendingWdata);
      master.stb <= sbBusy;
    }

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
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
          ...sbResetAssigns,
        ],
        orElse: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
          // Debug memory is not designed yet. Every access gets ACK with 0.
          If(bus.stb & ~bus.ack, then: [bus.ack < Const(1)]),
          ...sbCompletionAssigns,
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
                    ...sbReadCases,
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
                    ...sbWriteCases,
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
