import 'package:rohd/rohd.dart';

import '../peripherals/bram.dart';
import '../soc/target.dart';

/// Two line buffers with a system-clock write port and a registered read
/// port, the clock-domain-crossing element of framebuffer scanout.
///
/// The framebuffer DMA (system clock) bursts a scanline into the buffer
/// selected by [wrSel], the scanout (pixel clock) reads the buffer selected by
/// [rdSel] at column [rdCol]. Double-buffering guarantees the read buffer is
/// never the buffer being written, so the read crossing into the pixel domain
/// is a safe quasi-static (multi-cycle) path, only the small line-swap handshake
/// (built by the surrounding controller) crosses through synchronizers.
///
/// [rdData] is registered on [rdClk], one cycle after [rdSel] and [rdCol]. With
/// a [blockRam] the two buffers are one block RAM addressed by `{sel, col}`.
/// Without one they are flops, with the same read latency.
class HarborDoubleLineBuffer extends Module {
  /// The selected buffer's word at [rdCol], one [rdClk] cycle later.
  Logic get rdData => output('rd_data');

  final int maxWords;

  /// The block RAM cell that holds the buffers, or null for flops.
  final HarborBlockRam? blockRam;

  HarborDoubleLineBuffer({
    required Logic wrClk,
    required Logic wrEn,
    required Logic wrSel,
    required Logic wrIdx,
    required Logic wrData,
    required Logic rdClk,
    required Logic rdReset,
    required Logic rdSel,
    required Logic rdCol,
    this.maxWords = 1024,
    this.blockRam,
    super.name = 'double_line_buffer',
  }) : super(definitionName: 'HarborDoubleLineBuffer') {
    final idxW = (maxWords - 1).bitLength < 1 ? 1 : (maxWords - 1).bitLength;

    wrClk = addInput('wr_clk', wrClk);
    wrEn = addInput('wr_en', wrEn);
    wrSel = addInput('wr_sel', wrSel);
    wrIdx = addInput('wr_idx', wrIdx, width: idxW);
    wrData = addInput('wr_data', wrData, width: 32);
    rdClk = addInput('rd_clk', rdClk);
    rdReset = addInput('rd_reset', rdReset);
    rdSel = addInput('rd_sel', rdSel);
    rdCol = addInput('rd_col', rdCol, width: rdCol.width);
    addOutput('rd_data', width: 32);

    final col = rdCol.width >= idxW
        ? rdCol.getRange(0, idxW)
        : rdCol.zeroExtend(idxW);

    final bram = blockRam;
    if (bram != null) {
      final ram = HarborDualClockBram(
        wrClk: wrClk,
        wrEn: wrEn,
        wrAddr: [wrSel, wrIdx].swizzle(),
        wrData: wrData,
        rdClk: rdClk,
        rdReset: rdReset,
        rdEn: Const(1),
        rdAddr: [rdSel, col].swizzle(),
        width: 32,
        depth: 2 << idxW,
        primitive: bram,
        name: 'lines',
      );
      rdData <= ram.rdData;
      return;
    }

    final buf0 = List.generate(
      maxWords,
      (i) => Logic(name: 'b0_$i', width: 32),
    );
    final buf1 = List.generate(
      maxWords,
      (i) => Logic(name: 'b1_$i', width: 32),
    );

    Sequential(wrClk, [
      If(
        wrEn,
        then: [
          for (var i = 0; i < maxWords; i++)
            If(
              wrIdx.eq(i),
              then: [
                If(wrSel, then: [buf1[i] < wrData], orElse: [buf0[i] < wrData]),
              ],
            ),
        ],
      ),
    ]);

    final rdReg = Logic(name: 'rd_reg', width: 32);
    Sequential(rdClk, reset: rdReset, [
      rdReg < mux(rdSel, _tree(col, buf1), _tree(col, buf0)),
    ]);
    rdData <= rdReg;
  }

  /// Binary mux tree over [words], indexed by [index].
  static Logic _tree(Logic index, List<Logic> words) {
    var level = words;
    for (var b = 0; b < index.width; b++) {
      level = [
        for (var i = 0; i < level.length; i += 2)
          i + 1 < level.length
              ? mux(index[b], level[i + 1], level[i])
              : level[i],
      ];
    }
    return level.single;
  }
}
