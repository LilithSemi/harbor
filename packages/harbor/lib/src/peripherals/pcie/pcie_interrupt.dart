import 'package:rohd/rohd.dart';

/// Drives the 7-series PCIe cfg_interrupt handshake from eight level inputs.
///
/// With MSI on, each rising edge of a pending bit sends one MSI. A bit at or
/// above the granted vector count goes out as vector 0. With MSI off, INTA
/// stays asserted while any bit is set.
class HarborPcieInterrupt extends Module {
  Logic get interruptN => output('interrupt_n');
  Logic get interruptDi => output('interrupt_di');
  Logic get interruptAssertN => output('interrupt_assert_n');

  HarborPcieInterrupt({
    required Logic clk,
    required Logic reset,
    required Logic irqPending,
    required Logic txBusy,
    required Logic msiEnable,
    required Logic mmEnable,
    required Logic busMasterEnable,
    required Logic interruptDisable,
    required Logic interruptRdyN,
    super.name = 'pcie_interrupt',
  }) : super(definitionName: 'HarborPcieInterrupt') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    irqPending = addInput('irq_pending', irqPending, width: 8);
    txBusy = addInput('tx_busy', txBusy);
    msiEnable = addInput('msi_enable', msiEnable);
    mmEnable = addInput('mm_enable', mmEnable, width: 3);
    busMasterEnable = addInput('bus_master_enable', busMasterEnable);
    interruptDisable = addInput('interrupt_disable', interruptDisable);
    interruptRdyN = addInput('interrupt_rdy_n', interruptRdyN);

    final previous = Logic(name: 'previous', width: 8);
    final latched = Logic(name: 'latched', width: 8);
    final active = Logic(name: 'active');
    final activeMsi = Logic(name: 'active_msi');
    final vector = Logic(name: 'vector', width: 8);
    final assertMessage = Logic(name: 'assert_message');
    final intxAsserted = Logic(name: 'intx_asserted');

    final grantedMask = mux(
      mmEnable.eq(0),
      Const(0x01, width: 8),
      mux(
        mmEnable.eq(1),
        Const(0x03, width: 8),
        mux(mmEnable.eq(2), Const(0x0f, width: 8), Const(0xff, width: 8)),
      ),
    ).named('granted_mask');
    final lowest = (latched & (~latched + 1)).named('lowest');
    final lowestInRange = (lowest & grantedMask & Const(0xfe, width: 8)).or();
    final lowestIndex = [
      for (var bit = 2; bit >= 0; bit--)
        [
          for (var i = 0; i < 8; i++)
            if (i & (1 << bit) != 0) lowest[i],
        ].swizzle().or(),
    ].swizzle().named('lowest_index');
    final msiVector = mux(
      lowestInRange,
      lowestIndex.zeroExtend(8),
      Const(0, width: 8),
    );
    final msiClear = mux(
      lowestInRange,
      lowest,
      latched & (~grantedMask | Const(0x01, width: 8)),
    );

    final accepted = (active & ~interruptRdyN).named('accepted');
    final level = irqPending.or().named('level');
    final startMsi =
        (~active & msiEnable & busMasterEnable & ~txBusy & latched.or()).named(
          'start_msi',
        );
    final startAssert =
        (~active &
                ~msiEnable &
                ~interruptDisable &
                ~txBusy &
                level &
                ~intxAsserted)
            .named('start_assert');
    final startDeassert =
        (~active & ~msiEnable & intxAsserted & (~level | interruptDisable))
            .named('start_deassert');
    final edges = (irqPending & ~previous).named('edges');
    // Bits leave the latch when their request starts, so an edge that comes
    // while the request is held starts a new MSI.
    final taken = mux(startMsi, latched & ~msiClear, latched);

    Sequential(clk, [
      If(
        reset,
        then: [
          previous < 0,
          latched < 0,
          active < 0,
          activeMsi < 0,
          vector < 0,
          assertMessage < 0,
          intxAsserted < 0,
        ],
        orElse: [
          If(
            msiEnable,
            then: [previous < irqPending, latched < (taken | edges)],
            orElse: [previous < 0, latched < 0],
          ),
          If.block([
            Iff(accepted, [
              active < 0,
              If(~activeMsi, then: [intxAsserted < assertMessage]),
            ]),
            ElseIf(startMsi, [
              active < 1,
              activeMsi < 1,
              vector < msiVector,
              assertMessage < 0,
            ]),
            ElseIf(startAssert | startDeassert, [
              active < 1,
              activeMsi < 0,
              vector < 0,
              assertMessage < startAssert,
            ]),
            // With MSI on, cfg_interrupt sends an MSI, so no Deassert_INTA
            // can go out. Drivers set Interrupt Disable before MSI Enable.
            ElseIf(~active & msiEnable, [intxAsserted < 0]),
          ]),
        ],
      ),
    ]);

    addOutput('interrupt_n') <= ~active;
    addOutput('interrupt_di', width: 8) <= vector;
    addOutput('interrupt_assert_n') <= ~assertMessage;
  }
}
