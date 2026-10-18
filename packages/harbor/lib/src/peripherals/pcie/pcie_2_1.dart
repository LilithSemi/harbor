import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'pcie_2_1_params.dart';
import 'pcie_2_1_ports.dart';

/// Xilinx 7-series integrated PCIe block primitive.
class HarborXilinxPcie21 extends BridgeModule {
  HarborXilinxPcie21({
    required Map<String, Logic> inputs,
    Map<String, String> parameterOverrides = const {},
    super.name = 'pcie_hard_block',
  }) : super('PCIE_2_1', isSystemVerilogLeaf: true) {
    final primitiveName = RegExp(r'^[A-Z][A-Z0-9_]*$');
    final invalidPorts = {
      ...xilinxPcie21InputWidths.keys,
      ...xilinxPcie21OutputWidths.keys,
    }.where((name) => !primitiveName.hasMatch(name));
    if (invalidPorts.isNotEmpty) {
      throw StateError(
        'invalid PCIE_2_1 port names: ${invalidPorts.join(', ')}',
      );
    }
    final invalidParameters = {
      ...xilinxPcie21Gen1X1Parameters.keys,
      ...parameterOverrides.keys,
    }.where((name) => !primitiveName.hasMatch(name));
    if (invalidParameters.isNotEmpty) {
      throw ArgumentError(
        'invalid PCIE_2_1 parameter names: ${invalidParameters.join(', ')}',
      );
    }
    final missing = xilinxPcie21InputWidths.keys.toSet().difference(
      inputs.keys.toSet(),
    );
    final unknown = inputs.keys.toSet().difference(
      xilinxPcie21InputWidths.keys.toSet(),
    );
    if (missing.isNotEmpty) {
      throw ArgumentError('missing PCIE_2_1 inputs: ${missing.join(', ')}');
    }
    if (unknown.isNotEmpty) {
      throw ArgumentError('unknown PCIE_2_1 inputs: ${unknown.join(', ')}');
    }
    final parameters = {...xilinxPcie21Gen1X1Parameters, ...parameterOverrides};
    for (final parameter in parameters.entries) {
      createParameter(parameter.key, parameter.value);
    }
    for (final port in xilinxPcie21InputWidths.entries) {
      addInput(port.key, inputs[port.key]!, width: port.value);
    }
    for (final port in xilinxPcie21OutputWidths.entries) {
      addOutput(port.key, width: port.value);
    }
  }
}

/// Makes a fully driven PCIE_2_1 input map.
Map<String, Logic> harborPcie21TiedInputs() => {
  for (final port in xilinxPcie21InputWidths.entries)
    port.key: Const(
      _pcie21ActiveLowInputs.contains(port.key) ? (1 << port.value) - 1 : 0,
      width: port.value,
    ),
};

const _pcie21ActiveLowInputs = {
  'CFGERRACSN',
  'CFGERRATOMICEGRESSBLOCKEDN',
  'CFGERRCORN',
  'CFGERRCPLABORTN',
  'CFGERRCPLTIMEOUTN',
  'CFGERRCPLUNEXPECTN',
  'CFGERRECRCN',
  'CFGERRINTERNALCORN',
  'CFGERRINTERNALUNCORN',
  'CFGERRLOCKEDN',
  'CFGERRMALFORMEDN',
  'CFGERRMCBLOCKEDN',
  'CFGERRNORECOVERYN',
  'CFGERRPOISONEDN',
  'CFGERRPOSTEDN',
  'CFGERRURN',
  'CFGINTERRUPTASSERTN',
  'CFGINTERRUPTN',
  'CFGINTERRUPTSTATN',
  'CFGMGMTRDENN',
  'CFGMGMTWRENN',
  'CFGMGMTWRREADONLYN',
  'CFGMGMTWRRW1CASRWN',
  'CFGPMFORCESTATEENN',
  'CFGPMHALTASPML0SN',
  'CFGPMHALTASPML1N',
  'CFGPMSENDPMETON',
  'CFGPMTURNOFFOKN',
  'CFGPMWAKEN',
  'CFGTRNPENDINGN',
  'CMRSTN',
  'CMSTICKYRSTN',
  'DLRSTN',
  'FUNCLVLRSTN',
  'PLRSTN',
  'SYSRSTN',
  'TLRSTN',
  'TRNRFCPRET',
  'TRNRNPOK',
  'TRNRNPREQ',
};
