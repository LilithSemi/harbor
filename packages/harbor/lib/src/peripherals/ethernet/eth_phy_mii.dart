import 'package:rohd/rohd.dart';

import '../../clock/cdc.dart';
import 'eth_byte_stream.dart';
import 'eth_constraint.dart';
import 'eth_phy_rx_stage.dart';

/// MII front end for the Ethernet MAC cores.
///
/// [speed] is not used. The PHY clock sets the rate. The port is there so
/// that all front ends have the same ports.
///
/// Both clocks come from the PHY and run at 25 MHz or 2.5 MHz. The byte
/// stream has one strobe on every second clock. The low nibble goes first.
/// Each domain gets its reset from [reset], released in step with its clock.
///
/// A preamble that lost a nibble still works. The first `0xD` nibble after
/// the `0x5` nibbles is the top nibble of the SFD, and sets the alignment.
///
/// The receive side drops a last half byte and sets `rx_er` on the last
/// whole byte. CRS and COL are only for half duplex, which this front end
/// does not support, so it ignores them.
class HarborEthPhyMii extends Module {
  /// Transmit data pins.
  Logic get txd => output('mii_txd');

  /// Transmit enable pin.
  Logic get txEn => output('mii_tx_en');

  /// Transmit error pin.
  Logic get txEr => output('mii_tx_er');

  HarborEthPhyMii(
    HarborEthByteStream stream, {
    required Logic reset,
    required Logic speed,
    required Logic miiTxClk,
    required Logic miiRxClk,
    required Logic miiRxd,
    required Logic miiRxDv,
    required Logic miiRxEr,
    required Logic miiCrs,
    required Logic miiCol,
    super.name = 'eth_phy_mii',
  }) : super(definitionName: 'HarborEthPhyMii') {
    final s = HarborEthByteStream()
      ..pairConnectIO(this, stream, PairRole.provider);
    reset = addInput('reset', reset);
    addInput('speed', speed, width: 2);
    final txClk = addInput('mii_tx_clk', miiTxClk);
    final rxClk = addInput('mii_rx_clk', miiRxClk);
    final rxd = addInput('mii_rxd', miiRxd, width: 4);
    final rxDv = addInput('mii_rx_dv', miiRxDv);
    final rxEr = addInput('mii_rx_er', miiRxEr);
    addInput('mii_crs', miiCrs);
    addInput('mii_col', miiCol);

    final txd = addOutput('mii_txd', width: 4);
    final txEn = addOutput('mii_tx_en');
    final txEr = addOutput('mii_tx_er');

    final txReset = harborCdcJoinReset(txClk, reset, Const(0), name: 'tx_rst');
    final rxReset = harborCdcJoinReset(rxClk, reset, Const(0), name: 'rx_rst');
    s.txClk <= txClk;
    s.txReset <= txReset;
    s.rxClk <= rxClk;
    s.rxReset <= rxReset;

    final phase = Logic(name: 'tx_phase');
    Sequential(txClk, [phase < ~phase], reset: txReset);
    s.txStrobe <= phase;

    final txdR = Logic(name: 'txd_r', width: 4);
    final txEnR = Logic(name: 'tx_en_r');
    final txErR = Logic(name: 'tx_er_r');
    Sequential(txClk, [
      txdR < mux(phase, s.txData.slice(7, 4), s.txData.slice(3, 0)),
      txEnR < s.txEn,
      txErR < s.txEr,
    ], reset: txReset);
    txd <= txdR;
    txEn <= txEnR;
    txEr <= txErR;

    final out = harborEthPhyNibbleRx(
      rxClk,
      rxReset,
      rxd: rxd,
      rxDv: rxDv,
      rxEr: rxEr,
    );
    s.rxData <= out.data;
    s.rxDv <= out.dv;
    s.rxEr <= out.er;
    s.rxStrobe <= out.strobe;
  }

  /// Timing constraints of the MII pins at 100 Mbps.
  ///
  /// [topPort] gives the top-level name of a front end pin. The clock names are
  /// the top-level names of `mii_tx_clk` and `mii_rx_clk`. The values come from
  /// IEEE 802.3 clauses 22.3.1 and 22.3.2. TX_EN, TXD and TX_ER change 0 to 25
  /// ns after TX_CLK rises at the PHY, so the output delay is 40 - 25 = 15 ns
  /// max and 0 ns min. RXD, RX_DV and RX_ER have 10 ns setup and 10 ns hold at
  /// the MAC, so the input delay is 40 - 10 = 30 ns max and 10 ns min. The 2.5
  /// MHz clocks of 10 Mbps have more margin.
  static List<HarborEthClockConstraint> constraints({
    String Function(String pin)? topPort,
  }) {
    final p = topPort ?? (String n) => n;
    final txClk = p('mii_tx_clk');
    final rxClk = p('mii_rx_clk');
    return [
      for (final c in [txClk, rxClk])
        HarborEthClockConstraint(
          kind: HarborEthClockConstraintKind.clock,
          clock: c,
          ports: [c],
          periodNs: 40.0,
        ),
      HarborEthClockConstraint(
        kind: HarborEthClockConstraintKind.outputDelay,
        clock: txClk,
        ports: ['${p('mii_txd')}[*]', p('mii_tx_en'), p('mii_tx_er')],
        maxNs: 15.0,
        minNs: 0.0,
      ),
      HarborEthClockConstraint(
        kind: HarborEthClockConstraintKind.inputDelay,
        clock: rxClk,
        ports: ['${p('mii_rxd')}[*]', p('mii_rx_dv'), p('mii_rx_er')],
        maxNs: 30.0,
        minNs: 10.0,
      ),
    ];
  }
}
