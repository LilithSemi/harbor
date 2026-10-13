import 'dart:async';

import 'package:harbor/src/peripherals/ddr3_config.dart'
    show HarborDdrConfig, HarborDdrType;
import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:harbor/src/peripherals/harbor_ddr3.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// wb2 register indices (the controller decodes a bus-width-independent
/// register index; the wrapper maps byte offset O -> index O>>3).
const int wOdelay = 1; // byte 0x08
const int wIdelay = 2; // byte 0x10
const int wCtl = 4; // byte 0x20
const int wCap = 6; // byte 0x30

class _Wb2 {
  final Logic cyc = Logic()..inject(0);
  final Logic stb = Logic()..inject(0);
  final Logic we = Logic()..inject(0);
  final Logic addr;
  final Logic sel;
  final Logic data;
  _Wb2()
    : addr = Logic(width: Ddr3Controller.wb2AddrBits)..inject(0),
      sel = Logic(width: Ddr3Controller.wb2SelBits)..inject(0),
      data = Logic(width: Ddr3Controller.wb2DataBits)..inject(0);
}

Ddr3Controller _build(
  DdrParams p, {
  required Logic clk,
  required Logic rstN,
  required _Wb2 wb2,
  required bool runtimeTrainable,
}) => Ddr3Controller(
  p,
  controllerClk: clk,
  rstN: rstN,
  wbCyc: Logic()..inject(0),
  wbStb: Logic()..inject(0),
  wbWe: Logic()..inject(0),
  wbAddr: Logic(width: p.wbAddrBits)..inject(0),
  wbData: Logic(width: p.wbDataBits)..inject(0),
  wbSel: Logic(width: p.wbSelBits)..inject(0),
  aux: Logic(width: Ddr3Controller.auxWidth)..inject(0),
  wb2Cyc: wb2.cyc,
  wb2Stb: wb2.stb,
  wb2We: wb2.we,
  wb2Addr: wb2.addr,
  wb2Sel: wb2.sel,
  wb2Data: wb2.data,
  phyIserdesData: Logic(width: p.dqBits * p.lanes * 8)..inject(0),
  phyIserdesDqs: Logic(width: p.lanes * 8)..inject(0),
  phyIserdesBitslipReference: Logic(width: p.lanes * 8)..inject(0),
  phyIdelayctrlRdy: Logic()..inject(0),
  runtimeTrainable: runtimeTrainable,
);

/// One wb2 write (asserted for a single controller cycle).
Future<void> _wb2Write(_Wb2 wb2, Logic clk, int addr, int data) async {
  wb2.cyc.inject(1);
  wb2.stb.inject(1);
  wb2.we.inject(1);
  wb2.addr.inject(addr);
  wb2.data.inject(data);
  await clk.nextPosedge;
  wb2.cyc.inject(0);
  wb2.stb.inject(0);
  wb2.we.inject(0);
}

/// Drives the real `train` Wishbone port of [ddr] with byte addresses, the
/// way the FSBL writes `train_base + index * 8`.
class _TrainPort {
  final HarborDdr3 ddr;
  final Logic clk;
  _TrainPort(this.ddr, this.clk);

  void _set(String p, int v) => ddr.input('train_$p').srcConnection!.inject(v);

  Future<int> access(int byteAddr, {int? write}) async {
    _set('CYC', 1);
    _set('STB', 1);
    _set('WE', write == null ? 0 : 1);
    _set('ADR', byteAddr);
    _set('DAT_MOSI', write ?? 0);
    _set('SEL', (1 << (ddr.trainBus!.sel.width)) - 1);
    var guard = 0;
    while (ddr.output('train_ACK').value.toInt() != 1) {
      await clk.nextPosedge;
      if (++guard > 400)
        throw StateError('no ACK at 0x${byteAddr.toRadixString(16)}');
    }
    final data = ddr.output('train_DAT_MISO').value.getRange(0, 32).toInt();
    await clk.nextNegedge;
    _set('CYC', 0);
    _set('STB', 0);
    _set('WE', 0);
    await clk.nextPosedge;
    return data;
  }
}

void main() {
  tearDown(() async => Simulator.reset());

  test('runtime knob write to ODELAY latches rtOdelay and drives o_phy after '
      'APPLY', () async {
    final clk = SimpleClockGenerator(10).clk;
    final rstN = Logic(name: 'rstn');
    final wb2 = _Wb2();
    final p = DdrParams.artyS7(ckPeriodPs: 3000);
    final dut = _build(
      p,
      clk: clk,
      rstN: rstN,
      wb2: wb2,
      runtimeTrainable: true,
    );
    await dut.build();

    rstN.inject(0);
    Simulator.setMaxSimTime(200000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    rstN.inject(1);
    await clk.nextPosedge;

    // Protocol: write ODELAY=7 -> CTL SET (lane 0) -> CTL LOAD/APPLY.
    await _wb2Write(wb2, clk, wOdelay, 0x7);
    await _wb2Write(wb2, clk, wCtl, 0x1); // SET, lane 0
    await _wb2Write(wb2, clk, wCtl, 0x2); // LOAD/APPLY
    await clk.nextPosedge;

    // The lane-0 knob register holds the applied value.
    expect(dut.rtOdelayRegs, isNotNull);
    expect(
      dut.rtOdelayRegs![0].value.toInt(),
      7,
      reason: 'rtOdelay[0] must latch the applied tap',
    );
    // And the PHY output follows the knob (override armed).
    expect(
      dut.output('o_phy_odelay_data_cntvaluein').value.toInt(),
      7,
      reason: 'o_phy_odelay_data_cntvaluein must reflect the runtime knob',
    );

    // A second lane/knob: IDELAY=0x1F on lane 1.
    await _wb2Write(wb2, clk, wIdelay, 0x1F);
    await _wb2Write(wb2, clk, wCtl, (1 << 8) | 0x1); // SET, lane 1
    await _wb2Write(wb2, clk, wCtl, 0x2); // LOAD/APPLY
    await clk.nextPosedge;
    expect(dut.rtIdelayRegs![1].value.toInt(), 0x1F);
    // Lane-0 odelay is untouched by the lane-1 idelay apply.
    expect(dut.rtOdelayRegs![0].value.toInt(), 7);

    await Simulator.endSimulation();
  });

  test('CAP register reports lanes/tapMax/slipMax and armed bit', () async {
    final clk = SimpleClockGenerator(10).clk;
    final rstN = Logic(name: 'rstn');
    final wb2 = _Wb2();
    final p = DdrParams.artyS7(ckPeriodPs: 3000);
    final dut = _build(
      p,
      clk: clk,
      rstN: rstN,
      wb2: wb2,
      runtimeTrainable: true,
    );
    await dut.build();

    rstN.inject(0);
    Simulator.setMaxSimTime(200000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    rstN.inject(1);
    await clk.nextPosedge;

    // Read CAP: assert an access, ack + data land one cycle later.
    wb2.cyc.inject(1);
    wb2.stb.inject(1);
    wb2.we.inject(0);
    wb2.addr.inject(wCap);
    await clk.nextPosedge;
    wb2.cyc.inject(0);
    wb2.stb.inject(0);
    await clk.nextPosedge;
    final cap = dut.output('o_wb2_data').value.toInt();
    expect((cap >> 4) & 0xF, p.lanes, reason: 'CAP[7:4] = lanes');
    expect((cap >> 8) & 0xFF, 31, reason: 'CAP[15:8] = tapMax');
    expect((cap >> 16) & 0xF, 7, reason: 'CAP[19:16] = slipMax');
    expect(cap & 0x1, 0, reason: 'runtimeActive still low, no APPLY yet');

    await Simulator.endSimulation();
  });

  test(
    'train=hw: wb2 is inert and o_phy knobs stay FSM-driven (golden guard)',
    () async {
      final clk = SimpleClockGenerator(10).clk;
      final rstN = Logic(name: 'rstn');
      final wb2 = _Wb2();
      final p = DdrParams.artyS7(ckPeriodPs: 3000);
      final dut = _build(
        p,
        clk: clk,
        rstN: rstN,
        wb2: wb2,
        runtimeTrainable: false,
      );
      await dut.build();

      // No runtime knob registers exist in train=hw.
      expect(dut.rtOdelayRegs, isNull);

      rstN.inject(0);
      Simulator.setMaxSimTime(200000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      rstN.inject(1);
      await clk.nextPosedge;

      final before = dut.output('o_phy_odelay_data_cntvaluein').value;

      // Drive the exact same knob sequence: it must be ignored.
      await _wb2Write(wb2, clk, wOdelay, 0x7);
      await _wb2Write(wb2, clk, wCtl, 0x1);
      await _wb2Write(wb2, clk, wCtl, 0x2);
      await clk.nextPosedge;

      // wb2 tie-off preserved: stall high, ack low, no knob override.
      expect(dut.output('o_wb2_stall').value.toInt(), 1);
      expect(dut.output('o_wb2_ack').value.toInt(), 0);
      expect(
        dut.output('o_phy_odelay_data_cntvaluein').value,
        before,
        reason: 'train=hw o_phy output must not follow wb2',
      );

      await Simulator.endSimulation();
    },
  );

  test(
    'train=hw: generated SV has no runtime-knob signals (regression guard)',
    () async {
      final p = DdrParams.artyS7(ckPeriodPs: 3000);
      final dut = _build(
        p,
        clk: Logic(name: 'c'),
        rstN: Logic(name: 'r'),
        wb2: _Wb2(),
        runtimeTrainable: false,
      );
      await dut.build();
      final sv = dut.generateSynth();
      expect(sv, isNot(contains('rt_odelay')));
      expect(sv, isNot(contains('rt_active')));
      expect(sv, isNot(contains('rt_wb2_ack')));
    },
  );

  test('HarborDdr3(runtimeTrainable:true) elaborates, exposes a wb2 slave, and '
      'dtNode has the training node', () async {
    final ddr = HarborDdr3(
      config: HarborDdrConfig(
        type: HarborDdrType.ddr3,
        size: 0x10000000,
        dataWidth: 16,
        frequency: 300000000,
        rowWidth: 14,
      ),
      baseAddress: 0x80000000,
      clockHz: 100000000,
      runtimeTrainable: true,
    );
    await ddr.build();

    // The knob-ABI wishbone slave is present.
    expect(ddr.trainBus, isNotNull);

    // dtNode carries geometry + a training child with 4 knobs + train-reg.
    final node = ddr.dtNode;
    expect(node.properties['harbor,ddr-lanes'], 2);
    final training = node.children.firstWhere((c) => c.name == 'training');
    final reg = training.properties['harbor,train-reg'] as List<int>;
    expect(reg[0], 0x80000000 + 0x10000000 - 0x1000);
    expect(reg[1], 0x1000);
    expect(training.properties['harbor,train-stride'], 8);
    expect(training.children.length, 4);
    expect(training.children[0].properties['harbor,knob'], 'write-level');
    expect(training.children[1].properties['harbor,reg'], [0x08]);
    expect(training.children[3].properties['harbor,knob'], 'bitslip');
  });

  test(
    'HarborDdr3(runtimeTrainable:false) keeps wb2 tied and dtNode plain',
    () async {
      final ddr = HarborDdr3(
        config: HarborDdrConfig(
          type: HarborDdrType.ddr3,
          size: 0x10000000,
          dataWidth: 16,
          frequency: 300000000,
          rowWidth: 14,
        ),
        baseAddress: 0x80000000,
        clockHz: 100000000,
      );
      await ddr.build();
      expect(ddr.trainBus, isNull);
      final node = ddr.dtNode;
      expect(node.children.where((c) => c.name == 'training'), isEmpty);
      expect(node.properties.containsKey('harbor,ddr-lanes'), isFalse);
    },
  );

  test('HarborDdr3(runtimeTrainable:true) elaborates on a 64-bit SoC bus '
      '(width-mismatch regression guard)', () async {
    final ddr = HarborDdr3(
      config: HarborDdrConfig(
        type: HarborDdrType.ddr3,
        size: 0x10000000,
        dataWidth: 16,
        frequency: 300000000,
        rowWidth: 14,
      ),
      baseAddress: 0x80000000,
      clockHz: 100000000,
      busDataWidth: 64,
      busAddressWidth: 64,
      runtimeTrainable: true,
    );
    await ddr.build();
    // The train slave is at the full bus width; the boundary narrows to wb2.
    final sv = ddr.generateSynth();
    expect(sv, contains('train_DAT_MOSI'));
    expect(ddr.trainBus, isNotNull);
    expect(ddr.trainBus!.dataIn.width, 64);
  });

  for (final busDW in [32, 64]) {
    test('HarborDdr3 $busDW-bit train port: FSBL byte offsets reach the knob '
        'registers', () async {
      final ddr = HarborDdr3(
        config: HarborDdrConfig(
          type: HarborDdrType.ddr3,
          size: 0x10000000,
          dataWidth: 16,
          frequency: 300000000,
          rowWidth: 14,
        ),
        baseAddress: 0x80000000,
        clockHz: 100000000,
        busDataWidth: busDW,
        busAddressWidth: 28,
        runtimeTrainable: true,
        ckPeriodPs: 3000,
      );
      final clk = SimpleClockGenerator(10).clk;
      for (final i in ddr.inputs.values) {
        i.srcConnection!.put(0);
      }
      // One clock for both sides keeps the sim deterministic. The port
      // layer still builds the crossing.
      ddr.input('clk').srcConnection! <= clk;
      ddr.input('ddr_clk').srcConnection! <= clk;
      await ddr.build();
      ddr.input('reset').srcConnection!.inject(1);
      ddr.input('ddr_reset').srcConnection!.inject(1);
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());
      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
      }
      ddr.input('reset').srcConnection!.inject(0);
      ddr.input('ddr_reset').srcConnection!.inject(0);
      // The controller leaves reset after the 4096 cycle power-on hold.
      for (var i = 0; i < 4200; i++) {
        await clk.nextPosedge;
      }

      final t = _TrainPort(ddr, clk);
      final base = ddr.trainBase - ddr.baseAddress;
      await t.access(base + 0x08, write: 0x7); // ODELAY = 7
      await t.access(base + 0x20, write: 0x1); // CTL SET, lane 0
      await t.access(base + 0x20, write: 0x2); // CTL LOAD/APPLY
      await clk.nextPosedge;
      final ctrl = ddr.controller!;
      expect(
        ctrl.rtOdelayRegs![0].value.toInt(),
        7,
        reason: 'byte 0x08 must hit ODELAY lane 0',
      );
      expect(
        ctrl.output('o_phy_odelay_data_cntvaluein').value.toInt(),
        7,
        reason: 'o_phy must follow the runtime knob after APPLY',
      );
      expect(await t.access(base + 0x08), 7, reason: 'ODELAY read-back');
      await Simulator.endSimulation();
    });
  }
}
