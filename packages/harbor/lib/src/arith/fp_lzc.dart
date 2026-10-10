import 'package:rohd/rohd.dart';

/// Leading zero count of [x]: x.width when [x] is zero.
///
/// A log depth tree of 2:1 muxes. Ones fill [x] below to a power of two, so
/// the count never runs past the real bits and a zero input reads as x.width.
Logic harborFpLeadingZeros(Logic x) {
  var n = 1;
  while (n < x.width + 1) {
    n *= 2;
  }
  final padded = [x, Const(1, width: n - x.width, fill: true)].swizzle();

  // Returns the zero flag and the count of a power of two wide slice.
  (Logic, Logic?) count(Logic v) {
    if (v.width == 1) {
      return (~v, null);
    }
    final half = v.width ~/ 2;
    final (zh, ch) = count(v.getRange(half, v.width));
    final (zl, cl) = count(v.getRange(0, half));
    final low = ch == null ? null : mux(zh, cl!, ch);
    return (zh & zl, low == null ? zh : [zh, low].swizzle());
  }

  return count(padded).$2!;
}
