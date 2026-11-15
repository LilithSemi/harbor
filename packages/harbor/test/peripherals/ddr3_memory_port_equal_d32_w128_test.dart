// Cycle equality of Ddr3MemoryPort with the earlier form, for a 32 bit bus
// and a 128 bit controller word.
import 'ddr3_memory_port_equal_ref.dart';

void main() => runEqualTests([(32, 128)]);
