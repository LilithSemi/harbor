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
/// - req: ID, WRITE, ADDR, LEN (beats minus one, up to 255), SIZE, BURST.
/// - wdata: DATA, STRB, LAST. Write data follows write requests in order.
/// - rdata: ID, DATA, ERR, LAST.
/// - wresp: ID, ERR.
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

  Logic get wrespValid => port('WRESP_VALID');
  Logic get wrespReady => port('WRESP_READY');
  Logic get wrespId => port('WRESP_ID');
  Logic get wrespErr => port('WRESP_ERR');

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
          Logic.port('WRESP_VALID'),
          Logic.port('WRESP_ID', config.idWidth),
          Logic.port('WRESP_ERR'),
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
