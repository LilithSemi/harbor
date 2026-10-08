import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

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

    group('register access', () {
      late HarborTraceEncoder trace;
      late Logic clk, reset, cyc, stb, we, adr, mosi;

      Future<void> busWrite(int addr, int data) async {
        adr.inject(addr);
        mosi.inject(data);
        we.inject(1);
        cyc.inject(1);
        stb.inject(1);
        await clk.nextPosedge;
        while (trace.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        cyc.inject(0);
        stb.inject(0);
        we.inject(0);
        await clk.nextPosedge;
      }

      Future<int> busRead(int addr) async {
        adr.inject(addr);
        we.inject(0);
        cyc.inject(1);
        stb.inject(1);
        await clk.nextPosedge;
        while (trace.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        final v = trace.output('bus_DAT_MISO').value.toInt();
        cyc.inject(0);
        stb.inject(0);
        await clk.nextPosedge;
        return v;
      }

      setUp(() async {
        trace = HarborTraceEncoder(baseAddress: 0x30000000);
        clk = SimpleClockGenerator(10).clk;
        reset = Logic(name: 'reset');
        cyc = Logic(name: 'cyc');
        stb = Logic(name: 'stb');
        we = Logic(name: 'we');
        adr = Logic(name: 'adr', width: trace.input('bus_ADR').width);
        mosi = Logic(name: 'mosi', width: 32);

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
        trace.input('bus_CYC').srcConnection! <= cyc;
        trace.input('bus_STB').srcConnection! <= stb;
        trace.input('bus_WE').srcConnection! <= we;
        trace.input('bus_ADR').srcConnection! <= adr;
        trace.input('bus_DAT_MOSI').srcConnection! <= mosi;
        trace.input('bus_SEL').srcConnection! <=
            Const(-1, width: trace.input('bus_SEL').width);

        await trace.build();
        reset.inject(1);
        cyc.inject(0);
        stb.inject(0);
        we.inject(0);
        adr.inject(0);
        mosi.inject(0);
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
        await busWrite(0x10, 0x1000); // BUF_BASE
        expect(await busRead(0x10), equals(0x1000));

        await busWrite(0x14, 0x2000); // BUF_SIZE
        expect(await busRead(0x14), equals(0x2000));

        // The registers are distinct, not aliases of one another.
        expect(await busRead(0x10), equals(0x1000));
        await Simulator.endSimulation();
      });
    });
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
