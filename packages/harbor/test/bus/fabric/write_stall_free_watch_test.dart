// The simulation stops when a master that declares writeStallFree stalls its
// write data inside a burst, on each fabric kind.

import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../port/memory_harness.dart' show Burst;
import '../port/port_harness.dart' show Sim;
import '../port/memory_native_harness.dart';
import 'axi4_fabric_harness.dart';
import 'native_fabric_harness.dart';

// The message of the first error the simulation raises while [body] runs,
// or null when the simulation ends without one.
Future<String?> _failure(Future<void> Function() body) async {
  String? message;
  await runZonedGuarded(() async {
    await body();
    await Simulator.simulationEnded;
  }, (e, s) => message ??= '$e');
  return message;
}

Future<String?> _wishbone(bool declare) => _failure(() async {
  final shell = NativeShell(
    HarborFabricKind.wishbone,
    HarborFabricTopology.shared,
    masters: [
      PortCfg('m0', writeStallFree: declare),
      const PortCfg('m1'),
    ],
    slaves: const [PortCfg('s0', base: 0, size: 0x8000)],
  );
  final sim = Sim(shell);
  WbMemory(sim, 's0', Random(1), busBytes: 4, errBase: 0xf000, wait: 0);
  // The master sends the first beat of a write burst, then holds CYC with
  // STB low for 8 cycles.
  var cycle = 0;
  var acked = false;
  sim.onRise(() {
    if (sim.pre('m0_ACK') == 1) acked = true;
  });
  sim.onFall(() {
    cycle++;
    final send = !acked;
    sim.set('m0_CYC', 1);
    sim.set('m0_STB', send ? 1 : 0);
    sim.set('m0_WE', 1);
    sim.set('m0_ADR', 0);
    sim.set('m0_DAT_MOSI', 1);
    sim.set('m0_SEL', 0xf);
    sim.set('m0_CTI', 2);
    if (acked && cycle > 100000) sim.set('m0_CYC', 0);
  });
  await sim.start();
  Simulator.setMaxSimTime(4000);
});

Future<String?> _axi4(bool declare) => _failure(() async {
  final b = await Bench.start(
    HarborFabricTopology.shared,
    masters: [MasterCfg('m0', 2, 4, writeStallFree: declare)],
    slaves: const [SlaveCfg('s0', 5, 4, 0, 0x10000)],
    stall: 0.6,
    maxTime: 60000,
  );
  b.managers['m0']!.write(
    Burst(
      id: 0,
      write: true,
      addr: 0x100,
      len: 15,
      size: 2,
      burst: 1,
      data: [for (var i = 0; i < 16; i++) i],
      strb: List.filled(16, 0xf),
    ),
  );
});

Future<String?> _tilelink(bool declare) => _failure(() async {
  final b = await TlBench.start(
    HarborFabricTopology.shared,
    masters: [PortCfg('m0', width: 1, writeStallFree: declare)],
    slaves: const [
      PortCfg('s0', width: 3, outstanding: 4, base: 0, size: 0x8000),
    ],
    stall: 0.5,
    maxTime: 60000,
  );
  b.send(
    'm0',
    TlMsg(
      op: tlPutFull,
      size: 6,
      addr: 0x40,
      data: [for (var i = 0; i < 16; i++) i],
      mask: List.filled(16, 0xf),
    ),
  );
});

void main() {
  tearDown(() async => Simulator.reset());

  final kinds = <String, Future<String?> Function(bool)>{
    'wishbone': _wishbone,
    'axi4': _axi4,
    'tilelink': _tilelink,
  };
  for (final e in kinds.entries) {
    test(
      '${e.key}: a stall inside a write burst stops the simulation',
      () async {
        final msg = await e.value(true);
        expect(msg, contains('writeStallFree'));
      },
    );
    test('${e.key}: the same stall is fine without the declaration', () async {
      expect(await e.value(false), isNull);
    });
  }
}
