import 'dart:async';

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
    pullUpPort(
      dev.port('dbg_recover_timeouts'),
      newPortName: 'dbg_recover_timeouts',
    );
    pullUpInterface(dev.interface('bus'), newIntfName: 'bus');
    pullUpInterface(dev.interface('up'), newIntfName: 'up');
  }
}

Module? _findOrNull(Module m, String prefix) {
  if (m.definitionName.startsWith(prefix)) return m;
  for (final s in m.subModules) {
    final h = _findOrNull(s, prefix);
    if (h != null) return h;
  }
  return null;
}

/// A device on the waist `up_*` and a memory on the AXI4 port `bus_*`. The
/// memory takes every AR and AW, and answers only when a test says so.
class _Bench {
  final _Top top;
  final Logic clk;
  final Module cdc;
  final ar = <({int id, int addr})>[];
  final aw = <({int id, int addr})>[];
  final wBeats = <({int data, int strb, int last})>[];
  final rGot = <({int id, int data})>[];
  final bGot = <({int id, int err})>[];
  var _req = false;
  var _w = false;
  var _r = false;
  var _b = false;

  _Bench._(this.top, this.clk, this.cdc);

  static Future<_Bench> start(int recoverTimeout) async {
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
    final b = _Bench._(
      top,
      clk,
      _findOrNull(top, 'HarborMemoryWaistCdcMaster')!,
    );
    b
      ..set('reset', 1)
      ..set('freset', 1)
      ..set('up_RDATA_READY', 1)
      ..set('up_WRESP_READY', 1)
      ..set('bus_ARREADY', 1)
      ..set('bus_AWREADY', 1);
    // Sampled late in the low phase, after the values driven at the falling
    // edge took effect, so they are what the next rising edge takes.
    clk.negedge.listen(
      (_) => Simulator.registerAction(Simulator.time + 4, b._sample),
    );
    Simulator.setMaxSimTime(100000);
    unawaited(Simulator.run());
    await b.fall(20);
    b
      ..set('reset', 0)
      ..set('freset', 0);
    await b.fall(2);
    return b;
  }

  void set(String p, int v) => top.input(p).srcConnection!.inject(v);

  int pre(String p) {
    final v = (top.tryOutput(p) ?? top.input(p).srcConnection!).value;
    return v.isValid ? v.toInt() : -1;
  }

  bool _fire(String v, String r) => pre(v) == 1 && pre(r) == 1;

  void _sample() {
    if (_fire('up_REQ_VALID', 'up_REQ_READY')) _req = true;
    if (_fire('up_WDATA_VALID', 'up_WDATA_READY')) _w = true;
    if (_fire('bus_RVALID', 'bus_RREADY')) _r = true;
    if (_fire('bus_BVALID', 'bus_BREADY')) _b = true;
    if (_fire('bus_ARVALID', 'bus_ARREADY')) {
      ar.add((id: pre('bus_ARID'), addr: pre('bus_ARADDR')));
    }
    if (_fire('bus_AWVALID', 'bus_AWREADY')) {
      aw.add((id: pre('bus_AWID'), addr: pre('bus_AWADDR')));
    }
    if (_fire('bus_WVALID', 'bus_WREADY')) {
      wBeats.add((
        data: pre('bus_WDATA'),
        strb: pre('bus_WSTRB'),
        last: pre('bus_WLAST'),
      ));
    }
    if (_fire('up_RDATA_VALID', 'up_RDATA_READY')) {
      rGot.add((id: pre('up_RDATA_ID'), data: pre('up_RDATA_DATA')));
    }
    if (_fire('up_WRESP_VALID', 'up_WRESP_READY')) {
      bGot.add((id: pre('up_WRESP_ID'), err: pre('up_WRESP_ERR')));
    }
  }

  Future<void> fall(int n) async {
    for (var i = 0; i < n; i++) {
      await clk.nextNegedge;
    }
  }

  /// Runs until [done] holds, for at most [limit] cycles.
  Future<void> until(bool Function() done, {int limit = 400}) async {
    for (var i = 0; i < limit && !done(); i++) {
      await fall(1);
    }
  }

  Future<void> reset() async {
    set('reset', 1);
    await fall(3);
    set('reset', 0);
  }

  /// Sends a request on the device waist and waits until it is taken.
  Future<void> req(int id, int write, int addr, {int len = 0}) async {
    _req = false;
    set('up_REQ_VALID', 1);
    set('up_REQ_ID', id);
    set('up_REQ_WRITE', write);
    set('up_REQ_ADDR', addr);
    set('up_REQ_LEN', len);
    set('up_REQ_SIZE', 2);
    set('up_REQ_BURST', 1);
    await until(() => _req);
    set('up_REQ_VALID', 0);
  }

  Future<void> wdata(int data, {int last = 1}) async {
    _w = false;
    set('up_WDATA_VALID', 1);
    set('up_WDATA_DATA', data);
    set('up_WDATA_STRB', 0xf);
    set('up_WDATA_LAST', last);
    await until(() => _w);
    set('up_WDATA_VALID', 0);
  }

  /// A read beat from the memory, with the full ID the memory saw.
  Future<void> rResp(int id, int data, {int last = 1}) async {
    _r = false;
    set('bus_RVALID', 1);
    set('bus_RID', id);
    set('bus_RDATA', data);
    set('bus_RLAST', last);
    await until(() => _r);
    set('bus_RVALID', 0);
  }

  Future<void> bResp(int id, {int err = 0}) async {
    _b = false;
    set('bus_BVALID', 1);
    set('bus_BID', id);
    set('bus_BRESP', err);
    await until(() => _b);
    set('bus_BVALID', 0);
  }

  int get timeouts => cdc.output('debug_recover_timeouts').value.toInt();
  int get dropped => cdc.output('debug_dropped').value.toInt();

  /// The epoch bit of a bus ID.
  static int epoch(int id) => id >> _cfg.idWidth;

  static int low(int id) => id & ((1 << _cfg.idWidth) - 1);

  Future<void> end() => Simulator.endSimulation();
}

/// ID 0 for every request, as the PCIe DMA does. The old read never gets
/// its response. A new read after the device reset goes out with the other
/// epoch, gets its answer, and the device sees ID 0 and the new data.
Future<void> _neverComes() async {
  final b = await _Bench.start(_timeout);
  await b.req(0, 0, 0x100);
  await b.until(() => b.ar.isNotEmpty);
  await b.reset();
  await b.req(0, 0, 0x200);
  await b.until(() => b.ar.length == 2);
  must(b.ar.length, 2, reason: 'new read reached the fabric');
  must(b.ar[1].addr, 0x200);
  must(_Bench.low(b.ar[1].id), 0);
  must(_Bench.epoch(b.ar[1].id) != _Bench.epoch(b.ar[0].id), true);
  await b.rResp(b.ar[1].id, 0xbeef);
  await b.fall(20);
  must(b.rGot, [(id: 0, data: 0xbeef)]);
  must(b.timeouts, 1);
  must(b.top.output('dbg_recover_timeouts').value.toInt(), 1);
  // The same ID keeps working.
  await b.req(0, 0, 0x300);
  await b.until(() => b.ar.length == 3);
  await b.rResp(b.ar[2].id, 0xf00d);
  await b.fall(20);
  must(b.rGot.last, (id: 0, data: 0xf00d));
  must(b.rGot.length, 2);
  await b.end();
}

/// A write has owed data when the timer runs out. The data goes out as
/// filler first, then the new write sends its own data to its own address.
/// The late B of the old write has an error and is dropped. The device sees
/// only the B of the new write.
Future<void> _owedData() async {
  final b = await _Bench.start(_timeout);
  b.set('bus_WREADY', 0);
  await b.req(1, 1, 0x180, len: 1);
  await b.until(() => b.aw.isNotEmpty);
  await b.reset();
  await b.req(2, 1, 0x300);
  final wr = b.wdata(0xcafe);
  await b.until(() => b.aw.length == 2);
  must(b.aw.length, 2, reason: 'new write reached the fabric');
  must(b.aw[1].addr, 0x300);
  b.set('bus_WREADY', 1);
  await wr;
  await b.until(() => b.wBeats.length == 3);
  await b.fall(20);
  must(
    [for (final w in b.wBeats) (w.data, w.strb, w.last)],
    [(0, 0, 0), (0, 0, 1), (0xcafe, 0xf, 1)],
    reason: 'two filler beats, then the new data',
  );
  await b.bResp(b.aw[0].id, err: 2);
  await b.bResp(b.aw[1].id);
  await b.fall(20);
  must(b.bGot, [(id: 2, err: 0)]);
  await b.end();
}

/// A late read of four beats from before the give up is dropped whole.
Future<void> _staleBurst() async {
  final b = await _Bench.start(_timeout);
  await b.req(1, 0, 0x100, len: 3);
  await b.until(() => b.ar.isNotEmpty);
  await b.reset();
  await b.req(1, 0, 0x200);
  await b.until(() => b.ar.length == 2);
  for (var i = 0; i < 4; i++) {
    await b.rResp(b.ar[0].id, 0x10 + i, last: i == 3 ? 1 : 0);
  }
  await b.rResp(b.ar[1].id, 0xbeef);
  await b.fall(20);
  must(b.rGot, [(id: 1, data: 0xbeef)]);
  must(b.dropped, 4);
  await b.end();
}

/// One ID is stale while a live response of another ID comes. Then the
/// stale ID is used again.
Future<void> _otherId() async {
  final b = await _Bench.start(_timeout);
  await b.req(1, 0, 0x100);
  await b.until(() => b.ar.isNotEmpty);
  await b.reset();
  await b.req(2, 0, 0x200);
  await b.until(() => b.ar.length == 2);
  await b.rResp(b.ar[1].id, 0x22);
  await b.req(1, 0, 0x300);
  await b.until(() => b.ar.length == 3);
  await b.rResp(b.ar[0].id, 0xdead);
  await b.rResp(b.ar[2].id, 0x11);
  await b.fall(20);
  must(b.rGot, [(id: 2, data: 0x22), (id: 1, data: 0x11)]);
  await b.end();
}

/// Two give ups, with the late answer of the first read between them. The epoch goes back to the first one, and the
/// requests after the second still work.
Future<void> _twice() async {
  final b = await _Bench.start(_timeout);
  await b.req(0, 0, 0x100);
  await b.until(() => b.ar.isNotEmpty);
  await b.reset();
  await b.req(0, 0, 0x200);
  await b.until(() => b.ar.length == 2);
  // The late answer of the first read must come before a second give up.
  await b.rResp(b.ar[0].id, 0xdead);
  await b.reset();
  await b.req(0, 0, 0x300);
  await b.until(() => b.ar.length == 3);
  must(b.timeouts, 2);
  must(_Bench.epoch(b.ar[2].id), _Bench.epoch(b.ar[0].id));
  await b.rResp(b.ar[2].id, 0x33);
  await b.fall(20);
  must(b.rGot, [(id: 0, data: 0x33)]);
  await b.end();
}

/// The first give up leaves read A owed. A second device reset must not
/// give up again, or A's late response would look like the answer to a new
/// read. The crossing stays in recover mode, takes A and the second read B
/// as dropped responses, and then the new read C is answered once.
Future<void> _aliasAfterSecondReset() async {
  final b = await _Bench.start(_timeout);
  await b.req(0, 0, 0x100);
  await b.until(() => b.ar.isNotEmpty);
  await b.reset();
  await b.req(0, 0, 0x200);
  await b.until(() => b.ar.length == 2);
  must(b.timeouts, 1);
  await b.reset();
  await b.req(0, 0, 0x300);
  await b.fall(_timeout * 4);
  must(b.ar.length, 2, reason: 'no second give up while A is owed');
  must(b.timeouts, 1);
  await b.rResp(b.ar[0].id, 0xdead);
  await b.rResp(b.ar[1].id, 0xbad);
  await b.until(() => b.ar.length == 3);
  must(b.ar.length, 3, reason: 'recover ends after the owed responses');
  must(b.ar[2].addr, 0x300);
  await b.rResp(b.ar[2].id, 0xbeef);
  await b.fall(20);
  must(b.rGot, [(id: 0, data: 0xbeef)]);
  must(b.timeouts, 1);
  // The R path is not stuck: another read works.
  await b.req(0, 0, 0x400);
  await b.until(() => b.ar.length == 4);
  await b.rResp(b.ar[3].id, 0x44);
  await b.fall(20);
  must(b.rGot.last, (id: 0, data: 0x44));
  await b.end();
}

/// With no wait limit the crossing waits for the response for ever, and
/// goes on when it comes.
Future<void> _noLimit() async {
  final b = await _Bench.start(0);
  await b.req(0, 0, 0x100);
  await b.until(() => b.ar.isNotEmpty);
  await b.reset();
  await b.req(0, 0, 0x200);
  await b.fall(400);
  must(b.ar.length, 1);
  must(b.timeouts, 0);
  await b.rResp(b.ar[0].id, 0xdead);
  await b.until(() => b.ar.length == 2);
  must(b.ar.length, 2);
  must(b.rGot, isEmpty);
  must(b.timeouts, 0);
  await b.end();
}

void main() {
  tearDown(endAndReset);

  test(
    'responses that never come do not block the same ID',
    () => isolated(_neverComes),
  );
  test(
    'a write with owed data sends filler, then the new write',
    () => isolated(_owedData),
  );
  test('a late burst is dropped', () => isolated(_staleBurst));
  test('a live ID works while another ID is stale', () => isolated(_otherId));
  test('a second give up flips the epoch back', () => isolated(_twice));
  test(
    'no second give up while old responses are owed',
    () => isolated(_aliasAfterSecondReset),
  );
  test('recoverTimeout 0 never gives up', () => isolated(_noLimit));

  test('a negative recoverTimeout names the field', () {
    expect(
      () => CdcMemDevice(
        _cfg,
        HarborFabricKind.axi4,
        slave: false,
        cross: true,
        recoverTimeout: -1,
      ),
      throwsA(
        isA<ArgumentError>().having((e) => e.name, 'name', 'recoverTimeout'),
      ),
    );
  });
}
