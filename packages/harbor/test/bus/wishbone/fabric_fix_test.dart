import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

typedef Drive = void Function(String, int);

Future<(Logic, Drive)> _start(Module dut) async {
  final clk = SimpleClockGenerator(10).clk;
  for (final i in dut.inputs.values) {
    if (i.name != 'clk') i.srcConnection!.put(0);
  }
  dut.input('clk').srcConnection! <= clk;
  void drive(String n, int v) => dut.input(n).srcConnection!.inject(v);
  await dut.build();
  drive('reset', 1);
  Simulator.setMaxSimTime(100000);
  unawaited(Simulator.run());
  await clk.nextNegedge;
  await clk.nextNegedge;
  drive('reset', 0);
  return (clk, drive);
}

int _out(Module dut, String n) => dut.output(n).value.toInt();

List<HarborAddressMapping> _twoSlaves() => [
  for (var i = 0; i < 2; i++)
    HarborAddressMapping(range: BusAddressRange(i * 4096, 4096), slaveIndex: i),
];

const _allOpts = WishboneConfig(
  addressWidth: 32,
  dataWidth: 32,
  useErr: true,
  useRty: true,
  useCti: true,
  useBte: true,
  tgaWidth: 2,
  tgdWidth: 4,
);

void main() {
  tearDown(() async => Simulator.reset());

  group('register stage', () {
    test('an aborted cycle does not end the next cycle', () async {
      const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
      final dut = WishboneRegisterStage(config: cfg);
      final (clk, drive) = await _start(dut);
      final downAdrs = <int>{};
      clk.posedge.listen((_) {
        if (_out(dut, 'down_CYC') == 1) downAdrs.add(_out(dut, 'down_ADR'));
      });

      drive('up_WE', 1);
      drive('up_ADR', 0x100);
      drive('up_CYC', 1);
      drive('up_STB', 1);
      await clk.nextNegedge;
      await clk.nextNegedge;
      expect(_out(dut, 'down_CYC'), 1);
      drive('up_CYC', 0);
      drive('up_STB', 0);
      await clk.nextNegedge;
      drive('up_ADR', 0x200);
      drive('up_CYC', 1);
      drive('up_STB', 1);
      await clk.nextNegedge;
      // The slave ends the aborted cycle. Its ACK has no owner.
      drive('down_ACK', 1);
      await clk.nextNegedge;
      drive('down_ACK', 0);
      expect(_out(dut, 'up_ACK'), 0);
      var bAck = false;
      for (var i = 0; i < 10 && !bAck; i++) {
        if (_out(dut, 'down_CYC') == 1 && _out(dut, 'down_ADR') == 0x200) {
          drive('down_ACK', 1);
        }
        await clk.nextNegedge;
        drive('down_ACK', 0);
        bAck = _out(dut, 'up_ACK') == 1;
      }
      expect(downAdrs, contains(0x200));
      expect(bAck, isTrue);
      await Simulator.endSimulation();
    });

    test('RTY ends the transfer and goes up as RTY, tags pass', () async {
      final dut = WishboneRegisterStage(config: _allOpts);
      final (clk, drive) = await _start(dut);
      drive('up_CYC', 1);
      drive('up_STB', 1);
      drive('up_CTI', 2);
      drive('up_TGD_MOSI', 5);
      await clk.nextNegedge;
      expect(_out(dut, 'down_CTI'), 2);
      expect(_out(dut, 'down_TGD_MOSI'), 5);
      drive('down_RTY', 1);
      await clk.nextNegedge;
      drive('down_RTY', 0);
      expect(_out(dut, 'up_RTY'), 1);
      expect(_out(dut, 'up_ACK'), 0);
      expect(_out(dut, 'up_ERR'), 0);
      expect(_out(dut, 'down_CYC'), 0);
      expect(dut.output('up_TGD_MISO').value.isValid, isTrue);
      await Simulator.endSimulation();
    });

    test('ERR reaches an ACK-only master as ACK with poison', () async {
      const down = WishboneConfig(
        addressWidth: 32,
        dataWidth: 32,
        useErr: true,
      );
      const up = WishboneConfig(addressWidth: 32, dataWidth: 32);
      final dut = WishboneRegisterStage(config: down, upConfig: up);
      final (clk, drive) = await _start(dut);
      drive('up_CYC', 1);
      drive('up_STB', 1);
      await clk.nextNegedge;
      drive('down_ERR', 1);
      await clk.nextNegedge;
      drive('down_ERR', 0);
      expect(_out(dut, 'up_ACK'), 1);
      expect(_out(dut, 'up_DAT_MISO'), wishbonePoisonWord);
      expect(_out(dut, 'bus_error'), 0);
      await clk.nextNegedge;
      expect(_out(dut, 'bus_error'), 1);
      await Simulator.endSimulation();
    });
  });

  group('decoder', () {
    test('unmapped access ends with ERR alone', () async {
      const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32, useErr: true);
      final dut = WishboneDecoder(cfg, _twoSlaves());
      final (clk, drive) = await _start(dut);
      drive('master_CYC', 1);
      drive('master_STB', 1);
      drive('master_ADR', 0x10000);
      await clk.nextPosedge;
      expect(_out(dut, 'master_ACK'), 0);
      expect(_out(dut, 'master_ERR'), 1);
      await clk.nextNegedge;
      drive('master_CYC', 0);
      drive('master_STB', 0);
      await clk.nextNegedge;
      expect(_out(dut, 'bus_error'), 1);
      await Simulator.endSimulation();
    });

    test('unmapped access without ERR acks 0 and sets bus_error', () async {
      const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
      final dut = WishboneDecoder(cfg, _twoSlaves());
      final (clk, drive) = await _start(dut);
      expect(_out(dut, 'bus_error'), 0);
      drive('master_CYC', 1);
      drive('master_STB', 1);
      drive('master_ADR', 0x10000);
      await clk.nextPosedge;
      expect(_out(dut, 'master_ACK'), 1);
      expect(_out(dut, 'master_DAT_MISO'), 0);
      await clk.nextNegedge;
      drive('master_CYC', 0);
      drive('master_STB', 0);
      await clk.nextNegedge;
      await clk.nextNegedge;
      expect(_out(dut, 'bus_error'), 1);
      await Simulator.endSimulation();
    });

    test('optional ports are forwarded and routed back', () async {
      final dut = WishboneDecoder(_allOpts, _twoSlaves());
      final (clk, drive) = await _start(dut);
      drive('master_CYC', 1);
      drive('master_STB', 1);
      drive('master_ADR', 4096);
      drive('master_CTI', 2);
      drive('master_BTE', 1);
      drive('master_TGA', 3);
      drive('master_TGD_MOSI', 5);
      drive('slave_1_RTY', 1);
      drive('slave_1_TGD_MISO', 9);
      drive('slave_0_RTY', 0);
      await clk.nextNegedge;
      expect(_out(dut, 'slave_1_CTI'), 2);
      expect(_out(dut, 'slave_1_BTE'), 1);
      expect(_out(dut, 'slave_1_TGA'), 3);
      expect(_out(dut, 'slave_1_TGD_MOSI'), 5);
      expect(_out(dut, 'master_RTY'), 1);
      expect(_out(dut, 'master_TGD_MISO'), 9);
      drive('master_ADR', 0);
      await clk.nextNegedge;
      expect(_out(dut, 'master_RTY'), 0);
      await Simulator.endSimulation();
    });

    test('ACK needs STB', () async {
      const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
      final dut = WishboneDecoder(cfg, _twoSlaves());
      final (clk, drive) = await _start(dut);
      drive('master_CYC', 1);
      drive('slave_0_ACK', 1);
      await clk.nextNegedge;
      expect(_out(dut, 'master_ACK'), 0);
      drive('master_STB', 1);
      await clk.nextNegedge;
      expect(_out(dut, 'master_ACK'), 1);
      await Simulator.endSimulation();
    });

    test('region that ends at the top of the address space', () async {
      const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
      final dut = WishboneDecoder(cfg, [
        HarborAddressMapping(
          range: BusAddressRange(0xA0000000, 0x60000000),
          slaveIndex: 0,
        ),
      ]);
      final (clk, drive) = await _start(dut);
      drive('master_CYC', 1);
      drive('master_STB', 1);
      drive('master_ADR', 0xFFFFFFFC);
      await clk.nextNegedge;
      expect(_out(dut, 'slave_0_CYC'), 1);
      drive('master_ADR', 0x10);
      await clk.nextNegedge;
      expect(_out(dut, 'slave_0_CYC'), 0);
      await Simulator.endSimulation();
    });

    test('region past the address space is rejected', () {
      const cfg = WishboneConfig(addressWidth: 16, dataWidth: 32);
      expect(
        () => WishboneDecoder(cfg, [
          HarborAddressMapping(
            range: BusAddressRange(0xF000, 0x2000),
            slaveIndex: 0,
          ),
        ]),
        throwsArgumentError,
      );
    });

    for (final useErr in [true, false]) {
      test('timeout ends a stuck access and orphans the slave '
          '(useErr: $useErr)', () async {
        final cfg = WishboneConfig(
          addressWidth: 32,
          dataWidth: 32,
          useErr: useErr,
        );
        final dut = WishboneDecoder(cfg, _twoSlaves(), timeoutCycles: 8);
        final (clk, drive) = await _start(dut);
        drive('master_CYC', 1);
        drive('master_STB', 1);
        drive('master_WE', 1);
        drive('master_ADR', 0x10);
        // The strobe starts mid-cycle here, so that cycle counts as one.
        var waited = 1;
        while (true) {
          await clk.nextNegedge;
          final term = useErr
              ? _out(dut, 'master_ERR')
              : _out(dut, 'master_ACK');
          if (term == 1) break;
          waited++;
          expect(waited, lessThan(20));
        }
        expect(waited, 8);
        if (useErr) {
          expect(_out(dut, 'master_ACK'), 0);
        } else {
          expect(_out(dut, 'master_DAT_MISO'), wishbonePoisonWord);
        }
        await clk.nextPosedge;
        drive('master_CYC', 0);
        drive('master_STB', 0);
        drive('master_WE', 0);
        await clk.nextNegedge;
        // The slave stays in the old cycle with the old request.
        expect(_out(dut, 'slave_0_CYC'), 1);
        expect(_out(dut, 'slave_0_WE'), 1);
        expect(_out(dut, 'slave_0_ADR'), 0x10);
        expect(_out(dut, 'bus_error'), 1);
        // A new access to the other slave works.
        drive('master_CYC', 1);
        drive('master_STB', 1);
        drive('master_ADR', 4096);
        drive('slave_1_ACK', 1);
        drive('slave_0_ACK', 1);
        await clk.nextPosedge;
        expect(_out(dut, 'master_ACK'), 1);
        await clk.nextNegedge;
        drive('slave_1_ACK', 0);
        drive('slave_0_ACK', 0);
        drive('master_CYC', 0);
        drive('master_STB', 0);
        await clk.nextNegedge;
        // The late ACK from slave 0 retired the orphan.
        expect(_out(dut, 'slave_0_CYC'), 0);
        await Simulator.endSimulation();
      });
    }

    for (final useErr in [true, false]) {
      test('two stuck slaves: the second ends at once and loses CYC '
          '(useErr: $useErr)', () async {
        final cfg = WishboneConfig(
          addressWidth: 32,
          dataWidth: 32,
          useErr: useErr,
        );
        final dut = WishboneDecoder(cfg, _twoSlaves(), timeoutCycles: 4);
        final (clk, drive) = await _start(dut);
        Future<int> waitTerm(int limit) async {
          for (var i = 1; i <= limit; i++) {
            await clk.nextNegedge;
            final t = useErr ? 'master_ERR' : 'master_ACK';
            if (_out(dut, t) == 1) return i;
          }
          return -1;
        }

        // Slave 0 times out and is held.
        drive('master_CYC', 1);
        drive('master_STB', 1);
        drive('master_ADR', 0x10);
        expect(await waitTerm(10), greaterThan(0));
        await clk.nextPosedge;
        drive('master_CYC', 0);
        drive('master_STB', 0);
        await clk.nextNegedge;
        // Slave 1 does not answer either. The access ends, and the master
        // keeps CYC for a block cycle.
        drive('master_CYC', 1);
        drive('master_STB', 1);
        drive('master_ADR', 4096);
        expect(await waitTerm(10), greaterThan(0));
        if (!useErr) {
          expect(_out(dut, 'master_DAT_MISO'), wishbonePoisonWord);
        }
        await clk.nextPosedge;
        drive('master_STB', 0);
        await clk.nextNegedge;
        expect(_out(dut, 'slave_1_CYC'), 0, reason: 'second slave cut off');
        expect(_out(dut, 'slave_0_CYC'), 1, reason: 'orphan still held');
        expect(_out(dut, 'bus_error'), 1);
        // A late ACK from slave 1 reaches no one, so a new strobe in the same
        // block cycle waits and times out again.
        drive('slave_1_ACK', 1);
        drive('master_STB', 1);
        await clk.nextNegedge;
        expect(_out(dut, 'master_ACK'), 0);
        expect(_out(dut, 'slave_1_STB'), 0);
        drive('slave_1_ACK', 0);
        drive('master_CYC', 0);
        drive('master_STB', 0);
        await clk.nextNegedge;
        // A new cycle reaches slave 1 again.
        drive('master_CYC', 1);
        drive('master_STB', 1);
        await clk.nextNegedge;
        expect(_out(dut, 'slave_1_CYC'), 1);
        await Simulator.endSimulation();
      });
    }
  });

  group('arbiter', () {
    test('optional ports are forwarded and routed back', () async {
      final dut = WishboneArbiter(numMasters: 2, config: _allOpts);
      final (clk, drive) = await _start(dut);
      drive('master_1_CYC', 1);
      drive('master_1_STB', 1);
      drive('master_1_CTI', 2);
      drive('master_1_BTE', 1);
      drive('master_1_TGA', 3);
      drive('master_1_TGD_MOSI', 5);
      await clk.nextNegedge;
      await clk.nextNegedge;
      expect(_out(dut, 'grant'), 2);
      expect(_out(dut, 'slave_CTI'), 2);
      expect(_out(dut, 'slave_BTE'), 1);
      expect(_out(dut, 'slave_TGA'), 3);
      expect(_out(dut, 'slave_TGD_MOSI'), 5);
      drive('slave_RTY', 1);
      drive('slave_TGD_MISO', 9);
      await clk.nextNegedge;
      expect(_out(dut, 'master_1_RTY'), 1);
      expect(_out(dut, 'master_0_RTY'), 0);
      expect(_out(dut, 'master_1_TGD_MISO'), 9);
      await Simulator.endSimulation();
    });

    test('grant is registered', () async {
      const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
      final dut = WishboneArbiter(numMasters: 2, config: cfg);
      final (clk, drive) = await _start(dut);
      await clk.nextPosedge;
      drive('master_0_CYC', 1);
      drive('master_0_STB', 1);
      await clk.nextNegedge;
      expect(_out(dut, 'grant'), 0);
      expect(_out(dut, 'slave_CYC'), 0);
      await clk.nextNegedge;
      expect(_out(dut, 'grant'), 1);
      expect(_out(dut, 'slave_CYC'), 1);
      await Simulator.endSimulation();
    });

    test('grant parks on the last owner', () async {
      const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
      final dut = WishboneArbiter(numMasters: 2, config: cfg);
      final (clk, drive) = await _start(dut);
      drive('master_1_CYC', 1);
      drive('master_1_STB', 1);
      await clk.nextNegedge;
      await clk.nextNegedge;
      expect(_out(dut, 'slave_CYC'), 1);
      drive('master_1_CYC', 0);
      drive('master_1_STB', 0);
      await clk.nextNegedge;
      await clk.nextNegedge;
      expect(_out(dut, 'grant'), 2);
      // The same master starts again with no idle cycle.
      drive('master_1_CYC', 1);
      drive('master_1_STB', 1);
      await clk.nextNegedge;
      expect(_out(dut, 'slave_CYC'), 1);
      await Simulator.endSimulation();
    });

    test('ACK reaches only a strobing owner', () async {
      const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
      final dut = WishboneArbiter(numMasters: 2, config: cfg);
      final (clk, drive) = await _start(dut);
      drive('master_0_CYC', 1);
      await clk.nextNegedge;
      await clk.nextNegedge;
      expect(_out(dut, 'grant'), 1);
      drive('slave_ACK', 1);
      await clk.nextNegedge;
      expect(_out(dut, 'master_0_ACK'), 0);
      drive('master_0_STB', 1);
      await clk.nextNegedge;
      expect(_out(dut, 'master_0_ACK'), 1);
      await Simulator.endSimulation();
    });

    for (final cap in [null, 4]) {
      test('grant-hold cap $cap', () async {
        const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
        final dut = WishboneArbiter(
          numMasters: 2,
          config: cfg,
          arbitration: BusArbitration.fixed,
          maxGrantCycles: cap,
        );
        final (clk, drive) = await _start(dut);
        // Master 0 keeps CYC and strobes without end.
        drive('master_0_CYC', 1);
        drive('master_0_STB', 1);
        await clk.nextNegedge;
        await clk.nextNegedge;
        drive('master_1_CYC', 1);
        drive('master_1_STB', 1);
        var m1Acks = 0;
        var gapSeen = false;
        for (var i = 0; i < 40; i++) {
          drive('slave_ACK', _out(dut, 'slave_STB'));
          await clk.nextPosedge;
          if (_out(dut, 'master_1_ACK') == 1) m1Acks++;
          await clk.nextNegedge;
          if (_out(dut, 'slave_CYC') == 0) gapSeen = true;
        }
        if (cap == null) {
          expect(m1Acks, 0);
        } else {
          expect(m1Acks, greaterThan(0));
          expect(gapSeen, isTrue);
        }
        await Simulator.endSimulation();
      });
    }
  });

  group('soc', () {
    test('fabric turns on ERR when every master has it and exposes '
        'bus_error', () async {
      const masterCfg = WishboneConfig(
        addressWidth: 32,
        dataWidth: 32,
        useErr: true,
        useCti: true,
      );
      const busCfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
      final soc = HarborSoC(
        name: 'ErrSoc',
        compatible: 'test,err',
        busConfig: busCfg,
      );
      final m = _Probe(masterCfg);
      soc.addMaster(m, busInterfaceName: 'bus');
      soc.addPeripheral(
        HarborSram(baseAddress: 0, size: 4096, busAddressWidth: 32),
      );
      soc.buildFabric(busTimeoutCycles: 16);
      soc.exposeBusError();
      expect(soc.fabricDecoders.single.timeoutCycles, 16);
      final (clk, _) = await _start(soc);
      void driveM(String n, int v) => m.input(n).srcConnection!.inject(v);
      driveM('cyc', 1);
      driveM('stb', 1);
      driveM('adr', 0x40000000);
      await clk.nextPosedge;
      expect(_out(m, 'err'), 1);
      expect(_out(m, 'ack'), 0);
      await clk.nextNegedge;
      driveM('cyc', 0);
      driveM('stb', 0);
      await clk.nextNegedge;
      expect(_out(soc, 'bus_error'), 1);
      await Simulator.endSimulation();
    });

    test('a slave ERR folded into ACK sets bus_error', () async {
      const masterCfg = WishboneConfig(
        addressWidth: 32,
        dataWidth: 32,
        useCti: true,
      );
      const busCfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
      final soc = HarborSoC(
        name: 'FoldSoc',
        compatible: 'test,fold',
        busConfig: busCfg,
      );
      final m = _Probe(masterCfg);
      soc.addMaster(m, busInterfaceName: 'bus');
      soc.addPeripheral(
        HarborSram(baseAddress: 0x10000, size: 4096, busAddressWidth: 32),
      );
      final slave = _ErrSlave();
      soc.addSubModule(slave);
      soc.addPeripheralSlave(slave, 'bus', const BusAddressRange(0, 4096));
      soc.buildFabric();
      soc.exposeBusError();
      final (clk, _) = await _start(soc);
      void driveM(String n, int v) => m.input(n).srcConnection!.inject(v);
      driveM('cyc', 1);
      driveM('stb', 1);
      driveM('adr', 0x10);
      await clk.nextNegedge;
      expect(_out(m, 'ack'), 1);
      expect(_out(m, 'dat'), wishbonePoisonWord);
      await clk.nextPosedge;
      driveM('cyc', 0);
      driveM('stb', 0);
      await clk.nextNegedge;
      expect(_out(soc, 'bus_error'), 1);
      await Simulator.endSimulation();
    });

    test('bus_error takes marked peripherals only', () async {
      const busCfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
      final soc = HarborSoC(
        name: 'MarkSoc',
        compatible: 'test,mark',
        busConfig: busCfg,
      );
      final m = _Probe(
        const WishboneConfig(addressWidth: 32, dataWidth: 32, useCti: true),
      );
      soc.addMaster(m, busInterfaceName: 'bus');
      final marked = _FlagSram(baseAddress: 0, name: 'marked');
      final plain = _PlainSram(baseAddress: 0x10000);
      soc.addPeripheral(marked);
      soc.addPeripheral(plain);
      soc.buildFabric();
      soc.exposeBusError();
      final markedFlag = Logic(name: 'marked_flag');
      final plainFlag = Logic(name: 'plain_flag');
      marked.input('flag').srcConnection! <= markedFlag;
      plain.input('flag').srcConnection! <= plainFlag;
      markedFlag.put(0);
      plainFlag.put(0);
      for (final n in ['cyc', 'stb', 'adr']) {
        m.input(n).srcConnection!.put(0);
      }
      final (clk, _) = await _start(soc);
      plainFlag.inject(1);
      await clk.nextNegedge;
      expect(_out(soc, 'bus_error'), 0);
      markedFlag.inject(1);
      await clk.nextNegedge;
      expect(_out(soc, 'bus_error'), 1);
      await Simulator.endSimulation();
    });
  });
}

/// An SRAM with a sticky error flag driven from the testbench.
class _FlagSram extends HarborSram with HarborBusErrorSource {
  _FlagSram({required super.baseAddress, required String name})
    : super(size: 4096, busAddressWidth: 32, name: name) {
    createPort('flag', PortDirection.input);
    addOutput('err_flag') <= input('flag');
  }

  @override
  Logic get busError => output('err_flag');
}

/// The same SRAM with an output named bus_error but no marker.
class _PlainSram extends HarborSram {
  _PlainSram({required super.baseAddress})
    : super(size: 4096, busAddressWidth: 32, name: 'plain') {
    createPort('flag', PortDirection.input);
    addOutput('bus_error') <= input('flag');
  }
}

/// A slave that ends every transfer with ERR.
class _ErrSlave extends BridgeModule {
  _ErrSlave() : super('ErrSlave', name: 'err_slave') {
    final bus =
        addInterface(
              WishboneInterface(
                const WishboneConfig(
                  addressWidth: 32,
                  dataWidth: 32,
                  useErr: true,
                ),
              ),
              name: 'bus',
              role: PairRole.consumer,
            ).internalInterface
            as WishboneInterface;
    bus.ack <= Const(0);
    bus.err! <= bus.cyc & bus.stb;
    bus.datMiso <= Const(0, width: 32);
  }
}

/// A master whose bus pins are driven from outside through plain ports.
class _Probe extends BridgeModule {
  _Probe(WishboneConfig cfg) : super('Probe', name: 'probe') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final bus =
        addInterface(
              WishboneInterface(cfg),
              name: 'bus',
              role: PairRole.provider,
            ).internalInterface
            as WishboneInterface;
    bus.cyc <= addInput('cyc', Logic());
    bus.stb <= addInput('stb', Logic());
    bus.we <= Const(0);
    bus.adr <= addInput('adr', Logic(width: 32), width: 32);
    bus.datMosi <= Const(0, width: 32);
    bus.sel <= Const(0xF, width: 4);
    bus.cti! <= Const(0, width: 3);
    addOutput('ack') <= bus.ack;
    addOutput('dat', width: 32) <= bus.datMiso;
    if (bus.err != null) addOutput('err') <= bus.err!;
  }
}
