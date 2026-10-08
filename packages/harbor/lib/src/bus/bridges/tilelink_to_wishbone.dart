import 'package:rohd/rohd.dart';

import '../tilelink/tilelink_interface.dart';
import '../wishbone/wishbone_interface.dart';

/// Bridges a TileLink master to a Wishbone slave.
///
/// Converts TileLink Channel A requests to Wishbone transactions
/// and routes Wishbone responses back through Channel D.
/// Useful for connecting a TileLink CPU to Wishbone peripherals.
///
/// Single outstanding: a request is latched once, then Wishbone CYC/STB
/// stay asserted from the latch until ACK or ERR (RTY, or no response yet,
/// simply holds and re-presents the same request, which is the correct
/// Wishbone classic retry behaviour). The response is held until D_READY
/// so a stalled TileLink master never loses it, and a new Channel A
/// request is only accepted once the previous response has drained.
class TileLinkToWishboneBridge extends Module {
  TileLinkToWishboneBridge(
    TileLinkInterface tl,
    WishboneInterface wb, {
    required Logic clk,
    required Logic reset,
    super.name = 'tl2wb',
  }) : super(definitionName: 'TileLinkToWishboneBridge') {
    final clkIn = addInput('clk', clk);
    final resetIn = addInput('reset', reset);

    final aw = wb.config.addressWidth;
    final dw = wb.config.dataWidth;
    final sw = wb.config.effectiveSelWidth;
    final wbErr = wb.err ?? Const(0);

    final latAdr = Logic(name: 'lat_adr', width: aw);
    final latWe = Logic(name: 'lat_we');
    final latDatW = Logic(name: 'lat_dat_w', width: dw);
    final latSel = Logic(name: 'lat_sel', width: sw);
    final latSize = Logic(name: 'lat_size', width: tl.config.sizeWidth);
    final latSource = Logic(name: 'lat_source', width: tl.config.sourceWidth);

    final wbCycReg = Logic(name: 'wb_cyc_reg');
    final respValid = Logic(name: 'resp_valid');
    final respDenied = Logic(name: 'resp_denied');
    final respData = Logic(name: 'resp_data', width: dw);
    final respWe = Logic(name: 'resp_we');
    final respSize = Logic(name: 'resp_size', width: tl.config.sizeWidth);
    final respSource = Logic(name: 'resp_source', width: tl.config.sourceWidth);

    final idle = ~wbCycReg & ~respValid;

    Sequential(clkIn, reset: resetIn, [
      If(
        idle & tl.aValid,
        then: [
          latAdr < tl.aAddress.getRange(0, aw),
          latWe <
              (tl.aOpcode.eq(Const(0, width: 3)) | // PutFullData
                  tl.aOpcode.eq(Const(1, width: 3))), // PutPartialData
          latDatW < tl.aData.getRange(0, dw),
          latSel < tl.aMask.getRange(0, sw),
          latSize < tl.aSize,
          latSource < tl.aSource,
          wbCycReg < Const(1),
        ],
      ),

      // ACK and ERR terminate the Wishbone cycle (mutually exclusive by the
      // Wishbone side's own contract). RTY, or no response yet, falls
      // through to neither branch, which holds wbCycReg and re-presents
      // the same latched request next cycle: the correct retry behaviour.
      If(
        wbCycReg & wb.ack,
        then: [
          wbCycReg < Const(0),
          respValid < Const(1),
          respDenied < Const(0),
          respData < wb.datMiso,
          respWe < latWe,
          respSize < latSize,
          respSource < latSource,
        ],
      ),
      If(
        wbCycReg & wbErr,
        then: [
          wbCycReg < Const(0),
          respValid < Const(1),
          respDenied < Const(1),
          respData < Const(0, width: dw),
          respWe < latWe,
          respSize < latSize,
          respSource < latSource,
        ],
      ),

      // Hold the response until the TileLink master is ready for it.
      If(respValid & tl.dReady, then: [respValid < Const(0)]),
    ]);

    // TileLink Channel A -> Wishbone, driven from the latched request.
    wb.cyc <= wbCycReg;
    wb.stb <= wbCycReg;
    wb.we <= latWe;
    wb.adr <= latAdr;
    wb.datMosi <= latDatW;
    wb.sel <= latSel;

    // Wishbone -> TileLink Channel D, held until D_READY.
    tl.dValid <= respValid;
    tl.dOpcode <= mux(respWe, Const(0, width: 3), Const(1, width: 3));
    tl.dParam <= Const(0, width: 2);
    tl.dSize <= respSize;
    tl.dSource <= respSource;
    tl.dSink <= Const(0, width: tl.config.sinkWidth);
    tl.dData <= respData.zeroExtend(tl.config.dataWidth);
    tl.dCorrupt <= Const(0);
    tl.dDenied <= respDenied;

    // Accept a new Channel A request only once fully idle: no Wishbone
    // cycle in flight and no unconsumed D response still waiting on
    // D_READY.
    tl.aReady <= idle;
  }
}
