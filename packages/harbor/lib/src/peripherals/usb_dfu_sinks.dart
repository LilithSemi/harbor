import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/wishbone/wishbone_interface.dart';
import '../clock/cdc.dart';
import 'spi_flash.dart';
import 'usb_dfu_device.dart';

/// DMAs a [HarborUsbDfu] firmware download into RAM over a Wishbone master.
/// Consumes [UsbDfuSinkInterface] (alt setting 0) through a CDC FIFO, so
/// `ready` always reflects real FIFO space.
class UsbDfuRamSink extends BridgeModule {
  static const int _errAddress = 0x08;

  /// The RAM load address that image byte 0 is written to.
  final int loadBase;

  /// Size of the writable region starting at [loadBase], in bytes. A byte
  /// past this raises errADDRESS and is not written.
  final int regionBytes;

  /// Wishbone address bus width.
  final int busAddressWidth;

  /// Wishbone data bus width (8, 16, 32 or 64).
  final int busDataWidth;

  /// Depth of the CDC FIFO (power of two). Sized to hold a full DFU
  /// transfer block with margin so normal streaming never backs up.
  final int fifoDepth;

  /// Number of byte lanes on the bus.
  int get bytesPerWord => busDataWidth ~/ 8;

  UsbDfuRamSink({
    this.loadBase = 0x80000000,
    required this.regionBytes,
    this.busAddressWidth = 32,
    this.busDataWidth = 32,
    this.fifoDepth = 128,
    String? name,
  }) : super('UsbDfuRamSink', name: name ?? 'usb_dfu_ram_sink') {
    if (![8, 16, 32, 64].contains(busDataWidth)) {
      throw ArgumentError(
        'busDataWidth must be one of [8,16,32,64], got $busDataWidth',
      );
    }
    if (busAddressWidth < 1 || busAddressWidth > 64) {
      throw ArgumentError('busAddressWidth out of range: $busAddressWidth');
    }
    if (loadBase < 0 || loadBase >= (BigInt.one << busAddressWidth).toInt()) {
      throw ArgumentError(
        'loadBase 0x${loadBase.toRadixString(16)} does not '
        'fit in $busAddressWidth address bits',
      );
    }
    if (regionBytes <= 0) {
      throw ArgumentError('regionBytes must be > 0');
    }
    if (loadBase + regionBytes > (BigInt.one << busAddressWidth).toInt()) {
      throw ArgumentError(
        'loadBase + regionBytes overflows $busAddressWidth address bits',
      );
    }
    if (fifoDepth < 2 || (fifoDepth & (fifoDepth - 1)) != 0) {
      throw ArgumentError('fifoDepth must be a power of two >= 2');
    }
    // HarborUsbDfu.defaultClearWatchdogLimit is derived for a FIFO no
    // deeper than this. A deeper one needs its own explicit
    // clearWatchdogLimit (see HarborUsbDfu.minClearWatchdogLimit).
    if (fifoDepth > 4096) {
      throw ArgumentError('fifoDepth must be <= 4096, got $fifoDepth');
    }

    final selWidth = bytesPerWord;
    // Log2 of bytesPerWord: how many low address bits are the in-word byte
    // offset (0 for an 8-bit bus).
    var wordShift = 0;
    for (var v = bytesPerWord; v > 1; v >>= 1) {
      wordShift++;
    }

    createPort('usb_clk', PortDirection.input);
    createPort('usb_reset', PortDirection.input);
    createPort('bus_clk', PortDirection.input);
    createPort('bus_reset', PortDirection.input);

    final dfuRef = addInterface(
      UsbDfuSinkInterface(),
      name: 'dfu',
      role: PairRole.consumer,
    );
    final dfu = dfuRef.internalInterface!;

    final busRef = addInterface(
      WishboneInterface(
        WishboneConfig(addressWidth: busAddressWidth, dataWidth: busDataWidth),
      ),
      name: 'bus',
      role: PairRole.provider, // master
    );
    final bus = busRef.internalInterface!;

    addOutput('image_ready');
    addOutput('entry_addr', width: busAddressWidth);
    addOutput('bytes_written', width: 32);

    final usbClk = input('usb_clk');
    final busClk = input('bus_clk');
    // Either reset resets both sides of every crossing, so a lone reset
    // cannot leave one FIFO pointer or toggle behind the other.
    final usbReset = harborCdcJoinReset(
      usbClk,
      input('usb_reset'),
      input('bus_reset'),
      name: 'usb_join_reset',
    );
    final busReset = harborCdcJoinReset(
      busClk,
      input('bus_reset'),
      input('usb_reset'),
      name: 'bus_join_reset',
    );

    // target == 0 selects RAM. Stable for the whole transfer (the DFU
    // device drives it from alt_setting), so no synchronizer is needed.
    final isRam = dfu.target.eq(Const(0, width: 8)).named('ram_is_target');

    // CDC FIFO: {end_marker, byte[7:0]}. Pushed in the USB domain on every
    // accepted byte (valid & ready) of a RAM-targeted stream, plus one
    // marker entry on `end`. Drained in the bus domain in order, so the
    // marker always arrives after every byte that precedes it.
    final fifo = HarborCdcFifo(
      name: 'sink_fifo',
      dataWidth: 9,
      depth: fifoDepth,
      almostFullMargin: 2,
    );
    addSubModule(fifo);

    final pushByte = (dfu.valid & dfu.ready & isRam).named('push_byte');
    final pushEnd = (dfu.end & isRam).named('push_end');
    final wrEn = (pushByte | pushEnd).named('fifo_wr_en');
    final bothPush = (pushByte & pushEnd).named('both_push_invariant');
    bothPush.changed.listen((e) {
      assert(
        !(e.newValue.isValid && e.newValue.toBool()),
        'UsbDfuRamSink: a data byte and the end marker landed on the same '
        'cycle, which the sink interface never does',
      );
    });
    final isEndEntry = (pushEnd & ~pushByte).named('is_end_entry');
    final wrData = [isEndEntry, dfu.data].swizzle();

    fifo.input('wr_clk').srcConnection! <= usbClk;
    fifo.input('wr_reset').srcConnection! <= usbReset;
    fifo.input('wr_data').srcConnection! <= wrData;
    fifo.input('wr_en').srcConnection! <= wrEn;
    fifo.input('rd_clk').srcConnection! <= busClk;
    fifo.input('rd_reset').srcConnection! <= busReset;

    final fifoAlmostFull = fifo.output('wr_almost_full');
    dfu.ready <= ~fifoAlmostFull;

    final fifoEmpty = fifo.output('rd_empty');
    final fifoRdData = fifo.output('rd_data'); // first-word-fall-through
    final fifoByte = fifoRdData.slice(7, 0);
    final fifoIsEnd = fifoRdData.slice(8, 8);

    // dfu.clear crosses USB -> bus as a toggle, edge-detected after the
    // bus domain syncs it. The device holds sink.valid low from `clear`
    // until `clearDone` answers, so nothing new enters the FIFO while the
    // bus domain drains it below.
    final clearToggleUsb = Logic(name: 'clear_toggle_usb_q');
    Sequential(usbClk, [
      If(
        usbReset,
        then: [clearToggleUsb < Const(0)],
        orElse: [
          If(dfu.clear, then: [clearToggleUsb < ~clearToggleUsb]),
        ],
      ),
    ]);
    final clearSync = HarborCdcSync(name: 'clear_sync');
    addSubModule(clearSync);
    clearSync.input('async_in').srcConnection! <= clearToggleUsb;
    clearSync.input('dst_clk').srcConnection! <= busClk;
    clearSync.input('dst_reset').srcConnection! <= busReset;
    final clearTogglePrevBus = Logic(name: 'clear_toggle_prev_bus_q');
    Sequential(busClk, [
      If(
        busReset,
        then: [clearTogglePrevBus < Const(0)],
        orElse: [clearTogglePrevBus < clearSync.output('sync_out')],
      ),
    ]);
    final clearPulseBus = (clearSync.output('sync_out') ^ clearTogglePrevBus)
        .named('clear_pulse_bus');

    // Bus write FSM (bus domain). Single write at a time, byte granular.
    const stIdle = 0; // FIFO empty / classify the next entry.
    const stWrite = 1; // driving a Wishbone single write, waiting for ack.
    const stPop = 2; // one-cycle gap for the FWFT head to advance.
    const stClearDrain = 3; // clear requested: discard everything queued.
    const stClearPop = 4; // one-cycle gap while draining.

    final fsm = Logic(name: 'sink_fsm', width: 3);
    final byteOff = Logic(name: 'byte_off', width: 32); // bytes written so far
    // Latched the cycle `clear` crosses in. Consumed (and the drain
    // entered) only once the FSM is back at a safe boundary: immediately
    // if already idle, or after any write already in flight gets its ack,
    // never by aborting a Wishbone cycle mid-flight.
    final pendingClearBus = Logic(name: 'pending_clear_bus_q');

    final cycReg = Logic(name: 'cyc_reg');
    final stbReg = Logic(name: 'stb_reg');
    final weReg = Logic(name: 'we_reg');
    final adrReg = Logic(name: 'adr_reg', width: busAddressWidth);
    final datReg = Logic(name: 'dat_reg', width: busDataWidth);
    final selReg = Logic(name: 'sel_reg', width: selWidth);
    final rdEnReg = Logic(name: 'rd_en_reg');
    final imageReadyReg = Logic(name: 'image_ready_reg');
    final errBus = Logic(name: 'err_bus_q'); // sticky address error (parks)
    final doneToggleBus = Logic(name: 'done_toggle_bus_q');
    final errToggleBus = Logic(name: 'err_toggle_bus_q');
    final clearAckToggleBus = Logic(name: 'clear_ack_toggle_bus_q');

    final outOfRegion = byteOff
        .gte(Const(regionBytes, width: 32))
        .named('out_of_region');

    // Combinational geometry for the byte currently at the FIFO head.
    final laneSel = bytesPerWord == 1
        ? Const(0, width: 1)
        : byteOff.slice(wordShift - 1, 0);
    Logic selMask = Const(1, width: selWidth);
    if (selWidth > 1) {
      selMask = (Const(1, width: selWidth) << laneSel.zeroExtend(selWidth))
          .named('sel_mask');
    }
    final laneShiftBits = (laneSel.zeroExtend(32) * Const(8, width: 32)).named(
      'lane_shift_bits',
    );
    final datPlaced = bytesPerWord == 1
        ? fifoByte
        : (fifoByte.zeroExtend(busDataWidth) <<
                  laneShiftBits.slice(busDataWidth.bitLength - 1, 0))
              .named('dat_placed');
    final wordBase32 = bytesPerWord == 1
        ? byteOff
        : [byteOff.slice(31, wordShift), Const(0, width: wordShift)].swizzle();
    final wordBase = busAddressWidth >= 32
        ? wordBase32.zeroExtend(busAddressWidth)
        : wordBase32.slice(busAddressWidth - 1, 0);
    final adrNext = (Const(loadBase, width: busAddressWidth) + wordBase).named(
      'adr_next',
    );

    Sequential(busClk, [
      If(
        busReset,
        then: [
          fsm < Const(stIdle, width: 3),
          byteOff < Const(0, width: 32),
          // A reset drops a pending clear without an ack. HarborUsbDfu's
          // watchdog then fails to dfuERROR, and the next CLRSTATUS
          // recovers.
          pendingClearBus < Const(0),
          cycReg < Const(0),
          stbReg < Const(0),
          weReg < Const(0),
          adrReg < Const(0, width: busAddressWidth),
          datReg < Const(0, width: busDataWidth),
          selReg < Const(0, width: selWidth),
          rdEnReg < Const(0),
          imageReadyReg < Const(0),
          errBus < Const(0),
          doneToggleBus < Const(0),
          errToggleBus < Const(0),
          clearAckToggleBus < Const(0),
        ],
        orElse: [
          imageReadyReg < Const(0),
          rdEnReg < Const(0),
          If(clearPulseBus, then: [pendingClearBus < Const(1)]),
          Case(fsm, [
            CaseItem(Const(stIdle, width: 3), [
              If(
                pendingClearBus,
                then: [
                  pendingClearBus < Const(0),
                  fsm < Const(stClearDrain, width: 3),
                ],
                orElse: [
                  If(
                    ~fifoEmpty,
                    then: [
                      If(
                        fifoIsEnd.eq(Const(1)),
                        then: [
                          // Image complete: pop the marker and always
                          // finish (clearing busy), but skip image_ready
                          // on an already-errored image.
                          rdEnReg < Const(1),
                          doneToggleBus < ~doneToggleBus,
                          If(~errBus, then: [imageReadyReg < Const(1)]),
                          fsm < Const(stPop, width: 3),
                        ],
                        orElse: [
                          If(
                            errBus | outOfRegion,
                            then: [
                              // Past the region (or already erroring): drop
                              // the byte instead of writing it.
                              If(
                                outOfRegion & ~errBus,
                                then: [
                                  errBus < Const(1),
                                  errToggleBus < ~errToggleBus,
                                ],
                              ),
                              rdEnReg < Const(1),
                              fsm < Const(stPop, width: 3),
                            ],
                            orElse: [
                              cycReg < Const(1),
                              stbReg < Const(1),
                              weReg < Const(1),
                              adrReg < adrNext,
                              datReg < datPlaced,
                              selReg < selMask,
                              fsm < Const(stWrite, width: 3),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(stWrite, width: 3), [
              If(
                bus.ack,
                then: [
                  cycReg < Const(0),
                  stbReg < Const(0),
                  weReg < Const(0),
                  byteOff < byteOff + Const(1, width: 32),
                  rdEnReg < Const(1),
                  fsm < Const(stPop, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(stPop, width: 3), [fsm < Const(stIdle, width: 3)]),
            // clear: discard every byte and marker left queued (an old
            // image's, or the sink's own tail), then reset per-image
            // state and tell the USB domain it is safe to resume.
            CaseItem(Const(stClearDrain, width: 3), [
              If(
                ~fifoEmpty,
                then: [rdEnReg < Const(1), fsm < Const(stClearPop, width: 3)],
                orElse: [
                  byteOff < Const(0, width: 32),
                  errBus < Const(0),
                  clearAckToggleBus < ~clearAckToggleBus,
                  fsm < Const(stIdle, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(stClearPop, width: 3), [
              fsm < Const(stClearDrain, width: 3),
            ]),
          ]),
        ],
      ),
    ]);

    bus.cyc <= cycReg;
    bus.stb <= stbReg;
    bus.we <= weReg;
    bus.adr <= adrReg;
    bus.datMosi <= datReg;
    bus.sel <= selReg;

    fifo.input('rd_en').srcConnection! <= rdEnReg;

    output('image_ready') <= imageReadyReg;
    output('entry_addr') <= Const(loadBase, width: busAddressWidth);
    output('bytes_written') <= byteOff;

    // Cross `done` and the first address error as toggles, not raw
    // pulses: the bus domain flips a bit on each event, the USB domain
    // edge-detects the synced toggle into a one-cycle pulse. `error` must
    // pulse, not stay high, since the device latches it into dfuStatus
    // and a held-high error would re-trigger dfuERROR right after
    // CLRSTATUS clears it.
    final doneSync = HarborCdcSync(name: 'done_sync');
    addSubModule(doneSync);
    doneSync.input('async_in').srcConnection! <= doneToggleBus;
    doneSync.input('dst_clk').srcConnection! <= usbClk;
    doneSync.input('dst_reset').srcConnection! <= usbReset;
    final doneTogglePrevUsb = Logic(name: 'done_toggle_prev_usb_q');
    Sequential(usbClk, [
      If(
        usbReset,
        then: [doneTogglePrevUsb < Const(0)],
        orElse: [doneTogglePrevUsb < doneSync.output('sync_out')],
      ),
    ]);
    final doneUsbPulse = (doneSync.output('sync_out') ^ doneTogglePrevUsb)
        .named('done_usb_pulse');
    dfu.done <= doneUsbPulse;

    final errSync = HarborCdcSync(name: 'err_sync');
    addSubModule(errSync);
    errSync.input('async_in').srcConnection! <= errToggleBus;
    errSync.input('dst_clk').srcConnection! <= usbClk;
    errSync.input('dst_reset').srcConnection! <= usbReset;
    final errTogglePrevUsb = Logic(name: 'err_toggle_prev_usb_q');
    Sequential(usbClk, [
      If(
        usbReset,
        then: [errTogglePrevUsb < Const(0)],
        orElse: [errTogglePrevUsb < errSync.output('sync_out')],
      ),
    ]);
    final errUsbPulse = (errSync.output('sync_out') ^ errTogglePrevUsb).named(
      'err_usb_pulse',
    );
    dfu.error <=
        mux(errUsbPulse, Const(_errAddress, width: 4), Const(0, width: 4));

    // clearAck: bus -> USB, the mirror image of `clear`. Tells the device
    // the drain above has finished and new DNLOAD data is safe to accept.
    final clearAckSync = HarborCdcSync(name: 'clear_ack_sync');
    addSubModule(clearAckSync);
    clearAckSync.input('async_in').srcConnection! <= clearAckToggleBus;
    clearAckSync.input('dst_clk').srcConnection! <= usbClk;
    clearAckSync.input('dst_reset').srcConnection! <= usbReset;
    final clearAckTogglePrevUsb = Logic(name: 'clear_ack_toggle_prev_usb_q');
    Sequential(usbClk, [
      If(
        usbReset,
        then: [clearAckTogglePrevUsb < Const(0)],
        orElse: [clearAckTogglePrevUsb < clearAckSync.output('sync_out')],
      ),
    ]);
    dfu.clearDone <=
        (clearAckSync.output('sync_out') ^ clearAckTogglePrevUsb).named(
          'clear_ack_usb_pulse',
        );

    // busy covers only the final drain after `end`: RAM writes have no
    // per-block commit, so it never rises on block_done.
    final busyUsb = Logic(name: 'busy_usb_q');
    Sequential(usbClk, [
      If(
        usbReset,
        then: [busyUsb < Const(0)],
        orElse: [
          If(dfu.end & isRam, then: [busyUsb < Const(1)]),
          If(doneUsbPulse, then: [busyUsb < Const(0)]),
        ],
      ),
    ]);
    dfu.busy <= busyUsb;
  }
}

/// Programs a [HarborUsbDfu] firmware download into SPI flash by driving a
/// [HarborSpiFlashController]'s write command interface. Consumes
/// [UsbDfuSinkInterface] (alt setting 1). The page buffer flushes when it
/// reaches the end of a flash page and on each `block_done`/`end`, so a
/// program never crosses a page for any block size. A sector is erased
/// only the first time it is touched.
class UsbDfuFlashSink extends BridgeModule {
  static const int _errWrite = 0x03;

  /// The flash byte offset the image's byte 0 is written at. Must be
  /// sector-aligned so erase-as-you-go never clears bytes below the image.
  final int flashBase;

  /// Flash sector size in bytes (erase granularity).
  final int sectorSize;

  /// Flash page size in bytes (program granularity). Only 256 is supported.
  final int pageSize;

  /// Width of the flash write-address bus (`wr_addr`).
  final int addrWidth;

  /// Depth of the CDC FIFO (power of two >= 2).
  final int fifoDepth;

  /// Build a flash sink whose sector/page/address geometry is taken from a
  /// [HarborSpiFlashController]'s config, so the two cannot drift.
  factory UsbDfuFlashSink.fromController(
    HarborSpiFlashController controller, {
    required int flashBase,
    int fifoDepth = 128,
    String? name,
  }) => UsbDfuFlashSink(
    flashBase: flashBase,
    sectorSize: controller.config.sectorSize,
    pageSize: controller.config.pageSize,
    addrWidth: controller.config.addressBytes * 8,
    fifoDepth: fifoDepth,
    name: name,
  );

  UsbDfuFlashSink({
    required this.flashBase,
    this.sectorSize = 4096,
    this.pageSize = 256,
    this.addrWidth = 24,
    this.fifoDepth = 128,
    String? name,
  }) : super('UsbDfuFlashSink', name: name ?? 'usb_dfu_flash_sink') {
    if (pageSize != 256) {
      throw ArgumentError(
        'UsbDfuFlashSink only supports a 256-byte page, got $pageSize',
      );
    }
    if (sectorSize <= 0 || (sectorSize & (sectorSize - 1)) != 0) {
      throw ArgumentError('sectorSize must be a power of two, got $sectorSize');
    }
    if (sectorSize < pageSize) {
      throw ArgumentError(
        'sectorSize ($sectorSize) must be >= pageSize ($pageSize)',
      );
    }
    if (addrWidth != 24 && addrWidth != 32) {
      throw ArgumentError('addrWidth must be 24 or 32, got $addrWidth');
    }
    if (flashBase < 0 || flashBase >= (BigInt.one << addrWidth).toInt()) {
      throw ArgumentError(
        'flashBase 0x${flashBase.toRadixString(16)} does not '
        'fit in $addrWidth address bits',
      );
    }
    if (flashBase % sectorSize != 0) {
      throw ArgumentError(
        'flashBase 0x${flashBase.toRadixString(16)} must be '
        'sector-aligned (sectorSize=$sectorSize)',
      );
    }
    if (fifoDepth < 2 || (fifoDepth & (fifoDepth - 1)) != 0) {
      throw ArgumentError('fifoDepth must be a power of two >= 2');
    }
    // HarborUsbDfu.defaultClearWatchdogLimit is derived for a FIFO no
    // deeper than this. A deeper one needs its own explicit
    // clearWatchdogLimit (see HarborUsbDfu.minClearWatchdogLimit).
    if (fifoDepth > 4096) {
      throw ArgumentError('fifoDepth must be <= 4096, got $fifoDepth');
    }

    // log2(sectorSize): low address bits inside a sector.
    var sectorShift = 0;
    for (var v = sectorSize; v > 1; v >>= 1) {
      sectorShift++;
    }

    createPort('usb_clk', PortDirection.input);
    createPort('usb_reset', PortDirection.input);
    createPort('bus_clk', PortDirection.input);
    createPort('bus_reset', PortDirection.input);

    final dfuRef = addInterface(
      UsbDfuSinkInterface(),
      name: 'dfu',
      role: PairRole.consumer,
    );
    final dfu = dfuRef.internalInterface!;

    // Flash write-engine command interface (drives HarborSpiFlashController).
    addOutput('wr_req');
    addOutput('wr_op'); // 0 = sector-erase, 1 = page-program
    addOutput('wr_addr', width: addrWidth);
    addOutput('wr_len', width: 9); // 1..256 program bytes
    addOutput('wr_data', width: 8); // page-buffer byte at wr_data_index
    createPort('wr_data_index', PortDirection.input, width: 9);
    createPort('wr_busy', PortDirection.input);
    createPort('wr_done', PortDirection.input);
    createPort('wr_err', PortDirection.input);

    addOutput('image_ready'); // 1-cyc pulse when the whole image is programmed
    addOutput('entry_addr', width: addrWidth);
    addOutput('bytes_written', width: 32);

    final usbClk = input('usb_clk');
    final busClk = input('bus_clk');
    // Either reset resets both sides of every crossing, so a lone reset
    // cannot leave one FIFO pointer or toggle behind the other.
    final usbReset = harborCdcJoinReset(
      usbClk,
      input('usb_reset'),
      input('bus_reset'),
      name: 'usb_join_reset',
    );
    final busReset = harborCdcJoinReset(
      busClk,
      input('bus_reset'),
      input('usb_reset'),
      name: 'bus_join_reset',
    );

    final isFlash = dfu.target.eq(Const(1, width: 8)).named('flash_is_target');

    // CDC FIFO: {tag[1:0], byte[7:0]}. tag 0 = data byte, 1 = block_done
    // marker, 2 = end marker. Pushed in the USB domain, drained in the bus
    // domain in order, so a marker always arrives after the bytes before it.
    final fifo = HarborCdcFifo(
      name: 'sink_fifo',
      dataWidth: 10,
      depth: fifoDepth,
      almostFullMargin: 2,
    );
    addSubModule(fifo);

    final pushByte = (dfu.valid & dfu.ready & isFlash).named('push_byte');
    final pushBlockDone = (dfu.blockDone & isFlash).named('push_block_done');
    final pushEnd = (dfu.end & isFlash).named('push_end');
    final wrEn = (pushByte | pushBlockDone | pushEnd).named('fifo_wr_en');
    final morePush =
        ((pushByte & pushBlockDone) |
                (pushByte & pushEnd) |
                (pushBlockDone & pushEnd))
            .named('more_than_one_push_invariant');
    morePush.changed.listen((e) {
      assert(
        !(e.newValue.isValid && e.newValue.toBool()),
        'UsbDfuFlashSink: a byte and a marker landed on the same cycle, '
        'which the sink interface never does',
      );
    });
    final tag = mux(
      pushEnd,
      Const(2, width: 2),
      mux(pushBlockDone, Const(1, width: 2), Const(0, width: 2)),
    );
    final wrData = [tag, dfu.data].swizzle();

    fifo.input('wr_clk').srcConnection! <= usbClk;
    fifo.input('wr_reset').srcConnection! <= usbReset;
    fifo.input('wr_data').srcConnection! <= wrData;
    fifo.input('wr_en').srcConnection! <= wrEn;
    fifo.input('rd_clk').srcConnection! <= busClk;
    fifo.input('rd_reset').srcConnection! <= busReset;

    final fifoAlmostFull = fifo.output('wr_almost_full');
    dfu.ready <= ~fifoAlmostFull;

    final fifoEmpty = fifo.output('rd_empty');
    final fifoRdData = fifo.output('rd_data'); // first-word-fall-through
    final fifoByte = fifoRdData.slice(7, 0);
    final fifoTag = fifoRdData.slice(9, 8);
    final fifoIsByte = fifoTag.eq(Const(0, width: 2));
    final fifoIsBlockDone = fifoTag.eq(Const(1, width: 2));
    final fifoIsEnd = fifoTag.eq(Const(2, width: 2));

    // dfu.clear crosses USB -> bus the same way: a toggle flipped on every
    // pulse, edge-detected after the bus domain syncs it, so a fresh image
    // (or a CLRSTATUS/ABORT recovery) always resets the page buffer state
    // and the sticky error, never leaving a stale image_ready suppressed.
    final clearToggleUsb = Logic(name: 'clear_toggle_usb_q');
    Sequential(usbClk, [
      If(
        usbReset,
        then: [clearToggleUsb < Const(0)],
        orElse: [
          If(dfu.clear, then: [clearToggleUsb < ~clearToggleUsb]),
        ],
      ),
    ]);
    final clearSync = HarborCdcSync(name: 'clear_sync');
    addSubModule(clearSync);
    clearSync.input('async_in').srcConnection! <= clearToggleUsb;
    clearSync.input('dst_clk').srcConnection! <= busClk;
    clearSync.input('dst_reset').srcConnection! <= busReset;
    final clearTogglePrevBus = Logic(name: 'clear_toggle_prev_bus_q');
    Sequential(busClk, [
      If(
        busReset,
        then: [clearTogglePrevBus < Const(0)],
        orElse: [clearTogglePrevBus < clearSync.output('sync_out')],
      ),
    ]);
    final clearPulseBus = (clearSync.output('sync_out') ^ clearTogglePrevBus)
        .named('clear_pulse_bus');

    const stFill = 0; // accumulate FIFO bytes into the page buffer
    const stPop = 1; // one-cycle gap for the FWFT head to advance
    const stEraseReq = 2; // assert wr_req (erase), hold until wr_busy rises
    const stEraseWait = 3; // wait for wr_done of the erase
    const stProgReq = 4; // assert wr_req (program), hold until wr_busy rises
    const stProgWait = 5; // wait for wr_done of the program
    const stFinish = 6; // pop the end marker, pulse image_ready
    const stError = 7; // a write op failed: park (sticky error already set)
    const stClearDrain = 8; // clear requested: discard everything queued
    const stClearPop = 9; // one-cycle gap while draining

    final fsm = Logic(name: 'flash_fsm', width: 4);
    // Latched the cycle `clear` crosses in. Consumed only from stFill or
    // stError, both guaranteed to have no wr_req in flight, never by
    // aborting an erase or program already running.
    final pendingClearBus = Logic(name: 'pending_clear_bus_q');

    final pageBuf = [
      for (var i = 0; i < pageSize; i++) Logic(name: 'page_$i', width: 8),
    ];
    final fillCount = Logic(name: 'fill_count', width: 9);
    final bytesProg = Logic(name: 'bytes_prog', width: 32);
    // True once a flush is needed before the pending marker can be popped:
    // a block_done or end marker reached the head while fillCount > 0.
    final flushThenPop = Logic(name: 'flush_then_pop');
    // What to do once the flush (if any) completes: pop a block_done marker
    // and pulse done, or finish the whole image.
    final pendingIsEnd = Logic(name: 'pending_is_end');
    final lastSector = Logic(name: 'last_sector', width: 32);
    final haveErased = Logic(name: 'have_erased');

    final reqReg = Logic(name: 'wr_req_reg');
    final opReg = Logic(name: 'wr_op_reg');
    final addrReg = Logic(name: 'wr_addr_reg', width: addrWidth);
    final lenReg = Logic(name: 'wr_len_reg', width: 9);
    final rdEnReg = Logic(name: 'rd_en_reg');
    final imageReadyReg = Logic(name: 'image_ready_reg');
    final errBus = Logic(name: 'error_bus_q'); // sticky
    final doneToggleBus = Logic(name: 'done_toggle_bus_q');
    final errToggleBus = Logic(name: 'err_toggle_bus_q');
    final clearAckToggleBus = Logic(name: 'clear_ack_toggle_bus_q');
    // wr_err stays high until the write engine's own next accepted
    // request, outliving a `clear`. Edge-detect it so a stale wr_err left
    // over from the errored op can never look like a fresh failure once
    // `clear` has reset errBus to 0.
    final wrErrPrevBus = Logic(name: 'wr_err_prev_bus_q');

    final wrBusy = input('wr_busy');
    final wrDone = input('wr_done');
    final wrErr = input('wr_err');

    final pageStart = (Const(flashBase, width: 32) + bytesProg)
        .slice(addrWidth - 1, 0)
        .named('page_start');
    final curSector = (Const(flashBase, width: 32) + bytesProg).getRange(0, 32);
    final curSectorIdx = curSector
        .slice(31, sectorShift)
        .zeroExtend(32)
        .named('cur_sector');
    // True only the first time a sector is touched. A program never crosses
    // a page, and a page never crosses a sector.
    final needErase = (~haveErased | ~curSectorIdx.eq(lastSector)).named(
      'need_erase',
    );
    // flashBase is sector aligned, so the low bits of bytesProg give the
    // page offset where the buffered bytes start.
    final pageFull =
        (bytesProg.slice(7, 0).zeroExtend(10) + fillCount.zeroExtend(10))
            .eq(Const(pageSize, width: 10))
            .named('page_full');

    final wrIdx = input('wr_data_index');
    Logic dataMux = Const(0, width: 8);
    for (var i = 0; i < pageSize; i++) {
      dataMux = mux(wrIdx.eq(Const(i, width: 9)), pageBuf[i], dataMux);
    }
    output('wr_data') <= dataMux;

    final haveByte = ~fifoEmpty & fifoIsByte;

    // The write engine can answer a request with wr_done and no wr_busy,
    // for example when it rejects a program. These actions run on wr_done
    // from either the request state or the wait state. ROHD needs a new
    // copy of a conditional for each place it is used.
    List<Conditional> eraseDone() => [
      If(
        wrErr,
        then: [fsm < Const(stError, width: 4)],
        orElse: [
          lastSector < curSectorIdx,
          haveErased < Const(1),
          fsm < Const(stProgReq, width: 4),
        ],
      ),
    ];
    List<Conditional> progDone() => [
      If(
        wrErr,
        then: [fsm < Const(stError, width: 4)],
        orElse: [
          bytesProg < bytesProg + fillCount.zeroExtend(32),
          fillCount < Const(0, width: 9),
          If(
            flushThenPop,
            then: [fsm < Const(stFinish, width: 4)],
            orElse: [fsm < Const(stFill, width: 4)],
          ),
        ],
      ),
    ];
    final haveMarker = ~fifoEmpty & (fifoIsBlockDone | fifoIsEnd);

    Sequential(busClk, [
      If(
        busReset,
        then: [
          fsm < Const(stFill, width: 4),
          for (final b in pageBuf) b < Const(0, width: 8),
          fillCount < Const(0, width: 9),
          bytesProg < Const(0, width: 32),
          flushThenPop < Const(0),
          pendingIsEnd < Const(0),
          lastSector < Const(0, width: 32),
          haveErased < Const(0),
          reqReg < Const(0),
          opReg < Const(0),
          addrReg < Const(0, width: addrWidth),
          lenReg < Const(0, width: 9),
          rdEnReg < Const(0),
          imageReadyReg < Const(0),
          errBus < Const(0),
          doneToggleBus < Const(0),
          errToggleBus < Const(0),
          wrErrPrevBus < Const(0),
          // A reset drops a pending clear without an ack. HarborUsbDfu's
          // watchdog then fails to dfuERROR, and the next CLRSTATUS
          // recovers.
          pendingClearBus < Const(0),
          clearAckToggleBus < Const(0),
        ],
        orElse: [
          imageReadyReg < Const(0),
          rdEnReg < Const(0),
          wrErrPrevBus < wrErr,
          If(clearPulseBus, then: [pendingClearBus < Const(1)]),

          // A failed write op finishes (clears busy) and raises error, on
          // wr_err's rising edge only: level-testing it would re-fire on
          // the stale wr_err still held after a later `clear`.
          If(
            wrErr & ~wrErrPrevBus,
            then: [
              errBus < Const(1),
              errToggleBus < ~errToggleBus,
              doneToggleBus < ~doneToggleBus,
            ],
          ),

          Case(fsm, [
            CaseItem(Const(stFill, width: 4), [
              If(
                pendingClearBus,
                then: [
                  pendingClearBus < Const(0),
                  fsm < Const(stClearDrain, width: 4),
                ],
                orElse: [
                  If(
                    errBus,
                    then: [fsm < Const(stError, width: 4)],
                    orElse: [
                      If(
                        pageFull,
                        then: [
                          If(
                            needErase,
                            then: [fsm < Const(stEraseReq, width: 4)],
                            orElse: [fsm < Const(stProgReq, width: 4)],
                          ),
                        ],
                        orElse: [
                          If(
                            haveByte,
                            then: [
                              for (var i = 0; i < pageSize; i++)
                                If(
                                  fillCount.eq(Const(i, width: 9)),
                                  then: [pageBuf[i] < fifoByte],
                                ),
                              fillCount < fillCount + 1,
                              rdEnReg < Const(1),
                              fsm < Const(stPop, width: 4),
                            ],
                            orElse: [
                              If(
                                haveMarker,
                                then: [
                                  If(
                                    fillCount.gt(Const(0, width: 9)),
                                    then: [
                                      flushThenPop < Const(1),
                                      pendingIsEnd < fifoIsEnd,
                                      If(
                                        needErase,
                                        then: [
                                          fsm < Const(stEraseReq, width: 4),
                                        ],
                                        orElse: [
                                          fsm < Const(stProgReq, width: 4),
                                        ],
                                      ),
                                    ],
                                    orElse: [
                                      // Nothing buffered: pop the marker now.
                                      rdEnReg < Const(1),
                                      If(
                                        fifoIsEnd,
                                        then: [
                                          imageReadyReg < Const(1),
                                          doneToggleBus < ~doneToggleBus,
                                        ],
                                        orElse: [
                                          doneToggleBus < ~doneToggleBus,
                                        ],
                                      ),
                                      fsm < Const(stPop, width: 4),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),

            CaseItem(Const(stPop, width: 4), [fsm < Const(stFill, width: 4)]),

            CaseItem(Const(stEraseReq, width: 4), [
              reqReg < Const(1),
              opReg < Const(0), // sector-erase
              addrReg <
                  [
                    pageStart.slice(addrWidth - 1, sectorShift),
                    Const(0, width: sectorShift),
                  ].swizzle(),
              lenReg < Const(0, width: 9),
              If(
                wrBusy,
                then: [reqReg < Const(0), fsm < Const(stEraseWait, width: 4)],
                orElse: [
                  If(wrDone, then: [reqReg < Const(0), ...eraseDone()]),
                ],
              ),
            ]),

            CaseItem(Const(stEraseWait, width: 4), [
              If(wrDone, then: eraseDone()),
            ]),

            CaseItem(Const(stProgReq, width: 4), [
              reqReg < Const(1),
              opReg < Const(1), // page-program
              addrReg < pageStart,
              lenReg < fillCount,
              If(
                wrBusy,
                then: [reqReg < Const(0), fsm < Const(stProgWait, width: 4)],
                orElse: [
                  If(wrDone, then: [reqReg < Const(0), ...progDone()]),
                ],
              ),
            ]),

            CaseItem(Const(stProgWait, width: 4), [
              If(wrDone, then: progDone()),
            ]),

            CaseItem(Const(stFinish, width: 4), [
              rdEnReg < Const(1), // pop the block_done/end marker
              flushThenPop < Const(0),
              If(pendingIsEnd, then: [imageReadyReg < Const(1)]),
              doneToggleBus < ~doneToggleBus,
              fsm < Const(stPop, width: 4),
            ]),

            CaseItem(Const(stError, width: 4), [
              If(
                pendingClearBus,
                then: [
                  pendingClearBus < Const(0),
                  fsm < Const(stClearDrain, width: 4),
                ],
                orElse: [reqReg < Const(0)],
              ),
            ]),

            // clear: discard every byte and marker left queued (an old
            // image's, including one stuck behind a parked wr_err), then
            // reset per-image state and tell the USB domain it is safe
            // to resume.
            CaseItem(Const(stClearDrain, width: 4), [
              If(
                ~fifoEmpty,
                then: [rdEnReg < Const(1), fsm < Const(stClearPop, width: 4)],
                orElse: [
                  fillCount < Const(0, width: 9),
                  bytesProg < Const(0, width: 32),
                  flushThenPop < Const(0),
                  pendingIsEnd < Const(0),
                  lastSector < Const(0, width: 32),
                  haveErased < Const(0),
                  errBus < Const(0),
                  clearAckToggleBus < ~clearAckToggleBus,
                  fsm < Const(stFill, width: 4),
                ],
              ),
            ]),
            CaseItem(Const(stClearPop, width: 4), [
              fsm < Const(stClearDrain, width: 4),
            ]),
          ]),
        ],
      ),
    ]);

    output('wr_req') <= reqReg;
    output('wr_op') <= opReg;
    output('wr_addr') <= addrReg;
    output('wr_len') <= lenReg;

    fifo.input('rd_en').srcConnection! <= rdEnReg;

    output('image_ready') <= imageReadyReg;
    output('entry_addr') <= Const(flashBase, width: addrWidth);
    output('bytes_written') <= bytesProg;

    // Cross `done` and the first write error as toggles, not raw
    // pulses: the bus domain flips a bit on each event, the USB domain
    // edge-detects the synced toggle into a one-cycle pulse. `error` must
    // pulse, not stay high, since the device latches it into dfuStatus
    // and a held-high error would re-trigger dfuERROR right after
    // CLRSTATUS clears it.
    final doneSync = HarborCdcSync(name: 'done_sync');
    addSubModule(doneSync);
    doneSync.input('async_in').srcConnection! <= doneToggleBus;
    doneSync.input('dst_clk').srcConnection! <= usbClk;
    doneSync.input('dst_reset').srcConnection! <= usbReset;
    final doneTogglePrevUsb = Logic(name: 'done_toggle_prev_usb_q');
    Sequential(usbClk, [
      If(
        usbReset,
        then: [doneTogglePrevUsb < Const(0)],
        orElse: [doneTogglePrevUsb < doneSync.output('sync_out')],
      ),
    ]);
    final doneUsbPulse = (doneSync.output('sync_out') ^ doneTogglePrevUsb)
        .named('done_usb_pulse');
    dfu.done <= doneUsbPulse;

    final errSync = HarborCdcSync(name: 'err_sync');
    addSubModule(errSync);
    errSync.input('async_in').srcConnection! <= errToggleBus;
    errSync.input('dst_clk').srcConnection! <= usbClk;
    errSync.input('dst_reset').srcConnection! <= usbReset;
    final errTogglePrevUsb = Logic(name: 'err_toggle_prev_usb_q');
    Sequential(usbClk, [
      If(
        usbReset,
        then: [errTogglePrevUsb < Const(0)],
        orElse: [errTogglePrevUsb < errSync.output('sync_out')],
      ),
    ]);
    final errUsbPulse = (errSync.output('sync_out') ^ errTogglePrevUsb).named(
      'err_usb_pulse',
    );
    dfu.error <=
        mux(errUsbPulse, Const(_errWrite, width: 4), Const(0, width: 4));

    // clearAck: bus -> USB, the mirror image of `clear`. Tells the device
    // the drain above has finished and new DNLOAD data is safe to accept.
    final clearAckSync = HarborCdcSync(name: 'clear_ack_sync');
    addSubModule(clearAckSync);
    clearAckSync.input('async_in').srcConnection! <= clearAckToggleBus;
    clearAckSync.input('dst_clk').srcConnection! <= usbClk;
    clearAckSync.input('dst_reset').srcConnection! <= usbReset;
    final clearAckTogglePrevUsb = Logic(name: 'clear_ack_toggle_prev_usb_q');
    Sequential(usbClk, [
      If(
        usbReset,
        then: [clearAckTogglePrevUsb < Const(0)],
        orElse: [clearAckTogglePrevUsb < clearAckSync.output('sync_out')],
      ),
    ]);
    dfu.clearDone <=
        (clearAckSync.output('sync_out') ^ clearAckTogglePrevUsb).named(
          'clear_ack_usb_pulse',
        );

    // busy rises on block_done or end and falls once that event's marker
    // has drained: almost instantly if no flush was needed, or for the
    // whole erase+program if one was.
    final busyUsb = Logic(name: 'busy_usb_q');
    Sequential(usbClk, [
      If(
        usbReset,
        then: [busyUsb < Const(0)],
        orElse: [
          If((dfu.blockDone | dfu.end) & isFlash, then: [busyUsb < Const(1)]),
          If(doneUsbPulse, then: [busyUsb < Const(0)]),
        ],
      ),
    ]);
    dfu.busy <= busyUsb;
  }
}
