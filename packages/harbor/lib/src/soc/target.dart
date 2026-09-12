import '../debug/jtag_remote.dart' show JtagRemote;
import '../pdk/io_ring.dart';
import '../pdk/klayout.dart';
import '../pdk/pdk_provider.dart';

/// Build target describing whether the SoC targets an FPGA or ASIC,
/// and which vendor/PDK to use.
///
/// The target controls what synthesis and place-and-route scripts
/// are generated when calling [HarborSoC.generateAll].
sealed class HarborDeviceTarget {
  /// Human-readable name for this target.
  String get name;

  /// The dual-clock block RAM primitive of this target, or null when the
  /// target has none.
  ///
  /// A block that can keep a `depth x width` storage array off the flop budget
  /// (for example `HarborCdcFifo` with `blockRam: true`) asks the target here.
  /// A null answer means the block must build the array from flops instead.
  /// Every target answers, so a new family only has to add its own case.
  HarborBlockRam? get blockRam => null;

  const HarborDeviceTarget();
}

/// The dual-clock block RAM primitive of a device family.
///
/// Each value names the vendor cell that the family maps a dual-clock
/// `depth x width` memory onto. Harbor does not instantiate the cell by hand:
/// it emits the inference template that the family's synthesis tool maps onto
/// this cell. The name here says which cell to expect in the netlist, and which
/// cell to count when you check the fit.
enum HarborBlockRam {
  /// Lattice ECP5 EBR: `DP16KD`, 18 kbit, one clock for each of the two ports.
  dp16kd,

  /// Lattice iCE40 EBR: `SB_RAM40_4K`, 4 kbit, separate `RCLK` and `WCLK`.
  sbRam40_4k,

  /// Xilinx 7-series block RAM: `RAMB18E1`/`RAMB36E1`, one clock for each of
  /// the two ports.
  ramb,
}

/// Implemented by a bus master that exposes a debug module over the FPGA
/// config-JTAG BSCAN tunnel (e.g. a RISC-V DM). When a SoC has such a master
/// and an FPGA target, [HarborSoC.generateAll] auto-emits an `openocd.cfg` via
/// [HarborFpgaTarget.generateOpenocdConfig].
abstract interface class HarborJtagDebug {
  /// Inner debug-module IR width in bits for the nested BSCAN tunnel.
  int get jtagInnerIrWidth;

  /// The debug module's JTAG IDCODE, or null if unknown.
  int? get jtagDmIdcode;
}

/// FPGA target with vendor-specific toolchain configuration.
///
/// ```dart
/// final target = HarborFpgaTarget.ice40(
///   device: 'up5k',
///   package: 'sg48',
///   frequency: 48000000,
///   pinMap: {'uart_tx': 'P1', 'uart_rx': 'P2'},
/// );
/// ```
class HarborFpgaTarget extends HarborDeviceTarget {
  @override
  final String name;

  /// FPGA vendor.
  final HarborFpgaVendor vendor;

  /// Device part number (e.g., `'up5k'`, `'lfe5u-45f'`, `'xc7s50'`).
  final String device;

  /// Package (e.g., `'sg48'`, `'CABGA381'`, `'ftgb196'`).
  final String package;

  /// Target clock frequency in Hz.
  final int frequency;

  /// Pin constraints: signal name → pin identifier.
  final Map<String, String> pinMap;

  /// Extra constraint lines, written into the generated file without a change.
  ///
  /// The key is a label only. The value is one full line of the constraint
  /// language of this target's family, with its own terminator (an LPF
  /// statement ends with `;`, a PCF or XDC line does not). The lines go at the
  /// end of the file, between `# BEGIN extraConstraints` and
  /// `# END extraConstraints`.
  ///
  /// Every family has its own language: iCE40 writes PCF, ECP5 writes LPF, and
  /// Xilinx writes XDC. Harbor does not translate between them and does not
  /// check the syntax, so a line that is correct for one family goes to the
  /// place-and-route tool of another family as written, and that tool rejects
  /// it. Keep one map for each family.
  ///
  /// These lines are added to the [pinMap] constraints, they do not replace
  /// them. In LPF, a second `IOBUF PORT` statement for a pin that [pinMap] also
  /// constrains adds its attributes to the first one. In PCF, a second `set_io`
  /// for the same pin is an error ("duplicate pin constraint").
  ///
  /// nextpnr uses only the IO attributes that it knows. `syn_useioff` in an LPF
  /// `IOBUF PORT` line gives "attribute 'syn_useioff' is not recognised" and
  /// does nothing. To pack a flop into an ECP5 IO cell, put the `syn_useioff`
  /// attribute on the flop in the RTL, which nextpnr-ecp5 does obey.
  final Map<String, String> extraConstraints;

  /// Name of the top-level clock input port, used for the timing constraint in
  /// the generated constraint file. Defaults to `'clk'`.
  final String clockPortName;

  /// Optional bitstream programming command for a `prog` Makefile target
  /// (e.g. `'openFPGALoader -b ulx3s \$(TOP).bit'`). When null, no `prog`
  /// target is emitted.
  final String? progCommand;

  /// Whether this FPGA supports eFuse OTP storage.
  ///
  /// ECP5 and Spartan 7 have eFuse support for user data and
  /// security keys. iCE40 does not.
  bool get hasEfuse => switch (vendor) {
    HarborFpgaVendor.ice40 => false,
    HarborFpgaVendor.ecp5 => true,
    HarborFpgaVendor.vivado => true,
    HarborFpgaVendor.openXc7 => true,
  };

  /// The dual-clock block RAM primitive of this FPGA family.
  ///
  /// Every supported family has one, so this is never null for an FPGA.
  @override
  HarborBlockRam get blockRam => switch (vendor) {
    HarborFpgaVendor.ice40 => HarborBlockRam.sbRam40_4k,
    HarborFpgaVendor.ecp5 => HarborBlockRam.dp16kd,
    HarborFpgaVendor.vivado => HarborBlockRam.ramb,
    HarborFpgaVendor.openXc7 => HarborBlockRam.ramb,
  };

  /// Whether this FPGA has a built-in temperature sensor primitive.
  ///
  /// ECP5 has DTR, Xilinx 7-series has XADC. iCE40 does not.
  bool get hasTemperatureSensor => switch (vendor) {
    HarborFpgaVendor.ice40 => false,
    HarborFpgaVendor.ecp5 => true,
    HarborFpgaVendor.vivado => true,
    HarborFpgaVendor.openXc7 => true,
  };

  /// File extension for the constraint file (e.g., `'pcf'`, `'lpf'`, `'xdc'`).
  String get constraintExtension => switch (vendor) {
    HarborFpgaVendor.ice40 => 'pcf',
    HarborFpgaVendor.ecp5 => 'lpf',
    HarborFpgaVendor.vivado => 'xdc',
    HarborFpgaVendor.openXc7 => 'xdc',
  };

  const HarborFpgaTarget({
    required this.name,
    required this.vendor,
    required this.device,
    required this.package,
    this.frequency = 0,
    this.pinMap = const {},
    this.extraConstraints = const {},
    this.clockPortName = 'clk',
    this.progCommand,
  });

  /// iCE40 UP5K target using Yosys + nextpnr-ice40.
  const HarborFpgaTarget.ice40({
    required this.device,
    required this.package,
    this.frequency = 0,
    this.pinMap = const {},
    this.extraConstraints = const {},
    this.clockPortName = 'clk',
    this.progCommand,
  }) : name = 'ice40-$device',
       vendor = HarborFpgaVendor.ice40;

  /// Lattice ECP5 target using Yosys + nextpnr-ecp5.
  const HarborFpgaTarget.ecp5({
    required this.device,
    required this.package,
    this.frequency = 0,
    this.pinMap = const {},
    this.extraConstraints = const {},
    this.clockPortName = 'clk',
    this.progCommand,
  }) : name = 'ecp5-$device',
       vendor = HarborFpgaVendor.ecp5;

  /// Xilinx Spartan 7 target using Vivado or openXC7.
  const HarborFpgaTarget.spartan7({
    required this.device,
    required this.package,
    this.frequency = 0,
    this.pinMap = const {},
    this.extraConstraints = const {},
    this.clockPortName = 'clk',
    this.progCommand,
    bool useOpenXc7 = false,
  }) : name = 'spartan7-$device',
       vendor = useOpenXc7 ? HarborFpgaVendor.openXc7 : HarborFpgaVendor.vivado;

  /// Yosys synthesis target string for this FPGA family.
  String get _yosysSynthTarget => switch (vendor) {
    HarborFpgaVendor.ice40 => 'ice40',
    HarborFpgaVendor.ecp5 => 'ecp5',
    HarborFpgaVendor.vivado => 'xilinx',
    HarborFpgaVendor.openXc7 => 'xilinx',
  };

  /// Bitstream output extension.
  String get bitstreamExtension => switch (vendor) {
    HarborFpgaVendor.ice40 => 'bin',
    HarborFpgaVendor.ecp5 => 'bit',
    HarborFpgaVendor.vivado => 'bit',
    HarborFpgaVendor.openXc7 => 'bit',
  };

  /// prjxray architecture family string for the openXC7 flow.
  ///
  /// Used as the `fasm2frames --db-root $(XRAY_DB)/<family>` segment and the
  /// `xc7frames2bit --part_file $(XRAY_DB)/<family>/<part>/part.yaml` path. Only
  /// meaningful for the Xilinx vendors (empty otherwise).
  String get _prjxrayFamily => switch (vendor) {
    HarborFpgaVendor.vivado || HarborFpgaVendor.openXc7 => 'spartan7',
    HarborFpgaVendor.ice40 || HarborFpgaVendor.ecp5 => '',
  };

  /// Generates a Yosys synthesis TCL script for this FPGA target.
  ///
  /// Produces a JSON netlist for nextpnr (iCE40/ECP5) or a
  /// Verilog netlist for Vivado/openXC7.
  String generateYosysTcl(String topCell, {List<String> svFiles = const []}) {
    final buf = StringBuffer();
    buf.writeln('# Auto-generated Yosys synthesis for $name');
    buf.writeln('# Target: ${_yosysSynthTarget} ($device)');
    buf.writeln();
    if (svFiles.isNotEmpty) {
      for (final sv in svFiles) {
        buf.writeln('read_verilog -sv $sv');
      }
    } else {
      buf.writeln('read_verilog -sv rtl/*.sv');
    }
    buf.writeln('hierarchy -top $topCell');

    switch (vendor) {
      case HarborFpgaVendor.ice40:
        // -abc2 -relut: extra ABC pass plus LUT re-mapping. Measured on the
        // stream_v1/up5k bring-up: 4160 -> 3822 LUT4s (~8%) for synth time.
        buf.writeln(
          'synth_ice40 -abc2 -relut -top $topCell -json $topCell.json',
        );
      case HarborFpgaVendor.ecp5:
        buf.writeln('synth_ecp5 -top $topCell -json $topCell.json');
      case HarborFpgaVendor.vivado:
      case HarborFpgaVendor.openXc7:
        // NOTE: -nowidelut (wide muxes as LUT trees, not MUXF7/8 carry chains)
        // de-congests the ddr_clk 8-bank select mux (s2_bank -> MUXF7/MUXF8 tree
        // -> command flop, the 56 MHz path while ddr_clk is driven at 75), but it
        // has caused unrelated issues before, so it is NOT used here. De-congest
        // that path a targeted way instead (register-duplicate s2_bank with a
        // synth-flow keep, or floorplan the controller).
        buf.writeln('synth_xilinx -top $topCell -flatten');
        buf.writeln('write_json $topCell.json');
    }

    buf.writeln('stat');
    return buf.toString();
  }

  /// Maps an ECP5 device part to its nextpnr size suffix (e.g. `45k`).
  static String _ecp5DeviceSize(String device) {
    final lower = device.toLowerCase();
    if (lower.contains('12')) return '12k';
    if (lower.contains('25')) return '25k';
    if (lower.contains('45')) return '45k';
    if (lower.contains('85')) return '85k';
    return device;
  }

  /// Generates a nextpnr command for place-and-route (iCE40/ECP5).
  ///
  /// Returns null for Vivado targets (which use their own flow).
  String? generateNextpnrCommand(String topCell) {
    switch (vendor) {
      case HarborFpgaVendor.ice40:
        return 'nextpnr-ice40 --$device --package $package '
            '--json $topCell.json '
            '--pcf $topCell.pcf '
            '--asc $topCell.asc'
            '${frequency > 0 ? " --freq ${(frequency / 1e6).toStringAsFixed(0)}" : ""}';
      case HarborFpgaVendor.ecp5:
        final ecp5Size = _ecp5DeviceSize(device);
        return 'nextpnr-ecp5 --$ecp5Size --package $package '
            '--json $topCell.json '
            '--lpf $topCell.lpf '
            '--textcfg $topCell.config'
            '${frequency > 0 ? " --freq ${(frequency / 1e6).toStringAsFixed(0)}" : ""}';
      case HarborFpgaVendor.vivado:
      case HarborFpgaVendor.openXc7:
        return null; // Vivado/openXC7 use their own PnR
    }
  }

  /// Generates a bitstream packing command (iCE40/ECP5).
  ///
  /// Returns null for Vivado targets.
  String? generatePackCommand(String topCell) {
    switch (vendor) {
      case HarborFpgaVendor.ice40:
        return 'icepack $topCell.asc $topCell.bin';
      case HarborFpgaVendor.ecp5:
        return 'ecppack --input $topCell.config --bit $topCell.bit';
      case HarborFpgaVendor.vivado:
      case HarborFpgaVendor.openXc7:
        return null;
    }
  }

  /// Boundary-scan TAP IR length for this FPGA family.
  int get jtagIrLength => switch (vendor) {
    HarborFpgaVendor.vivado || HarborFpgaVendor.openXc7 => 6, // Xilinx 7-series
    HarborFpgaVendor.ecp5 => 8,
    HarborFpgaVendor.ice40 => 8,
  };

  /// The config-JTAG user-register instruction a debug BSCAN tunnel rides.
  /// Xilinx 7-series USER4 = 0x23 (riscv-openocd's bscan tunnel hardcodes USER4
  /// for tunneled DMI scans, so the DM must sit on it); ECP5 ER1 = 0x32.
  int get jtagUserInstruction => switch (vendor) {
    HarborFpgaVendor.vivado || HarborFpgaVendor.openXc7 => 0x23,
    HarborFpgaVendor.ecp5 => 0x32,
    HarborFpgaVendor.ice40 => 0x00,
  };

  /// Known boundary-scan IDCODE for this device, or null to accept any.
  int? get jtagIdcode => switch (device.toLowerCase()) {
    'xc7s50' => 0x0362F093,
    'xc7s25' => 0x0362D093,
    'lfe5u-25f' => 0x41111043,
    'lfe5u-45f' => 0x41112043,
    'lfe5u-85f' => 0x41113043,
    _ => null,
  };

  /// Generates an OpenOCD config to reach a RISC-V debug module that is tunneled
  /// through this FPGA's config JTAG (Xilinx BSCANE2 on USER1, ECP5 JTAGG ER1)
  /// with a SiFive nested-tap BSCAN tunnel. The adapter and outer TAP come from
  /// this target; [innerIrWidth] and [dmIdcode] describe the inner DM (River's
  /// DM is irWidth 5, idcode 0x10000001). The FTDI adapter defaults to the
  /// Digilent Arty FT2232H layout on Xilinx; override for another board.
  String generateOpenocdConfig({
    required int innerIrWidth,
    int? dmIdcode,
    int adapterSpeedKHz = 1000,
    String targetName = 'cpu',
  }) {
    String hex(int v, int width) =>
        '0x${v.toRadixString(16).padLeft(width, '0')}';

    final buf = StringBuffer();
    buf.writeln(
      '# Auto-generated by Harbor. OpenOCD for a RISC-V debug module',
    );
    buf.writeln(
      '# tunneled through the $name config JTAG (BSCAN tunnel on the',
    );
    buf.writeln('# ${vendor.name} TAP). Launch: openocd -f openocd.cfg');
    buf.writeln();

    // Adapter: the config-JTAG entry point.
    switch (vendor) {
      case HarborFpgaVendor.vivado:
      case HarborFpgaVendor.openXc7:
        buf.writeln('adapter driver ftdi');
        buf.writeln('ftdi vid_pid 0x0403 0x6010');
        buf.writeln('ftdi channel 0');
        buf.writeln('ftdi layout_init 0x0088 0x008b');
      case HarborFpgaVendor.ecp5:
        buf.writeln('adapter driver dirtyjtag');
      case HarborFpgaVendor.ice40:
        buf.writeln('adapter driver ftdi');
    }
    buf.writeln('transport select jtag');
    buf.writeln('adapter speed $adapterSpeedKHz');
    buf.writeln();

    // Outer FPGA TAP.
    buf.writeln('set _CHIPNAME ${device.toLowerCase()}');
    final fid = jtagIdcode;
    buf.writeln(
      'jtag newtap \$_CHIPNAME tap -irlen $jtagIrLength '
      '-expected-id ${fid != null ? hex(fid, 8) : hex(0, 8)}',
    );
    buf.writeln(
      'set _USER ${hex(jtagUserInstruction, 2)}  ;# config-JTAG user register '
      'the DM tunnels through',
    );
    buf.writeln();

    // RISC-V target on the outer TAP. Create it BEFORE any `riscv` subcommand:
    // the `riscv` command group only registers once a riscv target exists.
    buf.writeln('set _TARGETNAME \$_CHIPNAME.$targetName');
    buf.writeln(
      'target create \$_TARGETNAME riscv -chain-position \$_CHIPNAME.tap',
    );
    if (dmIdcode != null) {
      buf.writeln('# inner DM IDCODE ${hex(dmIdcode, 8)}');
    }
    buf.writeln();

    // Enable the nested-tap BSCAN tunnel before init so examination reaches the
    // inner DM through it (hardware-proven: OpenOCD examines the RISC-V DM and
    // reads DDR over SBA through this). Then prefer System Bus Access so memory
    // (e.g. DDR) reads/writes without halting the core.
    buf.writeln(
      '# SiFive nested-tap BSCAN tunnel, inner DM IR width $innerIrWidth.',
    );
    buf.writeln('riscv use_bscan_tunnel $innerIrWidth 0');
    buf.writeln('riscv set_mem_access sysbus progbuf abstract');
    buf.writeln();

    buf.writeln('init');
    buf.writeln('irscan \$_CHIPNAME.tap \$_USER');
    buf.writeln('targets');
    return buf.toString();
  }

  /// Per-device DDR train-SERDES pre-place geometry for the openXC7 flow.
  ///
  /// The DDR PHY's bitslip-reference train SERDES must be pinned off the dead
  /// `_SING` OLOGIC/ILOGIC tile (missing prjxray PIPs make its capture dead).
  /// Lane 0 pins to `X<column>Y<baseY>`, lane `l` to
  /// `X<column>Y<baseY + l*strideY>`; the dead `_SING` tile sits one stride
  /// above lane 0 (`baseY - strideY`). Each lane's OSERDESE2/ISERDESE2 pair
  /// shares the SAME tile (they loop back via OFB).
  ///
  /// Keyed by the lower-case device part. Add an entry per verified part.
  static const Map<String, _DdrPreplaceGeom> _ddrPreplaceGeom = {
    // Verified on the Arty S7 (xc7s50), 2 lanes: lane0 -> X0Y145,
    // lane1 -> X0Y141, dead _SING -> X0Y149.
    'xc7s50': _DdrPreplaceGeom(baseY: 145, strideY: -4, column: 0),
  };

  /// Generates the nextpnr-xilinx `--pre-place` Python script
  /// (`support/nextpnr/constraints.py`) for the openXC7 DDR3 flow.
  ///
  /// It pins each of the [lanes] DDR train SERDES pairs off the dead `_SING`
  /// tile using the [device]-keyed [_ddrPreplaceGeom]. When the device is not
  /// in the map, the xc7s50 geometry is used as a fallback and a warning
  /// header notes that the placement is unverified for the part.
  String generateDdrPreplacePy({required int lanes}) {
    final geom = _ddrPreplaceGeom[device.toLowerCase()];
    // Fallback geometry (xc7s50) when the part is unknown: still emit, but flag.
    final g =
        geom ?? const _DdrPreplaceGeom(baseY: 145, strideY: -4, column: 0);
    final singY =
        g.baseY - g.strideY; // dead _SING tile, one stride above lane 0

    final buf = StringBuffer();
    if (geom == null) {
      buf.writeln(
        '# WARNING: device "$device" has no verified DDR train-SERDES tile',
      );
      buf.writeln(
        '# placement in Harbor. The geometry below is the xc7s50 default and is',
      );
      buf.writeln(
        '# UNVERIFIED for this part - confirm the OLOGIC/ILOGIC tile Y range.',
      );
    }
    buf.writeln(
      '# Pin the bitslip-reference train serdes off the _SING tile '
      '(X${g.column}Y$singY, which has',
    );
    buf.writeln(
      '# missing prjxray PIPs -> dead capture). Each lane\'s '
      'OSERDESE2/ISERDESE2 pair',
    );
    buf.writeln(
      '# must share the SAME ILOGIC/OLOGIC tile (they loop back via OFB).',
    );
    buf.writeln('def get_cells(part):');
    buf.writeln('    return [c.second for c in ctx.cells if part in c.first]');
    final pairs = [
      for (var l = 0; l < lanes; l++)
        "('$l', 'X${g.column}Y${g.baseY + l * g.strideY}')",
    ];
    buf.writeln('pairs = [${pairs.join(', ')}]');
    buf.writeln('for suf, y in pairs:');
    buf.writeln("    for c in get_cells('train_oserdes_' + suf):");
    buf.writeln("        c.setAttr('BEL', 'OLOGIC_' + y + '/OSERDESE2')");
    buf.writeln(
      "        print('PREPLACE train_oserdes_%s -> OLOGIC_%s' % (suf, y))",
    );
    buf.writeln("    for c in get_cells('train_iserdes_' + suf):");
    buf.writeln("        c.setAttr('BEL', 'ILOGIC_' + y + '/ISERDESE2')");
    buf.writeln(
      "        print('PREPLACE train_iserdes_%s -> ILOGIC_%s' % (suf, y))",
    );
    return buf.toString();
  }

  /// Generates the nextpnr-xilinx `--pre-pack` clock over-constraint
  /// (`support/nextpnr/clocks.py`). nextpnr-xilinx does not propagate the XDC
  /// `create_clock` through a PLLE2/MMCM or BUFG, so every derived clock (the
  /// core net `O`, the DDR controller net `ddr_clk`) reaches the timing engine
  /// UNCONSTRAINED - zero margin, setup-only, single-corner. addClock at a rate
  /// ABOVE the real one restores a timing budget: it drives timing-aware
  /// placement/routing to prioritise these paths and surfaces true silicon
  /// margin as an honest WNS. The core is over-constrained modestly (it already
  /// runs well under its routing ceiling); the DDR controller carries the larger
  /// margin because it is far more slack-critical per cycle.
  String generateClockConstraintPy({
    required double coreClkMhz,
    required double ddrCtrlMhz,
  }) {
    final coreTarget = (coreClkMhz * 1.4);
    final ddrTarget = (ddrCtrlMhz * 1.25);
    final buf = StringBuffer();
    buf.writeln('# --pre-pack over-constraint for the PLL/BUFG-derived clocks');
    buf.writeln(
      '# that nextpnr-xilinx leaves UNCONSTRAINED (create_clock does',
    );
    buf.writeln('# not cross the PLL). Targets are ABOVE the real rate for');
    buf.writeln('# derate margin. Confirm each took: the report must read');
    buf.writeln(
      '# "Max frequency for clock \'NAME\': X MHz (... at <target>)".',
    );
    buf.writeln('for net, mhz in [');
    buf.writeln(
      "    ('O', ${coreTarget.toStringAsFixed(2)}),"
      '  # core, real ~${coreClkMhz.toStringAsFixed(1)} MHz',
    );
    buf.writeln(
      "    ('ddr_clk', ${ddrTarget.toStringAsFixed(2)}),"
      '  # DDR controller, real ~${ddrCtrlMhz.toStringAsFixed(1)} MHz',
    );
    buf.writeln(']:');
    buf.writeln('    try:');
    buf.writeln('        ctx.addClock(net, mhz)');
    buf.writeln("        print('ADDCLOCK %s -> %.2f MHz' % (net, mhz))");
    buf.writeln('    except Exception as e:');
    buf.writeln("        print('ADDCLOCK %s FAILED: %s' % (net, e))");
    return buf.toString();
  }

  /// Generates the nextpnr-xilinx `--pre-route` BEL-placement diagnostic
  /// (`support/nextpnr/show_bels.py`) for the openXC7 DDR3 flow. It prints
  /// where the train SERDES landed after placement so a bad pin is visible.
  String generateDdrShowBelsPy() {
    final buf = StringBuffer();
    buf.writeln('def show(name_part):');
    buf.writeln('    found=False');
    buf.writeln('    for c in ctx.cells:');
    buf.writeln('        if name_part in c.first:');
    buf.writeln(
      '            print("BELCHK", c.first, "->", c.second.bel); found=True',
    );
    buf.writeln('    if not found: print("BELCHK none:", name_part)');
    buf.writeln("show('ISERDESE2_train')");
    buf.writeln("show('OSERDESE2_train')");
    return buf.toString();
  }

  /// Generates a complete Makefile for the FPGA build flow.
  String generateMakefile(String topCell) {
    final buf = StringBuffer();
    buf.writeln('# Auto-generated Makefile for $name');
    buf.writeln('TOP = $topCell');
    buf.writeln('DEVICE = $device');
    buf.writeln('PACKAGE = $package');
    buf.writeln();
    buf.writeln('SV_FILES = \$(wildcard rtl/*.sv)');
    buf.writeln();

    // Synthesis
    buf.writeln('.PHONY: all synth pnr pack clean');
    buf.writeln();
    buf.writeln('all: \$(TOP).$bitstreamExtension');
    buf.writeln();
    buf.writeln('synth: \$(TOP).json');
    buf.writeln('\$(TOP).json: \$(SV_FILES)');
    buf.writeln('\tyosys -s synth.tcl');
    buf.writeln();

    // PnR + pack
    final pnrCmd = generateNextpnrCommand(topCell);
    final packCmd = generatePackCommand(topCell);
    if (pnrCmd != null && packCmd != null) {
      final intermediate = vendor == HarborFpgaVendor.ice40
          ? '\$(TOP).asc'
          : '\$(TOP).config';
      buf.writeln(
        '# --pre-place/--pre-route hooks activate only when Harbor emitted the',
      );
      buf.writeln(
        '# scripts, which happens when a peripheral contributed a fragment.',
      );
      buf.writeln(
        '# Both are empty otherwise, so a plain design is unaffected.',
      );
      buf.writeln(
        'PREPLACE := \$(if \$(wildcard support/nextpnr/constraints.py),'
        '--pre-place support/nextpnr/constraints.py,)',
      );
      buf.writeln(
        'PREROUTE := \$(if \$(wildcard support/nextpnr/show_bels.py),'
        '--pre-route support/nextpnr/show_bels.py,)',
      );
      buf.writeln();
      buf.writeln('pnr: $intermediate');
      buf.writeln('$intermediate: \$(TOP).json \$(TOP).$constraintExtension');
      buf.writeln('\t$pnrCmd \$(PREPLACE) \$(PREROUTE)');
      buf.writeln();
      buf.writeln('pack: \$(TOP).$bitstreamExtension');
      buf.writeln('\$(TOP).$bitstreamExtension: $intermediate');
      buf.writeln('\t$packCmd');
    } else if (vendor == HarborFpgaVendor.openXc7) {
      // openXC7 (nextpnr-xilinx + prjxray) flow: json -> fasm -> frames -> bit.
      // The tools nextpnr-xilinx / fasm2frames / xc7frames2bit are assumed on
      // PATH in the dev shell; the data files come from Make variables the
      // caller (nix/user) can override with `?=`.
      buf.writeln();
      buf.writeln(
        '# openXC7 (nextpnr-xilinx + prjxray) place-and-route + pack.',
      );
      buf.writeln(
        '# CHIPDB / XRAY_DB / PART / SEED are overridable (nix supplies them).',
      );
      buf.writeln(
        '# Default CHIPDB is the nextpnr-xilinx chipdb for this device/package.',
      );
      buf.writeln(
        'CHIPDB ?= \$(NEXTPNR_XILINX_CHIPDB)/\$(DEVICE)\$(PACKAGE).bin',
      );
      buf.writeln('XRAY_DB ?= \$(PRJXRAY_DB)');
      buf.writeln('PART ?= \$(DEVICE)\$(PACKAGE)-1');
      buf.writeln('FAMILY = $_prjxrayFamily');
      buf.writeln('SEED ?= 1');
      buf.writeln(
        '# nextpnr-xilinx has no --threads flag, but it links OpenMP, so the',
      );
      buf.writeln(
        '# thread count is set through OMP_NUM_THREADS on the pnr command below.',
      );
      buf.writeln(
        '# Defaults to all host cores; override with e.g. THREADS=8.',
      );
      buf.writeln('THREADS ?= \$(shell nproc)');
      buf.writeln(
        '# nextpnr placer: heap (analytical, default) or sa (annealing). heap is',
      );
      buf.writeln(
        '# usually better on dense designs but its legalization is single-'
        'threaded and slow; sa is an alternative when heap stalls.',
      );
      buf.writeln('PLACER ?= heap');
      buf.writeln(
        '# --pre-place/--pre-route hooks activate only when Harbor emitted the',
      );
      buf.writeln(
        '# matching script (openXC7 + DDR peripheral, or any peripheral that',
      );
      buf.writeln(
        '# contributes a fragment); empty otherwise. The two are tested apart,',
      );
      buf.writeln(
        '# so a design with a pre-place script but no BEL dump still routes.',
      );
      buf.writeln(
        'PREPLACE := \$(if \$(wildcard support/nextpnr/constraints.py),'
        '--pre-place support/nextpnr/constraints.py,)',
      );
      buf.writeln(
        'PREROUTE := \$(if \$(wildcard support/nextpnr/show_bels.py),'
        '--pre-route support/nextpnr/show_bels.py,)',
      );
      buf.writeln(
        '# --pre-pack over-constrains the PLL/BUFG-derived clocks (which',
      );
      buf.writeln(
        '# nextpnr leaves unconstrained); --timing-allow-fail still writes a',
      );
      buf.writeln('# bitstream when the aggressive target is not met.');
      buf.writeln(
        'PREPACK := \$(if \$(wildcard support/nextpnr/clocks.py),'
        '--pre-pack support/nextpnr/clocks.py --timing-allow-fail,)',
      );
      buf.writeln();
      buf.writeln('pnr: \$(TOP).fasm');
      buf.writeln('\$(TOP).fasm: \$(TOP).json \$(TOP).$constraintExtension');
      buf.writeln(
        '\tOMP_NUM_THREADS=\$(THREADS) nextpnr-xilinx --chipdb \$(CHIPDB) '
        '--xdc \$(TOP).$constraintExtension '
        '--json \$(TOP).json --write \$(TOP)_routed.json --fasm \$(TOP).fasm '
        '\$(PREPACK) \$(PREPLACE) \$(PREROUTE) --placer \$(PLACER) '
        '--seed \$(SEED)',
      );
      buf.writeln();
      buf.writeln('pack: \$(TOP).$bitstreamExtension');
      buf.writeln('\$(TOP).frames: \$(TOP).fasm');
      buf.writeln(
        '\tfasm2frames --db-root \$(XRAY_DB)/\$(FAMILY) --part \$(PART) '
        '\$(TOP).fasm \$(TOP).frames',
      );
      buf.writeln('\$(TOP).$bitstreamExtension: \$(TOP).frames');
      buf.writeln(
        '\txc7frames2bit --part_file \$(XRAY_DB)/\$(FAMILY)/\$(PART)/part.yaml '
        '--part_name \$(PART) --frm_file \$(TOP).frames '
        '--output_file \$(TOP).$bitstreamExtension',
      );
    }

    // Bitstream programming (loads the board over USB/JTAG).
    if (progCommand != null) {
      buf.writeln();
      buf.writeln('.PHONY: prog');
      buf.writeln('prog: all');
      buf.writeln('\t$progCommand');
    }

    buf.writeln();
    buf.writeln('clean:');
    buf.writeln(
      '\trm -f \$(TOP).json \$(TOP).asc \$(TOP).config '
      '\$(TOP).fasm \$(TOP).frames \$(TOP)_routed.json '
      '\$(TOP).bin \$(TOP).bit',
    );
    return buf.toString();
  }

  /// Generates a pin constraint file in the vendor's format.
  ///
  /// - iCE40: `.pcf` (Physical Constraints File)
  /// - ECP5: `.lpf` (Lattice Preference File)
  /// - Xilinx: `.xdc` (Xilinx Design Constraints)
  /// [knownPorts] is the set of top-level port base-names the design actually
  /// has. When given, a [pinMap] entry whose port is not among them is skipped:
  /// a board defines pins for every connector it carries (e.g. an unused HDMI
  /// header), but a constraint for a port the netlist does not expose makes the
  /// place-and-route tool reject the design. When null, every pin is emitted.
  String generateConstraints({Set<String>? knownPorts}) {
    switch (vendor) {
      case HarborFpgaVendor.ice40:
        return _generatePcf(knownPorts);
      case HarborFpgaVendor.ecp5:
        return _generateLpf(knownPorts);
      case HarborFpgaVendor.vivado:
      case HarborFpgaVendor.openXc7:
        return _generateXdc(knownPorts);
    }
  }

  /// A pin key may carry a bus index (`sdram_dq[0]`); the port it belongs to is
  /// the base name (`sdram_dq`). Strip the index before checking [knownPorts].
  static String _portBaseName(String pinKey) {
    final b = pinKey.indexOf('[');
    return b < 0 ? pinKey : pinKey.substring(0, b);
  }

  /// Whether a [pinMap] entry should be emitted: always when [knownPorts] is
  /// null, else only if the design exposes the pin's port.
  static bool _emitPin(String pinKey, Set<String>? knownPorts) =>
      knownPorts == null || knownPorts.contains(_portBaseName(pinKey));

  /// A pin map value is the site name, optionally followed by
  /// whitespace-separated IO attributes (e.g. `"C17 SSTL135_I
  /// TERMINATION=OFF"`). The site is always the first token.
  static String _site(String value) => value.trim().split(RegExp(r'\s+')).first;

  /// The IO attributes of a pin map value (everything after the site).
  static List<String> _ioAttrs(String value) =>
      value.trim().split(RegExp(r'\s+')).skip(1).toList();

  /// Writes [extraConstraints] at the end of a constraint file, as a delimited
  /// block of lines that do not change.
  ///
  /// [family] names the constraint language for a person who reads the
  /// generated file. PCF, LPF and XDC all start a comment with `#`.
  void _writeExtraConstraints(StringBuffer buf, String family) {
    if (extraConstraints.isEmpty) return;
    buf.writeln('# BEGIN extraConstraints (raw $family lines)');
    for (final line in extraConstraints.values) {
      buf.writeln(line);
    }
    buf.writeln('# END extraConstraints');
  }

  String _generatePcf(Set<String>? knownPorts) {
    final buf = StringBuffer();
    buf.writeln('# Auto-generated PCF for $name');
    for (final entry in pinMap.entries) {
      if (!_emitPin(entry.key, knownPorts)) continue;
      buf.writeln('set_io ${entry.key} ${_site(entry.value)}');
    }
    if (frequency > 0) {
      final clkPin = pinMap[clockPortName];
      if (clkPin != null) {
        buf.writeln('set_frequency $clockPortName ${frequency / 1e6}');
      }
    }
    _writeExtraConstraints(buf, 'PCF');
    return buf.toString();
  }

  /// ECP5 CSFBGA285 ball -> I/O bank, for the DDR3 SSTL135 banks only (the rest
  /// of the package returns null = not a tracked DDR bank). VERIFIED against the
  /// nextpnr iodb / PnR VREF assignment for the OrangeCrab creek_ddrlevel build:
  /// "Using pin C15 as VREF for bank 7" and "Using pin H15 as VREF for bank 6" -
  /// the DQ/DQS input banks are 6 (lane1) and 7 (lane0). VREF is auto-selected by
  /// nextpnr for SSTL135_I, so only the VCCIO declaration is needed.
  ///
  /// Bank 7 carries lane-0 DQ/DQS (balls A13..A17, B13..B17, C16..C17, D15..D16,
  /// + B15 DQS0, C15 VREF). Bank 6 carries lane-1 DQ/DQS (F15..F18, G15..G18,
  /// H16, J16, C18, + G18 DQS1, H15 VREF). Mapped by the ball's row letter +
  /// column band, with the verified per-ball EXCEPTIONS that the row split gets
  /// wrong (C18 is a bank-6 lane-1 DQ ball, NOT bank 7 despite row C).
  static int? _ddrBankOf(String ball) {
    final m = RegExp(r'^([A-Z])(\d+)$').firstMatch(ball);
    if (m == null) return null;
    final row = m.group(1)!;
    final col = int.parse(m.group(2)!);
    if (col < 13) return null; // cmd/addr (SSTL outputs, no VREF) - not tracked
    // Verified per-ball exceptions to the row split (from the iodb / litex
    // OrangeCrab pinout): C18 is a lane-1 DQ ball in bank 6, not bank 7.
    if (ball == 'C18') return 6;
    // Right edge, columns 13..18: rows A..D -> bank 7, rows E..L -> bank 6.
    if ('ABCD'.contains(row)) return 7;
    if ('EFGHJKL'.contains(row)) return 6;
    return null;
  }

  String _generateLpf(Set<String>? knownPorts) {
    final buf = StringBuffer();
    buf.writeln('# Auto-generated LPF for $name');
    // Collect the DDR SSTL135 banks (from the DQ/DQS input pins) so each gets a
    // single VCCIO declaration. The SSTL135 input threshold is referenced to
    // VCCIO/2. Without an explicit BANK VCCIO the threshold is left undefined
    // (litex/Lattice ECP5 DDR3 lpf always sets it). Deduped, emitted once.
    final ddrBanks = <int>{};
    for (final entry in pinMap.entries) {
      if (!_emitPin(entry.key, knownPorts)) continue;
      final attrs = _ioAttrs(entry.value);
      final ioType = attrs.where((a) => !a.contains('=')).firstOrNull;
      if (ioType != null && ioType.startsWith('SSTL135')) {
        final bank = _ddrBankOf(_site(entry.value));
        if (bank != null) ddrBanks.add(bank);
      }
    }
    for (final bank in ddrBanks.toList()..sort()) {
      buf.writeln('BANK $bank VCCIO 1.35 V;');
    }
    for (final entry in pinMap.entries) {
      if (!_emitPin(entry.key, knownPorts)) continue;
      final attrs = _ioAttrs(entry.value);
      // A bare IO type may be given as the first attribute. Anything with
      // an '=' passes through verbatim (TERMINATION, DIFFRESISTOR, ...).
      final ioType = attrs.where((a) => !a.contains('=')).firstOrNull;
      final extras = attrs.where((a) => a.contains('=')).join(' ');
      buf.writeln('LOCATE COMP "${entry.key}" SITE "${_site(entry.value)}";');
      buf.writeln(
        'IOBUF PORT "${entry.key}" IO_TYPE=${ioType ?? 'LVCMOS33'}'
        '${extras.isEmpty ? '' : ' $extras'};',
      );
    }
    if (frequency > 0) {
      buf.writeln(
        'FREQUENCY PORT "$clockPortName" '
        '${(frequency / 1e6).toStringAsFixed(1)} MHz;',
      );
    }
    _writeExtraConstraints(buf, 'LPF');
    return buf.toString();
  }

  String _generateXdc(Set<String>? knownPorts) {
    final buf = StringBuffer();
    buf.writeln('# Auto-generated XDC for $name');
    for (final entry in pinMap.entries) {
      if (!_emitPin(entry.key, knownPorts)) continue;
      final attrs = _ioAttrs(entry.value);
      final ioStandard = attrs.where((a) => !a.contains('=')).firstOrNull;
      // No braces around the port name in get_ports: the open-source
      // nextpnr-xilinx XDC parser rejects `[get_ports {name}]` (asserts on the
      // brace token), unlike Vivado which accepts either form.
      buf.writeln(
        'set_property -dict {PACKAGE_PIN ${_site(entry.value)} '
        'IOSTANDARD ${ioStandard ?? 'LVCMOS33'}} '
        '[get_ports ${entry.key}]',
      );
    }
    if (frequency > 0) {
      final periodNs = 1e9 / frequency;
      buf.writeln(
        'create_clock -period ${periodNs.toStringAsFixed(3)} '
        '[get_ports $clockPortName]',
      );
    }
    // Extra raw XDC lines (values written verbatim). Used for openXC7 clock-BEL
    // placement constraints the auto placer gets wrong, e.g. pinning the DDR3
    // PHY's regional clock buffers (BUFHCE) into the DDR bank's clock region so
    // the BUFG->BUFH dedicated arc routes (nextpnr-xilinx otherwise places them
    // in the wrong clock region and the dedicated clock router rejects the arc).
    // The key is a label only, the value is the full XDC line.
    _writeExtraConstraints(buf, 'XDC');
    return buf.toString();
  }
}

/// DDR train-SERDES pre-place tile geometry for one FPGA part (openXC7 flow).
///
/// See [HarborFpgaTarget.generateDdrPreplacePy]. Lane `l`'s OSERDESE2/ISERDESE2
/// pair pins to `X<column>Y<baseY + l*strideY>`.
class _DdrPreplaceGeom {
  /// OLOGIC/ILOGIC tile Y for lane 0.
  final int baseY;

  /// Per-lane Y delta (negative descends the tile column).
  final int strideY;

  /// OLOGIC/ILOGIC tile X column.
  final int column;

  const _DdrPreplaceGeom({
    required this.baseY,
    required this.strideY,
    required this.column,
  });
}

/// Describes a macro/tile module for hierarchical hardening.
///
/// Each macro is synthesized and placed-and-routed independently,
/// then placed as a hard macro in the top-level chip assembly.
class HarborAsicMacro {
  /// Module name in the RTL hierarchy.
  final String moduleName;

  /// Utilization target for this macro's internal placement.
  final double utilization;

  /// Halo spacing around this macro in the top-level layout (um).
  final double haloUm;

  /// Pin placement on all 4 edges for grid connectivity.
  final bool pinOnAllEdges;

  const HarborAsicMacro({
    required this.moduleName,
    this.utilization = 0.6,
    this.haloUm = 10.0,
    this.pinOnAllEdges = true,
  });
}

/// ASIC tapeout target with PDK configuration.
///
/// Supports two flows:
/// - **Flat**: entire design synthesized and placed at once
/// - **Hierarchical**: specified modules are hardened as macros first,
///   then assembled into the top-level chip (like Aegis tile flow)
///
/// The emitted synth/PnR TCL is driven by `asix.mkTapeout`: PDK paths and
/// floorplan knobs are read from environment variables (LIB_FILE, TECH_LEF,
/// CELL_LEF_DIR, SYNTH_V, SDC_FILE, SITE_NAME, UTILIZATION, etc.) rather than
/// baked into the script, and RTL is read relative to the script via
/// `[info script]`. Cell *names* (tie/fill/clock-buffer) stay baked from the
/// [PdkProvider]. Knobs that asix also owns ([utilization], [frequency]) act as
/// defaults only: asix's matching args take precedence at build time.
///
/// ```dart
/// final target = HarborAsicTarget(
///   provider: Sky130Provider(pdkRoot: '/path/to/sky130A'),
///   topCell: 'MySoC',
///   frequency: 50000000,
///   macros: [
///     HarborAsicMacro(moduleName: 'RiverCore'),
///     HarborAsicMacro(moduleName: 'L2Cache'),
///   ],
/// );
/// ```
class HarborAsicTarget extends HarborDeviceTarget {
  @override
  String get name => '${provider.name}-${provider.node}';

  /// The PDK provider supplying cell libraries, analog blocks, etc.
  final PdkProvider provider;

  /// Top-level cell name for synthesis.
  final String topCell;

  /// Target clock frequency in Hz.
  ///
  /// Drives [generateSdc] for standalone/FPGA use. Under `asix.mkTapeout` the
  /// constraints come from asix's own `clockPeriodNs` (it generates its own
  /// `constraints.sdc` and points `SDC_FILE` at it), so keep the two in sync.
  final int frequency;

  /// Utilization target for placement (0.0 to 1.0).
  ///
  /// Advisory under `asix.mkTapeout`: the PnR script reads `UTILIZATION` from
  /// the env (asix's `coreUtilization`), so this value is the default rather
  /// than the build-time effective one.
  final double utilization;

  /// Modules to harden as macros before top-level assembly.
  ///
  /// Empty list = flat flow (no hierarchical hardening).
  final List<HarborAsicMacro> macros;

  /// Margin around the die edge in um.
  final double dieMarginUm;

  /// Minimum metal layer for top-level routing (skip lower layers
  /// used internally by macros to avoid DRC violations).
  final int topRoutingMinLayer;

  /// IO ring configuration (null = no IO ring generation).
  final HarborIoRing? ioRing;

  /// KLayout scripts configuration (null = no KLayout scripts).
  final HarborKlayoutDrcConfig? klayoutDrc;

  /// Analog GDS files to merge into the final layout.
  final List<String> analogGdsPaths;

  const HarborAsicTarget({
    required this.provider,
    required this.topCell,
    this.frequency = 0,
    this.utilization = 0.5,
    this.macros = const [],
    this.dieMarginUm = 200.0,
    this.topRoutingMinLayer = 2,
    this.ioRing,
    this.klayoutDrc,
    this.analogGdsPaths = const [],
  });

  /// Whether this uses hierarchical macro hardening.
  bool get isHierarchical => macros.isNotEmpty;

  /// Generates an SDC timing constraints file.
  ///
  /// Used by the FPGA/standalone flows. `asix.mkTapeout` ignores this and
  /// generates its own `constraints.sdc` from `clockPeriodNs`, pointing the
  /// PnR script's `SDC_FILE` env var at it.
  String generateSdc() {
    final buf = StringBuffer();
    buf.writeln('# Auto-generated SDC for $name');
    if (frequency > 0) {
      final periodNs = 1e9 / frequency;
      buf.writeln(
        'create_clock -name clk -period ${periodNs.toStringAsFixed(3)} '
        '[get_ports {clk}]',
      );
    }
    buf.writeln('set_input_delay 0 -clock clk [all_inputs]');
    buf.writeln('set_output_delay 0 -clock clk [all_outputs]');
    return buf.toString();
  }

  /// Generates a Yosys synthesis TCL script for the top-level design.
  ///
  /// In hierarchical mode, macro modules are replaced with blackbox
  /// stubs so only the glue logic is synthesized at the top level.
  String generateYosysTcl() {
    final lib = provider.standardCellLibrary;
    final buf = StringBuffer();
    buf.writeln('# Auto-generated Yosys synthesis for $topCell');
    buf.writeln('# PDK: ${provider.name}');
    buf.writeln(
      '# Run by asix.mkTapeout (yosys -c). The standard-cell liberty',
    );
    buf.writeln(
      '# comes from \$::env(LIB_FILE); RTL/stubs are read relative to',
    );
    buf.writeln(
      '# this script via [info script] so the flow is location-agnostic.',
    );
    if (isHierarchical) {
      buf.writeln('# Mode: hierarchical (${macros.length} macros)');
    }
    buf.writeln();
    buf.writeln('set ipdir [file dirname [info script]]');
    buf.writeln('read_verilog -sv \$ipdir/rtl/*.sv');

    // Read blackbox stubs for hard macros (SRAM, etc.)
    buf.writeln('read_verilog -lib \$ipdir/blackboxes.v');

    // In hierarchical mode, replace macros with blackbox stubs
    if (isHierarchical) {
      buf.writeln();
      buf.writeln('# Replace hardened macros with blackbox stubs');
      buf.writeln('read_verilog \$::env(STUBS_V)');
      for (final macro in macros) {
        buf.writeln('blackbox ${macro.moduleName}');
      }
      buf.writeln();
    }

    buf.writeln('hierarchy -top $topCell -keep_portwidths');
    buf.writeln('synth -top $topCell');
    buf.writeln('dfflibmap -liberty \$::env(LIB_FILE)');
    buf.writeln('abc -liberty \$::env(LIB_FILE)');
    buf.writeln(
      'hilomap -hicell ${lib.tieHighCell} Z '
      '-locell ${lib.tieLowCell} ZN',
    );
    buf.writeln('opt_clean -purge');
    buf.writeln('write_verilog -noattr ${topCell}_synth.v');
    buf.writeln('stat -liberty \$::env(LIB_FILE)');
    return buf.toString();
  }

  /// Generates a Yosys synthesis TCL script for a single macro module.
  ///
  /// Used in hierarchical flow to harden each macro independently.
  String generateMacroYosysTcl(HarborAsicMacro macro) {
    final lib = provider.standardCellLibrary;
    final buf = StringBuffer();
    buf.writeln(
      '# Auto-generated Yosys synthesis for macro: ${macro.moduleName}',
    );
    buf.writeln('# PDK: ${provider.name}');
    buf.writeln(
      '# Run by asix.mkTapeout (yosys -c); liberty from \$::env(LIB_FILE),',
    );
    buf.writeln(
      '# RTL read relative to this script. Macro scripts live in the',
    );
    buf.writeln('# ip macros/ subdir, so rtl/ is one level up from here.');
    buf.writeln();
    buf.writeln('set iproot [file dirname [file dirname [info script]]]');
    buf.writeln('read_verilog -sv \$iproot/rtl/*.sv');
    buf.writeln('hierarchy -top ${macro.moduleName}');
    buf.writeln('synth -top ${macro.moduleName} -flatten');
    buf.writeln('dfflibmap -liberty \$::env(LIB_FILE)');
    buf.writeln('abc -liberty \$::env(LIB_FILE)');
    buf.writeln(
      'hilomap -hicell ${lib.tieHighCell} Z '
      '-locell ${lib.tieLowCell} ZN',
    );
    buf.writeln('opt_clean -purge');
    buf.writeln('write_verilog -noattr ${macro.moduleName}_synth.v');
    buf.writeln('stat -liberty \$::env(LIB_FILE)');
    return buf.toString();
  }

  /// Generates an OpenROAD PnR script for a single macro (tile hardening).
  ///
  /// Produces three outputs per macro:
  /// - `<macro>_final.def`: routed layout
  /// - `<macro>.lef`: LEF abstract for top-level placement
  /// - `<macro>.lib`: Liberty timing model for top-level STA
  String generateMacroOpenroadTcl(HarborAsicMacro macro) {
    final lib = provider.standardCellLibrary;
    final m = macro.moduleName;
    final buf = StringBuffer();
    buf.writeln('# Auto-generated OpenROAD macro hardening for $m');
    buf.writeln('# PDK: ${provider.name}');
    buf.writeln(
      '# Run by asix.mkTapeout (openroad -exit). Liberty/LEF come from',
    );
    buf.writeln(
      '# the env (LIB_FILE/TECH_LEF/CELL_LEF_DIR); utilization is the',
    );
    buf.writeln(
      '# per-tile TILE_UTIL. asix provides no macro SDC, so timing is',
    );
    buf.writeln('# left unconstrained at the tile level.');
    buf.writeln();

    // Read inputs (paths supplied by asix via env vars)
    buf.writeln('read_liberty \$::env(LIB_FILE)');
    buf.writeln(
      'if {[info exists ::env(TECH_LEF)] && \$::env(TECH_LEF) ne ""} {',
    );
    buf.writeln('    read_lef \$::env(TECH_LEF)');
    buf.writeln('}');
    buf.writeln(
      'foreach _lef [lsort [glob -nocomplain \$::env(CELL_LEF_DIR)/*.lef]] {',
    );
    buf.writeln(
      '    if {[string match *tech* [file tail \$_lef]]} { continue }',
    );
    buf.writeln('    read_lef \$_lef');
    buf.writeln('}');
    buf.writeln('read_verilog ${m}_synth.v');
    buf.writeln('link_design $m');
    buf.writeln();

    // Floorplan
    buf.writeln('initialize_floorplan \\');
    buf.writeln('    -utilization \$::env(TILE_UTIL) \\');
    buf.writeln('    -core_space 2 \\');
    buf.writeln('    -site \$::env(SITE_NAME)');
    buf.writeln();

    // Pin placement on all edges for grid connectivity
    if (macro.pinOnAllEdges) {
      buf.writeln('# Place pins on all edges for macro connectivity');
      buf.writeln('place_pins -hor_layers Metal3 -ver_layers Metal2');
      buf.writeln();
    }

    // Power
    buf.writeln('add_global_connection -net VDD -pin_pattern VDD -power');
    buf.writeln('add_global_connection -net VSS -pin_pattern VSS -ground');
    buf.writeln('global_connect');
    buf.writeln();

    // Placement
    buf.writeln('global_placement -density \$::env(TILE_UTIL)');
    buf.writeln('detailed_placement');
    buf.writeln();

    // CTS
    if (lib.clockBufferCells.isNotEmpty) {
      buf.writeln('estimate_parasitics -placement');
      buf.writeln(
        'clock_tree_synthesis -buf_list '
        '{${lib.clockBufferCells.join(" ")}}',
      );
      buf.writeln('detailed_placement');
      buf.writeln();
    }

    // Routing
    buf.writeln('global_route -allow_congestion');
    buf.writeln('detailed_route');
    buf.writeln();

    // Fill
    if (lib.fillCells.isNotEmpty) {
      buf.writeln('filler_placement ${lib.fillCells.join(" ")}');
      buf.writeln();
    }

    // Output macro artifacts
    buf.writeln('# Macro outputs');
    buf.writeln('write_def ${m}_final.def');
    buf.writeln('write_abstract_lef ${m}.lef');
    buf.writeln('write_timing_model ${m}.lib');
    buf.writeln();
    buf.writeln('report_checks -path_delay min_max > ${m}_timing.rpt');
    buf.writeln('report_design_area > ${m}_area.rpt');

    return buf.toString();
  }

  /// Generates an OpenROAD place-and-route TCL script for the top level.
  ///
  /// In hierarchical mode, reads pre-hardened macro LEF/LIB files
  /// and places them with halos. Routes only on upper metal layers
  /// to avoid DRC violations with macro-internal routing.
  String generateOpenroadTcl() {
    final lib = provider.standardCellLibrary;
    final buf = StringBuffer();
    buf.writeln('# Auto-generated OpenROAD P&R for $topCell');
    buf.writeln('# PDK: ${provider.name}');
    buf.writeln('# Run by asix.mkTapeout (openroad -exit). All PDK paths and');
    buf.writeln('# floorplan knobs come from the env: LIB_FILE/TECH_LEF/');
    buf.writeln('# CELL_LEF_DIR/SYNTH_V/SDC_FILE/SITE_NAME/UTILIZATION/');
    buf.writeln(
      '# MACRO_HALO/PLACEMENT_DENSITY/DROUTE_END_ITER (+optional DIE_AREA).',
    );
    if (isHierarchical) {
      buf.writeln(
        '# Mode: hierarchical assembly '
        '(${macros.length} pre-hardened macros)',
      );
    }
    buf.writeln();

    // Read inputs (paths supplied by asix via env vars). The tech LEF is read
    // explicitly, then every other cell LEF is globbed from CELL_LEF_DIR while
    // skipping anything that looks like the tech LEF (avoids a double read).
    buf.writeln('read_liberty \$::env(LIB_FILE)');
    buf.writeln(
      'if {[info exists ::env(TECH_LEF)] && \$::env(TECH_LEF) ne ""} {',
    );
    buf.writeln('    read_lef \$::env(TECH_LEF)');
    buf.writeln('}');
    buf.writeln(
      'foreach _lef [lsort [glob -nocomplain \$::env(CELL_LEF_DIR)/*.lef]] {',
    );
    buf.writeln(
      '    if {[string match *tech* [file tail \$_lef]]} { continue }',
    );
    buf.writeln('    read_lef \$_lef');
    buf.writeln('}');

    // Read macro LEF/LIB in hierarchical mode (asix copies these into the CWD)
    if (isHierarchical) {
      buf.writeln();
      buf.writeln('# Read hardened macro abstracts');
      for (final macro in macros) {
        buf.writeln('read_lef ${macro.moduleName}.lef');
        buf.writeln('read_liberty ${macro.moduleName}.lib');
      }
    }

    buf.writeln();
    buf.writeln('read_verilog \$::env(SYNTH_V)');
    buf.writeln('link_design $topCell');
    buf.writeln('read_sdc \$::env(SDC_FILE)');
    buf.writeln();

    // Floorplan: a fixed DIE_AREA (fab-slot tapeouts) takes precedence over a
    // utilization-driven auto floorplan. The core is inset from the die by the
    // die margin on every side.
    buf.writeln('if {[info exists ::env(DIE_AREA)]} {');
    buf.writeln('    lassign \$::env(DIE_AREA) _dx0 _dy0 _dx1 _dy1');
    buf.writeln('    set _m ${dieMarginUm.toStringAsFixed(0)}');
    buf.writeln('    initialize_floorplan \\');
    buf.writeln('        -die_area "\$_dx0 \$_dy0 \$_dx1 \$_dy1" \\');
    buf.writeln(
      '        -core_area "[expr {\$_dx0 + \$_m}] [expr {\$_dy0 + \$_m}] [expr {\$_dx1 - \$_m}] [expr {\$_dy1 - \$_m}]" \\',
    );
    buf.writeln('        -site \$::env(SITE_NAME)');
    buf.writeln('} else {');
    buf.writeln('    initialize_floorplan \\');
    buf.writeln('        -utilization \$::env(UTILIZATION) \\');
    buf.writeln('        -core_space ${dieMarginUm.toStringAsFixed(0)} \\');
    buf.writeln('        -site \$::env(SITE_NAME)');
    buf.writeln('}');
    buf.writeln();

    // Macro placement with halos (halo width supplied by asix as MACRO_HALO)
    if (isHierarchical) {
      buf.writeln('# Macro placement with halos');
      for (final macro in macros) {
        buf.writeln(
          'set_macro_halo -halo_x \$::env(MACRO_HALO) '
          '-halo_y \$::env(MACRO_HALO) '
          '[get_cells -hierarchical -filter "ref_name == ${macro.moduleName}"]',
        );
      }
      buf.writeln('macro_placement');
      buf.writeln();
    }

    // Power
    buf.writeln('add_global_connection -net VDD -pin_pattern VDD -power');
    buf.writeln('add_global_connection -net VSS -pin_pattern VSS -ground');
    buf.writeln('global_connect');
    buf.writeln();

    // Placement (density supplied by asix as PLACEMENT_DENSITY)
    buf.writeln('global_placement -density \$::env(PLACEMENT_DENSITY)');
    buf.writeln('detailed_placement');
    buf.writeln();

    // CTS
    if (lib.clockBufferCells.isNotEmpty) {
      buf.writeln('estimate_parasitics -placement');
      buf.writeln(
        'clock_tree_synthesis -buf_list '
        '{${lib.clockBufferCells.join(" ")}}',
      );
      buf.writeln('detailed_placement');
      buf.writeln();
    }

    // Routing: skip lower metal layers in hierarchical mode
    if (isHierarchical && topRoutingMinLayer > 1) {
      buf.writeln(
        '# Skip Metal1-${topRoutingMinLayer - 1} '
        '(used internally by macros)',
      );
      buf.writeln(
        'set_global_routing_layer_adjustment '
        'Metal1-Metal${topRoutingMinLayer - 1} 1.0',
      );
    }
    buf.writeln('global_route -allow_congestion');
    buf.writeln('if {[info exists ::env(DROUTE_END_ITER)]} {');
    buf.writeln('    detailed_route -droute_end_iter \$::env(DROUTE_END_ITER)');
    buf.writeln('} else {');
    buf.writeln('    detailed_route');
    buf.writeln('}');
    buf.writeln();

    // Fill
    if (lib.fillCells.isNotEmpty) {
      buf.writeln('filler_placement ${lib.fillCells.join(" ")}');
      buf.writeln();
    }

    // Reports & outputs
    buf.writeln('report_checks -path_delay min_max > timing.rpt');
    buf.writeln('report_design_area > area.rpt');
    buf.writeln('report_power > power.rpt');
    buf.writeln('write_def ${topCell}_final.def');
    buf.writeln('write_verilog ${topCell}_final.v');

    return buf.toString();
  }
}

/// Supported FPGA vendors / toolchains.
enum HarborFpgaVendor {
  /// Lattice iCE40: Yosys + nextpnr-ice40
  ice40,

  /// Lattice ECP5: Yosys + nextpnr-ecp5
  ecp5,

  /// Xilinx Vivado (proprietary)
  vivado,

  /// Xilinx openXC7 (open-source)
  openXc7,
}

/// Verilator simulation target.
///
/// Verilator cannot simulate vendor IP, so this is not an FPGA vendor and not a
/// variant of one: under this target the SoC instantiates NO vendor primitives
/// at all. No PLL, no SERDES, no BSCAN, no PDK memory macro. Clock domains
/// become top-level input ports driven by the generated C++ harness at their
/// configured frequency, so clock-crossing logic is still exercised rather than
/// collapsed onto one clock.
///
/// The emitted Silicon IP Package builds a simulator with `make` the same way
/// an FPGA package builds a bitstream, and keeps the same `.dts`/`.svd`, so the
/// same software images boot against it.
class HarborSimTarget extends HarborDeviceTarget {
  @override
  String get name => 'verilator';

  /// Top-level module name for the Verilated design.
  final String topCell;

  /// Frequency in Hz of the primary input clock. Every other domain is derived
  /// from its own [HarborClockConfig] frequency by the harness clock wheel.
  final int frequency;

  /// Emit FST waveform tracing support. Tracing costs a large constant factor
  /// in run time, so it is opt-in and also gated behind a `--trace` flag in the
  /// generated harness.
  final bool trace;

  /// Verilator's `--trace-depth`. Ignored when [trace] is false.
  final int traceDepth;

  /// Serve the RISC-V debug module over OpenOCD's `remote_bitbang` protocol on
  /// this TCP port. Only takes effect when the SoC has a [HarborJtagDebug]
  /// master; see [generateOpenocdConfig].
  ///
  /// Defaults to [JtagRemote.defaultPort], so the Verilator server and the
  /// ROHD-side [JtagRemote] answer on the same port and one openocd.cfg works
  /// against either simulator.
  final int jtagPort;

  /// Extra Verilator warnings to suppress, on top of the defaults that ROHD
  /// output reliably trips.
  final List<String> extraWarningsOff;

  /// Optimisation level passed to Verilator (`-O3` by default) and to the
  /// generated C++.
  final int optLevel;

  /// Number of runtime threads for the Verilated model (`--threads N`).
  ///
  /// This is the SIM-time thread count, not the build parallelism (which is the
  /// `-j` flag). A value of 1 keeps the single-threaded model, which Verilator
  /// runs with no synchronisation overhead. A value above 1 partitions the
  /// model across that many host threads: useful for a large SoC where a boot
  /// is billions of cycles, but a small design can go slower because the
  /// partition sync costs more than it saves. Clamped to at least 1.
  final int threads;

  const HarborSimTarget({
    this.topCell = 'harbor_soc',
    this.frequency = 100000000,
    this.trace = false,
    this.traceDepth = 99,
    this.jtagPort = JtagRemote.defaultPort,
    this.extraWarningsOff = const [],
    this.optLevel = 3,
    this.threads = 1,
  });

  /// Warnings ROHD-emitted SystemVerilog actually trips, measured by linting a
  /// full SoC (core + fabric + DDR + SDIO) with NO suppressions:
  ///
  /// - `WIDTHEXPAND` (82 hits) and `CASEINCOMPLETE` (21) come from ROHD's
  ///   explicit sizing and its `Case` lowering, not from design bugs.
  /// - `UNOPTFLAT` does not appear in a lint run because it is a `--cc`
  ///   scheduling diagnostic that lint does not analyse. It is kept for the
  ///   combinational ack paths through the bus fabric, and is the one entry
  ///   here still worth re-testing on a full `--cc` build.
  ///
  /// `WIDTHTRUNC`, `UNUSEDSIGNAL`, `UNDRIVEN` and `MULTIDRIVEN` were suppressed
  /// on my guess and never fired once measured, so they are gone: a suppression
  /// nothing needs only hides the day one of them means something.
  static const defaultWarningsOff = [
    'UNOPTFLAT',
    'WIDTHEXPAND',
    'CASEINCOMPLETE',
  ];

  List<String> get warningsOff => [...defaultWarningsOff, ...extraWarningsOff];
}

/// Emission for [HarborSimTarget]: the Verilator build of a Silicon IP Package.
extension HarborSimTargetEmit on HarborSimTarget {
  /// Verilator invocation. Mirrors [HarborFpgaTarget.generateMakefile]: `make`
  /// in the package directory produces the artifact, here a simulator binary
  /// rather than a bitstream.
  String generateMakefile(
    String topName, {
    List<HarborSimModel> models = const [],
  }) {
    final buf = StringBuffer();
    buf.writeln('# Auto-generated Makefile for the Verilator simulation build');
    buf.writeln('TOP = $topCell');
    buf.writeln('SIM = V\$(TOP)');
    buf.writeln('VERILATOR ?= verilator');
    buf.writeln();
    buf.writeln('WARNINGS = ${warningsOff.map((w) => '-Wno-$w').join(' ')}');
    buf.writeln('VFLAGS = --cc --exe --build -j 0 -O$optLevel \\');
    buf.writeln('         --top-module \$(TOP) -f filelist.f \$(WARNINGS) \\');
    buf.writeln('         -CFLAGS "-O$optLevel -std=c++17"');
    // Build flags the host-side models asked for (a graphics backend, a codec).
    // Deduplicated so two instances of one model do not double their flags.
    final cflags = {for (final m in models) ...m.cflags};
    final ldflags = {for (final m in models) ...m.ldflags};
    final packages = {for (final m in models) ...m.pkgConfig};
    if (packages.isNotEmpty) {
      buf.writeln();
      buf.writeln(
        '# Host libraries the simulation models need. Resolved here,',
      );
      buf.writeln('# at build time, so this package carries no host paths.');
      for (final pkg in packages) {
        final variable = pkg.toUpperCase().replaceAll(
          RegExp(r'[^A-Z0-9]'),
          '_',
        );
        buf.writeln(
          '${variable}_CFLAGS := \$(shell pkg-config --cflags $pkg '
          '2>/dev/null)',
        );
        buf.writeln(
          '${variable}_LIBS := \$(shell pkg-config --libs $pkg 2>/dev/null)',
        );
        // An unfound package otherwise expands to empty flags, and the build
        // fails much later with an error that names something else entirely.
        buf.writeln('ifeq (\$(strip \$(${variable}_LIBS)),)');
        buf.writeln(
          '\$(error pkg-config cannot find "$pkg", which a simulation model '
          'needs. Install it, or set PKG_CONFIG_PATH.)',
        );
        buf.writeln('endif');
        buf.writeln('VFLAGS += -CFLAGS "\$(${variable}_CFLAGS)"');
        buf.writeln('VFLAGS += -LDFLAGS "\$(${variable}_LIBS)"');
      }
      buf.writeln();
    }
    if (cflags.isNotEmpty) {
      buf.writeln('VFLAGS += -CFLAGS "${cflags.join(' ')}"');
    }
    if (ldflags.isNotEmpty) {
      buf.writeln('VFLAGS += -LDFLAGS "${ldflags.join(' ')}"');
    }
    final simThreads = threads < 1 ? 1 : threads;
    if (simThreads > 1) {
      // Runtime multi-threading of the Verilated model. This is not the build
      // `-j`; it partitions the simulation across host threads at run time.
      buf.writeln('VFLAGS += --threads $simThreads');
      if (trace) {
        // A threaded model needs a threaded trace writer, or the FST dump
        // serialises the whole model back onto one thread.
        buf.writeln('VFLAGS += --trace-threads $simThreads');
      }
    }
    if (trace) {
      buf.writeln('VFLAGS += --trace-fst --trace-depth $traceDepth');
    }
    buf.writeln();
    buf.writeln('.PHONY: all run clean');
    buf.writeln();
    buf.writeln('all: obj_dir/\$(SIM)');
    buf.writeln();
    buf.writeln(
      'obj_dir/\$(SIM): filelist.f sim/main.cpp \$(wildcard rtl/*.sv)',
    );
    buf.writeln('\t\$(VERILATOR) \$(VFLAGS) sim/main.cpp');
    buf.writeln();
    buf.writeln('run: obj_dir/\$(SIM)');
    buf.writeln('\t./obj_dir/\$(SIM) \$(SIM_ARGS)');
    buf.writeln();
    buf.writeln('clean:');
    buf.writeln('\trm -rf obj_dir');
    return buf.toString();
  }

  /// OpenOCD configuration for the simulated debug module.
  ///
  /// Unlike the FPGA targets there is no config-JTAG TAP and no BSCAN tunnel:
  /// the debug module sits directly on top-level TCK/TMS/TDI/TDO, which the
  /// harness serves over OpenOCD's `remote_bitbang` protocol. So no
  /// `innerIrWidth` and no tunnel stanza.
  String generateOpenocdConfig({int? dmIdcode, String targetName = 'cpu'}) {
    final buf = StringBuffer();
    buf.writeln('# Auto-generated by Harbor. OpenOCD against the Verilator');
    buf.writeln('# simulation over remote_bitbang. Start the simulator first,');
    buf.writeln('# then: openocd -f openocd.cfg');
    buf.writeln();
    buf.writeln('adapter driver remote_bitbang');
    buf.writeln('remote_bitbang host localhost');
    buf.writeln('remote_bitbang port $jtagPort');
    buf.writeln();
    // No real adapter, so the speed setting is advisory only.
    buf.writeln('transport select jtag');
    buf.writeln();
    if (dmIdcode != null) {
      final id = '0x${dmIdcode.toRadixString(16).padLeft(8, '0')}';
      buf.writeln('jtag newtap $targetName tap -irlen 5 -expected-id $id');
    } else {
      buf.writeln('jtag newtap $targetName tap -irlen 5');
    }
    buf.writeln(
      'target create $targetName.0 riscv -chain-position $targetName.tap',
    );
    buf.writeln('init');
    buf.writeln('halt');
    return buf.toString();
  }
}

/// C++ harness emission for [HarborSimTarget].
extension HarborSimTargetHarness on HarborSimTarget {
  /// The Verilated testbench.
  ///
  /// [clockPorts] maps each derived clock's top-level port name to its
  /// frequency in Hz; the primary input clock is added at [frequency]. Each
  /// clock keeps its own next-edge time, so domains genuinely run at different
  /// rates and the crossings are exercised.
  String generateMain({
    required String topCell,
    required Map<String, int> clockPorts,
    List<HarborSimModel> models = const [],
    bool hasJtag = false,
    String resetPort = 'reset',
    String primaryClockPort = 'clk',
    String jtagTckPort = 'jtag_tck',
    String jtagTmsPort = 'jtag_tms',
    String jtagTdiPort = 'jtag_tdi',
    String jtagTdoPort = 'jtag_tdo',
    String jtagTrstPort = 'jtag_trst',
  }) {
    final all = <String, int>{primaryClockPort: frequency, ...clockPorts};
    final b = StringBuffer();

    b.writeln('// Auto-generated Verilator harness for $topCell.');
    b.writeln('// Build with `make`, run with `make run SIM_ARGS="..."`.');
    b.writeln('#include <cstdio>');
    b.writeln('#include <cstdlib>');
    b.writeln('#include <cstring>');
    b.writeln('#include <cstdint>');
    b.writeln('#include "V$topCell.h"');
    b.writeln('#include "verilated.h"');
    if (trace) b.writeln('#include "verilated_fst_c.h"');
    for (final h in {for (final m in models) m.headerPath}) {
      // headerPath is relative to the package root; main.cpp lives in sim/.
      b.writeln('#include "${h.substring('sim/'.length)}"');
    }
    if (hasJtag) {
      b.writeln('#include <arpa/inet.h>');
      b.writeln('#include <fcntl.h>');
      b.writeln('#include <netinet/in.h>');
      b.writeln('#include <netinet/tcp.h>');
      b.writeln('#include <unistd.h>');
    }
    b.writeln();
    b.writeln('static V$topCell* top;');
    for (final m in models) {
      b.writeln(m.declaration);
    }
    b.writeln('static uint64_t time_ps = 0;');
    b.writeln('double sc_time_stamp() { return (double)time_ps; }');
    b.writeln();

    // --- clock wheel -------------------------------------------------------
    b.writeln(
      '// One entry per clock domain. Each advances on its own period,',
    );
    b.writeln('// so the design sees genuinely asynchronous domains.');
    b.writeln('struct ClockPort {');
    b.writeln('  const char* name;');
    b.writeln('  uint64_t half_ps;   // half period');
    b.writeln('  uint64_t next_ps;   // time of the next edge');
    b.writeln('  CData* sig;');
    b.writeln('};');
    b.writeln();
    b.writeln('static ClockPort clocks[] = {');
    for (final e in all.entries) {
      // Half period in ps. 1e12 / (2*f), rounded to at least one ps.
      final halfPs = (1000000000000 / (2 * e.value)).round();
      b.writeln(
        '  {"${e.key}", ${halfPs < 1 ? 1 : halfPs}, 0, nullptr}, '
        '// ${e.value} Hz',
      );
    }
    b.writeln('};');
    b.writeln(
      'static const int kNumClocks = '
      '${all.length};',
    );
    b.writeln();
    b.writeln('static void bindClocks() {');
    var i = 0;
    for (final e in all.entries) {
      b.writeln('  clocks[$i].sig = &top->${e.key};');
      b.writeln('  clocks[$i].next_ps = clocks[$i].half_ps;');
      i++;
    }
    b.writeln('}');
    b.writeln();

    if (hasJtag)
      _emitJtagServer(
        b,
        jtagTckPort,
        jtagTmsPort,
        jtagTdiPort,
        jtagTdoPort,
        jtagTrstPort,
      );

    // --- main --------------------------------------------------------------
    b.writeln('int main(int argc, char** argv) {');
    b.writeln('  Verilated::commandArgs(argc, argv);');
    b.writeln('  uint64_t max_ps = 0;      // 0 = run forever');
    if (trace) b.writeln('  const char* trace_path = nullptr;');
    if (hasJtag) b.writeln('  int jtag_port = $jtagPort;');
    b.writeln('  for (int a = 1; a < argc; a++) {');
    b.writeln('    if (!strncmp(argv[a], "--max-ns=", 9))');
    b.writeln('      max_ps = strtoull(argv[a] + 9, nullptr, 0) * 1000ULL;');
    if (trace) {
      b.writeln('    else if (!strncmp(argv[a], "--trace=", 8))');
      b.writeln('      trace_path = argv[a] + 8;');
    }
    if (hasJtag) {
      b.writeln('    else if (!strncmp(argv[a], "--jtag-port=", 12))');
      b.writeln('      jtag_port = atoi(argv[a] + 12);');
    }
    for (final m in models) {
      final cli = m.cliOption;
      if (cli != null) b.writeln('    $cli');
    }
    b.writeln('  }');
    b.writeln();
    b.writeln('  top = new V$topCell;');
    b.writeln('  bindClocks();');
    if (trace) {
      b.writeln('  VerilatedFstC* tfp = nullptr;');
      b.writeln('  if (trace_path) {');
      b.writeln('    Verilated::traceEverOn(true);');
      b.writeln('    tfp = new VerilatedFstC;');
      b.writeln('    top->trace(tfp, $traceDepth);');
      b.writeln('    tfp->open(trace_path);');
      b.writeln('  }');
    }
    if (hasJtag) {
      b.writeln('  jtagListen(jtag_port);');
      b.writeln('  top->$jtagTrstPort = 0;');
    }
    b.writeln();
    b.writeln(
      '  // Hold reset over several edges of the SLOWEST clock, so every',
    );
    b.writeln(
      '  // domain sees it asserted for at least a few of its own edges.',
    );
    b.writeln('  uint64_t slowest_half = 0;');
    b.writeln('  for (int c = 0; c < kNumClocks; c++)');
    b.writeln(
      '    if (clocks[c].half_ps > slowest_half) '
      'slowest_half = clocks[c].half_ps;',
    );
    b.writeln('  const uint64_t reset_until = slowest_half * 20;');
    b.writeln('  top->$resetPort = 1;');
    b.writeln();
    b.writeln('  while (!Verilated::gotFinish()) {');
    b.writeln('    if (max_ps && time_ps >= max_ps) break;');
    b.writeln(
      '    // Advance to the next edge of whichever clock is due first.',
    );
    b.writeln('    uint64_t next = UINT64_MAX;');
    b.writeln('    for (int c = 0; c < kNumClocks; c++)');
    b.writeln('      if (clocks[c].next_ps < next) next = clocks[c].next_ps;');
    b.writeln('    time_ps = next;');
    b.writeln('    bool toggled[kNumClocks] = {false};');
    b.writeln('    for (int c = 0; c < kNumClocks; c++) {');
    b.writeln('      if (clocks[c].next_ps != time_ps) continue;');
    b.writeln('      *clocks[c].sig = !*clocks[c].sig;');
    b.writeln('      clocks[c].next_ps += clocks[c].half_ps;');
    b.writeln('      toggled[c] = true;');
    b.writeln('    }');
    b.writeln(
      '    if (top->$resetPort && time_ps >= reset_until) '
      'top->$resetPort = 0;',
    );
    b.writeln('    top->eval();');
    if (models.isNotEmpty) {
      b.writeln(
        '    // Host-side models, on the edges of the clock domain each',
      );
      b.writeln('    // one declared. Gated on the clock having actually');
      b.writeln(
        '    // toggled this iteration: another domain\'s edge must not',
      );
      b.writeln(
        '    // tick a model whose own clock merely happens to be high.',
      );
      final ports = all.keys.toList();
      final byClock = <String, List<HarborSimModel>>{};
      for (final m in models) {
        (byClock[m.clockPort] ??= []).add(m);
      }
      for (final entry in byClock.entries) {
        final index = ports.indexOf(entry.key);
        if (index < 0) {
          throw StateError(
            'sim model on clock port "${entry.key}", which is not a clock '
            'domain of this SoC (have: ${ports.join(', ')})',
          );
        }
        final rising = entry.value
            .where((m) => m.edge == HarborSimClockEdge.rising)
            .toList();
        final falling = entry.value
            .where((m) => m.edge == HarborSimClockEdge.falling)
            .toList();
        final both = entry.value
            .where((m) => m.edge == HarborSimClockEdge.both)
            .toList();
        b.writeln('    if (toggled[$index]) {');
        for (final m in both) {
          b.writeln('      ${m.tick}');
        }
        if (rising.isNotEmpty) {
          b.writeln('      if (top->${entry.key}) {');
          for (final m in rising) {
            b.writeln('        ${m.tick}');
          }
          b.writeln('      }');
        }
        if (falling.isNotEmpty) {
          b.writeln('      if (!top->${entry.key}) {');
          for (final m in falling) {
            b.writeln('        ${m.tick}');
          }
          b.writeln('      }');
        }
        b.writeln('    }');
      }
    }
    if (hasJtag) {
      b.writeln('    // Serve JTAG only on the primary clock rising edge: the');
      b.writeln('    // bitbang protocol drives TCK itself, so it must not be');
      b.writeln('    // stepped faster than the design can sample it.');
      b.writeln('    if (*clocks[0].sig) { jtagPoll(); top->eval(); }');
    }
    if (trace) b.writeln('    if (tfp) tfp->dump(time_ps);');
    b.writeln('  }');
    b.writeln();
    if (trace) b.writeln('  if (tfp) { tfp->close(); delete tfp; }');
    b.writeln('  top->final();');
    b.writeln('  delete top;');
    b.writeln('  return 0;');
    b.writeln('}');
    return b.toString();
  }

  /// OpenOCD `remote_bitbang`: a one-character-per-operation ASCII protocol
  /// over TCP. This is what spike and rocket-chip speak, so stock OpenOCD and
  /// GDB attach with no custom adapter.
  void _emitJtagServer(
    StringBuffer b,
    String tck,
    String tms,
    String tdi,
    String tdo,
    String trst,
  ) {
    b.writeln(
      '// --- OpenOCD remote_bitbang server ---------------------------',
    );
    b.writeln('// Protocol: 0-7 write {tck,tms,tdi} (bit2=TCK, bit1=TMS,');
    b.writeln(
      '// bit0=TDI); R read TDO; r/s/t/u reset (bit1=TRST, bit0=SRST);',
    );
    b.writeln('// B/b blink; Q quit.');
    b.writeln('static int jtag_listen_fd = -1;');
    b.writeln('static int jtag_fd = -1;');
    b.writeln();
    b.writeln('static void jtagListen(int port) {');
    b.writeln('  jtag_listen_fd = socket(AF_INET, SOCK_STREAM, 0);');
    b.writeln('  if (jtag_listen_fd < 0) { perror("socket"); exit(1); }');
    b.writeln('  int one = 1;');
    b.writeln(
      '  setsockopt(jtag_listen_fd, SOL_SOCKET, SO_REUSEADDR, '
      '&one, sizeof(one));',
    );
    b.writeln('  sockaddr_in addr {};');
    b.writeln('  addr.sin_family = AF_INET;');
    b.writeln('  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);');
    b.writeln('  addr.sin_port = htons(port);');
    b.writeln(
      '  if (bind(jtag_listen_fd, (sockaddr*)&addr, sizeof(addr)) < 0) '
      '{ perror("bind"); exit(1); }',
    );
    b.writeln(
      '  if (listen(jtag_listen_fd, 1) < 0) '
      '{ perror("listen"); exit(1); }',
    );
    b.writeln('  fcntl(jtag_listen_fd, F_SETFL, O_NONBLOCK);');
    b.writeln(
      '  printf("[harbor] remote_bitbang listening on port %d\\n", '
      'port);',
    );
    b.writeln('  fflush(stdout);');
    b.writeln('}');
    b.writeln();
    b.writeln('static void jtagPoll() {');
    b.writeln('  if (jtag_fd < 0) {');
    b.writeln('    jtag_fd = accept(jtag_listen_fd, nullptr, nullptr);');
    b.writeln('    if (jtag_fd < 0) return;');
    b.writeln('    fcntl(jtag_fd, F_SETFL, O_NONBLOCK);');
    b.writeln('    int one = 1;');
    b.writeln(
      '    setsockopt(jtag_fd, IPPROTO_TCP, TCP_NODELAY, '
      '&one, sizeof(one));',
    );
    b.writeln('    printf("[harbor] openocd attached\\n"); fflush(stdout);');
    b.writeln('  }');
    b.writeln('  char c;');
    b.writeln('  // One command per call keeps TCK stepping in lockstep with');
    b.writeln('  // the design clock rather than racing ahead of it.');
    b.writeln('  ssize_t n = read(jtag_fd, &c, 1);');
    b.writeln('  if (n != 1) return;');
    b.writeln('  switch (c) {');
    b.writeln('    case \'B\': case \'b\': break;                 // blink');
    b.writeln('    case \'R\': {');
    b.writeln('      char r = top->$tdo ? \'1\' : \'0\';');
    b.writeln('      if (write(jtag_fd, &r, 1) != 1) { /* peer gone */ }');
    b.writeln('      break;');
    b.writeln('    }');
    b.writeln('    case \'Q\':');
    b.writeln('      close(jtag_fd); jtag_fd = -1;');
    b.writeln('      break;');
    b.writeln('    case \'0\': case \'1\': case \'2\': case \'3\':');
    b.writeln('    case \'4\': case \'5\': case \'6\': case \'7\': {');
    b.writeln('      int v = c - \'0\';');
    b.writeln('      top->$tck = (v >> 2) & 1;');
    b.writeln('      top->$tms = (v >> 1) & 1;');
    b.writeln('      top->$tdi = (v >> 0) & 1;');
    b.writeln('      break;');
    b.writeln('    }');
    b.writeln('    case \'r\': case \'s\': case \'t\': case \'u\': {');
    b.writeln('      int v = c - \'r\';');
    b.writeln('      top->$trst = (v >> 1) & 1;   // bit0 (SRST) unused: the');
    b.writeln(
      '                                   // harness owns system reset',
    );
    b.writeln('      break;');
    b.writeln('    }');
    b.writeln('    default: break;');
    b.writeln('  }');
    b.writeln('}');
    b.writeln();
  }
}

/// Mixed into a `isSystemVerilogLeaf` [BridgeModule] that supplies its own
/// behavioral body under [HarborSimTarget], because the real implementation is
/// vendor IP Verilator cannot compile.
///
/// The body lives on the leaf itself, next to the port list it has to match,
/// so the two cannot drift. `generateAll` writes it to
/// `sim/<definitionName>.sv` and appends that to `filelist.f`; the file name is
/// derived from the module name for the same reason `rtl/` file names are
/// derived from `SynthFileContents.name`.
///
/// A leaf that does NOT mix this in is a build error under a sim target rather
/// than a silent stub: an unimplemented leaf reads as X in simulation and
/// sends you hunting for a design bug that is not there.
mixin HarborSimLeaf {
  /// SystemVerilog defining a module named exactly `definitionName`.
  String get simRtl;
}

/// Which edge of a [HarborSimModel]'s clock port ticks it.
enum HarborSimClockEdge {
  /// Tick when the clock goes high. The default: what a single-data-rate pin
  /// is sampled on.
  rising,

  /// Tick when the clock goes low.
  falling,

  /// Tick on both edges, for a DDR pin that carries a bit per edge.
  both,
}

/// A C++ model of whatever is attached to a peripheral's pins in the real
/// world: a terminal on a UART, a card on an SD bus, a file behind a flash.
///
/// The design's own logic belongs in ROHD, which emits SystemVerilog that
/// Verilator compiles with everything else. These models are only for what
/// ROHD cannot express: host I/O. Keep them small; a large one is a sign the
/// logic belonged in ROHD.
class HarborSimModel {
  /// C++ struct name. The header is written to `sim/models/<className>.h`,
  /// derived so the file and the type cannot disagree, and deduplicated so two
  /// instances of the same peripheral share one header.
  final String className;

  /// Header source defining [className]. Must be self-contained and
  /// include-guarded.
  final String header;

  /// C++ declaring the instance at file scope, e.g.
  /// `static UartSink uart0_sink(434, "uart0");`
  final String declaration;

  /// Called after `eval()` on [clockPort]'s rising edge, e.g.
  /// `uart0_sink.tick(top->uart0_tx);`
  final String tick;

  /// Top-level clock port whose edges tick this model. A model ticked on the
  /// wrong domain looks like a protocol bug, so it is explicit.
  final String clockPort;

  /// Which edge of [clockPort] ticks this model. A single-data-rate pin is
  /// sampled on one edge; a DDR pin (a TMDS lane, a DDR3 command) carries a
  /// different bit on each edge, so a model that reads one only sees half the
  /// stream.
  final HarborSimClockEdge edge;

  /// Optional `else if` branches spliced into the argument loop, e.g.
  /// `else if (!strncmp(argv[a], "--uart-baud=", 12)) ...`
  final String? cliOption;

  /// Literal compiler flags this model's header needs, e.g. a `-D`.
  final List<String> cflags;

  /// Literal linker flags this model needs.
  final List<String> ldflags;

  /// Host libraries this model needs, by pkg-config package name (`cairo`,
  /// `gtk+-3.0`).
  ///
  /// Resolved when the simulator is BUILT, not when it is generated, so the
  /// output carries no host paths. A package pkg-config cannot find stops the
  /// build with a message naming it, because the alternative is a compiler
  /// command line with empty flags in it, which fails somewhere unrelated.
  final List<String> pkgConfig;

  const HarborSimModel({
    required this.className,
    required this.header,
    required this.declaration,
    required this.tick,
    required this.clockPort,
    this.edge = HarborSimClockEdge.rising,
    this.cliOption,
    this.cflags = const [],
    this.ldflags = const [],
    this.pkgConfig = const [],
  });

  String get headerPath => 'sim/models/$className.h';
}

/// What a peripheral needs to know to emit a [HarborSimModel]: chiefly the
/// TOP-LEVEL names its pins were exposed under, which it cannot know itself.
class HarborSimModelContext {
  /// Peripheral port name -> top-level port name, for pins pulled up with
  /// `HarborSoC.exposePin`.
  final Map<String, String> exposedPins;

  /// Primary input clock frequency in Hz.
  final int clockHz;

  /// Top-level port name of the primary clock.
  final String primaryClockPort;

  /// Top-level clock port THIS peripheral runs on. Not always the primary: a
  /// peripheral on a derived domain gets its own top-level input.
  final String peripheralClockPort;

  /// Frequency of [peripheralClockPort] in Hz.
  ///
  /// A model must take its tick domain AND any rate it derives from the SAME
  /// clock. Mixing them is how a UART sink ends up ticking at 100 MHz while
  /// sizing its bit period for 50 MHz, which decodes as garbage rather than as
  /// an error.
  final int peripheralClockHz;

  const HarborSimModelContext({
    required this.exposedPins,
    required this.clockHz,
    required this.primaryClockPort,
    required this.peripheralClockPort,
    required this.peripheralClockHz,
  });

  /// The top-level name of [portName], or null if it was never exposed. A null
  /// means the pin is internal, so no host-side model can reach it.
  String? topPort(String portName) => exposedPins[portName];
}

/// Implemented by a peripheral that has something to model on the host side
/// under [HarborSimTarget].
mixin HarborSimModelProvider {
  /// Models for this peripheral, or empty when its pins are not exposed.
  List<HarborSimModel> simModels(HarborSimModelContext ctx);
}

/// State a [HarborNextpnrPreplaceProvider] gets when the SoC asks it for a
/// nextpnr pre-place fragment.
///
/// The peripheral knows the names of its own cells. The target knows the part.
/// This context carries the part down so a provider can pin a cell to a BEL
/// that is correct for the device, or return null for a part it has no
/// verified placement for.
class HarborNextpnrPreplaceContext {
  /// FPGA family the build targets. A BEL name is family-specific, so a
  /// provider must check this before it emits a pin.
  final HarborFpgaVendor vendor;

  /// FPGA part, as [HarborFpgaTarget.device] gives it (e.g. `xc7s50`,
  /// `lfe5u-45f`, `up5k`).
  final String device;

  /// FPGA package, as [HarborFpgaTarget.package] gives it (e.g. `csga324`).
  final String package;

  const HarborNextpnrPreplaceContext({
    required this.vendor,
    required this.device,
    required this.package,
  });
}

/// Implemented by a peripheral that must pin one of its cells to a BEL before
/// nextpnr places the design.
///
/// The SoC collects a fragment from every peripheral that has this mixin, joins
/// them, and writes the result as `support/nextpnr/constraints.py`. The
/// generated Makefile passes that file to nextpnr with `--pre-place`, but only
/// when the file exists, so a design with no provider runs the normal flow.
///
/// A fragment is Python that nextpnr runs with `ctx` bound to the design. Give
/// each helper function a name that cannot collide with another fragment: all
/// fragments share ONE namespace.
///
/// ```dart
/// class MyPhy extends Module with HarborNextpnrPreplaceProvider {
///   @override
///   String? nextpnrPreplacePy(HarborNextpnrPreplaceContext ctx) {
///     if (ctx.vendor != HarborFpgaVendor.ecp5) return null;
///     return "for c in ctx.cells:\n"
///         "    if 'my_phy_ff' in c.first:\n"
///         "        c.second.setAttr('BEL', 'X0/Y0/SLICEA')\n";
///   }
/// }
/// ```
mixin HarborNextpnrPreplaceProvider {
  /// The pre-place Python for this peripheral, or null when it has nothing to
  /// pin on [ctx]. Return null (not an empty string) for a part or a family
  /// this peripheral has no verified placement for.
  String? nextpnrPreplacePy(HarborNextpnrPreplaceContext ctx);
}
