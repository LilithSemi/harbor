import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Backend-selection tests for HarborRegisterFile across FPGA targets. These
/// are elaboration and emitted-primitive checks. register_file_rdw_test.dart
/// simulates the flop and ECP5 paths.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const spartan7 = HarborFpgaTarget.spartan7(device: 's50', package: 'csga324');
  const ecp5 = HarborFpgaTarget.ecp5(device: '25f', package: 'CABGA256');

  test('Spartan 7 single-write uses RAMB36E1 with registered read', () async {
    final rf = HarborRegisterFile(target: spartan7);
    expect(rf.readLatency, equals(1));

    await rf.build();
    final sv = rf.generateSynth();
    expect(sv, contains('RAMB36E1'));
    expect(sv, isNot(contains('DP16KD')));
  });

  test('ECP5 single-write still uses DP16KD, not Xilinx BRAM', () async {
    final rf = HarborRegisterFile(target: ecp5);
    expect(rf.readLatency, equals(1));

    await rf.build();
    final sv = rf.generateSynth();
    expect(sv, contains('DP16KD'));
    expect(sv, isNot(contains('RAMB36E1')));
  });

  test('Spartan 7 multi-write falls back to the flop array', () async {
    final rf = HarborRegisterFile(
      numWritePorts: 2,
      numBanks: 2,
      target: spartan7,
    );
    // The flop path keeps latency 0 (the buffered multi-write path requires it).
    expect(rf.readLatency, equals(0));

    await rf.build();
    final sv = rf.generateSynth();
    expect(sv, isNot(contains('RAMB36E1')));
  });

  /// Drives the flop backend, writes [value] to [addr] on one cycle, then
  /// returns the combinational read of [addr].
  Future<int> writeThenRead(HarborRegisterFile rf, int addr, int value) async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final rdAddr = Logic(name: 'rd_addr', width: rf.addrWidth);
    final wrEn = Logic(name: 'wr_en');
    final wrAddr = Logic(name: 'wr_addr', width: rf.addrWidth);
    final wrData = Logic(name: 'wr_data', width: rf.dataWidth);

    rf.input('clk').srcConnection! <= clk;
    rf.input('reset').srcConnection! <= reset;
    rf.input('rd0_addr').srcConnection! <= rdAddr;
    rf.input('wr_en').srcConnection! <= wrEn;
    rf.input('wr_addr').srcConnection! <= wrAddr;
    rf.input('wr_data').srcConnection! <= wrData;

    await rf.build();

    reset.inject(1);
    rdAddr.inject(addr);
    wrEn.inject(0);
    wrAddr.inject(addr);
    wrData.inject(value);
    Simulator.setMaxSimTime(100000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    // Apply the write for one posedge.
    wrEn.inject(1);
    await clk.nextPosedge;
    wrEn.inject(0);
    // Combinational read of the now-stored value (settle past the edge).
    await clk.nextNegedge;
    final read = rf.readData(0).value.toInt();
    await Simulator.endSimulation();
    return read;
  }

  test(
    'reservedZero:false makes entry 0 a normal round-tripping entry',
    () async {
      final rf = HarborRegisterFile(
        numEntries: 4,
        dataWidth: 8,
        numReadPorts: 1,
        numWritePorts: 1,
        reservedZero: false,
      );
      expect(await writeThenRead(rf, 0, 0xAB), equals(0xAB));
    },
  );

  test('default reservedZero:true keeps entry 0 reading zero', () async {
    final rf = HarborRegisterFile(
      numEntries: 4,
      dataWidth: 8,
      numReadPorts: 1,
      numWritePorts: 1,
    );
    // A write to entry 0 is dropped and the read returns zero.
    expect(await writeThenRead(rf, 0, 0xAB), equals(0));
  });
}
