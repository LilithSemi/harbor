import 'package:rohd/rohd.dart';

/// Burst type of a memory waist request. The encodings match AXI4 xBURST.
enum HarborMemoryBurst {
  fixed(0),
  incr(1),
  wrap(2);

  final int value;
  const HarborMemoryBurst(this.value);
}

/// Parameters of a memory waist.
class HarborMemoryWaistConfig {
  /// Byte address width in bits.
  final int addressWidth;

  /// Data width in bits.
  final int dataWidth;

  /// Request ID width in bits.
  final int idWidth;

  /// Number of requests the slave side can hold in flight. The port layer
  /// never issues more than this.
  final int outstanding;

  /// Width of the request length field. LEN is beats minus one.
  static const int lenWidth = 8;

  /// Width of the request size field, log2 of bytes per beat.
  static const int sizeWidth = 3;

  /// Width of the request burst field.
  static const int burstWidth = 2;

  const HarborMemoryWaistConfig({
    required this.addressWidth,
    required this.dataWidth,
    this.idWidth = 1,
    this.outstanding = 1,
  });

  /// Byte strobe width.
  int get strbWidth => dataWidth ~/ 8;

  /// Returns error messages. Empty means valid.
  List<String> validate() => [
    if (addressWidth < 1) 'addressWidth must be >= 1',
    if (dataWidth < 8 || dataWidth & (dataWidth - 1) != 0)
      'dataWidth must be a power of two >= 8',
    if (idWidth < 1) 'idWidth must be >= 1',
    if (outstanding < 1) 'outstanding must be >= 1',
  ];

  @override
  String toString() =>
      'HarborMemoryWaistConfig(addr: $addressWidth, data: $dataWidth, '
      'id: $idWidth, outstanding: $outstanding)';
}

/// The memory waist: valid/ready channels for bursts and many requests in
/// flight, independent of the fabric kind.
///
/// - req: ID, WRITE, ADDR, LEN (beats minus one, up to 255), SIZE, BURST,
///   EXCLUSIVE.
/// - wdata: DATA, STRB, LAST. Write data follows write requests in order.
/// - rdata: ID, DATA, ERR, LAST, EXOKAY.
/// - wresp: ID, ERR, EXOKAY.
///
/// REQ_EXCLUSIVE high makes the request an AXI4 exclusive access. EXOKAY has
/// the same value on every beat of a read.
///
/// A device makes an exclusive pair (an exclusive read, then an exclusive
/// write to the same bytes) only by these rules:
///
/// - The read and the write use the same REQ_ID.
/// - That ID has a reservation slot in the monitor. On a fabric, these are
///   the low IDs 0 to N-1 of the master, where N comes from its
///   `exclusiveIds` (with `HarborExclusive.auto`, N can be less than the ID
///   count).
/// - The bytes of the access are a power of two, at most the reservation
///   granule and at most 128, and the address is aligned to them. LEN is at
///   most 15 (16 beats).
///
/// On a response:
///
/// - ERR 1 is a bus error. EXOKAY is 0.
/// - ERR 0 and EXOKAY 1: the exclusive access passed. After a read, the
///   reservation is set. After a write, memory changed.
/// - ERR 0 and EXOKAY 0 after an exclusive read: the path has no exclusive
///   support for this access. Do not send the exclusive write.
/// - ERR 0 and EXOKAY 0 after an exclusive write, when the read of the pair
///   got EXOKAY 1 and the pair keeps the rules: the reservation was lost and
///   memory did not change. The device can try the pair again.
///
/// When a device breaks the rules, EXOKAY 0 does not tell it that memory
/// did not change. An exclusive access on an ID with no slot is a normal
/// access: the write changes memory and gets OKAY. An access that breaks
/// the size rules is a normal read, or a write that is dropped with OKAY.
///
/// A plain access always gets EXOKAY 0. Only an AXI4 master port does
/// exclusive access. A Wishbone or TileLink master port does an exclusive
/// request as a plain access with EXOKAY 0, so an exclusive write there
/// changes memory. A device must check EXOKAY of the exclusive read before
/// it sends the write.
///
/// A slave adapter answers exclusive access itself. It ignores the EXOKAY
/// that the memory device drives, so a device drives 0. REQ_EXCLUSIVE on a
/// slave waist is AXI4 LOCK when the port has an exclusive monitor, else 0.
/// It is a hint only: it is also high for an access the monitor treats as
/// normal or drops. The device can ignore it.
///
/// A slave waist (the memory device side) returns responses in acceptance
/// order per direction. That order is still legal AXI4 order per ID.
///
/// There is no order between the two directions. A read accepted after the
/// WRESP of a write returns the data of that write. A master that needs
/// read after write order waits for the WRESP before it sends the read.
///
/// A master waist (the initiator side, such as a DMA engine or a cache)
/// returns responses ordered per ID only: each response carries its ID, and
/// different IDs may come back in any order. Responses that share an ID stay
/// in issue order. Read beats of different IDs may interleave with each
/// other beat by beat, mid-burst.
///
/// A channel transfers when its VALID and READY are both high. The slave
/// side states its depth in [HarborMemoryWaistConfig.outstanding].
///
/// REQ_READY must not depend on WDATA_VALID. The slave adapter sends write
/// data only after its REQ is taken, so a device that waits for data before
/// it accepts a write REQ deadlocks.
///
/// A master must not make a request's write data depend on the response to
/// a later request, or it can hold a shared bus waiting for data that never
/// comes.
///
/// A device on a master waist holds RDATA_READY high only while a read it
/// sent is still in flight or taken in that cycle, and WRESP_READY the same
/// for a write. This is stricter than plain valid/ready: a READY tied high
/// is not allowed. The Wishbone master with one request in flight passes a
/// response through in the ACK cycle, so a READY that is high in a cycle
/// where the device does not take the response loses it. That port stops a
/// simulation when a device breaks this rule.
///
/// A memory waist device must have no read side effects. A burst that breaks
/// the AXI4 rules still reaches the device: the slave adapter forwards it
/// with write strobes forced to 0 and discards its read data, so the device
/// does a real read it was never asked for, and that read must not change
/// device state.
///
/// A write beat with every strobe low must not cause WRESP_ERR either. A
/// slave adapter pads a short burst out to the length it already
/// committed to, so the device sees beats the real master never named.
///
/// Provider role is the requester (a memory master waist). Consumer role is
/// the memory (a memory slave waist).
class HarborMemoryWaist extends PairInterface {
  /// The parameters of this waist.
  final HarborMemoryWaistConfig config;

  Logic get reqValid => port('REQ_VALID');
  Logic get reqReady => port('REQ_READY');
  Logic get reqId => port('REQ_ID');
  Logic get reqWrite => port('REQ_WRITE');
  Logic get reqAddr => port('REQ_ADDR');
  Logic get reqLen => port('REQ_LEN');
  Logic get reqSize => port('REQ_SIZE');
  Logic get reqBurst => port('REQ_BURST');
  Logic get reqExclusive => port('REQ_EXCLUSIVE');

  Logic get wdataValid => port('WDATA_VALID');
  Logic get wdataReady => port('WDATA_READY');
  Logic get wdataData => port('WDATA_DATA');
  Logic get wdataStrb => port('WDATA_STRB');
  Logic get wdataLast => port('WDATA_LAST');

  Logic get rdataValid => port('RDATA_VALID');
  Logic get rdataReady => port('RDATA_READY');
  Logic get rdataId => port('RDATA_ID');
  Logic get rdataData => port('RDATA_DATA');
  Logic get rdataErr => port('RDATA_ERR');
  Logic get rdataLast => port('RDATA_LAST');
  Logic get rdataExOkay => port('RDATA_EXOKAY');

  Logic get wrespValid => port('WRESP_VALID');
  Logic get wrespReady => port('WRESP_READY');
  Logic get wrespId => port('WRESP_ID');
  Logic get wrespErr => port('WRESP_ERR');
  Logic get wrespExOkay => port('WRESP_EXOKAY');

  HarborMemoryWaist(this.config)
    : super(
        portsFromProvider: [
          Logic.port('REQ_VALID'),
          Logic.port('REQ_ID', config.idWidth),
          Logic.port('REQ_WRITE'),
          Logic.port('REQ_ADDR', config.addressWidth),
          Logic.port('REQ_LEN', HarborMemoryWaistConfig.lenWidth),
          Logic.port('REQ_SIZE', HarborMemoryWaistConfig.sizeWidth),
          Logic.port('REQ_BURST', HarborMemoryWaistConfig.burstWidth),
          Logic.port('REQ_EXCLUSIVE'),
          Logic.port('WDATA_VALID'),
          Logic.port('WDATA_DATA', config.dataWidth),
          Logic.port('WDATA_STRB', config.strbWidth),
          Logic.port('WDATA_LAST'),
          Logic.port('RDATA_READY'),
          Logic.port('WRESP_READY'),
        ],
        portsFromConsumer: [
          Logic.port('REQ_READY'),
          Logic.port('WDATA_READY'),
          Logic.port('RDATA_VALID'),
          Logic.port('RDATA_ID', config.idWidth),
          Logic.port('RDATA_DATA', config.dataWidth),
          Logic.port('RDATA_ERR'),
          Logic.port('RDATA_LAST'),
          Logic.port('RDATA_EXOKAY'),
          Logic.port('WRESP_VALID'),
          Logic.port('WRESP_ID', config.idWidth),
          Logic.port('WRESP_ERR'),
          Logic.port('WRESP_EXOKAY'),
        ],
      ) {
    final errors = config.validate();
    if (errors.isNotEmpty) {
      throw ArgumentError(
        'Invalid HarborMemoryWaistConfig: ${errors.join("; ")}',
      );
    }
  }

  @override
  HarborMemoryWaist clone() => HarborMemoryWaist(config);
}
