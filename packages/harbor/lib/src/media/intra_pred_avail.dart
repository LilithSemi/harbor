import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_mode_pred.dart';

/// Harbor bit-exact AV1 intra predictor WITH neighbour availability (bd 8,
/// angle_delta = 0, no edge filter, above-right / below-left treated as repeat).
///
/// Wraps [HarborIntraModePred] with the libaom edge construction for missing
/// neighbours (`predictIntraRaw` / `_build`): when `have_above` / `have_left`
/// is low the above / left arrays are filled with defaults (127 / 129) or
/// cross-filled from the other side, the corner resolves to the available
/// source or 128, and DC uses its availability variant (both / left / top /
/// 128). Every real frame needs this: the top-left block has no neighbours.
///
/// Ports: `mode` (4b, y_mode 0..12), `have_above` / `have_left` (1b), `above` /
/// `left` (bs neighbour pixels, 8b), `above_left` (corner) -> `pred`
/// (bs*bs predicted pixels, row-major, 8b). Combinational.
class HarborIntraPredAvail extends BridgeModule {
  /// Block size (square): 4, 8 or 16.
  final int bs;

  /// Sample bit depth (8/10/12). bd 8 is byte-identical to the original.
  final int bitDepth;

  HarborIntraPredAvail({required this.bs, this.bitDepth = 8, String? name})
    : assert(bs == 4 || bs == 8 || bs == 16 || bs == 32, 'bs 4/8/16/32'),
      assert(bitDepth == 8 || bitDepth == 10 || bitDepth == 12, 'bit depth'),
      super(
        'HarborIntraPredAvail_S${bs}_B$bitDepth',
        name: name ?? 'intra_pred_avail_${bs}_$bitDepth',
      ) {
    final pw = bitDepth;
    createPort('mode', PortDirection.input, width: 4);
    createPort('have_above', PortDirection.input);
    createPort('have_left', PortDirection.input);
    createPort('above', PortDirection.input, width: bs * pw);
    createPort('left', PortDirection.input, width: bs * pw);
    createPort('above_left', PortDirection.input, width: pw);
    addOutput('pred', width: bs * bs * pw);

    final mode = input('mode');
    final haveA = input('have_above');
    final haveL = input('have_left');
    final aboveLeft = input('above_left');
    Logic aPix(int i) => input('above').getRange(i * pw, i * pw + pw);
    Logic lPix(int i) => input('left').getRange(i * pw, i * pw + pw);

    final base = 1 << (bitDepth - 1); // 128 at bd8
    final defAbove = Const(base - 1, width: pw); // 127 at bd8
    final defLeft = Const(base + 1, width: pw); // 129 at bd8

    // Constructed (availability-resolved) neighbour arrays.
    //  aboveC[i] = haveA ? above[i] : (haveL ? left[0] : 127)
    //  leftC[i]  = haveL ? left[i]  : (haveA ? above[0] : 129)
    final aboveC = [
      for (var i = 0; i < bs; i++)
        mux(haveA, aPix(i), mux(haveL, lPix(0), defAbove)),
    ];
    final leftC = [
      for (var i = 0; i < bs; i++)
        mux(haveL, lPix(i), mux(haveA, aPix(0), defLeft)),
    ];
    final cornerC = mux(
      haveA & haveL,
      aboveLeft,
      mux(haveA, aPix(0), mux(haveL, lPix(0), Const(base, width: pw))),
    );

    // Proven predictor over the constructed arrays (correct for every mode
    // except DC, whose averaging depends on availability, overridden below).
    final pred = HarborIntraModePred(bs: bs, bitDepth: bitDepth, name: 'pred');
    addSubModule(pred);
    pred.input('mode').srcConnection! <= mode;
    pred.input('above').srcConnection! <=
        [for (var i = bs - 1; i >= 0; i--) aboveC[i]].swizzle();
    pred.input('left').srcConnection! <=
        [for (var i = bs - 1; i >= 0; i--) leftC[i]].swizzle();
    pred.input('above_left').srcConnection! <= cornerC;
    final predFull = pred.output('pred');

    // DC availability variant -> a single broadcast value.
    final bsLog2 = bs.bitLength - 1;
    final maxV = (1 << bitDepth) - 1;
    final accW = (2 * bs * maxV + bs).bitLength + 2; // 14 -> holds every sum
    Logic sumOf(List<Logic> a) {
      Logic s = a[0].zeroExtend(accW);
      for (var i = 1; i < bs; i++) {
        s = (s + a[i].zeroExtend(accW)).getRange(0, accW);
      }
      return s;
    }

    final sumA = sumOf([for (var i = 0; i < bs; i++) aPix(i)]);
    final sumL = sumOf([for (var i = 0; i < bs; i++) lPix(i)]);
    final dcBoth = ((sumA + sumL).getRange(0, accW) + Const(bs, width: accW))
        .getRange(bsLog2 + 1, accW); // >> (log2+1)
    final dcLeftV = (sumL + Const(bs >> 1, width: accW)).getRange(bsLog2, accW);
    final dcTopV = (sumA + Const(bs >> 1, width: accW)).getRange(bsLog2, accW);
    final dcVal = mux(
      haveL & haveA,
      dcBoth.getRange(0, pw),
      mux(
        haveL,
        dcLeftV.getRange(0, pw),
        mux(haveA, dcTopV.getRange(0, pw), Const(base, width: pw)),
      ),
    );
    final isDc = mode.eq(Const(0, width: 4));
    final predDc = [for (var i = 0; i < bs * bs; i++) dcVal].swizzle();

    output('pred') <= mux(isDc, predDc, predFull);
  }
}
