import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Runs the fetcher before the start_s3 stage and the current fetcher side
/// by side. The current one gets each port input one cycle late, so each
/// of its outputs must be the output of the old one, one cycle late.
Future<void> _compare({required int seed, required int lines}) async {
  final rng = Random(seed);
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic()..inject(1);
  final start = Logic()..inject(0);
  final fetchAddr = Logic(width: 32)..inject(0);
  final words = Logic(width: 16)..inject(0);
  final fill = Logic()..inject(0);
  Logic bit() => Logic()..inject(0);
  Logic half() => Logic(width: 16)..inject(0);
  final (oReady, oValid, oData) = (bit(), bit(), half());
  final (nReady, nValid, nData) = (bit(), bit(), half());

  final old = _OldScanoutFetcher(
    clk: clk,
    reset: reset,
    fetchStart: start,
    fetchAddr: fetchAddr,
    words: words,
    fillSel: fill,
    rqReady: oReady,
    rdValid: oValid,
    rdData: oData,
  );
  final cur = HarborScanoutFetcher(
    clk: clk,
    reset: reset,
    fetchStart: start,
    fetchAddr: fetchAddr,
    words: words,
    fillSel: fill,
    rqReady: nReady,
    rdValid: nValid,
    rdData: nData,
  );
  await old.build();
  await cur.build();

  const shifted = [
    'rq_valid',
    'rq_addr',
    'rq_words',
    'wr_en',
    'wr_idx',
    'wr_data',
    'done',
  ];
  final prev = <String, LogicValue>{};
  var prevBusy = LogicValue.zero;
  var prevIn = (0, 0, 0);
  final pipe = Queue<(int, int)>();
  var cycle = 0;
  var checked = 0;

  clk.negedge.listen((_) {
    cycle++;
    if (reset.value == LogicValue.zero) {
      for (final n in shifted) {
        expect(
          cur.output(n).value,
          prev[n],
          reason: 'cycle $cycle: $n is not the old $n one cycle late',
        );
      }
      if (cur.wrEn.value == LogicValue.one) {
        expect(cur.wrSel.value, prev['wr_sel'], reason: 'cycle $cycle');
      }
      final oldBusy = old.output('busy').value;
      expect(cur.busy.value, oldBusy | prevBusy, reason: 'cycle $cycle: busy');
      checked++;
    }
    for (final n in [...shifted, 'wr_sel']) {
      prev[n] = old.output(n).value;
    }
    prevBusy = old.output('busy').value;

    // The old fetcher's port, with a random ready and latency.
    final ready = rng.nextInt(3) != 0;
    if (ready && old.output('rq_valid').value == LogicValue.one) {
      final a = old.output('rq_addr').value.toInt();
      final k = old.output('rq_words').value.toInt();
      final t0 =
          max(cycle, pipe.isEmpty ? 0 : pipe.last.$1) + 1 + rng.nextInt(6);
      for (var i = 0; i < k; i++) {
        pipe.add((t0 + i, ((a >> 1) + i) * 0x9E37 & 0xFFFF));
      }
    }
    final out = pipe.isNotEmpty && pipe.first.$1 <= cycle;
    final d = out ? pipe.removeFirst().$2 : 0;
    nReady.put(prevIn.$1);
    nValid.put(prevIn.$2);
    nData.put(prevIn.$3);
    oReady.put(ready ? 1 : 0);
    oValid.put(out ? 1 : 0);
    oData.put(d);
    prevIn = (ready ? 1 : 0, out ? 1 : 0, d);
  });

  Simulator.setMaxSimTime(1 << 40);
  unawaited(Simulator.run());
  try {
    await clk.nextNegedge;
    await clk.nextNegedge;
    reset.put(0);
    for (var l = 0; l < lines; l++) {
      for (var i = rng.nextInt(4); i >= 0; i--) {
        await clk.nextNegedge;
      }
      fetchAddr.put(rng.nextInt(1 << 20) << 2 | rng.nextInt(4));
      words.put(rng.nextInt(5) == 0 ? rng.nextInt(3) : 1 + rng.nextInt(40));
      fill.put(rng.nextInt(2));
      start.put(1);
      await clk.nextNegedge;
      start.put(0);
      for (var c = 0; cur.busy.value == LogicValue.one; c++) {
        if (c > 5000) fail('line $l is not done');
        await clk.nextNegedge;
      }
    }
    await clk.nextNegedge;
  } finally {
    await Simulator.endSimulation();
  }
  expect(checked, greaterThan(lines));
}

void main() {
  tearDown(() async => Simulator.reset());

  for (final seed in [1, 2, 3, 4]) {
    test('the fetcher is the old fetcher one cycle late, seed $seed', () async {
      await _compare(seed: seed, lines: 60);
    });
  }
}

/// The fetcher as it was before the start_s3 stage.
class _OldScanoutFetcher extends Module {
  Logic get rqValid => output('rq_valid');
  Logic get rqAddr => output('rq_addr');
  Logic get rqWords => output('rq_words');
  Logic get wrEn => output('wr_en');
  Logic get wrSel => output('wr_sel');
  Logic get wrIdx => output('wr_idx');
  Logic get wrData => output('wr_data');
  Logic get busy => output('busy');
  Logic get done => output('done');

  final int maxWords;
  final int maxBurst;
  static const rqWordsWidth = 4;

  _OldScanoutFetcher({
    required Logic clk,
    required Logic reset,
    required Logic fetchStart,
    required Logic fetchAddr,
    required Logic words,
    required Logic fillSel,
    required Logic rqReady,
    required Logic rdValid,
    required Logic rdData,
    this.maxWords = 1024,
    this.maxBurst = 8,
  }) : super(
         name: 'old_scanout_fetcher',
         definitionName: 'OldScanoutFetcher_b${maxBurst}_w$maxWords',
       ) {
    if (maxBurst < 2 ||
        (maxBurst & (maxBurst - 1)) != 0 ||
        maxBurst >= (1 << rqWordsWidth)) {
      throw ArgumentError.value(
        maxBurst,
        'maxBurst',
        'must be a power of two from 2 to ${1 << (rqWordsWidth - 1)}',
      );
    }
    final idxW = (maxWords - 1).bitLength < 1 ? 1 : (maxWords - 1).bitLength;

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    fetchStart = addInput('fetch_start', fetchStart);
    fetchAddr = addInput('fetch_addr', fetchAddr, width: 32);
    words = addInput('words', words, width: 16);
    fillSel = addInput('fill_sel', fillSel);
    rqReady = addInput('rq_ready', rqReady);
    rdValid = addInput('rd_valid', rdValid);
    rdData = addInput('rd_data', rdData, width: 16);

    addOutput('rq_valid');
    addOutput('rq_addr', width: 32);
    addOutput('rq_words', width: rqWordsWidth);
    addOutput('wr_en');
    addOutput('wr_sel');
    addOutput('wr_idx', width: idxW);
    addOutput('wr_data', width: 32);
    addOutput('busy');
    addOutput('done');

    const lw = 17;
    final burstBits = maxBurst.bitLength - 1;

    final reading = Logic(name: 'reading');
    final fillReg = Logic(name: 'fill_reg');
    final doneReg = Logic(name: 'done_reg');
    // The request on offer, and the 16-bit words after it.
    final valid = Logic(name: 'rq_valid_reg');
    final addr = Logic(name: 'addr', width: 32);
    final len = Logic(name: 'len', width: rqWordsWidth);
    final reqLeft = Logic(name: 'req_left', width: lw);
    // 16-bit words not yet back, and the low half of a pair.
    final rdLeft = Logic(name: 'rd_left', width: lw);
    final odd = Logic(name: 'odd');
    final low = Logic(name: 'low', width: 16);
    final idx = Logic(name: 'idx', width: idxW);
    final wrEnReg = Logic(name: 'wr_en_reg');
    final wrDataReg = Logic(name: 'wr_data_reg', width: 32);
    final wrIdxReg = Logic(name: 'wr_idx_reg', width: idxW);

    Logic minOf(Logic a, Logic b) => mux(a.lt(b), a, b);

    // Stage 1 takes the start inputs from a far source. Stage 2 holds the
    // first request.
    final start1 = Logic(name: 'start_s1');
    final addr1 = Logic(name: 'addr_s1', width: 30);
    final words1 = Logic(name: 'words_s1', width: 16);
    final fill1 = Logic(name: 'fill_s1');
    final start2 = Logic(name: 'start_s2');
    final addr2 = Logic(name: 'addr_s2', width: 32);
    final len2 = Logic(name: 'len_s2', width: rqWordsWidth);
    final left2 = Logic(name: 'left_s2', width: lw);
    final total2 = Logic(name: 'total_s2', width: lw);
    final any2 = Logic(name: 'any_s2');
    final fill2 = Logic(name: 'fill_s2');

    final startAddr = [addr1, Const(0, width: 2)].concat().named('start_addr');
    // The first request runs to the end of its group.
    final total = [words1, Const(0)].concat().named('total');
    final toGroupEnd =
        (Const(maxBurst, width: lw) -
                startAddr.getRange(1, 1 + burstBits).zeroExtend(lw))
            .named('to_group_end');
    final firstLen = minOf(total, toGroupEnd).named('first_len');

    // Every later request starts on a group, so it asks for
    // min(req_left, maxBurst). The left_* registers hold this for req_left.
    // A start loads them with req_left, so they are correct at the first
    // offer. A take makes them one cycle late, and a take never comes in the
    // cycle after a take.
    final leftSub = Logic(name: 'left_sub', width: lw);
    final leftBig = Logic(name: 'left_big');
    final leftLow = Logic(name: 'left_low');
    final take = Logic(name: 'take');
    final rdValidReg = Logic(name: 'rd_valid_reg');
    final rdDataReg = Logic(name: 'rd_data_reg', width: 16);
    final got = (reading & rdValidReg).named('got');
    final leftSrc = mux(start2, left2, reqLeft).named('left_src');

    rqValid <= valid;
    rqAddr <= addr;
    rqWords <= len;
    wrEn <= wrEnReg;
    wrSel <= fillReg;
    wrIdx <= wrIdxReg;
    wrData <= wrDataReg;
    busy <= reading | start1 | start2;
    done <= doneReg;

    // Only the control flops reset, so the reset net stays small. A start
    // loads the data flops straight from start_s2, so a synthesis tool
    // that turns a constant load into a set or reset uses that flop.
    Sequential(clk, [
      doneReg < Const(0),
      wrEnReg < Const(0),
      take < valid & rqReady,
      start1 < fetchStart,
      addr1 < fetchAddr.getRange(2),
      words1 < words,
      fill1 < fillSel,
      start2 < start1,
      addr2 < startAddr,
      len2 < firstLen.getRange(0, rqWordsWidth),
      left2 < total - firstLen,
      total2 < total,
      any2 < words1.neq(0),
      fill2 < fill1,
      leftSub < leftSrc - maxBurst,
      leftBig < leftSrc.getRange(burstBits).or(),
      leftLow < leftSrc.getRange(0, burstBits).or(),
      rdValidReg < rdValid,
      rdDataReg < rdData,
      If(
        start2,
        then: [
          addr < addr2,
          len < len2,
          valid < any2,
          reqLeft < left2,
          rdLeft < total2,
          idx < Const(0, width: idxW),
          odd < Const(0),
          fillReg < fill2,
          reading < any2,
        ],
        orElse: [
          If(
            take,
            then: [
              addr < addr + [len, Const(0)].concat().zeroExtend(32),
              len <
                  mux(
                    leftBig,
                    Const(maxBurst, width: rqWordsWidth),
                    reqLeft.getRange(0, burstBits).zeroExtend(rqWordsWidth),
                  ),
              valid < leftBig | leftLow,
              reqLeft < mux(leftBig, leftSub, Const(0, width: lw)),
            ],
            orElse: [
              If(rqReady, then: [valid < Const(0)]),
            ],
          ),
          If(
            got,
            then: [
              odd < ~odd,
              If(
                odd,
                then: [
                  wrEnReg < Const(1),
                  wrDataReg < [rdDataReg, low].concat(),
                  wrIdxReg < idx,
                  idx < idx + 1,
                ],
                orElse: [low < rdDataReg],
              ),
              rdLeft < rdLeft - 1,
              If(rdLeft.eq(1), then: [reading < Const(0), doneReg < Const(1)]),
            ],
          ),
        ],
      ),
      If(
        reset,
        then: [
          reading < Const(0),
          valid < Const(0),
          take < Const(0),
          start1 < Const(0),
          start2 < Const(0),
          rdValidReg < Const(0),
        ],
      ),
    ]);
  }
}
