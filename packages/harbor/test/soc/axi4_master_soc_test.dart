// A HarborSoC built only from native bus masters (a register CPU, a line
// fetcher and a DMA controller) against an sdram with its pin-level timing
// model and a uart, on both the AXI4 and the TileLink fabric. A third test
// checks a pipelined AXI4 master against an SRAM.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../peripherals/sdram_memory_port_bench.dart' show sdramBenchConfig;
import '../peripherals/sdram_phy_ecp5_harness.dart' show sdramPhyCaptureOk;
import '../peripherals/sdram_pin_model.dart';
import '../util/reg_bus.dart';

const _sdram = 0x40000000;
const _uart = 0x10000000;
const _dma = 0x30000000;
const _src = _sdram + 0x1000;
const _dst = _sdram + 0x2000;
const _n = 32;
const _pipeSram = 0x80000000;

const _sdramPads = [
  'sdram_clk',
  'sdram_cke',
  'sdram_cs_n',
  'sdram_ras_n',
  'sdram_cas_n',
  'sdram_we_n',
  'sdram_ba',
  'sdram_addr',
  'sdram_dqm',
  'sdram_dq',
];

/// A register master whose native port pins are plain `p_<PORT>` ports.
class _Cpu extends BridgeModule {
  _Cpu(HarborFabricKind kind)
    : super('MasterSdramCpu_${kind.name}', name: 'cpu') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final PairInterface intf = switch (kind) {
      HarborFabricKind.wishbone => WishboneInterface(
        const WishboneConfig(addressWidth: 32, dataWidth: 32, useErr: true),
      ),
      HarborFabricKind.axi4 => Axi4LiteInterface(
        addressWidth: 32,
        dataWidth: 32,
      ),
      HarborFabricKind.tilelink => TileLinkInterface(
        const TileLinkConfig(addressWidth: 32, dataWidth: 32),
      ),
    };
    final i = addInterface(
      intf,
      name: 'dataBus',
      role: PairRole.provider,
    ).internalInterface!;
    for (final e in i.getPorts([PairDirection.fromProvider]).entries) {
      final w = e.value.width;
      e.value <= addInput('p_${e.key}', Logic(width: w), width: w);
    }
    for (final e in i.getPorts([PairDirection.fromConsumer]).entries) {
      addOutput('p_${e.key}', width: e.value.width) <= e.value;
    }
  }

  void pullUp(HarborSoC soc) {
    for (final n in [...inputs.keys, ...outputs.keys]) {
      if (!n.startsWith('p_')) continue;
      soc.pullUpPort(port(n), newPortName: 'cpu_${n.substring(2)}');
    }
  }
}

/// A [HarborLineFetcher] behind a memory master port named `bus`.
class _Fetcher extends BridgeModule {
  _Fetcher(HarborFabricKind kind, int outstanding)
    : super('MasterSdramFetcher_${kind.name}_n$outstanding', name: 'fetcher') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final port = HarborMemoryMasterPort.create(
      module: this,
      name: 'bus',
      kind: kind,
      config: HarborMemoryWaistConfig(
        addressWidth: 32,
        dataWidth: 32,
        outstanding: outstanding,
      ),
      clk: input('clk'),
      reset: input('reset'),
    );
    final f = HarborLineFetcher(
      clk: input('clk'),
      reset: port.reset,
      fetchStart: addInput('f_start', Logic()),
      fetchAddr: addInput('f_addr', Logic(width: 32), width: 32),
      words: addInput('f_words', Logic(width: 16), width: 16),
      fillSel: Const(0),
      waist: port.waist,
      maxWords: 64,
      burstWords: 4,
    );
    addOutput('f_wr_en') <= f.wrEn;
    addOutput('f_wr_idx', width: f.wrIdx.width) <= f.wrIdx;
    addOutput('f_wr_data', width: 32) <= f.wrData;
    addOutput('f_done') <= f.done;
  }
}

HarborSoC _soc(HarborFabricKind kind) => HarborSoC(
  name: 'sdram_masters_${kind.name}',
  compatible: 'test,sdram-masters',
  fabricKind: kind,
  target: const HarborSimTarget(frequency: 50000000),
);

int _word(int i) => (0x9e3779b9 * (i + 1)) & 0xffffffff;

/// Writes byte [offset] of the uart's register window, on a 32-bit bus:
/// the byte goes in its lane of the word it packs into.
Future<void> _uartWrite(RegBus bus, int base, int offset, int value) async {
  const lanes = 4;
  final lane = offset % lanes;
  await bus.write(base + offset - lane, value << (8 * lane), sel: 1 << lane);
}

/// Reads byte [offset] of the uart's register window back out of its lane.
Future<int> _uartRead(RegBus bus, int base, int offset) async {
  const lanes = 4;
  final lane = offset % lanes;
  final word = await bus.read(base + offset - lane);
  return (word >> (8 * lane)) & 0xFF;
}

/// Wires the fabric and sdram clocks, builds [soc], attaches the sdram pin
/// model to its pads, and runs past reset and the sdram's power-up. Returns
/// the pin model so the test can check it at the end.
Future<SdramPinModel> _bootSdram(
  HarborSoC soc,
  HarborSdram sdram,
  Logic fabricClk,
  Logic memClk,
  int memPeriodPs,
  List<void Function()> idle,
) async {
  final reset = Logic(name: 'reset')..inject(1);
  final memReset = Logic(name: 'mem_reset')..inject(1);
  soc.input('clk').srcConnection! <= fabricClk;
  soc.input('reset').srcConnection! <= reset;
  soc.input('mem_clk').srcConnection! <= memClk;
  soc.input('mem_reset').srcConnection! <= memReset;
  await soc.build();
  for (final f in idle) {
    f();
  }

  final phy = sdram.subModules.whereType<SdramPhyEcp5>().single;
  final bbs = {for (final m in phy.subModules.whereType<Ecp5Bb>()) m.name: m};
  final dqBbs = [for (var i = 0; i < 16; i++) bbs['dq_bb_$i']!];
  const fpgaToSdramNs = 4.6;
  if (!sdramPhyCaptureOk(
    periodPs: memPeriodPs,
    tAcNs: sdram.cycles.casLatency == 3 ? 5.0 : 6.0,
    fpgaToSdramNs: fpgaToSdramNs,
    phy: const HarborSdramPhyConfig(),
  )) {
    throw ArgumentError('the capture window misses at $memPeriodPs ps');
  }
  final model = SdramPinModel(
    clk: soc.output('sdram_clk'),
    cke: soc.output('sdram_cke'),
    csN: soc.output('sdram_cs_n'),
    rasN: soc.output('sdram_ras_n'),
    casN: soc.output('sdram_cas_n'),
    weN: soc.output('sdram_we_n'),
    ba: soc.output('sdram_ba'),
    addr: soc.output('sdram_addr'),
    dqm: soc.output('sdram_dqm'),
    dq: soc.inOutSource('sdram_dq') as LogicNet,
    rules: const SdramModelRules.as4c16m16sb6().copyWith(powerUpNs: 2000),
    fpgaToSdramNs: fpgaToSdramNs,
    fpgaDqOe: [for (final bb in dqBbs) ~bb.input('T')].rswizzle(),
    fpgaDqOut: [for (final bb in dqBbs) bb.input('I')].rswizzle(),
    refreshPolicy: SdramRefreshPolicy(
      maxPostponed: sdram.cycles.maxPostponed,
      maxPulledIn: sdram.cycles.maxPulledIn,
      periodNs: sdram.cycles.refi * memPeriodPs / 1000,
      maxLatencyNs: 256 * memPeriodPs / 1000,
      initRefreshes: sdram.cycles.initRefreshes,
    ),
  );

  Simulator.setMaxSimTime(1 << 40);
  unawaited(Simulator.run());
  for (var i = 0; i < 8; i++) {
    await memClk.nextPosedge;
  }
  memReset.inject(0);
  await fabricClk.nextNegedge;
  reset.inject(0);
  for (var i = 0; i < 4; i++) {
    await fabricClk.nextNegedge;
  }
  var guard = 0;
  while (sdram.output('init_done').value != LogicValue.one) {
    if (guard++ > 20000) {
      throw StateError('sdram init_done never went high');
    }
    await memClk.nextPosedge;
  }
  return model;
}

void main() {
  tearDown(() async => Simulator.reset());

  for (final kind in [HarborFabricKind.axi4, HarborFabricKind.tilelink]) {
    test('${kind.name}: a dma copy, a line fetcher and uart writes run '
        'together against an sdram', () async {
      final soc = _soc(kind);
      final cpu = soc.addMaster(_Cpu(kind));

      final dma = HarborDmaController(
        baseAddress: _dma,
        channels: 1,
        busAddressWidth: 32,
        fabricKind: kind,
      );
      soc.addPeripheral(dma);
      soc.addMaster(dma, busInterfaceName: 'dma', memory: true, outstanding: 1);

      final fetcher = _Fetcher(kind, 4);
      soc.addMaster(
        fetcher,
        busInterfaceName: 'bus',
        memory: true,
        outstanding: 4,
      );

      final shape = soc.memoryBusShape();

      final uart = HarborUart(
        baseAddress: _uart,
        busAddressWidth: 32,
        busDataWidth: 32,
        fabricKind: kind,
      );
      uart.port('rx').getsLogic(Const(1));
      soc.addPeripheral(uart);

      final sdram = HarborSdram(
        config: sdramBenchConfig(),
        baseAddress: _sdram,
        clockHz: 125000000,
        busAddressWidth: 32,
        protocol: kind,
        idWidth: shape.idWidth,
        exclusive: shape.exclusive,
        target: const HarborFpgaTarget.ecp5(
          device: 'LFE5U-85F',
          package: 'CABGA381',
        ),
      );
      soc.addPeripheral(sdram);

      cpu.pullUp(soc);
      for (final n in ['f_start', 'f_addr', 'f_words']) {
        soc.pullUpPort(fetcher.port(n), newPortName: n);
      }
      for (final n in ['f_wr_en', 'f_wr_idx', 'f_wr_data', 'f_done']) {
        soc.pullUpPort(fetcher.port(n), newPortName: n);
      }
      for (final p in _sdramPads) {
        soc.pullUpPort(sdram.port(p), newPortName: p);
      }
      soc.pullUpPort(sdram.port('mem_clk'), newPortName: 'mem_clk');
      soc.pullUpPort(sdram.port('mem_reset'), newPortName: 'mem_reset');

      soc.buildFabric();
      final busError = soc.exposeBusError();

      final fetchStart = Logic(name: 'drv_f_start');
      final fetchAddr = Logic(name: 'drv_f_addr', width: 32);
      final fetchWords = Logic(name: 'drv_f_words', width: 16);
      soc.input('f_start').srcConnection! <= fetchStart;
      soc.input('f_addr').srcConnection! <= fetchAddr;
      soc.input('f_words').srcConnection! <= fetchWords;

      final fabricClk = SimpleClockGenerator(20000).clk;
      final memClk = SimpleClockGenerator(8000).clk;
      final bus = RegBus.attach(soc, fabricClk, name: 'cpu', kind: kind);

      final model = await _bootSdram(soc, sdram, fabricClk, memClk, 8000, [
        bus.idle,
        () {
          fetchStart.inject(0);
          fetchAddr.inject(0);
          fetchWords.inject(0);
        },
      ]);

      // The CPU fills the source region with a known pattern.
      for (var i = 0; i < _n; i++) {
        await bus.write(_src + 4 * i, _word(i));
      }

      // Start the DMA copying the source region to the destination.
      await bus.write(_dma + 0x00, 1);
      await bus.write(_dma + 0x50, _src);
      await bus.write(_dma + 0x58, _dst);
      await bus.write(_dma + 0x60, _n * 4);
      await bus.write(_dma + 0x40, 1);

      // While the DMA runs, fetch the source region too.
      final got = <int, int>{};
      var fetchDone = false;
      fabricClk.posedge.listen((_) {
        if (soc.output('f_wr_en').previousValue?.toBool() ?? false) {
          got[soc.output('f_wr_idx').previousValue!.toInt()] = soc
              .output('f_wr_data')
              .previousValue!
              .toInt();
        }
        if (soc.output('f_done').previousValue?.toBool() ?? false) {
          fetchDone = true;
        }
      });
      await fabricClk.nextNegedge;
      fetchAddr.inject(_src);
      fetchWords.inject(_n);
      fetchStart.inject(1);
      await fabricClk.nextNegedge;
      fetchStart.inject(0);

      // And write a couple of bytes out through the uart: 8N1, DLAB
      // clear, then THR twice.
      await _uartWrite(bus, _uart, 3, 0x03);
      await _uartWrite(bus, _uart, 0, 0x55);
      var txLow = false;
      fabricClk.posedge.listen((_) {
        if (uart.tx.value.isValid && uart.tx.value.toInt() == 0) {
          txLow = true;
        }
      });
      await _uartWrite(bus, _uart, 0, 0xA5);

      // Poll the DMA with idle cycles between reads, so a master that
      // kept its grant back to back would not starve it.
      var status = 0;
      for (var i = 0; i < 1000 && status & 0x2 == 0; i++) {
        for (var c = 0; c < 20; c++) {
          await fabricClk.nextPosedge;
        }
        status = await bus.read(_dma + 0x48);
      }
      expect(status & 0x7, 0x2, reason: 'complete, not busy, no error');

      for (var i = 0; i < 2000 && !fetchDone; i++) {
        await fabricClk.nextPosedge;
      }
      expect(fetchDone, isTrue, reason: 'line fetcher finished');
      expect(got, {for (var i = 0; i < _n; i++) i: _word(i)});

      for (var i = 0; i < _n; i++) {
        expect(await bus.read(_dst + 4 * i), _word(i), reason: 'word $i');
      }

      expect(txLow, isTrue, reason: 'tx went low for a start bit');
      final lsr = await _uartRead(bus, _uart, 5);
      expect(lsr & 0x60, 0x60, reason: 'thre and temt once tx drains');

      expect(busError.value.toInt(), 0);
      model.finish();
      expect(model.errors, isEmpty);
      await Simulator.endSimulation();
    });
  }

  // On AXI4, pipeline adds no register stage.
  test(
    'axi4: a pipelined master builds and runs a few writes and reads',
    () async {
      final soc = HarborSoC(
        name: 'pipe_axi4',
        compatible: 'test,pipe-axi4',
        fabricKind: HarborFabricKind.axi4,
        target: const HarborSimTarget(frequency: 50000000),
      );
      final cpu = soc.addMaster(_Cpu(HarborFabricKind.axi4), pipeline: true);
      soc.addPeripheral(
        HarborSram(
          baseAddress: _pipeSram,
          size: 4096,
          busAddressWidth: 32,
          protocol: HarborFabricKind.axi4,
        ),
      );
      cpu.pullUp(soc);
      soc.buildFabric();
      final busError = soc.exposeBusError();

      final clk = SimpleClockGenerator(10).clk;
      final bus = RegBus.attach(
        soc,
        clk,
        name: 'cpu',
        kind: HarborFabricKind.axi4,
      );
      final reset = Logic(name: 'reset')..inject(1);
      soc.input('clk').srcConnection! <= clk;
      soc.input('reset').srcConnection! <= reset;
      await soc.build();
      bus.idle();
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      for (var i = 0; i < 8; i++) {
        await clk.nextPosedge;
      }
      reset.inject(0);
      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
      }

      for (var i = 0; i < 4; i++) {
        await bus.write(_pipeSram + 4 * i, _word(i));
      }
      for (var i = 0; i < 4; i++) {
        expect(await bus.read(_pipeSram + 4 * i), _word(i));
      }
      expect(busError.value.toInt(), 0);
      await Simulator.endSimulation();
    },
  );
}
