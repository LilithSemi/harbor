import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../blackbox/ecp5/ecp5.dart';
import '../blackbox/ice40/ice40.dart';
import '../blackbox/xilinx/xilinx.dart';
import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../soc/target.dart';

/// On-chip SRAM memory module.
///
/// Uses target BRAM primitives for synthesis. For simulation (no target),
/// uses a small register array (max 4KB).
///
/// Sub-word stores: the iCE40 SPRAM path honors the bus byte-lane selects
/// through MASKWREN, the ECP5 path through one x9 DP16KD per byte lane, the
/// Xilinx path through the RAMB36E1 per-byte WEA lanes, and the generic
/// sim/inferred-BRAM model through an explicit per-lane read-merge. The ASIC
/// macro path still writes whole words (a known follow-up).
class HarborSram extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  final int? busDataWidth;
  final int size;
  final int baseAddress;
  final int dataWidth;

  late final BusSlavePort bus;

  HarborSram({
    required this.baseAddress,
    required this.size,
    this.dataWidth = 32,
    int? busAddressWidth,
    this.busDataWidth,
    BusProtocol protocol = BusProtocol.wishbone,
    HarborDeviceTarget? target,
    String? name,
  }) : super('HarborSram_${size}', name: name ?? 'sram') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    final bytesPerWord = dataWidth ~/ 8;
    final numWords = size ~/ bytesPerWord;
    final addrWidth = numWords > 1 ? (numWords - 1).bitLength : 1;
    final byteOffsetBits = bytesPerWord > 1 ? (bytesPerWord - 1).bitLength : 0;
    final totalAddrWidth = addrWidth + byteOffsetBits;
    final effectiveAddrWidth = busAddressWidth ?? totalAddrWidth;

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: effectiveAddrWidth,
      dataWidth: busDataWidth ?? dataWidth,
    );

    final clk = input('clk');
    final stb = bus.stb;
    final we = bus.we;
    final addr = bus.addr;
    final datIn = bus.dataIn;
    final datOut = bus.dataOut;
    final ack = bus.ack;

    final wordAddr = byteOffsetBits > 0
        ? addr.getRange(byteOffsetBits, byteOffsetBits + addrWidth)
        : addr.getRange(0, addrWidth);

    if (target case HarborFpgaTarget fpgaTarget) {
      _buildWithBram(
        fpgaTarget,
        clk,
        wordAddr,
        datIn,
        datOut,
        stb,
        we,
        ack,
        bus.sel,
      );
    } else if (target case HarborSimTarget()) {
      _buildSimArray(clk, wordAddr, datIn, datOut, stb, we, ack, bus.sel);
    } else if (target case HarborAsicTarget asicTarget) {
      _buildWithAsicSram(
        asicTarget,
        clk,
        wordAddr,
        datIn,
        datOut,
        stb,
        we,
        ack,
        numWords,
        bus.sel,
      );
    } else {
      _buildSimModel(
        clk,
        wordAddr,
        datIn,
        datOut,
        stb,
        we,
        ack,
        numWords,
        bus.sel,
      );
    }
  }

  void _buildWithBram(
    HarborFpgaTarget target,
    Logic clk,
    Logic wordAddr,
    Logic datIn,
    Logic datOut,
    Logic stb,
    Logic we,
    Logic ack,
    Logic sel,
  ) {
    // Exhaustive over the vendor enum on purpose: a new vendor must make a
    // deliberate choice here rather than silently inheriting another vendor's
    // primitive (a Xilinx build emitting Lattice DP16KD would never map).
    switch (target.vendor) {
      case HarborFpgaVendor.ecp5:
        _buildEcp5Bram(clk, wordAddr, datIn, datOut, stb, we, ack, sel);
      case HarborFpgaVendor.ice40:
        _buildIce40Bram(clk, wordAddr, datIn, datOut, stb, we, ack, sel);
      case HarborFpgaVendor.vivado:
      case HarborFpgaVendor.openXc7:
        _buildXilinxBram(clk, wordAddr, datIn, datOut, stb, we, ack, sel);
    }
  }

  void _buildXilinxBram(
    Logic clk,
    Logic wordAddr,
    Logic datIn,
    Logic datOut,
    Logic stb,
    Logic we,
    Logic ack,
    Logic sel,
  ) {
    // Xilinx 7-series RAMB36E1 in x36 mode: 1024 x 32-bit per block, with
    // WEA[3:0] giving one write enable per byte lane so sub-word stores honor
    // the bus byte selects. Words wider than 32 bits tile blocks across the
    // width. Memories deeper than 1024 words cascade blocks across depth with
    // an address-decoded read mux. The read is registered (one cycle), which
    // lines up with the ack asserted the cycle after stb.
    const blockWordDepth = 1024;
    const blockDataWidth = 32;
    const blockAddrWidth = 16;

    final bytesPerWord = dataWidth ~/ 8;
    final numWords = size ~/ bytesPerWord;
    final widthBlocks = (dataWidth + blockDataWidth - 1) ~/ blockDataWidth;
    final depthBlocks = (numWords + blockWordDepth - 1) ~/ blockWordDepth;
    final totalBlocks = widthBlocks * depthBlocks;

    // Past a sane block budget this would carpet the device in BRAM, so refuse
    // instead. Falling through to the generic model here would either build a
    // memory of registers the part cannot hold, or (for a large one) fail with
    // a message about passing a target, which is confusing when a target IS
    // set and the real limit is the block budget.
    if (totalBlocks > 64) {
      throw ArgumentError(
        'HarborSram of $size bytes needs $totalBlocks RAMB36E1 blocks, past '
        'the 64 this builder places. A Spartan-7 XC7S50 holds 75 blocks in '
        'total, so this is near the whole device. Put a memory this big off '
        'chip (a `dram` device) or make it smaller.',
      );
    }

    final depthAddrBits = depthBlocks > 1 ? (depthBlocks - 1).bitLength : 0;
    final bankSelect = depthAddrBits > 0
        ? wordAddr.getRange(
            blockWordDepth.bitLength - 1,
            blockWordDepth.bitLength - 1 + depthAddrBits,
          )
        : null;

    // x36 word index occupies ADDRARDADDR[14:5]: a 1-bit pad, the 10-bit word
    // index, then the 5 low bits tied zero.
    final addrBits = wordAddr.width < blockWordDepth.bitLength - 1
        ? wordAddr.width
        : blockWordDepth.bitLength - 1;
    final localAddr = [
      Const(0, width: 1),
      wordAddr.getRange(0, addrBits).zeroExtend(blockWordDepth.bitLength - 1),
      Const(0, width: 5),
    ].swizzle().getRange(0, blockAddrWidth);

    final bankOutputs = <Logic>[];
    for (var d = 0; d < depthBlocks; d++) {
      final bankEnable = bankSelect != null
          ? bankSelect.eq(Const(d, width: depthAddrBits))
          : Const(1);

      final sliceOutputs = <Logic>[];
      for (var w = 0; w < widthBlocks; w++) {
        final bitLo = w * blockDataWidth;
        final bitHi = (bitLo + blockDataWidth) > dataWidth
            ? dataWidth
            : bitLo + blockDataWidth;
        final sliceWidth = bitHi - bitLo;

        // One write enable per byte lane this block covers (the rest tied off).
        final weBits = <Logic>[
          for (var b = 3; b >= 0; b--)
            (bitLo ~/ 8 + b) < bytesPerWord
                ? (stb & we & bankEnable & sel[bitLo ~/ 8 + b])
                : Const(0),
        ].swizzle();

        final bram = XilinxRamb36e1(name: 'bram_${d}_$w');
        addSubModule(bram);

        bram.input('CLKARDCLK').srcConnection! <= clk;
        bram.input('ENARDEN').srcConnection! <= stb & bankEnable;
        bram.input('ADDRARDADDR').srcConnection! <= localAddr;
        bram.input('DIADI').srcConnection! <=
            datIn.getRange(bitLo, bitHi).zeroExtend(blockDataWidth);
        bram.input('DIPADIP').srcConnection! <= Const(0, width: 4);
        bram.input('WEA').srcConnection! <= weBits;
        bram.input('REGCEAREGCE').srcConnection! <= Const(0);
        bram.input('RSTRAMARSTRAM').srcConnection! <= Const(0);

        // Port B is unused.
        bram.input('CLKBWRCLK').srcConnection! <= clk;
        bram.input('ENBWREN').srcConnection! <= Const(0);
        bram.input('WEBWE').srcConnection! <= Const(0, width: 8);
        bram.input('ADDRBWRADDR').srcConnection! <= Const(0, width: 16);
        bram.input('DIBDI').srcConnection! <= Const(0, width: 32);
        bram.input('DIPBDIP').srcConnection! <= Const(0, width: 4);
        bram.input('REGCEB').srcConnection! <= Const(0);
        bram.input('RSTRAMB').srcConnection! <= Const(0);

        sliceOutputs.add(bram.output('DOADO').getRange(0, sliceWidth));
      }

      final bankData = sliceOutputs.length == 1
          ? sliceOutputs.first.zeroExtend(dataWidth)
          : sliceOutputs.rswizzle().getRange(0, dataWidth);
      bankOutputs.add(bankData);
    }

    if (depthBlocks == 1) {
      datOut <= bankOutputs.first;
    } else {
      Logic readMux = bankOutputs.first;
      for (var d = 1; d < depthBlocks; d++) {
        readMux = mux(
          bankSelect!.eq(Const(d, width: depthAddrBits)),
          bankOutputs[d],
          readMux,
        );
      }
      datOut <= readMux;
    }

    Sequential(clk, [
      ack < Const(0),
      If(stb & ~ack, then: [ack < Const(1)]),
    ]);
  }

  void _buildEcp5Bram(
    Logic clk,
    Logic wordAddr,
    Logic datIn,
    Logic datOut,
    Logic stb,
    Logic we,
    Logic ack,
    Logic sel,
  ) {
    // ECP5 DP16KD in x9 mode: 2048 x 9-bit, ONE BRAM PER BYTE LANE so each
    // lane gets its own write enable (x18 slices straddle byte lanes and the
    // primitive has no byte masks). Sub-word stores then honor the bus
    // byte-lane selects by construction. In x9 mode the word address lives
    // in AD[13:3] with the low bits zeroed.
    const bramWordDepth = 2048;
    const bramAddrWidth = 14;

    final bytesPerWord = dataWidth ~/ 8;
    final numWords = size ~/ bytesPerWord;
    final depthBrams = (numWords + bramWordDepth - 1) ~/ bramWordDepth;
    final totalBrams = bytesPerWord * depthBrams;

    // Past a sane block budget this would carpet the device in BRAM, so refuse
    // instead. See the Xilinx path for why this does not fall through to the
    // generic model.
    if (totalBrams > 64) {
      throw ArgumentError(
        'HarborSram of $size bytes needs $totalBrams DP16KD blocks, past the '
        '64 this builder places (a $dataWidth-bit memory reaches that at '
        '${64 ~/ bytesPerWord * bramWordDepth * bytesPerWord} bytes). Put a '
        'memory this big off chip (a `dram` device) or make it smaller.',
      );
    }

    final depthAddrBits = depthBrams > 1 ? (depthBrams - 1).bitLength : 0;
    final bankSelect = depthAddrBits > 0
        ? wordAddr.getRange(
            bramWordDepth.bitLength - 1,
            bramWordDepth.bitLength - 1 + depthAddrBits,
          )
        : null;

    // Collect read outputs from all banks
    final bankOutputs = <Logic>[];

    for (var d = 0; d < depthBrams; d++) {
      final bankEnable = bankSelect != null
          ? bankSelect.eq(Const(d, width: depthAddrBits))
          : Const(1);

      final bankDataParts = <Logic>[];

      for (var lane = 0; lane < bytesPerWord; lane++) {
        final addrBits = wordAddr.width < bramWordDepth.bitLength - 1
            ? wordAddr.width
            : bramWordDepth.bitLength - 1;
        // x9 addressing: word index in AD[13:3].
        final localAddr = [
          wordAddr.getRange(0, addrBits).zeroExtend(bramAddrWidth - 3),
          Const(0, width: 3),
        ].swizzle();

        final bram = Ecp5Dp16kd(
          name: 'bram_${d}_$lane',
          dataWidthA: 9,
          dataWidthB: 9,
          clkA: clk,
          ceA: bankEnable,
          oceA: Const(0),
          rstA: Const(0),
          adA: localAddr,
          diA: datIn.getRange(lane * 8, lane * 8 + 8).zeroExtend(9),
          weA: stb & we & bankEnable & sel[lane],
          clkB: clk,
          ceB: Const(0),
          weB: Const(0),
          oceB: Const(0),
          rstB: Const(0),
          adB: Const(0, width: bramAddrWidth),
          diB: Const(0, width: 9),
        );

        bankDataParts.add(bram.doA.getRange(0, 8));
      }

      // Concatenate byte lanes for this bank
      final bankData = bankDataParts.rswizzle().getRange(0, dataWidth);

      bankOutputs.add(bankData);
    }

    // Mux between depth banks
    if (depthBrams == 1) {
      datOut <= bankOutputs.first;
    } else {
      Logic readMux = bankOutputs.first;
      for (var d = 1; d < depthBrams; d++) {
        readMux = mux(
          bankSelect!.eq(Const(d, width: depthAddrBits)),
          bankOutputs[d],
          readMux,
        );
      }
      datOut <= readMux;
    }

    Sequential(clk, [
      ack < Const(0),
      If(stb & ~ack, then: [ack < Const(1)]),
    ]);
  }

  void _buildIce40Bram(
    Logic clk,
    Logic wordAddr,
    Logic datIn,
    Logic datOut,
    Logic stb,
    Logic we,
    Logic ack,
    Logic sel,
  ) {
    // iCE40 SPRAM (SB_SPRAM256KA): 16384 x 16-bit = 32KB each. up5k has 4
    // (128KB total). Pair SPRAMs across the data width and bank them across
    // depth, with an address-decoded read mux. Sub-word stores are honored
    // through MASKWREN, driven from the bus byte-lane selects.
    const spramDepth = 16384;
    const spramWidth = 16;
    const spramAddrBits = 14;

    final bytesPerWord = dataWidth ~/ 8;
    final numWords = size ~/ bytesPerWord;
    final widthSprams = (dataWidth + spramWidth - 1) ~/ spramWidth;
    final depthSprams = (numWords + spramDepth - 1) ~/ spramDepth;
    final totalSprams = widthSprams * depthSprams;

    if (totalSprams > 4) {
      throw ArgumentError(
        'HarborSram "$name": $size bytes at $dataWidth-bit needs $totalSprams '
        'iCE40 SPRAM blocks, but up5k has only 4 (128KB max on-chip). '
        'Use external memory (SPI flash / DRAM) for regions this large.',
      );
    }

    final depthAddrBits = depthSprams > 1 ? (depthSprams - 1).bitLength : 0;
    final bankSelect = depthAddrBits > 0
        ? wordAddr.getRange(spramAddrBits, spramAddrBits + depthAddrBits)
        : null;
    final localAddr = wordAddr.width >= spramAddrBits
        ? wordAddr.getRange(0, spramAddrBits)
        : wordAddr.zeroExtend(spramAddrBits);

    final bankOutputs = <Logic>[];
    for (var d = 0; d < depthSprams; d++) {
      final bankEnable = bankSelect != null
          ? bankSelect.eq(Const(d, width: depthAddrBits))
          : Const(1);

      final sliceOutputs = <Logic>[];
      for (var w = 0; w < widthSprams; w++) {
        final bitLo = w * spramWidth;
        final bitHi = (bitLo + spramWidth) > dataWidth
            ? dataWidth
            : bitLo + spramWidth;
        final sliceWidth = bitHi - bitLo;

        final spram = Ice40SbSpram256ka(name: 'spram_${d}_$w');
        addSubModule(spram);

        spram.input('CLOCK').srcConnection! <= clk;
        spram.input('CHIPSELECT').srcConnection! <= bankEnable;
        spram.input('STANDBY').srcConnection! <= Const(0);
        spram.input('SLEEP').srcConnection! <= Const(0);
        spram.input('POWEROFF').srcConnection! <= Const(1);
        spram.input('ADDRESS').srcConnection! <= localAddr;
        spram.input('DATAIN').srcConnection! <=
            datIn.getRange(bitLo, bitHi).zeroExtend(spramWidth);
        spram.input('WREN').srcConnection! <= stb & we & bankEnable;
        // Each MASKWREN bit enables one nibble of the 16-bit SPRAM word, so
        // each bus byte-lane select drives two adjacent mask bits.
        final maskBits = <Logic>[
          for (var n = 3; n >= 0; n--)
            ((bitLo + n * 4) ~/ 8) < bytesPerWord
                ? sel[(bitLo + n * 4) ~/ 8]
                : Const(0),
        ];
        spram.input('MASKWREN').srcConnection! <= maskBits.swizzle();

        sliceOutputs.add(spram.output('DATAOUT').getRange(0, sliceWidth));
      }

      final bankData = sliceOutputs.length == 1
          ? sliceOutputs.first.zeroExtend(dataWidth)
          : sliceOutputs.rswizzle().getRange(0, dataWidth);
      bankOutputs.add(bankData);
    }

    if (depthSprams == 1) {
      datOut <= bankOutputs.first;
    } else {
      Logic readMux = bankOutputs.first;
      for (var d = 1; d < depthSprams; d++) {
        readMux = mux(
          bankSelect!.eq(Const(d, width: depthAddrBits)),
          bankOutputs[d],
          readMux,
        );
      }
      datOut <= readMux;
    }

    Sequential(clk, [
      ack < Const(0),
      If(stb & ~ack, then: [ack < Const(1)]),
    ]);
  }

  void _buildWithAsicSram(
    HarborAsicTarget target,
    Logic clk,
    Logic wordAddr,
    Logic datIn,
    Logic datOut,
    Logic stb,
    Logic we,
    Logic ack,
    int numWords,
    Logic sel,
  ) {
    final pdk = target.provider;
    if (!pdk.hasSramMacro) {
      _buildSimModel(clk, wordAddr, datIn, datOut, stb, we, ack, numWords, sel);
      return;
    }

    final macro = pdk.sramMacro(words: numWords, width: dataWidth);
    if (macro == null) {
      _buildSimModel(clk, wordAddr, datIn, datOut, stb, we, ack, numWords, sel);
      return;
    }

    // Instantiate the PDK SRAM macro as a blackbox
    final sramBlock = _PdkSramMacro(
      macroName: macro.properties['name'] ?? 'sram_macro',
      addrWidth: wordAddr.width,
      dataWidth: busDataWidth ?? dataWidth,
      pinMapping: macro.pinMapping,
    );
    addSubModule(sramBlock);

    final clkPin = macro.pinMapping['clk'] ?? 'clk';
    final addrPin = macro.pinMapping['addr'] ?? 'addr';
    final dataInPin = macro.pinMapping['dataIn'] ?? 'dataIn';
    final dataOutPin = macro.pinMapping['dataOut'] ?? 'dataOut';
    final wePin = macro.pinMapping['writeEnable'] ?? 'writeEnable';
    final csPin = macro.pinMapping['chipSelect'] ?? 'chipSelect';

    sramBlock.input(clkPin).srcConnection! <= clk;
    sramBlock.input(addrPin).srcConnection! <= wordAddr;
    sramBlock.input(dataInPin).srcConnection! <= datIn;
    sramBlock.input(wePin).srcConnection! <= stb & we;
    sramBlock.input(csPin).srcConnection! <= stb;

    datOut <= sramBlock.output(dataOutPin);

    Sequential(clk, [
      ack < Const(0),
      If(stb & ~ack, then: [ack < Const(1)]),
    ]);
  }

  /// A behavioral memory array for a Verilator build.
  ///
  /// The generic model builds one register and one mux leg per word, which
  /// stops scaling long before a framebuffer. A simulator does not need that:
  /// a SystemVerilog array is exact, unlimited, and compiles in constant time.
  /// The protocol matches the generic model exactly (ack one cycle after the
  /// strobe, registered read data, per-lane write enables), so a design behaves
  /// the same whichever path it takes.
  void _buildSimArray(
    Logic clk,
    Logic wordAddr,
    Logic datIn,
    Logic datOut,
    Logic stb,
    Logic we,
    Logic ack,
    Logic sel,
  ) {
    final array = addSubModule(
      HarborSramArray(
        words: size ~/ (dataWidth ~/ 8),
        dataWidth: dataWidth,
        addrWidth: wordAddr.width,
        name: '${name}_array',
      ),
    );
    array.input('clk').srcConnection! <= clk;
    array.input('addr').srcConnection! <= wordAddr;
    array.input('din').srcConnection! <= datIn;
    array.input('we').srcConnection! <= we;
    array.input('stb').srcConnection! <= stb;
    array.input('sel').srcConnection! <= sel;
    datOut <= array.output('dout');
    ack <= array.output('ack');
  }

  void _buildSimModel(
    Logic clk,
    Logic wordAddr,
    Logic datIn,
    Logic datOut,
    Logic stb,
    Logic we,
    Logic ack,
    int numWords,
    Logic sel,
  ) {
    // Merge a write into the stored word honoring the Wishbone byte-lane
    // selects: a lane keeps its old byte unless its sel bit is set. Without
    // this a sub-word store (e.g. `sb`) writes the whole word and clobbers its
    // neighbors, so a byte-at-a-time fill keeps only the last byte (found via
    // the maskrom banner: SRAM read back as 0x..00 with only one lane set).
    // The ECP5/iCE40 BRAM paths already honor sel via per-lane write enables.
    // This keeps the generic sim/inferred-BRAM path faithful to them.
    Logic mergeSel(Logic old, Logic data) {
      final bytes = <Logic>[
        for (var b = 0; b < dataWidth ~/ 8; b++)
          mux(
            sel[b],
            data.getRange(b * 8, b * 8 + 8),
            old.getRange(b * 8, b * 8 + 8),
          ),
      ];
      return bytes.rswizzle();
    }

    // For simulation or small memories: Yosys will infer BRAM from this
    // pattern during synthesis. Each word costs a register plus a mux leg, so
    // this path is only viable for a small memory.
    //
    // Refusing is deliberate. Quietly building a smaller memory than asked for
    // makes every access above the cut vanish: writes are dropped, reads come
    // back zero, and the device tree still advertises the full size, so the
    // failure surfaces far from its cause (a framebuffer that renders only its
    // first rows, a heap that corrupts past a boundary).
    const maxSimWords = 1024;
    if (numWords > maxSimWords) {
      throw ArgumentError(
        'HarborSram of $size bytes needs $numWords words, past the '
        '$maxSimWords this generic model can build. Pass a `target` so it '
        'uses that device\'s memory (FPGA block RAM, an ASIC macro, or the '
        'behavioral array for a Verilator build), or make it smaller.',
      );
    }
    final effectiveWords = numWords;

    final mem = <Logic>[
      for (var i = 0; i < effectiveWords; i++)
        Logic(name: 'mem_$i', width: dataWidth),
    ];

    Logic readData = Const(0, width: dataWidth);
    for (var i = 0; i < effectiveWords; i++) {
      readData = mux(
        wordAddr.eq(Const(i, width: wordAddr.width)),
        mem[i],
        readData,
      );
    }

    Sequential(clk, [
      ack < Const(0),
      datOut < Const(0, width: dataWidth),
      If(
        stb & ~ack,
        then: [
          ack < Const(1),
          If(
            we,
            then: [
              for (var i = 0; i < effectiveWords; i++)
                If(
                  wordAddr.eq(Const(i, width: wordAddr.width)),
                  then: [mem[i] < mergeSel(mem[i], datIn)],
                ),
            ],
            orElse: [datOut < readData],
          ),
        ],
      ),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,sram', 'mmio-sram'],
    reg: BusAddressRange(baseAddress, size),
    properties: {'data-width': dataWidth},
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, size)],
    properties: {
      'compatible': ['harbor,sram', 'mmio-sram'],
      'data-width': dataWidth,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'SRAM',
    groupName: 'SRAM',
    description: 'On-chip SRAM memory',
    baseAddress: baseAddress,
    size: size,
  );
}

/// PDK SRAM macro instantiated as a blackbox leaf.
class _PdkSramMacro extends BridgeModule {
  _PdkSramMacro({
    required String macroName,
    required int addrWidth,
    required int dataWidth,
    required Map<String, String> pinMapping,
  }) : super(macroName, isSystemVerilogLeaf: true) {
    final clkPin = pinMapping['clk'] ?? 'clk';
    final addrPin = pinMapping['addr'] ?? 'addr';
    final dataInPin = pinMapping['dataIn'] ?? 'dataIn';
    final dataOutPin = pinMapping['dataOut'] ?? 'dataOut';
    final wePin = pinMapping['writeEnable'] ?? 'writeEnable';
    final csPin = pinMapping['chipSelect'] ?? 'chipSelect';

    createPort(clkPin, PortDirection.input);
    createPort(addrPin, PortDirection.input, width: addrWidth);
    createPort(dataInPin, PortDirection.input, width: dataWidth);
    createPort(dataOutPin, PortDirection.output, width: dataWidth);
    createPort(wePin, PortDirection.input);
    createPort(csPin, PortDirection.input);
  }
}

/// The behavioral memory behind [HarborSram] under a Verilator target.
///
/// A leaf: it has no ROHD body, only the SystemVerilog one below, because a
/// word-per-register array does not scale to the sizes a simulation wants to
/// model. Sized modules get sized definition names, so two different memories
/// cannot collide on one emitted file.
class HarborSramArray extends BridgeModule with HarborSimLeaf {
  /// Words of storage.
  final int words;

  /// Bits per word.
  final int dataWidth;

  /// Width of the word address port.
  final int addrWidth;

  HarborSramArray({
    required this.words,
    required this.dataWidth,
    required this.addrWidth,
    String? name,
  }) : super(
         'HarborSramArray_${words}x$dataWidth',
         name: name ?? 'sram_array',
         isSystemVerilogLeaf: true,
       ) {
    createPort('clk', PortDirection.input);
    createPort('addr', PortDirection.input, width: addrWidth);
    createPort('din', PortDirection.input, width: dataWidth);
    createPort('we', PortDirection.input);
    createPort('stb', PortDirection.input);
    createPort('sel', PortDirection.input, width: dataWidth ~/ 8);
    addOutput('dout', width: dataWidth);
    addOutput('ack');
  }

  @override
  String get simRtl {
    final lanes = dataWidth ~/ 8;
    return '''
// Auto-generated behavioral SRAM for the Verilator build.
// Single-cycle ack, registered read data, per-lane write enables: the same
// protocol the generic ROHD model implements, at a size it cannot reach.
module $definitionName (
  input  logic clk,
  input  logic [${addrWidth - 1}:0] addr,
  input  logic [${dataWidth - 1}:0] din,
  input  logic we,
  input  logic stb,
  input  logic [${lanes - 1}:0] sel,
  output logic [${dataWidth - 1}:0] dout,
  output logic ack
);
  logic [${dataWidth - 1}:0] mem [0:${words - 1}];
  initial begin
    for (int i = 0; i < $words; i++) mem[i] = '0;
  end
  always_ff @(posedge clk) begin
    ack <= 1'b0;
    dout <= '0;
    if (stb && !ack) begin
      ack <= 1'b1;
      if (we) begin
        for (int b = 0; b < $lanes; b++) begin
          if (sel[b]) mem[addr][b*8 +: 8] <= din[b*8 +: 8];
        end
      end else begin
        dout <= mem[addr];
      end
    end
  end
endmodule
''';
  }
}
