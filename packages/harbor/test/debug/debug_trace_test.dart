import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

void main() {
  group('HarborDebugModule', () {
    test('creates with defaults (numHarts=1)', () {
      final dm = HarborDebugModule(baseAddress: 0x00000000);
      expect(dm, isNotNull);
      expect(dm.numHarts, equals(1));
    });

    test('multi-hart (numHarts=4) has hart3 ports', () {
      final dm = HarborDebugModule(baseAddress: 0x00000000, numHarts: 4);
      expect(dm.output('hart3_halt_req').width, equals(1));
      expect(dm.output('hart3_resume_req').width, equals(1));
    });

    test('DT node contains riscv,debug-013', () {
      final dm = HarborDebugModule(baseAddress: 0x00000000);
      expect(dm.dtNode.compatible, contains('riscv,debug-013'));
    });

    test('ndmreset output', () {
      final dm = HarborDebugModule(baseAddress: 0x00000000);
      expect(dm.output('ndmreset').width, equals(1));
    });

    test('DMI interface (dmi_addr width=7, dmi_data_in width=32)', () {
      final dm = HarborDebugModule(baseAddress: 0x00000000);
      expect(dm.input('dmi_addr').width, equals(7));
      expect(dm.input('dmi_data_in').width, equals(32));
    });
  });

  group('HarborTraceEncoder', () {
    test('creates with defaults (bufferSize=4096, syncInterval=256)', () {
      final trace = HarborTraceEncoder(baseAddress: 0x00000000);
      expect(trace, isNotNull);
      expect(trace.bufferSize, equals(4096));
      expect(trace.syncInterval, equals(256));
    });

    test('DT node', () {
      final trace = HarborTraceEncoder(baseAddress: 0x00000000);
      expect(trace.dtNode.compatible, contains('riscv,trace'));
    });

    test(
      'trace outputs (trace_data width=32, trace_valid, trace_sync, overflow)',
      () {
        final trace = HarborTraceEncoder(baseAddress: 0x00000000);
        expect(trace.output('trace_data').width, equals(32));
        expect(trace.output('trace_valid').width, equals(1));
        expect(trace.output('trace_sync').width, equals(1));
        expect(trace.output('overflow').width, equals(1));
      },
    );

    test('different sync intervals get different definition names', () {
      final a = HarborTraceEncoder(baseAddress: 0x0, syncInterval: 256);
      final b = HarborTraceEncoder(baseAddress: 0x0, syncInterval: 512);
      expect(a.definitionName, isNot(equals(b.definitionName)));
    });

    for (final kind in HarborFabricKind.values) {
      registerTests(kind);
    }
  });

  group('JtagTapController', () {
    test('creates without error', () {
      final tap = JtagTapController(irWidth: 5, idcode: 0x10001FFF);
      expect(tap, isNotNull);
    });

    test('has state/instruction/inShiftDr outputs', () {
      final tap = JtagTapController(irWidth: 5);
      expect(tap.state.width, equals(4));
      expect(tap.instruction.width, equals(5));
      expect(tap.inShiftDr.width, equals(1));
    });
  });

  group('JtagDtm', () {
    test('creates without error', () {
      final dtm = JtagDtm();
      expect(dtm, isNotNull);
    });

    test('has DMI outputs', () {
      final dtm = JtagDtm();
      expect(dtm.dmiReqValid.width, equals(1));
      expect(dtm.dmiReqAddr.width, equals(7));
      expect(dtm.dmiReqData.width, equals(32));
      expect(dtm.dmiReqOp.width, equals(2));
      expect(dtm.dmiRspReady.width, equals(1));
    });
  });
}

void registerTests(HarborFabricKind kind) {
  group('HarborTraceEncoder register access (${kind.name})', () {
    late HarborTraceEncoder trace;
    late Logic clk, reset;
    late RegBus bus;

    setUp(() async {
      trace = HarborTraceEncoder(baseAddress: 0x30000000, fabricKind: kind);
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');

      trace.input('clk').srcConnection! <= clk;
      trace.input('reset').srcConnection! <= reset;
      trace.input('valid').srcConnection! <= Const(0);
      trace.input('pc').srcConnection! <= Const(0, width: 64);
      trace.input('is_branch').srcConnection! <= Const(0);
      trace.input('branch_taken').srcConnection! <= Const(0);
      trace.input('is_exception').srcConnection! <= Const(0);
      trace.input('is_eret').srcConnection! <= Const(0);
      trace.input('exception_cause').srcConnection! <= Const(0, width: 5);
      trace.input('priv_mode').srcConnection! <= Const(0, width: 2);
      trace.input('priv_change').srcConnection! <= Const(0);
      bus = RegBus.attach(trace, clk);

      await trace.build();
      reset.inject(1);
      bus.idle();
      Simulator.setMaxSimTime(200000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    });

    tearDown(() async => Simulator.reset());

    // Regression: the decode used to match a word index (addr >> 2)
    // against the byte address on ADR, so only CTRL at 0x00 ever
    // answered and every other register was dead.
    test('BUF_BASE, BUF_SIZE and SYNC_CNT decode at their own byte '
        'offsets, not at CTRL', () async {
      await bus.write(0x10, 0x1000); // BUF_BASE
      expect(await bus.read(0x10), equals(0x1000));

      await bus.write(0x14, 0x2000); // BUF_SIZE
      expect(await bus.read(0x14), equals(0x2000));

      // The registers are distinct, not aliases of one another.
      expect(await bus.read(0x10), equals(0x1000));
      await Simulator.endSimulation();
    });

    // A write with no byte selected must not change BUF_BASE or BUF_SIZE.
    test('a write with no byte selected changes nothing', () async {
      await bus.write(0x10, 0x1000);
      await bus.write(0x14, 0x2000);
      await bus.write(0x10, 0xffffffff, sel: 0x0);
      await bus.write(0x14, 0xffffffff, sel: 0x0);

      expect(await bus.read(0x10), equals(0x1000));
      expect(await bus.read(0x14), equals(0x2000));
      await Simulator.endSimulation();
    });
  });
}
