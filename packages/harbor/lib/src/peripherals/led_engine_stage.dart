import 'package:rohd/rohd.dart';

import '../arith/fpu_config.dart' show harborStableDefinitionName;
import 'led_engine.dart' show HarborLedByte, HarborLedPin;

/// One serial channel of the LED engine: the item reader, the output stage
/// and the frame control for a raw pulse train.
///
/// An item is 16 bits: bit 15 is the level and bits 14:0 are the duration in
/// ticks. A duration of 0 ends the train, and so does a read past the end of
/// the item RAM. The reader prefetches one item from a shared item RAM with
/// an asynchronous read. It asks with `ram_req` and takes `ram_data` in the
/// cycle `ram_grant` is high. No control decision uses `ram_data`: the data
/// goes into the prefetch register and the registered copy is tested.
///
/// The reader keeps the first item of the train in a register. A train with
/// a LOOP count starts again from that register, so a repeat has no gap.
/// When the next item is not ready at a tick, the pin keeps its level and
/// `underrun` goes high until the next SEND.
///
/// With `pixel` high, the items come from a pixel expander and the item
/// address is not used.
class HarborLedSerialChannel extends Module {
  final int addrWidth;

  Logic get pin => output('pin');
  Logic get busy => output('busy');

  /// One clock high when a train ends.
  Logic get done => output('done');

  /// High from a missed item until the next SEND.
  Logic get underrun => output('underrun');
  Logic get ramReq => output('ram_req');

  /// High with `ram_req` when the item is needed to keep the train exact.
  /// It is low for the read of the first item, which has no deadline.
  Logic get ramCritical => output('ram_crit');

  /// High in a clock in which the reader takes an item.
  Logic get fetched => output('fetched');
  Logic get ramAddr => output('ram_addr');

  /// Completed trains, 8 bits.
  Logic get frameCount => output('frame_count');

  /// The index of the item on the pin.
  Logic get state => output('state');

  HarborLedSerialChannel({
    required Logic clk,
    required Logic reset,
    required Logic tick,
    required Logic send,
    required Logic polarity,
    required Logic idle,
    required Logic itemStart,
    required Logic loop,
    required Logic ramData,
    required Logic ramGrant,
    required Logic pixel,
    required this.addrWidth,
    required bool activeLow,
    super.name = 'led_serial_channel',
  }) : super(
         definitionName:
             'HarborLedSerialChannel_a${addrWidth}_${activeLow ? 'l' : 'h'}',
         reserveDefinitionName: true,
       ) {
    final aw = addrWidth;
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    tick = addInput('tick', tick);
    send = addInput('send', send);
    polarity = addInput('polarity', polarity);
    idle = addInput('idle', idle);
    itemStart = addInput('item_start', itemStart, width: aw);
    loop = addInput('loop', loop, width: 8);
    ramData = addInput('ram_data', ramData, width: 16);
    ramGrant = addInput('ram_grant', ramGrant);
    pixel = addInput('pixel', pixel);
    addOutput('pin');
    addOutput('busy');
    addOutput('done');
    addOutput('underrun');
    addOutput('ram_req');
    addOutput('ram_crit');
    addOutput('fetched');
    addOutput('ram_addr', width: aw);
    addOutput('frame_count', width: 8);
    addOutput('state', width: aw);

    final busy = Logic(name: 'busy_q');
    final started = Logic(name: 'started');
    final curActive = Logic(name: 'cur_active');
    final lvl = Logic(name: 'lvl');
    final curIdx = Logic(name: 'cur_idx', width: aw);
    final remaining = Logic(name: 'remaining', width: 15);
    final pfValid = Logic(name: 'pf_valid');
    final pfLevel = Logic(name: 'pf_level');
    final pfDur = Logic(name: 'pf_dur', width: 15);
    final pfIdx = Logic(name: 'pf_idx', width: aw);
    final firstPending = Logic(name: 'first_pending');
    final firstLevel = Logic(name: 'first_level');
    final firstDur = Logic(name: 'first_dur', width: 15);
    final fetchAddr = Logic(name: 'fetch_addr', width: aw + 1);
    final startQ = Logic(name: 'start_q', width: aw);
    final loopLeft = Logic(name: 'loop_left', width: 8);
    final frames = Logic(name: 'frames', width: 8);
    final pinQ = Logic(name: 'pin_q');
    final doneQ = Logic(name: 'done_q');
    final underrunQ = Logic(name: 'underrun_q');

    final startNext = startQ.zeroExtend(aw + 1) + 1;
    final pfEnd = pfValid & pfDur.eq(0);
    // The end marker of a looping train hands out the first item again.
    final wrapping = pfEnd & loopLeft.neq(0) & firstDur.neq(0);
    final itemLevel = mux(wrapping, firstLevel, pfLevel);
    final itemDur = mux(wrapping, firstDur, pfDur);
    final itemIdx = mux(wrapping, startQ, pfIdx);
    final itemAvail = pfValid & (wrapping | pfDur.neq(0));
    final needItem = ~curActive | remaining.eq(1);
    final atTick = busy & tick & needItem;
    final consume = atTick & itemAvail;
    final finish = atTick & pfEnd & ~wrapping;

    final fetchAddrEff = mux(wrapping, startNext, fetchAddr);
    final fetchReq =
        busy & ((wrapping & consume) | (~pfEnd & (~pfValid | consume)));
    final fetching = fetchReq & ramGrant;
    final overrun = fetchAddrEff[aw] & ~pixel;
    final ramLevel = mux(overrun, Const(0), ramData[15]);
    final ramDur = mux(overrun, Const(0, width: 15), ramData.getRange(0, 15));

    output('pin') <= pinQ;
    output('busy') <= busy;
    output('done') <= doneQ;
    output('underrun') <= underrunQ;
    output('ram_req') <= fetchReq;
    output('ram_crit') <= fetchReq & (started | pfValid);
    output('fetched') <= fetching;
    output('ram_addr') <= fetchAddrEff.getRange(0, aw);
    output('frame_count') <= frames;
    output('state') <= curIdx;

    List<Conditional> loadFetched() => [
      pfValid < 1,
      pfLevel < ramLevel,
      pfDur < ramDur,
      pfIdx < fetchAddrEff.getRange(0, aw),
      fetchAddr < (fetchAddrEff + 1),
    ];

    Sequential(clk, [
      If(
        reset,
        then: [
          busy < 0,
          started < 0,
          curActive < 0,
          lvl < 0,
          curIdx < Const(0, width: aw),
          remaining < Const(0, width: 15),
          pfValid < 0,
          pfLevel < 0,
          pfDur < Const(0, width: 15),
          pfIdx < Const(0, width: aw),
          firstPending < 0,
          firstLevel < 0,
          firstDur < Const(0, width: 15),
          fetchAddr < Const(0, width: aw + 1),
          startQ < Const(0, width: aw),
          loopLeft < Const(0, width: 8),
          frames < Const(0, width: 8),
          pinQ < Const(activeLow ? 1 : 0),
          doneQ < 0,
          underrunQ < 0,
        ],
        orElse: [
          doneQ < 0,
          pinQ < (mux(busy & started, lvl, idle) ^ polarity),
          If(
            busy,
            then: [
              If(
                tick & curActive & remaining.neq(1),
                then: [remaining < (remaining - 1)],
              ),
              If(
                consume,
                then: [
                  curActive < 1,
                  started < 1,
                  lvl < itemLevel,
                  curIdx < itemIdx,
                  remaining < itemDur,
                ],
              ),
              If(
                finish,
                then: [
                  busy < 0,
                  curActive < 0,
                  frames < (frames + 1),
                  doneQ < 1,
                ],
              ),
              If(
                atTick & ~pfValid,
                then: [
                  curActive < 0,
                  If(curActive, then: [underrunQ < 1]),
                ],
              ),
              If(
                wrapping,
                then: [
                  loopLeft < (loopLeft - 1),
                  If(
                    consume,
                    then: [
                      If(
                        fetching,
                        then: loadFetched(),
                        orElse: [pfValid < 0, fetchAddr < startNext],
                      ),
                    ],
                    orElse: [
                      pfValid < 1,
                      pfLevel < firstLevel,
                      pfDur < firstDur,
                      pfIdx < startQ,
                      fetchAddr < startNext,
                    ],
                  ),
                ],
                orElse: [
                  If(
                    fetching,
                    then: [
                      ...loadFetched(),
                      If(
                        firstPending,
                        then: [
                          firstPending < 0,
                          firstLevel < ramLevel,
                          firstDur < ramDur,
                        ],
                      ),
                    ],
                    orElse: [
                      If(consume, then: [pfValid < 0]),
                    ],
                  ),
                ],
              ),
            ],
          ),
          If(
            send & ~busy,
            then: [
              busy < 1,
              started < 0,
              curActive < 0,
              pfValid < 0,
              firstPending < 1,
              underrunQ < 0,
              curIdx < itemStart,
              startQ < itemStart,
              fetchAddr < itemStart.zeroExtend(aw + 1),
              loopLeft < loop,
            ],
          ),
        ],
      ),
    ]);
  }
}

// Balanced mux tree: entries[index].
Logic _pick(Logic index, List<Logic> entries) {
  if (entries.length == 1) return entries[0];
  final next = <Logic>[];
  for (var i = 0; i < entries.length; i += 2) {
    next.add(
      i + 1 < entries.length
          ? mux(index[0], entries[i + 1], entries[i])
          : entries[i],
    );
  }
  return _pick(index.getRange(1, index.width), next);
}

/// The pixel expander of one serial channel.
///
/// It turns pixel words into the items of a WS2812 frame. Each bit is a high
/// item and a low item, and the frame ends with the reset gap and an end
/// item. A reset gap longer than 15 bits is sent as more than one item. The
/// expander gives the next item in `level` and `dur` while `ready` is high,
/// and moves on when `advance` is high.
///
/// The expander asks for a pixel word with `px_req` and `px_addr`. The word
/// is taken in the clock in which `px_valid` is high. `px_grant` ends the
/// request. The next word is read while the low item of the last bit of the
/// pixel is sent.
class HarborLedPixelExpander extends Module {
  final int pixelAddrWidth;
  final int countWidth;

  Logic get level => output('level');
  Logic get dur => output('dur');
  Logic get ready => output('ready');
  Logic get pxReq => output('px_req');
  Logic get pxAddr => output('px_addr');

  /// The index of the pixel that is sent.
  Logic get index => output('index');

  HarborLedPixelExpander({
    required Logic clk,
    required Logic reset,
    required Logic start,
    required Logic busy,
    required Logic advance,
    required Logic bpp,
    required Logic order,
    required List<Logic> timing,
    required Logic resetGap,
    required Logic count,
    required Logic pxData,
    required Logic pxGrant,
    required Logic pxValid,
    required int maxPixels,
    required this.pixelAddrWidth,
    super.name = 'led_pixel_expander',
  }) : countWidth = count.width,
       super(
         definitionName:
             'HarborLedPixelExpander_p${maxPixels}_a$pixelAddrWidth',
         reserveDefinitionName: true,
       ) {
    final cw = countWidth;
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    start = addInput('start', start);
    busy = addInput('busy', busy);
    advance = addInput('advance', advance);
    bpp = addInput('bpp', bpp);
    order = addInput('order', order, width: 3);
    timing = [
      for (var k = 0; k < 4; k++) addInput('t$k', timing[k], width: 15),
    ];
    resetGap = addInput('reset_gap', resetGap, width: 20);
    count = addInput('count', count, width: cw);
    pxData = addInput('px_data', pxData, width: 32);
    pxGrant = addInput('px_grant', pxGrant);
    pxValid = addInput('px_valid', pxValid);
    addOutput('level');
    addOutput('dur', width: 15);
    addOutput('ready');
    addOutput('px_req');
    addOutput('px_addr', width: pixelAddrWidth);
    addOutput('index', width: cw);

    const phH = 0, phL = 1, phReset = 2, phEnd = 3;
    final active = Logic(name: 'active');
    final wordValid = Logic(name: 'word_valid');
    final reqQ = Logic(name: 'req_q');
    final tail = Logic(name: 'tail');
    final curBit = Logic(name: 'cur_bit');
    final pidx = Logic(name: 'pidx', width: cw);
    final cntQ = Logic(name: 'cnt_q', width: cw);
    final kbyte = Logic(name: 'kbyte', width: 2);
    final bidx = Logic(name: 'bidx', width: 3);
    final phase = Logic(name: 'phase', width: 2);
    final word = Logic(name: 'word', width: 32);
    final rstLeft = Logic(name: 'rst_left', width: 20);

    // Byte of the pixel word that goes out as byte number kbyte. The word
    // is 0xWWRRGGBB, so B is byte 0, G is 1, R is 2 and W is 3.
    const table = [
      [1, 2, 0],
      [2, 1, 0],
      [0, 2, 1],
      [2, 0, 1],
      [1, 0, 2],
      [0, 1, 2],
    ];
    final srcByte = Logic(name: 'src_byte', width: 2);
    Combinational([
      Case(
        [order, kbyte].concat(),
        [
          for (var o = 0; o < 6; o++)
            for (var k = 0; k < 3; k++)
              CaseItem(Const(o * 4 + k, width: 5), [
                srcByte < Const(table[o][k], width: 2),
              ]),
        ],
        defaultItem: [srcByte < Const(3, width: 2)],
      ),
    ]);

    final selBit = _pick([srcByte, bidx].concat(), [
      for (var i = 0; i < 32; i++) word[i],
    ]);

    final lastByte = [Const(1), bpp].concat();
    final nextPidx = pidx + 1;
    final inH = phase.eq(phH);
    final inL = phase.eq(phL);
    final inReset = phase.eq(phReset);
    final bigReset = rstLeft.getRange(15, 20).neq(0);
    final chunk = mux(
      bigReset,
      Const(0x7FFF, width: 15),
      rstLeft.getRange(0, 15),
    );
    final restAfter = mux(
      bigReset,
      rstLeft - Const(0x7FFF, width: 20),
      Const(0, width: 20),
    );

    output('ready') <= active & (~inH | wordValid);
    output('level') <= inH;
    output('px_req') <= reqQ;
    output('px_addr') <= pidx.getRange(0, pixelAddrWidth);
    output('index') <= pidx;
    output('dur') <=
        mux(
          inH,
          mux(selBit, timing[2], timing[0]),
          mux(
            inL,
            mux(curBit, timing[3], timing[1]),
            mux(inReset, chunk, Const(0, width: 15)),
          ),
        );

    final step = advance & active & (~inH | wordValid);
    final lastBit = kbyte.eq(lastByte) & bidx.eq(0);
    final clamped = mux(
      count.gt(Const(maxPixels, width: cw)),
      Const(maxPixels, width: cw),
      count,
    );

    Sequential(clk, [
      If(
        reset,
        then: [
          active < 0,
          wordValid < 0,
          reqQ < 0,
          tail < 0,
          curBit < 0,
          pidx < Const(0, width: cw),
          cntQ < Const(0, width: cw),
          kbyte < Const(0, width: 2),
          bidx < Const(7, width: 3),
          phase < Const(phEnd, width: 2),
          word < Const(0, width: 32),
          rstLeft < Const(0, width: 20),
        ],
        orElse: [
          If(pxGrant, then: [reqQ < 0]),
          If(pxValid, then: [word < pxData, wordValid < 1]),
          If(
            step,
            then: [
              Case(phase, [
                CaseItem(Const(phH, width: 2), [
                  curBit < selBit,
                  phase < Const(phL, width: 2),
                  If(
                    lastBit,
                    then: [
                      If(
                        nextPidx.neq(cntQ),
                        then: [
                          pidx < nextPidx,
                          reqQ < 1,
                          wordValid < 0,
                          tail < 0,
                        ],
                        orElse: [tail < 1],
                      ),
                    ],
                  ),
                ]),
                CaseItem(Const(phL, width: 2), [
                  If(
                    bidx.eq(0),
                    then: [
                      bidx < Const(7, width: 3),
                      If(
                        kbyte.eq(lastByte),
                        then: [
                          kbyte < Const(0, width: 2),
                          phase < [tail, Const(0)].concat(),
                        ],
                        orElse: [
                          kbyte < (kbyte + 1),
                          phase < Const(phH, width: 2),
                        ],
                      ),
                    ],
                    orElse: [bidx < (bidx - 1), phase < Const(phH, width: 2)],
                  ),
                ]),
                CaseItem(Const(phReset, width: 2), [
                  rstLeft < restAfter,
                  If(restAfter.eq(0), then: [phase < Const(phEnd, width: 2)]),
                ]),
              ]),
            ],
          ),
          If(~busy, then: [active < 0, reqQ < 0]),
          If(
            start,
            then: [
              active < 1,
              cntQ < clamped,
              rstLeft < resetGap,
              kbyte < Const(0, width: 2),
              bidx < Const(7, width: 3),
              pidx < Const(0, width: cw),
              tail < 0,
              wordValid < 0,
              reqQ < clamped.neq(0),
              phase < [clamped.eq(0), Const(0)].concat(),
            ],
          ),
        ],
      ),
    ]);
  }
}

/// The PWM bank of one channel.
///
/// Each pin has an 8-bit duty register and a compare against the shared
/// `counter`. A pin is high while the counter is below its duty, so a duty
/// of d gives d ticks high in the 256 ticks of the counter.
///
/// `start` loads the duties. The bank asks for the pixel of one pin in each
/// clock with `px_req` and `px_addr`. The word is taken in the clock in which
/// `px_valid` is high, which is the clock of `px_grant` for a RAM with an
/// asynchronous read and the next one when `registeredRead` is set.
/// `done` is high for one clock when the last duty is loaded.
class HarborLedPwmBank extends Module {
  final List<HarborLedPin> pwmPins;
  final int pixelAddrWidth;

  /// One bit per pin, in the order of the pin map.
  Logic get pins => output('pins');
  Logic get busy => output('busy');
  Logic get done => output('done');

  /// Completed frames, 8 bits.
  Logic get frameCount => output('frame_count');
  Logic get pxReq => output('px_req');
  Logic get pxAddr => output('px_addr');

  HarborLedPwmBank({
    required Logic clk,
    required Logic reset,
    required Logic start,
    required Logic polarity,
    required Logic counter,
    required Logic pxData,
    required Logic pxGrant,
    required Logic pxValid,
    required this.pwmPins,
    required this.pixelAddrWidth,
    required bool registeredRead,
    required bool activeLow,
    super.name = 'led_pwm_bank',
  }) : super(
         definitionName: harborStableDefinitionName('HarborLedPwmBank', [
           for (final p in pwmPins) '${p.pixel}${p.byte.name}',
           'a$pixelAddrWidth',
           registeredRead ? 'q' : 'c',
           activeLow ? 'l' : 'h',
         ]),
         reserveDefinitionName: true,
       ) {
    final p = pwmPins.length;
    final iw = p > 1 ? (p - 1).bitLength : 1;
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    start = addInput('start', start);
    polarity = addInput('polarity', polarity);
    counter = addInput('counter', counter, width: 8);
    pxData = addInput('px_data', pxData, width: 32);
    pxGrant = addInput('px_grant', pxGrant);
    pxValid = addInput('px_valid', pxValid);
    addOutput('pins', width: p);
    addOutput('busy');
    addOutput('done');
    addOutput('frame_count', width: 8);
    addOutput('px_req');
    addOutput('px_addr', width: pixelAddrWidth);

    final busyQ = Logic(name: 'busy_q');
    final reqActive = Logic(name: 'req_active');
    final reqIdx = Logic(name: 'req_idx', width: iw);
    final grantIdx = Logic(name: 'grant_idx', width: iw);
    final doneQ = Logic(name: 'done_q');
    final frames = Logic(name: 'frames', width: 8);
    final duty = [for (var i = 0; i < p; i++) Logic(name: 'duty$i', width: 8)];
    final pinQ = [for (var i = 0; i < p; i++) Logic(name: 'pin_q$i')];

    // The byte lanes of the pixel word 0xWWRRGGBB.
    int lane(HarborLedByte b) => switch (b) {
      HarborLedByte.b => 0,
      HarborLedByte.g => 1,
      HarborLedByte.r => 2,
      HarborLedByte.w => 3,
    };

    final target = registeredRead ? grantIdx : reqIdx;
    output('pins') <= (p == 1 ? pinQ[0] : pinQ.rconcat());
    output('busy') <= busyQ;
    output('done') <= doneQ;
    output('frame_count') <= frames;
    output('px_req') <= reqActive;
    output('px_addr') <=
        _pick(reqIdx, [
          for (final pin in pwmPins) Const(pin.pixel, width: pixelAddrWidth),
        ]);

    Sequential(clk, [
      If(
        reset,
        then: [
          busyQ < 0,
          reqActive < 0,
          reqIdx < Const(0, width: iw),
          grantIdx < Const(0, width: iw),
          doneQ < 0,
          frames < Const(0, width: 8),
          for (var i = 0; i < p; i++) ...[
            duty[i] < Const(0, width: 8),
            pinQ[i] < Const(activeLow ? 1 : 0),
          ],
        ],
        orElse: [
          doneQ < 0,
          for (var i = 0; i < p; i++) ...[
            pinQ[i] < (counter.lt(duty[i]) ^ polarity),
            If(
              pxValid & target.eq(Const(i, width: iw)),
              then: [
                duty[i] <
                    pxData.getRange(
                      8 * lane(pwmPins[i].byte),
                      8 * lane(pwmPins[i].byte) + 8,
                    ),
              ],
            ),
          ],
          If(
            pxGrant,
            then: [
              grantIdx < reqIdx,
              If(
                reqIdx.eq(Const(p - 1, width: iw)),
                then: [reqActive < 0],
                orElse: [reqIdx < (reqIdx + 1)],
              ),
            ],
          ),
          If(
            pxValid & target.eq(Const(p - 1, width: iw)),
            then: [busyQ < 0, doneQ < 1, frames < (frames + 1)],
          ),
          If(
            start,
            then: [
              busyQ < 1,
              reqActive < 1,
              reqIdx < Const(0, width: iw),
            ],
          ),
        ],
      ),
    ]);
  }
}
