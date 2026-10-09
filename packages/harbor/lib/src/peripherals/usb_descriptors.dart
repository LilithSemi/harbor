import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// A single USB descriptor entry: the (desc_type, desc_index) key that
/// selects it and the byte list that makes it up.
///
/// [bytes.length] is the descriptor's true byte count and is what
/// [UsbDescriptorRom] reports on `length`. [UsbDescriptorRom] checks that
/// the descriptor's own length field (wTotalLength for a CONFIGURATION
/// descriptor, bLength otherwise) matches the actual byte count, so a
/// transcription error fails at build time instead of shipping a
/// malformed descriptor.
class UsbDescriptorEntry {
  /// bDescriptorType (DEVICE=1, CONFIGURATION=2, STRING=3, ...).
  final int type;

  /// The descriptor index (descriptor index for STRING, 0 for DEVICE/CONFIG).
  final int index;

  /// The raw descriptor bytes, in wire order (LE multi-byte fields).
  final List<int> bytes;

  const UsbDescriptorEntry(this.type, this.index, this.bytes);
}

/// Builds a STRING descriptor (bDescriptorType 0x03) for [s] as UTF-16LE.
List<int> usbStringDescriptor(String s) {
  final units = s.codeUnits;
  final out = <int>[2 + 2 * units.length, 0x03];
  for (final u in units) {
    out.add(u & 0xFF);
    out.add((u >> 8) & 0xFF);
  }
  return out;
}

/// STRING index 0: supported LANGID list (English-US 0x0409).
const List<int> usbStringLangIdEnUs = [4, 0x03, 0x09, 0x04];

/// Combinational ROM of USB descriptors.
///
/// This is pure data: no clock, no reset, no state. Given a descriptor key
/// (`desc_type`, `desc_index`) and a byte `offset`, it returns:
///   - `present` : 1 if the (type, index) pair is a known descriptor, else 0.
///   - `length`  : the total byte count of the selected descriptor (0 if not
///                 present).
///   - `data`    : the byte at `offset` within the selected descriptor, or 0
///                 if the descriptor is absent or `offset` is out of range.
///
/// Each descriptor is at most 255 bytes, because `offset` is 8 bits.
class UsbDescriptorRom extends BridgeModule {
  /// The descriptors this ROM serves.
  final List<UsbDescriptorEntry> descriptors;

  UsbDescriptorRom({required this.descriptors, String? name})
    : super('UsbDescriptorRom', name: name ?? 'usb_desc_rom') {
    createPort('desc_type', PortDirection.input, width: 8);
    createPort('desc_index', PortDirection.input, width: 8);
    createPort('offset', PortDirection.input, width: 8);
    addOutput('data', width: 8);
    addOutput('length', width: 16);
    addOutput('present');

    final descs = descriptors;
    if (descs.isEmpty) {
      throw ArgumentError('UsbDescriptorRom requires at least one descriptor');
    }
    for (final d in descs) {
      if (d.bytes.length > 255) {
        throw ArgumentError(
          'descriptor (type=${d.type}, index=${d.index}) is '
          '${d.bytes.length} bytes, the ROM limit is 255',
        );
      }
    }

    // Build-time integrity checks: every byte must be a legal 0..255 value, and
    // each descriptor's declared length field must equal its real byte count.
    for (final d in descs) {
      for (final b in d.bytes) {
        if (b < 0 || b > 0xFF) {
          throw ArgumentError(
            'descriptor (type=${d.type}, index=${d.index}) has out-of-range '
            'byte $b',
          );
        }
      }
      if (d.bytes.isEmpty) {
        throw ArgumentError(
          'descriptor (type=${d.type}, index=${d.index}) is empty',
        );
      }
      // bLength (byte 0) must equal the actual length for non-config
      // descs. The CONFIGURATION descriptor instead carries the total in
      // wTotalLength (bytes 2..3), with byte 0 being just the header length.
      if (d.type == 0x02) {
        final wTotalLength = d.bytes[2] | (d.bytes[3] << 8);
        if (wTotalLength != d.bytes.length) {
          throw ArgumentError(
            'CONFIGURATION descriptor wTotalLength=$wTotalLength does not '
            'match actual byte count ${d.bytes.length}',
          );
        }
      } else {
        if (d.bytes[0] != d.bytes.length) {
          throw ArgumentError(
            'descriptor (type=${d.type}, index=${d.index}) bLength='
            '${d.bytes[0]} does not match actual byte count '
            '${d.bytes.length}',
          );
        }
      }
    }

    final descType = input('desc_type');
    final descIndex = input('desc_index');
    final offset = input('offset');

    // Per-descriptor key match.
    final matches = <Logic>[
      for (final d in descs)
        (descType.eq(Const(d.type, width: 8)) &
                descIndex.eq(Const(d.index, width: 8)))
            .named('match_t${d.type}_i${d.index}'),
    ];

    // present = logical or of all key matches.
    Logic presentLocal = Const(0);
    for (final m in matches) {
      presentLocal = presentLocal | m;
    }
    output('present') <= presentLocal;

    // length = the matched descriptor's byte count (0 if no match). Built as a
    // priority-free or-mux: keys are mutually exclusive by construction.
    Logic lengthLocal = Const(0, width: 16);
    for (var i = 0; i < descs.length; i++) {
      lengthLocal = mux(
        matches[i],
        Const(descs[i].bytes.length, width: 16),
        lengthLocal,
      );
    }
    output('length') <= lengthLocal;

    // data = byte at `offset` within the matched descriptor, else 0. For each
    // descriptor build an indexed mux over its bytes (offset out of range -> 0),
    // then select the matched descriptor's byte.
    Logic dataLocal = Const(0, width: 8);
    for (var i = 0; i < descs.length; i++) {
      final bytes = descs[i].bytes;
      // Indexed byte select for this descriptor.
      Logic byteSel = Const(0, width: 8);
      for (var off = 0; off < bytes.length; off++) {
        byteSel = mux(
          offset.eq(Const(off, width: 8)),
          Const(bytes[off], width: 8),
          byteSel,
        );
      }
      dataLocal = mux(matches[i], byteSel, dataLocal);
    }
    output('data') <= dataLocal;
  }
}
