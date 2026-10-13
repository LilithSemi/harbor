import 'dart:math';

import 'package:rohd/rohd.dart';

import '../../arith/fpu_config.dart' show harborStableDefinitionName;
import '../fabric.dart';
import '../fabric_util.dart';
import '../port/fabric_kind.dart';
import '../port/reg_fifo.dart';
import 'tilelink_interface.dart';

const _accessAckData = 1;
const _hintAck = 2;

// Beats less one of a message of [size] that carries data when [withData].
Logic _beatsLess1(Logic withData, Logic size, int beatLog2, int width) {
  final sw = size.width;
  if (beatLog2 >= (1 << sw) - 1) return Const(0, width: width);
  final over = size.gt(Const(beatLog2, width: sw));
  final shift = size - Const(beatLog2, width: sw);
  final n = (Const(1, width: width) << shift) - 1;
  return mux(withData & over, n, Const(0, width: width));
}

// Put, ArithmeticData and LogicalData carry data on A.
Logic _aHasData(Logic op) => ~op[2];

// AccessAckData and GrantData carry data on D.
Logic _dHasData(Logic op) => op.eq(_accessAckData) | op.eq(5);

// The D opcode that answers A opcode [op].
Logic _respOp(Logic op) => mux(
  op.eq(TileLinkAOpcode.get.value) | op.eq(2) | op.eq(3),
  Const(_accessAckData, width: 3),
  mux(op.eq(5), Const(_hintAck, width: 3), Const(0, width: 3)),
);

// A response stream from one target, with its slave side source.
class _Resp {
  final Logic valid = Logic();
  final Logic ready = Logic();
  final Logic sid;
  final Logic payload;
  _Resp(int sidWidth, int payloadWidth)
    : sid = Logic(width: sidWidth),
      payload = Logic(width: payloadWidth);
  Logic get fire => valid & ready;
}

/// A TileLink fabric. Build it with [HarborFabric.build].
///
/// - Register ports are TL-UL and memory ports are TL-UH, set by
///   [HarborFabricMaster.memory] and [HarborFabricSlave.memory].
/// - Each master port takes A into a 2 entry FIFO, and each slave port
///   drives A from a 2 entry FIFO. D reaches a master through a 2 entry
///   FIFO.
/// - A slave sees the master index on top of the master source. A slave
///   with fewer source bits gets sources remapped: each message in flight
///   holds one slave source, and a message waits when none is free.
/// - A slave never has more than its `outstanding` messages in flight, and
///   a master never more than its own `outstanding`.
/// - The beats of a message never interleave with other beats, on A at a
///   slave and on D at a master.
///
/// TileLink has no order between sources, and a master has one message per
/// source in flight, so the fabric keeps no order between messages.
///
/// A message that hits no slave, or that its slave cannot take, goes to an
/// internal error slave. It takes all A beats, then answers denied with the
/// full D beats, and AccessAckData beats are also corrupt. A TL-UL slave
/// takes only Get, PutFullData and PutPartialData of one beat or less. A
/// TL-UH slave takes every opcode up to the size its size field holds.
class HarborTileLinkFabric extends HarborFabricModule {
  /// Topology of the fabric.
  final HarborFabricTopology topology;

  /// Masters, in port order.
  final List<HarborFabricMaster> masters;

  /// Slaves, in port order.
  final List<HarborFabricSlave> slaves;

  /// Source bits a slave needs for no remap: the widest master source plus
  /// the master index.
  late final int fullSourceWidth;

  /// Width of the size field inside the fabric, the widest of all ports.
  late final int sizeWidth;

  /// Messages the internal error slave holds in flight.
  static const int errorOutstanding = 2;

  HarborTileLinkFabric({
    required this.topology,
    required Logic clk,
    required Logic reset,
    required this.masters,
    required this.slaves,
    super.name = 'fabric',
  }) : super(definitionName: _definitionName(topology, masters, slaves)) {
    final cfg0 = _tl(masters.first.name, masters.first.interface).config;
    final addrW = cfg0.addressWidth;
    final dataW = cfg0.dataWidth;
    for (final (name, intf) in [
      for (final m in masters) (m.name, m.interface),
      for (final s in slaves) (s.name, s.interface),
    ]) {
      final t = _tl(name, intf).config;
      if (t.addressWidth != addrW || t.dataWidth != dataW) {
        throw ArgumentError(
          '$name: TileLink widths (addr ${t.addressWidth}, data '
          '${t.dataWidth}) differ from addr $addrW, data $dataW',
        );
      }
      if (t.withBCE || t.sizeWidth > 5) {
        throw ArgumentError(
          '$name: a TileLink fabric port has no B, C and E channels and a '
          'size width of 5 or less',
        );
      }
    }
    HarborFabric.checkPorts(
      kind: HarborFabricKind.tilelink,
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
    final nt = ns + 1;
    final mCfg = [for (final m in masters) _tl(m.name, m.interface).config];
    final sCfg = [for (final s in slaves) _tl(s.name, s.interface).config];
    sizeWidth = [...mCfg, ...sCfg].map((x) => x.sizeWidth).reduce(max);
    final zw = sizeWidth;
    final maxSrc = mCfg.map((x) => x.sourceWidth).reduce(max);
    final pW = nm > 1 ? indexWidth(nm) : 0;
    fullSourceWidth = maxSrc + pW;
    final fw = fullSourceWidth;
    final beatLog2 = (dataW ~/ 8).bitLength - 1;
    final cw = max(1, (1 << zw) - 1 - beatLog2);
    final mW = indexWidth(nm);
    final tW = indexWidth(nt);
    final maskW = dataW ~/ 8;

    final ma = [
      for (final m in masters)
        (m.interface as TileLinkInterface).clone()..pairConnectIO(
          this,
          m.interface,
          PairRole.consumer,
          uniquify: (n) => '${m.name}_$n',
        ),
    ];
    final sa = [
      for (final s in slaves)
        (s.interface as TileLinkInterface).clone()..pairConnectIO(
          this,
          s.interface,
          PairRole.provider,
          uniquify: (n) => '${s.name}_$n',
        ),
    ];
    final tName = [for (final s in slaves) s.name, 'err'];
    final tSrcW = [for (final x in sCfg) x.sourceWidth, fw];
    final tN = [for (final s in slaves) s.outstanding, errorOutstanding];
    final tRemap = [for (var t = 0; t < nt; t++) tSrcW[t] < fw];

    // A beat inside the fabric, without its source.
    final aWidths = [3, 3, zw, addrW, maskW, dataW, 1];
    // A D beat inside the fabric, without its source.
    final dWidths = [3, 2, zw, dataW, 1, 1];
    final dPayW = dWidths.reduce((a, b) => a + b);

    final resp = [for (var t = 0; t < nt; t++) _Resp(tSrcW[t], dPayW)];
    final dLast = <Logic>[];
    for (var t = 0; t < nt; t++) {
      final [op, _, size, _, _, _] = harborUnpack(resp[t].payload, dWidths);
      final beat = Logic(name: '${tName[t]}_d_beat', width: cw);
      final last = beat
          .eq(_beatsLess1(_dHasData(op), size, beatLog2, cw))
          .named('${tName[t]}_d_last');
      Sequential(c, reset: r, [
        If(
          resp[t].fire,
          then: [beat < mux(last, Const(0, width: cw), beat + 1)],
        ),
      ]);
      dLast.add(last);
    }
    final dDone = [for (var t = 0; t < nt; t++) resp[t].fire & dLast[t]];

    // Master stages: input FIFO, beat count, decode and the master limit.
    final mPop = [for (var m = 0; m < nm; m++) Logic()];
    final mDone = [for (var m = 0; m < nm; m++) Logic()];
    final tReady = [for (var t = 0; t < nt; t++) Logic()];
    final tFirstOk = [for (var t = 0; t < nt; t++) Logic()];
    final lockV = [
      for (var t = 0; t < nt; t++) Logic(name: '${tName[t]}_a_lock'),
    ];
    final lockM = [
      for (var t = 0; t < nt; t++)
        Logic(name: '${tName[t]}_a_lock_master', width: mW),
    ];
    final mFirst = <Logic>[];
    final mLast = <Logic>[];
    final mFull = <Logic>[];
    final mBeatData = <Logic>[];
    final firstReq = <List<Logic>>[];
    final contReq = <List<Logic>>[];
    for (var m = 0; m < nm; m++) {
      final a = ma[m];
      final mn = masters[m].name;
      final f = HarborRegFifo(
        name: '${mn}_a',
        clk: c,
        reset: r,
        depth: 2,
        pushValid: a.aValid,
        pushData: harborPack([
          a.aOpcode,
          a.aParam,
          a.aSize.zeroExtend(zw),
          a.aAddress,
          a.aMask,
          a.aData,
          a.aCorrupt,
          a.aSource.zeroExtend(maxSrc),
        ]),
        popReady: mPop[m],
      );
      a.aReady <= f.pushReady;
      final beatData = f.popData.getRange(0, f.popData.width - maxSrc);
      final [op, _, size, addr, _, _, _] = harborUnpack(beatData, aWidths);
      final src = f.popData.getRange(f.popData.width - maxSrc);
      final beat = Logic(name: '${mn}_a_beat', width: cw);
      final first = beat.eq(0).named('${mn}_a_first');
      final last = beat
          .eq(_beatsLess1(_aHasData(op), size, beatLog2, cw))
          .named('${mn}_a_last');
      final ow = widthOf(masters[m].outstandingOn(HarborFabricKind.tilelink));
      final inflight = Logic(name: '${mn}_inflight', width: ow);
      final mOk = inflight.lt(
        Const(masters[m].outstandingOn(HarborFabricKind.tilelink), width: ow),
      );
      Sequential(c, reset: r, [
        If(mPop[m], then: [beat < mux(last, Const(0, width: cw), beat + 1)]),
        inflight <
            inflight +
                (mPop[m] & first).zeroExtend(ow) -
                mDone[m].zeroExtend(ow),
      ]);
      final hits = [
        for (var t = 0; t < ns; t++)
          (masters[m].reaches(slaves[t].name)
                  ? inRange(addr, slaves[t].range)
                  : Const(0)) &
              _fits(slaves[t].memory, sCfg[t].sizeWidth, beatLog2, op, size),
      ];
      final tgt = [...hits, ~anyOf(hits)];
      mFirst.add(first);
      mLast.add(last);
      mFull.add(pW > 0 ? [Const(m, width: pW), src].swizzle() : src);
      mBeatData.add(beatData);
      firstReq.add([
        for (var t = 0; t < nt; t++)
          f.popValid & first & mOk & tgt[t] & tFirstOk[t],
      ]);
      contReq.add([
        for (var t = 0; t < nt; t++)
          f.popValid &
              ~first &
              lockV[t] &
              lockM[t].eq(Const(m, width: mW)) &
              tReady[t],
      ]);
    }

    // Arbitration with a lock that holds a target for the rest of a
    // message.
    final grant = [
      for (var m = 0; m < nm; m++) [for (var t = 0; t < nt; t++) Logic()],
    ];
    if (topology == HarborFabricTopology.crossbar) {
      for (var t = 0; t < nt; t++) {
        final rr = roundRobin('${tName[t]}_a', c, r, [
          for (var m = 0; m < nm; m++) firstReq[m][t],
        ]);
        for (var m = 0; m < nm; m++) {
          grant[m][t] <= rr[m] | contReq[m][t];
        }
      }
      for (var m = 0; m < nm; m++) {
        mPop[m] <= anyOf(grant[m]);
      }
    } else {
      final busLock = Logic(name: 'bus_a_lock');
      final rr = roundRobin('bus_a', c, r, [
        for (var m = 0; m < nm; m++) anyOf(firstReq[m]) & ~busLock,
      ]);
      final g = [for (var m = 0; m < nm; m++) rr[m] | anyOf(contReq[m])];
      for (var m = 0; m < nm; m++) {
        mPop[m] <= g[m];
        for (var t = 0; t < nt; t++) {
          grant[m][t] <= g[m] & (firstReq[m][t] | contReq[m][t]);
        }
      }
      final pop = anyOf(g);
      Sequential(c, reset: r, [
        If(pop, then: [busLock < ~pick(g, mLast)]),
      ]);
    }

    // Each target: the beat it takes, source remap, locks and the limit.
    final tFire = <Logic>[];
    final tFirst = <Logic>[];
    final tLast = <Logic>[];
    final tBeat = <Logic>[];
    final tSid = <Logic>[];
    final fullOf = <Logic Function(Logic)>[];
    for (var t = 0; t < nt; t++) {
      final p = tName[t];
      final from = [for (var m = 0; m < nm; m++) grant[m][t]];
      final fire = anyOf(from).named('${p}_a_fire');
      final first = pick(from, mFirst);
      final last = pick(from, mLast);
      final full = pick(from, mFull);
      tFire.add(fire);
      tFirst.add(first);
      tLast.add(last);
      tBeat.add(pick(from, mBeatData));
      Sequential(c, reset: r, [
        If.block([
          Iff(fire & first & ~last, [
            lockV[t] < 1,
            lockM[t] < indexOf(from, mW),
          ]),
          ElseIf(fire & last, [lockV[t] < 0]),
        ]),
      ]);

      final n = tN[t];
      final ow = widthOf(n);
      final cnt = Logic(name: '${p}_inflight', width: ow);
      Sequential(c, reset: r, [
        cnt < cnt + (fire & first).zeroExtend(ow) - dDone[t].zeroExtend(ow),
      ]);
      Logic slotFree = Const(1);
      final sidHeld = Logic(name: '${p}_a_sid', width: tSrcW[t]);
      Logic sidNew;
      if (tRemap[t]) {
        final k = min(1 << tSrcW[t], n);
        final kw = indexWidth(k);
        final valid = [
          for (var i = 0; i < k; i++) Logic(name: '${p}_remap${i}_v'),
        ];
        final fid = [
          for (var i = 0; i < k; i++)
            Logic(name: '${p}_remap${i}_src', width: fw),
        ];
        final alloc = lowestOf([for (final v in valid) ~v]);
        slotFree = anyOf([for (final v in valid) ~v]);
        sidNew = indexOf(alloc, kw).zeroExtend(tSrcW[t]);
        final done = decodeIndex(resp[t].sid.getRange(0, kw), k);
        Sequential(c, reset: r, [
          for (var i = 0; i < k; i++) ...[
            If.block([
              Iff(fire & first & alloc[i], [valid[i] < 1, fid[i] < full]),
              ElseIf(dDone[t] & done[i], [valid[i] < 0]),
            ]),
          ],
        ]);
        fullOf.add((sid) => pick(decodeIndex(sid.getRange(0, kw), k), fid));
      } else {
        sidNew = full.zeroExtend(tSrcW[t]);
        fullOf.add((sid) => sid.getRange(0, fw));
      }
      Sequential(c, reset: r, [
        If(fire & first, then: [sidHeld < sidNew]),
      ]);
      tSid.add(mux(first, sidNew, sidHeld).named('${p}_a_sid_out'));
      tFirstOk[t] <=
          tReady[t] & ~lockV[t] & cnt.lt(Const(n, width: ow)) & slotFree;
    }

    // Slave paths and the error slave.
    final dead = <Logic>[];
    for (var t = 0; t < ns; t++) {
      final x = _slavePath(
        c,
        r,
        p: tName[t],
        s: sa[t],
        outstanding: tN[t],
        timeout: slaves[t].timeout,
        fire: tFire[t],
        first: tFirst[t],
        last: tLast[t],
        beat: tBeat[t],
        sid: tSid[t],
        ready: tReady[t],
        resp: resp[t],
        dLast: dLast[t],
        aWidths: aWidths,
        sizeWidth: zw,
        base: slaves[t].base,
      );
      if (x != null) dead.add(x);
    }
    _errorSlave(
      c,
      r,
      fire: tFire[ns],
      last: tLast[ns],
      beat: tBeat[ns],
      sid: tSid[ns],
      ready: tReady[ns],
      resp: resp[ns],
      dLast: dLast[ns],
      aWidths: aWidths,
      dataW: dataW,
    );
    output('bus_error') <= anyOf(dead);

    // D to the masters. The master index on top of the full source picks
    // the master, and a lock keeps the beats of a message together.
    final mids = <Logic>[];
    final dest = <List<Logic>>[];
    for (var t = 0; t < nt; t++) {
      final full = fullOf[t](resp[t].sid);
      mids.add(full.getRange(0, maxSrc));
      dest.add(nm > 1 ? decodeIndex(full.getRange(maxSrc), nm) : [Const(1)]);
    }
    final push = [for (var m = 0; m < nm; m++) Logic()];
    final pushData = <Logic>[];
    final outs = <HarborRegFifo>[];
    final items = <List<Logic>>[];
    for (var m = 0; m < nm; m++) {
      final a = ma[m];
      final x = mCfg[m];
      items.add([
        for (var t = 0; t < nt; t++)
          harborPack([mids[t].getRange(0, x.sourceWidth), resp[t].payload]),
      ]);
      final data = Logic(width: items[m].first.width);
      pushData.add(data);
      final f = HarborRegFifo(
        name: '${masters[m].name}_d',
        clk: c,
        reset: r,
        depth: 2,
        pushValid: push[m],
        pushData: data,
        popReady: a.dReady,
        resetEntries: true,
      );
      outs.add(f);
      final [src, op, param, size, dat, corrupt, denied] = harborUnpack(
        f.popData,
        [x.sourceWidth, ...dWidths],
      );
      a.dValid <= f.popValid;
      a.dSource <= src;
      a.dOpcode <= op;
      a.dParam <= param;
      a.dSize <= size.getRange(0, x.sizeWidth);
      a.dSink <= Const(0, width: x.sinkWidth);
      a.dData <= dat;
      a.dCorrupt <= corrupt;
      a.dDenied <= denied;
    }
    if (topology == HarborFabricTopology.crossbar) {
      final grants = <List<Logic>>[];
      for (var m = 0; m < nm; m++) {
        final mn = masters[m].name;
        final lock = Logic(name: '${mn}_d_lock');
        final lockT = Logic(name: '${mn}_d_lock_target', width: tW);
        final g = roundRobin('${mn}_d', c, r, [
          for (var t = 0; t < nt; t++)
            resp[t].valid &
                dest[t][m] &
                outs[m].pushReady &
                (~lock | lockT.eq(Const(t, width: tW))),
        ]);
        grants.add(g);
        push[m] <= anyOf(g);
        pushData[m] <= pick(g, items[m]);
        mDone[m] <= push[m] & pick(g, dLast);
        Sequential(c, reset: r, [
          If(push[m], then: [lock < ~pick(g, dLast), lockT < indexOf(g, tW)]),
        ]);
      }
      for (var t = 0; t < nt; t++) {
        resp[t].ready <= anyOf([for (var m = 0; m < nm; m++) grants[m][t]]);
      }
    } else {
      final lock = Logic(name: 'bus_d_lock');
      final lockT = Logic(name: 'bus_d_lock_target', width: tW);
      final g = roundRobin('bus_d', c, r, [
        for (var t = 0; t < nt; t++)
          resp[t].valid &
              anyOf([
                for (var m = 0; m < nm; m++) dest[t][m] & outs[m].pushReady,
              ]) &
              (~lock | lockT.eq(Const(t, width: tW))),
      ]);
      final any = anyOf(g);
      final last = pick(g, dLast);
      for (var m = 0; m < nm; m++) {
        push[m] <= anyOf([for (var t = 0; t < nt; t++) g[t] & dest[t][m]]);
        pushData[m] <= pick(g, items[m]);
        mDone[m] <= push[m] & last;
      }
      for (var t = 0; t < nt; t++) {
        resp[t].ready <= g[t];
      }
      Sequential(c, reset: r, [
        If(any, then: [lock < ~last, lockT < indexOf(g, tW)]),
      ]);
    }
  }

  // True when a slave can take a message of [op] and [size]. A TL-UL slave
  // takes Get, PutFullData and PutPartialData of one beat or less. A TL-UH
  // slave takes every opcode but Acquire, up to the size its field holds.
  static Logic _fits(
    bool memory,
    int slaveSizeWidth,
    int beatLog2,
    Logic op,
    Logic size,
  ) {
    final top = (1 << slaveSizeWidth) - 1;
    final maxSize = memory ? top : min(top, beatLog2);
    final sizeOk = size.lte(Const(maxSize, width: size.width));
    if (memory) return sizeOk & op.lt(TileLinkAOpcode.acquireBlock.value);
    return sizeOk &
        (op.eq(TileLinkAOpcode.get.value) |
            op.eq(TileLinkAOpcode.putFullData.value) |
            op.eq(TileLinkAOpcode.putPartialData.value));
  }

  // The A FIFO to one slave, and the timeout guard when the slave has a
  // timeout. Returns the guard's cut off flag.
  //
  // The guard keeps a record of each message in flight. When the slave owes
  // something and shows no progress for `timeout` cycles, the guard cuts it
  // off until reset. It takes the rest of the A beats, answers every
  // message in flight and every later one as denied, and takes and drops
  // each late D beat. A D message already started ends with corrupt beats
  // and keeps the denied value of its first beat.
  static Logic? _slavePath(
    Logic c,
    Logic r, {
    required String p,
    required TileLinkInterface s,
    required int outstanding,
    required int timeout,
    required Logic fire,
    required Logic first,
    required Logic last,
    required Logic beat,
    required Logic sid,
    required Logic ready,
    required _Resp resp,
    required Logic dLast,
    required List<int> aWidths,
    required int sizeWidth,
    required int base,
  }) {
    final guard = timeout > 0;
    final dead = guard ? Logic(name: '${p}_cut_off') : Const(0);
    final cfg = s.config;
    final aValid = Logic(name: '${p}_a_pop');
    final aF = HarborRegFifo(
      name: '${p}_a',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: fire & ~dead,
      pushData: harborPack([beat, sid]),
      popReady: s.aReady & aValid,
      resetEntries: true,
    );
    aValid <= cutValid('${p}_a', c, r, aF.popValid, s.aReady, dead);
    final [op, param, size, addr, mask, data, corrupt, aSid] = harborUnpack(
      aF.popData,
      [...aWidths, sid.width],
    );
    // A cut off slave never sees the beats still queued for it.
    s.aValid <= aValid;
    s.aOpcode <= op;
    s.aParam <= param;
    s.aSize <= size.getRange(0, cfg.sizeWidth);
    s.aSource <= aSid;
    s.aAddress <= (base == 0 ? addr : addr - Const(base, width: addr.width));
    s.aMask <= mask;
    s.aData <= data;
    s.aCorrupt <= corrupt;
    ready <= aF.pushReady | dead;

    final sPayload = harborPack([
      s.dOpcode,
      s.dParam,
      s.dSize.zeroExtend(sizeWidth),
      s.dData,
      s.dCorrupt,
      s.dDenied,
    ]);
    if (!guard) {
      resp.valid <= s.dValid;
      resp.sid <= s.dSource;
      resp.payload <= sPayload;
      s.dReady <= resp.ready;
      return null;
    }

    final n = outstanding;
    final nw = indexWidth(n);
    final v = [for (var i = 0; i < n; i++) Logic(name: '${p}_rec${i}_v')];
    final gsid = [
      for (var i = 0; i < n; i++)
        Logic(name: '${p}_rec${i}_sid', width: sid.width),
    ];
    final gop = [
      for (var i = 0; i < n; i++) Logic(name: '${p}_rec${i}_op', width: 3),
    ];
    final gsize = [
      for (var i = 0; i < n; i++)
        Logic(name: '${p}_rec${i}_size', width: sizeWidth),
    ];
    final adone = [
      for (var i = 0; i < n; i++) Logic(name: '${p}_rec${i}_a_done'),
    ];
    final aCur = Logic(name: '${p}_rec_a_cur', width: nw);
    final dCur = Logic(name: '${p}_rec_d_cur', width: nw);
    final dDen = Logic(name: '${p}_rec_d_denied');
    final dMid = Logic(name: '${p}_rec_d_mid');

    final slot = lowestOf([for (final x in v) ~x]);
    final owed = [for (var i = 0; i < n; i++) v[i] & adone[i]];
    final oldest = lowestOf(owed);
    final pickOh = [
      for (var i = 0; i < n; i++)
        mux(dMid, dCur.eq(Const(i, width: nw)), oldest[i]),
    ];
    final match = [for (var i = 0; i < n; i++) v[i] & gsid[i].eq(s.dSource)];
    final mop = pick(pickOh, gop);
    final mDenied = mux(dMid, dDen, Const(1));
    resp.valid <= mux(dead, dMid | anyOf(owed), s.dValid);
    resp.sid <= mux(dead, pick(pickOh, gsid), s.dSource);
    resp.payload <=
        mux(
          dead,
          harborPack([
            mop,
            Const(0, width: 2),
            pick(pickOh, gsize),
            Const(0, width: s.config.dataWidth),
            mop.eq(_accessAckData),
            mDenied,
          ]),
          sPayload,
        );
    s.dReady <= dead | resp.ready;
    final rel = [for (var i = 0; i < n; i++) mux(dead, pickOh[i], match[i])];
    final denied = resp.payload[-1];

    // The timer runs while the slave owes something: an answer to a message
    // whose A beats are all sent, or an A beat it has not taken. Any A
    // handshake or D VALID from the slave restarts it.
    final busy = anyOf(owed) | aF.popValid;
    final progress = (s.aValid & s.aReady) | s.dValid;
    final tw = widthOf(timeout);
    final timer = Logic(name: '${p}_timer', width: tw);
    final aOp = beat.getRange(0, 3);
    final aSize = beat.getRange(6, 6 + sizeWidth);
    Sequential(c, reset: r, [
      If.block([
        Iff(dead | ~busy | progress, [timer < 0]),
        ElseIf(timer.eq(Const(timeout - 1, width: tw)), [dead < 1]),
        Else([timer < timer + 1]),
      ]),
      If(fire & first, then: [aCur < indexOf(slot, nw)]),
      If(
        resp.fire,
        then: [
          dMid < ~dLast,
          If(~dMid, then: [dCur < indexOf(rel, nw), dDen < denied]),
        ],
      ),
      for (var i = 0; i < n; i++)
        If.block([
          Iff(fire & first & slot[i], [
            v[i] < 1,
            gsid[i] < sid,
            gop[i] < _respOp(aOp),
            gsize[i] < aSize,
            adone[i] < last,
          ]),
          Else([
            If(resp.fire & dLast & rel[i], then: [v[i] < 0]),
            If(
              fire & ~first & last & aCur.eq(Const(i, width: nw)),
              then: [adone[i] < 1],
            ),
          ]),
        ]),
    ]);
    return dead;
  }

  // The slave for messages that hit no region or that their slave cannot
  // take. It takes all A beats of a message, then answers it as denied with
  // all its D beats, in order.
  static void _errorSlave(
    Logic c,
    Logic r, {
    required Logic fire,
    required Logic last,
    required Logic beat,
    required Logic sid,
    required Logic ready,
    required _Resp resp,
    required Logic dLast,
    required List<int> aWidths,
    required int dataW,
  }) {
    final [op, _, size, _, _, _, _] = harborUnpack(beat, aWidths);
    final f = HarborRegFifo(
      name: 'err_msg',
      clk: c,
      reset: r,
      depth: errorOutstanding,
      pushValid: fire & last,
      pushData: harborPack([sid, _respOp(op), size]),
      popReady: resp.fire & dLast,
    );
    ready <= f.pushReady;
    final [hSid, hOp, hSize] = harborUnpack(f.popData, [
      sid.width,
      3,
      size.width,
    ]);
    resp.valid <= f.popValid;
    resp.sid <= hSid;
    resp.payload <=
        harborPack([
          hOp,
          Const(0, width: 2),
          hSize,
          Const(0, width: dataW),
          hOp.eq(_accessAckData),
          Const(1),
        ]);
  }

  static TileLinkInterface _tl(String name, PairInterface p) => switch (p) {
    final TileLinkInterface t => t,
    _ => throw ArgumentError(
      '$name: a TileLink fabric takes TileLinkInterface ports, got $p',
    ),
  };

  static String _definitionName(
    HarborFabricTopology topology,
    List<HarborFabricMaster> masters,
    List<HarborFabricSlave> slaves,
  ) {
    if (masters.isEmpty) {
      throw ArgumentError.value(masters, 'masters', 'must not be empty');
    }
    final c0 = _tl(masters.first.name, masters.first.interface).config;
    String port(String name, PairInterface p, bool memory) {
      final t = _tl(name, p).config;
      return '${memory ? 'H' : 'L'}s${t.sourceWidth}z${t.sizeWidth}';
    }

    return harborStableDefinitionName('HarborTileLinkFabric', [
      topology.name,
      'a${c0.addressWidth}',
      'd${c0.dataWidth}',
      for (final m in masters)
        'M${m.name}${port(m.name, m.interface, m.memory)}'
            'o${m.outstandingOn(HarborFabricKind.tilelink)}${m.reachTag(slaves)}',
      for (final s in slaves)
        'S${s.name}${port(s.name, s.interface, s.memory)}n${s.outstanding}'
            '${s.offset ? 'O' : ''}t${s.timeout}r${s.range.start.toRadixString(16)}'
            'x${s.range.size.toRadixString(16)}',
    ]);
  }
}
