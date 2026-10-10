import '../util/pretty_string.dart';

/// Cache replacement policy.
enum HarborReplacementPolicy {
  /// Least Recently Used.
  lru,

  /// Pseudo-LRU (tree-based approximation).
  plru,

  /// Random replacement.
  random,

  /// First-In First-Out.
  fifo,
}

/// Cache write policy.
enum HarborWritePolicy {
  /// Write-through: writes go to both cache and backing memory.
  writeThrough,

  /// Write-back: writes go to cache, dirty lines written on eviction.
  writeBack,
}

/// Cache write-miss policy.
enum HarborWriteMissPolicy {
  /// Write-allocate: on write miss, fetch line then write.
  writeAllocate,

  /// No-write-allocate: on write miss, write directly to memory.
  noWriteAllocate,
}

/// Cache inclusion policy for multi-level hierarchies.
enum HarborInclusionPolicy {
  /// Inclusive: L1 contents are always in L2.
  inclusive,

  /// Exclusive: a line exists in exactly one level.
  exclusive,

  /// Non-inclusive non-exclusive: no constraint.
  nine,
}

/// Coherency protocol.
enum HarborCoherencyProtocol {
  /// No coherency (single-core or software-managed).
  none,

  /// MSI: Modified, Shared, Invalid.
  msi,

  /// MESI: Modified, Exclusive, Shared, Invalid.
  mesi,

  /// MOESI: Modified, Owned, Exclusive, Shared, Invalid.
  moesi,
}

/// Configuration for a single cache level.
class HarborCacheConfig with HarborPrettyString {
  /// Total cache size in bytes.
  final int size;

  /// Cache line (block) size in bytes.
  final int lineSize;

  /// Number of ways (associativity). 1 = direct-mapped.
  final int ways;

  /// Replacement policy.
  final HarborReplacementPolicy replacementPolicy;

  /// Write policy.
  final HarborWritePolicy writePolicy;

  /// Write-miss policy.
  final HarborWriteMissPolicy writeMissPolicy;

  /// Number of MSHR (Miss Status Holding Register) entries.
  /// Controls how many outstanding misses can be tracked.
  final int mshrEntries;

  /// Number of write buffer entries.
  final int writeBufferEntries;

  /// Access latency in cycles (for timing models).
  final int latencyCycles;

  const HarborCacheConfig({
    required this.size,
    this.lineSize = 64,
    required this.ways,
    this.replacementPolicy = HarborReplacementPolicy.plru,
    this.writePolicy = HarborWritePolicy.writeBack,
    this.writeMissPolicy = HarborWriteMissPolicy.writeAllocate,
    this.mshrEntries = 4,
    this.writeBufferEntries = 4,
    this.latencyCycles = 1,
  });

  /// Number of sets.
  int get sets => size ~/ (lineSize * ways);

  /// Number of total lines.
  int get lines => size ~/ lineSize;

  /// Index bits (log2 of sets).
  int get indexBits => sets.bitLength - 1;

  /// Offset bits (log2 of line size).
  int get offsetBits => lineSize.bitLength - 1;

  /// Whether this is direct-mapped.
  bool get isDirectMapped => ways == 1;

  /// Whether this is fully associative.
  bool get isFullyAssociative => sets == 1;

  @override
  String toString() =>
      'HarborCacheConfig(${size ~/ 1024}KB, ${ways}-way, ${lineSize}B line)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborCacheConfig(\n');
    buf.writeln('${c}size: ${size ~/ 1024} KB,');
    buf.writeln('${c}lineSize: $lineSize bytes,');
    buf.writeln('${c}ways: $ways,');
    buf.writeln('${c}sets: $sets,');
    buf.writeln('${c}replacement: ${replacementPolicy.name},');
    buf.writeln('${c}writePolicy: ${writePolicy.name},');
    buf.writeln('${c}writeMiss: ${writeMissPolicy.name},');
    if (mshrEntries > 0) buf.writeln('${c}mshr: $mshrEntries,');
    if (writeBufferEntries > 0) {
      buf.writeln('${c}writeBuffer: $writeBufferEntries,');
    }
    buf.writeln('${c}latency: $latencyCycles cycles,');
    buf.write('$p)');
    return buf.toString();
  }
}

/// L1 instruction cache configuration.
class HarborL1iCacheConfig extends HarborCacheConfig {
  const HarborL1iCacheConfig({
    required super.size,
    super.lineSize,
    required super.ways,
    super.replacementPolicy,
    super.mshrEntries,
    super.latencyCycles,
  }) : super(
         writePolicy: HarborWritePolicy.writeThrough,
         writeMissPolicy: HarborWriteMissPolicy.noWriteAllocate,
         writeBufferEntries: 0,
       );
}

/// L1 data cache configuration.
class HarborL1dCacheConfig extends HarborCacheConfig {
  const HarborL1dCacheConfig({
    required super.size,
    super.lineSize,
    required super.ways,
    super.replacementPolicy,
    super.writePolicy,
    super.writeMissPolicy,
    super.mshrEntries,
    super.writeBufferEntries,
    super.latencyCycles,
  });
}

/// L1 cache configuration (split, unified, or instruction-only).
class HarborL1CacheConfig with HarborPrettyString {
  /// Instruction cache (null for unified).
  final HarborL1iCacheConfig? i;

  /// Data cache (or unified cache when [i] is null).
  /// Null only for an instruction-only configuration.
  final HarborL1dCacheConfig? d;

  const HarborL1CacheConfig({this.i, required HarborL1dCacheConfig d}) : d = d;

  /// Creates an instruction-only L1 cache, leaving data accesses uncached.
  const HarborL1CacheConfig.instructionOnly(HarborL1iCacheConfig i)
    : i = i,
      d = null;

  /// Creates a unified L1 cache.
  const HarborL1CacheConfig.unified(HarborL1dCacheConfig d) : d = d, i = null;

  /// Creates a split I/D L1 cache.
  HarborL1CacheConfig.split({
    required int iSize,
    required int dSize,
    required int ways,
    int lineSize = 64,
  }) : i = HarborL1iCacheConfig(size: iSize, ways: ways, lineSize: lineSize),
       d = HarborL1dCacheConfig(size: dSize, ways: ways, lineSize: lineSize);

  /// Whether this is a unified cache.
  bool get isUnified => i == null;

  @override
  String toString() => isUnified
      ? 'L1(unified: $d)'
      : d == null
      ? 'L1(I: $i)'
      : 'L1(I: $i, D: $d)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborL1CacheConfig(\n');
    if (i != null) {
      buf.writeln('${c}I-cache:');
      buf.writeln(i!.toPrettyString(options.nested()));
    }
    if (d != null) {
      buf.writeln('${c}D-cache:');
      buf.writeln(d!.toPrettyString(options.nested()));
    }
    buf.write('$p)');
    return buf.toString();
  }
}
