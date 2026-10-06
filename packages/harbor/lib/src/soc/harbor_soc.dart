import 'dart:io';

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/wishbone/wishbone_arbiter.dart';
import '../bus/wishbone/wishbone_decoder.dart';
import '../bus/wishbone/wishbone_register_stage.dart';
import '../bus/wishbone/wishbone_interface.dart';
import '../blackbox/xilinx/xilinx.dart';
import '../clock/clock_domain.dart';
import '../pdk/klayout.dart';
import '../peripherals/harbor_ddr3.dart';
import 'acpi.dart';
import 'cpu.dart';
import 'device_tree.dart';
import 'graph.dart';
import 'svd.dart';
import 'target.dart';

/// Selects how a slave that more than one fabric channel reaches is shared.
///
/// A channel is one arbiter plus decoder over its own slave subset. When two
/// channels both reach one slave (for example a DMA channel and the CPU channel
/// that meet only at memory), that slave has more than one channel decoder that
/// wants to drive it. The convergence mode says how to merge those drivers.
enum HarborMemConverge {
  /// Merge the channels with a [WishboneArbiter] at the shared slave. The
  /// arbiter grants one channel at a time, so the slave sees one master. This
  /// is the only mode that is built today.
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
/// through a bus decoder. For custom topology, drop down to
/// rohd_bridge's [addSubModule], [connectInterfaces], and
/// [connectPorts] directly.
///
/// ```dart
/// final soc = HarborSoC(
///   name: 'MySoC',
///   compatible: 'lilithsemi,creek-v1',
///   busConfig: WishboneConfig(addressWidth: 32, dataWidth: 32),
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
/// // Build the bus fabric (decoder + wiring)
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

  /// Bus configuration for the fabric.
  final Object busConfig;

  /// CPU information for the device tree.
  final List<HarborCpu> cpus;

  /// Build target (FPGA or ASIC). Controls what scripts are generated.
  final HarborDeviceTarget? target;

  final List<_PeripheralEntry> _peripherals = [];
  final List<_SecondarySlave> _secondarySlaves = [];
  final List<_MasterEntry> _masters = [];

  /// The fabric arbiter, exposed after [buildFabric] when there is more than one
  /// master (null with a single master, which connects to the decoder directly).
  /// Its `grant` output identifies the master currently owning the bus, which a
  /// security peripheral can use as the unforgeable source identity.
  WishboneArbiter? fabricArbiter;

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
        : (input('clk'), input('reset'));
    module.input('clk').srcConnection! <= clk;
    module.input('reset').srcConnection! <= reset;
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

  final String acpiOemId;
  final String acpiOemTableId;

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

  /// Creates a new SoC.
  ///
  /// Accepts an optional list of [clocks] to generate PLL-derived
  /// clock domains. If empty, the external `clk` input is used directly.
  HarborSoC({
    required String name,
    required this.compatible,
    required this.busConfig,
    this.acpiOemId = 'LILSEM',
    this.acpiOemTableId = 'HARBOR',
    this.svdVendor = 'Lilith Semiconductor',
    this.svdVersion = '1.0',
    this.interruptBase = 1,
    this.interruptGsiBase = 0,
    this.interruptContexts = const [],
    this.externalReset = false,
    this.cpus = const [],
    this.target,
    List<HarborClockConfig> clocks = const [],
    XilinxDdr3TreeSpec? xilinxDdr3Tree,
  }) : super(name, name: name) {
    createPort('clk', PortDirection.input);

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

    final Logic resetSignal;
    if (usePowerOnReset) {
      final porCount = Logic(name: 'porCount', width: 8);
      Sequential(input('clk'), [
        If(~porCount[7], then: [porCount < porCount + 1]),
      ]);
      final por = (~porCount[7]).named('porReset');
      resetSignal = externalReset
          ? (por | ~input('reset_n')).named('sysReset')
          : por;
    } else {
      resetSignal = input('reset');
    }

    _clockGen = HarborClockGenerator(
      parent: this,
      inputClk: input('clk'),
      inputReset: resetSignal,
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
    final ddrSpec = xilinxDdr3Tree;
    ({Logic coreClk, Logic locked, double coreMhz})? corePll;
    if (ddrSpec != null) {
      final sharedIn = addSubModule(XilinxBufg(name: 'sysosc_bufg'));
      sharedIn.input('I').srcConnection! <= input('clk');
      final shared = sharedIn.output('O');
      // Decoupled core PLL off the shared input. The DDR tree no longer emits
      // its CLKOUT5 core clock.
      corePll = buildXilinxCorePll(
        this,
        source: shared,
        sourceHz: ddrSpec.sourceHz,
        coreClkHz: ddrSpec.coreClkHz,
      );
      _xilinxCoreClkMhz = corePll.coreMhz;
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
        _clockDomains[clkConfig.name] = _clockGen.createDomainFromClock(
          clkConfig,
          corePll.coreClk,
          locked: combinedLocked,
        );
        continue;
      }
      final sec = clkConfig.coClkosSecondary;
      if (sec != null) {
        // One EHXPLLL drives both: CLKOP = this domain, CLKOS = the secondary.
        // Avoids a 2nd PLL block that may not lock on silicon.
        final shared = _clockGen.createDomainWithSecondary(
          clkConfig,
          secondaryFrequency: sec.frequency,
          secondaryName: sec.name,
        );
        // Register the secondary FIRST so a 'sys'-named secondary stays the
        // default clock (values.first), then the CLKOP primary.
        _clockDomains[sec.name] = shared.secondary;
        _clockDomains[clkConfig.name] = shared.primary;
      } else {
        _clockDomains[clkConfig.name] = _clockGen.createDomain(clkConfig);
      }
    }
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
    return (input('clk'), input('reset'));
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
  T addPeripheral<T extends BridgeModule>(
    T peripheral, {
    String? clockDomainName,
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
      ),
    );
    _wireOnce(peripheral, clockDomainName);

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

  /// Maps a SECOND wishbone slave interface of an already-added peripheral into
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
  /// [busInterfaceName] is the name of the master's Wishbone provider
  /// interface (default `'dataBus'`).
  ///
  /// When [pipeline] is set, a [WishboneRegisterStage] is interposed on this
  /// master's leg to the arbiter, so a physically distant master (for example a
  /// DMA engine at an I/O pad) drives a registered bus instead of a
  /// die-crossing combinational one. That relieves routing congestion near the
  /// arbiter at the cost of two extra bus-latency cycles on this master alone.
  ///
  /// [channel] names the fabric channel this master joins. Masters that share a
  /// channel share one arbiter plus decoder. A master on its own channel gets
  /// its own arbiter plus decoder, and meets the other channels only at a slave
  /// that both channels reach (see [buildFabric]'s `channelSlaves`). The default
  /// `'primary'` keeps the classic single-fabric SoC.
  ///
  /// Clock and reset are auto-wired.
  T addMaster<T extends BridgeModule>(
    T master, {
    String busInterfaceName = 'dataBus',
    String? clockDomainName,
    bool pipeline = false,
    String channel = 'primary',
  }) {
    _masters.add(
      _MasterEntry(
        module: master,
        busInterfaceName: busInterfaceName,
        pipeline: pipeline,
        channel: channel,
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

  /// Peripheral -> (its port name -> top-level port name), for every pin
  /// pulled up with [exposePin].
  final Map<BridgeModule, Map<String, String>> _exposedPins = {};

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

    // Register maps: internal overlaps and out-of-block registers. The register
    // map and its block size both come from the SVD view, so they are checked
    // against a single source.
    for (final entry in _peripherals) {
      final m = entry.module;
      if (m is! HarborSvdPeripheralProvider) continue;
      final sp = (m as HarborSvdPeripheralProvider).svdPeripheral;
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

  /// Builds the bus fabric connecting masters to peripherals.
  ///
  /// For each master, creates address-decode logic that routes
  /// transactions to the correct peripheral based on
  /// [HarborDeviceTreeNode.reg] address ranges.
  ///
  /// Validates the SoC via [validate] first and throws a [StateError] if any
  /// problem is found.
  ///
  /// Must be called after all [addPeripheral] and [addMaster]
  /// calls, before [build].
  /// Builds the bus fabric connecting masters to peripherals.
  ///
  /// When [pipeline] is set, a [WishboneRegisterStage] is interposed at the
  /// decoder's master port, so the master -> arbiter -> decoder -> slave -> back
  /// path is registered instead of fully combinational. That raises the fabric
  /// clock ceiling at the cost of two extra cycles of bus latency per transfer.
  ///
  /// [channelSlaves] turns the one fabric into N named channels. It maps a
  /// channel name to the SET of slave module names that channel can reach. Each
  /// channel gets its own arbiter plus decoder over just those slaves. A slave
  /// that more than one channel reaches is shared through a convergence arbiter
  /// (see [converge]). When [channelSlaves] is null there is one `'primary'`
  /// channel that reaches every slave, which is byte identical to the historic
  /// fabric. A channel that has masters must appear in [channelSlaves].
  ///
  /// [converge] selects how a shared slave merges its channels. Only
  /// [HarborMemConverge.arbiter] is built. The other modes throw
  /// [UnimplementedError].
  void buildFabric({
    bool pipeline = false,
    Map<String, Set<String>>? channelSlaves,
    HarborMemConverge converge = HarborMemConverge.arbiter,
  }) {
    final errors = validate();
    if (errors.isNotEmpty) {
      throw StateError('Validation errors in $name:\n${errors.join("\n")}');
    }

    if (_peripherals.isEmpty || _masters.isEmpty) return;

    switch (busConfig) {
      case WishboneConfig wbConfig:
        _buildWishboneFabric(
          wbConfig,
          pipeline: pipeline,
          channelSlaves: channelSlaves,
          converge: converge,
        );
      default:
        throw UnsupportedError(
          'Bus protocol ${busConfig.runtimeType} not yet supported in buildFabric',
        );
    }
  }

  void _buildWishboneFabric(
    WishboneConfig wbConfig, {
    bool pipeline = false,
    Map<String, Set<String>>? channelSlaves,
    HarborMemConverge converge = HarborMemConverge.arbiter,
  }) {
    // Primary peripheral buses first, then any secondary slaves (each a distinct
    // decoder slot). Both feed the same address-decode + connect loop below.
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

    // Group masters by channel, keeping the add order inside each channel.
    final byChannel = <String, List<_MasterEntry>>{};
    for (final m in _masters) {
      byChannel.putIfAbsent(m.channel, () => []).add(m);
    }

    // The set of slave list indices a channel can reach. A null map is the
    // classic SoC: the one channel reaches every slave.
    Set<int> reachableFor(String channel) {
      if (channelSlaves == null) {
        return {for (var i = 0; i < slaves.length; i++) i};
      }
      final names = channelSlaves[channel];
      if (names == null) {
        throw StateError(
          'channel "$channel" has masters but is absent from channelSlaves',
        );
      }
      return {
        for (var i = 0; i < slaves.length; i++)
          if (names.contains(slaves[i].module.name)) i,
      };
    }

    // One channel that reaches every slave is byte identical to the historic
    // fabric, so take the exact old path. This keeps creek and delta unchanged.
    final onlyOneChannel = byChannel.length == 1;
    final singleChannel = byChannel.keys.first;
    if (onlyOneChannel && reachableFor(singleChannel).length == slaves.length) {
      _buildSingleChannelWishboneFabric(wbConfig, slaves, pipeline: pipeline);
      return;
    }

    _buildMultiChannelWishboneFabric(
      wbConfig,
      slaves,
      byChannel,
      reachableFor,
      pipeline: pipeline,
      converge: converge,
    );
  }

  // ACK-only peripherals have no ERR response. Tie the missing signal low
  // rather than leaving an error-enabled fabric input floating.
  void _connectWishboneSlave(
    InterfaceReference upstream,
    InterfaceReference downstream,
  ) {
    final up = upstream.interface as WishboneInterface;
    final down = downstream.interface as WishboneInterface;
    if (up.err != null && down.err == null) up.err! <= Const(0);
    connectInterfaces(upstream, downstream);
  }

  /// The historic one-fabric path: all masters -> one arbiter -> one decoder ->
  /// all slaves. Kept verbatim so its emitted netlist stays byte identical.
  void _buildSingleChannelWishboneFabric(
    WishboneConfig wbConfig,
    List<({BridgeModule module, String iface, BusAddressRange range})> slaves, {
    bool pipeline = false,
  }) {
    final mappings = slaves.indexed
        .map((e) => HarborAddressMapping(range: e.$2.range, slaveIndex: e.$1))
        .toList();

    final decoder = WishboneDecoder(wbConfig, mappings);
    addSubModule(decoder);

    // Whatever drives the decoder's master port: the decoder directly, or a
    // register slice interposed in front of it when [pipeline] is set.
    var decoderUpstream = decoder.interface('master');
    if (pipeline) {
      final reg = WishboneRegisterStage(config: wbConfig);
      addSubModule(reg);
      final (clk, reset) = defaultClock;
      reg.input('clk').srcConnection! <= clk;
      reg.input('reset').srcConnection! <= reset;
      connectInterfaces(reg.interface('down'), decoder.interface('master'));
      decoderUpstream = reg.interface('up');
    }

    // One master -> straight to the decoder. Multiple masters -> merge them
    // through a WishboneArbiter first (round-robin, grant-locked) so they share
    // the single decoder/peripheral fabric without multi-driving it.
    if (_masters.length == 1) {
      connectInterfaces(
        _masterFabricPort(_masters[0], wbConfig),
        decoderUpstream,
      );
    } else {
      final arbiter = WishboneArbiter(
        numMasters: _masters.length,
        config: wbConfig,
      );
      fabricArbiter = arbiter;
      addSubModule(arbiter);
      final (clk, reset) = defaultClock;
      arbiter.input('clk').srcConnection! <= clk;
      arbiter.input('reset').srcConnection! <= reset;
      for (var i = 0; i < _masters.length; i++) {
        connectInterfaces(
          _masterFabricPort(_masters[i], wbConfig),
          arbiter.interface('master_$i'),
        );
      }
      connectInterfaces(arbiter.interface('slave'), decoderUpstream);
    }

    // Connect decoder's slave interfaces to the primary + secondary slaves.
    for (var i = 0; i < slaves.length; i++) {
      _connectWishboneSlave(
        decoder.interface('slave_$i'),
        slaves[i].module.interface(slaves[i].iface),
      );
    }
  }

  /// The N-channel path. Each channel gets its own arbiter plus decoder over its
  /// own reachable slave subset. A slave that more than one channel reaches is
  /// merged by a convergence arbiter at that slave.
  void _buildMultiChannelWishboneFabric(
    WishboneConfig wbConfig,
    List<({BridgeModule module, String iface, BusAddressRange range})> slaves,
    Map<String, List<_MasterEntry>> byChannel,
    Set<int> Function(String channel) reachableFor, {
    bool pipeline = false,
    HarborMemConverge converge = HarborMemConverge.arbiter,
  }) {
    // A channel with masters that is absent from channelSlaves is an error.
    // reachableFor throws for such a channel, so the loop below surfaces it.

    // Deterministic channel order: 'primary' first when present, then the rest
    // sorted by name. This fixes the submodule order so regens stay stable.
    final channelNames = byChannel.keys.toList()
      ..sort((a, b) {
        if (a == b) return 0;
        if (a == 'primary') return -1;
        if (b == 'primary') return 1;
        return a.compareTo(b);
      });

    final (clk, reset) = defaultClock;

    // Each channel decoder's slave port, keyed by global slave index. A slave
    // with more than one entry is shared and needs a convergence arbiter.
    final drivers = <int, List<InterfaceReference>>{};

    for (final channel in channelNames) {
      final masters = byChannel[channel]!;
      final reachable = reachableFor(channel).toList()..sort();
      if (reachable.isEmpty) {
        throw StateError('channel "$channel" reaches no slave');
      }

      final mappings = [
        for (final gi in reachable)
          HarborAddressMapping(range: slaves[gi].range, slaveIndex: gi),
      ];
      final decoder = WishboneDecoder(
        wbConfig,
        mappings,
        name: 'wishbone_decoder_$channel',
      );
      addSubModule(decoder);

      // Optional per-channel register slice at the decoder master port, same as
      // the single-channel `pipeline` behaviour.
      var decoderUpstream = decoder.interface('master');
      if (pipeline) {
        final reg = WishboneRegisterStage(config: wbConfig);
        addSubModule(reg);
        reg.input('clk').srcConnection! <= clk;
        reg.input('reset').srcConnection! <= reset;
        connectInterfaces(reg.interface('down'), decoder.interface('master'));
        decoderUpstream = reg.interface('up');
      }

      // One master on the channel -> straight to its decoder. More than one ->
      // merge them through the channel arbiter first.
      if (masters.length == 1) {
        connectInterfaces(
          _masterFabricPort(masters[0], wbConfig),
          decoderUpstream,
        );
      } else {
        final arbiter = WishboneArbiter(
          numMasters: masters.length,
          config: wbConfig,
          name: 'wishbone_arbiter_$channel',
        );
        addSubModule(arbiter);
        arbiter.input('clk').srcConnection! <= clk;
        arbiter.input('reset').srcConnection! <= reset;
        for (var i = 0; i < masters.length; i++) {
          connectInterfaces(
            _masterFabricPort(masters[i], wbConfig),
            arbiter.interface('master_$i'),
          );
        }
        connectInterfaces(arbiter.interface('slave'), decoderUpstream);
        // Keep fabricArbiter pointing at the primary channel for back-compat.
        if (channel == 'primary') fabricArbiter = arbiter;
      }

      for (var k = 0; k < reachable.length; k++) {
        drivers
            .putIfAbsent(reachable[k], () => [])
            .add(decoder.interface('slave_$k'));
      }
    }

    // Every slave must be reachable from at least one channel. An orphan slave
    // would have undriven bus inputs, so fail loudly instead.
    final orphans = [
      for (var gi = 0; gi < slaves.length; gi++)
        if (!drivers.containsKey(gi)) slaves[gi].module.name,
    ];
    if (orphans.isNotEmpty) {
      throw StateError(
        'slaves unreachable from every channel: ${orphans.join(", ")}',
      );
    }

    // Hook each slave up. One driver connects straight. More than one driver
    // means channels share the slave, so a convergence arbiter merges them.
    for (var gi = 0; gi < slaves.length; gi++) {
      final ds = drivers[gi]!;
      final slaveIface = slaves[gi].module.interface(slaves[gi].iface);
      if (ds.length == 1) {
        _connectWishboneSlave(ds[0], slaveIface);
        continue;
      }
      if (converge != HarborMemConverge.arbiter) {
        throw UnimplementedError(
          'converge ${converge.name} not yet implemented',
        );
      }
      final conv = WishboneArbiter(
        numMasters: ds.length,
        config: wbConfig,
        name: 'wishbone_converge_${slaves[gi].module.name}',
      );
      addSubModule(conv);
      conv.input('clk').srcConnection! <= clk;
      conv.input('reset').srcConnection! <= reset;
      for (var i = 0; i < ds.length; i++) {
        connectInterfaces(ds[i], conv.interface('master_$i'));
      }
      _connectWishboneSlave(conv.interface('slave'), slaveIface);
    }
  }

  /// The interface the fabric (arbiter or lone decoder) connects to for master
  /// [m]. When the master requested a pipelined leg, a [WishboneRegisterStage]
  /// is interposed here so its bus to the arbiter is registered rather than a
  /// long combinational route (see [addMaster]'s `pipeline`). Otherwise the
  /// master's own bus interface is returned directly.
  InterfaceReference _masterFabricPort(
    _MasterEntry m,
    WishboneConfig wbConfig,
  ) {
    final port = m.module.interface(m.busInterfaceName);
    if (!m.pipeline) return port;
    final reg = WishboneRegisterStage(config: wbConfig);
    addSubModule(reg);
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
      model: name,
      compatible: compatible,
      cpus: cpus,
      peripherals: providers,
      memories: memories,
      interrupts: {
        for (final p in providers)
          if (assign[p] != null) p: [assign[p]!],
      },
      interruptContexts: interruptContexts,
    ).generate();
  }

  /// Generates a CMSIS-SVD (System View Description) file.
  String generateSvd() {
    final assign = interruptAssignments();
    final providers = _peripherals
        .map((e) => e.module)
        .whereType<HarborSvdPeripheralProvider>()
        .toList();
    return HarborSvdGenerator(
      vendor: svdVendor,
      name: name,
      version: svdVersion,
      description: compatible,
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

    // CMSIS-SVD
    File('$path/$name.svd').writeAsStringSync(generateSvd());

    // Graphs
    File('$path/$name.dot').writeAsStringSync(generateDot());
    File(
      '$path/$name.mermaid.md',
    ).writeAsStringSync('```mermaid\n${generateMermaid()}\n```\n');

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
          // monitor whether or not it also answers as a slave). A dual-role
          // module is asked once.
          final models = <HarborSimModel>[];
          final askedForModels = <BridgeModule>{};
          for (final p
              in peripherals
                  .followedBy(masters)
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
          File(
            '$path/$name.${t.constraintExtension}',
          ).writeAsStringSync(t.generateConstraints(knownPorts: knownPorts));
          final rtlDir = Directory('$path/rtl');
          final svFiles = rtlDir.existsSync()
              ? rtlDir
                    .listSync()
                    .where((f) => f.path.endsWith('.sv'))
                    .map((f) => 'rtl/${f.uri.pathSegments.last}')
                    .toList()
              : <String>[];
          File(
            '$path/synth.tcl',
          ).writeAsStringSync(t.generateYosysTcl(name, svFiles: svFiles));
          File('$path/Makefile').writeAsStringSync(t.generateMakefile(name));

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

          // openXC7 DDR3 nextpnr helper scripts. The DDR PHY's bitslip-
          // reference train SERDES must be pinned off the dead _SING tile;
          // these ride nextpnr-xilinx --pre-place (constraints.py) and
          // --pre-route (show_bels.py). Emitted only for the open-source
          // Xilinx flow when a HarborDdr3 controller is present.
          if (t.vendor == HarborFpgaVendor.openXc7) {
            final ddr = peripherals.whereType<HarborDdr3>().firstOrNull;
            if (ddr != null) {
              preplacePy.add(t.generateDdrPreplacePy(lanes: ddr.lanes));
              Directory('$path/support/nextpnr').createSync(recursive: true);
              File(
                '$path/support/nextpnr/show_bels.py',
              ).writeAsStringSync(t.generateDdrShowBelsPy());
              // Over-constrain the derived core + DDR-controller clocks via a
              // --pre-pack addClock. nextpnr-xilinx does NOT propagate the XDC
              // create_clock through the PLL/BUFG, so these domains reach the
              // timing engine UNCONSTRAINED (zero margin, setup-only, single-
              // corner). addClock at a rate ABOVE the real one forces timing-
              // driven placement/routing to prioritise them and makes silicon
              // margin show up as an honest WNS. --timing-allow-fail keeps a
              // bitstream written when the aggressive target is not met.
              final coreMhz = _xilinxCoreClkMhz;
              // The over-constraint targets the `ddr_clk` net = the controller
              // LOGIC clock (controllerClk), which is CK/8 at gearRatio 2 and
              // CK/4 at gearRatio 1. Use controllerClkMhz (the realised logic
              // rate), NOT controllerMhz (the SERDES/CLKDIV rate, which stays
              // CK/4). At gearRatio 1 the two are equal, so this is byte-
              // identical for the legacy path.
              final ddrCtrlMhz = xilinxDdr3Clocks?.controllerClkMhz;
              if (coreMhz != null && ddrCtrlMhz != null) {
                File('$path/support/nextpnr/clocks.py').writeAsStringSync(
                  t.generateClockConstraintPy(
                    coreClkMhz: coreMhz,
                    ddrCtrlMhz: ddrCtrlMhz,
                  ),
                );
              }
            }
          }

          // Peripheral-contributed pins. The peripheral names its own cells;
          // the part those cells must land on comes down in the context, so a
          // provider can decline a family or a device it has no verified
          // placement for.
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

  const _PeripheralEntry({
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

  /// The fabric channel this master lives on. Masters on the same channel share
  /// one arbiter plus decoder. The default `'primary'` keeps every master on
  /// one channel, which is the classic single-fabric SoC.
  final String channel;

  const _MasterEntry({
    required this.module,
    required this.busInterfaceName,
    this.pipeline = false,
    this.channel = 'primary',
  });
}
