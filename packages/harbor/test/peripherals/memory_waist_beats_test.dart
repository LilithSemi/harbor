import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:harbor/src/peripherals/memory_waist_beats.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../bus/port/memory_harness.dart';
import '../bus/port/port_harness.dart';

/// [HarborMemoryBeats] with its waist on `up_*` and its storage port on
/// `st_*`, so a test can be the storage.
class _BeatsShell extends BridgeModule {
  _BeatsShell(HarborMemoryWaistConfig c)
    : super('BeatsTestShell_d${c.dataWidth}', name: 'shell') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('st_ack', PortDirection.input);
    createPort('st_rdata', PortDirection.input, width: c.dataWidth);
    final waist = HarborMemoryWaist(c);
    final beats = HarborMemoryBeats(
      clk: input('clk'),
      reset: input('reset'),
      waist: waist,
      ack: input('st_ack'),
      dataOut: input('st_rdata'),
    );
    exposeWaist(this, waist, 'up', PairRole.consumer);
    for (final (n, l) in [
      ('st_stb', beats.stb),
      ('st_we', beats.we),
      ('st_addr', beats.addr),
      ('st_wdata', beats.dataIn),
      ('st_sel', beats.sel),
    ]) {
      createPort(n, PortDirection.output, width: l.width);
      output(n) <= l;
    }
  }
}

/// A storage on `st_*` that answers each strobe after 0 to [maxWait] wait
/// states. Records every beat and fails on a strobe that changes before its
/// ACK or stays high in the ACK cycle.
class _Storage {
  final Sim s;
  final Random rng;
  final int busBytes;
  final int maxWait;
  final List<String> errors;
  final WordMemory mem;
  final List<(int, bool, int, int)> beats = [];
  (int, bool, int, int)? _held;
  int? _wait;

  _Storage(this.s, this.rng, this.busBytes, this.errors, {this.maxWait = 3})
    : mem = WordMemory(busBytes) {
    s.onRise(() {
      final stb = s.pre('st_stb') == 1;
      if (s.pre('st_ack') == 1) {
        if (stb) errors.add('STB high in the ACK cycle');
        return;
      }
      if (!stb) {
        if (_held != null) errors.add('STB dropped before ACK');
        return;
      }
      final now = (
        s.pre('st_addr'),
        s.pre('st_we') == 1,
        s.pre('st_wdata'),
        s.pre('st_sel'),
      );
      if (_held == null) {
        _held = now;
        _wait = rng.nextInt(maxWait + 1);
      } else if (_held != now) {
        errors.add('beat changed before ACK: $_held -> $now');
      }
    });
    s.onFall(() {
      final b = _held;
      if (b == null || _wait! > 0) {
        if (b != null) _wait = _wait! - 1;
        s.set('st_ack', 0);
        return;
      }
      final (addr, we, data, sel) = b;
      beats.add(b);
      s.set('st_rdata', we ? 0 : mem.read(addr));
      if (we) mem.write(addr, data, sel);
      s.set('st_ack', 1);
      _held = null;
    });
  }
}

void main() {
  tearDown(endAndReset);

  const c = HarborMemoryWaistConfig(
    addressWidth: 16,
    dataWidth: 32,
    idWidth: 3,
  );

  Future<void> run(
    List<Burst> Function(BurstGen gen, Random rng) traffic, {
    int seed = 1,
    int maxWait = 3,
  }) async {
    final rng = Random(seed);
    final s = Sim(_BeatsShell(c));
    final errors = <String>[];
    final req = WaistRequester(s, 'up', rng, errors: errors);
    final st = _Storage(s, rng, 4, errors, maxWait: maxWait);
    var inflight = 0;
    var most = 0;
    s.onRise(() {
      if (s.pre('up_REQ_VALID') == 1 && s.pre('up_REQ_READY') == 1) {
        most = max(most, ++inflight);
      }
      if (s.pre('up_RDATA_VALID') == 1 &&
          s.pre('up_RDATA_READY') == 1 &&
          s.pre('up_RDATA_LAST') == 1) {
        inflight--;
      }
      if (s.pre('up_WRESP_VALID') == 1 && s.pre('up_WRESP_READY') == 1) {
        inflight--;
      }
    });
    StableCheck(s, 'up_RDATA_VALID', 'up_RDATA_READY', [
      'up_RDATA_ID',
      'up_RDATA_DATA',
      'up_RDATA_ERR',
      'up_RDATA_LAST',
    ], errors);
    StableCheck(s, 'up_WRESP_VALID', 'up_WRESP_READY', [
      'up_WRESP_ID',
      'up_WRESP_ERR',
    ], errors);
    final gen = BurstGen(rng, busBytes: 4, idWidth: c.idWidth, span: 0x4000);
    final bursts = traffic(gen, rng);
    final want = WordMemory(4);
    final expectBeats = <(int, bool, int, int)>[];
    for (final b in bursts) {
      req.send(b);
      final addrs = beatAddrs(b.addr, b.len, b.size, b.burst);
      for (var i = 0; i < b.beats; i++) {
        final lanes = _laneMask(addrs[i], b.size);
        expectBeats.add((
          addrs[i],
          b.write,
          b.write ? b.data[i] : 0,
          b.write ? b.strb[i] & lanes : lanes,
        ));
      }
    }
    await s.start();
    Simulator.setMaxSimTime(50000000);
    await waitUntil(s, () => req.done, limit: 400000);
    await s.stop();

    expect(errors, isEmpty);
    expect(most, 1);
    // Reads carry no write data, so compare their data field as 0.
    expect([
      for (final (a, w, d, sel) in st.beats) (a, w, w ? d : 0, sel),
    ], expectBeats);
    for (final r in req.writeResp) {
      expect(r.$2, 0);
    }
    var ri = 0;
    for (final b in bursts) {
      final addrs = beatAddrs(b.addr, b.len, b.size, b.burst);
      if (b.write) {
        for (var i = 0; i < b.beats; i++) {
          want.write(
            addrs[i],
            b.data[i],
            b.strb[i] & _laneMask(addrs[i], b.size),
          );
        }
        continue;
      }
      final got = req.readResp[ri++];
      expect(got, [
        for (var i = 0; i < b.beats; i++)
          (b.id, want.read(addrs[i]), 0, i == b.len ? 1 : 0),
      ], reason: '$b');
    }
    expect(req.writeResp.map((r) => r.$1), [
      for (final b in bursts)
        if (b.write) b.id,
    ]);
  }

  test('random bursts of every type, size and length', () async {
    await run((gen, rng) {
      final out = <Burst>[];
      for (var i = 0; i < 120; i++) {
        out.add(gen.next(write: rng.nextBool()));
      }
      return out;
    });
  });

  test('256 beat bursts of every type, with no wait states', () async {
    await run((gen, rng) {
      Burst b(bool write, int addr, int burst, int size) => Burst(
        id: rng.nextInt(8),
        write: write,
        addr: addr,
        len: 255,
        size: size,
        burst: burst,
        data: [for (var i = 0; i < 256; i++) rng.nextInt(1 << 32)],
        strb: [for (var i = 0; i < 256; i++) rng.nextInt(16)],
      );
      return [
        for (final size in [0, 1, 2])
          for (final burst in [0, 1, 2]) ...[
            b(true, burst == 2 ? 0x1008 : 0x1001, burst, size),
            b(false, 0x1000 + 0x40 * burst, burst, size),
          ],
      ];
    }, maxWait: 0);
  });

  test(
    'a write with every strobe low changes nothing and has no ERR',
    () async {
      await run(
        (gen, rng) => [
          Burst(
            id: 1,
            write: true,
            addr: 0x200,
            len: 7,
            size: 2,
            burst: 1,
            data: List.filled(8, 0xffffffff),
            strb: List.filled(8, 0),
          ),
          Burst(id: 2, write: false, addr: 0x200, len: 7, size: 2, burst: 1),
        ],
      );
    },
  );

  test('STB is low while reset is high, even mid burst', () async {
    final rng = Random(4);
    final s = Sim(_BeatsShell(c));
    final errors = <String>[];
    final req = WaistRequester(s, 'up', rng, errors: errors, idle: 0);
    _Storage(s, rng, 4, errors, maxWait: 6);
    var inReset = 0;
    var stbInReset = 0;
    s.onRise(() {
      if (s.pre('reset') == 1) {
        inReset++;
        if (s.pre('st_stb') == 1) stbInReset++;
      }
    });
    req.send(
      Burst(id: 0, write: false, addr: 0x40, len: 31, size: 2, burst: 1),
    );
    await s.start();
    await s.cycles(9);
    s.set('reset', 1);
    await s.cycles(3);
    s.set('reset', 0);
    await s.cycles(2);
    await s.stop();
    expect(inReset, greaterThan(0));
    expect(stbInReset, 0);
  });

  test('REQ_READY does not wait for WDATA_VALID', () async {
    final rng = Random(3);
    final s = Sim(_BeatsShell(c));
    final errors = <String>[];
    final req = WaistRequester(s, 'up', rng, errors: errors, idle: 0);
    _Storage(s, rng, 4, errors);
    req.wdata.idle = 1;
    req.send(
      Burst(
        id: 0,
        write: true,
        addr: 0x10,
        len: 3,
        size: 2,
        burst: 1,
        data: [1, 2, 3, 4],
        strb: [15, 15, 15, 15],
      ),
    );
    await s.start();
    await waitUntil(s, () => req.req.idleNow, limit: 50);
    req.wdata.idle = 0;
    await waitUntil(s, () => req.done, limit: 200);
    await s.stop();
    expect(errors, isEmpty);
  });
}

int _laneMask(int addr, int size) {
  final bytes = 1 << size;
  final lo = (addr & ~(bytes - 1)) % 4;
  var m = 0;
  for (var i = lo; i < lo + bytes && i < 4; i++) {
    m |= 1 << i;
  }
  return m;
}
