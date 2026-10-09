import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'usb_test_host.dart';

// Shared fixtures and harness modules for the usb_dfu_device_*_test.dart
// files. Kept out of a _test.dart file so dart test runs those files in
// parallel instead of serializing every HarborUsbDfu test onto one core.

/// A configurable [UsbDfuSinkInterface] consumer for tests: a ready/busy
/// pattern, and an optional one-shot error injected at a given byte index.
///
/// [readyOnCycles]/[readyOffCycles] cycle `ready` on then off. A zero
/// [readyOffCycles] holds `ready` high the whole run. [busyCyclesAfterEnd]
/// holds `busy` for that many cycles after every `block_done` pulse (a
/// block commit) or `end` pulse (the final manifest), then pulses `done`
/// once. 0 means never busy, so `done` just follows `block_done`/`end`
/// straight through.
class TestDfuSink extends BridgeModule {
  final int readyOnCycles;
  final int readyOffCycles;
  final int busyCyclesAfterEnd;
  final int errorAtByteIndex;
  final int errorCode;

  TestDfuSink({
    this.readyOnCycles = 1,
    this.readyOffCycles = 0,
    this.busyCyclesAfterEnd = 0,
    this.errorAtByteIndex = -1,
    this.errorCode = 0,
    String? name,
  }) : super('TestDfuSink', name: name ?? 'test_sink') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    // Re-exposes the provider side of the sink interface so a test can
    // watch the byte stream from the harness, without reaching across a
    // module boundary into another module's internal signals.
    addOutput('obs_byte_valid');
    addOutput('obs_byte_data', width: 8);
    addOutput('obs_block', width: 16);
    addOutput('obs_target', width: 8);
    addOutput('obs_block_done');
    addOutput('obs_end');

    final sinkRef = addInterface(
      UsbDfuSinkInterface(),
      name: 'sink',
      role: PairRole.consumer,
    );
    final sink = sinkRef.internalInterface!;

    output('obs_byte_valid') <= sink.valid;
    output('obs_byte_data') <= sink.data;
    output('obs_block') <= sink.block;
    output('obs_target') <= sink.target;
    output('obs_block_done') <= sink.blockDone;
    output('obs_end') <= sink.end;

    final clk = input('clk');
    final reset = input('reset');

    if (readyOffCycles <= 0) {
      sink.ready <= Const(1);
    } else {
      final period = readyOnCycles + readyOffCycles;
      final cyclePos = Logic(name: 'ready_cycle_pos_q', width: 32);
      Sequential(clk, [
        If(
          reset,
          then: [cyclePos < Const(0, width: 32)],
          orElse: [
            If(
              cyclePos.eq(Const(period - 1, width: 32)),
              then: [cyclePos < Const(0, width: 32)],
              orElse: [cyclePos < cyclePos + Const(1, width: 32)],
            ),
          ],
        ),
      ]);
      sink.ready <= cyclePos.lt(Const(readyOnCycles, width: 32));
    }

    final byteCount = Logic(name: 'byte_count_q', width: 32);
    final accept = (sink.valid & sink.ready).named('sink_accept');
    Sequential(clk, [
      If(
        reset,
        then: [byteCount < Const(0, width: 32)],
        orElse: [
          If(
            byteCount.lt(Const(0xFFFFFFFF, width: 32)) & accept,
            then: [byteCount < byteCount + Const(1, width: 32)],
          ),
        ],
      ),
    ]);

    if (errorAtByteIndex >= 0) {
      final errorNow =
          (accept & byteCount.eq(Const(errorAtByteIndex, width: 32))).named(
            'err_now',
          );
      sink.error <=
          mux(errorNow, Const(errorCode, width: 4), Const(0, width: 4));
    } else {
      sink.error <= Const(0, width: 4);
    }

    final startBusy = (sink.blockDone | sink.end).named('start_busy');
    if (busyCyclesAfterEnd <= 0) {
      sink.busy <= Const(0);
      sink.done <= startBusy;
    } else {
      final busyCounter = Logic(name: 'busy_counter_q', width: 32);
      final busyReg = Logic(name: 'busy_q');
      final doneReg = Logic(name: 'done_q');
      Sequential(clk, [
        If(
          reset,
          then: [
            busyCounter < Const(0, width: 32),
            busyReg < Const(0),
            doneReg < Const(0),
          ],
          orElse: [
            doneReg < Const(0),
            If(
              startBusy,
              then: [
                busyReg < Const(1),
                busyCounter < Const(busyCyclesAfterEnd, width: 32),
              ],
              orElse: [
                If(
                  busyReg,
                  then: [
                    If(
                      busyCounter.lte(Const(1, width: 32)),
                      then: [
                        busyReg < Const(0),
                        busyCounter < Const(0, width: 32),
                        doneReg < Const(1),
                      ],
                      orElse: [busyCounter < busyCounter - Const(1, width: 32)],
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ]);
      sink.busy <= busyReg;
      sink.done <= doneReg;
    }

    // This test sink has no FIFO to drain, so it acks `clear` as soon as
    // it sees it: one cycle later, never held off.
    final clearAckReg = Logic(name: 'clear_ack_q');
    Sequential(clk, [
      If(
        reset,
        then: [clearAckReg < Const(0)],
        orElse: [clearAckReg < sink.clear],
      ),
    ]);
    sink.clearDone <= clearAckReg;
  }
}

/// Wraps [HarborUsbCore], [HarborUsbDfu] and a [TestDfuSink], exposing the
/// pad-level shape for [UsbTestHost] plus the DFU state outputs and the
/// provider side of the sink interface for a test to sample directly.
class UsbDfuHarness extends BridgeModule {
  UsbDfuHarness({
    int pollTimeoutMs = 10,
    int readyOnCycles = 1,
    int readyOffCycles = 0,
    int busyCyclesAfterEnd = 0,
    int errorAtByteIndex = -1,
    int errorCode = 0,
    String? name,
  }) : super('UsbDfuHarness', name: name ?? 'dfu_h') {
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
    addOutput('dfu_state', width: 4);
    addOutput('dfu_status', width: 4);
    addOutput('sink_byte_valid');
    addOutput('sink_byte_data', width: 8);
    addOutput('sink_block', width: 16);
    addOutput('sink_target', width: 8);
    addOutput('sink_block_done');
    addOutput('sink_end');

    final clk = input('clk');
    final reset = input('reset');

    final core = HarborUsbCore(
      descriptors: HarborUsbDfu.dfuDescriptors(),
      name: 'core',
    );
    addSubModule(core);
    core.input('clk').srcConnection! <= clk;
    core.input('reset').srcConnection! <= reset;
    core.input('dp').srcConnection! <= input('dp');
    core.input('dm').srcConnection! <= input('dm');

    final dfu = HarborUsbDfu(pollTimeoutMs: pollTimeoutMs, name: 'dfu');
    addSubModule(dfu);
    dfu.input('clk').srcConnection! <= clk;
    dfu.input('reset').srcConnection! <= reset;

    connectInterfaces(core.interface('func'), dfu.interface('usb'));

    final sink = TestDfuSink(
      readyOnCycles: readyOnCycles,
      readyOffCycles: readyOffCycles,
      busyCyclesAfterEnd: busyCyclesAfterEnd,
      errorAtByteIndex: errorAtByteIndex,
      errorCode: errorCode,
      name: 'sink',
    );
    addSubModule(sink);
    sink.input('clk').srcConnection! <= clk;
    sink.input('reset').srcConnection! <= reset;

    connectInterfaces(dfu.interface('sink'), sink.interface('sink'));

    output('dp_out') <= core.output('dp_out');
    output('dm_out') <= core.output('dm_out');
    output('oe') <= core.output('oe');
    output('dev_addr') <= core.output('dev_addr');
    output('configured') <= core.output('configured');
    output('bus_reset') <= core.output('bus_reset');
    output('dfu_state') <= dfu.output('dfu_state');
    output('dfu_status') <= dfu.output('dfu_status');

    output('sink_byte_valid') <= sink.output('obs_byte_valid');
    output('sink_byte_data') <= sink.output('obs_byte_data');
    output('sink_block') <= sink.output('obs_block');
    output('sink_target') <= sink.output('obs_target');
    output('sink_block_done') <= sink.output('obs_block_done');
    output('sink_end') <= sink.output('obs_end');
  }
}

/// Builds a [UsbDfuHarness] wired to a [UsbTestHost], releases reset, and
/// returns both plus the raw clk/dp/dm signals a test may need directly.
Future<(UsbDfuHarness, UsbTestHost, Logic, Logic, Logic)> buildDfuHarness({
  int pollTimeoutMs = 10,
  int readyOnCycles = 1,
  int readyOffCycles = 0,
  int busyCyclesAfterEnd = 0,
  int errorAtByteIndex = -1,
  int errorCode = 0,
  int maxSimTime = 6000000,
}) async {
  final dut = UsbDfuHarness(
    pollTimeoutMs: pollTimeoutMs,
    readyOnCycles: readyOnCycles,
    readyOffCycles: readyOffCycles,
    busyCyclesAfterEnd: busyCyclesAfterEnd,
    errorAtByteIndex: errorAtByteIndex,
    errorCode: errorCode,
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
  Simulator.setMaxSimTime(maxSimTime);
  unawaited(Simulator.run());

  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.inject(0);
  for (var i = 0; i < 30; i++) {
    await clk.nextPosedge;
  }

  return (dut, host, clk, dp, dm);
}

/// Enumerates [dut]/[host] to the configured state: SET_ADDRESS(1),
/// SET_CONFIGURATION(1), SET_INTERFACE alt [altSetting]. Every DFU test
/// starts from here.
Future<void> enumerateDfu(
  UsbDfuHarness dut,
  UsbTestHost host, {
  int altSetting = 0,
}) async {
  final setAddr = <int>[0x00, 0x05, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00];
  if (!await host.controlNoData(0, setAddr)) {
    throw StateError('SET_ADDRESS failed');
  }
  final setCfg = <int>[0x00, 0x09, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00];
  if (!await host.controlNoData(1, setCfg)) {
    throw StateError('SET_CONFIGURATION failed');
  }
  final setIntf = <int>[0x01, 0x0B, altSetting, 0x00, 0x00, 0x00, 0x00, 0x00];
  if (!await host.controlNoData(1, setIntf)) {
    throw StateError('SET_INTERFACE failed');
  }
}

// DFU 1.1 class bRequest values, for building SETUP packets in tests.
const int dfuReqDnload = 1;
const int dfuReqUpload = 2;
const int dfuReqGetStatus = 3;
const int dfuReqClrStatus = 4;
const int dfuReqGetState = 5;
const int dfuReqAbort = 6;

List<int> dfuSetup({
  required bool dirIn,
  required int bRequest,
  int wValue = 0,
  int wLength = 0,
}) {
  final bmRequestType = (dirIn ? 0x80 : 0x00) | 0x21; // class, interface
  return <int>[
    bmRequestType,
    bRequest,
    wValue & 0xFF,
    (wValue >> 8) & 0xFF,
    0x00,
    0x00,
    wLength & 0xFF,
    (wLength >> 8) & 0xFF,
  ];
}

/// Watches a [UsbDfuHarness]'s sink-side outputs for the rest of the test
/// and appends every accepted byte (with its block number and target) to
/// the returned lists. Cancel the returned subscription when done.
({
  List<int> bytes,
  List<int> blocks,
  List<int> targets,
  StreamSubscription<void> sub,
})
watchSink(UsbDfuHarness dut) {
  final bytes = <int>[];
  final blocks = <int>[];
  final targets = <int>[];
  final sub = dut.output('sink_byte_valid').changed.listen((e) {
    if (!e.newValue.isValid || !e.newValue.toBool()) return;
    final d = dut.output('sink_byte_data').value;
    final b = dut.output('sink_block').value;
    final t = dut.output('sink_target').value;
    if (d.isValid) bytes.add(d.toInt());
    if (b.isValid) blocks.add(b.toInt());
    if (t.isValid) targets.add(t.toInt());
  });
  return (bytes: bytes, blocks: blocks, targets: targets, sub: sub);
}

/// Counts rising pulses on a one-bit [UsbDfuHarness] output (`sink_end` or
/// `sink_block_done`) for the rest of the test. Read `.count.value` at any
/// point. Cancel `.sub` when done.
({_PulseCount count, StreamSubscription<void> sub}) watchPulses(
  UsbDfuHarness dut,
  String outputName,
) {
  final count = _PulseCount();
  final sub = dut.output(outputName).changed.listen((e) {
    if (e.newValue.isValid && e.newValue.toBool()) count.value++;
  });
  return (count: count, sub: sub);
}

/// A mutable pulse count, boxed so [watchPulses]' listener closure can bump
/// it after the function returns.
class _PulseCount {
  int value = 0;
}
