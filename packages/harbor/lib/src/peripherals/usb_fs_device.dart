/// The vendor bulk USB device Mimic and Glacier run on: ch9 control on
/// endpoint 0, served by [HarborUsbCore], and a vendor command/response
/// stream on endpoint 1. Every class or vendor SETUP stalls, because the
/// whole vendor protocol lives on the bulk endpoint.
///
/// Endpoint 1 streams the vendor command protocol: OUT bytes arrive on
/// cmd_valid/cmd_data with a cmd_ready handshake (one byte per three
/// cycles), IN bytes leave on
/// resp_valid/resp_data with a resp_ready handshake and resp_last marking
/// the final byte of a response. cmd_start pulses on the first packet of
/// every EP1 OUT transfer so the command engine can preempt a stale
/// response. A packet that continues a transfer, which is a packet that
/// follows a full-size packet, gives no pulse.
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'usb_core.dart';
import 'usb_descriptors.dart' show UsbDescriptorEntry;

/// Vendor full-speed USB device on [HarborUsbCore].
class HarborUsbFsDevice extends BridgeModule {
  /// Width of the counter behind [ep1StartStallCycles].
  static const int _ep1StallBits = 22;

  /// The largest bound the counter can hold.
  static const int ep1StartStallMax = (1 << _ep1StallBits) - 1;

  /// The vendor descriptor set served on endpoint 0.
  final List<UsbDescriptorEntry> descriptors;

  /// When true, endpoint 1 bulk streams exist.
  final bool bulkEndpoints;

  /// Maximum packet payload per endpoint, in bytes.
  final int maxPacketSize;

  /// Cycles a command may wait in the EP1 OUT buffer before `cmd_start`
  /// goes out anyway and preempts the answer in front of it.
  ///
  /// A command that arrives while an answer is still going out waits for
  /// that answer. This lets a host queue a command right behind the
  /// answer it replaces. The bound only matters for a host that walks
  /// away from an answer it asked for: that host never takes another
  /// byte, so the command would wait forever without it.
  ///
  /// The default sits far above any real answer time and low enough that
  /// a dead host cannot keep the device quiet: at 48 MHz it is about
  /// 87 ms, against an answer that drains in milliseconds.
  ///
  /// A test can lower this value to reach the bound without running
  /// millions of cycles. In hardware, keep it above the time any real
  /// answer takes to drain, or it cuts off a healthy read.
  final int ep1StartStallCycles;

  HarborUsbFsDevice({
    required this.descriptors,
    this.bulkEndpoints = true,
    this.maxPacketSize = 32,
    this.ep1StartStallCycles = ep1StartStallMax,
    String? name,
  }) : super('HarborUsbFsDevice', name: name ?? 'usb_fs_device') {
    if (ep1StartStallCycles < 1 || ep1StartStallCycles > ep1StartStallMax) {
      throw ArgumentError.value(
        ep1StartStallCycles,
        'ep1StartStallCycles',
        'must be between 1 and $ep1StartStallMax',
      );
    }
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('dp', PortDirection.input);
    createPort('dm', PortDirection.input);
    createPort('cmd_ready', PortDirection.input);
    createPort('resp_data', PortDirection.input, width: 8);
    createPort('resp_valid', PortDirection.input);
    createPort('resp_last', PortDirection.input);

    addOutput('dp_out');
    addOutput('dm_out');
    addOutput('oe');
    addOutput('usb_pullup');
    addOutput('dev_addr', width: 7);
    addOutput('configured');
    addOutput('bus_reset');
    addOutput('cmd_data', width: 8);
    addOutput('cmd_valid');
    addOutput('resp_ready');
    addOutput('cmd_start');

    final clk = input('clk');
    final reset = input('reset');

    final numEps = bulkEndpoints ? 1 : 0;

    final core = HarborUsbCore(
      descriptors: descriptors,
      maxPacketSize: maxPacketSize,
      numOutEps: numEps,
      numInEps: numEps,
      name: 'core',
    );
    addSubModule(core);
    core.input('clk').srcConnection! <= clk;
    core.input('reset').srcConnection! <= reset;
    core.input('dp').srcConnection! <= input('dp');
    core.input('dm').srcConnection! <= input('dm');

    output('dp_out') <= core.output('dp_out');
    output('dm_out') <= core.output('dm_out');
    output('oe') <= core.output('oe');
    output('usb_pullup') <= core.output('usb_pullup');
    output('dev_addr') <= core.output('dev_addr');
    output('configured') <= core.output('configured');
    output('bus_reset') <= core.output('bus_reset');

    final fn = _HarborUsbBulkFunction(
      bulkEndpoints: bulkEndpoints,
      ep1StartStallCycles: ep1StartStallCycles,
      name: 'bulk_fn',
    );
    addSubModule(fn);
    fn.input('clk').srcConnection! <= clk;
    fn.input('reset').srcConnection! <= reset;
    fn.input('cmd_ready').srcConnection! <= input('cmd_ready');
    fn.input('resp_data').srcConnection! <= input('resp_data');
    fn.input('resp_valid').srcConnection! <= input('resp_valid');
    fn.input('resp_last').srcConnection! <= input('resp_last');

    connectInterfaces(core.interface('func'), fn.interface('func'));

    output('cmd_data') <= fn.output('cmd_data');
    output('cmd_valid') <= fn.output('cmd_valid');
    output('cmd_start') <= fn.output('cmd_start');
    output('resp_ready') <= fn.output('resp_ready');
  }
}

/// Drives [HarborUsbCore]'s `func` interface for [HarborUsbFsDevice]:
/// endpoint 0 stalls every SETUP, and the one extra bulk endpoint pair
/// carries the vendor command/response stream.
class _HarborUsbBulkFunction extends BridgeModule {
  static const int _ep1StallBits = HarborUsbFsDevice._ep1StallBits;

  final bool bulkEndpoints;
  final int ep1StartStallCycles;

  _HarborUsbBulkFunction({
    required this.bulkEndpoints,
    required this.ep1StartStallCycles,
    String? name,
  }) : super('HarborUsbBulkFunction', name: name ?? 'usb_bulk_fn') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('cmd_ready', PortDirection.input);
    createPort('resp_data', PortDirection.input, width: 8);
    createPort('resp_valid', PortDirection.input);
    createPort('resp_last', PortDirection.input);

    addOutput('cmd_data', width: 8);
    addOutput('cmd_valid');
    addOutput('resp_ready');
    addOutput('cmd_start');

    final clk = input('clk');
    final reset = input('reset');
    final cmdReady = input('cmd_ready');
    final respData = input('resp_data');
    final respValid = input('resp_valid');
    final respLast = input('resp_last');

    final numEps = bulkEndpoints ? 1 : 0;
    final funcRef = addInterface(
      UsbFunctionInterface(numOutEps: numEps, numInEps: numEps),
      name: 'func',
      role: PairRole.consumer,
    );
    final func = funcRef.internalInterface!;

    // Endpoint 0 carries no class or vendor protocol: every SETUP stalls.
    func.setupAccept <= Const(0);
    func.setupStall <= func.setupValid;
    func.ep0OutReady <= Const(0);
    func.ep0InValid <= Const(0);
    func.ep0InData <= Const(0, width: 8);
    func.ep0InLast <= Const(0);

    if (!bulkEndpoints) {
      output('cmd_data') <= Const(0, width: 8);
      output('cmd_valid') <= Const(0);
      output('cmd_start') <= Const(0);
      output('resp_ready') <= Const(0);
      return;
    }

    // A bus reset must also clear this endpoint's own bookkeeping below,
    // the same as a chip reset.
    final combinedReset = (reset | func.busReset).named('bulk_fn_reset');

    final cmdValid = Logic(name: 'cmd_valid_i');
    final getEp1 = Logic(name: 'ep1_get');
    final ep1Gap = Logic(name: 'ep1_gap', width: 2);

    // OUT: the endpoint data register loads one cycle after the arbiter
    // grant, so the byte is offered one cycle after the grant. The gap
    // counts down after each acceptance and covers the same read delay
    // for the bytes that follow.
    final ep1Avail = func.port('out_ep_data_avail').named('ep1_avail');
    final ep1Data = func.port('out_ep_data').named('ep1_data');
    final ep1Granted = func.port('out_ep_grant').named('ep1_granted');
    final ep1DataValid = Logic(name: 'ep1_data_valid_q');
    Sequential(clk, [
      If(
        combinedReset,
        then: [ep1DataValid < Const(0)],
        orElse: [ep1DataValid < (ep1Avail & ep1Granted)],
      ),
    ]);
    // The raw offer: a byte is sitting in the endpoint and the read delay
    // has passed. cmd_valid is this, minus the cycle the cmd_start pulse
    // takes for itself. The pulse is built from the raw offer and not
    // from cmd_valid, because cmd_valid is built from the pulse and the
    // two would otherwise chase each other.
    final ep1Offer = (ep1DataValid & ep1Gap.eq(Const(0, width: 2))).named(
      'ep1_offer',
    );
    output('cmd_data') <= ep1Data;

    // cmd_start marks the start of a bulk transfer, not of a packet. A
    // transfer longer than wMaxPacketSize arrives as several packets:
    // full-size packets, then a shorter one. A packet after a full-size
    // packet continues the open transfer. A packet after a short packet,
    // or the first packet after a reset, starts a new command.
    final ep1Acked = func.port('out_ep_acked').named('ep1_acked');
    final ep1PktFull = func.port('out_ep_pkt_full').named('ep1_pkt_full');
    final ep1XfrOpen = Logic(name: 'ep1_xfr_open_q');

    // The pulse fires when the engine takes the first byte of the new
    // transfer, not when the packet carrying it is acknowledged. Until
    // then the command sits in the endpoint buffer: the drain runs on
    // cmd_ready, and the engine holds cmd_ready low while it still has
    // an answer to emit, so the protocol engine NAKs further OUT bytes
    // and the host retries. Once the answer finishes, the engine takes
    // the command's first byte and the pulse fires.
    //
    // The escape below covers a host that walks away from an answer it
    // asked for: that host never takes another byte, so the command
    // would wait forever. Once a command has waited long enough, the
    // pulse fires anyway and preempts the stale answer.
    final ep1PendingStart = Logic(name: 'ep1_pending_start_q');
    final ep1StartStall = Logic(
      name: 'ep1_start_stall_q',
      width: _ep1StallBits,
    );
    final ep1StallFull = ep1StartStall
        .eq(Const(ep1StartStallCycles, width: _ep1StallBits))
        .named('ep1_stall_full');
    final cmdStart = (((ep1Offer & cmdReady) | ep1StallFull) & ep1PendingStart)
        .named('cmd_start_pulse');
    output('cmd_start') <= cmdStart;

    // The pulse takes the cycle to itself: no byte is offered on it. The
    // engine treats cmd_start as a preempt and drops whatever it holds,
    // so a byte offered that cycle would be taken and thrown away.
    // cmd_start reaches the engine alone, and the byte is offered on the
    // cycle after.
    cmdValid <= ep1Offer & ~cmdStart;
    output('cmd_valid') <= cmdValid;

    final accept = (cmdValid & cmdReady).named('cmd_accept');

    Sequential(clk, [
      If(
        combinedReset,
        then: [
          ep1XfrOpen < Const(0),
          ep1PendingStart < Const(0),
          ep1StartStall < Const(0, width: _ep1StallBits),
        ],
        orElse: [
          If(ep1Acked, then: [ep1XfrOpen < ep1PktFull]),
          // A packet that starts a new transfer arms the pulse. The arm
          // survives until the engine takes a byte, however long the
          // answer in front of it runs.
          If(ep1Acked & ~ep1XfrOpen, then: [ep1PendingStart < Const(1)]),
          If(cmdStart, then: [ep1PendingStart < Const(0)]),
          // The stall counts only while a command is armed and waiting.
          // It starts again the moment the pulse goes out.
          If(
            ep1PendingStart & ~cmdStart,
            then: [
              If(
                ~ep1StallFull,
                then: [
                  ep1StartStall <
                      ep1StartStall + Const(1, width: _ep1StallBits),
                ],
              ),
            ],
            orElse: [ep1StartStall < Const(0, width: _ep1StallBits)],
          ),
        ],
      ),
    ]);

    Sequential(clk, [
      If(
        combinedReset,
        then: [getEp1 < Const(0), ep1Gap < Const(0, width: 2)],
        orElse: [
          If(
            accept,
            then: [getEp1 < Const(1), ep1Gap < Const(2, width: 2)],
            orElse: [
              getEp1 < Const(0),
              If(
                ep1Gap.neq(Const(0, width: 2)),
                then: [ep1Gap < ep1Gap - Const(1, width: 2)],
              ),
            ],
          ),
        ],
      ),
    ]);

    func.port('out_ep_req') <= ep1Avail;
    func.port('out_ep_data_get') <= getEp1;
    func.port('out_ep_stall') <= Const(0, width: 1);

    // IN: response bytes stream into the endpoint while free.
    final ep1Free = func.port('in_ep_data_free').named('ep1_free');
    final ep1Done = (respValid & respLast & ep1Free).named('ep1_done');
    final ep1Put = (respValid & ep1Free).named('ep1_put');

    func.port('in_ep_req') <= respValid;
    func.port('in_ep_data_put') <= ep1Put;
    func.port('in_ep_data') <= respData;
    func.port('in_ep_data_done') <= ep1Done;
    func.port('in_ep_stall') <= Const(0, width: 1);

    output('resp_ready') <= ep1Free;
  }
}
