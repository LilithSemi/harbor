import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:rohd_hcl/rohd_hcl.dart' show PriorityArbiter, RoundRobinArbiter;

import '../bus.dart';
import 'wishbone_interface.dart';

/// Arbitrates N Wishbone masters onto a single Wishbone slave.
///
/// It exposes a consumer-role `master_$i` interface per master and a
/// provider-role `slave` interface. Selection is round-robin or fixed
/// priority, with grant locking: a granted master keeps the grant while it
/// holds CYC, so a cycle is never cut by re-arbitration. The grant is
/// registered, so a new owner starts one cycle after its request and the slave
/// always sees CYC low for one cycle between two owners. With no request the
/// grant stays on the last owner, which then starts its next cycle at once.
///
/// When [maxGrantCycles] is set, a master that has held the grant for that
/// many cycles loses it at the end of its next transfer if another master is
/// waiting. This can split a read-modify-write that a
/// master holds under one CYC, so it is off by default.
class WishboneArbiter extends BridgeModule {
  final int numMasters;

  /// Grant-hold cap in cycles. Null turns the cap off.
  final int? maxGrantCycles;

  /// Which master is currently granted (one-hot, registered).
  Logic get grant => output('grant');

  WishboneArbiter({
    required this.numMasters,
    required WishboneConfig config,
    BusArbitration arbitration = BusArbitration.roundRobin,
    this.maxGrantCycles,
    String? name,
  }) : super('WishboneArbiter_M$numMasters', name: name ?? 'wishbone_arbiter') {
    if (numMasters < 1) {
      throw ArgumentError('At least one master is required, got $numMasters');
    }
    final cap = maxGrantCycles;
    if (cap != null && cap < 1) {
      throw ArgumentError('maxGrantCycles must be >= 1, got $cap');
    }

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final clk = input('clk');
    final reset = input('reset');

    final masters = <WishboneInterface>[
      for (var i = 0; i < numMasters; i++)
        addInterface(
              WishboneInterface(config),
              name: 'master_$i',
              role: PairRole.consumer,
            ).internalInterface
            as WishboneInterface,
    ];

    final slave =
        addInterface(
              WishboneInterface(config),
              name: 'slave',
              role: PairRole.provider,
            ).internalInterface
            as WishboneInterface;

    final requestsVec = [
      for (final m in masters) m.cyc,
    ].rswizzle().named('requests');

    // A master that lost the grant to the cap stays out of arbitration until
    // another master takes the grant.
    final blocked = cap != null
        ? Logic(name: 'blocked', width: numMasters)
        : null;
    final arbReqVec = blocked == null
        ? requestsVec
        : (requestsVec & ~blocked).named('arb_requests');
    final arbRequests = [for (var i = 0; i < numMasters; i++) arbReqVec[i]];

    final grantSignals = <Logic>[];
    switch (arbitration) {
      case BusArbitration.roundRobin:
        final arb = RoundRobinArbiter(arbRequests, clk: clk, reset: reset);
        grantSignals.addAll(arb.grants);
      case BusArbitration.fixed:
      case BusArbitration.priority:
        final arb = PriorityArbiter(arbRequests);
        grantSignals.addAll(arb.grants);
    }

    // The grant is a register. It stays on one master while that master
    // holds CYC, and a fresh grant shows one cycle after the request. A
    // combinational grant would put arbitration, address decode and the slave
    // ACK in one long path.
    final grantVec = grantSignals.rswizzle();
    final heldReg = Logic(name: 'held_grant', width: numMasters);
    final heldReqVec = (heldReg & requestsVec).named('held_req');
    final heldValid = heldReqVec.or().named('held_valid');
    // With no request the grant parks on the last owner, so a master that
    // asks again pays no extra cycle.
    final nextGrant = mux(
      requestsVec.or(),
      mux(heldValid, heldReqVec, grantVec),
      heldReg,
    ).named('next_grant');
    final effGrant = [for (var i = 0; i < numMasters; i++) heldReg[i]];

    final slaveTerm =
        (slave.ack | (slave.err ?? Const(0)) | (slave.rty ?? Const(0))).named(
          'slave_term',
        );

    if (cap == null) {
      Sequential(clk, [
        If(
          reset,
          then: [heldReg < Const(0, width: numMasters)],
          orElse: [heldReg < nextGrant],
        ),
      ]);
    } else {
      final count = Logic(name: 'hold_count', width: cap.bitLength);
      final othersWait = (requestsVec & ~heldReg).or().named('others_wait');
      final preempt = (heldValid & count.eq(cap) & slaveTerm & othersWait)
          .named('preempt');
      final freeVec = (requestsVec & ~blocked!).named('free_requests');
      Sequential(clk, [
        If(
          reset,
          then: [
            heldReg < Const(0, width: numMasters),
            blocked < Const(0, width: numMasters),
            count < 0,
          ],
          orElse: [
            If(
              preempt,
              // An empty grant for one cycle drops CYC between the owners.
              then: [
                heldReg < Const(0, width: numMasters),
                blocked < heldReqVec,
                count < 0,
              ],
              orElse: [
                heldReg < nextGrant,
                If(
                  (heldReg & ~blocked).or() | ~freeVec.or(),
                  then: [blocked < Const(0, width: numMasters)],
                ),
                If(
                  heldValid,
                  then: [
                    If(count.lt(cap), then: [count < count + 1]),
                  ],
                  orElse: [count < 0],
                ),
              ],
            ),
          ],
        ),
      ]);
    }

    addOutput('grant', width: numMasters);
    grant <= heldReg;

    // Mux the granted master's request onto the slave.
    final requestPorts = [
      'CYC',
      'STB',
      'WE',
      'ADR',
      'DAT_MOSI',
      'SEL',
      ...wishboneOptionalRequestPorts.where((p) => slave.tryPort(p) != null),
    ];
    final muxed = {
      for (final p in requestPorts)
        p: Logic(name: 'muxed_${p.toLowerCase()}', width: slave.port(p).width),
    };
    Combinational([
      for (final e in muxed.entries) e.value < Const(0, width: e.value.width),
      for (var i = numMasters - 1; i >= 0; i--)
        If(
          effGrant[i],
          then: [
            for (final e in muxed.entries) e.value < masters[i].port(e.key),
          ],
        ),
    ]);
    for (final e in muxed.entries) {
      slave.port(e.key) <= e.value;
    }

    // Route the slave response back to the granted master. Read data is
    // broadcast, only the granted master consumes it.
    for (var i = 0; i < numMasters; i++) {
      final m = masters[i];
      final owns = (effGrant[i] & m.cyc & m.stb).named('owns_$i');
      m.ack <= slave.ack & owns;
      if (m.err != null) m.err! <= slave.err! & owns;
      if (m.rty != null) m.rty! <= slave.rty! & owns;
      m.datMiso <= slave.datMiso;
      if (m.tgdMiso != null) m.tgdMiso! <= slave.tgdMiso!;
    }
  }
}
