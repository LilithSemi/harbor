import 'dart:async';
import 'dart:math';

import 'package:harbor/src/peripherals/ethernet/eth_byte_stream.dart';
import 'package:harbor/src/peripherals/ethernet/eth_config.dart';
import 'package:harbor/src/peripherals/ethernet/eth_mac_rx.dart';
import 'package:harbor/src/peripherals/ethernet/eth_mac_tx.dart';
import 'package:harbor/src/peripherals/ethernet/eth_phy_mii.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/eth_phy_model.dart';

class _Top extends Module {
  _Top(
    EthMiiModel m,
    Logic reset,
    Logic speed,
    Logic rxEn,
    Logic inValid,
    Logic inData,
    Logic inLast,
    Logic inErr,
  ) {
    final config = HarborEthernetConfig.basic(phy: HarborEthPhy.mii);
    reset = addInput('reset', reset);
    final stream = HarborEthByteStream();
    final phy = HarborEthPhyMii(
      stream,
      reset: reset,
      speed: addInput('speed', speed, width: 2),
      miiTxClk: addInput('mii_tx_clk', m.txClk),
      miiRxClk: addInput('mii_rx_clk', m.rxClk),
      miiRxd: addInput('mii_rxd', m.rxd, width: 4),
      miiRxDv: addInput('mii_rx_dv', m.rxDv),
      miiRxEr: addInput('mii_rx_er', m.rxEr),
      miiCrs: addInput('mii_crs', m.crs),
      miiCol: addInput('mii_col', m.col),
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
    addOutput('mii_txd', width: 4) <= phy.txd;
    addOutput('mii_tx_en') <= phy.txEn;
    addOutput('mii_tx_er') <= phy.txEr;
  }
}

class _Bench {
  final EthMiiModel model;
  final EthCoreProbe probe;

  _Bench(this.model, this.probe);

  static Future<_Bench> start({required bool fast}) async {
    final model = EthMiiModel(fast: fast);
    final reset = Logic();
    final speed = Logic(width: 2);
    final rxEn = Logic();
    final inValid = Logic();
    final inData = Logic(width: 8);
    final inLast = Logic();
    final inErr = Logic();
    final top = _Top(model, reset, speed, rxEn, inValid, inData, inLast, inErr);
    await top.build();
    model.attach(
      top.output('mii_txd'),
      top.output('mii_tx_en'),
      top.output('mii_tx_er'),
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
    speed.inject(fast ? 1 : 0);
    rxEn.inject(1);
    Simulator.setMaxSimTime(100000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await model.txClk.nextPosedge;
    }
    reset.inject(0);
    for (var i = 0; i < 8; i++) {
      await model.rxClk.nextPosedge;
    }
    model.start();
    probe.collect(model.rxClk);
    return _Bench(model, probe);
  }

  Future<void> finish() async {
    model.stop();
    probe.stop();
    await Simulator.endSimulation();
  }
}

const bcastEr = HarborEthMacRx.statusBcast | HarborEthMacRx.statusRxEr;

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

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  for (final fast in [true, false]) {
    final name = fast ? '100 Mbps' : '10 Mbps';
    group('HarborEthPhyMii $name', () {
      test('transmit frames are whole on the pins', () async {
        final b = await _Bench.start(fast: fast);
        final rand = Random(1);
        final frames = [_frame(rand, 60), _frame(rand, 77), _frame(rand, 64)];
        b.probe.feed(b.model.txClk, frames);
        await b.probe.waitFor(
          b.model.txClk,
          () => b.model.txFrames.length == frames.length,
          3000,
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

      test('receive frames reach the core', () async {
        final b = await _Bench.start(fast: fast);
        final rand = Random(2);
        final frames = [_frame(rand, 60), _frame(rand, 90), _frame(rand, 64)];
        for (var i = 0; i < frames.length; i++) {
          await b.model.sendFrame(ethWireFrame(frames[i]), idleClocks: 1 + i);
        }
        await b.finish();
        expect(b.probe.rxFrames, equals(frames));
        expect(b.probe.rxStatus, everyElement(HarborEthMacRx.statusBcast));
      });

      test('loopback returns the frames', () async {
        final b = await _Bench.start(fast: fast);
        b.model.loopback = true;
        final rand = Random(3);
        final frames = [_frame(rand, 60), _frame(rand, 100)];
        b.probe.feed(b.model.txClk, frames);
        await b.probe.waitFor(
          b.model.txClk,
          () => b.probe.rxFrames.length == frames.length,
          3000,
        );
        await b.finish();
        expect(b.probe.rxFrames, equals(frames));
        expect(b.probe.rxStatus, everyElement(HarborEthMacRx.statusBcast));
      });

      test('a half byte at the end drops and sets rx_er', () async {
        final b = await _Bench.start(fast: fast);
        final rand = Random(4);
        final frames = [_frame(rand, 60), _frame(rand, 60)];
        await b.model.sendFrame(ethWireFrame(frames[0]), dribble: true);
        await b.model.sendFrame(ethWireFrame(frames[1]));
        await b.finish();
        expect(b.probe.rxFrames, equals(frames));
        expect(b.probe.rxStatus, [bcastEr, HarborEthMacRx.statusBcast]);
      });

      test('preamble short by 1 nibble', () async {
        final b = await _Bench.start(fast: fast);
        final frames = [_frame(Random(7), 64)];
        await b.model.sendFrame(ethWireFrame(frames[0]), skipNibbles: 1);
        await b.finish();
        expect(b.probe.rxFrames, equals(frames));
      });

      test('rx_er on a nibble reaches the status', () async {
        final b = await _Bench.start(fast: fast);
        final frame = _frame(Random(5), 70);
        await b.model.sendFrame(ethWireFrame(frame), erAtNibble: 41);
        await b.finish();
        expect(b.probe.rxFrames, equals([frame]));
        expect(b.probe.rxStatus, [bcastEr]);
      });
    });
  }
}
