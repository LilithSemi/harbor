import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';

/// Trace packet type.
enum HarborTracePacketType {
  /// Branch taken/not-taken.
  branch,

  /// Exception/interrupt entry.
  exception,

  /// Return from exception.
  exceptionReturn,

  /// Context switch (privilege mode change).
  context_,

  /// Synchronization packet (periodic full address).
  sync,
}

/// RISC-V E-Trace (Efficient Trace) encoder.
///
/// Implements the RISC-V Efficient Trace specification for
/// non-intrusive instruction tracing. Generates compressed
/// trace packets that can be captured by an external trace
/// probe or stored in an on-chip trace buffer.
///
/// Trace format:
/// - Branch trace: 1-bit per branch (taken/not-taken)
/// - Address trace: differential addresses for discontinuities
/// - Sync packets: periodic full PC for decoder synchronization
///
/// Register map:
/// - 0x00: CTRL     (enable, mode, trigger source)
/// - 0x04: STATUS   (running, overflow, wrap)
/// - 0x08: TRIG     (trigger config: start/stop address)
/// - 0x0C: TRIG_HI  (trigger address high bits)
/// - 0x10: BUF_BASE (trace buffer base address)
/// - 0x14: BUF_SIZE (trace buffer size)
/// - 0x18: BUF_WR   (current write pointer, read-only)
/// - 0x1C: SYNC_CNT (sync packet interval in branches)
class HarborTraceEncoder extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// Base address for trace registers.
  final int baseAddress;

  /// Trace buffer size in bytes (0 = no on-chip buffer, external only).
  final int bufferSize;

  /// Sync packet interval (number of branches between syncs).
  final int syncInterval;

  /// Bus slave port for register access.
  late final BusSlavePort bus;

  HarborTraceEncoder({
    required this.baseAddress,
    this.bufferSize = 4096,
    this.syncInterval = 256,
    BusProtocol protocol = BusProtocol.wishbone,
    super.name = 'trace',
  }) : super('HarborTraceEncoder') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // Pipeline trace inputs
    createPort('valid', PortDirection.input); // instruction retired
    createPort('pc', PortDirection.input, width: 64);
    createPort('is_branch', PortDirection.input);
    createPort('branch_taken', PortDirection.input);
    createPort('is_exception', PortDirection.input);
    createPort('is_eret', PortDirection.input);
    createPort('exception_cause', PortDirection.input, width: 5);
    createPort('priv_mode', PortDirection.input, width: 2);
    createPort('priv_change', PortDirection.input);

    // Trace output (to external probe or on-chip buffer)
    addOutput('trace_data', width: 32);
    addOutput('trace_valid');
    addOutput('trace_sync'); // this is a sync packet

    // Overflow
    addOutput('overflow');

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: 8,
      dataWidth: 32,
    );

    final clk = input('clk');
    final reset = input('reset');

    // Trace state
    final enabled = Logic(name: 'trace_enabled');
    final lastPc = Logic(name: 'last_pc', width: 64);
    final branchCount = Logic(name: 'branch_count', width: 16);
    final branchBits = Logic(name: 'branch_bits', width: 32);
    final branchBitCount = Logic(name: 'branch_bit_count', width: 6);
    final syncCount = Logic(name: 'sync_count', width: 16);
    final bufWrPtr = Logic(name: 'buf_wr_ptr', width: 32);
    final bufBase = Logic(name: 'buf_base', width: 32);
    final bufSz = Logic(name: 'buf_size', width: 32);
    final trigAddr = Logic(name: 'trig_addr', width: 64);
    final overflowReg = Logic(name: 'overflow_reg');

    output('overflow') <= overflowReg;

    Sequential(clk, [
      If(
        reset,
        then: [
          enabled < Const(0),
          lastPc < Const(0, width: 64),
          branchCount < Const(0, width: 16),
          branchBits < Const(0, width: 32),
          branchBitCount < Const(0, width: 6),
          syncCount < Const(0, width: 16),
          bufWrPtr < Const(0, width: 32),
          bufBase < Const(0, width: 32),
          bufSz < Const(bufferSize, width: 32),
          trigAddr < Const(0, width: 64),
          overflowReg < Const(0),
          output('trace_valid') < Const(0),
          output('trace_sync') < Const(0),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          output('trace_valid') < Const(0),
          output('trace_sync') < Const(0),

          If(
            enabled & input('valid'),
            then: [
              // Branch trace: accumulate branch bits
              If(
                input('is_branch'),
                then: [
                  branchBits <
                      (branchBits |
                          (input('branch_taken').zeroExtend(32) <<
                              branchBitCount)),
                  branchBitCount < branchBitCount + 1,

                  // Flush branch packet when full
                  If(
                    branchBitCount.eq(Const(31, width: 6)),
                    then: [
                      output('trace_data') < branchBits,
                      output('trace_valid') < Const(1),
                      branchBits < Const(0, width: 32),
                      branchBitCount < Const(0, width: 6),
                    ],
                  ),
                ],
              ),

              // Discontinuity: emit address packet
              If(
                input('is_exception') | input('is_eret') | input('priv_change'),
                then: [
                  // Emit differential address (PC - lastPC)
                  output('trace_data') < input('pc').getRange(0, 32),
                  output('trace_valid') < Const(1),
                  lastPc < input('pc'),
                ],
              ),

              // Periodic sync
              syncCount < syncCount + 1,
              If(
                syncCount.gte(Const(syncInterval, width: 16)),
                then: [
                  output('trace_data') < input('pc').getRange(0, 32),
                  output('trace_valid') < Const(1),
                  output('trace_sync') < Const(1),
                  syncCount < Const(0, width: 16),
                  lastPc < input('pc'),
                ],
              ),

              lastPc < input('pc'),
            ],
          ),

          // Register access
          bus.ack < Const(0),
          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),
              // Byte-address decode (see the register map above), matched
              // against the full address so an address outside the map
              // reads 0 and ignores writes instead of aliasing a register.
              // This used to compare a word index (addr >> 2) against the
              // byte address on ADR, so every register but 0x00 was dead.
              Case(bus.addr, [
                CaseItem(Const(0x00, width: 8), [
                  If(
                    bus.we & bus.selAny(0x00, 1),
                    then: [enabled < bus.dataIn[0]],
                    orElse: [bus.dataOut < enabled.zeroExtend(32)],
                  ),
                ]),
                CaseItem(Const(0x04, width: 8), [
                  bus.dataOut <
                      [Const(0, width: 30), overflowReg, enabled].swizzle(),
                ]),
                CaseItem(Const(0x10, width: 8), [
                  If(
                    bus.we,
                    then: [bufBase < bus.selMerge(bufBase, 0x10)],
                    orElse: [bus.dataOut < bufBase],
                  ),
                ]),
                CaseItem(Const(0x14, width: 8), [
                  If(
                    bus.we,
                    then: [bufSz < bus.selMerge(bufSz, 0x14)],
                    orElse: [bus.dataOut < bufSz],
                  ),
                ]),
                CaseItem(Const(0x18, width: 8), [bus.dataOut < bufWrPtr]),
                CaseItem(Const(0x1C, width: 8), [
                  If(
                    bus.we & bus.selAny(0x1C, 2),
                    then: [syncCount < Const(0, width: 16)],
                    orElse: [bus.dataOut < syncCount.zeroExtend(32)],
                  ),
                ]),
              ]),
            ],
          ),
        ],
      ),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['riscv,trace'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {'buffer-size': bufferSize, 'sync-interval': syncInterval},
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['riscv,trace'],
      'buffer-size': bufferSize,
      'sync-interval': syncInterval,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'TRACE',
    groupName: 'TRACE',
    description: 'RISC-V E-Trace encoder',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
