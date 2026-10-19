import 'package:rohd/rohd.dart';

/// A PCIe packet stream with data width 64 or 128.
///
/// DW0 of a beat is in bits 31:0. A packet always starts in DW0 of a beat.
/// Header DWs keep their natural bit order. Payload DWs have their bytes
/// swapped. The `user` layout follows `HarborPcieTrnAxi`.
class HarborPcieStream {
  /// Bit in `user` for a BAR0 hit.
  static const userBar0 = 1 << 2;

  /// Bit in `user` for a BAR2 hit.
  static const userBar2 = 1 << 4;

  /// Bit in `user` for an expansion ROM hit.
  static const userRom = 1 << 8;

  /// Width of the `user` signal.
  static const userWidth = 22;

  /// Data width in bits, 64 or 128.
  final int width;

  final Logic data;
  final Logic keep;
  final Logic last;
  final Logic valid;
  final Logic ready;
  final Logic user;

  /// Creates a stream of new signals.
  HarborPcieStream({required int width, String name = 'pcie_stream'})
    : this._(
        width: width,
        data: Logic(name: '${name}_data', width: width),
        keep: Logic(name: '${name}_keep', width: width ~/ 8),
        last: Logic(name: '${name}_last'),
        valid: Logic(name: '${name}_valid'),
        ready: Logic(name: '${name}_ready'),
        user: Logic(name: '${name}_user', width: userWidth),
      );

  HarborPcieStream._({
    required this.width,
    required this.data,
    required this.keep,
    required this.last,
    required this.valid,
    required this.ready,
    required this.user,
  }) {
    if (width != 64 && width != 128) {
      throw RangeError.value(width, 'width', 'must be 64 or 128');
    }
  }

  /// Number of bytes in a beat.
  int get keepWidth => width ~/ 8;

  /// Makes [module] a consumer of [outer].
  ///
  /// Adds the inputs `<prefix>data`, `keep`, `last`, `valid` and `user`, and
  /// the output `<prefix>ready`. The returned stream holds the signals inside
  /// the module. The caller drives its `ready`.
  factory HarborPcieStream.addSink(
    Module module,
    HarborPcieStream outer, {
    String prefix = 'rx_',
  }) {
    final inner = HarborPcieStream._(
      width: outer.width,
      data: module.addInput('${prefix}data', outer.data, width: outer.width),
      keep: module.addInput(
        '${prefix}keep',
        outer.keep,
        width: outer.keepWidth,
      ),
      last: module.addInput('${prefix}last', outer.last),
      valid: module.addInput('${prefix}valid', outer.valid),
      ready: Logic(name: '${prefix}ready_inner'),
      user: module.addInput('${prefix}user', outer.user, width: userWidth),
    );
    module.addOutput('${prefix}ready') <= inner.ready;
    outer.ready <= module.output('${prefix}ready');
    return inner;
  }

  /// Makes [module] a producer onto [outer].
  ///
  /// Adds the outputs `<prefix>data`, `keep`, `last`, `valid` and `user`, and
  /// the input `<prefix>ready`. The returned stream holds the signals inside
  /// the module. The caller drives all of them except `ready`.
  factory HarborPcieStream.addSource(
    Module module,
    HarborPcieStream outer, {
    String prefix = 'tx_',
  }) {
    final inner = HarborPcieStream._(
      width: outer.width,
      data: Logic(name: '${prefix}data_inner', width: outer.width),
      keep: Logic(name: '${prefix}keep_inner', width: outer.keepWidth),
      last: Logic(name: '${prefix}last_inner'),
      valid: Logic(name: '${prefix}valid_inner'),
      ready: module.addInput('${prefix}ready', outer.ready),
      user: Logic(name: '${prefix}user_inner', width: userWidth),
    );
    for (final (suffix, source, target) in [
      ('data', inner.data, outer.data),
      ('keep', inner.keep, outer.keep),
      ('last', inner.last, outer.last),
      ('valid', inner.valid, outer.valid),
      ('user', inner.user, outer.user),
    ]) {
      module.addOutput('$prefix$suffix', width: source.width) <= source;
      target <= module.output('$prefix$suffix');
    }
    return inner;
  }
}

/// Header DW0 to DW3 in a 128 bit value, DW0 in bits 31:0.
typedef PcieHeader = Logic;

/// Format and type, bits 31:24 of DW0.
Logic tlpFmtType(PcieHeader header) => header.slice(31, 24);

/// True when the header has four DWs.
Logic tlpIs4Dw(PcieHeader header) => header[29];

/// True when the packet carries a payload.
Logic tlpHasData(PcieHeader header) => header[30];

/// The EP (poisoned) bit.
Logic tlpPoisoned(PcieHeader header) => header[14];

/// Length field in DWs. The value 0 means 1024.
Logic tlpLength(PcieHeader header) => header.slice(9, 0);

/// Requester ID of a request.
Logic tlpRequesterId(PcieHeader header) => header.slice(63, 48);

/// Tag of a request.
Logic tlpTag(PcieHeader header) => header.slice(47, 40);

/// Last DW byte enables of a request.
Logic tlpLastBe(PcieHeader header) => header.slice(39, 36);

/// First DW byte enables of a request.
Logic tlpFirstBe(PcieHeader header) => header.slice(35, 32);

/// Byte address of a request. A 3DW header gives the upper 32 bits as zero.
Logic tlpAddress(PcieHeader header) {
  final dw2 = header.slice(95, 64);
  final dw3 = header.slice(127, 96);
  return mux(
    tlpIs4Dw(header),
    [dw2, dw3.slice(31, 2), Const(0, width: 2)].swizzle(),
    [Const(0, width: 32), dw2.slice(31, 2), Const(0, width: 2)].swizzle(),
  );
}

/// Completer ID of a completion.
Logic tlpCompleterId(PcieHeader header) => header.slice(63, 48);

/// Completion status of a completion.
Logic tlpCplStatus(PcieHeader header) => header.slice(47, 45);

/// Remaining byte count of a completion. The value 0 means 4096.
Logic tlpByteCount(PcieHeader header) => header.slice(43, 32);

/// Requester ID of a completion.
Logic tlpCplRequesterId(PcieHeader header) => header.slice(95, 80);

/// Tag of a completion.
Logic tlpCplTag(PcieHeader header) => header.slice(79, 72);

/// Lower address of a completion.
Logic tlpLowerAddress(PcieHeader header) => header.slice(70, 64);

/// Swaps the bytes of a payload DW between stream order and memory order.
Logic tlpSwapBytes(Logic dword) => [
  dword.slice(7, 0),
  dword.slice(15, 8),
  dword.slice(23, 16),
  dword.slice(31, 24),
].swizzle();

/// Collects the 128 bit header of each packet on a [HarborPcieStream].
///
/// At width 128 the header is in the first beat. At width 64 it ends in the
/// second beat. The module only watches the stream. `headerValid` is high
/// while the last header beat is on the stream. A consumer takes the header
/// when `headerValid` and `ready` are both high.
///
/// A 3DW header with data has its first payload DW in the same beat as the
/// header. That DW is bits 63:32 of the second beat at width 64 and bits
/// 127:96 of the first beat at width 128. `payloadInHeaderBeat` marks this
/// case. A 4DW header has its first payload DW in the next beat.
class HarborPcieHeaderCapture extends Module {
  /// Data width in bits.
  final int width;

  Logic get header => output('header');
  Logic get headerValid => output('header_valid');
  Logic get payloadInHeaderBeat => output('payload_in_header_beat');

  /// First payload DW in stream byte order. Use [tlpSwapBytes] for memory
  /// order.
  Logic get firstPayloadDw => output('first_payload_dw');

  HarborPcieHeaderCapture({
    required Logic clk,
    required Logic reset,
    required HarborPcieStream stream,
    super.name = 'pcie_header_capture',
  }) : width = stream.width,
       super(definitionName: 'HarborPcieHeaderCapture_W${stream.width}') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final data = addInput('rx_data', stream.data, width: width);
    final valid = addInput('rx_valid', stream.valid);
    final ready = addInput('rx_ready', stream.ready);
    final last = addInput('rx_last', stream.last);

    final beat = Logic(name: 'beat', width: 2);
    final low = width == 64 ? Logic(name: 'header_low', width: 64) : null;
    final fire = valid & ready;
    Sequential(clk, [
      If(
        reset,
        then: [beat < 0],
        orElse: [
          If(
            fire,
            then: [
              If(
                last,
                then: [beat < 0],
                orElse: [
                  If(beat.lt(2), then: [beat < beat + 1]),
                ],
              ),
              if (low != null) If(beat.eq(0), then: [low < data.slice(63, 0)]),
            ],
          ),
        ],
      ),
    ]);

    final Logic head;
    final Logic atHeader;
    final Logic payload;
    if (width == 64) {
      head = [data, low!].swizzle();
      atHeader = beat.eq(1);
      payload = data.slice(63, 32);
    } else {
      head = data;
      atHeader = beat.eq(0);
      payload = data.slice(127, 96);
    }
    addOutput('header', width: 128) <= head;
    addOutput('header_valid') <= valid & atHeader;
    addOutput('payload_in_header_beat') <= tlpHasData(head) & ~tlpIs4Dw(head);
    addOutput('first_payload_dw', width: 32) <= payload;
  }
}
