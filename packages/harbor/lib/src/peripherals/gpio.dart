import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';

/// General-Purpose I/O (GPIO) peripheral.
///
/// Provides configurable input/output pins with direction control,
/// output value, and input readback registers.
///
/// Register map (each register in its own 64-bit-aligned slot, so a 32-bit
/// access lands in the low word on both a 32-bit and a 64-bit fabric, and the
/// byte-address decode needs no high/low-half selection):
/// - 0x00: INPUT   (read-only, current pin values)
/// - 0x08: OUTPUT  (read/write, output values)
/// - 0x10: DIR     (read/write, 1=output, 0=input)
/// - 0x18: IRQ_EN  (read/write, interrupt enable per pin)
/// - 0x20: IRQ_STATUS (read/write-1-to-clear, interrupt status)
/// - 0x28: IRQ_EDGE (read/write, 0=level, 1=edge triggered)
class HarborGpio extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// Number of GPIO pins.
  final int pinCount;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Wishbone slave address width. Defaults to 12 (the 0x1000 window).
  final int busAddressWidth;

  /// Wishbone slave data width. Must match the SoC fabric (e.g. 64 on an RV64
  /// SoC). The register file itself is 32-bit; wider buses zero-extend reads.
  final int busDataWidth;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// GPIO pin I/O (directly exposed for board connection).
  Logic get gpioIn => input('gpio_in');
  Logic get gpioOut => output('gpio_out');
  Logic get gpioDir => output('gpio_dir');

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  HarborGpio({
    required this.baseAddress,
    this.pinCount = 32,
    this.busAddressWidth = 12,
    this.busDataWidth = 32,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborGpio', name: name ?? 'gpio') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    createPort('gpio_in', PortDirection.input, width: pinCount);
    addOutput('gpio_out', width: pinCount);
    addOutput('gpio_dir', width: pinCount);
    addOutput('interrupt');

    // Bus read-data width. The register file is 32-bit; a wider fabric sees the
    // registers zero-extended into the low word.
    final dw = busDataWidth;

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: busAddressWidth,
      dataWidth: dw,
    );

    final clk = input('clk');
    final reset = input('reset');

    final outputReg = Logic(name: 'output_reg', width: pinCount);
    final dirReg = Logic(name: 'dir_reg', width: pinCount);
    final irqEn = Logic(name: 'irq_en', width: pinCount);
    final irqStatus = Logic(name: 'irq_status', width: pinCount);
    final irqEdge = Logic(name: 'irq_edge', width: pinCount);
    final prevInput = Logic(name: 'prev_input', width: pinCount);

    gpioOut <= outputReg;
    gpioDir <= dirReg;

    // Interrupt: OR of all enabled, active interrupts
    interrupt <= (irqStatus & irqEn).or();

    // Pins raising a status bit this cycle: a rising edge on an edge-triggered
    // pin, or a high level on a level-triggered one. This is ONE vector, not a
    // per-pin conditional: `pinCount` separate `If`s all assigning irqStatus
    // race under last-write-wins, so only the highest-numbered firing pin was
    // ever recorded and every lower pin's interrupt was lost.
    final irqSet = ((irqEdge & gpioIn & ~prevInput) | (~irqEdge & gpioIn))
        .named('irq_set');

    Sequential(clk, [
      If(
        reset,
        then: [
          outputReg < Const(0, width: pinCount),
          dirReg < Const(0, width: pinCount),
          irqEn < Const(0, width: pinCount),
          irqStatus < Const(0, width: pinCount),
          irqEdge < Const(0, width: pinCount),
          prevInput < Const(0, width: pinCount),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: dw),
        ],
        orElse: [
          prevInput < gpioIn,
          irqStatus < (irqStatus | irqSet),

          bus.ack < Const(0),
          bus.dataOut < Const(0, width: dw),

          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              // Registers sit 8 bytes apart (see the map above). Decode every
              // address bit of the 0x1000 window and ignore the bits above it,
              // so absolute and relative addresses both work. An unused offset
              // reads 0 and ignores writes.
              Case(bus.windowAddr(0x1000), [
                // 0x00: INPUT
                CaseItem(Const(0x00, width: 12), [
                  bus.dataOut < gpioIn.zeroExtend(dw),
                ]),
                // 0x08: OUTPUT
                CaseItem(Const(0x08, width: 12), [
                  If(
                    bus.we,
                    then: [outputReg < bus.selMerge(outputReg, 0x08)],
                    orElse: [bus.dataOut < outputReg.zeroExtend(dw)],
                  ),
                ]),
                // 0x10: DIR
                CaseItem(Const(0x10, width: 12), [
                  If(
                    bus.we,
                    then: [dirReg < bus.selMerge(dirReg, 0x10)],
                    orElse: [bus.dataOut < dirReg.zeroExtend(dw)],
                  ),
                ]),
                // 0x18: IRQ_EN
                CaseItem(Const(0x18, width: 12), [
                  If(
                    bus.we,
                    then: [irqEn < bus.selMerge(irqEn, 0x18)],
                    orElse: [bus.dataOut < irqEn.zeroExtend(dw)],
                  ),
                ]),
                // 0x20: IRQ_STATUS (write-1-to-clear)
                CaseItem(Const(0x20, width: 12), [
                  If(
                    bus.we,
                    then: [
                      // Fold this cycle's sets back in, so a pin that raises
                      // its status in the same cycle as the clear is not
                      // lost. A byte SEL does not select stays clear of the
                      // clear mask, so it is not cleared either.
                      irqStatus <
                          ((irqStatus | irqSet) &
                              ~bus.selMasked(0x20, pinCount)),
                    ],
                    orElse: [bus.dataOut < irqStatus.zeroExtend(dw)],
                  ),
                ]),
                // 0x28: IRQ_EDGE
                CaseItem(Const(0x28, width: 12), [
                  If(
                    bus.we,
                    then: [irqEdge < bus.selMerge(irqEdge, 0x28)],
                    orElse: [bus.dataOut < irqEdge.zeroExtend(dw)],
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
    compatible: ['harbor,gpio', 'sifive,gpio0'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {'ngpios': pinCount, '#gpio-cells': 2, 'gpio-controller': true},
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,gpio', 'sifive,gpio0'],
      'ngpios': pinCount,
      '#gpio-cells': 2,
      'gpio-controller': true,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'GPIO',
    groupName: 'GPIO',
    description: 'General-purpose I/O controller',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
