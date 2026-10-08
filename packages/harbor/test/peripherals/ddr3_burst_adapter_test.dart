import 'dart:async';
import 'dart:math';

import 'package:harbor/src/clock/wishbone_cdc_fifo.dart';
import 'package:harbor/src/peripherals/ddr3_burst_adapter.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Unit-tests the 32<->128 burst adapter against a procedural mock of the
/// [Ddr3Controller]'s wide pipelined side (always-accept, byte-masked backing
/// store, fixed read-ack latency). Verifies narrow words land in / come from the
/// correct lane of the wide burst without clobbering neighbours (DM masking).
void main() {
  tearDown(() async => Simulator.reset());

  test('narrow 32b writes/reads map to the right 128b burst lane', () async {
    const busAddrW = 24, ddrAddrW = 24;
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset')..inject(1);
    final sCyc = Logic()..inject(0);
    final sStb = Logic()..inject(0);
    final sWe = Logic()..inject(0);
    final sAddr = Logic(width: busAddrW)..inject(0);
    final sData = Logic(width: 32)..inject(0);
    final sSel = Logic(width: 4)..inject(0);
    final mStall = Logic()..inject(0); // always accept
    final mAck = Logic()..inject(0);
    final mAckAux = Logic(width: 4)..inject(0);
    final mData = Logic(width: 128)..inject(0);
    final acks = _AckPipe(mAck, mAckAux, mData);

    final dut = Ddr3BurstAdapter(
      busAddrWidth: busAddrW,
      ddrAddrWidth: ddrAddrW,
      clk: clk,
      reset: reset,
      sCyc: sCyc,
      sStb: sStb,
      sWe: sWe,
      sAddr: sAddr,
      sData: sData,
      sSel: sSel,
      mStall: mStall,
      mAck: mAck,
      mAckAux: mAckAux,
      mData: mData,
    );
    await dut.build();

    // Procedural mock of the wide controller side.
    final mem = <int, BigInt>{}; // burst addr -> 128-bit word
    // Models the controller's write pipeline: a write only reaches DRAM if cyc
    // stays asserted long enough for it to flush; if cyc drops early the
    // controller ABORTS it (o_wb_cyc gates s1/s2 pending). This is exactly the
    // regression the WRITE_DRAIN state fixes - without cyc held, writes abort.
    const wrDrainNeeded = 4;
    Map<String, dynamic>? pendingWrite;
    Timer? _; // silence unused

    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());

    // Mock: every posedge, service the adapter's wide master port.
    clk.posedge.listen((_) {
      final cyc = dut.output('m_cyc').value.toInt();
      // accept a command (mStall held 0).
      if (cyc == 1 && dut.output('m_stb').value.toInt() == 1) {
        final addr = dut.output('m_addr').value.toInt();
        acks.accept(dut, () => mem[addr] ?? BigInt.zero);
        if (dut.output('m_we').value.toInt() == 1) {
          // capture the write, but DON'T commit yet: it must survive the drain.
          pendingWrite ??= {
            'addr': addr,
            'data': dut.output('m_data_out').value.toBigInt(),
            'sel': dut.output('m_sel').value.toInt(),
            'left': wrDrainNeeded,
          };
        }
      }
      // in-flight write: commit iff cyc stays high through the drain; else abort.
      if (pendingWrite != null) {
        if (cyc == 0) {
          pendingWrite =
              null; // cyc dropped early -> controller aborts the write
        } else {
          pendingWrite!['left'] = (pendingWrite!['left'] as int) - 1;
          if ((pendingWrite!['left'] as int) <= 0) {
            final addr = pendingWrite!['addr'] as int;
            final wdata = pendingWrite!['data'] as BigInt;
            final sel = pendingWrite!['sel'] as int;
            var mask = BigInt.zero;
            for (var b = 0; b < 16; b++) {
              if ((sel >> b) & 1 == 1) mask |= BigInt.from(0xff) << (b * 8);
            }
            mem[addr] = ((mem[addr] ?? BigInt.zero) & ~mask) | (wdata & mask);
            pendingWrite = null;
          }
        }
      }
      acks.tick();
    });

    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    Future<void> busWrite(int addr, int data, {int sel = 0xF}) async {
      sCyc.inject(1);
      sStb.inject(1);
      sWe.inject(1);
      sAddr.inject(addr);
      sData.inject(data);
      sSel.inject(sel);
      // wait for ack
      var guard = 0;
      do {
        await clk.nextPosedge;
        guard++;
      } while (dut.output('s_ack').value.toInt() != 1 && guard < 100);
      sCyc.inject(0);
      sStb.inject(0);
      sWe.inject(0);
      await clk.nextPosedge;
    }

    Future<int> busRead(int addr) async {
      sCyc.inject(1);
      sStb.inject(1);
      sWe.inject(0);
      sAddr.inject(addr);
      var guard = 0;
      do {
        await clk.nextPosedge;
        guard++;
      } while (dut.output('s_ack').value.toInt() != 1 && guard < 100);
      final v = dut.output('s_data_out').value.toInt();
      sCyc.inject(0);
      sStb.inject(0);
      await clk.nextPosedge;
      return v;
    }

    // BYTE addresses: burst = addr>>4, word-in-burst = addr[3:2]. byte 0 and byte
    // 4 are words 0/1 of burst 0; byte 0x14 is word 1 of burst 1.
    await busWrite(0x0, 0xAABBCCDD);
    await busWrite(0x4, 0x11223344);
    await busWrite(0x14, 0xDEADBEEF);

    expect(await busRead(0x0), 0xAABBCCDD, reason: 'burst0 word0');
    expect(
      await busRead(0x4),
      0x11223344,
      reason: 'burst0 word1 (neighbour not clobbered)',
    );
    expect(await busRead(0x8), 0, reason: 'burst0 word2 never written');
    expect(await busRead(0x14), 0xDEADBEEF, reason: 'burst1 word1');

    // partial byte write into an existing word must not disturb other bytes.
    await busWrite(0x0, 0x000000FF, sel: 0x1); // low byte only
    expect(await busRead(0x0), 0xAABBCCFF, reason: 'byte-masked write');

    await Simulator.endSimulation();
  });

  group('pipelined write path', () {
    for (final combine in const [true, false]) {
      final mode = combine ? 'combining' : 'pass-through';

      test('$mode: 16 sequential words all land', () async {
        final h = _Harness(writeCombine: combine);
        await h.start();
        for (var i = 0; i < 16; i++) {
          await h.busWrite(i * 4, 0xC0DE0000 | i);
        }
        await h.idle(120); // let the idle flush land the tail
        for (var i = 0; i < 16; i++) {
          expect(
            await h.busRead(i * 4),
            0xC0DE0000 | i,
            reason: 'word $i must survive the write stream',
          );
        }
        expect(
          h.wideWrites,
          combine ? 4 : 16,
          reason: combine
              ? 'four narrow words per 128-bit burst = four DRAM commands'
              : 'no combining means one DRAM command per narrow word',
        );
        await h.stop();
      });

      test('$mode: a write stream costs a few cycles per word', () async {
        const n = 64;
        final h = _Harness(writeCombine: combine);
        await h.start();
        final start = h.cycles;
        for (var i = 0; i < n; i++) {
          await h.busWrite(i * 4, i);
        }
        final perWord = (h.cycles - start) / n;
        // The old adapter sat in WRITE_DRAIN for 31 cycles before it would look
        // at the next request, so it could never beat 33 cycles per word.
        expect(
          perWord,
          lessThan(10),
          reason: 'write stream took $perWord cycles per word',
        );
        await h.idle(120);
        expect(await h.busRead((n - 1) * 4), n - 1);
        await h.stop();
      });
    }

    test('a held burst is flushed before a read that needs it', () async {
      final h = _Harness(writeCombine: true);
      await h.start();
      await h.busWrite(0x0, 0xAAAA5555);
      expect(
        h.wideWrites,
        0,
        reason: 'the write is still held, no DRAM command yet',
      );
      expect(
        await h.busRead(0x0),
        0xAAAA5555,
        reason: 'the read must see the held bytes',
      );
      expect(h.wideWrites, 1, reason: 'the read forced exactly one flush');
      await h.stop();
    });

    test('a read to another burst does not disturb the held one', () async {
      final h = _Harness(writeCombine: true);
      await h.start();
      await h.busWrite(0x100, 0x11112222); // burst 0x10
      expect(await h.busRead(0x0), 0, reason: 'unrelated burst, never written');
      expect(h.wideWrites, 0, reason: 'an unrelated read must not flush');
      await h.idle(120);
      expect(h.wideWrites, 1, reason: 'the idle timeout lands the tail');
      expect(await h.busRead(0x100), 0x11112222);
      await h.stop();
    });

    test('a request held across the ACK is served once', () async {
      // What the CDC bridge in front of this adapter really does: it keeps
      // m_cyc/m_stb asserted through the ACK cycle and only drops them the
      // cycle after. Without the ACK guard in IDLE the adapter takes the same
      // request a second time, which doubles every DRAM command.
      final h = _Harness(writeCombine: false);
      await h.start();
      await h.busWriteHeld(0x0, 0x12345678, hold: 3);
      await h.idle(60);
      expect(h.wideWrites, 1, reason: 'one request must be one DRAM command');
      expect(await h.busRead(0x0), 0x12345678);
      await h.stop();
    });

    // The whole SoC-side DRAM path: CDC bridge (posted writes) in front of the
    // burst adapter, exactly as HarborDdr3 wires them.
    //
    // This is what lets a driver drop a timed spin after publishing an ADMA
    // descriptor. A posted write ACKs before it reaches DRAM, so the ACK alone
    // proves nothing. What DOES hold is ordering: the write and a following
    // read share one request FIFO and the adapter flushes a held burst that a
    // read needs, so a read-back can never see the pre-write value. A read is
    // therefore a correct barrier, and the driver does not have to guess a
    // cycle count.
    test(
      'a read-back is ordered behind a posted write (no timed spin)',
      () async {
        const aw = 24, dw = 32;
        final sClk = SimpleClockGenerator(50).clk;
        final mClk = SimpleClockGenerator(13).clk;
        final sReset = Logic(name: 's_reset')..inject(1);
        final mReset = Logic(name: 'm_reset')..inject(1);
        final sCyc = Logic(name: 's_cyc')..inject(0);
        final sWe = Logic(name: 's_we')..inject(0);
        final sAdr = Logic(name: 's_adr', width: aw)..inject(0);
        final sDatW = Logic(name: 's_dat_w', width: dw)..inject(0);
        final mStall = Logic(name: 'm_stall')..inject(0);
        final mAck = Logic(name: 'm_ack')..inject(0);
        final mAckAux = Logic(name: 'm_ack_aux', width: 4)..inject(0);
        final mData = Logic(name: 'm_data', width: 128)..inject(0);
        final acks = _AckPipe(mAck, mAckAux, mData);

        final cdc = HarborWishboneCdcFifoBridge(
          addressWidth: aw,
          dataWidth: dw,
          depth: 8,
          postedWrites: true,
        );
        cdc.input('s_clk').srcConnection! <= sClk;
        cdc.input('s_reset').srcConnection! <= sReset;
        cdc.input('s_cyc').srcConnection! <= sCyc;
        cdc.input('s_stb').srcConnection! <= Const(1);
        cdc.input('s_we').srcConnection! <= sWe;
        cdc.input('s_adr').srcConnection! <= sAdr;
        cdc.input('s_dat_w').srcConnection! <= sDatW;
        cdc.input('s_sel').srcConnection! <= Const(0xf, width: dw ~/ 8);
        cdc.input('m_clk').srcConnection! <= mClk;
        cdc.input('m_reset').srcConnection! <= mReset;

        final dut = Ddr3BurstAdapter(
          busAddrWidth: aw,
          ddrAddrWidth: aw,
          clk: mClk,
          reset: mReset,
          sCyc: cdc.output('m_cyc') & cdc.output('m_stb'),
          sStb: Const(1),
          sWe: cdc.output('m_we'),
          sAddr: cdc.output('m_adr'),
          sData: cdc.output('m_dat_w'),
          sSel: cdc.output('m_sel'),
          mStall: mStall,
          mAck: mAck,
          mAckAux: mAckAux,
          mData: mData,
        );
        cdc.input('m_ack').srcConnection! <= dut.output('s_ack');
        cdc.input('m_dat_r').srcConnection! <= dut.output('s_data_out');
        await cdc.build();
        await dut.build();

        // Wide controller mock: commits a write only if cyc survives the drain.
        final mem = <int, BigInt>{};
        final inflight = <Map<String, dynamic>>[];
        Simulator.setMaxSimTime(20000000);
        unawaited(Simulator.run());

        mClk.posedge.listen((_) {
          final cycVal = dut.output('m_cyc').value;
          if (!cycVal.isValid) return;
          final cyc = cycVal == LogicValue.one;
          if (cyc && dut.output('m_stb').value == LogicValue.one) {
            final addr = dut.output('m_addr').value.toInt();
            acks.accept(dut, () => mem[addr] ?? BigInt.zero);
            if (dut.output('m_we').value == LogicValue.one) {
              inflight.add({
                'addr': addr,
                'data': dut.output('m_data_out').value.toBigInt(),
                'sel': dut.output('m_sel').value.toInt(),
                'left': 4,
              });
            }
          }
          if (!cyc) {
            inflight.clear();
          } else {
            for (final w in [...inflight]) {
              w['left'] = (w['left'] as int) - 1;
              if ((w['left'] as int) > 0) continue;
              var mask = BigInt.zero;
              final sel = w['sel'] as int;
              for (var b = 0; b < 16; b++) {
                if ((sel >> b) & 1 == 1) mask |= BigInt.from(0xff) << (b * 8);
              }
              final a = w['addr'] as int;
              mem[a] =
                  ((mem[a] ?? BigInt.zero) & ~mask) |
                  ((w['data'] as BigInt) & mask);
              inflight.remove(w);
            }
          }
          acks.tick();
        });

        for (var i = 0; i < 6; i++) {
          await sClk.nextPosedge;
        }
        sReset.inject(0);
        mReset.inject(0);
        await sClk.nextPosedge;

        Future<void> wr(int addr, int data) async {
          sAdr.inject(addr);
          sDatW.inject(data);
          sWe.inject(1);
          sCyc.inject(1);
          var g = 0;
          while (cdc.output('s_ack').value != LogicValue.one) {
            await sClk.nextPosedge;
            if (++g > 2000) fail('write to 0x${addr.toRadixString(16)} hung');
          }
          sCyc.inject(0);
          await sClk.nextPosedge;
        }

        Future<int> rd(int addr) async {
          sAdr.inject(addr);
          sWe.inject(0);
          sCyc.inject(1);
          var g = 0;
          while (cdc.output('s_ack').value != LogicValue.one) {
            await sClk.nextPosedge;
            if (++g > 2000) fail('read from 0x${addr.toRadixString(16)} hung');
          }
          final v = cdc.output('s_dat_r').value.toInt();
          sCyc.inject(0);
          await sClk.nextPosedge;
          return v;
        }

        // The two descriptor words, published then read straight back with NO
        // delay in between. This is the driver's `drainCycles` window.
        await wr(0x40, 0x00001000); // desc[0] = buffer address
        await wr(0x44, 0x80000200); // desc[1] = length | end
        expect(
          await rd(0x40),
          0x00001000,
          reason: 'the read-back must not see the pre-write value',
        );
        expect(await rd(0x44), 0x80000200);

        // Re-arming the same descriptor for a following block is the case the
        // driver comment calls out as racing: back-to-back reads handing the
        // engine a stale descriptor.
        for (var blk = 1; blk <= 4; blk++) {
          await wr(0x40, 0x2000 + blk * 0x200);
          await wr(0x44, 0x80000200);
          expect(
            await rd(0x40),
            0x2000 + blk * 0x200,
            reason: 'block $blk re-armed the descriptor but read back stale',
          );
        }
        await Simulator.endSimulation();
      },
    );

    test('byte enables accumulate across a combined burst', () async {
      final h = _Harness(writeCombine: true);
      await h.start();
      // Three byte-writes into three different words of the same burst. Only
      // the selected bytes may reach DRAM.
      await h.busWrite(0x0, 0x000000AA, sel: 0x1);
      await h.busWrite(0x4, 0x0000BB00, sel: 0x2);
      await h.busWrite(0x8, 0xCC000000, sel: 0x8);
      await h.idle(120);
      expect(h.wideWrites, 1, reason: 'one burst, one command');
      expect(await h.busRead(0x0), 0x000000AA);
      expect(await h.busRead(0x4), 0x0000BB00);
      expect(await h.busRead(0x8), 0xCC000000);
      expect(await h.busRead(0xC), 0, reason: 'the unwritten word stays clear');
      await h.stop();
    });
  });

  group('write acks', () {
    // Each burst holds its burst address in every lane, so a read that takes
    // the wrong ack shows junk or another burst.
    void prefill(_Harness h, Iterable<int> bursts) {
      for (final b in bursts) {
        var v = BigInt.zero;
        for (var w = 0; w < 4; w++) {
          v |= BigInt.from(0x5A000000 | b) << (32 * w);
        }
        h.mem[b] = v;
      }
    }

    for (final combine in const [false, true]) {
      final mode = combine ? 'combining' : 'pass-through';
      for (final lat in const [3, 8]) {
        test(
          '$mode, latency $lat: a read right after a posted write',
          () async {
            final h = _Harness(writeCombine: combine, ackLatency: lat);
            prefill(h, [0x10, 0x20]);
            await h.start();
            await h.busWrite(0x000, 0x1234);
            expect(await h.busRead(0x100), 0x5A000010);
            expect(await h.busRead(0x200), 0x5A000020);
            await h.idle(120);
            expect(await h.busRead(0x000), 0x1234);
            expect(h.acks.writeAcks, greaterThan(0));
            await h.stop();
          },
        );
      }
    }

    test('a read while several writes are not acked yet', () async {
      final h = _Harness(writeCombine: false, ackLatency: 16);
      prefill(h, [0x40]);
      await h.start();
      for (var i = 0; i < 4; i++) {
        await h.busWrite(i * 0x10, 0xA0 + i);
      }
      expect(await h.busRead(0x404), 0x5A000040);
      for (var i = 0; i < 4; i++) {
        expect(await h.busRead(i * 0x10), 0xA0 + i);
      }
      expect(h.acks.writeAcks, 4);
      await h.stop();
    });

    for (final combine in const [false, true]) {
      final mode = combine ? 'combining' : 'pass-through';
      test('$mode: a read lost to a bus-side reset cannot complete '
          'the next read', () async {
        final h = _Harness(
          writeCombine: combine,
          ackLatency: 12,
          splitReset: true,
        );
        prefill(h, [0x10, 0x20]);
        await h.start();
        // The controller accepts the read, then only the bus side resets.
        h.sCyc.inject(1);
        h.sStb.inject(1);
        h.sWe.inject(0);
        h.sAddr.inject(0x100);
        await h.idle(4);
        expect(h.wideReads, 1);
        h.sCyc.inject(0);
        h.sStb.inject(0);
        h.reset.inject(1);
        await h.idle(2);
        h.reset.inject(0);
        await h.idle(1);
        // The old read's ACK arrives while this read waits.
        expect(await h.busRead(0x200), 0x5A000020);
        expect(await h.busRead(0x100), 0x5A000010);
        await h.stop();
      });
    }

    for (final combine in const [false, true]) {
      final mode = combine ? 'combining' : 'pass-through';
      test('$mode: random reads and writes in any order', () async {
        final h = _Harness(writeCombine: combine, ackLatency: 6);
        await h.start();
        final rng = Random(7);
        final model = <int, int>{};
        for (var i = 0; i < 300; i++) {
          final addr = rng.nextInt(16) * 4;
          if (rng.nextBool()) {
            final v = rng.nextInt(1 << 32);
            await h.busWrite(addr, v);
            model[addr] = v;
          } else {
            expect(
              await h.busRead(addr),
              model[addr] ?? 0,
              reason: 'op $i read 0x${addr.toRadixString(16)}',
            );
          }
        }
        expect(h.acks.writeAcks, greaterThan(0));
        await h.stop();
      });
    }
  });
}

/// Drives the adapter against a procedural mock of the wide controller side.
///
/// The mock reproduces the controller's abort rule: a write reaches DRAM only
/// if `m_cyc` stays asserted for [wrDrain] cycles after the command is
/// accepted. A write stream that lets `cyc` fall between words silently loses
/// data here, which is what makes the read-backs meaningful.
class _Harness {
  static const busAddrW = 24;
  static const ddrAddrW = 24;

  final bool writeCombine;

  /// Cycles the mock controller needs `m_cyc` held after it accepts a write.
  static const wrDrain = 4;

  final Logic clk;
  final Logic reset = Logic(name: 'reset')..inject(1);
  final Logic ctrlReset = Logic(name: 'ctrl_reset')..inject(1);
  final Logic sCyc = Logic()..inject(0);
  final Logic sStb = Logic()..inject(0);
  final Logic sWe = Logic()..inject(0);
  final Logic sAddr = Logic(width: busAddrW)..inject(0);
  final Logic sData = Logic(width: 32)..inject(0);
  final Logic sSel = Logic(width: 4)..inject(0);
  final Logic mStall = Logic()..inject(0);
  final Logic mAck = Logic()..inject(0);
  final Logic mAckAux = Logic(width: 4)..inject(0);
  final Logic mData = Logic(width: 128)..inject(0);
  late final _AckPipe acks;
  late final Ddr3BurstAdapter dut;

  /// Burst address -> 128-bit contents.
  final mem = <int, BigInt>{};

  /// Wide commands the controller accepted.
  int wideWrites = 0;
  int wideReads = 0;

  /// Clock cycles since the mock started.
  int cycles = 0;

  StreamSubscription<void>? _mock;

  _Harness({
    required this.writeCombine,
    int period = 10,
    int ackLatency = 3,
    bool splitReset = false,
  }) : clk = SimpleClockGenerator(period).clk {
    acks = _AckPipe(mAck, mAckAux, mData, latency: ackLatency);
    dut = Ddr3BurstAdapter(
      busAddrWidth: busAddrW,
      ddrAddrWidth: ddrAddrW,
      writeCombine: writeCombine,
      clk: clk,
      reset: reset,
      ctrlReset: splitReset ? ctrlReset : null,
      sCyc: sCyc,
      sStb: sStb,
      sWe: sWe,
      sAddr: sAddr,
      sData: sData,
      sSel: sSel,
      mStall: mStall,
      mAck: mAck,
      mAckAux: mAckAux,
      mData: mData,
    );
  }

  Future<void> start() async {
    await dut.build();

    final inflight = <Map<String, dynamic>>[];

    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());

    _mock = clk.posedge.listen((_) {
      cycles++;
      final cycVal = dut.output('m_cyc').value;
      if (!cycVal.isValid) return;
      final cyc = cycVal == LogicValue.one;

      if (cyc &&
          dut.output('m_stb').value == LogicValue.one &&
          mStall.value == LogicValue.zero) {
        final addr = dut.output('m_addr').value.toInt();
        acks.accept(dut, () => mem[addr] ?? BigInt.zero);
        if (dut.output('m_we').value == LogicValue.one) {
          wideWrites++;
          inflight.add({
            'addr': addr,
            'data': dut.output('m_data_out').value.toBigInt(),
            'sel': dut.output('m_sel').value.toInt(),
            'left': wrDrain,
          });
        } else {
          wideReads++;
        }
      }

      if (!cyc) {
        inflight.clear(); // the controller aborts on ~cyc
      } else {
        for (final w in [...inflight]) {
          w['left'] = (w['left'] as int) - 1;
          if ((w['left'] as int) > 0) continue;
          final addr = w['addr'] as int;
          final wdata = w['data'] as BigInt;
          final sel = w['sel'] as int;
          var mask = BigInt.zero;
          for (var b = 0; b < 16; b++) {
            if ((sel >> b) & 1 == 1) mask |= BigInt.from(0xff) << (b * 8);
          }
          mem[addr] = ((mem[addr] ?? BigInt.zero) & ~mask) | (wdata & mask);
          inflight.remove(w);
        }
      }

      acks.tick();
    });

    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    ctrlReset.inject(0);
    await clk.nextPosedge;
  }

  Future<void> busWrite(int addr, int data, {int sel = 0xF}) async {
    sCyc.inject(1);
    sStb.inject(1);
    sWe.inject(1);
    sAddr.inject(addr);
    sData.inject(data);
    sSel.inject(sel);
    var guard = 0;
    do {
      await clk.nextPosedge;
      if (++guard > 500)
        fail('timeout on write to 0x${addr.toRadixString(16)}');
    } while (dut.output('s_ack').value != LogicValue.one);
    sCyc.inject(0);
    sStb.inject(0);
    sWe.inject(0);
    await clk.nextPosedge;
  }

  /// Like [busWrite], but keeps the request on the port for [hold] more cycles
  /// after the ACK, the way the CDC bridge upstream does.
  Future<void> busWriteHeld(
    int addr,
    int data, {
    int sel = 0xF,
    int hold = 2,
  }) async {
    sCyc.inject(1);
    sStb.inject(1);
    sWe.inject(1);
    sAddr.inject(addr);
    sData.inject(data);
    sSel.inject(sel);
    var guard = 0;
    do {
      await clk.nextPosedge;
      if (++guard > 500) fail('timeout on held write');
    } while (dut.output('s_ack').value != LogicValue.one);
    for (var i = 0; i < hold; i++) {
      await clk.nextPosedge;
    }
    sCyc.inject(0);
    sStb.inject(0);
    sWe.inject(0);
    await clk.nextPosedge;
  }

  Future<int> busRead(int addr) async {
    sCyc.inject(1);
    sStb.inject(1);
    sWe.inject(0);
    sAddr.inject(addr);
    var guard = 0;
    do {
      await clk.nextPosedge;
      if (++guard > 500)
        fail('timeout on read from 0x${addr.toRadixString(16)}');
    } while (dut.output('s_ack').value != LogicValue.one);
    final v = dut.output('s_data_out').value.toInt();
    sCyc.inject(0);
    sStb.inject(0);
    await clk.nextPosedge;
    return v;
  }

  Future<void> idle(int n) async {
    for (var i = 0; i < n; i++) {
      await clk.nextPosedge;
    }
  }

  Future<void> stop() async {
    await _mock?.cancel();
    await Simulator.endSimulation();
  }
}

/// The controller's ack pipe. Every accepted command, read or write, is acked
/// [latency] cycles later in command order, and the ack echoes the command's
/// `aux`. A write ack carries junk on the data bus.
class _AckPipe {
  static final junk = BigInt.parse(
    'BADBADBADBADBADBADBADBADBADBADBA',
    radix: 16,
  );

  final Logic ack;
  final Logic aux;
  final Logic data;
  final int latency;
  final _queue = <(List<int>, int, BigInt Function())>[];

  /// Write commands that got an ack.
  int writeAcks = 0;

  _AckPipe(this.ack, this.aux, this.data, {this.latency = 3});

  /// Queue the ack for the command [dut] drives now. [readValue] gives the
  /// burst contents when a read ack fires.
  void accept(Ddr3BurstAdapter dut, BigInt Function() readValue) {
    final we = dut.output('m_we').value == LogicValue.one;
    final tag = dut.output('m_aux').value.toInt();
    _queue.add(([latency], tag, we ? () => junk : readValue));
    if (we) writeAcks++;
  }

  /// Advance one cycle. Call once per posedge, after [accept].
  void tick() {
    ack.inject(0);
    for (final e in _queue) {
      e.$1[0]--;
    }
    if (_queue.isNotEmpty && _queue.first.$1[0] <= 0) {
      final e = _queue.removeAt(0);
      data.inject(e.$3());
      aux.inject(e.$2);
      ack.inject(1);
    }
  }
}
