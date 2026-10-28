import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// 25.2 MHz scaled down by 100. CTS is the 25.2 MHz value divided by 100,
/// N does not change, so fs does not change.
const _scaledClock = 252000;

/// A [HdmiPacketScheduler] with a counter sample source (left is the
/// count, right the count xor 0xABCDEF), a frame pulse each [framePeriod]
/// clocks and a ready that is high in 3 of 4 clocks while [stall] is low.
class _Bench extends Module {
  late final HdmiPacketScheduler sched;
  Logic get ready => output('ready');

  _Bench(
    Logic clk,
    Logic reset,
    Logic sourceOn,
    Logic stall,
    Logic fsSel,
    Logic vic,
    Logic aviQ,
    Logic aviM, {
    required int framePeriod,
  }) : super(name: 'bench') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    sourceOn = addInput('source_on', sourceOn);
    stall = addInput('stall', stall);
    fsSel = addInput('fs_sel', fsSel, width: 2);
    vic = addInput('vic', vic, width: 7);
    aviQ = addInput('avi_q', aviQ, width: 2);
    aviM = addInput('avi_m', aviM, width: 2);
    final count = Logic(name: 'count', width: 24);
    final tick = Logic(name: 'tick', width: 16);
    final phase = Logic(name: 'phase', width: 2);
    final ready = addOutput('ready');
    final pop = Logic(name: 'pop');
    Sequential(clk, reset: reset, [
      If(pop, then: [count < count + 1]),
      tick < mux(tick.eq(framePeriod - 1), Const(0, width: 16), tick + 1),
      phase < phase + 1,
    ]);
    ready <= phase.neq(3) & ~stall;
    sched = HdmiPacketScheduler(
      clk: clk,
      reset: reset,
      frame: tick.eq(0),
      vic: vic,
      aviQ: aviQ,
      aviM: aviM,
      active: Const(1),
      fsSel: fsSel,
      sampleValid: sourceOn,
      sampleLeft: count,
      sampleRight: count ^ Const(0xABCDEF, width: 24),
      packetReady: ready,
      pixelClock: _scaledClock,
    );
    pop <= sched.samplePop;
  }
}

typedef _Packet = ({int header, List<int> subs});

class _Result {
  final packets = <_Packet>[];
  var frames = 0;
  var underruns = 0;
  var missed = 0;
}

Future<_Result> _run(
  int clocks, {
  required int fs,
  int vic = 0,
  int aviQ = 0,
  int aviM = 0,
  int sourceOffAt = -1,
  int stallFrom = -1,
  int stallTo = -1,
  int framePeriod = 2000,
}) async {
  const period = 10;
  final clk = SimpleClockGenerator(period).clk;
  final reset = Logic(name: 'reset');
  final on = Logic(name: 'on');
  final stall = Logic(name: 'stall');
  final sel = Logic(name: 'sel', width: 2);
  final v = Logic(name: 'v', width: 7);
  final q = Logic(name: 'q', width: 2);
  final m = Logic(name: 'm', width: 2);
  final bench = _Bench(
    clk,
    reset,
    on,
    stall,
    sel,
    v,
    q,
    m,
    framePeriod: framePeriod,
  );
  await bench.build();
  reset.inject(1);
  on.inject(1);
  stall.inject(0);
  sel.inject(fs);
  v.inject(vic);
  q.inject(aviQ);
  m.inject(aviM);
  final s = bench.sched;
  final r = _Result();
  var started = false;
  var i = 0;
  clk.negedge.listen((_) {
    if (!started || i >= clocks) return;
    if (s.packetValid.value.toInt() == 1 && bench.ready.value.toInt() == 1) {
      r.packets.add((
        header: s.packetHeader.value.toInt(),
        subs: [
          for (var k = 0; k < 4; k++)
            s.packetSubpacket(k).value.toBigInt().toInt(),
        ],
      ));
    }
    if (s.input('frame').value.toInt() == 1) r.frames++;
    r.underruns += s.underrun.value.toInt();
    r.missed += s.missed.value.toInt();
    if (i == sourceOffAt) on.inject(0);
    if (i == stallFrom) stall.inject(1);
    if (i == stallTo) stall.inject(0);
    i++;
  });
  Simulator.registerAction(period * 2 + period ~/ 2 - 1, () {
    reset.inject(0);
    started = true;
  });
  Simulator.setMaxSimTime(period * (clocks + 4));
  await Simulator.run();
  return r;
}

int _byte(_Packet p, int k, int j) => p.subs[k] >> (8 * j) & 0xff;

/// Sum of HB0..HB2 and PB0..PB27 mod 256.
int _infoSum(_Packet p) {
  var sum = (p.header & 0xff) + (p.header >> 8 & 0xff) + (p.header >> 16);
  for (var k = 0; k < 4; k++) {
    for (var j = 0; j < 7; j++) {
      sum += _byte(p, k, j);
    }
  }
  return sum & 0xff;
}

int _ones(int v) {
  var n = 0;
  for (; v != 0; v &= v - 1) {
    n++;
  }
  return n;
}

/// One IEC 60958 frame from an audio sample packet.
typedef _Frame = ({int left, int right, int status, bool block});

List<_Frame> _frames(List<_Packet> packets) {
  final out = <_Frame>[];
  for (final p in packets.where((p) => p.header & 0xff == 0x02)) {
    final hb1 = p.header >> 8 & 0xff;
    final hb2 = p.header >> 16;
    expect(hb1 & 0xf0, 0, reason: 'layout 0');
    expect(hb2 & 0x0f, 0, reason: 'sample_flat');
    final present = hb1 & 0x0f;
    expect([1, 3, 7, 15], contains(present));
    for (var k = 0; k < 4; k++) {
      if (present >> k & 1 == 0) {
        expect(p.subs[k], 0);
        expect(hb2 >> (4 + k) & 1, 0);
        continue;
      }
      out.add((
        left: p.subs[k] & 0xffffff,
        right: p.subs[k] >> 24 & 0xffffff,
        status: p.subs[k] >> 48,
        block: hb2 >> (4 + k) & 1 == 1,
      ));
    }
  }
  return out;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('N and CTS equal the HDMI 1.4 tables and are exact', () {
    // HDMI 1.4 tables 7-1 (32 kHz), 7-2 (44.1 kHz) and 7-3 (48 kHz).
    const table = {
      25200000: [(4096, 25200), (6272, 28000), (6144, 25200)],
      27000000: [(4096, 27000), (6272, 30000), (6144, 27000)],
      74250000: [(4096, 74250), (6272, 82500), (6144, 74250)],
      148500000: [(4096, 148500), (6272, 165000), (6144, 148500)],
    };
    for (final e in table.entries) {
      for (final r in HdmiAudioRate.values) {
        final got = HdmiAcr.values(e.key, r);
        expect(got, e.value[r.index], reason: '${e.key} ${r.hz}');
        expect(128 * r.hz * got.$2, e.key * got.$1);
      }
    }
    // No row: the exact pair with N nearest to the default N.
    expect(HdmiAcr.values(25000000, HdmiAudioRate.fs32000), (4096, 25000));
    expect(HdmiAcr.values(25000000, HdmiAudioRate.fs44100), (7056, 31250));
    expect(HdmiAcr.values(25000000, HdmiAudioRate.fs48000), (6144, 25000));
    for (final r in HdmiAudioRate.values) {
      final (n, cts) = HdmiAcr.values(25000000, r);
      expect(128 * r.hz * cts, 25000000 * n, reason: '${r.hz}');
    }
    expect(HdmiAcr.values(_scaledClock, HdmiAudioRate.fs44100), (6272, 280));
    // No exact pair: the default N and a rounded CTS.
    const odd = 30000001;
    for (final r in HdmiAudioRate.values) {
      final (n, cts) = HdmiAcr.values(odd, r);
      expect(n, r.recommendedN, reason: '${r.hz}');
      expect(cts, (odd * n / (128 * r.hz)).round(), reason: '${r.hz}');
      expect(128 * r.hz * cts, isNot(odd * n), reason: '${r.hz}');
    }
    // No exact pair, CTS rounds to 34 and the fs error is 1.5 percent.
    expect(
      () => HdmiAcr.values(33501, HdmiAudioRate.fs32000),
      throwsArgumentError,
    );
  });

  test('the 1.001 clocks equal the HDMI 1.4 table rows', () {
    // Tables 7-1 to 7-3 for the clocks divided or multiplied by 1.001.
    final rows = {
      25175000: [(4576, 28125), (7007, 31250), (6864, 28125)],
      27027000: [(4096, 27027), (6272, 30030), (6144, 27027)],
      74175824: [(11648, 210938), (17836, 234375), (11648, 140625)],
      148351648: [(5824, 210938), (8918, 234375), (5824, 140625)],
    };
    for (final e in rows.entries) {
      for (final r in HdmiAudioRate.values) {
        final (n, cts) = HdmiAcr.values(e.key, r);
        expect((n, cts), e.value[r.index], reason: '${e.key} ${r.hz}');
        final ppm = (e.key * n / (128 * r.hz * cts) - 1).abs() * 1e6;
        expect(ppm, lessThan(10), reason: '${e.key} ${r.hz}');
      }
    }
  });

  test(
    'the rate generator gives fs strobes in 1 s',
    () async {
      for (final r in HdmiAudioRate.values) {
        const period = 10;
        final clk = SimpleClockGenerator(period).clk;
        final reset = Logic();
        final sel = Logic(width: 2);
        final gen = HdmiAudioRateGen(
          clk: clk,
          reset: reset,
          fsSel: sel,
          pixelClock: _scaledClock,
        );
        await gen.build();
        reset.inject(1);
        sel.inject(r.index);
        final (n, cts) = HdmiAcr.values(_scaledClock, r);
        // The select applies 2 clocks after the reset, so count from
        // clock 8 for 1 s of the scaled clock.
        const from = 8;
        var i = 0;
        var strobes = 0;
        var acrs = 0;
        var started = false;
        clk.negedge.listen((_) {
          if (!started) return;
          if (i == from) {
            expect(gen.rate.value.toInt(), r.index);
            expect(gen.n.value.toInt(), n);
            expect(gen.cts.value.toInt(), cts);
          }
          if (i >= from && i < from + _scaledClock) {
            strobes += gen.strobe.value.toInt();
            acrs += gen.acr.value.toInt();
          }
          i++;
        });
        Simulator.registerAction(period * 2 + period ~/ 2 - 1, () {
          reset.inject(0);
          started = true;
        });
        Simulator.setMaxSimTime(period * (_scaledClock + from + 8));
        await Simulator.run();
        expect(strobes, r.hz, reason: '${r.hz}');
        expect(acrs, _scaledClock ~/ cts, reason: '${r.hz}');
        await Simulator.reset();
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );

  test(
    'InfoFrames and ACR equal hand built CEA-861 and HDMI bytes',
    () async {
      // AVI v2: HB 82 02 0D, PB2 M1M0R3..R0, PB3 Q1Q0, PB4 VIC.
      // Q 0, M 0, VIC 16: 0x91 + 0x10 = 0xA1, PB0 0x5F.
      // Q 1, M 1 (PB2 0x18), VIC 4: 0x91 + 0x18 + 0x04 + 0x04 = 0xB1, 0x4F.
      // Q 2, M 2 (PB2 0x28), VIC 0: 0x91 + 0x28 + 0x08 = 0xC1, PB0 0x3F.
      // Audio: HB 84 01 0A, PB1 0x01, PB0 0x100 - 0x90 = 0x70.
      // ACR at 252 kHz: SB1..SB3 CTS, SB4..SB6 N.
      final cases = [
        (fs: 0, vic: 16, q: 0, m: 0, avi: 0x100000005F, acr: 0x001000FC000000),
        (fs: 1, vic: 4, q: 1, m: 1, avi: 0x040418004F, acr: 0x80180018010000),
        (fs: 2, vic: 0, q: 2, m: 2, avi: 0x000828003F, acr: 0x001800FC000000),
      ];
      for (final c in cases) {
        final r = await _run(8000, fs: c.fs, vic: c.vic, aviQ: c.q, aviM: c.m);
        await Simulator.reset();
        final avi = r.packets.where((p) => p.header & 0xff == 0x82).toList();
        final aif = r.packets.where((p) => p.header & 0xff == 0x84).toList();
        final acr = r.packets.where((p) => p.header & 0xff == 0x01).toList();
        expect(r.packets.map((p) => p.header & 0xff).toSet(), {
          0x01,
          0x02,
          0x82,
          0x84,
        });
        expect(avi.length, greaterThanOrEqualTo(r.frames));
        expect(aif.length, greaterThanOrEqualTo(r.frames));
        for (final p in avi) {
          expect(p.header, 0x0D0282);
          expect(p.subs, [c.avi, 0, 0, 0]);
          expect(_infoSum(p), 0);
        }
        for (final p in aif) {
          expect(p.header, 0x0A0184);
          expect(p.subs, [0x0170, 0, 0, 0]);
          expect(_infoSum(p), 0);
        }
        final (n, cts) = HdmiAcr.values(
          _scaledClock,
          HdmiAudioRate.values[c.fs],
        );
        expect(acr.length, inInclusiveRange(8000 ~/ cts - 1, 8000 ~/ cts));
        for (final p in acr) {
          expect(p.header, 0x000001);
          expect(p.subs, List.filled(4, c.acr));
          expect(
            _byte(p, 0, 1) << 16 | _byte(p, 0, 2) << 8 | _byte(p, 0, 3),
            cts,
          );
          expect(
            _byte(p, 0, 4) << 16 | _byte(p, 0, 5) << 8 | _byte(p, 0, 6),
            n,
          );
        }
        expect(r.missed, 0);
        expect(r.underruns, 0);
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );

  test(
    'IEC 60958 B, channel status and parity for each fs',
    () async {
      // IEC 60958-3 consumer channel status: bit 2 is 1 (no copyright),
      // bits 24..27 the fs (32 kHz
      // 1100, 44.1 kHz 0000, 48 kHz 0100, bit 24 first), bit 32 for 24-bit
      // max, bits 33..35 101 for 24 bits. All other bits 0.
      const statusOnes = {
        0: [2, 24, 25, 32, 33, 35],
        1: [2, 32, 33, 35],
        2: [2, 25, 32, 33, 35],
      };
      for (final fs in [0, 1, 2]) {
        final r = await _run(12000, fs: fs);
        await Simulator.reset();
        final frames = _frames(r.packets);
        expect(frames.length, greaterThan(3 * 192));
        for (final (i, f) in frames.indexed) {
          expect(f.left, i, reason: 'frame $i in order');
          expect(f.right, i ^ 0xABCDEF);
          expect(f.block, i % 192 == 0, reason: 'B at frame $i');
          final c = statusOnes[fs]!.contains(i % 192) ? 1 : 0;
          // Byte 6: PR CR UR VR PL CL UL VL.
          expect(f.status & 0x33, 0, reason: 'V and U are 0');
          expect(f.status >> 2 & 1, c, reason: 'CL of frame $i');
          expect(f.status >> 6 & 1, c, reason: 'CR of frame $i');
          expect((_ones(f.left) + _ones(f.status & 0x0f)).isEven, isTrue);
          expect((_ones(f.right) + _ones(f.status >> 4)).isEven, isTrue);
        }
        expect(r.missed, 0);
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );

  test('an empty source gives zero samples and underruns', () async {
    final r = await _run(4000, fs: 2, sourceOffAt: 2000);
    final frames = _frames(r.packets);
    final zero = frames.indexWhere((f) => f.left == 0 && f.right == 0, 1);
    expect(zero, greaterThan(300));
    for (final f in frames.sublist(zero)) {
      expect(f.left, 0);
      expect(f.right, 0);
    }
    for (final (i, f) in frames.sublist(0, zero).indexed) {
      expect(f.left, i);
    }
    // Up to 4 samples wait in the scheduler at the end. The bench reads
    // underrun before the source_on inject takes effect, so it can miss
    // the strobe of that clock.
    expect(
      r.underruns,
      inInclusiveRange(frames.length - zero - 1, frames.length - zero + 4),
    );
    expect(r.underruns, greaterThan(300));
  });

  test('a stalled packet port counts missed slots', () async {
    final r = await _run(4000, fs: 2, stallFrom: 500, stallTo: 2500);
    // 2000 clocks hold about 7 ACR periods and 380 samples.
    expect(r.missed, greaterThan(300));
    final last = r.packets.last;
    expect(r.packets.length, greaterThan(150));
    expect(last.header & 0xff, isIn([0x01, 0x02, 0x82, 0x84]));
    expect(_frames(r.packets).length, greaterThan(300));
  });
}
