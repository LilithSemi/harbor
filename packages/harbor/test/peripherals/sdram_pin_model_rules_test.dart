import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_pin_model.dart';

/// A free-running clk this test can glitch: it self-chains like
/// [SimpleClockGenerator], but [highPs] and [lowPs] are mutable so one half
/// period can be made too short, checked, then restored.
class _ClkDriver {
  _ClkDriver(int periodPs)
    : highPs = periodPs ~/ 2,
      lowPs = periodPs - periodPs ~/ 2 {
    _arm();
  }

  final Logic clk = Logic(name: 'sdram_clk')..inject(0);
  int highPs, lowPs;
  bool _high = false;

  void _arm() {
    final delay = _high ? highPs : lowPs;
    Simulator.registerAction(Simulator.time + delay, () {
      _high = !_high;
      clk.put(_high ? LogicValue.one : LogicValue.zero);
      _arm();
    });
  }
}

Future<void> _delayPs(Logic clk, int ps) async {
  final c = Completer<void>();
  Simulator.registerAction(Simulator.time + ps, c.complete);
  await c.future;
}

/// The controller-side pin driver: every sdram pin, plus its own
/// TriStateBuffer standing in for the fpga, changing pins on `clk` negedges.
class _Driver {
  _Driver(this.clk) {
    dq <= TriStateBuffer(dqDrv, enable: dqEn, name: 'fpga_dq').out;
    Simulator.injectAction(() {
      dqDrv.put(0);
      dqEn.put(0);
    });
  }

  final Logic clk;
  final Logic cke = Logic(name: 'cke')..inject(0);
  final Logic csN = Logic(name: 'cs_n')..inject(1);
  final Logic rasN = Logic(name: 'ras_n')..inject(1);
  final Logic casN = Logic(name: 'cas_n')..inject(1);
  final Logic weN = Logic(name: 'we_n')..inject(1);
  final Logic ba = Logic(name: 'ba', width: 2)..inject(0);
  final Logic addr = Logic(name: 'addr', width: 13)..inject(0);
  final Logic dqm = Logic(name: 'dqm', width: 2)..inject(0);
  final LogicNet dq = LogicNet(name: 'dq', width: 16);
  final Logic dqDrv = Logic(name: 'fpga_dq_drv', width: 16);
  final Logic dqEn = Logic(name: 'fpga_dq_en');

  Future<void> _issue(
    int cmd3, {
    int bank = 0,
    int a = 0,
    int cke = 1,
    int? data,
    int? dqmBits,
  }) async {
    await clk.nextNegedge;
    rasN.put((cmd3 >> 2) & 1);
    casN.put((cmd3 >> 1) & 1);
    weN.put(cmd3 & 1);
    csN.put(0);
    ba.put(bank);
    addr.put(a);
    this.cke.put(cke);
    if (dqmBits != null) dqm.put(dqmBits);
    if (data != null) {
      dqDrv.put(data);
      dqEn.put(1);
    } else {
      dqEn.put(0);
    }
    await clk.nextPosedge;
  }

  Future<void> nop({int cke = 1}) => _issue(7, cke: cke);
  Future<void> deselect() async {
    await clk.nextNegedge;
    csN.put(1);
    await clk.nextPosedge;
  }

  Future<void> prechargeAll({int cke = 1}) => _issue(2, a: 1 << 10, cke: cke);
  Future<void> precharge(int bank) => _issue(2, bank: bank);
  Future<void> mrs(int word, {int bank = 0}) => _issue(0, a: word, bank: bank);
  Future<void> refresh() => _issue(1);
  Future<void> activate(int bank, int row) => _issue(3, bank: bank, a: row);
  Future<void> read(int bank, int col, {bool a10 = false}) =>
      _issue(5, bank: bank, a: col | (a10 ? (1 << 10) : 0));
  Future<void> burstStop() => _issue(6);
  Future<void> write(int bank, int col, int data, {int dqmBits = 0}) =>
      _issue(4, bank: bank, a: col, data: data, dqmBits: dqmBits);

  Future<void> waitEdges(int n) async {
    for (var i = 0; i < n; i++) {
      await nop();
    }
  }
}

const rules = SdramModelRules.as4c16m16sb6();
const periodPs = 8000; // 125 MHz, table 16 tCK3 min 6ns, p21.
const cl = 3;
const mrsWord = 0x233; // CL3, BL8, single write (table 9 p15, table 6 p14).

int _ceilCycles(double ns) => (ns * 1000 / periodPs).ceil();

/// Raises cke after holding it low for at least [powerUpNs], then one more
/// nop so the next real command sees cke high on the previous edge.
Future<void> _powerUp(_Driver d, double powerUpNs) async {
  final cycles = (powerUpNs * 1000 / periodPs).ceil() + 2;
  for (var i = 0; i < cycles; i++) {
    await d.nop(cke: 0);
  }
  await d.nop(cke: 1);
}

Future<void> _initToReady(_Driver d, SdramModelRules r) async {
  await _powerUp(d, r.powerUpNs);
  await d.prechargeAll();
  await d.waitEdges(_ceilCycles(r.tRp));
  await d.mrs(mrsWord);
  final mrd = _ceilCycles(r.tMrd);
  await d.waitEdges(mrd > r.tMrdNck ? mrd : r.tMrdNck);
  await d.refresh();
  await d.waitEdges(_ceilCycles(r.tRfc));
  await d.refresh();
  await d.waitEdges(_ceilCycles(r.tRfc));
}

class _Rig {
  _Rig(this.clkDriver, this.d, this.model);
  final _ClkDriver clkDriver;
  final _Driver d;
  final SdramPinModel model;
  Logic get clk => clkDriver.clk;
}

_Rig _setup({
  SdramModelRules? rulesOverride,
  SdramRefreshPolicy? refreshPolicy,
  // Most tests pass the driver's own oe/out straight through, the same
  // way a real testbench would wire a registered phy. A few turn this
  // off on purpose, to keep covering the net-inference fallback.
  bool withFpgaSignals = true,
}) {
  final clkDriver = _ClkDriver(periodPs);
  final d = _Driver(clkDriver.clk);
  final model = SdramPinModel(
    clk: clkDriver.clk,
    cke: d.cke,
    csN: d.csN,
    rasN: d.rasN,
    casN: d.casN,
    weN: d.weN,
    ba: d.ba,
    addr: d.addr,
    dqm: d.dqm,
    dq: d.dq,
    rules: rulesOverride ?? rules.copyWith(powerUpNs: 2000),
    refreshPolicy: refreshPolicy,
    fpgaDqOe: withFpgaSignals ? d.dqEn : null,
    fpgaDqOut: withFpgaSignals ? d.dqDrv : null,
  );
  return _Rig(clkDriver, d, model);
}

void _expectOnly(SdramPinModel m, String rule) {
  final matches = m.errors.where((e) => e.contains(': $rule:')).toList();
  expect(
    matches,
    hasLength(1),
    reason: 'wanted exactly one $rule error, got:\n${m.errors.join('\n')}',
  );
}

void main() {
  tearDown(() async => Simulator.reset());

  test('clock: a short tCL fires once', () async {
    final rig = _setup();
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());

    await rig.d.deselect();
    // The driver already armed the upcoming negedge from the old lowPs, so
    // the mutation has to land one edge earlier, right after a posedge, to
    // reach the _arm() call that has not run yet.
    await rig.clk.nextPosedge;
    rig.clkDriver.lowPs = 500; // below tCL (2ns)
    await rig.clk.nextNegedge;
    await rig.clk.nextPosedge;
    rig.clkDriver.lowPs = periodPs - periodPs ~/ 2;
    await rig.d.waitEdges(2);

    rig.model.finish();
    await Simulator.endSimulation();
    _expectOnly(rig.model, 'clock');
  });

  test(
    'cl-clock: tCK shorter than tCkMin for the active CAS latency fires once',
    () async {
      final rig = _setup();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _initToReady(rig.d, rig.model.rules);
      await rig.clk.nextNegedge;
      rig.clkDriver.highPs =
          2000; // arms the next posedge's high-phase duration.
      await rig.clk.nextPosedge;
      rig.clkDriver.lowPs = 2000; // arms the next negedge's low-phase duration.
      await rig.clk.nextNegedge;
      rig.clkDriver.highPs = periodPs ~/ 2;
      rig.clkDriver.lowPs = periodPs - periodPs ~/ 2;
      await rig
          .clk
          .nextPosedge; // period here: 2000 + 2000 = 4000ps < tCkMin(CL3) 6000ps.
      await rig.d.waitEdges(2);

      rig.model.finish();
      await Simulator.endSimulation();
      _expectOnly(rig.model, 'cl-clock');
    },
  );

  test('setup: a pin changing within tIS of an edge fires once', () async {
    final rig = _setup();
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());

    await rig.clk.nextNegedge;
    rig.d.csN.put(1); // deselected: no command is decoded.
    await _delayPs(
      rig.clk,
      periodPs ~/ 2 - 500,
    ); // 500ps before the posedge, below tIS (1.5ns)
    rig.d.ba.put(2);
    await rig.clk.nextPosedge;
    rig.d.ba.put(0);
    await rig.d.waitEdges(2);

    rig.model.finish();
    await Simulator.endSimulation();
    _expectOnly(rig.model, 'setup');
  });

  test('hold: a pin changing within tIH of an edge fires once', () async {
    final rig = _setup();
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());

    await rig.d.deselect();
    await rig.clk.nextPosedge;
    await _delayPs(rig.clk, 300); // 300ps after the edge, below tIH (0.8ns)
    rig.d.ba.put(2);
    await rig.d.waitEdges(2);

    rig.model.finish();
    await Simulator.endSimulation();
    _expectOnly(rig.model, 'hold');
  });

  test(
    'cke: a command issued without cke high on the previous edge fires once',
    () async {
      final rig = _setup();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      final cycles = (rig.model.rules.powerUpNs * 1000 / periodPs).ceil() + 2;
      for (var i = 0; i < cycles; i++) {
        await rig.d.nop(cke: 0);
      }
      // Raise cke and issue the first real command on the same edge, instead
      // of waiting one more nop: the previous edge still saw cke low.
      await rig.d.prechargeAll(cke: 1);
      await rig.d.waitEdges(2);

      rig.model.finish();
      await Simulator.endSimulation();
      _expectOnly(rig.model, 'cke');
    },
  );

  test(
    'init-order: a mode register set before precharge-all fires once',
    () async {
      final rig = _setup();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _powerUp(rig.d, rig.model.rules.powerUpNs);
      await rig.d.mrs(mrsWord); // precharge-all never happened yet.
      await rig.d.prechargeAll();
      await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRp));
      final mrd = _ceilCycles(rig.model.rules.tMrd);
      await rig.d.waitEdges(
        mrd > rig.model.rules.tMrdNck ? mrd : rig.model.rules.tMrdNck,
      );
      await rig.d.refresh();
      await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRfc));
      await rig.d.refresh();
      await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRfc));
      await rig.d.activate(0, 5);

      await Simulator.endSimulation();
      _expectOnly(rig.model, 'init-order');
    },
  );

  test('power-up: raising cke before powerUpNs elapses fires once', () async {
    final rig = _setup(rulesOverride: rules); // the real 200us.
    Simulator.setMaxSimTime(400000000);
    unawaited(Simulator.run());

    await rig.d.waitEdges(1000); // far short of 200us.
    await rig.d.nop(cke: 1);
    await rig.d.waitEdges(2);

    await Simulator.endSimulation();
    _expectOnly(rig.model, 'power-up');
  });

  test(
    'mode-register: a nonzero BA during a mode register set fires once',
    () async {
      final rig = _setup();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _powerUp(rig.d, rig.model.rules.powerUpNs);
      await rig.d.prechargeAll();
      await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRp));
      await rig.d.mrs(mrsWord, bank: 1);
      await rig.d.waitEdges(2);

      await Simulator.endSimulation();
      _expectOnly(rig.model, 'mode-register');
    },
  );

  test('state: activating an already-active bank fires once', () async {
    final rig = _setup();
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());

    await _initToReady(rig.d, rig.model.rules);
    await rig.d.activate(0, 5);
    await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRcd));
    await rig.d.activate(0, 6);

    await Simulator.endSimulation();
    _expectOnly(rig.model, 'state');
  });

  test('tRC: re-activating a bank before tRC elapses fires once', () async {
    final rig = _setup();
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());

    await _initToReady(rig.d, rig.model.rules);
    await rig.d.activate(0, 5);
    await rig.d.precharge(0);
    await rig.d.activate(0, 6);

    await Simulator.endSimulation();
    _expectOnly(rig.model, 'tRC');
  });

  test(
    'tRRD: activating another bank before tRRD elapses fires once',
    () async {
      final rig = _setup();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _initToReady(rig.d, rig.model.rules);
      await rig.d.activate(0, 5);
      await rig.d.activate(1, 5);

      await Simulator.endSimulation();
      _expectOnly(rig.model, 'tRRD');
    },
  );

  test('tRCD: reading before tRCD elapses fires once', () async {
    final rig = _setup();
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());

    await _initToReady(rig.d, rig.model.rules);
    await rig.d.activate(0, 5);
    await rig.d.read(0, 0);
    await rig.d.waitEdges(cl + 9);

    await Simulator.endSimulation();
    _expectOnly(rig.model, 'tRCD');
  });

  test('tRAS-min: precharging before tRAS min elapses fires once', () async {
    final rig = _setup();
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());

    await _initToReady(rig.d, rig.model.rules);
    await rig.d.activate(0, 5);
    await rig.d.precharge(0);
    await rig.d.waitEdges(2);

    await Simulator.endSimulation();
    _expectOnly(rig.model, 'tRAS-min');
  });

  test('tRAS-max: a bank left open past tRAS max fires once', () async {
    final rig = _setup(
      rulesOverride: rules.copyWith(powerUpNs: 2000, tRasMax: 100),
    );
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());

    await _initToReady(rig.d, rig.model.rules);
    await rig.d.activate(0, 5);
    await rig.d.waitEdges(20); // 160ns > 100ns tRAS max.

    await Simulator.endSimulation();
    _expectOnly(rig.model, 'tRAS-max');
  });

  test(
    'tRP: activating before tRP since the last precharge elapses fires once',
    () async {
      final rig = _setup();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _initToReady(rig.d, rig.model.rules);
      await rig.d.activate(0, 5);
      await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRasMin));
      await rig.d.precharge(0);
      await rig.d.activate(0, 6);

      await Simulator.endSimulation();
      _expectOnly(rig.model, 'tRP');
    },
  );

  test(
    'tRP: refresh before tRP since the last precharge elapses fires once',
    () async {
      final rig = _setup();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _initToReady(rig.d, rig.model.rules);
      await rig.d.activate(0, 5);
      await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRasMin));
      await rig.d.precharge(0);
      await rig.d.refresh();

      await Simulator.endSimulation();
      _expectOnly(rig.model, 'tRP');
    },
  );

  test(
    'tRP: a mode register set before tRP since the last precharge elapses fires once',
    () async {
      final rig = _setup();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _initToReady(rig.d, rig.model.rules);
      await rig.d.activate(0, 5);
      await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRasMin));
      await rig.d.precharge(0);
      await rig.d.mrs(mrsWord);

      await Simulator.endSimulation();
      _expectOnly(rig.model, 'tRP');
    },
  );

  test('tRFC: a command before tRFC of a refresh elapses fires once', () async {
    final rig = _setup();
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());

    await _initToReady(rig.d, rig.model.rules);
    await rig.d.refresh();
    await rig.d.activate(0, 5);

    await Simulator.endSimulation();
    _expectOnly(rig.model, 'tRFC');
  });

  test(
    'tMRD: a command before tMRD of a mode register set elapses fires once',
    () async {
      final rig = _setup();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _initToReady(rig.d, rig.model.rules);
      await rig.d.mrs(mrsWord);
      await rig.d.refresh();

      await Simulator.endSimulation();
      _expectOnly(rig.model, 'tMRD');
    },
  );

  test('tMRD: the ns branch binds when it exceeds 2 nCK fires once', () async {
    // tMrd=20ns needs 3 cycles at 125 MHz, but tMrdNck=1 only needs 1,
    // so the ns value is the one actually gating this command.
    final rig = _setup(
      rulesOverride: rules.copyWith(powerUpNs: 2000, tMrd: 20, tMrdNck: 1),
    );
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());

    await _initToReady(rig.d, rig.model.rules);
    await rig.d.mrs(mrsWord);
    await rig.d.waitEdges(1);
    await rig.d.refresh();

    await Simulator.endSimulation();
    _expectOnly(rig.model, 'tMRD');
  });

  test(
    'tWR: precharging before tWR since the last write elapses fires once',
    () async {
      final rig = _setup();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _initToReady(rig.d, rig.model.rules);
      await rig.d.activate(0, 5);
      await rig.d.write(0, 0, 0x1234);
      await rig.d.precharge(0);

      await Simulator.endSimulation();
      _expectOnly(rig.model, 'tWR');
    },
  );

  test(
    'refresh-busy: a second refresh before tRFC of the first elapses fires once',
    () async {
      final rig = _setup();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _initToReady(rig.d, rig.model.rules);
      await rig.d.refresh();
      await rig.d.refresh();

      await Simulator.endSimulation();
      _expectOnly(rig.model, 'refresh-busy');
    },
  );

  test(
    'refresh-window: a policy that cannot complete 8192 refreshes in 64ms fires once',
    () async {
      final rig = _setup(
        refreshPolicy: const SdramRefreshPolicy(
          maxPostponed: 8,
          maxPulledIn: 8,
          periodNs: 7800,
          maxLatencyNs: 0,
          initRefreshes: 2,
        ),
      );
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());
      await rig.d.waitEdges(2);

      await Simulator.endSimulation();
      _expectOnly(rig.model, 'refresh-window');
    },
  );

  test(
    'refresh-window: a refresh outside the sliding window fires once',
    () async {
      final rig = _setup(
        refreshPolicy: const SdramRefreshPolicy(
          maxPostponed: 1,
          maxPulledIn: 1,
          periodNs: 7800,
          maxLatencyNs: 0,
          initRefreshes: 2,
        ),
      );
      Simulator.setMaxSimTime(30000000);
      unawaited(Simulator.run());

      // t0 is fixed at the 2nd (init) refresh as soon as it happens, no
      // matter what comes after it, so nothing needs to "freeze" it here.
      await _initToReady(rig.d, rig.model.rules);
      await _delayPs(
        rig.clk,
        16000000,
      ); // past t0 + (1+k)*P: outside the window.
      await rig.d.refresh();

      await Simulator.endSimulation();
      _expectOnly(rig.model, 'refresh-window');
    },
  );

  test(
    'refresh-window: finish() flags a refresh overdue at the end of the run',
    () async {
      final rig = _setup(
        refreshPolicy: const SdramRefreshPolicy(
          maxPostponed: 1,
          maxPulledIn: 1,
          periodNs: 7800,
          maxLatencyNs: 0,
          initRefreshes: 2,
        ),
      );
      Simulator.setMaxSimTime(30000000);
      unawaited(Simulator.run());

      await _initToReady(rig.d, rig.model.rules);
      await rig.d.nop();
      // Past the window, but no refresh is attempted at all: only finish()
      // can catch this one.
      await _delayPs(rig.clk, 16000000);

      rig.model.finish();
      await Simulator.endSimulation();
      _expectOnly(rig.model, 'refresh-window');
    },
  );

  test(
    'dq-contention: the net disagreeing with the model while it drives fires once',
    () async {
      // Net inference specifically, not oe/out: covers the fallback path.
      final rig = _setup(withFpgaSignals: false);
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _initToReady(rig.d, rig.model.rules);
      await rig.d.activate(0, 5);
      await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRcd));
      await rig.d.read(0, 0);
      final readAt = Simulator.time;
      final firstBeatEdge = readAt + cl * periodPs;
      const dPs = 5100;
      // tAC counts from the edge before this beat's own (fig 20, p24).
      final probeAt =
          firstBeatEdge -
          periodPs +
          dPs +
          5000 +
          100; // well inside beat 0's valid window.
      Simulator.registerAction(probeAt, () {
        rig.d.dqDrv.put(0x0000);
        rig.d.dqEn.put(1);
      });
      Simulator.registerAction(probeAt + 1, () {
        rig.d.dqEn.put(0);
      });
      await rig.d.waitEdges(cl + 9);

      await Simulator.endSimulation();
      _expectOnly(rig.model, 'dq-contention');
    },
  );

  test(
    'dq-contention: dq not released when the model starts to drive fires twice',
    () async {
      final rig = _setup();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _initToReady(rig.d, rig.model.rules);
      await rig.d.activate(0, 5);
      await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRcd));
      // The write leaves the fpga driving dq. Issue the read raw, without
      // going through _issue, so dqEn is never cleared the way it would be
      // on the way to any other real command.
      // The read targets the same column the write just set, so the data
      // the read will show matches what the stuck fpga drive already
      // shows. Under oe/out (W3), that still counts: both drivers are
      // really on, so the beat's own value put flags it too, on top of
      // the release check at the chip's own low-z deadline.
      await rig.d.write(0, 0, 0x1234);
      await rig.clk.nextNegedge;
      rig.d.rasN.put(1);
      rig.d.casN.put(0);
      rig.d.weN.put(1);
      rig.d.csN.put(0);
      rig.d.ba.put(0);
      rig.d.addr.put(0);
      rig.d.cke.put(1);
      await rig.clk.nextPosedge;
      // Precharge one edge later, raw too, to cut the burst down to just
      // its first beat so the stuck fpga drive only collides once.
      await rig.clk.nextNegedge;
      rig.d.rasN.put(0);
      rig.d.casN.put(1);
      rig.d.weN.put(0);
      rig.d.csN.put(0);
      rig.d.ba.put(0);
      rig.d.addr.put(0);
      await rig.clk.nextPosedge;
      // Deselect without going through nop(), which would clear dqEn itself
      // and defeat the point of leaving the fpga stuck driving.
      await rig.clk.nextNegedge;
      rig.d.csN.put(1);
      await rig.clk.nextPosedge;
      await _delayPs(rig.clk, 30000);

      await Simulator.endSimulation();
      expect(
        rig.model.errors.where((e) => e.contains(': dq-contention:')).length,
        2,
      );
    },
  );

  test(
    'dq-contention: an unmasked beat before a cutting write fires once',
    () async {
      final rig = _setup();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _initToReady(rig.d, rig.model.rules);
      await rig.d.activate(0, 5);
      await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRcd));
      // dqm only starts 2 edges before the write, not 2 edges before the
      // read's own first beat, so that beat stays unmasked (unlike the
      // legal turnaround data test) and the write's own fpga drive
      // collides with it (fig 7/8, p10).
      await rig.d.read(0, 0);
      await rig.d.waitEdges(1);
      await rig.d._issue(7, dqmBits: 3);
      await rig.d._issue(7, dqmBits: 3);
      await rig.d.write(0, 1, 0xabcd);
      await rig.d.waitEdges(10);

      await Simulator.endSimulation();
      _expectOnly(rig.model, 'dq-contention');
    },
  );

  test(
    'dq-contention: fpga drives before tHZ after a precharge cut fires once',
    () async {
      final rig = _setup();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _initToReady(rig.d, rig.model.rules);
      await rig.d.activate(0, 5);
      await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRcd));
      await rig.d.read(0, 0);
      await rig.d.waitEdges(3);
      await rig.d.precharge(0);
      final lastBeatEdge = Simulator.time + (cl - 1) * periodPs;
      Simulator.registerAction(lastBeatEdge + 4500, () {
        rig.d.dqDrv.put(0x5555);
        rig.d.dqEn.put(1);
      });
      Simulator.registerAction(lastBeatEdge + 5500, () {
        rig.d.dqEn.put(0);
      });
      await rig.d.waitEdges(10);

      await Simulator.endSimulation();
      _expectOnly(rig.model, 'dq-contention');
    },
  );

  test(
    'dqm-before-write: a write cutting a read without dqm high fires once',
    () async {
      final rig = _setup();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _initToReady(rig.d, rig.model.rules);
      await rig.d.activate(0, 5);
      await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRcd));
      await rig.d.read(0, 0);
      await rig.d.waitEdges(1);
      await rig.d.write(0, 1, 0x1234);
      await rig.d.waitEdges(2);

      await Simulator.endSimulation();
      _expectOnly(rig.model, 'dqm-before-write');
    },
  );

  /// The handoff bound is the chip's own tHZ after the read's last beat,
  /// well before this write's edge, so driving write data anywhere in
  /// this window is already fair game for dq-contention. Only tIS, timed
  /// from the write's own edge, can still fire (probe6 a, probe7).
  Future<List<String>> _setupCaseErrors(int leadPs) async {
    await Simulator.reset();
    final rig = _setup();
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());

    await _initToReady(rig.d, rig.model.rules);
    await rig.d.activate(0, 5);
    await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRcd));
    await rig.d.read(0, 0);
    await rig.d.waitEdges(1);
    await rig.d._issue(7, dqmBits: 3);
    await rig.d._issue(7, dqmBits: 3);
    final w = Simulator.time + periodPs;
    Simulator.registerAction(w - leadPs, () {
      rig.d.dqDrv.put(0x1357);
      rig.d.dqEn.put(1);
    });
    await rig.d._issue(4, a: 1, dqmBits: 0);
    await rig.d.waitEdges(8);

    await Simulator.endSimulation();
    return rig.model.errors;
  }

  test(
    'setup: write data changing within tIS of the write edge fires on both lanes',
    () async {
      // 500ps before the write edge, below tIS (1.5ns), and the new data
      // changes both bytes, so both lanes are independently late. Past
      // the chip's own tHZ already, so no dq-contention on top.
      final errors = await _setupCaseErrors(500);
      expect(errors.where((e) => e.contains(': setup:')).length, 2);
      expect(errors.where((e) => e.contains(': dq-contention:')).length, 0);
    },
  );

  test(
    'setup: write data changing well before tIS of the write edge gives zero errors',
    () async {
      // 2500ps before the write edge, clear of tIS (1.5ns) and, same as
      // the 500ps case, already past the chip's own tHZ: fully legal.
      final errors = await _setupCaseErrors(2500);
      expect(errors, isEmpty, reason: errors.join('\n'));
    },
  );

  /// probe8: the same write-cuts-a-read shape as above, but the lead lands
  /// inside the last beat's own x-again phase (tOH to tHZ), where the net
  /// already reads x and an incoming concrete value merges straight back
  /// to x, so no glitch fires until the write's forced release reveals it.
  /// That reveal must still carry the real tIS violation, not read as a
  /// brand new, on-time change.
  Future<List<String>> _probe8Errors(
    int leadPs, {
    bool withFpgaSignals = true,
  }) async {
    await Simulator.reset();
    final rig = _setup(withFpgaSignals: withFpgaSignals);
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());

    await _initToReady(rig.d, rig.model.rules);
    await rig.d.activate(0, 5);
    await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRcd));
    await rig.d.read(0, 0);
    await rig.d.waitEdges(1);
    await rig.d._issue(7, dqmBits: 3);
    await rig.d.waitEdges(1);
    final w = Simulator.time + periodPs;
    Simulator.registerAction(w - leadPs, () {
      rig.d.dqDrv.put(0x1357);
      rig.d.dqEn.put(1);
    });
    await rig.d._issue(4, a: 1, dqmBits: 0);
    await rig.d.waitEdges(8);

    await Simulator.endSimulation();
    return rig.model.errors;
  }

  test(
    'setup: write data hidden in the x phase still fires once revealed',
    () async {
      // Net inference specifically, not oe/out: covers the fallback path,
      // and this is exactly the conservative backdating it documents.
      // 300ps before the write edge, inside the x-again phase: invisible
      // until the forced release reveals it right on the write's edge.
      final errors = await _probe8Errors(300, withFpgaSignals: false);
      expect(errors.where((e) => e.contains(': setup:')).length, 2);
    },
  );

  test(
    'setup: write data visible before the x phase fires at its own time',
    () async {
      // 1000ps before the write edge, still inside tIS but before the
      // x-again phase starts: visible on its own, not via the release.
      final errors = await _probe8Errors(1000);
      expect(errors.where((e) => e.contains(': setup:')).length, 2);
    },
  );

  /// probe9: the fpga starts driving inside a model x phase and keeps
  /// driving into the next value phase, where this model's own valid put
  /// now checks the net against what it just drove (Y1).
  Future<List<String>> _probe9Errors(int offPs, int lenPs) async {
    final rig = _setup();
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());
    await _initToReady(rig.d, rig.model.rules);
    await rig.d.activate(0, 5);
    await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRcd));
    await rig.d.read(0, 0);
    final edge = Simulator.time + 3 * periodPs;
    Simulator.registerAction(edge + offPs, () {
      rig.d.dqDrv.put(0x5555);
      rig.d.dqEn.put(1);
    });
    Simulator.registerAction(edge + offPs + lenPs, () {
      rig.d.dqEn.put(0);
    });
    await rig.d.waitEdges(14);
    await Simulator.endSimulation();
    return rig.model.errors;
  }

  test(
    'dq-contention: fpga drives from the first beat lead-in x into its value fires twice',
    () async {
      // E-2.0ns to E+8.0ns: starts in the lead-in x, caught directly on
      // oe asserting there, and again when this beat's own value put
      // still finds it on.
      final errors = await _probe9Errors(-2000, 10000);
      expect(errors.where((e) => e.contains(': dq-contention:')).length, 2);
    },
  );

  test(
    'dq-contention: fpga drives from mid-burst x into the next value fires twice',
    () async {
      // E+8.0ns to E+13.0ns: starts after this beat's own x-again, caught
      // directly on oe asserting there, and again when the next,
      // continuing beat's own value put still finds it on.
      final errors = await _probe9Errors(8000, 5000);
      expect(errors.where((e) => e.contains(': dq-contention:')).length, 2);
    },
  );

  test(
    'dq-contention: fpga drives from mid-burst value through the next beat fires twice',
    () async {
      // E+6.0ns to E+11.0ns: visible immediately against this beat's own
      // value, then still driving when the next beat's value put runs.
      final errors = await _probe9Errors(6000, 5000);
      expect(errors.where((e) => e.contains(': dq-contention:')).length, 2);
    },
  );

  /// probe11/probe12: a dedicated CL2, 100 MHz rig, since _setup/_initToReady
  /// are fixed to the file's own CL3, 125 MHz constants.
  _Rig _setupCl2() {
    const cl2PeriodPs = 10000;
    final clkDriver = _ClkDriver(cl2PeriodPs);
    final d = _Driver(clkDriver.clk);
    final model = SdramPinModel(
      clk: clkDriver.clk,
      cke: d.cke,
      csN: d.csN,
      rasN: d.rasN,
      casN: d.casN,
      weN: d.weN,
      ba: d.ba,
      addr: d.addr,
      dqm: d.dqm,
      dq: d.dq,
      rules: rules.copyWith(powerUpNs: 2000),
      fpgaDqOe: d.dqEn,
      fpgaDqOut: d.dqDrv,
    );
    return _Rig(clkDriver, d, model);
  }

  Future<void> _initToReadyCl2(_Rig rig) async {
    const cl2PeriodPs = 10000;
    int ceil(double ns) => (ns * 1000 / cl2PeriodPs).ceil();
    final cycles = ceil(rig.model.rules.powerUpNs) + 2;
    for (var i = 0; i < cycles; i++) {
      await rig.d.nop(cke: 0);
    }
    await rig.d.nop(cke: 1);
    await rig.d.prechargeAll();
    await rig.d.waitEdges(ceil(rig.model.rules.tRp));
    await rig.d.mrs(0x223); // CL2, BL8 (table 9 p15, table 6 p14).
    final mrd = ceil(rig.model.rules.tMrd);
    await rig.d.waitEdges(
      mrd > rig.model.rules.tMrdNck ? mrd : rig.model.rules.tMrdNck,
    );
    await rig.d.refresh();
    await rig.d.waitEdges(ceil(rig.model.rules.tRfc));
    await rig.d.refresh();
    await rig.d.waitEdges(ceil(rig.model.rules.tRfc));
  }

  test(
    'legal traffic: write data matching the last read beat on one lane gives zero errors',
    () async {
      // probe12 (Z1): the write's high byte (0x00) happens to equal both
      // the read's own last-beat value there and the fpga's own idle
      // value, so that lane never really changes. Net inference could
      // not tell "always 0" apart from "revealed now" and flagged it,
      // fixed by X1/oe-out. This must stay clean.
      final rig = _setupCl2();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _initToReadyCl2(rig);
      await rig.d.activate(0, 5);
      await rig.d.waitEdges(2); // tRCD at CL2, 100 MHz.
      await rig.d.read(0, 0); // T2, CL2 beats at T4, T5, ...
      await rig.d._issue(7, dqmBits: 3); // T3
      await rig.d._issue(7, dqmBits: 3); // T4: last unmasked beat.
      final t4 = Simulator.time;
      Simulator.registerAction(t4 + 5000, () {
        rig.d.dqDrv.put(0x0057);
        rig.d.dqEn.put(1);
      });
      // Raw, not _issue: _issue's own no-data branch would put dqEn back
      // to 0 on this same negedge, racing the fpga drive above.
      await rig.clk.nextNegedge;
      rig.d.rasN.put(1);
      rig.d.casN.put(0);
      rig.d.weN.put(0);
      rig.d.csN.put(0);
      rig.d.addr.put(1);
      rig.d.dqm.put(0);
      await rig.clk.nextPosedge; // T5: cuts the read.
      await rig.d.waitEdges(8);

      await Simulator.endSimulation();
      expect(rig.model.errors, isEmpty, reason: rig.model.errors.join('\n'));
      expect(rig.model.peek(0, 5, 1), 0x0057);
    },
  );

  test(
    'dq-contention: write data changes again while still hidden still fires once',
    () async {
      // probe11 (Z2): A lands with a clean 1.7ns margin, legal on its
      // own, but B replaces it 0.3ns before the write edge, hidden the
      // whole way through by the model's own x. oe/out catch B's own,
      // real change directly, no backdating guesswork needed.
      final rig = _setup();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _initToReady(rig.d, rig.model.rules);
      await rig.d.activate(0, 5);
      await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRcd));
      await rig.d.read(0, 0);
      await rig.d.waitEdges(1);
      await rig.d._issue(7, dqmBits: 3);
      await rig.d._issue(7, dqmBits: 3);
      final w = Simulator.time + periodPs;
      const a = 0x28 ^ 0x00f0;
      Simulator.registerAction(w - 2000, () {
        rig.d.dqDrv.put(a);
        rig.d.dqEn.put(1);
      });
      Simulator.registerAction(w - 300, () {
        rig.d.dqDrv.put(a ^ 0x0030);
      });
      await rig.d._issue(4, a: 1, dqmBits: 0);
      await rig.d.waitEdges(8);

      await Simulator.endSimulation();
      expect(rig.model.errors.where((e) => e.contains(': setup:')).length, 1);
    },
  );

  test(
    'setup: write data preset while oe is low still fires once oe rises',
    () async {
      // probe13 c (W1): out was already sitting at this value while oe
      // was still low, so only the oe edge itself, 0.3ns before an
      // otherwise isolated write, reveals it on the net. Without W1,
      // nothing records either lane's change time at all.
      final rig = _setup();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _initToReady(rig.d, rig.model.rules);
      await rig.d.activate(0, 5);
      await rig.d.waitEdges(4); // tRCD, clear of any other dq activity.
      rig.d.dqDrv.put(0x1357);
      final w = Simulator.time + periodPs;
      Simulator.registerAction(w - 300, () => rig.d.dqEn.put(1));
      await rig.clk.nextNegedge;
      rig.d.rasN.put(1);
      rig.d.casN.put(0);
      rig.d.weN.put(0);
      rig.d.csN.put(0);
      rig.d.addr.put(1);
      rig.d.dqm.put(0);
      await rig.clk.nextPosedge;
      rig.d.csN.put(1);
      Simulator.registerAction(Simulator.time + 4000, () => rig.d.dqEn.put(0));
      await rig.clk.nextPosedge;
      await rig.clk.nextPosedge;

      await Simulator.endSimulation();
      expect(rig.model.errors.where((e) => e.contains(': setup:')).length, 2);
    },
  );

  test('hold: oe dropping shortly after the write edge fires once', () async {
    // probe13 d (W1): the write data itself is stable with a 4ns margin,
    // but oe drops again 0.3ns after the edge on the way out, which only
    // an oe-edge-triggered check can see since out itself never changes.
    final rig = _setup();
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());

    await _initToReady(rig.d, rig.model.rules);
    await rig.d.activate(0, 5);
    await rig.d.waitEdges(4);
    final w = Simulator.time + periodPs;
    Simulator.registerAction(w - 4000, () {
      rig.d.dqDrv.put(0x1357);
      rig.d.dqEn.put(1);
    });
    Simulator.registerAction(w + 300, () => rig.d.dqEn.put(0));
    await rig.clk.nextNegedge;
    rig.d.rasN.put(1);
    rig.d.casN.put(0);
    rig.d.weN.put(0);
    rig.d.csN.put(0);
    rig.d.addr.put(1);
    rig.d.dqm.put(0);
    await rig.clk.nextPosedge;
    rig.d.csN.put(1);
    await rig.clk.nextPosedge;
    await rig.clk.nextPosedge;

    await Simulator.endSimulation();
    expect(rig.model.errors.where((e) => e.contains(': hold:')).length, 2);
  });

  test(
    'dq-contention: oe still on past the chip low-z deadline for a fresh beat fires once',
    () async {
      // probe13 f (W2): oe has been on since well before this read even
      // started and only lets go 3ns after the chip's own low-z deadline
      // for this, the first beat after a quiet bus. startDrive's own
      // check runs later, in fpga time, by which point oe has already
      // gone again, so only the chip-time check at previousEdge + tLZ
      // catches it.
      final rig = _setup();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _initToReady(rig.d, rig.model.rules);
      await rig.d.activate(0, 5);
      await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRcd));
      await rig.d.read(0, 0);
      final e = Simulator.time;
      final firstBeat = e + cl * periodPs;
      Simulator.registerAction(e + 1000, () {
        rig.d.dqDrv.put(0x1111);
        rig.d.dqEn.put(1);
      });
      Simulator.registerAction(
        firstBeat - periodPs + 3000,
        () => rig.d.dqEn.put(0),
      );
      rig.d.csN.put(1); // deselect raw: no further command this run.
      for (var i = 0; i < 12; i++) {
        await rig.clk.nextPosedge;
      }

      await Simulator.endSimulation();
      expect(
        rig.model.errors.where((e) => e.contains(': dq-contention:')).length,
        1,
      );
    },
  );

  test(
    'dq-contention: a short oe pulse before this model ever drives fires once',
    () async {
      // probe14 g: nothing has driven dq at all yet this run, so
      // _lastDrivenBeatEdgePs is still its initial, unset value. The
      // pulse (1.0ns to 4.0ns after this beat's own previousEdge) ends
      // well before the model's own lead-in at previousEdge + d + tLZ
      // (5.1ns), so only treating the beat's own, already-decided
      // [previousEdge + tLZ, edge + tHZ) window as the chip's driving
      // interval catches it.
      final rig = _setup();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _initToReady(rig.d, rig.model.rules);
      await rig.d.activate(0, 5);
      await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRcd));
      await rig.d.read(0, 0);
      final e = Simulator.time;
      final lowZ = e + (cl - 1) * periodPs; // first beat's previousEdge.
      Simulator.registerAction(lowZ + 1000, () {
        rig.d.dqDrv.put(0x1111);
        rig.d.dqEn.put(1);
      });
      Simulator.registerAction(lowZ + 4000, () => rig.d.dqEn.put(0));
      rig.d.csN.put(1); // deselect raw: no further command this run.
      for (var i = 0; i < 12; i++) {
        await rig.clk.nextPosedge;
      }

      await Simulator.endSimulation();
      expect(
        rig.model.errors
            .where((err) => err.contains(': dq-contention:'))
            .length,
        1,
      );
    },
  );

  test(
    'dq-contention: an oe overlap with a matching value still fires before handoff',
    () async {
      // probe13 e (W3): oe pulses on during the last surviving beat's own
      // valid-data phase with a value that happens to equal it exactly.
      // oe mode knows both drivers are really on, so agreeing values are
      // no exemption: still contention.
      final rig = _setup();
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _initToReady(rig.d, rig.model.rules);
      await rig.d.activate(0, 5);
      await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRcd));
      await rig.d.read(0, 0);
      await rig.d.waitEdges(3);
      await rig.d.precharge(0);
      final lastBeatEdge = Simulator.time + (cl - 1) * periodPs;
      final value = rig.model.peek(0, 5, 3);
      Simulator.registerAction(lastBeatEdge + 3000, () {
        rig.d.dqDrv.put(value);
        rig.d.dqEn.put(1);
      });
      Simulator.registerAction(lastBeatEdge + 3500, () => rig.d.dqEn.put(0));
      await rig.d.waitEdges(10);

      await Simulator.endSimulation();
      expect(
        rig.model.errors.where((e) => e.contains(': dq-contention:')).length,
        1,
      );
    },
  );

  test('dq-contention: a short fpga pulse mid-burst fires once', () async {
    final rig = _setup();
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());

    await _initToReady(rig.d, rig.model.rules);
    await rig.d.activate(0, 5);
    await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRcd));
    await rig.d.read(0, 0);
    // One beat into the burst, well before this beat's own tHZ release,
    // but the model is briefly showing x between tOH and the next beat's
    // own drive: a later surviving beat is still due, so this must not
    // read as already past handoff (fig 20, p24).
    final edge = Simulator.time + 4 * periodPs;
    Simulator.registerAction(edge + 6000, () {
      rig.d.dqDrv.put(0x5555);
      rig.d.dqEn.put(1);
    });
    Simulator.registerAction(edge + 6500, () {
      rig.d.dqEn.put(0);
    });
    await rig.d.waitEdges(14);

    await Simulator.endSimulation();
    _expectOnly(rig.model, 'dq-contention');
  });

  test(
    'refresh-window: every refresh after t0 that is too slow fires, not just the first',
    () async {
      // A tiny policy period (3 clk cycles) so each 9-cycle-late refresh
      // below only costs a handful of edges, not thousands.
      final rig = _setup(
        refreshPolicy: const SdramRefreshPolicy(
          maxPostponed: 1,
          maxPulledIn: 1,
          periodNs: 24,
          maxLatencyNs: 0,
          initRefreshes: 2,
        ),
      );
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await _initToReady(rig.d, rig.model.rules);
      // Every refresh here lands 3 policy-periods after the one before it,
      // outside even the k=1 postpone credit (3n > n+1 for every n >= 1),
      // so each one in turn must be flagged, not just the first (a sliding
      // t0 would have let later ones catch up and go quiet).
      for (var j = 0; j < 4; j++) {
        await rig.d.waitEdges(8);
        await rig.d.refresh();
      }

      await Simulator.endSimulation();
      final matches = rig.model.errors
          .where((e) => e.contains(': refresh-window:'))
          .toList();
      expect(
        matches.length,
        4,
        reason:
            'wanted one refresh-window error per late refresh, got:\n'
            '${rig.model.errors.join('\n')}',
      );
    },
  );

  test('unsupported: A10 on a read fires once', () async {
    final rig = _setup();
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());

    await _initToReady(rig.d, rig.model.rules);
    await rig.d.activate(0, 5);
    await rig.d.waitEdges(_ceilCycles(rig.model.rules.tRcd));
    await rig.d.read(0, 0, a10: true);
    await rig.d.waitEdges(cl + 9);

    await Simulator.endSimulation();
    _expectOnly(rig.model, 'unsupported');
  });
}
