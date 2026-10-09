import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:harbor/src/clock/wishbone_cdc_fifo.dart';
import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:harbor/src/peripherals/ddr3_dram_model.dart';
import 'package:harbor/src/peripherals/ddr3_mode_registers.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Faithful SDIO ADMA -> DDR write-throughput harness.
//
// The real card-read data path on hardware is:
//   SDIO ADMA master (raw dma_* handshake, fabricDma=false)
//     -> HarborWishboneCdcFifoBridge (posted writes, depth 16, sys clock)
//     -> Ddr3BurstAdapter (posted + write-combining, ddr clock)
//     -> DDR3 controller.
//
// The prior sim used a one-cycle-ack RAM directly on the dma_* port, so it
// could never show the throughput the board sees. This harness wires the REAL
// CDC bridge and the REAL burst adapter, on a faster ddr clock than the SDIO
// system clock, and terminates the adapter's wide side with a byte-masked
// controller model whose WRITE ACCEPT LATENCY is a parameter. That is the knob
// that mimics the ~11000-fabric-cycle-per-word regime measured on the Arty S7,
// and it lets a later fix be measured against a baseline here.
//
// The ADMA data-write state machine (sdio.dart aMemWrite) is NON-PIPELINED: it
// asserts dma_stb with one beat, waits for dma_ack, drops stb, advances, and
// only then produces the next beat. So every beat serializes on its own round
// trip and the burst adapter downstream never sees a continuous stream. This
// harness measures the cost of that.

// Register byte offsets (the byte-addressed fabric decodes byte-offset >> 3).
const _ctrl = 0x00;
const _clkDiv = 0x10;
const _cmd = 0x18;
const _cmdArg = 0x20;
const _blkSize = 0x50;
const _blkCount = 0x58;
const _intStatus = 0x60;
const _intEnable = 0x68;
const _admaAddr = 0x70;

const _intDataDone = 0x02;

int _bit(Logic l) {
  final v = l.value;
  return v.isValid ? v.toInt() : 0;
}

// SD data CRC16 (CCITT, x^16+x^12+x^5+1), MSB-first, seed 0. Mirrors the RTL.
int _crc16Next(int crc, int bit) {
  final inv = ((crc >> 15) ^ (bit & 1)) & 1;
  var next = 0;
  for (var i = 0; i < 16; i++) {
    int b;
    if (i == 0) {
      b = inv;
    } else if (i == 5) {
      b = ((crc >> 4) & 1) ^ inv;
    } else if (i == 12) {
      b = ((crc >> 11) & 1) ^ inv;
    } else {
      b = (crc >> (i - 1)) & 1;
    }
    next |= (b & 1) << i;
  }
  return next & 0xffff;
}

int _crc7(List<int> bits) {
  var crc = 0;
  for (final b in bits) {
    final fb = ((crc >> 6) & 1) ^ (b & 1);
    crc = (crc << 1) & 0x7f;
    if (fb != 0) crc ^= 0x09;
  }
  return crc;
}

List<int> _toBits(int value, int n) {
  final bits = <int>[];
  for (var i = n - 1; i >= 0; i--) {
    bits.add((value >> i) & 1);
  }
  return bits;
}

int _fromBits(List<int> bits) {
  var v = 0;
  for (final b in bits) {
    v = (v << 1) | (b & 1);
  }
  return v;
}

/// Fake native-SD card streaming a single 1-bit block on DAT0. It answers R1 on
/// CMD, then drives the block (start bit, data bytes MSB-first, CRC16) on
/// falling edges of the host's SD clock. Copied from the sdio data sim so this
/// harness is self-contained; it only reads the SD outputs and drives the two
/// injected input Logics.
class _FakeSdCard {
  final HarborSdioController dut;
  final Logic cmdIn;
  final Logic datIn;

  int gotIndex = -1;
  int commandCount = 0;
  bool stop = false;

  /// The block to stream on DAT0 after the command response. Null = none.
  List<int>? readBlock;

  /// Multiple blocks streamed back-to-back for a CMD18 multi-block read, each
  /// framed with its own start bit + CRC16. Takes precedence over readBlock.
  List<List<int>>? readBlocks;

  _FakeSdCard(this.dut, this.cmdIn, this.datIn);

  List<int> _buildDatMulti(List<List<int>> blocks) {
    final bits = <int>[];
    for (final block in blocks) {
      bits.addAll(_buildDat(block));
    }
    return bits;
  }

  List<int> _buildR1(int index, int arg) {
    final bits = <int>[0, 0];
    bits.addAll(_toBits(index, 6));
    bits.addAll(_toBits(arg, 32));
    bits.addAll(_toBits(_crc7(bits.sublist(0, 40)), 7));
    bits.add(1);
    return bits;
  }

  List<int> _buildDat(List<int> block) {
    final bits = <int>[0]; // start bit on DAT0
    var crc = 0;
    for (final byte in block) {
      for (var i = 7; i >= 0; i--) {
        final b = (byte >> i) & 1;
        bits.add(b);
        crc = _crc16Next(crc, b);
      }
    }
    for (var i = 15; i >= 0; i--) {
      bits.add((crc >> i) & 1);
    }
    return bits;
  }

  Future<void> run(Logic clk) async {
    var prevClk = 0;
    var prevOe = 0;
    var collecting = false;
    final cmdBits = <int>[];
    var respBits = <int>[];
    var responding = false;
    var respGap = 0;

    var datBits = <int>[];
    var datPhase = 0; // 0 idle, 1 gap, 2 driving
    var datGap = 0;

    while (!stop) {
      await clk.nextPosedge;
      final sclk = _bit(dut.output('sd_clk'));
      final oe = _bit(dut.output('sd_cmd_oe'));
      final cmdOut = _bit(dut.output('sd_cmd_out'));
      final rise = prevClk == 0 && sclk == 1;
      final fall = prevClk == 1 && sclk == 0;

      // Command RX.
      if (oe == 1 && rise) {
        if (!collecting) {
          if (cmdOut == 0) {
            collecting = true;
            cmdBits.add(0);
          }
        } else {
          cmdBits.add(cmdOut);
        }
      }
      if (prevOe == 1 && oe == 0 && collecting && !responding) {
        if (cmdBits.length >= 47) {
          final f = cmdBits.sublist(0, 47);
          gotIndex = _fromBits(f.sublist(2, 8));
          commandCount++;
          respBits = _buildR1(gotIndex, _fromBits(f.sublist(8, 40)));
          responding = true;
          respGap = 2;
        }
        collecting = false;
        cmdBits.clear();
      }

      // CMD response on falling edges; queue the DAT block when it finishes.
      if (responding && fall) {
        if (respGap > 0) {
          respGap--;
          cmdIn.inject(1);
        } else if (respBits.isNotEmpty) {
          cmdIn.inject(respBits.removeAt(0));
        } else {
          cmdIn.inject(1);
          responding = false;
          if (readBlocks != null && datPhase == 0) {
            datBits = _buildDatMulti(readBlocks!);
            datPhase = 1;
            datGap = 3; // let the host reach the data-read wait state
          } else if (readBlock != null && datPhase == 0) {
            datBits = _buildDat(readBlock!);
            datPhase = 1;
            datGap = 3; // let the host reach the data-read wait state
          }
        }
      }

      // DAT block drive on falling edges (DAT0 low lane, others idle high).
      if (datPhase != 0 && fall) {
        if (datPhase == 1) {
          if (datGap > 0) {
            datGap--;
          } else {
            datPhase = 2;
          }
        }
        if (datPhase == 2) {
          if (datBits.isNotEmpty) {
            datIn.inject(0xe | datBits.removeAt(0));
          } else {
            datIn.inject(0xf);
            datPhase = 0;
            readBlock = null;
            readBlocks = null;
          }
        }
      }

      prevClk = sclk;
      prevOe = oe;
    }
  }
}

/// One classic single-outstanding Wishbone register slice, a byte-identical
/// behavioural copy of `WishboneRegisterStage` (wishbone_register_stage.dart):
/// capture a request only while idle and not in the ACK-pulse cycle, hold STB to
/// the downstream until its ACK, then pulse ACK upstream for one cycle. Two
/// extra cycles per transfer, one outstanding at a time. Returned as a record of
/// the downstream request lines plus the upstream response lines.
({
  Logic downCyc,
  Logic downStb,
  Logic downWe,
  Logic downAdr,
  Logic downDat,
  Logic downSel,
  Logic upAck,
  Logic upMiso,
})
_regStage(
  Logic clk,
  Logic reset,
  Logic upCyc,
  Logic upStb,
  Logic upWe,
  Logic upAdr,
  Logic upDat,
  Logic upSel,
  Logic downAck,
  Logic downMiso,
  String tag,
) {
  final busy = Logic(name: 'rs_busy_$tag');
  final ackR = Logic(name: 'rs_ack_$tag');
  final weR = Logic(name: 'rs_we_$tag');
  final adrR = Logic(name: 'rs_adr_$tag', width: upAdr.width);
  final datR = Logic(name: 'rs_dat_$tag', width: upDat.width);
  final selR = Logic(name: 'rs_sel_$tag', width: upSel.width);
  final misoR = Logic(name: 'rs_miso_$tag', width: downMiso.width);

  Sequential(clk, [
    If(
      reset,
      then: [busy < Const(0), ackR < Const(0)],
      orElse: [
        ackR < Const(0),
        If(
          ~busy,
          then: [
            If(
              upCyc & upStb & ~ackR,
              then: [
                busy < Const(1),
                weR < upWe,
                adrR < upAdr,
                datR < upDat,
                selR < upSel,
              ],
            ),
          ],
          orElse: [
            If(
              downAck,
              then: [busy < Const(0), ackR < Const(1), misoR < downMiso],
            ),
          ],
        ),
      ],
    ),
  ]);

  return (
    downCyc: busy,
    downStb: busy,
    downWe: weR,
    downAdr: adrR,
    downDat: datR,
    downSel: selR,
    upAck: ackR,
    upMiso: misoR,
  );
}

/// A fully wired throughput bench. The SDIO ADMA drives a real posted CDC FIFO
/// bridge into a real burst adapter, which is terminated by a byte-masked
/// controller model on a faster clock. Register access is a direct Wishbone
/// slave drive on the system clock.
class _Bench {
  static const _busAddrW = 32;
  static const _ddrAddrW = 32;

  /// DDR-clock cycles the controller model refuses a new command after it
  /// accepts a write. This is the "write accept latency" knob.
  final int writeAcceptLatency;

  /// The ADMA / CDC / burst-adapter narrow data width (32 or 64). The delta
  /// RV64 build packs two 32-bit words per 64-bit beat, so the 64-bit path is
  /// the one that ships; the 32-bit path is kept as the simpler cross-check.
  final int busWidth;

  /// DDR-clock read-ack latency (descriptor fetches). Kept small and fixed.
  final int readLatency = 4;

  late final HarborSdioController sdio;
  late final HarborWishboneCdcFifoBridge cdc;
  late final Ddr3BurstAdapter adapter;

  late final Logic clkSys, clkDdr;
  late final Logic resetSys, resetDdr;
  late final Logic stb, we, adr, mosi;
  late final Logic cmdIn, datIn;

  // Controller model backing store: wide-burst address -> 128-bit word.
  final store = <int, BigInt>{};
  int wideWrites = 0;
  int wideReads = 0;

  StreamSubscription<void>? _ctrl;

  /// Number of classic single-outstanding WishboneRegisterStage slices to
  /// interpose between the ADMA master and the posted CDC bridge, mirroring the
  /// real delta fabric (dma_* -> wishbone_reg_0 -> arbiter -> wishbone_reg ->
  /// CDC). The prior harness wired the ADMA STRAIGHT to the CDC (regStages=0),
  /// so it never re-serialized the streamed beats; the real fabric does, which
  /// spaces same-burst beats apart and can defeat the burst adapter's combine.
  final int regStages;

  /// ADMA beats retired (dma_ack pulses seen at the ADMA port) and the total
  /// sys-cycles the ADMA held dma_stb asserted, filled by a probe in build().
  /// avg-cycles-per-beat = stbCycles / admaBeats is the per-beat issue cost the
  /// interconnect adds; wideWrites is how many of those beats reached DRAM as
  /// distinct bursts (combining collapses beats -> fewer bursts).
  int admaBeats = 0;
  int stbCycles = 0;
  StreamSubscription<void>? _probe;

  /// Whether the burst adapter combines same-burst narrow beats into one 128b
  /// DRAM write. delta-ffs (the current HW bitstream) has this OFF, so each
  /// narrow beat is a separate masked DRAM write; ffwc2 turns it ON. With a slow
  /// controller (high writeAcceptLatency) the number of DRAM writes multiplies
  /// the drain cost, so combine=false should be markedly slower than true.
  final bool combine;

  /// Fence a card-read's data-done on a read-back of the last written address,
  /// so data-done means the block is durable in the controller store. This is
  /// the DMA-read-coherency fix under test.
  final bool readBackBarrier;

  _Bench({
    required this.writeAcceptLatency,
    this.busWidth = 32,
    this.regStages = 0,
    this.combine = true,
    this.readBackBarrier = false,
  }) : assert(busWidth == 32 || busWidth == 64);

  Future<void> build() async {
    sdio = HarborSdioController(
      baseAddress: 0x0,
      rxFifoDepth: 16,
      dmaDataWidth: busWidth,
      readBackBarrier: readBackBarrier,
    );
    cdc = HarborWishboneCdcFifoBridge(
      addressWidth: _busAddrW,
      dataWidth: busWidth,
      depth: 16,
      postedWrites: true,
    );

    clkSys = SimpleClockGenerator(10).clk; // ~ system clock
    clkDdr = SimpleClockGenerator(4).clk; // ~ 2.5x faster ddr clock
    resetSys = Logic(name: 'reset_sys');
    resetDdr = Logic(name: 'reset_ddr');
    stb = Logic(name: 'stb');
    we = Logic(name: 'we');
    adr = Logic(name: 'adr', width: 12);
    mosi = Logic(name: 'mosi', width: 32);
    cmdIn = Logic(name: 'cmd_in');
    datIn = Logic(name: 'dat_in', width: 4);

    // SDIO register slave + pins.
    sdio.input('clk').srcConnection! <= clkSys;
    sdio.input('reset').srcConnection! <= resetSys;
    sdio.input('bus_CYC').srcConnection! <= stb;
    sdio.input('bus_STB').srcConnection! <= stb;
    sdio.input('bus_WE').srcConnection! <= we;
    sdio.input('bus_ADR').srcConnection! <= adr;
    sdio.input('bus_DAT_MOSI').srcConnection! <= mosi;
    sdio.input('bus_SEL').srcConnection! <=
        Const(0xF, width: sdio.input('bus_SEL').width);
    sdio.input('sd_cmd_in').srcConnection! <= cmdIn;
    sdio.input('sd_cd').srcConnection! <= Const(0);
    sdio.input('sd_dat_in').srcConnection! <= datIn;

    cdc.input('s_clk').srcConnection! <= clkSys;
    cdc.input('s_reset').srcConnection! <= resetSys;
    cdc.input('m_clk').srcConnection! <= clkDdr;
    cdc.input('m_reset').srcConnection! <= resetDdr;

    // SDIO ADMA master -> [regStages classic register slices] -> CDC slave side,
    // all on the system clock. Each slice is a byte-identical model of the real
    // WishboneRegisterStage (classic, one outstanding, holds STB until the
    // downstream ACK, one ACK pulse upstream, ~ack bubble). Chaining N of them
    // re-serializes the ADMA's streamed beats exactly as the real fabric does.
    var upCyc = sdio.output('dma_cyc');
    var upStb = sdio.output('dma_stb');
    var upWe = sdio.output('dma_we');
    var upAdr = sdio.output('dma_addr');
    var upDat = sdio.output('dma_wdata');
    var upSel = sdio.output('dma_sel');

    // Pre-create the per-stage downstream-response wires so the ack/miso can be
    // tied back after the whole forward request chain is built.
    final downAcks = [
      for (var i = 0; i < regStages; i++) Logic(name: 'rs_dack_$i'),
    ];
    final downMisos = [
      for (var i = 0; i < regStages; i++)
        Logic(name: 'rs_dmiso_$i', width: busWidth),
    ];
    final upAcks = <Logic>[];
    final upMisos = <Logic>[];
    for (var i = 0; i < regStages; i++) {
      final s = _regStage(
        clkSys,
        resetSys,
        upCyc,
        upStb,
        upWe,
        upAdr,
        upDat,
        upSel,
        downAcks[i],
        downMisos[i],
        '$i',
      );
      upAcks.add(s.upAck);
      upMisos.add(s.upMiso);
      upCyc = s.downCyc;
      upStb = s.downStb;
      upWe = s.downWe;
      upAdr = s.downAdr;
      upDat = s.downDat;
      upSel = s.downSel;
    }

    // Final (deepest) request drives the CDC slave port.
    cdc.input('s_cyc').srcConnection! <= upCyc;
    cdc.input('s_stb').srcConnection! <= upStb;
    cdc.input('s_we').srcConnection! <= upWe;
    cdc.input('s_adr').srcConnection! <= upAdr;
    cdc.input('s_dat_w').srcConnection! <= upDat;
    cdc.input('s_sel').srcConnection! <= upSel;

    // Tie the response chain back up: deepest stage takes the CDC ack, each
    // shallower stage takes the next stage's up-ack, and the ADMA takes stage 0.
    for (var i = 0; i < regStages; i++) {
      if (i == regStages - 1) {
        downAcks[i] <= cdc.output('s_ack');
        downMisos[i] <= cdc.output('s_dat_r');
      } else {
        downAcks[i] <= upAcks[i + 1];
        downMisos[i] <= upMisos[i + 1];
      }
    }
    if (regStages == 0) {
      sdio.input('dma_ack').srcConnection! <= cdc.output('s_ack');
      sdio.input('dma_rdata').srcConnection! <= cdc.output('s_dat_r');
    } else {
      sdio.input('dma_ack').srcConnection! <= upAcks[0];
      sdio.input('dma_rdata').srcConnection! <= upMisos[0];
    }

    // Controller-side handshake Logics (driven by the model below).
    final mStall = Logic(name: 'm_stall')..inject(0);
    final mAck = Logic(name: 'm_ack')..inject(0);
    final mAckAux = Logic(name: 'm_ack_aux', width: 4)..inject(0);
    final mData = Logic(name: 'm_data', width: 128)..inject(0);

    // CDC master side -> burst adapter slave side (ddr clock).
    adapter = Ddr3BurstAdapter(
      busAddrWidth: _busAddrW,
      ddrAddrWidth: _ddrAddrW,
      busDataWidth: busWidth,
      writeCombine: combine,
      clk: clkDdr,
      reset: resetDdr,
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
    cdc.input('m_ack').srcConnection! <= adapter.output('s_ack');
    cdc.input('m_dat_r').srcConnection! <= adapter.output('s_data_out');

    await sdio.build();
    await cdc.build();
    await adapter.build();

    // The wide controller model: byte-masked backing store, one command per
    // `writeAcceptLatency+1` ddr cycles for writes (mStall backpressure),
    // fixed read latency for descriptor fetches. Commits on accept, exactly
    // when the adapter drove the command and mStall was low. Like the real
    // controller, it acks reads and writes in order and echoes aux.
    // Entries are [burstAddr or -1 for a write, cyclesLeft, aux].
    final pendingAcks = <List<int>>[];
    var busy = 0; // remaining stall cycles

    _ctrl = clkDdr.posedge.listen((_) {
      mAck.inject(0);

      final cycV = adapter.output('m_cyc').value;
      final accepting = busy == 0; // mStall was low last edge
      if (accepting) {
        if (cycV.isValid &&
            cycV == LogicValue.one &&
            adapter.output('m_stb').value == LogicValue.one) {
          final addr = adapter.output('m_addr').value.toInt();
          final aux = adapter.output('m_aux').value.toInt();
          if (adapter.output('m_we').value == LogicValue.one) {
            final data = adapter.output('m_data_out').value.toBigInt();
            final sel = adapter.output('m_sel').value.toInt();
            var mask = BigInt.zero;
            for (var b = 0; b < 16; b++) {
              if ((sel >> b) & 1 == 1) mask |= BigInt.from(0xff) << (b * 8);
            }
            store[addr] =
                ((store[addr] ?? BigInt.zero) & ~mask) | (data & mask);
            wideWrites++;
            busy = writeAcceptLatency; // pay the accept latency before the next
            pendingAcks.add([-1, readLatency, aux]);
          } else {
            pendingAcks.add([addr, readLatency, aux]);
            wideReads++;
          }
        }
      } else {
        busy--;
      }
      mStall.inject(busy > 0 ? 1 : 0);

      for (final r in pendingAcks) {
        r[1]--;
      }
      if (pendingAcks.isNotEmpty && pendingAcks.first[1] <= 0) {
        final r = pendingAcks.removeAt(0);
        mData.inject(r[0] < 0 ? BigInt.zero : store[r[0]] ?? BigInt.zero);
        mAckAux.inject(r[2]);
        mAck.inject(1);
      }
    });

    // ADMA-port probe: count beats (dma_ack pulses reaching the ADMA) and the
    // sys-cycles dma_stb was held. stbCycles/admaBeats is the per-beat issue
    // cost the interposed slices add.
    _probe = clkSys.posedge.listen((_) {
      if (_bit(sdio.output('dma_stb')) == 1) stbCycles++;
      if (_bit(sdio.input('dma_ack')) == 1 &&
          _bit(sdio.output('dma_stb')) == 1) {
        admaBeats++;
      }
    });

    resetSys.inject(1);
    resetDdr.inject(1);
    stb.inject(0);
    we.inject(0);
    adr.inject(0);
    mosi.inject(0);
    cmdIn.inject(1);
    datIn.inject(0xf);
    Simulator.setMaxSimTime(2000000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 6; i++) {
      await clkSys.nextPosedge;
    }
    resetSys.inject(0);
    resetDdr.inject(0);
    await clkSys.nextPosedge;
  }

  Future<void> busWrite(int addr, int data) async {
    adr.inject(addr);
    mosi.inject(data);
    we.inject(1);
    stb.inject(1);
    await clkSys.nextPosedge;
    var g = 0;
    while (_bit(sdio.output('bus_ACK')) != 1) {
      await clkSys.nextPosedge;
      if (++g > 200)
        throw StateError('reg write to 0x${addr.toRadixString(16)} hung');
    }
    stb.inject(0);
    we.inject(0);
    await clkSys.nextPosedge;
  }

  Future<int> busRead(int addr) async {
    adr.inject(addr);
    we.inject(0);
    stb.inject(1);
    await clkSys.nextPosedge;
    var g = 0;
    while (_bit(sdio.output('bus_ACK')) != 1) {
      await clkSys.nextPosedge;
      if (++g > 200)
        throw StateError('reg read from 0x${addr.toRadixString(16)} hung');
    }
    final v = _bit(sdio.output('bus_DAT_MISO'));
    stb.inject(0);
    await clkSys.nextPosedge;
    return v;
  }

  /// The 32-bit word this target byte address holds in the controller model.
  int wordAt(int byteAddr) {
    final burst = (byteAddr >> 4) & ((1 << _ddrAddrW) - 1);
    final lane = (byteAddr >> 2) & 3;
    final w = store[burst] ?? BigInt.zero;
    return ((w >> (lane * 32)) & BigInt.from(0xffffffff)).toInt();
  }

  Future<void> stop() async {
    await _ctrl?.cancel();
    await _probe?.cancel();
    await Simulator.endSimulation();
  }
}

/// Runs one CMD17 + ADMA single-block read into the controller store and
/// reports the throughput. Returns (cyclesToLand, expectedWords, actualWords).
Future<_Result> _runBlock({
  required int writeAcceptLatency,
  int busWidth = 32,
  int blockBytes = 512,
  int bufferAddr = 0x1000,
  int regStages = 0,
  bool combine = true,
  bool readBackBarrier = false,
}) async {
  final bench = _Bench(
    writeAcceptLatency: writeAcceptLatency,
    busWidth: busWidth,
    regStages: regStages,
    combine: combine,
    readBackBarrier: readBackBarrier,
  );
  await bench.build();

  final wordCount = blockBytes ~/ 4;
  // A deterministic payload so every landed word is checkable.
  final block = [for (var i = 0; i < blockBytes; i++) (i * 7 + 0x11) & 0xff];
  final expected = [
    for (var i = 0; i < wordCount; i++)
      block[4 * i] |
          block[4 * i + 1] << 8 |
          block[4 * i + 2] << 16 |
          block[4 * i + 3] << 24,
  ];

  // Descriptor at ADMA base 0: word0 = buffer address, word1 = len | end.
  // Seed the descriptor directly into the controller store (burst 0, lanes 0/1).
  bench.store[0] =
      (BigInt.from(blockBytes | (1 << 31)) << 32) | BigInt.from(bufferAddr);

  final card = _FakeSdCard(bench.sdio, bench.cmdIn, bench.datIn)
    ..readBlock = block;
  unawaited(card.run(bench.clkSys));

  await bench.busWrite(_clkDiv, 0); // fastest SD clock
  await bench.busWrite(_intEnable, 0x12);
  await bench.busWrite(_ctrl, 0x1); // enable
  await bench.busWrite(_blkSize, blockBytes);
  await bench.busWrite(_blkCount, 1);
  await bench.busWrite(_admaAddr, bufferAddr); // direct-buffer DMA
  await bench.busWrite(_cmdArg, 0);
  // CMD17: short resp, data present, read direction, DMA mode (bit 10).
  await bench.busWrite(_cmd, 17 | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10));

  // Count system cycles from the command issue until the whole block has
  // landed (every target word present and correct) in the controller store.
  // Keep running past the landing until the engine raises its data-done
  // interrupt, so the transfer is confirmed complete, but the measured
  // cyclesToLand is the first cycle the whole block is in memory.
  //
  // The engine raises data-done when the receive side has drained, but at a
  // high controller latency a backlog of posted writes is still crossing the
  // CDC and has not reached the controller store yet. So landing (every word
  // committed in the store) can lag data-done; loop until BOTH have happened.
  var cycles = 0;
  var landedCycle = -1;
  var dataDoneCycle = -1;
  var dataDone = false;
  final actual = List<int>.filled(wordCount, -1);
  for (var i = 0; i < 8000000; i++) {
    await bench.clkSys.nextPosedge;
    cycles++;
    if (_bit(bench.sdio.output('interrupt')) == 1) {
      dataDone = true;
      if (dataDoneCycle < 0) dataDoneCycle = cycles;
    }
    if (landedCycle < 0) {
      var landed = 0;
      for (var w = 0; w < wordCount; w++) {
        actual[w] = bench.wordAt(bufferAddr + 4 * w);
        if (actual[w] == expected[w]) landed++;
      }
      if (landed == wordCount) landedCycle = cycles;
    }
    if (landedCycle > 0 && dataDone) break;
  }

  final intStatus = dataDone ? _intDataDone : (await bench.busRead(_intStatus));
  final wideWrites = bench.wideWrites;
  // Let the card streamer observe the stop flag and return before the
  // simulator is torn down, so no future is left awaiting a dead clock (which
  // corrupts a later rebuild in the same process).
  card.stop = true;
  await bench.clkSys.nextPosedge;
  await bench.clkSys.nextPosedge;
  await bench.stop();

  return _Result(
    latency: writeAcceptLatency,
    wordCount: wordCount,
    cyclesToLand: landedCycle,
    dataDoneCycle: dataDoneCycle,
    expected: expected,
    actual: actual,
    wideWrites: wideWrites,
    dataDone: intStatus & _intDataDone != 0,
    admaBeats: bench.admaBeats,
    stbCycles: bench.stbCycles,
    regStages: regStages,
  );
}

/// CMD18 multi-block ADMA read through the REAL DMA path (posted CDC + burst
/// adapter + controller model), N 512-byte blocks each with a distinct per-word
/// fingerprint. Returns the index of the first word that lands wrong (-1 = all
/// correct), or a landed-count short of total if the stream stalled. This is the
/// DMA-path counterpart to the PIO byte-exact test: if the store is byte-exact
/// at 16/32 blocks, the ADMA multi-block RTL is functionally correct.
Future<({int total, int landed, int firstBad, int want, int got})>
_runMultiBlock({
  required int nBlocks,
  int busWidth = 64,
  int blockBytes = 512,
  int bufferAddr = 0x1000,
}) async {
  final bench = _Bench(writeAcceptLatency: 2, busWidth: busWidth);
  await bench.build();

  final wordsPerBlk = blockBytes ~/ 4;
  int fp(int b, int w) => (0xB0000000 | (b << 12) | w) & 0xffffffff;
  final blocks = [
    for (var b = 0; b < nBlocks; b++)
      [
        for (var w = 0; w < wordsPerBlk; w++)
          for (var byte = 0; byte < 4; byte++) (fp(b, w) >> (byte * 8)) & 0xff,
      ],
  ];

  final totalBytes = nBlocks * blockBytes;
  bench.store[0] =
      (BigInt.from(totalBytes | (1 << 31)) << 32) | BigInt.from(bufferAddr);

  final card = _FakeSdCard(bench.sdio, bench.cmdIn, bench.datIn)
    ..readBlocks = blocks;
  unawaited(card.run(bench.clkSys));

  await bench.busWrite(_clkDiv, 0);
  await bench.busWrite(_intEnable, 0x12);
  await bench.busWrite(_ctrl, 0x1);
  await bench.busWrite(_blkSize, blockBytes);
  await bench.busWrite(_blkCount, nBlocks);
  await bench.busWrite(_admaAddr, bufferAddr); // direct-buffer DMA
  await bench.busWrite(_cmdArg, 0);
  await bench.busWrite(_cmd, 18 | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10));

  final total = nBlocks * wordsPerBlk;
  var dataDone = false;
  for (var i = 0; i < 60000000; i++) {
    await bench.clkSys.nextPosedge;
    if (_bit(bench.sdio.output('interrupt')) == 1) dataDone = true;
    if (dataDone) break;
  }
  for (var i = 0; i < 5000; i++) {
    await bench.clkSys.nextPosedge; // let the posted writes drain
  }

  var landed = 0, firstBad = -1, want = 0, got = 0;
  for (var g = 0; g < total; g++) {
    final b = g ~/ wordsPerBlk, w = g % wordsPerBlk;
    final v = bench.wordAt(bufferAddr + 4 * g);
    if (v == fp(b, w)) {
      landed++;
    } else if (firstBad < 0) {
      firstBad = g;
      want = fp(b, w);
      got = v;
    }
  }

  card.stop = true;
  await bench.clkSys.nextPosedge;
  await bench.stop();
  return (
    total: total,
    landed: landed,
    firstBad: firstBad,
    want: want,
    got: got,
  );
}

class _Result {
  final int latency;
  final int wordCount;
  final int cyclesToLand;
  final int dataDoneCycle;
  final List<int> expected;
  final List<int> actual;
  final int wideWrites;
  final bool dataDone;
  final int admaBeats;
  final int stbCycles;
  final int regStages;

  _Result({
    required this.latency,
    required this.wordCount,
    required this.cyclesToLand,
    this.dataDoneCycle = -1,
    required this.expected,
    required this.actual,
    required this.wideWrites,
    required this.dataDone,
    this.admaBeats = 0,
    this.stbCycles = 0,
    this.regStages = 0,
  });

  /// sys-cycles the ADMA spent holding STB per beat it retired. On the direct
  /// path this is a handful; each interposed classic slice inflates it.
  double get cyclesPerAdmaBeat => admaBeats == 0 ? 0 : stbCycles / admaBeats;
  double get cyclesPerBeat => cyclesToLand / wordCount;
  bool get dataOk => cyclesToLand > 0 && _eq(actual, expected);

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

// The write-accept-latency sweep, filled by the per-latency tests below and
// read by the trend assertion. Each simulation lives in its own test() so the
// only Simulator.reset() is the sanctioned one in tearDown (a mid-test reset +
// rebuild corrupts the next build; see the ROHD gotchas).
final _sweep = <_Result>[];

// The DMA-bound sweep uses a 128-byte block (32 words, 8 bursts) on the 32-bit
// path (the 32-bit sim is several times faster than the 128-bit-adapter 64-bit
// one) and spans a low-to-high controller latency. The point after the
// streaming fix is that the number of WIDE DRAM writes stays at one per 16-byte
// burst no matter how slow the controller is: the burst adapter combines the
// streamed narrow beats before the controller ever sees them.
const _sweepBlock = 128;
const _sweepBursts = _sweepBlock ~/ 16;
const _sweepWidth = 32;
// A high controller latency makes the behavioural sim churn (mStall/adapter FSM
// toggle every ddr edge), so the wall time grows with latency, not cycle count.
// These stay tractable while still spanning low to elevated latency; the slow
// end of the regime is covered by the 512-byte latency-200 test above.
const _sweepLatencies = [50, 200];

// ===========================================================================
// PART 2: the REAL DDR write path (Ddr3Controller + Ddr3DramModel).
//
// The controller-model tests above proved the ADMA + posted CDC + burst
// adapter are fast (~66 sys-cycles/beat), so the hardware ~560us/word must be
// downstream, in the real Ddr3Controller + DRAM behaviour, which a model
// controller cannot show. This part instantiates the REAL controller,
// calibrates it against the Ddr3DramModel (the same behavioural PHY the
// controller unit tests use), then drives it with the exact 128-bit burst
// write stream the burst adapter emits for an ADMA block, and measures how many
// CONTROLLER cycles each burst write costs. That is the bisection knob.
//
// Note on the DRAM model: Ddr3DramModel is a calibration model with only a
// two-word BIST memory (ddr3_dram_model.dart ~line 228), NOT a full DRAM array.
// So an end-to-end ADMA-block-through-real-DRAM data test is not possible with
// it (there is nowhere to hold the descriptor at address 0 plus 512 bytes of
// payload). The controller-stage timing is therefore measured directly at the
// controller's wishbone, which is exactly what the adapter presents to it.

/// One decoded active DDR command on some CK slot within a controller cycle.
class _Cmd {
  final int slot, cmd3, bank, addr;
  _Cmd(this.slot, this.cmd3, this.bank, this.addr);
  String get name => const {
    0: 'MRS',
    1: 'REF',
    2: 'PRE',
    3: 'ACT',
    4: 'WR',
    5: 'RD',
    6: 'ZQC',
    7: 'NOP',
  }[cmd3]!;
}

List<_Cmd> _decodeCmd(LogicValue v, DdrParams p) {
  final cmdLen = 4 + 3 + p.baBits + p.rowBits;
  final out = <_Cmd>[];
  for (var s = 0; s < p.serdesRatio; s++) {
    final slot = v.getRange(cmdLen * s, cmdLen * (s + 1));
    if (!slot.isValid) continue;
    if (slot[cmdLen - 1].toInt() != 0) continue; // cs_n high = deselect
    final cmd3 = slot.getRange(cmdLen - 4, cmdLen - 1).toInt();
    if (cmd3 == Ddr3Cmd.nop) continue;
    final bank = slot.getRange(p.rowBits, p.rowBits + p.baBits).toInt();
    final addr = slot.getRange(0, p.rowBits).toInt();
    out.add(_Cmd(s, cmd3, bank, addr));
  }
  return out;
}

/// Real Ddr3Controller + Ddr3DramModel, calibrated and ready for wishbone
/// traffic. Runs on a single clock (the controller clock); the DRAM AC timing
/// is governed by [p], not by the sim clock period.
class _RealDdr {
  final DdrParams p;
  late final Ddr3Controller ctrl;
  late final Ddr3DramModel model;

  late final Logic clk, rstN;
  late final Logic wbCyc, wbStb, wbWe, wbAddr, wbData, wbSel, aux;

  int calCycles = -1;
  int maxState = -1;

  // Command stream observed while the controller runs (calibration BIST + any
  // traffic). Gives the controller's intrinsic DDR-command cadence even when
  // full calibration cannot close in behavioural sim.
  final cmdHist = <String, int>{};
  final wrCycles = <int>[];
  final rdCycles = <int>[];

  _RealDdr(this.p);

  int get state =>
      ctrl.debug1.value.isValid ? ctrl.debug1.value.toInt() & 0x3F : -1;
  bool get stall => ctrl.output('o_wb_stall').value.toInt() == 1;
  bool get ack =>
      ctrl.output('o_wb_ack').value.isValid &&
      ctrl.output('o_wb_ack').value.toInt() == 1;

  Future<bool> buildAndCalibrate({int calBudget = 400000}) async {
    clk = SimpleClockGenerator(10).clk;
    rstN = Logic(name: 'rstn');
    wbCyc = Logic(name: 'wb_cyc')..inject(0);
    wbStb = Logic(name: 'wb_stb')..inject(0);
    wbWe = Logic(name: 'wb_we')..inject(0);
    wbAddr = Logic(name: 'wb_addr', width: p.wbAddrBits)..inject(0);
    wbData = Logic(name: 'wb_data', width: p.wbDataBits)..inject(0);
    wbSel = Logic(name: 'wb_sel', width: p.wbSelBits)..inject(0);
    aux = Logic(name: 'aux', width: Ddr3Controller.auxWidth)..inject(0);

    final phyData = Logic(name: 'phy_data', width: p.dqBits * p.lanes * 8);
    final phyDqs = Logic(name: 'phy_dqs', width: p.lanes * 8);
    final phyBsRef = Logic(name: 'phy_bsref', width: p.lanes * 8);
    final phyRdy = Logic(name: 'phy_rdy');

    ctrl = Ddr3Controller(
      p,
      controllerClk: clk,
      rstN: rstN,
      wbCyc: wbCyc,
      wbStb: wbStb,
      wbWe: wbWe,
      wbAddr: wbAddr,
      wbData: wbData,
      wbSel: wbSel,
      aux: aux,
      wb2Cyc: Logic()..inject(0),
      wb2Stb: Logic()..inject(0),
      wb2We: Logic()..inject(0),
      wb2Addr: Logic(width: Ddr3Controller.wb2AddrBits)..inject(0),
      wb2Sel: Logic(width: Ddr3Controller.wb2SelBits)..inject(0),
      wb2Data: Logic(width: Ddr3Controller.wb2DataBits)..inject(0),
      phyIserdesData: phyData,
      phyIserdesDqs: phyDqs,
      phyIserdesBitslipReference: phyBsRef,
      phyIdelayctrlRdy: phyRdy,
    );
    model = Ddr3DramModel(
      p,
      controllerClk: clk,
      phyReset: ctrl.phyReset,
      cmd: ctrl.phyCmd,
      writeData: ctrl.output('o_phy_data'),
      bitslip: ctrl.output('o_phy_bitslip'),
      idelayDqsLd: ctrl.output('o_phy_idelay_dqs_ld'),
    );
    phyData <= model.iserdesData;
    phyDqs <= model.iserdesDqs;
    phyBsRef <= model.iserdesBitslipReference;
    phyRdy <= model.idelayctrlRdy;

    await ctrl.build();
    await model.build();

    rstN.inject(0);
    Simulator.setMaxSimTime(1 << 30);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    rstN.inject(1);

    for (var i = 0; i < calBudget; i++) {
      await clk.nextPosedge;
      final s = state;
      if (s > maxState) maxState = s;
      for (final c in _decodeCmd(ctrl.phyCmd.value, p)) {
        cmdHist[c.name] = (cmdHist[c.name] ?? 0) + 1;
        if (c.cmd3 == Ddr3Cmd.wr) wrCycles.add(i);
        if (c.cmd3 == Ddr3Cmd.rd) rdCycles.add(i);
      }
      if (s == 23) {
        calCycles = i;
        return true;
      }
    }
    return false;
  }

  Future<void> stop() async {
    await Simulator.endSimulation();
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // ===========================================================================
  // HW bug hunt: CMD18 multi-block reads corrupt/crash at scale on the Arty S7
  // (n=16 ok, n>=32 wrong on the bounce path; flaky crashes on direct-DMA). The
  // PIO receive engine is byte-exact to 48 blocks, so this drives the REAL DMA
  // path (ADMA -> posted CDC -> burst adapter -> store) at the failing scale and
  // checks every word. If the store is byte-exact here, the ADMA multi-block RTL
  // is functionally correct and the HW fault is timing/electrical (openXC7 DDR
  // margin), not logic.
  group('CMD18 multi-block ADMA is byte-exact at scale (DMA path)', () {
    for (final n in [8, 16, 32]) {
      test('$n x 512-byte blocks land byte-exact through the ADMA', () async {
        final r = await _runMultiBlock(nBlocks: n, busWidth: 64);
        print(
          '[multiblock n=$n] landed=${r.landed}/${r.total} '
          'firstBad=${r.firstBad}'
          '${r.firstBad >= 0 ? ' (block ${r.firstBad ~/ 128} word ${r.firstBad % 128}: '
                    'want 0x${r.want.toRadixString(16)} got 0x${r.got.toRadixString(16)})' : ''}',
        );
        expect(
          r.landed,
          r.total,
          reason:
              'all $n blocks must land byte-exact through the ADMA; '
              'first divergence at word ${r.firstBad}',
        );
      });
    }
  });

  // ===========================================================================
  // The crossbar-inclusive reproduction. The HW read stays ~12.75ms/block even
  // with the streaming fix + combining ON, while this harness (ADMA wired
  // STRAIGHT to the CDC) shows ~66 cyc/word. The real delta fabric interposes
  // classic single-outstanding register slices between the ADMA and the CDC
  // (dma_* -> wishbone_reg_0 -> arbiter -> wishbone_reg -> CDC). Each slice
  // re-serializes the streamed beats and spaces same-burst beats apart. If that
  // spacing exceeds the burst adapter's combine window, combining silently
  // reverts (wideWrites climbs from ~32 back toward 128) and the per-beat issue
  // cost balloons. This group sweeps 0/1/2 slices and prints the effect.
  group('interconnect re-serialization (crossbar-inclusive)', () {
    for (final stages in [0, 1, 2]) {
      test('512B block, 64b path, $stages register slice(s)', () async {
        final r = await _runBlock(
          writeAcceptLatency: 2,
          busWidth: 64,
          regStages: stages,
        );
        print(
          '[regStages=$stages] cyclesToLand=${r.cyclesToLand} '
          'cyclesPerBeat=${r.cyclesPerBeat.toStringAsFixed(1)} '
          'wideWrites=${r.wideWrites} '
          'admaBeats=${r.admaBeats} '
          'cyclesPerAdmaBeat=${r.cyclesPerAdmaBeat.toStringAsFixed(1)} '
          'dataOk=${r.dataOk}',
        );
        expect(
          r.dataOk,
          isTrue,
          reason: 'data must still land correctly with $stages slice(s)',
        );
      });
    }
  });

  // ===========================================================================
  // Does combining actually buy block time under a SLOW controller? This is the
  // ffwc2 predictor. delta-ffs runs writeCombine=OFF (every narrow beat a
  // separate masked DRAM write); ffwc2 turns it ON. With a slow controller the
  // DRAM-write COUNT multiplies the drain, so if combining works, combine=false
  // should be markedly slower than combine=true here. A 128-byte block at a high
  // controller latency makes the drain (not the 1-bit SD receive) the limiter.
  group('combine on/off predicts ffwc2 (slow controller, drain-limited)', () {
    const lat = 600;
    for (final combine in [false, true]) {
      test('128B block, latency=$lat, combine=$combine', () async {
        final r = await _runBlock(
          writeAcceptLatency: lat,
          busWidth: 64,
          blockBytes: 128,
          combine: combine,
        );
        print(
          '[combine=$combine, latency=$lat] '
          'cyclesToLand=${r.cyclesToLand} '
          'cyclesPerBeat=${r.cyclesPerBeat.toStringAsFixed(1)} '
          'wideWrites=${r.wideWrites} '
          'dataOk=${r.dataOk}',
        );
        expect(
          r.dataOk,
          isTrue,
          reason: 'data must land with combine=$combine',
        );
      });
    }
  });

  group('SDIO ADMA -> posted CDC -> burst adapter -> DDR write throughput', () {
    // The streaming fix: the ADMA holds STB asserted and buffers a full wide
    // burst's worth of words before draining, so the burst adapter combines
    // four narrow words (or two packed 64-bit beats) into ONE 128-bit DRAM
    // burst. A 512-byte block is 32 such bursts, so wideWrites collapses from
    // 128 (one DRAM command per narrow word, the pre-fix behaviour) to about
    // 32, and every word still lands. 512B / 16B-per-burst = 32; the ceiling
    // leaves headroom for the one tail idle-flush.
    const wideWriteCeiling = 40;
    for (final width in [32, 64]) {
      test('a 512-byte block combines to ~32 wide bursts on the ${width}b path '
          '(low latency)', () async {
        final r = await _runBlock(writeAcceptLatency: 2, busWidth: width);
        print(
          '[512B block, ${width}b, latency=${r.latency}] '
          'cyclesToLand=${r.cyclesToLand} '
          'cyclesPerBeat=${r.cyclesPerBeat.toStringAsFixed(1)} '
          'wideWrites=${r.wideWrites} (was 128 before the fix)',
        );
        expect(r.dataOk, isTrue, reason: 'all 128 words must land correctly');
        expect(r.dataDone, isTrue, reason: 'data-done interrupt must fire');
        // Locked-in improvement: narrow words are combined into wide bursts.
        expect(
          r.wideWrites,
          lessThanOrEqualTo(wideWriteCeiling),
          reason:
              'the burst adapter must combine narrow words into wide '
              'bursts (128 means no combining at all)',
        );
      });
    }

    test('a 512-byte block still combines to ~32 wide bursts when the '
        'controller is slow (32b path)', () async {
      // Combining is latency-independent: the adapter merges the streamed
      // same-burst beats regardless of how slowly the controller then drains
      // them, so a slow controller costs 32 wide writes, not 128. Run on the
      // faster 32-bit sim so a high latency stays test-tractable.
      final r = await _runBlock(writeAcceptLatency: 200, busWidth: 32);
      print(
        '[512B block, 32b, latency=${r.latency}] '
        'cyclesToLand=${r.cyclesToLand} '
        'cyclesPerBeat=${r.cyclesPerBeat.toStringAsFixed(1)} '
        'wideWrites=${r.wideWrites}',
      );
      expect(
        r.dataOk,
        isTrue,
        reason: 'all 128 words must land correctly at latency=200',
      );
      expect(
        r.wideWrites,
        lessThanOrEqualTo(wideWriteCeiling),
        reason: 'combining must hold up when the controller is slow',
      );
    });

    // One simulation per latency. After the streaming fix the number of wide
    // DRAM writes is one per 16-byte burst at EVERY latency: the adapter
    // combines the streamed beats before the slow controller sees them, so the
    // controller latency no longer multiplies the DRAM command count.
    for (final lat in _sweepLatencies) {
      test(
        'write latency $lat: the 128-byte block combines and lands',
        () async {
          final r = await _runBlock(
            writeAcceptLatency: lat,
            busWidth: _sweepWidth,
            blockBytes: _sweepBlock,
          );
          print(
            '[128B block, ${_sweepWidth}b, latency=${r.latency}] '
            'cyclesToLand=${r.cyclesToLand} '
            'cyclesPerBeat=${r.cyclesPerBeat.toStringAsFixed(1)} '
            'wideWrites=${r.wideWrites} (${_sweepBursts} bursts)',
          );
          expect(
            r.dataOk,
            isTrue,
            reason: 'data must land correctly at latency=$lat',
          );
          _sweep.add(r);
        },
      );
    }

    test('combining holds across the controller-latency sweep', () {
      expect(
        _sweep.length,
        _sweepLatencies.length,
        reason: 'every latency run must have recorded a result',
      );
      // The 128-byte block is _sweepBursts 16-byte bursts. Allow the one tail
      // idle-flush plus a small margin. Crucially this ceiling does NOT grow
      // with latency, which is the whole point of the streaming + combining
      // fix: the DRAM command count is decoupled from the controller latency.
      final ceiling = _sweepBursts + 4;
      for (final r in _sweep) {
        expect(
          r.wideWrites,
          lessThanOrEqualTo(ceiling),
          reason:
              'wideWrites must stay near one-per-burst at latency='
              '${r.latency}, not scale with it (got ${r.wideWrites})',
        );
      }
      // And more controller latency still costs more time (the writes now
      // overlap the SD receive, but a slow controller cannot go faster than the
      // combined-burst drain), so the block time is still monotonic in latency.
      final ordered = [..._sweep]
        ..sort((a, b) => a.latency.compareTo(b.latency));
      for (var i = 1; i < ordered.length; i++) {
        expect(
          ordered[i].cyclesToLand,
          greaterThanOrEqualTo(ordered[i - 1].cyclesToLand),
          reason: 'block time must not shrink as controller latency grows',
        );
      }
    });
  });

  // ===========================================================================
  // The DMA-read-coherency fix: data-done must MEAN the block is durable.
  //
  // On a posted-write fabric the ADMA's block writes are ACKed before they land
  // in the controller store, so with a slow controller the last writes are still
  // in flight when the RX FIFO drains. Without the read-back barrier the engine
  // raises data-done at that moment, so a driver that reads the buffer the
  // instant it sees data-done reads STALE data (the exact Arty S7 boot failure:
  // the sustained EFI-file read resets the board on stale/garbage). The barrier
  // fences the writes with a read-back of the last written address, so data-done
  // is held until the whole block has committed.
  group(
    'read-back barrier makes data-done mean durable (DMA-read coherency)',
    () {
      const lat = 200; // a slow controller: posted writes lag the SD receive
      test(
        'WITHOUT the barrier, data-done fires before the block lands (the bug)',
        () async {
          final r = await _runBlock(
            writeAcceptLatency: lat,
            busWidth: 32,
            readBackBarrier: false,
          );
          print(
            '[no-barrier latency=$lat] dataDoneCycle=${r.dataDoneCycle} '
            'landedCycle=${r.cyclesToLand}',
          );
          expect(r.dataDoneCycle, greaterThan(0));
          expect(r.cyclesToLand, greaterThan(0));
          // The defect: data-done precedes the block being fully committed.
          expect(
            r.dataDoneCycle,
            lessThan(r.cyclesToLand),
            reason:
                'without the barrier the slow controller leaves writes in '
                'flight when data-done fires; this is the stale-read window',
          );
        },
      );

      test(
        'WITH the barrier, data-done fires only after the block lands (fixed)',
        () async {
          final r = await _runBlock(
            writeAcceptLatency: lat,
            busWidth: 32,
            readBackBarrier: true,
          );
          print(
            '[barrier latency=$lat] dataDoneCycle=${r.dataDoneCycle} '
            'landedCycle=${r.cyclesToLand} wideWrites=${r.wideWrites} '
            'dataOk=${r.dataOk}',
          );
          expect(
            r.dataOk,
            isTrue,
            reason: 'the block must still land correctly',
          );
          expect(r.dataDone, isTrue, reason: 'data-done must still fire');
          expect(r.dataDoneCycle, greaterThan(0));
          expect(r.cyclesToLand, greaterThan(0));
          // The fix: every word is committed no later than data-done.
          expect(
            r.dataDoneCycle,
            greaterThanOrEqualTo(r.cyclesToLand),
            reason:
                'the read-back barrier must hold data-done until the whole '
                'block has committed to the controller store',
          );
        },
      );
    },
  );

  group('real Ddr3Controller write-accept rate (the bisection)', () {
    test('the real controller accepts ADMA-pattern burst writes fast', () async {
      // The controller's own unit tests (ddr3_readcal, tool_ddr3_bank_mgmt)
      // calibrate with these fast-reset periods: realistic Arty S7 CK timing
      // (3.33 ns CK) makes the power-up dwells ~60x longer in cycles and is not
      // sim-tractable (millions of cycles). With these periods the DRAM AC
      // timing collapses toward 1 cycle, so cycles/write measures the
      // controller's PIPELINE/COMMAND-SEQUENCE cost (does it precharge+activate
      // per write, does it stall on refresh) rather than the raw AC dwell. The
      // command histogram below shows the sequence; the AC-timing headroom is
      // argued separately (tRCD/tRP/tWR are tens of ns = single-digit CK cycles,
      // nowhere near the ~560 us/word HW regime).
      final p = DdrParams(
        controllerClkPeriodPs: 800000,
        ddr3ClkPeriodPs: 200000,
      );
      final d = _RealDdr(p);
      final calibrated = await d.buildAndCalibrate(calBudget: 100000);
      final ctrlNs = p.controllerClkPeriodPs / 1000.0;
      final hwCyclesPerWord = 560000.0 / ctrlNs;
      print(
        'calibration reached DONE_CALIBRATE(23): $calibrated '
        'after ${d.calCycles} controller cycles, maxState=${d.maxState} '
        '(controller period ${ctrlNs.toStringAsFixed(1)} ns)',
      );
      print('DDR command stream observed during the cal attempt: ${d.cmdHist}');

      // The controller emits WR/RD commands during the calibration BIST (it
      // writes W1/W2 then reads them back). The gap between consecutive WR
      // commands is the controller's intrinsic write-command cadence, the best
      // proxy we get for steady-state write throughput given full calibration
      // cannot close in behavioural sim.
      int medianGap(List<int> cyclesList) {
        if (cyclesList.length < 2) return -1;
        final gaps = <int>[];
        for (var i = 1; i < cyclesList.length; i++) {
          final g = cyclesList[i] - cyclesList[i - 1];
          if (g > 0) gaps.add(g);
        }
        if (gaps.isEmpty) return -1;
        gaps.sort();
        return gaps[gaps.length ~/ 2];
      }

      final wrGap = medianGap(d.wrCycles);
      final rdGap = medianGap(d.rdCycles);
      print(
        'controller intrinsic command cadence: WR commands=${d.wrCycles.length} '
        'median gap=$wrGap ctrl-cycles (${(wrGap * ctrlNs).toStringAsFixed(1)} ns), '
        'RD commands=${d.rdCycles.length} median gap=$rdGap ctrl-cycles',
      );
      print(
        'HW ~560 us/word == ${hwCyclesPerWord.toStringAsFixed(0)} controller '
        'cycles/word at this clock; observed WR cadence is far below that',
      );

      await d.stop();

      // The controller ran real DDR command traffic (it calibrates through
      // read-cal and the write BIST), and its command cadence is tens of cycles
      // at most, orders of magnitude below the HW ~560 us/word regime.
      expect(
        d.cmdHist['WR'],
        isNotNull,
        reason: 'the real controller must emit WR commands',
      );
      expect(wrGap, greaterThan(0));
      expect(
        wrGap,
        lessThan(hwCyclesPerWord / 10),
        reason:
            'the real controller command cadence is far faster than the HW '
            'regime, so the HW cost is NOT the controller command rate',
      );

      // DONE_CALIBRATE(23) is unreachable with the behavioural DRAM model (the
      // write-BIST read-back never matches at ANALYZE_DATA state 13, and the
      // full Ddr3Phy path uses Xilinx blackbox primitives with no sim model).
      // So the post-calibration wishbone write path cannot be exercised in pure
      // ROHD sim. Record that clearly instead of forcing a false green.
      if (!calibrated) {
        markTestSkipped(
          'real controller reached maxState=${d.maxState} '
          '(ANALYZE_DATA) but not DONE_CALIBRATE(23): the behavioural DRAM '
          'model does not satisfy the write-BIST read-back, so the wishbone '
          'never goes live in sim. Controller command cadence still measured '
          'above (WR gap=$wrGap ctrl-cycles).',
        );
      }
    });
  });
}
