import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'bit_reader.dart';

/// Harbor AV1 `lr_params()` parser (loop restoration).
///
/// The frame header's restoration section, which selects per plane whether the
/// restoration filter built earlier (Wiener / SGR) runs: each plane reads a
/// 2-bit `lr_type` remapped to the AV1 enum (0=NONE, 3=SWITCHABLE, 1=WIENER,
/// 2=SGRPROJ). If any plane uses restoration it then reads the restoration unit
/// size shift (1 or 2 reads depending on `use_128x128_superblock`) and, for
/// subsampled chroma, the chroma size shift. A `lr_disabled` input (AllLossless
/// || allow_intrabc || !enable_restoration) forces RESTORE_NONE everywhere.
///
/// `restoration_size` is the luma unit size (RESTORATION_TILESIZE_MAX=256 >>
/// (2 - lr_unit_shift), i.e. 64/128/256). Conditional-read idiom. Combinational.
class HarborLrParamsParser extends BridgeModule {
  HarborLrParamsParser({int maxBytes = 16, String? name})
    : super('HarborLrParamsParser', name: name ?? 'lr_params') {
    final totalBits = maxBytes * 8;

    createPort('bytes', PortDirection.input, width: totalBits);
    createPort('num_planes', PortDirection.input, width: 2);
    createPort('subsampling_x', PortDirection.input, width: 1);
    createPort('subsampling_y', PortDirection.input, width: 1);
    createPort('use_128x128_superblock', PortDirection.input, width: 1);
    createPort('lr_disabled', PortDirection.input, width: 1);
    for (var i = 0; i < 3; i++) {
      addOutput('frame_restoration_type_$i', width: 2);
    }
    addOutput('uses_lr', width: 1);
    addOutput('lr_unit_shift', width: 2);
    addOutput('lr_uv_shift', width: 1);
    addOutput('restoration_size', width: 9);
    addOutput('bits_consumed', width: 8);

    final bytesIn = input('bytes');
    final numPlanes = input('num_planes');
    final subx = input('subsampling_x');
    final suby = input('subsampling_y');
    final use128 = input('use_128x128_superblock');
    final gateBase = ~input('lr_disabled');

    var idx = 0;
    (Logic, Logic) condFn(Logic off, Logic cond, int n, Logic dflt) {
      final r = HarborBitReader(maxBytes: maxBytes, name: 'fn${idx++}');
      addSubModule(r);
      r.input('bytes').srcConnection! <= bytesIn;
      r.input('bit_offset').srcConnection! <= off;
      r.input('n').srcConnection! <= Const(n, width: 6);
      return (
        mux(cond, r.output('value'), dflt),
        mux(cond, r.output('next_offset'), off),
      );
    }

    final z = Const(0, width: 32);
    var off = Const(0, width: totalBits.bitLength) as Logic;

    // Per-plane restoration type, remapped: 0->NONE, 1->SWITCHABLE(3),
    // 2->WIENER(1), 3->SGRPROJ(2).
    final frt = <Logic>[];
    for (var i = 0; i < 3; i++) {
      final planeActive = gateBase & Const(i, width: 2).lt(numPlanes);
      final (ltV, on) = condFn(off, planeActive, 2, z);
      final lt = ltV.getRange(0, 2);
      final remapped = mux(
        lt.eq(Const(0, width: 2)),
        Const(0, width: 2),
        mux(
          lt.eq(Const(1, width: 2)),
          Const(3, width: 2),
          mux<Logic>(
            lt.eq(Const(2, width: 2)),
            Const(1, width: 2),
            Const(2, width: 2),
          ),
        ),
      );
      frt.add(mux(planeActive, remapped, Const(0, width: 2)));
      off = on;
    }

    final usesLr = frt[0].or() | frt[1].or() | frt[2].or();
    final usesChromaLr = frt[1].or() | frt[2].or();

    // Unit-size shift: 128-SB reads one bit (+1), else one bit + optional extra.
    final (s0V, p1) = condFn(off, usesLr, 1, z);
    final s0 = s0V.getRange(0, 1);
    final (extraV, p2) = condFn(p1, usesLr & ~use128 & s0, 1, z);
    final extra = extraV.getRange(0, 1);
    final shift128 = (s0.zeroExtend(2) + Const(1, width: 2)).getRange(0, 2);
    final shiftNorm = mux(
      s0,
      (Const(1, width: 2) + extra.zeroExtend(2)).getRange(0, 2),
      Const(0, width: 2),
    );
    final unitShift = mux(
      usesLr,
      mux(use128, shift128, shiftNorm),
      Const(0, width: 2),
    );

    // Chroma size shift when subsampled and chroma uses LR.
    final uvCond = usesLr & subx & suby & usesChromaLr;
    final (uvV, p3) = condFn(p2, uvCond, 1, z);

    // restoration_size = 256 >> (2 - lr_unit_shift).
    final sizeShift = (Const(2, width: 2) - unitShift).getRange(0, 2);
    final restSize = (Const(256, width: 9) >>> sizeShift.zeroExtend(9))
        .getRange(0, 9);

    for (var i = 0; i < 3; i++) {
      output('frame_restoration_type_$i') <= frt[i];
    }
    output('uses_lr') <= usesLr;
    output('lr_unit_shift') <= unitShift;
    output('lr_uv_shift') <= uvV.getRange(0, 1);
    output('restoration_size') <= restSize;
    output('bits_consumed') <= p3.getRange(0, 8);
  }
}
