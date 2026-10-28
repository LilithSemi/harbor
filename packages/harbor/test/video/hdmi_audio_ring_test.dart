import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/mem_target.dart';
import '../util/reg_bus.dart';
import '../util/tmds_decoder.dart';
import 'echo_memory.dart';

const _memConfig = HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32);

/// The small timing of hdmi_audio_test: 936 clocks a frame at 1.8 MHz, so
/// 48 kHz gives 25 samples a frame.
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
const _base = 0x4000;
const _frames = 400;

int _left(int k) => (k * 0x010203 + 0x123456) & 0xffffff;
int _right(int k) => _left(k) ^ 0xA5A5A5;

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'ring samples reach the HDMI audio sample packets',
    () async {
      const clocks = 12 * _frame;
      const pixelPeriod = 14;
      final pixelClk = SimpleClockGenerator(pixelPeriod).clk;
      final sysClk = SimpleClockGenerator(6).clk;
      final pixelReset = Logic(name: 'pixel_reset');
      final sysReset = Logic(name: 'sys_reset');

      final audio = HarborAudioController(baseAddress: 0x10060000);
      final top = MasterTop(
        audio,
        iface: 'dma',
        kind: HarborFabricKind.wishbone,
        config: _memConfig,
      );
      top.input('clk').srcConnection! <= sysClk;
      top.input('reset').srcConnection! <= sysReset;
      top.input('sdata_in').srcConnection! <= Const(0);
      final bus = RegBus.attach(top, sysClk);
      final mem = BeatMemory(top, sysClk, latency: 4);
      for (var k = 0; k < _frames; k++) {
        mem.writeWord(_base + 8 * k, _left(k));
        mem.writeWord(_base + 8 * k + 4, _right(k));
      }

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
        enable: Const(1),
        update: Const(1),
        fbBase: Const(0x100, width: 32),
        memory: memory,
        hdmi: true,
        hdmiEnable: Const(1),
        hdmiVic: Const(1, width: 7),
        hdmiAviQ: Const(0, width: 2),
        hdmiAviM: Const(0, width: 2),
        audioFsSel: Const(2, width: 2),
        audioValid: top.output('audio_valid'),
        audioLeft: top.output('audio_left'),
        audioRight: top.output('audio_right'),
      );
      top.input('audio_ready').srcConnection! <= disp.output('audio_ready');
      final echo = EchoMemory(memory, sysClk, sysReset);
      await top.build();
      await disp.build();
      await echo.build();

      bus.idle();
      pixelReset.inject(1);
      sysReset.inject(1);
      final ch = [<int>[], <int>[], <int>[]];
      final symbols = disp.transmitter!.symbols;
      final sched = disp.subModules.whereType<HdmiPacketScheduler>().single;
      var underruns = 0;
      var started = false;
      var i = 0;
      pixelClk.negedge.listen((_) {
        if (!started || i >= clocks) return;
        for (var c = 0; c < 3; c++) {
          ch[c].add(symbols[c].value.toInt());
        }
        underruns += sched.underrun.value.toInt();
        i++;
      });
      Simulator.registerAction(pixelPeriod * 2 + pixelPeriod ~/ 2 - 1, () {
        pixelReset.inject(0);
        sysReset.inject(0);
        started = true;
      });
      Simulator.setMaxSimTime(pixelPeriod * (clocks + 4));
      final sim = Simulator.run();
      mem.start();
      await sysClk.nextPosedge;
      while (!started) {
        await sysClk.nextPosedge;
      }
      await bus.write(0x30, _base);
      await bus.write(0x38, (_frames + 1) * 8);
      await bus.write(0x40, _frames * 8);
      await bus.write(0x20, 1);
      await sim;

      // Decode from 20 clocks before the first preamble.
      final dvi = decodeTmds(ch[0], ch[1], ch[2], hdmi: false);
      final from =
          dvi.periods
              .firstWhere(
                (p) =>
                    p.kind == TmdsPeriodKind.videoPreamble ||
                    p.kind == TmdsPeriodKind.islandPreamble,
              )
              .start -
          20;
      final d = decodeTmds(
        ch[0].sublist(from),
        ch[1].sublist(from),
        ch[2].sublist(from),
      );
      expect(d.errors, isEmpty, reason: d.errors.take(10).join('\n'));
      final left = <int>[];
      final right = <int>[];
      for (final p in d.packets.where((p) => p.type == 0x02)) {
        final present = p.header >> 8 & 0x0f;
        for (var k = 0; k < 4; k++) {
          if (present >> k & 1 == 0) continue;
          left.add(p.subpackets[k] & 0xffffff);
          right.add(p.subpackets[k] >> 24 & 0xffffff);
        }
      }
      expect(left.length, greaterThan(250));
      for (var k = 0; k < left.length; k++) {
        expect(left[k], _left(k), reason: 'left $k');
        expect(right[k], _right(k), reason: 'right $k');
      }
      expect(underruns, 0);
      expect(disp.output('audio_underrun_count').value.toInt(), 0);
      expect(top.output('tx_underrun_count').value.toInt(), 0);
      expect(top.output('tx_dma_error').value.toInt(), 0);
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
