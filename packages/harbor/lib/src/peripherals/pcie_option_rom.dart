import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus_master_port.dart';
import '../bus/port/fabric_kind.dart';

/// Serves a memory-backed PCI expansion ROM on the Xilinx 7-series AXI stream.
class HarborPcieOptionRom extends BridgeModule {
  late final BusMasterPort memory;

  HarborPcieOptionRom({
    required Logic clk,
    required Logic reset,
    required Logic completerId,
    required Logic rxData,
    required Logic rxValid,
    required Logic rxLast,
    required Logic rxUser,
    required Logic txReady,
    this.romSize = 256 * 1024,
    this.memoryOffset = 0,
    int? memoryAddressWidth,
    Logic? readCompletionBoundary128,
    this.fabricKind = HarborFabricKind.wishbone,
    String? name,
  }) : super(
         'HarborPcieOptionRom_S${romSize}_O${memoryOffset}_A${memoryAddressWidth ?? (memoryOffset + romSize - 1).bitLength}_${fabricKind.name}',
         name: name ?? 'pcie_option_rom',
       ) {
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
    rxData = addInput('rx_data', rxData, width: 64);
    rxValid = addInput('rx_valid', rxValid);
    rxLast = addInput('rx_last', rxLast);
    rxUser = addInput('rx_user', rxUser, width: 22);
    txReady = addInput('tx_ready', txReady);
    final rcb128 = addInput(
      'read_completion_boundary_128',
      readCompletionBoundary128 ?? Const(0),
    );

    final rxReady = addOutput('rx_ready');
    final txData = addOutput('tx_data', width: 64);
    final txKeep = addOutput('tx_keep', width: 8);
    final txLast = addOutput('tx_last');
    final txValid = addOutput('tx_valid');
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
    const fetchData0 = 6;
    const fetchData1 = 7;
    const sendData = 8;
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
    final word0 = Logic(name: 'rom_word0', width: 32);
    final word1 = Logic(name: 'rom_word1', width: 32);
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

    Logic popcount4(Logic value, String signalName) {
      final count = Logic(name: signalName, width: 3);
      count <=
          value[0].zeroExtend(3) +
              value[1].zeroExtend(3) +
              value[2].zeroExtend(3) +
              value[3].zeroExtend(3);
      return count;
    }

    final wireWord0 = swapBytes(word0, 'wire_word0');
    final wireWord1 = swapBytes(word1, 'wire_word1');
    final firstByteCount = popcount4(firstBe, 'first_byte_count');
    final lastByteCount = popcount4(lastBe, 'last_byte_count');
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
            firstByteCount.eq(Const(0, width: 3)),
            Const(1, width: 13),
            firstByteCount.zeroExtend(13),
          ),
          ((requestWords.zeroExtend(13) - Const(2, width: 13)) <<
                  Const(2, width: 13)) +
              firstByteCount.zeroExtend(13) +
              lastByteCount.zeroExtend(13),
        );
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
    final firstResponseByteCount = mux(
      firstByteCount.eq(Const(0, width: 3)),
      Const(1, width: 13),
      firstByteCount.zeroExtend(13),
    );
    final completionBytesReturned = mux(
      firstCompletion,
      ((completionWords - Const(1, width: 11)).zeroExtend(13) <<
              Const(2, width: 13)) +
          firstResponseByteCount,
      completionWords.zeroExtend(13) << Const(2, width: 13),
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
            state.eq(Const(fetchData0, width: 4)) |
            state.eq(Const(fetchData1, width: 4));

    Combinational([
      rxReady < Const(0),
      txData < Const(0, width: 64),
      txKeep < Const(0, width: 8),
      txLast < Const(0),
      txValid < Const(0),
      Case(state, [
        CaseItem(Const(waitHeader, width: 4), [rxReady < Const(1)]),
        CaseItem(Const(waitAddress, width: 4), [rxReady < Const(1)]),
        CaseItem(Const(drain, width: 4), [rxReady < Const(1)]),
        CaseItem(Const(sendHeader, width: 4), [
          txData <
              (cplDw1.zeroExtend(64) << Const(32, width: 64)) |
                  cplDw0.zeroExtend(64),
          txKeep < Const(0xff, width: 8),
          txValid < Const(1),
        ]),
        CaseItem(Const(sendFirst, width: 4), [
          txData <
              (wireWord0.zeroExtend(64) << Const(32, width: 64)) |
                  cplDw2.zeroExtend(64),
          txKeep < Const(0xff, width: 8),
          txLast < remaining.eq(Const(1, width: 11)),
          txValid < Const(1),
        ]),
        CaseItem(Const(sendData, width: 4), [
          txData <
              (wireWord1.zeroExtend(64) << Const(32, width: 64)) |
                  wireWord0.zeroExtend(64),
          txKeep <
              mux(
                remaining.eq(Const(1, width: 11)),
                Const(0x0f, width: 8),
                Const(0xff, width: 8),
              ),
          txLast < ~Const(2, width: 11).lt(remaining),
          txValid < Const(1),
        ]),
      ]),
    ]);

    Sequential(clk, [
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
              requestOk <
                  rxData.slice(30, 24).eq(Const(0, width: 7)) & rxUser[8],
              state <
                  mux(
                    rxLast,
                    Const(waitHeader, width: 4),
                    Const(waitAddress, width: 4),
                  ),
            ],
          ),
        ]),
        CaseItem(Const(waitAddress, width: 4), [
          If(
            rxValid,
            then: [
              If(
                requestOk,
                then: [
                  wordAddress < rxData.slice(wordAddressWidth + 1, 2),
                  requestRemaining < requestWords,
                  bytesRemaining < requestByteCount,
                  firstCompletion < Const(1),
                  readCount < readCount + Const(1, width: 16),
                  state < Const(prepareCompletion, width: 4),
                ],
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
            then: [word0 < memory.dataIn, state < Const(sendHeader, width: 4)],
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
                then: [
                  completionCount < completionCount + Const(1, width: 16),
                  If(
                    requestRemaining.eq(completionWords),
                    then: [state < Const(waitHeader, width: 4)],
                    orElse: [
                      requestRemaining < requestRemaining - completionWords,
                      bytesRemaining < bytesRemaining - completionBytesReturned,
                      wordAddress <
                          wordAddress + Const(1, width: wordAddressWidth),
                      firstCompletion < Const(0),
                      state < Const(prepareCompletion, width: 4),
                    ],
                  ),
                ],
                orElse: [
                  remaining < remaining - Const(1, width: 11),
                  wordAddress < wordAddress + Const(1, width: wordAddressWidth),
                  state < Const(fetchData0, width: 4),
                ],
              ),
            ],
          ),
        ]),
        CaseItem(Const(fetchData0, width: 4), [
          If(
            memory.ack,
            then: [
              word0 < memory.dataIn,
              If(
                remaining.eq(Const(1, width: 11)),
                then: [state < Const(sendData, width: 4)],
                orElse: [
                  wordAddress < wordAddress + Const(1, width: wordAddressWidth),
                  state < Const(fetchData1, width: 4),
                ],
              ),
            ],
          ),
        ]),
        CaseItem(Const(fetchData1, width: 4), [
          If(
            memory.ack,
            then: [word1 < memory.dataIn, state < Const(sendData, width: 4)],
          ),
        ]),
        CaseItem(Const(sendData, width: 4), [
          If(
            txReady,
            then: [
              If(
                ~Const(2, width: 11).lt(remaining),
                then: [
                  completionCount < completionCount + Const(1, width: 16),
                  If(
                    requestRemaining.eq(completionWords),
                    then: [state < Const(waitHeader, width: 4)],
                    orElse: [
                      requestRemaining < requestRemaining - completionWords,
                      bytesRemaining < bytesRemaining - completionBytesReturned,
                      wordAddress <
                          wordAddress + Const(1, width: wordAddressWidth),
                      firstCompletion < Const(0),
                      state < Const(prepareCompletion, width: 4),
                    ],
                  ),
                ],
                orElse: [
                  remaining < remaining - Const(2, width: 11),
                  wordAddress < wordAddress + Const(1, width: wordAddressWidth),
                  state < Const(fetchData0, width: 4),
                ],
              ),
            ],
          ),
        ]),
      ]),
    ], reset: reset);
  }

  final int romSize;
  final int memoryOffset;
  final HarborFabricKind fabricKind;
}
