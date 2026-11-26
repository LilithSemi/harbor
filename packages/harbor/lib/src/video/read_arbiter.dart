import 'package:rohd/rohd.dart';

/// Round-robin read arbiter: shares one downstream Wishbone-style memory port
/// among N read-only masters (e.g. the framebuffer DMAs of several displays).
///
/// Grant is combinational with a rotating priority anchored at [_rr]. The
/// pointer advances past the served master on each `ack`, so masters take turns
/// word by word. The granted master's address drives the downstream port, and
/// `ack`/data are routed back only to it. Read-only: `we` is tied low.
class HarborReadArbiter extends Module {
  final int n;

  /// Per-master ack (high on the cycle this master's word is served).
  Logic ack(int i) => output('ack_$i');

  /// Per-master read data (valid with [ack]).
  Logic dat(int i) => output('dat_$i');

  /// Downstream memory port.
  Logic get dStb => output('d_stb');
  Logic get dCyc => output('d_cyc');
  Logic get dWe => output('d_we');
  Logic get dAddr => output('d_adr');
  Logic get dSel => output('d_sel');
  Logic get dDataOut => output('d_dat_o');

  HarborReadArbiter({
    required Logic clk,
    required Logic reset,
    required List<Logic> stb,
    required List<Logic> cyc,
    required List<Logic> adr,
    required Logic dAck,
    required Logic dDataIn,
    super.name = 'read_arbiter',
  }) : n = stb.length,
       super(definitionName: 'HarborReadArbiter') {
    assert(
      stb.length == cyc.length && cyc.length == adr.length,
      'master port lists must be the same length',
    );
    final idxW = (n - 1).bitLength < 1 ? 1 : (n - 1).bitLength;
    final rpW = idxW + 1;

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    dAck = addInput('d_ack', dAck);
    dDataIn = addInput('d_dat_i', dDataIn, width: 32);
    final stbI = [for (var i = 0; i < n; i++) addInput('stb_$i', stb[i])];
    final cycI = [for (var i = 0; i < n; i++) addInput('cyc_$i', cyc[i])];
    final adrI = [
      for (var i = 0; i < n; i++) addInput('adr_$i', adr[i], width: 32),
    ];

    for (var i = 0; i < n; i++) {
      addOutput('ack_$i');
      addOutput('dat_$i', width: 32);
    }
    addOutput('d_stb');
    addOutput('d_cyc');
    addOutput('d_we');
    addOutput('d_adr', width: 32);
    addOutput('d_sel', width: 4);
    addOutput('d_dat_o', width: 32);

    final rr = Logic(name: 'rr', width: idxW);

    final req = [for (var i = 0; i < n; i++) cycI[i] & stbI[i]];

    // Rotated position of each master relative to rr (0 = highest priority).
    final rrE = rr.zeroExtend(rpW);
    final rp = [
      for (var i = 0; i < n; i++)
        mux<Logic>(
          rr.lte(Const(i, width: idxW)),
          Const(i, width: rpW) - rrE,
          Const(i + n, width: rpW) - rrE,
        ),
    ];

    // Grant the requester with the smallest rotated position.
    final grant = <Logic>[];
    for (var i = 0; i < n; i++) {
      Logic blocked = Const(0);
      for (var j = 0; j < n; j++) {
        if (j == i) continue;
        blocked |= req[j] & rp[j].lt(rp[i]);
      }
      grant.add(req[i] & ~blocked);
    }

    final anyGrant = grant.reduce((a, b) => a | b);
    Logic selAddr = Const(0, width: 32);
    Logic grantedIdx = Const(0, width: idxW);
    for (var i = 0; i < n; i++) {
      selAddr = mux(grant[i], adrI[i], selAddr);
      grantedIdx = mux(grant[i], Const(i, width: idxW), grantedIdx);
    }

    dStb <= anyGrant;
    dCyc <= anyGrant;
    dWe <= Const(0);
    dAddr <= selAddr;
    dSel <= Const(0xF, width: 4);
    dDataOut <= Const(0, width: 32);

    for (var i = 0; i < n; i++) {
      output('ack_$i') <= grant[i] & dAck;
      output('dat_$i') <= dDataIn;
    }

    final rrNext = mux(
      grantedIdx.eq(n - 1),
      Const(0, width: idxW),
      grantedIdx + Const(1, width: idxW),
    );
    Sequential(clk, reset: reset, [
      If(dAck, then: [rr < rrNext]),
    ]);
  }
}
