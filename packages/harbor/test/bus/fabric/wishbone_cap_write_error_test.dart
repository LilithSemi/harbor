// The default grant cap of a Wishbone fabric must not end a write burst at a
// beat that did not wait for its response, or a failed write comes back
// without an error.

import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../port/memory_harness.dart';
import '../port/port_harness.dart';
import 'native_fabric_harness.dart';

const _memCfg = HarborMemoryWaistConfig(
  addressWidth: addrW,
  dataWidth: dataW,
  outstanding: 2,
);

class _Shell extends BridgeModule {
  _Shell(HarborFabricTopology t)
    : super('CapWriteErrShell_${t.name}', name: 'shell') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final clk = input('clk');
    final reset = input('reset');
    final wcfg = harborWishboneMemoryConfig(_memCfg);
    final links = [WishboneInterface(wcfg), WishboneInterface(wcfg)];
    for (final (i, n) in ['ua', 'ub'].indexed) {
      final up = HarborMemoryWaist(_memCfg);
      HarborWishboneMemoryMaster(
        clk: clk,
        reset: reset,
        waist: up,
        wb: links[i],
      );
      exposeWaist(this, up, n, PairRole.consumer);
    }
    final slaveLink = WishboneInterface(wcfg);
    final down = HarborMemoryWaist(_memCfg);
    HarborWishboneMemorySlave(
      clk: clk,
      reset: reset,
      wb: slaveLink,
      waist: down,
    );
    exposeWaist(this, down, 'mem', PairRole.provider);
    HarborFabric.build(
      kind: HarborFabricKind.wishbone,
      topology: t,
      clk: clk,
      reset: reset,
      masters: [
        HarborFabricMaster(name: 'a', interface: links[0]),
        HarborFabricMaster(name: 'b', interface: links[1]),
      ],
      slaves: [
        HarborFabricSlave(
          name: 's0',
          range: BusAddressRange(0, 0x10000),
          interface: slaveLink,
        ),
      ],
    );
  }
}

Future<void> _failedWrites(HarborFabricTopology t) async {
  final sim = Sim(_Shell(t));
  final rng = Random(9);
  final errors = <String>[];
  final req = {
    for (final n in ['ua', 'ub'])
      n: WaistRequester(sim, n, rng, errors: errors, idle: 0.6, stall: 0),
  };
  WaistMemory(
    sim,
    'mem',
    rng,
    outstanding: 2,
    busBytes: busBytes,
    errors: errors,
    errBase: 0x2000,
    perBeatErr: true,
    errLine: 0x40,
    stall: 0,
  );
  await sim.start();
  Simulator.setMaxSimTime(8000000);
  for (var i = 0; i < 30; i++) {
    for (final (k, n) in ['ua', 'ub'].indexed) {
      req[n]!.send(
        Burst(
          id: 0,
          write: true,
          addr: 0x2000 + k * 0x1000 + (i % 4) * 0x40,
          len: 15,
          size: 2,
          burst: 1,
          data: [for (var j = 0; j < 16; j++) i * 100 + j],
          strb: List.filled(16, 0xf),
        ),
      );
    }
  }
  await waitUntil(sim, () => req.values.every((r) => r.done), limit: 400000);
  await sim.stop();
  for (final e in req.entries) {
    final ok = e.value.writeResp.where((x) => x.$2 == 0).length;
    must(e.value.writeResp.length, 30);
    expect(ok, 0, reason: '${e.key}: a failed write came back with no error');
  }
  must(errors, isEmpty);
}

void main() {
  tearDown(() async => Simulator.reset());

  for (final t in HarborFabricTopology.values) {
    test('wishbone ${t.name}: the default grant cap keeps the error of a '
        'failed write burst', () async {
      await _failedWrites(t);
    });
  }
}
