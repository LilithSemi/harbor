import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';

/// HarborWatchdog timer peripheral.
///
/// If not kicked within the timeout period, asserts a system reset
/// or interrupt. Supports windowed mode where kicking too early
/// is also a fault.
///
/// Register map (each register in its own 64-bit-aligned slot, so a 32-bit
/// access lands in the low word on both a 32-bit and a 64-bit fabric, and the
/// byte-address decode needs no high/low-half selection):
/// - 0x00: CTRL    (enable, reset_en, irq_en, window_en)
/// - 0x08: STATUS  (running, expired)
/// - 0x10: TIMEOUT (timeout value in clock cycles)
/// - 0x18: WINDOW  (minimum kick interval, windowed mode)
/// - 0x20: KICK    (write magic value 0x4B494B to kick)
/// - 0x28: COUNT   (current counter value, read-only)
///
/// Magic kick value prevents accidental kicks from stray writes.
class HarborWatchdog extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Counter width in bits.
  final int counterWidth;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// Reset output (directly exposed, directly active).
  Logic get resetOut => output('wdt_reset');

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  /// Magic value to write to KICK register.
  static const kickMagic = 0x4B494B; // "KIK"

  HarborWatchdog({
    required this.baseAddress,
    this.counterWidth = 32,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborWatchdog', name: name ?? 'watchdog') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    addOutput('wdt_reset');
    addOutput('interrupt');

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: 12,
      dataWidth: 32,
    );

    final clk = input('clk');
    final reset = input('reset');

    final enable = Logic(name: 'enable');
    final resetEn = Logic(name: 'reset_en');
    final irqEn = Logic(name: 'irq_en');
    final windowEn = Logic(name: 'window_en');
    final timeout = Logic(name: 'timeout', width: counterWidth);
    final window = Logic(name: 'window', width: counterWidth);
    final count = Logic(name: 'count', width: counterWidth);
    final expired = Logic(name: 'expired');
    final kicked = Logic(name: 'kicked');

    // Outputs
    output('wdt_reset') <= expired & resetEn;
    interrupt <= expired & irqEn;

    Sequential(clk, [
      If(
        reset,
        then: [
          enable < Const(0),
          resetEn < Const(1),
          irqEn < Const(0),
          windowEn < Const(0),
          timeout < Const(0xFFFF, width: counterWidth),
          window < Const(0, width: counterWidth),
          count < Const(0, width: counterWidth),
          expired < Const(0),
          kicked < Const(0),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          kicked < Const(0),

          // Counter
          If(
            enable & ~expired,
            then: [
              count < (count + Const(1, width: counterWidth)),
              If(count.gte(timeout), then: [expired < Const(1)]),
            ],
          ),

          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              // Decode every address bit of the 0x1000 window and ignore the
              // bits above it, so absolute and relative addresses both work. An
              // unused offset reads 0 and ignores writes.
              Case(bus.windowAddr(0x1000), [
                // 0x00: CTRL
                CaseItem(Const(0x00, width: 12), [
                  If(
                    bus.we & bus.selAny(0x00, 1),
                    then: [
                      enable < bus.dataIn[0],
                      resetEn < bus.dataIn[1],
                      irqEn < bus.dataIn[2],
                      windowEn < bus.dataIn[3],
                    ],
                    orElse: [
                      bus.dataOut <
                          enable.zeroExtend(32) |
                              (resetEn.zeroExtend(32) << Const(1, width: 32)) |
                              (irqEn.zeroExtend(32) << Const(2, width: 32)) |
                              (windowEn.zeroExtend(32) << Const(3, width: 32)),
                    ],
                  ),
                ]),
                // 0x08: STATUS
                CaseItem(Const(0x08, width: 12), [
                  bus.dataOut <
                      enable.zeroExtend(32) |
                          (expired.zeroExtend(32) << Const(1, width: 32)),
                ]),
                // 0x10: TIMEOUT
                CaseItem(Const(0x10, width: 12), [
                  If(
                    bus.we,
                    then: [timeout < bus.selMerge(timeout, 0x10)],
                    orElse: [bus.dataOut < timeout.zeroExtend(32)],
                  ),
                ]),
                // 0x18: WINDOW
                CaseItem(Const(0x18, width: 12), [
                  If(
                    bus.we,
                    then: [window < bus.selMerge(window, 0x18)],
                    orElse: [bus.dataOut < window.zeroExtend(32)],
                  ),
                ]),
                // 0x20: KICK (write magic to reset counter)
                CaseItem(Const(0x20, width: 12), [
                  If(
                    bus.we & bus.selAny(0x20, 3),
                    then: [
                      If(
                        bus.dataIn
                            .getRange(0, 24)
                            .eq(Const(kickMagic, width: 24)),
                        then: [
                          // Window check: fault if kicked too early
                          If(
                            windowEn & count.lt(window),
                            then: [
                              expired < Const(1), // early kick = fault
                            ],
                            orElse: [
                              count < Const(0, width: counterWidth),
                              expired < Const(0),
                              kicked < Const(1),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ]),
                // 0x28: COUNT (read-only)
                CaseItem(Const(0x28, width: 12), [
                  bus.dataOut < count.zeroExtend(32),
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
    compatible: ['harbor,watchdog'],
    reg: BusAddressRange(baseAddress, 0x1000),
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,watchdog'],
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'WDT',
    groupName: 'WDT',
    description: 'Watchdog timer',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
