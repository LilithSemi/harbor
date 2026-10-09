/// Behavioral dram leaf shared by the Verilator build of every memory
/// controller wrapper (ddr3, sdr sdram). It carries its own SystemVerilog
/// body, so the ports and the module they must match live in one place.
library;

import 'package:rohd_bridge/rohd_bridge.dart';

import '../soc/target.dart';

/// Single-cycle wishbone b4 ram leaf for a [HarborSimTarget] build. It
/// replaces the cdc, front end and phy of a memory controller, which a host
/// Verilator build cannot usefully simulate.
class HarborSimDram extends BridgeModule with HarborSimLeaf {
  final int addrWidth;
  final int dataWidth;
  final int words;
  final int byteSize;

  HarborSimDram({
    required this.addrWidth,
    required this.dataWidth,
    required this.words,
    required this.byteSize,
  }) : super(
         _definitionName(addrWidth: addrWidth, dataWidth: dataWidth, words: words),
         name: 'sim_dram',
         isSystemVerilogLeaf: true,
       ) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('stb', PortDirection.input);
    createPort('we', PortDirection.input);
    createPort('adr', PortDirection.input, width: addrWidth);
    createPort('dat_w', PortDirection.input, width: dataWidth);
    createPort('sel', PortDirection.input, width: dataWidth ~/ 8);
    addOutput('ack');
    addOutput('dat_r', width: dataWidth);
  }

  /// Holds every parameter that changes the generated module's ports, so
  /// two instances with different widths or sizes never share a name.
  static String _definitionName({
    required int addrWidth,
    required int dataWidth,
    required int words,
  }) => 'harbor_sim_dram_${addrWidth}a${dataWidth}d${words}w';

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
    b.writeln('  output logic [${dw - 1}:0] dat_r');
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
    b.writeln('endmodule');
    return b.toString();
  }
}
