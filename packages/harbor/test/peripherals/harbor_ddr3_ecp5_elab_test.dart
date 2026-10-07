import 'package:harbor/src/peripherals/ddr3_config.dart';
import 'package:harbor/src/peripherals/harbor_ddr3.dart';
import 'package:harbor/src/soc/target.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Elaboration-shape proof. `HarborDdr3` on an ECP5 target must emit
/// the ECP5 x2 primitives, with the right count per DQS group (2 lanes,
/// OrangeCrab), and never a Xilinx DDR primitive. The reverse holds for the
/// Arty S7 (Xilinx) target: no ECP5 primitive leaks in.
void main() {
  tearDown(() async => Simulator.reset());

  int count(String sv, String cell) =>
      RegExp('\\b$cell\\b').allMatches(sv).length;

  /// Port connections of every instance of [cell], by instance name.
  Map<String, Map<String, String>> instances(String sv, String cell) {
    final out = <String, Map<String, String>>{};
    final inst = RegExp(
      '^\\s*$cell\\s+(?:#\\(.*?\\)\\s*)?(\\w+)\\s*\\((.*)\\);\\s*\$',
      multiLine: true,
    );
    for (final m in inst.allMatches(sv)) {
      out[m.group(1)!] = {
        for (final p in RegExp(
          r'\.(\w+)\(([^()]*(?:\([^()]*\))?[^()]*)\)',
        ).allMatches(m.group(2)!))
          p.group(1)!: p.group(2)!,
      };
    }
    return out;
  }

  // Xilinx 7-series primitives this PHY's DDR subtree could use.
  const xilinxCells = [
    'ODDR',
    'IDDR',
    'OSERDESE2',
    'ISERDESE2',
    'IDELAYE2',
    'ODELAYE2',
    'IDELAYCTRL',
    'IOBUF',
    'IOBUFDS',
    'OBUF',
    'OBUFDS',
  ];
  // ECP5 primitives this PHY's DDR subtree could use.
  const ecp5Cells = [
    'DQSBUFM',
    'IDDRX2DQA',
    'ODDRX2DQA',
    'ODDRX2DQSB',
    'TSHX2DQA',
    'TSHX2DQSA',
    'ODDRX2F',
    'DDRDLLA',
    'ECLKSYNCB',
    'ECLKBRIDGECS',
    'CLKDIVF',
  ];

  for (final runtime in [false, true]) {
    test(
      'ECP5 target (${runtime ? 'train=runtime' : 'train=hw'}): the x2 '
      'primitives appear with the per-DQS-group counts, no Xilinx primitive',
      () async {
        final ddr = HarborDdr3(
          config: const HarborDdrConfig.orangeCrab(),
          baseAddress: 0x40000000,
          clockHz: 48000000,
          busAddressWidth: 27,
          busDataWidth: 32,
          ckPeriodPs: 2500,
          target: const HarborFpgaTarget.ecp5(
            device: 'LFE5U-25F',
            package: 'CSFBGA285',
          ),
          runtimeTrainable: runtime,
        );
        await ddr.build();
        final sv = ddr.generateSynth();

        const lanes = 2; // OrangeCrab DQS groups
        const dqBits = 8;
        expect(count(sv, 'DQSBUFM'), lanes);
        expect(count(sv, 'IDDRX2DQA'), lanes * dqBits);
        expect(count(sv, 'ODDRX2DQA'), lanes * dqBits + lanes); // DQ + DM
        expect(count(sv, 'ODDRX2DQSB'), lanes);
        expect(count(sv, 'TSHX2DQA'), lanes * dqBits);
        expect(count(sv, 'TSHX2DQSA'), lanes);
        expect(count(sv, 'DDRDLLA'), 1);
        expect(count(sv, 'ECLKSYNCB'), 1);
        // One ECLKSYNCB must reach the edge clocks on both chip sides (DQ in
        // banks 6/7, address in bank 2), so it is fed through ECLKBRIDGECS.
        expect(count(sv, 'ECLKBRIDGECS'), 1);
        final ecsout = RegExp(
          r'ECLKBRIDGECS\s+\w+\s*\([^;]*\.ECSOUT\(([^)]*)\)',
        ).firstMatch(sv)!.group(1)!;
        final eclki = RegExp(
          r'ECLKSYNCB\s+\w+\s*\([^;]*\.ECLKI\(([^)]*)\)',
        ).firstMatch(sv)!.group(1)!;
        expect(eclki, ecsout);
        expect(count(sv, 'CLKDIVF'), 1);
        // CS#, RAS#, CAS#, WE#, ODT, CKE, RESET#, BA[2:0], A[12:0], CK, CK#.
        const cmdPads = 7 + 3 + 13;
        expect(instances(sv, 'ODDRX2F'), hasLength(cmdPads + 2));
        expect(instances(sv, 'BB'), hasLength(lanes * dqBits + lanes));
        expect(
          instances(sv, 'DELAYF'),
          hasLength(runtime ? lanes * dqBits : 0),
        );
        expect(
          instances(sv, 'DELAYG'),
          hasLength(cmdPads + 2 + (runtime ? 0 : lanes * dqBits)),
        );

        // Per DQS group: every DQ and DM cell of lane l runs off lane l's
        // DQSBUFM strobes.
        final bufm = instances(sv, 'DQSBUFM');
        final iddr = instances(sv, 'IDDRX2DQA');
        final oddr = instances(sv, 'ODDRX2DQA');
        final tsh = instances(sv, 'TSHX2DQA');
        final dqsOddr = instances(sv, 'ODDRX2DQSB');
        final dqsTsh = instances(sv, 'TSHX2DQSA');
        for (var l = 0; l < lanes; l++) {
          final b = bufm['dqsbufm_$l']!;
          for (var j = 0; j < dqBits; j++) {
            final gi = l * dqBits + j;
            expect(iddr['dq_iddr_$gi']!['DQSR90'], b['DQSR90'], reason: '$gi');
            expect(oddr['dq_oddr_$gi']!['DQSW270'], b['DQSW270']);
            expect(tsh['dq_tsh_$gi']!['DQSW270'], b['DQSW270']);
          }
          expect(oddr['dm_oddr_$l']!['DQSW270'], b['DQSW270']);
          expect(dqsOddr['dqs_oddr_$l']!['DQSW'], b['DQSW']);
          expect(dqsTsh['dqs_tsh_$l']!['DQSW'], b['DQSW']);
        }
        // The two groups have their own strobes.
        expect(
          bufm['dqsbufm_0']!['DQSR90'],
          isNot(bufm['dqsbufm_1']!['DQSR90']),
        );

        for (final cell in xilinxCells) {
          expect(
            count(sv, cell),
            0,
            reason: '$cell (Xilinx) leaked into the ECP5 build',
          );
        }
      },
    );
  }

  test('Arty S7 (Xilinx) target: the Xilinx primitives appear, no ECP5 '
      'primitive leaks in', () async {
    final ddr = HarborDdr3(
      config: const HarborDdrConfig.artyS7(),
      baseAddress: 0x80000000,
      clockHz: 75000000,
      busAddressWidth: 25,
      busDataWidth: 32,
      ckPeriodPs: 3333,
    );
    await ddr.build();
    final sv = ddr.generateSynth();

    expect(count(sv, 'OSERDESE2'), greaterThan(0));
    expect(count(sv, 'IDELAYE2'), greaterThan(0));
    expect(count(sv, 'IDELAYCTRL'), greaterThan(0));
    for (final cell in ['IOBUF', 'IOBUFDS', 'OBUF', 'OBUFDS']) {
      expect(count(sv, cell), greaterThan(0), reason: cell);
    }

    for (final cell in ecp5Cells) {
      expect(
        count(sv, cell),
        0,
        reason: '$cell (ECP5) leaked into the Xilinx build',
      );
    }
  });
}
