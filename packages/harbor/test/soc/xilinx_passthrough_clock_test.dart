import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _sd = HarborClockConfig(
  name: 'sd',
  rate: HarborFixedClockRate(100000000),
  sourceFrequency: 100000000,
);

const _core = HarborClockConfig(
  name: 'sys',
  rate: HarborFixedClockRate(100000000),
  sourceFrequency: 100000000,
  source: HarborClockSource.ddr3Core,
);

Future<Directory> _generate({
  required List<HarborClockConfig> clocks,
  String fabric = 'sd',
  bool tree = false,
  bool himbaechel = true,
}) async {
  final board = HarborBoard.get('arty-s7-50');
  final soc = HarborSoC(
    name: 'PassSoc',
    compatible: 'test,pass-soc',
    target: board.fpgaTarget(
      pins: ['clk', 'uart_tx', 'uart_rx'],
      useHimbaechel: himbaechel,
    ),
    clocks: clocks,
    fabricClockDomain: fabric,
    xilinxDdr3Tree: tree
        ? const XilinxDdr3TreeSpec(
            sourceHz: 100000000,
            ddrCkHz: 400000000,
            coreClkHz: 100000000,
          )
        : null,
  );
  final uart = soc.addPeripheral(
    HarborUart(baseAddress: 0x10000000),
    clockDomainName: 'sd',
  );
  soc.exposePin(uart, 'tx', externalName: 'uart_tx');
  soc.exposePin(uart, 'rx', externalName: 'uart_rx');
  final dir = Directory.systemTemp.createTempSync('harbor_pass_clock_');
  await soc.generateAll(dir);
  return dir;
}

String _read(Directory dir, String file) =>
    File('${dir.path}/$file').readAsStringSync();

String _sv(Directory dir) => _read(dir, 'rtl/PassSoc.sv');

/// The BUFG instances whose input is the clock pin.
int _pinBufgs(String sv) =>
    RegExp(r'BUFG\s+\w+\(\.I\(clk\)').allMatches(sv).length;

/// Every instance port wired to the clock pin. Only the one BUFG may be.
List<String> _padLoads(String sv) => RegExp(
  r'^.*\.\w+\(clk\).*$',
  multiLine: true,
).allMatches(sv).map((m) => m.group(0)!).toList();

void _expectOnBuffer(String sv) {
  expect(_pinBufgs(sv), 1);
  expect(_padLoads(sv), hasLength(1), reason: _padLoads(sv).join('\n'));
  expect(sv, contains('(* keep = 1 *) logic sysosc_clk;'));
  expect(sv, contains('uart(.clk(sysosc_clk)'));
  expect(sv, contains('always_ff @(posedge sysosc_clk)'));
}

void main() {
  tearDown(() async => Simulator.reset());

  test('a same-rate domain runs on the shared BUFG and is timed', () async {
    final dir = await _generate(clocks: const [_sd]);
    addTearDown(() => dir.deleteSync(recursive: true));
    final sv = _sv(dir);
    _expectOnBuffer(sv);
    expect(sv, isNot(contains('.clk(clk)')));
    final xdc = _read(dir, 'PassSoc.xdc');
    expect(xdc, contains('create_clock -period 10.000 [get_nets sysosc_clk]'));
  });

  test('the legacy flow gets the buffered net in its clock script', () async {
    final dir = await _generate(clocks: const [_sd], himbaechel: false);
    addTearDown(() => dir.deleteSync(recursive: true));
    _expectOnBuffer(_sv(dir));
    expect(
      _read(dir, 'support/nextpnr/pll_clocks.py'),
      contains("('sysosc_clk', 100.00)"),
    );
  });

  test('a primary domain runs on the shared BUFG', () async {
    final dir = await _generate(
      clocks: const [
        HarborClockConfig(
          name: 'sd',
          rate: HarborFixedClockRate(100000000),
          sourceFrequency: 100000000,
          isPrimary: true,
        ),
      ],
    );
    addTearDown(() => dir.deleteSync(recursive: true));
    _expectOnBuffer(_sv(dir));
    expect(
      _read(dir, 'PassSoc.xdc'),
      contains('create_clock -period 10.000 [get_nets sysosc_clk]'),
    );
  });

  test('a PLL domain and a same-rate domain share one BUFG', () async {
    final dir = await _generate(
      clocks: const [
        _sd,
        HarborClockConfig(
          name: 'pix',
          rate: HarborFixedClockRate(50000000),
          sourceFrequency: 100000000,
        ),
      ],
    );
    addTearDown(() => dir.deleteSync(recursive: true));
    final sv = _sv(dir);
    _expectOnBuffer(sv);
    expect(sv, contains('.CLKIN1(sysosc_clk)'));
    expect(sv, isNot(contains('.CLKIN1(clk)')));
  });

  test('two same-rate domains are one clock', () async {
    final board = HarborBoard.get('arty-s7-50');
    final soc = HarborSoC(
      name: 'PassTwo',
      compatible: 'test,pass-two',
      target: board.fpgaTarget(pins: ['clk']),
      clocks: const [
        _sd,
        HarborClockConfig(
          name: 'sd2',
          rate: HarborFixedClockRate(100000000),
          sourceFrequency: 100000000,
        ),
      ],
      fabricClockDomain: 'sd',
    );
    final a = soc.clockDomain('sd')!;
    final b = soc.clockDomain('sd2')!;
    expect(identical(a.clk, b.clk), isTrue);
    expect(identical(a.clk, soc.sharedOscillatorClock), isTrue);
    // A peripheral on the second domain needs no crossing to the first.
    final uart = soc.addPeripheral(
      HarborUart(baseAddress: 0x10000000),
      clockDomainName: 'sd2',
    );
    soc.exposePin(uart, 'tx', externalName: 'uart_tx');
    expect(soc.validate(), isEmpty);
    soc.buildFabric();
    await soc.build();
  });

  group('with the DDR3 clock tree', () {
    const clocks = [_core, _sd];

    for (final himb in [true, false]) {
      test('the tree BUFG is reused, himb=$himb', () async {
        final dir = await _generate(
          clocks: clocks,
          tree: true,
          himbaechel: himb,
        );
        addTearDown(() => dir.deleteSync(recursive: true));
        final sv = _sv(dir);
        _expectOnBuffer(sv);
        expect(sv, contains('(* keep = 1 *) logic core_clk;'));
        if (himb) {
          expect(
            _read(dir, 'PassSoc.xdc'),
            contains('create_clock -period 10.000 [get_nets sysosc_clk]'),
          );
        }
      });
    }
  });

  test('a design with no same-rate domain has no input BUFG', () async {
    final dir = await _generate(
      clocks: const [
        HarborClockConfig(
          name: 'sd',
          rate: HarborFixedClockRate(50000000),
          sourceFrequency: 100000000,
        ),
      ],
    );
    addTearDown(() => dir.deleteSync(recursive: true));
    final sv = _sv(dir);
    expect(sv, isNot(contains('sysosc')));
    expect(sv, contains('.CLKIN1(clk)'));
  });

  test('a late same-rate domain after a pad PLL is refused', () {
    final soc = HarborSoC(
      name: 'PassLate',
      compatible: 'test,pass-late',
      target: HarborBoard.get('arty-s7-50').fpgaTarget(pins: ['clk']),
      clocks: const [
        HarborClockConfig(
          name: 'pix',
          rate: HarborFixedClockRate(50000000),
          sourceFrequency: 100000000,
        ),
      ],
    );
    expect(
      () => soc.addClockDomain(_sd),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('"sd"'), contains('constructor')),
        ),
      ),
    );
  });

  test('a late same-rate domain with no PLL gets the BUFG', () async {
    final soc = HarborSoC(
      name: 'PassLate2',
      compatible: 'test,pass-late2',
      target: HarborBoard.get('arty-s7-50').fpgaTarget(pins: ['clk']),
      clocks: const [],
    );
    final d = soc.addClockDomain(_sd);
    expect(identical(d.clk, soc.sharedOscillatorClock), isTrue);
  });

  test('a rate that differs from the target clock is refused', () {
    expect(
      () => HarborSoC(
        name: 'PassRate',
        compatible: 'test,pass-rate',
        target: HarborBoard.get('arty-s7-50').fpgaTarget(pins: ['clk']),
        clocks: const [
          HarborClockConfig(
            name: 'sd',
            rate: HarborFixedClockRate(50000000),
            sourceFrequency: 50000000,
          ),
        ],
      ),
      throwsStateError,
    );
  });

  test('a Vivado target buffers the clock and keeps the port clock', () async {
    final soc = HarborSoC(
      name: 'PassSoc',
      compatible: 'test,pass-vivado',
      target: const HarborFpgaTarget.artix7(
        device: 'xc7a35t',
        package: 'cpg236',
        frequency: 100000000,
        pinMap: {'clk': 'E3 LVCMOS33'},
      ),
      clocks: const [_sd],
      fabricClockDomain: 'sd',
    );
    soc.addPeripheral(HarborUart(baseAddress: 0x10000000));
    final dir = Directory.systemTemp.createTempSync('harbor_pass_vivado_');
    addTearDown(() => dir.deleteSync(recursive: true));
    await soc.generateAll(dir);
    final sv = _sv(dir);
    expect(_pinBufgs(sv), 1);
    expect(_padLoads(sv), hasLength(1));
    expect(sv, contains('uart(.clk(sysosc_clk)'));
    final xdc = _read(dir, 'PassSoc.xdc');
    expect(xdc, contains('create_clock -period 10.000 [get_ports clk]'));
  });

  test('the ADV7511 clocks share the buffer of a same-rate domain', () async {
    final soc = HarborSoC(
      name: 'PassSoc',
      compatible: 'test,pass-adv',
      target: HarborBoard.get('arty-s7-50').fpgaTarget(pins: ['clk']),
      clocks: const [_sd],
      fabricClockDomain: 'sd',
    );
    expect(soc.sharedOscillatorClock, isNotNull);
    soc.addSubModule(
      HarborAdv7511Clocks(
        source: soc.sharedOscillatorClock ?? soc.boardClk,
        sourceBuffered: soc.sharedOscillatorClock != null,
        reset: soc.clockDomain('sd')!.reset,
        sourceHz: 100000000,
        clk2xHz: 50000000,
      ),
    );
    final dir = Directory.systemTemp.createTempSync('harbor_pass_adv_');
    addTearDown(() => dir.deleteSync(recursive: true));
    await soc.generateAll(dir);
    final sv = _sv(dir);
    expect(_pinBufgs(sv), 1);
    expect(_padLoads(sv), hasLength(1));
    final all = Directory(
      '${dir.path}/rtl',
    ).listSync().whereType<File>().map((f) => f.readAsStringSync()).join('\n');
    expect(RegExp(r'BUFG\s+source_bufg').hasMatch(all), isFalse);
  });

  test('a CLKOS secondary domain does not take the input buffer', () {
    final soc = HarborSoC(
      name: 'PassSec',
      compatible: 'test,pass-sec',
      target: HarborBoard.get('arty-s7-50').fpgaTarget(pins: ['clk']),
      clocks: const [],
    );
    expect(soc.sharedOscillatorClock, isNull);
    final d = soc.addClockDomain(
      const HarborClockConfig(
        name: 'a',
        rate: HarborFixedClockRate(100000000),
        sourceFrequency: 100000000,
        isPrimary: true,
        coClkosSecondary: (name: 'b', frequency: 50000000, tolerancePpm: 0),
      ),
    );
    expect(d.clk, isNot(same(soc.boardClk)));
    expect(soc.sharedOscillatorClock, isNull);
  });

  test('an ECP5 primary domain gets the LPF frequency line', () async {
    final board = HarborBoard.get('orangecrab-25f');
    final target = board.fpgaTarget(pins: ['clk', 'uart_tx', 'uart_rx']);
    final soc = HarborSoC(
      name: 'EcpPrimary',
      compatible: 'test,ecp-primary',
      target: target,
      clocks: [
        HarborClockConfig(
          name: 'usb',
          rate: HarborFixedClockRate(board.oscillatorHz),
          sourceFrequency: board.oscillatorHz,
          isPrimary: true,
        ),
      ],
    );
    final uart = soc.addPeripheral(HarborUart(baseAddress: 0x10000000));
    soc.exposePin(uart, 'tx', externalName: 'uart_tx');
    soc.exposePin(uart, 'rx', externalName: 'uart_rx');
    final dir = Directory.systemTemp.createTempSync('harbor_ecp_primary_');
    addTearDown(() => dir.deleteSync(recursive: true));
    await soc.generateAll(dir);
    expect(
      _read(dir, 'EcpPrimary.lpf'),
      contains('FREQUENCY PORT "clk" 48.0 MHz;'),
    );
    expect(_read(dir, 'rtl/EcpPrimary.sv'), isNot(contains('BUFG')));
  });
}
