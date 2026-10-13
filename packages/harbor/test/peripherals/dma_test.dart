import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

// Register BYTE offsets. Each register is its own 8-byte slot and a block is 8
// slots (0x40): block 0 is global, block ch+1 is channel ch.
const _ctrl = 0x00;
const _intEnable = 0x10;
int _chBase(int ch) => 0x40 * (ch + 1);
int _chCtrl(int ch) => _chBase(ch) + 0x00;
int _chStatus(int ch) => _chBase(ch) + 0x08;
int _chSrc(int ch) => _chBase(ch) + 0x10;
int _chDst(int ch) => _chBase(ch) + 0x18;
int _chLen(int ch) => _chBase(ch) + 0x20;

void main() {
  group('HarborDmaChannelConfig', () {
    test('defaults', () {
      const config = HarborDmaChannelConfig();
      expect(config.maxBurstLength, equals(16));
      expect(config.scatterGather, isFalse);
    });

    test('toPrettyString', () {
      const config = HarborDmaChannelConfig(scatterGather: true);
      expect(config.toPrettyString(), contains('scatter-gather'));
    });
  });

  group('HarborDmaController', () {
    test('creates with default channels', () {
      final dma = HarborDmaController(baseAddress: 0x30000000);
      expect(dma.bus, isNotNull);
      expect(dma.interrupt.width, equals(1));
      expect(dma.channels, equals(4));
    });

    test('creates with custom channel count', () {
      final dma = HarborDmaController(baseAddress: 0x30000000, channels: 8);
      expect(dma.channels, equals(8));
    });

    test('DT node', () {
      final dma = HarborDmaController(baseAddress: 0x30000000, channels: 2);
      final dt = dma.dtNode;
      expect(dt.compatible.first, equals('harbor,dma'));
      expect(dt.properties['dma-channels'], equals(2));
    });

    test('supports TileLink', () {
      final dma = HarborDmaController(
        baseAddress: 0x30000000,
        fabricKind: HarborFabricKind.tilelink,
      );
      expect(dma.bus.kind, equals(HarborFabricKind.tilelink));
    });

    test('defaults the master data bus to 32 bits', () {
      final dma = HarborDmaController(baseAddress: 0x30000000);
      expect(dma.output('dma_wdata').width, equals(32));
      expect(dma.input('dma_rdata').width, equals(32));
    });

    test('widens the master data bus when dataWidth is set', () {
      final dma = HarborDmaController(baseAddress: 0x30000000, dataWidth: 64);
      expect(dma.output('dma_wdata').width, equals(64));
      expect(dma.input('dma_rdata').width, equals(64));
    });

    test('adds peripheral stream ports only in stream mode', () {
      final dma = HarborDmaController(
        baseAddress: 0x30000000,
        source: HarborDmaSource.peripheralStream,
        dataWidth: 64,
      );
      expect(dma.input('s_data').width, equals(64));
      expect(dma.input('s_valid').width, equals(1));
      expect(dma.input('s_last').width, equals(1));
      expect(dma.output('s_ready').width, equals(1));

      // Default (mem) source stays byte-identical: no stream ports at all.
      final memDma = HarborDmaController(baseAddress: 0x30000000);
      expect(memDma.tryInput('s_data'), isNull);
      expect(memDma.tryInput('s_valid'), isNull);
      expect(memDma.tryInput('s_last'), isNull);
      expect(memDma.tryOutput('s_ready'), isNull);
    });

    test('defaults target to fabric', () {
      final dma = HarborDmaController(baseAddress: 0x30000000);
      expect(dma.target, equals(HarborDmaTarget.fabric));
      expect(dma.memRange, isNull);
    });

    test('target sdram without a memRange throws', () {
      expect(
        () => HarborDmaController(
          baseAddress: 0x30000000,
          target: HarborDmaTarget.sdram,
        ),
        throwsArgumentError,
      );
    });

    test('two parameter sets give different definitionNames', () {
      final a = HarborDmaController(baseAddress: 0x30000000, channels: 2);
      final b = HarborDmaController(baseAddress: 0x30000000, channels: 4);
      expect(a.definitionName, isNot(equals(b.definitionName)));
    });
  });

  for (final kind in HarborFabricKind.values) {
    _transferEngineTests(kind);
    _dataWidth64Tests(kind);
    _peripheralStreamTests(kind);
    _targetSdramTests(kind);
  }
}

void _transferEngineTests(HarborFabricKind kind) {
  group('HarborDmaController transfer engine (${kind.name})', () {
    late HarborDmaController dma;
    late Logic clk, reset, irq;
    late RegBus bus;
    late List<Logic> mem;

    Future<void> bw(int addr, int data) => bus.write(addr, data);
    Future<int> br(int addr) => bus.read(addr);

    // Build the DUT with a 16-word memory model on the master port, preloaded
    // with [dmaMem].
    Future<void> setUpDut(List<int> dmaMem) async {
      dma = HarborDmaController(
        baseAddress: 0x30000000,
        channels: 2,
        fabricKind: kind,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      bus = RegBus.attach(dma, clk);

      dma.input('clk').srcConnection! <= clk;
      dma.input('reset').srcConnection! <= reset;

      final initVals = [
        for (var i = 0; i < 16; i++) i < dmaMem.length ? dmaMem[i] : 0,
      ];
      mem = [for (var i = 0; i < 16; i++) Logic(name: 'mem$i', width: 32)];
      final mStb = dma.output('dma_stb');
      final mWe = dma.output('dma_we');
      final mAddr = dma.output('dma_addr');
      final mWdata = dma.output('dma_wdata');
      final mIdx = mAddr.getRange(2, 6);
      Sequential(
        clk,
        reset: reset,
        resetValues: {
          for (var i = 0; i < 16; i++) mem[i]: Const(initVals[i], width: 32),
        },
        [
          If(
            mStb & mWe,
            then: [
              for (var i = 0; i < 16; i++)
                If(mIdx.eq(Const(i, width: 4)), then: [mem[i] < mWdata]),
            ],
          ),
        ],
      );
      Logic mRd = mem[15];
      for (var i = 14; i >= 0; i--) {
        mRd = mux(mIdx.eq(Const(i, width: 4)), mem[i], mRd);
      }
      dma.input('dma_rdata').srcConnection! <= mRd;
      dma.input('dma_ack').srcConnection! <= mStb;

      await dma.build();
      bus.idle();
      irq = dma.output('interrupt');

      reset.inject(1);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    }

    Future<bool> runUntilIrq() async {
      for (var i = 0; i < 4000; i++) {
        await clk.nextPosedge;
        if (irq.value.toInt() == 1) return true;
      }
      return false;
    }

    tearDown(() async {
      await Simulator.reset();
    });

    test('mem-to-mem copies a buffer and raises the channel IRQ', () async {
      // Source words 0,1, destination words 8,9 (byte 0x20).
      await setUpDut([0xAAAA1111, 0xBBBB2222]);
      await bw(_ctrl, 1); // global enable
      await bw(_intEnable, 0x1); // channel 0 IRQ
      await bw(_chSrc(0), 0x00);
      await bw(_chDst(0), 0x20);
      await bw(_chLen(0), 8); // 2 words
      await bw(_chCtrl(0), 0x1); // enable, type memToMem -> start

      expect(await runUntilIrq(), isTrue);
      expect(mem[8].value.toInt(), equals(0xAAAA1111));
      expect(mem[9].value.toInt(), equals(0xBBBB2222));
      await Simulator.endSimulation();
    });

    test('periph-to-mem holds the source address fixed', () async {
      await setUpDut([0xC0FFEE00, 0xDEADBEEF]);
      await bw(_ctrl, 1);
      await bw(_intEnable, 0x1);
      await bw(_chSrc(0), 0x00); // fixed source = word 0
      await bw(_chDst(0), 0x20);
      await bw(_chLen(0), 8);
      // type periphToMem (2): source stays fixed, destination increments.
      await bw(_chCtrl(0), 0x1 | (2 << 4));

      expect(await runUntilIrq(), isTrue);
      // Both destination words got the same (fixed) source word.
      expect(mem[8].value.toInt(), equals(0xC0FFEE00));
      expect(mem[9].value.toInt(), equals(0xC0FFEE00));
      await Simulator.endSimulation();
    });

    test('a write with no byte selected changes nothing', () async {
      await setUpDut([0xAAAA1111, 0xBBBB2222]);
      // intEnable is channels wide (2 bits here); the other registers are
      // full 32-bit words.
      await bw(_intEnable, 0x3);
      await bw(_chSrc(0), 0x11223344);

      // sel=0: none of these may take effect, including the channel start.
      await bus.write(_intEnable, 0x0, sel: 0x0);
      await bus.write(_chSrc(0), 0xffffffff, sel: 0x0);
      await bus.write(_chCtrl(0), 0x1, sel: 0x0);

      expect(await br(_intEnable), equals(0x3));
      expect(await br(_chSrc(0)), equals(0x11223344));
      expect(await br(_chStatus(0)) & 0x1, equals(0)); // not busy: no start
      await Simulator.endSimulation();
    });
  });
}

void _dataWidth64Tests(HarborFabricKind kind) {
  group(
    'HarborDmaController transfer engine at dataWidth 64 (${kind.name})',
    () {
      late HarborDmaController dma;
      late Logic clk, reset, irq;
      late RegBus bus;
      late List<Logic> mem;
      late Logic beatCount;

      Future<void> bw(int addr, int data) => bus.write(addr, data);

      // Build the DUT with a 64-bit master data bus and an 8-beat memory model
      // (one beat = 8 bytes), preloaded with [dmaMem]. Also counts write beats
      // on the master port so the test can tell 8-byte beats apart from the
      // 4-byte beats the default dataWidth:32 uses.
      Future<void> setUpDut(List<int> dmaMem) async {
        dma = HarborDmaController(
          baseAddress: 0x30000000,
          channels: 2,
          dataWidth: 64,
          fabricKind: kind,
        );
        clk = SimpleClockGenerator(10).clk;
        reset = Logic(name: 'reset');
        bus = RegBus.attach(dma, clk);

        dma.input('clk').srcConnection! <= clk;
        dma.input('reset').srcConnection! <= reset;

        final initVals = [
          for (var i = 0; i < 8; i++) i < dmaMem.length ? dmaMem[i] : 0,
        ];
        mem = [for (var i = 0; i < 8; i++) Logic(name: 'mem64_$i', width: 64)];
        final beats = Logic(name: 'beat_count', width: 8);
        final mStb = dma.output('dma_stb');
        final mWe = dma.output('dma_we');
        final mAddr = dma.output('dma_addr');
        final mWdata = dma.output('dma_wdata');
        // 8-byte beats: the beat index is the byte address divided by 8.
        final mIdx = mAddr.getRange(3, 6);
        Sequential(
          clk,
          reset: reset,
          resetValues: {
            for (var i = 0; i < 8; i++) mem[i]: Const(initVals[i], width: 64),
            beats: Const(0, width: 8),
          },
          [
            If(
              mStb & mWe,
              then: [
                for (var i = 0; i < 8; i++)
                  If(mIdx.eq(Const(i, width: 3)), then: [mem[i] < mWdata]),
                beats < (beats + Const(1, width: 8)),
              ],
            ),
          ],
        );
        Logic mRd = mem[7];
        for (var i = 6; i >= 0; i--) {
          mRd = mux(mIdx.eq(Const(i, width: 3)), mem[i], mRd);
        }
        dma.input('dma_rdata').srcConnection! <= mRd;
        dma.input('dma_ack').srcConnection! <= mStb;
        beatCount = beats;

        await dma.build();
        bus.idle();
        irq = dma.output('interrupt');

        reset.inject(1);
        Simulator.setMaxSimTime(2000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;
      }

      Future<bool> runUntilIrq() async {
        for (var i = 0; i < 4000; i++) {
          await clk.nextPosedge;
          if (irq.value.toInt() == 1) return true;
        }
        return false;
      }

      tearDown(() async {
        await Simulator.reset();
      });

      test('mem-to-mem moves 8 bytes per beat, not 4', () async {
        // Source beat 0 (byte 0x00), destination beat 4 (byte 0x20). CH_LEN is
        // 16 bytes: at dataWidth:64 that is 2 beats of 8 bytes, versus 4 beats
        // of 4 bytes at the default dataWidth:32.
        await setUpDut([0x1111111122222222, 0x3333333344444444]);
        await bw(_ctrl, 1); // global enable
        await bw(_intEnable, 0x1); // channel 0 IRQ
        await bw(_chSrc(0), 0x00);
        await bw(_chDst(0), 0x20);
        await bw(_chLen(0), 16); // 2 beats of 8 bytes
        await bw(_chCtrl(0), 0x1); // enable, type memToMem -> start

        expect(await runUntilIrq(), isTrue);
        expect(beatCount.value.toInt(), equals(2));
        expect(mem[4].value.toInt(), equals(0x1111111122222222));
        expect(mem[5].value.toInt(), equals(0x3333333344444444));
        await Simulator.endSimulation();
      });
    },
  );
}

void _peripheralStreamTests(HarborFabricKind kind) {
  group('HarborDmaController peripheral stream source (${kind.name})', () {
    late HarborDmaController dma;
    late Logic clk, reset;
    late RegBus bus;
    late Logic sData, sValid, sLast, irq;
    late List<Logic> mem;

    Future<void> bw(int addr, int data) => bus.write(addr, data);

    // Build the DUT in peripheralStream mode with a 16-word memory model on
    // the master (write) side. The stream is fed by the test via s_data /
    // s_valid / s_last, honoring s_ready backpressure.
    Future<void> setUpDut() async {
      dma = HarborDmaController(
        baseAddress: 0x30000000,
        channels: 2,
        source: HarborDmaSource.peripheralStream,
        fabricKind: kind,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      bus = RegBus.attach(dma, clk);
      sData = Logic(name: 's_data', width: dma.input('s_data').width);
      sValid = Logic(name: 's_valid');
      sLast = Logic(name: 's_last');

      dma.input('clk').srcConnection! <= clk;
      dma.input('reset').srcConnection! <= reset;
      dma.input('s_data').srcConnection! <= sData;
      dma.input('s_valid').srcConnection! <= sValid;
      dma.input('s_last').srcConnection! <= sLast;

      mem = [for (var i = 0; i < 16; i++) Logic(name: 'mem$i', width: 32)];
      final mStb = dma.output('dma_stb');
      final mWe = dma.output('dma_we');
      final mAddr = dma.output('dma_addr');
      final mWdata = dma.output('dma_wdata');
      final mIdx = mAddr.getRange(2, 6);
      Sequential(
        clk,
        reset: reset,
        resetValues: {for (final m in mem) m: Const(0, width: 32)},
        [
          If(
            mStb & mWe,
            then: [
              for (var i = 0; i < 16; i++)
                If(mIdx.eq(Const(i, width: 4)), then: [mem[i] < mWdata]),
            ],
          ),
        ],
      );
      // The stream source never issues a master read, but the port still
      // needs to be driven.
      dma.input('dma_rdata').srcConnection! <=
          Const(0, width: dma.input('dma_rdata').width);
      dma.input('dma_ack').srcConnection! <= mStb;

      await dma.build();
      bus.idle();
      irq = dma.output('interrupt');

      reset.inject(1);
      sData.inject(0);
      sValid.inject(0);
      sLast.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    }

    Future<bool> runUntilIrq() async {
      for (var i = 0; i < 4000; i++) {
        await clk.nextPosedge;
        if (irq.value.toInt() == 1) return true;
      }
      return false;
    }

    tearDown(() async {
      await Simulator.reset();
    });

    test(
      'writes a stream of words into memory and completes on s_last',
      () async {
        await setUpDut();
        await bw(_ctrl, 1); // global enable
        await bw(_intEnable, 0x1); // channel 0 IRQ
        await bw(_chDst(0), 0x20); // destination word 8
        // CH_LEN covers 4 words. The stream only sends 3 and ends on s_last,
        // proving s_last (not CH_LEN) ends the transfer here.
        await bw(_chLen(0), 16);
        // enable, type periphToMem (2) -> start
        await bw(_chCtrl(0), 0x1 | (2 << 4));

        final words = [0x11111111, 0x22222222, 0x33333333];
        for (var i = 0; i < words.length; i++) {
          // Honor s_ready backpressure: only present a word once the
          // controller signals it can accept one.
          while (dma.output('s_ready').value.toInt() != 1) {
            await clk.nextPosedge;
          }
          sData.inject(words[i]);
          sValid.inject(1);
          sLast.inject(i == words.length - 1 ? 1 : 0);
          await clk.nextPosedge;
          sValid.inject(0);
          sLast.inject(0);
        }

        expect(await runUntilIrq(), isTrue);
        expect(mem[8].value.toInt(), equals(0x11111111));
        expect(mem[9].value.toInt(), equals(0x22222222));
        expect(mem[10].value.toInt(), equals(0x33333333));
        // Only the 3 streamed words landed. s_last ended the transfer early.
        expect(mem[11].value.toInt(), equals(0));
        await Simulator.endSimulation();
      },
    );
  });
}

void _targetSdramTests(HarborFabricKind kind) {
  group('HarborDmaController target=sdram address clamp (${kind.name})', () {
    late HarborDmaController dma;
    late Logic clk, reset, irq;
    late RegBus bus;
    late List<Logic> mem;
    late Logic writeBeats;

    // The allowed memory window: matches the brief's example (0x8000_0000,
    // 256 MiB).
    const memRange = BusAddressRange(0x80000000, 0x10000000);

    Future<void> bw(int addr, int data) => bus.write(addr, data);
    Future<int> br(int addr) => bus.read(addr);

    // Build the DUT with target: sdram and the memRange above, and a 16-word
    // memory model on the master port preloaded with [dmaMem]. The model
    // only decodes the low 6 address bits, so a destination inside the
    // window (e.g. 0x8000_0020) and a destination outside it (e.g.
    // 0x1000_0000) both fall on real word slots. A write beat counter proves
    // whether the master port ever pulsed dma_stb & dma_we.
    Future<void> setUpDut(List<int> dmaMem) async {
      dma = HarborDmaController(
        baseAddress: 0x30000000,
        channels: 2,
        target: HarborDmaTarget.sdram,
        memRange: memRange,
        fabricKind: kind,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      bus = RegBus.attach(dma, clk);

      dma.input('clk').srcConnection! <= clk;
      dma.input('reset').srcConnection! <= reset;

      final initVals = [
        for (var i = 0; i < 16; i++) i < dmaMem.length ? dmaMem[i] : 0,
      ];
      mem = [for (var i = 0; i < 16; i++) Logic(name: 'mem$i', width: 32)];
      final beats = Logic(name: 'write_beats', width: 8);
      final mStb = dma.output('dma_stb');
      final mWe = dma.output('dma_we');
      final mAddr = dma.output('dma_addr');
      final mWdata = dma.output('dma_wdata');
      final mIdx = mAddr.getRange(2, 6);
      Sequential(
        clk,
        reset: reset,
        resetValues: {
          for (var i = 0; i < 16; i++) mem[i]: Const(initVals[i], width: 32),
          beats: Const(0, width: 8),
        },
        [
          If(
            mStb & mWe,
            then: [
              for (var i = 0; i < 16; i++)
                If(mIdx.eq(Const(i, width: 4)), then: [mem[i] < mWdata]),
              beats < (beats + Const(1, width: 8)),
            ],
          ),
        ],
      );
      Logic mRd = mem[15];
      for (var i = 14; i >= 0; i--) {
        mRd = mux(mIdx.eq(Const(i, width: 4)), mem[i], mRd);
      }
      dma.input('dma_rdata').srcConnection! <= mRd;
      dma.input('dma_ack').srcConnection! <= mStb;
      writeBeats = beats;

      await dma.build();
      bus.idle();
      irq = dma.output('interrupt');

      reset.inject(1);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    }

    Future<bool> runUntilIrq() async {
      for (var i = 0; i < 4000; i++) {
        await clk.nextPosedge;
        if (irq.value.toInt() == 1) return true;
      }
      return false;
    }

    // No IRQ fires on an out-of-range abort (the channel never completes),
    // so poll CH_STATUS (bit 0 busy) until the channel engine has stopped.
    Future<void> runUntilNotBusy(int ch) async {
      for (var i = 0; i < 4000; i++) {
        final status = await br(_chStatus(ch));
        if (status & 0x1 == 0) return;
        await clk.nextPosedge;
      }
    }

    tearDown(() async {
      await Simulator.reset();
    });

    test(
      'in-range destination writes normally and leaves error clear',
      () async {
        await setUpDut([0xAAAA1111, 0xBBBB2222]);
        await bw(_ctrl, 1); // global enable
        await bw(_intEnable, 0x1); // channel 0 IRQ
        await bw(_chSrc(0), 0x00);
        await bw(_chDst(0), 0x80000020); // inside [0x8000_0000, 0x9000_0000)
        await bw(_chLen(0), 8); // 2 words
        await bw(_chCtrl(0), 0x1); // enable, type memToMem -> start

        expect(await runUntilIrq(), isTrue);
        expect(writeBeats.value.toInt(), equals(2));
        expect(mem[8].value.toInt(), equals(0xAAAA1111));
        expect(mem[9].value.toInt(), equals(0xBBBB2222));

        final status = await br(_chStatus(0));
        expect(status & 0x4, equals(0)); // CH_STATUS.error clear
        await Simulator.endSimulation();
      },
    );

    test(
      'out-of-range destination sets CH_STATUS.error and writes nothing',
      () async {
        await setUpDut([0xAAAA1111, 0xBBBB2222]);
        await bw(_ctrl, 1); // global enable
        await bw(_intEnable, 0x1); // channel 0 IRQ
        await bw(_chSrc(0), 0x00);
        await bw(_chDst(0), 0x10000000); // outside the memRange window
        await bw(_chLen(0), 8);
        await bw(_chCtrl(0), 0x1); // enable, type memToMem -> start

        await runUntilNotBusy(0);
        final status = await br(_chStatus(0));
        expect(status & 0x4, equals(0x4)); // CH_STATUS.error set
        expect(status & 0x2, equals(0)); // CH_STATUS.complete stays clear
        expect(writeBeats.value.toInt(), equals(0)); // no master write at all
        await Simulator.endSimulation();
      },
    );
  });
}
