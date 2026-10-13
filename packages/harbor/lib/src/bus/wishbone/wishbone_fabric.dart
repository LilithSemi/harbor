import 'package:rohd/rohd.dart';

import '../../arith/fpu_config.dart' show harborStableDefinitionName;
import '../fabric.dart';
import '../fabric_util.dart';
import '../port/fabric_kind.dart';
import '../port/reg_fifo.dart';
import 'wishbone_arbiter.dart';
import 'wishbone_interface.dart';

/// A Wishbone fabric. Build it with [HarborFabric.build].
///
/// On a shared fabric the [grant] output shows the master that owns the bus,
/// one hot. It holds the last owner while no master requests.
///
/// - Register ports are classic and memory ports also do registered
///   feedback bursts, set by [HarborFabricMaster.memory] and
///   [HarborFabricSlave.memory]. A memory port has ERR, CTI and BTE.
/// - shared: one grant over all masters, then an address decode. crossbar:
///   one grant per slave over the masters that address it.
/// - A grant is a register, as in [WishboneArbiter]. A master keeps it while
///   it holds CYC (on a crossbar, while it holds CYC to that slave), and
///   with `maxGrantCycles` it loses it at the end of a transfer once it held
///   it that long and another master waits.
/// - Requests, CTI and BTE pass through, so a burst reaches the slave as
///   the master sends it. A slave sees the full address, or the offset in
///   its region with [HarborFabricSlave.offset].
/// - Every port has 1 transfer in flight, so `outstanding` must be 1.
/// - On a crossbar the grant follows CYC and the address. A master that
///   holds CYC with STB low keeps the grant of the slave its stale ADR
///   points at, and `maxGrantCycles` cannot take it back, because no
///   transfer ends.
///
/// An access that hits no slave ends with ERR. A slave with a timeout that
/// does not answer a strobe in time is cut off until reset: CYC to it drops,
/// its late answers are dropped, and every access to it ends with ERR. A
/// master with no ERR gets ACK instead, with read data 0 for an access that
/// hits no slave and [wishbonePoison] for a slave error. The sticky
/// `fold_error` output records each such ACK.
class HarborWishboneFabric extends HarborFabricModule {
  /// Topology of the fabric.
  final HarborFabricTopology topology;

  /// Masters, in port order.
  final List<HarborFabricMaster> masters;

  /// Slaves, in port order.
  final List<HarborFabricSlave> slaves;

  /// The aligned block of a memory burst, for the address map check.
  final int wishboneBurstBeats;

  /// Grant hold cap in cycles. Null turns the cap off.
  final int? maxGrantCycles;

  /// The owner of the bus, one bit per master. Null on a crossbar.
  Logic? get grant => tryOutput('grant');

  HarborWishboneFabric({
    required this.topology,
    required Logic clk,
    required Logic reset,
    required this.masters,
    required this.slaves,
    this.wishboneBurstBeats = 8,
    this.maxGrantCycles,
    super.name = 'fabric',
  }) : super(
         definitionName: _definitionName(
           topology,
           masters,
           slaves,
           wishboneBurstBeats,
           maxGrantCycles,
         ),
       ) {
    final cap = maxGrantCycles;
    if (cap != null && cap < 1) {
      throw ArgumentError.value(cap, 'maxGrantCycles', 'must be >= 1');
    }
    if (wishboneBurstBeats < 1) {
      throw ArgumentError.value(
        wishboneBurstBeats,
        'wishboneBurstBeats',
        'must be >= 1',
      );
    }
    final c0 = _wb(masters.first.name, masters.first.interface).config;
    final addrW = c0.addressWidth;
    final dataW = c0.dataWidth;
    for (final (name, intf, memory, outstanding) in [
      for (final m in masters)
        (
          m.name,
          m.interface,
          m.memory,
          m.outstandingOn(HarborFabricKind.wishbone),
        ),
      for (final s in slaves) (s.name, s.interface, s.memory, s.outstanding),
    ]) {
      final w = _wb(name, intf).config;
      if (w.addressWidth != addrW || w.dataWidth != dataW) {
        throw ArgumentError(
          '$name: Wishbone widths (addr ${w.addressWidth}, data '
          '${w.dataWidth}) differ from addr $addrW, data $dataW',
        );
      }
      if (w.effectiveSelWidth != dataW ~/ 8 ||
          w.useRty ||
          w.tgaWidth != 0 ||
          w.tgdWidth != 0) {
        throw ArgumentError(
          '$name: a Wishbone fabric port has byte selects and no RTY or tags',
        );
      }
      if (memory && !(w.useErr && w.useCti && w.useBte)) {
        throw ArgumentError('$name: a Wishbone memory port has ERR, CTI, BTE');
      }
      if (outstanding != 1) {
        throw ArgumentError(
          '$name: a Wishbone port has outstanding 1, got $outstanding',
        );
      }
    }
    HarborFabric.checkPorts(
      kind: HarborFabricKind.wishbone,
      masters: masters,
      slaves: slaves,
      addressWidth: addrW,
      dataWidth: dataW,
      wishboneBurstBeats: wishboneBurstBeats,
    );

    final c = addInput('clk', clk);
    final r = addInput('reset', reset);
    addOutput('bus_error');

    final nm = masters.length;
    final ns = slaves.length;
    final ma = [
      for (final m in masters)
        (m.interface as WishboneInterface).clone()..pairConnectIO(
          this,
          m.interface,
          PairRole.consumer,
          uniquify: (n) => '${m.name}_$n',
        ),
    ];
    final sa = [
      for (final s in slaves)
        (s.interface as WishboneInterface).clone()..pairConnectIO(
          this,
          s.interface,
          PairRole.provider,
          uniquify: (n) => '${s.name}_$n',
        ),
    ];

    // Request fields of each master, CTI and BTE 0 when it has none.
    final reqW = [1, addrW, dataW, dataW ~/ 8, 3, 2];
    final mReq = [
      for (final a in ma)
        [
          a.we,
          a.adr,
          a.datMosi,
          a.sel,
          a.cti ?? Const(0, width: 3),
          a.bte ?? Const(0, width: 2),
        ].rswizzle(),
    ];
    final hit = [
      for (var m = 0; m < nm; m++)
        [
          for (final s in slaves)
            masters[m].reaches(s.name) ? inRange(ma[m].adr, s.range) : Const(0),
        ],
    ];
    final noHit = [for (var m = 0; m < nm; m++) ~anyOf(hit[m])];

    final dead = [
      for (var t = 0; t < ns; t++)
        slaves[t].timeout > 0
            ? Logic(name: '${slaves[t].name}_cut_off')
            : Const(0),
    ];
    // Transfers that end at each slave, for the grant cap.
    final term = [for (var t = 0; t < ns; t++) Logic()];

    // A slave that only one master can reach needs no grant register.
    Logic grantOf(List<Logic> req, Logic term, String prefix, int reachers) =>
        reachers <= 1
        ? Const(1, width: nm, fill: true)
        : harborWishboneGrant(
            clk: c,
            reset: r,
            requests: req,
            terminate: term,
            maxGrantCycles: cap,
            prefix: prefix,
          );

    // own[t][m]: master m drives slave t this cycle.
    final own = <List<Logic>>[];
    final errOwn = <Logic>[];
    if (topology == HarborFabricTopology.crossbar) {
      for (var t = 0; t < ns; t++) {
        final req = [for (var m = 0; m < nm; m++) ma[m].cyc & hit[m][t]];
        final reachers = masters.where((m) => m.reaches(slaves[t].name));
        final g = grantOf(req, term[t], '${slaves[t].name}_', reachers.length);
        own.add([for (var m = 0; m < nm; m++) g[m] & req[m]]);
      }
      for (var m = 0; m < nm; m++) {
        errOwn.add(ma[m].cyc & ma[m].stb & noHit[m]);
      }
    } else {
      final busTerm = Logic();
      final g = grantOf([for (final a in ma) a.cyc], busTerm, 'bus_', nm);
      addOutput('grant', width: nm) <= g;
      final gm = [for (var m = 0; m < nm; m++) g[m] & ma[m].cyc];
      for (var t = 0; t < ns; t++) {
        own.add([for (var m = 0; m < nm; m++) gm[m] & hit[m][t]]);
      }
      for (var m = 0; m < nm; m++) {
        errOwn.add(gm[m] & ma[m].stb & noHit[m]);
      }
      busTerm <= anyOf([for (var t = 0; t < ns; t++) term[t]]) | anyOf(errOwn);
    }

    // Slave sides, and what each answers to its owner.
    final sAck = <Logic>[];
    final sErr = <Logic>[];
    for (var t = 0; t < ns; t++) {
      final s = sa[t];
      final p = slaves[t].name;
      final o = own[t];
      final cyc = anyOf(o).named('${p}_owned');
      final stb = anyOf([
        for (var m = 0; m < nm; m++) o[m] & ma[m].stb,
      ]).named('${p}_strobed');
      final [we, adr, dat, sel, cti, bte] = harborUnpack(pick(o, mReq), reqW);
      s.cyc <= cyc & ~dead[t];
      s.stb <= stb & ~dead[t];
      s.we <= we;
      final base = slaves[t].base;
      s.adr <= (base == 0 ? adr : adr - Const(base, width: addrW));
      s.datMosi <= dat;
      s.sel <= sel;
      if (s.cti != null) s.cti! <= cti;
      if (s.bte != null) s.bte! <= bte;

      final ack = (s.ack & stb & ~dead[t]).named('${p}_ack_in');
      final err = ((s.err ?? Const(0)) & stb & ~dead[t]) | (stb & dead[t]);
      sAck.add(ack);
      sErr.add(err.named('${p}_err_in'));
      term[t] <= ack | err;

      final timeout = slaves[t].timeout;
      if (timeout > 0) {
        final tw = widthOf(timeout);
        final timer = Logic(name: '${p}_timer', width: tw);
        Sequential(c, reset: r, [
          If.block([
            Iff(dead[t] | ~stb | s.ack | (s.err ?? Const(0)), [timer < 0]),
            ElseIf(timer.eq(Const(timeout - 1, width: tw)), [dead[t] < 1]),
            Else([timer < timer + 1]),
          ]),
        ]);
      }
    }
    output('bus_error') <= anyOf(dead);

    // Answers to each master.
    final folds = <Logic>[];
    for (var m = 0; m < nm; m++) {
      final a = ma[m];
      final from = [for (var t = 0; t < ns; t++) own[t][m]];
      final ack = anyOf([for (var t = 0; t < ns; t++) from[t] & sAck[t]]);
      final slaveErr = anyOf([for (var t = 0; t < ns; t++) from[t] & sErr[t]]);
      final err = slaveErr | errOwn[m];
      final data = ns == 0
          ? Const(0, width: dataW)
          : pick(from, [for (final s in sa) s.datMiso]);
      if (a.err != null) {
        a.ack <= ack;
        a.err! <= err;
        a.datMiso <= data;
      } else {
        // No slave drives data on an unmapped access, so it reads 0.
        a.ack <= ack | err;
        a.datMiso <= mux(slaveErr, wishbonePoison(dataW), data);
        folds.add(err);
      }
    }
    if (folds.isNotEmpty) {
      final fold = Logic(name: 'fold_error_r');
      Sequential(c, reset: r, [fold < (fold | anyOf(folds))]);
      addOutput('fold_error') <= fold;
    }
  }

  static WishboneInterface _wb(String name, PairInterface p) => switch (p) {
    final WishboneInterface w => w,
    _ => throw ArgumentError(
      '$name: a Wishbone fabric takes WishboneInterface ports, got $p',
    ),
  };

  static String _definitionName(
    HarborFabricTopology topology,
    List<HarborFabricMaster> masters,
    List<HarborFabricSlave> slaves,
    int burstBeats,
    int? maxGrantCycles,
  ) {
    if (masters.isEmpty) {
      throw ArgumentError.value(masters, 'masters', 'must not be empty');
    }
    final c0 = _wb(masters.first.name, masters.first.interface).config;
    String port(String name, PairInterface p, bool memory) {
      final w = _wb(name, p).config;
      return '${memory ? 'B' : 'C'}${w.useErr ? 'e' : ''}'
          '${w.useCti ? 'c' : ''}${w.useBte ? 'x' : ''}';
    }

    return harborStableDefinitionName('HarborWishboneFabric', [
      topology.name,
      'a${c0.addressWidth}',
      'd${c0.dataWidth}',
      'b$burstBeats',
      'g${maxGrantCycles ?? 0}',
      for (final m in masters)
        'M${m.name}${port(m.name, m.interface, m.memory)}'
            '${m.reachTag(slaves)}',
      for (final s in slaves)
        'S${s.name}${port(s.name, s.interface, s.memory)}'
            '${s.offset ? 'O' : ''}t${s.timeout}'
            'r${s.range.start.toRadixString(16)}'
            'x${s.range.size.toRadixString(16)}',
    ]);
  }
}
