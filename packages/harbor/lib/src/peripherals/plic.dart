import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';

/// RISC-V Platform-Level Interrupt Controller (PLIC), SiFive-compatible.
///
/// Register map (SiFive PLIC spec):
/// - Priority:       0x000000 + source*4   (4 bytes per source)
/// - Pending:        0x001000              (bitmap, 4 bytes per 32 sources)
/// - Enable:         0x002000 + ctx*0x80   (bitmap per context)
/// - Threshold:      0x200000 + ctx*0x1000 (4 bytes per context)
/// - Claim/Complete: 0x200004 + ctx*0x1000 (4 bytes per context)
///
/// Address space: 64 MB (0x4000000).
class HarborPlic extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  final int? busDataWidth;
  final int sources;
  final int contexts;
  final int priorityBits;
  final int baseAddress;

  late final List<Logic> externalInterrupt;
  late final List<Logic> sourceInterrupt;

  /// Bus slave port.
  late final BusSlavePort bus;

  HarborPlic({
    required this.baseAddress,
    this.sources = 32,
    this.contexts = 1,
    this.priorityBits = 3,
    int? busAddressWidth,
    this.busDataWidth,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborPlic', name: name ?? 'plic') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: busAddressWidth ?? 26,
      dataWidth: busDataWidth ?? 32,
    );

    final clk = input('clk');
    final reset = input('reset');
    final addr = bus.addr.getRange(0, 26);
    final ack = bus.ack;
    final stb = bus.stb;
    final we = bus.we;

    // Byte-lane decode. The bus carries whole 32-bit words side by side, and a
    // master puts a word-aligned address on ADR with the data and SEL shifted
    // into the byte lane of the access (River MMU wbAdr/wbDatMosi/wbSel, and
    // the debug SBA). So a register at byte offset X answers at bus address
    // X & ~(busBytes - 1) in word lane (X % busBytes) / 4. On a 32-bit bus
    // every register is in lane 0 and this is the identity. On a 64-bit bus the
    // claim/complete register shares a bus word with the threshold register,
    // and odd-numbered source priorities share a word with the even ones.
    final dataWidth = bus.dataIn.width;
    final busBytes = dataWidth ~/ 8;
    final laneCount = dataWidth ~/ 32;
    final datOut = List.generate(
      laneCount,
      (l) => Logic(name: 'plic_dat_out_$l', width: 32),
    );
    bus.dataOut <= datOut.rswizzle();

    int laneOf(int off) => (off % busBytes) ~/ 4;
    Logic addrHit(int off) => addr.eq(Const(off - (off % busBytes), width: 26));
    // A lane takes a write only when the master selects one of its bytes.
    Logic laneSel(int off) =>
        bus.sel.getRange(laneOf(off) * 4, laneOf(off) * 4 + 4).or();
    Logic wrData(int off) =>
        bus.dataIn.getRange(laneOf(off) * 32, laneOf(off) * 32 + 32);

    sourceInterrupt = List.generate(sources, (i) {
      createPort('src_irq_$i', PortDirection.input);
      return input('src_irq_$i');
    });

    externalInterrupt = List.generate(contexts, (i) => addOutput('ext_irq_$i'));

    final priority = List.generate(
      sources,
      (i) => Logic(name: 'priority_$i', width: priorityBits),
    );
    final pending = List.generate(sources, (i) => Logic(name: 'pending_$i'));
    final claimed = List.generate(sources, (i) => Logic(name: 'claimed_$i'));
    final enable = List.generate(
      contexts,
      (ctx) =>
          List.generate(sources, (src) => Logic(name: 'enable_${ctx}_$src')),
    );
    final threshold = List.generate(
      contexts,
      (i) => Logic(name: 'threshold_$i', width: priorityBits),
    );

    for (var ctx = 0; ctx < contexts; ctx++) {
      Logic anyPending = Const(0);
      for (var src = 0; src < sources; src++) {
        final active =
            pending[src] &
            enable[ctx][src] &
            ~claimed[src] &
            priority[src].gt(threshold[ctx]);
        anyPending = anyPending | active;
      }
      externalInterrupt[ctx] <= anyPending;
    }

    Sequential(clk, [
      If(
        reset,
        then: [
          for (var i = 0; i < sources; i++) ...[
            priority[i] < Const(0, width: priorityBits),
            pending[i] < Const(0),
            claimed[i] < Const(0),
          ],
          for (var ctx = 0; ctx < contexts; ctx++) ...[
            threshold[ctx] < Const(0, width: priorityBits),
            for (var src = 0; src < sources; src++) enable[ctx][src] < Const(0),
          ],
          ack < Const(0),
          for (var l = 0; l < laneCount; l++) datOut[l] < Const(0, width: 32),
        ],
        orElse: [
          for (var i = 0; i < sources; i++)
            If(sourceInterrupt[i] & ~claimed[i], then: [pending[i] < Const(1)]),

          ack < Const(0),
          for (var l = 0; l < laneCount; l++) datOut[l] < Const(0, width: 32),

          If(
            stb & ~ack,
            then: [
              ack < Const(1),

              for (var src = 0; src < sources; src++)
                If(
                  addrHit(src * 4),
                  then: [
                    If(
                      we & laneSel(src * 4),
                      then: [
                        priority[src] <
                            wrData(src * 4).getRange(0, priorityBits),
                      ],
                    ),
                    If(
                      ~we,
                      then: [
                        datOut[laneOf(src * 4)] < priority[src].zeroExtend(32),
                      ],
                    ),
                  ],
                ),

              If(
                addrHit(0x1000),
                then: [
                  datOut[laneOf(0x1000)] <
                      [
                        for (
                          var src = (sources > 32 ? 31 : sources - 1);
                          src >= 0;
                          src--
                        )
                          pending[src],
                      ].swizzle().zeroExtend(32),
                ],
              ),

              for (var ctx = 0; ctx < contexts; ctx++)
                If(
                  addrHit(0x2000 + ctx * 0x80),
                  then: [
                    If(
                      we & laneSel(0x2000 + ctx * 0x80),
                      then: [
                        for (var src = 0; src < sources && src < 32; src++)
                          enable[ctx][src] < wrData(0x2000 + ctx * 0x80)[src],
                      ],
                    ),
                    If(
                      ~we,
                      then: [
                        datOut[laneOf(0x2000 + ctx * 0x80)] <
                            [
                              for (
                                var src = (sources > 32 ? 31 : sources - 1);
                                src >= 0;
                                src--
                              )
                                enable[ctx][src],
                            ].swizzle().zeroExtend(32),
                      ],
                    ),
                  ],
                ),

              for (var ctx = 0; ctx < contexts; ctx++)
                If(
                  addrHit(0x200000 + ctx * 0x1000),
                  then: [
                    If(
                      we & laneSel(0x200000 + ctx * 0x1000),
                      then: [
                        threshold[ctx] <
                            wrData(
                              0x200000 + ctx * 0x1000,
                            ).getRange(0, priorityBits),
                      ],
                    ),
                    If(
                      ~we,
                      then: [
                        datOut[laneOf(0x200000 + ctx * 0x1000)] <
                            threshold[ctx].zeroExtend(32),
                      ],
                    ),
                  ],
                ),

              for (var ctx = 0; ctx < contexts; ctx++)
                // A claim READ has a side effect: it masks the source. So the
                // read arm is gated by SEL too, or a master that reads only the
                // threshold half of the same bus word would eat an interrupt.
                If(
                  addrHit(0x200004 + ctx * 0x1000) &
                      laneSel(0x200004 + ctx * 0x1000),
                  then: [
                    If(
                      we,
                      then: [
                        for (var src = 0; src < sources; src++)
                          If(
                            wrData(0x200004 + ctx * 0x1000)
                                .getRange(0, sources.bitLength)
                                .eq(Const(src, width: sources.bitLength)),
                            then: [
                              claimed[src] < Const(0),
                              pending[src] < Const(0),
                            ],
                          ),
                      ],
                      orElse: [
                        for (var src = 0; src < sources; src++)
                          If(
                            pending[src] & enable[ctx][src] & ~claimed[src],
                            then: [
                              datOut[laneOf(0x200004 + ctx * 0x1000)] <
                                  Const(src, width: 32),
                              claimed[src] < Const(1),
                            ],
                          ),
                      ],
                    ),
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
    compatible: ['sifive,plic-1.0.0'],
    reg: BusAddressRange(baseAddress, 0x4000000),
    interruptController: true,
    interruptCells: 1,
    properties: {'riscv,ndev': sources},
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    // ACPI identifies the PLIC by a real _HID, NOT by the PRP0001 device-tree
    // shim. Linux matches `RSCV0001` (drivers/irqchip/irq-sifive-plic.c
    // plic_acpi_match) and builds its GSI map with
    // `acpi_get_devices("RSCV0001", riscv_acpi_create_gsi_map, ...)`
    // (drivers/acpi/riscv/irq.c). With PRP0001 that search finds nothing, the
    // ext_intc_list stays empty, and riscv_acpi_get_gsi_domain_id() then returns
    // NULL for EVERY gsi, so no device can resolve an interrupt.
    //
    // The DT-shim properties are deliberately dropped: under ACPI the driver
    // takes gsi_base, id, nr_irqs and the context count from the MADT via
    // riscv_acpi_get_gsi_info(), not from _DSD. `interrupt-controller` and
    // `#interrupt-cells` are device-tree concepts ACPI has no notion of.
    // The device-tree form is unaffected, see [dtNode] above.
    hid: 'RSCV0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x4000000)],
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'PLIC',
    groupName: 'PLIC',
    description: 'RISC-V Platform-Level Interrupt Controller',
    baseAddress: baseAddress,
    size: 0x4000000,
  );
}
