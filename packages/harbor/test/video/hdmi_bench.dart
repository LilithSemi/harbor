import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/tmds_decoder.dart';
import 'tmds_reference.dart';

/// Benches and checks for the HDMI framer tests.

typedef HdmiTestPacket = ({int header, List<int> subs});

/// Timing generator, one register stage, a pattern, the framer and the
/// HDMI encoders.
class HdmiBench extends Module {
  late final HdmiFramer framer;
  late final List<Logic> hdmiQ;
  late final Logic de;
  late final Logic hs;
  late final Logic vs;
  late final Logic rgb;

  HdmiBench(
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
int hdmiPattern(int x, int y) {
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

class HdmiRun {
  final ch = [<int>[], <int>[], <int>[]];

  /// The DVI symbols of the same inputs, from [TmdsReference].
  final dvi = [<int>[], <int>[], <int>[]];
  final sync = <int>[];
  final taken = <HdmiTestPacket>[];
  var drained = 0;
}

/// A packet source in logic: a packet becomes valid when an LFSR hits 0 in
/// its low 8 bits, and stays valid until taken. Each taken packet is the
/// next value of a counter, spread over the header and subpackets.
class HdmiSource extends Module {
  Logic get valid => output('valid');
  Logic get header => output('header');
  List<Logic> get subs => [for (var k = 0; k < 4; k++) output('sub$k')];

  HdmiSource(Logic clk, Logic reset, Logic ready) : super(name: 'source') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    ready = addInput('ready', ready);
    addOutput('valid');
    addOutput('header', width: 24);
    final lfsr = Logic(name: 'lfsr', width: 16);
    final count = Logic(name: 'count', width: 32);
    final pending = Logic(name: 'pending');
    final fb = lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10];
    final take = pending & ready;
    Sequential(clk, reset: reset, [
      lfsr <
          mux(
            lfsr.eq(0),
            Const(1, width: 16),
            [lfsr.getRange(0, 15), fb].swizzle(),
          ),
      pending < (pending & ~take) | lfsr.getRange(0, 8).eq(0),
      If(take, then: [count < count + 1]),
    ]);
    valid <= pending;
    header <= count.getRange(0, 24) ^ Const(0x5A3C96, width: 24);
    for (var k = 0; k < 4; k++) {
      addOutput('sub$k', width: 56) <=
          [count.getRange(0, 24), count].swizzle() ^
              Const(0x123456789ABCD * (k + 3) & 0xFFFFFFFFFFFFFF, width: 56);
    }
  }
}

/// Like [simulateHdmi] with packets from a [HdmiSource]. It samples in a
/// negedge listener, without an await for each clock, so it is fast enough
/// for a full 720p frame.
Future<HdmiRun> simulateHdmiFast(
  HarborDisplayTiming timing,
  int clocks, {
  required int hdmiAt,
}) async {
  const period = 10;
  final clk = SimpleClockGenerator(period).clk;
  final reset = Logic(name: 'reset');
  final en = Logic(name: 'hdmi_enable');
  final ready = Logic(name: 'ready');
  final source = HdmiSource(clk, reset, ready);
  final bench = HdmiBench(
    timing,
    clk,
    reset,
    en,
    source.valid,
    source.header,
    source.subs,
  );
  ready <= bench.output('ready');
  await bench.build();
  await source.build();
  reset.inject(1);
  en.inject(0);
  final run = HdmiRun();
  final refs = [TmdsReference(), TmdsReference(), TmdsReference()];
  final pending = [
    for (var k = 0; k < TmdsEncoder.latency; k++) [0, 0, 0],
  ];
  var started = false;
  var i = 0;
  clk.negedge.listen((_) {
    if (!started || i >= clocks) return;
    for (var c = 0; c < 3; c++) {
      run.ch[c].add(bench.hdmiQ[c].value.toInt());
    }
    final sync = bench.hs.value.toInt() | bench.vs.value.toInt() << 1;
    run.sync.add(sync);
    final de = bench.de.value.toInt() == 1;
    final rgb = bench.rgb.value.toInt();
    final want = pending.removeAt(0);
    for (var c = 0; c < 3; c++) {
      run.dvi[c].add(want[c]);
    }
    pending.add([
      refs[0].encode(de: de, data: rgb & 0xFF, ctrl: sync),
      refs[1].encode(de: de, data: (rgb >> 8) & 0xFF, ctrl: 0),
      refs[2].encode(de: de, data: rgb >> 16, ctrl: 0),
    ]);
    if (source.valid.value.toInt() == 1 && ready.value.toInt() == 1) {
      if (bench.framer.active.value.toInt() == 1) {
        run.taken.add((
          header: source.header.value.toInt(),
          subs: [for (final s in source.subs) s.value.toBigInt().toInt()],
        ));
      } else {
        run.drained++;
      }
    }
    if (i == hdmiAt) en.inject(1);
    i++;
  });
  // Reset for two clocks, then release on a negedge, as in [simulateHdmi].
  Simulator.registerAction(period * 2 + period ~/ 2 - 1, () {
    reset.inject(0);
    started = true;
  });
  Simulator.setMaxSimTime(period * (clocks + 4));
  await Simulator.run();
  return run;
}

/// Runs [clocks] pixel clocks. [offer] gives the packet to offer in a clock
/// (by clock index), or null. A packet stays offered until it is taken.
/// [hdmiAt] is the clock where hdmi_enable goes to 1, -1 for never.
Future<HdmiRun> simulateHdmi(
  HarborDisplayTiming timing,
  int clocks, {
  int hdmiAt = 0,
  HdmiTestPacket? Function(int clock)? offer,
}) async {
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final en = Logic(name: 'hdmi_enable');
  final valid = Logic(name: 'valid');
  final header = Logic(name: 'header', width: 24);
  final subs = [for (var k = 0; k < 4; k++) Logic(name: 's$k', width: 56)];
  final bench = HdmiBench(timing, clk, reset, en, valid, header, subs);
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
  final run = HdmiRun();
  HdmiTestPacket? held;
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

HdmiTestPacket randomHdmiPacket(Random rng) => (
  header: rng.nextInt(1 << 24),
  subs: [
    for (var k = 0; k < 4; k++)
      (rng.nextInt(1 << 28) << 28) | rng.nextInt(1 << 28),
  ],
);

/// Decodes [run] from [from] on and checks every rule of the model, the
/// video pattern, sync on channel 0 and that every packet the framer took
/// comes out whole and in order. Returns the decode.
TmdsDecode checkHdmi(HarborDisplayTiming timing, HdmiRun run) {
  final from = hdmiStart(run) - 20;
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
      for (var x = 0; x < timing.hActive; x++) hdmiPattern(x, y),
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
int hdmiStart(HdmiRun run) =>
    decodeTmds(run.ch[0], run.ch[1], run.ch[2], hdmi: false).periods
        .firstWhere(
          (p) =>
              p.kind == TmdsPeriodKind.videoPreamble ||
              p.kind == TmdsPeriodKind.islandPreamble,
        )
        .start;

List<int> islandSizes(TmdsDecode d) => [
  for (final p in d.periods)
    if (p.kind == TmdsPeriodKind.island) p.length ~/ 32,
];

/// hblank 62 for one packet in each line blank, a vertical blank of 8
/// lines for an island of 18 packets.
const smallHdmiTiming = HarborDisplayTiming(
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
