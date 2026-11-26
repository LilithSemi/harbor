// An unmapped access of a master on a channel that reaches one slave ends
// with the native decode error on every fabric kind.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

const _sram = 0x08000000;
const _dma = 0x30000000;
const _unmapped = 0x80000000;

class _Cpu extends BridgeModule {
  _Cpu(HarborFabricKind kind) : super('DecErrCpu_${kind.name}', name: 'cpu') {
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

Future<int> _copy(
  HarborFabricKind kind, {
  required int src,
  required int dst,
  required bool channels,
}) async {
  final soc = HarborSoC(
    name: 'decerr_${kind.name}',
    compatible: 'test,decerr',
    fabricKind: kind,
    target: const HarborSimTarget(frequency: 50000000),
  );
  final cpu = soc.addMaster(_Cpu(kind));
  final dma = HarborDmaController(
    baseAddress: _dma,
    channels: 1,
    busAddressWidth: 32,
    fabricKind: kind,
  );
  soc.addPeripheral(dma);
  soc.addMaster(
    dma,
    busInterfaceName: 'dma',
    memory: true,
    outstanding: 1,
    channel: channels ? 'dma' : 'primary',
  );
  soc.addPeripheral(
    HarborSram(
      baseAddress: _sram,
      size: 4096,
      busAddressWidth: 32,
      protocol: kind,
    ),
  );
  cpu.pullUp(soc);
  soc.buildFabric(
    channelSlaves: channels
        ? {
            'primary': {'dma', 'sram'},
            'dma': {'sram'},
          }
        : null,
  );
  final clk = SimpleClockGenerator(10).clk;
  final bus = RegBus.attach(soc, clk, name: 'cpu', kind: kind);
  final reset = Logic(name: 'reset')..inject(1);
  soc.input('clk').srcConnection! <= clk;
  soc.input('reset').srcConnection! <= reset;
  await soc.build();
  bus.idle();
  Simulator.setMaxSimTime(20000000);
  unawaited(Simulator.run());
  for (var i = 0; i < 12; i++) {
    await clk.nextPosedge;
  }
  reset.inject(0);
  for (var i = 0; i < 4; i++) {
    await clk.nextPosedge;
  }
  for (var i = 0; i < 8; i++) {
    await bus.write(_sram + 4 * i, 0x1000 + i);
  }
  await bus.write(_dma + 0x00, 1);
  await bus.write(_dma + 0x50, src);
  await bus.write(_dma + 0x58, dst);
  await bus.write(_dma + 0x60, 32);
  await bus.write(_dma + 0x40, 1);
  var status = 0;
  for (var i = 0; i < 400 && status & 0x6 == 0; i++) {
    for (var c = 0; c < 20; c++) {
      await clk.nextPosedge;
    }
    status = await bus.read(_dma + 0x48);
  }
  await Simulator.endSimulation();
  return status;
}

void main() {
  tearDown(() async => Simulator.reset());

  for (final kind in HarborFabricKind.values) {
    for (final channels in [false, true]) {
      final tag = '${kind.name}${channels ? ', own dma channel' : ''}';
      test('$tag: a write to an unmapped address sets the error', () async {
        final status = await _copy(
          kind,
          src: _sram,
          dst: _unmapped,
          channels: channels,
        );
        expect(status & 0x6, 0x4, reason: 'error, not complete');
      });

      test('$tag: a read from an unmapped address sets the error', () async {
        final status = await _copy(
          kind,
          src: _unmapped,
          dst: _sram + 0x200,
          channels: channels,
        );
        expect(status & 0x6, 0x4, reason: 'error, not complete');
      });
    }
  }
}
