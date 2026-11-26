import '../peripherals/device_register.dart';
import 'cpu.dart';

/// An interrupt sourced by a peripheral, as described in a CMSIS-SVD file.
class HarborSvdInterrupt {
  /// Interrupt name (a valid identifier).
  final String name;

  /// Interrupt number.
  final int value;

  /// Optional human-readable description.
  final String? description;

  const HarborSvdInterrupt({
    required this.name,
    required this.value,
    this.description,
  });
}

/// A peripheral as described in a CMSIS-SVD file.
///
/// This is an immutable value object. Devices implement
/// [HarborSvdPeripheralProvider] and return one of these from
/// [HarborSvdPeripheralProvider.svdPeripheral].
///
/// The register-level detail is carried by an optional
/// [HarborDeviceRegisterMap], the same neutral register description the
/// peripheral uses to implement its MMIO logic. Each field in that map becomes
/// a `<register>` in the SVD output.
class HarborSvdPeripheral {
  /// Peripheral name (a valid identifier, e.g. `UART0`).
  final String name;

  /// Optional description.
  final String? description;

  /// MMIO base address.
  final int baseAddress;

  /// Size of the peripheral's address block, in bytes.
  final int size;

  /// Optional group name used to share register definitions between
  /// peripherals of the same type (e.g. `UART`).
  final String? groupName;

  /// Interrupts this peripheral sources.
  final List<HarborSvdInterrupt> interrupts;

  /// Register-level detail. Each field becomes a `<register>`.
  final HarborDeviceRegisterMap? registers;

  const HarborSvdPeripheral({
    required this.name,
    required this.baseAddress,
    required this.size,
    this.description,
    this.groupName,
    this.interrupts = const [],
    this.registers,
  });
}

/// Interface for devices that contribute a peripheral to a CMSIS-SVD file.
///
/// Implement this on any peripheral module to enable automatic SVD
/// generation. The getter is independent of [dtNode] / `acpiDevice`: each
/// generator reads its own neutral description, none adapts another.
///
/// ```dart
/// class MyUart extends Module with HarborSvdPeripheralProvider {
///   @override
///   HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
///     name: 'UART0',
///     baseAddress: 0x10000000,
///     size: 0x1000,
///     registers: StandardRegisters.uart16550,
///   );
/// }
/// ```
mixin HarborSvdPeripheralProvider {
  /// The SVD peripheral description for this device.
  HarborSvdPeripheral get svdPeripheral;

  /// More SVD peripherals for the same device, after [svdPeripheral].
  List<HarborSvdPeripheral> get extraSvdPeripherals => const [];
}

/// Generates a CMSIS-SVD (System View Description) file from a list of
/// [HarborSvdPeripheralProvider] peripherals and [HarborCpu] entries.
///
/// The output is consumed by debuggers (peripheral register views) and by
/// header generators such as `svdconv`.
///
/// ```dart
/// final svd = HarborSvdGenerator(
///   vendor: 'Lilith Semiconductor',
///   name: 'Creek V1',
///   version: '1.0',
///   cpus: [HarborCpu(hartId: 0, isa: 'rv64imac')],
///   peripherals: [uart, clint],
/// ).generate();
/// ```
class HarborSvdGenerator {
  /// Device vendor name.
  final String vendor;

  /// Device name.
  final String name;

  /// Device version string.
  final String version;

  /// Optional device description.
  final String? description;

  /// Default register width, in bits.
  final int width;

  /// CPU entries. The first is used for the single SVD `<cpu>` block.
  final List<HarborCpu> cpus;

  /// Peripheral nodes implementing [HarborSvdPeripheralProvider].
  final List<HarborSvdPeripheralProvider> peripherals;

  /// Interrupt numbers assigned to peripherals by the SoC's allocator, keyed
  /// by provider.
  ///
  /// When a provider has an entry here, those numbers are emitted as
  /// `<interrupt>` elements (named after the peripheral) instead of the
  /// peripheral's own [HarborSvdPeripheral.interrupts], so interrupt numbering
  /// lives in one place rather than being hardcoded per peripheral.
  final Map<HarborSvdPeripheralProvider, List<int>> interrupts;

  const HarborSvdGenerator({
    required this.vendor,
    required this.name,
    this.version = '1.0',
    this.description,
    this.width = 32,
    this.cpus = const [],
    this.peripherals = const [],
    this.interrupts = const {},
  });

  /// SVD peripheral descriptions from the peripherals.
  List<HarborSvdPeripheral> get devices => [
    for (final p in peripherals) ...[p.svdPeripheral, ...p.extraSvdPeripherals],
  ];

  /// Generates the CMSIS-SVD XML source as a string.
  String generate() {
    final buf = StringBuffer();

    buf.writeln('<?xml version="1.0" encoding="utf-8"?>');
    buf.writeln(
      '<device schemaVersion="1.3" '
      'xmlns:xs="http://www.w3.org/2001/XMLSchema-instance" '
      'xs:noNamespaceSchemaLocation="CMSIS-SVD.xsd">',
    );
    buf.writeln('  <vendor>${_esc(vendor)}</vendor>');
    buf.writeln('  <name>${_ident(name)}</name>');
    buf.writeln('  <version>${_esc(version)}</version>');
    buf.writeln('  <description>${_esc(description ?? name)}</description>');
    buf.writeln('  <addressUnitBits>8</addressUnitBits>');
    buf.writeln('  <width>$width</width>');
    buf.writeln('  <size>$width</size>');
    buf.writeln('  <access>read-write</access>');
    buf.writeln('  <resetValue>0x0</resetValue>');
    buf.writeln('  <resetMask>${_mask(width)}</resetMask>');

    _writeCpu(buf);

    buf.writeln('  <peripherals>');
    for (final provider in peripherals) {
      final dev = provider.svdPeripheral;
      _writePeripheral(buf, dev, _interruptsFor(provider, dev));
      for (final extra in provider.extraSvdPeripherals) {
        _writePeripheral(buf, extra, extra.interrupts);
      }
    }
    buf.writeln('  </peripherals>');

    buf.writeln('</device>');
    return buf.toString();
  }

  void _writeCpu(StringBuffer buf) {
    if (cpus.isEmpty) return;
    final cpu = cpus.first;
    buf.writeln('  <cpu>');
    // SVD has no RISC-V enum value, so the generic "other" name is used and the
    // ISA string is carried in the description.
    buf.writeln('    <name>other</name>');
    buf.writeln('    <revision>r0p0</revision>');
    buf.writeln('    <endian>little</endian>');
    buf.writeln('    <mpuPresent>${cpu.mmu != null}</mpuPresent>');
    buf.writeln('    <fpuPresent>${_hasFpu(cpu.isa)}</fpuPresent>');
    buf.writeln('    <nvicPrioBits>0</nvicPrioBits>');
    buf.writeln('    <vendorSystickConfig>false</vendorSystickConfig>');
    buf.writeln('  </cpu>');
  }

  /// The interrupts to emit for [dev]. SoC-allocated numbers (named after the
  /// peripheral) take precedence over any the peripheral declared itself.
  List<HarborSvdInterrupt> _interruptsFor(
    HarborSvdPeripheralProvider provider,
    HarborSvdPeripheral dev,
  ) {
    final assigned = interrupts[provider];
    if (assigned == null || assigned.isEmpty) return dev.interrupts;
    if (assigned.length == 1) {
      return [
        HarborSvdInterrupt(name: _ident(dev.name), value: assigned.first),
      ];
    }
    return [
      for (var i = 0; i < assigned.length; i++)
        HarborSvdInterrupt(name: '${_ident(dev.name)}$i', value: assigned[i]),
    ];
  }

  void _writePeripheral(
    StringBuffer buf,
    HarborSvdPeripheral dev,
    List<HarborSvdInterrupt> irqs,
  ) {
    buf.writeln('    <peripheral>');
    buf.writeln('      <name>${_ident(dev.name)}</name>');
    if (dev.groupName != null) {
      buf.writeln('      <groupName>${_ident(dev.groupName!)}</groupName>');
    }
    if (dev.description != null) {
      buf.writeln('      <description>${_esc(dev.description!)}</description>');
    }
    buf.writeln('      <baseAddress>${_hex(dev.baseAddress)}</baseAddress>');

    buf.writeln('      <addressBlock>');
    buf.writeln('        <offset>0</offset>');
    buf.writeln('        <size>${_hex(dev.size)}</size>');
    buf.writeln('        <usage>registers</usage>');
    buf.writeln('      </addressBlock>');

    for (final irq in irqs) {
      buf.writeln('      <interrupt>');
      buf.writeln('        <name>${_ident(irq.name)}</name>');
      if (irq.description != null) {
        buf.writeln(
          '        <description>${_esc(irq.description!)}</description>',
        );
      }
      buf.writeln('        <value>${irq.value}</value>');
      buf.writeln('      </interrupt>');
    }

    final regs = dev.registers;
    if (regs != null && regs.fields.isNotEmpty) {
      buf.writeln('      <registers>');
      for (final field in regs.fields) {
        _writeRegister(buf, field);
      }
      buf.writeln('      </registers>');
    }

    buf.writeln('    </peripheral>');
  }

  void _writeRegister(StringBuffer buf, HarborDeviceField field) {
    buf.writeln('        <register>');
    buf.writeln('          <name>${_ident(field.name)}</name>');
    buf.writeln(
      '          <addressOffset>${_hex(field.offset)}</addressOffset>',
    );
    buf.writeln('          <size>${field.widthBits}</size>');
    buf.writeln('          <access>${_access(field)}</access>');
    buf.writeln('          <resetValue>${_hex(field.resetValue)}</resetValue>');
    buf.writeln('        </register>');
  }

  String _access(HarborDeviceField field) {
    if (field.readOnly) return 'read-only';
    if (field.writeOnly) return 'write-only';
    return 'read-write';
  }

  /// Whether the ISA string carries a floating-point extension.
  bool _hasFpu(String isa) {
    final base = isa.toLowerCase().split('_').first;
    return base.contains('f') || base.contains('d') || base.contains('q');
  }

  String _hex(int v) => '0x${v.toRadixString(16).toUpperCase()}';

  String _mask(int bits) {
    final value = bits >= 64 ? -1 : (1 << bits) - 1;
    final hex = value
        .toUnsigned(bits)
        .toRadixString(16)
        .toUpperCase()
        .padLeft(bits ~/ 4, 'F');
    return '0x$hex';
  }

  /// Escapes XML special characters in free text.
  String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  /// Sanitizes an arbitrary string into a valid SVD identifier.
  String _ident(String s) {
    var out = s.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    if (out.isEmpty) out = '_';
    if (RegExp(r'[0-9]').hasMatch(out[0])) out = '_$out';
    return out;
  }
}
