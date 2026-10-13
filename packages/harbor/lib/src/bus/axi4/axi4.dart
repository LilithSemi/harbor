/// AXI4 bus support for Harbor.
///
/// Re-exports rohd_hcl's AXI4 interface definitions and adds
/// convenience configuration and missing arbiter/decoder components.
library;

export 'package:rohd_hcl/src/interfaces/axi4.dart';

export 'axi4_config.dart';
export 'axi4_interface.dart';
export 'axi4_lite_interface.dart';
export 'axi4_memory_port.dart';
export 'axi4_fabric.dart';
