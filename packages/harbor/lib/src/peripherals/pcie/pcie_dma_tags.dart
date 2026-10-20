import 'dart:async';
import 'dart:math';

import 'package:rohd/rohd.dart';

import 'pcie_stream.dart';

/// The read tags of the PCIe DMA engine and their reorder buffer.
///
/// The engine gives tags in order. Each tag has a slot of
/// [maxReadRequestBytes] in the buffer. Completions for a tag write their
/// payload at the next offset of its slot. The engine drains the oldest slot
/// when all its bytes are in, then frees it.
///
/// A tag value is `(base + slot) mod 32`. An abort frees all slots. When a
/// read was still in flight, it also moves base forward by the slot count.
/// Thus a completion for a request from before the abort does not match a
/// new request, until base wraps.
///
/// With [reservedTags] 1, slot [readTags] is reserved for another reader.
/// It has no buffer. A completion for it gives `reserved_cpl` and nothing
/// more.
///
/// A completion for a tag that is not in flight is dropped and counted in
/// `stale_count`. A completion for a tag in flight with an error gives
/// `err` with code 1 (status not SC), 3 (poisoned) or 6 (length, byte count
/// or lower address does not fit). A tag that waits [timeoutCycles] gives
/// code 2.
class HarborPcieDmaTags extends Module {
  static const codeCompletion = 1;
  static const codeTimeout = 2;
  static const codePoisoned = 3;
  static const codeLength = 6;

  /// Stream width in bits.
  final int width;

  /// Fabric data width in bits. The drain reads this many bits per beat.
  final int dataWidth;

  final int addressWidth;
  final int readTags;
  final int reservedTags;
  final int maxReadRequestBytes;
  final int timeoutCycles;

  /// Width of a slot index.
  final int slotWidth;

  /// Width of a DW index in the buffer.
  final int indexWidth;

  Logic get issueReady => output('issue_ready');
  Logic get issueTag => output('issue_tag');
  Logic get reservedTag => output('reserved_tag');
  Logic get reservedCpl => output('reserved_cpl');
  Logic get headReady => output('head_ready');
  Logic get headSlot => output('head_slot');
  Logic get headLocal => output('head_local');
  Logic get headLen => output('head_len');
  Logic get busy => output('busy');
  Logic get err => output('err');
  Logic get errCode => output('err_code');
  Logic get staleCount => output('stale_count');

  /// DWs at `rd_index` and later of slot `rd_slot`, one cycle after them.
  Logic get rdData => output('rd_data');

  HarborPcieDmaTags({
    required Logic clk,
    required Logic reset,
    required Logic abort,
    required Logic clearStale,
    required Logic cplHeader,
    required Logic header,
    required Logic firstDw,
    required Logic rxFire,
    required Logic rxLast,
    required Logic rxData,
    required Logic issue,
    required Logic issueLen,
    required Logic issueLocal,
    required Logic issueHostLow,
    required Logic drainDone,
    required Logic rdSlot,
    required Logic rdIndex,
    required this.dataWidth,
    required this.addressWidth,
    required this.readTags,
    required this.maxReadRequestBytes,
    required this.timeoutCycles,
    this.reservedTags = 0,
    super.name = 'pcie_dma_tags',
  }) : width = rxData.width,
       slotWidth = max(1, (readTags - 1).bitLength),
       indexWidth =
           max(1, (readTags - 1).bitLength) +
           (maxReadRequestBytes ~/ 4 - 1).bitLength,
       super(
         definitionName:
             'HarborPcieDmaTags_W${rxData.width}_D${dataWidth}_A$addressWidth'
             '_T${readTags}_V${reservedTags}_R${maxReadRequestBytes}'
             '_O$timeoutCycles',
       ) {
    if (reservedTags < 0 || reservedTags > 1) {
      throw RangeError.range(reservedTags, 0, 1, 'reservedTags');
    }
    // At most 16 slots, so a tag value comes back only after two aborts with
    // reads in flight.
    if (readTags < 1 || readTags + reservedTags > 16) {
      throw RangeError.range(readTags, 1, 16 - reservedTags, 'readTags');
    }
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    abort = addInput('abort', abort);
    clearStale = addInput('clear_stale', clearStale);
    cplHeader = addInput('cpl_header', cplHeader);
    header = addInput('header', header, width: 128);
    firstDw = addInput('first_dw', firstDw, width: 32);
    rxFire = addInput('rx_fire', rxFire);
    rxLast = addInput('rx_last', rxLast);
    rxData = addInput('rx_data', rxData, width: width);
    issue = addInput('issue', issue);
    issueLen = addInput('issue_len', issueLen, width: 13);
    issueLocal = addInput('issue_local', issueLocal, width: addressWidth);
    issueHostLow = addInput('issue_host_low', issueHostLow, width: 7);
    drainDone = addInput('drain_done', drainDone);
    rdSlot = addInput('rd_slot', rdSlot, width: slotWidth);
    rdIndex = addInput('rd_index', rdIndex, width: indexWidth);
    _build(
      clk,
      reset,
      abort,
      clearStale,
      cplHeader,
      header,
      firstDw,
      rxFire,
      rxLast,
      rxData,
      issue,
      issueLen,
      issueLocal,
      issueHostLow,
      drainDone,
      rdSlot,
      rdIndex,
    );
  }

  static int _log2(int v) => v.bitLength - 1;

  void _build(
    Logic clk,
    Logic reset,
    Logic abort,
    Logic clearStale,
    Logic cplHeader,
    Logic header,
    Logic firstDw,
    Logic rxFire,
    Logic rxLast,
    Logic rxData,
    Logic issue,
    Logic issueLen,
    Logic issueLocal,
    Logic issueHostLow,
    Logic drainDone,
    Logic rdSlot,
    Logic rdIndex,
  ) {
    final n = width ~/ 32;
    final dpb = dataWidth ~/ 32;
    final banks = max(n, dpb);
    final bLog = _log2(banks);
    final slotDw = maxReadRequestBytes ~/ 4;
    final sLog = _log2(slotDw);
    final sw = slotWidth;
    final gw = indexWidth;
    final bankDepth = readTags * slotDw ~/ banks;
    final bankAw = (bankDepth - 1).bitLength.clamp(1, 32);
    final slots = readTags + reservedTags;
    final tw = max(1, timeoutCycles.bitLength);

    final base = Logic(name: 'base', width: 5);
    final allocPtr = Logic(name: 'alloc_ptr', width: sw);
    final headPtr = Logic(name: 'head_ptr', width: sw);
    final count = Logic(name: 'count', width: sw + 1);
    final stale = Logic(name: 'stale', width: 16);

    final sBusy = [for (var i = 0; i < readTags; i++) Logic(name: 'busy_$i')];
    final sDone = [for (var i = 0; i < readTags; i++) Logic(name: 'done_$i')];
    final sLen = [
      for (var i = 0; i < readTags; i++) Logic(name: 'len_$i', width: 13),
    ];
    final sRecv = [
      for (var i = 0; i < readTags; i++) Logic(name: 'recv_$i', width: 13),
    ];
    final sHost = [
      for (var i = 0; i < readTags; i++) Logic(name: 'host_$i', width: 7),
    ];
    final sLocal = [
      for (var i = 0; i < readTags; i++)
        Logic(name: 'local_$i', width: addressWidth),
    ];
    final sTimer = [
      for (var i = 0; i < readTags; i++) Logic(name: 'timer_$i', width: tw),
    ];

    Logic next(Logic p) => readTags == 1 << sw
        ? p + 1
        : mux(p.eq(readTags - 1), Const(0, width: sw), p + 1);

    addOutput('issue_ready') <= count.lt(readTags);
    addOutput('issue_tag', width: 8) <=
        (base + allocPtr.zeroExtend(5)).zeroExtend(8);
    addOutput('reserved_tag', width: 8) <=
        (base + Const(readTags & 31, width: 5)).zeroExtend(8);
    final headBusy = headPtr.selectFrom(sBusy);
    final headDone = headPtr.selectFrom(sDone);
    addOutput('head_ready') <= ~count.eq(0) & headBusy & headDone;
    addOutput('head_slot', width: sw) <= headPtr;
    addOutput('head_local', width: addressWidth) <= headPtr.selectFrom(sLocal);
    addOutput('head_len', width: 13) <= headPtr.selectFrom(sLen);
    addOutput('busy') <= ~count.eq(0);
    addOutput('stale_count', width: 16) <= stale;

    // Completion header.
    final tag = tlpCplTag(header);
    final rel = (tag.slice(4, 0) - base).named('cpl_rel');
    final low = tag.slice(7, 5).eq(0);
    final inRange = low & rel.lt(readTags);
    final sel = rel.slice(sw - 1, 0).named('cpl_slot');
    final hit = (inRange & sel.selectFrom(sBusy, defaultValue: Const(0))).named(
      'cpl_hit',
    );
    final rsvHit = reservedTags == 0
        ? Const(0)
        : (low & rel.eq(readTags)).named('cpl_reserved');
    final selLen = sel.selectFrom(sLen, defaultValue: Const(0, width: 13));
    final selRecv = sel.selectFrom(sRecv, defaultValue: Const(0, width: 13));
    final selHost = sel.selectFrom(sHost, defaultValue: Const(0, width: 7));
    final rem = (selLen - selRecv).named('cpl_rem');
    final bc = tlpByteCount(header);
    final bc13 = mux(bc.eq(0), Const(4096, width: 13), bc.zeroExtend(13));
    final lenDw = tlpLength(header);
    final len13 = mux(
      lenDw.eq(0),
      Const(4096, width: 13),
      lenDw.zeroExtend(13) << 2,
    ).named('cpl_bytes');
    final expLow = (selHost + selRecv.slice(6, 0)).named('cpl_exp_low');
    final bad =
        ~tlpHasData(header) |
        len13.gt(rem) |
        ~bc13.eq(rem) |
        ~tlpLowerAddress(header).eq(expLow);
    final cplCode = mux(
      ~tlpCplStatus(header).eq(0),
      Const(codeCompletion, width: 3),
      mux(
        tlpPoisoned(header),
        Const(codePoisoned, width: 3),
        mux(bad, Const(codeLength, width: 3), Const(0, width: 3)),
      ),
    ).named('cpl_code');
    final cplErr = cplHeader & hit & ~cplCode.eq(0);
    final cplGood = (cplHeader & hit & cplCode.eq(0) & ~abort).named(
      'cpl_good',
    );

    final expired = [
      for (var i = 0; i < readTags; i++)
        sBusy[i] & ~sDone[i] & sTimer[i].eq(timeoutCycles - 1),
    ];
    final timeout = expired.reduce((a, b) => a | b).named('timeout');
    addOutput('err') <= cplErr | timeout;
    addOutput('err_code', width: 3) <=
        mux(cplErr, cplCode, Const(codeTimeout, width: 3));
    addOutput('reserved_cpl') <= cplHeader & rsvHit;

    // Payload writes. The header beat holds the first payload DW.
    final inPkt = Logic(name: 'pkt_on');
    final pktSlot = Logic(name: 'pkt_slot', width: sw);
    final pktPtr = Logic(name: 'pkt_ptr', width: gw);
    final pktLeft = Logic(name: 'pkt_left', width: 11);
    final pktFinal = Logic(name: 'pkt_final');
    final beatWrite = (rxFire & inPkt).named('beat_write');
    final hdrStart =
        ([sel, Const(0, width: sLog)].swizzle() +
                selRecv.slice(sLog + 1, 2).zeroExtend(gw))
            .named('hdr_start');
    final start = mux(cplGood, hdrStart, pktPtr).named('w_start');
    final lanes = [
      for (var i = 0; i < n; i++)
        tlpSwapBytes(rxData.slice(32 * i + 31, 32 * i)),
    ];
    final firstMem = tlpSwapBytes(firstDw);
    final countN = mux(pktLeft.lt(n), pktLeft.slice(2, 0), Const(n, width: 3));
    final wCount = mux(cplGood, Const(1, width: 3), countN).named('w_count');
    final wEn = (cplGood | beatWrite).named('w_en');
    final startLow = start.slice(bLog - 1, 0);
    final startHigh = (start >> bLog).slice(bankAw - 1, 0);
    final rdStart = ([rdSlot, Const(0, width: sLog)].swizzle() + rdIndex).named(
      'rd_start',
    );
    final rdLow = rdStart.slice(bLog - 1, 0);
    final rdHigh = (rdStart >> bLog).slice(bankAw - 1, 0);
    final rot = Logic(name: 'rd_rot', width: bLog);
    final bankOut = <Logic>[];
    for (var b = 0; b < banks; b++) {
      final cb = Const(b, width: bLog);
      final l = (cb - startLow).named('w_lane_$b');
      final data = _laneMux(cplGood, firstMem, l, lanes);
      final ram = _ReorderRam(
        clk,
        width: 32,
        depth: bankDepth,
        wrEn: wEn & l.zeroExtend(3).lt(wCount),
        wrAddr:
            startHigh +
            mux(cb.lt(startLow), Const(1), Const(0)).zeroExtend(bankAw),
        wrData: data,
        rdAddr:
            rdHigh + mux(cb.lt(rdLow), Const(1), Const(0)).zeroExtend(bankAw),
        name: 'reorder_$b',
      );
      bankOut.add(ram.rdData);
    }
    addOutput('rd_data', width: dataWidth) <=
        [
          for (var l = dpb - 1; l >= 0; l--)
            (rot + Const(l, width: bLog)).selectFrom(bankOut),
        ].swizzle();

    final completes = (cplGood & bc13.eq(len13)).named('cpl_completes');
    final inFlight = [
      for (var i = 0; i < readTags; i++) sBusy[i] & ~sDone[i],
    ].reduce((a, b) => a | b).named('in_flight');
    final staleCpl = (cplHeader & ~hit & ~rsvHit).named('stale_cpl');
    final more = cplGood & ~rxLast;
    Sequential(clk, [
      rot < rdLow,
      If(
        reset | abort,
        then: [
          If(
            reset,
            then: [base < 0],
            orElse: [
              If(inFlight, then: [base < base + slots]),
            ],
          ),
          allocPtr < 0,
          headPtr < 0,
          count < 0,
          for (var i = 0; i < readTags; i++) ...[
            sBusy[i] < 0,
            sDone[i] < 0,
            sTimer[i] < 0,
          ],
          inPkt < 0,
          If.block([
            Iff(reset | clearStale, [stale < 0]),
            ElseIf(staleCpl, [stale < stale + 1]),
          ]),
        ],
        orElse: [
          If(
            clearStale,
            then: [stale < 0],
            orElse: [
              If(staleCpl, then: [stale < stale + 1]),
            ],
          ),
          If(issue & issueReady, then: [allocPtr < next(allocPtr)]),
          If(drainDone, then: [headPtr < next(headPtr)]),
          If.block([
            Iff(issue & issueReady & ~drainDone, [count < count + 1]),
            ElseIf(drainDone & ~(issue & issueReady), [count < count - 1]),
          ]),
          for (var i = 0; i < readTags; i++) ...[
            If.block([
              Iff(issue & issueReady & allocPtr.eq(i), [
                sBusy[i] < 1,
                sDone[i] < 0,
                sLen[i] < issueLen,
                sRecv[i] < 0,
                sHost[i] < issueHostLow,
                sLocal[i] < issueLocal,
                sTimer[i] < 0,
              ]),
              ElseIf(drainDone & headPtr.eq(i), [sBusy[i] < 0, sDone[i] < 0]),
              Else([
                If(sBusy[i] & ~sDone[i], then: [sTimer[i] < sTimer[i] + 1]),
                If(
                  cplGood & sel.eq(i),
                  then: [
                    sRecv[i] < sRecv[i] + len13,
                    If(completes & rxLast, then: [sDone[i] < 1]),
                  ],
                ),
                If(
                  beatWrite & rxLast & pktFinal & pktSlot.eq(i),
                  then: [sDone[i] < 1],
                ),
              ]),
            ]),
          ],
          If(
            cplGood,
            then: [
              inPkt < more,
              pktSlot < sel,
              pktPtr < hdrStart + 1,
              pktLeft <
                  mux(
                    lenDw.eq(0),
                    Const(1023, width: 11),
                    lenDw.zeroExtend(11) - 1,
                  ),
              pktFinal < completes,
            ],
            orElse: [
              If(
                beatWrite,
                then: [
                  pktPtr < pktPtr + wCount.zeroExtend(gw),
                  pktLeft < pktLeft - wCount.zeroExtend(11),
                  If(rxLast, then: [inPkt < 0]),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);
  }
}

/// Lane `l` of [lanes], or [first] when [useFirst] is high. Lanes past the
/// list give 0.
Logic _laneMux(Logic useFirst, Logic first, Logic l, List<Logic> lanes) {
  final out = Logic(width: first.width);
  Combinational([
    If(
      useFirst,
      then: [out < first],
      orElse: [
        out < 0,
        Case(l, [
          for (var i = 0; i < lanes.length; i++)
            CaseItem(Const(i, width: l.width), [out < lanes[i]]),
        ]),
      ],
    ),
  ]);
  return out;
}

/// A simple dual port RAM with a registered read, as [HarborBram].
///
/// The simulation body is a Dart list, because a flop array of this depth
/// is slow in the simulator. Synthesis uses the same inferred block RAM
/// template as [HarborBram].
class _ReorderRam extends Module with SystemVerilog {
  final int width;
  final int depth;
  final int addrWidth;

  Logic get rdData => output('rd_data');

  _ReorderRam(
    Logic clk, {
    required this.width,
    required this.depth,
    required Logic wrEn,
    required Logic wrAddr,
    required Logic wrData,
    required Logic rdAddr,
    super.name,
  }) : addrWidth = (depth - 1).bitLength.clamp(1, 32),
       super(
         definitionName: 'HarborPcieDmaReorderRam_${width}x$depth',
         reserveDefinitionName: true,
       ) {
    clk = addInput('clk', clk);
    wrEn = addInput('wr_en', wrEn);
    wrAddr = addInput('wr_addr', wrAddr, width: addrWidth);
    wrData = addInput('wr_data', wrData, width: width);
    rdAddr = addInput('rd_addr', rdAddr, width: addrWidth);
    final reg = Logic(name: 'rd_reg', width: width);
    addOutput('rd_data', width: width) <= reg;

    final unknown = LogicValue.filled(width, LogicValue.x);
    final cells = List<LogicValue>.filled(depth, unknown);
    reg.put(unknown);
    // Inputs are sampled at the clock edge. The read data changes when the
    // flops change, so other flops see it in the next cycle.
    clk.glitch.listen((event) {
      if (event.previousValue != LogicValue.zero ||
          event.newValue != LogicValue.one) {
        return;
      }
      final ra = rdAddr.value;
      final read = ra.isValid && ra.toInt() < depth
          ? cells[ra.toInt()]
          : unknown;
      final we = wrEn.value;
      if (we.isValid && we.toBool()) {
        final wa = wrAddr.value;
        if (!wa.isValid) {
          throw StateError('$name: write address is not valid');
        }
        if (wa.toInt() < depth) cells[wa.toInt()] = wrData.value;
      }
      unawaited(Simulator.clkStable.first.then((_) => reg.put(read)));
    });
  }

  @override
  String? definitionVerilog(String definitionType) =>
      '''
module $definitionType (
  input logic clk,
  input logic wr_en,
  input logic [${addrWidth - 1}:0] wr_addr,
  input logic [${width - 1}:0] wr_data,
  input logic [${addrWidth - 1}:0] rd_addr,
  output logic [${width - 1}:0] rd_data
);
  logic [${width - 1}:0] mem [0:${depth - 1}];
  always_ff @(posedge clk) begin
    if (wr_en) mem[wr_addr] <= wr_data;
    rd_data <= mem[rd_addr];
  end
endmodule''';
}
