@Tags(['slow'])
library;

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'hdmi_bench.dart';

/// The 720p frame test runs in its own file. In one isolate after the
/// other framer tests it ran more than twice as slow.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test(
    '720p: hdmi off is DVI, then on decodes clean',
    () async {
      const timing = HarborDisplayTiming.hd720();
      final frame = timing.hTotal * timing.vTotal;
      // hdmi_enable goes high in frame 0 and takes effect in its vertical
      // blank. A logic source offers packets at random clocks.
      final run = await simulateHdmiFast(
        timing,
        2 * frame + 2 * timing.hTotal,
        hdmiAt: frame ~/ 2,
      );
      final on = hdmiStart(run);
      expect(on, greaterThan(timing.vActive * timing.hTotal));
      for (var c = 0; c < 3; c++) {
        expect(run.ch[c].sublist(2, on), run.dvi[c].sublist(2, on));
      }
      final d = checkHdmi(timing, run);
      expect(d.packets.length, greaterThan(100));
      expect(
        d.video.where((v) => v.pixels.length == timing.hActive).length,
        greaterThanOrEqualTo(timing.vActive),
      );
    },
    timeout: const Timeout(Duration(hours: 2)),
  );
}
