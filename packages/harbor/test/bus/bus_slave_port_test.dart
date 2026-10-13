import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

BusSlavePort _create(
  BridgeModule mod,
  HarborFabricKind kind, {
  int addressWidth = 16,
  int dataWidth = 32,
  bool useErr = false,
}) {
  mod.createPort('clk', PortDirection.input);
  mod.createPort('reset', PortDirection.input);
  return BusSlavePort.create(
    module: mod,
    name: 'bus',
    kind: kind,
    addressWidth: addressWidth,
    dataWidth: dataWidth,
    clk: mod.input('clk'),
    reset: mod.input('reset'),
    useErr: useErr,
  );
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('BusSlavePort', () {
    for (final kind in HarborFabricKind.values) {
      test('creates a ${kind.name} port with the same waist', () {
        final mod = BridgeModule('test_${kind.name}', name: 'test');
        final port = _create(mod, kind);
        expect(port.kind, equals(kind));
        expect(port.addr.width, equals(16));
        expect(port.dataIn.width, equals(32));
        expect(port.dataOut.width, equals(32));
        expect(port.sel.width, equals(4));
        expect(port.stb.width, equals(1));
        expect(port.we.width, equals(1));
        expect(port.ack.width, equals(1));
        expect(port.err, isNull);
        expect(port.interfaceRef, isNotNull);
      });
    }

    test('native interface type follows the kind', () {
      final wb = _create(
        BridgeModule('a', name: 'a'),
        HarborFabricKind.wishbone,
      );
      final axi = _create(BridgeModule('b', name: 'b'), HarborFabricKind.axi4);
      final tl = _create(
        BridgeModule('c', name: 'c'),
        HarborFabricKind.tilelink,
      );
      expect(wb.interfaceRef.internalInterface, isA<WishboneInterface>());
      expect(axi.interfaceRef.internalInterface, isA<Axi4LiteInterface>());
      expect(tl.interfaceRef.internalInterface, isA<TileLinkInterface>());
    });

    test('useErr adds err and the Wishbone ERR port', () {
      final mod = BridgeModule('test_err', name: 'test');
      final port = _create(mod, HarborFabricKind.wishbone, useErr: true);
      expect(port.err, isNotNull);
      expect(mod.tryOutput('bus_ERR'), isNotNull);
    });
  });

  group('BusSlavePort TileLink D_READY backpressure', () {
    test('holds D_VALID until D_READY and runs each request once', () async {
      final mod = BridgeModule('test_tl_dready', name: 'test');
      final port = _create(mod, HarborFabricKind.tilelink, addressWidth: 8);

      var execCount = 0;
      Sequential(mod.input('clk'), reset: mod.input('reset'), [
        If(
          port.stb & ~port.ack,
          then: [port.ack < Const(1), port.dataOut < Const(0x1234, width: 32)],
          orElse: [port.ack < Const(0)],
        ),
      ]);
      port.ack.posedge.listen((_) => execCount++);

      final clk = SimpleClockGenerator(10).clk;
      mod.input('clk').srcConnection! <= clk;
      final reset = Logic(name: 'ext_reset');
      mod.input('reset').srcConnection! <= reset;

      final aValid = Logic(name: 'a_valid');
      final dReady = Logic(name: 'd_ready');
      mod.input('bus_A_VALID').srcConnection! <= aValid;
      mod.input('bus_A_OPCODE').srcConnection! <= Const(4, width: 3);
      mod.input('bus_A_PARAM').srcConnection! <= Const(0, width: 3);
      mod.input('bus_A_SIZE').srcConnection! <= Const(2, width: 3);
      mod.input('bus_A_SOURCE').srcConnection! <= Const(0, width: 1);
      mod.input('bus_A_ADDRESS').srcConnection! <= Const(0x10, width: 8);
      mod.input('bus_A_MASK').srcConnection! <= Const(0xf, width: 4);
      mod.input('bus_A_DATA').srcConnection! <= Const(0, width: 32);
      mod.input('bus_A_CORRUPT').srcConnection! <= Const(0);
      mod.input('bus_D_READY').srcConnection! <= dReady;

      await mod.build();

      reset.inject(1);
      aValid.inject(0);
      dReady.inject(0);
      Simulator.setMaxSimTime(20000);
      unawaited(Simulator.run());
      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
      }
      reset.inject(0);
      await clk.nextNegedge;

      // One request, taken on the next edge, with D_READY withheld.
      aValid.inject(1);
      await clk.nextNegedge;
      aValid.inject(0);
      for (var i = 0; i < 8; i++) {
        await clk.nextNegedge;
      }

      expect(mod.output('bus_D_VALID').value, equals(LogicValue.one));
      expect(mod.output('bus_D_DATA').value.toInt(), equals(0x1234));
      expect(execCount, equals(1));

      dReady.inject(1);
      await clk.nextNegedge;
      expect(mod.output('bus_D_VALID').value, equals(LogicValue.zero));
      expect(execCount, equals(1));

      await Simulator.endSimulation();
    });
  });

  group('HarborFabricKind', () {
    test('enum values', () {
      expect(HarborFabricKind.values, hasLength(3));
      expect(
        HarborFabricKind.values.map((k) => k.name),
        equals(['wishbone', 'axi4', 'tilelink']),
      );
    });
  });
}
