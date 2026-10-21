import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../support/gtpe2_status_model.dart';

typedef _S = HarborGtpResetState;

const _timeouts = HarborGtpPcieTimeouts(
  pllLock: 100,
  resetDone: 100,
  pmaResetDone: 50,
  mmcmLock: 100,
  txSync: 40,
  rate: 60,
);

const _porFlops = {'por_lock_0', 'por_lock_1', 'por_count'};

const _goodOrder = [
  _S.cfgWait,
  _S.pllReset,
  _S.pllLock,
  _S.gtReset,
  _S.pmaHigh,
  _S.mmcmLock,
  _S.resetDone,
  _S.txDlySReset,
  _S.txPhInit,
  _S.txPhAlign,
  _S.txDlyEn,
  _S.idle,
];

class _Bench {
  final HarborGtpPciePhy phy;
  final Gtpe2StatusModel model;
  final List<HarborPciePipeLane> pipes;
  final HarborGtpCommonPorts common;
  final List<HarborGtpChannelPorts> channels;
  final Logic perstN;
  final Logic pclk;

  /// The state after each change, from the start.
  final List<_S> trace = [];

  /// Cycle numbers of events on the GT controls, by name.
  final Map<String, List<int>> events = {};

  /// Cycles with PIPE PHYSTATUS high on lane 0, after the first idle.
  int phyStatusHighAfterIdle = 0;

  int cycle = 0;
  bool _stop = false;

  _Bench(
    this.phy,
    this.model,
    this.pipes,
    this.common,
    this.channels,
    this.perstN,
    this.pclk,
  );

  _S get state => _S.fromCode(phy.resetState.value.toInt());
  _S get failState => _S.fromCode(phy.resetFailState.value.toInt());
  int get retries => phy.resetRetries.value.toInt();
  bool hi(Logic l) => l.value.isValid && l.value.toBool();

  static Future<_Bench> start({
    int lanes = 1,
    bool drivePllReset = false,
    bool waitRxPmaResetDone = true,
    bool waitForRxResetStatus = true,
    bool perstEdge = true,
    void Function(Gtpe2StatusModel m)? setup,
  }) async {
    final pclk = SimpleClockGenerator(8).clk;
    // A valid PERST# before build keeps the async reset of the power-on
    // reset flops away from an X edge at time 0.
    final perstN = Logic(name: 'perst_n')..put(perstEdge ? 0 : 1);
    final common = HarborGtpCommonPorts();
    final channels = [for (var i = 0; i < lanes; i++) HarborGtpChannelPorts()];
    final pipes = [for (var i = 0; i < lanes; i++) HarborPciePipeLane()];
    final model = Gtpe2StatusModel(pclk, common, channels);
    setup?.call(model);
    final phy = HarborGtpPciePhy(
      perstN: perstN,
      common: common,
      channels: channels,
      pipes: pipes,
      lanes: lanes,
      clocks: HarborPipeClocks(
        pclk: pclk,
        userClk1: pclk,
        userClk2: pclk,
        mmcmLock: model.mmcmLock,
      ),
      timeouts: _timeouts,
      drivePllReset: drivePllReset,
      waitRxPmaResetDone: waitRxPmaResetDone,
      waitForRxResetStatus: waitForRxResetStatus,
    );
    await phy.build();
    for (final p in pipes) {
      p.txData.inject(0);
      p.txDataK.inject(0);
      p.txDetectRx.inject(0);
      p.txElecIdle.inject(1);
      p.txCompliance.inject(0);
      p.rxPolarity.inject(0);
      p.powerDown.inject(0);
      p.pipeRate.inject(0);
      p.txMargin.inject(0);
      p.txSwing.inject(0);
      p.txDeemph.inject(0);
    }
    // FPGA flops start at zero after configuration.
    for (final l in phy.internalSignals) {
      if (_porFlops.contains(l.name)) l.inject(0);
    }
    final b = _Bench(phy, model, pipes, common, channels, perstN, pclk);
    Simulator.setMaxSimTime(10000000);
    unawaited(Simulator.run());
    await pclk.nextPosedge;
    model.start();
    unawaited(b._monitor());
    for (var i = 0; i < 4; i++) {
      await pclk.nextPosedge;
    }
    if (perstEdge) perstN.inject(1);
    return b;
  }

  Future<void> _monitor() async {
    final ch0 = channels[0];
    final watch = {
      'gt_reset': ch0.port('GTTXRESET'),
      'pll_reset': common.port('PLL0RESET'),
      'pll_lock': common.port('PLL0LOCK'),
      'user_rdy': ch0.port('TXUSERRDY'),
      'mmcm_lock': model.mmcmLock,
    };
    final last = <String, bool>{};
    var seenIdle = false;
    while (!_stop) {
      await pclk.nextNegedge;
      cycle++;
      if (!phy.resetState.value.isValid) continue;
      final s = state;
      if (trace.isEmpty || trace.last != s) trace.add(s);
      for (final e in watch.entries) {
        final v = hi(e.value);
        if (last[e.key] != v) {
          events
              .putIfAbsent('${e.key}_${v ? 'rise' : 'fall'}', () => [])
              .add(cycle);
          last[e.key] = v;
        }
      }
      if (s == _S.idle) seenIdle = true;
      if (seenIdle && hi(pipes[0].phyStatus)) phyStatusHighAfterIdle++;
    }
  }

  Future<void> cycles(int n) async {
    for (var i = 0; i < n; i++) {
      await pclk.nextNegedge;
    }
  }

  Future<void> waitFor(_S s, {int limit = 2000}) async {
    for (var i = 0; i < limit; i++) {
      await pclk.nextNegedge;
      if (phy.resetState.value.isValid && state == s) return;
    }
    fail('state $s not reached in $limit cycles, now $state, trace $trace');
  }

  /// The trace from the last time it entered [from].
  List<_S> traceFrom(_S from) => trace.sublist(trace.lastIndexOf(from));

  int first(String event) => events[event]?.first ?? -1;

  int last(String event) => events[event]?.last ?? -1;

  Future<void> finish() async {
    _stop = true;
    model.stop();
    await Simulator.endSimulation();
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborGtpPciePhy sequence', () {
    test('good start goes through each state in order', () async {
      final b = await _Bench.start(drivePllReset: true);
      await b.waitFor(_S.idle);
      expect(b.trace, _goodOrder);
      expect(b.retries, 0);
      expect(b.failState, _S.none);
      expect(b.hi(b.phy.phyReady), isTrue);

      // GT reset and PLL reset first, then PLL lock, then GT reset low,
      // then USERRDY after the MMCM lock.
      expect(b.first('gt_reset_rise'), greaterThan(0));
      expect(b.first('pll_reset_rise'), b.first('gt_reset_rise'));
      expect(b.first('pll_reset_fall'), lessThan(b.first('pll_lock_rise')));
      expect(b.last('pll_lock_rise'), lessThan(b.last('gt_reset_fall')));
      expect(b.last('gt_reset_fall'), lessThan(b.first('user_rdy_rise')));
      expect(b.first('mmcm_lock_rise'), lessThan(b.first('user_rdy_rise')));

      final ch = b.channels[0];
      expect(b.hi(ch.port('TXDLYEN')), isTrue);
      expect(b.hi(ch.port('TXPHALIGN')), isFalse);
      expect(b.hi(ch.port('GTRXRESET')), isFalse);
      expect(b.hi(ch.port('RXUSERRDY')), isTrue);
      expect(b.common.port('PLL0REFCLKSEL').value.toInt(), 2);
      expect(b.model.txSyncRuns, 1);
      await b.finish();
    });

    test('PLL0RESET stays low without drivePllReset', () async {
      final b = await _Bench.start();
      await b.waitFor(_S.idle);
      expect(b.trace, _goodOrder);
      expect(b.events['pll_reset_rise'], isNull);
      await b.finish();
    });

    test('four lanes reach idle', () async {
      final b = await _Bench.start(lanes: 4);
      await b.waitFor(_S.idle);
      expect(b.trace, _goodOrder);
      for (final ch in b.channels) {
        expect(b.hi(ch.port('TXUSERRDY')), isTrue);
        expect(b.hi(ch.port('TXDLYEN')), isTrue);
      }
      await b.finish();
    });

    test(
      'stuck PLL never reaches idle, retries, and shows its state',
      () async {
        final b = await _Bench.start(setup: (m) => m.pllStuck = true);
        await b.cycles(1500);
        expect(b.trace, isNot(contains(_S.idle)));
        expect(b.state, anyOf(_S.pllReset, _S.pllLock));
        expect(b.failState, _S.pllLock);
        expect(b.retries, greaterThanOrEqualTo(10));
        expect(b.hi(b.channels[0].port('GTTXRESET')), isTrue);
        expect(b.hi(b.phy.phyReady), isFalse);
        expect(b.hi(b.pipes[0].phyStatus), isTrue);

        b.model.pllStuck = false;
        await b.waitFor(_S.idle);
        expect(b.traceFrom(_S.pllReset), _goodOrder.sublist(1));
        await b.finish();
      },
    );

    test('a short RXPMARESETDONE pulse right at GT reset release', () async {
      final b = await _Bench.start(
        setup: (m) => m
          ..pmaRiseDelay = 0
          ..pmaHighCycles = 2,
      );
      await b.waitFor(_S.idle);
      expect(b.trace, _goodOrder);
      expect(b.model.pmaPulses, greaterThanOrEqualTo(1));
      expect(b.retries, 0);
      await b.finish();
    });

    test('RXPMARESETDONE stays high after reset completes', () async {
      final b = await _Bench.start(setup: (m) => m.pmaHighCycles = null);
      await b.waitFor(_S.idle);
      expect(b.retries, 0);
      await b.finish();
    });

    test('waitRxPmaResetDone false skips the RXPMARESETDONE waits', () async {
      final b = await _Bench.start(
        waitRxPmaResetDone: false,
        setup: (m) => m.pmaHighCycles = null,
      );
      await b.waitFor(_S.idle);
      expect(b.trace, _goodOrder.where((s) => s != _S.pmaHigh));
      await b.finish();
    });

    test('RX reset status can be skipped for openXC7', () async {
      final b = await _Bench.start(
        waitForRxResetStatus: false,
        setup: (m) => m
          ..rxResetDoneOn = false
          ..startupPhyStatusStuck = true,
      );
      await b.waitFor(_S.idle);
      expect(b.trace, _goodOrder);
      expect(b.retries, 0);
      expect(b.hi(b.channels[0].port('TXRESETDONE')), isTrue);
      expect(b.hi(b.channels[0].port('RXRESETDONE')), isFalse);
      expect(b.hi(b.channels[0].port('PHYSTATUS')), isTrue);
      await b.finish();
    });

    test('TX sync timeout retries', () async {
      final b = await _Bench.start(setup: (m) => m.phAlignStuck = true);
      await b.cycles(1500);
      expect(b.trace, isNot(contains(_S.idle)));
      expect(b.failState, _S.txPhAlign);
      expect(b.retries, greaterThan(0));
      b.model.phAlignStuck = false;
      await b.waitFor(_S.idle);
      await b.finish();
    });

    test('PERST# high from power-up with no edge reaches idle', () async {
      final b = await _Bench.start(perstEdge: false);
      await b.waitFor(_S.idle);
      expect(b.trace, _goodOrder);
      expect(b.retries, 0);
      expect(b.hi(b.phy.phyReady), isTrue);
      b.perstN.inject(0);
      await b.cycles(4);
      expect(b.state, _S.cfgWait);
      expect(b.hi(b.phy.phyReady), isFalse);
      b.perstN.inject(1);
      await b.waitFor(_S.idle);
      expect(b.traceFrom(_S.cfgWait), _goodOrder);
      await b.finish();
    });

    test('power-on reset holds until the MMCM locks', () async {
      final b = await _Bench.start(
        perstEdge: false,
        setup: (m) => m.mmcmLockDelay = 300,
      );
      await b.cycles(290);
      expect(b.state, _S.cfgWait);
      expect(b.first('gt_reset_rise'), -1);
      await b.waitFor(_S.idle);
      expect(b.first('mmcm_lock_rise'), lessThan(b.first('gt_reset_rise')));
      await b.finish();
    });

    test('PERST# holds reset until the MMCM locks again', () async {
      final b = await _Bench.start();
      await b.waitFor(_S.idle);
      // PERST# resets the MMCM, so the lock goes away and comes back later.
      b.perstN.inject(0);
      b.model.dropMmcmLock(120);
      final low = b.cycle;
      await b.cycles(20);
      b.perstN.inject(1);
      await b.waitFor(_S.idle, limit: 3000);
      final lockBack = b.events['mmcm_lock_rise']!.last;
      final gtReset = b.events['gt_reset_rise']!.firstWhere((c) => c > low);
      expect(lockBack, greaterThan(low + 100));
      expect(gtReset, greaterThan(lockBack + 64));
      expect(b.traceFrom(_S.cfgWait), _goodOrder);
      expect(b.retries, 0);
      await b.finish();
    });

    test('PERST# mid sequence restarts from the top', () async {
      final b = await _Bench.start();
      await b.waitFor(_S.txPhInit);
      b.perstN.inject(0);
      await b.cycles(1);
      expect(b.state, _S.cfgWait);
      await b.cycles(3);
      final ch = b.channels[0];
      expect(b.hi(ch.port('GTTXRESET')), isFalse);
      expect(b.hi(ch.port('TXUSERRDY')), isFalse);
      expect(b.hi(ch.port('TXPHINIT')), isFalse);
      expect(b.hi(b.pipes[0].phyStatus), isTrue);
      await b.cycles(20);
      expect(b.state, _S.cfgWait);
      b.perstN.inject(1);
      await b.waitFor(_S.idle);
      expect(b.traceFrom(_S.cfgWait), _goodOrder);
      expect(b.retries, 0);
      await b.finish();
    });

    test('lost PLL lock in idle restarts the sequence', () async {
      final b = await _Bench.start();
      await b.waitFor(_S.idle);
      b.model.dropPllLock(30);
      await b.waitFor(_S.pllReset, limit: 20);
      expect(b.failState, _S.idle);
      expect(b.retries, 1);
      await b.waitFor(_S.idle);
      expect(b.traceFrom(_S.pllReset), _goodOrder.sublist(1));
      await b.finish();
    });

    test('lost MMCM lock in idle restarts the sequence', () async {
      final b = await _Bench.start();
      await b.waitFor(_S.idle);
      b.model.dropMmcmLock(20);
      await b.waitFor(_S.pllReset, limit: 20);
      expect(b.failState, _S.idle);
      await b.waitFor(_S.idle);
      expect(b.retries, 1);
      await b.finish();
    });

    test('every wait has a bound', () async {
      // Each fault holds one wait. The sequence must leave that wait and
      // count a retry.
      final faults = <String, void Function(Gtpe2StatusModel m)>{
        'pll lock': (m) => m.pllStuck = true,
        'reset done': (m) => m.resetDoneDelay = 1 << 30,
        'pma high': (m) => m.pmaRiseDelay = 1 << 30,
        'tx sync': (m) => m.syncDelay = 1 << 30,
      };
      for (final f in faults.entries) {
        final b = await _Bench.start(setup: f.value);
        await b.cycles(800);
        expect(b.retries, greaterThan(0), reason: f.key);
        expect(b.trace, isNot(contains(_S.idle)), reason: f.key);
        await b.finish();
        await Simulator.reset();
      }

      // The power-on reset waits for the first MMCM lock, so the lock goes
      // away after the sequence starts.
      final b = await _Bench.start();
      await b.waitFor(_S.gtReset);
      b.model.dropMmcmLock(1 << 30);
      await b.cycles(800);
      expect(b.retries, greaterThan(0), reason: 'mmcm lock');
      expect(b.trace, isNot(contains(_S.idle)), reason: 'mmcm lock');
      await b.finish();
    });
  });

  group('HarborGtpPciePhy PIPE shaping', () {
    test('a rate change reruns TX sync and gives one PHYSTATUS', () async {
      final b = await _Bench.start();
      await b.waitFor(_S.idle);
      await b.cycles(10);
      final before = b.phyStatusHighAfterIdle;
      final traceLen = b.trace.length;
      b.pipes[0].pipeRate.inject(1);
      await b.cycles(3);
      expect(b.channels[0].port('TXRATE').value.toInt(), 1);
      expect(b.channels[0].port('RXRATE').value.toInt(), 1);
      await b.waitFor(_S.txDlySReset, limit: 100);
      await b.waitFor(_S.idle, limit: 300);
      await b.cycles(10);
      expect(b.trace.sublist(traceLen - 1), [
        _S.idle,
        _S.txDlySReset,
        _S.txPhInit,
        _S.txPhAlign,
        _S.txDlyEn,
        _S.idle,
      ]);
      expect(b.model.txSyncRuns, 2);
      expect(b.phyStatusHighAfterIdle - before, 1);
      expect(b.hi(b.phy.phyReady), isTrue);
      expect(b.retries, 0);
      await b.finish();
    });

    test('a rate change with no answer restarts the sequence', () async {
      final b = await _Bench.start(setup: (m) => m.rateStuck = true);
      await b.waitFor(_S.idle);
      b.pipes[0].pipeRate.inject(1);
      await b.waitFor(_S.pllReset, limit: 200);
      expect(b.failState, _S.rateChange);
      expect(b.retries, 1);
      await b.finish();
    });

    test('RXVALID passes only in idle after 16 clean cycles', () async {
      final b = await _Bench.start();
      final pipe = b.pipes[0];
      final gtValid = b.channels[0].port('RXVALID');
      // GT RXVALID is high from reset done, before idle.
      await b.waitFor(_S.txDlySReset);
      expect(b.hi(gtValid), isTrue);
      expect(b.hi(pipe.rxValid), isFalse);
      await b.waitFor(_S.idle);
      await b.cycles(2);
      expect(b.hi(pipe.rxValid), isTrue);

      b.model.rxValidOn = false;
      await b.cycles(2);
      expect(b.hi(gtValid), isFalse);
      expect(b.hi(pipe.rxValid), isFalse);
      b.model.rxValidOn = true;
      var n = 0;
      while (!b.hi(pipe.rxValid)) {
        await b.cycles(1);
        n++;
        expect(n, lessThan(40));
      }
      expect(n, inInclusiveRange(15, 19));

      // A one cycle drop starts the count again.
      b.model.rxValidOn = false;
      await b.cycles(2);
      b.model.rxValidOn = true;
      await b.cycles(8);
      expect(b.hi(pipe.rxValid), isFalse);
      await b.cycles(12);
      expect(b.hi(pipe.rxValid), isTrue);
      await b.finish();
    });

    test('PHYSTATUS is high until idle, then follows power changes', () async {
      final b = await _Bench.start();
      final pipe = b.pipes[0];
      // The GT drops PHYSTATUS at reset done, the PIPE side stays high.
      await b.waitFor(_S.txPhInit);
      expect(b.hi(b.channels[0].port('PHYSTATUS')), isFalse);
      expect(b.hi(pipe.phyStatus), isTrue);
      await b.waitFor(_S.idle);
      await b.cycles(2);
      expect(b.hi(pipe.phyStatus), isFalse);
      final before = b.phyStatusHighAfterIdle;
      pipe.powerDown.inject(2);
      await b.cycles(20);
      expect(b.phyStatusHighAfterIdle - before, 1);
      expect(b.channels[0].port('TXPD').value.toInt(), 2);
      expect(b.channels[0].port('RXPD').value.toInt(), 2);
      await b.finish();
    });

    test('TX and RX data map to the low half of the GT data', () async {
      final b = await _Bench.start();
      final pipe = b.pipes[0];
      final ch = b.channels[0];
      pipe.txData.inject(0xBCBC);
      pipe.txDataK.inject(3);
      pipe.txCompliance.inject(1);
      ch.port('RXDATA').inject(0xFFFF1C1C);
      ch.port('RXCHARISK').inject(0xF);
      await b.cycles(1);
      expect(ch.port('TXDATA').value.toInt(), 0xBCBC);
      expect(ch.port('TXCHARISK').value.toInt(), 3);
      expect(ch.port('TXCHARDISPMODE').value.toInt(), 1);
      expect(pipe.rxData.value.toInt(), 0x1C1C);
      expect(pipe.rxDataK.value.toInt(), 3);
      await b.finish();
    });
  });

  group('HarborGtpPciePhy elaboration', () {
    int count(String sv, String cell) =>
        RegExp('\\b$cell\\b').allMatches(sv).length;

    for (final lanes in [1, 4]) {
      test('x$lanes emits the MMCM, the BUFGs and the refclk select', () async {
        final common = HarborGtpCommonPorts();
        final phy = HarborGtpPciePhy(
          perstN: Logic(name: 'perst_n'),
          common: common,
          channels: [for (var i = 0; i < lanes; i++) HarborGtpChannelPorts()],
          pipes: [for (var i = 0; i < lanes; i++) HarborPciePipeLane()],
          lanes: lanes,
        );
        await phy.build();
        final sv = phy.generateSynth();
        expect(count(sv, 'MMCME2_ADV'), 1);
        expect(count(sv, 'BUFG'), 3);
        String param(String name) {
          final m = RegExp('\\.$name\\(([^)]*)\\)').firstMatch(sv);
          expect(m, isNotNull, reason: name);
          return m!.group(1)!;
        }

        expect(double.parse(param('CLKFBOUT_MULT_F')), 10);
        expect(double.parse(param('CLKOUT0_DIVIDE_F')), 8);
        expect(int.parse(param('CLKOUT2_DIVIDE')), lanes == 1 ? 16 : 8);
        expect(int.parse(param('DIVCLK_DIVIDE')), 1);
        expect(double.parse(param('CLKIN1_PERIOD')), 10);
        expect(param('COMPENSATION'), '"ZHOLD"');
        expect(sv, contains("gtc_PLL0REFCLKSEL = 3'h2"));
        expect(phy.input('gt${lanes - 1}_TXRESETDONE').width, 1);
        expect(phy.output('gt${lanes - 1}_TXDATA').width, 32);
        expect(phy.output('pipe${lanes - 1}_rxdata').width, 16);
      });
    }

    Module? mmcmOf(Module m) {
      for (final sub in m.subModules) {
        if (sub.definitionName == 'MMCME2_ADV') return sub;
        final found = mmcmOf(sub);
        if (found != null) return found;
      }
      return null;
    }

    for (final extra in [false, true]) {
      test('PERST# low resets the MMCM, mmcm_reset $extra', () async {
        final perstN = Logic(name: 'perst_n');
        final mmcmReset = Logic(name: 'mmcm_reset');
        final phy = HarborGtpPciePhy(
          perstN: perstN,
          common: HarborGtpCommonPorts(),
          channels: [HarborGtpChannelPorts()],
          pipes: [HarborPciePipeLane()],
          mmcmReset: extra ? mmcmReset : null,
        );
        await phy.build();
        final rst = mmcmOf(phy)!.input('RST');
        final seen = <int>[];
        void sample() => seen.add(rst.value.toInt());
        Simulator.registerAction(1, () {
          mmcmReset.put(0);
          perstN.put(0);
        });
        Simulator.registerAction(2, sample);
        Simulator.registerAction(3, () => perstN.put(1));
        Simulator.registerAction(4, sample);
        Simulator.registerAction(5, () => mmcmReset.put(1));
        Simulator.registerAction(6, sample);
        await Simulator.run();
        expect(seen, [1, 0, if (extra) 1 else 0]);
      });
    }

    test('lanes other than 1 and 4 throw', () {
      expect(
        () => HarborGtpPciePhy(
          perstN: Logic(),
          common: HarborGtpCommonPorts(),
          channels: [HarborGtpChannelPorts(), HarborGtpChannelPorts()],
          pipes: [HarborPciePipeLane(), HarborPciePipeLane()],
          lanes: 2,
        ),
        throwsArgumentError,
      );
    });

    test('GTPE2 parameter tables', () {
      expect(gtpe2ChannelPcieParameters, hasLength(232));
      expect(gtpe2ChannelPcieParameters['PCS_PCIE_EN'], '"TRUE"');
      expect(gtpe2ChannelPcieParameters['TXBUF_EN'], '"FALSE"');
      expect(gtpe2ChannelPcieParameters['TXSYNC_OVRD'], "1'h1");
      expect(gtpe2ChannelPcieParameters['TX_DRIVE_MODE'], '"PIPE"');
      expect(gtpe2ChannelPcieParameters['RX_DATA_WIDTH'], '20');
      expect(gtpe2ChannelPcieParameters['ES_CONTROL'], "6'h0");
      expect(
        gtpe2ChannelPcieParameters.keys.where((k) => k.startsWith('IS_')),
        isEmpty,
      );
      expect(gtpe2CommonPcieParameters['SIM_PLL0REFCLK_SEL'], "3'h2");
      expect(gtpe2CommonPcieParameters['PLL0_FBDIV'], '5');
      expect(gtpe2CommonPcieParameters['PLL0_FBDIV_45'], '5');
      expect(gtpe2CommonPcieParameters['PLL0_CFG'], "27'h1F024C");
      expect(gtpe2ChannelPcieTieOffs['TXOUTCLKSEL'], (3, 3));
      expect(gtpe2ChannelPcieTieOffs['TXPHALIGNEN'], (1, 1));
      expect(gtpe2ChannelPcieTieOffs['TXDLYBYPASS'], (1, 0));
      expect(gtpe2CommonPcieTieOffs['PLL0LOCKEN'], (1, 1));
    });

    test('tie-offs and PHY ports do not overlap', () {
      final ch = HarborGtpChannelPorts();
      final co = HarborGtpCommonPorts();
      for (final name in ch.getPorts().keys) {
        expect(
          gtpe2ChannelPcieTieOffs.containsKey(name),
          isFalse,
          reason: name,
        );
      }
      for (final name in co.getPorts().keys) {
        expect(gtpe2CommonPcieTieOffs.containsKey(name), isFalse, reason: name);
      }
    });

    test('primitive wrappers elaborate with the PCIe parameter set', () async {
      final commonPorts = HarborGtpCommonPorts();
      final common = HarborXilinxGtpe2Common(
        refClk1: Logic(),
        ports: commonPorts,
      );
      final channel = HarborXilinxGtpe2Channel(
        rxP: Logic(),
        rxN: Logic(),
        pll0Clk: common.pll0OutClk,
        pll0RefClk: common.pll0OutRefClk,
        ports: HarborGtpChannelPorts(),
      );
      await common.build();
      await channel.build();
      expect(common.definitionName, 'GTPE2_COMMON');
      expect(channel.definitionName, 'GTPE2_CHANNEL');
      expect(channel.input('DRPADDR').width, 9);
      expect(channel.input('DRPDI').width, 16);
      expect(channel.output('DRPDO').width, 16);
    });
  });
}
