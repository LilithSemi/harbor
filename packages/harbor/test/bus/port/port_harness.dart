import 'dart:async';
import 'dart:collection';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Word index that answers every access with err.
const errWord = 3;

/// Four 32-bit registers behind a register slave waist. Word [errWord] fails
/// every access. [waitStates] delays each ACK.
class RegFile extends BridgeModule {
  late final BusSlavePort bus;
  final int waitStates;

  /// Values of the four registers.
  final List<Logic> regs = [];

  RegFile(HarborFabricKind kind, {this.waitStates = 0})
    : super('PortTestRegFile_${kind.name}_w$waitStates', name: 'regfile') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final clk = input('clk');
    final reset = input('reset');
    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      kind: kind,
      addressWidth: 16,
      dataWidth: 32,
      clk: clk,
      reset: reset,
      useErr: true,
    );

    for (var i = 0; i < 4; i++) {
      regs.add(Logic(name: 'r$i', width: 32));
    }
    final index = bus.addr.getRange(2, 4);
    final hitErr = index.eq(Const(errWord, width: 2));
    final wait = Logic(name: 'wait', width: 4);
    final go = bus.stb & ~bus.ack & wait.eq(Const(waitStates, width: 4));

    Sequential(clk, reset: reset, [
      bus.ack < Const(0),
      bus.err! < Const(0),
      If(
        bus.stb & ~bus.ack & ~go,
        then: [wait < wait + 1],
        orElse: [wait < Const(0, width: 4)],
      ),
      If(
        go,
        then: [
          bus.ack < Const(1),
          bus.err! < hitErr,
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

/// A device that brings its register master waist out to plain ports named
/// `m_*`, so a test can drive it.
class MasterShell extends BridgeModule {
  late final BusMasterPort bus;

  MasterShell(HarborFabricKind kind)
    : super('PortTestMasterShell_${kind.name}', name: 'shell') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
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

/// Runs a top-level module with a clock.
///
/// Test code changes inputs only from edge callbacks, so a change never lands
/// on a rising edge. [onFall] callbacks drive inputs, [onRise] callbacks
/// sample with [pre].
class Sim {
  final BridgeModule dut;
  final Logic clk;
  final List<void Function()> _fall = [];
  final List<void Function()> _rise = [];

  /// Edge callbacks run only while this is set.
  bool running = false;

  /// Uses [clk] when given, else a clock with a period of 10.
  Sim(this.dut, {Logic? clk}) : clk = clk ?? SimpleClockGenerator(10).clk;

  /// Builds and runs [dut], then releases reset.
  Future<void> start() async {
    for (final input in dut.inputs.values) {
      if (input.name != 'clk') input.srcConnection!.put(0);
    }
    dut.input('clk').srcConnection! <= clk;
    await dut.build();
    dut.input('reset').srcConnection!.put(1);
    final ready = Completer<void>();
    var falls = 0;
    clk.negedge.listen((_) {
      falls++;
      if (falls == 3) set('reset', 0);
      if (falls == 4) {
        running = true;
        ready.complete();
      }
    });
    attach();
    Simulator.setMaxSimTime(100000);
    watchEnd();
    unawaited(Simulator.run());
    await ready.future;
  }

  /// Hooks the edge callbacks to [clk]. [start] calls it.
  void attach() {
    clk.negedge.listen((_) {
      if (running) {
        for (final f in _fall) {
          f();
        }
      }
    });
    clk.posedge.listen((_) {
      if (running) {
        for (final f in _rise) {
          f();
        }
      }
    });
  }

  final List<Completer<Object?>> _open = [];

  /// Fails every [track]ed completer still open when the simulation ends.
  void watchEnd() {
    unawaited(
      Simulator.simulationEnded.then((_) {
        for (final c in _open) {
          if (!c.isCompleted) {
            c.completeError(StateError('simulation ran out of time'));
          }
        }
      }),
    );
  }

  /// Fails [c] if the simulation runs out of time first.
  Completer<T> track<T>(Completer<T> c) {
    _open.add(c as Completer<Object?>);
    return c;
  }

  void onFall(void Function() f) => _fall.add(f);
  void onRise(void Function() f) => _rise.add(f);

  /// Drives input [port]. Call it from an edge callback.
  void set(String port, int value) =>
      dut.input(port).srcConnection!.inject(value);

  /// Value of [port] (input or output) just before the current edge.
  int pre(String port) {
    final s = dut.tryOutput(port) ?? dut.input(port).srcConnection!;
    return s.previousValue!.toInt();
  }

  /// Waits for [n] falling edges.
  Future<void> cycles(int n) async {
    for (var i = 0; i < n; i++) {
      await clk.nextNegedge;
    }
  }

  Future<void> stop() => Simulator.endSimulation();
}

/// A valid/ready channel the test sends on.
class Sender {
  final Sim s;
  final String valid;
  final String ready;
  final Queue<(Map<String, int>, Completer<void>)> _queue = Queue();
  (Map<String, int>, Completer<void>)? _cur;

  Sender(this.s, this.valid, this.ready) {
    s.onRise(() {
      if (_cur != null && s.pre(valid) == 1 && s.pre(ready) == 1) {
        _cur!.$2.complete();
        _cur = null;
      }
    });
    s.onFall(() {
      if (_cur == null && _queue.isNotEmpty) {
        _cur = _queue.removeFirst();
        _cur!.$1.forEach(s.set);
      }
      s.set(valid, _cur == null ? 0 : 1);
    });
  }

  /// Sends one transfer with [fields] and completes when it is taken.
  Future<void> send(Map<String, int> fields) {
    final done = s.track(Completer<void>());
    _queue.add((fields, done));
    return done.future;
  }
}

/// A valid/ready channel the test receives on.
class Receiver {
  final Sim s;
  final String valid;
  final String ready;
  final List<String> fields;
  final Queue<(int, Completer<Map<String, int>>)> _queue = Queue();
  Completer<Map<String, int>>? _cur;
  int _stall = 0;

  Receiver(this.s, this.valid, this.ready, this.fields) {
    s.onRise(() {
      if (_cur != null && s.pre(valid) == 1 && s.pre(ready) == 1) {
        _cur!.complete({for (final f in fields) f: s.pre(f)});
        _cur = null;
      }
    });
    s.onFall(() {
      if (_cur == null && _queue.isNotEmpty) {
        final next = _queue.removeFirst();
        _stall = next.$1;
        _cur = next.$2;
      }
      if (_cur != null && _stall > 0) {
        _stall--;
        s.set(ready, 0);
      } else {
        s.set(ready, _cur == null ? 0 : 1);
      }
    });
  }

  /// Takes one transfer after holding READY low for [stall] cycles.
  Future<Map<String, int>> take({int stall = 0}) {
    final done = s.track(Completer<Map<String, int>>());
    _queue.add((stall, done));
    return done.future;
  }
}

/// A strobe/ack requester, such as a Wishbone classic master or a register
/// master waist. Queued accesses run back to back with the strobe held.
class StrobeMaster {
  final Sim s;
  final List<String> strobes;
  final String we;
  final String addr;
  final String wdata;
  final String sel;
  final String ack;
  final String? err;
  final String rdata;

  /// Drive right after the rising edge instead of on the falling edge.
  final bool driveOnRise;
  final Queue<(Map<String, int>, Completer<(int, int, int)>)> _queue = Queue();
  (Map<String, int>, Completer<(int, int, int)>)? _cur;

  StrobeMaster(
    this.s, {
    required this.strobes,
    required this.we,
    required this.addr,
    required this.wdata,
    required this.sel,
    required this.ack,
    required this.err,
    required this.rdata,
    this.driveOnRise = false,
  }) {
    s.onRise(() {
      final errNow = err == null ? 0 : s.pre(err!);
      if (_cur != null && (s.pre(ack) == 1 || errNow == 1)) {
        _cur!.$2.complete((s.pre(rdata), s.pre(ack), errNow));
        _cur = null;
      }
      if (driveOnRise) _drive();
    });
    if (!driveOnRise) s.onFall(_drive);
  }

  void _drive() {
    if (_cur == null && _queue.isNotEmpty) {
      _cur = _queue.removeFirst();
      _cur!.$1.forEach(s.set);
    }
    for (final p in strobes) {
      s.set(p, _cur == null ? 0 : 1);
    }
  }

  /// Ends the access in progress and every queued one with (-1, -1, -1),
  /// as a device reset does.
  void abort() {
    final all = [?_cur, ..._queue];
    _cur = null;
    _queue.clear();
    for (final (_, c) in all) {
      c.complete((-1, -1, -1));
    }
  }

  /// Runs one access. Returns read data, ack and err.
  Future<(int, int, int)> access(
    bool write,
    int address, {
    int data = 0,
    int byteSel = 0xf,
  }) {
    final done = s.track(Completer<(int, int, int)>());
    _queue.add((
      {we: write ? 1 : 0, addr: address, wdata: data, sel: byteSel},
      done,
    ));
    return done.future;
  }
}

/// Merges [data] into [old] on the bytes [strb] marks.
int mergeBytes(int old, int data, int strb) {
  var out = old;
  for (var b = 0; b < 4; b++) {
    if (strb & (1 << b) != 0) {
      final m = 0xff << (8 * b);
      out = (out & ~m) | (data & m);
    }
  }
  return out & 0xffffffff;
}
