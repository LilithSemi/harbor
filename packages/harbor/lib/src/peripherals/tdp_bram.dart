import 'dart:async';

import 'package:rohd/rohd.dart';

import '../arith/fpu_config.dart' show harborStableDefinitionName;
import '../blackbox/ecp5/ecp5.dart';
import '../soc/target.dart';

/// A block RAM with one read port (A) and one read/write port (B) on one
/// clock. Both reads are registered: the data shows one clock after the
/// address.
///
/// Port B writes when `b_we` is high and reads when it is low. On a write
/// clock `b_rdata` keeps its value. When port A reads the address that port B
/// writes on the same clock, `a_rdata` is undefined. The memory starts at 0.
///
/// With [primitive] `dp16kd` the module places ECP5 `DP16KD` blocks in x18
/// mode, 1024 words each, so a 4096 word memory of up to 18 bits takes 4
/// blocks. The simulation runs the `Ecp5Dp16kd` model. Any other value, or
/// null, emits a plain inferrable memory for the synthesis tool.
class HarborTdpBram extends Module {
  final int width;
  final int depth;
  final HarborBlockRam? primitive;

  Logic get aRdata => output('a_rdata');
  Logic get bRdata => output('b_rdata');

  HarborTdpBram(
    Logic clk, {
    required this.width,
    required this.depth,
    required Logic aAddr,
    required Logic bAddr,
    required Logic bWe,
    required Logic bWdata,
    this.primitive,
    super.name = 'harbor_tdp_bram',
  }) : super(
         definitionName: harborStableDefinitionName('HarborTdpBram', [
           '${width}x$depth',
           primitive?.name ?? 'gen',
         ]),
         reserveDefinitionName: true,
       ) {
    if (depth < 2 || depth & (depth - 1) != 0) {
      throw ArgumentError.value(depth, 'depth', 'Must be a power of 2.');
    }
    if (width < 1 || (primitive == HarborBlockRam.dp16kd && width > 18)) {
      throw ArgumentError.value(width, 'width', 'Out of range.');
    }
    final aw = (depth - 1).bitLength;
    clk = addInput('clk', clk);
    aAddr = addInput('a_addr', aAddr, width: aw);
    bAddr = addInput('b_addr', bAddr, width: aw);
    bWe = addInput('b_we', bWe);
    bWdata = addInput('b_wdata', bWdata, width: width);
    final aOut = addOutput('a_rdata', width: width);
    final bOut = addOutput('b_rdata', width: width);

    if (primitive != HarborBlockRam.dp16kd) {
      final gen = _HarborTdpRamGeneric(
        clk,
        width: width,
        depth: depth,
        aAddr: aAddr,
        bAddr: bAddr,
        bWe: bWe,
        bWdata: bWdata,
      );
      aOut <= gen.aRdata;
      bOut <= gen.bRdata;
      return;
    }

    const blockDepth = 1024;
    final blocks = depth <= blockDepth ? 1 : depth ~/ blockDepth;
    final idxBits = aw < 10 ? aw : 10;
    final bankBits = aw - idxBits;
    Logic wordAddr(Logic a) => [
      a.slice(idxBits - 1, 0).zeroExtend(10),
      Const(0, width: 2),
      Const(3, width: 2),
    ].concat();
    final aWord = wordAddr(aAddr);
    final bWord = wordAddr(bAddr);
    Logic bank(Logic a) => bankBits == 0 ? Const(0) : a.slice(aw - 1, idxBits);
    final aBank = bank(aAddr);
    final bBank = bank(bAddr);
    Logic enable(Logic b, int i) =>
        bankBits == 0 ? Const(1) : b.eq(Const(i, width: bankBits));

    final aDo = <Logic>[];
    final bDo = <Logic>[];
    for (var i = 0; i < blocks; i++) {
      final ram = Ecp5Dp16kd(
        name: 'bram_$i',
        clkA: clk,
        ceA: enable(aBank, i),
        weA: Const(0),
        oceA: Const(0),
        rstA: Const(0),
        adA: aWord,
        diA: Const(0, width: 18),
        clkB: clk,
        ceB: enable(bBank, i),
        weB: bWe,
        oceB: Const(0),
        rstB: Const(0),
        adB: bWord,
        diB: bWdata.zeroExtend(18),
      );
      aDo.add(ram.doA.slice(width - 1, 0));
      bDo.add(ram.doB.slice(width - 1, 0));
    }
    if (blocks == 1) {
      aOut <= aDo[0];
      bOut <= bDo[0];
      return;
    }
    final aSel = flop(clk, aBank);
    // A write clock keeps the last read data, so the bank select holds too.
    final bSel = flop(clk, bBank, en: ~bWe);
    Logic pick(Logic sel, List<Logic> outs) {
      var v = outs[0];
      for (var i = 1; i < outs.length; i++) {
        v = mux(sel.eq(Const(i, width: bankBits)), outs[i], v);
      }
      return v;
    }

    aOut <= pick(aSel, aDo);
    bOut <= pick(bSel, bDo);
  }
}

class _HarborTdpRamGeneric extends Module with SystemVerilog {
  final int width;
  final int depth;
  final int addrWidth;

  Logic get aRdata => output('a_rdata');
  Logic get bRdata => output('b_rdata');

  _HarborTdpRamGeneric(
    Logic clk, {
    required this.width,
    required this.depth,
    required Logic aAddr,
    required Logic bAddr,
    required Logic bWe,
    required Logic bWdata,
  }) : addrWidth = (depth - 1).bitLength,
       super(
         name: 'tdp_ram',
         definitionName: 'HarborTdpRam_${width}x$depth',
         reserveDefinitionName: true,
       ) {
    clk = addInput('clk', clk);
    aAddr = addInput('a_addr', aAddr, width: addrWidth);
    bAddr = addInput('b_addr', bAddr, width: addrWidth);
    bWe = addInput('b_we', bWe);
    bWdata = addInput('b_wdata', bWdata, width: width);
    final aOut = addOutput('a_rdata', width: width);
    final bOut = addOutput('b_rdata', width: width);

    final zero = LogicValue.filled(width, LogicValue.zero);
    final unknown = LogicValue.filled(width, LogicValue.x);
    final mem = List<LogicValue>.filled(depth, zero);
    aOut.put(zero);
    bOut.put(zero);
    clk.posedge.listen((_) {
      final aa = aAddr.previousValue ?? aAddr.value;
      final ba = bAddr.previousValue ?? bAddr.value;
      final we = bWe.previousValue ?? bWe.value;
      final wd = bWdata.previousValue ?? bWdata.value;
      final writes = we == LogicValue.one && ba.isValid && ba.toInt() < depth;
      var nextA = aa.isValid && aa.toInt() < depth ? mem[aa.toInt()] : unknown;
      if (writes && aa == ba) nextA = unknown;
      var nextB = bOut.value;
      if (we != LogicValue.one) {
        nextB = ba.isValid && ba.toInt() < depth ? mem[ba.toInt()] : unknown;
      }
      if (writes) mem[ba.toInt()] = wd;
      unawaited(
        Simulator.clkStable.first
            .then((_) {
              aOut.put(nextA);
              bOut.put(nextB);
            })
            .catchError((_) {}, test: (e) => e is StateError),
      );
    });
  }

  @override
  String? definitionVerilog(String definitionType) =>
      '''
module $definitionType (
  input logic clk,
  input logic [${addrWidth - 1}:0] a_addr,
  input logic [${addrWidth - 1}:0] b_addr,
  input logic b_we,
  input logic [${width - 1}:0] b_wdata,
  output logic [${width - 1}:0] a_rdata,
  output logic [${width - 1}:0] b_rdata
);
  logic [${width - 1}:0] mem [0:${depth - 1}];
  initial begin
    for (int i = 0; i < $depth; i++) mem[i] = '0;
    a_rdata = '0;
    b_rdata = '0;
  end
  always_ff @(posedge clk) a_rdata <= mem[a_addr];
  always_ff @(posedge clk) begin
    if (b_we) mem[b_addr] <= b_wdata;
    else b_rdata <= mem[b_addr];
  end
endmodule''';
}
