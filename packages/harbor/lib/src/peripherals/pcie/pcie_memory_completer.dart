import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../../bus/port/fabric_kind.dart';
import '../../bus/port/memory_port.dart';
import '../../bus/port/memory_waist.dart';
import 'pcie_stream.dart';

/// Gives the host access to local memory through a memory BAR.
///
/// The BAR offset of a request is its address modulo [barBytes]. The fabric
/// address is [memoryOffset] plus that offset. The block does one TLP at a
/// time, in order:
///
/// - A memory write goes into a buffer, then to the fabric as INCR bursts.
///   A burst does not cross a 4 KB boundary and has at most 256 beats. The
///   block waits for each write response before it continues. A write that
///   gets a fabric error, a poisoned write and a write longer than
///   [maxPayloadBytes] are dropped and counted in `write_errors`.
/// - A memory read is answered by completions. The first ends at the read
///   completion boundary, the next ones have the maximum payload size, and
///   the last ends at the end of the request. The block reads one
///   completion from the fabric into the buffer before it sends it. If a
///   fabric read fails, the block sends one completion with status CA for
///   the rest of the request.
/// - Other non-posted requests get a completion with status UR. Other
///   packets are dropped.
///
/// `max_payload` uses the CFGDEVCONTROLMAXPAYLOAD encoding. The block uses
/// the smaller of it and [maxPayloadBytes].
class HarborPcieMemoryCompleter extends BridgeModule {
  /// Stream width in bits.
  final int width;

  /// Fabric data width in bits, 32, 64 or 128.
  final int dataWidth;

  /// Fabric byte address width.
  final int addressWidth;

  /// BAR size in bytes, a power of two of at least 4 KB.
  final int barBytes;

  /// Fabric address of BAR offset 0.
  final int memoryOffset;

  /// Bit in `rx_user` that marks a hit on the BAR.
  final int barHitBit;

  /// Size of the buffer, the largest write payload and completion payload.
  final int maxPayloadBytes;

  /// Fabric kind of the memory port.
  final HarborFabricKind fabricKind;

  /// The memory master port.
  late final HarborMemoryMasterPort memory;

  /// Count of dropped writes. It stops at 0xffff.
  Logic get writeErrors => output('write_errors');

  HarborPcieMemoryCompleter({
    required Logic clk,
    required Logic reset,
    required Logic maxPayload,
    required Logic rcb128,
    required Logic completerId,
    required HarborPcieStream rx,
    required HarborPcieStream tx,
    this.fabricKind = HarborFabricKind.axi4,
    this.dataWidth = 64,
    this.addressWidth = 32,
    this.barBytes = 16 << 20,
    this.memoryOffset = 0,
    this.barHitBit = 4,
    this.maxPayloadBytes = 256,
    String? name,
  }) : width = rx.width,
       super(
         'HarborPcieMemoryCompleter_W${rx.width}_D${dataWidth}_A$addressWidth'
         '_${fabricKind.name}_S${barBytes.toRadixString(16)}'
         '_O${memoryOffset.toRadixString(16)}_B${barHitBit}_P$maxPayloadBytes',
         name: name ?? 'pcie_memory_completer',
       ) {
    _validate(tx);

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    maxPayload = addInput('max_payload', maxPayload, width: 3);
    rcb128 = addInput('rcb_128', rcb128);
    completerId = addInput('completer_id', completerId, width: 16);
    // A register stage on RX keeps the request decode away from the
    // endpoint and the router decode.
    final rxIn = HarborPcieStream.addSink(this, rx);
    final rxs = HarborPcieStream(width: width, name: 'rx_reg');
    HarborPcieStreamRegister(
      clk: clk,
      reset: reset,
      upstream: rxIn,
      downstream: rxs,
      name: 'rx_register',
    );
    // A register stage on TX keeps the completion beat logic away from the
    // router mux and the endpoint.
    final txOut = HarborPcieStream.addSource(this, tx);
    final txs = HarborPcieStream(width: width, name: 'tx_reg');
    HarborPcieStreamRegister(
      clk: clk,
      reset: reset,
      upstream: txs,
      downstream: txOut,
      name: 'tx_register',
    );

    memory = HarborMemoryMasterPort.create(
      module: this,
      name: 'memory',
      kind: fabricKind,
      config: HarborMemoryWaistConfig(
        addressWidth: addressWidth,
        dataWidth: dataWidth,
      ),
      clk: clk,
      reset: reset,
    );
    _build(clk, reset, maxPayload, rcb128, completerId, rxs, txs);
  }

  static int _log2(int v) => v.bitLength - 1;
  static bool _pow2(int v) => v > 0 && v & (v - 1) == 0;

  void _validate(HarborPcieStream tx) {
    if (tx.width != width) {
      throw ArgumentError('tx width ${tx.width} differs from rx width $width');
    }
    if (![32, 64, 128].contains(dataWidth)) {
      throw ArgumentError.value(dataWidth, 'dataWidth', 'must be 32/64/128');
    }
    if (addressWidth < 12 || addressWidth > 64) {
      throw RangeError.range(addressWidth, 12, 64, 'addressWidth');
    }
    if (!_pow2(barBytes) || barBytes < 4096) {
      throw ArgumentError.value(barBytes, 'barBytes', 'power of two >= 4096');
    }
    if (!_pow2(maxPayloadBytes) ||
        maxPayloadBytes < 128 ||
        maxPayloadBytes > 4096) {
      throw ArgumentError.value(
        maxPayloadBytes,
        'maxPayloadBytes',
        'power of two from 128 to 4096',
      );
    }
    if (memoryOffset < 0 || memoryOffset % 4 != 0) {
      throw ArgumentError.value(memoryOffset, 'memoryOffset', 'DW aligned');
    }
    if (BigInt.from(memoryOffset) + BigInt.from(barBytes) >
        BigInt.one << addressWidth) {
      throw ArgumentError('the BAR does not fit in $addressWidth bits');
    }
    if (barHitBit < 2 || barHitBit > 8) {
      throw RangeError.range(barHitBit, 2, 8, 'barHitBit');
    }
  }

  void _build(
    Logic clk,
    Logic reset,
    Logic maxPayload,
    Logic rcb128,
    Logic completerId,
    HarborPcieStream rxs,
    HarborPcieStream txs,
  ) {
    final mem = memory.waist;
    final aw = addressWidth;
    final n = width ~/ 32;
    final dpb = dataWidth ~/ 32;
    final dpbLog = _log2(dpb);
    final beatBytes = dataWidth ~/ 8;
    final sizeLog = _log2(beatBytes);
    final maxDw = maxPayloadBytes ~/ 4;
    final entries = maxDw + dpb;
    final barBits = _log2(barBytes);
    final idxW = (entries + 8).bitLength + 1;
    final maxCode = _log2(maxPayloadBytes ~/ 128);

    const sRx = 0;
    const sDecode = 1;
    const sChunk = 2;
    const sReq = 3;
    const sWdata = 4;
    const sWresp = 5;
    const sRdata = 6;
    const sTx = 7;
    const statusUr = 1;
    const statusCa = 4;

    final state = Logic(name: 'state', width: 3);
    Logic inState(int s) => state.eq(Const(s, width: 3));

    final capture = HarborPcieHeaderCapture(
      clk: clk,
      reset: reset,
      stream: rxs,
    );
    final header = capture.header;

    // Header fields, kept from the header beat.
    final hFmtType = Logic(name: 'h_fmt_type', width: 8);
    final hLenDw = Logic(name: 'h_len_dw', width: 11);
    final hFirstBe = Logic(name: 'h_first_be', width: 4);
    final hLastBe = Logic(name: 'h_last_be', width: 4);
    final hReqId = Logic(name: 'h_req_id', width: 16);
    final hTag = Logic(name: 'h_tag', width: 8);
    final hTc = Logic(name: 'h_tc', width: 3);
    final hAttr = Logic(name: 'h_attr', width: 2);
    final hPoison = Logic(name: 'h_poison');
    final hHit = Logic(name: 'h_hit');
    final hBarOff = Logic(name: 'h_bar_off', width: barBits);

    // RX payload fill.
    final pastHeader = Logic(name: 'past_header');
    final rxBase = Logic(name: 'rx_base', width: idxW);

    // Fabric operation.
    final opWrite = Logic(name: 'op_write');
    final lane0 = Logic(name: 'lane0', width: 2);
    final opDw = Logic(name: 'op_dw', width: 11);
    final curAddr = Logic(name: 'cur_addr', width: aw);
    final beatsLeft = Logic(name: 'beats_left', width: 12);
    final burstLeft = Logic(name: 'burst_left', width: 9);
    final word = Logic(name: 'word', width: idxW);
    final fabErr = Logic(name: 'fab_err');

    // Read request progress. Page values are offsets in the 4 KB page.
    final rdA = Logic(name: 'rd_a', width: 12);
    final rdEnd = Logic(name: 'rd_end', width: 12);
    final rdStop = Logic(name: 'rd_stop', width: 12);
    final rdFirst = Logic(name: 'rd_first');
    final rdRemaining = Logic(name: 'rd_remaining', width: 13);
    final rdStart = Logic(name: 'rd_start', width: 13);
    final rdFab = Logic(name: 'rd_fab', width: aw);
    final cDw = Logic(name: 'c_dw', width: 11);
    final cplStatus = Logic(name: 'cpl_status', width: 3);
    final txT = Logic(name: 'tx_t', width: 12);
    final txBase = Logic(name: 'tx_base', width: idxW);

    final errCount = Logic(name: 'err_count', width: 16);
    addOutput('write_errors', width: 16) <= errCount;

    final buf = [
      for (var j = 0; j < entries; j++) Logic(name: 'buf_$j', width: 32),
    ];

    Logic laneOf(Logic addr) => dpb == 1
        ? Const(0, width: 2)
        : addr.slice(3, 2) & Const(dpb - 1, width: 2);

    // RX side.
    final inRx = inState(sRx);
    rxs.ready <= inRx;
    final rxFire = rxs.valid & rxs.ready;
    final hdrFire = capture.headerValid & rxs.ready;
    final addrComb = tlpAddress(header);
    final fabComb =
        (Const(memoryOffset, width: aw) +
                addrComb.slice(barBits - 1, 0).zeroExtend(aw))
            .named('fab_comb');
    final lane0Comb = laneOf(fabComb);
    final payloadFire = inRx & rxFire & pastHeader;

    // Decode.
    final type = hFmtType.slice(4, 0);
    final hasData = hFmtType[6];
    final isMRd = type.eq(0) & ~hasData;
    final isMWr = type.eq(0) & hasData;
    final nonPosted =
        (type.eq(0) | type.eq(1)) & ~hasData |
        type.eq(2) |
        type.eq(4) |
        type.eq(5) |
        (type.eq(0x0c) | type.eq(0x0d) | type.eq(0x0e)) & hasData;
    final tooLong = hLenDw.gt(Const(maxDw, width: 11));
    final fabStart = (Const(memoryOffset, width: aw) + hBarOff.zeroExtend(aw))
        .named('fab_start');

    Logic firstSet(Logic be) => mux(
      be[0],
      Const(0, width: 2),
      mux(
        be[1],
        Const(1, width: 2),
        mux(
          be[2],
          Const(2, width: 2),
          mux(be[3], Const(3, width: 2), Const(0, width: 2)),
        ),
      ),
    );
    final fe = firstSet(hFirstBe);
    final tailBe = mux(hLenDw.eq(1), hFirstBe, hLastBe);
    final tailTrim = mux(
      tailBe[3],
      Const(0, width: 2),
      mux(
        tailBe[2],
        Const(1, width: 2),
        mux(
          tailBe[1],
          Const(2, width: 2),
          mux(tailBe[0], Const(3, width: 2), Const(0, width: 2)),
        ),
      ),
    );
    final aByte = hBarOff.slice(11, 0).zeroExtend(13);
    final begin = (aByte + fe.zeroExtend(13)).named('rd_begin');
    final zeroLen = hLenDw.eq(1) & hFirstBe.eq(0);
    final endByte = mux(
      zeroLen,
      begin + 1,
      aByte + (hLenDw.zeroExtend(13) << 2) - tailTrim.zeroExtend(13),
    ).named('rd_end_byte');
    final aDw = hBarOff.slice(11, 2).zeroExtend(12);

    // Completion split.
    final rcbDw = mux(rcb128, Const(32, width: 12), Const(16, width: 12));
    final mpsCode = mux(
      maxPayload.gt(Const(maxCode, width: 3)),
      Const(maxCode, width: 3),
      maxPayload,
    );
    final mpsDw = Const(32, width: 12) << mpsCode;
    final bound = mux(
      rdFirst,
      (rdA & ~(rcbDw - 1)) + rcbDw,
      rdA + mpsDw,
    ).named('rd_bound');
    final stop = mux(bound.lt(rdEnd), bound, rdEnd).named('rd_stop_next');
    final chunkDw = (stop - rdA).slice(10, 0);

    // Fabric bursts.
    final to4k =
        (Const(0x1000, width: 13) - curAddr.slice(11, 0).zeroExtend(13)) >>
        sizeLog;
    final left13 = beatsLeft.zeroExtend(13);
    final cap = mux(to4k.lt(256), to4k, Const(256, width: 13));
    final burst = mux(left13.lt(cap), left13, cap).named('burst');

    mem.reqValid <= inState(sReq);
    mem.reqId <= Const(0, width: mem.config.idWidth);
    mem.reqWrite <= opWrite;
    mem.reqAddr <= curAddr;
    mem.reqLen <= (burst - 1).slice(HarborMemoryWaistConfig.lenWidth - 1, 0);
    mem.reqSize <= Const(sizeLog, width: HarborMemoryWaistConfig.sizeWidth);
    mem.reqBurst <=
        Const(
          HarborMemoryBurst.incr.value,
          width: HarborMemoryWaistConfig.burstWidth,
        );
    mem.reqExclusive <= Const(0);
    final reqFire = mem.reqValid & mem.reqReady;

    final words = [
      for (var x = 0; x < entries ~/ dpb; x++)
        [for (var l = dpb - 1; l >= 0; l--) buf[x * dpb + l]].swizzle(),
    ];
    final strobes = <Logic>[];
    for (var l = 0; l < dpb; l++) {
      final p = (word << dpbLog) + l;
      final k = p - lane0.zeroExtend(idxW);
      final kExt = k.zeroExtend(idxW + 11);
      final inRange =
          p.gte(lane0.zeroExtend(idxW)) & kExt.lt(opDw.zeroExtend(idxW + 11));
      final be = mux(
        k.eq(0),
        hFirstBe,
        mux(
          kExt.eq((opDw - 1).zeroExtend(idxW + 11)),
          hLastBe,
          Const(0xf, width: 4),
        ),
      );
      strobes.add(mux(inRange, be, Const(0, width: 4)));
    }
    mem.wdataValid <= inState(sWdata);
    // Bytes with no strobe are driven 0.
    final strb = strobes.rswizzle();
    final raw = word.selectFrom(words);
    mem.wdataData <=
        [
          for (var b = beatBytes - 1; b >= 0; b--)
            mux(strb[b], raw.slice(8 * b + 7, 8 * b), Const(0, width: 8)),
        ].swizzle();
    mem.wdataStrb <= strb;
    mem.wdataLast <= burstLeft.eq(1);
    final wFire = mem.wdataValid & mem.wdataReady;
    mem.wrespReady <= inState(sWresp);
    final bFire = mem.wrespValid & mem.wrespReady;
    mem.rdataReady <= inState(sRdata);
    final rFire = mem.rdataValid & mem.rdataReady;

    // TX side.
    final cplData = cplStatus.eq(0);
    final dw0 = [
      mux(cplData, Const(0x4a, width: 8), Const(0x0a, width: 8)),
      Const(0, width: 1),
      hTc,
      Const(0, width: 6),
      hAttr,
      Const(0, width: 2),
      mux(cplData, cDw.slice(9, 0), Const(0, width: 10)),
    ].swizzle();
    final dw1 = [
      completerId,
      cplStatus,
      Const(0, width: 1),
      rdRemaining.slice(11, 0),
    ].swizzle();
    final dw2 = [
      hReqId,
      hTag,
      Const(0, width: 1),
      rdStart.slice(6, 0),
    ].swizzle();
    final totalDw =
        (Const(3, width: 12) +
                mux(cplData, cDw.zeroExtend(12), Const(0, width: 12)))
            .named('tx_total');
    final txLanes = <Logic>[];
    final txKeep = <Logic>[];
    for (var i = 0; i < n; i++) {
      final t = txT + i;
      Logic value = tlpSwapBytes(
        (txBase + i).selectFrom(buf, defaultValue: Const(0, width: 32)),
      );
      for (var h = 2; h >= 0; h--) {
        if (h % n != i) continue;
        value = mux(t.eq(h), [dw0, dw1, dw2][h], value);
      }
      final live = t.lt(totalDw);
      txLanes.add(mux(live, value, Const(0, width: 32)));
      txKeep.add(live.replicate(4));
    }
    final txLast = (txT + n).gte(totalDw);
    txs.data <= txLanes.rswizzle();
    txs.keep <= txKeep.rswizzle();
    txs.last <= txLast;
    txs.valid <= inState(sTx);
    txs.user <= Const(0, width: HarborPcieStream.userWidth);
    final txFire = txs.valid & txs.ready;

    List<Conditional> countError() => [
      If(~errCount.and(), then: [errCount < errCount + 1]),
    ];

    List<Conditional> startOp(Logic start, Logic dw) {
      final l0 = laneOf(start);
      return [
        lane0 < l0,
        opDw < dw,
        curAddr < (start & ~Const(beatBytes - 1, width: aw)),
        beatsLeft <
            ((l0.zeroExtend(12) + dw.zeroExtend(12) + (dpb - 1)) >> dpbLog),
        word < 0,
        fabErr < 0,
      ];
    }

    final fill = <Conditional>[];
    for (var j = 0; j < entries; j++) {
      final x = j ~/ dpb;
      final l = j % dpb;
      final cases = <(Logic, Logic)>[
        (
          inRx &
              hdrFire &
              capture.payloadInHeaderBeat &
              lane0Comb.zeroExtend(idxW).eq(j),
          tlpSwapBytes(capture.firstPayloadDw),
        ),
        for (var i = 0; i < n && i <= j; i++)
          (
            payloadFire & rxBase.eq(j - i),
            tlpSwapBytes(rxs.data.slice(32 * i + 31, 32 * i)),
          ),
        (
          inState(sRdata) & rFire & word.eq(x),
          mem.rdataData.slice(32 * l + 31, 32 * l),
        ),
      ];
      fill.add(
        If.block([
          for (final (k, (cond, value)) in cases.indexed)
            k == 0
                ? Iff(cond, [buf[j] < value])
                : ElseIf(cond, [buf[j] < value]),
        ]),
      );
    }

    Sequential(clk, [
      ...fill,
      If(
        reset,
        then: [
          state < sRx,
          pastHeader < 0,
          rxBase < 0,
          errCount < 0,
          opWrite < 0,
          cplStatus < 0,
          txT < 0,
        ],
        orElse: [
          Case(state, [
            CaseItem(Const(sRx, width: 3), [
              If(
                hdrFire,
                then: [
                  hFmtType < tlpFmtType(header),
                  hLenDw <
                      mux(
                        tlpLength(header).eq(0),
                        Const(1024, width: 11),
                        tlpLength(header).zeroExtend(11),
                      ),
                  hFirstBe < tlpFirstBe(header),
                  hLastBe < tlpLastBe(header),
                  hReqId < tlpRequesterId(header),
                  hTag < tlpTag(header),
                  hTc < header.slice(22, 20),
                  hAttr < header.slice(13, 12),
                  hPoison < tlpPoisoned(header),
                  hHit < rxs.user[barHitBit],
                  hBarOff < addrComb.slice(barBits - 1, 0),
                  rxBase <
                      lane0Comb.zeroExtend(idxW) +
                          mux(
                            tlpIs4Dw(header),
                            Const(0, width: idxW),
                            Const(1, width: idxW),
                          ),
                  pastHeader < ~rxs.last,
                ],
                orElse: [
                  If(payloadFire, then: [rxBase < rxBase + n]),
                  If(rxFire & rxs.last, then: [pastHeader < 0]),
                ],
              ),
              If(rxFire & rxs.last, then: [state < sDecode]),
            ]),
            CaseItem(Const(sDecode, width: 3), [
              If.block([
                Iff(hHit & isMWr, [
                  If(
                    hPoison | tooLong,
                    then: [...countError(), state < sRx],
                    orElse: [
                      ...startOp(fabStart, hLenDw),
                      opWrite < 1,
                      state < sReq,
                    ],
                  ),
                ]),
                ElseIf(hHit & isMRd, [
                  rdA < aDw,
                  rdEnd < aDw + hLenDw.zeroExtend(12),
                  rdFirst < 1,
                  rdRemaining < endByte - begin,
                  rdStart < begin,
                  rdFab < fabStart,
                  opWrite < 0,
                  state < sChunk,
                ]),
                ElseIf(nonPosted, [
                  cplStatus < statusUr,
                  rdRemaining < 4,
                  rdStart < 0,
                  cDw < 0,
                  txT < 0,
                  state < sTx,
                ]),
                Else([state < sRx]),
              ]),
            ]),
            CaseItem(Const(sChunk, width: 3), [
              cDw < chunkDw,
              rdStop < stop,
              ...startOp(rdFab, chunkDw),
              state < sReq,
            ]),
            CaseItem(Const(sReq, width: 3), [
              If(
                reqFire,
                then: [
                  burstLeft < burst.slice(8, 0),
                  beatsLeft < beatsLeft - burst.slice(11, 0),
                  curAddr < curAddr + (burst.zeroExtend(aw) << sizeLog),
                  state <
                      mux(
                        opWrite,
                        Const(sWdata, width: 3),
                        Const(sRdata, width: 3),
                      ),
                ],
              ),
            ]),
            CaseItem(Const(sWdata, width: 3), [
              If(
                wFire,
                then: [
                  word < word + 1,
                  burstLeft < burstLeft - 1,
                  If(burstLeft.eq(1), then: [state < sWresp]),
                ],
              ),
            ]),
            CaseItem(Const(sWresp, width: 3), [
              If(
                bFire,
                then: [
                  If.block([
                    Iff(mem.wrespErr, [...countError(), state < sRx]),
                    ElseIf(beatsLeft.eq(0), [state < sRx]),
                    Else([state < sReq]),
                  ]),
                ],
              ),
            ]),
            CaseItem(Const(sRdata, width: 3), [
              If(
                rFire,
                then: [
                  word < word + 1,
                  If(mem.rdataErr, then: [fabErr < 1]),
                  If(
                    mem.rdataLast,
                    then: [
                      If(
                        beatsLeft.eq(0) | fabErr | mem.rdataErr,
                        then: [
                          cplStatus <
                              mux(
                                fabErr | mem.rdataErr,
                                Const(statusCa, width: 3),
                                Const(0, width: 3),
                              ),
                          txT < 0,
                          txBase < lane0.zeroExtend(idxW) - 3,
                          state < sTx,
                        ],
                        orElse: [state < sReq],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sTx, width: 3), [
              If(
                txFire,
                then: [
                  If(
                    txLast,
                    then: [
                      If(
                        ~cplData | rdStop.eq(rdEnd),
                        then: [state < sRx],
                        orElse: [state < sChunk],
                      ),
                      rdRemaining <
                          rdRemaining -
                              ((rdStop.zeroExtend(13) << 2) - rdStart),
                      rdStart < rdStop.zeroExtend(13) << 2,
                      rdA < rdStop,
                      rdFab < rdFab + (cDw.zeroExtend(aw) << 2),
                      rdFirst < 0,
                    ],
                    orElse: [txT < txT + n, txBase < txBase + n],
                  ),
                ],
              ),
            ]),
          ]),
        ],
      ),
    ]);
  }
}
