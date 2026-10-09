import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'usb_test_host.dart';

// Shared fixtures for the usb_controller_*_test.dart files. Kept out of a
// _test.dart file so dart test runs those files in parallel.

/// A single-outstanding Wishbone master driven by test code, wired to
/// [HarborUsbController]'s bus slave.
class _UsbWbMaster extends BridgeModule {
  _UsbWbMaster({required WishboneConfig config})
    : super('UsbWbMaster', name: 'wb_master') {
    createPort('clk', PortDirection.input);
    addInterface(
      WishboneInterface(config),
      name: 'bus',
      role: PairRole.provider,
    );
    final bus = interface('bus').internalInterface! as WishboneInterface;

    createPort('m_cyc', PortDirection.input);
    createPort('m_stb', PortDirection.input);
    createPort('m_we', PortDirection.input);
    createPort('m_adr', PortDirection.input, width: config.addressWidth);
    createPort('m_dat_out', PortDirection.input, width: config.dataWidth);
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

/// Wraps [HarborUsbController] with a Wishbone test master on the bus
/// clock and exposes the line pins for a [UsbTestHost].
class UsbControllerHarness extends BridgeModule {
  final int numEndpoints;
  late final _UsbWbMaster _master;

  UsbControllerHarness({
    this.numEndpoints = 4,
    int localResetDetachUs = 10000,
    String? name,
  }) : super('UsbControllerHarness', name: name ?? 'ctrl_h') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('usb_clk', PortDirection.input);
    createPort('usb_reset', PortDirection.input);
    createPort('dp', PortDirection.input);
    createPort('dm', PortDirection.input);
    addOutput('dp_out');
    addOutput('dm_out');
    addOutput('oe');
    addOutput('interrupt');
    addOutput('usb_pullup');

    final usb = HarborUsbController(
      baseAddress: 0,
      numEndpoints: numEndpoints,
      localResetDetachUs: localResetDetachUs,
      name: 'usb',
    );
    addSubModule(usb);
    usb.input('clk').srcConnection! <= input('clk');
    usb.input('reset').srcConnection! <= input('reset');
    usb.input('usb_clk').srcConnection! <= input('usb_clk');
    usb.input('usb_reset').srcConnection! <= input('usb_reset');
    usb.input('dp').srcConnection! <= input('dp');
    usb.input('dm').srcConnection! <= input('dm');

    final wb = usb.interface('bus').internalInterface! as WishboneInterface;
    _master = _UsbWbMaster(config: wb.config);
    addSubModule(_master);
    _master.input('clk').srcConnection! <= input('clk');
    connectInterfaces(_master.interface('bus'), usb.interface('bus'));

    pullUpPort(_master.port('m_cyc'), newPortName: 'cyc');
    pullUpPort(_master.port('m_stb'), newPortName: 'stb');
    pullUpPort(_master.port('m_we'), newPortName: 'we');
    pullUpPort(_master.port('m_adr'), newPortName: 'adr');
    pullUpPort(_master.port('m_dat_out'), newPortName: 'dat_out');
    pullUpPort(_master.port('m_sel'), newPortName: 'sel');
    pullUpPort(_master.port('m_dat_in'), newPortName: 'dat_in');
    pullUpPort(_master.port('m_ack'), newPortName: 'ack');

    output('dp_out') <= usb.output('dp_out');
    output('dm_out') <= usb.output('dm_out');
    output('oe') <= usb.output('oe');
    output('interrupt') <= usb.output('interrupt');
    output('usb_pullup') <= usb.output('usb_pullup');
  }

  int get _selWidth =>
      (_master.interface('bus').internalInterface! as WishboneInterface)
          .config
          .effectiveSelWidth;
  int get _fullSel => (1 << _selWidth) - 1;

  Logic get ack => output('ack');
  Logic get datIn => output('dat_in');

  /// Performs a bus write and waits for ack.
  ///
  /// Always settles the bus clock for one cycle first. The extra cycle is
  /// harmless either way. [sel] selects the byte lanes, all lanes if null.
  Future<void> write(Logic clk, int address, int data, {int? sel}) async {
    await clk.nextPosedge;
    input('cyc').put(1);
    input('stb').put(1);
    input('we').put(1);
    input('adr').put(address);
    input('dat_out').put(data);
    input('sel').put(sel ?? _fullSel);

    var guard = 0;
    while (!(ack.value.isValid && ack.value.toInt() == 1)) {
      await clk.nextPosedge;
      if (++guard > 2000) {
        throw TimeoutException(
          'timeout waiting for ack on write 0x'
          '${address.toRadixString(16)}',
        );
      }
    }
    input('cyc').put(0);
    input('stb').put(0);
    input('we').put(0);
    await clk.nextPosedge;
  }

  /// Performs a bus read and returns the data.
  ///
  /// See [write]: it also settles the bus clock for one cycle first.
  Future<int> read(Logic clk, int address) async {
    await clk.nextPosedge;
    input('cyc').put(1);
    input('stb').put(1);
    input('we').put(0);
    input('adr').put(address);
    input('sel').put(_fullSel);

    var guard = 0;
    while (!(ack.value.isValid && ack.value.toInt() == 1)) {
      await clk.nextPosedge;
      if (++guard > 2000) {
        throw TimeoutException(
          'timeout waiting for ack on read 0x'
          '${address.toRadixString(16)}',
        );
      }
    }
    final data = datIn.value.isValid ? datIn.value.toInt() : 0;
    input('cyc').put(0);
    input('stb').put(0);
    await clk.nextPosedge;
    return data;
  }
}

// Register offsets (must track lib/src/peripherals/usb.dart).
const ctrlAddr = 0x000;
const statusAddr = 0x008;
const addrAddr = 0x010;
const intStatusAddr = 0x018;
const intEnableAddr = 0x020;
const frameAddr = 0x028;

const epBase = 0x200;
const epStride = 0x40;
const cfgOff = 0x00;
const outStatOff = 0x08;
const outDataOff = 0x10;
const outAckOff = 0x18;
const inDataOff = 0x20;
const inCommitOff = 0x28;
const inStatOff = 0x30;

int epAddr(int ep, int off) => epBase + ep * epStride + off;

/// Polls OUT_STAT of [ep] until its ready bit sets and returns the value.
Future<int> waitOutReady(
  UsbControllerHarness dut,
  Logic clk,
  int ep, {
  int maxPolls = 500,
}) async {
  var status = await dut.read(clk, epAddr(ep, outStatOff));
  for (var i = 0; (status & 0x1) == 0 && i < maxPolls; i++) {
    await clk.nextPosedge;
    status = await dut.read(clk, epAddr(ep, outStatOff));
  }
  return status;
}

/// Builds a [UsbControllerHarness] wired to a [UsbTestHost] on two
/// independent clocks: `clk` (bus, period [busPeriod]) and `usb_clk` (the
/// PE's 48 MHz domain, period [usbPeriod]). Releases both resets and returns
/// everything a test needs.
Future<
  (UsbControllerHarness dut, UsbTestHost host, Logic clk, Logic dp, Logic dm)
>
buildUsbControllerHarness({
  int numEndpoints = 4,
  int maxSimTime = 8000000,
  int busPeriod = 20,
  int usbPeriod = 10,
  int localResetDetachUs = 10000,
}) async {
  final dut = UsbControllerHarness(
    numEndpoints: numEndpoints,
    localResetDetachUs: localResetDetachUs,
  );

  final clk = SimpleClockGenerator(busPeriod).clk;
  final usbClk = SimpleClockGenerator(usbPeriod).clk;
  final reset = Logic(name: 'reset');
  final usbReset = Logic(name: 'usb_reset');
  final dp = Logic(name: 'dp');
  final dm = Logic(name: 'dm');

  dut.input('clk').srcConnection! <= clk;
  dut.input('reset').srcConnection! <= reset;
  dut.input('usb_clk').srcConnection! <= usbClk;
  dut.input('usb_reset').srcConnection! <= usbReset;
  dut.input('dp').srcConnection! <= dp;
  dut.input('dm').srcConnection! <= dm;

  final host = UsbTestHost(
    clk: usbClk,
    reset: usbReset,
    dp: dp,
    dm: dm,
    devOe: dut.output('oe'),
    devDp: dut.output('dp_out'),
    devDm: dut.output('dm_out'),
  );

  await dut.build();
  await host.build();

  reset.inject(1);
  usbReset.inject(1);
  dp.inject(1);
  dm.inject(0);
  dut.input('cyc').inject(0);
  dut.input('stb').inject(0);
  dut.input('we').inject(0);
  dut.input('adr').inject(0);
  dut.input('dat_out').inject(0);
  dut.input('sel').inject(0xf);

  Simulator.setMaxSimTime(maxSimTime);
  unawaited(Simulator.run());

  // The controller joins its resets through short flop chains in each
  // domain, so hold both resets for 8 edges of each clock.
  for (var i = 0; i < 8; i++) {
    await clk.nextPosedge;
  }
  for (var i = 0; i < 8; i++) {
    await usbClk.nextPosedge;
  }
  reset.inject(0);
  usbReset.inject(0);
  for (var i = 0; i < 40; i++) {
    await usbClk.nextPosedge;
  }

  return (dut, host, clk, dp, dm);
}

/// Pushes and commits EP1 IN packets of [sizes] bytes, each with every
/// phase in [phases] (extra bus cycles between the last IN_DATA and the
/// IN_COMMIT), and checks that the host reads each packet whole.
Future<void> inCommitSweep(
  UsbControllerHarness dut,
  UsbTestHost host,
  Logic clk, {
  List<int> sizes = const [0, 1, 7, 63, 64],
  List<int> phases = const [0, 1, 2],
}) async {
  await dut.write(clk, ctrlAddr, 0x3);
  // EP1: enable, type bulk.
  await dut.write(clk, epAddr(1, cfgOff), 0x5);
  var seed = 1;
  for (final size in sizes) {
    for (final phase in phases) {
      final payload = [for (var i = 0; i < size; i++) (seed + i * 7) & 0xFF];
      seed += 13;
      for (final b in payload) {
        await dut.write(clk, epAddr(1, inDataOff), b);
      }
      for (var i = 0; i < phase; i++) {
        await clk.nextPosedge;
      }
      await dut.write(clk, epAddr(1, inCommitOff), 1);

      UsbTestPacket? pkt;
      for (var tries = 0; tries < 20; tries++) {
        await host.sendToken(9, 0, 1);
        pkt = await host.waitPacket();
        if (pkt != null && pkt.pid != 10) break;
        await host.idle(20);
      }
      if (pkt == null || (pkt.pid != 3 && pkt.pid != 11)) {
        throw StateError('size $size phase $phase: no data packet');
      }
      if (pkt.payload.length != size || !_listEquals(pkt.payload, payload)) {
        throw StateError(
          'size $size phase $phase: got ${pkt.payload.length} bytes '
          '${pkt.payload}, want $payload',
        );
      }
      await host.idle(2);
      await host.sendHandshake(2);
      await host.idle(30);
      var stat = await dut.read(clk, epAddr(1, inStatOff));
      for (var i = 0; (stat & 0x2) == 0 && i < 200; i++) {
        stat = await dut.read(clk, epAddr(1, inStatOff));
      }
      if ((stat & 0x2) == 0) {
        throw StateError('size $size phase $phase: no IN-done');
      }
    }
  }
}

bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
