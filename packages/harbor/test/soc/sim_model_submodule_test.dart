import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

/// A plain submodule (not a peripheral or a master) that offers a sim model.
///
/// Records every context it was asked with, so a test can check whether
/// [HarborSoC.generateAll] reached it.
class _SimModelMock extends BridgeModule with HarborSimModelProvider {
  final List<HarborSimModelContext> seenContexts = [];

  _SimModelMock() : super('SimModelMock', name: 'sim_model_mock') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
  }

  @override
  List<HarborSimModel> simModels(HarborSimModelContext ctx) {
    seenContexts.add(ctx);
    return [
      const HarborSimModel(
        className: 'MockSimModel',
        header: '#pragma once\n',
        declaration: 'static MockSimModel mock_inst;',
        tick: 'mock_inst.tick();',
        clockPort: 'clk',
      ),
    ];
  }
}

Future<Directory> _generate(HarborSoC soc) async {
  final dir = Directory.systemTemp.createTempSync('harbor_sim_model_sub_');
  addTearDown(() => dir.deleteSync(recursive: true));
  await soc.generateAll(dir);
  return dir;
}

void main() {
  test('a plain submodule that provides a sim model is asked for it', () async {
    final soc = HarborSoC(
      name: 'SimModelSubSoc',
      compatible: 'test,sim-model-sub',
      target: const HarborSimTarget(topCell: 'soc'),
    );
    soc.addPeripheral(HarborUart(baseAddress: 0x10000000));
    final mock = _SimModelMock();
    soc.addSubModule(mock);
    mock.input('clk').srcConnection! <= soc.input('clk');
    mock.input('reset').srcConnection! <= soc.input('reset');

    final dir = await _generate(soc);

    expect(mock.seenContexts, hasLength(1));
    expect(File('${dir.path}/sim/models/MockSimModel.h').existsSync(), isTrue);
  });

  test(
    'a submodule nested under a peripheral is asked for its sim model',
    () async {
      final soc = HarborSoC(
        name: 'SimModelNestedSoc',
        compatible: 'test,sim-model-nested',
        target: const HarborSimTarget(topCell: 'soc'),
      );
      final uart = HarborUart(baseAddress: 0x10000000);
      soc.addPeripheral(uart);
      final mock = _SimModelMock();
      // Nested two levels deep: a child of the peripheral, not of the SoC.
      uart.addSubModule(mock);
      mock.input('clk').srcConnection! <= uart.input('clk');
      mock.input('reset').srcConnection! <= uart.input('reset');

      final dir = await _generate(soc);

      expect(mock.seenContexts, hasLength(1));
      expect(
        File('${dir.path}/sim/models/MockSimModel.h').existsSync(),
        isTrue,
      );
    },
  );
}
