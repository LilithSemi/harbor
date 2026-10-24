import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../arith/fpu_config.dart' show harborStableDefinitionName;
import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../soc/target.dart';
import 'device_register.dart';

/// 16550-compatible UART peripheral.
///
/// Works with Linux `ns16550a` driver and U-Boot `ns16550` driver.
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
      addr = laneBits >= 3 ? wrLane : [bus.addr[2], wrLane].swizzle();
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

    // TX state (single-byte holding register, no FIFO for simplicity)
    final txBusy = Logic(name: 'tx_busy');
    final txShift = Logic(name: 'tx_shift', width: 10);
    final txCount = Logic(name: 'tx_count', width: 4);
    final txHolding = Logic(name: 'tx_holding', width: 8);
    final txHoldingFull = Logic(name: 'tx_holding_full');

    // RX state (single-byte holding register). The pin is asynchronous, so it
    // passes through a two-flop synchronizer before the sampler looks at it.
    final rxIn = input('rx');
    final rxSyncA = Logic(name: 'rx_sync_a');
    final rxSyncB = Logic(name: 'rx_sync_b');
    final rxBusy = Logic(name: 'rx_busy');
    final rxBits = Logic(name: 'rx_bits', width: 4);
    final rxBaud = Logic(name: 'rx_baud', width: 16);
    final rxShift = Logic(name: 'rx_shift', width: 8);
    final rxData = Logic(name: 'rx_data', width: 8);
    final rxReady = Logic(name: 'rx_ready');

    // Baud rate
    final baudCount = Logic(name: 'baud_count', width: 16);
    final baudTick = Logic(name: 'baud_tick');
    final divisor = [dlm, dll].swizzle();
    baudTick <=
        baudCount.eq(Const(0, width: 16)) & divisor.neq(Const(0, width: 16));

    // LSR
    final lsr = Logic(name: 'lsr', width: 8);
    lsr <=
        rxReady.zeroExtend(8) | // bit 0: data ready
            ((~txHoldingFull).zeroExtend(8) <<
                Const(5, width: 8)) | // bit 5: THRE
            (((~txHoldingFull) & (~txBusy)).zeroExtend(8) <<
                Const(6, width: 8)); // bit 6: TEMT

    // IIR
    final irqRx = rxReady & ier[0];
    final irqTx = (~txHoldingFull) & ier[1];
    final computedIir = Logic(name: 'computed_iir', width: 8);
    Combinational([
      computedIir < (fcr.getRange(6, 8).zeroExtend(8) << Const(6, width: 8)),
      If(
        irqRx,
        then: [computedIir < (computedIir | Const(0x04, width: 8))],
        orElse: [
          If(
            irqTx,
            then: [computedIir < (computedIir | Const(0x02, width: 8))],
            orElse: [computedIir < (computedIir | Const(0x01, width: 8))],
          ),
        ],
      ),
    ]);

    interrupt <= irqRx | irqTx;

    final dlab = lcr[7];

    // Read value of each register index.
    final regValue = <Logic>[
      mux(dlab, dll, rxData),
      mux(dlab, dlm, ier),
      computedIir,
      lcr,
      mcr,
      lsr,
      Const(0, width: 8),
      scr,
    ];

    // Write of data [d] to the register at index [idx].
    Conditional writeReg(Logic idx, Logic d) => Case(idx, [
      CaseItem(Const(0, width: 3), [
        If(
          dlab,
          then: [dll < d],
          orElse: [txHolding < d, txHoldingFull < Const(1)],
        ),
      ]),
      CaseItem(Const(1, width: 3), [
        If(dlab, then: [dlm < d], orElse: [ier < d]),
      ]),
      CaseItem(Const(2, width: 3), [fcr < d]),
      CaseItem(Const(3, width: 3), [lcr < d]),
      CaseItem(Const(4, width: 3), [mcr < d]),
      // LSR (5) and MSR (6) are read-only.
      CaseItem(Const(7, width: 3), [scr < d]),
    ]);

    // Only a read that selects the RBR byte pops the receive buffer, so a
    // read of another register in the same word does not.
    final List<Conditional> readItems;
    final List<Conditional> writeItems;
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
        (final w?, _) => [w, Const(s, width: slotBits)].swizzle(),
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
      final rbrWord = word == null ? Const(1) : word.eq(0);
      readItems = [
        datOutW <
            slotValue.reversed.toList().swizzle().zeroExtend(bus.dataOut.width),
        If(~dlab & rbrWord & bus.sel[0], then: [rxReady < Const(0)]),
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
      readItems = [
        Case(addr!, [
          for (var i = 0; i < 8; i++)
            CaseItem(Const(i, width: 3), [
              datOutW < regValue[i],
              if (i == 0) If(~dlab, then: [rxReady < Const(0)]),
            ]),
        ]),
      ];
      writeItems = [
        If(anySel, then: [writeReg(addr, datIn!)]),
      ];
    } else {
      // Every register of the addressed word is returned in its lane.
      final word0 = regValue.sublist(0, 4).reversed.toList().swizzle();
      final word1 = regValue.sublist(4).reversed.toList().swizzle();
      if (lanes >= 8) {
        readItems = [
          datOutW < [word1, word0].swizzle().zeroExtend(bus.dataOut.width),
          If(~dlab & bus.sel[0], then: [rxReady < Const(0)]),
        ];
      } else {
        readItems = [
          If(
            bus.addr[2],
            then: [datOutW < word1.zeroExtend(bus.dataOut.width)],
            orElse: [
              datOutW < word0.zeroExtend(bus.dataOut.width),
              If(~dlab & bus.sel[0], then: [rxReady < Const(0)]),
            ],
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
          txHolding < Const(0, width: 8),
          txHoldingFull < Const(0),
          rxData < Const(0, width: 8),
          rxReady < Const(0),
          rxSyncA < Const(1), // idle-high line
          rxSyncB < Const(1),
          rxBusy < Const(0),
          rxBits < Const(0, width: 4),
          rxBaud < Const(0, width: 16),
          rxShift < Const(0, width: 8),
          baudCount < Const(0, width: 16),
          ack < Const(0),
          errR < Const(0),
          datOutW < Const(0, width: bus.dataOut.width),
        ],
        orElse: [
          // Baud counter
          If(
            baudCount.eq(Const(0, width: 16)),
            then: [baudCount < (divisor - Const(1, width: 16))],
            orElse: [baudCount < (baudCount - Const(1, width: 16))],
          ),

          // TX engine
          If(
            txBusy & baudTick,
            then: [
              txShift < (txShift >> Const(1, width: 10)),
              txCount < (txCount + Const(1, width: 4)),
              If(
                txCount.eq(Const(9, width: 4)),
                then: [txBusy < Const(0), txCount < Const(0, width: 4)],
              ),
            ],
          ),

          // Load from holding register when TX idle. Reloading the baud
          // counter here phase-aligns the generator to the new frame:
          // without it the free-running counter truncates the start bit to
          // whatever remained of the current period, and receivers misframe
          // the first byte after an idle gap.
          If(
            ~txBusy & txHoldingFull,
            then: [
              txShift <
                  [Const(1, width: 1), txHolding, Const(0, width: 1)].swizzle(),
              txBusy < Const(1),
              txCount < Const(0, width: 4),
              txHoldingFull < Const(0),
              baudCount < (divisor - Const(1, width: 16)),
            ],
          ),

          // RX engine: hunt for a start bit on the synchronized line, then
          // sample mid-bit at the divisor rate (8N1, LSB first). The divisor
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
                  // Half a bit period, to land mid-start for validation.
                  rxBaud <
                      [Const(0, width: 1), divisor.getRange(1, 16)].swizzle(),
                ],
              ),
            ],
            orElse: [
              If(
                rxBaud.eq(Const(0, width: 16)),
                then: [
                  rxBaud < (divisor - Const(1, width: 16)),
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
                          rxShift < [rxSyncB, rxShift.getRange(1, 8)].swizzle(),
                          rxBits < (rxBits + Const(1, width: 4)),
                        ],
                        orElse: [
                          // Stop position: a high line frames a valid byte.
                          If(
                            rxSyncB,
                            then: [rxData < rxShift, rxReady < Const(1)],
                          ),
                          rxBusy < Const(0),
                        ],
                      ),
                    ],
                  ),
                ],
                orElse: [rxBaud < (rxBaud - Const(1, width: 16))],
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
            ],
          ),
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
  /// this is generated. The default assumes the firmware programs
  /// `<this peripheral's clock>` / 115200; override with
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
    hid: 'PNP0501',
    cid: ['PNP0501'],
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
