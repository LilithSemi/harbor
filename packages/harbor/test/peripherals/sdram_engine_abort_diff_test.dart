import 'dart:async';
import 'dart:collection';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_stack.dart';
import 'sdram_phy_ecp5_harness.dart' show sdramPhyCaptureOk;
import 'sdram_pin_model.dart';

int _addr(HarborSdramConfig c, int bank, int row, int col) =>
    c.addressMap == HarborSdramAddressMap.rowBankCol
    ? (((row << c.bankBits) | bank) << c.colWidth) | col
    : (((bank << c.rowWidth) | row) << c.colWidth) | col;

HarborSdramConfig _buildConfig() {
  const base = HarborSdramConfig.as4c16m16sb6();
  return base.copyWith(timing: base.timing.copyWith(powerUpNs: 2000));
}

/// One request this test drives into a port. A write carries its words, a
/// read only its length: this test checks command timing, not data.
class _Op {
  _Op.write(this.addr, List<int> words)
    : write = true,
      length = words.length,
      words = words;
  _Op.read(this.addr, this.length) : write = false, words = const [];

  final bool write;
  final int addr;
  final int length;
  final List<int> words;
}

/// Drives one [SdramPortInterface] with a FIFO of [_Op]s: offers req_valid
/// until req_ready takes it, and wr_valid word by word. Mirrors
/// [SdramEngineStack]'s own port driver, trimmed to one port and with no
/// read scoreboard.
class _PortDriver {
  _PortDriver(this.iface) {
    for (final s in [
      iface.reqValid,
      iface.reqWrite,
      iface.reqAddr,
      iface.reqWords,
      iface.reqPort,
      iface.wrValid,
      iface.wrData,
      iface.wrMask,
    ]) {
      s.inject(0);
    }
  }

  final SdramPortInterface iface;
  final Queue<_Op> _toSend = Queue();
  final Queue<(int, int)> _wrWords = Queue();
  _Op? _pending;

  void enqueue(_Op op) {
    _toSend.add(op);
    if (op.write) {
      for (final w in op.words) {
        _wrWords.add((w & 0xFFFF, 3));
      }
    }
  }

  bool get idle => _pending == null && _toSend.isEmpty && _wrWords.isEmpty;

  void drive() {
    if (_pending == null && _toSend.isNotEmpty) {
      _pending = _toSend.removeFirst();
    }
    final req = _pending;
    if (req != null) {
      iface.reqValid.put(1);
      iface.reqWrite.put(req.write ? 1 : 0);
      iface.reqAddr.put(req.addr);
      iface.reqWords.put(req.length);
    } else {
      iface.reqValid.put(0);
    }
    if (_wrWords.isNotEmpty) {
      final (data, mask) = _wrWords.first;
      iface.wrValid.put(1);
      iface.wrData.put(data);
      iface.wrMask.put(mask);
    } else {
      iface.wrValid.put(0);
    }
  }

  void sample() {
    if (_pending != null && iface.reqReady.value == LogicValue.one) {
      _pending = null;
    }
    if (iface.wrReady.value == LogicValue.one && _wrWords.isNotEmpty) {
      _wrWords.removeFirst();
    }
  }
}

SdramPinModel _buildModel(SdramEngineStackTop top, LogicNet dqPad) {
  final bbs = {
    for (final m in top.phy.subModules.whereType<Ecp5Bb>()) m.name: m,
  };
  final dqBbs = [for (var i = 0; i < 16; i++) bbs['dq_bb_$i']!];
  return SdramPinModel(
    clk: top.phy.oSdramClk,
    cke: top.phy.oSdramCke,
    csN: top.phy.oSdramCsN,
    rasN: top.phy.oSdramRasN,
    casN: top.phy.oSdramCasN,
    weN: top.phy.oSdramWeN,
    ba: top.phy.oSdramBa,
    addr: top.phy.oSdramAddr,
    dqm: top.phy.oSdramDqm,
    dq: dqPad,
    rules: const SdramModelRules.as4c16m16sb6().copyWith(powerUpNs: 2000),
    fpgaToSdramNs: 4.6,
    fpgaDqOe: [for (final bb in dqBbs) ~bb.input('T')].rswizzle(),
    fpgaDqOut: [for (final bb in dqBbs) bb.input('I')].rswizzle(),
  );
}

void main() {
  tearDown(() async => Simulator.reset());

  test('abortNext flopped the way HarborSdram does matches the direct '
      'standalone abort gate, command for command', () async {
    const clockHz = 125000000;
    final config = _buildConfig();
    final cycles = HarborSdramCycles(
      config,
      clockHz: clockHz,
      maxPostponedRefresh: 8,
      maxPulledInRefresh: 8,
      phyMaxClockHz: SdramPhyEcp5.maxClockHzLvcmos33,
    );
    final periodPs = 1000000000000 ~/ clockHz;
    expect(
      sdramPhyCaptureOk(
        periodPs: periodPs,
        tAcNs: cycles.casLatency == 3 ? 5.0 : 6.0,
        fpgaToSdramNs: 4.6,
        phy: const HarborSdramPhyConfig(),
      ),
      isTrue,
      reason: 'fpgaToSdramNs must land inside the capture window',
    );

    final clk = SimpleClockGenerator(periodPs).clk;
    final reset = Logic(name: 'reset');

    // The one abort schedule this test controls. [dIn] is the D input of
    // the shared flop, so the registered [absAbort] it drives is the
    // exact same net both engines see on `abort`. The new (abortNext)
    // engine also reads [dIn] itself on `abort_next`: that is exactly
    // the D input HarborSdram's own engine_abort flop uses, so
    // abort(t+1) == abortNext(t) holds by construction and this is an
    // honest comparison, not matching numbers by coincidence.
    final dIn = Logic(name: 'abort_d_in')..inject(0);
    final absAbort = Ecp5Fd1s3bx(
      d: dIn,
      ck: clk,
      pd: Const(0),
      name: 'abort_reg',
    ).q;

    final portOld = SdramPortInterface(
      addrWidth: 24,
      wordsWidth: 7,
      portIdWidth: 1,
    );
    final portNew = SdramPortInterface(
      addrWidth: 24,
      wordsWidth: 7,
      portIdWidth: 1,
    );
    final dqPadOld = LogicNet(name: 'dq_pad_old', width: 16);
    final dqPadNew = LogicNet(name: 'dq_pad_new', width: 16);

    reset.inject(1);

    // The old, standalone-engine gate: abortNext is null, so the engine
    // reads `abort` straight in the pick, the way every other engine
    // test in this suite already builds it.
    final topOld = SdramEngineStackTop(
      config,
      cycles,
      clk: clk,
      reset: reset,
      ports: [portOld],
      dqPad: dqPadOld,
      maxGrantWords: 16,
      abort: absAbort,
    );
    // The new, HarborSdram-shaped gate: abortNext drives the register
    // fold, and `abort` is the flopped copy, exactly as _build() in
    // harbor_sdram.dart wires engine_abort.
    final topNew = SdramEngineStackTop(
      config,
      cycles,
      clk: clk,
      reset: reset,
      ports: [portNew],
      dqPad: dqPadNew,
      maxGrantWords: 16,
      abort: absAbort,
      abortNext: dIn,
    );
    await topOld.build();
    await topNew.build();

    final pinOld = _buildModel(topOld, dqPadOld);
    final pinNew = _buildModel(topNew, dqPadNew);
    final driverOld = _PortDriver(portOld);
    final driverNew = _PortDriver(portNew);

    clk.negedge.listen((_) {
      driverOld.drive();
      driverNew.drive();
      driverOld.sample();
      driverNew.sample();
    });

    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    reset.put(0);
    while (topOld.engine.initDone.value != LogicValue.one ||
        topNew.engine.initDone.value != LogicValue.one) {
      await clk.nextPosedge;
    }

    // One case: a row miss, a 4-beat read, a lookahead activate and a
    // 2-word read starting at column 7, with abort pulsed for [width]
    // cycles starting at cycle [offset] counted from the prime write.
    // Returns the number of negedges the case used.
    Future<int> runCase(int offset, int width) async {
      var i = 0;
      var cap = 0;
      void pulse() => dIn.put(i >= offset && i < offset + width ? 1 : 0);

      Future<void> waitIdle() async {
        while (!(driverOld.idle && driverNew.idle)) {
          pulse();
          await clk.nextNegedge;
          i++;
          cap++;
          if (cap > 5000) {
            throw StateError(
              'case offset $offset width $width: '
              'driver never drained',
            );
          }
        }
      }

      Future<void> settle(int n) async {
        for (var k = 0; k < n; k++) {
          pulse();
          await clk.nextNegedge;
          i++;
        }
      }

      // Prime: opens bank 0, row 5. Drained on its own so the next
      // request is a genuine row miss, not a plain activate from closed.
      driverOld.enqueue(_Op.write(_addr(config, 0, 5, 0), const [0x1111]));
      driverNew.enqueue(_Op.write(_addr(config, 0, 5, 0), const [0x1111]));
      await waitIdle();
      await settle(20);

      // A row miss (bank 0, row 5 -> row 12) and a 4-beat read, with a
      // lookahead activate on bank 1 queued right behind it, and a
      // 2-word read starting at column 7.
      driverOld.enqueue(_Op.read(_addr(config, 0, 12, 0), 4));
      driverNew.enqueue(_Op.read(_addr(config, 0, 12, 0), 4));
      driverOld.enqueue(_Op.read(_addr(config, 1, 9, 7), 2));
      driverNew.enqueue(_Op.read(_addr(config, 1, 9, 7), 2));
      await waitIdle();
      await settle(60);

      dIn.put(0);
      return i;
    }

    // A dry run with no abort, to size the sweep.
    final span = await runCase(1 << 30, 0);

    for (final width in [1, 4]) {
      for (var offset = 0; offset < span; offset++) {
        final beforeLogOld = pinOld.log.length;
        final beforeLogNew = pinNew.log.length;
        final beforeErrOld = pinOld.errors.length;
        final beforeErrNew = pinNew.errors.length;

        await runCase(offset, width);

        expect(
          pinOld.errors.length,
          beforeErrOld,
          reason:
              'offset $offset width $width: old pin model rule, '
              '${pinOld.errors.skip(beforeErrOld)}',
        );
        expect(
          pinNew.errors.length,
          beforeErrNew,
          reason:
              'offset $offset width $width: new pin model rule, '
              '${pinNew.errors.skip(beforeErrNew)}',
        );

        final logOld = pinOld.log.skip(beforeLogOld).toList();
        final logNew = pinNew.log.skip(beforeLogNew).toList();
        expect(
          logNew.length,
          logOld.length,
          reason: 'offset $offset width $width: command count differs',
        );
        for (var k = 0; k < logOld.length; k++) {
          final a = logOld[k];
          final b = logNew[k];
          expect(
            (b.timePs, b.kind, b.bank, b.a),
            (a.timePs, a.kind, a.bank, a.a),
            reason: 'offset $offset width $width: command $k differs',
          );
        }
      }
    }

    pinOld.finish();
    pinNew.finish();
    expect(pinOld.errors, isEmpty);
    expect(pinNew.errors, isEmpty);
    await Simulator.endSimulation();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
