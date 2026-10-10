/// The request and data seam between an sdram port front end and the
/// sdram engine, and the round robin arbiter in front of the engine.
library;

import 'package:rohd/rohd.dart';

/// One sdram port. The consumer is the port front end, the provider is the
/// engine (or an arbiter in front of it).
///
/// A request asks for `req_words` 16-bit words from `req_addr`, no page
/// cross, taken on a cycle where `req_ready` and `req_valid` are both
/// high. Requests from one port run in order; there is no order between
/// ports. Write data follows on `wr_*`, taken on a `wr_ready` pulse. Reads
/// come back on `rd_*` with no back pressure, so a client reserves space
/// for the data before it sends the request.
///
/// [wrLookahead], used only between [SdramArbiter] and the engine, adds
/// `wr_next_*` so the write side never needs a same-cycle turnaround: the
/// consumer shows the next word on `wr_*` and the word after it on
/// `wr_next_*`, and reads `wr_next_*` for one cycle right after taking a
/// word, while the client catches up.
/// `wr_valid_d` and `wr_next_valid_d` are the values `wr_valid` and
/// `wr_next_valid` take after this edge, so the engine can keep its own
/// registered copy. `wr_next2_valid_d` is high when a third word waits
/// behind `wr_next_*` after this edge.
class SdramPortInterface extends PairInterface {
  /// Word address width.
  final int addrWidth;

  /// Width of the `req_words` count.
  final int wordsWidth;

  /// Width of the port id tags, or 0 for no tags.
  final int portIdWidth;

  /// Adds `wr_next_*` and moves `wr_ready` one cycle late, as described
  /// above.
  final bool wrLookahead;

  Logic get wrNextValid => port('wr_next_valid');
  Logic get wrValidD => port('wr_valid_d');
  Logic get wrNextValidD => port('wr_next_valid_d');
  Logic get wrNext2ValidD => port('wr_next2_valid_d');
  Logic get wrNextData => port('wr_next_data');
  Logic get wrNextMask => port('wr_next_mask');

  Logic get reqValid => port('req_valid');
  Logic get reqWrite => port('req_write');
  Logic get reqAddr => port('req_addr');
  Logic get reqWords => port('req_words');
  Logic get reqPort => port('req_port');
  Logic get wrValid => port('wr_valid');
  Logic get wrData => port('wr_data');

  /// Byte enables for [wrData], 1 = write the byte.
  Logic get wrMask => port('wr_mask');

  Logic get reqReady => port('req_ready');
  Logic get wrReady => port('wr_ready');
  Logic get wrPort => port('wr_port');
  Logic get rdValid => port('rd_valid');
  Logic get rdData => port('rd_data');

  /// High on the last word of a read request.
  Logic get rdLast => port('rd_last');
  Logic get rdPort => port('rd_port');

  SdramPortInterface({
    this.addrWidth = 24,
    this.wordsWidth = 4,
    this.portIdWidth = 0,
    this.wrLookahead = false,
  }) : super(
         portsFromConsumer: [
           Logic.port('req_valid'),
           Logic.port('req_write'),
           Logic.port('req_addr', addrWidth),
           Logic.port('req_words', wordsWidth),
           Logic.port('wr_valid'),
           Logic.port('wr_data', 16),
           Logic.port('wr_mask', 2),
           if (portIdWidth > 0) Logic.port('req_port', portIdWidth),
           if (wrLookahead) ...[
             Logic.port('wr_next_valid'),
             Logic.port('wr_valid_d'),
             Logic.port('wr_next_valid_d'),
             Logic.port('wr_next2_valid_d'),
             Logic.port('wr_next_data', 16),
             Logic.port('wr_next_mask', 2),
           ],
         ],
         portsFromProvider: [
           Logic.port('req_ready'),
           Logic.port('wr_ready'),
           Logic.port('rd_valid'),
           Logic.port('rd_data', 16),
           Logic.port('rd_last'),
           if (portIdWidth > 0) ...[
             Logic.port('wr_port', portIdWidth),
             Logic.port('rd_port', portIdWidth),
           ],
         ],
       );

  @override
  SdramPortInterface clone() => SdramPortInterface(
    addrWidth: addrWidth,
    wordsWidth: wordsWidth,
    portIdWidth: portIdWidth,
    wrLookahead: wrLookahead,
  );
}

/// One arbiter port: its name, used as the prefix of its signal names, and
/// its largest request. [SdramArbiter] stops the simulation if the port
/// sends a larger request.
class HarborSdramPortConfig {
  /// Name used in logic and signal names for this port.
  final String name;

  /// Largest request this port may send, in words.
  final int maxGrantWords;

  const HarborSdramPortConfig({required this.name, this.maxGrantWords = 8});
}

/// Smallest bit width that indexes `0 .. n - 1`.
int _arbiterIndexWidth(int n) => n <= 1 ? 1 : (n - 1).bitLength;

/// Round robin arbiter in front of [SdramEngine]. [ports] is the list of
/// client ports, [engine] is the single port the engine sees.
///
/// Every signal the arbiter drives into [engine] comes straight from a
/// register: the winning request is latched into a one-entry request
/// register, and write words go through a 4-word buffer that is filled
/// in the order the engine accepted the write requests. The engine's
/// `req_ready`, `rd_valid`, `rd_data`, `rd_last` and `rd_port` outputs
/// are only muxed and demuxed toward the clients.
///
/// `abort` is the bus side reset. It drops a held read request only. Taken
/// writes stay in the request register, the write queue and the buffer,
/// and still drain to the engine.
class SdramArbiter extends Module {
  SdramArbiter({
    required Logic clk,
    required Logic reset,
    Logic? abort,
    required List<SdramPortInterface> ports,
    required List<HarborSdramPortConfig> configs,
    required SdramPortInterface engine,
    super.name = 'sdram_arbiter',
  }) {
    final n = ports.length;
    if (n < 1) {
      throw ArgumentError('SdramArbiter needs at least one port');
    }
    if (configs.length != n) {
      throw ArgumentError('SdramArbiter needs one config per port');
    }
    if (configs.map((c) => c.name).toSet().length != n) {
      throw ArgumentError('SdramArbiter port names must be unique');
    }
    for (var i = 0; i < n; i++) {
      final m = configs[i].maxGrantWords;
      if (m < 1 || m >= (1 << ports[i].wordsWidth)) {
        throw ArgumentError(
          'port ${configs[i].name}: maxGrantWords $m does not fit req_words',
        );
      }
    }
    if (engine.portIdWidth < 1) {
      throw ArgumentError('the engine port needs portIdWidth >= 1');
    }
    if (!engine.wrLookahead) {
      throw ArgumentError('the engine port needs wrLookahead');
    }
    final idxWidth = _arbiterIndexWidth(n);
    if (engine.portIdWidth < idxWidth) {
      throw ArgumentError(
        'engine.portIdWidth must be at least $idxWidth for $n ports',
      );
    }

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    abort = addInput('abort', abort ?? Const(0));

    final clients = [
      for (var i = 0; i < n; i++)
        ports[i].clone()..pairConnectIO(
          this,
          ports[i],
          PairRole.provider,
          uniquify: (name) => '${configs[i].name}_$name',
        ),
    ];
    final eng = engine.clone()..pairConnectIO(this, engine, PairRole.consumer);

    final addrW = eng.addrWidth;
    final wordsW = eng.wordsWidth;
    final portW = eng.portIdWidth;

    // --- request arbitration: priority search starting at grant, one
    // mux chain per possible grant value, so grant itself never needs
    // hardware modulo math ---
    final grant = Logic(name: 'grant', width: idxWidth);

    Logic selFor(int g) {
      Logic v = Const(0, width: idxWidth);
      for (var k = n - 1; k >= 0; k--) {
        final idx = (g + k) % n;
        v = mux(clients[idx].reqValid, Const(idx, width: idxWidth), v);
      }
      return v;
    }

    Logic selValidFor(int g) {
      Logic v = Const(0);
      for (var k = n - 1; k >= 0; k--) {
        final idx = (g + k) % n;
        v = mux(clients[idx].reqValid, Const(1), v);
      }
      return v;
    }

    final sel = cases(
      grant,
      {for (var g = 0; g < n; g++) Const(g, width: idxWidth): selFor(g)},
      width: idxWidth,
      defaultValue: Const(0, width: idxWidth),
      conditionalType: ConditionalType.unique,
    ).named('sel');
    final selValid = cases(
      grant,
      {for (var g = 0; g < n; g++) Const(g, width: idxWidth): selValidFor(g)},
      defaultValue: Const(0),
      conditionalType: ConditionalType.unique,
    ).named('sel_valid');

    Logic pickBySel(List<Logic> vals) => cases(
      sel,
      {for (var i = 0; i < n; i++) Const(i, width: idxWidth): vals[i]},
      width: vals[0].width,
      defaultValue: vals[0],
      conditionalType: ConditionalType.unique,
    );

    final grantNext = cases(
      sel,
      {
        for (var i = 0; i < n; i++)
          Const(i, width: idxWidth): Const((i + 1) % n, width: idxWidth),
      },
      width: idxWidth,
      defaultValue: grant,
      conditionalType: ConditionalType.unique,
    );

    // --- one-entry request register, the only thing the engine's
    // req_* inputs ever connect to ---
    final heldValid = Logic(name: 'held_valid');
    final heldWrite = Logic(name: 'held_write');
    final heldAddr = Logic(name: 'held_addr', width: addrW);
    final heldWords = Logic(name: 'held_words', width: wordsW);
    final heldPort = Logic(name: 'held_port', width: portW);

    eng.reqValid <= heldValid;
    eng.reqWrite <= heldWrite;
    eng.reqAddr <= heldAddr;
    eng.reqWords <= heldWords;
    eng.reqPort <= heldPort;

    final canLoad = (~heldValid | eng.reqReady).named('can_load');
    final loadNow = (canLoad & selValid).named('load_now');

    for (var i = 0; i < n; i++) {
      clients[i].reqReady <= canLoad & selValid & sel.eq(i);
    }

    // --- write data ---
    // The engine takes write words in the order it accepted the write
    // requests. A queue of accepted writes (port, words left) says which
    // client the next word comes from. A client word is taken as soon as
    // it enters a 4-word shift buffer, so the client moves on at once. The
    // engine sees the first two buffer words straight from their
    // registers, and its registered wr_ready shifts the buffer one word,
    // as [SdramPortInterface.wrLookahead] describes.
    final wqValid = [for (var i = 0; i < 2; i++) Logic(name: 'wq_valid_$i')];
    final wqPort = [
      for (var i = 0; i < 2; i++) Logic(name: 'wq_port_$i', width: idxWidth),
    ];
    final wqLeft = [
      for (var i = 0; i < 2; i++) Logic(name: 'wq_left_$i', width: wordsW),
    ];
    const depth = 4;
    final slot = [
      for (var i = 0; i < depth; i++) Logic(name: 'wr_slot_$i', width: 18),
    ];
    // One-hot fill level, 0 to depth words.
    final fill = [for (var i = 0; i <= depth; i++) Logic(name: 'wr_fill_$i')];
    final notFull = Logic(name: 'wr_not_full');
    final out0Valid = Logic(name: 'wr_out0_valid');
    final out1Valid = Logic(name: 'wr_out1_valid');

    eng.wrValid <= out0Valid;
    eng.wrData <= slot[0].getRange(0, 16);
    eng.wrMask <= slot[0].getRange(16, 18);
    eng.wrNextValid <= out1Valid;
    eng.wrNextData <= slot[1].getRange(0, 16);
    eng.wrNextMask <= slot[1].getRange(16, 18);

    Logic pickByHead(List<Logic> vals) => [
      for (var i = 0; i < n; i++)
        vals[i] & wqPort[0].eq(i).replicate(vals[i].width),
    ].reduce((x, y) => x | y);
    final headValid = pickByHead([for (final c in clients) c.wrValid]);
    final headWord = pickByHead([
      for (final c in clients) [c.wrMask, c.wrData].swizzle(),
    ]);

    final load = (wqValid[0] & notFull & headValid).named('wr_load');
    for (var i = 0; i < n; i++) {
      clients[i].wrReady <= load & wqPort[0].eq(i);
    }

    final pop = eng.wrReady;
    // A new word goes into the first free slot after this cycle's shift.
    final slotNext = <Logic>[];
    for (var i = 0; i < depth; i++) {
      final freeAfterPop = i + 1 <= depth ? fill[i + 1] : Const(0);
      final we = load & mux(pop, freeAfterPop, fill[i]);
      final shifted = i + 1 < depth ? slot[i + 1] : slot[i];
      slotNext.add(mux(we, headWord, mux(pop, shifted, slot[i])));
    }
    final fillNext = <Logic>[];
    final up = load & ~pop;
    final down = pop & ~load;
    for (var k = 0; k <= depth; k++) {
      final stay = fill[k] & ~up & ~down;
      final fromBelow = k > 0 ? fill[k - 1] & up : Const(0);
      final fromAbove = k < depth ? fill[k + 1] & down : Const(0);
      fillNext.add(stay | fromBelow | fromAbove);
    }

    // Queue of accepted writes: push when the engine takes a write
    // request, count down on each loaded word, pop at zero.
    final push = heldValid & eng.reqReady & heldWrite;
    final headDone = load & wqLeft[0].eq(1);
    final left0 = mux(load, wqLeft[0] - 1, wqLeft[0]);
    // After a pop, entry 1 moves to entry 0.
    final v0 = mux(headDone, wqValid[1], wqValid[0]);
    final p0 = mux(headDone, wqPort[1], wqPort[0]);
    final l0 = mux(headDone, wqLeft[1], left0);
    final v1 = mux(headDone, Const(0), wqValid[1]);
    _checkQueue(clk, push & v1);
    final pushInto0 = push & ~v0;
    final pushInto1 = push & v0;
    final wqValidNext = [v0 | pushInto0, v1 | pushInto1];
    final heldIdx = heldPort.getRange(0, idxWidth);
    final wqPortNext = [
      mux(pushInto0, heldIdx, p0),
      mux(pushInto1, heldIdx, wqPort[1]),
    ];
    final wqLeftNext = [
      mux(pushInto0, heldWords, l0),
      mux(pushInto1, heldWords, wqLeft[1]),
    ];

    // --- read and ready/accept fan-out, straight from engine outputs,
    // never registered again on the way back out ---
    for (var i = 0; i < n; i++) {
      clients[i].rdValid <= eng.rdValid & eng.rdPort.eq(i);
      clients[i].rdData <= eng.rdData;
      clients[i].rdLast <= eng.rdLast;
      // A client only ever sees its own traffic, so its own wr_port and
      // rd_port (when it has them) are always its own index.
      if (ports[i].portIdWidth > 0) {
        clients[i].wrPort <= Const(i, width: ports[i].portIdWidth);
        clients[i].rdPort <= Const(i, width: ports[i].portIdWidth);
      }
    }

    final heldWriteNext = mux(
      loadNow,
      pickBySel([for (final c in clients) c.reqWrite]),
      heldWrite,
    );
    final out0ValidD = ~fillNext[0];
    final out1ValidD = ~fillNext[0] & ~fillNext[1];
    eng.wrValidD <= mux(reset, Const(0), out0ValidD);
    eng.wrNextValidD <= mux(reset, Const(0), out1ValidD);
    eng.wrNext2ValidD <=
        mux(reset, Const(0), ~fillNext[0] & ~fillNext[1] & ~fillNext[2]);
    final regs = <(Logic, Logic, int)>[
      (grant, mux(loadNow, grantNext, grant), 0),
      (
        heldValid,
        mux(canLoad, selValid, heldValid) & ~(abort & ~heldWriteNext),
        0,
      ),
      (heldWrite, heldWriteNext, 0),
      (
        heldAddr,
        mux(loadNow, pickBySel([for (final c in clients) c.reqAddr]), heldAddr),
        0,
      ),
      (
        heldWords,
        mux(
          loadNow,
          pickBySel([for (final c in clients) c.reqWords]),
          heldWords,
        ),
        0,
      ),
      (heldPort, mux(loadNow, sel.zeroExtend(portW), heldPort), 0),
      (out0Valid, out0ValidD, 0),
      (out1Valid, out1ValidD, 0),
      (notFull, ~fillNext[depth], 1),
      for (var i = 0; i < depth; i++) (slot[i], slotNext[i], 0),
      for (var k = 0; k <= depth; k++) (fill[k], fillNext[k], k == 0 ? 1 : 0),
      for (var i = 0; i < 2; i++) ...[
        (wqValid[i], wqValidNext[i], 0),
        (wqPort[i], wqPortNext[i], 0),
        (wqLeft[i], wqLeftNext[i], 0),
      ],
    ];

    for (var i = 0; i < n; i++) {
      _checkRequestSize(
        clk,
        clients[i].reqValid & clients[i].reqReady,
        clients[i].reqWords,
        configs[i],
      );
    }

    Sequential(clk, [
      If(
        reset,
        then: [for (final r in regs) r.$1 < Const(r.$3, width: r.$1.width)],
        orElse: [for (final r in regs) r.$1 < r.$2],
      ),
    ]);
  }

  /// Stops the simulation when [port] sends a request larger than its
  /// [HarborSdramPortConfig.maxGrantWords]. The hardware does not check
  /// this.
  void _checkRequestSize(
    Logic clk,
    Logic accept,
    Logic words,
    HarborSdramPortConfig port,
  ) {
    clk.glitch.listen((args) {
      // A fresh clk net reads z before anything drives it, which a plain
      // module never shows a listener but a BridgeModule's two-step port
      // wiring can, so an invalid edge here is not a real one.
      if (!LogicValue.isPosedge(
            args.previousValue,
            args.newValue,
            ignoreInvalid: true,
          ) ||
          accept.value != LogicValue.one ||
          !words.value.isValid) {
        return;
      }
      final w = words.value.toInt();
      if (w > port.maxGrantWords) {
        Simulator.throwException(
          Exception(
            'sdram port ${port.name} sent $w words, more than its '
            'maxGrantWords ${port.maxGrantWords}',
          ),
          StackTrace.current,
        );
      }
    });
  }

  /// Stops the simulation if a write request is pushed while the write
  /// queue is full. The engine holds at most 2 requests, so this must not
  /// happen.
  void _checkQueue(Logic clk, Logic overflow) {
    clk.glitch.listen((args) {
      if (LogicValue.isPosedge(
            args.previousValue,
            args.newValue,
            ignoreInvalid: true,
          ) &&
          overflow.value == LogicValue.one) {
        Simulator.throwException(
          Exception('sdram arbiter write queue pushed while full'),
          StackTrace.current,
        );
      }
    });
  }
}
