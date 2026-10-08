import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import 'device_register.dart';

/// RISC-V Core Local Interruptor (CLINT), SiFive-compatible.
///
/// Provides per-hart timer and software interrupt functionality.
/// Compatible with Linux `riscv,clint0` driver.
///
/// Register map (per SiFive CLINT spec):
/// - `msip[hart]`:     0x0000 + hart*4  (4 bytes, software interrupt pending)
/// - `mtimecmp[hart]`: 0x4000 + hart*8  (8 bytes, timer compare)
/// - `mtime`:          0xBFF8           (8 bytes, machine timer)
///
/// Address space: 64 KB (0x10000).
class HarborClint extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  final int? busDataWidth;

  /// Number of harts this CLINT serves.
  final int hartCount;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Timer interrupt output per hart.
  late final List<Logic> timerInterrupt;

  /// Software interrupt output per hart.
  late final List<Logic> softwareInterrupt;

  /// Bus slave port.
  late final BusSlavePort bus;

  HarborClint({
    required this.baseAddress,
    this.hartCount = 1,
    int? busAddressWidth,
    this.busDataWidth,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborClint', name: name ?? 'clint') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: busAddressWidth ?? 16,
      dataWidth: busDataWidth ?? 32,
    );

    final clk = input('clk');
    final reset = input('reset');
    final addr = bus.addr.getRange(0, 16);
    final ack = bus.ack;
    final stb = bus.stb;
    final we = bus.we;

    // Byte-lane decode. The bus carries whole 32-bit words side by side, and a
    // master puts a word-aligned address on ADR with the data and SEL shifted
    // into the byte lane of the access (River MMU wbAdr/wbDatMosi/wbSel, and
    // the debug SBA). So a register at byte offset X answers at bus address
    // X & ~(busBytes - 1) in word lane (X % busBytes) / 4. On a 32-bit bus
    // every register is in lane 0 and this is the identity. On a 64-bit bus the
    // mtimecmp high half is in lane 1: a decode that always took lane 0 wrote
    // the low half with the wrong data and could never set the high half.
    final dataWidth = bus.dataIn.width;
    final busBytes = dataWidth ~/ 8;
    final laneCount = dataWidth ~/ 32;
    final datOut = List.generate(
      laneCount,
      (l) => Logic(name: 'clint_dat_out_$l', width: 32),
    );
    bus.dataOut <= datOut.rswizzle();

    int laneOf(int off) => (off % busBytes) ~/ 4;
    Logic addrHit(int off) => addr.eq(Const(off - (off % busBytes), width: 16));
    // A lane takes a write only when the master selects one of its bytes.
    Logic laneSel(int off) =>
        bus.sel.getRange(laneOf(off) * 4, laneOf(off) * 4 + 4).or();
    Logic wrData(int off) =>
        bus.dataIn.getRange(laneOf(off) * 32, laneOf(off) * 32 + 32);

    timerInterrupt = List.generate(hartCount, (i) => addOutput('timer_irq_$i'));
    softwareInterrupt = List.generate(hartCount, (i) => addOutput('sw_irq_$i'));

    final mtime = Logic(name: 'mtime', width: 64);
    final mtimecmp = List.generate(
      hartCount,
      (i) => Logic(name: 'mtimecmp_$i', width: 64),
    );
    final msip = List.generate(hartCount, (i) => Logic(name: 'msip_$i'));

    for (var i = 0; i < hartCount; i++) {
      timerInterrupt[i] <= mtime.gte(mtimecmp[i]);
      softwareInterrupt[i] <= msip[i];
    }

    // Expose the raw machine timer so a core can serve the `time` CSR (rdtime)
    // natively from the SAME counter its timer interrupts compare against, so
    // the OS clocksource and its timer events never diverge. Single clock domain
    // (mtime ticks on the bus clock), so it reads combinationally.
    final mtimeOut = addOutput('mtime_val', width: 64);
    mtimeOut <= mtime;

    // Per-half write enables for mtimecmp, so one assignment can merge a
    // doubleword store that carries both halves.
    final cmpWriteLo = [
      for (var i = 0; i < hartCount; i++)
        (stb & ~ack & we & addrHit(0x4000 + i * 8) & laneSel(0x4000 + i * 8))
            .named('mtimecmp_wr_lo_$i'),
    ];
    final cmpWriteHi = [
      for (var i = 0; i < hartCount; i++)
        (stb &
                ~ack &
                we &
                addrHit(0x4000 + i * 8 + 4) &
                laneSel(0x4000 + i * 8 + 4))
            .named('mtimecmp_wr_hi_$i'),
    ];

    Sequential(clk, [
      If(
        reset,
        then: [
          mtime < Const(0, width: 64),
          for (var i = 0; i < hartCount; i++) ...[
            // Reset mtimecmp to all ones, not zero. The timer interrupt is
            // mtime >= mtimecmp, so a zero reset asserts MTIP forever until
            // software programs mtimecmp. A hart that enables the machine timer
            // before its first set_timer then takes a continuous timer trap.
            // All ones keeps MTIP low out of reset. Software arms the timer with
            // a real compare value.
            mtimecmp[i] < Const((BigInt.one << 64) - BigInt.one, width: 64),
            msip[i] < Const(0),
          ],
          ack < Const(0),
          for (var l = 0; l < laneCount; l++) datOut[l] < Const(0, width: 32),
        ],
        orElse: [
          mtime < mtime + Const(1, width: 64),
          ack < Const(0),
          for (var l = 0; l < laneCount; l++) datOut[l] < Const(0, width: 32),

          If(
            stb & ~ack,
            then: [
              ack < Const(1),

              for (var i = 0; i < hartCount; i++) ...[
                If(
                  addrHit(i * 4),
                  then: [
                    If(we & laneSel(i * 4), then: [msip[i] < wrData(i * 4)[0]]),
                    If(
                      ~we,
                      then: [datOut[laneOf(i * 4)] < msip[i].zeroExtend(32)],
                    ),
                  ],
                ),
              ],

              // Both mtimecmp halves can arrive in one bus word, so the two
              // halves merge into ONE assignment. Two separate assignments to
              // the same register in a Sequential keep only the last, which
              // would drop the half written by the other lane.
              for (var i = 0; i < hartCount; i++) ...[
                If(
                  cmpWriteLo[i] | cmpWriteHi[i],
                  then: [
                    mtimecmp[i] <
                        [
                          mux(
                            cmpWriteHi[i],
                            wrData(0x4000 + i * 8 + 4),
                            mtimecmp[i].getRange(32, 64),
                          ),
                          mux(
                            cmpWriteLo[i],
                            wrData(0x4000 + i * 8),
                            mtimecmp[i].getRange(0, 32),
                          ),
                        ].swizzle(),
                  ],
                ),
                If(
                  ~we,
                  then: [
                    If(
                      addrHit(0x4000 + i * 8),
                      then: [
                        datOut[laneOf(0x4000 + i * 8)] <
                            mtimecmp[i].getRange(0, 32),
                      ],
                    ),
                    If(
                      addrHit(0x4000 + i * 8 + 4),
                      then: [
                        datOut[laneOf(0x4000 + i * 8 + 4)] <
                            mtimecmp[i].getRange(32, 64),
                      ],
                    ),
                  ],
                ),
              ],

              If(
                addrHit(0xBFF8),
                then: [datOut[laneOf(0xBFF8)] < mtime.getRange(0, 32)],
              ),
              If(
                addrHit(0xBFFC),
                then: [datOut[laneOf(0xBFFC)] < mtime.getRange(32, 64)],
              ),
            ],
          ),
        ],
      ),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['riscv,clint0'],
    reg: BusAddressRange(baseAddress, 0x10000),
    properties: {'reg-names': 'control'},
  );

  @override
  // The CLINT has NO ACPI representation, deliberately. Under ACPI the RISC-V
  // timer is initialised from the RHCT table
  // (`TIMER_ACPI_DECLARE(aclint_mtimer, ACPI_SIG_RHCT, riscv_timer_acpi_init)`,
  // drivers/clocksource/timer-riscv.c) using `sbi_set_timer()` and the `time`
  // CSR, and IPIs come from the SBI IPI extension. Linux never touches CLINT
  // MMIO in that path, which is why there is no RSCV* _HID for it, unlike the
  // PLIC (RSCV0001) and APLIC (RSCV0002).
  //
  // A PRP0001 device-tree shim would not work either: drivers/clocksource/
  // timer-clint.c registers via `TIMER_OF_DECLARE(clint_timer, "riscv,clint0",
  // ...)`, and TIMER_OF_DECLARE is matched only by timer_probe() walking a real
  // device tree at early boot, never through the platform bus that PRP0001
  // feeds. So the old PRP0001 entry could never bind to anything and was just a
  // bogus namespace object.
  //
  // The device-tree description in [dtNode] is unaffected and still complete.
  HarborAcpiDevice? get acpiDevice => null;

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'CLINT',
    groupName: 'CLINT',
    description: 'RISC-V Core Local Interruptor',
    baseAddress: baseAddress,
    size: 0x10000,
    registers: StandardRegisters.clint,
  );
}
