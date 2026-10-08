import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

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
/// Register map (standard 16550):
/// - 0x0: RBR (read) / THR (write) / DLL (DLAB=1)
/// - 0x1: IER (DLAB=0) / DLM (DLAB=1)
/// - 0x2: IIR (read) / FCR (write)
/// - 0x3: LCR (bit 7 = DLAB)
/// - 0x4: MCR
/// - 0x5: LSR (read-only)
/// - 0x6: MSR (read-only)
/// - 0x7: SCR
///
/// Address space: 8 bytes (mapped to 0x1000 page for SoC).
///
/// On a multi-byte bus the registers stay byte-mapped within words: writes
/// pick their register through the byte-lane selects, and reads return the
/// whole addressed word with every register in its lane, so masters that
/// issue word-aligned loads extract the byte they want.
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

  /// TX serial output.
  Logic get tx => output('tx');

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  /// Bus slave port.
  late final BusSlavePort bus;

  HarborUart({
    required this.baseAddress,
    this.clockFrequency = 0,
    int? busAddressWidth,
    this.busDataWidth,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborUart', name: name ?? 'uart') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('rx', PortDirection.input);
    addOutput('tx');
    addOutput('interrupt');

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      // The full 0x1000 window, so no address in it aliases a register.
      addressWidth: busAddressWidth ?? 12,
      dataWidth: busDataWidth ?? 8,
    );

    final clk = input('clk');
    final reset = input('reset');
    // The bus carries word-aligned addresses with the byte position encoded
    // in the SEL lanes (ns16550a registers are byte-mapped). Writes decode
    // the active lane back into a register index and take their data from
    // that lane. Reads return the whole addressed word with every byte
    // register in its lane, and the master extracts the byte it asked for.
    final lanes = bus.dataIn.width ~/ 8;
    final Logic addr;
    final Logic datIn;
    if (lanes == 1) {
      // Byte-wide bus: addresses are already byte-granular.
      addr = bus.addr.getRange(0, 3);
      datIn = bus.dataIn.getRange(0, 8);
    } else {
      final laneBits = (lanes - 1).bitLength;
      final wrLane = Logic(name: 'uart_wr_lane', width: laneBits);
      Combinational([
        wrLane < Const(0, width: laneBits),
        for (var i = 1; i < lanes; i++)
          If(bus.sel[i], then: [wrLane < Const(i, width: laneBits)]),
      ]);
      // Write register index 0..7: the lane within the addressed word, plus
      // the word-select address bit on a 32-bit bus (a 64-bit bus spans all
      // 8 registers in one word).
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
    // The registers span 8 bytes. An address above them matches nothing, so
    // it reads 0 and ignores writes instead of aliasing a register.
    final inWindow = bus.addr.width > 3
        ? bus.addr.getRange(3).eq(0).named('uart_in_window')
        : Const(1);
    final datOutW = Logic(name: 'uart_dat_out', width: bus.dataOut.width);
    bus.dataOut <= datOutW;
    final ack = bus.ack;
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

    // Read mux. On a multi-byte bus every byte register of the addressed word
    // is returned in its lane and the master extracts the byte it wants. On a
    // byte-wide bus each register is returned individually. Reading the word
    // holding the RBR pops the receive buffer, and with word-grouped reads
    // that also fires for IIR/LCR reads of the same word, an accepted quirk
    // of byte registers on a word bus (LSR polling, in the other word, is
    // unaffected).
    final List<Conditional> readItems;
    if (lanes == 1) {
      readItems = [
        Case(addr, [
          CaseItem(Const(0, width: 3), [
            If(
              dlab,
              then: [datOutW < dll],
              orElse: [datOutW < rxData, rxReady < Const(0)],
            ),
          ]),
          CaseItem(Const(1, width: 3), [
            If(dlab, then: [datOutW < dlm], orElse: [datOutW < ier]),
          ]),
          CaseItem(Const(2, width: 3), [datOutW < computedIir]),
          CaseItem(Const(3, width: 3), [datOutW < lcr]),
          CaseItem(Const(4, width: 3), [datOutW < mcr]),
          CaseItem(Const(5, width: 3), [datOutW < lsr]),
          CaseItem(Const(6, width: 3), [datOutW < Const(0, width: 8)]),
          CaseItem(Const(7, width: 3), [datOutW < scr]),
        ]),
      ];
    } else {
      final word0 = [
        lcr,
        computedIir,
        mux(dlab, dlm, ier),
        mux(dlab, dll, rxData),
      ].swizzle();
      final word1 = [scr, Const(0, width: 8), lsr, mcr].swizzle();
      if (lanes >= 8) {
        readItems = [
          datOutW < [word1, word0].swizzle().zeroExtend(bus.dataOut.width),
          If(~dlab, then: [rxReady < Const(0)]),
        ];
      } else {
        readItems = [
          If(
            bus.addr[2],
            then: [datOutW < word1.zeroExtend(bus.dataOut.width)],
            orElse: [
              datOutW < word0.zeroExtend(bus.dataOut.width),
              If(~dlab, then: [rxReady < Const(0)]),
            ],
          ),
        ];
      }
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
          datOutW < Const(0, width: bus.dataOut.width),

          If(
            stb & ~ack,
            then: [
              ack < Const(1),

              If(
                inWindow & we,
                then: [
                  Case(addr, [
                    // 0x0: THR/DLL
                    CaseItem(Const(0, width: 3), [
                      If(
                        dlab,
                        then: [dll < datIn],
                        orElse: [txHolding < datIn, txHoldingFull < Const(1)],
                      ),
                    ]),
                    // 0x1: IER/DLM
                    CaseItem(Const(1, width: 3), [
                      If(dlab, then: [dlm < datIn], orElse: [ier < datIn]),
                    ]),
                    // 0x2: FCR
                    CaseItem(Const(2, width: 3), [fcr < datIn]),
                    // 0x3: LCR
                    CaseItem(Const(3, width: 3), [lcr < datIn]),
                    // 0x4: MCR
                    CaseItem(Const(4, width: 3), [mcr < datIn]),
                    // 0x5 LSR and 0x6 MSR are read-only.
                    // 0x7: SCR
                    CaseItem(Const(7, width: 3), [scr < datIn]),
                  ]),
                ],
                orElse: [If(inWindow, then: readItems)],
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
      'reg-shift': 0,
      'reg-io-width': 1,
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
      'reg-shift': 0,
      'reg-io-width': 1,
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
    registers: StandardRegisters.uart16550,
  );
}
