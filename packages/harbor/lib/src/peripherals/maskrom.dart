import 'dart:io';
import 'dart:typed_data';

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../util/elf_loader.dart';

/// Mask ROM: read-only memory with contents fixed at synthesis time.
///
/// Used as the first-stage bootloader (FSBL) entry point. The CPU
/// resets into the mask ROM, which initializes cache-as-RAM and
/// loads the next boot stage from flash/DDR.
///
/// Contents are provided as [initialData], a list of data words
/// that get synthesized into the ROM fabric (LUT ROM on FPGA,
/// hardwired gates on ASIC).
///
/// ```dart
/// final bootrom = HarborMaskRom(
///   baseAddress: 0x00000000,
///   initialData: [
///     0x00000297, // auipc t0, 0
///     0x02028593, // addi a1, t0, 0x20
///     0x0005a583, // lw a1, 0(a1)
///     0x00058067, // jr a1
///     // ... bootloader code
///   ],
/// );
/// ```
class HarborMaskRom extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  final int? busDataWidth;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// ROM data words (fixed at synthesis time).
  final List<int> initialData;

  /// Data width in bits.
  final int dataWidth;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// Size in bytes.
  int get size => initialData.length * (dataWidth ~/ 8);

  HarborMaskRom({
    required this.baseAddress,
    required this.initialData,
    this.dataWidth = 32,
    int? busAddressWidth,
    this.busDataWidth,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborMaskRom', name: name ?? 'maskrom') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    final depth = initialData.isEmpty ? 1 : initialData.length;
    final addrWidth = depth.bitLength.clamp(1, 64);
    // The bus carries byte addresses while initialData is word-indexed, so
    // the default port is wide enough for the word index plus the byte-offset
    // bits, and the offset bits are dropped before the lookup. Indexing by
    // the raw byte address served every Nth word instead of consecutive
    // ones, which scrambled fetched instruction streams.
    final byteShift = (dataWidth ~/ 8 - 1).bitLength;

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: busAddressWidth ?? (addrWidth + byteShift),
      dataWidth: busDataWidth ?? dataWidth,
    );

    final clk = input('clk');
    if (bus.addr.width <= byteShift) {
      throw ArgumentError(
        'HarborMaskRom: busAddressWidth (${bus.addr.width}) is too narrow to '
        'carry byte addresses for $dataWidth-bit words',
      );
    }
    final idxHi = byteShift + addrWidth <= bus.addr.width
        ? byteShift + addrWidth
        : bus.addr.width;
    final addr = bus.addr.getRange(byteShift, idxHi).zeroExtend(addrWidth);
    final datOutInternal = Logic(name: 'rom_data', width: dataWidth);
    bus.dataOut <= datOutInternal.zeroExtend(bus.dataOut.width);
    final ack = bus.ack;
    final stb = bus.stb;

    // ROM read logic: generates a case statement from initialData
    // that synthesizes as LUT ROM on FPGAs
    Sequential(clk, [
      ack < Const(0),
      datOutInternal < Const(0, width: dataWidth),
      If(
        stb & ~ack,
        then: [
          ack < Const(1),
          Case(addr, [
            for (var i = 0; i < initialData.length; i++)
              CaseItem(Const(i, width: addrWidth), [
                datOutInternal < Const(initialData[i], width: dataWidth),
              ]),
          ]),
        ],
      ),
    ]);
  }

  /// Creates a HarborMaskRom from an ELF file.
  ///
  /// Loads all PT_LOAD segments and flattens them into words.
  /// The base address can be overridden. Otherwise uses the
  /// ELF's physical addresses.
  factory HarborMaskRom.fromElf(
    File file, {
    required int baseAddress,
    int dataWidth = 32,
    int? busDataWidth,
    String? name,
  }) {
    final elf = HarborElfLoader.fromFile(file);
    final words = elf.toWords(
      baseAddress: baseAddress,
      wordSize: dataWidth ~/ 8,
    );
    return HarborMaskRom(
      baseAddress: baseAddress,
      initialData: words,
      dataWidth: dataWidth,
      busDataWidth: busDataWidth,
      name: name,
    );
  }

  /// Creates a HarborMaskRom from a raw binary file.
  ///
  /// Reads the file and splits it into data words.
  factory HarborMaskRom.fromBinary(
    File file, {
    required int baseAddress,
    int dataWidth = 32,
    int? busDataWidth,
    String? name,
  }) {
    final bytes = file.readAsBytesSync();
    final bytesPerWord = dataWidth ~/ 8;
    final words = <int>[];

    for (var i = 0; i < bytes.length; i += bytesPerWord) {
      var word = 0;
      for (var b = 0; b < bytesPerWord && (i + b) < bytes.length; b++) {
        word |= bytes[i + b] << (b * 8);
      }
      words.add(word);
    }

    return HarborMaskRom(
      baseAddress: baseAddress,
      initialData: words,
      dataWidth: dataWidth,
      busDataWidth: busDataWidth,
      name: name,
    );
  }

  /// Creates a HarborMaskRom from raw bytes.
  factory HarborMaskRom.fromBytes(
    Uint8List bytes, {
    required int baseAddress,
    int dataWidth = 32,
    int? busDataWidth,
    String? name,
  }) {
    final bytesPerWord = dataWidth ~/ 8;
    final words = <int>[];

    for (var i = 0; i < bytes.length; i += bytesPerWord) {
      var word = 0;
      for (var b = 0; b < bytesPerWord && (i + b) < bytes.length; b++) {
        word |= bytes[i + b] << (b * 8);
      }
      words.add(word);
    }

    return HarborMaskRom(
      baseAddress: baseAddress,
      initialData: words,
      dataWidth: dataWidth,
      busDataWidth: busDataWidth,
      name: name,
    );
  }

  /// Creates a HarborMaskRom from an Intel HEX (.ihex) file.
  ///
  /// Parses the Intel HEX format and extracts data records.
  factory HarborMaskRom.fromIntelHex(
    File file, {
    required int baseAddress,
    int dataWidth = 32,
    int? busDataWidth,
    String? name,
  }) {
    final lines = file.readAsLinesSync();
    final allBytes = <int, int>{}; // address -> byte

    var baseAddr = 0;
    for (final line in lines) {
      if (!line.startsWith(':')) continue;
      final byteCount = int.parse(line.substring(1, 3), radix: 16);
      final addr = int.parse(line.substring(3, 7), radix: 16);
      final type = int.parse(line.substring(7, 9), radix: 16);

      if (type == 0x00) {
        // Data record
        for (var i = 0; i < byteCount; i++) {
          final b = int.parse(line.substring(9 + i * 2, 11 + i * 2), radix: 16);
          allBytes[baseAddr + addr + i] = b;
        }
      } else if (type == 0x02) {
        // Extended segment address
        baseAddr = int.parse(line.substring(9, 13), radix: 16) << 4;
      } else if (type == 0x04) {
        // Extended linear address
        baseAddr = int.parse(line.substring(9, 13), radix: 16) << 16;
      } else if (type == 0x01) {
        break; // EOF
      }
    }

    if (allBytes.isEmpty) {
      return HarborMaskRom(
        baseAddress: baseAddress,
        initialData: [],
        dataWidth: dataWidth,
        busDataWidth: busDataWidth,
        name: name,
      );
    }

    // Convert sparse byte map to word array
    final minAddr = allBytes.keys.reduce((a, b) => a < b ? a : b);
    final maxAddr = allBytes.keys.reduce((a, b) => a > b ? a : b);
    final bytesPerWord = dataWidth ~/ 8;
    final words = <int>[];

    for (var a = minAddr; a <= maxAddr; a += bytesPerWord) {
      var word = 0;
      for (var b = 0; b < bytesPerWord; b++) {
        word |= (allBytes[a + b] ?? 0) << (b * 8);
      }
      words.add(word);
    }

    return HarborMaskRom(
      baseAddress: baseAddress,
      initialData: words,
      dataWidth: dataWidth,
      busDataWidth: busDataWidth,
      name: name,
    );
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,maskrom'],
    reg: BusAddressRange(baseAddress, size),
    properties: {'data-width': dataWidth, 'depth': initialData.length},
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, size)],
    properties: {
      'compatible': ['harbor,maskrom'],
      'data-width': dataWidth,
      'depth': initialData.length,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'MASKROM',
    groupName: 'MASKROM',
    description: 'Mask ROM with contents fixed at synthesis time',
    baseAddress: baseAddress,
    size: size,
  );
}
