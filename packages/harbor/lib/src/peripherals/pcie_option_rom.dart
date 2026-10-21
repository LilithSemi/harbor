import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus_master_port.dart';
import '../bus/port/fabric_kind.dart';
import 'pcie/pcie_stream.dart';

/// Serves a memory-backed PCI expansion ROM on a [HarborPcieStream] of
/// width 64 or 128.
///
/// The block answers 3DW memory reads with the ROM hit bit in `rx_user`. It
/// drops other packets. It reads one memory word for each payload DW.
///
/// `rom_reads` counts the read requests it answers and `completions` the
/// completions it sends. Both stop at 0xffff. They reset only on
/// [counterReset] (`counter_reset`), or on `reset` when it is not given, so
/// a top can keep them over link resets.
class HarborPcieOptionRom extends BridgeModule {
  late final BusMasterPort memory;

  HarborPcieOptionRom({
    required Logic clk,
    required Logic reset,
    required Logic completerId,
    required HarborPcieStream rx,
    required HarborPcieStream tx,
    this.romSize = 256 * 1024,
    this.memoryOffset = 0,
    int? memoryAddressWidth,
    Logic? readCompletionBoundary128,
    Logic? counterReset,
    this.fabricKind = HarborFabricKind.wishbone,
    String? name,
  }) : super(
         'HarborPcieOptionRom_W${rx.width}_S${romSize}_O${memoryOffset}_A${memoryAddressWidth ?? (memoryOffset + romSize - 1).bitLength}_${fabricKind.name}${counterReset == null ? '' : '_C'}',
         name: name ?? 'pcie_option_rom',
       ) {
    if (tx.width != rx.width) {
      throw ArgumentError('tx width ${tx.width} differs from rx ${rx.width}');
    }
    if (romSize < 512 || (romSize & (romSize - 1)) != 0) {
      throw ArgumentError.value(romSize, 'romSize', 'must be a power of 2');
    }
    if (memoryOffset < 0) {
      throw ArgumentError.value(memoryOffset, 'memoryOffset', 'must be >= 0');
    }
    final addressWidth =
        memoryAddressWidth ?? (memoryOffset + romSize - 1).bitLength;
    if (memoryOffset + romSize > (1 << addressWidth)) {
      throw RangeError('option ROM does not fit in the memory address space');
    }
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    completerId = addInput('completer_id', completerId, width: 16);
    final rxs = HarborPcieStream.addSink(this, rx);
    final txs = HarborPcieStream.addSource(this, tx);
    final rxData = rxs.data;
    final rxValid = rxs.valid;
    final rxLast = rxs.last;
    final rxUser = rxs.user;
    final txReady = txs.ready;
    final countersReset = counterReset == null
        ? reset
        : addInput('counter_reset', counterReset);
    final rcb128 = addInput(
      'read_completion_boundary_128',
      readCompletionBoundary128 ?? Const(0),
    );

    final rxReady = rxs.ready;
    final txData = txs.data;
    final txKeep = txs.keep;
    final txLast = txs.last;
    final txValid = txs.valid;
    txs.user <= Const(0, width: HarborPcieStream.userWidth);
    final romReads = addOutput('rom_reads', width: 16);
    final completions = addOutput('completions', width: 16);

    memory = BusMasterPort.create(
      module: this,
      name: 'memory',
      kind: fabricKind,
      addressWidth: addressWidth,
      dataWidth: 32,
      clk: clk,
      reset: reset,
    );

    const waitHeader = 0;
    const waitAddress = 1;
    const drain = 2;
    const fetchFirst = 3;
    const sendHeader = 4;
    const sendFirst = 5;
    const fetchData = 6;
    const startRead = 7;
    const sendData = 8;
    final width = rx.width;
    // Payload DWs in a data beat.
    final n = width ~/ 32;
    const prepareCompletion = 9;
    final wordAddressWidth = (romSize ~/ 4 - 1).bitLength;
    final state = Logic(name: 'state', width: 4);
    final requester = Logic(name: 'requester', width: 16);
    final tag = Logic(name: 'tag', width: 8);
    final trafficClass = Logic(name: 'traffic_class', width: 3);
    final attributes = Logic(name: 'attributes', width: 2);
    final poisoned = Logic(name: 'poisoned');
    final firstBe = Logic(name: 'first_be', width: 4);
    final lastBe = Logic(name: 'last_be', width: 4);
    final length = Logic(name: 'length', width: 10);
    final requestRemaining = Logic(name: 'request_remaining', width: 11);
    final completionWords = Logic(name: 'completion_words', width: 11);
    final remaining = Logic(name: 'remaining', width: 11);
    final bytesRemaining = Logic(name: 'bytes_remaining', width: 13);
    final firstCompletion = Logic(name: 'first_completion');
    final wordAddress = Logic(name: 'word_address', width: wordAddressWidth);
    final words = [
      for (var i = 0; i < n; i++) Logic(name: 'rom_word$i', width: 32),
    ];
    final word0 = words[0];
    final fetchIndex = Logic(name: 'fetch_index', width: 2);
    final requestOk = Logic(name: 'request_ok');
    final readCount = Logic(name: 'read_count', width: 16);
    final completionCount = Logic(name: 'completion_count', width: 16);
    romReads <= readCount;
    completions <= completionCount;

    Logic swapBytes(Logic value, String signalName) {
      final swapped = Logic(name: signalName, width: 32);
      swapped <=
          (value.slice(7, 0).zeroExtend(32) << Const(24, width: 32)) |
              (value.slice(15, 8).zeroExtend(32) << Const(16, width: 32)) |
              (value.slice(23, 16).zeroExtend(32) << Const(8, width: 32)) |
              value.slice(31, 24).zeroExtend(32);
      return swapped;
    }

    // Index of the highest enabled byte. Byte counts go from the first
    // enabled byte to the last one, gaps included.
    Logic highestByte(Logic be) => mux(
      be[3],
      Const(3, width: 3),
      mux(
        be[2],
        Const(2, width: 3),
        mux(be[1], Const(1, width: 3), Const(0, width: 3)),
      ),
    );

    final wireWords = [
      for (var i = 0; i < n; i++) swapBytes(words[i], 'wire_word$i'),
    ];
    final wireWord0 = wireWords[0];
    final firstByteOffset = Logic(name: 'first_byte_offset', width: 2);
    firstByteOffset <=
        mux(
          firstBe[0],
          Const(0, width: 2),
          mux(
            firstBe[1],
            Const(1, width: 2),
            mux(firstBe[2], Const(2, width: 2), Const(3, width: 2)),
          ),
        );
    final requestWords = Logic(name: 'request_words', width: 11);
    requestWords <=
        mux(
          length.eq(Const(0, width: 10)),
          Const(1024, width: 11),
          length.zeroExtend(11),
        );
    final requestByteCount = Logic(name: 'request_byte_count', width: 13);
    requestByteCount <=
        mux(
          requestWords.eq(Const(1, width: 11)),
          mux(
            firstBe.eq(Const(0, width: 4)),
            Const(1, width: 13),
            (highestByte(firstBe) - firstByteOffset.zeroExtend(3) + 1)
                .zeroExtend(13),
          ),
          ((requestWords.zeroExtend(13) - Const(1, width: 13)) <<
                  Const(2, width: 13)) -
              firstByteOffset.zeroExtend(13) +
              (highestByte(lastBe) + 1).zeroExtend(13),
        );
    final completionByteOffset = mux(
      firstCompletion,
      firstByteOffset,
      Const(0, width: 2),
    );
    final lowerAddress =
        (wordAddress.slice(4, 0).zeroExtend(32) << Const(2, width: 32)) |
        completionByteOffset.zeroExtend(32);
    final cplDw0 =
        Const(0x4a000000, width: 32) |
        (trafficClass.zeroExtend(32) << Const(20, width: 32)) |
        (poisoned.zeroExtend(32) << Const(14, width: 32)) |
        (attributes.zeroExtend(32) << Const(12, width: 32)) |
        completionWords.slice(9, 0).zeroExtend(32);
    final cplDw1 =
        (completerId.zeroExtend(32) << Const(16, width: 32)) |
        bytesRemaining.slice(11, 0).zeroExtend(32);
    final cplDw2 =
        (requester.zeroExtend(32) << Const(16, width: 32)) |
        (tag.zeroExtend(32) << Const(8, width: 32)) |
        lowerAddress;
    final wordsTo64ByteBoundary =
        Const(16, width: 11) - wordAddress.slice(3, 0).zeroExtend(11);
    final wordsTo128ByteBoundary =
        Const(32, width: 11) - wordAddress.slice(4, 0).zeroExtend(11);
    final wordsToBoundary = mux(
      rcb128,
      wordsTo128ByteBoundary,
      wordsTo64ByteBoundary,
    );
    final nextCompletionWords = mux(
      requestRemaining.lt(wordsToBoundary),
      requestRemaining,
      wordsToBoundary,
    );
    // Only a completion that is not the last uses this, so its first DW
    // counts from the first enabled byte to the DW end.
    final completionBytesReturned =
        (completionWords.zeroExtend(13) << Const(2, width: 13)) -
        mux(
          firstCompletion,
          firstByteOffset.zeroExtend(13),
          Const(0, width: 13),
        );

    memory.addr <=
        Const(memoryOffset, width: addressWidth) +
            (wordAddress.zeroExtend(addressWidth) <<
                Const(2, width: addressWidth));
    memory.dataOut <= Const(0, width: 32);
    memory.we <= Const(0);
    memory.sel <= Const(0xf, width: 4);
    memory.lock <= Const(0);
    memory.stb <=
        state.eq(Const(fetchFirst, width: 4)) |
            state.eq(Const(fetchData, width: 4));

    // Data beat lanes. Lanes past the end of the completion are 0.
    final laneLive = [
      for (var i = 0; i < n; i++) Const(i, width: 11).lt(remaining),
    ];
    final dataBeat = [
      for (var i = n - 1; i >= 0; i--) wireWords[i] & laneLive[i].replicate(32),
    ].swizzle();
    final dataKeep = [
      for (var i = n - 1; i >= 0; i--) laneLive[i].replicate(4),
    ].swizzle();
    final dataEnds = ~Const(n, width: 11).lt(remaining);

    // A 3DW read request at width 128 is one beat with DW2 in it.
    final headerAddress = width == 128
        ? rxData.slice(64 + wordAddressWidth + 1, 66)
        : rxData.slice(wordAddressWidth + 1, 2);
    final headerOk = rxData.slice(30, 24).eq(Const(0, width: 7)) & rxUser[8];

    final w = width;

    // Counter strobes: a request starts, a completion ends.
    final readStart =
        state.eq(Const(startRead, width: 4)) |
        state.eq(Const(waitAddress, width: 4)) & rxValid & requestOk & rxLast;
    final completionEnd =
        txReady &
        (state.eq(Const(sendFirst, width: 4)) &
                remaining.eq(Const(1, width: 11)) |
            state.eq(Const(sendData, width: 4)) & dataEnds);
    Sequential(clk, [
      If(
        countersReset,
        then: [readCount < 0, completionCount < 0],
        orElse: [
          If(
            readStart & ~readCount.eq(0xffff),
            then: [readCount < readCount + 1],
          ),
          If(
            completionEnd & ~completionCount.eq(0xffff),
            then: [completionCount < completionCount + 1],
          ),
        ],
      ),
    ]);
    Logic beat(List<Logic> dws) => [
      for (var i = n - 1; i >= 0; i--)
        i < dws.length ? dws[i] : Const(0, width: 32),
    ].swizzle();
    final fullKeep = Const((1 << (w ~/ 8)) - 1, width: w ~/ 8);

    Combinational([
      rxReady < Const(0),
      txData < Const(0, width: w),
      txKeep < Const(0, width: w ~/ 8),
      txLast < Const(0),
      txValid < Const(0),
      Case(state, [
        CaseItem(Const(waitHeader, width: 4), [rxReady < Const(1)]),
        CaseItem(Const(waitAddress, width: 4), [rxReady < Const(1)]),
        CaseItem(Const(drain, width: 4), [rxReady < Const(1)]),
        CaseItem(Const(sendHeader, width: 4), [
          txData < beat([cplDw0, cplDw1]),
          txKeep < fullKeep,
          txValid < Const(1),
        ]),
        CaseItem(Const(sendFirst, width: 4), [
          // Width 64: DW2 and the first payload DW. Width 128: the whole
          // header and the first payload DW.
          txData <
              beat(
                w == 64
                    ? [cplDw2, wireWord0]
                    : [cplDw0, cplDw1, cplDw2, wireWord0],
              ),
          txKeep < fullKeep,
          txLast < remaining.eq(Const(1, width: 11)),
          txValid < Const(1),
        ]),
        CaseItem(Const(sendData, width: 4), [
          txData < dataBeat,
          txKeep < dataKeep,
          txLast < dataEnds,
          txValid < Const(1),
        ]),
      ]),
    ]);

    // The end of a completion: the next one, or the next request.
    List<Conditional> completionDone() => [
      If(
        requestRemaining.eq(completionWords),
        then: [state < Const(waitHeader, width: 4)],
        orElse: [
          requestRemaining < requestRemaining - completionWords,
          bytesRemaining < bytesRemaining - completionBytesReturned,
          wordAddress < wordAddress + Const(1, width: wordAddressWidth),
          firstCompletion < Const(0),
          state < Const(prepareCompletion, width: 4),
        ],
      ),
    ];
    List<Conditional> startRequest() => [
      requestRemaining < requestWords,
      bytesRemaining < requestByteCount,
      firstCompletion < Const(1),
      state < Const(prepareCompletion, width: 4),
    ];

    Sequential(clk, [
      If(
        reset,
        then: [
          state < Const(waitHeader, width: 4),
          for (final word in words) word < 0,
        ],
        orElse: [
          Case(state, [
            CaseItem(Const(waitHeader, width: 4), [
              If(
                rxValid,
                then: [
                  requester < rxData.slice(63, 48),
                  tag < rxData.slice(47, 40),
                  trafficClass < rxData.slice(22, 20),
                  attributes < rxData.slice(13, 12),
                  poisoned < rxData[14],
                  firstBe < rxData.slice(35, 32),
                  lastBe < rxData.slice(39, 36),
                  length < rxData.slice(9, 0),
                  requestOk < headerOk,
                  if (w == 64)
                    state <
                        mux(
                          rxLast,
                          Const(waitHeader, width: 4),
                          Const(waitAddress, width: 4),
                        )
                  else ...[
                    wordAddress < headerAddress,
                    If.block([
                      Iff(headerOk & rxLast, [
                        state < Const(startRead, width: 4),
                      ]),
                      ElseIf(rxLast, [state < Const(waitHeader, width: 4)]),
                      Else([state < Const(drain, width: 4)]),
                    ]),
                  ],
                ],
              ),
            ]),
            CaseItem(Const(waitAddress, width: 4), [
              If(
                rxValid,
                then: [
                  If(
                    requestOk & rxLast,
                    then: [wordAddress < headerAddress, ...startRequest()],
                    orElse: [
                      state <
                          mux(
                            rxLast,
                            Const(waitHeader, width: 4),
                            Const(drain, width: 4),
                          ),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(startRead, width: 4), startRequest()),
            CaseItem(Const(drain, width: 4), [
              If(rxValid & rxLast, then: [state < Const(waitHeader, width: 4)]),
            ]),
            CaseItem(Const(prepareCompletion, width: 4), [
              completionWords < nextCompletionWords,
              remaining < nextCompletionWords,
              state < Const(fetchFirst, width: 4),
            ]),
            CaseItem(Const(fetchFirst, width: 4), [
              If(
                memory.ack,
                then: [
                  word0 < memory.dataIn,
                  state < Const(w == 64 ? sendHeader : sendFirst, width: 4),
                ],
              ),
            ]),
            CaseItem(Const(sendHeader, width: 4), [
              If(txReady, then: [state < Const(sendFirst, width: 4)]),
            ]),
            CaseItem(Const(sendFirst, width: 4), [
              If(
                txReady,
                then: [
                  If(
                    remaining.eq(Const(1, width: 11)),
                    then: completionDone(),
                    orElse: [
                      remaining < remaining - Const(1, width: 11),
                      wordAddress <
                          wordAddress + Const(1, width: wordAddressWidth),
                      fetchIndex < 0,
                      state < Const(fetchData, width: 4),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(fetchData, width: 4), [
              If(
                memory.ack,
                then: [
                  for (var i = 0; i < n; i++)
                    If(
                      fetchIndex.eq(Const(i, width: 2)),
                      then: [words[i] < memory.dataIn],
                    ),
                  If(
                    remaining.eq(fetchIndex.zeroExtend(11) + 1) |
                        fetchIndex.eq(Const(n - 1, width: 2)),
                    then: [state < Const(sendData, width: 4)],
                    orElse: [
                      fetchIndex < fetchIndex + 1,
                      wordAddress <
                          wordAddress + Const(1, width: wordAddressWidth),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sendData, width: 4), [
              If(
                txReady,
                then: [
                  If(
                    dataEnds,
                    then: completionDone(),
                    orElse: [
                      remaining < remaining - Const(n, width: 11),
                      wordAddress <
                          wordAddress + Const(1, width: wordAddressWidth),
                      fetchIndex < 0,
                      state < Const(fetchData, width: 4),
                    ],
                  ),
                ],
              ),
            ]),
          ]),
        ],
      ),
    ]);
  }

  final int romSize;
  final int memoryOffset;
  final HarborFabricKind fabricKind;
}
