import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/tmds_decoder.dart';
import 'echo_memory.dart';

const _memConfig = HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32);

/// hblank 62 holds one packet, the vertical blank of 8 lines 18. At 1.8
/// MHz a frame of 936 clocks has 25 samples at 48 kHz, and the ACR period
/// at 48 kHz is CTS = 1800 clocks.
const _timing = HarborDisplayTiming(
  hActive: 16,
  hFrontPorch: 4,
  hSyncWidth: 8,
  hBackPorch: 50,
  vActive: 4,
  vFrontPorch: 2,
  vSyncWidth: 2,
  vBackPorch: 4,
  pixelClock: 1800000,
);

const _frame = 78 * 12;

/// A stereo source on the control clock: left is a count, right the
/// count xor 0x5A5A5A. It offers a sample while [on] is high.
class _Source extends Module {
  Logic get valid => output('valid');
  Logic get left => output('left');
  Logic get right => output('right');

  _Source(Logic clk, Logic reset, Logic on, Logic ready)
    : super(name: 'source') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    on = addInput('on', on);
    ready = addInput('ready', ready);
    final count = Logic(name: 'count', width: 24);
    Sequential(clk, reset: reset, [
      If(on & ready, then: [count < count + 1]),
    ]);
    addOutput('valid') <= on;
    addOutput('left', width: 24) <= count;
    addOutput('right', width: 24) <= count ^ Const(0x5A5A5A, width: 24);
  }
}

class _Run {
  final ch = [<int>[], <int>[], <int>[]];
  final rgb = <int>[];
  final sync = <int>[];
  var underruns = 0;
  var underrunPort = 0;
  var missedPort = 0;
}

/// Runs [clocks] pixel clocks. [hdmi] null makes a build without hdmi,
/// else it is the hdmi_enable value. [yuvOffset] makes a yuyv build with
/// that CSC output offset on all channels.
Future<_Run> _simulate(
  int clocks, {
  bool? hdmi = true,
  int sourceOffAt = -1,
  int? yuvOffset,
  int vic = 1,
  int fs = 2,
}) async {
  const pixelPeriod = 14;
  final pixelClk = SimpleClockGenerator(pixelPeriod).clk;
  final sysClk = SimpleClockGenerator(6).clk;
  final pixelReset = Logic(name: 'pixel_reset');
  final sysReset = Logic(name: 'sys_reset');
  final on = Logic(name: 'on');
  final ready = Logic(name: 'ready');
  final source = _Source(sysClk, sysReset, on, ready);
  final memory = HarborMemoryWaist(_memConfig);
  final audio = hdmi != null;
  final disp = HarborDualClockDisplay(
    target: const HarborSimTarget(),
    timing: _timing,
    pixelClk: pixelClk,
    pixelReset: pixelReset,
    shiftClk: sysClk,
    shiftReset: sysReset,
    sysClk: sysClk,
    sysReset: sysReset,
    enable: Const(1),
    update: Const(1),
    fbBase: Const(0x100, width: 32),
    memory: memory,
    pixelFormat: yuvOffset == null
        ? HarborPixelFormat.xrgb8888
        : HarborPixelFormat.yuyv,
    cscOutOffset: yuvOffset == null
        ? null
        : List.filled(3, Const(yuvOffset, width: 8)),
    hdmi: audio,
    hdmiEnable: audio ? Const(hdmi ? 1 : 0) : null,
    hdmiVic: audio ? Const(vic, width: 7) : null,
    audioFsSel: audio ? Const(fs, width: 2) : null,
    audioValid: audio ? source.valid : null,
    audioLeft: audio ? source.left : null,
    audioRight: audio ? source.right : null,
  );
  if (audio) {
    ready <= disp.output('audio_ready');
  } else {
    ready <= Const(1);
  }
  final echo = EchoMemory(memory, sysClk, sysReset);
  await disp.build();
  await echo.build();
  await source.build();

  pixelReset.inject(1);
  sysReset.inject(1);
  on.inject(1);
  final run = _Run();
  final symbols = disp.transmitter!.symbols;
  final sched = audio
      ? disp.subModules.whereType<HdmiPacketScheduler>().single
      : null;
  var started = false;
  var i = 0;
  pixelClk.negedge.listen((_) {
    if (!started || i >= clocks) return;
    for (var c = 0; c < 3; c++) {
      run.ch[c].add(symbols[c].value.toInt());
    }
    run.rgb.add(
      disp.red.value.toInt() << 16 |
          disp.green.value.toInt() << 8 |
          disp.blue.value.toInt(),
    );
    run.sync.add(disp.hsync.value.toInt() | disp.vsync.value.toInt() << 1);
    if (sched != null) {
      run.underruns += sched.underrun.value.toInt();
      run.underrunPort = disp.output('audio_underrun_count').value.toInt();
      run.missedPort = disp.output('hdmi_packets_missed').value.toInt();
    }
    if (i == sourceOffAt) on.inject(0);
    i++;
  });
  Simulator.registerAction(pixelPeriod * 2 + pixelPeriod ~/ 2 - 1, () {
    pixelReset.inject(0);
    sysReset.inject(0);
    started = true;
  });
  Simulator.setMaxSimTime(pixelPeriod * (clocks + 4));
  await Simulator.run();
  return run;
}

/// The decode from 20 clocks before the first preamble.
({TmdsDecode d, int from}) _decode(_Run run) {
  final dvi = decodeTmds(run.ch[0], run.ch[1], run.ch[2], hdmi: false);
  final on = dvi.periods
      .firstWhere(
        (p) =>
            p.kind == TmdsPeriodKind.videoPreamble ||
            p.kind == TmdsPeriodKind.islandPreamble,
      )
      .start;
  final from = on - 20;
  final d = decodeTmds(
    run.ch[0].sublist(from),
    run.ch[1].sublist(from),
    run.ch[2].sublist(from),
  );
  expect(d.errors, isEmpty, reason: d.errors.take(10).join('\n'));
  return (d: d, from: from);
}

/// Left samples of the audio sample packets in order, and the frame
/// indexes with B set.
({List<int> left, List<int> right, List<int> block}) _samples(TmdsDecode d) {
  final left = <int>[];
  final right = <int>[];
  final block = <int>[];
  for (final p in d.packets.where((p) => p.type == 0x02)) {
    final present = p.header >> 8 & 0x0f;
    for (var k = 0; k < 4; k++) {
      if (present >> k & 1 == 0) continue;
      if (p.header >> (20 + k) & 1 == 1) block.add(left.length);
      left.add(p.subpackets[k] & 0xffffff);
      right.add(p.subpackets[k] >> 24 & 0xffffff);
    }
  }
  return (left: left, right: right, block: block);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  HarborDualClockDisplay make({bool packets = false, bool partial = false}) =>
      HarborDualClockDisplay(
        target: const HarborSimTarget(),
        timing: _timing,
        pixelClk: Logic(),
        pixelReset: Logic(),
        shiftClk: Logic(),
        shiftReset: Logic(),
        sysClk: Logic(),
        sysReset: Logic(),
        enable: Logic(),
        update: Logic(),
        fbBase: Logic(width: 32),
        memory: HarborMemoryWaist(_memConfig),
        hdmi: true,
        hdmiEnable: Logic(),
        hdmiPacketValid: packets ? Logic() : null,
        hdmiPacketHeader: packets ? Logic(width: 24) : null,
        hdmiPacketSubpacket: packets
            ? [for (var k = 0; k < 4; k++) Logic(width: 56)]
            : null,
        hdmiVic: Logic(width: 7),
        audioFsSel: Logic(width: 2),
        audioValid: Logic(),
        audioLeft: Logic(width: 24),
        audioRight: partial ? null : Logic(width: 24),
      );

  test('an audio build has its own name and the audio ports', () async {
    final d = make();
    await d.build();
    expect(d.definitionName, endsWith('_hdmi_audio_p1800000'));
    expect(
      d.inputs.keys,
      containsAll([
        'hdmi_enable',
        'hdmi_vic',
        'audio_fs_sel',
        'audio_valid',
        'audio_left',
        'audio_right',
      ]),
    );
    expect(
      d.outputs.keys,
      containsAll([
        'audio_ready',
        'audio_underrun_count',
        'hdmi_packets_missed',
        'hdmi_packets_dropped',
        'hdmi_active',
      ]),
    );
    expect(d.inputs.keys, isNot(contains('hdmi_packet_valid')));
    expect(d.outputs.keys, isNot(contains('hdmi_packet_ready')));
    expect(() => make(packets: true), throwsArgumentError);
    expect(() => make(partial: true), throwsArgumentError);
  });

  test('hdmi_enable 0 gives the lanes of a build without hdmi', () async {
    const clocks = 3 * _frame;
    final a = await _simulate(clocks, hdmi: null);
    await Simulator.reset();
    final b = await _simulate(clocks, hdmi: false);
    for (var c = 0; c < 3; c++) {
      expect(b.ch[c], a.ch[c], reason: 'channel $c');
    }
  });

  test(
    'every packet type decodes clean in each frame',
    () async {
      const clocks = 12 * _frame;
      final run = await _simulate(clocks, vic: 2);
      final (:d, :from) = _decode(run);
      const lat = TmdsEncoder.latency;
      var pixels = 0;
      for (final v in d.video) {
        expect(v.guarded, isTrue);
        for (var k = 0; k < v.pixels.length; k++) {
          final j = from + v.start + k - lat;
          expect(v.pixels[k], run.rgb[j], reason: 'clock $j');
          pixels++;
        }
      }
      expect(pixels, greaterThanOrEqualTo(16 * 4 * 10));
      expect(d.packets.map((p) => p.type).toSet(), {0x01, 0x02, 0x82, 0x84});
      // Each full frame after the first preamble has both InfoFrames.
      final frames = (clocks - from) ~/ _frame;
      for (var f = 0; f < frames; f++) {
        final inFrame = d.packets.where(
          (p) => p.start >= f * _frame && p.start < (f + 1) * _frame,
        );
        expect(inFrame.where((p) => p.type == 0x82), isNotEmpty);
        expect(inFrame.where((p) => p.type == 0x84), isNotEmpty);
      }
      for (final p in d.packets.where((p) => p.type == 0x82)) {
        // Full range RGB, VIC 2: 0x91 + 0x08 + 0x02 = 0x9B, PB0 0x65.
        expect(p.subpackets, [0x00000208000065, 0, 0, 0]);
      }
      for (final p in d.packets.where((p) => p.type == 0x84)) {
        expect(p.header, 0x0A0184);
        expect(p.subpackets, [0x1160, 0, 0, 0]);
      }
      // 48 kHz at 1.8 MHz: N 6144 (0x1800), CTS 1800 (0x708).
      final acr = d.packets.where((p) => p.type == 0x01).toList();
      expect(acr.length, greaterThanOrEqualTo((clocks - from) ~/ 1800 - 1));
      for (final p in acr) {
        expect(p.subpackets, List.filled(4, 0x00180008070000));
      }
      final s = _samples(d);
      expect(s.left.length, greaterThan(250));
      final first = s.left.first;
      for (var k = 0; k < s.left.length; k++) {
        expect(s.left[k], first + k, reason: 'sample $k');
        expect(s.right[k], (first + k) ^ 0x5A5A5A);
      }
      expect(s.block, isNotEmpty);
      for (var k = 1; k < s.block.length; k++) {
        expect(s.block[k] - s.block[k - 1], 192);
      }
      expect(run.underruns, 0);
      expect(run.missedPort, 0);
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );

  test(
    'an empty FIFO sends zero samples and counts at the port',
    () async {
      const clocks = 6 * _frame;
      final run = await _simulate(clocks, sourceOffAt: 2 * _frame);
      final (:d, from: _) = _decode(run);
      final s = _samples(d);
      final zero = s.left.indexWhere((v) => v == 0, 1);
      expect(zero, greaterThan(0));
      for (var k = zero; k < s.left.length; k++) {
        expect(s.left[k], 0);
        expect(s.right[k], 0);
      }
      expect(s.left.length - zero, greaterThan(60));
      // 4 frames hold 100 strobes, and the FIFO holds 32 samples.
      expect(run.underruns, greaterThan(60));
      expect(
        run.underrunPort,
        inInclusiveRange(run.underruns - 1, run.underruns),
      );
    },
    timeout: const Timeout(Duration(minutes: 30)),
    tags: ['slow'],
  );

  test(
    'the AVI range bits follow the CSC output offset',
    () async {
      for (final (offset, pb3) in [(0, 0x08), (16, 0x04)]) {
        final run = await _simulate(4 * _frame, yuvOffset: offset, vic: 4);
        await Simulator.reset();
        final (:d, from: _) = _decode(run);
        final avi = d.packets.where((p) => p.type == 0x82).toList();
        expect(avi.length, greaterThanOrEqualTo(2));
        // 0x91 + PB3 + 0x04.
        final check = -(0x95 + pb3) & 0xff;
        for (final p in avi) {
          expect(p.subpackets[0], 0x04 << 32 | pb3 << 24 | check);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 30)),
    tags: ['slow'],
  );
}
