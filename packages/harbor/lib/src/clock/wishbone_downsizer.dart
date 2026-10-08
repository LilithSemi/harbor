import 'package:rohd/rohd.dart';

/// Single-outstanding Wishbone data-width downsizer (2:1).
///
/// Presents a WIDE Wishbone B4 slave (e.g. 64-bit) and drives a NARROW Wishbone
/// B4 master (e.g. 32-bit) on the same clock, turning each wide transaction into
/// two sequential narrow ones: the low half at the request address, the high
/// half at address + [narrowBytes]. Reads assemble `{high, low}`. Writes split
/// `dat_w`/`sel` into their low and high halves.
///
/// Why this exists: the DDR3 controller's datapath is natively 32-bit (one
/// 32-bit word per BL8-selected burst access). On a 64-bit core bus a 64-bit
/// access (every RV64 instruction fetch is a 64-bit read) would otherwise drop
/// its upper half. This bridge lets the proven 32-bit DDR datapath serve a
/// 64-bit bus, one half-word at a time, with no change to the silicon-calibrated
/// PHY. Latency doubles for DDR-backed access, which is negligible next to DRAM
/// latency and the read-burst already on the wire.
///
/// Single-outstanding: the master holds cyc/stb until ack on each half, drops it
/// for the ack cycle, then re-asserts for the second half, so a downstream
/// single-outstanding slave (the DDR bus face, optionally behind the CDC bridge)
/// sees two cleanly separated transactions.
class HarborWishboneDownsizer extends Module {
  /// Address bus width (shared by both faces).
  final int addressWidth;

  /// Wide (slave) data width. Must be exactly twice [narrowWidth].
  final int wideWidth;

  /// Narrow (master) data width.
  final int narrowWidth;

  /// Idle cycles inserted between the two narrow halves and between successive
  /// wide transactions. 0 = fire as fast as the downstream slave acks. A nonzero
  /// pace throttles the DDR access rate to match the spacing that paced accesses
  /// (a software poll loop between accesses) get for free, working around a
  /// streaming-rate read corruption in the DDR PHY/CDC that only appears under
  /// back-to-back access. A correctness knob for bring-up, not a perf feature.
  final int paceCycles;

  /// Per-beat completion-timeout watchdog (cycles). If a narrow beat's `m_ack`
  /// does not arrive within this many cycles, re-issue the beat (drop then
  /// re-assert `m_cyc` on the same address). After [maxReissues] the beat is
  /// force-completed so the wide transaction always acks. This is a LIVENESS
  /// backstop for a lost downstream completion: the upstream CDC bridge has no
  /// watchdog (it assumes `m_ack` is timed and never lost), so without this a
  /// single lost PHY read-valid wedges the whole read chain forever (the creek
  /// Ferrite S-mode read hang). 0 disables it. Default is large so a normal
  /// (fast-ack) access never trips it, leaving in-spec behaviour unchanged.
  final int completionTimeout;

  /// Bounded re-issue budget for [completionTimeout] before force-completing.
  final int maxReissues;

  HarborWishboneDownsizer({
    required this.addressWidth,
    required this.wideWidth,
    required this.narrowWidth,
    this.paceCycles = 0,
    this.completionTimeout = 1024,
    this.maxReissues = 8,
    super.name = 'wishbone_downsizer',
  }) : assert(
         wideWidth == 2 * narrowWidth,
         'downsizer is 2:1 (wideWidth must be 2*narrowWidth)',
       ),
       super(definitionName: 'HarborWishboneDownsizer') {
    final wideSel = wideWidth ~/ 8;
    final narrowSel = narrowWidth ~/ 8;
    final narrowBytes = narrowWidth ~/ 8;

    final clk = addInput('clk', Logic());
    final reset = addInput('reset', Logic());

    // Wide slave face.
    final sCyc = addInput('s_cyc', Logic());
    final sStb = addInput('s_stb', Logic());
    final sWe = addInput('s_we', Logic());
    final sAdr = addInput(
      's_adr',
      Logic(width: addressWidth),
      width: addressWidth,
    );
    final sDatW = addInput(
      's_dat_w',
      Logic(width: wideWidth),
      width: wideWidth,
    );
    final sSel = addInput('s_sel', Logic(width: wideSel), width: wideSel);
    final sAck = addOutput('s_ack');
    final sErr = addOutput('s_err');
    final sDatR = addOutput('s_dat_r', width: wideWidth);

    // Narrow master face.
    final mAck = addInput('m_ack', Logic());
    final mErr = addInput('m_err', Logic());
    final mDatR = addInput(
      'm_dat_r',
      Logic(width: narrowWidth),
      width: narrowWidth,
    );
    final mCyc = addOutput('m_cyc');
    final mStb = addOutput('m_stb');
    final mWe = addOutput('m_we');
    final mAdr = addOutput('m_adr', width: addressWidth);
    final mDatW = addOutput('m_dat_w', width: narrowWidth);
    final mSel = addOutput('m_sel', width: narrowSel);

    // State: 0 idle, 1 low half in flight, 2 gap (pace) before high,
    // 3 high in flight, 4 cooldown (pace) before the next transaction.
    final state = Logic(name: 'state', width: 3);
    final cnt = Logic(name: 'pace_cnt', width: 16);
    final paceC = Const(paceCycles, width: 16);
    final latAdr = Logic(name: 'lat_adr', width: addressWidth);
    final latWe = Logic(name: 'lat_we');
    final latDatW = Logic(name: 'lat_dat_w', width: wideWidth);
    final latSel = Logic(name: 'lat_sel', width: wideSel);
    final rdLo = Logic(name: 'rd_lo', width: narrowWidth);
    final ackReg = Logic(name: 's_ack_reg');
    final errReg = Logic(name: 's_err_reg');
    final datRReg = Logic(name: 's_dat_r_reg', width: wideWidth);
    final mCycReg = Logic(name: 'm_cyc_reg');
    final hiSel = Logic(name: 'hi_sel'); // 0 -> drive low half, 1 -> high half

    // Completion-timeout watchdog: `waitCnt` counts cycles a beat has waited for
    // `m_ack`. On [completionTimeout] re-issue (up to [maxReissues]) then force
    // the beat to complete. Reset per beat and on abort.
    final wdOn = completionTimeout > 0;
    final wdW = wdOn ? (completionTimeout + 1).bitLength : 1;
    final rrW = wdOn ? (maxReissues + 1).bitLength : 1;
    final waitCnt = Logic(name: 'wd_wait', width: wdW);
    final reissues = Logic(name: 'wd_reissues', width: rrW);
    final wdFire = wdOn
        ? waitCnt.gte(Const(completionTimeout, width: wdW))
        : Const(0);
    final wdCanReissue = wdOn
        ? reissues.lt(Const(maxReissues, width: rrW))
        : Const(0);

    // A half is ACTIVE (its narrow access must actually be issued) if this is a
    // READ (both halves are always needed to assemble the 64-bit word) or, for a
    // WRITE, if that half has at least one selected byte. A sub-word store (e.g.
    // a 32-bit sw on the 64-bit bus) selects only one half, so the other half's
    // SEL is all-zero: issuing it as a narrow WRITE would push a spurious,
    // byte-masked write to the DDR whose sibling word it can corrupt if the DDR
    // does not honor the byte mask. Skipping the zero-SEL half removes that write
    // entirely (the correct behavior: a half with no selected bytes is not
    // written), so sub-word stores never touch their sibling.
    final loZero = latSel.getRange(0, narrowSel).eq(Const(0, width: narrowSel));
    final hiZero = latSel
        .getRange(narrowSel, wideSel)
        .eq(Const(0, width: narrowSel));
    final loActive = ~latWe | ~loZero; // low half must be issued
    final hiActive = ~latWe | ~hiZero; // high half must be issued
    // Incoming (state-0) low-half activity, from the un-latched request.
    final loActiveIn =
        ~sWe | ~sSel.getRange(0, narrowSel).eq(Const(0, width: narrowSel));

    // Master-abort: if the master deasserts s_cyc while we are mid-split waiting
    // on a narrow ack (states 1/2/3), tear down and return to idle. Proper
    // Wishbone requires a slave to drop its cycle when cyc falls. It also lets
    // the upstream CDC bridge's completion-timeout RE-ISSUE propagate through the
    // downsizer (Harbor #144: a lost narrow completion would otherwise wedge us
    // in a wait state, deaf to the bridge's retry). The post-ack cooldown
    // (state 4) is left to finish so DDR inter-access pacing is preserved.
    final midWait =
        state.eq(Const(1, width: 3)) |
        state.eq(Const(2, width: 3)) |
        state.eq(Const(3, width: 3));
    Sequential(clk, reset: reset, [
      ackReg < Const(0),
      errReg < Const(0),
      If(
        ~sCyc & midWait,
        then: [
          state < Const(0, width: 3),
          mCycReg < Const(0),
          cnt < Const(0, width: 16),
          hiSel < Const(0),
          waitCnt < Const(0, width: wdW),
          reissues < Const(0, width: rrW),
        ],
        orElse: [
          Case(state, [
            // Idle: accept a new wide transaction. Issue the low narrow access only
            // if it is active (read, or a write that selects a low byte).
            CaseItem(Const(0, width: 3), [
              If(
                sCyc & sStb & ~ackReg,
                then: [
                  latAdr < sAdr,
                  latWe < sWe,
                  latDatW < sDatW,
                  latSel < sSel,
                  hiSel < Const(0),
                  mCycReg < loActiveIn,
                  waitCnt < Const(0, width: wdW),
                  reissues < Const(0, width: rrW),
                  state < Const(1, width: 3),
                ],
              ),
            ]),
            // Low half: wait for the narrow ack (if issued), then pace. If the low
            // half is inactive (a write that selects no low byte), skip straight to
            // the gap without issuing or waiting.
            CaseItem(Const(1, width: 3), [
              If(
                ~loActive,
                then: [
                  mCycReg < Const(0),
                  cnt < Const(0, width: 16),
                  state < Const(2, width: 3),
                ],
                orElse: [
                  If(
                    mCycReg & (mAck | mErr),
                    then: [
                      // An errored low half ends the whole wide transaction
                      // with ERR: the high half is never issued.
                      If(
                        mErr,
                        then: [
                          errReg < Const(1),
                          mCycReg < Const(0),
                          hiSel < Const(0),
                          cnt < Const(0, width: 16),
                          state < Const(4, width: 3),
                        ],
                        orElse: [
                          rdLo < mDatR,
                          mCycReg < Const(0),
                          cnt < Const(0, width: 16),
                          state < Const(2, width: 3),
                        ],
                      ),
                    ],
                    orElse: [
                      // Still waiting on the narrow ack: run the completion watchdog.
                      If(
                        ~mCycReg,
                        then: [
                          mCycReg <
                              Const(1), // re-assert after a re-issue drop cycle
                        ],
                        orElse: [
                          If(
                            wdFire,
                            then: [
                              If(
                                wdCanReissue,
                                then: [
                                  mCycReg <
                                      Const(
                                        0,
                                      ), // drop m_cyc: re-issue this beat
                                  waitCnt < Const(0, width: wdW),
                                  reissues < reissues + 1,
                                ],
                                orElse: [
                                  // budget spent: report ERR instead of
                                  // acking with unverified (poison) data.
                                  errReg < Const(1),
                                  mCycReg < Const(0),
                                  hiSel < Const(0),
                                  cnt < Const(0, width: 16),
                                  state < Const(4, width: 3),
                                ],
                              ),
                            ],
                            orElse: [waitCnt < waitCnt + 1],
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            // Gap: hold m_cyc low for paceCycles, then issue the high half only if it
            // is active.
            CaseItem(Const(2, width: 3), [
              If(
                cnt.gte(paceC),
                then: [
                  hiSel < Const(1),
                  mCycReg < hiActive,
                  waitCnt < Const(0, width: wdW),
                  reissues < Const(0, width: rrW),
                  state < Const(3, width: 3),
                ],
                orElse: [cnt < cnt + 1],
              ),
            ]),
            // High half: wait, assemble, ack, then cool down. If the high half is
            // inactive (a write that selects no high byte), ack without issuing it.
            CaseItem(Const(3, width: 3), [
              If(
                ~hiActive,
                then: [
                  ackReg < Const(1),
                  mCycReg < Const(0),
                  hiSel < Const(0),
                  cnt < Const(0, width: 16),
                  state < Const(4, width: 3),
                ],
                orElse: [
                  If(
                    mCycReg & (mAck | mErr),
                    then: [
                      If(
                        mErr,
                        then: [
                          errReg < Const(1),
                          mCycReg < Const(0),
                          hiSel < Const(0),
                          cnt < Const(0, width: 16),
                          state < Const(4, width: 3),
                        ],
                        orElse: [
                          datRReg < [mDatR, rdLo].swizzle(),
                          ackReg < Const(1),
                          mCycReg < Const(0),
                          hiSel < Const(0),
                          cnt < Const(0, width: 16),
                          state < Const(4, width: 3),
                        ],
                      ),
                    ],
                    orElse: [
                      // Still waiting on the narrow ack: run the completion watchdog.
                      If(
                        ~mCycReg,
                        then: [
                          mCycReg <
                              Const(1), // re-assert after a re-issue drop cycle
                        ],
                        orElse: [
                          If(
                            wdFire,
                            then: [
                              If(
                                wdCanReissue,
                                then: [
                                  mCycReg <
                                      Const(
                                        0,
                                      ), // drop m_cyc: re-issue this beat
                                  waitCnt < Const(0, width: wdW),
                                  reissues < reissues + 1,
                                ],
                                orElse: [
                                  // budget spent: report ERR instead of
                                  // acking with unverified (poison) data.
                                  errReg < Const(1),
                                  mCycReg < Const(0),
                                  hiSel < Const(0),
                                  cnt < Const(0, width: 16),
                                  state < Const(4, width: 3),
                                ],
                              ),
                            ],
                            orElse: [waitCnt < waitCnt + 1],
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            // Cooldown: idle for paceCycles before accepting the next transaction.
            CaseItem(Const(4, width: 3), [
              If(
                cnt.gte(paceC),
                then: [state < Const(0, width: 3)],
                orElse: [cnt < cnt + 1],
              ),
            ]),
          ]),
        ],
      ),
    ]);

    // ACK and ERR are mutually exclusive (only one of ackReg/errReg is ever
    // set per cycle) and gated by CYC & STB so a stray pulse can never land
    // on an unrelated later cycle.
    sAck <= ackReg & sCyc & sStb;
    sErr <= errReg & sCyc & sStb;
    sDatR <= datRReg;

    mCyc <= mCycReg;
    mStb <= mCycReg;
    mWe <= latWe;
    mAdr <=
        mux(hiSel, latAdr + Const(narrowBytes, width: addressWidth), latAdr);
    mDatW <=
        mux(
          hiSel,
          latDatW.getRange(narrowWidth, wideWidth),
          latDatW.getRange(0, narrowWidth),
        );
    mSel <=
        mux(
          hiSel,
          latSel.getRange(narrowSel, wideSel),
          latSel.getRange(0, narrowSel),
        );
  }
}
