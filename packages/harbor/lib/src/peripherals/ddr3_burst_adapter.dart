import 'package:rohd/rohd.dart';

/// Width/burst + flow-control adapter between the SoC's narrow Wishbone-B4 bus
/// (ACK-only, [busDataWidth]-bit, e.g. 32) and the [Ddr3Controller]'s wide,
/// pipelined interface (one word = one BL8 burst, e.g. 128-bit, with a stall).
///
/// Bus `adr` is a byte address. The burst address is `adr >> log2(ddrSelWidth)`
/// and the word-in-burst is the bits between the two byte offsets.
///
/// ## Writes
///
/// Writes are posted: the adapter ACKs the bus as soon as the command is safe,
/// and it does not wait for DRAM. Two mechanisms keep the command rate up.
///
///  - The adapter accepts a new bus request immediately after it releases the
///    previous write to the controller. The controller ABORTS an in-flight
///    request when `cyc` drops, so `cyc` stays asserted for
///    [writeDrainCycles] more cycles after the last write. A following write
///    arrives well inside that window, so a stream of writes holds `cyc`
///    continuously and pays the drain only once, at the end.
///  - With [writeCombine], the adapter holds ONE dirty burst. A write whose
///    burst address matches the held burst is merged into it and ACKed with no
///    DRAM command at all, so four sequential narrow words become one BL8
///    burst. A write to a different burst flushes the held burst first. The
///    byte-enables accumulate, so DDR3 DM still masks the untouched bytes and
///    no read-modify-write is needed.
///
/// The held burst is flushed when: a write addresses a different burst, a read
/// addresses the SAME burst (the read hazard), or the bus is idle for
/// [flushIdleCycles]. The idle flush is what lands the tail of a transfer.
///
/// ## Reads
///
/// A narrow read issues ONE wide burst read, waits for the controller's read
/// ACK, then muxes out the addressed narrow word. Reads are strictly ordered
/// against the held burst by the flush above. One read is outstanding at a
/// time.
///
/// The controller also ACKs writes, in command order, and echoes `aux` with
/// each ACK. Writes carry aux 1. A read carries a tag with bit 0 clear and a
/// sequence number above it, and only the ACK with that tag completes the
/// read.
///
/// `ctrl_reset` is the reset of the controller. When only `reset` asserts, a
/// read can still be in the controller, so the adapter skips that read tag.
class Ddr3BurstAdapter extends Module {
  final int busDataWidth;
  final int ddrDataWidth;
  final int busAddrWidth;
  final int ddrAddrWidth;
  final int auxWidth;

  /// Merge sequential narrow writes into one wide burst before issuing them.
  final bool writeCombine;

  /// Cycles to hold `cyc` after a write is accepted, so the controller does not
  /// abort it. A following write re-arms this, so a stream pays it only once.
  final int writeDrainCycles;

  /// Idle cycles before a held dirty burst is flushed to DRAM.
  final int flushIdleCycles;

  /// Narrow words per burst (e.g. 128/32 = 4).
  int get ratio => ddrDataWidth ~/ busDataWidth;
  int get _ratioBits => _clog2(ratio);
  int get busSelWidth => busDataWidth ~/ 8;
  int get ddrSelWidth => ddrDataWidth ~/ 8;

  Ddr3BurstAdapter({
    required this.busAddrWidth,
    required this.ddrAddrWidth,
    this.busDataWidth = 32,
    this.ddrDataWidth = 128,
    this.auxWidth = 4,
    this.writeCombine = true,
    this.writeDrainCycles = 31,
    this.flushIdleCycles = 64,
    // --- narrow B4 slave side ---
    required Logic clk,
    required Logic reset,
    Logic? ctrlReset,
    required Logic sCyc,
    required Logic sStb,
    required Logic sWe,
    required Logic sAddr,
    required Logic sData,
    required Logic sSel,
    // --- wide controller read-return / status side ---
    required Logic mStall,
    required Logic mAck, // controller o_wb_ack (reads and writes)
    required Logic mAckAux, // controller o_aux, aligned with o_wb_ack
    required Logic mData, // controller o_wb_data (wide)
    super.name = 'ddr3_burst_adapter',
  }) {
    assert(ddrDataWidth % busDataWidth == 0, 'ratio must be integral');
    assert(writeDrainCycles >= 1, 'writeDrainCycles must be at least 1');
    assert(flushIdleCycles >= 1, 'flushIdleCycles must be at least 1');
    assert(auxWidth >= 1, 'auxWidth must be at least 1');
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    // Without a controller reset, every reset also resets the controller.
    final hardReset = ctrlReset == null
        ? reset
        : addInput('ctrl_reset', ctrlReset);
    sCyc = addInput('s_cyc', sCyc);
    sStb = addInput('s_stb', sStb);
    sWe = addInput('s_we', sWe);
    sAddr = addInput('s_addr', sAddr, width: busAddrWidth);
    sData = addInput('s_data', sData, width: busDataWidth);
    sSel = addInput('s_sel', sSel, width: busSelWidth);
    mStall = addInput('m_stall', mStall);
    mAck = addInput('m_ack', mAck);
    mAckAux = addInput('m_ack_aux', mAckAux, width: auxWidth);
    mData = addInput('m_data', mData, width: ddrDataWidth);

    // Narrow slave responses.
    final sAck = addOutput('s_ack');
    final sDataOut = addOutput('s_data_out', width: busDataWidth);
    // Wide controller drive.
    final mCyc = addOutput('m_cyc');
    final mStb = addOutput('m_stb');
    final mWe = addOutput('m_we');
    final mAddr = addOutput('m_addr', width: ddrAddrWidth);
    final mDataOut = addOutput('m_data_out', width: ddrDataWidth);
    final mSel = addOutput('m_sel', width: ddrSelWidth);
    final mAux = addOutput('m_aux', width: auxWidth);

    const stIdle = 0; // accept a request; hold cyc while draining
    const stIssue =
        1; // pass-through command (read, or write when not combining)
    const stReadWait = 2; // await the controller read ack
    const stFlush = 3; // flush the held burst to service a pending request
    const stFlushIdle = 4; // flush the held burst after an idle timeout

    final drainW = writeDrainCycles.bitLength;
    final idleW = flushIdleCycles.bitLength;

    final st = Logic(name: 'st', width: 3);
    final wordSel = Logic(name: 'word_sel', width: _ratioBits); // low addr bits
    final isWrite = Logic(name: 'is_write');
    final rdData = Logic(name: 'rd_data', width: busDataWidth);
    final ackReg = Logic(name: 'ack_reg');
    // One command per request. ACK is a one-cycle pulse, so a master that keeps
    // its request on the port past the ACK would otherwise be served again and
    // the command would be issued twice. Released when the request drops.
    final served = Logic(name: 'served');
    final drainCnt = Logic(name: 'wr_drain', width: drainW);
    final idleCnt = Logic(name: 'idle_cnt', width: idleW);
    final seqW = auxWidth - 1;
    final rdSeq = seqW > 0 ? Logic(name: 'rd_seq', width: seqW) : null;
    final rdTag = (rdSeq == null ? Const(0) : [rdSeq, Const(0)].swizzle())
        .named('rd_tag');

    // The one held dirty burst (write combining).
    final wbValid = Logic(name: 'wc_valid');
    final wbAddr = Logic(name: 'wc_addr', width: ddrAddrWidth);
    final wbData = Logic(name: 'wc_data', width: ddrDataWidth);
    final wbSel = Logic(name: 'wc_sel', width: ddrSelWidth);

    // BYTE-addressed bus: addr[busByteBits-1:0] = byte-in-narrow-word (ignored),
    // addr[ddrByteBits-1:busByteBits] = which narrow word within the burst,
    // addr[.. :ddrByteBits] = the wide-burst (BL8) address.
    final busByteBits = _clog2(busSelWidth);
    final ddrByteBits = _clog2(ddrSelWidth);
    final curWord = sAddr.getRange(busByteBits, ddrByteBits);
    final burstAddr = (busAddrWidth >= ddrByteBits + ddrAddrWidth)
        ? sAddr.getRange(ddrByteBits, ddrByteBits + ddrAddrWidth)
        : sAddr.getRange(ddrByteBits, busAddrWidth).zeroExtend(ddrAddrWidth);

    // Position the narrow write data + byte-enables into the wide word.
    Logic placedData(Logic word) => cases(
      word,
      {
        for (var w = 0; w < ratio; w++)
          Const(w, width: _ratioBits): [
            if (w < ratio - 1) Const(0, width: (ratio - 1 - w) * busDataWidth),
            sData,
            if (w > 0) Const(0, width: w * busDataWidth),
          ].swizzle(),
      },
      defaultValue: Const(0, width: ddrDataWidth),
      conditionalType: ConditionalType.unique,
    );
    Logic placedSel(Logic word) => cases(
      word,
      {
        for (var w = 0; w < ratio; w++)
          Const(w, width: _ratioBits): [
            if (w < ratio - 1) Const(0, width: (ratio - 1 - w) * busSelWidth),
            sSel,
            if (w > 0) Const(0, width: w * busSelWidth),
          ].swizzle(),
      },
      defaultValue: Const(0, width: ddrSelWidth),
      conditionalType: ConditionalType.unique,
    );
    // Extract the addressed narrow word from a wide read burst.
    Logic pickWord(Logic wide, Logic word) => cases(
      word,
      {
        for (var w = 0; w < ratio; w++)
          Const(w, width: _ratioBits): wide.getRange(
            w * busDataWidth,
            (w + 1) * busDataWidth,
          ),
      },
      defaultValue: wide.getRange(0, busDataWidth),
      conditionalType: ConditionalType.unique,
    );
    // One byte-enable bit becomes eight data-mask bits.
    Logic expandSel(Logic sel) => [
      for (var b = ddrSelWidth - 1; b >= 0; b--) sel[b].replicate(8),
    ].swizzle();

    // The held burst with the current narrow write merged into it. Bytes the
    // new write does not select keep their held value.
    final newSel = placedSel(curWord).named('wc_new_sel');
    final newMask = expandSel(newSel).named('wc_new_mask');
    final mergedData = ((wbData & ~newMask) | (placedData(curWord) & newMask))
        .named('wc_merged_data');
    final sameBurst = (wbValid & burstAddr.eq(wbAddr)).named('wc_same_burst');
    final otherBurst = (wbValid & ~burstAddr.eq(wbAddr)).named(
      'wc_other_burst',
    );

    // Combinational wide-master + narrow-ack drive off the registered state.
    Combinational([
      mCyc < Const(0),
      mStb < Const(0),
      mWe < Const(0),
      mAddr < Const(0, width: ddrAddrWidth),
      mDataOut < Const(0, width: ddrDataWidth),
      mSel < Const(0, width: ddrSelWidth),
      mAux < Const(1, width: auxWidth),
      If(
        st.eq(stIssue),
        then: [
          mCyc < Const(1),
          mStb < Const(1),
          mWe < isWrite,
          mAddr < burstAddr,
          mDataOut < placedData(wordSel),
          mSel < mux(isWrite, placedSel(wordSel), Const(0, width: ddrSelWidth)),
          mAux < mux(isWrite, Const(1, width: auxWidth), rdTag),
        ],
      ),
      // Keep cyc while awaiting a read ack.
      If(st.eq(stReadWait), then: [mCyc < Const(1)]),
      if (writeCombine)
        // Flush the held burst. The pending request is still on the slave port,
        // so the command must come from the held registers, not from sAddr.
        If(
          st.eq(stFlush) | st.eq(stFlushIdle),
          then: [
            mCyc < Const(1),
            mStb < Const(1),
            mWe < Const(1),
            mAddr < wbAddr,
            mDataOut < wbData,
            mSel < wbSel,
          ],
        ),
      // Hold cyc through the post-write drain so the controller does not abort
      // the last accepted write.
      If(
        st.eq(stIdle) & drainCnt.neq(Const(0, width: drainW)),
        then: [mCyc < Const(1)],
      ),
    ]);
    sAck <= ackReg;
    sDataOut <= rdData;

    Sequential(clk, [
      If(
        reset | hardReset,
        then: [
          st < Const(stIdle, width: 3),
          wordSel < Const(0, width: _ratioBits),
          isWrite < Const(0),
          rdData < Const(0, width: busDataWidth),
          ackReg < Const(0),
          served < Const(0),
          drainCnt < Const(0, width: drainW),
          idleCnt < Const(0, width: idleW),
          wbValid < Const(0),
          wbAddr < Const(0, width: ddrAddrWidth),
          wbData < Const(0, width: ddrDataWidth),
          wbSel < Const(0, width: ddrSelWidth),
          // The controller can still return a read issued before a reset of
          // this side only. Skip its tag so that ACK cannot match a new read.
          if (rdSeq != null)
            If(
              hardReset,
              then: [rdSeq < Const(0, width: seqW)],
              orElse: [
                If(
                  st.eq(stIssue) | st.eq(stReadWait),
                  then: [rdSeq < rdSeq + 1],
                ),
              ],
            ),
        ],
        orElse: [
          ackReg < Const(0), // single-cycle ack pulse by default
          // Re-arm for the next request as soon as this one leaves the port.
          If(~(sCyc & sStb), then: [served < Const(0)]),
          Case(
            st,
            [
              CaseItem(Const(stIdle, width: 3), [
                If(
                  drainCnt.neq(Const(0, width: drainW)),
                  then: [drainCnt < drainCnt - 1],
                ),
                If(
                  sCyc & sStb & ~served,
                  then: [
                    served < Const(1),
                    idleCnt < Const(0, width: idleW),
                    if (!writeCombine) ...[
                      wordSel < curWord,
                      isWrite < sWe,
                      st < Const(stIssue, width: 3),
                    ] else ...[
                      If(
                        sWe,
                        then: [
                          If(
                            otherBurst,
                            // Only one burst is held: make room first.
                            then: [
                              isWrite < Const(1),
                              st < Const(stFlush, width: 3),
                            ],
                            // Merge into the held burst, or start a new one.
                            // Either way no DRAM command is needed.
                            orElse: [
                              wbAddr < burstAddr,
                              wbData <
                                  mux(wbValid, mergedData, placedData(curWord)),
                              wbSel < mux(wbValid, wbSel | newSel, newSel),
                              wbValid < Const(1),
                              ackReg < Const(1),
                            ],
                          ),
                        ],
                        orElse: [
                          isWrite < Const(0),
                          If(
                            sameBurst,
                            // Read hazard: the held burst has bytes this read
                            // must see. Land it before the read is issued.
                            then: [st < Const(stFlush, width: 3)],
                            orElse: [
                              wordSel < curWord,
                              st < Const(stIssue, width: 3),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ],
                  orElse: [
                    if (writeCombine)
                      If(
                        wbValid,
                        then: [
                          If(
                            idleCnt.gte(
                              Const(flushIdleCycles - 1, width: idleW),
                            ),
                            then: [st < Const(stFlushIdle, width: 3)],
                            orElse: [idleCnt < idleCnt + 1],
                          ),
                        ],
                      ),
                  ],
                ),
              ]),
              CaseItem(Const(stIssue, width: 3), [
                // Hold the wide command until the controller accepts it.
                If(
                  ~mStall,
                  then: [
                    If(
                      isWrite,
                      then: [
                        // Posted write: ack on accept and take the next request
                        // straight away. drainCnt keeps cyc up meanwhile.
                        ackReg < Const(1),
                        drainCnt < Const(writeDrainCycles, width: drainW),
                        st < Const(stIdle, width: 3),
                      ],
                      orElse: [
                        st < Const(stReadWait, width: 3), // await data ack
                      ],
                    ),
                  ],
                ),
              ]),
              CaseItem(Const(stReadWait, width: 3), [
                // Capture the addressed word on this read's ack. Write acks
                // still in the pipe carry a different tag.
                If(
                  mAck & mAckAux.eq(rdTag),
                  then: [
                    rdData < pickWord(mData, wordSel),
                    ackReg < Const(1),
                    if (rdSeq != null) rdSeq < rdSeq + 1,
                    st < Const(stIdle, width: 3),
                  ],
                ),
              ]),
              if (writeCombine) ...[
                CaseItem(Const(stFlush, width: 3), [
                  If(
                    ~mStall,
                    then: [
                      drainCnt < Const(writeDrainCycles, width: drainW),
                      idleCnt < Const(0, width: idleW),
                      If(
                        isWrite,
                        // The buffer is free now: absorb the pending write into
                        // it and ack, so the flush cost is one command per four
                        // narrow words, not one per word.
                        then: [
                          wbAddr < burstAddr,
                          wbData < placedData(curWord),
                          wbSel < newSel,
                          wbValid < Const(1),
                          ackReg < Const(1),
                          st < Const(stIdle, width: 3),
                        ],
                        // The pending read can go now that DRAM is current.
                        orElse: [
                          wbValid < Const(0),
                          wbSel < Const(0, width: ddrSelWidth),
                          wordSel < curWord,
                          st < Const(stIssue, width: 3),
                        ],
                      ),
                    ],
                  ),
                ]),
                CaseItem(Const(stFlushIdle, width: 3), [
                  If(
                    ~mStall,
                    then: [
                      wbValid < Const(0),
                      wbSel < Const(0, width: ddrSelWidth),
                      drainCnt < Const(writeDrainCycles, width: drainW),
                      idleCnt < Const(0, width: idleW),
                      st < Const(stIdle, width: 3),
                    ],
                  ),
                ]),
              ],
            ],
            conditionalType: ConditionalType.unique,
            defaultItem: [st < Const(stIdle, width: 3)],
          ),
        ],
      ),
    ]);
  }

  static int _clog2(int x) {
    var n = 0;
    var v = x - 1;
    while (v > 0) {
      v >>= 1;
      n++;
    }
    return n;
  }
}
