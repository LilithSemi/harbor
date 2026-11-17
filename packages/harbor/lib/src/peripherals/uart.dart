import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../arith/fpu_config.dart' show harborStableDefinitionName;
import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../bus/port/reg_fifo.dart' show HarborFifoRam;
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../soc/target.dart';
import 'device_register.dart';

/// 16550A-compatible UART peripheral.
///
/// Works with Linux `ns16550a` driver and U-Boot `ns16550` driver.
///
/// The UART follows the TI PC16550D data sheet. One bit lasts 16 times the
/// divisor in clocks, and the clock-frequency property gives the raw clock.
///
/// It has a 16-byte TX FIFO and
/// a 16-byte RX FIFO in distributed RAM. FCR bit 0 enables the FIFOs. With
/// the FIFOs off, each direction holds one byte, as in a 16450. A byte that
/// arrives when the RX FIFO is full is dropped and sets LSR OE. A THR write
/// when the TX FIFO is full is dropped. A frame with a low stop bit is
/// dropped, so LSR bits 7 and 4:2 always read 0. The UART has no modem pins:
/// MSR reads 0, and MSR follows MCR only in loopback.
///
/// Register map (standard 16550), register index n:
/// - 0: RBR (read) / THR (write) / DLL (DLAB=1)
/// - 1: IER (DLAB=0) / DLM (DLAB=1)
/// - 2: IIR (read) / FCR (write)
/// - 3: LCR (bit 7 = DLAB)
/// - 4: MCR
/// - 5: LSR (read-only)
/// - 6: MSR (read-only)
/// - 7: SCR
///
/// The registers sit in a 0x1000 window. [regShift] sets their stride:
///
/// - 0: register n is the byte at offset n (8 bytes). On a bus wider than
///   8 bits the registers share words. A write selects its register through
///   one byte lane. A write that selects more than one lane changes nothing
///   and ends with a bus error. A read returns the whole word with each
///   register in its lane, and the master takes the byte it wants.
/// - 2: register n is the 32-bit word at offset n * 4 (32 bytes). The value
///   is in bits 7:0 and bits 31:8 read 0. A write changes register n only
///   when byte lane 0 of that word is selected. The bus must be 32 bits or
///   wider, so a master that does only word accesses reaches every register.
class HarborUart extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider,
        HarborSimModelProvider,
        HarborInputClockConsumer {
  final int? busDataWidth;
  final int baseAddress;
  int clockFrequency;

  /// Register stride as a power of two: 0 for byte registers, 2 for word
  /// registers.
  final int regShift;

  /// TX serial output.
  Logic get tx => output('tx');

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  /// Bus slave port.
  late final BusSlavePort bus;

  // A packed UART on a multi-byte bus fails multi-lane writes through ERR.
  static bool _useErr(int regShift, int dataWidth) =>
      regShift == 0 && dataWidth > 8;

  static String _definitionName({
    required HarborFabricKind kind,
    required int addressWidth,
    required int dataWidth,
    required bool cross,
    required int regShift,
  }) {
    if (regShift != 0 && regShift != 2) {
      throw ArgumentError.value(
        regShift,
        'regShift',
        'must be 0 (byte registers) or 2 (32-bit word registers)',
      );
    }
    // An AXI4-Lite read has no byte strobes, so it selects whole 32-bit
    // words. A read of one packed register would also read its neighbours,
    // and a read of IIR, LSR or RBR changes state.
    if (kind == HarborFabricKind.axi4 && regShift == 0 && dataWidth > 8) {
      throw ArgumentError.value(
        dataWidth,
        'busDataWidth',
        'must be 8 when regShift is 0 on AXI4, because an AXI4-Lite read '
            'selects every register in the word',
      );
    }
    if (regShift == 2 && dataWidth < 32) {
      throw ArgumentError.value(
        dataWidth,
        'busDataWidth',
        'must be 32 or more when regShift is 2',
      );
    }
    return harborStableDefinitionName('HarborUart', [
      ...BusSlavePort.definitionNameParts(
        kind: kind,
        addressWidth: addressWidth,
        dataWidth: dataWidth,
        useErr: _useErr(regShift, dataWidth),
        cross: cross,
      ),
      if (regShift != 0) 's$regShift',
    ]);
  }

  HarborUart({
    required this.baseAddress,
    this.clockFrequency = 0,
    int? busAddressWidth,
    this.busDataWidth,
    this.regShift = 0,
    HarborFabricKind fabricKind = HarborFabricKind.wishbone,
    bool crossFabricClock = false,
    String? name,
  }) : super(
         _definitionName(
           kind: fabricKind,
           addressWidth: busAddressWidth ?? 12,
           dataWidth: busDataWidth ?? 8,
           cross: crossFabricClock,
           regShift: regShift,
         ),
         name: name ?? 'uart',
       ) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('rx', PortDirection.input);
    addOutput('tx');
    addOutput('interrupt');

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      kind: fabricKind,
      clk: input('clk'),
      reset: input('reset'),
      // The full 0x1000 window, so no address in it aliases a register.
      addressWidth: busAddressWidth ?? 12,
      dataWidth: busDataWidth ?? 8,
      useErr: _useErr(regShift, busDataWidth ?? 8),
      fabricClock: BusSlavePort.fabricClockInputs(
        this,
        cross: crossFabricClock,
      ),
    );

    final clk = input('clk');
    final reset = bus.reset;
    final lanes = bus.dataIn.width ~/ 8;
    final wide = regShift == 2;
    // Register index and write data of the packed layout. The bus carries
    // word-aligned addresses with the byte position in the SEL lanes.
    Logic? addr;
    Logic? datIn;
    if (!wide && lanes == 1) {
      addr = bus.addr.getRange(0, 3);
      datIn = bus.dataIn.getRange(0, 8);
    } else if (!wide) {
      final laneBits = (lanes - 1).bitLength;
      final wrLane = Logic(name: 'uart_wr_lane', width: laneBits);
      Combinational([
        wrLane < Const(0, width: laneBits),
        for (var i = 1; i < lanes; i++)
          If(bus.sel[i], then: [wrLane < Const(i, width: laneBits)]),
      ]);
      // The lane in the word, plus the word-select address bit on a 32-bit
      // bus. A 64-bit bus holds all 8 registers in one word.
      addr = laneBits >= 3 ? wrLane : [bus.addr[2], wrLane].concat();
      final laneData = Logic(name: 'uart_dat_in', width: 8);
      Combinational([
        laneData < Const(0, width: 8),
        for (var i = 0; i < lanes; i++)
          If(
            wrLane.eq(Const(i, width: laneBits)),
            then: [laneData < bus.dataIn.getRange(8 * i, 8 * i + 8)],
          ),
      ]);
      datIn = laneData;
    }
    // Other offsets in the window read 0 and ignore writes. Address bits
    // above the window are ignored, so absolute and window-relative
    // addresses both work.
    final inWindow = bus.inSpan(wide ? 32 : 8, 0x1000).named('uart_in_window');
    // A write that selects no byte at all (AXI4 WSTRB 0) changes nothing.
    final anySel = bus.sel.or().named('uart_any_sel');
    final multiLane = lanes == 1
        ? Const(0)
        : (bus.sel & (bus.sel - 1)).or().named('uart_multi_lane');
    final datOutW = Logic(name: 'uart_dat_out', width: bus.dataOut.width);
    bus.dataOut <= datOutW;
    final ack = bus.ack;
    final errR = Logic(name: 'uart_err');
    bus.err?.gets(errR);
    final stb = bus.stb;
    final we = bus.we;

    // Registers
    final dll = Logic(name: 'dll', width: 8);
    final dlm = Logic(name: 'dlm', width: 8);
    final ier = Logic(name: 'ier', width: 8);
    final fcr = Logic(name: 'fcr', width: 8);
    final lcr = Logic(name: 'lcr', width: 8);
    final mcr = Logic(name: 'mcr', width: 8);
    final scr = Logic(name: 'scr', width: 8);

    final dlab = lcr[7];
    final fifoOn = fcr[0];

    // TX state. The TX FIFO holds 16 bytes in distributed RAM. A THR write
    // lands in thrData and enters the FIFO one cycle later.
    final txBusy = Logic(name: 'tx_busy');
    final txShift = Logic(name: 'tx_shift', width: 10);
    final txCount = Logic(name: 'tx_count', width: 4);
    final thrData = Logic(name: 'thr_data', width: 8);
    final thrValid = Logic(name: 'thr_valid');
    final txWr = Logic(name: 'tx_wr_ptr', width: 5);
    final txRd = Logic(name: 'tx_rd_ptr', width: 5);
    // The THRE interrupt is a latch: it sets when the TX FIFO empties and
    // clears on a THR write or on an IIR read that reports it.
    final threPend = Logic(name: 'thre_pend');
    final txEmptyQ = Logic(name: 'tx_empty_q');

    // RX state. The RX FIFO holds 16 bytes in distributed RAM. The pin is
    // asynchronous, so it passes through a two-flop synchronizer before the
    // sampler looks at it.
    final rxIn = input('rx');
    final rxSyncA = Logic(name: 'rx_sync_a');
    final rxSyncB = Logic(name: 'rx_sync_b');
    final rxBusy = Logic(name: 'rx_busy');
    final rxBits = Logic(name: 'rx_bits', width: 4);
    final rxPhase = Logic(name: 'rx_phase', width: 4);
    final rxSample = Logic(name: 'rx_sample');
    final rxShift = Logic(name: 'rx_shift', width: 8);
    final rxWr = Logic(name: 'rx_wr_ptr', width: 5);
    final rxRd = Logic(name: 'rx_rd_ptr', width: 5);
    final overrun = Logic(name: 'rx_overrun');
    final timeoutCount = Logic(name: 'rx_timeout_count', width: 6);
    final timeoutFlag = Logic(name: 'rx_timeout');

    // FIFO fill levels. Pointers carry one extra bit, so the difference is
    // the level. With FIFOs off the capacity is one byte.
    final txLevel = (txWr - txRd).named('tx_level');
    final rxLevel = (rxWr - rxRd).named('rx_level');
    Logic fullOf(Logic level) => level[4] | (~fifoOn & level.or());
    final txFull = fullOf(txLevel).named('tx_full');
    final rxFull = fullOf(rxLevel).named('rx_full');
    final rxHasData = rxLevel.or().named('rx_has_data');
    final txEmpty = (~txLevel.or() & ~thrValid).named('tx_empty');

    // A frame with a high stop bit ends in the RX FIFO. A frame that finds
    // the FIFO full is dropped and sets the overrun flag.
    final rxFrame =
        (rxBusy & rxSample & rxBits.gt(Const(8, width: 4)) & rxSyncB).named(
          'rx_frame',
        );
    // An RBR read in the same cycle frees the slot the frame needs.
    final rbrPop = Logic(name: 'rbr_pop');
    final rxPush = (rxFrame & (~rxFull | rbrPop)).named('rx_push');
    final txPush = (thrValid & ~txFull).named('tx_push');

    final txRam = HarborFifoRam(
      name: 'tx_fifo_ram',
      clk: clk,
      wrEn: txPush,
      wrAddr: txWr.getRange(0, 4),
      wrData: thrData,
      rdAddr: txRd.getRange(0, 4),
      depth: 16,
      zeroInit: true,
    );
    final rxRam = HarborFifoRam(
      name: 'rx_fifo_ram',
      clk: clk,
      wrEn: rxPush,
      wrAddr: rxWr.getRange(0, 4),
      wrData: rxShift,
      rdAddr: rxRd.getRange(0, 4),
      depth: 16,
      zeroInit: true,
    );

    // Baud rate. As in a 16550, one bit lasts 16 divisor periods. The
    // baud tick runs at 16 times the bit rate, and txPhase counts it up to
    // the bit tick.
    final baudCount = Logic(name: 'baud_count', width: 16);
    final baudTick = Logic(name: 'baud_tick');
    final txPhase = Logic(name: 'tx_phase', width: 4);
    final divisor = [dlm, dll].concat();
    // A write of a divisor latch loads the counter, as in a PC16550D.
    Logic divisorLoad(Logic next) => mux<Logic>(
      next.eq(Const(0, width: 16)),
      Const(0, width: 16),
      next - Const(1, width: 16),
    );
    baudTick <=
        baudCount.eq(Const(0, width: 16)) & divisor.neq(Const(0, width: 16));
    final bitTick = (baudTick & txPhase.eq(Const(15, width: 4))).named(
      'bit_tick',
    );

    // LSR. Bit 7 stays 0 because a frame with a low stop bit is dropped, so
    // no byte in the FIFO carries an error. Bits 4:2 are 0 for the same
    // reason.
    final lsr = Logic(name: 'lsr', width: 8);
    lsr <=
        [
          Const(0),
          txEmpty & ~txBusy, // TEMT
          txEmpty, // THRE
          Const(0, width: 3),
          overrun, // OE
          rxHasData, // DR
        ].concat();

    // MSR. The UART has no modem pins. In loopback the upper nibble follows
    // MCR and the delta bits stay 0.
    final msr = mux(
      mcr[4],
      [mcr[3], mcr[2], mcr[0], mcr[1], Const(0, width: 4)].concat(),
      Const(0, width: 8),
    );

    // Interrupt sources, highest priority first.
    final rxTrigger = fcr.getRange(6, 8).selectFrom(<Logic>[
      Const(1, width: 5),
      Const(4, width: 5),
      Const(8, width: 5),
      Const(14, width: 5),
    ]);
    final rxLevelHit = mux(fifoOn, rxLevel.gte(rxTrigger), rxHasData);
    final lineInt = ier[2] & overrun;
    final rxInt = ier[0] & rxLevelHit;
    final timeoutInt = fifoOn & ier[0] & timeoutFlag;
    final threInt = ier[1] & threPend;
    final computedIir = Logic(name: 'computed_iir', width: 8);
    Combinational([
      If.block([
        Iff(lineInt, [computedIir < Const(0x06, width: 8)]),
        ElseIf(rxInt, [computedIir < Const(0x04, width: 8)]),
        ElseIf(timeoutInt, [computedIir < Const(0x0c, width: 8)]),
        ElseIf(threInt, [computedIir < Const(0x02, width: 8)]),
        Else([computedIir < Const(0x01, width: 8)]),
      ]),
    ]);
    final iirOut = [
      fifoOn,
      fifoOn,
      Const(0, width: 2),
      computedIir.getRange(0, 4),
    ].concat();

    // The output comes from one flop, so it carries no glitch from the
    // interrupt logic.
    final irqQ = Logic(name: 'irq_q');
    interrupt <= irqQ;
    final irqNext = lineInt | rxInt | timeoutInt | threInt;

    // Read value of each register index.
    final regValue = <Logic>[
      mux(dlab, dll, rxRam.rdData),
      mux(dlab, dlm, ier),
      iirOut,
      lcr,
      mcr,
      lsr,
      msr,
      scr,
    ];

    // Write of data [d] to the register at index [idx].
    Conditional writeReg(Logic idx, Logic d) => Case(idx, [
      CaseItem(Const(0, width: 3), [
        If(
          dlab,
          then: [
            dll < d,
            baudCount < divisorLoad([dlm, d].concat()),
          ],
          orElse: [thrData < d, thrValid < Const(1), threPend < Const(0)],
        ),
      ]),
      CaseItem(Const(1, width: 3), [
        If(
          dlab,
          then: [
            dlm < d,
            baudCount < divisorLoad([d, dll].concat()),
          ],
          orElse: [
            // Only bits 3:0 exist. Enabling THRE while the TX FIFO is empty
            // raises the interrupt.
            ier < (d & Const(0x0f, width: 8)),
            If(d[1] & ~ier[1] & txEmpty, then: [threPend < Const(1)]),
          ],
        ),
      ]),
      // The reset bits do not stay set. A change of the enable bit clears
      // both FIFOs. The byte in the TX shift register still goes out.
      CaseItem(Const(2, width: 3), [
        fcr < (d & Const(0xc1, width: 8)),
        If(
          (d[0] & d[1]) | (d[0] ^ fcr[0]),
          then: [
            rxWr < Const(0, width: 5),
            rxRd < Const(0, width: 5),
            timeoutCount < Const(0, width: 6),
            timeoutFlag < Const(0),
          ],
        ),
        If(
          (d[0] & d[2]) | (d[0] ^ fcr[0]),
          then: [
            txWr < Const(0, width: 5),
            txRd < Const(0, width: 5),
            thrValid < Const(0),
          ],
        ),
      ]),
      CaseItem(Const(3, width: 3), [lcr < d]),
      CaseItem(Const(4, width: 3), [mcr < d]),
      // LSR (5) and MSR (6) are read-only.
      CaseItem(Const(7, width: 3), [scr < d]),
    ]);

    // A read changes state only when it selects the byte lane of the
    // register: RBR pops the receive buffer and IIR clears THRE. A read of
    // another register in the same word does neither.
    final List<Conditional> readItems;
    final List<Conditional> writeItems;
    // High when the bus word of a read holds register [r] in a selected lane.
    final Logic Function(int r) regSel;
    if (wide) {
      // Each bus word holds `slots` registers, one per 32-bit slot. Slot s
      // of word w is register w * slots + s.
      final wordBits = lanes.bitLength - 1;
      final slots = lanes ~/ 4;
      final slotBits = wordBits - 2;
      final Logic? word = wordBits < 5
          ? bus.windowAddr(32).getRange(wordBits, 5)
          : null;
      Logic regIndex(int s) => switch ((word, slotBits)) {
        (null, _) => Const(s, width: 3),
        (final w?, 0) => w,
        (final w?, _) => [w, Const(s, width: slotBits)].concat(),
      };
      final used = slots < 8 ? slots : 8;
      final slotValue = [
        for (var s = 0; s < slots; s++)
          if (s >= used)
            Const(0, width: 32)
          else if (word == null)
            regValue[s].zeroExtend(32)
          else
            word
                .selectFrom([
                  for (var w = 0; w < 8 ~/ slots; w++) regValue[w * slots + s],
                ])
                .zeroExtend(32),
      ];
      regSel = (r) => [
        for (var s = 0; s < used; s++)
          regIndex(s).eq(Const(r, width: 3)) & bus.sel[4 * s],
      ].reduce((a, b) => a | b);
      readItems = [
        datOutW <
            slotValue.reversed.toList().concat().zeroExtend(bus.dataOut.width),
      ];
      writeItems = [
        for (var s = 0; s < used; s++)
          If(
            bus.sel[4 * s],
            then: [
              writeReg(regIndex(s), bus.dataIn.getRange(32 * s, 32 * s + 8)),
            ],
          ),
      ];
    } else if (lanes == 1) {
      regSel = (r) => addr!.eq(Const(r, width: 3));
      readItems = [
        Case(addr!, [
          for (var i = 0; i < 8; i++)
            CaseItem(Const(i, width: 3), [datOutW < regValue[i]]),
        ]),
      ];
      writeItems = [
        If(anySel, then: [writeReg(addr, datIn!)]),
      ];
    } else {
      // Every register of the addressed word is returned in its lane.
      regSel = (r) {
        if (lanes >= 8) return bus.sel[r];
        final lane = r & 3 < lanes ? bus.sel[r & 3] : Const(0);
        return (r < 4 ? ~bus.addr[2] : bus.addr[2]) & lane;
      };
      final word0 = regValue.sublist(0, 4).reversed.toList().concat();
      final word1 = regValue.sublist(4).reversed.toList().concat();
      if (lanes >= 8) {
        readItems = [
          datOutW < [word1, word0].concat().zeroExtend(bus.dataOut.width),
        ];
      } else {
        readItems = [
          If(
            bus.addr[2],
            then: [datOutW < word1.zeroExtend(bus.dataOut.width)],
            orElse: [datOutW < word0.zeroExtend(bus.dataOut.width)],
          ),
        ];
      }
      // A write to more than one lane is not one register write, so it
      // changes nothing and fails.
      writeItems = [
        If(
          multiLane,
          then: [errR < Const(1)],
          orElse: [
            If(anySel, then: [writeReg(addr!, datIn!)]),
          ],
        ),
      ];
    }

    // The middle of the start bit is 8 ticks after the edge, the middle of
    // every other bit 16 ticks after the one before.
    rxSample <=
        (rxBusy &
            baudTick &
            rxPhase.eq(
              mux<Logic>(
                rxBits.eq(Const(0, width: 4)),
                Const(7, width: 4),
                Const(15, width: 4),
              ),
            ));

    // Reads that change state. A read of RBR, IIR or LSR acts only when its
    // own lane is selected.
    final readEvt = stb & ~ack & inWindow & ~we;
    final rbrRead = (readEvt & ~dlab & regSel(0)).named('rbr_read');
    rbrPop <= rbrRead & rxHasData;

    // Four character times in bit times: start, data, parity, stop.
    final timeoutLimit =
        ((Const(7, width: 6) +
                    lcr.getRange(0, 2).zeroExtend(6) +
                    lcr[3].zeroExtend(6) +
                    lcr[2].zeroExtend(6)) <<
                Const(2, width: 6))
            .named('rx_timeout_limit');

    Sequential(clk, [
      If(
        reset,
        then: [
          dll < Const(1, width: 8),
          dlm < Const(0, width: 8),
          ier < Const(0, width: 8),
          fcr < Const(0, width: 8),
          lcr < Const(0x03, width: 8), // 8N1
          mcr < Const(0, width: 8),
          scr < Const(0, width: 8),
          txBusy < Const(0),
          txShift < Const(0x3FF, width: 10),
          txCount < Const(0, width: 4),
          thrData < Const(0, width: 8),
          thrValid < Const(0),
          txWr < Const(0, width: 5),
          txRd < Const(0, width: 5),
          threPend < Const(0),
          txEmptyQ < Const(1),
          irqQ < Const(0),
          rxWr < Const(0, width: 5),
          rxRd < Const(0, width: 5),
          overrun < Const(0),
          timeoutCount < Const(0, width: 6),
          timeoutFlag < Const(0),
          rxSyncA < Const(1), // idle-high line
          rxSyncB < Const(1),
          rxBusy < Const(0),
          rxBits < Const(0, width: 4),
          rxPhase < Const(0, width: 4),
          txPhase < Const(0, width: 4),
          rxShift < Const(0, width: 8),
          baudCount < Const(0, width: 16),
          ack < Const(0),
          errR < Const(0),
          datOutW < Const(0, width: bus.dataOut.width),
        ],
        orElse: [
          irqQ < irqNext,

          // Baud counter
          // The counter holds at 0 while the divisor is 0.
          If(
            baudCount.eq(Const(0, width: 16)),
            then: [
              If(
                divisor.neq(Const(0, width: 16)),
                then: [baudCount < (divisor - Const(1, width: 16))],
              ),
            ],
            orElse: [baudCount < (baudCount - Const(1, width: 16))],
          ),

          If(baudTick, then: [txPhase < (txPhase + Const(1, width: 4))]),

          // TX engine
          If(
            txBusy & bitTick,
            then: [
              txShift < (txShift >> Const(1, width: 10)),
              txCount < (txCount + Const(1, width: 4)),
              If(
                txCount.eq(Const(9, width: 4)),
                then: [txBusy < Const(0), txCount < Const(0, width: 4)],
              ),
            ],
          ),

          // THRE interrupt when the TX FIFO becomes empty.
          txEmptyQ < txEmpty,
          If(txEmpty & ~txEmptyQ, then: [threPend < Const(1)]),

          thrValid < Const(0),
          If(txPush, then: [txWr < (txWr + Const(1, width: 5))]),

          // Load from the TX FIFO when TX idle, on a baud tick. The baud
          // counter runs free, as in a 16550, so the start bit lasts exactly
          // 16 divisor periods and the receiver keeps its sample points.
          // Nothing loads while the divisor is 0.
          If(
            ~txBusy & txLevel.or() & baudTick,
            then: [
              txShift <
                  [
                    Const(1, width: 1),
                    txRam.rdData,
                    Const(0, width: 1),
                  ].concat(),
              txBusy < Const(1),
              txCount < Const(0, width: 4),
              txRd < (txRd + Const(1, width: 5)),
              txPhase < Const(0, width: 4),
            ],
          ),

          // RX engine: hunt for a start bit on the synchronized line, then
          // sample at the middle of each bit, 8 baud ticks after the start
          // edge and every 16 ticks after that (8N1, LSB first). The divisor
          // gate keeps the receiver idle until the UART is configured, the
          // same rule the transmitter follows.
          rxSyncA < rxIn,
          rxSyncB < rxSyncA,
          If(
            ~rxBusy,
            then: [
              If(
                ~rxSyncB & divisor.neq(Const(0, width: 16)),
                then: [
                  rxBusy < Const(1),
                  rxBits < Const(0, width: 4),
                  rxPhase < Const(0, width: 4),
                ],
              ),
            ],
            orElse: [
              If(
                rxSample,
                then: [
                  rxPhase < Const(0, width: 4),
                  If(
                    rxBits.eq(Const(0, width: 4)),
                    then: [
                      // Mid-start: still low means a real start bit, else a
                      // glitch, so re-arm the hunt.
                      If(
                        ~rxSyncB,
                        then: [rxBits < Const(1, width: 4)],
                        orElse: [rxBusy < Const(0)],
                      ),
                    ],
                    orElse: [
                      If(
                        rxBits.lte(Const(8, width: 4)),
                        then: [
                          // Data bits 1..8: insert at the top and shift down,
                          // so the first (LSB-first) bit ends at bit 0.
                          rxShift < [rxSyncB, rxShift.getRange(1, 8)].concat(),
                          rxBits < (rxBits + Const(1, width: 4)),
                        ],
                        orElse: [
                          // Stop position: a high line frames a valid byte,
                          // and rxFrame pushes it into the RX FIFO.
                          rxBusy < Const(0),
                        ],
                      ),
                    ],
                  ),
                ],
                orElse: [
                  If(
                    baudTick,
                    then: [rxPhase < (rxPhase + Const(1, width: 4))],
                  ),
                ],
              ),
            ],
          ),

          If(rxPush, then: [rxWr < (rxWr + Const(1, width: 5))]),
          If(rbrRead & rxHasData, then: [rxRd < (rxRd + Const(1, width: 5))]),

          // The timeout counts bit times from the last byte in or out of the
          // RX FIFO. It stops at four character times.
          If(
            rxPush | rbrRead | ~rxHasData,
            then: [timeoutCount < Const(0, width: 6), timeoutFlag < Const(0)],
            orElse: [
              If(
                bitTick & ~timeoutFlag,
                then: [
                  timeoutCount < (timeoutCount + Const(1, width: 6)),
                  If(
                    timeoutCount.eq(timeoutLimit - Const(1, width: 6)),
                    then: [timeoutFlag < Const(1)],
                  ),
                ],
              ),
            ],
          ),

          // Bus access
          ack < Const(0),
          errR < Const(0),
          datOutW < Const(0, width: bus.dataOut.width),

          If(
            stb & ~ack,
            then: [
              ack < Const(1),

              If(
                inWindow & we,
                then: writeItems,
                orElse: [If(inWindow & ~we, then: readItems)],
              ),
              // An IIR read that reports THRE clears it.
              If(
                inWindow &
                    ~we &
                    regSel(2) &
                    computedIir.getRange(0, 4).eq(Const(2, width: 4)),
                then: [threPend < Const(0)],
              ),
              // An LSR read clears the overrun flag.
              If(readEvt & regSel(5), then: [overrun < Const(0)]),
            ],
          ),
          If(rxFrame & ~rxPush, then: [overrun < Const(1)]),
        ],
      ),
    ]);

    // TX output: LSB of shift register when busy, else idle high
    Combinational([
      If(txBusy, then: [tx < txShift[0]], orElse: [tx < Const(1)]),
    ]);
  }

  /// A terminal on the TX line: decodes 8N1 serial and writes bytes to stdout.
  ///
  /// The divisor is a runtime register, so the bit period cannot be known when
  /// this is generated. The default assumes the firmware programs a divisor of
  /// `<this peripheral's clock>` / (16 * 115200) for 115200 baud; override with
  /// `--uart-cycles-per-bit=N`. A wrong value is reported as a framing error
  /// rather than printed as mojibake, so the failure names its own cause.
  ///
  /// The tick domain and the bit period BOTH come from
  /// [HarborSimModelContext.peripheralClockPort]. Taking them from different
  /// clocks is what made the first version print garbage: it ticked on the
  /// 100 MHz primary while sizing bits for a 50 MHz UART clock.
  @override
  List<HarborSimModel> simModels(HarborSimModelContext ctx) {
    final txPort = ctx.topPort('tx');
    // Not exposed at the top level, so nothing on the host can see it.
    if (txPort == null) return const [];
    // The harness level-gates every model on its clockPort, which only ticks
    // once per cycle for the FASTEST (primary) clock; a slower clockPort would
    // fire several times per cycle. So the sink ticks on the primary clock and
    // measures the bit period in PRIMARY ticks: it oversamples the tx line and
    // counts real time, which is correct whatever clock the UART sits on (the
    // firmware programs 115200 baud in real time regardless of its divisor).
    final cyclesPerBit = (ctx.clockHz / 115200).round().clamp(2, 1 << 30);
    final inst = '${name}_sink';
    return [
      HarborSimModel(
        className: 'UartSink',
        clockPort: ctx.primaryClockPort,
        header: _uartSinkHeader,
        declaration: 'static UartSink $inst($cyclesPerBit, "$name");',
        tick: '$inst.tick(top->$txPort);',
        cliOption:
            'else if (!strncmp(argv[a], "--uart-cycles-per-bit=", 22))\n'
            '      $inst.cycles_per_bit = atoi(argv[a] + 22);',
      ),
    ];
  }

  static const _uartSinkHeader = r"""
#pragma once
// Decodes 8N1 serial on a UART TX line and writes each byte to stdout.
//
// Samples at the middle of every bit: on the falling start edge it waits 1.5
// bit periods to land in the centre of bit 0, then one period per bit after
// that. The stop bit must read high; if it does not, the configured bit period
// disagrees with what the firmware programmed, which is reported rather than
// letting the output turn to garbage.
#include <cstdio>
#include <cstdint>

struct UartSink {
  const char* tag;
  int cycles_per_bit;
  int state = 0;   // 0 = idle, 1 = receiving
  int counter = 0;
  int bit_index = 0;
  uint8_t shifter = 0;
  int prev = 1;    // the line idles high
  long framing_errors = 0;

  UartSink(int cpb, const char* t) : tag(t), cycles_per_bit(cpb) {}

  void tick(int tx) {
    if (state == 0) {
      if (prev == 1 && tx == 0) {
        state = 1;
        // 1.5 bit periods lands in the middle of bit 0.
        counter = cycles_per_bit + cycles_per_bit / 2;
        bit_index = 0;
        shifter = 0;
      }
    } else if (--counter <= 0) {
      if (bit_index < 8) {
        shifter >>= 1;                       // LSB first
        if (tx) shifter |= 0x80;
        bit_index++;
        counter = cycles_per_bit;
      } else {
        if (tx) {
          fputc(shifter, stdout);
          fflush(stdout);
        } else if (++framing_errors <= 4) {
          fprintf(stderr,
                  "[%s] UART framing error: stop bit low. The bit period "
                  "(%d cycles) does not match the programmed divisor; set "
                  "--uart-cycles-per-bit=N\n",
                  tag, cycles_per_bit);
        }
        state = 0;
      }
    }
    prev = tx;
  }
};
""";

  @override
  int get inputClockHz => clockFrequency;

  @override
  void provideInputClockHz(int hz) {
    if (clockFrequency == 0) clockFrequency = hz;
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['ns16550a'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      'reg-shift': regShift,
      'reg-io-width': 1 << regShift,
      if (clockFrequency > 0) 'clock-frequency': clockFrequency,
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'RSCV0003',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['ns16550a'],
      'reg-shift': regShift,
      'reg-io-width': 1 << regShift,
      if (clockFrequency > 0) 'clock-frequency': clockFrequency,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'UART',
    groupName: 'UART',
    description: '16550-compatible UART',
    baseAddress: baseAddress,
    size: 0x1000,
    registers: regShift == 2
        ? StandardRegisters.uart16550Word
        : StandardRegisters.uart16550,
  );
}
