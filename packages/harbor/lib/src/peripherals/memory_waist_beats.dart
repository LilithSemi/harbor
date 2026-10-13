import 'package:rohd/rohd.dart';

import '../bus/axi4/axi4_interface.dart';
import '../bus/axi4/axi4_lite_interface.dart';
import '../bus/port/memory_waist.dart';
import '../bus/port/reg_fifo.dart';
import '../bus/tilelink/tilelink_interface.dart';
import '../bus/wishbone/wishbone_interface.dart';

/// Runs the requests of a memory slave waist on a storage port that takes one
/// beat at a time, with an outstanding depth of 1.
///
/// The storage port has the register waist shape. [stb] stays high until the
/// storage raises `ack` for one cycle, and [addr], [we], [dataIn] and [sel]
/// stay stable while it is high. The storage gives the read data with `ack`.
/// [stb] is low in the `ack` cycle, so each beat starts a new strobe, and it
/// is low while [reset] is high.
///
/// [addr] is the byte address of the beat by the FIXED, INCR and WRAP rules.
/// [sel] is the lanes of the beat size, and for a write only those with
/// their strobe set. Write data
/// goes straight from the waist to the storage, and one register holds a read
/// beat until the waist takes it. A request ends with its last read beat or
/// its write response, and only then is REQ_READY high again. The storage
/// cannot fail a beat, so ERR is always low.
class HarborMemoryBeats {
  /// High while a beat is presented to the storage.
  final Logic stb;

  /// High for a write beat.
  final Logic we;

  /// Byte address of the beat.
  final Logic addr;

  /// Write data of the beat.
  final Logic dataIn;

  /// Byte-lane selects of the beat.
  final Logic sel;

  /// High when the beat is the last beat of its request.
  final Logic last;

  HarborMemoryBeats._(
    this.stb,
    this.we,
    this.addr,
    this.dataIn,
    this.sel,
    this.last,
  );

  /// Drives the consumer side of [waist] from the storage [ack] and
  /// [dataOut], which the storage drives later.
  factory HarborMemoryBeats({
    required Logic clk,
    required Logic reset,
    required HarborMemoryWaist waist,
    required Logic ack,
    required Logic dataOut,
    String name = 'beats',
  }) {
    final w = waist;
    final c = w.config;
    final aw = c.addressWidth;
    const lenW = HarborMemoryWaistConfig.lenWidth;
    const sizeW = HarborMemoryWaistConfig.sizeWidth;
    const burstW = HarborMemoryWaistConfig.burstWidth;

    final busy = Logic(name: '${name}_busy');
    final done = Logic(name: '${name}_done');
    final isWrite = Logic(name: '${name}_write');
    final id = Logic(name: '${name}_id', width: c.idWidth);
    final beatAddr = Logic(name: '${name}_addr', width: aw);
    final len = Logic(name: '${name}_len', width: lenW);
    final left = Logic(name: '${name}_left', width: lenW);
    final size = Logic(name: '${name}_size', width: sizeW);
    final burst = Logic(name: '${name}_burst', width: burstW);
    final rValid = Logic(name: '${name}_r_valid');
    final rData = Logic(name: '${name}_r_data', width: c.dataWidth);
    final rLast = Logic(name: '${name}_r_last');
    final bValid = Logic(name: '${name}_b_valid');

    final issuing = (busy & ~done).named('${name}_issuing');
    final want = (issuing & mux(isWrite, w.wdataValid, ~rValid | w.rdataReady))
        .named('${name}_want');
    final stb = (want & ~ack & ~reset).named('${name}_stb');
    final beat = (issuing & ack).named('${name}_beat');
    final final_ = left.eq(Const(0, width: lenW)).named('${name}_final');

    // Wide enough for 256 beats of 128 bytes, then cut to the address.
    final wide = aw + lenW + (1 << sizeW);
    final bytes = (Const(1, width: wide) << size).named('${name}_bytes');
    final cur = beatAddr.zeroExtend(wide);
    final incr = ((cur & ~(bytes - 1)) + bytes).named('${name}_incr');
    final wrapMask = ((len.zeroExtend(wide) << size) | (bytes - 1)).named(
      '${name}_wrap_mask',
    );
    final wrap = ((cur & ~wrapMask) | (incr & wrapMask)).named('${name}_wrap');
    final next = mux(
      burst.eq(Const(HarborMemoryBurst.fixed.value, width: burstW)),
      cur,
      mux(
        burst.eq(Const(HarborMemoryBurst.wrap.value, width: burstW)),
        wrap,
        incr,
      ),
    ).getRange(0, aw).named('${name}_next');

    w.reqReady <= ~busy;
    w.wdataReady <= beat & isWrite;
    w.rdataValid <= rValid;
    w.rdataId <= id;
    w.rdataData <= rData;
    w.rdataErr <= Const(0);
    w.rdataLast <= rLast;
    w.wrespValid <= bValid;
    w.wrespId <= id;
    w.wrespErr <= Const(0);

    Sequential(clk, [
      If(
        reset,
        then: [
          busy < 0,
          done < 0,
          isWrite < 0,
          id < 0,
          beatAddr < 0,
          len < 0,
          left < 0,
          size < 0,
          burst < 0,
          rValid < 0,
          rData < 0,
          rLast < 0,
          bValid < 0,
        ],
        orElse: [
          If(
            rValid & w.rdataReady,
            then: [
              rValid < 0,
              If(rLast, then: [busy < 0]),
            ],
          ),
          If(bValid & w.wrespReady, then: [bValid < 0, busy < 0]),
          If(
            beat,
            then: [
              beatAddr < next,
              left < left - 1,
              If(final_, then: [done < 1]),
              If(
                isWrite,
                then: [
                  If(final_, then: [bValid < 1]),
                ],
                orElse: [rValid < 1, rData < dataOut, rLast < final_],
              ),
            ],
          ),
          If(
            w.reqValid & ~busy,
            then: [
              busy < 1,
              done < 0,
              isWrite < w.reqWrite,
              id < w.reqId,
              beatAddr < w.reqAddr,
              len < w.reqLen,
              left < w.reqLen,
              size < w.reqSize,
              burst < w.reqBurst,
            ],
          ),
        ],
      ),
    ]);

    final lanes = harborLaneMask(beatAddr, size, c.strbWidth);
    return HarborMemoryBeats._(
      stb,
      isWrite,
      beatAddr,
      w.wdataData,
      mux(isWrite, w.wdataStrb & lanes, lanes).named('${name}_sel'),
      final_,
    );
  }
}

/// High in a cycle where the native port [intf] ends a beat or a message with
/// an error. Inside the module that owns the port.
Logic harborPortErrorBeat(PairInterface intf) => switch (intf) {
  WishboneInterface(:final err?) => intf.cyc & intf.stb & err,
  WishboneInterface() => Const(0),
  Axi4Interface() =>
    (intf.bValid & intf.bReady & intf.bResp[1]) |
        (intf.rValid & intf.rReady & intf.rResp[1]),
  Axi4LiteInterface() =>
    (intf.bValid & intf.bReady & intf.bResp[1]) |
        (intf.rValid & intf.rReady & intf.rResp[1]),
  TileLinkInterface() =>
    intf.dValid & intf.dReady & (intf.dDenied | intf.dCorrupt),
  _ => throw ArgumentError('no error beat for ${intf.runtimeType}'),
};
