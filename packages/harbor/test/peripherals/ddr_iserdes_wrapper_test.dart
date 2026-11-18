import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

/// Thin wrapper so the leaf instantiation appears in generateSynth() output.
/// XilinxIserdese2 is isSystemVerilogLeaf=true, so calling generateSynth()
/// directly on it yields only the file header (no module body). Wrapping it
/// in a parent BridgeModule causes the instantiation to show up in the parent
/// module's SV definition.
class _IserdesWrap extends BridgeModule {
  _IserdesWrap({
    required Logic clk,
    required Logic clkb,
    required Logic clkdiv,
    required Logic ddly,
    required Logic bitslip,
  }) : super('IserdesWrap') {
    clk = addInput('clk', clk);
    clkb = addInput('clkb', clkb);
    clkdiv = addInput('clkdiv', clkdiv);
    ddly = addInput('ddly', ddly);
    bitslip = addInput('bitslip', bitslip);

    // Create directly (not via addSubModule) so the typed getters are available.
    // ROHD tracks submodules automatically when a module is created during build.
    final iser = XilinxIserdese2(
      clk: clk,
      clkb: clkb,
      clkdiv: clkdiv,
      ddly: ddly,
      bitslip: bitslip,
    );

    // Pull up outputs so the ports are not pruned.
    addOutput('q1') <= iser.q1;
    addOutput('q2') <= iser.q2;
  }
}

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'XilinxIserdese2 emits an ISERDESE2 with width-2 DDR NETWORKING params',
    () async {
      final wrap = _IserdesWrap(
        clk: Logic(name: 'clk90'),
        clkb: Logic(name: 'clk90b'),
        clkdiv: Logic(name: 'clkdiv'),
        ddly: Logic(name: 'ddly'),
        bitslip: Logic(name: 'bitslip'),
      );
      await wrap.build();
      final sv = wrap.dumpSystemVerilog();

      expect(sv, contains('ISERDESE2'));
      expect(sv, contains('.DATA_WIDTH(2)'));
      expect(sv, contains('.DATA_RATE("DDR")'));
      expect(sv, contains('.INTERFACE_TYPE("NETWORKING")'));
      expect(sv, contains('.IOBDELAY("IFD")'));
      // Every scaling port must be wrapped even if only Q1/Q2 are used now.
      for (final p in [
        'CLK',
        'CLKB',
        'CLKDIV',
        'DDLY',
        'BITSLIP',
        'CE1',
        'Q1',
        'Q2',
        'Q3',
        'Q8',
      ]) {
        expect(sv, contains('.$p('), reason: 'ISERDESE2 must wrap port $p');
      }
    },
  );
}
