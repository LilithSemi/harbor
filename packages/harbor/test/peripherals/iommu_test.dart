import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

// ddtp at byte 0x10 (register index addr[6:3] == 2).
const _ddtp = 0x10;

void main() {
  test('different iotlbEntries counts get different definition names', () {
    final a = HarborIommu(baseAddress: 0x10000000, iotlbEntries: 4);
    final b = HarborIommu(baseAddress: 0x10000000, iotlbEntries: 8);
    expect(a.definitionName, isNot(equals(b.definitionName)));
  });

  for (final kind in HarborFabricKind.values) {
    translationTests(kind);
  }
}

void translationTests(HarborFabricKind kind) {
  group('HarborIommu translation (${kind.name})', () {
    late HarborIommu io;
    late Logic clk, reset;
    late Logic dmaAddr, dmaValid, dmaWrite;
    late Logic transValid, fault;
    late RegBus regBus;

    Future<void> regWrite(int addr, int data) => regBus.write(addr, data);

    // Build with a combinational page-table model on the PTW port: each address
    // in [ptes] returns its PTE, ptw_valid follows ptw_read (single cycle).
    Future<void> setUpDut(Map<int, int> ptes) async {
      io = HarborIommu(
        baseAddress: 0x10000000,
        iotlbEntries: 4,
        msiTranslation: false,
        fabricKind: kind,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      dmaAddr = Logic(name: 'dma_addr_t', width: 64);
      dmaValid = Logic(name: 'dma_valid_t');
      dmaWrite = Logic(name: 'dma_write_t');

      io.input('clk').srcConnection! <= clk;
      io.input('reset').srcConnection! <= reset;
      io.input('dma_addr').srcConnection! <= dmaAddr;
      io.input('dma_valid').srcConnection! <= dmaValid;
      io.input('dma_write').srcConnection! <= dmaWrite;
      io.input('dma_device_id').srcConnection! <= Const(0, width: 24);
      regBus = RegBus.attach(io, clk, name: 'reg');

      // Page-table model on the PTW port.
      final ptwAddr = io.output('ptw_addr');
      Logic pte = Const(0, width: 64);
      ptes.forEach((a, v) {
        pte = mux(ptwAddr.eq(Const(a, width: 64)), Const(v, width: 64), pte);
      });
      io.input('ptw_data').srcConnection! <= pte;
      io.input('ptw_valid').srcConnection! <= io.output('ptw_read');

      await io.build();
      transValid = io.output('dma_translated_valid');
      fault = io.output('dma_fault');

      reset.inject(1);
      regBus.idle();
      dmaAddr.inject(0);
      dmaValid.inject(0);
      dmaWrite.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    }

    // Issue a DMA request and run until translated or faulted. Returns
    // (translatedAddr, faulted, ptwUsed).
    Future<(int, bool, bool)> translate(int va, {bool write = false}) async {
      dmaAddr.inject(va);
      dmaWrite.inject(write ? 1 : 0);
      dmaValid.inject(1);
      await clk.nextPosedge;
      dmaValid.inject(0);
      var ptwUsed = false;
      for (var i = 0; i < 100; i++) {
        if (io.output('ptw_read').value.toInt() == 1) ptwUsed = true;
        if (transValid.value.toInt() == 1) {
          return (
            io.output('dma_translated_addr').value.toInt(),
            false,
            ptwUsed,
          );
        }
        if (fault.value.toInt() == 1) return (0, true, ptwUsed);
        await clk.nextPosedge;
      }
      return (0, false, ptwUsed);
    }

    tearDown(() async {
      await Simulator.reset();
    });

    test('bare mode passes the address through untranslated', () async {
      await setUpDut({});
      // ddtp disabled (bit 0 = 0): bare.
      final (addr, faulted, _) = await translate(0x12345678);
      expect(faulted, isFalse);
      expect(addr, equals(0x12345678));
      await Simulator.endSimulation();
    });

    test('Sv39 walk translates and then hits the IOTLB', () async {
      // root 0x10000 -> L1 0x11000 -> L0 0x12000, leaf maps page 0x55, RW.
      await setUpDut({
        0x10000: (0x11 << 10) | 1, // pointer to L1
        0x11000: (0x12 << 10) | 1, // pointer to L0
        0x12010: (0x55 << 10) | 0x7, // leaf: V|R|W, ppn 0x55
      });
      await regWrite(_ddtp, 0x10000 | 1); // root 0x10000, translation enabled

      // VA 0x2000 -> VPN0 = 2 -> leaf at 0x12000 + 2*8 = 0x12010.
      final (addr, faulted, ptwUsed) = await translate(0x2000);
      expect(faulted, isFalse);
      expect(addr, equals(0x55000)); // ppn 0x55 << 12
      expect(ptwUsed, isTrue); // first access walked the table

      // Second access to the same page: served from the IOTLB, no walk.
      final (addr2, faulted2, ptwUsed2) = await translate(0x2000);
      expect(faulted2, isFalse);
      expect(addr2, equals(0x55000));
      expect(ptwUsed2, isFalse);
      await Simulator.endSimulation();
    });

    test('a write to a read-only page faults', () async {
      await setUpDut({
        0x10000: (0x11 << 10) | 1,
        0x11000: (0x12 << 10) | 1,
        0x12010: (0x55 << 10) | 0x3, // leaf: V|R only (no W)
      });
      await regWrite(_ddtp, 0x10000 | 1);

      final (_, faulted, __) = await translate(0x2000, write: true);
      expect(faulted, isTrue);
      expect(io.output('dma_fault_cause').value.toInt(), equals(2)); // perm
      await Simulator.endSimulation();
    });

    // A write with no byte selected must not change ddtp.
    test('a write with no byte selected changes nothing', () async {
      await setUpDut({
        0x10000: (0x11 << 10) | 1,
        0x11000: (0x12 << 10) | 1,
        0x12010: (0x55 << 10) | 0x7,
      });
      await regWrite(_ddtp, 0x10000 | 1);
      await regBus.write(_ddtp, -1, sel: 0x0);

      // If the sel-0 write had clobbered ddtp, translation would either
      // disable (bare passthrough, no walk) or walk a different root.
      final (addr, faulted, ptwUsed) = await translate(0x2000);
      expect(faulted, isFalse);
      expect(addr, equals(0x55000));
      expect(ptwUsed, isTrue);
      await Simulator.endSimulation();
    });
  });
}
