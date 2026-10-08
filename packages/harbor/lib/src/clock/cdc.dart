import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../peripherals/bram.dart';
import '../soc/target.dart';

/// Clock domain crossing synchronizer.
///
/// Implements a multi-stage flip-flop synchronizer for safely
/// crossing single-bit signals between clock domains.
///
/// For multi-bit data, use [HarborCdcHandshake] or [HarborCdcFifo].
class HarborCdcSync extends BridgeModule {
  /// Number of synchronizer stages (minimum 2).
  final int stages;

  /// Synchronized output.
  Logic get syncOut => output('sync_out');

  HarborCdcSync({this.stages = 2, super.name = 'cdc_sync'})
    : super('HarborCdcSync') {
    assert(stages >= 2, 'CDC synchronizer requires at least 2 stages');

    createPort('async_in', PortDirection.input);
    createPort('dst_clk', PortDirection.input);
    createPort('dst_reset', PortDirection.input);
    addOutput('sync_out');

    final dstClk = input('dst_clk');
    final dstReset = input('dst_reset');
    final asyncIn = input('async_in');

    // Chain of flip-flops
    final regs = <Logic>[
      for (var i = 0; i < stages; i++) Logic(name: 'sync_stage_$i'),
    ];

    Sequential(dstClk, [
      If(
        dstReset,
        then: [for (final r in regs) r < Const(0)],
        orElse: [
          regs[0] < asyncIn,
          for (var i = 1; i < stages; i++) regs[i] < regs[i - 1],
        ],
      ),
    ]);

    syncOut <= regs.last;
  }
}

/// Reset for one side of a two-clock bridge.
///
/// It asserts as soon as [own] or [other] asserts, and releases [stages]
/// cycles of [clk] after both are low. Both sides of a bridge thus enter
/// reset together, and each side releases only after it saw both resets low.
///
/// The flops of the chain reset asynchronously and release synchronously, so
/// the result is a flop output in the [clk] domain. A peer pulse of any width
/// that the reset pins of the chain accept resets the full domain for at least
/// [stages] edges of [clk].
Logic harborCdcJoinReset(
  Logic clk,
  Logic own,
  Logic other, {
  int stages = 2,
  String name = 'join_reset',
}) {
  assert(stages >= 2, 'reset synchronizer needs >= 2 stages');
  final raw = (own | other).named('${name}_raw');
  final chain = [
    for (var i = 0; i < stages; i++) Logic(name: '${name}_sync_$i'),
  ];
  Sequential(
    clk,
    [
      chain[0] < Const(0),
      for (var i = 1; i < stages; i++) chain[i] < chain[i - 1],
    ],
    reset: raw,
    asyncReset: true,
    resetValues: {for (final c in chain) c: Const(1)},
  );
  return chain.last.named(name);
}

/// Clock domain crossing with handshake protocol.
///
/// Safely transfers multi-bit data between two clock domains
/// using a req/ack handshake.
class HarborCdcHandshake extends BridgeModule {
  /// Data width in bits.
  final int dataWidth;

  HarborCdcHandshake({this.dataWidth = 32, super.name = 'cdc_handshake'})
    : super('HarborCdcHandshake') {
    // Source domain
    createPort('src_clk', PortDirection.input);
    createPort('src_reset', PortDirection.input);
    createPort('src_data', PortDirection.input, width: dataWidth);
    createPort('src_valid', PortDirection.input);
    addOutput('src_ready');

    // Destination domain
    createPort('dst_clk', PortDirection.input);
    createPort('dst_reset', PortDirection.input);
    addOutput('dst_data', width: dataWidth);
    addOutput('dst_valid');
    createPort('dst_ready', PortDirection.input);

    final srcClk = input('src_clk');
    final srcReset = input('src_reset');
    final dstClk = input('dst_clk');
    final dstReset = input('dst_reset');

    // Source side: latch data and assert req
    final srcReq = Logic(name: 'src_req');
    final dataReg = Logic(name: 'data_reg', width: dataWidth);

    // The acknowledge register of the destination domain. It is made here,
    // above the source block, because the source block synchronizes it back.
    // A signal with no driver in its place holds X, and the X reaches
    // dataReg through the load condition below, so every bit of the
    // crossing becomes X on the first clock after reset.
    final dstAck = Logic(name: 'dst_ack');

    // Synchronize ack back to src domain
    final ackSync0 = Logic(name: 'ack_sync0');
    final ackSync1 = Logic(name: 'ack_sync1');

    Sequential(srcClk, [
      If(
        srcReset,
        then: [
          srcReq < Const(0),
          dataReg < Const(0, width: dataWidth),
          ackSync0 < Const(0),
          ackSync1 < Const(0),
        ],
        orElse: [
          ackSync0 < dstAck,
          ackSync1 < ackSync0,
          If(
            input('src_valid') & ~srcReq & ~ackSync1,
            then: [dataReg < input('src_data'), srcReq < Const(1)],
          ),
          If(ackSync1, then: [srcReq < Const(0)]),
        ],
      ),
    ]);

    output('src_ready') <= ~srcReq & ~ackSync1;

    // Destination side: synchronize req, latch data, assert ack
    final reqSync0 = Logic(name: 'req_sync0');
    final reqSync1 = Logic(name: 'req_sync1');

    Sequential(dstClk, [
      If(
        dstReset,
        then: [reqSync0 < Const(0), reqSync1 < Const(0), dstAck < Const(0)],
        orElse: [
          reqSync0 < srcReq,
          reqSync1 < reqSync0,
          If(reqSync1 & ~dstAck, then: [dstAck < Const(1)]),
          If(input('dst_ready') & dstAck, then: [dstAck < Const(0)]),
        ],
      ),
    ]);

    output('dst_data') <= dataReg;
    output('dst_valid') <= reqSync1 & dstAck;
  }
}

/// Asynchronous FIFO for clock domain crossing.
///
/// Uses gray-code pointers to safely pass data between two
/// independent clock domains.
class HarborCdcFifo extends BridgeModule {
  /// Data width in bits.
  final int dataWidth;

  /// FIFO depth (must be power of 2).
  final int depth;

  /// Free-space margin (in entries) below which [wr_almost_full] asserts. A
  /// consumer that gates its producer on `~wr_almost_full` can have up to
  /// [almostFullMargin] pushes already in flight (decided but not yet retired)
  /// without overflowing, so this must be >= the producer's worst-case
  /// push-while-deasserting latency. Must be 1.. depth.
  final int almostFullMargin;

  /// FPGA target. When non-null and [blockRam] is set, the storage array is
  /// backed by target block RAM instead of flops (see [blockRam]).
  final HarborDeviceTarget? target;

  /// Back the `depth x dataWidth` storage with block RAM where [target] supports
  /// it, instead of a flop array: keeps a deep/wide FIFO off the flop budget.
  /// The gray pointers stay in flops (small).
  ///
  /// The storage becomes a [HarborDualClockBram], which the synthesis tool maps
  /// onto the cell that `target.blockRam` names (`DP16KD` on ECP5). When
  /// [target] is null, or the target has no block RAM, the flop array is used
  /// instead and this flag does nothing, so the flag is always safe to set.
  /// [usesBlockRam] reports which storage the built FIFO has.
  ///
  /// A block RAM read port is SYNCHRONOUS, so the block RAM path adds a
  /// pre-fetch stage that holds the head word in the read port register. The
  /// external contract does not change: `rd_data` is still valid in the SAME
  /// cycle that `rd_empty` is low, and one word for each cycle can still be
  /// read. Only the LATENCY changes. `rd_empty` falls one `rd_clk` cycle later
  /// than with the flop array, because the head word must come out of the RAM
  /// first.
  final bool blockRam;

  /// Whether the storage of this FIFO is block RAM. False when [blockRam] is
  /// not set, and false when the [target] has no block RAM (or is null), where
  /// the FIFO falls back to the flop array.
  bool get usesBlockRam => _bram != null;

  /// The block RAM storage, or null when the FIFO uses the flop array.
  final HarborBlockRam? _bram;

  HarborCdcFifo({
    this.dataWidth = 32,
    this.depth = 8,
    this.almostFullMargin = 1,
    this.target,
    this.blockRam = false,
    super.name = 'cdc_fifo',
    // Derive the module definition name from the parameters so that two
    // differently-sized FIFOs (e.g. a Wishbone-CDC bridge's request and
    // response paths) do not collide on one reserved definitionName in ROHD.
  }) : _bram = blockRam ? target?.blockRam : null,
       // Two FIFOs of one size but a different storage have a different
       // structure, so the block RAM one takes its own definition name and the
       // two cannot dedupe onto one definition.
       super(
         'HarborCdcFifo_${dataWidth}w${depth}d'
         '${blockRam && target?.blockRam != null ? '_bram' : ''}',
       ) {
    assert(
      depth >= 2 && (depth & (depth - 1)) == 0,
      'HarborCdcFifo depth must be a power of 2 and >= 2',
    );
    assert(
      almostFullMargin >= 1 && almostFullMargin <= depth,
      'almostFullMargin must be in 1..depth',
    );

    // Write domain
    createPort('wr_clk', PortDirection.input);
    createPort('wr_reset', PortDirection.input);
    createPort('wr_data', PortDirection.input, width: dataWidth);
    createPort('wr_en', PortDirection.input);
    addOutput('wr_full');
    // Asserted (write domain) when the FIFO has fewer than [almostFullMargin]
    // free entries left. Conservative: it uses the SYNCHRONIZED read pointer,
    // so it can only ever OVER-estimate occupancy (the real read side may have
    // advanced further than the write domain has yet observed), never
    // under-estimate it, which is exactly the safe direction for back-pressure.
    addOutput('wr_almost_full');

    // Read domain
    createPort('rd_clk', PortDirection.input);
    createPort('rd_reset', PortDirection.input);
    addOutput('rd_data', width: dataWidth);
    createPort('rd_en', PortDirection.input);
    addOutput('rd_empty');

    // Pointer width includes extra bit for full/empty detection
    final ptrWidth = _log2(depth) + 1;

    final wrPtr = Logic(name: 'wr_ptr', width: ptrWidth);
    final wrPtrGray = Logic(name: 'wr_ptr_gray', width: ptrWidth);
    final rdPtrGraySync = Logic(name: 'rd_ptr_gray_sync', width: ptrWidth);

    final rdPtr = Logic(name: 'rd_ptr', width: ptrWidth);
    final rdPtrGray = Logic(name: 'rd_ptr_gray', width: ptrWidth);
    final wrPtrGraySync = Logic(name: 'wr_ptr_gray_sync', width: ptrWidth);

    // Gray code conversion: binary ^ (binary >> 1)
    wrPtrGray <= wrPtr ^ (wrPtr >>> 1);
    rdPtrGray <= rdPtr ^ (rdPtr >>> 1);

    // Full: write gray == inverted top 2 bits of read gray, rest equal
    output('wr_full') <=
        wrPtrGray.eq(
          [
            ~rdPtrGraySync.getRange(ptrWidth - 2, ptrWidth),
            rdPtrGraySync.getRange(0, ptrWidth - 2),
          ].swizzle(),
        );

    // Almost-full (write domain): convert the synchronized read gray pointer
    // back to binary, compute the occupancy as the modulo-2*depth difference of
    // the binary write and read pointers, and assert when free space has fallen
    // below [almostFullMargin]. Using the SYNCHRONIZED (lagging) read pointer
    // only ever makes occupancy look LARGER than it truly is, so this signal is
    // conservatively safe for back-pressure (it never under-reports fullness).
    //
    // Gray->binary: bin[msb] = gray[msb], bin[i] = bin[i+1] ^ gray[i].
    final rdBinBits = List<Logic?>.filled(ptrWidth, null);
    rdBinBits[ptrWidth - 1] = rdPtrGraySync.slice(ptrWidth - 1, ptrWidth - 1);
    for (var i = ptrWidth - 2; i >= 0; i--) {
      rdBinBits[i] = rdBinBits[i + 1]! ^ rdPtrGraySync.slice(i, i);
    }
    final rdPtrBinSync = rdBinBits.reversed
        .map((b) => b!)
        .toList()
        .swizzle()
        .named('rd_ptr_bin_sync');
    // Occupancy modulo 2*depth (ptrWidth bits wrap correctly under subtraction).
    final occupancy = (wrPtr - rdPtrBinSync).named('fifo_occupancy');
    // free < margin  <=>  occupancy > depth - margin.
    output('wr_almost_full') <=
        occupancy.gt(Const(depth - almostFullMargin, width: ptrWidth));

    // Empty (flop storage): read gray == write gray. The block RAM path drives
    // `rd_empty` from its pre-fetch stage instead, further down.
    if (_bram == null) {
      output('rd_empty') <= rdPtrGray.eq(wrPtrGraySync);
    }

    // Write domain logic
    final wrClk = input('wr_clk');
    final wrReset = input('wr_reset');

    // Storage memory: `depth` entries of `dataWidth` bits. Written in the write
    // domain at the low (non-wrap) bits of the write pointer, read in the read
    // domain at the low bits of a read-side pointer. The extra wrap bit of the
    // pointers (used only for full/empty detection) is dropped here.
    //
    // Flop storage keeps the array here and reads it combinational. Block RAM
    // storage puts the array in a [HarborDualClockBram] instead, and its read
    // port is SYNCHRONOUS (see the pre-fetch stage in the read domain below).
    final addrWidth = ptrWidth - 1;
    final mem = _bram != null
        ? const <Logic>[]
        : <Logic>[
            for (var i = 0; i < depth; i++)
              Logic(name: 'mem_$i', width: dataWidth),
          ];
    final wrAddr = wrPtr.getRange(0, addrWidth);
    final wrPush = input('wr_en') & ~output('wr_full');

    // Synchronize read pointer gray to write domain
    final rdGraySync0 = Logic(name: 'rd_gray_sync0', width: ptrWidth);
    Sequential(wrClk, [
      If(
        wrReset,
        then: [
          wrPtr < Const(0, width: ptrWidth),
          rdGraySync0 < Const(0, width: ptrWidth),
          rdPtrGraySync < Const(0, width: ptrWidth),
        ],
        orElse: [
          rdGraySync0 < rdPtrGray,
          rdPtrGraySync < rdGraySync0,
          If(
            wrPush,
            then: [
              wrPtr < wrPtr + 1,
              // Write data into the addressed memory entry. The block RAM has
              // its own write port, clocked by the same `wr_clk` and enabled by
              // the same `wrPush`, so it takes no statement here.
              if (_bram == null)
                for (var i = 0; i < depth; i++)
                  If(wrAddr.eq(i), then: [mem[i] < input('wr_data')]),
            ],
          ),
        ],
      ),
    ]);

    // Read domain logic
    final rdClk = input('rd_clk');
    final rdReset = input('rd_reset');

    final wrGraySync0 = Logic(name: 'wr_gray_sync0', width: ptrWidth);

    if (_bram == null) {
      Sequential(rdClk, [
        If(
          rdReset,
          then: [
            rdPtr < Const(0, width: ptrWidth),
            wrGraySync0 < Const(0, width: ptrWidth),
            wrPtrGraySync < Const(0, width: ptrWidth),
          ],
          orElse: [
            wrGraySync0 < wrPtrGray,
            wrPtrGraySync < wrGraySync0,
            If(input('rd_en') & ~output('rd_empty'), then: [rdPtr < rdPtr + 1]),
          ],
        ),
      ]);

      // Combinational read: mux the addressed memory entry onto rd_data using
      // the low (non-wrap) bits of the read pointer.
      final rdAddr = rdPtr.getRange(0, addrWidth);
      Combinational([
        Case(
          rdAddr,
          [
            for (var i = 0; i < depth; i++)
              CaseItem(Const(i, width: addrWidth), [
                output('rd_data') < mem[i],
              ]),
          ],
          defaultItem: [output('rd_data') < Const(0, width: dataWidth)],
        ),
      ]);
      return;
    }

    // Block RAM storage. The read port of a block RAM is SYNCHRONOUS: the data
    // of an address comes out one `rd_clk` cycle later. To keep the same
    // external contract as the flop array (`rd_data` valid in the SAME cycle
    // that `rd_empty` is low), the read side PRE-FETCHES the head word into the
    // read port register, where it waits for the consumer.
    //
    // Two pointers do this:
    //   * `fetchPtr` says which entry to read OUT OF the RAM next. It runs one
    //     entry ahead while the head word waits in the register.
    //   * `rdPtr` says which entries the consumer has TAKEN. It is the pointer
    //     that crosses to the write domain, so an entry stays reserved until
    //     the consumer has the word. The write side therefore cannot overwrite
    //     the pre-fetched entry, and the depth of the FIFO does not change.
    //
    // `dataValid` follows the read port register: a fetch of cycle N puts both
    // its data and `dataValid` in place in cycle N+1, so the two never
    // disagree and no half-fetched word is observable. The register HOLDS while
    // no fetch goes out (the read enable of the port is low), so `rd_data` also
    // cannot change under a consumer that does not read.
    final fetchPtr = Logic(name: 'fetch_ptr', width: ptrWidth);
    final fetchPtrGray = (fetchPtr ^ (fetchPtr >>> 1)).named('fetch_ptr_gray');
    // No entry left to pre-fetch: the same gray comparison as `rd_empty` of the
    // flop path, but against the pointer of the pre-fetch instead.
    final memEmpty = fetchPtrGray.eq(wrPtrGraySync).named('mem_empty');
    final dataValid = Logic(name: 'rd_data_valid');
    // A word leaves the FIFO. This is `rd_en & ~rd_empty`, written from
    // `dataValid` because `rd_empty` is driven from it below.
    final pop = (input('rd_en') & dataValid).named('rd_pop');
    // Send a fetch only when the read port register is free in the next cycle:
    // it either holds nothing, or the consumer takes what it holds now. So one
    // fetch at most is ever in flight and no pre-fetched word is lost.
    final fetch = (~memEmpty & (~dataValid | pop)).named('rd_fetch');

    final ram = HarborDualClockBram(
      wrClk: wrClk,
      wrEn: wrPush,
      wrAddr: wrAddr,
      wrData: input('wr_data'),
      rdClk: rdClk,
      rdReset: rdReset,
      rdEn: fetch,
      rdAddr: fetchPtr.getRange(0, addrWidth),
      width: dataWidth,
      depth: depth,
      primitive: _bram,
      name: 'storage',
    );

    Sequential(rdClk, [
      If(
        rdReset,
        then: [
          rdPtr < Const(0, width: ptrWidth),
          wrGraySync0 < Const(0, width: ptrWidth),
          wrPtrGraySync < Const(0, width: ptrWidth),
          fetchPtr < Const(0, width: ptrWidth),
          dataValid < Const(0),
        ],
        orElse: [
          wrGraySync0 < wrPtrGray,
          wrPtrGraySync < wrGraySync0,
          If(pop, then: [rdPtr < rdPtr + 1]),
          If(fetch, then: [fetchPtr < fetchPtr + 1]),
          // A fetch of this cycle lands in the read port register at the next
          // edge, which is the same edge that sets `dataValid`.
          If(
            fetch,
            then: [dataValid < Const(1)],
            orElse: [
              If(pop, then: [dataValid < Const(0)]),
            ],
          ),
        ],
      ),
    ]);

    output('rd_data') <= ram.rdData;
    output('rd_empty') <= ~dataValid;
  }

  static int _log2(int val) {
    var result = 0;
    var v = val;
    while (v > 1) {
      v >>= 1;
      result++;
    }
    return result;
  }
}
