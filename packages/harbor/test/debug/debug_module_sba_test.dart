import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

/// Eight 32-bit registers behind a register slave waist, matched to the
/// address and data width of [HarborDebugModule]'s system bus access master.
/// Word 7 (byte address 0x1C) fails every access. [waitStates] delays each
/// ACK, so a test can catch the master mid-access.
class SbaTestSlave extends BridgeModule {
  late final BusSlavePort bus;
  final int waitStates;
  final List<Logic> regs = [];

  static const errWord = 7;

  SbaTestSlave(HarborFabricKind kind, {this.waitStates = 0})
    : super('SbaTestSlave_${kind.name}_w$waitStates', name: 'slave') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final clk = input('clk');
    final reset = input('reset');
    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      kind: kind,
      addressWidth: 32,
      dataWidth: 32,
      clk: clk,
      reset: reset,
      useErr: true,
    );

    for (var i = 0; i < 8; i++) {
      regs.add(Logic(name: 'r$i', width: 32));
    }
    final index = bus.addr.getRange(2, 5);
    final hitErr = index.eq(Const(errWord, width: 3));
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
          for (var i = 0; i < 8; i++)
            if (i != errWord)
              If(
                index.eq(Const(i, width: 3)),
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

/// A [HarborDebugModule] with an [SbaTestSlave] behind its system bus access
/// master. The DM's own register slave window comes up as `bus_*`; drive it
/// idle with [RegBus]. DMI comes up as plain ports with the DM's own names.
class SbaTestTop extends BridgeModule {
  final HarborFabricKind kind;
  late final HarborDebugModule dm;
  late final SbaTestSlave slave;

  SbaTestTop(this.kind, {int waitStates = 0})
    : super('SbaTestTop_${kind.name}_w$waitStates', name: 'top') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('dmi_addr', PortDirection.input, width: 7);
    createPort('dmi_data_in', PortDirection.input, width: 32);
    createPort('dmi_op', PortDirection.input, width: 2);
    createPort('dmi_valid', PortDirection.input);
    createPort('dmi_data_out', PortDirection.output, width: 32);

    dm = addSubModule(HarborDebugModule(baseAddress: 0x0, fabricKind: kind));
    slave = addSubModule(SbaTestSlave(kind, waitStates: waitStates));

    for (final m in [dm, slave]) {
      m.input('clk').srcConnection! <= input('clk');
      m.input('reset').srcConnection! <= input('reset');
    }
    dm.input('dmi_addr').srcConnection! <= input('dmi_addr');
    dm.input('dmi_data_in').srcConnection! <= input('dmi_data_in');
    dm.input('dmi_op').srcConnection! <= input('dmi_op');
    dm.input('dmi_valid').srcConnection! <= input('dmi_valid');
    output('dmi_data_out') <= dm.output('dmi_data_out');

    for (final n in ['halted', 'running', 'unavail', 'reg_ready']) {
      dm.port('hart0_$n').getsLogic(Const(0));
    }
    dm.port('hart0_reg_rdata').getsLogic(Const(0, width: 64));

    connectInterfaces(dm.interface('sba'), slave.interface('bus'));
    pullUpInterface(dm.interface('bus'), newIntfName: 'bus');
  }
}

/// Drives the DMI interface of an [SbaTestTop] from the test.
class DmiDriver {
  final BridgeModule top;
  final Logic clk;
  final Logic _addr = Logic(name: 'drv_dmi_addr', width: 7);
  final Logic _data = Logic(name: 'drv_dmi_data_in', width: 32);
  final Logic _op = Logic(name: 'drv_dmi_op', width: 2);
  final Logic _valid = Logic(name: 'drv_dmi_valid');

  DmiDriver(this.top, this.clk) {
    top.input('dmi_addr').srcConnection! <= _addr;
    top.input('dmi_data_in').srcConnection! <= _data;
    top.input('dmi_op').srcConnection! <= _op;
    top.input('dmi_valid').srcConnection! <= _valid;
  }

  void idle() {
    _addr.inject(0);
    _data.inject(0);
    _op.inject(0);
    _valid.inject(0);
  }

  Future<void> _pulse(int op, int addr, int data) async {
    await clk.nextNegedge;
    _addr.inject(addr);
    _data.inject(data);
    _op.inject(op);
    _valid.inject(1);
    await clk.nextPosedge;
    await clk.nextNegedge;
    _valid.inject(0);
    _op.inject(0);
  }

  /// Writes [data] to DMI register [addr].
  Future<void> write(int addr, int data) => _pulse(2, addr, data);

  /// Reads DMI register [addr]. Only valid after a prior read, since the DM
  /// never resets dmi_data_out.
  Future<int> read(int addr) async {
    await _pulse(1, addr, 0);
    return top.output('dmi_data_out').value.toInt();
  }
}

/// sbcs (0x38) write value with the given fields set. [clearBusyError] and
/// [clearError] are write-1-to-clear.
int sbcsWord({
  int access = 2,
  bool readOnAddr = false,
  bool readOnData = false,
  bool autoIncrement = false,
  bool clearBusyError = false,
  int clearError = 0,
}) =>
    (clearBusyError ? 1 : 0) << 22 |
    (readOnAddr ? 1 : 0) << 20 |
    access << 17 |
    (autoIncrement ? 1 : 0) << 16 |
    (readOnData ? 1 : 0) << 15 |
    clearError << 12;

/// Polls sbcs until sbbusy clears.
Future<void> waitNotBusy(DmiDriver dmi, {int timeout = 400}) async {
  for (var i = 0; i < timeout; i++) {
    final sbcs = await dmi.read(0x38);
    if ((sbcs >> 21) & 1 == 0) return;
  }
  throw StateError('sbcs: sbbusy stuck');
}

/// Builds and runs [top], and returns a [DmiDriver] on it.
Future<DmiDriver> startTop(SbaTestTop top) async {
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  top.input('clk').srcConnection! <= clk;
  top.input('reset').srcConnection! <= reset;
  final dmi = DmiDriver(top, clk);
  dmi.idle();
  final regBus = RegBus.attach(top, clk, name: 'bus', kind: top.kind);

  await top.build();
  reset.inject(1);
  regBus.idle();
  Simulator.setMaxSimTime(400000);
  unawaited(Simulator.run());
  await clk.nextPosedge;
  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.inject(0);
  await clk.nextPosedge;
  return dmi;
}

void main() {
  tearDown(() async => Simulator.reset());

  for (final kind in HarborFabricKind.values) {
    sbaTests(kind);
  }
}

void sbaTests(HarborFabricKind kind) {
  test('32-bit write and read (${kind.name})', () async {
    final dmi = await startTop(SbaTestTop(kind));

    await dmi.write(0x38, sbcsWord(access: 2));
    await dmi.write(0x39, 0x0);
    await dmi.write(0x3C, 0x12345678);
    await waitNotBusy(dmi);

    await dmi.write(0x38, sbcsWord(access: 2, readOnAddr: true));
    await dmi.write(0x39, 0x0);
    await waitNotBusy(dmi);
    expect(await dmi.read(0x3C), 0x12345678);

    await Simulator.endSimulation();
  });

  test('8-bit write and read at each lane (${kind.name})', () async {
    final dmi = await startTop(SbaTestTop(kind));

    for (var lane = 0; lane < 4; lane++) {
      final value = 0x10 + lane;

      await dmi.write(0x38, sbcsWord(access: 0));
      await dmi.write(0x39, lane);
      await dmi.write(0x3C, value);
      await waitNotBusy(dmi);

      await dmi.write(0x38, sbcsWord(access: 0, readOnAddr: true));
      await dmi.write(0x39, lane);
      await waitNotBusy(dmi);
      expect(await dmi.read(0x3C), value, reason: 'lane $lane');
    }

    await Simulator.endSimulation();
  });

  test('16-bit write and read at each lane (${kind.name})', () async {
    final dmi = await startTop(SbaTestTop(kind));

    for (final addr in [4, 6]) {
      final value = 0x2000 + addr;

      await dmi.write(0x38, sbcsWord(access: 1));
      await dmi.write(0x39, addr);
      await dmi.write(0x3C, value);
      await waitNotBusy(dmi);

      await dmi.write(0x38, sbcsWord(access: 1, readOnAddr: true));
      await dmi.write(0x39, addr);
      await waitNotBusy(dmi);
      expect(
        await dmi.read(0x3C),
        value,
        reason: 'addr 0x${addr.toRadixString(16)}',
      );
    }

    await Simulator.endSimulation();
  });

  test('autoincrement, sbreadonaddr and sbreadondata chain over 3 words '
      '(${kind.name})', () async {
    final dmi = await startTop(SbaTestTop(kind));
    const values = [0x11111111, 0x22222222, 0x33333333];

    for (var i = 0; i < 3; i++) {
      await dmi.write(0x38, sbcsWord(access: 2));
      await dmi.write(0x39, i * 4);
      await dmi.write(0x3C, values[i]);
      await waitNotBusy(dmi);
    }

    // sbreadonaddr starts the first read. sbreadondata and
    // sbautoincrement chain the rest, one word at a time.
    await dmi.write(
      0x38,
      sbcsWord(
        access: 2,
        readOnAddr: true,
        readOnData: true,
        autoIncrement: true,
      ),
    );
    await dmi.write(0x39, 0x0);
    await waitNotBusy(dmi);

    for (var i = 0; i < 3; i++) {
      expect(await dmi.read(0x3C), values[i], reason: 'word $i');
      await waitNotBusy(dmi);
    }

    await Simulator.endSimulation();
  });

  test(
    'sbbusyerror when a second access arrives while busy (${kind.name})',
    () async {
      final dmi = await startTop(SbaTestTop(kind, waitStates: 6));

      await dmi.write(0x38, sbcsWord(access: 2));
      await dmi.write(0x39, 0x0);
      await dmi.write(0x3C, 0xcafebabe);
      await waitNotBusy(dmi);

      // Start a slow read, then collide with a second access before it ends.
      await dmi.write(0x38, sbcsWord(access: 2, readOnAddr: true));
      await dmi.write(0x39, 0x0);
      await dmi.write(0x3C, 0xdeaddead);
      await waitNotBusy(dmi);

      var sbcs = await dmi.read(0x38);
      expect((sbcs >> 22) & 1, 1, reason: 'sbbusyerror');
      expect((sbcs >> 12) & 0x7, 0, reason: 'sberror');

      // The colliding write never landed.
      expect(await dmi.read(0x3C), 0xcafebabe);

      await dmi.write(0x38, sbcsWord(access: 2, clearBusyError: true));
      sbcs = await dmi.read(0x38);
      expect((sbcs >> 22) & 1, 0, reason: 'sbbusyerror cleared');

      await Simulator.endSimulation();
    },
  );

  test('a bus error gives sberror 2 (${kind.name})', () async {
    final dmi = await startTop(SbaTestTop(kind));

    await dmi.write(0x38, sbcsWord(access: 2, readOnAddr: true));
    await dmi.write(0x39, 0x1C); // the slave's error word
    await waitNotBusy(dmi);

    var sbcs = await dmi.read(0x38);
    expect((sbcs >> 21) & 1, 0, reason: 'sbbusy');
    expect((sbcs >> 12) & 0x7, 2, reason: 'sberror');

    await dmi.write(0x38, sbcsWord(access: 2, clearError: 0x7));
    sbcs = await dmi.read(0x38);
    expect((sbcs >> 12) & 0x7, 0, reason: 'sberror cleared');

    await Simulator.endSimulation();
  });

  test('reset value, and no autoincrement or sbdata0 write after an error '
      '(${kind.name})', () async {
    final dmi = await startTop(SbaTestTop(kind));

    await dmi.read(0x38);
    expect((await dmi.read(0x38) >> 17) & 0x7, 2, reason: 'sbaccess reset');

    await dmi.write(
      0x38,
      sbcsWord(access: 2, readOnAddr: true, autoIncrement: true),
    );
    await dmi.write(0x39, 0x1C); // the slave's error word
    await waitNotBusy(dmi);
    expect((await dmi.read(0x38) >> 12) & 0x7, 2, reason: 'sberror');
    expect(await dmi.read(0x39), 0x1C, reason: 'sbaddress moved');

    await dmi.write(0x3C, 0xabcd1234);
    expect(await dmi.read(0x3C), 0, reason: 'sbdata0 written');

    await Simulator.endSimulation();
  });

  test('a misaligned access gives sberror 3 (${kind.name})', () async {
    final dmi = await startTop(SbaTestTop(kind));

    await dmi.write(0x38, sbcsWord(access: 2, readOnAddr: true));
    await dmi.write(0x39, 0x1); // misaligned for a 32-bit access

    final sbcs = await dmi.read(0x38);
    expect((sbcs >> 21) & 1, 0, reason: 'sbbusy');
    expect((sbcs >> 12) & 0x7, 3, reason: 'sberror');

    await Simulator.endSimulation();
  });
}
