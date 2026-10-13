import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Xilinx speed grade in the openXC7 Makefile, the differential board clock,
/// and the parallel RGB display output.
void main() {
  tearDown(() async => Simulator.reset());

  group('speed grade', () {
    String line(String mk, String needle) =>
        mk.split('\n').firstWhere((l) => l.contains(needle));

    test('defaults to -1, so existing targets do not change', () {
      final mk = HarborBoard.get(
        'arty-s7-50',
      ).fpgaTarget().generateMakefile('Top');
      expect(mk, contains('PART ?= \$(DEVICE)\$(PACKAGE)-1'));
      const t = HarborFpgaTarget.artix7(
        device: 'xc7a35t',
        package: 'csg324',
        useOpenXc7: true,
      );
      expect(t.speedGrade, '1');
    });

    test('-2 reaches PART, and part_file and part_name follow PART', () {
      const t = HarborFpgaTarget.artix7(
        device: 'xc7a200t',
        package: 'fbg484',
        speedGrade: '2',
        useOpenXc7: true,
      );
      final mk = t.generateMakefile('Top');
      expect(mk, contains('PART ?= \$(DEVICE)\$(PACKAGE)-2'));
      expect(
        line(mk, 'xc7frames2bit'),
        contains(
          '--part_file \$(XRAY_DB)/\$(FAMILY)/\$(PART)/part.yaml '
          '--part_name \$(PART)',
        ),
      );
      expect(line(mk, 'fasm2frames'), contains('--part \$(PART)'));
      // The chipdb is per device and package, not per grade.
      expect(
        line(mk, 'CHIPDB ?='),
        'CHIPDB ?= \$(NEXTPNR_XILINX_CHIPDB)/\$(DEVICE)\$(PACKAGE).bin',
      );
    });
  });

  group('differential board clock', () {
    HarborSoC soc(HarborDeviceTarget target) =>
        HarborSoC(name: 'DiffClk', compatible: 'test,diff-clk', target: target);

    test('a Xilinx target adds clk_n and an IBUFDS', () async {
      final s = soc(
        const HarborFpgaTarget.artix7(
          device: 'xc7a200t',
          package: 'fbg484',
          clockNPortName: 'clk_n',
          useOpenXc7: true,
        ),
      );
      s.addPeripheral(HarborUart(baseAddress: 0x10000000));
      await s.build();
      expect(s.inputs.keys, containsAll(['clk', 'clk_n']));
      final sv = s.generateSynth();
      expect(sv, contains(RegExp(r'IBUFDS\s+sysclk_ibufds')));
    });

    test('a single-ended target has no IBUFDS', () async {
      final s = soc(HarborBoard.get('arty-s7-50').fpgaTarget());
      s.addPeripheral(HarborUart(baseAddress: 0x10000000));
      await s.build();
      expect(s.inputs.keys, isNot(contains('clk_n')));
      expect(s.generateSynth(), isNot(contains('IBUFDS')));
    });

    test('a non-Xilinx target refuses it', () {
      expect(
        () => soc(
          const HarborFpgaTarget(
            name: 'ecp5-lfe5u-85f',
            vendor: HarborFpgaVendor.ecp5,
            device: 'lfe5u-85f',
            package: 'CABGA381',
            clockNPortName: 'clk_n',
          ),
        ),
        throwsUnsupportedError,
      );
    });
  });

  test('parallel RGB display has RGB and sync and no TMDS lanes', () async {
    Logic l([int w = 1]) => Logic(width: w);
    final d = HarborDualClockDisplay(
      target: HarborBoard.get('ax7203').fpgaTarget(),
      timing: const HarborDisplayTiming.vga640x480(),
      pixelClk: l(),
      pixelReset: l(),
      shiftClk: l(),
      shiftReset: l(),
      sysClk: l(),
      sysReset: l(),
      enable: l(),
      fbBase: l(32),
      mDataIn: l(32),
      mAck: l(),
      outputType: HarborDisplayInterface.parallelRgb,
    );
    await d.build();
    expect(
      d.outputs.keys,
      containsAll(['red', 'green', 'blue', 'de', 'hsync', 'vsync']),
    );
    expect(d.outputs.keys, isNot(contains('gpdi')));
    expect(d.outputs.keys, isNot(contains('gpdi_n')));
    expect(d.outputs.keys, containsAll(['rgb', 'pclk']));

    final tmds = HarborDualClockDisplay(
      target: HarborBoard.get('ax7203').fpgaTarget(),
      timing: const HarborDisplayTiming.vga640x480(),
      pixelClk: l(),
      pixelReset: l(),
      shiftClk: l(),
      shiftReset: l(),
      sysClk: l(),
      sysReset: l(),
      enable: l(),
      fbBase: l(32),
      mDataIn: l(32),
      mAck: l(),
    );
    expect(tmds.definitionName, isNot(d.definitionName));
  });

  group('DDR train-SERDES pre-place', () {
    test('xc7a200t pins each lane to its bank 35 site', () {
      final py = HarborBoard.get(
        'ax7203',
      ).fpgaTarget().generateDdrPreplacePy(lanes: 4);
      expect(
        py,
        contains(
          "pairs = [('0', 'X1Y187'), ('1', 'X1Y175'), ('2', 'X1Y174'), "
          "('3', 'X1Y161')]",
        ),
      );
    });

    test('xc7s50 keeps the Arty sites', () {
      final py = HarborBoard.get(
        'arty-s7-50',
      ).fpgaTarget().generateDdrPreplacePy(lanes: 2);
      expect(py, contains("pairs = [('0', 'X0Y145'), ('1', 'X0Y141')]"));
      expect(py, contains('(X0Y149, which has'));
    });

    test('an unknown device or too many lanes throws', () {
      const t = HarborFpgaTarget.artix7(
        device: 'xc7a35t',
        package: 'csg324',
        useOpenXc7: true,
      );
      expect(() => t.generateDdrPreplacePy(lanes: 2), throwsArgumentError);
      expect(
        () => HarborBoard.get(
          'arty-s7-50',
        ).fpgaTarget().generateDdrPreplacePy(lanes: 4),
        throwsArgumentError,
      );
    });
  });

  test('xc7a200t IDCODE', () {
    expect(HarborBoard.get('ax7203').fpgaTarget().jtagIdcode, 0x13636093);
  });

  test('parallel RGB sync idles inactive while in reset', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic()..inject(1);
    const timing = HarborDisplayTiming.vga640x480();
    final dual = HarborDualClockDisplay(
      target: const HarborSimTarget(),
      timing: timing,
      pixelClk: clk,
      pixelReset: reset,
      shiftClk: clk,
      shiftReset: reset,
      sysClk: clk,
      sysReset: reset,
      enable: Const(0),
      fbBase: Const(0, width: 32),
      mDataIn: Const(0, width: 32),
      mAck: Const(0),
      outputType: HarborDisplayInterface.parallelRgb,
    );
    final single = HarborFramebufferDisplay(
      target: const HarborSimTarget(),
      timing: timing,
      pixelClk: clk,
      pixelReset: reset,
      shiftClk: clk,
      shiftReset: reset,
      enable: Const(0),
      fbBase: Const(0, width: 32),
      mDataIn: Const(0, width: 32),
      mAck: Const(0),
      outputType: HarborDisplayInterface.parallelRgb,
    );
    await dual.build();
    await single.build();
    Simulator.setMaxSimTime(200);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    await clk.nextNegedge;
    // 640x480 has negative sync, so the idle level is 1.
    for (final s in [dual.hsync, dual.vsync, single.hsync, single.vsync]) {
      expect(s.value.toInt(), 1, reason: s.name);
    }
    await Simulator.endSimulation();
  });

  group('SSTL internal VREF', () {
    const sed =
        "sed -i 's/\\.VREF\\.V_675_MV\$\$/.VREF.V_750_MV/' \$(TOP).fasm";

    test('AX7203 SSTL15 rewrites the fasm VREF to 0.75 V', () {
      final t = HarborBoard.get('ax7203').fpgaTarget();
      expect(t.sstlVrefMv, 750);
      expect(t.generateMakefile('Top'), contains(sed));
    });

    test('Arty S7 SSTL135 keeps the 0.675 V nextpnr writes', () {
      final t = HarborBoard.get('arty-s7-50').fpgaTarget();
      expect(t.sstlVrefMv, 675);
      expect(t.generateMakefile('Top'), isNot(contains('V_750_MV')));
    });
  });

  test('the differential clock net carries the board clock constraint', () {
    final xdc = HarborBoard.get('ax7203').fpgaTarget().generateConstraints();
    expect(xdc, contains('create_clock -period 5.000 [get_ports clk]'));
    expect(xdc, contains('create_clock -period 5.000 [get_nets sysclk_diff]'));
    expect(
      HarborBoard.get('arty-s7-50').fpgaTarget().generateConstraints(),
      isNot(contains('get_nets')),
    );
  });
}
