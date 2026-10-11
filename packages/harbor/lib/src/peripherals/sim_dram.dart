/// Behavioral dram leaf shared by the Verilator build of every memory
/// controller wrapper (ddr3, sdr sdram). It carries its own SystemVerilog
/// body, so the ports and the module they must match live in one place.
library;

import 'package:rohd_bridge/rohd_bridge.dart';

import '../soc/target.dart';

/// Wishbone b4 ram leaf for a [HarborSimTarget] build. It replaces the cdc,
/// front end and phy of a memory controller, which a host Verilator build
/// cannot usefully simulate.
///
/// By default it acks one cycle after the strobe. [readLatency] and
/// [writeLatency] set the cycles from the strobe to the ack, so a build can
/// show the per access cost of the real controller. [latencyFor] gives that
/// cost for a controller clock behind a clock crossing.
///
/// [scanoutPorts] adds read ports as on [HarborSdram], on `clk`. Each gives
/// one 16-bit word a cycle. Their `rq_addr` is a 16-bit word address.
class HarborSimDram extends BridgeModule with HarborSimLeaf {
  final int addrWidth;
  final int dataWidth;
  final int words;
  final int byteSize;

  /// Bus cycles from a read strobe to its ack.
  final int readLatency;

  /// Bus cycles from a write strobe to its ack.
  final int writeLatency;

  /// Number of scanout read ports.
  final int scanoutPorts;

  HarborSimDram({
    required this.addrWidth,
    required this.dataWidth,
    required this.words,
    required this.byteSize,
    this.readLatency = 1,
    this.writeLatency = 1,
    this.scanoutPorts = 0,
  }) : super(
         _definitionName(
           addrWidth: addrWidth,
           dataWidth: dataWidth,
           words: words,
           readLatency: readLatency,
           writeLatency: writeLatency,
           scanoutPorts: scanoutPorts,
         ),
         name: 'sim_dram',
         isSystemVerilogLeaf: true,
       ) {
    for (final (v, n) in [
      (readLatency, 'readLatency'),
      (writeLatency, 'writeLatency'),
    ]) {
      if (v < 1 || v > 1024) {
        throw ArgumentError.value(v, n, 'must be from 1 to 1024');
      }
    }
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('stb', PortDirection.input);
    createPort('we', PortDirection.input);
    createPort('adr', PortDirection.input, width: addrWidth);
    createPort('dat_w', PortDirection.input, width: dataWidth);
    createPort('sel', PortDirection.input, width: dataWidth ~/ 8);
    addOutput('ack');
    addOutput('dat_r', width: dataWidth);
    if (scanoutPorts > 0 && dataWidth != 32) {
      throw ArgumentError('scanout ports need a 32-bit data width');
    }
    for (var i = 0; i < scanoutPorts; i++) {
      createPort('scan${i}_rq_valid', PortDirection.input);
      createPort(
        'scan${i}_rq_addr',
        PortDirection.input,
        width: _scanAddrWidth,
      );
      createPort('scan${i}_rq_words', PortDirection.input, width: 4);
      addOutput('scan${i}_rq_ready');
      addOutput('scan${i}_rd_valid');
      addOutput('scan${i}_rd_data', width: 16);
    }
  }

  int get _scanAddrWidth => (byteSize - 1).bitLength - 1;

  /// The bus cycles of one access to a memory controller that runs on
  /// [memHz] behind a clock crossing from a bus on [busHz]: [crossingCycles]
  /// bus cycles for the crossing and [memCycles] controller cycles.
  ///
  /// The defaults match [HarborSdram] with its clock crossing, measured with
  /// back to back 32-bit reads from a 25 MHz bus: 10 cycles at 100 MHz and 9
  /// at 125 MHz.
  static int latencyFor({
    required int busHz,
    required int memHz,
    int memCycles = 19,
    int crossingCycles = 5,
  }) => crossingCycles + (memCycles * busHz + memHz - 1) ~/ memHz;

  /// Holds every parameter that changes the generated module, so two
  /// instances with different widths, sizes or latencies never share a name.
  static String _definitionName({
    required int addrWidth,
    required int dataWidth,
    required int words,
    required int readLatency,
    required int writeLatency,
    required int scanoutPorts,
  }) {
    var name = 'harbor_sim_dram_${addrWidth}a${dataWidth}d${words}w';
    if (readLatency != 1 || writeLatency != 1) {
      name = '${name}_r${readLatency}w$writeLatency';
    }
    if (scanoutPorts > 0) name = '${name}_s$scanoutPorts';
    return name;
  }

  @override
  String get simRtl {
    final dw = dataWidth;
    final aw = addrWidth;
    final lanes = dw ~/ 8;
    final byteBits = (lanes - 1).bitLength;
    final idxBits = (words - 1).bitLength;
    final b = StringBuffer();
    b.writeln('// Generated behavioral dram for the Verilator build.');
    b.writeln('// It replaces the memory controller and its phy.');
    b.writeln('//');
    b.writeln('// Preload a boot image with a plusarg, e.g.');
    b.writeln('//   ./obj_dir/Vtop +dram_image=fw.hex');
    b.writeln('// where fw.hex is one $dw-bit word per line in hex');
    b.writeln('// (objcopy -O verilog, or hexdump).');
    b.writeln('module $definitionName (');
    b.writeln('  input  logic            clk,');
    b.writeln('  input  logic            reset,');
    b.writeln('  input  logic            stb,');
    b.writeln('  input  logic            we,');
    b.writeln('  input  logic [${aw - 1}:0] adr,');
    b.writeln('  input  logic [${dw - 1}:0] dat_w,');
    b.writeln('  input  logic [${lanes - 1}:0]  sel,');
    b.writeln('  output logic            ack,');
    b.writeln(
      '  output logic [${dw - 1}:0] dat_r${scanoutPorts > 0 ? ',' : ''}',
    );
    final sw = _scanAddrWidth;
    for (var i = 0; i < scanoutPorts; i++) {
      final last = i == scanoutPorts - 1;
      b.writeln('  input  logic            scan${i}_rq_valid,');
      b.writeln('  input  logic [${sw - 1}:0] scan${i}_rq_addr,');
      b.writeln('  input  logic [3:0]      scan${i}_rq_words,');
      b.writeln('  output logic            scan${i}_rq_ready,');
      b.writeln('  output logic            scan${i}_rd_valid,');
      b.writeln('  output logic [15:0]     scan${i}_rd_data${last ? '' : ','}');
    }
    b.writeln(');');
    b.writeln('  // $words words of $dw bits ($byteSize bytes).');
    b.writeln('  logic [${dw - 1}:0] mem [0:${words - 1}];');
    b.writeln(
      '  wire [${idxBits - 1}:0] widx = adr[${idxBits + byteBits - 1}:'
      '$byteBits];',
    );
    b.writeln();
    b.writeln('  string image;');
    b.writeln('  initial begin');
    b.writeln('    if (\$value\$plusargs("dram_image=%s", image))');
    b.writeln('      \$readmemh(image, mem);');
    b.writeln('  end');
    b.writeln();
    if (readLatency > 1 || writeLatency > 1) {
      _writeSlowAccess(b, lanes);
      _writeScanPorts(b);
      b.writeln('endmodule');
      return b.toString();
    }
    b.writeln(
      '  // Single-cycle ack. The bus master must drop stb on the ack,',
    );
    b.writeln('  // so `ack` is gated on its own previous value.');
    b.writeln('  always_ff @(posedge clk) begin');
    b.writeln('    if (reset) begin');
    b.writeln("      ack <= 1'b0;");
    b.writeln('    end else begin');
    b.writeln('      ack <= stb & ~ack;');
    b.writeln('      if (stb & ~ack & we) begin');
    for (var l = 0; l < lanes; l++) {
      b.writeln(
        '        if (sel[$l]) mem[widx][${l * 8 + 7}:${l * 8}] '
        '<= dat_w[${l * 8 + 7}:${l * 8}];',
      );
    }
    b.writeln('      end');
    b.writeln('      dat_r <= mem[widx];');
    b.writeln('    end');
    b.writeln('  end');
    _writeScanPorts(b);
    b.writeln('endmodule');
    return b.toString();
  }

  /// One 16-bit word a cycle per scanout port, low half of a word first.
  void _writeScanPorts(StringBuffer b) {
    final sw = _scanAddrWidth;
    for (var i = 0; i < scanoutPorts; i++) {
      final p = 'scan$i';
      final word = 'mem[${p}_addr[${sw - 1}:1]]';
      b.writeln();
      b.writeln('  // Scanout port $i.');
      b.writeln('  logic [${sw - 1}:0] ${p}_addr;');
      b.writeln('  logic [3:0] ${p}_left;');
      b.writeln("  assign ${p}_rq_ready = ${p}_left <= 4'd1;");
      b.writeln('  always_ff @(posedge clk) begin');
      b.writeln('    if (reset) begin');
      b.writeln("      ${p}_left <= 4'd0;");
      b.writeln("      ${p}_rd_valid <= 1'b0;");
      b.writeln('    end else begin');
      b.writeln("      ${p}_rd_valid <= ${p}_left != 4'd0;");
      b.writeln(
        '      ${p}_rd_data <= ${p}_addr[0] ? $word[31:16] : $word[15:0];',
      );
      b.writeln("      if (${p}_left != 4'd0) begin");
      b.writeln("        ${p}_addr <= ${p}_addr + 1'b1;");
      b.writeln("        ${p}_left <= ${p}_left - 4'd1;");
      b.writeln('      end');
      b.writeln('      if (${p}_rq_valid & ${p}_rq_ready) begin');
      b.writeln('        ${p}_addr <= ${p}_rq_addr;');
      b.writeln('        ${p}_left <= ${p}_rq_words;');
      b.writeln('      end');
      b.writeln('    end');
      b.writeln('  end');
    }
  }

  /// The access logic with a wait counter: the ack comes [readLatency] or
  /// [writeLatency] cycles after the strobe. A strobe that drops first
  /// cancels the access.
  void _writeSlowAccess(StringBuffer b, int lanes) {
    final cw =
        (readLatency > writeLatency ? readLatency : writeLatency).bitLength;
    b.writeln(
      '  // Ack $readLatency cycles after a read strobe and '
      '$writeLatency after a write strobe.',
    );
    b.writeln('  logic busy;');
    b.writeln('  logic [${cw - 1}:0] left;');
    b.writeln('  wire start = stb & ~ack & ~busy;');
    b.writeln(
      '  wire [${cw - 1}:0] lat = we ? $cw\'d$writeLatency : '
      '$cw\'d$readLatency;',
    );
    b.writeln(
      "  wire fire = start ? lat == $cw'd1 : "
      "busy & stb & left == $cw'd0;",
    );
    b.writeln('  always_ff @(posedge clk) begin');
    b.writeln('    if (reset) begin');
    b.writeln("      ack <= 1'b0;");
    b.writeln("      busy <= 1'b0;");
    b.writeln('    end else begin');
    b.writeln('      ack <= fire;');
    b.writeln('      if (start & ~fire) begin');
    b.writeln("        busy <= 1'b1;");
    b.writeln("        left <= lat - $cw'd2;");
    b.writeln('      end else if (busy) begin');
    b.writeln("        if (fire | ~stb) busy <= 1'b0;");
    b.writeln("        else left <= left - $cw'd1;");
    b.writeln('      end');
    b.writeln('      if (fire & we) begin');
    for (var l = 0; l < lanes; l++) {
      b.writeln(
        '        if (sel[$l]) mem[widx][${l * 8 + 7}:${l * 8}] '
        '<= dat_w[${l * 8 + 7}:${l * 8}];',
      );
    }
    b.writeln('      end');
    b.writeln('      dat_r <= mem[widx];');
    b.writeln('    end');
    b.writeln('  end');
  }
}
