import 'dart:math' as math;

import 'package:rohd/rohd.dart';

/// The ADV7511 registers that the initializer writes, in order, as
/// (register, value).
///
/// The list is the one of the KC705 HDMI probe (`gen.pl`): the power and
/// fixed registers, 16 bit 4:2:2 input with separate syncs, the forced hot
/// plug, HDMI mode, and the 24 color space conversion registers from 0x18.
const adv7511RegisterTable = <(int, int)>[
  (0x41, 0x10),
  (0x98, 0x03),
  (0x9A, 0xE0),
  (0x9C, 0x30),
  (0x9D, 0x61),
  (0xA2, 0xA4),
  (0xA3, 0xA4),
  (0xE0, 0xD0),
  (0xF9, 0x00),
  (0xD6, 0xC0),
  (0x15, 0x01),
  (0x16, 0x38),
  (0x17, 0x00),
  (0x48, 0x08),
  (0x55, 0x00),
  (0x56, 0x18),
  (0xAF, 0x06),
  (0x40, 0x80),
  (0x4C, 0x00),
  (0xBA, 0x60),
  (0x18, 0xE7),
  (0x19, 0x34),
  (0x1A, 0x04),
  (0x1B, 0xAD),
  (0x1C, 0x00),
  (0x1D, 0x00),
  (0x1E, 0x1C),
  (0x1F, 0x1B),
  (0x20, 0x1D),
  (0x21, 0xDC),
  (0x22, 0x04),
  (0x23, 0xAD),
  (0x24, 0x1F),
  (0x25, 0x24),
  (0x26, 0x01),
  (0x27, 0x35),
  (0x28, 0x00),
  (0x29, 0x00),
  (0x2A, 0x04),
  (0x2B, 0xAD),
  (0x2C, 0x08),
  (0x2D, 0x7C),
  (0x2E, 0x1B),
  (0x2F, 0x77),
];

/// The registers that the initializer reads back, in order. The first four
/// make the status word. 0x3E holds the detected VIC and 0x3D the detected
/// timing data, and both go to the readback word as raw bytes.
const adv7511ReadRegisters = <int>[0x42, 0x9E, 0xF5, 0xF6, 0x3E, 0x3D];

/// Writes the PCA9548 channel select and the ADV7511 registers, and reads
/// the status back.
///
/// One pass is: write 0x20 to the PCA9548 at 0x74 (channel 5), write
/// [adv7511RegisterTable] to the ADV7511 at 0x39 in order, then read the
/// registers of [adv7511ReadRegisters]. A new pass starts [repeatCycles]
/// after the previous one ends, because the chip loses its registers when
/// the hot plug line goes low. The first pass starts [repeatCycles] after
/// the reset.
///
/// The bus is open drain: [sclOe] and [sdaOe] pull the line low, and a low
/// enable releases it. The module has no clock stretch support. [muxResetN]
/// is high all the time.
///
/// [status] bits: 0 hot plug detect (0x42 bit 6), 1 monitor sense (0x42
/// bit 5), 2 PLL locked (0x9E bit 4), 3 chip ID 0x7511 in 0xF5 and 0xF6,
/// 4 a byte got a NACK in the last pass, 5 a pass ended since the reset.
/// [passes] counts the finished passes, saturating at 255. [vic] and [timing]
/// are the last read of 0x3E and 0x3D.
class HarborAdv7511Initializer extends Module {
  static const muxAddress = 0x74;
  static const muxChannel5 = 0x20;
  static const chip = 0x39;

  static const statusHotPlug = 1 << 0;
  static const statusSense = 1 << 1;
  static const statusPllLocked = 1 << 2;
  static const statusChipId = 1 << 3;
  static const statusNack = 1 << 4;
  static const statusValid = 1 << 5;

  /// The ROM ops. Each has an op code and one data byte. A read op has
  /// the index of its register in [adv7511ReadRegisters] as data.
  static const opStart = 0;
  static const opWrite = 1;
  static const opRead = 2;
  static const opStop = 3;

  /// The op list of one pass.
  static List<(int, int)> get ops {
    final out = <(int, int)>[];
    void start() => out.add((opStart, 0));
    void write(int b) => out.add((opWrite, b));
    void stop() => out.add((opStop, 0));
    start();
    write(muxAddress << 1);
    write(muxChannel5);
    stop();
    for (final (r, v) in adv7511RegisterTable) {
      start();
      write(chip << 1);
      write(r);
      write(v);
      stop();
    }
    for (final (i, r) in adv7511ReadRegisters.indexed) {
      start();
      write(chip << 1);
      write(r);
      start();
      write((chip << 1) | 1);
      out.add((opRead, i));
      stop();
    }
    return out;
  }

  Logic get muxResetN => output('mux_reset_n');
  Logic get sclOe => output('scl_oe');
  Logic get sdaOe => output('sda_oe');
  Logic get status => output('status');
  Logic get passes => output('passes');

  /// Raw 0x3E, the detected VIC, from the last read.
  Logic get vic => output('vic');

  /// Raw 0x3D from the last read.
  Logic get timing => output('timing');

  final int clockFrequency;
  final int i2cFrequency;
  final int repeatCycles;

  HarborAdv7511Initializer({
    required Logic clk,
    required Logic reset,
    required Logic sclIn,
    required Logic sdaIn,
    required this.clockFrequency,
    this.i2cFrequency = 100000,
    int? repeatCycles,
    super.name = 'adv7511_initializer',
  }) : repeatCycles = repeatCycles ?? clockFrequency ~/ 10,
       super(
         definitionName:
             'HarborAdv7511Initializer_${clockFrequency}_${i2cFrequency}_'
             '${repeatCycles ?? clockFrequency ~/ 10}',
       ) {
    if (clockFrequency <= 0) {
      throw ArgumentError.value(clockFrequency, 'clockFrequency');
    }
    if (i2cFrequency <= 0 || i2cFrequency > 400000) {
      throw ArgumentError.value(
        i2cFrequency,
        'i2cFrequency',
        'must be between 1 and 400000 Hz',
      );
    }
    if (this.repeatCycles < 1) {
      throw ArgumentError.value(repeatCycles, 'repeatCycles');
    }
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    sclIn = addInput('scl_in', sclIn);
    sdaIn = addInput('sda_in', sdaIn);
    addOutput('mux_reset_n');
    addOutput('scl_oe');
    addOutput('sda_oe');
    addOutput('status', width: 8);
    addOutput('passes', width: 8);
    addOutput('vic', width: 8);
    addOutput('timing', width: 8);

    final quarter = math.max(2, clockFrequency ~/ (i2cFrequency * 4));
    final divW = math.max(1, (quarter - 1).bitLength);
    final waitW = math.max(1, this.repeatCycles.bitLength);
    final opList = ops;
    final pcW = (opList.length - 1).bitLength;

    muxResetN <= Const(1);

    final pc = Logic(name: 'pc', width: pcW);
    final running = Logic(name: 'running');
    final wait = Logic(name: 'wait_count', width: waitW);
    final div = Logic(name: 'div', width: divW);
    final q = Logic(name: 'q', width: 2);
    final bitn = Logic(name: 'bitn', width: 4);
    final rx = Logic(name: 'rx', width: 8);
    final regs = [
      for (var i = 0; i < adv7511ReadRegisters.length; i++)
        Logic(name: 'rd$i', width: 8),
    ];
    final nackNow = Logic(name: 'nack_now');
    final sclLow = Logic(name: 'scl_low');
    final sdaLow = Logic(name: 'sda_low');
    final sdaMeta = Logic(name: 'sda_meta');
    final sdaSync = Logic(name: 'sda_sync');
    final statusReg = Logic(name: 'status_reg', width: 8);
    final passReg = Logic(name: 'pass_reg', width: 8);

    final rom = Logic(name: 'rom', width: 10);
    Combinational([
      Case(
        pc,
        [
          for (final (i, (op, data)) in opList.indexed)
            CaseItem(Const(i, width: pcW), [
              rom < Const((op << 8) | data, width: 10),
            ]),
        ],
        defaultItem: [rom < Const(0x300, width: 10)],
      ),
    ]);
    final op = rom.getRange(8, 10);
    final data = rom.getRange(0, 8);

    final isStart = op.eq(opStart);
    final isWrite = op.eq(opWrite);
    final isRead = op.eq(opRead);
    final isStop = op.eq(opStop);
    final lastBit = isStart | isStop | bitn.eq(8);
    final tick = div.eq(0);
    final ack = bitn.eq(8);
    final lastOp = pc.eq(opList.length - 1);

    final statusNext = [
      Const(0, width: 2),
      Const(1),
      nackNow,
      regs[2].eq(0x75) & regs[3].eq(0x11),
      regs[1][4],
      regs[0][5],
      regs[0][6],
    ].concat();

    // The low bit of each write byte goes out last, so the shift is a
    // bit select on bitn.
    final txBit = mux(
      ack,
      Const(1),
      (data >> (Const(7, width: 4) - bitn).getRange(0, 3))[0],
    );

    Sequential(
      clk,
      reset: reset,
      resetValues: {
        pc: 0,
        running: 0,
        wait: this.repeatCycles,
        div: 0,
        q: 0,
        bitn: 0,
        rx: 0,
        for (final r in regs) r: 0,
        nackNow: 0,
        sclLow: 0,
        sdaLow: 0,
        sdaMeta: 1,
        sdaSync: 1,
        statusReg: 0,
        passReg: 0,
      },
      [
        sdaMeta < sdaIn,
        sdaSync < sdaMeta,
        If(
          ~running,
          then: [
            If(
              wait.eq(0),
              then: [
                running < 1,
                pc < 0,
                div < 0,
                q < 0,
                bitn < 0,
                nackNow < 0,
              ],
              orElse: [wait < wait - 1],
            ),
          ],
          orElse: [
            div < mux(tick, Const(quarter - 1, width: divW), div - 1),
            If(
              tick,
              then: [
                q < q + 1,
                // START: release SDA, release SCL, pull SDA, pull SCL.
                // STOP: pull SDA, release SCL, release SDA.
                If(
                  isStart,
                  then: [
                    Case(q, [
                      CaseItem(Const(0, width: 2), [sdaLow < 0]),
                      CaseItem(Const(1, width: 2), [sclLow < 0]),
                      CaseItem(Const(2, width: 2), [sdaLow < 1]),
                      CaseItem(Const(3, width: 2), [sclLow < 1]),
                    ]),
                  ],
                  orElse: [
                    If(
                      isStop,
                      then: [
                        Case(q, [
                          CaseItem(Const(0, width: 2), [sdaLow < 1]),
                          CaseItem(Const(1, width: 2), [sclLow < 0]),
                          CaseItem(Const(2, width: 2), [sdaLow < 0]),
                        ]),
                      ],
                      orElse: [
                        Case(q, [
                          CaseItem(Const(0, width: 2), [
                            // A write byte sends its bit, a read byte and the ACK
                            // slot release SDA. The master NACKs the last read.
                            sdaLow < ~mux(isWrite, txBit, Const(1)),
                          ]),
                          CaseItem(Const(1, width: 2), [sclLow < 0]),
                          CaseItem(Const(2, width: 2), [
                            If(
                              isRead & ~ack,
                              then: [
                                rx < [rx.getRange(0, 7), sdaSync].concat(),
                              ],
                            ),
                            If(isWrite & ack & sdaSync, then: [nackNow < 1]),
                          ]),
                          CaseItem(Const(3, width: 2), [
                            sclLow < 1,
                            If(
                              isRead & ack,
                              then: [
                                for (var i = 0; i < regs.length; i++)
                                  If(data.eq(i), then: [regs[i] < rx]),
                              ],
                            ),
                          ]),
                        ]),
                      ],
                    ),
                  ],
                ),
                If(
                  q.eq(3),
                  then: [
                    If(
                      lastBit,
                      then: [
                        bitn < 0,
                        If(
                          lastOp,
                          then: [
                            running < 0,
                            wait < this.repeatCycles,
                            statusReg < statusNext,
                            passReg <
                                mux(passReg.eq(0xff), passReg, passReg + 1),
                          ],
                          orElse: [pc < pc + 1],
                        ),
                      ],
                      orElse: [bitn < bitn + 1],
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
    );

    sclOe <= sclLow;
    sdaOe <= sdaLow;
    status <= statusReg;
    passes <= passReg;
    vic <= regs[4];
    timing <= regs[5];
  }
}

/// Pulls a bidirectional pad low while [oe] is high and releases it
/// otherwise.
///
/// The SystemVerilog is written by hand. A tristate of ROHD on an inout
/// emits a form that yosys rejects.
class HarborOpenDrainPad extends Module with SystemVerilog {
  HarborOpenDrainPad({
    required Logic oe,
    required Logic pad,
    super.name = 'open_drain_pad',
  }) : super(
         definitionName: 'HarborOpenDrainPad',
         reserveDefinitionName: true,
       ) {
    addInput('oe', oe);
    addInOut('pad', pad);
  }

  @override
  String? definitionVerilog(String definitionType) =>
      '''
module $definitionType (
  input logic oe,
  inout wire pad
);
  assign pad = oe ? 1'b0 : 1'bz;
endmodule''';
}
