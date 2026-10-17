/// Kind of a [HarborEthClockConstraint].
enum HarborEthClockConstraintKind {
  /// A clock that comes in on a port.
  clock,

  /// A clock that the design sends out on a port.
  generatedClock,

  /// Input delay of data ports against a clock.
  inputDelay,

  /// Output delay of data ports against a clock.
  outputDelay,

  /// A path between two groups of flops that has more than one clock.
  multicyclePath,

  /// A clock domain crossing. Only the data path counts, with no clock
  /// skew, and the delay is at most [HarborEthClockConstraint.maxNs].
  maxDelay,

  /// Largest skew between the bits of a gray code bus that crosses clock
  /// domains.
  busSkew,

  /// No timing check to the pins in [HarborEthClockConstraint.toPins], such
  /// as the asynchronous preset of a reset synchronizer.
  falsePath,
}

/// One timing constraint entry of an Ethernet front end or MAC.
///
/// Port names are the names of the front end pins. The front end changes
/// them to top-level names when it makes the list.
class HarborEthClockConstraint {
  /// Kind of the entry.
  final HarborEthClockConstraintKind kind;

  /// Name of the clock that the entry makes or uses.
  final String clock;

  /// Ports of the entry. A bus port has `[*]` at the end.
  final List<String> ports;

  /// Clock period in ns, for [HarborEthClockConstraintKind.clock].
  final double? periodNs;

  /// Pattern of the full hierarchical name of the clock source pin, for
  /// [HarborEthClockConstraintKind.generatedClock].
  final String? sourcePin;

  /// Pattern of the full hierarchical name of the pin that a generated clock
  /// is on, for [HarborEthClockConstraintKind.generatedClock]. When it is
  /// set, the source is the port in [ports] and the clock is on this pin.
  final String? targetPin;

  /// Largest delay in ns, for a delay entry, or the largest skew for
  /// [HarborEthClockConstraintKind.busSkew].
  final double? maxNs;

  /// Smallest delay in ns, for a delay entry.
  final double? minNs;

  /// True when a delay entry is for the falling edge of [clock].
  final bool clockFall;

  /// Cell patterns at the start of a path. For a multicycle path they match
  /// the local cell name. For the other kinds they match the full
  /// hierarchical name.
  final List<String> fromCells;

  /// Cell patterns at the end of a path, the same as [fromCells].
  final List<String> toCells;

  /// Patterns of full hierarchical pin names at the end of a false path.
  final List<String> toPins;

  /// Setup multiplier of a multicycle path.
  final int setupCycles;

  /// Hold multiplier of a multicycle path.
  final int holdCycles;

  const HarborEthClockConstraint({
    required this.kind,
    required this.clock,
    required this.ports,
    this.periodNs,
    this.sourcePin,
    this.targetPin,
    this.maxNs,
    this.minNs,
    this.clockFall = false,
    this.fromCells = const [],
    this.toCells = const [],
    this.toPins = const [],
    this.setupCycles = 1,
    this.holdCycles = 0,
  });

  // nextpnr-xilinx takes create_clock only with a port name in no braces.
  String get _ports => ports.length == 1 && !ports.single.contains('[')
      ? '[get_ports ${ports.single}]'
      : '[get_ports {${ports.join(' ')}}]';

  String _ns(double v) => v.toStringAsFixed(3);

  static String _filter(List<String> names) =>
      '-filter {${names.map((n) => 'NAME =~ $n').join(' || ')}}';

  static String _cells(List<String> names) =>
      '[get_cells -hierarchical ${_filter(names)}]';

  /// The entry as XDC (Vivado) lines. The same text is valid SDC.
  List<String> toXdc() {
    switch (kind) {
      case HarborEthClockConstraintKind.clock:
        return ['create_clock -name $clock -period ${_ns(periodNs!)} $_ports'];
      case HarborEthClockConstraintKind.generatedClock when targetPin != null:
        return [
          'create_generated_clock -name $clock '
              '-source [get_ports ${ports.single}] -divide_by 1 '
              '[get_pins -hierarchical -filter {NAME =~ $targetPin}]',
        ];
      case HarborEthClockConstraintKind.generatedClock:
        return [
          'create_generated_clock -name $clock '
              '-source [get_pins -hierarchical -filter {NAME =~ $sourcePin}] '
              '-multiply_by 1 $_ports',
        ];
      case HarborEthClockConstraintKind.inputDelay:
      case HarborEthClockConstraintKind.outputDelay:
        final cmd = kind == HarborEthClockConstraintKind.inputDelay
            ? 'set_input_delay'
            : 'set_output_delay';
        final fall = clockFall ? ' -clock_fall -add_delay' : '';
        return [
          '$cmd -clock $clock -max ${_ns(maxNs!)}$fall $_ports',
          '$cmd -clock $clock -min ${_ns(minNs!)}$fall $_ports',
        ];
      case HarborEthClockConstraintKind.multicyclePath:
        String cells(List<String> c) =>
            '[get_cells -hierarchical {${c.join(' ')}}]';
        final path = '-from ${cells(fromCells)} -to ${cells(toCells)}';
        return [
          'set_multicycle_path -setup $setupCycles $path',
          'set_multicycle_path -hold $holdCycles $path',
        ];
      case HarborEthClockConstraintKind.maxDelay:
        return [
          'set_max_delay -datapath_only -from ${_cells(fromCells)} '
              '-to ${_cells(toCells)} ${_ns(maxNs!)}',
        ];
      case HarborEthClockConstraintKind.busSkew:
        return [
          'set_bus_skew -from ${_cells(fromCells)} '
              '-to ${_cells(toCells)} ${_ns(maxNs!)}',
        ];
      case HarborEthClockConstraintKind.falsePath:
        return [
          'set_false_path -to [get_pins -hierarchical ${_filter(toPins)}]',
        ];
    }
  }

  /// The entry as an LPF line for nextpnr-ecp5, or null when LPF has no
  /// statement for it. nextpnr-ecp5 uses clock periods only.
  String? toLpf() => kind == HarborEthClockConstraintKind.clock
      ? 'FREQUENCY PORT "${ports.single}" '
            '${(1000 / periodNs!).toStringAsFixed(3)} MHz;'
      : null;
}
