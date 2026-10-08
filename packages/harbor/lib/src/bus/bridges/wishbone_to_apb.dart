import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' show ApbInterface;

import '../wishbone/wishbone_interface.dart';

/// Bridges a Wishbone master to an APB slave.
///
/// Converts Wishbone transactions to APB protocol with proper
/// setup/access phase timing. APB is commonly used for slow
/// peripherals (UART, SPI, GPIO, timers).
class WishboneToApbBridge extends Module {
  WishboneToApbBridge(
    WishboneInterface wb,
    ApbInterface apb, {
    super.name = 'wb2apb',
  }) : super(definitionName: 'WishboneToApbBridge') {
    final clk = addInput('clk', apb.clk);
    final reset = addInput('reset_n', apb.resetN);

    // APB state machine
    final apbPhase = Logic(name: 'apb_phase'); // 0=setup, 1=access

    // Wishbone -> APB
    apb.addr <= wb.adr.zeroExtend(apb.addrWidth);
    apb.write <= wb.we;
    apb.wData <= wb.datMosi.zeroExtend(apb.dataWidth);
    apb.strb <= wb.sel.zeroExtend(apb.dataWidth ~/ 8);
    apb.prot <= Const(0, width: 3);
    apb.nse <= Const(0);

    // Select is asserted during both setup and access phases
    if (apb.sel.isNotEmpty) {
      apb.sel[0] <= wb.cyc & wb.stb;
    }

    // Enable is only asserted during access phase
    apb.enable <= wb.cyc & wb.stb & apbPhase;

    // APB -> Wishbone. ACK and ERR are mutually exclusive, both gated by
    // PREADY & the access phase and by CYC & STB so a stray pulse can
    // never land on an unrelated later cycle. ERR ties low when the APB
    // side has no PSLVERR at all.
    final slvErr = apb.slvErr;
    final errCond = slvErr != null ? (apb.ready & apbPhase & slvErr) : Const(0);
    final ackCond = slvErr != null
        ? (apb.ready & apbPhase & ~slvErr)
        : (apb.ready & apbPhase);

    wb.ack <= ackCond & wb.cyc & wb.stb;
    wb.datMiso <= apb.rData.getRange(0, wb.config.dataWidth);

    if (wb.err != null) {
      wb.err! <= errCond & wb.cyc & wb.stb;
    }

    // Phase tracking: setup -> access on first cycle, hold during transfer.
    // A dropped CYC clears the phase immediately so a later, unrelated
    // transaction never inherits a stuck access phase.
    Sequential(clk, [
      If(
        ~reset,
        then: [apbPhase < Const(0)],
        orElse: [
          If(
            ~wb.cyc,
            then: [apbPhase < Const(0)],
            orElse: [
              If(
                wb.cyc & wb.stb & ~apbPhase,
                then: [
                  apbPhase < Const(1), // setup -> access
                ],
              ),
              If(
                apb.ready & apbPhase,
                then: [
                  apbPhase < Const(0), // complete, back to idle
                ],
              ),
            ],
          ),
        ],
      ),
    ]);
  }
}
