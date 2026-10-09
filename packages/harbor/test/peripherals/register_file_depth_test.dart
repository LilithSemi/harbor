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
}
