import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One test case from `testfloat_gen`.
///
/// [flags] holds the five IEEE exception flags in the same bit order as
/// RISC-V fflags: bit 4 is NV, bit 3 is DZ, bit 2 is OF, bit 1 is UF, and
/// bit 0 is NX.
class TestFloatCase {
  /// The input operands, in the order `testfloat_gen` printed them.
  final List<BigInt> operands;

  /// The expected result.
  final BigInt result;

  /// The expected exception flags, NV DZ OF UF NX from bit 4 to bit 0.
  final int flags;

  const TestFloatCase({
    required this.operands,
    required this.result,
    required this.flags,
  });

  @override
  String toString() =>
      'TestFloatCase(${operands.map((o) => o.toRadixString(16)).join(' ')} '
      '-> ${result.toRadixString(16)}, flags: '
      '${flags.toRadixString(16).padLeft(2, '0')})';
}

String _testFloatGenPath() =>
    Platform.environment['HARBOR_TESTFLOAT_GEN'] ?? 'testfloat_gen';

/// True when `testfloat_gen` can be run, either from `$HARBOR_TESTFLOAT_GEN`
/// or from PATH. Tests call this to skip with a reason when it is missing.
bool testFloatAvailable() {
  try {
    final result = Process.runSync(_testFloatGenPath(), ['-help']);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

TestFloatCase _parseLine(String line) {
  final tokens = line.trim().split(RegExp(r'\s+'));
  if (tokens.length < 2) {
    throw FormatException('Bad testfloat_gen line: $line');
  }
  final flags = int.parse(tokens.removeLast(), radix: 16);
  final result = BigInt.parse(tokens.removeLast(), radix: 16);
  final operands = [for (final token in tokens) BigInt.parse(token, radix: 16)];
  return TestFloatCase(operands: operands, result: result, flags: flags);
}

/// Runs `testfloat_gen` for [op] and streams its test cases. [stride]
/// samples every nth case instead of a prefix; [exact] passes `-exact` so
/// round-to-integer ops report NX. [onStart] hands back the child process,
/// for tests that check it exits after the stream is cancelled.
Stream<TestFloatCase> testFloatCases(
  String op, {
  required String rm,
  int level = 1,
  int? seed,
  int? count,
  int stride = 1,
  bool exact = false,
  void Function(Process process)? onStart,
}) async* {
  final exe = _testFloatGenPath();
  final args = [
    '-tininessafter',
    if (exact) '-exact',
    '-r$rm',
    '-level',
    '$level',
    if (seed != null) ...['-seed', '$seed'],
    if (count != null) ...['-n', '$count'],
    op,
  ];

  final process = await Process.start(exe, args);
  onStart?.call(process);
  final stderrText = process.stderr.transform(utf8.decoder).join();

  final lines = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter());

  try {
    var i = 0;
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      if (i % stride == 0) yield _parseLine(line);
      i++;
    }

    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      throw ProcessException(exe, args, (await stderrText).trim(), exitCode);
    }
  } finally {
    process.kill();
  }
}
