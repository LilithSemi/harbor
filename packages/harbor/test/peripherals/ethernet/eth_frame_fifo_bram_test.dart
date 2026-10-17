// A built HarborDualClockBram makes later simulations in the same isolate
// slow, so these tests have their own file.
import 'dart:async';
import 'dart:math';

import 'package:harbor/src/peripherals/ethernet/eth_frame_fifo.dart';
import 'package:harbor/src/soc/target.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _ecp5 = HarborFpgaTarget.ecp5(device: 'lfe5u-25f', package: 'CABGA381');

List<List<int>> _frames(Random r, int n, int maxLen) => [
  for (var i = 0; i < n; i++)
    [for (var k = 0, len = 1 + r.nextInt(maxLen); k < len; k++) r.nextInt(256)],
];

Future<void> _cycles(Logic clk, int n) async {
  for (var i = 0; i < n; i++) {
    await clk.nextPosedge;
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('tx block RAM storage: frames out equal frames in', () async {
    final r = Random(40);
    final sysClk = SimpleClockGenerator(10).clk;
    final txClk = SimpleClockGenerator(8).clk;
    final sysReset = Logic()..inject(1);
    final txReset = Logic()..inject(1);
    final wValid = Logic()..inject(0);
    final wData = Logic(width: 32)..inject(0);
    final wBytes = Logic(width: 2)..inject(0);
    final wLast = Logic()..inject(0);
    final inReady = Logic()..inject(1);
    final dut = HarborEthTxFrameFifo(
      sysClk,
      sysReset,
      txClk,
      txReset,
      bytes: 64,
      wValid: wValid,
      wData: wData,
      wBytes: wBytes,
      wLast: wLast,
      wErr: Const(0),
      inReady: inReady,
      target: _ecp5,
    );
    await dut.build();
    expect(dut.usesBlockRam, isTrue);
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    await _cycles(sysClk, 4);
    sysReset.inject(0);
    txReset.inject(0);
    await _cycles(sysClk, 20);

    final frames = _frames(r, 40, 60);
    final out = <List<int>>[];
    var cur = <int>[];
    txClk.negedge.listen((_) {
      if (!dut.inValid.value.toBool()) return;
      cur.add(dut.inData.value.toInt());
      if (dut.inLast.value.toBool()) {
        out.add(cur);
        cur = [];
      }
    });
    for (final f in frames) {
      final words = (f.length + 3) ~/ 4;
      var wi = 0;
      while (wi < words) {
        await sysClk.nextNegedge;
        var word = 0;
        for (var k = 0; k < 4 && wi * 4 + k < f.length; k++) {
          word |= f[wi * 4 + k] << (8 * k);
        }
        wValid.put(1);
        wData.put(word);
        wBytes.put(f.length % 4);
        wLast.put(wi == words - 1);
        if (dut.wReady.value.toBool()) wi++;
      }
    }
    await sysClk.nextNegedge;
    wValid.put(0);
    await _cycles(sysClk, 200);
    expect(out, frames);
    await Simulator.endSimulation();
  });

  test('rx block RAM storage: frames out equal frames in', () async {
    final r = Random(41);
    final rxClk = SimpleClockGenerator(8).clk;
    final sysClk = SimpleClockGenerator(10).clk;
    final rxReset = Logic()..inject(1);
    final sysReset = Logic()..inject(1);
    final inValid = Logic()..inject(0);
    final inData = Logic(width: 8)..inject(0);
    final inLast = Logic()..inject(0);
    final inStatus = Logic(width: 8)..inject(0);
    final dut = HarborEthRxFrameFifo(
      rxClk,
      rxReset,
      sysClk,
      sysReset,
      bytes: 64,
      inValid: inValid,
      inData: inData,
      inLast: inLast,
      inStatus: inStatus,
      rReady: Const(1),
      target: _ecp5,
    );
    await dut.build();
    expect(dut.usesBlockRam, isTrue);
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    await _cycles(sysClk, 4);
    rxReset.inject(0);
    sysReset.inject(0);
    await _cycles(sysClk, 20);

    final frames = _frames(r, 40, 40);
    final out = <List<int>>[];
    final status = <int>[];
    var cur = <int>[];
    sysClk.negedge.listen((_) {
      if (dut.rxOverflow.value.toBool()) fail('overflow');
      if (!dut.rValid.value.toBool()) return;
      final w = dut.rData.value.toInt();
      final last = dut.rLast.value.toBool();
      final b = dut.rBytes.value.toInt();
      final n = last && b != 0 ? b : 4;
      for (var k = 0; k < n; k++) {
        cur.add((w >> (8 * k)) & 0xFF);
      }
      if (last) {
        out.add(cur);
        status.add(dut.rStatus.value.toInt());
        cur = [];
      }
    });
    for (var fi = 0; fi < frames.length; fi++) {
      final f = frames[fi];
      for (var i = 0; i < f.length; i++) {
        await rxClk.nextNegedge;
        inValid.put(1);
        inData.put(f[i]);
        inLast.put(i == f.length - 1);
        inStatus.put(i == f.length - 1 ? fi : 0);
      }
      await rxClk.nextNegedge;
      inValid.put(0);
      await _cycles(rxClk, 12);
    }
    await _cycles(sysClk, 200);
    expect(out, frames);
    expect(status, [for (var i = 0; i < frames.length; i++) i]);
    await Simulator.endSimulation();
  });
}
