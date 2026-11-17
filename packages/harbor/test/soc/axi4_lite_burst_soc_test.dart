// A burst master reads the XIP window of the SPI flash controller through an
// AXI4 fabric. The controller has an AXI4-Lite port, so the fabric runs each
// burst as single beats, as for a cache line refill.

import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../bus/port/cdc_harness.dart' show isolated, must;
import '../bus/port/memory_harness.dart';
import '../bus/port/port_harness.dart';
import '../util/spi_nor_model.dart';

const _xip = 0x20000000;

class _Master extends BridgeModule {
  _Master(int dw) : super('LiteBurstMaster$dw', name: 'burster') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final mem = HarborMemoryMasterPort.create(
      module: this,
      name: 'dataBus',
      kind: HarborFabricKind.axi4,
      config: HarborMemoryWaistConfig(
        addressWidth: 32,
        dataWidth: dw,
        idWidth: 2,
        outstanding: 2,
      ),
      clk: input('clk'),
      reset: input('reset'),
    );
    exposeWaist(this, mem.waist, 'mem', PairRole.consumer);
  }

  void pullUp(HarborSoC soc) {
    for (final n in [...inputs.keys, ...outputs.keys]) {
      if (n.startsWith('mem_')) soc.pullUpPort(port(n), newPortName: 'cpu_$n');
    }
  }
}

int _byte(int a) => (a * 7 + 3) & 0xff;

int _word(int a, int bytes) => [
  for (var i = bytes - 1; i >= 0; i--) _byte((a & ~(bytes - 1)) + i),
].fold(0, (v, b) => v << 8 | b);

void main() {
  for (final dw in [32, 64]) {
    test(
      '$dw-bit line refill bursts read the SPI flash XIP window',
      () => isolated(() => _run(dw)),
    );
  }
}

Future<void> _run(int dw) async {
  {
    final soc = HarborSoC(
      name: 'lite_burst',
      compatible: 'test,lite-burst',
      fabricKind: HarborFabricKind.axi4,
      target: const HarborSimTarget(frequency: 50000000),
    );
    final cpu = soc.addMaster(_Master(dw), memory: true);
    final flash = soc.addPeripheral(
      HarborSpiFlashController(
        config: HarborSpiFlashConfig(
          size: 1024 * 1024,
          mode: HarborSpiFlashMode.standard,
          partitions: const [
            HarborFlashPartition(label: 'data', offset: 0, size: 0x10000),
          ],
        ),
        baseAddress: _xip,
        busAddressWidth: 32,
        busDataWidth: dw,
        fabricKind: HarborFabricKind.axi4,
        clockHz: 50000000,
      ),
    );
    flash.input('wr_req').srcConnection! <= Const(0);
    flash.input('wr_op').srcConnection! <= Const(0);
    flash.input('wr_addr').srcConnection! <= Const(0, width: 24);
    flash.input('wr_len').srcConnection! <= Const(0, width: 9);
    flash.input('wr_data').srcConnection! <= Const(0, width: 8);
    soc
      ..exposePin(flash, 'spi_clk', externalName: 'spi_clk')
      ..exposePin(flash, 'spi_cs_n', externalName: 'spi_cs_n')
      ..exposePin(flash, 'spi_mosi', externalName: 'spi_mosi')
      ..exposePin(flash, 'spi_miso', externalName: 'spi_miso');
    cpu.pullUp(soc);
    soc.buildFabric();

    final bytes = dw ~/ 8;
    final model = SpiNorModel();
    for (final base in [0, 0x51c00]) {
      for (var a = base; a < base + 0x400; a++) {
        model.storage[a] = _byte(a);
      }
    }
    final sim = Sim(soc);
    final errors = <String>[];
    final req = WaistRequester(sim, 'cpu_mem', Random(5), errors: errors);
    await sim.start();
    Simulator.setMaxSimTime(40000000);
    final pins = model.attach(
      clk: sim.clk,
      csN: soc.output('spi_cs_n'),
      spiClk: soc.output('spi_clk'),
      mosi: soc.output('spi_mosi'),
      miso: soc.input('spi_miso').srcConnection!,
    );
    await sim.cycles(60);

    Burst rd(int id, int addr, int len, int burst) => Burst(
      id: id,
      write: false,
      addr: addr,
      len: len,
      size: bytes.bitLength - 1,
      burst: burst,
    );
    final line = 256 ~/ dw - 1;
    final reads = [
      rd(0, _xip + 0x40, line, 1),
      rd(1, _xip + 0x80 + 2 * bytes, line, 2),
      rd(0, _xip + 0xa0, 0, 1),
      rd(1, _xip + 0xc8, 3, 2),
      rd(0, _xip + 0x100, line, 1),
      rd(1, _xip + 0x51fe0, line, 1),
      rd(0, _xip + 0x51fc8, line, 2),
    ];
    for (final x in reads) {
      req.send(x);
    }
    await waitUntil(sim, () => req.done, limit: 400000);
    await pins.stop();
    await sim.stop();
    must(errors, isEmpty);
    for (var i = 0; i < reads.length; i++) {
      final x = reads[i];
      final beats = req.readResp[i];
      must(beats.length, x.beats, reason: '$x');
      must(beats.map((b) => b.$3), everyElement(0), reason: '$x');
      must(beats.map((b) => b.$2).toList(), [
        for (final a in beatAddrs(x.addr, x.len, x.size, x.burst))
          _word(a - _xip, bytes),
      ], reason: '$x');
      must(beats.map((b) => b.$4).toList(), [
        for (var k = 0; k < x.beats; k++) k == x.len ? 1 : 0,
      ]);
    }
  }
}
