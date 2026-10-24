import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../../bus/port/fabric_kind.dart';
import '../../bus/port/memory_port.dart';
import '../../bus/port/memory_waist.dart';
import '../../bus/port/reg_fifo.dart';
import '../bram.dart';
import 'pcie_bank_ram.dart';
import 'pcie_dma_tags.dart';
import 'pcie_endpoint.dart';
import 'pcie_stream.dart';

/// A PCIe DMA engine with a descriptor queue and a completion record ring.
///
/// The host controls the engine through BAR0. It is one client of a
/// `HarborPcieRouter` that takes BAR0 packets and completions. The engine
/// takes one descriptor at a time from the queue. A device to host
/// descriptor reads local memory in bursts and writes it to the host in
/// memory writes of at most the maximum payload size. A host to device
/// descriptor sends up to [readTags] memory reads at a time. The completions
/// go into a reorder buffer, and the engine writes each read to local memory
/// in request order. Then the engine writes a 16 byte record to the
/// completion ring on the same stream. For a host to device descriptor, the
/// record goes after the last local write response. When the descriptor asks
/// for it, the done cause rises after the last record beat leaves the TX
/// port.
///
/// The queue gets descriptors from the BAR0 push registers, from a
/// descriptor ring in host memory, or from both with a select bit in
/// CONTROL. The ring fetcher reads up to 4 descriptors in one memory read
/// with its own tag. The ring head moves when a descriptor goes into the
/// queue. A fetch error, or a tail outside the ring, gets a record with
/// cookie 0 after the queue is empty.
///
/// A descriptor with an error gets a record with the error code, and then
/// the engine halts. An engine reset clears the halt, the queue and the ring
/// head and tail. When the completion ring is full, the engine waits.
///
/// BAR0 is 1 DW registers. A write of more than 1 DW writes the DWs in
/// order. A read of up to [maxReadDw] DWs gets one completion with data,
/// read one DW per cycle. A longer read gets a completion with status CA.
/// Other non-posted requests get status UR.
class HarborPcieDma extends BridgeModule {
  /// Value of the ID register.
  static const identifier = 0x48444d41;

  static const registerId = 0x000;
  static const registerCaps = 0x004;
  static const registerControl = 0x008;
  static const registerStatus = 0x00c;
  static const registerIrqCause = 0x010;
  static const registerIrqMask = 0x014;

  /// Count of completions that match no read in flight. Read only.
  static const registerStaleCompletions = 0x018;

  /// Option ROM counters, read only, when [romStatusBuilt]: [15:0] ROM read
  /// requests, [31:16] ROM completions.
  static const registerRomStatus = 0x01c;

  /// CAPS bit: the ROM counter word at [registerRomStatus] is built.
  static const capsRomStatus = 1 << 2;

  /// Bits 3:0 of the ring base are always 0.
  static const registerCplBaseLow = 0x020;
  static const registerCplBaseHigh = 0x024;
  static const registerCplSize = 0x028;
  static const registerCplHead = 0x02c;
  static const registerCplTail = 0x030;

  /// Bits 4:0 of the ring base are always 0.
  static const registerDescBaseLow = 0x040;
  static const registerDescBaseHigh = 0x044;
  static const registerDescSize = 0x048;
  static const registerDescTail = 0x04c;
  static const registerDescHead = 0x050;

  /// First of the 8 descriptor push DWs. A write to the last DW commits.
  static const registerPush = 0x080;
  static const registerPushCommit = 0x09c;

  static const controlEnable = 1 << 0;
  static const controlEngineReset = 1 << 1;

  /// Selects the ring when both sources are built. A change waits until
  /// the engine is idle.
  static const controlRingSource = 1 << 2;

  static const statusBusy = 1 << 0;
  static const statusHalted = 1 << 1;

  /// A commit came while the queue was full. The descriptor is lost.
  static const statusOverflow = 1 << 2;

  /// The ring is the active descriptor source.
  static const statusRingSource = 1 << 3;
  static const statusErrorShift = 8;
  static const statusFreeShift = 16;

  static const causeDone = 1 << 0;
  static const causeError = 1 << 1;
  static const causeLineShift = 8;

  static const flagDeviceToHost = 1 << 0;
  static const flagIrq = 1 << 1;

  static const errorCompletion = 1;
  static const errorTimeout = 2;
  static const errorPoisoned = 3;
  static const errorFabric = 4;

  /// The local range does not fit in the fabric address space.
  static const errorLocalRange = 5;
  static const errorLength = 6;

  /// A host address, local address or length is not a multiple of 4.
  static const errorAlignment = 7;

  /// The host range crosses 2^64.
  static const errorHostRange = 8;

  /// The length is 0.
  static const errorZeroLength = 9;

  /// The descriptor ring is not valid: log2 size 0 with a doorbell, a tail
  /// outside the ring, or base + size past 2^64.
  static const errorDescRing = 10;

  /// The completion ring is not valid: log2 size 0, or base + size past
  /// 2^64. The engine halts with no record.
  static const errorCplRing = 11;

  /// Bit 31 of the record status DW.
  static const recordPhase = 1 << 31;

  /// Longest BAR0 read that gets data. 128 bytes fit in one completion at
  /// every max payload size. A CPU load does not make a longer read.
  static const maxReadDw = 32;

  /// BAR0 size in words.
  static const barWords = 0x400;

  /// First BAR0 word of the [infoWords] aperture.
  static const infoFirstWord = 0x40;

  static const infoMaxWords = barWords - infoFirstWord;

  /// Stream width in bits, 64 or 128.
  final int width;

  /// Fabric kind of the memory port.
  final HarborFabricKind fabricKind;

  /// Fabric data width in bits, 32, 64 or 128.
  final int dataWidth;

  /// Fabric byte address width.
  final int addressWidth;

  /// True when the BAR0 descriptor push is built.
  final bool fifoSource;

  /// True when the host ring fetcher is built.
  final bool ringSource;

  /// Number of entries in the descriptor queue, a power of two.
  final int queueDepth;

  /// Host reads in flight.
  final int readTags;

  /// Number of SoC interrupt lines, 0 to 7.
  final int irqLines;

  /// Cycles before a host read times out. The default is 50 ms at a 62.5 MHz
  /// user clock, and 25 ms at 125 MHz.
  final int timeoutCycles;

  /// Largest memory write payload the engine sends.
  final int maxPayloadBytes;

  /// Largest memory read the engine sends, and the reorder buffer size of
  /// each tag.
  final int maxReadRequestBytes;

  /// Read-only words in BAR0 from [infoFirstWord]. A word past the end
  /// reads 0.
  final List<int> infoWords;

  /// The memory master port.
  late final HarborMemoryMasterPort memory;

  /// Level per MSI vector, for the endpoint.
  Logic get irqPending => output('irq_pending');

  HarborPcieDma({
    required Logic clk,
    required Logic reset,
    required Logic completerId,
    required Logic maxPayload,
    required Logic maxReadRequest,
    required Logic rcb128,
    required Logic busMasterEnable,
    required Logic msiEnable,
    required Logic msiVectorsGranted,
    required HarborPcieStream rx,
    required HarborPcieStream tx,
    Logic? irqInputs,
    Logic? romStatus,
    required HarborPcieEndpointConfig endpointConfig,
    this.fabricKind = HarborFabricKind.axi4,
    this.dataWidth = 64,
    this.addressWidth = 32,
    this.fifoSource = true,
    this.ringSource = false,
    this.queueDepth = 64,
    this.readTags = 8,
    this.irqLines = 0,
    this.timeoutCycles = 3125000,
    this.maxPayloadBytes = 256,
    this.maxReadRequestBytes = 512,
    this.infoWords = const [],
    String? name,
  }) : width = rx.width,
       romStatusBuilt = romStatus != null,
       super(
         'HarborPcieDma_W${rx.width}_D${dataWidth}_A${addressWidth}_'
         '${fabricKind.name}_S${fifoSource ? 'f' : ''}${ringSource ? 'r' : ''}'
         '_Q${queueDepth}_T${readTags}_L${irqLines}_O${timeoutCycles}'
         '_P${maxPayloadBytes}_R${maxReadRequestBytes}'
         '_I${_infoTag(infoWords)}${romStatus == null ? '' : '_M'}',
         name: name ?? 'pcie_dma',
       ) {
    _validate(tx, irqInputs);
    // Vector 0 is the DMA and vector 1 + i is line i. With fewer vectors
    // every group shares vector 0.
    if (endpointConfig.msiVectors < 1 + irqLines) {
      throw ArgumentError(
        'msiVectors ${endpointConfig.msiVectors} < 1 + irqLines $irqLines',
      );
    }

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    completerId = addInput('completer_id', completerId, width: 16);
    maxPayload = addInput('max_payload', maxPayload, width: 3);
    maxReadRequest = addInput('max_read_request', maxReadRequest, width: 3);
    // Completions are checked against the request only, so RCB is not used.
    addInput('rcb_128', rcb128);
    busMasterEnable = addInput('bus_master_enable', busMasterEnable);
    msiEnable = addInput('msi_enable', msiEnable);
    msiVectorsGranted = addInput(
      'msi_vectors_granted',
      msiVectorsGranted,
      width: 3,
    );
    final lines = irqLines == 0
        ? null
        : addInput('irq_lines', irqInputs!, width: irqLines);
    _romStatus = romStatus == null
        ? null
        : addInput('rom_status', romStatus, width: 32);
    // A register stage on RX keeps the completion checks away from the
    // endpoint and the router decode.
    final rxIn = HarborPcieStream.addSink(this, rx);
    final rxs = HarborPcieStream(width: width, name: 'rx_reg');
    HarborPcieStreamRegister(
      clk: clk,
      reset: reset,
      upstream: rxIn,
      downstream: rxs,
      name: 'rx_register',
    );
    final txs = HarborPcieStream.addSource(this, tx);

    memory = HarborMemoryMasterPort.create(
      module: this,
      name: 'memory',
      kind: fabricKind,
      config: HarborMemoryWaistConfig(
        addressWidth: addressWidth,
        dataWidth: dataWidth,
      ),
      clk: clk,
      reset: reset,
    );
    _build(
      clk,
      reset,
      completerId,
      maxPayload,
      maxReadRequest,
      busMasterEnable,
      msiEnable,
      msiVectorsGranted,
      lines,
      rxs,
      txs,
    );
  }

  /// True when the option ROM counter word is built.
  final bool romStatusBuilt;

  Logic? _romStatus;

  /// The CAPS register value for these build options.
  int get caps =>
      (fifoSource ? 1 : 0) |
      (ringSource ? 2 : 0) |
      (romStatusBuilt ? capsRomStatus : 0) |
      _log2(queueDepth) << 4 |
      readTags << 8 |
      (width ~/ 32) << 16 |
      (1 + irqLines) << 20;

  static int _log2(int v) => v.bitLength - 1;
  static bool _pow2(int v) => v > 0 && v & (v - 1) == 0;

  void _validate(HarborPcieStream tx, Logic? irqInputs) {
    if (tx.width != width) {
      throw ArgumentError('tx width ${tx.width} differs from rx width $width');
    }
    if (!fifoSource && !ringSource) {
      throw ArgumentError('no descriptor source is built');
    }
    if (![32, 64, 128].contains(dataWidth)) {
      throw ArgumentError.value(dataWidth, 'dataWidth', 'must be 32/64/128');
    }
    if (addressWidth < 12 || addressWidth > 64) {
      throw RangeError.range(addressWidth, 12, 64, 'addressWidth');
    }
    if (!_pow2(queueDepth) || queueDepth < 2 || queueDepth > 4096) {
      throw ArgumentError.value(
        queueDepth,
        'queueDepth',
        'power of two from 2 to 4096',
      );
    }
    // Read tags plus the reserved fetch tag are at most 16 slots.
    if (readTags < 1 || readTags + 1 > 16) {
      throw RangeError.range(readTags, 1, 15, 'readTags');
    }
    if (irqLines < 0 || irqLines > 7) {
      throw RangeError.range(irqLines, 0, 7, 'irqLines');
    }
    if (irqLines > 0 && (irqInputs == null || irqInputs.width != irqLines)) {
      throw ArgumentError('irqInputs must be $irqLines bits wide');
    }
    if (timeoutCycles < 1) {
      throw RangeError.value(timeoutCycles, 'timeoutCycles', 'must be >= 1');
    }
    if (!_pow2(maxPayloadBytes) ||
        maxPayloadBytes < 128 ||
        maxPayloadBytes > 4096) {
      throw ArgumentError.value(
        maxPayloadBytes,
        'maxPayloadBytes',
        'power of two from 128 to 4096',
      );
    }
    if (!_pow2(maxReadRequestBytes) ||
        maxReadRequestBytes < 128 ||
        maxReadRequestBytes > 4096) {
      throw ArgumentError.value(
        maxReadRequestBytes,
        'maxReadRequestBytes',
        'power of two from 128 to 4096',
      );
    }
    if (infoWords.length > infoMaxWords) {
      throw RangeError.range(infoWords.length, 0, infoMaxWords, 'infoWords');
    }
  }

  static Logic _firstSet(Logic be) => mux(
    be[0],
    Const(0, width: 2),
    mux(
      be[1],
      Const(1, width: 2),
      mux(
        be[2],
        Const(2, width: 2),
        mux(be[3], Const(3, width: 2), Const(0, width: 2)),
      ),
    ),
  );

  static Logic _lastTrim(Logic be) => mux(
    be[3],
    Const(0, width: 2),
    mux(
      be[2],
      Const(1, width: 2),
      mux(
        be[1],
        Const(2, width: 2),
        mux(be[0], Const(3, width: 2), Const(0, width: 2)),
      ),
    ),
  );

  static Logic _min(Logic a, Logic b) => mux(a.lt(b), a, b);

  /// The smallest of [left] (32 bits), [limit] and [toPage]. The two limits
  /// are at most 4096, so the three compares run side by side.
  static Logic _sizeOf(Logic left, Logic limit, Logic toPage) {
    final low = left.slice(12, 0);
    final small = ~left.slice(31, 13).or();
    final leftFirst = small & low.lt(limit) & low.lt(toPage);
    return mux(leftFirst, low, _min(limit, toPage));
  }

  void _build(
    Logic clk,
    Logic reset,
    Logic completerId,
    Logic maxPayload,
    Logic maxReadRequest,
    Logic busMasterEnable,
    Logic msiEnable,
    Logic msiVectorsGranted,
    Logic? lines,
    HarborPcieStream rxs,
    HarborPcieStream txs,
  ) {
    final mem = memory.waist;
    final aw = addressWidth;
    final n = width ~/ 32;
    final dpb = dataWidth ~/ 32;
    final dpbLog = _log2(dpb);
    final beatBytes = dataWidth ~/ 8;
    final sizeLog = _log2(beatBytes);
    final maxDw = maxPayloadBytes ~/ 4;
    final entries = maxDw + dpb;
    final idxW = (entries + 8).bitLength + 1;
    final maxCode = _log2(maxPayloadBytes ~/ 128);
    final qBits = _log2(queueDepth);
    const causeWidth = 15;
    final causeBits = 0x3 | ((1 << irqLines) - 1) << causeLineShift;

    // Host visible registers.
    final enable = Logic(name: 'enable');
    final halted = Logic(name: 'halted');
    final overflow = Logic(name: 'overflow');
    final errCode = Logic(name: 'err_code', width: 8);
    final resetReq = Logic(name: 'engine_reset_req');
    final cause = Logic(name: 'irq_cause', width: causeWidth);
    final mask = Logic(name: 'irq_mask', width: causeWidth);
    final cplBase = Logic(name: 'cpl_base', width: 64);
    final cplLog = Logic(name: 'cpl_log2', width: 4);
    final cplHead = Logic(name: 'cpl_head', width: 16);
    final cplTail = Logic(name: 'cpl_tail', width: 16);
    final phase = Logic(name: 'phase');
    final stage = [
      if (fifoSource)
        for (var i = 0; i < 7; i++) Logic(name: 'push_$i', width: 32),
    ];

    // Source select, used only when both sources are built. A new select
    // waits until the engine, the queue and the fetcher are idle.
    final both = fifoSource && ringSource;
    final selReq = Logic(name: 'sel_req');
    final selActive = Logic(name: 'sel_active');
    final Logic ringActive = ringSource
        ? (fifoSource ? selActive : Const(1))
        : Const(0);
    final Logic fifoActive = fifoSource ? ~ringActive : Const(0);
    final selPending = both
        ? (~selReq.eq(selActive)).named('sel_pending')
        : Const(0);

    // Descriptor ring and its fetcher.
    final descBase = Logic(name: 'desc_base', width: 64);
    final descLog = Logic(name: 'desc_log2', width: 4);
    final descTail = Logic(name: 'desc_tail', width: 16);
    final descHead = Logic(name: 'desc_head', width: 16);
    final descRung = Logic(name: 'desc_rung');
    const fIdle = 0;
    const fSend = 1;
    const fWait = 2;
    final fState = Logic(name: 'f_state', width: 2);
    final fAddr = Logic(name: 'f_addr', width: 64);
    final fCount = Logic(name: 'f_count', width: 3);
    final fTag = Logic(name: 'f_tag', width: 8);
    final fT = Logic(name: 'f_t', width: 3);
    final fGot = Logic(name: 'f_got', width: 6);
    // fCount * 32 - fGot * 4 and fAddr + fGot * 4 (mod 128), kept in
    // registers next to fGot, so the completion check has no adder.
    final fRemReg = Logic(name: 'f_rem_reg', width: 13);
    final fExpReg = Logic(name: 'f_exp_reg', width: 7);
    final fPushed = Logic(name: 'f_pushed', width: 3);
    final fErr = Logic(name: 'f_err', width: 8);
    final fInPkt = Logic(name: 'f_in_pkt');
    final fLeft = Logic(name: 'f_left', width: 11);
    final fTimer = Logic(
      name: 'f_timer',
      width: max(1, timeoutCycles.bitLength),
    );
    final fBuf = [
      if (ringSource)
        for (var j = 0; j < 32; j++) Logic(name: 'f_buf_$j', width: 32),
    ];
    final fBusy = ringSource ? (~fState.eq(fIdle)).named('f_busy') : Const(0);

    // Descriptor queue.
    final qHead = Logic(name: 'q_head', width: qBits);
    final qTail = Logic(name: 'q_tail', width: qBits);
    final qCount = Logic(name: 'q_count', width: qBits + 1);
    final qFull = qCount.eq(queueDepth);

    // Engine.
    const sIdle = 0;
    const sLoad = 1;
    const sCheck = 2;
    const sChunk = 3;
    const sReq = 4;
    const sRdata = 5;
    const sTxWait = 6;
    const sTx = 7;
    const sRecWait = 8;
    const sRecTx = 9;
    const sH2d = 10;
    final state = Logic(name: 'state', width: 4);
    Logic inState(int s) => state.eq(Const(s, width: 4));

    final hAddr = Logic(name: 'h_addr', width: 64);
    final lAddr = Logic(name: 'l_addr', width: aw);
    final left = Logic(name: 'left', width: 32);
    final done = Logic(name: 'done', width: 32);
    final dFlags = Logic(name: 'd_flags', width: 2);
    final dCookie = Logic(name: 'd_cookie', width: 32);
    // Where the descriptor came from: [16] ring, [15:0] ring slot or push
    // sequence number.
    final dSrc = Logic(name: 'd_src', width: 17);
    final pushSeq = Logic(name: 'push_seq', width: 16);
    final dLocalBad = Logic(name: 'd_local_bad');
    final code = Logic(name: 'code', width: 8);

    final lane0 = Logic(name: 'lane0', width: 2);
    final curAddr = Logic(name: 'cur_addr', width: aw);
    final beatsLeft = Logic(name: 'beats_left', width: 12);
    final burstLeft = Logic(name: 'burst_left', width: 9);
    final word = Logic(name: 'word', width: idxW);
    final fabErr = Logic(name: 'fab_err');

    final pktAddr = Logic(name: 'pkt_addr', width: 64);
    final pktDw = Logic(name: 'pkt_dw', width: 11);
    final pktRead = Logic(name: 'pkt_read');
    final pktTag = Logic(name: 'pkt_tag', width: 8);

    // Host to device: the read sender and the local write drain.
    const dIdle = 0;
    const dReq = 1;
    const dPrime = 2;
    const dData = 3;
    const dResp = 4;
    final iBusy = Logic(name: 'i_busy');
    final dState = Logic(name: 'd_state', width: 3);
    Logic inD(int s) => dState.eq(Const(s, width: 3));
    final slotW = (readTags - 1).bitLength < 1 ? 1 : (readTags - 1).bitLength;
    final dSlot = Logic(name: 'd_slot', width: slotW);
    final dLen = Logic(name: 'd_len', width: 13);
    final wBeat = Logic(name: 'w_beat', width: 12);
    final txT = Logic(name: 'tx_t', width: 12);
    final txBase = Logic(name: 'tx_base', width: idxW);

    // Entries of the D2H payload buffer from the read start of the last
    // cycle.
    final banks = max(n, dpb);
    final window = [
      for (var k = 0; k < banks; k++) Logic(name: 'payload_lane_$k', width: 32),
    ];
    // The record DWs. They do not change while the record is sent.
    final recWords = [
      dCookie,
      [phase, Const(0, width: 23), code].swizzle(),
      done,
      [dSrc[16], Const(0, width: 15), dSrc.slice(15, 0)].swizzle(),
    ];

    // BAR0 completion.
    const cIdle = 0;
    const cGather = 1;
    const cSend = 2;
    final cState = Logic(name: 'c_state', width: 2);
    final cReqId = Logic(name: 'c_req_id', width: 16);
    final cTag = Logic(name: 'c_tag', width: 8);
    final cTc = Logic(name: 'c_tc', width: 3);
    final cAttr = Logic(name: 'c_attr', width: 2);
    final cAddr = Logic(name: 'c_addr', width: 10);
    final cStatus = Logic(name: 'c_status', width: 3);
    final cByteCount = Logic(name: 'c_byte_count', width: 12);
    final cLowAddr = Logic(name: 'c_low_addr', width: 7);
    final cDw = Logic(name: 'c_dw', width: 6);
    final cG = Logic(name: 'c_g', width: 5);
    final cFirstBe = Logic(name: 'c_first_be', width: 4);
    final cLastBe = Logic(name: 'c_last_be', width: 4);
    final cT = Logic(name: 'c_t', width: 6);
    final cData = [
      for (var i = 0; i < maxReadDw; i++) Logic(name: 'c_data_$i', width: 32),
    ];
    final cplBusy = ~cState.eq(cIdle);

    // RX.
    final capture = HarborPcieHeaderCapture(
      clk: clk,
      reset: reset,
      stream: rxs,
    );
    final header = capture.header;
    final type = tlpFmtType(header).slice(4, 0);
    final hasData = tlpHasData(header);
    final isMWr = type.eq(0) & hasData;
    final isMRd = type.eq(0) & ~hasData;
    final nonPosted =
        (type.eq(0) | type.eq(1)) & ~hasData |
        type.eq(2) |
        type.eq(4) |
        type.eq(5) |
        (type.eq(0x0c) | type.eq(0x0d) | type.eq(0x0e)) & hasData;
    final hdrDw = tlpAddress(header).slice(11, 2);
    final hdrLen = mux(
      tlpLength(header).eq(0),
      Const(1024, width: 11),
      tlpLength(header).zeroExtend(11),
    ).named('hdr_len');
    final hdrFirstBe = tlpFirstBe(header);
    final hdrLastBe = tlpLastBe(header);
    final isCpl = type.eq(0x0a);

    final afterHdr = Logic(name: 'after_hdr');
    final wMode = Logic(name: 'w_mode');
    final wLeft = Logic(name: 'w_left', width: 11);
    final wAddr = Logic(name: 'w_addr', width: 10);
    final wFirst = Logic(name: 'w_first');
    final wFirstBe = Logic(name: 'w_first_be', width: 4);
    final wLastBe = Logic(name: 'w_last_be', width: 4);
    final wLane = Logic(name: 'w_lane', width: 2);

    final atHdr = capture.headerValid;
    final wBeatDone = wLeft.lte(1) | wLane.eq(n - 1);
    rxs.ready <=
        mux(atHdr, ~cplBusy, mux(afterHdr & wMode, wBeatDone, Const(1)));
    final hdrFire = atHdr & rxs.ready;
    final rxFire = rxs.valid & rxs.ready;
    final hdrWrite =
        hdrFire & isMWr & ~tlpPoisoned(header) & capture.payloadInHeaderBeat;

    final tagAbort = Logic(name: 'tag_abort');
    final engReset = Logic(name: 'eng_reset');
    final issueGo = Logic(name: 'issue_go');
    final reqBytes = Logic(name: 'req_bytes', width: 13);
    final drainDone = Logic(name: 'drain_done');
    final rdIndex = Logic(
      name: 'rd_index',
      width: slotW + _log2(maxReadRequestBytes ~/ 4),
    );
    final tags = HarborPcieDmaTags(
      clk: clk,
      reset: reset,
      abort: tagAbort,
      clearStale: engReset,
      cplHeader: hdrFire & isCpl,
      // Without the tag check or ready, so the read issue does not wait for
      // the slot compare.
      cplSeen: capture.headerValid & isCpl,
      header: header,
      firstDw: capture.firstPayloadDw,
      rxFire: rxs.valid & rxs.ready,
      rxLast: rxs.last,
      rxData: rxs.data,
      issue: issueGo,
      issueLen: reqBytes,
      issueLocal: lAddr,
      issueHostLow: hAddr.slice(6, 0),
      drainDone: drainDone,
      reservedBusy: fBusy,
      rdSlot: dSlot,
      rdIndex: rdIndex,
      dataWidth: dataWidth,
      addressWidth: aw,
      readTags: readTags,
      maxReadRequestBytes: maxReadRequestBytes,
      timeoutCycles: timeoutCycles,
      reservedTags: ringSource ? 1 : 0,
    );
    final wDo = afterHdr & wMode & rxs.valid & ~wLeft.eq(0);
    final laneDw = [
      for (var i = 0; i < n; i++) rxs.data.slice(32 * i + 31, 32 * i),
    ];

    // One register write per cycle.
    final wEn = (hdrWrite | wDo).named('reg_w_en');
    final wPort = mux(hdrWrite, hdrDw, wAddr).named('reg_w_addr');
    final wData = tlpSwapBytes(
      harborBitMux(
        hdrWrite,
        capture.firstPayloadDw,
        wLane.selectFrom(laneDw, defaultValue: Const(0, width: 32)),
      ),
    ).named('reg_w_data');
    final wBe = mux(
      hdrWrite,
      hdrFirstBe,
      mux(wFirst, wFirstBe, mux(wLeft.eq(1), wLastBe, Const(0xf, width: 4))),
    ).named('reg_w_be');
    final wMask = [
      for (var b = 3; b >= 0; b--) wBe[b].replicate(8),
    ].swizzle().named('reg_w_mask');
    Logic writes(int dw) => wEn & wPort.eq(Const(dw, width: 10));
    Logic merge(Logic old) =>
        (old & ~wMask.slice(old.width - 1, 0)) |
        (wData & wMask).slice(old.width - 1, 0);

    // Register read port, used by the BAR0 completion.
    final rAddr = (cAddr + cG.zeroExtend(10)).named('reg_r_addr');
    final cplMask = ((Const(1, width: 17) << cplLog) - 1).slice(15, 0);
    final status = [
      (Const(queueDepth, width: qBits + 1) - qCount).zeroExtend(16),
      errCode,
      Const(0, width: 4),
      ringActive,
      overflow,
      halted,
      // Busy means a descriptor is in the engine.
      ~inState(sIdle),
    ].swizzle().named('status');
    final regValue = Logic(name: 'reg_value', width: 32);
    final Logic? infoWord;
    if (infoWords.isNotEmpty) {
      infoWord = Logic(name: 'info_word', width: 32);
      Combinational([
        infoWord < 0,
        Case(rAddr, [
          for (var i = 0; i < infoWords.length; i++)
            if (infoWords[i] != 0)
              CaseItem(Const(infoFirstWord + i, width: 10), [
                infoWord < Const(infoWords[i], width: 32),
              ]),
        ]),
      ]);
    } else {
      infoWord = null;
    }
    CaseItem reg(int offset, Logic value) => CaseItem(
      Const(offset ~/ 4, width: 10),
      [regValue < value.zeroExtend(32)],
    );
    Combinational([
      regValue < 0,
      Case(rAddr, [
        reg(registerId, Const(identifier, width: 32)),
        reg(registerCaps, Const(caps, width: 32)),
        reg(
          registerControl,
          [both ? selReq : Const(0), resetReq, enable].swizzle(),
        ),
        reg(registerStatus, status),
        reg(registerIrqCause, cause),
        reg(registerIrqMask, mask),
        reg(registerStaleCompletions, tags.staleCount),
        if (_romStatus != null) reg(registerRomStatus, _romStatus!),
        reg(registerCplBaseLow, cplBase.slice(31, 0)),
        reg(registerCplBaseHigh, cplBase.slice(63, 32)),
        reg(registerCplSize, cplLog),
        reg(registerCplHead, cplHead),
        reg(registerCplTail, cplTail),
        if (ringSource) ...[
          reg(registerDescBaseLow, descBase.slice(31, 0)),
          reg(registerDescBaseHigh, descBase.slice(63, 32)),
          reg(registerDescSize, descLog),
          reg(registerDescTail, descTail),
          reg(registerDescHead, descHead),
        ],
        for (var i = 0; i < stage.length; i++)
          reg(registerPush + 4 * i, stage[i]),
      ]),
      if (infoWord != null)
        If(rAddr.gte(infoFirstWord), then: [regValue < infoWord]),
    ]);

    // Queue storage. An entry is DWs 0 to 6 of a descriptor and its source.
    Logic pack(List<Logic> d, Logic src) {
      final local64 = [d[3], d[2]].swizzle();
      final localHigh = aw == 64 ? Const(0) : local64.slice(63, aw).or();
      return [
        src,
        localHigh,
        d[6],
        d[5].slice(1, 0),
        d[4],
        local64.slice(aw - 1, 0),
        d[1],
        d[0],
      ].swizzle();
    }

    final commit = fifoSource ? writes(registerPushCommit ~/ 4) : Const(0);
    final fifoPush = (commit & fifoActive & ~qFull).named('fifo_push');
    final fPush = Logic(name: 'f_push');
    final push = (fifoPush | fPush).named('q_push');
    Logic? fifoData = fifoSource
        ? pack(stage, [Const(0), pushSeq].swizzle())
        : null;
    Logic? fetchData;
    if (ringSource) {
      for (var k = 3; k >= 0; k--) {
        // The slot of descriptor k is the head when it goes in.
        final d = pack(
          fBuf.sublist(8 * k, 8 * k + 7),
          [Const(1), descHead].swizzle(),
        );
        fetchData = fetchData == null
            ? d
            : harborBitMux(fPushed.eq(k), d, fetchData);
      }
    }
    final pushData = fifoData == null
        ? fetchData!
        : fetchData == null
        ? fifoData
        : harborBitMux(fPush, fetchData, fifoData);
    final ram = HarborBram(
      clk,
      width: pushData.width,
      depth: queueDepth,
      wrEn: push,
      wrAddr: qTail,
      wrData: pushData,
      rdAddr: qHead,
      name: 'queue',
    );
    final rd = ram.rdData;
    final rdHost = rd.slice(63, 0);
    final rdLocal = rd.slice(63 + aw, 64);
    final rdLen = rd.slice(95 + aw, 64 + aw);
    final rdFlags = rd.slice(97 + aw, 96 + aw);
    final rdCookie = rd.slice(129 + aw, 98 + aw);
    final rdLocalHigh = rd[130 + aw];
    final rdSrc = rd.slice(147 + aw, 131 + aw);
    final pop = inState(sLoad);

    // The local range must fit in the fabric address space.
    final localEnd = (lAddr.zeroExtend(aw + 33) + left.zeroExtend(aw + 33))
        .named('local_end');
    Logic wrapsPast64(Logic base, Logic bytes) {
      final end = base.zeroExtend(66) + bytes.zeroExtend(66);
      return end.slice(65, 64).or() & end.slice(63, 0).or() | end[65];
    }

    final hostWraps = wrapsPast64(hAddr, left).named('host_wraps');

    // Completion ring.
    final cplNext = ((cplTail + 1) & cplMask).named('cpl_next');
    final cplFull = cplNext.eq(cplHead & cplMask).named('cpl_full');
    // The tail stays inside the ring, because the ring cannot change while
    // it holds records.
    final recAddr = (cplBase + (cplTail.zeroExtend(64) << 4)).named('rec_addr');

    // Chunk size: the smallest of bytes left, max payload, 4 KB page end.
    final mpsCode = mux(
      maxPayload.gt(Const(maxCode, width: 3)),
      Const(maxCode, width: 3),
      maxPayload,
    );
    final mpsBytes = Const(128, width: 13) << mpsCode;
    final toPage = Const(0x1000, width: 13) - hAddr.slice(11, 0).zeroExtend(13);
    // The chunk size is registered. After a packet, the chunk state waits
    // one cycle for the new size.
    final chunk = Logic(name: 'chunk', width: 13);
    final chunkStale = Logic(name: 'chunk_stale');
    Sequential(clk, [
      chunk < _sizeOf(left, mpsBytes, toPage),
      chunkStale < inState(sTx),
    ], reset: reset);
    final chunkDw = chunk.slice(12, 2).zeroExtend(11).named('chunk_dw');

    // Read size: the smallest of bytes left, max read request, 4 KB page end.
    final mrrMax = _log2(maxReadRequestBytes ~/ 128);
    final mrrCode = mux(
      maxReadRequest.gt(Const(mrrMax, width: 3)),
      Const(mrrMax, width: 3),
      maxReadRequest,
    );
    final mrrBytes = Const(128, width: 13) << mrrCode;
    // The read size is registered. A read does not start in the cycle after
    // the one before it, when the register still holds the old size.
    final reqNext = _sizeOf(left, mrrBytes, toPage).named('req_next');
    final reqStale = Logic(name: 'req_stale');
    Sequential(clk, [reqBytes < reqNext, reqStale < issueGo], reset: reset);

    // Fabric reads.
    Logic laneOf(Logic addr) => dpb == 1
        ? Const(0, width: 2)
        : addr.slice(3, 2) & Const(dpb - 1, width: 2);
    final to4k =
        (Const(0x1000, width: 13) - curAddr.slice(11, 0).zeroExtend(13)) >>
        sizeLog;
    final beats13 = beatsLeft.zeroExtend(13);
    final cap = mux(to4k.lt(256), to4k, Const(256, width: 13));
    // The burst length is registered. A request waits one cycle after a
    // write to cur_addr or beats_left.
    final burst = Logic(name: 'burst', width: 13);
    final burstStale = Logic(name: 'burst_stale');
    final inH2d = inState(sH2d);
    final reqFire = Logic(name: 'req_fire');
    Sequential(clk, [
      burst < mux(beats13.lt(cap), beats13, cap),
      burstStale < inState(sChunk) | reqFire | inH2d & inD(dIdle),
    ], reset: reset);

    mem.reqValid <= (inState(sReq) | inH2d & inD(dReq)) & ~burstStale;
    mem.reqId <= Const(0, width: mem.config.idWidth);
    mem.reqWrite <= inH2d & inD(dReq);
    mem.reqAddr <= curAddr;
    mem.reqLen <= (burst - 1).slice(HarborMemoryWaistConfig.lenWidth - 1, 0);
    mem.reqSize <= Const(sizeLog, width: HarborMemoryWaistConfig.sizeWidth);
    mem.reqBurst <=
        Const(
          HarborMemoryBurst.incr.value,
          width: HarborMemoryWaistConfig.burstWidth,
        );
    mem.reqExclusive <= Const(0);
    mem.rdataReady <= inState(sRdata);
    reqFire <= mem.reqValid & mem.reqReady;
    final rFire = mem.rdataValid & mem.rdataReady;

    // Local writes from the reorder buffer. Lane l of beat w_beat holds DW
    // w_beat * dpb + l - lane0 of the tag.
    final dLenDw = dLen.slice(12, 2).zeroExtend(13);
    final strobes = <Logic>[];
    for (var l = 0; l < dpb; l++) {
      final p = ((wBeat.zeroExtend(13) << dpbLog) + l).named('d_pos_$l');
      final inRange =
          p.gte(lane0.zeroExtend(13)) & p.lt(lane0.zeroExtend(13) + dLenDw);
      strobes.add(inRange.replicate(4));
    }
    final strb = strobes.rswizzle().named('d_strb');
    mem.wdataValid <= inH2d & inD(dData);
    mem.wdataData <=
        [
          for (var b = beatBytes - 1; b >= 0; b--)
            mux(
              strb[b],
              tags.rdData.slice(8 * b + 7, 8 * b),
              Const(0, width: 8),
            ),
        ].swizzle();
    mem.wdataStrb <= strb;
    mem.wdataLast <= burstLeft.eq(1);
    mem.wrespReady <= inH2d & inD(dResp);
    final wFire = mem.wdataValid & mem.wdataReady;
    final bFire = mem.wrespValid & mem.wrespReady;
    // The buffer address leads the beat by one cycle.
    final wBeatNext = mux(wFire, wBeat + 1, wBeat);
    rdIndex <=
        (((wBeatNext.zeroExtend(16) << dpbLog) - lane0.zeroExtend(16)).slice(
          rdIndex.width - 1,
          0,
        )).named('rd_index_value');

    // Engine TX: memory write of pkt_dw DWs from buf, from lane0 on.
    final is4 = pktAddr.slice(63, 32).or();
    final hdrDws = mux(is4, Const(4, width: 12), Const(3, width: 12));
    final eHdr = [
      [
        mux(
          pktRead,
          mux(is4, Const(0x20, width: 8), Const(0x00, width: 8)),
          mux(is4, Const(0x60, width: 8), Const(0x40, width: 8)),
        ),
        Const(0, width: 14),
        pktDw.slice(9, 0),
      ].swizzle(),
      [
        completerId,
        pktTag,
        mux(pktDw.gt(1), Const(0xf, width: 4), Const(0, width: 4)),
        Const(0xf, width: 4),
      ].swizzle(),
      mux(
        is4,
        pktAddr.slice(63, 32),
        [pktAddr.slice(31, 2), Const(0, width: 2)].swizzle(),
      ),
      [pktAddr.slice(31, 2), Const(0, width: 2)].swizzle(),
    ];
    final eTotal =
        (hdrDws + mux(pktRead, Const(0, width: 12), pktDw.zeroExtend(12)))
            .named('e_total');
    final eLanes = <Logic>[];
    final eKeep = <Logic>[];
    for (var i = 0; i < n; i++) {
      final t = txT + i;
      // In a record, DW k of the payload is record DW k.
      var value = tlpSwapBytes(
        mux(
          inState(sRecTx),
          (txBase + i).slice(1, 0).selectFrom(recWords),
          window[i],
        ),
      );
      for (var h = 3; h >= 0; h--) {
        if (h % n != i) continue;
        value = mux(h == 3 ? t.eq(3) & is4 : t.eq(h), eHdr[h], value);
      }
      final live = t.lt(eTotal);
      eLanes.add(mux(live, value, Const(0, width: 32)));
      eKeep.add(live.replicate(4));
    }
    final eLast = (txT + n).gte(eTotal);
    // The TX port keeps a source until its last beat. Owner 0 is the
    // engine, 1 the BAR0 completion, 2 the fetcher. A request shows no beat
    // while bus master enable is 0, but a packet that holds the port ends.
    final txLock = Logic(name: 'tx_lock');
    final txOwner = Logic(name: 'tx_owner', width: 2);
    Logic mayRequest(int owner) =>
        busMasterEnable | txLock & txOwner.eq(Const(owner, width: 2));
    final eValid =
        (inState(sTx) | inState(sRecTx) | inH2d & iBusy) & mayRequest(0);

    // BAR0 completion TX.
    final cHdr = [
      [
        mux(cDw.eq(0), Const(0x0a, width: 8), Const(0x4a, width: 8)),
        Const(0, width: 1),
        cTc,
        Const(0, width: 6),
        cAttr,
        Const(0, width: 2),
        cDw.zeroExtend(10),
      ].swizzle(),
      [completerId, cStatus, Const(0, width: 1), cByteCount].swizzle(),
      [cReqId, cTag, Const(0, width: 1), cLowAddr].swizzle(),
    ];
    // The payload shifts down after each beat, so lane i of a payload beat
    // is c_data_i and the first payload DW is c_data_0.
    final cTotal = (Const(3, width: 6) + cDw).named('c_total');
    final cLanes = <Logic>[];
    final cKeep = <Logic>[];
    for (var i = 0; i < n; i++) {
      final t = cT + i;
      Logic value = tlpSwapBytes(cData[i]);
      if (3 % n == i) value = mux(t.eq(3), tlpSwapBytes(cData[0]), value);
      for (var h = 2; h >= 0; h--) {
        if (h % n != i) continue;
        value = mux(t.eq(h), cHdr[h], value);
      }
      final live = t.lt(cTotal);
      cLanes.add(mux(live, value, Const(0, width: 32)));
      cKeep.add(live.replicate(4));
    }
    final cLast = (cT + n).gte(cTotal);
    final cValid = cState.eq(cSend);

    // Fetch TX: a memory read of f_count descriptors.
    final fIs4 = fAddr.slice(63, 32).or();
    final fAddrLow = [fAddr.slice(31, 2), Const(0, width: 2)].swizzle();
    final fHdr = [
      [
        mux(fIs4, Const(0x20, width: 8), Const(0x00, width: 8)),
        Const(0, width: 14),
        [fCount, Const(0, width: 3)].swizzle().zeroExtend(10),
      ].swizzle(),
      [completerId, fTag, Const(0xff, width: 8)].swizzle(),
      mux(fIs4, fAddr.slice(63, 32), fAddrLow),
      fAddrLow,
    ];
    final fTotal = mux(fIs4, Const(4, width: 3), Const(3, width: 3));
    final fLanes = <Logic>[];
    final fKeep = <Logic>[];
    for (var i = 0; i < n; i++) {
      final t = fT + i;
      Logic value = Const(0, width: 32);
      for (var h = 3; h >= 0; h--) {
        if (h % n != i) continue;
        value = mux(t.eq(h), fHdr[h], value);
      }
      final live = t.lt(fTotal);
      fLanes.add(mux(live, value, Const(0, width: 32)));
      fKeep.add(live.replicate(4));
    }
    final fLast = (fT + n).gte(fTotal);
    final fValid = ringSource ? fState.eq(fSend) & mayRequest(2) : Const(0);

    final pick = mux(
      txLock,
      txOwner,
      mux(
        cValid,
        Const(1, width: 2),
        mux(fValid, Const(2, width: 2), Const(0, width: 2)),
      ),
    ).named('tx_pick');
    final pickCpl = pick.eq(1);
    final pickFetch = pick.eq(2);
    txs.valid <= mux(pickCpl, cValid, mux(pickFetch, fValid, eValid));
    txs.data <=
        harborBitMux(
          pickCpl,
          cLanes.rswizzle(),
          harborBitMux(pickFetch, fLanes.rswizzle(), eLanes.rswizzle()),
        );
    txs.keep <=
        mux(
          pickCpl,
          cKeep.rswizzle(),
          mux(pickFetch, fKeep.rswizzle(), eKeep.rswizzle()),
        );
    txs.last <= mux(pickCpl, cLast, mux(pickFetch, fLast, eLast));
    txs.user <= Const(0, width: HarborPcieStream.userWidth);
    final txFire = txs.valid & txs.ready;
    final eFire = txFire & pick.eq(0);
    final cFire = txFire & pickCpl;
    final fFire = txFire & pickFetch;
    final recDone = (inState(sRecTx) & eFire & eLast).named('rec_done');

    // The D2H payload buffer. Fabric reads write it, and the read address
    // leads the TX beat by one cycle.
    final payload = HarborPcieWindowBuffer(
      clk,
      entries: entries,
      banks: banks,
      wrEn: inState(sRdata) & rFire,
      wrStart: word << dpbLog,
      wrCount: Const(dpb, width: 3),
      wrLanes: [
        for (var l = 0; l < dpb; l++) mem.rdataData.slice(32 * l + 31, 32 * l),
      ],
      // The TX wait state sets the start of the next packet, so the start
      // does not look at the last beat.
      rdStart: mux(
        inState(sTx),
        mux(eFire, txBase + n, txBase),
        lane0.zeroExtend(idxW) - hdrDws.slice(idxW - 1, 0),
      ),
      name: 'payload',
    );
    for (var k = 0; k < banks; k++) {
      window[k] <= payload.window[k];
    }

    // Host to device control.
    final wrespErr = inH2d & inD(dResp) & bFire & mem.wrespErr;
    final errNow = (inH2d & tags.err | wrespErr).named('err_now');
    final dSafe = (~iBusy & inD(dIdle)).named('d_safe');
    // The tags give an error one cycle late, so no read starts in a cycle
    // that can give one.
    issueGo <=
        inH2d &
            ~iBusy &
            code.eq(0) &
            ~errNow &
            ~tags.errAhead &
            ~reqStale &
            ~resetReq &
            ~left.eq(0) &
            tags.issueReady &
            busMasterEnable;
    // A fetch read that is on the TX port finishes first. An engine packet
    // that has not shown a beat yet is dropped. A packet that has shown a
    // beat finishes first.
    final eShown = (txLock & txOwner.eq(0) | txs.valid & pick.eq(0)).named(
      'e_shown',
    );
    // In the H2D state the drain must also be idle, so no local write
    // burst is cut. The drain only writes data that is in the buffer, so
    // it ends.
    final eStaged = inState(sTx) | inState(sRecTx) | inH2d & iBusy & inD(dIdle);
    engReset <=
        resetReq &
            ~fValid &
            (inState(sIdle) |
                inState(sTxWait) |
                inState(sRecWait) |
                inH2d & inD(dIdle) |
                eStaged) &
            ~(eStaged & eShown);
    tagAbort <= errNow | engReset;
    drainDone <=
        inH2d &
            inD(dData) &
            wFire &
            burstLeft.eq(1) &
            beatsLeft.eq(0) &
            code.eq(0);
    final headLane = laneOf(tags.headLocal);

    // Fetch size: the smallest of descriptors ready, 4, slots to the ring
    // end, slots to the 4 KB page end and free queue entries.
    final descMask = ((Const(1, width: 17) << descLog) - 1).slice(15, 0);
    final fetchAddr = (descBase + (descHead.zeroExtend(64) << 5)).named(
      'fetch_addr',
    );
    Logic cap4(Logic v) {
      final w = v.width < 3 ? v.zeroExtend(3) : v;
      return mux(w.gte(4), Const(4, width: 3), w.slice(2, 0));
    }

    final fN = _min(
      _min(
        cap4((descTail - descHead) & descMask),
        cap4(descMask.zeroExtend(17) - descHead.zeroExtend(17) + 1),
      ),
      _min(
        cap4(Const(128, width: 8) - fetchAddr.slice(11, 5).zeroExtend(8)),
        cap4(Const(queueDepth, width: qBits + 1) - qCount),
      ),
    ).named('f_n');
    final badTail = (descTail & ~descMask).or().named('bad_tail');
    final fMay =
        ringActive &
        fState.eq(fIdle) &
        enable &
        ~halted &
        ~resetReq &
        fErr.eq(0) &
        ~selPending;
    final descWraps = wrapsPast64(
      descBase,
      (Const(32, width: 21) << descLog).zeroExtend(64),
    ).named('desc_wraps');
    final fStart = (fMay & ~badTail & ~descWraps & busMasterEnable & ~fN.eq(0))
        .named('f_start');
    // A ring of 1 slot can hold no descriptor.
    final fBadTail = (fMay & (badTail | descRung & (descLog.eq(0) | descWraps)))
        .named('f_bad_tail');

    // Fetch completions. They come in address order, so DW k of the read
    // goes to f_buf_k.
    final fInWait = fState.eq(fWait) & fErr.eq(0);
    final fRsv = (tags.reservedCpl & fInWait).named('f_cpl');
    final fRem = fRemReg;
    final fBc = tlpByteCount(header);
    final fBc13 = mux(fBc.eq(0), Const(4096, width: 13), fBc.zeroExtend(13));
    final fLen13 = (hdrLen.zeroExtend(13) << 2).named('f_cpl_bytes');
    final fExpLow = fExpReg;
    final fBad =
        ~hasData |
        fLen13.gt(fRem) |
        ~fBc13.eq(fRem) |
        ~tlpLowerAddress(header).eq(fExpLow);
    final fCode = mux(
      ~tlpCplStatus(header).eq(0),
      Const(errorCompletion, width: 8),
      mux(
        tlpPoisoned(header),
        Const(errorPoisoned, width: 8),
        mux(fBad, Const(errorLength, width: 8), Const(0, width: 8)),
      ),
    ).named('f_code');
    final fGood = (fRsv & fCode.eq(0)).named('f_good');
    final fBeat = (fInPkt & rxFire & fInWait).named('f_beat');
    final fCnt = mux(fLeft.lt(n), fLeft.slice(2, 0), Const(n, width: 3));
    final fWant = [fCount, Const(0, width: 3)].swizzle();
    final fExpired = (fInWait & fGot.lt(fWant) & fTimer.eq(timeoutCycles - 1))
        .named('f_expired');
    if (ringSource) {
      // After a halt no descriptor goes in, so DESC_HEAD stays at the
      // failing slot.
      fPush <=
          fInWait &
              ~halted &
              fPushed.lt(fCount) &
              fGot.gte([fPushed + 1, Const(0, width: 3)].swizzle());
    } else {
      fPush <= Const(0);
    }
    final fFill = <Conditional>[
      for (var j = 0; j < fBuf.length; j++)
        If.block([
          // Any fetch completion header writes its DW. A bad one ends the
          // fetch, and that DW is past every pushed descriptor.
          Iff(fRsv & fGot.eq(j), [
            fBuf[j] < tlpSwapBytes(capture.firstPayloadDw),
          ]),
          for (var i = 0; i < n && i <= j; i++)
            ElseIf(fBeat & fGot.eq(j - i) & fCnt.gt(i), [
              fBuf[j] < tlpSwapBytes(laneDw[i]),
            ]),
        ]),
    ];
    final fetcher = <Conditional>[
      ...fFill,
      Case(fState, [
        CaseItem(Const(fIdle, width: 2), [
          If(fBadTail, then: [fErr < errorDescRing]),
          If(
            fStart,
            then: [
              fAddr < fetchAddr,
              fCount < fN,
              fTag < tags.reservedTag,
              fT < 0,
              fGot < 0,
              fRemReg < [fN, Const(0, width: 5)].swizzle().zeroExtend(13),
              fExpReg < fetchAddr.slice(6, 0),
              fPushed < 0,
              fTimer < 0,
              fInPkt < 0,
              fState < fSend,
            ],
          ),
        ]),
        CaseItem(Const(fSend, width: 2), [
          If(
            fFire,
            then: [
              If(fLast, then: [fState < fWait], orElse: [fT < fT + n]),
            ],
          ),
        ]),
        CaseItem(Const(fWait, width: 2), [
          If(fInWait & fGot.lt(fWant), then: [fTimer < fTimer + 1]),
          If(fExpired, then: [fErr < errorTimeout]),
          If.block([
            Iff(fRsv & ~fCode.eq(0), [fErr < fCode, fInPkt < 0]),
            ElseIf(fGood, [
              fGot < fGot + 1,
              fRemReg < fRemReg - 4,
              fExpReg < fExpReg + 4,
              fInPkt < ~rxs.last,
              fLeft < hdrLen - 1,
            ]),
            ElseIf(fBeat, [
              fGot < fGot + fCnt.zeroExtend(6),
              fRemReg < fRemReg - (fCnt.zeroExtend(13) << 2),
              fExpReg < fExpReg + (fCnt.zeroExtend(7) << 2),
              fLeft < fLeft - fCnt.zeroExtend(11),
              If(rxs.last, then: [fInPkt < 0]),
            ]),
          ]),
          If(
            fPush,
            then: [
              fPushed < fPushed + 1,
              descHead < ((descHead + 1) & descMask),
            ],
          ),
          // The last push was in an earlier cycle.
          If(fInWait & fPushed.eq(fCount), then: [fState < fIdle]),
        ]),
      ]),
    ];

    // Interrupt causes.
    // A completion ring of 1 slot is always full, and a ring past 2^64 has
    // no valid record address. The engine halts with code 11 before it
    // starts and writes no record. The error cause still rises.
    final startWanted =
        (enable & ~halted & ~resetReq & ~qCount.eq(0) |
                (ringSource
                    ? enable & ~halted & ~resetReq & ~fErr.eq(0)
                    : Const(0)))
            .named('start_wanted');
    final cplWraps = wrapsPast64(
      cplBase,
      (Const(16, width: 20) << cplLog).zeroExtend(64),
    );
    // The ring check is registered. The engine does not start in the cycle
    // after a CPL ring write, so the check always sees the new ring.
    final cplBadReg = Logic(name: 'cpl_bad_reg');
    final cplWrote = Logic(name: 'cpl_wrote');
    final cplSizeBad = (inState(sIdle) & startWanted & ~cplWrote & cplBadReg)
        .named('cpl_ring_bad');
    // CPL_BASE and CPL_SIZE writes take effect only in the reset state of
    // the ring: tail 0, head 0 and phase 1, with the engine idle and not
    // starting. The ring changes only when no slot holds a record of the
    // current phase.
    final cplWritable =
        (inState(sIdle) & ~startWanted & cplTail.eq(0) & cplHead.eq(0) & phase)
            .named('cpl_writable');
    Sequential(clk, [
      cplBadReg < cplLog.eq(0) | cplWraps,
      cplWrote <
          (writes(registerCplBaseLow ~/ 4) |
                  writes(registerCplBaseHigh ~/ 4) |
                  writes(registerCplSize ~/ 4)) &
              cplWritable,
    ], reset: reset);
    final doneSet = recDone & code.eq(0) & dFlags[1];
    final errSet = recDone & ~code.eq(0) | cplSizeBad;
    final sets = [
      if (irqLines < 7) Const(0, width: causeWidth - causeLineShift - irqLines),
      ?lines,
      Const(0, width: causeLineShift - 2),
      errSet,
      doneSet,
    ].swizzle();
    // A cause event after the last IRQ_CAUSE read is fresh. A W1C does not
    // clear a fresh bit, so the handler cannot clear an event it has not
    // read. For a line, the event is its rising edge.
    final fresh = Logic(name: 'irq_fresh', width: causeWidth);
    final linesPrev = lines == null
        ? null
        : Logic(name: 'irq_lines_prev', width: irqLines);
    final events = [
      if (irqLines < 7) Const(0, width: causeWidth - causeLineShift - irqLines),
      if (lines != null) lines & ~linesPrev!,
      Const(0, width: causeLineShift - 2),
      errSet,
      doneSet,
    ].swizzle();
    // A read clears the fresh bits only in the bytes it reads. A zero length
    // read (first byte enable 0) reads nothing.
    final rBe = mux(
      cG.eq(0),
      cFirstBe,
      mux((cG.zeroExtend(6) + 1).eq(cDw), cLastBe, Const(0xf, width: 4)),
    ).named('reg_r_be');
    final causeRead =
        (cState.eq(cGather) &
                rBe.or() &
                rAddr.eq(Const(registerIrqCause ~/ 4, width: 10)))
            .named('irq_cause_read');
    final readBits = [
      for (var i = 3; i >= 0; i--) (causeRead & rBe[i]).replicate(8),
    ].swizzle().slice(causeWidth - 1, 0).named('irq_cause_read_bits');
    final freshNext = ((fresh & ~readBits) | events).named('irq_fresh_next');
    final clears = mux(
      writes(registerIrqCause ~/ 4),
      (wData & wMask).slice(causeWidth - 1, 0) & ~fresh,
      Const(0, width: causeWidth),
    );
    final causeNext = ((cause & ~clears) | sets).named('cause_next');
    final pend = (cause & mask).named('irq_pend');
    final needLog = irqLines == 0 ? 0 : irqLines.bitLength;
    final split = (msiEnable & msiVectorsGranted.gte(needLog)).named(
      'irq_split',
    );
    // A vector of irq_pending is low for one cycle after a write to
    // IRQ_CAUSE or IRQ_MASK that touches a bit of its group. A cause that is
    // still set then rises again, and the endpoint sends a new MSI for it.
    // Other vectors do not change. With MSI off (INTx), there is no gap, so
    // a write does not send a Deassert and Assert pair.
    final touched = mux(
      writes(registerIrqMask ~/ 4),
      wMask.slice(causeWidth - 1, 0),
      (wData & wMask).slice(causeWidth - 1, 0),
    ).named('irq_touched');
    final irqWrite =
        writes(registerIrqCause ~/ 4) | writes(registerIrqMask ~/ 4);
    final irqGapBits = Logic(name: 'irq_gap_bits', width: causeWidth);
    Sequential(clk, [
      If(
        reset,
        then: [irqGapBits < 0, fresh < 0, if (linesPrev != null) linesPrev < 0],
        orElse: [
          irqGapBits <
              mux(irqWrite & msiEnable, touched, Const(0, width: causeWidth)) &
                  Const(causeBits, width: causeWidth),
          // An engine reset starts the driver again, so it clears fresh.
          fresh <
              mux(
                engReset,
                Const(0, width: causeWidth),
                freshNext & Const(causeBits, width: causeWidth),
              ),
          if (linesPrev != null) linesPrev < lines!,
        ],
      ),
    ]);
    final gap0 = mux(split, irqGapBits[0] | irqGapBits[1], irqGapBits.or());
    addOutput('irq_pending', width: 8) <=
        [
          if (irqLines < 7) Const(0, width: 7 - irqLines),
          for (var i = irqLines - 1; i >= 0; i--)
            split & pend[causeLineShift + i] & ~irqGapBits[causeLineShift + i],
          mux(split, pend[0] | pend[1], pend.or()) & ~gap0,
        ].swizzle();

    // Completion request capture.
    final aByte = [hdrDw.slice(4, 0), Const(0, width: 2)].swizzle();
    final fe = _firstSet(hdrFirstBe);
    final tailTrim = _lastTrim(mux(hdrLen.eq(1), hdrFirstBe, hdrLastBe));
    final zeroLen = hdrLen.eq(1) & hdrFirstBe.eq(0);
    final byteCount = mux(
      zeroLen,
      Const(1, width: 13),
      (hdrLen.zeroExtend(13) << 2) -
          fe.zeroExtend(13) -
          tailTrim.zeroExtend(13),
    ).named('byte_count');
    final readOk = hdrLen.lte(maxReadDw);
    final cShift = mux(
      (cT + n).lte(3),
      Const(0, width: 3),
      mux(cT.lte(3), Const(1, width: 3), Const(n, width: 3)),
    ).named('c_shift');

    final recLoad = (inState(sRecWait) & ~resetReq & ~cplFull & busMasterEnable)
        .named('rec_load');
    List<Conditional> engineReset() => [
      state < sIdle,
      pushSeq < 0,
      halted < 0,
      errCode < 0,
      overflow < 0,
      qHead < 0,
      qTail < 0,
      qCount < 0,
      cplHead < 0,
      cplTail < 0,
      phase < 1,
      resetReq < 0,
      iBusy < 0,
      dState < dIdle,
      if (ringSource) ...[
        fState < fIdle,
        fErr < 0,
        fInPkt < 0,
        descHead < 0,
        descTail < 0,
        descRung < 0,
      ],
    ];
    final pktBytes = (pktDw.zeroExtend(32) << 2).named('pkt_bytes');

    Sequential(clk, [
      If(
        reset,
        then: [
          enable < 0,
          cause < 0,
          mask < 0,
          cplBase < 0,
          cplLog < 0,
          for (final s in stage) s < 0,
          afterHdr < 0,
          wMode < 0,
          cState < cIdle,
          txLock < 0,
          txOwner < 0,
          selReq < 0,
          selActive < 0,
          descBase < 0,
          descLog < 0,
          code < 0,
          dFlags < 0,
          pktRead < 0,
          pktTag < 0,
          ...engineReset(),
        ],
        orElse: [
          // Register writes.
          If(
            writes(registerControl ~/ 4) & wBe[0],
            then: [
              enable < wData[0],
              If(wData[1], then: [resetReq < 1]),
              if (both) selReq < wData[2],
            ],
          ),
          cause < causeNext & Const(causeBits, width: causeWidth),
          If(
            writes(registerIrqMask ~/ 4),
            then: [mask < merge(mask) & Const(causeBits, width: causeWidth)],
          ),
          If(
            writes(registerCplBaseLow ~/ 4) & cplWritable,
            then: [
              cplBase <
                  [
                    cplBase.slice(63, 32),
                    merge(cplBase.slice(31, 0)).slice(31, 4),
                    Const(0, width: 4),
                  ].swizzle(),
            ],
          ),
          If(
            writes(registerCplBaseHigh ~/ 4) & cplWritable,
            then: [
              cplBase <
                  [
                    merge(cplBase.slice(63, 32)),
                    cplBase.slice(31, 0),
                  ].swizzle(),
            ],
          ),
          If(
            writes(registerCplSize ~/ 4) & cplWritable,
            then: [cplLog < merge(cplLog)],
          ),
          // Ring pointer writes are dropped while an engine reset waits,
          // because the reset clears them.
          If(
            writes(registerCplHead ~/ 4) & ~resetReq,
            then: [cplHead < merge(cplHead)],
          ),
          for (var i = 0; i < stage.length; i++)
            If(
              writes(registerPush ~/ 4 + i),
              then: [stage[i] < merge(stage[i])],
            ),
          if (ringSource) ...[
            If(
              writes(registerDescBaseLow ~/ 4),
              then: [
                descBase <
                    [
                      descBase.slice(63, 32),
                      merge(descBase.slice(31, 0)).slice(31, 5),
                      Const(0, width: 5),
                    ].swizzle(),
              ],
            ),
            If(
              writes(registerDescBaseHigh ~/ 4),
              then: [
                descBase <
                    [
                      merge(descBase.slice(63, 32)),
                      descBase.slice(31, 0),
                    ].swizzle(),
              ],
            ),
            If(writes(registerDescSize ~/ 4), then: [descLog < merge(descLog)]),
            If(
              writes(registerDescTail ~/ 4) & ~resetReq,
              then: [descTail < merge(descTail), descRung < 1],
            ),
          ],
          if (both)
            If(
              selPending &
                  inState(sIdle) &
                  qCount.eq(0) &
                  fState.eq(fIdle) &
                  fErr.eq(0),
              then: [selActive < selReq],
            ),

          // Queue.
          If(push, then: [qTail < qTail + 1]),
          If(fifoPush, then: [pushSeq < pushSeq + 1]),
          // A commit is lost when the queue is full or the ring is the
          // source.
          If(commit & (qFull | ~fifoActive), then: [overflow < 1]),
          If(pop, then: [qHead < qHead + 1]),
          If.block([
            Iff(push & ~pop, [qCount < qCount + 1]),
            ElseIf(pop & ~push, [qCount < qCount - 1]),
          ]),

          // RX packet tracking.
          If(
            hdrFire,
            then: [
              afterHdr < ~rxs.last,
              wMode < isMWr & ~tlpPoisoned(header),
              wLane < 0,
              wFirstBe < hdrFirstBe,
              wLastBe < hdrLastBe,
              If(
                capture.payloadInHeaderBeat,
                then: [wLeft < hdrLen - 1, wAddr < hdrDw + 1, wFirst < 0],
                orElse: [wLeft < hdrLen, wAddr < hdrDw, wFirst < 1],
              ),
            ],
            orElse: [
              If(
                wDo,
                then: [
                  wLeft < wLeft - 1,
                  wAddr < wAddr + 1,
                  wFirst < 0,
                  wLane < mux(wBeatDone, Const(0, width: 2), wLane + 1),
                ],
              ),
              If(afterHdr & rxFire & rxs.last, then: [afterHdr < 0]),
            ],
          ),

          // BAR0 completions.
          Case(cState, [
            CaseItem(Const(cIdle, width: 2), [
              If(
                hdrFire & (isMRd | nonPosted),
                then: [
                  cReqId < tlpRequesterId(header),
                  cTag < tlpTag(header),
                  cTc < header.slice(22, 20),
                  cAttr < header.slice(13, 12),
                  cAddr < hdrDw,
                  cG < 0,
                  cT < 0,
                  If.block([
                    Iff(isMRd & readOk, [
                      cFirstBe < hdrFirstBe,
                      cLastBe < hdrLastBe,
                      cStatus < 0,
                      cDw < hdrLen.slice(5, 0),
                      cByteCount < byteCount.slice(11, 0),
                      cLowAddr < aByte + fe.zeroExtend(7),
                      cState < cGather,
                    ]),
                    ElseIf(isMRd, [
                      cStatus < 4,
                      cDw < 0,
                      cByteCount < byteCount.slice(11, 0),
                      cLowAddr < aByte + fe.zeroExtend(7),
                      cState < cSend,
                    ]),
                    Else([
                      cStatus < 1,
                      cDw < 0,
                      cByteCount < 4,
                      cLowAddr < 0,
                      cState < cSend,
                    ]),
                  ]),
                ],
              ),
            ]),
            CaseItem(Const(cGather, width: 2), [
              for (var i = 0; i < maxReadDw; i++)
                If(cG.eq(i), then: [cData[i] < regValue]),
              If(
                (cG.zeroExtend(6) + 1).eq(cDw),
                then: [cState < cSend],
                orElse: [cG < cG + 1],
              ),
            ]),
            CaseItem(Const(cSend, width: 2), [
              If(
                cFire,
                then: [
                  If(
                    cLast,
                    then: [cState < cIdle],
                    orElse: [
                      cT < cT + n,
                      for (var i = 0; i < maxReadDw; i++)
                        Case(cShift, [
                          for (final k in {1, n})
                            CaseItem(Const(k, width: 3), [
                              cData[i] <
                                  (i + k < maxReadDw
                                      ? cData[i + k]
                                      : Const(0, width: 32)),
                            ]),
                        ]),
                    ],
                  ),
                ],
              ),
            ]),
          ]),

          // TX source hold.
          If(
            txFire,
            then: [
              If(
                txs.last,
                then: [txLock < 0],
                orElse: [txLock < 1, txOwner < pick],
              ),
            ],
            orElse: [
              If(txs.valid, then: [txLock < 1, txOwner < pick]),
            ],
          ),

          if (ringSource) ...fetcher,

          // Engine.
          Case(state, [
            CaseItem(Const(sIdle, width: 4), [
              If.block([
                Iff(resetReq, [If(engReset, then: engineReset())]),
                // A waiting fetch error is reported first, because its
                // record cannot be written either.
                ElseIf(cplSizeBad, [
                  halted < 1,
                  errCode <
                      (ringSource
                          ? mux(
                              fErr.eq(0),
                              Const(errorCplRing, width: 8),
                              fErr.zeroExtend(8),
                            )
                          : Const(errorCplRing, width: 8)),
                ]),
                ElseIf(enable & ~halted & ~cplWrote & ~qCount.eq(0), [
                  state < sLoad,
                ]),
                // A fetch error gets a record after the queue is empty.
                if (ringSource)
                  ElseIf(enable & ~halted & ~cplWrote & ~fErr.eq(0), [
                    dCookie < 0,
                    dFlags < 0,
                    done < 0,
                    // The slot where the fetch failed.
                    dSrc < [Const(1), descHead].swizzle(),
                    code < fErr,
                    state < sRecWait,
                  ]),
              ]),
            ]),
            CaseItem(Const(sLoad, width: 4), [
              hAddr < rdHost,
              lAddr < rdLocal,
              left < rdLen,
              dFlags < rdFlags,
              dCookie < rdCookie,
              dSrc < rdSrc,
              dLocalBad < rdLocalHigh,
              done < 0,
              code < 0,
              state < sCheck,
            ]),
            CaseItem(Const(sCheck, width: 4), [
              If.block([
                Iff(
                  hAddr.slice(1, 0).or() |
                      lAddr.slice(1, 0).or() |
                      left.slice(1, 0).or(),
                  [code < errorAlignment, state < sRecWait],
                ),
                ElseIf(left.eq(0), [code < errorZeroLength, state < sRecWait]),
                // The ends are one bit wider than the address, so no range
                // wraps past these checks.
                ElseIf(
                  dLocalBad |
                      localEnd.gt(Const(BigInt.one << aw, width: aw + 33)),
                  [code < errorLocalRange, state < sRecWait],
                ),
                ElseIf(hostWraps, [code < errorHostRange, state < sRecWait]),
                ElseIf(dFlags[0], [state < sChunk]),
                Else([state < sH2d]),
              ]),
            ]),
            CaseItem(Const(sChunk, width: 4), [
              If(
                chunkStale,
                then: [],
                orElse: [
                  pktAddr < hAddr,
                  pktDw < chunkDw,
                  pktRead < 0,
                  pktTag < 0,
                  lane0 < laneOf(lAddr),
                  curAddr < (lAddr & ~Const(beatBytes - 1, width: aw)),
                  beatsLeft <
                      ((laneOf(lAddr).zeroExtend(12) +
                              chunkDw.zeroExtend(12) +
                              (dpb - 1)) >>
                          dpbLog),
                  word < 0,
                  fabErr < 0,
                  state < sReq,
                ],
              ),
            ]),
            CaseItem(Const(sReq, width: 4), [
              If(
                reqFire,
                then: [
                  burstLeft < burst.slice(8, 0),
                  beatsLeft < beatsLeft - burst.slice(11, 0),
                  curAddr < curAddr + (burst.zeroExtend(aw) << sizeLog),
                  state < sRdata,
                ],
              ),
            ]),
            CaseItem(Const(sRdata, width: 4), [
              If(
                rFire,
                then: [
                  word < word + 1,
                  burstLeft < burstLeft - 1,
                  If(mem.rdataErr, then: [fabErr < 1]),
                  If(
                    burstLeft.eq(1),
                    then: [
                      If.block([
                        Iff(fabErr | mem.rdataErr, [
                          code < errorFabric,
                          state < sRecWait,
                        ]),
                        ElseIf(beatsLeft.eq(0), [state < sTxWait]),
                        Else([state < sReq]),
                      ]),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sTxWait, width: 4), [
              If.block([
                Iff(resetReq, [If(engReset, then: engineReset())]),
                ElseIf(busMasterEnable, [
                  txT < 0,
                  txBase < lane0.zeroExtend(idxW) - hdrDws.slice(idxW - 1, 0),
                  state < sTx,
                ]),
              ]),
            ]),
            CaseItem(Const(sTx, width: 4), [
              If(
                eFire,
                then: [
                  If(
                    eLast,
                    then: [
                      hAddr < hAddr + pktBytes.zeroExtend(64),
                      lAddr <
                          lAddr +
                              pktBytes
                                  .slice(aw > 32 ? 31 : aw - 1, 0)
                                  .zeroExtend(aw),
                      left < left - pktBytes,
                      done < done + pktBytes,
                      If(
                        left.eq(pktBytes),
                        then: [state < sRecWait],
                        orElse: [state < sChunk],
                      ),
                    ],
                    orElse: [txT < txT + n, txBase < txBase + n],
                  ),
                ],
              ),
              If(engReset, then: engineReset()),
            ]),
            CaseItem(Const(sH2d, width: 4), [
              // After an error the drain still writes the rest of its tag,
              // and that tag counts in bytes done.
              If(
                errNow & code.eq(0),
                then: [
                  code <
                      mux(
                        tags.err,
                        tags.errCode.zeroExtend(8),
                        Const(errorFabric, width: 8),
                      ),
                ],
              ),
              If(
                issueGo,
                then: [
                  pktAddr < hAddr,
                  pktDw < reqBytes.slice(12, 2).zeroExtend(11),
                  pktRead < 1,
                  pktTag < tags.issueTag,
                  txT < 0,
                  iBusy < 1,
                  hAddr < hAddr + reqBytes.zeroExtend(64),
                  lAddr <
                      lAddr +
                          reqBytes
                              .zeroExtend(aw > 13 ? aw : 13)
                              .slice(aw - 1, 0),
                  left < left - reqBytes.zeroExtend(32),
                ],
              ),
              If(
                iBusy & eFire,
                then: [
                  If(eLast, then: [iBusy < 0], orElse: [txT < txT + n]),
                ],
              ),
              Case(dState, [
                CaseItem(Const(dIdle, width: 3), [
                  If(
                    code.eq(0) &
                        ~errNow &
                        ~tags.errAhead &
                        ~resetReq &
                        tags.headReady,
                    then: [
                      dSlot < tags.headSlot,
                      dLen < tags.headLen,
                      lane0 < headLane,
                      curAddr <
                          (tags.headLocal & ~Const(beatBytes - 1, width: aw)),
                      beatsLeft <
                          ((headLane.zeroExtend(12) +
                                  tags.headLen.slice(12, 2).zeroExtend(12) +
                                  (dpb - 1)) >>
                              dpbLog),
                      wBeat < 0,
                      dState < dReq,
                    ],
                  ),
                ]),
                CaseItem(Const(dReq, width: 3), [
                  If(
                    reqFire,
                    then: [
                      burstLeft < burst.slice(8, 0),
                      beatsLeft < beatsLeft - burst.slice(11, 0),
                      curAddr < curAddr + (burst.zeroExtend(aw) << sizeLog),
                      dState < dPrime,
                    ],
                  ),
                ]),
                CaseItem(Const(dPrime, width: 3), [dState < dData]),
                CaseItem(Const(dData, width: 3), [
                  If(
                    wFire,
                    then: [
                      wBeat < wBeat + 1,
                      burstLeft < burstLeft - 1,
                      If(burstLeft.eq(1), then: [dState < dResp]),
                    ],
                  ),
                ]),
                CaseItem(Const(dResp, width: 3), [
                  If(
                    bFire,
                    then: [
                      If.block([
                        Iff(mem.wrespErr, [dState < dIdle]),
                        ElseIf(beatsLeft.eq(0), [
                          done < done + dLen.zeroExtend(32),
                          dState < dIdle,
                        ]),
                        Else([dState < dReq]),
                      ]),
                    ],
                  ),
                ]),
              ]),
              If.block([
                Iff(engReset, engineReset()),
                ElseIf(dSafe & ~code.eq(0), [state < sRecWait]),
                ElseIf(dSafe & code.eq(0) & ~errNow & left.eq(0) & ~tags.busy, [
                  state < sRecWait,
                ]),
              ]),
            ]),
            CaseItem(Const(sRecWait, width: 4), [
              If.block([
                Iff(resetReq, [If(engReset, then: engineReset())]),
                ElseIf(recLoad, [
                  pktAddr < recAddr,
                  pktDw < 4,
                  pktRead < 0,
                  pktTag < 0,
                  lane0 < 0,
                  txT < 0,
                  txBase <
                      Const(0, width: idxW) -
                          mux(
                            recAddr.slice(63, 32).or(),
                            Const(4, width: idxW),
                            Const(3, width: idxW),
                          ),
                  state < sRecTx,
                ]),
              ]),
            ]),
            CaseItem(Const(sRecTx, width: 4), [
              If(
                eFire,
                then: [
                  If(
                    eLast,
                    then: [
                      cplTail < cplNext,
                      If(cplNext.eq(0), then: [phase < ~phase]),
                      If(
                        ~code.eq(0),
                        then: [
                          halted < 1,
                          errCode < code,
                          // At a halt, DESC_HEAD is the failing slot.
                          if (ringSource)
                            If(dSrc[16], then: [descHead < dSrc.slice(15, 0)]),
                        ],
                      ),
                      state < sIdle,
                    ],
                    orElse: [txT < txT + n, txBase < txBase + n],
                  ),
                ],
              ),
              If(engReset, then: engineReset()),
            ]),
          ]),
        ],
      ),
    ]);
  }

  /// Word count and FNV-1a hash, so different tables get different
  /// definition names.
  static String _infoTag(List<int> words) {
    var hash = 0x811c9dc5;
    for (final word in words) {
      for (var shift = 0; shift < 32; shift += 8) {
        hash = ((hash ^ ((word >>> shift) & 0xff)) * 0x01000193) & 0xffffffff;
      }
    }
    return '${words.length}_${hash.toRadixString(16)}';
  }
}
