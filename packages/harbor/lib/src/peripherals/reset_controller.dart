import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';

/// Reset source that can trigger a system reset.
enum HarborResetSource {
  /// Power-on reset.
  por,

  /// External reset pin.
  external_,

  /// Watchdog timer expiry.
  watchdog,

  /// Debug module halt-on-reset.
  debug,

  /// Software-initiated reset.
  software,
}

/// System reset controller.
///
/// Manages reset domains with configurable hold times, reset
/// sequencing, and reset cause tracking. Supports per-domain
/// reset control for isolating subsystems.
///
/// Register map (each register in its own 64-bit-aligned slot, so a 32-bit
/// access lands in the low word on both a 32-bit and a 64-bit fabric, and the
/// byte-address decode needs no high/low-half selection):
/// - 0x00: CTRL       (bit 0: global reset, bit 4: reset cause clear)
/// - 0x08: STATUS     (bits 4:0: reset cause, bit 8: reset active)
/// - 0x10: HOLD_TIME  (reset hold cycles, default 256)
/// - 0x18: DOMAIN_RST (per-domain reset control, 1 bit per domain)
/// - 0x20: DOMAIN_STATUS (per-domain reset status, read-only)
/// - 0x28: WDOG_RST_EN (enable watchdog as reset source)
/// - 0x30: SW_RST_KEY  (write 0xDEAD to trigger software reset)
class HarborResetController extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Number of independently resettable domains.
  final int domainCount;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// Per-domain reset outputs.
  Logic get domainResets => output('domain_resets');

  /// Global system reset output.
  Logic get systemReset => output('system_reset');

  /// Reset cause output (encoded as [HarborResetSource] index).
  Logic get resetCause => output('reset_cause');

  HarborResetController({
    required this.baseAddress,
    this.domainCount = 4,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborResetController', name: name ?? 'reset_ctrl') {
    createPort('clk', PortDirection.input);
    createPort('por', PortDirection.input); // power-on reset
    createPort('ext_reset', PortDirection.input); // external reset pin
    createPort('wdog_reset', PortDirection.input); // from watchdog
    createPort('debug_reset', PortDirection.input); // from debug module

    addOutput('system_reset');
    addOutput('domain_resets', width: domainCount);
    addOutput('reset_cause', width: 3);

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      addressWidth: 8,
      dataWidth: 32,
      clk: input('clk'),
      reset: input('por'),
    );

    final clk = input('clk');
    final por = input('por');

    final holdTime = Logic(name: 'hold_time', width: 16);
    final holdCounter = Logic(name: 'hold_counter', width: 16);
    final resetActive = Logic(name: 'reset_active');
    final cause = Logic(name: 'cause', width: 3);
    final domainRstReg = Logic(name: 'domain_rst_reg', width: domainCount);
    final wdogEn = Logic(name: 'wdog_en');
    final swResetPending = Logic(name: 'sw_reset_pending');

    systemReset <= resetActive | por;
    domainResets <=
        domainRstReg |
            [for (var i = 0; i < domainCount; i++) resetActive].swizzle();
    resetCause <= cause;

    Sequential(clk, [
      If(
        por,
        then: [
          holdTime < Const(256, width: 16),
          holdCounter < Const(0, width: 16),
          resetActive < Const(1),
          cause < Const(HarborResetSource.por.index, width: 3),
          domainRstReg < Const(0, width: domainCount),
          wdogEn < Const(0),
          swResetPending < Const(0),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          // Reset hold timer
          If(
            resetActive,
            then: [
              If(
                holdCounter.lt(holdTime),
                then: [holdCounter < holdCounter + 1],
                orElse: [
                  resetActive < Const(0),
                  holdCounter < Const(0, width: 16),
                ],
              ),
            ],
          ),

          // Reset sources
          If(
            input('wdog_reset') & wdogEn & ~resetActive,
            then: [
              resetActive < Const(1),
              cause < Const(HarborResetSource.watchdog.index, width: 3),
            ],
          ),
          If(
            input('debug_reset') & ~resetActive,
            then: [
              resetActive < Const(1),
              cause < Const(HarborResetSource.debug.index, width: 3),
            ],
          ),
          If(
            input('ext_reset') & ~resetActive,
            then: [
              resetActive < Const(1),
              cause < Const(HarborResetSource.external_.index, width: 3),
            ],
          ),
          If(
            swResetPending & ~resetActive,
            then: [
              resetActive < Const(1),
              cause < Const(HarborResetSource.software.index, width: 3),
              swResetPending < Const(0),
            ],
          ),

          // Bus registers
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              // Match the full address, not just enough low bits for the
              // registers defined today, so an address outside the map
              // reads 0 and ignores writes instead of aliasing a register.
              Case(bus.addr, [
                CaseItem(Const(0x00, width: 8), [
                  If(
                    bus.we & bus.selAny(0x00, 1),
                    then: [
                      If(bus.dataIn[0], then: [swResetPending < Const(1)]),
                      If(bus.dataIn[4], then: [cause < Const(0, width: 3)]),
                    ],
                    orElse: [bus.dataOut < Const(0, width: 32)],
                  ),
                ]),
                CaseItem(Const(0x08, width: 8), [
                  bus.dataOut <
                      [
                        Const(0, width: 23),
                        resetActive,
                        cause,
                      ].swizzle().zeroExtend(32),
                ]),
                CaseItem(Const(0x10, width: 8), [
                  If(
                    bus.we,
                    then: [holdTime < bus.selMerge(holdTime, 0x10)],
                    orElse: [bus.dataOut < holdTime.zeroExtend(32)],
                  ),
                ]),
                CaseItem(Const(0x18, width: 8), [
                  If(
                    bus.we,
                    then: [domainRstReg < bus.selMerge(domainRstReg, 0x18)],
                    orElse: [bus.dataOut < domainRstReg.zeroExtend(32)],
                  ),
                ]),
                CaseItem(Const(0x28, width: 8), [
                  If(
                    bus.we,
                    then: [wdogEn < bus.selMerge(wdogEn, 0x28)],
                    orElse: [bus.dataOut < wdogEn.zeroExtend(32)],
                  ),
                ]),
                CaseItem(Const(0x30, width: 8), [
                  If(
                    bus.we & bus.selAny(0x30, 2),
                    then: [
                      If(
                        bus.dataIn.getRange(0, 16).eq(Const(0xDEAD, width: 16)),
                        then: [swResetPending < Const(1)],
                      ),
                    ],
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
    compatible: ['harbor,reset-controller'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {'#reset-cells': 1, 'num-domains': domainCount},
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,reset-controller'],
      '#reset-cells': 1,
      'num-domains': domainCount,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'RESET',
    groupName: 'RESET',
    description: 'System reset controller',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
