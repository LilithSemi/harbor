import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'wishbone_interface.dart';

/// A one-deep register slice for a classic Wishbone link.
///
/// It flops the whole request forward and the whole response back, so no
/// signal crosses the slice combinationally. That splits the long master to
/// slave path in two and costs two extra clock cycles per transfer.
///
/// One transfer is outstanding at a time. The slice captures a request only
/// while idle, holds STB to the downstream slave until it ends the transfer
/// with ACK, ERR or RTY, then pulses that termination upstream for one cycle.
///
/// If the upstream master drops CYC while a transfer is outstanding, the
/// transfer becomes an orphan. The downstream cycle still runs to its end, its
/// termination is discarded, and the slice takes no new request until then.
///
/// `up` is a consumer and `down` is a provider. [config] sets the `down` side.
/// [upConfig] sets the `up` side and defaults to [config]. When `up` has no ERR
/// or RTY, the slice returns that termination as ACK with [wishbonePoison]
/// read data, and sets the sticky `bus_error` output.
class WishboneRegisterStage extends BridgeModule {
  WishboneRegisterStage({
    required WishboneConfig config,
    WishboneConfig? upConfig,
    String? name,
  }) : super('WishboneRegisterStage', name: name ?? 'wishbone_reg') {
    final upCfg = upConfig ?? config;
    if (upCfg.addressWidth != config.addressWidth ||
        upCfg.dataWidth != config.dataWidth ||
        upCfg.effectiveSelWidth != config.effectiveSelWidth) {
      throw ArgumentError(
        'upConfig must have the same address, data and select widths',
      );
    }

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final clk = input('clk');
    final reset = input('reset');

    final up =
        addInterface(
              WishboneInterface(upCfg),
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

    final busy = Logic(name: 'busy');
    final orphan = Logic(name: 'orphan');

    final weR = Logic(name: 'we_r');
    final adrR = Logic(name: 'adr_r', width: config.addressWidth);
    final datR = Logic(name: 'dat_mosi_r', width: config.dataWidth);
    final selR = Logic(name: 'sel_r', width: config.effectiveSelWidth);

    // Optional request tags that both sides carry are latched, the rest of
    // the downstream ones are tied to 0.
    final tagLatches = <(Logic, Logic)>[];
    for (final n in wishboneOptionalRequestPorts) {
      final d = down.tryPort(n);
      if (d == null) continue;
      final u = up.tryPort(n);
      if (u == null) {
        d <= Const(0, width: d.width);
        continue;
      }
      final r = Logic(name: '${n.toLowerCase()}_r', width: d.width);
      d <= r;
      tagLatches.add((r, u));
    }

    final ackR = Logic(name: 'ack_r');
    final errR = Logic(name: 'err_r');
    final rtyR = Logic(name: 'rty_r');
    final misoR = Logic(name: 'dat_miso_r', width: config.dataWidth);
    final tgdMisoR = (up.tgdMiso != null && down.tgdMiso != null)
        ? Logic(name: 'tgd_miso_r', width: down.tgdMiso!.width)
        : null;

    down.cyc <= busy;
    down.stb <= busy;
    down.we <= weR;
    down.adr <= adrR;
    down.datMosi <= datR;
    down.sel <= selR;

    // A termination the master cannot see as ERR or RTY folds into ACK.
    final folded = [if (up.err == null) errR, if (up.rty == null) rtyR];
    final badFold = folded.isEmpty
        ? null
        : folded.reduce((a, b) => a | b).named('fold');
    up.ack <= (badFold == null ? ackR : ackR | badFold);
    up.datMiso <=
        (badFold == null
            ? misoR
            : mux(badFold, wishbonePoison(config.dataWidth), misoR));
    final busErr = Logic(name: 'bus_error_r');
    addOutput('bus_error') <= busErr;
    if (up.err != null) up.err! <= errR;
    if (up.rty != null) up.rty! <= rtyR;
    if (up.tgdMiso != null) {
      up.tgdMiso! <= (tgdMisoR ?? Const(0, width: up.tgdMiso!.width));
    }

    final dAck = down.ack;
    final dErr = down.err ?? Const(0);
    final dRty = down.rty ?? Const(0);
    final dTerm = (dAck | dErr | dRty).named('down_term');
    // The upstream cycle is gone, so the result has no owner.
    final drop = (orphan | ~up.cyc).named('drop');

    Sequential(clk, [
      If(
        reset,
        then: [
          busy < 0,
          orphan < 0,
          ackR < 0,
          errR < 0,
          rtyR < 0,
          misoR < 0,
          if (tgdMisoR != null) tgdMisoR < 0,
          busErr < 0,
        ],
        orElse: [
          if (badFold != null) busErr < (busErr | badFold),
          ackR < 0,
          errR < 0,
          rtyR < 0,
          If(
            ~busy,
            then: [
              // A classic master holds its request for one cycle after the
              // termination pulse. Do not capture it again.
              If(
                up.cyc & up.stb & ~ackR & ~errR & ~rtyR,
                then: [
                  busy < 1,
                  orphan < 0,
                  weR < up.we,
                  adrR < up.adr,
                  datR < up.datMosi,
                  selR < up.sel,
                  for (final (r, u) in tagLatches) r < u,
                ],
              ),
            ],
            orElse: [
              If(
                dTerm,
                then: [
                  busy < 0,
                  orphan < 0,
                  If(
                    ~drop,
                    then: [
                      ackR < dAck,
                      errR < dErr,
                      rtyR < dRty,
                      misoR < down.datMiso,
                      if (tgdMisoR != null) tgdMisoR < down.tgdMiso!,
                    ],
                  ),
                ],
                orElse: [orphan < drop],
              ),
            ],
          ),
        ],
      ),
    ]);
  }
}
