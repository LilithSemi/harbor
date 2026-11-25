import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

class _Cpu extends BridgeModule {
  _Cpu() : super('LocalResetCpu', name: 'cpu') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final i = addInterface(
      WishboneInterface(WishboneConfig(addressWidth: 32, dataWidth: 32)),
      name: 'dataBus',
      role: PairRole.provider,
    ).internalInterface!;
    for (final e in i.getPorts([PairDirection.fromProvider]).entries) {
      final w = e.value.width;
      e.value <= addInput('p_${e.key}', Logic(width: w), width: w);
    }
    for (final e in i.getPorts([PairDirection.fromConsumer]).entries) {
      addOutput('p_${e.key}', width: e.value.width) <= e.value;
    }
  }

  void pullUp(HarborSoC soc) {
    for (final n in [...inputs.keys, ...outputs.keys]) {
      if (!n.startsWith('p_')) continue;
      soc.pullUpPort(port(n), newPortName: 'cpu_${n.substring(2)}');
    }
  }
}

const _ecp5 = HarborFpgaTarget.ecp5(
  device: 'lfe5u-85f',
  package: 'CABGA381',
  frequency: 25000000,
  pinMap: {'clk': 'G2'},
);

HarborSoC _soc(HarborDeviceTarget target, Set<String> local) => HarborSoC(
  name: 'LocalResetSoc',
  compatible: 'test,local-reset',
  target: target,
  clocks: [
    HarborClockConfig.fixed(
      name: 'sys',
      frequency: 50000000,
      sourceFrequency: 25000000,
      isPrimary: false,
    ),
  ],
  localResetDomains: local,
);

Future<List<HarborRegisteredResetBranch>> _branches(
  HarborDeviceTarget target,
  Set<String> local,
) async {
  final soc = HarborSoC(
    name: 'LocalResetSoc',
    compatible: 'test,local-reset',
    target: target,
    clocks: [
      HarborClockConfig.fixed(
        name: 'sys',
        frequency: 50000000,
        sourceFrequency: 25000000,
        isPrimary: false,
      ),
    ],
    localResetDomains: local,
  );
  final cpu = soc.addMaster(_Cpu());
  soc.addPeripheral(
    HarborUart(baseAddress: 0x10000000, busAddressWidth: 32, busDataWidth: 32),
  );
  cpu.pullUp(soc);
  soc.buildFabric();
  await soc.build();
  expect(soc.resetBranchSource('sys'), isNotNull);
  expect(soc.resetBranchSource('none'), isNull);
  final branches = soc.subModules
      .whereType<HarborRegisteredResetBranch>()
      .toList();
  if (branches.isNotEmpty) {
    expect(
      harborSynthesisMarks(soc).preserve,
      contains('HarborRegisteredResetBranch'),
    );
  }
  return branches;
}

void main() {
  tearDown(() async => Simulator.reset());

  test('a local reset domain gives each module its own release flop', () async {
    final branches = await _branches(_ecp5, {'sys'});
    expect(
      branches.map((b) => b.name),
      containsAll([
        'cpu_reset_branch',
        'uart_reset_branch',
        'fabric_reset_branch',
      ]),
    );
  });

  test('a register stage and the fabric take their own release flop', () async {
    final soc = _soc(_ecp5, {'sys'});
    final cpu = soc.addMaster(_Cpu(), pipeline: true);
    soc.addPeripheral(
      HarborUart(
        baseAddress: 0x10000000,
        busAddressWidth: 32,
        busDataWidth: 32,
      ),
    );
    cpu.pullUp(soc);
    soc.buildFabric(pipeline: true);
    await soc.build();
    final names = soc.subModules
        .whereType<HarborRegisteredResetBranch>()
        .map((b) => b.name)
        .toList();
    // A master with both pipeline flags gets two stages, each with its own.
    expect(
      names,
      unorderedEquals([
        'cpu_reset_branch',
        'uart_reset_branch',
        'fabric_reset_branch',
        'wishbone_reg_0_reset_branch',
        'wishbone_reg_1_reset_branch',
      ]),
    );
    expect(names.toSet(), hasLength(names.length));
    final sys = soc.clockDomain('sys')!;
    final readers = [
      for (final m in soc.subModules)
        if (m is! HarborRegisteredResetBranch)
          for (final i in m.inputs.values)
            if (identical(i.srcConnections.firstOrNull, sys.reset)) m.name,
    ];
    expect(readers, isEmpty);
  });

  test('an unknown local reset domain throws at buildFabric', () {
    final soc = _soc(_ecp5, {'sys', 'nope'});
    soc.addMaster(_Cpu()).pullUp(soc);
    expect(
      soc.buildFabric,
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('nope')),
      ),
    );
  });

  test('a target with no local reset support throws', () {
    for (final t in [
      const HarborFpgaTarget.ice40(
        device: 'up5k',
        package: 'sg48',
        pinMap: {'clk': '35'},
      ),
      const HarborFpgaTarget.artix7(
        device: 'xc7a200t',
        package: 'fbg484',
        useOpenXc7: false,
      ),
    ]) {
      expect(() => _soc(t, {'sys'}), throwsArgumentError);
    }
  });

  test('no local reset domain adds no branch', () async {
    expect(await _branches(_ecp5, {}), isEmpty);
  });

  test('the sim target adds no branch', () async {
    expect(
      await _branches(const HarborSimTarget(frequency: 25000000), {'sys'}),
      isEmpty,
    );
  });

  test(
    'the branch asserts at once and releases one edge after its input',
    () async {
      final clk = SimpleClockGenerator(10).clk;
      final hold = Logic();
      final release = Logic();
      final branch = HarborRegisteredResetBranch(name: 'branch');
      branch.input('clk').srcConnection! <= clk;
      branch.input('reset_assert').srcConnection! <= hold;
      branch.input('release_in').srcConnection! <= release;
      await branch.build();
      final out = branch.output('reset_out');

      hold.inject(1);
      release.inject(0);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      expect(out.value.toBool(), isTrue);
      hold.inject(0);
      await clk.nextPosedge;
      expect(out.value.toBool(), isTrue);
      release.inject(1);
      await clk.nextNegedge;
      expect(out.value.toBool(), isTrue);
      await clk.nextPosedge;
      await clk.nextNegedge;
      expect(out.value.toBool(), isFalse);
      hold.inject(1);
      await clk.nextPosedge;
      expect(out.value.toBool(), isTrue);
      await Simulator.endSimulation();
    },
  );

  test('every copy sets at once and releases on the same edge', () async {
    final clk = SimpleClockGenerator(10).clk;
    final hold = Logic()..inject(1);
    final release = Logic()..inject(0);
    final branch = HarborRegisteredResetBranch(name: 'branch', copies: 3);
    branch.input('clk').srcConnection! <= clk;
    branch.input('reset_assert').srcConnection! <= hold;
    branch.input('release_in').srcConnection! <= release;
    await branch.build();
    final outs = branch.resetOuts;
    expect(outs, hasLength(3));
    List<bool> values() => [for (final o in outs) o.value.toBool()];

    unawaited(Simulator.run());
    await clk.nextPosedge;
    expect(values(), [true, true, true]);
    hold.inject(0);
    await clk.nextPosedge;
    release.inject(1);
    await clk.nextNegedge;
    expect(values(), [true, true, true]);
    await clk.nextPosedge;
    await clk.nextNegedge;
    expect(values(), [false, false, false]);
    // Assertion does not wait for an edge.
    final t = Simulator.time;
    List<bool>? between;
    Simulator.registerAction(t + 1, () => hold.put(1));
    Simulator.registerAction(t + 2, () => between = values());
    await clk.nextPosedge;
    expect(between, [true, true, true]);
    await Simulator.endSimulation();
  });

  test('each copy is its own flop in the SV and kept in synthesis', () async {
    final branch = HarborRegisteredResetBranch(name: 'branch', copies: 4);
    branch.input('clk').srcConnection! <= Logic();
    branch.input('reset_assert').srcConnection! <= Logic();
    branch.input('release_in').srcConnection! <= Logic();
    await branch.build();
    final sv = SynthBuilder(
      branch,
      SystemVerilogSynthesizer(),
    ).getSynthFileContents().map((f) => f.contents).join();
    final flops = RegExp(
      r'^\s*(reset_q(?:_\d+)?) <= \(~release_in\);',
      multiLine: true,
    ).allMatches(sv).map((m) => m.group(1)).toSet();
    expect(flops, {'reset_q', 'reset_q_1', 'reset_q_2', 'reset_q_3'});
    expect(sv, contains('posedge reset_assert'));
    for (var i = 0; i < 4; i++) {
      final name = HarborRegisteredResetBranch.outputName(i);
      expect(sv, contains('assign $name = reset_q${i == 0 ? '' : '_$i'};'));
    }

    final marks = harborSynthesisMarks(branch).preserve;
    expect(marks, ['HarborRegisteredResetBranch_x4']);
    final tcl = _ecp5.generateYosysTcl('Top', preserveRegisterModules: marks);
    expect(
      tcl,
      contains(r'setattr -set keep 1 HarborRegisteredResetBranch_x4/t:$*ff*'),
    );
    expect(
      () => HarborRegisteredResetBranch(name: 'none', copies: 0),
      throwsArgumentError,
    );
  });

  test('resetCopies gives kept copies in a local reset domain', () async {
    final soc = _soc(_ecp5, {'sys'});
    soc.addMaster(_Cpu()).pullUp(soc);
    soc.buildFabric();
    final copies = soc.resetCopies('sys', 'user_reset_branch', copies: 3);
    expect(copies.toSet(), hasLength(3));
    for (final (i, c) in copies.indexed) {
      soc.addOutput('user_reset_$i') <= c;
    }
    await soc.build();
    final branch = soc.subModules
        .whereType<HarborRegisteredResetBranch>()
        .singleWhere((b) => b.name == 'user_reset_branch');
    expect(branch.copies, 3);
    expect(branch.resetOuts, copies);
    expect(() => soc.resetCopies('none', 'x'), throwsArgumentError);
  });

  test('resetCopies gives the domain reset with no local reset', () {
    final soc = _soc(_ecp5, {});
    final sys = soc.clockDomain('sys')!;
    expect(soc.resetCopies('sys', 'user_reset_branch', copies: 2), [
      sys.reset,
      sys.reset,
    ]);
  });
}
