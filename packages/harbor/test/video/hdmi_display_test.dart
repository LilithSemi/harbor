import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/tmds_decoder.dart';
import 'echo_memory.dart';

const _memConfig = HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32);

/// hblank 62 holds one packet, the vertical blank of 8 lines 18.
const _timing = HarborDisplayTiming(
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

typedef _Packet = ({int header, List<int> subs});

class _Run {
  final ch = [<int>[], <int>[], <int>[]];
  final rgb = <int>[];
  final de = <int>[];
  final sync = <int>[];
  final taken = <_Packet>[];
}

/// Runs a display for [clocks] pixel clocks after reset. [hdmi] null makes
/// a build without hdmi, else it is the hdmi_enable value. With [packets]
/// the source offers a new random packet whenever the last one is taken.
Future<_Run> _simulate(int clocks, {bool? hdmi, bool packets = false}) async {
  final pixelClk = SimpleClockGenerator(14).clk;
  final sysClk = SimpleClockGenerator(6).clk;
  final pixelReset = Logic(name: 'pixel_reset');
  final sysReset = Logic(name: 'sys_reset');
  final enable = Logic(name: 'enable');
  final base = Logic(name: 'fb_base', width: 32);
  final hdmiEnable = Logic(name: 'hdmi_enable');
  final valid = Logic(name: 'valid');
  final header = Logic(name: 'header', width: 24);
  final subs = [for (var k = 0; k < 4; k++) Logic(name: 's$k', width: 56)];
  final memory = HarborMemoryWaist(_memConfig);
  final disp = HarborDualClockDisplay(
    target: const HarborSimTarget(),
    timing: _timing,
    pixelClk: pixelClk,
    pixelReset: pixelReset,
    shiftClk: sysClk,
    shiftReset: sysReset,
    sysClk: sysClk,
    sysReset: sysReset,
    enable: enable,
    update: Const(1),
    fbBase: base,
    memory: memory,
    hdmi: hdmi != null,
    hdmiEnable: hdmi == null ? null : hdmiEnable,
    hdmiPacketValid: hdmi == null ? null : valid,
    hdmiPacketHeader: hdmi == null ? null : header,
    hdmiPacketSubpacket: hdmi == null ? null : subs,
  );
  final echo = EchoMemory(memory, sysClk, sysReset);
  await disp.build();
  await echo.build();

  pixelReset.inject(1);
  sysReset.inject(1);
  enable.inject(1);
  base.inject(0x100);
  hdmiEnable.inject(hdmi == true ? 1 : 0);
  valid.inject(0);
  header.inject(0);
  for (final s in subs) {
    s.inject(0);
  }
  Simulator.setMaxSimTime(14 * (clocks + 100));
  unawaited(Simulator.run());
  await pixelClk.nextPosedge;
  await pixelClk.nextPosedge;
  pixelReset.inject(0);
  sysReset.inject(0);
  final rng = Random(4);
  final run = _Run();
  _Packet? held;
  final symbols = disp.transmitter!.symbols;
  for (var i = 0; i < clocks; i++) {
    await pixelClk.nextNegedge;
    for (var c = 0; c < 3; c++) {
      run.ch[c].add(symbols[c].value.toInt());
    }
    run.de.add(disp.de.value.toInt());
    run.rgb.add(
      disp.red.value.toInt() << 16 |
          disp.green.value.toInt() << 8 |
          disp.blue.value.toInt(),
    );
    run.sync.add(disp.hsync.value.toInt() | disp.vsync.value.toInt() << 1);
    if (packets) {
      held ??= (
        header: rng.nextInt(1 << 24),
        subs: [
          for (var k = 0; k < 4; k++)
            (rng.nextInt(1 << 28) << 28) | rng.nextInt(1 << 28),
        ],
      );
      valid.inject(1);
      header.inject(held.header);
      for (var k = 0; k < 4; k++) {
        subs[k].inject(held.subs[k]);
      }
      // An inject takes effect later in the time step, so ready is read
      // a little after it, before the next posedge.
      final done = Completer<void>();
      Simulator.registerAction(Simulator.time + 2, done.complete);
      await done.future;
      if (disp.output('hdmi_packet_ready').value.toInt() == 1) {
        // With hdmi off the framer drops the packet.
        if (disp.framer!.active.value.toInt() == 1) run.taken.add(held);
        held = null;
      }
    }
  }
  await Simulator.endSimulation();
  await Simulator.simulationEnded;
  return run;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  HarborDualClockDisplay make({
    bool hdmi = true,
    bool packets = true,
    HarborDisplayInterface out = HarborDisplayInterface.dvi,
  }) => HarborDualClockDisplay(
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
    outputType: out,
    hdmi: hdmi,
    hdmiEnable: hdmi ? Logic() : null,
    hdmiPacketValid: packets ? Logic() : null,
    hdmiPacketHeader: packets ? Logic(width: 24) : null,
    hdmiPacketSubpacket: packets
        ? [for (var k = 0; k < 4; k++) Logic(width: 56)]
        : null,
  );

  test('an hdmi build has its own name and the hdmi ports', () async {
    final d = make();
    await d.build();
    expect(d.definitionName, endsWith('_hdmi'));
    expect(d.inputs.keys, containsAll(['hdmi_enable', 'hdmi_packet_valid']));
    expect(d.inputs.keys, contains('hdmi_packet_subpacket_3'));
    expect(d.outputs.keys, contains('hdmi_packet_ready'));
    expect(d.framer, isNotNull);
    final e = make(packets: false);
    await e.build();
    expect(e.inputs.keys, contains('hdmi_enable'));
    expect(e.inputs.keys, isNot(contains('hdmi_packet_valid')));
    expect(e.outputs.keys, isNot(contains('hdmi_packet_ready')));
    final plain = make(hdmi: false, packets: false);
    await plain.build();
    expect(plain.definitionName, isNot(endsWith('_hdmi')));
    expect(plain.framer, isNull);
    expect(plain.inputs.keys.where((k) => k.startsWith('hdmi')), isEmpty);
    expect(
      () => make(out: HarborDisplayInterface.parallelRgb),
      throwsArgumentError,
    );
    expect(() => make(hdmi: false), throwsArgumentError);
  });

  test('hdmi_enable 0 gives the lanes of a build without hdmi', () async {
    const clocks = 3 * 78 * 12;
    final a = await _simulate(clocks);
    await Simulator.reset();
    final b = await _simulate(clocks, hdmi: false, packets: true);
    for (var c = 0; c < 3; c++) {
      expect(b.ch[c], a.ch[c], reason: 'channel $c');
    }
    expect(a.de.where((v) => v == 1).length, greaterThanOrEqualTo(16 * 4 * 2));
  });

  test('hdmi_enable 1 decodes clean with the display pixels', () async {
    const clocks = 4 * 78 * 12;
    final run = await _simulate(clocks, hdmi: true, packets: true);
    // hdmi_enable goes in at the first vertical blank, so frame 0 is DVI.
    final dvi = decodeTmds(run.ch[0], run.ch[1], run.ch[2], hdmi: false);
    final on = dvi.periods
        .firstWhere(
          (p) =>
              p.kind == TmdsPeriodKind.videoPreamble ||
              p.kind == TmdsPeriodKind.islandPreamble,
        )
        .start;
    expect(on, greaterThan(_timing.vActive * _timing.hTotal));
    final from = on - 20;
    final d = decodeTmds(
      run.ch[0].sublist(from),
      run.ch[1].sublist(from),
      run.ch[2].sublist(from),
    );
    expect(d.errors, isEmpty, reason: d.errors.take(10).join('\n'));
    // The symbol of clock i comes from the outputs of clock i - 2.
    const lat = TmdsEncoder.latency;
    var pixels = 0;
    for (final v in d.video) {
      expect(v.guarded, isTrue);
      for (var k = 0; k < v.pixels.length; k++) {
        final j = from + v.start + k - lat;
        expect(run.de[j], 1);
        expect(v.pixels[k], run.rgb[j], reason: 'clock $j');
        pixels++;
      }
    }
    expect(pixels, greaterThanOrEqualTo(16 * 4 * 3));
    var synced = 0;
    for (var i = 0; i < d.sync.length; i++) {
      if (d.sync[i] < 0) continue;
      expect(d.sync[i], run.sync[from + i - lat], reason: 'sync at $i');
      synced++;
    }
    expect(synced, greaterThan(clocks ~/ 3));
    expect(d.packets.length, greaterThan(20));
    expect(run.taken.length - d.packets.length, inInclusiveRange(0, 1));
    for (var k = 0; k < d.packets.length; k++) {
      expect(d.packets[k].header, run.taken[k].header);
      expect(d.packets[k].subpackets, run.taken[k].subs);
    }
  });
}
