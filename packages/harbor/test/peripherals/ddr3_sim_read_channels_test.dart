import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../bus/fabric/axi4_fabric_harness.dart'
    show ReadWant, checkReads, checkWrites;
import '../bus/port/memory_harness.dart';
import '../bus/port/port_harness.dart';

/// A Verilator style [HarborDdr3] with its memory beats on `mem_*` ports and
/// both read channels pulled up as `bus_*` and `bus_r1_*`.
class _Top extends BridgeModule {
  late final HarborDdr3 ddr;

  _Top() : super('Ddr3SimRcTop', name: 'top') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    ddr = addSubModule(
      HarborDdr3(
        config: const HarborDdrConfig.artyS7(),
        baseAddress: 0,
        clockHz: 100000000,
        busAddressWidth: 28,
        protocol: HarborFabricKind.axi4,
        idWidth: 2,
        readChannels: 2,
        outstanding: 4,
        simExternalMem: true,
        target: const HarborSimTarget(),
      ),
    );
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
    ddr.input('clk').srcConnection! <= input('clk');
    ddr.input('reset').srcConnection! <= input('reset');
    for (final p in ['mem_stb', 'mem_we', 'mem_adr', 'mem_dat_w', 'mem_sel']) {
      addOutput(p, width: ddr.output(p).width) <= ddr.output(p);
    }
    for (final p in ['mem_ack', 'mem_dat_r']) {
      ddr.input(p).srcConnection! <=
          addInput(
            p,
            Logic(width: ddr.input(p).width),
            width: ddr.input(p).width,
          );
    }
    pullUpInterface(ddr.interface('bus'));
    pullUpInterface(ddr.interface('bus_r1'));
  }
}

void main() {
  tearDown(Simulator.reset);

  test('the sim memory serves two read channels in turn', () async {
    final top = _Top();
    final s = Sim(top);
    final rng = Random(4);
    final wr = AxiManager(s, 'bus', rng, stall: 0.2);
    final rd = AxiManager(s, 'bus_r1', rng, stall: 0.2, readOnly: true);
    final mem = WordMemory(4);
    // The DramStore protocol: ack = stb & ~ack, data registered.
    var ack = 0;
    var rdata = 0;
    s.onRise(() {
      final stb = s.pre('mem_stb');
      if (stb == 0) {
        ack = 0;
        return;
      }
      final adr = s.pre('mem_adr');
      rdata = mem.read(adr & ~3);
      if (ack == 0 && s.pre('mem_we') == 1) {
        mem.write(adr & ~3, s.pre('mem_dat_w'), s.pre('mem_sel'));
      }
      ack = ack == 1 ? 0 : 1;
    });
    s.onFall(() {
      s.set('mem_ack', ack);
      s.set('mem_dat_r', rdata);
    });
    await s.start();
    Simulator.setMaxSimTime(10000000);

    final golden = WordMemory(4);
    final gen = BurstGen(rng, busBytes: 4, idWidth: 2, span: 0x800);
    for (var i = 0; i < 30; i++) {
      final w = gen.next(write: true);
      wr.write(w);
      final addrs = beatAddrs(w.addr, w.len, w.size, w.burst);
      for (var k = 0; k < w.beats; k++) {
        golden.write(addrs[k], w.data[k], w.strb[k]);
      }
    }
    await waitUntil(s, () => wr.bResp.length == 30, limit: 200000);
    for (var i = 0; i < 30; i++) {
      wr.read(gen.next(write: false));
      rd.read(gen.next(write: false));
    }
    await waitUntil(
      s,
      () =>
          wr.rBeats.length == wr.readBeatsExpected &&
          rd.rBeats.length == rd.readBeatsExpected,
      limit: 400000,
    );
    await s.stop();
    ReadWant want(Burst b) => (
      0,
      [
        for (final a in beatAddrs(b.addr, b.len, b.size, b.burst))
          golden.read(a),
      ],
    );
    expect([
      ...checkWrites('bus', wr.awOrder, wr.bResp, (_) => 0),
      ...checkReads('bus', wr.arOrder, wr.rBeats, want),
      ...checkReads('bus_r1', rd.arOrder, rd.rBeats, want),
    ], isEmpty);
    expect(top.ddr.busError.value.toInt(), 0);
  });
}
