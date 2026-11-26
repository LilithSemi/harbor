import 'dart:io';
import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';

Future<void> main() async {
  final clk = Logic(name: 'clk');
  final rdAddr = Logic(name: 'rd_addr', width: 10);
  final wrEn = Logic(name: 'wr_en');
  final wrAddr = Logic(name: 'wr_addr', width: 10);
  final wrData = Logic(name: 'wr_data', width: 139);
  final contents = [
    for (var a = 0; a < 679; a++)
      (BigInt.from(a) * BigInt.parse('0x1F2E3D4C5B6A79') + BigInt.from(0x55)) &
          ((BigInt.one << 139) - BigInt.one),
  ];
  final rom = Ecp5InitRom(
    clk,
    contents: contents,
    width: 139,
    rdAddr: rdAddr,
    wrEn: wrEn,
    wrAddr: wrAddr,
    wrData: wrData,
  );
  await rom.build();
  File('/tmp/ecp5_rom.sv').writeAsStringSync(rom.dumpSystemVerilog());
  print('wrote /tmp/ecp5_rom.sv');
}
