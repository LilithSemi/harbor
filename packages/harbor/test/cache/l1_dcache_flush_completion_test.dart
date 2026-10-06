import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'l1d_dut.dart';

void main() {
  tearDown(Simulator.reset);

  for (final write in [false, true]) {
    for (final fault in [false, true]) {
      for (final flushCycles in [1, 12]) {
        test(
          '${write ? "store" : "bypass read"} ${fault ? "fault" : "success"} '
          'survives $flushCycles-cycle flush and invalidates other lines',
          () async {
            final dut = await makeDut(latency: 6, size: 32);
            const mmio = 0x10000000;
            // Different index from MMIO: store invalidation alone cannot drop it.
            const resident = 0x80000008;
            final oldData = BigInt.from(0x1234);
            final newData = BigInt.from(0x5678);
            final deviceData = BigInt.from(0xabcd);
            dut.backing.mem[resident] = oldData;
            dut.backing.mem[mmio] = deviceData;

            Future<BigInt> load(int addr) async {
              dut['req_addr'].inject(addr);
              dut['req_write'].inject(0);
              dut['req_valid'].inject(1);
              for (var i = 0; i < 80; i++) {
                await dut.backing.step();
                expect(dut.respFault, isFalse);
                if (dut.respValid) {
                  final data = dut.cache.output('resp_data').value.toBigInt();
                  dut['req_valid'].inject(0);
                  await dut.backing.step();
                  return data;
                }
              }
              fail('load never completed');
            }

            try {
              expect(await load(resident), oldData);
              final primed = dut.backing.accesses;
              expect(await load(resident), oldData);
              expect(dut.backing.accesses, primed);
              dut.backing.mem[resident] = newData;

              dut.backing.faultResponse = fault;
              dut['req_addr'].inject(mmio);
              dut['req_data'].inject(deviceData);
              dut['req_write'].inject(write ? 1 : 0);
              dut['req_valid'].inject(1);
              for (var i = 0; i < 20 && dut.backing.accesses == primed; i++) {
                await dut.backing.step();
              }
              expect(dut.backing.accesses, primed + 1);
              expect(dut.busy, isTrue);

              var responses = 0;
              var responseDuringFlush = false;
              for (var cycle = 0; cycle < 40; cycle++) {
                final flushing = cycle < flushCycles;
                dut['flush'].inject(flushing ? 1 : 0);
                await dut.backing.step();
                if (dut.respValid || dut.respFault) {
                  responses++;
                  responseDuringFlush |= flushing;
                  expect(dut.respFault, fault);
                  expect(dut.respValid, !fault);
                  if (!write && !fault) {
                    expect(
                      dut.cache.output('resp_data').value.toBigInt(),
                      deviceData,
                    );
                  }
                  dut['req_valid'].inject(0);
                  dut['req_write'].inject(0);
                }
              }
              expect(
                responses,
                1,
                reason: 'preserve exactly one terminal response',
              );
              expect(
                dut.backing.accesses,
                primed + 1,
                reason: 'flush must not replay a device access',
              );
              if (flushCycles == 12) {
                expect(
                  responseDuringFlush,
                  isTrue,
                  reason: 'held flush must not suppress the completion',
                );
              }
              expect(dut.busy, isFalse);
              dut.backing.faultResponse = false;
              final beforeReload = dut.backing.accesses;
              expect(
                await load(resident),
                newData,
                reason: 'flush must invalidate even during a store/bypass',
              );
              expect(dut.backing.accesses, beforeReload + 1);
            } finally {
              await Simulator.endSimulation();
              await Simulator.simulationEnded;
            }
          },
        );
      }
    }
  }
}
