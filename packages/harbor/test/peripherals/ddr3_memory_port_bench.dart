import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../bus/port/port_harness.dart';
import 'ddr3_ecp5_pad_dram_model.dart';
import 'memory_port_bench.dart';

const _pads = [
  'sdram_ck',
  'sdram_ck_n',
  'sdram_cke',
  'sdram_cs_n',
  'sdram_ras_n',
  'sdram_cas_n',
  'sdram_we_n',
  'sdram_ba',
  'sdram_addr',
  'sdram_dm',
  'sdram_odt',
  'sdram_reset_n',
  'sdram_dq',
  'sdram_dqs',
  'sdram_dqs_n',
];

/// A requester on the fabric clock `clk` linked to an ECP5 [HarborDdr3] on
/// `ddr_clk`, with the DDR3 pads on the top.
class _Ddr3Bench extends BridgeModule {
  late final HarborDdr3 ddr;

  _Ddr3Bench(HarborFabricKind kind, HarborMemoryWaistConfig config)
    : super('Ddr3PortBench_${kind.name}', name: 'top') {
    for (final p in ['clk', 'reset', 'ddr_clk', 'ddr_reset', 'ddr_ck_fast']) {
      createPort(p, PortDirection.input);
    }
    ddr = addSubModule(
      HarborDdr3(
        config: const HarborDdrConfig.orangeCrab(),
        baseAddress: 0x40000000,
        clockHz: 48000000,
        busAddressWidth: config.addressWidth,
        busDataWidth: config.dataWidth,
        ckPeriodPs: 200000,
        protocol: kind,
        idWidth: config.idWidth,
        target: const HarborFpgaTarget.ecp5(
          device: 'LFE5U-25F',
          package: 'CSFBGA285',
        ),
      ),
    );
    for (final p in ['clk', 'reset', 'ddr_clk', 'ddr_reset', 'ddr_ck_fast']) {
      ddr.input(p).srcConnection! <= input(p);
    }
    for (final p in ['ddr_ck90_fast', 'ddr_ck_dqs_fast', 'ddr_idelay_ref']) {
      ddr.input(p).srcConnection! <= Const(0);
    }
    for (final p in _pads) {
      pullUpPort(ddr.port(p), newPortName: p);
    }
    linkRequester(this, ddr, config, kind);
  }
}

/// Random bursts from a requester on a fabric clock of [fabricPeriod]
/// through the native [kind] port of an ECP5 [HarborDdr3], whose memory
/// clock is CK/4 with CK of period 4. The DDR3 pins drive a pad level DRAM
/// model, and the port layer crosses between the two clocks.
Future<void> ddr3RandomBursts(
  HarborFabricKind kind, {
  required int fabricPeriod,
  required int seed,
  int count = 12,
}) async {
  const config = HarborMemoryWaistConfig(
    addressWidth: 27,
    dataWidth: 32,
    idWidth: 2,
    outstanding: 2,
  );
  final top = _Ddr3Bench(kind, config);
  final p = DdrParams.orangeCrab(ckPeriodPs: 200000);

  final ck = SimpleClockGenerator(4).clk;
  final divInit = Logic(name: 'div_init')..inject(1);
  Simulator.registerAction(4, () => divInit.put(0));
  final div = Logic(name: 'div', width: 2);
  Sequential(ck, reset: divInit, [div < div + 1]);
  final ddrClk = div[1];
  final fabricClk = SimpleClockGenerator(fabricPeriod).clk;

  for (final input in top.inputs.values) {
    if (!{'clk', 'ddr_clk', 'ddr_ck_fast'}.contains(input.name)) {
      input.srcConnection!.put(0);
    }
  }
  top.input('clk').srcConnection! <= fabricClk;
  top.input('ddr_clk').srcConnection! <= ddrClk;
  top.input('ddr_ck_fast').srcConnection! <= ck;
  await top.build();

  final dram = Ddr3PinDramModel(
    p,
    ck: top.output('sdram_ck'),
    cke: top.output('sdram_cke'),
    resetN: top.output('sdram_reset_n'),
    csN: top.output('sdram_cs_n'),
    rasN: top.output('sdram_ras_n'),
    casN: top.output('sdram_cas_n'),
    weN: top.output('sdram_we_n'),
    ba: top.output('sdram_ba'),
    addr: top.output('sdram_addr'),
    dm: top.output('sdram_dm'),
    dqPad: top.inOutSource('sdram_dq') as LogicNet,
    dqsPad: top.inOutSource('sdram_dqs') as LogicNet,
    dmRemapping: const HarborDdrConfig.orangeCrab().dmRemapping,
  );

  final s = Sim(top, clk: fabricClk);
  final check = MemoryPortCheck(
    s,
    Random(seed),
    busBytes: config.strbWidth,
    idWidth: config.idWidth,
    span: 0x800,
    timeout: 4000000,
  );
  s.attach();
  top.input('reset').srcConnection!.put(1);
  top.input('ddr_reset').srcConnection!.put(1);
  Simulator.setMaxSimTime(1 << 40);
  s.watchEnd();
  unawaited(Simulator.run());

  for (var i = 0; i < 20; i++) {
    await ck.nextPosedge;
  }
  top.input('ddr_reset').srcConnection!.inject(0);
  await fabricClk.nextNegedge;
  top.input('reset').srcConnection!.inject(0);
  await fabricClk.nextNegedge;
  s.running = true;

  // The power-on hold is 4096 memory clocks, then the controller calibrates.
  final ctrl = top.ddr.controller!;
  var state = -1;
  for (var i = 0; i < 40000 && state != 23 && state != 26; i++) {
    await ddrClk.nextPosedge;
    final v = ctrl.debug1.value.getRange(0, 6);
    state = v.isValid ? v.toInt() : -1;
  }
  expect(state, 23, reason: 'DONE_CALIBRATE');

  await check.fill();
  final bad = await check.run(count, extra: longBursts(Random(seed), 4));
  final busError = top.ddr.busError.value.toInt();
  await Simulator.endSimulation();
  expect([for (final e in dram.errors) 'dram: $e', ...bad], isEmpty);
  expect(busError, 0);
}
