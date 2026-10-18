import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  test('primitive metadata contains valid identifiers', () {
    final identifier = RegExp(r'^[A-Z][A-Z0-9_]*$');
    for (final name in xilinxPcie21Gen1X1Parameters.keys) {
      expect(name, matches(identifier));
    }
    for (final name in xilinxPcie21InputWidths.keys) {
      expect(name, matches(identifier));
    }
    for (final name in xilinxPcie21OutputWidths.keys) {
      expect(name, matches(identifier));
    }
  });

  test('rejects malformed parameter names', () {
    expect(
      () => HarborXilinxPcie21(
        inputs: harborPcie21TiedInputs(),
        parameterOverrides: const {'bad parameter': '0'},
      ),
      throwsArgumentError,
    );
  });

  test('hard block wrapper elaborates with all ports', () async {
    final block = HarborXilinxPcie21(inputs: harborPcie21TiedInputs());
    await block.build();
    expect(block.definitionName, 'PCIE_2_1');
    expect(block.input('TRNTD').width, 128);
    expect(block.output('TRNRD').width, 128);
    expect(block.output('MIMTXWDATA').width, 69);
  });
}
