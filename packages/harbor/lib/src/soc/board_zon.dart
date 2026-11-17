import 'board.dart';
import 'cpu.dart';
import 'target.dart';

/// The kind of a system memory, as the firmware SMBIOS tables name it.
enum HarborMemoryKind {
  ddr,
  ddr2,
  ddr3,
  ddr4,
  ddr5,
  lpddr4,
  lpddr5,
  sdram,
  psram,
}

/// How a memory is fitted to its board.
enum HarborMemoryFormFactor { chip, sodimm }

/// What a memory device tells the board zon generator about itself.
class HarborMemoryInfo {
  final HarborMemoryKind kind;

  /// Usable size in bytes.
  final int sizeBytes;

  /// The address window that the SoC maps for this memory. A socketed memory
  /// reports it as its upper bound. Defaults to [sizeBytes].
  final int maxSizeBytes;

  /// Data bus width in bits.
  final int widthBits;

  /// How this memory is fitted to its board.
  final HarborMemoryFormFactor formFactor;

  const HarborMemoryInfo({
    required this.kind,
    required this.sizeBytes,
    int? maxSizeBytes,
    required this.widthBits,
    this.formFactor = HarborMemoryFormFactor.chip,
  }) : maxSizeBytes = maxSizeBytes ?? sizeBytes;
}

/// Writes the Zig object notation file that the firmware reads at build time
/// to make its SMBIOS tables.
///
/// A field appears only when the SoC knows its value. The firmware uses its
/// own default for each field that is missing.
///
/// A socketed memory has a fitted size that the build cannot know. It gets
/// `.max_size_bytes` (the window the SoC maps) in place of `.size_bytes`, and
/// the firmware reads the fitted size at run time from the SPD or the
/// controller geometry.
///
/// `.memory` is a tuple of objects, one for each memory in the order of the
/// peripherals. The firmware rejects a field it does not know, and a cpu needs
/// a `.model`, so an unknown model is the empty string.
class HarborBoardZonGenerator {
  final String? vendor;
  final String? product;
  final String family;
  final List<HarborCpu> cpus;
  final List<HarborMemoryInfo> memories;
  final HarborBoard? board;

  const HarborBoardZonGenerator({
    this.vendor,
    this.product,
    required this.family,
    this.cpus = const [],
    this.memories = const [],
    this.board,
  });

  /// Escapes [s] for a Zig string literal.
  static String quote(String s) {
    final out = StringBuffer('"');
    for (final c in s.runes) {
      switch (c) {
        case 0x5c:
          out.write(r'\\');
        case 0x22:
          out.write(r'\"');
        case 0x0a:
          out.write(r'\n');
        case 0x0d:
          out.write(r'\r');
        case 0x09:
          out.write(r'\t');
        default:
          if (c < 0x20 || c == 0x7f) {
            out.write('\\x${c.toRadixString(16).padLeft(2, '0')}');
          } else {
            out.writeCharCode(c);
          }
      }
    }
    return (out..write('"')).toString();
  }

  /// The firmware memory type tag. A kind that the firmware does not list
  /// becomes `other`.
  static String _tag(HarborMemoryKind k) => switch (k) {
    HarborMemoryKind.ddr ||
    HarborMemoryKind.ddr2 ||
    HarborMemoryKind.ddr3 ||
    HarborMemoryKind.ddr4 ||
    HarborMemoryKind.ddr5 ||
    HarborMemoryKind.lpddr4 ||
    HarborMemoryKind.lpddr5 ||
    HarborMemoryKind.sdram => k.name,
    _ => 'other',
  };

  String _memory(HarborMemoryInfo m) {
    final size = m.formFactor == HarborMemoryFormFactor.sodimm
        ? '.max_size_bytes = ${m.maxSizeBytes}'
        : '.size_bytes = ${m.sizeBytes}';
    return '.{ .type = .${_tag(m.kind)}, $size, '
        '.width_bits = ${m.widthBits}, '
        '.form_factor = .${m.formFactor.name} }';
  }

  /// The firmware part name of [b].
  static String fpgaPart(HarborBoard b) => switch (b.vendor) {
    HarborFpgaVendor.vivado ||
    HarborFpgaVendor.openXc7 => '${b.device}${b.package}-${b.speedGrade}',
    _ => '${b.device}-${b.package}',
  };

  String generate() {
    final out = StringBuffer('.{\n');
    if (vendor != null) out.writeln('    .vendor = ${quote(vendor!)},');
    if (product != null) out.writeln('    .product = ${quote(product!)},');
    out.writeln('    .family = ${quote(family)},');
    if (cpus.isNotEmpty) {
      final first = cpus.first;
      final model = first.model;
      final hz = first.clockFrequency;
      out.writeln(
        '    .cpu = .{ '
        '.model = ${quote(model ?? '')}, '
        '.isa = ${quote(first.isa)}, '
        '.harts = ${cpus.length}'
        '${hz != null ? ', .clock_hz = $hz' : ''}'
        ' },',
      );
    }
    if (memories.isNotEmpty) {
      out.writeln('    .memory = .{');
      for (final m in memories) {
        out.writeln('        ${_memory(m)},');
      }
      out.writeln('    },');
    }
    final b = board;
    if (b != null) {
      out.writeln(
        '    .board = .{ .preset = ${quote(b.name)}, '
        '.fpga_part = ${quote(fpgaPart(b))} },',
      );
    }
    return (out..write('}\n')).toString();
  }
}
