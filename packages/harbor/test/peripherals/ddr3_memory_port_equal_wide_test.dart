// The equality test of Ddr3MemoryPort for a controller word of 16 or more bus
// beats. A separate file keeps each file short.
import 'ddr3_memory_port_equal_test.dart';

void main() => runEqualTests([(32, 512), (8, 128)]);
