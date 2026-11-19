import 'dart:async';
import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../peripherals/ddr3_fast_bench.dart'
    show Ddr3PhyWordModel, ax7203, ax7203CkPs, ax7203Params;

const _ddrPads = [
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
  'sdram_dq',
  'sdram_dqs',
  'sdram_dqs_n',
  'sdram_odt',
  'sdram_reset_n',
];

/// The KC705 names the one-rank DDR3 control pads with an index.
const _ddrExtra = {
  'sdram_ck': 'AG10 DIFF_SSTL15',
  'sdram_ck_n': 'AH10 DIFF_SSTL15',
  'sdram_cke': 'AF10 SSTL15',
  'sdram_cs_n': 'AC12 SSTL15',
  'sdram_odt': 'AD8 SSTL15',
};

const _ddrBase = 0x80000000;
const _uartBase = 0x10000000;

/// A master with a memory waist port `bus` that crosses to the fabric
/// clock, driven from `rq_*` and `wd_*` pins.
class _Cpu extends BridgeModule {
  _Cpu() : super('BusDomainCpu', name: 'cpu') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final fabricClock = BusSlavePort.fabricClockInputs(this, cross: true);
    final port = HarborMemoryMasterPort.create(
      module: this,
      name: 'bus',
      kind: HarborFabricKind.axi4,
      config: const HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32),
      clk: input('clk'),
      reset: input('reset'),
      fabricClock: fabricClock,
    );
    final w = port.waist;
    w.reqValid <= addInput('rq_valid', Logic());
    w.reqWrite <= addInput('rq_write', Logic());
    w.reqAddr <= addInput('rq_addr', Logic(width: 32), width: 32);
    w.reqId <= Const(0);
    w.reqLen <= Const(0, width: 8);
    w.reqSize <= Const(2, width: 3);
    w.reqBurst <= Const(HarborMemoryBurst.incr.value, width: 2);
    w.reqExclusive <= Const(0);
    w.wdataValid <= addInput('wd_valid', Logic());
    w.wdataData <= addInput('wd_data', Logic(width: 32), width: 32);
    w.wdataStrb <= Const(0xf, width: 4);
    w.wdataLast <= Const(1);
    w.rdataReady <= Const(1);
    w.wrespReady <= Const(1);
    addOutput('rq_ready') <= w.reqReady;
    addOutput('wd_ready') <= w.wdataReady;
    addOutput('rd_valid') <= w.rdataValid;
    addOutput('rd_data', width: 32) <= w.rdataData;
    addOutput('wr_valid') <= w.wrespValid;
  }

  void pullUp(HarborSoC soc) {
    for (final n in [...inputs.keys, ...outputs.keys]) {
      if (!RegExp('^(rq|wd|rd|wr)_').hasMatch(n)) continue;
      soc.pullUpPort(port(n), newPortName: 'cpu_$n');
    }
  }
}

const _coreClock = HarborClockConfig(
  name: 'core',
  rate: HarborFixedClockRate(50000000),
  sourceFrequency: 200000000,
  source: HarborClockSource.ddr3Core,
  isPrimary: true,
);

const _busClock = HarborClockConfig(
  name: 'bus',
  rate: HarborFixedClockRate(83333333),
  sourceFrequency: 200000000,
  source: HarborClockSource.ddr3Controller,
);

HarborUart _uart() => HarborUart(
  baseAddress: _uartBase,
  busAddressWidth: 32,
  busDataWidth: 32,
  regShift: 2,
  fabricKind: HarborFabricKind.axi4,
);

HarborSoC _kc705Soc(HarborFpgaTarget target) {
  final soc = HarborSoC(
    name: 'Kc705BusDomain',
    compatible: 'test,kc705-bus-domain',
    target: target,
    fabricKind: HarborFabricKind.axi4,
    fabricClockDomain: 'bus',
    clocks: const [_coreClock, _busClock],
    xilinxDdr3Tree: const XilinxDdr3TreeSpec.kc705(coreClkHz: 50000000),
  );
  final tree = soc.xilinxDdr3Clocks!;
  final cpu = soc.addMaster(
    _Cpu(),
    busInterfaceName: 'bus',
    memory: true,
    outstanding: 1,
    clockDomainName: 'core',
  );
  final shape = soc.memoryBusShape();
  final ddr = soc.addPeripheral(
    HarborDdr3(
      config: ax7203,
      baseAddress: _ddrBase,
      clockHz: tree.controllerMhz.round() * 1000000,
      busAddressWidth: 32,
      busDataWidth: 32,
      protocol: HarborFabricKind.axi4,
      idWidth: shape.idWidth,
      exclusive: shape.exclusive,
      sameClock: true,
      target: target,
      ckPeriodPs: (1000000 / tree.ddrCkMhz).round(),
    ),
  );
  ddr.input('ddr_ck_fast').srcConnection! <= tree.ddrCk;
  ddr.input('ddr_ck90_fast').srcConnection! <= tree.ddrCk90;
  ddr.input('ddr_ck_dqs_fast').srcConnection! <= tree.ddrCkDqs;
  ddr.input('ddr_idelay_ref').srcConnection! <= tree.idelayRef;
  for (final pad in _ddrPads) {
    soc.exposePin(ddr, pad, externalName: pad);
  }
  final uart = soc.addPeripheral(_uart());
  soc.exposePin(uart, 'tx', externalName: 'uart_tx');
  soc.exposePin(uart, 'rx', externalName: 'uart_rx');
  for (final p in cpu.inputs.keys) {
    if (RegExp('^(rq|wd)_').hasMatch(p)) {
      cpu.input(p).srcConnection! <= Const(0, width: cpu.input(p).width);
    }
  }
  return soc;
}

/// The same shape on a simulation target. The DDR3 controller runs its fast
/// simulation, and the bus clock comes in on a pin, as the sim target has no
/// clock tree.
class _Sim {
  final HarborSoC soc;
  final HarborDdr3 ddr;

  _Sim._(this.soc, this.ddr);

  factory _Sim() {
    final soc = HarborSoC(
      name: 'BusDomainSim',
      compatible: 'test,bus-domain-sim',
      target: const HarborSimTarget(frequency: 50000000),
      fabricKind: HarborFabricKind.axi4,
      fabricClockDomain: 'bus',
      clocks: [
        HarborClockConfig.fixed(
          name: 'core',
          frequency: 50000000,
          sourceFrequency: 50000000,
          isPrimary: true,
        ),
      ],
    );
    final busNet = soc.addInput('bus_net', Logic());
    soc.addClockDomainFromNet(_busClock, busNet, locked: Const(1));
    final cpu = soc.addMaster(
      _Cpu(),
      busInterfaceName: 'bus',
      memory: true,
      outstanding: 1,
      clockDomainName: 'core',
    );
    final shape = soc.memoryBusShape();
    final ddr = soc.addPeripheral(
      HarborDdr3(
        config: ax7203,
        baseAddress: _ddrBase,
        clockHz: 83333333,
        busAddressWidth: 32,
        busDataWidth: 32,
        protocol: HarborFabricKind.axi4,
        idWidth: shape.idWidth,
        exclusive: shape.exclusive,
        fastSim: true,
        sameClock: true,
        target: const HarborFpgaTarget.artix7(
          device: 'xc7a200t',
          package: 'fbg484',
        ),
        ckPeriodPs: ax7203CkPs,
      ),
    );
    for (final p in [
      'ddr_ck_fast',
      'ddr_ck90_fast',
      'ddr_ck_dqs_fast',
      'ddr_idelay_ref',
    ]) {
      ddr.input(p).srcConnection! <= Const(0);
    }
    for (final p in ['phy_cmd', 'phy_data', 'phy_dm', 'phy_iserdes_data']) {
      soc.pullUpPort(ddr.port(p), newPortName: p);
    }
    final uart = soc.addPeripheral(_uart());
    uart.input('rx').srcConnection! <= Const(1);
    cpu.pullUp(soc);
    return _Sim._(soc, ddr);
  }
}

final _clockNet = RegExp(r'create_clock -period \S+ \[get_nets (\S+)\]');

void main() {
  tearDown(() async => Simulator.reset());

  group('the KC705 SoC', () {
    final board = HarborBoard.get('kc705');
    late Directory dir;
    late HarborSoC soc;
    late String xdcText;
    late String rtl;

    setUpAll(() async {
      dir = Directory.systemTemp.createTempSync('harbor_kc705_bus_domain_');
      final target = board.fpgaTarget(
        useHimbaechel: true,
        extraPins: _ddrExtra,
      );
      soc = _kc705Soc(target);
      await soc.generateAll(dir);
      xdcText = File('${dir.path}/Kc705BusDomain.xdc').readAsStringSync();
      rtl = Directory('${dir.path}/rtl')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.sv'))
          .map((f) => f.readAsStringSync())
          .join('\n');
    });

    tearDownAll(() async {
      dir.deleteSync(recursive: true);
      await Simulator.reset();
    });

    String moduleBody(String name) {
      final m = RegExp(
        'module $name\\b.*?\\nendmodule',
        dotAll: true,
      ).firstMatch(rtl);
      expect(m, isNotNull, reason: name);
      return m!.group(0)!;
    }

    test('the DDR3 controller has no crossing', () {
      final ddrDef = soc.peripherals
          .firstWhere((p) => p is HarborDdr3)
          .definitionName;
      final body = moduleBody(ddrDef);
      for (final name in [
        'HarborMemoryWaistCdc',
        'status_sync',
        'cal_state_cdc',
      ]) {
        expect(body, isNot(contains(name)), reason: name);
      }
      expect(body, isNot(contains('ddr_clk')));
    });

    test('the CPU master has its crossing', () {
      final body = moduleBody('BusDomainCpu');
      expect(body, contains('HarborMemoryWaistCdc'));
      expect(body, contains(BusSlavePort.fabricClkPort));
    });

    test('the UART clock-frequency is the bus rate', () {
      expect(
        soc.generateDts(),
        matches(RegExp(r'@10000000 \{[^}]*clock-frequency = <83333333>')),
      );
    });

    // The XDC names only the board clock. nextpnr derives the ddr_clk rate
    // from the DDR3 MMCM settings, so the fabric on ddr_clk is timed only
    // while the board clock is constrained and the ddr_clk net stays.
    test('the board clock is constrained and the ddr_clk net is kept', () {
      expect(xdcText, matches(RegExp(r'create_clock .*sysclk')));
      expect(rtl, contains('ddr_clk'));
    });

    test('no clock net is constrained twice, the ddr_clk net at most once', () {
      final nets = _clockNet.allMatches(xdcText).map((m) => m.group(1)!);
      expect(nets.where((n) => n.contains('ddr_clk')).length, lessThan(2));
      expect(nets.toSet(), hasLength(nets.length), reason: '$nets');
    });
  });

  test('the CPU writes and reads DRAM and a UART register in sim', () async {
    final sim = _Sim();
    final soc = sim.soc;
    final coreClk = SimpleClockGenerator(20).clk;
    final busClk = SimpleClockGenerator(12).clk;
    final reset = Logic(name: 'reset')..inject(1);
    soc.input('clk').srcConnection! <= coreClk;
    soc.input('bus_net').srcConnection! <= busClk;
    soc.input('reset').srcConnection! <= reset;
    final pins = {
      for (final p in [
        'rq_valid',
        'rq_write',
        'rq_addr',
        'wd_valid',
        'wd_data',
      ])
        p: Logic(name: 'drv_$p', width: soc.input('cpu_$p').width),
    };
    for (final e in pins.entries) {
      soc.input('cpu_${e.key}').srcConnection! <= e.value;
      e.value.inject(0);
    }
    soc.input('phy_iserdes_data').srcConnection!.put(0);
    soc.buildFabric();
    await soc.build();
    final model = Ddr3PhyWordModel(
      ax7203Params,
      clk: busClk,
      cmd: soc.output('phy_cmd'),
      data: soc.output('phy_data'),
      dm: soc.output('phy_dm'),
      iserdes: soc.input('phy_iserdes_data').srcConnection!,
    );
    Simulator.setMaxSimTime(1 << 50);
    unawaited(Simulator.run());
    for (var i = 0; i < 8; i++) {
      await coreClk.nextPosedge;
    }
    reset.inject(0);
    final ctrl = sim.ddr.controller!;
    for (var i = 0; ; i++) {
      await busClk.nextPosedge;
      final v = ctrl.debug1.value.getRange(0, 7);
      // DONE_CALIBRATE and reset_done.
      if (v.isValid && v.toInt() == 23 + 64) break;
      if (i > 200000) throw StateError('the controller never opened its bus');
    }

    bool high(String n) {
      final v = soc.output('cpu_$n').previousValue!;
      return v.isValid && v.toBool();
    }

    Future<void> waitHigh(String n) async {
      for (var i = 0; i < 2000; i++) {
        await coreClk.nextPosedge;
        if (high(n)) return;
      }
      throw StateError('$n never rose');
    }

    Future<void> send(String valid, String ready) async {
      await coreClk.nextNegedge;
      pins[valid]!.inject(1);
      await waitHigh(ready);
      await coreClk.nextNegedge;
      pins[valid]!.inject(0);
    }

    Future<void> write(int addr, int data) async {
      await coreClk.nextNegedge;
      pins['rq_write']!.inject(1);
      pins['rq_addr']!.inject(addr);
      pins['wd_data']!.inject(data);
      await send('rq_valid', 'rq_ready');
      await send('wd_valid', 'wd_ready');
      await waitHigh('wr_valid');
    }

    Future<int> read(int addr) async {
      await coreClk.nextNegedge;
      pins['rq_write']!.inject(0);
      pins['rq_addr']!.inject(addr);
      await send('rq_valid', 'rq_ready');
      await waitHigh('rd_valid');
      return soc.output('cpu_rd_data').previousValue!.toInt();
    }

    int word(int i) => (i * 0x9e3779b1 + 0x5a5a1234) & 0xffffffff;
    const words = 64;
    for (var i = 0; i < words; i++) {
      await write(_ddrBase + 0x1000 + 4 * i, word(i));
    }
    final bad = <String>[];
    for (var i = 0; i < words; i++) {
      final got = await read(_ddrBase + 0x1000 + 4 * i);
      if (got != word(i)) bad.add('word $i: $got, want ${word(i)}');
    }
    expect(bad, isEmpty);

    // The line status register reads transmitter empty after reset.
    final lsr = await read(_uartBase + 5 * 4);
    expect(lsr & 0x60, 0x60);
    await Simulator.endSimulation();
    expect(model.errors, isEmpty);
  });
}
