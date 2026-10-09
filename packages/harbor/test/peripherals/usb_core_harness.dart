import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'usb_test_host.dart';

// Shared fixtures and harness modules for the usb_core_*_test.dart files.
// Kept out of a _test.dart file so dart test runs those files in parallel
// instead of serializing every HarborUsbCore test onto one core.

// A minimal device descriptor (18 bytes).
const devDesc = <int>[
  18, 1, 0x00, 0x02, 0x00, 0x00, 0x00, 64, //
  0x09, 0x12, 0xF1, 0x5B, 0x00, 0x01, 0, 0, 0, 1,
];

// The config descriptor header alone, what GET_DESCRIPTOR(CONFIGURATION)
// returns for a wLength 9 request.
const cfgDescHeader = <int>[9, 2, 27, 0x00, 1, 1, 0, 0x80, 50];

// A config descriptor with one interface, alt setting 0 only. Used by a
// harness that never exercises an alternate setting, so SET_INTERFACE(0,
// 0) still has a real pair to match.
const cfgDescOneIface = <int>[
  9,
  2,
  18,
  0x00,
  1,
  1,
  0,
  0x80,
  50,
  9,
  4,
  0,
  0,
  0,
  0xFF,
  0x00,
  0x00,
  0,
];

// Full config descriptor: the header plus one interface with two
// alternate settings, so a SET_INTERFACE test has a real pair to pick.
const cfgDesc = <int>[
  ...cfgDescHeader,
  9,
  4,
  0,
  0,
  0,
  0xFF,
  0x00,
  0x00,
  0,
  9,
  4,
  0,
  1,
  0,
  0xFF,
  0x00,
  0x00,
  0,
];

// A STRING descriptor sized exactly to maxPacketSize (64 bytes), to
// exercise the IN data stage's trailing ZLP at a packet boundary.
final boundaryDesc64 = List<int>.generate(
  64,
  (i) => switch (i) {
    0 => 64,
    1 => 0x03,
    _ => i & 0xFF,
  },
);

// Reset timer threshold in HarborUsbFsResetDet is 30000 cycles. Hold SE0
// well past that.
const busResetHoldCycles = 33000;

/// A tiny function device for [HarborUsbCore]: accepts bRequest 0x01 (OUT,
/// stores bytes) and 0x02 (IN, returns [1 .. inResponseLength] mod 256).
/// Stalls everything else. [blockOutReadyCycles] holds ep0_out_ready low
/// for that many cycles after every SETUP, to exercise the engine's
/// NAK-while-busy behavior.
class TestFunctionDevice extends BridgeModule {
  final int blockOutReadyCycles;
  final int inResponseLength;

  TestFunctionDevice({
    this.blockOutReadyCycles = 0,
    this.inResponseLength = 5,
    String? name,
  }) : super('TestFunctionDevice', name: name ?? 'test_fn') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    addOutput('out_byte_valid');
    addOutput('out_byte_data', width: 8);
    addOutput('out_end_pulse');

    final funcRef = addInterface(
      UsbFunctionInterface(),
      name: 'func',
      role: PairRole.consumer,
    );
    final func = funcRef.internalInterface!;

    final clk = input('clk');
    final reset = input('reset');

    final setupValid = func.setupValid;
    final bRequest = func.setupData.slice(15, 8);
    final isOut = bRequest.eq(Const(1, width: 8)).named('is_test_out');
    final isIn = bRequest.eq(Const(2, width: 8)).named('is_test_in');

    func.setupAccept <= setupValid & (isOut | isIn);
    func.setupStall <= setupValid & ~(isOut | isIn);

    final activeOut = Logic(name: 'active_out_q');
    final activeIn = Logic(name: 'active_in_q');
    Sequential(clk, [
      If(
        reset,
        then: [activeOut < Const(0), activeIn < Const(0)],
        orElse: [
          If(setupValid, then: [activeOut < isOut, activeIn < isIn]),
        ],
      ),
    ]);

    // Holds ep0_out_ready low for blockOutReadyCycles after every SETUP.
    final blockCounter = Logic(name: 'block_counter_q', width: 20);
    Sequential(clk, [
      If(
        reset,
        then: [blockCounter < Const(0, width: 20)],
        orElse: [
          If(
            setupValid,
            then: [blockCounter < Const(blockOutReadyCycles, width: 20)],
            orElse: [
              If(
                blockCounter.gt(Const(0, width: 20)),
                then: [blockCounter < blockCounter - Const(1, width: 20)],
              ),
            ],
          ),
        ],
      ),
    ]);
    func.ep0OutReady <= activeOut & blockCounter.eq(Const(0, width: 20));
    output('out_byte_valid') <= func.ep0OutValid & func.ep0OutReady;
    output('out_byte_data') <= func.ep0OutData;
    output('out_end_pulse') <= func.ep0OutEnd;

    // Streams bytes 1..inResponseLength, marking the last as last.
    final inIndex = Logic(name: 'in_index_q', width: 8);
    final accepted = func.ep0InValid & func.ep0InReady;
    Sequential(clk, [
      If(
        reset,
        then: [inIndex < Const(0, width: 8)],
        orElse: [
          If(setupValid, then: [inIndex < Const(0, width: 8)]),
          If(accepted, then: [inIndex < inIndex + Const(1, width: 8)]),
        ],
      ),
    ]);
    func.ep0InValid <= activeIn & inIndex.lt(Const(inResponseLength, width: 8));
    func.ep0InData <= (inIndex + Const(1, width: 8)).zeroExtend(8);
    func.ep0InLast <= inIndex.eq(Const(inResponseLength - 1, width: 8));
  }
}

/// Wraps [HarborUsbCore] and a [TestFunctionDevice] connected through the
/// `func` interface, exposing the same pad-level shape as a device so
/// [UsbTestHost] can drive it directly.
class UsbCoreHarness extends BridgeModule {
  UsbCoreHarness({
    required List<UsbDescriptorEntry> descriptors,
    int blockOutReadyCycles = 0,
    int inResponseLength = 5,
    String? name,
  }) : super('UsbCoreHarness', name: name ?? 'harness') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('dp', PortDirection.input);
    createPort('dm', PortDirection.input);
    addOutput('dp_out');
    addOutput('dm_out');
    addOutput('oe');
    addOutput('dev_addr', width: 7);
    addOutput('configured');
    addOutput('bus_reset');
    addOutput('out_byte_valid');
    addOutput('out_byte_data', width: 8);
    addOutput('out_end_pulse');

    final clk = input('clk');
    final reset = input('reset');

    final core = HarborUsbCore(descriptors: descriptors, name: 'core');
    addSubModule(core);
    core.input('clk').srcConnection! <= clk;
    core.input('reset').srcConnection! <= reset;
    core.input('dp').srcConnection! <= input('dp');
    core.input('dm').srcConnection! <= input('dm');

    final fn = TestFunctionDevice(
      blockOutReadyCycles: blockOutReadyCycles,
      inResponseLength: inResponseLength,
      name: 'fn',
    );
    addSubModule(fn);
    fn.input('clk').srcConnection! <= clk;
    fn.input('reset').srcConnection! <= reset;

    connectInterfaces(core.interface('func'), fn.interface('func'));

    output('dp_out') <= core.output('dp_out');
    output('dm_out') <= core.output('dm_out');
    output('oe') <= core.output('oe');
    output('dev_addr') <= core.output('dev_addr');
    output('configured') <= core.output('configured');
    output('bus_reset') <= core.output('bus_reset');
    output('out_byte_valid') <= fn.output('out_byte_valid');
    output('out_byte_data') <= fn.output('out_byte_data');
    output('out_end_pulse') <= fn.output('out_end_pulse');
  }
}

/// A minimal function device with one extra OUT and one extra IN bulk
/// endpoint, to prove the core's pass-through wiring for an endpoint
/// beyond 0. Every SETUP is stalled, and endpoint 0 is otherwise unused.
class Ep1PassthroughFunction extends BridgeModule {
  /// Stalls EP1 IN from the function's own side, independent of any
  /// host SET_FEATURE, to exercise GET_STATUS(endpoint) reporting a
  /// function-initiated stall.
  final bool selfStallIn;

  Ep1PassthroughFunction({this.selfStallIn = false, String? name})
    : super('Ep1PassthroughFunction', name: name ?? 'ep1_fn') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    // While high, EP1 OUT is not drained, so its packet stays held.
    createPort('out_hold', PortDirection.input);
    addOutput('out_byte_valid');
    addOutput('out_byte_data', width: 8);

    final funcRef = addInterface(
      UsbFunctionInterface(numOutEps: 1, numInEps: 1),
      name: 'func',
      role: PairRole.consumer,
    );
    final func = funcRef.internalInterface!;
    final clk = input('clk');
    final reset = input('reset');

    func.setupStall <= func.setupValid;
    func.setupAccept <= Const(0);
    func.ep0OutReady <= Const(0);
    func.ep0InValid <= Const(0);
    func.ep0InData <= Const(0, width: 8);
    func.ep0InLast <= Const(0);

    // EP1 OUT: the same two-phase drain shape the core itself uses for
    // EP0 OUT (out_ep_data already holds the byte at the pulse cycle).
    final ep1Avail = func.port('out_ep_data_avail');
    final ep1Data = func.port('out_ep_data');
    final getReg = Logic(name: 'ep1_get_q');
    final drainPhase = Logic(name: 'ep1_drain_phase_q');
    func.port('out_ep_req') <= ep1Avail;
    func.port('out_ep_stall') <= Const(0, width: 1);
    Sequential(clk, [
      If(
        reset,
        then: [getReg < Const(0), drainPhase < Const(0)],
        orElse: [
          If(
            drainPhase.eq(Const(0)) & ep1Avail & ~input('out_hold'),
            then: [getReg < Const(1), drainPhase < Const(1)],
            orElse: [getReg < Const(0)],
          ),
          If(drainPhase.eq(Const(1)), then: [drainPhase < Const(0)]),
        ],
      ),
    ]);
    func.port('out_ep_data_get') <= getReg;
    output('out_byte_valid') <= getReg;
    output('out_byte_data') <= ep1Data;

    // EP1 IN: put a single fixed byte for every packet the engine is
    // ready for. put is registered, not a same-cycle function of
    // ep1Free: driving it straight from the engine's own free output
    // would feed back into the engine's Combinational pass that
    // produced it. The rising-edge check fires once per fresh packet
    // opportunity, not on every cycle ep1Free happens to stay high.
    final ep1Free = func.port('in_ep_data_free');
    final ep1FreeQ = Logic(name: 'ep1_free_prev_q');
    final put = Logic(name: 'ep1_in_put_q');
    Sequential(clk, [
      If(
        reset,
        then: [ep1FreeQ < Const(0), put < Const(0)],
        orElse: [put < (ep1Free & ~ep1FreeQ), ep1FreeQ < ep1Free],
      ),
    ]);
    // in_ep_req picks which channel's byte lands on the shared data
    // bus, so it must be high the same cycle as in_ep_data_put, not
    // the cycle armed was still high.
    func.port('in_ep_req') <= put;
    func.port('in_ep_data_put') <= put;
    func.port('in_ep_data') <= Const(0x42, width: 8);
    func.port('in_ep_data_done') <= put;
    func.port('in_ep_stall') <= Const(selfStallIn ? 1 : 0, width: 1);
  }
}

/// Wraps [HarborUsbCore] (with one extra OUT and one extra IN endpoint)
/// and [Ep1PassthroughFunction], exposing the pad-level shape so
/// [UsbTestHost] can drive EP1 traffic directly.
class Ep1Harness extends BridgeModule {
  Ep1Harness({bool selfStallIn = false, String? name})
    : super('Ep1Harness', name: name ?? 'ep1_h') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('out_hold', PortDirection.input);
    createPort('dp', PortDirection.input);
    createPort('dm', PortDirection.input);
    addOutput('dp_out');
    addOutput('dm_out');
    addOutput('oe');
    addOutput('out_byte_valid');
    addOutput('out_byte_data', width: 8);

    final clk = input('clk');
    final reset = input('reset');

    final core = HarborUsbCore(
      descriptors: [
        const UsbDescriptorEntry(0x01, 0, devDesc),
        const UsbDescriptorEntry(0x02, 0, cfgDescOneIface),
      ],
      numOutEps: 1,
      numInEps: 1,
      name: 'core',
    );
    addSubModule(core);
    core.input('clk').srcConnection! <= clk;
    core.input('reset').srcConnection! <= reset;
    core.input('dp').srcConnection! <= input('dp');
    core.input('dm').srcConnection! <= input('dm');

    final fn = Ep1PassthroughFunction(selfStallIn: selfStallIn, name: 'fn');
    addSubModule(fn);
    fn.input('clk').srcConnection! <= clk;
    fn.input('reset').srcConnection! <= reset;
    fn.input('out_hold').srcConnection! <= input('out_hold');

    connectInterfaces(core.interface('func'), fn.interface('func'));

    output('dp_out') <= core.output('dp_out');
    output('dm_out') <= core.output('dm_out');
    output('oe') <= core.output('oe');
    output('out_byte_valid') <= fn.output('out_byte_valid');
    output('out_byte_data') <= fn.output('out_byte_data');
  }
}

/// Builds a [UsbCoreHarness] wired to a [UsbTestHost], releases reset, and
/// returns both plus the raw clk/dp/dm signals a test may need directly.
Future<(UsbCoreHarness, UsbTestHost, Logic, Logic, Logic)> buildCoreHarness({
  int blockOutReadyCycles = 0,
  int inResponseLength = 5,
}) async {
  final dut = UsbCoreHarness(
    descriptors: [
      const UsbDescriptorEntry(0x01, 0, devDesc),
      const UsbDescriptorEntry(0x02, 0, cfgDesc),
      UsbDescriptorEntry(0x03, 9, boundaryDesc64),
    ],
    blockOutReadyCycles: blockOutReadyCycles,
    inResponseLength: inResponseLength,
  );

  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final dp = Logic(name: 'dp');
  final dm = Logic(name: 'dm');

  dut.input('clk').srcConnection! <= clk;
  dut.input('reset').srcConnection! <= reset;
  dut.input('dp').srcConnection! <= dp;
  dut.input('dm').srcConnection! <= dm;

  final host = UsbTestHost(
    clk: clk,
    reset: reset,
    dp: dp,
    dm: dm,
    devOe: dut.output('oe'),
    devDp: dut.output('dp_out'),
    devDm: dut.output('dm_out'),
  );

  await dut.build();
  await host.build();

  reset.inject(1);
  dp.inject(1);
  dm.inject(0);
  Simulator.setMaxSimTime(6000000);
  unawaited(Simulator.run());

  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.inject(0);
  for (var i = 0; i < 30; i++) {
    await clk.nextPosedge;
  }

  return (dut, host, clk, dp, dm);
}

/// Builds an [Ep1Harness] wired to a [UsbTestHost], releases reset, and
/// returns both plus the raw clk/dp/dm signals a test may need directly.
Future<(Ep1Harness, UsbTestHost, Logic, Logic, Logic)> buildEp1Harness({
  bool selfStallIn = false,
}) async {
  final dut = Ep1Harness(selfStallIn: selfStallIn);
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final dp = Logic(name: 'dp');
  final dm = Logic(name: 'dm');
  final hold = Logic(name: 'out_hold');
  dut.input('out_hold').srcConnection! <= hold;

  dut.input('clk').srcConnection! <= clk;
  dut.input('reset').srcConnection! <= reset;
  dut.input('dp').srcConnection! <= dp;
  dut.input('dm').srcConnection! <= dm;

  final host = UsbTestHost(
    clk: clk,
    reset: reset,
    dp: dp,
    dm: dm,
    devOe: dut.output('oe'),
    devDp: dut.output('dp_out'),
    devDm: dut.output('dm_out'),
  );

  await dut.build();
  await host.build();

  reset.inject(1);
  hold.inject(0);
  dp.inject(1);
  dm.inject(0);
  Simulator.setMaxSimTime(2000000);
  unawaited(Simulator.run());

  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.inject(0);
  for (var i = 0; i < 30; i++) {
    await clk.nextPosedge;
  }

  return (dut, host, clk, dp, dm);
}
