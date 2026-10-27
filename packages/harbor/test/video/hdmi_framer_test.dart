import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/tmds_decoder.dart';
import 'hdmi_bench.dart';

/// TERC4 table of HDMI 1.4 section 5.4.3, q_out[9:0] for D3..D0 = 0 to 15.
const _terc4Spec = [
  '1010011100', '1001100011', '1011100100', '1011100010', //
  '0101110001', '0100011110', '0110001110', '0100111100',
  '1011001100', '0100111001', '0110011100', '1011000110',
  '1010001110', '1001110001', '0101100011', '1011000011',
];

/// BCH parity from the generator polynomial: the remainder of
/// m(x) * x^8 / g(x), with the first bit sent as the highest power of m.
/// The parity is sent from the x^7 term down.
int _bchByDivision(List<int> bits) {
  // g(x) = x^8 + x^7 + x^6 + 1, coefficient of x^i in bit i.
  const g = 0x1C1;
  var r = 0;
  for (final b in [...bits, ...List.filled(8, 0)]) {
    r = (r << 1) | b;
    if ((r >> 8) & 1 == 1) r ^= g;
  }
  // Bit k of the sent parity is the x^(7-k) term.
  var p = 0;
  for (var k = 0; k < 8; k++) {
    p |= ((r >> (7 - k)) & 1) << k;
  }
  return p;
}

List<int> _bitsOf(int v, int n) => [for (var i = 0; i < n; i++) (v >> i) & 1];
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('the TERC4 and guard band constants are the HDMI 1.4 values', () {
    for (var v = 0; v < 16; v++) {
      expect(
        TmdsEncoder.terc4[v],
        int.parse(_terc4Spec[v], radix: 2),
        reason: 'code $v',
      );
      expect(terc4Symbols[v], TmdsEncoder.terc4[v]);
    }
    expect(TmdsEncoder.guardBand0, int.parse('1011001100', radix: 2));
    expect(TmdsEncoder.guardBand1, int.parse('0100110011', radix: 2));
    // The guard band and control symbols decode to no TERC4 code.
    expect(terc4Symbols, isNot(contains(TmdsEncoder.guardBand1)));
    for (final c in [0x354, 0x0AB, 0x154, 0x2AB]) {
      expect(terc4Symbols, isNot(contains(c)));
    }
  });

  test('the encoder sends each TERC4 code and both guard bands', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic();
    final de = Logic();
    final data = Logic(width: 8);
    final mode = Logic(width: 2);
    final aux = Logic(width: 4);
    final enc = TmdsEncoder(
      clk: clk,
      reset: reset,
      de: de,
      data: data,
      ctrl: Const(2, width: 2),
      mode: mode,
      aux: aux,
    );
    await enc.build();
    expect(enc.definitionName, 'TmdsEncoder_hdmi');
    reset.inject(1);
    de.inject(0);
    data.inject(0);
    mode.inject(0);
    aux.inject(0);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    reset.inject(0);
    final inputs = [
      for (var v = 0; v < 16; v++) (TmdsEncoder.modeTerc4, v),
      (TmdsEncoder.modeGuard0, 5),
      (TmdsEncoder.modeGuard1, 9),
      (TmdsEncoder.modeDvi, 3),
    ];
    final want = [
      for (var v = 0; v < 16; v++) int.parse(_terc4Spec[v], radix: 2),
      int.parse('1011001100', radix: 2),
      int.parse('0100110011', radix: 2),
      0x154,
    ];
    final got = <int>[];
    for (var i = 0; i < inputs.length + TmdsEncoder.latency; i++) {
      await clk.nextNegedge;
      if (i >= TmdsEncoder.latency) got.add(enc.q.value.toInt());
      if (i < inputs.length) {
        mode.inject(inputs[i].$1);
        aux.inject(inputs[i].$2);
      }
    }
    await Simulator.endSimulation();
    expect(got, want);
  });

  test('BCH parity matches the hand vector and the polynomial', () {
    // AVI InfoFrame header 82 02 0D and its subpacket 0 (2F 40 00 00 00 00
    // 00), hand computed from the generator.
    expect(hdmiBch(0x0D0282, 24), 0xE4);
    expect(hdmiBch(0x402F, 56), 0x71);
    expect(hdmiBch(0, 24), 0);
    expect(_bchByDivision(_bitsOf(0x0D0282, 24)), 0xE4);
    final rng = Random(3);
    for (var i = 0; i < 2000; i++) {
      final h = rng.nextInt(1 << 24);
      expect(_bchByDivision(_bitsOf(h, 24)), hdmiBch(h, 24));
      final s = (rng.nextInt(1 << 28) << 28) | rng.nextInt(1 << 28);
      expect(_bchByDivision(_bitsOf(s, 56)), hdmiBch(s, 56));
    }
  });

  test('with hdmi off the lanes are the DVI lanes', () async {
    final rng = Random(5);
    final run = await simulateHdmi(
      smallHdmiTiming,
      smallHdmiTiming.hTotal * smallHdmiTiming.vTotal * 2,
      hdmiAt: -1,
      offer: (_) => randomHdmiPacket(rng),
    );
    // Clock 1 still has the reset value of the encoder first stage.
    for (var c = 0; c < 3; c++) {
      expect(run.ch[c].skip(2), run.dvi[c].skip(2), reason: 'channel $c');
    }
    final d = decodeTmds(run.ch[0], run.ch[1], run.ch[2], hdmi: false);
    expect(d.errors, isEmpty, reason: d.errors.take(10).join('\n'));
    expect(d.packets, isEmpty);
    expect(run.taken, isEmpty);
    expect(run.drained, greaterThan(100));
  });

  test('with no packets each line has a preamble and guard band', () async {
    final run = await simulateHdmi(
      smallHdmiTiming,
      smallHdmiTiming.hTotal * smallHdmiTiming.vTotal * 3,
    );
    final d = checkHdmi(smallHdmiTiming, run);
    expect(d.packets, isEmpty);
    expect(
      d.periods.where((p) => p.kind == TmdsPeriodKind.videoGuard).length,
      greaterThanOrEqualTo(2 * smallHdmiTiming.vActive),
    );
  });

  test('one packet makes one island of one packet', () async {
    final rng = Random(6);
    final p = randomHdmiPacket(rng);
    final run = await simulateHdmi(
      smallHdmiTiming,
      smallHdmiTiming.hTotal * smallHdmiTiming.vTotal * 3,
      // After the first vertical blank, where hdmi_enable goes in.
      offer: (i) =>
          i == (smallHdmiTiming.vTotal + 1) * smallHdmiTiming.hTotal ? p : null,
    );
    final d = checkHdmi(smallHdmiTiming, run);
    expect(run.taken, hasLength(1));
    expect(islandSizes(d), [1]);
  });

  test('a flood of packets fills islands up to 18 packets', () async {
    final rng = Random(7);
    final run = await simulateHdmi(
      smallHdmiTiming,
      smallHdmiTiming.hTotal * smallHdmiTiming.vTotal * 4,
      offer: (_) => randomHdmiPacket(rng),
    );
    final d = checkHdmi(smallHdmiTiming, run);
    final sizes = islandSizes(d);
    expect(sizes.reduce(max), HdmiFramer.maxPackets);
    expect(sizes, everyElement(inInclusiveRange(1, HdmiFramer.maxPackets)));
    // Each active line blank has room for one packet.
    expect(
      sizes.where((s) => s == 1).length,
      greaterThan(smallHdmiTiming.vActive),
    );
  });

  test('a packet offered late in a blank is held, not cut', () async {
    final rng = Random(8);
    final h = smallHdmiTiming.hTotal;
    // Offer near the end of each line blank, from late to too late.
    final run = await simulateHdmi(
      smallHdmiTiming,
      h * smallHdmiTiming.vTotal * 4,
      offer: (i) {
        final x = i % h;
        return x >= h - 30 && rng.nextInt(4) == 0
            ? randomHdmiPacket(rng)
            : null;
      },
    );
    final d = checkHdmi(smallHdmiTiming, run);
    expect(d.packets.length, greaterThan(4));
  });

  test('hdmi_enable goes in only in the vertical blank', () async {
    final h = smallHdmiTiming.hTotal;
    final frame = h * smallHdmiTiming.vTotal;
    // Set in the middle of frame 1: the change waits for its vertical
    // blank, so the first guarded line is in frame 2.
    final run = await simulateHdmi(
      smallHdmiTiming,
      frame * 3,
      hdmiAt: frame + 2 * h,
    );
    final firstPre = hdmiStart(run);
    expect(firstPre, greaterThan(frame + smallHdmiTiming.vActive * h));
    for (var c = 0; c < 3; c++) {
      expect(run.ch[c].sublist(2, firstPre), run.dvi[c].sublist(2, firstPre));
    }
    checkHdmi(smallHdmiTiming, run);
  });

  test('the build checks the blank', () {
    HdmiFramer make(HarborDisplayTiming t) => HdmiFramer(
      timing: t,
      clk: Logic(),
      reset: Logic(),
      hdmiEnable: Logic(),
      videoEnable: Logic(),
      de: Logic(),
      hsync: Logic(),
      vsync: Logic(),
      x: Logic(width: (t.hTotal - 1).bitLength),
      y: Logic(width: (t.vTotal - 1).bitLength),
      packetValid: Logic(),
      packetHeader: Logic(width: 24),
      packetSubpacket: [for (var k = 0; k < 4; k++) Logic(width: 56)],
    );
    HarborDisplayTiming t(int hActive, int blank) => HarborDisplayTiming(
      hActive: hActive,
      hFrontPorch: blank,
      hSyncWidth: 0,
      hBackPorch: 0,
      vActive: 2,
      vFrontPorch: 1,
      vSyncWidth: 1,
      vBackPorch: 1,
      pixelClock: 1000000,
    );
    expect(() => make(t(100, 13)), throwsArgumentError);
    expect(() => make(t(100, 14)), returnsNormally);
    expect(() => make(t(10, 48)), throwsArgumentError);
    expect(() => make(t(10, 49)), returnsNormally);
    expect(
      make(const HarborDisplayTiming.hd720()).definitionName,
      isNot(make(const HarborDisplayTiming.fhd1080()).definitionName),
    );
  });

  test('a logic source at the small timing decodes clean', () async {
    final frame = smallHdmiTiming.hTotal * smallHdmiTiming.vTotal;
    final run = await simulateHdmiFast(smallHdmiTiming, 20 * frame, hdmiAt: 0);
    final d = checkHdmi(smallHdmiTiming, run);
    expect(d.packets.length, greaterThan(20));
  });
}
