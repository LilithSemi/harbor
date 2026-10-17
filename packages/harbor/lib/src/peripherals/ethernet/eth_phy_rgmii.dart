import 'package:rohd/rohd.dart';

import '../../blackbox/ecp5/ecp5.dart';
import '../../blackbox/xilinx/xilinx.dart';
import '../../clock/cdc.dart';
import '../../soc/target.dart';
import '../../video/ddr_output.dart';
import 'eth_byte_stream.dart';
import 'eth_config.dart';
import 'eth_constraint.dart';
import 'eth_phy_rx_stage.dart';

/// RGMII front end for the Ethernet MAC cores, for 10, 100 and 1000 Mbps.
///
/// Transmit runs on [clk125]. The byte stream TX clock is [clk125] at all
/// speeds, and `tx_strobe` gives the byte rate: on each clock at 1000 Mbps,
/// on 1 of 10 clocks at 100 Mbps and on 1 of 100 clocks at 10 Mbps. At 1000
/// Mbps a DDR output register sends the low nibble on the rising edge and the
/// high nibble on the falling edge. At 10 and 100 Mbps each nibble stays on
/// the pins for 5 or 50 clocks, and the TX clock of 25 or 2.5 MHz is a
/// pattern that the DDR output register of `rgmii_txc` sends, so no other
/// clock net is necessary. The rising edge of that clock is 8 ns or 80 ns
/// after the nibble starts, and the falling edge is in the second half.
///
/// `tx_ctl` sends `tx_en` on the rising edge and `tx_en ^ tx_er` on the
/// falling edge. When [HarborEthernetConfig.txClockShift] is true, the
/// `rgmii_txc` register runs on [clk125_90], so the clock is 2 ns after the
/// data. When it is false, the clock has the phase of the data and the PHY
/// must add the delay. The KSZ9031 can do this with its pad skew registers.
/// With the shift, the `rgmii_txc` pattern goes from [clk125] flops to
/// [clk125_90] flops. [constraints] gives that path 2 clocks of setup, so
/// the shifted flops can take the pattern 2 ns or 10 ns after it changes.
/// The pattern holds at 1000 Mbps, and at 10 and 100 Mbps the extra clock
/// moves the TX clock edges 8 ns later, which keeps 2 ns or more of margin
/// to each change of the data and `tx_ctl`.
///
/// Receive runs on the buffered `rgmii_rxc` at 125, 25 or 2.5 MHz. On Xilinx
/// a BUFIO clocks the IDDRs and a BUFR clocks the receive domain, so the
/// RX pins must be in the I/O bank of `rgmii_rxc` and the receive logic in
/// its clock region. A BUFG puts about 4 ns of clock delay on an XC7A200T,
/// which the RGMII data window cannot take. At 1000 Mbps
/// one byte comes on each clock, the low nibble on the rising edge, and
/// `rx_strobe` stays high. At 10 and 100 Mbps one nibble comes on each clock
/// and a byte strobe comes on every second clock. The first `0xD` nibble of
/// the SFD sets the byte alignment. `rx_ctl` gives `rx_dv` on the rising edge
/// and `rx_dv ^ rx_er` on the falling edge.
///
/// [HarborEthernetConfig.rgmiiRxDelayTaps] above 0 puts a fixed delay line on
/// the RX data and control. On Xilinx this is an IDELAYE2 with taps of 78 ps
/// at a 200 MHz reference. On ECP5 it is a DELAYG with taps of about 25 ps.
/// A simulation target has no delay line and does not accept taps.
/// [HarborEthernetConfig.rgmiiPhyRxDelay] tells if the PHY adds the RX clock
/// delay, and selects the input delay constraints. Both can be on. The
/// KSZ9031 adds 1.2 ns by default.
///
/// Xilinx IDELAYE2 cells need an IDELAYCTRL. With [idelayCtrl] true the
/// front end builds one on [clk200]. The XilinxIdelayctrl class cannot set
/// the IODELAY_GROUP attribute, so two ungrouped IDELAYCTRL cells in one
/// design (for example this one and the DDR3 PHY one) are left to Vivado to
/// merge. To share the DDR3 PHY IDELAYCTRL instead, set [idelayCtrl] false.
/// That IDELAYCTRL must then use a 200 MHz reference.
///
/// [speed] is 2 for 1000 Mbps, 1 for 100 Mbps and 0 for 10 Mbps. Change it
/// only while the transmitter and the receiver are stopped. Each clock
/// domain uses a synchronized speed only after it holds for 2 clocks, so a
/// change that the synchronizer takes bit by bit cannot give a wrong speed.
/// The TX side takes a new speed only at a byte boundary, so the TX clock
/// gets no short pulse. The MAC strobe is one clock after the front end
/// strobe, so a speed change in a frame sends one byte twice or skips one.
/// Change the speed only while TX is stopped.
class HarborEthPhyRgmii extends Module {
  /// Configuration of the MAC that contains this front end.
  final HarborEthernetConfig config;

  /// Device the front end is built for.
  final HarborDeviceTarget target;

  /// Transmit clock pin.
  Logic get txc => output('rgmii_txc');

  /// Transmit data pins.
  Logic get txd => output('rgmii_txd');

  /// Transmit control pin.
  Logic get txCtl => output('rgmii_tx_ctl');

  static const _txcOddrName = 'txc_oddr';
  static const _rxBufrName = 'rx_bufr';

  HarborEthPhyRgmii(
    HarborEthByteStream stream, {
    required this.config,
    required this.target,
    required Logic reset,
    required Logic speed,
    required Logic clk125,
    required Logic clk125_90,
    required Logic rgmiiRxc,
    required Logic rgmiiRxd,
    required Logic rgmiiRxCtl,
    Logic? clk200,
    bool idelayCtrl = true,
    super.name = 'eth_phy_rgmii',
  }) : super(
         definitionName:
             'HarborEthPhyRgmii_${_vendorTag(target)}'
             '_s${config.txClockShift ? 1 : 0}'
             '_d${config.rgmiiRxDelayTaps}'
             '${config.rgmiiRxDelayTaps > 0 && idelayCtrl ? '_c' : ''}',
       ) {
    final vendor = _vendorOf(target);
    final taps = config.rgmiiRxDelayTaps;
    if (taps > 0) {
      if (vendor == _Vendor.xilinx && taps > 31) {
        throw ArgumentError.value(
          taps,
          'rgmiiRxDelayTaps',
          'IDELAYE2 has 0 to 31 taps',
        );
      }
      if (vendor == _Vendor.ecp5 && taps > 127) {
        throw ArgumentError.value(
          taps,
          'rgmiiRxDelayTaps',
          'DELAYG has 0 to 127 taps',
        );
      }
      if (vendor == _Vendor.sim) {
        throw ArgumentError.value(
          taps,
          'rgmiiRxDelayTaps',
          'a simulation target has no input delay line',
        );
      }
      if (vendor == _Vendor.xilinx && idelayCtrl && clk200 == null) {
        throw ArgumentError.notNull('clk200');
      }
    }

    final s = HarborEthByteStream()
      ..pairConnectIO(this, stream, PairRole.provider);
    reset = addInput('reset', reset);
    speed = addInput('speed', speed, width: 2);
    final tclk = addInput('clk125', clk125);
    final tclk90 = addInput('clk125_90', clk125_90);
    final rxcPin = addInput('rgmii_rxc', rgmiiRxc);
    final rxdPin = addInput('rgmii_rxd', rgmiiRxd, width: 4);
    final rxCtlPin = addInput('rgmii_rx_ctl', rgmiiRxCtl);
    final refClk = (vendor == _Vendor.xilinx && taps > 0 && idelayCtrl)
        ? addInput('clk200', clk200!)
        : null;

    final txcOut = addOutput('rgmii_txc');
    final txdOut = addOutput('rgmii_txd', width: 4);
    final txCtlOut = addOutput('rgmii_tx_ctl');

    // Transmit.
    final tRst = harborCdcJoinReset(tclk, reset, Const(0), name: 'tx_rst');
    s.txClk <= tclk;
    s.txReset <= tRst;

    final tSpeed = _speedSync(speed, tclk, tRst, 2, 'tx');

    // The speed decode, the end of a nibble and the strobe are flops that
    // look one clock ahead. [atLim] is high on the clock where [div] is at
    // its limit. [strobe] is high when `fast | (atLim & nib)`.
    final fast = Logic(name: 'tx_fast');
    final mid = Logic(name: 'tx_mid');
    final div = Logic(name: 'tx_div', width: 6);
    final nib = Logic(name: 'tx_nib');
    final atLim = Logic(name: 'tx_at_lim');
    final strobe = Logic(name: 'tx_strobe_r');
    final lim = mux(mid, Const(4, width: 6), Const(49, width: 6));
    final step = (fast | atLim).named('tx_step');
    final atLimNext = (~step & (div + 1).eq(lim)).named('tx_at_lim_next');
    final fastNext = mux(strobe, tSpeed.eq(2), fast).named('tx_fast_next');
    final byteR = Logic(name: 'tx_byte', width: 8);
    final enR = Logic(name: 'tx_en_r');
    final erR = Logic(name: 'tx_er_r');
    Sequential(
      tclk,
      [
        If(
          step,
          then: [div < 0, nib < mux(fast, Const(0), ~nib)],
          orElse: [div < div + 1],
        ),
        atLim < atLimNext,
        // While atLimNext is high, step is low, so nib keeps its value.
        strobe < fastNext | (atLimNext & nib),
        fast < fastNext,
        If(
          strobe,
          then: [
            mid < tSpeed.eq(1),
            byteR < s.txData,
            enR < s.txEn,
            erR < s.txEr,
          ],
        ),
      ],
      reset: tRst,
      // Start at 1000 Mbps, so the first strobe loads the speed at once.
      resetValues: {fast: Const(1), strobe: Const(1)},
    );
    // The MAC gets its own copy of the strobe, one clock late, so the MAC
    // and the TX FIFO can be far from the pins. The front end takes a byte
    // only on its own strobe, so the MAC sees each byte slot once and the
    // byte order does not change.
    final strobeMac = Logic(name: 'tx_strobe_mac');
    Sequential(
      tclk,
      [strobeMac < strobe],
      reset: tRst,
      resetValues: {strobeMac: Const(1)},
    );
    s.txStrobe <= strobeMac;

    // Half clock index in the nibble: 2 * div on the rise, one more on the
    // fall. The clock is high from half [hi] to half [lo], and the control
    // pin changes to `en ^ er` at half [sw].
    final hRise = [div, Const(0)].swizzle().named('tx_h_rise');
    final hFall = [div, Const(1)].swizzle().named('tx_h_fall');
    final hi = mux(mid, Const(2, width: 7), Const(20, width: 7));
    final lo = mux(mid, Const(7, width: 7), Const(70, width: 7));
    final sw = mux(mid, Const(5, width: 7), Const(50, width: 7));
    final enEr = (enR ^ erR).named('tx_en_er');
    final nibble = mux(nib, byteR.slice(7, 4), byteR.slice(3, 0));

    final dD1 = Logic(name: 'txd_d1', width: 4);
    final dD2 = Logic(name: 'txd_d2', width: 4);
    final cD1 = Logic(name: 'ctl_d1');
    final cD2 = Logic(name: 'ctl_d2');
    final kD1 = Logic(name: _txcD1);
    final kD2 = Logic(name: _txcD2);
    Sequential(tclk, [
      dD1 < mux(fast, byteR.slice(3, 0), nibble),
      dD2 < mux(fast, byteR.slice(7, 4), nibble),
      cD1 < mux(fast | hRise.lt(sw), enR, enEr),
      cD2 < mux(~fast & hFall.lt(sw), enR, enEr),
      kD1 < (fast | (hRise.gte(hi) & hRise.lt(lo))),
      kD2 < (~fast & hFall.gte(hi) & hFall.lt(lo)),
    ], reset: tRst);

    Logic oddr(Logic clk, Logic rst, Logic d1, Logic d2, String n) =>
        switch (vendor) {
          _Vendor.xilinx => XilinxOddr(c: clk, d1: d1, d2: d2, name: n).q,
          _Vendor.ecp5 => Ecp5Oddrx1f(
            sclk: clk,
            rst: Const(0),
            d0: d1,
            d1: d2,
            name: n,
          ).q,
          _Vendor.sim => HarborDdrOutput(
            clk: clk,
            reset: rst,
            d0: d1,
            d1: d2,
            name: n,
          ).q,
        };

    txdOut <=
        [
          for (var i = 0; i < 4; i++)
            oddr(tclk, tRst, dD1[i], dD2[i], 'txd_oddr_$i'),
        ].rswizzle();
    txCtlOut <= oddr(tclk, tRst, cD1, cD2, 'tx_ctl_oddr');
    if (config.txClockShift) {
      // One register on the shifted clock, so the ODDR inputs come from
      // flops of its own clock. It takes the value 2 ns after the data
      // registers, so the clock stays in step with the data.
      final rst90 = harborCdcJoinReset(
        tclk90,
        reset,
        Const(0),
        name: 'tx90_rst',
      );
      final kS1 = Logic(name: _txcS1);
      final kS2 = Logic(name: _txcS2);
      Sequential(tclk90, [kS1 < kD1, kS2 < kD2], reset: rst90);
      txcOut <= oddr(tclk90, rst90, kS1, kS2, _txcOddrName);
    } else {
      txcOut <= oddr(tclk, tRst, kD1, kD2, _txcOddrName);
    }

    // Receive. On Xilinx the IDDRs take the BUFIO clock and the rest of the
    // receive domain the BUFR clock.
    final rclk = switch (vendor) {
      _Vendor.xilinx => XilinxBufr(i: rxcPin, name: _rxBufrName).o,
      _ => rxcPin,
    }.named('rx_clk_buf');
    final ioClk = switch (vendor) {
      _Vendor.xilinx => XilinxBufio(i: rxcPin, name: 'rx_bufio').o,
      _ => rclk,
    }.named('rx_io_clk');
    final rRst = harborCdcJoinReset(rclk, reset, Const(0), name: 'rx_rst');
    s.rxClk <= rclk;
    s.rxReset <= rRst;

    if (refClk != null) {
      XilinxIdelayctrl(refclk: refClk, rst: reset, name: 'rx_idelayctrl');
    }

    Logic delay(Logic pin, String n) {
      if (taps == 0) return pin;
      return switch (vendor) {
        _Vendor.xilinx => XilinxIdelaye2(
          idatain: pin,
          idelayValue: taps,
          name: n,
        ).dataout,
        _Vendor.ecp5 => Ecp5Delayg(a: pin, delValue: taps, name: n).z,
        _Vendor.sim => pin,
      };
    }

    // Each pair is the rise and the fall after it. The Xilinx IDDR in
    // SAME_EDGE mode gives Q1 from this rise and Q2 from the fall before it,
    // so Q1 waits one clock. The ECP5 IDDRX1F gives an aligned pair.
    (Logic, Logic) iddr(Logic pin, String n) {
      final d = delay(pin, '${n}_idelay');
      final (q1, q2) = switch (vendor) {
        _Vendor.xilinx => () {
          final c = XilinxIddr(c: ioClk, d: d, name: '${n}_iddr');
          return (c.q1, c.q2);
        }(),
        _Vendor.ecp5 => () {
          final c = Ecp5Iddrx1f(
            sclk: rclk,
            rst: Const(0),
            d: d,
            name: '${n}_iddr',
          );
          return (c.q0, c.q1);
        }(),
        _Vendor.sim => _ddrIn(rclk, d, n),
      };
      if (vendor == _Vendor.ecp5) return (q1, q2);
      final rise = Logic(name: '${n}_rise');
      Sequential(rclk, [rise < q1]);
      return (rise, q2);
    }

    final rx = [for (var i = 0; i < 4; i++) iddr(rxdPin[i], 'rxd_$i')];
    final rxR = rx.map((e) => e.$1).toList().rswizzle().named('rx_r');
    final rxF = rx.map((e) => e.$2).toList().rswizzle().named('rx_f');
    final (ctlR, ctlF) = iddr(rxCtlPin, 'rx_ctl');
    final dv = ctlR.named('rx_dv_pin');
    final er = (ctlR ^ ctlF).named('rx_er_pin');

    // The speed decode is a flop. The speed changes only while RX is
    // stopped, so one more clock of delay has no effect.
    final rFast = Logic(name: 'rx_fast');
    Sequential(rclk, [
      rFast < _speedSync(speed, rclk, rRst, 0, 'rx').eq(2),
    ], reset: rRst);

    final gData = Logic(name: 'rx_g_data', width: 8);
    final gDv = Logic(name: 'rx_g_dv');
    final gEr = Logic(name: 'rx_g_er');
    Sequential(rclk, [
      gData < [rxF, rxR].swizzle(),
      gDv < dv & rFast,
      gEr < er & rFast,
    ], reset: rRst);

    final slow = harborEthPhyNibbleRx(
      rclk,
      rRst,
      rxd: rxR,
      rxDv: dv,
      rxEr: er,
      enable: ~rFast,
    );
    s.rxData <= mux(rFast, gData, slow.data);
    s.rxDv <= mux(rFast, gDv, slow.dv);
    s.rxEr <= mux(rFast, gEr, slow.er);
    s.rxStrobe <= mux(rFast, Const(1), slow.strobe);
  }

  /// Timing constraints of the RGMII pins at 1000 Mbps.
  ///
  /// [topPort] gives the top-level name of a front end pin. The clock names
  /// are the top-level names of `rgmii_rxc` and `rgmii_txc`, so two front
  /// ends in one design have different clocks. [instance] is a name in the
  /// hierarchical path of this front end, such as the MAC instance. It
  /// selects the TX clock source pin when the design has more than one front
  /// end. The values come
  /// from the RGMII v2.0 table in the KSZ9031RNX datasheet (Microchip
  /// DS00002117F, Table 7-1, page 58):
  ///
  /// - RX with [HarborEthernetConfig.rgmiiPhyRxDelay]: TsetupT and TholdT
  ///   are 1.2 ns min at the 1.2 ns default delay. For phy-mode
  ///   `rgmii-rxid` and `rgmii-id`, the Linux micrel driver
  ///   (`ksz9031_config_rgmii_delay`) sets the RX_CLK pad skew to +0.60 ns
  ///   (Table 3-5) and leaves the RX data, so the clock is 1.8 ns after the
  ///   data. Setup is then 1.8 ns min and hold 0.6 ns min, so the input
  ///   delay is 4.0 - 1.8 = 2.2 ns max and 0.6 ns min.
  /// - RX with [HarborEthernetConfig.rgmiiRxSetupNs] and
  ///   [HarborEthernetConfig.rgmiiRxHoldNs]: 4.0 - setup max and hold min.
  ///   These win over the two cases above and below.
  /// - RX without it: TskewT is -0.5 to 0.5 ns, so 0.5 max and -0.5 min.
  ///   For phy-mode `rgmii` the Linux driver sets RX_CLK -0.90 ns and RX data
  ///   +0.30 ns, which cancels the 1.2 ns default delay.
  /// - TX with [HarborEthernetConfig.txClockShift]: TsetupR and TholdR are
  ///   1.0 ns min, so the output delay is 1.0 ns max and -1.0 ns min.
  /// - TX without it: data changes at most 0.5 ns (TskewT) from a clock
  ///   edge. The setup check is against the next edge, 4.0 ns later, so the
  ///   output delay is 4.0 - 0.5 = 3.5 ns max. The hold check is against the
  ///   same edge, so it is 0.5 ns min.
  ///
  /// On Xilinx the list has a generated clock `<rxc>_bufr` on the BUFR
  /// output that clocks the receive domain. The IDDRs take the `rgmii_rxc`
  /// clock through the BUFIO.
  ///
  /// With the TX clock shift, the list also has a multicycle path of setup
  /// 2 and hold 1 from the `rgmii_txc` pattern flops on `clk125` to the
  /// flops on `clk125_90`.
  ///
  /// The LiteEth 7-series RGMII PHY (liteeth/phy/parallel/rgmii/s7.py) uses
  /// 2 ns for its TX clock phase and its RX IDELAY, which agrees. All values
  /// are for each edge, with no PCB skew.
  List<HarborEthClockConstraint> constraints({
    String Function(String pin)? topPort,
    String? instance,
  }) {
    final p = topPort ?? (String n) => n;
    final rxClk = p('rgmii_rxc');
    final txClk = p('rgmii_txc');
    final rxPorts = ['${p('rgmii_rxd')}[*]', p('rgmii_rx_ctl')];
    final txPorts = ['${p('rgmii_txd')}[*]', p('rgmii_tx_ctl')];
    final rxDelay = config.rgmiiPhyRxDelay;
    final setup = config.rgmiiRxSetupNs;
    final hold = config.rgmiiRxHoldNs;
    final (rxMax, rxMin) = setup != null && hold != null
        ? (4.0 - setup, hold)
        : (rxDelay ? (2.2, 0.6) : (0.5, -0.5));
    final (txMax, txMin) = config.txClockShift ? (1.0, -1.0) : (3.5, 0.5);
    return [
      HarborEthClockConstraint(
        kind: HarborEthClockConstraintKind.clock,
        clock: rxClk,
        ports: [p('rgmii_rxc')],
        periodNs: 8.0,
      ),
      // The receive domain clock on the BUFR output.
      if (_vendorOf(target) == _Vendor.xilinx)
        HarborEthClockConstraint(
          kind: HarborEthClockConstraintKind.generatedClock,
          clock: '${rxClk}_bufr',
          ports: [p('rgmii_rxc')],
          targetPin: instance == null
              ? '*/$_rxBufrName/O'
              : '*$instance/*/$_rxBufrName/O',
        ),
      HarborEthClockConstraint(
        kind: HarborEthClockConstraintKind.generatedClock,
        clock: txClk,
        ports: [p('rgmii_txc')],
        sourcePin: instance == null
            ? '*/$_txcOddrName/C'
            : '*$instance/*/$_txcOddrName/C',
      ),
      for (final fall in [false, true])
        HarborEthClockConstraint(
          kind: HarborEthClockConstraintKind.inputDelay,
          clock: rxClk,
          ports: rxPorts,
          maxNs: rxMax,
          minNs: rxMin,
          clockFall: fall,
        ),
      for (final fall in [false, true])
        HarborEthClockConstraint(
          kind: HarborEthClockConstraintKind.outputDelay,
          clock: txClk,
          ports: txPorts,
          maxNs: txMax,
          minNs: txMin,
          clockFall: fall,
        ),
      if (config.txClockShift)
        const HarborEthClockConstraint(
          kind: HarborEthClockConstraintKind.multicyclePath,
          clock: 'clk125_90',
          ports: [],
          fromCells: ['*$_txcD1*', '*$_txcD2*'],
          toCells: ['*$_txcS1*', '*$_txcS2*'],
          setupCycles: 2,
          holdCycles: 1,
        ),
    ];
  }

  static const _txcD1 = 'txc_d1';
  static const _txcD2 = 'txc_d2';
  static const _txcS1 = 'txc_s1';
  static const _txcS2 = 'txc_s2';

  /// The [speed] synchronized into [clk]. It changes only to a value that
  /// held for 2 clocks after the synchronizer.
  static Logic _speedSync(
    Logic speed,
    Logic clk,
    Logic reset,
    int resetValue,
    String n,
  ) {
    // The synchronizer has no reset. It fills while the reset is high.
    final sync = HarborCdcSync(width: 2, name: '${n}_speed_sync');
    sync.input('async_in').srcConnection! <= speed;
    sync.input('dst_clk').srcConnection! <= clk;
    sync.input('dst_reset').srcConnection! <= Const(0);
    final prev = Logic(name: '${n}_speed_prev', width: 2);
    final held = Logic(name: '${n}_speed_held', width: 2);
    final init = Const(resetValue, width: 2);
    Sequential(
      clk,
      [
        prev < sync.syncOut,
        If(sync.syncOut.eq(prev), then: [held < prev]),
      ],
      reset: reset,
      resetValues: {prev: init, held: init},
    );
    return held;
  }

  /// DDR input register in plain logic for a simulation target. It has the
  /// same timing as the vendor cells.
  static (Logic, Logic) _ddrIn(Logic clk, Logic d, String n) {
    final fallHeld = Logic(name: '${n}_fall_held');
    final q1 = Logic(name: '${n}_q1');
    final q2 = Logic(name: '${n}_q2');
    Sequential.multi([], [fallHeld < d], negedgeTriggers: [clk]);
    Sequential(clk, [q1 < d, q2 < fallHeld]);
    return (q1, q2);
  }

  static _Vendor _vendorOf(HarborDeviceTarget target) => switch (target) {
    HarborSimTarget() => _Vendor.sim,
    HarborFpgaTarget(vendor: HarborFpgaVendor.ecp5) => _Vendor.ecp5,
    HarborFpgaTarget(vendor: HarborFpgaVendor.vivado) ||
    HarborFpgaTarget(vendor: HarborFpgaVendor.openXc7) => _Vendor.xilinx,
    HarborFpgaTarget(vendor: HarborFpgaVendor.ice40) => throw UnsupportedError(
      'HarborEthPhyRgmii needs DDR I/O registers. iCE40 has none in this '
      'catalog. Use MII or RMII, or an ECP5 or Xilinx 7-series part.',
    ),
    HarborAsicTarget() => throw UnsupportedError(
      'HarborEthPhyRgmii has no DDR I/O registers for an ASIC target. They '
      'come from the foundry IO library.',
    ),
  };

  static String _vendorTag(HarborDeviceTarget target) => _vendorOf(target).name;
}

enum _Vendor { sim, xilinx, ecp5 }
