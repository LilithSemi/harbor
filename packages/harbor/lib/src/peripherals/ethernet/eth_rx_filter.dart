import 'package:rohd/rohd.dart';

import 'eth_config.dart';

/// Ethernet receive address filter.
///
/// `start` clears the filter at the start of a frame. Each `in_valid` cycle
/// gives the next destination address byte. After the sixth byte `done` goes
/// high and `keep` tells if the frame passes. The filter keeps a frame for the
/// own unicast address, for broadcast, for a multicast address whose hash bit
/// is set, and for all frames when `promisc` is high.
///
/// `mac_addr` bits [8i+7:8i] are address byte i, byte 0 first on the wire.
///
/// The hash bit index is the top 6 bits of the Linux `ether_crc` of the
/// address, which is `bitrev32(crc32_le(~0, addr, 6))` with no inversion.
/// Linux drivers with a 64-bit table, such as ethoc, use `ether_crc >> 26`.
/// The index is thus bits 0 to 5 of the CRC state, bit 0 as the high bit.
/// `crc_next` is that CRC state after the byte on `in_data`.
class HarborEthRxFilter extends Module {
  /// Configuration of the MAC that contains this filter.
  final HarborEthernetConfig config;

  /// High after the sixth address byte until the next `start`.
  Logic get done => output('done');

  /// High when the frame passes. Valid with [done].
  Logic get keep => output('keep');

  /// Multicast address that is not broadcast. Valid with [done].
  Logic get mcast => output('mcast');

  /// Broadcast address. Valid with [done].
  Logic get bcast => output('bcast');

  HarborEthRxFilter(
    Logic clk,
    Logic reset, {
    required this.config,
    required Logic start,
    required Logic inValid,
    required Logic inData,
    required Logic macAddr,
    Logic? crcNext,
    Logic? mcHash,
    Logic? promisc,
    super.name = 'eth_rx_filter',
  }) : super(definitionName: _definitionName(config)) {
    if (config.multicastHash && (crcNext == null || mcHash == null)) {
      throw ArgumentError('multicastHash needs crcNext and mcHash');
    }
    if (config.promiscuous && promisc == null) {
      throw ArgumentError('promiscuous needs promisc');
    }

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    start = addInput('start', start);
    inValid = addInput('in_valid', inValid);
    inData = addInput('in_data', inData, width: 8);
    macAddr = addInput('mac_addr', macAddr, width: 48);

    final done = addOutput('done');
    final keepOut = addOutput('keep');
    final keep = Logic(name: 'keep_r');
    final mcast = addOutput('mcast');
    final bcast = addOutput('bcast');

    final idx = Logic(name: 'idx', width: 3);
    final own = Logic(name: 'own');
    final allOnes = Logic(name: 'all_ones');
    final group = Logic(name: 'group');

    final macByte = mux(
      idx.eq(Const(0, width: 3)),
      macAddr.slice(7, 0),
      mux(
        idx.eq(Const(1, width: 3)),
        macAddr.slice(15, 8),
        mux(
          idx.eq(Const(2, width: 3)),
          macAddr.slice(23, 16),
          mux(
            idx.eq(Const(3, width: 3)),
            macAddr.slice(31, 24),
            mux(
              idx.eq(Const(4, width: 3)),
              macAddr.slice(39, 32),
              macAddr.slice(47, 40),
            ),
          ),
        ),
      ),
    ).named('mac_byte');

    final ownNext = (own & inData.eq(macByte)).named('own_next');
    final allOnesNext = (allOnes & inData.eq(Const(0xFF, width: 8))).named(
      'all_ones_next',
    );
    final isMcast = (group & ~allOnesNext).named('is_mcast');

    var pass = ownNext | allOnesNext;
    // The hash index is a flop, set with the sixth byte. In the next cycle,
    // the first with `done`, `keep` reads the table bit from it, and the
    // bit goes into `hash_keep` for the rest of the frame. So a new MC_HASH
    // in a frame does not change its decision.
    Logic hashHit = Const(0);
    if (config.multicastHash) {
      final hashIdx = Logic(name: 'hash_idx', width: 6);
      final hashMcast = Logic(name: 'hash_mcast');
      final hashFirst = Logic(name: 'hash_first');
      final hashKeep = Logic(name: 'hash_keep');
      final c = addInput('crc_next', crcNext!, width: 32);
      final table = addInput('mc_hash', mcHash!, width: 64);
      final index = [
        for (var i = 0; i < 6; i++) c[i],
      ].swizzle().named('hash_index');
      final live = (hashMcast & table[hashIdx]).named('hash_live');
      hashHit = mux(hashFirst, live, hashKeep).named('hash_hit');
      Sequential(clk, [
        hashFirst < 0,
        If.block([
          Iff(start, [hashMcast < 0, hashKeep < 0]),
          Iff(inValid & ~done & idx.eq(Const(5, width: 3)), [
            hashIdx < index,
            hashMcast < isMcast,
            hashFirst < 1,
          ]),
          Iff(hashFirst, [hashKeep < live]),
        ]),
      ], reset: reset);
    }
    if (config.promiscuous) {
      pass = pass | addInput('promisc', promisc!);
    }
    keepOut <= keep | hashHit;

    Sequential(clk, [
      If.block([
        Iff(start, [
          idx < Const(0, width: 3),
          own < 1,
          allOnes < 1,
          done < 0,
          keep < 0,
          mcast < 0,
          bcast < 0,
        ]),
        Iff(inValid & ~done, [
          idx < idx + Const(1, width: 3),
          own < ownNext,
          allOnes < allOnesNext,
          If(idx.eq(Const(0, width: 3)), then: [group < inData[0]]),
          If(
            idx.eq(Const(5, width: 3)),
            then: [done < 1, keep < pass, mcast < isMcast, bcast < allOnesNext],
          ),
        ]),
      ]),
    ], reset: reset);
  }

  static String _definitionName(HarborEthernetConfig config) =>
      'HarborEthRxFilter'
      '${config.multicastHash ? '_Hash' : ''}'
      '${config.promiscuous ? '_Promisc' : ''}';
}
