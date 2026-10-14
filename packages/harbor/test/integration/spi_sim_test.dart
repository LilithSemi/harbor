import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../util/mem_target.dart';
import 'test_harness.dart';

/// Test bench that programs the SPI controller over its slave bus and
/// captures the DMA master port's writes with a [MasterTop] + [BeatMemory].
/// Mirrors [PeripheralTestBench] but also wires the `dma` master interface.
class _DmaSpiBench extends BridgeModule {
  final HarborSpiController spi;
  late final WishboneMasterTestDriver master;
  late final MasterTop memTop;
  late final BeatMemory mem;
  late final Logic clk;
  late final int _selWidth;
  int get _fullSel => (1 << _selWidth) - 1;

  Logic get ack => master.output('m_ack');
  Logic get datIn => master.output('m_dat_in');

  /// Number of write beats the memory has seen.
  int get writeCount => mem.log.where((e) => e.$1).length;

  /// Byte address of the last write beat.
  int get lastWriteAddr => mem.log.lastWhere((e) => e.$1).$2;

  /// Data of the last write beat.
  int get lastWriteData => mem.log.lastWhere((e) => e.$1).$3;

  /// Bitwise OR of every write beat's data.
  int get writeDataOr =>
      mem.log.where((e) => e.$1).fold(0, (acc, e) => acc | e.$3);

  _DmaSpiBench(this.spi) : super('DmaSpiBench', name: 'dtb') {
    final clkGen = SimpleClockGenerator(10);
    clk = clkGen.clk;
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    final wb = spi.interface('bus').internalInterface! as WishboneInterface;
    _selWidth = wb.config.effectiveSelWidth;
    final dmaWb = spi.interface('dma').internalInterface! as WishboneInterface;
    final cfg = HarborMemoryWaistConfig(
      addressWidth: dmaWb.config.addressWidth,
      dataWidth: dmaWb.config.dataWidth,
    );

    memTop = MasterTop(
      spi,
      iface: 'dma',
      kind: HarborFabricKind.wishbone,
      config: cfg,
    );
    master = WishboneMasterTestDriver(config: wb.config);
    addSubModule(master);
    addSubModule(memTop);

    connectPorts(port('clk'), master.port('clk'));
    connectPorts(port('clk'), memTop.port('clk'));
    connectPorts(port('reset'), memTop.port('reset'));
    if (memTop.inputs.containsKey('fabric_clk')) {
      connectPorts(port('clk'), memTop.port('fabric_clk'));
      connectPorts(port('reset'), memTop.port('fabric_reset'));
    }
    connectInterfaces(master.interface('bus'), memTop.interface('bus'));

    mem = BeatMemory(memTop, clk);

    pullUpPort(master.port('m_cyc'), newPortName: 'cyc');
    pullUpPort(master.port('m_stb'), newPortName: 'stb');
    pullUpPort(master.port('m_we'), newPortName: 'we');
    pullUpPort(master.port('m_adr'), newPortName: 'adr');
    pullUpPort(master.port('m_dat_out'), newPortName: 'dat_out');
    pullUpPort(master.port('m_sel'), newPortName: 'sel');
  }

  Future<void> init({int maxSimTime = 200000}) async {
    port('clk').getsLogic(clk);
    final resetSig = Logic(name: 'tb_reset');
    port('reset').getsLogic(resetSig);
    await build();

    resetSig.inject(1);
    input('cyc').inject(0);
    input('stb').inject(0);
    input('we').inject(0);
    input('adr').inject(0);
    input('dat_out').inject(0);
    input('sel').inject(_fullSel);
    mem.start();

    Simulator.setMaxSimTime(maxSimTime);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    await clk.nextPosedge;
    resetSig.put(0);
    await clk.nextPosedge;
  }

  Future<void> write(int address, int data) async {
    input('cyc').put(1);
    input('stb').put(1);
    input('we').put(1);
    input('adr').put(address);
    input('dat_out').put(data);
    input('sel').put(_fullSel);
    for (var i = 0; i < 10; i++) {
      await clk.nextPosedge;
      if (ack.value.isValid && ack.value.toInt() == 1) break;
    }
    input('cyc').put(0);
    input('stb').put(0);
    input('we').put(0);
    await clk.nextPosedge;
  }

  Future<int> read(int address) async {
    input('cyc').put(1);
    input('stb').put(1);
    input('we').put(0);
    input('adr').put(address);
    var data = 0;
    for (var i = 0; i < 10; i++) {
      await clk.nextPosedge;
      if (ack.value.isValid && ack.value.toInt() == 1) {
        data = datIn.value.isValid ? datIn.value.toInt() : 0;
        break;
      }
    }
    input('cyc').put(0);
    input('stb').put(0);
    await clk.nextPosedge;
    return data;
  }

  Future<void> waitCycles(int n) async {
    for (var i = 0; i < n; i++) {
      await clk.nextPosedge;
    }
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('SPI sim', () {
    test('write CTRL enable and read back', () async {
      final spi = HarborSpiController(baseAddress: 0x5000);
      spi.port('spi_miso').getsLogic(Const(0));

      final tb = PeripheralTestBench(spi);
      await tb.init();

      // CTRL byte addr 0x00, bit 0 = enable. Registers sit 8 bytes apart, so
      // the bench drives byte addresses (matching the controller's decode).
      await tb.write(0x00, 0x01);
      final val = await tb.read(0x00);
      expect(val & 0x01, equals(0x01));

      await Simulator.endSimulation();
    });

    test('read STATUS not busy', () async {
      final spi = HarborSpiController(baseAddress: 0x5000);
      spi.port('spi_miso').getsLogic(Const(0));

      final tb = PeripheralTestBench(spi);
      await tb.init();

      // STATUS byte addr 0x08
      final val = await tb.read(0x08);
      // bit 0 = busy, should be 0 after reset
      expect(val & 0x01, equals(0));

      await Simulator.endSimulation();
    });

    test('write clock divider and read back', () async {
      final spi = HarborSpiController(baseAddress: 0x5000);
      spi.port('spi_miso').getsLogic(Const(0));

      final tb = PeripheralTestBench(spi);
      await tb.init();

      // DIVIDER byte addr 0x18
      await tb.write(0x18, 42);
      final val = await tb.read(0x18);
      expect(val, equals(42));

      await Simulator.endSimulation();
    });

    test(
      'DMA read packs SPI bytes into memory words (32-bit fabric)',
      () async {
        // dma:true adds the master memory port engine. Drive MISO high so every
        // clocked-in byte is 0xFF; the memory model acks and records each beat.
        // 8 bytes over a 32-bit fabric = two 0xFFFFFFFF words at 0x100/0x104.
        final spi = HarborSpiController(baseAddress: 0x5000, dma: true);

        final tb = _DmaSpiBench(spi);
        tb.memTop.input('spi_miso').srcConnection! <= Const(1);
        await tb.init();

        await tb.write(0x00, 0x01); // CTRL: enable
        await tb.write(0x18, 1); // DIVIDER: fast
        await tb.write(0x28, 0x100); // DMA_ADDR
        await tb.write(0x30, 8); // DMA_LEN: 8 bytes
        await tb.write(0x38, 0x01); // DMA_CTRL: START, DIR=0

        await tb.waitCycles(800);

        expect(tb.writeCount, equals(2), reason: '2 word writes');
        expect(tb.lastWriteAddr, equals(0x104));
        expect(tb.lastWriteData, equals(0xFFFFFFFF));
        expect(
          tb.writeDataOr,
          equals(0xFFFFFFFF),
          reason: 'every packed byte was 0xFF',
        );

        await Simulator.endSimulation();
      },
    );

    test('DMA through a clock crossing writes each word once', () async {
      final spi = HarborSpiController(
        baseAddress: 0x5000,
        dma: true,
        crossFabricClock: true,
      );

      final tb = _DmaSpiBench(spi);
      tb.memTop.input('spi_miso').srcConnection! <= Const(1);
      await tb.init();

      await tb.write(0x00, 0x01);
      await tb.write(0x18, 1);
      for (final base in [0x100, 0x200]) {
        await tb.write(0x28, base);
        await tb.write(0x30, 8);
        await tb.write(0x38, 0x01);
        await tb.waitCycles(1500);
      }

      expect([
        for (final e in tb.mem.log.where((e) => e.$1)) e.$2,
      ], equals([0x100, 0x104, 0x200, 0x204]));

      await Simulator.endSimulation();
    });

    test('a START while the DMA is busy is ignored', () async {
      final spi = HarborSpiController(baseAddress: 0x5000, dma: true);

      final tb = _DmaSpiBench(spi);
      tb.memTop.input('spi_miso').srcConnection! <= Const(1);
      await tb.init();

      await tb.write(0x00, 0x01);
      await tb.write(0x18, 1);
      await tb.write(0x28, 0x100);
      await tb.write(0x30, 8);
      await tb.write(0x38, 0x01);
      // The second START comes in the middle of the first word.
      await tb.waitCycles(60);
      await tb.write(0x38, 0x01);
      await tb.waitCycles(800);

      expect([
        for (final e in tb.mem.log.where((e) => e.$1)) (e.$2, e.$3),
      ], equals([(0x100, 0xFFFFFFFF), (0x104, 0xFFFFFFFF)]));

      await Simulator.endSimulation();
    });

    test(
      'DMA handles back-to-back transfers (GPT/FAT sequential reads)',
      () async {
        // GPT/FAT parsing issues many separate block reads. Verify the FSM
        // re-initialises cleanly between transfers: run two DMAs and confirm the
        // second lands the right words at the right address with DMA_DONE re-set.
        final spi = HarborSpiController(baseAddress: 0x5000, dma: true);

        final tb = _DmaSpiBench(spi);
        tb.memTop.input('spi_miso').srcConnection! <= Const(1);
        await tb.init();

        await tb.write(0x00, 0x01); // CTRL enable
        await tb.write(0x18, 1); // DIVIDER fast

        // Transfer 1: 8 bytes to 0x100 -> two words.
        await tb.write(0x28, 0x100);
        await tb.write(0x30, 8);
        await tb.write(0x38, 0x01); // START
        await tb.waitCycles(800);
        expect(tb.writeCount, equals(2), reason: 'first transfer');
        expect(tb.lastWriteAddr, equals(0x104));

        // Transfer 2: 8 bytes to a fresh 0x200 -> two more words, no leftover
        // state from transfer 1 (address/byte-index/word all re-init on START).
        await tb.write(0x28, 0x200);
        await tb.write(0x30, 8);
        await tb.write(0x38, 0x01); // START
        await tb.waitCycles(800);
        expect(tb.writeCount, equals(4), reason: 'both transfers');
        expect(tb.lastWriteAddr, equals(0x204));
        expect(tb.lastWriteData, equals(0xFFFFFFFF));

        // DMA_DONE is latched again after the second transfer.
        final status = await tb.read(0x08);
        expect((status >> 4) & 0x1, equals(1), reason: 'DMA_DONE re-set');

        await Simulator.endSimulation();
      },
    );

    test('DMA_DONE is write-1-to-clear through STATUS (W1C ack)', () async {
      // STATUS (0x08) is read-only except DMA_DONE (bit 4), which a driver
      // acknowledges by writing a 1 to it. Before this was wired the STATUS
      // write was a no-op, so DMA_DONE stayed set and a driver polling it read a
      // stale done from an earlier transfer (the bug that corrupted back-to-back
      // reads). Confirm one DMA sets DONE, a non-bit-4 write leaves it, and a
      // bit-4 write clears it.
      final spi = HarborSpiController(baseAddress: 0x5000, dma: true);

      final tb = _DmaSpiBench(spi);
      tb.memTop.input('spi_miso').srcConnection! <= Const(1);
      await tb.init();

      await tb.write(0x00, 0x01); // CTRL enable
      await tb.write(0x18, 1); // DIVIDER fast
      await tb.write(0x28, 0x100); // DMA_ADDR
      await tb.write(0x30, 8); // DMA_LEN
      await tb.write(0x38, 0x01); // START
      await tb.waitCycles(800);

      var status = await tb.read(0x08);
      expect(
        (status >> 4) & 0x1,
        equals(1),
        reason: 'DMA_DONE set after transfer',
      );

      // A STATUS write without bit 4 must not disturb DMA_DONE.
      await tb.write(0x08, 0x01);
      status = await tb.read(0x08);
      expect(
        (status >> 4) & 0x1,
        equals(1),
        reason: 'non-bit-4 write leaves DMA_DONE',
      );

      // Writing a 1 to bit 4 clears DMA_DONE.
      await tb.write(0x08, 0x10);
      status = await tb.read(0x08);
      expect((status >> 4) & 0x1, equals(0), reason: 'DMA_DONE cleared by W1C');

      await Simulator.endSimulation();
    });

    test('DMA read packs a full 64-bit beat (RV64 fabric)', () async {
      // On the real delta SoC the fabric is 64-bit, so the engine must pack 8
      // bytes per aligned beat (sel all-ones). 16 bytes = two 64-bit words.
      final spi = HarborSpiController(
        baseAddress: 0x5000,
        busDataWidth: 64,
        dma: true,
      );

      final tb = _DmaSpiBench(spi);
      tb.memTop.input('spi_miso').srcConnection! <= Const(1);
      await tb.init();

      await tb.write(0x00, 0x01); // CTRL: enable
      await tb.write(0x18, 1); // DIVIDER: fast
      await tb.write(0x28, 0x200); // DMA_ADDR
      await tb.write(0x30, 16); // DMA_LEN: 16 bytes
      await tb.write(0x38, 0x01); // DMA_CTRL: START, DIR=0

      await tb.waitCycles(1600);

      expect(tb.writeCount, equals(2), reason: '16B = two 64b beats');
      expect(tb.lastWriteAddr, equals(0x208));
      // An all-ones 64-bit beat is -1 as a Dart int.
      expect(tb.lastWriteData, equals(-1));
      await Simulator.endSimulation();
    });

    test('CS initial state is deasserted (high)', () async {
      final spi = HarborSpiController(baseAddress: 0x5000);
      spi.port('spi_miso').getsLogic(Const(0));

      final tb = PeripheralTestBench(spi);
      await tb.init();

      await tb.waitCycles(2);
      // spi_cs_n is ~csReg. csReg resets to 0, so cs_n should be high (1)
      expect(spi.output('spi_cs_n').value.toInt(), equals(1));

      await Simulator.endSimulation();
    });
  });
}
