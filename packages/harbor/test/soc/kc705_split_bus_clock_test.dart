import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../peripherals/ddr3_fast_bench.dart' show ax7203;

const _ddrPads = [
  'sdram_ck',
  'sdram_ck_n',
  'sdram_cke',
  'sdram_cs_n',
  'sdram_ras_n',
  'sdram_cas_n',
  'sdram_we_n',
  'sdram_ba',
  'sdram_addr',
  'sdram_dm',
  'sdram_dq',
  'sdram_dqs',
  'sdram_dqs_n',
  'sdram_odt',
  'sdram_reset_n',
];

const _ddrExtra = {
  'sdram_ck': 'AG10 DIFF_SSTL15',
  'sdram_ck_n': 'AH10 DIFF_SSTL15',
  'sdram_cke': 'AF10 SSTL15',
  'sdram_cs_n': 'AC12 SSTL15',
  'sdram_odt': 'AD8 SSTL15',
};

const _coreClock = HarborClockConfig(
  name: 'core',
  rate: HarborFixedClockRate(50000000),
  sourceFrequency: 200000000,
  source: HarborClockSource.ddr3Core,
  isPrimary: true,
);

/// The bus runs on its own MMCM beside the DDR3 clock tree.
const _busClock = HarborClockConfig(
  name: 'bus',
  rate: HarborFixedClockRate(83333333),
  sourceFrequency: 200000000,
  tolerancePpm: 100,
);

Future<Directory> _generate({
  required bool useHimbaechel,
  required bool ddr,
  bool netDomain = false,
  Map<String, String> extraConstraints = const {},
}) async {
  final target = HarborBoard.get('kc705').fpgaTarget(
    pins: ddr ? null : ['clk', 'clk_n', 'uart_tx', 'uart_rx'],
    useHimbaechel: useHimbaechel,
    extraPins: ddr ? _ddrExtra : const {},
    extraConstraints: extraConstraints,
  );
  final soc = HarborSoC(
    name: 'SplitBus',
    compatible: 'test,split-bus',
    target: target,
    fabricKind: HarborFabricKind.axi4,
    fabricClockDomain: 'bus',
    clocks: const [_coreClock, _busClock],
    xilinxDdr3Tree: const XilinxDdr3TreeSpec.kc705(coreClkHz: 50000000),
  );
  if (netDomain) {
    final buf = soc.addSubModule(XilinxBufg(name: 'ext_bufg'));
    buf.input('I').srcConnection! <= soc.boardClk;
    soc.addClockDomainFromNet(
      HarborClockConfig.fixed(
        name: 'ext',
        frequency: 200000000,
        sourceFrequency: 200000000,
      ),
      buf.output('O').named('ext_clk'),
    );
  }
  if (ddr) {
    final tree = soc.xilinxDdr3Clocks!;
    final shape = soc.memoryBusShape();
    final ddr3 = soc.addPeripheral(
      HarborDdr3(
        config: ax7203,
        baseAddress: 0x80000000,
        clockHz: tree.controllerMhz.round() * 1000000,
        busAddressWidth: 32,
        busDataWidth: 32,
        protocol: HarborFabricKind.axi4,
        idWidth: shape.idWidth,
        exclusive: shape.exclusive,
        target: target,
        ckPeriodPs: (1000000 / tree.ddrCkMhz).round(),
      ),
    );
    ddr3.input('ddr_ck_fast').srcConnection! <= tree.ddrCk;
    ddr3.input('ddr_ck90_fast').srcConnection! <= tree.ddrCk90;
    ddr3.input('ddr_ck_dqs_fast').srcConnection! <= tree.ddrCkDqs;
    ddr3.input('ddr_idelay_ref').srcConnection! <= tree.idelayRef;
    for (final pad in _ddrPads) {
      soc.exposePin(ddr3, pad, externalName: pad);
    }
  }
  final uart = soc.addPeripheral(
    HarborUart(
      baseAddress: 0x10000000,
      busAddressWidth: 32,
      busDataWidth: 32,
      regShift: 2,
      fabricKind: HarborFabricKind.axi4,
    ),
  );
  soc.exposePin(uart, 'tx', externalName: 'uart_tx');
  soc.exposePin(uart, 'rx', externalName: 'uart_rx');
  final dir = Directory.systemTemp.createTempSync('harbor_split_bus_');
  await soc.generateAll(dir);
  return dir;
}

String _read(Directory dir, String file) =>
    File('${dir.path}/$file').readAsStringSync();

void main() {
  tearDown(() async => Simulator.reset());

  for (final ddr in [false, true]) {
    test('himbaechel times the bus MMCM clock in the XDC, ddr=$ddr', () async {
      final dir = await _generate(useHimbaechel: true, ddr: ddr);
      addTearDown(() => dir.deleteSync(recursive: true));
      final xdc = _read(dir, 'SplitBus.xdc');
      final py = ddr ? _read(dir, 'support/nextpnr/clocks.py') : '';
      expect(xdc, isNot(contains('dst_clk')));
      expect(
        _read(dir, 'rtl/SplitBus.sv'),
        contains('(* keep = 1 *) logic bus_clk;'),
      );
      // One constraint for the net, from clocks.py when it is written.
      final inXdc = RegExp(r'create_clock .*\[get_nets bus_clk\]');
      final inPy = RegExp(r"\('bus_clk', [0-9.]+\)");
      expect(
        inXdc.allMatches(xdc).length + inPy.allMatches(py).length,
        1,
        reason: '$xdc\n$py',
      );
      if (ddr) {
        expect(py, contains("('bus_clk', 83.33)"));
      } else {
        expect(xdc, contains('create_clock -period 12.000 [get_nets bus_clk]'));
        expect(
          xdc,
          contains('create_clock -period 20.000 [get_nets core_clk]'),
        );
      }
    });
  }

  test('the legacy flow refuses a bus MMCM clock with no clock script', () {
    expect(
      _generate(useHimbaechel: false, ddr: false),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('bus_clk'),
        ),
      ),
    );
  });

  test('himbaechel refuses a net clock domain with no constraint', () {
    expect(
      _generate(useHimbaechel: true, ddr: false, netDomain: true),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('"ext"'), contains('ext_clk')),
        ),
      ),
    );
  });

  test('himbaechel takes a net clock domain the caller constrains', () async {
    final dir = await _generate(
      useHimbaechel: true,
      ddr: false,
      netDomain: true,
      extraConstraints: const {
        'ext_clk': 'create_clock -period 5.000 [get_nets ext_clk]',
      },
    );
    addTearDown(() => dir.deleteSync(recursive: true));
    expect(
      _read(dir, 'SplitBus.xdc'),
      contains('create_clock -period 5.000 [get_nets ext_clk]'),
    );
  });

  test('the XDC clock nets come from its create_clock lines', () {
    expect(
      harborXdcClockNets(
        'create_clock -period 5.000 [get_ports clk]\n'
        'set_property -dict {PACKAGE_PIN A1} [get_ports x]\n'
        'create_clock -name p -period 8.000 [get_nets a.b.pclk]\n',
      ),
      {'clk', 'a.b.pclk'},
    );
  });

  test('a clock net with no constraint stops the build', () {
    expect(
      () => harborCheckClockNets(
        {'core': 'core_clk', 'bus': 'dst_clk'},
        {'core_clk'},
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('"bus"'), contains('dst_clk')),
        ),
      ),
    );
    harborCheckClockNets({'bus': 'bus_clk'}, {'bus_clk'});
    harborCheckClockNets({'pipe': 'pclk'}, {'pcie.phy.pclk'});
  });
}
