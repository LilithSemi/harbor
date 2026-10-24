import 'package:rohd/rohd.dart';

import '../peripherals/display.dart';

/// Video timing generator: free-running pixel counters producing HSYNC, VSYNC,
/// data-enable, and the current pixel coordinates for a [HarborDisplayTiming].
///
/// Clocked by the pixel clock. [hsync]/[vsync] honor the timing's configured
/// polarity, so they are the real pin-level sync signals. [de] is high over the
/// visible region, [x]/[y] are the raw column/row counters (valid as pixel
/// coordinates while [de] is high).
class VideoTimingGenerator extends Module {
  Logic get hsync => output('hsync');
  Logic get vsync => output('vsync');
  Logic get de => output('de');
  Logic get x => output('x');
  Logic get y => output('y');

  final HarborDisplayTiming timing;

  VideoTimingGenerator({
    required this.timing,
    required Logic clk,
    required Logic reset,
    super.name = 'video_timing',
  }) : super(
         definitionName:
             'VideoTimingGenerator_${timing.hActive}_${timing.hFrontPorch}'
             '_${timing.hSyncWidth}_${timing.hBackPorch}_${timing.vActive}'
             '_${timing.vFrontPorch}_${timing.vSyncWidth}_${timing.vBackPorch}'
             '_${timing.hSyncPositive ? 1 : 0}${timing.vSyncPositive ? 1 : 0}',
       ) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    final hbits = (timing.hTotal - 1).bitLength;
    final vbits = (timing.vTotal - 1).bitLength;

    addOutput('hsync');
    addOutput('vsync');
    addOutput('de');
    addOutput('x', width: hbits);
    addOutput('y', width: vbits);

    final hc = Logic(name: 'h_count', width: hbits);
    final vc = Logic(name: 'v_count', width: vbits);

    final hEnd = hc.eq(timing.hTotal - 1);
    final vEnd = vc.eq(timing.vTotal - 1);

    Sequential(clk, reset: reset, [
      If(
        hEnd,
        then: [
          hc < 0,
          If(vEnd, then: [vc < 0], orElse: [vc < vc + 1]),
        ],
        orElse: [hc < hc + 1],
      ),
    ]);

    x <= hc;
    y <= vc;

    final hSyncStart = timing.hActive + timing.hFrontPorch;
    final hSyncEnd = hSyncStart + timing.hSyncWidth;
    final inHsync =
        hc.gte(Const(hSyncStart, width: hbits)) &
        hc.lt(Const(hSyncEnd, width: hbits));

    final vSyncStart = timing.vActive + timing.vFrontPorch;
    final vSyncEnd = vSyncStart + timing.vSyncWidth;
    final inVsync =
        vc.gte(Const(vSyncStart, width: vbits)) &
        vc.lt(Const(vSyncEnd, width: vbits));

    de <=
        hc.lt(Const(timing.hActive, width: hbits)) &
            vc.lt(Const(timing.vActive, width: vbits));

    // Apply the configured polarity so these are the real pin-level signals.
    hsync <= (timing.hSyncPositive ? inHsync : ~inHsync);
    vsync <= (timing.vSyncPositive ? inVsync : ~inVsync);
  }
}
