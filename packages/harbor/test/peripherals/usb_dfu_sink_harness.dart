import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'usb_test_host.dart';

// Shared fixtures for usb_dfu_sink_ram_test.dart and
// usb_dfu_sink_flash_test.dart: a real HarborUsbCore + HarborUsbDfu feeding
// a real UsbDfuRamSink / UsbDfuFlashSink against a behavioral bus-side
// model, two independent clocks (usb_clk, bus_clk).

/// A minimal behavioral Wishbone B4 slave RAM (consumer/slave role). On a
/// write cycle it stores the selected byte lanes of `dat_mosi` into a word
/// array and acks after [ackDelay] extra cycles. Reads are unsupported.
class WishboneMemoryModel extends BridgeModule {
  final int addressWidth;
  final int dataWidth;
  final int loadBase;
  final int words;
  final int ackDelay;

  int get bytesPerWord => dataWidth ~/ 8;

  late final List<Logic> _mem;

  /// The current stored value of word [i].
  int wordAt(int i) => _mem[i].value.isValid ? _mem[i].value.toInt() : 0;

  /// The current stored value of byte [i] (word-decoded).
  int byteAt(int i) {
    final word = wordAt(i ~/ bytesPerWord);
    final lane = i % bytesPerWord;
    return (word >> (lane * 8)) & 0xFF;
  }

  WishboneMemoryModel({
    required this.addressWidth,
    required this.dataWidth,
    required this.loadBase,
    required this.words,
    this.ackDelay = 0,
    String? name,
  }) : super('WishboneMemoryModel', name: name ?? 'wb_mem') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    final ref = addInterface(
      WishboneInterface(
        WishboneConfig(addressWidth: addressWidth, dataWidth: dataWidth),
      ),
      name: 'bus',
      role: PairRole.consumer, // slave
    );
    final bus = ref.internalInterface!;

    final clk = input('clk');
    final reset = input('reset');
    final selWidth = dataWidth ~/ 8;
    var wordShift = 0;
    for (var v = bytesPerWord; v > 1; v >>= 1) {
      wordShift++;
    }

    _mem = [
      for (var i = 0; i < words; i++) Logic(name: 'mem_$i', width: dataWidth),
    ];

    final wrEn = bus.cyc & bus.stb & bus.we;
    final byteIdx = bus.adr - Const(loadBase, width: addressWidth);
    final wordIdx = bytesPerWord == 1
        ? byteIdx
        : byteIdx.slice(addressWidth - 1, wordShift).zeroExtend(addressWidth);

    final ackReg = Logic(name: 'ack_reg');
    final waitW = ackDelay < 2 ? 1 : (ackDelay + 1).bitLength;
    final waitCnt = Logic(name: 'wait_cnt', width: waitW);

    Logic mergedFor(Logic cur) {
      var out = cur;
      for (var lane = 0; lane < selWidth; lane++) {
        final lo = lane * 8;
        final newByte = bus.datMosi.slice(lo + 7, lo);
        final keepByte = cur.slice(lo + 7, lo);
        final laneByte = mux(
          bus.sel.slice(lane, lane).eq(Const(1)),
          newByte,
          keepByte,
        );
        out = lane == 0 ? laneByte : [laneByte, out.slice(lo - 1, 0)].swizzle();
      }
      return out;
    }

    final accept = ackDelay == 0
        ? (wrEn & ~ackReg)
        : (wrEn & ~ackReg & waitCnt.eq(Const(ackDelay, width: waitW)));

    Sequential(clk, [
      If(
        reset,
        then: [
          ackReg < Const(0),
          waitCnt < Const(0, width: waitW),
          for (final w in _mem) w < Const(0, width: dataWidth),
        ],
        orElse: [
          ackReg < accept,
          If(
            ackDelay == 0 ? Const(0) : (wrEn & ~ackReg & ~accept),
            then: [waitCnt < waitCnt + 1],
            orElse: [waitCnt < Const(0, width: waitW)],
          ),
          If(
            accept,
            then: [
              for (var i = 0; i < words; i++)
                If(
                  wordIdx.eq(Const(i, width: addressWidth)),
                  then: [_mem[i] < mergedFor(_mem[i])],
                ),
            ],
          ),
        ],
      ),
    ]);

    bus.ack <= ackReg;
    bus.datMiso <= Const(0, width: dataWidth);
  }
}

/// A behavioral flash write-port model for [UsbDfuFlashSink]: on `wr_req`
/// it raises `wr_busy`, holds it for [eraseLatency] (op=0) or
/// [programLatency] (op=1) cycles, then pulses `wr_done`. On a program it
/// also copies the sink's page-buffer bytes (read back via `wr_data`/
/// `wr_data_index`) into [storage]. [errorOnOp] (1-based count of write
/// ops, 0 = never) makes that op's `wr_done` carry `wr_err` instead of
/// succeeding, and stops advancing storage from then on.
///
/// Like [HarborSpiFlashController], it rejects a page program of length 0
/// or one that crosses a 256-byte page: it raises `wr_err` and pulses
/// `wr_done` with no `wr_busy`. [rejectOnReq] (1-based count of requests,
/// 0 = never) rejects that request the same way.
class FlashWritePortModel extends BridgeModule {
  final int addrWidth;
  final int eraseLatency;
  final int programLatency;
  final int errorOnOp;
  final int rejectOnReq;

  final Map<int, int> storage = {};
  int opCount = 0;

  /// Cycles on which the model rejected a held request.
  int rejectCount = 0;

  FlashWritePortModel({
    required this.addrWidth,
    this.eraseLatency = 4,
    this.programLatency = 4,
    this.errorOnOp = 0,
    this.rejectOnReq = 0,
    String? name,
  }) : super('FlashWritePortModel', name: name ?? 'flash_wr_model') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('wr_req', PortDirection.input);
    createPort('wr_op', PortDirection.input);
    createPort('wr_addr', PortDirection.input, width: addrWidth);
    createPort('wr_len', PortDirection.input, width: 9);
    createPort('wr_data', PortDirection.input, width: 8);
    addOutput('wr_data_index', width: 9);
    addOutput('wr_busy');
    addOutput('wr_done');
    addOutput('wr_err');

    final clk = input('clk');
    final reset = input('reset');
    final wrReq = input('wr_req');
    final wrOp = input('wr_op');
    final wrAddr = input('wr_addr');
    final wrLen = input('wr_len');
    final wrData = input('wr_data');

    const sIdle = 0;
    const sBusy = 1;

    final state = Logic(name: 'model_state_q');
    final cnt = Logic(name: 'model_cnt_q', width: 16);
    final target = Logic(name: 'model_cnt_target_q', width: 16);
    final busyReg = Logic(name: 'wr_busy_q');
    final doneReg = Logic(name: 'wr_done_q');
    final errReg = Logic(name: 'wr_err_q');
    final idxReg = Logic(name: 'wr_idx_q', width: 9);
    final opReg = Logic(name: 'op_q');
    final addrReg = Logic(name: 'addr_q', width: addrWidth);
    final lenReg = Logic(name: 'len_q', width: 9);

    // Shadow copy of every byte presented on wr_data, captured on the
    // clock edge at the index it was presented at. A plain `.changed`
    // listener on wr_data would miss a byte whose value happens to equal
    // whatever was last held at a different index (both can easily be the
    // same byte value), so the capture has to be synchronous and
    // index-keyed, exactly like a real page buffer.
    const capWidth = 256;
    final capBuf = [
      for (var i = 0; i < capWidth; i++) Logic(name: 'cap_$i', width: 8),
    ];

    output('wr_data_index') <= idxReg;

    // The sink holds wr_req from the request until busy or done, so a
    // rising edge starts a new request.
    final reqPrev = Logic(name: 'req_prev_q');
    final reqIdx = Logic(name: 'req_idx_q', width: 16);
    final reqStart = (wrReq & ~reqPrev).named('req_start');
    final curIdx = (reqIdx + reqStart.zeroExtend(16)).named('cur_req_idx');
    final forceReject = rejectOnReq == 0
        ? Const(0)
        : curIdx.eq(Const(rejectOnReq, width: 16));
    final rejectNow =
        (state.eq(Const(sIdle, width: 1)) &
                wrReq &
                ((wrOp &
                        (wrLen.eq(Const(0, width: 9)) |
                            (wrAddr.getRange(0, 8).zeroExtend(10) +
                                    wrLen.zeroExtend(10))
                                .gt(Const(256, width: 10)))) |
                    forceReject))
            .named('reject_now');
    final rejDone = Logic(name: 'rej_done_q');
    final rejErr = Logic(name: 'rej_err_q');

    Sequential(clk, [
      If(
        reset,
        then: [
          state < Const(sIdle, width: 1),
          cnt < Const(0, width: 16),
          target < Const(0, width: 16),
          busyReg < Const(0),
          doneReg < Const(0),
          errReg < Const(0),
          idxReg < Const(0, width: 9),
          opReg < Const(0),
          addrReg < Const(0, width: addrWidth),
          lenReg < Const(0, width: 9),
          for (final b in capBuf) b < Const(0, width: 8),
          reqPrev < Const(0),
          reqIdx < Const(0, width: 16),
          rejDone < Const(0),
          rejErr < Const(0),
        ],
        orElse: [
          doneReg < Const(0),
          reqPrev < wrReq,
          reqIdx < curIdx,
          rejDone < rejectNow,
          If(rejectNow, then: [rejErr < Const(1)]),
          If(busyReg, then: [rejErr < Const(0)]),
          Case(state, [
            CaseItem(Const(sIdle, width: 1), [
              If(
                wrReq & ~rejectNow,
                then: [
                  busyReg < Const(1),
                  opReg < wrOp,
                  addrReg < wrAddr,
                  lenReg < wrLen,
                  idxReg < Const(0, width: 9),
                  cnt < Const(0, width: 16),
                  // A program must walk every byte of the buffer (so the
                  // test model can capture it), plus at least
                  // programLatency cycles of settle time.
                  target <
                      mux(
                        wrOp,
                        mux(
                          wrLen
                              .zeroExtend(16)
                              .gt(Const(programLatency, width: 16)),
                          wrLen.zeroExtend(16),
                          Const(programLatency, width: 16),
                        ),
                        Const(eraseLatency, width: 16),
                      ),
                  state < Const(sBusy, width: 1),
                ],
              ),
            ]),
            CaseItem(Const(sBusy, width: 1), [
              If(
                opReg,
                then: [
                  for (var i = 0; i < capWidth; i++)
                    If(
                      idxReg.eq(Const(i, width: 9)),
                      then: [capBuf[i] < wrData],
                    ),
                ],
              ),
              If(
                idxReg.lt(lenReg) & opReg,
                then: [idxReg < idxReg + Const(1, width: 9)],
              ),
              If(
                cnt.gte(target),
                then: [
                  busyReg < Const(0),
                  doneReg < Const(1),
                  state < Const(sIdle, width: 1),
                ],
                orElse: [cnt < cnt + Const(1, width: 16)],
              ),
            ]),
          ]),
        ],
      ),
    ]);

    output('wr_busy') <= busyReg;
    output('wr_done') <= doneReg | rejDone;
    output('wr_err') <= errReg | rejErr;
    rejectNow.changed.listen((e) {
      if (e.newValue.isValid && e.newValue.toBool()) rejectCount++;
    });

    // Real flash write engines clear a sticky wr_err the moment the next
    // request is accepted (see HarborSpiFlashController). Mirror that here
    // so an injected error does not wedge every op after it.
    busyReg.changed.listen((e) {
      if (e.newValue.isValid && e.newValue.toBool()) errReg.put(0);
    });

    // Dart-side storage bookkeeping, driven off the done pulse (outside the
    // RTL: the hardware model only needs to time wr_busy/wr_done/wr_err,
    // this just records what a real part would have stored).
    doneReg.changed.listen((e) {
      if (!e.newValue.isValid || !e.newValue.toBool()) return;
      opCount++;
      final isErrorOp = errorOnOp > 0 && opCount == errorOnOp;
      if (isErrorOp) {
        errReg.put(1);
        return;
      }
      final op = opReg.value.isValid ? opReg.value.toInt() : 0;
      final addr = addrReg.value.isValid ? addrReg.value.toInt() : 0;
      final len = lenReg.value.isValid ? lenReg.value.toInt() : 0;
      if (op == 0) {
        // Erase: fill the whole 4 KB sector with 0xFF.
        final sectorBase = addr & ~0xFFF;
        for (var i = 0; i < 4096; i++) {
          storage[sectorBase + i] = 0xFF;
        }
      } else {
        for (var i = 0; i < len; i++) {
          final v = capBuf[i].value;
          storage[addr + i] = v.isValid ? v.toInt() : 0xFF;
        }
      }
    });
  }

  int read(int addr) => storage[addr] ?? 0xFF;
}

/// Wraps [HarborUsbCore], [HarborUsbDfu] and a real [UsbDfuRamSink] against
/// a [WishboneMemoryModel], exposing the pad-level shape for [UsbTestHost]
/// plus the sink's own observability outputs.
class RamSinkHarness extends BridgeModule {
  final int loadBase;
  final int regionBytes;
  final int words;

  RamSinkHarness({
    this.loadBase = 0,
    required this.regionBytes,
    required this.words,
    int pollTimeoutMs = 10,
    int fifoDepth = 128,
    int ackDelay = 0,
    int clearWatchdogLimit = HarborUsbDfu.defaultClearWatchdogLimit,
    String? name,
  }) : super('RamSinkHarness', name: name ?? 'ram_sink_h') {
    createPort('usb_clk', PortDirection.input);
    createPort('usb_reset', PortDirection.input);
    createPort('bus_clk', PortDirection.input);
    createPort('bus_reset', PortDirection.input);
    createPort('dp', PortDirection.input);
    createPort('dm', PortDirection.input);
    addOutput('dp_out');
    addOutput('dm_out');
    addOutput('oe');
    addOutput('dfu_state', width: 4);
    addOutput('dfu_status', width: 4);
    addOutput('image_ready');
    addOutput('bytes_written', width: 32);

    final usbClk = input('usb_clk');
    final usbReset = input('usb_reset');
    final busClk = input('bus_clk');
    final busReset = input('bus_reset');

    final core = HarborUsbCore(
      descriptors: HarborUsbDfu.dfuDescriptors(),
      name: 'core',
    );
    addSubModule(core);
    core.input('clk').srcConnection! <= usbClk;
    core.input('reset').srcConnection! <= usbReset;
    core.input('dp').srcConnection! <= input('dp');
    core.input('dm').srcConnection! <= input('dm');

    final dfu = HarborUsbDfu(
      pollTimeoutMs: pollTimeoutMs,
      clearWatchdogLimit: clearWatchdogLimit,
      name: 'dfu',
    );
    addSubModule(dfu);
    dfu.input('clk').srcConnection! <= usbClk;
    dfu.input('reset').srcConnection! <= usbReset;
    connectInterfaces(core.interface('func'), dfu.interface('usb'));

    final sink = UsbDfuRamSink(
      name: 'sink',
      loadBase: loadBase,
      regionBytes: regionBytes,
      fifoDepth: fifoDepth,
    );
    addSubModule(sink);
    sink.input('usb_clk').srcConnection! <= usbClk;
    sink.input('usb_reset').srcConnection! <= usbReset;
    sink.input('bus_clk').srcConnection! <= busClk;
    sink.input('bus_reset').srcConnection! <= busReset;
    connectInterfaces(dfu.interface('sink'), sink.interface('dfu'));

    final mem = WishboneMemoryModel(
      addressWidth: 32,
      dataWidth: 32,
      loadBase: loadBase,
      words: words,
      ackDelay: ackDelay,
      name: 'mem',
    );
    addSubModule(mem);
    mem.input('clk').srcConnection! <= busClk;
    mem.input('reset').srcConnection! <= busReset;
    connectInterfaces(sink.interface('bus'), mem.interface('bus'));

    output('dp_out') <= core.output('dp_out');
    output('dm_out') <= core.output('dm_out');
    output('oe') <= core.output('oe');
    output('dfu_state') <= dfu.output('dfu_state');
    output('dfu_status') <= dfu.output('dfu_status');
    output('image_ready') <= sink.output('image_ready');
    output('bytes_written') <= sink.output('bytes_written');

    _mem = mem;
  }

  late final WishboneMemoryModel _mem;
  WishboneMemoryModel get mem => _mem;
}

/// Wraps [HarborUsbCore], [HarborUsbDfu] and a real [UsbDfuFlashSink]
/// against a [FlashWritePortModel].
class FlashSinkHarness extends BridgeModule {
  final int flashBase;
  final int eraseLatency;
  final int programLatency;
  final int errorOnOp;
  final int rejectOnReq;

  FlashSinkHarness({
    this.flashBase = 0,
    this.eraseLatency = 4,
    this.programLatency = 4,
    this.errorOnOp = 0,
    this.rejectOnReq = 0,
    int pollTimeoutMs = 10,
    int fifoDepth = 128,
    int clearWatchdogLimit = HarborUsbDfu.defaultClearWatchdogLimit,
    String? name,
  }) : super('FlashSinkHarness', name: name ?? 'flash_sink_h') {
    createPort('usb_clk', PortDirection.input);
    createPort('usb_reset', PortDirection.input);
    createPort('bus_clk', PortDirection.input);
    createPort('bus_reset', PortDirection.input);
    createPort('dp', PortDirection.input);
    createPort('dm', PortDirection.input);
    addOutput('dp_out');
    addOutput('dm_out');
    addOutput('oe');
    addOutput('dfu_state', width: 4);
    addOutput('dfu_status', width: 4);
    addOutput('image_ready');
    addOutput('bytes_written', width: 32);

    final usbClk = input('usb_clk');
    final usbReset = input('usb_reset');
    final busClk = input('bus_clk');
    final busReset = input('bus_reset');

    final core = HarborUsbCore(
      descriptors: HarborUsbDfu.dfuDescriptors(),
      name: 'core',
    );
    addSubModule(core);
    core.input('clk').srcConnection! <= usbClk;
    core.input('reset').srcConnection! <= usbReset;
    core.input('dp').srcConnection! <= input('dp');
    core.input('dm').srcConnection! <= input('dm');

    final dfu = HarborUsbDfu(
      pollTimeoutMs: pollTimeoutMs,
      clearWatchdogLimit: clearWatchdogLimit,
      name: 'dfu',
    );
    addSubModule(dfu);
    dfu.input('clk').srcConnection! <= usbClk;
    dfu.input('reset').srcConnection! <= usbReset;
    connectInterfaces(core.interface('func'), dfu.interface('usb'));

    final sink = UsbDfuFlashSink(
      name: 'sink',
      flashBase: flashBase,
      fifoDepth: fifoDepth,
    );
    addSubModule(sink);
    sink.input('usb_clk').srcConnection! <= usbClk;
    sink.input('usb_reset').srcConnection! <= usbReset;
    sink.input('bus_clk').srcConnection! <= busClk;
    sink.input('bus_reset').srcConnection! <= busReset;
    connectInterfaces(dfu.interface('sink'), sink.interface('dfu'));

    final model = FlashWritePortModel(
      addrWidth: sink.addrWidth,
      eraseLatency: eraseLatency,
      programLatency: programLatency,
      errorOnOp: errorOnOp,
      rejectOnReq: rejectOnReq,
      name: 'flash_model',
    );
    addSubModule(model);
    model.input('clk').srcConnection! <= busClk;
    model.input('reset').srcConnection! <= busReset;
    model.input('wr_req').srcConnection! <= sink.output('wr_req');
    model.input('wr_op').srcConnection! <= sink.output('wr_op');
    model.input('wr_addr').srcConnection! <= sink.output('wr_addr');
    model.input('wr_len').srcConnection! <= sink.output('wr_len');
    model.input('wr_data').srcConnection! <= sink.output('wr_data');
    sink.input('wr_data_index').srcConnection! <= model.output('wr_data_index');
    sink.input('wr_busy').srcConnection! <= model.output('wr_busy');
    sink.input('wr_done').srcConnection! <= model.output('wr_done');
    sink.input('wr_err').srcConnection! <= model.output('wr_err');

    output('dp_out') <= core.output('dp_out');
    output('dm_out') <= core.output('dm_out');
    output('oe') <= core.output('oe');
    output('dfu_state') <= dfu.output('dfu_state');
    output('dfu_status') <= dfu.output('dfu_status');
    output('image_ready') <= sink.output('image_ready');
    output('bytes_written') <= sink.output('bytes_written');

    _model = model;
  }

  late final FlashWritePortModel _model;
  FlashWritePortModel get model => _model;
}

/// Builds a [RamSinkHarness] wired to a [UsbTestHost] on two independent
/// clocks, releases reset, and returns both plus the raw dp/dm signals.
Future<(RamSinkHarness, UsbTestHost)> buildRamSinkHarness({
  required int regionBytes,
  int loadBase = 0,
  int words = 128,
  int usbClkPeriod = 10,
  int busClkPeriod = 37,
  int ackDelay = 0,
  int clearWatchdogLimit = HarborUsbDfu.defaultClearWatchdogLimit,
  int maxSimTime = 20000000,
}) async {
  final dut = RamSinkHarness(
    loadBase: loadBase,
    regionBytes: regionBytes,
    words: words,
    ackDelay: ackDelay,
    clearWatchdogLimit: clearWatchdogLimit,
  );

  final usbClk = SimpleClockGenerator(usbClkPeriod).clk;
  final busClk = SimpleClockGenerator(busClkPeriod).clk;
  final usbReset = Logic(name: 'usb_reset');
  final busReset = Logic(name: 'bus_reset');
  final dp = Logic(name: 'dp');
  final dm = Logic(name: 'dm');

  dut.input('usb_clk').srcConnection! <= usbClk;
  dut.input('usb_reset').srcConnection! <= usbReset;
  dut.input('bus_clk').srcConnection! <= busClk;
  dut.input('bus_reset').srcConnection! <= busReset;
  dut.input('dp').srcConnection! <= dp;
  dut.input('dm').srcConnection! <= dm;

  final host = UsbTestHost(
    clk: usbClk,
    reset: usbReset,
    dp: dp,
    dm: dm,
    devOe: dut.output('oe'),
    devDp: dut.output('dp_out'),
    devDm: dut.output('dm_out'),
  );

  await dut.build();
  await host.build();

  usbReset.inject(1);
  busReset.inject(1);
  dp.inject(1);
  dm.inject(0);
  Simulator.setMaxSimTime(maxSimTime);
  unawaited(Simulator.run());

  // The sinks join their two resets through a short flop chain in each
  // domain, so hold both resets for a few edges of each clock.
  for (var i = 0; i < 4; i++) {
    await usbClk.nextPosedge;
  }
  for (var i = 0; i < 4; i++) {
    await busClk.nextPosedge;
  }
  usbReset.inject(0);
  busReset.inject(0);
  for (var i = 0; i < 30; i++) {
    await usbClk.nextPosedge;
  }

  return (dut, host);
}

/// Builds a [FlashSinkHarness] wired to a [UsbTestHost] on two independent
/// clocks, releases reset.
Future<(FlashSinkHarness, UsbTestHost)> buildFlashSinkHarness({
  int flashBase = 0,
  int eraseLatency = 4,
  int programLatency = 4,
  int errorOnOp = 0,
  int rejectOnReq = 0,
  int usbClkPeriod = 10,
  int busClkPeriod = 37,
  int clearWatchdogLimit = HarborUsbDfu.defaultClearWatchdogLimit,
  int maxSimTime = 40000000,
}) async {
  final dut = FlashSinkHarness(
    flashBase: flashBase,
    eraseLatency: eraseLatency,
    programLatency: programLatency,
    errorOnOp: errorOnOp,
    rejectOnReq: rejectOnReq,
    clearWatchdogLimit: clearWatchdogLimit,
  );

  final usbClk = SimpleClockGenerator(usbClkPeriod).clk;
  final busClk = SimpleClockGenerator(busClkPeriod).clk;
  final usbReset = Logic(name: 'usb_reset');
  final busReset = Logic(name: 'bus_reset');
  final dp = Logic(name: 'dp');
  final dm = Logic(name: 'dm');

  dut.input('usb_clk').srcConnection! <= usbClk;
  dut.input('usb_reset').srcConnection! <= usbReset;
  dut.input('bus_clk').srcConnection! <= busClk;
  dut.input('bus_reset').srcConnection! <= busReset;
  dut.input('dp').srcConnection! <= dp;
  dut.input('dm').srcConnection! <= dm;

  final host = UsbTestHost(
    clk: usbClk,
    reset: usbReset,
    dp: dp,
    dm: dm,
    devOe: dut.output('oe'),
    devDp: dut.output('dp_out'),
    devDm: dut.output('dm_out'),
  );

  await dut.build();
  await host.build();

  usbReset.inject(1);
  busReset.inject(1);
  dp.inject(1);
  dm.inject(0);
  Simulator.setMaxSimTime(maxSimTime);
  unawaited(Simulator.run());

  // The sinks join their two resets through a short flop chain in each
  // domain, so hold both resets for a few edges of each clock.
  for (var i = 0; i < 4; i++) {
    await usbClk.nextPosedge;
  }
  for (var i = 0; i < 4; i++) {
    await busClk.nextPosedge;
  }
  usbReset.inject(0);
  busReset.inject(0);
  for (var i = 0; i < 30; i++) {
    await usbClk.nextPosedge;
  }

  return (dut, host);
}

/// Drives the sink's `bus_reset` to [value] on a falling edge of [busClk].
/// A change in the same tick as a rising edge makes the bus-domain flops X.
Future<void> setBusReset(Logic busClk, Logic busReset, int value) async {
  await busClk.nextNegedge;
  busReset.put(value);
}

/// Like [buildRamSinkHarness], but also hands back `bus_clk` and the
/// `bus_reset` signal so a test can pulse the sink's bus domain into
/// reset directly (for example, mid-drain of a `clear`), something the
/// sink itself cannot be made to do from the USB side alone.
Future<(RamSinkHarness, UsbTestHost, Logic, Logic)>
buildRamSinkHarnessWithBusControl({
  required int regionBytes,
  int loadBase = 0,
  int words = 128,
  int usbClkPeriod = 10,
  int busClkPeriod = 37,
  int ackDelay = 0,
  int clearWatchdogLimit = HarborUsbDfu.defaultClearWatchdogLimit,
  int maxSimTime = 20000000,
}) async {
  final dut = RamSinkHarness(
    loadBase: loadBase,
    regionBytes: regionBytes,
    words: words,
    ackDelay: ackDelay,
    clearWatchdogLimit: clearWatchdogLimit,
  );

  final usbClk = SimpleClockGenerator(usbClkPeriod).clk;
  final busClk = SimpleClockGenerator(busClkPeriod).clk;
  final usbReset = Logic(name: 'usb_reset');
  final busReset = Logic(name: 'bus_reset');
  final dp = Logic(name: 'dp');
  final dm = Logic(name: 'dm');

  dut.input('usb_clk').srcConnection! <= usbClk;
  dut.input('usb_reset').srcConnection! <= usbReset;
  dut.input('bus_clk').srcConnection! <= busClk;
  dut.input('bus_reset').srcConnection! <= busReset;
  dut.input('dp').srcConnection! <= dp;
  dut.input('dm').srcConnection! <= dm;

  final host = UsbTestHost(
    clk: usbClk,
    reset: usbReset,
    dp: dp,
    dm: dm,
    devOe: dut.output('oe'),
    devDp: dut.output('dp_out'),
    devDm: dut.output('dm_out'),
  );

  await dut.build();
  await host.build();

  usbReset.inject(1);
  busReset.inject(1);
  dp.inject(1);
  dm.inject(0);
  Simulator.setMaxSimTime(maxSimTime);
  unawaited(Simulator.run());

  // The sinks join their two resets through a short flop chain in each
  // domain, so hold both resets for a few edges of each clock.
  for (var i = 0; i < 4; i++) {
    await usbClk.nextPosedge;
  }
  for (var i = 0; i < 4; i++) {
    await busClk.nextPosedge;
  }
  usbReset.inject(0);
  busReset.inject(0);
  for (var i = 0; i < 30; i++) {
    await usbClk.nextPosedge;
  }

  return (dut, host, busClk, busReset);
}

/// Like [buildFlashSinkHarness], but also hands back `bus_clk` and the
/// `bus_reset` signal, for the same reason as
/// [buildRamSinkHarnessWithBusControl].
Future<(FlashSinkHarness, UsbTestHost, Logic, Logic)>
buildFlashSinkHarnessWithBusControl({
  int flashBase = 0,
  int eraseLatency = 4,
  int programLatency = 4,
  int errorOnOp = 0,
  int rejectOnReq = 0,
  int usbClkPeriod = 10,
  int busClkPeriod = 37,
  int clearWatchdogLimit = HarborUsbDfu.defaultClearWatchdogLimit,
  int maxSimTime = 40000000,
}) async {
  final dut = FlashSinkHarness(
    flashBase: flashBase,
    eraseLatency: eraseLatency,
    programLatency: programLatency,
    errorOnOp: errorOnOp,
    rejectOnReq: rejectOnReq,
    clearWatchdogLimit: clearWatchdogLimit,
  );

  final usbClk = SimpleClockGenerator(usbClkPeriod).clk;
  final busClk = SimpleClockGenerator(busClkPeriod).clk;
  final usbReset = Logic(name: 'usb_reset');
  final busReset = Logic(name: 'bus_reset');
  final dp = Logic(name: 'dp');
  final dm = Logic(name: 'dm');

  dut.input('usb_clk').srcConnection! <= usbClk;
  dut.input('usb_reset').srcConnection! <= usbReset;
  dut.input('bus_clk').srcConnection! <= busClk;
  dut.input('bus_reset').srcConnection! <= busReset;
  dut.input('dp').srcConnection! <= dp;
  dut.input('dm').srcConnection! <= dm;

  final host = UsbTestHost(
    clk: usbClk,
    reset: usbReset,
    dp: dp,
    dm: dm,
    devOe: dut.output('oe'),
    devDp: dut.output('dp_out'),
    devDm: dut.output('dm_out'),
  );

  await dut.build();
  await host.build();

  usbReset.inject(1);
  busReset.inject(1);
  dp.inject(1);
  dm.inject(0);
  Simulator.setMaxSimTime(maxSimTime);
  unawaited(Simulator.run());

  // The sinks join their two resets through a short flop chain in each
  // domain, so hold both resets for a few edges of each clock.
  for (var i = 0; i < 4; i++) {
    await usbClk.nextPosedge;
  }
  for (var i = 0; i < 4; i++) {
    await busClk.nextPosedge;
  }
  usbReset.inject(0);
  busReset.inject(0);
  for (var i = 0; i < 30; i++) {
    await usbClk.nextPosedge;
  }

  return (dut, host, busClk, busReset);
}

/// Enumerates [host] against [dut] (SET_ADDRESS(1), SET_CONFIGURATION(1),
/// SET_INTERFACE alt [altSetting]). Every sink test starts from here.
Future<void> enumerateSinkDfu(UsbTestHost host, {int altSetting = 0}) async {
  final setAddr = <int>[0x00, 0x05, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00];
  if (!await host.controlNoData(0, setAddr)) {
    throw StateError('SET_ADDRESS failed');
  }
  final setCfg = <int>[0x00, 0x09, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00];
  if (!await host.controlNoData(1, setCfg)) {
    throw StateError('SET_CONFIGURATION failed');
  }
  final setIntf = <int>[0x01, 0x0B, altSetting, 0x00, 0x00, 0x00, 0x00, 0x00];
  if (!await host.controlNoData(1, setIntf)) {
    throw StateError('SET_INTERFACE failed');
  }
}

// DFU 1.1 class bRequest values, for building SETUP packets in tests.
const int dfuReqDnload = 1;
const int dfuReqGetStatus = 3;
const int dfuReqClrStatus = 4;
const int dfuReqAbort = 6;

List<int> dfuSetup({
  required bool dirIn,
  required int bRequest,
  int wValue = 0,
  int wLength = 0,
}) {
  final bmRequestType = (dirIn ? 0x80 : 0x00) | 0x21; // class, interface
  return <int>[
    bmRequestType,
    bRequest,
    wValue & 0xFF,
    (wValue >> 8) & 0xFF,
    0x00,
    0x00,
    wLength & 0xFF,
    (wLength >> 8) & 0xFF,
  ];
}

/// Downloads [data] to [host]/[addr] as consecutive DFU blocks of at most
/// [blockSize] bytes, polling GETSTATUS between blocks until the sink is
/// not busy, then sends the zero-length DNLOAD that ends the transfer.
/// Returns the final GETSTATUS payload (6 bytes: bStatus, poll timeout x3,
/// bState, iString).
Future<List<int>?> dfuDownload(
  UsbTestHost host,
  int addr,
  List<int> data, {
  int blockSize = 64,
}) async {
  var block = 0;
  var offset = 0;
  while (offset < data.length) {
    final end = (offset + blockSize).clamp(0, data.length);
    final chunk = data.sublist(offset, end);
    final setup = dfuSetup(
      dirIn: false,
      bRequest: dfuReqDnload,
      wValue: block,
      wLength: chunk.length,
    );
    if (!await host.controlWrite(addr, setup, chunk)) return null;
    final status = await _waitNotBusy(host, addr);
    if (status == null) return null;
    // dfuERROR: stop, same as a real host would on seeing it.
    if (status[4] == 10) return status;
    offset = end;
    block++;
  }
  final endSetup = dfuSetup(
    dirIn: false,
    bRequest: dfuReqDnload,
    wValue: block,
  );
  if (!await host.controlNoData(addr, endSetup)) return null;
  return _waitNotBusy(host, addr);
}

/// Polls GETSTATUS until bState is no longer dfuDNBUSY(4)/dfuMANIFEST(7).
Future<List<int>?> _waitNotBusy(UsbTestHost host, int addr) async {
  final getStatus = dfuSetup(
    dirIn: true,
    bRequest: dfuReqGetStatus,
    wLength: 6,
  );
  for (var i = 0; i < 2000; i++) {
    final status = await host.controlRead(addr, getStatus);
    if (status == null) return null;
    if (status[4] != 4 && status[4] != 7) return status;
    await host.idle(50);
  }
  return null;
}

/// Counts the Wishbone writes [dut]'s sink completes while [on] returns
/// true. The count is in element 0 of the returned list.
List<int> countSinkWrites(
  RamSinkHarness dut,
  Logic busClk,
  bool Function() on,
) {
  final sink = dut.subModules.firstWhere((m) => m is UsbDfuRamSink);
  final cyc = sink.output('bus_CYC');
  final stb = sink.output('bus_STB');
  final ack = sink.input('bus_ACK');
  final count = [0];
  busClk.posedge.listen((_) {
    if (!on()) return;
    if (cyc.value.isValid &&
        cyc.value.toBool() &&
        stb.value.isValid &&
        stb.value.toBool() &&
        ack.value.isValid &&
        ack.value.toBool()) {
      count[0]++;
    }
  });
  return count;
}

/// Holds [reset] high for [cycles] edges of [clk]. It changes [reset] on
/// a falling edge only.
Future<void> pulseReset(Logic clk, Logic reset, int cycles) async {
  await clk.nextNegedge;
  reset.put(1);
  for (var i = 0; i < cycles; i++) {
    await clk.nextPosedge;
  }
  await clk.nextNegedge;
  reset.put(0);
}
