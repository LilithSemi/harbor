import 'dart:math';

import 'package:meta/meta.dart' show visibleForTesting;
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' show Axi4RespField;

import '../../arith/fpu_config.dart' show harborStableDefinitionName;
import '../bus.dart' show BusAddressRange;
import '../fabric.dart';
import '../fabric_narrow.dart';
import '../fabric_util.dart';
import '../port/fabric_kind.dart';
import '../port/reg_fifo.dart';
import 'axi4_exclusive.dart';
import 'axi4_interface.dart';
import 'axi4_lite_interface.dart';

// Orders response codes from best to worst: EXOKAY, OKAY, SLVERR, DECERR.
Logic _respKey(Logic r) =>
    mux(r.eq(0), Const(1, width: 2), mux(r.eq(1), Const(0, width: 2), r));

Logic _resp(Axi4RespField f) => Const(f.value, width: Axi4Interface.respWidth);

// A request on its way to one target.
class _Req {
  final Logic valid;
  final Logic id;
  final Logic rest;
  _Req(this.valid, this.id, this.rest);
}

class _WBeat {
  final Logic valid;
  final Logic data;
  final Logic last;
  _WBeat(this.valid, this.data, this.last);
}

// A response channel from one target, with its slave side ID.
class _Resp {
  final Logic valid = Logic();
  final Logic ready = Logic();
  final Logic id;
  final Logic payload;
  final Logic last;
  _Resp(int idWidth, int payloadWidth)
    : id = Logic(width: idWidth),
      payload = Logic(width: payloadWidth),
      last = Logic();
  Logic get fire => valid & ready;
}

// Maps full IDs onto the fewer ID bits of a slave. A full ID keeps its slot
// while it has requests in flight, so the slave still sees one ID for it and
// keeps their order.
class _Remap {
  final String name;
  final List<Logic> fid;
  final List<Logic> cnt;
  final int slotWidth;
  final int slaveIdWidth;

  _Remap(this.name, int fullIdWidth, this.slaveIdWidth, int outstanding)
    : fid = [],
      cnt = [],
      slotWidth = indexWidth(min(1 << min(slaveIdWidth, 16), outstanding)) {
    final k = min(1 << min(slaveIdWidth, 16), outstanding);
    for (var i = 0; i < k; i++) {
      fid.add(Logic(name: '${name}_fid$i', width: fullIdWidth));
      cnt.add(Logic(name: '${name}_cnt$i', width: widthOf(outstanding)));
    }
  }

  List<Logic> get _valid => [for (final c in cnt) c.neq(0)];

  List<Logic> _match(Logic f) => [
    for (var i = 0; i < fid.length; i++) _valid[i] & fid[i].eq(f),
  ];

  List<Logic> _slot(Logic f) {
    final m = _match(f);
    final free = lowestOf([for (final v in _valid) ~v]);
    final hasMatch = anyOf(m);
    return [for (var i = 0; i < m.length; i++) mux(hasMatch, m[i], free[i])];
  }

  Logic ok(Logic f) => anyOf(_match(f)) | anyOf([for (final v in _valid) ~v]);

  /// High when [f] holds a slot.
  Logic has(Logic f) => anyOf(_match(f));

  Logic slaveId(Logic f) =>
      indexOf(_slot(f), slotWidth).zeroExtend(slaveIdWidth);

  Logic fullId(Logic sid) =>
      pick(decodeIndex(sid.getRange(0, slotWidth), fid.length), fid);

  void update(
    Logic clk,
    Logic reset, {
    required Logic issue,
    required Logic f,
    required Logic done,
    required Logic doneSid,
  }) {
    final slot = _slot(f);
    final doneSlot = decodeIndex(doneSid.getRange(0, slotWidth), fid.length);
    final w = cnt.first.width;
    Sequential(clk, reset: reset, [
      for (var i = 0; i < fid.length; i++) ...[
        cnt[i] <
            cnt[i] +
                (issue & slot[i]).zeroExtend(w) -
                (done & doneSlot[i]).zeroExtend(w),
        fid[i] < harborLoad(fid[i], issue & slot[i], f),
      ],
    ]);
  }

  /// The slave ID of [f] for a request that [issue] marks, as [update]
  /// does, with the table update one cycle later. The lookup sees the
  /// request of the cycle before as if it were in the table. [charged] marks
  /// a request that took a slot credit. One cycle later [giveBack] is high
  /// when a charged request found its ID, and [charge] when a request that
  /// was not charged took a free slot. [release] is high three cycles after
  /// a slot became free, so it never comes before the [charge] of a request
  /// that saw that slot live.
  ({Logic sid, Logic giveBack, Logic charge, Logic release}) lookup(
    Logic clk,
    Logic reset, {
    required Logic issue,
    required Logic charged,
    required Logic f,
    required Logic done,
    required Logic doneSid,
  }) {
    final k = fid.length;
    final issueQ = Logic(name: '${name}_issue_q');
    final slotQ = Logic(name: '${name}_slot_q', width: k);
    final allocQ = Logic(name: '${name}_alloc_q');
    final fQ = Logic(name: '${name}_f_q', width: f.width);
    final liveQ = Logic(name: '${name}_live_q', width: k);
    final chargedQ = Logic(name: '${name}_charged_q');
    final rel = [
      for (var i = 0; i < 2; i++) Logic(name: '${name}_release_q$i'),
    ];
    final pend = [for (var i = 0; i < k; i++) issueQ & slotQ[i]];
    final live = [for (var i = 0; i < k; i++) cnt[i].neq(0) | pend[i]];
    final load = [for (var i = 0; i < k; i++) allocQ & pend[i]];
    final match = [
      for (var i = 0; i < k; i++)
        live[i] & harborLoad(fid[i], load[i], fQ).eq(f),
    ];
    final hasMatch = anyOf(match);
    final free = lowestOf([for (final v in live) ~v]);
    final slot = [
      for (var i = 0; i < k; i++) (hasMatch & match[i]) | (~hasMatch & free[i]),
    ];
    final doneSlot = decodeIndex(doneSid.getRange(0, slotWidth), k);
    final w = cnt.first.width;
    Sequential(clk, reset: reset, [
      issueQ < issue,
      slotQ < slot.rconcat(),
      allocQ < ~hasMatch,
      fQ < f,
      liveQ < live.rconcat(),
      chargedQ < charged,
      rel[0] < anyOf([for (var i = 0; i < k; i++) liveQ[i] & ~live[i]]),
      rel[1] < rel[0],
      for (var i = 0; i < k; i++) ...[
        cnt[i] <
            cnt[i] + pend[i].zeroExtend(w) - (done & doneSlot[i]).zeroExtend(w),
        fid[i] < harborLoad(fid[i], load[i], fQ),
      ],
    ]);
    return (
      sid: indexOf(slot, slotWidth).zeroExtend(slaveIdWidth),
      giveBack: issueQ & chargedQ & ~allocQ,
      charge: issueQ & ~chargedQ & allocQ,
      release: rel[1],
    );
  }
}

// Requests a master has in flight in one direction, grouped by ID. Each
// group keeps the target its requests went to.
class _Tracker {
  final Logic? ok;
  final Logic _total;
  final int outstanding;
  final Logic Function(Logic id, Logic target)? _okFor;

  _Tracker._(this.ok, this._total, this.outstanding, this._okFor);

  /// High when the master has no request in flight.
  Logic get idle => _total.eq(0);

  /// High when the ID order lets a request with [id] go to [target]. The
  /// caller checks the count with [below].
  Logic okFor(Logic id, Logic target) => _okFor!(id, target);

  /// High when fewer than [outstanding] less [x] requests are in flight.
  Logic below(int x) => outstanding > x
      ? _total.lt(Const(outstanding - x, width: _total.width))
      : Const(0);

  /// [id] and [target] are of the request that issues. With [head], [ok] is
  /// null and [okFor] checks any request.
  factory _Tracker(
    String name,
    Logic clk,
    Logic reset, {
    required int outstanding,
    required Logic id,
    required Logic target,
    required Logic issue,
    required Logic done,
    required Logic doneId,
    bool head = false,
  }) {
    final k = min(1 << min(id.width, 16), outstanding);
    final cw = widthOf(outstanding);
    final ids = [
      for (var i = 0; i < k; i++) Logic(name: '${name}_id$i', width: id.width),
    ];
    final tgts = [
      for (var i = 0; i < k; i++)
        Logic(name: '${name}_tgt$i', width: target.width),
    ];
    final cnt = [
      for (var i = 0; i < k; i++) Logic(name: '${name}_cnt$i', width: cw),
    ];
    final total = Logic(name: '${name}_total', width: cw);
    final valid = [for (final c in cnt) c.neq(0)];
    final match = [for (var i = 0; i < k; i++) valid[i] & ids[i].eq(id)];
    final hasMatch = anyOf(match);
    final free = lowestOf([for (final v in valid) ~v]);
    final ok = head
        ? null
        : mux(hasMatch, pick(match, tgts).eq(target), anyOf(free)) &
              total.lt(Const(outstanding, width: cw));
    // The completion credit returns one cycle after the response select. The
    // slot stays live for that cycle, so no extra request can issue, and the
    // path from the response mux to the counters gets a flop.
    final completed = Logic(name: '${name}_completed');
    final completedId = Logic(name: '${name}_completed_id', width: id.width);
    final doneMatch = [
      for (var i = 0; i < k; i++) valid[i] & ids[i].eq(completedId),
    ];
    Sequential(clk, reset: reset, [
      completed < done,
      completedId < doneId,
      total < total + issue.zeroExtend(cw) - completed.zeroExtend(cw),
      for (var i = 0; i < k; i++) ...[
        cnt[i] <
            cnt[i] +
                (head
                        ? issue &
                              ((hasMatch & match[i]) | (~hasMatch & free[i]))
                        : issue & mux(hasMatch, match[i], free[i]))
                    .zeroExtend(cw) -
                (completed & doneMatch[i]).zeroExtend(cw),
        ids[i] < harborLoad(ids[i], issue & ~hasMatch & free[i], id),
        tgts[i] < harborLoad(tgts[i], issue & ~hasMatch & free[i], target),
      ],
    ]);
    // Each slot is free or holds an ID, and a full tracker has its total at
    // the limit. So a request with no slot of its own finds a free one.
    Logic okFor(Logic f, Logic t) {
      final m = [for (var i = 0; i < k; i++) valid[i] & ids[i].eq(f)];
      return mux(anyOf(m), pick(m, tgts).eq(t), Const(1));
    }

    return _Tracker._(
      ok?.named('${name}_ok'),
      total,
      outstanding,
      head ? okFor : null,
    );
  }
}

/// An AXI4 fabric. Build it with [HarborFabric.build].
///
/// - Each master port takes AW, AR and W into 2 entry FIFOs, and each full
///   AXI4 slave port drives AW, AR and W from 2 entry FIFOs. An AXI4-Lite
///   slave port drives AW or AR from one shared entry and W from one entry.
///   B and R reach a master through 2 entry FIFOs. At the fast level each
///   target has a 2 entry response stage, and the master FIFOs have 4
///   entries.
/// - A fabric with one slave has no master FIFOs. The slave FIFOs are its
///   one request stage, so AWREADY, ARREADY and WREADY to a master follow
///   its VALID in the same cycle.
/// - The FIFOs keep only the address bits that change inside a slave
///   region. A slave still sees the full address, or its offset in the
///   region.
/// - A slave sees the master index on top of the master ID. A slave with
///   fewer ID bits gets IDs remapped: each full ID in flight holds one slave
///   ID, and a request waits when no slave ID is free.
/// - A slave never has more than its `outstanding` requests in flight,
///   reads and writes together.
/// - Read beats are arbitrated beat by beat, so beats of different IDs can
///   interleave at a master. Write data follows AW order at each slave.
///
/// Per ID order: a request waits while its master has requests with the
/// same ID in flight to a different slave. So same-ID responses can only
/// come from one slave at a time and keep issue order.
///
/// Ports can be [Axi4Interface] or [Axi4LiteInterface]:
/// - An AXI4-Lite master sends ID 0, LEN 0, full width SIZE and INCR.
/// - An AXI4-Lite slave has 1 request in flight, and the fabric keeps the
///   ID. Its `outstanding` must be 1. An INCR, WRAP or FIXED burst to it
///   runs as one single beat request per beat, in order, and a write burst
///   gets one B after the last beat, with the worst response of its beats.
///   An error response goes back on its own beat. A narrow access runs as a
///   full word access, and its write strobes keep only the lanes that SIZE
///   and the address allow. A WRAP burst that is not 2, 4, 8 or 16 beats, or
///   the reserved burst type, gets SLVERR on every beat. A narrow burst reads
///   the slave word once per beat, so a FIFO register pops once per beat. A
///   native AXI4-Lite slave must ignore the address bits below the bus width.
///
/// Decode uses the start address of a burst only. A full AXI4 slave must
/// accept any burst that starts in its region, so a full slave region under
/// 4 KB must handle addresses past its end.
///
/// A slave with [HarborFabricSlave.readChannels] over 1 gets one target per
/// channel: channel 0 is its full port, and each extra channel is a
/// read-only port ([Axi4ReadOnlyInterface]) presented internally as a full
/// [Axi4Interface] with its AW/W/B side tied off. Writes always go to
/// channel 0. A master's reads go to the channel [HarborFabricMaster]
/// names, or round robin by master order when it names none. Each channel
/// has its own outstanding counter and timeout guard.
class HarborAxi4Fabric extends HarborFabricModule {
  /// Topology of the fabric.
  final HarborFabricTopology topology;

  /// Masters, in port order.
  final List<HarborFabricMaster> masters;

  /// Slaves, in port order.
  final List<HarborFabricSlave> slaves;

  /// ID bits a slave needs for no remap: the widest master ID plus the
  /// master index.
  late final int fullIdWidth;

  /// Requests the internal error slave holds in flight.
  static const int errorOutstanding = 2;

  /// Most beats of a burst of a master that is not real-time that go to a
  /// slave in one request, while a real-time master reaches that slave.
  /// Unused when no master is real-time.
  final int realtimeBurstCap;

  /// The register stages of this fabric.
  final HarborFabricPipeline pipeline;

  /// The signals from the response, W and slave side that the request side
  /// and the AXI4-Lite slave paths read, at the balanced and fast levels. A
  /// depth check of those parts counts them as constants.
  @visibleForTesting
  final Set<Logic> requestCut = {};

  HarborAxi4Fabric({
    required this.topology,
    required Logic clk,
    required Logic reset,
    required this.masters,
    required this.slaves,
    this.realtimeBurstCap = HarborFabric.defaultRealtimeBurstCap,
    this.pipeline = HarborFabricPipeline.balanced,
    super.name = 'fabric',
  }) : super(
         definitionName: _definitionName(
           topology,
           masters,
           slaves,
           realtimeBurstCap,
           pipeline,
         ),
       ) {
    final (addrW, dataW, _) = _shape(masters.first.interface);
    for (final m in masters) {
      final (a, d, _) = _shape(m.interface);
      if (a != addrW || d != dataW) {
        throw ArgumentError(
          '${m.name}: AXI4 widths (addr $a, data $d) differ from addr '
          '$addrW, data $dataW',
        );
      }
    }
    for (final s in slaves) {
      _shape(s.interface);
      harborSlaveAdapts(s, kind: 'AXI4', addrW: addrW, dataW: dataW);
    }
    for (final (name, intf, memory) in [
      for (final m in masters) (m.name, m.interface, m.memory),
      for (final s in slaves) (s.name, s.interface, s.memory),
    ]) {
      if (memory != intf is Axi4Interface) {
        throw ArgumentError(
          '$name: memory is $memory but the port is ${intf.runtimeType}',
        );
      }
    }
    for (final s in slaves) {
      for (var k = 0; k < s.readInterfaces.length; k++) {
        final (a, d, _) = _shape(s.readInterfaces[k]);
        if (a != addrW || d != dataW) {
          throw ArgumentError(
            '${s.name} read channel ${k + 1}: AXI4 widths (addr $a, data '
            '$d) differ from addr $addrW, data $dataW',
          );
        }
      }
    }
    for (final s in slaves) {
      if (s.interface is Axi4LiteInterface && s.outstanding != 1) {
        throw ArgumentError(
          '${s.name}: an AXI4-Lite slave has outstanding 1, got '
          '${s.outstanding}',
        );
      }
    }
    HarborFabric.checkPorts(
      kind: HarborFabricKind.axi4,
      masters: masters,
      slaves: slaves,
      addressWidth: addrW,
      dataWidth: dataW,
    );
    _checkExclusive(masters, slaves);

    final c = addInput('clk', clk);
    final r = addInput('reset', reset);
    addOutput('bus_error');
    addOutput('timeout_count', width: timeoutCountWidth(slaves.length));

    final nm = masters.length;
    final ns = slaves.length;

    // One target per (slave, read channel), plus the error target. Channel
    // 0 of a slave is its full port; channel k >= 1 is a read-only port.
    final chCount = [for (final s in slaves) s.readChannels];
    final tSlave = <int>[];
    final tChan = <int>[];
    for (var s = 0; s < ns; s++) {
      for (var k = 0; k < chCount[s]; k++) {
        tSlave.add(s);
        tChan.add(k);
      }
    }
    final nst = tSlave.length;
    final nt = nst + 1;

    final maxId = masters.map((m) => _shape(m.interface).$3 ?? 1).reduce(max);
    final pW = nm > 1 ? indexWidth(nm) : 0;
    fullIdWidth = fullIdWidthOf(masters);
    final tW = indexWidth(nt);
    final mW = indexWidth(nm);
    // With one slave, the slave FIFOs are the only request stage.
    final pass = ns == 1;
    final headOn = pipeline != HarborFabricPipeline.compact;
    final fast = pipeline == HarborFabricPipeline.fast;
    // At the fast level an entry of a master response FIFO comes back four
    // cycles after its grant: the grant register, the push, the pop and the
    // count. So four entries pass one response per cycle.
    const respDepth = 4;
    // A grant FIFO slot comes back four cycles after its grant: the grant
    // register, the push, the pop and the registered pop. With one more
    // slot for the grant in each cycle, one request per cycle goes on.
    const grantDepth = 5;

    // The read channel each master uses at each slave, by master index.
    final chanOf = [
      for (final s in slaves) HarborFabric.readChannelsOf(s, masters),
    ];

    final ma = [for (final m in masters) _masterPort(m)];

    // A master that declares writeStallFree sends the W beats of a burst
    // with no gap.
    for (var m = 0; m < nm; m++) {
      if (!masters[m].writeStallFree) continue;
      final a = ma[m];
      var inBurst = false;
      harborSimWatch(c, r, () {
        final valid = simHigh(a.wValid);
        final bad = inBurst && !valid
            ? '${masters[m].name} declares writeStallFree and leaves a gap '
                  'inside a write burst: WVALID low before WLAST'
            : null;
        if (valid && simHigh(a.wReady)) inBurst = !simHigh(a.wLast);
        return bad;
      });
    }
    final sa = <Axi4Interface>[];
    final sLite = <Axi4LiteInterface?>[];
    for (final s in slaves) {
      final (a, l) = _slavePort(s, c, r, addrW, dataW);
      sa.add(a);
      sLite.add(l);
      for (var k = 1; k < s.readChannels; k++) {
        sa.add(_slaveReadPort(s, k));
        sLite.add(null);
      }
    }
    final tName = [
      for (var t = 0; t < nst; t++)
        tChan[t] == 0
            ? slaves[tSlave[t]].name
            : '${slaves[tSlave[t]].name}_r${tChan[t]}',
      'err',
    ];
    final tIdW = [for (final a in sa) a.idWidth, fullIdWidth];
    final tN = [
      for (final s in tSlave) slaves[s].outstanding,
      errorOutstanding,
    ];
    final tRemap = [for (var t = 0; t < nt; t++) tIdW[t] < fullIdWidth];

    // Requests keep only the address bits that differ inside the widest
    // slave region. A slave path adds back the bits its region fixes.
    final innerW = slaves.fold(
      1,
      (w, s) => max(w, _regionBits(s.range, addrW)),
    );
    final restWidths = _restWidths(innerW);
    final restW = restWidths.reduce((a, b) => a + b);
    final rPayW = dataW + Axi4Interface.respWidth;
    const bPayW = Axi4Interface.respWidth;

    // Responses from each target, filled in by the slave paths.
    final bResp = [for (var t = 0; t < nt; t++) _Resp(tIdW[t], bPayW)];
    final rResp = [for (var t = 0; t < nt; t++) _Resp(tIdW[t], rPayW)];
    final bDone = [for (final x in bResp) x.fire];
    final rDone = [for (final x in rResp) x.fire & x.last];

    // Remap tables per target and direction.
    final remap = [
      for (var t = 0; t < nt; t++)
        tRemap[t]
            ? [
                for (final d in ['aw', 'ar'])
                  _Remap('${tName[t]}_${d}_remap', fullIdWidth, tIdW[t], tN[t]),
              ]
            : null,
    ];
    Logic fullOf(int t, int dir, Logic sid) =>
        tRemap[t] ? remap[t]![dir].fullId(sid) : sid.getRange(0, fullIdWidth);

    // Completions seen by each master, filled in by the response network.
    final mDone = [
      for (var m = 0; m < nm; m++) [Logic(), Logic()],
    ];
    final mDoneId = [
      for (var m = 0; m < nm; m++)
        [for (var d = 0; d < 2; d++) Logic(width: ma[m].idWidth)],
    ];

    // Master stages: input FIFO, address decode and the per ID order check.
    final inReady = [
      for (var t = 0; t < nt; t++) [Logic(), Logic()],
    ];
    final mPop = [
      for (var m = 0; m < nm; m++) [Logic(), Logic()],
    ];

    // Real-time masters win arbitration. A burst of another master that goes
    // to a slave a real-time master reaches, and is longer than the cap, goes
    // as bursts of at most the cap (see [HarborFabric.build]).
    final rt = [for (final m in masters) m.realtime];
    final hasRt = rt.contains(true);
    final cap = realtimeBurstCap;
    const lenW = Axi4Interface.lenWidth;
    final splitOn = hasRt && cap < (1 << lenW);
    final splitT = [
      for (var t = 0; t < nt; t++)
        splitOn &&
            t < nst &&
            sLite[t] == null &&
            masters.any((m) => m.realtime && m.reaches(slaves[tSlave[t]].name)),
    ];
    final splitM = [
      for (final m in masters)
        splitOn &&
            !m.realtime &&
            m.interface is Axi4Interface &&
            splitT.contains(true),
    ];
    // Per master and direction: the burst has more pieces to send, how many
    // beats the piece has less one, and the pieces granted that are not the
    // last one of their burst.
    final mMore = [
      for (var m = 0; m < nm; m++) [Logic(), Logic()],
    ];
    final mPieceLen = [
      for (var m = 0; m < nm; m++)
        [for (var d = 0; d < 2; d++) Logic(width: lenW)],
    ];
    final mFire = [
      for (var m = 0; m < nm; m++) [Logic(), Logic()],
    ];
    final mNonFinal = [
      for (var m = 0; m < nm; m++) [Logic(), Logic()],
    ];
    // Pieces of a master whose write data has not all passed.
    final wPieces = [
      for (var m = 0; m < nm; m++)
        Logic(name: '${masters[m].name}_w_pieces', width: 4),
    ];
    // The master takes the grant [fire] for the piece it presents. The
    // request leaves the master FIFO with the last piece.
    void grantTo(int m, int dir, Logic fire) {
      if (!splitM[m]) {
        mPop[m][dir] <= fire;
        if (hasRt) mFire[m][dir] <= fire;
        return;
      }
      mFire[m][dir] <= fire;
      mPop[m][dir] <= fire & ~mMore[m][dir];
      mNonFinal[m][dir] <= fire & mMore[m][dir];
    }

    final mTgtIdx = <List<Logic>>[];
    final List<List<Logic>> tFire;
    final List<List<_Req>> tReq;
    final List<List<Logic>> tMaster;
    final List<Logic> awBusTarget;
    final List<Logic> awBusMaster;
    final List<Logic> awBusLen;
    final List<List<Logic>> tSid;
    final grantPopQ = <List<Logic>>[];
    if (!headOn) {
      final mIdle = [
        for (var m = 0; m < nm; m++) <Logic?>[null, null],
      ];
      final mFull = <List<Logic>>[];
      final mRest = <List<Logic>>[];
      final mTgt = <List<List<Logic>>>[];
      final req = <List<List<Logic>>>[];
      for (var m = 0; m < nm; m++) {
        final a = ma[m];
        final mn = masters[m].name;
        mFull.add([]);
        mRest.add([]);
        mTgt.add([]);
        mTgtIdx.add([]);
        req.add([]);
        for (var dir = 0; dir < 2; dir++) {
          final d = dir == 0 ? 'AW' : 'AR';
          // Decode comes before the FIFO, so the FIFO holds the target and
          // the low address bits in place of the full address.
          final addr = a.port('${d}ADDR');
          final hits = [
            for (final s in slaves)
              masters[m].reaches(s.name) ? inRange(addr, s.range) : Const(0),
          ];
          // AW always targets channel 0. AR targets this master's assigned
          // channel at the slave it hits.
          final tgtIn = <Logic>[];
          for (var s = 0; s < ns; s++) {
            final chan = dir == 0 ? 0 : max(0, chanOf[s][m]);
            for (var k = 0; k < chCount[s]; k++) {
              tgtIn.add(k == chan ? hits[s] : Const(0));
            }
          }
          tgtIn.add(~anyOf(hits));
          final f = _stage(
            pass,
            name: '${mn}_${d.toLowerCase()}',
            clk: c,
            reset: r,
            valid: a.port('${d}VALID'),
            data: harborPack([
              a.port('${d}ID'),
              indexOf(tgtIn, tW),
              addr.getRange(0, innerW),
              for (final x in _restFields.skip(1)) a.port('$d$x'),
            ]),
            ready: a.port('${d}READY'),
            pop: mPop[m][dir],
          );
          final [hid, tgtIdx, rest] = harborUnpack(f.data, [
            a.idWidth,
            tW,
            restW,
          ]);
          final tgt = decodeIndex(tgtIdx, nt);
          var pieceRest = rest;
          Logic? splitOk;
          if (splitM[m]) {
            // The piece the master offers now: at most the cap beats of what
            // is left of the burst, from the address the earlier pieces ended
            // at.
            final [addr, len, size, burst, lock, cache, prot, qos] =
                harborUnpack(rest, restWidths);
            const lw = lenW + 1;
            final p = '${mn}_${d.toLowerCase()}_split';
            final done = Logic(name: '${p}_done', width: lw);
            final busy = Logic(name: '${p}_busy');
            final remain = (len.zeroExtend(lw) + 1) - done;
            final eligible = anyOf([
              for (var t = 0; t < nt; t++)
                if (splitT[t]) tgt[t],
            ]);
            final incr = burst.eq(Const(1, width: Axi4Interface.burstWidth));
            // A legal exclusive burst (16 beats or fewer) goes whole, or the
            // monitor would see pieces. An exclusive burst above 16 beats is
            // illegal and splits like any other.
            final more =
                (eligible &
                        incr &
                        (~lock | len.gt(Const(15, width: lenW))) &
                        remain.gt(Const(cap, width: lw)))
                    .named('${p}_more');
            mMore[m][dir] <= more;
            final pieceLen = mux(
              more,
              Const(cap - 1, width: lenW),
              (remain - 1).getRange(0, lenW),
            );
            mPieceLen[m][dir] <= pieceLen;
            final w = innerW + lw + 8;
            final aligned = (addr.zeroExtend(w) >> size) << size;
            final offset = done.zeroExtend(w) << size;
            final pieceAddr = mux(
              done.eq(0),
              addr,
              (aligned + offset).getRange(0, innerW),
            );
            pieceRest = harborPack([
              pieceAddr,
              pieceLen,
              size,
              burst,
              lock,
              cache,
              prot,
              qos,
            ]);
            Sequential(c, reset: r, [
              If(
                mFire[m][dir],
                then: [
                  If(more, then: [done < done + Const(cap, width: lw)]),
                  If(~more, then: [done < 0]),
                ],
              ),
              busy < (busy | mNonFinal[m][dir]) & ~mDone[m][dir],
            ]);
            // A burst that splits starts when the master has nothing else in
            // flight, and any other request waits until it ends. So each
            // response of the master belongs to the burst that splits.
            mIdle[m][dir] = Logic(name: '${p}_idle');
            splitOk = done.neq(0) | (~busy & (~more | mIdle[m][dir]!));
            if (dir == 0) {
              // Pieces of one burst overlap, as far as the master and the
              // fabric hold their write routes.
              final room = wPieces[m].lt(
                Const(
                  min(15, masters[m].outstandingOn(HarborFabricKind.axi4)),
                  width: 4,
                ),
              );
              splitOk = splitOk & room;
            }
          } else if (hasRt) {
            mPieceLen[m][dir] <= rest.getRange(innerW, innerW + lenW);
          }
          final full = pW > 0
              ? [Const(m, width: pW), hid.zeroExtend(maxId)].concat()
              : hid.zeroExtend(maxId);
          final tracker = _Tracker(
            '${mn}_${d.toLowerCase()}_order',
            c,
            r,
            outstanding: masters[m].outstandingOn(HarborFabricKind.axi4),
            id: hid,
            target: tgtIdx,
            issue: mPop[m][dir],
            done: mDone[m][dir],
            doneId: mDoneId[m][dir],
          );
          final ok = splitOk == null ? tracker.ok! : tracker.ok! & splitOk;
          if (splitOk != null) mIdle[m][dir]! <= tracker.idle;
          mFull[m].add(full);
          mRest[m].add(pieceRest);
          mTgt[m].add(tgt);
          mTgtIdx[m].add(tgtIdx);
          req[m].add([
            for (var t = 0; t < nt; t++)
              f.valid &
                  ok &
                  tgt[t] &
                  inReady[t][dir] &
                  (tRemap[t] ? remap[t]![dir].ok(full) : Const(1)),
          ]);
        }
      }

      // Outstanding limit per target, reads and writes together. When one
      // slot is left, a registered direction owns it. On a target that a
      // real-time master reaches, a request in one direction takes the slot
      // when the other direction does not want it. On other targets a request
      // in the other direction waits one cycle for its turn, so no path goes
      // from the AW request to the AR grant.
      final outOk = <List<Logic>>[];
      tFire = [
        for (var t = 0; t < nt; t++) [Logic(), Logic()],
      ];
      for (var t = 0; t < nt; t++) {
        final n = tN[t];
        final cw = widthOf(n);
        final cnt = Logic(name: '${tName[t]}_inflight', width: cw);
        final preferRead = Logic(name: '${tName[t]}_prefer_read');
        final full = cnt.eq(Const(n, width: cw));
        final lastOne = cnt.eq(Const(n - 1, width: cw));
        final awWant = anyOf([for (var m = 0; m < nm; m++) req[m][0][t]]);
        final arWant = anyOf([for (var m = 0; m < nm; m++) req[m][1][t]]);
        // The error target counts as real-time in a fabric with a real-time
        // master, as any master can decode to it.
        final rtTarget = t < nst
            ? masters.any(
                (m) => m.realtime && m.reaches(slaves[tSlave[t]].name),
              )
            : hasRt;
        // A real-time request in one direction takes the last slot from a
        // request in the other direction.
        var prefer = preferRead;
        if (rtTarget) {
          final awRt = anyOf([
            for (var m = 0; m < nm; m++)
              if (rt[m]) req[m][0][t],
          ]);
          final arRt = anyOf([
            for (var m = 0; m < nm; m++)
              if (rt[m]) req[m][1][t],
          ]);
          prefer = mux(
            arRt & ~awRt,
            Const(1),
            mux(awRt & ~arRt, Const(0), preferRead),
          );
        }
        outOk.add(
          rtTarget
              ? [
                  ~full & ~(lastOne & arWant & prefer),
                  ~full & ~(lastOne & awWant & ~prefer),
                ]
              : [~full & ~(lastOne & prefer), ~full & ~(lastOne & ~prefer)],
        );
        Sequential(c, reset: r, [
          cnt <
              cnt +
                  tFire[t][0].zeroExtend(cw) +
                  tFire[t][1].zeroExtend(cw) -
                  bDone[t].zeroExtend(cw) -
                  rDone[t].zeroExtend(cw),
          // On a target that is not real-time, the direction turns when the
          // other direction wants the slot. A stream in one direction keeps it
          // and does not wait.
          if (rtTarget)
            preferRead < preferRead ^ (lastOne & awWant & arWant)
          else
            preferRead <
                preferRead ^ (lastOne & mux(preferRead, awWant, arWant)),
        ]);
      }

      // Arbitration. Each target gets a request with its full ID and the
      // master it came from.
      tReq = [for (var t = 0; t < nt; t++) <_Req>[]];
      tMaster = [for (var t = 0; t < nt; t++) <Logic>[]];
      awBusTarget = <Logic>[];
      awBusMaster = <Logic>[];
      awBusLen = <Logic>[];
      for (var dir = 0; dir < 2; dir++) {
        final d = dir == 0 ? 'aw' : 'ar';
        final gated = [
          for (var m = 0; m < nm; m++)
            [for (var t = 0; t < nt; t++) req[m][dir][t] & outOk[t][dir]],
        ];
        final full = [for (var m = 0; m < nm; m++) mFull[m][dir]];
        final rest = [for (var m = 0; m < nm; m++) mRest[m][dir]];
        if (topology == HarborFabricTopology.crossbar) {
          final grants = <List<Logic>>[];
          for (var t = 0; t < nt; t++) {
            final g = roundRobin(
              '${tName[t]}_$d',
              c,
              r,
              realtimeFirst([for (var m = 0; m < nm; m++) gated[m][t]], rt),
            );
            grants.add(g);
            tFire[t][dir] <= anyOf(g);
            tReq[t].add(_Req(tFire[t][dir], pick(g, full), pick(g, rest)));
            tMaster[t].add(indexOf(g, mW));
          }
          for (var m = 0; m < nm; m++) {
            grantTo(m, dir, anyOf([for (var t = 0; t < nt; t++) grants[t][m]]));
          }
        } else {
          final g = roundRobin(
            'bus_$d',
            c,
            r,
            realtimeFirst([for (var m = 0; m < nm; m++) anyOf(gated[m])], rt),
          );
          final busFull = pick(g, full);
          final busRest = pick(g, rest);
          final busMaster = indexOf(g, mW);
          for (var t = 0; t < nt; t++) {
            tFire[t][dir] <=
                anyOf([for (var m = 0; m < nm; m++) g[m] & mTgt[m][dir][t]]);
            tReq[t].add(_Req(tFire[t][dir], busFull, busRest));
            tMaster[t].add(busMaster);
          }
          for (var m = 0; m < nm; m++) {
            grantTo(m, dir, g[m]);
          }
          if (dir == 0) {
            awBusTarget.add(
              pick(g, [for (var m = 0; m < nm; m++) mTgtIdx[m][0]]),
            );
            awBusMaster.add(busMaster);
            if (hasRt) {
              awBusLen.add(
                pick(g, [for (var m = 0; m < nm; m++) mPieceLen[m][0]]),
              );
            }
          }
        }
      }

      // ID remap at each target.
      tSid = [
        for (var t = 0; t < nt; t++)
          [
            for (var dir = 0; dir < 2; dir++)
              tRemap[t]
                  ? remap[t]![dir].slaveId(tReq[t][dir].id)
                  : tReq[t][dir].id.zeroExtend(tIdW[t]),
          ],
      ];
      for (var t = 0; t < nt; t++) {
        if (!tRemap[t]) continue;
        for (var dir = 0; dir < 2; dir++) {
          final resp = dir == 0 ? bResp[t] : rResp[t];
          remap[t]![dir].update(
            c,
            r,
            issue: tFire[t][dir],
            f: tReq[t][dir].id,
            done: dir == 0 ? bDone[t] : rDone[t],
            doneSid: resp.id,
          );
        }
      }
    } else {
      // The flop-only arbitration. Each master head is a register, each
      // target and direction has an eligibility flop from local credits,
      // and the arbiter reads only flops. The granted fields, the ID remap,
      // the grant FIFO push and the tracker issue follow one cycle later
      // from the grant register.
      final elig = [
        for (var t = 0; t < nt; t++)
          [
            for (final d in ['aw', 'ar']) Logic(name: '${tName[t]}_${d}_elig'),
          ],
      ];
      final hValid = [
        for (var m = 0; m < nm; m++) [Logic(), Logic()],
      ];
      final hOk = [
        for (var m = 0; m < nm; m++) [Logic(), Logic()],
      ];
      final hTgt = [
        for (var m = 0; m < nm; m++) <List<Logic>>[[], []],
      ];
      final gFire = [
        for (var m = 0; m < nm; m++) [Logic(), Logic()],
      ];
      final iFull = [for (var m = 0; m < nm; m++) <Logic>[]];
      final iRest = [for (var m = 0; m < nm; m++) <Logic>[]];
      final iTgt = [for (var m = 0; m < nm; m++) <Logic>[]];
      // Remap targets with fewer slave IDs than requests in flight. A
      // request there takes a slot credit unless its ID holds a slot.
      final few = [
        for (var t = 0; t < nt; t++)
          [
            for (var dir = 0; dir < 2; dir++)
              tRemap[t] && remap[t]![dir].fid.length < tN[t],
          ],
      ];
      final hFound = [
        for (var m = 0; m < nm; m++) <Logic>[Const(0), Const(0)],
      ];
      final iFound = [
        for (var m = 0; m < nm; m++) <Logic>[Const(0), Const(0)],
      ];
      for (var m = 0; m < nm; m++) {
        final a = ma[m];
        final mn = masters[m].name;
        mTgtIdx.add([]);
        final n = masters[m].outstandingOn(HarborFabricKind.axi4);
        for (var dir = 0; dir < 2; dir++) {
          final d = dir == 0 ? 'AW' : 'AR';
          final p = '${mn}_${d.toLowerCase()}';
          final addr = a.port('${d}ADDR');
          final hits = [
            for (final s in slaves)
              masters[m].reaches(s.name) ? inRange(addr, s.range) : Const(0),
          ];
          final tgtIn = <Logic>[];
          for (var s = 0; s < ns; s++) {
            final chan = dir == 0 ? 0 : max(0, chanOf[s][m]);
            for (var k = 0; k < chCount[s]; k++) {
              tgtIn.add(k == chan ? hits[s] : Const(0));
            }
          }
          tgtIn.add(~anyOf(hits));
          final advance = Logic(name: '${p}_advance');
          final f = _inStage(
            pass,
            name: p,
            clk: c,
            reset: r,
            valid: a.port('${d}VALID'),
            data: harborPack([
              a.port('${d}ID'),
              indexOf(tgtIn, tW),
              addr.getRange(0, innerW),
              for (final x in _restFields.skip(1)) a.port('$d$x'),
            ]),
            ready: a.port('${d}READY'),
            pop: advance,
          );
          final [eid, eIdx, eRest] = harborUnpack(f.data, [
            a.idWidth,
            tW,
            restW,
          ]);
          final eTgt = decodeIndex(eIdx, nt);

          // The head register. It takes the next entry when it is empty or
          // its request issues, so one request can issue each cycle.
          final hp = '${p}_head';
          final hv = Logic(name: '${hp}_valid');
          final hid = Logic(name: '${hp}_id', width: a.idWidth);
          final rest = Logic(name: '${hp}_rest', width: restW);
          final ht = Logic(name: '${hp}_tgt', width: nt);
          final fire = gFire[m][dir];
          final more = splitM[m] ? Logic(name: '${p}_split_more') : Const(0);
          final pop = splitM[m] ? fire & ~more : fire;
          advance <= ~hv | pop;
          Sequential(c, reset: r, [hv < harborLoad(hv, advance, f.valid)]);
          Sequential(c, [
            hid < harborLoad(hid, advance, eid),
            rest < harborLoad(rest, advance, eRest),
            ht < harborLoad(ht, advance, eTgt.rconcat()),
          ]);
          final tgt = [for (var t = 0; t < nt; t++) ht[t]];
          final tgtIdx = indexOf(tgt, tW);
          hValid[m][dir] <= hv;
          hTgt[m][dir] = tgt;

          // The request that issued last cycle, for the grant register.
          final iid = Logic(name: '${p}_issued_id', width: a.idWidth);
          final irest = Logic(name: '${p}_issued_rest', width: restW);
          final itgt = Logic(name: '${p}_issued_tgt', width: tW);
          final popQ = Logic(name: '${p}_pop_q');
          final fireQ = Logic(name: '${p}_fire_q');

          var pieceRest = rest;
          Logic? splitD;
          final idleNow = Logic();
          if (splitM[m]) {
            // The piece the head offers, kept in registers: its address,
            // the beats left of the burst and the piece length. A piece
            // that is not the last moves them on by the cap.
            final [addr, len, size, burst, lock, cache, prot, qos] =
                harborUnpack(rest, restWidths);
            final [eAddr, eLen, _, eBurst, eLock, ...] = harborUnpack(
              eRest,
              restWidths,
            );
            const lw = lenW + 1;
            final sp = '${p}_split';
            final pAddr = Logic(name: '${sp}_addr', width: innerW);
            final remain = Logic(name: '${sp}_remain', width: lw);
            final pLen = Logic(name: '${sp}_len', width: lenW);
            final mid = Logic(name: '${sp}_mid');
            final busy = Logic(name: '${sp}_busy');
            Logic base(List<Logic> tg, Logic b, Logic l, Logic ln) =>
                anyOf([
                  for (var t = 0; t < nt; t++)
                    if (splitT[t]) tg[t],
                ]) &
                b.eq(Const(1, width: Axi4Interface.burstWidth)) &
                (~l | ln.gt(Const(15, width: lenW)));
            final eMore =
                base(eTgt, eBurst, eLock, eLen) &
                eLen.gt(Const(cap - 1, width: lenW));
            final sMore =
                base(tgt, burst, lock, len) &
                remain.gt(Const(2 * cap, width: lw));
            final sLen = mux(
              sMore,
              Const(cap - 1, width: lenW),
              (remain - (cap + 1)).getRange(0, lenW),
            );
            final low = [
              for (var b = 0; b < innerW; b++)
                b < 7
                    ? size.gt(Const(b, width: Axi4Interface.sizeWidth))
                    : Const(0),
            ];
            final step = Const(cap, width: innerW) << size;
            final sAddr = (pAddr & ~low.rconcat()) + step;
            final isStep = fire & more;
            Sequential(c, reset: r, [
              more <
                  harborLoad(harborLoad(more, isStep, sMore), advance, eMore),
              mid < (mid | isStep) & ~advance,
              busy < (busy | isStep) & ~mDone[m][dir],
            ]);
            Sequential(c, [
              pAddr <
                  harborLoad(harborLoad(pAddr, isStep, sAddr), advance, eAddr),
              remain <
                  harborLoad(
                    harborLoad(remain, isStep, remain - cap),
                    advance,
                    eLen.zeroExtend(lw) + 1,
                  ),
              pLen <
                  harborLoad(
                    harborLoad(pLen, isStep, sLen),
                    advance,
                    mux(eMore, Const(cap - 1, width: lenW), eLen),
                  ),
            ]);
            pieceRest = harborPack([
              pAddr,
              pLen,
              size,
              burst,
              lock,
              cache,
              prot,
              qos,
            ]);
            // The write pieces in flight count the piece of last cycle and
            // the one that fires now.
            Logic roomFor(int x) {
              if (dir == 1) return Const(1);
              final limit = min(15, n);
              Logic below(int y) => limit - y > 0
                  ? wPieces[m].lt(Const(limit - y, width: 4))
                  : Const(0);
              return mux(fireQ, below(x + 1), below(x));
            }

            final roomHeld = roomFor(0);
            final roomFire = roomFor(1);
            final heldOk = (mid | (~busy & (~more | idleNow))) & roomHeld;
            final entryOk =
                ~busy &
                (~eMore | (idleNow & ~pop)) &
                harborLoad(roomHeld, fire, roomFire);
            splitD = harborLoad(
              harborLoad(heldOk, isStep, roomFire),
              advance,
              entryOk,
            );
          }
          Sequential(c, [
            iid < harborLoad(iid, fire, hid),
            irest < harborLoad(irest, fire, pieceRest),
            itgt < harborLoad(itgt, fire, tgtIdx),
          ]);
          Sequential(c, reset: r, [popQ < pop, fireQ < fire]);
          mPop[m][dir] <= popQ;
          mFire[m][dir] <= fireQ;
          if (splitM[m]) {
            final nf = Logic(name: '${p}_non_final_q');
            Sequential(c, reset: r, [nf < fire & more]);
            mNonFinal[m][dir] <= nf;
          }
          if (hasRt) {
            mPieceLen[m][dir] <= irest.getRange(innerW, innerW + lenW);
          }
          iFull[m].add(
            pW > 0
                ? [Const(m, width: pW), iid.zeroExtend(maxId)].concat()
                : iid.zeroExtend(maxId),
          );
          iRest[m].add(irest);
          iTgt[m].add(itgt);
          mTgtIdx[m].add(itgt);

          // The order check of the head, one cycle ahead. The tracker takes
          // an issue one cycle after the grant, so the check also looks at
          // the request in the grant register and at the one that issues
          // now.
          final tracker = _Tracker(
            '${p}_order',
            c,
            r,
            outstanding: n,
            id: iid,
            target: itgt,
            issue: popQ,
            done: mDone[m][dir],
            doneId: mDoneId[m][dir],
            head: true,
          );
          idleNow <= tracker.idle & ~popQ;
          Logic clash(Logic id, Logic t, Logic withId, Logic withT) =>
              withId.eq(id) & withT.neq(t);
          Logic room(int x) =>
              mux(popQ, tracker.below(x + 1), tracker.below(x));
          final heldTrk =
              tracker.okFor(hid, tgtIdx) &
              ~(popQ & clash(hid, tgtIdx, iid, itgt)) &
              room(0);
          final eBase =
              tracker.okFor(eid, eIdx) & ~(popQ & clash(eid, eIdx, iid, itgt));
          final entryTrk = harborLoad(
            eBase & room(0),
            pop,
            eBase & ~clash(eid, eIdx, hid, tgtIdx) & room(1),
          );
          final trkOk = Logic(name: '${hp}_trk_ok');
          Sequential(c, reset: r, [
            trkOk < harborLoad(heldTrk, advance, entryTrk),
          ]);
          if ([for (var t = 0; t < nt; t++) few[t][dir]].contains(true)) {
            // The ID holds a slot at its target, from the table one cycle
            // ahead. Only a slot that frees can make it wrong, and the
            // lookup then charges the slot it takes.
            Logic full(Logic id) => pW > 0
                ? [Const(m, width: pW), id.zeroExtend(maxId)].concat()
                : id.zeroExtend(maxId);
            Logic foundOf(Logic id, List<Logic> tg) => anyOf([
              for (var t = 0; t < nt; t++)
                if (few[t][dir]) tg[t] & remap[t]![dir].has(full(id)),
            ]);
            final found = Logic(name: '${hp}_remap_found');
            final ifound = Logic(name: '${p}_issued_found');
            Sequential(c, reset: r, [
              found <
                  harborLoad(foundOf(hid, tgt), advance, foundOf(eid, eTgt)),
              ifound < harborLoad(ifound, fire, found),
            ]);
            hFound[m][dir] = found;
            iFound[m][dir] = ifound;
          }
          if (splitD != null) {
            final splitOk = Logic(name: '${hp}_split_ok');
            Sequential(c, reset: r, [splitOk < splitD]);
            hOk[m][dir] <= trkOk & splitOk;
          } else {
            hOk[m][dir] <= trkOk;
          }
        }
      }

      // Wants of each target, registered, for the last slot rules.
      Logic wantOf(int t, int dir, bool rtOnly) => anyOf([
        for (var m = 0; m < nm; m++)
          if (!rtOnly || rt[m]) hValid[m][dir] & hOk[m][dir] & hTgt[m][dir][t],
      ]);
      Logic wantSlot(int t, int dir) => anyOf([
        for (var m = 0; m < nm; m++)
          hValid[m][dir] & hOk[m][dir] & hTgt[m][dir][t] & ~hFound[m][dir],
      ]);
      // The remap slot credit of a target with few slave IDs.
      final slotElig = [
        for (var t = 0; t < nt; t++)
          [
            for (var dir = 0; dir < 2; dir++)
              few[t][dir]
                  ? Logic(
                      name: '${tName[t]}_${dir == 0 ? 'aw' : 'ar'}_slot_elig',
                    )
                  : Const(1),
          ],
      ];
      // A head may take target [t] when the target is eligible and, on a
      // target with few slave IDs, its ID holds a slot or a slot is free.
      Logic open(int m, int dir, int t) => few[t][dir]
          ? elig[t][dir] & (hFound[m][dir] | slotElig[t][dir])
          : elig[t][dir];
      final charged = [
        for (var t = 0; t < nt; t++) [Logic(), Logic()],
      ];

      // The arbiters and the grant registers.
      tReq = [for (var t = 0; t < nt; t++) <_Req>[]];
      tMaster = [for (var t = 0; t < nt; t++) <Logic>[]];
      tFire = [
        for (var t = 0; t < nt; t++) [Logic(), Logic()],
      ];
      awBusTarget = [];
      awBusMaster = [];
      awBusLen = [];
      for (var dir = 0; dir < 2; dir++) {
        final d = dir == 0 ? 'aw' : 'ar';
        final full = [for (var m = 0; m < nm; m++) iFull[m][dir]];
        final rest = [for (var m = 0; m < nm; m++) iRest[m][dir]];
        if (topology == HarborFabricTopology.crossbar) {
          final grants = <List<Logic>>[];
          for (var t = 0; t < nt; t++) {
            final g = _roundRobin(
              '${tName[t]}_$d',
              c,
              r,
              realtimeFirst([
                for (var m = 0; m < nm; m++)
                  hValid[m][dir] &
                      hOk[m][dir] &
                      hTgt[m][dir][t] &
                      open(m, dir, t),
              ], rt),
            );
            grants.add(g);
            final reg = Logic(name: '${tName[t]}_${d}_grant_reg', width: nm);
            Sequential(c, reset: r, [reg < g.rconcat()]);
            final oh = [for (var m = 0; m < nm; m++) reg[m]];
            tFire[t][dir] <= anyOf(oh);
            charged[t][dir] <=
                tFire[t][dir] &
                    ~pick(oh, [for (var m = 0; m < nm; m++) iFound[m][dir]]);
            tReq[t].add(_Req(tFire[t][dir], pick(oh, full), pick(oh, rest)));
            tMaster[t].add(indexOf(oh, mW));
          }
          for (var m = 0; m < nm; m++) {
            gFire[m][dir] <= anyOf([for (var t = 0; t < nt; t++) grants[t][m]]);
          }
        } else {
          final g = _roundRobin(
            'bus_$d',
            c,
            r,
            realtimeFirst([
              for (var m = 0; m < nm; m++)
                hValid[m][dir] &
                    hOk[m][dir] &
                    anyOf([
                      for (var t = 0; t < nt; t++)
                        hTgt[m][dir][t] & open(m, dir, t),
                    ]),
            ], rt),
          );
          for (var m = 0; m < nm; m++) {
            gFire[m][dir] <= g[m];
          }
          final reg = Logic(name: 'bus_${d}_grant_reg', width: nm + nt);
          Sequential(c, reset: r, [
            reg <
                [
                  ...g,
                  for (var t = 0; t < nt; t++)
                    anyOf([
                      for (var m = 0; m < nm; m++) g[m] & hTgt[m][dir][t],
                    ]),
                ].rconcat(),
          ]);
          final oh = [for (var m = 0; m < nm; m++) reg[m]];
          final busFull = pick(oh, full);
          final busRest = pick(oh, rest);
          final busMaster = indexOf(oh, mW);
          final busFound = pick(oh, [
            for (var m = 0; m < nm; m++) iFound[m][dir],
          ]);
          for (var t = 0; t < nt; t++) {
            tFire[t][dir] <= reg[nm + t];
            charged[t][dir] <= tFire[t][dir] & ~busFound;
            tReq[t].add(_Req(tFire[t][dir], busFull, busRest));
            tMaster[t].add(busMaster);
          }
          if (dir == 0) {
            awBusTarget.add(
              pick(oh, [for (var m = 0; m < nm; m++) iTgt[m][0]]),
            );
            awBusMaster.add(busMaster);
            if (hasRt) {
              awBusLen.add(
                pick(oh, [for (var m = 0; m < nm; m++) mPieceLen[m][0]]),
              );
            }
          }
        }
      }

      // ID remap at each target, from the grant register.
      final remapFree = [
        for (var t = 0; t < nt; t++) <(Logic, Logic, Logic)?>[null, null],
      ];
      tSid = [
        for (var t = 0; t < nt; t++)
          [
            for (var dir = 0; dir < 2; dir++)
              if (tRemap[t])
                () {
                  final resp = dir == 0 ? bResp[t] : rResp[t];
                  final x = remap[t]![dir].lookup(
                    c,
                    r,
                    issue: tFire[t][dir],
                    charged: charged[t][dir],
                    f: tReq[t][dir].id,
                    done: dir == 0 ? bDone[t] : rDone[t],
                    doneSid: resp.id,
                  );
                  remapFree[t][dir] = (x.giveBack, x.charge, x.release);
                  return x.sid;
                }()
              else
                tReq[t][dir].id.zeroExtend(tIdW[t]),
          ],
      ];

      // Credits and eligibility per target and direction. A credit goes
      // down when the grant register holds the target. An outstanding slot
      // comes back with its B or last R, a grant FIFO slot one cycle after
      // its pop. A grant in the next cycle needs room for the requests in
      // the grant register, the grants now and itself.
      for (var t = 0; t < nt; t++) {
        final n = tN[t];
        final tn = tName[t];
        final held = [tFire[t][0], tFire[t][1]];
        final inflight = Logic(name: '${tn}_inflight', width: widthOf(n));
        final w = inflight.width;
        Sequential(c, reset: r, [
          inflight <
              inflight +
                  held[0].zeroExtend(w) +
                  held[1].zeroExtend(w) -
                  bDone[t].zeroExtend(w) -
                  rDone[t].zeroExtend(w),
        ]);
        // A grant can come now only where the target is eligible and a head
        // wants it.
        final now = [
          for (var dir = 0; dir < 2; dir++)
            (elig[t][dir] & wantOf(t, dir, false)).named(
              '${tn}_${dir == 0 ? 'aw' : 'ar'}_may_grant',
            ),
        ];
        final pend = [held[0], held[1], now[0], now[1]];
        final two = _fits(inflight, pend, n, 2);
        final one = _fits(inflight, pend, n, 1) & ~two;
        final rtTarget = t < nst
            ? masters.any(
                (m) => m.realtime && m.reaches(slaves[tSlave[t]].name),
              )
            : hasRt;
        final preferRead = Logic(name: '${tn}_prefer_read');
        final wantQ = [
          for (final d in ['aw', 'ar']) Logic(name: '${tn}_${d}_want_q'),
        ];
        Sequential(c, reset: r, [
          for (var dir = 0; dir < 2; dir++) wantQ[dir] < wantOf(t, dir, false),
        ]);
        // When one slot is left, one direction owns it: the direction that
        // wants it alone, else on a real-time target the direction with a
        // real-time request alone, else the registered direction, which
        // turns at each use while both directions want the slot.
        var prefer = preferRead;
        if (rtTarget) {
          final rtQ = [
            for (final d in ['aw', 'ar']) Logic(name: '${tn}_${d}_rt_want_q'),
          ];
          Sequential(c, reset: r, [
            for (var dir = 0; dir < 2; dir++) rtQ[dir] < wantOf(t, dir, true),
          ]);
          prefer = mux(
            rtQ[1] & ~rtQ[0],
            Const(1),
            mux(rtQ[0] & ~rtQ[1], Const(0), preferRead),
          );
        }
        final ownerRead = mux(
          wantQ[1] & ~wantQ[0],
          Const(1),
          mux(wantQ[0] & ~wantQ[1], Const(0), prefer),
        );
        Sequential(c, reset: r, [
          preferRead < preferRead ^ (one & wantQ[0] & wantQ[1]),
        ]);
        final outOk = [two | (one & ~ownerRead), two | (one & ownerRead)];
        final gPopQ = [
          for (final d in ['aw', 'ar']) Logic(name: '${tn}_${d}_grant_pop_q'),
        ];
        for (var dir = 0; dir < 2; dir++) {
          final d = dir == 0 ? 'aw' : 'ar';
          final used = Logic(
            name: '${tn}_${d}_grant_used',
            width: widthOf(grantDepth),
          );
          Sequential(c, reset: r, [
            used <
                used +
                    held[dir].zeroExtend(used.width) -
                    gPopQ[dir].zeroExtend(used.width),
          ]);
          var ok =
              outOk[dir] & _fits(used, [held[dir], now[dir]], grantDepth, 1);
          final free = remapFree[t][dir];
          if (few[t][dir]) {
            // Slot credits: a grant whose ID held no slot takes one; the
            // lookup gives it back when the ID was there, or charges one
            // when an ID lost its slot on the way.
            final k = remap[t]![dir].fid.length;
            final ru = Logic(
              name: '${tn}_${d}_remap_used',
              width: widthOf(k + 1),
            );
            final rw = ru.width;
            Sequential(c, reset: r, [
              ru <
                  ru +
                      charged[t][dir].zeroExtend(rw) +
                      free!.$2.zeroExtend(rw) -
                      free.$1.zeroExtend(rw) -
                      free.$3.zeroExtend(rw),
            ]);
            final mayTake = (elig[t][dir] & slotElig[t][dir] & wantSlot(t, dir))
                .named('${tn}_${d}_may_take_slot');
            Sequential(c, reset: r, [
              slotElig[t][dir] < _fits(ru, [charged[t][dir], mayTake], k, 1),
            ]);
            harborSimWatch(
              c,
              r,
              () => simInt(ru) > k + 1
                  ? '$tn $d: remap slot credits ${simInt(ru)} over ${k + 1}'
                  : null,
            );
          }
          Sequential(c, reset: r, [elig[t][dir] < ok]);
        }
        grantPopQ.add(gPopQ);
      }
    }

    // The grant goes through a register stage into each target, so no path
    // goes from a master queue to a slave request queue in one cycle. The
    // order check and the outstanding count stay at the grant.
    final slaveTake = [
      for (var t = 0; t < nt; t++) [Logic(), Logic()],
    ];
    if (headOn) {
      requestCut.addAll([
        for (var m = 0; m < nm; m++) ...[...mDone[m], ...mDoneId[m]],
        ...bDone,
        ...rDone,
        for (var t = 0; t < nt; t++) ...[bResp[t].id, rResp[t].id],
        for (final x in slaveTake) ...x,
      ]);
    }
    final grantQ = [
      for (var t = 0; t < nt; t++)
        [
          for (var dir = 0; dir < 2; dir++)
            HarborRegFifo(
              name: '${tName[t]}_${dir == 0 ? 'aw' : 'ar'}_grant',
              clk: c,
              reset: r,
              depth: headOn ? grantDepth : 2,
              pushValid: tReq[t][dir].valid,
              pushData: harborPack([tSid[t][dir], tReq[t][dir].rest]),
              popReady: slaveTake[t][dir],
            ),
        ],
    ];
    final gFields = [
      for (var t = 0; t < nt; t++)
        [
          for (var dir = 0; dir < 2; dir++)
            harborUnpack(grantQ[t][dir].popData, [tIdW[t], restW]),
        ],
    ];
    // A request leaves the stage when the slave side queue takes it.
    final gReq = [
      for (var t = 0; t < nt; t++)
        [
          for (var dir = 0; dir < 2; dir++)
            _Req(
              grantQ[t][dir].popFire,
              gFields[t][dir][0],
              gFields[t][dir][1],
            ),
        ],
    ];
    for (var t = 0; t < nt; t++) {
      for (var dir = 0; dir < 2; dir++) {
        inReady[t][dir] <= grantQ[t][dir].pushReady;
      }
    }
    if (headOn) {
      Sequential(c, reset: r, [
        for (var t = 0; t < nt; t++)
          for (var dir = 0; dir < 2; dir++)
            grantPopQ[t][dir] < grantQ[t][dir].popFire,
      ]);
    }

    // Write data. A master's beats go to the targets of its AWs in order,
    // and a target takes beats from the masters of its AWs in order. A beat
    // for a target waits until the AW of its burst is in the slave side
    // queue.
    final wSlaveReady = [for (var t = 0; t < nt; t++) Logic()];
    final wLastBeat = [
      for (var t = 0; t < nt; t++) Logic(name: '${tName[t]}_w_last_beat'),
    ];
    final wReady = <Logic>[];
    for (var t = 0; t < nt; t++) {
      final cw = widthOf(tN[t] + 2);
      final held = Logic(name: '${tName[t]}_w_aw_held', width: cw);
      Sequential(c, reset: r, [
        held <
            held +
                grantQ[t][0].popFire.zeroExtend(cw) -
                wLastBeat[t].zeroExtend(cw),
      ]);
      wReady.add(wSlaveReady[t] & held.neq(0));
    }
    final wPop = [for (var m = 0; m < nm; m++) Logic()];
    final wHead = [
      for (var m = 0; m < nm; m++)
        _stage(
          pass,
          name: '${masters[m].name}_w',
          clk: c,
          reset: r,
          valid: ma[m].wValid,
          data: harborPack([ma[m].wData, ma[m].wStrb, ma[m].wLast]),
          ready: ma[m].wReady,
          pop: wPop[m],
        ),
    ];
    // With a real-time master the fabric ends each write piece itself: the
    // last beat of a piece is the one the piece length names. A piece of a
    // request that did not split ends with the beat the master marks.
    final pieceLen = [for (var m = 0; m < nm; m++) Logic(width: lenW)];
    final wCount = [
      for (var m = 0; m < nm; m++)
        Logic(name: '${masters[m].name}_w_count', width: lenW),
    ];
    final wPieceEnd = [for (var m = 0; m < nm; m++) Logic()];
    Logic withLast(Logic data, Logic last) =>
        [last, data.getRange(0, data.width - 1)].concat();
    final wLast = [
      for (var m = 0; m < nm; m++)
        hasRt ? wCount[m].eq(pieceLen[m]) : wHead[m].data[-1],
    ];
    final wData = [
      for (var m = 0; m < nm; m++)
        hasRt ? withLast(wHead[m].data, wLast[m]) : wHead[m].data,
    ];
    final tBeat = <_WBeat>[];
    if (topology == HarborFabricTopology.crossbar) {
      final xfer = [
        for (var m = 0; m < nm; m++) [for (var t = 0; t < nt; t++) Logic()],
      ];
      final routes = [
        for (var m = 0; m < nm; m++)
          HarborRegFifo(
            name: '${masters[m].name}_w_route',
            clk: c,
            reset: r,
            depth: masters[m].outstandingOn(HarborFabricKind.axi4),
            pushValid: hasRt ? mFire[m][0] : mPop[m][0],
            pushData: hasRt
                ? harborPack([mTgtIdx[m][0], mPieceLen[m][0]])
                : mTgtIdx[m][0],
            popReady: wPop[m] & wLast[m],
          ),
      ];
      final routeTgt = [
        for (var m = 0; m < nm; m++)
          hasRt
              ? harborUnpack(routes[m].popData, [tW, lenW]).first
              : routes[m].popData,
      ];
      if (hasRt) {
        for (var m = 0; m < nm; m++) {
          pieceLen[m] <= harborUnpack(routes[m].popData, [tW, lenW])[1];
          wPieceEnd[m] <= wPop[m] & wLast[m];
        }
      }
      for (var t = 0; t < nt; t++) {
        final from = [for (var m = 0; m < nm; m++) xfer[m][t]];
        final beat = _WBeat(anyOf(from), pick(from, wData), pick(from, wLast));
        final src = HarborRegFifo(
          name: '${tName[t]}_w_source',
          clk: c,
          reset: r,
          depth: tN[t],
          pushValid: tFire[t][0],
          pushData: tMaster[t][0],
          popReady: beat.valid & beat.last,
        );
        for (var m = 0; m < nm; m++) {
          xfer[m][t] <=
              wHead[m].valid &
                  routes[m].popValid &
                  routeTgt[m].eq(Const(t, width: tW)) &
                  src.popValid &
                  src.popData.eq(Const(m, width: mW)) &
                  wReady[t];
        }
        tBeat.add(beat);
      }
      for (var m = 0; m < nm; m++) {
        wPop[m] <= anyOf(xfer[m]);
      }
    } else {
      final orderPop = Logic(name: 'bus_w_order_pop');
      final order = HarborRegFifo(
        name: 'bus_w_order',
        clk: c,
        reset: r,
        depth: masters.fold(
          0,
          (n, m) => n + m.outstandingOn(HarborFabricKind.axi4),
        ),
        pushValid: anyOf([
          for (var m = 0; m < nm; m++) hasRt ? mFire[m][0] : mPop[m][0],
        ]),
        pushData: hasRt
            ? harborPack([awBusMaster.first, awBusTarget.first, awBusLen.first])
            : harborPack([awBusMaster.first, awBusTarget.first]),
        popReady: orderPop,
      );
      final [mh, th, ...more] = harborUnpack(order.popData, [
        mW,
        tW,
        if (hasRt) lenW,
      ]);
      final mOh = decodeIndex(mh, nm);
      final tOh = decodeIndex(th, nt);
      final xfer =
          (order.popValid &
                  pick(mOh, [for (final f in wHead) f.valid]) &
                  pick(tOh, wReady))
              .named('bus_w_xfer');
      final Logic data;
      final Logic last;
      if (hasRt) {
        final count = Logic(name: 'bus_w_count', width: lenW);
        last = count.eq(more.first);
        data = withLast(pick(mOh, [for (final f in wHead) f.data]), last);
        Sequential(c, reset: r, [
          If(xfer, then: [count < mux(last, Const(0, width: lenW), count + 1)]),
        ]);
      } else {
        data = pick(mOh, wData);
        last = pick(mOh, wLast);
      }
      orderPop <= xfer & last;
      for (var m = 0; m < nm; m++) {
        wPop[m] <= xfer & mOh[m];
        if (hasRt) wPieceEnd[m] <= xfer & mOh[m] & last;
      }
      for (var t = 0; t < nt; t++) {
        tBeat.add(_WBeat(xfer & tOh[t], data, last));
      }
    }

    if (hasRt) {
      for (var m = 0; m < nm; m++) {
        if (topology == HarborFabricTopology.crossbar) {
          Sequential(c, reset: r, [
            If(
              wPop[m],
              then: [
                wCount[m] < mux(wLast[m], Const(0, width: lenW), wCount[m] + 1),
              ],
            ),
          ]);
        }
        Sequential(c, reset: r, [
          wPieces[m] <
              wPieces[m] +
                  mFire[m][0].zeroExtend(4) -
                  wPieceEnd[m].zeroExtend(4),
        ]);
      }
    }

    for (var t = 0; t < nt; t++) {
      wLastBeat[t] <= tBeat[t].valid & tBeat[t].last;
    }
    if (headOn) {
      requestCut.addAll([
        for (var t = 0; t < nt; t++) ...[
          bResp[t].ready,
          rResp[t].ready,
          tBeat[t].valid,
          tBeat[t].data,
          tBeat[t].last,
        ],
      ]);
    }

    // Slave paths and the error slave.
    final dead = <Logic>[];
    for (var t = 0; t < nst; t++) {
      final x = _slavePath(
        c,
        r,
        p: tName[t],
        s: sa[t],
        lite: sLite[t],
        outstanding: tN[t],
        timeout: slaves[tSlave[t]].timeout,
        aw: gReq[t][0],
        awSid: gReq[t][0].id,
        ar: gReq[t][1],
        arSid: gReq[t][1].id,
        w: tBeat[t],
        awReady: slaveTake[t][0],
        arReady: slaveTake[t][1],
        wReady: wSlaveReady[t],
        b: bResp[t],
        rd: rResp[t],
        addrW: addrW,
        innerW: innerW,
        range: slaves[tSlave[t]].range,
        offset: slaves[tSlave[t]].offset,
        liteStaged: headOn,
        cutStaged: fast,
      );
      if (x != null) dead.add(x);
    }
    _errorSlave(
      c,
      r,
      aw: gReq[nst][0],
      awSid: gReq[nst][0].id,
      ar: gReq[nst][1],
      arSid: gReq[nst][1].id,
      w: tBeat[nst],
      awReady: slaveTake[nst][0],
      arReady: slaveTake[nst][1],
      wReady: wSlaveReady[nst],
      b: bResp[nst],
      rd: rResp[nst],
      innerW: innerW,
      dataW: dataW,
    );
    output('bus_error') <= anyOf(dead);
    output('timeout_count') <= timeoutCountOf(dead, slaves.length);

    // Responses. The master index on top of the full ID picks the master.
    for (var dir = 0; dir < 2; dir++) {
      final resp = dir == 0 ? bResp : rResp;
      final d = dir == 0 ? 'b' : 'r';
      final mids = <Logic>[];
      final dest = <List<Logic>>[];
      for (var t = 0; t < nt; t++) {
        final full = fullOf(t, dir, resp[t].id);
        mids.add(full.getRange(0, maxId));
        dest.add(nm > 1 ? decodeIndex(full.getRange(maxId), nm) : [Const(1)]);
      }
      // The fields the master FIFOs take: from the slave side, or at the
      // fast level from the front entry of each response stage.
      var iMid = mids;
      var iPay = [for (final x in resp) x.payload];
      var iLast = [for (final x in resp) x.last];
      final stage = fast
          ? [
              for (var t = 0; t < nt; t++)
                _respStage(
                  c,
                  r,
                  name: '${tName[t]}_${d}_rhead',
                  resp: resp[t],
                  mid: mids[t],
                  dest: dest[t],
                  withLast: dir == 1,
                ),
            ]
          : null;
      if (stage != null) {
        iMid = [for (final x in stage) x.mid];
        iPay = [for (final x in stage) x.payload];
        iLast = [for (final x in stage) x.last];
      }
      final push = [for (var m = 0; m < nm; m++) Logic()];
      final pushData = <Logic>[];
      final outs = <HarborRegFifo>[];
      final items = <List<Logic>>[];
      // A master with split bursts has one burst in flight, so each
      // response is of that burst. The pieces granted that are not its
      // last one end with a slave side last (R) or B that the master does
      // not see. B of a piece with an error leaves its code for the B of
      // the last piece.
      final pieces = [
        for (var m = 0; m < nm; m++)
          splitM[m]
              ? Logic(name: '${masters[m].name}_${d}_pieces', width: lenW + 1)
              : null,
      ];
      final worst = [
        for (var m = 0; m < nm; m++)
          splitM[m] && dir == 0
              ? Logic(name: '${masters[m].name}_b_worst', width: 2)
              : null,
      ];
      for (var m = 0; m < nm; m++) {
        final a = ma[m];
        final more = pieces[m]?.neq(0);
        items.add([
          for (var t = 0; t < nt; t++)
            harborPack([
              iMid[t].getRange(0, a.idWidth),
              if (worst[m] != null && fast)
                _worse(worst[m]!, iPay[t])
              else if (worst[m] != null)
                mux(
                  _respKey(worst[m]!).gt(_respKey(iPay[t])),
                  worst[m]!,
                  iPay[t],
                )
              else
                iPay[t],
              if (dir == 1) more != null ? iLast[t] & ~more : iLast[t],
            ]),
        ]);
        final data = Logic(width: items[m].first.width);
        pushData.add(data);
        final ready = dir == 0 ? a.bReady : a.rReady;
        final f = HarborRegFifo(
          name: '${masters[m].name}_$d',
          clk: c,
          reset: r,
          depth: fast ? respDepth : 2,
          pushValid: push[m],
          pushData: data,
          popReady: ready,
          resetEntries: true,
        );
        outs.add(f);
        if (dir == 0) {
          final [id, rsp] = harborUnpack(f.popData, [
            a.idWidth,
            Axi4Interface.respWidth,
          ]);
          a.bValid <= f.popValid;
          a.bId <= id;
          a.bResp <= rsp;
          mDone[m][0] <= push[m];
        } else {
          final [id, dat, rsp, last] = harborUnpack(f.popData, [
            a.idWidth,
            dataW,
            Axi4Interface.respWidth,
            1,
          ]);
          a.rValid <= f.popValid;
          a.rId <= id;
          a.rData <= dat;
          a.rResp <= rsp;
          a.rLast <= last;
          mDone[m][1] <= push[m] & data[-1];
        }
        mDoneId[m][dir] <= data.getRange(0, a.idWidth);
      }
      // Pushes a response of master [m] to its FIFO. [raw] is high when a
      // response for [m] is taken, with [last] and [payload] of its target.
      void pushTo(
        int m,
        Logic raw,
        Logic Function() last,
        Logic Function() payload, {
        Logic Function()? merged,
      }) {
        final n = pieces[m];
        if (n == null) {
          push[m] <= raw;
          return;
        }
        final nonFinal = mNonFinal[m][dir];
        if (dir == 1) {
          push[m] <= raw;
          final end = raw & last() & n.neq(0);
          Sequential(c, reset: r, [
            n < n + nonFinal.zeroExtend(lenW + 1) - end.zeroExtend(lenW + 1),
          ]);
          return;
        }
        final swallow = raw & n.neq(0);
        push[m] <= raw & ~swallow;
        final w = worst[m]!;
        Sequential(c, reset: r, [
          n < n + nonFinal.zeroExtend(lenW + 1) - swallow.zeroExtend(lenW + 1),
          If(
            swallow,
            then: [
              if (merged != null)
                w < merged()
              else
                If(_respKey(payload()).gt(_respKey(w)), then: [w < payload()]),
            ],
            orElse: [
              If(raw, then: [w < 0]),
            ],
          ),
        ]);
      }

      if (stage != null) {
        // The arbiters see only flops: the front of each response stage and
        // the credit flag of each master FIFO. The grant register pops the
        // stage and selects its entry into the master FIFO one cycle later.
        final elig = [
          for (final mc in masters) Logic(name: '${mc.name}_${d}_resp_elig'),
        ];
        final sel = <List<Logic>>[];
        if (topology == HarborFabricTopology.crossbar) {
          for (var m = 0; m < nm; m++) {
            final g = _roundRobin('${masters[m].name}_${d}_resp', c, r, [
              for (var t = 0; t < nt; t++)
                stage[t].valid & stage[t].dest[m] & elig[m],
            ]);
            final reg = Logic(
              name: '${masters[m].name}_${d}_resp_grant_reg',
              width: nt,
            );
            Sequential(c, reset: r, [reg < g.rconcat()]);
            sel.add([for (var t = 0; t < nt; t++) reg[t]]);
          }
          for (var t = 0; t < nt; t++) {
            stage[t].pop <= anyOf([for (var m = 0; m < nm; m++) sel[m][t]]);
          }
        } else {
          final g = _roundRobin('bus_${d}_resp', c, r, [
            for (var t = 0; t < nt; t++)
              stage[t].valid &
                  anyOf([
                    for (var m = 0; m < nm; m++) stage[t].dest[m] & elig[m],
                  ]),
          ]);
          final reg = Logic(name: 'bus_${d}_resp_grant_reg', width: nt);
          Sequential(c, reset: r, [reg < g.rconcat()]);
          for (var t = 0; t < nt; t++) {
            stage[t].pop <= reg[t];
          }
          for (var m = 0; m < nm; m++) {
            sel.add([
              for (var t = 0; t < nt; t++) reg[t] & stage[t].popDest[m],
            ]);
          }
        }
        for (var m = 0; m < nm; m++) {
          final raw = anyOf(sel[m]);
          pushTo(
            m,
            raw,
            () => pick(sel[m], iLast),
            () => pick(sel[m], iPay),
            merged: worst[m] == null
                ? null
                : () => pick(sel[m], [
                    for (final x in iPay) _worse(worst[m]!, x),
                  ]),
          );
          pushData[m] <= pick(sel[m], items[m]);
          // A grant needs a free FIFO entry after the entries in the FIFO,
          // the grant in the register and a grant now.
          Sequential(c, reset: r, [
            elig[m] < _fits(outs[m].count, [raw, elig[m]], respDepth, 1),
          ]);
        }
      } else if (topology == HarborFabricTopology.crossbar) {
        final grants = <List<Logic>>[];
        for (var m = 0; m < nm; m++) {
          final g = roundRobin('${masters[m].name}_${d}_resp', c, r, [
            for (var t = 0; t < nt; t++)
              resp[t].valid & dest[t][m] & outs[m].pushReady,
          ]);
          grants.add(g);
          final raw = anyOf(g);
          pushTo(
            m,
            raw,
            () => pick(g, [for (final x in resp) x.last]),
            () => pick(g, [for (final x in resp) x.payload]),
          );
          pushData[m] <= pick(g, items[m]);
        }
        for (var t = 0; t < nt; t++) {
          resp[t].ready <= anyOf([for (var m = 0; m < nm; m++) grants[m][t]]);
        }
      } else {
        final g = roundRobin('bus_${d}_resp', c, r, [
          for (var t = 0; t < nt; t++)
            resp[t].valid &
                anyOf([
                  for (var m = 0; m < nm; m++) dest[t][m] & outs[m].pushReady,
                ]),
        ]);
        for (var m = 0; m < nm; m++) {
          pushTo(
            m,
            anyOf([for (var t = 0; t < nt; t++) g[t] & dest[t][m]]),
            () => pick(g, [for (final x in resp) x.last]),
            () => pick(g, [for (final x in resp) x.payload]),
          );
          pushData[m] <= pick(g, items[m]);
        }
        for (var t = 0; t < nt; t++) {
          resp[t].ready <= g[t];
        }
      }
    }
  }

  // The request stage of a master channel at the balanced and fast levels:
  // a 2 entry FIFO whose pointers and flags take no adder, or with [pass]
  // the port itself, whose READY is then [pop].
  static ({Logic valid, Logic data}) _inStage(
    bool pass, {
    required String name,
    required Logic clk,
    required Logic reset,
    required Logic valid,
    required Logic data,
    required Logic ready,
    required Logic pop,
  }) {
    if (pass) {
      ready <= pop;
      return (valid: valid, data: data);
    }
    final wr = Logic(name: '${name}_wr');
    final rd = Logic(name: '${name}_rd');
    final has = Logic(name: '${name}_has');
    final full = Logic(name: '${name}_full');
    final push = valid & ~full;
    final take = pop & has;
    final ram = HarborFifoRam(
      name: '${name}_ram',
      clk: clk,
      wrEn: push,
      wrAddr: wr,
      wrData: data,
      rdAddr: rd,
      depth: 2,
      zeroInit: false,
    );
    Sequential(clk, reset: reset, [
      wr < wr ^ push,
      rd < rd ^ take,
      has < push | full | (has & ~take),
      full < (full & ~take) | (has & ~full & push & ~take),
    ]);
    ready <= ~full;
    return (valid: has, data: ram.rdData);
  }

  // The response stage of a target at the fast level: two entries, each with
  // the master side ID, the payload, the last flag and the destination
  // master one-hot. [pop] is the grant register, which takes the front
  // entry. [valid] and [dest] are of the entry after it, which the arbiter
  // sees, and [mid], [payload], [last] and [popDest] are of the front entry.
  static ({
    Logic valid,
    List<Logic> dest,
    Logic pop,
    Logic mid,
    Logic payload,
    Logic last,
    List<Logic> popDest,
  })
  _respStage(
    Logic clk,
    Logic reset, {
    required String name,
    required _Resp resp,
    required Logic mid,
    required List<Logic> dest,
    required bool withLast,
  }) {
    final widths = [
      mid.width,
      resp.payload.width,
      if (withLast) 1,
      dest.length,
    ];
    final data = harborPack([
      mid,
      resp.payload,
      if (withLast) resp.last,
      dest.rconcat(),
    ]);
    final v0 = Logic(name: '${name}_v0');
    final v1 = Logic(name: '${name}_v1');
    final e0 = Logic(name: '${name}_e0', width: data.width);
    final e1 = Logic(name: '${name}_e1', width: data.width);
    final pop = Logic();
    final valid = (pop & v1) | (~pop & v0);
    final front = harborLoad(e0, pop, e1);
    final push = resp.valid & (~v1 | pop);
    resp.ready <= ~v1 | pop;
    Sequential(clk, reset: reset, [
      v0 < valid | push,
      v1 < (~pop & v1) | (push & valid),
    ]);
    Sequential(clk, [
      e0 < harborLoad(front, ~valid, data),
      e1 < harborLoad(e1, push & valid, data),
    ]);
    final f = harborUnpack(e0, widths);
    final next = harborUnpack(front, widths).last;
    return (
      valid: valid,
      dest: [for (var i = 0; i < dest.length; i++) valid & next[i]],
      pop: pop,
      mid: f[0],
      payload: f[1],
      last: withLast ? f[2] : Const(1),
      popDest: [for (var i = 0; i < dest.length; i++) f.last[i]],
    );
  }

  // A register for the made-up responses of a cut off slave. It loads
  // [valid], [sel] and [fields] while [dead] and empty, and empties when
  // [ready] takes it.
  static ({Logic valid, List<Logic> sel, List<Logic> fields}) _cutStage(
    Logic clk,
    Logic reset,
    String name,
    Logic dead,
    Logic ready,
    Logic valid,
    List<Logic> sel,
    List<Logic> fields,
  ) {
    final v = Logic(name: '${name}_v');
    final selQ = Logic(name: '${name}_sel', width: sel.length);
    final f = harborPack(fields);
    final fQ = Logic(name: '${name}_fields', width: f.width);
    final load = dead & ~v;
    Sequential(clk, reset: reset, [
      v < (load & valid) | (v & ~ready),
      selQ < harborLoad(selQ, load, sel.rconcat()),
      fQ < harborLoad(fQ, load, f),
    ]);
    return (
      valid: v,
      sel: [for (var i = 0; i < sel.length; i++) selQ[i]],
      fields: harborUnpack(fQ, [for (final x in fields) x.width]),
    );
  }

  // The worse of the response codes [a] and [b], as [_respKey] orders them,
  // in AND and OR terms.
  static Logic _worse(Logic a, Logic b) {
    final ka1 = a[1];
    final ka0 = ~(a[1] ^ a[0]);
    final kb1 = b[1];
    final kb0 = ~(b[1] ^ b[0]);
    final aWorse = (ka1 & ~kb1) | (~(ka1 ^ kb1) & ka0 & ~kb0);
    return harborLoad(b, aWorse, a);
  }

  // Round robin over [req] in AND and OR terms of the requests and the
  // one-hot pointer, with no adder. The order is that of [roundRobin].
  static List<Logic> _roundRobin(
    String name,
    Logic clk,
    Logic reset,
    List<Logic> req,
  ) {
    final n = req.length;
    if (n == 1) return req;
    final last = Logic(name: '${name}_rr', width: n);
    Logic none(Iterable<int> js) => _allOf([for (final j in js) ~req[j]]);
    final fresh = ~anyOf([for (var i = 0; i < n; i++) last[i]]);
    final g = [
      for (var i = 0; i < n; i++)
        req[i] &
            ((fresh & none([for (var j = 0; j < i; j++) j])) |
                anyOf([
                  for (var p = 0; p < n; p++)
                    last[p] &
                        none([
                          for (var q = 1; q < n && (p + q) % n != i; q++)
                            (p + q) % n,
                        ]),
                ])),
    ];
    final grant = g.rconcat().named('${name}_grant');
    Sequential(clk, reset: reset, [last < harborLoad(last, anyOf(req), grant)]);
    return [for (var i = 0; i < n; i++) grant[i]];
  }

  static Logic _allOf(List<Logic> xs) =>
      xs.isEmpty ? Const(1) : xs.reduce((a, b) => a & b);

  // High when [used] plus the number of high bits in [pend] plus [x] is at
  // most [cap]. It is AND and OR terms of equalities, with no adder.
  static Logic _fits(Logic used, List<Logic> pend, int cap, int x) {
    final terms = <Logic>[];
    for (var v = 0; v <= pend.length; v++) {
      final top = min(cap - v - x, (1 << used.width) - 1);
      if (top < 0) continue;
      final exactly = anyOf([
        for (var s = 0; s < 1 << pend.length; s++)
          if (_ones(s) == v)
            _allOf([
              for (var i = 0; i < pend.length; i++)
                (s >> i) & 1 == 1 ? pend[i] : ~pend[i],
            ]),
      ]);
      terms.add(
        exactly &
            anyOf([
              for (var u = 0; u <= top; u++)
                used.eq(Const(u, width: used.width)),
            ]),
      );
    }
    return anyOf(terms);
  }

  static int _ones(int s) => s == 0 ? 0 : (s & 1) + _ones(s >> 1);

  // The request stage of a master channel: a 2 entry FIFO, or with [pass]
  // the port itself, whose READY is then [pop].
  static ({Logic valid, Logic data}) _stage(
    bool pass, {
    required String name,
    required Logic clk,
    required Logic reset,
    required Logic valid,
    required Logic data,
    required Logic ready,
    required Logic pop,
  }) {
    if (pass) {
      ready <= pop;
      return (valid: valid, data: data);
    }
    final f = HarborRegFifo(
      name: name,
      clk: clk,
      reset: reset,
      depth: 2,
      pushValid: valid,
      pushData: data,
      popReady: pop,
    );
    ready <= f.pushReady;
    return (valid: f.popValid, data: f.popData);
  }

  // AW, AR and W FIFOs to one slave, and the timeout guard when the slave
  // has a timeout. Returns the guard's cut off flag.
  //
  // The FIFOs keep only the address bits that change in the slave region.
  // The slave sees the full address, or its offset in the region.
  //
  // An AXI4-Lite slave [lite] has 1 request in flight. Its AW and AR share
  // one entry, which stays until the response ends (with [liteStaged],
  // until the response is queued), and its W has one entry. [s] then only carries the handshakes and responses for the
  // guard. A burst runs as single beats. A narrow access is a full word
  // access with the write strobes of its lanes, since the master takes its
  // bytes by address.
  //
  // The guard keeps a record of each request in flight. When the slave owes
  // something and shows no progress for `timeout` cycles, the guard cuts it
  // off until reset: it ends every request in flight and every later one
  // with SLVERR, takes the rest of their write data, and takes and drops
  // each late response. So a late response never reaches a master.
  static Logic? _slavePath(
    Logic c,
    Logic r, {
    required String p,
    required Axi4Interface s,
    required Axi4LiteInterface? lite,
    required int outstanding,
    required int timeout,
    required _Req aw,
    required Logic awSid,
    required _Req ar,
    required Logic arSid,
    required _WBeat w,
    required Logic awReady,
    required Logic arReady,
    required Logic wReady,
    required _Resp b,
    required _Resp rd,
    required int addrW,
    required int innerW,
    required BusAddressRange range,
    required bool offset,
    bool liteStaged = false,
    bool cutStaged = false,
  }) {
    final guard = timeout > 0;
    final dead = guard ? Logic(name: '${p}_cut_off') : Const(0);
    final k = _regionBits(range, addrW);
    final restWidths = _restWidths(innerW);
    Logic slaveAddr(Logic low) => _slaveAddr(low, range, offset, addrW);
    final Logic arPending;
    final Logic wPending;
    if (lite == null) {
      final fifos = <HarborRegFifo>[];
      for (final (d, x, sid, ready) in [
        ('AW', aw, awSid, awReady),
        ('AR', ar, arSid, arReady),
      ]) {
        final valid = Logic(name: '${p}_${d.toLowerCase()}_pop');
        final [addr, ...more] = harborUnpack(x.rest, restWidths);
        final f = HarborRegFifo(
          name: '${p}_${d.toLowerCase()}',
          clk: c,
          reset: r,
          depth: 2,
          pushValid: x.valid & ~dead,
          pushData: harborPack([sid, addr.getRange(0, k), ...more]),
          popReady: s.port('${d}READY') & valid,
          resetEntries: true,
        );
        final [id, low, ...fields] = harborUnpack(f.popData, [
          s.idWidth,
          k,
          ...restWidths.skip(1),
        ]);
        s.port('${d}ID') <= id;
        s.port('${d}ADDR') <= slaveAddr(low);
        for (var i = 1; i < _restFields.length; i++) {
          s.port('$d${_restFields[i]}') <= fields[i - 1];
        }
        // A cut off slave never sees the requests still queued for it.
        valid <=
            cutValid(
              '${p}_${d.toLowerCase()}',
              c,
              r,
              f.popValid,
              s.port('${d}READY'),
              dead,
            );
        s.port('${d}VALID') <= valid;
        ready <= f.pushReady | dead;
        fifos.add(f);
      }
      arPending = fifos[1].popValid;
      final wValid = Logic(name: '${p}_w_pop');
      final wF = HarborRegFifo(
        name: '${p}_w',
        clk: c,
        reset: r,
        depth: 2,
        pushValid: w.valid & ~dead,
        pushData: w.data,
        popReady: s.wReady & wValid,
        resetEntries: true,
      );
      wValid <= cutValid('${p}_w', c, r, wF.popValid, s.wReady, dead);
      final [wData, wStrb, wLast] = harborUnpack(wF.popData, [
        s.dataWidth,
        s.dataWidth ~/ 8,
        1,
      ]);
      s.wValid <= wValid;
      s.wData <= wData;
      s.wStrb <= wStrb;
      s.wLast <= wLast;
      wReady <= wF.pushReady | dead;
      wPending = wF.popValid;
    } else {
      final pending = (liteStaged ? _litePathStaged : _litePath)(
        c,
        r,
        p: p,
        s: s,
        l: lite,
        aw: aw,
        awSid: awSid,
        ar: ar,
        arSid: arSid,
        w: w,
        awReady: awReady,
        arReady: arReady,
        wReady: wReady,
        dead: dead,
        k: k,
        restWidths: restWidths,
        slaveAddr: slaveAddr,
      );
      arPending = pending.$1;
      wPending = pending.$2;
    }

    if (!guard) {
      b.valid <= s.bValid;
      b.id <= s.bId;
      b.payload <= s.bResp;
      b.last <= Const(1);
      s.bReady <= b.ready;
      rd.valid <= s.rValid;
      rd.id <= s.rId;
      rd.payload <= harborPack([s.rData, s.rResp]);
      rd.last <= s.rLast;
      s.rReady <= rd.ready;
      return null;
    }

    final n = outstanding;
    final idW = s.idWidth;
    const lenW = Axi4Interface.lenWidth;
    final aheadW = widthOf(n);
    final ev = [for (var i = 0; i < n; i++) Logic(name: '${p}_rec${i}_v')];
    final isW = [for (var i = 0; i < n; i++) Logic(name: '${p}_rec${i}_w')];
    final gid = [
      for (var i = 0; i < n; i++) Logic(name: '${p}_rec${i}_id', width: idW),
    ];
    final glen = [
      for (var i = 0; i < n; i++) Logic(name: '${p}_rec${i}_len', width: lenW),
    ];
    final gbeat = [
      for (var i = 0; i < n; i++) Logic(name: '${p}_rec${i}_beat', width: lenW),
    ];
    final ahead = [
      for (var i = 0; i < n; i++)
        Logic(name: '${p}_rec${i}_ahead', width: aheadW),
    ];
    final wdone = [
      for (var i = 0; i < n; i++) Logic(name: '${p}_rec${i}_wdone'),
    ];
    final first = [for (var i = 0; i < n; i++) ahead[i].eq(0)];
    final free = [for (final v in ev) ~v];
    final awSlot = lowestOf(free);
    final arSlot = highestOf(free);
    final slvErr = _resp(Axi4RespField.slvErr);

    // B: passed through, or made up once cut off.
    final bMatch = [
      for (var i = 0; i < n; i++) ev[i] & isW[i] & gid[i].eq(s.bId) & first[i],
    ];
    final bCand = [
      for (var i = 0; i < n; i++) ev[i] & isW[i] & wdone[i] & first[i],
    ];
    final bPick = lowestOf(bCand);
    // With [cutStaged], a made-up response comes from a register that loads
    // when it is empty. So the response stage sees only flops, for one
    // response each 2 cycles.
    final bCut = cutStaged
        ? _cutStage(c, r, '${p}_cut_b', dead, b.ready, anyOf(bCand), bPick, [
            pick(bPick, gid),
          ])
        : null;
    b.valid <= mux(dead, bCut?.valid ?? anyOf(bCand), s.bValid);
    b.id <= mux(dead, bCut?.fields[0] ?? pick(bPick, gid), s.bId);
    b.payload <= mux(dead, slvErr, s.bResp);
    b.last <= Const(1);
    s.bReady <= dead | b.ready;
    final bDoneOh = [
      for (var i = 0; i < n; i++)
        b.fire & mux(dead, bCut?.sel[i] ?? bPick[i], bMatch[i]),
    ];

    // R: passed through, or made up once cut off. A burst already started
    // goes first.
    final rMatch = [
      for (var i = 0; i < n; i++) ev[i] & ~isW[i] & gid[i].eq(s.rId) & first[i],
    ];
    final rCand = [for (var i = 0; i < n; i++) ev[i] & ~isW[i] & first[i]];
    final started = [for (var i = 0; i < n; i++) rCand[i] & gbeat[i].neq(0)];
    final anyStarted = anyOf(started);
    final rFirstStarted = lowestOf(started);
    final rFirstCand = lowestOf(rCand);
    final rPick = [
      for (var i = 0; i < n; i++)
        mux(anyStarted, rFirstStarted[i], rFirstCand[i]),
    ];
    final rCut = cutStaged
        ? _cutStage(c, r, '${p}_cut_r', dead, rd.ready, anyOf(rCand), rPick, [
            pick(rPick, gid),
            pick(rPick, gbeat).eq(pick(rPick, glen)),
          ])
        : null;
    final rSel = [
      for (var i = 0; i < n; i++)
        mux(dead, rCut?.sel[i] ?? rPick[i], rMatch[i]),
    ];
    rd.valid <= mux(dead, rCut?.valid ?? anyOf(rCand), s.rValid);
    rd.id <= mux(dead, rCut?.fields[0] ?? pick(rPick, gid), s.rId);
    rd.payload <=
        mux(
          dead,
          harborPack([Const(0, width: s.dataWidth), slvErr]),
          harborPack([s.rData, s.rResp]),
        );
    rd.last <=
        mux(
          dead,
          rCut?.fields[1] ?? pick(rPick, gbeat).eq(pick(rPick, glen)),
          s.rLast,
        );
    s.rReady <= dead | rd.ready;
    final rBeatOh = [for (var i = 0; i < n; i++) rd.fire & rSel[i]];
    final rDoneOh = [for (var i = 0; i < n; i++) rBeatOh[i] & rd.last];

    // A new record counts the records of the same ID and direction ahead
    // of it. A record that ends lets the others of its ID move up.
    final awLen = aw.rest.getRange(innerW, innerW + lenW);
    final arLen = ar.rest.getRange(innerW, innerW + lenW);
    final awAhead = countOf([
      for (var i = 0; i < n; i++)
        ev[i] & isW[i] & gid[i].eq(awSid) & ~bDoneOh[i],
    ], aheadW);
    final arAhead = countOf([
      for (var i = 0; i < n; i++)
        ev[i] & ~isW[i] & gid[i].eq(arSid) & ~rDoneOh[i],
    ], aheadW);
    final move = [
      for (var i = 0; i < n; i++)
        ev[i] &
            ((isW[i] & b.fire & gid[i].eq(b.id) & ~bDoneOh[i]) |
                (~isW[i] & rd.fire & rd.last & gid[i].eq(rd.id) & ~rDoneOh[i])),
    ];

    // Write data comes in AW order, so a FIFO of slots tells which write a
    // beat belongs to.
    final wOrder = HarborRegFifo(
      name: '${p}_w_order',
      clk: c,
      reset: r,
      depth: n,
      pushValid: aw.valid,
      pushData: indexOf(awSlot, indexWidth(n)),
      popReady: w.valid & w.last,
    );
    final wDoneSet = decodeIndex(
      wOrder.popData,
      n,
    ).map((x) => x & w.valid & w.last).toList();

    // The timer runs while the slave owes something: a read, a write whose
    // data is all here, an AR or a W beat. An AW alone does not count, since
    // a slave may hold AWREADY until WVALID. Any handshake or response VALID
    // from the slave restarts the timer.
    final busy =
        anyOf([for (var i = 0; i < n; i++) ev[i] & (~isW[i] | wdone[i])]) |
        arPending |
        wPending;
    final progress =
        (s.awValid & s.awReady) |
        (s.arValid & s.arReady) |
        (s.wValid & s.wReady) |
        s.bValid |
        s.rValid;
    final tw = widthOf(timeout);
    final timer = Logic(name: '${p}_timer', width: tw);
    Sequential(c, reset: r, [
      If.block([
        Iff(dead | ~busy | progress, [timer < 0]),
        ElseIf(timer.eq(Const(timeout - 1, width: tw)), [dead < 1]),
        Else([timer < timer + 1]),
      ]),
      for (var i = 0; i < n; i++)
        If.block([
          Iff(aw.valid & awSlot[i], [
            ev[i] < 1,
            isW[i] < 1,
            gid[i] < awSid,
            glen[i] < awLen,
            gbeat[i] < 0,
            ahead[i] < awAhead,
            wdone[i] < 0,
          ]),
          ElseIf(ar.valid & arSlot[i], [
            ev[i] < 1,
            isW[i] < 0,
            gid[i] < arSid,
            glen[i] < arLen,
            gbeat[i] < 0,
            ahead[i] < arAhead,
            wdone[i] < 0,
          ]),
          Else([
            If(bDoneOh[i] | rDoneOh[i], then: [ev[i] < 0]),
            If(rBeatOh[i], then: [gbeat[i] < gbeat[i] + 1]),
            If(wDoneSet[i], then: [wdone[i] < 1]),
            If(move[i], then: [ahead[i] < ahead[i] - 1]),
          ]),
        ]),
    ]);
    return dead;
  }

  // The slave for addresses that hit no region. It answers each read with
  // all its beats and each write with one B after its last W beat, with
  // DECERR, in order per direction.
  static void _errorSlave(
    Logic c,
    Logic r, {
    required _Req aw,
    required Logic awSid,
    required _Req ar,
    required Logic arSid,
    required _WBeat w,
    required Logic awReady,
    required Logic arReady,
    required Logic wReady,
    required _Resp b,
    required _Resp rd,
    required int innerW,
    required int dataW,
  }) {
    const lenW = Axi4Interface.lenWidth;
    final decErr = _resp(Axi4RespField.decErr);
    final awF = HarborRegFifo(
      name: 'err_aw',
      clk: c,
      reset: r,
      depth: errorOutstanding,
      pushValid: aw.valid,
      pushData: awSid,
      popReady: b.fire,
    );
    awReady <= awF.pushReady;
    final arF = HarborRegFifo(
      name: 'err_ar',
      clk: c,
      reset: r,
      depth: errorOutstanding,
      pushValid: ar.valid,
      pushData: harborPack([arSid, ar.rest.getRange(innerW, innerW + lenW)]),
      popReady: rd.fire & rd.last,
    );
    arReady <= arF.pushReady;
    wReady <= Const(1);

    final cw = widthOf(errorOutstanding);
    final wDone = Logic(name: 'err_w_done', width: cw);
    b.valid <= awF.popValid & wDone.neq(0);
    b.id <= awF.popData;
    b.payload <= decErr;
    b.last <= Const(1);

    final beat = Logic(name: 'err_r_beat', width: lenW);
    final [id, len] = harborUnpack(arF.popData, [arSid.width, lenW]);
    rd.valid <= arF.popValid;
    rd.id <= id;
    rd.payload <= harborPack([Const(0, width: dataW), decErr]);
    rd.last <= beat.eq(len);
    Sequential(c, reset: r, [
      wDone < wDone + (w.valid & w.last).zeroExtend(cw) - b.fire.zeroExtend(cw),
      beat <
          (beat + rd.fire.zeroExtend(lenW)) &
              ~(rd.fire & rd.last).replicate(lenW),
    ]);
  }

  /// ID bits a slave needs to see full master IDs with no remap: the widest
  /// master ID plus the master index.
  static int fullIdWidthOf(List<HarborFabricMaster> masters) {
    final maxId = masters.map((m) => _shape(m.interface).$3 ?? 1).reduce(max);
    return maxId + (masters.length > 1 ? indexWidth(masters.length) : 0);
  }

  /// The exclusive monitor for the slave side of a fabric of [masters], or
  /// null when no master has exclusive access. A memory slave with a
  /// monitor on this fabric needs these slots and an ID width of at least
  /// [fullIdWidthOf]. The fabric check uses the default [slotBudget] for
  /// automatic masters.
  static HarborAxi4Exclusive? exclusiveOf(
    List<HarborFabricMaster> masters, {
    int slotBudget = HarborExclusive.defaultSlotBudget,
    int granuleBytes = HarborExclusive.defaultGranuleBytes,
  }) => HarborAxi4Exclusive.forMasters(
    [for (final m in masters) _shape(m.interface).$3 ?? 1],
    [for (final m in masters) m.exclusiveIds],
    slotBudget: slotBudget,
    granuleBytes: granuleBytes,
  );

  // Throws when an exclusive master or a monitored slave cannot work.
  static void _checkExclusive(
    List<HarborFabricMaster> masters,
    List<HarborFabricSlave> slaves,
  ) {
    for (final m in masters) {
      if (m.exclusive && m.interface is! Axi4Interface) {
        throw ArgumentError(
          '${m.name}: exclusive access needs a full AXI4 port',
        );
      }
      if (!m.exclusive) continue;
      for (final s in slaves) {
        if (s.exclusive == null &&
            s.memory &&
            s.interface is Axi4Interface &&
            m.reaches(s.name)) {
          throw ArgumentError(
            '${m.name}: an exclusive master reaches the memory slave '
            '${s.name}, which has no exclusive monitor. Give it a monitor or '
            'take it out of the master reach.',
          );
        }
      }
    }
    final want = exclusiveOf(masters);
    final fullW = fullIdWidthOf(masters);
    for (final s in slaves) {
      final have = s.exclusive;
      if (have == null) continue;
      final w = _shape(s.interface).$3;
      if (w == null || w < fullW) {
        throw ArgumentError(
          '${s.name}: an exclusive monitor needs full master IDs, so the '
          'slave needs ID width $fullW, but it has ${w ?? 'no ID'}',
        );
      }
      if (want == null || !have.sameIds(want)) {
        final need = want == null
            ? 'the fabric has no exclusive master'
            : 'the exclusive masters need ${want.runs}';
        throw ArgumentError(
          '${s.name}: the exclusive monitor has slots for ${have.runs}, but '
          '$need',
        );
      }
      final chans = HarborFabric.readChannelsOf(s, masters);
      for (var i = 0; i < masters.length; i++) {
        if (masters[i].exclusive && chans[i] > 0) {
          throw ArgumentError(
            '${masters[i].name}: an exclusive master must read ${s.name} on '
            'read channel 0, the only channel with the monitor',
          );
        }
      }
    }
  }

  // Address width, data width, and ID width or null for AXI4-Lite.
  static (int, int, int?) _shape(PairInterface p) => switch (p) {
    final Axi4Interface a => (a.addressWidth, a.dataWidth, a.idWidth),
    final Axi4LiteInterface l => (l.addressWidth, l.dataWidth, null),
    final Axi4ReadOnlyInterface x => (x.addressWidth, x.dataWidth, x.idWidth),
    _ => throw ArgumentError(
      'an AXI4 fabric takes Axi4Interface or Axi4LiteInterface ports, got $p',
    ),
  };

  // The master port as AXI4. An AXI4-Lite master is wired to fixed fields.
  Axi4Interface _masterPort(HarborFabricMaster m) {
    final i = m.interface;
    String uniq(String n) => '${m.name}_$n';
    if (i is Axi4Interface) {
      return i.clone()
        ..pairConnectIO(this, i, PairRole.consumer, uniquify: uniq);
    }
    final l = (i as Axi4LiteInterface).clone()
      ..pairConnectIO(this, i, PairRole.consumer, uniquify: uniq);
    final a = Axi4Interface(
      addressWidth: l.addressWidth,
      dataWidth: l.dataWidth,
      idWidth: 1,
    );
    for (final d in ['AW', 'AR']) {
      a.port('${d}ID') <= Const(0);
      a.port('${d}ADDR') <= l.port('${d}ADDR');
      a.port('${d}LEN') <= Const(0, width: Axi4Interface.lenWidth);
      a.port('${d}SIZE') <= _fullSize(l.dataWidth);
      a.port('${d}BURST') <= Const(1, width: Axi4Interface.burstWidth);
      a.port('${d}LOCK') <= Const(0);
      a.port('${d}CACHE') <= Const(0, width: Axi4Interface.cacheWidth);
      a.port('${d}PROT') <= l.port('${d}PROT');
      a.port('${d}QOS') <= Const(0, width: Axi4Interface.qosWidth);
      a.port('${d}VALID') <= l.port('${d}VALID');
      l.port('${d}READY') <= a.port('${d}READY');
    }
    a.wData <= l.wData;
    a.wStrb <= l.wStrb;
    a.wLast <= Const(1);
    a.wValid <= l.wValid;
    l.wReady <= a.wReady;
    l.bValid <= a.bValid;
    l.bResp <= a.bResp;
    a.bReady <= l.bReady;
    l.rValid <= a.rValid;
    l.rData <= a.rData;
    l.rResp <= a.rResp;
    a.rReady <= l.rReady;
    return a;
  }

  // The slave port as AXI4. For an AXI4-Lite slave, the AXI4 side only
  // carries handshakes and responses, and the slave path drives the port.
  (Axi4Interface, Axi4LiteInterface?) _slavePort(
    HarborFabricSlave s,
    Logic clk,
    Logic reset,
    int addrW,
    int dataW,
  ) {
    final i = s.interface;
    String uniq(String n) => '${s.name}_$n';
    if (i is Axi4Interface) {
      return (
        i.clone()..pairConnectIO(this, i, PairRole.provider, uniquify: uniq),
        null,
      );
    }
    var l = (i as Axi4LiteInterface).clone()
      ..pairConnectIO(this, i, PairRole.provider, uniquify: uniq);
    if (harborSlaveAdapts(s, kind: 'AXI4', addrW: addrW, dataW: dataW)) {
      final wide = Axi4LiteInterface(addressWidth: addrW, dataWidth: dataW);
      harborNarrowAxi4Lite(clk, reset, name: s.name, w: wide, n: l);
      l = wide;
    }
    final a = Axi4Interface(
      addressWidth: l.addressWidth,
      dataWidth: l.dataWidth,
      idWidth: fullIdWidth,
    );
    return (a, l);
  }

  // A read-only target for channel [k] (k >= 1) of slave [s]. Presented
  // internally as a full Axi4Interface so the rest of the fabric treats it
  // like any other target: AWREADY, WREADY, BVALID, BID and BRESP are tied
  // to 0, and AR/R are wired straight to the slave's extra read-only port.
  Axi4Interface _slaveReadPort(HarborFabricSlave s, int k) {
    final ri = s.readInterfaces[k - 1] as Axi4ReadOnlyInterface;
    final uniq = (String n) => '${s.name}_r${k}_$n';
    final ro = ri.clone()
      ..pairConnectIO(this, ri, PairRole.provider, uniquify: uniq);
    final a = Axi4Interface(
      addressWidth: ro.addressWidth,
      dataWidth: ro.dataWidth,
      idWidth: ro.idWidth,
    );
    a.awReady <= Const(0);
    a.wReady <= Const(0);
    a.bValid <= Const(0);
    a.bId <= Const(0, width: a.idWidth);
    a.bResp <= Const(0, width: Axi4Interface.respWidth);

    for (final f in [
      'ID',
      'ADDR',
      'LEN',
      'SIZE',
      'BURST',
      'LOCK',
      'CACHE',
      'PROT',
      'QOS',
    ]) {
      ro.port('AR$f') <= a.port('AR$f');
    }
    ro.arValid <= a.arValid;
    a.arReady <= ro.arReady;
    a.rValid <= ro.rValid;
    a.rId <= ro.rId;
    a.rData <= ro.rData;
    a.rResp <= ro.rResp;
    a.rLast <= ro.rLast;
    ro.rReady <= a.rReady;
    return a;
  }

  static Logic _fullSize(int dataW) =>
      Const((dataW ~/ 8).bitLength - 1, width: Axi4Interface.sizeWidth);

  // Serves the AXI4-Lite slave [l] for a slave path, and drives the
  // handshakes and responses on [s]. Returns the AR and W pending flags for
  // the guard.
  static (Logic, Logic) _litePath(
    Logic c,
    Logic r, {
    required String p,
    required Axi4Interface s,
    required Axi4LiteInterface l,
    required _Req aw,
    required Logic awSid,
    required _Req ar,
    required Logic arSid,
    required _WBeat w,
    required Logic awReady,
    required Logic arReady,
    required Logic wReady,
    required Logic dead,
    required int k,
    required List<int> restWidths,
    required Logic Function(Logic) slaveAddr,
  }) {
    const lenW = Axi4Interface.lenWidth;
    const protW = Axi4Interface.protWidth;
    const sizeW = Axi4Interface.sizeWidth;
    final nb = s.dataWidth ~/ 8;
    final nbLog = nb.bitLength - 1;
    final full = _fullSize(s.dataWidth);
    // A SIZE above the bus width counts as the bus width.
    Logic sizeOf(Logic sz) => mux(sz.gt(full), full, sz);
    final slvErr = _resp(Axi4RespField.slvErr);
    Logic entry(_Req x, Logic sid) {
      final [addr, len, sz0, burst, _, _, prot, _] = harborUnpack(
        x.rest,
        restWidths,
      );
      final sz = sizeOf(sz0);
      // A burst reaches the slave as single beats. WRAP takes 2, 4, 8 or
      // 16 beats, and the reserved burst type is an error.
      final isWrap = burst.eq(Const(2, width: 2));
      final wrapOk =
          len[0] & (len & (len + 1)).eq(0) & len.getRange(4, lenW).eq(0);
      var badBurst = burst.eq(Const(3, width: 2)) | (isWrap & ~wrapOk);
      if (k < 12) {
        // A region under 4 KB has no bits above it to carry into, so a
        // burst that leaves it is an error.
        final w = max(k + 1, lenW + nbLog) + 2;
        final low = addr.getRange(0, k).zeroExtend(w);
        final aligned = low & ~((Const(1, width: w) << sz) - 1);
        final end = aligned + (len.zeroExtend(w) << sz);
        final window = (len.zeroExtend(w) + 1) << sz;
        final leaves =
            (burst.eq(Const(1, width: 2)) & end.getRange(k, w).neq(0)) |
            (isWrap & window.getRange(k + 1, w).neq(0));
        badBurst = badBurst | (len.neq(0) & leaves);
      }
      return harborPack([
        sid,
        addr.getRange(0, k),
        len,
        sz,
        burst,
        badBurst,
        prot,
      ]);
    }

    // AW and AR share one entry. The outstanding limit lets a request in
    // only when nothing is in flight, and then the preferRead turn lets only
    // one of AW and AR fire in that cycle.
    _checkInSim(c, r, aw.valid & ar.valid, '$p: AW and AR in one cycle');
    final done = Logic(name: '${p}_lite_done');
    final req = HarborRegFifo(
      name: '${p}_req',
      clk: c,
      reset: r,
      depth: 1,
      pushValid: (aw.valid | ar.valid) & ~dead,
      pushData: harborPack([
        mux(aw.valid, entry(aw, awSid), entry(ar, arSid)),
        aw.valid,
      ]),
      popReady: done,
      resetEntries: true,
    );
    awReady <= req.pushReady | dead;
    arReady <= req.pushReady | dead;
    final [id, low, len, sz, burst, bad, prot, isW] = harborUnpack(
      req.popData,
      [s.idWidth, k, lenW, sizeW, Axi4Interface.burstWidth, 1, protW, 1],
    );
    // A cut off slave never sees a request it was not shown.
    final held = cutValid('${p}_req', c, r, req.popValid, done, dead);

    final wValid = Logic(name: '${p}_w_pop');
    final wF = HarborRegFifo(
      name: '${p}_w',
      clk: c,
      reset: r,
      depth: 1,
      pushValid: w.valid & ~dead,
      pushData: w.data,
      popReady: s.wReady & wValid,
      resetEntries: true,
    );
    wValid <= cutValid('${p}_w', c, r, wF.popValid, s.wReady, dead);
    final [wData, wStrb, wLast] = harborUnpack(wF.popData, [
      s.dataWidth,
      s.dataWidth ~/ 8,
      1,
    ]);
    wReady <= wF.pushReady | dead;

    final aSent = Logic(name: '${p}_lite_a_sent');
    final wSent = Logic(name: '${p}_lite_w_sent');
    final beat = Logic(name: '${p}_lite_beat', width: lenW);
    // A burst never crosses 4 KB, so only the low 12 address bits change.
    final kk = min(k, 12);
    final cur = Logic(name: '${p}_lite_cur', width: kk);
    final worst = Logic(name: '${p}_lite_worst', width: 2);
    final lastBeat = beat.eq(len);
    final hereLow = mux(beat.eq(0), low.getRange(0, kk), cur);
    final here = k > kk ? [low.getRange(kk, k), hereLow].concat() : hereLow;
    final good = held & ~bad;
    final addr = slaveAddr(here);
    l.awValid <= good & isW & ~aSent;
    l.awAddr <= addr;
    l.awProt <= prot;
    l.arValid <= good & ~isW & ~aSent;
    l.arAddr <= addr;
    l.arProt <= prot;
    l.wValid <= good & isW & ~wSent & wValid;
    l.wData <= wData;
    l.wStrb <= wStrb & _laneMask(here, sz, nb);

    s.awValid <= held & isW;
    s.arValid <= held & ~isW;
    s.wValid <= wValid;
    s.wLast <= wLast;
    s.wReady <= held & isW & ~wSent & (bad | l.wReady);
    s.bValid <= held & isW & mux(bad, wSent, l.bValid & lastBeat);
    s.bId <= id;
    s.bResp <= mux(bad, slvErr, mux(worst.gt(l.bResp), worst, l.bResp));
    l.bReady <= good & isW & (s.bReady | ~lastBeat);
    s.rValid <= held & ~isW & (bad | l.rValid);
    s.rId <= id;
    s.rData <= mux(bad, Const(0, width: s.dataWidth), l.rData);
    s.rResp <= mux(bad, slvErr, l.rResp);
    s.rLast <= lastBeat;
    l.rReady <= good & ~isW & s.rReady;
    final bFire = s.bValid & s.bReady;
    final rFire = s.rValid & s.rReady;
    done <= bFire | (rFire & s.rLast);
    // The entry leaves when its response ends, so the guard sees the AW or
    // AR handshake then.
    s.awReady <= bFire;
    s.arReady <= rFire & s.rLast;

    // A good request moves on when the slave answers one beat. A bad
    // request has no slave beats and only counts the R beats it returns.
    final lBeat = good & isW & l.bValid & l.bReady;
    final step = rFire | lBeat;
    final clear = done | step;
    final wFire = s.wValid & s.wReady;

    // Next address: FIXED keeps it, INCR adds one word to the aligned
    // address, and WRAP wraps inside the window of len + 1 words.
    Logic next = hereLow;
    if (kk > 0) {
      final sizeMask = (Const(1, width: kk) << sz) - 1;
      final aligned = hereLow & ~sizeMask;
      final inc = aligned + (Const(1, width: kk) << sz);
      final winW = max(kk, lenW + nbLog);
      final win = (len.zeroExtend(winW) << sz) | sizeMask.zeroExtend(winW);
      final mask = win.getRange(0, kk);
      final wrap = (aligned & ~mask) | (inc & mask);
      next = mux(
        burst.eq(Const(2, width: 2)),
        wrap,
        mux(burst.eq(Const(1, width: 2)), inc, hereLow),
      );
    }

    // The flags and counters have no flop enable, so they share the common
    // control set. cur loads only when a beat ends.
    Sequential(c, reset: r, [
      aSent <
          ~clear & (aSent | (l.awValid & l.awReady) | (l.arValid & l.arReady)),
      wSent < ~clear & (wSent | mux(bad, wFire & s.wLast, l.wValid & l.wReady)),
      beat < (beat + step.zeroExtend(lenW)) & ~done.replicate(lenW),
      cur < mux(step, next, cur),
      worst <
          ~done.replicate(2) & mux(lBeat & l.bResp.gt(worst), l.bResp, worst),
    ]);
    return (req.popValid & ~isW, wF.popValid);
  }

  // [_litePath] at the balanced and fast levels. The request waits in a one
  // entry register, its burst checks and address steps go to registers in
  // the two cycles after it arrives, and B leaves through a one entry
  // register and R through a 2 entry FIFO. So the response arbiter does not reach the beat counter, and the
  // next address comes from registers only.
  static (Logic, Logic) _litePathStaged(
    Logic c,
    Logic r, {
    required String p,
    required Axi4Interface s,
    required Axi4LiteInterface l,
    required _Req aw,
    required Logic awSid,
    required _Req ar,
    required Logic arSid,
    required _WBeat w,
    required Logic awReady,
    required Logic arReady,
    required Logic wReady,
    required Logic dead,
    required int k,
    required List<int> restWidths,
    required Logic Function(Logic) slaveAddr,
  }) {
    const lenW = Axi4Interface.lenWidth;
    const protW = Axi4Interface.protWidth;
    const sizeW = Axi4Interface.sizeWidth;
    const burstW = Axi4Interface.burstWidth;
    final nb = s.dataWidth ~/ 8;
    final nbLog = nb.bitLength - 1;
    final slvErr = _resp(Axi4RespField.slvErr);
    final kk = min(k, 12);
    Logic fields(_Req x, Logic sid) {
      final [addr, len, sz, burst, _, _, prot, _] = harborUnpack(
        x.rest,
        restWidths,
      );
      return harborPack([sid, addr.getRange(0, k), len, sz, burst, prot]);
    }

    _checkInSim(c, r, aw.valid & ar.valid, '$p: AW and AR in one cycle');
    final entryW = s.idWidth + k + lenW + sizeW + burstW + protW + 1;
    final valid = Logic(name: '${p}_req_valid');
    final entry = Logic(name: '${p}_req_entry', width: entryW);
    final done = Logic(name: '${p}_lite_done');
    final push = (aw.valid | ar.valid) & ~dead;
    _checkInSim(c, r, push & valid, '$p: a request while one is held');
    awReady <= ~valid | dead;
    arReady <= ~valid | dead;
    Sequential(c, reset: r, [
      valid < push | (valid & ~done),
      entry <
          harborLoad(
            entry,
            push,
            harborPack([
              mux(aw.valid, fields(aw, awSid), fields(ar, arSid)),
              aw.valid,
            ]),
          ),
    ]);
    final [id, low, len, sz0, burst, prot, isW] = harborUnpack(entry, [
      s.idWidth,
      k,
      lenW,
      sizeW,
      burstW,
      protW,
      1,
    ]);
    final held = cutValid('${p}_req', c, r, valid, done, dead);

    // Two cycles of checks after the request arrives. A SIZE above the bus
    // width counts as the bus width.
    final staged = Logic(name: '${p}_lite_staged', width: 2);
    final ready = staged[1];
    final w0 = max(kk + 1, lenW + nbLog) + 2;
    final full = _fullSize(s.dataWidth);
    final szc = mux(sz0.gt(full), full, sz0);
    final low0 = [
      for (var b = 0; b < w0; b++)
        b < nbLog ? sz0.gt(Const(b, width: sizeW)) : Const(0),
    ];
    final szMask = Logic(name: '${p}_lite_size_mask', width: low0.length);
    final szStep = Logic(name: '${p}_lite_size_step', width: low0.length);
    final sz = Logic(name: '${p}_lite_size', width: sizeW);
    final wrapOk = Logic(name: '${p}_lite_wrap_ok');
    final winMask = Logic(name: '${p}_lite_win', width: max(kk, 1));
    final bad = Logic(name: '${p}_lite_bad');
    final isWrap = burst.eq(Const(2, width: burstW));
    final isIncr = burst.eq(Const(1, width: burstW));
    Logic shifted(Logic x) => (x.zeroExtend(w0) << sz).getRange(0, w0);
    final aligned = low.getRange(0, min(k, w0)).zeroExtend(w0) & ~szMask;
    final end = aligned + shifted(len);
    final window = shifted(len.zeroExtend(lenW + 1) + 1);
    var badB = burst.eq(Const(3, width: burstW)) | (isWrap & ~wrapOk);
    if (k < 12) {
      // A region under 4 KB has no bits above it to carry into, so a burst
      // that leaves it is an error.
      final leaves =
          (isIncr & end.getRange(k, w0).neq(0)) |
          (isWrap & window.getRange(k + 1, w0).neq(0));
      badB = badB | (len.neq(0) & leaves);
    }
    Sequential(c, reset: r, [
      staged <
          mux(
            valid & ~done,
            [Const(1), staged[0]].rconcat(),
            Const(0, width: 2),
          ),
      sz < szc,
      szMask < low0.rconcat(),
      szStep <
          [
            for (var b = 0; b < w0; b++)
              b <= nbLog
                  ? (sz0.eq(Const(b, width: sizeW)) |
                        (b == nbLog ? sz0.gt(full) : Const(0)))
                  : Const(0),
          ].rconcat(),
      wrapOk < len[0] & (len & (len + 1)).eq(0) & len.getRange(4, lenW).eq(0),
      winMask <
          (kk > 0
              ? ((len.zeroExtend(w0) << szc).getRange(0, kk) |
                    low0.rconcat().getRange(0, kk))
              : Const(0)),
      bad < badB,
    ]);

    final wValid = Logic(name: '${p}_w_pop');
    final wF = HarborRegFifo(
      name: '${p}_w',
      clk: c,
      reset: r,
      depth: 1,
      pushValid: w.valid & ~dead,
      pushData: w.data,
      popReady: s.wReady & wValid,
      resetEntries: true,
    );
    wValid <= cutValid('${p}_w', c, r, wF.popValid, s.wReady, dead);
    final [wData, wStrb, wLast] = harborUnpack(wF.popData, [
      s.dataWidth,
      s.dataWidth ~/ 8,
      1,
    ]);
    wReady <= wF.pushReady | dead;

    final aSent = Logic(name: '${p}_lite_a_sent');
    final wSent = Logic(name: '${p}_lite_w_sent');
    final beat = Logic(name: '${p}_lite_beat', width: lenW);
    final cur = Logic(name: '${p}_lite_cur', width: max(kk, 1));
    final worst = Logic(name: '${p}_lite_worst', width: 2);
    final lastBeat = beat.eq(len);
    final hereLow = kk > 0 ? cur : low.getRange(0, 0);
    final here = k > kk ? [low.getRange(kk, k), hereLow].concat() : hereLow;
    final live = held & ready;
    final good = live & ~bad;
    final addr = slaveAddr(here);
    l.awValid <= good & isW & ~aSent;
    l.awAddr <= addr;
    l.awProt <= prot;
    l.arValid <= good & ~isW & ~aSent;
    l.arAddr <= addr;
    l.arProt <= prot;
    l.wValid <= good & isW & ~wSent & wValid;
    l.wData <= wData;
    l.wStrb <= wStrb & _laneMask(here, sz, nb);

    s.awValid <= held & isW;
    s.arValid <= held & ~isW;
    s.wValid <= wValid;
    s.wLast <= wLast;
    s.wReady <= live & isW & ~wSent & (bad | l.wReady);

    // B: one entry, as the slave has one request in flight.
    final bHeld = Logic(name: '${p}_lite_b_valid');
    final bData = Logic(
      name: '${p}_lite_b_data',
      width: s.idWidth + Axi4Interface.respWidth,
    );
    final bPush = (live & isW & mux(bad, wSent, l.bValid & lastBeat) & ~bHeld)
        .named('${p}_lite_b_push');
    Sequential(c, reset: r, [
      bHeld < bPush | (bHeld & ~s.bReady),
      bData <
          harborLoad(
            bData,
            bPush,
            harborPack([
              id,
              mux(bad, slvErr, mux(worst.gt(l.bResp), worst, l.bResp)),
            ]),
          ),
    ]);
    final [bId, bResp] = harborUnpack(bData, [
      s.idWidth,
      Axi4Interface.respWidth,
    ]);
    s.bValid <= bHeld;
    s.bId <= bId;
    s.bResp <= bResp;
    l.bReady <= good & isW & (~bHeld | ~lastBeat);
    final rF = HarborRegFifo(
      name: '${p}_lite_r',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: live & ~isW & (bad | l.rValid),
      pushData: harborPack([
        id,
        mux(bad, Const(0, width: s.dataWidth), l.rData),
        mux(bad, slvErr, l.rResp),
        lastBeat,
      ]),
      popReady: s.rReady,
      resetEntries: true,
    );
    final [rId, rData, rResp, rLast] = harborUnpack(rF.popData, [
      s.idWidth,
      s.dataWidth,
      Axi4Interface.respWidth,
      1,
    ]);
    s.rValid <= rF.popValid;
    s.rId <= rId;
    s.rData <= rData;
    s.rResp <= rResp;
    s.rLast <= rLast;
    l.rReady <= good & ~isW & rF.pushReady;
    final bFire = bPush;
    final rFire = rF.pushFire;
    done <= bFire | (rFire & lastBeat);
    // The entry leaves when its response is queued, so the guard sees the
    // AW or AR handshake then.
    s.awReady <= bFire;
    s.arReady <= rFire & lastBeat;

    final lBeat = good & isW & l.bValid & l.bReady;
    final step = rFire | lBeat;
    final clear = done | step;
    final wFire = s.wValid & s.wReady;

    // Next address: FIXED keeps it, INCR adds one word to the aligned
    // address, and WRAP wraps inside the window of len + 1 words.
    Logic next = hereLow;
    if (kk > 0) {
      final al = cur & ~szMask.getRange(0, kk);
      final inc = al + szStep.getRange(0, kk);
      final wrap = (al & ~winMask) | (inc & winMask);
      next = harborLoad(harborLoad(cur, isIncr, inc), isWrap, wrap);
    }

    Sequential(c, reset: r, [
      aSent <
          ~clear & (aSent | (l.awValid & l.awReady) | (l.arValid & l.arReady)),
      wSent < ~clear & (wSent | mux(bad, wFire & s.wLast, l.wValid & l.wReady)),
      beat < (beat + step.zeroExtend(lenW)) & ~done.replicate(lenW),
      if (kk > 0)
        cur <
            harborLoad(
              harborLoad(cur, step, next),
              ~staged[0],
              low.getRange(0, kk),
            ),
      worst <
          ~done.replicate(2) & mux(lBeat & l.bResp.gt(worst), l.bResp, worst),
    ]);
    return (valid & ~isW, wF.popValid);
  }

  // Byte lanes that an access of 2^[sz] bytes at the byte address [a] covers
  // on a bus of [nb] bytes. [a] has at least log2([nb]) bits, or fewer when
  // a region is smaller than a word.
  static Logic _laneMask(Logic a, Logic sz, int nb) {
    final nbLog = nb.bitLength - 1;
    if (nbLog == 0) return Const(1);
    final addr = a.width < nbLog ? a.zeroExtend(nbLog) : a.getRange(0, nbLog);
    Logic bySize(int s) => [
      for (var i = nb - 1; i >= 0; i--)
        s == nbLog
            ? Const(1)
            : addr.getRange(s, nbLog).eq(Const(i >> s, width: nbLog - s)),
    ].concat();
    var mask = bySize(nbLog);
    for (var s = nbLog - 1; s >= 0; s--) {
      mask = mux(sz.eq(Const(s, width: sz.width)), bySize(s), mask);
    }
    return mask;
  }

  // Stops the simulation when [bad] is high at a [clk] edge out of reset.
  // The generated RTL does not use [bad].
  static void _checkInSim(Logic clk, Logic reset, Logic bad, String what) {
    clk.glitch.listen((args) {
      if (LogicValue.isPosedge(
            args.previousValue,
            args.newValue,
            ignoreInvalid: true,
          ) &&
          reset.value == LogicValue.zero &&
          bad.value == LogicValue.one) {
        Simulator.throwException(
          Exception('AXI4 fabric: $what'),
          StackTrace.current,
        );
      }
    });
  }

  // Bits below which the addresses of [range] differ. The bits above are
  // the same for every address in it.
  static int _regionBits(BusAddressRange range, int addrW) {
    final first = BigInt.from(range.start);
    final last = first + BigInt.from(range.size) - BigInt.one;
    return min(addrW, max(1, (first ^ last).bitLength));
  }

  // The address a slave sees for an address in [range] with low bits [low]:
  // the full address, or the offset from the start of [range] when
  // [offset] is set.
  static Logic _slaveAddr(
    Logic low,
    BusAddressRange range,
    bool offset,
    int addrW,
  ) {
    final k = low.width;
    final start = BigInt.from(range.start);
    if (offset) {
      final startLow = start & ((BigInt.one << k) - BigInt.one);
      final off = startLow == BigInt.zero
          ? low
          : low - Const(startLow, width: k);
      return off.zeroExtend(addrW);
    }
    if (k >= addrW) return low;
    return [Const(start >> k, width: addrW - k), low].concat();
  }

  // Names the widths of a slave that the fabric adapts, and nothing for a
  // slave of the fabric widths.
  static String _widthTag(HarborFabricSlave s, int addrW, int dataW) {
    final (a, d, _) = _shape(s.interface);
    return a == addrW && d == dataW ? '' : 'W${a}x$d';
  }

  static const _restFields = [
    'ADDR',
    'LEN',
    'SIZE',
    'BURST',
    'LOCK',
    'CACHE',
    'PROT',
    'QOS',
  ];

  static List<int> _restWidths(int addrW) => [
    addrW,
    Axi4Interface.lenWidth,
    Axi4Interface.sizeWidth,
    Axi4Interface.burstWidth,
    1,
    Axi4Interface.cacheWidth,
    Axi4Interface.protWidth,
    Axi4Interface.qosWidth,
  ];

  static String _definitionName(
    HarborFabricTopology topology,
    List<HarborFabricMaster> masters,
    List<HarborFabricSlave> slaves,
    int realtimeBurstCap,
    HarborFabricPipeline pipeline,
  ) {
    if (masters.isEmpty) {
      throw ArgumentError.value(masters, 'masters', 'must not be empty');
    }
    final (addrW, dataW, _) = _shape(masters.first.interface);
    String id(PairInterface p) => switch (_shape(p).$3) {
      null => 'L',
      final w => 'i$w',
    };
    return harborStableDefinitionName('HarborAxi4Fabric', [
      topology.name,
      if (pipeline != HarborFabricPipeline.compact) pipeline.name,
      'a$addrW',
      'd$dataW',
      if (masters.any((m) => m.realtime)) 'q$realtimeBurstCap',
      for (final m in masters)
        'M${m.name}${id(m.interface)}'
            'o${m.outstandingOn(HarborFabricKind.axi4)}${m.reachTag(slaves)}'
            '${m.readChannel != null ? 'rc${m.readChannel}' : ''}'
            '${m.realtime ? 'Q' : ''}',
      for (final s in slaves)
        'S${s.name}${id(s.interface)}n${s.outstanding}'
            '${_widthTag(s, addrW, dataW)}${s.offset ? 'O' : ''}'
            't${s.timeout}r${s.range.start.toRadixString(16)}'
            'x${s.range.size.toRadixString(16)}'
            '${s.readChannels > 1 ? 'c${s.readChannels}' : ''}',
    ]);
  }
}
