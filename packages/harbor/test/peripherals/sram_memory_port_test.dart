import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../bus/port/memory_harness.dart';
import '../bus/port/port_harness.dart';
import 'memory_port_bench.dart';

const _ecp5 = HarborFpgaTarget.ecp5(device: '85f', package: 'CABGA381');

String _tag(HarborDeviceTarget? t) => switch (t) {
  null => 'generic',
  HarborAsicTarget() => 'asic',
  _ => 'ecp5',
};

final _pdks = <(String, PdkProvider Function())>[
  ('sky130', () => Sky130Provider(pdkRoot: '/pdk/sky130A')),
  ('gf180mcu', () => Gf180mcuProvider(pdkRoot: '/pdk/gf180mcuD')),
];

const _config = HarborMemoryWaistConfig(
  addressWidth: 12,
  dataWidth: 32,
  idWidth: 2,
  outstanding: 2,
);

/// A requester linked to a 4 KiB [HarborSram] over the native port.
class _SramBench extends BridgeModule {
  late final HarborSram sram;

  _SramBench(HarborFabricKind kind, HarborDeviceTarget? target)
    : super('SramPortBench_${kind.name}_${_tag(target)}', name: 'top') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    sram = addSubModule(
      HarborSram(
        baseAddress: 0,
        size: 4096,
        protocol: kind,
        idWidth: _config.idWidth,
        target: target,
      ),
    );
    sram.input('clk').srcConnection! <= input('clk');
    sram.input('reset').srcConnection! <= input('reset');
    linkRequester(this, sram, _config, kind);
  }
}

void main() {
  tearDown(endAndReset);

  for (final kind in HarborFabricKind.values) {
    for (final target in [null, _ecp5]) {
      test('${kind.name} ${target == null ? 'generic' : 'ECP5'}: random '
          'bursts match a reference memory', () async {
        final s = Sim(_SramBench(kind, target));
        final check = MemoryPortCheck(
          s,
          Random(kind.index * 7 + (target == null ? 1 : 2)),
          busBytes: 4,
          idWidth: _config.idWidth,
          span: 0x1000,
        );
        Simulator.setMaxSimTime(20000000);
        await s.start();
        Simulator.setMaxSimTime(20000000);
        await check.fill();
        final bad = await check.run(
          40,
          extra: longBursts(Random(5), check.busBytes),
        );
        await s.stop();
        expect(bad, isEmpty);
      });
    }
  }

  for (final (pdkName, pdk) in _pdks) {
    test('ASIC $pdkName macro: a beat with no strobe and a 1 byte beat keep '
        'the other bytes', () async {
      final asic = HarborAsicTarget(provider: pdk(), topCell: 'top');
      final s = Sim(_SramBench(HarborFabricKind.axi4, asic));
      final check = MemoryPortCheck(
        s,
        Random(9),
        busBytes: 4,
        idWidth: _config.idWidth,
        span: 0x1000,
      );
      Burst w(int addr, int size, int strb, int data) => Burst(
        id: 1,
        write: true,
        addr: addr,
        len: 0,
        size: size,
        burst: 1,
        data: [data],
        strb: [strb],
      );
      Burst r(int addr) =>
          Burst(id: 2, write: false, addr: addr, len: 0, size: 2, burst: 1);
      await s.start();
      Simulator.setMaxSimTime(20000000);
      await check.fill();
      final bad = await check.run(
        8,
        extra: [
          w(0x100, 2, 0, 0xffffffff),
          w(0x106, 0, 0x4, 0x00ab0000),
          w(0x108, 2, 0x9, 0x11223344),
          r(0x100),
          r(0x104),
          r(0x108),
        ],
      );
      await s.stop();
      expect(bad, isEmpty);
    });
  }

  for (final (pdkName, pdk) in _pdks) {
    test('ASIC $pdkName macro pins: selected and written only when the '
        'access asks, at the PDK polarity', () async {
      final asic = HarborAsicTarget(provider: pdk(), topCell: 'top');
      final top = _SramBench(HarborFabricKind.axi4, asic);
      final s = Sim(top);
      final errors = <String>[];
      final req = WaistRequester(s, 'up', Random(2), errors: errors);
      final block = pdk().sramMacro(words: 1024, width: 32)!;
      final macro = top.sram.subModules.singleWhere(
        (m) => m.definitionName == block.properties['name'],
      );
      int at(String name) =>
          macro.input(block.pinMapping[name]!).previousValue!.toInt();
      // Every enable of both PDKs is active low.
      expect(block.activeLow, containsAll(['chipSelect', 'writeEnable']));
      final cycles = <(int, int)>[];
      s.onRise(() => cycles.add((at('chipSelect'), at('writeEnable'))));
      await s.start();
      await s.cycles(6);
      req.send(
        Burst(
          id: 0,
          write: true,
          addr: 0x40,
          len: 3,
          size: 2,
          burst: 1,
          data: [1, 2, 3, 4],
          strb: [15, 15, 15, 15],
        ),
      );
      req.send(
        Burst(
          id: 1,
          write: true,
          addr: 0x80,
          len: 0,
          size: 2,
          burst: 1,
          data: [5],
          strb: [0],
        ),
      );
      req.send(
        Burst(id: 2, write: false, addr: 0x40, len: 3, size: 2, burst: 1),
      );
      await waitUntil(s, () => req.done, limit: 2000);
      await s.cycles(6);
      await s.stop();
      expect(errors, isEmpty);
      expect(req.readResp.single.map((b) => b.$2), [1, 2, 3, 4]);
      // Idle: deselected and not writing.
      expect(cycles.take(6), everyElement((1, 1)));
      expect(cycles.skip(cycles.length - 6), everyElement((1, 1)));
      // A write enable only inside a selected cycle.
      expect(cycles.where((c) => c.$2 == 0 && c.$1 != 0), isEmpty);
      // 4 writes with lanes, each a read cycle then a write cycle. The write
      // with no lane only reads, twice. 4 reads.
      expect(cycles.where((c) => c == (0, 0)), hasLength(4));
      expect(cycles.where((c) => c.$1 == 0), hasLength(4 * 2 + 2 + 4));
    });
  }

  test('definitionName carries the kind, depth, crossing and parameters', () {
    String name({
      HarborFabricKind kind = HarborFabricKind.wishbone,
      int idWidth = 1,
      int beats = 8,
      int? addressWidth,
      HarborDeviceTarget? target,
    }) => HarborSram(
      baseAddress: 0,
      size: 4096,
      protocol: kind,
      idWidth: idWidth,
      wishboneBurstBeats: beats,
      busAddressWidth: addressWidth,
      target: target,
    ).definitionName;
    expect(name(), 'HarborSram_4096_d32_a12_wishbone_i1_n1_q0_b8_generic');
    expect({
      name(),
      name(kind: HarborFabricKind.axi4),
      name(kind: HarborFabricKind.tilelink),
      name(idWidth: 3),
      name(beats: 4),
      name(addressWidth: 16),
      name(target: _ecp5),
      name(target: const HarborSimTarget()),
    }, hasLength(8));
    // The burst block changes nothing outside Wishbone.
    expect(
      name(kind: HarborFabricKind.axi4, beats: 4),
      name(kind: HarborFabricKind.axi4),
    );
  });

  test('busDataWidth other than dataWidth is refused', () {
    expect(
      () => HarborSram(baseAddress: 0, size: 4096, busDataWidth: 64),
      throwsArgumentError,
    );
  });
}
