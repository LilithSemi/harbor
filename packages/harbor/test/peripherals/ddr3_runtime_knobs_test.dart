import 'dart:async';

import 'package:harbor/src/clock/wishbone_cdc_fifo.dart';
import 'package:harbor/src/peripherals/ddr3_config.dart'
    show HarborDdrConfig, HarborDdrType;
import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:harbor/src/peripherals/harbor_ddr3.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
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

/// Fabric harness: a 64-bit SoC-side wishbone -> train_cdc (CDC FIFO) -> the
/// wb2 boundary adaptation (mirror of HarborDdr3._build) -> Ddr3Controller wb2.
/// Proves the width + address-granularity conversion end to end at 64-bit.
class _Wb2FabricTop extends BridgeModule {
  late final Ddr3Controller controller;

  _Wb2FabricTop(DdrParams p) : super('_Wb2FabricTop', name: 'wb2_fabric_top') {
    const busDW = 64;
    createPort('sys_clk', PortDirection.input);
    createPort('ddr_clk', PortDirection.input);
    createPort('rst_n', PortDirection.input);
    createPort('t_cyc', PortDirection.input);
    createPort('t_stb', PortDirection.input);
    createPort('t_we', PortDirection.input);
    createPort('t_adr', PortDirection.input, width: busDW);
    createPort('t_dat', PortDirection.input, width: busDW);
    createPort('t_sel', PortDirection.input, width: busDW ~/ 8);

    final sysClk = input('sys_clk');
    final ddrClk = input('ddr_clk');
    final rstN = input('rst_n');
    final rst = ~rstN;

    final cdc = HarborWishboneCdcFifoBridge(
      addressWidth: busDW,
      dataWidth: busDW,
      selWidth: busDW ~/ 8,
      depth: 16,
      name: 'train_cdc',
    );
    addSubModule(cdc);
    cdc.input('s_clk').srcConnection! <= sysClk;
    cdc.input('s_reset').srcConnection! <= rst;
    cdc.input('s_cyc').srcConnection! <= input('t_cyc');
    cdc.input('s_stb').srcConnection! <= input('t_stb');
    cdc.input('s_we').srcConnection! <= input('t_we');
    cdc.input('s_adr').srcConnection! <= input('t_adr');
    cdc.input('s_dat_w').srcConnection! <= input('t_dat');
    cdc.input('s_sel').srcConnection! <= input('t_sel');
    cdc.input('m_clk').srcConnection! <= ddrClk;
    cdc.input('m_reset').srcConnection! <= rst;

    // wb2 boundary adaptation (mirror of HarborDdr3._build).
    final wordShift = (busDW ~/ 8).bitLength - 1; // log2(bytesPerWord) = 3
    final mAdr = cdc.output('m_adr');
    final byteAddr = [mAdr, Const(0, width: wordShift)].swizzle();
    final wb2Addr = byteAddr.getRange(3, 3 + Ddr3Controller.wb2AddrBits);
    final wb2Data = cdc
        .output('m_dat_w')
        .getRange(0, Ddr3Controller.wb2DataBits);
    final wb2Sel = cdc.output('m_sel').getRange(0, Ddr3Controller.wb2SelBits);
    final wb2Cyc = cdc.output('m_cyc') & cdc.output('m_stb');

    final wb2Ack = Logic(name: 'wb2_ack');
    final wb2DataOut = Logic(
      name: 'wb2_data',
      width: Ddr3Controller.wb2DataBits,
    );

    controller = Ddr3Controller(
      p,
      controllerClk: ddrClk,
      rstN: rstN,
      wbCyc: Const(0),
      wbStb: Const(0),
      wbWe: Const(0),
      wbAddr: Const(0, width: p.wbAddrBits),
      wbData: Const(0, width: p.wbDataBits),
      wbSel: Const(0, width: p.wbSelBits),
      aux: Const(0, width: Ddr3Controller.auxWidth),
      wb2Cyc: wb2Cyc,
      wb2Stb: Const(1),
      wb2We: cdc.output('m_we'),
      wb2Addr: wb2Addr,
      wb2Sel: wb2Sel,
      wb2Data: wb2Data,
      phyIserdesData: Const(0, width: p.dqBits * p.lanes * 8),
      phyIserdesDqs: Const(0, width: p.lanes * 8),
      phyIserdesBitslipReference: Const(0, width: p.lanes * 8),
      phyIdelayctrlRdy: Const(0),
      runtimeTrainable: true,
    );
    wb2Ack <= controller.output('o_wb2_ack');
    wb2DataOut <= controller.output('o_wb2_data');
    cdc.input('m_ack').srcConnection! <= wb2Ack;
    cdc.input('m_dat_r').srcConnection! <= wb2DataOut.zeroExtend(busDW);

    addOutput('t_ack') <= cdc.output('s_ack');
    addOutput('t_dat_r', width: busDW) <= cdc.output('s_dat_r');
  }
}

/// One 64-bit fabric write through the CDC; holds the request until ack.
Future<void> _fabricWrite(
  _Wb2FabricTop top,
  Logic clk,
  int adr,
  int data,
) async {
  top.input('t_cyc').inject(1);
  top.input('t_stb').inject(1);
  top.input('t_we').inject(1);
  top.input('t_adr').inject(adr);
  top.input('t_dat').inject(data);
  top.input('t_sel').inject(0xF);
  var guard = 0;
  while (top.output('t_ack').value.toInt() != 1) {
    await clk.nextPosedge;
    if (++guard > 400) break;
  }
  await clk.nextPosedge;
  top.input('t_cyc').inject(0);
  top.input('t_stb').inject(0);
  top.input('t_we').inject(0);
  await clk.nextPosedge;
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

  test('FABRIC 64-bit: byte 0x08 write lands on the ODELAY register and drives '
      'o_phy (address-granularity + data-narrow)', () async {
    final clk = SimpleClockGenerator(10).clk;
    final p = DdrParams.artyS7(ckPeriodPs: 3000);
    final top = _Wb2FabricTop(p);
    top.port('sys_clk').getsLogic(clk);
    top
        .port('ddr_clk')
        .getsLogic(clk); // synchronous CDC for a deterministic sim
    await top.build();

    top.input('rst_n').inject(0);
    top.input('t_cyc').inject(0);
    top.input('t_stb').inject(0);
    top.input('t_we').inject(0);
    top.input('t_adr').inject(0);
    top.input('t_dat').inject(0);
    top.input('t_sel').inject(0);
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    top.input('rst_n').inject(1);
    await clk.nextPosedge;

    // 64-bit ADR is byte>>3: ODELAY (byte 0x08) = adr 1, CTL (byte 0x20) = adr 4.
    await _fabricWrite(top, clk, 1, 0x7); // ODELAY = 7
    await _fabricWrite(top, clk, 4, 0x1); // CTL SET, lane 0
    await _fabricWrite(top, clk, 4, 0x2); // CTL LOAD/APPLY
    await clk.nextPosedge;

    // The byte offset routed to the ODELAY register (index 1), value from the
    // low 32 bits of the 64-bit word.
    expect(
      top.controller.rtOdelayRegs![0].value.toInt(),
      7,
      reason: 'byte 0x08 must hit ODELAY lane 0 through the 64-bit fabric',
    );
    expect(
      top.controller.output('o_phy_odelay_data_cntvaluein').value.toInt(),
      7,
      reason: 'o_phy must follow the runtime knob after APPLY',
    );

    // Read back ODELAY (byte 0x08) over the same fabric: low 32 bits = 7.
    top.input('t_cyc').inject(1);
    top.input('t_stb').inject(1);
    top.input('t_we').inject(0);
    top.input('t_adr').inject(1);
    var guard = 0;
    while (top.output('t_ack').value.toInt() != 1) {
      await clk.nextPosedge;
      if (++guard > 400) break;
    }
    final rd = top.output('t_dat_r').value.getRange(0, 32).toInt();
    top.input('t_cyc').inject(0);
    top.input('t_stb').inject(0);
    expect(rd, 7, reason: 'fabric read-back of ODELAY returns the applied tap');

    await Simulator.endSimulation();
  });
}
