import 'dart:math';

import 'package:rohd/rohd.dart';

import '../fabric_util.dart';
import '../port/memory_waist.dart';
import '../port/reg_fifo.dart';

/// Defaults and the automatic slot split for AXI4 exclusive access.
abstract final class HarborExclusive {
  /// Use as [HarborFabricMaster.exclusiveIds] to let the builder pick the
  /// slot count from a slot budget (see [slotCounts]).
  static const int auto = -1;

  /// Slots per monitored memory slave that automatic masters share.
  static const int defaultSlotBudget = 8;

  /// Default reservation granule in bytes.
  static const int defaultGranuleBytes = 64;

  /// The slot count of each master. [requested] holds null or 0 for a master
  /// with no exclusive access, a count N for the low IDs 0 to N-1, or [auto].
  /// [idWidths] are the master ID widths.
  ///
  /// Each automatic master gets a power of two of at least 1 and at most its
  /// ID count. They share what [budget] leaves after the fixed counts, and
  /// each gets 1 even when nothing is left. So the total can be more than
  /// [budget].
  static List<int> slotCounts(
    List<int> idWidths,
    List<int?> requested, {
    int budget = defaultSlotBudget,
  }) {
    final counts = <int>[];
    for (var m = 0; m < requested.length; m++) {
      final r = requested[m] ?? 0;
      final most = 1 << idWidths[m];
      if (r < auto || r > most) {
        throw ArgumentError(
          'master $m: exclusiveIds $r is out of range, its ID width gives '
          '$most IDs',
        );
      }
      counts.add(r == auto ? 1 : r);
    }
    final autos = [
      for (var m = 0; m < requested.length; m++)
        if (requested[m] == auto) m,
    ];
    var left = budget - counts.fold(0, (a, b) => a + b);
    var grew = true;
    while (grew) {
      grew = false;
      for (final m in autos) {
        if (counts[m] * 2 <= 1 << idWidths[m] && left >= counts[m]) {
          left -= counts[m];
          counts[m] *= 2;
          grew = true;
        }
      }
    }
    return counts;
  }
}

/// The exclusive monitor of an AXI4 memory slave: the slave side IDs that
/// have a reservation slot, and the reservation granule.
///
/// An AXI4 fabric puts the master index above the master ID, so the slots of
/// one master are one run of IDs. [forMasters] gives the runs for a fabric.
class HarborAxi4Exclusive {
  /// Runs of IDs as (first ID, number of IDs), in increasing order.
  final List<(int, int)> runs;

  /// Bytes of one reservation granule: a power of two from the bus width to
  /// 128. A reservation covers the aligned granule that holds the access.
  final int granuleBytes;

  const HarborAxi4Exclusive(
    this.runs, {
    this.granuleBytes = HarborExclusive.defaultGranuleBytes,
  });

  /// The monitor for the slave side of an AXI4 fabric, or null when no
  /// master has exclusive access. [idWidths] are the master ID widths in
  /// master order, an AXI4-Lite master counting as 1 bit. [exclusiveIds]
  /// are as in [HarborExclusive.slotCounts].
  static HarborAxi4Exclusive? forMasters(
    List<int> idWidths,
    List<int?> exclusiveIds, {
    int slotBudget = HarborExclusive.defaultSlotBudget,
    int granuleBytes = HarborExclusive.defaultGranuleBytes,
  }) {
    final counts = HarborExclusive.slotCounts(
      idWidths,
      exclusiveIds,
      budget: slotBudget,
    );
    if (counts.every((c) => c == 0)) return null;
    final maxId = idWidths.reduce(max);
    return HarborAxi4Exclusive([
      for (var m = 0; m < idWidths.length; m++)
        if (counts[m] > 0) (idWidths.length > 1 ? m << maxId : 0, counts[m]),
    ], granuleBytes: granuleBytes);
  }

  /// Every ID with a slot, in slot order.
  List<int> get ids => [
    for (final (first, count) in runs)
      for (var i = 0; i < count; i++) first + i,
  ];

  /// Number of slots.
  int get slots => runs.fold(0, (n, r) => n + r.$2);

  /// The fewest ID bits that hold every ID.
  int get idWidth => max(1, ids.reduce(max).bitLength);

  /// A short name tag for definition names.
  String get tag =>
      'x${[for (final (f, c) in runs) '${f}_$c'].join('_')}_g$granuleBytes';

  /// True when [other] has the same slot IDs.
  bool sameIds(HarborAxi4Exclusive other) =>
      other.runs.length == runs.length &&
      [
        for (var i = 0; i < runs.length; i++) other.runs[i] == runs[i],
      ].every((b) => b);

  @override
  bool operator ==(Object other) =>
      other is HarborAxi4Exclusive &&
      other.granuleBytes == granuleBytes &&
      sameIds(other);

  @override
  int get hashCode => Object.hash(Object.hashAll(runs), granuleBytes);

  @override
  String toString() =>
      'HarborAxi4Exclusive($runs, granule $granuleBytes bytes)';
}

// The address split of a monitor: the key is the granule number in the
// device, its low part the block in the 4 KB page, its high part the page.
class _Geometry {
  final int g;
  final int kb;
  final int keyW;
  final int blkHi;

  _Geometry(HarborAxi4Exclusive config, int addrWidth, int busSize, int bits)
    : g = config.granuleBytes.bitLength - 1,
      kb = min(bits, addrWidth),
      keyW = max(1, min(bits, addrWidth) - (config.granuleBytes.bitLength - 1)),
      blkHi = min(12, min(bits, addrWidth)) {
    final gBytes = config.granuleBytes;
    if (gBytes & (gBytes - 1) != 0 || g < busSize || gBytes > 128) {
      throw ArgumentError(
        'exclusive granule $gBytes must be a power of two from the bus '
        'width ${1 << busSize} to 128 bytes',
      );
    }
    if (kb < g) {
      throw ArgumentError(
        'an exclusive monitor needs at least $g device address bits for a '
        '$gBytes byte granule, got $kb',
      );
    }
  }

  int get blkW => max(0, blkHi - g);
  bool get paged => kb > 12;
  bool get aliased => kb < 12;

  /// Width of the bits [HarborAxi4ExclusiveMonitor.pre] gives.
  int get preWidth => 1 + 2 * blkW + (aliased ? 1 : 0);

  Logic key(Logic a) => kb > g ? a.getRange(g, kb) : Const(0, width: keyW);
  Logic? blk(Logic key) => blkW > 0 ? key.getRange(0, blkW) : null;
  Logic? page(Logic key) => paged ? key.getRange(12 - g) : null;
}

/// An AXI4 exclusive access monitor, built in the current module at the
/// request output of an AXI4 memory slave.
///
/// The monitor looks at the request on the waist REQ channel and acts when
/// the waist takes it ([take]). Takes come one at a time and the memory does
/// writes in take order, so take order is the order of every decision.
///
/// - Each ID with a slot has a valid bit and a granule address. The address
///   holds only the bits the device decodes, so an alias of the same word
///   has the same address.
/// - An exclusive read sets the slot of its ID. If a write that overlaps the
///   granule is still in flight (taken, no WRESP yet), the slot stays clear,
///   because the read can return the data from before that write.
/// - An exclusive write passes when the slot of its ID is valid and holds
///   its granule. Else the write is dropped: [drop] is high, every strobe
///   must be forced low, and nothing changes.
/// - A write that changes memory clears every slot whose granule it
///   overlaps, at its take. This includes an exclusive write that passes.
///
/// So when an exclusive write and a conflicting write are in flight at the
/// same time, the first taken wins. If the conflicting write is taken first,
/// the exclusive write fails. If the exclusive write is taken first, it
/// passes and the conflicting write lands after it.
///
/// An exclusive access with no slot for its ID, or one with an illegal
/// burst, is a normal access. An exclusive access that breaks the AXI4
/// exclusive rules (bytes not a power of two or not aligned to the bytes)
/// or is larger than the granule is a normal read or a dropped write, with
/// OKAY.
///
/// For timing, the burst checks and the write range come from [pre] at the
/// AW or AR push, and the slot change of a take lands one cycle later. A
/// decision in that cycle sees the pending change through a bypass, so the
/// result is the same as a change at the take.
class HarborAxi4ExclusiveMonitor {
  /// High when the request at the waist is a write that must change no
  /// memory.
  final Logic drop;

  /// High when the write at the AW head gets EXOKAY.
  final Logic wExOkay;

  /// High when the read at the AR head gets EXOKAY on every beat.
  final Logic rExOkay;

  /// High when the AW head is not ready yet. The arbiter must not pick it.
  final Logic wStall;

  /// High when the AR head is not ready yet. The arbiter must not pick it.
  final Logic rStall;

  HarborAxi4ExclusiveMonitor._(
    this.drop,
    this.wExOkay,
    this.rExOkay,
    this.wStall,
    this.rStall,
  );

  /// Width of the bits [pre] gives.
  static int preWidth({
    required HarborAxi4Exclusive config,
    required int addrWidth,
    required int busSize,
    required int deviceBits,
  }) => _Geometry(config, addrWidth, busSize, deviceBits).preWidth;

  /// The bits the monitor needs from an AW ([write] true) or AR request,
  /// built at the FIFO push: the exclusive rule check and, for a write, the
  /// blocks of the page it can change.
  static Logic pre({
    required HarborAxi4Exclusive config,
    required Logic addr,
    required Logic len,
    required Logic size,
    required Logic burst,
    required int busSize,
    required int deviceBits,
    required bool write,
  }) {
    final geo = _Geometry(config, addr.width, busSize, deviceBits);
    const lens = [0, 1, 3, 7, 15];
    final pow2 = anyOf([for (final l in lens) len.eq(l)]);
    Logic lenLog = Const(0, width: 4);
    for (var i = 1; i < lens.length; i++) {
      lenLog = mux(len.eq(lens[i]), Const(i, width: 4), lenLog);
    }
    final bytesLog = size.zeroExtend(4) + lenLog;
    final addr7 = addr.width >= 7 ? addr.getRange(0, 7) : addr.zeroExtend(7);
    final aligned = (addr7 & ~(Const(0x7f, width: 7) << bytesLog)).eq(0);
    final exBad = ~pow2 | bytesLog.gt(geo.g) | ~aligned;
    final rest = geo.preWidth - 1;
    if (!write || rest == 0) {
      return rest == 0 ? exBad : [Const(0, width: rest), exBad].swizzle();
    }

    // The bytes a write can change, as [lo, hi] in the page of [addr]. A
    // write that crosses a device alias boundary in the page hits every
    // slot.
    final addr12 = addr.width >= 12
        ? addr.getRange(0, 12)
        : addr.zeroExtend(12);
    final total = (len.zeroExtend(17) + 1) << size;
    final totalMask = (total - 1).getRange(0, 12);
    final isWrap = burst.eq(HarborMemoryBurst.wrap.value);
    final wrapLo = addr12 & ~totalMask;
    final sizeLo = addr12 & (Const(0xfff, width: 12) << size);
    final lo = mux(isWrap, wrapLo, addr12);
    final hiSum = mux(isWrap, wrapLo, sizeLo).zeroExtend(17) + total - 1;
    final hi = mux(
      hiSum.gt(0xfff),
      Const(0xfff, width: 12),
      hiSum.getRange(0, 12),
    );
    return harborPack([
      exBad,
      if (geo.blkW > 0) ...[
        lo.getRange(geo.g, geo.blkHi),
        hi.getRange(geo.g, geo.blkHi),
      ],
      if (geo.aliased) lo.getRange(geo.kb).neq(hi.getRange(geo.kb)),
    ]);
  }

  /// Builds the monitor. The write request at the head of the AW FIFO and
  /// the read request at the head of the AR FIFO each come as an ID, an
  /// address, LOCK, the illegal-burst bit (high for SLVERR) and the bits
  /// [pre] made at the push. [write] is high when the waist request is the
  /// write one. The decision is made for each head on its own and only the
  /// result goes through [write], to keep the arbiter off the long path.
  /// [take] is high when the waist takes the request. [done] is high when
  /// the waist gives a write response. [deviceBits] is the number of low
  /// address bits the device decodes. [depth] is the most writes in flight.
  ///
  /// [wEntryIds], [wEntryAddrs], [wPush] and [wRead] are the AW FIFO
  /// entries in place: the ID and address of each entry, its push enable
  /// for an exclusive (LOCK) request, and the index of the head. The slot lookup of each entry is a register
  /// that is one cycle behind, so an entry is not ready ([wStall]) in the
  /// cycle after its push. [rEntryAddrs], [rPush] and [rRead] are the same
  /// for the AR FIFO, for the in-flight write check.
  factory HarborAxi4ExclusiveMonitor({
    required Logic clk,
    required Logic reset,
    required HarborAxi4Exclusive config,
    required Logic write,
    required Logic wId,
    required Logic wAddr,
    required Logic wLock,
    required Logic wIllegal,
    required Logic wPre,
    required Logic rId,
    required Logic rAddr,
    required Logic rLock,
    required Logic rIllegal,
    required Logic rPre,
    required List<Logic> wEntryIds,
    required List<Logic> wEntryAddrs,
    required List<Logic> wPush,
    required Logic wRead,
    required List<Logic> rEntryAddrs,
    required List<Logic> rPush,
    required Logic rRead,
    required Logic take,
    required Logic done,
    required int busSize,
    required int deviceBits,
    required int depth,
    String name = 'excl',
  }) {
    final geo = _Geometry(config, wAddr.width, busSize, deviceBits);
    final idW = wId.width;
    if (config.idWidth > idW) {
      throw ArgumentError(
        'exclusive IDs ${config.runs} do not fit in $idW ID bits',
      );
    }
    final keyW = geo.keyW;
    final blkW = geo.blkW;
    final wKey = geo.key(wAddr).named('${name}_wkey');
    final rKey = geo.key(rAddr).named('${name}_rkey');
    final preWidths = [
      1,
      if (blkW > 0) ...[blkW, blkW],
      if (geo.aliased) 1,
    ];
    final [wBad, ...range] = harborUnpack(wPre, preWidths);
    final rBad = harborUnpack(rPre, preWidths).first;
    final wLo = blkW > 0 ? range[0] : null;
    final wHi = blkW > 0 ? range[1] : null;
    final Logic wCross = geo.aliased ? range.last : Const(0);
    final wPage = geo.page(wKey);

    Logic eqOrTrue(Logic? a, Logic? b) =>
        a == null || b == null ? Const(1) : a.eq(b);
    Logic inRange(Logic? x, Logic? lo, Logic? hi) =>
        x == null ? Const(1) : x.gte(lo!) & x.lte(hi!);
    // True when a write of [lo, hi] blocks in [page] hits the granule [k].
    Logic hits(Logic cross, Logic? page, Logic? lo, Logic? hi, Logic k) =>
        cross | eqOrTrue(page, geo.page(k)) & inRange(geo.blk(k), lo, hi);
    Logic? reg(Logic? like, String n) =>
        like == null ? null : Logic(name: n, width: like.width);
    Logic hasSlot(Logic id) => anyOf([
      for (final (first, count) in config.runs)
        id.gte(first) & id.zeroExtend(idW + 1).lt(first + count),
    ]);

    // Slots, and the slot of the write ID through a mux tree on the ID.
    final slotIds = config.ids;
    final n = slotIds.length;
    final valid = [for (var k = 0; k < n; k++) Logic(name: '${name}_v$k')];
    final keys = [
      for (var k = 0; k < n; k++) Logic(name: '${name}_key$k', width: keyW),
    ];
    Logic byId(List<Logic> items, Logic sel, int bit, int base) {
      final span = 1 << bit;
      final k = [
        for (var i = 0; i < n; i++)
          if (slotIds[i] >= base && slotIds[i] < base + span) i,
      ];
      if (k.isEmpty) return Const(0, width: items.first.width);
      if (bit == 0) return items[k.single];
      return mux(
        sel[bit - 1],
        byId(items, sel, bit - 1, base + (span >> 1)),
        byId(items, sel, bit - 1, base),
      );
    }

    // The slot change of the last take, applied at the next edge.
    final evSet = Logic(name: '${name}_ev_set');
    final evId = Logic(name: '${name}_ev_id', width: idW);
    final evKey = Logic(name: '${name}_ev_key', width: keyW);
    final evValid = Logic(name: '${name}_ev_valid');
    final evClr = Logic(name: '${name}_ev_clr');
    final evLo = reg(wLo, '${name}_ev_lo');
    final evHi = reg(wHi, '${name}_ev_hi');
    final evPage = reg(wPage, '${name}_ev_page');
    final evCross = geo.aliased ? Logic(name: '${name}_ev_cross') : Const(0);

    // The slot of an entry as it is after the pending change. A pending
    // clear only matters when the slot key equals the entry key, so it is
    // checked against the entry key.
    Logic bypass(Logic id, Logic key, Logic slotValid, Logic slotKeyEq) {
      final same = evSet & evId.eq(id);
      final pendClr = evClr & hits(evCross, evPage, evLo, evHi, key);
      return mux(same, evValid & evKey.eq(key), slotValid & slotKeyEq) &
          ~pendClr;
    }

    // Each AW entry looks up its slot in the slot table one cycle ahead.
    // The register holds the lookup with every change up to the last take,
    // and the decision adds the change of the last take through [bypass].
    final ents = wEntryIds.length;
    final lk = [for (var e = 0; e < ents; e++) Logic(name: '${name}_lk$e')];
    final fresh = [
      for (var e = 0; e < ents; e++) Logic(name: '${name}_fresh$e'),
    ];
    final entKey = [for (final a in wEntryAddrs) geo.key(a)];
    final lkNext = [
      for (var e = 0; e < ents; e++)
        bypass(
          wEntryIds[e],
          entKey[e],
          byId(valid, wEntryIds[e], idW, 0),
          byId(keys, wEntryIds[e], idW, 0).eq(entKey[e]),
        ),
    ];
    // The change of the last take as seen by each entry, worked out at the
    // take so the decision reads only registers. A fresh entry is not
    // decided in the cycle these are wrong for it.
    final evSameId = [
      for (var e = 0; e < ents; e++) Logic(name: '${name}_ev_same$e'),
    ];
    final evSameKey = [
      for (var e = 0; e < ents; e++) Logic(name: '${name}_ev_skey$e'),
    ];
    final evHit = [
      for (var e = 0; e < ents; e++) Logic(name: '${name}_ev_hit$e'),
    ];
    final entMatch = [
      for (var e = 0; e < ents; e++)
        mux(evSameId[e], evSameKey[e] & evValid, lk[e] & ~evHit[e]),
    ];
    Logic atHead(List<Logic> xs) {
      Logic out = xs[0];
      for (var e = 1; e < ents; e++) {
        out = mux(wRead.eq(e), xs[e], out);
      }
      return out;
    }

    final match = atHead(entMatch).named('${name}_match');
    final wStall = atHead(fresh).named('${name}_wstall');
    final wExcl = wLock & hasSlot(wId) & ~wIllegal;
    final wDrop = (wExcl & (wBad | ~match)).named('${name}_wdrop');
    final wOkay = (wExcl & ~wBad & match).named('${name}_wexokay');
    final rExcl = (rLock & hasSlot(rId) & ~rIllegal & ~rBad).named(
      '${name}_rexcl',
    );

    final drop = (write & wDrop).named('${name}_drop');
    final writes = (~wIllegal & ~wDrop).named('${name}_writes');

    // Writes in flight: taken, with no WRESP yet. Responses come back in
    // take order, so a ring of [depth] entries holds them. A write goes in
    // at its take, so the next take already sees it.
    final ptrW = indexWidth(depth);
    final head = Logic(name: '${name}_head', width: ptrW);
    final tail = Logic(name: '${name}_tail', width: ptrW);
    final live = [for (var j = 0; j < depth; j++) Logic(name: '${name}_p$j')];
    final pLo = [for (var j = 0; j < depth; j++) reg(wLo, '${name}_plo$j')];
    final pHi = [for (var j = 0; j < depth; j++) reg(wHi, '${name}_phi$j')];
    final pPage = [
      for (var j = 0; j < depth; j++) reg(wPage, '${name}_ppage$j'),
    ];
    final pCross = [
      for (var j = 0; j < depth; j++)
        geo.aliased ? Logic(name: '${name}_pcross$j') : Const(0),
    ];
    // Each AR entry keeps a register per ring entry: does that write hit
    // the granule of the read. It is one cycle behind the ring, so a ring
    // entry written in the last cycle uses the hit worked out at its push,
    // and an AR entry is not ready ([rStall]) in the cycle after its push.
    final rEnts = rEntryAddrs.length;
    final rKeys = [for (final a in rEntryAddrs) geo.key(a)];
    final rh = [
      for (var e = 0; e < rEnts; e++)
        [for (var j = 0; j < depth; j++) Logic(name: '${name}_rh${e}_$j')],
    ];
    final rhPush = [
      for (var e = 0; e < rEnts; e++) Logic(name: '${name}_rhpush$e'),
    ];
    final pushed = [
      for (var j = 0; j < depth; j++) Logic(name: '${name}_pushed$j'),
    ];
    final rFresh = [
      for (var e = 0; e < rEnts; e++) Logic(name: '${name}_rfresh$e'),
    ];
    Logic atRead(List<Logic> xs) {
      Logic out = xs[0];
      for (var e = 1; e < rEnts; e++) {
        out = mux(rRead.eq(e), xs[e], out);
      }
      return out;
    }

    final pendHit = atRead([
      for (var e = 0; e < rEnts; e++)
        anyOf([
          for (var j = 0; j < depth; j++)
            live[j] & mux(pushed[j], rhPush[e], rh[e][j]),
        ]),
    ]).named('${name}_pend_hit');
    final rStall = atRead(rFresh).named('${name}_rstall');

    Logic next(Logic p) => depth == 1 << ptrW
        ? p + 1
        : mux(p.eq(depth - 1), Const(0, width: ptrW), p + 1);

    final push = take & write;
    Sequential(clk, reset: reset, [
      // A write clears at its take, not at its WRESP. A clear at WRESP
      // lets an exclusive write taken after a conflicting write pass, and
      // the memory then does the conflicting write first and loses it.
      for (var e = 0; e < ents; e++) ...[
        lk[e] < lkNext[e],
        fresh[e] < wPush[e],
        evSameId[e] < take & ~write & rExcl & rId.eq(wEntryIds[e]),
        evSameKey[e] < rKey.eq(entKey[e]),
        evHit[e] <
            take & write & writes & hits(wCross, wPage, wLo, wHi, entKey[e]),
      ],
      evSet < take & ~write & rExcl,
      evClr < take & write & writes,
      evId < rId,
      evKey < rKey,
      evValid < ~pendHit,
      if (evLo != null) evLo < wLo,
      if (evHi != null) evHi < wHi,
      if (evPage != null) evPage < wPage,
      if (geo.aliased) evCross < wCross,
      for (var k = 0; k < n; k++) ...[
        If(
          evSet & evId.eq(Const(slotIds[k], width: idW)),
          then: [valid[k] < evValid, keys[k] < evKey],
        ),
        If(
          evClr & hits(evCross, evPage, evLo, evHi, keys[k]),
          then: [valid[k] < Const(0)],
        ),
      ],
      for (var e = 0; e < rEnts; e++) ...[
        rFresh[e] < rPush[e],
        rhPush[e] < hits(wCross, wPage, wLo, wHi, rKeys[e]),
        for (var j = 0; j < depth; j++)
          rh[e][j] < hits(pCross[j], pPage[j], pLo[j], pHi[j], rKeys[e]),
      ],
      for (var j = 0; j < depth; j++) pushed[j] < push & tail.eq(j),
      If(push, then: [tail < next(tail)]),
      for (var j = 0; j < depth; j++)
        If(
          push & tail.eq(j),
          then: [
            live[j] < writes,
            if (wLo != null) pLo[j]! < wLo,
            if (wHi != null) pHi[j]! < wHi,
            if (wPage != null) pPage[j]! < wPage,
            if (geo.aliased) pCross[j] < wCross,
          ],
        ),
      If(done, then: [head < next(head)]),
      for (var j = 0; j < depth; j++)
        If(done & head.eq(j), then: [live[j] < Const(0)]),
    ]);

    return HarborAxi4ExclusiveMonitor._(drop, wOkay, rExcl, wStall, rStall);
  }
}
