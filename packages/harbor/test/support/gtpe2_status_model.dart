/// A scripted model of the GTPE2 status outputs for PHY tests.
library;

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';

/// Drives the status outputs of one GTPE2_COMMON, the GTPE2_CHANNELs and the
/// MMCM lock from the controls the PHY gives. All delays are in `pclk`
/// cycles. The model changes its outputs on the falling edge of `pclk`.
class Gtpe2StatusModel {
  final Logic pclk;
  final HarborGtpCommonPorts common;
  final List<HarborGtpChannelPorts> channels;

  /// MMCM lock into the PHY.
  final Logic mmcmLock = Logic(name: 'model_mmcm_lock');

  /// Cycles from the start, or from PLL0RESET low, to PLL0LOCK.
  int pllLockDelay;

  /// When true, PLL0LOCK stays low.
  bool pllStuck = false;

  /// Cycles from the start to the MMCM lock.
  int mmcmLockDelay;

  /// Cycles from GT reset low, PLL lock and USERRDY to reset done.
  int resetDoneDelay;

  /// Cycles from GTRXRESET low to RXPMARESETDONE high.
  int pmaRiseDelay;

  /// Cycles that RXPMARESETDONE stays high. Null keeps it high.
  int? pmaHighCycles;

  /// Cycles from a TX sync request to its done.
  int syncDelay;

  /// Cycles from a rate or power change to the done pulses.
  int changeDelay;

  /// When true, the GT does not answer a rate change.
  bool rateStuck = false;

  /// When true, TXPHALIGNDONE never rises.
  bool phAlignStuck = false;

  /// RXVALID while the GT is out of reset.
  bool rxValidOn = true;

  /// RXRESETDONE follows the modelled reset sequence.
  bool rxResetDoneOn = true;

  /// PHYSTATUS stays high during startup.
  bool startupPhyStatusStuck = false;

  /// Number of TX sync runs that completed.
  int txSyncRuns = 0;

  /// Number of rising edges of RXPMARESETDONE.
  int pmaPulses = 0;

  bool _stop = false;
  int _cycle = 0;
  int _pllCount = 0;
  int _pllDropUntil = -1;
  int _mmcmDropUntil = -1;
  int _mmcmCount = 0;
  int _gtCount = 0;
  int _rdCount = 0;
  bool _pmaWasHigh = false;
  int _dlyCount = -1;
  int _phInitCount = -1;
  int _phAlignCount = -1;
  int _phAlignPulse = 0;
  int _dlyEnCount = -1;
  int _lastRate = 0;
  int _lastPd = 0;
  int _changeCount = -1;
  bool _changeIsRate = false;
  bool _drpPending = false;
  bool _drpPendingWrite = false;
  int _drpPendingData = 0;
  int _drp011 = 0xaffe;

  Gtpe2StatusModel(
    this.pclk,
    this.common,
    this.channels, {
    this.pllLockDelay = 20,
    this.mmcmLockDelay = 10,
    this.resetDoneDelay = 12,
    this.pmaRiseDelay = 4,
    this.pmaHighCycles = 6,
    this.syncDelay = 5,
    this.changeDelay = 6,
  }) {
    common.port('PLL0LOCK').inject(0);
    mmcmLock.inject(0);
    for (final ch in channels) {
      for (final p in [
        'TXOUTCLK',
        'TXRESETDONE',
        'RXRESETDONE',
        'RXPMARESETDONE',
        'TXDLYSRESETDONE',
        'TXPHINITDONE',
        'TXPHALIGNDONE',
        'TXRATEDONE',
        'RXRATEDONE',
        'PHYSTATUS',
        'RXVALID',
        'RXELECIDLE',
        'RXCHANISALIGNED',
        'RXSYNCOUT',
        'RXSTATUS',
        'RXDATA',
        'RXCHARISK',
        'DRPDO',
        'DRPRDY',
      ]) {
        ch.port(p).inject(0);
      }
      ch.port('PHYSTATUS').inject(1);
      ch.port('RXELECIDLE').inject(1);
    }
  }

  /// Starts the model. Call after the simulation runs.
  void start() => unawaited(_run());

  /// Stops the model.
  void stop() => _stop = true;

  /// PLL0LOCK goes low for [cycles], then the PLL locks again after its delay.
  void dropPllLock(int cycles) => _pllDropUntil = _cycle + cycles;

  /// The MMCM lock goes low for [cycles].
  void dropMmcmLock(int cycles) => _mmcmDropUntil = _cycle + cycles;

  /// Sets RXELECIDLE on all lanes.
  void setRxElecIdle(bool idle) {
    for (final ch in channels) {
      ch.port('RXELECIDLE').put(idle ? 1 : 0);
    }
  }

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
    final ch0 = channels[0];

    ch0.port('DRPRDY').put(_drpPending ? 1 : 0);
    ch0.port('DRPDO').put(_drp011);
    if (_drpPending && _drpPendingWrite) _drp011 = _drpPendingData;
    _drpPending = _hi(ch0.port('DRPEN'));
    _drpPendingWrite = _hi(ch0.port('DRPWE'));
    _drpPendingData = _int(ch0.port('DRPDI'));

    // PLL0: PLL0RESET clears the lock. The count restarts after a drop.
    var pllLocked = false;
    if (_hi(common.port('PLL0RESET')) || _cycle < _pllDropUntil) {
      _pllCount = 0;
    } else {
      _pllCount++;
      pllLocked = !pllStuck && _pllCount >= pllLockDelay;
    }
    common.port('PLL0LOCK').put(pllLocked ? 1 : 0);

    var mmcmLocked = false;
    if (_cycle < _mmcmDropUntil) {
      _mmcmCount = 0;
    } else {
      _mmcmCount++;
      mmcmLocked = _mmcmCount >= mmcmLockDelay;
    }
    mmcmLock.put(mmcmLocked ? 1 : 0);

    final gtReset = _hi(ch0.port('GTTXRESET')) || _hi(ch0.port('GTRXRESET'));
    final userRdy = _hi(ch0.port('TXUSERRDY')) && _hi(ch0.port('RXUSERRDY'));

    // RXPMARESETDONE: high some cycles after GTRXRESET low.
    _gtCount = gtReset ? 0 : _gtCount + 1;
    final hc = pmaHighCycles;
    final pmaHigh =
        !gtReset &&
        _gtCount >= pmaRiseDelay &&
        (hc == null || _gtCount < pmaRiseDelay + hc);
    if (pmaHigh && !_pmaWasHigh) pmaPulses++;
    _pmaWasHigh = pmaHigh;

    // TX and RX reset done.
    if (gtReset || !pllLocked || !userRdy) {
      _rdCount = 0;
    } else {
      _rdCount++;
    }
    final resetDone = _rdCount >= resetDoneDelay;
    // PHYSTATUS stays high until two cycles after reset done.
    final phyReset = startupPhyStatusStuck || _rdCount < resetDoneDelay + 2;

    // TX sync. Each done follows its request after the sync delay.
    bool after(Logic req, int count) => _hi(req) && count >= syncDelay;
    _dlyCount = _hi(ch0.port('TXDLYSRESET')) ? _dlyCount + 1 : -1;
    _phInitCount = _hi(ch0.port('TXPHINIT')) ? _phInitCount + 1 : -1;
    _phAlignCount = _hi(ch0.port('TXPHALIGN')) ? _phAlignCount + 1 : -1;
    _dlyEnCount = _hi(ch0.port('TXDLYEN')) && !_hi(ch0.port('TXPHALIGN'))
        ? _dlyEnCount + 1
        : -1;
    final dlyDone = after(ch0.port('TXDLYSRESET'), _dlyCount);
    final phInitDone = after(ch0.port('TXPHINIT'), _phInitCount);
    // TXPHALIGNDONE: a two cycle pulse in TXPHALIGN, then high in TXDLYEN.
    if (_phAlignCount == syncDelay) _phAlignPulse = 2;
    final alignPulse = _phAlignPulse > 0;
    if (_phAlignPulse > 0) _phAlignPulse--;
    final alignLevel = _dlyEnCount >= syncDelay;
    if (_dlyEnCount == syncDelay) txSyncRuns++;
    final phAlignDone = !phAlignStuck && (alignPulse || alignLevel);

    // Rate and power changes give TXRATEDONE, RXRATEDONE and PHYSTATUS.
    final rate = _int(ch0.port('TXRATE'));
    final pd = _int(ch0.port('TXPD'));
    if (rate != _lastRate || pd != _lastPd) {
      _changeIsRate = rate != _lastRate;
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

    for (final ch in channels) {
      ch.port('RXPMARESETDONE').put(pmaHigh ? 1 : 0);
      ch.port('TXRESETDONE').put(resetDone ? 1 : 0);
      ch.port('RXRESETDONE').put(resetDone && rxResetDoneOn ? 1 : 0);
      ch.port('PHYSTATUS').put(phyReset || changePulse ? 1 : 0);
      ch.port('TXDLYSRESETDONE').put(dlyDone ? 1 : 0);
      ch.port('TXPHINITDONE').put(phInitDone ? 1 : 0);
      ch.port('TXPHALIGNDONE').put(phAlignDone ? 1 : 0);
      ch.port('TXRATEDONE').put(ratePulse ? 1 : 0);
      ch.port('RXRATEDONE').put(ratePulse ? 1 : 0);
      ch.port('RXVALID').put(rxValidOn && resetDone ? 1 : 0);
      ch.port('RXCHANISALIGNED').put(resetDone ? 1 : 0);
    }
  }
}
