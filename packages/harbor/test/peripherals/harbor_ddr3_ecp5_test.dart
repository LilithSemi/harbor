import 'package:harbor/src/peripherals/ddr3_config.dart';
import 'package:harbor/src/peripherals/harbor_ddr3.dart';
import 'package:harbor/src/soc/target.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _ecp5 = HarborFpgaTarget.ecp5(device: 'LFE5U-25F', package: 'CSFBGA285');

HarborDdr3 _ddr({
  HarborDeviceTarget? target = _ecp5,
  bool runtimeTrainable = false,
  int gear = 1,
}) => HarborDdr3(
  config: const HarborDdrConfig.orangeCrab(),
  baseAddress: 0x40000000,
  clockHz: 48000000,
  busAddressWidth: 27,
  busDataWidth: 32,
  ckPeriodPs: 2500,
  target: target,
  runtimeTrainable: runtimeTrainable,
  controllerGearRatio: gear,
);

List<String> _knobs(HarborDdr3 d) => [
  for (final k in d.dtNode.children.single.children)
    k.properties['harbor,knob']! as String,
];

void main() {
  tearDown(() async => Simulator.reset());

  for (final runtime in [false, true]) {
    test('an ECP5 target builds Ddr3PhyEcp5 '
        '(${runtime ? 'train=runtime' : 'train=hw'})', () async {
      final d = _ddr(runtimeTrainable: runtime);
      await d.build();
      final sv = d.generateSynth();
      expect(sv, contains('module Ddr3PhyEcp5'));
      expect(sv, contains('DQSBUFM'));
      expect(sv, isNot(contains('IDELAYCTRL')));
      expect(sv, isNot(contains('module Ddr3Phy(')));
      expect(d.output('sdram_addr').width, 13);
      expect(d.outputs, contains('cal_failed'));
      expect(d.controller!.phySelfTrainsRead, isTrue);
      expect(d.dtNode.properties['harbor,ddr-rows'], runtime ? 13 : isNull);
      if (runtime) {
        // ECP5 has no write taps and no write leveling to sweep.
        expect(_knobs(d), ['bitslip', 'read-clk-sel', 'read-idelay']);
        final slip = d.dtNode.children.single.children.first;
        expect(slip.properties['harbor,max'], [15]);
      }
    });
  }

  test('the Xilinx knob table is unchanged', () {
    final d = _ddr(target: null, runtimeTrainable: true);
    expect(_knobs(d), [
      'write-level',
      'write-odelay',
      'read-idelay',
      'bitslip',
    ]);
    expect(d.controller, isNotNull);
    expect(d.controller!.phySelfTrainsRead, isFalse);
    expect(d.outputs, isNot(contains('cal_failed')));
  });

  test('an ECP5 target rejects the CK/8 geared controller', () {
    expect(() => _ddr(gear: 2), throwsArgumentError);
  });
}
