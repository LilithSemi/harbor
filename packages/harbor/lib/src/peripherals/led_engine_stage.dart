import 'package:rohd/rohd.dart';

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
class HarborLedSerialChannel extends Module {
  final int addrWidth;

  Logic get pin => output('pin');
  Logic get busy => output('busy');

  /// One clock high when a train ends.
  Logic get done => output('done');

  /// High from a missed item until the next SEND.
  Logic get underrun => output('underrun');
  Logic get ramReq => output('ram_req');
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
    addOutput('pin');
    addOutput('busy');
    addOutput('done');
    addOutput('underrun');
    addOutput('ram_req');
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
    final overrun = fetchAddrEff[aw];
    final ramLevel = mux(overrun, Const(0), ramData[15]);
    final ramDur = mux(overrun, Const(0, width: 15), ramData.getRange(0, 15));

    output('pin') <= pinQ;
    output('busy') <= busy;
    output('done') <= doneQ;
    output('underrun') <= underrunQ;
    output('ram_req') <= fetchReq;
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
