import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../util/pcie_host_model.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test('serves a one-DWORD expansion ROM read through its bus', () async {
    final fixture = await _Fixture.create();

    await fixture.request(address: 0, length: 1);
    expect(fixture.memory.bus.stb.value.toInt(), 1);
    expect(fixture.memory.bus.addr.value.toInt(), 0xc00000);
    expect(fixture.option.output('tx_valid').value.toInt(), 0);

    await fixture.clk.nextPosedge;
    expect(fixture.option.output('tx_valid').value.toInt(), 0);
    await fixture.ackRead(0xcb08aa55);

    expect(fixture.option.output('tx_valid').value.toInt(), 1);
    expect(fixture.option.output('tx_data').value.toInt(), 0x020000044a000001);
    await fixture.clk.nextPosedge;

    expect(fixture.option.output('tx_valid').value.toInt(), 1);
    expect(fixture.option.output('tx_last').value.toInt(), 1);
    expect(fixture.option.output('tx_keep').value.toInt(), 0xff);
    expect(fixture.option.output('tx_data').value.toInt(), 0x55aa08cb12345600);
    await fixture.clk.nextPosedge;

    expect(fixture.option.output('rom_reads').value.toInt(), 1);
    expect(fixture.option.output('completions').value.toInt(), 1);
    await Simulator.endSimulation();
  });

  test('reads sequential bus words and honors TX backpressure', () async {
    final fixture = await _Fixture.create();

    await fixture.request(address: 0x40, length: 3);
    await fixture.ackRead(0x03020100, expectedAddress: 0xc00040);

    fixture.txReady.inject(0);
    final header = fixture.option.output('tx_data').value.toInt();
    await fixture.clk.nextPosedge;
    await fixture.clk.nextPosedge;
    expect(fixture.option.output('tx_valid').value.toInt(), 1);
    expect(fixture.option.output('tx_data').value.toInt(), header);

    fixture.txReady.inject(1);
    await fixture.clk.nextPosedge;
    expect(fixture.option.output('tx_data').value.toInt(), 0x0001020312345640);
    expect(fixture.option.output('tx_last').value.toInt(), 0);
    await fixture.clk.nextPosedge;

    await fixture.ackRead(0x07060504, expectedAddress: 0xc00044);
    await fixture.ackRead(0x0b0a0908, expectedAddress: 0xc00048);
    expect(fixture.option.output('tx_data').value.toInt(), 0x08090a0b04050607);
    expect(fixture.option.output('tx_last').value.toInt(), 1);
    expect(fixture.option.output('tx_keep').value.toInt(), 0xff);
    await fixture.clk.nextPosedge;

    expect(fixture.option.output('completions').value.toInt(), 1);
    await Simulator.endSimulation();
  });

  test('splits completions at the 64-byte read boundary', () async {
    final fixture = await _Fixture.create();

    await fixture.request(address: 0x38, length: 4);
    await fixture.ackRead(0x03020100, expectedAddress: 0xc00038);
    expect(fixture.option.output('tx_data').value.toInt(), 0x020000104a000002);
    await fixture.clk.nextPosedge;
    expect(fixture.option.output('tx_data').value.toInt(), 0x0001020312345638);
    expect(fixture.option.output('tx_last').value.toInt(), 0);
    await fixture.clk.nextPosedge;

    await fixture.ackRead(0x07060504, expectedAddress: 0xc0003c);
    expect(fixture.option.output('tx_last').value.toInt(), 1);
    expect(fixture.option.output('tx_keep').value.toInt(), 0x0f);
    expect(fixture.option.output('tx_data').value.toInt(), 0x04050607);
    await fixture.clk.nextPosedge;
    await fixture.clk.nextPosedge;

    await fixture.ackRead(0x0b0a0908, expectedAddress: 0xc00040);
    expect(fixture.option.output('tx_data').value.toInt(), 0x020000084a000002);
    await fixture.clk.nextPosedge;
    expect(fixture.option.output('tx_data').value.toInt(), 0x08090a0b12345640);
    await fixture.clk.nextPosedge;
    await fixture.ackRead(0x0f0e0d0c, expectedAddress: 0xc00044);
    expect(fixture.option.output('tx_last').value.toInt(), 1);
    expect(fixture.option.output('tx_keep').value.toInt(), 0x0f);
    expect(fixture.option.output('tx_data').value.toInt(), 0x0c0d0e0f);
    await fixture.clk.nextPosedge;

    expect(fixture.option.output('rom_reads').value.toInt(), 1);
    expect(fixture.option.output('completions').value.toInt(), 2);
    await Simulator.endSimulation();
  });

  test('decodes a zero length field as 1024 DWORDs', () async {
    final fixture = await _Fixture.create();

    await fixture.request(address: 0x3c, length: 0);
    await fixture.ackRead(0x03020100, expectedAddress: 0xc0003c);
    expect(fixture.option.output('tx_data').value.toInt(), 0x020000004a000001);
    await fixture.clk.nextPosedge;
    expect(fixture.option.output('tx_last').value.toInt(), 1);
    await fixture.clk.nextPosedge;
    await fixture.clk.nextPosedge;

    await fixture.ackRead(0x07060504, expectedAddress: 0xc00040);
    expect(fixture.option.output('tx_data').value.toInt(), 0x02000ffc4a000010);
    await Simulator.endSimulation();
  });

  test('uses a 128-byte boundary when the core selects it', () async {
    final fixture = await _Fixture.create(rcb128: true);

    await fixture.request(address: 0x38, length: 3);
    await fixture.ackRead(0x03020100, expectedAddress: 0xc00038);
    expect(fixture.option.output('tx_data').value.toInt(), 0x0200000c4a000003);
    await Simulator.endSimulation();
  });

  test('ignores a read that did not hit the expansion ROM BAR', () async {
    final fixture = await _Fixture.create();

    await fixture.request(address: 0, length: 1, barHit: false);
    expect(fixture.memory.bus.stb.value.toInt(), 0);
    expect(fixture.option.output('tx_valid').value.toInt(), 0);
    expect(fixture.option.output('rom_reads').value.toInt(), 0);
    await Simulator.endSimulation();
  });

  for (final kind in HarborFabricKind.values) {
    test(
      'connects directly to HarborSpiFlashController (${kind.name})',
      () async {
        final chain = _SpiChain(kind);
        await chain.build();
        expect(chain.option.memory.kind, kind);
        expect(chain.flash.bus.kind, kind);
      },
    );
  }

  test('rejects a memory range that is too narrow', () {
    expect(
      () => HarborPcieOptionRom(
        clk: Logic(),
        reset: Logic(),
        completerId: Logic(width: 16),
        rx: HarborPcieStream(width: 64),
        tx: HarborPcieStream(width: 64),
        romSize: 256 * 1024,
        memoryOffset: 0xc00000,
        memoryAddressWidth: 20,
      ),
      throwsRangeError,
    );
  });

  test('rejects different rx and tx widths', () {
    expect(
      () => HarborPcieOptionRom(
        clk: Logic(),
        reset: Logic(),
        completerId: Logic(width: 16),
        rx: HarborPcieStream(width: 128),
        tx: HarborPcieStream(width: 64),
      ),
      throwsArgumentError,
    );
  });

  for (final width in [64, 128]) {
    test('random reads match the ROM at RCB 64 and 128, W$width', () async {
      final bench = await _StreamBench.create(width);
      final random = Random(width);
      for (var i = 0; i < 40; i++) {
        final rcb128 = random.nextBool();
        bench.rcb128.inject(rcb128 ? 1 : 0);
        final lengthDw = 1 + random.nextInt(64);
        final offset = random.nextInt(_romBytes ~/ 4 - lengthDw) * 4;
        final firstBe = 1 + random.nextInt(15);
        final request = PcieTlp.memRead(
          address: _romBase + offset,
          lengthDw: lengthDw,
          tag: i,
          requesterId: 0x0100,
          firstBe: firstBe,
          lastBe: lengthDw == 1 ? 0 : 1 + random.nextInt(15),
          tc: random.nextInt(8),
          attr: random.nextInt(4),
        );
        final before = bench.sink.received.length;
        await bench.driver.send(request, user: HarborPcieStream.userRom);
        final (begin, end) = pcieReadSpan(request);
        await bench.waitForBytes(before, end - begin);
        final errors = pcieCheckReadCompletions(
          request,
          bench.sink.received.sublist(before),
          rcb: rcb128 ? 128 : 64,
          maxPayload: 4096,
          completerId: 0x0200,
          read: _romRead,
        );
        if (errors.isNotEmpty) fail(errors.join('\n'));
      }
      // A read without the ROM hit and a write are dropped.
      final before = bench.sink.received.length;
      await bench.driver.send(
        PcieTlp.memRead(address: _romBase, lengthDw: 4),
        user: HarborPcieStream.userBar0,
      );
      await bench.driver.send(
        PcieTlp.memWrite(address: _romBase, data: List.filled(16, 1)),
        user: HarborPcieStream.userRom,
      );
      for (var i = 0; i < 200; i++) {
        await bench.clk.nextPosedge;
      }
      expect(bench.sink.received.length, before);
      expect(bench.top.output('rom_reads').value.toInt(), 40);
      await Simulator.endSimulation();
    });
  }
}

const _romBase = 0xf7100000;
const _romBytes = 4096;
const _romOffset = 0x10000;

int _romWord(int byteAddress) =>
    (byteAddress * 0x01030507 + 0x55aa1234) & 0xffffffff;

/// Memory order bytes of the ROM at host addresses.
Uint8List _romRead(int address, int length) => Uint8List.fromList([
  for (var i = 0; i < length; i++)
    () {
      final a = (address + i) % _romBytes;
      return (_romWord(_romOffset + (a & ~3)) >> (8 * (a & 3))) & 0xff;
    }(),
]);

/// The ROM on driven and sampled streams, with a memory that answers after
/// a random delay.
class _StreamBench {
  final _StreamTop top;
  final Logic clk;
  final Logic rcb128;
  final PcieStreamDriver driver;
  final PcieStreamSink sink;

  _StreamBench._(this.top, this.clk, this.rcb128, this.driver, this.sink);

  static Future<_StreamBench> create(int width) async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic();
    final rcb128 = Logic();
    final rx = HarborPcieStream(width: width, name: 'rx');
    final tx = HarborPcieStream(width: width, name: 'tx');
    final top = _StreamTop(
      clk: clk,
      reset: reset,
      rcb128: rcb128,
      rx: rx,
      tx: tx,
    );
    await top.build();
    final ack = Logic();
    final data = Logic(width: 32);
    top.input('mem_ack').srcConnection! <= ack;
    top.input('mem_data').srcConnection! <= data;
    ack.inject(0);
    data.inject(0);
    final random = Random(width + 5);
    var wait = -1;
    clk.negedge.listen((_) {
      final stb = top.output('mem_stb').value;
      if (ack.value.toBool() || !stb.isValid || !stb.toBool()) {
        ack.inject(0);
        wait = -1;
        return;
      }
      if (wait < 0) wait = random.nextInt(3);
      if (wait-- > 0) return;
      data.inject(_romWord(top.output('mem_addr').value.toInt()));
      ack.inject(1);
    });
    final driver = PcieStreamDriver(clk: clk, stream: rx, seed: width);
    final sink = PcieStreamSink(clk: clk, stream: tx, seed: width + 1);
    reset.inject(1);
    rcb128.inject(0);
    Simulator.setMaxSimTime(100000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;
    sink.start();
    return _StreamBench._(top, clk, rcb128, driver, sink);
  }

  /// Waits until the completions after [from] carry [bytes] bytes.
  Future<void> waitForBytes(int from, int bytes) async {
    for (var i = 0; i < 20000; i++) {
      final got = sink.received.skip(from).toList();
      if (got.isNotEmpty) {
        final last = got.last;
        if (last.lengthDw * 4 - (last.lowerAddress & 3) >= last.byteCount) {
          return;
        }
      }
      await clk.nextPosedge;
    }
    fail('the ROM did not complete $bytes bytes');
  }
}

class _StreamTop extends BridgeModule {
  _StreamTop({
    required Logic clk,
    required Logic reset,
    required Logic rcb128,
    required HarborPcieStream rx,
    required HarborPcieStream tx,
  }) : super('PcieOptionRomStreamTop_W${rx.width}') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    rcb128 = addInput('rcb_128', rcb128);
    final rxi = HarborPcieStream.addSink(this, rx);
    final txi = HarborPcieStream.addSource(this, tx);
    final romRx = HarborPcieStream(width: rx.width, name: 'rom_rx');
    final romTx = HarborPcieStream(width: rx.width, name: 'rom_tx');
    for (final (a, b) in [
      (romRx.data, rxi.data),
      (romRx.keep, rxi.keep),
      (romRx.last, rxi.last),
      (romRx.valid, rxi.valid),
      (romRx.user, rxi.user),
      (txi.data, romTx.data),
      (txi.keep, romTx.keep),
      (txi.last, romTx.last),
      (txi.valid, romTx.valid),
      (txi.user, romTx.user),
    ]) {
      a <= b;
    }
    rxi.ready <= romRx.ready;
    romTx.ready <= txi.ready;
    final rom = addSubModule(
      HarborPcieOptionRom(
        clk: clk,
        reset: reset,
        completerId: Const(0x0200, width: 16),
        rx: romRx,
        tx: romTx,
        romSize: _romBytes,
        memoryOffset: _romOffset,
        memoryAddressWidth: 20,
        readCompletionBoundary128: rcb128,
      ),
    );
    final memory = addSubModule(
      _ReadMemory(
        clk: clk,
        reset: reset,
        data: addInput('mem_data', Logic(width: 32), width: 32),
        allow: addInput('mem_ack', Logic()),
        addressWidth: 20,
      ),
    );
    connectInterfaces(rom.interface('memory'), memory.interface('bus'));
    addOutput('mem_stb') <= memory.output('stb');
    addOutput('mem_addr', width: 20) <= memory.output('addr');
    addOutput('rom_reads', width: 16) <= rom.output('rom_reads');
  }
}

class _Fixture {
  final HarborPcieOptionRom option;
  final _ReadMemory memory;
  final Logic clk;
  final Logic rxData;
  final Logic rxValid;
  final Logic rxLast;
  final Logic rxUser;
  final Logic txReady;
  final Logic readData;
  final Logic readAllow;

  _Fixture._({
    required this.option,
    required this.memory,
    required this.clk,
    required this.rxData,
    required this.rxValid,
    required this.rxLast,
    required this.rxUser,
    required this.txReady,
    required this.readData,
    required this.readAllow,
  });

  static Future<_Fixture> create({bool rcb128 = false}) async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic();
    final completerId = Logic(width: 16);
    final rxData = Logic(width: 64);
    final rxValid = Logic();
    final rxLast = Logic();
    final rxUser = Logic(width: 22);
    final txReady = Logic();
    final readData = Logic(width: 32);
    final readAllow = Logic();
    final harness = _Harness(
      clk: clk,
      reset: reset,
      completerId: completerId,
      rxData: rxData,
      rxValid: rxValid,
      rxLast: rxLast,
      rxUser: rxUser,
      txReady: txReady,
      readData: readData,
      readAllow: readAllow,
      rcb128: rcb128,
    );
    await harness.build();

    reset.inject(1);
    completerId.inject(0x0200);
    rxData.inject(0);
    rxValid.inject(0);
    rxLast.inject(0);
    rxUser.inject(0);
    txReady.inject(1);
    readData.inject(0);
    readAllow.inject(0);
    Simulator.setMaxSimTime(10000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    return _Fixture._(
      option: harness.option,
      memory: harness.memory,
      clk: clk,
      rxData: rxData,
      rxValid: rxValid,
      rxLast: rxLast,
      rxUser: rxUser,
      txReady: txReady,
      readData: readData,
      readAllow: readAllow,
    );
  }

  Future<void> request({
    required int address,
    required int length,
    bool barHit = true,
  }) async {
    final header =
        (BigInt.from(0x1234) << 48) |
        (BigInt.from(0x56) << 40) |
        (BigInt.from(length == 1 ? 0 : 0xf) << 36) |
        (BigInt.from(0xf) << 32) |
        BigInt.from(length);
    rxData.inject(header);
    rxUser.inject(barHit ? 1 << 8 : 0);
    rxValid.inject(1);
    rxLast.inject(0);
    await clk.nextPosedge;

    rxData.inject(address);
    rxLast.inject(1);
    await clk.nextPosedge;
    rxValid.inject(0);
    rxLast.inject(0);
    rxUser.inject(0);
    await clk.nextPosedge;
  }

  Future<void> ackRead(int data, {int? expectedAddress}) async {
    expect(memory.bus.stb.value.toInt(), 1);
    if (expectedAddress != null) {
      expect(memory.bus.addr.value.toInt(), expectedAddress);
    }
    readData.inject(data);
    readAllow.inject(1);
    await clk.nextPosedge;
    readAllow.inject(0);
  }
}

class _Harness extends BridgeModule {
  late final HarborPcieOptionRom option;
  late final _ReadMemory memory;

  _Harness({
    required Logic clk,
    required Logic reset,
    required Logic completerId,
    required Logic rxData,
    required Logic rxValid,
    required Logic rxLast,
    required Logic rxUser,
    required Logic txReady,
    required Logic readData,
    required Logic readAllow,
    required bool rcb128,
  }) : super('PcieOptionRomTestHarness') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    completerId = addInput('completer_id', completerId, width: 16);
    rxData = addInput('rx_data', rxData, width: 64);
    rxValid = addInput('rx_valid', rxValid);
    rxLast = addInput('rx_last', rxLast);
    rxUser = addInput('rx_user', rxUser, width: 22);
    txReady = addInput('tx_ready', txReady);
    readData = addInput('read_data', readData, width: 32);
    readAllow = addInput('read_allow', readAllow);
    final rx = HarborPcieStream(width: 64, name: 'rx');
    final tx = HarborPcieStream(width: 64, name: 'tx');
    rx.data <= rxData;
    rx.keep <= Const(0xff, width: 8);
    rx.valid <= rxValid;
    rx.last <= rxLast;
    rx.user <= rxUser;
    tx.ready <= txReady;
    option = addSubModule(
      HarborPcieOptionRom(
        clk: clk,
        reset: reset,
        completerId: completerId,
        rx: rx,
        tx: tx,
        memoryOffset: 0xc00000,
        memoryAddressWidth: 24,
        readCompletionBoundary128: Const(rcb128 ? 1 : 0),
      ),
    );
    memory = addSubModule(
      _ReadMemory(
        clk: clk,
        reset: reset,
        data: readData,
        allow: readAllow,
        addressWidth: 24,
      ),
    );
    connectInterfaces(option.interface('memory'), memory.interface('bus'));
    for (final port in [
      'rx_ready',
      'tx_data',
      'tx_keep',
      'tx_last',
      'tx_valid',
      'rom_reads',
      'completions',
    ]) {
      addOutput(port, width: option.output(port).width) <= option.output(port);
    }
  }
}

class _ReadMemory extends BridgeModule {
  late final BusSlavePort bus;

  _ReadMemory({
    required Logic clk,
    required Logic reset,
    required Logic data,
    required Logic allow,
    required int addressWidth,
  }) : super('PcieOptionRomTestMemory_A$addressWidth') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    data = addInput('data', data, width: 32);
    allow = addInput('allow', allow);
    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      kind: HarborFabricKind.wishbone,
      addressWidth: addressWidth,
      dataWidth: 32,
      clk: clk,
      reset: reset,
    );
    bus.dataOut <= data;
    bus.ack <= bus.stb & allow;
    addOutput('stb') <= bus.stb;
    addOutput('addr', width: addressWidth) <= bus.addr;
  }
}

class _SpiChain extends BridgeModule {
  late final HarborPcieOptionRom option;
  late final HarborSpiFlashController flash;

  _SpiChain(HarborFabricKind kind)
    : super('PcieOptionRomSpiChain_${kind.name}') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final clk = input('clk');
    final reset = input('reset');
    option = addSubModule(
      HarborPcieOptionRom(
        clk: clk,
        reset: reset,
        completerId: Const(0, width: 16),
        rx: _idleStream(),
        tx: _idleStream(ready: true),
        memoryOffset: 0xc00000,
        memoryAddressWidth: 24,
        fabricKind: kind,
      ),
    );
    flash = addSubModule(
      HarborSpiFlashController(
        config: const HarborSpiFlashConfig.w25q128(readAheadWords: 32),
        baseAddress: 0,
        busAddressWidth: 24,
        useStartupe2: true,
        fabricKind: kind,
      ),
    );
    flash.input('clk').srcConnection! <= clk;
    flash.input('reset').srcConnection! <= reset;
    flash.input('spi_io_in').srcConnection! <= Const(0, width: 4);
    flash.input('wr_req').srcConnection! <= Const(0);
    flash.input('wr_op').srcConnection! <= Const(0);
    flash.input('wr_addr').srcConnection! <= Const(0, width: 24);
    flash.input('wr_len').srcConnection! <= Const(0, width: 9);
    flash.input('wr_data').srcConnection! <= Const(0, width: 8);
    connectInterfaces(option.interface('memory'), flash.interface('bus'));
  }
}

HarborPcieStream _idleStream({bool ready = false}) {
  final s = HarborPcieStream(width: 64, name: 'idle');
  if (ready) {
    s.ready <= Const(1);
  } else {
    s.data <= Const(0, width: 64);
    s.keep <= Const(0, width: 8);
    s.valid <= Const(0);
    s.last <= Const(0);
    s.user <= Const(0, width: HarborPcieStream.userWidth);
  }
  return s;
}
