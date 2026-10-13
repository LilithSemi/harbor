import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' show Axi4RespField;

import '../../arith/fpu_config.dart' show harborStableDefinitionName;
import '../fabric.dart';
import '../fabric_util.dart';
import '../port/fabric_kind.dart';
import '../port/reg_fifo.dart';
import 'axi4_interface.dart';
import 'axi4_lite_interface.dart';

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
  final List<Logic> fid;
  final List<Logic> cnt;
  final int slotWidth;
  final int slaveIdWidth;

  _Remap(String name, int fullIdWidth, this.slaveIdWidth, int outstanding)
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
        If(issue & slot[i], then: [fid[i] < f]),
      ],
    ]);
  }
}

// Requests a master has in flight in one direction, grouped by ID. Each
// group keeps the target its requests went to.
class _Tracker {
  final Logic ok;

  _Tracker._(this.ok);

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
    final ok =
        mux(hasMatch, pick(match, tgts).eq(target), anyOf(free)) &
        total.lt(Const(outstanding, width: cw));
    final doneMatch = [
      for (var i = 0; i < k; i++) valid[i] & ids[i].eq(doneId),
    ];
    Sequential(clk, reset: reset, [
      total < total + issue.zeroExtend(cw) - done.zeroExtend(cw),
      for (var i = 0; i < k; i++) ...[
        cnt[i] <
            cnt[i] +
                (issue & mux(hasMatch, match[i], free[i])).zeroExtend(cw) -
                (done & doneMatch[i]).zeroExtend(cw),
        If(issue & ~hasMatch & free[i], then: [ids[i] < id, tgts[i] < target]),
      ],
    ]);
    return _Tracker._(ok.named('${name}_ok'));
  }
}

/// An AXI4 fabric. Build it with [HarborFabric.build].
///
/// - Each master port takes AW, AR and W into 2 entry FIFOs, and each slave
///   port drives AW, AR and W from 2 entry FIFOs. B and R reach a master
///   through 2 entry FIFOs.
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
///   ID. Its `outstanding` must be 1. A burst or a narrow access to it gets SLVERR on every beat.
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

  HarborAxi4Fabric({
    required this.topology,
    required Logic clk,
    required Logic reset,
    required this.masters,
    required this.slaves,
    super.name = 'fabric',
  }) : super(definitionName: _definitionName(topology, masters, slaves)) {
    final (addrW, dataW, _) = _shape(masters.first.interface);
    for (final p in [
      for (final m in masters) (m.name, m.interface),
      for (final s in slaves) (s.name, s.interface),
    ]) {
      final (a, d, _) = _shape(p.$2);
      if (a != addrW || d != dataW) {
        throw ArgumentError(
          '${p.$1}: AXI4 widths (addr $a, data $d) differ from addr '
          '$addrW, data $dataW',
        );
      }
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

    final c = addInput('clk', clk);
    final r = addInput('reset', reset);
    addOutput('bus_error');

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
    fullIdWidth = maxId + pW;
    final tW = indexWidth(nt);
    final mW = indexWidth(nm);

    // The read channel each master uses at each slave, by master index.
    final chanOf = [
      for (final s in slaves) HarborFabric.readChannelsOf(s, masters),
    ];

    final ma = [for (final m in masters) _masterPort(m)];
    final sa = <Axi4Interface>[];
    for (final s in slaves) {
      sa.add(_slavePort(c, r, s));
      for (var k = 1; k < s.readChannels; k++) {
        sa.add(_slaveReadPort(s, k));
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
    final tN = [for (final s in tSlave) slaves[s].outstanding, errorOutstanding];
    final tRemap = [for (var t = 0; t < nt; t++) tIdW[t] < fullIdWidth];

    const restFields = [
      'ADDR',
      'LEN',
      'SIZE',
      'BURST',
      'LOCK',
      'CACHE',
      'PROT',
      'QOS',
    ];
    final restWidths = [
      addrW,
      Axi4Interface.lenWidth,
      Axi4Interface.sizeWidth,
      Axi4Interface.burstWidth,
      1,
      Axi4Interface.cacheWidth,
      Axi4Interface.protWidth,
      Axi4Interface.qosWidth,
    ];
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
    final mFull = <List<Logic>>[];
    final mRest = <List<Logic>>[];
    final mTgt = <List<List<Logic>>>[];
    final mTgtIdx = <List<Logic>>[];
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
        final f = HarborRegFifo(
          name: '${mn}_${d.toLowerCase()}',
          clk: c,
          reset: r,
          depth: 2,
          pushValid: a.port('${d}VALID'),
          pushData: harborPack([
            a.port('${d}ID'),
            for (final x in restFields) a.port('$d$x'),
          ]),
          popReady: mPop[m][dir],
        );
        a.port('${d}READY') <= f.pushReady;
        final [hid, rest] = harborUnpack(f.popData, [a.idWidth, restW]);
        final addr = rest.getRange(0, addrW);
        final hits = [
          for (final s in slaves)
            masters[m].reaches(s.name) ? inRange(addr, s.range) : Const(0),
        ];
        // AW always targets channel 0. AR targets this master's assigned
        // channel at the slave it hits.
        final tgt = <Logic>[];
        for (var s = 0; s < ns; s++) {
          final chan = dir == 0 ? 0 : max(0, chanOf[s][m]);
          for (var k = 0; k < chCount[s]; k++) {
            tgt.add(k == chan ? hits[s] : Const(0));
          }
        }
        tgt.add(~anyOf(hits));
        final tgtIdx = indexOf(tgt, tW);
        final full = pW > 0
            ? [Const(m, width: pW), hid.zeroExtend(maxId)].swizzle()
            : hid.zeroExtend(maxId);
        final ok = _Tracker(
          '${mn}_${d.toLowerCase()}_order',
          c,
          r,
          outstanding: masters[m].outstandingOn(HarborFabricKind.axi4),
          id: hid,
          target: tgtIdx,
          issue: mPop[m][dir],
          done: mDone[m][dir],
          doneId: mDoneId[m][dir],
        ).ok;
        mFull[m].add(full);
        mRest[m].add(rest);
        mTgt[m].add(tgt);
        mTgtIdx[m].add(tgtIdx);
        req[m].add([
          for (var t = 0; t < nt; t++)
            f.popValid &
                ok &
                tgt[t] &
                inReady[t][dir] &
                (tRemap[t] ? remap[t]![dir].ok(full) : Const(1)),
        ]);
      }
    }

    // Outstanding limit per target, reads and writes together. When one
    // slot is left and both directions want it, they take turns.
    final outOk = <List<Logic>>[];
    final tFire = [
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
      outOk.add([
        ~full & ~(lastOne & arWant & preferRead),
        ~full & ~(lastOne & awWant & ~preferRead),
      ]);
      Sequential(c, reset: r, [
        cnt <
            cnt +
                tFire[t][0].zeroExtend(cw) +
                tFire[t][1].zeroExtend(cw) -
                bDone[t].zeroExtend(cw) -
                rDone[t].zeroExtend(cw),
        If(lastOne & awWant & arWant, then: [preferRead < ~preferRead]),
      ]);
    }

    // Arbitration. Each target gets a request with its full ID and the
    // master it came from.
    final tReq = [for (var t = 0; t < nt; t++) <_Req>[]];
    final tMaster = [for (var t = 0; t < nt; t++) <Logic>[]];
    final awBusTarget = <Logic>[];
    final awBusMaster = <Logic>[];
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
          final g = roundRobin('${tName[t]}_$d', c, r, [
            for (var m = 0; m < nm; m++) gated[m][t],
          ]);
          grants.add(g);
          tFire[t][dir] <= anyOf(g);
          tReq[t].add(_Req(tFire[t][dir], pick(g, full), pick(g, rest)));
          tMaster[t].add(indexOf(g, mW));
        }
        for (var m = 0; m < nm; m++) {
          mPop[m][dir] <= anyOf([for (var t = 0; t < nt; t++) grants[t][m]]);
        }
      } else {
        final g = roundRobin('bus_$d', c, r, [
          for (var m = 0; m < nm; m++) anyOf(gated[m]),
        ]);
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
          mPop[m][dir] <= g[m];
        }
        if (dir == 0) {
          awBusTarget.add(
            pick(g, [for (var m = 0; m < nm; m++) mTgtIdx[m][0]]),
          );
          awBusMaster.add(busMaster);
        }
      }
    }

    // ID remap at each target.
    final tSid = [
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

    // Write data. A master's beats go to the targets of its AWs in order,
    // and a target takes beats from the masters of its AWs in order.
    final wReady = [for (var t = 0; t < nt; t++) Logic()];
    final wPop = [for (var m = 0; m < nm; m++) Logic()];
    final wHead = <HarborRegFifo>[];
    for (var m = 0; m < nm; m++) {
      final a = ma[m];
      final f = HarborRegFifo(
        name: '${masters[m].name}_w',
        clk: c,
        reset: r,
        depth: 2,
        pushValid: a.wValid,
        pushData: harborPack([a.wData, a.wStrb, a.wLast]),
        popReady: wPop[m],
      );
      a.wReady <= f.pushReady;
      wHead.add(f);
    }
    final wData = [for (final f in wHead) f.popData];
    final wLast = [for (final f in wHead) f.popData[-1]];
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
            pushValid: mPop[m][0],
            pushData: mTgtIdx[m][0],
            popReady: wPop[m] & wLast[m],
          ),
      ];
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
              wHead[m].popValid &
                  routes[m].popValid &
                  routes[m].popData.eq(Const(t, width: tW)) &
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
        pushValid: anyOf([for (var m = 0; m < nm; m++) mPop[m][0]]),
        pushData: harborPack([awBusMaster.first, awBusTarget.first]),
        popReady: orderPop,
      );
      final [mh, th] = harborUnpack(order.popData, [mW, tW]);
      final mOh = decodeIndex(mh, nm);
      final tOh = decodeIndex(th, nt);
      final xfer =
          (order.popValid &
                  pick(mOh, [for (final f in wHead) f.popValid]) &
                  pick(tOh, wReady))
              .named('bus_w_xfer');
      final data = pick(mOh, wData);
      final last = pick(mOh, wLast);
      orderPop <= xfer & last;
      for (var m = 0; m < nm; m++) {
        wPop[m] <= xfer & mOh[m];
      }
      for (var t = 0; t < nt; t++) {
        tBeat.add(_WBeat(xfer & tOh[t], data, last));
      }
    }

    // Slave paths and the error slave.
    final dead = <Logic>[];
    for (var t = 0; t < nst; t++) {
      final x = _slavePath(
        c,
        r,
        p: tName[t],
        s: sa[t],
        outstanding: tN[t],
        timeout: slaves[tSlave[t]].timeout,
        aw: tReq[t][0],
        awSid: tSid[t][0],
        ar: tReq[t][1],
        arSid: tSid[t][1],
        w: tBeat[t],
        awReady: inReady[t][0],
        arReady: inReady[t][1],
        wReady: wReady[t],
        b: bResp[t],
        rd: rResp[t],
        addrW: addrW,
        base: slaves[tSlave[t]].base,
      );
      if (x != null) dead.add(x);
    }
    _errorSlave(
      c,
      r,
      aw: tReq[nst][0],
      awSid: tSid[nst][0],
      ar: tReq[nst][1],
      arSid: tSid[nst][1],
      w: tBeat[nst],
      awReady: inReady[nst][0],
      arReady: inReady[nst][1],
      wReady: wReady[nst],
      b: bResp[nst],
      rd: rResp[nst],
      addrW: addrW,
      dataW: dataW,
    );
    output('bus_error') <= anyOf(dead);

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
      final push = [for (var m = 0; m < nm; m++) Logic()];
      final pushData = <Logic>[];
      final outs = <HarborRegFifo>[];
      final items = <List<Logic>>[];
      for (var m = 0; m < nm; m++) {
        final a = ma[m];
        items.add([
          for (var t = 0; t < nt; t++)
            harborPack([
              mids[t].getRange(0, a.idWidth),
              resp[t].payload,
              if (dir == 1) resp[t].last,
            ]),
        ]);
        final data = Logic(width: items[m].first.width);
        pushData.add(data);
        final ready = dir == 0 ? a.bReady : a.rReady;
        final f = HarborRegFifo(
          name: '${masters[m].name}_$d',
          clk: c,
          reset: r,
          depth: 2,
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
      if (topology == HarborFabricTopology.crossbar) {
        final grants = <List<Logic>>[];
        for (var m = 0; m < nm; m++) {
          final g = roundRobin('${masters[m].name}_${d}_resp', c, r, [
            for (var t = 0; t < nt; t++)
              resp[t].valid & dest[t][m] & outs[m].pushReady,
          ]);
          grants.add(g);
          push[m] <= anyOf(g);
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
          push[m] <= anyOf([for (var t = 0; t < nt; t++) g[t] & dest[t][m]]);
          pushData[m] <= pick(g, items[m]);
        }
        for (var t = 0; t < nt; t++) {
          resp[t].ready <= g[t];
        }
      }
    }
  }

  // AW, AR and W FIFOs to one slave, and the timeout guard when the slave
  // has a timeout. Returns the guard's cut off flag.
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
    required int base,
  }) {
    final guard = timeout > 0;
    final dead = guard ? Logic(name: '${p}_cut_off') : Const(0);
    final reqWidths = [
      s.idWidth,
      addrW,
      Axi4Interface.lenWidth,
      Axi4Interface.sizeWidth,
      Axi4Interface.burstWidth,
      1,
      Axi4Interface.cacheWidth,
      Axi4Interface.protWidth,
      Axi4Interface.qosWidth,
    ];
    const reqFields = [
      'ID',
      'ADDR',
      'LEN',
      'SIZE',
      'BURST',
      'LOCK',
      'CACHE',
      'PROT',
      'QOS',
    ];
    final fifos = <HarborRegFifo>[];
    for (final (d, x, sid, ready) in [
      ('AW', aw, awSid, awReady),
      ('AR', ar, arSid, arReady),
    ]) {
      final valid = Logic(name: '${p}_${d.toLowerCase()}_pop');
      final f = HarborRegFifo(
        name: '${p}_${d.toLowerCase()}',
        clk: c,
        reset: r,
        depth: 2,
        pushValid: x.valid & ~dead,
        pushData: harborPack([sid, x.rest]),
        popReady: s.port('${d}READY') & valid,
        resetEntries: true,
      );
      final fields = harborUnpack(f.popData, reqWidths);
      for (var i = 0; i < reqFields.length; i++) {
        s.port('$d${reqFields[i]}') <=
            (reqFields[i] == 'ADDR' && base != 0
                ? fields[i] - Const(base, width: addrW)
                : fields[i]);
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
    b.valid <= mux(dead, anyOf(bCand), s.bValid);
    b.id <= mux(dead, pick(bPick, gid), s.bId);
    b.payload <= mux(dead, slvErr, s.bResp);
    b.last <= Const(1);
    s.bReady <= dead | b.ready;
    final bDoneOh = [
      for (var i = 0; i < n; i++) b.fire & mux(dead, bPick[i], bMatch[i]),
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
    final rSel = [for (var i = 0; i < n; i++) mux(dead, rPick[i], rMatch[i])];
    rd.valid <= mux(dead, anyOf(rCand), s.rValid);
    rd.id <= mux(dead, pick(rPick, gid), s.rId);
    rd.payload <=
        mux(
          dead,
          harborPack([Const(0, width: s.dataWidth), slvErr]),
          harborPack([s.rData, s.rResp]),
        );
    rd.last <= mux(dead, pick(rPick, gbeat).eq(pick(rPick, glen)), s.rLast);
    s.rReady <= dead | rd.ready;
    final rBeatOh = [for (var i = 0; i < n; i++) rd.fire & rSel[i]];
    final rDoneOh = [for (var i = 0; i < n; i++) rBeatOh[i] & rd.last];

    // A new record counts the records of the same ID and direction ahead
    // of it. A record that ends lets the others of its ID move up.
    final awLen = aw.rest.getRange(addrW, addrW + lenW);
    final arLen = ar.rest.getRange(addrW, addrW + lenW);
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
        fifos[1].popValid |
        wF.popValid;
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
    required int addrW,
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
      pushData: harborPack([arSid, ar.rest.getRange(addrW, addrW + lenW)]),
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
      If(rd.fire, then: [beat < mux(rd.last, Const(0, width: lenW), beat + 1)]),
    ]);
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

  // The slave port as AXI4. An AXI4-Lite slave sits behind [_liteSlave].
  Axi4Interface _slavePort(Logic c, Logic r, HarborFabricSlave s) {
    final i = s.interface;
    String uniq(String n) => '${s.name}_$n';
    if (i is Axi4Interface) {
      return i.clone()
        ..pairConnectIO(this, i, PairRole.provider, uniquify: uniq);
    }
    final l = (i as Axi4LiteInterface).clone()
      ..pairConnectIO(this, i, PairRole.provider, uniquify: uniq);
    final a = Axi4Interface(
      addressWidth: l.addressWidth,
      dataWidth: l.dataWidth,
      idWidth: fullIdWidth,
    );
    _liteSlave(c, r, p: s.name, a: a, l: l);
    return a;
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

  // Drives the AXI4-Lite slave [l] from the AXI4 side [a] of a slave path
  // with 1 request in flight. It keeps the ID, and answers a burst or a
  // narrow access with SLVERR on every beat without the slave.
  static void _liteSlave(
    Logic c,
    Logic r, {
    required String p,
    required Axi4Interface a,
    required Axi4LiteInterface l,
  }) {
    const lenW = Axi4Interface.lenWidth;
    final held = Logic(name: '${p}_lite_held');
    final isW = Logic(name: '${p}_lite_write');
    final bad = Logic(name: '${p}_lite_bad');
    final id = Logic(name: '${p}_lite_id', width: a.idWidth);
    final len = Logic(name: '${p}_lite_len', width: lenW);
    final addr = Logic(name: '${p}_lite_addr', width: a.addressWidth);
    final prot = Logic(name: '${p}_lite_prot', width: Axi4Interface.protWidth);
    final aSent = Logic(name: '${p}_lite_a_sent');
    final wSent = Logic(name: '${p}_lite_w_sent');
    final beat = Logic(name: '${p}_lite_beat', width: lenW);
    final size = _fullSize(a.dataWidth);
    final slvErr = _resp(Axi4RespField.slvErr);

    final takeAw = a.awValid & ~held;
    final takeAr = a.arValid & ~held & ~a.awValid;
    a.awReady <= ~held;
    a.arReady <= ~held & ~a.awValid;

    final good = held & ~bad;
    final wr = held & isW;
    final rd = held & ~isW;
    l.awValid <= good & isW & ~aSent;
    l.awAddr <= addr;
    l.awProt <= prot;
    l.arValid <= good & ~isW & ~aSent;
    l.arAddr <= addr;
    l.arProt <= prot;
    l.wValid <= good & isW & ~wSent & a.wValid;
    l.wData <= a.wData;
    l.wStrb <= a.wStrb;
    a.wReady <= wr & ~wSent & (bad | l.wReady);

    a.bValid <= wr & mux(bad, wSent, l.bValid);
    a.bId <= id;
    a.bResp <= mux(bad, slvErr, l.bResp);
    l.bReady <= good & isW & a.bReady;
    a.rValid <= rd & (bad | l.rValid);
    a.rId <= id;
    a.rData <= mux(bad, Const(0, width: a.dataWidth), l.rData);
    a.rResp <= mux(bad, slvErr, l.rResp);
    a.rLast <= ~bad | beat.eq(len);
    l.rReady <= good & ~isW & a.rReady;

    Logic badOf(String d) =>
        a.port('${d}LEN').neq(0) | a.port('${d}SIZE').neq(size);
    final rFire = a.rValid & a.rReady;
    Sequential(c, reset: r, [
      If.block([
        Iff(takeAw | takeAr, [
          held < 1,
          isW < takeAw,
          id < mux(takeAw, a.awId, a.arId),
          len < mux(takeAw, a.awLen, a.arLen),
          addr < mux(takeAw, a.awAddr, a.arAddr),
          prot < mux(takeAw, a.awProt, a.arProt),
          bad < mux(takeAw, badOf('AW'), badOf('AR')),
          aSent < 0,
          wSent < 0,
          beat < 0,
        ]),
        ElseIf((a.bValid & a.bReady) | (rFire & a.rLast), [held < 0]),
        Else([
          If(
            (l.awValid & l.awReady) | (l.arValid & l.arReady),
            then: [aSent < 1],
          ),
          If(a.wValid & a.wReady & a.wLast, then: [wSent < 1]),
          If(rFire, then: [beat < beat + 1]),
        ]),
      ]),
    ]);
  }

  static String _definitionName(
    HarborFabricTopology topology,
    List<HarborFabricMaster> masters,
    List<HarborFabricSlave> slaves,
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
      'a$addrW',
      'd$dataW',
      for (final m in masters)
        'M${m.name}${id(m.interface)}'
            'o${m.outstandingOn(HarborFabricKind.axi4)}${m.reachTag(slaves)}'
            '${m.readChannel != null ? 'rc${m.readChannel}' : ''}',
      for (final s in slaves)
        'S${s.name}${id(s.interface)}n${s.outstanding}'
            '${s.offset ? 'O' : ''}'
            't${s.timeout}r${s.range.start.toRadixString(16)}'
            'x${s.range.size.toRadixString(16)}'
            '${s.readChannels > 1 ? 'c${s.readChannels}' : ''}',
    ]);
  }
}
