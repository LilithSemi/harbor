import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:rohd_hcl/rohd_hcl.dart' show PriorityArbiter, RoundRobinArbiter;

import '../bus.dart';
import 'wishbone_interface.dart';

/// Arbitrates N Wishbone masters onto a single Wishbone slave.
///
/// A [BridgeModule] so it composes via `connectInterfaces`: it exposes a
/// consumer-role `master_$i` interface per master (it receives their requests
/// and drives their responses) and a provider-role `slave` interface (it drives
/// the merged transaction toward the downstream decoder/slave). Round-robin or
/// fixed/priority selection, with GRANT LOCKING: once a master is granted it
/// holds the grant while it keeps CYC asserted, so a transaction is never
/// interrupted by re-arbitration (the bare round-robin re-picks every cycle,
/// which livelocks two simultaneously-requesting masters).
class WishboneArbiter extends BridgeModule {
  final int numMasters;

  /// Which master is currently granted (one-hot, effective/locked grant).
  Logic get grant => output('grant');

  WishboneArbiter({
    required this.numMasters,
    required WishboneConfig config,
    BusArbitration arbitration = BusArbitration.roundRobin,
    String? name,
  }) : super('WishboneArbiter_M$numMasters', name: name ?? 'wishbone_arbiter') {
    if (numMasters < 1) {
      throw ArgumentError('At least one master is required, got $numMasters');
    }

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final clk = input('clk');
    final reset = input('reset');

    // Per-master consumer interfaces (we read requests, drive responses).
    final masters = <WishboneInterface>[
      for (var i = 0; i < numMasters; i++)
        addInterface(
              WishboneInterface(config),
              name: 'master_$i',
              role: PairRole.consumer,
            ).internalInterface
            as WishboneInterface,
    ];

    // Provider interface toward the downstream slave (we drive the request).
    final slave =
        addInterface(
              WishboneInterface(config),
              name: 'slave',
              role: PairRole.provider,
            ).internalInterface
            as WishboneInterface;

    // Request = each master's CYC.
    final requests = [for (final m in masters) m.cyc];

    final grantSignals = <Logic>[];
    switch (arbitration) {
      case BusArbitration.roundRobin:
        final arb = RoundRobinArbiter(requests, clk: clk, reset: reset);
        grantSignals.addAll(arb.grants);
      case BusArbitration.fixed:
      case BusArbitration.priority:
        final arb = PriorityArbiter(requests);
        grantSignals.addAll(arb.grants);
    }

    // Grant locking: hold the grant to a master while it keeps CYC asserted.
    final requestsVec = requests.rswizzle();
    final grantVec = grantSignals.rswizzle();
    final heldReg = Logic(name: 'held_grant', width: numMasters);
    final heldReqVec = (heldReg & requestsVec).named('held_req');
    final heldValid = heldReqVec.or().named('held_valid');
    final effVec = mux(heldValid, heldReqVec, grantVec).named('eff_grant');
    Sequential(clk, [
      If(
        reset,
        then: [heldReg < Const(0, width: numMasters)],
        orElse: [heldReg < effVec],
      ),
    ]);
    final effGrant = [for (var i = 0; i < numMasters; i++) effVec[i]];

    addOutput('grant', width: numMasters);
    grant <= effVec;

    // Mux the granted master's request onto the slave.
    final muxedCyc = Logic(name: 'muxed_cyc');
    final muxedStb = Logic(name: 'muxed_stb');
    final muxedWe = Logic(name: 'muxed_we');
    final muxedAdr = Logic(name: 'muxed_adr', width: config.addressWidth);
    final muxedDatMosi = Logic(name: 'muxed_dat_mosi', width: config.dataWidth);
    final muxedSel = Logic(name: 'muxed_sel', width: config.effectiveSelWidth);

    Combinational([
      muxedCyc < Const(0),
      muxedStb < Const(0),
      muxedWe < Const(0),
      muxedAdr < Const(0, width: config.addressWidth),
      muxedDatMosi < Const(0, width: config.dataWidth),
      muxedSel < Const(0, width: config.effectiveSelWidth),
      for (var i = numMasters - 1; i >= 0; i--)
        If(
          effGrant[i],
          then: [
            muxedCyc < masters[i].cyc,
            muxedStb < masters[i].stb,
            muxedWe < masters[i].we,
            muxedAdr < masters[i].adr,
            muxedDatMosi < masters[i].datMosi,
            muxedSel < masters[i].sel,
          ],
        ),
    ]);

    slave.cyc <= muxedCyc;
    slave.stb <= muxedStb;
    slave.we <= muxedWe;
    slave.adr <= muxedAdr;
    slave.datMosi <= muxedDatMosi;
    slave.sel <= muxedSel;

    // Route the slave response back to each master (ACK gated by grant,
    // DAT_MISO broadcast: only the granted master consumes it).
    for (var i = 0; i < numMasters; i++) {
      masters[i].ack <= slave.ack & effGrant[i];
      if (masters[i].err != null) {
        masters[i].err! <=
            slave.err! & effGrant[i] & masters[i].cyc & masters[i].stb;
      }
      masters[i].datMiso <= slave.datMiso;
    }
  }
}
