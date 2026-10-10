import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:harbor/src/peripherals/sdram_bank_timers.dart';
import 'package:harbor/src/peripherals/sdram_engine.dart' show
    debugSdramEngineWithoutRowAgeGuard;
import 'package:harbor/src/peripherals/sdram_refresh.dart';
import 'package:rohd/rohd.dart';

import 'sdram_phy_ecp5_harness.dart';
import 'sdram_pin_model.dart';

/// [SdramArbiter], [SdramEngine] and [SdramPhyEcp5] in one module, so the
/// stack builds as one hierarchy. [ports] is one or more client ports. The
/// arbiter sits between them and the engine, the way a real build always
/// has it, so a one-port run also proves the arbiter is a clean passthrough.
class SdramEngineStackTop extends Module {
  late final SdramEngine engine;
  late final SdramArbiter arbiter;
  late final SdramPhyEcp5 phy;

  SdramEngineStackTop(
    HarborSdramConfig config,
    HarborSdramCycles cycles, {
    required Logic clk,
    required Logic reset,
    required List<SdramPortInterface> ports,
    required LogicNet dqPad,
    required int maxGrantWords,
    List<int>? portMaxGrantWords,
    bool rowAgeGuard = true,
  }) : super(name: 'sdram_engine_stack') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final outer = [
      for (var i = 0; i < ports.length; i++)
        ports[i].clone()..pairConnectIO(
          this,
          ports[i],
          PairRole.provider,
          uniquify: (n) => 'p${i}_$n',
        ),
    ];
    final dq = addInOut('sdram_dq', dqPad, width: config.dataWidth);

    Logic w(String n, [int width = 1]) => Logic(name: n, width: width);
    final cke = w('cke'), csN = w('cs_n'), rasN = w('ras_n');
    final casN = w('cas_n'), weN = w('we_n');
    final ba = w('ba', config.bankBits), addr = w('addr', config.rowWidth);
    final dqm = w('dqm', 2), dqOut = w('dq_out', 16), dqOe = w('dq_oe', 16);

    phy = SdramPhyEcp5(
      config,
      casLatency: cycles.casLatency,
      clk: clk,
      reset: reset,
      cke: cke,
      csN: csN,
      rasN: rasN,
      casN: casN,
      weN: weN,
      ba: ba,
      addr: addr,
      dqm: dqm,
      dqOut: dqOut,
      dqOe: dqOe,
      dqPad: dq,
    );

    // A bare port sitting only between the arbiter and the engine, the
    // way the arbiter's own request register sits only between a client
    // and the engine.
    final enginePort = SdramPortInterface(
      addrWidth: ports[0].addrWidth,
      wordsWidth: ports[0].wordsWidth,
      portIdWidth: ports[0].portIdWidth,
      wrLookahead: true,
    );

    engine = rowAgeGuard
        ? SdramEngine(
            config,
            cycles,
            clk: clk,
            reset: reset,
            port: enginePort,
            phyRdData: phy.rdData,
            phyReadLatency: phy.readLatency,
            maxGrantWords: maxGrantWords,
          )
        : debugSdramEngineWithoutRowAgeGuard(
            config,
            cycles,
            clk: clk,
            reset: reset,
            port: enginePort,
            phyRdData: phy.rdData,
            phyReadLatency: phy.readLatency,
            maxGrantWords: maxGrantWords,
          );
    arbiter = SdramArbiter(
      clk: clk,
      reset: reset,
      ports: outer,
      configs: [
        for (var i = 0; i < outer.length; i++)
          HarborSdramPortConfig(
            name: 'p$i',
            maxGrantWords: portMaxGrantWords?[i] ?? maxGrantWords,
          ),
      ],
      engine: enginePort,
    );

    cke <= engine.phyCke;
    csN <= engine.phyCsN;
    rasN <= engine.phyRasN;
    casN <= engine.phyCasN;
    weN <= engine.phyWeN;
    ba <= engine.phyBa;
    addr <= engine.phyAddr;
    dqm <= engine.phyDqm;
    dqOut <= engine.phyDqOut;
    dqOe <= engine.phyDqOe;
  }
}

/// Command kinds in cs#/ras#/cas#/we# encoding order, cmd3 = (ras << 2) |
/// (cas << 1) | we. Index 7 (nop while selected) is never logged, the
/// same rule [SdramPinModel] uses on the pins.
const _engineCmdKinds = [
  'mrs',
  'refresh',
  'precharge',
  'activate',
  'write',
  'read',
  'burst-stop',
  'nop',
];

class _Req {
  _Req(this.write, this.addr, this.words, this.expected);

  final bool write;
  final int addr, words;
  final List<int> expected;
  final List<int> got = [];
  final Completer<List<int>> done = Completer();
}

/// Engine, ecp5 phy, the arbiter and [SdramPinModel], with one Dart port
/// driver per client port. Each driver changes its port's inputs on clk
/// negedges and keeps a scoreboard seeded with [SdramPinModel.initialWord].
class SdramEngineStack {
  final int clockHz;
  final HarborSdramConfig config;
  final HarborSdramCycles cycles;
  final double fpgaToSdramNs;
  final int maxGrantWords;
  final bool fastInit;

  /// Number of client ports the arbiter serves. 1 by default.
  final int ports;

  /// Per-port request limits for the arbiter, or null for [maxGrantWords].
  final List<int>? portMaxGrantWords;

  /// Off only for the row-age negative test: a real build never does this.
  final bool rowAgeGuard;

  /// A shorter tRAS max for both the engine and the model, or null.
  final double? tRasMaxNs;

  late final SdramEngineStackTop top;
  late final SdramPinModel model;
  late final Logic clk;
  final Logic reset = Logic(name: 'reset');
  late final List<SdramPortInterface> portIfaces;

  /// Port 0, kept for callers that only ever used one port.
  SdramPortInterface get port => portIfaces[0];

  final List<String> _errors = [];
  late final List<Queue<_Req>> _toSend;
  late final List<Queue<(int, int, _Req)>> _wrData;
  late final List<Queue<_Req>> _reads;

  /// The request currently offered on `req_valid` for each port, held
  /// until `req_ready` takes it: through an arbiter, `req_ready` can
  /// depend on `req_valid` already being high, so a driver must not wait
  /// to see `req_ready` before raising `req_valid` in the first place.
  late final List<_Req?> _pendingReq;
  final Map<int, int> _mem = {};
  int _cycle = 0;
  int _pending = 0;

  /// Write words queued on any port, and words the engine itself took.
  /// The arbiter buffers words, so a client sees its write done before
  /// the engine issues it.
  int _wordsQueued = 0, _wordsIssued = 0;

  /// The running simulation. It completes with an error if the engine
  /// stops it, for example on a bad request.
  late final Future<void> simRun;

  /// The most requests other ports had granted while one port waited
  /// with `req_valid` high.
  int maxOtherGrants = 0;
  late final List<int> _otherGrants = List.filled(ports, 0);

  /// Rising edges of the refresh credit force and the row-age force.
  int forceEdges = 0, rowAgeEdges = 0;

  /// Every command decoded from the engine's own phy_* wires, before the
  /// PHY's fabric pad stage and output register: (time in ps, kind, bank,
  /// address field). Same cs#/ras#/cas#/we# decode as [SdramPinModel],
  /// run one stage earlier, so a test can tell the engine's own command
  /// timing apart from the PHY's output delay.
  final List<(int, String, int, int)> engineCommandLog = [];

  /// Every model error and scoreboard error so far.
  List<String> get errors => [...model.errors, ..._errors];

  /// Requests queued and not done yet, on every port.
  int get pending => _pending;

  /// Controller cycles since [start] began.
  int get cycle => _cycle;

  SdramEngineStack({
    required this.clockHz,
    int maxPostponed = 8,
    int maxPulledIn = 8,
    this.fpgaToSdramNs = 4.6,
    this.fastInit = true,
    this.maxGrantWords = 8,
    this.ports = 1,
    this.portMaxGrantWords,
    this.rowAgeGuard = true,
    HarborSdramAddressMap map = HarborSdramAddressMap.rowBankCol,
    this.tRasMaxNs,
  }) : config = _config(map, fastInit, tRasMaxNs),
       cycles = HarborSdramCycles(
         _config(map, fastInit, tRasMaxNs),
         clockHz: clockHz,
         maxPostponedRefresh: maxPostponed,
         maxPulledInRefresh: maxPulledIn,
         phyMaxClockHz: SdramPhyEcp5.maxClockHzLvcmos33,
       ) {
    if (ports < 1) {
      throw ArgumentError('ports must be at least 1');
    }
    portIfaces = [
      for (var i = 0; i < ports; i++)
        SdramPortInterface(addrWidth: 24, wordsWidth: 7, portIdWidth: 1),
    ];
    _toSend = [for (var i = 0; i < ports; i++) Queue()];
    _wrData = [for (var i = 0; i < ports; i++) Queue()];
    _reads = [for (var i = 0; i < ports; i++) Queue()];
    _pendingReq = List.filled(ports, null);
  }

  static HarborSdramConfig _config(
    HarborSdramAddressMap map,
    bool fastInit,
    double? tRasMaxNs,
  ) {
    const base = HarborSdramConfig.as4c16m16sb6();
    return base.copyWith(
      addressMap: map,
      timing: base.timing.copyWith(
        powerUpNs: fastInit ? 2000 : null,
        tRasMax: tRasMaxNs,
      ),
    );
  }

  int get periodPs => 1000000000000 ~/ clockHz;

  /// Splits a word address into (bank, row, col) per [config].
  (int, int, int) split(int addr) {
    final col = addr & ((1 << config.colWidth) - 1);
    final hi = addr >> config.colWidth;
    if (config.addressMap == HarborSdramAddressMap.rowBankCol) {
      return (hi & 3, hi >> 2, col);
    }
    return (hi >> config.rowWidth, hi & ((1 << config.rowWidth) - 1), col);
  }

  int _peek(int addr) {
    final (b, r, c) = split(addr);
    return _mem[addr] ?? SdramPinModel.initialWord(b, r, c);
  }

  Future<void> start() async {
    clk = SimpleClockGenerator(periodPs).clk;
    final dqPad = LogicNet(name: 'dq_pad', width: 16);
    reset.inject(1);
    for (final iface in portIfaces) {
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
    top = SdramEngineStackTop(
      config,
      cycles,
      clk: clk,
      reset: reset,
      ports: portIfaces,
      dqPad: dqPad,
      maxGrantWords: maxGrantWords,
      portMaxGrantWords: portMaxGrantWords,
      rowAgeGuard: rowAgeGuard,
    );
    await top.build();

    final phy = top.phy;
    final bbs = {for (final m in phy.subModules.whereType<Ecp5Bb>()) m.name: m};
    final dqBbs = [for (var i = 0; i < 16; i++) bbs['dq_bb_$i']!];
    final tAcNs = cycles.casLatency == 3 ? 5.0 : 6.0;
    if (!sdramPhyCaptureOk(
      periodPs: periodPs,
      tAcNs: tAcNs,
      fpgaToSdramNs: fpgaToSdramNs,
      phy: const HarborSdramPhyConfig(),
    )) {
      throw ArgumentError('fpgaToSdramNs $fpgaToSdramNs misses the window');
    }

    var rules = const SdramModelRules.as4c16m16sb6();
    if (fastInit) rules = rules.copyWith(powerUpNs: 2000);
    if (tRasMaxNs != null) rules = rules.copyWith(tRasMax: tRasMaxNs);
    final periodNs = cycles.refi * periodPs / 1000;
    model = SdramPinModel(
      clk: phy.oSdramClk,
      cke: phy.oSdramCke,
      csN: phy.oSdramCsN,
      rasN: phy.oSdramRasN,
      casN: phy.oSdramCasN,
      weN: phy.oSdramWeN,
      ba: phy.oSdramBa,
      addr: phy.oSdramAddr,
      dqm: phy.oSdramDqm,
      dq: dqPad,
      rules: rules,
      fpgaToSdramNs: fpgaToSdramNs,
      fpgaDqOe: [for (final bb in dqBbs) ~bb.input('T')].rswizzle(),
      fpgaDqOut: [for (final bb in dqBbs) bb.input('I')].rswizzle(),
      refreshPolicy: SdramRefreshPolicy(
        maxPostponed: cycles.maxPostponed,
        maxPulledIn: cycles.maxPulledIn,
        periodNs: periodNs,
        maxLatencyNs: 256 * periodPs / 1000,
        initRefreshes: cycles.initRefreshes,
      ),
    );

    clk.negedge.listen((_) => _onNegedge());
    clk.posedge.listen((_) => _onEngineCmdPosedge());
    final credit = top.engine.subModules.whereType<SdramRefreshCredit>().single;
    final timers = top.engine.subModules.whereType<SdramBankTimers>().single;
    var lastForce = false, lastAge = false;
    clk.posedge.listen((_) {
      final f = credit.force.value == LogicValue.one;
      final a = timers.rowAgeForce.value == LogicValue.one;
      if (f && !lastForce) forceEdges++;
      if (a && !lastAge) rowAgeEdges++;
      lastForce = f;
      lastAge = a;
    });
    simRun = Simulator.run();
    unawaited(simRun);

    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    reset.put(0);
    while (top.engine.initDone.value != LogicValue.one) {
      await clk.nextPosedge;
    }
  }

  /// Decodes the engine's own phy_* command wires on every clk posedge,
  /// the same way [SdramPinModel] decodes the pins after the PHY.
  void _onEngineCmdPosedge() {
    final csN = top.engine.phyCsN.value;
    if (!csN.isValid || csN.toInt() != 0) return;
    final rasN = top.engine.phyRasN.value;
    final casN = top.engine.phyCasN.value;
    final weN = top.engine.phyWeN.value;
    final ba = top.engine.phyBa.value;
    final addr = top.engine.phyAddr.value;
    if (!rasN.isValid || !casN.isValid || !weN.isValid || !ba.isValid ||
        !addr.isValid) {
      return;
    }
    final cmd3 = (rasN.toInt() << 2) | (casN.toInt() << 1) | weN.toInt();
    if (cmd3 == 7) return;
    engineCommandLog.add((
      Simulator.time,
      _engineCmdKinds[cmd3],
      ba.toInt(),
      addr.toInt(),
    ));
  }

  void _onNegedge() {
    _cycle++;
    if (reset.value == LogicValue.one) return;
    // Drive every port first, then sample the ready signals: through the
    // arbiter one port's req_ready depends on every port's req_valid, and
    // the values that count are the ones just before the next posedge.
    for (var p = 0; p < ports; p++) {
      _drivePort(p);
    }
    final waiting = [for (var p = 0; p < ports; p++) _pendingReq[p] != null];
    for (var p = 0; p < ports; p++) {
      _samplePort(p);
    }
    // Count the grants other ports get while a port waits.
    for (var p = 0; p < ports; p++) {
      final accepted = waiting[p] && _pendingReq[p] == null;
      if (!accepted) continue;
      _otherGrants[p] = 0;
      for (var q = 0; q < ports; q++) {
        if (q == p || !waiting[q] || _pendingReq[q] == null) continue;
        _otherGrants[q]++;
        if (_otherGrants[q] > maxOtherGrants) {
          maxOtherGrants = _otherGrants[q];
        }
      }
    }
    if (top.engine.output('wr_ready').value == LogicValue.one) {
      _wordsIssued++;
    }
  }

  void _drivePort(int p) {
    final iface = portIfaces[p];

    if (iface.rdValid.value == LogicValue.one) {
      if (_reads[p].isEmpty) {
        _errors.add('cycle $_cycle: port $p rd_valid with no read pending');
      } else {
        final r = _reads[p].first;
        r.got.add(iface.rdData.value.isValid ? iface.rdData.value.toInt() : -1);
        final last = r.got.length == r.words;
        if ((iface.rdLast.value == LogicValue.one) != last) {
          _errors.add(
            'cycle $_cycle: port $p rd_last wrong for read @${r.addr}',
          );
        }
        if (last) {
          _reads[p].removeFirst();
          _finish(r);
        }
      }
    }

    // req_valid stays up with the same request until req_ready takes it.
    // It must not wait for req_ready, which can depend on it.
    if (_pendingReq[p] == null && _toSend[p].isNotEmpty) {
      _pendingReq[p] = _toSend[p].removeFirst();
    }
    final req = _pendingReq[p];
    if (req != null) {
      iface.reqValid.put(1);
      iface.reqWrite.put(req.write ? 1 : 0);
      iface.reqAddr.put(req.addr);
      iface.reqWords.put(req.words);
    } else {
      iface.reqValid.put(0);
    }

    if (_wrData[p].isNotEmpty) {
      final (data, mask, _) = _wrData[p].first;
      iface.wrValid.put(1);
      iface.wrData.put(data);
      iface.wrMask.put(mask);
    } else {
      iface.wrValid.put(0);
    }
  }

  void _samplePort(int p) {
    final iface = portIfaces[p];
    final offered = _pendingReq[p];
    if (offered != null && iface.reqReady.value == LogicValue.one) {
      if (!offered.write) _reads[p].add(offered);
      _pendingReq[p] = null;
    }
    if (iface.wrReady.value == LogicValue.one) {
      if (_wrData[p].isEmpty) {
        _errors.add('cycle $_cycle: port $p wr_ready with no write data');
      } else {
        final (_, _, r) = _wrData[p].removeFirst();
        r.got.add(0);
        if (r.got.length == r.words) _finish(r);
      }
    }
  }

  void _finish(_Req r) {
    _pending--;
    if (!r.write) {
      for (var i = 0; i < r.words; i++) {
        if (r.got[i] != r.expected[i]) {
          _errors.add(
            'read @0x${(r.addr + i).toRadixString(16)}: got '
            '0x${r.got[i].toRadixString(16)}, want '
            '0x${r.expected[i].toRadixString(16)}',
          );
        }
      }
    }
    r.done.complete(r.got);
  }

  void _checkRequest(int addr, int words) {
    if (words < 1 || words > maxGrantWords) {
      throw ArgumentError('words must be in 1..$maxGrantWords');
    }
    final colMask = (1 << config.colWidth) - 1;
    if ((addr & colMask) + words > colMask + 1) {
      throw ArgumentError('request crosses a page');
    }
  }

  /// Queues a write on [port]. [masks] holds 2-bit byte enables, 1 = write
  /// the byte.
  Future<void> write(
    int addr,
    List<int> words, {
    List<int>? masks,
    int port = 0,
  }) {
    _checkRequest(addr, words.length);
    final r = _Req(true, addr, words.length, const []);
    for (var i = 0; i < words.length; i++) {
      final m = masks?[i] ?? 3;
      var v = _peek(addr + i);
      if (m & 1 != 0) v = (v & 0xFF00) | (words[i] & 0xFF);
      if (m & 2 != 0) v = (v & 0x00FF) | (words[i] & 0xFF00);
      _mem[addr + i] = v;
      _wrData[port].add((words[i] & 0xFFFF, m, r));
    }
    _wordsQueued += words.length;
    _toSend[port].add(r);
    _pending++;
    return r.done.future;
  }

  /// Queues a read on [port] and returns the words read.
  Future<List<int>> read(int addr, int words, {int port = 0}) {
    _checkRequest(addr, words);
    final r = _Req(false, addr, words, [
      for (var i = 0; i < words; i++) _peek(addr + i),
    ]);
    _toSend[port].add(r);
    _pending++;
    return r.done.future;
  }

  /// Queues a request on [port] with no checks, for tests of the engine's
  /// own request checks.
  void rawRequest(int addr, int words, {bool write = false, int port = 0}) {
    _toSend[port].add(_Req(write, addr, words, const []));
  }

  Future<void> idle(int cycles) async {
    for (var i = 0; i < cycles; i++) {
      await clk.nextPosedge;
    }
  }

  /// Waits until every queued request, on every port, is done and the
  /// engine has issued every write word, or [maxCycles] pass.
  Future<void> drain({int maxCycles = 200000}) async {
    final limit = _cycle + maxCycles;
    while (_pending > 0 || _wordsIssued < _wordsQueued) {
      if (_cycle > limit) {
        _errors.add('drain timed out with $_pending requests pending');
        return;
      }
      await clk.nextPosedge;
    }
  }

  /// Runs the model's end checks and stops the simulation.
  Future<void> stop() async {
    model.finish();
    await Simulator.endSimulation();
  }
}

/// Runs [requests] random requests of 1 to 16 words (random bank, a few
/// rows per bank, random offset, no page cross) on port 0 and returns the
/// stopped stack. With [gaps], the queue drains now and then and idles, so
/// idle and pull-in refreshes run too.
Future<SdramEngineStack> sdramRandomRun(
  int clockHz, {
  required int seed,
  required int requests,
  HarborSdramAddressMap map = HarborSdramAddressMap.rowBankCol,
  int maxPostponed = 8,
  int maxPulledIn = 8,
  bool gaps = true,
  double? tRasMaxNs,
}) async {
  final s = SdramEngineStack(
    clockHz: clockHz,
    maxGrantWords: 16,
    map: map,
    maxPostponed: maxPostponed,
    maxPulledIn: maxPulledIn,
    tRasMaxNs: tRasMaxNs,
  );
  await s.start();
  final rng = Random(seed);
  final c = s.config;
  final rows = [for (var i = 0; i < 3; i++) rng.nextInt(1 << c.rowWidth)];
  for (var i = 0; i < requests; i++) {
    final words = 1 + rng.nextInt(16);
    final col = rng.nextInt((1 << c.colWidth) - words + 1);
    final bank = rng.nextInt(c.banks);
    final row = rows[rng.nextInt(rows.length)];
    final addr = map == HarborSdramAddressMap.rowBankCol
        ? (((row << c.bankBits) | bank) << c.colWidth) | col
        : (((bank << c.rowWidth) | row) << c.colWidth) | col;
    if (rng.nextBool()) {
      s.write(
        addr,
        [for (var w = 0; w < words; w++) rng.nextInt(1 << 16)],
        masks: [for (var w = 0; w < words; w++) rng.nextInt(4)],
      );
    } else {
      s.read(addr, words);
    }
    if (gaps && rng.nextInt(40) == 0) {
      await s.drain();
      await s.idle(rng.nextInt(300));
    }
  }
  await s.drain();
  await s.idle(50);
  await s.stop();
  return s;
}
