import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/mem_target.dart';

void main() {
  tearDown(() async => Simulator.reset());

  for (final kind in HarborFabricKind.values) {
    test('elaborates with a ${kind.name} local memory manager', () async {
      final dma = HarborPcieDma(
        clk: Logic(),
        reset: Logic(),
        completerId: Logic(width: 16),
        rxData: Logic(width: 64),
        rxValid: Logic(),
        rxLast: Logic(),
        rxUser: Logic(width: 22),
        txReady: Logic(),
        fabricKind: kind,
      );
      await dma.build();
      expect(dma.memory.kind, kind);
    });
  }

  test('returns the BAR identifier in host byte order', () async {
    final fixture = await _Fixture.create();

    await fixture.barRead(HarborPcieDma.registerIdentifier);
    expect(fixture.txValid.value.toInt(), 1);
    expect(
      fixture.txData.value.toBigInt(),
      BigInt.parse('020000044a000001', radix: 16),
    );
    await fixture.clk.nextPosedge;
    expect(fixture.txLast.value.toInt(), 1);
    expect(fixture.txData.value.toBigInt() >> 32, BigInt.from(0x414d4448));
    await Simulator.endSimulation();
  });

  test('moves a host DWORD into local memory', () async {
    final fixture = await _Fixture.create();
    await fixture.barWrite(HarborPcieDma.registerHostAddressLow, 0x1000);
    await fixture.barWrite(HarborPcieDma.registerHostAddressHigh, 0);
    await fixture.barWrite(HarborPcieDma.registerLocalAddressLow, 0x80);
    await fixture.barWrite(HarborPcieDma.registerLocalAddressHigh, 0);
    await fixture.barWrite(HarborPcieDma.registerLengthDwords, 1);
    await fixture.barWrite(
      HarborPcieDma.registerControl,
      HarborPcieDma.controlStart,
    );

    expect(fixture.txData.value.toInt() & 0xffffffff, 0x20000001);
    expect(
      (fixture.txData.value.toBigInt() >> 40) & BigInt.from(0xff),
      BigInt.from(0x41),
    );
    await fixture.clk.nextPosedge;
    expect(fixture.txLast.value.toInt(), 1);
    expect(fixture.txData.value.toInt(), 0x100000000000);
    await fixture.clk.nextPosedge;

    await fixture.completion(tag: 0x41, data: 0x11223344);
    expect(await fixture.waitForDone(), isTrue);
    expect(fixture.memory.readWord(0x80), 0x11223344);
    expect(fixture.error.value.toInt(), 0);
    await Simulator.endSimulation();
  });

  test('moves a local DWORD to the host and fences the write', () async {
    final fixture = await _Fixture.create();
    fixture.memory.writeWord(0x40, 0xdeadbeef);
    fixture.memory.writeWord(0x44, 0x12345678);
    await fixture.barWrite(HarborPcieDma.registerHostAddressLow, 0x2000);
    await fixture.barWrite(HarborPcieDma.registerHostAddressHigh, 0);
    await fixture.barWrite(HarborPcieDma.registerLocalAddressLow, 0x40);
    await fixture.barWrite(HarborPcieDma.registerLocalAddressHigh, 0);
    await fixture.barWrite(HarborPcieDma.registerLengthDwords, 2);
    await fixture.barWrite(
      HarborPcieDma.registerControl,
      HarborPcieDma.controlStart | HarborPcieDma.controlDeviceToHost,
    );

    final beats = <BigInt>[];
    for (var cycle = 0; cycle < 150 && beats.length < 8; cycle++) {
      if (fixture.txValid.value.toBool()) {
        beats.add(fixture.txData.value.toBigInt());
      }
      await fixture.clk.nextPosedge;
    }
    expect(beats, hasLength(8));
    expect(beats[0] & BigInt.from(0xffffffff), BigInt.from(0x60000001));
    expect(beats[1], BigInt.parse('0000200000000000', radix: 16));
    expect(beats[2], BigInt.from(0xefbeadde));
    expect(beats[3] & BigInt.from(0xffffffff), BigInt.from(0x60000001));
    expect(beats[4], BigInt.parse('0000200400000000', radix: 16));
    expect(beats[5], BigInt.from(0x78563412));
    expect(beats[6] & BigInt.from(0xffffffff), BigInt.from(0x20000001));
    expect((beats[6] >> 40) & BigInt.from(0xff), BigInt.from(0x43));
    expect(beats[7], BigInt.parse('0000200400000000', radix: 16));
    expect(fixture.done.value.toInt(), 0);

    await fixture.completion(tag: 0x43, data: 0xdeadbeef);
    expect(await fixture.waitForDone(), isTrue);
    expect(fixture.error.value.toInt(), 0);
    await Simulator.endSimulation();
  });

  test('serves the info words above the registers', () async {
    const words = [0x47444556, 1, 0x5a5a1234];
    final fixture = await _Fixture.create(infoWords: words);

    for (var i = 0; i < words.length; i++) {
      expect(
        await fixture.readWord((HarborPcieDma.infoFirstWord + i) * 4),
        words[i],
        reason: 'word $i',
      );
    }
    // The engine keeps its own registers, which the aperture sits above.
    expect(
      await fixture.readWord(HarborPcieDma.registerIdentifier),
      HarborPcieDma.identifier,
    );
    await Simulator.endSimulation();
  });

  test('a word past the end of the info words reads zero', () async {
    final fixture = await _Fixture.create(infoWords: const [0x47444556]);
    expect(await fixture.readWord((HarborPcieDma.infoFirstWord + 1) * 4), 0);
    await Simulator.endSimulation();
  });

  test('two different word lists are two definitions', () {
    HarborPcieDma build(List<int> words) => HarborPcieDma(
      clk: Logic(),
      reset: Logic(),
      completerId: Logic(width: 16),
      rxData: Logic(width: 64),
      rxValid: Logic(),
      rxLast: Logic(),
      rxUser: Logic(width: 22),
      txReady: Logic(),
      infoWords: words,
    );

    final empty = build(const []).definitionName;
    final one = build(const [1]).definitionName;
    final other = build(const [2]).definitionName;
    expect(one, isNot(empty));
    // Same length, different contents. A count alone would collide here.
    expect(one, isNot(other));
  });

  test('more words than the aperture holds is refused', () {
    expect(
      () => HarborPcieDma(
        clk: Logic(),
        reset: Logic(),
        completerId: Logic(width: 16),
        rxData: Logic(width: 64),
        rxValid: Logic(),
        rxLast: Logic(),
        rxUser: Logic(width: 22),
        txReady: Logic(),
        infoWords: List<int>.filled(HarborPcieDma.infoMaxWords + 1, 0),
      ),
      throwsA(isA<RangeError>()),
    );
  });
}

class _Fixture {
  final HarborPcieDma dma;
  final MasterTop top;
  final Logic clk;
  final Logic rxData;
  final Logic rxValid;
  final Logic rxLast;
  final Logic rxUser;
  final Logic txReady;
  final BeatMemory memory;

  _Fixture({
    required this.dma,
    required this.top,
    required this.clk,
    required this.rxData,
    required this.rxValid,
    required this.rxLast,
    required this.rxUser,
    required this.txReady,
    required this.memory,
  });

  Logic get txData => top.output('tx_data');
  Logic get txValid => top.output('tx_valid');
  Logic get txLast => top.output('tx_last');
  Logic get done => top.output('done');
  Logic get error => top.output('error');

  static Future<_Fixture> create({
    HarborFabricKind kind = HarborFabricKind.wishbone,
    List<int> infoWords = const [],
  }) async {
    final dma = HarborPcieDma(
      clk: Logic(),
      reset: Logic(),
      completerId: Logic(width: 16),
      rxData: Logic(width: 64),
      rxValid: Logic(),
      rxLast: Logic(),
      rxUser: Logic(width: 22),
      txReady: Logic(),
      fabricKind: kind,
      localAddressWidth: 32,
      infoWords: infoWords,
    );
    const config = HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32);
    final top = MasterTop(dma, iface: 'memory', kind: kind, config: config);
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic();
    final completerId = Logic(width: 16);
    final rxData = Logic(width: 64);
    final rxValid = Logic();
    final rxLast = Logic();
    final rxUser = Logic(width: 22);
    final txReady = Logic();
    top.input('clk').srcConnection! <= clk;
    top.input('reset').srcConnection! <= reset;
    top.input('completer_id').srcConnection! <= completerId;
    top.input('rx_data').srcConnection! <= rxData;
    top.input('rx_valid').srcConnection! <= rxValid;
    top.input('rx_last').srcConnection! <= rxLast;
    top.input('rx_user').srcConnection! <= rxUser;
    top.input('tx_ready').srcConnection! <= txReady;
    final memory = BeatMemory(top, clk);
    await top.build();

    reset.inject(1);
    completerId.inject(0x0200);
    rxData.inject(0);
    rxValid.inject(0);
    rxLast.inject(0);
    rxUser.inject(0);
    txReady.inject(1);
    Simulator.setMaxSimTime(100000);
    unawaited(Simulator.run());
    memory.start();
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;
    return _Fixture(
      dma: dma,
      top: top,
      clk: clk,
      rxData: rxData,
      rxValid: rxValid,
      rxLast: rxLast,
      rxUser: rxUser,
      txReady: txReady,
      memory: memory,
    );
  }

  int _swapBytes(int value) =>
      ((value & 0xff) << 24) |
      ((value & 0xff00) << 8) |
      ((value >> 8) & 0xff00) |
      ((value >> 24) & 0xff);

  Future<void> _packet(int header, int second, {required int user}) async {
    rxData.inject(BigInt.from(header));
    rxUser.inject(user);
    rxValid.inject(1);
    rxLast.inject(0);
    await clk.nextPosedge;
    rxData.inject(BigInt.from(second));
    rxLast.inject(1);
    await clk.nextPosedge;
    rxValid.inject(0);
    rxLast.inject(0);
    rxUser.inject(0);
  }

  Future<void> barWrite(int address, int data) => _packet(
    (0x0000000f << 32) | 0x40000001,
    (_swapBytes(data) << 32) | address,
    user: 1 << 2,
  );

  Future<void> barRead(int address) =>
      _packet((0x1234560f << 32) | 0x00000001, address, user: 1 << 2);

  Future<void> completion({required int tag, required int data}) => _packet(
    (0x02000004 << 32) | 0x4a000001,
    (_swapBytes(data) << 32) | (tag << 8),
    user: 0,
  );

  /// One BAR0 word, in host byte order.
  ///
  /// The completion carries the payload in the second beat, byte swapped on
  /// the wire, so this undoes both.
  Future<int> readWord(int address) async {
    await barRead(address);
    await clk.nextPosedge;
    final wire = ((txData.value.toBigInt() >> 32) & BigInt.from(0xffffffff))
        .toInt();
    return _swapBytes(wire);
  }

  Future<bool> waitForDone() async {
    for (var cycle = 0; cycle < 100; cycle++) {
      if (done.value.toBool()) return true;
      await clk.nextPosedge;
    }
    return false;
  }
}
