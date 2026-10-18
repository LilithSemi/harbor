import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/port/fabric_kind.dart';
import '../bus/port/memory_port.dart';
import '../bus/port/memory_waist.dart';

/// Transfer direction for [HarborPcieDma].
enum HarborPcieDmaDirection {
  /// Read host memory and write the local memory fabric.
  hostToDevice,

  /// Read the local memory fabric and write host memory.
  deviceToHost,
}

/// A PCIe endpoint DMA engine for the Xilinx 7-series 64-bit AXI stream.
///
/// The host programs the engine through BAR0. The local side is a Harbor
/// memory manager, which is a full AXI4 manager when [fabricKind] is AXI4.
class HarborPcieDma extends BridgeModule {
  /// Value returned from BAR0 offset 0.
  static const identifier = 0x48444d41;

  static const registerIdentifier = 0x00;
  static const registerControl = 0x04;
  static const registerStatus = 0x08;
  static const registerHostAddressLow = 0x0c;
  static const registerHostAddressHigh = 0x10;
  static const registerLocalAddressLow = 0x14;
  static const registerLocalAddressHigh = 0x18;
  static const registerLengthDwords = 0x1c;
  static const registerCompletedDwords = 0x20;
  static const registerLastData = 0x24;
  static const registerErrorCode = 0x28;

  static const controlStart = 1 << 0;
  static const controlClear = 1 << 1;
  static const controlDeviceToHost = 1 << 2;
  static const statusBusy = 1 << 0;
  static const statusDone = 1 << 1;
  static const statusError = 1 << 2;

  /// One PCIe Memory Read is outstanding at a time.
  static const outstandingReads = 1;

  /// Local memory manager.
  late final HarborMemoryMasterPort memory;

  /// Local fabric kind.
  final HarborFabricKind fabricKind;

  /// Width of local byte addresses.
  final int localAddressWidth;

  /// Bit in `rx_user` that marks a BAR0 hit.
  final int barHitBit;

  HarborPcieDma({
    required Logic clk,
    required Logic reset,
    required Logic completerId,
    required Logic rxData,
    required Logic rxValid,
    required Logic rxLast,
    required Logic rxUser,
    required Logic txReady,
    this.fabricKind = HarborFabricKind.axi4,
    this.localAddressWidth = 32,
    this.barHitBit = 2,
    String? name,
  }) : super(
         'HarborPcieDma_A${localAddressWidth}_${fabricKind.name}_B$barHitBit',
         name: name ?? 'pcie_dma',
       ) {
    if (localAddressWidth < 3 || localAddressWidth > 64) {
      throw RangeError.range(localAddressWidth, 3, 64, 'localAddressWidth');
    }
    if (barHitBit < 0 || barHitBit >= 22) {
      throw RangeError.range(barHitBit, 0, 21, 'barHitBit');
    }

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    completerId = addInput('completer_id', completerId, width: 16);
    rxData = addInput('rx_data', rxData, width: 64);
    rxValid = addInput('rx_valid', rxValid);
    rxLast = addInput('rx_last', rxLast);
    rxUser = addInput('rx_user', rxUser, width: 22);
    txReady = addInput('tx_ready', txReady);

    final rxReady = addOutput('rx_ready');
    final txData = addOutput('tx_data', width: 64);
    final txKeep = addOutput('tx_keep', width: 8);
    final txLast = addOutput('tx_last');
    final txValid = addOutput('tx_valid');
    final busyOut = addOutput('busy');
    final doneOut = addOutput('done');
    final errorOut = addOutput('error');

    memory = HarborMemoryMasterPort.create(
      module: this,
      name: 'memory',
      kind: fabricKind,
      config: HarborMemoryWaistConfig(
        addressWidth: localAddressWidth,
        dataWidth: 32,
        idWidth: 1,
        outstanding: 1,
      ),
      clk: clk,
      reset: reset,
    );
    final mem = memory.waist;

    const idle = 0;
    const hostReadHeader = 1;
    const hostReadAddress = 2;
    const waitHostRead = 3;
    const localWrite = 4;
    const localRead = 5;
    const hostWriteHeader = 6;
    const hostWriteAddress = 7;
    const hostWriteData = 8;
    const fenceHeader = 9;
    const fenceAddress = 10;
    const waitFence = 11;
    final dmaState = Logic(name: 'dma_state', width: 4);
    final busy = Logic(name: 'busy');
    final done = Logic(name: 'done');
    final error = Logic(name: 'error');
    final direction = Logic(name: 'direction');
    final errorCode = Logic(name: 'error_code', width: 8);
    final hostAddress = Logic(name: 'host_address', width: 64);
    final localAddress = Logic(name: 'local_address', width: 64);
    final transferLength = Logic(name: 'transfer_length', width: 32);
    final wordIndex = Logic(name: 'word_index', width: 32);
    final completed = Logic(name: 'completed', width: 32);
    final transferData = Logic(name: 'transfer_data', width: 32);
    final reqSent = Logic(name: 'local_req_sent');
    final wdataSent = Logic(name: 'local_wdata_sent');
    final currentHost =
        hostAddress + (wordIndex.zeroExtend(64) << Const(2, width: 64));
    final currentLocal =
        localAddress + (wordIndex.zeroExtend(64) << Const(2, width: 64));
    busyOut <= busy;
    doneOut <= done;
    errorOut <= error;

    const rxIdle = 0;
    const rxSecond = 1;
    const rxDrain = 2;
    const kindNone = 0;
    const kindBarRead = 1;
    const kindBarWrite = 2;
    const kindCompletion = 3;
    final rxState = Logic(name: 'rx_state', width: 2);
    final rxKind = Logic(name: 'rx_kind', width: 2);
    final requester = Logic(name: 'requester', width: 16);
    final requestTag = Logic(name: 'request_tag', width: 8);
    final completionStatus = Logic(name: 'completion_status', width: 3);
    final barReadWord = Logic(name: 'bar_read_word', width: 10);
    final barLowerAddress = Logic(name: 'bar_lower_address', width: 7);
    final barTxPhase = Logic(name: 'bar_tx_phase', width: 2);
    final barReadData = Logic(name: 'bar_read_data', width: 32);

    Logic swapBytes(Logic value, String signalName) {
      final swapped = Logic(name: signalName, width: 32);
      swapped <=
          (value.slice(7, 0).zeroExtend(32) << Const(24, width: 32)) |
              (value.slice(15, 8).zeroExtend(32) << Const(16, width: 32)) |
              (value.slice(23, 16).zeroExtend(32) << Const(8, width: 32)) |
              value.slice(31, 24).zeroExtend(32);
      return swapped;
    }

    final wireBarReadData = swapBytes(barReadData, 'wire_bar_read_data');
    final wireTransferData = swapBytes(transferData, 'wire_transfer_data');
    final incomingData = swapBytes(
      rxData.slice(63, 32),
      'incoming_payload_data',
    );
    final status =
        busy.zeroExtend(32) |
        (done.zeroExtend(32) << Const(1, width: 32)) |
        (error.zeroExtend(32) << Const(2, width: 32)) |
        (direction.zeroExtend(32) << Const(3, width: 32)) |
        (dmaState.zeroExtend(32) << Const(8, width: 32));

    Combinational([
      barReadData < Const(0, width: 32),
      Case(barReadWord, [
        CaseItem(Const(0, width: 10), [
          barReadData < Const(identifier, width: 32),
        ]),
        CaseItem(Const(2, width: 10), [barReadData < status]),
        CaseItem(Const(3, width: 10), [barReadData < hostAddress.slice(31, 0)]),
        CaseItem(Const(4, width: 10), [
          barReadData < hostAddress.slice(63, 32),
        ]),
        CaseItem(Const(5, width: 10), [
          barReadData < localAddress.slice(31, 0),
        ]),
        CaseItem(Const(6, width: 10), [
          barReadData < localAddress.slice(63, 32),
        ]),
        CaseItem(Const(7, width: 10), [barReadData < transferLength]),
        CaseItem(Const(8, width: 10), [barReadData < completed]),
        CaseItem(Const(9, width: 10), [barReadData < transferData]),
        CaseItem(Const(10, width: 10), [
          barReadData < errorCode.zeroExtend(32),
        ]),
      ]),
    ]);

    final localAccess =
        dmaState.eq(Const(localWrite, width: 4)) |
        dmaState.eq(Const(localRead, width: 4));
    final localWriteActive = dmaState.eq(Const(localWrite, width: 4));
    mem.reqValid <= localAccess & ~reqSent;
    mem.reqId <= Const(0, width: mem.config.idWidth);
    mem.reqWrite <= localWriteActive;
    mem.reqAddr <= currentLocal.slice(localAddressWidth - 1, 0);
    mem.reqLen <= Const(0, width: HarborMemoryWaistConfig.lenWidth);
    mem.reqSize <= Const(2, width: HarborMemoryWaistConfig.sizeWidth);
    mem.reqBurst <=
        Const(
          HarborMemoryBurst.incr.value,
          width: HarborMemoryWaistConfig.burstWidth,
        );
    mem.reqExclusive <= Const(0);
    mem.wdataValid <= localWriteActive & ~wdataSent;
    mem.wdataData <= transferData;
    mem.wdataStrb <= Const(0xf, width: 4);
    mem.wdataLast <= Const(1);
    mem.rdataReady <= dmaState.eq(Const(localRead, width: 4));
    mem.wrespReady <= localWriteActive;

    Logic requestDw1(int tag, String signalName) {
      final value = Logic(name: signalName, width: 32);
      value <=
          (completerId.zeroExtend(32) << Const(16, width: 32)) |
              Const((tag << 8) | 0x0f, width: 32);
      return value;
    }

    final readDw1 = requestDw1(0x41, 'read_dw1');
    final writeDw1 = requestDw1(0x42, 'write_dw1');
    final fenceDw1 = requestDw1(0x43, 'fence_dw1');
    final readDw0 = Const(0x20000001, width: 32);
    final writeDw0 = Const(0x60000001, width: 32);
    final barCplDw0 = Const(0x4a000001, width: 32);
    final barCplDw1 =
        (completerId.zeroExtend(32) << Const(16, width: 32)) |
        Const(4, width: 32);
    final barCplDw2 =
        (requester.zeroExtend(32) << Const(16, width: 32)) |
        (requestTag.zeroExtend(32) << Const(8, width: 32)) |
        barLowerAddress.zeroExtend(32);

    List<Conditional> addressBeat(Logic address) => [
      txData <
          (address.slice(31, 0).zeroExtend(64) << Const(32, width: 64)) |
              address.slice(63, 32).zeroExtend(64),
      txKeep < Const(0xff, width: 8),
      txLast < Const(1),
      txValid < Const(1),
    ];

    List<Conditional> headerBeat(Logic dw0, Logic dw1) => [
      txData <
          (dw1.zeroExtend(64) << Const(32, width: 64)) | dw0.zeroExtend(64),
      txKeep < Const(0xff, width: 8),
      txValid < Const(1),
    ];

    Combinational([
      rxReady < Const(1),
      txData < Const(0, width: 64),
      txKeep < Const(0, width: 8),
      txLast < Const(0),
      txValid < Const(0),
      Case(dmaState, [
        CaseItem(Const(hostReadHeader, width: 4), [
          ...headerBeat(readDw0, readDw1),
        ]),
        CaseItem(Const(hostReadAddress, width: 4), [
          ...addressBeat(currentHost),
        ]),
        CaseItem(Const(hostWriteHeader, width: 4), [
          ...headerBeat(writeDw0, writeDw1),
        ]),
        CaseItem(Const(hostWriteAddress, width: 4), [
          ...addressBeat(currentHost),
          txLast < Const(0),
        ]),
        CaseItem(Const(hostWriteData, width: 4), [
          txData < wireTransferData.zeroExtend(64),
          txKeep < Const(0x0f, width: 8),
          txLast < Const(1),
          txValid < Const(1),
        ]),
        CaseItem(Const(fenceHeader, width: 4), [
          ...headerBeat(readDw0, fenceDw1),
        ]),
        CaseItem(Const(fenceAddress, width: 4), [...addressBeat(currentHost)]),
      ]),
      If(
        dmaState.eq(Const(idle, width: 4)) |
            dmaState.eq(Const(waitHostRead, width: 4)) |
            dmaState.eq(Const(waitFence, width: 4)) |
            dmaState.eq(Const(localRead, width: 4)) |
            dmaState.eq(Const(localWrite, width: 4)),
        then: [
          If(
            barTxPhase.eq(Const(1, width: 2)),
            then: [...headerBeat(barCplDw0, barCplDw1)],
          ),
          If(
            barTxPhase.eq(Const(2, width: 2)),
            then: [
              txData <
                  (wireBarReadData.zeroExtend(64) << Const(32, width: 64)) |
                      barCplDw2.zeroExtend(64),
              txKeep < Const(0xff, width: 8),
              txLast < Const(1),
              txValid < Const(1),
            ],
          ),
        ],
      ),
    ]);

    List<Conditional> fail(int code) => [
      busy < Const(0),
      done < Const(1),
      error < Const(1),
      errorCode < Const(code, width: 8),
      dmaState < Const(idle, width: 4),
      reqSent < Const(0),
      wdataSent < Const(0),
    ];

    List<Conditional> advanceOrFinish(int continueState, {int? finishState}) =>
        [
          completed < completed + Const(1, width: 32),
          If(
            (wordIndex + Const(1, width: 32)).eq(transferLength),
            then: [
              if (finishState != null)
                dmaState < Const(finishState, width: 4)
              else ...[
                busy < Const(0),
                done < Const(1),
                dmaState < Const(idle, width: 4),
              ],
            ],
            orElse: [
              wordIndex < wordIndex + Const(1, width: 32),
              dmaState < Const(continueState, width: 4),
              reqSent < Const(0),
              wdataSent < Const(0),
            ],
          ),
        ];

    Sequential(clk, [
      If(
        txReady,
        then: [
          Case(dmaState, [
            CaseItem(Const(hostReadHeader, width: 4), [
              dmaState < Const(hostReadAddress, width: 4),
            ]),
            CaseItem(Const(hostReadAddress, width: 4), [
              dmaState < Const(waitHostRead, width: 4),
            ]),
            CaseItem(Const(hostWriteHeader, width: 4), [
              dmaState < Const(hostWriteAddress, width: 4),
            ]),
            CaseItem(Const(hostWriteAddress, width: 4), [
              dmaState < Const(hostWriteData, width: 4),
            ]),
            CaseItem(Const(hostWriteData, width: 4), [
              ...advanceOrFinish(localRead, finishState: fenceHeader),
            ]),
            CaseItem(Const(fenceHeader, width: 4), [
              dmaState < Const(fenceAddress, width: 4),
            ]),
            CaseItem(Const(fenceAddress, width: 4), [
              dmaState < Const(waitFence, width: 4),
            ]),
          ]),
          If(
            dmaState.eq(Const(idle, width: 4)) |
                dmaState.eq(Const(waitHostRead, width: 4)) |
                dmaState.eq(Const(waitFence, width: 4)) |
                dmaState.eq(Const(localRead, width: 4)) |
                dmaState.eq(Const(localWrite, width: 4)),
            then: [
              If(
                barTxPhase.eq(Const(1, width: 2)),
                then: [barTxPhase < Const(2, width: 2)],
              ),
              If(
                barTxPhase.eq(Const(2, width: 2)),
                then: [barTxPhase < Const(0, width: 2)],
              ),
            ],
          ),
        ],
      ),
      If(mem.reqValid & mem.reqReady, then: [reqSent < Const(1)]),
      If(mem.wdataValid & mem.wdataReady, then: [wdataSent < Const(1)]),
      If(
        dmaState.eq(Const(localWrite, width: 4)) & mem.wrespValid,
        then: [
          If(
            mem.wrespErr,
            then: fail(5),
            orElse: advanceOrFinish(hostReadHeader),
          ),
        ],
      ),
      If(
        dmaState.eq(Const(localRead, width: 4)) & mem.rdataValid,
        then: [
          If(
            mem.rdataErr,
            then: fail(5),
            orElse: [
              transferData < mem.rdataData,
              reqSent < Const(0),
              dmaState < Const(hostWriteHeader, width: 4),
            ],
          ),
        ],
      ),
      Case(rxState, [
        CaseItem(Const(rxIdle, width: 2), [
          If(
            rxValid,
            then: [
              requester < rxData.slice(63, 48),
              requestTag < rxData.slice(47, 40),
              completionStatus < rxData.slice(47, 45),
              rxKind < Const(kindNone, width: 2),
              If(
                rxUser[barHitBit] & rxData.slice(30, 24).eq(Const(0, width: 7)),
                then: [rxKind < Const(kindBarRead, width: 2)],
              ),
              If(
                rxUser[barHitBit] &
                    rxData.slice(30, 24).eq(Const(0x40, width: 7)),
                then: [rxKind < Const(kindBarWrite, width: 2)],
              ),
              If(
                rxData.slice(30, 24).eq(Const(0x4a, width: 7)),
                then: [rxKind < Const(kindCompletion, width: 2)],
              ),
              rxState <
                  mux(
                    rxLast,
                    Const(rxIdle, width: 2),
                    Const(rxSecond, width: 2),
                  ),
            ],
          ),
        ]),
        CaseItem(Const(rxSecond, width: 2), [
          If(
            rxValid,
            then: [
              If(
                rxKind.eq(Const(kindBarRead, width: 2)),
                then: [
                  barReadWord < rxData.slice(11, 2),
                  barLowerAddress < rxData.slice(6, 0),
                  barTxPhase < Const(1, width: 2),
                ],
              ),
              If(
                rxKind.eq(Const(kindBarWrite, width: 2)),
                then: [
                  Case(rxData.slice(11, 2), [
                    CaseItem(Const(1, width: 10), [
                      If(
                        incomingData[0] & ~busy,
                        then: [
                          busy < Const(1),
                          done < Const(0),
                          error < Const(0),
                          errorCode < Const(0, width: 8),
                          direction < incomingData[2],
                          wordIndex < Const(0, width: 32),
                          completed < Const(0, width: 32),
                          reqSent < Const(0),
                          wdataSent < Const(0),
                          If(
                            transferLength.eq(Const(0, width: 32)),
                            then: fail(4),
                            orElse: [
                              dmaState <
                                  mux(
                                    incomingData[2],
                                    Const(localRead, width: 4),
                                    Const(hostReadHeader, width: 4),
                                  ),
                            ],
                          ),
                        ],
                      ),
                      If(
                        incomingData[1],
                        then: [
                          done < Const(0),
                          error < Const(0),
                          errorCode < Const(0, width: 8),
                        ],
                      ),
                    ]),
                    CaseItem(Const(3, width: 10), [
                      hostAddress <
                          (hostAddress &
                                  Const(
                                    BigInt.parse('ffffffff00000000', radix: 16),
                                    width: 64,
                                  )) |
                              incomingData.zeroExtend(64),
                    ]),
                    CaseItem(Const(4, width: 10), [
                      hostAddress <
                          (incomingData.zeroExtend(64) <<
                                  Const(32, width: 64)) |
                              hostAddress.slice(31, 0).zeroExtend(64),
                    ]),
                    CaseItem(Const(5, width: 10), [
                      localAddress <
                          (localAddress &
                                  Const(
                                    BigInt.parse('ffffffff00000000', radix: 16),
                                    width: 64,
                                  )) |
                              incomingData.zeroExtend(64),
                    ]),
                    CaseItem(Const(6, width: 10), [
                      localAddress <
                          (incomingData.zeroExtend(64) <<
                                  Const(32, width: 64)) |
                              localAddress.slice(31, 0).zeroExtend(64),
                    ]),
                    CaseItem(Const(7, width: 10), [
                      transferLength < incomingData,
                    ]),
                  ]),
                ],
              ),
              If(
                rxKind.eq(Const(kindCompletion, width: 2)),
                then: [
                  If(
                    dmaState.eq(Const(waitHostRead, width: 4)),
                    then: [
                      If(
                        ~completionStatus.eq(Const(0, width: 3)),
                        then: fail(1),
                        orElse: [
                          If(
                            ~rxData.slice(15, 8).eq(Const(0x41, width: 8)),
                            then: fail(2),
                            orElse: [
                              transferData < incomingData,
                              reqSent < Const(0),
                              wdataSent < Const(0),
                              dmaState < Const(localWrite, width: 4),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                  If(
                    dmaState.eq(Const(waitFence, width: 4)),
                    then: [
                      If(
                        ~completionStatus.eq(Const(0, width: 3)),
                        then: fail(1),
                        orElse: [
                          If(
                            ~rxData.slice(15, 8).eq(Const(0x43, width: 8)),
                            then: fail(2),
                            orElse: [
                              busy < Const(0),
                              done < Const(1),
                              dmaState < Const(idle, width: 4),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
              rxState <
                  mux(
                    rxLast,
                    Const(rxIdle, width: 2),
                    Const(rxDrain, width: 2),
                  ),
            ],
          ),
        ]),
        CaseItem(Const(rxDrain, width: 2), [
          If(rxValid & rxLast, then: [rxState < Const(rxIdle, width: 2)]),
        ]),
      ]),
    ], reset: reset);
  }
}
