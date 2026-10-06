import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Register byte offsets, same map as i2c_test.dart.
const _ctrl = 0x00;
const _status = 0x08;
const _data = 0x10;
const _prescale = 0x20;
const _cmd = 0x28;

const _cmdStart = 0x01;
const _cmdStop = 0x02;
const _cmdWrite = 0x04;
const _cmdRead = 0x08;
const _cmdNack = 0x10;

const _stAck = 0x02;

/// Behavioral I2C slave: a 128-byte EEPROM/EDID-style ROM at [address7].
///
/// ACKs its own address, then on a read sends [pattern] sequentially
/// starting at offset 0, advancing a byte on every master ACK and stopping
/// (releasing SDA) on a master NACK. Write support is limited to ACKing the
/// address. Data bytes are otherwise unused, since nothing in this suite
/// writes to the model.
///
/// Models an open-drain line: [sclOe]/[sdaOe] ask to drive low, released
/// means the external pull-up (modeled by the test) reads high.
class I2cEepromModel extends Module {
  final List<int> pattern;
  final int address7;

  Logic get sclOe => output('scl_oe');
  Logic get sdaOe => output('sda_oe');

  I2cEepromModel({
    required Logic clk,
    required Logic reset,
    required Logic sclLine,
    required Logic sdaLine,
    required this.pattern,
    this.address7 = 0x50,
    Logic? stretchEnable,
    super.name = 'i2c_eeprom_model',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    sclLine = addInput('scl_line', sclLine);
    sdaLine = addInput('sda_line', sdaLine);
    final stretch = addInput('stretch_enable', stretchEnable ?? Const(0));
    addOutput('scl_oe');
    addOutput('sda_oe');
    final sclOeReg = Logic(name: 'scl_oe_reg');
    final sdaOeReg = Logic(name: 'sda_oe_reg');
    output('scl_oe') <= sclOeReg;
    output('sda_oe') <= sdaOeReg;

    const sIdle = 0;
    const sAddrBits = 1;
    const sAddrAck = 2;
    const sTxData = 3;
    const sTxAckWait = 4;
    const sNotMe = 5;

    final prevScl = Logic(name: 'prev_scl');
    final prevSda = Logic(name: 'prev_sda');
    final state = Logic(name: 'state', width: 3);
    final bitCnt = Logic(name: 'bit_cnt', width: 4);
    final shiftReg = Logic(name: 'shift_reg', width: 8);
    final ptr = Logic(name: 'ptr', width: 7);
    final matchReg = Logic(name: 'match_reg');
    final rwBitReg = Logic(name: 'rw_bit_reg');
    final ackBitReg = Logic(name: 'ack_bit_reg');
    final stretchActive = Logic(name: 'stretch_active');
    final stretchedUsed = Logic(name: 'stretched_used');
    final stretchCounter = Logic(name: 'stretch_counter', width: 8);

    // Byte ROM lookup: pattern[p], as a pure combinational read.
    Logic byteAt(Logic p) => cases(p, {
      for (var i = 0; i < pattern.length; i++)
        Const(i, width: 7): Const(pattern[i] & 0xFF, width: 8),
    }, defaultValue: Const(0, width: 8));

    // MSB-first bit select: bit (7 - idx) of byte8.
    Logic bitAt(Logic byte8, Logic idx) => cases(idx, {
      for (var i = 0; i < 8; i++) Const(i, width: 3): byte8[7 - i],
    }, defaultValue: Const(0));

    final byteAtPtr = byteAt(ptr);
    final nextPtr = ptr + Const(1, width: 7);
    final nextByte = byteAt(nextPtr);

    Sequential(clk, [
      If(
        reset,
        then: [
          prevScl < Const(1),
          prevSda < Const(1),
          state < Const(sIdle, width: 3),
          bitCnt < Const(0, width: 4),
          shiftReg < Const(0, width: 8),
          ptr < Const(0, width: 7),
          matchReg < Const(0),
          rwBitReg < Const(0),
          ackBitReg < Const(0),
          stretchActive < Const(0),
          stretchedUsed < Const(0),
          stretchCounter < Const(0, width: 8),
          sclOeReg < Const(0),
          sdaOeReg < Const(0),
        ],
        orElse: [
          prevScl < sclLine,
          prevSda < sdaLine,

          If(
            sclLine & prevScl & prevSda & ~sdaLine,
            then: [
              // START, or repeated START mid-transaction.
              state < Const(sAddrBits, width: 3),
              bitCnt < Const(0, width: 4),
              shiftReg < Const(0, width: 8),
              ptr < Const(0, width: 7),
              stretchActive < Const(0),
              stretchedUsed < Const(0),
              sdaOeReg < Const(0),
              sclOeReg < Const(0),
            ],
            orElse: [
              If(
                sclLine & prevScl & ~prevSda & sdaLine,
                then: [
                  // STOP.
                  state < Const(sIdle, width: 3),
                  sdaOeReg < Const(0),
                  sclOeReg < Const(0),
                ],
                orElse: [
                  Case(state, [
                    CaseItem(Const(sIdle, width: 3), []),

                    // Shift in the 7-bit address and the R/W bit, MSB first.
                    CaseItem(Const(sAddrBits, width: 3), [
                      If(
                        ~prevScl & sclLine,
                        then: [
                          shiftReg <
                              (shiftReg << Const(1, width: 8)) |
                                  sdaLine.zeroExtend(8),
                          bitCnt < (bitCnt + Const(1, width: 4)),
                        ],
                      ),
                      If(
                        prevScl & ~sclLine & bitCnt.eq(Const(8, width: 4)),
                        then: [
                          state < Const(sAddrAck, width: 3),
                          bitCnt < Const(0, width: 4),
                          matchReg <
                              shiftReg
                                  .getRange(1, 8)
                                  .eq(Const(address7, width: 7)),
                          rwBitReg < shiftReg[0],
                          sdaOeReg <
                              shiftReg
                                  .getRange(1, 8)
                                  .eq(Const(address7, width: 7)),
                          If(
                            stretch &
                                shiftReg
                                    .getRange(1, 8)
                                    .eq(Const(address7, width: 7)) &
                                ~stretchedUsed,
                            then: [
                              sclOeReg < Const(1),
                              stretchActive < Const(1),
                              stretchedUsed < Const(1),
                              stretchCounter < Const(40, width: 8),
                            ],
                          ),
                        ],
                      ),
                    ]),

                    // ACK the address. A one-shot clock stretch (test hook)
                    // holds SCL low here past when the master releases it.
                    CaseItem(Const(sAddrAck, width: 3), [
                      If(
                        stretchActive,
                        then: [
                          If(
                            stretchCounter.eq(Const(0, width: 8)),
                            then: [
                              stretchActive < Const(0),
                              sclOeReg < Const(0),
                            ],
                            orElse: [
                              stretchCounter <
                                  (stretchCounter - Const(1, width: 8)),
                            ],
                          ),
                        ],
                      ),
                      If(
                        prevScl & ~sclLine,
                        then: [
                          If(
                            matchReg & rwBitReg,
                            then: [
                              state < Const(sTxData, width: 3),
                              bitCnt < Const(1, width: 4),
                              sdaOeReg < ~byteAtPtr[7],
                            ],
                            orElse: [
                              state < Const(sNotMe, width: 3),
                              sdaOeReg < Const(0),
                              sclOeReg < Const(0),
                            ],
                          ),
                        ],
                      ),
                    ]),

                    // Send one byte, MSB first, changing SDA only while
                    // SCL is low.
                    CaseItem(Const(sTxData, width: 3), [
                      If(
                        prevScl & ~sclLine,
                        then: [
                          If(
                            bitCnt.eq(Const(8, width: 4)),
                            then: [
                              state < Const(sTxAckWait, width: 3),
                              sdaOeReg < Const(0),
                            ],
                            orElse: [
                              sdaOeReg <
                                  ~bitAt(byteAtPtr, bitCnt.getRange(0, 3)),
                              bitCnt < (bitCnt + Const(1, width: 4)),
                            ],
                          ),
                        ],
                      ),
                    ]),

                    // Release SDA and read the master's ACK/NACK.
                    CaseItem(Const(sTxAckWait, width: 3), [
                      If(~prevScl & sclLine, then: [ackBitReg < sdaLine]),
                      If(
                        prevScl & ~sclLine,
                        then: [
                          If(
                            ~ackBitReg,
                            then: [
                              ptr < nextPtr,
                              bitCnt < Const(1, width: 4),
                              sdaOeReg < ~nextByte[7],
                              state < Const(sTxData, width: 3),
                            ],
                            orElse: [
                              sdaOeReg < Const(0),
                              sclOeReg < Const(0),
                              state < Const(sNotMe, width: 3),
                            ],
                          ),
                        ],
                      ),
                    ]),

                    CaseItem(Const(sNotMe, width: 3), []),
                  ]),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);
  }
}

/// Minimal Wishbone bus driver plus a shared open-drain I2C bus, wiring
/// [HarborI2cController] against [I2cEepromModel] the way two real chips on
/// the same bus would be wired: both drive sda_oe/scl_oe, wired-and.
class _I2cHarness {
  late final Logic clk;
  late final Logic reset;
  late final Logic stb;
  late final Logic we;
  late final Logic adr;
  late final Logic mosi;
  late final Logic sclLine;
  late final Logic sdaLine;
  late final HarborI2cController i2c;
  late final I2cEepromModel slave;

  Future<void> init({
    required List<int> pattern,
    bool stretch = false,
    int prescale = 4,
  }) async {
    i2c = HarborI2cController(baseAddress: 0x6000);

    clk = SimpleClockGenerator(10).clk;
    reset = Logic(name: 'reset');
    stb = Logic(name: 'stb');
    we = Logic(name: 'we');
    adr = Logic(name: 'adr', width: 8);
    mosi = Logic(name: 'mosi', width: 32);
    sclLine = Logic(name: 'scl_line');
    sdaLine = Logic(name: 'sda_line');

    i2c.input('clk').srcConnection! <= clk;
    i2c.input('reset').srcConnection! <= reset;
    i2c.input('bus_CYC').srcConnection! <= stb;
    i2c.input('bus_STB').srcConnection! <= stb;
    i2c.input('bus_WE').srcConnection! <= we;
    i2c.input('bus_ADR').srcConnection! <= adr;
    i2c.input('bus_DAT_MOSI').srcConnection! <= mosi;
    i2c.input('bus_SEL').srcConnection! <=
        Const(-1, width: i2c.input('bus_SEL').width);
    i2c.input('scl_in').srcConnection! <= sclLine;
    i2c.input('sda_in').srcConnection! <= sdaLine;

    await i2c.build();

    slave = I2cEepromModel(
      clk: clk,
      reset: reset,
      sclLine: sclLine,
      sdaLine: sdaLine,
      pattern: pattern,
      stretchEnable: Const(stretch ? 1 : 0),
    );
    await slave.build();

    // Open-drain wired-and: the line reads low if either side drives it
    // low, otherwise an (implicit) pull-up holds it high.
    sclLine <= ~(i2c.output('scl_oe') | slave.sclOe);
    sdaLine <= ~(i2c.output('sda_oe') | slave.sdaOe);

    reset.inject(1);
    stb.inject(0);
    we.inject(0);
    adr.inject(0);
    mosi.inject(0);
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    await busWrite(_prescale, prescale);
    await busWrite(_ctrl, 0x1); // enable
  }

  Future<void> busWrite(int addr, int data) async {
    adr.inject(addr);
    mosi.inject(data);
    we.inject(1);
    stb.inject(1);
    await clk.nextPosedge;
    while (i2c.output('bus_ACK').value.toInt() != 1) {
      await clk.nextPosedge;
    }
    stb.inject(0);
    we.inject(0);
    await clk.nextPosedge;
  }

  Future<int> busRead(int addr) async {
    adr.inject(addr);
    we.inject(0);
    stb.inject(1);
    await clk.nextPosedge;
    while (i2c.output('bus_ACK').value.toInt() != 1) {
      await clk.nextPosedge;
    }
    final v = i2c.output('bus_DAT_MISO').value.toInt();
    stb.inject(0);
    await clk.nextPosedge;
    return v;
  }

  /// Issues a CMD and waits for cmd_done, returning the STATUS value seen
  /// (cmd_done still set) and the simulated time (in Simulator.time units)
  /// the whole call took, start to finish.
  Future<({int status, int elapsed})> issueCmd(int cmd) async {
    final t0 = Simulator.time;
    await busWrite(_cmd, cmd);
    var polls = 0;
    int status;
    while (true) {
      status = await busRead(_status);
      polls++;
      if (status & 0x20 != 0) break;
      if (polls > 100000) {
        fail('CMD 0x${cmd.toRadixString(16)} never completed (cmd_done)');
      }
    }
    await busWrite(_status, 0x20); // clear cmd_done
    return (status: status, elapsed: Simulator.time - t0);
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('I2C EDID read against a behavioral EEPROM slave', () {
    test(
      'reads all 128 bytes in one transaction, NACKs the last, then STOPs',
      () async {
        final pattern = List<int>.generate(128, (i) => (i * 7 + 3) & 0xFF);
        final h = _I2cHarness();
        await h.init(pattern: pattern);

        // Address phase: 0x50 << 1 | 1 (read).
        await h.busWrite(_data, 0xA1);
        final addrResult = await h.issueCmd(_cmdStart | _cmdWrite);
        expect(
          addrResult.status & _stAck,
          equals(_stAck),
          reason: 'slave should ACK its own address',
        );

        final received = <int>[];
        for (var i = 0; i < 128; i++) {
          final last = i == 127;
          final cmd = _cmdRead | (last ? _cmdNack : 0);
          await h.issueCmd(cmd);
          received.add(await h.busRead(_data));
        }

        await h.issueCmd(_cmdStop);

        expect(received, equals(pattern));
        expect(
          h.sclLine.value.toInt(),
          equals(1),
          reason: 'SCL must be released after STOP',
        );
        expect(
          h.sdaLine.value.toInt(),
          equals(1),
          reason: 'SDA must be released after STOP',
        );

        await Simulator.endSimulation();
      },
    );

    test('ack_received reflects a real address NACK', () async {
      final pattern = List<int>.generate(128, (i) => i & 0xFF);
      final h = _I2cHarness();
      await h.init(pattern: pattern);

      // Address 0x55 (not the EEPROM's 0x50): no slave answers.
      await h.busWrite(_data, 0xAB);
      final result = await h.issueCmd(_cmdStart | _cmdWrite);

      expect(
        result.status & _stAck,
        equals(0),
        reason: 'nothing on the bus should ACK a mismatched address',
      );

      await h.issueCmd(_cmdStop);
      await Simulator.endSimulation();
    });

    test('waits for the slave to release a stretched SCL', () async {
      final pattern = List<int>.generate(128, (i) => i & 0xFF);

      final baseline = _I2cHarness();
      await baseline.init(pattern: pattern, stretch: false);
      await baseline.busWrite(_data, 0xA1);
      final baseResult = await baseline.issueCmd(_cmdStart | _cmdWrite);
      expect(baseResult.status & _stAck, equals(_stAck));

      final stretched = _I2cHarness();
      await stretched.init(pattern: pattern, stretch: true);
      await stretched.busWrite(_data, 0xA1);
      final stretchResult = await stretched.issueCmd(_cmdStart | _cmdWrite);

      // The transaction still succeeds...
      expect(stretchResult.status & _stAck, equals(_stAck));
      // ...but only after waiting out the slave's 40-cycle hold on SCL,
      // not by racing ahead or timing out. The measured delta (320 time
      // units) is short of the full 400 (40 cycles at this 10-unit clock
      // period): the master's own quarter-2 wait would have spent some
      // of that time anyway, even unstretched. A narrow band around the
      // measured value still proves the wait is real and roughly the
      // right size, tighter than a bare "it waited at all" check.
      final delta = stretchResult.elapsed - baseResult.elapsed;
      expect(
        delta,
        inInclusiveRange(280, 360),
        reason:
            'the master must wait out the slave\'s SCL hold, '
            'neither skipping it nor stalling on something else',
      );

      await Simulator.endSimulation();
    });
  });
}
