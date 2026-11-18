import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:rohd_hcl/rohd_hcl.dart' show PriorityArbiter, RoundRobinArbiter;

import '../../arith/fpu_config.dart' show harborStableDefinitionName;
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
/// waiting. This can split a read-modify-write that a master holds under one
/// CYC. The arbiter has no cap by default. `HarborSoC.buildFabric` sets one
/// of 16 cycles on a fabric with two or more
/// masters, so a master that polls back to back cannot starve the others.
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
  }) : super(
         harborStableDefinitionName('WishboneArbiter', [
           'M$numMasters',
           ...config.definitionNameParts(),
           arbitration.name,
           if (maxGrantCycles != null) 'G$maxGrantCycles',
         ]),
         name: name ?? 'wishbone_arbiter',
       ) {
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

    final slaveTerm =
        (slave.ack | (slave.err ?? Const(0)) | (slave.rty ?? Const(0))).named(
          'slave_term',
        );
    final heldReg = harborWishboneGrant(
      clk: clk,
      reset: reset,
      requests: [for (final m in masters) m.cyc],
      terminate: slaveTerm,
      arbitration: arbitration,
      maxGrantCycles: cap,
    );
    final effGrant = [for (var i = 0; i < numMasters; i++) heldReg[i]];

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

/// The registered grant of a Wishbone arbiter over [requests], one-hot.
///
/// A master keeps the grant while its request stays high, and a new grant
/// shows one cycle after the request. With no request the grant stays on
/// the last owner. [terminate] is high when the owner's transfer ends. With
/// [maxGrantCycles], an owner that held the grant that long loses it at the
/// end of a transfer when another master waits (see [WishboneArbiter]). The
/// cap takes the grant only at a transfer end where [safeEnd] is high, so
/// the fabric can cut after a read or after a write that waited for its
/// response. A null [safeEnd] counts as high.
/// [prefix] goes in front of every signal name.
///
/// Wishbone has no LOCK signal, so a master that holds CYC for a read and a
/// write that follows it can lose the grant between the two, at a transfer
/// end that is safe to cut (see [safeEnd]).
///
/// With [realtime] (one flag per request) and [realtimeBeats], a request of
/// a real-time master wins over the others. An owner that is not real-time
/// loses the grant at the end of its transfer number [realtimeBeats] while
/// a real-time request waits, and [realtimeCut] is high during that last
/// transfer, so the fabric can end a burst there. Pass a fresh [Logic] as
/// [realtimeCut]. [strobes] (one per request) lets a real-time request take
/// the grant from an owner that holds CYC with STB low, when [safeEnd] was
/// high at the end of its last transfer (a null [safeEnd] counts as high).
/// With no real-time flag the logic is the same as with
/// none of the three.
Logic harborWishboneGrant({
  required Logic clk,
  required Logic reset,
  required List<Logic> requests,
  required Logic terminate,
  BusArbitration arbitration = BusArbitration.roundRobin,
  int? maxGrantCycles,
  List<bool>? realtime,
  int realtimeBeats = 16,
  Logic? realtimeCut,
  List<Logic>? strobes,
  Logic? safeEnd,
  String prefix = '',
}) {
  final numMasters = requests.length;
  final cap = maxGrantCycles;
  final hasRt = realtime != null && realtime.contains(true);
  if (hasRt && realtime.length != numMasters) {
    throw ArgumentError.value(
      realtime,
      'realtime',
      'needs one flag per request',
    );
  }
  final requestsVec = requests.rconcat().named('${prefix}requests');

  // A master that lost the grant to the cap stays out of arbitration until
  // another master takes the grant.
  final blocked = cap != null || hasRt
      ? Logic(name: '${prefix}blocked', width: numMasters)
      : null;
  final rtMask = hasRt
      ? Const(
          BigInt.parse(
            [
              for (var i = numMasters - 1; i >= 0; i--) realtime[i] ? '1' : '0',
            ].join(),
            radix: 2,
          ),
          width: numMasters,
        )
      : null;
  final rtReq = hasRt
      ? (requestsVec & rtMask!).named('${prefix}rt_requests')
      : null;
  var arbReqVec = blocked == null
      ? requestsVec
      : (requestsVec & ~blocked).named('${prefix}arb_requests');
  if (hasRt) {
    // A waiting real-time request shuts the other requests out. A real-time
    // master that the grant cap blocked does not, or no master would get the
    // grant until the block clears.
    final rtFree = arbReqVec & rtMask!;
    arbReqVec = mux(
      rtFree.or(),
      rtFree,
      arbReqVec,
    ).named('${prefix}rt_arb_requests');
  }
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

  // The grant is a register. A combinational grant would put arbitration,
  // address decode and the slave ACK in one long path.
  final grantVec = grantSignals.rconcat();
  final heldReg = Logic(name: '${prefix}held_grant', width: numMasters);
  final heldReqVec = (heldReg & requestsVec).named('${prefix}held_req');
  final heldValid = heldReqVec.or().named('${prefix}held_valid');
  final nextGrant = mux(
    requestsVec.or(),
    mux(heldValid, heldReqVec, grantVec),
    heldReg,
  ).named('${prefix}next_grant');

  if (cap == null && !hasRt) {
    Sequential(clk, [
      If(
        reset,
        then: [heldReg < Const(0, width: numMasters)],
        orElse: [heldReg < nextGrant],
      ),
    ]);
  } else {
    final count = cap != null
        ? Logic(name: '${prefix}hold_count', width: cap.bitLength)
        : null;
    // High when the last transfer that ended leaves the owner at a point
    // where CYC can drop (see [safeEnd]).
    final idleOk = safeEnd == null ? null : Logic(name: '${prefix}idle_ok');
    if (idleOk != null) {
      Sequential(clk, [
        If(
          reset,
          then: [idleOk < 1],
          orElse: [
            If(
              terminate | ~heldValid,
              then: [idleOk < mux(heldValid, safeEnd!, Const(1))],
            ),
          ],
        ),
      ]);
    }
    Logic? preempt;
    if (cap != null) {
      // A real-time owner gives the grant up to real-time requests only.
      final othersWait = hasRt
          ? mux(
              (heldReg & rtMask!).or(),
              (rtReq! & ~heldReg).or(),
              (requestsVec & ~heldReg).or(),
            ).named('${prefix}others_wait')
          : (requestsVec & ~heldReg).or().named('${prefix}others_wait');
      preempt =
          (heldValid &
                  count!.eq(cap) &
                  terminate &
                  (safeEnd ?? Const(1)) &
                  othersWait)
              .named('${prefix}preempt');
      if (strobes != null && idleOk != null) {
        // An owner that held the grant for the cap and holds CYC with STB
        // low loses it too, when its last transfer ended at a safe point.
        final ownerStb = (heldReg & strobes.rconcat()).or();
        preempt =
            (preempt |
                    (heldValid &
                        count.eq(cap) &
                        othersWait &
                        ~ownerStb &
                        idleOk))
                .named('${prefix}preempt_idle');
      }
    }
    final rtCount = hasRt
        ? Logic(name: '${prefix}rt_count', width: realtimeBeats.bitLength)
        : null;
    if (hasRt) {
      // The cut flag of a transfer is set when the transfer starts and holds
      // to its end, so CTI does not change in the middle of a transfer. A
      // non real-time owner is cut at the end of its transfer number
      // realtimeBeats, or at the end of the first transfer that starts after
      // that while a real-time request waits. An owner that holds CYC with
      // no transfer in progress loses the grant at once.
      final rtWaits = (rtReq! & ~heldReg).or().named('${prefix}rt_waits');
      final ownerOther = (heldValid & (heldReg & ~rtMask!).or()).named(
        '${prefix}owner_other',
      );
      final cutReg = Logic(name: '${prefix}rt_cut_reg');
      final cutNext = mux(
        heldValid,
        ownerOther & rtWaits & rtCount!.gte(realtimeBeats - 2),
        rtWaits & (realtimeBeats <= 1 ? Const(1) : Const(0)),
      ).named('${prefix}rt_cut_next');
      Sequential(clk, [
        If(
          reset,
          then: [cutReg < 0],
          orElse: [
            If(terminate | ~heldValid, then: [cutReg < cutNext]),
          ],
        ),
      ]);
      final cutBeat = (ownerOther & cutReg).named('${prefix}rt_cut_beat');
      if (realtimeCut != null) realtimeCut <= cutBeat;
      var rtPreempt = cutBeat & terminate;
      if (strobes != null) {
        final ownerStb = (heldReg & strobes.rconcat()).or();
        rtPreempt =
            rtPreempt |
            (ownerOther & rtWaits & ~ownerStb & (idleOk ?? Const(1)));
      }
      rtPreempt = rtPreempt.named('${prefix}rt_preempt');
      preempt = preempt == null
          ? rtPreempt
          : (preempt | rtPreempt).named('${prefix}preempt_any');
    }
    final freeVec = (requestsVec & ~blocked!).named('${prefix}free_requests');
    Sequential(clk, [
      If(
        reset,
        then: [
          heldReg < Const(0, width: numMasters),
          blocked < Const(0, width: numMasters),
          if (count != null) count < 0,
          if (rtCount != null) rtCount < 0,
        ],
        orElse: [
          If(
            preempt!,
            // An empty grant for one cycle drops CYC between the owners.
            then: [
              heldReg < Const(0, width: numMasters),
              blocked < heldReqVec,
              if (count != null) count < 0,
              if (rtCount != null) rtCount < 0,
            ],
            orElse: [
              heldReg < nextGrant,
              If(
                (heldReg & ~blocked).or() | ~freeVec.or(),
                then: [blocked < Const(0, width: numMasters)],
              ),
              if (count != null)
                If(
                  heldValid,
                  then: [
                    If(count.lt(cap!), then: [count < count + 1]),
                  ],
                  orElse: [count < 0],
                ),
              if (rtCount != null)
                If(
                  heldValid,
                  then: [
                    If(
                      terminate & rtCount.lt(realtimeBeats),
                      then: [rtCount < rtCount + 1],
                    ),
                  ],
                  orElse: [rtCount < 0],
                ),
            ],
          ),
        ],
      ),
    ]);
  }
  return heldReg;
}
