import 'dart:io';
import 'dart:math' show max;

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/axi4/axi4_exclusive.dart';
import '../bus/axi4/axi4_fabric.dart';
import '../bus/axi4/axi4_interface.dart';
import '../bus/axi4/axi4_lite_interface.dart';
import '../bus/bus.dart';
import '../bus/bus_error_source.dart';
import '../bus/bus_slave_port.dart';
import '../bus/fabric.dart';
import '../bus/fabric_narrow.dart';
import '../bus/port/memory_port.dart';
import '../bus/tilelink/tilelink_interface.dart';
import '../bus/wishbone/wishbone_arbiter.dart';
import '../bus/wishbone/wishbone_interface.dart';
import '../bus/wishbone/wishbone_register_stage.dart';
import '../blackbox/xilinx/xilinx.dart';
import '../clock/clock_domain.dart';
import '../pdk/klayout.dart';
import '../peripherals/flash.dart';
import '../peripherals/harbor_ddr3.dart';
import '../peripherals/harbor_sdram.dart';
import '../peripherals/led_engine.dart';
import '../peripherals/maskrom.dart';
import '../peripherals/reset_controller.dart';
import '../peripherals/spi_flash.dart';
import '../peripherals/sram.dart';
import 'acpi.dart';
import 'board.dart';
import 'board_zon.dart';
import 'cpu.dart';
import 'device_tree.dart';
import 'graph.dart';
import 'svd.dart';
import 'target.dart';

/// Selects how a slave that more than one fabric channel reaches is shared.
///
/// A channel is a group of masters that reach the same slave subset. When
/// two channels both reach one slave (for example a DMA channel and the CPU
/// channel that meet only at memory), the convergence mode says how that
/// slave takes both.
enum HarborMemConverge {
  /// The fabric arbitrates the channels at the shared slave, so the slave
  /// sees one master at a time. This is the only mode that is built today.
  arbiter,

  /// Give the shared slave two independent ports (for a true dual-port memory).
  /// Not built yet.
  dualport,

  /// Let the channels keep separate decoders but share one decode map. Not
  /// built yet.
  sharedDecode,
}

/// A composable SoC built on rohd_bridge.
///
/// Provides a declarative API for assembling a RISC-V SoC: add
/// peripherals and bus masters, and [HarborSoC] auto-wires them
/// through a [HarborFabric] of [fabricKind]. For custom topology, drop down
/// to rohd_bridge's [addSubModule], [connectInterfaces], and
/// [connectPorts] directly.
///
/// ```dart
/// final soc = HarborSoC(
///   name: 'MySoC',
///   compatible: 'lilithsemi,creek-v1',
///   fabricKind: HarborFabricKind.wishbone,
/// );
///
/// // Declarative - auto-wired by address
/// soc.addPeripheral(HarborClint(baseAddress: 0x02000000));
/// soc.addPeripheral(HarborPlic(baseAddress: 0x0C000000));
/// soc.addPeripheral(HarborUart(baseAddress: 0x10000000));
///
/// // Expose UART pins at SoC level
/// soc.exposePin(uart, 'tx');
/// soc.exposePin(uart, 'rx');
///
/// // Add a bus master (CPU)
/// soc.addMaster(myRiverCore);
///
/// // Build the bus fabric
/// soc.buildFabric();
///
/// // Generate outputs
/// await soc.buildAndGenerateRTL();
/// File('soc.dts').writeAsStringSync(soc.generateDts());
/// File('soc.dot').writeAsStringSync(soc.generateDot());
/// ```
class HarborSoC extends BridgeModule {
  /// Root `compatible` string for the device tree.
  final String compatible;

  /// The kind of the bus fabric. Every peripheral and master port must be
  /// native to it.
  final HarborFabricKind fabricKind;

  /// The topology of the bus fabric. Null picks crossbar when [buildFabric]
  /// gets more than one channel, else shared.
  final HarborFabricTopology? fabricTopology;

  /// CPU information for the device tree.
  final List<HarborCpu> cpus;

  /// Build target (FPGA or ASIC). Controls what scripts are generated.
  final HarborDeviceTarget? target;

  final List<_PeripheralEntry> _peripherals = [];
  final List<_SecondarySlave> _secondarySlaves = [];
  final List<_MasterEntry> _masters = [];

  /// Every bus fabric [buildFabric] built: one, or with channels one per
  /// channel and one per shared slave.
  final List<HarborFabricModule> fabrics = [];

  /// The first fabric, the one of the primary channel. On a shared Wishbone
  /// fabric its `grant` output shows the master that owns the bus.
  HarborFabricModule? get fabric => fabrics.firstOrNull;

  /// Sticky error flags of the master register stages.
  final List<Logic> _fabricErrorFlags = [];

  /// Adds a `bus_error` output (or [portName]) to the SoC. It stays high
  /// until reset once one of these happens:
  ///
  /// - a bus timeout cuts a slave off,
  /// - an error goes to a master that has no error signal, so the master
  ///   sees a normal response (an unmapped access or a slave error),
  /// - a master register stage gives such a response,
  /// - a peripheral that is a [HarborBusErrorSource] flags an error.
  ///
  /// An unmapped access from a master that has an error signal gets the
  /// native decode error and does not set it. Call it after [buildFabric].
  Logic exposeBusError({String portName = 'bus_error'}) {
    if (fabrics.isEmpty) {
      throw StateError('exposeBusError needs buildFabric first');
    }
    final sources = <Logic>[
      for (final f in fabrics) ...[
        f.busError,
        if (f.foldError case final fold?) fold,
      ],
      ..._fabricErrorFlags,
      for (final e in _peripherals)
        if (e.module case final HarborBusErrorSource m) m.busError,
    ];
    final port = addOutput(portName);
    port <= sources.reduce((a, b) => a | b);
    return port;
  }

  /// Modules already added as submodules + clock-wired. A module may be BOTH a
  /// master and a peripheral (a dual-role device like a DMA or an accelerator
  /// with CSR slave + bus master). This set keeps the second [addMaster] /
  /// [addPeripheral] from double-adding or double-driving its clk/reset.
  final Set<BridgeModule> _wired = {};

  /// Adds [module] as a submodule and wires its clk/reset exactly once, even if
  /// it is registered as both a master and a peripheral.
  void _wireOnce(BridgeModule module, String? clockDomainName) {
    if (!_wired.add(module)) return;
    addSubModule(module);
    final domain = domainFor(clockDomainName);
    final (clk, reset) = domain != null
        ? (domain.clk, domain.reset)
        : (_boardClk, _systemReset);
    module.input('clk').srcConnection! <= clk;
    if (module is HarborResetController) {
      // The controller makes the soft reset, so its own reset is the hard
      // reset only.
      // The reset of its own domain, held with the PLL lock and without the
      // soft reset request, which the controller makes itself.
      module.input('por').srcConnection! <=
          (domain != null ? _clockGen.hardResetOf(domain) : _hardReset);
      final pin = _pinReset;
      if (pin == null) {
        module.input('ext_reset').srcConnection! <= Const(0);
      } else {
        final sync = Logic(name: 'ext_reset_sync', width: 2);
        Sequential(clk, [
          sync < [sync[0], pin].concat(),
        ]);
        module.input('ext_reset').srcConnection! <= sync[1];
      }
      module.input('wdog_reset').srcConnection! <= (_resetWatchdog ?? Const(0));
      module.input('watchdog_wired').srcConnection! <=
          Const(_resetWatchdog == null ? 0 : 1);
      module.input('debug_reset').srcConnection! <= (_resetDebug ?? Const(0));
    } else {
      module.input('reset').srcConnection! <= reset;
    }
  }

  /// The clock domain a peripheral registered under [clockDomainName] actually
  /// runs on, or null when it rides the raw `clk` input because no domains are
  /// configured.
  ///
  /// [_wireOnce] and every rate this SoC reports go through here, so what a
  /// device tree claims about a peripheral's clock cannot drift from what the
  /// hardware is wired to.
  HarborClockDomain? domainFor(String? clockDomainName) {
    if (clockDomainName != null && _clockDomains.containsKey(clockDomainName)) {
      return _clockDomains[clockDomainName];
    }
    if (_clockDomains.isEmpty) return null;
    // Mirrors [defaultClock]: the conventional 'sys' bus domain, else the first
    // registered one. NOT "the primary domain": on a SoC where sys is a CLKOS
    // secondary those are different clocks, and picking the wrong one emits a
    // plausible but wrong rate.
    return _clockDomains['sys'] ?? _clockDomains.values.first;
  }

  late final HarborClockGenerator _clockGen;

  // The reset that is not the soft reset: the reset pin or the power-on
  // reset. The SoC reset adds the soft reset request to it.
  late final Logic _hardReset;

  // The reset of everything on the SoC, with the soft reset request.
  late final Logic _systemReset;

  // The reset pin, active high, or null when the SoC has only the power-on
  // reset. The reset controller reports it as an external reset.
  late final Logic? _pinReset;

  Logic? _softResetRequest;
  HarborResetController? _resetController;
  String? _resetControllerDomain;
  Logic? _resetWatchdog;
  Logic? _resetDebug;

  late final Logic _boardClk;

  /// The board clock after the input buffer. It is the `clk` port itself for
  /// a single-ended clock. It runs before any MMCM or PLL locks.
  Logic get boardClk => _boardClk;
  final Map<String, HarborClockDomain> _clockDomains = {};

  /// The Xilinx DDR3-fast clock tree, built in this SoC's clock generation when
  /// [xilinxDdr3Tree] is provided. Null otherwise. Exposes the DDR CK / CLKDIV /
  /// IDELAYCTRL-ref / CK90 / DQS clocks for the DDR controller peripheral, and
  /// its spare `coreClk` drives any [HarborClockConfig.providedByDdr3Tree] domain
  /// (so the core runs off the SAME MMCM as the DDR clocks: one MMCM on the pin).
  late final XilinxDdr3Clocks? xilinxDdr3Clocks;

  /// Realised core-clock MHz of the dedicated Xilinx core PLL, kept so the
  /// nextpnr `--pre-pack` addClock over-constraint can be emitted at build time.
  double? _xilinxCoreClkMhz;

  /// Board oscillator rate for the Xilinx DDR3 clock tree.
  double? _xilinxSourceClkMhz;

  /// Whether the SoC builds the Xilinx DDR3 clock tree. The PLL clock net
  /// naming, its keep attribute and its nextpnr scripts all follow this one
  /// check, so a DDR3 build keeps its own clock script and RTL.
  late final bool _hasDdr3ClockTree;

  /// Clock net name to MHz for each Xilinx PLL domain that has no DDR3 tree.
  final Map<String, double> _xilinxPllClockMhz = {};

  final String acpiOemId;
  final String acpiOemTableId;

  /// Product name for the device tree root `model` property. Defaults to
  /// [name]. ACPI has no product name field, so it does not appear there.
  final String model;
  final String? _explicitModel;

  /// Manufacturer name. When set, it is the vendor of the generated SVD file
  /// and replaces [svdVendor]. Null leaves [svdVendor] in use.
  final String? manufacturer;

  /// The board preset this SoC builds for, or null. It fills the board fields
  /// of [generateBoardZon].
  final HarborBoard? board;

  /// Vendor name for the generated CMSIS-SVD file.
  final String svdVendor;

  /// Version string for the generated CMSIS-SVD file.
  final String svdVersion;

  /// First interrupt source number handed out by the interrupt allocator.
  ///
  /// Source 0 is reserved (the "no interrupt" sentinel in PLIC/APLIC), so the
  /// default first real source is 1.
  final int interruptBase;

  /// The global system interrupt (GSI) that the interrupt controller's source
  /// 0 answers to.
  ///
  /// [interruptAssignments] names a controller source. ACPI names a GSI. The
  /// two spaces share an origin here: the GSI of a device is its source number
  /// plus this base, and an OS gets the source back with
  /// `source = gsi - gsiBase`. One SoC has one interrupt controller today and
  /// it owns the numbers from the start of the space, so the default is 0.
  ///
  /// This is the only place the origin is stated. The ACPI generator adds it
  /// to every `_CRS` interrupt and returns it from the controller's `_GSB`, so
  /// a change moves the whole space at once. Firmware must put the same value
  /// in the `GsiBase` field of the controller's MADT record: Linux matches the
  /// MADT record to the namespace device by that pair, and a mismatch (or a
  /// missing `_GSB`) stops the interrupt controller from probing at all.
  final int interruptGsiBase;

  /// The interrupt controller's contexts, in hardware context order.
  ///
  /// Entry N describes context N of the SoC's PLIC/APLIC: which hart claims
  /// from it and which hart-local cause it drives. [generateDts] emits it as
  /// `interrupts-extended`, and the SoC integrator wires `ext_irq_<N>` from the
  /// same list, so the tables and the wires stay in step.
  final List<HarborInterruptContext> interruptContexts;

  /// Add an active-low external reset input (`reset_n`) that ORs into the
  /// power-on reset. A board reset button can then restart the whole SoC (core
  /// to its reset vector, peripherals + DDR controller re-init) without a full
  /// FPGA reconfig. Only affects the FPGA power-on-reset path; the ASIC/sim
  /// path already takes a real external `reset` pin.
  final bool externalReset;

  /// Adds a software reset request to the SoC reset. The request comes from
  /// the controller that [addResetController] takes, and [buildFabric] throws
  /// when there is none.
  final bool softReset;

  /// Reservation slots per monitored memory slave that masters added with
  /// `exclusiveIds: HarborExclusive.auto` share (see
  /// [HarborExclusive.slotCounts]).
  final int exclusiveSlotBudget;

  /// The reservation granule of the memory exclusive monitors, in bytes.
  final int exclusiveGranuleBytes;

  /// Creates a new SoC.
  ///
  /// Accepts an optional list of [clocks] to generate PLL-derived
  /// clock domains. If empty, the external `clk` input is used directly.
  HarborSoC({
    required String name,
    required this.compatible,
    String? model,
    this.manufacturer,
    this.board,
    this.fabricKind = HarborFabricKind.wishbone,
    this.fabricTopology,
    this.acpiOemId = 'LILSEM',
    this.acpiOemTableId = 'HARBOR',
    this.svdVendor = 'Lilith Semiconductor',
    this.svdVersion = '1.0',
    this.interruptBase = 1,
    this.interruptGsiBase = 0,
    this.interruptContexts = const [],
    this.externalReset = false,
    this.softReset = false,
    this.cpus = const [],
    this.target,
    this.exclusiveSlotBudget = HarborExclusive.defaultSlotBudget,
    this.exclusiveGranuleBytes = HarborExclusive.defaultGranuleBytes,
    List<HarborClockConfig> clocks = const [],
    XilinxDdr3TreeSpec? xilinxDdr3Tree,
  }) : model = model ?? name,
       _explicitModel = model,
       super(name, name: name) {
    if (exclusiveSlotBudget < 1) {
      throw ArgumentError.value(
        exclusiveSlotBudget,
        'exclusiveSlotBudget',
        'must be at least 1',
      );
    }
    final g = exclusiveGranuleBytes;
    if (g < 1 || g & (g - 1) != 0 || g > 128) {
      throw ArgumentError.value(
        g,
        'exclusiveGranuleBytes',
        'must be a power of two of at most 128',
      );
    }
    createPort('clk', PortDirection.input);
    _boardClk = _buildBoardClock();

    final hasClockDomains = clocks.isNotEmpty;

    // Reset source is target-aware. FPGA targets with clock domains generate
    // an internal power-on reset: FPGA registers have a defined power-up
    // state of zero after configuration, so a counter self-starts at 0 and
    // holds reset asserted for its first 128 cycles, then releases forever
    // (it deliberately has no reset of its own: the power-up value is its
    // initializer). Everything else (FPGA SoCs without clock domains, ASIC
    // tapeouts whose flops have NO defined power-up state, and targetless/
    // simulation SoCs) gets a real external reset pin instead: the board,
    // PMIC, or testbench owns reset.
    // Without one of these, nonzero-reset state (such as a core's
    // reset-vector PC) never loads and the SoC wedges fetching from 0.
    final usePowerOnReset = hasClockDomains && target is HarborFpgaTarget;
    if (!usePowerOnReset) {
      createPort('reset', PortDirection.input);
    } else if (externalReset) {
      // Active-low board reset (e.g. an Arty RESET button), ORed into the POR
      // below so a press restarts the whole SoC. Held deasserted (high) by the
      // pad's external pull-up when the button is not pressed.
      createPort('reset_n', PortDirection.input);
    }

    Logic resetSignal;
    if (usePowerOnReset) {
      final porCount = Logic(name: 'porCount', width: 8);
      Sequential(_boardClk, [
        If(~porCount[7], then: [porCount < porCount + 1]),
      ]);
      final por = (~porCount[7]).named('porReset');
      resetSignal = externalReset
          ? (por | ~input('reset_n')).named('sysReset')
          : por;
    } else {
      resetSignal = input('reset');
    }
    _hardReset = resetSignal;
    if (softReset) {
      _softResetRequest = Logic(name: 'softResetRequest');
      resetSignal = (resetSignal | _softResetRequest!).named('sysResetSoft');
    }
    _systemReset = resetSignal;
    _pinReset = !usePowerOnReset
        ? input('reset')
        : externalReset
        ? ~input('reset_n')
        : null;

    _clockGen = HarborClockGenerator(
      parent: this,
      inputClk: _boardClk,
      inputReset: _hardReset,
      softReset: _softResetRequest,
      target: target,
    );

    // Xilinx DDR3-fast (single-oscillator, e.g. Arty S7): build the shared DDR3
    // clock tree HERE (from the `clk` pin). The core/sys clock is generated by a
    // SEPARATE PLL (not a spare CLKOUT of the DDR MMCM): two outputs of one MMCM
    // are phase-locked at a fixed sub-cycle relationship, which parks the async
    // sys<->ctrl CDC synchronizer at a pathological metastable phase and corrupts
    // crossed reads (the creek boot coin-flip). Two independent PLLs drift, so
    // the crossing is genuinely async. Both PLLs source one shared input BUFG so
    // openXC7 accepts two PLLs on the pin's single clock-capable route.
    _hasDdr3ClockTree = xilinxDdr3Tree != null;
    final ddrSpec = xilinxDdr3Tree;
    ({Logic coreClk, Logic locked, double coreMhz})? corePll;
    if (ddrSpec != null) {
      final sharedIn = addSubModule(XilinxBufg(name: 'sysosc_bufg'));
      sharedIn.input('I').srcConnection! <= _boardClk;
      // Stable aliases keep timing constraints independent of duplicate BUFG
      // port-name disambiguation in the generated RTL (O, O_0, ...).
      final shared = sharedIn.output('O').named('sysosc_clk');
      // Decoupled core PLL off the shared input. The DDR tree no longer emits
      // its CLKOUT5 core clock.
      corePll = buildXilinxCorePll(
        this,
        source: shared,
        sourceHz: ddrSpec.sourceHz,
        coreClkHz: ddrSpec.coreClkHz,
      );
      _xilinxCoreClkMhz = corePll.coreMhz;
      _xilinxSourceClkMhz = ddrSpec.sourceHz / 1e6;
      xilinxDdr3Clocks = buildXilinxDdr3ClockTree(
        this,
        source: shared,
        sourceHz: ddrSpec.sourceHz,
        ddrCkHz: ddrSpec.ddrCkHz,
        idelayRefHz: ddrSpec.idelayRefHz,
        dqsPhaseDeg: ddrSpec.dqsPhaseDeg,
        // Core clock now comes from the dedicated corePll, not CLKOUT5. When the
        // DDR runs a CK/8 controller, CLKOUT5 becomes that gearbox clock instead.
        coreClkHz: null,
        ddrGearRatio: ddrSpec.ddrGearRatio,
      );
    } else {
      xilinxDdr3Clocks = null;
    }

    for (final clkConfig in clocks) {
      if (clkConfig.providedByDdr3Tree) {
        if (corePll == null) {
          throw StateError(
            'clock "${clkConfig.name}" is providedByDdr3Tree but no '
            'xilinxDdr3Tree/coreClkHz was supplied to build its core clock.',
          );
        }
        // Hold reset until BOTH the core PLL and the DDR3 clock-tree PLL have
        // locked (the belt-and-suspenders timer in createDomainFromClock still
        // releases if a LOCKED never reaches the fabric). Gating only on the
        // core PLL left the DDR PLL's LOCKED unconnected, so the system could
        // release reset before the DDR clock tree was stable, and nothing ever
        // observed a DDR PLL lock-loss: a placement-independent, different-each-
        // boot hazard on top of the DDR's own margin.
        final ddrLocked = xilinxDdr3Clocks?.locked;
        final combinedLocked = ddrLocked == null
            ? corePll.locked
            : (corePll.locked & ddrLocked).named('core_ddr_pll_locked');
        // Give the PLL-derived BUFG output a stable name for generated timing
        // constraints. ROHD otherwise disambiguates output ports as O/O_0.
        final coreClk = corePll.coreClk.named('core_clk');
        _clockDomains[clkConfig.name] = _clockGen.createDomainFromClock(
          clkConfig,
          coreClk,
          locked: combinedLocked,
        );
        continue;
      }
      _addPllClock(clkConfig);
    }
  }

  /// Adds a clock domain from [config] after the constructor, for a helper
  /// that needs its own domains. A [HarborClockConfig.coClkosSecondary]
  /// adds the secondary domain too. Returns the domain of [config]. Call it
  /// before [build], and not for a name that already has a domain.
  HarborClockDomain addClockDomain(HarborClockConfig config) {
    if (_clockDomains.containsKey(config.name)) {
      throw ArgumentError.value(
        config.name,
        'config',
        'a clock domain with this name exists',
      );
    }
    _addPllClock(config);
    return _clockDomains[config.name]!;
  }

  void _addPllClock(HarborClockConfig clkConfig) {
    final sec = clkConfig.coClkosSecondary;
    if (sec != null) {
      // One EHXPLLL drives both: CLKOP = this domain, CLKOS = the secondary.
      // Avoids a 2nd PLL block that may not lock on silicon.
      final shared = _clockGen.createDomainWithSecondary(
        clkConfig,
        secondaryFrequency: sec.frequency,
        secondaryName: sec.name,
        secondaryTolerancePpm: sec.tolerancePpm,
      );
      // Register the secondary FIRST so a 'sys'-named secondary stays the
      // default clock (values.first), then the CLKOP primary.
      _clockDomains[sec.name] = shared.secondary;
      _clockDomains[clkConfig.name] = shared.primary;
    } else {
      final t = target;
      // A design with the DDR3 clock tree has its own clock script, so its
      // generated RTL stays as it was.
      final domain = _clockGen.createDomain(
        clkConfig,
        namePllClock:
            !_hasDdr3ClockTree &&
            t is HarborFpgaTarget &&
            t.vendor == HarborFpgaVendor.openXc7,
      );
      _clockDomains[clkConfig.name] = domain;
      final pll = domain.pllClock;
      if (pll != null) _xilinxPllClockMhz[pll.net] = pll.hz / 1e6;
    }
  }

  // Throws when the hold of [controller] on [clockDomainName] is under 4
  // edges of the slowest clock domain. A domain added later can make it so.
  void _checkResetHold(
    HarborResetController controller,
    String? clockDomainName,
  ) {
    final need = requiredResetHoldCycles(clockDomainName);
    if (controller.minHoldCycles >= need) return;
    final fix = need > HarborResetController.maxMinHoldCycles
        ? 'No valid minHoldCycles exists for this clock ratio, since the '
              'most it takes is ${HarborResetController.maxMinHoldCycles}. '
              'Put the controller on a slower clock domain.'
        : 'Build it with HarborResetController(minHoldCycles: $need).';
    throw ArgumentError(
      'the reset controller needs minHoldCycles of at least $need, which '
      'is 4 edges of the slowest clock domain, but it has '
      '${controller.minHoldCycles}. $fix',
    );
  }

  /// The least reset hold time in cycles of a controller on the domain
  /// [clockDomainName]: 4 edges of the slowest clock domain. A SoC with no
  /// clock domains needs none.
  int requiredResetHoldCycles(String? clockDomainName) {
    final own = domainFor(clockDomainName)?.config.frequency;
    if (own == null || _clockDomains.isEmpty) return 1;
    final slowest = _clockDomains.values
        .map((d) => d.config.frequency)
        .reduce((a, b) => a < b ? a : b);
    return (4 * own + slowest - 1) ~/ slowest;
  }

  /// Adds [controller] and ORs its `system_reset` into the SoC reset beside
  /// the reset pin, so a write of 0xDEAD to its SW_RST_KEY register reboots
  /// the SoC. The SoC needs `softReset: true`, and it takes one controller.
  ///
  /// - The controller runs on the hard reset only, the reset pin or the
  ///   power-on reset, so it keeps its state and its reset cause through a
  ///   soft reset. It holds the soft reset for its hold time, 256 clock
  ///   cycles by default, and then releases it on a clock edge.
  /// - The controller resets its own bus port with the SoC reset, so a
  ///   response that is still in the port at the start of a reset never
  ///   reaches the fabric after it.
  /// - The reset pin is the controller's `ext_reset`, so a pin reset reads as
  ///   external. A SoC that has only a reset pin and no power-on reset
  ///   (simulation, ASIC) also reads external after a cold boot.
  /// - The controller needs `minHoldCycles` of at least
  ///   [requiredResetHoldCycles], and this throws when it has less.
  /// - A [watchdog] makes WDOG_RST_EN 1 after reset, so an expiry resets the
  ///   SoC. Without one it is 0. The watchdog must run on the clock domain of
  ///   the controller, and this throws when it does not.
  /// - [watchdog] and [debug] are optional reset requests for its `wdog_reset`
  ///   and `debug_reset` inputs. A controller on another fabric clock is not
  ///   accepted, since its bus port would then reset itself.
  T addResetController<T extends HarborResetController>(
    T controller, {
    String? clockDomainName,
    Logic? watchdog,
    Logic? debug,
  }) {
    final request = _softResetRequest;
    if (request == null) {
      throw StateError('addResetController needs softReset: true');
    }
    if (_resetController != null) {
      throw StateError('a SoC takes one reset controller');
    }
    if (controller.tryInput(BusSlavePort.fabricClkPort) != null) {
      throw ArgumentError(
        'the reset controller must run on the fabric clock, without a '
        'crossing',
      );
    }
    if (watchdog != null) {
      for (final e in _peripherals) {
        if (!identical(e.module, watchdog.parentModule)) continue;
        if (!identical(
          domainFor(e.clockDomainName),
          domainFor(clockDomainName),
        )) {
          throw ArgumentError(
            'the watchdog ${e.module.name} and the reset controller run on '
            'different clock domains, and wdog_reset has no synchroniser. '
            'Put both on one domain.',
          );
        }
      }
    }
    _checkResetHold(controller, clockDomainName);
    _resetController = controller;
    _resetControllerDomain = clockDomainName;
    _resetWatchdog = watchdog;
    _resetDebug = debug;
    addPeripheral(controller, clockDomainName: clockDomainName);
    request <= controller.systemReset;
    return controller;
  }

  /// Gets a clock domain by name.
  ///
  /// Returns null if no domain with that name exists. Falls back to
  /// the raw `clk`/`reset` inputs if no domains were configured.
  HarborClockDomain? clockDomain(String name) => _clockDomains[name];

  /// The default clock and reset signals.
  ///
  /// If clock domains are configured, returns the first domain.
  /// Otherwise returns the raw input clock and reset.
  (Logic clk, Logic reset) get defaultClock {
    if (_clockDomains.isNotEmpty) {
      // Prefer the conventional 'sys' bus domain: it may not be the first
      // registered entry when it is a CLKOS secondary of another PLL, and fall
      // back to the first domain otherwise.
      final d = _clockDomains['sys'] ?? _clockDomains.values.first;
      return (d.clk, d.reset);
    }
    return (_boardClk, _systemReset);
  }

  /// Joins a differential board clock (`clk` and the target's
  /// [HarborFpgaTarget.clockNPortName]) through an IBUFDS.
  Logic _buildBoardClock() {
    final t = target;
    final nName = t is HarborFpgaTarget ? t.clockNPortName : null;
    if (nName == null) return input('clk');
    t as HarborFpgaTarget;
    if (t.vendor != HarborFpgaVendor.vivado &&
        t.vendor != HarborFpgaVendor.openXc7) {
      throw UnsupportedError(
        'A differential board clock is only built for Xilinx targets.',
      );
    }
    if (t.clockPortName != 'clk') {
      throw ArgumentError(
        'The SoC clock input is `clk`, but the target names its P side '
        '"${t.clockPortName}".',
      );
    }
    createPort(nName, PortDirection.input);
    final buf = addSubModule(XilinxIbufds(name: 'sysclk_ibufds'));
    buf.input('I').srcConnection! <= input('clk');
    buf.input('IB').srcConnection! <= input(nName);
    // A fixed net name lets the XDC put the board clock constraint on it.
    final net = Logic(name: HarborFpgaTarget.differentialClockNet);
    net <= buf.o;
    return net;
  }

  /// All registered peripherals.
  List<BridgeModule> get peripherals =>
      _peripherals.map((e) => e.module).toList();

  /// All registered bus masters.
  List<BridgeModule> get masters => _masters.map((e) => e.module).toList();

  /// Adds a peripheral to the SoC.
  ///
  /// The peripheral must implement [HarborDeviceTreeNodeProvider] so
  /// the address mapping can be derived from its [HarborDeviceTreeNode.reg].
  ///
  /// Clock and reset are auto-wired. The bus interface is connected
  /// when [buildFabric] is called.
  ///
  /// [busTimeoutCycles] sets the timeout of this peripheral on the fabric
  /// and overrides the one of [buildFabric]. 0 turns it off.
  T addPeripheral<T extends BridgeModule>(
    T peripheral, {
    String? clockDomainName,
    int? busTimeoutCycles,
  }) {
    if (peripheral is! HarborDeviceTreeNodeProvider) {
      throw ArgumentError(
        'Peripheral ${peripheral.name} must implement '
        'HarborDeviceTreeNodeProvider.',
      );
    }

    final dt = (peripheral as HarborDeviceTreeNodeProvider).dtNode;
    _peripherals.add(
      _PeripheralEntry(
        module: peripheral,
        addressRange: dt.reg,
        clockDomainName: clockDomainName,
        busTimeoutCycles: busTimeoutCycles,
      ),
    );
    if (peripheral is HarborSecondarySlaveProvider) {
      for (final slave
          in (peripheral as HarborSecondarySlaveProvider).secondarySlaves) {
        addPeripheralSlave(peripheral, slave.busInterfaceName, slave.range);
      }
    }
    _wireOnce(peripheral, clockDomainName);
    if (peripheral.tryInput(BusSlavePort.fabricClkPort) != null) {
      final (clk, reset) = defaultClock;
      peripheral.input(BusSlavePort.fabricClkPort).srcConnection! <= clk;
      peripheral.input(BusSlavePort.fabricResetPort).srcConnection! <= reset;
    }

    // A driver that divides its input clock cannot work without knowing the
    // rate. The peripheral does not know which domain it landed on, the SoC
    // does, so fill it in rather than let the property go silently missing.
    if (peripheral is HarborInputClockConsumer) {
      final consumer = peripheral as HarborInputClockConsumer;
      if (consumer.inputClockHz == 0) {
        final hz = inputClockHzFor(clockDomainName);
        if (hz > 0) consumer.provideInputClockHz(hz);
      }
    }
    return peripheral;
  }

  /// Rate in Hz of the clock a peripheral registered under [clockDomainName]
  /// actually runs on.
  ///
  /// Returns 0 when no clock domains are configured, because the peripheral
  /// then rides the raw `clk` pin and only the board knows its rate. 0 leaves
  /// the property OUT rather than emitting a guess: a missing `clock-frequency`
  /// stops a driver at probe with a clear message, while a wrong one makes it
  /// compute a wrong divider and fail somewhere much less obvious.
  int inputClockHzFor(String? clockDomainName) =>
      domainFor(clockDomainName)?.config.frequency ?? 0;

  /// Maps a second slave interface of an already-added peripheral into
  /// the fabric at [range]. Unlike [addPeripheral] it does NOT register the
  /// module again (its dtNode / clock / interrupts are already wired) - it only
  /// adds a decoder slot bound to [busInterfaceName]. For peripherals that
  /// expose more than one bus face, e.g. the ddr3 controller's runtime-training
  /// register window carved from the top of its own region.
  void addPeripheralSlave(
    BridgeModule module,
    String busInterfaceName,
    BusAddressRange range,
  ) {
    _secondarySlaves.add(
      _SecondarySlave(
        module: module,
        busInterfaceName: busInterfaceName,
        addressRange: range,
      ),
    );
  }

  /// Adds a bus master (e.g., CPU core) to the SoC.
  ///
  /// [busInterfaceName] is the name of the master's provider interface
  /// (default `'dataBus'`). It must be native to [fabricKind].
  ///
  /// When [pipeline] is set, a [WishboneRegisterStage] is interposed on this
  /// master's leg to the fabric, so a physically distant master (for example
  /// a DMA engine at an I/O pad) drives a registered bus instead of a
  /// die-crossing combinational one. That costs two extra bus-latency cycles
  /// on this master alone. It needs a Wishbone fabric.
  ///
  /// [channel] names the fabric channel this master joins. The masters of a
  /// channel reach the slaves [buildFabric] gives that channel in
  /// `channelSlaves`. The default `'primary'` keeps the classic SoC.
  ///
  /// [memory] marks a memory port (see [HarborFabricMaster.memory]). Null
  /// picks true for an `Axi4Interface` and false for every other port, so a
  /// master built on [HarborMemoryMasterPort] passes true. [outstanding] is
  /// the most requests in flight (see [HarborFabricMaster.outstanding]).
  /// [readChannel] picks the read channel at a slave with more than one (see
  /// [HarborFabricMaster.readChannel]). [exclusiveIds] turns on AXI4
  /// exclusive access for this master (see [HarborFabricMaster.exclusiveIds]
  /// and [memoryBusShape]).
  ///
  /// [realtime] makes this a real-time master (see
  /// [HarborFabricMaster.realtime]): it wins arbitration, and the bursts of
  /// the other masters are capped while it waits (see
  /// [buildFabric]'s `realtimeBurstCap`).
  ///
  /// [writeStallFree] declares that this master never stalls write data
  /// inside a burst (see [HarborFabricMaster.writeStallFree]).
  ///
  /// [targetRanges] lists the address ranges this master is meant to reach.
  /// [buildFabric] throws when a range is not fully covered by the slaves of
  /// the master's channel. Null skips the check.
  ///
  /// [burstRanges] lists the address ranges where this master issues
  /// multi-beat bursts, for example the ranges a cache with a line over one
  /// bus word refills from, or a DMA engine moves data to. A master with no
  /// [burstRanges] issues single beats only. [buildFabric] throws when a
  /// burst range holds a slave that cannot take bursts (see
  /// [HarborFabric.slaveTakesBursts]).
  ///
  /// A module can be a peripheral and a master, or have more than one
  /// master port. Its master then takes the name
  /// `<module>_<busInterfaceName>` on the fabric.
  ///
  /// Clock and reset are auto-wired.
  T addMaster<T extends BridgeModule>(
    T master, {
    String busInterfaceName = 'dataBus',
    String? clockDomainName,
    bool pipeline = false,
    String channel = 'primary',
    bool? memory,
    int? outstanding,
    int? readChannel,
    int? exclusiveIds,
    bool realtime = false,
    bool writeStallFree = false,
    List<BusAddressRange>? targetRanges,
    List<BusAddressRange>? burstRanges,
  }) {
    _masters.add(
      _MasterEntry(
        module: master,
        busInterfaceName: busInterfaceName,
        pipeline: pipeline,
        channel: channel,
        memory: memory,
        outstanding: outstanding,
        readChannel: readChannel,
        exclusiveIds: exclusiveIds,
        realtime: realtime,
        writeStallFree: writeStallFree,
        targetRanges: targetRanges,
        burstRanges: burstRanges,
      ),
    );
    _wireOnce(master, clockDomainName);
    return master;
  }

  /// Pulls a peripheral's port up to the SoC level as an external pin.
  ///
  /// Useful for UART TX/RX, GPIO, SPI, etc.
  PortReference exposePin(
    BridgeModule peripheral,
    String portName, {
    String? externalName,
  }) {
    final topName = externalName ?? '${peripheral.name}_$portName';
    // Remembered so a sim model can be told the TOP-LEVEL name of a pin it
    // has to read; the peripheral itself only knows its own port names.
    (_exposedPins[peripheral] ??= {})[portName] = topName;
    return pullUpPort(peripheral.port(portName), newPortName: topName);
  }

  /// Binds the pins of [engine] to the LED pins of [board].
  ///
  /// Channel `k` of [engine] drives `board.ledChannels[k]`. A catalog pin
  /// such as `led[3]` joins one top-level vector port `led`, bit 3, so that
  /// the pin constraints match. A pin without an index, such as `led0_r`,
  /// is a 1-bit port of the same name. The pin indices of one vector must be
  /// 0 to N-1 with no gap.
  void bindBoardLeds(HarborLedEngine engine, HarborBoard board) {
    if (board.ledChannels.length > engine.channels.length) {
      throw ArgumentError(
        '${board.name} has ${board.ledChannels.length} LED channels but the '
        'engine has ${engine.channels.length}',
      );
    }
    final vectors = <String, Map<int, Logic>>{};
    for (var k = 0; k < board.ledChannels.length; k++) {
      final pins = board.ledChannels[k].pins;
      final outs = engine.channelOut(k);
      if (pins.length != outs.length) {
        throw ArgumentError(
          'LED channel $k has ${outs.length} outputs for ${pins.length} pins',
        );
      }
      for (var i = 0; i < pins.length; i++) {
        final m = RegExp(r'^(\w+)\[(\d+)\]$').firstMatch(pins[i]);
        if (m == null) {
          addOutput(pins[i]) <= outs[i];
        } else {
          (vectors[m.group(1)!] ??= {})[int.parse(m.group(2)!)] = outs[i];
        }
      }
    }
    for (final MapEntry(key: name, value: bits) in vectors.entries) {
      for (var i = 0; i < bits.length; i++) {
        if (!bits.containsKey(i)) {
          throw ArgumentError('LED pin $name[$i] is missing');
        }
      }
      addOutput(name, width: bits.length) <=
          [for (var i = 0; i < bits.length; i++) bits[i]!].rconcat();
    }
  }

  /// Peripheral -> (its port name -> top-level port name), for every pin
  /// pulled up with [exposePin].
  final Map<BridgeModule, Map<String, String>> _exposedPins = {};

  /// The clock nets and rates of every [HarborClockRateProvider] module in
  /// the hierarchy of the SoC, a bus peripheral or not. Each module gets its
  /// instance path from the SoC, with `.` between the names. Call it after
  /// the build.
  Map<String, double> _peripheralClockMhz() {
    final rates = <String, double>{};
    void walk(Module m, String path) {
      if (m is HarborClockRateProvider) {
        rates.addAll((m as HarborClockRateProvider).clockRates(path));
      }
      for (final child in m.subModules) {
        walk(child, '$path.${child.uniqueInstanceName}');
      }
    }

    for (final child in subModules) {
      walk(child, child.uniqueInstanceName);
    }
    return rates;
  }

  /// Lines of every [HarborPinConstraintProvider] peripheral, each line once.
  List<String> _devicePinConstraints(HarborFpgaTarget t) {
    final lines = <String>{};
    for (final e in _peripherals) {
      final m = e.module;
      if (m is! HarborPinConstraintProvider) continue;
      final pins = _exposedPins[m] ?? const {};
      lines.addAll(
        (m as HarborPinConstraintProvider).pinConstraints(
          t,
          (p) => pins[p],
          m.name,
        ),
      );
    }
    return lines.toList();
  }

  /// Top-level names of [peripheral]'s exposed pins. Empty if it has none.
  Map<String, String> exposedPinsOf(BridgeModule peripheral) =>
      Map.unmodifiable(_exposedPins[peripheral] ?? const {});

  /// The top-level clock port and frequency a peripheral actually runs on
  /// under [HarborSimTarget].
  ///
  /// Under that target every non-primary domain is its own top-level input
  /// named `<domain>_clk` (see `HarborClockGenerator`), and the primary is
  /// plain `clk`. A host-side model has to agree with this or it samples at
  /// the wrong rate: a UART sink ticked on a 100 MHz clock while sizing its
  /// bit period from a 50 MHz one decodes pure garbage.
  ({String port, int hz}) simClockOf(BridgeModule peripheral, int primaryHz) {
    final entry = _peripherals
        .where((e) => identical(e.module, peripheral))
        .firstOrNull;
    final domainName = entry?.clockDomainName;
    // A peripheral with no explicit domain is wired to [defaultClock] (the
    // 'sys' bus domain when present), NOT the primary input clock. Resolve the
    // same fallback so the reported clock matches the one the peripheral's bus
    // is actually clocked by, which is what a sim model must sample.
    final domain =
        (domainName != null ? _clockDomains[domainName] : null) ??
        _clockDomains['sys'] ??
        _clockDomains.values.firstOrNull;
    if (domain == null || domain.config.isPrimary) {
      return (port: 'clk', hz: primaryHz);
    }
    // A domain with no port of its own IS the input clock (it runs at the
    // source rate), so a model on it samples `clk`.
    final port = domain.simPort;
    if (port == null) return (port: 'clk', hz: primaryHz);
    return (port: port, hz: domain.config.frequency);
  }

  /// Checks the SoC for build-time integrity problems and returns every
  /// problem found as a human-readable string. An empty list means the SoC is
  /// consistent.
  ///
  /// [buildFabric] calls this and refuses to build when it returns anything,
  /// so these checks turn silent surprises into loud failures. The checks are:
  ///
  /// - peripheral address windows must not overlap,
  /// - a peripheral's register map must have no overlapping fields,
  /// - every register must fit within the peripheral's address block,
  /// - no interrupt number may be assigned to two peripherals.
  List<String> validate() {
    final errors = <String>[];

    // Peripheral address windows must not overlap.
    final mappings = _peripherals.indexed
        .map(
          (e) =>
              HarborAddressMapping(range: e.$2.addressRange, slaveIndex: e.$1),
        )
        .toList();
    errors.addAll(validateAddressMappings(mappings));

    // A second port may sit inside its own peripheral's window, but not in
    // the window of another peripheral or of another second port.
    for (final (i, a) in _secondarySlaves.indexed) {
      for (final b in _secondarySlaves.skip(i + 1)) {
        final x = a.addressRange;
        final y = b.addressRange;
        if (x.start < y.end && y.start < x.end) {
          errors.add(
            '${a.module.name}.${a.busInterfaceName} overlaps '
            '${b.module.name}.${b.busInterfaceName}: $x and $y',
          );
        }
      }
    }
    for (final slave in _secondarySlaves) {
      for (final e in _peripherals) {
        if (identical(e.module, slave.module)) continue;
        final a = slave.addressRange;
        final b = e.addressRange;
        if (a.start < b.end && b.start < a.end) {
          errors.add(
            '${slave.module.name}.${slave.busInterfaceName} overlaps '
            '${e.module.name}: $a and $b',
          );
        }
      }
    }

    // Register maps: internal overlaps and out-of-block registers. The register
    // map and its block size both come from the SVD view, so they are checked
    // against a single source.
    for (final entry in _peripherals) {
      final m = entry.module;
      if (m is! HarborSvdPeripheralProvider) continue;
      final provider = m as HarborSvdPeripheralProvider;
      for (final sp in [
        provider.svdPeripheral,
        ...provider.extraSvdPeripherals,
      ]) {
        final regs = sp.registers;
        if (regs == null) continue;

        for (final overlap in regs.validate()) {
          errors.add('${sp.name}: $overlap');
        }
        for (final f in regs.fields) {
          if (f.end > sp.size) {
            errors.add(
              "${sp.name}: register '${f.name}' @ 0x${f.offset.toRadixString(16)} "
              '(${f.width}B) exceeds address block size '
              '0x${sp.size.toRadixString(16)}',
            );
          }
        }
      }
    }

    // No interrupt number may be assigned twice.
    final seen = <int, String>{};
    interruptAssignments().forEach((module, irq) {
      final existing = seen[irq];
      if (existing != null) {
        errors.add(
          'interrupt $irq assigned to both $existing and ${module.name}',
        );
      } else {
        seen[irq] = module.name;
      }
    });

    return errors;
  }

  /// Builds the bus fabric that connects the masters to the peripherals.
  ///
  /// It runs [validate] first and throws a [StateError] for any problem.
  /// Call it after every [addPeripheral] and [addMaster], before [build].
  ///
  /// The fabric is a [HarborFabric] of [fabricKind] on the [defaultClock].
  /// Every master and peripheral port must be native to [fabricKind]. A slave
  /// sees the offset of the access in its own region, and an access that
  /// hits no slave ends with the native decode error (see [exposeBusError]
  /// for masters with no error signal). [HarborSram], [HarborSdram] and the
  /// [HarborDdr3] data port are memory slaves with their outstanding depth.
  ///
  /// When [pipeline] is set on a Wishbone fabric, a [WishboneRegisterStage]
  /// goes in front of every master, so no path from a master through the
  /// fabric is fully combinational. That costs two cycles per transfer. The
  /// AXI4 and TileLink fabrics register their edges already, so [pipeline]
  /// has no effect on them.
  ///
  /// [channelSlaves] maps a channel name to the set of slave module names
  /// the masters of that channel can reach. A master reaches no other slave.
  /// When it is null every master reaches every slave. A channel that has
  /// masters must appear in it, and every slave must be in reach of some
  /// channel. With more than one channel and no [fabricTopology], each
  /// channel gets its own shared fabric over its reach set, and each slave
  /// that more than one channel reaches gets a converge fabric in front of
  /// it, so the channels move at the same time and meet only there. With a
  /// [fabricTopology] it is one fabric of that topology with a reach set per
  /// master.
  ///
  /// [converge] selects how a shared slave merges its channels. Only
  /// [HarborMemConverge.arbiter] is built. The other modes throw
  /// [UnimplementedError].
  ///
  /// [busTimeoutCycles] is the timeout of every slave that does not hold
  /// memory (see [HarborFabricSlave.timeout]). A slave that times out is cut
  /// off until reset. Memory (system RAM, SRAM, flash, mask ROM) gets none,
  /// and [addPeripheral] can set the timeout of one peripheral.
  /// [maxGrantCycles] sets the Wishbone grant hold cap (see
  /// [WishboneArbiter.maxGrantCycles]). It is [harborDefaultWishboneGrantCap]
  /// on a Wishbone fabric with two or more masters, so a master that polls
  /// back to back cannot starve the others. Pass null or 0 to turn it off.
  /// [busTimeoutCycles] is off by default.
  /// [realtimeBurstCap] is the most beats of a burst another master sends
  /// to a slave in one grant while a real-time master waits (see
  /// [HarborFabric.build]). It has no effect without a real-time master.
  void buildFabric({
    bool pipeline = false,
    Map<String, Set<String>>? channelSlaves,
    HarborMemConverge converge = HarborMemConverge.arbiter,
    int? busTimeoutCycles,
    int? maxGrantCycles = harborDefaultWishboneGrantCap,
    int realtimeBurstCap = HarborFabric.defaultRealtimeBurstCap,
  }) {
    final errors = validate();
    if (errors.isNotEmpty) {
      throw StateError('Validation errors in $name:\n${errors.join("\n")}');
    }
    if (softReset && _resetController == null) {
      throw StateError('$name has softReset but no reset controller');
    }
    if (_resetController case final c?) {
      _checkResetHold(c, _resetControllerDomain);
    }

    if (_peripherals.isEmpty) {
      for (final m in _masters) {
        final target = m.targetRanges?.firstOrNull;
        if (target != null) {
          throw StateError(
            '${m.module.name}_${m.busInterfaceName}: target range $target '
            'is not covered by any slave, the SoC has none',
          );
        }
      }
    }
    if (_peripherals.isEmpty || _masters.isEmpty) return;
    if (fabrics.isNotEmpty) {
      throw StateError('buildFabric was already called');
    }

    final slaves =
        <({BridgeModule module, String iface, BusAddressRange range})>[
          for (final e in _peripherals)
            (module: e.module, iface: 'bus', range: e.addressRange),
          for (final s in _secondarySlaves)
            (
              module: s.module,
              iface: s.busInterfaceName,
              range: s.addressRange,
            ),
        ];
    String slaveName(int i) => i < _peripherals.length
        ? slaves[i].module.name
        : '${slaves[i].module.name}_${slaves[i].iface}';

    for (final s in slaves) {
      _checkNative(s.module, s.module.interface(s.iface).interface, 'slave');
    }
    for (final m in _masters) {
      _checkNative(
        m.module,
        m.module.interface(m.busInterfaceName).interface,
        'master',
      );
    }
    _checkClockDomains();

    // The slaves each channel reaches. Null when every master reaches all.
    final channels = {for (final m in _masters) m.channel};
    Set<String>? reachOf(String channel) {
      if (channelSlaves == null) return null;
      final names = channelSlaves[channel];
      if (names == null) {
        throw StateError(
          'channel "$channel" has masters but is absent from channelSlaves',
        );
      }
      final reach = {
        for (var i = 0; i < slaves.length; i++)
          if (names.contains(slaves[i].module.name)) slaveName(i),
      };
      if (reach.isEmpty) {
        throw StateError('channel "$channel" reaches no slave');
      }
      return reach;
    }

    final reach = {for (final c in channels) c: reachOf(c)};
    for (final m in _masters) {
      for (final target in m.targetRanges ?? const <BusAddressRange>[]) {
        final covers = [
          for (var i = 0; i < slaves.length; i++)
            if (reach[m.channel]?.contains(slaveName(i)) ?? true)
              slaves[i].range,
        ]..sort((a, b) => a.start.compareTo(b.start));
        var next = target.start;
        for (final r in covers) {
          if (r.start <= next && r.end > next) next = r.end;
        }
        if (next < target.end) {
          throw StateError(
            '${m.module.name}_${m.busInterfaceName}: target range $target is '
            'not covered by the slaves of channel "${m.channel}"',
          );
        }
      }
    }
    if (channelSlaves != null) {
      final orphans = [
        for (var i = 0; i < slaves.length; i++)
          if (!reach.values.any((r) => r!.contains(slaveName(i))))
            slaves[i].module.name,
      ];
      if (orphans.isNotEmpty) {
        throw StateError(
          'slaves unreachable from every channel: ${orphans.join(", ")}',
        );
      }
      final shared = [
        for (var i = 0; i < slaves.length; i++)
          if (reach.values.where((r) => r!.contains(slaveName(i))).length > 1)
            i,
      ];
      if (shared.isNotEmpty &&
          channels.length > 1 &&
          converge != HarborMemConverge.arbiter) {
        throw UnimplementedError(
          'converge ${converge.name} not yet implemented',
        );
      }
    }

    final (clk, reset) = defaultClock;
    PairInterface slaveIntf(int i) =>
        slaves[i].module.interface(slaves[i].iface).interface;
    int timeoutOf(int i) {
      final own = i < _peripherals.length
          ? _peripherals[i].busTimeoutCycles
          : null;
      return own ?? (_isMemory(slaves[i].module) ? 0 : busTimeoutCycles ?? 0);
    }

    ({bool memory, int outstanding}) shapeOf(int i) =>
        _slaveShape(slaves[i].module, slaves[i].iface, slaveIntf(i));

    for (final m in _masters) {
      for (final target in m.burstRanges ?? const <BusAddressRange>[]) {
        for (var i = 0; i < slaves.length; i++) {
          final r = slaves[i].range;
          if (!(reach[m.channel]?.contains(slaveName(i)) ?? true)) continue;
          if (r.start >= target.end || r.end <= target.start) continue;
          if (HarborFabric.slaveTakesBursts(
            fabricKind,
            memory: shapeOf(i).memory,
          )) {
            continue;
          }
          throw StateError(
            '${m.module.name}_${m.busInterfaceName}: burst range $target '
            'holds ${slaveName(i)} at $r, which cannot take bursts',
          );
        }
      }
    }
    // The map check takes the largest Wishbone burst block of any slave.
    final burstBeats = slaves
        .map(
          (s) => switch (s.module) {
            HarborSram(:final wishboneBurstBeats) ||
            HarborDdr3(:final wishboneBurstBeats) ||
            HarborSdram(:final wishboneBurstBeats) => wishboneBurstBeats,
            _ => 8,
          },
        )
        .fold(8, max);

    // The read-only ports of a slave with more than one read channel.
    List<PairInterface> readIntfs(int i) => switch (slaves[i].module) {
      final HarborDdr3 d when slaves[i].iface == 'bus' => [
        for (var k = 1; k < d.readChannels; k++)
          d.interface('bus_r$k').interface,
      ],
      _ => const [],
    };

    // The exclusive monitor IDs of a memory slave port.
    HarborAxi4Exclusive? exclusiveOf(int i) => switch (slaves[i].module) {
      HarborSram(:final exclusive) ||
      HarborDdr3(:final exclusive) ||
      HarborSdram(:final exclusive) when slaves[i].iface == 'bus' => exclusive,
      _ => null,
    };
    for (var i = 0; i < slaves.length; i++) {
      final g = exclusiveOf(i)?.granuleBytes;
      if (g != null && g != exclusiveGranuleBytes) {
        throw ArgumentError(
          '${slaveName(i)}: the exclusive monitor granule is $g bytes, but '
          'exclusiveGranuleBytes is $exclusiveGranuleBytes. Build the memory '
          'with memoryBusShape().',
        );
      }
    }

    HarborFabricSlave realSlave(int i) => HarborFabricSlave(
      name: slaveName(i),
      range: slaves[i].range,
      interface: slaveIntf(i),
      readInterfaces: readIntfs(i),
      exclusive: exclusiveOf(i),
      outstanding: shapeOf(i).outstanding,
      timeout: timeoutOf(i),
      memory: shapeOf(i).memory,
      offset: true,
      narrowOk: slaves[i].module is HarborNarrowSlaveOk,
    );

    // A master takes its module name, or the module name plus its bus
    // interface name when a slave or another master has that name.
    final taken = {for (var i = 0; i < slaves.length; i++) slaveName(i)};
    String masterName(_MasterEntry m) {
      final base = m.module.name;
      final name = taken.contains(base)
          ? '${base}_${m.busInterfaceName}'
          : base;
      if (!taken.add(name)) {
        throw ArgumentError('two fabric masters are named $name');
      }
      return name;
    }

    final slotsOf = _exclusiveSlotsOf();
    final masters = <String, List<HarborFabricMaster>>{};
    for (final m in _masters) {
      var port = m.module.interface(m.busInterfaceName);
      if (m.pipeline && fabricKind == HarborFabricKind.wishbone) {
        port = _registerStage(port);
      }
      if (pipeline && fabricKind == HarborFabricKind.wishbone) {
        port = _registerStage(port);
      }
      final intf = port.interface;
      (masters[m.channel] ??= []).add(
        HarborFabricMaster(
          name: masterName(m),
          interface: intf,
          outstanding: m.outstanding,
          memory: m.isMemoryPort,
          reach: reach[m.channel],
          readChannel: m.readChannel,
          exclusiveIds: slotsOf[m],
          realtime: m.realtime,
          writeStallFree: m.writeStallFree,
        ),
      );
    }

    HarborFabricModule build(
      String name,
      HarborFabricTopology topology,
      List<HarborFabricMaster> ms,
      List<HarborFabricSlave> ss,
    ) {
      final f = HarborFabric.build(
        kind: fabricKind,
        topology: topology,
        clk: clk,
        reset: reset,
        masters: ms,
        slaves: ss,
        wishboneBurstBeats: burstBeats,
        maxGrantCycles: maxGrantCycles,
        realtimeBurstCap: realtimeBurstCap,
        name: name,
      );
      fabrics.add(f);
      return f;
    }

    // One fabric, unless channels keep the channel shape: a shared bus per
    // channel over its reach set, and a converge fabric in front of each
    // slave that more than one channel reaches.
    if (channels.length == 1 || fabricTopology != null) {
      build(
        'fabric',
        fabricTopology ?? HarborFabricTopology.shared,
        [for (final c in channels) ...masters[c]!],
        [for (var i = 0; i < slaves.length; i++) realSlave(i)],
      );
      return;
    }

    final order = channels.toList()
      ..sort((a, b) {
        if (a == b) return 0;
        if (a == 'primary') return -1;
        if (b == 'primary') return 1;
        return a.compareTo(b);
      });
    List<String> users(int i) => [
      for (final c in order)
        if (reach[c]?.contains(slaveName(i)) ?? true) c,
    ];
    final legs = <int, List<(String, PairInterface)>>{};
    for (final c in order) {
      final ss = <HarborFabricSlave>[];
      for (var i = 0; i < slaves.length; i++) {
        if (!(reach[c]?.contains(slaveName(i)) ?? true)) continue;
        if (users(i).length == 1) {
          ss.add(realSlave(i));
          continue;
        }
        if (readIntfs(i).isNotEmpty) {
          throw StateError(
            '${slaveName(i)}: a slave with more than one read channel cannot '
            'sit behind a converge fabric, use one fabric with a topology',
          );
        }
        // A leg to the converge fabric. It passes the full address on, and
        // on Wishbone it has ERR so a cut off reaches the master as ERR.
        // A narrow slave gets a leg of the fabric widths, and the converge
        // fabric adapts it.
        final (fabricAddrW, fabricDataW) = harborPortWidths(
          masters[c]!.first.interface,
        );
        final (slaveAddrW, slaveDataW) = harborPortWidths(slaveIntf(i));
        final leg = switch (slaveAddrW == fabricAddrW &&
                slaveDataW == fabricDataW
            ? slaveIntf(i)
            : harborWidenPort(
                slaveIntf(i),
                addressWidth: fabricAddrW,
                dataWidth: fabricDataW,
              )) {
          final WishboneInterface w => WishboneInterface(
            w.config.copyWith(useErr: true),
          ),
          final other => other.clone(),
        };
        (legs[i] ??= []).add((c, leg));
        ss.add(
          HarborFabricSlave(
            name: slaveName(i),
            range: slaves[i].range,
            interface: leg,
            outstanding: shapeOf(i).outstanding,
            memory: shapeOf(i).memory,
          ),
        );
      }
      build('fabric_$c', HarborFabricTopology.shared, [
        for (final m in masters[c]!)
          HarborFabricMaster(
            name: m.name,
            interface: m.interface,
            outstanding: m.outstanding,
            memory: m.memory,
            exclusiveIds: m.exclusiveIds,
            realtime: m.realtime,
            writeStallFree: m.writeStallFree,
          ),
      ], ss);
    }
    for (final MapEntry(key: i, value: ls) in legs.entries) {
      build(
        'converge_${slaveName(i)}',
        HarborFabricTopology.shared,
        [
          for (final (c, leg) in ls)
            HarborFabricMaster(
              name: c,
              interface: leg,
              outstanding: shapeOf(i).outstanding,
              memory: shapeOf(i).memory,
              realtime: masters[c]!.any((m) => m.realtime),
              writeStallFree: masters[c]!.every((m) => m.writeStallFree),
            ),
        ],
        [realSlave(i)],
      );
    }
  }

  // The masters in the order of the one fabric that [buildFabric] builds.
  List<_MasterEntry> get _fabricOrder {
    final channels = {for (final m in _masters) m.channel};
    return [
      for (final c in channels)
        for (final m in _masters)
          if (m.channel == c) m,
    ];
  }

  // The resolved exclusive slot count of each master, in fabric order. It
  // throws when exclusive masters cannot share one fabric.
  Map<_MasterEntry, int> _exclusiveSlotsOf() {
    final order = _fabricOrder;
    if (!order.any((m) => (m.exclusiveIds ?? 0) != 0)) {
      return {for (final m in order) m: 0};
    }
    final channels = {for (final m in order) m.channel};
    if (channels.length > 1 && fabricTopology == null) {
      throw StateError(
        'exclusive access needs one fabric, so a SoC with more than one '
        'channel needs a fabricTopology',
      );
    }
    final counts = HarborExclusive.slotCounts(
      [
        for (final m in order)
          switch (m.module.interface(m.busInterfaceName).interface) {
            final Axi4Interface a => a.idWidth,
            _ => 1,
          },
      ],
      [for (final m in order) m.exclusiveIds],
      budget: exclusiveSlotBudget,
    );
    return {for (final (i, m) in order.indexed) m: counts[i]};
  }

  /// The reservation slots of each exclusive master by module name, after
  /// [HarborExclusive.auto] is resolved. Empty when no master is exclusive.
  Map<String, int> get exclusiveSlots => {
    for (final e in _exclusiveSlotsOf().entries)
      if (e.value > 0) e.key.module.name: e.value,
  };

  /// The memory bus shape to build an AXI4 memory slave with (`idWidth` and
  /// `exclusive` of [HarborSram], [HarborSdram] and [HarborDdr3]): the ID
  /// width that carries full master IDs, and the exclusive monitor, or null
  /// when no master is exclusive. Call it after every [addMaster].
  ({int idWidth, HarborAxi4Exclusive? exclusive}) memoryBusShape() {
    if (fabricKind != HarborFabricKind.axi4 || _masters.isEmpty) {
      return (idWidth: 1, exclusive: null);
    }
    final slots = _exclusiveSlotsOf();
    final ms = [
      for (final (i, m) in _fabricOrder.indexed)
        HarborFabricMaster(
          name: 'm$i',
          interface: m.module.interface(m.busInterfaceName).interface,
          exclusiveIds: slots[m],
        ),
    ];
    return (
      idWidth: HarborAxi4Fabric.fullIdWidthOf(ms),
      exclusive: HarborAxi4Fabric.exclusiveOf(
        ms,
        granuleBytes: exclusiveGranuleBytes,
      ),
    );
  }

  // A slave that holds memory, which a SoC-wide timeout leaves out.
  static bool _isMemory(BridgeModule m) =>
      m is HarborSystemMemoryProvider ||
      m is HarborSram ||
      m is HarborSdram ||
      m is HarborDdr3 ||
      m is HarborFlash ||
      m is HarborSpiFlashController ||
      m is HarborMaskRom;

  // The memory flag and outstanding depth of a slave port. Other ports are
  // register ports, except a full AXI4 port.
  static ({bool memory, int outstanding}) _slaveShape(
    BridgeModule m,
    String iface,
    PairInterface intf,
  ) => switch (m) {
    HarborSram() => (memory: true, outstanding: HarborSram.outstanding),
    HarborDdr3(:final outstanding) when iface == 'bus' => (
      memory: true,
      outstanding: outstanding,
    ),
    HarborSdram(:final outstanding) when iface == 'bus' => (
      memory: true,
      outstanding: outstanding,
    ),
    _ => (memory: intf is Axi4Interface, outstanding: 1),
  };

  /// Throws when [intf] of [module] is not a port of [fabricKind].
  void _checkNative(BridgeModule module, PairInterface intf, String role) {
    final native = switch (fabricKind) {
      HarborFabricKind.wishbone => intf is WishboneInterface,
      HarborFabricKind.axi4 =>
        intf is Axi4Interface || intf is Axi4LiteInterface,
      HarborFabricKind.tilelink => intf is TileLinkInterface,
    };
    if (native) return;
    throw StateError(
      '$role ${module.name} has a ${intf.runtimeType} port, but the fabric '
      'of $name is ${fabricKind.name}.',
    );
  }

  /// Throws when a peripheral runs on a clock other than the fabric clock
  /// and has no crossing to it.
  void _checkClockDomains() {
    final (fabricClk, _) = defaultClock;
    for (final e in _peripherals) {
      final domain = domainFor(e.clockDomainName);
      if (domain == null || identical(domain.clk, fabricClk)) continue;
      if (e.module.tryInput(BusSlavePort.fabricClkPort) == null) {
        throw StateError(
          'peripheral ${e.module.name} runs on clock domain '
          '"${e.clockDomainName}", not on the fabric clock. Build it with '
          'crossFabricClock so its port crosses to the fabric clock.',
        );
      }
    }
  }

  // Puts a register stage in front of a master port and returns the stage's
  // fabric side.
  InterfaceReference _registerStage(InterfaceReference port) {
    final cfg = (port.interface as WishboneInterface).config;
    final reg = WishboneRegisterStage(config: cfg);
    addSubModule(reg);
    _fabricErrorFlags.add(reg.output('bus_error'));
    final (clk, reset) = defaultClock;
    reg.input('clk').srcConnection! <= clk;
    reg.input('reset').srcConnection! <= reset;
    connectInterfaces(port, reg.interface('up'));
    return reg.interface('down');
  }

  /// Assigns an interrupt source number to every peripheral that sources an
  /// interrupt, in the order peripherals were added.
  ///
  /// This is the single interrupt-number allocator for the SoC: the device
  /// tree, ACPI, SVD, and graph generators all read this assignment rather
  /// than each peripheral hardcoding its own number. A peripheral is treated
  /// as an interrupt source when it has an `interrupt` output port and is not
  /// itself an interrupt controller.
  ///
  /// The returned map is keyed by the peripheral module.
  Map<BridgeModule, int> interruptAssignments() {
    final result = <BridgeModule, int>{};
    var next = interruptBase;
    for (final entry in _peripherals) {
      final m = entry.module;
      if (m is HarborDeviceTreeNodeProvider &&
          (m as HarborDeviceTreeNodeProvider).dtNode.interruptController) {
        continue;
      }
      if (!_hasInterruptOutput(m)) continue;
      result[m] = next++;
    }
    return result;
  }

  bool _hasInterruptOutput(BridgeModule m) {
    try {
      m.output('interrupt');
      return true;
    } on Exception {
      return false;
    }
  }

  /// Generates a ACPICA compatible `.asl` file.
  String generateAcpi() {
    final assign = interruptAssignments();
    final providers = _peripherals
        .map((e) => e.module)
        .whereType<HarborAcpiDeviceProvider>()
        .toList();
    return HarborAcpiGenerator(
      oemId: acpiOemId,
      oemTableId: acpiOemTableId,
      cpus: cpus,
      peripherals: providers,
      interrupts: {
        for (final p in providers)
          if (assign[p] != null) p: [assign[p]!],
      },
      gsiBase: interruptGsiBase,
    ).generate();
  }

  /// Generates a Linux/U-Boot compatible `.dts` file.
  String generateDts() {
    final assign = interruptAssignments();
    final providers = _peripherals
        .map((e) => e.module)
        .whereType<HarborDeviceTreeNodeProvider>()
        .toList();
    // Devices that back usable RAM contribute root `memory@` nodes, not just
    // their controller node under `/soc`, so an OS/SBI payload finds RAM.
    final memories = _peripherals
        .map((e) => e.module)
        .whereType<HarborSystemMemoryProvider>()
        .expand((p) => p.systemMemory)
        .toList();
    return HarborDeviceTreeGenerator(
      model: model,
      compatible: compatible,
      cpus: cpus,
      peripherals: providers,
      memories: memories,
      reservedMemories: _peripherals
          .map((e) => e.module)
          .whereType<HarborReservedMemoryProvider>()
          .expand((p) => p.reservedMemory)
          .toList(),
      interrupts: {
        for (final p in providers)
          if (assign[p] != null) p: [assign[p]!],
      },
      interruptContexts: interruptContexts,
    ).generate();
  }

  /// Generates the Zig object notation file that the firmware reads to make
  /// its SMBIOS tables.
  ///
  /// Each field is present only when this SoC knows it. The memory fields
  /// come from the peripherals that back system memory.
  String generateBoardZon() => HarborBoardZonGenerator(
    vendor: manufacturer,
    product: _explicitModel,
    family: name,
    cpus: cpus,
    memories: _peripherals
        .map((e) => e.module)
        .whereType<HarborSystemMemoryProvider>()
        .map((p) => p.memoryInfo)
        .toList(),
    board: board,
  ).generate();

  /// Generates a CMSIS-SVD (System View Description) file.
  String generateSvd() {
    final assign = interruptAssignments();
    final providers = _peripherals
        .map((e) => e.module)
        .whereType<HarborSvdPeripheralProvider>()
        .toList();
    return HarborSvdGenerator(
      vendor: manufacturer ?? svdVendor,
      name: name,
      version: svdVersion,
      description: _explicitModel ?? compatible,
      cpus: cpus,
      peripherals: providers,
      interrupts: {
        for (final p in providers)
          if (assign[p] != null) p: [assign[p]!],
      },
    ).generate();
  }

  /// Generates a Mermaid flowchart of this SoC's topology.
  String generateMermaid() => _graphGenerator().mermaid();

  /// Generates a Graphviz DOT graph of this SoC's topology.
  String generateDot() => _graphGenerator().dot();

  HarborSoCGraphGenerator _graphGenerator() {
    final assign = interruptAssignments();
    final providers = _peripherals
        .map((e) => e.module)
        .whereType<HarborDeviceTreeNodeProvider>()
        .toList();
    return HarborSoCGraphGenerator(
      name: name,
      cpus: cpus,
      peripherals: providers,
      interrupts: {
        for (final p in providers)
          if (assign[p] != null) p: [assign[p]!],
      },
      hasJtagDebug: masters.whereType<HarborJtagDebug>().isNotEmpty,
    );
  }

  /// Builds RTL and writes all generated outputs to [outputPath].
  ///
  /// Generates:
  /// - `rtl/`: SystemVerilog files + filelist.f (via rohd_bridge)
  /// - `<name>.dts`: device tree source
  /// - `<name>.board.zon`: firmware SMBIOS board data
  /// - `<name>.dot`: Graphviz topology graph
  /// - `<name>.mermaid.md`: Mermaid topology graph
  /// - Target-specific files:
  ///   - FPGA: constraint file (`.pcf`/`.lpf`/`.xdc`)
  ///   - ASIC: SDC timing constraints
  Future<void> generateAll(Directory directory) async {
    directory.createSync(recursive: true);
    final path = directory.path;

    // RTL generation: emit one SystemVerilog file per UNIQUIFIED module name.
    //
    // We deliberately do NOT use rohd_bridge's `buildAndGenerateRTL`, which
    // names each output file by `module.definitionName`. When ROHD's
    // synthesizer uniquifies two *distinct* modules that requested the same
    // `definitionName` (e.g. `ParallelPrefixAdder_W64` and the second,
    // structurally-different instance emitted as `ParallelPrefixAdder_W64_0`),
    // both modules still report the same `definitionName`, so they collide onto
    // a single file: one body clobbers the other (corrupting its `endmodule`)
    // and the filelist lists it twice -> Verilator MODDUP/ENDLABEL errors.
    //
    // ROHD already prevents this: `SynthFileContents.name` carries the correct
    // uniquified module name. Keying filenames on that yields one file per
    // emitted module with no collision.
    await build();
    final synthBuilder = SynthBuilder(this, SystemVerilogSynthesizer());
    final rtlPath = '$path/rtl';
    Directory(rtlPath).createSync(recursive: true);
    final filelist = StringBuffer();
    for (final fileContents in synthBuilder.getSynthFileContents()) {
      final fileName = '${fileContents.name}.sv';
      var contents = fileContents.contents;
      // ROHD emits the bidirectional `net_connect` helper with TWO ports that
      // share the name `w` (`module net_connect #(...) (w, w)`), which yosys
      // rejects as a duplicate port. Rewrite it to two distinct cross-assigned
      // inout ports. Instantiations are positional, so this is transparent.
      if (fileContents.name == 'net_connect' &&
          RegExp(r'\(\s*w\s*,\s*w\s*\)').hasMatch(contents)) {
        contents =
            '// A special module for connecting two nets '
            'bidirectionally\n'
            'module net_connect #(parameter int WIDTH=1) (w0, w1);\n'
            'inout wire [WIDTH-1:0] w0;\n'
            'inout wire [WIDTH-1:0] w1;\n'
            'assign w0 = w1;\n'
            'assign w1 = w0;\n'
            'endmodule\n';
      }
      if (fileContents.name == name && _xilinxSourceClkMhz != null) {
        // These clock aliases otherwise disappear in Yosys because they are
        // only consumed as clocks. Keep the actual BUFG output nets named so
        // the nextpnr addClock hook can target mapped nets reliably.
        for (final clockNet in ['sysosc_clk', 'core_clk', 'ddr_clk']) {
          final declaration = RegExp(
            '^logic $clockNet;\\s*\$',
            multiLine: true,
          );
          if (!declaration.hasMatch(contents)) {
            throw StateError(
              'Generated top RTL is missing preserved clock net $clockNet.',
            );
          }
          contents = contents.replaceFirst(
            declaration,
            '(* keep = 1 *) logic $clockNet;',
          );
        }
      }
      if (fileContents.name == name && !_hasDdr3ClockTree) {
        for (final clockNet in _xilinxPllClockMhz.keys) {
          final declaration = RegExp(
            '^logic $clockNet;\\s*\$',
            multiLine: true,
          );
          if (!declaration.hasMatch(contents)) {
            throw StateError(
              'Generated top RTL is missing the PLL clock net $clockNet.',
            );
          }
          contents = contents.replaceFirst(
            declaration,
            '(* keep = 1 *) logic $clockNet;',
          );
        }
      }
      File('$rtlPath/$fileName').writeAsStringSync(contents);
      filelist.writeln('./rtl/$fileName');
    }
    File('$path/filelist.f').writeAsStringSync(filelist.toString());

    // Generate blackbox stubs for leaf modules (SRAM macros, etc.)
    final blackboxStubs = _generateBlackboxStubs();
    if (blackboxStubs.isNotEmpty) {
      File('$path/blackboxes.v').writeAsStringSync(blackboxStubs);
    }

    // ACPI
    File('$path/$name.asl').writeAsStringSync(generateAcpi());

    // Device tree
    File('$path/$name.dts').writeAsStringSync(generateDts());
    File('$path/$name.board.zon').writeAsStringSync(generateBoardZon());

    // CMSIS-SVD
    File('$path/$name.svd').writeAsStringSync(generateSvd());

    // Graphs
    File('$path/$name.dot').writeAsStringSync(generateDot());
    File(
      '$path/$name.mermaid.md',
    ).writeAsStringSync('```mermaid\n${generateMermaid()}\n```\n');
    final slots = exclusiveSlots;
    if (slots.isNotEmpty) {
      File('$path/$name.exclusive.txt').writeAsStringSync(
        'AXI4 exclusive reservation slots per monitored memory slave '
        '(budget $exclusiveSlotBudget, granule $exclusiveGranuleBytes '
        'bytes):\n${[for (final e in slots.entries) '${e.key}: ${e.value}\n'].join()}',
      );
    }

    // Target-specific outputs
    final t = target;
    if (t != null) {
      switch (t) {
        case HarborSimTarget():
          // Behavioral bodies for leaves that only exist in simulation. These
          // go into the filelist so Verilator compiles them with the design;
          // blackboxes.v is a synthesis artifact and is NOT in the filelist.
          //
          // Every leaf must supply one. A stubbed leaf drives X into the
          // design and reads as a design bug, so refuse the build instead.
          final leaves = <BridgeModule>[];
          _collectLeafModules(this, leaves);
          final unimplemented = <String>{};
          final extraRtl = <String>[];
          final writtenLeaves = <String>{};
          for (final leaf in leaves) {
            if (leaf is! HarborSimLeaf) {
              unimplemented.add(leaf.definitionName);
              continue;
            }
            // Name the file after the module, so the two cannot disagree.
            if (!writtenLeaves.add(leaf.definitionName)) continue;
            final rel = 'sim/${leaf.definitionName}.sv';
            final f = File('$path/$rel')..parent.createSync(recursive: true);
            f.writeAsStringSync((leaf as HarborSimLeaf).simRtl);
            extraRtl.add('./$rel');
          }
          if (unimplemented.isNotEmpty) {
            throw StateError(
              'Verilator target: these leaf modules have no behavioral model, '
              'so the simulation would see them as undriven X: '
              '${(unimplemented.toList()..sort()).join(', ')}. '
              'Mix HarborSimLeaf into each, or keep them off the sim build.',
            );
          }
          if (extraRtl.isNotEmpty) {
            File('$path/filelist.f').writeAsStringSync(
              '${filelist.toString()}${extraRtl.join('\n')}\n',
            );
          }

          // The clock wheel needs every domain's port name and frequency, and
          // the primary input clock, which only the SoC knows.
          // Only the domains that actually became top-level inputs. A domain
          // running at the source rate short-circuits to the input clock and
          // has no port of its own, so listing it by name would make the
          // harness bind a port that does not exist.
          final domains = <String, int>{
            for (final e in _clockDomains.entries)
              if (e.value.simPort case final port?)
                port: e.value.config.frequency,
          };
          // Host-side C++ models, one context per module so each is told the
          // TOP-LEVEL names its own pins were exposed under. Masters are
          // scanned too: what hangs off a pin does not depend on which side of
          // the fabric the module sits on (a display's TMDS lanes reach a
          // monitor whether or not it also answers as a slave). Plain
          // submodules at any depth, such as a display on a memory read port,
          // are asked too. A module is asked once.
          Iterable<Module> descendants(Module m) sync* {
            for (final c in m.subModules) {
              yield c;
              yield* descendants(c);
            }
          }

          final models = <HarborSimModel>[];
          final askedForModels = <BridgeModule>{};
          for (final p
              in peripherals
                  .followedBy(masters)
                  .followedBy(descendants(this).whereType<BridgeModule>())
                  .whereType<HarborSimModelProvider>()) {
            final mod = p as BridgeModule;
            if (!askedForModels.add(mod)) continue;
            final periClk = simClockOf(mod, t.frequency);
            models.addAll(
              p.simModels(
                HarborSimModelContext(
                  exposedPins: exposedPinsOf(mod),
                  clockHz: t.frequency,
                  primaryClockPort: 'clk',
                  peripheralClockPort: periClk.port,
                  peripheralClockHz: periClk.hz,
                ),
              ),
            );
          }
          // One header per class, however many instances use it.
          final writtenHeaders = <String>{};
          for (final m in models) {
            if (!writtenHeaders.add(m.headerPath)) continue;
            final f = File('$path/${m.headerPath}')
              ..parent.createSync(recursive: true);
            f.writeAsStringSync(m.header);
          }

          final jtag = masters.whereType<HarborJtagDebug>();
          Directory('$path/sim').createSync(recursive: true);
          File('$path/sim/main.cpp').writeAsStringSync(
            t.generateMain(
              topCell: t.topCell,
              clockPorts: domains,
              models: models,
              hasJtag: jtag.isNotEmpty,
            ),
          );
          File(
            '$path/Makefile',
          ).writeAsStringSync(t.generateMakefile(name, models: models));
          if (jtag.isNotEmpty) {
            final dm = jtag.first;
            File('$path/openocd.cfg').writeAsStringSync(
              t.generateOpenocdConfig(dmIdcode: dm.jtagDmIdcode),
            );
          }
        case HarborFpgaTarget():
          // Only constrain pins the design actually exposes. A board defines a
          // pin for every connector it carries (an unused HDMI header, a spare
          // Pmod); a constraint for a port the netlist has no top-level signal
          // for makes nextpnr reject the design. inOuts covers the bidirectional
          // pads (DDR DQ, SD CMD/DAT).
          final knownPorts = <String>{
            ...inputs.keys,
            ...outputs.keys,
            ...inOuts.keys,
          };
          // nextpnr-xilinx rejects a design with an unconstrained IO, and
          // Vivado stops at bitstream time. Fail here and name the ports.
          if (t.vendor == HarborFpgaVendor.openXc7 ||
              t.vendor == HarborFpgaVendor.vivado) {
            final missing = t.missingPins({
              for (final p in [...inputs.values, ...outputs.values])
                p.name: p.width,
              for (final p in inOuts.values) p.name: p.width,
            });
            if (missing.isNotEmpty) {
              throw StateError(
                'Top-level ports of $name have no pin in the ${t.name} '
                'pin map: ${missing.join(', ')}.',
              );
            }
          }
          File('$path/$name.${t.constraintExtension}').writeAsStringSync(
            t.generateConstraints(
              knownPorts: knownPorts,
              deviceLines: _devicePinConstraints(t),
            ),
          );
          final rtlDir = Directory('$path/rtl');
          final svFiles = rtlDir.existsSync()
              // The file system order is not stable, so sort the list.
              ? (rtlDir
                    .listSync()
                    .where((f) => f.path.endsWith('.sv'))
                    .map((f) => 'rtl/${f.uri.pathSegments.last}')
                    .toList()
                  ..sort())
              : <String>[];
          File(
            '$path/synth.tcl',
          ).writeAsStringSync(t.generateYosysTcl(name, svFiles: svFiles));
          final providedClocks = _peripheralClockMhz();
          final pllClocks = {..._xilinxPllClockMhz, ...providedClocks};
          final pllScript =
              t.vendor == HarborFpgaVendor.openXc7 &&
              !t.useHimbaechel &&
              pllClocks.isNotEmpty &&
              !_hasDdr3ClockTree;
          File('$path/Makefile').writeAsStringSync(
            t.generateMakefile(
              name,
              pllClockScript: pllScript,
              knownPorts: knownPorts,
            ),
          );

          // OpenOCD config, auto-emitted when the SoC has a JTAG debug master.
          final jtag = masters.whereType<HarborJtagDebug>();
          if (jtag.isNotEmpty) {
            final dm = jtag.first;
            File('$path/openocd.cfg').writeAsStringSync(
              t.generateOpenocdConfig(
                innerIrWidth: dm.jtagInnerIrWidth,
                dmIdcode: dm.jtagDmIdcode,
              ),
            );
          }

          // nextpnr --pre-place fragments. Two sources feed the ONE
          // support/nextpnr/constraints.py file: the openXC7 DDR train-SERDES
          // pins, and every peripheral that mixes in
          // HarborNextpnrPreplaceProvider. The fragments are collected and
          // joined, so a second contributor does not overwrite the first.
          // Nothing is written when no source contributes, which leaves the
          // Makefile --pre-place hook empty.
          final preplacePy = <String>[];

          // openXC7 DDR3 nextpnr helper scripts. Legacy nextpnr-xilinx needs
          // the train SERDES pinned off the dead _SING tile through pre-place.
          // Himbächel pairs the SERDES during packing, so it only uses the
          // clock constraint script below.
          var clocksPyWritten = false;
          if (t.vendor == HarborFpgaVendor.openXc7) {
            final ddr = peripherals.whereType<HarborDdr3>().firstOrNull;
            if (ddr != null) {
              if (!t.useHimbaechel) {
                preplacePy.add(t.generateDdrPreplacePy(lanes: ddr.lanes));
                Directory('$path/support/nextpnr').createSync(recursive: true);
                File(
                  '$path/support/nextpnr/show_bels.py',
                ).writeAsStringSync(t.generateDdrShowBelsPy());
              }
              // Over-constrain the derived core + DDR-controller clocks via a
              // --pre-pack addClock. The open Xilinx flows do not reliably
              // propagate the XDC clock through the PLL/BUFG, so these domains
              // timing engine UNCONSTRAINED (zero margin, setup-only, single-
              // corner). addClock at a rate ABOVE the real one forces timing-
              // driven placement/routing to prioritise them and makes silicon
              // margin show up as an honest WNS. --timing-allow-fail keeps a
              // bitstream written when the aggressive target is not met.
              final coreMhz = _xilinxCoreClkMhz;
              final sourceMhz = _xilinxSourceClkMhz;
              // The over-constraint targets the `ddr_clk` net = the controller
              // LOGIC clock (controllerClk), which is CK/8 at gearRatio 2 and
              // CK/4 at gearRatio 1. Use controllerClkMhz (the realised logic
              // rate), NOT controllerMhz (the SERDES/CLKDIV rate, which stays
              // CK/4). At gearRatio 1 the two are equal, so this is byte-
              // identical for the legacy path.
              final ddrCtrlMhz = xilinxDdr3Clocks?.controllerClkMhz;
              if (coreMhz != null && sourceMhz != null && ddrCtrlMhz != null) {
                clocksPyWritten = true;
                Directory('$path/support/nextpnr').createSync(recursive: true);
                File('$path/support/nextpnr/clocks.py').writeAsStringSync(
                  t.generateClockConstraintPy(
                    coreClkMhz: coreMhz,
                    coreClockNet: 'core_clk',
                    sourceClockNet: 'sysosc_clk',
                    sourceClkMhz: sourceMhz,
                    ddrCtrlMhz: ddrCtrlMhz,
                    extraClocks: providedClocks,
                  ),
                );
              }
            }
            if (_hasDdr3ClockTree &&
                !t.useHimbaechel &&
                providedClocks.isNotEmpty &&
                !clocksPyWritten) {
              throw StateError(
                'The clock rates of ${providedClocks.keys.join(', ')} need '
                'support/nextpnr/clocks.py, and a design with a DDR3 clock '
                'tree writes it only with a DDR3 controller and the rates of '
                'its clocks. Use Himbächel or add the controller.',
              );
            }
            // Himbächel can lack Python hooks, so the XDC carries the rates.
            // With a DDR3 clock tree the PLL nets are not timed here.
            final xdcClocks = _hasDdr3ClockTree ? providedClocks : pllClocks;
            if (t.useHimbaechel && xdcClocks.isNotEmpty) {
              final xdc = File('$path/$name.${t.constraintExtension}');
              final lines = StringBuffer(xdc.readAsStringSync());
              for (final e in xdcClocks.entries) {
                lines.writeln(
                  'create_clock -period '
                  '${(1000 / e.value).toStringAsFixed(3)} '
                  '[get_nets ${e.key}]',
                );
              }
              xdc.writeAsStringSync(lines.toString());
            } else if (!t.useHimbaechel &&
                !_hasDdr3ClockTree &&
                pllClocks.isNotEmpty) {
              Directory('$path/support/nextpnr').createSync(recursive: true);
              File(
                '$path/support/nextpnr/pll_clocks.py',
              ).writeAsStringSync(t.generatePllClockConstraintPy(pllClocks));
            }
          } else if (t.vendor == HarborFpgaVendor.vivado &&
              providedClocks.isNotEmpty) {
            // Vivado names a net in a flat design with `/` between the names.
            final xdc = File('$path/$name.${t.constraintExtension}');
            final lines = StringBuffer(xdc.readAsStringSync());
            for (final e in providedClocks.entries) {
              lines.writeln(
                'create_clock -period '
                '${(1000 / e.value).toStringAsFixed(3)} '
                '[get_nets ${e.key.replaceAll('.', '/')}]',
              );
            }
            xdc.writeAsStringSync(lines.toString());
          }

          // Peripheral-contributed pins. The peripheral names its own cells;
          // the part those cells must land on comes down in the context, so a
          // provider can decline a family or a device it has no verified
          // placement for.
          if (!t.useHimbaechel) {
            final preplaceCtx = HarborNextpnrPreplaceContext(
              vendor: t.vendor,
              device: t.device,
              package: t.package,
            );
            for (final p
                in peripherals.whereType<HarborNextpnrPreplaceProvider>()) {
              final fragment = p.nextpnrPreplacePy(preplaceCtx);
              if (fragment == null || fragment.trim().isEmpty) continue;
              preplacePy.add(fragment);
            }
          }

          if (preplacePy.isNotEmpty) {
            Directory('$path/support/nextpnr').createSync(recursive: true);
            File(
              '$path/support/nextpnr/constraints.py',
            ).writeAsStringSync(preplacePy.join('\n'));
          }
        case HarborAsicTarget():
          File('$path/$name.sdc').writeAsStringSync(t.generateSdc());
          File('$path/synth.tcl').writeAsStringSync(t.generateYosysTcl());
          File('$path/pnr.tcl').writeAsStringSync(t.generateOpenroadTcl());

          // Hierarchical macro scripts
          if (t.isHierarchical) {
            final macroDir = Directory('$path/macros');
            macroDir.createSync(recursive: true);
            for (final macro in t.macros) {
              File(
                '$path/macros/${macro.moduleName}_synth.tcl',
              ).writeAsStringSync(t.generateMacroYosysTcl(macro));
              File(
                '$path/macros/${macro.moduleName}_pnr.tcl',
              ).writeAsStringSync(t.generateMacroOpenroadTcl(macro));
            }
          }

          // KLayout scripts
          final klayout = HarborKlayoutScripts(
            pdkName: t.provider.name,
            topCell: t.topCell,
            drc: t.klayoutDrc,
            lvsNetlistPath: '${t.topCell}_final.v',
          );

          final klayoutDir = Directory('$path/klayout');
          klayoutDir.createSync(recursive: true);

          // DEF to GDS conversion
          final lib = t.provider.standardCellLibrary;
          File('$path/klayout/def2gds.py').writeAsStringSync(
            klayout.generateDefToGds(
              defPath: '${t.topCell}_final.def',
              techLefPath: lib.techLefPath ?? lib.lefPath,
              outputGdsPath: '${t.topCell}.gds',
            ),
          );

          // GDS merge (if analog blocks present)
          if (t.analogGdsPaths.isNotEmpty) {
            File('$path/klayout/gds_merge.py').writeAsStringSync(
              klayout.generateGdsMerge(
                digitalGdsPath: '${t.topCell}.gds',
                analogGdsPaths: t.analogGdsPaths,
                outputGdsPath: '${t.topCell}_merged.gds',
              ),
            );
          }

          // DRC
          File(
            '$path/klayout/drc.py',
          ).writeAsStringSync(klayout.generateDrc(gdsPath: '${t.topCell}.gds'));

          // LVS
          File(
            '$path/klayout/lvs.py',
          ).writeAsStringSync(klayout.generateLvs(gdsPath: '${t.topCell}.gds'));
      }
    }
  }

  /// Generates Verilog blackbox stubs for all SystemVerilog leaf modules.
  ///
  /// These are hard IP blocks (SRAM macros, PLLs, etc.) that have no
  /// ROHD-generated definition. The stubs let Yosys recognize the
  /// module interfaces during synthesis.
  String _generateBlackboxStubs() {
    final leafModules = <BridgeModule>[];
    _collectLeafModules(this, leafModules);
    if (leafModules.isEmpty) return '';

    final buf = StringBuffer();
    buf.writeln('// Auto-generated blackbox stubs for synthesis');
    final seen = <String>{};
    for (final mod in leafModules) {
      if (!seen.add(mod.definitionName)) continue;

      buf.writeln('(* blackbox *)');
      buf.write('module ${mod.definitionName}(');

      final ports = <String>[];
      for (final entry in mod.inputs.entries) {
        final w = entry.value.width;
        ports.add(
          w > 1 ? 'input [${w - 1}:0] ${entry.key}' : 'input ${entry.key}',
        );
      }
      for (final entry in mod.outputs.entries) {
        final w = entry.value.width;
        ports.add(
          w > 1 ? 'output [${w - 1}:0] ${entry.key}' : 'output ${entry.key}',
        );
      }
      buf.writeln(ports.join(', '));
      buf.writeln(');');
      buf.writeln('endmodule');
      buf.writeln();
    }
    return buf.toString();
  }

  static void _collectLeafModules(Module mod, List<BridgeModule> result) {
    if (mod is BridgeModule && mod.isSystemVerilogLeaf) {
      result.add(mod);
    }
    for (final sub in mod.subModules) {
      _collectLeafModules(sub, result);
    }
  }
}

class _PeripheralEntry {
  final BridgeModule module;
  final BusAddressRange addressRange;

  /// Clock domain this peripheral was wired to, or null for the default. Kept
  /// so a sim model can be ticked on the domain its peripheral actually runs
  /// on rather than assuming the primary.
  final String? clockDomainName;

  /// Fabric timeout of this peripheral, or null for the SoC default.
  final int? busTimeoutCycles;

  const _PeripheralEntry({
    this.busTimeoutCycles,
    required this.module,
    required this.addressRange,
    this.clockDomainName,
  });
}

/// A secondary bus slave of an already-registered peripheral (see
/// [HarborSoC.addPeripheralSlave]): another decoder slot only, no dtNode/clock.
class _SecondarySlave {
  final BridgeModule module;
  final String busInterfaceName;
  final BusAddressRange addressRange;

  const _SecondarySlave({
    required this.module,
    required this.busInterfaceName,
    required this.addressRange,
  });
}

class _MasterEntry {
  final BridgeModule module;
  final String busInterfaceName;
  final bool pipeline;

  /// The fabric channel this master lives on.
  final String channel;

  /// Memory port flag, or null to pick from the interface class.
  final bool? memory;

  /// Most requests in flight, or null for the fabric default.
  final int? outstanding;

  /// Read channel at a slave with more than one, or null for the default.
  final int? readChannel;

  /// AXI4 exclusive slots, as in [HarborFabricMaster.exclusiveIds].
  final int? exclusiveIds;

  /// Real-time flag, as in [HarborFabricMaster.realtime].
  final bool realtime;

  /// Write stall flag, as in [HarborFabricMaster.writeStallFree].
  final bool writeStallFree;

  /// Address ranges the master must reach, or null for no check.
  final List<BusAddressRange>? targetRanges;

  /// Address ranges where the master issues bursts, or null for none.
  final List<BusAddressRange>? burstRanges;

  /// The memory port flag: [memory], else true for a full AXI4 port.
  bool get isMemoryPort =>
      memory ?? module.interface(busInterfaceName).interface is Axi4Interface;

  const _MasterEntry({
    required this.module,
    required this.busInterfaceName,
    this.pipeline = false,
    this.channel = 'primary',
    this.memory,
    this.outstanding,
    this.readChannel,
    this.exclusiveIds,
    this.realtime = false,
    this.writeStallFree = false,
    this.targetRanges,
    this.burstRanges,
  });
}
