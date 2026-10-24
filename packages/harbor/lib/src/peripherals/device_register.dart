import '../bus/bus.dart';
import '../util/pretty_string.dart';

/// A single register field within a device register map.
class HarborDeviceField {
  /// Field name.
  final String name;

  /// Width in bytes.
  final int width;

  /// Byte offset within the device's address space.
  final int offset;

  /// Whether this field is read-only.
  final bool readOnly;

  /// Whether this field is write-only.
  final bool writeOnly;

  /// Reset value (0 if not specified).
  final int resetValue;

  const HarborDeviceField({
    required this.name,
    required this.width,
    required this.offset,
    this.readOnly = false,
    this.writeOnly = false,
    this.resetValue = 0,
  });

  /// Width in bits.
  int get widthBits => width * 8;

  /// End offset (exclusive).
  int get end => offset + width;

  /// Address range this field occupies.
  BusAddressRange get range => BusAddressRange(offset, width);

  /// Whether [addr] falls within this field.
  bool contains(int addr) => addr >= offset && addr < end;

  @override
  String toString() =>
      'HarborDeviceField($name, $width bytes @ 0x${offset.toRadixString(16)})';
}

/// A device register map: a collection of named fields at fixed offsets.
///
/// Provides the declarative register description that peripherals
/// use to implement MMIO read/write logic. River's `DeviceAccessor`
/// equivalent.
///
/// ```dart
/// const uartRegisters = HarborDeviceRegisterMap(
///   name: 'uart',
///   fields: [
///     HarborDeviceField(name: 'rbr_thr_dll', width: 1, offset: 0x0),
///     HarborDeviceField(name: 'ier_dlm', width: 1, offset: 0x1),
///     HarborDeviceField(name: 'iir_fcr', width: 1, offset: 0x2),
///     HarborDeviceField(name: 'lcr', width: 1, offset: 0x3),
///     HarborDeviceField(name: 'mcr', width: 1, offset: 0x4),
///     HarborDeviceField(name: 'lsr', width: 1, offset: 0x5, readOnly: true),
///     HarborDeviceField(name: 'msr', width: 1, offset: 0x6, readOnly: true),
///     HarborDeviceField(name: 'scr', width: 1, offset: 0x7),
///   ],
/// );
/// ```
class HarborDeviceRegisterMap with HarborPrettyString {
  /// Device name.
  final String name;

  /// All register fields.
  final List<HarborDeviceField> fields;

  const HarborDeviceRegisterMap({required this.name, this.fields = const []});

  /// Total address space size (max end offset).
  int get size {
    var maxEnd = 0;
    for (final f in fields) {
      if (f.end > maxEnd) maxEnd = f.end;
    }
    return maxEnd;
  }

  /// Finds the field at [offset].
  HarborDeviceField? fieldAt(int offset) {
    for (final f in fields) {
      if (f.contains(offset)) return f;
    }
    return null;
  }

  /// Finds a field by [name].
  HarborDeviceField? operator [](String name) {
    for (final f in fields) {
      if (f.name == name) return f;
    }
    return null;
  }

  /// Byte offset of a named field.
  int? fieldOffset(String name) => this[name]?.offset;

  /// All field names.
  Iterable<String> get fieldNames => fields.map((f) => f.name);

  /// Validates the register map for overlaps.
  List<String> validate() {
    final errors = <String>[];
    for (var i = 0; i < fields.length; i++) {
      for (var j = i + 1; j < fields.length; j++) {
        final a = fields[i];
        final b = fields[j];
        if (a.offset < b.end && b.offset < a.end) {
          errors.add('Overlap: ${a.name} and ${b.name}');
        }
      }
    }
    return errors;
  }

  @override
  String toString() =>
      'HarborDeviceRegisterMap($name, ${fields.length} fields)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborDeviceRegisterMap($name,\n');
    for (final f in fields) {
      buf.write('${c}0x${f.offset.toRadixString(16).padLeft(4, "0")} ');
      buf.write('${f.name} (${f.width}B');
      if (f.readOnly) buf.write(', RO');
      if (f.writeOnly) buf.write(', WO');
      if (f.resetValue != 0)
        buf.write(', reset=0x${f.resetValue.toRadixString(16)}');
      buf.writeln(')');
    }
    buf.write('$p)');
    return buf.toString();
  }
}

/// Standard register maps for common peripherals.
abstract final class StandardRegisters {
  /// 16550 UART register map.
  static const uart16550 = HarborDeviceRegisterMap(
    name: 'uart16550',
    fields: [
      HarborDeviceField(name: 'rbr_thr_dll', width: 1, offset: 0x0),
      HarborDeviceField(name: 'ier_dlm', width: 1, offset: 0x1),
      HarborDeviceField(name: 'iir_fcr', width: 1, offset: 0x2),
      HarborDeviceField(name: 'lcr', width: 1, offset: 0x3, resetValue: 0x03),
      HarborDeviceField(name: 'mcr', width: 1, offset: 0x4),
      HarborDeviceField(name: 'lsr', width: 1, offset: 0x5, readOnly: true),
      HarborDeviceField(name: 'msr', width: 1, offset: 0x6, readOnly: true),
      HarborDeviceField(name: 'scr', width: 1, offset: 0x7),
    ],
  );

  /// 16550 UART register map with 32-bit registers (`reg-shift` 2).
  static const uart16550Word = HarborDeviceRegisterMap(
    name: 'uart16550_word',
    fields: [
      HarborDeviceField(name: 'rbr_thr_dll', width: 4, offset: 0x00),
      HarborDeviceField(name: 'ier_dlm', width: 4, offset: 0x04),
      HarborDeviceField(name: 'iir_fcr', width: 4, offset: 0x08),
      HarborDeviceField(name: 'lcr', width: 4, offset: 0x0c, resetValue: 0x03),
      HarborDeviceField(name: 'mcr', width: 4, offset: 0x10),
      HarborDeviceField(name: 'lsr', width: 4, offset: 0x14, readOnly: true),
      HarborDeviceField(name: 'msr', width: 4, offset: 0x18, readOnly: true),
      HarborDeviceField(name: 'scr', width: 4, offset: 0x1c),
    ],
  );

  /// SiFive CLINT register map (per hart 0).
  static const clint = HarborDeviceRegisterMap(
    name: 'clint',
    fields: [
      HarborDeviceField(name: 'msip', width: 4, offset: 0x0000),
      HarborDeviceField(name: 'mtimecmp', width: 8, offset: 0x4000),
      HarborDeviceField(
        name: 'mtime',
        width: 8,
        offset: 0xBFF8,
        readOnly: true,
      ),
    ],
  );
}
