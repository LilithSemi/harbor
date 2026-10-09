// Area report harness for the USB DFU subsystem that would be added to
// creek. Wraps the synthesizable DFU datapath that lands in the SoC:
//   - HarborUsbCore + HarborUsbDfu (the ch9 + DFU class state machine that
//     streams a firmware download through UsbDfuSinkInterface)
//   - UsbDfuRamSink (the bus-master RAM sink + CDC FIFO)
// into a single parent BridgeModule DfuAreaTop so synth sees the whole
// subsystem as one netlist.
//
// Every top-level input is driven, from top ports or a register that is
// genuinely used. The bus master's ack/dat_miso are driven by an always-ack
// so the bus write FSM is retained. This keeps `opt` from pruning the logic
// and reporting a misleading ~0 cell count.
//
// This tool only reports area. It does not change any RTL.
import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Parent that stitches the core + device + ram sink into one synthesizable
/// top.
class DfuAreaTop extends BridgeModule {
  DfuAreaTop() : super('DfuAreaTop', name: 'dfu_area_top') {
    // ---- Top-level ports (everything an external SoC would wire). ----
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    // USB line inputs (drive the core PHY rx so framing logic is retained).
    createPort('usb_dp_in', PortDirection.input);
    createPort('usb_dm_in', PortDirection.input);
    // Bus-domain clock/reset for the ram sink. A real SoC would use a slower
    // bus clock, so this gives it its own port instead of tying it to a const.
    createPort('bus_clk', PortDirection.input);
    createPort('bus_reset', PortDirection.input);

    // Surface a couple of core + sink outputs at the top so the whole chain
    // (device FSM -> sink interface -> bus FSM -> image_ready) is observable
    // and therefore not pruned.
    addOutput('usb_dp_out');
    addOutput('usb_dm_out');
    addOutput('usb_oe');
    addOutput('dev_addr', width: 7);
    addOutput('configured');
    addOutput('dfu_state', width: 4);
    addOutput('image_ready');
    addOutput('bytes_written', width: 32);

    final clk = input('clk');
    final reset = input('reset');
    final busClk = input('bus_clk');
    final busReset = input('bus_reset');

    // ---- The USB core + DFU device. ----
    // Only the RAM sink is wired, so the flash alt setting is left out.
    final core = HarborUsbCore(
      descriptors: HarborUsbDfu.dfuDescriptors(includeFlashAlt: false),
    );
    addSubModule(core);
    core.input('clk').srcConnection! <= clk;
    core.input('reset').srcConnection! <= reset;
    core.input('dp').srcConnection! <= input('usb_dp_in');
    core.input('dm').srcConnection! <= input('usb_dm_in');

    final dfu = HarborUsbDfu(name: 'dfu');
    addSubModule(dfu);
    dfu.input('clk').srcConnection! <= clk;
    dfu.input('reset').srcConnection! <= reset;
    connectInterfaces(core.interface('func'), dfu.interface('usb'));

    // ---- The RAM sink (bus master). ----
    final ramSink = UsbDfuRamSink(
      loadBase: 0x1000,
      regionBytes: 0x100000,
      busDataWidth: 32,
    );
    addSubModule(ramSink);
    // USB-domain clock/reset share the 48 MHz domain with the device.
    ramSink.input('usb_clk').srcConnection! <= clk;
    ramSink.input('usb_reset').srcConnection! <= reset;
    ramSink.input('bus_clk').srcConnection! <= busClk;
    ramSink.input('bus_reset').srcConnection! <= busReset;
    connectInterfaces(dfu.interface('sink'), ramSink.interface('dfu'));

    // ---- Bus master slave side: drive the ram sink's Wishbone consumer-side
    // inputs (bus_ACK, bus_DAT_MISO) directly. The ram sink's `bus` interface
    // is a provider (master), so ACK and DAT_MISO are input ports on the
    // submodule. An always-ack drives them so the bus write FSM (stWrite
    // waits on bus.ack) always completes and the whole FSM and datapath stay
    // live, not pruned by opt. ----
    final busCyc = ramSink.output('bus_CYC');
    final busStb = ramSink.output('bus_STB');
    final busAdr = ramSink.output('bus_ADR');

    // Always-ack: ack follows (cyc & stb) one cycle later, so the master's
    // stWrite state always completes. dat_miso is fed from the master's adr so
    // the read path is also kept live.
    final ackReg = Logic(name: 'ack_reg');
    final misoReg = Logic(name: 'miso_reg', width: 32);
    Sequential(busClk, [
      If(
        busReset,
        then: [ackReg < Const(0), misoReg < Const(0, width: 32)],
        orElse: [
          ackReg < (busCyc & busStb & ~ackReg),
          misoReg < busAdr.zeroExtend(32),
        ],
      ),
    ]);
    ramSink.input('bus_ACK').srcConnection! <= ackReg;
    ramSink.input('bus_DAT_MISO').srcConnection! <= misoReg;

    // ---- Surface outputs. ----
    output('usb_dp_out') <= core.output('dp_out');
    output('usb_dm_out') <= core.output('dm_out');
    output('usb_oe') <= core.output('oe');
    output('dev_addr') <= core.output('dev_addr');
    output('configured') <= core.output('configured');
    output('dfu_state') <= dfu.output('dfu_state');
    output('image_ready') <= ramSink.output('image_ready');
    output('bytes_written') <= ramSink.output('bytes_written');
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: gen_dfu_area <output.sv>');
    exitCode = 64;
    return;
  }
  final top = DfuAreaTop();
  await top.build();
  final sv = top.generateSynth();
  final outPath = args.first;
  File(outPath).writeAsStringSync(sv);
  stdout.writeln('WROTE ${sv.length} bytes to $outPath');
}
