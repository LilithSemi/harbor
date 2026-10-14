import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'port_harness.dart';

/// Address that every slave model fails.
const _errAddr = errWord * 4;

/// The register master waist of a [MasterShell], driven by the test.
StrobeMaster _waist(Sim s) => StrobeMaster(
  s,
  strobes: ['m_stb'],
  we: 'm_we',
  addr: 'm_addr',
  wdata: 'm_wdata',
  sel: 'm_sel',
  ack: 'm_ack',
  err: 'm_err',
  rdata: 'm_rdata',
);

/// Wishbone classic slave model. Samples on the rising edge and answers on
/// the next falling edge after [latency] extra cycles.
class _WbSlave {
  final Map<int, int> mem = {};
  int accesses = 0;

  _WbSlave(Sim s, {int latency = 0}) {
    var wait = 0;
    var acked = false;
    (int, int, int)? next;
    s.onRise(() {
      next = null;
      if (acked) {
        acked = false;
        return;
      }
      if (s.pre('bus_CYC') == 1 && s.pre('bus_STB') == 1) {
        if (wait++ < latency) return;
        wait = 0;
        acked = true;
        accesses++;
        final addr = s.pre('bus_ADR');
        if (addr == _errAddr) {
          next = (0, 0, 1);
        } else if (s.pre('bus_WE') == 1) {
          mem[addr] = mergeBytes(
            mem[addr] ?? 0,
            s.pre('bus_DAT_MOSI'),
            s.pre('bus_SEL'),
          );
          next = (0, 1, 0);
        } else {
          next = (mem[addr] ?? 0, 1, 0);
        }
      }
    });
    s.onFall(() {
      s.set('bus_DAT_MISO', next?.$1 ?? 0);
      s.set('bus_ACK', next?.$2 ?? 0);
      s.set('bus_ERR', next?.$3 ?? 0);
    });
  }
}

/// AXI4-Lite subordinate model. AWREADY rises every [awEvery] cycles and
/// WREADY every [wEvery] cycles, so AW and W are taken at different times.
class _AxiSlave {
  final Map<int, int> mem = {};
  int writes = 0;
  int reads = 0;

  _AxiSlave(Sim s, {int awEvery = 1, int wEvery = 1}) {
    var cycle = 0;
    int? aw;
    (int, int)? w;
    int? ar;
    int? b;
    (int, int)? r;
    s.onRise(() {
      if (s.pre('bus_AWVALID') == 1 && s.pre('bus_AWREADY') == 1) {
        aw = s.pre('bus_AWADDR');
      }
      if (s.pre('bus_WVALID') == 1 && s.pre('bus_WREADY') == 1) {
        w = (s.pre('bus_WDATA'), s.pre('bus_WSTRB'));
      }
      if (s.pre('bus_ARVALID') == 1 && s.pre('bus_ARREADY') == 1) {
        ar = s.pre('bus_ARADDR');
      }
      if (s.pre('bus_BVALID') == 1 && s.pre('bus_BREADY') == 1) b = null;
      if (s.pre('bus_RVALID') == 1 && s.pre('bus_RREADY') == 1) r = null;
      if (aw != null && w != null && b == null) {
        writes++;
        if (aw == _errAddr) {
          b = 2;
        } else {
          mem[aw!] = mergeBytes(mem[aw!] ?? 0, w!.$1, w!.$2);
          b = 0;
        }
        aw = null;
        w = null;
      }
      if (ar != null && r == null) {
        reads++;
        r = ar == _errAddr ? (0, 2) : (mem[ar!] ?? 0, 0);
        ar = null;
      }
    });
    s.onFall(() {
      cycle++;
      s.set('bus_AWREADY', aw == null && cycle % awEvery == 0 ? 1 : 0);
      s.set('bus_WREADY', w == null && cycle % wEvery == 0 ? 1 : 0);
      s.set('bus_ARREADY', ar == null ? 1 : 0);
      s.set('bus_BVALID', b == null ? 0 : 1);
      s.set('bus_BRESP', b ?? 0);
      s.set('bus_RVALID', r == null ? 0 : 1);
      s.set('bus_RDATA', r?.$1 ?? 0);
      s.set('bus_RRESP', r?.$2 ?? 0);
    });
  }
}

/// TileLink-UL slave model. A_READY rises every [aEvery] cycles.
class _TlSlave {
  final Map<int, int> mem = {};
  final List<int> opcodes = [];

  _TlSlave(Sim s, {int aEvery = 1}) {
    var cycle = 0;
    Map<String, int>? a;
    (int, int, int)? d;
    s.onRise(() {
      if (s.pre('bus_A_VALID') == 1 && s.pre('bus_A_READY') == 1) {
        a = {
          for (final f in ['OPCODE', 'ADDRESS', 'DATA', 'MASK', 'SIZE'])
            f: s.pre('bus_A_$f'),
        };
      }
      if (s.pre('bus_D_VALID') == 1 && s.pre('bus_D_READY') == 1) d = null;
      if (a != null && d == null) {
        final op = a!['OPCODE']!;
        final addr = a!['ADDRESS']!;
        opcodes.add(op);
        expect(a!['SIZE'], 2);
        expect(addr % 4, 0);
        if (addr == _errAddr) {
          d = (op == 4 ? 1 : 0, 0, 1);
        } else if (op == 4) {
          expect(a!['MASK'], 0xf);
          d = (1, mem[addr] ?? 0, 0);
        } else {
          expect(op == 0, a!['MASK'] == 0xf);
          mem[addr] = mergeBytes(mem[addr] ?? 0, a!['DATA']!, a!['MASK']!);
          d = (0, 0, 0);
        }
        a = null;
      }
    });
    s.onFall(() {
      cycle++;
      s.set('bus_A_READY', a == null && cycle % aEvery == 0 ? 1 : 0);
      s.set('bus_D_VALID', d == null ? 0 : 1);
      s.set('bus_D_OPCODE', d?.$1 ?? 0);
      s.set('bus_D_DATA', d?.$2 ?? 0);
      s.set('bus_D_DENIED', d?.$3 ?? 0);
      s.set('bus_D_CORRUPT', d != null && d!.$1 == 1 ? d!.$3 : 0);
    });
  }
}

/// Runs the same access sequence through any kind and checks the waist side.
Future<void> _sequence(StrobeMaster m) async {
  expect(await m.access(true, 0x0, data: 0x11223344), (0, 1, 0));
  expect((await m.access(false, 0x0)).$1, 0x11223344);
  await m.access(true, 0x0, data: 0x0000aa00, byteSel: 0x2);
  expect((await m.access(false, 0x0)).$1, 0x1122aa44);

  final err = await m.access(true, _errAddr, data: 1);
  expect((err.$2, err.$3), (1, 1));
  expect((await m.access(false, _errAddr)).$3, 1);

  // Back to back with the strobe held.
  final results = await Future.wait([
    m.access(true, 0x4, data: 0xa),
    m.access(true, 0x8, data: 0xb),
    m.access(false, 0x4),
    m.access(false, 0x8),
  ]);
  expect(results[2].$1, 0xa);
  expect(results[3].$1, 0xb);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('Wishbone register master', () {
    for (final latency in [0, 3]) {
      test('accesses with $latency wait cycles', () async {
        final sim = Sim(MasterShell(HarborFabricKind.wishbone));
        final slave = _WbSlave(sim, latency: latency);
        final m = _waist(sim);
        await sim.start();
        await _sequence(m);
        expect(slave.accesses, 10);
        await sim.stop();
      });
    }
  });

  group('AXI4-Lite register master', () {
    for (final (awEvery, wEvery) in [(1, 1), (3, 1), (1, 3), (2, 5)]) {
      test('accesses, AWREADY every $awEvery, WREADY every $wEvery', () async {
        final sim = Sim(MasterShell(HarborFabricKind.axi4));
        final slave = _AxiSlave(sim, awEvery: awEvery, wEvery: wEvery);
        final m = _waist(sim);
        await sim.start();
        await _sequence(m);
        expect((slave.writes, slave.reads), (5, 5));
        await sim.stop();
      });
    }

    test('DECERR is an error too', () async {
      final sim = Sim(MasterShell(HarborFabricKind.axi4));
      final m = _waist(sim);
      var bValid = false;
      sim.onRise(() {
        if (sim.pre('bus_AWVALID') == 1 && sim.pre('bus_WVALID') == 1) {
          bValid = true;
        }
        if (sim.pre('bus_BVALID') == 1) bValid = false;
      });
      sim.onFall(() {
        sim.set('bus_AWREADY', 1);
        sim.set('bus_WREADY', 1);
        sim.set('bus_BVALID', bValid ? 1 : 0);
        sim.set('bus_BRESP', 3);
      });
      await sim.start();
      final r = await m.access(true, 0x0, data: 1);
      expect((r.$2, r.$3), (1, 1));
      await sim.stop();
    });

    test('dropping stb after AW is accepted clears awDone', () async {
      final sim = Sim(MasterShell(HarborFabricKind.axi4));
      // AWREADY always fires. WREADY and BVALID never do, so once AW is
      // taken the access can only end by the device dropping stb.
      var stbOn = false;
      var awAccepted = false;
      var watchRecovery = false;
      var recoveryAwValid = false;
      sim.onRise(() {
        if (sim.pre('bus_AWVALID') == 1 && sim.pre('bus_AWREADY') == 1) {
          awAccepted = true;
        }
        if (watchRecovery && sim.pre('bus_AWVALID') == 1) {
          recoveryAwValid = true;
        }
      });
      sim.onFall(() {
        sim.set('bus_AWREADY', 1);
        sim.set('bus_WREADY', 0);
        sim.set('bus_BVALID', 0);
        sim.set('m_stb', stbOn ? 1 : 0);
        sim.set('m_we', 1);
        sim.set('m_addr', 0x4);
        sim.set('m_wdata', 0xbeef);
        sim.set('m_sel', 0xf);
      });
      await sim.start();

      stbOn = true;
      await sim.cycles(3);
      expect(awAccepted, isTrue, reason: 'AW must be taken before stb drops');

      // The device abandons the access before B ever arrives.
      stbOn = false;
      await sim.cycles(2);

      // A fresh write must raise AWVALID again. Before the fix, awDone
      // stayed set from the dropped access and AWVALID never rose.
      watchRecovery = true;
      stbOn = true;
      await sim.cycles(2);
      expect(
        recoveryAwValid,
        isTrue,
        reason: 'awDone must clear when stb dropped',
      );
      await sim.stop();
    });
  });

  group('AXI4 write commit', () {
    // The subordinate takes AW and W at once and holds B back for [bDelay]
    // cycles. It answers [bResp] and [rResp].
    void delayedB(Sim sim, {int bDelay = 5, int bResp = 0, int rResp = 0}) {
      var wait = -1;
      var rValid = false;
      sim.onRise(() {
        if (sim.pre('bus_BVALID') == 1) wait = -1;
        if (sim.pre('bus_AWVALID') == 1 && sim.pre('bus_WVALID') == 1) {
          wait = bDelay;
        } else if (wait > 0) {
          wait--;
        }
        rValid = sim.pre('bus_ARVALID') == 1;
      });
      sim.onFall(() {
        sim.set('bus_AWREADY', 1);
        sim.set('bus_WREADY', 1);
        sim.set('bus_ARREADY', 1);
        sim.set('bus_BVALID', wait == 0 ? 1 : 0);
        sim.set('bus_BRESP', bResp);
        sim.set('bus_RVALID', rValid ? 1 : 0);
        sim.set('bus_RRESP', rResp);
        if (sim.dut.tryInput('bus_RLAST') != null) sim.set('bus_RLAST', 1);
      });
    }

    for (final exclusive in [false, true]) {
      test(
        'a write ack never comes before B${exclusive ? ', full AXI4' : ''}',
        () async {
          final sim = Sim(
            MasterShell(HarborFabricKind.axi4, exclusive: exclusive),
          );
          delayedB(sim);
          final acks = <int>[];
          final bs = <int>[];
          var cycle = 0;
          sim.onRise(() {
            cycle++;
            if (sim.pre('bus_BVALID') == 1) bs.add(cycle);
            if (sim.pre('m_ack') == 1) acks.add(cycle);
          });
          final m = _waist(sim);
          await sim.start();
          for (var i = 0; i < 3; i++) {
            expect(await m.access(true, 4 * i, data: i), (0, 1, 0));
          }
          expect(acks, bs);
          expect(acks.length, 3);
          await sim.stop();
        },
      );
    }

    test(
      'an exclusive port drives AxLOCK from lock and reports EXOKAY',
      () async {
        final sim = Sim(MasterShell(HarborFabricKind.axi4, exclusive: true));
        // EXOKAY on B and R.
        delayedB(sim, bDelay: 1, bResp: 1, rResp: 1);
        var lock = 0;
        final awLocks = <int>[];
        final arLocks = <int>[];
        final exokays = <int>[];
        sim.onFall(() => sim.set('m_lock', lock));
        sim.onRise(() {
          if (sim.pre('bus_AWVALID') == 1) awLocks.add(sim.pre('bus_AWLOCK'));
          if (sim.pre('bus_ARVALID') == 1) arLocks.add(sim.pre('bus_ARLOCK'));
          if (sim.pre('m_ack') == 1) exokays.add(sim.pre('m_exokay'));
          expect(sim.pre('bus_AWLEN'), 0);
          expect(sim.pre('bus_AWSIZE'), 2);
          expect(sim.pre('bus_AWBURST'), 1);
          expect(sim.pre('bus_AWID'), 0);
          expect(sim.pre('bus_ARID'), 0);
        });
        final m = _waist(sim);
        await sim.start();
        lock = 1;
        await m.access(false, 0x10);
        await m.access(true, 0x10, data: 1);
        expect(awLocks.toSet(), {1});
        expect(arLocks.toSet(), {1});
        expect(exokays, [1, 1]);
        await sim.stop();
      },
    );

    for (final kind in [HarborFabricKind.tilelink, HarborFabricKind.wishbone]) {
      test('a ${kind.name} port cannot be exclusive', () {
        expect(() => MasterShell(kind, exclusive: true), throwsArgumentError);
      });
    }
  });

  group('TileLink-UL register master', () {
    for (final aEvery in [1, 3]) {
      test('accesses, A_READY every $aEvery', () async {
        final sim = Sim(MasterShell(HarborFabricKind.tilelink));
        final slave = _TlSlave(sim, aEvery: aEvery);
        final m = _waist(sim);
        await sim.start();
        await _sequence(m);
        // PutFull, Get, PutPartial, Get, PutFull, Get, PutFull x2, Get x2.
        expect(slave.opcodes, [0, 4, 1, 4, 0, 4, 0, 0, 4, 4]);
        await sim.stop();
      });
    }
  });
}
