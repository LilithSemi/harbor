import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'l1d_dut.dart';

void main() {
  tearDown(() async => Simulator.reset());

  for (final pageFault in [true, false]) {
    final kind = pageFault ? 'page' : 'access';

    test('l1i preserves $kind fault classification on refill', () async {
      final clk = SimpleClockGenerator(10).clk;
      final ports = <String, Logic>{
        'reset': Logic(),
        'req_addr': Logic(width: 64),
        'req_valid': Logic(),
        'flush': Logic(),
        'mem_done': Logic(),
        'mem_valid': Logic(),
        'mem_rdata': Logic(width: 64),
        'mem_fault': Logic(),
      };
      final cache = HarborL1ICache(
        config: const HarborL1iCacheConfig(size: 256, ways: 1, lineSize: 8),
        reqAddrBits: 32,
      );
      cache.port('clk').getsLogic(clk);
      ports.forEach((name, signal) => cache.port(name).getsLogic(signal));
      await cache.build();
      for (final signal in ports.values) {
        signal.inject(0);
      }
      ports['reset']!.inject(1);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      ports['reset']!.inject(0);
      ports['req_addr']!.inject(0x80000000);
      ports['req_valid']!.inject(1);

      while (!cache.output('mem_en').value.toBool()) {
        await clk.nextPosedge;
      }
      ports['mem_done']!.inject(1);
      ports['mem_fault']!.inject(pageFault ? 1 : 0);
      await clk.nextPosedge;
      ports['mem_done']!.inject(0);
      ports['mem_fault']!.inject(0);
      await clk.nextPosedge;

      expect(cache.output('resp_fault').value.toBool(), isTrue);
      expect(cache.output('resp_fault_is_access').value.toBool(), !pageFault);
      expect(cache.output('resp_valid').value.toBool(), isFalse);
      await Simulator.endSimulation();
    });

    for (final operation in ['refill', 'bypass', 'store']) {
      test('l1d preserves $kind fault classification on $operation', () async {
        final dut = await makeDut();
        dut.backing
          ..faultResponse = true
          ..faultIsPage = pageFault;
        dut['req_addr'].inject(operation == 'bypass' ? 0x1000 : 0x80000000);
        dut['req_write'].inject(operation == 'store' ? 1 : 0);
        dut['req_valid'].inject(1);

        var sawCompletion = false;
        for (var cycle = 0; cycle < 40 && !sawCompletion; cycle++) {
          await dut.backing.step();
          sawCompletion = dut.respFault;
        }

        expect(sawCompletion, isTrue);
        expect(dut.respFault, isTrue);
        expect(dut.respFaultIsAccess, !pageFault);
        expect(dut.respValid, isFalse);
        await Simulator.endSimulation();
      });
    }
  }
}
