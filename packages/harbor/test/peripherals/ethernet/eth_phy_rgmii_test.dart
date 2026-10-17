import 'dart:async';
import 'dart:math';

import 'package:harbor/src/peripherals/ethernet/eth_byte_stream.dart';
import 'package:harbor/src/peripherals/ethernet/eth_config.dart';
import 'package:harbor/src/peripherals/ethernet/eth_mac_rx.dart';
import 'package:harbor/src/peripherals/ethernet/eth_mac_tx.dart';
import 'package:harbor/src/peripherals/ethernet/eth_phy_rgmii.dart';
import 'package:harbor/src/soc/target.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/eth_frames.dart';
import '../../util/eth_phy_model.dart';

const _artix = HarborFpgaTarget.artix7(
  device: 'xc7a200t',
  package: 'fbg484',
  speedGrade: '2',
);
const _ecp5 = HarborFpgaTarget.ecp5(device: 'lfe5u-45f', package: 'CABGA381');

class _Top extends Module {
  _Top(
    EthRgmiiModel m,
    HarborDeviceTarget target,
    HarborEthernetConfig config, {
    required Logic reset,
    required Logic speed,
    required Logic clk125,
    required Logic clk125_90,
    required Logic rxEn,
    required Logic inValid,
    required Logic inData,
    required Logic inLast,
    required Logic inErr,
  }) {
    reset = addInput('reset', reset);
    final stream = HarborEthByteStream();
    final phy = HarborEthPhyRgmii(
      stream,
      config: config,
      target: target,
      reset: reset,
      speed: addInput('speed', speed, width: 2),
      clk125: addInput('clk125', clk125),
      clk125_90: addInput('clk125_90', clk125_90),
      rgmiiRxc: addInput('rgmii_rxc', m.rxc),
      rgmiiRxd: addInput('rgmii_rxd', m.rxd, width: 4),
      rgmiiRxCtl: addInput('rgmii_rx_ctl', m.rxCtl),
    );
    final tx = HarborEthMacTx(
      stream.txClk,
      stream.txReset,
      config: config,
      txStrobe: stream.txStrobe,
      inValid: addInput('in_valid', inValid),
      inData: addInput('in_data', inData, width: 8),
      inLast: addInput('in_last', inLast),
      inErr: addInput('in_err', inErr),
    );
    stream.txData <= tx.txData;
    stream.txEn <= tx.txEn;
    stream.txEr <= tx.txEr;
    final rx = HarborEthMacRx(
      stream.rxClk,
      stream.rxReset,
      config: config,
      rxStrobe: stream.rxStrobe,
      rxData: stream.rxData,
      rxDv: stream.rxDv,
      rxEr: stream.rxEr,
      rxEn: addInput('rx_en', rxEn),
      macAddr: Const(0x554433221102, width: 48),
    );
    addOutput('in_ready') <= tx.inReady;
    addOutput('out_valid') <= rx.outValid;
    addOutput('out_data', width: 8) <= rx.outData;
    addOutput('out_last') <= rx.outLast;
    addOutput('out_status', width: 8) <= rx.outStatus;
    addOutput('rgmii_txc') <= phy.txc;
    addOutput('rgmii_txd', width: 4) <= phy.txd;
    addOutput('rgmii_tx_ctl') <= phy.txCtl;
  }
}

class _RxTop extends Module {
  _RxTop(Logic rxc, Logic rxd, Logic ctl, Logic clk, Logic reset) {
    final s = HarborEthByteStream();
    final c = addInput('clk', clk);
    HarborEthPhyRgmii(
      s,
      config: HarborEthernetConfig(
        phy: HarborEthPhy.rgmii,
        maxSpeed: HarborEthSpeed.mbps1000,
      ),
      target: _artix,
      reset: addInput('reset', reset),
      speed: Const(2, width: 2),
      clk125: c,
      clk125_90: c,
      rgmiiRxc: addInput('rxc', rxc),
      rgmiiRxd: addInput('rxd', rxd, width: 4),
      rgmiiRxCtl: addInput('ctl', ctl),
    );
    s.txData <= Const(0, width: 8);
    s.txEn <= Const(0);
    s.txEr <= Const(0);
    addOutput('dv') <= s.rxDv;
    addOutput('er') <= s.rxEr;
  }
}

class _Bench {
  final EthRgmiiModel model;
  final EthCoreProbe probe;
  final Logic clk125;
  final Logic speed;
  final Logic inErr;

  _Bench(this.model, this.probe, this.clk125, this.speed, this.inErr);

  static Future<_Bench> start({
    int mbps = 1000,
    HarborDeviceTarget target = _artix,
    bool shift = true,
  }) async {
    final model = EthRgmiiModel(mbps: mbps, txSampleDelay: shift ? 0 : 2);
    final config = HarborEthernetConfig(
      phy: HarborEthPhy.rgmii,
      maxSpeed: HarborEthSpeed.mbps1000,
      txClockShift: shift,
    );
    final clk125 = SimpleClockGenerator(8).clk;
    final clk90 = ethShiftedClock(clk125, 2, name: 'clk90');
    final reset = Logic();
    final speed = Logic(width: 2);
    final rxEn = Logic();
    final inValid = Logic();
    final inData = Logic(width: 8);
    final inLast = Logic();
    final inErr = Logic();
    final top = _Top(
      model,
      target,
      config,
      reset: reset,
      speed: speed,
      clk125: clk125,
      clk125_90: clk90,
      rxEn: rxEn,
      inValid: inValid,
      inData: inData,
      inLast: inLast,
      inErr: inErr,
    );
    await top.build();
    model.attach(
      top.output('rgmii_txc'),
      top.output('rgmii_txd'),
      top.output('rgmii_tx_ctl'),
    );
    final probe = EthCoreProbe(
      inValid: inValid,
      inData: inData,
      inLast: inLast,
      inErr: inErr,
      inReady: top.output('in_ready'),
      outValid: top.output('out_valid'),
      outData: top.output('out_data'),
      outLast: top.output('out_last'),
      outStatus: top.output('out_status'),
    );
    reset.inject(1);
    speed.inject(_speedCode(mbps));
    rxEn.inject(1);
    Simulator.setMaxSimTime(100000000);
    unawaited(Simulator.run());
    model.start();
    for (var i = 0; i < 4; i++) {
      await clk125.nextPosedge;
    }
    // At 10 Mbps the receive clock is slow. The receive reset needs edges
    // of it while the reset is high.
    for (var i = 0; i < 2; i++) {
      await model.rxc.nextPosedge;
    }
    reset.inject(0);
    for (var i = 0; i < 8; i++) {
      await model.rxc.nextPosedge;
    }
    probe.collect(model.rxc);
    return _Bench(model, probe, clk125, speed, inErr);
  }

  Future<void> finish() async {
    model.stop();
    probe.stop();
    await Simulator.endSimulation();
  }

  /// Gives [frames] to the TX core and waits for them on the RX side.
  Future<void> loop(List<List<int>> frames) async {
    final want = probe.rxFrames.length + frames.length;
    probe.feed(clk125, frames);
    await probe.waitFor(
      clk125,
      () => probe.rxFrames.length == want,
      frames.length * 160 * _byteClocks(model.mbps) + 4000,
    );
  }
}

int _speedCode(int mbps) => switch (mbps) {
  1000 => 2,
  100 => 1,
  _ => 0,
};

int _byteClocks(int mbps) => 1000 ~/ mbps;

List<int> _frame(Random rand, int len) => [
  ...List.filled(6, 0xFF),
  0x02,
  0x00,
  0x00,
  0x00,
  0x00,
  0x01,
  for (var i = 12; i < len; i++) rand.nextInt(256),
];

const _bcastEr = HarborEthMacRx.statusBcast | HarborEthMacRx.statusRxEr;

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  for (final mbps in [1000, 100, 10]) {
    group('HarborEthPhyRgmii $mbps Mbps', () {
      test('transmit frames are whole on the pins', () async {
        final b = await _Bench.start(mbps: mbps);
        final rand = Random(1);
        final frames = [_frame(rand, 60), _frame(rand, 77)];
        b.probe.feed(b.clk125, frames);
        await b.probe.waitFor(
          b.clk125,
          () => b.model.txFrames.length == frames.length,
          300 * _byteClocks(mbps) + 2000,
        );
        await b.finish();
        expect(b.model.txFrames, hasLength(frames.length));
        for (var i = 0; i < frames.length; i++) {
          final f = b.model.txFrames[i];
          expect(f.bytes, equals(ethWireFrame(frames[i])), reason: 'frame $i');
          expect(f.malformed, isFalse);
          expect(f.er, isFalse);
        }
      });

      test('the late MAC strobe takes each byte once, in order', () async {
        final b = await _Bench.start(mbps: mbps);
        // Counting bytes after the header show a repeated or a lost byte.
        final frames = [
          for (var f = 0; f < 3; f++)
            [
              ..._frame(Random(f), 14).sublist(0, 14),
              for (var i = 0; i < 200; i++) (i + 37 * f) & 0xFF,
            ],
        ];
        b.probe.feed(b.clk125, frames);
        await b.probe.waitFor(
          b.clk125,
          () => b.model.txFrames.length == frames.length,
          900 * _byteClocks(mbps) + 4000,
        );
        await b.finish();
        expect(b.model.txFrames, hasLength(frames.length));
        for (var i = 0; i < frames.length; i++) {
          expect(
            b.model.txFrames[i].bytes,
            equals(ethWireFrame(frames[i])),
            reason: 'frame $i',
          );
          expect(b.model.txFrames[i].malformed, isFalse);
        }
      });

      test('receive frames reach the core', () async {
        final b = await _Bench.start(mbps: mbps);
        final rand = Random(2);
        final frames = [_frame(rand, 60), _frame(rand, 90)];
        for (var i = 0; i < frames.length; i++) {
          await b.model.sendFrame(ethWireFrame(frames[i]), idleClocks: 1 + i);
        }
        await b.finish();
        expect(b.probe.rxFrames, equals(frames));
        expect(b.probe.rxStatus, everyElement(HarborEthMacRx.statusBcast));
      });

      test('loopback returns the frames', () async {
        final b = await _Bench.start(mbps: mbps);
        b.model.loopback = true;
        final rand = Random(3);
        final frames = [_frame(rand, 60), _frame(rand, 100)];
        await b.loop(frames);
        await b.finish();
        expect(b.probe.rxFrames, equals(frames));
        expect(b.probe.rxStatus, everyElement(HarborEthMacRx.statusBcast));
      });

      if (mbps == 10) return;

      test('tx_er goes on the falling edge of tx_ctl', () async {
        final b = await _Bench.start(mbps: mbps);
        final frame = _frame(Random(4), 60);
        b.inErr.inject(1);
        b.probe.feed(b.clk125, [frame]);
        await b.probe.waitFor(
          b.clk125,
          () => b.model.txFrames.isNotEmpty,
          100 * _byteClocks(mbps) + 2000,
        );
        await b.finish();
        final f = b.model.txFrames.single;
        final wire = ethWireFrame(frame);
        expect(f.malformed, isFalse);
        expect(f.er, isTrue);
        expect(f.erBytes, [wire.length - 1]);
        expect(
          f.bytes.sublist(0, wire.length - 4),
          wire.sublist(0, wire.length - 4),
        );
        final fcs = ethFcsBytes(frame);
        expect(f.bytes.sublist(wire.length - 4), [
          for (final x in fcs) x ^ 0xFF,
        ]);
      });

      test('rx_er on the falling edge of rx_ctl reaches the status', () async {
        final b = await _Bench.start(mbps: mbps);
        final frame = _frame(Random(5), 70);
        await b.model.sendFrame(ethWireFrame(frame), erAtByte: 30);
        await b.finish();
        expect(b.probe.rxFrames, equals([frame]));
        expect(b.probe.rxStatus, [_bcastEr]);
      });
    });
  }

  group('HarborEthPhyRgmii 100 Mbps preamble', () {
    test('preamble short by 1 nibble', () async {
      final b = await _Bench.start(mbps: 100);
      final frames = [_frame(Random(7), 64), _frame(Random(8), 64)];
      await b.model.sendFrame(ethWireFrame(frames[0]), skipNibbles: 1);
      await b.model.sendFrame(ethWireFrame(frames[1]), skipNibbles: 2);
      await b.finish();
      expect(b.probe.rxFrames, equals(frames));
    });
  });

  group('HarborEthPhyRgmii 1000 Mbps primitives', () {
    for (final (name, target) in [
      ('ecp5', _ecp5 as HarborDeviceTarget),
      ('sim', const HarborSimTarget()),
    ]) {
      test('loopback on $name', () async {
        final b = await _Bench.start(target: target);
        b.model.loopback = true;
        final rand = Random(9);
        final frames = [_frame(rand, 60), _frame(rand, 80)];
        await b.loop(frames);
        await b.finish();
        expect(b.probe.rxFrames, equals(frames));
        expect(b.model.txFrames.map((f) => f.bytes), [
          for (final f in frames) ethWireFrame(f),
        ]);
      });
    }

    test('loopback on ecp5 at 100 Mbps', () async {
      final b = await _Bench.start(mbps: 100, target: _ecp5);
      b.model.loopback = true;
      final frames = [_frame(Random(12), 64)];
      await b.loop(frames);
      await b.finish();
      expect(b.probe.rxFrames, equals(frames));
    });

    test('loopback with the TX delay in the PHY', () async {
      final b = await _Bench.start(shift: false);
      b.model.loopback = true;
      final frames = [_frame(Random(10), 64)];
      await b.loop(frames);
      await b.finish();
      expect(b.probe.rxFrames, equals(frames));
    });
  });

  /// Records the high and low times of [txc], in order.
  List<(bool, int)> pulses(Logic txc) {
    final out = <(bool, int)>[];
    var last = -1;
    txc.changed.listen((e) {
      if (!e.newValue.isValid) return;
      if (last >= 0)
        out.add((e.previousValue == LogicValue.one, Simulator.time - last));
      last = Simulator.time;
    });
    return out;
  }

  test('a speed change while idle keeps a clean TX clock', () async {
    final b = await _Bench.start();
    b.model.loopback = true;
    final p = pulses(b.model.txc);
    final rand = Random(11);
    final frames = <List<int>>[];
    for (final mbps in [1000, 100, 10, 1000]) {
      b.speed.inject(_speedCode(mbps));
      b.model.mbps = mbps;
      for (var i = 0; i < 300; i++) {
        await b.clk125.nextPosedge;
      }
      final f = [_frame(rand, 64)];
      frames.addAll(f);
      await b.loop(f);
    }
    await b.finish();
    expect(b.probe.rxFrames, equals(frames));
    final highs = [
      for (final (h, w) in p)
        if (h) w,
    ];
    final runs = <int>[];
    for (final h in highs) {
      if (runs.isEmpty || runs.last != h) runs.add(h);
    }
    expect(runs, [4, 20, 200, 4]);
    // Between two highs of one speed, the low has the same length, so the
    // duty cycle is 50 percent.
    for (var i = 1; i + 1 < p.length; i++) {
      final (h, w) = p[i];
      if (h || p[i - 1].$2 != p[i + 1].$2) continue;
      expect(w, p[i - 1].$2, reason: 'low $i');
    }
    expect(p.where((e) => !e.$1 && e.$2 == 200).length, greaterThan(100));
  });

  test('a one clock glitch on speed does not change the TX clock', () async {
    final b = await _Bench.start();
    final p = pulses(b.model.txc);
    for (var i = 0; i < 20; i++) {
      await b.clk125.nextPosedge;
    }
    await b.clk125.nextNegedge;
    b.speed.put(1);
    await b.clk125.nextNegedge;
    b.speed.put(2);
    for (var i = 0; i < 200; i++) {
      await b.clk125.nextPosedge;
    }
    await b.finish();
    expect(p, isNotEmpty);
    expect(p.map((e) => e.$2).toSet(), {4});
  });

  test('false carrier gives rx_er with rx_dv low at 1000 Mbps', () async {
    final clk = SimpleClockGenerator(8).clk;
    final rxc = Logic()..inject(0);
    final rxd = Logic(width: 4)..inject(0);
    final ctl = Logic()..inject(0);
    final reset = Logic()..inject(1);
    final top = _RxTop(rxc, rxd, ctl, clk, reset);
    await top.build();
    final seen = <(int, int)>[];
    Simulator.setMaxSimTime(100000);
    unawaited(Simulator.run());
    // Rise data, fall data, rise control, fall control for each clock. The
    // false carrier code is control 0 then 1 with data 0xE.
    final syms = <(int, int, int, int)>[
      for (var i = 0; i < 40; i++) (0, 0, 0, 0),
      for (var i = 0; i < 4; i++) (0xE, 0x0, 0, 1),
      for (var i = 0; i < 10; i++) (0, 0, 0, 0),
    ];
    var n = 0;
    for (final (r, f, cr, cf) in syms) {
      if (n++ == 10) reset.inject(0);
      rxd.put(r);
      ctl.put(cr);
      await ethSimDelay(2);
      rxc.put(1);
      await ethSimDelay(2);
      rxd.put(f);
      ctl.put(cf);
      await ethSimDelay(2);
      rxc.put(0);
      await ethSimDelay(2);
      if (n > 20) {
        seen.add((
          top.output('dv').value.toInt(),
          top.output('er').value.toInt(),
        ));
      }
    }
    await Simulator.endSimulation();
    expect(seen.every((e) => e.$1 == 0), isTrue);
    expect(seen.where((e) => e.$2 == 1).length, 4);
  });

  group('HarborEthPhyRgmii build', () {
    HarborEthPhyRgmii make(
      HarborDeviceTarget target, {
      int taps = 0,
      bool clk200 = false,
      bool phyRxDelay = true,
      bool shift = true,
      bool idelayCtrl = true,
    }) => HarborEthPhyRgmii(
      HarborEthByteStream(),
      config: HarborEthernetConfig(
        phy: HarborEthPhy.rgmii,
        maxSpeed: HarborEthSpeed.mbps1000,
        rgmiiRxDelayTaps: taps,
        rgmiiPhyRxDelay: phyRxDelay,
        txClockShift: shift,
      ),
      idelayCtrl: idelayCtrl,
      target: target,
      reset: Logic(),
      speed: Logic(width: 2),
      clk125: Logic(),
      clk125_90: Logic(),
      rgmiiRxc: Logic(),
      rgmiiRxd: Logic(width: 4),
      rgmiiRxCtl: Logic(),
      clk200: clk200 ? Logic() : null,
    );

    test('Artix constraints have a 125 MHz clock on rgmii_rxc', () {
      final phy = make(_artix);
      final xdc = phy.constraints().expand((c) => c.toXdc()).toList();
      expect(
        xdc,
        contains(
          'create_clock -name rgmii_rxc -period 8.000 '
          '[get_ports rgmii_rxc]',
        ),
      );
      expect(
        xdc,
        contains(startsWith('create_generated_clock -name rgmii_txc')),
      );
      expect(
        xdc,
        contains(
          'set_input_delay -clock rgmii_rxc -max 2.200 '
          '[get_ports {rgmii_rxd[*] rgmii_rx_ctl}]',
        ),
      );
      expect(
        xdc,
        contains(
          'set_output_delay -clock rgmii_txc -min -1.000 '
          '-clock_fall -add_delay [get_ports {rgmii_txd[*] rgmii_tx_ctl}]',
        ),
      );
      final named = phy.constraints(topPort: (n) => 'eth0_$n');
      expect(named.first.ports, ['eth0_rgmii_rxc']);
      expect(named.first.clock, 'eth0_rgmii_rxc');
      final scoped = phy
          .constraints(topPort: (n) => 'eth0_$n', instance: 'eth0')
          .expand((c) => c.toXdc());
      expect(
        scoped,
        contains(
          'create_generated_clock -name eth0_rgmii_txc '
          '-source [get_pins -hierarchical -filter '
          '{NAME =~ *eth0/*/txc_oddr/C}] '
          '-multiply_by 1 [get_ports eth0_rgmii_txc]',
        ),
      );
    });

    test('Artix has a generated clock on the RX BUFR, ECP5 has none', () {
      final xdc = make(_artix)
          .constraints(topPort: (n) => 'eth0_$n', instance: 'eth0')
          .expand((c) => c.toXdc());
      expect(
        xdc,
        contains(
          'create_generated_clock -name eth0_rgmii_rxc_bufr '
          '-source [get_ports eth0_rgmii_rxc] -divide_by 1 '
          '[get_pins -hierarchical -filter {NAME =~ *eth0/*/rx_bufr/O}]',
        ),
      );
      final ecp = make(_ecp5).constraints().expand((c) => c.toXdc());
      expect(ecp, isNot(contains(contains('_bufr'))));
    });

    test('the shifted TX clock path has 2 clocks of setup', () {
      List<String> xdc(bool shift) => make(
        _artix,
        shift: shift,
      ).constraints().expand((c) => c.toXdc()).toList();
      const path =
          '-from [get_cells -hierarchical {*txc_d1* *txc_d2*}] '
          '-to [get_cells -hierarchical {*txc_s1* *txc_s2*}]';
      expect(xdc(true), contains('set_multicycle_path -setup 2 $path'));
      expect(xdc(true), contains('set_multicycle_path -hold 1 $path'));
      expect(xdc(false), isNot(contains(startsWith('set_multicycle_path'))));
    });

    test('rgmiiPhyRxDelay selects the input delays, taps do not', () {
      List<String> xdc({required bool phy, required int taps}) => make(
        _artix,
        taps: taps,
        clk200: true,
        phyRxDelay: phy,
      ).constraints().expand((c) => c.toXdc()).toList();
      const ports = '[get_ports {rgmii_rxd[*] rgmii_rx_ctl}]';
      for (final taps in [0, 10]) {
        expect(
          xdc(phy: true, taps: taps),
          contains('set_input_delay -clock rgmii_rxc -min 0.600 $ports'),
        );
        expect(
          xdc(phy: false, taps: taps),
          contains('set_input_delay -clock rgmii_rxc -max 0.500 $ports'),
        );
        expect(
          xdc(phy: false, taps: taps),
          contains('set_input_delay -clock rgmii_rxc -min -0.500 $ports'),
        );
      }
    });

    test('taps on a simulation target throw', () {
      expect(() => make(const HarborSimTarget(), taps: 4), throwsArgumentError);
    });

    test('a shared IDELAYCTRL needs no clk200', () async {
      final phy = make(_artix, taps: 26, idelayCtrl: false);
      await phy.build();
      final sv = phy.generateSynth();
      expect(sv, contains('IDELAYE2'));
      expect(sv, isNot(contains('IDELAYCTRL')));
    });

    test('taps on Xilinx need clk200', () {
      expect(() => make(_artix, taps: 26), throwsArgumentError);
      expect(() => make(_artix, taps: 32, clk200: true), throwsArgumentError);
    });

    test('iCE40 has no DDR I/O', () {
      expect(
        () =>
            make(const HarborFpgaTarget.ice40(device: 'up5k', package: 'sg48')),
        throwsUnsupportedError,
      );
    });

    test('Xilinx SystemVerilog has the cells and no sim body', () async {
      final phy = make(_artix, taps: 26, clk200: true);
      await phy.build();
      final sv = phy.generateSynth();
      for (final cell in [
        'ODDR',
        'IDDR',
        'BUFIO',
        'BUFR',
        'IDELAYE2',
        'IDELAYCTRL',
      ]) {
        expect(
          sv,
          contains(RegExp('^\\s*$cell\\b', multiLine: true)),
          reason: cell,
        );
      }
      expect(sv, isNot(contains(RegExp(r'^\s*BUFG\b', multiLine: true))));
      expect(sv, isNot(contains('_sim_')));
      // Every IDDR takes the BUFIO clock.
      final iddrs = RegExp(r'IDDR\s[^;]*;').allMatches(sv).toList();
      expect(iddrs, hasLength(5));
      for (final m in iddrs) {
        expect(m.group(0), contains('.C(rx_io_clk)'));
      }
      expect(sv, contains(RegExp(r'\.O\(rx_clk_buf\)')));
    });

    test('ECP5 SystemVerilog has the cells', () async {
      final phy = make(_ecp5, taps: 40);
      await phy.build();
      final sv = phy.generateSynth();
      for (final cell in ['ODDRX1F', 'IDDRX1F', 'DELAYG']) {
        expect(
          sv,
          contains(RegExp('^\\s*$cell\\b', multiLine: true)),
          reason: cell,
        );
      }
    });
  });
}
