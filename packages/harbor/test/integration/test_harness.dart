import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Wishbone bus master driver for simulation testing.
///
/// Wraps a Wishbone provider interface with input ports that
/// can be driven via inject/put from test code.
class WishboneMasterTestDriver extends BridgeModule {
  final WishboneConfig config;

  WishboneMasterTestDriver({required this.config})
    : super('WishboneMasterTestDriver', name: 'wb_master') {
    createPort('clk', PortDirection.input);

    final intf = WishboneInterface(config);
    addInterface(intf, name: 'bus', role: PairRole.provider);
    final bus = interface('bus').internalInterface! as WishboneInterface;

    createPort('m_cyc', PortDirection.input);
    createPort('m_stb', PortDirection.input);
    createPort('m_we', PortDirection.input);
    createPort('m_adr', PortDirection.input, width: config.addressWidth);
    createPort('m_dat_out', PortDirection.input, width: config.dataWidth);
    // Byte-lane selects, driven by the testbench (defaults to all-ones for
    // whole-word access, a sub-word test drives a partial mask).
    createPort('m_sel', PortDirection.input, width: config.effectiveSelWidth);

    bus.cyc <= input('m_cyc');
    bus.stb <= input('m_stb');
    bus.we <= input('m_we');
    bus.adr <= input('m_adr');
    bus.datMosi <= input('m_dat_out');
    bus.sel <= input('m_sel');

    addOutput('m_dat_in', width: config.dataWidth);
    addOutput('m_ack');

    output('m_dat_in') <= bus.datMiso;
    output('m_ack') <= bus.ack;
  }
}

/// Integration test bench that connects a Wishbone master driver
/// to a peripheral via rohd_bridge's connectInterfaces.
///
/// Provides [write] and [read] helpers that drive bus transactions
/// and wait for ACK in simulation.
///
/// Usage:
/// ```dart
/// final gpio = HarborGpio(baseAddress: 0x1000, pinCount: 8);
/// gpio.port('gpio_in').getsLogic(someSignal);
///
/// final tb = PeripheralTestBench(gpio);
/// await tb.init();
///
/// await tb.write(1, 0xA5);
/// final val = await tb.read(1);
/// expect(val, equals(0xA5));
///
/// await Simulator.endSimulation();
/// ```
class PeripheralTestBench extends BridgeModule {
  final BridgeModule peripheral;
  late final WishboneMasterTestDriver master;
  late final Logic clk;
  late final int _selWidth;
  int get _fullSel => (1 << _selWidth) - 1;

  Logic get ack => master.output('m_ack');
  Logic get datIn => master.output('m_dat_in');

  PeripheralTestBench(this.peripheral, {String busName = 'bus'})
    : super('PeripheralTestBench', name: 'tb') {
    final clkGen = SimpleClockGenerator(10);
    clk = clkGen.clk;

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    final wb =
        peripheral.interface(busName).internalInterface! as WishboneInterface;
    _selWidth = wb.config.effectiveSelWidth;

    master = WishboneMasterTestDriver(config: wb.config);
    addSubModule(master);
    addSubModule(peripheral);

    connectPorts(port('clk'), master.port('clk'));
    connectPorts(port('clk'), peripheral.port('clk'));
    connectPorts(port('reset'), peripheral.port('reset'));
    connectInterfaces(master.interface('bus'), peripheral.interface(busName));

    pullUpPort(master.port('m_cyc'), newPortName: 'cyc');
    pullUpPort(master.port('m_stb'), newPortName: 'stb');
    pullUpPort(master.port('m_we'), newPortName: 'we');
    pullUpPort(master.port('m_adr'), newPortName: 'adr');
    pullUpPort(master.port('m_dat_out'), newPortName: 'dat_out');
    pullUpPort(master.port('m_sel'), newPortName: 'sel');
  }

  /// Builds the module hierarchy, asserts reset for 3 cycles,
  /// then deasserts. Starts the simulator.
  Future<void> init({int maxSimTime = 100000}) async {
    port('clk').getsLogic(clk);

    final resetSig = Logic(name: 'tb_reset');
    port('reset').getsLogic(resetSig);

    await build();

    resetSig.inject(1);
    input('cyc').inject(0);
    input('stb').inject(0);
    input('we').inject(0);
    input('adr').inject(0);
    input('dat_out').inject(0);
    input('sel').inject(_fullSel);

    Simulator.setMaxSimTime(maxSimTime);
    unawaited(Simulator.run());

    await clk.nextPosedge;
    await clk.nextPosedge;
    await clk.nextPosedge;
    resetSig.put(0);
    await clk.nextPosedge;
  }

  /// Performs a bus write transaction and waits for ACK. [sel] drives the
  /// byte-lane selects (defaults to all-ones for a whole-word write), pass a
  /// partial mask to exercise sub-word stores.
  Future<void> write(int address, int data, {int? sel}) async {
    input('cyc').put(1);
    input('stb').put(1);
    input('we').put(1);
    input('adr').put(address);
    input('dat_out').put(data);
    input('sel').put(sel ?? _fullSel);

    for (var i = 0; i < 10; i++) {
      await clk.nextPosedge;
      if (ack.value.isValid && ack.value.toInt() == 1) break;
    }

    input('cyc').put(0);
    input('stb').put(0);
    input('we').put(0);
    input('sel').put(_fullSel);
    await clk.nextPosedge;
  }

  /// Performs a bus read transaction and returns the data.
  Future<int> read(int address) async {
    input('cyc').put(1);
    input('stb').put(1);
    input('we').put(0);
    input('adr').put(address);

    for (var i = 0; i < 10; i++) {
      await clk.nextPosedge;
      if (ack.value.isValid && ack.value.toInt() == 1) break;
    }

    final data = datIn.value.isValid ? datIn.value.toInt() : 0;

    input('cyc').put(0);
    input('stb').put(0);
    await clk.nextPosedge;
    return data;
  }

  /// Waits for [n] clock cycles.
  Future<void> waitCycles(int n) async {
    for (var i = 0; i < n; i++) {
      await clk.nextPosedge;
    }
  }
}
