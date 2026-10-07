import 'package:rohd/rohd.dart';

/// The vendor-neutral seam between the DDR3 controller and a concrete PHY.
///
/// A PHY must also take the controller's named inputs: clocks, resets, `cmd`,
/// the tri-state, data, and `dm` buses, the four delay tap and load pairs,
/// `bitslip`, `writeLevelingCalib`, and the `dq`/`dqs`/`dqsN` pads. See [Ddr3Phy].
///
/// The `odelay`, `idelay`, `idelayctrl`, and `iserdes` names come from Xilinx.
/// Each is a function, not a primitive: a tap value with a load pulse, a lock
/// flag, and deserialized read data. Another vendor maps them to its own cells.
abstract class Ddr3PhyBase extends Module {
  Ddr3PhyBase({super.name});

  /// Delay-reference lock status. The calibration engine waits on this
  /// before loading any tap.
  Logic get idelayctrlRdy;

  /// Deserialized read data (one BL8 gather).
  Logic get iserdesData;

  /// Deserialized DQS strobe, read to find where the read burst begins.
  Logic get iserdesDqs;

  /// Fabric model of the read SERDES bitslip barrel-shift.
  Logic get iserdesBitslipReference;

  /// True when the PHY levels its own read path. The controller then skips
  /// its sampled-DQS calibration and drives the read-level ports instead.
  bool get selfTrainsRead => false;

  /// High when the PHY's own read leveling is done. Null when
  /// [selfTrainsRead] is false.
  Logic? get readLevelDone => null;

  // SDRAM pads. A missing pad in an implementation fails at compile time,
  // not as a dead pin.

  Logic get oDdr3ClkP;
  Logic get oDdr3ClkN;
  Logic get oDdr3Cke;
  Logic get oDdr3CsN;
  Logic get oDdr3RasN;
  Logic get oDdr3CasN;
  Logic get oDdr3WeN;
  Logic get oDdr3Odt;
  Logic get oDdr3ResetN;
  Logic get oDdr3BaAddr;
  Logic get oDdr3Addr;
  Logic get oDdr3Dm;
  Logic get ioDdr3Dq;
  Logic get ioDdr3Dqs;
  Logic get ioDdr3DqsN;
}
