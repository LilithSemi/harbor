import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus.dart';
import 'wishbone_interface.dart';

/// Decodes a single Wishbone master to N Wishbone slaves based on
/// address mappings.
class WishboneDecoder extends BridgeModule {
  WishboneDecoder(
    WishboneConfig config,
    List<HarborAddressMapping> mappings, {
    String name = 'wishbone_decoder',
  }) : super('WishboneDecoder_S${mappings.length}', name: name) {
    if (mappings.isEmpty) {
      throw ArgumentError('At least one slave is required.');
    }

    final errors = validateAddressMappings(mappings);
    if (errors.isNotEmpty) {
      throw ArgumentError('Invalid address mappings: ${errors.join("; ")}');
    }

    // Master: consumer role (we receive from bus master)
    final masterRef = addInterface(
      WishboneInterface(config),
      name: 'master',
      role: PairRole.consumer,
    );
    final m = masterRef.internalInterface as WishboneInterface;

    // Slaves: provider role (we drive to peripherals)
    final slaveIntfs = <WishboneInterface>[];
    for (var i = 0; i < mappings.length; i++) {
      final slaveRef = addInterface(
        WishboneInterface(config),
        name: 'slave_$i',
        role: PairRole.provider,
      );
      slaveIntfs.add(slaveRef.internalInterface as WishboneInterface);
    }

    // Address decode + route
    final hitBits = <Logic>[];
    final slaveAcks = <Logic>[];
    final slaveDatas = <Logic>[];

    for (var i = 0; i < mappings.length; i++) {
      final range = mappings[i].range;
      final s = slaveIntfs[i];
      final aw = config.addressWidth;
      final size = range.end - range.start;

      // A power-of-two region aligned to its own size decodes by matching the
      // high address bits (one LUT compare), instead of the `>= base & < end`
      // pair of carry-chain magnitude compares. This decode is the fabric's
      // critical path, so the shorter form directly raises the clock ceiling.
      // Any irregular region falls back to the general range compare.
      final isPow2Aligned =
          size > 0 &&
          (size & (size - 1)) == 0 &&
          (range.start & (size - 1)) == 0;
      final Logic inRange;
      if (isPow2Aligned && size.bitLength - 1 < aw) {
        final low = size.bitLength - 1; // log2(size)
        inRange = m.adr
            .getRange(low)
            .eq(Const(range.start >> low, width: aw - low));
      } else if (isPow2Aligned) {
        inRange = Const(1); // region spans the whole address space
      } else {
        inRange =
            m.adr.gte(Const(range.start, width: aw)) &
            m.adr.lt(Const(range.end, width: aw));
      }

      final hitI = (m.cyc & inRange).named('hit_$i');
      hitBits.add(hitI);

      s.cyc <= m.cyc & hitI;
      s.stb <= m.stb & hitI;
      s.we <= m.we;
      s.adr <= m.adr - Const(range.start, width: config.addressWidth);
      s.datMosi <= m.datMosi;
      s.sel <= m.sel;

      slaveAcks.add(s.ack);
      slaveDatas.add(s.datMiso);
    }

    // Bus-error termination for unmapped addresses. A cycle that decodes to no
    // slave must be TERMINATED, not left with ack deasserted forever: an
    // ack-only master (the caches, CPU) stalls on the missing ack and wedges the
    // whole bus - the CPU hangs, and even the debug SBA can no longer read
    // memory. Instead, ack the cycle (so it completes and the bus frees) and
    // raise err (so an err-aware master faults it as a bus/access error).
    final anyHit = hitBits.reduce((a, b) => a | b).named('any_hit');
    final noMatch = (m.cyc & m.stb & ~anyHit).named('no_match');

    // Mux responses back to master
    final muxedAck = Logic(name: 'muxed_ack');
    final muxedData = Logic(name: 'muxed_data', width: config.dataWidth);

    Combinational([
      muxedAck < Const(0),
      muxedData < Const(0, width: config.dataWidth),
      for (var i = mappings.length - 1; i >= 0; i--)
        If(
          hitBits[i],
          then: [muxedAck < slaveAcks[i], muxedData < slaveDatas[i]],
        ),
      // Self-terminate an unmapped access so the bus never wedges.
      If(noMatch, then: [muxedAck < Const(1)]),
    ]);

    m.ack <= muxedAck;
    m.datMiso <= muxedData;
    if (m.err != null) {
      m.err! <=
          noMatch |
              [
                for (var i = 0; i < mappings.length; i++)
                  hitBits[i] & m.stb & slaveIntfs[i].err!,
              ].reduce((a, b) => a | b);
    }
  }
}
