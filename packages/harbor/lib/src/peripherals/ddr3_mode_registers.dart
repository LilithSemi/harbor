/// DDR3 Mode-Register values and the power-up reset / refresh instruction ROM, a
/// faithful port of ddr3_controller.v (MR0..MR3 localparams at 300-342 and the
/// `read_rom_instruction` function at 555-649).
///
/// The controller drives the DRAM through a fixed sequence held in a small ROM:
/// hold RESET#, raise CKE, program MR2/MR3/MR1/MR0, ZQ-calibrate, precharge,
/// enable/disable the MPR around read calibration, run write leveling, then the
/// refresh loop. Each ROM word packs the CKE/RESET#/A10 control bits, the DDR3
/// command, and either a post-command timer delay or the MRS payload.
library;

import 'ddr3_timing.dart';

/// DDR3 command encoding {cs_n, ras_n, cas_n, we_n} (JEDEC pg. 33).
class Ddr3Cmd {
  static const int mrs = 0x0; // Mode Register Set
  static const int ref = 0x1; // Refresh
  static const int pre = 0x2; // Precharge
  static const int act = 0x3; // Bank Activate
  static const int wr = 0x4; // Write
  static const int rd = 0x5; // Read
  static const int zqc = 0x6; // ZQ Calibration
  static const int nop = 0x7; // No-op
}

/// A decoded reset-ROM instruction word (28 bits).
///
/// Layout (MSB..LSB): [27]=RST_DONE/REF_IDLE, [26]=USE_TIMER, [25]=A10_CONTROL,
/// [24]=CLOCK_EN(CKE), [23]=RESET_N, [22:19]=DDR3 command, [18:0]=timer delay or
/// MRS payload.
class Ddr3Instruction {
  final int word;
  const Ddr3Instruction(this.word);

  int get rstDone => (word >> 27) & 1;
  int get useTimer => (word >> 26) & 1;
  int get a10 => (word >> 25) & 1;
  int get cke => (word >> 24) & 1;
  int get resetN => (word >> 23) & 1;
  int get cmd => (word >> 19) & 0xF;
  int get payload => word & 0x7FFFF;

  @override
  String toString() =>
      'Ddr3Instruction(rstDone:$rstDone useTimer:$useTimer a10:$a10 cke:$cke '
      'resetN:$resetN cmd:$cmd payload:$payload)';
}

class Ddr3ModeRegisters {
  final DdrTiming timing;

  /// Shorten the two multi-hundred-microsecond resets by 500x for simulation
  /// (the MICRON_SIM path). False on hardware.
  final bool micronSim;

  const Ddr3ModeRegisters(this.timing, {this.micronSim = false});

  static const int delaySlotWidth = DdrTiming.delaySlotWidth; // 19

  // --- Mode Register values (ddr3_controller.v:300-340) ---

  /// MR2: CWL=5 (A5:A3=000), ASR on, RTT_WR off. = 0x20040.
  int get mr2 {
    const mr2Sel = 0x2; // 3'b010
    const asr = 1;
    return (mr2Sel << 16) | (asr << 6);
  }

  /// MR3 with the Multi-Purpose Register enabled (predefined pattern 0101...).
  int get mr3MprEn {
    const mr3Sel = 0x3;
    const mprEn = 1;
    const mprLoc = 0x0;
    return (mr3Sel << 16) | (mprEn << 2) | mprLoc; // 0x30004
  }

  /// MR3 with the MPR disabled.
  int get mr3MprDis => 0x3 << 16; // 0x30000

  // MR1 field constants (RTT_NOM = 40 ohm = 3'b011, DIC=00, AL=00, DLL enabled).
  static const int _rttNom = 0x3; // 3'b011
  static const int _dic = 0x0;

  int _mr1(int wlEn) {
    const mr1Sel = 0x1;
    final rtt2 = (_rttNom >> 2) & 1;
    final rtt1 = (_rttNom >> 1) & 1;
    final rtt0 = _rttNom & 1;
    final dic1 = (_dic >> 1) & 1;
    final dic0 = _dic & 1;
    // {MR1_SEL, 3'b000, QOFF, TDQS, 1'b0, RTT[2], 1'b0, WL, RTT[1], DIC[1], AL,
    //  RTT[0], DIC[0], DLL_EN} (QOFF=TDQS=AL=DLL_EN=0).
    return (mr1Sel << 16) |
        (rtt2 << 9) |
        (wlEn << 7) |
        (rtt1 << 6) |
        (dic1 << 5) |
        (rtt0 << 2) |
        (dic0 << 1);
  }

  /// MR1 with write leveling enabled. = 0x100C4.
  int get mr1WlEn => _mr1(1);

  /// MR1 with write leveling disabled. = 0x10044.
  int get mr1WlDis => _mr1(0);

  /// MR0: BL8 fixed, CL=6 (A6:A4=010, A2=0), DLL reset, WR from tWR/CK. = 0x520.
  int get mr0 {
    const cl = 0x4; // 4'b0100
    const dllRst = 1;
    final wr = timing.wr; // 3-bit write-recovery
    final cl31 = (cl >> 1) & 0x7; // CL[3:1]
    final cl0 = cl & 1;
    // {MR0_SEL, 3'b000, PPD, WR, DLL_RST, 1'b0, CL[3:1], RBT, CL[0], BL}.
    return (wr << 9) | (dllRst << 8) | (cl31 << 4) | (cl0 << 2);
  }

  // --- reset / refresh instruction ROM (ddr3_controller.v:555-649) ---

  int _instr({
    int rstDone = 0,
    int useTimer = 0,
    int a10 = 0,
    int cke = 0,
    int resetN = 0,
    required int cmd,
    required int payload,
  }) =>
      (rstDone << 27) |
      (useTimer << 26) |
      (a10 << 25) |
      (cke << 24) |
      (resetN << 23) |
      (cmd << 19) |
      (payload & 0x7FFFF);

  /// The instruction the reset engine holds out of reset before the ROM is first
  /// read: RESET#/CKE low, NOP, a 5-cycle timer (ddr3_controller.v:342).
  int get initialResetInstruction =>
      _instr(useTimer: 1, cmd: Ddr3Cmd.nop, payload: 5);

  /// MRS instruction: CKE/RESET# high, A10 = MRx[10], command = MRS, payload = MRx.
  int _mrs(int mr) => _instr(
    a10: (mr >> 10) & 1,
    cke: 1,
    resetN: 1,
    cmd: Ddr3Cmd.mrs,
    payload: mr,
  );

  int _ns(double ns) => timing.nsToCycles(ns);

  /// The 28-bit ROM word at [address] (0..22; anything else = the default idle
  /// NOP the FSM lands on after the sequence, RST_DONE clear, CKE/RESET# high).
  int romWord(int address) {
    switch (address) {
      case 0: // hold RESET# low >= 200 us
        return _instr(
          useTimer: 1,
          cmd: Ddr3Cmd.nop,
          payload: micronSim
              ? _ns(DdrTiming.powerOnResetHigh / 500)
              : _ns(DdrTiming.powerOnResetHigh.toDouble()),
        );
      case 1: // RESET# high, CKE low >= 500 us
        return _instr(
          useTimer: 1,
          resetN: 1,
          cmd: Ddr3Cmd.nop,
          payload: micronSim
              ? _ns(DdrTiming.initialCkeLow / 500)
              : _ns(DdrTiming.initialCkeLow.toDouble()),
        );
      case 2: // CKE high, wait tXPR
        return _instr(
          useTimer: 1,
          cke: 1,
          resetN: 1,
          cmd: Ddr3Cmd.nop,
          payload: _ns(timing.tXpr),
        );
      case 3: // MRS MR2
        return _mrs(mr2);
      case 4: // MRS MR3 (MPR disabled)
        return _mrs(mr3MprDis);
      case 5: // MRS MR1 (DLL enable, WL disable)
        return _mrs(mr1WlDis);
      case 6: // MRS MR0 (DLL reset)
        return _mrs(mr0);
      case 7: // wait tMOD
        return _instr(
          useTimer: 1,
          cke: 1,
          resetN: 1,
          cmd: Ddr3Cmd.nop,
          payload: timing.tMod,
        );
      case 8: // ZQ calibration (long: A10 high), wait tZQinit
        return _instr(
          useTimer: 1,
          a10: 1,
          cke: 1,
          resetN: 1,
          cmd: Ddr3Cmd.zqc,
          payload: timing.tZqInit,
        );
      case 9: // precharge all (A10 high), wait tRP
        return _instr(
          useTimer: 1,
          a10: 1,
          cke: 1,
          resetN: 1,
          cmd: Ddr3Cmd.pre,
          payload: _ns(DdrTiming.tRp),
        );
      case 10: // MRS MR3 (MPR enable for read calibration)
        return _mrs(mr3MprEn);
      case 11: // wait tMOD
        return _instr(
          useTimer: 1,
          cke: 1,
          resetN: 1,
          cmd: Ddr3Cmd.nop,
          payload: timing.tMod,
        );
      case 12: // read-calibration delay
        return _instr(
          useTimer: 1,
          cke: 1,
          resetN: 1,
          cmd: Ddr3Cmd.nop,
          payload: DdrTiming.calibrationDelay,
        );
      case 13: // MRS MR3 (MPR disable)
        return _mrs(mr3MprDis);
      case 14: // MRS MR1 (WL enable)
        return _mrs(mr1WlEn);
      case 15: // wait tWLMRD
        return _instr(
          useTimer: 1,
          cke: 1,
          resetN: 1,
          cmd: Ddr3Cmd.nop,
          payload: timing.tWlmrd,
        );
      case 16: // write-calibration delay
        return _instr(
          useTimer: 1,
          cke: 1,
          resetN: 1,
          cmd: Ddr3Cmd.nop,
          payload: DdrTiming.calibrationDelay,
        );
      case 17: // MRS MR1 (WL disable)
        return _mrs(mr1WlDis);
      case 18: // wait tMOD
        return _instr(
          useTimer: 1,
          cke: 1,
          resetN: 1,
          cmd: Ddr3Cmd.nop,
          payload: timing.tMod,
        );
      case 19: // precharge all (refresh loop entry), wait tRP
        return _instr(
          useTimer: 1,
          a10: 1,
          cke: 1,
          resetN: 1,
          cmd: Ddr3Cmd.pre,
          payload: _ns(DdrTiming.tRp),
        );
      case 20: // refresh, wait tRFC
        return _instr(
          useTimer: 1,
          cke: 1,
          resetN: 1,
          cmd: Ddr3Cmd.ref,
          payload: _ns(timing.tRfc),
        );
      case 21: // reset done (RST_DONE=1), refresh interval starts, wait tREFI
        return _instr(
          rstDone: 1,
          useTimer: 1,
          cke: 1,
          resetN: 1,
          cmd: Ddr3Cmd.nop,
          payload: _ns(DdrTiming.tRefiNs.toDouble()),
        );
      case 22: // pre-refresh margin
        return _instr(
          useTimer: 1,
          cke: 1,
          resetN: 1,
          cmd: Ddr3Cmd.nop,
          payload: timing.preRefreshDelay,
        );
      default: // idle NOP (CKE/RESET# high, no timer)
        return _instr(cke: 1, resetN: 1, cmd: Ddr3Cmd.nop, payload: 0);
    }
  }

  /// The full ROM as decoded instructions, addresses 0..22.
  List<Ddr3Instruction> get rom => [
    for (var a = 0; a <= 22; a++) Ddr3Instruction(romWord(a)),
  ];
}
