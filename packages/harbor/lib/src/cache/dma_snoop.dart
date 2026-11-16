import 'package:rohd/rohd.dart';

import '../bus/axi4/axi4_interface.dart';
import '../bus/tilelink/tilelink_interface.dart';
import '../bus/wishbone/wishbone_interface.dart';
import 'l1_cache.dart';

/// A FIFO of flops. [push] and [pop] act on the rising edge. A push when the
/// FIFO is full is not taken, also when it pops in that cycle, so `~full` is
/// the ready of the push.
class _FlopFifo {
  final Logic empty;
  final Logic full;
  final Logic head;

  _FlopFifo._(this.empty, this.full, this.head);

  factory _FlopFifo(
    Logic clk,
    Logic reset, {
    required Logic push,
    required Logic data,
    required Logic pop,
    required int depth,
    required String name,
  }) {
    final ptrW = depth <= 1 ? 1 : (depth - 1).bitLength;
    final cntW = depth.bitLength;
    final cells = [
      for (var i = 0; i < depth; i++)
        Logic(name: '${name}_cell$i', width: data.width),
    ];
    final rd = Logic(name: '${name}_rd', width: ptrW);
    final wr = Logic(name: '${name}_wr', width: ptrW);
    final count = Logic(name: '${name}_count', width: cntW);
    final empty = count.eq(0).named('${name}_empty');
    final full = count.eq(depth).named('${name}_full');
    final doPop = (pop & ~empty).named('${name}_pop');
    final doPush = (push & ~full).named('${name}_push');
    Logic next(Logic p) => (depth & (depth - 1)) == 0
        ? p + 1
        : mux(p.eq(depth - 1), Const(0, width: ptrW), p + 1);
    var head = cells.first;
    for (var i = 1; i < depth; i++) {
      head = mux(rd.eq(i), cells[i], head);
    }
    Sequential(clk, [
      If(
        reset,
        then: [rd < 0, wr < 0, count < 0],
        orElse: [
          If(doPop, then: [rd < next(rd)]),
          If(
            doPush,
            then: [
              wr < next(wr),
              for (var i = 0; i < depth; i++)
                If(wr.eq(i), then: [cells[i] < data]),
            ],
          ),
          count < count + doPush.zeroExtend(cntW) - doPop.zeroExtend(cntW),
        ],
      ),
    ]);
    return _FlopFifo._(empty, full, head.named('${name}_head'));
  }
}

/// The signal at the start of the connection chain of [l].
Logic _root(Logic l) {
  var s = l;
  while (s.srcConnection != null) {
    s = s.srcConnection!;
  }
  return s;
}

/// Throws when [clk] and the clock of [cache] do not come from one signal.
void _checkClock(Logic clk, HarborL1DCache cache, String who) {
  final cacheClk = cache.input('clk').srcConnection;
  if (cacheClk == null || !identical(_root(cacheClk), _root(clk))) {
    throw ArgumentError(
      '$who must run on the clock of ${cache.name}: connect the cache clock '
      'first. The snoop path has no clock domain crossing.',
    );
  }
}

/// Inline stage on the bus of a DMA master that keeps an L1 data cache
/// coherent with the writes of that master. Connect the master to `m_*` and
/// the fabric to `s_*`. Every signal passes through, except the handshakes
/// below.
///
/// - Each write gives one invalidate for each line it writes, on
///   `inval_valid` and `inval_addr`, at most one line per cycle. A line goes
///   out when `inval_ready` is high.
/// - The completion of a write goes to the master only when every invalidate
///   of the tap has gone out and `inval_quiet` is high, so the cache has
///   dropped the lines. The completion is the AXI4 B response, the Wishbone
///   acknowledge of the last beat, or the TileLink AccessAck. The stage holds
///   it until then. A load that the CPU starts after it sees the completion
///   (an interrupt or a status read) cannot hit the old line.
/// - `inval_hold` is high while `fill_line` is in the line range of the
///   writes that are in flight. A refill of that line in flight then does
///   not make its line valid, because its read can come before the write in
///   memory. The range is the smallest range that holds all the writes since
///   the tap was last idle (a min and max union). A refill between two
///   written lines is killed too. That costs only speed, because the killed
///   refill still answers its load.
/// - When the queue of invalidates is full, the stage stops new writes: it
///   holds AWREADY low (AXI4), holds STB to the fabric low (Wishbone) or
///   holds A_READY low for a Put (TileLink). No invalidate is lost.
///
/// Assumptions:
///
/// - The bus is in the clock domain of the cache. There is no clock domain
///   crossing. [connectCache] checks this.
/// - Harbor's Wishbone memory slave posts the write beats before the last one
///   and acknowledges the last beat only after its write response, so all
///   beats of the burst are in memory then. The stage holds that last
///   acknowledge until the lines are dropped.
/// - TileLink Arithmetic and Logical data are not watched. The Harbor slave
///   denies them.
///
/// For more than one DMA master, put each tap into a [HarborDmaSnoopMerge].
class HarborDmaSnoop extends Module {
  /// Line size of the cache in bytes.
  final int lineSize;

  /// Bytes of one bus beat.
  final int beatBytes;

  final Logic _clk;

  /// Drive high when the next stage can take a line this cycle.
  final Logic invalReadyIn = Logic(name: 'inval_ready_src');

  /// Drive high when no line of this tap waits after the tap and the cache
  /// is not busy with an invalidate.
  final Logic invalQuietIn = Logic(name: 'inval_quiet_src');

  /// Drive with the line the cache refills (`fill_line`).
  late final Logic fillLineIn;

  Logic get invalValid => output('inval_valid');
  Logic get invalAddr => output('inval_addr');
  Logic get invalHold => output('inval_hold');

  late final Logic _ready;
  late final Logic _quiet;
  late final Logic _fillLine;
  late final int _lineBits = lineSize.bitLength - 1;

  void _checkLine() {
    if (lineSize < beatBytes || lineSize & (lineSize - 1) != 0) {
      throw ArgumentError(
        'lineSize ($lineSize) must be a power of two of at least one bus '
        'beat ($beatBytes bytes).',
      );
    }
  }

  Logic _lineOf(Logic a) => a & ~Const(lineSize - 1, width: a.width);

  void _common(Logic clk, Logic reset, int addrWidth) {
    fillLineIn = Logic(name: 'fill_line_src', width: addrWidth);
    _ready = addInput('inval_ready', invalReadyIn);
    _quiet = addInput('inval_quiet', invalQuietIn);
    _fillLine = addInput('fill_line', fillLineIn, width: addrWidth);
  }

  /// Keeps the line range of the writes in flight and drives `inval_hold`.
  /// A write that covers lines [lo] to [hi] is added when [add] is high. The
  /// range is dropped when [busy] is low.
  void _range(
    Logic clk,
    Logic reset, {
    required Logic add,
    required Logic lo,
    required Logic hi,
    required Logic busy,
  }) {
    final w = lo.width;
    final valid = Logic(name: 'rangeValid');
    final rLo = Logic(name: 'rangeLo', width: w);
    final rHi = Logic(name: 'rangeHi', width: w);
    Sequential(clk, [
      If(
        reset,
        then: [valid < 0],
        orElse: [
          If(
            add,
            then: [
              valid < 1,
              rLo < mux(valid & rLo.lt(lo), rLo, lo),
              rHi < mux(valid & rHi.gt(hi), rHi, hi),
            ],
            orElse: [
              If(~busy, then: [valid < 0]),
            ],
          ),
        ],
      ),
    ]);
    final line = _lineOf(_fillLine);
    addOutput('inval_hold') <= valid & line.gte(rLo) & line.lte(rHi);
  }

  /// Connects this tap straight to [cache], with no merge.
  void connectCache(HarborL1DCache cache) {
    _checkClock(_clk, cache, name);
    if (!cache.snoop || cache.config.lineSize != lineSize) {
      throw ArgumentError(
        '${cache.name} needs snoop: true and lineSize $lineSize.',
      );
    }
    final aw = cache.invalAddr.width;
    cache.invalValid.srcConnection! <= invalValid;
    cache.invalAddr.srcConnection! <=
        (invalAddr.width >= aw
            ? invalAddr.getRange(0, aw)
            : invalAddr.zeroExtend(aw));
    cache.invalHold.srcConnection! <= invalHold;
    invalReadyIn <= Const(1);
    invalQuietIn <= ~cache.invalBusy;
    fillLineIn <= cache.fillLine.getRange(0, fillLineIn.width);
  }

  /// Inline stage on an AXI4 manager. Each accepted AW gives one invalidate
  /// for each line it covers, one line per cycle. [awDepth] accepted AWs can
  /// wait for their invalidates. When they are all waiting, AWREADY is low.
  HarborDmaSnoop.axi4(
    Logic clk,
    Logic reset, {
    required Axi4Interface master,
    required Axi4Interface slave,
    required this.lineSize,
    int awDepth = 4,
    super.name = 'dma_snoop',
  }) : beatBytes = master.dataWidth ~/ 8,
       _clk = clk,
       super(
         definitionName:
             'HarborDmaSnoopAxi4_a${master.addressWidth}_d${master.dataWidth}'
             '_i${master.idWidth}_l${lineSize}_q$awDepth',
       ) {
    _checkLine();
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    _common(clk, reset, master.addressWidth);
    final m = master.clone()
      ..pairConnectIO(this, master, PairRole.consumer, uniquify: (n) => 'm_$n');
    final s = slave.clone()
      ..pairConnectIO(this, slave, PairRole.provider, uniquify: (n) => 's_$n');
    const gated = {'AWVALID', 'AWREADY', 'BVALID', 'BREADY'};
    m.getPorts([PairDirection.fromProvider]).forEach((n, p) {
      if (!gated.contains(n)) s.port(n) <= p;
    });
    s.getPorts([PairDirection.fromConsumer]).forEach((n, p) {
      if (!gated.contains(n)) m.port(n) <= p;
    });
    final aW = master.addressWidth;

    final busy = Logic(name: 'busy');
    final cur = Logic(name: 'curLine', width: aW);
    final countW = 16 - _lineBits + 1;
    final left = Logic(name: 'linesLeft', width: countW);
    final pop = Logic(name: 'pop');
    final full = Logic(name: 'awFull');
    final release = Logic(name: 'release');

    s.port('AWVALID') <= m.port('AWVALID') & ~full;
    m.port('AWREADY') <= s.port('AWREADY') & ~full;
    // Once B is shown, it stays shown until BREADY (AXI4 A3.2.1), also when a
    // new AW makes the tap busy again. Its lines were dropped already.
    final bShown = Logic(name: 'bShown');
    final bOpen = (release | bShown).named('bOpen');
    m.port('BVALID') <= s.port('BVALID') & bOpen;
    s.port('BREADY') <= m.port('BREADY') & bOpen;
    final aw = (m.port('AWVALID') & s.port('AWREADY') & ~full).named('awTake');
    final b = (s.port('BVALID') & m.port('BREADY') & bOpen).named('bTake');
    Sequential(clk, [
      bShown < ~reset & s.port('BVALID') & bOpen & ~m.port('BREADY'),
    ]);

    final addr = m.port('AWADDR');
    final len = m.port('AWLEN');
    final size = m.port('AWSIZE');
    final burst = m.port('AWBURST');
    // Bytes of the burst: (len + 1) << size, at most 256 * 128.
    const bytesW = 16;
    final bytes = ((len.zeroExtend(bytesW) + 1) << size.zeroExtend(bytesW))
        .named('burstBytes');
    final bytesA = bytes.width >= aW
        ? bytes.getRange(0, aW)
        : bytes.zeroExtend(aW);
    final wrapBlock = burst.eq(2) & bytes.gte(lineSize);
    final first = mux(
      wrapBlock,
      addr & ~(bytesA - 1),
      _lineOf(addr),
    ).named('firstLine');
    final incrCount =
        ((_lineOf(addr + bytesA - 1) - _lineOf(addr)) >> _lineBits).getRange(
          0,
          countW,
        ) +
        1;
    final count = mux(
      burst.eq(1),
      incrCount,
      mux(
        wrapBlock,
        (bytes >> _lineBits).getRange(0, countW),
        Const(1, width: countW),
      ),
    ).named('lineCount');
    final lastLine = (first + (count.zeroExtend(aW) - 1 << _lineBits)).named(
      'lastLine',
    );

    final fifo = _FlopFifo(
      clk,
      reset,
      push: aw,
      data: [count, first].concat(),
      pop: pop,
      depth: awDepth,
      name: 'aw',
    );
    full <= fifo.full;
    final advance = (busy & _ready).named('advance');
    pop <= ~fifo.empty & (~busy | (advance & left.eq(1)));
    final outstanding = Logic(name: 'outstanding', width: 16);
    final idle = (fifo.empty & ~busy).named('idle');
    release <= idle & _quiet;
    Sequential(clk, [
      If(
        reset,
        then: [busy < 0, outstanding < 0],
        orElse: [
          outstanding < outstanding + aw.zeroExtend(16) - b.zeroExtend(16),
          If(
            pop,
            then: [
              busy < 1,
              cur < fifo.head.getRange(0, aW),
              left < fifo.head.getRange(aW),
            ],
            orElse: [
              If(
                advance,
                then: [
                  If(
                    left.eq(1),
                    then: [busy < 0],
                    orElse: [cur < cur + lineSize, left < left - 1],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);
    addOutput('inval_valid') <= busy;
    addOutput('inval_addr', width: aW) <= cur;
    _range(
      clk,
      reset,
      add: aw,
      lo: first,
      hi: lastLine,
      busy: outstanding.neq(0) | ~idle,
    );
  }

  /// Inline stage on a Wishbone master. Each acknowledged write beat gives
  /// one invalidate, except a beat in the same line as the beat before it in
  /// one cycle. The stage holds the acknowledge of the last beat (CTI 111,
  /// or each beat without CTI) until the lines are dropped.
  HarborDmaSnoop.wishbone(
    Logic clk,
    Logic reset, {
    required WishboneInterface master,
    required WishboneInterface slave,
    required this.lineSize,
    super.name = 'dma_snoop',
  }) : beatBytes = master.config.dataWidth ~/ 8,
       _clk = clk,
       super(
         definitionName:
             'HarborDmaSnoopWishbone_a${master.config.addressWidth}'
             '_d${master.config.dataWidth}_l$lineSize',
       ) {
    _checkLine();
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final aW = master.config.addressWidth;
    _common(clk, reset, aW);
    final m = master.clone()
      ..pairConnectIO(this, master, PairRole.consumer, uniquify: (n) => 'm_$n');
    final s = slave.clone()
      ..pairConnectIO(this, slave, PairRole.provider, uniquify: (n) => 's_$n');
    const gated = {'STB', 'ACK', 'ERR'};
    m.getPorts([PairDirection.fromProvider]).forEach((n, p) {
      if (!gated.contains(n)) s.port(n) <= p;
    });
    s.getPorts([PairDirection.fromConsumer]).forEach((n, p) {
      if (!gated.contains(n)) m.port(n) <= p;
    });
    final hasErr = master.err != null;
    final cyc = m.port('CYC');
    final write = (cyc & m.port('WE')).named('write');
    final cti = master.cti == null ? null : m.port('CTI');
    final last = cti == null ? Const(1) : cti.neq(2);
    final sAck = s.port('ACK');
    final sErr = hasErr ? s.port('ERR') : Const(0);
    final pend = Logic(name: 'pend');
    final ackQ = Logic(name: 'ackQ');
    final errQ = Logic(name: 'errQ');
    final valid = Logic(name: 'invalValid');
    final out = Logic(name: 'invalAddr', width: aW);
    final release = (pend & ~valid & _quiet).named('release');
    final stall = (write & valid & ~_ready).named('stall');
    final stb = (m.port('STB') & ~pend & ~stall).named('stbOut');
    s.port('STB') <= stb;
    final beat = (stb & write & (sAck | sErr)).named('beat');
    final holdLast = (beat & last).named('holdLast');
    m.port('ACK') <= mux(pend, release & ackQ, sAck & ~holdLast);
    if (hasErr) m.port('ERR') <= mux(pend, release & errQ, sErr & ~holdLast);

    final line = _lineOf(m.port('ADR'));
    final lastLine = Logic(name: 'lastLine', width: aW);
    final lastValid = Logic(name: 'lastValid');
    final pulse = (beat & (~lastValid | line.neq(lastLine))).named('pulse');
    Sequential(clk, [
      If(
        reset,
        then: [lastValid < 0, valid < 0, pend < 0],
        orElse: [
          If(
            pulse,
            then: [valid < 1, out < line, lastLine < line],
            orElse: [
              If(_ready, then: [valid < 0]),
            ],
          ),
          lastValid < cyc & (lastValid | beat),
          If(
            holdLast,
            then: [pend < 1, ackQ < sAck, errQ < sErr],
            orElse: [
              If(release, then: [pend < 0]),
            ],
          ),
        ],
      ),
    ]);
    addOutput('inval_valid') <= valid;
    addOutput('inval_addr', width: aW) <= out;
    _range(
      clk,
      reset,
      add: beat,
      lo: line,
      hi: line,
      busy: write | pend | valid,
    );
  }

  /// Inline stage on a TileLink master. Each accepted beat of a PutFullData
  /// or PutPartialData gives one invalidate when it starts a line. The stage
  /// holds the AccessAck until the lines are dropped.
  HarborDmaSnoop.tileLink(
    Logic clk,
    Logic reset, {
    required TileLinkInterface master,
    required TileLinkInterface slave,
    required this.lineSize,
    super.name = 'dma_snoop',
  }) : beatBytes = master.config.dataWidth ~/ 8,
       _clk = clk,
       super(
         definitionName:
             'HarborDmaSnoopTileLink_a${master.config.addressWidth}'
             '_d${master.config.dataWidth}_l$lineSize',
       ) {
    _checkLine();
    final cfg = master.config;
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final aW = cfg.addressWidth;
    _common(clk, reset, aW);
    final m = master.clone()
      ..pairConnectIO(this, master, PairRole.consumer, uniquify: (n) => 'm_$n');
    final s = slave.clone()
      ..pairConnectIO(this, slave, PairRole.provider, uniquify: (n) => 's_$n');
    const gated = {'A_VALID', 'A_READY', 'D_VALID', 'D_READY'};
    m.getPorts([PairDirection.fromProvider]).forEach((n, p) {
      if (!gated.contains(n)) s.port(n) <= p;
    });
    s.getPorts([PairDirection.fromConsumer]).forEach((n, p) {
      if (!gated.contains(n)) m.port(n) <= p;
    });
    final valid = Logic(name: 'invalValid');
    final out = Logic(name: 'invalAddr', width: aW);
    final isPut = m.port('A_OPCODE').lt(2);
    final stall = (isPut & valid & ~_ready).named('stall');
    s.port('A_VALID') <= m.port('A_VALID') & ~stall;
    m.port('A_READY') <= s.port('A_READY') & ~stall;
    final put = (m.port('A_VALID') & s.port('A_READY') & ~stall & isPut).named(
      'putBeat',
    );
    final release = (~valid & _quiet).named('release');
    final ack = s.port('D_OPCODE').eq(0);
    // Once an AccessAck is shown, it stays shown until D_READY.
    final dShown = Logic(name: 'dShown');
    final dOpen = (release | dShown).named('dOpen');
    m.port('D_VALID') <= s.port('D_VALID') & (~ack | dOpen);
    s.port('D_READY') <= m.port('D_READY') & (~ack | dOpen);
    final dAck = (s.port('D_VALID') & m.port('D_READY') & ack & dOpen).named(
      'dAck',
    );
    Sequential(clk, [
      dShown < ~reset & s.port('D_VALID') & ack & dOpen & ~m.port('D_READY'),
    ]);

    final beatLog = beatBytes.bitLength - 1;
    const beatW = 12;
    final size = m.port('A_SIZE');
    final address = m.port('A_ADDRESS');
    final beat = Logic(name: 'beat', width: beatW);
    final beats = mux(
      size.zeroExtend(beatW).gt(beatLog),
      Const(1, width: beatW) <<
          (size.zeroExtend(beatW) - Const(beatLog, width: beatW)),
      Const(1, width: beatW),
    ).named('beats');
    final beatAddr = (address + (beat.zeroExtend(aW) << beatLog)).named(
      'beatAddr',
    );
    final startsLine =
        beat.eq(0) | (beatAddr & Const(lineSize - 1, width: aW)).eq(0);
    final pulse = (put & startsLine).named('pulse');
    final outstanding = Logic(name: 'outstanding', width: 16);
    final firstBeat = put & beat.eq(0);
    Sequential(clk, [
      If(
        reset,
        then: [beat < 0, valid < 0, outstanding < 0],
        orElse: [
          If(
            pulse,
            then: [valid < 1, out < _lineOf(beatAddr)],
            orElse: [
              If(_ready, then: [valid < 0]),
            ],
          ),
          If(
            put,
            then: [
              beat < mux(beat.eq(beats - 1), Const(0, width: beatW), beat + 1),
            ],
          ),
          outstanding <
              outstanding + firstBeat.zeroExtend(16) - dAck.zeroExtend(16),
        ],
      ),
    ]);
    addOutput('inval_valid') <= valid;
    addOutput('inval_addr', width: aW) <= out;
    _range(
      clk,
      reset,
      add: put,
      lo: _lineOf(beatAddr),
      hi: _lineOf(beatAddr),
      busy: outstanding.neq(0) | put | valid,
    );
  }
}

/// Joins several [HarborDmaSnoop] taps for one cache. Each source has a
/// queue of [depth] lines, and the output takes one line per cycle in turn.
///
/// A tap gives at most `beatBytes / lineSize` lines per cycle. The sum of
/// that over the sources must be at most 1, so the output keeps up. A full
/// queue stops the writes of its tap, so no line is lost.
///
/// A completion waits until the cache is not busy with any invalidate, also
/// one from another source. So a busy master can hold back the completion of
/// another master while its write stream lasts. The outstanding write limit
/// of each master bounds that stream.
class HarborDmaSnoopMerge extends Module {
  final List<HarborDmaSnoop> sources;

  /// Drive high when the cache is busy with an invalidate (`inval_busy`).
  final Logic cacheBusyIn = Logic(name: 'cache_busy_src');

  Logic get invalValid => output('inval_valid');
  Logic get invalAddr => output('inval_addr');
  Logic get invalHold => output('inval_hold');

  final Logic _clk;

  HarborDmaSnoopMerge(
    Logic clk,
    Logic reset,
    this.sources, {
    required int addressWidth,
    int depth = 4,
    super.name = 'dma_snoop_merge',
  }) : _clk = clk,
       super(
         definitionName:
             'HarborDmaSnoopMerge_n${sources.length}_a${addressWidth}_d$depth',
       ) {
    if (sources.isEmpty) throw ArgumentError('no snoop sources');
    final lineSize = sources.first.lineSize;
    var rate = 0.0;
    for (final s in sources) {
      if (s.lineSize != lineSize) {
        throw ArgumentError(
          'snoop source ${s.name} has lineSize ${s.lineSize}, '
          'not $lineSize.',
        );
      }
      rate += s.beatBytes / s.lineSize;
      if (rate > 1) {
        throw ArgumentError(
          'snoop source ${s.name} makes the sum of beatBytes / lineSize more '
          'than 1, so the merge cannot keep up.',
        );
      }
    }
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final busy = addInput('cache_busy', cacheBusyIn);
    final n = sources.length;
    final selW = n <= 1 ? 1 : (n - 1).bitLength;
    final turn = Logic(name: 'turn', width: selW);
    final valid = Logic(name: 'invalValid');
    final out = Logic(name: 'invalAddr', width: addressWidth);
    final fifos = <_FlopFifo>[];
    final pops = <Logic>[];
    Logic hold = Const(0);
    for (var i = 0; i < n; i++) {
      final s = sources[i];
      final v = addInput('src${i}_valid', s.invalValid);
      final a = addInput('src${i}_addr', s.invalAddr, width: s.invalAddr.width);
      hold = hold | addInput('src${i}_hold', s.invalHold);
      final pop = Logic(name: 'pop$i');
      pops.add(pop);
      final fifo = _FlopFifo(
        clk,
        reset,
        push: v,
        data: a.width >= addressWidth
            ? a.getRange(0, addressWidth)
            : a.zeroExtend(addressWidth),
        pop: pop,
        depth: depth,
        name: 'src$i',
      );
      fifos.add(fifo);
      // The tap pushes on a cycle where it shows a line and ready is high.
      final ready = addOutput('src${i}_ready');
      ready <= ~fifo.full;
      s.invalReadyIn <= ready;
      final quiet = addOutput('src${i}_quiet');
      quiet <= fifo.empty & ~valid & ~busy;
      s.invalQuietIn <= quiet;
    }
    // Round robin: the first non-empty queue at or after [turn].
    final pick = <Logic>[];
    for (var i = 0; i < n; i++) {
      Logic take = Const(0);
      for (var k = 0; k < n; k++) {
        Logic before = Const(1);
        for (var j = 0; j < k; j++) {
          before = before & fifos[(i - k + j + n) % n].empty;
        }
        take = take | (turn.eq((i - k + n) % n) & ~fifos[i].empty & before);
      }
      pick.add(take.named('pick$i'));
      pops[i] <= pick[i];
    }
    Logic any = Const(0);
    Logic data = Const(0, width: addressWidth);
    Logic nextTurn = turn;
    for (var i = 0; i < n; i++) {
      any = any | pick[i];
      data = mux(pick[i], fifos[i].head, data);
      nextTurn = mux(pick[i], Const((i + 1) % n, width: selW), nextTurn);
    }
    Sequential(clk, [
      If(
        reset,
        then: [valid < 0, turn < 0],
        orElse: [valid < any, out < data, turn < nextTurn],
      ),
    ]);
    addOutput('inval_valid') <= valid;
    addOutput('inval_addr', width: addressWidth) <= out;
    addOutput('inval_hold') <= hold;
  }

  /// Connects the merge and its taps to [cache].
  void connectCache(HarborL1DCache cache) {
    _checkClock(_clk, cache, name);
    for (final s in sources) {
      _checkClock(s._clk, cache, s.name);
      if (cache.config.lineSize != s.lineSize) {
        throw ArgumentError('${s.name} lineSize does not match ${cache.name}.');
      }
      s.fillLineIn <= cache.fillLine.getRange(0, s.fillLineIn.width);
    }
    if (!cache.snoop) throw ArgumentError('${cache.name} needs snoop: true.');
    final aw = cache.invalAddr.width;
    cache.invalValid.srcConnection! <= invalValid;
    cache.invalAddr.srcConnection! <=
        (invalAddr.width >= aw
            ? invalAddr.getRange(0, aw)
            : invalAddr.zeroExtend(aw));
    cache.invalHold.srcConnection! <= invalHold;
    cacheBusyIn <= cache.invalBusy;
  }
}
