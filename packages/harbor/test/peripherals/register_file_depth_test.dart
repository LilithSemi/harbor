import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());
  for (final entries in [1024, 1025, 2048, 4096]) {
    for (final width in [32, 54, 64]) {
      for (final ports in [1, 2]) {
        test(
          'Xilinx $entries x $width with $ports registered read ports',
          () async {
            final rf = HarborRegisterFile(
              numEntries: entries,
              dataWidth: width,
              numReadPorts: ports,
              reservedZero: false,
              target: const HarborFpgaTarget.spartan7(
                device: 's50',
                package: 'csga324',
              ),
            );
            expect(rf.readLatency, 1);
            await rf.build();
            final sv = rf.generateSynth();
            expect(
              RegExp(r'RAMB36E1 #').allMatches(sv).length,
              ((entries + 1023) ~/ 1024) * ((width + 31) ~/ 32) * ports,
            );
            if (entries > 1024) {
              for (var port = 0; port < ports; port++) {
                expect(sv, contains('rfBramDepthQ_$port'));
              }
            }
          },
        );
      }
    }
  }

  const ecp5 = HarborFpgaTarget.ecp5(device: 'lfe5u-25f', package: 'CABGA256');
  const ice40 = HarborFpgaTarget.ice40(device: 'up5k', package: 'sg48');

  for (final entries in [2048, 2049, 4096]) {
    test('ECP5 $entries x 32 uses one DP16KD per 2048 entries', () async {
      final rf = HarborRegisterFile(
        numEntries: entries,
        dataWidth: 32,
        numReadPorts: 2,
        reservedZero: false,
        target: ecp5,
      );
      await rf.build();
      final sv = rf.generateSynth();
      expect(
        RegExp(r'DP16KD #').allMatches(sv).length,
        ((entries + 2047) ~/ 2048) * 4 * 2,
      );
    });
  }

  for (final entries in [256, 257, 1024]) {
    test('iCE40 $entries x 32 uses one EBR per 256 entries', () async {
      final rf = HarborRegisterFile(
        numEntries: entries,
        dataWidth: 32,
        numReadPorts: 1,
        reservedZero: false,
        target: ice40,
      );
      await rf.build();
      final sv = rf.generateSynth();
      expect(
        RegExp(r'SB_RAM40_4KNR ').allMatches(sv).length,
        ((entries + 255) ~/ 256) * 2,
      );
    });
  }

  test('ECP5 6144-entry file keeps entries of each block apart', () async {
    final rf = HarborRegisterFile(
      numEntries: 6144,
      dataWidth: 32,
      numReadPorts: 1,
      reservedZero: false,
      target: ecp5,
    );
    final clk = SimpleClockGenerator(10).clk;
    final ins = <String, Logic>{};
    for (final name in ['reset', 'wr_en', 'wr_addr', 'wr_data', 'rd0_addr']) {
      ins[name] = Logic(width: rf.input(name).width);
      rf.input(name).srcConnection! <= ins[name]!;
    }
    rf.input('clk').srcConnection! <= clk;
    await rf.build();
    for (final i in ins.values) {
      i.inject(0);
    }
    Simulator.setMaxSimTime(1000000);
    unawaited(Simulator.run());

    int value(int a) => 0x5a000000 ^ (a * 0x10001);
    const addresses = [0, 5, 2047, 2048, 2053, 4095, 4096, 4101, 6143];
    ins['wr_en']!.inject(1);
    for (final a in addresses) {
      ins['wr_addr']!.inject(a);
      ins['wr_data']!.inject(value(a));
      await clk.nextPosedge;
    }
    ins['wr_en']!.inject(0);
    for (final a in addresses) {
      ins['rd0_addr']!.inject(a);
      await clk.nextPosedge;
      await clk.nextNegedge;
      expect(rf.readData(0).value.toInt(), value(a), reason: 'entry $a');
    }
    await Simulator.endSimulation();
  });

  test('flop and block RAM files of one shape get different names', () async {
    final top = _TwoFiles(ecp5);
    await top.build();
    final names = {for (final m in top.subModules) m.name: m.definitionName};
    expect(names['flop'], isNot(names['ebr']));
    expect(names['flop'], endsWith('_flop'));
    expect(names['ebr'], endsWith('_ecp5'));
    expect(top.generateSynth(), contains(names['ebr']));
  });
}

/// One flop register file and one ECP5 register file of the same shape and
/// read latency.
class _TwoFiles extends Module {
  _TwoFiles(HarborDeviceTarget target) : super(name: 'two_files') {
    final clk = addInput('clk', Logic());
    final addr = addInput('addr', Logic(width: 5), width: 5);
    final data = addInput('data', Logic(width: 32), width: 32);
    final out = addOutput('out', width: 32);
    final files = [
      HarborRegisterFile(numReadPorts: 1, forceReadLatency: 1, name: 'flop'),
      HarborRegisterFile(numReadPorts: 1, target: target, name: 'ebr'),
    ];
    for (final rf in files) {
      rf.input('clk').srcConnection! <= clk;
      rf.input('reset').srcConnection! <= Const(0);
      rf.input('rd0_addr').srcConnection! <= addr;
      rf.input('wr_en').srcConnection! <= Const(1);
      rf.input('wr_addr').srcConnection! <= addr;
      rf.input('wr_data').srcConnection! <= data;
    }
    out <= files[0].readData(0) ^ files[1].readData(0);
  }
}
