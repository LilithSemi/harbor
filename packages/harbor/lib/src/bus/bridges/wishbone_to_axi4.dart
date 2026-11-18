import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' show Axi4ReadCluster, Axi4WriteCluster;

import '../wishbone/wishbone_interface.dart';

/// Number of bytes selected by [sel], used to pick an AXI4 SIZE encoding.
Logic _selByteCount(Logic sel) {
  Logic sum = Const(0, width: sel.width + 1);
  for (var i = 0; i < sel.width; i++) {
    sum = sum + sel[i].zeroExtend(sum.width);
  }
  return sum;
}

/// AXI4 SIZE (log2 bytes per beat) for a Wishbone SEL mask, instead of a
/// fixed 4-byte beat. Falls back to the full bus width for a SEL pattern
/// that is not a simple power-of-two byte count (e.g. all lanes idle).
Logic axiSizeFromSel(Logic sel, int sizeWidth) {
  final maxBytes = sel.width;
  final fullSize = (maxBytes.bitLength - 1).toUnsigned(sizeWidth);
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

/// Bridges a Wishbone master to AXI4 read/write slave interfaces.
///
/// Converts Wishbone read/write transactions to AXI4 AR/R and AW/W/B
/// channels. Single-beat transfers only (no burst), single outstanding.
///
/// Each Wishbone cycle issues its AXI request once and holds ARVALID (or
/// AWVALID/WVALID) until the subordinate accepts it, then waits for the
/// matching response. If the Wishbone master drops CYC while a request is
/// still outstanding, the bridge still has to finish what AXI4 requires
/// (VALID cannot be retracted once asserted, and the response must be
/// drained), but the result is dropped instead of acking a cycle that is no
/// longer there.
class WishboneToAxi4Bridge extends Module {
  WishboneToAxi4Bridge(
    WishboneInterface wb,
    Axi4ReadCluster axiRead,
    Axi4WriteCluster axiWrite, {
    required Logic clk,
    required Logic reset,
    super.name = 'wb2axi4',
  }) : super(definitionName: 'WishboneToAxi4Bridge') {
    final clkIn = addInput('clk', clk);
    final resetIn = addInput('reset', reset);

    final isRead = wb.cyc & wb.stb & ~wb.we;
    final isWrite = wb.cyc & wb.stb & wb.we;

    // Per-channel handshake state. AR and AW/W are independent because a
    // read and a write never overlap on a single-outstanding Wishbone cycle.
    final arValidReg = Logic(name: 'ar_valid_reg');
    final rWaitReg = Logic(name: 'r_wait_reg');
    final awValidReg = Logic(name: 'aw_valid_reg');
    final wValidReg = Logic(name: 'w_valid_reg');
    final bWaitReg = Logic(name: 'b_wait_reg');
    // Whether the in-flight request still belongs to a live Wishbone cycle.
    // Cleared the moment CYC drops; the response is still drained (AXI4
    // requires it) but no longer acked upstream.
    final pendingLive = Logic(name: 'pending_live');
    final ackReg = Logic(name: 's_ack_reg');
    final errReg = Logic(name: 's_err_reg');
    final datReg = Logic(name: 's_dat_reg', width: wb.config.dataWidth);

    final idle = ~arValidReg & ~rWaitReg & ~awValidReg & ~wValidReg & ~bWaitReg;
    final busy = ~idle;
    // The master still holds CYC/STB on the cycle it sees the ack. Do not
    // take that as a new request.
    final issue = idle & ~ackReg & ~errReg;

    // Payload is latched at issue and held while VALID is high, so an
    // aborted request still completes with what was issued.
    final adrReg = Logic(name: 'adr_reg', width: wb.config.addressWidth);
    final wdatReg = Logic(name: 'wdat_reg', width: wb.config.dataWidth);
    final selReg = Logic(name: 'sel_reg', width: wb.sel.width);

    final rErr = axiRead.rIntf.resp != null
        ? axiRead.rIntf.resp!.or()
        : Const(0);
    final bErr = axiWrite.bIntf.resp != null
        ? axiWrite.bIntf.resp!.or()
        : Const(0);

    final awSettled = (awValidReg & axiWrite.awIntf.ready) | ~awValidReg;
    final wSettled = (wValidReg & axiWrite.wIntf.ready) | ~wValidReg;
    final writeAddrDataDone = awSettled & wSettled & (awValidReg | wValidReg);

    final rFire = rWaitReg & axiRead.rIntf.valid;
    final bFire = bWaitReg & axiWrite.bIntf.valid;

    Sequential(clkIn, reset: resetIn, [
      ackReg < Const(0),
      errReg < Const(0),

      If(
        issue & (isRead | isWrite),
        then: [
          adrReg < wb.adr,
          wdatReg < wb.datMosi,
          selReg < wb.sel,
          pendingLive < Const(1),
        ],
      ),
      If(issue & isRead, then: [arValidReg < Const(1)]),
      If(issue & isWrite, then: [awValidReg < Const(1), wValidReg < Const(1)]),

      // Orphan rule: an abort mid-flight only stops the ack, never the
      // AXI4 handshake, which must still be seen through to completion.
      If(busy & ~wb.cyc, then: [pendingLive < Const(0)]),

      If(
        arValidReg & axiRead.arIntf.ready,
        then: [arValidReg < Const(0), rWaitReg < Const(1)],
      ),
      If(awValidReg & axiWrite.awIntf.ready, then: [awValidReg < Const(0)]),
      If(wValidReg & axiWrite.wIntf.ready, then: [wValidReg < Const(0)]),
      If(writeAddrDataDone, then: [bWaitReg < Const(1)]),

      If(
        rFire,
        then: [
          rWaitReg < Const(0),
          If(
            pendingLive & wb.cyc,
            then: [
              If(
                rErr,
                then: [errReg < Const(1)],
                orElse: [
                  ackReg < Const(1),
                  datReg < axiRead.rIntf.data.getRange(0, wb.config.dataWidth),
                ],
              ),
            ],
          ),
        ],
      ),
      If(
        bFire,
        then: [
          bWaitReg < Const(0),
          If(
            pendingLive & wb.cyc,
            then: [
              If(bErr, then: [errReg < Const(1)], orElse: [ackReg < Const(1)]),
            ],
          ),
        ],
      ),
    ]);

    // Wishbone -> AXI4 Read (AR channel). Issued once per cycle and held
    // until accepted, not re-pulsed every cycle CYC & STB are asserted.
    axiRead.arIntf.valid <= arValidReg;
    axiRead.arIntf.addr <= adrReg.zeroExtend(axiRead.arIntf.addrWidth);
    axiRead.arIntf.prot <= Const(0, width: 3);
    if (axiRead.arIntf.id != null) {
      axiRead.arIntf.id! <= Const(0, width: axiRead.arIntf.idWidth);
    }
    if (axiRead.arIntf.len != null) {
      axiRead.arIntf.len! <=
          Const(0, width: axiRead.arIntf.lenWidth); // single beat
    }
    if (axiRead.arIntf.size != null) {
      axiRead.arIntf.size! <= axiSizeFromSel(selReg, 3);
    }
    if (axiRead.arIntf.burst != null) {
      axiRead.arIntf.burst! <= Const(1, width: 2); // INCR
    }

    // AXI4 Read -> Wishbone (R channel). Only ready while actually waiting.
    axiRead.rIntf.ready <= rWaitReg;

    // Wishbone -> AXI4 Write (AW + W channels), each held until accepted.
    axiWrite.awIntf.valid <= awValidReg;
    axiWrite.awIntf.addr <= adrReg.zeroExtend(axiWrite.awIntf.addrWidth);
    axiWrite.awIntf.prot <= Const(0, width: 3);
    if (axiWrite.awIntf.id != null) {
      axiWrite.awIntf.id! <= Const(0, width: axiWrite.awIntf.idWidth);
    }
    if (axiWrite.awIntf.len != null) {
      axiWrite.awIntf.len! <= Const(0, width: axiWrite.awIntf.lenWidth);
    }
    if (axiWrite.awIntf.size != null) {
      axiWrite.awIntf.size! <= axiSizeFromSel(selReg, 3);
    }
    if (axiWrite.awIntf.burst != null) {
      axiWrite.awIntf.burst! <= Const(1, width: 2);
    }

    axiWrite.wIntf.data <= wdatReg.zeroExtend(axiWrite.wIntf.dataWidth);
    axiWrite.wIntf.strb <= selReg.zeroExtend(axiWrite.wIntf.strbWidth);
    if (axiWrite.wIntf.last != null) {
      axiWrite.wIntf.last! <= Const(1);
    }
    axiWrite.wIntf.valid <= wValidReg;

    // AXI4 Write -> Wishbone (B channel). Only ready while actually waiting.
    axiWrite.bIntf.ready <= bWaitReg;

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
