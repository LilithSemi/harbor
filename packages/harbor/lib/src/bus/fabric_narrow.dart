import 'dart:math';

import 'package:rohd/rohd.dart';

import 'axi4/axi4_interface.dart';
import 'axi4/axi4_lite_interface.dart';
import 'fabric.dart';
import 'fabric_util.dart';
import 'port/reg_fifo.dart' show harborLoad;
import 'tilelink/tilelink_interface.dart';
import 'wishbone/wishbone_interface.dart';

/// Address width and data width of a fabric port.
(int, int) harborPortWidths(PairInterface p) => switch (p) {
  final Axi4Interface a => (a.addressWidth, a.dataWidth),
  final Axi4LiteInterface l => (l.addressWidth, l.dataWidth),
  final WishboneInterface w => (w.config.addressWidth, w.config.dataWidth),
  final TileLinkInterface t => (t.config.addressWidth, t.config.dataWidth),
  _ => throw ArgumentError('$p is not a fabric port'),
};

/// A register port like [port] with the given widths, for a fabric port
/// that carries a narrow slave. Wishbone ports get ERR, since the width
/// adapter answers ERR for a rejected access.
PairInterface harborWidenPort(
  PairInterface port, {
  required int addressWidth,
  required int dataWidth,
}) => switch (port) {
  Axi4LiteInterface() => Axi4LiteInterface(
    addressWidth: addressWidth,
    dataWidth: dataWidth,
  ),
  final WishboneInterface w => WishboneInterface(
    w.config.copyWith(
      addressWidth: addressWidth,
      dataWidth: dataWidth,
      selWidth: 0,
      useErr: true,
    ),
  ),
  final TileLinkInterface t => TileLinkInterface(
    TileLinkConfig(
      addressWidth: addressWidth,
      dataWidth: dataWidth,
      sizeWidth: t.config.sizeWidth,
      sourceWidth: t.config.sourceWidth,
      sinkWidth: t.config.sinkWidth,
    ),
  ),
  _ => throw ArgumentError('$port has no width adapter'),
};

/// True when a fabric of [addrW] by [dataW] has to adapt slave [s], and
/// throws [ArgumentError] when it cannot.
///
/// A slave adapts when its data or address width is narrower. Only a
/// register slave can, and only when it sets [HarborFabricSlave.narrowOk]: an AXI4-Lite, TL-UL or classic Wishbone port with
/// one request in flight, and with an address offset (so a region of up to
/// `2^address width` bytes fits its address). A slave wider than the fabric
/// never adapts.
bool harborSlaveAdapts(
  HarborFabricSlave s, {
  required String kind,
  required int addrW,
  required int dataW,
}) {
  final (a, d) = harborPortWidths(s.interface);
  if (a == addrW && d == dataW) return false;
  final why = <String>[
    if (a > addrW || d > dataW) 'it is wider than the fabric',
    if (!s.narrowOk)
      'it is not a register slave that allows adapting (a memory or XIP '
          'window must be built with the fabric data width, for example '
          'busDataWidth on a SPI flash)',
    if (s.memory || s.interface is Axi4Interface) 'it is a memory port',
    if (s.outstanding != 1) 'it has more than one request in flight',
    if (s.readInterfaces.isNotEmpty || s.exclusive != null)
      'it has read channels or an exclusive monitor',
    if (!s.offset) 'it does not see the offset address',
    if (a < addrW && BigInt.from(s.range.size) > (BigInt.one << a))
      'its region is too big',
    if (d <= dataW && a < _lowBits(d, dataW)) 'its address is too narrow',
  ];
  if (why.isNotEmpty) {
    throw ArgumentError(
      '${s.name}: $kind widths (addr $a, data $d) differ from addr $addrW, '
      'data $dataW and the fabric cannot adapt it: ${why.join(', ')}',
    );
  }
  return true;
}

// Address bits a narrow word of [d] bits and its lane in a [dataW] bit word
// take.
int _lowBits(int d, int dataW) =>
    (d ~/ 8).bitLength - 1 + (dataW ~/ d).bitLength - 1;

/// Byte lanes of a wide access for a narrow slave.
class _Lanes {
  /// Narrow words in a wide word.
  final int count;

  /// Bytes in a narrow word.
  final int narrowBytes;

  final int narrowLog2;
  final int laneBits;

  /// Index of the selected lane.
  final Logic lane;

  /// High when more than one lane has a byte select.
  final Logic multi;

  _Lanes._(
    this.count,
    this.narrowBytes,
    this.narrowLog2,
    this.laneBits,
    this.lane,
    this.multi,
  );

  /// Lane of an access with byte selects [sel] at [addr]. Without a byte
  /// select the address picks the lane, which is also the lane of a read.
  /// [sel] is null for a read that has no byte selects.
  factory _Lanes(Logic? sel, Logic addr, int wideBytes, int narrowBytes) {
    final count = wideBytes ~/ narrowBytes;
    final nl = narrowBytes.bitLength - 1;
    final lb = count.bitLength - 1;
    if (count == 1) {
      return _Lanes._(1, narrowBytes, nl, 0, Const(0), Const(0));
    }
    final fromAddr = addr.getRange(nl, nl + lb);
    if (sel == null) {
      return _Lanes._(count, narrowBytes, nl, lb, fromAddr, Const(0));
    }
    final groups = [
      for (var g = 0; g < count; g++)
        sel.getRange(g * narrowBytes, (g + 1) * narrowBytes).or(),
    ];
    Logic seen = Const(0);
    Logic multi = Const(0);
    for (final g in groups) {
      multi = multi | (seen & g);
      seen = seen | g;
    }
    return _Lanes._(
      count,
      narrowBytes,
      nl,
      lb,
      mux(seen, indexOf(groups, lb), fromAddr),
      multi,
    );
  }

  /// The narrow slice of [wide] in the selected lane.
  Logic take(Logic wide) {
    if (count == 1) return wide;
    final w = wide.width ~/ count;
    return pick(decodeIndex(lane, count), [
      for (var g = 0; g < count; g++) wide.getRange(g * w, (g + 1) * w),
    ]);
  }

  /// [narrow] in the selected lane of a wide word, other lanes 0. With
  /// [at], that lane index takes the place of the selected lane.
  Logic place(Logic narrow, [Logic? at]) {
    if (count == 1) return narrow;
    final oh = decodeIndex(at ?? lane, count);
    final w = narrow.width;
    return [
      for (var g = count - 1; g >= 0; g--) narrow & oh[g].replicate(w),
    ].concat();
  }

  /// The narrow address of [wide], with the lane bits set to the selected
  /// lane and the bits above the narrow address dropped.
  Logic address(Logic wide, int narrowAddrW) {
    if (count == 1) return wide.getRange(0, narrowAddrW);
    return [
      if (narrowAddrW > narrowLog2 + laneBits)
        wide.getRange(narrowLog2 + laneBits, narrowAddrW),
      lane,
      if (narrowLog2 > 0) wide.getRange(0, narrowLog2),
    ].concat();
  }
}

/// Ties a wide AXI4-Lite port [w] of a fabric to the narrow slave port [n].
///
/// - A lane comes from the write strobes, or from the address when none is
///   set. A read takes the lane the address selects and returns the data in
///   that lane, with 0 in the others. A read has no byte selects, so a read
///   of both lanes gets the lane at its address.
/// - A write with strobes in more than one lane gets SLVERR and never
///   reaches the slave.
/// - A write waits for its AW and W, then goes to the slave, and its B comes
///   from the slave. No write is posted.
void harborNarrowAxi4Lite(
  Logic c,
  Logic r, {
  required String name,
  required Axi4LiteInterface w,
  required Axi4LiteInterface n,
}) {
  final wideBytes = w.dataWidth ~/ 8;
  final narrowBytes = n.dataWidth ~/ 8;
  final na = n.addressWidth;

  // Write: hold AW and W, then pick the lane.
  final awHeld = Logic(name: '${name}_aw_held');
  final wHeld = Logic(name: '${name}_w_held');
  final awSent = Logic(name: '${name}_aw_sent');
  final wSent = Logic(name: '${name}_w_sent');
  final awAddr = Logic(name: '${name}_aw_addr', width: w.addressWidth);
  final awProt = Logic(name: '${name}_aw_prot', width: 3);
  final wData = Logic(name: '${name}_w_data', width: w.dataWidth);
  final wStrb = Logic(name: '${name}_w_strb', width: wideBytes);
  final both = awHeld & wHeld;
  final wl = _Lanes(wStrb, awAddr, wideBytes, narrowBytes);
  final bad = wl.multi;
  w.awReady <= ~awHeld;
  w.wReady <= ~wHeld;
  n.awValid <= both & ~bad & ~awSent;
  n.awAddr <= wl.address(awAddr, na);
  n.awProt <= awProt;
  n.wValid <= both & ~bad & ~wSent;
  n.wData <= wl.take(wData);
  n.wStrb <= wl.take(wStrb);
  w.bValid <= both & (bad | n.bValid);
  w.bResp <= mux(bad, Const(2, width: 2), n.bResp);
  n.bReady <= both & ~bad & w.bReady;
  final bFire = w.bValid & w.bReady;
  Sequential(c, reset: r, [
    If(
      bFire,
      then: [awHeld < 0, wHeld < 0, awSent < 0, wSent < 0],
      orElse: [
        If(w.awValid & ~awHeld, then: [awHeld < 1]),
        If(w.wValid & ~wHeld, then: [wHeld < 1]),
        If(n.awValid & n.awReady, then: [awSent < 1]),
        If(n.wValid & n.wReady, then: [wSent < 1]),
      ],
    ),
    awAddr < harborLoad(awAddr, w.awValid & ~awHeld, w.awAddr),
    awProt < harborLoad(awProt, w.awValid & ~awHeld, w.awProt),
    wData < harborLoad(wData, w.wValid & ~wHeld, w.wData),
    wStrb < harborLoad(wStrb, w.wValid & ~wHeld, w.wStrb),
  ]);

  // Read: the request passes through, and the lane waits for the data.
  final rl = _Lanes(null, w.arAddr, wideBytes, narrowBytes);
  final rLane = Logic(name: '${name}_r_lane', width: max(1, rl.laneBits));
  final laneNow = rl.lane.zeroExtend(rLane.width);
  n.arValid <= w.arValid;
  n.arAddr <= rl.address(w.arAddr, na);
  n.arProt <= w.arProt;
  w.arReady <= n.arReady;
  w.rValid <= n.rValid;
  w.rResp <= n.rResp;
  n.rReady <= w.rReady;
  w.rData <= rl.place(n.rData, mux(w.arValid, laneNow, rLane));
  Sequential(c, reset: r, [
    rLane < harborLoad(rLane, w.arValid & n.arReady, laneNow),
  ]);
}

/// Ties a wide classic Wishbone port [w] of a fabric to the narrow slave
/// port [n]. [w] has ERR.
///
/// - A lane comes from the byte selects, or from the address when none is
///   set. The slave sees the address of its word, and the read data goes
///   back in that lane with 0 in the others.
/// - An access with selects in more than one lane, read or write, gets ERR
///   and never reaches the slave.
void harborNarrowWishbone({
  required WishboneInterface w,
  required WishboneInterface n,
}) {
  final l = _Lanes(
    w.sel,
    w.adr,
    w.config.dataWidth ~/ 8,
    n.config.dataWidth ~/ 8,
  );
  final bad = w.stb & l.multi;
  n.cyc <= w.cyc & ~bad;
  n.stb <= w.stb & ~bad;
  n.we <= w.we;
  n.adr <= l.address(w.adr, n.config.addressWidth);
  n.datMosi <= l.take(w.datMosi);
  n.sel <= l.take(w.sel);
  w.ack <= n.ack & ~bad;
  w.err! <= bad | (n.err ?? Const(0));
  w.datMiso <= l.place(n.datMiso);
}

/// Ties a wide TL-UL port [w] of a fabric to the narrow slave port [n].
///
/// The fabric sends the slave only Get, PutFullData and PutPartialData of
/// the size of a narrow word or less, and answers a bigger message denied
/// itself. So a message always sits in one lane, the lane of its address.
void harborNarrowTileLink(
  Logic c,
  Logic r, {
  required String name,
  required TileLinkInterface w,
  required TileLinkInterface n,
}) {
  final wideBytes = w.config.dataWidth ~/ 8;
  final l = _Lanes(null, w.aAddress, wideBytes, n.config.dataWidth ~/ 8);
  n.aValid <= w.aValid;
  w.aReady <= n.aReady;
  n.aOpcode <= w.aOpcode;
  n.aParam <= w.aParam;
  n.aSize <= w.aSize;
  n.aSource <= w.aSource;
  n.aAddress <= l.address(w.aAddress, n.config.addressWidth);
  n.aMask <= l.take(w.aMask);
  n.aData <= l.take(w.aData);
  n.aCorrupt <= w.aCorrupt;

  final held = Logic(name: '${name}_lane', width: max(1, l.laneBits));
  final now = l.lane.zeroExtend(held.width);
  w.dValid <= n.dValid;
  n.dReady <= w.dReady;
  w.dOpcode <= n.dOpcode;
  w.dParam <= n.dParam;
  w.dSize <= n.dSize;
  w.dSource <= n.dSource;
  w.dSink <= n.dSink;
  w.dData <= l.place(n.dData, mux(w.aValid, now, held));
  w.dCorrupt <= n.dCorrupt;
  w.dDenied <= n.dDenied;
  Sequential(c, reset: r, [held < harborLoad(held, w.aValid & n.aReady, now)]);
}
