/// Floating point format geometry.
library;

/// A floating point format: one sign bit, an exponent field, and a mantissa
/// field.
///
/// The datapath is sized for the widest format an [HarborFpuConfig] enables.
/// A narrower format rounds at its own exponent range and mantissa position
/// inside that datapath.
class HarborFpFormat {
  /// Exponent field width in bits.
  final int exponentWidth;

  /// Mantissa field width in bits.
  final int mantissaWidth;

  const HarborFpFormat(this.exponentWidth, this.mantissaWidth);

  /// IEEE 754 binary16 (half precision).
  static const fp16 = HarborFpFormat(5, 10);

  /// Bfloat16: the binary32 exponent range with a 7-bit mantissa.
  static const bf16 = HarborFpFormat(8, 7);

  /// IEEE 754 binary32 (single precision).
  static const fp32 = HarborFpFormat(8, 23);

  /// IEEE 754 binary64 (double precision).
  static const fp64 = HarborFpFormat(11, 52);

  /// Total encoded width: sign bit plus the exponent and mantissa fields.
  int get width => 1 + exponentWidth + mantissaWidth;

  /// Exponent bias, `2^(exponentWidth - 1) - 1`.
  int get bias => (1 << (exponentWidth - 1)) - 1;

  @override
  bool operator ==(Object other) =>
      other is HarborFpFormat &&
      other.exponentWidth == exponentWidth &&
      other.mantissaWidth == mantissaWidth;

  @override
  int get hashCode => Object.hash(exponentWidth, mantissaWidth);

  @override
  String toString() => 'HarborFpFormat($exponentWidth, $mantissaWidth)';

  /// Short, stable token for this format, e.g. `E8M23` for fp32. Used to
  /// build a config-dependent `definitionName` for a module.
  String get tag => 'E${exponentWidth}M$mantissaWidth';
}
