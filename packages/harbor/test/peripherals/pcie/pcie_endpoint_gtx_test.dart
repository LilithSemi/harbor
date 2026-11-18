import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _kintex = HarborFpgaTarget.kintex7(
  device: 'xc7k325t',
  package: 'ffg900',
  speedGrade: '2',
  useOpenXc7: true,
);

const _artix = HarborFpgaTarget.artix7(
  device: 'xc7a200t',
  package: 'fbg484',
  useOpenXc7: true,
);

void main() {
  tearDown(() async => Simulator.reset());

  HarborPcieEndpoint endpoint(
    HarborDeviceTarget target, {
    bool? gen2,
    bool waitRxCdrLock = false,
    HarborGtxPcieTimeouts gtxTimeouts = const HarborGtxPcieTimeouts(),
    Map<String, String> hardBlockOverrides = const {},
    bool debugSkipTxPhaseAlign = false,
    bool debugBuild = false,
  }) => HarborPcieEndpoint(
    target: target,
    refClkP: Logic(),
    refClkN: Logic(),
    perstN: Logic(),
    rxP: Logic(),
    rxN: Logic(),
    rxReady: Logic(),
    txData: Logic(width: 64),
    txKeep: Logic(width: 8),
    txLast: Logic(),
    txValid: Logic(),
    gen2: gen2,
    waitRxCdrLock: waitRxCdrLock,
    gtxTimeouts: gtxTimeouts,
    hardBlockOverrides: hardBlockOverrides,
    debugSkipTxPhaseAlign: debugSkipTxPhaseAlign,
    debugBuild: debugBuild,
  );

  String param(String sv, String name) {
    final m = RegExp('\\.$name\\(([^)]*)\\)').firstMatch(sv);
    expect(m, isNotNull, reason: name);
    return m!.group(1)!;
  }

  test('a Kintex-7 target gets the GTX PHY at 5 GT/s', () async {
    final dut = endpoint(_kintex);
    await dut.build();
    final sv = dut.dumpSystemVerilog();
    expect(dut.gtx, isTrue);
    expect(dut.gen2, isTrue);
    expect(dut.definitionName, contains('Gtx_G2'));
    expect(sv, contains('GTXE2_CHANNEL'));
    expect(sv, isNot(contains('GTPE2_CHANNEL')));
    expect(sv, contains('IBUFDS_GTE2'));
    expect(sv, contains('BUFGCTRL'));
    expect(param(sv, 'LINK_CAP_MAX_LINK_SPEED'), "4'h2");
    expect(param(sv, 'LINK_CTRL2_TARGET_LINK_SPEED'), "4'h2");
    expect(param(sv, 'USER_CLK_FREQ'), '2');
    expect(param(sv, 'LINK_STATUS_SLOT_CLOCK_CONFIG'), '"TRUE"');
    expect(dut.phyLocks!.width, 5);
    expect(dut.phyTimeoutFlags!.width, 5);
    expect(dut.pclkSel!.width, 1);
    expect(dut.ltssmStateOut!.width, 6);
    expect(dut.phyTxSync!.width, 4);
    expect(dut.phyRxDebug!.width, 15);
    expect(dut.phyTxSyncSeen!.width, 3);
    expect(dut.phyPhAlignCount!.width, 4);
    expect(dut.resetState.width, 4);
    expect(dut.linkRetrains!.width, 8);
  });

  test('userClkHz is the frequency of the MMCM user clock', () async {
    final gen2 = endpoint(_kintex);
    await gen2.build();
    final sv2 = gen2.dumpSystemVerilog();
    expect(gen2.userClkHz, 125000000);
    expect(
      HarborPipeClock.vcoHz ~/ int.parse(param(sv2, 'CLKOUT2_DIVIDE')),
      gen2.userClkHz,
    );
    expect(
      HarborPipeClock.userClkFreqCode(int.parse(param(sv2, 'CLKOUT2_DIVIDE'))),
      int.parse(param(sv2, 'USER_CLK_FREQ')),
    );

    final gen1 = endpoint(_kintex, gen2: false);
    await gen1.build();
    final sv1 = gen1.dumpSystemVerilog();
    expect(gen1.userClkHz, 62500000);
    expect(
      HarborPipeClock.vcoHz ~/ int.parse(param(sv1, 'CLKOUT2_DIVIDE')),
      gen1.userClkHz,
    );
    expect(param(sv1, 'LINK_CAP_MAX_LINK_SPEED'), "4'h1");
    expect(param(sv1, 'USER_CLK_FREQ'), '1');
    expect(sv1, isNot(contains('BUFGCTRL')));
    expect(gen1.definitionName, isNot(contains('G2')));
  });

  test('an Artix-7 target keeps the GTP PHY at 2.5 GT/s', () async {
    final dut = endpoint(_artix);
    await dut.build();
    final sv = dut.dumpSystemVerilog();
    expect(dut.gtx, isFalse);
    expect(dut.gen2, isFalse);
    expect(dut.userClkHz, 62500000);
    expect(sv, contains('GTPE2_CHANNEL'));
    expect(sv, isNot(contains('GTXE2_CHANNEL')));
    expect(dut.definitionName, isNot(contains('Gtx')));
    expect(dut.phyLocks, isNull);
    expect(dut.phyTimeoutFlags, isNull);
    expect(
      () => endpoint(_artix, gen2: true),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('the GTX options reach the PHY and the hard block', () async {
    final dut = endpoint(
      _kintex,
      hardBlockOverrides: {'PL_FAST_TRAIN': '"TRUE"'},
      gtxTimeouts: const HarborGtxPcieTimeouts(linkWait: 0),
      debugBuild: true,
    );
    await dut.build();
    final sv = dut.dumpSystemVerilog();
    expect(param(sv, 'PL_FAST_TRAIN'), '"TRUE"');
    expect(dut.linkRetrains, isNull);
    expect(dut.definitionName, isNot(contains('LinkWd')));
  });

  test('derived hard block parameters cannot be overridden', () {
    for (final key in [
      'USER_CLK_FREQ',
      'LINK_STATUS_SLOT_CLOCK_CONFIG',
      'LINK_CAP_MAX_LINK_SPEED',
      'LINK_CTRL2_TARGET_LINK_SPEED',
    ]) {
      expect(
        () =>
            endpoint(_kintex, hardBlockOverrides: {key: '1'}, debugBuild: true),
        throwsArgumentError,
        reason: key,
      );
    }
  });

  test('options are in the definition name', () {
    String name({Map<String, String> ov = const {}, bool cdr = false}) =>
        endpoint(
          _kintex,
          hardBlockOverrides: ov,
          waitRxCdrLock: cdr,
          debugBuild: true,
        ).definitionName;
    final names = {
      name(),
      name(cdr: true),
      name(ov: {'PL_FAST_TRAIN': '"TRUE"'}),
      name(ov: {'PL_FAST_TRAIN': '"FALSE"'}),
    };
    expect(names, hasLength(4));
    expect(
      name(ov: {'PL_FAST_TRAIN': '"TRUE"'}),
      name(ov: {'PL_FAST_TRAIN': '"TRUE"'}),
    );
  });

  test('hard block overrides need a debug build', () {
    expect(
      () => endpoint(_kintex, hardBlockOverrides: {'PL_FAST_TRAIN': '"TRUE"'}),
      throwsArgumentError,
    );
  });

  test('timeouts are in the definition name', () {
    String name(HarborGtxPcieTimeouts t) =>
        endpoint(_kintex, gtxTimeouts: t).definitionName;
    final names = {
      name(const HarborGtxPcieTimeouts()),
      name(const HarborGtxPcieTimeouts(txSync: 1 << 14)),
      name(const HarborGtxPcieTimeouts(clockSettle: 1 << 9)),
    };
    expect(names, hasLength(3));
  });

  test('gen1 on Kintex-7 states the user clock and the slot clock', () async {
    final dut = endpoint(_kintex, gen2: false);
    await dut.build();
    final sv = dut.dumpSystemVerilog();
    expect(param(sv, 'LINK_STATUS_SLOT_CLOCK_CONFIG'), '"TRUE"');
    expect(param(sv, 'USER_CLK_FREQ'), '1');
  });

  test('the TX sync skip is a debug build option', () {
    expect(
      () => endpoint(_kintex, debugSkipTxPhaseAlign: true),
      throwsArgumentError,
    );
    expect(
      endpoint(
        _kintex,
        debugSkipTxPhaseAlign: true,
        debugBuild: true,
      ).definitionName,
      contains('DebugNoPhAlign'),
    );
  });

  test('a GTP endpoint has no GTX taps', () async {
    final dut = endpoint(_artix);
    await dut.build();
    expect(dut.ltssmStateOut, isNull);
    expect(dut.outputs.containsKey('ltssm_state_out'), isFalse);
  });

  test('other targets are rejected', () {
    expect(
      () => endpoint(
        const HarborFpgaTarget.ecp5(device: 'lfe5u-85f', package: 'CABGA381'),
      ),
      throwsUnsupportedError,
    );
  });
}
