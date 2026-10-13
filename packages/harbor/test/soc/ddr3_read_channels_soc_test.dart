import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../peripherals/ddr3_fast_bench.dart' show DisplayMaster;

HarborSoC _soc() => HarborSoC(
  name: 'ddr_rc',
  compatible: 'test,ddr-rc',
  fabricKind: HarborFabricKind.axi4,
  fabricTopology: HarborFabricTopology.crossbar,
  target: const HarborSimTarget(frequency: 100000000),
);

HarborDdr3 _ddr(int readChannels) => HarborDdr3(
  config: const HarborDdrConfig.ax7203(),
  baseAddress: 0x80000000,
  clockHz: 100000000,
  busAddressWidth: 32,
  ckPeriodPs: 2500,
  protocol: HarborFabricKind.axi4,
  idWidth: 3,
  readChannels: readChannels,
  target: const HarborSimTarget(),
  name: 'ddr',
);

void main() {
  tearDown(Simulator.reset);

  test('the fabric gets every read channel of a DDR3 slave', () async {
    final soc = _soc();
    final ddr = soc.addPeripheral(_ddr(2));
    for (final (i, ch) in [(0, null), (1, null), (2, 0)]) {
      final m = DisplayMaster(name: 'disp$i');
      soc.addMaster(
        m,
        busInterfaceName: 'bus',
        memory: true,
        outstanding: 4,
        readChannel: ch,
      );
      for (final p in ['fetch_start', 'fetch_addr', 'words']) {
        m.input(p).srcConnection! <= Const(0, width: m.input(p).width);
      }
    }
    for (final p in [
      'ddr_clk',
      'ddr_reset',
      'ddr_ck_fast',
      'ddr_ck90_fast',
      'ddr_ck_dqs_fast',
      'ddr_idelay_ref',
    ]) {
      ddr.input(p).srcConnection! <= Const(0);
    }
    soc.buildFabric();
    final fabric = soc.fabrics.single as HarborAxi4Fabric;
    final slave = fabric.slaves.single;
    expect(slave.readChannels, 2);
    expect(slave.outstanding, 8);
    expect(fabric.masters.map((m) => m.readChannel), [null, null, 0]);
    await soc.build();
    final sv = soc.generateSynth();
    expect(sv, contains('bus_r1_ARVALID'));
  });

  test('a DDR3 slave with two read channels behind a converge throws', () {
    final soc = HarborSoC(
      name: 'ddr_rc2',
      compatible: 'test,ddr-rc',
      fabricKind: HarborFabricKind.axi4,
      target: const HarborSimTarget(frequency: 100000000),
    );
    soc.addPeripheral(_ddr(2));
    soc
      ..addMaster(
        DisplayMaster(name: 'a'),
        busInterfaceName: 'bus',
        memory: true,
        channel: 'primary',
      )
      ..addMaster(
        DisplayMaster(name: 'b'),
        busInterfaceName: 'bus',
        memory: true,
        channel: 'gpu',
      );
    expect(
      () => soc.buildFabric(
        channelSlaves: {
          'primary': {'ddr'},
          'gpu': {'ddr'},
        },
      ),
      throwsStateError,
    );
  });
}
