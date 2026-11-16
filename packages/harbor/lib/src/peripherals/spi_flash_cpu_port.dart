import 'package:rohd/rohd.dart';

import '../bus/bus_slave_port.dart';
import '../bus/port/reg_fifo.dart' show HarborFifoRam;

/// The CPU register port of [HarborSpiFlashController]: registers that start
/// a sector erase or a page program on the write engine, a 256-byte page
/// buffer, a partition lock mask and a claim register.
///
/// Registers are 32 bits wide in a 4 KiB window:
/// - 0x00 ctrl: bits [1:0] op (1 erase 4 KiB, 2 program), bit 31 go.
/// - 0x04 addr: flash byte offset.
/// - 0x08 len: program byte count, 1 to 256.
/// - 0x0c status: bit 0 busy, bit 1 done, bit 2 err, bit 3 locked.
/// - 0x10 lock_mask: bit N locks partition N of the build. A write sets
///   bits and never clears them. Only a reset clears the mask.
/// - 0x14 and 0x18 are reserved: they read 0 and ignore writes.
/// - 0x1c claim: a read returns 1 and takes the claim when it is free, and
///   returns 0 when it is taken. A write of 1 gives the claim back.
/// - 0x100 to 0x1ff page: the program data. Byte 0 goes to flash offset addr.
///
/// A go clears done and sets busy in the cycle of its bus ack, so the first
/// status read after the go shows busy 1 and done 0. A go does not clear err
/// or locked. A go while err or locked is set is still accepted. A go while
/// busy sets err and changes nothing. A refused op sets err, and locked when
/// the lock refused it, and never reaches the engine. A write of 1 to status
/// bit 2 clears err and locked together. Nothing else clears them.
///
/// A program sends page bytes 0 to len-1 whatever addr[7:0] is. Byte 0 is
/// the low byte of the word at offset 0x100 and goes out first. The lock
/// refuses an op that meets a locked partition. Writes to op, addr, len and
/// the page are ignored while busy. The page reads 0 while busy.
///
/// The claim is a semaphore for software. The hardware does not check it.
/// The master must drive SEL from the access size, so a 32-bit load sets
/// exactly the 4 bytes of 0x1c. A master that drives SEL all ones on every
/// read can never take the claim.
/// Only a read of exactly the 4 bytes of 0x1c takes the claim. A read with a
/// wider or narrower byte select, such as a 64-bit read of the word at 0x18,
/// returns the value and does not take it. On a 64-bit bus one store to 0x00
/// can write ctrl and addr together, and the go uses the new addr.
///
/// A completed erase or program changes the flash behind the XIP window.
/// The read line buffer is dropped, but a CPU cache over the window is not.
/// Software must invalidate it.
class HarborSpiFlashCpuPort {
  /// Size of the register window in bytes.
  static const windowBytes = 0x1000;

  /// Offset of the claim register.
  static const claimOffset = 0x1c;

  /// A request waits for the engine.
  final Logic req;

  /// The pending op: 0 erase, 1 program.
  final Logic op;

  /// The flash address of the pending op.
  final Logic addr;

  /// The program length of the pending op, 1 to 256.
  final Logic len;

  /// The page byte at the engine index. Valid while [run] is high.
  final Logic data;

  /// High from the cycle after the engine takes the request until the cycle
  /// after it finishes.
  final Logic run;

  HarborSpiFlashCpuPort._({
    required this.req,
    required this.op,
    required this.addr,
    required this.len,
    required this.data,
    required this.run,
  });

  /// Builds the port in the module that owns [bus].
  ///
  /// [take] is high in the cycle the engine starts the pending request.
  /// [engDone] is the engine done pulse, [engErr] its error flag and
  /// [engIdx] the index of the program byte it asks for.
  factory HarborSpiFlashCpuPort.build({
    required BusSlavePort bus,
    required Logic clk,
    required int flashSize,
    required List<({int offset, int size})> partitions,
    required int addrWidth,
    required Logic take,
    required Logic engDone,
    required Logic engErr,
    required Logic engIdx,
  }) {
    final busW = bus.dataIn.width;
    if (busW < 32) {
      throw ArgumentError.value(busW, 'bus data width', 'must be >= 32');
    }
    final bytesW = busW ~/ 8;
    final lb = bytesW.bitLength - 1;
    final reset = bus.reset;
    final off = bus.windowAddr(windowBytes);

    final opR = Logic(name: 'cp_op', width: 2);
    final addrR = Logic(name: 'cp_addr', width: 32);
    final lenR = Logic(name: 'cp_len', width: 32);
    final pend = Logic(name: 'cp_pend');
    final run = Logic(name: 'cp_run');
    final done = Logic(name: 'cp_done');
    final err = Logic(name: 'cp_err');
    final locked = Logic(name: 'cp_locked');
    final claimed = Logic(name: 'cp_claimed');
    final lockMask = Logic(name: 'cp_lock_mask', width: 32);

    Logic word(int o) =>
        bus.dataIn.getRange((o % bytesW) * 8, (o % bytesW) * 8 + 32);
    Logic laneSel(int o) => bus.sel[o % bytesW];
    Logic hit(int o) =>
        off.eq(Const(o - o % bytesW, width: 12)) & bus.selAny(o, 4);

    final busy = (pend | run).named('cp_busy');

    // The page buffer: one byte RAM per lane of the bus word.
    final inPage = off.getRange(8).eq(Const(1, width: 4));
    final pageWord = off.getRange(lb, 8);
    final access = bus.stb & ~bus.ack;
    final engWord = engIdx.getRange(lb, 8);
    final rams = [
      for (var i = 0; i < bytesW; i++)
        HarborFifoRam(
          name: 'cp_page_$i',
          clk: clk,
          wrEn: access & bus.we & inPage & ~busy & bus.sel[i],
          wrAddr: pageWord,
          wrData: bus.dataIn.getRange(i * 8, i * 8 + 8),
          rdAddr: mux(run, engWord, pageWord),
          depth: 256 ~/ bytesW,
          zeroInit: true,
        ).rdData,
    ];
    final pageRead = rams.rconcat();
    var engByte = rams.first;
    if (lb > 0) {
      final lane = engIdx.getRange(0, lb);
      for (var i = 1; i < bytesW; i++) {
        engByte = mux(lane.eq(Const(i, width: lb)), rams[i], engByte);
      }
    }

    // A go is checked against the registers. Width 34 holds addr + len.
    final opNow = mux(laneSel(0x00), word(0x00).getRange(0, 2), opR);
    final isErase = opNow.eq(Const(1, width: 2));
    final isProg = opNow.eq(Const(2, width: 2));
    // On a 64-bit bus one store can write ctrl and addr together, so the
    // check uses the address with that store merged in.
    final addrNow = bytesW >= 8 ? bus.selMerge(addrR, 0x04) : addrR;
    final addr34 = addrNow.zeroExtend(34);
    final sector34 = addr34 & Const(((1 << 34) - 1) & ~0xfff, width: 34);
    final start = mux(isProg, addr34, sector34);
    final end = mux(
      isProg,
      addr34 + lenR.zeroExtend(34),
      sector34 + Const(0x1000, width: 34),
    );
    final progBad =
        lenR.eq(Const(0, width: 32)) |
        (addrNow.getRange(0, 8).zeroExtend(34) + lenR.zeroExtend(34)).gt(
          Const(256, width: 34),
        );
    final formed =
        (isErase | isProg) &
        ~(isProg & progBad) &
        ~end.gt(Const(flashSize, width: 34));
    Logic meets(({int offset, int size}) part) =>
        start.lt(Const(part.offset + part.size, width: 34)) &
        end.gt(Const(part.offset, width: 34));
    final overlap = [
      Const(0),
      for (final (i, part) in partitions.indexed) lockMask[i] & meets(part),
    ].reduce((a, b) => a | b);

    final status = [Const(0, width: 28), locked, err, done, busy].concat();
    final regs = <int, Logic>{
      0x00: opR.zeroExtend(32),
      0x04: addrR,
      0x08: lenR,
      0x0c: status,
      0x10: lockMask,
      claimOffset: (~claimed).zeroExtend(32),
    };
    final bases = {for (final o in regs.keys) o - o % bytesW};
    Logic readWord(int base) => [
      for (var j = 0; j < bytesW ~/ 4; j++)
        regs[base + 4 * j] ?? Const(0, width: 32),
    ].rconcat();

    // Only an exact 32-bit read of the claim register takes the claim, so a
    // 64-bit read of the word at 0x18 does not.
    final claimRead =
        off.eq(Const(claimOffset - claimOffset % bytesW, width: 12)) &
        bus.sel.eq(Const(0xf << (claimOffset % bytesW), width: bytesW));

    final goHit = hit(0x00) & laneSel(0x03) & word(0x00)[31];

    Sequential(clk, [
      If(
        reset,
        then: [
          opR < Const(0, width: 2),
          addrR < Const(0, width: 32),
          lenR < Const(0, width: 32),
          pend < Const(0),
          run < Const(0),
          done < Const(0),
          err < Const(0),
          locked < Const(0),
          claimed < Const(0),
          lockMask < Const(0, width: 32),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: busW),
        ],
        orElse: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: busW),
          If(take, then: [pend < Const(0), run < Const(1)]),
          If(
            engDone & run,
            then: [
              run < Const(0),
              done < Const(1),
              If(engErr, then: [err < Const(1)]),
            ],
          ),
          If(
            access,
            then: [
              bus.ack < Const(1),
              If(
                bus.we,
                then: [
                  If(
                    ~busy,
                    then: [
                      If(
                        hit(0x00) & laneSel(0x00),
                        then: [opR < word(0x00).getRange(0, 2)],
                      ),
                      If(hit(0x04), then: [addrR < bus.selMerge(addrR, 0x04)]),
                      If(hit(0x08), then: [lenR < bus.selMerge(lenR, 0x08)]),
                    ],
                  ),
                  If(
                    goHit,
                    then: [
                      If(
                        busy,
                        then: [err < Const(1)],
                        orElse: [
                          If(
                            formed & ~overlap,
                            then: [pend < Const(1), done < Const(0)],
                            orElse: [
                              err < Const(1),
                              If(formed, then: [locked < Const(1)]),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                  If(
                    hit(0x0c) & laneSel(0x0c) & word(0x0c)[2],
                    then: [err < Const(0), locked < Const(0)],
                  ),
                  If(
                    hit(0x10),
                    then: [lockMask < (lockMask | bus.selMasked(0x10, 32))],
                  ),
                  If(
                    hit(claimOffset) &
                        laneSel(claimOffset) &
                        word(claimOffset)[0],
                    then: [claimed < Const(0)],
                  ),
                ],
                orElse: [
                  If(claimRead, then: [claimed < Const(1)]),
                  If(
                    inPage,
                    then: [
                      If(~busy, then: [bus.dataOut < pageRead]),
                    ],
                    orElse: [
                      Case(off, [
                        for (final b in bases)
                          CaseItem(Const(b, width: 12), [
                            bus.dataOut < readWord(b),
                          ]),
                      ]),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    return HarborSpiFlashCpuPort._(
      req: pend,
      op: opR[1],
      addr: addrR.getRange(0, addrWidth),
      len: lenR.getRange(0, 9),
      data: engByte,
      run: run,
    );
  }
}
