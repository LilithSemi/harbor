import 'target.dart';

/// A physical FPGA board: a named bundle of the vendor part, the on-board
/// oscillator, a catalog of usable pins, and how to program it.
///
/// This is the whole-board cousin of River's `DdrBoard`. Instead of describing
/// a DRAM part, it describes a complete board so an SoC can target it by name
/// without hand-entering pin sites. Use [fpgaTarget] to turn a board into a
/// [HarborFpgaTarget].
class HarborBoard {
  /// Board name (e.g. `'ulx3s-85f'`).
  final String name;

  /// FPGA vendor.
  final HarborFpgaVendor vendor;

  /// Device part (e.g. `'lfe5u-85f'`).
  final String device;

  /// Package (e.g. `'CABGA381'`).
  final String package;

  /// On-board oscillator frequency in Hz. Used as the default target clock and
  /// for the input-clock timing constraint.
  final int oscillatorHz;

  /// Pin catalog: logical signal name -> `"SITE [IO_TYPE] [ATTR=VAL...]"`, in
  /// the format [HarborFpgaTarget] renders into constraints.
  final Map<String, String> pins;

  /// Named external connectors (a Pmod header, a built-in card slot, ...). Each
  /// entry maps a peripheral pad role to a `"SITE [IO_TYPE] [ATTR]"` string, in
  /// the same format as [pins]. A device with `iface=<name>` (e.g. an `spi`
  /// controller) binds its pads to the roles here, so the board author bakes the
  /// connector wiring once (e.g. the Digilent Pmod-SPI convention) and an SoC
  /// need not hand-enter Pmod sites. SPI roles: `sck`, `mosi`, `miso`, `cs`.
  final Map<String, Map<String, String>> interfaces;

  /// Bitstream programming command for the generated `prog` Makefile target.
  final String? progCommand;

  /// Name of the board's clock signal in [pins] and the SoC top port (default
  /// `'clk'`).
  final String clockPortName;

  /// Package balls that reach a global clock net with no clock buffer.
  ///
  /// A design that clocks logic from a pin must know if the ball is on a
  /// dedicated clock route. A ball that is not on one needs a vendor clock
  /// buffer between the pad and the logic (an ECP5 `DCCA`, a Xilinx `BUFG`,
  /// an iCE40 `SB_GB`). Without the buffer the tool routes the clock through
  /// general fabric, where the skew across the loads is large and the design
  /// fails on hardware even though it passes in simulation.
  ///
  /// The entries are SITE names (package balls), NOT catalog signal names,
  /// because clock capability belongs to the part and the package and not to
  /// the role a board gives a ball. A design that moves a signal to another
  /// ball is then still judged correctly. Use [siteIsClockCapable] to ask.
  ///
  /// The default is empty, which reads as "no ball is known to reach a clock
  /// net". A design then puts a clock buffer on every pin it clocks from,
  /// which is always correct and costs one global buffer. A board lists the
  /// balls it has confirmed. A list can be incomplete: an absent ball only
  /// gives a buffer that was not necessary.
  final Set<String> clockCapableSites;

  const HarborBoard({
    required this.name,
    required this.vendor,
    required this.device,
    required this.package,
    required this.oscillatorHz,
    required this.pins,
    this.interfaces = const {},
    this.progCommand,
    this.clockPortName = 'clk',
    this.clockCapableSites = const {},
  });

  /// Whether [pin] is on a ball that reaches a global clock net with no clock
  /// buffer, per [clockCapableSites].
  ///
  /// [pin] is a pin map VALUE, so both a bare ball (`"K1"`) and a full catalog
  /// entry (`"K1 LVCMOS33 PULLMODE=UP"`) are accepted. Only the site token is
  /// read. Give the value from the target the design really builds, so a pin
  /// the build moved is judged on the ball it moved to.
  bool siteIsClockCapable(String pin) =>
      clockCapableSites.contains(pin.trim().split(RegExp(r'\s+')).first);

  /// Built-in board presets, keyed by [name].
  static const byName = <String, HarborBoard>{
    'ulx3s-85f': _ulx3s85f,
    'orangecrab-25f': _orangeCrab25f,
    'arty-s7-50': _artyS7_50,
  };

  /// Resolves a board preset by name, throwing if it is unknown.
  static HarborBoard get(String name) {
    final board = byName[name];
    if (board == null) {
      throw ArgumentError(
        'Unknown board "$name". Known: ${byName.keys.join(', ')}.',
      );
    }
    return board;
  }

  String get _vendorPrefix => switch (vendor) {
    HarborFpgaVendor.ice40 => 'ice40',
    HarborFpgaVendor.ecp5 => 'ecp5',
    HarborFpgaVendor.vivado => 'spartan7',
    HarborFpgaVendor.openXc7 => 'spartan7',
  };

  /// Builds a [HarborFpgaTarget] for this board.
  ///
  /// [pins] selects which catalog signals to constrain (defaults to all of
  /// them), requesting a signal not in the catalog throws. [extraPins] adds
  /// board-specific pins not in the catalog. [frequency] overrides the target
  /// clock (defaults to [oscillatorHz]).
  HarborFpgaTarget fpgaTarget({
    Iterable<String>? pins,
    int? frequency,
    Map<String, String> extraPins = const {},
  }) {
    final selected = pins ?? this.pins.keys;
    final pinMap = <String, String>{};
    for (final signal in selected) {
      final site = this.pins[signal];
      if (site == null) {
        throw ArgumentError(
          'Pin "$signal" is not in board "$name"\'s catalog. '
          'Known: ${this.pins.keys.join(', ')}.',
        );
      }
      pinMap[signal] = site;
    }
    pinMap.addAll(extraPins);

    return HarborFpgaTarget(
      name: '$_vendorPrefix-$device',
      vendor: vendor,
      device: device,
      package: package,
      frequency: frequency ?? oscillatorHz,
      pinMap: pinMap,
      clockPortName: clockPortName,
      progCommand: progCommand,
    );
  }
}

/// ULX3S with the Lattice ECP5 LFE5U-85F (CABGA381), 25 MHz oscillator.
///
/// Fully open toolchain (yosys + nextpnr + trellis) with GPDI/HDMI display
/// output. The catalog covers the oscillator, the FTDI console UART, the GPDI
/// TMDS lanes and sideband, the LEDs, the buttons, and the sdram. Sites come
/// from the upstream `ulx3s_v20.lpf` constraint file (emard/ulx3s).
const _ulx3s85f = HarborBoard(
  name: 'ulx3s-85f',
  vendor: HarborFpgaVendor.ecp5,
  device: 'lfe5u-85f',
  package: 'CABGA381',
  oscillatorHz: 25000000,
  pins: {
    'clk': 'G2', // clk_25mhz
    'uart_tx': 'L4', // ftdi_rxd (FPGA drives FTDI receive)
    'uart_rx': 'M1', // ftdi_txd (FPGA reads FTDI transmit)
    // GPDI (HDMI) TMDS lanes, ULX3S v2.0. LVCMOS33D is a true differential
    // output, so only the positive ball is constrained, the tool drives the
    // complement pad. Channels 0..2 are data (blue/green/red), 3 is the clock.
    'gpdi_dp[0]': 'A16 LVCMOS33D DRIVE=4',
    'gpdi_dp[1]': 'A14 LVCMOS33D DRIVE=4',
    'gpdi_dp[2]': 'A12 LVCMOS33D DRIVE=4',
    'gpdi_dp[3]': 'A17 LVCMOS33D DRIVE=4',
    // GPDI sideband. sda and scl are an I2C bus shared with the on-board
    // RTC, so a driver must not assume it owns the bus.
    'gpdi_sda': 'B19 LVCMOS33 DRIVE=4 PULLMODE=UP',
    'gpdi_scl': 'E12 LVCMOS33 DRIVE=4 PULLMODE=UP',
    'gpdi_hpd': 'B20 LVCMOS33 DRIVE=4',
    'gpdi_cec': 'A18 LVCMOS33 DRIVE=4 PULLMODE=UP',
    // USB device port ("US2" on the schematic), wired straight to the FPGA
    // and not through the FTDI chip. Confirmed on real hardware: a bitstream
    // with this mapping enumerates over USB.
    //
    // usb_fpga_dp/dn (E16/F16) are differential input only and cannot
    // transmit, so they are not usable for a device port and are left out.
    // usb_fpga_pu_dn (C12) is left out too: the hardware-proven build does
    // not constrain it.
    'usb_dp': 'D15 LVCMOS33 DRIVE=4 PULLMODE=NONE', // usb_fpga_bd_dp
    'usb_dm': 'E15 LVCMOS33 DRIVE=4 PULLMODE=NONE', // usb_fpga_bd_dn
    'usb_pullup': 'B12 LVCMOS33 DRIVE=16 PULLMODE=NONE', // usb_fpga_pu_dp
    // LEDs. Active high, no inversion noted upstream.
    'led[0]': 'B2 LVCMOS33 DRIVE=4 PULLMODE=NONE',
    'led[1]': 'C2 LVCMOS33 DRIVE=4 PULLMODE=NONE',
    'led[2]': 'C1 LVCMOS33 DRIVE=4 PULLMODE=NONE',
    'led[3]': 'D2 LVCMOS33 DRIVE=4 PULLMODE=NONE',
    'led[4]': 'D1 LVCMOS33 DRIVE=4 PULLMODE=NONE',
    'led[5]': 'E2 LVCMOS33 DRIVE=4 PULLMODE=NONE',
    'led[6]': 'E1 LVCMOS33 DRIVE=4 PULLMODE=NONE',
    'led[7]': 'H3 LVCMOS33 DRIVE=4 PULLMODE=NONE',
    // BTN_PWRn. It is ACTIVE LOW (pressed reads 0), while the SoC top port
    // `reset` is active high, so a design must invert this pin, same as
    // OrangeCrab's rst_n.
    'rst_n': 'D6 LVCMOS33 DRIVE=4 PULLMODE=UP',
    // Fire and direction buttons. Active high, pulled down when idle.
    'btn_fire1': 'R1 LVCMOS33 DRIVE=4 PULLMODE=DOWN',
    'btn_fire2': 'T1 LVCMOS33 DRIVE=4 PULLMODE=DOWN',
    'btn_up': 'R18 LVCMOS33 DRIVE=4 PULLMODE=DOWN',
    'btn_down': 'V1 LVCMOS33 DRIVE=4 PULLMODE=DOWN',
    'btn_left': 'U1 LVCMOS33 DRIVE=4 PULLMODE=DOWN',
    'btn_right': 'H16 LVCMOS33 DRIVE=4 PULLMODE=DOWN',
    // sdram (AS4C16M16SB). The upstream names are sdram_csn, sdram_a and
    // sdram_d. Here they follow the HarborSdram port names.
    'sdram_clk': 'F19 LVCMOS33 SLEWRATE=FAST',
    'sdram_cke': 'F20 LVCMOS33 SLEWRATE=FAST',
    'sdram_cs_n': 'P20 LVCMOS33 SLEWRATE=FAST',
    'sdram_we_n': 'T20 LVCMOS33 SLEWRATE=FAST',
    'sdram_ras_n': 'R20 LVCMOS33 SLEWRATE=FAST',
    'sdram_cas_n': 'T19 LVCMOS33 SLEWRATE=FAST',
    'sdram_addr[0]': 'M20 LVCMOS33 SLEWRATE=FAST',
    'sdram_addr[1]': 'M19 LVCMOS33 SLEWRATE=FAST',
    'sdram_addr[2]': 'L20 LVCMOS33 SLEWRATE=FAST',
    'sdram_addr[3]': 'L19 LVCMOS33 SLEWRATE=FAST',
    'sdram_addr[4]': 'K20 LVCMOS33 SLEWRATE=FAST',
    'sdram_addr[5]': 'K19 LVCMOS33 SLEWRATE=FAST',
    'sdram_addr[6]': 'K18 LVCMOS33 SLEWRATE=FAST',
    'sdram_addr[7]': 'J20 LVCMOS33 SLEWRATE=FAST',
    'sdram_addr[8]': 'J19 LVCMOS33 SLEWRATE=FAST',
    'sdram_addr[9]': 'H20 LVCMOS33 SLEWRATE=FAST',
    'sdram_addr[10]': 'N19 LVCMOS33 SLEWRATE=FAST',
    'sdram_addr[11]': 'G20 LVCMOS33 SLEWRATE=FAST',
    'sdram_addr[12]': 'G19 LVCMOS33 SLEWRATE=FAST',
    'sdram_ba[0]': 'P19 LVCMOS33 SLEWRATE=FAST',
    'sdram_ba[1]': 'N20 LVCMOS33 SLEWRATE=FAST',
    'sdram_dqm[0]': 'U19 LVCMOS33 SLEWRATE=FAST',
    'sdram_dqm[1]': 'E20 LVCMOS33 SLEWRATE=FAST',
    'sdram_dq[0]': 'J16 LVCMOS33 SLEWRATE=FAST',
    'sdram_dq[1]': 'L18 LVCMOS33 SLEWRATE=FAST',
    'sdram_dq[2]': 'M18 LVCMOS33 SLEWRATE=FAST',
    'sdram_dq[3]': 'N18 LVCMOS33 SLEWRATE=FAST',
    'sdram_dq[4]': 'P18 LVCMOS33 SLEWRATE=FAST',
    'sdram_dq[5]': 'T18 LVCMOS33 SLEWRATE=FAST',
    'sdram_dq[6]': 'T17 LVCMOS33 SLEWRATE=FAST',
    'sdram_dq[7]': 'U20 LVCMOS33 SLEWRATE=FAST',
    'sdram_dq[8]': 'E19 LVCMOS33 SLEWRATE=FAST',
    'sdram_dq[9]': 'D20 LVCMOS33 SLEWRATE=FAST',
    'sdram_dq[10]': 'D19 LVCMOS33 SLEWRATE=FAST',
    'sdram_dq[11]': 'C20 LVCMOS33 SLEWRATE=FAST',
    'sdram_dq[12]': 'E18 LVCMOS33 SLEWRATE=FAST',
    'sdram_dq[13]': 'F18 LVCMOS33 SLEWRATE=FAST',
    'sdram_dq[14]': 'J18 LVCMOS33 SLEWRATE=FAST',
    'sdram_dq[15]': 'J17 LVCMOS33 SLEWRATE=FAST',
  },
  // openFPGALoader knows the ULX3S. Loads the bitstream over USB.
  progCommand: 'openFPGALoader -b ulx3s \$(TOP).bit',
);

/// OrangeCrab r0.2 with the Lattice ECP5 LFE5U-25F (CSFBGA285), 48 MHz oscillator.
///
/// Fully open toolchain (yosys + nextpnr-ecp5 + trellis). The catalog covers the
/// oscillator, the DirtyJTAG CDC UART, the config SPI flash (quad, clock via
/// the ECP5 USRMCLK macro so there is no spi_clk pad), the USB device pads, the
/// button, and the green LED. Sites come from the litex-boards
/// `gsd_orangecrab` `_io_r0_2` table and are proven on hardware: a bitstream
/// with these pins enumerates over USB. DDR3L sdram_* sites are added with
/// their SSTL135 attributes when the DDR weight backend lands (the OrangeCrab
/// DDR path is not yet hardware-proven). Loaded over DirtyJTAG.
const _orangeCrab25f = HarborBoard(
  name: 'orangecrab-25f',
  vendor: HarborFpgaVendor.ecp5,
  device: 'lfe5u-25f',
  package: 'CSFBGA285',
  oscillatorHz: 48000000,
  pins: {
    'clk': 'A9 LVCMOS33',
    'uart_tx': 'N17 LVCMOS33', // FPGA drives the DirtyJTAG CDC receive
    'uart_rx': 'M18 LVCMOS33', // FPGA reads the DirtyJTAG CDC transmit
    // Config SPI flash (W25Q128, quad). The clock has no pad: the controller
    // drives it through USRMCLK, so only cs_n + the 4-bit io bus are constrained.
    'spi_cs_n': 'U17 LVCMOS33',
    'spi_io[0]': 'U18 LVCMOS33',
    'spi_io[1]': 'T18 LVCMOS33',
    'spi_io[2]': 'R18 LVCMOS33',
    'spi_io[3]': 'N18 LVCMOS33',
    // USB device port (the same USB-C socket that carries power). The FPGA
    // drives the full-speed pads itself, there is no PHY chip. D+ and D- are
    // bidirectional, so a design binds one top-level pad port to each and
    // drives it with an output enable. usb_pullup enables the 1k5 pull-up on
    // D+, which is how a full-speed device tells the host it is present: hold
    // it low to stay disconnected, drive it high to enumerate.
    'usb_dp': 'N1 LVCMOS33',
    'usb_dm': 'M2 LVCMOS33',
    'usb_pullup': 'N2 LVCMOS33',
    // The user button. It is ACTIVE LOW (pressed reads 0), while the SoC top
    // port `reset` is active high, so a design must invert this pin.
    'rst_n': 'V17 LVCMOS33',
    // Green channel of the RGB LED. It is active low (drive 0 to light it).
    // The blue channel is added when a bring-up needs it.
    'led_g': 'M3 LVCMOS33',
    // Red channel of the RGB LED (gsd_orangecrab.py _io_r0_2, user_led 0,
    // "K4"). Wired to the DDR3 cal-failed signal. Active low, so a lit LED
    // means calibration failed.
    'ddr_cal_failed': 'K4 LVCMOS33',
    // The microSD socket, 1-bit mode. Sites from the litex-boards
    // `gsd_orangecrab` `_io_r0_2` table. CMD and DAT carry a pull-up, which
    // is what an SD host and an SD card both expect on an idle line: the line
    // reads high while nothing drives it, so a released line is not a start
    // bit. The clock needs no pull-up, because the host always drives it.
    //
    // DAT1 to DAT3 are here although the 1-bit datapath reads none of them.
    // An SD HOST holds its command inhibit while DAT[3:0] read busy, and a
    // real card holds all four lines high through pull-ups. A ball with no
    // constraint has no pull-up and floats, so a host can read a card that
    // is permanently busy and send no command at all. A design that takes
    // these three lines therefore needs only a top-level port for each one:
    // the pad pull-up then holds the line high the way a card does. The
    // 4-bit datapath reads the same three lines later.
    //
    // A constraint for a port the design has no pin for makes nextpnr reject
    // the build, so a design that does not carry these ports must not ask
    // for these pins.
    //
    // sd_clk takes a pull-down. The host drives the clock, so nothing holds
    // the line when no host is connected. A floating input picks up noise,
    // and every noise edge counts as a clock in DBG_SD_CLK, which makes that
    // counter lie during bring-up. A pull-down gives a clean 0 instead.
    //
    // sd_clk is on K1, which is NOT a clock-capable ball (see
    // [clockCapableSites]), so a design that clocks logic from it must put a
    // DCCA between the pad and the logic.
    'sd_clk': 'K1 LVCMOS33 PULLMODE=DOWN',
    'sd_cmd': 'K2 LVCMOS33 PULLMODE=UP',
    'sd_dat0': 'J1 LVCMOS33 PULLMODE=UP',
    'sd_dat1': 'K3 LVCMOS33 PULLMODE=UP',
    'sd_dat2': 'L3 LVCMOS33 PULLMODE=UP',
    'sd_dat3': 'M1 LVCMOS33 PULLMODE=UP',
  },
  // The 48 MHz oscillator ball is the one confirmed clock input of this
  // board. Every other ball the catalog carries is a general I/O, so a clock
  // taken from one of them needs a DCCA. The list is deliberately short: it
  // states what is proven, and an absent ball only costs a clock buffer that
  // was not necessary.
  clockCapableSites: {'A9'},
  // DirtyJTAG speaks the OrangeCrab JTAG. openFPGALoader loads to SRAM.
  progCommand: 'openFPGALoader -c dirtyJtag \$(TOP).bit',
);

/// Digilent Arty S7-50 with the Xilinx Spartan-7 XC7S50 (csga324), 100 MHz
/// oscillator, via the open-source openXC7 flow (yosys synth_xilinx +
/// nextpnr-xilinx + prjxray, the only Xilinx flow that runs on aarch64).
///
/// Covers the oscillator, the USB-UART bridge (the HW-proven Weir-boot pins),
/// a TMDS adapter on Pmod JB, and the DDR3L sdram_* sites.
///
/// The DDR3L part is a Micron MT41K128M16: 256 MB, x16, sites from the
/// litex/migen `arty_s7` platform. Every project that drives this board wants
/// the same table, so it belongs here and not beside one project's generator.
/// Pair it with `DdrParams.artyS7()`, which carries the geometry.
///
/// CK and DQS are single-ended SSTL135 on BOTH the _p and the _n ball, not a
/// true differential pair. The DLL-off PHY drives the complement itself, so
/// there is no hard OBUFDS pair for a DIFF_SSTL135 site to feed. The XDC
/// writer emits PACKAGE_PIN and IOSTANDARD only, so migen's IN_TERM and SLEW
/// attributes are dropped.
///
/// The config SPI flash sites are still not here.
const _artyS7_50 = HarborBoard(
  name: 'arty-s7-50',
  vendor: HarborFpgaVendor.openXc7,
  device: 'xc7s50',
  package: 'csga324',
  oscillatorHz: 100000000,
  pins: {
    'clk': 'R2', // 100 MHz board oscillator
    'uart_tx': 'R12 LVCMOS33', // FPGA -> USB-UART bridge RX (Pmod/onboard)
    'uart_rx': 'V12 LVCMOS33', // FPGA <- USB-UART bridge TX
    // A passive TMDS adapter (the MuseLab/iCESugar PMOD-HDMI) on header JB.
    // These are the same eight balls as `pmod@jb`, read as a display instead,
    // so a build binds one or the other and never both.
    //
    // Both pins of a lane are plain LVCMOS33, NOT a differential pair, which
    // is what the iCESugar reference design does: the open Xilinx flow has no
    // TMDS_33 site, and the adapter is passive, so the design puts out the
    // true lane AND the complement itself.
    //
    // The adapter pairs a lane ACROSS the two rows of the header (its pin 1
    // with its pin 12), while the FPGA pairs balls WITHIN a row, so a lane's
    // two balls are not an FPGA pair and are not length matched. That is fine
    // at a 25 MHz pixel clock, and it is why JB is the header to use: JC has
    // only two of the four lanes on true pairs and JD has none.
    //
    // Lane order matches the display's `gpdi` bus: 0 blue, 1 green, 2 red,
    // 3 clock. Polarity comes from the adapter schematic, which puts the MINUS
    // side of every lane on header pins 1 to 4 and the PLUS side on 7 to 10.
    // TMDS reads the difference between the two pins, so swapping them inverts
    // the bits and 8b/10b decoding fails. Swapping every lane does not cancel.
    //
    // No drive strength is set. The iCESugar reference uses DRIVE=4 on Lattice,
    // but the XDC writer emits PACKAGE_PIN and IOSTANDARD only, so a DRIVE here
    // would read as if it applied and would not. If the lanes need taming, add
    // it to the XDC writer first, and check that nextpnr-xilinx accepts it.
    //
    // Sites from the Digilent Arty-S7-50 master XDC (JB1=P17 JB2=P18 JB3=R18
    // JB4=T18, JB7=P14 JB8=P15 JB9=N15 JB10=P16), all bank 14.
    'gpdi_dp[0]': 'N15 LVCMOS33', // blue +, header pin 9
    'gpdi_dp[1]': 'P15 LVCMOS33', // green +, header pin 8
    'gpdi_dp[2]': 'P14 LVCMOS33', // red +, header pin 7
    'gpdi_dp[3]': 'P16 LVCMOS33', // clock +, header pin 10
    'gpdi_dn[0]': 'R18 LVCMOS33', // blue -, header pin 3
    'gpdi_dn[1]': 'P18 LVCMOS33', // green -, header pin 2
    'gpdi_dn[2]': 'P17 LVCMOS33', // red -, header pin 1
    'gpdi_dn[3]': 'T18 LVCMOS33', // clock -, header pin 4
    // DDR3L (Micron MT41K128M16, 256 MB, x16). Address a[13:0] gives 14 row
    // lines. Lane 0 is DM0/DQS0 with DQ[7:0], lane 1 is DM1/DQS1 with
    // DQ[15:8], in litex site order.
    //
    // Both DQS rails are constrained. The PHY always drives the _n rail, so
    // leaving it out fails place-and-route with "no IOSTANDARD" rather than
    // falling back to a generated complement.
    'sdram_ck': 'R5 DIFF_SSTL135',
    'sdram_ck_n': 'T4 DIFF_SSTL135',
    'sdram_cke': 'T2 SSTL135',
    'sdram_cs_n': 'R3 SSTL135',
    'sdram_ras_n': 'U1 SSTL135',
    'sdram_cas_n': 'V3 SSTL135',
    'sdram_we_n': 'P7 SSTL135',
    'sdram_odt': 'P5 SSTL135',
    'sdram_reset_n': 'J6 SSTL135',
    'sdram_ba[0]': 'V5 SSTL135',
    'sdram_ba[1]': 'T1 SSTL135',
    'sdram_ba[2]': 'U3 SSTL135',
    'sdram_addr[0]': 'U2 SSTL135',
    'sdram_addr[1]': 'R4 SSTL135',
    'sdram_addr[2]': 'V2 SSTL135',
    'sdram_addr[3]': 'V4 SSTL135',
    'sdram_addr[4]': 'T3 SSTL135',
    'sdram_addr[5]': 'R7 SSTL135',
    'sdram_addr[6]': 'V6 SSTL135',
    'sdram_addr[7]': 'T6 SSTL135',
    'sdram_addr[8]': 'U7 SSTL135',
    'sdram_addr[9]': 'V7 SSTL135',
    'sdram_addr[10]': 'P6 SSTL135',
    'sdram_addr[11]': 'T5 SSTL135',
    'sdram_addr[12]': 'R6 SSTL135',
    'sdram_addr[13]': 'U6 SSTL135',
    'sdram_dm[0]': 'K4 SSTL135',
    'sdram_dm[1]': 'M3 SSTL135',
    'sdram_dq[0]': 'K2 SSTL135',
    'sdram_dq[1]': 'K3 SSTL135',
    'sdram_dq[2]': 'L4 SSTL135',
    'sdram_dq[3]': 'M6 SSTL135',
    'sdram_dq[4]': 'K6 SSTL135',
    'sdram_dq[5]': 'M4 SSTL135',
    'sdram_dq[6]': 'L5 SSTL135',
    'sdram_dq[7]': 'L6 SSTL135',
    'sdram_dq[8]': 'N4 SSTL135',
    'sdram_dq[9]': 'R1 SSTL135',
    'sdram_dq[10]': 'N1 SSTL135',
    'sdram_dq[11]': 'N5 SSTL135',
    'sdram_dq[12]': 'M2 SSTL135',
    'sdram_dq[13]': 'P1 SSTL135',
    'sdram_dq[14]': 'M1 SSTL135',
    'sdram_dq[15]': 'P2 SSTL135',
    'sdram_dqs[0]': 'K1 SSTL135',
    'sdram_dqs[1]': 'N3 SSTL135',
    'sdram_dqs_n[0]': 'L1 SSTL135',
    'sdram_dqs_n[1]': 'N2 SSTL135',
  },
  // Pmod headers as SPI connectors, wired to the Digilent Pmod-SPI (Type 2A)
  // convention: connector pin 1 = ~CS, 2 = MOSI, 3 = MISO, 4 = SCK. A device
  // with `iface=pmod@ja` (e.g. a PmodSD SD card in SPI mode) binds its pads
  // here. MISO gets a PULLUP so an empty socket reads high, not floating.
  // Sites from the Digilent Arty-S7-50 master XDC (JA1=L17 JA2=L18 JA3=M14
  // JA4=N14; JB1=P17 JB2=P18 JB3=R18 JB4=T18), all bank 14 LVCMOS33.
  interfaces: {
    'pmod@ja': {
      'cs': 'L17 LVCMOS33',
      'mosi': 'L18 LVCMOS33',
      'miso': 'M14 LVCMOS33 PULLUP TRUE',
      'sck': 'N14 LVCMOS33',
    },
    'pmod@jb': {
      'cs': 'P17 LVCMOS33',
      'mosi': 'P18 LVCMOS33',
      'miso': 'R18 LVCMOS33 PULLUP TRUE',
      'sck': 'T18 LVCMOS33',
    },
  },
);
