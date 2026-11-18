/// A scripted model of the GTXE2 status outputs for PHY tests.
library;

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';

/// Drives the status outputs of one GTXE2_CHANNEL and the MMCM lock from the
/// controls the PHY gives. All delays are in `pclk` cycles. The model changes
/// its outputs on the falling edge of `pclk`.
class Gtxe2StatusModel {
  final Logic pclk;
  final HarborGtxChannelPorts channel;

  /// MMCM lock into the PHY.
  final Logic mmcmLock = Logic(name: 'model_mmcm_lock');

  /// Cycles from CPLLRESET low to CPLLLOCK.
  int cpllLockDelay;

  /// When true, CPLLLOCK stays low.
  bool cpllStuck = false;

  /// Cycles from GT reset low to RXCDRLOCK.
  int cdrLockDelay;

  /// When true, RXCDRLOCK stays low.
  bool cdrStuck = false;

  /// Cycles from the start to the MMCM lock.
  int mmcmLockDelay;

  /// When true, the MMCM lock stays low.
  bool mmcmStuck = false;

  /// Cycles from GT reset low, CPLL lock and USERRDY to reset done.
  int resetDoneDelay;

  /// When true, TXRESETDONE and RXRESETDONE stay low.
  bool resetDoneStuck = false;

  /// Cycles from a TX sync request to its done.
  int syncDelay;

  /// Cycles from a rate or power change to the done pulses.
  int changeDelay;

  /// When true, the GT does not answer a rate change.
  bool rateStuck = false;

  /// When true, TXPHALIGNDONE never rises.
  bool phAlignStuck = false;

  /// When true, TXDLYSRESETDONE and TXPHINITDONE are one cycle pulses and
  /// TXPHALIGNDONE is one cycle pulse after TXPHALIGN and another one after
  /// TXDLYEN, as in the manual TX buffer bypass of UG476. Otherwise each done
  /// stays high while its request stays high.
  bool pulseDones = false;

  /// When true, the test drives RXVALID, as a link partner does.
  bool rxValidExternal = false;

  /// RXVALID while the GT is out of reset.
  bool rxValidOn = true;

  /// RXCHANISALIGNED while the GT is out of reset.
  bool chanAlignedOn = true;

  /// Number of TX sync runs that completed.
  int txSyncRuns = 0;

  /// The TXRATE values in the order that they appeared, from 0.
  final List<int> txRates = [0];

  bool _stop = false;
  int _cycle = 0;
  int _cpllCount = 0;
  int _cpllDropUntil = -1;
  int _mmcmDropUntil = -1;
  int _mmcmCount = 0;
  int _gtCount = 0;
  int _rdCount = 0;
  int _dlyCount = -1;
  int _phInitCount = -1;
  int _phAlignCount = -1;
  int _phAlignPulse = 0;
  int _dlyEnCount = -1;
  int _lastRate = 0;
  int _lastPd = 0;
  int _changeCount = -1;
  bool _changeIsRate = false;
  bool _detPrev = false;
  int _detCount = -1;

  Gtxe2StatusModel(
    this.pclk,
    this.channel, {
    this.cpllLockDelay = 20,
    this.cdrLockDelay = 8,
    this.mmcmLockDelay = 10,
    this.resetDoneDelay = 12,
    this.syncDelay = 5,
    this.changeDelay = 6,
  }) {
    mmcmLock.inject(0);
    for (final p in [
      'TXOUTCLK',
      'CPLLLOCK',
      'RXCDRLOCK',
      'RXBYTEISALIGNED',
      'TXRESETDONE',
      'RXRESETDONE',
      'TXDLYSRESETDONE',
      'TXPHINITDONE',
      'TXPHALIGNDONE',
      'TXRATEDONE',
      'RXRATEDONE',
      'PHYSTATUS',
      'RXVALID',
      'RXELECIDLE',
      'RXCHANISALIGNED',
      'RXSTATUS',
      'RXDATA',
      'RXCHARISK',
    ]) {
      channel.port(p).inject(0);
    }
    channel.port('PHYSTATUS').inject(1);
    channel.port('RXELECIDLE').inject(1);
  }

  /// Starts the model. Call after the simulation runs.
  void start() => unawaited(_run());

  /// Stops the model.
  void stop() => _stop = true;

  /// CPLLLOCK goes low for [cycles], then the CPLL locks again after its
  /// delay.
  void dropCpllLock(int cycles) => _cpllDropUntil = _cycle + cycles;

  /// The MMCM lock goes low for [cycles].
  void dropMmcmLock(int cycles) => _mmcmDropUntil = _cycle + cycles;

  bool _hi(Logic l) => l.value.isValid && l.value.toBool();
  int _int(Logic l) => l.value.isValid ? l.value.toInt() : 0;

  Future<void> _run() async {
    while (!_stop) {
      await pclk.nextNegedge;
      _cycle++;
      _step();
    }
  }

  void _step() {
    final ch = channel;

    // CPLL: CPLLRESET clears the lock. The count restarts after a drop.
    var cpllLocked = false;
    if (_hi(ch.port('CPLLRESET')) || _cycle < _cpllDropUntil) {
      _cpllCount = 0;
    } else {
      _cpllCount++;
      cpllLocked = !cpllStuck && _cpllCount >= cpllLockDelay;
    }
    ch.port('CPLLLOCK').put(cpllLocked ? 1 : 0);

    var mmcmLocked = false;
    if (_cycle < _mmcmDropUntil) {
      _mmcmCount = 0;
    } else {
      _mmcmCount++;
      mmcmLocked = !mmcmStuck && _mmcmCount >= mmcmLockDelay;
    }
    mmcmLock.put(mmcmLocked ? 1 : 0);

    final gtReset = _hi(ch.port('GTTXRESET')) || _hi(ch.port('GTRXRESET'));
    final userRdy = _hi(ch.port('TXUSERRDY')) && _hi(ch.port('RXUSERRDY'));

    // RXCDRLOCK: high some cycles after the GT resets are low.
    _gtCount = gtReset ? 0 : _gtCount + 1;
    final cdrLocked = !cdrStuck && _gtCount >= cdrLockDelay;

    // TX and RX reset done.
    if (gtReset || !cpllLocked || !userRdy || resetDoneStuck) {
      _rdCount = 0;
    } else {
      _rdCount++;
    }
    final resetDone = _rdCount >= resetDoneDelay;
    // PHYSTATUS stays high until two cycles after reset done.
    final phyReset = _rdCount < resetDoneDelay + 2;

    // TX sync. Each done follows its request after the sync delay.
    bool after(Logic req, int count) => _hi(req) && count >= syncDelay;
    _dlyCount = _hi(ch.port('TXDLYSRESET')) ? _dlyCount + 1 : -1;
    _phInitCount = _hi(ch.port('TXPHINIT')) ? _phInitCount + 1 : -1;
    _phAlignCount = _hi(ch.port('TXPHALIGN')) ? _phAlignCount + 1 : -1;
    _dlyEnCount = _hi(ch.port('TXDLYEN')) && !_hi(ch.port('TXPHALIGN'))
        ? _dlyEnCount + 1
        : -1;
    final dlyDone = pulseDones
        ? _dlyCount == syncDelay
        : after(ch.port('TXDLYSRESET'), _dlyCount);
    final phInitDone = pulseDones
        ? _phInitCount == syncDelay
        : after(ch.port('TXPHINIT'), _phInitCount);
    // TXPHALIGNDONE: a two cycle pulse in TXPHALIGN, then high in TXDLYEN.
    if (_phAlignCount == syncDelay) _phAlignPulse = pulseDones ? 1 : 2;
    final alignPulse = _phAlignPulse > 0;
    if (_phAlignPulse > 0) _phAlignPulse--;
    final alignLevel = pulseDones
        ? _dlyEnCount == syncDelay
        : _dlyEnCount >= syncDelay;
    if (_dlyEnCount == syncDelay) txSyncRuns++;
    final phAlignDone = !phAlignStuck && (alignPulse || alignLevel);

    // Rate and power changes give TXRATEDONE, RXRATEDONE and PHYSTATUS.
    final rate = _int(ch.port('TXRATE'));
    final pd = _int(ch.port('TXPD'));
    if (rate != _lastRate || pd != _lastPd) {
      _changeIsRate = rate != _lastRate;
      if (_changeIsRate) txRates.add(rate);
      _changeCount = 0;
      _lastRate = rate;
      _lastPd = pd;
    } else if (_changeCount >= 0) {
      _changeCount++;
    }
    final changePulse =
        _changeCount == changeDelay && !(rateStuck && _changeIsRate);
    if (_changeCount > changeDelay) _changeCount = -1;
    final ratePulse = changePulse && _changeIsRate;

    // Receiver detect: TXDETECTRX rising gives PHYSTATUS and RXSTATUS 011 on
    // the same cycle.
    final det = _hi(ch.port('TXDETECTRX'));
    if (det && !_detPrev) _detCount = 0;
    _detPrev = det;
    final detectPulse = _detCount == changeDelay;
    if (_detCount >= 0) _detCount++;
    if (_detCount > changeDelay) _detCount = -1;
    ch.port('RXCDRLOCK').put(cdrLocked ? 1 : 0);
    // A power change gives RXSTATUS 3'b011 on the cycle of its PHYSTATUS.
    ch
        .port('RXSTATUS')
        .put(detectPulse || (changePulse && !_changeIsRate) ? 3 : 0);
    ch.port('TXRESETDONE').put(resetDone ? 1 : 0);
    ch.port('RXRESETDONE').put(resetDone ? 1 : 0);
    ch.port('PHYSTATUS').put(phyReset || changePulse || detectPulse ? 1 : 0);
    ch.port('TXDLYSRESETDONE').put(dlyDone ? 1 : 0);
    ch.port('TXPHINITDONE').put(phInitDone ? 1 : 0);
    ch.port('TXPHALIGNDONE').put(phAlignDone ? 1 : 0);
    ch.port('TXRATEDONE').put(ratePulse ? 1 : 0);
    ch.port('RXRATEDONE').put(ratePulse ? 1 : 0);
    if (!rxValidExternal) {
      ch.port('RXVALID').put(rxValidOn && resetDone ? 1 : 0);
    }
    ch.port('RXCHANISALIGNED').put(resetDone && chanAlignedOn ? 1 : 0);
  }
}
