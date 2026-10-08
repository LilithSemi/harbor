import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';

/// PWM/Timer peripheral.
///
/// Provides configurable timer/counter channels with PWM output
/// capability. Each channel can operate as a free-running timer,
/// one-shot timer, or PWM generator.
///
/// Each register sits in its own 64-bit-aligned slot, so a 32-bit access lands
/// in the low word on both a 32-bit and a 64-bit fabric, and the byte-address
/// decode needs no high/low-half selection.
///
/// Per-channel register map (0x20 + ch*0x20):
/// - +0x00: CTRL    (enable, mode, irq_en, prescaler)
/// - +0x08: COUNT   (current counter value)
/// - +0x10: COMPARE (compare/period value)
/// - +0x18: DUTY    (PWM duty cycle value)
///
/// Global registers:
/// - 0x00: GLOBAL_CTRL (global enable)
/// - 0x08: INT_STATUS  (per-channel interrupt status, W1C)
class HarborPwmTimer extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// Number of timer/PWM channels.
  final int channels;

  /// Counter width in bits.
  final int counterWidth;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  /// PWM outputs (directly exposed for board connection).
  late final List<Logic> pwmOut;

  HarborPwmTimer({
    required this.baseAddress,
    this.channels = 4,
    this.counterWidth = 32,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborPwmTimer', name: name ?? 'pwm_timer') {
    // Channel ch decodes at 0x20 + ch*0x20 inside the 4 KiB register window, so
    // channel 127 would wrap past the window and alias the global block.
    if (channels > 127) {
      throw ArgumentError(
        'HarborPwmTimer: at most 127 channels fit the 4 KiB register window '
        '(got $channels).',
      );
    }
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    addOutput('interrupt');

    pwmOut = List.generate(channels, (i) => addOutput('pwm_$i'));

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

    // Per-channel state
    final chEnable = List.generate(channels, (i) => Logic(name: 'ch${i}_en'));
    final chMode = List.generate(
      channels,
      (i) => Logic(name: 'ch${i}_mode', width: 2),
    );
    final chIrqEn = List.generate(
      channels,
      (i) => Logic(name: 'ch${i}_irq_en'),
    );
    final chPrescale = List.generate(
      channels,
      (i) => Logic(name: 'ch${i}_prescale', width: 8),
    );
    final chCount = List.generate(
      channels,
      (i) => Logic(name: 'ch${i}_count', width: counterWidth),
    );
    final chCompare = List.generate(
      channels,
      (i) => Logic(name: 'ch${i}_compare', width: counterWidth),
    );
    final chDuty = List.generate(
      channels,
      (i) => Logic(name: 'ch${i}_duty', width: counterWidth),
    );
    final chPrescaleCount = List.generate(
      channels,
      (i) => Logic(name: 'ch${i}_psc', width: 8),
    );

    final globalEnable = Logic(name: 'global_enable');
    final intStatus = Logic(name: 'int_status', width: channels);

    interrupt <=
        (intStatus &
                [for (var i = channels - 1; i >= 0; i--) chIrqEn[i]].swizzle())
            .or();

    // PWM outputs: high when count < duty
    for (var i = 0; i < channels; i++) {
      pwmOut[i] <= chEnable[i] & chCount[i].lt(chDuty[i]);
    }

    Sequential(clk, [
      If(
        reset,
        then: [
          globalEnable < Const(0),
          intStatus < Const(0, width: channels),
          for (var i = 0; i < channels; i++) ...[
            chEnable[i] < Const(0),
            chMode[i] < Const(0, width: 2),
            chIrqEn[i] < Const(0),
            chPrescale[i] < Const(0, width: 8),
            chCount[i] < Const(0, width: counterWidth),
            chCompare[i] < Const(0, width: counterWidth),
            chDuty[i] < Const(0, width: counterWidth),
            chPrescaleCount[i] < Const(0, width: 8),
          ],
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          // Timer engine per channel
          for (var i = 0; i < channels; i++)
            If(
              chEnable[i] & globalEnable,
              then: [
                If(
                  chPrescaleCount[i].eq(Const(0, width: 8)),
                  then: [
                    chPrescaleCount[i] < chPrescale[i],
                    chCount[i] < (chCount[i] + Const(1, width: counterWidth)),
                    // Compare match
                    If(
                      chCount[i].eq(chCompare[i]),
                      then: [
                        intStatus <
                            (intStatus | Const(1 << i, width: channels)),
                        // Mode 0: free-running (wrap), Mode 1: one-shot (stop), Mode 2: auto-reload
                        If(
                          chMode[i].eq(Const(1, width: 2)),
                          then: [chEnable[i] < Const(0)],
                        ),
                        If(
                          chMode[i].eq(Const(2, width: 2)),
                          then: [chCount[i] < Const(0, width: counterWidth)],
                        ),
                      ],
                    ),
                  ],
                  orElse: [
                    chPrescaleCount[i] <
                        (chPrescaleCount[i] - Const(1, width: 8)),
                  ],
                ),
              ],
            ),

          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              // Global registers (the first 0x20 bytes only: without this
              // guard a channel access at 0x20 + n decoded as a global one too,
              // because the low bits match).
              If(
                bus.addr.getRange(5, 12).eq(Const(0, width: 7)),
                then: [
                  Case(bus.addr.getRange(0, 5), [
                    CaseItem(Const(0x00, width: 5), [
                      If(
                        bus.we & bus.selAny(0x00, 1),
                        then: [globalEnable < bus.dataIn[0]],
                        orElse: [bus.dataOut < globalEnable.zeroExtend(32)],
                      ),
                    ]),
                    CaseItem(Const(0x08, width: 5), [
                      If(
                        bus.we,
                        then: [
                          intStatus <
                              (intStatus & ~bus.selMasked(0x08, channels)),
                        ],
                        orElse: [bus.dataOut < intStatus.zeroExtend(32)],
                      ),
                    ]),
                  ]),
                ],
              ),

              // Per-channel registers (0x20 + ch*0x20). The stride is 0x20, not
              // 0x10: four 8-byte slots no longer fit in 16 bytes, and a 0x10
              // stride put DUTY on the next channel's CTRL.
              for (var ch = 0; ch < channels; ch++)
                If(
                  bus.addr.getRange(5, 12).eq(Const(1 + ch, width: 7)),
                  then: [
                    Case(bus.addr.getRange(0, 5), [
                      CaseItem(Const(0x00, width: 5), [
                        If(
                          bus.we,
                          then: [
                            If(
                              bus.selAny(0x00, 1),
                              then: [
                                chEnable[ch] < bus.dataIn[0],
                                chMode[ch] < bus.dataIn.getRange(2, 4),
                                chIrqEn[ch] < bus.dataIn[4],
                              ],
                            ),
                            If(
                              bus.selAny(0x01, 1),
                              then: [
                                chPrescale[ch] < bus.dataIn.getRange(8, 16),
                              ],
                            ),
                          ],
                          orElse: [
                            bus.dataOut <
                                chEnable[ch].zeroExtend(32) |
                                    (chMode[ch].zeroExtend(32) <<
                                        Const(2, width: 32)) |
                                    (chIrqEn[ch].zeroExtend(32) <<
                                        Const(4, width: 32)) |
                                    (chPrescale[ch].zeroExtend(32) <<
                                        Const(8, width: 32)),
                          ],
                        ),
                      ]),
                      CaseItem(Const(0x08, width: 5), [
                        If(
                          bus.we,
                          then: [chCount[ch] < bus.selMerge(chCount[ch], 0x08)],
                          orElse: [bus.dataOut < chCount[ch].zeroExtend(32)],
                        ),
                      ]),
                      CaseItem(Const(0x10, width: 5), [
                        If(
                          bus.we,
                          then: [
                            chCompare[ch] < bus.selMerge(chCompare[ch], 0x10),
                          ],
                          orElse: [bus.dataOut < chCompare[ch].zeroExtend(32)],
                        ),
                      ]),
                      CaseItem(Const(0x18, width: 5), [
                        If(
                          bus.we,
                          then: [chDuty[ch] < bus.selMerge(chDuty[ch], 0x18)],
                          orElse: [bus.dataOut < chDuty[ch].zeroExtend(32)],
                        ),
                      ]),
                    ]),
                  ],
                ),
            ],
          ),
        ],
      ),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,pwm-timer'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {'#pwm-cells': 3, 'num-channels': channels},
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,pwm-timer'],
      '#pwm-cells': 3,
      'num-channels': channels,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'PWM',
    groupName: 'PWM',
    description: 'PWM and timer peripheral',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
