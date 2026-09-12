/// Full-speed USB line-level PHY ported from the proven tinyfpga_bx_usbserial
/// core (davidthings). This file is a faithful ROHD translation of the
/// original usb_fs_rx.v and usb_fs_tx.v, including the clock-recovery
/// alignment between the receive and transmit paths.
///
/// The receive path double-flops the asynchronous pads, recovers the line
/// state, aligns a 4x bit-phase tracker to each transition, detects packet
/// start (sync pattern) and end (SE0 SE0), NRZI-decodes the bits, removes
/// stuff bits, checks PID/CRC5/CRC16, decodes token fields and deserializes
/// data bytes.
///
/// The transmit path serializes a packet: sync, PID, optional data payload
/// (pulled from the caller with a one-cycle get pulse per byte), CRC16 and
/// the EOP. Bit stuffing is inserted and the NRZI encoding drives the pads.
/// The bit strobe from the receive path aligns transmit bit timing with the
/// host clock.
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Full-speed USB packet receiver, ported from usb_fs_rx.v.
///
/// Runs on a 48 MHz clock. Consumes the raw dp/dn line inputs and produces
/// decoded packets: PID, token fields (addr/endp/frame), data bytes and
/// packet validity.
class HarborUsbFsRx extends BridgeModule {
  HarborUsbFsRx({String? name})
    : super('HarborUsbFsRx', name: name ?? 'usb_fs_rx') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('dp', PortDirection.input);
    createPort('dn', PortDirection.input);

    addOutput('bit_strobe');
    addOutput('pkt_start');
    addOutput('pkt_end');
    addOutput('pid', width: 4);
    addOutput('addr', width: 7);
    addOutput('endp', width: 4);
    addOutput('frame_num', width: 11);
    addOutput('rx_data_put');
    addOutput('rx_data', width: 8);
    addOutput('valid_packet');

    final clk = input('clk');
    final reset = input('reset');
    final dp = input('dp');
    final dn = input('dn');

    // ------------------------------------------------------------------
    // Double-flop synchronizer for the asynchronous pads.
    // ------------------------------------------------------------------
    final dpairQ = Logic(name: 'dpair_q', width: 4);
    Sequential(clk, [
      If(
        reset,
        then: [dpairQ < Const(0, width: 4)],
        orElse: [
          dpairQ < [dpairQ.slice(1, 0), dp, dn].swizzle(),
        ],
      ),
    ]);

    final dpair = dpairQ.slice(3, 2);

    // ------------------------------------------------------------------
    // Line state recovery. A transition holds the machine in DT for one
    // sample so a skewed pair change never decodes as a wrong state.
    // ------------------------------------------------------------------
    final lineState = Logic(name: 'line_state', width: 3);
    const stDt = 4;
    const stDj = 2;
    const stDk = 1;
    const stSe0 = 0;
    const stSe1 = 3;

    Sequential(clk, [
      If(
        reset,
        then: [lineState < Const(stSe0, width: 3)],
        orElse: [
          Case(
            lineState,
            [
              CaseItem(Const(stDt, width: 3), [
                Case(dpair, [
                  CaseItem(Const(2, width: 2), [
                    lineState < Const(stDj, width: 3),
                  ]),
                  CaseItem(Const(1, width: 2), [
                    lineState < Const(stDk, width: 3),
                  ]),
                  CaseItem(Const(0, width: 2), [
                    lineState < Const(stSe0, width: 3),
                  ]),
                  CaseItem(Const(3, width: 2), [
                    lineState < Const(stSe1, width: 3),
                  ]),
                ]),
              ]),
              CaseItem(Const(stDj, width: 3), [
                If(
                  ~dpair.eq(Const(2, width: 2)),
                  then: [lineState < Const(stDt, width: 3)],
                ),
              ]),
              CaseItem(Const(stDk, width: 3), [
                If(
                  ~dpair.eq(Const(1, width: 2)),
                  then: [lineState < Const(stDt, width: 3)],
                ),
              ]),
              CaseItem(Const(stSe0, width: 3), [
                If(
                  ~dpair.eq(Const(0, width: 2)),
                  then: [lineState < Const(stDt, width: 3)],
                ),
              ]),
              CaseItem(Const(stSe1, width: 3), [
                If(
                  ~dpair.eq(Const(3, width: 2)),
                  then: [lineState < Const(stDt, width: 3)],
                ),
              ]),
            ],
            defaultItem: [lineState < Const(stDt, width: 3)],
          ),
        ],
      ),
    ]);

    // ------------------------------------------------------------------
    // Clock recovery. Each DT resets the phase; the phase then counts 0,
    // 1, 2, 3 within each bit. The state is valid at phase 1 and the bit
    // strobe fires at phase 2.
    // ------------------------------------------------------------------
    final bitPhase = Logic(name: 'bit_phase', width: 2);
    final lineStateValid = bitPhase
        .eq(Const(1, width: 2))
        .named('line_state_valid');
    final bitStrobe = bitPhase.eq(Const(2, width: 2)).named('bit_strobe_i');
    output('bit_strobe') <= bitStrobe;

    Sequential(clk, [
      If(
        reset,
        then: [bitPhase < Const(0, width: 2)],
        orElse: [
          If(
            lineState.eq(Const(stDt, width: 3)),
            then: [bitPhase < Const(0, width: 2)],
            orElse: [bitPhase < bitPhase + Const(1, width: 2)],
          ),
        ],
      ),
    ]);

    // ------------------------------------------------------------------
    // Packet detection. Sync pattern KJKJKK starts a packet, SE0 SE0
    // ends it.
    // ------------------------------------------------------------------
    final lineHistory = Logic(name: 'line_history', width: 6);
    final packetValid = Logic(name: 'packet_valid');
    final nextPacketValid = Logic(name: 'next_packet_valid');

    final packetStart = (nextPacketValid & ~packetValid).named(
      'packet_start_i',
    );
    final packetEnd = (~nextPacketValid & packetValid).named('packet_end_i');
    output('pkt_start') <= packetStart;
    output('pkt_end') <= packetEnd;

    Combinational([
      If(
        lineStateValid,
        then: [
          If(
            ~packetValid & lineHistory.eq(Const(37, width: 6)),
            then: [nextPacketValid < Const(1)],
            orElse: [
              If(
                packetValid & lineHistory.slice(3, 0).eq(Const(0, width: 4)),
                then: [nextPacketValid < Const(0)],
                orElse: [nextPacketValid < packetValid],
              ),
            ],
          ),
        ],
        orElse: [nextPacketValid < packetValid],
      ),
    ]);

    Sequential(clk, [
      If(
        reset,
        then: [lineHistory < Const(42, width: 6), packetValid < Const(0)],
        orElse: [
          If(
            lineStateValid,
            then: [
              lineHistory <
                  [lineHistory.slice(3, 0), lineState.slice(1, 0)].swizzle(),
            ],
          ),
          // Deviation from usb_fs_rx.v:168-179. In the original, the
          // statement packet_valid <= next_packet_valid is outside the
          // if (reset) block, so it runs on every clock. This makes the
          // reset assignment above it dead code. The original receiver
          // keeps packet_valid during reset. It also holds line_history
          // at 6'b101010 during reset, so the receiver keeps its
          // in-packet state.
          // This port clears packet_valid on reset. ROHD has no
          // equivalent of a Verilog declaration initialiser, so the reset
          // branch is the only way to give the register a defined
          // power-on value.
          // The deviation has a cost. A reset in the middle of a packet
          // re-arms the sync detector, and the receiver can then send a
          // pkt_start with no matching pkt_end. This is safe in this
          // design. Reset comes from the chip reset or from
          // usb_reset_det, and usb_reset_det needs more than 30000 clocks
          // of SE0. No packet is in flight in either case.
          packetValid < nextPacketValid,
        ],
      ),
    ]);

    // ------------------------------------------------------------------
    // NRZI decode from the line history low nibble.
    // ------------------------------------------------------------------
    final din = Logic(name: 'din');
    final dvalidRaw = Logic(name: 'dvalid_raw');

    Combinational([
      Case(
        lineHistory.slice(3, 0),
        [
          CaseItem(Const(5, width: 4), [din < Const(1)]),
          CaseItem(Const(6, width: 4), [din < Const(0)]),
          CaseItem(Const(9, width: 4), [din < Const(0)]),
          CaseItem(Const(10, width: 4), [din < Const(1)]),
        ],
        defaultItem: [din < Const(0)],
      ),
      If(
        packetValid & lineStateValid,
        then: [
          Case(
            lineHistory.slice(3, 0),
            [
              CaseItem(Const(5, width: 4), [dvalidRaw < Const(1)]),
              CaseItem(Const(6, width: 4), [dvalidRaw < Const(1)]),
              CaseItem(Const(9, width: 4), [dvalidRaw < Const(1)]),
              CaseItem(Const(10, width: 4), [dvalidRaw < Const(1)]),
            ],
            defaultItem: [dvalidRaw < Const(0)],
          ),
        ],
        orElse: [dvalidRaw < Const(0)],
      ),
    ]);

    // ------------------------------------------------------------------
    // Stuff-bit removal. Six consecutive one bits mark a stuff bit; it
    // is dropped from the decoded stream.
    // ------------------------------------------------------------------
    final bitstuffHistory = Logic(name: 'bitstuff_history', width: 6);
    final dvalid = (dvalidRaw & ~bitstuffHistory.eq(Const(63, width: 6))).named(
      'dvalid',
    );

    Sequential(clk, [
      If(
        reset | packetEnd,
        then: [bitstuffHistory < Const(0, width: 6)],
        orElse: [
          If(
            dvalidRaw,
            then: [
              bitstuffHistory < [bitstuffHistory.slice(4, 0), din].swizzle(),
            ],
          ),
        ],
      ),
    ]);

    // ------------------------------------------------------------------
    // PID capture with a sentinel bit.
    // ------------------------------------------------------------------
    final fullPid = Logic(name: 'full_pid', width: 9);
    final pidValid = fullPid
        .slice(4, 1)
        .eq(~fullPid.slice(8, 5))
        .named('pid_valid');
    final pidComplete = fullPid.slice(0, 0).named('pid_complete');

    Sequential(clk, [
      If(
        reset,
        then: [fullPid < Const(0, width: 9)],
        orElse: [
          If(packetStart, then: [fullPid < Const(256, width: 9)]),
          If(
            dvalid & ~pidComplete,
            then: [
              fullPid < [din, fullPid.slice(8, 1)].swizzle(),
            ],
          ),
        ],
      ),
    ]);

    // ------------------------------------------------------------------
    // CRC5 check (tokens).
    // ------------------------------------------------------------------
    final crc5 = Logic(name: 'crc5', width: 5);
    final crc5Valid = crc5.eq(Const(12, width: 5)).named('crc5_valid');
    final crc5Invert = (din ^ crc5.slice(4, 4)).named('crc5_invert');

    Sequential(clk, [
      If(
        reset,
        then: [crc5 < Const(0, width: 5)],
        orElse: [
          If(packetStart, then: [crc5 < Const(31, width: 5)]),
          If(
            dvalid & pidComplete,
            then: [
              crc5 <
                  [
                    crc5.slice(3, 2),
                    crc5.slice(1, 1) ^ crc5Invert,
                    crc5.slice(0, 0),
                    crc5Invert,
                  ].swizzle(),
            ],
          ),
        ],
      ),
    ]);

    // ------------------------------------------------------------------
    // CRC16 check (data packets).
    // ------------------------------------------------------------------
    final crc16 = Logic(name: 'crc16', width: 16);
    final crc16Valid = crc16.eq(Const(32781, width: 16)).named('crc16_valid');
    final crc16Invert = (din ^ crc16.slice(15, 15)).named('crc16_invert');

    Sequential(clk, [
      If(
        reset,
        then: [crc16 < Const(0, width: 16)],
        orElse: [
          If(packetStart, then: [crc16 < Const(0xFFFF, width: 16)]),
          If(
            dvalid & pidComplete,
            then: [
              crc16 <
                  [
                    crc16.slice(14, 14) ^ crc16Invert,
                    crc16.slice(13, 2),
                    crc16.slice(1, 1) ^ crc16Invert,
                    crc16.slice(0, 0),
                    crc16Invert,
                  ].swizzle(),
            ],
          ),
        ],
      ),
    ]);

    // ------------------------------------------------------------------
    // Packet type decode from the PID nibble.
    // ------------------------------------------------------------------
    final pktIsToken = fullPid
        .slice(2, 1)
        .eq(Const(1, width: 2))
        .named('pkt_is_token');
    final pktIsData = fullPid
        .slice(2, 1)
        .eq(Const(3, width: 2))
        .named('pkt_is_data');
    final pktIsHandshake = fullPid
        .slice(2, 1)
        .eq(Const(2, width: 2))
        .named('pkt_is_handshake');

    output('valid_packet') <=
        pidValid &
            (pktIsHandshake |
                (pktIsData & crc16Valid) |
                (pktIsToken & crc5Valid));

    output('pid') <= fullPid.slice(4, 1);

    // ------------------------------------------------------------------
    // Token payload capture: 11 bits with a sentinel.
    // ------------------------------------------------------------------
    final tokenPayload = Logic(name: 'token_payload', width: 12);
    final tokenPayloadDone = tokenPayload
        .slice(0, 0)
        .named('token_payload_done');

    Sequential(clk, [
      If(
        reset,
        then: [tokenPayload < Const(0, width: 12)],
        orElse: [
          If(packetStart, then: [tokenPayload < Const(2048, width: 12)]),
          If(
            dvalid & pidComplete & pktIsToken & ~tokenPayloadDone,
            then: [
              tokenPayload < [din, tokenPayload.slice(11, 1)].swizzle(),
            ],
          ),
        ],
      ),
    ]);

    final addrReg = Logic(name: 'addr_reg', width: 7);
    final endpReg = Logic(name: 'endp_reg', width: 4);
    final frameNumReg = Logic(name: 'frame_num_reg', width: 11);

    Sequential(clk, [
      If(
        reset,
        then: [
          addrReg < Const(0, width: 7),
          endpReg < Const(0, width: 4),
          frameNumReg < Const(0, width: 11),
        ],
        orElse: [
          If(
            tokenPayloadDone & pktIsToken,
            then: [
              addrReg < tokenPayload.slice(7, 1),
              endpReg < tokenPayload.slice(11, 8),
              frameNumReg < tokenPayload.slice(11, 1),
            ],
          ),
        ],
      ),
    ]);

    output('addr') <= addrReg;
    output('endp') <= endpReg;
    output('frame_num') <= frameNumReg;

    // ------------------------------------------------------------------
    // Data deserialization with a sentinel.
    // ------------------------------------------------------------------
    final rxDataBuffer = Logic(name: 'rx_data_buffer', width: 9);
    final rxDataBufferFull = rxDataBuffer.slice(0, 0).named('rx_buffer_full');

    output('rx_data_put') <= rxDataBufferFull;
    output('rx_data') <= rxDataBuffer.slice(8, 1);

    Sequential(clk, [
      If(
        reset,
        then: [rxDataBuffer < Const(0, width: 9)],
        orElse: [
          If(
            packetStart | rxDataBufferFull,
            then: [rxDataBuffer < Const(256, width: 9)],
          ),
          If(
            dvalid & pidComplete & pktIsData,
            then: [
              rxDataBuffer < [din, rxDataBuffer.slice(8, 1)].swizzle(),
            ],
          ),
        ],
      ),
    ]);
  }
}

/// Full-speed USB packet transmitter, ported from usb_fs_tx.v.
///
/// Runs on a 48 MHz clock. Consumes a start pulse, a PID and an optional
/// data stream (avail/get handshake, one get pulse per byte) and drives
/// the dp/dn pads with the serialized, stuffed, NRZI-encoded packet
/// including sync, CRC16 and EOP.
class HarborUsbFsTx extends BridgeModule {
  HarborUsbFsTx({String? name})
    : super('HarborUsbFsTx', name: name ?? 'usb_fs_tx') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('bit_strobe', PortDirection.input);
    addOutput('oe');
    addOutput('dp');
    addOutput('dn');
    createPort('pkt_start', PortDirection.input);
    addOutput('pkt_end');
    createPort('pid', PortDirection.input, width: 4);
    createPort('tx_data_avail', PortDirection.input);
    addOutput('tx_data_get');
    createPort('tx_data', PortDirection.input, width: 8);

    final clk = input('clk');
    final reset = input('reset');
    final bitStrobe = input('bit_strobe');
    final pktStart = input('pkt_start');
    final pidIn = input('pid');
    final txDataAvail = input('tx_data_avail');
    final txData = input('tx_data');

    // ------------------------------------------------------------------
    // Latched PID.
    // ------------------------------------------------------------------
    final pidq = Logic(name: 'pidq', width: 4);

    // ------------------------------------------------------------------
    // Serializer shift registers.
    // ------------------------------------------------------------------
    final dataShiftReg = Logic(name: 'data_shift_reg', width: 8);
    final oeShiftReg = Logic(name: 'oe_shift_reg', width: 8);
    final se0ShiftReg = Logic(name: 'se0_shift_reg', width: 8);

    final serialTxData = dataShiftReg.slice(0, 0).named('serial_tx_data');
    final serialTxOe = oeShiftReg.slice(0, 0).named('serial_tx_oe');
    final serialTxSe0 = se0ShiftReg.slice(0, 0).named('serial_tx_se0');

    final byteStrobe = Logic(name: 'byte_strobe');
    final bitCount = Logic(name: 'bit_count', width: 3);

    final bitHistoryQ = Logic(name: 'bit_history_q', width: 5);
    final bitHistory = [
      serialTxData,
      bitHistoryQ,
    ].swizzle().named('bit_history');
    final bitstuff = bitHistory.eq(Const(63, width: 6)).named('bitstuff');

    // Stuff-pipeline: the CRC must skip a stuff bit when it reaches the
    // serial output, which is 4 clock cycles after the insertion
    // decision (usb_fs_tx.v:61-66). These registers are not gated by
    // bit_strobe. 4 clock cycles are equal to one bit strobe only at the
    // nominal 4-clock bit time. The strobe period is not constant,
    // because the receive phase tracker makes the bit time longer or
    // shorter at each line transition.
    final bitstuffQ = Logic(name: 'bitstuff_q');
    final bitstuffQq = Logic(name: 'bitstuff_qq');
    final bitstuffQqq = Logic(name: 'bitstuff_qqq');
    final bitstuffQqqq = Logic(name: 'bitstuff_qqqq');

    Sequential(clk, [
      If(
        reset,
        then: [
          bitstuffQ < Const(0),
          bitstuffQq < Const(0),
          bitstuffQqq < Const(0),
          bitstuffQqqq < Const(0),
        ],
        orElse: [
          bitstuffQ < bitstuff,
          bitstuffQq < bitstuffQ,
          bitstuffQqq < bitstuffQq,
          bitstuffQqqq < bitstuffQqq,
        ],
      ),
    ]);

    output('pkt_end') <=
        bitStrobe & se0ShiftReg.slice(1, 0).eq(Const(1, width: 2));

    final dataPayload = Logic(name: 'data_payload');

    // ------------------------------------------------------------------
    // Packet state machine. State values match the original.
    // ------------------------------------------------------------------
    final pktState = Logic(name: 'pkt_state', width: 32);
    const stIdle = 0;
    const stSync = 1;
    const stPid = 2;
    const stDataOrCrc16_0 = 3;
    const stCrc16_1 = 4;
    const stEop = 5;

    final txDataGet = Logic(name: 'tx_data_get');

    // ------------------------------------------------------------------
    // CRC16 generation over the serialized payload.
    // ------------------------------------------------------------------
    final crc16 = Logic(name: 'crc16', width: 16);
    final crc16Invert = (serialTxData ^ crc16.slice(15, 15)).named(
      'crc16_invert',
    );

    Sequential(clk, [
      If(
        reset,
        then: [crc16 < Const(0, width: 16)],
        orElse: [
          If(pktStart, then: [crc16 < Const(0xFFFF, width: 16)]),
          If(
            bitStrobe & dataPayload & ~bitstuffQqqq & ~pktStart,
            then: [
              crc16 <
                  [
                    crc16.slice(14, 14) ^ crc16Invert,
                    crc16.slice(13, 2),
                    crc16.slice(1, 1) ^ crc16Invert,
                    crc16.slice(0, 0),
                    crc16Invert,
                  ].swizzle(),
            ],
          ),
        ],
      ),
    ]);

    // ------------------------------------------------------------------
    // EOP sequencing for the dp line.
    // ------------------------------------------------------------------
    final dpEop = Logic(name: 'dp_eop', width: 3);

    // Output registers.
    final oeReg = Logic(name: 'oe_reg');
    final dpReg = Logic(name: 'dp_reg');
    final dnReg = Logic(name: 'dn_reg');

    // ------------------------------------------------------------------
    // Main serialization: state machine, byte strobe and bit shifting in
    // one clocked block, preserving the original assignment order so
    // the last write wins exactly as in the Verilog.
    // ------------------------------------------------------------------
    Sequential(clk, [
      If(
        reset,
        then: [
          pktState < Const(stIdle, width: 32),
          pidq < Const(0, width: 4),
          dataShiftReg < Const(0, width: 8),
          oeShiftReg < Const(0, width: 8),
          se0ShiftReg < Const(0, width: 8),
          byteStrobe < Const(0),
          bitCount < Const(0, width: 3),
          bitHistoryQ < Const(0, width: 5),
          dataPayload < Const(0),
          txDataGet < Const(0),
          dpEop < Const(0, width: 3),
          oeReg < Const(0),
          dpReg < Const(0),
          dnReg < Const(0),
        ],
        orElse: [
          If(pktStart, then: [pidq < pidIn]),

          Case(pktState, [
            CaseItem(Const(stIdle, width: 32), [
              If(pktStart, then: [pktState < Const(stSync, width: 32)]),
            ]),
            CaseItem(Const(stSync, width: 32), [
              If(
                byteStrobe,
                then: [
                  pktState < Const(stPid, width: 32),
                  dataShiftReg < Const(128, width: 8),
                  oeShiftReg < Const(255, width: 8),
                  se0ShiftReg < Const(0, width: 8),
                ],
              ),
            ]),
            CaseItem(Const(stPid, width: 32), [
              If(
                byteStrobe,
                then: [
                  If(
                    pidq.slice(1, 0).eq(Const(3, width: 2)),
                    then: [pktState < Const(stDataOrCrc16_0, width: 32)],
                    orElse: [pktState < Const(stEop, width: 32)],
                  ),
                  dataShiftReg < [~pidq, pidq].swizzle(),
                  oeShiftReg < Const(255, width: 8),
                  se0ShiftReg < Const(0, width: 8),
                ],
              ),
            ]),
            CaseItem(Const(stDataOrCrc16_0, width: 32), [
              If(
                byteStrobe,
                then: [
                  If(
                    txDataAvail,
                    then: [
                      pktState < Const(stDataOrCrc16_0, width: 32),
                      dataPayload < Const(1),
                      txDataGet < Const(1),
                      dataShiftReg < txData,
                      oeShiftReg < Const(255, width: 8),
                      se0ShiftReg < Const(0, width: 8),
                    ],
                    orElse: [
                      pktState < Const(stCrc16_1, width: 32),
                      dataPayload < Const(0),
                      txDataGet < Const(0),
                      dataShiftReg <
                          ~[
                            crc16.slice(8, 8),
                            crc16.slice(9, 9),
                            crc16.slice(10, 10),
                            crc16.slice(11, 11),
                            crc16.slice(12, 12),
                            crc16.slice(13, 13),
                            crc16.slice(14, 14),
                            crc16.slice(15, 15),
                          ].swizzle(),
                      oeShiftReg < Const(255, width: 8),
                      se0ShiftReg < Const(0, width: 8),
                    ],
                  ),
                ],
                orElse: [txDataGet < Const(0)],
              ),
            ]),
            CaseItem(Const(stCrc16_1, width: 32), [
              If(
                byteStrobe,
                then: [
                  pktState < Const(stEop, width: 32),
                  dataShiftReg <
                      ~[
                        crc16.slice(0, 0),
                        crc16.slice(1, 1),
                        crc16.slice(2, 2),
                        crc16.slice(3, 3),
                        crc16.slice(4, 4),
                        crc16.slice(5, 5),
                        crc16.slice(6, 6),
                        crc16.slice(7, 7),
                      ].swizzle(),
                  oeShiftReg < Const(255, width: 8),
                  se0ShiftReg < Const(0, width: 8),
                ],
              ),
            ]),
            CaseItem(Const(stEop, width: 32), [
              If(
                byteStrobe,
                then: [
                  pktState < Const(stIdle, width: 32),
                  oeShiftReg < Const(7, width: 8),
                  se0ShiftReg < Const(7, width: 8),
                ],
              ),
            ]),
          ]),

          // Byte strobe: fires at the first bit of each byte time.
          If(
            bitStrobe & ~bitstuff,
            then: [byteStrobe < bitCount.eq(Const(0, width: 3))],
            orElse: [byteStrobe < Const(0)],
          ),

          // Bit shifting. On pkt_start the counters prime. On each bit
          // strobe either a stuff bit holds the shift or the registers
          // advance.
          If(
            pktStart,
            then: [
              bitCount < Const(1, width: 3),
              bitHistoryQ < Const(0, width: 5),
            ],
            orElse: [
              If(
                bitStrobe,
                then: [
                  If(
                    bitstuff,
                    then: [
                      bitHistoryQ < bitHistory.slice(5, 1),
                      dataShiftReg <
                          [dataShiftReg.slice(7, 1), Const(0)].swizzle(),
                    ],
                    orElse: [
                      bitCount < bitCount + Const(1, width: 3),
                      dataShiftReg < dataShiftReg >>> 1,
                      oeShiftReg < oeShiftReg >>> 1,
                      se0ShiftReg < se0ShiftReg >>> 1,
                      bitHistoryQ < bitHistory.slice(5, 1),
                    ],
                  ),
                ],
              ),
            ],
          ),

          // ----------------------------------------------------------------
          // NRZI line driving.
          // ----------------------------------------------------------------
          If(
            pktStart,
            then: [
              dpReg < Const(1),
              dnReg < Const(0),
              dpEop < Const(4, width: 3),
            ],
            orElse: [
              If(
                bitStrobe,
                then: [
                  oeReg < serialTxOe,
                  If(
                    serialTxSe0,
                    then: [
                      dpReg < dpEop.slice(0, 0),
                      dnReg < Const(0),
                      dpEop < dpEop >>> 1,
                    ],
                    orElse: [
                      If(~serialTxData, then: [dpReg < ~dpReg, dnReg < ~dnReg]),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    output('oe') <= oeReg;
    output('dp') <= dpReg;
    output('dn') <= dnReg;
    output('tx_data_get') <= txDataGet;
  }
}
