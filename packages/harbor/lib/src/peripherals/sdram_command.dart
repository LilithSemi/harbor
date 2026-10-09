/// Sdr sdram command encoding, shared by the init sequencer, the bank
/// timers and the scheduler.
library;

/// The eight sdr sdram commands the controller issues. The index of each
/// value is the 3-bit `cmd` code carried on the internal command bus.
enum SdramCommand {
  /// No operation.
  nop,

  /// Bank activate.
  act,

  /// Read.
  read,

  /// Write.
  write,

  /// Precharge one bank.
  pre,

  /// Precharge all banks.
  preAll,

  /// Auto refresh.
  ref,

  /// Mode register set.
  mrs,
}

/// Decodes a [SdramCommand] into the `{cs_n, ras_n, cas_n, we_n, a10}` pins
/// the device expects. as4c16m16sb datasheet rev 2.0, command text p9-p17.
extension SdramCommandPins on SdramCommand {
  static const _pinBits = {
    SdramCommand.nop: 0x7,
    SdramCommand.act: 0x3,
    SdramCommand.read: 0x5,
    SdramCommand.write: 0x4,
    SdramCommand.pre: 0x2,
    SdramCommand.preAll: 0x2,
    SdramCommand.ref: 0x1,
    SdramCommand.mrs: 0x0,
  };

  int get _bits => _pinBits[this]!;

  /// Chip select, active low.
  int get csN => (_bits >> 3) & 1;

  /// Row address strobe, active low.
  int get rasN => (_bits >> 2) & 1;

  /// Column address strobe, active low.
  int get casN => (_bits >> 1) & 1;

  /// Write enable, active low.
  int get weN => _bits & 1;

  /// A10 distinguishes [SdramCommand.pre] from [SdramCommand.preAll].
  bool get a10 => this == SdramCommand.preAll;
}
