/// The vendor-neutral seam between the sdr sdram engine and a concrete PHY.
library;

import 'package:rohd/rohd.dart';

/// A PHY carries every sdram_* pin through its own vendor IO registers. The
/// engine drives plain command, address and data signals and never sees a
/// vendor cell, so a new target only needs a new [SdramPhyBase] subclass.
abstract class SdramPhyBase extends Module {
  SdramPhyBase({super.name});

  /// Cycles from the engine's phy-side cycle of a read command to the cycle
  /// [rdData] holds beat 0.
  int get readLatency;

  /// 16-bit read return data, valid [readLatency] cycles after a read.
  Logic get rdData;

  Logic get oSdramClk;
  Logic get oSdramCke;
  Logic get oSdramCsN;
  Logic get oSdramRasN;
  Logic get oSdramCasN;
  Logic get oSdramWeN;
  Logic get oSdramBa;
  Logic get oSdramAddr;
  Logic get oSdramDqm;
  Logic get ioSdramDq;
}
