// Two BridgeModule masters race an LR/SC style increment loop against one
// AXI4 exclusive SRAM on a HarborSoC, so the fabric's exclusive monitor sees
// real contention.

import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

const _sramBase = 0x80000000;

/// A plain AXI4 (or AXI4 exclusive) master port on bare pins, for a test to
/// drive directly. Unlike `MasterShell` in the port tests, it takes its own
/// instance name, so more than one can sit in the same SoC.
class _Shell extends BridgeModule {
  late final BusMasterPort bus;

  _Shell(String name, {bool exclusive = false})
    : super('BusExclSocShell${exclusive ? '_x' : ''}', name: name) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('m_addr', PortDirection.input, width: 32);
    createPort('m_wdata', PortDirection.input, width: 32);
    createPort('m_stb', PortDirection.input);
    createPort('m_we', PortDirection.input);
    createPort('m_sel', PortDirection.input, width: 4);
    createPort('m_rdata', PortDirection.output, width: 32);
    createPort('m_ack', PortDirection.output);
    createPort('m_err', PortDirection.output);
    bus = BusMasterPort.create(
      module: this,
      name: 'dataBus',
      kind: HarborFabricKind.axi4,
      addressWidth: 32,
      dataWidth: 32,
      clk: input('clk'),
      reset: input('reset'),
      useErr: true,
      exclusive: exclusive,
    );
    if (exclusive) {
      bus.lock <= addInput('m_lock', Logic());
      addOutput('m_exokay') <= bus.exokay;
    }
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

/// Pulls every pin of a [_Shell] up to the SoC, named `<prefix>m_*`.
void _exposeShell(
  HarborSoC soc,
  BridgeModule shell,
  String prefix, {
  bool exclusive = false,
}) {
  for (final p in [
    'm_addr',
    'm_wdata',
    'm_stb',
    'm_we',
    'm_sel',
    'm_rdata',
    'm_ack',
    'm_err',
  ]) {
    soc.pullUpPort(shell.port(p), newPortName: '$prefix$p');
  }
  if (exclusive) {
    soc.pullUpPort(shell.port('m_lock'), newPortName: '${prefix}m_lock');
    soc.pullUpPort(shell.port('m_exokay'), newPortName: '${prefix}m_exokay');
  }
}

/// Drives one access through a [_Shell] exposed with prefix [prefix] on
/// [dut] and waits for its ack.
Future<({int data, int exokay, bool err})> _access(
  Logic clk,
  BridgeModule dut,
  String prefix, {
  required bool write,
  required int addr,
  int data = 0,
  bool lock = false,
  int timeout = 10000,
}) async {
  void set(String suffix, int v) {
    final name = '${prefix}m_$suffix';
    if (dut.inputs.containsKey(name)) {
      dut.input(name).srcConnection!.inject(v);
    }
  }

  int outOf(String suffix) {
    final name = '${prefix}m_$suffix';
    if (!dut.outputs.containsKey(name)) return 0;
    final v = dut.output(name).value;
    return v.isValid ? v.toInt() : 0;
  }

  set('addr', addr);
  set('wdata', data);
  set('sel', 0xf);
  set('we', write ? 1 : 0);
  set('lock', lock ? 1 : 0);
  set('stb', 1);
  for (var i = 0; i < timeout; i++) {
    await clk.nextNegedge;
    if (outOf('ack') == 1) {
      final result = (
        data: outOf('rdata'),
        exokay: outOf('exokay'),
        err: outOf('err') == 1,
      );
      await clk.nextPosedge;
      set('stb', 0);
      set('we', 0);
      set('lock', 0);
      return result;
    }
    await clk.nextPosedge;
  }
  throw StateError('$prefix: no ack in $timeout cycles');
}

/// An LR/SC style increment loop on the counter word at [_sramBase]: an
/// exclusive read, then an exclusive write of value+1. A write that comes
/// back without EXOKAY is a failed store-conditional, and the loop retries
/// from the read. The loop waits for [start] before its first read, so a
/// test can seed the counter first. [done] goes high once [n] writes have
/// succeeded. [gapRw] and [gapWr] are idle cycles between the read ack and
/// the next write, and between a write ack and the next read, so two
/// masters with different gaps actually interleave on the bus.
class _Incrementer extends BridgeModule {
  late final BusMasterPort bus;

  _Incrementer(
    String name,
    int n, {
    int gapRw = 2,
    int gapWr = 2,
    int failsWidth = 16,
  }) : super('BusExclSocIncrementer_n${n}_r${gapRw}_w$gapWr', name: name) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final clk = input('clk');
    final reset = input('reset');
    final start = addInput('start', Logic());

    bus = BusMasterPort.create(
      module: this,
      name: 'dataBus',
      kind: HarborFabricKind.axi4,
      addressWidth: 32,
      dataWidth: 32,
      clk: clk,
      reset: reset,
      exclusive: true,
    );

    const sIdle = 0, sWaitRead = 1, sRead = 2, sWaitWrite = 3, sWrite = 4;
    const sDone = 5;
    final succWidth = max(1, (n + 1).bitLength);
    final gapWidth = max(1, max(gapRw, gapWr).bitLength + 1);

    final state = Logic(name: 'state', width: 3);
    final gap = Logic(name: 'gap', width: gapWidth);
    final value = Logic(name: 'value', width: 32);
    final succ = Logic(name: 'succ', width: succWidth);
    final failsReg = Logic(name: 'fails_reg', width: failsWidth);
    final errSticky = Logic(name: 'err_sticky');

    final nextSucc = succ + 1;
    final nextFails = failsReg + 1;

    bus.addr <= Const(_sramBase, width: 32);
    bus.sel <= Const(0xf, width: 4);
    bus.we <= state.eq(Const(sWrite, width: 3));
    bus.stb <=
        state.eq(Const(sRead, width: 3)) | state.eq(Const(sWrite, width: 3));
    bus.lock <= bus.stb;
    bus.dataOut <= value + 1;

    Sequential(clk, reset: reset, [
      If(bus.ack & bus.err, then: [errSticky < Const(1)]),
      Case(state, [
        CaseItem(Const(sIdle, width: 3), [
          If(
            start,
            then: [
              gap < Const(gapWr, width: gapWidth),
              state < Const(sWaitRead, width: 3),
            ],
          ),
        ]),
        CaseItem(Const(sWaitRead, width: 3), [
          If(
            gap.eq(0),
            then: [state < Const(sRead, width: 3)],
            orElse: [gap < gap - 1],
          ),
        ]),
        CaseItem(Const(sRead, width: 3), [
          If(
            bus.ack,
            then: [
              value < bus.dataIn,
              gap < Const(gapRw, width: gapWidth),
              state < Const(sWaitWrite, width: 3),
            ],
          ),
        ]),
        CaseItem(Const(sWaitWrite, width: 3), [
          If(
            gap.eq(0),
            then: [state < Const(sWrite, width: 3)],
            orElse: [gap < gap - 1],
          ),
        ]),
        CaseItem(Const(sWrite, width: 3), [
          If(
            bus.ack,
            then: [
              If(
                bus.exokay,
                then: [
                  succ < nextSucc,
                  If(
                    nextSucc.eq(Const(n, width: succWidth)),
                    then: [state < Const(sDone, width: 3)],
                    orElse: [
                      gap < Const(gapWr, width: gapWidth),
                      state < Const(sWaitRead, width: 3),
                    ],
                  ),
                ],
                orElse: [
                  failsReg < nextFails,
                  gap < Const(gapWr, width: gapWidth),
                  state < Const(sWaitRead, width: 3),
                ],
              ),
            ],
          ),
        ]),
        CaseItem(Const(sDone, width: 3), []),
      ]),
    ]);

    addOutput('done') <= state.eq(Const(sDone, width: 3));
    addOutput('fails', width: failsWidth) <= failsReg;
    addOutput('err') <= errSticky;
  }
}

HarborSoC _soc() => HarborSoC(
  name: 'excl_bus_soc',
  compatible: 'test,exclbus',
  fabricKind: HarborFabricKind.axi4,
);

HarborSram _sram(({int idWidth, HarborAxi4Exclusive? exclusive}) shape) =>
    HarborSram(
      baseAddress: _sramBase,
      size: 4096,
      busAddressWidth: 32,
      protocol: HarborFabricKind.axi4,
      idWidth: shape.idWidth,
      exclusive: shape.exclusive,
    );

/// Wires clk and reset, builds, runs and releases reset.
///
/// Every other top-level input (the pulled-up shell and incrementer pins)
/// starts at 0, so nothing rides in on X while reset is still asserted.
Future<Logic> _start(HarborSoC soc) async {
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset')..inject(1);
  for (final input in soc.inputs.values) {
    if (input.name != 'clk') input.srcConnection!.put(0);
  }
  soc.input('clk').srcConnection! <= clk;
  soc.input('reset').srcConnection! <= reset;
  await soc.build();
  Simulator.setMaxSimTime(4000000);
  unawaited(Simulator.run());
  for (var i = 0; i < 8; i++) {
    await clk.nextPosedge;
  }
  reset.inject(0);
  for (var i = 0; i < 4; i++) {
    await clk.nextPosedge;
  }
  return clk;
}

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'two incrementers race an LR/SC loop and the monitor fails some SCs',
    () async {
      final soc = _soc();
      const n = 30;
      final incA = soc.addMaster(
        _Incrementer('incA', n, gapRw: 10, gapWr: 1),
        exclusiveIds: 1,
        outstanding: 1,
      );
      final incB = soc.addMaster(
        _Incrementer('incB', n, gapRw: 1, gapWr: 1),
        exclusiveIds: 1,
        outstanding: 1,
      );
      final reader = soc.addMaster(_Shell('reader'));
      for (final e in {'a_': incA, 'b_': incB}.entries) {
        for (final p in ['done', 'fails', 'err', 'start']) {
          soc.pullUpPort(e.value.port(p), newPortName: '${e.key}$p');
        }
      }
      _exposeShell(soc, reader, 'rd_');

      final shape = soc.memoryBusShape();
      soc.addPeripheral(_sram(shape));
      soc.buildFabric();

      final clk = await _start(soc);

      // Seed the counter at 0 before either incrementer is let loose: the
      // sim SRAM has no reset of its own and starts unwritten.
      await _access(clk, soc, 'rd_', write: true, addr: _sramBase, data: 0);

      soc.input('a_start').srcConnection!.inject(1);
      soc.input('b_start').srcConnection!.inject(1);

      var doneA = false;
      var doneB = false;
      while (!doneA || !doneB) {
        await clk.nextNegedge;
        doneA = soc.output('a_done').value.toBool();
        doneB = soc.output('b_done').value.toBool();
      }

      final failsA = soc.output('a_fails').value.toInt();
      final failsB = soc.output('b_fails').value.toInt();
      expect(soc.output('a_err').value.toInt(), 0, reason: 'a_err');
      expect(soc.output('b_err').value.toInt(), 0, reason: 'b_err');
      expect(
        failsA + failsB,
        greaterThan(0),
        reason: 'the exclusive monitor never failed a store-conditional',
      );

      final result = await _access(
        clk,
        soc,
        'rd_',
        write: false,
        addr: _sramBase,
      );
      expect(result.data, 2 * n);

      await Simulator.endSimulation();
    },
  );

  test(
    'a plain write between an exclusive read and write fails the SC',
    () async {
      final soc = _soc();
      final a = soc.addMaster(
        _Shell('a', exclusive: true),
        exclusiveIds: 1,
        outstanding: 1,
      );
      final b = soc.addMaster(_Shell('b'));
      _exposeShell(soc, a, 'a_', exclusive: true);
      _exposeShell(soc, b, 'b_');

      final shape = soc.memoryBusShape();
      soc.addPeripheral(_sram(shape));
      soc.buildFabric();

      final clk = await _start(soc);

      // Seed the counter with a plain write, same reason as above.
      const seed = 0x1000;
      await _access(clk, soc, 'b_', write: true, addr: _sramBase, data: seed);

      // A reserves the word with an exclusive read.
      final read = await _access(
        clk,
        soc,
        'a_',
        write: false,
        addr: _sramBase,
        lock: true,
      );
      expect(read.exokay, 1, reason: 'exclusive read should set a reservation');
      expect(read.data, seed);

      // B writes the word plainly while A still holds the reservation.
      const bValue = 0x1234;
      await _access(clk, soc, 'b_', write: true, addr: _sramBase, data: bValue);

      // A's exclusive write must fail and change nothing.
      final write = await _access(
        clk,
        soc,
        'a_',
        write: true,
        addr: _sramBase,
        data: read.data + 1,
        lock: true,
      );
      expect(write.exokay, 0, reason: 'the reservation was broken by B');
      expect(write.err, isFalse);

      final after = await _access(
        clk,
        soc,
        'b_',
        write: false,
        addr: _sramBase,
      );
      expect(after.data, bValue);

      await Simulator.endSimulation();
    },
  );
}
