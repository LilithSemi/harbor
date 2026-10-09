/// A USB DFU 1.1 device that plugs into [HarborUsbCore]'s function
/// interface. [HarborUsbDfu] serves the DFU class requests (DNLOAD,
/// GETSTATUS, CLRSTATUS, GETSTATE, ABORT) and streams a firmware download
/// into a sink (RAM or SPI flash) through [UsbDfuSinkInterface]. Standard
/// requests, including GET_DESCRIPTOR of the descriptors built by
/// [HarborUsbDfu.dfuDescriptors], are answered by the core, not here.
///
/// The state machine follows DFU 1.1 section 6.1.2 (the request table) and
/// Appendix A (the state diagram). A short comment cites the section at
/// each transition that is not obvious from the request alone.
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'usb_core.dart';
import 'usb_descriptors.dart';

/// The contract between [HarborUsbDfu] and a firmware sink (RAM or SPI
/// flash). The DFU device is the provider: it streams one data byte per
/// DNLOAD block, tagged with the block number and the target alternate
/// setting. [blockDone] and [end] are two separate signals, never both
/// about the same event:
///   - [blockDone] pulses once a nonzero-length DNLOAD block's last byte
///     has landed, so the sink can start committing that block (for
///     example a flash page program) and raise [busy] while it works.
///   - [end] pulses once for the zero-length DNLOAD that closes the
///     download, so the sink can start manifesting the finished image.
/// The sink is the consumer: [ready] gates the byte stream (so a slow
/// sink cannot lose a byte), [busy] reports that a block commit or the
/// manifestation is still running, and [error] carries a DFU 1.1 Table
/// 6.2 bStatus code the moment a write fails. [done] pulses once when the
/// sink finishes the operation ([blockDone] or [end]) it was busy with.
/// [busy] stays high until that [done] pulse. If [busy] falls with no
/// [done], the device goes to dfuERROR with errUNKNOWN.
class UsbDfuSinkInterface extends PairInterface {
  /// A download data byte, valid while [valid] is high.
  Logic get data => port('data');

  /// High while [data] holds a byte the sink has not taken yet.
  Logic get valid => port('valid');

  /// The wBlockNum of the DNLOAD block [data] belongs to.
  Logic get block => port('block');

  /// The SET_INTERFACE alternate setting of the image being written.
  Logic get target => port('target');

  /// One-cycle strobe: a nonzero-length DNLOAD block's last byte has
  /// landed. Commit it. It never fires for the zero-length DNLOAD.
  Logic get blockDone => port('block_done');

  /// One-cycle strobe: the zero-length DNLOAD that starts manifestation.
  /// It never fires for a block. The port is named `xfer_end` because `end`
  /// is a SystemVerilog keyword.
  Logic get end => port('xfer_end');

  /// High while the sink can accept the next [data] byte.
  Logic get ready => port('ready');

  /// High while the sink is still writing a block or manifesting.
  Logic get busy => port('busy');

  /// Nonzero while the sink reports a DFU 1.1 Table 6.2 bStatus error.
  Logic get error => port('error');

  /// One-cycle strobe: the sink finished the operation it was busy with.
  Logic get done => port('done');

  /// One-cycle strobe: start a fresh image. Reset error, the write
  /// pointer and bytes written, and empty any queued byte or marker left
  /// over from the last image. Pulses on CLRSTATUS, on ABORT, and when a
  /// new download's first block is accepted from dfuIDLE. The device
  /// holds [valid] low and stops acking DNLOAD data until [clearDone].
  Logic get clear => port('clear');

  /// One-cycle strobe: the sink has emptied its queue and reset its
  /// per-image state after [clear]. The device may resume streaming.
  Logic get clearDone => port('clear_done');

  UsbDfuSinkInterface()
    : super(
        portsFromProvider: [
          Logic.port('data', 8),
          Logic.port('valid'),
          Logic.port('block', 16),
          Logic.port('target', 8),
          Logic.port('block_done'),
          Logic.port('xfer_end'),
          Logic.port('clear'),
        ],
        portsFromConsumer: [
          Logic.port('ready'),
          Logic.port('busy'),
          Logic.port('error', 4),
          Logic.port('done'),
          Logic.port('clear_done'),
        ],
      );

  @override
  UsbDfuSinkInterface clone() => UsbDfuSinkInterface();
}

/// USB DFU 1.1 device on [HarborUsbCore]. Serves the DFU class requests on
/// endpoint 0 and streams a firmware download into a [UsbDfuSinkInterface]
/// sink.
class HarborUsbDfu extends BridgeModule {
  /// DFU wTransferSize: the maximum DNLOAD block payload, in bytes. A
  /// DNLOAD with a longer wLength STALLs. Must match the wTransferSize
  /// field in [dfuDescriptors]'s DFU functional descriptor.
  static const int transferSize = 64;

  // DFU 1.1 Table 4.1 bState values. appIDLE/appDETACH are not used: this
  // device is DFU-mode only.
  static const int _dfuIdle = 2;
  static const int _dfuDnloadSync = 3;
  static const int _dfuDnBusy = 4;
  static const int _dfuDnloadIdle = 5;
  static const int _dfuManifestSync = 6;
  static const int _dfuManifest = 7;
  static const int _dfuErrorState = 10;

  // DFU 1.1 Table 6.2 bStatus values this device produces itself. Any other
  // code (errWRITE, errADDRESS, errVERIFY, ...) comes from the sink's own
  // `error` port.
  static const int _statusOk = 0x00;
  static const int _statusErrStalledPkt = 0x0F;
  // Raised when the sink never answers `clear` with `clearDone`: this
  // device gives up waiting, not the sink reporting a write failure.
  static const int _statusErrUnknown = 0x0E;

  // DFU 1.1 6.1.1 bRequest values.
  static const int _reqDnload = 1;
  static const int _reqGetStatus = 3;
  static const int _reqClrStatus = 4;
  static const int _reqGetState = 5;
  static const int _reqAbort = 6;

  /// bwPollTimeout reported, in milliseconds, while a block or the
  /// manifestation is still being written.
  final int pollTimeoutMs;

  /// Default [clearWatchdogLimit]: a sink's `clearDone` takes at most 2
  /// bus-clock cycles per queued FIFO entry to arrive (one to pop, one
  /// gap cycle for the FWFT head to advance). This covers a CDC FIFO up
  /// to 4096 entries deep, a bus clock up to 8x slower than the USB
  /// clock (the slowest ratio this design is meant to support), and a 4x
  /// margin on top: 4096 * 2 * 8 * 4 = 2^18 USB-clock cycles. Same as
  /// `4 * minClearWatchdogLimit(4096, 8)`.
  static const int defaultClearWatchdogLimit = 1 << 18;

  /// The fewest USB-clock cycles any `clear`/`clearDone` round trip can
  /// take, even against an already-idle FIFO: this device's own `clear`
  /// raise plus a two-stage synchronizer each way. A [clearWatchdogLimit]
  /// below this can never see `clearDone` arrive in time, for any sink.
  static const int minClearWatchdogLimitFloor = 8;

  /// The minimum [clearWatchdogLimit] for a sink whose CDC FIFO is
  /// [fifoDepth] entries deep (the power-of-two `fifoDepth` constructor
  /// argument both [UsbDfuRamSink] and [UsbDfuFlashSink] take), behind a
  /// bus clock up to [busToUsbRatio] times slower than the USB clock: 2
  /// cycles per queued entry (one to pop, one FWFT gap), scaled by the
  /// clock ratio. Carries no safety margin of its own, so integrators and
  /// tests that want one scale the result up themselves, the way
  /// [defaultClearWatchdogLimit] scales its own worst case
  /// (`fifoDepth: 4096`, `busToUsbRatio: 8`) by 4x.
  static int minClearWatchdogLimit(int fifoDepth, int busToUsbRatio) {
    if (fifoDepth < 1) {
      throw ArgumentError.value(fifoDepth, 'fifoDepth', 'must be >= 1');
    }
    if (busToUsbRatio < 1) {
      throw ArgumentError.value(busToUsbRatio, 'busToUsbRatio', 'must be >= 1');
    }
    return fifoDepth * 2 * busToUsbRatio;
  }

  /// How many USB-clock cycles [HarborUsbDfu] waits for a sink's
  /// `clearDone` after raising `clear` before giving up. On expiry the
  /// device fails closed into dfuERROR (bStatus 0x0E) rather than
  /// resuming the byte stream. [defaultClearWatchdogLimit] only covers a
  /// sink whose bus clock is no more than 8x slower than the USB clock
  /// and whose CDC FIFO is at most 4096 entries deep (the bound both
  /// [UsbDfuRamSink] and [UsbDfuFlashSink] enforce on their own
  /// `fifoDepth`). Outside that, pass [minClearWatchdogLimit] (scaled up
  /// with margin) explicitly instead. Tests may pass a small value.
  final int clearWatchdogLimit;

  HarborUsbDfu({
    this.pollTimeoutMs = 10,
    this.clearWatchdogLimit = defaultClearWatchdogLimit,
    String? name,
  }) : super('HarborUsbDfu', name: name ?? 'usb_dfu') {
    if (pollTimeoutMs <= 0 || pollTimeoutMs >= (1 << 24)) {
      throw ArgumentError.value(
        pollTimeoutMs,
        'pollTimeoutMs',
        'must be between 1 and ${(1 << 24) - 1}',
      );
    }
    if (clearWatchdogLimit < minClearWatchdogLimitFloor) {
      throw ArgumentError.value(
        clearWatchdogLimit,
        'clearWatchdogLimit',
        'must be >= $minClearWatchdogLimitFloor (cannot drain even an '
            'empty handshake round trip)',
      );
    }

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    addOutput('dfu_state', width: 4);
    addOutput('dfu_status', width: 4);

    final usbRef = addInterface(
      UsbFunctionInterface(),
      name: 'usb',
      role: PairRole.consumer,
    );
    final usb = usbRef.internalInterface!;
    final sinkRef = addInterface(
      UsbDfuSinkInterface(),
      name: 'sink',
      role: PairRole.provider,
    );
    final sink = sinkRef.internalInterface!;

    final clk = input('clk');
    final reset = input('reset');

    // A USB bus reset returns the DFU state machine to its default state,
    // same as a chip reset (DFU 1.1 has no bus-reset rule of its own, but
    // the host always re-enumerates after one, so stale DNLOAD/MANIFEST
    // state must not survive it).
    final combinedReset = (reset | usb.busReset).named('dfu_reset');

    final setupValid = usb.setupValid;
    final setupData = usb.setupData;
    final bmRequestType = setupData.slice(7, 0).named('dfu_bm_request_type');
    final bRequestField = setupData.slice(15, 8).named('dfu_b_request');
    final wValueField = setupData.slice(31, 16).named('dfu_w_value');
    final wLengthField = setupData.slice(63, 48).named('dfu_w_length');

    final isClassReq = bmRequestType
        .slice(6, 5)
        .eq(Const(1, width: 2))
        .named('dfu_is_class');
    final wLengthIsZero = wLengthField
        .eq(Const(0, width: 16))
        .named('dfu_wlen_zero');
    final wLengthTooLong = wLengthField
        .gt(Const(transferSize, width: 16))
        .named('dfu_wlen_too_long');

    final isDnload =
        (isClassReq & bRequestField.eq(Const(_reqDnload, width: 8))).named(
          'dfu_is_dnload',
        );
    final isGetStatusReq =
        (isClassReq & bRequestField.eq(Const(_reqGetStatus, width: 8))).named(
          'dfu_is_getstatus',
        );
    final isClrStatusReq =
        (isClassReq & bRequestField.eq(Const(_reqClrStatus, width: 8))).named(
          'dfu_is_clrstatus',
        );
    final isGetStateReq =
        (isClassReq & bRequestField.eq(Const(_reqGetState, width: 8))).named(
          'dfu_is_getstate',
        );
    final isAbortReq =
        (isClassReq & bRequestField.eq(Const(_reqAbort, width: 8))).named(
          'dfu_is_abort',
        );

    final dfuState = Logic(name: 'dfu_state_reg', width: 4);
    final dfuStateNext = Logic(name: 'dfu_state_next', width: 4);
    final dfuStatus = Logic(name: 'dfu_status_reg', width: 4);
    final dfuStatusNext = Logic(name: 'dfu_status_next', width: 4);

    final inIdle = dfuState.eq(Const(_dfuIdle, width: 4)).named('dfu_in_idle');
    final inDnloadIdle = dfuState
        .eq(Const(_dfuDnloadIdle, width: 4))
        .named('dfu_in_dnload_idle');
    final inError = dfuState
        .eq(Const(_dfuErrorState, width: 4))
        .named('dfu_in_error');

    // DFU 1.1 Appendix A: GETSTATUS and GETSTATE answer from every state.
    // DNLOAD starts a new block only from dfuIDLE or dfuDNLOAD_IDLE. A
    // zero-length DNLOAD from dfuIDLE does not end a download that never
    // started, so it falls to the stall path below instead. A DNLOAD
    // block longer than wTransferSize also STALLs. CLRSTATUS clears
    // dfuERROR. ABORT leaves an idle state.
    final acceptCond =
        (isGetStatusReq |
                isGetStateReq |
                (isClrStatusReq & inError) |
                (isAbortReq & (inIdle | inDnloadIdle)) |
                (isDnload & inIdle & ~wLengthIsZero & ~wLengthTooLong) |
                (isDnload & inDnloadIdle & ~wLengthTooLong))
            .named('dfu_accept_cond');

    usb.setupAccept <= setupValid & acceptCond;
    usb.setupStall <= setupValid & ~acceptCond;

    final sinkErrorNow = sink.error
        .neq(Const(0, width: 4))
        .named('dfu_sink_error_now');

    // Set below, high from the cycle `clear` is raised until `clearDone`
    // answers, or until the watchdog gives up and latches `clearFailedUsb`
    // instead. Declared here so the error-latch block below can tell what
    // a DNLOAD abort was actually waiting on.
    final clearingUsb = Logic(name: 'dfu_clearing_q');
    final clearFailedUsb = Logic(name: 'dfu_clear_failed_q');
    final clearBlocked = (clearingUsb | clearFailedUsb).named(
      'dfu_clear_blocked',
    );

    // Set below, high for the whole OUT data stage of a DNLOAD block.
    // Declared here so the error-latch block can tell a genuine abort of
    // that data stage from the request it would otherwise dispatch.
    final dnloadActive = Logic(name: 'dfu_dnload_active_q');

    // usb_core.dart pulses `ep0Abort` when a new SETUP preempts the
    // DNLOAD OUT data stage mid-block (USB 2.0 8.5.3/9.2.6.4). DFU 1.1
    // 6.1.2 treats an incomplete DNLOAD like any unexpected request:
    // STALL and dfuERROR. `clearBlocked` means the sink is the root
    // cause, so this reports errUNKNOWN, the same code the watchdog
    // below reports on its own. Any other mid-block abort reports
    // errSTALLEDPKT.
    final dnloadAbortedNow = (usb.ep0Abort & dnloadActive).named(
      'dfu_dnload_aborted_now',
    );
    final dnloadAbortedByClear = (dnloadAbortedNow & clearBlocked).named(
      'dfu_dnload_aborted_by_clear',
    );

    // A sink holds busy from block_done or end until its done pulse. In
    // dfuDNBUSY or dfuMANIFEST, busy low with no done means the sink was
    // reset under the device, so the device fails closed.
    final sinkLostNow =
        ((dfuState.eq(Const(_dfuDnBusy, width: 4)) |
                    dfuState.eq(Const(_dfuManifest, width: 4))) &
                ~sink.busy &
                ~sink.done)
            .named('dfu_sink_lost_now');

    Combinational([
      dfuStateNext < dfuState,
      dfuStatusNext < dfuStatus,
      If(
        (sinkErrorNow | clearFailedUsb | dnloadAbortedNow | sinkLostNow) &
            ~inError,
        then: [
          dfuStateNext < Const(_dfuErrorState, width: 4),
          dfuStatusNext <
              mux(
                sinkErrorNow,
                sink.error,
                mux(
                  clearFailedUsb | dnloadAbortedByClear | sinkLostNow,
                  Const(_statusErrUnknown, width: 4),
                  Const(_statusErrStalledPkt, width: 4),
                ),
              ),
        ],
        orElse: [
          If(
            setupValid,
            then: [
              If(
                acceptCond,
                then: [
                  // DFU 1.1 Table A.1: a GETSTATUS poll is what actually
                  // advances dfuDNLOAD_SYNC/dfuMANIFEST_SYNC onward, based
                  // on whether the sink is still busy.
                  If(
                    isGetStatusReq,
                    then: [
                      If(
                        dfuState.eq(Const(_dfuDnloadSync, width: 4)),
                        then: [
                          dfuStateNext <
                              mux(
                                sink.busy,
                                Const(_dfuDnBusy, width: 4),
                                Const(_dfuDnloadIdle, width: 4),
                              ),
                        ],
                      ),
                      If(
                        dfuState.eq(Const(_dfuManifestSync, width: 4)),
                        then: [
                          dfuStateNext <
                              mux(
                                sink.busy,
                                Const(_dfuManifest, width: 4),
                                Const(_dfuIdle, width: 4),
                              ),
                        ],
                      ),
                    ],
                  ),
                  If(
                    isClrStatusReq,
                    then: [
                      dfuStateNext < Const(_dfuIdle, width: 4),
                      dfuStatusNext < Const(_statusOk, width: 4),
                    ],
                  ),
                  If(
                    isAbortReq,
                    then: [dfuStateNext < Const(_dfuIdle, width: 4)],
                  ),
                  If(
                    isDnload & ~wLengthIsZero,
                    then: [dfuStateNext < Const(_dfuDnloadSync, width: 4)],
                  ),
                  If(
                    isDnload & wLengthIsZero,
                    then: [dfuStateNext < Const(_dfuManifestSync, width: 4)],
                  ),
                ],
                orElse: [
                  // DFU 1.1 6.1.2: any request a state does not expect
                  // STALLs, reports errSTALLEDPKT, and moves to dfuERROR.
                  // An error already latched there is never overwritten.
                  If(
                    ~inError,
                    then: [
                      dfuStateNext < Const(_dfuErrorState, width: 4),
                      dfuStatusNext < Const(_statusErrStalledPkt, width: 4),
                    ],
                  ),
                ],
              ),
            ],
            orElse: [
              // DFU 1.1 Table A.1: dfuDNBUSY and dfuMANIFEST leave on
              // their own once the sink reports done. dfuDNBUSY goes back
              // to dfuDNLOAD_SYNC, not dfuDNLOAD_IDLE: the next GETSTATUS
              // decides between dfuDNLOAD_IDLE (sink idle) and dfuDNBUSY
              // (sink already busy again). dfuMANIFEST has no such fork
              // and goes straight to dfuIDLE.
              If(
                sink.done,
                then: [
                  If(
                    dfuState.eq(Const(_dfuDnBusy, width: 4)),
                    then: [dfuStateNext < Const(_dfuDnloadSync, width: 4)],
                  ),
                  If(
                    dfuState.eq(Const(_dfuManifest, width: 4)),
                    then: [dfuStateNext < Const(_dfuIdle, width: 4)],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    Sequential(clk, [
      If(
        combinedReset,
        then: [
          dfuState < Const(_dfuIdle, width: 4),
          dfuStatus < Const(_statusOk, width: 4),
        ],
        orElse: [dfuState < dfuStateNext, dfuStatus < dfuStatusNext],
      ),
    ]);

    output('dfu_state') <= dfuState;
    output('dfu_status') <= dfuStatus;

    // ==================================================================
    // DNLOAD OUT data stage: stream bytes into the sink with a plain
    // ready/valid handshake, gated by the sink's own `ready`. The core
    // only advances its own buffer once ep0_out_ready goes high, so a
    // sink that holds ready low simply pauses the whole USB transfer
    // instead of ever losing a byte.
    // ==================================================================
    final dfuBlockReg = Logic(name: 'dfu_block_reg', width: 16);

    final onAcceptDnloadData =
        (setupValid & acceptCond & isDnload & ~wLengthIsZero).named(
          'dfu_on_accept_dnload_data',
        );
    final onAcceptDnloadEnd =
        (setupValid & acceptCond & isDnload & wLengthIsZero).named(
          'dfu_on_accept_dnload_end',
        );

    Sequential(clk, [
      If(
        combinedReset,
        then: [dnloadActive < Const(0), dfuBlockReg < Const(0, width: 16)],
        orElse: [
          If(
            onAcceptDnloadData,
            then: [dnloadActive < Const(1), dfuBlockReg < wValueField],
          ),
          If(usb.ep0OutEnd, then: [dnloadActive < Const(0)]),
          // Drop it last: a block that was aborted never reaches
          // ep0OutEnd, so this is the only thing that clears it then.
          If(usb.ep0Abort, then: [dnloadActive < Const(0)]),
        ],
      ),
    ]);

    // clearingUsb: held from the cycle `clear` is raised until the sink's
    // `clearDone` answers, so no new image byte reaches the sink while an
    // old image's queue is still being emptied. A free-running watchdog
    // fails closed if `clearDone` never comes (a stuck sink, or a stalled
    // bus clock): it latches `clearFailedUsb`, driving the device into
    // dfuERROR instead of resuming the byte stream on a guess. Only a
    // genuine `clearDone`, or a fresh `clear` from CLRSTATUS, lowers the
    // block again.
    final watchdogBits = (clearWatchdogLimit - 1).bitLength;
    final watchdogWidth = watchdogBits < 1 ? 1 : watchdogBits;
    final clearWatchdog = Logic(
      name: 'dfu_clear_watchdog_q',
      width: watchdogWidth,
    );
    final sinkClearNow = sink.clear;
    Sequential(clk, [
      If(
        combinedReset,
        then: [
          clearingUsb < Const(0),
          clearFailedUsb < Const(0),
          clearWatchdog < Const(0, width: watchdogWidth),
        ],
        orElse: [
          If(
            sinkClearNow,
            then: [
              clearingUsb < Const(1),
              clearFailedUsb < Const(0),
              clearWatchdog < Const(0, width: watchdogWidth),
            ],
            orElse: [
              If(
                clearingUsb,
                then: [
                  If(
                    sink.clearDone,
                    then: [clearingUsb < Const(0)],
                    orElse: [
                      If(
                        clearWatchdog.eq(
                          Const(clearWatchdogLimit - 1, width: watchdogWidth),
                        ),
                        then: [
                          clearingUsb < Const(0),
                          clearFailedUsb < Const(1),
                        ],
                        orElse: [
                          clearWatchdog <
                              clearWatchdog + Const(1, width: watchdogWidth),
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
    ]);

    // While waiting on `clearDone`, or after the watchdog gave up on it,
    // the byte stream stays blocked: the core NAKs DNLOAD data instead of
    // acking it.
    usb.ep0OutReady <= dnloadActive & sink.ready & ~clearBlocked;
    final outAccept =
        (dnloadActive & usb.ep0OutValid & sink.ready & ~clearBlocked).named(
          'dfu_out_accept',
        );
    sink.valid <= outAccept;
    sink.data <= usb.ep0OutData;
    sink.block <= dfuBlockReg;
    sink.target <= usb.altSetting;
    // blockDone: a block's bytes have all landed (the OUT data stage
    // ends). end: the zero-length DNLOAD, which has no data stage of its
    // own. These never coincide, so the sink can always tell a block
    // commit from the start of manifestation.
    sink.blockDone <= usb.ep0OutEnd;
    sink.end <= onAcceptDnloadEnd;

    // clear: a fresh image starts at dfuIDLE (not a continuing block from
    // dfuDNLOAD_IDLE), or the host explicitly backs out via CLRSTATUS or
    // ABORT. acceptCond already requires inError for CLRSTATUS and
    // inIdle|inDnloadIdle for ABORT, so only the fresh-download case needs
    // its own state check here.
    sink.clear <=
        (setupValid &
                acceptCond &
                (isClrStatusReq |
                    isAbortReq |
                    (isDnload & ~wLengthIsZero & inIdle)))
            .named('dfu_sink_clear');

    // ==================================================================
    // GETSTATUS (6 bytes) / GETSTATE (1 byte) IN data stage.
    // ==================================================================
    final inIndex = Logic(name: 'dfu_in_index_q', width: 3);
    final activeGetStatus = Logic(name: 'dfu_active_getstatus_q');
    final activeGetState = Logic(name: 'dfu_active_getstate_q');

    final respLength = mux(
      activeGetStatus,
      Const(6, width: 3),
      Const(1, width: 3),
    ).named('dfu_resp_length');
    final ep0InValidLocal =
        ((activeGetStatus | activeGetState) & inIndex.lt(respLength)).named(
          'dfu_in_valid',
        );
    final ep0InLastLocal =
        ((activeGetStatus | activeGetState) &
                (inIndex + Const(1, width: 3)).eq(respLength))
            .named('dfu_in_last');
    usb.ep0InValid <= ep0InValidLocal;
    usb.ep0InLast <= ep0InLastLocal;
    final inAccepted = (ep0InValidLocal & usb.ep0InReady).named(
      'dfu_in_accepted',
    );

    Sequential(clk, [
      If(
        combinedReset,
        then: [
          inIndex < Const(0, width: 3),
          activeGetStatus < Const(0),
          activeGetState < Const(0),
        ],
        orElse: [
          If(
            setupValid,
            then: [
              inIndex < Const(0, width: 3),
              activeGetStatus < isGetStatusReq,
              activeGetState < isGetStateReq,
            ],
          ),
          If(inAccepted, then: [inIndex < inIndex + Const(1, width: 3)]),
        ],
      ),
    ]);

    // bwPollTimeout (3 bytes, LE, milliseconds): nonzero while the
    // reported state is busy, so the host waits before polling again
    // (DFU 1.1 6.1.2). While `clearingUsb` drains the sink's queue,
    // bState reports dfuDNBUSY regardless of the real dfuState, so the
    // host keeps polling instead of starting a new DNLOAD too soon.
    // `~inError` guards this: a SETUP can abort the DNLOAD into dfuERROR
    // while clearingUsb is still counting down, and that real error must
    // win over a busy state the drain never finishes reporting.
    final reportedState = mux(
      clearingUsb & ~inError,
      Const(_dfuDnBusy, width: 4),
      dfuState,
    ).named('dfu_reported_state');
    final pollBusy =
        (reportedState.eq(Const(_dfuDnBusy, width: 4)) |
                reportedState.eq(Const(_dfuManifest, width: 4)))
            .named('dfu_poll_busy');
    final pollTimeoutVal = mux(
      pollBusy,
      Const(pollTimeoutMs, width: 24),
      Const(0, width: 24),
    ).named('dfu_poll_timeout_val');

    final statusBytes = [
      dfuStatus.zeroExtend(8),
      pollTimeoutVal.slice(7, 0),
      pollTimeoutVal.slice(15, 8),
      pollTimeoutVal.slice(23, 16),
      reportedState.zeroExtend(8),
      Const(0, width: 8), // iString
    ];
    Logic statusByteSel = Const(0, width: 8);
    for (var i = 0; i < statusBytes.length; i++) {
      statusByteSel = mux(
        inIndex.eq(Const(i, width: 3)),
        statusBytes[i],
        statusByteSel,
      );
    }
    usb.ep0InData <=
        mux(activeGetStatus, statusByteSel, reportedState.zeroExtend(8));
  }

  /// The built-in DFU descriptor set: DEVICE, CONFIGURATION (one interface,
  /// alt setting 0 = RAM, alt setting 1 = SPI flash if [includeFlashAlt],
  /// plus the DFU functional descriptor), and the STRING descriptors they
  /// reference.
  ///
  /// [includeFlashAlt] defaults to true (both alt settings, unchanged).
  /// Pass false for an integration with no flash sink wired up, so a host
  /// can never select an alt setting nothing will actually service.
  static List<UsbDescriptorEntry> dfuDescriptors({
    int vendorId = 0x1209,
    int productId = 0x5BF1,
    bool includeFlashAlt = true,
  }) {
    final deviceDescriptor = <int>[
      18, // bLength
      0x01, // bDescriptorType = DEVICE
      0x00, 0x02, // bcdUSB = 0x0200 (LE)
      0x00, // bDeviceClass
      0x00, // bDeviceSubClass
      0x00, // bDeviceProtocol
      64, // bMaxPacketSize0
      vendorId & 0xFF, (vendorId >> 8) & 0xFF, // idVendor (LE)
      productId & 0xFF, (productId >> 8) & 0xFF, // idProduct (LE)
      0x00, 0x01, // bcdDevice = 0x0100 (LE)
      1, // iManufacturer
      2, // iProduct
      0, // iSerialNumber
      1, // bNumConfigurations
    ];
    final configDescriptor = <int>[
      // Configuration header (9 bytes). wTotalLength is filled in below,
      // once the bytes that follow are known.
      9, 0x02, 0, 0, 1, 1, 0, 0x80, 50,
      // Interface, alt setting 0 (RAM).
      9, 0x04, 0, 0, 0, 0xFE, 0x01, 0x02, 4,
      // Interface, alt setting 1 (SPI flash).
      if (includeFlashAlt) ...[9, 0x04, 0, 1, 0, 0xFE, 0x01, 0x02, 5],
      // DFU functional descriptor.
      9, 0x21, 0x05, 0xFF, 0x00, transferSize, 0x00, 0x10, 0x01,
    ];
    configDescriptor[2] = configDescriptor.length & 0xFF;
    configDescriptor[3] = (configDescriptor.length >> 8) & 0xFF;
    return <UsbDescriptorEntry>[
      UsbDescriptorEntry(0x01, 0, deviceDescriptor),
      UsbDescriptorEntry(0x02, 0, configDescriptor),
      const UsbDescriptorEntry(0x03, 0, usbStringLangIdEnUs),
      UsbDescriptorEntry(0x03, 1, usbStringDescriptor('River')),
      UsbDescriptorEntry(0x03, 2, usbStringDescriptor('River DFU')),
      UsbDescriptorEntry(0x03, 4, usbStringDescriptor('RAM')),
      if (includeFlashAlt)
        UsbDescriptorEntry(0x03, 5, usbStringDescriptor('SPI flash')),
    ];
  }
}
