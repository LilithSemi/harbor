import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

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

  test('rejects a 128 bit stream', () {
    expect(
      () => HarborPcieOptionRom(
        clk: Logic(),
        reset: Logic(),
        completerId: Logic(width: 16),
        rx: HarborPcieStream(width: 128),
        tx: HarborPcieStream(width: 128),
      ),
      throwsArgumentError,
    );
  });
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
