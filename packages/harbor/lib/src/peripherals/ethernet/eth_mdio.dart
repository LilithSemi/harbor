import 'package:rohd/rohd.dart';

import '../../clock/cdc.dart';
import 'eth_config.dart';

/// MDIO master for the PHY management interface.
///
/// A pulse on `start` latches the inputs and sends one clause 22 frame: 32
/// preamble ones, ST 01, OP (01 write, 10 read), PHYAD, REGAD, TA and 16
/// data bits. With [HarborEthernetConfig.mdioC45] and `c45` high, it sends
/// two clause 45 frames with ST 00: an address frame with `addr`, then a
/// write (OP 01) or read (OP 11) frame. DEVAD takes the place of REGAD.
///
/// MDC is `clk / (2 * (div + 1))`, with `div` latched at `start`. The
/// master changes `mdio_out` after the falling edge of MDC, and samples
/// `mdio_in` at the rising edge. For a read it releases the line (`mdio_oe`
/// low) from the first TA bit to the end of the frame. `busy` is high from
/// the cycle after `start` until the last falling edge of MDC. `start` is
/// ignored while `busy` is high. After a read, `rdone` pulses with the
/// result on `rdata`.
class HarborEthMdio extends Module {
  /// Configuration of the MAC that contains this master.
  final HarborEthernetConfig config;

  /// Width of the `div` input.
  static const divWidth = 8;

  Logic get busy => output('busy');
  Logic get rdone => output('rdone');
  Logic get rdata => output('rdata');
  Logic get mdc => output('mdc');
  Logic get mdioOut => output('mdio_out');
  Logic get mdioOe => output('mdio_oe');

  HarborEthMdio(
    Logic clk,
    Logic reset, {
    required this.config,
    required Logic start,
    required Logic write,
    required Logic phy,
    required Logic reg,
    required Logic wdata,
    required Logic div,
    required Logic mdioIn,
    Logic? c45,
    Logic? devad,
    Logic? addr,
    super.name = 'eth_mdio',
  }) : super(definitionName: 'HarborEthMdio${config.mdioC45 ? '_C45' : ''}') {
    if (config.mdioC45 && (c45 == null || devad == null || addr == null)) {
      throw ArgumentError('mdioC45 needs c45, devad and addr');
    }
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    start = addInput('start', start);
    write = addInput('write', write);
    phy = addInput('phyad', phy, width: 5);
    reg = addInput('regad', reg, width: 5);
    wdata = addInput('wdata', wdata, width: 16);
    div = addInput('div', div, width: divWidth);
    mdioIn = addInput('mdio_in', mdioIn);
    final hasC45 = config.mdioC45;
    final isC45 = hasC45 ? addInput('c45', c45!) : null;
    final devadIn = hasC45 ? addInput('devad', devad!, width: 5) : null;
    final addrIn = hasC45 ? addInput('addr', addr!, width: 16) : null;

    final busyOut = addOutput('busy');
    final rdoneOut = addOutput('rdone');
    final rdataOut = addOutput('rdata', width: 16);
    final mdcOut = addOutput('mdc');
    final mdioOutOut = addOutput('mdio_out');
    final mdioOeOut = addOutput('mdio_oe');

    final inSync = HarborCdcSync(name: 'mdio_in_sync');
    inSync.input('async_in').srcConnection! <= mdioIn;
    inSync.input('dst_clk').srcConnection! <= clk;
    inSync.input('dst_reset').srcConnection! <= reset;
    final sample = inSync.syncOut;

    final busyR = Logic(name: 'busy_r');
    final rdoneR = Logic(name: 'rdone_r');
    final rdataR = Logic(name: 'rdata_r', width: 16);
    final mdcR = Logic(name: 'mdc_r');
    final oeR = Logic(name: 'oe_r');
    final sh = Logic(name: 'shift', width: 64);
    final bit = Logic(name: 'bit', width: 6);
    final cnt = Logic(name: 'cnt', width: divWidth);
    final rd = Logic(name: 'rd', width: 16);
    final isRead = Logic(name: 'is_read');
    final divR = Logic(name: 'div_r', width: divWidth);

    busyOut <= busyR;
    rdoneOut <= rdoneR;
    rdataOut <= rdataR;
    mdcOut <= mdcR;
    mdioOutOut <= sh[63];
    mdioOeOut <= oeR;

    Logic c(int v, int w) => Const(v, width: w);
    final ones = c(0xFFFFFFFF, 32);
    final ta = c(2, 2);

    final frame22 = [
      ones,
      c(1, 2),
      mux(write, c(1, 2), c(2, 2)),
      phy,
      reg,
      ta,
      wdata,
    ].swizzle().named('frame_c22');

    var first = frame22;
    var readFrame = isRead;
    final c45Load = <Conditional>[];
    final c45Next = <Iff>[];
    if (hasC45) {
      final second = Logic(name: 'second');
      final c45R = Logic(name: 'c45_r');
      final phyR = Logic(name: 'phy_r', width: 5);
      final devR = Logic(name: 'dev_r', width: 5);
      final dataR = Logic(name: 'data_r', width: 16);
      first = mux(
        isC45!,
        [ones, c(0, 2), c(0, 2), phy, devadIn!, ta, addrIn!].swizzle(),
        frame22,
      ).named('frame_first');
      final secondFrame = [
        ones,
        c(0, 2),
        mux(isRead, c(3, 2), c(1, 2)),
        phyR,
        devR,
        ta,
        dataR,
      ].swizzle().named('frame_second');
      // The first frame of a clause 45 access sets the address.
      readFrame = (isRead & (~c45R | second)).named('read_frame');
      c45Load.addAll([
        c45R < isC45,
        second < 0,
        phyR < phy,
        devR < devadIn,
        dataR < wdata,
      ]);
      c45Next.add(
        Iff(bit.eq(63) & c45R & ~second, [
          cnt < 0,
          mdcR < 0,
          second < 1,
          sh < secondFrame,
          bit < 0,
          oeR < 1,
        ]),
      );
    }

    final tick = cnt.eq(divR).named('tick');
    final lastBit = bit.eq(63).named('last_bit');
    final nextBit = (bit + 1).named('next_bit');

    Sequential(clk, reset: reset, [
      rdoneR < 0,
      If.block([
        Iff(~busyR, [
          mdcR < 0,
          oeR < 0,
          If(
            start,
            then: [
              busyR < 1,
              oeR < 1,
              sh < first,
              bit < 0,
              cnt < 0,
              isRead < ~write,
              divR < div,
              ...c45Load,
            ],
          ),
        ]),
        Iff(~tick, [cnt < cnt + 1]),
        Iff(~mdcR, [
          cnt < 0,
          mdcR < 1,
          If(
            readFrame & bit.gte(48),
            then: [
              rd < [rd.slice(14, 0), sample].swizzle(),
            ],
          ),
        ]),
        ...c45Next,
        Iff(lastBit, [
          cnt < 0,
          mdcR < 0,
          busyR < 0,
          oeR < 0,
          If(isRead, then: [rdoneR < 1, rdataR < rd]),
        ]),
        Else([
          cnt < 0,
          mdcR < 0,
          bit < nextBit,
          sh < (sh << 1),
          oeR < ~(readFrame & nextBit.gte(46)),
        ]),
      ]),
    ]);
  }
}
