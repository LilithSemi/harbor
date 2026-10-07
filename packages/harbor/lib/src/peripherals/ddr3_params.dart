/// Parameters for the DDR3 controller, faithful to the UberDDR3 parameter set.
///
/// The controller and PHY are Xilinx 7-series generic (Artix-7, Kintex-7,
/// Spartan-7, Zynq-7); [odelaySupported] is the only bank-specific knob (HP banks
/// have ODELAYE2 for the write path, HR banks use the CK@90 launch instead). The
/// geometry defaults target the Micron MT41K128M16 (256 MB, x16) as fitted on the
/// Digilent Arty S7.
///
/// Notably absent are the bench-sweep tuning knobs the old harbor PHY carried
/// (cmdSlot, wrShift, wrBeat, window, readTaps, readSlack, readRetry, ...): the
/// UberDDR3 calibration engine finds the read/write timing at run time, so there
/// is nothing to hand-tune.
library;

import 'ddr3_timing.dart';

class DdrParams {
  /// Controller-LOGIC clock period in picoseconds. Must be an integer multiple
  /// of [ddr3ClkPeriodPs] that is itself a multiple of [serdesRatio]. When it
  /// equals [serdesRatio] * [ddr3ClkPeriodPs] the controller clock IS the SERDES
  /// CLKDIV (no gearbox, [gearRatio] == 1, the historical 4:1 arrangement). When
  /// it is a larger multiple (e.g. 8x CK with a 4-wide SERDES = [gearRatio] 2),
  /// the controller logic runs slower than the SERDES datapath and a fabric
  /// [gearRatio]:1 gearbox bridges them. Slowing the logic buys timing margin
  /// for the congestion-limited command scheduler on a dense open-tools part,
  /// at the cost of proportionally lower peak DDR command bandwidth.
  final int controllerClkPeriodPs;

  /// DDR3 device clock (CK) period in picoseconds (e.g. 3000 = 333.3 MHz,
  /// 3333 = 300 MHz).
  final int ddr3ClkPeriodPs;

  /// Row-address width. MT41K128M16 = 14.
  final int rowBits;

  /// Column-address width. MT41K128M16 = 10.
  final int colBits;

  /// Bank-address width. DDR3 = 3 (8 banks).
  final int baBits;

  /// DQ bits per byte lane. Always 8 for DDR3.
  final int dqBits;

  /// Byte lanes: 1 = x8, 2 = x16. The Arty S7 populates a x16 device, so 2
  /// (the full 256 MB).
  final int lanes;

  /// Write path selection: HP-bank ODELAYE2 deskew (true) vs HR-bank CK@90
  /// launch (false). Spartan-7 and Artix-7 HR banks = false.
  final bool odelaySupported;

  /// Emit the low-power idle sequence between bursts (UberDDR3 OPT_LOWPOWER).
  final bool optLowPower;

  /// Honour i_wb_cyc dropping mid-transaction as an abort (UberDDR3 OPT_BUS_ABORT).
  final bool optBusAbort;

  /// Exercise the data-mask (per-byte write) path during calibration.
  final bool testDatamask;

  /// Run the built-in self test (burst / random / alternating write-read across
  /// the address space) before the wishbone bus is opened. Reaching
  /// DONE_CALIBRATE then means the memory has been proven read/write-clean.
  final bool bistMode;

  /// DDR3 speed bin selecting the JEDEC AC timings: 0 = use top-level overrides,
  /// 1 = DDR3-1066 (7-7-7), 2 = DDR3-1333 (9-9-9), 3 = DDR3-1600 (11-11-11).
  final int speedBin;

  /// Side-band ECC (0 = off). Kept for parity with UberDDR3; unused on the Arty S7.
  final bool eccEnable;

  /// Dual-rank DIMM support (adds a rank address bit). Single-rank device = false.
  final bool dualRankDimm;

  /// SERDES DATAPATH ratio = CK cycles per SERDES CLKDIV tick = beats-per-BL8 / 2
  /// = 4 for a real-speed 7-series PHY (OSERDESE2/ISERDESE2 DATA_WIDTH 8, DDR).
  /// This fixes the datapath width ([wbDataBits]) and the SERDES config; it is
  /// INDEPENDENT of the controller-logic clock. Do not exceed 4 on 7-series
  /// (single-primitive OSERDESE2 max). Slowing the controller uses a larger
  /// [controllerClkPeriodPs] + the gearbox, not a larger serdesRatio.
  final int serdesRatio;

  /// Device density. It sets tRFC in the controller timing.
  final DdrDensity density;

  const DdrParams({
    required this.controllerClkPeriodPs,
    required this.ddr3ClkPeriodPs,
    this.serdesRatio = 4,
    this.rowBits = 14,
    this.colBits = 10,
    this.baBits = 3,
    this.dqBits = 8,
    this.lanes = 2,
    this.odelaySupported = false,
    this.optLowPower = true,
    this.optBusAbort = true,
    this.testDatamask = true,
    this.bistMode = true,
    this.speedBin = 1,
    this.eccEnable = false,
    this.dualRankDimm = false,
    this.density = DdrDensity.gb2,
  }) : assert(dqBits == 8, 'DDR3 DQ is 8 bits per lane'),
       assert(lanes == 1 || lanes == 2, 'x8 (1) or x16 (2)'),
       assert(serdesRatio >= 1, 'serdesRatio must be >= 1'),
       // The controller clock must be an integer multiple of the SERDES CLKDIV
       // rate (serdesRatio * CK), so the fabric gearbox is a clean integer ratio.
       assert(
         controllerClkPeriodPs % (serdesRatio * ddr3ClkPeriodPs) == 0,
         'controllerClkPeriodPs must be an integer multiple of '
         'serdesRatio * ddr3ClkPeriodPs (so gearRatio is integer)',
       );

  /// Digilent Arty S7: Micron MT41K128M16, x16, 256 MB, HR I/O bank. [ckPeriodPs]
  /// sets the DDR CK (3000 = 333 MHz, 3333 = 300 MHz); the controller clock is
  /// `4 * controllerGearRatio` times slower than CK. [controllerGearRatio] 1 (the
  /// default) is the historical CK/4 controller ([gearRatio] 1, no gearbox); 2
  /// runs the controller LOGIC at CK/8 through the fabric gearbox for timing
  /// margin ([gearRatio] 2) while the SERDES stays at CK/4.
  factory DdrParams.artyS7({
    int ckPeriodPs = 3000,
    int controllerGearRatio = 1,
  }) => DdrParams(
    ddr3ClkPeriodPs: ckPeriodPs,
    controllerClkPeriodPs: ckPeriodPs * 4 * controllerGearRatio,
    rowBits: 14,
    colBits: 10,
    baBits: 3,
    dqBits: 8,
    lanes: 2,
    odelaySupported: false,
    speedBin: 1,
  );

  /// OrangeCrab r0.2: Micron MT41K64M16 (1 Gb, 128 MB, x16), the litex-boards
  /// gsd_orangecrab default part. The ECP5 PHY presents the same CK/4 SERDES
  /// interface as the Xilinx PHY, so [serdesRatio] stays 4. The default CK is
  /// 96 MHz, the litex-boards `gsd_orangecrab.py` proven setting
  /// (`sys_clk_freq=48e6` default on both `BaseSoC` and the `--sys-clk-freq`
  /// CLI flag). `_CRGSDRAM.pll.create_clkout(cd_sys2x_i, 2*sys_clk_freq)`
  /// makes the DDR3 CK, and litedram's `ecp5ddrphy.py` ECLK runs off that
  /// same `sys2x` net. 10417 ps rounds 1e6/96.0 to the nearest ps
  /// ([buildEcp5Ddr3ClockTree]'s own realised-CK rounding).
  factory DdrParams.orangeCrab({
    int ckPeriodPs = 10417,
    int controllerGearRatio = 1,
  }) => DdrParams(
    ddr3ClkPeriodPs: ckPeriodPs,
    controllerClkPeriodPs: ckPeriodPs * 4 * controllerGearRatio,
    rowBits: 13,
    colBits: 10,
    baBits: 3,
    dqBits: 8,
    lanes: 2,
    odelaySupported: false,
    speedBin: 1,
    density: DdrDensity.gb1,
  );

  // --- derived geometry (mirrors the UberDDR3 localparams) ---

  /// Controller-LOGIC clock ratio = CK cycles per controller-logic tick =
  /// controllerClkPeriodPs / CK. 4 historically (== serdesRatio, no gearbox);
  /// 8 for the CK/8 controller (gearRatio 2). Drives the AC-timing counters.
  int get controllerClkRatio => controllerClkPeriodPs ~/ ddr3ClkPeriodPs;

  /// Fabric gearbox ratio = controller-logic cycles' worth of SERDES loads per
  /// controller tick = controllerClkRatio / serdesRatio. 1 = the controller
  /// clock IS the SERDES CLKDIV (no gearbox, historical). 2 = a CK/8 controller
  /// feeding a CK/4 SERDES: the gearbox drives one BL8 into slot 0 of the pair
  /// and a NOP into slot 1 (half the peak command bandwidth).
  int get gearRatio => controllerClkRatio ~/ serdesRatio;

  /// Burst-addressable {row, bank, col} address, minus the bits a single
  /// wishbone word already spans across the SERDES burst.
  int get wbAddrBits =>
      rowBits +
      colBits +
      baBits -
      _clog2(serdesRatio * 2) +
      (dualRankDimm ? 1 : 0);

  /// Wishbone data width: one BL8 burst gathered across the SERDES ratio, both
  /// lanes. x16 @ 4:1 = 8*2*4*2 = 128 bits.
  int get wbDataBits => dqBits * lanes * serdesRatio * 2;

  /// Wishbone byte-select width.
  int get wbSelBits => wbDataBits ~/ 8;

  /// Total addressable capacity in bytes (x16 = 256 MB).
  int get sizeBytes => (1 << wbAddrBits) * wbSelBits;

  static int _clog2(int x) {
    var n = 0;
    var v = x - 1;
    while (v > 0) {
      v >>= 1;
      n++;
    }
    return n;
  }
}
