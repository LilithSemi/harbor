import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus.dart';
import 'wishbone_interface.dart';

/// Decodes a single Wishbone master to N Wishbone slaves based on
/// address mappings.
///
/// An access that hits no mapping ends at once. With ERR in [WishboneConfig]
/// it ends with ERR alone. Without ERR it ends with ACK and read data 0.
///
/// When [timeoutCycles] is set, a strobe that waits that many cycles without
/// an answer ends with ERR, or with ACK and [wishbonePoison] read data when
/// there is no ERR. The decoder then holds the slave in its cycle as an orphan
/// until the slave answers, and discards that answer. Only one slave is held
/// at a time. Accesses to the held slave wait and time out again. A timeout on
/// a second slave while one is held ends the access the same way, and the
/// decoder drops CYC to that second slave until the master drops CYC. So a
/// late answer from it cannot end a later transfer.
///
/// The `bus_error` output goes high on an unmapped access or a timeout and
/// stays high until reset.
class WishboneDecoder extends BridgeModule {
  /// Strobe cycles before a stuck access ends. Null turns the timeout off.
  final int? timeoutCycles;

  /// Sticky bus error status.
  Logic get busError => output('bus_error');

  WishboneDecoder(
    WishboneConfig config,
    List<HarborAddressMapping> mappings, {
    this.timeoutCycles,
    String name = 'wishbone_decoder',
  }) : super('WishboneDecoder_S${mappings.length}', name: name) {
    if (mappings.isEmpty) {
      throw ArgumentError('At least one slave is required.');
    }
    if (timeoutCycles != null && timeoutCycles! < 1) {
      throw ArgumentError('timeoutCycles must be >= 1, got $timeoutCycles');
    }

    final aw = config.addressWidth;
    final top = BigInt.one << aw;
    final errors = [
      ...validateAddressMappings(mappings),
      for (final m in mappings)
        if (m.range.start < 0 ||
            m.range.size < 1 ||
            BigInt.from(m.range.end) > top)
          'slave ${m.slaveIndex} (${m.range}) is outside the $aw-bit '
              'address space',
    ];
    if (errors.isNotEmpty) {
      throw ArgumentError('Invalid address mappings: ${errors.join("; ")}');
    }

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final clk = input('clk');
    final reset = input('reset');
    addOutput('bus_error');

    final m =
        addInterface(
              WishboneInterface(config),
              name: 'master',
              role: PairRole.consumer,
            ).internalInterface
            as WishboneInterface;

    final slaves = <WishboneInterface>[
      for (var i = 0; i < mappings.length; i++)
        addInterface(
              WishboneInterface(config),
              name: 'slave_$i',
              role: PairRole.provider,
            ).internalInterface
            as WishboneInterface,
    ];
    final n = slaves.length;
    final timeout = timeoutCycles;

    // Orphan slot state, present only with a timeout.
    final orphanValid = timeout != null ? Logic(name: 'orphan_valid') : null;
    final orphanOh = timeout != null
        ? Logic(name: 'orphan_slave', width: n)
        : null;
    // Slaves cut off after a timeout while the orphan slot was full. Their CYC
    // stays low until the master ends its cycle.
    final dropped = timeout != null
        ? Logic(name: 'dropped_slaves', width: n)
        : null;
    final oWe = Logic(name: 'orphan_we');
    final oAdr = Logic(name: 'orphan_adr', width: aw);
    final oDat = Logic(name: 'orphan_dat', width: config.dataWidth);
    final oSel = Logic(name: 'orphan_sel', width: config.effectiveSelWidth);
    final oTags = {
      for (final p in wishboneOptionalRequestPorts)
        if (m.tryPort(p) != null)
          p: Logic(
            name: 'orphan_${p.toLowerCase()}',
            width: m.tryPort(p)!.width,
          ),
    };

    final hitBits = <Logic>[];
    final selBits = <Logic>[];
    final orphBits = <Logic>[];

    for (var i = 0; i < n; i++) {
      final range = mappings[i].range;
      final s = slaves[i];
      final size = range.size;

      // A power-of-two region aligned to its own size decodes by matching the
      // high address bits. Any other region uses a range compare.
      final isPow2Aligned =
          (size & (size - 1)) == 0 && (range.start & (size - 1)) == 0;
      final Logic inRange;
      if (isPow2Aligned && size.bitLength - 1 < aw) {
        final low = size.bitLength - 1;
        inRange = m.adr
            .getRange(low)
            .eq(Const(range.start >> low, width: aw - low));
      } else if (isPow2Aligned) {
        inRange = Const(1);
      } else {
        // A region that ends at the top of the address space has no upper
        // bound to compare, and its end does not fit in aw bits.
        final atTop = BigInt.from(range.end) == top;
        inRange =
            (range.start == 0
                ? Const(1)
                : m.adr.gte(Const(range.start, width: aw))) &
            (atTop ? Const(1) : m.adr.lt(Const(range.end, width: aw)));
      }

      final hit = (m.cyc & inRange).named('hit_$i');
      hitBits.add(hit);

      final base = Const(range.start, width: aw);
      if (timeout == null) {
        selBits.add(hit);
        s.cyc <= hit;
        s.stb <= m.stb & hit;
        s.we <= m.we;
        s.adr <= m.adr - base;
        s.datMosi <= m.datMosi;
        s.sel <= m.sel;
        for (final p in wishboneOptionalRequestPorts) {
          final sp = s.tryPort(p);
          if (sp != null) sp <= m.port(p);
        }
      } else {
        final orph = (orphanValid! & orphanOh![i]).named('orphan_$i');
        orphBits.add(orph);
        final live = (hit & ~dropped![i]).named('live_$i');
        selBits.add((live & ~orph).named('sel_$i'));
        s.cyc <= orph | live;
        s.stb <= orph | (m.stb & live);
        s.we <= mux(orph, oWe, m.we);
        s.adr <= mux(orph, oAdr, m.adr) - base;
        s.datMosi <= mux(orph, oDat, m.datMosi);
        s.sel <= mux(orph, oSel, m.sel);
        for (final p in wishboneOptionalRequestPorts) {
          final sp = s.tryPort(p);
          if (sp != null) sp <= mux(orph, oTags[p]!, m.port(p));
        }
      }
    }

    final anyHit = hitBits.reduce((a, b) => a | b).named('any_hit');
    final strobe = (m.cyc & m.stb).named('strobe');
    final noMatch = (strobe & ~anyHit).named('no_match');

    final slaveAck = Logic(name: 'slave_ack');
    final slaveErr = Logic(name: 'slave_err');
    final slaveRty = Logic(name: 'slave_rty');
    final slaveData = Logic(name: 'slave_data', width: config.dataWidth);
    final slaveTgd = m.tgdMiso != null
        ? Logic(name: 'slave_tgd', width: m.tgdMiso!.width)
        : null;

    Combinational([
      slaveAck < 0,
      slaveErr < 0,
      slaveRty < 0,
      slaveData < 0,
      if (slaveTgd != null) slaveTgd < 0,
      for (var i = n - 1; i >= 0; i--)
        If(
          selBits[i],
          then: [
            slaveAck < slaves[i].ack,
            slaveErr < (slaves[i].err ?? Const(0)),
            slaveRty < (slaves[i].rty ?? Const(0)),
            slaveData < slaves[i].datMiso,
            if (slaveTgd != null) slaveTgd < slaves[i].tgdMiso!,
          ],
        ),
    ]);

    // Responses count only while the master strobes.
    final sAck = (slaveAck & m.stb).named('s_ack');
    final sErr = (slaveErr & m.stb).named('s_err');
    final sRty = (slaveRty & m.stb).named('s_rty');

    Logic timedOut = Const(0);
    Logic? count;
    if (timeout != null) {
      count = Logic(name: 'timeout_count', width: timeout.bitLength);
      timedOut = (strobe & anyHit & ~(sAck | sErr | sRty) & count.eq(timeout))
          .named('timed_out');
    }

    final hasErr = m.err != null;
    final fault = (noMatch | timedOut).named('fault');
    if (hasErr) {
      m.ack <= sAck;
      m.err! <= sErr | fault;
      m.datMiso <= slaveData;
    } else {
      m.ack <= sAck | fault;
      m.datMiso <= mux(timedOut, wishbonePoison(config.dataWidth), slaveData);
    }
    if (m.rty != null) m.rty! <= sRty;
    if (m.tgdMiso != null) m.tgdMiso! <= slaveTgd!;

    final masterTerm = (sAck | sErr | sRty | fault).named('master_term');
    final busErr = Logic(name: 'bus_error_r');
    output('bus_error') <= busErr;

    Sequential(clk, [
      If(
        reset,
        then: [
          busErr < 0,
          if (count != null) count < 0,
          if (orphanValid != null) orphanValid < 0,
          if (orphanOh != null) orphanOh < 0,
          if (dropped != null) dropped < 0,
        ],
        orElse: [
          busErr < (busErr | fault),
          if (count != null)
            If(
              strobe & ~masterTerm,
              then: [
                If(count.lt(timeout!), then: [count < count + 1]),
              ],
              orElse: [count < 0],
            ),
          if (dropped != null)
            If(
              ~m.cyc,
              then: [dropped < 0],
              orElse: [
                If(
                  timedOut & orphanValid!,
                  then: [dropped < (dropped | hitBits.rswizzle())],
                ),
              ],
            ),
          if (orphanValid != null)
            If(
              orphanValid,
              then: [
                // The held slave answers. Its answer has no owner.
                If(
                  [
                    for (var i = 0; i < n; i++)
                      orphBits[i] &
                          (slaves[i].ack |
                              (slaves[i].err ?? Const(0)) |
                              (slaves[i].rty ?? Const(0))),
                  ].reduce((a, b) => a | b),
                  then: [orphanValid < 0],
                ),
              ],
              orElse: [
                If(
                  timedOut,
                  then: [
                    orphanValid < 1,
                    orphanOh! < hitBits.rswizzle(),
                    oWe < m.we,
                    oAdr < m.adr,
                    oDat < m.datMosi,
                    oSel < m.sel,
                    for (final e in oTags.entries) e.value < m.port(e.key),
                  ],
                ),
              ],
            ),
        ],
      ),
    ]);
  }
}
