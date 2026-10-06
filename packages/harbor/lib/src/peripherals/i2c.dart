import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';

/// I2C master controller (slave mode is not implemented: ADDR is reserved
/// for it and otherwise unused).
///
/// Register map (each register in its own 64-bit-aligned slot, so a 32-bit
/// access lands in the low word on both a 32-bit and a 64-bit fabric, and the
/// byte-address decode needs no high/low-half selection):
/// - 0x00: CTRL     (bit 0 enable, bit 1 interrupt enable)
/// - 0x08: STATUS   (bit 0 busy, bit 1 ack_received, bit 2 arb_lost,
///   bit 4 rx_ready, bit 5 cmd_done, bit 6 cmd_rejected. Write any value
///   to clear cmd_done and cmd_rejected. cmd_rejected is set when CMD is
///   written while busy or while CTRL enable is 0, and that write is ignored.
///   ack_received is the 9th-bit ACK of the last byte sent, address byte
///   included, so a driver checks it right after a START|WRITE to tell an
///   address NACK from a real slave.
/// - 0x10: DATA     (write loads the TX byte, read returns the last RX byte)
/// - 0x18: ADDR     (reserved for slave mode, not used by the master)
/// - 0x20: PRESCALE (SCL timing. In input clock cycles, SCL low is
///   2 * (PRESCALE + 1) and SCL high is that plus 3, before any stretch.)
/// - 0x28: CMD      (write-only, write 1 to trigger). CMD bits are a
///   sequence run as one command, not independent triggers: START (or a
///   repeated START if a transaction is already open) runs first, then the
///   WRITE or READ byte, then STOP once the byte's ACK/NACK bit is done.
///   busy stays set for the whole sequence. A single-bit write (WRITE
///   alone, READ alone, STOP alone) still works the same, continuing a
///   transaction a previous command left open:
///   - bit 0: START
///   - bit 1: STOP
///   - bit 2: WRITE, send the byte in DATA
///   - bit 3: READ, receive a byte into DATA
///   - bit 4: NACK, read only. 0 sends ACK after the byte, 1 sends NACK
///
/// Supports standard (100 kHz), fast (400 kHz), and fast-plus (1 MHz).
class HarborI2cController extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider,
        HarborInputClockConsumer {
  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Controller input clock in Hz (the system clock the PRESCALE register
  /// divides). Emitted as `harbor,input-clock-hz`, NOT `clock-frequency`: on an
  /// I2C node the standard binding gives `clock-frequency` the SCL bus rate, so
  /// overloading it would make a driver clock the bus at the system rate.
  /// 0 leaves the property out.
  int clockFrequency;

  /// Wishbone slave address width. Defaults to 8 (256-byte register window).
  final int busAddressWidth;

  /// Wishbone slave data width. Must match the SoC fabric (e.g. 64 on an RV64
  /// SoC). The register file itself is 32-bit; wider buses zero-extend reads.
  final int busDataWidth;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  HarborI2cController({
    required this.baseAddress,
    this.clockFrequency = 0,
    this.busAddressWidth = 8,
    this.busDataWidth = 32,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborI2cController', name: name ?? 'i2c') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // I2C pins (directly exposed, directly active or active-low variants)
    createPort('scl_in', PortDirection.input);
    addOutput('scl_out');
    addOutput('scl_oe'); // output enable (active high)
    createPort('sda_in', PortDirection.input);
    addOutput('sda_out');
    addOutput('sda_oe');
    addOutput('interrupt');

    // Bus read-data width. The register file is 32-bit; a wider fabric sees the
    // registers zero-extended into the low word.
    final dw = busDataWidth;

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      addressWidth: busAddressWidth,
      dataWidth: dw,
    );

    final clk = input('clk');
    final reset = input('reset');
    final sclOut = output('scl_out');
    final sclOe = output('scl_oe');
    final sdaOut = output('sda_out');
    final sdaOe = output('sda_oe');
    // Raw pad inputs. Asynchronous relative to clk (the RTC and the
    // monitor can both change the shared bus on their own clock), so
    // nothing but the synchronizer below reads these directly.
    final sclIn = input('scl_in');
    final sdaIn = input('sda_in');

    // Registers
    final enable = Logic(name: 'enable');
    final irqEn = Logic(name: 'irq_en');
    final prescale = Logic(name: 'prescale', width: 16);
    final txData = Logic(name: 'tx_data', width: 8);
    final rxData = Logic(name: 'rx_data', width: 8);
    final slaveAddr = Logic(name: 'slave_addr', width: 7);
    final shiftReg = Logic(name: 'shift_reg', width: 8);
    final bitCount = Logic(name: 'bit_count', width: 4);
    final divCount = Logic(name: 'div_count', width: 16);

    // Status
    final busy = Logic(name: 'busy');
    final ackReceived = Logic(name: 'ack_received');
    final arbLost = Logic(name: 'arb_lost');
    final rxReady = Logic(name: 'rx_ready');
    final cmdDone = Logic(name: 'cmd_done');

    // I2C state. i2cState picks the condition the engine is generating.
    // subPhase walks its four quarter-bit steps (set up SDA, release SCL
    // and wait for it to read high, sample, drive SCL low again).
    final i2cState = Logic(name: 'i2c_state', width: 4);
    final subPhase = Logic(name: 'sub_phase', width: 2);

    // Direction and per-byte options latched by the CMD write that starts
    // or continues the current byte, held for the whole byte.
    final readDir = Logic(name: 'read_dir');
    final nackBit = Logic(name: 'nack_bit');
    final stopPending = Logic(name: 'stop_pending');

    // Registered line drive. open-drain: asserted means drive SDA/SCL low,
    // deasserted means release it (an external pull-up reads it high).
    final sclOeReg = Logic(name: 'scl_oe_reg');
    final sdaOeReg = Logic(name: 'sda_oe_reg');

    // 2-flop synchronizers on the async pad inputs. sclInSync/sdaInSync,
    // not the raw pads, are what the bit engine reads everywhere below.
    final sclSync0 = Logic(name: 'scl_sync0');
    final sclInSync = Logic(name: 'scl_in_sync');
    final sdaSync0 = Logic(name: 'sda_sync0');
    final sdaInSync = Logic(name: 'sda_in_sync');

    // A CMD write while busy, or before enable, is rejected rather than
    // disturbing an in-flight sequence or sticking busy forever.
    final cmdRejected = Logic(name: 'cmd_rejected');

    const stIdle = 0;
    const stStart = 1;
    const stData = 2;
    const stAck = 3;
    const stStop = 4;

    sclOut <= Const(0);
    sdaOut <= Const(0);
    sclOe <= sclOeReg;
    sdaOe <= sdaOeReg;

    interrupt <= irqEn & cmdDone;

    // Runs on a quarter-bit tick (every PRESCALE cycles), running [actions]
    // and reloading the divider.
    Conditional onTick(List<Conditional> actions) => If(
      divCount.eq(Const(0, width: 16)),
      then: [...actions, divCount < prescale],
      orElse: [divCount < (divCount - Const(1, width: 16))],
    );

    // First of a bit's two low quarters: drives SCL low every cycle (so
    // it takes effect at once, even if the previous bit left SCL
    // released) and applies [setup] (the next bit's SDA value) every
    // cycle too. Low lasts this quarter plus the next, 2 x PRESCALE
    // cycles, with no dependence on the bus.
    List<Conditional> lowQuarter(List<Conditional> setup, int next) => [
      sclOeReg < Const(1),
      ...setup,
      If(
        divCount.eq(Const(0, width: 16)),
        then: [subPhase < Const(next, width: 2), divCount < prescale],
        orElse: [divCount < (divCount - Const(1, width: 16))],
      ),
    ];

    // Releases SCL and waits for it to read high before moving to
    // [next]. A slave holding SCL low (clock stretching) pins subPhase
    // here: the divider does not advance until sclInSync reads 1, so the
    // wait can take any number of cycles beyond the synchronizer's fixed
    // 2-cycle latency.
    List<Conditional> waitSclHigh(int next) => [
      sclOeReg < Const(0),
      If(
        sclInSync,
        then: [
          If(
            divCount.eq(Const(0, width: 16)),
            then: [subPhase < Const(next, width: 2), divCount < prescale],
            orElse: [divCount < (divCount - Const(1, width: 16))],
          ),
        ],
        orElse: [divCount < prescale],
      ),
    ];

    final status =
        busy.zeroExtend(dw) |
        (ackReceived.zeroExtend(dw) << Const(1, width: dw)) |
        (arbLost.zeroExtend(dw) << Const(2, width: dw)) |
        (rxReady.zeroExtend(dw) << Const(4, width: dw)) |
        (cmdDone.zeroExtend(dw) << Const(5, width: dw)) |
        (cmdRejected.zeroExtend(dw) << Const(6, width: dw));

    Sequential(clk, [
      If(
        reset,
        then: [
          enable < Const(0),
          irqEn < Const(0),
          // Default ~104 kHz at a 10 MHz input clock: PRESCALE = 24 per
          // the class doc formula (SCL period = 4 x PRESCALE cycles).
          prescale < Const(24, width: 16),
          txData < Const(0, width: 8),
          rxData < Const(0, width: 8),
          slaveAddr < Const(0, width: 7),
          shiftReg < Const(0xFF, width: 8),
          bitCount < Const(0, width: 4),
          divCount < Const(0, width: 16),
          busy < Const(0),
          ackReceived < Const(0),
          arbLost < Const(0),
          rxReady < Const(0),
          cmdDone < Const(0),
          cmdRejected < Const(0),
          i2cState < Const(stIdle, width: 4),
          subPhase < Const(0, width: 2),
          readDir < Const(0),
          nackBit < Const(0),
          stopPending < Const(0),
          sclOeReg < Const(0),
          sdaOeReg < Const(0),
          sclSync0 < Const(1),
          sclInSync < Const(1),
          sdaSync0 < Const(1),
          sdaInSync < Const(1),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: dw),
        ],
        orElse: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: dw),

          // 2-flop synchronizer on the async pad inputs, sampled every
          // cycle regardless of state. sclInSync/sdaInSync lag the pads
          // by exactly 2 clk cycles.
          sclSync0 < sclIn,
          sclInSync < sclSync0,
          sdaSync0 < sdaIn,
          sdaInSync < sdaSync0,

          // I2C bit engine: steps the current START/STOP condition or data
          // byte one quarter-bit at a time. A CMD write (below) picks the
          // state and loads shiftReg/readDir/nackBit/stopPending for it.
          If(
            busy & enable,
            then: [
              Case(i2cState, [
                CaseItem(Const(stIdle, width: 4), []),

                // Drive (or repeated-drive) a START condition: release SDA
                // and SCL, wait for SCL to read high, pull SDA low while
                // SCL is high (the START edge), then drive SCL low to
                // begin the first bit. Works for an initial START (SCL and
                // SDA already released) and a repeated START (SCL was held
                // low by the previous byte's ACK) alike.
                CaseItem(Const(stStart, width: 4), [
                  Case(subPhase, [
                    CaseItem(Const(0, width: 2), [
                      onTick([
                        sdaOeReg < Const(0),
                        sclOeReg < Const(0),
                        subPhase < Const(1, width: 2),
                      ]),
                    ]),
                    CaseItem(Const(1, width: 2), waitSclHigh(2)),
                    CaseItem(Const(2, width: 2), [
                      onTick([
                        sdaOeReg < Const(1),
                        subPhase < Const(3, width: 2),
                      ]),
                    ]),
                    CaseItem(Const(3, width: 2), [
                      onTick([
                        sclOeReg < Const(1),
                        i2cState < Const(stData, width: 4),
                        subPhase < Const(0, width: 2),
                      ]),
                    ]),
                  ]),
                ]),

                // Shift one data byte, MSB first, as 4 quarter-bit steps:
                // two low (SDA changes only here, 2 x PRESCALE cycles of
                // low with no dependence on the bus), then release SCL
                // and wait for it to read high (where a slave stretching
                // the clock holds the master off), then a further
                // PRESCALE cycles of high before sampling. SCL period
                // works out to 4 x PRESCALE cycles, low = high = 2 x
                // PRESCALE, outside of a stretch. See the class doc.
                CaseItem(Const(stData, width: 4), [
                  Case(subPhase, [
                    CaseItem(
                      Const(0, width: 2),
                      lowQuarter([
                        If(
                          readDir,
                          then: [sdaOeReg < Const(0)],
                          orElse: [sdaOeReg < ~shiftReg[7]],
                        ),
                      ], 1),
                    ),
                    CaseItem(Const(1, width: 2), [
                      onTick([subPhase < Const(2, width: 2)]),
                    ]),
                    CaseItem(Const(2, width: 2), waitSclHigh(3)),
                    CaseItem(Const(3, width: 2), [
                      onTick([
                        If(
                          readDir,
                          then: [
                            shiftReg <
                                (shiftReg << Const(1, width: 8)) |
                                    sdaInSync.zeroExtend(8),
                            bitCount < (bitCount + Const(1, width: 4)),
                            If(
                              bitCount.eq(Const(7, width: 4)),
                              then: [i2cState < Const(stAck, width: 4)],
                            ),
                            subPhase < Const(0, width: 2),
                          ],
                          // Arbitration loss: SDA was released expecting
                          // a 1 (another device, such as the RTC, may be
                          // driving the shared bus at the same time).
                          // Checked against the live sample, not a
                          // registered flag, so the abort below lands in
                          // the same cycle the mismatch is seen.
                          orElse: [
                            If(
                              shiftReg[7] & ~sdaInSync,
                              then: [
                                arbLost < Const(1),
                                busy < Const(0),
                                cmdDone < Const(1),
                                i2cState < Const(stIdle, width: 4),
                                sclOeReg < Const(0),
                                sdaOeReg < Const(0),
                              ],
                              orElse: [
                                shiftReg < (shiftReg << Const(1, width: 8)),
                                bitCount < (bitCount + Const(1, width: 4)),
                                If(
                                  bitCount.eq(Const(7, width: 4)),
                                  then: [i2cState < Const(stAck, width: 4)],
                                ),
                                subPhase < Const(0, width: 2),
                              ],
                            ),
                          ],
                        ),
                      ]),
                    ]),
                  ]),
                ]),

                // The 9th bit: the master either reads the slave's ACK
                // (after a WRITE) or drives its own ACK/NACK (after a
                // READ, per nackBit, latched from CMD bit 4). Same 4
                // quarter-bit shape as a data bit.
                CaseItem(Const(stAck, width: 4), [
                  Case(subPhase, [
                    CaseItem(
                      Const(0, width: 2),
                      lowQuarter([
                        If(
                          readDir,
                          then: [sdaOeReg < ~nackBit],
                          orElse: [sdaOeReg < Const(0)],
                        ),
                      ], 1),
                    ),
                    CaseItem(Const(1, width: 2), [
                      onTick([subPhase < Const(2, width: 2)]),
                    ]),
                    CaseItem(Const(2, width: 2), waitSclHigh(3)),
                    CaseItem(Const(3, width: 2), [
                      onTick([
                        If(~readDir, then: [ackReceived < ~sdaInSync]),
                        If(
                          readDir,
                          then: [rxData < shiftReg, rxReady < Const(1)],
                        ),
                        // Park SCL low between commands (not just at a
                        // STOP): leaves any later START/data/STOP driving
                        // SDA only after SCL is already low, never in
                        // the same cycle as releasing SCL.
                        sclOeReg < Const(1),
                        If(
                          stopPending,
                          then: [
                            i2cState < Const(stStop, width: 4),
                            subPhase < Const(0, width: 2),
                            stopPending < Const(0),
                          ],
                          orElse: [
                            busy < Const(0),
                            cmdDone < Const(1),
                            i2cState < Const(stIdle, width: 4),
                          ],
                        ),
                      ]),
                    ]),
                  ]),
                ]),

                // STOP: drive SDA low as a known starting point, release
                // SCL and wait for it high, then release SDA while SCL is
                // still high (the STOP edge). Both lines end up released,
                // so the bus reads idle.
                CaseItem(Const(stStop, width: 4), [
                  Case(subPhase, [
                    CaseItem(Const(0, width: 2), [
                      onTick([
                        sdaOeReg < Const(1),
                        sclOeReg < Const(1),
                        subPhase < Const(1, width: 2),
                      ]),
                    ]),
                    CaseItem(Const(1, width: 2), waitSclHigh(2)),
                    CaseItem(Const(2, width: 2), [
                      onTick([
                        sdaOeReg < Const(0),
                        subPhase < Const(3, width: 2),
                      ]),
                    ]),
                    CaseItem(Const(3, width: 2), [
                      onTick([
                        busy < Const(0),
                        cmdDone < Const(1),
                        i2cState < Const(stIdle, width: 4),
                        stopPending < Const(0),
                      ]),
                    ]),
                  ]),
                ]),
              ]),
            ],
          ),

          // Bus access
          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              // Byte-address decode: registers sit 8 bytes apart (see the map
              // above), so match the low 6 bits of the byte address directly.
              Case(bus.addr.getRange(0, 6), [
                // 0x00: CTRL
                CaseItem(Const(0x00, width: 6), [
                  If(
                    bus.we,
                    then: [enable < bus.dataIn[0], irqEn < bus.dataIn[1]],
                    orElse: [
                      bus.dataOut <
                          enable.zeroExtend(dw) |
                              (irqEn.zeroExtend(dw) << Const(1, width: dw)),
                    ],
                  ),
                ]),
                // 0x08: STATUS
                CaseItem(Const(0x08, width: 6), [
                  bus.dataOut < status,
                  // Any write clears both sticky bits (write-1-to-clear;
                  // the controller does not care what value is written).
                  If(
                    bus.we,
                    then: [cmdDone < Const(0), cmdRejected < Const(0)],
                  ),
                ]),
                // 0x10: DATA
                CaseItem(Const(0x10, width: 6), [
                  If(
                    bus.we,
                    then: [txData < bus.dataIn.getRange(0, 8)],
                    orElse: [
                      bus.dataOut < rxData.zeroExtend(dw),
                      rxReady < Const(0),
                    ],
                  ),
                ]),
                // 0x18: ADDR
                CaseItem(Const(0x18, width: 6), [
                  If(
                    bus.we,
                    then: [slaveAddr < bus.dataIn.getRange(0, 7)],
                    orElse: [bus.dataOut < slaveAddr.zeroExtend(dw)],
                  ),
                ]),
                // 0x20: PRESCALE
                CaseItem(Const(0x20, width: 6), [
                  If(
                    bus.we,
                    then: [prescale < bus.dataIn.getRange(0, 16)],
                    orElse: [bus.dataOut < prescale.zeroExtend(dw)],
                  ),
                ]),
                // 0x28: CMD (write-only: trigger I2C operations). Bits
                // combine in one write, for example START with WRITE to
                // send an address byte. See the class doc for the map.
                CaseItem(Const(0x28, width: 6), [
                  If(
                    bus.we,
                    then: [
                      // A write while a sequence is in flight, or before
                      // the controller is enabled, is ignored outright
                      // rather than tearing a byte apart mid-flight or
                      // sticking busy forever with enable still 0.
                      If(
                        busy | ~enable,
                        then: [cmdRejected < Const(1)],
                        orElse: [
                          If(
                            bus.dataIn[0],
                            then: [
                              // START (or repeated START if already open).
                              busy < Const(1),
                              arbLost < Const(0),
                              bitCount < Const(0, width: 4),
                              subPhase < Const(0, width: 2),
                              i2cState < Const(stStart, width: 4),
                              readDir < bus.dataIn[3],
                              nackBit < bus.dataIn[4],
                              stopPending < bus.dataIn[1],
                              If(
                                bus.dataIn[3],
                                then: [shiftReg < Const(0xFF, width: 8)],
                                orElse: [shiftReg < txData],
                              ),
                            ],
                            orElse: [
                              If(
                                bus.dataIn[3],
                                then: [
                                  // READ byte, continuing an open transaction.
                                  busy < Const(1),
                                  arbLost < Const(0),
                                  bitCount < Const(0, width: 4),
                                  subPhase < Const(0, width: 2),
                                  i2cState < Const(stData, width: 4),
                                  readDir < Const(1),
                                  nackBit < bus.dataIn[4],
                                  stopPending < bus.dataIn[1],
                                  shiftReg < Const(0xFF, width: 8),
                                ],
                                orElse: [
                                  If(
                                    bus.dataIn[2],
                                    then: [
                                      // WRITE byte, continuing an open
                                      // transaction.
                                      busy < Const(1),
                                      arbLost < Const(0),
                                      bitCount < Const(0, width: 4),
                                      subPhase < Const(0, width: 2),
                                      i2cState < Const(stData, width: 4),
                                      readDir < Const(0),
                                      shiftReg < txData,
                                      stopPending < bus.dataIn[1],
                                    ],
                                    orElse: [
                                      If(
                                        bus.dataIn[1],
                                        then: [
                                          // STOP alone, closing an open
                                          // transaction.
                                          busy < Const(1),
                                          subPhase < Const(0, width: 2),
                                          i2cState < Const(stStop, width: 4),
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
  int get inputClockHz => clockFrequency;

  @override
  void provideInputClockHz(int hz) {
    if (clockFrequency == 0) clockFrequency = hz;
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,i2c', 'opencores,i2c-ocores'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      '#address-cells': 1,
      '#size-cells': 0,
      if (clockFrequency > 0) 'harbor,input-clock-hz': clockFrequency,
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,i2c', 'opencores,i2c-ocores'],
      '#address-cells': 1,
      '#size-cells': 0,
      if (clockFrequency > 0) 'harbor,input-clock-hz': clockFrequency,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'I2C',
    groupName: 'I2C',
    description: 'I2C master/slave controller',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
