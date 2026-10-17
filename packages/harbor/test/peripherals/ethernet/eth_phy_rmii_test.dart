import 'dart:async';
import 'dart:math';

import 'package:harbor/src/peripherals/ethernet/eth_byte_stream.dart';
import 'package:harbor/src/peripherals/ethernet/eth_config.dart';
import 'package:harbor/src/peripherals/ethernet/eth_mac_rx.dart';
import 'package:harbor/src/peripherals/ethernet/eth_mac_tx.dart';
import 'package:harbor/src/peripherals/ethernet/eth_phy_rmii.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/eth_phy_model.dart';

class _Top extends Module {
  _Top(
    EthRmiiModel m,
    Logic reset,
    Logic speed,
    Logic rxEn,
    Logic inValid,
    Logic inData,
    Logic inLast,
    Logic inErr,
  ) {
    final config = HarborEthernetConfig.basic(phy: HarborEthPhy.rmii);
    reset = addInput('reset', reset);
    final stream = HarborEthByteStream();
    final phy = HarborEthPhyRmii(
      stream,
      reset: reset,
      speed: addInput('speed', speed, width: 2),
      rmiiRefClk: addInput('rmii_ref_clk', m.refClk),
      rmiiRxd: addInput('rmii_rxd', m.rxd, width: 2),
      rmiiCrsDv: addInput('rmii_crs_dv', m.crsDv),
      rmiiRxEr: addInput('rmii_rx_er', m.rxEr),
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
    addOutput('rmii_txd', width: 2) <= phy.txd;
    addOutput('rmii_tx_en') <= phy.txEn;
  }
}

class _Bench {
  final EthRmiiModel model;
  final EthCoreProbe probe;

  _Bench(this.model, this.probe);

  static Future<_Bench> start({required bool fast}) async {
    final model = EthRmiiModel(fast: fast);
    final reset = Logic();
    final speed = Logic(width: 2);
    final rxEn = Logic();
    final inValid = Logic();
    final inData = Logic(width: 8);
    final inLast = Logic();
    final inErr = Logic();
    final top = _Top(model, reset, speed, rxEn, inValid, inData, inLast, inErr);
    await top.build();
    model.attach(top.output('rmii_txd'), top.output('rmii_tx_en'));
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
      await model.refClk.nextPosedge;
    }
    reset.inject(0);
    for (var i = 0; i < 8; i++) {
      await model.refClk.nextPosedge;
    }
    model.start();
    probe.collect(model.refClk);
    return _Bench(model, probe);
  }

  Future<void> finish() async {
    model.stop();
    probe.stop();
    await Simulator.endSimulation();
  }
}

const _bcast = HarborEthMacRx.statusBcast;
const _bcastEr = _bcast | HarborEthMacRx.statusRxEr;

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
    group('HarborEthPhyRmii $name', () {
      test('transmit frames are whole on the pins', () async {
        final b = await _Bench.start(fast: fast);
        final rand = Random(1);
        final frames = [_frame(rand, 60), _frame(rand, 77), _frame(rand, 64)];
        b.probe.feed(b.model.refClk, frames);
        await b.probe.waitFor(
          b.model.refClk,
          () => b.model.txFrames.length == frames.length,
          fast ? 4000 : 40000,
        );
        await b.finish();
        expect(b.model.txFrames, hasLength(frames.length));
        for (var i = 0; i < frames.length; i++) {
          final f = b.model.txFrames[i];
          expect(f.bytes, equals(ethWireFrame(frames[i])), reason: 'frame $i');
          expect(f.malformed, isFalse);
        }
      });

      test('receive frames reach the core at any pair phase', () async {
        final b = await _Bench.start(fast: fast);
        final rand = Random(2);
        final frames = [for (var i = 0; i < 4; i++) _frame(rand, 60 + 9 * i)];
        for (var i = 0; i < frames.length; i++) {
          await b.model.sendFrame(
            ethWireFrame(frames[i]),
            idleClocks: 1 + 3 * i,
          );
        }
        await b.finish();
        expect(b.probe.rxFrames, equals(frames));
        expect(b.probe.rxStatus, everyElement(_bcast));
      });

      test('loopback returns the frames', () async {
        final b = await _Bench.start(fast: fast);
        b.model.loopback = true;
        final rand = Random(3);
        final frames = [_frame(rand, 60), _frame(rand, 100)];
        b.probe.feed(b.model.refClk, frames);
        await b.probe.waitFor(
          b.model.refClk,
          () => b.probe.rxFrames.length == frames.length,
          fast ? 4000 : 40000,
        );
        await b.finish();
        expect(b.probe.rxFrames, equals(frames));
        expect(b.probe.rxStatus, everyElement(_bcast));
      });

      test('crs_dv toggling at the end does not cut the last byte', () async {
        final b = await _Bench.start(fast: fast);
        final rand = Random(4);
        final frames = [_frame(rand, 60), _frame(rand, 61)];
        await b.model.sendFrame(ethWireFrame(frames[0]), toggleBytes: 2);
        await b.model.sendFrame(
          ethWireFrame(frames[1]),
          toggleBytes: 1,
          idleClocks: 13,
        );
        await b.finish();
        expect(b.probe.rxFrames, equals(frames));
        expect(b.probe.rxStatus, everyElement(_bcast));
      });

      test('carrier before the preamble is skipped', () async {
        final b = await _Bench.start(fast: fast);
        final frames = [_frame(Random(5), 80)];
        await b.model.sendFrame(
          ethWireFrame(frames[0]),
          earlyPairs: 5,
          toggleBytes: 2,
        );
        await b.finish();
        expect(b.probe.rxFrames, equals(frames));
        expect(b.probe.rxStatus, everyElement(_bcast));
      });

      for (final skip in [1, 2, 3]) {
        test('preamble short by $skip pairs', () async {
          final b = await _Bench.start(fast: fast);
          final frames = [_frame(Random(7), 64)];
          await b.model.sendFrame(
            ethWireFrame(frames[0]),
            skipPairs: skip,
            earlyPairs: skip == 2 ? 3 : 0,
          );
          await b.finish();
          expect(b.probe.rxFrames, equals(frames));
        });
      }

      test('rx_er on a pair reaches the status', () async {
        final b = await _Bench.start(fast: fast);
        final frames = [_frame(Random(8), 70)];
        await b.model.sendFrame(ethWireFrame(frames[0]), erAtPair: 150);
        await b.finish();
        expect(b.probe.rxFrames, equals(frames));
        expect(b.probe.rxStatus, [_bcastEr]);
      });

      test('a half byte at the end drops and sets rx_er', () async {
        final b = await _Bench.start(fast: fast);
        final rand = Random(6);
        final frames = [_frame(rand, 60), _frame(rand, 60)];
        await b.model.sendFrame(
          ethWireFrame(frames[0]),
          dribble: true,
          toggleBytes: 1,
        );
        await b.model.sendFrame(ethWireFrame(frames[1]));
        await b.finish();
        expect(b.probe.rxFrames, equals(frames));
        expect(b.probe.rxStatus, [_bcastEr, _bcast]);
      });
    });
  }
}
