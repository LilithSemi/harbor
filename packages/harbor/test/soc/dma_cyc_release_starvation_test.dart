// Repro for the HW fabric deadlock seen on delta (Arty S7): the SD read
// benchmark hangs because the CPU's uncached read never gets a bus ack. Root
// cause hypothesis: the DMA/CPU converge WishboneArbiter grant-locks to whoever
// holds CYC. The ADMA holds CYC across a 16-beat burst and yields only via a
// ONE-cycle drop (dmaCycRelease). Its leg is register-staged
// (WishboneRegisterStage, +2 cyc, from the 40 MHz Fmax work), which holds
// down.cyc while its own beat is outstanding, so the 1-cycle yield never reaches
// the arbiter and the grant stays locked. A polling CPU-like master then
// starves forever.
//
// The _BurstHog models the ADMA (CYC held across a burst, 1-cycle release at the
// boundary) on a register-staged leg. The _Poller models the CPU doing one
// access that must complete. The starving test asserts the poller completes; it
// FAILS today (reproduces the deadlock) and must PASS after the arbiter/release
// fix.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

/// ADMA-like master: once started it holds CYC and streams back-to-back writes,
/// dropping CYC for exactly one cycle every [burst] acked beats (the
/// dmaCycRelease yield). It never stops, so it keeps the arbiter grant unless
/// the yield actually reaches the arbiter.
class _BurstHog extends BridgeModule {
  _BurstHog(
    WishboneConfig cfg, {
    required int burst,
    int addr = 0x100,
    String? name,
  }) : super('BurstHog', name: name ?? 'burst_hog') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    final bus =
        addInterface(
              WishboneInterface(cfg),
              name: 'bus',
              role: PairRole.provider,
            ).internalInterface
            as WishboneInterface;
    final clk = input('clk');
    final reset = input('reset');
    final start = input('start');

    final cntW = burst < 2 ? 1 : burst.bitLength;
    final running = Logic(name: 'running');
    final beatCnt = Logic(name: 'beat_cnt', width: cntW);
    final release = Logic(
      name: 'release',
    ); // 1-cycle CYC drop at burst boundary

    final ackNow = (running & ~release & bus.ack).named('hog_ack_now');

    Sequential(clk, [
      If(
        reset,
        then: [
          running < Const(0),
          beatCnt < Const(0, width: cntW),
          release < Const(0),
        ],
        orElse: [
          release < Const(0), // default: 1-cycle pulse
          If(start, then: [running < Const(1)]),
          If(
            ackNow,
            then: [
              If(
                beatCnt.eq(Const(burst - 1, width: cntW)),
                then: [
                  release < Const(1),
                  beatCnt < Const(0, width: cntW),
                ],
                orElse: [beatCnt < beatCnt + 1],
              ),
            ],
          ),
        ],
      ),
    ]);

    bus.cyc <= running & ~release;
    bus.stb <= running & ~release;
    bus.we <= Const(1);
    bus.adr <= Const(addr, width: cfg.addressWidth);
    bus.datMosi <= Const(0xDEAD0000, width: cfg.dataWidth);
    bus.sel <=
        Const((1 << cfg.effectiveSelWidth) - 1, width: cfg.effectiveSelWidth);
  }
}

/// CPU-like master: on `start`, issue ONE read of [addr] and assert `done` when
/// it acks. `stuck` counts cycles it has waited for the ack, so the test can see
/// how long it has been starved.
class _Poller extends BridgeModule {
  _Poller(WishboneConfig cfg, {int addr = 0x200, String? name})
    : super('Poller', name: name ?? 'poller') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    final done = addOutput('done');
    final rdata = addOutput('rdata', width: cfg.dataWidth);
    final waited = addOutput('waited', width: 32);

    final bus =
        addInterface(
              WishboneInterface(cfg),
              name: 'bus',
              role: PairRole.provider,
            ).internalInterface
            as WishboneInterface;
    final clk = input('clk');
    final reset = input('reset');
    final start = input('start');

    final st = Logic(name: 'st', width: 2);
    final cyc = Logic(name: 'cyc');
    final stb = Logic(name: 'stb');
    final rdReg = Logic(name: 'rd_reg', width: cfg.dataWidth);
    final doneReg = Logic(name: 'done_reg');
    final waitCnt = Logic(name: 'wait_cnt', width: 32);
    final ackNow = cyc & stb & bus.ack;

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(0, width: 2),
          cyc < Const(0),
          stb < Const(0),
          rdReg < Const(0, width: cfg.dataWidth),
          doneReg < Const(0),
          waitCnt < Const(0, width: 32),
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(0, width: 2), [
              If(
                start,
                then: [cyc < Const(1), stb < Const(1), st < Const(1, width: 2)],
              ),
            ]),
            CaseItem(Const(1, width: 2), [
              waitCnt < waitCnt + 1, // counting cycles blocked on the ack
              If(
                ackNow,
                then: [
                  rdReg < bus.datMiso,
                  cyc < Const(0),
                  stb < Const(0),
                  doneReg < Const(1),
                  st < Const(2, width: 2),
                ],
              ),
            ]),
            CaseItem(Const(2, width: 2), []),
          ]),
        ],
      ),
    ]);

    bus.cyc <= cyc;
    bus.stb <= stb;
    bus.we <= Const(0);
    bus.adr <= Const(addr, width: cfg.addressWidth);
    bus.datMosi <= Const(0, width: cfg.dataWidth);
    bus.sel <=
        Const((1 << cfg.effectiveSelWidth) - 1, width: cfg.effectiveSelWidth);
    done <= doneReg;
    rdata <= rdReg;
    waited <= waitCnt;
  }
}

Future<int> _runStarvation({
  required bool pipelineHog,
  required int burst,
}) async {
  const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
  final soc = HarborSoC(
    name: 'StarveSoC',
    compatible: 'test,starve',
    busConfig: cfg,
  );
  final hog = _BurstHog(cfg, burst: burst, addr: 0x100, name: 'hog');
  final poller = _Poller(cfg, addr: 0x200, name: 'poller');
  // The ADMA leg is register-staged in the real SoC (genip pipeline: true); the
  // CPU leg is not. Mirror that exactly.
  soc.addMaster(hog, busInterfaceName: 'bus', pipeline: pipelineHog);
  soc.addMaster(poller, busInterfaceName: 'bus');
  soc.addPeripheral(
    HarborSram(baseAddress: 0, size: 4096, busAddressWidth: 32),
  );
  soc.buildFabric();

  final clk = SimpleClockGenerator(10).clk;
  final resetL = Logic(name: 'reset')..inject(1);
  final startH = Logic(name: 'startH')..inject(0);
  final startP = Logic(name: 'startP')..inject(0);
  soc.input('clk').srcConnection! <= clk;
  soc.input('reset').srcConnection! <= resetL;
  hog.input('start').srcConnection! <= startH;
  poller.input('start').srcConnection! <= startP;

  await soc.build();
  Simulator.setMaxSimTime(2000000);
  unawaited(Simulator.run());
  await clk.nextPosedge;
  await clk.nextPosedge;
  resetL.inject(0);
  await clk.nextPosedge;

  // Start the hog and let it establish a grant-locked burst stream.
  startH.inject(1);
  await clk.nextPosedge;
  startH.inject(0);
  for (var i = 0; i < 60; i++) {
    await clk.nextPosedge;
  }

  // Now the CPU-like poller asks for a single access.
  startP.inject(1);
  await clk.nextPosedge;
  startP.inject(0);

  var guard = 0;
  while (guard++ < 1500) {
    await clk.nextPosedge;
    if (poller.output('done').value.toBool()) break;
  }
  final done = poller.output('done').value.toBool();
  await Simulator.endSimulation();
  return done ? poller.output('waited').value.toInt() : -1;
}

/// A DDR-like slave: acks a request [latency] cycles after it is presented, so
/// each beat occupies the bus (and any upstream register slice) for that long.
/// This is the factor the fast-SRAM harness lacked.
class _LatencySlave extends BridgeModule {
  _LatencySlave(WishboneConfig cfg, {required int latency, String? name})
    : super('LatencySlave', name: name ?? 'latency_slave') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final bus =
        addInterface(
              WishboneInterface(cfg),
              name: 'bus',
              role: PairRole.consumer,
            ).internalInterface
            as WishboneInterface;
    final clk = input('clk');
    final reset = input('reset');
    final cntW = latency < 2 ? 1 : latency.bitLength;
    final cnt = Logic(name: 'cnt', width: cntW);
    final active = Logic(name: 'active');
    final ackReg = Logic(name: 'ack_reg');
    final req = (bus.cyc & bus.stb & ~ackReg & ~active).named('slv_req');

    Sequential(clk, [
      If(
        reset,
        then: [
          active < Const(0),
          cnt < Const(0, width: cntW),
          ackReg < Const(0),
        ],
        orElse: [
          ackReg < Const(0),
          If(
            ~active,
            then: [
              If(
                req,
                then: [
                  active < Const(1),
                  cnt < Const(latency - 1, width: cntW),
                ],
              ),
            ],
            orElse: [
              If(
                cnt.eq(Const(0, width: cntW)),
                then: [ackReg < Const(1), active < Const(0)],
                orElse: [cnt < cnt - 1],
              ),
            ],
          ),
        ],
      ),
    ]);
    bus.ack <= ackReg;
    bus.datMiso <= Const(0x5A5A5A5A, width: cfg.dataWidth);
  }
}

/// A posted-write FIFO slave that HARD-STALLS (stops acking writes) when full,
/// like the real DDR path's CDC/write-FIFO under posted-write backpressure. A
/// slow background drainer frees one slot every [drainEvery] cycles. Reads are
/// always acked. This is the factor the _LatencySlave lacked: when the hog
/// fills it, the hog's write beat is NEVER acked, so the hog never reaches its
/// dmaCycRelease boundary and holds CYC (and the grant) indefinitely.
class _FifoSlave extends BridgeModule {
  _FifoSlave(
    WishboneConfig cfg, {
    required int depth,
    required int drainEvery,
    String? name,
  }) : super('FifoSlave', name: name ?? 'fifo_slave') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final bus =
        addInterface(
              WishboneInterface(cfg),
              name: 'bus',
              role: PairRole.consumer,
            ).internalInterface
            as WishboneInterface;
    final clk = input('clk');
    final reset = input('reset');
    final occW = (depth + 1).bitLength;
    final dW = drainEvery < 2 ? 1 : drainEvery.bitLength;
    final occ = Logic(name: 'occ', width: occW);
    final drainCnt = Logic(name: 'drain_cnt', width: dW);
    final ackReg = Logic(name: 'ack_reg');

    final req = (bus.cyc & bus.stb & ~ackReg).named('slv_req');
    final hasSpace = occ.lt(Const(depth, width: occW)).named('has_space');
    final wrAck = (req & bus.we & hasSpace).named('wr_ack');
    final rdAck = (req & ~bus.we).named('rd_ack');
    final drainTick =
        (drainCnt.eq(Const(0, width: dW)) & occ.gt(Const(0, width: occW)))
            .named('drain_tick');
    final inc = wrAck.named('occ_inc');
    final dec = drainTick.named('occ_dec');

    Sequential(clk, [
      If(
        reset,
        then: [
          occ < Const(0, width: occW),
          drainCnt < Const(drainEvery - 1, width: dW),
          ackReg < Const(0),
        ],
        orElse: [
          ackReg < Const(0),
          If(
            drainCnt.eq(Const(0, width: dW)),
            then: [drainCnt < Const(drainEvery - 1, width: dW)],
            orElse: [drainCnt < drainCnt - 1],
          ),
          // occupancy += accepted-write - drained-slot (net when both)
          If(inc & ~dec, then: [occ < occ + 1]),
          If(dec & ~inc, then: [occ < occ - 1]),
          If(wrAck | rdAck, then: [ackReg < Const(1)]),
        ],
      ),
    ]);
    bus.ack <= ackReg;
    bus.datMiso <= Const(0x5A5A5A5A, width: cfg.dataWidth);
  }
}

/// The real converge: a [WishboneArbiter] merging the register-staged ADMA-like
/// hog and the CPU-like poller onto one slow DDR-like slave, exactly the delta
/// DMA/CPU converge-in-front-of-DRAM topology (hog leg pipelined, CPU leg not).
class _ConvergeHarness extends BridgeModule {
  _ConvergeHarness(
    WishboneConfig cfg, {
    required int burst,
    required int slaveLatency,
    required bool pipelineHog,
    bool hardStall = false,
    int fifoDepth = 16,
    int drainEvery = 24,
    String? name,
  }) : super('ConvergeHarness', name: name ?? 'converge_harness') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('startH', PortDirection.input);
    createPort('startP', PortDirection.input);
    final done = addOutput('done');
    final waited = addOutput('waited', width: 32);
    final clk = input('clk');
    final reset = input('reset');

    final hog = _BurstHog(cfg, burst: burst, addr: 0x100, name: 'hog');
    final poller = _Poller(cfg, addr: 0x200, name: 'poller');
    final arbiter = WishboneArbiter(numMasters: 2, config: cfg);
    final BridgeModule slave = hardStall
        ? _FifoSlave(cfg, depth: fifoDepth, drainEvery: drainEvery)
        : _LatencySlave(cfg, latency: slaveLatency);
    addSubModule(hog);
    addSubModule(poller);
    addSubModule(arbiter);
    addSubModule(slave);

    for (final m in [hog, poller, arbiter, slave]) {
      m.input('clk').srcConnection! <= clk;
      m.input('reset').srcConnection! <= reset;
    }
    hog.input('start').srcConnection! <= input('startH');
    poller.input('start').srcConnection! <= input('startP');

    if (pipelineHog) {
      final reg = WishboneRegisterStage(config: cfg);
      addSubModule(reg);
      reg.input('clk').srcConnection! <= clk;
      reg.input('reset').srcConnection! <= reset;
      connectInterfaces(hog.interface('bus'), reg.interface('up'));
      connectInterfaces(reg.interface('down'), arbiter.interface('master_0'));
    } else {
      connectInterfaces(hog.interface('bus'), arbiter.interface('master_0'));
    }
    connectInterfaces(poller.interface('bus'), arbiter.interface('master_1'));
    connectInterfaces(arbiter.interface('slave'), slave.interface('bus'));

    done <= poller.output('done');
    waited <= poller.output('waited');
  }
}

/// Runs the converge harness: start the hog, let it establish a grant-locked
/// burst stream to the slow slave, then have the poller ask for one access.
/// Returns the cycles the poller waited, or -1 if it never got the bus.
Future<int> _runConverge({
  required int slaveLatency,
  required bool pipelineHog,
  bool hardStall = false,
  int fifoDepth = 16,
  int drainEvery = 24,
  int burst = 16,
  int startDelay = 120,
  int guardMax = 6000,
}) async {
  await Simulator.reset(); // the sweep calls this repeatedly in one test
  const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
  final h = _ConvergeHarness(
    cfg,
    burst: burst,
    slaveLatency: slaveLatency,
    pipelineHog: pipelineHog,
    hardStall: hardStall,
    fifoDepth: fifoDepth,
    drainEvery: drainEvery,
  );
  final clk = SimpleClockGenerator(10).clk;
  final resetL = Logic(name: 'reset')..inject(1);
  final startH = Logic(name: 'startH')..inject(0);
  final startP = Logic(name: 'startP')..inject(0);
  h.input('clk').srcConnection! <= clk;
  h.input('reset').srcConnection! <= resetL;
  h.input('startH').srcConnection! <= startH;
  h.input('startP').srcConnection! <= startP;

  await h.build();
  Simulator.setMaxSimTime(50000000);
  unawaited(Simulator.run());
  await clk.nextPosedge;
  await clk.nextPosedge;
  resetL.inject(0);
  await clk.nextPosedge;
  startH.inject(1);
  await clk.nextPosedge;
  startH.inject(0);
  for (var i = 0; i < startDelay; i++) {
    await clk.nextPosedge;
  }
  startP.inject(1);
  await clk.nextPosedge;
  startP.inject(0);

  var guard = 0;
  while (guard++ < guardMax) {
    await clk.nextPosedge;
    if (h.output('done').value.toBool()) break;
  }
  final done = h.output('done').value.toBool();
  final waited = done ? h.output('waited').value.toInt() : -1;
  await Simulator.endSimulation();
  return waited;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // The failing repro: with the ADMA leg register-staged (as in the real SoC),
  // the 1-cycle dmaCycRelease is swallowed by the register slice, so the arbiter
  // never sees the hog yield CYC and the poller starves forever.
  test('register-staged CYC-hog does NOT starve a polling master', () async {
    final waited = await _runStarvation(pipelineHog: true, burst: 16);
    expect(
      waited,
      greaterThanOrEqualTo(0),
      reason:
          'poller starved: never got the bus while the DMA held CYC '
          '(waited forever). This is the delta SD-read boot hang.',
    );
  });

  // Control: without the register stage on the hog leg, the 1-cycle yield does
  // reach the arbiter, so the poller gets in. Proves the register-slice-swallow
  // is the mechanism (this should pass today).
  test(
    'un-pipelined CYC-hog lets the poller through (mechanism control)',
    () async {
      final waited = await _runStarvation(pipelineHog: false, burst: 16);
      expect(
        waited,
        greaterThanOrEqualTo(0),
        reason: 'control: poller completes',
      );
    },
  );

  // Characterisation: sweep the DDR-like slave latency, with and without the
  // register-staged hog leg, and print whether the poller ever gets the bus.
  test(
    'converge starvation sweep vs slave latency (characterisation)',
    () async {
      for (final pipe in [false, true]) {
        for (final lat in [1, 2, 4, 8, 16]) {
          final waited = await _runConverge(
            slaveLatency: lat,
            pipelineHog: pipe,
          );
          // ignore: avoid_print
          print(
            'pipelineHog=$pipe slaveLatency=$lat -> '
            '${waited < 0 ? "STARVED (poller never got the bus)" : "ok, waited $waited cyc"}',
          );
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  // RESULT (2026-08-13): this PASSES at every latency (1..16), pipelined or not.
  // The converge arbiter + register stage are provably starvation-free even with
  // a slow DDR-like slave, so the delta SD-read boot hang is NOT a DMA/CPU
  // converge-arbiter starvation. Kept as a fairness regression + a recorded
  // ruled-out hypothesis; the real hang is on the SDIO-slave / primary-channel /
  // D-cache-bypass side (the CPU's stuck read is to the SDIO, not to DRAM).
  test(
    'converge is starvation-free: register-staged CYC-hog + slow DDR (fairness)',
    () async {
      final waited = await _runConverge(slaveLatency: 8, pipelineHog: true);
      expect(
        waited,
        greaterThanOrEqualTo(0),
        reason: 'the converge arbiter must not starve a polling master',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  // THE faithful repro: a posted-write DDR path that HARD-STALLS when full
  // (drains slower than the hog fills it). The hog's write beat is never acked
  // while the FIFO is full, so the hog never reaches its dmaCycRelease boundary
  // and holds CYC (and the converge grant) forever -> the CPU-like poller
  // starves. This is the delta "DDR posted-write backpressure deadlocks the
  // fabric" hang (conduit harbor_sdio.zig:391). Expected to FAIL (poller
  // starves) until the backpressure/release is fixed.
  test(
    'backpressure: full-DDR hard-stall + CYC-hog starves the poller (repro)',
    () async {
      final waited = await _runConverge(
        slaveLatency: 1,
        pipelineHog: true,
        hardStall: true,
        fifoDepth: 16,
        drainEvery: 24, // drains far slower than the hog fills -> stays full
        guardMax: 8000,
      );
      expect(
        waited,
        greaterThanOrEqualTo(0),
        reason:
            'poller starved under DDR posted-write backpressure: the hog held '
            'CYC while the write FIFO stayed full and never yielded the grant. '
            'This is the delta SD-read fabric deadlock.',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
