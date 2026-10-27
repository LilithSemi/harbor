import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/tmds_decoder.dart';
import 'tmds_reference.dart';

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

typedef _Packet = ({int header, List<int> subs});

/// Timing generator, one register stage, a pattern, the framer and the
/// HDMI encoders.
class _Bench extends Module {
  late final HdmiFramer framer;
  late final List<Logic> hdmiQ;
  late final Logic de;
  late final Logic hs;
  late final Logic vs;
  late final Logic rgb;

  _Bench(
    HarborDisplayTiming timing,
    Logic clk,
    Logic reset,
    Logic hdmiEnable,
    Logic valid,
    Logic header,
    List<Logic> subs,
  ) : super(name: 'bench') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    hdmiEnable = addInput('hdmi_enable', hdmiEnable);
    valid = addInput('valid', valid);
    header = addInput('header', header, width: 24);
    subs = [for (var k = 0; k < 4; k++) addInput('sub$k', subs[k], width: 56)];
    final vtg = VideoTimingGenerator(timing: timing, clk: clk, reset: reset);
    Logic d(Logic v) => flop(clk, v, reset: reset);
    de = d(vtg.de);
    hs = d(vtg.hsync);
    vs = d(vtg.vsync);
    final x = d(vtg.x);
    final y = d(vtg.y);
    Logic byte(Logic v) => v.width >= 8 ? v.getRange(0, 8) : v.zeroExtend(8);
    final r = byte(x);
    final g = byte(y);
    final b = r ^ (g << 3);
    rgb = [r, g, b].swizzle();
    framer = HdmiFramer(
      timing: timing,
      clk: clk,
      reset: reset,
      hdmiEnable: hdmiEnable,
      videoEnable: Const(1),
      de: de,
      hsync: hs,
      vsync: vs,
      x: x,
      y: y,
      packetValid: valid,
      packetHeader: header,
      packetSubpacket: subs,
    );
    addOutput('ready') <= framer.packetReady;
    final ctrl = [
      [vs, hs].swizzle(),
      framer.ctl.getRange(0, 2),
      framer.ctl.getRange(2, 4),
    ];
    final data = [b, g, r];
    hdmiQ = [
      for (var c = 0; c < 3; c++)
        TmdsEncoder(
          clk: clk,
          reset: reset,
          de: de,
          data: data[c],
          ctrl: ctrl[c],
          mode: framer.mode.getRange(2 * c, 2 * c + 2),
          aux: framer.aux.getRange(4 * c, 4 * c + 4),
        ).q,
    ];
  }
}

/// The pattern pixel of the bench.
int _pattern(int x, int y) {
  final r = x & 0xFF;
  final g = y & 0xFF;
  final b = (r ^ (g << 3)) & 0xFF;
  return r << 16 | g << 8 | b;
}

/// Waits 2 time units, less than half a clock period of the benches.
Future<void> _settle() {
  final done = Completer<void>();
  Simulator.registerAction(Simulator.time + 2, done.complete);
  return done.future;
}

class _Run {
  final ch = [<int>[], <int>[], <int>[]];

  /// The DVI symbols of the same inputs, from [TmdsReference].
  final dvi = [<int>[], <int>[], <int>[]];
  final sync = <int>[];
  final taken = <_Packet>[];
  var drained = 0;
}

/// Runs [clocks] pixel clocks. [offer] gives the packet to offer in a clock
/// (by clock index), or null. A packet stays offered until it is taken.
/// [hdmiAt] is the clock where hdmi_enable goes to 1, -1 for never.
Future<_Run> _simulate(
  HarborDisplayTiming timing,
  int clocks, {
  int hdmiAt = 0,
  _Packet? Function(int clock)? offer,
}) async {
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final en = Logic(name: 'hdmi_enable');
  final valid = Logic(name: 'valid');
  final header = Logic(name: 'header', width: 24);
  final subs = [for (var k = 0; k < 4; k++) Logic(name: 's$k', width: 56)];
  final bench = _Bench(timing, clk, reset, en, valid, header, subs);
  await bench.build();
  reset.inject(1);
  en.inject(0);
  valid.inject(0);
  header.inject(0);
  for (final s in subs) {
    s.inject(0);
  }
  Simulator.setMaxSimTime(20 * (clocks + 100));
  unawaited(Simulator.run());
  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.inject(0);
  final run = _Run();
  _Packet? held;
  final ready = bench.output('ready');
  final refs = [TmdsReference(), TmdsReference(), TmdsReference()];
  // The encoder output of clock i is the input of clock i - 2. The
  // encoder registers reset to 0.
  final pending = [
    for (var k = 0; k < TmdsEncoder.latency; k++) [0, 0, 0],
  ];
  for (var i = 0; i < clocks; i++) {
    await clk.nextNegedge;
    for (var c = 0; c < 3; c++) {
      run.ch[c].add(bench.hdmiQ[c].value.toInt());
    }
    final sync = bench.hs.value.toInt() | bench.vs.value.toInt() << 1;
    run.sync.add(sync);
    final de = bench.de.value.toInt() == 1;
    final rgb = bench.rgb.value.toInt();
    final expect = pending.removeAt(0);
    for (var c = 0; c < 3; c++) {
      run.dvi[c].add(expect[c]);
    }
    pending.add([
      refs[0].encode(de: de, data: rgb & 0xFF, ctrl: sync),
      refs[1].encode(de: de, data: (rgb >> 8) & 0xFF, ctrl: 0),
      refs[2].encode(de: de, data: rgb >> 16, ctrl: 0),
    ]);
    if (i == hdmiAt) en.inject(1);
    held ??= offer?.call(i);
    valid.inject(held == null ? 0 : 1);
    if (held != null) {
      header.inject(held.header);
      for (var k = 0; k < 4; k++) {
        subs[k].inject(held.subs[k]);
      }
      // An inject takes effect later in the time step, so ready is read
      // a little after it, before the next posedge.
      await _settle();
      if (ready.value.toInt() == 1) {
        // With hdmi off the framer drops the packet.
        if (bench.framer.active.value.toInt() == 1) {
          run.taken.add(held);
        } else {
          run.drained++;
        }
        held = null;
      }
    }
  }
  await Simulator.endSimulation();
  await Simulator.simulationEnded;
  return run;
}

_Packet _randomPacket(Random rng) => (
  header: rng.nextInt(1 << 24),
  subs: [
    for (var k = 0; k < 4; k++)
      (rng.nextInt(1 << 28) << 28) | rng.nextInt(1 << 28),
  ],
);

/// Decodes [run] from [from] on and checks every rule of the model, the
/// video pattern, sync on channel 0 and that every packet the framer took
/// comes out whole and in order. Returns the decode.
TmdsDecode _check(HarborDisplayTiming timing, _Run run) {
  final from = _hdmiStart(run) - 20;
  final d = decodeTmds(
    run.ch[0].sublist(from),
    run.ch[1].sublist(from),
    run.ch[2].sublist(from),
  );
  expect(d.errors, isEmpty, reason: d.errors.take(10).join('\n'));
  var lines = 0;
  for (final v in d.video) {
    if (v.pixels.length < timing.hActive) continue;
    expect(v.guarded, isTrue, reason: 'line at ${v.start}');
    // The pattern green is y, so the line is known from the first pixel.
    final y = (v.pixels.first >> 8) & 0xFF;
    expect(v.pixels, [
      for (var x = 0; x < timing.hActive; x++) _pattern(x, y),
    ], reason: 'line at ${v.start}');
    lines++;
  }
  expect(lines, greaterThan(0));
  // The encoder output of clock i is the input of clock i - 2.
  var synced = 0;
  for (var i = 0; i < d.sync.length; i++) {
    final j = from + i - TmdsEncoder.latency;
    if (d.sync[i] < 0 || j < 0) continue;
    expect(d.sync[i], run.sync[j], reason: 'sync at clock ${from + i}');
    synced++;
  }
  expect(synced, greaterThan(0));
  final got = d.packets;
  expect(run.taken.length - got.length, inInclusiveRange(0, 1));
  for (var k = 0; k < got.length; k++) {
    expect(got[k].header, run.taken[k].header, reason: 'packet $k header');
    expect(got[k].subpackets, run.taken[k].subs, reason: 'packet $k body');
  }
  return d;
}

/// The first clock of a preamble. hdmi_enable goes in only in a vertical
/// blank, so frame 0 after reset is DVI.
int _hdmiStart(_Run run) =>
    decodeTmds(run.ch[0], run.ch[1], run.ch[2], hdmi: false).periods
        .firstWhere(
          (p) =>
              p.kind == TmdsPeriodKind.videoPreamble ||
              p.kind == TmdsPeriodKind.islandPreamble,
        )
        .start;

List<int> _islandSizes(TmdsDecode d) => [
  for (final p in d.periods)
    if (p.kind == TmdsPeriodKind.island) p.length ~/ 32,
];

/// hblank 62 for one packet in each line blank, a vertical blank of 8
/// lines for an island of 18 packets.
const _small = HarborDisplayTiming(
  hActive: 16,
  hFrontPorch: 4,
  hSyncWidth: 8,
  hBackPorch: 50,
  vActive: 4,
  vFrontPorch: 2,
  vSyncWidth: 2,
  vBackPorch: 4,
  pixelClock: 1000000,
);

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
    final run = await _simulate(
      _small,
      _small.hTotal * _small.vTotal * 2,
      hdmiAt: -1,
      offer: (_) => _randomPacket(rng),
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
    final run = await _simulate(_small, _small.hTotal * _small.vTotal * 3);
    final d = _check(_small, run);
    expect(d.packets, isEmpty);
    expect(
      d.periods.where((p) => p.kind == TmdsPeriodKind.videoGuard).length,
      greaterThanOrEqualTo(2 * _small.vActive),
    );
  });

  test('one packet makes one island of one packet', () async {
    final rng = Random(6);
    final p = _randomPacket(rng);
    final run = await _simulate(
      _small,
      _small.hTotal * _small.vTotal * 3,
      // After the first vertical blank, where hdmi_enable goes in.
      offer: (i) => i == (_small.vTotal + 1) * _small.hTotal ? p : null,
    );
    final d = _check(_small, run);
    expect(run.taken, hasLength(1));
    expect(_islandSizes(d), [1]);
  });

  test('a flood of packets fills islands up to 18 packets', () async {
    final rng = Random(7);
    final run = await _simulate(
      _small,
      _small.hTotal * _small.vTotal * 4,
      offer: (_) => _randomPacket(rng),
    );
    final d = _check(_small, run);
    final sizes = _islandSizes(d);
    expect(sizes.reduce(max), HdmiFramer.maxPackets);
    expect(sizes, everyElement(inInclusiveRange(1, HdmiFramer.maxPackets)));
    // Each active line blank has room for one packet.
    expect(sizes.where((s) => s == 1).length, greaterThan(_small.vActive));
  });

  test('a packet offered late in a blank is held, not cut', () async {
    final rng = Random(8);
    final h = _small.hTotal;
    // Offer near the end of each line blank, from late to too late.
    final run = await _simulate(
      _small,
      h * _small.vTotal * 4,
      offer: (i) {
        final x = i % h;
        return x >= h - 30 && rng.nextInt(4) == 0 ? _randomPacket(rng) : null;
      },
    );
    final d = _check(_small, run);
    expect(d.packets.length, greaterThan(4));
  });

  test('hdmi_enable goes in only in the vertical blank', () async {
    final h = _small.hTotal;
    final frame = h * _small.vTotal;
    // Set in the middle of frame 1: the change waits for its vertical
    // blank, so the first guarded line is in frame 2.
    final run = await _simulate(_small, frame * 3, hdmiAt: frame + 2 * h);
    final firstPre = _hdmiStart(run);
    expect(firstPre, greaterThan(frame + _small.vActive * h));
    for (var c = 0; c < 3; c++) {
      expect(run.ch[c].sublist(2, firstPre), run.dvi[c].sublist(2, firstPre));
    }
    _check(_small, run);
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

  test(
    '720p: hdmi off is DVI, then on decodes clean',
    () async {
      const timing = HarborDisplayTiming.hd720();
      final frame = timing.hTotal * timing.vTotal;
      final rng = Random(9);
      // hdmi_enable goes high in frame 0 and takes effect in its vertical
      // blank. Packets come in bursts at random clocks.
      final run = await _simulate(
        timing,
        2 * frame + 2 * timing.hTotal,
        hdmiAt: frame ~/ 2,
        offer: (i) => rng.nextInt(400) == 0 ? _randomPacket(rng) : null,
      );
      final on = _hdmiStart(run);
      expect(on, greaterThan(timing.vActive * timing.hTotal));
      for (var c = 0; c < 3; c++) {
        expect(run.ch[c].sublist(2, on), run.dvi[c].sublist(2, on));
      }
      final d = _check(timing, run);
      expect(d.packets.length, greaterThan(100));
      expect(
        d.video.where((v) => v.pixels.length == timing.hActive).length,
        greaterThanOrEqualTo(timing.vActive),
      );
    },
    timeout: const Timeout(Duration(hours: 4)),
  );
}
