import 'dart:async';
import 'dart:isolate';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import 'memory_harness.dart';
import 'port_harness.dart';

/// Clock periods of the fabric and of the two devices. Each is even.
class Ratio {
  final int fabric;
  final int a;
  final int b;
  const Ratio(this.fabric, this.a, this.b);

  @override
  String toString() => 'fabric $fabric, a $a, b $b';
}

/// Periods for the device clocks: slower, faster, near equal and
/// non-integer ratios to a fabric period of 20.
const ratios = [
  Ratio(20, 74, 6),
  Ratio(20, 22, 18),
  Ratio(20, 8, 30),
  Ratio(20, 28, 34),
];

HarborFabricClock? _fabricClock(BridgeModule m, bool cross) => cross
    ? HarborFabricClock(clk: m.input('fclk'), reset: m.input('freset'))
    : HarborFabricClock(clk: m.input('clk'), reset: m.input('reset'));

void _clockPorts(BridgeModule m) {
  for (final p in ['clk', 'reset', 'fclk', 'freset']) {
    m.createPort(p, PortDirection.input);
  }
}

/// A register master on the device clock `clk`, with its waist on `m_*`.
class CdcRegMaster extends BridgeModule {
  late final BusMasterPort bus;

  CdcRegMaster(HarborFabricKind kind, {required bool cross})
    : super('CdcTestRegMaster_${kind.name}_c$cross', name: 'master') {
    _clockPorts(this);
    createPort('m_addr', PortDirection.input, width: 16);
    createPort('m_wdata', PortDirection.input, width: 32);
    createPort('m_stb', PortDirection.input);
    createPort('m_we', PortDirection.input);
    createPort('m_sel', PortDirection.input, width: 4);
    createPort('m_rdata', PortDirection.output, width: 32);
    createPort('m_ack', PortDirection.output);
    createPort('m_err', PortDirection.output);
    bus = BusMasterPort.create(
      module: this,
      name: 'bus',
      kind: kind,
      addressWidth: 16,
      dataWidth: 32,
      clk: input('clk'),
      reset: input('reset'),
      useErr: true,
      fabricClock: _fabricClock(this, cross),
    );
    bus.addr <= input('m_addr');
    bus.dataOut <= input('m_wdata');
    bus.stb <= input('m_stb');
    bus.we <= input('m_we');
    bus.sel <= input('m_sel');
    output('m_rdata') <= bus.dataIn;
    output('m_ack') <= bus.ack;
    output('m_err') <= bus.err;
  }
}

/// [RegFile] on the device clock `clk`, reset by the port reset.
class CdcRegFile extends BridgeModule {
  late final BusSlavePort bus;

  CdcRegFile(
    HarborFabricKind kind, {
    required bool cross,
    int waitStates = 1,
    bool useErr = true,
  }) : super(
         'CdcTestRegFile_${kind.name}_c${cross}_w${waitStates}_e$useErr',
         name: 'regfile',
       ) {
    _clockPorts(this);
    createPort('dev_stb', PortDirection.output);
    final clk = input('clk');
    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      kind: kind,
      addressWidth: 16,
      dataWidth: 32,
      clk: clk,
      reset: input('reset'),
      useErr: useErr,
      fabricClock: _fabricClock(this, cross),
    );
    output('dev_stb') <= bus.stb;
    final err = bus.err ?? Logic(name: 'no_err');
    final regs = [for (var i = 0; i < 4; i++) Logic(name: 'r$i', width: 32)];
    final index = bus.addr.getRange(2, 4);
    final wait = Logic(name: 'wait', width: 4);
    final go = bus.stb & ~bus.ack & wait.eq(Const(waitStates, width: 4));
    Sequential(clk, reset: bus.reset, [
      bus.ack < Const(0),
      err < Const(0),
      If(
        bus.stb & ~bus.ack & ~go,
        then: [wait < wait + 1],
        orElse: [wait < Const(0, width: 4)],
      ),
      If(
        go,
        then: [
          bus.ack < Const(1),
          err < index.eq(Const(errWord, width: 2)),
          bus.dataOut < Const(0, width: 32),
          for (var i = 0; i < 4; i++)
            if (i != errWord)
              If(
                index.eq(Const(i, width: 2)),
                then: [
                  bus.dataOut < regs[i],
                  If(bus.we, then: [regs[i] < bus.selMerge(regs[i], i * 4)]),
                ],
              ),
        ],
      ),
    ]);
  }
}

/// Wires the ports `clk`, `reset`, `fclk` and `freset` of [sub] to the
/// device clock [dev] of [top] and to its fabric clock.
void _wireClocks(BridgeModule top, BridgeModule sub, String dev) {
  sub.input('clk').srcConnection! <= top.input('clk_$dev');
  sub.input('reset').srcConnection! <= top.input('reset_$dev');
  sub.input('fclk').srcConnection! <= top.input('clk');
  sub.input('freset').srcConnection! <= top.input('reset');
}

void _topClocks(BridgeModule m) {
  for (final p in ['clk', 'reset', 'clk_a', 'reset_a', 'clk_b', 'reset_b']) {
    m.createPort(p, PortDirection.input);
  }
}

/// A register master on clock `clk_a` linked over the native fabric on
/// clock `clk` to a [CdcRegFile] on clock `clk_b`. The master waist is on
/// ports `m_*`.
class CdcRegLoop extends BridgeModule {
  late final CdcRegMaster master;
  late final CdcRegFile file;

  CdcRegLoop(
    HarborFabricKind kind, {
    bool cross = true,
    int waitStates = 1,
    bool fileErr = true,
  }) : super(
         'CdcTestRegLoop_${kind.name}_c${cross}_w${waitStates}_e$fileErr',
         name: 'top',
       ) {
    _topClocks(this);
    master = addSubModule(CdcRegMaster(kind, cross: cross));
    file = addSubModule(
      CdcRegFile(kind, cross: cross, waitStates: waitStates, useErr: fileErr),
    );
    createPort('dev_stb', PortDirection.output);
    output('dev_stb') <= file.output('dev_stb');
    _wireClocks(this, master, 'a');
    _wireClocks(this, file, 'b');
    connectInterfaces(master.interface('bus'), file.interface('bus'));
    for (final (p, w) in [
      ('m_addr', 16),
      ('m_wdata', 32),
      ('m_stb', 1),
      ('m_we', 1),
      ('m_sel', 4),
    ]) {
      createPort(p, PortDirection.input, width: w);
      master.input(p).srcConnection! <= input(p);
    }
    for (final (p, w) in [('m_rdata', 32), ('m_ack', 1), ('m_err', 1)]) {
      createPort(p, PortDirection.output, width: w);
      output(p) <= master.output(p);
    }
  }
}

/// A [CdcRegMaster] on clock `clk_a` with its native port on the top as
/// `bus_*`, so a test can be the slave on the fabric clock `clk`.
class CdcMasterShell extends BridgeModule {
  CdcMasterShell(HarborFabricKind kind)
    : super('CdcTestMasterShell_${kind.name}', name: 'top') {
    _topClocks(this);
    final master = addSubModule(CdcRegMaster(kind, cross: true));
    _wireClocks(this, master, 'a');
    pullUpInterface(master.interface('bus'));
    for (final (p, w) in [
      ('m_addr', 16),
      ('m_wdata', 32),
      ('m_stb', 1),
      ('m_we', 1),
      ('m_sel', 4),
    ]) {
      createPort(p, PortDirection.input, width: w);
      master.input(p).srcConnection! <= input(p);
    }
    for (final (p, w) in [('m_rdata', 32), ('m_ack', 1), ('m_err', 1)]) {
      createPort(p, PortDirection.output, width: w);
      output(p) <= master.output(p);
    }
  }
}

/// A memory port device on clock `clk` with its waist on `<waist>_*` and
/// the port reset on `dev_reset`.
class CdcMemDevice extends BridgeModule {
  CdcMemDevice(
    HarborMemoryWaistConfig config,
    HarborFabricKind kind, {
    required bool slave,
    required bool cross,
    int? depth,
  }) : super(
         'CdcTestMem${slave ? 'Slave' : 'Master'}_${kind.name}'
         '_a${config.addressWidth}_d${config.dataWidth}_i${config.idWidth}'
         '_n${config.outstanding}_c${cross}_q$depth',
         name: slave ? 'memory' : 'requester',
       ) {
    _clockPorts(this);
    createPort('dev_reset', PortDirection.output);
    final fabric = _fabricClock(this, cross);
    if (slave) {
      final port = HarborMemorySlavePort.create(
        module: this,
        name: 'bus',
        kind: kind,
        config: config,
        clk: input('clk'),
        reset: input('reset'),
        fabricClock: fabric,
        cdcDepth: depth,
      );
      output('dev_reset') <= port.reset;
      exposeWaist(this, port.waist, 'mem', PairRole.provider);
    } else {
      final port = HarborMemoryMasterPort.create(
        module: this,
        name: 'bus',
        kind: kind,
        config: config,
        clk: input('clk'),
        reset: input('reset'),
        fabricClock: fabric,
        cdcDepth: depth,
      );
      output('dev_reset') <= port.reset;
      exposeWaist(this, port.waist, 'up', PairRole.consumer);
    }
  }
}

/// A memory requester on clock `clk_a` linked over the native fabric on
/// clock `clk` to a memory on clock `clk_b`. The waists are on `up_*` and
/// `mem_*`, and the port resets on `a_reset_joined` and `b_reset_joined`.
class CdcMemLoop extends BridgeModule {
  CdcMemLoop(
    HarborMemoryWaistConfig config,
    HarborFabricKind kind, {
    bool cross = true,
    int? depth,
  }) : super(
         'CdcTestMemLoop_${kind.name}_a${config.addressWidth}'
         '_d${config.dataWidth}_i${config.idWidth}_n${config.outstanding}'
         '_c${cross}_q$depth',
         name: 'top',
       ) {
    _topClocks(this);
    final a = addSubModule(
      CdcMemDevice(config, kind, slave: false, cross: cross, depth: depth),
    );
    final b = addSubModule(
      CdcMemDevice(config, kind, slave: true, cross: cross, depth: depth),
    );
    _wireClocks(this, a, 'a');
    _wireClocks(this, b, 'b');
    connectInterfaces(a.interface('bus'), b.interface('bus'));
    pullUpInterface(a.interface('up'));
    pullUpInterface(b.interface('mem'));
    createPort('a_reset_joined', PortDirection.output);
    createPort('b_reset_joined', PortDirection.output);
    output('a_reset_joined') <= a.output('dev_reset');
    output('b_reset_joined') <= b.output('dev_reset');
  }
}

/// Runs [dut] with one clock for each of `clk`, `clk_a` and `clk_b`.
///
/// [fabric], [a] and [b] drive inputs only from their own edge callbacks.
class MultiSim {
  final BridgeModule dut;
  final Ratio ratio;
  late final Sim fabric;
  late final Sim a;
  late final Sim b;

  MultiSim(this.dut, this.ratio) {
    fabric = Sim(dut, clk: SimpleClockGenerator(ratio.fabric).clk);
    a = Sim(dut, clk: SimpleClockGenerator(ratio.a).clk);
    b = Sim(dut, clk: SimpleClockGenerator(ratio.b).clk);
    _hookPulses();
  }

  List<(Sim, String)> get _domains => [
    (fabric, 'reset'),
    (a, 'reset_a'),
    (b, 'reset_b'),
  ];

  /// Builds and runs [dut], releases every reset and returns once every
  /// side is out of reset.
  Future<void> start() async {
    const clocks = {'clk', 'clk_a', 'clk_b'};
    for (final input in dut.inputs.values) {
      if (!clocks.contains(input.name)) input.srcConnection!.put(0);
    }
    dut.input('clk').srcConnection! <= fabric.clk;
    dut.input('clk_a').srcConnection! <= a.clk;
    dut.input('clk_b').srcConnection! <= b.clk;
    await dut.build();
    final ready = <Future<void>>[];
    for (final (s, reset) in _domains) {
      dut.input(reset).srcConnection!.put(1);
      s.attach();
      final done = Completer<void>();
      var falls = 0;
      s.clk.negedge.listen((_) {
        falls++;
        if (falls == 3) s.dut.input(reset).srcConnection!.inject(0);
        if (falls == 4) {
          s.running = true;
          done.complete();
        }
      });
      ready.add(done.future);
    }
    Simulator.setMaxSimTime(30000000);
    for (final (s, _) in _domains) {
      s.watchEnd();
    }
    unawaited(Simulator.run());
    await Future.wait(ready);
    // The joined resets release a few cycles after the slowest side.
    await slow(8);
  }

  /// The domain with the longest period.
  Sim get slowest =>
      [a, b, fabric].reduce((x, y) => _period(x) >= _period(y) ? x : y);

  int _period(Sim s) => s == fabric
      ? ratio.fabric
      : s == a
      ? ratio.a
      : ratio.b;

  /// Waits [n] cycles of the slowest clock.
  Future<void> slow(int n) => slowest.cycles(n);

  final Map<String, (int, Completer<void>)> _pulses = {};

  /// Asserts [reset] for [cycles] cycles of its own clock, from the falling
  /// edges of that clock.
  Future<void> pulse(String reset, int cycles) {
    final done = Completer<void>();
    _pulses[reset] = (cycles, done);
    return done.future;
  }

  void _hookPulses() {
    for (final (s, reset) in _domains) {
      s.onFall(() {
        final p = _pulses[reset];
        if (p == null) return;
        final (left, done) = p;
        if (left > 0) {
          s.set(reset, 1);
          _pulses[reset] = (left - 1, done);
        } else {
          s.set(reset, 0);
          _pulses.remove(reset);
          done.complete();
        }
      });
    }
  }

  Future<void> stop() => Simulator.endSimulation();
}

/// Waits on [s] until [done] holds.
Future<void> settle(Sim s, bool Function() done, {int limit = 60000}) =>
    waitUntil(s, done, limit: limit);

/// The definition names of every module under [m].
Set<String> definitions(Module m) => {
  m.definitionName,
  for (final sub in m.subModules) ...definitions(sub),
};

/// True when [m] has a clock domain crossing anywhere under it.
bool hasCrossing(Module m) => definitions(m).any(
  (d) =>
      d.startsWith('HarborCdcFifo') ||
      d.startsWith('HarborWishboneCdcFifoBridge') ||
      d.startsWith('HarborMemoryWaistCdc'),
);

/// Runs [body] in a fresh isolate. ROHD keeps every wire of every design
/// built in an isolate on its tick stream, so later simulations in one
/// isolate get slower with each design.
Future<void> isolated(Future<void> Function() body) => Isolate.run(body);

/// [expect] for code in an [isolated] body, where [expect] cannot run.
void must(Object? actual, Object? expected, {String? reason}) {
  final matcher = wrapMatcher(expected);
  if (matcher.matches(actual, {})) return;
  final d = StringDescription()
    ..add('Expected: ')
    ..addDescriptionOf(matcher)
    ..add('\n  Actual: ')
    ..addDescriptionOf(actual);
  if (reason != null) d.add('\n  $reason');
  throw TestFailure(d.toString());
}
