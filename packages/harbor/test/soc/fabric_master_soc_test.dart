// Bus masters on a HarborSoC of each fabric kind: the DMA controller, the
// debug module system bus access and a line fetcher, each against an SRAM.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

const _sram = 0x80000000;
const _dma = 0x30000000;
const _dm = 0x30001000;

/// A register master whose native port pins are plain `p_<PORT>` ports.
class _Cpu extends BridgeModule {
  _Cpu(HarborFabricKind kind)
    : super('MasterSocCpu_${kind.name}', name: 'cpu') {
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
    : super('MasterSocFetcher_${kind.name}_n$outstanding', name: 'fetcher') {
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
  name: 'masters_${kind.name}',
  compatible: 'test,masters',
  fabricKind: kind,
  target: const HarborSimTarget(frequency: 50000000),
);

HarborSram _ram(HarborFabricKind kind) => HarborSram(
  baseAddress: _sram,
  size: 4096,
  busAddressWidth: 32,
  protocol: kind,
);

/// Wires clk and reset, builds, and runs [soc] out of reset.
Future<void> _start(
  HarborSoC soc,
  Logic clk,
  List<void Function()> idle,
) async {
  final reset = Logic(name: 'reset')..inject(1);
  soc.input('clk').srcConnection! <= clk;
  soc.input('reset').srcConnection! <= reset;
  await soc.build();
  for (final f in idle) {
    f();
  }
  Simulator.setMaxSimTime(20000000);
  unawaited(Simulator.run());
  for (var i = 0; i < 8; i++) {
    await clk.nextPosedge;
  }
  reset.inject(0);
  for (var i = 0; i < 4; i++) {
    await clk.nextPosedge;
  }
}

int _word(int i) => (0x9e3779b9 * (i + 1)) & 0xffffffff;

void main() {
  tearDown(() async => Simulator.reset());

  for (final kind in HarborFabricKind.values) {
    test('${kind.name}: the DMA controller copies SRAM to SRAM', () async {
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
      soc.addPeripheral(_ram(kind));
      cpu.pullUp(soc);
      soc.buildFabric();
      final busError = soc.exposeBusError();
      final clk = SimpleClockGenerator(10).clk;
      final bus = RegBus.attach(soc, clk, name: 'cpu', kind: kind);
      await _start(soc, clk, [bus.idle]);

      for (var i = 0; i < 8; i++) {
        await bus.write(_sram + 4 * i, _word(i));
      }
      await bus.write(_dma + 0x00, 1);
      await bus.write(_dma + 0x50, _sram);
      await bus.write(_dma + 0x58, _sram + 0x200);
      await bus.write(_dma + 0x60, 32);
      await bus.write(_dma + 0x40, 1);
      // Poll with idle cycles between reads. A Wishbone master that keeps
      // CYC high back to back holds the grant, which would starve the DMA.
      var status = 0;
      for (var i = 0; i < 400 && status & 0x2 == 0; i++) {
        for (var c = 0; c < 20; c++) {
          await clk.nextPosedge;
        }
        status = await bus.read(_dma + 0x48);
      }
      expect(status & 0x7, 0x2, reason: 'complete, not busy, no error');
      for (var i = 0; i < 8; i++) {
        expect(await bus.read(_sram + 0x200 + 4 * i), _word(i));
      }
      expect(busError.value.toInt(), 0);
      await Simulator.endSimulation();
    });

    test('${kind.name}: the debug module reads and writes over sba', () async {
      final soc = _soc(kind);
      final cpu = soc.addMaster(_Cpu(kind));
      final dm = HarborDebugModule(baseAddress: _dm, fabricKind: kind);
      soc.addPeripheral(dm);
      soc.addMaster(dm, busInterfaceName: 'sba', memory: false, outstanding: 1);
      soc.addPeripheral(_ram(kind));
      cpu.pullUp(soc);
      final dmi = <String, Logic>{};
      for (final n in ['dmi_addr', 'dmi_data_in', 'dmi_op', 'dmi_valid']) {
        final p = dm.input(n);
        dmi[n] = Logic(name: 'drv_$n', width: p.width);
        soc.pullUpPort(dm.port(n), newPortName: n);
      }
      soc.pullUpPort(dm.port('dmi_data_out'), newPortName: 'dmi_data_out');
      for (final n in ['halted', 'running', 'unavail', 'reg_ready']) {
        dm.input('hart0_$n').srcConnection! <= Const(0);
      }
      dm.input('hart0_reg_rdata').srcConnection! <= Const(0, width: 64);
      soc.buildFabric();
      for (final e in dmi.entries) {
        soc.input(e.key).srcConnection! <= e.value;
      }
      final clk = SimpleClockGenerator(10).clk;
      final bus = RegBus.attach(soc, clk, name: 'cpu', kind: kind);
      await _start(soc, clk, [
        bus.idle,
        () {
          for (final l in dmi.values) {
            l.inject(0);
          }
        },
      ]);

      Future<void> pulse(int op, int addr, int data) async {
        await clk.nextNegedge;
        dmi['dmi_addr']!.inject(addr);
        dmi['dmi_data_in']!.inject(data);
        dmi['dmi_op']!.inject(op);
        dmi['dmi_valid']!.inject(1);
        await clk.nextPosedge;
        await clk.nextNegedge;
        dmi['dmi_valid']!.inject(0);
        dmi['dmi_op']!.inject(0);
      }

      Future<int> read(int addr) async {
        await pulse(1, addr, 0);
        return soc.output('dmi_data_out').value.toInt();
      }

      Future<void> idle() async {
        for (var i = 0; i < 400; i++) {
          if ((await read(0x38) >> 21) & 1 == 0) return;
        }
        throw StateError('sbbusy stuck');
      }

      // A 32-bit write through sba, read back by the CPU.
      await pulse(2, 0x38, 2 << 17);
      await pulse(2, 0x39, _sram + 0x40);
      await pulse(2, 0x3c, 0xdeadbeef);
      await idle();
      expect(await bus.read(_sram + 0x40), 0xdeadbeef);

      // A word the CPU wrote, read with sbreadonaddr.
      await bus.write(_sram + 0x80, 0x12345678);
      await pulse(2, 0x38, (1 << 20) | (2 << 17));
      await pulse(2, 0x39, _sram + 0x80);
      await idle();
      expect(await read(0x3c), 0x12345678);
      expect((await read(0x38) >> 12) & 7, 0, reason: 'sberror');
      await Simulator.endSimulation();
    });

    test('${kind.name}: a line fetcher reads an SRAM line', () async {
      final soc = _soc(kind);
      final cpu = soc.addMaster(_Cpu(kind));
      final outstanding = kind == HarborFabricKind.wishbone ? 1 : 4;
      final f = _Fetcher(kind, outstanding);
      soc.addMaster(
        f,
        busInterfaceName: 'bus',
        memory: true,
        outstanding: outstanding,
      );
      soc.addPeripheral(_ram(kind));
      cpu.pullUp(soc);
      for (final n in ['f_start', 'f_addr', 'f_words']) {
        soc.pullUpPort(f.port(n), newPortName: n);
      }
      for (final n in ['f_wr_en', 'f_wr_idx', 'f_wr_data', 'f_done']) {
        soc.pullUpPort(f.port(n), newPortName: n);
      }
      soc.buildFabric();
      final start = Logic(name: 'drv_start');
      final addr = Logic(name: 'drv_addr', width: 32);
      final words = Logic(name: 'drv_words', width: 16);
      soc.input('f_start').srcConnection! <= start;
      soc.input('f_addr').srcConnection! <= addr;
      soc.input('f_words').srcConnection! <= words;
      final clk = SimpleClockGenerator(10).clk;
      final bus = RegBus.attach(soc, clk, name: 'cpu', kind: kind);
      await _start(soc, clk, [
        bus.idle,
        () {
          start.inject(0);
          addr.inject(0);
          words.inject(0);
        },
      ]);

      const n = 13;
      for (var i = 0; i < n; i++) {
        await bus.write(_sram + 0x100 + 4 * i, _word(i));
      }
      final got = <int, int>{};
      var done = false;
      clk.posedge.listen((_) {
        if (soc.output('f_wr_en').previousValue?.toBool() ?? false) {
          got[soc.output('f_wr_idx').previousValue!.toInt()] = soc
              .output('f_wr_data')
              .previousValue!
              .toInt();
        }
        if (soc.output('f_done').previousValue?.toBool() ?? false) {
          done = true;
        }
      });
      await clk.nextNegedge;
      addr.inject(_sram + 0x100);
      words.inject(n);
      start.inject(1);
      await clk.nextNegedge;
      start.inject(0);
      for (var i = 0; i < 2000 && !done; i++) {
        await clk.nextPosedge;
      }
      expect(done, isTrue);
      expect(got, {for (var i = 0; i < n; i++) i: _word(i)});
      await Simulator.endSimulation();
    });
  }
}
