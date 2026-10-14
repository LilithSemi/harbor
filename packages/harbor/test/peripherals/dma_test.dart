import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../util/mem_target.dart';
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

/// A memory slave waist that fails every request whose byte address is at or
/// above [errorAddr] (RDATA_ERR for a read, WRESP_ERR for a write) and
/// completes every other request normally. One request at a time, LEN 0
/// only, which is all the DMA engine ever issues.
///
/// Built directly on [HarborMemorySlavePort] instead of
/// `test/util/mem_target.dart`'s [MemBeatTarget], which always answers ERR
/// low.
class _ErrorTarget extends BridgeModule {
  _ErrorTarget(
    HarborFabricKind kind,
    HarborMemoryWaistConfig config,
    int errorAddr,
  ) : super(
        'ErrorTarget_${kind.name}_a${config.addressWidth}_d${config.dataWidth}'
        '_e$errorAddr',
        name: 'err_target',
      ) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final port = HarborMemorySlavePort.create(
      module: this,
      name: 'bus',
      kind: kind,
      config: config,
      clk: input('clk'),
      reset: input('reset'),
    );
    final w = port.waist;
    final clk = input('clk');
    final reset = port.reset;
    final aw = config.addressWidth;

    final busy = Logic(name: 'busy');
    final isWrite = Logic(name: 'is_write');
    final id = Logic(name: 'id', width: config.idWidth);
    final rValid = Logic(name: 'r_valid');
    final bValid = Logic(name: 'b_valid');
    final err = Logic(name: 'err');

    w.reqReady <= ~busy;
    w.wdataReady <= (busy & isWrite);
    w.rdataValid <= rValid;
    w.rdataId <= id;
    w.rdataData <= Const(0, width: config.dataWidth);
    w.rdataErr <= err;
    w.rdataLast <= Const(1);
    w.wrespValid <= bValid;
    w.wrespId <= id;
    w.wrespErr <= err;

    Sequential(clk, [
      If(
        reset,
        then: [
          busy < Const(0),
          isWrite < Const(0),
          id < Const(0, width: config.idWidth),
          rValid < Const(0),
          bValid < Const(0),
          err < Const(0),
        ],
        orElse: [
          If(rValid & w.rdataReady, then: [rValid < Const(0), busy < Const(0)]),
          If(bValid & w.wrespReady, then: [bValid < Const(0), busy < Const(0)]),
          If(
            busy & isWrite & w.wdataValid & w.wdataReady,
            then: [bValid < Const(1)],
          ),
          If(
            w.reqValid & ~busy,
            then: [
              busy < Const(1),
              isWrite < w.reqWrite,
              id < w.reqId,
              err < w.reqAddr.gte(Const(errorAddr, width: aw)),
              If(~w.reqWrite, then: [rValid < Const(1)]),
            ],
          ),
        ],
      ),
    ]);
  }
}

/// Wires [dut]'s memory master interface [iface] to an [_ErrorTarget], the
/// same way `test/util/mem_target.dart`'s `MasterTop` wires one to a
/// `MemBeatTarget`. Every other interface and port of [dut] keeps its name.
class _ErrorMasterTop extends BridgeModule {
  late final _ErrorTarget target;

  _ErrorMasterTop(
    BridgeModule dut, {
    required String iface,
    required HarborFabricKind kind,
    required HarborMemoryWaistConfig config,
    required int errorAddr,
  }) : super('ErrorMasterTop_${dut.definitionName}_e$errorAddr', name: 'top') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    addSubModule(dut);
    target = addSubModule(_ErrorTarget(kind, config, errorAddr));
    for (final m in [dut, target]) {
      m.input('clk').srcConnection! <= input('clk');
      m.input('reset').srcConnection! <= input('reset');
    }
    connectInterfaces(dut.interface(iface), target.interface('bus'));
    final intfNames = dut.interfaces.keys.toList();
    for (final n in intfNames) {
      if (n == iface) continue;
      pullUpInterface(dut.interface(n), newIntfName: n);
    }
    bool inIntf(String p) => intfNames.any((n) => p.startsWith('${n}_'));
    for (final p in [...dut.inputs.keys, ...dut.outputs.keys]) {
      if (p == 'clk' || p == 'reset' || inIntf(p)) continue;
      pullUpPort(dut.port(p), newPortName: p);
    }
  }
}

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
      expect(dma.output('dma_DAT_MOSI').width, equals(32));
      expect(dma.input('dma_DAT_MISO').width, equals(32));
    });

    test('widens the master data bus when dataWidth is set', () {
      final dma = HarborDmaController(baseAddress: 0x30000000, dataWidth: 64);
      expect(dma.output('dma_DAT_MOSI').width, equals(64));
      expect(dma.input('dma_DAT_MISO').width, equals(64));
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
    _memoryWaistTests(kind);
  }
}

/// Builds a [HarborDmaController] of [kind], wires its `dma` master memory
/// port to a [MasterTop] + [BeatMemory], and preloads [dmaMem] as the first
/// words of memory. Returns the running testbench pieces.
class _Dut {
  final HarborDmaController dma;
  final MasterTop top;
  final Logic clk;
  final Logic reset;
  final RegBus bus;
  final BeatMemory mem;
  final Logic irq;

  _Dut(this.dma, this.top, this.clk, this.reset, this.bus, this.mem, this.irq);

  Future<void> bw(int addr, int data) => bus.write(addr, data);
  Future<int> br(int addr) => bus.read(addr);

  Future<bool> runUntilIrq({int limit = 4000}) async {
    for (var i = 0; i < limit; i++) {
      await clk.nextPosedge;
      if (irq.value.toInt() == 1) return true;
    }
    return false;
  }

  Future<void> runUntilNotBusy(int ch, {int limit = 4000}) async {
    for (var i = 0; i < limit; i++) {
      final status = await br(_chStatus(ch));
      if (status & 0x1 == 0) return;
      await clk.nextPosedge;
    }
  }
}

Future<_Dut> _setUpDut(
  HarborFabricKind kind, {
  int channels = 2,
  int dataWidth = 32,
  HarborDmaSource source = HarborDmaSource.mem,
  HarborDmaTarget target = HarborDmaTarget.fabric,
  BusAddressRange? memRange,
  List<int> dmaMem = const [],
}) async {
  final dma = HarborDmaController(
    baseAddress: 0x30000000,
    channels: channels,
    dataWidth: dataWidth,
    source: source,
    target: target,
    memRange: memRange,
    fabricKind: kind,
  );
  final cfg = HarborMemoryWaistConfig(
    addressWidth: dma.addressWidth,
    dataWidth: dma.dataWidth,
  );
  final top = MasterTop(dma, iface: 'dma', kind: kind, config: cfg);
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  top.input('clk').srcConnection! <= clk;
  top.input('reset').srcConnection! <= reset;
  final bus = RegBus.attach(top, clk);
  final mem = BeatMemory(top, clk, fill: (_) => 0);
  final busBytes = dataWidth ~/ 8;
  for (var i = 0; i < dmaMem.length; i++) {
    mem.writeWord(i * busBytes, dmaMem[i]);
  }

  if (source == HarborDmaSource.peripheralStream) {
    top.input('s_data').srcConnection! <= Const(0, width: dataWidth);
    top.input('s_valid').srcConnection! <= Const(0);
    top.input('s_last').srcConnection! <= Const(0);
  }

  await top.build();
  bus.idle();
  final irq = dma.output('interrupt');

  reset.inject(1);
  Simulator.setMaxSimTime(2000000);
  unawaited(Simulator.run());
  mem.start();
  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.inject(0);
  await clk.nextPosedge;

  return _Dut(dma, top, clk, reset, bus, mem, irq);
}

void _transferEngineTests(HarborFabricKind kind) {
  group('HarborDmaController transfer engine (${kind.name})', () {
    tearDown(() async {
      await Simulator.reset();
    });

    test('mem-to-mem copies a buffer and raises the channel IRQ', () async {
      // Source words 0,1, destination words 8,9 (byte 0x20).
      final d = await _setUpDut(kind, dmaMem: [0xAAAA1111, 0xBBBB2222]);
      await d.bw(_ctrl, 1); // global enable
      await d.bw(_intEnable, 0x1); // channel 0 IRQ
      await d.bw(_chSrc(0), 0x00);
      await d.bw(_chDst(0), 0x20);
      await d.bw(_chLen(0), 8); // 2 words
      await d.bw(_chCtrl(0), 0x1); // enable, type memToMem -> start

      expect(await d.runUntilIrq(), isTrue);
      expect(d.mem.readWord(0x20), equals(0xAAAA1111));
      expect(d.mem.readWord(0x24), equals(0xBBBB2222));
      await Simulator.endSimulation();
    });

    test('periph-to-mem holds the source address fixed', () async {
      final d = await _setUpDut(kind, dmaMem: [0xC0FFEE00, 0xDEADBEEF]);
      await d.bw(_ctrl, 1);
      await d.bw(_intEnable, 0x1);
      await d.bw(_chSrc(0), 0x00); // fixed source = word 0
      await d.bw(_chDst(0), 0x20);
      await d.bw(_chLen(0), 8);
      // type periphToMem (2): source stays fixed, destination increments.
      await d.bw(_chCtrl(0), 0x1 | (2 << 4));

      expect(await d.runUntilIrq(), isTrue);
      // Both destination words got the same (fixed) source word.
      expect(d.mem.readWord(0x20), equals(0xC0FFEE00));
      expect(d.mem.readWord(0x24), equals(0xC0FFEE00));
      await Simulator.endSimulation();
    });

    test('a write with no byte selected changes nothing', () async {
      final d = await _setUpDut(kind, dmaMem: [0xAAAA1111, 0xBBBB2222]);
      // intEnable is channels wide (2 bits here); the other registers are
      // full 32-bit words.
      await d.bw(_intEnable, 0x3);
      await d.bw(_chSrc(0), 0x11223344);

      // sel=0: none of these may take effect, including the channel start.
      await d.bus.write(_intEnable, 0x0, sel: 0x0);
      await d.bus.write(_chSrc(0), 0xffffffff, sel: 0x0);
      await d.bus.write(_chCtrl(0), 0x1, sel: 0x0);

      expect(await d.br(_intEnable), equals(0x3));
      expect(await d.br(_chSrc(0)), equals(0x11223344));
      expect(await d.br(_chStatus(0)) & 0x1, equals(0)); // not busy: no start
      await Simulator.endSimulation();
    });
  });
}

void _dataWidth64Tests(HarborFabricKind kind) {
  group(
    'HarborDmaController transfer engine at dataWidth 64 (${kind.name})',
    () {
      tearDown(() async {
        await Simulator.reset();
      });

      test('mem-to-mem moves 8 bytes per beat, not 4', () async {
        // Source beat 0 (byte 0x00), destination beat 4 (byte 0x20). CH_LEN is
        // 16 bytes: at dataWidth:64 that is 2 beats of 8 bytes, versus 4 beats
        // of 4 bytes at the default dataWidth:32.
        final d = await _setUpDut(
          kind,
          dataWidth: 64,
          dmaMem: [0x1111111122222222, 0x3333333344444444],
        );
        await d.bw(_ctrl, 1); // global enable
        await d.bw(_intEnable, 0x1); // channel 0 IRQ
        await d.bw(_chSrc(0), 0x00);
        await d.bw(_chDst(0), 0x20);
        await d.bw(_chLen(0), 16); // 2 beats of 8 bytes
        await d.bw(_chCtrl(0), 0x1); // enable, type memToMem -> start

        expect(await d.runUntilIrq(), isTrue);
        final writes = d.mem.log.where((e) => e.$1).length;
        expect(writes, equals(2));
        expect(d.mem.readWord(0x20), equals(0x1111111122222222));
        expect(d.mem.readWord(0x28), equals(0x3333333344444444));
        await Simulator.endSimulation();
      });
    },
  );
}

void _peripheralStreamTests(HarborFabricKind kind) {
  group('HarborDmaController peripheral stream source (${kind.name})', () {
    tearDown(() async {
      await Simulator.reset();
    });

    test(
      'writes a stream of words into memory and completes on s_last',
      () async {
        final d = await _setUpDut(
          kind,
          source: HarborDmaSource.peripheralStream,
        );
        final sData = d.top.input('s_data');
        final sValid = d.top.input('s_valid');
        final sLast = d.top.input('s_last');
        final sReady = d.dma.output('s_ready');

        await d.bw(_ctrl, 1); // global enable
        await d.bw(_intEnable, 0x1); // channel 0 IRQ
        await d.bw(_chDst(0), 0x20); // destination word 8
        // CH_LEN covers 4 words. The stream only sends 3 and ends on s_last,
        // proving s_last (not CH_LEN) ends the transfer here.
        await d.bw(_chLen(0), 16);
        // enable, type periphToMem (2) -> start
        await d.bw(_chCtrl(0), 0x1 | (2 << 4));

        final words = [0x11111111, 0x22222222, 0x33333333];
        for (var i = 0; i < words.length; i++) {
          // Honor s_ready backpressure: only present a word once the
          // controller signals it can accept one.
          while (sReady.value.toInt() != 1) {
            await d.clk.nextPosedge;
          }
          sData.inject(words[i]);
          sValid.inject(1);
          sLast.inject(i == words.length - 1 ? 1 : 0);
          await d.clk.nextPosedge;
          sValid.inject(0);
          sLast.inject(0);
        }

        expect(await d.runUntilIrq(), isTrue);
        expect(d.mem.readWord(0x20), equals(0x11111111));
        expect(d.mem.readWord(0x24), equals(0x22222222));
        expect(d.mem.readWord(0x28), equals(0x33333333));
        // Only the 3 streamed words landed. s_last ended the transfer early.
        expect(d.mem.readWord(0x2c), equals(0));
        await Simulator.endSimulation();
      },
    );
  });
}

void _targetSdramTests(HarborFabricKind kind) {
  group('HarborDmaController target=sdram address clamp (${kind.name})', () {
    // The allowed memory window: matches the brief's example (0x8000_0000,
    // 256 MiB).
    const memRange = BusAddressRange(0x80000000, 0x10000000);

    tearDown(() async {
      await Simulator.reset();
    });

    test(
      'in-range destination writes normally and leaves error clear',
      () async {
        final d = await _setUpDut(
          kind,
          target: HarborDmaTarget.sdram,
          memRange: memRange,
          dmaMem: [0xAAAA1111, 0xBBBB2222],
        );
        await d.bw(_ctrl, 1); // global enable
        await d.bw(_intEnable, 0x1); // channel 0 IRQ
        await d.bw(_chSrc(0), 0x00);
        await d.bw(_chDst(0), 0x80000020); // inside [0x8000_0000, 0x9000_0000)
        await d.bw(_chLen(0), 8); // 2 words
        await d.bw(_chCtrl(0), 0x1); // enable, type memToMem -> start

        expect(await d.runUntilIrq(), isTrue);
        final writes = d.mem.log.where((e) => e.$1).length;
        expect(writes, equals(2));
        expect(d.mem.readWord(0x80000020), equals(0xAAAA1111));
        expect(d.mem.readWord(0x80000024), equals(0xBBBB2222));

        final status = await d.br(_chStatus(0));
        expect(status & 0x4, equals(0)); // CH_STATUS.error clear
        await Simulator.endSimulation();
      },
    );

    test(
      'out-of-range destination sets CH_STATUS.error and writes nothing',
      () async {
        final d = await _setUpDut(
          kind,
          target: HarborDmaTarget.sdram,
          memRange: memRange,
          dmaMem: [0xAAAA1111, 0xBBBB2222],
        );
        await d.bw(_ctrl, 1); // global enable
        await d.bw(_intEnable, 0x1); // channel 0 IRQ
        await d.bw(_chSrc(0), 0x00);
        await d.bw(_chDst(0), 0x10000000); // outside the memRange window
        await d.bw(_chLen(0), 8);
        await d.bw(_chCtrl(0), 0x1); // enable, type memToMem -> start

        await d.runUntilNotBusy(0);
        final status = await d.br(_chStatus(0));
        expect(status & 0x4, equals(0x4)); // CH_STATUS.error set
        expect(status & 0x2, equals(0)); // CH_STATUS.complete stays clear
        final writes = d.mem.log.where((e) => e.$1).length;
        expect(writes, equals(0)); // no master write at all
        await Simulator.endSimulation();
      },
    );
  });
}

/// New fabric-port tests: multi-beat copies on both data widths, address
/// stepping for the one-sided transfer types, and a slave error that must
/// not hang the engine.
void _memoryWaistTests(HarborFabricKind kind) {
  group('HarborDmaController memory waist (${kind.name})', () {
    tearDown(() async {
      await Simulator.reset();
    });

    for (final dataWidth in [32, 64]) {
      test('memToMem copies 16 beats at dataWidth $dataWidth', () async {
        final busBytes = dataWidth ~/ 8;
        final beats = 16;
        final src = [for (var i = 0; i < beats; i++) 0x1000 + i];
        final d = await _setUpDut(kind, dataWidth: dataWidth, dmaMem: src);
        final dstBase = beats * busBytes; // just past the source region

        await d.bw(_ctrl, 1);
        await d.bw(_intEnable, 0x1);
        await d.bw(_chSrc(0), 0x00);
        await d.bw(_chDst(0), dstBase);
        await d.bw(_chLen(0), beats * busBytes);
        await d.bw(_chCtrl(0), 0x1); // memToMem

        expect(await d.runUntilIrq(), isTrue);
        for (var i = 0; i < beats; i++) {
          expect(
            d.mem.readWord(dstBase + i * busBytes),
            equals(src[i]),
            reason: 'beat $i',
          );
        }
        final writes = d.mem.log.where((e) => e.$1).length;
        expect(writes, equals(beats));
        await Simulator.endSimulation();
      });
    }

    test('memToPeriph steps the source, holds the destination', () async {
      const beats = 4;
      final src = [for (var i = 0; i < beats; i++) 0x2000 + i];
      final d = await _setUpDut(kind, dmaMem: src);

      await d.bw(_ctrl, 1);
      await d.bw(_intEnable, 0x1);
      await d.bw(_chSrc(0), 0x00);
      await d.bw(_chDst(0), 0x100); // fixed destination
      await d.bw(_chLen(0), beats * 4);
      // type memToPeriph (1): source increments, destination fixed.
      await d.bw(_chCtrl(0), 0x1 | (1 << 4));

      expect(await d.runUntilIrq(), isTrue);
      // Every beat landed at the same destination word: only the last one
      // (the highest source address) is still there.
      expect(d.mem.readWord(0x100), equals(src.last));
      final writes = d.mem.log.where((e) => e.$1).length;
      expect(writes, equals(beats));
      // Every write hit the same fixed address.
      expect(d.mem.log.where((e) => e.$1).every((e) => e.$2 == 0x100), isTrue);
      await Simulator.endSimulation();
    });

    test('periphToMem steps the destination, holds the source', () async {
      final d = await _setUpDut(kind, dmaMem: [0x3000beef]);

      await d.bw(_ctrl, 1);
      await d.bw(_intEnable, 0x1);
      await d.bw(_chSrc(0), 0x00); // fixed source
      await d.bw(_chDst(0), 0x200);
      await d.bw(_chLen(0), 16); // 4 beats
      // type periphToMem (2): source fixed, destination increments.
      await d.bw(_chCtrl(0), 0x1 | (2 << 4));

      expect(await d.runUntilIrq(), isTrue);
      for (var i = 0; i < 4; i++) {
        expect(d.mem.readWord(0x200 + i * 4), equals(0x3000beef));
      }
      await Simulator.endSimulation();
    });

    test(
      'a slave read error sets CH_STATUS.error for the channel with no hang',
      () async {
        final dma = HarborDmaController(
          baseAddress: 0x30000000,
          channels: 2,
          fabricKind: kind,
        );
        final cfg = HarborMemoryWaistConfig(
          addressWidth: dma.addressWidth,
          dataWidth: dma.dataWidth,
        );
        const errorAddr = 0x1000;
        final top = _ErrorMasterTop(
          dma,
          iface: 'dma',
          kind: kind,
          config: cfg,
          errorAddr: errorAddr,
        );
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        top.input('clk').srcConnection! <= clk;
        top.input('reset').srcConnection! <= reset;
        final bus = RegBus.attach(top, clk);
        await top.build();
        bus.idle();

        reset.inject(1);
        Simulator.setMaxSimTime(200000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;

        await bus.write(_ctrl, 1);
        await bus.write(_chSrc(0), errorAddr); // read fails immediately
        await bus.write(_chDst(0), 0x40);
        await bus.write(_chLen(0), 4);
        await bus.write(_chCtrl(0), 0x1);

        var stopped = false;
        for (var i = 0; i < 4000; i++) {
          final status = await bus.read(_chStatus(0));
          if (status & 0x1 == 0) {
            stopped = true;
            break;
          }
          await clk.nextPosedge;
        }
        expect(stopped, isTrue);
        final status = await bus.read(_chStatus(0));
        expect(status & 0x4, equals(0x4)); // CH_STATUS.error
        expect(status & 0x2, equals(0)); // never completes
        await Simulator.endSimulation();
      },
    );

    test(
      'a slave write error sets CH_STATUS.error for the channel with no hang',
      () async {
        final dma = HarborDmaController(
          baseAddress: 0x30000000,
          channels: 2,
          fabricKind: kind,
        );
        final cfg = HarborMemoryWaistConfig(
          addressWidth: dma.addressWidth,
          dataWidth: dma.dataWidth,
        );
        const errorAddr = 0x1000;
        final top = _ErrorMasterTop(
          dma,
          iface: 'dma',
          kind: kind,
          config: cfg,
          errorAddr: errorAddr,
        );
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        top.input('clk').srcConnection! <= clk;
        top.input('reset').srcConnection! <= reset;
        final bus = RegBus.attach(top, clk);
        await top.build();
        bus.idle();

        reset.inject(1);
        Simulator.setMaxSimTime(200000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;

        await bus.write(_ctrl, 1);
        await bus.write(_chSrc(0), 0x00); // read succeeds
        await bus.write(_chDst(0), errorAddr); // write fails
        await bus.write(_chLen(0), 4);
        await bus.write(_chCtrl(0), 0x1);

        var stopped = false;
        for (var i = 0; i < 4000; i++) {
          final status = await bus.read(_chStatus(0));
          if (status & 0x1 == 0) {
            stopped = true;
            break;
          }
          await clk.nextPosedge;
        }
        expect(stopped, isTrue);
        final status = await bus.read(_chStatus(0));
        expect(status & 0x4, equals(0x4)); // CH_STATUS.error
        expect(status & 0x2, equals(0)); // never completes
        await Simulator.endSimulation();
      },
    );
  });
}
