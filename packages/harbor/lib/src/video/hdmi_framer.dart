import 'package:rohd/rohd.dart';

import '../peripherals/display.dart';
import 'tmds_encoder.dart';

/// HDMI 1.4 periods for a [DviTransmitter]: the video preamble and guard
/// band before each active line, and data islands in the blank.
///
/// All inputs are in the pixel domain and come from the same register
/// stage: [de], [hsync], [vsync] and the position [x], [y] of the clock.
/// The outputs are not registered. They go to the first stage of the
/// encoders together with that stage.
///
/// [hdmiEnable] goes into the framer only in the vertical blank, while no
/// period is in progress. With it at 0, [mode] and [ctl] are 0, so the
/// lanes are DVI, and [packetReady] is high, so a source does not wait.
///
/// A packet (HDMI 1.4 section 5.3.1) is a 24-bit [packetHeader], HB0 in
/// bits 7..0, and four 56-bit [packetSubpacket] values, byte j of a
/// subpacket in bits 8j+7..8j. The framer adds the BCH parity bytes. A
/// source holds [packetValid] and the packet until [packetReady]. The
/// framer takes a packet in the clock where both are high and then sends
/// all 32 clocks of it. [packetReady] can depend on [packetValid] in the
/// same clock.
///
/// The framer starts a data island only in the blank, after at least 4
/// control clocks, and only if the island with one packet, its trailing
/// guard band and the 12 control clocks before the next active line all
/// fit. It adds one more packet to the island only if that packet fits
/// the same way, and stops at [maxPackets]. Each active line position
/// counts, also when the display is off.
class HdmiFramer extends Module {
  /// The most packets in one data island (HDMI 1.4 section 5.2.3.1).
  static const maxPackets = 18;

  /// Clocks of a preamble (HDMI 1.4 section 5.2.1.1).
  static const preambleClocks = 8;

  /// Least control clocks before a preamble (HDMI 1.4 section 5.2.1.1).
  static const minControlClocks = 4;

  /// Clocks of a guard band.
  static const guardClocks = 2;

  /// Clocks of one packet.
  static const packetClocks = 32;

  /// Clocks from a data island start (its first preamble clock) to the
  /// first video data clock, with one packet.
  static const islandRoom =
      preambleClocks +
      guardClocks +
      packetClocks +
      guardClocks +
      minControlClocks +
      preambleClocks +
      guardClocks;

  /// The least horizontal blank: control clocks, the video preamble and
  /// the video guard band.
  static const minHBlank = minControlClocks + preambleClocks + guardClocks;

  Logic get packetReady => output('packet_ready');

  /// [TmdsEncoder] mode of channel n in bits 2n+1..2n.
  Logic get mode => output('mode');

  /// TERC4 data of channel n in bits 4n+3..4n.
  Logic get aux => output('aux');

  /// CTL3..CTL0.
  Logic get ctl => output('ctl');

  /// The applied [hdmiEnable].
  Logic get active => output('active');

  final HarborDisplayTiming timing;

  HdmiFramer({
    required this.timing,
    required Logic clk,
    required Logic reset,
    required Logic hdmiEnable,
    required Logic videoEnable,
    required Logic de,
    required Logic hsync,
    required Logic vsync,
    required Logic x,
    required Logic y,
    required Logic packetValid,
    required Logic packetHeader,
    required List<Logic> packetSubpacket,
    super.name = 'hdmi_framer',
  }) : super(
         definitionName:
             'HdmiFramer_${timing.hActive}_${timing.hFrontPorch}'
             '_${timing.hSyncWidth}_${timing.hBackPorch}_${timing.vActive}'
             '_${timing.vFrontPorch}_${timing.vSyncWidth}_${timing.vBackPorch}',
       ) {
    final hTotal = timing.hTotal;
    final vTotal = timing.vTotal;
    final vActive = timing.vActive;
    if (hTotal - timing.hActive < minHBlank) {
      throw ArgumentError(
        'HDMI needs at least $minHBlank clocks of horizontal blank, got '
        '${hTotal - timing.hActive}',
      );
    }
    if (hTotal <= islandRoom || vTotal <= vActive) {
      throw ArgumentError(
        'HDMI needs hTotal above $islandRoom and a vertical blank',
      );
    }
    if (packetSubpacket.length != 4) {
      throw ArgumentError('give 4 subpackets');
    }
    final hbits = (hTotal - 1).bitLength;
    final vbits = (vTotal - 1).bitLength;
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    hdmiEnable = addInput('hdmi_enable', hdmiEnable);
    videoEnable = addInput('video_enable', videoEnable);
    de = addInput('de', de);
    hsync = addInput('hsync', hsync);
    vsync = addInput('vsync', vsync);
    x = addInput('x', x, width: hbits);
    y = addInput('y', y, width: vbits);
    packetValid = addInput('packet_valid', packetValid);
    packetHeader = addInput('packet_header', packetHeader, width: 24);
    final sub = [
      for (var k = 0; k < 4; k++)
        addInput('packet_subpacket_$k', packetSubpacket[k], width: 56),
    ];
    addOutput('packet_ready');
    addOutput('mode', width: 6);
    addOutput('aux', width: 12);
    addOutput('ctl', width: 4);
    addOutput('active');

    Logic xIs(int v) => x.eq(Const(v, width: hbits));

    // The line after this one is an active line position.
    final nextActive =
        (y.lt(Const(vActive - 1, width: vbits)) |
                y.eq(Const(vTotal - 1, width: vbits)))
            .named('next_line_active');
    final blank =
        (x.gte(Const(timing.hActive, width: hbits)) |
                y.gte(Const(vActive, width: vbits)))
            .named('blank');
    // Clocks from the next clock to the next active line are at least n.
    Logic room(int n) =>
        ~nextActive | x.lte(Const(hTotal - 1 - n, width: hbits));

    final on = Logic(name: 'on');
    final vp = Logic(name: 'video_preamble');
    final vg = Logic(name: 'video_guard');
    final ctlRun = Logic(name: 'control_run', width: 3);
    // 0 idle, 1 preamble, 2 leading guard, 3 packet, 4 trailing guard.
    final phase = Logic(name: 'island_phase', width: 3);
    final count = Logic(name: 'island_count', width: 5);
    final packets = Logic(name: 'island_packets', width: 5);
    final first = Logic(name: 'island_first');

    final idle = phase.eq(0).named('island_idle');
    final pre = phase.eq(1);
    final lead = phase.eq(2);
    final data = phase.eq(3).named('island_data');
    final trail = phase.eq(4);
    final plain = (idle & ~vp & ~vg & ~de).named('plain_control');
    final lastClock = count.eq(packetClocks - 1);

    final start =
        (on &
                packetValid &
                plain &
                blank &
                ctlRun.gte(minControlClocks - 1) &
                room(islandRoom))
            .named('island_start');
    final more =
        (data &
                lastClock &
                packetValid &
                packets.lt(maxPackets) &
                room(islandRoom - preambleClocks - guardClocks))
            .named('island_more');
    final take = (start | more).named('packet_take');
    packetReady <= ~on | take;

    // hdmi_enable goes in only in the vertical blank, away from the video
    // preamble and while no island is in progress.
    final apply =
        (idle &
                ~start &
                y.gte(Const(vActive, width: vbits)) &
                x.lt(Const(hTotal - minHBlank, width: hbits)))
            .named('enable_apply');

    // The packet bits go out low bit first. The BCH parity follows the
    // data bits of each block: header bits 24 to 31, subpacket bits 56 to
    // 63. Generator x^8 + x^7 + x^6 + 1 (HDMI 1.4 section 5.2.3.5), one
    // step for each bit.
    Logic bch(Logic ecc, Logic bit) {
      final f = ecc[0] ^ bit;
      final s = ecc >>> 1;
      return s ^ [f, Const(0, width: 5), f, f].swizzle();
    }

    final hdr = Logic(name: 'header_bits', width: 24);
    final hdrEcc = Logic(name: 'header_ecc', width: 8);
    final subBits = [
      for (var k = 0; k < 4; k++) Logic(name: 'subpacket${k}_bits', width: 56),
    ];
    final subEcc = [
      for (var k = 0; k < 4; k++) Logic(name: 'subpacket${k}_ecc', width: 8),
    ];
    final hdrData = ~(count[4] & count[3]);
    final subData = ~(count[4] & count[3] & count[2]);
    final zero8 = Const(0, width: 8);

    Sequential(clk, reset: reset, [
      If(apply, then: [on < hdmiEnable]),
      ctlRun <
          mux(plain, mux(ctlRun.eq(7), ctlRun, ctlRun + 1), Const(0, width: 3)),
      vp <
          mux(
            xIs(hTotal - preambleClocks - guardClocks - 1),
            on & videoEnable & nextActive,
            mux(xIs(hTotal - guardClocks - 1), Const(0), vp),
          ),
      vg <
          mux(
            xIs(hTotal - guardClocks - 1),
            vp,
            mux(xIs(hTotal - 1), Const(0), vg),
          ),
      If.block([
        Iff(idle, [
          If(start, then: [phase < 1, count < 0]),
        ]),
        Iff(pre, [
          If(
            count.eq(preambleClocks - 1),
            then: [phase < 2, count < 0],
            orElse: [count < count + 1],
          ),
        ]),
        Iff(lead, [
          If(
            count.eq(guardClocks - 1),
            then: [phase < 3, count < 0, packets < 1, first < 1],
            orElse: [count < count + 1],
          ),
        ]),
        Iff(data, [
          count < count + 1,
          If(
            lastClock,
            then: [
              first < 0,
              If(
                more,
                then: [packets < packets + 1],
                orElse: [phase < 4, count < 0],
              ),
            ],
          ),
        ]),
        Iff(trail, [
          If(
            count.eq(guardClocks - 1),
            then: [phase < 0, count < 0],
            orElse: [count < count + 1],
          ),
        ]),
      ]),
      If.block([
        Iff(take, [
          hdr < packetHeader,
          hdrEcc < zero8,
          for (var k = 0; k < 4; k++) ...[
            subBits[k] < sub[k],
            subEcc[k] < zero8,
          ],
        ]),
        Iff(data, [
          If(
            hdrData,
            then: [hdr < (hdr >>> 1), hdrEcc < bch(hdrEcc, hdr[0])],
            orElse: [hdrEcc < (hdrEcc >>> 1)],
          ),
          for (var k = 0; k < 4; k++)
            If(
              subData,
              then: [
                subBits[k] < (subBits[k] >>> 2),
                subEcc[k] < bch(bch(subEcc[k], subBits[k][0]), subBits[k][1]),
              ],
              orElse: [subEcc[k] < (subEcc[k] >>> 2)],
            ),
        ]),
      ]),
    ]);

    final headerBit = mux(hdrData, hdr[0], hdrEcc[0]);
    Logic subBit(int k, int b) => mux(subData, subBits[k][b], subEcc[k][b]);
    final guard = (lead | trail).named('island_guard');
    final one = Const(1);

    final aux0 = [
      mux(data, ~(first & count.eq(0)), one),
      mux(data, headerBit, one),
      vsync,
      hsync,
    ].swizzle();
    final aux1 = [for (var k = 3; k >= 0; k--) subBit(k, 0)].swizzle();
    final aux2 = [for (var k = 3; k >= 0; k--) subBit(k, 1)].swizzle();
    aux <= [aux2, aux1, aux0].swizzle();

    Logic m(int v) => Const(v, width: 2);
    final terc4 = (data | guard).named('island_terc4');
    final mode0 = mux(
      terc4,
      m(TmdsEncoder.modeTerc4),
      mux(vg, m(TmdsEncoder.modeGuard0), m(TmdsEncoder.modeDvi)),
    );
    final mode1 = mux(
      data,
      m(TmdsEncoder.modeTerc4),
      mux(guard | vg, m(TmdsEncoder.modeGuard1), m(TmdsEncoder.modeDvi)),
    );
    final mode2 = mux(
      data,
      m(TmdsEncoder.modeTerc4),
      mux(
        guard,
        m(TmdsEncoder.modeGuard1),
        mux(vg, m(TmdsEncoder.modeGuard0), m(TmdsEncoder.modeDvi)),
      ),
    );
    mode <= [mode2, mode1, mode0].swizzle();
    // Video preamble CTL3..0 = 0001, data island preamble 0101.
    ctl <= [Const(0), pre, Const(0), vp | pre].swizzle();
    active <= on;
  }
}
