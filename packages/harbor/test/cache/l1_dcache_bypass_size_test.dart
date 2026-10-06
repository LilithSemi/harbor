import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// The uncached (bypass) load path must carry the REQUESTED access size to
/// memory, exactly like the store and the line-fill paths do.
///
/// Every access below `cacheableBase` bypasses the cache: MMIO device
/// registers, boot SRAM and flash. The bypass arm used a hardcoded size of 2
/// (4 bytes), so an 8-byte `ld` from a device register or from SRAM went to the
/// bus as a 4-byte access. The MMU turns this size into the Wishbone SEL
/// byte-lane mask, so the transaction told the slave it wanted half the bytes
/// it wanted. The same hardcoded 2 was already a bug on the line-fill path.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  /// Issue one uncached load of [size] (log2 bytes) at [addr] and return the
  /// `mem_size` the cache put on its memory port.
  Future<int> bypassLoadSize({required int addr, required int size}) async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final reqAddr = Logic(name: 'req_addr', width: 64);
    final reqValid = Logic(name: 'req_valid');
    final reqWrite = Logic(name: 'req_write');
    final reqData = Logic(name: 'req_data', width: 64);
    final reqSize = Logic(name: 'req_size', width: 3);
    final flush = Logic(name: 'flush');
    final memDone = Logic(name: 'mem_done');
    final memValid = Logic(name: 'mem_valid');
    final memRdata = Logic(name: 'mem_rdata', width: 64);
    final memFault = Logic(name: 'mem_fault');

    final cache = HarborL1DCache(
      config: const HarborL1dCacheConfig(size: 256, ways: 1, lineSize: 8),
      xlen: 64,
      reqAddrBits: 32,
    );
    for (final (n, l) in [
      ('clk', clk),
      ('reset', reset),
      ('req_addr', reqAddr),
      ('req_valid', reqValid),
      ('req_write', reqWrite),
      ('req_data', reqData),
      ('req_size', reqSize),
      ('flush', flush),
      ('mem_done', memDone),
      ('mem_valid', memValid),
      ('mem_rdata', memRdata),
      ('mem_fault', memFault),
    ]) {
      cache.port(n).getsLogic(l);
    }
    await cache.build();

    reset.inject(1);
    reqValid.inject(0);
    reqWrite.inject(0);
    reqAddr.inject(0);
    reqData.inject(0);
    reqSize.inject(size);
    flush.inject(0);
    memDone.inject(0);
    memValid.inject(0);
    memRdata.inject(0);

    unawaited(Simulator.run());

    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    // Hold the load until the cache raises its memory request.
    reqAddr.inject(addr);
    reqValid.inject(1);
    reqWrite.inject(0);

    var seen = -1;
    for (var i = 0; i < 50; i++) {
      await clk.nextPosedge;
      if (cache.output('mem_en').value.toBool() &&
          !cache.output('mem_we').value.toBool()) {
        expect(
          cache.output('mem_addr').value.toInt(),
          equals(addr),
          reason: 'bypass must read the exact requested address',
        );
        seen = cache.output('mem_size').value.toInt();
        break;
      }
    }
    reqValid.inject(0);
    await Simulator.endSimulation();
    return seen;
  }

  // 0x10000000 is below the default cacheableBase (0x80000000), so it is an
  // uncached MMIO/SRAM access and takes the bypass path.
  for (final size in [0, 1, 2, 3]) {
    test(
      'uncached load of ${1 << size} bytes goes to memory as size $size',
      () async {
        final got = await bypassLoadSize(addr: 0x10000000, size: size);
        expect(
          got,
          equals(size),
          reason:
              'bypass issued size $got for a ${1 << size}-byte uncached load',
        );
      },
    );
  }
}
