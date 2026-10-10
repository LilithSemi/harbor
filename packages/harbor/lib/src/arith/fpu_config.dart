/// Shared FPU elaboration config: ops, formats, pipeline depth.
library;

import '../riscv/micro_op.dart';
import 'fp_format.dart';

/// An operation the Harbor FPU can perform.
///
/// `fpToFp`, `fpToInt` and `intToFp` cover every RISC-V `fcvt` variant. The
/// source and destination formats or widths come from the micro-op, not the
/// enum value.
enum HarborFpOp {
  add,
  sub,
  mul,
  madd,
  msub,
  nmsub,
  nmadd,
  div,
  sqrt,
  eq,
  lt,
  le,
  ltq,
  leq,
  min,
  max,
  minm,
  maxm,
  classify,
  sgnj,
  sgnjn,
  sgnjx,
  fpToFp,
  fpToInt,
  intToFp,
  cvtModWD,
  li,
  round,
  roundNx,
  rec7,
  rsqrt7,
}

/// Divider iteration strategy.
enum HarborFpDivMode {
  /// One op at a time on shared hardware, a digit each cycle (or two at
  /// radix 4). Latency is `steps / k + 4`, not [HarborFpuConfig.divStages].
  /// That field is ignored in this mode.
  iterative,

  /// A new divide can start every cycle. Results come out in order.
  pipelined,
}

/// How the FMA path builds the significand product.
enum HarborFpMultiplier {
  /// Plain `*` on operand slices that each fit one FPGA DSP block. See
  /// [HarborFpuConfig.mulSlice].
  dsp,

  /// A rohd_hcl radix 4 Booth compression tree in logic.
  compressionTree,
}

/// A pipeline cut point in the shared FPU datapath.
///
/// C1 is after unpack, C2 is after the partial products, C3 is after
/// reduction, C4 is after add, C5 is after normalize, C6 is between round
/// and pack (`HarborFpRound` and `HarborFpPack`), C7 is after pack.
enum HarborFpCut { c1, c2, c3, c4, c5, c6, c7 }

/// Elaboration-time configuration for the Harbor FPU.
///
/// Logic for an op outside [ops], a format outside [formats], or a widening
/// pair outside [widening] is not built.
class HarborFpuConfig {
  /// Enabled formats. The runtime format index is the position in this
  /// list.
  final List<HarborFpFormat> formats;

  /// Widening pairs as `(narrow, wide)`, e.g. a widening FMA that reads fp16
  /// operands and accumulates in fp32.
  final List<(HarborFpFormat, HarborFpFormat)> widening;

  /// Enabled operations.
  final Set<HarborFpOp> ops;

  /// Pipeline depth, 0 to 7. Selects the cut set from the stage table.
  final int stages;

  /// Flush subnormal inputs and outputs to signed zero.
  final bool ftz;

  /// Divider iteration strategy.
  final HarborFpDivMode divMode;

  /// Divider radix, 2 or 4.
  final int divRadix;

  /// Divider pipeline stages.
  final int divStages;

  /// FP to integer and integer to FP widths, e.g. `[32, 64]`.
  final List<int> intWidths;

  /// How the FMA path builds the significand product.
  final HarborFpMultiplier multiplier;

  /// Unsigned operand widths `(a, b)` of one DSP multiply, for
  /// [HarborFpMultiplier.dsp]. ECP5 MULT18X18D takes `(18, 18)`. A Xilinx
  /// DSP48E2 (27x18 signed) takes `(26, 17)` and a DSP48E1 takes `(24, 17)`.
  final (int, int) mulSlice;

  /// Formats that size the significand product width `pm`, together with
  /// the narrow side of each widening pair. Null means all of [formats]. A
  /// `mul` or madd op is computed exactly when its format's mantissa plus
  /// hidden bit fits `pm`. Otherwise it gives the canonical NaN and NV.
  final Set<HarborFpFormat>? mulFormats;

  HarborFpuConfig({
    required List<HarborFpFormat> formats,
    List<(HarborFpFormat, HarborFpFormat)> widening = const [],
    required Set<HarborFpOp> ops,
    required this.stages,
    this.ftz = false,
    this.divMode = HarborFpDivMode.iterative,
    this.divRadix = 2,
    this.divStages = 1,
    List<int> intWidths = const [],
    this.multiplier = HarborFpMultiplier.dsp,
    this.mulSlice = (18, 18),
    Set<HarborFpFormat>? mulFormats,
  }) : formats = List.unmodifiable(formats),
       widening = List.unmodifiable(widening),
       ops = Set.unmodifiable(ops),
       intWidths = List.unmodifiable(intWidths),
       mulFormats = mulFormats == null ? null : Set.unmodifiable(mulFormats) {
    if (formats.isEmpty) {
      throw ArgumentError.value(formats, 'formats', 'must not be empty');
    }
    if (stages < 0 || stages > 7) {
      throw ArgumentError.value(stages, 'stages', 'must be 0 to 7');
    }
    if (divRadix != 2 && divRadix != 4) {
      throw ArgumentError.value(divRadix, 'divRadix', 'must be 2 or 4');
    }
    for (final pair in widening) {
      final (narrow, wide) = pair;
      if (!formats.contains(narrow) || !formats.contains(wide)) {
        throw ArgumentError.value(
          pair,
          'widening',
          'narrow and wide formats must both be in formats',
        );
      }
      if (narrow.width >= wide.width) {
        throw ArgumentError.value(
          pair,
          'widening',
          'narrow format must be smaller than wide format',
        );
      }
    }
    if (mulSlice.$1 < 2 || mulSlice.$2 < 2) {
      throw ArgumentError.value(mulSlice, 'mulSlice', 'must be 2 or more');
    }
    if (mulFormats case final mf?) {
      if (!formats.toSet().containsAll(mf)) {
        throw ArgumentError.value(mf, 'mulFormats', 'must be in formats');
      }
      final multiplies = ops.intersection(const {
        HarborFpOp.mul,
        HarborFpOp.madd,
        HarborFpOp.msub,
        HarborFpOp.nmsub,
        HarborFpOp.nmadd,
      });
      if (mf.isEmpty && widening.isEmpty && multiplies.isNotEmpty) {
        throw ArgumentError.value(
          mf,
          'mulFormats',
          'leaves no format for ${multiplies.first.name}',
        );
      }
    }
    if (ops.contains(HarborFpOp.cvtModWD) &&
        (!formats.contains(HarborFpFormat.fp64) || !intWidths.contains(32))) {
      throw ArgumentError('cvtModWD needs fp64 in formats and 32 in intWidths');
    }
  }

  /// Pipeline cut points for [stages], from the stage table. The table
  /// comes from logic levels and routed Fmax on ECP5 for fp32, fp64 and a
  /// fp16 to fp32 widening config.
  Set<HarborFpCut> get cuts => switch (stages) {
    0 => const {},
    1 => const {HarborFpCut.c4},
    2 => const {HarborFpCut.c3, HarborFpCut.c5},
    3 => const {HarborFpCut.c2, HarborFpCut.c4, HarborFpCut.c5},
    4 => const {HarborFpCut.c2, HarborFpCut.c4, HarborFpCut.c5, HarborFpCut.c6},
    5 => const {
      HarborFpCut.c1,
      HarborFpCut.c2,
      HarborFpCut.c4,
      HarborFpCut.c5,
      HarborFpCut.c6,
    },
    6 => const {
      HarborFpCut.c1,
      HarborFpCut.c2,
      HarborFpCut.c3,
      HarborFpCut.c4,
      HarborFpCut.c5,
      HarborFpCut.c6,
    },
    _ => HarborFpCut.values.toSet(),
  };

  /// Pipeline latency in cycles: the number of cuts.
  int get latency => cuts.length;

  /// The widest configured format.
  HarborFpFormat get widest =>
      formats.reduce((a, b) => a.width >= b.width ? a : b);

  /// Width of the runtime format index (`in_fmt` and similar ports).
  int get fmtWidth => (formats.length - 1).bitLength.clamp(1, 64);
}

/// Orders formats by exponent width then mantissa width, a total order
/// over distinct formats. Used to give a set of formats a fixed order
/// before it feeds a `definitionName`, since two logically equal sets
/// built in a different insertion order iterate differently.
int harborFpFormatCompare(HarborFpFormat a, HarborFpFormat b) {
  final e = a.exponentWidth.compareTo(b.exponentWidth);
  return e != 0 ? e : a.mantissaWidth.compareTo(b.mantissaWidth);
}

/// Builds a `definitionName` from [prefix] and [parts], joined with `_`.
///
/// Past [maxLength] characters the parts collapse into a short, stable
/// hash instead, so a `definitionName` built from many parameters never
/// grows without bound. Two calls with the same parts always give the
/// same name. Different parts almost always give a different name.
String harborStableDefinitionName(
  String prefix,
  List<String> parts, {
  int maxLength = 100,
}) {
  final tail = parts.join('_');
  final full = tail.isEmpty ? prefix : '${prefix}_$tail';
  if (full.length <= maxLength) {
    return full;
  }
  var hash = 0x811c9dc5;
  for (final c in tail.codeUnits) {
    hash = (hash ^ c) & 0xffffffff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return '${prefix}_H${hash.toRadixString(16).padLeft(8, '0')}';
}

/// Maps a RISC-V FPU funct to the [HarborFpOp] that implements it.
///
/// Returns null for `fmv` and `fmvXH`, which move bits between register
/// files and need no FPU op. Every `fcvt` variant maps to `fpToFp`,
/// `fpToInt` or `intToFp`. The source and destination come from the
/// micro-op, not from the returned op.
HarborFpOp? harborFpOpFor(RiscVFpuFunct f) => switch (f) {
  RiscVFpuFunct.fadd => HarborFpOp.add,
  RiscVFpuFunct.fsub => HarborFpOp.sub,
  RiscVFpuFunct.fmul => HarborFpOp.mul,
  RiscVFpuFunct.fdiv => HarborFpOp.div,
  RiscVFpuFunct.fsqrt => HarborFpOp.sqrt,
  RiscVFpuFunct.fcvtWS => HarborFpOp.fpToInt,
  RiscVFpuFunct.fcvtSW => HarborFpOp.intToFp,
  RiscVFpuFunct.fcvtLS => HarborFpOp.fpToInt,
  RiscVFpuFunct.fcvtSL => HarborFpOp.intToFp,
  RiscVFpuFunct.fcvtWD => HarborFpOp.fpToInt,
  RiscVFpuFunct.fcvtDW => HarborFpOp.intToFp,
  RiscVFpuFunct.fcvtLD => HarborFpOp.fpToInt,
  RiscVFpuFunct.fcvtDL => HarborFpOp.intToFp,
  RiscVFpuFunct.fcvtSD => HarborFpOp.fpToFp,
  RiscVFpuFunct.fcvtDS => HarborFpOp.fpToFp,
  RiscVFpuFunct.feq => HarborFpOp.eq,
  RiscVFpuFunct.flt => HarborFpOp.lt,
  RiscVFpuFunct.fle => HarborFpOp.le,
  RiscVFpuFunct.fmv => null,
  RiscVFpuFunct.fclass => HarborFpOp.classify,
  RiscVFpuFunct.fsgnj => HarborFpOp.sgnj,
  RiscVFpuFunct.fsgnjn => HarborFpOp.sgnjn,
  RiscVFpuFunct.fsgnjx => HarborFpOp.sgnjx,
  RiscVFpuFunct.fmin => HarborFpOp.min,
  RiscVFpuFunct.fmax => HarborFpOp.max,
  RiscVFpuFunct.fmadd => HarborFpOp.madd,
  RiscVFpuFunct.fmsub => HarborFpOp.msub,
  RiscVFpuFunct.fnmsub => HarborFpOp.nmsub,
  RiscVFpuFunct.fnmadd => HarborFpOp.nmadd,
  RiscVFpuFunct.fcvtSH => HarborFpOp.fpToFp,
  RiscVFpuFunct.fcvtHS => HarborFpOp.fpToFp,
  RiscVFpuFunct.fli => HarborFpOp.li,
  RiscVFpuFunct.fminm => HarborFpOp.minm,
  RiscVFpuFunct.fmaxm => HarborFpOp.maxm,
  RiscVFpuFunct.fround => HarborFpOp.round,
  RiscVFpuFunct.froundnx => HarborFpOp.roundNx,
  RiscVFpuFunct.fleq => HarborFpOp.leq,
  RiscVFpuFunct.fltq => HarborFpOp.ltq,
  RiscVFpuFunct.fcvtmodWD => HarborFpOp.cvtModWD,
  RiscVFpuFunct.fcvtDH => HarborFpOp.fpToFp,
  RiscVFpuFunct.fcvtHD => HarborFpOp.fpToFp,
  RiscVFpuFunct.fmvXH => null,
};
