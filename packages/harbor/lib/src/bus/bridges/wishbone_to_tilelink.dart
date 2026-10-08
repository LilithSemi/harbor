import 'package:rohd/rohd.dart';

import '../tilelink/tilelink_interface.dart';
import '../wishbone/wishbone_interface.dart';

/// Number of bytes selected by [sel], used to pick a TileLink SIZE encoding.
Logic _selByteCount(Logic sel) {
  Logic sum = Const(0, width: sel.width + 1);
  for (var i = 0; i < sel.width; i++) {
    sum = sum + sel[i].zeroExtend(sum.width);
  }
  return sum;
}

/// TileLink A_SIZE (log2 bytes) for a Wishbone SEL mask, instead of a fixed
/// 4-byte beat.
Logic _sizeFromSel(Logic sel, int sizeWidth) {
  final maxBytes = sel.width;
  final fullSize = maxBytes.bitLength - 1;
  final count = _selByteCount(sel);
  Logic size = Const(fullSize, width: sizeWidth);
  for (var bytes = maxBytes; bytes >= 1; bytes ~/= 2) {
    final enc = bytes.bitLength - 1;
    size = mux(
      count.eq(Const(bytes, width: count.width)),
      Const(enc, width: sizeWidth),
      size,
    );
  }
  return size;
}

/// Bridges a Wishbone master to a TileLink slave.
///
/// Converts Wishbone bus transactions to TileLink Channel A/D
/// transactions. Useful for connecting Wishbone peripherals to a
/// TileLink fabric. Single outstanding: Channel A is issued once per
/// Wishbone cycle and held until A_READY, then the bridge waits for the
/// matching D response.
class WishboneToTileLinkBridge extends Module {
  WishboneToTileLinkBridge(
    WishboneInterface wb,
    TileLinkInterface tl, {
    required Logic clk,
    required Logic reset,
    super.name = 'wb2tl',
  }) : super(definitionName: 'WishboneToTileLinkBridge') {
    final clkIn = addInput('clk', clk);
    final resetIn = addInput('reset', reset);

    final config = tl.config;
    final isActive = wb.cyc & wb.stb;

    final aValidReg = Logic(name: 'a_valid_reg');
    final dWaitReg = Logic(name: 'd_wait_reg');
    // Dropped the moment CYC aborts; the D response is still drained (A was
    // already issued and cannot be retracted) but no longer acked upstream.
    final pendingLive = Logic(name: 'pending_live');
    final ackReg = Logic(name: 's_ack_reg');
    final errReg = Logic(name: 's_err_reg');
    final datReg = Logic(name: 's_dat_reg', width: wb.config.dataWidth);
    final weReg = Logic(name: 'we_reg');
    // Payload is latched at issue and held while A_VALID is high, so an
    // aborted request still completes with what was issued.
    final adrReg = Logic(name: 'adr_reg', width: wb.config.addressWidth);
    final wdatReg = Logic(name: 'wdat_reg', width: wb.config.dataWidth);
    final selReg = Logic(name: 'sel_reg', width: wb.sel.width);

    final idle = ~aValidReg & ~dWaitReg;
    final busy = ~idle;
    // The master still holds CYC/STB on the cycle it sees the ack. Do not
    // take that as a new request.
    final issue = idle & ~ackReg & ~errReg;
    final aFire = aValidReg & tl.aReady;
    final dFire = dWaitReg & tl.dValid;

    Sequential(clkIn, reset: resetIn, [
      ackReg < Const(0),
      errReg < Const(0),

      If(
        issue & isActive,
        then: [
          aValidReg < Const(1),
          pendingLive < Const(1),
          weReg < wb.we,
          adrReg < wb.adr,
          wdatReg < wb.datMosi,
          selReg < wb.sel,
        ],
      ),

      // Orphan rule: an abort mid-flight only stops the ack, never the
      // TileLink handshake, which must still be seen through to completion.
      If(busy & ~wb.cyc, then: [pendingLive < Const(0)]),

      If(aFire, then: [aValidReg < Const(0), dWaitReg < Const(1)]),

      If(
        dFire,
        then: [
          dWaitReg < Const(0),
          If(
            pendingLive & wb.cyc,
            then: [
              If(
                tl.dDenied,
                then: [errReg < Const(1)],
                orElse: [
                  ackReg < Const(1),
                  datReg < tl.dData.getRange(0, wb.config.dataWidth),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    // Wishbone -> TileLink Channel A. Issued once and held until A_READY.
    tl.aValid <= aValidReg;
    tl.aOpcode <=
        mux(weReg, Const(0, width: 3), Const(4, width: 3)); // Put=0, Get=4
    tl.aParam <= Const(0, width: 3);
    tl.aSize <= _sizeFromSel(selReg, config.sizeWidth);
    tl.aSource <= Const(0, width: config.sourceWidth);
    tl.aAddress <= adrReg.zeroExtend(config.addressWidth);
    tl.aMask <= selReg.zeroExtend(config.maskWidth);
    tl.aData <= wdatReg.zeroExtend(config.dataWidth);
    tl.aCorrupt <= Const(0);

    // TileLink Channel D -> Wishbone. Only ready while actually waiting.
    tl.dReady <= dWaitReg;

    // Wishbone ACK/ERR: one termination per cycle, mutually exclusive, and
    // gated by CYC & STB so a stray pulse can never land on an unrelated
    // later cycle.
    wb.ack <= ackReg & wb.cyc & wb.stb;
    wb.datMiso <= datReg;
    if (wb.err != null) {
      wb.err! <= errReg & wb.cyc & wb.stb;
    }
  }
}
