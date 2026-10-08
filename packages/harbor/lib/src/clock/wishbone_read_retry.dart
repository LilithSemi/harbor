import 'package:rohd/rohd.dart';

/// Single-outstanding Wishbone read-retry / read-voting filter.
///
/// Presents a Wishbone B4 slave and drives a Wishbone B4 master of the SAME
/// width on the same clock. WRITES pass through 1:1. READS are issued to the
/// master REPEATEDLY until two CONSECUTIVE reads return the same word, and only
/// then is the slave acked with that word. A [maxTries] cap guarantees liveness.
///
/// Why this exists: on the creek OrangeCrab the DLL-off static DDR3 read has an
/// irreducible metastability residual: a word occasionally reads back wrong
/// (the low 16-bit beat captures the dead q0 transition zone), and the SAME word
/// re-reads CORRECT (HW-measured: the FSBL verify reports "matches on re-read").
/// Centering the read tap cuts it to ~1-2 words per image but cannot reach zero,
/// and the robust DQS-DATAVALID read does not fit the 25F alongside the L1
/// icache. Because the glitch is intermittent and uncorrelated, reading each
/// word twice and re-reading on mismatch converges to the correct value with
/// tiny logic that DOES fit, trading ~2x read latency (negligible next to DRAM
/// latency, and reads are already paced through the CDC bridge) for reliable
/// reads. A correctness filter, not a perf feature, sits in front of the DDR bus
/// face. Mirrors [HarborWishboneDownsizer]'s single-outstanding handshake.
class HarborWishboneReadRetry extends Module {
  /// Address bus width.
  final int addressWidth;

  /// Data bus width (slave and master, same).
  final int dataWidth;

  /// Maximum read issues before giving up and returning the latest word (a
  /// liveness backstop. Two consecutive agreeing reads normally settle in 2).
  final int maxTries;

  HarborWishboneReadRetry({
    required this.addressWidth,
    required this.dataWidth,
    this.maxTries = 8,
    super.name = 'wishbone_read_retry',
  }) : assert(maxTries >= 2, 'maxTries must be >= 2'),
       super(definitionName: 'HarborWishboneReadRetry') {
    final selWidth = dataWidth ~/ 8;
    final triesW = (maxTries + 1).bitLength;

    final clk = addInput('clk', Logic());
    final reset = addInput('reset', Logic());

    // Slave face.
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
      Logic(width: dataWidth),
      width: dataWidth,
    );
    final sSel = addInput('s_sel', Logic(width: selWidth), width: selWidth);
    final sAck = addOutput('s_ack');
    final sErr = addOutput('s_err');
    final sDatR = addOutput('s_dat_r', width: dataWidth);

    // Master face.
    final mAck = addInput('m_ack', Logic());
    final mErr = addInput('m_err', Logic());
    final mDatR = addInput(
      'm_dat_r',
      Logic(width: dataWidth),
      width: dataWidth,
    );
    final mCyc = addOutput('m_cyc');
    final mStb = addOutput('m_stb');
    final mWe = addOutput('m_we');
    final mAdr = addOutput('m_adr', width: addressWidth);
    final mDatW = addOutput('m_dat_w', width: dataWidth);
    final mSel = addOutput('m_sel', width: selWidth);

    // State: 0 idle, 1 write in flight, 2 read in flight, 3 read gap (one
    // cyc-low cycle between successive read issues so the single-outstanding
    // downstream sees separated transactions).
    final state = Logic(name: 'state', width: 2);
    final latAdr = Logic(name: 'lat_adr', width: addressWidth);
    final latWe = Logic(name: 'lat_we');
    final latDatW = Logic(name: 'lat_dat_w', width: dataWidth);
    final latSel = Logic(name: 'lat_sel', width: selWidth);
    // Previous read value + whether one has been captured yet this transaction.
    final prev = Logic(name: 'prev_rd', width: dataWidth);
    final prevValid = Logic(name: 'prev_valid');
    final tries = Logic(name: 'tries', width: triesW);
    final ackReg = Logic(name: 's_ack_reg');
    final errReg = Logic(name: 's_err_reg');
    final datRReg = Logic(name: 's_dat_r_reg', width: dataWidth);
    final mCycReg = Logic(name: 'm_cyc_reg');

    final curD = mDatR;
    // On a fresh read result, "settled" iff it matches the previous read.
    final settled = prevValid & curD.eq(prev);
    // Reaching the last allowed try forces a return (liveness).
    final lastTry = tries.gte(Const(maxTries - 1, width: triesW));

    // Master-abort: if the master drops s_cyc while a write or a read (or
    // its gap) is outstanding, tear down and return to idle instead of
    // chasing a request nobody wants anymore.
    final midWait =
        state.eq(Const(1, width: 2)) |
        state.eq(Const(2, width: 2)) |
        state.eq(Const(3, width: 2));

    Sequential(clk, reset: reset, [
      ackReg < Const(0),
      errReg < Const(0),
      If(
        ~sCyc & midWait,
        then: [state < Const(0, width: 2), mCycReg < Const(0)],
        orElse: [
          Case(state, [
            // Idle: accept a new transaction.
            CaseItem(Const(0, width: 2), [
              If(
                sCyc & sStb & ~ackReg & ~errReg,
                then: [
                  latAdr < sAdr,
                  latWe < sWe,
                  latDatW < sDatW,
                  latSel < sSel,
                  prevValid < Const(0),
                  tries < Const(0, width: triesW),
                  mCycReg < Const(1),
                  state < mux(sWe, Const(1, width: 2), Const(2, width: 2)),
                ],
              ),
            ]),
            // Write in flight: single pass-through, terminate on the
            // master's ack or err (never both; RTY or no response yet
            // simply holds and re-presents the same write).
            CaseItem(Const(1, width: 2), [
              If(
                mCycReg & (mAck | mErr),
                then: [
                  mCycReg < Const(0),
                  state < Const(0, width: 2),
                  If(
                    mErr,
                    then: [errReg < Const(1)],
                    orElse: [datRReg < mDatR, ackReg < Const(1)],
                  ),
                ],
              ),
            ]),
            // Read in flight: an error is authoritative and ends the
            // transaction immediately (not subject to read-voting).
            // Otherwise capture the word, ack if it agrees with the
            // previous read (or the try cap is hit), else record it and
            // issue another read.
            CaseItem(Const(2, width: 2), [
              If(
                mCycReg & (mAck | mErr),
                then: [
                  mCycReg < Const(0),
                  If(
                    mErr,
                    then: [errReg < Const(1), state < Const(0, width: 2)],
                    orElse: [
                      If(
                        settled | lastTry,
                        then: [
                          datRReg < curD,
                          ackReg < Const(1),
                          state < Const(0, width: 2),
                        ],
                        orElse: [
                          prev < curD,
                          prevValid < Const(1),
                          tries < tries + 1,
                          state < Const(3, width: 2), // gap, then re-read
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            // Read gap: one cyc-low cycle, then re-issue the read.
            CaseItem(Const(3, width: 2), [
              mCycReg < Const(1),
              state < Const(2, width: 2),
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
    mAdr <= latAdr;
    mDatW <= latDatW;
    mSel <= latSel;
  }
}
