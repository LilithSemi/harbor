import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';

/// RISC-V Advanced Platform-Level Interrupt Controller (APLIC).
///
/// Part of the RISC-V Advanced Interrupt Architecture (AIA) spec.
/// Supports direct interrupt delivery mode.
///
/// Register map (RISC-V AIA APLIC spec):
/// - `domaincfg`:     0x0000
/// - `sourcecfg[i]`:  0x0004 + (i-1)*4
/// - `setip`:         0x1C00       (set pending bitmap)
/// - `clrip`:         0x1D00       (clear pending bitmap)
/// - `setie`:         0x1E00       (set enable bitmap)
/// - `clrie`:         0x1F00       (clear enable bitmap)
/// - `target[i]`:     0x3004 + (i-1)*4
/// - IDC per hart:    0x4000 + hart*32
///   - `idelivery` +0x00, `iforce` +0x04, `ithreshold` +0x08, `claimi` +0x1C
class HarborAplic extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  final int sources;
  final int harts;
  final int priorityBits;
  final int baseAddress;

  late final List<Logic> externalInterrupt;
  late final List<Logic> sourceInterrupt;

  /// Bus slave port.
  late final BusSlavePort bus;

  HarborAplic({
    required this.baseAddress,
    this.sources = 32,
    this.harts = 1,
    this.priorityBits = 8,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborAplic', name: name ?? 'aplic') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: 16,
      dataWidth: 32,
    );

    final clk = input('clk');
    final reset = input('reset');
    // Decode only the bits of the 0x8000 window, so absolute and relative
    // addresses both work.
    final addr = bus.windowAddr(0x8000);
    final datIn = bus.dataIn;
    final datOut = bus.dataOut;
    final ack = bus.ack;
    final stb = bus.stb;
    final we = bus.we;

    sourceInterrupt = List.generate(sources, (i) {
      createPort('src_irq_$i', PortDirection.input);
      return input('src_irq_$i');
    });

    externalInterrupt = List.generate(harts, (i) => addOutput('ext_irq_$i'));

    final domaincfg = Logic(name: 'domaincfg', width: 32);
    final sourcecfg = List.generate(
      sources,
      (i) => Logic(name: 'sourcecfg_$i', width: 10),
    );
    final pending = List.generate(sources, (i) => Logic(name: 'pending_$i'));
    final enabled = List.generate(sources, (i) => Logic(name: 'enabled_$i'));
    final target = List.generate(
      sources,
      (i) => Logic(name: 'target_$i', width: 32),
    );

    final idelivery = List.generate(harts, (i) => Logic(name: 'idelivery_$i'));
    final iforce = List.generate(harts, (i) => Logic(name: 'iforce_$i'));
    final ithreshold = List.generate(
      harts,
      (i) => Logic(name: 'ithreshold_$i', width: priorityBits),
    );

    final hartIdWidth = harts.bitLength.clamp(1, 18);

    // Interrupt delivery
    for (var h = 0; h < harts; h++) {
      Logic anyActive = iforce[h];
      for (var src = 0; src < sources; src++) {
        final targetHart = target[src].getRange(0, hartIdWidth);
        final targetPri = target[src].getRange(18, 18 + priorityBits);
        final active =
            pending[src] &
            enabled[src] &
            idelivery[h] &
            targetHart.eq(Const(h, width: hartIdWidth)) &
            targetPri.gt(ithreshold[h]);
        anyActive = anyActive | active;
      }
      externalInterrupt[h] <= anyActive;
    }

    Sequential(clk, [
      If(
        reset,
        then: [
          domaincfg < Const(0, width: 32),
          for (var i = 0; i < sources; i++) ...[
            sourcecfg[i] < Const(0, width: 10),
            pending[i] < Const(0),
            enabled[i] < Const(0),
            target[i] < Const(0, width: 32),
          ],
          for (var h = 0; h < harts; h++) ...[
            idelivery[h] < Const(0),
            iforce[h] < Const(0),
            ithreshold[h] < Const(0, width: priorityBits),
          ],
          ack < Const(0),
          datOut < Const(0, width: 32),
        ],
        orElse: [
          for (var i = 0; i < sources; i++)
            If(sourceInterrupt[i], then: [pending[i] < Const(1)]),

          ack < Const(0),
          datOut < Const(0, width: 32),

          If(
            stb & ~ack,
            then: [
              ack < Const(1),

              // domaincfg
              If(
                addr.eq(Const(0x0000, width: 15)),
                then: [
                  If(
                    we,
                    then: [domaincfg < bus.selMerge(domaincfg, 0x0000)],
                    orElse: [datOut < domaincfg],
                  ),
                ],
              ),

              // sourcecfg
              for (var i = 0; i < sources; i++)
                If(
                  addr.eq(Const(0x0004 + i * 4, width: 15)),
                  then: [
                    If(
                      we,
                      then: [
                        sourcecfg[i] <
                            bus.selMerge(sourcecfg[i], 0x0004 + i * 4),
                      ],
                      orElse: [datOut < sourcecfg[i].zeroExtend(32)],
                    ),
                  ],
                ),

              // setip
              If(
                addr.eq(Const(0x1C00, width: 15)),
                then: [
                  If(
                    we,
                    then: [
                      // A bit whose byte SEL does not select stays as it
                      // was: a byte store only reaches the sources in the
                      // bytes it selects.
                      for (var i = 0; i < sources && i < 32; i++)
                        If(
                          datIn[i] & bus.sel[i ~/ 8],
                          then: [pending[i] < Const(1)],
                        ),
                    ],
                    orElse: [
                      datOut <
                          [
                            for (
                              var i = (sources > 32 ? 31 : sources - 1);
                              i >= 0;
                              i--
                            )
                              pending[i],
                          ].swizzle().zeroExtend(32),
                    ],
                  ),
                ],
              ),

              // clrip
              If(
                addr.eq(Const(0x1D00, width: 15)),
                then: [
                  If(
                    we,
                    then: [
                      for (var i = 0; i < sources && i < 32; i++)
                        If(
                          datIn[i] & bus.sel[i ~/ 8],
                          then: [pending[i] < Const(0)],
                        ),
                    ],
                  ),
                ],
              ),

              // setie
              If(
                addr.eq(Const(0x1E00, width: 15)),
                then: [
                  If(
                    we,
                    then: [
                      for (var i = 0; i < sources && i < 32; i++)
                        If(
                          datIn[i] & bus.sel[i ~/ 8],
                          then: [enabled[i] < Const(1)],
                        ),
                    ],
                    orElse: [
                      datOut <
                          [
                            for (
                              var i = (sources > 32 ? 31 : sources - 1);
                              i >= 0;
                              i--
                            )
                              enabled[i],
                          ].swizzle().zeroExtend(32),
                    ],
                  ),
                ],
              ),

              // clrie
              If(
                addr.eq(Const(0x1F00, width: 15)),
                then: [
                  If(
                    we,
                    then: [
                      for (var i = 0; i < sources && i < 32; i++)
                        If(
                          datIn[i] & bus.sel[i ~/ 8],
                          then: [enabled[i] < Const(0)],
                        ),
                    ],
                  ),
                ],
              ),

              // target
              for (var i = 0; i < sources; i++)
                If(
                  addr.eq(Const(0x3004 + i * 4, width: 15)),
                  then: [
                    If(
                      we,
                      then: [
                        target[i] < bus.selMerge(target[i], 0x3004 + i * 4),
                      ],
                      orElse: [datOut < target[i]],
                    ),
                  ],
                ),

              // IDC per hart
              for (var h = 0; h < harts; h++) ...[
                If(
                  addr.eq(Const(0x4000 + h * 32, width: 15)),
                  then: [
                    If(
                      we & bus.selAny(0x4000 + h * 32, 1),
                      then: [idelivery[h] < datIn[0]],
                      orElse: [datOut < idelivery[h].zeroExtend(32)],
                    ),
                  ],
                ),
                If(
                  addr.eq(Const(0x4000 + h * 32 + 4, width: 15)),
                  then: [
                    If(
                      we & bus.selAny(0x4000 + h * 32 + 4, 1),
                      then: [iforce[h] < datIn[0]],
                      orElse: [datOut < iforce[h].zeroExtend(32)],
                    ),
                  ],
                ),
                If(
                  addr.eq(Const(0x4000 + h * 32 + 8, width: 15)),
                  then: [
                    If(
                      we,
                      then: [
                        ithreshold[h] <
                            bus.selMerge(ithreshold[h], 0x4000 + h * 32 + 8),
                      ],
                      orElse: [datOut < ithreshold[h].zeroExtend(32)],
                    ),
                  ],
                ),
                // claimi
                If(
                  addr.eq(Const(0x4000 + h * 32 + 0x1C, width: 15)),
                  then: [
                    for (var src = 0; src < sources; src++)
                      If(
                        pending[src] &
                            enabled[src] &
                            target[src]
                                .getRange(0, hartIdWidth)
                                .eq(Const(h, width: hartIdWidth)),
                        then: [
                          datOut < Const(src, width: 32),
                          pending[src] < Const(0),
                        ],
                      ),
                  ],
                ),
              ],
            ],
          ),
        ],
      ),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['riscv,aplic'],
    reg: BusAddressRange(baseAddress, 0x8000),
    interruptController: true,
    interruptCells: 2,
    properties: {'riscv,num-sources': sources},
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    // Same reasoning as the PLIC: ACPI matches a real _HID, not the PRP0001
    // device-tree shim. Linux matches `RSCV0002`
    // (drivers/irqchip/irq-riscv-aplic-main.c) and enumerates it with
    // `acpi_get_devices("RSCV0002", ...)` in drivers/acpi/riscv/irq.c, taking
    // gsi_base/id/nr_irqs from the MADT rather than from _DSD. The device-tree
    // form is unaffected, see [dtNode] above.
    hid: 'RSCV0002',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x8000)],
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'APLIC',
    groupName: 'APLIC',
    description: 'RISC-V Advanced Platform-Level Interrupt Controller',
    baseAddress: baseAddress,
    size: 0x8000,
  );
}
