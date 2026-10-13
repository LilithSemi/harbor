import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

/// An AXI4 master with its port pins on plain ports.
class _Core extends BridgeModule {
  _Core(String name, int idWidth) : super('ExclSocCore_i$idWidth', name: name) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final i = addInterface(
      Axi4Interface(addressWidth: 32, dataWidth: 32, idWidth: idWidth),
      name: 'dataBus',
      role: PairRole.provider,
    ).internalInterface!;
    for (final e in i.getPorts([PairDirection.fromProvider]).entries) {
      final w = e.value.width;
      e.value <= addInput('p_${e.key}', Logic(width: w), width: w);
    }
    for (final e in i.getPorts([PairDirection.fromConsumer]).entries) {
      addOutput('p_${e.key}', width: e.value.width) <= e.value;
    }
  }
}

HarborSoC _soc({int budget = HarborExclusive.defaultSlotBudget}) => HarborSoC(
  name: 'excl_soc',
  compatible: 'test,excl',
  fabricKind: HarborFabricKind.axi4,
  exclusiveSlotBudget: budget,
);

HarborSram _sram(({int idWidth, HarborAxi4Exclusive? exclusive}) shape) =>
    HarborSram(
      baseAddress: 0x80000000,
      size: 4096,
      busAddressWidth: 32,
      protocol: HarborFabricKind.axi4,
      idWidth: shape.idWidth,
      exclusive: shape.exclusive,
    );

const _auto = HarborExclusive.auto;

void main() {
  tearDown(Simulator.reset);

  test('fixed and automatic exclusive masters size the memory', () async {
    final soc = _soc();
    soc.addMaster(_Core('a', 3), exclusiveIds: 2);
    soc.addMaster(_Core('b', 2), exclusiveIds: _auto);
    soc.addMaster(_Core('c', 4), exclusiveIds: _auto);
    soc.addMaster(_Core('d', 1));
    final shape = soc.memoryBusShape();
    expect(soc.exclusiveSlots, {'a': 2, 'b': 4, 'c': 2});
    expect(shape.idWidth, 6);
    expect(shape.exclusive!.runs, [(0, 2), (16, 4), (32, 2)]);
    expect(shape.exclusive!.granuleBytes, 64);
    final sram = soc.addPeripheral(_sram(shape));
    soc.buildFabric();
    final slave = (soc.fabric! as HarborAxi4Fabric).slaves.single;
    expect(slave.exclusive, shape.exclusive);
    expect(sram.definitionName, contains('_x0_2_16_4_32_2_g64'));
    await soc.build();
  });

  test('a small budget gives each automatic master one slot', () {
    final soc = _soc(budget: 4);
    soc.addMaster(_Core('a', 3), exclusiveIds: 2);
    soc.addMaster(_Core('b', 2), exclusiveIds: _auto);
    soc.addMaster(_Core('c', 4), exclusiveIds: _auto);
    expect(soc.exclusiveSlots, {'a': 2, 'b': 1, 'c': 1});
  });

  test('a memory built before the last master throws at buildFabric', () {
    final soc = _soc();
    soc.addMaster(_Core('a', 2), exclusiveIds: 1);
    soc.addPeripheral(_sram(soc.memoryBusShape()));
    soc.addMaster(_Core('b', 2), exclusiveIds: 1);
    expect(soc.buildFabric, throwsArgumentError);
  });

  test('an exclusive master and a memory with no monitor throw', () {
    final soc = _soc();
    soc.addMaster(_Core('a', 2), exclusiveIds: 1);
    soc.addPeripheral(
      _sram((idWidth: soc.memoryBusShape().idWidth, exclusive: null)),
    );
    expect(
      soc.buildFabric,
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('no exclusive monitor'),
        ),
      ),
    );
  });

  test('the SoC checks the slot budget and the granule', () {
    expect(() => _soc(budget: 0), throwsArgumentError);
    for (final g in [0, 96, 256]) {
      expect(
        () => HarborSoC(
          name: 'excl_soc',
          compatible: 'test,excl',
          fabricKind: HarborFabricKind.axi4,
          exclusiveGranuleBytes: g,
        ),
        throwsArgumentError,
        reason: '$g',
      );
    }
  });

  test('a memory granule that differs from the SoC granule throws', () {
    final soc = _soc();
    soc.addMaster(_Core('a', 2), exclusiveIds: 1);
    final shape = soc.memoryBusShape();
    soc.addPeripheral(
      _sram((
        idWidth: shape.idWidth,
        exclusive: HarborAxi4Exclusive(shape.exclusive!.runs, granuleBytes: 32),
      )),
    );
    expect(
      soc.buildFabric,
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('exclusiveGranuleBytes is 64'),
        ),
      ),
    );
  });

  test('exclusive masters on more than one channel need a topology', () {
    final soc = _soc();
    soc.addMaster(_Core('a', 2), exclusiveIds: 1);
    soc.addMaster(_Core('b', 2), channel: 'dma');
    expect(
      soc.memoryBusShape,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('fabricTopology'),
        ),
      ),
    );
  });
}
