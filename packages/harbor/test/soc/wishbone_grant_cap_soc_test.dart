// A master that polls back to back never drops CYC, so a grant locked to
// CYC alone would starve every other master. The default grant cap hands the
// bus over at a transfer boundary.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

const _mem = 0x80000000;
const _words = 8;
const _cfg = WishboneConfig(addressWidth: 32, dataWidth: 32, useErr: true);

/// Reads one word of memory again and again with CYC and STB held high.
class _Poller extends BridgeModule {
  _Poller() : super('GrantCapPoller', name: 'poller') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final bus =
        addInterface(
              WishboneInterface(_cfg),
              name: 'bus',
              role: PairRole.provider,
            ).internalInterface
            as WishboneInterface;
    bus.cyc <= Const(1);
    bus.stb <= Const(1);
    bus.we <= Const(0);
    bus.adr <= Const(_mem + 0x10, width: 32);
    bus.datMosi <= Const(0, width: 32);
    bus.sel <= Const(0xF, width: 4);
  }
}

/// Reads [_words] words of memory, one beat each, and counts the replies.
class _BlockReader extends BridgeModule {
  _BlockReader() : super('GrantCapBlockReader', name: 'reader') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final port = HarborMemoryMasterPort.create(
      module: this,
      name: 'rdbus',
      kind: HarborFabricKind.wishbone,
      config: const HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32),
      clk: input('clk'),
      reset: input('reset'),
    );
    final mem = port.waist;
    final sent = Logic(name: 'sent', width: 4);
    final got = Logic(name: 'got', width: 4);
    final waiting = Logic(name: 'waiting');
    final all = sent.eq(Const(_words, width: 4));
    mem.reqValid <= ~all & ~waiting;
    mem.reqId <= Const(0, width: mem.config.idWidth);
    mem.reqWrite <= Const(0);
    mem.reqAddr <= (Const(_mem, width: 32) + (sent.zeroExtend(32) << 2));
    mem.reqLen <= Const(0, width: HarborMemoryWaistConfig.lenWidth);
    mem.reqSize <= Const(2, width: HarborMemoryWaistConfig.sizeWidth);
    mem.reqBurst <=
        Const(
          HarborMemoryBurst.incr.value,
          width: HarborMemoryWaistConfig.burstWidth,
        );
    mem.reqExclusive <= Const(0);
    mem.wdataValid <= Const(0);
    mem.wdataData <= Const(0, width: 32);
    mem.wdataStrb <= Const(0, width: 4);
    mem.wdataLast <= Const(0);
    mem.rdataReady <= Const(1);
    mem.wrespReady <= Const(0);
    Sequential(input('clk'), [
      If(
        input('reset'),
        then: [sent < 0, got < 0, waiting < 0],
        orElse: [
          If(
            mem.reqValid & mem.reqReady,
            then: [sent < sent + 1, waiting < 1],
          ),
          If(
            mem.rdataValid,
            then: [got < got + 1, waiting < 0],
          ),
        ],
      ),
    ]);
    addOutput('words', width: 4) <= got;
  }
}

// Builds the SoC with the cap argument of buildFabric left out when [cap] is
// absent, and returns the cycles the reader needs, or -1 on a hang.
Future<int> _run({bool explicit = false, int? cap, int limit = 1500}) async {
  final soc = HarborSoC(
    name: 'grant_cap_${explicit ? 'x$cap' : 'default'}',
    compatible: 'test,grantcap',
    fabricKind: HarborFabricKind.wishbone,
    target: const HarborSimTarget(frequency: 50000000),
  );
  final poller = _Poller();
  final reader = _BlockReader();
  soc.addMaster(poller, busInterfaceName: 'bus');
  const range = BusAddressRange(_mem, 0x1000);
  soc.addMaster(
    reader,
    busInterfaceName: 'rdbus',
    memory: true,
    outstanding: 1,
    targetRanges: [range],
  );
  soc.addPeripheral(
    HarborSram(baseAddress: _mem, size: 0x1000, busAddressWidth: 32),
  );
  if (explicit) {
    soc.buildFabric(maxGrantCycles: cap);
  } else {
    soc.buildFabric();
  }
  soc.exposePin(reader, 'words', externalName: 'words');

  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset')..inject(1);
  soc.input('clk').srcConnection! <= clk;
  soc.input('reset').srcConnection! <= reset;
  await soc.build();
  Simulator.setMaxSimTime(10000000);
  unawaited(Simulator.run());
  for (var i = 0; i < 4; i++) {
    await clk.nextPosedge;
  }
  reset.inject(0);
  var cycles = -1;
  for (var i = 0; i < limit; i++) {
    await clk.nextPosedge;
    final v = soc.output('words').value;
    if (v.isValid && v.toInt() == _words) {
      cycles = i;
      break;
    }
  }
  await Simulator.endSimulation();
  await Simulator.reset();
  return cycles;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('a polling master does not starve a dma reader by default', () async {
    final cycles = await _run();
    expect(cycles, greaterThan(0), reason: 'the reader hung');
    expect(cycles, lessThan(600));
  });

  test('an explicit cap of 16 also finishes', () async {
    expect(await _run(explicit: true, cap: 16), greaterThan(0));
  });

  for (final off in <int?>[null, 0]) {
    test('opting out with $off lets the poller starve the reader', () async {
      expect(await _run(explicit: true, cap: off, limit: 800), -1);
    });
  }
}
