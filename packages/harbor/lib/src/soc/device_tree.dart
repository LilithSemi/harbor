import '../bus/bus.dart';
import '../util/pretty_string.dart';
import 'cpu.dart';

/// A device tree node: an immutable value object describing a device's
/// presence in the device tree.
///
/// Devices don't extend this directly. Instead, they implement
/// [HarborDeviceTreeNodeProvider] and return a [HarborDeviceTreeNode] from
/// [HarborDeviceTreeNodeProvider.dtNode].
/// A raw device-tree child node nested under a peripheral's [HarborDeviceTreeNode].
///
/// Unlike [HarborDeviceTreeNode] it has no required compatible/reg, so it models
/// both container nodes (e.g. `partitions`) and unit-addressed leaves (e.g.
/// `partition@0`, whose `reg` is a `<offset size>` pair under the container's own
/// #address-cells/#size-cells). Values follow the same encoding as node
/// properties: [String] -> "str", [int] -> <n>, [List<int>] -> <0x.. 0x..>.
class HarborDeviceTreeChild {
  /// The literal node name, e.g. `partitions` or `partition@300000`.
  final String name;

  /// Node properties (e.g. `label`, `reg`, `compatible`, `#address-cells`).
  final Map<String, Object> properties;

  /// Nested child nodes, one level deeper.
  final List<HarborDeviceTreeChild> children;

  const HarborDeviceTreeChild({
    required this.name,
    this.properties = const {},
    this.children = const [],
  });
}

/// One context (hart-facing register block) of an interrupt controller.
///
/// A RISC-V PLIC gives each privilege level that claims interrupts its own
/// enable, threshold and claim/complete block. [hartId] names the hart the
/// block belongs to and [cause] names the local interrupt it drives: 11 for
/// machine external, 9 for supervisor external.
///
/// The list order is the hardware context order, so entry N describes the
/// controller's context N. The same list drives the `interrupts-extended`
/// property and the SoC wiring, so the two cannot disagree.
class HarborInterruptContext {
  /// The hart that claims from this context.
  final int hartId;

  /// The hart-local interrupt cause this context drives.
  final int cause;

  const HarborInterruptContext({required this.hartId, required this.cause});

  /// Machine external interrupt (mip.MEIP) of [hartId].
  const HarborInterruptContext.machine(int hartId)
    : this(hartId: hartId, cause: 11);

  /// Supervisor external interrupt (mip.SEIP) of [hartId].
  const HarborInterruptContext.supervisor(int hartId)
    : this(hartId: hartId, cause: 9);

  @override
  String toString() => 'hart $hartId cause $cause';
}

class HarborDeviceTreeNode with HarborPrettyString {
  /// Device tree `compatible` strings.
  ///
  /// Most-specific first, with generic fallbacks after. Linux
  /// matches the first compatible string it has a driver for.
  ///
  /// Example: `['harbor,sdhci', 'sdhci']`. Linux tries the
  /// harbor-specific driver first, falls back to generic SDHCI.
  final List<String> compatible;

  /// Address range (`reg` property): base address and size.
  final BusAddressRange reg;

  /// Interrupt numbers this device sources.
  final List<int> interrupts;

  /// Whether this device is an interrupt controller.
  final bool interruptController;

  /// Number of cells in an interrupt specifier for this controller.
  final int interruptCells;

  /// Additional device tree properties.
  ///
  /// Values can be [int], [String], [List<int>], or [bool].
  final Map<String, Object> properties;

  /// Nested child nodes (e.g. a `partitions` container under a flash node).
  final List<HarborDeviceTreeChild> children;

  const HarborDeviceTreeNode({
    required this.compatible,
    required this.reg,
    this.interrupts = const [],
    this.interruptController = false,
    this.interruptCells = 1,
    this.properties = const {},
    this.children = const [],
  });

  /// The primary compatible string (first in the list).
  String get primaryCompatible => compatible.first;

  /// The node name used in the DTS.
  ///
  /// Generated from the first compatible string + hex base address.
  String get nodeName {
    final base = primaryCompatible
        .split(',')
        .last
        .replaceAll(RegExp(r'[^a-z0-9]'), '-');
    return '$base@${reg.start.toRadixString(16)}';
  }

  @override
  String toString() {
    final buf = StringBuffer(
      'HarborDeviceTreeNode(${compatible.join(", ")} @ '
      '0x${reg.start.toRadixString(16)}',
    );
    if (interruptController) buf.write(', interrupt-controller');
    if (interrupts.isNotEmpty) buf.write(', irqs: $interrupts');
    if (properties.isNotEmpty) buf.write(', $properties');
    buf.write(')');
    return buf.toString();
  }

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborDeviceTreeNode(\n');
    buf.writeln('${c}compatible: ${compatible.join(", ")},');
    buf.writeln(
      '${c}reg: 0x${reg.start.toRadixString(16)} (0x${reg.size.toRadixString(16)}),',
    );
    if (interruptController) buf.writeln('${c}interrupt-controller,');
    if (interruptCells != 1)
      buf.writeln('${c}#interrupt-cells: $interruptCells,');
    if (interrupts.isNotEmpty) buf.writeln('${c}interrupts: $interrupts,');
    for (final entry in properties.entries) {
      buf.writeln('$c${entry.key}: ${entry.value},');
    }
    buf.write('$p)');
    return buf.toString();
  }
}

/// Interface for devices that contribute a node to the device tree.
///
/// Implement this on any peripheral module to enable automatic DTS
/// generation, graph visualization, and introspection.
///
/// ```dart
/// class MyUart extends Module with HarborDeviceTreeNodeProvider {
///   @override
///   HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
///     compatible: 'ns16550a',
///     reg: BusAddressRange(0x10000000, 0x1000),
///   );
/// }
/// ```
mixin HarborDeviceTreeNodeProvider {
  /// The device tree node for this device.
  HarborDeviceTreeNode get dtNode;
}

/// Interface for devices that back usable system RAM (DRAM, etc.).
///
/// Their spans are emitted as root `memory@<addr>` nodes carrying
/// `device_type = "memory"`, which is where an OS/SBI payload looks for RAM,
/// rather than as an MMIO peripheral under `/soc`. A device implementing this
/// may still be a [HarborDeviceTreeNodeProvider] for its control-register
/// window, the two describe different resources.
mixin HarborSystemMemoryProvider {
  /// The usable RAM span(s) this device backs. Excludes any control-register
  /// window, matching the ACPI memory view.
  List<BusAddressRange> get systemMemory;
}

/// Generates a Linux/U-Boot compatible `.dts` file from a list of
/// [HarborDeviceTreeNodeProvider] peripherals and [HarborCpu] entries.
///
/// ```dart
/// final dts = HarborDeviceTreeGenerator(
///   model: 'Lilith Semiconductor Creek V1',
///   compatible: 'lilithsemi,creek-v1',
///   cpus: [HarborCpu(hartId: 0, isa: 'rv64imac')],
///   peripherals: [clint, plic, uart],
/// ).generate();
/// ```
class HarborDeviceTreeGenerator {
  /// Model name for the root `model` property.
  final String model;

  /// Root `compatible` string.
  final String compatible;

  /// Number of address cells.
  final int addressCells;

  /// Number of size cells.
  final int sizeCells;

  /// CPU entries.
  final List<HarborCpu> cpus;

  /// Peripheral nodes implementing [HarborDeviceTreeNodeProvider].
  final List<HarborDeviceTreeNodeProvider> peripherals;

  /// Usable system RAM spans, emitted as root `memory@<addr>` nodes with
  /// `device_type = "memory"`. Without these an OS/SBI payload finds no RAM.
  final List<BusAddressRange> memories;

  /// Interrupt numbers assigned to peripherals by the SoC's allocator, keyed
  /// by provider.
  ///
  /// When a provider has an entry here it overrides the node's own
  /// [HarborDeviceTreeNode.interrupts], so interrupt numbering lives in one
  /// place rather than being hardcoded per peripheral.
  final Map<HarborDeviceTreeNodeProvider, List<int>> interrupts;

  /// The interrupt controller's contexts, in hardware context order.
  ///
  /// Each entry becomes one `interrupts-extended` pair on the controller node,
  /// pointing at the `riscv,cpu-intc` child of its hart. Empty leaves the
  /// property out, which is what a SoC with no interrupt controller wants.
  final List<HarborInterruptContext> interruptContexts;

  const HarborDeviceTreeGenerator({
    required this.model,
    required this.compatible,
    this.addressCells = 1,
    this.sizeCells = 1,
    this.cpus = const [],
    this.peripherals = const [],
    this.memories = const [],
    this.interrupts = const {},
    this.interruptContexts = const [],
  });

  /// All device tree nodes from the peripherals.
  List<HarborDeviceTreeNode> get nodes =>
      peripherals.map((p) => p.dtNode).toList();

  /// Encodes [value] as [cells] 32-bit device-tree cells, most-significant
  /// first (big-endian cell order), e.g. cells=2 -> `0x<hi> 0x<lo>`.
  static String _regCells(int value, int cells) {
    final parts = <String>[];
    for (var i = cells - 1; i >= 0; i--) {
      parts.add('0x${((value >> (32 * i)) & 0xffffffff).toRadixString(16)}');
    }
    return parts.join(' ');
  }

  /// Generates the DTS source as a string.
  String generate() {
    final buf = StringBuffer();

    // Phandle plan. An `interrupts` number means nothing to an OS until the
    // node has a resolvable interrupt parent, so every SoC that has an
    // interrupt controller also gets a `riscv,cpu-intc` node per hart, a
    // phandle on each, and an `interrupt-parent` on the bus.
    //
    // Phandles are handed out in a fixed order (harts first, then interrupt
    // controllers) so the same SoC always emits the same numbers.
    final controllers = [
      for (final p in peripherals)
        if (p.dtNode.interruptController) p,
    ];
    final hasIntc = controllers.isNotEmpty;
    final cpuIntcPhandle = <int, int>{};
    if (hasIntc) {
      for (final (i, cpu) in cpus.indexed) {
        cpuIntcPhandle[cpu.hartId] = i + 1;
      }
    }
    final controllerPhandle = <HarborDeviceTreeNodeProvider, int>{
      for (final (i, c) in controllers.indexed) c: cpus.length + 1 + i,
    };
    // Nodes carry BOTH a label and an explicit `phandle`. dtc keeps the explicit
    // value, so the numbering stays deterministic, while the `&label` references
    // below are the conventional source form that dtc can check.
    String cpuIntcLabel(int hartId) => 'cpu${hartId}_intc';
    String controllerLabel(HarborDeviceTreeNodeProvider c) =>
        'intc${controllers.indexOf(c)}';

    buf.writeln('/dts-v1/;');
    buf.writeln();
    buf.writeln('/ {');
    buf.writeln('    model = "$model";');
    buf.writeln('    compatible = "$compatible";');
    buf.writeln('    #address-cells = <$addressCells>;');
    buf.writeln('    #size-cells = <$sizeCells>;');

    if (cpus.isNotEmpty) {
      buf.writeln();
      buf.writeln('    cpus {');
      buf.writeln('        #address-cells = <1>;');
      buf.writeln('        #size-cells = <0>;');
      for (final cpu in cpus) {
        buf.writeln();
        buf.writeln('        cpu@${cpu.hartId} {');
        buf.writeln('            device_type = "cpu";');
        buf.writeln('            compatible = "riscv";');
        buf.writeln('            reg = <0x${cpu.hartId.toRadixString(16)}>;');
        buf.writeln('            riscv,isa = "${cpu.isa}";');
        if (cpu.mmu != null) {
          buf.writeln('            mmu-type = "${cpu.mmu}";');
        }
        if (cpu.clockFrequency != null) {
          buf.writeln('            clock-frequency = <${cpu.clockFrequency}>;');
        }
        if (cpu.timebaseFrequency != null) {
          buf.writeln(
            '            timebase-frequency = <${cpu.timebaseFrequency}>;',
          );
        }
        buf.writeln('            status = "okay";');
        // The hart's own interrupt controller. `interrupts-extended` on the
        // platform controller points here, which is how an OS learns which
        // hart-local cause each context drives.
        final intc = cpuIntcPhandle[cpu.hartId];
        if (intc != null) {
          buf.writeln();
          buf.writeln(
            '            ${cpuIntcLabel(cpu.hartId)}: interrupt-controller {',
          );
          buf.writeln('                #interrupt-cells = <1>;');
          buf.writeln('                compatible = "riscv,cpu-intc";');
          buf.writeln('                interrupt-controller;');
          buf.writeln(
            '                phandle = <0x${intc.toRadixString(16)}>;',
          );
          buf.writeln('            };');
        }
        buf.writeln('        };');
      }
      buf.writeln('    };');
    }

    for (final region in memories) {
      buf.writeln();
      buf.writeln('    memory@${region.start.toRadixString(16)} {');
      buf.writeln('        device_type = "memory";');
      // The memory node is a root child, so its reg is encoded in the ROOT's
      // #address-cells/#size-cells. RV64 SoCs use 2/2 (64-bit base+size), a
      // parser that reads 64-bit cells (e.g. Ferrite's SBI dtb.parseMemory) then
      // sees the right span. Emit exactly [addressCells] + [sizeCells] cells.
      buf.writeln(
        '        reg = <${_regCells(region.start, addressCells)} '
        '${_regCells(region.size, sizeCells)}>;',
      );
      buf.writeln('    };');
    }

    if (peripherals.isNotEmpty) {
      buf.writeln();
      buf.writeln('    soc {');
      buf.writeln('        compatible = "simple-bus";');
      buf.writeln('        #address-cells = <$addressCells>;');
      buf.writeln('        #size-cells = <$sizeCells>;');
      buf.writeln('        ranges;');
      // Every device under this bus inherits the controller as its interrupt
      // parent, so a plain `interrupts = <n>` resolves without repeating the
      // property on each node.
      if (hasIntc) {
        buf.writeln(
          '        interrupt-parent = <&${controllerLabel(controllers.first)}>;',
        );
      }

      for (final p in peripherals) {
        final node = p.dtNode;
        final irqList = interrupts[p] ?? node.interrupts;
        buf.writeln();
        final label = node.interruptController ? '${controllerLabel(p)}: ' : '';
        buf.writeln('        $label${node.nodeName} {');
        final compatStr = node.compatible.map((c) => '"$c"').join(', ');
        buf.writeln('            compatible = $compatStr;');
        buf.writeln(
          '            reg = <${_regCells(node.reg.start, addressCells)} '
          '${_regCells(node.reg.size, sizeCells)}>;',
        );

        if (node.interruptController) {
          buf.writeln('            interrupt-controller;');
          buf.writeln(
            '            #interrupt-cells = <${node.interruptCells}>;',
          );
          buf.writeln(
            '            phandle = '
            '<0x${controllerPhandle[p]!.toRadixString(16)}>;',
          );
          // One pair per hardware context, in context order: the hart's
          // cpu-intc phandle and the cause that context drives.
          final pairs = [
            for (final ctx in interruptContexts)
              if (cpuIntcPhandle[ctx.hartId] != null)
                '<&${cpuIntcLabel(ctx.hartId)} '
                    '0x${ctx.cause.toRadixString(16)}>',
          ];
          if (pairs.isNotEmpty) {
            buf.writeln(
              '            interrupts-extended = ${pairs.join(', ')};',
            );
          }
        }

        if (irqList.isNotEmpty) {
          final irqs = irqList.map((i) => '0x${i.toRadixString(16)}').join(' ');
          buf.writeln('            interrupts = <$irqs>;');
        }

        for (final entry in node.properties.entries) {
          _emitProperty(buf, '            ', entry.key, entry.value);
        }

        for (final child in node.children) {
          _emitChild(buf, child, '            ');
        }

        buf.writeln('        };');
      }

      buf.writeln('    };');
    }

    buf.writeln('};');
    return buf.toString();
  }

  /// Recursively emits a nested [HarborDeviceTreeChild] at [indent].
  void _emitChild(StringBuffer buf, HarborDeviceTreeChild c, String indent) {
    buf.writeln('$indent${c.name} {');
    for (final entry in c.properties.entries) {
      _emitProperty(buf, '$indent    ', entry.key, entry.value);
    }
    for (final child in c.children) {
      _emitChild(buf, child, '$indent    ');
    }
    buf.writeln('$indent};');
  }

  /// Emits one property line. A DTS boolean is the bare property name (its
  /// presence means true); a false boolean is omitted entirely. Everything
  /// else is `key = <value>;`.
  void _emitProperty(
    StringBuffer buf,
    String indent,
    String key,
    Object value,
  ) {
    if (value is bool) {
      if (value) buf.writeln('$indent$key;');
      return;
    }
    buf.writeln('$indent$key = ${_formatValue(value)};');
  }

  String _formatValue(Object value) {
    if (value is String) return '"$value"';
    if (value is int) return '<$value>';
    if (value is List<int>) {
      return '<${value.map((v) => '0x${v.toRadixString(16)}').join(' ')}>';
    }
    return '"$value"';
  }
}

/// A peripheral whose driver cannot work without knowing the rate of the clock
/// it is wired to: a UART picks a baud divisor from it, an SPI or SDIO
/// controller picks a bus-clock divider, an I2C controller a prescaler.
///
/// These all used to take the rate as a constructor argument defaulting to 0,
/// and quietly OMIT the property when nobody passed one. The node then looked
/// well-formed but the Linux driver refused to probe (`no controller clock
/// rate`). The SoC knows the answer, so it fills it in: see
/// `HarborSoC.addPeripheral`. An explicitly supplied rate is never overridden.
mixin HarborInputClockConsumer {
  /// Rate in Hz, 0 when still unknown.
  int get inputClockHz;

  /// Called by the SoC with the rate of the clock domain this peripheral was
  /// wired to. Implementations must ignore it once a rate is known.
  void provideInputClockHz(int hz);
}
