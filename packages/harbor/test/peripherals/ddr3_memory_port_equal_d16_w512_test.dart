// Cycle equality of Ddr3MemoryPort with the earlier form, for a 16 bit bus
// and a 512 bit controller word.
import 'ddr3_memory_port_equal_ref.dart';

void main() => runEqualTests([(16, 512)]);
