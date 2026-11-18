import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../arith/fpu_config.dart' show harborStableDefinitionName;
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
/// - 0x10: HOLD_TIME  (reset hold cycles, default 256, least [minHoldCycles])
/// - 0x18: DOMAIN_RST (per-domain reset control, 1 bit per domain)
/// - 0x20: DOMAIN_STATUS (per-domain reset status, read-only)
/// - 0x28: WDOG_RST_EN (enable watchdog as reset source)
/// - 0x30: SW_RST_KEY  (write 0xDEAD to trigger software reset)
///
/// The node is a `syscon` with a `syscon-reboot` child that writes 0xDEAD at
/// offset 0x30, so the Linux restart handler triggers the software reset.
/// `HarborSoC.addResetController` ORs [systemReset] into the SoC reset.
class HarborResetController extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider,
        HarborNarrowSlaveOk {
  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Number of independently resettable domains.
  final int domainCount;

  /// Most that [minHoldCycles] takes: the default hold time.
  static const maxMinHoldCycles = 256;

  /// Least reset hold time in controller clock cycles. A write to HOLD_TIME
  /// below it sets this value. Pick it so the slowest domain sees a few
  /// clock edges of reset.
  final int minHoldCycles;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// Per-domain reset outputs.
  Logic get domainResets => output('domain_resets');

  /// Global system reset output.
  Logic get systemReset => output('system_reset');

  /// Byte offset of the SW_RST_KEY register.
  static const swResetKeyOffset = 0x30;

  /// Value that SW_RST_KEY takes to trigger the software reset.
  static const swResetKey = 0xDEAD;

  /// Reset cause output (encoded as [HarborResetSource] index).
  Logic get resetCause => output('reset_cause');

  HarborResetController({
    required this.baseAddress,
    this.domainCount = 4,
    this.minHoldCycles = 16,
    HarborFabricKind fabricKind = HarborFabricKind.wishbone,
    bool crossFabricClock = false,
    String? name,
  }) : super(
         harborStableDefinitionName('HarborResetController', [
           ...BusSlavePort.definitionNameParts(
             kind: fabricKind,
             addressWidth: 12,
             dataWidth: 32,
             cross: crossFabricClock,
           ),
           'd$domainCount',
           'h$minHoldCycles',
         ]),
         name: name ?? 'reset_ctrl',
       ) {
    if (minHoldCycles < 1 || minHoldCycles > maxMinHoldCycles) {
      throw ArgumentError.value(
        minHoldCycles,
        'minHoldCycles',
        'must be 1 to 256, the default hold time',
      );
    }
    createPort('clk', PortDirection.input);
    createPort('por', PortDirection.input); // power-on reset
    createPort('ext_reset', PortDirection.input); // external reset pin
    createPort('wdog_reset', PortDirection.input); // from watchdog
    createPort('debug_reset', PortDirection.input); // from debug module

    addOutput('system_reset');
    addOutput('domain_resets', width: domainCount);
    addOutput('reset_cause', width: 3);

    // The bus port also resets while the controller holds the system reset.
    // The fabric resets then too, so a response that waits in the port
    // would reach it after the reset.
    final resetActive = Logic(name: 'reset_active');
    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      kind: fabricKind,
      addressWidth: 12,
      dataWidth: 32,
      clk: input('clk'),
      reset: crossFabricClock
          ? input('por')
          : (input('por') | resetActive).named('bus_reset'),
      fabricClock: BusSlavePort.fabricClockInputs(
        this,
        cross: crossFabricClock,
      ),
    );

    final clk = input('clk');
    // This device's own reset is the power-on reset, not a plain 'reset'
    // port. [bus.reset] is that same signal, joined with the fabric reset
    // when the port crosses clocks.
    final por = crossFabricClock ? bus.reset : input('por');

    final holdTime = Logic(name: 'hold_time', width: 16);
    final holdCounter = Logic(name: 'hold_counter', width: 16);
    final cause = Logic(name: 'cause', width: 3);
    final domainRstReg = Logic(name: 'domain_rst_reg', width: domainCount);
    final wdogEn = Logic(name: 'wdog_en');
    final swResetPending = Logic(name: 'sw_reset_pending');

    systemReset <= resetActive | por;
    domainResets <=
        domainRstReg |
            [for (var i = 0; i < domainCount; i++) resetActive].concat();
    resetCause <= cause;

    Sequential(clk, [
      If(
        por,
        then: [
          holdTime < Const(256, width: 16),
          holdCounter < Const(0, width: 16),
          resetActive < Const(1),
          // The reset pin held in reset is an external reset.
          If(
            input('ext_reset'),
            then: [cause < Const(HarborResetSource.external_.index, width: 3)],
            orElse: [cause < Const(HarborResetSource.por.index, width: 3)],
          ),
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

              // Decode every address bit of the 0x1000 window and ignore the
              // bits above it, so absolute and relative addresses both work. An
              // unused offset reads 0 and ignores writes.
              Case(bus.windowAddr(0x1000), [
                CaseItem(Const(0x00, width: 12), [
                  If(
                    bus.we & bus.selAny(0x00, 1),
                    then: [
                      If(bus.dataIn[0], then: [swResetPending < Const(1)]),
                      If(bus.dataIn[4], then: [cause < Const(0, width: 3)]),
                    ],
                    orElse: [bus.dataOut < Const(0, width: 32)],
                  ),
                ]),
                CaseItem(Const(0x08, width: 12), [
                  bus.dataOut <
                      [
                        Const(0, width: 23),
                        resetActive,
                        cause,
                      ].concat().zeroExtend(32),
                ]),
                CaseItem(Const(0x10, width: 12), [
                  If(
                    bus.we,
                    then: [
                      // A hold under the minimum would leave a slower
                      // domain with too few clock edges to reset.
                      holdTime <
                          mux(
                            bus
                                .selMerge(holdTime, 0x10)
                                .lt(Const(minHoldCycles, width: 16)),
                            Const(minHoldCycles, width: 16),
                            bus.selMerge(holdTime, 0x10),
                          ),
                    ],
                    orElse: [bus.dataOut < holdTime.zeroExtend(32)],
                  ),
                ]),
                CaseItem(Const(0x18, width: 12), [
                  If(
                    bus.we,
                    then: [domainRstReg < bus.selMerge(domainRstReg, 0x18)],
                    orElse: [bus.dataOut < domainRstReg.zeroExtend(32)],
                  ),
                ]),
                CaseItem(Const(0x28, width: 12), [
                  If(
                    bus.we,
                    then: [wdogEn < bus.selMerge(wdogEn, 0x28)],
                    orElse: [bus.dataOut < wdogEn.zeroExtend(32)],
                  ),
                ]),
                CaseItem(Const(swResetKeyOffset, width: 12), [
                  If(
                    bus.we & bus.selAny(swResetKeyOffset, 2),
                    then: [
                      If(
                        bus.dataIn
                            .getRange(0, 16)
                            .eq(Const(swResetKey, width: 16)),
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
    compatible: ['harbor,reset-controller', 'syscon', 'simple-mfd'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      '#reset-cells': 1,
      'num-domains': domainCount,
      'reg-io-width': 4,
    },
    children: [
      HarborDeviceTreeChild(
        name: 'reboot',
        properties: {
          'compatible': 'syscon-reboot',
          'offset': [swResetKeyOffset],
          'value': [swResetKey],
          // Under the SBI restart handler at 192, so a reboot goes through SBI
          // first and this register runs only if the SBI call returns.
          'priority': 128,
        },
      ),
    ],
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
