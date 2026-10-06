import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'wishbone_interface.dart';

/// A one-deep, protocol-correct register slice for a classic Wishbone link.
///
/// It flops the whole request forward (CYC/STB/WE/ADR/DAT_MOSI/SEL) and the
/// whole response back (ACK/DAT_MISO/ERR), so no signal crosses the slice
/// combinationally. That splits the long master -> arbiter -> decoder -> slave
/// -> back combinational path in two, which is the interconnect's clock-speed
/// limiter on a dense fabric.
///
/// Classic Wishbone is not pipelined, so one transfer is outstanding at a time.
/// The slice captures a request only while idle, holds STB to the downstream
/// slave until the slave's ACK, then pulses ACK upstream for one cycle. That
/// costs two extra clock cycles per transfer, which is negligible next to the
/// core's cycles-per-instruction.
///
/// Interfaces: `up` is a consumer (it takes the master-side request and drives
/// the master-side response) and `down` is a provider (it drives the request
/// toward the decoder/slave). Interpose it between the fabric master (or the
/// arbiter) and the decoder.
class WishboneRegisterStage extends BridgeModule {
  WishboneRegisterStage({required WishboneConfig config, String? name})
    : super('WishboneRegisterStage', name: name ?? 'wishbone_reg') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final clk = input('clk');
    final reset = input('reset');

    final up =
        addInterface(
              WishboneInterface(config),
              name: 'up',
              role: PairRole.consumer,
            ).internalInterface
            as WishboneInterface;
    final down =
        addInterface(
              WishboneInterface(config),
              name: 'down',
              role: PairRole.provider,
            ).internalInterface
            as WishboneInterface;

    // A transfer is outstanding toward the downstream slave.
    final busy = Logic(name: 'busy');

    // Latched request (driven downstream while busy).
    final weR = Logic(name: 'we_r');
    final adrR = Logic(name: 'adr_r', width: config.addressWidth);
    final datR = Logic(name: 'dat_mosi_r', width: config.dataWidth);
    final selR = Logic(name: 'sel_r', width: config.effectiveSelWidth);

    // Latched response (driven upstream for one cycle on completion).
    final ackR = Logic(name: 'ack_r');
    final misoR = Logic(name: 'dat_miso_r', width: config.dataWidth);
    final errR = up.err != null ? Logic(name: 'err_r') : null;

    // Drive the downstream request from the latch. CYC/STB assert only while a
    // transfer is outstanding, so the stale request fields are ignored.
    down.cyc <= busy;
    down.stb <= busy;
    down.we <= weR;
    down.adr <= adrR;
    down.datMosi <= datR;
    down.sel <= selR;

    // Drive the upstream response from the latch.
    up.ack <= ackR;
    up.datMiso <= misoR;
    if (up.err != null) up.err! <= errR!;

    Sequential(clk, [
      If(
        reset,
        then: [busy < Const(0), ackR < Const(0), if (errR != null) errR < 0],
        orElse: [
          // ACK upstream is a one-cycle pulse.
          ackR < Const(0),
          if (errR != null) errR < 0,
          If(
            ~busy,
            then: [
              // Idle: capture a new request when the master asserts CYC & STB.
              // Gate on ~ackR: the cycle we pulse ACK upstream, a classic master
              // still holds its (now-complete) request for one more cycle because
              // its deassert is registered. Without this gate we would re-capture
              // that stale request and run the transfer twice.
              If(
                up.cyc & up.stb & ~ackR & ~(errR ?? Const(0)),
                then: [
                  busy < Const(1),
                  weR < up.we,
                  adrR < up.adr,
                  datR < up.datMosi,
                  selR < up.sel,
                ],
              ),
            ],
            orElse: [
              // Outstanding: complete on the downstream ACK, latch the response
              // and pulse ACK upstream next cycle.
              If(
                down.ack | (down.err ?? Const(0)),
                then: [
                  busy < Const(0),
                  ackR < down.ack,
                  misoR < down.datMiso,
                  if (errR != null) errR < (down.err ?? Const(0)),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);
  }
}
