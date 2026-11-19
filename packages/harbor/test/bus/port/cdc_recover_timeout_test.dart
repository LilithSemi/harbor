import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import 'cdc_harness.dart';
import 'memory_harness.dart';

const _cfg = HarborMemoryWaistConfig(
  addressWidth: 16,
  dataWidth: 32,
  idWidth: 2,
  outstanding: 4,
);

const _timeout = 40;

class _Top extends BridgeModule {
  _Top(int recoverTimeout)
    : super('CdcRecoverTop_t$recoverTimeout', name: 'top') {
    final dev = addSubModule(
      CdcMemDevice(
        _cfg,
        HarborFabricKind.axi4,
        slave: false,
        cross: true,
        recoverTimeout: recoverTimeout,
      ),
    );
    for (final p in ['clk', 'reset', 'fclk', 'freset']) {
      pullUpPort(dev.port(p), newPortName: p);
    }
    pullUpInterface(dev.interface('bus'), newIntfName: 'bus');
    pullUpInterface(dev.interface('up'), newIntfName: 'up');
  }
}

Module _find(Module m, String prefix) {
  if (m.definitionName.startsWith(prefix)) return m;
  for (final s in m.subModules) {
    final h = _findOrNull(s, prefix);
    if (h != null) return h;
  }
  throw StateError('no $prefix');
}

Module? _findOrNull(Module m, String prefix) {
  try {
    return _find(m, prefix);
  } on StateError {
    return null;
  }
}

/// A requester that sends in-flight traffic, loses it to a device reset and
/// sends fresh traffic. The memory side never answers the first requests,
/// then answers each fresh one after a late answer of the old request with
/// the same ID.
Future<void> _silentThenReset(int recoverTimeout) async {
  final top = _Top(recoverTimeout);
  final clk = SimpleClockGenerator(10).clk;
  for (final input in top.inputs.values) {
    if (input.name != 'clk' && input.name != 'fclk') {
      input.srcConnection!.put(0);
    }
  }
  top.input('clk').srcConnection! <= clk;
  top.input('fclk').srcConnection! <= clk;
  await top.build();
  final cdc = _find(top, 'HarborMemoryWaistCdcMaster');
  void set(String p, int v) => top.input(p).srcConnection!.inject(v);
  int pre(String p) {
    final v = (top.tryOutput(p) ?? top.input(p)).previousValue;
    return v != null && v.isValid ? v.toInt() : -1;
  }

  final arSeen = <int, int>{};
  final awSeen = <int, int>{};
  final wBeats = <int>[];
  final rGot = <int>[];
  var bGot = 0;
  var reqPhase = 0;
  var reqSent = false;
  var reqFired = false;
  var wSent = false;
  var wFired = false;
  final rResp = <int>[];
  var bResp = 0;
  var rPresent = false;
  var bPresent = false;
  var rFired = false;
  var bFired = false;
  var falls = 0;

  void sendReq(int id, int write, int addr) {
    set('up_REQ_VALID', 1);
    set('up_REQ_ID', id);
    set('up_REQ_WRITE', write);
    set('up_REQ_ADDR', addr);
    set('up_REQ_SIZE', 2);
    set('up_REQ_BURST', 1);
  }

  set('up_RDATA_READY', 1);
  set('up_WRESP_READY', 1);
  set('bus_ARREADY', 1);
  set('bus_AWREADY', 1);
  set('reset', 1);
  set('freset', 1);

  bool fire(String v, String r) => pre(v) == 1 && pre(r) == 1;

  clk.posedge.listen((_) {
    if (fire('up_REQ_VALID', 'up_REQ_READY')) reqFired = true;
    if (fire('up_WDATA_VALID', 'up_WDATA_READY')) wFired = true;
    if (fire('bus_RVALID', 'bus_RREADY')) rFired = true;
    if (fire('bus_BVALID', 'bus_BREADY')) bFired = true;
    if (fire('bus_ARVALID', 'bus_ARREADY')) {
      arSeen.putIfAbsent(pre('bus_ARADDR'), () => falls);
    }
    if (fire('bus_AWVALID', 'bus_AWREADY')) {
      awSeen.putIfAbsent(pre('bus_AWADDR'), () => falls);
    }
    if (fire('bus_WVALID', 'bus_WREADY')) wBeats.add(pre('bus_WDATA'));
    if (fire('up_RDATA_VALID', 'up_RDATA_READY')) {
      rGot.add(pre('up_RDATA_DATA'));
    }
    if (fire('up_WRESP_VALID', 'up_WRESP_READY')) bGot++;
  });

  clk.negedge.listen((_) {
    falls++;
    if (falls == 4) {
      set('reset', 0);
      set('freset', 0);
    }
    // Device reset in the middle of the unanswered traffic.
    if (falls == 40) {
      set('reset', 1);
      set('up_REQ_VALID', 0);
      set('up_WDATA_VALID', 0);
      reqSent = reqFired = wSent = wFired = false;
      reqPhase = 2;
    }
    if (falls == 43) set('reset', 0);

    if (arSeen.containsKey(0x200) && rResp.isEmpty && !rPresent) {
      rResp.addAll([0xdead, 0xbeef]);
    }
    if (awSeen.containsKey(0x300)) {
      set('bus_WREADY', 1);
      if (bResp == 0 && !bPresent) bResp = 2;
    }
    // The old request answers first, then the new one, with the same ID.
    if (rPresent && rFired) {
      rPresent = rFired = false;
      set('bus_RVALID', 0);
    }
    if (!rPresent && rResp.isNotEmpty) {
      set('bus_RVALID', 1);
      set('bus_RID', 1);
      set('bus_RDATA', rResp.removeAt(0));
      set('bus_RLAST', 1);
      rPresent = true;
    }
    if (bPresent && bFired) {
      bPresent = bFired = false;
      set('bus_BVALID', 0);
    }
    if (!bPresent && bResp > 0) {
      set('bus_BVALID', 1);
      set('bus_BID', 2);
      bResp--;
      bPresent = true;
    }

    // Old traffic before the reset, new traffic after it.
    if (reqSent && reqFired) {
      set('up_REQ_VALID', 0);
      reqSent = reqFired = false;
      reqPhase++;
    }
    if (wSent && wFired) {
      set('up_WDATA_VALID', 0);
      wSent = wFired = false;
    }
    final before = falls > 6 && falls < 40 && reqPhase < 2;
    final after = falls >= 46 && reqPhase >= 2 && reqPhase < 4;
    if (!reqSent && (before || after)) {
      const plan = [(1, 0, 0x100), (2, 1, 0x180), (1, 0, 0x200), (2, 1, 0x300)];
      final (id, write, addr) = plan[reqPhase];
      sendReq(id, write, addr);
      if (write == 1) {
        set('up_WDATA_VALID', 1);
        set('up_WDATA_DATA', reqPhase == 1 ? 0x11 : 0xcafe);
        set('up_WDATA_STRB', 0xf);
        set('up_WDATA_LAST', 1);
        wSent = true;
      }
      reqSent = true;
    }
  });
  Simulator.setMaxSimTime(10 * 600);
  await Simulator.run();

  must(arSeen.containsKey(0x100), isTrue, reason: 'old read reached memory');
  must(arSeen.containsKey(0x200), isTrue, reason: 'new read got through');
  must(awSeen.containsKey(0x300), isTrue, reason: 'new write got through');
  must(
    arSeen[0x200]! - 43,
    greaterThanOrEqualTo(_timeout),
    reason: 'the wait covers the timeout',
  );
  must(rGot, [0xbeef], reason: 'late answer never reaches the device');
  must(bGot, 1);
  // The beat of the old write is in the AXI4 register and leaves first.
  must(wBeats, [0x11, 0xcafe]);
  must(cdc.output('debug_recover_timeouts').value.toInt(), 1);
  must(cdc.output('debug_dropped').value.toInt(), 2);
}

void main() {
  tearDown(endAndReset);

  test(
    'the crossing gives up on answers that never come after a device reset',
    () => isolated(() => _silentThenReset(_timeout)),
  );
}
