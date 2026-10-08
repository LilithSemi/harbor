import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('BusSlavePort', () {
    test('creates Wishbone port', () {
      final mod = BridgeModule('test_wb', name: 'test');
      final port = BusSlavePort.create(
        module: mod,
        name: 'bus',
        protocol: BusProtocol.wishbone,
        addressWidth: 16,
        dataWidth: 32,
      );
      expect(port.protocol, equals(BusProtocol.wishbone));
      expect(port.addr.width, equals(16));
      expect(port.dataIn.width, equals(32));
      expect(port.dataOut.width, equals(32));
      expect(port.stb.width, equals(1));
      expect(port.we.width, equals(1));
      expect(port.ack.width, equals(1));
    });

    test('creates TileLink port', () {
      final mod = BridgeModule('test_tl', name: 'test');
      mod.createPort('clk', PortDirection.input);
      mod.createPort('reset', PortDirection.input);
      final port = BusSlavePort.create(
        module: mod,
        name: 'bus',
        protocol: BusProtocol.tilelink,
        addressWidth: 32,
        dataWidth: 32,
        clk: mod.input('clk'),
        reset: mod.input('reset'),
      );
      expect(port.protocol, equals(BusProtocol.tilelink));
      expect(port.addr.width, equals(32));
      expect(port.dataIn.width, equals(32));
      expect(port.dataOut.width, equals(32));
    });

    test('TileLink without clk/reset is rejected', () {
      final mod = BridgeModule('test_tl_noclk', name: 'test');
      expect(
        () => BusSlavePort.create(
          module: mod,
          name: 'bus',
          protocol: BusProtocol.tilelink,
          addressWidth: 32,
          dataWidth: 32,
        ),
        throwsArgumentError,
      );
    });

    test('interface reference is set', () {
      final mod = BridgeModule('test', name: 'test');
      final port = BusSlavePort.create(
        module: mod,
        name: 'bus',
        protocol: BusProtocol.wishbone,
        addressWidth: 8,
        dataWidth: 32,
      );
      expect(port.interfaceRef, isNotNull);
    });
  });

  group('BusSlavePort TileLink D_READY backpressure', () {
    test(
      'holds D_VALID until D_READY, never re-executes the request',
      () async {
        final mod = BridgeModule('test_tl_dready', name: 'test');
        mod.createPort('clk', PortDirection.input);
        mod.createPort('reset', PortDirection.input);
        final port = BusSlavePort.create(
          module: mod,
          name: 'bus',
          protocol: BusProtocol.tilelink,
          addressWidth: 8,
          dataWidth: 32,
          clk: mod.input('clk'),
          reset: mod.input('reset'),
        );

        // One-shot register-file style peripheral: acks exactly once per STB
        // assertion, same idiom used by the real peripherals in lib/.
        var execCount = 0;
        Sequential(mod.input('clk'), reset: mod.input('reset'), [
          If(
            port.stb & ~port.ack,
            then: [
              port.ack < Const(1),
              port.dataOut < Const(0x1234, width: 32),
            ],
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
        mod.input('bus_A_OPCODE').srcConnection! <= Const(4, width: 3); // Get
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
        await clk.nextPosedge;

        // Issue the request with D_READY withheld.
        aValid.inject(1);
        await clk.nextPosedge;
        await clk.nextPosedge;

        expect(
          mod.output('bus_D_VALID').value,
          equals(LogicValue.one),
          reason:
              'the response must be held, not dropped, while D_READY is low',
        );
        expect(
          mod.output('bus_A_READY').value,
          equals(LogicValue.zero),
          reason:
              'a new request must not be accepted while the response '
              'is still undrained',
        );

        // Hold for several more cycles: still no second execution.
        for (var i = 0; i < 5; i++) {
          await clk.nextPosedge;
        }
        expect(
          execCount,
          equals(1),
          reason: 'a held response must not re-trigger the peripheral',
        );
        expect(mod.output('bus_D_VALID').value, equals(LogicValue.one));

        // Now the master is ready: the response drains and A_READY fires.
        // A real master drops A_VALID once it is accepted; this test does
        // the same rather than holding the same request open forever.
        aValid.inject(0);
        dReady.inject(1);
        await clk.nextPosedge;
        expect(mod.output('bus_D_DATA').value.toInt(), equals(0x1234));
        expect(mod.output('bus_D_VALID').value, equals(LogicValue.zero));

        await Simulator.endSimulation();
      },
    );
  });

  group('BusProtocol', () {
    test('enum values', () {
      expect(BusProtocol.values, hasLength(2));
      expect(BusProtocol.wishbone.name, equals('wishbone'));
      expect(BusProtocol.tilelink.name, equals('tilelink'));
    });
  });
}
