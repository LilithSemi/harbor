import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

/// Throwaway peripheral that contributes one nextpnr pre-place fragment.
///
/// It exists to exercise [HarborNextpnrPreplaceProvider] without tying these
/// tests to a real peripheral's placement rules. [fragment] is what it returns,
/// and [seenContexts] records every context it was asked with, so a test can
/// check what the target handed down.
class _PreplaceMock extends BridgeModule
    with HarborDeviceTreeNodeProvider, HarborNextpnrPreplaceProvider {
  /// Text this mock returns, or null to decline.
  final String? fragment;

  /// Base address of the mock's register block.
  final int baseAddress;

  /// Every context this mock was asked with, in call order.
  final List<HarborNextpnrPreplaceContext> seenContexts = [];

  _PreplaceMock({
    required this.fragment,
    required this.baseAddress,
    required String name,
  }) : super('PreplaceMock', name: name) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['test,preplace-mock'],
    reg: BusAddressRange(baseAddress, 0x1000),
  );

  @override
  String? nextpnrPreplacePy(HarborNextpnrPreplaceContext ctx) {
    seenContexts.add(ctx);
    return fragment;
  }
}

const _ice40 = HarborFpgaTarget.ice40(
  device: 'up5k',
  package: 'sg48',
  frequency: 48000000,
  pinMap: {'clk': '35'},
);

const _ecp5 = HarborFpgaTarget.ecp5(
  device: 'lfe5u-45f',
  package: 'CABGA381',
  frequency: 50000000,
  pinMap: {'clk': 'A10'},
);

const _openXc7 = HarborFpgaTarget.spartan7(
  device: 'xc7s50',
  package: 'csga324',
  frequency: 100000000,
  pinMap: {'clk': 'F14'},
  useOpenXc7: true,
);

HarborSoC _soc({
  HarborDeviceTarget? target,
  List<BridgeModule> extra = const [],
}) {
  final soc = HarborSoC(
    name: 'PreplaceSoC',
    compatible: 'test,preplace-soc',
    busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
    target: target,
  );
  soc.addPeripheral(HarborUart(baseAddress: 0x10000000));
  for (final p in extra) {
    soc.addPeripheral(p);
  }
  return soc;
}

Future<Directory> _generate(HarborSoC soc) async {
  final dir = Directory.systemTemp.createTempSync('harbor_preplace_');
  addTearDown(() => dir.deleteSync(recursive: true));
  await soc.generateAll(dir);
  return dir;
}

void main() {
  group('generateMakefile pre-place hook', () {
    test('ice40 defines PREPLACE from constraints.py', () {
      final mk = _ice40.generateMakefile('TopCell');
      expect(
        mk,
        contains(
          'PREPLACE := \$(if \$(wildcard support/nextpnr/constraints.py),'
          '--pre-place support/nextpnr/constraints.py,)',
        ),
      );
    });

    test('ice40 passes PREPLACE to nextpnr-ice40', () {
      final mk = _ice40.generateMakefile('TopCell');
      final recipe = mk
          .split('\n')
          .firstWhere((l) => l.contains('nextpnr-ice40'));
      expect(recipe, contains('\$(PREPLACE)'));
      expect(recipe, contains('\$(PREROUTE)'));
    });

    test('ecp5 defines PREPLACE from constraints.py', () {
      final mk = _ecp5.generateMakefile('TopCell');
      expect(
        mk,
        contains(
          'PREPLACE := \$(if \$(wildcard support/nextpnr/constraints.py),'
          '--pre-place support/nextpnr/constraints.py,)',
        ),
      );
    });

    test('ecp5 passes PREPLACE to nextpnr-ecp5', () {
      final mk = _ecp5.generateMakefile('TopCell');
      final recipe = mk
          .split('\n')
          .firstWhere((l) => l.contains('nextpnr-ecp5'));
      expect(recipe, contains('\$(PREPLACE)'));
      expect(recipe, contains('\$(PREROUTE)'));
    });

    test('show_bels.py guard is independent of constraints.py', () {
      for (final mk in [
        _ice40.generateMakefile('TopCell'),
        _ecp5.generateMakefile('TopCell'),
        _openXc7.generateMakefile('TopCell'),
      ]) {
        // The pre-place test names ONLY constraints.py, and the pre-route test
        // names ONLY show_bels.py. A design that has one file but not the other
        // must not make nextpnr point at the missing one.
        expect(
          mk,
          contains(
            'PREPLACE := \$(if \$(wildcard support/nextpnr/constraints.py),'
            '--pre-place support/nextpnr/constraints.py,)',
          ),
        );
        expect(
          mk,
          contains(
            'PREROUTE := \$(if \$(wildcard support/nextpnr/show_bels.py),'
            '--pre-route support/nextpnr/show_bels.py,)',
          ),
        );
        final preplaceLine = mk
            .split('\n')
            .firstWhere((l) => l.startsWith('PREPLACE :='));
        expect(preplaceLine, isNot(contains('show_bels.py')));
        final preRouteLine = mk
            .split('\n')
            .firstWhere((l) => l.startsWith('PREROUTE :='));
        expect(preRouteLine, isNot(contains('constraints.py')));
      }
    });

    test('openXc7 pnr recipe is otherwise unchanged', () {
      final mk = _openXc7.generateMakefile('TopCell');
      // Everything the working DDR3 flow depends on, pinned so the pre-place
      // rework cannot move it.
      expect(
        mk,
        contains(
          'CHIPDB ?= \$(NEXTPNR_XILINX_CHIPDB)/\$(DEVICE)\$(PACKAGE).bin',
        ),
      );
      expect(mk, contains('XRAY_DB ?= \$(PRJXRAY_DB)'));
      expect(mk, contains('PART ?= \$(DEVICE)\$(PACKAGE)-1'));
      expect(mk, contains('SEED ?= 1'));
      expect(mk, contains('THREADS ?= \$(shell nproc)'));
      expect(mk, contains('PLACER ?= heap'));
      expect(
        mk,
        contains(
          'PREPACK := \$(if \$(wildcard support/nextpnr/clocks.py),'
          '--pre-pack support/nextpnr/clocks.py --timing-allow-fail,)',
        ),
      );
      expect(
        mk,
        contains(
          '\tOMP_NUM_THREADS=\$(THREADS) nextpnr-xilinx --chipdb \$(CHIPDB) '
          '--xdc \$(TOP).xdc '
          '--json \$(TOP).json --write \$(TOP)_routed.json --fasm \$(TOP).fasm '
          '\$(PREPACK) \$(PREPLACE) \$(PREROUTE) --placer \$(PLACER) '
          '--seed \$(SEED)',
        ),
      );
      expect(
        mk,
        contains(
          'fasm2frames --db-root \$(XRAY_DB)/\$(FAMILY) --part \$(PART) ',
        ),
      );
      expect(mk, contains('xc7frames2bit --part_file '));
    });
  });

  group('generateAll pre-place collection', () {
    test('no contributor writes no constraints.py', () async {
      final dir = await _generate(_soc(target: _ecp5));
      expect(
        File('${dir.path}/support/nextpnr/constraints.py').existsSync(),
        isFalse,
      );
      expect(Directory('${dir.path}/support/nextpnr').existsSync(), isFalse);
    });

    test('one contributor writes its fragment verbatim', () async {
      final mock = _PreplaceMock(
        fragment: "print('MOCK A')\n",
        baseAddress: 0x40000000,
        name: 'mock_a',
      );
      final dir = await _generate(_soc(target: _ecp5, extra: [mock]));
      final py = File('${dir.path}/support/nextpnr/constraints.py');
      expect(py.existsSync(), isTrue);
      expect(py.readAsStringSync(), equals("print('MOCK A')\n"));
    });

    test('the context carries the part down', () async {
      final mock = _PreplaceMock(
        fragment: "print('MOCK A')\n",
        baseAddress: 0x40000000,
        name: 'mock_a',
      );
      await _generate(_soc(target: _ecp5, extra: [mock]));
      expect(mock.seenContexts, hasLength(1));
      expect(mock.seenContexts.single.vendor, equals(HarborFpgaVendor.ecp5));
      expect(mock.seenContexts.single.device, equals('lfe5u-45f'));
      expect(mock.seenContexts.single.package, equals('CABGA381'));
    });

    test('two contributors are joined, not clobbered', () async {
      final a = _PreplaceMock(
        fragment: "print('MOCK A')\n",
        baseAddress: 0x40000000,
        name: 'mock_a',
      );
      final b = _PreplaceMock(
        fragment: "print('MOCK B')\n",
        baseAddress: 0x40001000,
        name: 'mock_b',
      );
      final dir = await _generate(_soc(target: _ice40, extra: [a, b]));
      final py = File(
        '${dir.path}/support/nextpnr/constraints.py',
      ).readAsStringSync();
      expect(py, contains("print('MOCK A')"));
      expect(py, contains("print('MOCK B')"));
      expect(py.indexOf('MOCK A'), lessThan(py.indexOf('MOCK B')));
    });

    test('a null fragment contributes nothing', () async {
      final declines = _PreplaceMock(
        fragment: null,
        baseAddress: 0x40000000,
        name: 'mock_null',
      );
      final dir = await _generate(_soc(target: _ice40, extra: [declines]));
      expect(declines.seenContexts, hasLength(1));
      expect(
        File('${dir.path}/support/nextpnr/constraints.py').existsSync(),
        isFalse,
      );
    });
  });
}
