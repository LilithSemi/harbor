import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'echo_memory.dart';

const _memConfig = HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32);

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

HarborDualClockDisplay _display({
  required bool packets,
  Logic? hdmiEnable,
  Logic? valid,
  Logic? pixelClk,
  Logic? sysClk,
  Logic? pixelReset,
  Logic? sysReset,
  HarborMemoryWaist? memory,
  bool scan = true,
}) => HarborDualClockDisplay(
  target: const HarborSimTarget(),
  timing: _timing,
  pixelClk: pixelClk ?? Logic(),
  pixelReset: pixelReset ?? Logic(),
  shiftClk: sysClk ?? Logic(),
  shiftReset: sysReset ?? Logic(),
  sysClk: sysClk ?? Logic(),
  sysReset: sysReset ?? Logic(),
  enable: Const(scan ? 1 : 0),
  update: Const(1),
  fbBase: Const(0x100, width: 32),
  memory: memory ?? HarborMemoryWaist(_memConfig),
  hdmi: true,
  hdmiEnable: hdmiEnable ?? Logic(),
  hdmiPacketValid: packets ? (valid ?? Logic()) : null,
  hdmiPacketHeader: packets ? Const(0, width: 24) : null,
  hdmiPacketSubpacket: packets
      ? [for (var k = 0; k < 4; k++) Const(0, width: 56)]
      : null,
);

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('definition names differ with and without packet ports', () async {
    final a = _display(packets: true);
    final b = _display(packets: false);
    await a.build();
    await b.build();
    expect(a.definitionName, isNot(b.definitionName));
    expect(a.outputs.keys, contains('hdmi_packets_dropped'));
    expect(b.outputs.keys, isNot(contains('hdmi_packets_dropped')));
    expect(b.outputs.keys, contains('hdmi_active'));
  });

  Future<({List<int> active, List<int> dropped})> run(
    int clocks, {
    required int enableAt,
    required bool enabled,
    bool scan = true,
    int step = 1,
  }) async {
    final pixelClk = SimpleClockGenerator(14).clk;
    final sysClk = SimpleClockGenerator(6).clk;
    final pixelReset = Logic();
    final sysReset = Logic();
    final hdmiEnable = Logic();
    final valid = Logic();
    final memory = HarborMemoryWaist(_memConfig);
    final d = _display(
      memory: memory,
      scan: scan,
      packets: true,
      hdmiEnable: hdmiEnable,
      valid: valid,
      pixelClk: pixelClk,
      sysClk: sysClk,
      pixelReset: pixelReset,
      sysReset: sysReset,
    );
    final echo = EchoMemory(memory, sysClk, sysReset);
    await d.build();
    await echo.build();
    pixelReset.inject(1);
    sysReset.inject(1);
    hdmiEnable.inject(0);
    valid.inject(1);
    Simulator.setMaxSimTime(14 * (clocks + 100));
    unawaited(Simulator.run());
    await pixelClk.nextPosedge;
    await pixelClk.nextPosedge;
    pixelReset.inject(0);
    sysReset.inject(0);
    final active = <int>[];
    final dropped = <int>[];
    for (var i = 0; i < clocks; i += step) {
      if (step == 1) {
        await pixelClk.nextNegedge;
      } else {
        final done = Completer<void>();
        Simulator.registerAction(Simulator.time + 14 * step, done.complete);
        await done.future;
      }
      if (enabled && i == enableAt) hdmiEnable.inject(1);
      active.add(d.output('hdmi_active').value.toInt());
      dropped.add(d.output('hdmi_packets_dropped').value.toInt());
    }
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
    return (active: active, dropped: dropped);
  }

  test('hdmi_active rises only in the vertical blank', () async {
    const frame = 78 * 12;
    final r = await run(2 * frame, enableAt: 10, enabled: true);
    final rise = r.active.indexOf(1);
    expect(rise, greaterThanOrEqualTo(_timing.vActive * _timing.hTotal));
    expect(rise, lessThan(frame));
    expect(r.active.sublist(rise).every((v) => v == 1), isTrue);
  });

  test(
    'the drop count rises while hdmi is off and stops at 0xffff',
    () async {
      final r = await run(
        70000,
        enableAt: 0,
        enabled: false,
        scan: false,
        step: 100,
      );
      expect(r.active.every((v) => v == 0), isTrue);
      expect(r.dropped[2], greaterThan(0));
      expect(r.dropped[4], greaterThan(r.dropped[2]));
      for (var i = 1; i < r.dropped.length; i++) {
        expect(r.dropped[i], greaterThanOrEqualTo(r.dropped[i - 1]));
      }
      expect(r.dropped.last, 0xffff);
    },
    timeout: const Timeout(Duration(minutes: 20)),
    tags: ['slow'],
  );
}
