import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../support/gtxe2_status_model.dart';

typedef _S = HarborGtxResetState;

const _timeouts = HarborGtxPcieTimeouts(
  resetDone: 100,
  cpllLock: 100,
  clockLock: 100,
  txSync: 40,
  rate: 60,
  clockSwitch: 8,
  syncRetries: 2,
  clockSettle: 30,
  txSettle: 8,
);

HarborGtxPcieTimeouts _withLinkWait(
  int linkWait, {
  int dataLinkWait = 1 << 27,
  int? txSettle,
}) => HarborGtxPcieTimeouts(
  resetDone: _timeouts.resetDone,
  cpllLock: _timeouts.cpllLock,
  clockLock: _timeouts.clockLock,
  txSync: _timeouts.txSync,
  rate: _timeouts.rate,
  clockSwitch: _timeouts.clockSwitch,
  syncRetries: _timeouts.syncRetries,
  clockSettle: _timeouts.clockSettle,
  txSettle: txSettle ?? _timeouts.txSettle,
  linkWait: linkWait,
  dataLinkWait: dataLinkWait,
);

/// PLLTSSMSTATE codes from PG054.
const _detectQuiet = 0x00;
const _l0 = 0x16;

const _porFlops = {'por_lock_0', 'por_lock_1', 'por_count'};

const _goodOrder = [
  _S.cfgWait,
  _S.cpllReset,
  _S.cpllLock,
  _S.gtRelease,
  _S.clockLock,
  _S.resetDone,
  _S.txDlySReset,
  _S.txPhInit,
  _S.txPhAlign,
  _S.txDlyEn,
  _S.idle,
];

class _Bench {
  final HarborGtxPciePhy phy;
  final Gtxe2StatusModel model;
  final HarborPciePipeLane pipe;
  final HarborGtxChannelPorts channel;
  final Logic perstN;
  final Logic pclk;
  final Logic? hardLinkUp;
  final Logic? phyLinkUpN;
  final Logic? ltssmState;

  /// The state after each change, from the start.
  final List<_S> trace = [];

  /// Cycle numbers of events on the GT controls, by name.
  final Map<String, List<int>> events = {};

  /// Cycles with PIPE PHYSTATUS high after the first idle.
  int phyStatusHighAfterIdle = 0;

  int cycle = 0;
  bool _stop = false;

  _Bench(
    this.phy,
    this.model,
    this.pipe,
    this.channel,
    this.perstN,
    this.pclk,
    this.hardLinkUp,
    this.phyLinkUpN,
    this.ltssmState,
  );

  _S get state => _S.fromCode(phy.resetState.value.toInt());
  _S get failState => _S.fromCode(phy.resetFailState.value.toInt());
  int get retries => phy.resetRetries.value.toInt();
  int get flags => phy.timeoutFlags.value.toInt();
  bool hi(Logic l) => l.value.isValid && l.value.toBool();

  Logic sig(String name) =>
      phy.internalSignals.firstWhere((l) => l.name == name);

  void link(int ltssm, {bool phy = false, bool data = false}) {
    ltssmState!.inject(ltssm);
    phyLinkUpN!.inject(phy ? 0 : 1);
    hardLinkUp!.inject(data ? 1 : 0);
  }

  static Future<_Bench> start({
    bool gen2 = true,
    bool waitRxCdrLock = false,
    bool waitForRxResetStatus = true,
    bool skipTxPhaseAlign = false,
    bool perstEdge = true,
    int pipeStages = 1,
    int linkWait = 0,
    int? txSettle,
    int userClkPeriod = 8,
    int? userClkHz,
    void Function(Gtxe2StatusModel m)? setup,
  }) async {
    final pclk = SimpleClockGenerator(8).clk;
    final userClk = userClkPeriod == 8
        ? pclk
        : SimpleClockGenerator(userClkPeriod).clk;
    // A valid PERST# before build keeps the async reset of the power-on
    // reset flops away from an X edge at time 0.
    final perstN = Logic(name: 'perst_n')..put(perstEdge ? 0 : 1);
    final channel = HarborGtxChannelPorts();
    final pipe = HarborPciePipeLane();
    final model = Gtxe2StatusModel(pclk, channel);
    setup?.call(model);
    final watch = linkWait != 0;
    final hardLinkUp = watch ? (Logic(name: 'link')..put(0)) : null;
    final phyLinkUpN = watch ? (Logic(name: 'phy_link_n')..put(1)) : null;
    final ltssmState = watch
        ? (Logic(name: 'ltssm', width: 6)..put(_detectQuiet))
        : null;
    final phy = HarborGtxPciePhy(
      perstN: perstN,
      hardLinkUp: hardLinkUp,
      phyLinkUpN: phyLinkUpN,
      ltssmState: ltssmState,
      channel: channel,
      pipe: pipe,
      clocks: HarborPipeClocks(
        pclk: pclk,
        userClk1: userClk,
        userClk2: userClk,
        mmcmLock: model.mmcmLock,
        oobClk: pclk,
      ),
      gen2: gen2,
      userClkHz: userClkHz,
      waitRxCdrLock: waitRxCdrLock,
      debugSkipTxPhaseAlign: skipTxPhaseAlign,
      debugBuild: skipTxPhaseAlign,
      waitForRxResetStatus: waitForRxResetStatus,
      pipeStages: pipeStages,
      timeouts: _withLinkWait(linkWait, txSettle: txSettle),
    );
    await phy.build();
    pipe.txData.inject(0);
    pipe.txDataK.inject(0);
    pipe.txDetectRx.inject(0);
    pipe.txElecIdle.inject(1);
    pipe.txCompliance.inject(0);
    pipe.rxPolarity.inject(0);
    pipe.powerDown.inject(0);
    pipe.pipeRate.inject(0);
    pipe.txMargin.inject(0);
    pipe.txSwing.inject(0);
    pipe.txDeemph.inject(0);
    // FPGA flops start at zero after configuration.
    for (final l in phy.internalSignals) {
      if (_porFlops.contains(l.name)) l.inject(0);
    }
    final b = _Bench(
      phy,
      model,
      pipe,
      channel,
      perstN,
      pclk,
      hardLinkUp,
      phyLinkUpN,
      ltssmState,
    );
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
    final watch = {
      'cpll_reset': channel.port('CPLLRESET'),
      'gt_reset': channel.port('GTTXRESET'),
      'cpll_lock': channel.port('CPLLLOCK'),
      'user_rdy': channel.port('TXUSERRDY'),
      'mmcm_lock': model.mmcmLock,
      'pclk_sel': phy.pclkSel,
      'txrate': channel.port('TXRATE'),
      'dlysreset': channel.port('TXDLYSRESET'),
    };
    final last = <String, bool>{};
    var seenIdle = false;
    while (!_stop) {
      await pclk.nextNegedge;
      cycle++;
      if (!phy.resetState.value.isValid) continue;
      final s = state;
      if (trace.isEmpty || trace.last != s) {
        trace.add(s);
        events.putIfAbsent('enter_${s.name}', () => []).add(cycle);
      }
      for (final e in watch.entries) {
        final v = e.value.value.isValid && e.value.value.toInt() != 0;
        if (last[e.key] != v) {
          events
              .putIfAbsent('${e.key}_${v ? 'rise' : 'fall'}', () => [])
              .add(cycle);
          last[e.key] = v;
        }
      }
      if (s == _S.idle) seenIdle = true;
      if (seenIdle && hi(pipe.phyStatus)) phyStatusHighAfterIdle++;
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

  /// Clock edges until [f] is true, 0 when it is true now.
  Future<int> until(bool Function() f, {int limit = 100}) async {
    for (var i = 0; i <= limit; i++) {
      if (i > 0) await pclk.nextNegedge;
      if (f()) return i;
    }
    fail('condition not met in $limit cycles');
  }

  List<_S> traceFrom(_S from) => trace.sublist(trace.lastIndexOf(from));

  int first(String event) => events[event]?.first ?? -1;

  /// The first cycle of [event] after cycle [after], or -1.
  int firstAfter(String event, int after) =>
      (events[event] ?? []).firstWhere((c) => c > after, orElse: () => -1);

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

  group('HarborGtxPciePhy sequence', () {
    test('good start goes through each state in order', () async {
      final b = await _Bench.start();
      await b.waitFor(_S.idle);
      expect(b.trace, _goodOrder);
      expect(b.retries, 0);
      expect(b.failState, _S.none);
      expect(b.flags, 0);
      expect(b.hi(b.phy.phyReady), isTrue);

      // CPLLRESET and the GT resets first, then CPLL lock, then the GT
      // resets low, then USERRDY after the MMCM lock.
      expect(b.first('cpll_reset_rise'), greaterThan(0));
      expect(b.first('gt_reset_rise'), b.first('cpll_reset_rise'));
      final released = b.firstAfter(
        'cpll_reset_fall',
        b.first('cpll_reset_rise'),
      );
      expect(released, lessThan(b.last('cpll_lock_rise')));
      expect(b.last('cpll_lock_rise'), lessThan(b.last('gt_reset_fall')));
      expect(b.last('gt_reset_fall'), lessThan(b.first('user_rdy_rise')));
      expect(b.first('mmcm_lock_rise'), lessThan(b.first('user_rdy_rise')));

      final ch = b.channel;
      expect(b.hi(ch.port('TXDLYEN')), isTrue);
      expect(b.hi(ch.port('TXPHALIGN')), isFalse);
      expect(b.hi(ch.port('GTRXRESET')), isFalse);
      expect(b.hi(ch.port('CPLLRESET')), isFalse);
      expect(b.hi(ch.port('RXUSERRDY')), isTrue);
      expect(b.model.txSyncRuns, 1);
      expect(b.phy.txResetDone.value.toInt(), 1);
      expect(b.phy.rxResetDone.value.toInt(), 1);
      await b.finish();
    });

    test(
      'one cycle done pulses pass the TX sync, two TXPHALIGNDONE pulses',
      () async {
        final b = await _Bench.start(setup: (m) => m.pulseDones = true);
        await b.waitFor(_S.idle);
        expect(b.trace, _goodOrder);
        expect(b.retries, 0);
        expect(b.model.txSyncRuns, 1);
        expect(b.phy.phAlignCount.value.toInt(), 2);
        expect(b.phy.txSyncSeen.value.toInt(), 7);
        await b.finish();
      },
    );

    test(
      'a TX sync timeout restarts the sync only, then the whole sequence',
      () async {
        final b = await _Bench.start(setup: (m) => m.phAlignStuck = true);
        await b.waitFor(_S.txPhAlign);
        // syncRetries is 2: the sync steps run three times, with no CPLL reset
        // in between, and then the sequence restarts.
        await b.waitFor(_S.cpllReset, limit: 3000);
        final t = b.traceFrom(_S.resetDone);
        expect(t.where((s) => s == _S.txDlySReset), hasLength(3));
        expect(t.where((s) => s == _S.cpllLock), isEmpty);
        expect(b.retries, 3);
        expect(b.flags, 8);
        b.model.phAlignStuck = false;
        await b.waitFor(_S.idle, limit: 3000);
        await b.finish();
      },
    );

    test('sync retries start again after a good sync', () async {
      final b = await _Bench.start();
      await b.waitFor(_S.idle);
      expect(b.sig('sync_tries').value.toInt(), 0);
      await b.finish();
    });

    test('the TX sync order is DLYSRESET, PHINIT, PHALIGN, DLYEN', () async {
      final b = await _Bench.start(setup: (m) => m.pulseDones = true);
      await b.waitFor(_S.txDlySReset);
      final ch = b.channel;
      final order = <String>[];
      var last = '';
      while (b.state != _S.idle) {
        await b.pclk.nextNegedge;
        for (final (n, p) in [
          ('dlysreset', 'TXDLYSRESET'),
          ('phinit', 'TXPHINIT'),
          ('phalign', 'TXPHALIGN'),
        ]) {
          if (b.hi(ch.port(p)) && last != n) {
            order.add(n);
            last = n;
          }
        }
        expect(
          [
            for (final p in ['TXDLYSRESET', 'TXPHINIT', 'TXPHALIGN'])
              b.hi(ch.port(p)) ? 1 : 0,
          ].reduce((a, c) => a + c),
          lessThanOrEqualTo(1),
          reason: 'one request at a time',
        );
      }
      expect(order, ['dlysreset', 'phinit', 'phalign']);
      await b.finish();
    });

    test('skipTxPhaseAlign goes from reset done to idle', () async {
      final b = await _Bench.start(skipTxPhaseAlign: true);
      await b.waitFor(_S.idle);
      expect(b.trace, [
        _S.cfgWait,
        _S.cpllReset,
        _S.cpllLock,
        _S.gtRelease,
        _S.clockLock,
        _S.resetDone,
        _S.idle,
      ]);
      expect(b.model.txSyncRuns, 0);
      expect(b.hi(b.channel.port('TXDLYEN')), isFalse);
      expect(b.hi(b.phy.phyReady), isTrue);
      // A rate change finishes with no TX sync.
      b.pipe.pipeRate.inject(1);
      await b.cycles(200);
      expect(b.channel.port('TXRATE').value.toInt(), 1);
      expect(b.state, _S.idle);
      expect(b.retries, 0);
      await b.finish();
    });

    for (final n in [0, 1, 2]) {
      test('pipeStages $n: PHYSTATUS and RXSTATUS come out together', () async {
        final b = await _Bench.start(pipeStages: n);
        await b.waitFor(_S.idle);
        await b.cycles(20);
        expect(b.hi(b.pipe.phyStatus), isFalse);
        var pulses = 0;
        b.pipe.powerDown.inject(2);
        for (var i = 0; i < 40; i++) {
          await b.pclk.nextNegedge;
          final st = b.hi(b.pipe.phyStatus);
          final rx = b.pipe.rxStatus.value.toInt();
          if (st) pulses++;
          expect(st, rx == 3, reason: 'cycle $i');
        }
        expect(pulses, 1);
        await b.finish();
      });
    }

    test('rx_debug shows the receive path since idle', () async {
      final b = await _Bench.start(pipeStages: 0);
      await b.waitFor(_S.idle);
      b.channel.port('RXELECIDLE').put(1);
      await b.cycles(3);
      final d = b.phy.rxDebug;
      int bit(int i) => d.value[i].toInt();
      expect(bit(0), 1, reason: 'idle now');
      expect(bit(2), 1, reason: 'RXVALID is up');
      b.channel.port('RXELECIDLE').put(0);
      b.channel.port('RXCHARISK').put(1);
      await b.cycles(40);
      expect(bit(0), 0);
      expect(bit(1), 1, reason: 'seen low');
      expect(bit(3), 1, reason: 'seen valid');
      expect(bit(6), 1, reason: 'seen K');
      expect(d.width, HarborGtxPciePhy.rxDebugBits);
      await b.finish();
    });

    test('debugSkipTxPhaseAlign needs debugBuild', () {
      expect(
        () => HarborGtxPciePhy(
          perstN: Logic(),
          channel: HarborGtxChannelPorts(),
          pipe: HarborPciePipeLane(),
          timeouts: const HarborGtxPcieTimeouts(linkWait: 0),
          debugSkipTxPhaseAlign: true,
        ),
        throwsArgumentError,
      );
    });

    test('options that change the logic change the definition name', () {
      String name({bool cdr = false, bool rx = true}) => HarborGtxPciePhy(
        perstN: Logic(),
        channel: HarborGtxChannelPorts(),
        pipe: HarborPciePipeLane(),
        timeouts: const HarborGtxPcieTimeouts(linkWait: 0),
        waitRxCdrLock: cdr,
        waitForRxResetStatus: rx,
      ).definitionName;
      expect({name(), name(cdr: true), name(rx: false)}, hasLength(3));
    });

    test(
      'the userClkHz option reaches the getter and the sequence is the same',
      () async {
        final b = await _Bench.start(userClkPeriod: 16, userClkHz: 62500000);
        await b.waitFor(_S.idle);
        expect(b.trace, _goodOrder);
        expect(b.phy.userClkHz, 62500000);
        await b.finish();
      },
    );

    test('USERRDY waits clockSettle cycles after the lock', () async {
      final b = await _Bench.start();
      await b.waitFor(_S.idle);
      final lock = b.first('enter_clockLock');
      final rdy = b.first('user_rdy_rise');
      expect(rdy - lock, greaterThanOrEqualTo(_timeouts.clockSettle));
      expect(rdy - lock, lessThan(_timeouts.clockSettle + 10));
      await b.finish();
    });

    test('a lock loss in clockLock starts the settle count again', () async {
      final b = await _Bench.start();
      await b.waitFor(_S.clockLock);
      await b.cycles(10);
      b.model.dropMmcmLock(5);
      final dropAt = b.cycle;
      await b.waitFor(_S.idle);
      final rdy = b.first('user_rdy_rise');
      expect(rdy - dropAt, greaterThanOrEqualTo(_timeouts.clockSettle));
      await b.finish();
    });

    test(
      'TXDLYSRESET rises txSettle cycles after the TX sync starts',
      () async {
        final b = await _Bench.start();
        await b.waitFor(_S.idle);
        final entered = b.first('enter_txDlySReset');
        final rise = b.first('dlysreset_rise');
        expect(rise - entered, greaterThanOrEqualTo(_timeouts.txSettle));
        expect(rise - entered, lessThan(_timeouts.txSettle + 4));
        await b.finish();
      },
    );

    test('a TX sync retry waits txSettle cycles again', () async {
      final b = await _Bench.start(setup: (m) => m.phAlignStuck = true);
      await b.waitFor(_S.txPhAlign);
      await b.waitFor(_S.cpllReset, limit: 3000);
      final entered = b.events['enter_txDlySReset']!;
      final rises = b.events['dlysreset_rise']!;
      expect(entered, hasLength(3));
      for (var i = 0; i < 3; i++) {
        expect(rises[i] - entered[i], greaterThanOrEqualTo(_timeouts.txSettle));
      }
      b.model.phAlignStuck = false;
      await b.waitFor(_S.idle, limit: 3000);
      await b.finish();
    });

    test(
      'a TXDLYSRESETDONE edge in the settle window does not advance',
      () async {
        final b = await _Bench.start();
        await b.waitFor(_S.txDlySReset);
        await b.cycles(1);
        b.model.dlyDoneForce = true;
        await b.cycles(2);
        b.model.dlyDoneForce = false;
        await b.cycles(2);
        expect(b.state, _S.txDlySReset);
        expect(b.hi(b.channel.port('TXDLYSRESET')), isFalse);
        await b.waitFor(_S.idle);
        expect(b.model.txSyncRuns, 1);
        await b.finish();
      },
    );

    test('a retry from TXDLYSRESET gives one TXDLYSRESET edge each', () async {
      final b = await _Bench.start(setup: (m) => m.dlySResetStuck = true);
      await b.waitFor(_S.txDlySReset, limit: 3000);
      await b.waitFor(_S.cpllReset, limit: 3000);
      // syncRetries is 2: the sync runs three times in the one state, then
      // the sequence restarts.
      expect(b.events['enter_txDlySReset'], hasLength(1));
      final entered = b.first('enter_txDlySReset');
      expect(
        b.events['dlysreset_rise']!.where((c) => c > entered),
        hasLength(3),
      );
      expect(
        b.events['dlysreset_fall']!.where((c) => c > entered),
        hasLength(3),
      );
      b.model.dlySResetStuck = false;
      await b.waitFor(_S.idle, limit: 3000);
      await b.finish();
    });

    test('a txSettle of 0 raises TXDLYSRESET at once', () async {
      final b = await _Bench.start(txSettle: 0);
      await b.waitFor(_S.idle);
      expect(
        b.first('dlysreset_rise') - b.first('enter_txDlySReset'),
        lessThan(4),
      );
      await b.finish();
    });

    test('a txSettle that does not fit the txSync bound throws', () {
      expect(
        () => HarborGtxPciePhy(
          perstN: Logic(),
          channel: HarborGtxChannelPorts(),
          pipe: HarborPciePipeLane(),
          timeouts: const HarborGtxPcieTimeouts(
            linkWait: 0,
            txSync: 100,
            txSettle: 100,
          ),
        ),
        throwsArgumentError,
      );
    });

    test('a clockSettle that does not fit the lock bound throws', () {
      expect(
        () => HarborGtxPciePhy(
          perstN: Logic(),
          channel: HarborGtxChannelPorts(),
          pipe: HarborPciePipeLane(),
          timeouts: const HarborGtxPcieTimeouts(
            linkWait: 0,
            clockLock: 100,
            clockSettle: 100,
          ),
        ),
        throwsArgumentError,
      );
    });

    test('CPLLRESET stays high at least 16 cycles', () async {
      final b = await _Bench.start();
      await b.waitFor(_S.idle);
      final rise = b.first('cpll_reset_rise');
      final fall = b.firstAfter('cpll_reset_fall', rise);
      expect(fall - rise, greaterThanOrEqualTo(16));
      await b.finish();
    });

    test('the clock and data controls take the PCIe constants', () async {
      final b = await _Bench.start();
      await b.waitFor(_S.idle);
      final ch = b.channel;
      for (final c in ['TXUSRCLK', 'TXUSRCLK2', 'RXUSRCLK', 'RXUSRCLK2']) {
        expect(ch.port(c).value.toInt(), anyOf(0, 1), reason: c);
      }
      // CLKRSVD[3:1] are low and CLKRSVD[0] is the OOB clock.
      expect(ch.port('CLKRSVD').value.toInt() >> 1, 0);
      await b.finish();
    });

    test(
      'stuck CPLL never reaches idle, retries, and shows its state',
      () async {
        final b = await _Bench.start(setup: (m) => m.cpllStuck = true);
        await b.cycles(1500);
        expect(b.trace, isNot(contains(_S.idle)));
        expect(b.state, anyOf(_S.cpllReset, _S.cpllLock));
        expect(b.failState, _S.cpllLock);
        expect(b.retries, greaterThanOrEqualTo(8));
        expect(b.flags, 1);
        expect(b.hi(b.channel.port('GTTXRESET')), isTrue);
        expect(b.hi(b.phy.phyReady), isFalse);
        expect(b.hi(b.pipe.phyStatus), isTrue);

        b.model.cpllStuck = false;
        await b.waitFor(_S.idle);
        expect(b.traceFrom(_S.cpllReset), _goodOrder.sublist(1));
        expect(b.flags, 1, reason: 'a flag stays until PERST#');
        await b.finish();
      },
    );

    test('RXCDRLOCK is waited for only with waitRxCdrLock', () async {
      var b = await _Bench.start(setup: (m) => m.cdrStuck = true);
      await b.waitFor(_S.idle);
      expect(b.retries, 0);
      await b.finish();
      await Simulator.reset();

      b = await _Bench.start(
        waitRxCdrLock: true,
        setup: (m) => m.cdrStuck = true,
      );
      await b.cycles(800);
      expect(b.trace, isNot(contains(_S.idle)));
      expect(b.failState, _S.clockLock);
      expect(b.flags, 2);
      b.model.cdrStuck = false;
      await b.waitFor(_S.idle);
      expect(b.traceFrom(_S.cpllReset), _goodOrder.sublist(1));
      await b.finish();
    });

    test('RX reset status can be skipped', () async {
      final b = await _Bench.start(
        waitForRxResetStatus: false,
        setup: (m) => m.resetDoneDelay = 12,
      );
      await b.waitFor(_S.idle);
      expect(b.trace, _goodOrder);
      expect(b.retries, 0);
      await b.finish();
    });

    test('each wait has a bound and its own timeout flag', () async {
      final faults = <String, (void Function(Gtxe2StatusModel m), int)>{
        'cpll lock': ((m) => m.cpllStuck = true, 1),
        'reset done': ((m) => m.resetDoneStuck = true, 4),
        'tx sync': ((m) => m.syncDelay = 1 << 30, 8),
      };
      for (final f in faults.entries) {
        final b = await _Bench.start(setup: f.value.$1);
        await b.cycles(800);
        expect(b.retries, greaterThan(0), reason: f.key);
        expect(b.trace, isNot(contains(_S.idle)), reason: f.key);
        expect(b.flags, f.value.$2, reason: f.key);
        await b.finish();
        await Simulator.reset();
      }

      // The power-on reset waits for the first MMCM lock, so the lock goes
      // away after the sequence starts.
      final b = await _Bench.start();
      await b.waitFor(_S.gtRelease);
      b.model.dropMmcmLock(1 << 30);
      await b.cycles(800);
      expect(b.retries, greaterThan(0), reason: 'mmcm lock');
      expect(b.trace, isNot(contains(_S.idle)), reason: 'mmcm lock');
      expect(b.failState, _S.clockLock);
      expect(b.flags, 2);
      await b.finish();
    });

    test('TX sync timeout lasts exactly the timeout in cycles', () async {
      final b = await _Bench.start(setup: (m) => m.phAlignStuck = true);
      await b.waitFor(_S.txPhAlign);
      // The state is seen at the first sample. It stays for txSync samples.
      var samples = 1;
      while (b.state == _S.txPhAlign) {
        await b.pclk.nextNegedge;
        if (b.state == _S.txPhAlign) samples++;
        if (samples > 200) fail('no timeout');
      }
      // The failure is registered, so the state stays one more cycle.
      expect(samples, _timeouts.txSync + 1);
      expect(b.state, _S.txDlySReset);
      expect(b.failState, _S.txPhAlign);
      await b.finish();
    });

    test('PERST# high from power-up with no edge reaches idle', () async {
      final b = await _Bench.start(perstEdge: false);
      await b.waitFor(_S.idle);
      expect(b.trace, _goodOrder);
      expect(b.retries, 0);
      b.perstN.inject(0);
      await b.cycles(4);
      expect(b.state, _S.cfgWait);
      expect(b.hi(b.phy.phyReady), isFalse);
      b.perstN.inject(1);
      await b.waitFor(_S.idle);
      expect(b.traceFrom(_S.cfgWait), _goodOrder);
      await b.finish();
    });

    test(
      'PERST# mid sequence restarts from the top and clears the flags',
      () async {
        final b = await _Bench.start(setup: (m) => m.cpllStuck = true);
        await b.cycles(400);
        expect(b.flags, 1);
        b.model.cpllStuck = false;
        await b.waitFor(_S.txPhInit);
        b.perstN.inject(0);
        await b.cycles(1);
        expect(b.state, _S.cfgWait);
        await b.cycles(3);
        final ch = b.channel;
        expect(b.hi(ch.port('GTTXRESET')), isFalse);
        expect(b.hi(ch.port('TXUSERRDY')), isFalse);
        expect(b.hi(ch.port('TXPHINIT')), isFalse);
        expect(b.hi(b.pipe.phyStatus), isTrue);
        expect(b.flags, 0);
        expect(b.retries, 0);
        b.perstN.inject(1);
        await b.waitFor(_S.idle);
        expect(b.traceFrom(_S.cfgWait), _goodOrder);
        expect(b.retries, 0);
        await b.finish();
      },
    );

    test('lost CPLL lock in idle restarts the sequence', () async {
      final b = await _Bench.start();
      await b.waitFor(_S.idle);
      b.model.dropCpllLock(30);
      await b.waitFor(_S.cpllReset, limit: 20);
      expect(b.failState, _S.idle);
      expect(b.retries, 1);
      expect(b.flags, 0, reason: 'a lock loss is not a timeout');
      await b.waitFor(_S.idle);
      expect(b.traceFrom(_S.cpllReset), _goodOrder.sublist(1));
      await b.finish();
    });

    test('lost MMCM lock in idle restarts the sequence', () async {
      final b = await _Bench.start();
      await b.waitFor(_S.idle);
      b.model.dropMmcmLock(20);
      await b.waitFor(_S.cpllReset, limit: 20);
      expect(b.failState, _S.idle);
      await b.waitFor(_S.idle);
      expect(b.retries, 1);
      await b.finish();
    });
  });

  group('HarborGtxPciePhy rate change', () {
    for (final n in [0, 1, 2]) {
      test('pipeStages $n: the clock select moves first, then TXRATE, then '
          'TX sync and one PHYSTATUS', () async {
        final b = await _Bench.start(pipeStages: n);
        await b.waitFor(_S.idle);
        await b.cycles(10);
        final before = b.phyStatusHighAfterIdle;
        final traceLen = b.trace.length;
        expect(b.phy.pclkSel.value.toInt(), 0);
        b.pipe.pipeRate.inject(1);
        await b.waitFor(_S.txDlySReset, limit: 200);
        await b.waitFor(_S.idle, limit: 300);
        await b.cycles(10);
        expect(b.phy.pclkSel.value.toInt(), 1);
        expect(b.channel.port('TXRATE').value.toInt(), 1);
        expect(b.channel.port('RXRATE').value.toInt(), 1);
        final sel = b.first('pclk_sel_rise');
        final rate = b.first('txrate_rise');
        expect(sel, greaterThan(0));
        expect(rate - sel, _timeouts.clockSwitch);
        expect(b.model.txRates, [0, 1]);
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
    }

    test('a rate change back to 2.5 GT/s moves both again', () async {
      final b = await _Bench.start();
      await b.waitFor(_S.idle);
      b.pipe.pipeRate.inject(1);
      await b.waitFor(_S.txDlySReset, limit: 200);
      await b.waitFor(_S.idle, limit: 300);
      await b.cycles(10);
      b.pipe.pipeRate.inject(0);
      await b.waitFor(_S.txDlySReset, limit: 200);
      await b.waitFor(_S.idle, limit: 300);
      await b.cycles(10);
      expect(b.phy.pclkSel.value.toInt(), 0);
      expect(b.channel.port('TXRATE').value.toInt(), 0);
      expect(b.model.txRates, [0, 1, 0]);
      expect(b.retries, 0);
      await b.finish();
    });

    test('a rate change with no answer restarts the sequence', () async {
      final b = await _Bench.start(setup: (m) => m.rateStuck = true);
      await b.waitFor(_S.idle);
      final rateState = b.sig('rate_state');
      final rateFail = b.sig('rate_fail');
      b.pipe.pipeRate.inject(1);
      // The rate wait is state 2.
      await b.until(() => rateState.value.toInt() == 2, limit: 100);
      final waited = await b.until(() => b.hi(rateFail));
      expect(waited, _timeouts.rate - 1);
      await b.waitFor(_S.cpllReset, limit: 200);
      expect(b.failState, _S.rateChange);
      expect(b.flags, 16);
      expect(b.retries, 1);
      // The restart goes back to 2.5 GT/s with the 125 MHz clock.
      await b.cycles(3);
      expect(b.phy.pclkSel.value.toInt(), 0);
      expect(b.channel.port('TXRATE').value.toInt(), 0);
      await b.finish();
    });

    test('PHYSTATUS is high until idle, then follows the GT', () async {
      final b = await _Bench.start();
      await b.cycles(5);
      expect(b.hi(b.pipe.phyStatus), isTrue);
      await b.waitFor(_S.idle);
      await b.cycles(10);
      expect(b.hi(b.pipe.phyStatus), isFalse);
      await b.finish();
    });
  });

  group('HarborGtxPciePhy Detect and Polling at the PIPE', () {
    // The PIPE side expectations of the hard block, from PG054: receiver
    // detect gives PHYSTATUS with RXSTATUS 011 on one cycle, TXELECIDLE low
    // starts the TS1, and the partner TS1 reaches PIPE RX with RXVALID and
    // the K symbols while RXELECIDLE is low.
    for (final n in [0, 1, 2]) {
      test(
        'pipeStages $n: detect, TXELECIDLE exit and TS1 from the partner',
        () async {
          final b = await _Bench.start(
            pipeStages: n,
            setup: (m) => m.rxValidExternal = true,
          );
          final ch = b.channel;
          await b.waitFor(_S.idle);
          // The PHY is ready. No hard block link up is needed for RXVALID.
          expect(b.hi(b.hardLinkUp ?? Const(0)), isFalse);
          await b.cycles(30);

          // Detect: P1, then TXDETECTRX.
          b.pipe.powerDown.inject(2);
          b.pipe.txDetectRx.inject(1);
          var pulses = 0;
          for (var i = 0; i < 60; i++) {
            await b.pclk.nextNegedge;
            if (b.hi(b.pipe.phyStatus)) {
              pulses++;
              expect(b.pipe.rxStatus.value.toInt(), 3, reason: 'cycle $i');
            }
          }
          expect(pulses, greaterThanOrEqualTo(1));
          expect(b.channel.port('TXDETECTRX').value.toInt(), 1);
          b.pipe.txDetectRx.inject(0);
          b.pipe.powerDown.inject(0);
          await b.cycles(30);
          expect(b.hi(b.pipe.phyStatus), isFalse);

          // TXELECIDLE exit reaches the GT after the pipeline stages.
          b.pipe.txElecIdle.inject(0);
          final late = await b.until(
            () => !b.hi(ch.port('TXELECIDLE')),
            limit: 10,
          );
          expect(late, inInclusiveRange(n, n + 1), reason: 'n pipeline stages');

          // The partner leaves idle and sends TS1 words: COM and PAD, then D10.2.
          ch.port('RXVALID').put(0);
          ch.port('RXELECIDLE').put(1);
          await b.cycles(10);
          expect(b.hi(b.pipe.rxElecIdle), isTrue);
          expect(b.hi(b.pipe.rxValid), isFalse);
          ch.port('RXELECIDLE').put(0);
          final idleLate = await b.until(
            () => !b.hi(b.pipe.rxElecIdle),
            limit: 10,
          );
          // Two sync flops and the n stages.
          expect(idleLate, lessThanOrEqualTo(n + 3));

          ch.port('RXVALID').put(1);
          var comSeen = false;
          var d102Seen = false;
          var validFirst = -1;
          for (var i = 0; i < 80; i++) {
            // TS1: word 0 is {PAD, COM}, then the D10.2 words.
            final word = i % 8 == 0 ? 0xF7BC : 0x4A4A;
            final k = i % 8 == 0 ? 3 : 0;
            ch.port('RXDATA').put(word);
            ch.port('RXCHARISK').put(k);
            await b.pclk.nextNegedge;
            if (b.hi(b.pipe.rxValid)) {
              validFirst = validFirst < 0 ? i : validFirst;
              if (b.pipe.rxData.value.toInt() == 0xF7BC &&
                  b.pipe.rxDataK.value.toInt() == 3) {
                comSeen = true;
              }
              if (b.pipe.rxData.value.toInt() == 0x4A4A &&
                  b.pipe.rxDataK.value.toInt() == 0) {
                d102Seen = true;
              }
            }
          }
          expect(
            validFirst,
            inInclusiveRange(15, 20 + n),
            reason: 'the 16 cycle RXVALID hold',
          );
          expect(comSeen, isTrue, reason: 'COM reached the PIPE');
          expect(d102Seen, isTrue, reason: 'D10.2 reached the PIPE');
          expect(b.hi(b.pipe.phyStatus), isFalse);
          await b.finish();
        },
      );
    }
  });

  group('HarborGtxPciePhy PIPE shaping', () {
    for (final n in [0, 1, 2]) {
      test(
        'pipeStages $n: TX and RX data map to the low half of the GT',
        () async {
          final b = await _Bench.start(pipeStages: n);
          await b.waitFor(_S.idle);
          b.pipe.txData.inject(0xA5C3);
          b.pipe.txDataK.inject(2);
          b.pipe.txCompliance.inject(1);
          b.channel.port('RXDATA').put(0x1234);
          b.channel.port('RXCHARISK').put(1);
          await b.cycles(n + 3);
          expect(b.channel.port('TXDATA').value.toInt(), 0xA5C3);
          expect(b.channel.port('TXCHARISK').value.toInt(), 2);
          expect(b.channel.port('TXCHARDISPMODE').value.toInt(), 1);
          expect(b.channel.port('TXDATA').width, 64);
          expect(b.pipe.rxData.value.toInt(), 0x1234);
          expect(b.pipe.rxDataK.value.toInt(), 1);
          await b.finish();
        },
      );
    }

    test('pipeStages other than 0, 1 and 2 throw', () {
      for (final n in [-1, 3]) {
        expect(
          () => HarborGtxPciePhy(
            perstN: Logic(),
            hardLinkUp: Logic(),
            phyLinkUpN: Logic(),
            ltssmState: Logic(width: 6),
            channel: HarborGtxChannelPorts(),
            pipe: HarborPciePipeLane(),
            pipeStages: n,
          ),
          throwsArgumentError,
        );
      }
    });

    test('RXVALID passes only in idle after 16 clean cycles', () async {
      final b = await _Bench.start(pipeStages: 0);
      final gtValid = b.channel.port('RXVALID');
      var seenValidBeforeIdle = false;
      while (true) {
        await b.pclk.nextNegedge;
        if (b.state == _S.idle) break;
        if (b.hi(b.pipe.rxValid)) seenValidBeforeIdle = true;
      }
      expect(seenValidBeforeIdle, isFalse);
      await b.cycles(40);
      expect(b.hi(gtValid), isTrue);
      expect(b.hi(b.pipe.rxValid), isTrue);
      await b.finish();
    });
  });

  group('HarborGtxPciePhy link watchdog', () {
    test('no link partner restarts every linkWait and saturates', () async {
      final b = await _Bench.start(linkWait: 400);
      b.link(_detectQuiet);
      await b.waitFor(_S.idle);
      await b.cycles(1500);
      expect(b.phy.linkRetrains!.value.toInt(), greaterThanOrEqualTo(2));
      expect(b.retries, 0, reason: 'a restart is not a failure');
      await b.finish();
    });

    test('link up stops the restarts', () async {
      final b = await _Bench.start(linkWait: 400);
      b.link(_detectQuiet);
      await b.waitFor(_S.idle);
      b.link(_l0, phy: true, data: true);
      await b.cycles(1500);
      expect(b.phy.linkRetrains!.value.toInt(), 0);
      await b.finish();
    });

    test('linkWait and hardLinkUp are checked', () {
      expect(
        () => HarborGtxPciePhy(
          perstN: Logic(),
          channel: HarborGtxChannelPorts(),
          pipe: HarborPciePipeLane(),
        ),
        throwsArgumentError,
      );
      expect(
        () => HarborGtxPciePhy(
          perstN: Logic(),
          channel: HarborGtxChannelPorts(),
          pipe: HarborPciePipeLane(),
          timeouts: const HarborGtxPcieTimeouts(linkWait: 2),
          hardLinkUp: Logic(),
          phyLinkUpN: Logic(),
          ltssmState: Logic(width: 6),
        ),
        throwsArgumentError,
      );
      expect(
        () => HarborGtxPciePhy(
          perstN: Logic(),
          channel: HarborGtxChannelPorts(),
          pipe: HarborPciePipeLane(),
          timeouts: const HarborGtxPcieTimeouts(linkWait: 0, resetDone: 20),
        ),
        throwsArgumentError,
      );
    });
  });

  group('HarborGtxPciePhy elaboration', () {
    int count(String sv, String cell) =>
        RegExp('\\b$cell\\b').allMatches(sv).length;

    for (final gen2 in [true, false]) {
      test('gen2 $gen2 emits the MMCM and the clock buffers', () async {
        final phy = HarborGtxPciePhy(
          perstN: Logic(name: 'perst_n'),
          hardLinkUp: Logic(name: 'link'),
          phyLinkUpN: Logic(name: 'phy_link_n'),
          ltssmState: Logic(name: 'ltssm', width: 6),
          channel: HarborGtxChannelPorts(),
          pipe: HarborPciePipeLane(),
          gen2: gen2,
        );
        await phy.build();
        final sv = phy.dumpSystemVerilog();
        expect(count(sv, 'MMCME2_ADV'), 1);
        expect(count(sv, 'BUFGCTRL'), gen2 ? 1 : 0);
        expect(count(sv, 'BUFG'), gen2 ? 3 : 4);
        String param(String name) {
          final m = RegExp('\\.$name\\(([^)]*)\\)').firstMatch(sv);
          expect(m, isNotNull, reason: name);
          return m!.group(1)!;
        }

        expect(double.parse(param('CLKFBOUT_MULT_F')), 10);
        expect(double.parse(param('CLKOUT0_DIVIDE_F')), 8);
        expect(int.parse(param('CLKOUT2_DIVIDE')), gen2 ? 8 : 16);
        if (gen2) expect(int.parse(param('CLKOUT1_DIVIDE')), 4);
        expect(int.parse(param('CLKOUT3_DIVIDE')), 16);
        expect(double.parse(param('CLKIN1_PERIOD')), 10);
        expect(param('COMPENSATION'), '"ZHOLD"');
        expect(phy.input('gt_TXRESETDONE').width, 1);
        expect(phy.output('gt_TXDATA').width, 64);
        expect(phy.output('pipe_rxdata').width, 16);
        expect(phy.output('gt_CPLLRESET').width, 1);
        expect(phy.definitionName, contains(gen2 ? '_G2' : 'X1_'));
      });
    }

    for (final reg in [true, false]) {
      test('registerMmcmLock $reg picks the lock source', () async {
        final phy = HarborGtxPciePhy(
          perstN: Logic(name: 'perst_n'),
          channel: HarborGtxChannelPorts(),
          pipe: HarborPciePipeLane(),
          registerMmcmLock: reg,
          timeouts: const HarborGtxPcieTimeouts(linkWait: 0),
        );
        await phy.build();
        final sv = phy.dumpSystemVerilog();
        expect(sv.contains('HarborPipeClock_U8_G2_Oob_R'), reg);
        expect(sv, contains('HarborPipeClock_U8_G2_Oob'));
        expect(phy.definitionName.contains('DirectLock'), !reg);
      });
    }

    test('PERST# low resets the MMCM', () async {
      final perstN = Logic(name: 'perst_n');
      final phy = HarborGtxPciePhy(
        perstN: perstN,
        hardLinkUp: Logic(),
        phyLinkUpN: Logic(),
        ltssmState: Logic(width: 6),
        channel: HarborGtxChannelPorts(),
        pipe: HarborPciePipeLane(),
      );
      await phy.build();
      Module? mmcm;
      void find(Module m) {
        for (final sub in m.subModules) {
          if (sub.definitionName == 'MMCME2_ADV') mmcm = sub;
          find(sub);
        }
      }

      find(phy);
      final rst = mmcm!.input('RST');
      final seen = <int>[];
      Simulator.registerAction(1, () => perstN.put(0));
      Simulator.registerAction(2, () => seen.add(rst.value.toInt()));
      Simulator.registerAction(3, () => perstN.put(1));
      Simulator.registerAction(4, () => seen.add(rst.value.toInt()));
      await Simulator.run();
      expect(seen, [1, 0]);
    });
  });
}
