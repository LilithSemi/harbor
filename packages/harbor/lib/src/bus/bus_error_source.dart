import 'package:rohd/rohd.dart';

/// A module with a sticky bus error flag that the SoC adds to its
/// `bus_error` output.
mixin HarborBusErrorSource on Module {
  /// High after the module ended a bus cycle with an error or poison data.
  /// Stays high until reset.
  Logic get busError;
}
