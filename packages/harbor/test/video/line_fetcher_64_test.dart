// HarborLineFetcher on a 64 bit waist: two words in each beat, low word
// first, odd word counts, lines in several bursts, a 4 KiB crossing, an
// errored beat and random back pressure on the read data.

import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../bus/port/memory_harness.dart';

const _burstWords = 4;
const _maxWords = 256;

class _Rig extends BridgeModule {
  _Rig() : super('LineFetch64Rig', name: 'rig') {
    for (final p in ['clk', 'reset', 'fetch_start', 'fill_sel']) {
      createPort(p, PortDirection.input);
    }
    createPort('fetch_addr', PortDirection.input, width: 32);
    createPort('words', PortDirection.input, width: 16);
    final w = HarborMemoryWaist(
      const HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 64),
    );
    exposeWaist(this, w, 'm', PairRole.provider);
    final f = HarborLineFetcher(
      clk: input('clk'),
      reset: input('reset'),
      fetchStart: input('fetch_start'),
      fetchAddr: input('fetch_addr'),
      words: input('words'),
      fillSel: input('fill_sel'),
      waist: w,
      maxWords: _maxWords,
      burstWords: _burstWords,
    );
    addOutput('wr_en') <= f.wrEn;
    addOutput('wr_idx', width: 8) <= f.wrIdx;
    addOutput('wr_data', width: 32) <= f.wrData;
    addOutput('err') <= f.err;
    addOutput('busy') <= f.busy;
    addOutput('done') <= f.done;
  }
}

int _word(int index) => 0x10000000 + index * 0x101;

Future<void> _run({required double gap, Set<int> errBeats = const {}}) async {
  final top = _Rig();
  final clk = SimpleClockGenerator(10).clk;
  final rng = Random(11);
  for (final i in top.inputs.values) {
    if (i.name != 'clk') i.srcConnection!.put(0);
  }
  top.input('clk').srcConnection! <= clk;
  await top.build();
  Logic out(String n) => top.output(n);
  Logic inp(String n) => top.input(n).srcConnection!;

  // Memory model: requests are taken at once, beats come back in order.
  final requests = <(int, int)>[];
  final beats = <(int, bool)>[];
  var presenting = false;
  final written = <int, int>{};
  final writes = <int>[];
  var errPulses = 0;
  var done = false;
  clk.posedge.listen((_) {
    bool hi(Logic l) {
      final v = l.previousValue;
      return v != null && v.isValid && v.toBool();
    }

    if (hi(out('m_REQ_VALID')) && hi(top.input('m_REQ_READY'))) {
      final addr = out('m_REQ_ADDR').previousValue!.toInt();
      final len = out('m_REQ_LEN').previousValue!.toInt() + 1;
      requests.add((addr, len));
      for (var k = 0; k < len; k++) {
        final a = addr + 8 * k;
        beats.add((a, errBeats.contains(a)));
      }
    }
    if (presenting &&
        hi(top.input('m_RDATA_VALID')) &&
        hi(out('m_RDATA_READY'))) {
      beats.removeAt(0);
    }
    if (hi(out('wr_en'))) {
      final idx = out('wr_idx').previousValue!.toInt();
      written[idx] = out('wr_data').previousValue!.toInt();
      writes.add(idx);
    }
    if (hi(out('err'))) errPulses++;
    if (hi(out('done'))) done = true;
  });
  clk.negedge.listen((_) {
    inp('m_REQ_READY').inject(1);
    if (beats.isNotEmpty && rng.nextDouble() >= gap) {
      final (a, err) = beats.first;
      presenting = true;
      inp('m_RDATA_VALID').inject(1);
      inp('m_RDATA_ID').inject(0);
      inp('m_RDATA_ERR').inject(err ? 1 : 0);
      inp('m_RDATA_LAST').inject(0);
      final lo = _word(a ~/ 4);
      final hiW = _word(a ~/ 4 + 1);
      inp('m_RDATA_DATA').inject(BigInt.from(lo) | (BigInt.from(hiW) << 32));
    } else {
      presenting = false;
      inp('m_RDATA_VALID').inject(0);
    }
  });
  inp('reset').inject(1);
  Simulator.setMaxSimTime(4000000);
  unawaited(Simulator.run());
  for (var i = 0; i < 4; i++) {
    await clk.nextPosedge;
  }
  inp('reset').inject(0);
  await clk.nextNegedge;

  Future<void> fetch(int addr, int n) async {
    written.clear();
    writes.clear();
    requests.clear();
    errPulses = 0;
    done = false;
    inp('fetch_addr').inject(addr);
    inp('words').inject(n);
    inp('fetch_start').inject(1);
    await clk.nextPosedge;
    inp('fetch_start').inject(0);
    for (var g = 0; g < 4000 && !done; g++) {
      await clk.nextPosedge;
    }
    expect(done, isTrue, reason: 'line at 0x${addr.toRadixString(16)}');
    await clk.nextNegedge;
    // One write for each word and no more, in order, low word first.
    expect(writes, [for (var i = 0; i < n; i++) i], reason: 'write order');
    var errWords = 0;
    for (var i = 0; i < n; i++) {
      final beat = addr + 8 * (i ~/ 2);
      final bad = errBeats.contains(beat);
      if (bad) errWords++;
      expect(
        written[i],
        bad ? 0 : _word(addr ~/ 4 + i),
        reason: 'word $i of the line at 0x${addr.toRadixString(16)}',
      );
    }
    expect(
      errPulses,
      errBeats.where((b) => b >= addr && b < addr + 8 * ((n + 1) ~/ 2)).length,
    );
    expect(errWords, greaterThanOrEqualTo(0));
    // The requests run in order, cover the line, stay below burstWords and
    // do not cross 4 KiB.
    var next = addr;
    var beatsTotal = 0;
    for (final (a, len) in requests) {
      expect(a, next);
      expect(len, lessThanOrEqualTo(_burstWords));
      expect(a ~/ 4096, (a + 8 * len - 1) ~/ 4096, reason: '4 KiB crossing');
      next = a + 8 * len;
      beatsTotal += len;
    }
    expect(beatsTotal, (n + 1) ~/ 2);
  }

  await fetch(0x0FC0, 40);
  await fetch(0x2008, 37);
  await fetch(0x3000, 9);
  await Simulator.endSimulation();
}

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'two words in each beat across a 4 KiB crossing and odd lines',
    () async {
      await _run(gap: 0);
    },
  );

  test('random back pressure on the read data', () async {
    await _run(gap: 0.5);
  });

  test(
    'an errored beat writes zero for both words and pulses err once',
    () async {
      await _run(gap: 0.2, errBeats: {0x0FD0, 0x2010});
    },
  );
}
