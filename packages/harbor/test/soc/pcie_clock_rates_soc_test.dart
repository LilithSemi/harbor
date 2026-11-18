import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
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

HarborPcieEndpoint _endpoint(HarborFpgaTarget target) => HarborPcieEndpoint(
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
);

/// A peripheral that states the clocks of a PCIe endpoint inside it.
class _PcieHost extends HarborUart with HarborClockRateProvider {
  final HarborPcieEndpoint endpoint;

  _PcieHost(this.endpoint) : super(baseAddress: 0x10000000);

  @override
  Map<String, double> clockRates(String instance) =>
      endpoint.clockRates('$instance.pcie_endpoint');
}

Future<(Directory, String)> _generate({
  required String board,
  required HarborFpgaTarget endpointTarget,
  required bool himbaechel,
  bool withPcie = true,
}) async {
  final b = HarborBoard.get(board);
  final target = b.fpgaTarget(
    pins: ['clk', 'clk_n', 'uart_tx', 'uart_rx'],
    useHimbaechel: himbaechel,
  );
  final soc = HarborSoC(
    name: 'RateSoc',
    compatible: 'test,rate-soc',
    target: target,
    clocks: const [
      HarborClockConfig(
        name: 'sys',
        rate: HarborFixedClockRate(100000000),
        sourceFrequency: 200000000,
      ),
    ],
  );
  final uart = soc.addPeripheral(
    withPcie
        ? _PcieHost(_endpoint(endpointTarget))
        : HarborUart(baseAddress: 0x10000000),
  );
  soc.exposePin(uart, 'tx', externalName: 'uart_tx');
  soc.exposePin(uart, 'rx', externalName: 'uart_rx');
  final dir = Directory.systemTemp.createTempSync('harbor_pcie_rates_');
  await soc.generateAll(dir);
  return (dir, uart.name);
}

/// A module that builds the endpoint inside it. It is not a bus peripheral.
class _EndpointHost extends BridgeModule {
  _EndpointHost(HarborFpgaTarget target, List<Logic> ins)
    : super('EndpointHost') {
    final ep = HarborPcieEndpoint(
      target: target,
      refClkP: addInput('ref_p', ins[0]),
      refClkN: addInput('ref_n', ins[1]),
      perstN: addInput('perst_n', ins[2]),
      rxP: addInput('rx_p', ins[3]),
      rxN: addInput('rx_n', ins[4]),
      rxReady: Const(1),
      txData: Const(0, width: 64),
      txKeep: Const(0, width: 8),
      txLast: Const(0),
      txValid: Const(0),
    );
    addOutput('tx_p') <= ep.txP;
    addOutput('tx_n') <= ep.txN;
  }
}

/// A SoC that has the endpoint inside a submodule, with no bus peripheral
/// for it.
Future<Directory> _generateDirect({
  required String board,
  required HarborFpgaTarget endpointTarget,
  required bool himbaechel,
  XilinxDdr3TreeSpec? tree,
}) async {
  final b = HarborBoard.get(board);
  const hostPorts = [
    'host_ref_p',
    'host_ref_n',
    'host_perst_n',
    'host_rx_p',
    'host_rx_n',
  ];
  final target = b.fpgaTarget(
    pins: ['clk', 'clk_n', 'uart_tx', 'uart_rx'],
    extraPins: {
      for (final (i, n) in hostPorts.indexed)
        n: 'A${i + 1} LVCMOS25 PULLTYPE=PULLUP',
    },
    useHimbaechel: himbaechel,
  );
  final soc = HarborSoC(
    name: 'RateSoc',
    compatible: 'test,rate-soc',
    target: target,
    clocks: [
      HarborClockConfig(
        name: 'sys',
        rate: const HarborFixedClockRate(100000000),
        sourceFrequency: 200000000,
        providedByDdr3Tree: tree != null,
      ),
      if (tree != null)
        const HarborClockConfig(
          name: 'aux',
          rate: HarborFixedClockRate(50000000),
          sourceFrequency: 200000000,
        ),
    ],
    xilinxDdr3Tree: tree,
  );
  soc.addSubModule(
    _EndpointHost(endpointTarget, [
      for (final n in hostPorts) soc.addInput(n, Logic()),
    ]),
  );
  final uart = soc.addPeripheral(HarborUart(baseAddress: 0x10000000));
  soc.exposePin(uart, 'tx', externalName: 'uart_tx');
  soc.exposePin(uart, 'rx', externalName: 'uart_rx');
  final dir = Directory.systemTemp.createTempSync('harbor_pcie_direct_');
  await soc.generateAll(dir);
  return dir;
}

String _read(Directory dir, String file) =>
    File('${dir.path}/$file').readAsStringSync();

void main() {
  tearDown(() async => Simulator.reset());

  group('endpoint clock rates', () {
    /// Follows [path] from [m] and returns the signal at its end, or null.
    Logic? find(Module m, List<String> path) {
      if (path.length == 1) {
        return m.signals.where((s) => s.name == path.single).firstOrNull;
      }
      final next = m.subModules.where((s) => s.name == path.first).firstOrNull;
      return next == null ? null : find(next, path.sublist(1));
    }

    for (final (label, target, gtx) in [
      ('GTX', _kintex, true),
      ('GTP', _artix, false),
    ]) {
      test('$label nets are in the module tree', () async {
        final dut = _endpoint(target);
        await dut.build();
        final rates = dut.clockRates('pcie_endpoint');
        for (final net in rates.keys) {
          final path = net.split('.').skip(1).toList();
          expect(find(dut, path), isNotNull, reason: net);
        }
        const pipe = 'pcie_endpoint.pcie_phy';
        final phy = gtx ? 'gtx_pcie_phy' : 'gtp_pcie_phy';
        expect(rates, {
          '$pipe.$phy.pipe_clock.txoutclk_buf': 100,
          '$pipe.$phy.pipe_clock.pclk': gtx ? 250 : 125,
          '$pipe.$phy.pipe_clock.userclk1': gtx ? 125 : 62.5,
          if (gtx) '$pipe.$phy.pipe_clock.oob_clk': 62.5,
        });
      });
    }

    test('gen1 on Kintex-7 has a 125 MHz pclk', () async {
      final dut = HarborPcieEndpoint(
        target: _kintex,
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
        gen2: false,
      );
      expect(
        dut.clockRates('e').entries.firstWhere((e) => e.key.endsWith('.pclk')),
        isA<MapEntry<String, double>>().having((e) => e.value, 'MHz', 125),
      );
    });
  });

  group('SoC', () {
    test('a KC705 SoC gives the four rates to the nextpnr script', () async {
      final (dir, host) = await _generate(
        board: 'kc705',
        endpointTarget: _kintex,
        himbaechel: false,
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final py = _read(dir, 'support/nextpnr/pll_clocks.py');
      const p = 'pcie_endpoint.pcie_phy.gtx_pcie_phy.pipe_clock';
      expect(py, contains("('$host.$p.txoutclk_buf', 100.00)"));
      expect(py, contains("('$host.$p.pclk', 250.00)"));
      expect(py, contains("('$host.$p.userclk1', 125.00)"));
      expect(py, contains("('$host.$p.oob_clk', 62.50)"));
      expect(py, contains("('sys_clk', 100.00)"));
      expect(_read(dir, 'Makefile'), contains('pll_clocks.py'));
    });

    test('a KC705 SoC with Himbächel gives them to the XDC', () async {
      final (dir, host) = await _generate(
        board: 'kc705',
        endpointTarget: _kintex,
        himbaechel: true,
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final xdc = _read(dir, 'RateSoc.xdc');
      const p = 'pcie_endpoint.pcie_phy.gtx_pcie_phy.pipe_clock';
      expect(
        xdc,
        contains('create_clock -period 4.000 [get_nets $host.$p.pclk]'),
      );
      expect(
        xdc,
        contains('create_clock -period 8.000 [get_nets $host.$p.userclk1]'),
      );
      expect(
        xdc,
        contains('create_clock -period 16.000 [get_nets $host.$p.oob_clk]'),
      );
      expect(
        xdc,
        contains(
          'create_clock -period 10.000 [get_nets $host.$p.txoutclk_buf]',
        ),
      );
    });

    test('an AX7203 SoC gives the GTP rates', () async {
      final (dir, host) = await _generate(
        board: 'ax7203',
        endpointTarget: _artix,
        himbaechel: false,
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final py = _read(dir, 'support/nextpnr/pll_clocks.py');
      const p = 'pcie_endpoint.pcie_phy.gtp_pcie_phy.pipe_clock';
      expect(py, contains("('$host.$p.txoutclk_buf', 100.00)"));
      expect(py, contains("('$host.$p.pclk', 125.00)"));
      expect(py, contains("('$host.$p.userclk1', 62.50)"));
      expect(py, isNot(contains('oob_clk')));
    });

    for (final (label, board, target, phy, gtx) in [
      ('GTX', 'kc705', _kintex, 'gtx', true),
      ('GTP', 'ax7203', _artix, 'gtp', false),
    ]) {
      test(
        'a direct $label endpoint gives its rates, script and XDC',
        () async {
          final script = await _generateDirect(
            board: board,
            endpointTarget: target,
            himbaechel: false,
          );
          addTearDown(() => script.deleteSync(recursive: true));
          final xdcDir = await _generateDirect(
            board: board,
            endpointTarget: target,
            himbaechel: true,
          );
          addTearDown(() => xdcDir.deleteSync(recursive: true));
          final p =
              'EndpointHost.pcie_endpoint.pcie_phy.${phy}_pcie_phy.pipe_clock';
          final py = _read(script, 'support/nextpnr/pll_clocks.py');
          final xdc = _read(xdcDir, 'RateSoc.xdc');
          for (final (net, mhz) in [
            ('txoutclk_buf', 100.0),
            ('pclk', gtx ? 250.0 : 125.0),
            ('userclk1', gtx ? 125.0 : 62.5),
            if (gtx) ('oob_clk', 62.5),
          ]) {
            expect(py, contains("('$p.$net', ${mhz.toStringAsFixed(2)})"));
            expect(
              xdc,
              contains(
                'create_clock -period ${(1000 / mhz).toStringAsFixed(3)} '
                '[get_nets $p.$net]',
              ),
            );
          }
          if (!gtx) expect(xdc, isNot(contains('oob_clk')));
        },
      );
    }

    test(
      'a KC705 SoC with a DDR3 clock tree and Himbächel has the rates',
      () async {
        final dir = await _generateDirect(
          board: 'kc705',
          endpointTarget: _kintex,
          himbaechel: true,
          tree: const XilinxDdr3TreeSpec(
            sourceHz: 200000000,
            ddrCkHz: 400000000,
            coreClkHz: 100000000,
          ),
        );
        addTearDown(() => dir.deleteSync(recursive: true));
        final xdc = _read(dir, 'RateSoc.xdc');
        const p = 'EndpointHost.pcie_endpoint.pcie_phy.gtx_pcie_phy.pipe_clock';
        for (final (net, ns) in [
          ('txoutclk_buf', '10.000'),
          ('pclk', '4.000'),
          ('userclk1', '8.000'),
          ('oob_clk', '16.000'),
        ]) {
          expect(xdc, contains('create_clock -period $ns [get_nets $p.$net]'));
        }
      },
    );

    test('the nextpnr script stops on a net that is not in the design', () {
      final py = _kintex.generatePllClockConstraintPy({'a.b': 100});
      expect(py, contains('def require_net(net):'));
      expect(py, contains('ctx.getNetByAlias(net)'));
      expect(
        py.indexOf('require_net(net)\n    ctx.addClock'),
        greaterThan(py.indexOf('for net, mhz in')),
      );
    });

    test('rates with a DDR3 tree and no clocks.py to carry them throw', () {
      expect(
        _generateDirect(
          board: 'kc705',
          endpointTarget: _kintex,
          himbaechel: false,
          tree: const XilinxDdr3TreeSpec(
            sourceHz: 200000000,
            ddrCkHz: 400000000,
            coreClkHz: 100000000,
          ),
        ),
        throwsStateError,
      );
    });

    test('a design without PCIe has no endpoint rates', () async {
      final (dir, _) = await _generate(
        board: 'kc705',
        endpointTarget: _kintex,
        himbaechel: false,
        withPcie: false,
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final py = _read(dir, 'support/nextpnr/pll_clocks.py');
      expect(py, isNot(contains('pipe_clock')));
      expect(py, contains("('sys_clk', 100.00)"));
    });

    test('a standalone top can write the script from the endpoint', () {
      final dut = _endpoint(_kintex);
      final py = _kintex.generatePllClockConstraintPy(
        dut.clockRates('pcie_endpoint'),
      );
      expect(
        py,
        contains(
          "('pcie_endpoint.pcie_phy.gtx_pcie_phy.pipe_clock.pclk', 250.00)",
        ),
      );
    });

    test('the DDR3 clock script takes the endpoint rates', () {
      final py = _kintex.generateClockConstraintPy(
        coreClkMhz: 100,
        coreClockNet: 'core_clk',
        sourceClockNet: 'sysosc_clk',
        sourceClkMhz: 200,
        ddrCtrlMhz: 75,
        extraClocks: const {'p.pipe_clock.pclk': 250},
      );
      expect(py, contains("('p.pipe_clock.pclk', 250.00)"));
      // The rates of the endpoint have no try and except, and the net must
      // exist.
      final extra = py.substring(py.indexOf('def require_net'));
      expect(extra, contains('raise Exception'));
      expect(extra, contains('require_net(net)'));
      expect(extra, isNot(contains('except Exception as e')));
      expect(py, contains("('ddr_clk',"));
    });
  });
}
